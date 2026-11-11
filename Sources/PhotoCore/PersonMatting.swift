import CoreGraphics
import CoreImage
import Foundation
import Vision

// MARK: - Matte settings

/// Edge/quality settings for the person matte.
///
/// All values are normalized so they behave the same on previews and full-size
/// images. This is a **heuristic v1** matte built on Vision's person
/// segmentation plus edge feathering and color desaturation; it is not a
/// commercial-grade matting model and real-photo quality is not guaranteed.
public struct PersonMatteSettings: Codable, Equatable {
    /// Feather radius as a fraction of the shorter image edge (`0...0.5`).
    /// `0.25` ≈ 0.5% of the shorter edge of Gaussian edge blur.
    public var feather: Double = 0.25
    /// Half-width of the linear alpha ramp around coverage 0.5 (`0.02...0.5`).
    /// Larger values keep more semi-transparent edge pixels (softer cutout).
    public var edgeSoftness: Double = 0.12
    /// Edge spill suppression strength (`0...1`); desaturates semi-transparent
    /// edge pixels so a colored original background does not tint the cutout.
    public var edgeDecontamination: Double = 0.65
    /// Mean coverage below which the matte is considered empty (`0...0.5`).
    public var minimumCoverage: Double = 0.02

    public init(feather: Double = 0.25,
                edgeSoftness: Double = 0.12,
                edgeDecontamination: Double = 0.65,
                minimumCoverage: Double = 0.02) {
        self.feather = feather
        self.edgeSoftness = edgeSoftness
        self.edgeDecontamination = edgeDecontamination
        self.minimumCoverage = minimumCoverage
    }

    /// Validates and clamps into the documented ranges. Callers that accept user
    /// input should fail loudly instead of silently producing a broken matte.
    public func validated() throws -> PersonMatteSettings {
        guard feather.isFinite, (0...0.5).contains(feather) else {
            throw AtelierError.invalidConfiguration("人物蒙版羽化必须在 0...0.5 之间。")
        }
        guard edgeSoftness.isFinite, (0.02...0.5).contains(edgeSoftness) else {
            throw AtelierError.invalidConfiguration("人物蒙版边缘柔和度必须在 0.02...0.5 之间。")
        }
        guard edgeDecontamination.isFinite, (0...1).contains(edgeDecontamination) else {
            throw AtelierError.invalidConfiguration("人物蒙版去色边强度必须在 0...1 之间。")
        }
        guard minimumCoverage.isFinite, (0...0.5).contains(minimumCoverage) else {
            throw AtelierError.invalidConfiguration("人物蒙版最小覆盖率必须在 0...0.5 之间。")
        }
        return self
    }
}

// MARK: - Matte

/// Result of person matting.
///
/// - `mask` is an opaque grayscale coverage image (RGB = coverage in `0...1`,
///   alpha = 1) in the **same pixel extent as the source** with Core Image's
///   bottom-left origin.
/// - `coverage` is the mean mask value over the whole frame.
/// - `confidence` is a coverage-based heuristic in `0...1` (not a model score).
/// - `hasPerson` is false when the coverage is below
///   `settings.minimumCoverage`; callers must then fail explicitly instead of
///   silently compositing an empty subject.
public struct PersonMatte {
    public var mask: CIImage
    public var coverage: Double
    public var confidence: Double
    public var hasPerson: Bool
    public var settings: PersonMatteSettings

    public init(mask: CIImage, coverage: Double, confidence: Double,
                hasPerson: Bool, settings: PersonMatteSettings) {
        self.mask = mask
        self.coverage = coverage
        self.confidence = confidence
        self.hasPerson = hasPerson
        self.settings = settings
    }
}

// MARK: - Engine

/// Vision person segmentation plus pure edge-refinement helpers.
///
/// The expensive Vision pass is isolated in `detect(in:settings:context:)`; every
/// other function is a pure Core Image pipeline so tests (and batch integration)
/// can run without a detector. Coordinate system: Core Image, bottom-left origin,
/// pixels; all inputs/outputs keep the source extent unless documented otherwise.
public enum PersonMatting {
    /// Upper bound for the Vision analysis raster (longest edge).
    public static let maximumAnalysisDimension = 2048
    /// Downsample cap used to measure matte coverage (longest edge).
    static let coverageSampleDimension = 256

    static let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private static let defaultContext = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false
    ])

    private static let edgeBandKernel = CIKernel(source: """
    kernel vec4 personEdgeBand(__sample matte, float strength) {
        float a = clamp(dot(matte.rgb, vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
        float band = clamp(4.0 * a * (1.0 - a), 0.0, 1.0);
        return vec4(vec3(band * strength), 1.0);
    }
    """)

    // MARK: Detection

    /// Runs Vision person segmentation and returns the refined matte.
    ///
    /// Throws `AtelierError.invalidConfiguration` with an explicit "未检测到人物"
    /// message when no usable person is found; it never silently returns an empty
    /// matte for a requested cutout.
    public static func detect(in image: CIImage,
                              settings: PersonMatteSettings = PersonMatteSettings(),
                              context: CIContext? = nil) throws -> PersonMatte {
        let settings = try settings.validated()
        let extent = try validExtent(of: image)
        let analysis = resized(image, longestEdge: maximumAnalysisDimension)
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent32Float
        request.usesCPUOnly = false
        do {
            try VNImageRequestHandler(ciImage: analysis, options: [:]).perform([request])
        } catch {
            throw AtelierError.invalidConfiguration(
                "本机 Vision 人物分割不可用（\(error.localizedDescription)）；证件照/换背景需要可用的人物蒙版。")
        }
        guard let observation = request.results?.first else {
            throw AtelierError.invalidConfiguration(
                "未检测到人物：Vision 人物分割未返回蒙版；证件照/换背景不会在无人物时静默改图。")
        }
        let linearGray = CGColorSpace(name: CGColorSpace.linearGray)!
        let rawMask = CIImage(cvPixelBuffer: observation.pixelBuffer,
                              options: [.colorSpace: linearGray])
        // Scale the detector raster back to the source pixel extent.
        let analysisExtent = analysis.extent
        let scaleX = extent.width / max(1, analysisExtent.width)
        let scaleY = extent.height / max(1, analysisExtent.height)
        let aligned = rawMask
            .transformed(by: CGAffineTransform(scaleX: scaleX * analysisExtent.width / max(1, rawMask.extent.width),
                                               y: scaleY * analysisExtent.height / max(1, rawMask.extent.height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        let matte = try matte(fromMask: aligned, settings: settings, context: context)
        guard matte.hasPerson else {
            throw AtelierError.invalidConfiguration(
                "未检测到可用人物：蒙版覆盖率 \(percent(matte.coverage)) 低于阈值 \(percent(settings.minimumCoverage))；证件照/换背景已跳过。")
        }
        return matte
    }

    /// Builds a matte from an existing grayscale/coverage mask (pure; no Vision).
    public static func matte(fromMask mask: CIImage,
                             settings: PersonMatteSettings = PersonMatteSettings(),
                             context: CIContext? = nil) throws -> PersonMatte {
        let settings = try settings.validated()
        let refined = try refine(mask: mask, settings: settings)
        let renderContext = context ?? defaultContext
        let coverage = try measureCoverage(refined, context: renderContext)
        let confidence = min(1, max(0, coverage / max(settings.minimumCoverage * 4, 0.0001)))
        let hasPerson = coverage >= settings.minimumCoverage
        return PersonMatte(mask: refined, coverage: coverage, confidence: confidence,
                           hasPerson: hasPerson, settings: settings)
    }

    /// Throws the documented explicit error when a matte has no usable person.
    public static func requirePerson(_ matte: PersonMatte) throws {
        guard matte.hasPerson else {
            throw AtelierError.invalidConfiguration(
                "未检测到可用人物：蒙版覆盖率 \(percent(matte.coverage)) 过低；换背景/证件照已跳过，不静默改图。")
        }
    }

    // MARK: Refinement (pure)

    /// Feathered, edge-shaped coverage mask. Pure Core Image; deterministic.
    ///
    /// Steps: RGB→luminance coverage → Gaussian feather (fraction of shorter
    /// edge) → linear alpha ramp of half-width `edgeSoftness` around 0.5 →
    /// clamp to `0...1` → force opaque alpha. Output keeps the input extent.
    public static func refine(mask: CIImage,
                              settings: PersonMatteSettings = PersonMatteSettings()) throws -> CIImage {
        let settings = try settings.validated()
        let extent = try validExtent(of: mask)
        var working = flattenToCoverage(mask)
        let shorterEdge = min(extent.width, extent.height)
        // Feather 0 keeps a hard edge; otherwise ~2% of the shorter edge, clamped
        // so a 6MP raster does not get a 30px halo and a 128px test mask still
        // produces a visible soft band.
        var blurRadius: CGFloat = 0
        if settings.feather > 0.0001 {
            blurRadius = min(24, max(0.6, CGFloat(settings.feather) * shorterEdge * 0.02))
        }
        if blurRadius > 0.5, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(working.clampedToExtent(), forKey: kCIInputImageKey)
            blur.setValue(blurRadius, forKey: kCIInputRadiusKey)
            if let blurred = blur.outputImage {
                working = blurred.cropped(to: extent)
            }
        }
        let softness = max(0.02, settings.edgeSoftness)
        let slope = 1.0 / (2 * softness)
        let bias = 0.5 * (1 - slope)
        if let matrix = CIFilter(name: "CIColorMatrix") {
            matrix.setValue(working, forKey: kCIInputImageKey)
            matrix.setValue(CIVector(x: slope, y: 0, z: 0, w: 0), forKey: "inputRVector")
            matrix.setValue(CIVector(x: slope, y: 0, z: 0, w: 0), forKey: "inputGVector")
            matrix.setValue(CIVector(x: slope, y: 0, z: 0, w: 0), forKey: "inputBVector")
            matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputAVector")
            matrix.setValue(CIVector(x: bias, y: bias, z: bias, w: 1), forKey: "inputBiasVector")
            if let shaped = matrix.outputImage {
                working = shaped.cropped(to: extent)
            }
        }
        if let clamp = CIFilter(name: "CIColorClamp") {
            clamp.setValue(working, forKey: kCIInputImageKey)
            clamp.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputMinComponents")
            clamp.setValue(CIVector(x: 1, y: 1, z: 1, w: 1), forKey: "inputMaxComponents")
            if let clamped = clamp.outputImage {
                working = clamped.cropped(to: extent)
            }
        }
        return working.cropped(to: extent)
    }

    /// Edge color decontamination: desaturates the semi-transparent matte band so
    /// a colored original background does not tint the cutout (heuristic v1
    /// spill suppression, not true background estimation).
    public static func decontaminateEdges(foreground: CIImage,
                                          matte: PersonMatte,
                                          strength: Double? = nil) throws -> CIImage {
        let extent = try validExtent(of: foreground)
        let strength = strength ?? matte.settings.edgeDecontamination
        guard strength.isFinite, (0...1).contains(strength) else {
            throw AtelierError.invalidConfiguration("去色边强度必须在 0...1 之间。")
        }
        guard strength > 0.0001 else { return foreground }
        let desaturated = foreground.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1 - strength
        ])
        guard let kernel = edgeBandKernel else {
            throw AtelierError.invalidConfiguration("去色边 kernel 编译失败。")
        }
        let matteMask = matte.mask
        guard let band = kernel.apply(extent: extent,
                                      roiCallback: { _, _ in matteMask.extent },
                                      arguments: [matteMask, NSNumber(value: strength)]) else {
            throw AtelierError.invalidConfiguration("去色边蒙版无法生成。")
        }
        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            throw AtelierError.invalidConfiguration("去色边合成滤镜不可用。")
        }
        blend.setValue(desaturated, forKey: kCIInputImageKey)
        blend.setValue(foreground, forKey: "inputBackgroundImage")
        blend.setValue(band.cropped(to: extent), forKey: "inputMaskImage")
        guard let output = blend.outputImage else {
            throw AtelierError.invalidConfiguration("去色边合成无法生成输出。")
        }
        return output.cropped(to: extent)
    }

    // MARK: Helpers

    /// Flattens arbitrary RGB masks into a single coverage channel in R/G/B.
    static func flattenToCoverage(_ image: CIImage) -> CIImage {
        guard let matrix = CIFilter(name: "CIColorMatrix") else { return image }
        matrix.setValue(image, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0), forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputAVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputBiasVector")
        return (matrix.outputImage ?? image).cropped(to: image.extent)
    }

    /// Mean coverage of the flattened mask over its whole extent (0...1).
    public static func measureCoverage(_ mask: CIImage, context: CIContext? = nil) throws -> Double {
        let extent = try validExtent(of: mask)
        let context = context ?? defaultContext
        let scale = min(1, CGFloat(coverageSampleDimension) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let sampled = mask
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width,
                                               y: CGFloat(height) / extent.height))
            .cropped(to: bounds)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            context.render(sampled, toBitmap: address,
                           rowBytes: width * 4 * MemoryLayout<Float>.stride,
                           bounds: bounds, format: .RGBAf, colorSpace: linearColorSpace)
        }
        var total = 0.0
        for index in 0..<(width * height) {
            let value = Double(pixels[index * 4])
            total += value.isFinite ? min(1, max(0, value)) : 0
        }
        return total / Double(max(1, width * height))
    }

    /// Normalizes any finite image extent; throws instead of producing NaN math.
    static func validExtent(of image: CIImage) throws -> CGRect {
        let extent = image.extent
        guard !extent.isNull, !extent.isInfinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0,
              extent.width <= 100_000, extent.height <= 100_000 else {
            throw AtelierError.invalidConfiguration("人物蒙版输入图像尺寸无效。")
        }
        return extent
    }

    private static func resized(_ image: CIImage, longestEdge: Int) -> CIImage {
        let extent = image.extent
        let scale = min(1, CGFloat(longestEdge) / max(1, max(extent.width, extent.height)))
        guard scale < 0.999 else { return image }
        let width = max(1, Int((extent.width * scale).rounded(.up)))
        let height = max(1, Int((extent.height * scale).rounded(.up)))
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.2f%%", value * 100)
    }
}

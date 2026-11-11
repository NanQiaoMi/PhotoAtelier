import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

public enum ContentSelectionTarget: String, Codable, CaseIterable, Hashable {
    case people
    case background
    case faceSkin

    public var title: String {
        switch self {
        case .people: return "人物"
        case .background: return "背景"
        case .faceSkin: return "面部皮肤候选"
        }
    }
}

public struct ContentSelectionReport: Codable, Equatable {
    public let personStatus: String
    public let faceStatus: String
    public let faceCount: Int
    /// Estimated visible-pixel coverage, keyed by ContentSelectionTarget.rawValue.
    /// This is a sampled mask statistic, not a calibrated probability.
    public let coverage: [String: Double]
    public let warnings: [String]

    public init(personStatus: String = "notRequested", faceStatus: String = "notRequested",
                faceCount: Int = 0, coverage: [String: Double] = [:], warnings: [String] = []) {
        self.personStatus = personStatus
        self.faceStatus = faceStatus
        self.faceCount = faceCount
        self.coverage = coverage
        self.warnings = warnings
    }
}

public struct ContentSelectionResult {
    public let report: ContentSelectionReport
    public let masks: [ContentSelectionTarget: CIImage]

    public init(report: ContentSelectionReport, masks: [ContentSelectionTarget: CIImage]) {
        self.report = report
        self.masks = masks
    }

    public func image(for target: ContentSelectionTarget) -> CIImage? { masks[target] }
}

/// Creates ephemeral, per-photo semantic mask candidates. No face geometry or
/// pixel-derived coordinates are written into recipes or reports.
public enum ContentSelectionAnalyzer {
    private static let visionLimit = 1024
    private static let sampleLimit = 384
    private static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private struct Raster {
        let width: Int
        let height: Int
        let pixels: [Float]

        subscript(_ x: Int, _ y: Int, _ channel: Int) -> Double {
            Double(pixels[(y * width + x) * 4 + channel])
        }
    }

    private struct FaceGeometry {
        let box: CGRect
        let contour: [CGPoint]
        let exclusions: [CGRect]
    }

    private struct ChromaSample {
        let red: Double
        let green: Double
        let blue: Double
        let luminance: Double
    }

    public static func analyze(reference: CIImage,
                               targets: Set<ContentSelectionTarget>,
                               context: CIContext,
                               cancellation: CancellationToken? = nil) throws -> ContentSelectionResult {
        try cancellation?.check()
        guard !targets.isEmpty else {
            return ContentSelectionResult(report: ContentSelectionReport(), masks: [:])
        }

        let extent = reference.extent
        guard !extent.isNull, !extent.isInfinite,
              extent.minX.isFinite, extent.minY.isFinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else {
            throw AtelierError.invalidConfiguration("内容选区参考图必须有有限且非空的图像范围。")
        }

        var masks: [ContentSelectionTarget: CIImage] = [:]
        var warnings: [String] = []
        var coverage: [String: Double] = [:]
        for target in targets { coverage[target.rawValue] = 0 }

        let needsPerson = targets.contains(.people) || targets.contains(.background)
        var personStatus = "notRequested"
        if needsPerson {
            try cancellation?.check()
            let visionImage = try resized(reference, longestEdge: visionLimit)
            var personMask: CIImage?
            do {
                // A dense segmentation map alone can hallucinate a subject in
                // illustrations or leave low probabilities across a landscape.
                // Require independent face/body evidence before offering its
                // inverse as a background selection.
                if try hasHumanEvidence(in: visionImage) {
                    personMask = try runPersonSegmentation(on: visionImage, cpuOnly: false)
                } else {
                    personStatus = "noDetection"
                    warnings.append("未找到足够的人脸或身体检测依据；人物和背景选区均未生成。")
                }
            } catch {
                try cancellation?.check()
                warnings.append("本机 Vision 人物检测首次运行失败，已尝试一次 CPU 回退。")
                do {
                    if try hasHumanEvidence(in: visionImage, cpuOnly: true) {
                        personMask = try runPersonSegmentation(on: visionImage, cpuOnly: true)
                    } else {
                        personStatus = "noDetection"
                    }
                } catch {
                    try cancellation?.check()
                    warnings.append("人物分割不可用；人物和背景选区均未生成。")
                }
            }

            if let personMask {
                try cancellation?.check()
                let aligned = alignedMask(personMask, extent: extent, inverted: false)
                let measurement = try measure(aligned, over: reference, context: context)
                if measurement.hasUsefulCoverage && measurement.confidentSamples >= 8 {
                    personStatus = "available"
                    if targets.contains(.people) {
                        masks[.people] = aligned
                        coverage[ContentSelectionTarget.people.rawValue] = measurement.coverage
                    }
                    if targets.contains(.background) {
                        let background = alignedMask(aligned, extent: extent, inverted: true)
                        masks[.background] = background
                        coverage[ContentSelectionTarget.background.rawValue] = max(0, 1 - measurement.coverage)
                    }
                    warnings.append("人物蒙版是本机 Vision 的软蒙版候选，可能只覆盖部分人物，并遗漏遮挡、发丝或透明边缘；不按身份区分，请逐张检查与补选。")
                } else {
                    personStatus = "noDetection"
                    warnings.append("未检测到足量的有效人物蒙版像素；人物和背景选区均不可用。")
                }
            } else if personStatus != "noDetection" {
                personStatus = "unavailable"
            }
        }

        var faceStatus = "notRequested"
        var faceCount = 0
        if targets.contains(.faceSkin) {
            try cancellation?.check()
            do {
                let visionImage = try resized(reference, longestEdge: visionLimit)
                let request = VNDetectFaceLandmarksRequest()
                try VNImageRequestHandler(ciImage: visionImage, options: [:]).perform([request])
                let faces = request.results ?? []
                faceCount = faces.count
                if faces.isEmpty {
                    faceStatus = "noDetection"
                    warnings.append("未检测到人脸，面部皮肤候选不可用。")
                } else {
                    try cancellation?.check()
                    let sample = try raster(reference, longestEdge: sampleLimit, context: context)
                    let candidate = makeFaceSkinMask(faces: Array(faces.prefix(16)),
                                                     width: sample.width, height: sample.height,
                                                     pixels: sample.pixels)
                    let candidateImage = image(from: candidate, width: sample.width,
                                               height: sample.height, extent: extent)
                    let measurement = try measure(candidateImage, over: reference, context: context)
                    if measurement.hasUsefulCoverage {
                        faceStatus = "available"
                        masks[.faceSkin] = candidateImage
                        coverage[ContentSelectionTarget.faceSkin.rawValue] = measurement.coverage
                        warnings.append("面部皮肤是按面部轮廓、五官排除区和本照片颜色生成的保守候选，并非皮肤分割模型；肤色边界可能有误。")
                    } else {
                        faceStatus = "unavailable"
                        warnings.append("检测到人脸，但有效地标或颜色样本不足；未生成面部皮肤候选。最多评估 16 张脸。")
                    }
                }
            } catch {
                try cancellation?.check()
                faceStatus = "unavailable"
                warnings.append("本机 Vision 人脸地标检测不可用；未生成面部皮肤候选。")
            }
        }

        try cancellation?.check()
        let report = ContentSelectionReport(personStatus: personStatus, faceStatus: faceStatus,
                                            faceCount: faceCount, coverage: coverage,
                                            warnings: warnings)
        return ContentSelectionResult(report: report, masks: masks)
    }

    private static func runPersonSegmentation(on image: CIImage, cpuOnly: Bool) throws -> CIImage {
        // Vision requests are deliberately created for this still image only;
        // VNStatefulRequest may otherwise retain earlier masks for video use.
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent32Float
        request.usesCPUOnly = cpuOnly
        try VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
        guard let observation = request.results?.first else {
            throw AtelierError.invalidConfiguration("Vision 人物分割未返回蒙版。")
        }
        let linearGray = CGColorSpace(name: CGColorSpace.linearGray)!
        return CIImage(cvPixelBuffer: observation.pixelBuffer,
                       options: [.colorSpace: linearGray])
    }

    private static func hasHumanEvidence(in image: CIImage, cpuOnly: Bool = false) throws -> Bool {
        let faces = VNDetectFaceRectanglesRequest()
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = false
        faces.usesCPUOnly = cpuOnly
        bodies.usesCPUOnly = cpuOnly
        try VNImageRequestHandler(ciImage: image, options: [:]).perform([faces, bodies])
        return (faces.results ?? []).contains { $0.confidence >= 0.5 }
            || (bodies.results ?? []).contains { $0.confidence >= 0.5 }
    }

    private static func resized(_ image: CIImage, longestEdge: Int) throws -> CIImage {
        let extent = image.extent
        let scale = min(1, CGFloat(longestEdge) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded(.up)))
        let height = max(1, Int((extent.height * scale).rounded(.up)))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let normalized = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: bounds)
        return normalized
    }

    private static func raster(_ image: CIImage, longestEdge: Int, context: CIContext,
                               referenceExtent: CGRect? = nil) throws -> Raster {
        // Use one explicit integer grid for both operands. Independently taking
        // ceil after several CI transforms can produce 384 vs 385 samples from
        // mathematically identical extents due to floating-point roundoff.
        let extent = referenceExtent ?? image.extent
        let scale = min(1, CGFloat(longestEdge) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let sampled = image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: .init(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
            .cropped(to: bounds)
        let pixelCount = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !pixelCount.overflow,
              pixelCount.partialValue <= longestEdge * longestEdge else {
            throw AtelierError.invalidConfiguration("内容选区采样尺寸无效。")
        }
        let componentCount = pixelCount.partialValue.multipliedReportingOverflow(by: 4)
        guard !componentCount.overflow else {
            throw AtelierError.invalidConfiguration("内容选区采样缓冲区过大。")
        }
        var pixels = [Float](repeating: 0, count: componentCount.partialValue)
        pixels.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            context.render(sampled, toBitmap: address,
                           rowBytes: width * 4 * MemoryLayout<Float>.stride,
                           bounds: bounds,
                           format: .RGBAf, colorSpace: linearSRGB)
        }
        return Raster(width: width, height: height, pixels: pixels)
    }

    private static func image(from grayscale: [Float], width: Int, height: Int,
                              extent: CGRect) -> CIImage {
        var rgba = [Float](repeating: 0, count: width * height * 4)
        for index in grayscale.indices {
            let value = grayscale[index].isFinite ? min(1, max(0, grayscale[index])) : 0
            let offset = index * 4
            rgba[offset] = value
            rgba[offset + 1] = value
            rgba[offset + 2] = value
            rgba[offset + 3] = 1
        }
        let data = rgba.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        let bitmap = CIImage(bitmapData: data, bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                             size: CGSize(width: width, height: height), format: .RGBAf,
                             colorSpace: linearSRGB)
        let scale = CGAffineTransform(scaleX: extent.width / CGFloat(width),
                                      y: extent.height / CGFloat(height))
        return bitmap.transformed(by: scale)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    static func alignedMask(_ image: CIImage, extent: CGRect,
                                        inverted: Bool) -> CIImage {
        let inputExtent = image.extent
        let normalized = image.transformed(by: CGAffineTransform(translationX: -inputExtent.minX,
                                                                  y: -inputExtent.minY))
        let scale = CGAffineTransform(scaleX: extent.width / max(1, inputExtent.width),
                                      y: extent.height / max(1, inputExtent.height))
        let aligned = normalized.transformed(by: scale)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        let filter = CIFilter(name: "CIColorMatrix")!
        filter.setValue(aligned, forKey: kCIInputImageKey)
        let value: CGFloat = inverted ? -1 : 1
        let bias: CGFloat = inverted ? 1 : 0
        let grayVector = CIVector(x: value, y: 0, z: 0, w: 0)
        filter.setValue(grayVector, forKey: "inputRVector")
        filter.setValue(grayVector, forKey: "inputGVector")
        filter.setValue(grayVector, forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputAVector")
        filter.setValue(CIVector(x: bias, y: bias, z: bias, w: 1), forKey: "inputBiasVector")
        return (filter.outputImage ?? aligned).cropped(to: extent)
    }

    static func measure(_ mask: CIImage, over reference: CIImage,
                                context: CIContext) throws -> (coverage: Double, hasUsefulCoverage: Bool, confidentSamples: Int) {
        let maskRaster = try raster(mask, longestEdge: sampleLimit, context: context, referenceExtent: reference.extent)
        let sourceRaster = try raster(reference, longestEdge: sampleLimit, context: context, referenceExtent: reference.extent)
        guard maskRaster.width == sourceRaster.width, maskRaster.height == sourceRaster.height else {
            throw AtelierError.invalidConfiguration("内容蒙版与参考图采样尺寸不一致。")
        }
        var visibleWeight = 0.0
        var maskWeight = 0.0
        var activeSamples = 0
        var confidentSamples = 0
        for y in 0..<maskRaster.height {
            for x in 0..<maskRaster.width {
                let alpha = min(1, max(0, sourceRaster[x, y, 3]))
                guard alpha > 0.001 else { continue }
                let value = min(1, max(0, maskRaster[x, y, 0]))
                visibleWeight += alpha
                maskWeight += alpha * value
                if value >= 0.05 { activeSamples += 1 }
                if value >= 0.5 { confidentSamples += 1 }
            }
        }
        guard visibleWeight > 0 else { return (0, false, 0) }
        let fraction = min(1, max(0, maskWeight / visibleWeight))
        return (fraction, activeSamples >= 8 && fraction >= 0.0005, confidentSamples)
    }

    private static func makeFaceSkinMask(faces: [VNFaceObservation], width: Int, height: Int,
                                         pixels: [Float]) -> [Float] {
        let geometries = faces.compactMap { faceGeometry($0, sampleWidth: width, sampleHeight: height) }
        guard !geometries.isEmpty else { return [Float](repeating: 0, count: width * height) }
        var output = [Float](repeating: 0, count: width * height)

        for face in geometries {
            var seeds: [ChromaSample] = []
            for row in 0..<height {
                let pointY = 1 - (Double(row) + 0.5) / Double(height)
                for x in 0..<width {
                    let pointX = (Double(x) + 0.5) / Double(width)
                    let point = CGPoint(x: pointX, y: pointY)
                    guard inside(point, polygon: face.contour), !face.exclusions.contains(where: { $0.contains(point) }) else { continue }
                    let localX = (pointX - face.box.minX) / face.box.width
                    let localY = (pointY - face.box.minY) / face.box.height
                    guard (0.16...0.42).contains(localX) || (0.58...0.84).contains(localX),
                          (0.28...0.68).contains(localY) else { continue }
                    let sample = chromaSample(pixels: pixels, width: width, x: x, y: row)
                    if let sample { seeds.append(sample) }
                }
            }
            guard seeds.count >= 6 else { continue }

            let meanRed = seeds.reduce(0) { $0 + $1.red } / Double(seeds.count)
            let meanGreen = seeds.reduce(0) { $0 + $1.green } / Double(seeds.count)
            let meanBlue = seeds.reduce(0) { $0 + $1.blue } / Double(seeds.count)
            let meanLuminance = seeds.reduce(0) { $0 + $1.luminance } / Double(seeds.count)
            let variance = seeds.reduce(0.0) { partial, sample in
                partial + pow(sample.red - meanRed, 2) + pow(sample.green - meanGreen, 2)
                    + pow(sample.blue - meanBlue, 2)
            } / Double(seeds.count * 3)
            let tolerance = min(0.12, max(0.05, sqrt(variance) * 2.5 + 0.025))
            var faceMask = [Float](repeating: 0, count: width * height)
            var usefulPixels = 0

            for row in 0..<height {
                let pointY = 1 - (Double(row) + 0.5) / Double(height)
                for x in 0..<width {
                    let pointX = (Double(x) + 0.5) / Double(width)
                    let point = CGPoint(x: pointX, y: pointY)
                    guard inside(point, polygon: face.contour),
                          !face.exclusions.contains(where: { $0.contains(point) }) else { continue }
                    let sample = chromaSample(pixels: pixels, width: width, x: x, y: row)
                    guard let sample, meanLuminance > 0.0001 else { continue }
                    let luminanceRatio = sample.luminance / meanLuminance
                    // Relative to this photo's cheek samples; no fixed skin-white point is used.
                    guard (0.18...3.0).contains(luminanceRatio) else { continue }
                    let distance = sqrt(pow(sample.red - meanRed, 2) + pow(sample.green - meanGreen, 2)
                                        + pow(sample.blue - meanBlue, 2))
                    let value = min(1, max(0, (tolerance + 0.025 - distance) / 0.025))
                    if value >= 0.1 { usefulPixels += 1 }
                    let offset = row * width + x
                    faceMask[offset] = Float(value)
                }
            }
            guard usefulPixels >= 8 else { continue }
            let softened = soften(faceMask, width: width, height: height)
            for index in output.indices { output[index] = max(output[index], softened[index]) }
        }
        return output
    }

    /// A separable-equivalent 3x3 binomial blur has a standard deviation of
    /// about 0.7 sample pixels. Facial-feature exclusion margins are applied
    /// before this step so smoothing cannot bleed into eyes or the mouth.
    private static func soften(_ mask: [Float], width: Int, height: Int) -> [Float] {
        let kernel: [Float] = [1, 2, 1]
        var output = [Float](repeating: 0, count: mask.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                var weight: Float = 0
                for dy in -1...1 {
                    let sampleY = y + dy
                    guard sampleY >= 0, sampleY < height else { continue }
                    for dx in -1...1 {
                        let sampleX = x + dx
                        guard sampleX >= 0, sampleX < width else { continue }
                        let w = kernel[dx + 1] * kernel[dy + 1]
                        sum += mask[sampleY * width + sampleX] * w
                        weight += w
                    }
                }
                output[y * width + x] = weight > 0 ? sum / weight : 0
            }
        }
        return output
    }

    private static func faceGeometry(_ face: VNFaceObservation,
                                    sampleWidth: Int,
                                    sampleHeight: Int) -> FaceGeometry? {
        let box = face.boundingBox
        guard box.minX.isFinite, box.minY.isFinite, box.width.isFinite, box.height.isFinite,
              box.width > 0.015, box.height > 0.015,
              let landmarks = face.landmarks,
              let contourRegion = landmarks.faceContour,
              let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye,
              let leftBrow = landmarks.leftEyebrow, let rightBrow = landmarks.rightEyebrow,
              let lips = landmarks.outerLips else { return nil }
        let contour = globalPoints(contourRegion, in: box)
        guard contour.count >= 8 else { return nil }
        let regions: [(VNFaceLandmarkRegion2D, CGFloat, CGFloat)] = [
            (leftEye, 0.055, 0.05), (rightEye, 0.055, 0.05),
            (leftBrow, 0.06, 0.035), (rightBrow, 0.06, 0.035),
            (lips, 0.07, 0.06)
        ]
        var exclusions: [CGRect] = []
        for (region, marginX, marginY) in regions {
            let points = globalPoints(region, in: box)
            guard points.count >= 3 else { return nil }
            var local = CGRect.null
            for point in points {
                let x = (point.x - box.minX) / box.width
                let y = (point.y - box.minY) / box.height
                local = local.union(CGRect(x: x, y: y, width: 0, height: 0))
            }
            // Keep the exclusion margin wider than the one-pixel blur kernel,
            // even when the detected face is small in the 384px analysis raster.
            let blurGuardX = 1.5 / (CGFloat(sampleWidth) * box.width)
            let blurGuardY = 1.5 / (CGFloat(sampleHeight) * box.height)
            let expanded = local.insetBy(dx: -max(marginX, blurGuardX),
                                         dy: -max(marginY, blurGuardY))
            let clipped = expanded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            if !clipped.isNull {
                exclusions.append(CGRect(x: box.minX + clipped.minX * box.width,
                                         y: box.minY + clipped.minY * box.height,
                                         width: clipped.width * box.width,
                                         height: clipped.height * box.height))
            }
        }
        return FaceGeometry(box: box, contour: contour, exclusions: exclusions)
    }

    private static func globalPoints(_ region: VNFaceLandmarkRegion2D, in box: CGRect) -> [CGPoint] {
        region.normalizedPoints.map { point in
            CGPoint(x: box.minX + point.x * box.width,
                    y: box.minY + point.y * box.height)
        }
    }

    private static func inside(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var result = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            let crosses = (current.y > point.y) != (previous.y > point.y)
                && point.x < (previous.x - current.x) * (point.y - current.y)
                    / ((previous.y - current.y) == 0 ? 1e-12 : (previous.y - current.y)) + current.x
            if crosses { result.toggle() }
            previous = current
        }
        return result
    }

    private static func chromaSample(pixels: [Float], width: Int, x: Int, y: Int) -> ChromaSample? {
        let offset = (y * width + x) * 4
        let alpha = Double(pixels[offset + 3])
        let red = Double(pixels[offset]), green = Double(pixels[offset + 1]), blue = Double(pixels[offset + 2])
        guard alpha.isFinite, alpha > 0.02, red.isFinite, green.isFinite, blue.isFinite else { return nil }
        let total = red + green + blue
        guard total.isFinite, total > 0.0003 else { return nil }
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        guard luminance.isFinite, luminance > 0 else { return nil }
        return ChromaSample(red: red / total, green: green / total, blue: blue / total,
                            luminance: luminance)
    }
}

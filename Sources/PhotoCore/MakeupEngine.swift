import CoreGraphics
import CoreImage
import Foundation

// MARK: - Settings

/// Cosmetic make-up controls (recipe field in C5).
///
/// Neutral means every intensity is zero: `isNeutral` is true and `apply` returns
/// the input image untouched (exact pre-makeup pixels). Colors are sRGB display
/// values (`0...1`) shared with `SRGBColor`; the engine converts them to linear
/// light internally. This is a heuristic v1 colouring pass (masked tinting), not a
/// professional make-up renderer: it does not rebuild structure, does not change
/// geometry, and real-photo aesthetic quality is not guaranteed.
public struct MakeupSettings: Codable, Equatable {
    public var lipColor: SRGBColor
    /// Lip tint strength `0...1` (`0` disables the lip pass).
    public var lipIntensity: Double
    public var browColor: SRGBColor
    /// Brow density `0...1`: darkens and tints the eyebrow pixels (`0` disables).
    public var browDensity: Double
    public var cheekColor: SRGBColor
    /// Blush strength `0...1` (`0` disables).
    public var cheekIntensity: Double
    /// Blush ellipse size as a `0.2...1.0` multiplier of the derived cheek radius.
    public var cheekRadius: Double
    public var eyeshadowColor: SRGBColor
    /// Eyeshadow strength `0...1` (`0` disables).
    public var eyeshadowIntensity: Double

    // P1-F: Enhanced makeup fields
    public var eyelinerColor: SRGBColor
    /// Eyeliner intensity `0...1` (`0` disables).
    public var eyelinerIntensity: Double
    /// Eyelash density strength `0...1` (`0` disables).
    public var eyelashIntensity: Double
    public var irisColor: SRGBColor
    /// Iris/contact-lens tint strength `0...1` (`0` disables).
    public var irisIntensity: Double
    /// Catchlight specular brightening `0...1` (`0` disables).
    public var catchlightIntensity: Double
    /// T-zone and cheek high-point brightening `0...1` (`0` disables).
    public var highlightIntensity: Double
    /// Face contour and jawline shading `0...1` (`0` disables).
    public var contourIntensity: Double

    public init(lipColor: SRGBColor = SRGBColor(red: 0.78, green: 0.22, blue: 0.30),
                lipIntensity: Double = 0,
                browColor: SRGBColor = SRGBColor(red: 0.28, green: 0.20, blue: 0.15),
                browDensity: Double = 0,
                cheekColor: SRGBColor = SRGBColor(red: 0.92, green: 0.45, blue: 0.45),
                cheekIntensity: Double = 0,
                cheekRadius: Double = 0.5,
                eyeshadowColor: SRGBColor = SRGBColor(red: 0.55, green: 0.35, blue: 0.45),
                eyeshadowIntensity: Double = 0,
                eyelinerColor: SRGBColor = SRGBColor(red: 0.12, green: 0.10, blue: 0.10),
                eyelinerIntensity: Double = 0,
                eyelashIntensity: Double = 0,
                irisColor: SRGBColor = SRGBColor(red: 0.42, green: 0.32, blue: 0.22),
                irisIntensity: Double = 0,
                catchlightIntensity: Double = 0,
                highlightIntensity: Double = 0,
                contourIntensity: Double = 0) {
        self.lipColor = lipColor
        self.lipIntensity = lipIntensity
        self.browColor = browColor
        self.browDensity = browDensity
        self.cheekColor = cheekColor
        self.cheekIntensity = cheekIntensity
        self.cheekRadius = cheekRadius
        self.eyeshadowColor = eyeshadowColor
        self.eyeshadowIntensity = eyeshadowIntensity
        self.eyelinerColor = eyelinerColor
        self.eyelinerIntensity = eyelinerIntensity
        self.eyelashIntensity = eyelashIntensity
        self.irisColor = irisColor
        self.irisIntensity = irisIntensity
        self.catchlightIntensity = catchlightIntensity
        self.highlightIntensity = highlightIntensity
        self.contourIntensity = contourIntensity
    }

    enum CodingKeys: String, CodingKey {
        case lipColor, lipIntensity, browColor, browDensity
        case cheekColor, cheekIntensity, cheekRadius, eyeshadowColor, eyeshadowIntensity
        case eyelinerColor, eyelinerIntensity, eyelashIntensity, irisColor, irisIntensity
        case catchlightIntensity, highlightIntensity, contourIntensity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lipColor = try container.decodeIfPresent(SRGBColor.self, forKey: .lipColor) ?? SRGBColor(red: 0.78, green: 0.22, blue: 0.30)
        lipIntensity = try container.decodeIfPresent(Double.self, forKey: .lipIntensity) ?? 0
        browColor = try container.decodeIfPresent(SRGBColor.self, forKey: .browColor) ?? SRGBColor(red: 0.28, green: 0.20, blue: 0.15)
        browDensity = try container.decodeIfPresent(Double.self, forKey: .browDensity) ?? 0
        cheekColor = try container.decodeIfPresent(SRGBColor.self, forKey: .cheekColor) ?? SRGBColor(red: 0.92, green: 0.45, blue: 0.45)
        cheekIntensity = try container.decodeIfPresent(Double.self, forKey: .cheekIntensity) ?? 0
        cheekRadius = try container.decodeIfPresent(Double.self, forKey: .cheekRadius) ?? 0.5
        eyeshadowColor = try container.decodeIfPresent(SRGBColor.self, forKey: .eyeshadowColor) ?? SRGBColor(red: 0.55, green: 0.35, blue: 0.45)
        eyeshadowIntensity = try container.decodeIfPresent(Double.self, forKey: .eyeshadowIntensity) ?? 0
        eyelinerColor = try container.decodeIfPresent(SRGBColor.self, forKey: .eyelinerColor) ?? SRGBColor(red: 0.12, green: 0.10, blue: 0.10)
        eyelinerIntensity = try container.decodeIfPresent(Double.self, forKey: .eyelinerIntensity) ?? 0
        eyelashIntensity = try container.decodeIfPresent(Double.self, forKey: .eyelashIntensity) ?? 0
        irisColor = try container.decodeIfPresent(SRGBColor.self, forKey: .irisColor) ?? SRGBColor(red: 0.42, green: 0.32, blue: 0.22)
        irisIntensity = try container.decodeIfPresent(Double.self, forKey: .irisIntensity) ?? 0
        catchlightIntensity = try container.decodeIfPresent(Double.self, forKey: .catchlightIntensity) ?? 0
        highlightIntensity = try container.decodeIfPresent(Double.self, forKey: .highlightIntensity) ?? 0
        contourIntensity = try container.decodeIfPresent(Double.self, forKey: .contourIntensity) ?? 0
    }

    /// True when no pass would change a pixel (all strengths zero).
    public var isNeutral: Bool {
        lipIntensity == 0 && browDensity == 0 && cheekIntensity == 0
            && eyeshadowIntensity == 0 && eyelinerIntensity == 0
            && eyelashIntensity == 0 && irisIntensity == 0
            && catchlightIntensity == 0 && highlightIntensity == 0
            && contourIntensity == 0
    }

    /// True when any P1-F enhanced makeup feature is active (requires recipe version 14).
    public var requiresVersion14: Bool {
        eyelinerIntensity > 0 || eyelashIntensity > 0 || irisIntensity > 0
            || catchlightIntensity > 0 || highlightIntensity > 0 || contourIntensity > 0
    }

    /// Validates ranges/NaN and colour components. Every color is validated even
    /// for a disabled pass so a malformed payload fails loudly instead of
    /// silently producing a different preview later.
    public func validated() throws -> MakeupSettings {
        _ = try lipColor.validated()
        _ = try browColor.validated()
        _ = try cheekColor.validated()
        _ = try eyeshadowColor.validated()
        _ = try eyelinerColor.validated()
        _ = try irisColor.validated()
        try Self.requireUnit(lipIntensity, named: "唇色强度")
        try Self.requireUnit(browDensity, named: "眉色密度")
        try Self.requireUnit(cheekIntensity, named: "腮红强度")
        try Self.requireUnit(eyeshadowIntensity, named: "眼影强度")
        try Self.requireUnit(eyelinerIntensity, named: "眼线强度")
        try Self.requireUnit(eyelashIntensity, named: "睫毛浓度")
        try Self.requireUnit(irisIntensity, named: "美瞳强度")
        try Self.requireUnit(catchlightIntensity, named: "眼神光强度")
        try Self.requireUnit(highlightIntensity, named: "面部高光强度")
        try Self.requireUnit(contourIntensity, named: "面部修容强度")
        guard cheekRadius.isFinite, (0.2...1.0).contains(cheekRadius) else {
            throw AtelierError.invalidConfiguration("腮红半径必须在 0.2...1.0 之间。")
        }
        return self
    }

    private static func requireUnit(_ value: Double, named name: String) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw AtelierError.invalidConfiguration("\(name)必须在 0...1 之间。")
        }
    }
}

// MARK: - Engine

/// Masked, luminance-preserving make-up tinting.
///
/// Pipeline: `FaceSemanticAnalyzer.masks(in:landmarks:)` supplies the feathered lip,
/// brow and skin mattes; cheeks and eyeshadow get geometric ellipse masks derived
/// from each face's bounding box / eye polygons (Gaussian-feathered). Every pass
/// multiplies the source by a per-channel ratio that keeps the **local luminance**
/// unchanged, then blends through the mask with `CIBlendWithMask`. Keeping the
/// luminance means skin shading/texture is preserved instead of being painted over,
/// which is the "skin-tone protection" heuristic in this v1.
///
/// Coordinate system: normalized landmarks/flexible geometry in Core Image
/// bottom-left coordinates; input/output extent is preserved. Manual strokes are
/// not modelled here; C5 wires the recipe/pipeline/UI.
public enum MakeupEngine {
    /// Upper bound on faces processed in one call (matches the semantic provider).
    public static let maximumFaces = 8
    /// Longest edge of the internal coverage raster for geometric masks.
    static let maskRasterDimension = 512

    static let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private static let coverageContext = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false
    ])

    /// Applies make-up to all detected/provided faces.
    ///
    /// - Parameters:
    ///   - image: Source image; the output keeps its extent.
    ///   - faces: Landmarks in normalized bottom-left coordinates (no Vision call).
    ///   - settings: Colors/strengths; neutral settings return `image` untouched.
    /// - Throws: `AtelierError.invalidConfiguration` for invalid settings, no
    ///   usable face geometry, or a failed Core Image stage; never silently edits.
    public static func apply(to image: CIImage,
                             faces: [FaceLandmarkSet],
                             settings: MakeupSettings,
                             maxDimension: Int = FaceSemanticAnalyzer.defaultMaxDimension) throws -> CIImage {
        let settings = try settings.validated()
        let extent = try validExtent(of: image)
        guard !settings.isNeutral else { return image }
        let usableFaces = Array(faces.prefix(maximumFaces)).filter { $0.hasUsableGeometry }
        guard !usableFaces.isEmpty else {
            throw AtelierError.invalidConfiguration(
                "未检测到可用人脸/地标，妆容未应用（不静默改图）。")
        }

        let semantic = FaceSemanticAnalyzer.masks(in: image, landmarks: usableFaces,
                                                  maxDimension: maxDimension)
        guard !semantic.isEmpty else {
            throw AtelierError.invalidConfiguration(
                "人脸语义蒙版为空（地标缺失或置信度不足），妆容未应用（不静默改图）。")
        }

        var output = image
        // Lips: use the colour-gated semantic matte, fall back to the landmark
        // polygons when the red-ring gate found nothing (e.g. pale synthetic lips).
        if settings.lipIntensity > 0 {
            // FaceSemanticAnalysis returns a NON-nil all-zero mask when its colour
            // gate rejects every pixel (pale lips, lip colour ≈ skin). Treating
            // non-nil as "available" would silently skip the fallback, so only use
            // a semantic mask that actually carries coverage.
            let mask: CIImage
            if isUsableMask(semantic.lips) {
                mask = semantic.lips!
            } else {
                mask = try polygonLipMask(faces: usableFaces, extent: extent)
            }
            output = try tint(output, mask: mask, color: settings.lipColor,
                              intensity: settings.lipIntensity, luminanceScale: 1.0)
        }
        // Brows: darken + tint; `luminanceScale < 1` produces the "density" darkening.
        if settings.browDensity > 0 {
            let mask: CIImage
            if isUsableMask(semantic.brows) {
                mask = semantic.brows!
            } else {
                mask = try polygonBrowMask(faces: usableFaces, extent: extent)
            }
            output = try tint(output, mask: mask, color: settings.browColor,
                              intensity: settings.browDensity, luminanceScale: 0.45)
        }
        // Cheeks: geometric blush ellipse per face, restricted to the skin matte so
        // eyes/lips/brows and background are never tinted.
        if settings.cheekIntensity > 0 {
            var mask = try ellipseMask(faces: usableFaces, extent: extent, kind: .cheek,
                                       radiusScale: settings.cheekRadius)
            // Always clip blush to the face region (inscribed bbox ellipse); the
            // cheek ellipse can extend past the face box, which would tint the
            // background when the skin matte is missing/empty.
            let faceRegion = try ellipseMask(faces: usableFaces, extent: extent,
                                             kind: .faceRegion, radiusScale: 1.0)
            mask = try multiplyMasks(mask, faceRegion, extent: extent)
            if isUsableMask(semantic.skin), let skin = semantic.skin {
                mask = try multiplyMasks(mask, skin, extent: extent)
            }
            output = try tint(output, mask: mask, color: settings.cheekColor,
                              intensity: settings.cheekIntensity, luminanceScale: 1.0)
        }
        // Eyeshadow: eyelid-band ellipse above each eye polygon.
        if settings.eyeshadowIntensity > 0 {
            let mask = try ellipseMask(faces: usableFaces, extent: extent, kind: .eyeshadow,
                                       radiusScale: 1.0)
            output = try tint(output, mask: mask, color: settings.eyeshadowColor,
                              intensity: settings.eyeshadowIntensity, luminanceScale: 0.9)
        }
        // Eyeliner (P1-F): upper eyelid contour darkening and tint
        if settings.eyelinerIntensity > 0 {
            let mask = try extendedGeometricMask(faces: usableFaces, extent: extent, kind: .eyeliner)
            output = try tint(output, mask: mask, color: settings.eyelinerColor,
                              intensity: settings.eyelinerIntensity, luminanceScale: 0.25)
        }
        // Eyelash (P1-F): upper margin density darkening
        if settings.eyelashIntensity > 0 {
            let mask = try extendedGeometricMask(faces: usableFaces, extent: extent, kind: .eyelash)
            output = try tint(output, mask: mask, color: SRGBColor(red: 0.08, green: 0.08, blue: 0.08),
                              intensity: settings.eyelashIntensity, luminanceScale: 0.20)
        }
        // Iris (P1-F): pupil-centered iris tinting, clipped to eye opening
        if settings.irisIntensity > 0 {
            let mask = try extendedGeometricMask(faces: usableFaces, extent: extent, kind: .iris)
            output = try tint(output, mask: mask, color: settings.irisColor,
                              intensity: settings.irisIntensity, luminanceScale: 1.15)
        }
        // Catchlight (P1-F): specular micro-brightening in the pupil
        if settings.catchlightIntensity > 0 {
            let mask = try extendedGeometricMask(faces: usableFaces, extent: extent, kind: .catchlight)
            output = try tint(output, mask: mask, color: SRGBColor(red: 1.0, green: 1.0, blue: 1.0),
                              intensity: settings.catchlightIntensity, luminanceScale: 2.2)
        }
        // Face Highlight (P1-F): T-zone and cheek high-point diffuse glow, clipped to skin
        if settings.highlightIntensity > 0 {
            var mask = try extendedGeometricMask(faces: usableFaces, extent: extent, kind: .highlight)
            if isUsableMask(semantic.skin), let skin = semantic.skin {
                mask = try multiplyMasks(mask, skin, extent: extent)
            }
            output = try tint(output, mask: mask, color: SRGBColor(red: 1.0, green: 0.98, blue: 0.94),
                              intensity: settings.highlightIntensity, luminanceScale: 1.35)
        }
        // Face Contour (P1-F): jawline and cheek hollow shading, clipped to skin
        if settings.contourIntensity > 0 {
            var mask = try extendedGeometricMask(faces: usableFaces, extent: extent, kind: .contour)
            let faceRegion = try ellipseMask(faces: usableFaces, extent: extent, kind: .faceRegion, radiusScale: 1.0)
            mask = try multiplyMasks(mask, faceRegion, extent: extent)
            if isUsableMask(semantic.skin), let skin = semantic.skin {
                mask = try multiplyMasks(mask, skin, extent: extent)
            }
            output = try tint(output, mask: mask, color: SRGBColor(red: 0.42, green: 0.34, blue: 0.28),
                              intensity: settings.contourIntensity, luminanceScale: 0.65)
        }
        return output.cropped(to: extent)
    }

    // MARK: - Tint stage

    /// Multiplies the image by `color` in linear light at constant luminance, then
    /// blends through `mask × intensity`. Luminance preservation keeps the skin's
    /// shading and texture; `luminanceScale` below 1 darkens (brow density).
    static func tint(_ image: CIImage, mask: CIImage, color: SRGBColor,
                     intensity: Double, luminanceScale: Double) throws -> CIImage {
        let extent = try validExtent(of: image)
        let linear = linearComponents(of: color)
        let tintLuminance = 0.2126 * linear.r + 0.7152 * linear.g + 0.0722 * linear.b
        let ratio: (r: Double, g: Double, b: Double)
        if tintLuminance < 0.002 {
            // Near-black/neutral target has no meaningful hue ratio (a pure
            // luminance-preserving ratio would be 1, i.e. a silent no-op). Darken
            // by half the requested scale so a black lip/brow color is visible.
            let darken = max(0.05, luminanceScale * 0.5)
            ratio = (darken, darken, darken)
        } else {
            let scale = luminanceScale / tintLuminance
            ratio = (linear.r * scale, linear.g * scale, linear.b * scale)
        }
        guard let matrix = CIFilter(name: "CIColorMatrix") else {
            throw AtelierError.invalidConfiguration("妆容颜色矩阵滤镜不可用。")
        }
        matrix.setValue(image, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: ratio.r, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: ratio.g, z: 0, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: ratio.b, w: 0), forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        guard var tinted = matrix.outputImage else {
            throw AtelierError.invalidConfiguration("妆容着色无法生成输出。")
        }
        // Luminance-preserving tint ratios for saturated colours can exceed 1 in
        // linear light (e.g. pure red lips ≈ 2.9). Bound the tinted layer so later
        // stages (reference colour / LUT / local masks) receive finite, sane values;
        // 1.5 keeps saturation while avoiding extreme HDR excursions.
        if let clamp = CIFilter(name: "CIColorClamp") {
            clamp.setValue(tinted, forKey: kCIInputImageKey)
            clamp.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputMinComponents")
            clamp.setValue(CIVector(x: 1.5, y: 1.5, z: 1.5, w: 1), forKey: "inputMaxComponents")
            if let clamped = clamp.outputImage {
                tinted = clamped.cropped(to: extent)
            }
        }

        // Scale the mask coverage by the intensity before blending.
        var weight = mask
        if intensity < 0.9999 {
            guard let weightMatrix = CIFilter(name: "CIColorMatrix") else {
                throw AtelierError.invalidConfiguration("妆容蒙版权重滤镜不可用。")
            }
            weightMatrix.setValue(mask, forKey: kCIInputImageKey)
            weightMatrix.setValue(CIVector(x: intensity, y: 0, z: 0, w: 0),
                                  forKey: "inputRVector")
            weightMatrix.setValue(CIVector(x: 0, y: intensity, z: 0, w: 0),
                                  forKey: "inputGVector")
            weightMatrix.setValue(CIVector(x: 0, y: 0, z: intensity, w: 0),
                                  forKey: "inputBVector")
            weightMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1),
                                  forKey: "inputAVector")
            weightMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0),
                                  forKey: "inputBiasVector")
            weight = (weightMatrix.outputImage ?? mask).cropped(to: extent)
        }

        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            throw AtelierError.invalidConfiguration("妆容合成滤镜不可用。")
        }
        blend.setValue(tinted, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: "inputBackgroundImage")
        blend.setValue(weight, forKey: "inputMaskImage")
        guard let output = blend.outputImage else {
            throw AtelierError.invalidConfiguration("妆容混合无法生成输出。")
        }
        return output.cropped(to: extent)
    }

    static func multiplyMasks(_ first: CIImage, _ second: CIImage, extent: CGRect) throws -> CIImage {
        guard let multiply = CIFilter(name: "CIMultiplyCompositing") else {
            throw AtelierError.invalidConfiguration("妆容蒙版相乘滤镜不可用。")
        }
        multiply.setValue(first, forKey: kCIInputImageKey)
        multiply.setValue(second, forKey: "inputBackgroundImage")
        guard let output = multiply.outputImage else {
            throw AtelierError.invalidConfiguration("妆容蒙版相乘无法生成输出。")
        }
        return output.cropped(to: extent)
    }

    // MARK: - Geometric masks

    enum EllipseKind {
        case cheek
        case eyeshadow
        /// Inscribed face-bbox ellipse used to clip blush inside the face.
        case faceRegion
    }

    /// Builds one feathered coverage image with the cheek/eyeshadow ellipses of
    /// every face, then scales it to the source extent.
    static func ellipseMask(faces: [FaceLandmarkSet], extent: CGRect,
                            kind: EllipseKind, radiusScale: Double) throws -> CIImage {
        let scale = min(1, CGFloat(maskRasterDimension) / max(extent.width, extent.height))
        let width = max(8, Int((extent.width * scale).rounded()))
        let height = max(8, Int((extent.height * scale).rounded()))
        var coverage = [Float](repeating: 0, count: width * height)
        for face in faces {
            let box = face.boundingBox
            guard box.width > 0.01, box.height > 0.01 else { continue }
            switch kind {
            case .cheek:
                let faceWidth = Double(box.width)
                let faceHeight = Double(box.height)
                let radiusX = 0.22 * faceWidth * radiusScale
                let radiusY = 0.16 * faceHeight * radiusScale
                for side in [-1.0, 1.0] {
                    let centerX = Double(box.midX) + side * 0.38 * faceWidth
                    let centerY = Double(box.midY) - 0.02 * faceHeight
                    fillEllipse(&coverage, width: width, height: height,
                                centerX: centerX, centerY: centerY,
                                radiusX: radiusX, radiusY: radiusY)
                }
            case .faceRegion:
                fillEllipse(&coverage, width: width, height: height,
                            centerX: Double(box.midX), centerY: Double(box.midY),
                            radiusX: 0.5 * Double(box.width),
                            radiusY: 0.5 * Double(box.height))
            case .eyeshadow:
                for eye in [face.leftEye, face.rightEye] {
                    let points = eye.filter { $0.x.isFinite && $0.y.isFinite }
                    guard points.count >= 3, let eyeBox = unionBox(points) else { continue }
                    let eyeWidth = Double(eyeBox.width)
                    let eyeHeight = Double(eyeBox.height)
                    let centerX = Double(eyeBox.midX)
                    let centerY = Double(eyeBox.midY) + 0.30 * eyeHeight
                    let radiusX = max(0.004, 0.62 * eyeWidth)
                    let radiusY = max(0.003, 0.55 * eyeHeight)
                    fillEllipse(&coverage, width: width, height: height,
                                centerX: centerX, centerY: centerY,
                                radiusX: radiusX, radiusY: radiusY)
                }
            }
        }
        return try rasterCoverage(coverage, width: width, height: height, extent: extent,
                                  featherFraction: 0.012)
    }

    enum ExtendedGeometricKind {
        case eyeliner
        case eyelash
        case iris
        case catchlight
        case highlight
        case contour
    }

    /// Builds feathered geometric masks for eye enhancements (eyeliner, eyelash, iris, catchlight)
    /// and facial sculpting (highlight, contour).
    static func extendedGeometricMask(faces: [FaceLandmarkSet], extent: CGRect,
                                      kind: ExtendedGeometricKind) throws -> CIImage {
        let scale = min(1, CGFloat(maskRasterDimension) / max(extent.width, extent.height))
        let width = max(8, Int((extent.width * scale).rounded()))
        let height = max(8, Int((extent.height * scale).rounded()))
        var coverage = [Float](repeating: 0, count: width * height)

        for face in faces {
            let box = face.boundingBox
            guard box.width > 0.01, box.height > 0.01 else { continue }
            let faceWidth = Double(box.width)
            let faceHeight = Double(box.height)
            let midX = Double(box.midX)
            let midY = Double(box.midY)

            switch kind {
            case .eyeliner:
                for eye in [face.leftEye, face.rightEye] {
                    let points = eye.filter { $0.x.isFinite && $0.y.isFinite }
                    guard points.count >= 3, let eyeBox = unionBox(points) else { continue }
                    let eyeH = Double(eyeBox.height)
                    let eyeMidY = Double(eyeBox.midY)
                    let upper = points.filter { Double($0.y) >= eyeMidY - 0.10 * eyeH }.sorted { $0.x < $1.x }
                    guard upper.count >= 2 else { continue }
                    let thickness = max(0.003, 0.08 * eyeH)
                    rasterizePolyline(&coverage, width: width, height: height, points: upper, thickness: thickness)
                }

            case .eyelash:
                for eye in [face.leftEye, face.rightEye] {
                    let points = eye.filter { $0.x.isFinite && $0.y.isFinite }
                    guard points.count >= 3, let eyeBox = unionBox(points) else { continue }
                    let eyeH = Double(eyeBox.height)
                    let eyeMidY = Double(eyeBox.midY)
                    let upper = points.filter { Double($0.y) >= eyeMidY - 0.10 * eyeH }.sorted { $0.x < $1.x }
                    guard upper.count >= 2 else { continue }
                    let shifted = upper.map { CGPoint(x: $0.x, y: $0.y + CGFloat(0.06 * eyeH)) }
                    let thickness = max(0.004, 0.14 * eyeH)
                    rasterizePolyline(&coverage, width: width, height: height, points: shifted, thickness: thickness)
                }

            case .iris:
                for (eye, pupil) in [(face.leftEye, face.leftPupil), (face.rightEye, face.rightPupil)] {
                    let points = eye.filter { $0.x.isFinite && $0.y.isFinite }
                    guard points.count >= 3, let eyeBox = unionBox(points) else { continue }
                    let eyeW = Double(eyeBox.width)
                    let eyeH = Double(eyeBox.height)
                    let center = pupil.map { (Double($0.x), Double($0.y)) } ?? (Double(eyeBox.midX), Double(eyeBox.midY))
                    let radiusX = max(0.003, 0.22 * eyeW)
                    let radiusY = max(0.003, 0.35 * eyeH)
                    fillEllipse(&coverage, width: width, height: height,
                                centerX: center.0, centerY: center.1,
                                radiusX: radiusX, radiusY: radiusY)
                }

            case .catchlight:
                for (eye, pupil) in [(face.leftEye, face.leftPupil), (face.rightEye, face.rightPupil)] {
                    let points = eye.filter { $0.x.isFinite && $0.y.isFinite }
                    guard points.count >= 3, let eyeBox = unionBox(points) else { continue }
                    let eyeW = Double(eyeBox.width)
                    let eyeH = Double(eyeBox.height)
                    let p = pupil.map { (Double($0.x), Double($0.y)) } ?? (Double(eyeBox.midX), Double(eyeBox.midY))
                    let cx = p.0 + 0.05 * eyeW
                    let cy = p.1 + 0.08 * eyeH
                    let rX = max(0.002, 0.06 * eyeW)
                    let rY = max(0.002, 0.08 * eyeH)
                    fillEllipse(&coverage, width: width, height: height,
                                centerX: cx, centerY: cy,
                                radiusX: rX, radiusY: rY)
                }

            case .highlight:
                // Forehead center
                fillEllipse(&coverage, width: width, height: height,
                            centerX: midX, centerY: midY + 0.35 * faceHeight,
                            radiusX: 0.12 * faceWidth, radiusY: 0.06 * faceHeight)
                // Nose bridge
                fillEllipse(&coverage, width: width, height: height,
                            centerX: midX, centerY: midY + 0.10 * faceHeight,
                            radiusX: 0.04 * faceWidth, radiusY: 0.12 * faceHeight)
                // Cheek high points
                for side in [-1.0, 1.0] {
                    fillEllipse(&coverage, width: width, height: height,
                                centerX: midX + side * 0.24 * faceWidth,
                                centerY: midY + 0.06 * faceHeight,
                                radiusX: 0.07 * faceWidth, radiusY: 0.05 * faceHeight)
                }

            case .contour:
                // Lower jawline & cheek hollows
                for side in [-1.0, 1.0] {
                    fillEllipse(&coverage, width: width, height: height,
                                centerX: midX + side * 0.38 * faceWidth,
                                centerY: midY - 0.18 * faceHeight,
                                radiusX: 0.12 * faceWidth, radiusY: 0.16 * faceHeight)
                }
                // Chin bottom
                fillEllipse(&coverage, width: width, height: height,
                            centerX: midX, centerY: midY - 0.44 * faceHeight,
                            radiusX: 0.16 * faceWidth, radiusY: 0.05 * faceHeight)
            }
        }

        let feather: Double
        switch kind {
        case .eyeliner: feather = 0.004
        case .eyelash: feather = 0.006
        case .iris: feather = 0.005
        case .catchlight: feather = 0.003
        case .highlight: feather = 0.020
        case .contour: feather = 0.025
        }
        var mask = try rasterCoverage(coverage, width: width, height: height, extent: extent,
                                      featherFraction: feather)

        // For iris and catchlight, clip to eye opening polygons so no effect bleeds outside eyes
        if kind == .iris || kind == .catchlight {
            var eyePolygons: [[CGPoint]] = []
            for face in faces {
                if let left = polygonPoints(face.leftEye) { eyePolygons.append(left) }
                if let right = polygonPoints(face.rightEye) { eyePolygons.append(right) }
            }
            if !eyePolygons.isEmpty {
                let eyeMatte = try polygonCoverageMask(include: eyePolygons, exclude: [], extent: extent)
                mask = try multiplyMasks(mask, eyeMatte, extent: extent)
            }
        }
        return mask
    }

    private static func rasterizePolyline(_ coverage: inout [Float], width: Int, height: Int,
                                          points: [CGPoint], thickness: Double) {
        guard points.count >= 2, thickness > 0 else { return }
        var minX = points[0].x, maxX = points[0].x
        var minY = points[0].y, maxY = points[0].y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = CGFloat(thickness * 1.5)
        let minCol = max(0, Int(((Double(minX - pad)) * Double(width)).rounded(.down)))
        let maxCol = min(width - 1, Int(((Double(maxX + pad)) * Double(width)).rounded(.up)))
        let minR = max(0, Int(((1 - Double(maxY + pad)) * Double(height)).rounded(.down)))
        let maxR = min(height - 1, Int(((1 - Double(minY - pad)) * Double(height)).rounded(.up)))
        guard minCol <= maxCol, minR <= maxR else { return }

        for r in minR...maxR {
            let py = 1 - (Double(r) + 0.5) / Double(height)
            for c in minCol...maxCol {
                let px = (Double(c) + 0.5) / Double(width)
                var minDist = Double.infinity
                for i in 0..<(points.count - 1) {
                    let d = distanceToSegment(px: px, py: py,
                                              x1: Double(points[i].x), y1: Double(points[i].y),
                                              x2: Double(points[i + 1].x), y2: Double(points[i + 1].y))
                    if d < minDist { minDist = d }
                }
                if minDist <= thickness {
                    let val = Float(max(0, min(1, 1.0 - (minDist / thickness))))
                    let idx = r * width + c
                    if val > coverage[idx] { coverage[idx] = val }
                }
            }
        }
    }

    private static func distanceToSegment(px: Double, py: Double,
                                          x1: Double, y1: Double,
                                          x2: Double, y2: Double) -> Double {
        let dx = x2 - x1
        let dy = y2 - y1
        let lenSq = dx * dx + dy * dy
        if lenSq < 1e-12 {
            let rx = px - x1
            let ry = py - y1
            return sqrt(rx * rx + ry * ry)
        }
        let t = max(0, min(1, ((px - x1) * dx + (py - y1) * dy) / lenSq))
        let projX = x1 + t * dx
        let projY = y1 + t * dy
        let rx = px - projX
        let ry = py - projY
        return sqrt(rx * rx + ry * ry)
    }

    /// Fallback lip matte: outer-lip polygon minus inner-lip polygon.
    static func polygonLipMask(faces: [FaceLandmarkSet], extent: CGRect) throws -> CIImage {
        let outer = faces.compactMap { polygonPoints($0.outerLips) }
        let inner = faces.compactMap { polygonPoints($0.innerLips) }
        return try polygonCoverageMask(include: outer, exclude: inner, extent: extent)
    }

    /// Fallback brow matte: eyebrow polygons.
    static func polygonBrowMask(faces: [FaceLandmarkSet], extent: CGRect) throws -> CIImage {
        var polygons: [[CGPoint]] = []
        for face in faces {
            if let left = polygonPoints(face.leftEyebrow) { polygons.append(left) }
            if let right = polygonPoints(face.rightEyebrow) { polygons.append(right) }
        }
        return try polygonCoverageMask(include: polygons, exclude: [], extent: extent)
    }

    // MARK: - Raster helpers

    private static func fillEllipse(_ coverage: inout [Float], width: Int, height: Int,
                                    centerX: Double, centerY: Double,
                                    radiusX: Double, radiusY: Double) {
        guard radiusX.isFinite, radiusY.isFinite, radiusX > 0, radiusY > 0 else { return }
        let minColumn = max(0, Int(((centerX - radiusX) * Double(width)).rounded(.down)))
        let maxColumn = min(width - 1, Int(((centerX + radiusX) * Double(width)).rounded(.up)))
        let minRow = max(0, Int(((1 - centerY - radiusY) * Double(height)).rounded(.down)))
        let maxRow = min(height - 1, Int(((1 - centerY + radiusY) * Double(height)).rounded(.up)))
        guard minColumn <= maxColumn, minRow <= maxRow else { return }
        for row in minRow...maxRow {
            let y = 1 - (Double(row) + 0.5) / Double(height)
            for column in minColumn...maxColumn {
                let x = (Double(column) + 0.5) / Double(width)
                let dx = (x - centerX) / radiusX
                let dy = (y - centerY) / radiusY
                if dx * dx + dy * dy <= 1 {
                    coverage[row * width + column] = 1
                }
            }
        }
    }

    static func polygonCoverageMask(include: [[CGPoint]], exclude: [[CGPoint]],
                                    extent: CGRect) throws -> CIImage {
        let scale = min(1, CGFloat(maskRasterDimension) / max(extent.width, extent.height))
        let width = max(8, Int((extent.width * scale).rounded()))
        let height = max(8, Int((extent.height * scale).rounded()))
        var coverage = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            let y = 1 - (Double(row) + 0.5) / Double(height)
            for column in 0..<width {
                let x = (Double(column) + 0.5) / Double(width)
                let insideInclude = include.contains { polygonContains($0, x: x, y: y) }
                guard insideInclude else { continue }
                let insideExclude = exclude.contains { polygonContains($0, x: x, y: y) }
                if !insideExclude { coverage[row * width + column] = 1 }
            }
        }
        return try rasterCoverage(coverage, width: width, height: height, extent: extent,
                                  featherFraction: 0.010)
    }

    /// Converts a coverage grid to a feathered grayscale CIImage scaled to `extent`.
    /// Row 0 is the top row (Core Image bitmap convention); y is flipped when the
    /// normalized gestures were rasterized.
    private static func rasterCoverage(_ coverage: [Float], width: Int, height: Int,
                                       extent: CGRect,
                                       featherFraction: Double) throws -> CIImage {
        var components = [Float](repeating: 0, count: width * height * 4)
        for index in coverage.indices {
            let value = coverage[index].isFinite ? min(1, max(0, coverage[index])) : 0
            let offset = index * 4
            components[offset] = value
            components[offset + 1] = value
            components[offset + 2] = value
            components[offset + 3] = 1
        }
        let data = components.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        var mask = CIImage(bitmapData: data,
                           bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                           size: CGSize(width: CGFloat(width), height: CGFloat(height)),
                           format: .RGBAf, colorSpace: linearColorSpace)
        let blurRadius = max(0.6, min(6, Double(width) * featherFraction))
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(mask.clampedToExtent(), forKey: kCIInputImageKey)
            blur.setValue(blurRadius, forKey: kCIInputRadiusKey)
            if let blurred = blur.outputImage {
                mask = blurred.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        let scaledX = extent.width / CGFloat(width)
        let scaledY = extent.height / CGFloat(height)
        return mask
            .transformed(by: CGAffineTransform(scaleX: scaledX, y: scaledY))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    static func polygonContains(_ points: [CGPoint], x: Double, y: Double) -> Bool {
        guard points.count >= 3 else { return false }
        var inside = false
        var previous = points[points.count - 1]
        for current in points {
            let xi = Double(current.x), yi = Double(current.y)
            let xj = Double(previous.x), yj = Double(previous.y)
            let intersects = ((yi > y) != (yj > y))
                && (x < (xj - xi) * (y - yi) / ((yj - yi) == 0 ? .leastNonzeroMagnitude : (yj - yi)) + xi)
            if intersects { inside.toggle() }
            previous = current
        }
        return inside
    }

    /// True when a mask actually carries coverage. The semantic analyzer can return
    /// a non-nil but all-zero matte when its colour gate rejects every pixel.
    static func isUsableMask(_ mask: CIImage?) -> Bool {
        guard let mask else { return false }
        let extent = mask.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return false }
        let scale = min(1, CGFloat(64) / max(extent.width, extent.height))
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
            coverageContext.render(sampled, toBitmap: address,
                                   rowBytes: width * 4 * MemoryLayout<Float>.stride,
                                   bounds: bounds, format: .RGBAf,
                                   colorSpace: linearColorSpace)
        }
        var total: Float = 0
        for index in 0..<(width * height) {
            total += max(0, min(1, pixels[index * 4]))
        }
        return total / Float(max(1, width * height)) > 0.0005
    }

    // MARK: - Colour helpers

    /// Converts an sRGB display colour to linear-light components.
    static func linearComponents(of color: SRGBColor) -> (r: Double, g: Double, b: Double) {
        func decode(_ value: Double) -> Double {
            let clamped = min(1, max(0, value))
            return clamped <= 0.04045 ? clamped / 12.92
                : pow((clamped + 0.055) / 1.055, 2.4)
        }
        return (decode(color.red), decode(color.green), decode(color.blue))
    }

    // MARK: - Geometry helpers

    private static func polygonPoints(_ points: [CGPoint]) -> [CGPoint]? {
        let finite = points.filter { $0.x.isFinite && $0.y.isFinite }
        return finite.count >= 3 ? finite : nil
    }

    private static func unionBox(_ points: [CGPoint]) -> CGRect? {
        var box = CGRect.null
        for point in points where point.x.isFinite && point.y.isFinite {
            box = box.union(CGRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        return box.isNull ? nil : box
    }

    static func validExtent(of image: CIImage) throws -> CGRect {
        let extent = image.extent
        guard !extent.isNull, !extent.isInfinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0,
              extent.width <= 100_000, extent.height <= 100_000 else {
            throw AtelierError.invalidConfiguration("妆容输入图像尺寸无效。")
        }
        return extent
    }
}

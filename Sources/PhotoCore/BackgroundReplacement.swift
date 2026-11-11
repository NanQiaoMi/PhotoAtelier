import CoreGraphics
import CoreImage
import Foundation

// MARK: - Colors

/// Display-referred (sRGB-encoded) RGB color in `0...1`, shared by the
/// background fill and the certificate-photo background presets.
public struct SRGBColor: Codable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `#RRGGBB` / `RRGGBB` (case-insensitive). Invalid input returns nil
    /// so callers can fail explicitly instead of silently using black.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.allSatisfy({ $0.isHexDigit }),
              let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    public var hexString: String {
        let r = Int((min(1, max(0, red)) * 255).rounded())
        let g = Int((min(1, max(0, green)) * 255).rounded())
        let b = Int((min(1, max(0, blue)) * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    public func validated() throws -> SRGBColor {
        guard red.isFinite, green.isFinite, blue.isFinite,
              (0...1).contains(red), (0...1).contains(green), (0...1).contains(blue) else {
            throw AtelierError.invalidConfiguration("背景颜色必须在 0...1 的 sRGB 分量范围内。")
        }
        return self
    }
}

/// Standard ID-photo background colors, expressed in sRGB display values.
public enum IDPhotoBackgroundPreset: String, Codable, CaseIterable, Identifiable {
    case white, blue, red, gray

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .white: return "白色"
        case .blue: return "标准蓝"
        case .red: return "标准红"
        case .gray: return "浅灰"
        }
    }

    public var color: SRGBColor {
        switch self {
        case .white: return SRGBColor(red: 1, green: 1, blue: 1)
        case .blue: return SRGBColor(red: 67 / 255, green: 142 / 255, blue: 219 / 255)
        case .red: return SRGBColor(red: 220 / 255, green: 30 / 255, blue: 40 / 255)
        case .gray: return SRGBColor(red: 214 / 255, green: 214 / 255, blue: 214 / 255)
        }
    }
}

// MARK: - Fill

/// Background fill for the person cutout: a solid sRGB color or a local image.
public enum BackgroundFill {
    case color(SRGBColor)
    /// Local image. It is aspect-filled (cropped, never stretched) to the
    /// foreground extent; it must already be loaded by the caller.
    case image(CIImage)

    public static func preset(_ preset: IDPhotoBackgroundPreset) -> BackgroundFill {
        .color(preset.color)
    }
}

// MARK: - Settings

/// Shadow / edge settings for background replacement.
///
/// Shadow geometry uses fractions of the foreground image size, so the same
/// settings look identical on previews and exports. This is a heuristic v1
/// cutout composition, not a commercial matting/relighting product.
public struct BackgroundReplacementSettings: Codable, Equatable {
    public var shadowEnabled: Bool = true
    /// Shadow opacity over the new background (`0...1`).
    public var shadowOpacity: Double = 0.30
    /// Shadow blur as a fraction of the shorter foreground edge (`0...0.5`).
    public var shadowBlur: Double = 0.12
    /// Shadow horizontal offset as a fraction of the foreground width (`-0.5...0.5`).
    public var shadowOffsetX: Double = 0
    /// Shadow vertical offset as a fraction of the foreground height (`-0.5...0.5`).
    /// Negative moves the shadow down in Core Image's bottom-left coordinate space.
    public var shadowOffsetY: Double = -0.035
    /// Edge spill suppression passed to `PersonMatting.decontaminateEdges` (`0...1`).
    public var edgeDecontamination: Double = 0.65

    public init(shadowEnabled: Bool = true,
                shadowOpacity: Double = 0.30,
                shadowBlur: Double = 0.12,
                shadowOffsetX: Double = 0,
                shadowOffsetY: Double = -0.035,
                edgeDecontamination: Double = 0.65) {
        self.shadowEnabled = shadowEnabled
        self.shadowOpacity = shadowOpacity
        self.shadowBlur = shadowBlur
        self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY
        self.edgeDecontamination = edgeDecontamination
    }

    public func validated() throws -> BackgroundReplacementSettings {
        guard shadowOpacity.isFinite, (0...1).contains(shadowOpacity) else {
            throw AtelierError.invalidConfiguration("背景阴影不透明度必须在 0...1 之间。")
        }
        guard shadowBlur.isFinite, (0...0.5).contains(shadowBlur) else {
            throw AtelierError.invalidConfiguration("背景阴影模糊必须在 0...0.5 之间。")
        }
        guard shadowOffsetX.isFinite, (-0.5...0.5).contains(shadowOffsetX),
              shadowOffsetY.isFinite, (-0.5...0.5).contains(shadowOffsetY) else {
            throw AtelierError.invalidConfiguration("背景阴影偏移必须在 -0.5...0.5 之间。")
        }
        guard edgeDecontamination.isFinite, (0...1).contains(edgeDecontamination) else {
            throw AtelierError.invalidConfiguration("背景去色边强度必须在 0...1 之间。")
        }
        return self
    }
}

// MARK: - Replacement

/// Composites a person cutout over a new background with an optional drop shadow.
///
/// Pipeline: edge decontamination → mask foreground → new background (solid color
/// or aspect-filled local image) → optional soft shadow over the background →
/// source-over composite. All geometry is in Core Image pixel coordinates
/// (bottom-left origin); the output keeps the foreground extent and is opaque.
public enum BackgroundReplacement {
    static let sSRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Replaces the background for an existing matte.
    ///
    /// - Throws: `AtelierError.invalidConfiguration` when the matte has no usable
    ///   person, when settings are out of range, or when a Core Image stage fails.
    public static func apply(foreground: CIImage,
                             matte: PersonMatte,
                             fill: BackgroundFill,
                             settings: BackgroundReplacementSettings = BackgroundReplacementSettings()) throws -> CIImage {
        try PersonMatting.requirePerson(matte)
        let settings = try settings.validated()
        let extent = try PersonMatting.validExtent(of: foreground)
        let mask = try alignedMatteMask(matte.mask, to: extent)
        let alignedMatte = PersonMatte(mask: mask, coverage: matte.coverage,
                                       confidence: matte.confidence,
                                       hasPerson: matte.hasPerson, settings: matte.settings)

        var foregroundSource = foreground
        if settings.edgeDecontamination > 0.0001 {
            foregroundSource = try PersonMatting.decontaminateEdges(
                foreground: foreground, matte: alignedMatte,
                strength: settings.edgeDecontamination)
        }

        let background = try makeBackground(fill, extent: extent)
        let backgroundWithShadow = try addShadowIfNeeded(to: background, mask: mask,
                                                         extent: extent, settings: settings)
        let cutout = try maskForeground(foregroundSource, mask: mask, extent: extent)
        guard let composite = CIFilter(name: "CISourceOverCompositing") else {
            throw AtelierError.invalidConfiguration("背景替换合成滤镜不可用。")
        }
        composite.setValue(cutout, forKey: kCIInputImageKey)
        composite.setValue(backgroundWithShadow, forKey: "inputBackgroundImage")
        guard let output = composite.outputImage else {
            throw AtelierError.invalidConfiguration("背景替换无法生成输出。")
        }
        let cropped = output.cropped(to: extent)
        guard !cropped.extent.isNull, cropped.extent.width.isFinite, cropped.extent.height.isFinite else {
            throw AtelierError.invalidConfiguration("背景替换输出尺寸无效。")
        }
        return cropped
    }

    /// Convenience: detect the person and replace the background in one call.
    /// Returns the composite plus the matte used, so callers can report coverage
    /// and confidence.
    public static func replace(foreground: CIImage,
                               fill: BackgroundFill,
                               matteSettings: PersonMatteSettings = PersonMatteSettings(),
                               settings: BackgroundReplacementSettings = BackgroundReplacementSettings(),
                               context: CIContext? = nil) throws -> (image: CIImage, matte: PersonMatte) {
        let matte = try PersonMatting.detect(in: foreground, settings: matteSettings, context: context)
        let image = try apply(foreground: foreground, matte: matte, fill: fill, settings: settings)
        return (image, matte)
    }

    /// Loads a local background image. Only file URLs are supported; no network.
    public static func backgroundImage(contentsOf url: URL) throws -> CIImage {
        guard url.isFileURL else {
            throw AtelierError.invalidConfiguration("背景图片必须是本地文件，不支持网络地址。")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AtelierError.imageRead("背景图片不存在：\(url.lastPathComponent)")
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw AtelierError.imageRead("无法读取背景图片：\(url.lastPathComponent)")
        }
        _ = try PersonMatting.validExtent(of: image)
        return image
    }

    // MARK: Stages

    /// Scales/crops the matte mask when it does not already match the foreground
    /// extent (Vision masks can be returned at a different raster size).
    static func alignedMatteMask(_ mask: CIImage, to extent: CGRect) throws -> CIImage {
        let maskExtent = try PersonMatting.validExtent(of: mask)
        guard abs(maskExtent.width - extent.width) > 0.5
                || abs(maskExtent.height - extent.height) > 0.5
                || abs(maskExtent.minX - extent.minX) > 0.5
                || abs(maskExtent.minY - extent.minY) > 0.5 else {
            return mask
        }
        let aligned = mask
            .transformed(by: CGAffineTransform(translationX: -maskExtent.minX, y: -maskExtent.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width / maskExtent.width,
                                               y: extent.height / maskExtent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        return try PersonMatting.refine(mask: aligned, settings: PersonMatteSettings(
            feather: 0, edgeSoftness: 0.25, edgeDecontamination: 0, minimumCoverage: 0))
    }

    private static func makeBackground(_ fill: BackgroundFill, extent: CGRect) throws -> CIImage {
        switch fill {
        case .color(let color):
            let validated = try color.validated()
            let ciColor = CIColor(red: CGFloat(validated.red), green: CGFloat(validated.green),
                                  blue: CGFloat(validated.blue), alpha: 1,
                                  colorSpace: sSRGBColorSpace)!
            return CIImage(color: ciColor).cropped(to: extent)
        case .image(let image):
            let imageExtent = try PersonMatting.validExtent(of: image)
            let scale = max(extent.width / imageExtent.width,
                            extent.height / imageExtent.height)
            let scaledWidth = imageExtent.width * scale
            let scaledHeight = imageExtent.height * scale
            let offsetX = extent.minX + (extent.width - scaledWidth) / 2
            let offsetY = extent.minY + (extent.height - scaledHeight) / 2
            return image
                .transformed(by: CGAffineTransform(translationX: -imageExtent.minX,
                                                   y: -imageExtent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
                .cropped(to: extent)
        }
    }

    /// Builds a black, translucent shadow from the matte and composites it over
    /// the background (shadow sits behind the foreground cutout).
    private static func addShadowIfNeeded(to background: CIImage,
                                          mask: CIImage,
                                          extent: CGRect,
                                          settings: BackgroundReplacementSettings) throws -> CIImage {
        guard settings.shadowEnabled, settings.shadowOpacity > 0.0001 else { return background }
        var shadow = mask
        let offsetX = CGFloat(settings.shadowOffsetX) * extent.width
        let offsetY = CGFloat(settings.shadowOffsetY) * extent.height
        if abs(offsetX) > 0.01 || abs(offsetY) > 0.01 {
            shadow = shadow.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
        }
        let blurRadius = CGFloat(settings.shadowBlur) * min(extent.width, extent.height) * 0.1
        if blurRadius > 0.5, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(shadow.clampedToExtent(), forKey: kCIInputImageKey)
            blur.setValue(blurRadius, forKey: kCIInputRadiusKey)
            if let blurred = blur.outputImage {
                shadow = blurred.cropped(to: extent)
            }
        }
        shadow = shadow.cropped(to: extent)
        guard let matrix = CIFilter(name: "CIColorMatrix") else {
            throw AtelierError.invalidConfiguration("背景阴影调色矩阵不可用。")
        }
        let opacity = CGFloat(settings.shadowOpacity)
        matrix.setValue(shadow, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        // Matting mask RGB carries coverage; alpha = coverage × opacity.
        matrix.setValue(CIVector(x: opacity, y: 0, z: 0, w: 0), forKey: "inputAVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        guard let shadowImage = matrix.outputImage else {
            throw AtelierError.invalidConfiguration("背景阴影无法生成。")
        }
        guard let composite = CIFilter(name: "CISourceOverCompositing") else {
            throw AtelierError.invalidConfiguration("背景阴影合成滤镜不可用。")
        }
        composite.setValue(shadowImage.cropped(to: extent), forKey: kCIInputImageKey)
        composite.setValue(background, forKey: "inputBackgroundImage")
        guard let output = composite.outputImage else {
            throw AtelierError.invalidConfiguration("背景阴影合成无法生成输出。")
        }
        return output.cropped(to: extent)
    }

    private static func maskForeground(_ foreground: CIImage, mask: CIImage,
                                       extent: CGRect) throws -> CIImage {
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0,
                                           colorSpace: sSRGBColorSpace)!).cropped(to: extent)
        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            throw AtelierError.invalidConfiguration("人物蒙版合成滤镜不可用。")
        }
        blend.setValue(foreground, forKey: kCIInputImageKey)
        blend.setValue(clear, forKey: "inputBackgroundImage")
        blend.setValue(mask, forKey: "inputMaskImage")
        guard let output = blend.outputImage else {
            throw AtelierError.invalidConfiguration("人物蒙版合成无法生成输出。")
        }
        return output.cropped(to: extent)
    }
}

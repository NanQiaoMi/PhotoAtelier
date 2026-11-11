import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO

/// Where a watermark sits on the canvas.
///
/// Anchors are named as the viewer sees the exported image: `top` is the upper
/// edge of the rendered picture. Core Image extents use a bottom-left origin, so
/// a "top" anchor maps to the larger Y side of the canvas; tests assert the
/// rendered CGImage rows, where row 0 is the visual top.
public enum WatermarkAnchor: String, Codable, Equatable, CaseIterable {
    case topLeft, topCenter, topRight
    case centerLeft, center, centerRight
    case bottomLeft, bottomCenter, bottomRight
}

/// Offset in fractions of the canvas size, added after the 9-grid anchor.
///
/// `x > 0` moves right, `y > 0` moves up (Core Image's Y-up convention). Values
/// are clamped by the renderer so the whole watermark stays inside the canvas.
public struct WatermarkOffset: Codable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

/// An sRGB colour component triple in `0...1`. Alpha is carried separately by
/// the watermark opacity / shadow opacity so the same colour can be reused.
public struct WatermarkColor: Codable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = WatermarkColor(red: 1, green: 1, blue: 1)
    public static let black = WatermarkColor(red: 0, green: 0, blue: 0)

    /// `nil` only when the system cannot create the sRGB colour space.
    fileprivate func cgColor(alpha: Double) -> CGColor? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGColor(colorSpace: space,
                       components: [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)])
    }

    fileprivate func validate(named name: String) throws {
        for (component, label) in [(red, "红"), (green, "绿"), (blue, "蓝")] {
            guard component.isFinite, (0...1).contains(component) else {
                throw AtelierError.invalidConfiguration("\(name)的\(label)色分量必须在 0...1 之间。")
            }
        }
    }
}

/// Optional drop shadow. Offsets and blur are fractions of the canvas' shorter
/// edge so the look is independent of the export resolution.
public struct WatermarkShadow: Codable, Equatable {
    public var color: WatermarkColor
    public var opacity: Double
    public var offset: WatermarkOffset
    public var blurFraction: Double

    public init(color: WatermarkColor = .black,
                opacity: Double = 0.55,
                offset: WatermarkOffset = WatermarkOffset(x: 0.004, y: -0.004),
                blurFraction: Double = 0.006) {
        self.color = color
        self.opacity = opacity
        self.offset = offset
        self.blurFraction = blurFraction
    }
}

/// Optional outline. Only used by text watermarks; image watermarks ignore it.
/// `widthPercent` follows Core Text's stroke-width convention: a percentage of
/// the font size, drawn outside the glyph fill as well (fill + stroke).
public struct WatermarkStroke: Codable, Equatable {
    public var color: WatermarkColor
    public var widthPercent: Double

    public init(color: WatermarkColor = .black, widthPercent: Double = 3) {
        self.color = color
        self.widthPercent = widthPercent
    }
}

/// Codable watermark description stored in a v11 recipe / export settings.
///
/// The renderer is a pure Core Image graph builder: it never writes files, never
/// touches AppKit and never reads the network. Text is typeset with Core Text
/// into a transparent RGBA bitmap and composited over the picture; image
/// watermarks are decoded locally through ImageIO (PNG/JPEG and anything else
/// the local system decodes) and keep their alpha channel.
///
/// Boundaries (deliberately explicit):
/// - Single line, no wrapping, no rich text. This is a watermark, not a page
///   layout / typesetting tool.
/// - Fonts come from the local system. The system font is used when
///   `fontName` is nil; an unknown name falls back to Core Text's substitution.
///   Glyph metrics therefore depend on the machine's installed fonts, which is
///   acceptable for watermarks but means layout is not byte-identical across
///   different macOS versions with different system fonts.
/// - Colours are sRGB component values. Alpha compositing happens in the
///   caller's Core Image working colour space, so a semi-transparent watermark
///   blends in that space (the pipeline uses extended linear sRGB).
/// - Image watermarks are local files only; a missing or undecodable file is an
///   explicit error instead of silently dropping the watermark.
public struct WatermarkSettings: Codable, Equatable {
    public enum Kind: String, Codable, Equatable {
        case text
        case image
    }

    public var kind: Kind
    /// Text content for `.text`. Ignored for `.image`.
    public var text: String
    /// Local file path for `.image` (PNG/JPEG/... via ImageIO). Ignored for `.text`.
    public var imagePath: String?
    public var anchor: WatermarkAnchor
    /// Extra offset after the anchor, in fractions of the canvas.
    public var offset: WatermarkOffset
    /// Inset from the canvas edge for the 9-grid anchors, fraction of the
    /// canvas' shorter edge (`0...0.3`).
    public var marginFraction: Double
    /// Global alpha `0...1`. `0` (or negative) is a documented no-op.
    public var opacity: Double
    /// Size multiplier. Text base size is `0.05 * min(canvas) * scale`; image
    /// base width is `0.18 * min(canvas) * scale`; both shrink to fit the canvas.
    public var scale: Double
    /// Rotation around the watermark's own centre, degrees, positive = counter-
    /// clockwise in Core Image's image coordinates.
    public var rotationDegrees: Double
    /// Text colour (sRGB). Ignored for image watermarks.
    public var color: WatermarkColor
    /// Optional local font family name for text watermarks; nil = system font.
    public var fontName: String?
    public var shadow: WatermarkShadow?
    /// Text outline; ignored for image watermarks.
    public var stroke: WatermarkStroke?

    public init(kind: Kind = .text,
                text: String = "",
                imagePath: String? = nil,
                anchor: WatermarkAnchor = .bottomRight,
                offset: WatermarkOffset = WatermarkOffset(),
                marginFraction: Double = 0.025,
                opacity: Double = 0.85,
                scale: Double = 1,
                rotationDegrees: Double = 0,
                color: WatermarkColor = .white,
                fontName: String? = nil,
                shadow: WatermarkShadow? = nil,
                stroke: WatermarkStroke? = nil) {
        self.kind = kind
        self.text = text
        self.imagePath = imagePath
        self.anchor = anchor
        self.offset = offset
        self.marginFraction = marginFraction
        self.opacity = opacity
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.color = color
        self.fontName = fontName
        self.shadow = shadow
        self.stroke = stroke
    }

    /// True when the settings cannot change pixels (opacity is zero or negative).
    /// Neutral settings are a no-op: the renderer returns the input image object
    /// unchanged, so a disabled watermark never costs a render or errors out.
    public var isNeutral: Bool {
        opacity.isFinite && opacity <= 0
    }

    /// Structural validation for recipe loading / UI commit. File existence and
    /// decodability are checked by the renderer so a recipe can be stored before
    /// the local watermark file is available, but an actual render reports the
    /// missing file explicitly.
    public func validate() throws {
        guard opacity.isFinite, (0...1).contains(opacity) else {
            throw AtelierError.invalidConfiguration("水印透明度必须在 0...1 之间。")
        }
        guard scale.isFinite, (0.02...20).contains(scale) else {
            throw AtelierError.invalidConfiguration("水印缩放必须在 0.02...20 之间。")
        }
        guard rotationDegrees.isFinite, (-180...180).contains(rotationDegrees) else {
            throw AtelierError.invalidConfiguration("水印旋转必须在 -180...180 度之间。")
        }
        guard marginFraction.isFinite, (0...0.3).contains(marginFraction) else {
            throw AtelierError.invalidConfiguration("水印边距必须在 0...0.3 之间（画布短边的比例）。")
        }
        guard offset.x.isFinite, offset.y.isFinite, (-1...1).contains(offset.x), (-1...1).contains(offset.y) else {
            throw AtelierError.invalidConfiguration("水印自定义偏移必须在 -1...1 之间（画布比例）。")
        }
        try color.validate(named: "水印文字颜色")
        switch kind {
        case .text:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AtelierError.invalidConfiguration("水印文字不能为空。")
            }
        case .image:
            guard let path = imagePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                throw AtelierError.invalidConfiguration("图片水印缺少图片路径。")
            }
        }
        if let shadow = shadow {
            guard shadow.opacity.isFinite, (0...1).contains(shadow.opacity) else {
                throw AtelierError.invalidConfiguration("水印阴影不透明度必须在 0...1 之间。")
            }
            guard shadow.blurFraction.isFinite, (0...0.2).contains(shadow.blurFraction) else {
                throw AtelierError.invalidConfiguration("水印阴影模糊必须在 0...0.2 之间（画布短边的比例）。")
            }
            guard shadow.offset.x.isFinite, shadow.offset.y.isFinite,
                  (-1...1).contains(shadow.offset.x), (-1...1).contains(shadow.offset.y) else {
                throw AtelierError.invalidConfiguration("水印阴影偏移必须在 -1...1 之间（画布比例）。")
            }
            try shadow.color.validate(named: "水印阴影颜色")
        }
        if let stroke = stroke {
            guard stroke.widthPercent.isFinite, (0...20).contains(stroke.widthPercent) else {
                throw AtelierError.invalidConfiguration("水印描边宽度必须在 0...20（字号百分比）之间。")
            }
            try stroke.color.validate(named: "水印描边颜色")
        }
    }
}

/// The two images a batch export needs: the untouched picture and the
/// watermarked one. Both are lazy Core Image graphs; nothing is rendered or
/// written until the caller asks for pixels.
public struct WatermarkVersions {
    /// The input image, unchanged (no watermark graph attached).
    public let plain: CIImage
    /// The input image with the watermark composited on top.
    public let watermarked: CIImage
    /// False when no watermark was applied (nil / neutral settings).
    public let applied: Bool

    public init(plain: CIImage, watermarked: CIImage, applied: Bool) {
        self.plain = plain
        self.watermarked = watermarked
        self.applied = applied
    }
}

/// Pure watermark composition for exports.
///
/// `WatermarkRenderer` only builds Core Image graphs. The caller supplies the
/// canvas extent (normally `image.extent`, or the resized export extent) and
/// renders with its own `CIContext`, so export keeps owning colour space,
/// metadata and file writing. The renderer is deterministic for identical
/// settings on the same machine and never mutates the input image.
public enum WatermarkRenderer {
    /// Text watermark font size as a fraction of the canvas' shorter edge at
    /// `scale == 1`.
    public static let textSizeFraction = 0.05
    /// Image watermark width as a fraction of the canvas' shorter edge at
    /// `scale == 1`.
    public static let imageWidthFraction = 0.18
    /// Maximum fraction of the canvas a watermark may occupy (width and height of
    /// the *rotated* bounding box). Larger text/images are shrunk to fit instead of
    /// being clipped by the export crop.
    public static let maximumCanvasFraction = 0.92

    // MARK: - Public API

    /// Returns a copy of `image` with the watermark composited on top.
    ///
    /// The watermark is fitted to the rotated bounding box before placement, and a
    /// post-rotation safety fit guarantees it is never silently clipped at a canvas
    /// edge (at most `maximumCanvasFraction` of the canvas is used).
    ///
    /// - Parameters:
    ///   - image: the picture to watermark; never mutated.
    ///   - canvasExtent: the placement rectangle (normally `image.extent`).
    ///   - settings: watermark description. Neutral settings return `image`
    ///     unchanged. Invalid settings throw `AtelierError.invalidConfiguration`;
    ///     missing/undecodable image files throw `AtelierError.imageRead`.
    public static func render(on image: CIImage,
                              canvasExtent: CGRect,
                              settings: WatermarkSettings) throws -> CIImage {
        guard isUsable(rect: image.extent) else {
            throw AtelierError.invalidConfiguration("水印底图尺寸无效，无法叠加水印。")
        }
        guard isUsable(rect: canvasExtent) else {
            throw AtelierError.invalidConfiguration("水印画布尺寸无效，无法叠加水印。")
        }
        if settings.isNeutral { return image }
        try settings.validate()
        let content = try makeContent(settings, canvas: canvasExtent)
        let opaque = applyOpacity(content, opacity: settings.opacity)
        let rotated = rotate(opaque, degrees: settings.rotationDegrees)
        let fitted = fitInsideCanvas(rotated, canvas: canvasExtent)
        let placed = place(fitted, settings: settings, canvas: canvasExtent)
        return placed.composited(over: image).cropped(to: canvasExtent)
    }

    /// Convenience overload using `image.extent` as the canvas.
    public static func render(on image: CIImage,
                              settings: WatermarkSettings) throws -> CIImage {
        try render(on: image, canvasExtent: image.extent, settings: settings)
    }

    /// Builds both export versions in one call: the untouched picture and the
    /// watermarked picture. Use this for "export with and without watermark"
    /// batches; `plain` keeps the original object so no watermark graph is
    /// attached when only the clean version is needed.
    public static func renderVersions(on image: CIImage,
                                      canvasExtent: CGRect,
                                      settings: WatermarkSettings?) throws -> WatermarkVersions {
        guard let settings, !settings.isNeutral else {
            return WatermarkVersions(plain: image, watermarked: image, applied: false)
        }
        let watermarked = try render(on: image, canvasExtent: canvasExtent, settings: settings)
        return WatermarkVersions(plain: image, watermarked: watermarked, applied: true)
    }

    /// Convenience overload using `image.extent` as the canvas.
    public static func renderVersions(on image: CIImage,
                                      settings: WatermarkSettings?) throws -> WatermarkVersions {
        try renderVersions(on: image, canvasExtent: image.extent, settings: settings)
    }

    /// True when `renderVersions` would attach a watermark graph.
    public static func shouldApply(_ settings: WatermarkSettings?) -> Bool {
        guard let settings else { return false }
        return !settings.isNeutral
    }

    // MARK: - Content

    private static func makeContent(_ settings: WatermarkSettings,
                                    canvas: CGRect) throws -> CIImage {
        switch settings.kind {
        case .text: return try makeTextContent(settings, canvas: canvas)
        case .image: return try makeImageContent(settings, canvas: canvas)
        }
    }

    // MARK: - Text

    private static func makeTextContent(_ settings: WatermarkSettings,
                                        canvas: CGRect) throws -> CIImage {
        let minDimension = min(canvas.width, canvas.height)
        let maximumWidth = canvas.width * maximumCanvasFraction
        let maximumHeight = canvas.height * maximumCanvasFraction
        var fontSize = max(1, minDimension * textSizeFraction * CGFloat(settings.scale))
        var metrics = try textMetrics(settings, fontSize: fontSize)
        var bitmapSize = textBitmapSize(metrics, settings: settings, canvas: canvas)
        // The *rotated* bounding box has to fit the canvas, not just the upright
        // bitmap: a 92%-wide line rotated by 90 degrees would otherwise be clipped
        // when composited. Re-measure up to a few times; glyph advances are linear
        // in the font size, so this converges quickly. Only the final bitmap is
        // rasterised, so fitting does not cost extra font rendering.
        for _ in 0..<8 {
            let rotated = rotatedBoundingSize(bitmapSize, degrees: settings.rotationDegrees)
            let fitsWidth = rotated.width <= maximumWidth
            let fitsHeight = rotated.height <= maximumHeight
            let fitsBitmap = bitmapSize.width <= 20_000 && bitmapSize.height <= 20_000
            if fitsWidth && fitsHeight && fitsBitmap { break }
            let widthRatio = maximumWidth / max(rotated.width, 1)
            let heightRatio = maximumHeight / max(rotated.height, 1)
            let pixelRatio = min(20_000 / max(bitmapSize.width, 1),
                                 20_000 / max(bitmapSize.height, 1))
            let factor = min(1, min(widthRatio, min(heightRatio, pixelRatio))) * 0.98
            fontSize = max(1, fontSize * max(0.05, factor))
            metrics = try textMetrics(settings, fontSize: fontSize)
            bitmapSize = textBitmapSize(metrics, settings: settings, canvas: canvas)
            if fontSize <= 1 { break }
        }
        let image = try renderTextBitmap(metrics, settings: settings, canvas: canvas,
                                         pixelSize: bitmapSize)
        return CIImage(cgImage: image)
    }

    private struct TextMetrics {
        let line: CTLine
        let fontSize: CGFloat
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let leading: CGFloat
    }

    private static func textMetrics(_ settings: WatermarkSettings,
                                    fontSize: CGFloat) throws -> TextMetrics {
        let font = makeFont(name: settings.fontName, size: fontSize)
        guard let fillColor = settings.color.cgColor(alpha: 1) else {
            throw AtelierError.invalidConfiguration("无法创建水印文字颜色。")
        }
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): fillColor
        ]
        if let stroke = settings.stroke, stroke.widthPercent > 0,
           let strokeColor = stroke.color.cgColor(alpha: 1) {
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = strokeColor
            // Core Text: a negative width means "fill and stroke".
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] =
                NSNumber(value: -abs(stroke.widthPercent))
        }
        let attributed = NSAttributedString(string: settings.text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        guard width.isFinite, width > 0.5, ascent.isFinite, descent.isFinite, leading.isFinite,
              ascent + descent + leading > 0 else {
            throw AtelierError.invalidConfiguration("水印文字无法排版（系统字体不可用或文字为空）。")
        }
        return TextMetrics(line: line, fontSize: fontSize, width: width,
                           ascent: ascent, descent: descent, leading: leading)
    }

    /// Pixel size of the transparent text bitmap including stroke/shadow padding.
    private static func textBitmapSize(_ metrics: TextMetrics,
                                       settings: WatermarkSettings,
                                       canvas: CGRect) -> CGSize {
        let padding = textPadding(metrics, settings: settings, canvas: canvas)
        return CGSize(width: ceil(metrics.width + padding * 2),
                      height: ceil(metrics.ascent + metrics.descent + metrics.leading + padding * 2))
    }

    private static func textPadding(_ metrics: TextMetrics,
                                    settings: WatermarkSettings,
                                    canvas: CGRect) -> CGFloat {
        let minDimension = min(canvas.width, canvas.height)
        let strokeWidth = CGFloat(settings.stroke?.widthPercent ?? 0) / 100 * metrics.fontSize
        let shadowOffsetX = CGFloat(abs(settings.shadow?.offset.x ?? 0)) * minDimension
        let shadowOffsetY = CGFloat(abs(settings.shadow?.offset.y ?? 0)) * minDimension
        let shadowBlur = CGFloat(settings.shadow?.blurFraction ?? 0) * minDimension
        return ceil(metrics.fontSize * 0.25 + strokeWidth + shadowOffsetX + shadowOffsetY
                    + shadowBlur * 1.5) + 2
    }

    private static func renderTextBitmap(_ metrics: TextMetrics,
                                         settings: WatermarkSettings,
                                         canvas: CGRect,
                                         pixelSize: CGSize) throws -> CGImage {
        let pixelWidth = Int(pixelSize.width)
        let pixelHeight = Int(pixelSize.height)
        guard pixelWidth > 0, pixelWidth <= 20_000, pixelHeight > 0, pixelHeight <= 20_000,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: pixelWidth,
                                      height: pixelHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AtelierError.imageWrite("水印文字位图创建失败。")
        }
        let minDimension = min(canvas.width, canvas.height)
        let shadowBlur = CGFloat(settings.shadow?.blurFraction ?? 0) * minDimension
        let padding = textPadding(metrics, settings: settings, canvas: canvas)
        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)
        context.interpolationQuality = .high
        context.textMatrix = .identity
        if let shadow = settings.shadow, shadow.opacity > 0,
           shadow.blurFraction > 0 || shadow.offset.x != 0 || shadow.offset.y != 0,
           let shadowColor = shadow.color.cgColor(alpha: shadow.opacity) {
            context.setShadow(offset: CGSize(width: CGFloat(shadow.offset.x) * minDimension,
                                             height: CGFloat(shadow.offset.y) * minDimension),
                              blur: shadowBlur,
                              color: shadowColor)
        }
        context.textPosition = CGPoint(x: padding, y: padding + metrics.descent)
        CTLineDraw(metrics.line, context)
        guard let image = context.makeImage() else {
            throw AtelierError.imageWrite("水印文字位图创建失败。")
        }
        return image
    }

    /// System font by default; a caller-supplied family name is used when Core
    /// Text can resolve it, otherwise Core Text substitutes a local font.
    private static func makeFont(name: String?, size: CGFloat) -> CTFont {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return CTFontCreateWithName(name as CFString, size, nil)
        }
        if let font = CTFontCreateUIFontForLanguage(.system, size, nil) {
            return font
        }
        return CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    // MARK: - Image

    private static func makeImageContent(_ settings: WatermarkSettings,
                                         canvas: CGRect) throws -> CIImage {
        guard let rawPath = settings.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            throw AtelierError.invalidConfiguration("图片水印缺少图片路径。")
        }
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AtelierError.imageRead("水印图片不存在：\(url.path)")
        }
        guard let loaded = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw AtelierError.imageRead("无法解码水印图片：\(url.path)")
        }
        guard isUsable(rect: loaded.extent) else {
            throw AtelierError.imageRead("水印图片尺寸无效：\(url.path)")
        }

        let minDimension = min(canvas.width, canvas.height)
        let maximumWidth = canvas.width * maximumCanvasFraction
        let maximumHeight = canvas.height * maximumCanvasFraction
        let aspect = loaded.extent.height / loaded.extent.width
        // Fit the rotated bounding box, not just the upright image: a wide
        // watermark rotated by 90 degrees is tall on screen, so it must be sized
        // so the rotated box still fits (otherwise the export would clip it).
        let radians = rotationRadians(settings.rotationDegrees)
        let cosine = abs(cos(radians))
        let sine = abs(sin(radians))
        let widthFactor = max(cosine + aspect * sine, 0.0001)
        let heightFactor = max(sine + aspect * cosine, 0.0001)
        var targetWidth = minDimension * imageWidthFraction * CGFloat(settings.scale)
        targetWidth = min(targetWidth, maximumWidth / widthFactor, maximumHeight / heightFactor)
        targetWidth = max(1, targetWidth)

        let scale = targetWidth / loaded.extent.width
        let scaled: CIImage
        if let filter = CIFilter(name: "CILanczosScaleTransform") {
            filter.setValue(loaded, forKey: kCIInputImageKey)
            filter.setValue(scale, forKey: kCIInputScaleKey)
            filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
            guard let output = filter.outputImage else {
                throw AtelierError.imageWrite("水印图片缩放失败：\(url.path)")
            }
            scaled = output
        } else {
            scaled = loaded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let normalized = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX,
                                                                  y: -scaled.extent.minY))

        guard let shadow = dropShadow(for: normalized, settings: settings, canvas: canvas) else {
            return normalized
        }
        return normalized.composited(over: shadow)
    }

    /// Drop shadow for image watermarks: a colourised copy of the watermark
    /// silhouette, blurred and offset behind the picture.
    ///
    /// `CIColorMatrix` is used only to build the alpha mask (its RGB vectors act
    /// on unpremultiplied colour, so tinting through the matrix would square the
    /// shadow opacity). The shadow colour is then applied with
    /// `CISourceInCompositing`, which multiplies an opaque colour image by the
    /// mask's alpha and keeps premultiplied semantics correct.
    private static func dropShadow(for image: CIImage,
                                   settings: WatermarkSettings,
                                   canvas: CGRect) -> CIImage? {
        guard let shadow = settings.shadow, shadow.opacity > 0,
              let shadowColor = CIColor(red: CGFloat(shadow.color.red),
                                        green: CGFloat(shadow.color.green),
                                        blue: CGFloat(shadow.color.blue),
                                        alpha: 1,
                                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            return nil
        }
        let minDimension = min(canvas.width, canvas.height)
        let blur = CGFloat(max(0, shadow.blurFraction)) * minDimension
        // Shadow offsets follow the same "fraction of the shorter canvas edge"
        // rule as blur and as the text path, so one WatermarkShadow looks the
        // same for text and image watermarks on non-square canvases.
        let offsetX = CGFloat(shadow.offset.x) * minDimension
        let offsetY = CGFloat(shadow.offset.y) * minDimension
        guard blur > 0.1 || offsetX != 0 || offsetY != 0 else { return nil }
        guard let matrix = CIFilter(name: "CIColorMatrix") else { return nil }
        let opacity = CGFloat(shadow.opacity)
        matrix.setValue(image, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: opacity), forKey: "inputAVector")
        guard let mask = matrix.outputImage else { return nil }
        let colorImage = CIImage(color: shadowColor).cropped(to: image.extent)
        var silhouette = colorImage.applyingFilter("CISourceInCompositing",
                                                   parameters: [kCIInputBackgroundImageKey: mask])
        if blur > 0.1 {
            silhouette = silhouette.applyingFilter("CIGaussianBlur",
                                                   parameters: [kCIInputRadiusKey: blur])
        }
        silhouette = silhouette.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
        return silhouette
    }

    // MARK: - Shared stages

    /// Applies the global opacity by scaling the alpha channel only.
    ///
    /// `CIColorMatrix` operates on unpremultiplied colour components, so scaling
    /// RGB as well would fade the colour twice (red at 50% would composite as
    /// 25% red). Scaling only alpha keeps the colour and relies on Core Image's
    /// premultiplication to produce exactly `opacity * watermark` over the
    /// picture.
    private static func applyOpacity(_ image: CIImage, opacity: Double) -> CIImage {
        guard opacity < 0.9999 else { return image }
        guard let matrix = CIFilter(name: "CIColorMatrix") else { return image }
        let alpha = CGFloat(max(0, min(1, opacity)))
        matrix.setValue(image, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: alpha), forKey: "inputAVector")
        return matrix.outputImage ?? image
    }

    /// Rotation angle in radians for the Core Image Y-up coordinate system.
    private static func rotationRadians(_ degrees: Double) -> CGFloat {
        CGFloat(degrees * .pi / 180)
    }

    /// Axis-aligned bounding box of `size` after rotating it by `degrees`.
    ///
    /// Used by both content builders to size the watermark so its *rotated* box
    /// fits the canvas (`|w·cos| + |h·sin|` by `|w·sin| + |h·cos|`), which is what
    /// prevents a vertical rotation from clipping a wide/long watermark.
    private static func rotatedBoundingSize(_ size: CGSize, degrees: Double) -> CGSize {
        let radians = rotationRadians(degrees)
        let cosine = abs(cos(radians))
        let sine = abs(sin(radians))
        return CGSize(width: size.width * cosine + size.height * sine,
                      height: size.width * sine + size.height * cosine)
    }

    /// Safety net applied after rotation: if the rotated watermark still exceeds
    /// `maximumCanvasFraction` of the canvas (for example when vertex/font metrics
    /// differ from the measured bitmap bounds), shrink it uniformly around its
    /// origin so `place` + cropping can never silently cut a glyph or logo edge.
    private static func fitInsideCanvas(_ content: CIImage, canvas: CGRect) -> CIImage {
        let size = content.extent.size
        guard size.width > 0.5, size.height > 0.5 else { return content }
        let maximumWidth = canvas.width * maximumCanvasFraction
        let maximumHeight = canvas.height * maximumCanvasFraction
        let factor = min(1, min(maximumWidth / size.width, maximumHeight / size.height))
        guard factor < 0.999 else { return content }
        let scaled = content.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        return scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX,
                                                        y: -scaled.extent.minY))
    }

    /// Rotates around the content centre, degrees counter-clockwise in Core
    /// Image's Y-up coordinates. The rotated extent is refitted/normalised by
    /// `fitInsideCanvas` and `place`.
    private static func rotate(_ image: CIImage, degrees: Double) -> CIImage {
        guard abs(degrees) > 0.0001 else { return image }
        let radians = rotationRadians(degrees)
        let center = CGPoint(x: image.extent.midX, y: image.extent.midY)
        let cosValue = cos(radians)
        let sinValue = sin(radians)
        let transform = CGAffineTransform(
            a: cosValue,
            b: sinValue,
            c: -sinValue,
            d: cosValue,
            tx: center.x - cosValue * center.x + sinValue * center.y,
            ty: center.y - sinValue * center.x - cosValue * center.y
        )
        return image.transformed(by: transform)
    }

    /// Anchors the (already rotated) content on the canvas, applies the custom
    /// offset and clamps it so no part of the watermark leaves the canvas.
    private static func place(_ content: CIImage,
                              settings: WatermarkSettings,
                              canvas: CGRect) -> CIImage {
        let size = content.extent.size
        let minDimension = min(canvas.width, canvas.height)
        let margin = CGFloat(min(max(settings.marginFraction, 0), 0.3)) * minDimension
        var inset = canvas.insetBy(dx: margin, dy: margin)
        if inset.width <= 1 || inset.height <= 1 { inset = canvas }
        var x: CGFloat
        var y: CGFloat
        switch settings.anchor {
        case .topLeft:
            x = inset.minX; y = inset.maxY - size.height
        case .topCenter:
            x = inset.midX - size.width / 2; y = inset.maxY - size.height
        case .topRight:
            x = inset.maxX - size.width; y = inset.maxY - size.height
        case .centerLeft:
            x = inset.minX; y = inset.midY - size.height / 2
        case .center:
            x = inset.midX - size.width / 2; y = inset.midY - size.height / 2
        case .centerRight:
            x = inset.maxX - size.width; y = inset.midY - size.height / 2
        case .bottomLeft:
            x = inset.minX; y = inset.minY
        case .bottomCenter:
            x = inset.midX - size.width / 2; y = inset.minY
        case .bottomRight:
            x = inset.maxX - size.width; y = inset.minY
        }
        x += CGFloat(settings.offset.x) * canvas.width
        y += CGFloat(settings.offset.y) * canvas.height
        let maximumX = max(canvas.minX, canvas.maxX - size.width)
        let maximumY = max(canvas.minY, canvas.maxY - size.height)
        x = min(max(x, canvas.minX), maximumX)
        y = min(max(y, canvas.minY), maximumY)
        return content.transformed(by: CGAffineTransform(translationX: x - content.extent.minX,
                                                         y: y - content.extent.minY))
    }

    private static func isUsable(rect: CGRect) -> Bool {
        rect.width.isFinite && rect.height.isFinite
            && rect.width > 0.5 && rect.height > 0.5
            && rect.width <= 100_000 && rect.height <= 100_000
    }
}

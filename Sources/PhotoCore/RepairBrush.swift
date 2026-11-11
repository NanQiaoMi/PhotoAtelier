import CoreGraphics
import CoreImage
import Foundation

/// A manual repair brush mode.
///
/// - `heal`: heuristic neighbourhood repair. The covered pixels are replaced by a
///   low-frequency estimate of the surrounding image plus texture sampled from an
///   automatically chosen nearby clean patch. It is **not** generative inpainting
///   and it cannot reconstruct structure that is not present nearby.
/// - `clone`: copies pixels verbatim from a user-chosen source offset. The result
///   is exactly what the stamp sampled; colour/structure matching is the user's
///   responsibility (classic clone-stamp semantics).
public enum RepairBrushMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case heal, clone

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .heal: return "修补"
        case .clone: return "仿制"
        }
    }
}

/// One manual repair-brush stroke stored in a recipe (data layer, undoable).
///
/// Coordinates use the same convention as the rest of PhotoCore: normalised to
/// the *corrected image extent*, origin at the bottom-left (Core Image axes),
/// `(0,0)` bottom-left, `(1,1)` top-right. The renderer clamps the rasterizer to
/// the image canvas, so points outside `0...1` are simply clipped.
///
/// - `radius` is the brush radius as a fraction of the image's **shorter edge**
///   (`pixelRadius = radius × min(width, height)`), documented explicitly so it is
///   not confused with the per-axis ellipse used by liquify strokes.
/// - `feather` is the soft-edge width `0...1` relative to the radius.
/// - `strength` is the blend amount `0...1` (`0` is a documented no-op).
/// - `cloneOffset` is only used by `.clone`: normalised source offset in image
///   fractions (`+x` right, `+y` up). The sampled source is
///   `target + cloneOffset`; offsets that leave the canvas replicate the edge.
public struct RepairStroke: Codable, Equatable, Identifiable {
    public var id: UUID
    public var mode: RepairBrushMode
    public var points: [MaskPoint]
    public var radius: Double
    public var feather: Double
    public var strength: Double
    public var cloneOffset: MaskPoint

    public init(id: UUID = UUID(),
                mode: RepairBrushMode = .heal,
                points: [MaskPoint] = [],
                radius: Double = 0.06,
                feather: Double = 0.5,
                strength: Double = 1,
                cloneOffset: MaskPoint = MaskPoint(x: 0, y: 0)) {
        self.id = id
        self.mode = mode
        self.points = points
        self.radius = radius
        self.feather = feather
        self.strength = strength
        self.cloneOffset = cloneOffset
    }

    /// Structural validation used by the renderer and (later) by the UI/recipe
    /// path. Every failure is an explicit `AtelierError.invalidConfiguration`
    /// instead of a silently skipped stroke.
    public func validate() throws {
        guard points.count <= RepairBrushEngine.maximumPointsPerStroke else {
            throw AtelierError.invalidConfiguration(
                "修复笔迹点数不能超过 \(RepairBrushEngine.maximumPointsPerStroke) 个。"
            )
        }
        guard !points.isEmpty else {
            throw AtelierError.invalidConfiguration("修复笔迹至少需要一个点。")
        }
        for point in points {
            guard point.x.isFinite, point.y.isFinite else {
                throw AtelierError.invalidConfiguration("修复笔迹坐标必须是有限数值。")
            }
        }
        guard radius.isFinite, (0.0005...0.5).contains(radius) else {
            throw AtelierError.invalidConfiguration("修复画笔半径必须在 0.0005...0.5（图像短边比例）之间。")
        }
        guard feather.isFinite, (0...1).contains(feather) else {
            throw AtelierError.invalidConfiguration("修复画笔羽化必须在 0...1 之间。")
        }
        guard strength.isFinite, (0...1).contains(strength) else {
            throw AtelierError.invalidConfiguration("修复画笔强度必须在 0...1 之间。")
        }
        guard cloneOffset.x.isFinite, cloneOffset.y.isFinite,
              (-1...1).contains(cloneOffset.x), (-1...1).contains(cloneOffset.y) else {
            throw AtelierError.invalidConfiguration("仿制来源偏移必须是 -1...1 的有限图像比例。")
        }
    }

    /// Fraction of the shorter image edge covered by the brush diameter. Used by
    /// the canvas overlay in the integration step so the drawn cursor matches the
    /// rendered footprint.
    public func pixelRadius(for extent: CGRect) -> CGFloat {
        CGFloat(radius) * min(extent.width, extent.height)
    }
}

/// Pure Core Image graph builder for manual repair brush strokes.
///
/// The engine never rasterises pixels itself except for the stroke coverage mask
/// (a small Core Graphics bitmap, capped at `maskResolutionCap` on its longest
/// edge, then scaled up). It returns a lazy `CIImage`; rendering, colour space and
/// file writing stay with the caller (the pipeline owns the `CIContext`).
///
/// Boundaries (deliberately explicit):
/// - `heal` is a heuristic, non-generative neighbourhood repair: low-frequency
///   colour + nearby texture. It removes small marks under the stroke but cannot
///   rebuild structure that is not present around them.
/// - `clone` copies pixels verbatim; it does not auto-match colour and it will
///   copy whatever the sampled source contains, including grain or a hard edge.
/// - Manual tool only: there is no automatic blemish detection and no face/skin
///   dependency; the caller decides where to paint.
/// - Strokes are applied sequentially in array order, so earlier strokes feed
///   later ones (deterministic; the recipe/undo layer controls ordering).
public enum RepairBrushEngine {
    /// Bounded work for hostile recipes; a normal retouch session uses far fewer.
    public static let maximumStrokeCount = 256
    /// A single repair stroke with thousands of points is a data error, not a
    /// brush path; bound it explicitly instead of hanging the rasteriser.
    public static let maximumPointsPerStroke = 20_000
    /// Longest edge of the internal coverage mask. Soft masks scale smoothly, so
    /// this keeps memory bounded even for 120 MP inputs. Boundary: on very large
    /// images a brush whose pixel radius is below `longestEdge / maskResolutionCap`
    /// is rasterised at sub-pixel size (minimum half a mask pixel), so its footprint
    /// becomes coarser than on a normal preview-sized image.
    public static let maskResolutionCap: CGFloat = 1600

    /// Applies repair strokes to `image` in order and returns a new image with the
    /// same extent. An empty stroke list returns the input image object unchanged.
    ///
    /// - Throws: `AtelierError.invalidConfiguration` for an unusable image extent,
    ///   too many strokes, or an invalid stroke (empty points, non-finite or
    ///   out-of-range parameters). Missing filter support is a configuration error
    ///   rather than a silent no-op.
    public static func apply(to image: CIImage, strokes: [RepairStroke]) throws -> CIImage {
        let extent = image.extent
        guard isUsable(extent) else {
            throw AtelierError.invalidConfiguration("修复画笔底图尺寸无效，无法应用笔迹。")
        }
        guard strokes.count <= maximumStrokeCount else {
            throw AtelierError.invalidConfiguration("修复笔迹数量不能超过 \(maximumStrokeCount) 笔。")
        }
        guard !strokes.isEmpty else { return image }

        var output = image
        for stroke in strokes {
            try stroke.validate()
            output = try apply(stroke: stroke, to: output, extent: extent)
        }
        return output.cropped(to: extent)
    }

    // MARK: - Single stroke

    private static func apply(stroke: RepairStroke, to image: CIImage, extent: CGRect) throws -> CIImage {
        let coverage = try coverageMask(for: stroke, extent: extent)
        let strengthMask = scaleCoverage(coverage, by: stroke.strength)
        let replacement: CIImage
        switch stroke.mode {
        case .clone:
            replacement = try cloneReplacement(for: stroke, image: image, extent: extent)
        case .heal:
            replacement = healReplacement(for: stroke, coverage: coverage, image: image, extent: extent)
        }
        return try blend(replacement, over: image, coverage: strengthMask, extent: extent)
    }

    /// Clone stamp: sample `image` at `target + cloneOffset` and use it verbatim.
    /// The shifted image is edge-clamped before cropping so offsets that leave the
    /// canvas replicate the border instead of introducing transparency.
    private static func cloneReplacement(for stroke: RepairStroke,
                                         image: CIImage,
                                         extent: CGRect) throws -> CIImage {
        let offsetX = CGFloat(stroke.cloneOffset.x) * extent.width
        let offsetY = CGFloat(stroke.cloneOffset.y) * extent.height
        guard offsetX.isFinite, offsetY.isFinite else {
            throw AtelierError.invalidConfiguration("仿制来源偏移无效。")
        }
        // `cloneOffset` is the displacement from the painted target to the source
        // (`source = target + offset`). Translating the image by the negated offset
        // makes the sampled pixel at the target equal the source pixel.
        return image
            .transformed(by: CGAffineTransform(translationX: -offsetX, y: -offsetY))
            .clampedToExtent()
            .cropped(to: extent)
    }

    /// Heal: low-frequency colour from the blurred surroundings plus nearby
    /// texture sampled from a clean patch next to the stroke. When no clean donor
    /// patch fits inside the canvas the blurred-neighbourhood-only result is used
    /// (still reduces local contrast, documented heuristic).
    private static func healReplacement(for stroke: RepairStroke,
                                        coverage: CIImage,
                                        image: CIImage,
                                        extent: CGRect) -> CIImage {
        let radiusPixels = max(1, stroke.pixelRadius(for: extent))
        let lowFrequency = gaussianBlurred(image, radius: radiusPixels * 1.15, extent: extent)

        guard let donorOffset = automaticDonorOffset(for: stroke, extent: extent),
              donorOffset.x.isFinite, donorOffset.y.isFinite else {
            return lowFrequency
        }
        let donor = image
            .transformed(by: CGAffineTransform(translationX: -donorOffset.x, y: -donorOffset.y))
            .clampedToExtent()
        let donorTexture = gaussianBlurred(donor, radius: max(0.5, radiusPixels * 0.30), extent: extent)
        // Blend a moderate amount of nearby texture over the smooth colour so the
        // repair keeps some local detail instead of looking like a plastic patch.
        let textureMask = scaleCoverage(coverage, by: 0.5)
        guard let blended = try? blend(donorTexture, over: lowFrequency, coverage: textureMask, extent: extent) else {
            return lowFrequency
        }
        return blended
    }

    /// Chooses a nearby clean donor patch. The stroke direction gives a normal;
    /// the first normal direction whose shifted stroke bounds still fit inside the
    /// canvas wins. Deterministic and order-independent of dictionary iteration.
    private static func automaticDonorOffset(for stroke: RepairStroke, extent: CGRect) -> CGPoint? {
        guard let first = stroke.points.first, let last = stroke.points.last else { return nil }
        var dx = (last.x - first.x) * extent.width
        var dy = (last.y - first.y) * extent.height
        if abs(dx) < 0.5 && abs(dy) < 0.5 {
            dx = 1; dy = 0
        }
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0.5, length.isFinite else { return nil }
        let normalX = -dy / length
        let normalY = dx / length
        let radiusPixels = max(1, stroke.pixelRadius(for: extent))
        let distance = radiusPixels * 2.6
        let bounds = strokeBounds(for: stroke, extent: extent)

        for candidate in [CGPoint(x: normalX * distance, y: normalY * distance),
                          CGPoint(x: -normalX * distance, y: -normalY * distance)] {
            let shifted = bounds.offsetBy(dx: candidate.x, dy: candidate.y)
            if extent.insetBy(dx: 1, dy: 1).contains(shifted) { return candidate }
        }
        return nil
    }

    // MARK: - Mask rasterisation

    /// Rasterises the stroke polyline into an opaque greyscale coverage mask
    /// (Core Image `CIBlendWithMask` uses the RGB value as the blend amount).
    /// The mask is drawn at a capped resolution and scaled up; feather is a
    /// Gaussian softening of the mask, clamped to the canvas before blurring so
    /// image-border strokes keep their coverage.
    private static func coverageMask(for stroke: RepairStroke, extent: CGRect) throws -> CIImage {
        let longestEdge = max(extent.width, extent.height)
        let scale = min(1, maskResolutionCap / longestEdge)
        let rasterWidth = max(1, Int(ceil(extent.width * scale)))
        let rasterHeight = max(1, Int(ceil(extent.height * scale)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: rasterWidth,
                                      height: rasterHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AtelierError.invalidConfiguration("修复画笔掩膜创建失败。")
        }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: rasterWidth, height: rasterHeight))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))

        let radius = max(0.5, CGFloat(stroke.radius) * min(extent.width, extent.height) * scale)
        let points = stroke.points.map { point in
            CGPoint(x: CGFloat(point.x) * CGFloat(rasterWidth),
                    y: CGFloat(point.y) * CGFloat(rasterHeight))
        }
        if points.count == 1 {
            let center = points[0]
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                           width: radius * 2, height: radius * 2))
        } else {
            context.setLineWidth(radius * 2)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            context.move(to: points[0])
            for point in points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        }
        guard let bitmap = context.makeImage() else {
            throw AtelierError.invalidConfiguration("修复画笔掩膜栅格化失败。")
        }

        var mask = CIImage(cgImage: bitmap)
        let featherRadius = CGFloat(stroke.feather) * radius * 0.85
        if featherRadius > 0.4 {
            mask = gaussianBlurred(mask.clampedToExtent(), radius: featherRadius, extent: mask.extent)
            mask = forcingOpaque(mask)
        }
        // Scale the small mask back to full image pixels and align it with the
        // image extent (points were normalised against the extent, so the raster
        // starts at the extent's bottom-left corner).
        if scale < 0.9999 {
            mask = mask.transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        }
        mask = forcingOpaque(mask)
        mask = mask.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return mask.cropped(to: extent)
    }

    /// Multiplies the mask's RGB coverage by `factor` while keeping the mask
    /// opaque (`CIBlendWithMask` reads the RGB value, not alpha).
    private static func scaleCoverage(_ mask: CIImage, by factor: Double) -> CIImage {
        let value = CGFloat(max(0, min(1, factor)))
        guard value < 0.9999, let filter = CIFilter(name: "CIColorMatrix") else { return mask }
        filter.setValue(mask, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: value, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: value, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: value, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputAVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputBiasVector")
        return filter.outputImage ?? mask
    }

    /// Restores alpha to 1 so a blurred finite mask stays a pure RGB coverage
    /// image (same convention as the face semantic mattes).
    private static func forcingOpaque(_ image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputAVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputBiasVector")
        return filter.outputImage ?? image
    }

    // MARK: - Composition helpers

    private static func blend(_ input: CIImage,
                              over background: CIImage,
                              coverage: CIImage,
                              extent: CGRect) throws -> CIImage {
        guard let filter = CIFilter(name: "CIBlendWithMask") else {
            throw AtelierError.invalidConfiguration("修复画笔合成滤镜不可用。")
        }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(background, forKey: "inputBackgroundImage")
        filter.setValue(coverage, forKey: "inputMaskImage")
        guard let output = filter.outputImage else {
            throw AtelierError.invalidConfiguration("修复画笔合成无法生成输出。")
        }
        return output.cropped(to: extent)
    }

    private static func gaussianBlurred(_ image: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        let clamped = image.clampedToExtent()
        guard radius > 0.05, let filter = CIFilter(name: "CIGaussianBlur") else {
            return clamped.cropped(to: extent)
        }
        filter.setValue(clamped, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return clamped.cropped(to: extent) }
        return output.cropped(to: extent)
    }

    /// Bounding box of the stroke footprint in pixel coordinates, expanded by the
    /// brush radius and a small feather allowance.
    private static func strokeBounds(for stroke: RepairStroke, extent: CGRect) -> CGRect {
        let radius = stroke.pixelRadius(for: extent)
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for point in stroke.points {
            let x = CGFloat(point.x) * extent.width + extent.minX
            let y = CGFloat(point.y) * extent.height + extent.minY
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        let padding = radius * 2
        return CGRect(x: minX - padding, y: minY - padding,
                      width: (maxX - minX) + padding * 2,
                      height: (maxY - minY) + padding * 2)
    }

    private static func isUsable(_ extent: CGRect) -> Bool {
        extent.width.isFinite && extent.height.isFinite
            && extent.width > 1 && extent.height > 1
            && extent.width <= 100_000 && extent.height <= 100_000
    }
}

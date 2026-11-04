import CoreGraphics
import CoreImage
import Foundation

// MARK: - Falloff

/// Radial weight used when rasterizing a control point or stroke into the field.
public enum WarpFalloff: String, Codable, CaseIterable {
    /// Smooth cosine bell: 1 at the centre, 0 at the radius.
    case cosine
    /// Gaussian bell (approximately 0 at the radius).
    case gaussian

    public var title: String {
        switch self {
        case .cosine: return "余弦"
        case .gaussian: return "高斯"
        }
    }
}

// MARK: - Manual stroke

/// A manual liquify stroke in normalized image coordinates (bottom-left origin).
///
/// The stroke is a polyline of `points`; `radius` is the brush radius as a
/// fraction of **each image axis**, so the footprint is an ellipse with pixel
/// radii `(radius × imageWidth, radius × imageHeight)` (radiusX = radiusY =
/// normalized `radius`); `strength` is `0...1`. Modes:
/// - `push`: drag content along the stroke direction;
/// - `rebuild`: locally remove warp and return toward the original pixels;
/// - `smooth`: locally blend the displacement field toward its smoothed version.
public struct WarpStroke: Codable, Equatable {
    public enum Mode: String, Codable, CaseIterable, Identifiable {
        case push, rebuild, smooth
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .push: return "推移"
            case .rebuild: return "重建"
            case .smooth: return "平滑"
            }
        }
    }

    public var id: UUID
    public var mode: Mode
    public var points: [MaskPoint]
    /// Brush radius as a fraction of each image axis. The rasterized footprint is
    /// an ellipse: pixel radiusX = `radius × image width`, pixel radiusY =
    /// `radius × image height` (not a short-edge circle). The canvas overlay uses
    /// the same ellipse (`LiquifyBrushGeometry`).
    public var radius: Double
    /// `0...1` stroke strength.
    public var strength: Double

    public init(id: UUID = UUID(), mode: Mode = .push,
                points: [MaskPoint] = [], radius: Double = 0.08,
                strength: Double = 0.6) {
        self.id = id
        self.mode = mode
        self.points = points
        self.radius = radius
        self.strength = strength
    }

    private enum CodingKeys: String, CodingKey {
        case id, mode, points, radius, strength
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .push
        points = try values.decodeIfPresent([MaskPoint].self, forKey: .points) ?? []
        radius = try values.decodeIfPresent(Double.self, forKey: .radius) ?? 0.08
        strength = try values.decodeIfPresent(Double.self, forKey: .strength) ?? 0.6
    }
}

// MARK: - Warp field

/// Low-resolution displacement field for geometric liquify/face reshaping.
///
/// The field is a `columns x rows` grid of normalized displacement vectors
/// (fractions of the image width/height, bottom-left origin). It is rasterized
/// from control points and strokes with a radial falloff, then applied to an
/// image as a pull-remap: each destination pixel samples the source at
/// `destination - displacement`.
///
/// Coordinate system: normalized image coordinates `0...1`, bottom-left origin,
/// matching `FaceLandmarkSet` / Core Image. `radius` values are normalized too;
/// `addGaussian(center:radiusX:radiusY:...)` lets callers compensate for a
/// non-square image so a circular brush stays circular in pixels.
///
/// Safety: all mutating entry points drop non-finite input, the field is clamped
/// to `maximumDisplacement` (3% of the image edge by default) and can be smoothed,
/// which bounds how far background straight lines can bend. This is a heuristic
/// v1 warp, not a commercial retouch engine.
public struct WarpField: Equatable {
    public static let defaultResolution = 128
    /// Maximum displacement magnitude in normalized image units (3% per edge).
    public static let maximumDisplacement = 0.03

    public private(set) var columns: Int
    public private(set) var rows: Int
    /// Row-major grid; row `0` is the top row (bitmap order), `y` is flipped when
    /// sampling with normalized bottom-left coordinates.
    public private(set) var offsets: [SIMD2<Float>]

    public init(columns: Int = WarpField.defaultResolution,
                rows: Int = WarpField.defaultResolution) {
        self.columns = max(2, columns)
        self.rows = max(2, rows)
        self.offsets = Array(repeating: SIMD2<Float>(repeating: 0),
                             count: self.columns * self.rows)
    }

    /// True when every grid vector is exactly zero. Applying an identity field
    /// returns the input image untouched (no resampling).
    public var isIdentity: Bool {
        offsets.allSatisfy { $0.x == 0 && $0.y == 0 }
    }

    /// Largest displacement magnitude currently stored (normalized units).
    public var maximumMagnitude: Double {
        offsets.reduce(0.0) { partial, value in
            let magnitude = (Double(value.x) * Double(value.x)
                + Double(value.y) * Double(value.y)).squareRoot()
            return max(partial, magnitude)
        }
    }

    // MARK: Control points

    /// Adds a radial displacement bump. Non-finite input is ignored so a corrupt
    /// recipe can never poison the whole field with NaN.
    public mutating func addGaussian(center: CGPoint,
                                     radiusX: Double,
                                     radiusY: Double,
                                     displacement: SIMD2<Double>,
                                     falloff: WarpFalloff = .gaussian,
                                     strength: Double = 1) {
        guard center.x.isFinite, center.y.isFinite,
              radiusX.isFinite, radiusY.isFinite, radiusX > 0, radiusY > 0,
              displacement.x.isFinite, displacement.y.isFinite,
              strength.isFinite, strength > 0 else { return }
        let minimumRadiusX = 1.0 / Double(columns)
        let minimumRadiusY = 1.0 / Double(rows)
        let rx = max(minimumRadiusX, radiusX)
        let ry = max(minimumRadiusY, radiusY)
        let firstColumn = max(0, Int(floor((center.x - rx) * Double(columns))) - 1)
        let lastColumn = min(columns - 1, Int(ceil((center.x + rx) * Double(columns))) + 1)
        let firstRow = max(0, Int(floor((1 - center.y - ry) * Double(rows))) - 1)
        let lastRow = min(rows - 1, Int(ceil((1 - center.y + ry) * Double(rows))) + 1)
        guard firstColumn <= lastColumn, firstRow <= lastRow else { return }
        for row in firstRow...lastRow {
            let y = 1 - (Double(row) + 0.5) / Double(rows)
            for column in firstColumn...lastColumn {
                let x = (Double(column) + 0.5) / Double(columns)
                let dx = (x - Double(center.x)) / rx
                let dy = (y - Double(center.y)) / ry
                let distanceSquared = dx * dx + dy * dy
                guard distanceSquared < 1 else { continue }
                let weight: Double
                switch falloff {
                case .cosine:
                    weight = 0.5 * (1 + cos(Double.pi * distanceSquared.squareRoot()))
                case .gaussian:
                    // sigma = radius / 2 → smooth and effectively zero at the edge.
                    weight = exp(-2 * distanceSquared)
                }
                guard weight > 0 else { continue }
                let index = row * columns + column
                offsets[index] += SIMD2<Float>(Float(displacement.x * weight * strength),
                                               Float(displacement.y * weight * strength))
            }
        }
    }

    /// Convenience overload with one radius for both axes.
    public mutating func addGaussian(center: CGPoint,
                                     radius: Double,
                                     displacement: SIMD2<Double>,
                                     falloff: WarpFalloff = .gaussian,
                                     strength: Double = 1) {
        addGaussian(center: center, radiusX: radius, radiusY: radius,
                    displacement: displacement, falloff: falloff, strength: strength)
    }

    /// Multiplies the field by a radial weight (used by `rebuild`).
    public mutating func multiplyGaussian(center: CGPoint,
                                          radiusX: Double,
                                          radiusY: Double,
                                          factor: Double) {
        guard center.x.isFinite, center.y.isFinite,
              radiusX.isFinite, radiusY.isFinite, radiusX > 0, radiusY > 0,
              factor.isFinite else { return }
        let rx = max(1.0 / Double(columns), radiusX)
        let ry = max(1.0 / Double(rows), radiusY)
        for row in 0..<rows {
            let y = 1 - (Double(row) + 0.5) / Double(rows)
            for column in 0..<columns {
                let x = (Double(column) + 0.5) / Double(columns)
                let dx = (x - Double(center.x)) / rx
                let dy = (y - Double(center.y)) / ry
                let distanceSquared = dx * dx + dy * dy
                guard distanceSquared < 1 else { continue }
                let weight = exp(-2 * distanceSquared)
                let index = row * columns + column
                let scale = Float(max(0, min(1, 1 - (1 - factor) * weight)))
                offsets[index] *= scale
            }
        }
    }

    /// Blends the field toward `target` with a radial weight (used by `smooth`).
    public mutating func blendGaussian(center: CGPoint,
                                       radiusX: Double,
                                       radiusY: Double,
                                       target: [SIMD2<Float>],
                                       amount: Double) {
        guard target.count == offsets.count,
              center.x.isFinite, center.y.isFinite,
              radiusX.isFinite, radiusY.isFinite, radiusX > 0, radiusY > 0,
              amount.isFinite, amount > 0 else { return }
        let rx = max(1.0 / Double(columns), radiusX)
        let ry = max(1.0 / Double(rows), radiusY)
        for row in 0..<rows {
            let y = 1 - (Double(row) + 0.5) / Double(rows)
            for column in 0..<columns {
                let x = (Double(column) + 0.5) / Double(columns)
                let dx = (x - Double(center.x)) / rx
                let dy = (y - Double(center.y)) / ry
                let distanceSquared = dx * dx + dy * dy
                guard distanceSquared < 1 else { continue }
                let weight = Float(min(1, amount * exp(-2 * distanceSquared)))
                let index = row * columns + column
                offsets[index] += (target[index] - offsets[index]) * weight
            }
        }
    }

    // MARK: Strokes

    /// Applies one manual stroke on top of the current field.
    public mutating func addStroke(_ stroke: WarpStroke) {
        let points = stroke.points
            .filter { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }
            .map { CGPoint(x: $0.x, y: $0.y) }
        guard !points.isEmpty, stroke.strength.isFinite, stroke.strength > 0,
              stroke.radius.isFinite, stroke.radius > 0 else { return }
        let strength = min(1, max(0, stroke.strength))
        let radius = min(0.5, max(0.001, stroke.radius))
        switch stroke.mode {
        case .push:
            let amount = radius * 0.35 * strength
            var previous: CGPoint?
            for point in points {
                defer { previous = point }
                guard let previous else { continue }
                let dx = point.x - previous.x
                let dy = point.y - previous.y
                let length = (dx * dx + dy * dy).squareRoot()
                guard length > 1e-7 else { continue }
                let direction = SIMD2<Double>(dx / length, dy / length)
                addGaussian(center: point, radiusX: radius, radiusY: radius,
                            displacement: SIMD2<Double>(direction.x * amount,
                                                        direction.y * amount),
                            falloff: .gaussian, strength: 1)
            }
        case .rebuild:
            for point in points {
                multiplyGaussian(center: point, radiusX: radius, radiusY: radius,
                                 factor: 1 - strength)
            }
        case .smooth:
            let target = smoothedOffsets(passes: 1)
            for point in points {
                blendGaussian(center: point, radiusX: radius, radiusY: radius,
                              target: target, amount: strength)
            }
        }
    }

    // MARK: Field shaping

    /// Separable 1-2-1 smoothing; each pass halves high-frequency ripples and
    /// reduces the chance of kinked lines.
    public mutating func smooth(passes: Int = 1) {
        let count = max(0, min(8, passes))
        guard count > 0 else { return }
        for _ in 0..<count {
            offsets = smoothedOffsets(passes: 1)
        }
    }

    /// Amplitude cap per vector. Non-finite vectors are reset to zero instead of
    /// propagating NaN into the coordinate map.
    public mutating func clampMagnitude(_ maximum: Double = WarpField.maximumDisplacement) {
        guard maximum.isFinite, maximum > 0 else { return }
        let limit = Float(maximum)
        for index in offsets.indices {
            let value = offsets[index]
            guard value.x.isFinite, value.y.isFinite else {
                offsets[index] = .zero
                continue
            }
            let length = (value.x * value.x + value.y * value.y).squareRoot()
            if length > limit, length > 0 {
                offsets[index] = value * (limit / length)
            }
        }
    }

    /// Background protection: keeps the displacement full inside `rect` and fades
    /// it to zero within `feather` (normalized) outside the rectangle, so straight
    /// lines outside the face stay straight.
    public mutating func attenuateOutside(rect: CGRect, feather: Double) {
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0,
              feather.isFinite, feather > 0 else { return }
        for row in 0..<rows {
            let y = 1 - (Double(row) + 0.5) / Double(rows)
            for column in 0..<columns {
                let x = (Double(column) + 0.5) / Double(columns)
                let dx = max(max(rect.minX - x, 0), x - rect.maxX)
                let dy = max(max(rect.minY - y, 0), y - rect.maxY)
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance < feather else {
                    offsets[row * columns + column] = .zero
                    continue
                }
                let t = distance / feather
                let weight = Float(1 - t * t * (3 - 2 * t))
                offsets[row * columns + column] *= weight
            }
        }
    }

    private func smoothedOffsets(passes: Int) -> [SIMD2<Float>] {
        var source = offsets
        for _ in 0..<max(1, passes) {
            var horizontal = [SIMD2<Float>](repeating: .zero, count: source.count)
            for row in 0..<rows {
                for column in 0..<columns {
                    let index = row * columns + column
                    let left = source[row * columns + max(0, column - 1)]
                    let right = source[row * columns + min(columns - 1, column + 1)]
                    horizontal[index] = (left + source[index] * SIMD2<Float>(repeating: 2) + right)
                        * SIMD2<Float>(repeating: 0.25)
                }
            }
            var vertical = [SIMD2<Float>](repeating: .zero, count: horizontal.count)
            for row in 0..<rows {
                for column in 0..<columns {
                    let index = row * columns + column
                    let up = horizontal[max(0, row - 1) * columns + column]
                    let down = horizontal[min(rows - 1, row + 1) * columns + column]
                    vertical[index] = (up + horizontal[index] * SIMD2<Float>(repeating: 2) + down)
                        * SIMD2<Float>(repeating: 0.25)
                }
            }
            source = vertical
        }
        return source
    }

    // MARK: Sampling

    /// Bilinear sample of the displacement at a normalized image point.
    public func displacement(at point: CGPoint) -> SIMD2<Double> {
        guard point.x.isFinite, point.y.isFinite, columns > 1, rows > 1 else { return .zero }
        let x = min(1, max(0, point.x))
        let y = min(1, max(0, point.y))
        let gridX = x * Double(columns) - 0.5
        let gridY = (1 - y) * Double(rows) - 0.5
        let x0 = max(0, min(columns - 1, Int(floor(gridX))))
        let y0 = max(0, min(rows - 1, Int(floor(gridY))))
        let x1 = min(columns - 1, x0 + 1)
        let y1 = min(rows - 1, y0 + 1)
        let fx = Float(min(1, max(0, gridX - Double(x0))))
        let fy = Float(min(1, max(0, gridY - Double(y0))))
        let topLeft = offsets[y0 * columns + x0]
        let topRight = offsets[y0 * columns + x1]
        let bottomLeft = offsets[y1 * columns + x0]
        let bottomRight = offsets[y1 * columns + x1]
        let top = topLeft + (topRight - topLeft) * fx
        let bottom = bottomLeft + (bottomRight - bottomLeft) * fx
        let value = top + (bottom - top) * fy
        return SIMD2<Double>(Double(value.x), Double(value.y))
    }

    // MARK: Rasterization

    /// Raw displacement image (R = dx, G = dy, normalized units). Diagnostic API;
    /// `apply(to:)` uses `coordinateMap(extent:)` instead.
    public func displacementMap(extent: CGRect) -> CIImage {
        renderMap(extent: extent) { _, _, value in
            SIMD2<Float>(Float(value.x), Float(value.y))
        }
    }

    /// Absolute source-coordinate map consumed by the warp kernel. Values are
    /// clamped inside the image so a border push can never sample outside.
    ///
    /// For images up to 4 megapixels the map is built at full image resolution, so
    /// a zero-displacement region samples the source at exact pixel centres
    /// (background pixels stay identical). Larger images use the 128-grid map
    /// upscaled by Core Image, which keeps memory bounded at the cost of a tiny
    /// interpolation blur on 1px background details (no line *bending*).
    public func coordinateMap(extent: CGRect) -> CIImage {
        guard extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite else {
            return CIImage(color: .clear).cropped(to: extent)
        }
        let width = max(1, Int(extent.width.rounded()))
        let height = max(1, Int(extent.height.rounded()))
        if width >= 2, height >= 2, width * height <= 4_000_000 {
            return fullResolutionCoordinateMap(extent: extent, width: width, height: height)
        }
        return scaledCoordinateMap(extent: extent)
    }

    private func fullResolutionCoordinateMap(extent: CGRect,
                                             width: Int, height: Int) -> CIImage {
        let minimumX = Float(extent.minX + 0.5)
        let maximumX = Float(max(extent.minX + 0.5, extent.maxX - 0.5))
        let minimumY = Float(extent.minY + 0.5)
        let maximumY = Float(max(extent.minY + 0.5, extent.maxY - 0.5))
        var floats = [Float](repeating: 0, count: width * height * 2)
        for row in 0..<height {
            let y = 1 - (Double(row) + 0.5) / Double(height)
            for column in 0..<width {
                let x = (Double(column) + 0.5) / Double(width)
                let value = displacement(at: CGPoint(x: x, y: y))
                let sourceX = Float(Double(extent.minX) + (x - value.x) * Double(extent.width))
                let sourceY = Float(Double(extent.minY) + (y - value.y) * Double(extent.height))
                let offset = (row * width + column) * 2
                floats[offset] = min(maximumX, max(minimumX, sourceX))
                floats[offset + 1] = min(maximumY, max(minimumY, sourceY))
            }
        }
        let data = floats.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        let bitmap = CIImage(bitmapData: data,
                             bytesPerRow: width * 2 * MemoryLayout<Float>.stride,
                             size: CGSize(width: CGFloat(width), height: CGFloat(height)),
                             format: .RGf, colorSpace: nil)
        return bitmap
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width),
                                               y: extent.height / CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    private func scaledCoordinateMap(extent: CGRect) -> CIImage {
        let minimumX = Float(extent.minX + 0.5)
        let maximumX = Float(max(extent.minX + 0.5, extent.maxX - 0.5))
        let minimumY = Float(extent.minY + 0.5)
        let maximumY = Float(max(extent.minY + 0.5, extent.maxY - 0.5))
        return renderMap(extent: extent) { column, row, value in
            let x = (Double(column) + 0.5) / Double(columns)
            let y = 1 - (Double(row) + 0.5) / Double(rows)
            let sourceX = Float(Double(extent.minX) + (x - value.x) * Double(extent.width))
            let sourceY = Float(Double(extent.minY) + (y - value.y) * Double(extent.height))
            return SIMD2<Float>(min(maximumX, max(minimumX, sourceX)),
                                min(maximumY, max(minimumY, sourceY)))
        }
    }

    private func renderMap(extent: CGRect,
                           value: (Int, Int, SIMD2<Double>) -> SIMD2<Float>) -> CIImage {
        let width = max(2, columns)
        let height = max(2, rows)
        var floats = [Float](repeating: 0, count: width * height * 2)
        for row in 0..<height {
            let y = 1 - (Double(row) + 0.5) / Double(height)
            for column in 0..<width {
                let x = (Double(column) + 0.5) / Double(width)
                let displacement = offsets[row * width + column]
                let output = value(column, row,
                                   SIMD2<Double>(Double(displacement.x),
                                                 Double(displacement.y)))
                let offset = (row * width + column) * 2
                floats[offset] = output.x
                floats[offset + 1] = output.y
            }
        }
        let data = floats.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        let bitmap = CIImage(bitmapData: data,
                             bytesPerRow: width * 2 * MemoryLayout<Float>.stride,
                             size: CGSize(width: CGFloat(width), height: CGFloat(height)),
                             format: .RGf, colorSpace: nil)
        return bitmap
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width),
                                               y: extent.height / CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    // MARK: Applying

    private static let warpKernel = CIKernel(source: """
    kernel vec4 liquifyCoordinateWarp(sampler source, sampler coordinateMap) {
        vec2 mapCoordinate = samplerCoord(coordinateMap);
        vec2 sourceCoordinate = sample(coordinateMap, mapCoordinate).rg;
        return sample(source, samplerTransform(source, sourceCoordinate));
    }
    """)

    /// Applies the field as a pull-remap. An identity field returns `image`
    /// unchanged, so neutral settings stay pixel-exact (pre-v11 render path).
    public func apply(to image: CIImage) throws -> CIImage {
        guard !isIdentity else { return image }
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width >= 1, extent.height >= 1,
              extent.width < 100_000, extent.height < 100_000 else { return image }
        let map = coordinateMap(extent: extent)
        guard let kernel = Self.warpKernel else {
            throw AtelierError.invalidConfiguration("液化位移 kernel 编译失败。")
        }
        guard let warped = kernel.apply(extent: extent,
                                        roiCallback: { index, _ in
                                            index == 0 ? extent : map.extent
                                        },
                                        arguments: [image, map]) else {
            throw AtelierError.invalidConfiguration("液化位移无法生成输出图像。")
        }
        return warped.cropped(to: extent)
    }
}

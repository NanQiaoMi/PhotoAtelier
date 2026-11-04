import CoreGraphics
import CoreImage
import Foundation

// MARK: - Settings

/// One control point of a color curve.
///
/// `x` is the input position and `y` the output value, both in the **display
/// encoded sRGB** domain (0...1). This matches how a photo editor's curve panel
/// is drawn: the midpoint of the x axis is 18%-gray's sRGB code value, not
/// linear light.
public struct CurveControlPoint: Codable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// RGB channel curves plus a luminance curve.
///
/// A `nil` channel means "no curve" (exact identity for that channel). Each
/// non-nil curve needs 2...16 control points with strictly increasing `x` in
/// 0...1 and `y` in 0...1; the engine validates this and rejects anything else
/// instead of silently clamping.
///
/// Semantics: the engine converts the linear working image to display-encoded
/// sRGB, applies the red/green/blue curves per channel, then applies the
/// luminance curve to Rec.709 luma and scales the three encoded channels by the
/// luma ratio. Finally it decodes back to linear light and clamps to [0,1]. The
/// curve therefore behaves like a familiar sRGB tone curve, not a linear-light
/// multiplier.
public struct ColorCurveSettings: Codable, Equatable {
    public var red: [CurveControlPoint]?
    public var green: [CurveControlPoint]?
    public var blue: [CurveControlPoint]?
    public var luminance: [CurveControlPoint]?

    public init(red: [CurveControlPoint]? = nil,
                green: [CurveControlPoint]? = nil,
                blue: [CurveControlPoint]? = nil,
                luminance: [CurveControlPoint]? = nil) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luminance = luminance
    }

    /// True when no channel has a curve; the engine returns the input object.
    public var isNeutral: Bool {
        red == nil && green == nil && blue == nil && luminance == nil
    }

    public func validate() throws {
        for (name, points) in [("红", red), ("绿", green), ("蓝", blue), ("亮度", luminance)] {
            guard let points else { continue }
            try ColorCurveEngine.validate(points: points, named: "\(name)曲线")
        }
    }
}

// MARK: - PCHIP

/// Monotone piecewise cubic Hermite interpolation (Fritsch–Carlson / PCHIP).
///
/// PCHIP is used instead of a natural cubic spline because it never overshoots
/// the local control points: a monotone point set produces a monotone curve, so
/// a tone curve cannot create ringing or clipped reversal between handles. The
/// implementation follows the standard PCHIP tangent rules (weighted harmonic
/// mean for interior nodes, limited one-sided slope at the ends).
internal enum PCHIPInterpolator {
    /// Evaluates the curve at `x`, clamping outside the control-point range to
    /// the nearest endpoint value (constant extrapolation).
    static func evaluate(points: [CurveControlPoint], x: Double) -> Double {
        guard points.count >= 2 else { return x }
        if x <= points[0].x { return points[0].y }
        if x >= points[points.count - 1].x { return points[points.count - 1].y }

        var index = 0
        while index < points.count - 2 && x > points[index + 1].x {
            index += 1
        }
        let x0 = points[index].x
        let x1 = points[index + 1].x
        let y0 = points[index].y
        let y1 = points[index + 1].y
        let h = x1 - x0
        guard h > 0 else { return y0 }

        let tangents = computeTangents(points: points)
        let m0 = tangents[index]
        let m1 = tangents[index + 1]
        let t = (x - x0) / h
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        let value = h00 * y0 + h10 * h * m0 + h01 * y1 + h11 * h * m1
        return min(max(value, 0), 1)
    }

    /// Standard PCHIP tangents. Returns one tangent per control point.
    static func computeTangents(points: [CurveControlPoint]) -> [Double] {
        let count = points.count
        guard count >= 2 else { return points.map { _ in 0 } }
        var h = [Double](repeating: 0, count: count - 1)
        var delta = [Double](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            h[index] = points[index + 1].x - points[index].x
            delta[index] = h[index] > 0 ? (points[index + 1].y - points[index].y) / h[index] : 0
        }
        var tangents = [Double](repeating: 0, count: count)
        if count == 2 {
            let slope = delta[0]
            tangents[0] = slope
            tangents[1] = slope
            return tangents
        }
        // Interior nodes: weighted harmonic mean of adjacent secants when they
        // agree in sign, zero at local extrema (this is what removes overshoot).
        for index in 1..<(count - 1) {
            let previous = delta[index - 1]
            let next = delta[index]
            if previous * next <= 0 {
                tangents[index] = 0
            } else {
                let w1 = 2 * h[index] + h[index - 1]
                let w2 = h[index] + 2 * h[index - 1]
                tangents[index] = (w1 + w2) / (w1 / previous + w2 / next)
            }
        }
        // End nodes: limited one-sided three-point estimate.
        tangents[0] = endTangent(h0: h[0], h1: h[1], delta0: delta[0], delta1: delta[1])
        tangents[count - 1] = endTangent(h0: h[count - 2], h1: h[count - 3],
                                         delta0: delta[count - 2], delta1: delta[count - 3])
        return tangents
    }

    private static func endTangent(h0: Double, h1: Double,
                                   delta0: Double, delta1: Double) -> Double {
        guard h0 > 0, h1 > 0 else { return 0 }
        var tangent = ((2 * h0 + h1) * delta0 - h0 * delta1) / (h0 + h1)
        if tangent * delta0 <= 0 {
            tangent = 0
        } else if delta0 * delta1 <= 0 && abs(tangent) > abs(3 * delta0) {
            tangent = 3 * delta0
        }
        return tangent
    }
}

// MARK: - Engine

/// Applies RGB and luminance curves.
///
/// Pipeline stage: first color tool, after basic tone, before HSL and grading.
/// The engine builds a 256-entry lookup table per curve on the CPU (PCHIP is
/// cheap but not cheap enough to evaluate per pixel in a kernel) and applies the
/// tables in a Core Image kernel.
///
/// Limits: 256-entry LUTs are linearly interpolated in the kernel, so very steep
/// curves can quantize slightly between table entries; curves are clamped to
/// [0,1] on both axes and cannot invert outside their control points.
public enum ColorCurveEngine {
    /// LUT resolution shared by all four curves.
    public static let lookupTableSize = 256
    /// Allowed control point counts.
    public static let minimumControlPoints = 2
    public static let maximumControlPoints = 16

    private static let kernel = CIKernel(source: ColorToolKernelMath.srgbFunctions + """
    float colorCurveLookup(sampler table, float unit) {
        float position = clamp(unit, 0.0, 1.0) * 255.0;
        float lower = floor(position);
        float upper = min(lower + 1.0, 255.0);
        float fraction = position - lower;
        float lowValue = sample(table, samplerTransform(table, vec2(lower + 0.5, 0.5))).r;
        float highValue = sample(table, samplerTransform(table, vec2(upper + 0.5, 0.5))).r;
        return mix(lowValue, highValue, fraction);
    }
    kernel vec4 applyColorCurves(sampler source, sampler redTable, sampler greenTable,
                                 sampler blueTable, sampler luminanceTable) {
        vec4 sampleValue = sample(source, samplerCoord(source));
        float alpha = clamp(sampleValue.a, 0.0, 1.0);
        if (alpha <= 0.000001) { return vec4(0.0); }
        vec3 linear = clamp(sampleValue.rgb / alpha, vec3(0.0), vec3(1.0));
        vec3 encoded = colorToolSRGBEncode(linear);
        vec3 curved = vec3(colorCurveLookup(redTable, encoded.r),
                           colorCurveLookup(greenTable, encoded.g),
                           colorCurveLookup(blueTable, encoded.b));
        float luma = dot(curved, vec3(0.2126, 0.7152, 0.0722));
        float mappedLuma = colorCurveLookup(luminanceTable, luma);
        vec3 resultEncoded;
        if (luma > 0.0001) {
            resultEncoded = curved * (mappedLuma / luma);
        } else {
            resultEncoded = curved + (mappedLuma - luma);
        }
        resultEncoded = clamp(resultEncoded, vec3(0.0), vec3(1.0));
        vec3 resultLinear = colorToolSRGBDecode(resultEncoded);
        return vec4(resultLinear * alpha, alpha);
    }
    """)

    /// Validates one curve's control points.
    public static func validate(points: [CurveControlPoint], named name: String = "曲线") throws {
        guard (minimumControlPoints...maximumControlPoints).contains(points.count) else {
            throw AtelierError.invalidConfiguration(
                "\(name)需要 \(minimumControlPoints)...\(maximumControlPoints) 个控制点。")
        }
        var previousX = -Double.infinity
        for point in points {
            guard point.x.isFinite, point.y.isFinite else {
                throw AtelierError.invalidConfiguration("\(name)的控制点包含非有限数值。")
            }
            guard (0...1).contains(point.x), (0...1).contains(point.y) else {
                throw AtelierError.invalidConfiguration("\(name)的控制点必须在 0...1 范围内。")
            }
            guard point.x > previousX else {
                throw AtelierError.invalidConfiguration("\(name)的控制点 X 必须严格递增。")
            }
            previousX = point.x
        }
    }

    /// Samples the PCHIP curve at `x` (used by tests and by the LUT builder).
    public static func sample(_ points: [CurveControlPoint], at x: Double) throws -> Double {
        try validate(points: points)
        return PCHIPInterpolator.evaluate(points: points, x: x)
    }

    /// Builds the LUT the kernel consumes. Identity curves return `i/(n-1)`.
    public static func lookupTable(for points: [CurveControlPoint]?,
                                   count: Int = lookupTableSize) throws -> [Double] {
        guard count >= 2 else {
            throw AtelierError.invalidConfiguration("曲线 LUT 至少需要 2 项。")
        }
        guard let points else {
            return (0..<count).map { Double($0) / Double(count - 1) }
        }
        try validate(points: points)
        return (0..<count).map { index in
            PCHIPInterpolator.evaluate(points: points, x: Double(index) / Double(count - 1))
        }
    }

    /// Applies the curve settings. A neutral setting returns `image` itself.
    public static func apply(_ settings: ColorCurveSettings,
                             to image: CIImage,
                             cancellation: CancellationToken? = nil) throws -> CIImage {
        try settings.validate()
        guard !settings.isNeutral else { return image }
        let extent = try ColorToolValidation.validExtent(of: image)
        try cancellation?.check()
        guard let kernel else {
            throw AtelierError.invalidConfiguration("Core Image 曲线 kernel 编译失败。")
        }

        let tables = [
            try lookupTable(for: settings.red),
            try lookupTable(for: settings.green),
            try lookupTable(for: settings.blue),
            try lookupTable(for: settings.luminance)
        ]
        let tableImages = tables.map { values -> CIImage in
            var pixels = [Float](repeating: 0, count: lookupTableSize * 4)
            for index in 0..<lookupTableSize {
                let value = Float(values[index])
                let offset = index * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 1
            }
            let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            return CIImage(bitmapData: data,
                           bytesPerRow: lookupTableSize * 4 * MemoryLayout<Float>.stride,
                           size: CGSize(width: lookupTableSize, height: 1),
                           format: .RGBAf,
                           colorSpace: nil)
        }
        let tableSamplers = tableImages.map { image in
            CISampler(image: image, options: [
                kCISamplerFilterMode: kCISamplerFilterNearest,
                kCISamplerWrapMode: kCISamplerWrapClamp
            ])
        }
        guard let output = kernel.apply(extent: extent, roiCallback: { index, rect in
            index == 0 ? rect : tableImages[0].extent
        }, arguments: [
            CISampler(image: image),
            tableSamplers[0], tableSamplers[1], tableSamplers[2], tableSamplers[3]
        ]) else {
            throw AtelierError.invalidConfiguration("Core Image 曲线 kernel 无法生成输出。")
        }
        return output.cropped(to: extent)
    }
}

import CoreImage
import Foundation

/// Independent exposure offsets for five overlapping luminance regions.
/// A zero value is the identity; these controls do not change the legacy
/// `highlights` and `shadows` adjustment semantics.
public struct TonalCurveSettings: Codable, Equatable {
    public var blacksEV: Double
    public var shadowsEV: Double
    public var midtonesEV: Double
    public var highlightsEV: Double
    public var whitesEV: Double

    public init(blacksEV: Double = 0, shadowsEV: Double = 0, midtonesEV: Double = 0,
                highlightsEV: Double = 0, whitesEV: Double = 0) {
        self.blacksEV = blacksEV
        self.shadowsEV = shadowsEV
        self.midtonesEV = midtonesEV
        self.highlightsEV = highlightsEV
        self.whitesEV = whitesEV
    }

    /// Exact zero is intentionally required so a neutral curve bypasses Core Image.
    public var isNeutral: Bool {
        blacksEV == 0 && shadowsEV == 0 && midtonesEV == 0
            && highlightsEV == 0 && whitesEV == 0
    }
}

internal enum TonalCurveEngine {
    // x/y and tangent values use linear-light luminance units. Evaluating this
    // polynomial directly avoids per-pixel log2/pow approximation noise.
    private static let kernel = CIColorKernel(source: """
    float refinedReciprocal(float value) {
        // The legacy Core Image software JIT uses an approximate reciprocal
        // for division. Refine it before evaluating a shallow monotone curve:
        // otherwise input-dependent reciprocal error can reverse adjacent tones.
        float estimate = 1.0 / value;
        estimate = estimate * (2.0 - value * estimate);
        return estimate * (2.0 - value * estimate);
    }

    float hermite(float x, float x0, float x1, float y0, float y1,
                  float m0, float m1) {
        float h = x1 - x0;
        float t = clamp((x - x0) * refinedReciprocal(h), 0.0, 1.0);
        float t2 = t * t;
        float t3 = t2 * t;
        return (2.0 * t3 - 3.0 * t2 + 1.0) * y0
             + (t3 - 2.0 * t2 + t) * h * m0
             + (-2.0 * t3 + 3.0 * t2) * y1
             + (t3 - t2) * h * m1;
    }

    kernel vec4 applyTonalCurve(__sample sample,
                                vec4 output0123, vec4 output4567,
                                vec4 slope0123, vec4 slope4567) {
        float alpha = sample.a;
        if (!(alpha > 0.000001) || !(alpha <= 1.0)) { return sample; }

        vec3 color = sample.rgb * refinedReciprocal(alpha);
        // Comparisons also reject NaNs and infinities while leaving the source untouched.
        if (!(abs(color.r) <= 65504.0) || !(abs(color.g) <= 65504.0)
            || !(abs(color.b) <= 65504.0)) { return sample; }

        float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
        if (!(luminance > 0.0) || !(luminance <= 65504.0)) { return sample; }

        // These are the linear-light counterparts of the CPU's fixed log2 EV
        // knots, with (0, 0) added so positive near-black values approach zero.
        float x0 = 0.0;
        float x1 = 0.0000152587890625;
        float x2 = 0.0078125;
        float x3 = 0.0625;
        float x4 = 0.18;
        float x5 = 0.6;
        float x6 = 1.0;
        float x7 = 16.0;
        float x = luminance;
        float mappedLuminance;

        if (x < x1) {
            mappedLuminance = hermite(x, x0, x1, output0123.x, output0123.y,
                                      slope0123.x, slope0123.y);
        } else if (x < x2) {
            mappedLuminance = hermite(x, x1, x2, output0123.y, output0123.z,
                                      slope0123.y, slope0123.z);
        } else if (x < x3) {
            mappedLuminance = hermite(x, x2, x3, output0123.z, output0123.w,
                                      slope0123.z, slope0123.w);
        } else if (x < x4) {
            mappedLuminance = hermite(x, x3, x4, output0123.w, output4567.x,
                                      slope0123.w, slope4567.x);
        } else if (x < x5) {
            mappedLuminance = hermite(x, x4, x5, output4567.x, output4567.y,
                                      slope4567.x, slope4567.y);
        } else if (x < x6) {
            mappedLuminance = hermite(x, x5, x6, output4567.y, output4567.z,
                                      slope4567.y, slope4567.z);
        } else if (x < x7) {
            mappedLuminance = hermite(x, x6, x7, output4567.z, output4567.w,
                                      slope4567.z, slope4567.w);
        } else {
            // Constant endpoint exposure gain above the extended-white knot.
            mappedLuminance = x * (output4567.w / x7);
        }

        if (!(mappedLuminance >= -3.402823e+38) || !(mappedLuminance <= 3.402823e+38)) {
            return sample;
        }
        // Keep the per-pixel EV adjustment within +/-3 stops, then limit the
        // ideal gray result to the half-float channel range. A zero caused by
        // underflow maps to black rather than reverting to the source.
        mappedLuminance = clamp(mappedLuminance, luminance * 0.125, luminance * 8.0);
        mappedLuminance = min(65504.0, mappedLuminance);
        float requestedGain = mappedLuminance * refinedReciprocal(luminance);
        float maxChannel = max(max(abs(color.r), abs(color.g)), abs(color.b));
        float channelLimit = maxChannel > 0.0 ? 65504.0 * refinedReciprocal(maxChannel) : 8.0;
        float gain = min(requestedGain, min(8.0, channelLimit));
        if (!(gain >= 0.0) || !(gain <= 8.0)) { return sample; }

        vec3 outputColor = color * gain;
        // Division followed by multiplication can undershoot the representable
        // ceiling on one backend and hit it on another. Pin only the limiting
        // channel(s) when the channel bound is active; other channels keep the
        // same shared gain and preserve their ratios within the gamut headroom.
        bool hitsChannelBound = maxChannel > 0.0 && channelLimit <= 8.0
                             && requestedGain >= channelLimit;
        if (hitsChannelBound) {
            if (abs(color.r) == maxChannel) { outputColor.r = color.r < 0.0 ? -65504.0 : 65504.0; }
            if (abs(color.g) == maxChannel) { outputColor.g = color.g < 0.0 ? -65504.0 : 65504.0; }
            if (abs(color.b) == maxChannel) { outputColor.b = color.b < 0.0 ? -65504.0 : 65504.0; }
        }
        outputColor = clamp(outputColor, vec3(-65504.0), vec3(65504.0));

        return vec4(outputColor * alpha, alpha);
    }
    """)

    static func validate(_ settings: TonalCurveSettings) throws {
        let values = [settings.blacksEV, settings.shadowsEV, settings.midtonesEV,
                      settings.highlightsEV, settings.whitesEV]
        let names = ["黑位", "阴影", "中间调", "高光", "白位"]
        for (index, value) in values.enumerated() {
            guard value.isFinite, (-3...3).contains(value) else {
                throw AtelierError.invalidConfiguration(
                    "色调曲线\(names[index]) EV 必须是有限值且位于 -3...3。")
            }
        }
    }

    static func apply(_ image: CIImage, settings: TonalCurveSettings) throws -> CIImage {
        try validate(settings)
        guard !settings.isNeutral else { return image }

        let curve = MonotoneTonalCurve(settings: settings)
        let output = curve.linearOutputs
        let slopes = curve.slopes
        let extent = image.extent
        guard !extent.isNull, !extent.isInfinite, extent.minX.isFinite, extent.minY.isFinite,
              extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
            throw AtelierError.invalidConfiguration("色调曲线需要有限且非空的图像范围。")
        }

        guard let kernel = Self.kernel,
              let result = kernel.apply(extent: image.extent, arguments: [
                image,
                CIVector(x: CGFloat(output[0]), y: CGFloat(output[1]),
                         z: CGFloat(output[2]), w: CGFloat(output[3])),
                CIVector(x: CGFloat(output[4]), y: CGFloat(output[5]),
                         z: CGFloat(output[6]), w: CGFloat(output[7])),
                CIVector(x: CGFloat(slopes[0]), y: CGFloat(slopes[1]),
                         z: CGFloat(slopes[2]), w: CGFloat(slopes[3])),
                CIVector(x: CGFloat(slopes[4]), y: CGFloat(slopes[5]),
                         z: CGFloat(slopes[6]), w: CGFloat(slopes[7]))
              ]) else {
            throw AtelierError.invalidConfiguration("Core Image 色调曲线无法生成输出。")
        }
        return result.cropped(to: image.extent)
    }
}

/// CPU mirror of the GPU curve for deterministic curve checks.
internal struct MonotoneTonalCurve {
    /// Seven original log2 linear-luminance input knots, in exposure-stop units.
    let logInputs: [Double]
    /// Seven monotone-projected log2 output knots, retained for recipe/debug checks.
    let logOutputs: [Double]
    /// Eight linear-light knots, including the explicit (0, 0) black anchor.
    let linearInputs: [Double]
    let linearOutputs: [Double]
    /// PCHIP tangent slopes in linear-light output per linear-light input unit.
    let slopes: [Double]

    private static let minimumSlope = 0.02
    private static let blackKnot = -16.0
    private static let shadowKnot = -7.0
    private static let deepShadowKnot = -4.0
    private static let middleKnot = Foundation.log2(0.18)
    private static let highlightKnot = Foundation.log2(0.6)
    private static let whiteKnot = 0.0
    private static let extendedWhiteKnot = 4.0

    init(settings: TonalCurveSettings) {
        let inputs = [Self.blackKnot, Self.shadowKnot, Self.deepShadowKnot,
                      Self.middleKnot, Self.highlightKnot, Self.whiteKnot,
                      Self.extendedWhiteKnot]
        let deltas = [settings.blacksEV, settings.blacksEV, settings.shadowsEV,
                      settings.midtonesEV, settings.highlightsEV, settings.whitesEV,
                      settings.whitesEV].map { value in
            value.isFinite ? min(3.0, max(-3.0, value)) : 0.0
        }
        let requestedOutputs = zip(inputs, deltas).map { pair in pair.0 + pair.1 }
        let transformed = zip(inputs, requestedOutputs).map { pair in
            pair.1 - Self.minimumSlope * pair.0
        }
        let projected = Self.isotonicProjection(transformed)
        let projectedOutputs = zip(inputs, projected).map { pair in
            pair.1 + Self.minimumSlope * pair.0
        }
        // Clamp projected nodes to the same per-knot +/-3 EV limit enforced by
        // the former log-domain evaluator. Clamping two monotone sequences
        // preserves their order, so this cannot introduce a tone reversal.
        let outputs = zip(inputs, projectedOutputs).map { pair in
            min(pair.0 + 3.0, max(pair.0 - 3.0, pair.1))
        }
        let positiveInputs = inputs.map { Foundation.pow(2.0, $0) }
        let positiveOutputs = outputs.map { Foundation.pow(2.0, $0) }
        let linearInputs = [0.0] + positiveInputs
        let linearOutputs = [0.0] + positiveOutputs

        self.logInputs = inputs
        self.logOutputs = outputs
        self.linearInputs = linearInputs
        self.linearOutputs = linearOutputs
        self.slopes = Self.monotoneSlopes(inputs: linearInputs, outputs: linearOutputs)
    }

    /// Maps linear-light luminance with the same linear-domain PCHIP used by GPU.
    /// Zero/negative values pass through; positive finite outputs are capped at
    /// the half-float channel limit used by the GPU path.
    func evaluateLuminance(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return value }
        let output: Double
        guard let lastInput = linearInputs.last, let lastOutput = linearOutputs.last,
              lastInput > 0, lastOutput.isFinite else { return value }
        if value >= lastInput {
            // Fixed EV gain beyond the final extended-white knot.
            output = value * (lastOutput / lastInput)
        } else {
            output = evaluateLinearSegment(value)
        }
        if !output.isFinite { return 65504 }
        // Apply the same pointwise +/-3 EV bounds as the prior log-domain path.
        let bounded = min(value * 8.0, max(value * 0.125, output))
        return min(65504, max(0, bounded))
    }

    private func evaluateLinearSegment(_ value: Double) -> Double {
        guard linearInputs.count == linearOutputs.count, linearInputs.count == slopes.count,
              linearInputs.count >= 2 else { return value }
        for index in 0..<(linearInputs.count - 1) where value < linearInputs[index + 1] {
            let x0 = linearInputs[index]
            let x1 = linearInputs[index + 1]
            let y0 = linearOutputs[index]
            let y1 = linearOutputs[index + 1]
            let h = x1 - x0
            guard h > 0 else { return max(y0, y1) }
            let t = min(1.0, max(0.0, (value - x0) / h))
            let t2 = t * t
            let t3 = t2 * t
            return (2 * t3 - 3 * t2 + 1) * y0
                + (t3 - 2 * t2 + t) * h * slopes[index]
                + (-2 * t3 + 3 * t2) * y1
                + (t3 - t2) * h * slopes[index + 1]
        }
        guard let last = linearOutputs.last, let input = linearInputs.last,
              input > 0 else { return value }
        return value * (last / input)
    }

    private static func isotonicProjection(_ values: [Double]) -> [Double] {
        var means: [Double] = []
        var weights: [Int] = []
        var starts: [Int] = []

        for (index, value) in values.enumerated() {
            means.append(value)
            weights.append(1)
            starts.append(index)

            while means.count >= 2 {
                let right = means.count - 1
                let left = right - 1
                guard means[left] > means[right] else { break }
                let totalWeight = weights[left] + weights[right]
                let mergedMean = (means[left] * Double(weights[left])
                    + means[right] * Double(weights[right])) / Double(totalWeight)
                means[left] = mergedMean
                weights[left] = totalWeight
                means.removeLast()
                weights.removeLast()
                starts.removeLast()
            }
        }

        var result = Array(repeating: 0.0, count: values.count)
        for block in means.indices {
            let end = starts[block] + weights[block]
            for index in starts[block]..<end { result[index] = means[block] }
        }
        return result
    }

    private static func monotoneSlopes(inputs: [Double], outputs: [Double]) -> [Double] {
        guard inputs.count == outputs.count, inputs.count >= 2 else {
            return Array(repeating: 1.0, count: inputs.count)
        }

        let intervalWidths = (0..<(inputs.count - 1)).map { inputs[$0 + 1] - inputs[$0] }
        let secants = intervalWidths.indices.map { index in
            (outputs[index + 1] - outputs[index]) / intervalWidths[index]
        }
        var result = Array(repeating: 0.0, count: inputs.count)

        if secants.count == 1 {
            result[0] = secants[0]
            result[1] = secants[0]
            return result
        }

        let first = ((2 * intervalWidths[0] + intervalWidths[1]) * secants[0]
            - intervalWidths[0] * secants[1])
            / (intervalWidths[0] + intervalWidths[1])
        result[0] = min(3 * secants[0], max(0, first))

        for index in 1..<(inputs.count - 1) {
            let previous = secants[index - 1]
            let next = secants[index]
            if previous <= 0 || next <= 0 {
                result[index] = 0
            } else {
                let leftWidth = intervalWidths[index - 1]
                let rightWidth = intervalWidths[index]
                let weightLeft = 2 * rightWidth + leftWidth
                let weightRight = rightWidth + 2 * leftWidth
                result[index] = (weightLeft + weightRight)
                    / (weightLeft / previous + weightRight / next)
            }
        }

        let last = inputs.count - 1
        let previousWidth = intervalWidths[intervalWidths.count - 2]
        let lastWidth = intervalWidths[intervalWidths.count - 1]
        let previousSecant = secants[secants.count - 2]
        let lastSecant = secants[secants.count - 1]
        let end = ((2 * lastWidth + previousWidth) * lastSecant
            - lastWidth * previousSecant) / (lastWidth + previousWidth)
        result[last] = min(3 * lastSecant, max(0, end))

        // Fritsch-Carlson limiter prevents the cubic segment from overshooting.
        for index in secants.indices {
            let secant = secants[index]
            guard secant > 0 else {
                result[index] = 0
                result[index + 1] = 0
                continue
            }
            let alpha = max(0, result[index] / secant)
            let beta = max(0, result[index + 1] / secant)
            let magnitudeSquared = alpha * alpha + beta * beta
            if magnitudeSquared > 9 {
                let scale = 3 / Foundation.sqrt(magnitudeSquared)
                result[index] = scale * alpha * secant
                result[index + 1] = scale * beta * secant
            }
        }
        return result
    }
}

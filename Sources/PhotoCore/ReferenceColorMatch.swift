import CoreGraphics
import CoreImage
import Foundation

/// A measured OKLab color distribution of a reference photo.
///
/// The profile is deliberately data-only and `Codable` so a recipe (v10) can
/// store the reference look without the reference photo itself. It records the
/// algorithm version so a future transfer change can reject old data instead of
/// silently reinterpreting it.
public struct ReferenceColorProfile: Codable, Equatable {
    /// Bump when the measured fields or the transfer semantics change.
    public static let currentAlgorithmVersion = 1
    /// Number of quantile knots per channel. Knots sit at percentile `i/(n-1)`.
    public static let quantileCount = 17

    public let algorithmVersion: Int
    public let quantileCount: Int
    /// OKLab L quantiles at percentiles 0, 1/16, 2/16, ... 1. Monotone non-decreasing.
    public let luminanceQuantiles: [Double]
    /// OKLab a quantiles at the same percentiles. Monotone non-decreasing.
    public let aQuantiles: [Double]
    /// OKLab b quantiles at the same percentiles. Monotone non-decreasing.
    public let bQuantiles: [Double]
    /// Mean OKLab coordinates of the contributing samples; diagnostics only.
    public let meanL: Double
    public let meanA: Double
    public let meanB: Double
    /// Number of opaque pixels that contributed to the statistics.
    public let sampleCount: Int

    public init(algorithmVersion: Int = ReferenceColorProfile.currentAlgorithmVersion,
                quantileCount: Int = ReferenceColorProfile.quantileCount,
                luminanceQuantiles: [Double],
                aQuantiles: [Double],
                bQuantiles: [Double],
                meanL: Double,
                meanA: Double,
                meanB: Double,
                sampleCount: Int) {
        self.algorithmVersion = algorithmVersion
        self.quantileCount = quantileCount
        self.luminanceQuantiles = luminanceQuantiles
        self.aQuantiles = aQuantiles
        self.bQuantiles = bQuantiles
        self.meanL = meanL
        self.meanA = meanA
        self.meanB = meanB
        self.sampleCount = sampleCount
    }

    /// Rejects profiles that cannot be applied faithfully: unsupported version,
    /// wrong knot count, non-finite values, or non-monotone quantiles (which
    /// would break the monotone transfer the matcher relies on).
    public func validate() throws {
        guard algorithmVersion == Self.currentAlgorithmVersion else {
            throw AtelierError.invalidConfiguration(
                "参考色彩 profile 的算法版本 \(algorithmVersion) 不受支持，需要版本 \(Self.currentAlgorithmVersion)。")
        }
        guard quantileCount == Self.quantileCount else {
            throw AtelierError.invalidConfiguration(
                "参考色彩 profile 的分位数档数 \(quantileCount) 无效，需要 \(Self.quantileCount)。")
        }
        let channels = [("L", luminanceQuantiles), ("a", aQuantiles), ("b", bQuantiles)]
        for (name, values) in channels {
            guard values.count == quantileCount else {
                throw AtelierError.invalidConfiguration("参考色彩 profile 的 \(name) 分位数数量无效。")
            }
            guard values.allSatisfy({ $0.isFinite }) else {
                throw AtelierError.invalidConfiguration("参考色彩 profile 的 \(name) 分位数包含非有限数值。")
            }
            let monotone = zip(values, values.dropFirst()).allSatisfy { pair in
                pair.0 <= pair.1
            }
            guard monotone else {
                throw AtelierError.invalidConfiguration("参考色彩 profile 的 \(name) 分位数不是单调非降的。")
            }
        }
        guard [meanL, meanA, meanB].allSatisfy({ $0.isFinite }) else {
            throw AtelierError.invalidConfiguration("参考色彩 profile 的均值包含非有限数值。")
        }
        guard sampleCount > 0 else {
            throw AtelierError.invalidConfiguration("参考色彩 profile 没有采样像素。")
        }
    }
}

/// Per-photo record of what the reference-color ("AI 追色") stage did.
///
/// It is embedded in `ProcessingReport` so a batch manifest can state, per
/// photo, whether the shared reference profile was applied or explicitly
/// skipped (for example when `skinOnly` found no usable skin mask).
public struct ReferenceColorReport: Codable, Equatable {
    public var applied: Bool
    public var strength: Double
    public var skinOnly: Bool
    /// Profile algorithm version, recorded for manifest traceability.
    public var algorithmVersion: Int?
    public var note: String?

    public init(applied: Bool, strength: Double, skinOnly: Bool,
                algorithmVersion: Int? = nil, note: String? = nil) {
        self.applied = applied
        self.strength = strength
        self.skinOnly = skinOnly
        self.algorithmVersion = algorithmVersion
        self.note = note
    }
}

/// Reference-driven global color matching ("AI 追色") in OKLab.
///
/// Two pure steps keep the reference analysis cacheable:
/// 1. `profile(reference:)` measures the reference's OKLab distribution.
/// 2. `apply(_:to:strength:)` measures the candidate, builds a piecewise-linear
///    monotone transfer from the candidate's quantiles to the reference's
///    quantiles, and applies it with a Core Image kernel.
///
/// Honest limits:
/// - This is a global distribution match. It is not semantic segmentation, does
///   not preserve individual object colors, and is not an aesthetic grade. No
///   parity with commercial color-matching products is claimed.
/// - Statistics come from a bounded downsample (`sampleLimit`, default 4096
///   pixels), so very large images are matched approximately.
/// - The kernel assumes the CIContext working space is extended linear sRGB
///   (the engine's working space). Input linear RGB is clamped to 0...1 and the
///   SDR output is clamped to 0...1 per channel; extended-range highlight
///   headroom is display-clamped here. Callers that need headroom should place
///   this stage where SDR clamping is acceptable.
/// - Alpha is preserved exactly. Fully transparent pixels are left untouched.
///   Partially transparent pixels are matched in unpremultiplied color.
/// - Skin and neutral guards only damp the chroma transfer. They are color
///   heuristics, not face detection, and can be conservative on strongly
///   neutral images.
public enum ReferenceColorMatcher {
    /// Default cap on sampled pixels for both reference and candidate.
    public static let defaultSampleLimit = 4096
    /// Hard cap so a caller cannot request an unbounded render.
    public static let maximumSampleLimit = 1_048_576

    private static let quantileKnotCount = ReferenceColorProfile.quantileCount
    private static let knots = Double(quantileKnotCount - 1)
    /// Transfer lookup resolution. The underlying transfer is piecewise linear
    /// with 16 segments, so a 256-entry lookup keeps interpolation error far
    /// below one 8-bit code value.
    private static let transferResolution = 256
    /// OKLab a/b lookup domain is [-chromaDomain, chromaDomain]; the sRGB gamut
    /// stays well inside it.
    private static let chromaDomain = 0.5
    private static let luminanceDeviationLimit = 0.5
    private static let chromaDeviationLimit = 0.25

    private static let samplingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let samplingContext = CIContext(options: [
        .workingColorSpace: samplingColorSpace,
        .outputColorSpace: samplingColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: false,
        .cacheIntermediates: false
    ])

    /// Measures the reference image's OKLab distribution.
    ///
    /// Measured values are quantized to a 1/65536 binary grid. The grid is far
    /// below a visible OKLab difference and makes JSON recipe round-trips exact
    /// and deterministic on toolchains whose JSON double formatting is lossy at
    /// the last unit in the last place.
    ///
    /// - Parameters:
    ///   - reference: A finite, non-empty image. Images are expected to be in
    ///     extended linear sRGB (the engine's working space).
    ///   - sampleLimit: Maximum number of pixels read from a bounded downsample.
    ///     Must be within `16...maximumSampleLimit`.
    /// - Returns: A versioned, Codable profile.
    /// - Throws: `AtelierError.invalidConfiguration` for invalid extents, an
    ///   invalid sample limit, or an image without opaque pixels.
    public static func profile(reference: CIImage,
                               sampleLimit: Int = defaultSampleLimit) throws -> ReferenceColorProfile {
        let measured = try measure(reference, sampleLimit: sampleLimit)
        return ReferenceColorProfile(luminanceQuantiles: quantiles(of: measured.l).map(quantized),
                                     aQuantiles: quantiles(of: measured.a).map(quantized),
                                     bQuantiles: quantiles(of: measured.b).map(quantized),
                                     meanL: quantized(measured.meanL),
                                     meanA: quantized(measured.meanA),
                                     meanB: quantized(measured.meanB),
                                     sampleCount: measured.count)
    }

    /// Applies a reference profile to a candidate image.
    ///
    /// `apply` performs a bounded downsample render of the candidate to measure
    /// its distribution, then returns a lazy Core Image graph for the transfer;
    /// the full-resolution image is never rendered eagerly here. Immutable
    /// profile/table data is used per call and the shared sampling `CIContext`
    /// is thread-safe, so independent calls may run concurrently.
    ///
    /// `strength` is clamped to `0...1`. A strength of 0 returns the input
    /// image object unchanged (exact identity, no render is forced).
    ///
    /// - Throws: `AtelierError.invalidConfiguration` for an invalid profile,
    ///   non-finite strength, invalid extents, or an image without opaque pixels.
    public static func apply(_ profile: ReferenceColorProfile,
                             to image: CIImage,
                             strength: Double) throws -> CIImage {
        try profile.validate()
        guard strength.isFinite else {
            throw AtelierError.invalidConfiguration("追色强度必须是有限数值。")
        }
        let clampedStrength = min(max(strength, 0), 1)
        guard clampedStrength > 0 else { return image }
        let extent = image.extent
        guard isFiniteNonEmpty(extent) else {
            throw AtelierError.invalidConfiguration("追色需要有限且非空的候选图像范围。")
        }

        let measured = try measure(image, sampleLimit: defaultSampleLimit)
        let source = (l: quantiles(of: measured.l),
                      a: quantiles(of: measured.a),
                      b: quantiles(of: measured.b))
        let transferData = buildTransferData(source: source, target: profile)
        let transferImage = CIImage(bitmapData: transferData,
                                    bytesPerRow: transferResolution * 4 * MemoryLayout<Float>.stride,
                                    size: CGSize(width: transferResolution, height: 1),
                                    format: .RGBAf,
                                    colorSpace: nil)
        guard let kernel = matchKernel else {
            throw AtelierError.invalidConfiguration("Core Image OKLab 追色 kernel 编译失败。")
        }
        let transferSampler = CISampler(image: transferImage, options: [
            kCISamplerFilterMode: kCISamplerFilterNearest,
            kCISamplerWrapMode: kCISamplerWrapClamp
        ])
        guard let output = kernel.apply(extent: extent, roiCallback: { index, rect in
            index == 1 ? transferImage.extent : rect
        }, arguments: [
            CISampler(image: image),
            transferSampler,
            NSNumber(value: clampedStrength)
        ]) else {
            throw AtelierError.invalidConfiguration("Core Image OKLab 追色 kernel 无法生成输出。")
        }
        return output.cropped(to: extent)
    }

    // MARK: - Measurement

    private struct Measurement {
        var l: [Double]
        var a: [Double]
        var b: [Double]
        var meanL: Double
        var meanA: Double
        var meanB: Double
        var count: Int
    }

    private static func measure(_ image: CIImage, sampleLimit: Int) throws -> Measurement {
        let extent = image.extent
        guard isFiniteNonEmpty(extent) else {
            throw AtelierError.invalidConfiguration("追色需要有限且非空的图像范围。")
        }
        guard (16...maximumSampleLimit).contains(sampleLimit) else {
            throw AtelierError.invalidConfiguration(
                "追色采样像素上限必须在 16...\(maximumSampleLimit) 之间。")
        }
        let pixelCount = Double(extent.width) * Double(extent.height)
        let scale = pixelCount > Double(sampleLimit)
            ? sqrt(Double(sampleLimit) / pixelCount)
            : 1
        let width = max(1, Int((Double(extent.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(extent.height) * scale).rounded(.down)))
        let (sampleArea, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, sampleArea > 0, sampleArea <= maximumSampleLimit else {
            throw AtelierError.invalidConfiguration("追色采样尺寸无效。")
        }
        let (floatCount, floatOverflow) = sampleArea.multipliedReportingOverflow(by: 4)
        guard !floatOverflow else {
            throw AtelierError.invalidConfiguration("追色采样缓冲区过大。")
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let translated = image.transformed(by: CGAffineTransform(translationX: -extent.minX,
                                                                  y: -extent.minY))
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width,
                                                                   y: CGFloat(height) / extent.height))
        // Edge-clamp before cropping so extreme aspect ratios and rounding never
        // read transparent pixels outside the scaled image.
        let sampled = scaled.clampedToExtent().cropped(to: bounds)
        var pixels = [Float](repeating: 0, count: floatCount)
        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            samplingContext.render(sampled, toBitmap: baseAddress,
                                   rowBytes: width * 4 * MemoryLayout<Float>.stride,
                                   bounds: bounds, format: .RGBAf,
                                   colorSpace: samplingColorSpace)
        }

        var luminances: [Double] = []
        var aValues: [Double] = []
        var bValues: [Double] = []
        luminances.reserveCapacity(sampleArea)
        aValues.reserveCapacity(sampleArea)
        bValues.reserveCapacity(sampleArea)
        var sumL = 0.0, sumA = 0.0, sumB = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3])
            guard alpha.isFinite, alpha > 0.001 else { continue }
            // The context renders unpremultiplied RGBAf; do not divide by alpha.
            let red = Double(pixels[offset])
            let green = Double(pixels[offset + 1])
            let blue = Double(pixels[offset + 2])
            guard red.isFinite, green.isFinite, blue.isFinite else { continue }
            // Match the kernel's SDR input clamp so profile and candidate
            // statistics describe the same values the transfer sees.
            let lab = linearRGBToOKLab(r: min(max(red, 0), 1),
                                       g: min(max(green, 0), 1),
                                       b: min(max(blue, 0), 1))
            guard lab.l.isFinite, lab.a.isFinite, lab.b.isFinite else { continue }
            luminances.append(lab.l)
            aValues.append(lab.a)
            bValues.append(lab.b)
            sumL += lab.l
            sumA += lab.a
            sumB += lab.b
        }
        guard !luminances.isEmpty else {
            throw AtelierError.invalidConfiguration("图像没有可用的不透明像素，无法进行参考追色。")
        }
        let count = Double(luminances.count)
        return Measurement(l: luminances, a: aValues, b: bValues,
                           meanL: sumL / count, meanA: sumA / count, meanB: sumB / count,
                           count: luminances.count)
    }

    /// Linear-interpolated quantiles at the fixed percentile grid.
    private static func quantiles(of values: [Double]) -> [Double] {
        let sorted = values.sorted()
        guard let first = sorted.first, let last = sorted.last else {
            return Array(repeating: 0, count: quantileKnotCount)
        }
        guard sorted.count > 1, last > first else {
            return Array(repeating: first, count: quantileKnotCount)
        }
        return (0..<quantileKnotCount).map { index in
            let position = Double(index) / knots * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, sorted.count - 1)
            let fraction = position - Double(lower)
            return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
        }
    }

    // MARK: - Transfer

    /// Piecewise-linear monotone quantile transfer: `Q_target(F_source(value))`.
    ///
    /// A degenerate source channel (all samples equal) maps to the target
    /// median, which is exactly identity when source and target are the same
    /// flat image. The result is limited to `value ± deviationLimit` so an
    /// extreme reference cannot crush a channel wholesale.
    private static func quantileTransfer(source: [Double],
                                         target: [Double],
                                         value: Double,
                                         deviationLimit: Double) -> Double {
        let mapped: Double
        if source[quantileKnotCount - 1] - source[0] <= 0.000001 {
            mapped = target[quantileKnotCount / 2]
        } else {
            var segment = quantileKnotCount - 2
            for index in 0..<(quantileKnotCount - 1) where value <= source[index + 1] {
                segment = index
                break
            }
            let span = source[segment + 1] - source[segment]
            var fraction = span > 0.000000000001 ? (value - source[segment]) / span : 0
            fraction = min(max(fraction, 0), 1)
            let position = (Double(segment) + fraction) / knots
            let targetPosition = position * knots
            let lower = min(Int(targetPosition.rounded(.down)), quantileKnotCount - 2)
            let targetFraction = targetPosition - Double(lower)
            mapped = target[lower] + (target[lower + 1] - target[lower]) * targetFraction
        }
        return min(max(mapped, value - deviationLimit), value + deviationLimit)
    }

    /// Builds a 256×1 RGBAf table where each entry holds the mapped OKLab
    /// coordinates for lookup unit `u = index/(resolution-1)`:
    /// `r = mapped L(u)`, `g = mapped a(-0.5 + u)`, `b = mapped b(-0.5 + u)`.
    private static func buildTransferData(source: (l: [Double], a: [Double], b: [Double]),
                                          target: ReferenceColorProfile) -> Data {
        var values = [Float](repeating: 0, count: transferResolution * 4)
        for index in 0..<transferResolution {
            let unit = Double(index) / Double(transferResolution - 1)
            let luminance = quantileTransfer(source: source.l,
                                             target: target.luminanceQuantiles,
                                             value: unit,
                                             deviationLimit: luminanceDeviationLimit)
            let chromaValue = -chromaDomain + unit * chromaDomain * 2
            let aValue = quantileTransfer(source: source.a,
                                          target: target.aQuantiles,
                                          value: chromaValue,
                                          deviationLimit: chromaDeviationLimit)
            let bValue = quantileTransfer(source: source.b,
                                          target: target.bQuantiles,
                                          value: chromaValue,
                                          deviationLimit: chromaDeviationLimit)
            let offset = index * 4
            values[offset] = Float(min(max(luminance, 0), 1))
            values[offset + 1] = Float(min(max(aValue, -chromaDomain), chromaDomain))
            values[offset + 2] = Float(min(max(bValue, -chromaDomain), chromaDomain))
            values[offset + 3] = 1
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Kernel

    // The transfer table is sampled with nearest filtering and interpolated
    // manually, matching the backend-independent lookup pattern already used
    // for LUTs. OKLab is computed in the kernel so the mapping stays exact
    // rather than relying on color-cube interpolation.
    private static let kernelSource = """
    float signedCubeRoot(float value) {
        return sign(value) * pow(abs(value), 1.0 / 3.0);
    }
    vec3 linearRGBToOKLab(vec3 rgb) {
        float l = 0.4122214708 * rgb.r + 0.5363325363 * rgb.g + 0.0514459929 * rgb.b;
        float m = 0.2119034982 * rgb.r + 0.6806995451 * rgb.g + 0.1073969566 * rgb.b;
        float s = 0.0883024619 * rgb.r + 0.2817188376 * rgb.g + 0.6299787005 * rgb.b;
        vec3 roots = vec3(signedCubeRoot(l), signedCubeRoot(m), signedCubeRoot(s));
        return vec3(
            0.2104542553 * roots.x + 0.7936177850 * roots.y - 0.0040720468 * roots.z,
            1.9779984951 * roots.x - 2.4285922050 * roots.y + 0.4505937099 * roots.z,
            0.0259040371 * roots.x + 0.7827717662 * roots.y - 0.8086757660 * roots.z
        );
    }
    vec3 oklabToLinearRGB(vec3 lab) {
        float l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
        float m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
        float s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
        l = l * l * l;
        m = m * m * m;
        s = s * s * s;
        return vec3(
             4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        );
    }
    float smoothRamp(float low, float high, float value) {
        float t = clamp((value - low) / max(high - low, 0.000001), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }
    vec4 transferSample(sampler transferTable, float unit) {
        float position = clamp(unit, 0.0, 1.0) * 255.0;
        float lower = floor(position);
        float upper = min(lower + 1.0, 255.0);
        float fraction = position - lower;
        vec4 lowValue = sample(transferTable,
                               samplerTransform(transferTable, vec2(lower + 0.5, 0.5)));
        vec4 highValue = sample(transferTable,
                                samplerTransform(transferTable, vec2(upper + 0.5, 0.5)));
        return mix(lowValue, highValue, fraction);
    }
    kernel vec4 matchReferenceColor(sampler source, sampler transferTable, float strength) {
        vec4 sourceSample = sample(source, samplerCoord(source));
        float alpha = clamp(sourceSample.a, 0.0, 1.0);
        if (alpha <= 0.000001) { return vec4(0.0); }
        vec3 linear = clamp(sourceSample.rgb / alpha, vec3(0.0), vec3(1.0));
        vec3 lab = linearRGBToOKLab(linear);
        float chroma = length(lab.yz);
        // Neutral guard: damp chroma transfer on near-neutral pixels so a
        // reference tint does not paint specular/neutral areas unnaturally.
        float neutralGuard = mix(0.55, 1.0, smoothRamp(0.006, 0.030, chroma));
        // Skin-like OKLab hue band (positive a/b, moderate chroma); heuristic
        // only, not face detection.
        float skinHue = smoothRamp(0.015, 0.035, lab.y) * smoothRamp(0.015, 0.035, lab.z)
                      * (1.0 - smoothRamp(0.25, 0.45, lab.y))
                      * (1.0 - smoothRamp(0.25, 0.45, lab.z));
        float skinLight = smoothRamp(0.15, 0.28, lab.x) * (1.0 - smoothRamp(0.92, 0.99, lab.x));
        float chromaStrength = strength * neutralGuard * mix(1.0, 0.72, skinHue * skinLight);
        float mappedL = mix(lab.x, transferSample(transferTable, lab.x).r, strength);
        float mappedA = mix(lab.y, transferSample(transferTable, lab.y + 0.5).g, chromaStrength);
        float mappedB = mix(lab.z, transferSample(transferTable, lab.z + 0.5).b, chromaStrength);
        vec3 matched = vec3(clamp(mappedL, 0.0, 1.0),
                            clamp(mappedA, -0.5, 0.5),
                            clamp(mappedB, -0.5, 0.5));
        vec3 outputRGB = clamp(oklabToLinearRGB(matched), vec3(0.0), vec3(1.0));
        return vec4(outputRGB * alpha, alpha);
    }
    """

    private static let matchKernel = CIKernel(source: kernelSource)

    // MARK: - Helpers

    /// Binary quantization grid for profile values; see `profile(reference:sampleLimit:)`.
    private static let quantizationScale = 65536.0

    private static func quantized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * quantizationScale).rounded() / quantizationScale
    }

    private static func linearRGBToOKLab(r: Double, g: Double, b: Double) -> (l: Double, a: Double, b: Double) {
        func root(_ value: Double) -> Double { copysign(pow(abs(value), 1.0 / 3.0), value) }
        let l = root(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = root(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = root(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private static func isFiniteNonEmpty(_ extent: CGRect) -> Bool {
        !extent.isNull && !extent.isInfinite &&
        extent.minX.isFinite && extent.minY.isFinite &&
        extent.width.isFinite && extent.height.isFinite &&
        extent.width > 0 && extent.height > 0
    }
}

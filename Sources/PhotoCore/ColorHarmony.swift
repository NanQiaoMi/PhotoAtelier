import CoreImage
import Foundation

/// Conservative limits on color introduced by local adjustments and LUTs.
/// This is a perceptual guard, not semantic segmentation or an aesthetic grade.
public struct ColorHarmonySettings: Codable, Equatable {
    public var enabled: Bool = true
    public var amount: Double = 0.65
    public var detailProtection: Double = 0.65
    public var saturatedProtection: Double = 0.65

    public init() {}
}

public enum ColorHarmonyEngine {
    private static let kernelSource = """
    float signedCubeRoot(float value) {
        return sign(value) * pow(abs(value), 1.0 / 3.0);
    }
    vec3 rgbToOKLab(vec3 rgb) {
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
    vec3 oklabToRGB(vec3 lab) {
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
    float smooth01(float low, float high, float value) {
        float t = clamp((value - low) / max(high - low, 0.000001), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }
    vec3 straightRGB(__sample sampleValue) {
        return sampleValue.a > 0.000001 ? sampleValue.rgb / sampleValue.a : vec3(0.0);
    }

    kernel vec4 harmonize(__sample referenceSample,
                          __sample candidateSample,
                          __sample referenceBlurSample,
                          float amount,
                          float detailProtection,
                          float saturatedProtection,
                          float hasScene,
                          float sceneSaturated,
                          float sceneNeutral,
                          float sceneDark,
                          float sceneBright,
                          float sceneDiversity,
                          float diagnosticMode) {
        float alpha = clamp(candidateSample.a, 0.0, 1.0);
        if (alpha <= 0.000001) { return vec4(0.0); }
        if (referenceSample.a <= 0.000001) {
            if (diagnosticMode > 0.5) { return vec4(0.0, 0.0, 0.0, alpha); }
            return vec4(candidateSample.rgb, alpha);
        }

        vec3 reference = straightRGB(referenceSample);
        vec3 candidate = straightRGB(candidateSample);
        vec3 blurredReference = straightRGB(referenceBlurSample);
        vec3 refLab = rgbToOKLab(reference);
        vec3 candidateLab = rgbToOKLab(candidate);
        vec3 blurLab = rgbToOKLab(blurredReference);
        vec2 referenceChroma = refLab.yz;
        vec2 candidateChroma = candidateLab.yz;

        // In linear RGB a pure exposure change scales luminance directly and OKLab a/b
        // by its cube root. Matching that relationship avoids treating exposure as tint.
        float referenceY = dot(reference, vec3(0.2126, 0.7152, 0.0722));
        float candidateY = dot(candidate, vec3(0.2126, 0.7152, 0.0722));
        float exposureRatio = 1.0;
        if (abs(referenceY) > 0.00001 && candidateY / referenceY > 0.0) {
            exposureRatio = clamp(candidateY / referenceY, 0.00390625, 256.0);
        }
        vec2 expectedChroma = referenceChroma * pow(exposureRatio, 1.0 / 3.0);
        float expectedMagnitude = length(expectedChroma);
        float candidateMagnitude = length(candidateChroma);
        float chromaDelta = length(candidateChroma - expectedChroma);

        float neutralWeight = 1.0 - smooth01(0.018, 0.075, expectedMagnitude);
        float diversity = hasScene > 0.5 ? clamp(sceneDiversity, 0.0, 1.0) : 0.5;
        float neutralFraction = hasScene > 0.5 ? clamp(sceneNeutral, 0.0, 1.0) : 0.25;
        float saturatedFraction = hasScene > 0.5 ? clamp(sceneSaturated, 0.0, 1.0) : 0.25;
        float darkFraction = hasScene > 0.5 ? clamp(sceneDark, 0.0, 1.0) : 0.25;
        float brightFraction = hasScene > 0.5 ? clamp(sceneBright, 0.0, 1.0) : 0.25;

        float neutralThreshold = mix(0.014, 0.005, neutralFraction);
        float chromaticThreshold = expectedMagnitude * mix(0.24, 0.12, saturatedFraction)
                                 + 0.008 + 0.012 * diversity;
        float transition = mix(0.085, 0.030, neutralWeight) + 0.20 * expectedMagnitude;
        float neutralAnomaly = smooth01(neutralThreshold, neutralThreshold + transition,
                                        chromaDelta);
        float growth = max(candidateMagnitude - expectedMagnitude, 0.0);
        float growthAnomaly = smooth01(chromaticThreshold,
                                       chromaticThreshold + transition, growth);
        float chromaProduct = max(candidateMagnitude * expectedMagnitude, 0.000001);
        float hueChange = 0.5 * (1.0 - clamp(dot(candidateChroma, expectedChroma)
                                            / chromaProduct, -1.0, 1.0));
        float hueSupport = smooth01(0.014, 0.055, candidateMagnitude)
                         * smooth01(0.018, 0.070, expectedMagnitude);
        float hueAnomaly = smooth01(0.12, 0.52, hueChange) * hueSupport;
        float chromaticAnomaly = max(growthAnomaly, hueAnomaly);
        float anomaly = candidateMagnitude < expectedMagnitude
            ? hueAnomaly
            : mix(chromaticAnomaly, neutralAnomaly, neutralWeight);

        // Use reference-local high-pass energy to raise correction around real edges
        // and texture. The blur radius is scaled to the image before this kernel runs.
        float detailEnergy = abs(refLab.x - blurLab.x)
                           + 0.45 * length(refLab.yz - blurLab.yz);
        float detailWeight = smooth01(0.010, 0.085, detailEnergy);
        float detailFactor = 1.0 + clamp(detailProtection, 0.0, 1.0) * detailWeight * 2.0;

        float darkWeight = 1.0 - smooth01(0.045, 0.38, max(refLab.x, 0.0));
        float brightWeight = smooth01(0.74, 1.03, max(refLab.x, 0.0));
        float tonalFactor = 1.0 + 0.25 * darkWeight * darkFraction
                               + 0.18 * brightWeight * brightFraction;
        float diverseSceneFactor = 0.82 + 0.18 * (1.0 - diversity);
        float saturatedRisk = smooth01(0.055, 0.22, expectedMagnitude)
                            * saturatedProtection * (0.45 + 0.55 * saturatedFraction);
        float sceneColorFactor = mix(1.0, 1.18, saturatedRisk);
        float guard = clamp(amount * anomaly * detailFactor * tonalFactor
                                  * diverseSceneFactor * sceneColorFactor, 0.0, 0.96);

        if (diagnosticMode > 0.5) {
            float risk = clamp(anomaly * detailFactor * tonalFactor
                                     * diverseSceneFactor * sceneColorFactor, 0.0, 1.0);
            return vec4(vec3(risk * alpha), alpha);
        }

        vec2 protectedTarget = expectedChroma;
        if (candidateMagnitude < expectedMagnitude && expectedMagnitude > 0.00001) {
            // Correct a hue discontinuity at the candidate's current radius, so a
            // deliberate reduction in saturation is never pulled back toward the source.
            protectedTarget = expectedChroma * (candidateMagnitude / expectedMagnitude);
        }
        vec2 protectedChroma = mix(candidateChroma, protectedTarget, guard);
        vec3 outputRGB = oklabToRGB(vec3(candidateLab.x, protectedChroma));
        // The opponent adjustment can move linear luminance slightly. Restore the
        // candidate's exact linear-light Y without clipping its extended RGB values.
        float outputY = dot(outputRGB, vec3(0.2126, 0.7152, 0.0722));
        if (abs(outputY) > 0.00001 && candidateY * outputY > 0.0) {
            outputRGB *= candidateY / outputY;
        }
        // RGB remains extended-range; output gamut policy belongs to the caller.
        return vec4(outputRGB * alpha, alpha);
    }
    """

    private static let harmonyKernel = CIColorKernel(source: kernelSource)

    public static func validate(_ settings: ColorHarmonySettings) throws {
        func require(_ value: Double, _ label: String) throws {
            guard value.isFinite, (0...1).contains(value) else {
                throw AtelierError.invalidConfiguration("色彩保护\(label)必须在 0...1 范围内。")
            }
        }
        try require(settings.amount, "强度")
        try require(settings.detailProtection, "细节保护")
        try require(settings.saturatedProtection, "高饱和保护")
    }

    public static func protect(reference: CIImage,
                               candidate: CIImage,
                               settings: ColorHarmonySettings,
                               scene: ColorSceneProfile?,
                               context: CIContext) throws -> CIImage {
        try validate(settings)
        guard settings.enabled, settings.amount > 0 else { return candidate }
        return try render(reference: reference, candidate: candidate, settings: settings,
                          scene: scene, diagnosticMode: false, context: context)
    }

    /// Returns a one-channel 0...1 risk visualization using the default protection profile.
    public static func chromaRiskMask(reference: CIImage,
                                      candidate: CIImage,
                                      context: CIContext) throws -> CIImage {
        var settings = ColorHarmonySettings()
        settings.amount = 1
        return try render(reference: reference, candidate: candidate, settings: settings,
                          scene: nil, diagnosticMode: true, context: context)
    }

    private static func render(reference: CIImage,
                               candidate: CIImage,
                               settings: ColorHarmonySettings,
                               scene: ColorSceneProfile?,
                               diagnosticMode: Bool,
                               context: CIContext) throws -> CIImage {
        let extent = candidate.extent
        guard isFiniteNonEmpty(extent), isFiniteNonEmpty(reference.extent) else {
            throw AtelierError.invalidConfiguration("色彩保护需要有限且非空的参考图和候选图范围。")
        }
        guard let kernel = harmonyKernel else {
            throw AtelierError.invalidConfiguration("Core Image OKLab 色彩保护 kernel 编译失败。")
        }

        // The Gaussian radius is 3% of the shorter output dimension, with no
        // pixel-size cap, so preview and export use the same normalized footprint.
        let shorterDimension = min(extent.width, extent.height)
        let blurRadius = shorterDimension * 0.03
        let blurredReference = reference.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: reference.extent)

        let profile = scene.map { value in
            [value.saturatedFraction, value.neutralFraction, value.darkFraction,
             value.brightFraction, value.colorDiversity].map {
                $0.isFinite ? Float(min(max($0, 0), 1)) : 0.0
            }
        } ?? [0, 0, 0, 0, 0]
        let sceneFlag: Float = scene == nil ? 0 : 1
        guard let output = kernel.apply(extent: extent, arguments: [
            reference,
            candidate,
            blurredReference,
            NSNumber(value: settings.amount),
            NSNumber(value: settings.detailProtection),
            NSNumber(value: settings.saturatedProtection),
            NSNumber(value: sceneFlag),
            NSNumber(value: profile[0]),
            NSNumber(value: profile[1]),
            NSNumber(value: profile[2]),
            NSNumber(value: profile[3]),
            NSNumber(value: profile[4]),
            NSNumber(value: diagnosticMode ? 1 : 0)
        ]) else {
            throw AtelierError.invalidConfiguration("Core Image OKLab 色彩保护无法生成输出。")
        }
        _ = context // CIImage evaluation uses the caller's context when rendered.
        return output.cropped(to: extent)
    }

    private static func isFiniteNonEmpty(_ extent: CGRect) -> Bool {
        !extent.isNull && !extent.isInfinite &&
        extent.minX.isFinite && extent.minY.isFinite &&
        extent.width.isFinite && extent.height.isFinite &&
        extent.width > 0 && extent.height > 0
    }
}

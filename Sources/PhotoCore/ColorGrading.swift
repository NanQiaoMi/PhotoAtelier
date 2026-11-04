import CoreGraphics
import CoreImage
import Foundation

// MARK: - Settings

/// One color-grading wheel (shadows / midtones / highlights / global).
///
/// - `hueDegrees` is the OKLab hue direction of the tint (0...360).
/// - `saturation` is the tint strength (0...1; 0 means no tint).
/// - `luminance` is a perceptual lightness offset (-1...1; ±0.12 OKLab L at full
///   range) applied to the same tonal region.
///
/// `hueDegrees` has no effect while `saturation == 0`, so a wheel is neutral when
/// both saturation and luminance are zero.
public struct ColorGradingWheel: Codable, Equatable {
    public var hueDegrees: Double
    public var saturation: Double
    public var luminance: Double

    public init(hueDegrees: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hueDegrees = hueDegrees
        self.saturation = saturation
        self.luminance = luminance
    }

    /// True when this wheel cannot change pixels.
    public var isNeutral: Bool {
        saturation == 0 && luminance == 0
    }
}

/// Three-way color grading plus a global tint and a tonal balance control.
///
/// Tonal regions are weighted by OKLab lightness with Gaussian weights centered
/// at 0.15 (shadows), 0.50 (midtones) and 0.85 (highlights); the weights are
/// normalized so the three wheels always partition the tonal range. `balance`
/// shifts all three pivots by ±0.10: positive values move the shadow weight up
/// toward the midtones (more of the image treated as shadows), negative values
/// move it down toward the highlights.
///
/// Neutral protection: tint and lightness offsets are damped near pure black and
/// pure white and the resulting chroma is clamped, so grading cannot posterize
/// the ends of the range. This is a color-grading heuristic, not a 3D LUT.
public struct ColorGradingSettings: Codable, Equatable {
    public var shadows = ColorGradingWheel()
    public var midtones = ColorGradingWheel()
    public var highlights = ColorGradingWheel()
    /// Uniform tint/lightness applied to every tonal region.
    public var global = ColorGradingWheel()
    public var balance: Double

    public init(shadows: ColorGradingWheel = ColorGradingWheel(),
                midtones: ColorGradingWheel = ColorGradingWheel(),
                highlights: ColorGradingWheel = ColorGradingWheel(),
                global: ColorGradingWheel = ColorGradingWheel(),
                balance: Double = 0) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
        self.global = global
        self.balance = balance
    }

    /// True when no wheel can change pixels (balance alone has no effect).
    public var isNeutral: Bool {
        shadows.isNeutral && midtones.isNeutral && highlights.isNeutral && global.isNeutral
    }

    public func validate() throws {
        for (name, wheel) in [("阴影", shadows), ("中间调", midtones),
                              ("高光", highlights), ("全局", global)] {
            try ColorToolValidation.require(wheel.hueDegrees, within: 0...360,
                                            named: "\(name)色轮色相")
            try ColorToolValidation.require(wheel.saturation, within: 0...1,
                                            named: "\(name)色轮饱和度")
            try ColorToolValidation.require(wheel.luminance, within: -1...1,
                                            named: "\(name)色轮亮度")
        }
        try ColorToolValidation.require(balance, within: -1...1, named: "颜色分级平衡")
    }
}

// MARK: - Engine

/// Applies three-way color grading.
///
/// Pipeline stage: last color tool, after curves and HSL, before lens effects.
/// The kernel works in OKLab on extended linear sRGB input and returns clamped
/// [0,1] linear RGB, matching the rest of the v11 color-tool chain.
///
/// Limits: this is a smooth tonal-region tint, not a hue-vs-saturation
/// secondary; very saturated input can reach the chroma ceiling and large
/// offsets are limited to keep the result inside the SDR range.
public enum ColorGradingEngine {
    /// OKLab chroma offset at `saturation == 1` for a wheel.
    public static let maximumWheelChroma = 0.10
    /// OKLab lightness offset at `luminance == ±1` for a wheel.
    public static let maximumWheelLightness = 0.12
    /// Total chroma offset magnitude limit after summing wheels.
    public static let maximumTotalChromaOffset = 0.12
    /// Total lightness offset limit after summing wheels.
    public static let maximumTotalLightnessOffset = 0.12
    /// Resulting OKLab chroma ceiling.
    public static let maximumChroma = 0.35

    private static let kernel = CIColorKernel(source: ColorToolKernelMath.oklabFunctions + """
    float gradingWeight(float lightness, float pivot) {
        float distance = (lightness - pivot) / 0.22;
        return exp(-distance * distance);
    }
    vec2 gradingOffset(float hue, float saturation) {
        float radians = hue * 0.017453292519943295;
        return vec2(cos(radians), sin(radians)) * saturation * 0.10;
    }
    kernel vec4 applyColorGrading(__sample source,
                                  float sHue, float sSat, float sLum,
                                  float mHue, float mSat, float mLum,
                                  float hHue, float hSat, float hLum,
                                  float gHue, float gSat, float gLum,
                                  float balance) {
        float alpha = clamp(source.a, 0.0, 1.0);
        if (alpha <= 0.000001) { return vec4(0.0); }
        vec3 rgb = clamp(source.rgb / alpha, vec3(0.0), vec3(1.0));
        vec3 lab = rgbToOKLab(rgb);
        float lightness = lab.x;

        float shadowPivot = 0.15 + balance * 0.10;
        float midPivot = 0.50 + balance * 0.10;
        float highlightPivot = 0.85 + balance * 0.10;
        float shadowWeight = gradingWeight(lightness, shadowPivot);
        float midWeight = gradingWeight(lightness, midPivot);
        float highlightWeight = gradingWeight(lightness, highlightPivot);
        float total = shadowWeight + midWeight + highlightWeight + 0.000001;
        shadowWeight /= total;
        midWeight /= total;
        highlightWeight /= total;

        vec2 shadowOffset = gradingOffset(sHue, sSat);
        vec2 midOffset = gradingOffset(mHue, mSat);
        vec2 highlightOffset = gradingOffset(hHue, hSat);
        vec2 globalOffset = gradingOffset(gHue, gSat);
        vec2 chromaOffset = shadowWeight * shadowOffset
                          + midWeight * midOffset
                          + highlightWeight * highlightOffset
                          + globalOffset;
        float lightnessOffset = shadowWeight * sLum * 0.12
                              + midWeight * mLum * 0.12
                              + highlightWeight * hLum * 0.12
                              + gLum * 0.12;

        // End-point protection: do not posterize pure black/white, and limit the
        // summed offsets so a stack of wheels cannot leave the SDR range.
        float edgeGuard = smoothstep(0.005, 0.05, lightness)
                        * (1.0 - smoothstep(0.95, 0.995, lightness));
        chromaOffset *= edgeGuard;
        lightnessOffset *= edgeGuard;
        float chromaLength = length(chromaOffset);
        if (chromaLength > 0.12) {
            chromaOffset *= 0.12 / chromaLength;
        }
        lightnessOffset = clamp(lightnessOffset, -0.12, 0.12);

        vec2 targetAB = lab.yz + chromaOffset;
        float targetChroma = length(targetAB);
        if (targetChroma > 0.35) {
            targetAB *= 0.35 / targetChroma;
        }
        vec3 targetLab = vec3(clamp(lightness + lightnessOffset, 0.0, 1.0), targetAB);
        vec3 outputRGB = clamp(oklabToRGB(targetLab), vec3(0.0), vec3(1.0));
        return vec4(outputRGB * alpha, alpha);
    }
    """)

    public static func validate(_ settings: ColorGradingSettings) throws {
        try settings.validate()
    }

    /// Applies the grading. A neutral setting returns `image` itself.
    public static func apply(_ settings: ColorGradingSettings,
                             to image: CIImage,
                             cancellation: CancellationToken? = nil) throws -> CIImage {
        try validate(settings)
        guard !settings.isNeutral else { return image }
        let extent = try ColorToolValidation.validExtent(of: image)
        try cancellation?.check()
        guard let kernel else {
            throw AtelierError.invalidConfiguration("Core Image 颜色分级 kernel 编译失败。")
        }
        let wheels = [settings.shadows, settings.midtones, settings.highlights, settings.global]
        var arguments: [Any] = [image]
        for wheel in wheels {
            arguments.append(NSNumber(value: wheel.hueDegrees))
            arguments.append(NSNumber(value: wheel.saturation))
            arguments.append(NSNumber(value: wheel.luminance))
        }
        arguments.append(NSNumber(value: settings.balance))
        guard let output = kernel.apply(extent: extent, arguments: arguments) else {
            throw AtelierError.invalidConfiguration("Core Image 颜色分级 kernel 无法生成输出。")
        }
        return output.cropped(to: extent)
    }
}

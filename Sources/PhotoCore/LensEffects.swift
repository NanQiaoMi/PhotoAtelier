import CoreGraphics
import CoreImage
import Foundation

/// Optical lens-style effects: vignette and lateral chromatic aberration.
///
/// Pipeline stage: after the color tools, before portrait refinement (see the
/// v11 pipeline order in `docs/p1-implementation-plan.md`). Both effects operate
/// on extended linear sRGB and return display-clamped [0,1] linear RGB.
///
/// Semantics:
/// - **Vignette** applies a radial gain to the whole frame. `amount` is signed:
///   positive darkens the corners, negative brightens them. `midpoint` is the
///   normalized radius where the falloff is centered, `feather` is the width of
///   the transition and `roundness` blends between a circular falloff (1) and a
///   squarer superellipse (0). The exact center is never changed.
/// - **Chromatic aberration** displaces the red and blue channels radially from
///   the center by a small scale (at most ±0.4% radius at full range). The green
///   channel and the image geometry are unchanged; this models lateral CA, not
///   axial (color fringing in out-of-focus areas).
///
/// Limits: the vignette is a smooth gain, not a physically measured lens
/// profile; the aberration is a display-scale approximation, not a per-lens
/// calibration. Extreme values are clamped so the result stays inside SDR.
public struct LensEffectsSettings: Codable, Equatable {
    /// Signed vignette strength (-1...1).
    public var vignetteAmount: Double
    /// Normalized radius (0...1) of the falloff midpoint.
    public var vignetteMidpoint: Double
    /// Falloff transition width (0...1).
    public var vignetteFeather: Double
    /// Falloff shape: 1 = circular, 0 = squarer superellipse.
    public var vignetteRoundness: Double
    /// Radial red-channel displacement (-1...1, scaled to ±0.4% radius).
    public var chromaticAberrationRed: Double
    /// Radial blue-channel displacement (-1...1, scaled to ±0.4% radius).
    public var chromaticAberrationBlue: Double

    public init(vignetteAmount: Double = 0,
                vignetteMidpoint: Double = 0.5,
                vignetteFeather: Double = 0.5,
                vignetteRoundness: Double = 1,
                chromaticAberrationRed: Double = 0,
                chromaticAberrationBlue: Double = 0) {
        self.vignetteAmount = vignetteAmount
        self.vignetteMidpoint = vignetteMidpoint
        self.vignetteFeather = vignetteFeather
        self.vignetteRoundness = vignetteRoundness
        self.chromaticAberrationRed = chromaticAberrationRed
        self.chromaticAberrationBlue = chromaticAberrationBlue
    }

    /// True when no effect can change pixels.
    public var isNeutral: Bool {
        vignetteAmount == 0 && chromaticAberrationRed == 0 && chromaticAberrationBlue == 0
    }

    public func validate() throws {
        try ColorToolValidation.require(vignetteAmount, within: -1...1, named: "暗角强度")
        try ColorToolValidation.require(vignetteMidpoint, within: 0...1, named: "暗角中点")
        try ColorToolValidation.require(vignetteFeather, within: 0...1, named: "暗角羽化")
        try ColorToolValidation.require(vignetteRoundness, within: 0...1, named: "暗角圆度")
        try ColorToolValidation.require(chromaticAberrationRed, within: -1...1, named: "红色差")
        try ColorToolValidation.require(chromaticAberrationBlue, within: -1...1, named: "蓝色差")
    }
}

/// Applies vignette and lateral chromatic aberration.
///
/// Both kernels are Core Image kernels (a color kernel for the vignette gain and
/// a general kernel with a source sampler for the radial channel displacement,
/// which needs neighbour sampling).
public enum LensEffectsEngine {
    /// Radial scale applied to a channel at `±1` chromatic-aberration setting.
    public static let maximumChromaticAberrationScale = 0.004

    private static let vignetteKernel = CIColorKernel(source: """
    kernel vec4 applyLensVignette(__sample source, vec4 bounds,
                                  float amount, float midpoint, float feather, float roundness) {
        float alpha = clamp(source.a, 0.0, 1.0);
        if (alpha <= 0.000001) { return vec4(0.0); }
        vec2 dimensions = max(bounds.zw, vec2(1.0));
        vec2 center = bounds.xy + dimensions * 0.5;
        vec2 halfSize = max(dimensions * 0.5, vec2(0.5));
        vec2 offset = destCoord() - center;
        vec2 normalized = vec2(offset.x / halfSize.x, offset.y / halfSize.y);
        float exponent = mix(4.0, 2.0, clamp(roundness, 0.0, 1.0));
        float radius = pow(pow(abs(normalized.x), exponent)
                           + pow(abs(normalized.y), exponent), 1.0 / exponent);
        float width = mix(0.05, 1.0, clamp(feather, 0.0, 1.0));
        float start = clamp(midpoint, 0.0, 1.0) - width * 0.5;
        float edge = smoothstep(start, start + width, radius);
        float gain = clamp(1.0 - amount * edge, 0.0, 4.0);
        return vec4(source.rgb * gain, alpha);
    }
    """)

    private static let chromaticAberrationKernel = CIKernel(source: """
    kernel vec4 applyLensChromaticAberration(sampler source, vec4 bounds,
                                             float redScale, float blueScale) {
        vec4 sampleValue = sample(source, samplerCoord(source));
        float alpha = clamp(sampleValue.a, 0.0, 1.0);
        if (alpha <= 0.000001) { return vec4(0.0); }
        vec2 dimensions = max(bounds.zw, vec2(1.0));
        vec2 center = bounds.xy + dimensions * 0.5;
        vec2 halfSize = max(dimensions * 0.5, vec2(0.5));
        vec2 offset = destCoord() - center;
        vec2 normalized = vec2(offset.x / halfSize.x, offset.y / halfSize.y);
        float radius = length(normalized);
        vec2 redCoordinate = center + offset * (1.0 + redScale * radius);
        vec2 blueCoordinate = center + offset * (1.0 + blueScale * radius);
        vec4 redSample = sample(source, samplerTransform(source, redCoordinate));
        vec4 blueSample = sample(source, samplerTransform(source, blueCoordinate));
        float red = redSample.a > 0.000001 ? redSample.r / redSample.a : 0.0;
        float green = sampleValue.g / alpha;
        float blue = blueSample.a > 0.000001 ? blueSample.b / blueSample.a : 0.0;
        vec3 rgb = clamp(vec3(red, green, blue), vec3(0.0), vec3(1.0));
        return vec4(rgb * alpha, alpha);
    }
    """)

    public static func validate(_ settings: LensEffectsSettings) throws {
        try settings.validate()
    }

    /// Applies the lens effects. A neutral setting returns `image` itself.
    public static func apply(_ settings: LensEffectsSettings,
                             to image: CIImage,
                             cancellation: CancellationToken? = nil) throws -> CIImage {
        try validate(settings)
        guard !settings.isNeutral else { return image }
        let extent = try ColorToolValidation.validExtent(of: image)
        try cancellation?.check()
        var output = image

        // Chromatic aberration first (it resamples neighbours), then the
        // per-pixel vignette gain so the two effects do not feed back into each
        // other's sampling.
        if settings.chromaticAberrationRed != 0 || settings.chromaticAberrationBlue != 0 {
            guard let kernel = chromaticAberrationKernel else {
                throw AtelierError.invalidConfiguration("Core Image 色差 kernel 编译失败。")
            }
            let maximumScale = max(abs(settings.chromaticAberrationRed),
                                   abs(settings.chromaticAberrationBlue))
                * maximumChromaticAberrationScale
            let maximumDisplacement = maximumScale * 1.5 * max(extent.width, extent.height)
            let bounds = CIVector(cgRect: extent)
            guard let aberrated = kernel.apply(extent: extent, roiCallback: { index, rect in
                index == 0 ? rect.insetBy(dx: -ceil(maximumDisplacement + 2),
                                          dy: -ceil(maximumDisplacement + 2)) : rect
            }, arguments: [
                CISampler(image: image),
                bounds,
                NSNumber(value: settings.chromaticAberrationRed * maximumChromaticAberrationScale),
                NSNumber(value: settings.chromaticAberrationBlue * maximumChromaticAberrationScale)
            ]) else {
                throw AtelierError.invalidConfiguration("Core Image 色差 kernel 无法生成输出。")
            }
            output = aberrated.cropped(to: extent)
        }

        if settings.vignetteAmount != 0 {
            guard let kernel = vignetteKernel else {
                throw AtelierError.invalidConfiguration("Core Image 暗角 kernel 编译失败。")
            }
            guard let vignetted = kernel.apply(extent: extent, arguments: [
                output,
                CIVector(cgRect: extent),
                NSNumber(value: settings.vignetteAmount),
                NSNumber(value: settings.vignetteMidpoint),
                NSNumber(value: settings.vignetteFeather),
                NSNumber(value: settings.vignetteRoundness)
            ]) else {
                throw AtelierError.invalidConfiguration("Core Image 暗角 kernel 无法生成输出。")
            }
            output = vignetted.cropped(to: extent)
        }
        return output
    }
}

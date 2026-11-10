import CoreImage
import Foundation

/// Independent, optional spatial treatments applied after the user's look.
/// Values are normalized strengths; zero keeps the corresponding effect off.
public struct CreativeEffectsSettings: Codable, Equatable {
    public var bloom: Double
    public var vignette: Double
    public var grain: Double
    public var halation: Double
    public var mist: Double
    public var fade: Double
    public var bleachBypass: Double

    public init(bloom: Double = 0, vignette: Double = 0, grain: Double = 0,
                halation: Double = 0, mist: Double = 0,
                fade: Double = 0, bleachBypass: Double = 0) {
        self.bloom = bloom
        self.vignette = vignette
        self.grain = grain
        self.halation = halation
        self.mist = mist
        self.fade = fade
        self.bleachBypass = bleachBypass
    }

    public var isNeutral: Bool {
        bloom == 0 && vignette == 0 && grain == 0 && halation == 0 && mist == 0
            && fade == 0 && bleachBypass == 0
    }

    private enum CodingKeys: String, CodingKey {
        case bloom, vignette, grain, halation, mist, fade, bleachBypass
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bloom: try container.decodeIfPresent(Double.self, forKey: .bloom) ?? 0,
            vignette: try container.decodeIfPresent(Double.self, forKey: .vignette) ?? 0,
            grain: try container.decodeIfPresent(Double.self, forKey: .grain) ?? 0,
            halation: try container.decodeIfPresent(Double.self, forKey: .halation) ?? 0,
            mist: try container.decodeIfPresent(Double.self, forKey: .mist) ?? 0,
            fade: try container.decodeIfPresent(Double.self, forKey: .fade) ?? 0,
            bleachBypass: try container.decodeIfPresent(Double.self, forKey: .bleachBypass) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bloom, forKey: .bloom)
        try container.encode(vignette, forKey: .vignette)
        try container.encode(grain, forKey: .grain)
        try container.encode(halation, forKey: .halation)
        try container.encode(mist, forKey: .mist)
        try container.encode(fade, forKey: .fade)
        try container.encode(bleachBypass, forKey: .bleachBypass)
    }
}

/// Core Image graph builders for small, deterministic creative treatments.
/// Input/output RGB values stay in extended linear light and alpha is retained.
internal enum CreativeEffectsEngine {
    private static let highlightExtractionKernel = CIColorKernel(source: """
    kernel vec4 extractCreativeHighlights(__sample sample) {
        float alpha = sample.a;
        if (!(alpha > 0.000001) || !(alpha <= 1.0)) { return vec4(0.0); }

        vec3 color = sample.rgb / alpha;
        if (!(abs(color.r) <= 65504.0) || !(abs(color.g) <= 65504.0)
            || !(abs(color.b) <= 65504.0)) { return vec4(0.0); }

        float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
        if (!(luminance >= 0.0) || !(luminance <= 65504.0)) { return vec4(0.0); }

        // The soft knee excludes ordinary midtones instead of lifting the
        // whole image. Emission stays colored and premultiplied for the blur.
        float weight = smoothstep(0.72, 1.35, luminance);
        vec3 emission = max(color, vec3(0.0)) * weight;
        return vec4(emission * alpha, alpha);
    }
    """)

    private static let bloomCompositeKernel = CIColorKernel(source: """
    kernel vec4 addCreativeBloom(__sample source, __sample glow, float strength) {
        float alpha = source.a;
        if (!(alpha > 0.0) || !(alpha <= 1.0)) { return source; }

        // Treat the blurred emission RGB as an unassociated color contribution;
        // multiply it by destination alpha when forming premultiplied output.
        vec3 addition = max(glow.rgb, vec3(0.0)) * (0.12 * strength);
        vec3 color = source.rgb / alpha;

        // Fade one shared RGB contribution as SDR highlights approach white.
        // This protects hue ratios and leaves HDR/negative source values alone.
        float maxRGB = max(max(color.r, color.g), color.b);
        float sdrHeadroomScale = 1.0;
        float largestAddition = max(max(addition.r, addition.g), addition.b);
        if (maxRGB <= 1.0 && largestAddition > 0.0) {
            float headroom = max(0.0, 1.0 - maxRGB);
            float smoothHeadroom = smoothstep(0.0, 0.18, headroom);
            sdrHeadroomScale = min(1.0, headroom / largestAddition) * smoothHeadroom;
        }

        vec3 outputColor = source.rgb + addition * (alpha * sdrHeadroomScale);

        // The working graph can use half-float storage. Reduce only the bloom
        // contribution near its representable ceiling; never clamp to SDR 0...1.
        float largestBase = max(max(source.rgb.r, source.rgb.g), source.rgb.b);
        float halfFloatAddition = largestAddition * alpha * sdrHeadroomScale;
        float halfFloatHeadroom = max(0.0, 65504.0 - largestBase);
        if (halfFloatAddition > 0.0 && halfFloatAddition > halfFloatHeadroom) {
            float scale = halfFloatHeadroom / halfFloatAddition;
            outputColor = source.rgb + addition * (alpha * sdrHeadroomScale * scale);
        }
        return vec4(outputColor, alpha);
    }
    """)

    private static let halationExtractionKernel = CIColorKernel(source: """
    kernel vec4 extractHalationHighlights(__sample sample) {
        float alpha = sample.a;
        if (!(alpha > 0.000001) || !(alpha <= 1.0)) { return vec4(0.0); }

        vec3 color = sample.rgb / alpha;
        if (!(abs(color.r) <= 65504.0) || !(abs(color.g) <= 65504.0)
            || !(abs(color.b) <= 65504.0)) { return vec4(0.0); }

        float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
        if (!(luminance >= 0.0) || !(luminance <= 65504.0)) { return vec4(0.0); }

        float weight = smoothstep(0.70, 1.30, luminance);
        vec3 halationTint = vec3(1.0, 0.22, 0.06) * (weight * luminance);
        return vec4(halationTint * alpha, alpha);
    }
    """)

    private static let halationCompositeKernel = CIColorKernel(source: """
    kernel vec4 addCreativeHalation(__sample source, __sample glow, float strength) {
        float alpha = source.a;
        if (!(alpha > 0.0) || !(alpha <= 1.0)) { return source; }

        vec3 addition = max(glow.rgb, vec3(0.0)) * (0.24 * strength);
        vec3 color = source.rgb / alpha;

        float maxRGB = max(max(color.r, color.g), color.b);
        float sdrHeadroomScale = 1.0;
        float largestAddition = max(max(addition.r, addition.g), addition.b);
        if (maxRGB <= 1.0 && largestAddition > 0.0) {
            float headroom = max(0.0, 1.0 - maxRGB);
            float smoothHeadroom = smoothstep(0.0, 0.18, headroom);
            sdrHeadroomScale = min(1.0, headroom / largestAddition) * smoothHeadroom;
        }

        vec3 outputColor = source.rgb + addition * (alpha * sdrHeadroomScale);
        float largestBase = max(max(source.rgb.r, source.rgb.g), source.rgb.b);
        float halfFloatAddition = largestAddition * alpha * sdrHeadroomScale;
        float halfFloatHeadroom = max(0.0, 65504.0 - largestBase);
        if (halfFloatAddition > 0.0 && halfFloatAddition > halfFloatHeadroom) {
            float scale = halfFloatHeadroom / halfFloatAddition;
            outputColor = source.rgb + addition * (alpha * sdrHeadroomScale * scale);
        }
        return vec4(outputColor, alpha);
    }
    """)

    private static let mistCompositeKernel = CIColorKernel(source: """
    kernel vec4 addCreativeMist(__sample source, __sample diffused, float strength) {
        float alpha = source.a;
        if (!(alpha > 0.0) || !(alpha <= 1.0)) { return source; }

        float difAlpha = diffused.a;
        vec3 src = source.rgb / alpha;
        vec3 dif = (difAlpha > 0.0001) ? diffused.rgb / difAlpha : src;

        vec3 blended = mix(src, dif, 0.20 * strength);
        return vec4(blended * alpha, alpha);
    }
    """)

    private static let fadeKernel = CIColorKernel(source: """
    kernel vec4 addCreativeFade(__sample source, float strength) {
        float alpha = source.a;
        if (!(alpha > 0.0) || !(alpha <= 1.0)) { return source; }

        vec3 color = source.rgb / alpha;
        float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
        if (!(luminance >= 0.0)) { return source; }

        float shadowWeight = max(0.0, 1.0 - smoothstep(0.0, 0.32, luminance));
        float lift = 0.09 * strength * shadowWeight;
        vec3 faded = color + vec3(lift);
        faded = min(faded, vec3(65504.0));
        return vec4(faded * alpha, alpha);
    }
    """)

    private static let bleachBypassKernel = CIColorKernel(source: """
    kernel vec4 addCreativeBleachBypass(__sample source, float strength) {
        float alpha = source.a;
        if (!(alpha > 0.0) || !(alpha <= 1.0)) { return source; }

        vec3 color = source.rgb / alpha;
        float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
        if (!(luminance >= 0.0)) { return source; }

        float hardLuma = smoothstep(0.06, 0.94, luminance);
        vec3 blended = (luminance < 0.5)
            ? (2.0 * color * hardLuma)
            : (1.0 - 2.0 * (1.0 - color) * (1.0 - hardLuma));
        vec3 silver = mix(blended, vec3(hardLuma), 0.35);
        vec3 result = mix(color, silver, 0.50 * strength);
        result = min(max(result, vec3(0.0)), vec3(65504.0));
        return vec4(result * alpha, alpha);
    }
    """)

    private static let finishKernel = CIColorKernel(source: """
    float creativeNoise(vec2 position) {
        // A fixed-coordinate hash makes repeated renders and ROI renders agree.
        float hashed = sin(dot(position, vec2(127.1, 311.7))) * 43758.5453123;
        return fract(hashed) * 2.0 - 1.0;
    }

    kernel vec4 finishCreativeEffects(__sample sample, vec4 bounds,
                                     float vignetteStrength, float grainStrength) {
        float alpha = sample.a;
        if (!(alpha > 0.000001) || !(alpha <= 1.0)) { return sample; }

        vec3 color = sample.rgb / alpha;
        if (!(abs(color.r) <= 65504.0) || !(abs(color.g) <= 65504.0)
            || !(abs(color.b) <= 65504.0)) { return sample; }

        vec2 dimensions = bounds.zw;
        vec2 center = bounds.xy + dimensions * 0.5;
        vec2 halfSize = dimensions * 0.5;
        vec2 offset = destCoord() - center;
        vec2 normalized = vec2(offset.x / halfSize.x, offset.y / halfSize.y);
        float radius = sqrt(dot(normalized, normalized));

        // A broad radial falloff protects the center and darkens the corners
        // by at most 34%, using one shared linear-light gain to retain hue.
        float edge = smoothstep(0.52, 1.38, radius);
        float vignetteGain = 1.0 - 0.34 * vignetteStrength * edge;

        float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float shadowWeight = smoothstep(0.003, 0.055, max(luminance, 0.0));
        float highlightWeight = 1.0 - 0.55 * smoothstep(0.65, 1.8, max(luminance, 0.0));
        float noise = creativeNoise(floor(destCoord()));
        float grainGain = 1.0 + noise * 0.03 * grainStrength
                        * shadowWeight * highlightWeight;

        float gain = vignetteGain * grainGain;
        float largestChannel = max(max(abs(color.r), abs(color.g)), abs(color.b));
        if (largestChannel > 0.0 && gain > 0.0) {
            gain = min(gain, 65504.0 / largestChannel);
        }
        return vec4(color * gain * alpha, alpha);
    }
    """)

    static func validate(_ settings: CreativeEffectsSettings) throws {
        let values = [settings.bloom, settings.vignette, settings.grain, settings.halation, settings.mist,
                      settings.fade, settings.bleachBypass]
        let names = ["柔光", "暗角", "颗粒", "光晕", "薄雾", "褪色", "留银"]
        for (index, value) in values.enumerated() {
            guard value.isFinite, (0...1).contains(value) else {
                throw AtelierError.invalidConfiguration(
                    "创意效果\(names[index])强度必须是 0...1 的有限数值。")
            }
        }
    }

    static func apply(_ settings: CreativeEffectsSettings, to image: CIImage,
                      context: CIContext, cancellation: CancellationToken? = nil) throws -> CIImage {
        try cancellation?.check()
        try validate(settings)
        guard !settings.isNeutral else { return image }

        let extent = image.extent
        guard !extent.isNull, !extent.isInfinite,
              extent.minX.isFinite, extent.minY.isFinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else {
            throw AtelierError.invalidConfiguration("创意效果需要有限且非空的图像范围。")
        }

        var output = image
        if settings.bloom > 0 {
            try cancellation?.check()
            guard let extractionKernel = Self.highlightExtractionKernel,
                  let emission = extractionKernel.apply(extent: extent, arguments: [image]) else {
                throw AtelierError.invalidConfiguration("Core Image 高光提取 kernel 无法生成输出。")
            }

            // Relative radius gives a matching composition at preview and export
            // sizes. A one-pixel floor keeps small previews visibly soft.
            let radius = max(1.0, min(extent.width, extent.height) * 0.012)
            guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: emission,
                kCIInputRadiusKey: radius
            ])?.outputImage?.cropped(to: extent) else {
                throw AtelierError.invalidConfiguration("Core Image 高光辉光模糊无法生成输出。")
            }
            guard let compositeKernel = Self.bloomCompositeKernel,
                  let composite = compositeKernel.apply(extent: extent, arguments: [
                    image, blurred, NSNumber(value: settings.bloom)
                  ]) else {
                throw AtelierError.invalidConfiguration("Core Image 高光辉光合成 kernel 无法生成输出。")
            }
            output = composite.cropped(to: extent)
        }

        if settings.halation > 0 {
            try cancellation?.check()
            guard let halationKernel = Self.halationExtractionKernel,
                  let halationEmission = halationKernel.apply(extent: extent, arguments: [image]) else {
                throw AtelierError.invalidConfiguration("Core Image 光晕提取 kernel 无法生成输出。")
            }
            let radius = max(1.5, min(extent.width, extent.height) * 0.016)
            guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: halationEmission,
                kCIInputRadiusKey: radius
            ])?.outputImage?.cropped(to: extent) else {
                throw AtelierError.invalidConfiguration("Core Image 光晕模糊无法生成输出。")
            }
            guard let compositeKernel = Self.halationCompositeKernel,
                  let composite = compositeKernel.apply(extent: extent, arguments: [
                    output, blurred, NSNumber(value: settings.halation)
                  ]) else {
                throw AtelierError.invalidConfiguration("Core Image 光晕合成 kernel 无法生成输出。")
            }
            output = composite.cropped(to: extent)
        }

        if settings.mist > 0 {
            try cancellation?.check()
            let radius = max(2.0, min(extent.width, extent.height) * 0.022)
            guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: output,
                kCIInputRadiusKey: radius
            ])?.outputImage?.cropped(to: extent) else {
                throw AtelierError.invalidConfiguration("Core Image 薄雾模糊无法生成输出。")
            }
            guard let compositeKernel = Self.mistCompositeKernel,
                  let composite = compositeKernel.apply(extent: extent, arguments: [
                    output, blurred, NSNumber(value: settings.mist)
                  ]) else {
                throw AtelierError.invalidConfiguration("Core Image 薄雾合成 kernel 无法生成输出。")
            }
            output = composite.cropped(to: extent)
        }

        if settings.bleachBypass > 0 {
            try cancellation?.check()
            guard let bleachKernel = Self.bleachBypassKernel,
                  let bleached = bleachKernel.apply(extent: extent, arguments: [
                    output, NSNumber(value: settings.bleachBypass)
                  ]) else {
                throw AtelierError.invalidConfiguration("Core Image 留银效果 kernel 无法生成输出。")
            }
            output = bleached.cropped(to: extent)
        }

        if settings.fade > 0 {
            try cancellation?.check()
            guard let fadeKernel = Self.fadeKernel,
                  let faded = fadeKernel.apply(extent: extent, arguments: [
                    output, NSNumber(value: settings.fade)
                  ]) else {
                throw AtelierError.invalidConfiguration("Core Image 胶片褪色 kernel 无法生成输出。")
            }
            output = faded.cropped(to: extent)
        }

        if settings.vignette > 0 || settings.grain > 0 {
            try cancellation?.check()
            guard let finishKernel = Self.finishKernel,
                  let finished = finishKernel.apply(extent: extent, arguments: [
                    output,
                    CIVector(x: extent.minX, y: extent.minY,
                             z: extent.width, w: extent.height),
                    NSNumber(value: settings.vignette),
                    NSNumber(value: settings.grain)
                  ]) else {
                throw AtelierError.invalidConfiguration("Core Image 暗角/颗粒 kernel 无法生成输出。")
            }
            output = finished.cropped(to: extent)
        }

        try cancellation?.check()
        // The argument documents the context used by PhotoEngine to evaluate
        // the returned lazy graph; rendering here would defeat cancellation and tiling.
        _ = context
        return output
    }
}

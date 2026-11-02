import CoreImage
import Foundation

/// Restrained local refinement controls for an already isolated subject region.
/// The engine deliberately does not detect blemishes or infer a target skin color.
public struct LocalDetailSettings: Codable, Equatable {
    public var smoothing: Double
    public var textureRetention: Double
    public var toneUniformity: Double

    public init(smoothing: Double = 0,
                textureRetention: Double = 0.9,
                toneUniformity: Double = 0) {
        self.smoothing = smoothing
        self.textureRetention = textureRetention
        self.toneUniformity = toneUniformity
    }

    /// Neutral settings preserve the caller's original Core Image graph.
    public var isNeutral: Bool {
        smoothing == 0 && toneUniformity == 0
    }
}

/// Small, bounded spatial adjustments intended to run under a caller-owned mask.
public enum LocalDetailEngine {
    private static let guideKernel = CIColorKernel(source: """
    float signedLogLuma(float value) {
        float magnitude = log2(1.0 + abs(value) / 0.18);
        return value < 0.0 ? -magnitude : magnitude;
    }

    kernel vec4 makeDetailGuide(__sample source) {
        float alpha = source.a;
        if (!(alpha > 0.000001) || !(alpha <= 1.0)) { return vec4(0.0); }

        vec3 rgb = source.rgb / alpha;
        if (!(abs(rgb.r) <= 65504.0) || !(abs(rgb.g) <= 65504.0)
            || !(abs(rgb.b) <= 65504.0)) { return vec4(0.0); }

        float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
        float logLuma = signedLogLuma(luma);
        float redChroma = rgb.r - luma;
        float blueChroma = rgb.b - luma;
        return vec4(vec3(logLuma, redChroma, blueChroma) * alpha, alpha);
    }
    """)

    private static let refinementKernel = CIColorKernel(source: """
    float smoothRamp(float lower, float upper, float value) {
        return smoothstep(lower, upper, value);
    }

    kernel vec4 refineLocalDetail(__sample source,
                                  __sample centerGuide,
                                  __sample smallGuide,
                                  __sample coarseGuide,
                                  float smoothing,
                                  float textureRetention,
                                  float toneUniformity) {
        float alpha = source.a;
        if (!(alpha > 0.000001) || !(alpha <= 1.0)) { return source; }

        vec3 color = source.rgb / alpha;
        float largestChannel = max(max(abs(color.r), abs(color.g)), abs(color.b));
        if (!(largestChannel > 0.0000001) || !(largestChannel <= 65504.0)) {
            return source;
        }
        vec3 sourceColor = color;
        float sourceWithinSDR = (
            sourceColor.r >= 0.0 && sourceColor.r <= 1.0
            && sourceColor.g >= 0.0 && sourceColor.g <= 1.0
            && sourceColor.b >= 0.0 && sourceColor.b <= 1.0) ? 1.0 : 0.0;
        float sourceMaximum = max(max(sourceColor.r, sourceColor.g), sourceColor.b);
        if (!(centerGuide.a > 0.000001) || !(smallGuide.a > 0.000001)
            || !(coarseGuide.a > 0.000001)) { return source; }

        float centerLog = centerGuide.r / centerGuide.a;
        float smallLog = smallGuide.r / smallGuide.a;
        float coarseLog = coarseGuide.r / coarseGuide.a;
        float fineDetail = centerLog - smallLog;
        float middleScale = smallLog - coarseLog;

        float inputLuma = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float lumaMagnitude = abs(inputLuma);
        float middleTone = smoothRamp(0.008, 0.06, lumaMagnitude)
                         * (1.0 - smoothRamp(0.8, 2.0, lumaMagnitude));
        float edgeGuard = 1.0 - smoothRamp(0.035, 0.24, abs(fineDetail));

        // Convert the shaped signed-log guide back to luminance before finding
        // its exposure ratio. A guide difference alone is not an EV difference,
        // especially in darker skin and low-key lighting.
        float targetLog = centerLog - smoothing
            * (middleScale + (1.0 - textureRetention) * fineDetail)
            * middleTone * edgeGuard;
        float targetMagnitude = 0.18 * (exp2(min(abs(targetLog), 20.0)) - 1.0);
        float proposedEV = 0.0;
        if (lumaMagnitude > 0.000001 && centerLog * targetLog > 0.0) {
            proposedEV = log2(max(targetMagnitude, 0.000001) / lumaMagnitude);
        }
        // Never exceed a small fraction of a stop or change luminance sign.
        float safeEV = clamp(proposedEV, -0.12, 0.12);
        float exposureScale = exp2(safeEV);
        if (sourceWithinSDR > 0.5 && safeEV > 0.0 && sourceMaximum > 0.0) {
            // Keep slight headroom below saturation so an in-gamut bright color
            // does not create a new clipped channel in a later output transform.
            exposureScale = min(exposureScale, 0.9995 / sourceMaximum);
        }
        color *= exposureScale;

        float adjustedLuma = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float desiredRedChroma = (smallGuide.g / smallGuide.a) * exposureScale;
        float desiredBlueChroma = (smallGuide.b / smallGuide.a) * exposureScale;
        float currentRedChroma = color.r - adjustedLuma;
        float currentBlueChroma = color.b - adjustedLuma;
        vec2 chromaDelta = vec2(desiredRedChroma - currentRedChroma,
                                desiredBlueChroma - currentBlueChroma);
        float chromaDistance = length(chromaDelta);
        float chromaEdgeGuard = 1.0 - smoothRamp(0.018, 0.12, chromaDistance);
        float chromaWeight = toneUniformity * middleTone * chromaEdgeGuard;
        vec2 appliedChromaDelta = chromaDelta * chromaWeight;
        float appliedLength = length(appliedChromaDelta);
        if (appliedLength > 0.04) {
            appliedChromaDelta *= 0.04 / appliedLength;
        }

        if (sourceWithinSDR > 0.5) {
            // Retain one common fraction of the chroma vector. Per-channel
            // clipping would alter its direction and can shift the local hue.
            float retained = 1.0;
            if (appliedChromaDelta.x > 0.0) {
                float available = max(0.0, 0.9995 - color.r);
                retained = min(retained,
                               0.999 * available / appliedChromaDelta.x);
            } else if (appliedChromaDelta.x < 0.0) {
                retained = min(retained,
                               0.999 * max(0.0, color.r) / -appliedChromaDelta.x);
            }
            if (appliedChromaDelta.y > 0.0) {
                float available = max(0.0, 0.9995 - color.b);
                retained = min(retained,
                               0.999 * available / appliedChromaDelta.y);
            } else if (appliedChromaDelta.y < 0.0) {
                retained = min(retained,
                               0.999 * max(0.0, color.b) / -appliedChromaDelta.y);
            }
            float greenDelta = -(0.2126 * appliedChromaDelta.x
                                 + 0.0722 * appliedChromaDelta.y) / 0.7152;
            if (greenDelta > 0.0) {
                float available = max(0.0, 0.9995 - color.g);
                retained = min(retained, 0.999 * available / greenDelta);
            } else if (greenDelta < 0.0) {
                retained = min(retained,
                               0.999 * max(0.0, color.g) / -greenDelta);
            }
            appliedChromaDelta *= clamp(retained, 0.0, 1.0);
        }

        color.r += appliedChromaDelta.x;
        color.b += appliedChromaDelta.y;
        color.g -= (0.2126 * appliedChromaDelta.x
                    + 0.0722 * appliedChromaDelta.y) / 0.7152;

        // RGBAh working surfaces cannot represent larger finite magnitudes. Leave
        // such pixels untouched instead of clipping extended-gamut values.
        if (!(abs(color.r) <= 65504.0) || !(abs(color.g) <= 65504.0)
            || !(abs(color.b) <= 65504.0)) { return source; }
        return vec4(color * alpha, alpha);
    }
    """)

    public static func validate(_ settings: LocalDetailSettings) throws {
        func require(_ value: Double, _ label: String) throws {
            guard value.isFinite, (0...1).contains(value) else {
                throw AtelierError.invalidConfiguration(
                    "人像细节\(label)必须是 0...1 之间的有限数值。")
            }
        }
        try require(settings.smoothing, "平滑度")
        try require(settings.textureRetention, "纹理保留")
        try require(settings.toneUniformity, "色调均匀度")
    }

    public static func apply(_ image: CIImage,
                            settings: LocalDetailSettings) throws -> CIImage {
        try validate(settings)
        if settings.isNeutral { return image }

        let extent = image.extent
        guard !extent.isNull, !extent.isInfinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else {
            throw AtelierError.invalidConfiguration("人像细节处理需要有限且非空的图像范围。")
        }
        guard let guideKernel = guideKernel,
              let refinementKernel = refinementKernel else {
            throw AtelierError.invalidConfiguration("人像细节 Core Image kernel 无法编译。")
        }

        guard let guide = guideKernel.apply(extent: extent, arguments: [image]) else {
            throw AtelierError.invalidConfiguration("人像细节分析图无法生成。")
        }

        let minimumSide = min(extent.width, extent.height)
        let smallRadius = max(0.5, minimumSide * 0.0015)
        let coarseRadius = max(smallRadius * 3.5, minimumSide * 0.008)

        func blurred(_ radius: CGFloat) -> CIImage {
            guide.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: NSNumber(value: Double(radius))
                ])
                .cropped(to: extent)
        }

        let smallScale = blurred(smallRadius)
        let coarseScale = blurred(coarseRadius)
        guard let output = refinementKernel.apply(extent: extent, arguments: [
            image,
            guide,
            smallScale,
            coarseScale,
            NSNumber(value: settings.smoothing),
            NSNumber(value: settings.textureRetention),
            NSNumber(value: settings.toneUniformity)
        ]) else {
            throw AtelierError.invalidConfiguration("人像细节调整无法生成输出。")
        }
        return output.cropped(to: extent)
    }
}

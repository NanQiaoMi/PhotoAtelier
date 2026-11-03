import CoreImage
import Foundation

/// Restrained local refinement controls for an already isolated subject region.
/// The engine deliberately does not detect blemishes or infer a target skin color.
public struct LocalDetailSettings: Codable, Equatable {
    public var smoothing: Double
    public var textureRetention: Double
    public var toneUniformity: Double
    public var noiseReduction: Double
    public var detailRecovery: Double

    public init(smoothing: Double = 0,
                textureRetention: Double = 0.9,
                toneUniformity: Double = 0,
                noiseReduction: Double = 0,
                detailRecovery: Double = 0) {
        self.smoothing = smoothing
        self.textureRetention = textureRetention
        self.toneUniformity = toneUniformity
        self.noiseReduction = noiseReduction
        self.detailRecovery = detailRecovery
    }

    private enum CodingKeys: String, CodingKey {
        case smoothing
        case textureRetention
        case toneUniformity
        case noiseReduction
        case detailRecovery
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        smoothing = try values.decode(Double.self, forKey: .smoothing)
        textureRetention = try values.decode(Double.self, forKey: .textureRetention)
        toneUniformity = try values.decode(Double.self, forKey: .toneUniformity)
        noiseReduction = try values.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
        detailRecovery = try values.decodeIfPresent(Double.self, forKey: .detailRecovery) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(smoothing, forKey: .smoothing)
        try values.encode(textureRetention, forKey: .textureRetention)
        try values.encode(toneUniformity, forKey: .toneUniformity)
        try values.encode(noiseReduction, forKey: .noiseReduction)
        try values.encode(detailRecovery, forKey: .detailRecovery)
    }

    /// Neutral settings preserve the caller's original Core Image graph.
    public var isNeutral: Bool {
        smoothing == 0 && toneUniformity == 0
            && noiseReduction == 0 && detailRecovery == 0
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
                                  __sample maximumGuide,
                                  __sample minimumGuide,
                                  float smoothing,
                                  float textureRetention,
                                  float toneUniformity,
                                  float modernDetailActive) {
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
        float modernFlat = 0.0;
        if (modernDetailActive > 0.5) {
            if (abs(minimumGuide.a - alpha) > 0.001
                || abs(maximumGuide.a - alpha) > 0.001) { return source; }
            // Stop the broad Gaussian operation across a strong boundary over
            // its entire support, not only at the central fine-scale gradient.
            float neighborhoodRange = maximumGuide.r / maximumGuide.a
                                    - minimumGuide.r / minimumGuide.a;
            if (neighborhoodRange >= 0.3) { return source; }
            float coarseEdge = abs(centerLog - coarseLog);
            float coarseEdgeGuard = 1.0 - smoothRamp(0.045, 0.20, coarseEdge);
            float localResidual = max(abs(fineDetail), abs(middleScale));
            // Guide surfaces may use half precision. Treat sub-quantization
            // variation as flat rather than manufacturing an exposure change.
            modernFlat = localResidual < 0.002 * max(1.0, abs(centerLog)) ? 1.0 : 0.0;
            edgeGuard *= coarseEdgeGuard * (1.0 - smoothRamp(0.1, 0.3, neighborhoodRange));
            // A constant neighborhood has no spatial correction to make. Do
            // not round-trip its guide through transcendental functions.
            if (modernFlat > 0.5) { return source; }
        }

        // Convert the shaped signed-log guide back to luminance before finding
        // its exposure ratio. A guide difference alone is not an EV difference,
        // especially in darker skin and low-key lighting.
        float targetLog = centerLog - smoothing
            * (middleScale + (1.0 - textureRetention) * fineDetail)
            * middleTone * edgeGuard;
        float targetMagnitude = 0.18 * (exp2(min(abs(targetLog), 20.0)) - 1.0);
        float proposedEV = 0.0;
        if (lumaMagnitude > 0.000001 && centerLog * targetLog > 0.0
            && (modernDetailActive < 0.5 || abs(targetLog - centerLog) > 0.000001)) {
            proposedEV = log2(max(targetMagnitude, 0.000001) / lumaMagnitude);
        }
        // The legacy SDR headroom guard intentionally moves any positive EV
        // below 1.0 slightly away from white. Ignore numerical-scale moves only
        // on the new combined path so a flat white plane stays exactly flat.
        if (modernDetailActive > 0.5 && abs(proposedEV) < 0.0001) {
            proposedEV = 0.0;
        }
        // Never exceed a small fraction of a stop or change luminance sign.
        float safeEV = clamp(proposedEV, -0.12, 0.12);
        float exposureScale = exp2(safeEV);
        if (modernDetailActive > 0.5 && safeEV == 0.0) { exposureScale = 1.0; }
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
        if (modernDetailActive > 0.5 && modernFlat > 0.5) { chromaWeight = 0.0; }
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

    // This stage uses fixed source-coordinate offsets so its footprint stays
    // local as image dimensions change. Luma changes are applied as a common
    // exposure scale, while chroma is adjusted radially to avoid independent
    // channel clipping or an arbitrary hue rotation.
    private static let localTextureKernel = CIKernel(source: """
    float signedLogLuma(float value) {
        float magnitude = log2(1.0 + abs(value) / 0.18);
        return value < 0.0 ? -magnitude : magnitude;
    }

    vec4 localColor(sampler source, vec2 coordinate) {
        vec4 sampleColor = sample(source, coordinate);
        if (!(sampleColor.a > 0.000001) || !(sampleColor.a <= 1.0)) {
            return vec4(0.0);
        }
        vec3 color = sampleColor.rgb / sampleColor.a;
        if (!(abs(color.r) <= 65504.0) || !(abs(color.g) <= 65504.0)
            || !(abs(color.b) <= 65504.0)) { return vec4(0.0); }
        float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
        return vec4(luma, color.r - luma, color.b - luma, 1.0);
    }

    float localDifference(vec4 neighbor, vec4 center) {
        float lumaDifference = abs(signedLogLuma(neighbor.r)
                                   - signedLogLuma(center.r));
        float referenceLuma = max(max(abs(neighbor.r), abs(center.r)), 0.05);
        float chromaDifference = 0.5 * length(neighbor.gb - center.gb)
                                 / referenceLuma;
        return max(lumaDifference, chromaDifference);
    }

    float softSignal(float value, float floorValue, float clearValue) {
        return smoothstep(floorValue, max(clearValue, floorValue + 0.000001),
                          abs(value));
    }

    kernel vec4 refineLocalTexture(sampler source,
                                   float noiseEstimate,
                                   float noiseReduction,
                                   float detailRecovery) {
        // samplerCoord is in this source sampler's pixel-coordinate space, so
        // integer offsets below denote fixed source pixels rather than a scale
        // derived from the image extent.
        vec2 coordinate = samplerCoord(source);
        vec4 original = sample(source, coordinate);
        float alpha = original.a;
        if (!(alpha > 0.000001) || !(alpha <= 1.0)) { return original; }

        vec3 originalColor = original.rgb / alpha;
        if (!(abs(originalColor.r) <= 65504.0)
            || !(abs(originalColor.g) <= 65504.0)
            || !(abs(originalColor.b) <= 65504.0)) { return original; }

        vec4 center = localColor(source, coordinate);
        if (!(center.a > 0.5)) { return original; }

        vec2 one = vec2(1.0, 0.0);
        vec2 diagonal = vec2(1.0, 1.0);
        vec4 p1 = localColor(source, coordinate + one);
        vec4 m1 = localColor(source, coordinate - one);
        vec4 p2 = localColor(source, coordinate + one.yx);
        vec4 m2 = localColor(source, coordinate - one.yx);
        vec4 pp = localColor(source, coordinate + diagonal);
        vec4 pm = localColor(source, coordinate + vec2(1.0, -1.0));
        vec4 mp = localColor(source, coordinate + vec2(-1.0, 1.0));
        vec4 mm = localColor(source, coordinate - diagonal);
        vec2 two = vec2(2.0, 0.0);
        vec2 twoDiagonal = vec2(2.0, 2.0);
        vec4 p3 = localColor(source, coordinate + two);
        vec4 m3 = localColor(source, coordinate - two);
        vec4 p4 = localColor(source, coordinate + two.yx);
        vec4 m4 = localColor(source, coordinate - two.yx);
        vec4 p5 = localColor(source, coordinate + twoDiagonal);
        vec4 p6 = localColor(source, coordinate + vec2(2.0, -2.0));
        vec4 m5 = localColor(source, coordinate + vec2(-2.0, 2.0));
        vec4 m6 = localColor(source, coordinate - twoDiagonal);

        float nearWeight = 0.25
            + (p1.a + m1.a + p2.a + m2.a) * 0.125
            + (pp.a + pm.a + mp.a + mm.a) * 0.0625;
        float nearLuma = (center.r * 0.25
            + (p1.r + m1.r + p2.r + m2.r) * 0.125
            + (pp.r + pm.r + mp.r + mm.r) * 0.0625) / nearWeight;
        vec2 nearChroma = (center.gb * 0.25
            + (p1.gb + m1.gb + p2.gb + m2.gb) * 0.125
            + (pp.gb + pm.gb + mp.gb + mm.gb) * 0.0625) / nearWeight;
        float farWeight = 0.25
            + (p3.a + m3.a + p4.a + m4.a) * 0.125
            + (p5.a + p6.a + m5.a + m6.a) * 0.0625;
        float farLuma = (center.r * 0.25
            + (p3.r + m3.r + p4.r + m4.r) * 0.125
            + (p5.r + p6.r + m5.r + m6.r) * 0.0625) / farWeight;

        float localEdge = 0.0;
        if (p1.a > 0.5) { localEdge = max(localEdge, localDifference(p1, center)); }
        if (m1.a > 0.5) { localEdge = max(localEdge, localDifference(m1, center)); }
        if (p2.a > 0.5) { localEdge = max(localEdge, localDifference(p2, center)); }
        if (m2.a > 0.5) { localEdge = max(localEdge, localDifference(m2, center)); }
        if (pp.a > 0.5) { localEdge = max(localEdge, localDifference(pp, center)); }
        if (pm.a > 0.5) { localEdge = max(localEdge, localDifference(pm, center)); }
        if (mp.a > 0.5) { localEdge = max(localEdge, localDifference(mp, center)); }
        if (mm.a > 0.5) { localEdge = max(localEdge, localDifference(mm, center)); }
        // Every neighbor contributing to recovery must also contribute to the
        // edge guard, including the wider middle-frequency support.
        if (p3.a > 0.5) { localEdge = max(localEdge, localDifference(p3, center)); }
        if (m3.a > 0.5) { localEdge = max(localEdge, localDifference(m3, center)); }
        if (p4.a > 0.5) { localEdge = max(localEdge, localDifference(p4, center)); }
        if (m4.a > 0.5) { localEdge = max(localEdge, localDifference(m4, center)); }
        if (p5.a > 0.5) { localEdge = max(localEdge, localDifference(p5, center)); }
        if (p6.a > 0.5) { localEdge = max(localEdge, localDifference(p6, center)); }
        if (m5.a > 0.5) { localEdge = max(localEdge, localDifference(m5, center)); }
        if (m6.a > 0.5) { localEdge = max(localEdge, localDifference(m6, center)); }
        float edgeGuard = 1.0 - smoothstep(0.18, 0.62, localEdge);

        float lumaMagnitude = abs(center.r);
        float sigmaLuma = 2.0 * sqrt(max(lumaMagnitude, 0.000001))
                          * noiseEstimate + noiseEstimate * noiseEstimate;
        float lumaThreshold = sigmaLuma * 1.2;
        float lumaHigh = center.r - nearLuma;
        float lumaSign = lumaHigh < 0.0 ? -1.0 : 1.0;
        float lumaRemoval = lumaSign
            * min(abs(lumaHigh), lumaThreshold)
            * noiseReduction * edgeGuard;
        float recoveredFine = lumaHigh
            * softSignal(lumaHigh, lumaThreshold * 1.05,
                         lumaThreshold * 2.1)
            * (0.30 * detailRecovery * edgeGuard);
        float middleHigh = nearLuma - farLuma;
        float middleThreshold = lumaThreshold * 0.65;
        float recoveredMiddle = middleHigh
            * softSignal(middleHigh, middleThreshold * 1.15,
                         middleThreshold * 2.3)
            * (0.16 * detailRecovery * edgeGuard);

        float targetLuma = center.r - lumaRemoval
                           + recoveredFine + recoveredMiddle;
        float exposureScale = 1.0;
        if (abs(center.r) > 0.000001 && center.r * targetLuma > 0.0
            && abs(targetLuma - center.r) > max(0.0000001, abs(center.r) * 0.000001)) {
            float proposedEV = log2(max(abs(targetLuma), 0.000001)
                                    / abs(center.r));
            exposureScale = exp2(clamp(proposedEV, -0.12, 0.12));
        }

        vec2 chroma = center.gb;
        float chromaMagnitude = length(chroma);
        vec2 chromaHigh = chroma - nearChroma;
        float chromaNoise = min(length(chromaHigh), lumaThreshold * 0.8)
                            * noiseReduction * edgeGuard;
        // Keep the opponent-color vector direction fixed. Cap the saturation
        // reduction to limit skin-tone shifts where luma noise is not a good
        // proxy for chroma noise.
        float chromaScale = 1.0;
        if (chromaMagnitude > 0.000001) {
            chromaScale = max(0.88, 1.0 - chromaNoise / chromaMagnitude);
        }

        vec3 targetColor = vec3(center.r * exposureScale,
                                chroma.x * chromaScale,
                                chroma.y * chromaScale);
        // Reconstruct RGB from luma and opponent chroma. The coefficients make
        // the luma of each chroma basis vector zero in linear RGB.
        vec3 outputColor = vec3(
            targetColor.x + targetColor.y,
            targetColor.x - (0.2126 * targetColor.y
                             + 0.0722 * targetColor.z) / 0.7152,
            targetColor.x + targetColor.z);
        if (!(abs(outputColor.r) <= 65504.0)
            || !(abs(outputColor.g) <= 65504.0)
            || !(abs(outputColor.b) <= 65504.0)) { return original; }

        float sourceWithinSDR = originalColor.r >= 0.0 && originalColor.r <= 1.0
            && originalColor.g >= 0.0 && originalColor.g <= 1.0
            && originalColor.b >= 0.0 && originalColor.b <= 1.0 ? 1.0 : 0.0;
        if (sourceWithinSDR > 0.5) {
            vec3 delta = outputColor - originalColor;
            float retained = 1.0;
            if (delta.r > 0.0) { retained = min(retained, (1.0 - originalColor.r) / delta.r); }
            else if (delta.r < 0.0) { retained = min(retained, originalColor.r / -delta.r); }
            if (delta.g > 0.0) { retained = min(retained, (1.0 - originalColor.g) / delta.g); }
            else if (delta.g < 0.0) { retained = min(retained, originalColor.g / -delta.g); }
            if (delta.b > 0.0) { retained = min(retained, (1.0 - originalColor.b) / delta.b); }
            else if (delta.b < 0.0) { retained = min(retained, originalColor.b / -delta.b); }
            outputColor = originalColor + delta * clamp(retained, 0.0, 1.0);
        }

        return vec4(outputColor * alpha, alpha);
    }
    """)

    // Keep the combined legacy and new stages within one exposure bound. The
    // common RGB delta factor also preserves the direction of the proposed
    // color change when an SDR channel reaches its gamut boundary.
    private static let finalOutputLimiterKernel = CIColorKernel(source: """
    kernel vec4 limitLocalOutput(__sample originalSample,
                                 __sample processedSample) {
        float alpha = originalSample.a;
        if (!(alpha > 0.000001) || !(alpha <= 1.0)
            || !(processedSample.a > 0.000001)
            || !(processedSample.a <= 1.0)) { return originalSample; }

        vec3 originalColor = originalSample.rgb / alpha;
        vec3 processedColor = processedSample.rgb / processedSample.a;
        if (!(abs(originalColor.r) <= 65504.0)
            || !(abs(originalColor.g) <= 65504.0)
            || !(abs(originalColor.b) <= 65504.0)
            || !(abs(processedColor.r) <= 65504.0)
            || !(abs(processedColor.g) <= 65504.0)
            || !(abs(processedColor.b) <= 65504.0)) { return originalSample; }

        float originalLuma = dot(originalColor, vec3(0.2126, 0.7152, 0.0722));
        float processedLuma = dot(processedColor, vec3(0.2126, 0.7152, 0.0722));
        // EV is undefined at zero luminance; retain the original there rather
        // than allowing a near-black sample to acquire a large relative change.
        if (abs(originalLuma) <= 0.000001
            || originalLuma * processedLuma <= 0.0) { return originalSample; }

        float minimumRatio = exp2(-0.12);
        float maximumRatio = exp2(0.12);
        float ratio = abs(processedLuma) / abs(originalLuma);
        float lumaRetained = 1.0;
        if (ratio < minimumRatio) {
            float minimumLuma = originalLuma * minimumRatio;
            lumaRetained = (minimumLuma - originalLuma)
                           / (processedLuma - originalLuma);
        } else if (ratio > maximumRatio) {
            float maximumLuma = originalLuma * maximumRatio;
            lumaRetained = (maximumLuma - originalLuma)
                           / (processedLuma - originalLuma);
        }
        vec3 boundedColor = originalColor
            + (processedColor - originalColor) * clamp(lumaRetained, 0.0, 1.0);

        float sourceWithinSDR = originalColor.r >= 0.0 && originalColor.r <= 1.0
            && originalColor.g >= 0.0 && originalColor.g <= 1.0
            && originalColor.b >= 0.0 && originalColor.b <= 1.0 ? 1.0 : 0.0;
        if (sourceWithinSDR > 0.5) {
            vec3 delta = boundedColor - originalColor;
            float gamutRetained = 1.0;
            if (delta.r > 0.0) {
                gamutRetained = min(gamutRetained, (1.0 - originalColor.r) / delta.r);
            } else if (delta.r < 0.0) {
                gamutRetained = min(gamutRetained, originalColor.r / -delta.r);
            }
            if (delta.g > 0.0) {
                gamutRetained = min(gamutRetained, (1.0 - originalColor.g) / delta.g);
            } else if (delta.g < 0.0) {
                gamutRetained = min(gamutRetained, originalColor.g / -delta.g);
            }
            if (delta.b > 0.0) {
                gamutRetained = min(gamutRetained, (1.0 - originalColor.b) / delta.b);
            } else if (delta.b < 0.0) {
                gamutRetained = min(gamutRetained, originalColor.b / -delta.b);
            }
            boundedColor = originalColor
                + delta * clamp(gamutRetained, 0.0, 1.0);
        }

        if (!(abs(boundedColor.r) <= 65504.0)
            || !(abs(boundedColor.g) <= 65504.0)
            || !(abs(boundedColor.b) <= 65504.0)) { return originalSample; }
        return vec4(boundedColor * alpha, alpha);
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
        try require(settings.noiseReduction, "噪声减弱")
        try require(settings.detailRecovery, "细节增强")
    }

    public static func apply(_ image: CIImage,
                            settings: LocalDetailSettings,
                            noiseEstimate: Double = 0.006,
                            modernProtection: Bool = false) throws -> CIImage {
        try validate(settings)
        guard noiseEstimate.isFinite, (0...0.25).contains(noiseEstimate) else {
            throw AtelierError.invalidConfiguration(
                "人像细节噪声估计必须是 0...0.25 之间的有限数值。")
        }
        if settings.isNeutral { return image }

        let extent = image.extent
        guard !extent.isNull, !extent.isInfinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else {
            throw AtelierError.invalidConfiguration("人像细节处理需要有限且非空的图像范围。")
        }
        var output = image
        let modernActive = modernProtection || settings.noiseReduction != 0 || settings.detailRecovery != 0
        if settings.smoothing != 0 || settings.toneUniformity != 0 {
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
            var maximumGuide = guide, minimumGuide = guide
            if modernActive {
                let radius = NSNumber(value: Double(ceil(coarseRadius * 3)))
                maximumGuide = guide.clampedToExtent().applyingFilter("CIMorphologyMaximum",
                    parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
                minimumGuide = guide.clampedToExtent().applyingFilter("CIMorphologyMinimum",
                    parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
            }
            guard let legacyOutput = refinementKernel.apply(extent: extent, arguments: [
                image,
                guide,
                smallScale,
                coarseScale,
                maximumGuide,
                minimumGuide,
                NSNumber(value: settings.smoothing),
                NSNumber(value: settings.textureRetention),
                NSNumber(value: settings.toneUniformity),
                NSNumber(value: modernActive ? 1 : 0)
            ]) else {
                throw AtelierError.invalidConfiguration("人像细节调整无法生成输出。")
            }
            output = legacyOutput.cropped(to: extent)
        }

        // When both new controls are zero, return the legacy graph unchanged.
        if settings.noiseReduction == 0 && settings.detailRecovery == 0 {
            return output
        }
        guard let localTextureKernel = localTextureKernel,
              let localOutput = localTextureKernel.apply(
                extent: extent,
                roiCallback: { _, rect in rect.insetBy(dx: -2, dy: -2) },
                arguments: [
                    output.clampedToExtent(),
                    NSNumber(value: noiseEstimate),
                    NSNumber(value: settings.noiseReduction),
                    NSNumber(value: settings.detailRecovery)
                ]) else {
            throw AtelierError.invalidConfiguration("局部噪声与纹理调整无法生成输出。")
        }
        guard let finalOutputLimiterKernel = finalOutputLimiterKernel,
              let boundedOutput = finalOutputLimiterKernel.apply(
                extent: extent,
                arguments: [image, localOutput.cropped(to: extent)]) else {
            throw AtelierError.invalidConfiguration("局部细节总亮度限制无法生成输出。")
        }
        return boundedOutput.cropped(to: extent)
    }
}

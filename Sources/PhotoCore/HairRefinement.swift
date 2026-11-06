import CoreGraphics
import CoreImage
import Foundation

/// Native hair refinement: hair parting / scalp gap filling, crown sheen, hair tone depth,
/// anti-frizz smoothing, and flyaway / stray hair removal.
///
/// Features:
/// 1. **发缝填充 (`hairGapFilling`)**:
///    Detects pale/pink scalp skin exposed along the hair parting and crown corridor,
///    shading and neutralizing the scalp skin tone towards dark ambient hair root tones,
///    while automatically preserving dark hair strands that cross over the parting.
/// 2. **秀发光泽 / 天使光环 (`hairGloss`)**:
///    Enhances specular highlights across the crown arc, giving dry or dull hair a
///    healthy, luminous silk/satin sheen without clipping high-frequency textures.
/// 3. **发色深邃 / 去枯黄 (`hairDarkening`)**:
///    Deepens mid-tones and suppresses brassy/yellowish tones in dull hair to produce
///    rich, salon-fresh hair colour and increase face-to-hair contrast.
/// 4. **秀发柔顺 / 抚平毛躁 (`hairSmoothing`)**:
///    Softens high-frequency micro-frizz and chaotic dry noise within the main hair mass,
///    preserving large strand contours and directional sheen for a sleek salon texture.
/// 5. **边缘去碎发 (`flyawayRemoval`)**:
///    Detects thin, protruding, high-contrast stray hair filaments in the outer halo
///    transition zone outside the cranial and hair silhouette, smoothly inpainting them
///    with surrounding background tones to create a clean head contour.
public enum HairRefinementEngine {

    private static let hairKernel: CIColorKernel? = {
        let source = """
        kernel vec4 applyHairRefine(__sample source, __sample smoothed, vec4 facePixelRect,
                                    float gapFilling, float gloss, float darkening,
                                    float smoothing, float flyaway) {
            float alpha = clamp(source.a, 0.0, 1.0);
            if (alpha <= 0.000001) { return vec4(0.0); }

            vec2 coord = destCoord();
            float midX = facePixelRect.x + facePixelRect.z * 0.5;
            float faceWidth = max(facePixelRect.z, 1.0);
            float faceHeight = max(facePixelRect.w, 1.0);

            float foreheadY = facePixelRect.y + faceHeight * 0.70;
            float crownMidY = facePixelRect.y + faceHeight * 1.35;
            float crownTopY = facePixelRect.y + faceHeight * 1.90;

            // Spatial weighting for main hair body
            float hairYWeight = smoothstep(foreheadY - faceHeight * 0.15, foreheadY + faceHeight * 0.08, coord.y)
                              * (1.0 - smoothstep(crownTopY - faceHeight * 0.20, crownTopY + faceHeight * 0.10, coord.y));
            float hairXDist = abs(coord.x - midX);
            float maxHairHalfWidth = faceWidth * 0.85;
            float hairXWeight = 1.0 - smoothstep(maxHairHalfWidth * 0.75, maxHairHalfWidth * 1.15, hairXDist);
            float hairRegionWeight = hairYWeight * hairXWeight;

            // Spatial weighting for flyaway halo band (outer perimeter of crown and silhouette)
            float haloOuterY = crownTopY + faceHeight * 0.40;
            float haloYWeight = smoothstep(foreheadY - faceHeight * 0.20, foreheadY + faceHeight * 0.05, coord.y)
                              * (1.0 - smoothstep(haloOuterY - faceHeight * 0.15, haloOuterY + faceHeight * 0.10, coord.y));

            float crownTopDist = coord.y - (crownTopY - faceHeight * 0.15);
            float crownTopHalo = smoothstep(0.0, faceHeight * 0.12, crownTopDist)
                               * (1.0 - smoothstep(faceHeight * 0.25, faceHeight * 0.48, crownTopDist))
                               * (1.0 - smoothstep(maxHairHalfWidth * 0.85, maxHairHalfWidth * 1.25, hairXDist));

            float lateralHalo = smoothstep(maxHairHalfWidth * 0.70, maxHairHalfWidth * 0.95, hairXDist)
                              * (1.0 - smoothstep(maxHairHalfWidth * 1.20, maxHairHalfWidth * 1.50, hairXDist))
                              * haloYWeight;

            float haloWeight = clamp(crownTopHalo + lateralHalo, 0.0, 1.0);

            if (hairRegionWeight <= 0.00001 && haloWeight <= 0.00001) {
                return source;
            }

            vec3 color = source.rgb;
            vec3 smoothColor = smoothed.rgb;

            // 1. Flyaway / stray hair removal along outer perimeter
            if (flyaway > 0.0001 && haloWeight > 0.0001) {
                float strayDiff = length(color - smoothColor);
                float isStray = smoothstep(0.03, 0.18, strayDiff);
                float straySuppression = flyaway * haloWeight * isStray;
                if (straySuppression > 0.0001) {
                    color = mix(color, smoothColor, clamp(straySuppression * 0.92, 0.0, 1.0));
                }
            }

            // 2. Anti-frizz smoothing within main hair mass
            if (smoothing > 0.0001 && hairRegionWeight > 0.0001) {
                float frizzDiff = length(color - smoothColor);
                float isMicroFrizz = 1.0 - smoothstep(0.15, 0.42, frizzDiff);
                float smoothFactor = smoothing * hairRegionWeight * 0.72 * isMicroFrizz;
                if (smoothFactor > 0.0001) {
                    color = mix(color, smoothColor, clamp(smoothFactor, 0.0, 1.0));
                }
            }

            // Update color metrics
            float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
            float redDiff = color.r - color.b;

            // Central hair parting corridor
            float partingRadius = max(faceWidth * 0.28, 1.0);
            float partingWeight = exp(-pow(hairXDist / partingRadius, 2.0)) * hairYWeight;

            // Crown arc (Angel Ring highlight band)
            float crownArcYDist = abs(coord.y - crownMidY);
            float crownArcRadius = max(faceHeight * 0.35, 1.0);
            float crownArcWeight = exp(-pow(crownArcYDist / crownArcRadius, 2.0)) * hairXWeight;

            // 3. Hair gap / scalp filling
            if (gapFilling > 0.0001 && hairRegionWeight > 0.0001) {
                float isScalpLuma = smoothstep(0.18, 0.40, luma);
                float isScalpWarm = smoothstep(0.02, 0.12, redDiff);
                float scalpConfidence = isScalpLuma * isScalpWarm * partingWeight;

                if (scalpConfidence > 0.0001) {
                    float darkenFactor = 1.0 - 0.70 * gapFilling * scalpConfidence;
                    color = color * darkenFactor;
                    float desatRed = max(0.0, redDiff) * 0.40 * gapFilling * scalpConfidence;
                    color.r = max(0.0, color.r - desatRed);
                }
            }

            // 4. Hair gloss / sheen
            if (gloss > 0.0001 && hairRegionWeight > 0.0001) {
                float isHighlight = smoothstep(0.10, 0.35, luma) * (1.0 - smoothstep(0.65, 0.95, luma));
                float glossBoost = isHighlight * crownArcWeight * gloss * 0.32;
                color = color * (1.0 + glossBoost);
            }

            // 5. Hair darkening & brassiness suppression
            if (darkening > 0.0001 && hairRegionWeight > 0.0001) {
                float isScalp = smoothstep(0.18, 0.40, luma) * smoothstep(0.02, 0.12, redDiff) * partingWeight;
                float hairToneWeight = hairRegionWeight * (1.0 - isScalp * 0.85);
                float midtoneDarkening = clamp((1.0 - luma) * luma * 1.5, 0.0, 1.0);
                float deepGain = 1.0 - midtoneDarkening * darkening * 0.38 * hairToneWeight;
                color = color * deepGain;

                float brassiness = max(0.0, color.r - color.b) * 0.25 * darkening * hairToneWeight;
                color.r = max(0.0, color.r - brassiness);
                color.g = max(0.0, color.g - brassiness * 0.5);
            }

            return vec4(color, source.a);
        }
        """
        return CIColorKernel(source: source)
    }()

    /// Applies hair refinement to `image` for all faces present in `faceMasks` or `landmarks`.
    public static func apply(_ image: CIImage,
                             settings: PortraitRefinementSettings,
                             faceMasks: [FaceSemanticMaskSet],
                             landmarks: [FaceLandmarkSet] = [],
                             context: CIContext,
                             cancellation: CancellationToken? = nil) throws -> CIImage {
        guard settings.hairGapFilling > 0 || settings.hairGloss > 0 || settings.hairDarkening > 0
            || settings.hairSmoothing > 0 || settings.flyawayRemoval > 0 else {
            return image
        }
        guard let kernel = hairKernel else {
            throw AtelierError.invalidConfiguration("初始化头发精修着色器失败。")
        }

        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 1, extent.height > 1 else {
            return image
        }

        // Collect face bounding boxes in pixel coordinates (Core Image bottom-left origin)
        var faceRects: [CGRect] = []
        if !landmarks.isEmpty {
            for landmark in landmarks where landmark.hasUsableGeometry {
                let box = landmark.boundingBox
                let pixelRect = CGRect(
                    x: extent.origin.x + box.origin.x * extent.width,
                    y: extent.origin.y + box.origin.y * extent.height,
                    width: box.width * extent.width,
                    height: box.height * extent.height
                )
                faceRects.append(pixelRect)
            }
        }
        if faceRects.isEmpty {
            for face in faceMasks where face.faceBounds.width > 0 && face.faceBounds.height > 0 {
                let box = face.faceBounds
                let pixelRect = CGRect(
                    x: extent.origin.x + box.origin.x * extent.width,
                    y: extent.origin.y + box.origin.y * extent.height,
                    width: box.width * extent.width,
                    height: box.height * extent.height
                )
                faceRects.append(pixelRect)
            }
        }

        guard !faceRects.isEmpty else {
            return image
        }

        // Prepare smoothed reference image if smoothing or flyaway removal is requested
        let needsSmoothed = settings.hairSmoothing > 0 || settings.flyawayRemoval > 0
        let smoothedSource: CIImage
        if needsSmoothed {
            let avgFaceWidth = faceRects.map(\.width).reduce(0, +) / CGFloat(faceRects.count)
            let sigma = max(3.5, min(14.0, Double(avgFaceWidth) * 0.022))
            smoothedSource = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        } else {
            smoothedSource = image
        }

        var result = image
        for rect in faceRects {
            try cancellation?.check()
            let faceVec = CIVector(x: rect.origin.x, y: rect.origin.y, z: rect.size.width, w: rect.size.height)
            guard let filtered = kernel.apply(
                extent: extent,
                arguments: [
                    result,
                    smoothedSource,
                    faceVec,
                    Float(settings.hairGapFilling),
                    Float(settings.hairGloss),
                    Float(settings.hairDarkening),
                    Float(settings.hairSmoothing),
                    Float(settings.flyawayRemoval)
                ]
            ) else {
                continue
            }
            result = filtered
        }

        return result
    }
}

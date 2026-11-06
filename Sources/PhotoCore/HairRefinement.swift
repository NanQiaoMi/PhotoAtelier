import CoreGraphics
import CoreImage
import Foundation

/// Native hair refinement: hair parting / scalp gap filling, crown sheen, and hair tone depth.
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
public enum HairRefinementEngine {

    private static let hairKernel: CIColorKernel? = {
        let source = """
        kernel vec4 applyHairRefine(__sample source, vec4 facePixelRect,
                                    float gapFilling, float gloss, float darkening) {
            float alpha = clamp(source.a, 0.0, 1.0);
            if (alpha <= 0.000001) { return vec4(0.0); }

            vec2 coord = destCoord();
            float midX = facePixelRect.x + facePixelRect.z * 0.5;
            float faceWidth = max(facePixelRect.z, 1.0);
            float faceHeight = max(facePixelRect.w, 1.0);

            float foreheadY = facePixelRect.y + faceHeight * 0.70;
            float crownMidY = facePixelRect.y + faceHeight * 1.35;
            float crownTopY = facePixelRect.y + faceHeight * 1.90;

            // Spatial weighting
            float hairYWeight = smoothstep(foreheadY - faceHeight * 0.15, foreheadY + faceHeight * 0.08, coord.y)
                              * (1.0 - smoothstep(crownTopY - faceHeight * 0.20, crownTopY + faceHeight * 0.10, coord.y));
            float hairXDist = abs(coord.x - midX);
            float maxHairHalfWidth = faceWidth * 0.85;
            float hairXWeight = 1.0 - smoothstep(maxHairHalfWidth * 0.75, maxHairHalfWidth * 1.15, hairXDist);
            float hairRegionWeight = hairYWeight * hairXWeight;

            if (hairRegionWeight <= 0.00001) {
                return source;
            }

            // Central hair parting corridor
            float partingRadius = max(faceWidth * 0.28, 1.0);
            float partingWeight = exp(-pow(hairXDist / partingRadius, 2.0)) * hairYWeight;

            // Crown arc (Angel Ring highlight band)
            float crownArcYDist = abs(coord.y - crownMidY);
            float crownArcRadius = max(faceHeight * 0.35, 1.0);
            float crownArcWeight = exp(-pow(crownArcYDist / crownArcRadius, 2.0)) * hairXWeight;

            // Color metrics (extended linear sRGB)
            vec3 color = source.rgb;
            float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
            float redDiff = color.r - color.b;

            // 1. Hair gap / scalp filling
            if (gapFilling > 0.0001) {
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

            // 2. Hair gloss / sheen
            if (gloss > 0.0001) {
                float isHighlight = smoothstep(0.10, 0.35, luma) * (1.0 - smoothstep(0.65, 0.95, luma));
                float glossBoost = isHighlight * crownArcWeight * gloss * 0.32;
                color = color * (1.0 + glossBoost);
            }

            // 3. Hair darkening & brassiness suppression
            if (darkening > 0.0001) {
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
        guard settings.hairGapFilling > 0 || settings.hairGloss > 0 || settings.hairDarkening > 0 else {
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

        var result = image
        for rect in faceRects {
            try cancellation?.check()
            let faceVec = CIVector(x: rect.origin.x, y: rect.origin.y, z: rect.size.width, w: rect.size.height)
            guard let filtered = kernel.apply(
                extent: extent,
                arguments: [
                    result,
                    faceVec,
                    Float(settings.hairGapFilling),
                    Float(settings.hairGloss),
                    Float(settings.hairDarkening)
                ]
            ) else {
                continue
            }
            result = filtered
        }

        return result
    }
}

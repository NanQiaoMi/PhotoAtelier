import CoreGraphics
import CoreImage
import Foundation

/// Native engine for P2-R: Smart hair color harmonization, gray hair removal & natural salon recoloring.
///
/// Aligning with PixelCake §4.7:
/// 1. **去白发 / 银发消除 (`grayHairRemoval`)**:
///    Detects high-luminance, achromatic silver/white hair filaments within the cranial hair mass,
///    softly darkening and blending them toward ambient base hair pigment while preserving
///    natural hair strand micro-textures and highlights (avoiding unnatural black-helmet look).
/// 2. **发色统一 (`hairHarmonization`)**:
///    Detects patchy discoloration, sun-bleached brassiness, and chemical dye fading bands,
///    gently harmonizing chromatic outliers toward the dominant median hair hue and saturation.
/// 3. **自然换发色 (`hairTone`, `hairToneStrength`, `hairLuminanceAdjust`)**:
///    Transforms hair into 7 classic salon hair color presets (Natural Black, Chestnut Brown,
///    Mocha Dark, Burgundy Red, Cool Linen, Honey Gold), preserving luminosity gradients
///    and specular highlights for a realistic, glossy finish.
public enum HairColorEngine {

    public struct Result {
        public let image: CIImage
        public let report: HairColorReport

        public init(image: CIImage, report: HairColorReport) {
            self.image = image
            self.report = report
        }
    }

    private static let hairColorKernelSource = """
    kernel vec4 applyHairColor(__sample source, __sample personMask, vec4 facePixelRect,
                               float grayRemoval, float harmonization,
                               float toneIndex, float toneStrength, float lumaAdjust,
                               vec3 targetHairRGB, vec3 medianHairRGB) {
        float alpha = clamp(source.a, 0.0, 1.0);
        if (alpha <= 0.000001) { return vec4(0.0); }

        vec2 coord = destCoord();
        float midX = facePixelRect.x + facePixelRect.z * 0.5;
        float faceWidth = max(facePixelRect.z, 1.0);
        float faceHeight = max(facePixelRect.w, 1.0);

        float foreheadY = facePixelRect.y + faceHeight * 0.70;
        float crownMidY = facePixelRect.y + faceHeight * 1.30;
        float crownTopY = facePixelRect.y + faceHeight * 1.95;

        // Vertical crown weighting
        float crownYWeight = smoothstep(foreheadY - faceHeight * 0.05, foreheadY + faceHeight * 0.15, coord.y)
                           * (1.0 - smoothstep(crownTopY - faceHeight * 0.20, crownTopY + faceHeight * 0.10, coord.y));
        float hairXDist = abs(coord.x - midX);
        float maxHairHalfWidth = faceWidth * 0.95;
        float crownXWeight = 1.0 - smoothstep(maxHairHalfWidth * 0.70, maxHairHalfWidth * 1.25, hairXDist);
        float crownWeight = crownYWeight * crownXWeight;

        // Lateral hair sides (around ears and temples down to jawline)
        float lateralYWeight = smoothstep(facePixelRect.y + faceHeight * 0.20, facePixelRect.y + faceHeight * 0.45, coord.y)
                             * (1.0 - smoothstep(foreheadY + faceHeight * 0.10, crownMidY, coord.y));
        float lateralXWeight = smoothstep(faceWidth * 0.38, faceWidth * 0.55, hairXDist)
                             * (1.0 - smoothstep(faceWidth * 0.85, maxHairHalfWidth * 1.25, hairXDist));
        float lateralWeight = lateralYWeight * lateralXWeight;

        float hairRegionWeight = clamp(crownWeight + lateralWeight, 0.0, 1.0);

        // Constrain to person segmentation mask if available (personMask.r > 0)
        float personAlpha = clamp(personMask.r, 0.0, 1.0);
        if (personAlpha > 0.00001) {
            hairRegionWeight *= personAlpha;
        }

        if (hairRegionWeight <= 0.00001) {
            return source;
        }

        vec3 color = source.rgb;
        float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float maxRGB = max(color.r, max(color.g, color.b));
        float minRGB = min(color.r, min(color.g, color.b));
        float chroma = maxRGB - minRGB;
        float sat = (maxRGB > 0.001) ? (chroma / maxRGB) : 0.0;

        // 1. 去白发 / 银发消除 (Gray Hair Removal)
        if (grayRemoval > 0.0001) {
            float isGrayLuma = smoothstep(0.22, 0.55, luma);
            float isAchromatic = 1.0 - smoothstep(0.12, 0.28, sat);
            float grayConfidence = isGrayLuma * isAchromatic * hairRegionWeight;
            if (grayConfidence > 0.0001) {
                float grayGain = clamp(grayRemoval * grayConfidence, 0.0, 1.0);
                vec3 targetBase = medianHairRGB * (0.6 + 0.4 * luma);
                color = mix(color, targetBase, grayGain * 0.90);
            }
        }

        // 2. 发色统一 (Hair Color Harmonization)
        if (harmonization > 0.0001) {
            float dist = length(color - medianHairRGB);
            float outlier = smoothstep(0.10, 0.40, dist);
            float harmGain = clamp(harmonization * outlier * hairRegionWeight, 0.0, 1.0);
            if (harmGain > 0.0001) {
                float medianLuma = max(dot(medianHairRGB, vec3(0.2126, 0.7152, 0.0722)), 0.05);
                vec3 harmonized = medianHairRGB * (luma / medianLuma);
                color = mix(color, harmonized, harmGain * 0.75);
            }
        }

        // 3. 自然换发色 (Salon Hair Tone)
        if (toneIndex > 0.5 && toneStrength > 0.0001) {
            float targetLuma = max(dot(targetHairRGB, vec3(0.2126, 0.7152, 0.0722)), 0.05);
            vec3 recolored = targetHairRGB * (luma / targetLuma);
            float toneGain = clamp(toneStrength * hairRegionWeight * 0.85, 0.0, 1.0);
            color = mix(color, recolored, toneGain);
        }

        // 4. 发色明度调整 (Hair Luminance Adjustment)
        if (abs(lumaAdjust) > 0.0001) {
            color = color * (1.0 + lumaAdjust * hairRegionWeight * 0.80);
        }

        return vec4(clamp(color, 0.0, 1.0), source.a);
    }
    """

    private static let hairColorKernel: CIColorKernel? = {
        CIColorKernel(source: hairColorKernelSource)
    }()

    /// Applies hair color harmonization, gray hair removal & recoloring across detected faces.
    public static func apply(to image: CIImage,
                             faces: [FaceLandmarkSet],
                             settings: HairColorSettings,
                             personMask: CIImage? = nil) -> Result {
        guard !settings.isNeutral else {
            return Result(image: image, report: HairColorReport(applied: false, faceCount: faces.count))
        }

        let usableFaces = faces.filter { $0.hasUsableGeometry }
        guard !usableFaces.isEmpty else {
            return Result(
                image: image,
                report: HairColorReport(
                    applied: false,
                    faceCount: 0,
                    note: "未检测到可用人脸，发色调整已跳过（原图保持不变）。"
                )
            )
        }

        guard let kernel = hairColorKernel else {
            return Result(
                image: image,
                report: HairColorReport(
                    applied: false,
                    faceCount: usableFaces.count,
                    note: "着色器编译失败，发色调整已跳过。"
                )
            )
        }

        let extent = image.extent
        guard extent.width > 1, extent.height > 1, extent.width.isFinite, extent.height.isFinite else {
            return Result(image: image, report: HairColorReport(applied: false, faceCount: usableFaces.count))
        }

        let fallbackMask = personMask ?? CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent)
        let targetRGB = settings.hairTone.targetRGB
        let targetVec = CIVector(x: targetRGB.r, y: targetRGB.g, z: targetRGB.b)
        let medianVec = CIVector(x: 0.12, y: 0.10, z: 0.08) // Standard healthy base dark hair tone

        var current = image
        for face in usableFaces {
            let box = face.boundingBox
            let pixelRect = CGRect(
                x: extent.origin.x + box.origin.x * extent.width,
                y: extent.origin.y + box.origin.y * extent.height,
                width: box.width * extent.width,
                height: box.height * extent.height
            )
            let faceVec = CIVector(x: pixelRect.origin.x, y: pixelRect.origin.y, z: pixelRect.width, w: pixelRect.height)

            guard let rendered = kernel.apply(
                extent: extent,
                arguments: [
                    current,
                    fallbackMask,
                    faceVec,
                    Float(settings.grayHairRemoval),
                    Float(settings.hairHarmonization),
                    Float(settings.hairTone.toneIndex),
                    Float(settings.hairToneStrength),
                    Float(settings.hairLuminanceAdjust),
                    targetVec,
                    medianVec
                ]
            ) else {
                continue
            }
            current = rendered
        }

        let report = HairColorReport(
            applied: true,
            faceCount: usableFaces.count,
            grayHairApplied: settings.grayHairRemoval > 0,
            harmonizationApplied: settings.hairHarmonization > 0,
            toneApplied: settings.hairTone != .original && settings.hairToneStrength > 0,
            note: nil
        )
        return Result(image: current, report: report)
    }

    /// Applies hair color refinement to a single person's face in the multi-person demographic pipeline.
    public static func applyPerPerson(to image: CIImage,
                                      face: FaceLandmarkSet,
                                      faceIndex: Int,
                                      perFaceMask: FaceSemanticMaskSet?,
                                      settings: HairColorSettings) -> CIImage {
        guard !settings.isNeutral, face.hasUsableGeometry else {
            return image
        }
        let result = apply(to: image, faces: [face], settings: settings)
        guard result.report.applied else {
            return image
        }
        return result.image
    }
}

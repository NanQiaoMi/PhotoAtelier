import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Smart body and hand skin refinement: neck wrinkle smoothing, hand vein reduction,
/// body skin frequency separation, and body-to-face skin tone harmonization.
///
/// Designed for studio portraits, wedding photography, corporate headshots, and certificate
/// photos where exposed neck, shoulders, arms, and hands require natural skin smoothing
/// and tone matching without creating a waxy/plastic look. Automatically isolates
/// exposed body skin from person segmentation (strictly excluding face, eyes, lips, and hair),
/// suppresses neck creases and cool-toned superficial veins on hands/arms, and retains
/// true micro-pore skin texture.
public enum BodySkinRefinementEngine {

    private static let bodySkinKernel: CIColorKernel? = {
        let source = """
        kernel vec4 applyBodySkinRefine(__sample source, __sample drapeBase, __sample midSmooth,
                                        __sample personMask, __sample faceMask, __sample neckMask,
                                        vec3 faceAnchorRGB, float hasFaceAnchor,
                                        float neckSmoothing, float bodySmoothing,
                                        float veinReduction, float bodyToneHarmonization,
                                        float texturePreservation) {
            float alpha = clamp(source.a, 0.0, 1.0);
            if (alpha <= 0.000001) { return vec4(0.0); }

            // 1. Person body mask: 1.0 on person, 0.0 on background
            float pWeight = clamp(personMask.r, 0.0, 1.0);
            pWeight = smoothstep(0.10, 0.85, pWeight);
            if (pWeight <= 0.00001) {
                return source;
            }

            // 2. Face & head exclusion: strictly shield face/eyes/lips/hair
            float fWeight = clamp(faceMask.r, 0.0, 1.0);
            float bodyWeight = pWeight * (1.0 - smoothstep(0.05, 0.65, fWeight));
            if (bodyWeight <= 0.00001) {
                return source;
            }

            vec3 c = source.rgb;
            vec3 cDrape = drapeBase.rgb;
            vec3 cMid = midSmooth.rgb;

            // 3. Exposed skin detection based on drape base color (cDrape)
            // Using cDrape averages out local veins, blemishes, and creases so the whole skin zone is recognized
            float lumaDrape = max(dot(cDrape, vec3(0.2126, 0.7152, 0.0722)), 0.0);
            float skinWarmth = smoothstep(0.005, 0.06, cDrape.r - cDrape.g)
                             * smoothstep(0.001, 0.04, cDrape.g - cDrape.b);
            float skinLuma = smoothstep(0.02, 0.14, lumaDrape)
                           * (1.0 - smoothstep(0.85, 1.35, lumaDrape));
            float skinMask = skinWarmth * skinLuma;
            float skinWeight = bodyWeight * smoothstep(0.08, 0.45, skinMask);
            if (skinWeight <= 0.00001) {
                return source;
            }

            float luma = max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 0.0001);

            // High-frequency skin micro-texture (pores, fine skin detail)
            vec3 microTexture = c - cMid;

            vec3 current = c;

            // 4. Neck Crease & Wrinkle Smoothing
            float nWeight = clamp(neckMask.r, 0.0, 1.0);
            if (neckSmoothing > 0.0001 && nWeight > 0.0001) {
                // Neck creases are dark troughs relative to drape base
                float lumaDeltaDrape = luma - lumaDrape;
                float creaseShadow = smoothstep(0.003, 0.10, max(0.0, -lumaDeltaDrape));
                float neckFactor = neckSmoothing * nWeight;
                // Blend crease toward drape base to fill the shadow trough
                vec3 neckLifted = mix(current, cDrape, clamp(neckFactor * (0.75 + 0.25 * creaseShadow), 0.0, 1.0));
                current = neckLifted;
            }

            // 5. Hand / Arm Vein Reduction
            if (veinReduction > 0.0001) {
                // In a vein, c is cooler than surrounding skin baseline cDrape
                float coolness = smoothstep(-0.01, 0.04, (c.b - cDrape.b) - (c.r - cDrape.r) * 0.4);
                float localTrough = smoothstep(0.003, 0.08, max(0.0, lumaDrape - luma));
                float veinStrength = max(coolness, localTrough);
                if (veinStrength > 0.0001) {
                    vec3 veinSuppressed = mix(current, cDrape, clamp(veinReduction * veinStrength * 1.5, 0.0, 1.0));
                    current = veinSuppressed;
                }
            }

            // 6. Body Skin Smoothing (Dodge & Burn / Frequency Separation)
            if (bodySmoothing > 0.0001) {
                float smoothFactor = bodySmoothing * 0.90;
                vec3 smoothed = mix(current, cMid, clamp(smoothFactor, 0.0, 1.0));
                current = smoothed;
            }

            // 7. Micro-texture Restoration
            current = current + microTexture * clamp(texturePreservation, 0.0, 1.5);

            // 8. Body-to-Face Skin Tone Harmonization
            if (bodyToneHarmonization > 0.0001 && hasFaceAnchor > 0.5) {
                float faceLuma = max(dot(faceAnchorRGB, vec3(0.2126, 0.7152, 0.0722)), 0.001);
                vec3 faceChroma = faceAnchorRGB / faceLuma;
                float curLuma = max(dot(current, vec3(0.2126, 0.7152, 0.0722)), 0.001);
                vec3 curChroma = current / curLuma;
                vec3 targetChroma = mix(curChroma, faceChroma, clamp(bodyToneHarmonization * 0.65, 0.0, 1.0));
                vec3 harmonized = curLuma * targetChroma;
                current = mix(current, harmonized, clamp(bodyToneHarmonization * 0.75, 0.0, 1.0));
            }

            // Final composite with original source
            vec3 finalColor = mix(c, current, clamp(skinWeight, 0.0, 1.0));
            return vec4(finalColor, source.a);
        }
        """
        return CIColorKernel(source: source)
    }()

    /// Applies smart body and hand skin refinement to `image`.
    ///
    /// - Parameters:
    ///   - image: Working canvas in linear sRGB.
    ///   - settings: Body skin refinement controls.
    ///   - personMatte: Optional pre-computed person matte. If nil, will detect via `PersonMatting`.
    ///   - faceLandmarks: Optional pre-detected face landmark sets for face exclusion and neck localization.
    ///   - context: CIContext for rendering/evaluation.
    ///   - cancellation: Optional cancellation token.
    public static func apply(_ image: CIImage,
                             settings: BodySkinRefinementSettings,
                             personMatte: PersonMatte?,
                             faceLandmarks: [FaceLandmarkSet]?,
                             context: CIContext,
                             cancellation: CancellationToken? = nil) throws -> (image: CIImage, report: BodySkinRefinementReport) {
        guard !settings.isNeutral else {
            return (image, BodySkinRefinementReport(applied: false, note: "身体与手部美肤未启用或参数全为中性。"))
        }
        _ = try settings.validated()

        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 1, extent.height > 1 else {
            return (image, BodySkinRefinementReport(applied: false, note: "图像尺寸无效。"))
        }

        try cancellation?.check()

        // Resolve person matte gracefully
        let activeMatte: PersonMatte?
        if let personMatte {
            activeMatte = personMatte
        } else {
            activeMatte = try? PersonMatting.detect(in: image, context: context)
        }

        guard let activeMatte, activeMatte.hasPerson else {
            return (image, BodySkinRefinementReport(applied: false, note: "未检测到人物主体，身体美肤已跳过。"))
        }

        try cancellation?.check()

        guard let kernel = bodySkinKernel else {
            throw AtelierError.invalidConfiguration("初始化身体美肤着色器失败。")
        }

        // Generate face exclusion mask & neck corridor mask
        let faces = faceLandmarks ?? FaceSemanticAnalyzer.detect(in: image, maxFaces: 4)
        let faceMask = makeFaceExclusionMask(faces: faces, extent: extent)
        let neckMask = makeNeckCorridorMask(faces: faces, extent: extent)

        // Sample face anchor color
        let faceAnchor = sampleFaceAnchor(image: image, faces: faces, extent: extent, context: context)

        // Generate multi-scale frequency representations
        let shorterEdge = Double(min(extent.width, extent.height))
        let midSigma = max(2.0, shorterEdge * 0.007)
        let drapeSigma = max(8.0, shorterEdge * 0.028)

        let midSmooth = image.clampedToExtent()
            .applyingGaussianBlur(sigma: midSigma)
            .cropped(to: extent)
        let drapeBase = image.clampedToExtent()
            .applyingGaussianBlur(sigma: drapeSigma)
            .cropped(to: extent)

        try cancellation?.check()

        let personMaskImage = activeMatte.mask

        guard let output = kernel.apply(
            extent: extent,
            arguments: [
                image,
                drapeBase,
                midSmooth,
                personMaskImage,
                faceMask,
                neckMask,
                faceAnchor.vector,
                faceAnchor.hasAnchor ? Float(1.0) : Float(0.0),
                Float(settings.neckSmoothing),
                Float(settings.bodySmoothing),
                Float(settings.veinReduction),
                Float(settings.bodyToneHarmonization),
                Float(settings.texturePreservation)
            ]
        ) else {
            throw AtelierError.invalidConfiguration("执行身体美肤渲染失败。")
        }

        var steps: [String] = []
        if settings.neckSmoothing > 0 { steps.append("neckSmoothing(\(Int(settings.neckSmoothing * 100))%)") }
        if settings.veinReduction > 0 { steps.append("veinReduction(\(Int(settings.veinReduction * 100))%)") }
        if settings.bodySmoothing > 0 { steps.append("bodySmoothing(\(Int(settings.bodySmoothing * 100))%)") }
        if settings.bodyToneHarmonization > 0 { steps.append("bodyToneHarmonization(\(Int(settings.bodyToneHarmonization * 100))%)") }

        let report = BodySkinRefinementReport(
            applied: true,
            appliedSteps: steps,
            note: "已成功应用身体与手部美肤精修（\(steps.joined(separator: " + "))）。"
        )

        return (output, report)
    }

    // MARK: - Mask Helpers

    private static func makeFaceExclusionMask(faces: [FaceLandmarkSet], extent: CGRect) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        }
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1.0, alpha: 1.0)

        for face in faces {
            let bbox = face.boundingBox
            let faceW = bbox.width * extent.width
            let faceH = bbox.height * extent.height
            let faceX = bbox.origin.x * extent.width
            let faceY = bbox.origin.y * extent.height

            // Feathered ellipse covering the entire face, eyes, lips, jaw, and hair crown
            let expandedRect = CGRect(
                x: faceX - faceW * 0.15,
                y: faceY - faceH * 0.20,
                width: faceW * 1.30,
                height: faceH * 1.45
            )
            ctx.fillEllipse(in: expandedRect)
        }

        guard let cgImage = ctx.makeImage() else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        }

        let shorterEdge = Double(min(extent.width, extent.height))
        let blurRadius = max(3.0, shorterEdge * 0.025)
        return CIImage(cgImage: cgImage)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: blurRadius)
            .cropped(to: extent)
    }

    private static func makeNeckCorridorMask(faces: [FaceLandmarkSet], extent: CGRect) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        }
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1.0, alpha: 1.0)

        for face in faces {
            let bbox = face.boundingBox
            let faceW = bbox.width * extent.width
            let faceH = bbox.height * extent.height
            let faceX = bbox.origin.x * extent.width
            let faceY = bbox.origin.y * extent.height

            // Neck corridor sits directly underneath the chin down to collarbone
            let neckW = faceW * 0.70
            let neckH = faceH * 0.85
            let neckX = faceX + (faceW - neckW) * 0.5
            let neckY = max(0, faceY - neckH * 0.90)

            let neckRect = CGRect(x: neckX, y: neckY, width: neckW, height: neckH)
            ctx.fillEllipse(in: neckRect)
        }

        guard let cgImage = ctx.makeImage() else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        }

        let shorterEdge = Double(min(extent.width, extent.height))
        let blurRadius = max(4.0, shorterEdge * 0.035)
        return CIImage(cgImage: cgImage)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: blurRadius)
            .cropped(to: extent)
    }

    private static func sampleFaceAnchor(image: CIImage,
                                        faces: [FaceLandmarkSet],
                                        extent: CGRect,
                                        context: CIContext) -> (vector: CIVector, hasAnchor: Bool) {
        guard let primaryFace = faces.max(by: { a, b in
            let areaA = a.boundingBox.width * a.boundingBox.height
            let areaB = b.boundingBox.width * b.boundingBox.height
            return areaA < areaB
        }) else {
            return (CIVector(x: 0, y: 0, z: 0), false)
        }

        let bbox = primaryFace.boundingBox
        let faceW = bbox.width * extent.width
        let faceH = bbox.height * extent.height
        let faceMidX = bbox.origin.x * extent.width + faceW * 0.5
        let faceMidY = bbox.origin.y * extent.height + faceH * 0.45 // nose/cheek center

        let sampleRect = CGRect(x: faceMidX - 8, y: faceMidY - 8, width: 16, height: 16).intersection(extent)
        guard sampleRect.width >= 2, sampleRect.height >= 2 else {
            return (CIVector(x: 0, y: 0, z: 0), false)
        }

        let avgFilter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: sampleRect)
        ])
        guard let avgImage = avgFilter?.outputImage else {
            return (CIVector(x: 0, y: 0, z: 0), false)
        }

        var pixel = [Float](repeating: 0, count: 4)
        context.render(avgImage, toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf,
                       colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.linearSRGB)!)

        let r = pixel[0]
        let g = pixel[1]
        let b = pixel[2]

        // Ensure reasonable skin warmth (red > green > blue and sufficient brightness)
        guard r.isFinite, g.isFinite, b.isFinite,
              r > 0.04, r > b, (r - b) > 0.01 else {
            return (CIVector(x: 0, y: 0, z: 0), false)
        }

        return (CIVector(x: CGFloat(r), y: CGFloat(g), z: CGFloat(b)), true)
    }
}

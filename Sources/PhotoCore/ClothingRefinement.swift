import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Smart clothing wrinkle smoothing, crease suppression, and fabric texture preservation.
///
/// Designed for studio portraits, corporate headshots, fashion lookbooks, and certificate
/// photos where garments (shirts, suits, dresses, T-shirts) contain unwanted transport
/// wrinkles, sitting folds, or creases. Automatically isolates the clothing region
/// from the person segmentation (excluding face, hair, and exposed skin), performs
/// multi-frequency separation to smooth fabric folds, and preserves or restores the
/// fine micro-weave fabric texture so the garment looks natural rather than plastic.
public enum ClothingRefinementEngine {

    private static let clothingKernel: CIColorKernel? = {
        let source = """
        kernel vec4 applyClothingRefine(__sample source, __sample drapeBase, __sample midSmooth,
                                        __sample personMask, __sample headMask,
                                        float wrinkleSmoothing, float creaseRemoval, float texturePreservation) {
            float alpha = clamp(source.a, 0.0, 1.0);
            if (alpha <= 0.000001) { return vec4(0.0); }

            // 1. Person body mask: 1.0 on person, 0.0 on background
            float pWeight = clamp(personMask.r, 0.0, 1.0);
            pWeight = smoothstep(0.10, 0.85, pWeight);
            if (pWeight <= 0.00001) {
                return source;
            }

            // 2. Head & hair exclusion: 1.0 on head/hair, 0.0 on body
            float hWeight = clamp(headMask.r, 0.0, 1.0);
            float bodyWeight = pWeight * (1.0 - smoothstep(0.05, 0.60, hWeight));
            if (bodyWeight <= 0.00001) {
                return source;
            }

            // 3. Exposed skin protection (neck, chest, bare arms)
            vec3 c = source.rgb;
            float luma = max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 0.0);
            float skinWarmth = smoothstep(0.015, 0.12, c.r - c.g)
                             * smoothstep(0.005, 0.08, c.g - c.b);
            float skinLuma = smoothstep(0.04, 0.20, luma)
                           * (1.0 - smoothstep(0.80, 1.30, luma));
            float skinMask = skinWarmth * skinLuma;
            float clothWeight = bodyWeight * (1.0 - smoothstep(0.20, 0.75, skinMask));
            if (clothWeight <= 0.00001) {
                return source;
            }

            vec3 cBase = drapeBase.rgb;
            vec3 cMid = midSmooth.rgb;

            // High-frequency micro-texture (fabric grain, knit pattern, weave)
            vec3 microTexture = c - cMid;

            // Luminance differences for wrinkles and folds
            float lumaBase = max(dot(cBase, vec3(0.2126, 0.7152, 0.0722)), 0.0001);
            float lumaMid = max(dot(cMid, vec3(0.2126, 0.7152, 0.0722)), 0.0001);
            float lumaDeltaBase = luma - lumaBase;
            float lumaDeltaMid = luma - lumaMid;

            // 4. Wrinkle Smoothing: blend toward smooth drape while preserving 3D form
            vec3 smoothed = c;
            if (wrinkleSmoothing > 0.0001) {
                float foldAttenuation = 1.0 - wrinkleSmoothing * clothWeight * (1.0 - smoothstep(0.35, 0.70, abs(lumaDeltaBase)));
                vec3 foldSuppressed = cBase + (cMid - cBase) * foldAttenuation;
                smoothed = mix(smoothed, foldSuppressed, clamp(wrinkleSmoothing * clothWeight * 0.90, 0.0, 1.0));
            }

            // 5. Crease Removal: attenuate sharp high-contrast crease lines in fabric
            if (creaseRemoval > 0.0001) {
                float isCrease = smoothstep(0.015, 0.25, abs(lumaDeltaMid));
                float creaseFactor = creaseRemoval * clothWeight * isCrease * 0.95;
                smoothed = mix(smoothed, cBase, clamp(creaseFactor, 0.0, 1.0));
            }

            // 6. Texture Retention: add back preserved fabric grain
            vec3 textured = smoothed + microTexture * clamp(texturePreservation, 0.0, 1.5);

            // Final composite
            vec3 finalColor = mix(c, textured, clamp(clothWeight, 0.0, 1.0));
            return vec4(finalColor, source.a);
        }
        """
        return CIColorKernel(source: source)
    }()

    /// Applies clothing wrinkle smoothing and crease suppression to `image`.
    ///
    /// - Parameters:
    ///   - image: Working canvas in linear sRGB.
    ///   - settings: Clothing refinement controls.
    ///   - personMatte: Optional pre-computed person matte. If nil, will detect via `PersonMatting`.
    ///   - faceLandmarks: Optional pre-detected face landmark sets for head/hair exclusion.
    ///   - context: CIContext for rendering/evaluation.
    ///   - cancellation: Optional cancellation token.
    public static func apply(_ image: CIImage,
                             settings: ClothingRefinementSettings,
                             personMatte: PersonMatte?,
                             faceLandmarks: [FaceLandmarkSet]?,
                             context: CIContext,
                             cancellation: CancellationToken? = nil) throws -> (image: CIImage, report: ClothingRefinementReport) {
        guard !settings.isNeutral else {
            return (image, ClothingRefinementReport(applied: false, note: "衣物平整未启用或参数全为中性。"))
        }
        _ = try settings.validated()

        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 1, extent.height > 1 else {
            return (image, ClothingRefinementReport(applied: false, note: "图像尺寸无效。"))
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
            return (image, ClothingRefinementReport(applied: false, note: "未检测到人物主体，衣物平整已跳过。"))
        }

        try cancellation?.check()

        guard let kernel = clothingKernel else {
            throw AtelierError.invalidConfiguration("初始化衣物平整着色器失败。")
        }

        // Generate head/hair exclusion mask
        let faces = faceLandmarks ?? FaceSemanticAnalyzer.detect(in: image, maxFaces: 4)
        let headMask = makeHeadExclusionMask(faces: faces, extent: extent)

        // Generate multi-scale frequency representations
        let shorterEdge = Double(min(extent.width, extent.height))
        let baseSigma = max(8.0, min(36.0, shorterEdge * 0.030))
        let drapeBase = image.clampedToExtent().applyingGaussianBlur(sigma: baseSigma).cropped(to: extent)

        let midSigma = max(2.0, min(10.0, shorterEdge * 0.008))
        let midSmooth = image.clampedToExtent().applyingGaussianBlur(sigma: midSigma).cropped(to: extent)

        try cancellation?.check()

        guard let output = kernel.apply(
            extent: extent,
            arguments: [
                image,
                drapeBase,
                midSmooth,
                activeMatte.mask,
                headMask,
                Float(settings.wrinkleSmoothing),
                Float(settings.creaseRemoval),
                Float(settings.texturePreservation)
            ]
        ) else {
            throw AtelierError.invalidConfiguration("衣物平整着色器执行失败。")
        }

        var steps: [String] = []
        if settings.wrinkleSmoothing > 0 { steps.append("wrinkleSmoothing") }
        if settings.creaseRemoval > 0 { steps.append("creaseRemoval") }
        if settings.texturePreservation > 0 { steps.append("texturePreservation") }

        return (output, ClothingRefinementReport(applied: true, appliedSteps: steps))
    }

    // MARK: - Private Helpers

    private static func makeHeadExclusionMask(faces: [FaceLandmarkSet], extent: CGRect) -> CIImage {
        guard !faces.isEmpty else {
            return CIImage(color: .black).cropped(to: extent)
        }

        let width = max(1, Int(extent.width))
        let height = max(1, Int(extent.height))
        let colorSpace = CGColorSpaceCreateDeviceGray()

        guard let cgContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return CIImage(color: .black).cropped(to: extent)
        }

        cgContext.setFillColor(gray: 0.0, alpha: 1.0)
        cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        cgContext.setFillColor(gray: 1.0, alpha: 1.0)

        for face in faces {
            let box = face.boundingBox
            let fx = box.origin.x * CGFloat(width)
            let fy = box.origin.y * CGFloat(height)
            let fw = box.size.width * CGFloat(width)
            let fh = box.size.height * CGFloat(height)

            // Feathered ellipse covering head, hair crown, and neck down to collar
            let headRect = CGRect(
                x: fx - fw * 0.25,
                y: fy - fh * 0.20,
                width: fw * 1.50,
                height: fh * 1.90
            )
            cgContext.fillEllipse(in: headRect)
        }

        guard let cgImage = cgContext.makeImage() else {
            return CIImage(color: .black).cropped(to: extent)
        }

        let rawMask = CIImage(cgImage: cgImage)
        let blurRadius = max(4.0, min(30.0, Double(min(width, height)) * 0.02))
        return rawMask.clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }
}

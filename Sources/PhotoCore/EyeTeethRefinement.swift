import Foundation
import CoreImage
import CoreGraphics

/// P2-N: Smart eye catchlight, eyeglass anti-glare, sclera bloodshot removal & aesthetic teeth restoration engine.
///
/// Capabilities:
/// 1. `eyeglassGlareReduction`: Suppresses harsh flash reflections and white flare on eyeglass lenses.
/// 2. `scleraBloodshotRemoval`: Eliminates red bloodshot capillaries and yellow turbidity from the sclera (white of eye).
/// 3. `irisClarity`: Enhances radial iris fibers, depth, and limbal ring definition for clear, expressive gaze.
/// 4. `catchlightPattern`: 6 studio catchlight templates (.naturalPoint, .ringLight, .softboxSquare, .dualStrip, .butterfly, .starburst) with scale & strength control.
/// 5. `teethStainRemoval`: Purifies yellow/tea/coffee stains and lipstick border smudges on teeth.
/// 6. `enamelSheen`: Re-injects 3D translucent specular curvature highlights to avoid flat dead-white teeth.
/// 7. `gingivaProtection`: Protects natural pink gum tissue from being bleached during teeth whitening.
///
/// 100% offline, zero external model weights, Core Image & Metal accelerated.
public enum EyeTeethRefinementEngine {

    // MARK: - Kernels

    private static let eyeKernelSource = """
    kernel vec4 eyeRefinementKernel(
        sampler src,
        sampler scleraMask,
        sampler irisMask,
        sampler glareMask,
        vec4 eyeParams,     // x: sclera, y: iris, z: glare, w: face skin luma
        float irisPivot     // mean luminance of this photo's iris matte
    ) {
        vec4 c = sample(src, samplerCoord(src));
        float scleraM = sample(scleraMask, samplerCoord(scleraMask)).r;
        float irisM = sample(irisMask, samplerCoord(irisMask)).r;
        float glareM = sample(glareMask, samplerCoord(glareMask)).r;

        vec3 col = c.rgb;

        // 1. Sclera bloodshot & yellow haze removal
        float sStrength = eyeParams.x;
        if (scleraM > 0.001 && sStrength > 0.0) {
            float weight = clamp(scleraM * sStrength, 0.0, 1.0);
            float avgGB = (col.g + col.b) * 0.5;
            float redExcess = max(0.0, col.r - avgGB);
            col.r -= redExcess * weight * 0.88;

            float avgRG = (col.r + col.g) * 0.5;
            float yellowExcess = max(0.0, avgRG - col.b);
            col.b += yellowExcess * weight * 0.45;
        }

        // 2. Iris clarity & depth enhancement
        float iStrength = eyeParams.y;
        if (irisM > 0.001 && iStrength > 0.0) {
            float weight = clamp(irisM * iStrength, 0.0, 1.0);
            // R4 (2026-11-14): the contrast pivot used to be an ABSOLUTE
            // `vec3(0.35)` in extended-linear space, where a real iris sits at
            // 0.017-0.028. Every iris pixel is below that pivot, so "clarity"
            // *darkened* the whole iris (measured: all 96 masked pixels darker,
            // mean luma 0.0275 -> 0.0085). The pivot is now the iris's own mean
            // luminance, measured on the CPU (`irisMeanLuminance`), so the pass
            // expands contrast around the iris instead of crushing it.
            vec3 pivot = vec3(max(irisPivot, 0.0001));
            vec3 centered = col - pivot;
            vec3 boosted = col + centered * (weight * 0.45);
            col = mix(col, clamp(boosted, 0.0, 1.0), weight);
        }

        // 3. Eyeglass glare reduction
        float gStrength = eyeParams.z;
        if (glareM > 0.001 && gStrength > 0.0) {
            float weight = clamp(glareM * gStrength, 0.0, 1.0);
            // R3 (2026-11-14): the gate used to be an ABSOLUTE `luma > 0.65`.
            // The engine works in extended-linear-sRGB, where real skin sits
            // near 0.05-0.30, so the control was a silent no-op on real photos.
            //
            // The reference is now the FACE's own skin luminance (measured once
            // on the CPU and passed in as `eyeParams.w`), not the local blur:
            // a blur around the eye is dominated by the white sclera and the
            // glare itself, so comparing against it hid exactly the pixels this
            // pass exists to fix. Glare is, by definition, a reflection much
            // brighter than the skin it sits on.
            vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
            float luma = dot(col, LUMA);
            float skinLuma = max(eyeParams.w, 0.0001);
            float excess = luma / skinLuma;
            float glare = smoothstep(1.60, 2.40, excess);
            if (glare > 0.0) {
                // Compress the reflected excess (not the whole pixel) so the
                // flare stops reading as a mirror while the eye keeps its shape.
                float target = skinLuma + (luma - skinLuma) * 0.35;
                float compressed = mix(luma, target, glare * weight);
                col = luma > 0.00001 ? col * (compressed / luma) : col;
            }
        }

        // R3 (2026-11-14): never clamp pixels the masks do not touch - the
        // working space is extended-linear-sRGB and highlights above 1.0 are
        // legitimate. The old unconditional clamp silently clipped them across
        // the whole photograph whenever the eye pass was enabled.
        float eyeWeight = max(scleraM * eyeParams.x, max(irisM * eyeParams.y, glareM * eyeParams.z));
        if (eyeWeight <= 0.00001) { return c; }
        return vec4(clamp(col, 0.0, 1.0), c.a);
    }
    """

    private static let teethKernelSource = """
    kernel vec4 teethRefinementKernel(
        sampler src,
        sampler teethMask,
        sampler gingivaMask,
        vec4 teethParams
    ) {
        vec4 c = sample(src, samplerCoord(src));
        float teethM = sample(teethMask, samplerCoord(teethMask)).r;
        float gingivaM = sample(gingivaMask, samplerCoord(gingivaMask)).r;

        vec3 col = c.rgb;

        // Gingiva protection: reduce teeth modification where gums are present
        float protectFactor = teethParams.z;
        float effectiveTeeth = teethM * (1.0 - clamp(gingivaM * protectFactor, 0.0, 0.95));

        if (effectiveTeeth > 0.001) {
            // 1. Stain removal (yellow/tea stains + lipstick smudges)
            float stainStrength = teethParams.x;
            if (stainStrength > 0.0) {
                float weight = clamp(effectiveTeeth * stainStrength, 0.0, 1.0);
                // Neutralize yellowing: bring B up toward (R+G)/2
                float yellowStain = max(0.0, ((col.r + col.g) * 0.5) - col.b);
                col.b += yellowStain * weight * 0.80;

                // Neutralize red lipstick smudge onto teeth
                float lipSmudge = max(0.0, col.r - max(col.g, col.b) * 1.20);
                col.r -= lipSmudge * weight * 0.70;
            }

            // 2. Enamel sheen: translucent 3D specular highlight
            float sheenStrength = teethParams.y;
            if (sheenStrength > 0.0) {
                float weight = clamp(effectiveTeeth * sheenStrength, 0.0, 1.0);
                float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
                float specular = pow(luma, 2.5) * 0.35 * weight;
                col += vec3(specular);
            }
        }

        // R3 (2026-11-14): as in the eye kernel, pixels outside the teeth matte
        // must pass through untouched - an unconditional clamp would clip the
        // extended-range highlights of the whole photograph.
        if (effectiveTeeth <= 0.00001) { return c; }
        return vec4(clamp(col, 0.0, 1.0), c.a);
    }
    """

    private static let catchlightKernelSource = """
    kernel vec4 catchlightBlendKernel(sampler src, sampler catchlight, float strength) {
        vec4 c = sample(src, samplerCoord(src));
        vec4 cl = sample(catchlight, samplerCoord(catchlight));
        float overlay = clamp(cl.a * strength, 0.0, 1.0);
        if (overlay <= 0.00001) { return c; }
        vec3 blended = c.rgb + cl.rgb * overlay;
        return vec4(clamp(blended, 0.0, 1.0), c.a);
    }
    """

    private static let eyeKernel = CIColorKernel(source: eyeKernelSource)
    private static let teethKernel = CIColorKernel(source: teethKernelSource)
    private static let catchlightKernel = CIColorKernel(source: catchlightKernelSource)

    /// Shared read-only context for the catchlight probe. `CIContext` is
    /// thread-safe, and reusing one keeps the many small region renders cheap.
    private static let catchlightAnalysisContext = CIContext(
        options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    // MARK: - Public Apply

    /// Applies eye & teeth refinement pass across all faces.
    public static func apply(
        to image: CIImage,
        faces: [FaceLandmarkSet],
        settings: EyeTeethRefinementSettings,
        maskSet: FaceSemanticMaskSet? = nil
    ) -> (image: CIImage, report: EyeTeethRefinementReport) {
        guard !settings.isNeutral, !faces.isEmpty else {
            return (image, EyeTeethRefinementReport(applied: false, faceCount: faces.count, note: "跳过：中性设置或无检测人脸"))
        }

        let extent = image.extent
        var result = image

        // 1. Process Eye Pass (Bloodshot, Iris clarity, Eyeglass glare)
        var scleraCovered = false
        let hasEyeWork = settings.scleraBloodshotRemoval > 0 || settings.irisClarity > 0 || settings.eyeglassGlareReduction > 0
        if hasEyeWork {
            let scleraMask = maskSet?.sclera ?? makeScleraMask(faces: faces, extent: extent)
            let irisMask = maskSet?.iris ?? makeIrisMask(faces: faces, extent: extent)
            let glareMask = makeEyeglassGlareMask(image: image, faces: faces, extent: extent)
            scleraCovered = settings.scleraBloodshotRemoval > 0
                && hasCoverage(scleraMask, extent: extent)
            // The face's own skin luminance: the reference that makes glare "a
            // reflection much brighter than the skin" instead of "a bright
            // absolute value", in any working colour space.
            let skinLuma = faceSkinLuminance(image: image, faces: faces,
                                             extent: extent, context: catchlightAnalysisContext)
            // Iris clarity expands contrast around the iris's own mean, not an
            // absolute pivot (see `irisMeanLuminance`).
            let irisPivot = irisMeanLuminance(image: image, mask: irisMask,
                                              extent: extent, context: catchlightAnalysisContext)
                ?? 0.18

            if let kernel = eyeKernel {
                let params = CIVector(
                    x: CGFloat(settings.scleraBloodshotRemoval),
                    y: CGFloat(settings.irisClarity),
                    z: CGFloat(settings.eyeglassGlareReduction),
                    w: CGFloat(skinLuma)
                )
                if let processed = kernel.apply(
                    extent: extent,
                    arguments: [result, scleraMask, irisMask, glareMask, params, CGFloat(irisPivot)]
                ) {
                    result = processed
                }
            }
        }

        // 2. Process Catchlight Pass
        if settings.catchlightPattern != .off && settings.catchlightStrength > 0 {
            // R3 (2026-11-14): the overlay is driven by what the photo already
            // shows - an existing iris highlight is enhanced in place, and a
            // synthesized one only appears when the light direction is clear.
            let analysis = analyzeCatchlight(to: image, faces: faces, extent: extent,
                                             context: catchlightAnalysisContext)
            if let catchlightOverlay = makeCatchlightOverlay(
                faces: faces,
                pattern: settings.catchlightPattern,
                scale: settings.catchlightScale,
                extent: extent,
                analysis: analysis
            ), let kernel = catchlightKernel {
                if let blended = kernel.apply(
                    extent: extent,
                    arguments: [result, catchlightOverlay, CGFloat(settings.catchlightStrength)]
                ) {
                    result = blended
                }
            }
        }

        // 3. Process Teeth Pass (Stain removal, Enamel sheen, Gingiva protection)
        var teethCovered = false
        let hasTeethWork = settings.teethStainRemoval > 0 || settings.enamelSheen > 0
        if hasTeethWork {
            let teethMask = maskSet?.teeth ?? makeTeethMask(faces: faces, extent: extent)
            let gingivaMask = makeGingivaMask(image: image, faces: faces, extent: extent)
            teethCovered = settings.teethStainRemoval > 0
                && hasCoverage(teethMask, extent: extent)

            if let kernel = teethKernel {
                let params = CIVector(
                    x: CGFloat(settings.teethStainRemoval),
                    y: CGFloat(settings.enamelSheen),
                    z: CGFloat(settings.gingivaProtection),
                    w: 0.0
                )
                if let processed = kernel.apply(
                    extent: extent,
                    arguments: [result, teethMask, gingivaMask, params]
                ) {
                    result = processed
                }
            }
        }

        // R3 (2026-11-14): the flags used to be copied straight from the slider
        // values, so a closed mouth or an eye in shadow reported "teeth stain
        // removed" while changing no pixel. Each flag now requires a matte that
        // actually covers something.
        var skipped: [String] = []
        if settings.scleraBloodshotRemoval > 0 && !scleraCovered { skipped.append("眼白") }
        if settings.teethStainRemoval > 0 && !teethCovered { skipped.append("牙齿") }
        let note = skipped.isEmpty ? nil
            : "未检测到可用的\(skipped.joined(separator: "与"))蒙版（闭嘴、未露齿或眼部过暗），对应步骤未执行。"
        let report = EyeTeethRefinementReport(
            applied: true,
            faceCount: faces.count,
            eyeglassGlareApplied: settings.eyeglassGlareReduction > 0,
            scleraBloodshotApplied: scleraCovered,
            catchlightPattern: settings.catchlightPattern,
            teethStainApplied: teethCovered,
            note: note
        )
        return (result, report)
    }

    /// Applies eye & teeth refinement for an individual face in multi-person workflow.
    public static func applyPerPerson(
        to image: CIImage,
        face: FaceLandmarkSet,
        faceIndex: Int,
        perFaceMask: FaceSemanticMaskSet?,
        settings: EyeTeethRefinementSettings
    ) -> CIImage {
        guard !settings.isNeutral else { return image }
        let (output, _) = apply(to: image, faces: [face], settings: settings, maskSet: perFaceMask)
        return output
    }

    // MARK: - Masks & Catchlight Generation

    public static func makeScleraMask(faces: [FaceLandmarkSet], extent: CGRect) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return makeBlackMask(extent: extent)
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        ctx.setFillColor(gray: 1, alpha: 1)
        for face in faces {
            drawPolygon(face.leftEye, in: ctx, extent: extent)
            drawPolygon(face.rightEye, in: ctx, extent: extent)
        }
        guard let cgImg = ctx.makeImage() else { return makeBlackMask(extent: extent) }
        let rawMask = CIImage(cgImage: cgImg)
        return rawMask.clampedToExtent().applyingGaussianBlur(sigma: max(1.0, extent.height * 0.003)).cropped(to: extent)
    }

    public static func makeIrisMask(faces: [FaceLandmarkSet], extent: CGRect) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return makeBlackMask(extent: extent)
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        ctx.setFillColor(gray: 1, alpha: 1)
        for face in faces {
            let leftCenter = face.leftPupil ?? polygonCenter(face.leftEye)
            let rightCenter = face.rightPupil ?? polygonCenter(face.rightEye)
            let radius = estimateIrisRadius(face: face, extent: extent)

            if let lc = leftCenter {
                let px = lc.x * extent.width
                let py = lc.y * extent.height
                ctx.fillEllipse(in: CGRect(x: px - radius, y: py - radius, width: radius * 2, height: radius * 2))
            }
            if let rc = rightCenter {
                let px = rc.x * extent.width
                let py = rc.y * extent.height
                ctx.fillEllipse(in: CGRect(x: px - radius, y: py - radius, width: radius * 2, height: radius * 2))
            }
        }
        guard let cgImg = ctx.makeImage() else { return makeBlackMask(extent: extent) }
        let rawMask = CIImage(cgImage: cgImg)
        return rawMask.clampedToExtent().applyingGaussianBlur(sigma: max(1.0, extent.height * 0.002)).cropped(to: extent)
    }

    public static func makeEyeglassGlareMask(image: CIImage, faces: [FaceLandmarkSet], extent: CGRect) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return makeBlackMask(extent: extent)
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Eye socket and spectacle lens zone: expand eye bounds by 1.6x
        ctx.setFillColor(gray: 1, alpha: 1)
        for face in faces {
            if !face.leftEye.isEmpty {
                let b = polygonBounds(face.leftEye)
                let expanded = b.insetBy(dx: -b.width * 0.40, dy: -b.height * 0.50)
                let pxRect = CGRect(x: expanded.minX * extent.width, y: expanded.minY * extent.height,
                                    width: expanded.width * extent.width, height: expanded.height * extent.height)
                ctx.fillEllipse(in: pxRect)
            }
            if !face.rightEye.isEmpty {
                let b = polygonBounds(face.rightEye)
                let expanded = b.insetBy(dx: -b.width * 0.40, dy: -b.height * 0.50)
                let pxRect = CGRect(x: expanded.minX * extent.width, y: expanded.minY * extent.height,
                                    width: expanded.width * extent.width, height: expanded.height * extent.height)
                ctx.fillEllipse(in: pxRect)
            }
        }
        guard let cgImg = ctx.makeImage() else { return makeBlackMask(extent: extent) }
        let baseMask = CIImage(cgImage: cgImg).clampedToExtent().applyingGaussianBlur(sigma: max(1.0, extent.height * 0.005)).cropped(to: extent)
        return baseMask
    }

    public static func makeTeethMask(faces: [FaceLandmarkSet], extent: CGRect) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return makeBlackMask(extent: extent)
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        ctx.setFillColor(gray: 1, alpha: 1)
        for face in faces {
            if !face.innerLips.isEmpty {
                drawPolygon(face.innerLips, in: ctx, extent: extent)
            }
        }
        guard let cgImg = ctx.makeImage() else { return makeBlackMask(extent: extent) }
        let rawMask = CIImage(cgImage: cgImg)
        return rawMask.clampedToExtent().applyingGaussianBlur(sigma: max(1.0, extent.height * 0.002)).cropped(to: extent)
    }

    public static func makeGingivaMask(image: CIImage, faces: [FaceLandmarkSet], extent: CGRect) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return makeBlackMask(extent: extent)
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw upper and lower gum borders inside mouth
        ctx.setFillColor(gray: 0.8, alpha: 1)
        for face in faces {
            guard !face.innerLips.isEmpty else { continue }
            let b = polygonBounds(face.innerLips)
            // Upper gum: top 30% of inner mouth
            let upperGum = CGRect(x: b.minX * extent.width, y: (b.maxY - b.height * 0.35) * extent.height,
                                  width: b.width * extent.width, height: b.height * 0.35 * extent.height)
            ctx.fillEllipse(in: upperGum)
            // Lower gum: bottom 25% of inner mouth
            let lowerGum = CGRect(x: b.minX * extent.width, y: b.minY * extent.height,
                                  width: b.width * extent.width, height: b.height * 0.25 * extent.height)
            ctx.fillEllipse(in: lowerGum)
        }
        guard let cgImg = ctx.makeImage() else { return makeBlackMask(extent: extent) }
        return CIImage(cgImage: cgImg).clampedToExtent().applyingGaussianBlur(sigma: max(1.0, extent.height * 0.002)).cropped(to: extent)
    }

    /// R3 (2026-11-14, "针对人的处理特别差" review): a synthetic catchlight is
    /// only defensible when the photograph itself asks for it. The analysis
    /// below answers two questions from the pixels of the photo:
    ///
    /// * Does the iris already carry a specular highlight? If it does, the
    ///   catchlight must *enhance* that one instead of adding a second one
    ///   (the "双重高光" artifact the P2 review found on every portrait).
    /// * From which side does the light come? A catchlight that contradicts
    ///   the photo's own light direction reads as a sticker.
    public struct CatchlightAnalysis {
        public struct Eye {
            /// Center of an existing specular highlight in image pixels, when one
            /// is present in the iris.
            public var existingHighlight: CGPoint?
            /// Horizontal light direction, `-1` (from the left) ... `1` (from the right).
            public var lightOffsetX: Double
            /// Vertical light direction, `-1` (from below) ... `1` (from above).
            public var lightOffsetY: Double
            /// True when the light direction is clear enough to synthesize a highlight.
            public var hasDirection: Bool

            public init(existingHighlight: CGPoint? = nil,
                        lightOffsetX: Double = 0,
                        lightOffsetY: Double = 0,
                        hasDirection: Bool = false) {
                self.existingHighlight = existingHighlight
                self.lightOffsetX = lightOffsetX
                self.lightOffsetY = lightOffsetY
                self.hasDirection = hasDirection
            }
        }

        public var leftEye: Eye?
        public var rightEye: Eye?

        public init(leftEye: Eye? = nil, rightEye: Eye? = nil) {
            self.leftEye = leftEye
            self.rightEye = rightEye
        }
    }

    /// Measures, per face, the existing iris highlight and the light direction
    /// of the photograph. Read-only: the source image is never modified.
    public static func analyzeCatchlight(to image: CIImage,
                                         faces: [FaceLandmarkSet],
                                         extent: CGRect,
                                         context: CIContext) -> [CatchlightAnalysis] {
        faces.map { face in
            let irisRadius = estimateIrisRadius(face: face, extent: extent)
            let leftCenter = face.leftPupil ?? polygonCenter(face.leftEye)
            let rightCenter = face.rightPupil ?? polygonCenter(face.rightEye)

            func pupilPixels(_ center: CGPoint?) -> CGPoint? {
                guard let center else { return nil }
                return CGPoint(x: center.x * extent.width, y: center.y * extent.height)
            }
            let fallbackCenter = CGPoint(x: face.boundingBox.midX * extent.width,
                                         y: face.boundingBox.midY * extent.height)
            let leftPixel = pupilPixels(leftCenter)
            let rightPixel = pupilPixels(rightCenter)
            let leftEyeCenter = pupilPixels(polygonCenter(face.leftEye)) ?? leftPixel ?? fallbackCenter
            let rightEyeCenter = pupilPixels(polygonCenter(face.rightEye)) ?? rightPixel ?? fallbackCenter

            // Existing specular highlight inside each iris.
            func existingHighlight(around pixel: CGPoint?) -> CGPoint? {
                guard let pixel else { return nil }
                let sample = sampleRegion(image: image, center: pixel, radius: irisRadius * 1.15,
                                           extent: extent, context: context)
                guard let sample, sample.peak - sample.mean > 0.14, sample.peak > 0.25,
                      let centroid = sample.peakCentroid else { return nil }
                return centroid
            }

            // Light direction: the brighter side of the face carries the light.
            // Cheeks sit below the eyes, the forehead above them.
            let cheekOffset = irisRadius * 1.9
            var leftCheek: Double = 0.5
            var rightCheek: Double = 0.5
            var forehead: Double = 0.5
            var chin: Double = 0.5
            leftCheek = sampleLuminance(image: image, center: CGPoint(x: leftEyeCenter.x, y: leftEyeCenter.y - cheekOffset),
                                        radius: max(2.0, irisRadius * 0.9), extent: extent, context: context)
            rightCheek = sampleLuminance(image: image, center: CGPoint(x: rightEyeCenter.x, y: rightEyeCenter.y - cheekOffset),
                                         radius: max(2.0, irisRadius * 0.9), extent: extent, context: context)
            forehead = sampleLuminance(image: image, center: CGPoint(x: leftEyeCenter.x, y: leftEyeCenter.y + cheekOffset * 1.6),
                                       radius: max(2.0, irisRadius * 0.9), extent: extent, context: context)
            chin = sampleLuminance(image: image, center: CGPoint(x: leftEyeCenter.x, y: leftEyeCenter.y - cheekOffset * 2.2),
                                   radius: max(2.0, irisRadius * 0.9), extent: extent, context: context)

            // `leftEye`/`rightEye` are the face's own eyes; for the light
            // direction only the image-space order matters.
            let leftIsImageLeft = leftEyeCenter.x <= rightEyeCenter.x
            let imageLeft = leftIsImageLeft ? leftCheek : rightCheek
            let imageRight = leftIsImageLeft ? rightCheek : leftCheek
            let horizontalDiff = imageRight - imageLeft
            let verticalDiff = forehead - chin
            let lightOffsetX = max(-1.0, min(1.0, horizontalDiff / 0.08))
            let lightOffsetY = max(-1.0, min(1.0, verticalDiff / 0.10))
            let hasDirection = abs(horizontalDiff) > 0.03 || abs(verticalDiff) > 0.04

            return CatchlightAnalysis(
                leftEye: CatchlightAnalysis.Eye(
                    existingHighlight: existingHighlight(around: leftPixel),
                    lightOffsetX: lightOffsetX,
                    lightOffsetY: lightOffsetY,
                    hasDirection: hasDirection),
                rightEye: CatchlightAnalysis.Eye(
                    existingHighlight: existingHighlight(around: rightPixel),
                    lightOffsetX: lightOffsetX,
                    lightOffsetY: lightOffsetY,
                    hasDirection: hasDirection)
            )
        }
    }

    private struct RegionSample {
        var mean: Double
        var peak: Double
        /// Centroid of the pixels above `mean + 0.14`, in image pixels.
        var peakCentroid: CGPoint?
    }

    private static func sampleRegion(image: CIImage, center: CGPoint, radius: CGFloat,
                                     extent: CGRect, context: CIContext) -> RegionSample? {
        let size = max(2, Int(radius * 2))
        guard size <= 512 else { return nil }
        var rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        rect = rect.intersection(CGRect(x: extent.minX, y: extent.minY,
                                        width: extent.width, height: extent.height))
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let width = max(1, Int(rect.width.rounded()))
        let height = max(1, Int(rect.height.rounded()))
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &buffer, rowBytes: width * 4,
                       bounds: rect, format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var total = 0.0
        var luminances = [Double](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let r = Double(buffer[index * 4]) / 255.0
            let g = Double(buffer[index * 4 + 1]) / 255.0
            let b = Double(buffer[index * 4 + 2]) / 255.0
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            luminances[index] = lum
            total += lum
        }
        let mean = total / Double(width * height)
        var peak = 0.0
        var sumX = 0.0
        var sumY = 0.0
        var count = 0
        for index in 0..<(width * height) {
            let lum = luminances[index]
            peak = max(peak, lum)
            if lum > mean + 0.14 {
                let column = index % width
                let row = index / width
                sumX += Double(column)
                sumY += Double(rect.maxY - CGFloat(row) - 0.5)
                count += 1
            }
        }
        guard count > 0 else {
            return RegionSample(mean: mean, peak: peak, peakCentroid: nil)
        }
        return RegionSample(mean: mean, peak: peak,
                            peakCentroid: CGPoint(x: rect.minX + sumX / Double(count),
                                                  y: rect.minY + sumY / Double(count)))
    }

    private static func sampleLuminance(image: CIImage, center: CGPoint, radius: CGFloat,
                                         extent: CGRect, context: CIContext) -> Double {
        sampleRegion(image: image, center: center, radius: radius, extent: extent, context: context)?.mean ?? 0.5
    }

    /// Median luminance of the cheek/forehead skin around every face, in the
    /// same working space the eye kernel samples (extended linear). Used as the
    /// reference that makes a specular glare "bright relative to skin" rather
    /// than "bright in absolute terms" - the difference that made the glare
    /// control work on the 8-bit unit fixture but do nothing on a real photo.
    ///
    /// The samples are taken just outside the eye polygons (cheekbone and mid
    /// forehead) so the sclera and the glare itself cannot bias the reference.
    public static func faceSkinLuminance(image: CIImage, faces: [FaceLandmarkSet],
                                         extent: CGRect, context: CIContext) -> Double {
        var samples: [Double] = []
        for face in faces {
            guard !face.leftEye.isEmpty, !face.rightEye.isEmpty else { continue }
            let box = face.boundingBox
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: extent.minX + x * extent.width,
                        y: extent.minY + y * extent.height)
            }
            // Cheekbones below the eyes and the mid forehead: skin lit by the
            // same light as the eyes but carrying no specular of its own.
            let leftMid = CGPoint(x: face.leftEye.map(\.x).reduce(0, +) / CGFloat(face.leftEye.count),
                                  y: face.leftEye.map(\.y).reduce(0, +) / CGFloat(face.leftEye.count))
            let rightMid = CGPoint(x: face.rightEye.map(\.x).reduce(0, +) / CGFloat(face.rightEye.count),
                                   y: face.rightEye.map(\.y).reduce(0, +) / CGFloat(face.rightEye.count))
            let radius = max(2.0, box.width * extent.width * 0.05)
            let candidates = [
                point(leftMid.x, leftMid.y - box.height * 0.16),
                point(rightMid.x, rightMid.y - box.height * 0.16),
                point(box.midX, box.maxY - box.height * 0.10)
            ]
            for center in candidates {
                if let value = linearMeanLuminance(image: image, center: center,
                                                   radius: radius, extent: extent,
                                                   context: context) {
                    samples.append(value)
                }
            }
        }
        guard !samples.isEmpty else { return 0.18 }
        samples.sort()
        return samples[samples.count / 2]
    }

    /// True when the matte actually covers something. `maskSet` can be present
    /// and still be entirely empty (a closed mouth has no teeth pixels), and the
    /// report must not claim a step ran in that case.
    static func hasCoverage(_ mask: CIImage?, extent: CGRect) -> Bool {
        guard let mask else { return false }
        guard let reduced = CIFilter(name: "CIAreaMaximum", parameters: [
            kCIInputImageKey: mask,
            kCIInputExtentKey: CIVector(cgRect: extent)
        ])?.outputImage else { return false }
        var buffer = [Float](repeating: 0, count: 4)
        buffer.withUnsafeMutableBytes { pointer in
            catchlightAnalysisContext.render(reduced, toBitmap: pointer.baseAddress!,
                                             rowBytes: 16,
                                             bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                             format: .RGBAf,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return buffer[0] > 0.05
    }

    /// Mean luminance of a square patch rendered in extended-linear sRGB, i.e.
    /// the space the refinement kernels themselves sample.
    private static func linearMeanLuminance(image: CIImage, center: CGPoint,
                                            radius: CGFloat, extent: CGRect,
                                            context: CIContext) -> Double? {
        var rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        rect = rect.intersection(extent)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let width = max(1, Int(rect.width.rounded()))
        let height = max(1, Int(rect.height.rounded()))
        var buffer = [Float](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { pointer in
            context.render(image, toBitmap: pointer.baseAddress!, rowBytes: width * 16,
                           bounds: rect, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        var total = 0.0
        for index in 0..<(width * height) {
            total += 0.2126 * Double(buffer[index * 4])
                + 0.7152 * Double(buffer[index * 4 + 1])
                + 0.0722 * Double(buffer[index * 4 + 2])
        }
        return total / Double(width * height)
    }

    /// Mean luminance of the pixels the iris matte actually covers, in the
    /// extended-linear space the kernels sample.
    ///
    /// R4 (2026-11-14): the iris-clarity pass used to centre its contrast on an
    /// absolute `vec3(0.35)`. Real irises sit at 0.017-0.028 there, so every
    /// iris pixel was below the pivot and the pass only darkened the eye. The
    /// pivot has to come from the photo.
    static func irisMeanLuminance(image: CIImage, mask: CIImage?,
                                  extent: CGRect, context: CIContext) -> Double? {
        guard let mask else { return nil }
        // Render the photo and the matte at a reduced resolution: the iris is
        // small, so 256 along the long edge keeps the disc well resolved while
        // staying cheap.
        let longest = max(extent.width, extent.height)
        guard longest > 1 else { return nil }
        let scale = min(1, 256 / longest)
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        func rescaled(_ ci: CIImage) -> CIImage {
            ci.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width,
                                                   y: CGFloat(height) / extent.height))
        }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { pointer in
            context.render(rescaled(image), toBitmap: pointer.baseAddress!,
                           rowBytes: width * 16, bounds: bounds, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        var coverage = [Float](repeating: 0, count: width * height * 4)
        coverage.withUnsafeMutableBytes { pointer in
            context.render(rescaled(mask), toBitmap: pointer.baseAddress!,
                           rowBytes: width * 16, bounds: bounds, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        var total = 0.0, weight = 0.0
        for index in 0..<(width * height) {
            let cover = Double(coverage[index * 4])
            guard cover > 0.2 else { continue }
            let luminance = 0.2126 * Double(pixels[index * 4])
                + 0.7152 * Double(pixels[index * 4 + 1])
                + 0.0722 * Double(pixels[index * 4 + 2])
            total += luminance * cover
            weight += cover
        }
        guard weight > 0 else { return nil }
        return total / weight
    }

    /// Builds the catchlight overlay for `faces`.
    ///
    /// `analysis` is the result of `analyzeCatchlight`. When it is supplied, an
    /// eye that already carries a specular is enhanced in place and an eye with
    /// no measurable light direction is left alone; when it is `nil` (legacy
    /// callers and unit fixtures), the highlight is placed at the pupil's
    /// upper-outer quadrant as before.
    public static func makeCatchlightOverlay(
        faces: [FaceLandmarkSet],
        pattern: EyeCatchlightPattern,
        scale: Double,
        extent: CGRect,
        analysis: [CatchlightAnalysis]? = nil
    ) -> CIImage? {
        guard pattern != .off else { return nil }
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))

        for (index, face) in faces.enumerated() {
            let leftCenter = face.leftPupil ?? polygonCenter(face.leftEye)
            let rightCenter = face.rightPupil ?? polygonCenter(face.rightEye)
            let baseRadius = estimateIrisRadius(face: face, extent: extent)
            let clRadius = baseRadius * 0.45 * CGFloat(scale)
            let faceAnalysis = analysis.flatMap { index < $0.count ? $0[index] : nil }

            /// R3: the highlight either lands on the specular spot the photo
            /// already has (enhancing it in place, never doubling it), or it
            /// follows the photo's own light direction. With no discernible
            /// light direction and no existing highlight, nothing is drawn at
            /// all — a catchlight must never be invented out of nothing.
            func drawEye(center: CGPoint?, eye: CatchlightAnalysis.Eye?) {
                guard let center else { return }
                let px = center.x * extent.width
                let py = center.y * extent.height
                if let existing = eye?.existingHighlight {
                    drawCatchlightPattern(pattern, at: existing, radius: clRadius, in: ctx)
                    return
                }
                guard let eye, eye.hasDirection else { return }
                let offsetX = clRadius * 0.35 * CGFloat(eye.lightOffsetX)
                let offsetY = clRadius * 0.35 * CGFloat(eye.lightOffsetY)
                drawCatchlightPattern(pattern, at: CGPoint(x: px + offsetX, y: py + offsetY),
                                      radius: clRadius, in: ctx)
            }

            drawEye(center: leftCenter, eye: faceAnalysis?.leftEye)
            drawEye(center: rightCenter, eye: faceAnalysis?.rightEye)
        }

        guard let cgImg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cgImg)
    }

    // MARK: - Pattern Drawing

    private static func drawCatchlightPattern(
        _ pattern: EyeCatchlightPattern,
        at center: CGPoint,
        radius: CGFloat,
        in ctx: CGContext
    ) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.95)
        ctx.setStrokeColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.95)

        switch pattern {
        case .off:
            break

        case .naturalPoint:
            // Crisp natural circular point light
            ctx.fillEllipse(in: CGRect(x: center.x - radius * 0.55, y: center.y - radius * 0.55,
                                       width: radius * 1.1, height: radius * 1.1))

        case .ringLight:
            // Beauty ring light: bright annulus
            ctx.setLineWidth(max(1.5, radius * 0.35))
            ctx.strokeEllipse(in: CGRect(x: center.x - radius * 0.70, y: center.y - radius * 0.70,
                                         width: radius * 1.4, height: radius * 1.4))

        case .softboxSquare:
            // Studio square softbox
            let rect = CGRect(x: center.x - radius * 0.60, y: center.y - radius * 0.60,
                              width: radius * 1.2, height: radius * 1.2)
            let path = CGPath(roundedRect: rect, cornerWidth: radius * 0.20, cornerHeight: radius * 0.20, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()

        case .dualStrip:
            // Dual side strip softboxes
            let stripWidth = max(1.5, radius * 0.28)
            let stripHeight = radius * 1.3
            // Left strip
            let r1 = CGRect(x: center.x - radius * 0.65, y: center.y - stripHeight * 0.5,
                            width: stripWidth, height: stripHeight)
            let p1 = CGPath(roundedRect: r1, cornerWidth: stripWidth * 0.4, cornerHeight: stripWidth * 0.4, transform: nil)
            ctx.addPath(p1)
            ctx.fillPath()
            // Right strip
            let r2 = CGRect(x: center.x + radius * 0.65 - stripWidth, y: center.y - stripHeight * 0.5,
                            width: stripWidth, height: stripHeight)
            let p2 = CGPath(roundedRect: r2, cornerWidth: stripWidth * 0.4, cornerHeight: stripWidth * 0.4, transform: nil)
            ctx.addPath(p2)
            ctx.fillPath()

        case .butterfly:
            // Paramount overhead butterfly light: horizontal rounded crescent
            let r = CGRect(x: center.x - radius * 0.75, y: center.y - radius * 0.25,
                           width: radius * 1.5, height: radius * 0.65)
            let path = CGPath(roundedRect: r, cornerWidth: radius * 0.25, cornerHeight: radius * 0.25, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()

        case .starburst:
            // Sparkling starburst: 4-pointed diamond glint
            let coreR = radius * 0.35
            ctx.fillEllipse(in: CGRect(x: center.x - coreR, y: center.y - coreR, width: coreR * 2, height: coreR * 2))
            // Cross spikes
            let path = CGMutablePath()
            let span = radius * 1.3
            let width = radius * 0.18
            // Horizontal flare
            path.move(to: CGPoint(x: center.x - span, y: center.y))
            path.addLine(to: CGPoint(x: center.x, y: center.y + width))
            path.addLine(to: CGPoint(x: center.x + span, y: center.y))
            path.addLine(to: CGPoint(x: center.x, y: center.y - width))
            path.closeSubpath()
            // Vertical flare
            path.move(to: CGPoint(x: center.x, y: center.y - span))
            path.addLine(to: CGPoint(x: center.x + width, y: center.y))
            path.addLine(to: CGPoint(x: center.x, y: center.y + span))
            path.addLine(to: CGPoint(x: center.x - width, y: center.y))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        }
    }

    // MARK: - Geometry Helpers

    private static func drawPolygon(_ points: [CGPoint], in ctx: CGContext, extent: CGRect) {
        guard points.count >= 3 else { return }
        ctx.beginPath()
        let p0 = points[0]
        ctx.move(to: CGPoint(x: p0.x * extent.width, y: p0.y * extent.height))
        for i in 1..<points.count {
            let p = points[i]
            ctx.addLine(to: CGPoint(x: p.x * extent.width, y: p.y * extent.height))
        }
        ctx.closePath()
        ctx.fillPath()
    }

    private static func polygonCenter(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for p in points {
            sumX += p.x
            sumY += p.y
        }
        return CGPoint(x: sumX / CGFloat(points.count), y: sumY / CGFloat(points.count))
    }

    private static func polygonBounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: max(0.001, maxX - minX), height: max(0.001, maxY - minY))
    }

    private static func estimateIrisRadius(face: FaceLandmarkSet, extent: CGRect) -> CGFloat {
        if !face.leftEye.isEmpty {
            let b = polygonBounds(face.leftEye)
            return max(3.0, (b.width * extent.width) * 0.22)
        } else if !face.rightEye.isEmpty {
            let b = polygonBounds(face.rightEye)
            return max(3.0, (b.width * extent.width) * 0.22)
        }
        return max(4.0, (face.boundingBox.width * extent.width) * 0.05)
    }

    private static func makeBlackMask(extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
    }
}

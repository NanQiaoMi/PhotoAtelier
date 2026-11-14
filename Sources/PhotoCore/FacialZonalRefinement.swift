import Foundation
import CoreImage
import CoreGraphics

/// P2-H: Smart facial zonal wrinkle smoothing & anti-shine matte finish.
///
/// Features:
/// 1. `darkCircles`: Lifts under-eye darkness and neutralizes purplish/bluish pooling.
/// 2. `eyeBags`: Smooths under-eye puffiness and curvilinear shadow troughs along the orbital rim.
/// 3. `nasolabialFolds`: Softens smile line shadow furrows between nose wings and mouth corners.
/// 4. `foreheadWrinkles`: Smooths horizontal forehead creases and inter-eyebrow vertical glabellar frown lines.
/// 5. `antiShine`: Compresses blown-out specular grease hotspots on T-zone toward diffuse skin with a velvety matte finish.
/// 6. `jawlineSculpting`: Softens submental shadow crease under chin to define clean mandibular contour.
/// 7. `texturePreservation`: Re-injects high-frequency micro-pores to prevent waxy/plastic look.
///
/// 100% offline, zero external model dependencies, GPU-accelerated with Core Image kernel.
public enum FacialZonalRefinementEngine {

    private static let kernelSource = """
    kernel vec4 facialZonalKernel(
        sampler src,
        sampler mid,
        sampler fine,
        sampler drape,
        sampler eyeBagsMask,
        sampler darkCirclesMask,
        sampler nasolabialMask,
        sampler foreheadMask,
        sampler jawlineMask,
        sampler antiShineMask,
        vec4 strengths1,
        vec4 strengths2,
        vec4 faceAnchor
    ) {
        vec4 c = sample(src, samplerCoord(src));
        vec4 m = sample(mid, samplerCoord(mid));
        vec4 f = sample(fine, samplerCoord(fine));
        vec4 d = sample(drape, samplerCoord(drape));

        // R3 (2026-11-14, "针对人的处理特别差" review): the kernel used to build
        // its result on top of the blurred `mid` band (`vec3 current = m.rgb`)
        // and re-inject only `texturePreservation` of the high-frequency detail.
        // That softened the *whole photograph* - hair, clothes and background
        // included - by roughly 30% and left the skin waxy and plastic, which
        // is why every pipeline that enabled this engine looked "processed".
        // The result now starts from the untouched source pixels and every
        // correction stays inside the zonal masks.
        vec3 current = c.rgb;

        // R3 (2026-11-14): the crease detector used `drape - mid` for *every*
        // zone, i.e. the difference between a very wide blur and a medium one.
        // That measures *broad brightness*, not a crease: on any face with a
        // lit side and a shadow side it fired across whole regions and lifted
        // the shadow side, flattening the light modelling and leaving a grey,
        // washed-out face (the "灰脸" artifact).
        //
        // Two detectors are used instead, each for the structure its zone is
        // actually about:
        //
        // * `creaseDelta` (narrow line): the medium blur is pulled down by a
        //   thin dark line more than the fine blur, so `mid - fine` is
        //   positive exactly on wrinkles and folds and ~0 on broad lighting
        //   gradients. This drives the wrinkle zones.
        // * `broadDelta` (broad shadow): the under-eye trough and the dark
        //   circle are wide shadow pools, not lines. `drape - mid` is the
        //   right measure for them, and because it now only ever fires inside
        //   the under-eye masks it can no longer flatten the whole face.
        vec3 creaseDelta = min(vec3(0.10), max(vec3(0.0), (m.rgb - f.rgb) * 2.0));
        vec3 broadDelta = min(vec3(0.18), max(vec3(0.0), (d.rgb - m.rgb) * 1.9));

        // Smoothed zone tone. `texturePreservation` decides how much of the
        // micro-texture survives the smoothing: 1.0 -> pores preserved, 0.0 ->
        // the zone is flattened to the medium blur. The narrow crease lift is
        // applied separately, outside this blend, because a wrinkle has to be
        // removed whether or not the pores around it are kept.
        vec3 zoneTone = mix(m.rgb, c.rgb, clamp(strengths2.z, 0.0, 1.0));

        // 1. Eye bags lifting (broad trough shadow + gentle smoothing)
        float mEB = sample(eyeBagsMask, samplerCoord(eyeBagsMask)).r;
        float wEB = clamp(strengths1.x * mEB * 0.95, 0.0, 1.0);
        current = mix(current, zoneTone, wEB * 0.70);
        current += broadDelta * wEB * 1.00;
        current += creaseDelta * wEB;

        // 2. Dark circles neutralization & lifting
        float mDC = sample(darkCirclesMask, samplerCoord(darkCirclesMask)).r;
        float wDC = clamp(strengths1.y * mDC * 0.90, 0.0, 1.0);
        if (wDC > 0.0) {
            current = mix(current, zoneTone, wDC * 0.60);
            current += broadDelta * wDC * 0.70;
            current += creaseDelta * wDC;
            // Neutralize the bluish/purplish pooling toward the local skin tone,
            // nudged by the sampled cheek anchor. The old code mixed toward a
            // 5%-of-face-height blur, which smeared a grey veil under the eyes.
            vec3 targetWarmth = mix(m.rgb, faceAnchor.rgb, 0.60);
            current = mix(current, targetWarmth, wDC * 0.55);
        }

        // 3. Nasolabial folds lifting
        float mNL = sample(nasolabialMask, samplerCoord(nasolabialMask)).r;
        float wNL = clamp(strengths1.z * mNL * 0.95, 0.0, 1.0);
        current = mix(current, zoneTone, wNL * 0.85);
        // A wrinkle is removed whether or not the pores around it are kept, so
        // the crease lift is applied outside the texture-preservation blend.
        current += creaseDelta * wNL;

        // 4. Forehead wrinkles & frown lines lifting
        float mFH = sample(foreheadMask, samplerCoord(foreheadMask)).r;
        float wFH = clamp(strengths1.w * mFH * 0.95, 0.0, 1.0);
        current = mix(current, zoneTone, wFH * 0.85);
        // A wrinkle is removed whether or not the pores around it are kept, so
        // the crease lift is applied outside the texture-preservation blend.
        current += creaseDelta * wFH;

        // 5. Jawline & double chin submental crease
        float mJL = sample(jawlineMask, samplerCoord(jawlineMask)).r;
        float wJL = clamp(strengths2.y * mJL * 0.90, 0.0, 1.0);
        current = mix(current, zoneTone, wJL * 0.85);
        // A wrinkle is removed whether or not the pores around it are kept, so
        // the crease lift is applied outside the texture-preservation blend.
        current += creaseDelta * wJL;

        // 6. Anti-shine specular compression (R3: compress the luminance only;
        // mixing toward a wide blur destroyed skin texture and left a milky
        // veil over the face).
        float mAS = sample(antiShineMask, samplerCoord(antiShineMask)).r;
        float sAS = strengths2.x;
        float shineWeight = 0.0;
        if (sAS > 0.0 && mAS > 0.0) {
            vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
            float lum = dot(c.rgb, LUMA);
            float diffuseLum = dot(d.rgb, LUMA);
            float cMax = max(c.r, max(c.g, c.b));
            float cMin = min(c.r, min(c.g, c.b));
            float chroma = cMax - cMin;

            // R3 (2026-11-14): the gate used to be `lum > 0.70`, i.e. an ABSOLUTE
            // luminance threshold. The engine runs in extended-linear-sRGB, where
            // real skin sits around 0.05-0.30 and even a hard specular rarely
            // passes 0.65 - so on every real photograph the anti-shine pass was a
            // silent no-op (measured: max delta 0.0028 across a portrait face).
            //
            // Both tests are now relative to the photo, so they mean the same
            // thing in any working colour space:
            //   * `peakRatio` - the pixel is brighter than the diffuse skin
            //     around it (the wide `drape` average). A grease hotspot is a
            //     local spike; ordinary lit skin is not.
            //   * `whiteness` - the pixel is LESS saturated than its own
            //     brightness implies. Skin keeps its hue as it brightens; a
            //     specular reflection washes out toward white.
            float peakRatio = diffuseLum > 0.0001 ? lum / diffuseLum : 1.0;
            float whiteness = lum > 0.0001 ? chroma / lum : 0.0;
            float isShine = smoothstep(1.12, 1.55, peakRatio) * smoothstep(0.62, 0.28, whiteness) * mAS;
            shineWeight = clamp(sAS * isShine * 0.90, 0.0, 1.0);
            if (shineWeight > 0.0) {
                // Compress the specular excess (not the pixel itself) so the
                // sharp highlight flattens while the skin's own micro-texture
                // and hue survive.
                float targetLum = diffuseLum + (lum - diffuseLum) * 0.35;
                float scale = lum > 0.00001 ? targetLum / lum : 1.0;
                current = current * mix(1.0, scale, shineWeight);
            }
        }

        // R3: the source pixels are the base, so no global texture re-injection
        // is needed any more - the zone masks keep every pixel outside them
        // bit-identical to the input.
        //
        // R3 (2026-11-14, second pass): the kernel used to return
        // `clamp(current, 0.0, 1.0)` for EVERY pixel of the image. The engine
        // works in extended-linear-sRGB, where a specular highlight legitimately
        // exceeds 1.0 (a real portrait measured 1.22 on a backlit rim), so
        // enabling any zonal slider silently clipped every highlight in the
        // photograph - including background, hair and clothes far from the face.
        // Untouched pixels now pass through unchanged; the clamp only applies
        // where a zone mask actually drives a correction.
        float zoneWeight = max(max(max(wEB, wDC), max(wNL, wFH)), max(wJL, shineWeight));
        if (zoneWeight <= 0.00001) { return c; }
        return vec4(clamp(current, 0.0, 1.0), c.a);
    }
    """

    private static let colorKernel: CIColorKernel? = {
        return CIColorKernel(source: kernelSource)
    }()

    /// Applies smart facial zonal wrinkle smoothing and anti-shine matte finish.
    public static func apply(
        _ image: CIImage,
        settings: FacialZonalRefinementSettings,
        faceLandmarks: [FaceLandmarkSet]?,
        context: CIContext? = nil,
        cancellation: CancellationToken? = nil
    ) throws -> (image: CIImage, report: FacialZonalRefinementReport) {
        let validated = try settings.validated()
        if validated.isNeutral {
            return (image, FacialZonalRefinementReport(applied: false, appliedSteps: [], note: "面部五区精修处于中性状态（未修改像素）。"))
        }

        guard let faces = faceLandmarks, !faces.isEmpty else {
            return (image, FacialZonalRefinementReport(applied: false, appliedSteps: [], note: "未检测到可用人脸，跳过面部五区精修。"))
        }

        try cancellation?.check()

        let extent = image.extent
        let shorterEdge = Double(min(extent.width, extent.height))

        // Find primary face size for adaptive frequency blur radii
        let primaryFace = faces.max(by: { a, b in
            let areaA = a.boundingBox.width * a.boundingBox.height
            let areaB = b.boundingBox.width * b.boundingBox.height
            return areaA < areaB
        }) ?? faces[0]
        let facePixelH = Double(primaryFace.boundingBox.height * extent.height)

        let sigmaDrape = max(8.0, facePixelH * 0.050)
        let sigmaMid = max(2.0, facePixelH * 0.012)
        // R3: a fine band below `mid`. `mid - fine` isolates narrow dark
        // structures (wrinkles, folds, lash lines) without reacting to broad
        // lighting gradients; `drape - mid` isolates broad shadow pools (the
        // under-eye trough, dark circles) and is only used inside those masks.
        let sigmaFine = max(0.8, facePixelH * 0.0035)

        let drape = image.clampedToExtent().applyingGaussianBlur(sigma: sigmaDrape).cropped(to: extent)
        let mid = image.clampedToExtent().applyingGaussianBlur(sigma: sigmaMid).cropped(to: extent)
        let fine = image.clampedToExtent().applyingGaussianBlur(sigma: sigmaFine).cropped(to: extent)

        try cancellation?.check()

        // Sample healthy diffuse skin anchor
        let anchorVector = sampleFaceAnchor(image: image, faces: faces, context: context)

        // Generate zonal masks
        let eyeBagsMask = validated.eyeBags > 0
            ? makeEyeBagsMask(faces: faces, extent: extent, shorterEdge: shorterEdge)
            : makeBlackMask(extent: extent)

        let darkCirclesMask = validated.darkCircles > 0
            ? makeDarkCirclesMask(faces: faces, extent: extent, shorterEdge: shorterEdge)
            : makeBlackMask(extent: extent)

        let nasolabialMask = validated.nasolabialFolds > 0
            ? makeNasolabialMask(faces: faces, extent: extent, shorterEdge: shorterEdge)
            : makeBlackMask(extent: extent)

        let foreheadMask = validated.foreheadWrinkles > 0
            ? makeForeheadMask(faces: faces, extent: extent, shorterEdge: shorterEdge)
            : makeBlackMask(extent: extent)

        let jawlineMask = validated.jawlineSculpting > 0
            ? makeJawlineMask(faces: faces, extent: extent, shorterEdge: shorterEdge)
            : makeBlackMask(extent: extent)

        let antiShineMask = validated.antiShine > 0
            ? makeAntiShineMask(faces: faces, extent: extent, shorterEdge: shorterEdge)
            : makeBlackMask(extent: extent)

        try cancellation?.check()

        guard let kernel = colorKernel else {
            return (image, FacialZonalRefinementReport(applied: false, appliedSteps: [], note: "Core Image Kernel 初始化失败。"))
        }

        let strengths1 = CIVector(x: validated.eyeBags,
                                  y: validated.darkCircles,
                                  z: validated.nasolabialFolds,
                                  w: validated.foreheadWrinkles)
        let strengths2 = CIVector(x: validated.antiShine,
                                  y: validated.jawlineSculpting,
                                  z: validated.texturePreservation,
                                  w: 0.0)

        let processed = kernel.apply(
            extent: extent,
            arguments: [
                image,
                mid,
                fine,
                drape,
                eyeBagsMask,
                darkCirclesMask,
                nasolabialMask,
                foreheadMask,
                jawlineMask,
                antiShineMask,
                strengths1,
                strengths2,
                anchorVector
            ]
        ) ?? image

        var steps: [String] = []
        if validated.eyeBags > 0 { steps.append("eyeBags") }
        if validated.darkCircles > 0 { steps.append("darkCircles") }
        if validated.nasolabialFolds > 0 { steps.append("nasolabialFolds") }
        if validated.foreheadWrinkles > 0 { steps.append("foreheadWrinkles") }
        if validated.antiShine > 0 { steps.append("antiShine") }
        if validated.jawlineSculpting > 0 { steps.append("jawlineSculpting") }

        let report = FacialZonalRefinementReport(
            applied: !steps.isEmpty,
            appliedSteps: steps,
            note: "已应用面部五区专项精修：\(steps.joined(separator: ", "))。"
        )

        return (processed, report)
    }

    private static func makeBlackMask(extent: CGRect) -> CIImage {
        return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
    }

    private static func sampleFaceAnchor(image: CIImage, faces: [FaceLandmarkSet], context: CIContext?) -> CIVector {
        guard let primaryFace = faces.first, let ctx = context else {
            return CIVector(x: 0.75, y: 0.58, z: 0.50, w: 1.0)
        }
        let extent = image.extent
        let bbox = primaryFace.boundingBox
        let faceX = bbox.origin.x * extent.width
        let faceY = bbox.origin.y * extent.height
        let faceW = bbox.width * extent.width
        let faceH = bbox.height * extent.height

        // R3 (2026-11-14): the anchor used to be a fixed 4x4 px at 28%/45% of
        // the face box. On a tilted or off-centre head that point can sit on
        // hair, an eye or the background, and the under-eye "neutralization"
        // then painted that wrong colour onto the face (a grey patch under the
        // eyes). The anchor is now sampled from the cheek, derived from the
        // eye and mouth landmarks, and averaged over both cheeks.
        var samplePoints: [CGPoint] = []
        let eyeCenters: [CGPoint] = [primaryFace.leftEye, primaryFace.rightEye]
            .filter { $0.count >= 3 }
            .map { points in
                let xs = points.map { $0.x * extent.width }
                let ys = points.map { $0.y * extent.height }
                let cx = ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2
                let cy = ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2
                return CGPoint(x: cx, y: cy)
            }
        var lipCenter: CGPoint?
        if primaryFace.outerLips.count >= 3 {
            let xs = primaryFace.outerLips.map { $0.x * extent.width }
            let ys = primaryFace.outerLips.map { $0.y * extent.height }
            lipCenter = CGPoint(x: ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2,
                                y: ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2)
        }
        if let lipCenter {
            for eyeCenter in eyeCenters {
                // Cheek point: 55% of the way from the eye down to the mouth
                // corner line, nudged toward the face centre so it stays on
                // the cheek rather than the nasolabial edge.
                let base = CGPoint(x: eyeCenter.x + (lipCenter.x - eyeCenter.x) * 0.55,
                                   y: eyeCenter.y + (lipCenter.y - eyeCenter.y) * 0.55)
                let towardCenter = (faceX + faceW * 0.5) - base.x
                samplePoints.append(CGPoint(x: base.x + towardCenter * 0.18, y: base.y))
            }
        }
        if samplePoints.isEmpty {
            // Legacy fallback: fixed proportion of the face box.
            samplePoints = [CGPoint(x: faceX + faceW * 0.28, y: faceY + faceH * 0.45)]
        }

        let sampleSize = max(4.0, min(12.0, faceW * 0.02))
        var samples: [(Double, Double, Double)] = []
        for point in samplePoints {
            let sampleRect = CGRect(x: point.x - sampleSize * 0.5, y: point.y - sampleSize * 0.5,
                                    width: sampleSize, height: sampleSize)
                .intersection(extent)
            guard sampleRect.width >= 1, sampleRect.height >= 1 else { continue }
            let avgFilter = image.cropped(to: sampleRect).applyingFilter("CIAreaAverage")
            var bitmap = [UInt8](repeating: 0, count: 4)
            ctx.render(avgFilter, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            samples.append((Double(bitmap[0]) / 255.0, Double(bitmap[1]) / 255.0, Double(bitmap[2]) / 255.0))
        }
        guard !samples.isEmpty else {
            return CIVector(x: 0.75, y: 0.58, z: 0.50, w: 1.0)
        }
        let r = samples.reduce(0.0) { $0 + $1.0 } / Double(samples.count)
        let g = samples.reduce(0.0) { $0 + $1.1 } / Double(samples.count)
        let b = samples.reduce(0.0) { $0 + $1.2 } / Double(samples.count)
        return CIVector(x: r, y: g, z: b, w: 1.0)
    }

    private static func makeEyeBagsMask(faces: [FaceLandmarkSet], extent: CGRect, shorterEdge: Double) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return makeBlackMask(extent: extent)
        }
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1.0, alpha: 1.0)

        for face in faces {
            // R3 (2026-11-14): Vision's own face box stops at the brows on many
            // portraits, so every proportion below was measured from a box that
            // never contained the forehead. `skinOvalBox` is the closed face
            // outline (jaw arc + forehead cap) and is the box these zones are
            // actually laid out in.
            let bbox = face.skinOvalBox
            let faceX = bbox.origin.x * extent.width
            let faceY = bbox.origin.y * extent.height
            let faceW = bbox.width * extent.width
            let faceH = bbox.height * extent.height

            // Left eye bag
            if face.leftEye.count >= 4 {
                let xs = face.leftEye.map { $0.x * extent.width }
                let ys = face.leftEye.map { $0.y * extent.height }
                let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
                let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
                let eyeW = max(1.0, maxX - minX), eyeH = max(1.0, maxY - minY)
                let bagRect = CGRect(x: minX - eyeW * 0.10, y: minY - eyeH * 0.75, width: eyeW * 1.20, height: eyeH * 0.80)
                ctx.fillEllipse(in: bagRect)
            } else {
                let bagRect = CGRect(x: faceX + faceW * 0.18, y: faceY + faceH * 0.48, width: faceW * 0.28, height: faceH * 0.10)
                ctx.fillEllipse(in: bagRect)
            }

            // Right eye bag
            if face.rightEye.count >= 4 {
                let xs = face.rightEye.map { $0.x * extent.width }
                let ys = face.rightEye.map { $0.y * extent.height }
                let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
                let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
                let eyeW = max(1.0, maxX - minX), eyeH = max(1.0, maxY - minY)
                let bagRect = CGRect(x: minX - eyeW * 0.10, y: minY - eyeH * 0.75, width: eyeW * 1.20, height: eyeH * 0.80)
                ctx.fillEllipse(in: bagRect)
            } else {
                let bagRect = CGRect(x: faceX + faceW * 0.54, y: faceY + faceH * 0.48, width: faceW * 0.28, height: faceH * 0.10)
                ctx.fillEllipse(in: bagRect)
            }
        }

        guard let cgImg = ctx.makeImage() else { return makeBlackMask(extent: extent) }
        let blurRadius = max(2.0, shorterEdge * 0.012)
        return CIImage(cgImage: cgImg).clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }

    private static func makeDarkCirclesMask(faces: [FaceLandmarkSet], extent: CGRect, shorterEdge: Double) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return makeBlackMask(extent: extent)
        }
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1.0, alpha: 1.0)

        for face in faces {
            // R3 (2026-11-14): Vision's own face box stops at the brows on many
            // portraits, so every proportion below was measured from a box that
            // never contained the forehead. `skinOvalBox` is the closed face
            // outline (jaw arc + forehead cap) and is the box these zones are
            // actually laid out in.
            let bbox = face.skinOvalBox
            let faceX = bbox.origin.x * extent.width
            let faceY = bbox.origin.y * extent.height
            let faceW = bbox.width * extent.width
            let faceH = bbox.height * extent.height

            // Left dark circle
            if face.leftEye.count >= 4 {
                let xs = face.leftEye.map { $0.x * extent.width }
                let ys = face.leftEye.map { $0.y * extent.height }
                let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
                let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
                let eyeW = max(1.0, maxX - minX), eyeH = max(1.0, maxY - minY)
                let dcRect = CGRect(x: minX - eyeW * 0.15, y: minY - eyeH * 0.90, width: eyeW * 1.30, height: eyeH * 0.95)
                ctx.fillEllipse(in: dcRect)
            } else {
                let dcRect = CGRect(x: faceX + faceW * 0.16, y: faceY + faceH * 0.46, width: faceW * 0.32, height: faceH * 0.14)
                ctx.fillEllipse(in: dcRect)
            }

            // Right dark circle
            if face.rightEye.count >= 4 {
                let xs = face.rightEye.map { $0.x * extent.width }
                let ys = face.rightEye.map { $0.y * extent.height }
                let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
                let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
                let eyeW = max(1.0, maxX - minX), eyeH = max(1.0, maxY - minY)
                let dcRect = CGRect(x: minX - eyeW * 0.15, y: minY - eyeH * 0.90, width: eyeW * 1.30, height: eyeH * 0.95)
                ctx.fillEllipse(in: dcRect)
            } else {
                let dcRect = CGRect(x: faceX + faceW * 0.52, y: faceY + faceH * 0.46, width: faceW * 0.32, height: faceH * 0.14)
                ctx.fillEllipse(in: dcRect)
            }
        }

        guard let cgImg = ctx.makeImage() else { return makeBlackMask(extent: extent) }
        let blurRadius = max(2.5, shorterEdge * 0.015)
        return CIImage(cgImage: cgImg).clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }

    private static func makeNasolabialMask(faces: [FaceLandmarkSet], extent: CGRect, shorterEdge: Double) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return makeBlackMask(extent: extent)
        }
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setStrokeColor(gray: 1.0, alpha: 1.0)

        for face in faces {
            // R3 (2026-11-14): Vision's own face box stops at the brows on many
            // portraits, so every proportion below was measured from a box that
            // never contained the forehead. `skinOvalBox` is the closed face
            // outline (jaw arc + forehead cap) and is the box these zones are
            // actually laid out in.
            let bbox = face.skinOvalBox
            let faceX = bbox.origin.x * extent.width
            let faceY = bbox.origin.y * extent.height
            let faceW = bbox.width * extent.width
            let faceH = bbox.height * extent.height

            ctx.setLineWidth(max(3.0, faceW * 0.07))
            ctx.setLineCap(.round)

            // R3 (2026-11-14): the folds are anchored to the actual nose wings
            // and mouth corners instead of fixed fractions of the face box. A
            // tilted or off-centre head put the old template on the cheek and
            // the temple, so the "fold" pass smeared unrelated skin.
            if let noseAlarLeft = face.nose.min(by: { $0.x < $1.x }),
               let noseAlarRight = face.nose.max(by: { $0.x < $1.x }),
               let lipLeft = face.outerLips.min(by: { $0.x < $1.x }),
               let lipRight = face.outerLips.max(by: { $0.x < $1.x }),
               face.nose.count >= 2, face.outerLips.count >= 2 {
                // Left fold: nose wing → mouth corner
                let pL1 = CGPoint(x: noseAlarLeft.x * extent.width, y: noseAlarLeft.y * extent.height)
                let pL2 = CGPoint(x: lipLeft.x * extent.width, y: lipLeft.y * extent.height)
                ctx.strokeLineSegments(between: [pL1, pL2])
                // Right fold
                let pR1 = CGPoint(x: noseAlarRight.x * extent.width, y: noseAlarRight.y * extent.height)
                let pR2 = CGPoint(x: lipRight.x * extent.width, y: lipRight.y * extent.height)
                ctx.strokeLineSegments(between: [pR1, pR2])
            } else {
                // Fallback: legacy proportions (only when landmarks are absent)
                let pL1 = CGPoint(x: faceX + faceW * 0.36, y: faceY + faceH * 0.45)
                let pL2 = CGPoint(x: faceX + faceW * 0.30, y: faceY + faceH * 0.30)
                ctx.strokeLineSegments(between: [pL1, pL2])
                let pR1 = CGPoint(x: faceX + faceW * 0.64, y: faceY + faceH * 0.45)
                let pR2 = CGPoint(x: faceX + faceW * 0.70, y: faceY + faceH * 0.30)
                ctx.strokeLineSegments(between: [pR1, pR2])
            }
        }

        guard let cgImg = ctx.makeImage() else { return makeBlackMask(extent: extent) }
        let blurRadius = max(3.0, shorterEdge * 0.016)
        return CIImage(cgImage: cgImg).clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }

    private static func makeForeheadMask(faces: [FaceLandmarkSet], extent: CGRect, shorterEdge: Double) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return makeBlackMask(extent: extent)
        }
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1.0, alpha: 1.0)

        for face in faces {
            // R3 (2026-11-14): Vision's own face box stops at the brows on many
            // portraits, so every proportion below was measured from a box that
            // never contained the forehead. `skinOvalBox` is the closed face
            // outline (jaw arc + forehead cap) and is the box these zones are
            // actually laid out in.
            let bbox = face.skinOvalBox
            let faceX = bbox.origin.x * extent.width
            let faceY = bbox.origin.y * extent.height
            let faceW = bbox.width * extent.width
            let faceH = bbox.height * extent.height

            // Horizontal forehead wrinkles corridor
            // R3 (2026-11-14): anchored to the brows when available so the
            // corridor follows a tilted head instead of the face box.
            let browPoints = face.leftEyebrow + face.rightEyebrow
            if browPoints.count >= 4 {
                let browYs = browPoints.map { $0.y * extent.height }
                let browXs = browPoints.map { $0.x * extent.width }
                let browTop = browYs.max() ?? (faceY + faceH * 0.70)
                let browBottom = browYs.min() ?? browTop
                let browLeft = browXs.min() ?? faceX
                let browRight = browXs.max() ?? (faceX + faceW)
                let corridor = CGRect(x: browLeft - faceW * 0.04,
                                      y: browTop + faceH * 0.02,
                                      width: (browRight - browLeft) + faceW * 0.08,
                                      height: max(faceH * 0.10, (browTop - browBottom) + faceH * 0.10))
                ctx.fillEllipse(in: corridor)

                // Glabellar frown lines (between the inner brow ends)
                if let innerLeft = face.leftEyebrow.max(by: { $0.x < $1.x }),
                   let innerRight = face.rightEyebrow.min(by: { $0.x < $1.x }) {
                    let glRect = CGRect(x: min(innerLeft.x, innerRight.x) * extent.width - faceW * 0.03,
                                        y: browBottom,
                                        width: abs(innerRight.x - innerLeft.x) * extent.width + faceW * 0.06,
                                        height: max(faceH * 0.10, (browTop - browBottom) + faceH * 0.04))
                    ctx.fillEllipse(in: glRect)
                }
            } else {
                let fhRect = CGRect(x: faceX + faceW * 0.20, y: faceY + faceH * 0.70, width: faceW * 0.60, height: faceH * 0.18)
                ctx.fillEllipse(in: fhRect)
                let glRect = CGRect(x: faceX + faceW * 0.43, y: faceY + faceH * 0.56, width: faceW * 0.14, height: faceH * 0.16)
                ctx.fillEllipse(in: glRect)
            }
        }

        guard let cgImg = ctx.makeImage() else { return makeBlackMask(extent: extent) }
        let blurRadius = max(3.0, shorterEdge * 0.020)
        return CIImage(cgImage: cgImg).clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }

    private static func makeJawlineMask(faces: [FaceLandmarkSet], extent: CGRect, shorterEdge: Double) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return makeBlackMask(extent: extent)
        }
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1.0, alpha: 1.0)

        for face in faces {
            // R3 (2026-11-14): Vision's own face box stops at the brows on many
            // portraits, so every proportion below was measured from a box that
            // never contained the forehead. `skinOvalBox` is the closed face
            // outline (jaw arc + forehead cap) and is the box these zones are
            // actually laid out in.
            let bbox = face.skinOvalBox
            let faceX = bbox.origin.x * extent.width
            let faceY = bbox.origin.y * extent.height
            let faceW = bbox.width * extent.width
            let faceH = bbox.height * extent.height

            // R3 (2026-11-14): the submental corridor used to sit half above
            // the chin line (it spanned faceY - 0.10H .. faceY + 0.10H), so the
            // crease that actually defines a double chin - the one *below* the
            // chin - was only half covered and stayed visible. The corridor is
            // now anchored below the chin and reaches far enough down to hold
            // the whole submental fold.
            let jwRect = CGRect(x: faceX + faceW * 0.25, y: max(0, faceY - faceH * 0.18), width: faceW * 0.50, height: faceH * 0.22)
            ctx.fillEllipse(in: jwRect)
        }

        guard let cgImg = ctx.makeImage() else { return makeBlackMask(extent: extent) }
        let blurRadius = max(4.0, shorterEdge * 0.025)
        return CIImage(cgImage: cgImg).clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }

    private static func makeAntiShineMask(faces: [FaceLandmarkSet], extent: CGRect, shorterEdge: Double) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return makeBlackMask(extent: extent)
        }
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1.0, alpha: 1.0)

        for face in faces {
            // R3 (2026-11-14): Vision's own face box stops at the brows on many
            // portraits, so every proportion below was measured from a box that
            // never contained the forehead. `skinOvalBox` is the closed face
            // outline (jaw arc + forehead cap) and is the box these zones are
            // actually laid out in.
            let bbox = face.skinOvalBox
            let faceX = bbox.origin.x * extent.width
            let faceY = bbox.origin.y * extent.height
            let faceW = bbox.width * extent.width
            let faceH = bbox.height * extent.height

            // T-zone / sebum zones, laid out in the closed face box: the chin
            // sits at 0 and the hairline at 1, so the forehead band starts just
            // above the brow line (≈0.78 on a real face).
            ctx.fillEllipse(in: CGRect(x: faceX + faceW * 0.30, y: faceY + faceH * 0.70, width: faceW * 0.40, height: faceH * 0.24))
            // Nose bridge & tip
            ctx.fillEllipse(in: CGRect(x: faceX + faceW * 0.40, y: faceY + faceH * 0.48, width: faceW * 0.20, height: faceH * 0.26))
            // Left cheek
            ctx.fillEllipse(in: CGRect(x: faceX + faceW * 0.18, y: faceY + faceH * 0.38, width: faceW * 0.22, height: faceH * 0.16))
            // Right cheek
            ctx.fillEllipse(in: CGRect(x: faceX + faceW * 0.60, y: faceY + faceH * 0.38, width: faceW * 0.22, height: faceH * 0.16))
            // Chin
            ctx.fillEllipse(in: CGRect(x: faceX + faceW * 0.38, y: faceY + faceH * 0.03, width: faceW * 0.24, height: faceH * 0.16))
        }

        guard let cgImg = ctx.makeImage() else { return makeBlackMask(extent: extent) }
        let blurRadius = max(3.0, shorterEdge * 0.020)
        return CIImage(cgImage: cgImg).clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }
}

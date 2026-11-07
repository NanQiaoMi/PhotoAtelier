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
        vec4 d = sample(drape, samplerCoord(drape));

        vec3 current = m.rgb;

        // Crease shadow: where mid is darker than surrounding drape base
        vec3 creaseDelta = max(vec3(0.0), d.rgb - m.rgb);

        // 1. Eye bags lifting
        float mEB = sample(eyeBagsMask, samplerCoord(eyeBagsMask)).r;
        float wEB = clamp(strengths1.x * mEB * 0.90, 0.0, 1.0);
        current += creaseDelta * wEB;

        // 2. Dark circles neutralization & lifting
        float mDC = sample(darkCirclesMask, samplerCoord(darkCirclesMask)).r;
        float wDC = clamp(strengths1.y * mDC * 0.85, 0.0, 1.0);
        if (wDC > 0.0) {
            current += creaseDelta * wDC * 0.70;
            vec3 targetWarmth = mix(d.rgb, faceAnchor.rgb, 0.5);
            current = mix(current, targetWarmth, wDC * 0.40);
        }

        // 3. Nasolabial folds lifting
        float mNL = sample(nasolabialMask, samplerCoord(nasolabialMask)).r;
        float wNL = clamp(strengths1.z * mNL * 0.92, 0.0, 1.0);
        current += creaseDelta * wNL;

        // 4. Forehead wrinkles & frown lines lifting
        float mFH = sample(foreheadMask, samplerCoord(foreheadMask)).r;
        float wFH = clamp(strengths1.w * mFH * 0.90, 0.0, 1.0);
        current += creaseDelta * wFH;

        // 5. Jawline & double chin submental crease
        float mJL = sample(jawlineMask, samplerCoord(jawlineMask)).r;
        float wJL = clamp(strengths2.y * mJL * 0.85, 0.0, 1.0);
        current += creaseDelta * wJL;

        // 6. Anti-shine specular compression
        float mAS = sample(antiShineMask, samplerCoord(antiShineMask)).r;
        float sAS = strengths2.x;
        float shineWeight = 0.0;
        if (sAS > 0.0 && mAS > 0.0) {
            float lum = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
            float cMax = max(c.r, max(c.g, c.b));
            float cMin = min(c.r, min(c.g, c.b));
            float chroma = cMax - cMin;
            float isShine = smoothstep(0.70, 0.90, lum) * smoothstep(0.35, 0.05, chroma) * mAS;
            shineWeight = clamp(sAS * isShine * 0.90, 0.0, 1.0);
            current = mix(current, d.rgb, shineWeight);
        }

        // 7. Re-inject high-frequency skin pores (softening specular grease spike)
        vec3 high = c.rgb - m.rgb;
        float texPreserve = strengths2.z;
        current += high * texPreserve * (1.0 - shineWeight * 0.80);

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

        let drape = image.clampedToExtent().applyingGaussianBlur(sigma: sigmaDrape).cropped(to: extent)
        let mid = image.clampedToExtent().applyingGaussianBlur(sigma: sigmaMid).cropped(to: extent)

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

        let sampleRect = CGRect(x: faceX + faceW * 0.28, y: faceY + faceH * 0.45, width: 4, height: 4)
            .intersection(extent)
        guard sampleRect.width >= 1, sampleRect.height >= 1 else {
            return CIVector(x: 0.75, y: 0.58, z: 0.50, w: 1.0)
        }

        let avgFilter = image.cropped(to: sampleRect).applyingFilter("CIAreaAverage")
        var bitmap = [UInt8](repeating: 0, count: 4)
        ctx.render(avgFilter, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        let r = Double(bitmap[0]) / 255.0
        let g = Double(bitmap[1]) / 255.0
        let b = Double(bitmap[2]) / 255.0
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
            let bbox = face.boundingBox
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
            let bbox = face.boundingBox
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
            let bbox = face.boundingBox
            let faceX = bbox.origin.x * extent.width
            let faceY = bbox.origin.y * extent.height
            let faceW = bbox.width * extent.width
            let faceH = bbox.height * extent.height

            ctx.setLineWidth(max(3.0, faceW * 0.07))
            ctx.setLineCap(.round)

            // Left fold: from left nose wing to left mouth corner
            let pL1 = CGPoint(x: faceX + faceW * 0.36, y: faceY + faceH * 0.45)
            let pL2 = CGPoint(x: faceX + faceW * 0.30, y: faceY + faceH * 0.30)
            ctx.strokeLineSegments(between: [pL1, pL2])

            // Right fold: from right nose wing to right mouth corner
            let pR1 = CGPoint(x: faceX + faceW * 0.64, y: faceY + faceH * 0.45)
            let pR2 = CGPoint(x: faceX + faceW * 0.70, y: faceY + faceH * 0.30)
            ctx.strokeLineSegments(between: [pR1, pR2])
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
            let bbox = face.boundingBox
            let faceX = bbox.origin.x * extent.width
            let faceY = bbox.origin.y * extent.height
            let faceW = bbox.width * extent.width
            let faceH = bbox.height * extent.height

            // Horizontal forehead wrinkles corridor
            let fhRect = CGRect(x: faceX + faceW * 0.20, y: faceY + faceH * 0.70, width: faceW * 0.60, height: faceH * 0.18)
            ctx.fillEllipse(in: fhRect)

            // Glabellar frown lines (between brows)
            let glRect = CGRect(x: faceX + faceW * 0.43, y: faceY + faceH * 0.56, width: faceW * 0.14, height: faceH * 0.16)
            ctx.fillEllipse(in: glRect)
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
            let bbox = face.boundingBox
            let faceX = bbox.origin.x * extent.width
            let faceY = bbox.origin.y * extent.height
            let faceW = bbox.width * extent.width
            let faceH = bbox.height * extent.height

            // Submental corridor under chin
            let jwRect = CGRect(x: faceX + faceW * 0.25, y: max(0, faceY - faceH * 0.10), width: faceW * 0.50, height: faceH * 0.20)
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
            let bbox = face.boundingBox
            let faceX = bbox.origin.x * extent.width
            let faceY = bbox.origin.y * extent.height
            let faceW = bbox.width * extent.width
            let faceH = bbox.height * extent.height

            // Forehead center
            ctx.fillEllipse(in: CGRect(x: faceX + faceW * 0.32, y: faceY + faceH * 0.65, width: faceW * 0.36, height: faceH * 0.20))
            // Nose bridge & tip
            ctx.fillEllipse(in: CGRect(x: faceX + faceW * 0.40, y: faceY + faceH * 0.36, width: faceW * 0.20, height: faceH * 0.28))
            // Left cheek
            ctx.fillEllipse(in: CGRect(x: faceX + faceW * 0.18, y: faceY + faceH * 0.44, width: faceW * 0.22, height: faceH * 0.16))
            // Right cheek
            ctx.fillEllipse(in: CGRect(x: faceX + faceW * 0.60, y: faceY + faceH * 0.44, width: faceW * 0.22, height: faceH * 0.16))
            // Chin
            ctx.fillEllipse(in: CGRect(x: faceX + faceW * 0.38, y: faceY + faceH * 0.08, width: faceW * 0.24, height: faceH * 0.14))
        }

        guard let cgImg = ctx.makeImage() else { return makeBlackMask(extent: extent) }
        let blurRadius = max(3.0, shorterEdge * 0.020)
        return CIImage(cgImage: cgImg).clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }
}

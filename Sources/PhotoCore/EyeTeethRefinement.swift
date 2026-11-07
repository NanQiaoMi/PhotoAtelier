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
        vec4 eyeParams
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
            vec3 centered = col - vec3(0.35);
            vec3 boosted = col + centered * (weight * 0.45);
            col = mix(col, clamp(boosted, 0.0, 1.0), weight);
        }

        // 3. Eyeglass glare reduction
        float gStrength = eyeParams.z;
        if (glareM > 0.001 && gStrength > 0.0) {
            float weight = clamp(glareM * gStrength, 0.0, 1.0);
            float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
            if (luma > 0.65) {
                float flareExcess = luma - 0.65;
                col -= vec3(flareExcess * 0.85 * weight);
            }
        }

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

        return vec4(clamp(col, 0.0, 1.0), c.a);
    }
    """

    private static let catchlightKernelSource = """
    kernel vec4 catchlightBlendKernel(sampler src, sampler catchlight, float strength) {
        vec4 c = sample(src, samplerCoord(src));
        vec4 cl = sample(catchlight, samplerCoord(catchlight));
        vec3 blended = c.rgb + cl.rgb * cl.a * strength;
        return vec4(clamp(blended, 0.0, 1.0), c.a);
    }
    """

    private static let eyeKernel = CIColorKernel(source: eyeKernelSource)
    private static let teethKernel = CIColorKernel(source: teethKernelSource)
    private static let catchlightKernel = CIColorKernel(source: catchlightKernelSource)

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
        let hasEyeWork = settings.scleraBloodshotRemoval > 0 || settings.irisClarity > 0 || settings.eyeglassGlareReduction > 0
        if hasEyeWork {
            let scleraMask = maskSet?.sclera ?? makeScleraMask(faces: faces, extent: extent)
            let irisMask = maskSet?.iris ?? makeIrisMask(faces: faces, extent: extent)
            let glareMask = makeEyeglassGlareMask(image: image, faces: faces, extent: extent)

            if let kernel = eyeKernel {
                let params = CIVector(
                    x: CGFloat(settings.scleraBloodshotRemoval),
                    y: CGFloat(settings.irisClarity),
                    z: CGFloat(settings.eyeglassGlareReduction),
                    w: 0.0
                )
                if let processed = kernel.apply(
                    extent: extent,
                    arguments: [result, scleraMask, irisMask, glareMask, params]
                ) {
                    result = processed
                }
            }
        }

        // 2. Process Catchlight Pass
        if settings.catchlightPattern != .off && settings.catchlightStrength > 0 {
            if let catchlightOverlay = makeCatchlightOverlay(
                faces: faces,
                pattern: settings.catchlightPattern,
                scale: settings.catchlightScale,
                extent: extent
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
        let hasTeethWork = settings.teethStainRemoval > 0 || settings.enamelSheen > 0
        if hasTeethWork {
            let teethMask = maskSet?.teeth ?? makeTeethMask(faces: faces, extent: extent)
            let gingivaMask = makeGingivaMask(image: image, faces: faces, extent: extent)

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

        let report = EyeTeethRefinementReport(
            applied: true,
            faceCount: faces.count,
            eyeglassGlareApplied: settings.eyeglassGlareReduction > 0,
            scleraBloodshotApplied: settings.scleraBloodshotRemoval > 0,
            catchlightPattern: settings.catchlightPattern,
            teethStainApplied: settings.teethStainRemoval > 0
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

    public static func makeCatchlightOverlay(
        faces: [FaceLandmarkSet],
        pattern: EyeCatchlightPattern,
        scale: Double,
        extent: CGRect
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

        for face in faces {
            let leftCenter = face.leftPupil ?? polygonCenter(face.leftEye)
            let rightCenter = face.rightPupil ?? polygonCenter(face.rightEye)
            let baseRadius = estimateIrisRadius(face: face, extent: extent)
            let clRadius = baseRadius * 0.45 * CGFloat(scale)

            if let lc = leftCenter {
                let px = lc.x * extent.width
                let py = lc.y * extent.height
                // Place catchlight in upper-outer quadrant for natural lighting reflection
                let offsetX = -clRadius * 0.25
                let offsetY = clRadius * 0.25
                drawCatchlightPattern(pattern, at: CGPoint(x: px + offsetX, y: py + offsetY), radius: clRadius, in: ctx)
            }
            if let rc = rightCenter {
                let px = rc.x * extent.width
                let py = rc.y * extent.height
                let offsetX = clRadius * 0.25
                let offsetY = clRadius * 0.25
                drawCatchlightPattern(pattern, at: CGPoint(x: px + offsetX, y: py + offsetY), radius: clRadius, in: ctx)
            }
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

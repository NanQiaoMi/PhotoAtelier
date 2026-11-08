import Foundation
import CoreImage
import CoreGraphics

/// Engine for P2-Z smart facial bone 3D contour shading, facial folding angle & high-fashion studio lighting sculpting.
///
/// Provides physically inspired 3D bone sculpting:
/// 1. Facial folding angle enhancement (sagittal prominence vs. lateral flank light falloff);
/// 2. T-Zone 3D specular highlight (glabella + nasal bridge axial luminescence);
/// 3. Bilateral C-Zone highlight (curvilinear pearl sheen over orbital rim & upper zygoma);
/// 4. Sub-zygomatic cheek contour shadow (structural slimming & high-fashion definition);
/// 5. Mandibular jawline contour shadow (sharp neck-jaw separation, double-chin visual reduction);
/// 6. Philtrum ridge & Cupid's bow specular micro-sculpting;
/// 7. Warmth modulation (warm golden peach vs. cool neutral taupe).
///
/// 100% offline, GPU-accelerated via Apple Vision landmarks and Core Image `CIColorKernel`.
public enum FacialBoneContourEngine {

    // MARK: - Core Image Shaders

    private static let facialBoneContourKernelSource = """
    kernel vec4 facialBoneContourKernel(
        sampler src,
        sampler hlGuide,
        sampler shGuide,
        vec4 hlParams,    // x: tZone, y: cZone, z: philtrum, w: warmth
        vec4 shParams,    // x: cheekShadow, y: jawlineShadow, z: facialFolding, w: warmth
        vec4 foldBoost    // x: centerBoostStrength, yzw: reserved
    ) {
        vec4 c = sample(src, samplerCoord(src));
        vec4 hl = sample(hlGuide, samplerCoord(hlGuide));
        vec4 sh = sample(shGuide, samplerCoord(shGuide));
        vec3 col = c.rgb;

        float tZone = hl.r * hlParams.x;
        float cZone = hl.g * hlParams.y;
        float philtrum = hl.b * hlParams.z;
        float warmth = hlParams.w;

        // 1. Highlights: Pearlescent Specular Sheen
        float totalHL = tZone * 0.16 + cZone * 0.14 + philtrum * 0.12;
        if (totalHL > 0.0005) {
            vec3 hlTint = vec3(1.0);
            if (warmth > 0.001) {
                hlTint = vec3(1.0 + 0.14 * warmth, 1.0 + 0.05 * warmth, 1.0 - 0.08 * warmth);
            } else if (warmth < -0.001) {
                float wAbs = abs(warmth);
                hlTint = vec3(1.0 - 0.06 * wAbs, 1.0, 1.0 + 0.08 * wAbs);
            }
            col += hlTint * totalHL;
        }

        // 2. Shadows & Lateral Folding Falloff
        float cheekSh = sh.r * shParams.x;
        float jawlineSh = sh.g * shParams.y;
        float foldLateralSh = sh.b * shParams.z;
        float totalShadow = cheekSh * 0.16 + jawlineSh * 0.20 + foldLateralSh * 0.14;

        if (totalShadow > 0.0005) {
            float shMult = max(0.40, 1.0 - totalShadow);
            vec3 shTint = vec3(1.0);
            if (warmth > 0.001) {
                shTint = vec3(1.0 + 0.08 * warmth, 1.0 + 0.02 * warmth, 1.0 - 0.06 * warmth);
            } else if (warmth < -0.001) {
                float wAbs = abs(warmth);
                shTint = vec3(1.0 - 0.04 * wAbs, 1.0, 1.0 + 0.06 * wAbs);
            }
            col *= (shMult * shTint);
        }

        // 3. Central Folding Axial Prominence Boost
        float centerBoost = sh.a * foldBoost.x;
        if (centerBoost > 0.0005) {
            col += vec3(centerBoost * 0.07);
        }

        return vec4(clamp(col, 0.0, 1.0), c.a);
    }
    """

    private static let facialBoneContourKernel: CIColorKernel? = {
        CIColorKernel(source: facialBoneContourKernelSource)
    }()

    // MARK: - Public API

    /// Applies facial bone contour shading, folding and highlight sculpting to all detected faces.
    public static func apply(
        to image: CIImage,
        faces: [FaceLandmarkSet],
        settings: FacialBoneContourSettings
    ) -> (image: CIImage, report: FacialBoneContourReport) {
        guard settings.enabled, !settings.isNeutral, !faces.isEmpty else {
            return (image, FacialBoneContourReport(applied: false, faceCount: 0, note: nil))
        }

        let startTime = Date().timeIntervalSinceReferenceDate
        let usableFaces = faces.filter { $0.hasUsableGeometry }
        guard !usableFaces.isEmpty else {
            return (image, FacialBoneContourReport(applied: false, faceCount: 0, note: "未检测到可用人脸骨相特征点。"))
        }

        guard let kernel = facialBoneContourKernel else {
            return (image, FacialBoneContourReport(applied: false, faceCount: 0, note: "着色器内核初始化失败。"))
        }

        var working = image
        let (hlGuide, shGuide) = makeBoneContourGuideMasks(faces: usableFaces, extent: working.extent)

        let hlParams = CIVector(
            x: CGFloat(settings.tZoneHighlight),
            y: CGFloat(settings.cZoneHighlight),
            z: CGFloat(settings.philtrumHighlight),
            w: CGFloat(settings.contourToneWarmth)
        )
        let shParams = CIVector(
            x: CGFloat(settings.cheekContourShadow),
            y: CGFloat(settings.jawlineShadow),
            z: CGFloat(settings.facialFolding),
            w: CGFloat(settings.contourToneWarmth)
        )
        let foldBoost = CIVector(
            x: CGFloat(settings.facialFolding),
            y: 0,
            z: 0,
            w: 0
        )

        if let shaded = kernel.apply(
            extent: working.extent,
            roiCallback: { _, rect in rect },
            arguments: [working, hlGuide, shGuide, hlParams, shParams, foldBoost]
        ) {
            working = shaded.cropped(to: working.extent)
        }

        let elapsed = Date().timeIntervalSinceReferenceDate - startTime
        let report = FacialBoneContourReport(
            applied: true,
            faceCount: usableFaces.count,
            facialFoldingApplied: settings.facialFolding,
            tZoneHighlightApplied: settings.tZoneHighlight,
            cZoneHighlightApplied: settings.cZoneHighlight,
            cheekContourShadowApplied: settings.cheekContourShadow,
            jawlineShadowApplied: settings.jawlineShadow,
            philtrumHighlightApplied: settings.philtrumHighlight,
            contourToneWarmthApplied: settings.contourToneWarmth,
            executionTime: elapsed,
            note: "智能全脸骨相光影修容处理完成（\(usableFaces.count) 人）。"
        )
        return (working, report)
    }

    /// Applies per-person facial bone contour sculpting with optional per-face mask.
    public static func applyPerPerson(
        to image: CIImage,
        face: FaceLandmarkSet,
        faceIndex: Int,
        settings: FacialBoneContourSettings,
        perFaceMask: FaceSemanticMaskSet? = nil
    ) -> (image: CIImage, report: FacialBoneContourReport) {
        guard settings.enabled, !settings.isNeutral, face.hasUsableGeometry else {
            return (image, FacialBoneContourReport(applied: false, faceCount: 0, note: "人脸 \(faceIndex + 1) 未启用或参数中性。"))
        }
        guard let kernel = facialBoneContourKernel else {
            return (image, FacialBoneContourReport(applied: false, faceCount: 0, note: "着色器内核初始化失败。"))
        }

        let startTime = Date().timeIntervalSinceReferenceDate
        let (hlGuide, shGuide) = makeBoneContourGuideMasks(faces: [face], extent: image.extent)
        let hlParams = CIVector(
            x: CGFloat(settings.tZoneHighlight),
            y: CGFloat(settings.cZoneHighlight),
            z: CGFloat(settings.philtrumHighlight),
            w: CGFloat(settings.contourToneWarmth)
        )
        let shParams = CIVector(
            x: CGFloat(settings.cheekContourShadow),
            y: CGFloat(settings.jawlineShadow),
            z: CGFloat(settings.facialFolding),
            w: CGFloat(settings.contourToneWarmth)
        )
        let foldBoost = CIVector(
            x: CGFloat(settings.facialFolding),
            y: 0,
            z: 0,
            w: 0
        )

        guard let shaded = kernel.apply(
            extent: image.extent,
            roiCallback: { _, rect in rect },
            arguments: [image, hlGuide, shGuide, hlParams, shParams, foldBoost]
        )?.cropped(to: image.extent) else {
            return (image, FacialBoneContourReport(applied: false, faceCount: 0, note: "着色器计算失败。"))
        }

        let finalImage: CIImage
        if let maskSet = perFaceMask, let faceMask = maskSet.skin ?? maskSet.lips {
            finalImage = shaded.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: faceMask
            ]).cropped(to: image.extent)
        } else {
            finalImage = shaded
        }

        let elapsed = Date().timeIntervalSinceReferenceDate - startTime
        let report = FacialBoneContourReport(
            applied: true,
            faceCount: 1,
            facialFoldingApplied: settings.facialFolding,
            tZoneHighlightApplied: settings.tZoneHighlight,
            cZoneHighlightApplied: settings.cZoneHighlight,
            cheekContourShadowApplied: settings.cheekContourShadow,
            jawlineShadowApplied: settings.jawlineShadow,
            philtrumHighlightApplied: settings.philtrumHighlight,
            contourToneWarmthApplied: settings.contourToneWarmth,
            executionTime: elapsed,
            note: nil
        )
        return (finalImage, report)
    }

    // MARK: - Guide Mask Generation

    /// Generates the highlight guide mask and shadow/folding guide mask.
    ///
    /// Highlight mask:
    /// - Red: T-Zone highlight (Glabella + nasal bridge spine + central forehead)
    /// - Green: C-Zone highlight (Orbital lateral rim & upper zygoma)
    /// - Blue: Philtrum ridge & Cupid's bow highlight
    ///
    /// Shadow & Folding mask:
    /// - Red: Sub-zygomatic cheek contour shadow
    /// - Green: Mandibular jawline bottom edge shadow
    /// - Blue: Lateral facial folding light falloff
    /// - Alpha: Central facial folding prominence boost
    public static func makeBoneContourGuideMasks(
        faces: [FaceLandmarkSet],
        extent: CGRect
    ) -> (hlGuide: CIImage, shGuide: CIImage) {
        let width = Int(max(16, extent.width))
        let height = Int(max(16, extent.height))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let hlCtx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ),
        let shCtx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ) else {
            let empty = makeTransparentImage(extent: extent)
            return (empty, empty)
        }

        hlCtx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        shCtx.clear(CGRect(x: 0, y: 0, width: width, height: height))

        var maxFaceWidth: CGFloat = 40.0

        for face in faces {
            guard let geometry = FacialBoneContourGeometry(face: face, extent: extent) else { continue }
            maxFaceWidth = max(maxFaceWidth, geometry.faceWidth)
            drawHighlightGuide(geometry: geometry, ctx: hlCtx, extent: extent)
            drawShadowGuide(geometry: geometry, ctx: shCtx, extent: extent)
        }

        guard let hlCG = hlCtx.makeImage(), let shCG = shCtx.makeImage() else {
            let empty = makeTransparentImage(extent: extent)
            return (empty, empty)
        }

        let blurRadius = max(6.0, maxFaceWidth * 0.045)
        let hlCI = CIImage(cgImage: hlCG)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: extent)
        let shCI = CIImage(cgImage: shCG)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: extent)

        return (hlCI, shCI)
    }

    private static func drawHighlightGuide(
        geometry: FacialBoneContourGeometry,
        ctx: CGContext,
        extent: CGRect
    ) {
        let fw = geometry.faceWidth
        let fh = geometry.faceHeight

        // 1. T-Zone (Red Channel)
        // 1a. Central Forehead Wedge
        ctx.saveGState()
        ctx.setFillColor(red: 1.0, green: 0, blue: 0, alpha: 0.90)
        let foreheadWedge = CGRect(
            x: geometry.glabella.x - fw * 0.12,
            y: geometry.glabella.y,
            width: fw * 0.24,
            height: fh * 0.18
        )
        ctx.fillEllipse(in: foreheadWedge)

        // 1b. Nasal Bridge Spine
        ctx.setStrokeColor(red: 1.0, green: 0, blue: 0, alpha: 0.95)
        ctx.setLineWidth(max(2.0, fw * 0.065))
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: geometry.glabella)
        ctx.addLine(to: geometry.nasalTip)
        ctx.strokePath()
        ctx.restoreGState()

        // 2. C-Zone (Green Channel)
        // Left C-Zone arc (Temple -> Lateral Eye -> Upper Zygoma)
        ctx.saveGState()
        ctx.setStrokeColor(red: 0, green: 1.0, blue: 0, alpha: 0.90)
        ctx.setLineWidth(max(2.0, fw * 0.08))
        ctx.setLineCap(.round)

        ctx.beginPath()
        ctx.move(to: geometry.leftTemple)
        ctx.addQuadCurve(to: geometry.leftUpperZygoma, control: geometry.leftLateralOrbit)
        ctx.strokePath()

        // Right C-Zone arc
        ctx.beginPath()
        ctx.move(to: geometry.rightTemple)
        ctx.addQuadCurve(to: geometry.rightUpperZygoma, control: geometry.rightLateralOrbit)
        ctx.strokePath()
        ctx.restoreGState()

        // 3. Philtrum & Cupid's Bow (Blue Channel)
        ctx.saveGState()
        ctx.setStrokeColor(red: 0, green: 0, blue: 1.0, alpha: 0.95)
        ctx.setLineWidth(max(1.5, fw * 0.035))
        ctx.setLineCap(.round)

        ctx.beginPath()
        ctx.move(to: geometry.subnasale)
        ctx.addLine(to: geometry.cupidBow)
        ctx.strokePath()

        // Small Cupid's bow crest horizontal glow
        let bowRect = CGRect(
            x: geometry.cupidBow.x - fw * 0.05,
            y: geometry.cupidBow.y - fh * 0.015,
            width: fw * 0.10,
            height: fh * 0.03
        )
        ctx.setFillColor(red: 0, green: 0, blue: 1.0, alpha: 0.85)
        ctx.fillEllipse(in: bowRect)
        ctx.restoreGState()
    }

    private static func drawShadowGuide(
        geometry: FacialBoneContourGeometry,
        ctx: CGContext,
        extent: CGRect
    ) {
        let fw = geometry.faceWidth
        let fh = geometry.faceHeight

        // 1. Sub-zygomatic Cheek Contour Shadow (Red Channel)
        ctx.saveGState()
        ctx.setStrokeColor(red: 1.0, green: 0, blue: 0, alpha: 0.90)
        ctx.setLineWidth(max(2.0, fw * 0.09))
        ctx.setLineCap(.round)

        // Left cheek hollow
        ctx.beginPath()
        ctx.move(to: geometry.leftSubZygoma)
        ctx.addLine(to: geometry.leftOralLateral)
        ctx.strokePath()

        // Right cheek hollow
        ctx.beginPath()
        ctx.move(to: geometry.rightSubZygoma)
        ctx.addLine(to: geometry.rightOralLateral)
        ctx.strokePath()
        ctx.restoreGState()

        // 2. Mandibular Jawline Shadow (Green Channel)
        ctx.saveGState()
        ctx.setStrokeColor(red: 0, green: 1.0, blue: 0, alpha: 0.92)
        ctx.setLineWidth(max(2.5, fw * 0.08))
        ctx.setLineCap(.round)

        if geometry.mandiblePoints.count >= 3 {
            ctx.beginPath()
            ctx.move(to: geometry.mandiblePoints[0])
            for pt in geometry.mandiblePoints.dropFirst() {
                ctx.addLine(to: pt)
            }
            ctx.strokePath()
        }
        ctx.restoreGState()

        // 3. Facial Folding: Lateral Falloff (Blue Channel) & Central Axial Boost (Alpha Channel)
        ctx.saveGState()

        // 3a. Lateral Flanks Falloff (Blue Channel)
        ctx.setStrokeColor(red: 0, green: 0, blue: 1.0, alpha: 0.90)
        ctx.setLineWidth(max(3.0, fw * 0.13))
        ctx.setLineCap(.round)

        // Left lateral flank strip
        ctx.beginPath()
        ctx.move(to: geometry.leftTemple)
        ctx.addQuadCurve(to: geometry.leftJawAngle, control: geometry.leftUpperZygoma)
        ctx.strokePath()

        // Right lateral flank strip
        ctx.beginPath()
        ctx.move(to: geometry.rightTemple)
        ctx.addQuadCurve(to: geometry.rightJawAngle, control: geometry.rightUpperZygoma)
        ctx.strokePath()

        // 3b. Central Axial Corridor Prominence Boost (Alpha Channel with subtle white)
        // Stored in Alpha channel of shGuide
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.85)
        let centerCorridor = CGRect(
            x: geometry.glabella.x - fw * 0.15,
            y: geometry.menton.y,
            width: fw * 0.30,
            height: geometry.glabella.y - geometry.menton.y + fh * 0.12
        )
        ctx.fillEllipse(in: centerCorridor)
        ctx.restoreGState()
    }

    private static func makeTransparentImage(extent: CGRect) -> CIImage {
        CIImage(color: .clear).cropped(to: extent)
    }
}

// MARK: - Internal Facial Bone Contour Geometry

public struct FacialBoneContourGeometry: Equatable {
    public var faceWidth: CGFloat
    public var faceHeight: CGFloat

    // T-Zone & Central Axis
    public var glabella: CGPoint
    public var nasalTip: CGPoint
    public var subnasale: CGPoint
    public var cupidBow: CGPoint
    public var menton: CGPoint

    // C-Zone & Lateral Orbital
    public var leftTemple: CGPoint
    public var rightTemple: CGPoint
    public var leftLateralOrbit: CGPoint
    public var rightLateralOrbit: CGPoint
    public var leftUpperZygoma: CGPoint
    public var rightUpperZygoma: CGPoint

    // Cheek Contour (Sub-zygomatic hollow)
    public var leftSubZygoma: CGPoint
    public var rightSubZygoma: CGPoint
    public var leftOralLateral: CGPoint
    public var rightOralLateral: CGPoint

    // Jawline & Mandible
    public var leftJawAngle: CGPoint
    public var rightJawAngle: CGPoint
    public var mandiblePoints: [CGPoint]

    public init?(face: FaceLandmarkSet, extent: CGRect) {
        guard face.hasUsableGeometry else { return nil }
        let box = face.boundingBox

        let fw = max(16.0, box.width * extent.width)
        let fh = max(16.0, box.height * extent.height)
        self.faceWidth = fw
        self.faceHeight = fh

        // Pupils & Eye Centers
        let validLeftEye = face.leftEye.filter { $0.x.isFinite && $0.y.isFinite }
        let leftEyeCenter: CGPoint
        if !validLeftEye.isEmpty {
            let sumX = validLeftEye.reduce(0.0) { $0 + $1.x }
            let sumY = validLeftEye.reduce(0.0) { $0 + $1.y }
            leftEyeCenter = CGPoint(x: (sumX / CGFloat(validLeftEye.count)) * extent.width,
                                    y: (sumY / CGFloat(validLeftEye.count)) * extent.height)
        } else {
            leftEyeCenter = CGPoint(x: (box.minX + box.width * 0.32) * extent.width,
                                    y: (box.minY + box.height * 0.65) * extent.height)
        }

        let validRightEye = face.rightEye.filter { $0.x.isFinite && $0.y.isFinite }
        let rightEyeCenter: CGPoint
        if !validRightEye.isEmpty {
            let sumX = validRightEye.reduce(0.0) { $0 + $1.x }
            let sumY = validRightEye.reduce(0.0) { $0 + $1.y }
            rightEyeCenter = CGPoint(x: (sumX / CGFloat(validRightEye.count)) * extent.width,
                                     y: (sumY / CGFloat(validRightEye.count)) * extent.height)
        } else {
            rightEyeCenter = CGPoint(x: (box.maxX - box.width * 0.32) * extent.width,
                                     y: (box.minY + box.height * 0.65) * extent.height)
        }

        // Midline & Axis Points
        let midX = (leftEyeCenter.x + rightEyeCenter.x) * 0.5
        let eyeY = (leftEyeCenter.y + rightEyeCenter.y) * 0.5

        let validNose = face.nose.filter { $0.x.isFinite && $0.y.isFinite }
        let noseTop = validNose.max(by: { $0.y < $1.y })
        let noseBottom = validNose.min(by: { $0.y < $1.y })

        self.glabella = noseTop.map { CGPoint(x: $0.x * extent.width, y: $0.y * extent.height) } ??
            CGPoint(x: midX, y: eyeY + fh * 0.05)

        self.nasalTip = noseBottom.map { CGPoint(x: $0.x * extent.width, y: ($0.y + box.height * 0.03) * extent.height) } ??
            CGPoint(x: midX, y: (box.minY + box.height * 0.45) * extent.height)

        self.subnasale = noseBottom.map { CGPoint(x: $0.x * extent.width, y: $0.y * extent.height) } ??
            CGPoint(x: midX, y: (box.minY + box.height * 0.42) * extent.height)

        let validLips = face.outerLips.filter { $0.x.isFinite && $0.y.isFinite }
        let lipTop = validLips.max(by: { $0.y < $1.y })
        self.cupidBow = lipTop.map { CGPoint(x: $0.x * extent.width, y: $0.y * extent.height) } ??
            CGPoint(x: midX, y: (box.minY + box.height * 0.35) * extent.height)

        let validContour = face.faceContour.filter { $0.x.isFinite && $0.y.isFinite }
        let lowestContour = validContour.min(by: { $0.y < $1.y })
        self.menton = lowestContour.map { CGPoint(x: $0.x * extent.width, y: $0.y * extent.height) } ??
            CGPoint(x: midX, y: (box.minY + box.height * 0.08) * extent.height)

        // C-Zone Lateral Points
        let leftEyebrowValid = face.leftEyebrow.filter { $0.x.isFinite && $0.y.isFinite }
        let leftBrowTail = leftEyebrowValid.min(by: { $0.x < $1.x }) // Normalized X is smaller on image left
        self.leftTemple = leftBrowTail.map { CGPoint(x: ($0.x - box.width * 0.04) * extent.width, y: ($0.y + box.height * 0.02) * extent.height) } ??
            CGPoint(x: (box.minX + box.width * 0.12) * extent.width, y: (box.minY + box.height * 0.72) * extent.height)

        let rightEyebrowValid = face.rightEyebrow.filter { $0.x.isFinite && $0.y.isFinite }
        let rightBrowTail = rightEyebrowValid.max(by: { $0.x < $1.x })
        self.rightTemple = rightBrowTail.map { CGPoint(x: ($0.x + box.width * 0.04) * extent.width, y: ($0.y + box.height * 0.02) * extent.height) } ??
            CGPoint(x: (box.maxX - box.width * 0.12) * extent.width, y: (box.minY + box.height * 0.72) * extent.height)

        self.leftLateralOrbit = CGPoint(x: leftEyeCenter.x - fw * 0.22, y: leftEyeCenter.y)
        self.rightLateralOrbit = CGPoint(x: rightEyeCenter.x + fw * 0.22, y: rightEyeCenter.y)

        self.leftUpperZygoma = CGPoint(x: leftEyeCenter.x - fw * 0.18, y: leftEyeCenter.y - fh * 0.12)
        self.rightUpperZygoma = CGPoint(x: rightEyeCenter.x + fw * 0.18, y: rightEyeCenter.y - fh * 0.12)

        // Cheek Contour Hollow
        self.leftSubZygoma = CGPoint(x: leftEyeCenter.x - fw * 0.22, y: leftEyeCenter.y - fh * 0.18)
        self.rightSubZygoma = CGPoint(x: rightEyeCenter.x + fw * 0.22, y: rightEyeCenter.y - fh * 0.18)

        let leftLipCorner = validLips.min(by: { $0.x < $1.x })
        let rightLipCorner = validLips.max(by: { $0.x < $1.x })

        self.leftOralLateral = leftLipCorner.map { CGPoint(x: ($0.x - box.width * 0.08) * extent.width, y: $0.y * extent.height) } ??
            CGPoint(x: (box.minX + box.width * 0.25) * extent.width, y: (box.minY + box.height * 0.32) * extent.height)
        self.rightOralLateral = rightLipCorner.map { CGPoint(x: ($0.x + box.width * 0.08) * extent.width, y: $0.y * extent.height) } ??
            CGPoint(x: (box.maxX - box.width * 0.25) * extent.width, y: (box.minY + box.height * 0.32) * extent.height)

        // Jaw Angles & Mandible
        let leftJawCandidates = validContour.filter { $0.x < box.midX && $0.y >= box.minY + box.height * 0.18 && $0.y <= box.minY + box.height * 0.32 }
        let rightJawCandidates = validContour.filter { $0.x > box.midX && $0.y >= box.minY + box.height * 0.18 && $0.y <= box.minY + box.height * 0.32 }

        self.leftJawAngle = leftJawCandidates.min(by: { $0.x < $1.x }).map { CGPoint(x: $0.x * extent.width, y: $0.y * extent.height) } ??
            CGPoint(x: (box.minX + box.width * 0.18) * extent.width, y: (box.minY + box.height * 0.24) * extent.height)
        self.rightJawAngle = rightJawCandidates.max(by: { $0.x < $1.x }).map { CGPoint(x: $0.x * extent.width, y: $0.y * extent.height) } ??
            CGPoint(x: (box.maxX - box.width * 0.18) * extent.width, y: (box.minY + box.height * 0.24) * extent.height)

        // Lower Mandible Outline Points (Offset downwards slightly into neck for shadow)
        let lowerContour = validContour.filter { $0.y <= box.minY + box.height * 0.28 }
            .sorted(by: { $0.x < $1.x })
        if !lowerContour.isEmpty {
            self.mandiblePoints = lowerContour.map {
                CGPoint(x: $0.x * extent.width, y: ($0.y - box.height * 0.02) * extent.height)
            }
        } else {
            self.mandiblePoints = [
                self.leftJawAngle,
                CGPoint(x: midX, y: self.menton.y - fh * 0.02),
                self.rightJawAngle
            ]
        }
    }
}

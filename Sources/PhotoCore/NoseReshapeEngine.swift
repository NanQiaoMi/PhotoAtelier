import CoreGraphics
import CoreImage
import Foundation

// MARK: - Nose Reshape Engine

/// P2-V: Smart nose reshaping, 3D bridge contouring & structural correction engine.
///
/// Features:
/// 1. 鼻翼收窄与精雕 (Narrow Nose Wings / `narrowNoseWing`):
///    Horizontally narrows or widens the alar bases and alar groove (-0.5 to +0.5).
/// 2. 鼻头立体微缩与塑形 (Nose Tip Resizing & Refinement / `noseTipSize`):
///    Shrinks bulbous, fleshy nose tips radially inward for a refined supratip contour (-0.5 to +0.5).
/// 3. 鼻梁挺拔度与宽度微调 (Nose Bridge Width & Vault Narrowing / `noseBridgeWidth`):
///    Tightens or broadens the bony nasal vault and radix lateral walls (-0.5 to +0.5).
/// 4. 鼻唇角/鼻尖仰俯角调节（朝天鼻/鹰钩鼻矫正） (Nose Pitch Angle & Rotation / `nosePitchAngle`):
///    Rotates and shifts the nasal tip vertically (-0.5 upturned/hawk correction to +0.5 short/snub correction).
/// 5. 驼峰鼻背平缓抚平 (Dorsal Hump Smoothing / `humpSmoothing`):
///    Smooths dorsal bony humps for a smooth, straight nasal profile (0 to 1.0).
/// 6. 鼻长调节与中庭平衡 (Nose Length Modulation / `noseLength`):
///    Modulates vertical nose length to shorten mid-face length for a youthful look, or lengthen it (-0.5 to +0.5).
/// 7. 鼻梁立体高光与双侧修容阴影 (3D Dorsal Highlight & Micro-Shading / `nose3DContour`):
///    Renders 3D specular highlight down the dorsal midline & tip paired with delicate lateral sidewall shadows (0 to 1.0).
///
/// 100% offline, zero external model weights, Core Image GPU & Metal accelerated via WarpField deformation.
public enum NoseReshapeEngine {

    // MARK: - Shader Kernels

    private static let nose3DContourKernelSource = """
    kernel vec4 nose3DContourKernel(
        sampler src,
        sampler guide,
        vec4 params // x: highlightStrength, y: shadowStrength, zw: reserved
    ) {
        vec4 c = sample(src, samplerCoord(src));
        vec4 g = sample(guide, samplerCoord(guide));
        vec3 col = c.rgb;

        float hl = g.r * params.x;
        float sh = g.g * params.y;

        // Specular highlight: subtle natural pearlescent bridge boost
        if (hl > 0.001) {
            col += vec3(hl * 0.18);
        }
        // Micro-shadow: subtle deepening of nasal sidewalls and columellar triangle
        if (sh > 0.001) {
            col *= (1.0 - sh * 0.15);
        }

        // R3 (2026-11-14): pixels outside this module's guides pass through
        // unchanged. The engine works in extended-linear-sRGB, where highlights
        // above 1.0 are legitimate; the unconditional clamp used to clip every
        // highlight in the photograph whenever the slider was non-zero.
        if (hl <= 0.001 && sh <= 0.001) { return c; }
        return vec4(clamp(col, 0.0, 1.0), c.a);
    }
    """

    private static let nose3DContourKernel: CIColorKernel? = {
        CIColorKernel(source: nose3DContourKernelSource)
    }()

    // MARK: - Public API

    /// Applies nose reshaping and 3D contouring to all detected faces.
    public static func apply(
        to image: CIImage,
        faces: [FaceLandmarkSet],
        settings: NoseReshapeSettings
    ) -> (image: CIImage, report: NoseReshapeReport) {
        guard settings.enabled, !settings.isNeutral, !faces.isEmpty else {
            return (image, NoseReshapeReport(applied: false, faceCount: 0, note: nil))
        }

        let startTime = Date().timeIntervalSinceReferenceDate
        let usableFaces = faces.filter { $0.hasUsableGeometry && !$0.nose.isEmpty }
        guard !usableFaces.isEmpty else {
            return (image, NoseReshapeReport(applied: false, faceCount: 0, note: "未检测到可用鼻部关键点。"))
        }

        var working = image

        // 1. Warp Field for wings, tip, bridge, pitch, hump & length
        let field = generateWarpField(faces: usableFaces, settings: settings, imageSize: image.extent.size)
        if !field.isIdentity {
            do {
                working = try field.apply(to: working)
            } catch {
                // If warp fails, keep working as is
            }
        }

        // 2. 3D Bridge Highlight & Sidewall Micro-Shading
        if settings.nose3DContour > 0.001, let kernel = nose3DContourKernel {
            let guide = makeNose3DGuideMask(faces: usableFaces, extent: image.extent)
            let params = CIVector(x: CGFloat(settings.nose3DContour),
                                  y: CGFloat(settings.nose3DContour * 0.85),
                                  z: 0, w: 0)
            if let shaded = kernel.apply(extent: image.extent,
                                         roiCallback: { _, rect in rect },
                                         arguments: [working, guide, params]) {
                working = shaded.cropped(to: image.extent)
            }
        }

        let elapsedMs = (Date().timeIntervalSinceReferenceDate - startTime) * 1000.0
        let report = NoseReshapeReport(
            applied: true,
            faceCount: usableFaces.count,
            averageNoseWingAdjustment: settings.narrowNoseWing,
            averageBridgeAdjustment: settings.noseBridgeWidth,
            humpSmoothedFaces: settings.humpSmoothing > 0.01 ? usableFaces.count : 0,
            processingTimeMs: elapsedMs,
            note: nil
        )

        return (working, report)
    }

    /// Applies nose reshape adjustments for a single person in multi-person demographic processing.
    public static func applyPerPerson(
        to image: CIImage,
        face: FaceLandmarkSet,
        faceIndex: Int,
        settings: NoseReshapeSettings,
        perFaceMask: FaceSemanticMaskSet? = nil
    ) -> (image: CIImage, report: NoseReshapeReport) {
        guard settings.enabled, !settings.isNeutral,
              face.hasUsableGeometry && !face.nose.isEmpty else {
            return (image, NoseReshapeReport(applied: false, faceCount: 0, note: "人脸 \(faceIndex + 1) 未启用或参数中性。"))
        }

        let startTime = Date().timeIntervalSinceReferenceDate
        var working = image

        let field = generateWarpField(faces: [face], settings: settings, imageSize: image.extent.size)
        if !field.isIdentity {
            do {
                let warped = try field.apply(to: working)
                if let maskSet = perFaceMask, let faceMask = maskSet.skin ?? maskSet.lips {
                    working = warped.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: working,
                        kCIInputMaskImageKey: faceMask
                    ])
                } else {
                    working = warped
                }
            } catch {
                // Fallback to unwarped image
            }
        }

        // 3D Bridge Highlight & Sidewall Micro-Shading
        if settings.nose3DContour > 0.001, let kernel = nose3DContourKernel {
            let guide = makeNose3DGuideMask(faces: [face], extent: image.extent)
            let params = CIVector(x: CGFloat(settings.nose3DContour),
                                  y: CGFloat(settings.nose3DContour * 0.85),
                                  z: 0, w: 0)
            if let shaded = kernel.apply(extent: image.extent,
                                         roiCallback: { _, rect in rect },
                                         arguments: [working, guide, params]) {
                working = shaded.cropped(to: image.extent)
            }
        }

        let elapsedMs = (Date().timeIntervalSinceReferenceDate - startTime) * 1000.0
        let report = NoseReshapeReport(
            applied: true,
            faceCount: 1,
            averageNoseWingAdjustment: settings.narrowNoseWing,
            averageBridgeAdjustment: settings.noseBridgeWidth,
            humpSmoothedFaces: settings.humpSmoothing > 0.01 ? 1 : 0,
            processingTimeMs: elapsedMs,
            note: "完成人脸 \(faceIndex + 1) 鼻部微雕。"
        )

        return (working, report)
    }

    // MARK: - Warp Field Generation

    /// Builds a WarpField displacement map tailored to the nose geometry of each face.
    public static func generateWarpField(
        faces: [FaceLandmarkSet],
        settings: NoseReshapeSettings,
        imageSize: CGSize,
        resolution: Int = WarpField.defaultResolution
    ) -> WarpField {
        var field = WarpField(columns: resolution, rows: resolution)
        guard imageSize.width > 1, imageSize.height > 1, !settings.isNeutral else {
            return field
        }

        for face in faces {
            guard let geometry = NoseGeometry(face: face, imageSize: imageSize) else { continue }
            addNoseShapeControls(to: &field, geometry: geometry, settings: settings, imageSize: imageSize)

            // Background protection around the nose
            var protectedRect = geometry.boundingBox
            protectedRect = protectedRect.insetBy(dx: -geometry.boundingBox.width * 0.20,
                                                  dy: -geometry.boundingBox.height * 0.20)
            let feather = max(Double(geometry.boundingBox.width), Double(geometry.boundingBox.height)) * 0.25
            field.attenuateOutside(rect: protectedRect, feather: feather)
        }

        field.smooth(passes: 2)
        field.clampMagnitude()
        return field
    }

    // MARK: - Nose Shape Controls

    private static func addNoseShapeControls(
        to field: inout WarpField,
        geometry: NoseGeometry,
        settings: NoseReshapeSettings,
        imageSize: CGSize
    ) {
        let nw = geometry.alarWidth
        let nh = geometry.noseHeight

        // 1. 鼻翼收窄 (Narrow Nose Wings)
        if abs(settings.narrowNoseWing) > 0.0001 {
            let dx = nw * 0.28 * settings.narrowNoseWing
            let rx = nw * 0.40
            let ry = nh * 0.25

            // Left alar base moves +X (inward towards center)
            field.addGaussian(
                center: geometry.leftAlarBase,
                radiusX: rx,
                radiusY: ry,
                displacement: SIMD2<Double>(dx, 0),
                falloff: .gaussian
            )

            // Right alar base moves -X (inward towards center)
            field.addGaussian(
                center: geometry.rightAlarBase,
                radiusX: rx,
                radiusY: ry,
                displacement: SIMD2<Double>(-dx, 0),
                falloff: .gaussian
            )
        }

        // 2. 鼻头立体微缩与塑形 (Nose Tip Resizing)
        if abs(settings.noseTipSize) > 0.0001 {
            let tipDx = nw * 0.18 * settings.noseTipSize
            let tipDy = nh * 0.14 * settings.noseTipSize
            let radX = nw * 0.35
            let radY = nh * 0.22

            // Left of tip pulls right (+X)
            field.addGaussian(
                center: CGPoint(x: geometry.noseTip.x - nw * 0.22, y: geometry.noseTip.y),
                radiusX: radX, radiusY: radY,
                displacement: SIMD2<Double>(tipDx, 0),
                falloff: .gaussian
            )
            // Right of tip pulls left (-X)
            field.addGaussian(
                center: CGPoint(x: geometry.noseTip.x + nw * 0.22, y: geometry.noseTip.y),
                radiusX: radX, radiusY: radY,
                displacement: SIMD2<Double>(-tipDx, 0),
                falloff: .gaussian
            )
            // Top of tip pulls down (-Y)
            field.addGaussian(
                center: CGPoint(x: geometry.noseTip.x, y: geometry.noseTip.y + nh * 0.15),
                radiusX: radX, radiusY: radY,
                displacement: SIMD2<Double>(0, -tipDy),
                falloff: .gaussian
            )
            // Bottom of tip pulls up (+Y)
            field.addGaussian(
                center: CGPoint(x: geometry.noseTip.x, y: geometry.noseTip.y - nh * 0.15),
                radiusX: radX, radiusY: radY,
                displacement: SIMD2<Double>(0, tipDy),
                falloff: .gaussian
            )
        }

        // 3. 鼻梁挺拔度与骨骼收窄 (Nose Bridge Width)
        if abs(settings.noseBridgeWidth) > 0.0001 {
            let bridgeDx = nw * 0.24 * settings.noseBridgeWidth
            let rx = nw * 0.35
            let ry = nh * 0.32

            // Left lateral nasal wall moves +X
            field.addGaussian(
                center: CGPoint(x: geometry.midBridge.x - nw * 0.25, y: geometry.midBridge.y),
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(bridgeDx, 0),
                falloff: .gaussian
            )
            // Right lateral nasal wall moves -X
            field.addGaussian(
                center: CGPoint(x: geometry.midBridge.x + nw * 0.25, y: geometry.midBridge.y),
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(-bridgeDx, 0),
                falloff: .gaussian
            )
        }

        // 4. 鼻唇角/鼻尖仰俯角调节（朝天鼻/鹰钩鼻矫正） (Nose Pitch Angle)
        if abs(settings.nosePitchAngle) > 0.0001 {
            // Positive shifts downward (-Y) to cover nostrils and lengthen short nose
            // Negative lifts upward (+Y) for upturned tip / correcting drooping nose
            let pitchDy = -nh * 0.25 * settings.nosePitchAngle
            let rx = nw * 0.50
            let ry = nh * 0.28

            field.addGaussian(
                center: geometry.noseTip,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(0, pitchDy),
                falloff: .gaussian
            )
            field.addGaussian(
                center: geometry.subnasale,
                radiusX: rx * 0.8, radiusY: ry * 0.8,
                displacement: SIMD2<Double>(0, pitchDy * 0.65),
                falloff: .gaussian
            )
        }

        // 5. 驼峰鼻背平缓抚平 (Dorsal Hump Smoothing)
        if settings.humpSmoothing > 0.0001 {
            let humpDx = nw * 0.18 * settings.humpSmoothing
            let rx = nw * 0.38
            let ry = nh * 0.25
            let humpY = geometry.subnasale.y + nh * 0.62

            field.addGaussian(
                center: CGPoint(x: geometry.midBridge.x - nw * 0.22, y: humpY),
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(humpDx, 0),
                falloff: .gaussian
            )
            field.addGaussian(
                center: CGPoint(x: geometry.midBridge.x + nw * 0.22, y: humpY),
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(-humpDx, 0),
                falloff: .gaussian
            )
        }

        // 6. 鼻长调节与中庭平衡 (Nose Length Modulation)
        if abs(settings.noseLength) > 0.0001 {
            // Positive lengthens downward (-Y), negative shortens upward (+Y)
            let lenDy = -nh * 0.20 * settings.noseLength
            let rx = nw * 0.60
            let ry = nh * 0.40

            field.addGaussian(
                center: CGPoint(x: geometry.noseTip.x, y: geometry.subnasale.y + nh * 0.15),
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(0, lenDy),
                falloff: .gaussian
            )
        }
    }

    // MARK: - 3D Contour Guide Mask

    /// Renders specular dorsal highlight (Red channel) and lateral sidewall micro-shading (Green channel).
    public static func makeNose3DGuideMask(
        faces: [FaceLandmarkSet],
        extent: CGRect
    ) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return makeTransparentImage(extent: extent)
        }

        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))

        for face in faces {
            guard let geometry = NoseGeometry(face: face, imageSize: extent.size) else { continue }
            renderSingleFaceNose3DGuide(geometry: geometry, in: ctx, extent: extent)
        }

        guard let cgImg = ctx.makeImage() else { return makeTransparentImage(extent: extent) }
        let rawMask = CIImage(cgImage: cgImg)
        let blurRadius = max(1.0, extent.height * 0.0035)
        return rawMask.clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }

    private static func renderSingleFaceNose3DGuide(
        geometry: NoseGeometry,
        in ctx: CGContext,
        extent: CGRect
    ) {
        let nw = geometry.alarWidth * extent.width
        let nh = geometry.noseHeight * extent.height

        let radixPt = CGPoint(x: geometry.radix.x * extent.width, y: geometry.radix.y * extent.height)
        let tipPt = CGPoint(x: geometry.noseTip.x * extent.width, y: geometry.noseTip.y * extent.height)
        let leftAlarPt = CGPoint(x: geometry.leftAlarBase.x * extent.width, y: geometry.leftAlarBase.y * extent.height)
        let rightAlarPt = CGPoint(x: geometry.rightAlarBase.x * extent.width, y: geometry.rightAlarBase.y * extent.height)

        // 1. Specular Dorsal Highlight (Red channel)
        ctx.saveGState()
        ctx.setStrokeColor(red: 1.0, green: 0, blue: 0, alpha: 0.90)
        ctx.setLineWidth(max(2.0, nw * 0.16))
        ctx.setLineCap(.round)
        ctx.beginPath()
        // Draw bridge highlight line from upper bridge down to supratip
        let startBridge = CGPoint(x: radixPt.x, y: radixPt.y - nh * 0.10)
        let endBridge = CGPoint(x: tipPt.x, y: tipPt.y + nh * 0.08)
        ctx.move(to: startBridge)
        ctx.addLine(to: endBridge)
        ctx.strokePath()

        // Highlight spot on nose tip
        ctx.setFillColor(red: 1.0, green: 0, blue: 0, alpha: 0.95)
        let tipRadius = max(2.5, nw * 0.16)
        ctx.fillEllipse(in: CGRect(x: tipPt.x - tipRadius, y: tipPt.y - tipRadius,
                                  width: tipRadius * 2, height: tipRadius * 2))
        ctx.restoreGState()

        // 2. Sidewall Micro-Shading (Green channel)
        ctx.saveGState()
        ctx.setStrokeColor(red: 0, green: 1.0, blue: 0, alpha: 0.85)
        ctx.setLineWidth(max(2.0, nw * 0.22))
        ctx.setLineCap(.round)

        // Left sidewall shadow line
        ctx.beginPath()
        ctx.move(to: CGPoint(x: radixPt.x - nw * 0.22, y: radixPt.y - nh * 0.12))
        ctx.addLine(to: CGPoint(x: leftAlarPt.x + nw * 0.10, y: leftAlarPt.y + nh * 0.10))
        ctx.strokePath()

        // Right sidewall shadow line
        ctx.beginPath()
        ctx.move(to: CGPoint(x: radixPt.x + nw * 0.22, y: radixPt.y - nh * 0.12))
        ctx.addLine(to: CGPoint(x: rightAlarPt.x - nw * 0.10, y: rightAlarPt.y + nh * 0.10))
        ctx.strokePath()

        // Infratip / Columellar shadow under tip
        ctx.setFillColor(red: 0, green: 1.0, blue: 0, alpha: 0.80)
        let columellaRadiusX = max(2.0, nw * 0.18)
        let columellaRadiusY = max(1.5, nh * 0.08)
        let subnasaleY = geometry.subnasale.y * extent.height
        ctx.fillEllipse(in: CGRect(x: tipPt.x - columellaRadiusX,
                                  y: subnasaleY - columellaRadiusY * 0.5,
                                  width: columellaRadiusX * 2,
                                  height: columellaRadiusY * 2))
        ctx.restoreGState()
    }

    private static func makeTransparentImage(extent: CGRect) -> CIImage {
        CIImage(color: .clear).cropped(to: extent)
    }
}

// MARK: - Internal Nose Geometry

public struct NoseGeometry: Equatable {
    public var boundingBox: CGRect
    public var radix: CGPoint
    public var noseTip: CGPoint
    public var subnasale: CGPoint
    public var leftAlarBase: CGPoint
    public var rightAlarBase: CGPoint
    public var midBridge: CGPoint
    public var alarWidth: Double
    public var noseHeight: Double

    public init?(face: FaceLandmarkSet, imageSize: CGSize) {
        guard face.hasUsableGeometry, !face.nose.isEmpty else { return nil }
        self.boundingBox = face.boundingBox

        let validPts = face.nose.filter { $0.x.isFinite && $0.y.isFinite }
        guard validPts.count >= 3 else { return nil }

        let minXPt = validPts.min(by: { $0.x < $1.x })!
        let maxXPt = validPts.max(by: { $0.x < $1.x })!
        let minYPt = validPts.min(by: { $0.y < $1.y })!
        let maxYPt = validPts.max(by: { $0.y < $1.y })!

        let subnasalePoint = minYPt
        let radixPoint = maxYPt

        let height = max(0.015, Double(radixPoint.y - subnasalePoint.y))
        let width = max(0.01, Double(maxXPt.x - minXPt.x))

        let leftAlar = minXPt
        let rightAlar = maxXPt

        let centerX = (leftAlar.x + rightAlar.x) * 0.5
        let tipY = subnasalePoint.y + CGFloat(height * 0.22)
        let midY = subnasalePoint.y + CGFloat(height * 0.60)

        self.radix = radixPoint
        self.subnasale = subnasalePoint
        self.leftAlarBase = leftAlar
        self.rightAlarBase = rightAlar
        self.noseTip = CGPoint(x: centerX, y: tipY)
        self.midBridge = CGPoint(x: centerX, y: midY)
        self.alarWidth = width
        self.noseHeight = height
    }
}

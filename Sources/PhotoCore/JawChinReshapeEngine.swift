import CoreGraphics
import CoreImage
import Foundation

// MARK: - Jaw & Chin Reshape Engine

/// P2-W: Smart jawline sculpting, chin reshaping & lower-face proportions engine.
///
/// Features:
/// 1. 下颌角收窄与折角微雕 (Narrow/Widen Jaw Angle & Gonial Width / `jawWidth`):
///    Horizontally narrows or widens the bilateral gonial angles and mandibular width (-0.5 to +0.5).
/// 2. 下巴长度调节与下庭平衡 (Chin Length Modulation & Lower-Face Proportions / `chinLength`):
///    Adjusts the vertical length of the chin apex to shorten a long chin or lengthen a short chin (-0.5 to +0.5).
/// 3. 下巴翘度微调（解决下巴后缩） (Chin Projection & Forward Perkiness / `chinProjection`):
///    Simulates forward and upward skeletal projection of the mentum to resolve a recessed chin (-0.5 to +0.5).
/// 4. 下巴形态微雕（圆幼下巴 vs 精致V脸） (Chin Shape Sculpting / `chinShape`):
///    Tapers the lower chin slopes inward for a sharp V-line chin, or rounds and widens the chin tip for a youthful round chin (-0.5 to +0.5).
/// 5. 下颌缘紧致与线条清晰度 (Mandibular Jawline Tightening / `jawlineTighten`):
///    Tightens soft tissue along the mandibular margin, reducing submental sagging and carving a crisp jawline (0.0 to 1.0).
/// 6. 下巴微光立体修容 (Chin 3D Highlight & Submental Micro-Shading / `chinContour`):
///    Renders specular highlight on the chin button (Red channel) and subtle submental shadow along the inferior jawline (Green channel) (0.0 to 1.0).
///
/// 100% offline, zero external model weights, Core Image GPU & Metal accelerated via WarpField deformation.
public enum JawChinReshapeEngine {

    // MARK: - Shader Kernels

    private static let chin3DContourKernelSource = """
    kernel vec4 chin3DContourKernel(
        sampler src,
        sampler guide,
        vec4 params // x: highlightStrength, y: shadowStrength, zw: reserved
    ) {
        vec4 c = sample(src, samplerCoord(src));
        vec4 g = sample(guide, samplerCoord(guide));
        vec3 col = c.rgb;

        float hl = g.r * params.x;
        float sh = g.g * params.y;

        // Specular highlight: subtle natural pearlescent chin button glow
        if (hl > 0.001) {
            col += vec3(hl * 0.15);
        }
        // Micro-shadow: subtle deepening of submental crease and mandibular inferior border
        if (sh > 0.001) {
            col *= (1.0 - sh * 0.12);
        }

        // R3 (2026-11-14): pixels outside this module's guides pass through
        // unchanged. The engine works in extended-linear-sRGB, where highlights
        // above 1.0 are legitimate; the unconditional clamp used to clip every
        // highlight in the photograph whenever the slider was non-zero.
        if (hl <= 0.001 && sh <= 0.001) { return c; }
        return vec4(clamp(col, 0.0, 1.0), c.a);
    }
    """

    private static let chin3DContourKernel: CIColorKernel? = {
        CIColorKernel(source: chin3DContourKernelSource)
    }()

    // MARK: - Public API

    /// Applies jawline sculpting, chin reshaping, and 3D contouring to all detected faces.
    public static func apply(
        to image: CIImage,
        faces: [FaceLandmarkSet],
        settings: JawChinReshapeSettings
    ) -> (image: CIImage, report: JawChinReshapeReport) {
        guard settings.enabled, !settings.isNeutral, !faces.isEmpty else {
            return (image, JawChinReshapeReport(applied: false, faceCount: 0, note: nil))
        }

        let startTime = Date().timeIntervalSinceReferenceDate
        let usableFaces = faces.filter { $0.hasUsableGeometry && !$0.faceContour.isEmpty }
        guard !usableFaces.isEmpty else {
            return (image, JawChinReshapeReport(applied: false, faceCount: 0, note: "未检测到可用人脸轮廓关键点。"))
        }

        var working = image

        // 1. Warp Field for jaw width, chin length, projection, shape & jawline tighten
        let field = generateWarpField(
            faces: usableFaces,
            settings: settings,
            imageSize: working.extent.size
        )
        if !field.isIdentity {
            do {
                working = try field.apply(to: working)
            } catch {
                // If warp fails, keep working image as fallback
            }
        }

        // 2. 3D Specular Highlight & Submental Micro-Shading
        if settings.chinContour > 0.001, let kernel = chin3DContourKernel {
            let guide = makeChin3DGuideMask(faces: usableFaces, extent: working.extent)
            let params = CIVector(
                x: CGFloat(settings.chinContour),
                y: CGFloat(settings.chinContour * 0.85),
                z: 0,
                w: 0
            )
            if let shaded = kernel.apply(
                extent: working.extent,
                roiCallback: { _, rect in rect },
                arguments: [working, guide, params]
            ) {
                working = shaded.cropped(to: working.extent)
            }
        }

        let elapsed = Date().timeIntervalSinceReferenceDate - startTime
        let report = JawChinReshapeReport(
            applied: true,
            faceCount: usableFaces.count,
            executionTime: elapsed,
            note: "下庭轮廓微雕处理完成（\(usableFaces.count) 人）。"
        )
        return (working, report)
    }

    /// Applies per-person jawline and chin reshaping with optional face mask.
    public static func applyPerPerson(
        to image: CIImage,
        face: FaceLandmarkSet,
        faceIndex: Int,
        settings: JawChinReshapeSettings,
        perFaceMask: FaceSemanticMaskSet? = nil
    ) -> (image: CIImage, report: JawChinReshapeReport) {
        guard settings.enabled, !settings.isNeutral,
              face.hasUsableGeometry, !face.faceContour.isEmpty else {
            return (image, JawChinReshapeReport(applied: false, faceCount: 0, note: "人脸 \(faceIndex + 1) 未启用或参数中性。"))
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
                // Keep working image
            }
        }

        if settings.chinContour > 0.001, let kernel = chin3DContourKernel {
            let guide = makeChin3DGuideMask(faces: [face], extent: image.extent)
            let params = CIVector(
                x: CGFloat(settings.chinContour),
                y: CGFloat(settings.chinContour * 0.85),
                z: 0,
                w: 0
            )
            if let shaded = kernel.apply(
                extent: image.extent,
                roiCallback: { _, rect in rect },
                arguments: [working, guide, params]
            ) {
                working = shaded.cropped(to: image.extent)
            }
        }

        let elapsed = Date().timeIntervalSinceReferenceDate - startTime
        let report = JawChinReshapeReport(
            applied: true,
            faceCount: 1,
            executionTime: elapsed,
            note: nil
        )
        return (working, report)
    }

    // MARK: - Warp Field Construction

    /// Generates the combined WarpField for jaw and chin reshaping.
    public static func generateWarpField(
        faces: [FaceLandmarkSet],
        settings: JawChinReshapeSettings,
        imageSize: CGSize,
        resolution: Int = WarpField.defaultResolution
    ) -> WarpField {
        var field = WarpField(columns: resolution, rows: resolution)
        guard imageSize.width > 1, imageSize.height > 1, !settings.isNeutral else {
            return field
        }

        for face in faces {
            guard let geometry = JawChinGeometry(face: face, imageSize: imageSize) else { continue }
            addJawChinControls(to: &field, geometry: geometry, settings: settings, imageSize: imageSize)

            // Protected bounding box around lower face
            var protectedRect = geometry.boundingBox
            protectedRect = protectedRect.insetBy(
                dx: -geometry.boundingBox.width * 0.25,
                dy: -geometry.boundingBox.height * 0.25
            )
            let feather = max(Double(geometry.boundingBox.width), Double(geometry.boundingBox.height)) * 0.30
            field.attenuateOutside(rect: protectedRect, feather: feather)
        }

        field.smooth(passes: 2)
        field.clampMagnitude()
        return field
    }

    private static func addJawChinControls(
        to field: inout WarpField,
        geometry: JawChinGeometry,
        settings: JawChinReshapeSettings,
        imageSize: CGSize
    ) {
        let fw = geometry.faceWidth
        let fh = geometry.faceHeight
        let jw = geometry.jawWidth

        // 1. 下颌角收窄与折角微雕 (jawWidth: -0.5...0.5)
        // 负值向内收拢双侧下颌角（dx > 0 针对左下颌角，dx < 0 针对右下颌角）
        if abs(settings.jawWidth) > 0.0001 {
            let jawDeltaX = -settings.jawWidth * fw * 0.16
            let rx = jw * 0.36
            let ry = fh * 0.20

            // 左下颌角（图像左侧）：向内位移为正 dx
            field.addGaussian(
                center: geometry.leftJawAngle,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(jawDeltaX, 0),
                falloff: .cosine
            )
            // 右下颌角（图像右侧）：向内位移为负 dx
            field.addGaussian(
                center: geometry.rightJawAngle,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(-jawDeltaX, 0),
                falloff: .cosine
            )
        }

        // 2. 下巴长度调节 (chinLength: -0.5...0.5)
        // 负值缩短下巴（向上移 dy > 0），正值拉长下巴（向下移 dy < 0）
        if abs(settings.chinLength) > 0.0001 {
            let lenDy = -settings.chinLength * fh * 0.18
            let rx = jw * 0.32
            let ry = fh * 0.16

            field.addGaussian(
                center: geometry.chinTip,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(0, lenDy),
                falloff: .gaussian
            )
        }

        // 3. 下巴翘度微调（向前立体感） (chinProjection: -0.5...0.5)
        // 正值提升翘度（轻微向上提拉颏部并向中轴微收）
        if abs(settings.chinProjection) > 0.0001 {
            let projDy = settings.chinProjection * fh * 0.10
            let rx = jw * 0.26
            let ry = fh * 0.14

            let projCenter = CGPoint(
                x: geometry.chinTip.x,
                y: geometry.chinTip.y + CGFloat(geometry.faceHeight * 0.03)
            )
            field.addGaussian(
                center: projCenter,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(0, projDy),
                falloff: .cosine
            )
        }

        // 4. 下巴形态微雕 (chinShape: -0.5...0.5)
        // 负值收尖打造 V 脸瓜子下巴（颏部两侧向中心向内收拢），正值圆润饱满化下巴
        if abs(settings.chinShape) > 0.0001 {
            let shapeDx = -settings.chinShape * fw * 0.12
            let rx = jw * 0.22
            let ry = fh * 0.13

            let leftChinPt = CGPoint(
                x: geometry.chinTip.x - CGFloat(geometry.jawWidth * 0.14),
                y: geometry.chinTip.y + CGFloat(geometry.faceHeight * 0.03)
            )
            let rightChinPt = CGPoint(
                x: geometry.chinTip.x + CGFloat(geometry.jawWidth * 0.14),
                y: geometry.chinTip.y + CGFloat(geometry.faceHeight * 0.03)
            )

            // 左侧下巴坡面向中心内收 (shapeDx > 0 为向右内收)
            field.addGaussian(
                center: leftChinPt,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(shapeDx, 0),
                falloff: .cosine
            )
            // 右侧下巴坡面向中心内收 (-shapeDx 为向左内收)
            field.addGaussian(
                center: rightChinPt,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(-shapeDx, 0),
                falloff: .cosine
            )
        }

        // 5. 下颌缘紧致与线条清晰度 (jawlineTighten: 0.0...1.0)
        // 沿下颌骨边缘向心斜向提拉
        if settings.jawlineTighten > 0.0001 {
            let tightenStrength = settings.jawlineTighten * fw * 0.09
            let rx = jw * 0.28
            let ry = fh * 0.15

            // 左下颌缘中段：向右上方内收 (dx > 0, dy > 0)
            field.addGaussian(
                center: geometry.leftMandibleMid,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(tightenStrength * 0.70, tightenStrength * 0.50),
                falloff: .cosine
            )
            // 右下颌缘中段：向左上方内收 (dx < 0, dy > 0)
            field.addGaussian(
                center: geometry.rightMandibleMid,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(-tightenStrength * 0.70, tightenStrength * 0.50),
                falloff: .cosine
            )
        }
    }

    // MARK: - 3D Contour Guide Mask

    /// Renders specular chin highlight (Red channel) and submental micro-shading (Green channel).
    public static func makeChin3DGuideMask(
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
            guard let geometry = JawChinGeometry(face: face, imageSize: extent.size) else { continue }
            renderSingleFaceChin3DGuide(geometry: geometry, in: ctx, extent: extent)
        }

        guard let cgImg = ctx.makeImage() else { return makeTransparentImage(extent: extent) }
        let rawMask = CIImage(cgImage: cgImg)
        let blurRadius = max(1.5, extent.height * 0.005)
        return rawMask.clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }

    private static func renderSingleFaceChin3DGuide(
        geometry: JawChinGeometry,
        in ctx: CGContext,
        extent: CGRect
    ) {
        let fw = geometry.faceWidth * extent.width
        let fh = geometry.faceHeight * extent.height
        let jw = geometry.jawWidth * extent.width

        let chinPt = CGPoint(
            x: geometry.chinTip.x * extent.width,
            y: (geometry.chinTip.y + CGFloat(geometry.faceHeight * 0.04)) * extent.height
        )

        // 1. 颏部高光斑 (Red channel)
        ctx.saveGState()
        ctx.setFillColor(red: 1.0, green: 0, blue: 0, alpha: 0.90)
        let highlightRadiusX = max(3.0, jw * 0.14)
        let highlightRadiusY = max(2.5, fh * 0.05)
        ctx.fillEllipse(in: CGRect(
            x: chinPt.x - highlightRadiusX,
            y: chinPt.y - highlightRadiusY,
            width: highlightRadiusX * 2,
            height: highlightRadiusY * 2
        ))
        ctx.restoreGState()

        // 2. 颏下缘与双侧下颌微阴影 (Green channel)
        ctx.saveGState()
        ctx.setStrokeColor(red: 0, green: 1.0, blue: 0, alpha: 0.85)
        ctx.setLineWidth(max(2.0, fw * 0.04))
        ctx.setLineCap(.round)

        let leftJaw = CGPoint(x: geometry.leftJawAngle.x * extent.width,
                              y: geometry.leftJawAngle.y * extent.height)
        let rightJaw = CGPoint(x: geometry.rightJawAngle.x * extent.width,
                               y: geometry.rightJawAngle.y * extent.height)
        let submental = CGPoint(x: geometry.submental.x * extent.width,
                                y: geometry.submental.y * extent.height)

        ctx.beginPath()
        ctx.move(to: CGPoint(x: leftJaw.x + (submental.x - leftJaw.x) * 0.25,
                             y: leftJaw.y - fh * 0.02))
        ctx.addQuadCurve(to: CGPoint(x: rightJaw.x - (rightJaw.x - submental.x) * 0.25,
                                    y: rightJaw.y - fh * 0.02),
                         control: submental)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func makeTransparentImage(extent: CGRect) -> CIImage {
        CIImage(color: .clear).cropped(to: extent)
    }
}

// MARK: - Internal Jaw & Chin Geometry

public struct JawChinGeometry: Equatable {
    public var boundingBox: CGRect
    public var chinTip: CGPoint
    public var leftJawAngle: CGPoint
    public var rightJawAngle: CGPoint
    public var leftMandibleMid: CGPoint
    public var rightMandibleMid: CGPoint
    public var submental: CGPoint
    public var faceWidth: Double
    public var faceHeight: Double
    public var jawWidth: Double

    public init?(face: FaceLandmarkSet, imageSize: CGSize) {
        guard face.hasUsableGeometry else { return nil }
        self.boundingBox = face.boundingBox

        let validContour = face.faceContour.filter { $0.x.isFinite && $0.y.isFinite }
        let box = face.boundingBox

        let fw = max(0.02, Double(box.width))
        let fh = max(0.02, Double(box.height))

        let detectedChin: CGPoint
        if let minPt = validContour.min(by: { $0.y < $1.y }) {
            detectedChin = minPt
        } else {
            detectedChin = CGPoint(x: box.midX, y: box.minY + box.height * 0.05)
        }
        self.chinTip = detectedChin

        // Find jaw angles along contour or fall back to geometric bounds
        let leftCandidates = validContour.filter { $0.x < box.midX && $0.y <= box.minY + box.height * 0.45 }
        let rightCandidates = validContour.filter { $0.x > box.midX && $0.y <= box.minY + box.height * 0.45 }

        let leftAngle = leftCandidates.min(by: { $0.x < $1.x }) ??
            CGPoint(x: box.minX + box.width * 0.10, y: detectedChin.y + CGFloat(fh * 0.28))
        let rightAngle = rightCandidates.max(by: { $0.x < $1.x }) ??
            CGPoint(x: box.maxX - box.width * 0.10, y: detectedChin.y + CGFloat(fh * 0.28))

        self.leftJawAngle = leftAngle
        self.rightJawAngle = rightAngle

        self.leftMandibleMid = CGPoint(
            x: (leftAngle.x + detectedChin.x) * 0.5,
            y: (leftAngle.y + detectedChin.y) * 0.5
        )
        self.rightMandibleMid = CGPoint(
            x: (rightAngle.x + detectedChin.x) * 0.5,
            y: (rightAngle.y + detectedChin.y) * 0.5
        )

        let subY = detectedChin.y - max(0.008, CGFloat(fh * 0.06))
        self.submental = CGPoint(x: detectedChin.x, y: subY)

        self.faceWidth = fw
        self.faceHeight = fh
        self.jawWidth = max(0.03, Double(rightAngle.x - leftAngle.x))
    }
}

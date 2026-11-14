import CoreGraphics
import CoreImage
import Foundation

// MARK: - Eyebrow Reshape Engine

/// P2-Y: Smart eyebrow reshaping, wild brow hair-stroke texture & symmetry calibration engine.
///
/// Features:
/// 1. 眉尾高度与走势提拉 (Eyebrow Tail Lift / `browTailLift`):
///    Vertically raises or lowers the lateral eyebrow tails to eliminate droopy/sad eyebrows (-0.5 to +0.5).
/// 2. 眉毛粗细饱满度微调 (Eyebrow Thickness Modulation / `browThickness`):
///    Expands or slenderizes eyebrow thickness for a balanced, full brow arch (-0.5 to +0.5).
/// 3. 眉身长度与眉梢延展 (Eyebrow Length & Tail Extension / `browLength`):
///    Extends or shortens eyebrow length along natural facial proportions (-0.5 to +0.5).
/// 4. 双眉对称性智能校准 (Bilateral Eyebrow Symmetry Calibration / `browSymmetry`):
///    Harmonizes bilateral eyebrow height, tilt, and arch disparity towards symmetrical balance (0.0 to 1.0).
/// 5. 根根分明野生眉毛流感与密度充盈 (Wild Brow Hair-Stroke Texture & Density / `wildBrowTexture`):
///    Enhances micro-contrast and hair-stroke definition, filling sparse gaps for natural feathery wild brows (0.0 to 1.0).
/// 6. 眉骨 3D 立体高光与眉下阴影 (Brow Bone 3D Highlight & Sub-Brow Shading / `brow3DContour`):
///    Renders 3D diffuse highlight on the brow ridge (Red channel) and subtle micro-shadow in the sub-brow socket (Green channel) (0.0 to 1.0).
///
/// 100% offline, zero external model weights, Core Image GPU & Metal accelerated via WarpField deformation.
public enum EyebrowReshapeEngine {

    // MARK: - Shader Kernels

    private static let eyebrowReshapeKernelSource = """
    kernel vec4 eyebrowReshapeKernel(
        sampler src,
        sampler guide,
        vec4 params // x: highlightStrength, y: shadowStrength, z: wildBrowTexture, w: reserved
    ) {
        vec4 c = sample(src, samplerCoord(src));
        vec4 g = sample(guide, samplerCoord(guide));
        vec3 col = c.rgb;

        float hl = g.r * params.x;
        float sh = g.g * params.y;
        float wb = g.b * params.z;

        // 1. Brow bone 3D highlight (Red channel): +15% pearlescent diffuse lift
        if (hl > 0.001) {
            col += vec3(hl * 0.15);
        }
        // 2. Sub-brow orbital socket micro-shadow (Green channel): -12% deep-set shading
        if (sh > 0.001) {
            col *= (1.0 - sh * 0.12);
        }
        // 3. Wild brow hair-stroke micro-contrast (Blue channel): enhances hair density & micro-fibers
        if (wb > 0.001) {
            float luma = dot(col, vec3(0.299, 0.587, 0.114));
            float darkening = (1.0 - luma) * 0.18 + 0.04;
            col = mix(col, col * (1.0 - darkening), wb);
        }

        // R3 (2026-11-14): pixels outside the brow guides pass through unchanged.
        // The engine works in extended-linear-sRGB, where highlights above 1.0
        // are legitimate; an unconditional clamp clipped the whole photograph's
        // highlights whenever this pass was enabled.
        if (hl <= 0.001 && sh <= 0.001 && wb <= 0.001) { return c; }
        return vec4(clamp(col, 0.0, 1.0), c.a);
    }
    """

    private static let eyebrowReshapeKernel: CIColorKernel? = {
        CIColorKernel(source: eyebrowReshapeKernelSource)
    }()

    // MARK: - Public API

    /// Applies eyebrow reshaping, wild brow texture, and 3D contouring to all detected faces.
    public static func apply(
        to image: CIImage,
        faces: [FaceLandmarkSet],
        settings: EyebrowReshapeSettings
    ) -> (image: CIImage, report: EyebrowReshapeReport) {
        guard settings.enabled, !settings.isNeutral, !faces.isEmpty else {
            return (image, EyebrowReshapeReport(applied: false, faceCount: 0, note: nil))
        }

        let startTime = Date().timeIntervalSinceReferenceDate
        let usableFaces = faces.filter { $0.hasUsableGeometry }
        guard !usableFaces.isEmpty else {
            return (image, EyebrowReshapeReport(applied: false, faceCount: 0, note: "未检测到可用人脸眉毛关键点。"))
        }

        var working = image

        // 1. Warp Field for eyebrow tail lift, thickness, length & symmetry
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

        // 2. Wild brow texture & 3D Brow Ridge Highlight / Sub-Brow Shading
        let hasTextureOrShading = settings.wildBrowTexture > 0.001 || settings.brow3DContour > 0.001
        if hasTextureOrShading, let kernel = eyebrowReshapeKernel {
            let guide = makeEyebrowGuideMask(faces: usableFaces, extent: working.extent)
            let params = CIVector(
                x: CGFloat(settings.brow3DContour),
                y: CGFloat(settings.brow3DContour * 0.85),
                z: CGFloat(settings.wildBrowTexture),
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
        let report = EyebrowReshapeReport(
            applied: true,
            faceCount: usableFaces.count,
            executionTime: elapsed,
            note: "眉部微雕处理完成（\(usableFaces.count) 人）。"
        )
        return (working, report)
    }

    /// Applies per-person eyebrow reshaping and texture enhancement with optional face mask.
    public static func applyPerPerson(
        to image: CIImage,
        face: FaceLandmarkSet,
        faceIndex: Int,
        settings: EyebrowReshapeSettings,
        perFaceMask: FaceSemanticMaskSet? = nil
    ) -> (image: CIImage, report: EyebrowReshapeReport) {
        guard settings.enabled, !settings.isNeutral, face.hasUsableGeometry else {
            return (image, EyebrowReshapeReport(applied: false, faceCount: 0, note: "人脸 \(faceIndex + 1) 未启用或参数中性。"))
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

        let hasTextureOrShading = settings.wildBrowTexture > 0.001 || settings.brow3DContour > 0.001
        if hasTextureOrShading, let kernel = eyebrowReshapeKernel {
            let guide = makeEyebrowGuideMask(faces: [face], extent: image.extent)
            let params = CIVector(
                x: CGFloat(settings.brow3DContour),
                y: CGFloat(settings.brow3DContour * 0.85),
                z: CGFloat(settings.wildBrowTexture),
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
        let report = EyebrowReshapeReport(
            applied: true,
            faceCount: 1,
            executionTime: elapsed,
            note: nil
        )
        return (working, report)
    }

    // MARK: - Warp Field Construction

    /// Generates the combined WarpField for eyebrow reshaping.
    public static func generateWarpField(
        faces: [FaceLandmarkSet],
        settings: EyebrowReshapeSettings,
        imageSize: CGSize,
        resolution: Int = WarpField.defaultResolution
    ) -> WarpField {
        var field = WarpField(columns: resolution, rows: resolution)
        guard imageSize.width > 1, imageSize.height > 1, !settings.isNeutral else {
            return field
        }

        for face in faces {
            guard let geometry = EyebrowGeometry(face: face, imageSize: imageSize) else { continue }
            addEyebrowControls(to: &field, geometry: geometry, settings: settings, imageSize: imageSize)

            // Protected bounding box around upper face / eye-brow region
            var protectedRect = geometry.boundingBox
            protectedRect = protectedRect.insetBy(
                dx: -geometry.boundingBox.width * 0.20,
                dy: -geometry.boundingBox.height * 0.20
            )
            let feather = max(Double(geometry.boundingBox.width), Double(geometry.boundingBox.height)) * 0.25
            field.attenuateOutside(rect: protectedRect, feather: feather)
        }

        field.smooth(passes: 2)
        field.clampMagnitude()
        return field
    }

    private static func addEyebrowControls(
        to field: inout WarpField,
        geometry: EyebrowGeometry,
        settings: EyebrowReshapeSettings,
        imageSize: CGSize
    ) {
        let fw = geometry.faceWidth
        let fh = geometry.faceHeight
        let bw = geometry.leftBrowWidth

        // 1. 眉尾高度与走势提拉 (browTailLift: -0.5...0.5)
        // 正值向上提拉眉尾消除下垂八字眉，负值舒缓过于上挑的眉毛
        if abs(settings.browTailLift) > 0.0001 {
            let tailLiftDy = settings.browTailLift * fh * 0.12
            let rx = bw * 0.45
            let ry = fh * 0.09

            field.addGaussian(
                center: geometry.leftTail,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(0, tailLiftDy),
                falloff: .cosine
            )
            field.addGaussian(
                center: geometry.rightTail,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(0, tailLiftDy),
                falloff: .cosine
            )
        }

        // 2. 眉毛粗细饱满度微调 (browThickness: -0.5...0.5)
        // 正值增粗饱满细弱眉毛，负值纤细化浓粗生硬眉毛
        if abs(settings.browThickness) > 0.0001 {
            let thickDy = settings.browThickness * fh * 0.07
            let rx = bw * 0.50
            let ry = fh * 0.08

            // 上边缘向上扩展
            field.addGaussian(
                center: CGPoint(x: geometry.leftArch.x, y: geometry.leftArch.y + CGFloat(fh * 0.02)),
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(0, thickDy),
                falloff: .cosine
            )
            // 下边缘向下扩展
            field.addGaussian(
                center: CGPoint(x: geometry.leftArch.x, y: geometry.leftArch.y - CGFloat(fh * 0.02)),
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(0, -thickDy),
                falloff: .cosine
            )

            // 右眉同理
            field.addGaussian(
                center: CGPoint(x: geometry.rightArch.x, y: geometry.rightArch.y + CGFloat(fh * 0.02)),
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(0, thickDy),
                falloff: .cosine
            )
            field.addGaussian(
                center: CGPoint(x: geometry.rightArch.x, y: geometry.rightArch.y - CGFloat(fh * 0.02)),
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(0, -thickDy),
                falloff: .cosine
            )
        }

        // 3. 眉身长度与眉梢延展 (browLength: -0.5...0.5)
        // 正值向外延展短眉眉梢，负值适度收敛短眉梢
        if abs(settings.browLength) > 0.0001 {
            let lenDx = settings.browLength * fw * 0.08
            let rx = bw * 0.40
            let ry = fh * 0.08

            // 左眉梢向左延展 (-dx)
            field.addGaussian(
                center: geometry.leftTail,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(-lenDx, -lenDx * 0.25),
                falloff: .cosine
            )
            // 右眉梢向右延展 (+dx)
            field.addGaussian(
                center: geometry.rightTail,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(lenDx, -lenDx * 0.25),
                falloff: .cosine
            )
        }

        // 4. 双眉对称性智能校准 (browSymmetry: 0.0...1.0)
        // 自动将双侧眉毛向对称中位线插值
        if settings.browSymmetry > 0.0001 {
            let meanArchY = (geometry.leftArch.y + geometry.rightArch.y) * 0.5
            let meanTailY = (geometry.leftTail.y + geometry.rightTail.y) * 0.5

            let leftArchDeltaY = (meanArchY - geometry.leftArch.y) * settings.browSymmetry
            let rightArchDeltaY = (meanArchY - geometry.rightArch.y) * settings.browSymmetry

            let leftTailDeltaY = (meanTailY - geometry.leftTail.y) * settings.browSymmetry
            let rightTailDeltaY = (meanTailY - geometry.rightTail.y) * settings.browSymmetry

            let rx = bw * 0.45
            let ry = fh * 0.09

            field.addGaussian(
                center: geometry.leftArch,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(0, leftArchDeltaY),
                falloff: .cosine
            )
            field.addGaussian(
                center: geometry.rightArch,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(0, rightArchDeltaY),
                falloff: .cosine
            )

            field.addGaussian(
                center: geometry.leftTail,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(0, leftTailDeltaY),
                falloff: .cosine
            )
            field.addGaussian(
                center: geometry.rightTail,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(0, rightTailDeltaY),
                falloff: .cosine
            )
        }
    }

    // MARK: - 3D Contour & Texture Guide Mask

    /// Renders brow bone highlight (Red), sub-brow socket shadow (Green), and wild brow hair stroke mask (Blue).
    public static func makeEyebrowGuideMask(
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
            guard let geometry = EyebrowGeometry(face: face, imageSize: extent.size) else { continue }
            renderSingleFaceEyebrowGuide(geometry: geometry, in: ctx, extent: extent)
        }

        guard let cgImg = ctx.makeImage() else { return makeTransparentImage(extent: extent) }
        let rawMask = CIImage(cgImage: cgImg)
        let blurRadius = max(1.5, extent.height * 0.005)
        return rawMask.clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }

    private static func renderSingleFaceEyebrowGuide(
        geometry: EyebrowGeometry,
        in ctx: CGContext,
        extent: CGRect
    ) {
        let fw = geometry.faceWidth * extent.width
        let fh = geometry.faceHeight * extent.height
        let bw = geometry.leftBrowWidth * extent.width

        let leftArch = CGPoint(x: geometry.leftArch.x * extent.width, y: geometry.leftArch.y * extent.height)
        let leftTail = CGPoint(x: geometry.leftTail.x * extent.width, y: geometry.leftTail.y * extent.height)
        let leftHead = CGPoint(x: geometry.leftHead.x * extent.width, y: geometry.leftHead.y * extent.height)

        let rightArch = CGPoint(x: geometry.rightArch.x * extent.width, y: geometry.rightArch.y * extent.height)
        let rightTail = CGPoint(x: geometry.rightTail.x * extent.width, y: geometry.rightTail.y * extent.height)
        let rightHead = CGPoint(x: geometry.rightHead.x * extent.width, y: geometry.rightHead.y * extent.height)

        // 1. 眉弓骨 3D 柔光立体高光 (Red channel)
        ctx.saveGState()
        ctx.setFillColor(red: 1.0, green: 0, blue: 0, alpha: 0.90)
        let hlRadiusX = max(3.0, bw * 0.22)
        let hlRadiusY = max(2.0, fh * 0.035)

        // 左眉骨迎光高光点（略偏外上方）
        let leftHL = CGPoint(x: leftArch.x - bw * 0.10, y: leftArch.y + fh * 0.02)
        ctx.fillEllipse(in: CGRect(
            x: leftHL.x - hlRadiusX, y: leftHL.y - hlRadiusY,
            width: hlRadiusX * 2, height: hlRadiusY * 2
        ))

        // 右眉骨迎光高光点
        let rightHL = CGPoint(x: rightArch.x + bw * 0.10, y: rightArch.y + fh * 0.02)
        ctx.fillEllipse(in: CGRect(
            x: rightHL.x - hlRadiusX, y: rightHL.y - hlRadiusY,
            width: hlRadiusX * 2, height: hlRadiusY * 2
        ))
        ctx.restoreGState()

        // 2. 眉下眼窝微修容阴影 (Green channel)
        ctx.saveGState()
        ctx.setStrokeColor(red: 0, green: 1.0, blue: 0, alpha: 0.85)
        ctx.setLineWidth(max(2.0, fw * 0.03))
        ctx.setLineCap(.round)

        // 左眉下方走廊
        ctx.beginPath()
        ctx.move(to: CGPoint(x: leftHead.x, y: leftHead.y - fh * 0.03))
        ctx.addQuadCurve(
            to: CGPoint(x: leftTail.x, y: leftTail.y - fh * 0.02),
            control: CGPoint(x: leftArch.x, y: leftArch.y - fh * 0.035)
        )
        ctx.strokePath()

        // 右眉下方走廊
        ctx.beginPath()
        ctx.move(to: CGPoint(x: rightHead.x, y: rightHead.y - fh * 0.03))
        ctx.addQuadCurve(
            to: CGPoint(x: rightTail.x, y: rightTail.y - fh * 0.02),
            control: CGPoint(x: rightArch.x, y: rightArch.y - fh * 0.035)
        )
        ctx.strokePath()
        ctx.restoreGState()

        // 3. 野生眉毛流纹理强化带 (Blue channel)
        ctx.saveGState()
        ctx.setStrokeColor(red: 0, green: 0, blue: 1.0, alpha: 0.88)
        ctx.setLineWidth(max(2.5, fw * 0.04))
        ctx.setLineCap(.round)

        // 左眉中轴线
        ctx.beginPath()
        ctx.move(to: leftHead)
        ctx.addQuadCurve(to: leftTail, control: leftArch)
        ctx.strokePath()

        // 右眉中轴线
        ctx.beginPath()
        ctx.move(to: rightHead)
        ctx.addQuadCurve(to: rightTail, control: rightArch)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func makeTransparentImage(extent: CGRect) -> CIImage {
        CIImage(color: .clear).cropped(to: extent)
    }
}

// MARK: - Internal Eyebrow Geometry

public struct EyebrowGeometry: Equatable {
    public var boundingBox: CGRect
    public var leftHead: CGPoint
    public var leftArch: CGPoint
    public var leftTail: CGPoint
    public var rightHead: CGPoint
    public var rightArch: CGPoint
    public var rightTail: CGPoint
    public var faceWidth: Double
    public var faceHeight: Double
    public var leftBrowWidth: Double
    public var rightBrowWidth: Double

    public init?(face: FaceLandmarkSet, imageSize: CGSize) {
        guard face.hasUsableGeometry else { return nil }
        self.boundingBox = face.boundingBox
        let box = face.boundingBox

        let fw = max(0.02, Double(box.width))
        let fh = max(0.02, Double(box.height))

        let validLeftBrow = face.leftEyebrow.filter { $0.x.isFinite && $0.y.isFinite }
        let validRightBrow = face.rightEyebrow.filter { $0.x.isFinite && $0.y.isFinite }

        // Left Eyebrow (Image Left: smaller X)
        if !validLeftBrow.isEmpty {
            // Head is medial (largest X), Tail is lateral (smallest X), Arch is peak (largest Y)
            self.leftHead = validLeftBrow.max(by: { $0.x < $1.x }) ??
                CGPoint(x: box.minX + box.width * 0.42, y: box.minY + box.height * 0.70)
            self.leftTail = validLeftBrow.min(by: { $0.x < $1.x }) ??
                CGPoint(x: box.minX + box.width * 0.18, y: box.minY + box.height * 0.68)
            self.leftArch = validLeftBrow.max(by: { $0.y < $1.y }) ??
                CGPoint(x: box.minX + box.width * 0.28, y: box.minY + box.height * 0.73)
        } else {
            self.leftHead = CGPoint(x: box.minX + box.width * 0.42, y: box.minY + box.height * 0.70)
            self.leftArch = CGPoint(x: box.minX + box.width * 0.28, y: box.minY + box.height * 0.73)
            self.leftTail = CGPoint(x: box.minX + box.width * 0.18, y: box.minY + box.height * 0.68)
        }

        // Right Eyebrow (Image Right: larger X)
        if !validRightBrow.isEmpty {
            // Head is medial (smallest X), Tail is lateral (largest X), Arch is peak (largest Y)
            self.rightHead = validRightBrow.min(by: { $0.x < $1.x }) ??
                CGPoint(x: box.maxX - box.width * 0.42, y: box.minY + box.height * 0.70)
            self.rightTail = validRightBrow.max(by: { $0.x < $1.x }) ??
                CGPoint(x: box.maxX - box.width * 0.18, y: box.minY + box.height * 0.68)
            self.rightArch = validRightBrow.max(by: { $0.y < $1.y }) ??
                CGPoint(x: box.maxX - box.width * 0.28, y: box.minY + box.height * 0.73)
        } else {
            self.rightHead = CGPoint(x: box.maxX - box.width * 0.42, y: box.minY + box.height * 0.70)
            self.rightArch = CGPoint(x: box.maxX - box.width * 0.28, y: box.minY + box.height * 0.73)
            self.rightTail = CGPoint(x: box.maxX - box.width * 0.18, y: box.minY + box.height * 0.68)
        }

        self.faceWidth = fw
        self.faceHeight = fh
        self.leftBrowWidth = max(0.02, Double(abs(leftHead.x - leftTail.x)))
        self.rightBrowWidth = max(0.02, Double(abs(rightTail.x - rightHead.x)))
    }
}

import CoreGraphics
import CoreImage
import Foundation

// MARK: - Facial Contour Engine

/// P2-X: Smart temples, cheekbones & facial contour smoothness micro-sculpting engine.
///
/// Features:
/// 1. 太阳穴凹陷饱满化充盈 (Temple Plump & Upper Lateral Volume / `templePlump`):
///    Horizontally plumps sunken bilateral temporal fossa outward (0.0 to 1.0).
/// 2. 颧骨突出与外扩内推平滑 (Cheekbone & Zygoma Narrowing / `cheekboneNarrow`):
///    Inward narrowing and compression of wide or prominent zygomatic arches (0.0 to 1.0).
/// 3. 面颊凹陷丰盈与胶原蛋白感 (Buccal Hollow & Cheek Plumping / `cheekPlump`):
///    Fills sunken buccal / sub-zygomatic hollows outward to restore youthful collagen (0.0 to 1.0).
/// 4. 面部外轮廓波折平滑度调和 (Facial Contour Curvature Smoothness / `contourSmoothness`):
///    Eliminates contour waves and step-like curvature transitions along temples, zygoma, and cheeks (0.0 to 1.0).
/// 5. 苹果肌立体微雕与提拉 (Apple Cheek Fullness & Vertical Lift / `appleCheekLift`):
///    Vertical positioning and perkiness of malar fat pads (-0.5 to +0.5).
/// 6. 面部外轮廓柔光立体光影 (Facial Contour 3D Highlight & Lateral Shading / `contour3DShading`):
///    Renders 3D diffuse highlight on apple cheek summits (Red channel) and micro-shadow along lateral zygomatic border & temples (Green channel) (0.0 to 1.0).
///
/// 100% offline, zero external model weights, Core Image GPU & Metal accelerated via WarpField deformation.
public enum FacialContourEngine {

    // MARK: - Shader Kernels

    private static let facialContour3DShadingKernelSource = """
    kernel vec4 facialContour3DShadingKernel(
        sampler src,
        sampler guide,
        vec4 params // x: highlightStrength, y: shadowStrength, zw: reserved
    ) {
        vec4 c = sample(src, samplerCoord(src));
        vec4 g = sample(guide, samplerCoord(guide));
        vec3 col = c.rgb;

        float hl = g.r * params.x;
        float sh = g.g * params.y;

        // Apple cheek specular highlight (Red channel): +14% diffuse pearlescence
        if (hl > 0.001) {
            col += vec3(hl * 0.14);
        }
        // Lateral zygoma & temple micro-shadow (Green channel): -12% contour shading
        if (sh > 0.001) {
            col *= (1.0 - sh * 0.12);
        }

        return vec4(clamp(col, 0.0, 1.0), c.a);
    }
    """

    private static let facialContour3DShadingKernel: CIColorKernel? = {
        CIColorKernel(source: facialContour3DShadingKernelSource)
    }()

    // MARK: - Public API

    /// Applies temples, cheekbones, and facial contour reshaping to all detected faces.
    public static func apply(
        to image: CIImage,
        faces: [FaceLandmarkSet],
        settings: FacialContourSettings
    ) -> (image: CIImage, report: FacialContourReport) {
        guard settings.enabled, !settings.isNeutral, !faces.isEmpty else {
            return (image, FacialContourReport(applied: false, faceCount: 0, note: nil))
        }

        let startTime = Date().timeIntervalSinceReferenceDate
        let usableFaces = faces.filter { $0.hasUsableGeometry && !$0.faceContour.isEmpty }
        guard !usableFaces.isEmpty else {
            return (image, FacialContourReport(applied: false, faceCount: 0, note: "未检测到可用人脸外轮廓关键点。"))
        }

        var working = image

        // 1. Warp Field for temples, cheekbones, cheek hollows, contour smoothness & apple cheeks
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

        // 2. 3D Apple Cheek Highlight & Lateral Zygomatic Micro-Shading
        if settings.contour3DShading > 0.001, let kernel = facialContour3DShadingKernel {
            let guide = makeContour3DGuideMask(faces: usableFaces, extent: working.extent)
            let params = CIVector(
                x: CGFloat(settings.contour3DShading),
                y: CGFloat(settings.contour3DShading * 0.85),
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
        let report = FacialContourReport(
            applied: true,
            faceCount: usableFaces.count,
            executionTime: elapsed,
            note: "面部外轮廓微雕处理完成（\(usableFaces.count) 人）。"
        )
        return (working, report)
    }

    /// Applies per-person temples, cheekbones, and facial contour reshaping with optional face mask.
    public static func applyPerPerson(
        to image: CIImage,
        face: FaceLandmarkSet,
        faceIndex: Int,
        settings: FacialContourSettings,
        perFaceMask: FaceSemanticMaskSet? = nil
    ) -> (image: CIImage, report: FacialContourReport) {
        guard settings.enabled, !settings.isNeutral,
              face.hasUsableGeometry, !face.faceContour.isEmpty else {
            return (image, FacialContourReport(applied: false, faceCount: 0, note: "人脸 \(faceIndex + 1) 未启用或参数中性。"))
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

        if settings.contour3DShading > 0.001, let kernel = facialContour3DShadingKernel {
            let guide = makeContour3DGuideMask(faces: [face], extent: image.extent)
            let params = CIVector(
                x: CGFloat(settings.contour3DShading),
                y: CGFloat(settings.contour3DShading * 0.85),
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
        let report = FacialContourReport(
            applied: true,
            faceCount: 1,
            executionTime: elapsed,
            note: nil
        )
        return (working, report)
    }

    // MARK: - Warp Field Construction

    /// Generates the combined WarpField for facial contour reshaping.
    public static func generateWarpField(
        faces: [FaceLandmarkSet],
        settings: FacialContourSettings,
        imageSize: CGSize,
        resolution: Int = WarpField.defaultResolution
    ) -> WarpField {
        var field = WarpField(columns: resolution, rows: resolution)
        guard imageSize.width > 1, imageSize.height > 1, !settings.isNeutral else {
            return field
        }

        for face in faces {
            guard let geometry = FacialContourGeometry(face: face, imageSize: imageSize) else { continue }
            addFacialContourControls(to: &field, geometry: geometry, settings: settings, imageSize: imageSize)

            // Protected bounding box around mid and upper face
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

    private static func addFacialContourControls(
        to field: inout WarpField,
        geometry: FacialContourGeometry,
        settings: FacialContourSettings,
        imageSize: CGSize
    ) {
        let fw = geometry.faceWidth
        let fh = geometry.faceHeight
        let zw = geometry.zygomaWidth

        // 1. 太阳穴凹陷饱满化充盈 (templePlump: 0.0...1.0)
        // 向外充盈双侧颞部 (左太阳穴向左 -dx, 右太阳穴向右 +dx)
        if settings.templePlump > 0.0001 {
            let deltaX = settings.templePlump * fw * 0.12
            let rx = zw * 0.28
            let ry = fh * 0.16

            field.addGaussian(
                center: geometry.leftTemple,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(-deltaX, 0),
                falloff: .cosine
            )
            field.addGaussian(
                center: geometry.rightTemple,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(deltaX, 0),
                falloff: .cosine
            )
        }

        // 2. 颧骨突出与外扩内推平滑 (cheekboneNarrow: 0.0...1.0)
        // 向内收拢双侧颧弓最宽处 (左颧骨向右 +dx, 右颧骨向左 -dx)
        if settings.cheekboneNarrow > 0.0001 {
            let deltaX = settings.cheekboneNarrow * fw * 0.14
            let rx = zw * 0.32
            let ry = fh * 0.18

            field.addGaussian(
                center: geometry.leftZygoma,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(deltaX, 0),
                falloff: .cosine
            )
            field.addGaussian(
                center: geometry.rightZygoma,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(-deltaX, 0),
                falloff: .cosine
            )
        }

        // 3. 面颊凹陷丰盈与胶原蛋白感 (cheekPlump: 0.0...1.0)
        // 向外充盈颧下至面颊凹陷 (左面颊向左 -dx, 右面颊向右 +dx)
        if settings.cheekPlump > 0.0001 {
            let deltaX = settings.cheekPlump * fw * 0.12
            let rx = zw * 0.28
            let ry = fh * 0.16

            field.addGaussian(
                center: geometry.leftCheekFossa,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(-deltaX, 0),
                falloff: .cosine
            )
            field.addGaussian(
                center: geometry.rightCheekFossa,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(deltaX, 0),
                falloff: .cosine
            )
        }

        // 4. 面部外轮廓波折平滑度调和 (contourSmoothness: 0.0...1.0)
        // 沿太阳穴-颧弓-面颊消除阶梯状波折，柔化外凸并充盈凹陷
        if settings.contourSmoothness > 0.0001 {
            let smoothness = settings.contourSmoothness * fw * 0.08
            let rx = zw * 0.26
            let ry = fh * 0.15

            // 太阳穴平缓外扩
            field.addGaussian(
                center: geometry.leftTemple,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(-smoothness * 0.50, 0),
                falloff: .cosine
            )
            field.addGaussian(
                center: geometry.rightTemple,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(smoothness * 0.50, 0),
                falloff: .cosine
            )

            // 颧骨轻微内收平滑
            field.addGaussian(
                center: geometry.leftZygoma,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(smoothness * 0.60, 0),
                falloff: .cosine
            )
            field.addGaussian(
                center: geometry.rightZygoma,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(-smoothness * 0.60, 0),
                falloff: .cosine
            )

            // 面颊凹陷平缓外推
            field.addGaussian(
                center: geometry.leftCheekFossa,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(-smoothness * 0.50, 0),
                falloff: .cosine
            )
            field.addGaussian(
                center: geometry.rightCheekFossa,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(smoothness * 0.50, 0),
                falloff: .cosine
            )
        }

        // 5. 苹果肌立体微雕与提拉 (appleCheekLift: -0.5...0.5)
        // 正值向内上方提拉苹果肌高光点，负值舒缓饱满度
        if abs(settings.appleCheekLift) > 0.0001 {
            let liftDy = settings.appleCheekLift * fh * 0.14
            let liftDx = settings.appleCheekLift * fw * 0.04
            let rx = zw * 0.24
            let ry = fh * 0.15

            // 左侧苹果肌：向内 (+dx) 向上 (+dy)
            field.addGaussian(
                center: geometry.leftAppleCheek,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(liftDx, liftDy),
                falloff: .cosine
            )
            // 右侧苹果肌：向内 (-dx) 向上 (+dy)
            field.addGaussian(
                center: geometry.rightAppleCheek,
                radiusX: rx, radiusY: ry,
                displacement: SIMD2<Double>(-liftDx, liftDy),
                falloff: .cosine
            )
        }
    }

    // MARK: - 3D Contour Guide Mask

    /// Renders specular apple cheek highlight (Red channel) and lateral zygomatic/temporal micro-shading (Green channel).
    public static func makeContour3DGuideMask(
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
            guard let geometry = FacialContourGeometry(face: face, imageSize: extent.size) else { continue }
            renderSingleFaceContour3DGuide(geometry: geometry, in: ctx, extent: extent)
        }

        guard let cgImg = ctx.makeImage() else { return makeTransparentImage(extent: extent) }
        let rawMask = CIImage(cgImage: cgImg)
        let blurRadius = max(1.5, extent.height * 0.006)
        return rawMask.clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }

    private static func renderSingleFaceContour3DGuide(
        geometry: FacialContourGeometry,
        in ctx: CGContext,
        extent: CGRect
    ) {
        let fw = geometry.faceWidth * extent.width
        let fh = geometry.faceHeight * extent.height
        let zw = geometry.zygomaWidth * extent.width

        let leftApple = CGPoint(
            x: geometry.leftAppleCheek.x * extent.width,
            y: geometry.leftAppleCheek.y * extent.height
        )
        let rightApple = CGPoint(
            x: geometry.rightAppleCheek.x * extent.width,
            y: geometry.rightAppleCheek.y * extent.height
        )

        // 1. 苹果肌高光点 (Red channel)
        ctx.saveGState()
        ctx.setFillColor(red: 1.0, green: 0, blue: 0, alpha: 0.90)
        let highlightRadiusX = max(3.0, zw * 0.16)
        let highlightRadiusY = max(2.5, fh * 0.09)

        ctx.fillEllipse(in: CGRect(
            x: leftApple.x - highlightRadiusX,
            y: leftApple.y - highlightRadiusY,
            width: highlightRadiusX * 2,
            height: highlightRadiusY * 2
        ))
        ctx.fillEllipse(in: CGRect(
            x: rightApple.x - highlightRadiusX,
            y: rightApple.y - highlightRadiusY,
            width: highlightRadiusX * 2,
            height: highlightRadiusY * 2
        ))
        ctx.restoreGState()

        // 2. 颧弓与颞部外侧柔光修容阴影 (Green channel)
        ctx.saveGState()
        ctx.setStrokeColor(red: 0, green: 1.0, blue: 0, alpha: 0.85)
        ctx.setLineWidth(max(2.0, fw * 0.05))
        ctx.setLineCap(.round)

        let leftTemple = CGPoint(x: geometry.leftTemple.x * extent.width,
                                 y: geometry.leftTemple.y * extent.height)
        let leftZygoma = CGPoint(x: geometry.leftZygoma.x * extent.width,
                                 y: geometry.leftZygoma.y * extent.height)
        let leftCheek = CGPoint(x: geometry.leftCheekFossa.x * extent.width,
                                y: geometry.leftCheekFossa.y * extent.height)

        ctx.beginPath()
        ctx.move(to: leftTemple)
        ctx.addQuadCurve(to: leftCheek, control: leftZygoma)
        ctx.strokePath()

        let rightTemple = CGPoint(x: geometry.rightTemple.x * extent.width,
                                  y: geometry.rightTemple.y * extent.height)
        let rightZygoma = CGPoint(x: geometry.rightZygoma.x * extent.width,
                                  y: geometry.rightZygoma.y * extent.height)
        let rightCheek = CGPoint(x: geometry.rightCheekFossa.x * extent.width,
                                 y: geometry.rightCheekFossa.y * extent.height)

        ctx.beginPath()
        ctx.move(to: rightTemple)
        ctx.addQuadCurve(to: rightCheek, control: rightZygoma)
        ctx.strokePath()

        ctx.restoreGState()
    }

    private static func makeTransparentImage(extent: CGRect) -> CIImage {
        CIImage(color: .clear).cropped(to: extent)
    }
}

// MARK: - Internal Facial Contour Geometry

public struct FacialContourGeometry: Equatable {
    public var boundingBox: CGRect
    public var leftTemple: CGPoint
    public var rightTemple: CGPoint
    public var leftZygoma: CGPoint
    public var rightZygoma: CGPoint
    public var leftCheekFossa: CGPoint
    public var rightCheekFossa: CGPoint
    public var leftAppleCheek: CGPoint
    public var rightAppleCheek: CGPoint
    public var faceWidth: Double
    public var faceHeight: Double
    public var zygomaWidth: Double

    public init?(face: FaceLandmarkSet, imageSize: CGSize) {
        guard face.hasUsableGeometry else { return nil }
        self.boundingBox = face.boundingBox

        let validContour = face.faceContour.filter { $0.x.isFinite && $0.y.isFinite }
        let box = face.boundingBox

        let fw = max(0.02, Double(box.width))
        let fh = max(0.02, Double(box.height))

        // Pupil / eye centers
        let leftEyeCenter: CGPoint
        let validLeftEye = face.leftEye.filter { $0.x.isFinite && $0.y.isFinite }
        if !validLeftEye.isEmpty {
            let sumX = validLeftEye.reduce(0.0) { $0 + $1.x }
            let sumY = validLeftEye.reduce(0.0) { $0 + $1.y }
            leftEyeCenter = CGPoint(x: sumX / CGFloat(validLeftEye.count), y: sumY / CGFloat(validLeftEye.count))
        } else {
            leftEyeCenter = CGPoint(x: box.minX + box.width * 0.32, y: box.minY + box.height * 0.65)
        }

        let rightEyeCenter: CGPoint
        let validRightEye = face.rightEye.filter { $0.x.isFinite && $0.y.isFinite }
        if !validRightEye.isEmpty {
            let sumX = validRightEye.reduce(0.0) { $0 + $1.x }
            let sumY = validRightEye.reduce(0.0) { $0 + $1.y }
            rightEyeCenter = CGPoint(x: sumX / CGFloat(validRightEye.count), y: sumY / CGFloat(validRightEye.count))
        } else {
            rightEyeCenter = CGPoint(x: box.maxX - box.width * 0.32, y: box.minY + box.height * 0.65)
        }

        // 1. Temples (Upper lateral face, ~0.62...0.78 Y)
        let leftTempleCandidates = validContour.filter {
            $0.x < box.midX && $0.y >= box.minY + box.height * 0.62 && $0.y <= box.minY + box.height * 0.78
        }
        let rightTempleCandidates = validContour.filter {
            $0.x > box.midX && $0.y >= box.minY + box.height * 0.62 && $0.y <= box.minY + box.height * 0.78
        }
        self.leftTemple = leftTempleCandidates.min(by: { $0.x < $1.x }) ??
            CGPoint(x: box.minX + box.width * 0.12, y: box.minY + box.height * 0.70)
        self.rightTemple = rightTempleCandidates.max(by: { $0.x < $1.x }) ??
            CGPoint(x: box.maxX - box.width * 0.12, y: box.minY + box.height * 0.70)

        // 2. Zygoma / Cheekbones (Mid-upper lateral peak, ~0.45...0.60 Y)
        let leftZygomaCandidates = validContour.filter {
            $0.x < box.midX && $0.y >= box.minY + box.height * 0.45 && $0.y <= box.minY + box.height * 0.60
        }
        let rightZygomaCandidates = validContour.filter {
            $0.x > box.midX && $0.y >= box.minY + box.height * 0.45 && $0.y <= box.minY + box.height * 0.60
        }
        self.leftZygoma = leftZygomaCandidates.min(by: { $0.x < $1.x }) ??
            CGPoint(x: box.minX + box.width * 0.06, y: box.minY + box.height * 0.52)
        self.rightZygoma = rightZygomaCandidates.max(by: { $0.x < $1.x }) ??
            CGPoint(x: box.maxX - box.width * 0.06, y: box.minY + box.height * 0.52)

        // 3. Buccal Hollow / Cheek Fossa (~0.30...0.45 Y)
        let leftCheekCandidates = validContour.filter {
            $0.x < box.midX && $0.y >= box.minY + box.height * 0.30 && $0.y <= box.minY + box.height * 0.45
        }
        let rightCheekCandidates = validContour.filter {
            $0.x > box.midX && $0.y >= box.minY + box.height * 0.30 && $0.y <= box.minY + box.height * 0.45
        }
        self.leftCheekFossa = leftCheekCandidates.min(by: { $0.x < $1.x }) ??
            CGPoint(x: box.minX + box.width * 0.10, y: box.minY + box.height * 0.38)
        self.rightCheekFossa = rightCheekCandidates.max(by: { $0.x < $1.x }) ??
            CGPoint(x: box.maxX - box.width * 0.10, y: box.minY + box.height * 0.38)

        // 4. Apple Cheeks (Malar fat pad apex below pupils)
        self.leftAppleCheek = CGPoint(
            x: leftEyeCenter.x,
            y: leftEyeCenter.y - CGFloat(fh * 0.13)
        )
        self.rightAppleCheek = CGPoint(
            x: rightEyeCenter.x,
            y: rightEyeCenter.y - CGFloat(fh * 0.13)
        )

        self.faceWidth = fw
        self.faceHeight = fh
        self.zygomaWidth = max(0.03, Double(rightZygoma.x - leftZygoma.x))
    }
}

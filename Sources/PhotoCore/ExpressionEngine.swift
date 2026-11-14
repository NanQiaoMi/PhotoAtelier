import CoreGraphics
import CoreImage
import Foundation

// MARK: - Expression Engine

/// P2-T: Smart facial micro-expression, smile嘴角与唇形立体微雕 engine.
///
/// Features:
/// 1. 微笑嘴角与嘴角上扬 (Smile & Lip Corner Uplift / `smileDegree`):
///    Simulates zygomaticus major muscle vectors, elevating oral commissures naturally upward and outward.
/// 2. 微笑宽度与张弛度 (Smile Width / `smileWidth`):
///    Modulates smile arc width (widening or narrowing) with natural lateral lip extension.
/// 3. 唇角对称性校准 (Lip Corner Symmetry / `lipSymmetry`):
///    Harmonizes asymmetrical mouth corners and balances tilted smiles.
/// 4. 幼态人中缩短 (Philtrum Shortening / `philtrumShortening`):
///    Lifts Cupid's bow towards the subnasale for youthful facial proportions.
/// 5. 丰唇立体微雕 (Vermilion Plumping / `upperLipPlump`, `lowerLipPlump`):
///    Independently adjusts upper and lower lip fullness and curvature.
/// 6. 唇峰珠光高光与立体阴影 (3D Vermilion Highlight & Micro-Shading / `lip3DHighlight`):
///    Subtle specular pearl highlight on upper lip tubercle and lower lip pillows, paired with
///    soft labiomental groove ambient shadow.
///
/// 100% offline, zero external model weights, Core Image GPU & Metal accelerated.
public enum ExpressionEngine {

    // MARK: - Shader Kernels

    private static let lip3DKernelSource = """
    kernel vec4 lip3DShadingKernel(
        sampler src,
        sampler guide,
        vec4 params // x: highlightStrength, y: shadowStrength, zw: reserved
    ) {
        vec4 c = sample(src, samplerCoord(src));
        vec4 g = sample(guide, samplerCoord(guide));
        vec3 col = c.rgb;

        float hl = g.r * params.x;
        float sh = g.g * params.y;

        // Specular highlight: gentle pearlescent luminance boost
        if (hl > 0.001) {
            col += vec3(hl * 0.16);
        }
        // Micro-shadow: subtle deepening of labiomental groove
        if (sh > 0.001) {
            col *= (1.0 - sh * 0.14);
        }

        // R3 (2026-11-14): pixels outside this module's guides pass through
        // unchanged. The engine works in extended-linear-sRGB, where highlights
        // above 1.0 are legitimate; the unconditional clamp used to clip every
        // highlight in the photograph whenever the slider was non-zero.
        if (hl <= 0.001 && sh <= 0.001) { return c; }
        return vec4(clamp(col, 0.0, 1.0), c.a);
    }
    """

    private static let lip3DKernel: CIColorKernel? = {
        CIColorKernel(source: lip3DKernelSource)
    }()

    // MARK: - Public API

    /// Applies facial expression, smile, and lip shape enhancements to all detected faces.
    public static func apply(
        to image: CIImage,
        faces: [FaceLandmarkSet],
        settings: ExpressionSettings
    ) -> (image: CIImage, report: ExpressionReport) {
        guard settings.enabled, !settings.isNeutral, !faces.isEmpty else {
            return (image, ExpressionReport(applied: false, faceCount: 0, note: nil))
        }

        let startTime = Date().timeIntervalSinceReferenceDate
        let usableFaces = faces.filter { $0.hasUsableGeometry && !$0.outerLips.isEmpty }
        guard !usableFaces.isEmpty else {
            return (image, ExpressionReport(applied: false, faceCount: 0, note: "未检测到可用唇部关键点。"))
        }

        var working = image

        // 1. Warp Field for smile, width, symmetry, philtrum shortening & plumping
        let field = generateWarpField(faces: usableFaces, settings: settings, imageSize: image.extent.size)
        if !field.isIdentity {
            do {
                working = try field.apply(to: working)
            } catch {
                // If warp fails, keep working as is
            }
        }

        // 2. 3D Lip Highlight & Micro-Shading
        if settings.lip3DHighlight > 0.001, let kernel = lip3DKernel {
            let guide = makeLip3DGuideMask(faces: usableFaces, extent: image.extent)
            let params = CIVector(x: CGFloat(settings.lip3DHighlight),
                                  y: CGFloat(settings.lip3DHighlight * 0.85),
                                  z: 0, w: 0)
            if let shaded = kernel.apply(extent: image.extent,
                                         roiCallback: { _, rect in rect },
                                         arguments: [working, guide, params]) {
                working = shaded.cropped(to: image.extent)
            }
        }

        let elapsedMs = (Date().timeIntervalSinceReferenceDate - startTime) * 1000.0
        let report = ExpressionReport(
            applied: true,
            faceCount: usableFaces.count,
            averageSmileAdjustment: settings.smileDegree,
            averagePlumpAdjustment: (settings.upperLipPlump + settings.lowerLipPlump) * 0.5,
            philtrumShortenedFaces: settings.philtrumShortening > 0.01 ? usableFaces.count : 0,
            processingTimeMs: elapsedMs,
            note: nil
        )

        return (working, report)
    }

    /// Applies expression adjustments for a single person in multi-person demographic processing.
    public static func applyPerPerson(
        to image: CIImage,
        face: FaceLandmarkSet,
        faceIndex: Int,
        perFaceMask: FaceSemanticMaskSet? = nil,
        settings: ExpressionSettings
    ) -> CIImage {
        guard settings.enabled, !settings.isNeutral, face.hasUsableGeometry, !face.outerLips.isEmpty else {
            return image
        }

        let res = apply(to: image, faces: [face], settings: settings)
        guard let maskSet = perFaceMask, let mask = maskSet.skin ?? maskSet.lips else {
            return res.image
        }

        // Blend with per-person mask to isolate effect strictly to this individual
        return res.image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask
        ]).cropped(to: image.extent)
    }

    // MARK: - Warp Field Generation

    /// Builds a WarpField incorporating smile, width, symmetry, philtrum shortening & plumping.
    public static func generateWarpField(
        faces: [FaceLandmarkSet],
        settings: ExpressionSettings,
        imageSize: CGSize,
        resolution: Int = WarpField.defaultResolution
    ) -> WarpField {
        var field = WarpField(columns: resolution, rows: resolution)
        guard !faces.isEmpty else { return field }

        for face in faces {
            guard let geometry = ExpressionGeometry(face: face) else { continue }
            addFaceExpression(to: &field, geometry: geometry, settings: settings)
        }

        field.clampMagnitude(WarpField.maximumDisplacement)
        return field
    }

    private static func addFaceExpression(
        to field: inout WarpField,
        geometry: ExpressionGeometry,
        settings: ExpressionSettings
    ) {
        let mw = geometry.mouthWidth
        let mh = geometry.mouthHeight

        // 1. 微笑嘴角与嘴角上扬 (Smile Degree)
        // R3: a smile that is already in the photo must not be pushed further.
        // The photo's own lip geometry decides how much headroom is left, so
        // the same slider reads as "relax the mouth" on a neutral face and as
        // a no-op on a laughing one.
        let smileStrength = settings.smileDegree * geometry.smileHeadroom
        if smileStrength > 0.0001 {
            let strength = smileStrength
            let upAmount = mh * 0.52 * strength
            let outAmount = mw * 0.12 * strength
            let cornerRadiusX = mw * 0.35
            let cornerRadiusY = mh * 0.65

            // Left commissure: upward (+Y) and outward (-X)
            field.addGaussian(
                center: geometry.leftCorner,
                radiusX: cornerRadiusX,
                radiusY: cornerRadiusY,
                displacement: SIMD2<Double>(-outAmount, upAmount),
                falloff: .gaussian
            )

            // Right commissure: upward (+Y) and outward (+X)
            field.addGaussian(
                center: geometry.rightCorner,
                radiusX: cornerRadiusX,
                radiusY: cornerRadiusY,
                displacement: SIMD2<Double>(outAmount, upAmount),
                falloff: .gaussian
            )

            // Outer lip arc smoothing: slight upward curve along lateral vermilion borders
            let leftMid = CGPoint(x: (geometry.leftCorner.x + geometry.mouthCenter.x) * 0.5,
                                  y: (geometry.leftCorner.y + geometry.mouthCenter.y) * 0.5)
            let rightMid = CGPoint(x: (geometry.rightCorner.x + geometry.mouthCenter.x) * 0.5,
                                   y: (geometry.rightCorner.y + geometry.mouthCenter.y) * 0.5)
            field.addGaussian(
                center: leftMid,
                radiusX: mw * 0.25,
                radiusY: mh * 0.40,
                displacement: SIMD2<Double>(-outAmount * 0.30, upAmount * 0.35),
                falloff: .gaussian
            )
            field.addGaussian(
                center: rightMid,
                radiusX: mw * 0.25,
                radiusY: mh * 0.40,
                displacement: SIMD2<Double>(outAmount * 0.30, upAmount * 0.35),
                falloff: .gaussian
            )
        }

        // 2. 微笑宽度 (Smile Width)
        if abs(settings.smileWidth) > 0.0001 {
            let widthDelta = mw * 0.24 * settings.smileWidth
            let cornerRadiusX = mw * 0.32
            let cornerRadiusY = mh * 0.50

            field.addGaussian(
                center: geometry.leftCorner,
                radiusX: cornerRadiusX,
                radiusY: cornerRadiusY,
                displacement: SIMD2<Double>(-widthDelta, 0),
                falloff: .gaussian
            )
            field.addGaussian(
                center: geometry.rightCorner,
                radiusX: cornerRadiusX,
                radiusY: cornerRadiusY,
                displacement: SIMD2<Double>(widthDelta, 0),
                falloff: .gaussian
            )
        }

        // 3. 唇角对称性校准 (Lip Corner Symmetry)
        if settings.lipSymmetry > 0.0001 {
            let targetY = (geometry.leftCorner.y + geometry.rightCorner.y) * 0.5
            let leftDy = (targetY - geometry.leftCorner.y) * settings.lipSymmetry
            let rightDy = (targetY - geometry.rightCorner.y) * settings.lipSymmetry

            if abs(leftDy) > 0.00005 {
                field.addGaussian(
                    center: geometry.leftCorner,
                    radiusX: mw * 0.30,
                    radiusY: mh * 0.55,
                    displacement: SIMD2<Double>(0, leftDy),
                    falloff: .gaussian
                )
            }
            if abs(rightDy) > 0.00005 {
                field.addGaussian(
                    center: geometry.rightCorner,
                    radiusX: mw * 0.30,
                    radiusY: mh * 0.55,
                    displacement: SIMD2<Double>(0, rightDy),
                    falloff: .gaussian
                )
            }
        }

        // 4. 幼态人中缩短 (Philtrum Shortening)
        if settings.philtrumShortening > 0.0001 {
            let subnasaleY = geometry.subnasale?.y ?? (geometry.cupidBow.y + mh * 0.8)
            let philtrumLength = max(0.008, subnasaleY - geometry.cupidBow.y)
            let lift = philtrumLength * 0.28 * settings.philtrumShortening

            field.addGaussian(
                center: geometry.cupidBow,
                radiusX: mw * 0.35,
                radiusY: philtrumLength * 0.75,
                displacement: SIMD2<Double>(0, lift),
                falloff: .gaussian
            )
        }

        // 5. 上唇丰满与微调 (Upper Lip Plump)
        if abs(settings.upperLipPlump) > 0.0001 {
            let upperLift = mh * 0.28 * settings.upperLipPlump
            field.addGaussian(
                center: geometry.upperVermilionCenter,
                radiusX: mw * 0.40,
                radiusY: mh * 0.45,
                displacement: SIMD2<Double>(0, upperLift),
                falloff: .gaussian
            )
        }

        // 6. 下唇丰满与微调 (Lower Lip Plump)
        if abs(settings.lowerLipPlump) > 0.0001 {
            let lowerDrop = -mh * 0.32 * settings.lowerLipPlump
            field.addGaussian(
                center: geometry.lowerVermilionCenter,
                radiusX: mw * 0.45,
                radiusY: mh * 0.50,
                displacement: SIMD2<Double>(0, lowerDrop),
                falloff: .gaussian
            )
        }
    }

    // MARK: - 3D Lip Highlight & Micro-Shading Mask

    /// Renders specular highlights in Red channel and labiomental groove shadow in Green channel.
    public static func makeLip3DGuideMask(
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
            guard let g = ExpressionGeometry(face: face) else { continue }
            renderFaceLip3D(g, in: ctx, extent: extent)
        }

        guard let cgImg = ctx.makeImage() else { return makeTransparentImage(extent: extent) }
        let raw = CIImage(cgImage: cgImg)
        let blurRadius = max(1.5, extent.height * 0.0035)
        return raw.clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }

    private static func renderFaceLip3D(
        _ g: ExpressionGeometry,
        in ctx: CGContext,
        extent: CGRect
    ) {
        let originX = extent.origin.x
        let originY = extent.origin.y
        let w = extent.width
        let h = extent.height

        func pixelPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: originX + p.x * w, y: originY + p.y * h)
        }

        let mwPixels = g.mouthWidth * Double(w)
        let mhPixels = g.mouthHeight * Double(h)

        // 1. Central tubercle highlight (Red channel = 1.0)
        let tubercle = pixelPoint(CGPoint(x: g.mouthCenter.x,
                                          y: (g.cupidBow.y + g.mouthCenter.y) * 0.5))
        let hlRadiusX = mwPixels * 0.16
        let hlRadiusY = mhPixels * 0.22
        let hlRect = CGRect(x: tubercle.x - hlRadiusX, y: tubercle.y - hlRadiusY,
                            width: hlRadiusX * 2, height: hlRadiusY * 2)

        ctx.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.85)
        ctx.fillEllipse(in: hlRect)

        // 2. Lower lip pillows highlight (Red channel = 1.0)
        let leftPillow = pixelPoint(CGPoint(x: g.mouthCenter.x - g.mouthWidth * 0.14,
                                            y: g.lowerVermilionCenter.y))
        let rightPillow = pixelPoint(CGPoint(x: g.mouthCenter.x + g.mouthWidth * 0.14,
                                             y: g.lowerVermilionCenter.y))
        let pillowRadiusX = mwPixels * 0.14
        let pillowRadiusY = mhPixels * 0.24

        ctx.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.70)
        ctx.fillEllipse(in: CGRect(x: leftPillow.x - pillowRadiusX, y: leftPillow.y - pillowRadiusY,
                                   width: pillowRadiusX * 2, height: pillowRadiusY * 2))
        ctx.fillEllipse(in: CGRect(x: rightPillow.x - pillowRadiusX, y: rightPillow.y - pillowRadiusY,
                                   width: pillowRadiusX * 2, height: pillowRadiusY * 2))

        // 3. Labiomental groove micro-shadow (Green channel = 1.0)
        let groove = pixelPoint(g.labiomentalGroove)
        let grooveRadiusX = mwPixels * 0.28
        let grooveRadiusY = mhPixels * 0.20
        ctx.setFillColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 0.75)
        ctx.fillEllipse(in: CGRect(x: groove.x - grooveRadiusX, y: groove.y - grooveRadiusY,
                                   width: grooveRadiusX * 2, height: grooveRadiusY * 2))
    }

    private static func makeTransparentImage(extent: CGRect) -> CIImage {
        CIImage(color: .clear).cropped(to: extent)
    }
}

// MARK: - Expression Geometry

/// Sanitized anatomical anchors derived from `FaceLandmarkSet`.
public struct ExpressionGeometry {
    public let boundingBox: CGRect
    public let leftCorner: CGPoint
    public let rightCorner: CGPoint
    public let mouthCenter: CGPoint
    public let mouthWidth: Double
    public let mouthHeight: Double
    public let cupidBow: CGPoint
    public let subnasale: CGPoint?
    public let upperVermilionCenter: CGPoint
    public let lowerVermilionCenter: CGPoint
    public let lowerVermilionBottom: CGPoint
    public let labiomentalGroove: CGPoint
    /// R3 (2026-11-14): how much the mouth is *already* smiling, measured from
    /// the photo's own lip contour - the corner height above the lip centre.
    /// `smileDegree` is a request to lift the corners; on a mouth that is
    /// already smiling that request has to be attenuated, otherwise the corners
    /// are pushed further up into the "咧嘴" grimace the P2 review caught.
    /// 0 ≈ a neutral mouth, ≈0.06 a relaxed smile, > 0.10 a broad grin.
    public let existingSmileArc: Double

    public init?(face: FaceLandmarkSet) {
        let pts = face.outerLips.filter { $0.x.isFinite && $0.y.isFinite }
        guard pts.count >= 3 else { return nil }

        guard let minXPt = pts.min(by: { $0.x < $1.x }),
              let maxXPt = pts.max(by: { $0.x < $1.x }) else {
            return nil
        }

        self.leftCorner = minXPt
        self.rightCorner = maxXPt
        self.boundingBox = face.boundingBox

        let center = CGPoint(x: (minXPt.x + maxXPt.x) * 0.5,
                             y: (minXPt.y + maxXPt.y) * 0.5)
        self.mouthCenter = center

        let w = max(0.005, Double(maxXPt.x - minXPt.x))
        let allY = pts.map(\.y)
        let minY = allY.min() ?? (center.y - 0.01)
        let maxY = allY.max() ?? (center.y + 0.01)
        let h = max(0.003, Double(maxY - minY))

        self.mouthWidth = w
        self.mouthHeight = h

        // Cupid's bow: highest point near horizontal center
        let centralPoints = pts.filter { abs($0.x - center.x) <= CGFloat(w * 0.30) }
        let cBow = centralPoints.max(by: { $0.y < $1.y }) ?? pts.max(by: { $0.y < $1.y })!
        self.cupidBow = cBow

        // Subnasale: lowest point on nose outline
        let nosePts = face.nose.filter { $0.x.isFinite && $0.y.isFinite }
        if let lowestNose = nosePts.min(by: { $0.y < $1.y }) {
            self.subnasale = lowestNose
        } else {
            self.subnasale = nil
        }

        // Lower vermilion bottom: lowest point near horizontal center
        let lBottom = centralPoints.min(by: { $0.y < $1.y }) ?? pts.min(by: { $0.y < $1.y })!
        self.lowerVermilionBottom = lBottom

        self.upperVermilionCenter = CGPoint(x: center.x, y: (cBow.y + center.y) * 0.5)
        self.lowerVermilionCenter = CGPoint(x: center.x, y: (lBottom.y + center.y) * 0.5)
        self.labiomentalGroove = CGPoint(x: center.x, y: max(0.0, lBottom.y - CGFloat(h * 0.35)))

        // Corner height above the lip centre: positive when the commissures
        // sit above the middle of the mouth, which is exactly what a smile is.
        let lipCenterY = Double((cBow.y + lBottom.y) * 0.5)
        let cornerMeanY = Double((minXPt.y + maxXPt.y) * 0.5)
        self.existingSmileArc = max(0.0, cornerMeanY - lipCenterY)
    }

    /// R3: the share of a requested smile uplift that is still appropriate,
    /// given how much the mouth already smiles. A neutral mouth takes the full
    /// request; a mouth that already smiles broadly takes almost none.
    public var smileHeadroom: Double {
        let alreadySmiling = min(1.0, max(0.0, (existingSmileArc - 0.015) / 0.075))
        return 1.0 - alreadySmiling
    }
}

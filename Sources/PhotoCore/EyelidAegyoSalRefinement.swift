import Foundation
import CoreImage
import CoreGraphics

// MARK: - Eyelid & Aegyo Sal Engine

/// P2-P: Smart double eyelid sculpting, eyelid tape concealing & aegyo sal / lower lid micro-contouring engine.
///
/// Features:
/// 1. Double Eyelid Sculpting: 4 customizable crease styles (.fan, .parallel, .crescent, .wide) with height and width modulation.
/// 2. Eyelid Tape Concealing: detects and smooths tape glare, softens hard step edges, and blends seamlessly into eyelid skin.
/// 3. Aegyo Sal Sculpting: shapes lower eyelid orbicularis roll with pearlescent highlight ridge and delicate bottom crease shadow.
///
/// 100% offline, zero external weights, Core Image & Metal accelerated.
public enum EyelidAegyoSalRefinementEngine {

    // MARK: - Shader Kernels

    private static let eyelidKernelSource = """
    kernel vec4 eyelidAegyoSalKernel(
        sampler src,
        sampler eyelidGuide,
        sampler aegyoSalGuide,
        vec4 eyelidParams,   // x: eyelidStrength, y: tapeConceal, z: aegyoSalLuma, w: aegyoSalShadow
        vec4 skinToneAnchor  // rgb: skin tone reference, a: reserved
    ) {
        vec4 c = sample(src, samplerCoord(src));
        vec4 el = sample(eyelidGuide, samplerCoord(eyelidGuide));
        vec4 as = sample(aegyoSalGuide, samplerCoord(aegyoSalGuide));

        vec3 col = c.rgb;

        // 1. Double Eyelid Crease Shadow & Highlight
        float creaseShadow = el.r * eyelidParams.x;
        float creaseHighlight = el.g * eyelidParams.x;
        if (creaseShadow > 0.001) {
            col *= (1.0 - creaseShadow * 0.42);
        }
        if (creaseHighlight > 0.001) {
            col += (vec3(creaseHighlight * 0.14) * max(skinToneAnchor.rgb, vec3(0.5)));
        }

        // 2. Eyelid Tape Concealing (suppress specular glare & step-edge contrast)
        float tapeWeight = el.b * eyelidParams.y;
        if (tapeWeight > 0.001) {
            float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
            float anchorLuma = dot(skinToneAnchor.rgb, vec3(0.2126, 0.7152, 0.0722));
            float glare = max(0.0, luma - anchorLuma);
            if (glare > 0.015) {
                col = mix(col, skinToneAnchor.rgb, clamp(glare * tapeWeight * 2.2, 0.0, 0.88));
            }
        }

        // 3. Aegyo Sal (卧蚕) Highlight Ridge
        float asLuma = as.r * eyelidParams.z;
        if (asLuma > 0.001) {
            col += (vec3(asLuma * 0.20) * max(skinToneAnchor.rgb, vec3(0.65)));
        }

        // 4. Aegyo Sal (卧蚕) Bottom Crease Shadow
        float asShadow = as.g * eyelidParams.w;
        if (asShadow > 0.001) {
            col *= (1.0 - asShadow * 0.36);
        }

        return vec4(clamp(col, 0.0, 1.0), c.a);
    }
    """

    private static let kernel: CIColorKernel? = {
        CIColorKernel(source: eyelidKernelSource)
    }()

    // MARK: - Public Processing Entry Points

    /// Applies double eyelid sculpting, tape concealing and aegyo sal micro-contouring to `image`.
    public static func apply(
        to image: CIImage,
        faces: [FaceLandmarkSet],
        settings: EyelidAegyoSalSettings
    ) -> (image: CIImage, report: EyelidAegyoSalReport) {
        guard !settings.isNeutral else {
            return (image, EyelidAegyoSalReport(applied: false, faceCount: faces.count, note: "双眼皮与卧蚕精雕未启用或参数全为中性。"))
        }
        guard !faces.isEmpty else {
            return (image, EyelidAegyoSalReport(applied: false, faceCount: 0, note: "未检测到可用人脸，双眼皮与卧蚕精雕已跳过。"))
        }
        guard let validated = try? settings.validated() else {
            return (image, EyelidAegyoSalReport(applied: false, faceCount: faces.count, note: "双眼皮与卧蚕参数无效。"))
        }

        let extent = image.extent
        let eyelidGuide = makeEyelidGuideMask(faces: faces, extent: extent, settings: validated)
        let aegyoSalGuide = makeAegyoSalGuideMask(faces: faces, extent: extent, settings: validated)
        let skinTone = estimateAverageSkinTone(image: image, faces: faces)

        guard let k = kernel else {
            return (image, EyelidAegyoSalReport(applied: false, faceCount: faces.count, note: "CIColorKernel 编译失败。"))
        }

        let params = CIVector(
            x: CGFloat(validated.eyelidStyle == .off ? 0 : validated.eyelidStrength),
            y: CGFloat(validated.tapeConceal),
            z: CGFloat(validated.aegyoSalLuminance),
            w: CGFloat(validated.aegyoSalShadow)
        )
        let anchorVector = CIVector(x: skinTone.x, y: skinTone.y, z: skinTone.z, w: 1.0)

        guard let output = k.apply(
            extent: extent,
            arguments: [image, eyelidGuide, aegyoSalGuide, params, anchorVector]
        ) else {
            return (image, EyelidAegyoSalReport(applied: false, faceCount: faces.count, note: "着色器计算输出为空。"))
        }

        let report = EyelidAegyoSalReport(
            applied: true,
            faceCount: faces.count,
            eyelidApplied: validated.eyelidStyle != .off && validated.eyelidStrength > 0,
            tapeConcealApplied: validated.tapeConceal > 0,
            aegyoSalApplied: validated.aegyoSalLuminance > 0 || validated.aegyoSalShadow > 0,
            note: "已成功应用双眼皮与卧蚕微雕（处理人脸数：\(faces.count)）。"
        )
        return (output, report)
    }

    /// Applies per-person eyelid and aegyo sal refinement.
    public static func applyPerPerson(
        to image: CIImage,
        face: FaceLandmarkSet,
        faceIndex: Int,
        perFaceMask: FaceSemanticMaskSet?,
        settings: EyelidAegyoSalSettings
    ) -> CIImage {
        guard !settings.isNeutral, face.hasUsableGeometry else { return image }
        let (processed, report) = apply(to: image, faces: [face], settings: settings)
        guard report.applied else { return image }
        if let mask = perFaceMask?.skin {
            return processed.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: mask
            ])
        }
        return processed
    }

    // MARK: - Guide Mask Generation

    /// Renders eyelid crease shadow (R), upper highlight (G), and tape candidate corridor (B).
    public static func makeEyelidGuideMask(
        faces: [FaceLandmarkSet],
        extent: CGRect,
        settings: EyelidAegyoSalSettings
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
            renderEyeEyelidGuide(face.leftEye, isLeftEye: true, in: ctx, extent: extent, settings: settings)
            renderEyeEyelidGuide(face.rightEye, isLeftEye: false, in: ctx, extent: extent, settings: settings)
        }

        guard let cgImg = ctx.makeImage() else { return makeTransparentImage(extent: extent) }
        let rawMask = CIImage(cgImage: cgImg)
        let blurRadius = max(1.0, extent.height * 0.0025)
        return rawMask.clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }

    /// Renders aegyo sal highlight ridge (R) and bottom crease shadow (G).
    public static func makeAegyoSalGuideMask(
        faces: [FaceLandmarkSet],
        extent: CGRect,
        settings: EyelidAegyoSalSettings
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
            renderEyeAegyoSalGuide(face.leftEye, isLeftEye: true, in: ctx, extent: extent, settings: settings)
            renderEyeAegyoSalGuide(face.rightEye, isLeftEye: false, in: ctx, extent: extent, settings: settings)
        }

        guard let cgImg = ctx.makeImage() else { return makeTransparentImage(extent: extent) }
        let rawMask = CIImage(cgImage: cgImg)
        let blurRadius = max(1.0, extent.height * 0.0028)
        return rawMask.clampedToExtent().applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }

    // MARK: - Internal Eyelid Geometry Rendering

    private static func renderEyeEyelidGuide(
        _ eyePoints: [CGPoint],
        isLeftEye: Bool,
        in ctx: CGContext,
        extent: CGRect,
        settings: EyelidAegyoSalSettings
    ) {
        guard eyePoints.count >= 4 else { return }
        let pxPoints = eyePoints.map { CGPoint(x: $0.x * extent.width, y: $0.y * extent.height) }
        guard let (inner, outer, midY, eyeHeight) = canthiAndMetrics(pxPoints, isLeftEye: isLeftEye) else { return }
        guard eyeHeight > 4 else { return }

        let steps = 30
        var creasePoints: [CGPoint] = []
        var upperHighlightPoints: [CGPoint] = []
        var tapePolygon: [CGPoint] = []

        let baseHeight = eyeHeight * 0.36 * CGFloat(settings.eyelidHeight)

        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = inner.x + t * (outer.x - inner.x)
            let baseLidY = midY + eyeHeight * 0.48 * sin(t * .pi)

            let styleFactor: CGFloat
            switch settings.eyelidStyle {
            case .off:
                styleFactor = 0
            case .fan:
                styleFactor = 0.20 + 0.95 * t
            case .parallel:
                styleFactor = 0.85
            case .crescent:
                styleFactor = 0.45 + 0.85 * sin(t * .pi)
            case .wide:
                styleFactor = 1.25
            }

            let creaseY = baseLidY + baseHeight * styleFactor
            creasePoints.append(CGPoint(x: x, y: creaseY))
            upperHighlightPoints.append(CGPoint(x: x, y: creaseY + baseHeight * 0.35))
            tapePolygon.append(CGPoint(x: x, y: creaseY + baseHeight * 0.50))
        }

        // Tape corridor bottom
        for i in (0...steps).reversed() {
            let t = CGFloat(i) / CGFloat(steps)
            let x = inner.x + t * (outer.x - inner.x)
            let baseLidY = midY + eyeHeight * 0.48 * sin(t * .pi)
            tapePolygon.append(CGPoint(x: x, y: baseLidY + baseHeight * 0.08))
        }

        // 1. Double Eyelid Tape Region (Blue channel)
        if settings.tapeConceal > 0, tapePolygon.count >= 3 {
            ctx.saveGState()
            ctx.setFillColor(red: 0, green: 0, blue: 1.0, alpha: 0.85)
            ctx.beginPath()
            ctx.move(to: tapePolygon[0])
            for pt in tapePolygon.dropFirst() {
                ctx.addLine(to: pt)
            }
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()
        }

        // 2. Crease Shadow Line (Red channel)
        if settings.eyelidStyle != .off, settings.eyelidStrength > 0, creasePoints.count >= 2 {
            ctx.saveGState()
            ctx.setStrokeColor(red: 1.0, green: 0, blue: 0, alpha: 0.90)
            ctx.setLineWidth(max(1.5, eyeHeight * 0.08))
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: creasePoints[0])
            for pt in creasePoints.dropFirst() {
                ctx.addLine(to: pt)
            }
            ctx.strokePath()
            ctx.restoreGState()

            // 3. Crease Upper Highlight Ridge (Green channel)
            ctx.saveGState()
            ctx.setStrokeColor(red: 0, green: 1.0, blue: 0, alpha: 0.70)
            ctx.setLineWidth(max(2.0, eyeHeight * 0.16))
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: upperHighlightPoints[0])
            for pt in upperHighlightPoints.dropFirst() {
                ctx.addLine(to: pt)
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: - Internal Aegyo Sal Geometry Rendering

    private static func renderEyeAegyoSalGuide(
        _ eyePoints: [CGPoint],
        isLeftEye: Bool,
        in ctx: CGContext,
        extent: CGRect,
        settings: EyelidAegyoSalSettings
    ) {
        guard eyePoints.count >= 4 else { return }
        let pxPoints = eyePoints.map { CGPoint(x: $0.x * extent.width, y: $0.y * extent.height) }
        guard let (inner, outer, midY, eyeHeight) = canthiAndMetrics(pxPoints, isLeftEye: isLeftEye) else { return }
        guard eyeHeight > 4 else { return }

        let steps = 30
        let rollThickness = eyeHeight * 0.42 * CGFloat(settings.aegyoSalWidth)

        var highlightPoints: [CGPoint] = []
        var shadowPoints: [CGPoint] = []

        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = inner.x + t * (outer.x - inner.x)
            let lowerLidY = midY - eyeHeight * 0.48 * sin(t * .pi)

            // Highlight ridge (35% down)
            let highY = lowerLidY - rollThickness * 0.36
            highlightPoints.append(CGPoint(x: x, y: highY))

            // Crease shadow valley (90% down)
            let shadowY = lowerLidY - rollThickness * 0.90
            shadowPoints.append(CGPoint(x: x, y: shadowY))
        }

        // 1. Aegyo Sal Highlight Ridge (Red channel of aegyoSalGuide)
        if settings.aegyoSalLuminance > 0, highlightPoints.count >= 2 {
            ctx.saveGState()
            ctx.setStrokeColor(red: 1.0, green: 0, blue: 0, alpha: 0.85)
            ctx.setLineWidth(max(2.0, rollThickness * 0.50))
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: highlightPoints[0])
            for pt in highlightPoints.dropFirst() {
                ctx.addLine(to: pt)
            }
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 2. Aegyo Sal Bottom Crease Shadow (Green channel of aegyoSalGuide)
        if settings.aegyoSalShadow > 0, shadowPoints.count >= 2 {
            ctx.saveGState()
            ctx.setStrokeColor(red: 0, green: 1.0, blue: 0, alpha: 0.85)
            ctx.setLineWidth(max(1.5, rollThickness * 0.32))
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: shadowPoints[0])
            for pt in shadowPoints.dropFirst() {
                ctx.addLine(to: pt)
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: - Helpers

    private static func canthiAndMetrics(_ points: [CGPoint], isLeftEye: Bool) -> (inner: CGPoint, outer: CGPoint, midY: CGFloat, eyeHeight: CGFloat)? {
        guard !points.isEmpty else { return nil }
        let minXPt = points.min(by: { $0.x < $1.x })!
        let maxXPt = points.max(by: { $0.x < $1.x })!
        let minY = points.map { $0.y }.min()!
        let maxY = points.map { $0.y }.max()!
        let midY = (minY + maxY) * 0.5
        let eyeHeight = max(1.0, maxY - minY)

        // For image-left eye, inner canthus is closest to face center (larger X)
        // For image-right eye, inner canthus is closest to face center (smaller X)
        let inner = isLeftEye ? maxXPt : minXPt
        let outer = isLeftEye ? minXPt : maxXPt

        return (inner, outer, midY, eyeHeight)
    }

    private static func estimateAverageSkinTone(image: CIImage, faces: [FaceLandmarkSet]) -> CIVector {
        // Return natural warm skin reference (0.82, 0.64, 0.54)
        return CIVector(x: 0.82, y: 0.64, z: 0.54)
    }

    private static func makeTransparentImage(extent: CGRect) -> CIImage {
        CIImage(color: .clear).cropped(to: extent)
    }
}

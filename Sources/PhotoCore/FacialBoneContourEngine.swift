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
        vec4 hlParams,      // x: tZone, y: cZone, z: philtrum, w: warmth
        vec4 shParams,      // x: cheekShadow, y: jawlineShadow, z: facialFolding, w: warmth
        vec4 foldBoost,     // x: centerBoostStrength, yzw: reserved
        vec4 lightInfo,     // x: lightX (-1 left .. 1 right), y: lightY, z: midline X px, w: face width px
        vec4 highlightTone, // rgb: the photo's own lit-skin colour
        vec4 shadowTone     // rgb: the photo's own shadow-skin colour
    ) {
        vec4 c = sample(src, samplerCoord(src));
        vec4 hl = sample(hlGuide, samplerCoord(hlGuide));
        vec4 sh = sample(shGuide, samplerCoord(shGuide));
        vec3 col = c.rgb;
        const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

        // R3 (2026-11-14): this kernel used to *add white* to the T-zone and
        // C-zone and multiply by a fixed darkness for the contour, on a fixed
        // template, ignoring where the light in the photo actually comes from.
        // On a portrait lit from the left the nasal bridge highlight still
        // landed dead centre and the right C-zone was brightened even though it
        // is the shaded side - the "贴纸/妆感" the P2 review found.
        //
        // Everything below now derives its colour from the photograph:
        //   * highlights lift toward the hue of the photo's own lit skin,
        //     scaled by how much headroom the pixel has (a bright forehead can
        //     no longer be pushed to clipping);
        //   * shadows darken through the hue of the photo's own shadowed skin,
        //     so the burn stays skin-coloured instead of neutral grey;
        //   * C-zone highlights and cheek-hollow shadows are attenuated on the
        //     side of the face that the light is *not* coming from.
        // The lit side / shadow side attenuation is baked into the guide masks
        // (see `drawHighlightGuide` / `drawShadowGuide`), because the kernel
        // language cannot read a pixel coordinate into a local variable.
        float tZone = hl.r * hlParams.x;
        float cZone = hl.g * hlParams.y;
        float philtrum = hl.b * hlParams.z;
        float warmth = hlParams.w;

        // 1. Highlights: lift toward the photo's own lit-skin tone.
        float totalHL = tZone * 0.16 + cZone * 0.14 + philtrum * 0.12;
        if (totalHL > 0.0005) {
            float hlLum = max(0.05, dot(highlightTone.rgb, LUMA));
            vec3 hlHue = highlightTone.rgb / hlLum;
            // Warmth pushes the highlight's own hue warmer/cooler; the swings
            // are large enough to survive an 8-bit output step.
            if (warmth > 0.001) {
                hlHue *= vec3(1.0 + 0.20 * warmth, 1.0 + 0.07 * warmth, 1.0 - 0.14 * warmth);
            } else if (warmth < -0.001) {
                float wAbs = abs(warmth);
                hlHue *= vec3(1.0 - 0.10 * wAbs, 1.0, 1.0 + 0.14 * wAbs);
            }
            float lum = dot(col, LUMA);
            float headroom = clamp(1.0 - lum, 0.0, 1.0);
            col += hlHue * totalHL * (0.35 + 0.65 * headroom);
        }

        // 2. Shadows & Lateral Folding Falloff
        float cheekSh = sh.r * shParams.x;
        float jawlineSh = sh.g * shParams.y;
        float foldLateralSh = sh.b * shParams.z;
        float totalShadow = cheekSh * 0.16 + jawlineSh * 0.20 + foldLateralSh * 0.14;

        if (totalShadow > 0.0005) {
            float shMult = max(0.45, 1.0 - totalShadow);
            // `shadowTone` is the photo's shadowed skin RELATIVE to its lit skin
            // (a per-channel ratio, 1.0 where the two are the same colour), so
            // the burn stays skin-coloured and is exactly neutral on a face
            // without a colour cast.
            vec3 shHue = mix(vec3(1.0), shadowTone.rgb, 0.85);
            if (warmth > 0.001) {
                shHue *= vec3(1.0 + 0.12 * warmth, 1.0 + 0.03 * warmth, 1.0 - 0.10 * warmth);
            } else if (warmth < -0.001) {
                float wAbs = abs(warmth);
                shHue *= vec3(1.0 - 0.08 * wAbs, 1.0, 1.0 + 0.10 * wAbs);
            }
            col *= (shMult * shHue);
        }

        // 3. Central Folding Axial Prominence Boost
        float centerBoost = sh.a * foldBoost.x;
        if (centerBoost > 0.0005) {
            col += vec3(centerBoost * 0.07);
        }

        // R3 (2026-11-14, second pass): pass untouched pixels straight through.
        // The unconditional clamp used to clip every value above 1.0 in the
        // extended-linear working space - i.e. every highlight in the photo,
        // wherever it was - whenever a bone-contour slider was non-zero.
        if (totalHL <= 0.0005 && totalShadow <= 0.0005 && centerBoost <= 0.0005) { return c; }
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
        let lighting = lightResponse(for: working, faces: usableFaces)
        let (hlGuide, shGuide) = makeBoneContourGuideMasks(
            faces: usableFaces, extent: working.extent, lightX: Double(lighting.lightInfo.x))

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
            arguments: [working, hlGuide, shGuide, hlParams, shParams, foldBoost,
                        lighting.lightInfo, lighting.highlightTone, lighting.shadowTone]
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
        let lighting = lightResponse(for: image, faces: [face])
        let (hlGuide, shGuide) = makeBoneContourGuideMasks(
            faces: [face], extent: image.extent, lightX: Double(lighting.lightInfo.x))
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
            arguments: [image, hlGuide, shGuide, hlParams, shParams, foldBoost,
                        lighting.lightInfo, lighting.highlightTone, lighting.shadowTone]
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

    // MARK: - Photo light response

    /// What the photograph itself says about its own light: the direction it
    /// comes from, and the colour of the lit and shadowed skin. The bone
    /// contour pass must be *derived* from these, otherwise its highlights are
    /// white paint and its shadows neutral grey, regardless of the photo.
    struct LightResponse {
        /// x: light direction (-1 left .. 1 right), y: vertical direction,
        /// z: face midline in pixels, w: face width in pixels.
        var lightInfo: CIVector
        /// The photo's own lit-skin colour (rgb), already normalised.
        var highlightTone: CIVector
        /// The photo's shadowed-skin colour as a per-channel ratio to its lit
        /// skin colour (rgb), `1` where they are identical.
        var shadowTone: CIVector
    }

    static func lightResponse(for image: CIImage, faces: [FaceLandmarkSet]) -> LightResponse {
        let extent = image.extent
        let face = faces.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        })
        let neutralTone = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let face, face.hasUsableGeometry, extent.width > 4, extent.height > 4 else {
            return LightResponse(lightInfo: CIVector(x: 0, y: 0, z: extent.midX, w: 0),
                                 highlightTone: neutralTone, shadowTone: neutralTone)
        }
        let box = face.boundingBox
        let context = CIContext(options: [.workingColorSpace: NSNull()])

        /// Mean colour of a small patch, ignoring near-black pixels (eyes,
        /// brows, nostrils) that would otherwise dominate a shadow sample.
        func patch(_ normalized: CGPoint, radiusFraction: CGFloat) -> (r: Double, g: Double, b: Double)? {
            let radius = max(1.0, box.width * extent.width * radiusFraction)
            let center = CGPoint(x: normalized.x * extent.width, y: normalized.y * extent.height)
            var rect = CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2)
            rect = rect.intersection(extent)
            let width = Int(rect.width.rounded()), height = Int(rect.height.rounded())
            guard width >= 1, height >= 1, width * height <= 1_000_000 else { return nil }
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            context.render(image, toBitmap: &buffer, rowBytes: width * 4, bounds: rect,
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            var sum = (r: 0.0, g: 0.0, b: 0.0)
            var count = 0.0
            for index in 0..<(width * height) {
                let r = Double(buffer[index * 4]) / 255.0
                let g = Double(buffer[index * 4 + 1]) / 255.0
                let b = Double(buffer[index * 4 + 2]) / 255.0
                let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                guard lum > 0.06 else { continue }
                sum.r += r; sum.g += g; sum.b += b; count += 1
            }
            guard count > 0 else { return nil }
            return (sum.r / count, sum.g / count, sum.b / count)
        }

        func luminance(_ tone: (r: Double, g: Double, b: Double)) -> Double {
            0.2126 * tone.r + 0.7152 * tone.g + 0.0722 * tone.b
        }

        // Sample five face landmarks that exist on every usable face.
        let samples: [(name: String, point: CGPoint, radius: CGFloat)] = [
            ("leftCheek", CGPoint(x: box.minX + box.width * 0.24, y: box.minY + box.height * 0.40), 0.05),
            ("rightCheek", CGPoint(x: box.minX + box.width * 0.76, y: box.minY + box.height * 0.40), 0.05),
            ("forehead", CGPoint(x: box.midX, y: box.minY + box.height * 0.92), 0.06),
            ("chin", CGPoint(x: box.midX, y: box.minY + box.height * 0.12), 0.04),
            ("noseBridge", CGPoint(x: box.midX, y: box.minY + box.height * 0.62), 0.03)
        ]
        var tones: [String: (r: Double, g: Double, b: Double)] = [:]
        for sample in samples {
            tones[sample.name] = patch(sample.point, radiusFraction: sample.radius)
        }
        let all = tones.values.sorted { luminance($0) < luminance($1) }
        let highlight = all.last ?? (r: 1, g: 1, b: 1)
        let shadow = all.first ?? highlight
        // The shadow tone is handed to the kernel as a per-channel RATIO to the
        // lit tone, so a face with no colour cast produces an exactly neutral
        // burn, and a cool-shadow portrait keeps its cool shadow.
        let shadowRatio = (
            r: min(1.10, max(0.55, shadow.r / max(0.05, highlight.r))),
            g: min(1.10, max(0.55, shadow.g / max(0.05, highlight.g))),
            b: min(1.10, max(0.55, shadow.b / max(0.05, highlight.b)))
        )

        let leftLum = tones["leftCheek"].map(luminance)
        let rightLum = tones["rightCheek"].map(luminance)
        let topLum = tones["forehead"].map(luminance)
        let bottomLum = tones["chin"].map(luminance)

        var lightX = 0.0
        var lightY = 0.0
        if let leftLum, let rightLum, abs(rightLum - leftLum) > 0.015 {
            lightX = max(-1, min(1, (rightLum - leftLum) / 0.06))
        }
        if let topLum, let bottomLum, abs(topLum - bottomLum) > 0.015 {
            lightY = max(-1, min(1, (topLum - bottomLum) / 0.08))
        }
        let midX = box.midX * extent.width
        let faceWidth = box.width * extent.width

        return LightResponse(
            lightInfo: CIVector(x: CGFloat(lightX), y: CGFloat(lightY),
                                z: midX, w: faceWidth),
            highlightTone: CIVector(x: CGFloat(highlight.r), y: CGFloat(highlight.g),
                                    z: CGFloat(highlight.b), w: 1),
            shadowTone: CIVector(x: CGFloat(shadowRatio.r), y: CGFloat(shadowRatio.g),
                                 z: CGFloat(shadowRatio.b), w: 1)
        )
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
        extent: CGRect,
        lightX: Double = 0
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
            drawHighlightGuide(geometry: geometry, ctx: hlCtx, extent: extent, lightX: lightX)
            drawShadowGuide(geometry: geometry, ctx: shCtx, extent: extent, lightX: lightX)
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

    /// R3 (2026-11-14): how strongly a structure at `x` should be drawn, given
    /// the light direction. On the lit side it is drawn fully, on the shadow
    /// side at a quarter strength - so a nose highlight and a C-zone sheen can
    /// no longer both sit on a face that is lit from one side only.
    private static func lightSideFactor(x: CGFloat, geometry: FacialBoneContourGeometry,
                                        lightX: Double) -> CGFloat {
        guard abs(lightX) > 0.12, geometry.faceWidth > 1 else { return 1 }
        let rel = (x - geometry.glabella.x) / (geometry.faceWidth * 0.5)
        let lit = rel * CGFloat(lightX > 0 ? 1 : -1)
        return 0.25 + 0.75 * min(1, max(0, lit * 0.5 + 0.5))
    }

    private static func drawHighlightGuide(
        geometry: FacialBoneContourGeometry,
        ctx: CGContext,
        extent: CGRect,
        lightX: Double = 0
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

        let leftCZAlpha = lightSideFactor(x: geometry.leftTemple.x, geometry: geometry, lightX: lightX)
        ctx.setStrokeColor(red: 0, green: 1.0, blue: 0, alpha: 0.90 * leftCZAlpha)
        ctx.beginPath()
        ctx.move(to: geometry.leftTemple)
        ctx.addQuadCurve(to: geometry.leftUpperZygoma, control: geometry.leftLateralOrbit)
        ctx.strokePath()

        // Right C-Zone arc
        let rightCZAlpha = lightSideFactor(x: geometry.rightTemple.x, geometry: geometry, lightX: lightX)
        ctx.setStrokeColor(red: 0, green: 1.0, blue: 0, alpha: 0.90 * rightCZAlpha)
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
        extent: CGRect,
        lightX: Double = 0
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

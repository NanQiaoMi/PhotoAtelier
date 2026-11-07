import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Applies non-destructive color and local adjustments to a CIImage graph.
/// The context works in extended linear sRGB; display/file encoding belongs to
/// the export boundary and must be selected there explicitly.
public final class PhotoEngine {
    public let context: CIContext

    private let workingColorSpace: CGColorSpace
    private static let analysisDimension = 64
    private static let maximumMaskRasterDimension = 2048

    static let localToneKernel = CIColorKernel(source: """
    kernel vec4 toneAdjust(__sample source, float saturation, float contrast,
                           float highlights, float shadows) {
        float alpha = source.a;
        vec3 color = alpha > 0.000001 ? source.rgb / alpha : vec3(0.0);
        float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
        color = mix(vec3(luminance), color, saturation);
        color = (color - vec3(0.18)) * contrast + vec3(0.18);
        float shadowWeight = 1.0 - smoothstep(0.0, 0.45, luminance);
        float highlightWeight = smoothstep(0.45, 1.0, luminance);
        color += color * (shadows * 0.15 * shadowWeight);
        color += color * (highlights * 0.15 * highlightWeight);
        return vec4(color * alpha, alpha);
    }
    """)

    private static let lutEncodeKernel = CIColorKernel(source: """
    float encodeSRGB(float value) {
        float signValue = value < 0.0 ? -1.0 : 1.0;
        float magnitude = abs(value);
        float encoded = magnitude <= 0.0031308
            ? 12.92 * magnitude
            : 1.055 * pow(magnitude, 1.0 / 2.4) - 0.055;
        return signValue * encoded;
    }
    float encodeRec709Gamma24(float value) {
        float signValue = value < 0.0 ? -1.0 : 1.0;
        return signValue * pow(abs(value), 1.0 / 2.4);
    }
    float encodeForLUT(float value, float mode) {
        if (mode < 0.5 || (mode > 2.5 && mode < 3.5)) { return encodeSRGB(value); }
        if (mode < 1.5) { return encodeRec709Gamma24(value); }
        if (mode > 3.5) {
            float v = abs(value);
            return sign(value) * (v < 0.018 ? 4.5 * v : 1.099 * pow(v, 0.45) - 0.099);
        }
        return value;
    }
    kernel vec4 encodeLUTInput(__sample source, vec3 domainMin,
                               vec3 domainRange, float mode) {
        float alpha = source.a;
        vec3 linear = alpha > 0.000001 ? source.rgb / alpha : vec3(0.0);
        linear = clamp(linear, vec3(-16.0), vec3(16.0));
        if (mode > 2.5 && mode < 3.5) {
            linear = vec3(0.8224619687 * linear.r + 0.1775380313 * linear.g,
                          0.0331941989 * linear.r + 0.9668058011 * linear.g,
                          0.0170826307 * linear.r + 0.0723974407 * linear.g + 0.9105199286 * linear.b);
        }
        vec3 encoded = vec3(encodeForLUT(linear.r, mode),
                            encodeForLUT(linear.g, mode),
                            encodeForLUT(linear.b, mode));
        vec3 normalized = clamp((encoded - domainMin) / domainRange,
                                vec3(0.0), vec3(1.0));
        return vec4(normalized, 1.0);
    }
    """)

    private static let lutDecodeKernel = CIColorKernel(source: """
    float decodeSRGB(float value) {
        float signValue = value < 0.0 ? -1.0 : 1.0;
        float magnitude = abs(value);
        float decoded = magnitude <= 0.04045
            ? magnitude / 12.92
            : pow((magnitude + 0.055) / 1.055, 2.4);
        return signValue * decoded;
    }
    float decodeRec709Gamma24(float value) {
        float signValue = value < 0.0 ? -1.0 : 1.0;
        return signValue * pow(abs(value), 2.4);
    }
    float decodeFromLUT(float value, float mode) {
        if (mode < 0.5 || (mode > 2.5 && mode < 3.5)) { return decodeSRGB(value); }
        if (mode < 1.5) { return decodeRec709Gamma24(value); }
        if (mode > 3.5) {
            float v = abs(value);
            return sign(value) * (v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1.0 / 0.45));
        }
        return value;
    }
    kernel vec4 decodeLUTOutput(__sample source, float mode) {
        vec3 decoded = vec3(decodeFromLUT(source.r, mode),
                            decodeFromLUT(source.g, mode),
                            decodeFromLUT(source.b, mode));
        if (mode > 2.5 && mode < 3.5) {
            decoded = vec3(1.2249401763 * decoded.r - 0.2249401763 * decoded.g,
                          -0.0420569547 * decoded.r + 1.0420569547 * decoded.g,
                          -0.0196375546 * decoded.r - 0.0786360456 * decoded.g + 1.0982736001 * decoded.b);
        }
        return vec4(decoded, 1.0);
    }
    """)

    private static let lutCoverageKernel = CIColorKernel(source: """
    float coverageSRGB(float value) {
        float signValue = value < 0.0 ? -1.0 : 1.0;
        float magnitude = abs(value);
        float encoded = magnitude <= 0.0031308
            ? 12.92 * magnitude
            : 1.055 * pow(magnitude, 1.0 / 2.4) - 0.055;
        return signValue * encoded;
    }
    float coverageRec709(float value) {
        float signValue = value < 0.0 ? -1.0 : 1.0;
        return signValue * pow(abs(value), 1.0 / 2.4);
    }
    float coverageEncode(float value, float mode) {
        if (mode < 0.5 || (mode > 2.5 && mode < 3.5)) { return coverageSRGB(value); }
        if (mode < 1.5) { return coverageRec709(value); }
        if (mode > 3.5) {
            float v = abs(value);
            return sign(value) * (v < 0.018 ? 4.5 * v : 1.099 * pow(v, 0.45) - 0.099);
        }
        return value;
    }
    kernel vec4 lutInputCoverage(__sample source, vec3 domainMin,
                                 vec3 domainRange, float mode) {
        float alpha = source.a;
        vec3 linear = alpha > 0.000001 ? source.rgb / alpha : vec3(0.0);
        linear = clamp(linear, vec3(-16.0), vec3(16.0));
        if (mode > 2.5 && mode < 3.5) {
            linear = vec3(0.8224619687 * linear.r + 0.1775380313 * linear.g,
                          0.0331941989 * linear.r + 0.9668058011 * linear.g,
                          0.0170826307 * linear.r + 0.0723974407 * linear.g + 0.9105199286 * linear.b);
        }
        vec3 encoded = vec3(coverageEncode(linear.r, mode),
                            coverageEncode(linear.g, mode),
                            coverageEncode(linear.b, mode));
        vec3 normalized = (encoded - domainMin) / domainRange;
        vec3 overflow = max(max(vec3(0.0) - normalized, normalized - vec3(1.0)),
                            vec3(0.0));
        float maximumOverflow = max(max(overflow.r, overflow.g), overflow.b);
        float coverage = 1.0 - smoothstep(0.0, 0.1, maximumOverflow);
        return vec4(coverage, coverage, coverage, 1.0);
    }
    """)

    // Treat LUT entries as numeric code values. Explicit nearest-node reads
    // avoid CIColorCube's backend-dependent interpolation/precision for sparse
    // tables and keep the declared trilinear function at every source knot.
    private static let lutSampleKernel = CIKernel(source: """
    vec4 cubeNode(sampler table, vec3 p, float size, float columns, float rows) {
        // p.b is an integer node index. Bias division away from exact integer
        // boundaries: some kernel backends approximate e.g. 3/3 below 1.
        float tileY = floor((p.b + 0.25) / columns);
        float tileX = p.b - tileY * columns;
        // Blue slices are tiled; bitmap rows are addressed from the top.
        vec2 position = vec2(tileX * size + p.r + 0.5,
                              rows * size - tileY * size - p.g - 0.5);
        return sample(table, samplerTransform(table, position));
    }
    kernel vec4 sampleTrilinearCube(sampler encoded, sampler table, float size,
                                     float columns, float rows) {
        vec3 p = clamp(sample(encoded, samplerCoord(encoded)).rgb,
                       vec3(0.0), vec3(1.0)) * (size - 1.0);
        vec3 lo = floor(p);
        vec3 hi = min(lo + vec3(1.0), vec3(size - 1.0));
        vec3 f = p - lo;
        vec4 c000 = cubeNode(table, vec3(lo.r, lo.g, lo.b), size, columns, rows);
        vec4 c100 = cubeNode(table, vec3(hi.r, lo.g, lo.b), size, columns, rows);
        vec4 c010 = cubeNode(table, vec3(lo.r, hi.g, lo.b), size, columns, rows);
        vec4 c110 = cubeNode(table, vec3(hi.r, hi.g, lo.b), size, columns, rows);
        vec4 c001 = cubeNode(table, vec3(lo.r, lo.g, hi.b), size, columns, rows);
        vec4 c101 = cubeNode(table, vec3(hi.r, lo.g, hi.b), size, columns, rows);
        vec4 c011 = cubeNode(table, vec3(lo.r, hi.g, hi.b), size, columns, rows);
        vec4 c111 = cubeNode(table, vec3(hi.r, hi.g, hi.b), size, columns, rows);
        vec4 z0 = mix(mix(c000, c100, f.r), mix(c010, c110, f.r), f.g);
        vec4 z1 = mix(mix(c001, c101, f.r), mix(c011, c111, f.r), f.g);
        return mix(z0, z1, f.b);
    }
    """)

    private static let lookKernel = CIColorKernel(source: """
    kernel vec4 protectLook(__sample originalSample, __sample gradedSample,
                            __sample coverageSample,
                            float intensity, float preserveLuminance,
                            float protectSkin, float protectNeutrals,
                            float gamutCompression) {
        float alpha = originalSample.a;
        vec3 original = alpha > 0.000001
            ? originalSample.rgb / alpha
            : vec3(0.0);
        vec3 graded = gradedSample.rgb;
        float originalLuma = max(dot(original, vec3(0.2126, 0.7152, 0.0722)), 0.0);
        float gradedLuma = dot(graded, vec3(0.2126, 0.7152, 0.0722));
        float maxChannel = max(max(original.r, original.g), original.b);
        float minChannel = min(min(original.r, original.g), original.b);
        float neutralMask = 1.0 - smoothstep(0.008, 0.08, maxChannel - minChannel);
        float skinWarmth = smoothstep(0.015, 0.10, original.r - original.g)
                         * smoothstep(0.004, 0.065, original.g - original.b);
        float skinLuma = smoothstep(0.035, 0.18, originalLuma)
                       * (1.0 - smoothstep(0.82, 1.35, originalLuma));
        float skinMask = skinWarmth * skinLuma;
        float protection = max(protectNeutrals * neutralMask,
                               protectSkin * skinMask);
        float lookWeight = intensity * coverageSample.r * (1.0 - protection);

        if (gradedLuma > 0.00001) {
            float lumaRatio = clamp(originalLuma / gradedLuma, 0.0625, 16.0);
            vec3 lumaMatched = graded * lumaRatio;
            graded = mix(graded, lumaMatched, preserveLuminance);
        }

        float gradedLumaForGamut = dot(graded, vec3(0.2126, 0.7152, 0.0722));
        if (gradedLumaForGamut >= 0.0 && gradedLumaForGamut <= 1.0) {
            float chromaScale = 1.0;
            if (graded.r > 1.0) {
                chromaScale = min(chromaScale, (1.0 - gradedLumaForGamut) / (graded.r - gradedLumaForGamut));
            }
            if (graded.g > 1.0) {
                chromaScale = min(chromaScale, (1.0 - gradedLumaForGamut) / (graded.g - gradedLumaForGamut));
            }
            if (graded.b > 1.0) {
                chromaScale = min(chromaScale, (1.0 - gradedLumaForGamut) / (graded.b - gradedLumaForGamut));
            }
            if (graded.r < 0.0) {
                chromaScale = min(chromaScale, (0.0 - gradedLumaForGamut) / (graded.r - gradedLumaForGamut));
            }
            if (graded.g < 0.0) {
                chromaScale = min(chromaScale, (0.0 - gradedLumaForGamut) / (graded.g - gradedLumaForGamut));
            }
            if (graded.b < 0.0) {
                chromaScale = min(chromaScale, (0.0 - gradedLumaForGamut) / (graded.b - gradedLumaForGamut));
            }
            chromaScale = clamp(chromaScale, 0.0, 1.0);
            vec3 compressed = vec3(gradedLumaForGamut)
                            + (graded - vec3(gradedLumaForGamut)) * chromaScale;
            graded = mix(graded, compressed, gamutCompression);
        }
        vec3 outputColor = mix(original, graded, lookWeight);
        return vec4(outputColor * alpha, alpha);
    }
    """)

    public init() {
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        self.workingColorSpace = colorSpace
        self.context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .workingFormat: CIFormat.RGBAh,
            .outputPremultiplied: false,
            .cacheIntermediates: false
        ])
    }

    /// Downsamples an image for analysis-only use (never for export): the analysis
    /// pipeline measures a small raster anyway, so feeding a capped sample avoids
    /// decoding full-resolution graphs repeatedly for previews. The caller keeps
    /// the original image for the actual render, so export pixels are unchanged.
    public func analysisSample(_ image: CIImage, maxDimension: Int = 1024) -> CIImage {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 1, extent.height > 1 else { return image }
        let limit = CGFloat(max(64, maxDimension))
        let scale = min(1, limit / max(extent.width, extent.height))
        guard scale < 0.999 else { return image }
        let translated = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int((extent.width * scale).rounded(.up)))
        let height = max(1, Int((extent.height * scale).rounded(.up)))
        return scaled.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Shared recipe/configuration validation used by both processing and UI
    /// recipe loading. Ranges match the normalized controls in AdjustmentSettings.
    public static func validate(_ settings: AdjustmentSettings) throws {
        try require(settings.exposureEV, within: -8...8, named: "曝光")
        try require(settings.temperature, within: -1...1, named: "色温")
        try require(settings.tint, within: -1...1, named: "色调")
        try require(settings.contrast, within: 0...4, named: "对比度")
        try require(settings.saturation, within: 0...4, named: "饱和度")
        try require(settings.highlights, within: -1...1, named: "高光")
        try require(settings.shadows, within: -1...1, named: "阴影")
        if let tonal = settings.tonalCurve { try TonalCurveEngine.validate(tonal) }
        try require(settings.lutIntensity, within: 0...1, named: "LUT 强度")
        try require(settings.preserveLuminance, within: 0...1, named: "亮度保护")
        try require(settings.protectSkin, within: 0...1, named: "肤色保护")
        try require(settings.protectNeutrals, within: 0...1, named: "中性色保护")
        try require(settings.gamutCompression, within: 0...1, named: "色域压缩")
        if let harmony = settings.colorHarmony { try ColorHarmonyEngine.validate(harmony) }
        if let effects = settings.creativeEffects { try CreativeEffectsEngine.validate(effects) }
        if let adaptation = settings.adaptiveLUT { try LUTAdaptationEngine.validate(adaptation) }
        if let colorTools = settings.colorTools { try colorTools.validate() }
        if let lensEffects = settings.lensEffects { try LensEffectsEngine.validate(lensEffects) }
        if let liquify = settings.liquify { try FaceReshapeEngine.validate(liquify) }
        // A neutral certificate field (enabled == false) is explicitly inert: the
        // recipe version gate accepts it on old payloads, so it must not be
        // rejected here by nested parameter validation. Active settings still fail
        // loudly with the same malformed values.
        if let certificate = settings.certificatePhoto, !certificate.isNeutral {
            try certificate.validated()
        }
        if let repair = settings.repairBrush { try repair.validate() }
        if let makeup = settings.makeup, !makeup.isNeutral { _ = try makeup.validated() }
        if let facialZonal = settings.facialZonal, !facialZonal.isNeutral { _ = try facialZonal.validated() }
        if let pet = settings.petEnhancement, !pet.isNeutral { _ = try pet.validated() }
        if let portrait = settings.portrait { try PortraitRefinementEngine.validate(portrait) }
        if let reference = settings.referenceColor {
            try reference.profile.validate()
            try require(reference.strength, within: 0...1, named: "参考图追色强度")
        }
        try require(settings.rotationDegrees, within: -45...45, named: "旋转")
        try require(settings.verticalPerspective, within: -0.3...0.3, named: "垂直透视")
        try require(settings.horizontalPerspective, within: -0.3...0.3, named: "水平透视")
        try require(settings.lensCropFactor, within: 0...10, named: "镜头裁切系数")
        try require(settings.lensFocalLength, within: 0...2000, named: "镜头实际焦距")
        guard (settings.lensProfileID?.count ?? 0) <= 1024 else {
            throw AtelierError.invalidConfiguration("镜头配置标识过长。")
        }
        guard settings.masks.count <= 16 else {
            throw AtelierError.invalidConfiguration("局部蒙版数量不能超过 16 个。")
        }

        guard settings.masks.reduce(0, { $0 + $1.components.count }) <= 64 else {
            throw AtelierError.invalidConfiguration("所有蒙版的修边步骤总数不能超过 64 个。")
        }
        var identifiers = Set<UUID>()
        var totalMaskPoints = 0
        for (index, mask) in settings.masks.enumerated() {
            let prefix = "第 \(index + 1) 个蒙版"
            guard identifiers.insert(mask.id).inserted else {
                throw AtelierError.invalidConfiguration("\(prefix)标识与其他蒙版重复。")
            }
            do {
                try LocalMaskValidator.validate(mask)
            } catch {
                throw AtelierError.invalidConfiguration("\(prefix)：\(error.localizedDescription)")
            }
            totalMaskPoints += mask.points.count + mask.components.reduce(0) { $0 + $1.points.count }
            guard totalMaskPoints <= 32768 else {
                throw AtelierError.invalidConfiguration("全部蒙版的总笔迹点数不能超过 32768。")
            }
            for component in mask.components {
                guard identifiers.insert(component.id).inserted else {
                    throw AtelierError.invalidConfiguration("\(prefix)组件标识与其他蒙版或组件重复。")
                }
            }
        }
    }

    public func process(_ image: CIImage,
                        settings: AdjustmentSettings,
                        lut: LUTCube?,
                        initialReport: ProcessingReport = .init(),
                        outputColorSpace: OutputColorSpace? = nil,
                        cancellation: CancellationToken? = nil,
                        preparedContentSelections: ContentSelectionResult? = nil,
                        preparedLUTContext: LUTSemanticContext? = nil,
                        preparedPersonMatte: PersonMatte? = nil,
                        preparedCertificateFaceBox: CGRect? = nil,
                        /// Optional pre-computed face landmarks for the make-up stage.
                        /// Pass to skip this engine's own Vision detection (tests or
                        /// advanced callers that already detected faces); `nil` reuses
                        /// the landmarks detected for portrait/reference-color, or runs
                        /// one detection when make-up is the only face-aware stage.
                        preparedMakeupFaces: [FaceLandmarkSet]? = nil,
                        /// Optional pre-detected animal targets for the pet enhancement stage.
                        preparedPetTargets: [PetTarget]? = nil) throws -> ProcessedPhoto {
        try Self.validate(settings)
        try cancellation?.check()

        let originalExtent = try validExtent(of: image)
        var report = initialReport
        var working = image

        if settings.lensCorrection && !report.lensCorrectionApplied {
            report.warnings.append("本图未应用镜头配置校正（详见输入报告）。")
        }

        let stats: ImageStatistics?
        if settings.autoExposure || settings.autoWhiteBalance {
            stats = try analyze(working, extent: originalExtent)
        } else {
            stats = nil
        }
        try cancellation?.check()

        // Implemented order (accepted deviation from docs/p1 plan §4): the P0
        // legacy pipeline applies the basic tone block before the geometry block,
        // and reordering it would change the pixel output of every v1–v10 recipe.
        // Lead decision (P1-6 review, F2): keep the legacy order and document it.
        // Real sequence: basic tone → geometry → liquify → color tools → lens
        // effects → portrait → reference color → local masks → LUT.
        // The plan's ideal `geometry → liquify → basic tone` is NOT implemented to
        // preserve the recipe pixel-compatibility contract.
        working = try applyBasicTone(working, settings: settings, stats: stats,
                                     report: &report, cancellation: cancellation)
        working = try applyGeometry(working, settings: settings, report: &report,
                                    cancellation: cancellation)
        working = try applyLiquify(working, settings: settings, report: &report,
                                   cancellation: cancellation)
        try cancellation?.check()

        // v11 color tools: basic tone → curves → HSL → grading → lens effects.
        // Both stages are pure filters on the working image; a neutral or absent
        // setting is skipped entirely so the pre-v11 pixel path stays exact.
        if let colorTools = settings.colorTools, !colorTools.isNeutral {
            working = try ColorToolsEngine.apply(colorTools, to: working,
                                                 cancellation: cancellation)
            var stages: [String] = []
            if let curves = colorTools.curves, !curves.isNeutral { stages.append("curves") }
            if let hsl = colorTools.hsl, !hsl.isNeutral { stages.append("hsl") }
            if let grading = colorTools.grading, !grading.isNeutral { stages.append("grading") }
            report.colorTools = ColorToolsReport(stages: stages)
        }
        if let lensEffects = settings.lensEffects, !lensEffects.isNeutral {
            working = try LensEffectsEngine.apply(lensEffects, to: working,
                                                  cancellation: cancellation)
            let chromatic = max(abs(lensEffects.chromaticAberrationRed),
                                abs(lensEffects.chromaticAberrationBlue))
            var stages = report.colorTools?.stages ?? []
            stages.append("lensEffects")
            report.colorTools = ColorToolsReport(stages: stages,
                                                 vignetteAmount: lensEffects.vignetteAmount,
                                                 chromaticAberration: chromatic)
        }
        try cancellation?.check()

        // P1-B v12 manual repair/clone brush: after lens effects and before the
        // portrait stage, so face masks, reference color and local edits all see
        // the repaired pixels. An absent or empty stroke list skips the stage
        // entirely and keeps the pre-v12 pixel path exact. Strength/feather
        // blending happens in this engine's working space (extended linear sRGB),
        // so partial-strength values differ from sRGB-only unit tests.
        if let repair = settings.repairBrush, !repair.isNeutral {
            working = try RepairBrushEngine.apply(to: working, strokes: repair.strokes)
            let healCount = repair.strokes.filter { $0.mode == .heal }.count
            report.repairBrush = RepairBrushReport(applied: true,
                                                   strokeCount: repair.strokes.count,
                                                   healStrokeCount: healCount,
                                                   cloneStrokeCount: repair.strokes.count - healCount)
        }
        try cancellation?.check()

        // Pipeline order: global tone/geometry → basic tone → color tools →
        // lens effects → repair brush → portrait refinement → reference-color
        // match → local masks/detail → LUT → output gamut.
        // Portrait masks are measured on the globally adjusted image and the
        // refined result becomes the reference for local-mask measurement, so
        // local edits see the same skin the user sees. A neutral portrait
        // setting skips the portrait stage (pre-v10 path); a neutral or absent
        // reference-color setting skips the match (pre-v10 path).
        //
        // Face masks are shared by the two v10 stages so a photo that uses both
        // portrait refinement and skin-limited reference color runs Vision once.
        // They are measured before portrait refinement because the skin geometry
        // is unchanged by the refinement; the match then sees refined skin.
        let portraitActive = settings.portrait.map { !$0.isNeutral } ?? false
        let referenceColor = settings.referenceColor
        let referenceColorActive = referenceColor.map { !$0.isNeutral } ?? false
        let makeupActive = settings.makeup.map { !$0.isNeutral } ?? false
        let facialZonalActive = settings.facialZonal.map { !$0.isNeutral } ?? false
        let needsPortraitMasks = portraitActive
            || (referenceColorActive && referenceColor?.skinOnly == true)
        let needsFaceMasks = needsPortraitMasks || makeupActive || facialZonalActive
        // One Vision detection feeds portrait masks, skin-limited reference color
        // and the make-up stage (the same landmarks are reused instead of running a
        // second detector in the make-up branch). Portrait/refcolor keep their
        // historical first-4-face window; make-up may use up to its own limit when
        // it is the only reason for detecting.
        let detectedFaces: [FaceLandmarkSet]
        if needsFaceMasks {
            detectedFaces = FaceSemanticAnalyzer.detect(in: working,
                maxFaces: makeupActive ? MakeupEngine.maximumFaces : 4)
        } else {
            detectedFaces = []
        }
        // Only portrait/refcolor consume masks: a make-up-only photo detects faces
        // for the make-up stage but must not pay for four unused semantic mats.
        let preparedFaceMasks = needsPortraitMasks
            ? detectedFaces.prefix(4).map { landmarks in
                FaceSemanticAnalyzer.masks(image: working,
                                           faceBounds: landmarks.boundingBox,
                                           landmarks: landmarks)
            }.filter { !$0.isEmpty }
            : []
        let preparedLandmarks = detectedFaces
        if let portrait = settings.portrait, portraitActive {
            let faces = preparedFaceMasks
            if faces.isEmpty {
                let note = "未检测到可用人脸或本机 Vision 不可用，人像修复已跳过（原图保持不变）。"
                report.portrait = PortraitRefinementReport(applied: false, faceCount: 0, note: note)
                report.warnings.append(note)
            } else {
                let portraitResult = try PortraitRefinementEngine.apply(
                    working, settings: portrait, faceMasks: faces,
                    landmarks: preparedLandmarks,
                    context: context, cancellation: cancellation)
                working = portraitResult.image
                report.portrait = portraitResult.report
                if let note = portraitResult.report.note {
                    report.warnings.append(note)
                }
            }
        }
        try cancellation?.check()

        // P2-H: Smart facial zonal wrinkle smoothing & anti-shine matte finish.
        if let facialZonal = settings.facialZonal, !facialZonal.isNeutral {
            let faces = detectedFaces
            let facialZonalResult = try FacialZonalRefinementEngine.apply(
                working, settings: facialZonal,
                faceLandmarks: faces.isEmpty ? nil : faces,
                context: context, cancellation: cancellation
            )
            working = facialZonalResult.image
            report.facialZonal = facialZonalResult.report
            if let note = facialZonalResult.report.note {
                report.warnings.append(note)
            }
        }
        try cancellation?.check()

        // P1-C v13 heuristic make-up: after portrait refinement and before
        // reference color / local masks, so the match and local edits see the
        // made-up pixels. Absent or fully neutral settings skip the stage and keep
        // the pre-v13 pixel path exact. No usable face → explicit skip with report
        // and warning, never a silent edit.
        //
        // Output headroom: C2 clamps its tinted layer to <=1.5 linear, so this
        // stage may hand >1 values to the next stages. ReferenceColor and the LUT
        // kernels clamp their inputs to 0...1 (documented in their engines), so the
        // >1 headroom does not leak past them; local masks can still sample up to
        // 1.5 before the LUT. `report.makeup.applied == true` means "stage ran with
        // usable landmarks"; heuristic masks can still be a geometric no-op on an
        // individual face.
        if let makeup = settings.makeup, !makeup.isNeutral {
            let faces: [FaceLandmarkSet]
            if let preparedMakeupFaces {
                faces = preparedMakeupFaces
            } else {
                faces = preparedLandmarks
            }
            if faces.contains(where: { $0.hasUsableGeometry }) {
                do {
                    let madeUp = try MakeupEngine.apply(to: working, faces: faces,
                                                        settings: makeup)
                    let strength = max(max(makeup.lipIntensity, makeup.browDensity),
                                       max(makeup.cheekIntensity, makeup.eyeshadowIntensity))
                    // Below ~5% strength a 48px probe cannot reliably distinguish a
                    // real (tiny) change from a mask miss, so keep the stage recorded
                    // as applied instead of false-reporting "mask not hit".
                    let difference = renderedDifference(working, madeUp)
                    let threshold = max(Float(0.000001), Float(0.0001 * strength))
                    if difference > threshold {
                        working = madeUp
                        report.makeup = MakeupReport(applied: true, faceCount: faces.count)
                    } else if strength < 0.05 {
                        working = madeUp
                        report.makeup = MakeupReport(
                            applied: true, faceCount: faces.count,
                            note: "妆容强度极低（\(String(format: "%.3f", strength))），未检测到可测量的像素变化。")
                    } else {
                        let note = "检测到人脸但妆容掩码未命中有效区域（启发式蒙版为空/过小或强度极低），该段未改变像素。"
                        working = madeUp
                        report.makeup = MakeupReport(applied: false, faceCount: faces.count,
                                                     note: note)
                        report.warnings.append(note)
                    }
                } catch {
                    let note = "妆容应用失败：\(error.localizedDescription)；该段已跳过（原图保持不变）。"
                    report.makeup = MakeupReport(applied: false, faceCount: faces.count,
                                                 note: note)
                    report.warnings.append(note)
                }
            } else {
                let note = "未检测到可用人脸或本机 Vision 不可用，妆容已跳过（原图保持不变）。"
                report.makeup = MakeupReport(applied: false, faceCount: 0, note: note)
                report.warnings.append(note)
            }
        }
        try cancellation?.check()

        if let reference = referenceColor, referenceColorActive {
            working = try applyReferenceColor(reference, to: working,
                                              faceMasks: preparedFaceMasks,
                                              report: &report, cancellation: cancellation)
        }
        try cancellation?.check()

        // P2-G: Smart body and hand skin refinement (neck smoothing, vein reduction, body tone harmonization).
        if let bodySkin = settings.bodySkin, !bodySkin.isNeutral {
            let bodySkinResult = try BodySkinRefinementEngine.apply(
                working, settings: bodySkin, personMatte: preparedPersonMatte,
                faceLandmarks: detectedFaces.isEmpty ? nil : detectedFaces,
                context: context, cancellation: cancellation
            )
            working = bodySkinResult.image
            report.bodySkin = bodySkinResult.report
        }
        try cancellation?.check()

        // P2-F: Smart clothing wrinkle smoothing & crease removal.
        if let clothing = settings.clothing, !clothing.isNeutral {
            let clothingResult = try ClothingRefinementEngine.apply(
                working, settings: clothing, personMatte: preparedPersonMatte,
                faceLandmarks: detectedFaces.isEmpty ? nil : detectedFaces,
                context: context, cancellation: cancellation
            )
            working = clothingResult.image
            report.clothing = clothingResult.report
        }
        try cancellation?.check()

        // P2-D: Studio backdrop smoothing, wrinkle elimination & defect cleanup.
        if let backdrop = settings.backdrop, !backdrop.isNeutral {
            let backdropResult = try BackdropRefinementEngine.apply(
                working, settings: backdrop, personMatte: preparedPersonMatte,
                context: context, cancellation: cancellation
            )
            working = backdropResult.image
            report.backdrop = backdropResult.report
        }
        try cancellation?.check()

        // P1-B: background replacement / certificate photo runs after reference
        // color and before local masks. A size preset changes the canvas extent;
        // the local-mask reference below therefore uses the cropped image and mask
        // coordinates are normalized against the new extent (documented in
        // CertificatePhotoSettings; the report carries a review note).
        if let certificate = settings.certificatePhoto, !certificate.isNeutral {
            working = try applyCertificatePhoto(working, settings: certificate,
                                                preparedMatte: preparedPersonMatte,
                                                preparedFaceBox: preparedCertificateFaceBox,
                                                report: &report, cancellation: cancellation)
        }
        try cancellation?.check()

        // P2-I: Smart pet enhancement (fur fluffiness, eye brightening, muzzle moisture, coat dehaze, coat whiten).
        if let pet = settings.petEnhancement, !pet.isNeutral {
            let petResult = try PetEnhancementEngine.apply(
                working, settings: pet,
                targets: preparedPetTargets,
                context: context, cancellation: cancellation
            )
            working = petResult.image
            report.petEnhancement = petResult.report
            if let note = petResult.report.note {
                report.warnings.append(note)
            }
        }
        try cancellation?.check()

        // The range/protection reference remains the global-only image throughout
        // both mask stages, avoiding feedback from preceding local adjustments.
        let localMaskReference = working
        var contentTargets = Set(settings.masks.filter { $0.enabled && $0.opacity > 0 }
            .compactMap(\.contentSelection))
        let adaptiveLUTActive = settings.adaptiveLUT?.enabled == true && lut != nil && settings.lutIntensity > 0
        if adaptiveLUTActive { contentTargets.insert(.faceSkin) }
        report.lutAdaptation = nil
        // A preview caller may reuse one result only while its source, global
        // reference and requested targets are unchanged. Batch callers leave
        // this nil so each still image receives fresh Vision requests.
        let contentSelections: ContentSelectionResult?
        if contentTargets.isEmpty {
            contentSelections = nil
        } else if let preparedContentSelections {
            contentSelections = preparedContentSelections
        } else {
            contentSelections = try ContentSelectionAnalyzer.analyze(
                reference: localMaskReference, targets: contentTargets, context: context, cancellation: cancellation)
        }
        report.contentSelection = contentSelections?.report
        if let contentSelections { report.warnings.append(contentsOf: contentSelections.report.warnings) }
        var detailPlans: [UUID: LocalDetailPlan] = [:]
        report.localDetails = nil
        for mask in settings.masks where mask.enabled && mask.opacity > 0 {
            guard let adaptation = mask.detailAdaptation else { continue }
            try cancellation?.check()
            let coverage = try localMaskImage(mask, reference: localMaskReference,
                                              contentSelections: contentSelections)
            // Inversion/additions no longer establish that the effective area
            // is skin, even when its base selection came from face landmarks.
            let retainsSkinMeaning = !mask.inverted && !mask.components.contains { $0.operation == .add }
            let detailTarget = mask.contentSelection == .faceSkin && !retainsSkinMeaning ? nil : mask.contentSelection
            detailPlans[mask.id] = try AdaptiveLocalDetailAnalyzer.analyze(reference: localMaskReference,
                coverage: coverage, maskID: mask.id, target: detailTarget,
                adaptation: adaptation, context: context, cancellation: cancellation,
                isSpatiallyLimited: !mask.inverted && (mask.kind == .brush || mask.kind == .radial))
        }
        if !detailPlans.isEmpty {
            report.localDetails = settings.masks.compactMap { detailPlans[$0.id] }
            working = try AdaptiveDetailRenderer.apply(reference: localMaskReference, masks: settings.masks,
                plans: detailPlans, context: context, contentSelections: contentSelections, cancellation: cancellation)
        }
        for mask in settings.masks where mask.enabled && mask.stage == .beforeLook {
            try cancellation?.check()
            if mask.kind == .brush, mask.points.isEmpty, mask.components.isEmpty {
                report.warnings.append("画笔蒙版“\(mask.name)”没有笔迹，已跳过。")
                continue
            }
            working = try applyLocalMask(mask, to: working, reference: localMaskReference,
                                         contentSelections: contentSelections)
        }

        if let lut, settings.lutIntensity > 0 {
            try validate(lut)
            report.lutCompatibility = LUTCompatibilityInspector.inspect(lut, colorSpace: settings.lutColorSpace)
            report.warnings.append(".cube 文件不包含输入传递函数标记，已按“\(settings.lutColorSpace.title)”解释输入和输出；Log 曲线 LUT 尚不支持自动识别。")
            let lutResult = try applyLUT(lut, to: working, colorSpace: settings.lutColorSpace,
                                         preciseSampling: settings.colorHarmony != nil
                                            || adaptiveLUTActive
                                            || settings.lutColorSpace == .displayP3
                                            || settings.lutColorSpace == .rec709OETF)
            let outsideFraction = try fractionOutsideLUTDomain(lutResult.coverage, extent: working.extent)
            if outsideFraction > 0.01 {
                report.warnings.append(String(format: "约 %.1f%% 的取样像素超出 LUT DOMAIN，已平滑降低 LUT 强度以保留域外高光与负值。", outsideFraction * 100))
            }
            guard let kernel = Self.lookKernel else {
                throw AtelierError.invalidConfiguration("Core Image LUT 保护 kernel 编译失败。")
            }
            let lutReference = working
            func renderLook(_ intensity: Double, _ luminance: Double, _ skin: Double, _ neutral: Double) throws -> CIImage {
                guard let protected = kernel.apply(extent: lutReference.extent, arguments: [
                    lutReference, lutResult.graded, lutResult.coverage,
                    NSNumber(value: intensity), NSNumber(value: luminance),
                    NSNumber(value: skin), NSNumber(value: neutral),
                    // A P3 or target-aware pipeline must not first squeeze into sRGB.
                    NSNumber(value: settings.colorHarmony != nil || adaptiveLUTActive || settings.lutColorSpace == .displayP3
                             ? 0 : settings.gamutCompression)
                ]) else { throw AtelierError.invalidConfiguration("Core Image LUT 保护 kernel 无法生成输出。") }
                return protected
            }
            if adaptiveLUTActive {
                let semantics = try preparedLUTContext ?? LUTSemanticContext.analyze(localMaskReference, cancellation: cancellation)
                let adapted = try LUTAdaptationEngine.apply(reference: lutReference, cube: lut, settings: settings,
                    selections: contentSelections, semantics: semantics, target: outputColorSpace,
                    context: context, cancellation: cancellation, render: renderLook)
                working = adapted.image; report.lutAdaptation = adapted.report
            } else {
                working = try renderLook(settings.lutIntensity, settings.preserveLuminance,
                                         settings.protectSkin, settings.protectNeutrals)
            }
        }
        try cancellation?.check()

        for mask in settings.masks where mask.enabled && mask.stage == .afterLook {
            try cancellation?.check()
            guard mask.kind != .brush || !mask.points.isEmpty || !mask.components.isEmpty else {
                report.warnings.append("画笔蒙版“\(mask.name)”没有笔迹，已跳过。")
                continue
            }
            if LocalMaskEngine.isLegacyCompatibleAfterLook(mask) {
                working = try apply(mask, to: working)
            } else {
                working = try applyLocalMask(mask, to: working, reference: localMaskReference,
                                             contentSelections: contentSelections)
            }
        }

        try cancellation?.check()
        if let effects = settings.creativeEffects, !effects.isNeutral {
            working = try CreativeEffectsEngine.apply(effects, to: working, context: context,
                                                       cancellation: cancellation)
        }
        let hasCreativeEffects = !(settings.creativeEffects?.isNeutral ?? true)
        let hasColorTreatment = (lut != nil && settings.lutIntensity > 0)
            || settings.masks.contains { $0.enabled } || hasCreativeEffects
        if hasColorTreatment || (outputColorSpace != nil && settings.colorHarmony != nil) {
            let candidate = working
            let scene = try ColorSceneAnalyzer.analyze(image: localMaskReference, context: context)
            if let harmony = settings.colorHarmony, harmony.enabled, hasColorTreatment {
                working = try ColorHarmonyEngine.protect(reference: localMaskReference, candidate: working,
                                                        settings: harmony, scene: scene, context: context)
            }
            try cancellation?.check()
            if let target = outputColorSpace, settings.colorHarmony != nil || hasCreativeEffects || adaptiveLUTActive {
                working = try OutputGamutMapper.map(working, to: target, context: context)
            }
            report.colorQuality = try ColorQualityInspector.inspect(reference: localMaskReference,
                candidate: candidate, final: working, scene: scene, settings: settings.colorHarmony,
                outputColorSpace: outputColorSpace, context: context)
        }
        try cancellation?.check()
        return ProcessedPhoto(image: working, report: report, contentSelections: contentSelections)
    }

    /// Returns the mask's effective coverage as a linear, single-channel CIImage.
    /// Its extent and origin match `reference`; geometry is rasterized at no more
    /// than 2048 pixels per longest edge before Core Image scales it back.
    public func localMaskImage(_ mask: LocalMask, reference: CIImage,
                               contentSelections: ContentSelectionResult? = nil) throws -> CIImage {
        var settings = AdjustmentSettings()
        settings.masks = [mask]
        try Self.validate(settings)
        let extent = try validExtent(of: reference)
        guard mask.enabled, mask.kind != .brush || !mask.points.isEmpty || !mask.components.isEmpty else {
            return CIImage(color: .black).cropped(to: extent)
        }
        if LocalMaskEngine.isLegacyCompatibleAfterLook(mask) {
            return try renderMask(mask, extent: extent)
        }
        return try LocalMaskEngine.coverage(for: mask, reference: reference, context: context,
                                            contentSelections: contentSelections)
    }

    /// Builds the stable mask-selection reference using global adjustments and
    /// geometry only. Masks, LUTs and creative effects are removed.
    public func maskReferenceImage(_ image: CIImage, settings: AdjustmentSettings,
                                   cancellation: CancellationToken? = nil) throws -> CIImage {
        var base = settings
        base.masks = []
        base.creativeEffects = nil
        base.adaptiveLUT = nil
        return try process(image, settings: base, lut: nil, cancellation: cancellation).image
    }

    /// Samples a small neighborhood and returns its average as encoded sRGB.
    public func sampleMaskColor(at point: MaskPoint, reference: CIImage) throws -> MaskColor {
        try LocalMaskEngine.sampleColor(at: point, reference: reference, context: context)
    }

    /// Summarizes the actual mask-weighted region and provides conservative
    /// suggestions. Suggestions are data only and never mutate the recipe.
    public func inspectLocalMask(_ mask: LocalMask, reference: CIImage,
                                 contentSelections: ContentSelectionResult? = nil) throws -> MaskInspection {
        let coverage = try localMaskImage(mask, reference: reference, contentSelections: contentSelections)
        return try LocalMaskEngine.inspect(mask, reference: reference, context: context,
                                           coverageImage: coverage)
    }

    private func applyLocalMask(_ mask: LocalMask, to image: CIImage,
                                reference: CIImage, contentSelections: ContentSelectionResult?) throws -> CIImage {
        try LocalMaskEngine.apply(mask, to: image, reference: reference, context: context,
                                  contentSelections: contentSelections,
                                  makeFilter: { try self.makeFilter($0) },
                                  applyTemperature: { temperature, tint, source in
                                      try self.applyTemperature(temperature, tint: tint, to: source)
                                  })
    }

    private static func require(_ value: Double, within range: ClosedRange<Double>, named name: String) throws {
        guard value.isFinite, range.contains(value) else {
            throw AtelierError.invalidConfiguration("\(name) 超出允许范围 \(range.lowerBound)...\(range.upperBound)。")
        }
    }

    /// Applies the reference-color match ("AI 追色") to the working image.
    ///
    /// The match is the global OKLab quantile transfer from `ReferenceColorMatcher`.
    /// When `skinOnly` is requested the match is blended through the union of the
    /// detected facial skin mattes. Without a usable skin matte — missing, or
    /// present but covering no more than `minimumSkinMaskCoverage` of the image —
    /// the stage is skipped explicitly (the report and a warning say why) instead
    /// of silently falling back to a global match the user did not ask for. The
    /// skin matte is resolved before any matching work so a skipped skin-only
    /// match never pays for a full-image match it would discard.
    private func applyReferenceColor(_ reference: ReferenceColorSettings,
                                     to image: CIImage,
                                     faceMasks: [FaceSemanticMaskSet],
                                     report: inout ProcessingReport,
                                     cancellation: CancellationToken?) throws -> CIImage {
        let extent = try validExtent(of: image)
        try cancellation?.check()
        var skinMask: CIImage?
        if reference.skinOnly {
            guard let usable = usableSkinMask(faceMasks, extent: extent) else {
                let skipNote = "未检测到可用人脸/皮肤蒙版，或皮肤覆盖不足（≤ \(Self.minimumSkinMaskCoverage * 100)%），皮肤限定的参考图追色已跳过（原图保持不变）。"
                report.referenceColor = ReferenceColorReport(
                    applied: false, strength: reference.strength, skinOnly: true,
                    algorithmVersion: reference.profile.algorithmVersion, note: skipNote)
                report.warnings.append(skipNote)
                return image
            }
            skinMask = usable
        }
        let matched = try ReferenceColorMatcher.apply(reference.profile, to: image,
                                                      strength: reference.strength)
        var output = matched
        var note: String?
        if let skinMask {
            let filter = try makeFilter("CIBlendWithMask")
            filter.setValue(matched, forKey: kCIInputImageKey)
            filter.setValue(image, forKey: "inputBackgroundImage")
            filter.setValue(skinMask, forKey: "inputMaskImage")
            guard let blended = filter.outputImage else {
                throw AtelierError.invalidConfiguration("追色皮肤限定合成无法生成输出。")
            }
            output = blended.cropped(to: extent)
            note = "皮肤限定：参考图追色仅应用于检测到的皮肤区域。"
        }
        report.referenceColor = ReferenceColorReport(
            applied: true, strength: reference.strength, skinOnly: reference.skinOnly,
            algorithmVersion: reference.profile.algorithmVersion, note: note)
        if let note { report.warnings.append(note) }
        return output.cropped(to: extent)
    }

    /// Canonical skin-matte coverage threshold shared by the portrait inspector
    /// and the skin-limited reference-color stage. A matte covering no more than
    /// 0.05% of the frame is treated as unusable (grayscale faces, false
    /// positives, blank frames); a small but real face still qualifies.
    public static let minimumSkinMaskCoverage = 0.0005

    /// True when a measured skin-matte coverage is high enough to act on.
    public static func isUsableSkinCoverage(_ coverage: Double) -> Bool {
        coverage.isFinite && coverage > minimumSkinMaskCoverage
    }

    /// Fraction of the frame covered by a soft RGB matte. Samples at most 128 px
    /// on the longest edge; this is a state decision helper, never pixel output.
    public static func skinMaskCoverage(of mask: CIImage, context: CIContext) -> Double {
        let extent = mask.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width >= 1, extent.height >= 1,
              extent.width < 100_000, extent.height < 100_000 else { return 0 }
        let scale = min(1, 128 / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let sample = mask
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: bounds.width / extent.width,
                                               y: bounds.height / extent.height))
            .cropped(to: bounds)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        pixels.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            context.render(sample, toBitmap: address,
                           rowBytes: width * 4 * MemoryLayout<Float>.stride,
                           bounds: bounds, format: .RGBAf, colorSpace: colorSpace)
        }
        var sum = 0.0
        for index in 0..<(width * height) {
            let value = pixels[index * 4]
            if value.isFinite { sum += Double(min(1, max(0, value))) }
        }
        return sum / Double(width * height)
    }

    /// Union of the per-face skin mattes, or `nil` when no face produced a matte
    /// or the union coverage is not usable (`isUsableSkinCoverage`).
    ///
    /// `CIMaximumCompositing` also takes the maximum of the alpha channels, so the
    /// union is made opaque again before it is used as an RGB coverage matte.
    /// Internal (not private) so tests can exercise the zero-coverage decision
    /// without a real face.
    func usableSkinMask(_ faceMasks: [FaceSemanticMaskSet], extent: CGRect) -> CIImage? {
        let skins = faceMasks.compactMap(\.skin)
        guard var union = skins.first?.cropped(to: extent) else { return nil }
        for mask in skins.dropFirst() {
            union = mask.applyingFilter("CIMaximumCompositing",
                                        parameters: [kCIInputBackgroundImageKey: union])
                .cropped(to: extent)
        }
        if skins.count > 1, let filter = CIFilter(name: "CIColorMatrix") {
            filter.setValue(union, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputAVector")
            filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputBiasVector")
            union = (filter.outputImage ?? union).cropped(to: extent)
        }
        guard Self.isUsableSkinCoverage(Self.skinMaskCoverage(of: union, context: context)) else {
            return nil
        }
        return union
    }

    /// Lowest recipe version that can encode `adjustments`/`automatic` without a
    /// silent downgrade. Version 13 is required when the v13-only make-up field
    /// can take effect anywhere; version 12 when a v12-only field
    /// (`certificatePhoto`, `repairBrush`) can take effect anywhere; version 11 when a v11-only
    /// field (color tools, lens effects or liquify) can; version 10 when
    /// a v10-only field (portrait refinement or reference color) can. A
    /// reference-color profile is stored as v10 data even at zero strength, so a
    /// present (non-nil) setting also requires v10. Neutral optional groups stay
    /// on the legacy version so old recipes keep their exact payload.
    public static func requiredRecipeVersion(adjustments: AdjustmentSettings,
                                             automatic: AutomaticBatchRecipe?) -> Int {
        let colorTools = [adjustments.colorTools,
                          automatic?.baseline.colorTools,
                          automatic?.referenceSettings.colorTools]
        let lensEffects = [adjustments.lensEffects,
                           automatic?.baseline.lensEffects,
                           automatic?.referenceSettings.lensEffects]
        let petGroups = [adjustments.petEnhancement,
                         automatic?.baseline.petEnhancement,
                         automatic?.referenceSettings.petEnhancement]
        if petGroups.contains(where: { $0.map { !$0.isNeutral } ?? false }) { return 18 }
        let facialZonalGroups = [adjustments.facialZonal,
                                 automatic?.baseline.facialZonal,
                                 automatic?.referenceSettings.facialZonal]
        if facialZonalGroups.contains(where: { $0.map { !$0.isNeutral } ?? false }) { return 17 }
        let bodySkinGroups = [adjustments.bodySkin,
                              automatic?.baseline.bodySkin,
                              automatic?.referenceSettings.bodySkin]
        if bodySkinGroups.contains(where: { $0.map { !$0.isNeutral } ?? false }) { return 16 }
        let clothingGroups = [adjustments.clothing,
                              automatic?.baseline.clothing,
                              automatic?.referenceSettings.clothing]
        if clothingGroups.contains(where: { $0.map { !$0.isNeutral } ?? false }) { return 15 }
        let backdropGroups = [adjustments.backdrop,
                              automatic?.baseline.backdrop,
                              automatic?.referenceSettings.backdrop]
        if backdropGroups.contains(where: { $0.map { !$0.isNeutral } ?? false }) { return 14 }
        let makeupGroups = [adjustments.makeup,
                            automatic?.baseline.makeup,
                            automatic?.referenceSettings.makeup]
        if makeupGroups.contains(where: { $0.map { $0.requiresVersion14 } ?? false }) { return 14 }
        if makeupGroups.contains(where: { $0.map { !$0.isNeutral } ?? false }) { return 13 }
        let certificateGroups = [adjustments.certificatePhoto,
                                 automatic?.baseline.certificatePhoto,
                                 automatic?.referenceSettings.certificatePhoto]
        if certificateGroups.contains(where: { $0.map { !$0.isNeutral } ?? false }) { return 12 }
        let repairGroups = [adjustments.repairBrush,
                            automatic?.baseline.repairBrush,
                            automatic?.referenceSettings.repairBrush]
        if repairGroups.contains(where: { $0.map { !$0.isNeutral } ?? false }) { return 12 }
        let liquifyGroups = [adjustments.liquify,
                             automatic?.baseline.liquify,
                             automatic?.referenceSettings.liquify]
        let needsVersion11 = colorTools.contains { $0.map { !$0.isNeutral } ?? false }
            || lensEffects.contains { $0.map { !$0.isNeutral } ?? false }
            || liquifyGroups.contains { $0.map { !$0.isNeutral } ?? false }
        if needsVersion11 { return 11 }
        let portraits = [adjustments.portrait,
                         automatic?.baseline.portrait,
                         automatic?.referenceSettings.portrait]
        let references = [adjustments.referenceColor,
                          automatic?.baseline.referenceColor,
                          automatic?.referenceSettings.referenceColor]
        let needsVersion10 = portraits.contains { $0.map { !$0.isNeutral } ?? false }
            || references.contains { $0 != nil }
        return needsVersion10 ? 10 : 9
    }

    /// Merges a freshly measured reference profile into the current settings so a
    /// strength / skin-only edit made while the measurement was running is kept.
    public static func mergedReferenceColorSettings(measured profile: ReferenceColorProfile,
                                                    current: ReferenceColorSettings?) -> ReferenceColorSettings {
        ReferenceColorSettings(profile: profile,
                               strength: current?.strength ?? 0.65,
                               skinOnly: current?.skinOnly ?? false)
    }

    private static func validatePoint(_ point: MaskPoint, named name: String) throws {
        try require(point.x, within: 0...1, named: "\(name) X")
        try require(point.y, within: 0...1, named: "\(name) Y")
    }

    /// Cheap 48px peak-difference probe used to tell "stage executed" from
    /// "stage produced identical pixels" (heuristic masks can miss every region).
    private func renderedDifference(_ first: CIImage, _ second: CIImage) -> Float {
        let firstExtent = first.extent
        let secondExtent = second.extent
        guard abs(firstExtent.width - secondExtent.width) < 0.5,
              abs(firstExtent.height - secondExtent.height) < 0.5 else { return 1 }
        let longest = max(firstExtent.width, firstExtent.height)
        guard longest.isFinite, longest > 0 else { return 0 }
        let scale = min(1, 48 / longest)
        let width = max(1, Int((firstExtent.width * scale).rounded()))
        let height = max(1, Int((firstExtent.height * scale).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func sample(_ image: CIImage) -> [Float] {
            let prepared = image
                .transformed(by: CGAffineTransform(translationX: -firstExtent.minX,
                                                   y: -firstExtent.minY))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / firstExtent.width,
                                                   y: CGFloat(height) / firstExtent.height))
                .cropped(to: bounds)
            var pixels = [Float](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { buffer in
                guard let address = buffer.baseAddress else { return }
                context.render(prepared, toBitmap: address,
                               rowBytes: width * 4 * MemoryLayout<Float>.stride,
                               bounds: bounds, format: .RGBAf, colorSpace: space)
            }
            return pixels
        }
        let firstPixels = sample(first)
        let secondPixels = sample(second)
        var maximum: Float = 0
        for index in firstPixels.indices {
            maximum = max(maximum, abs(firstPixels[index] - secondPixels[index]))
        }
        return maximum
    }

    private func validExtent(of image: CIImage) throws -> CGRect {
        let extent = image.extent
        guard !extent.isNull, !extent.isInfinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else {
            throw AtelierError.invalidConfiguration("照片必须有有限且非空的图像范围。")
        }
        return extent
    }

    private struct ImageStatistics {
        let medianLuminance: Double
        let neutralBalanceGains: SIMD3<Double>?

        var conservativeExposureEV: Double {
            guard medianLuminance >= 0.025, medianLuminance <= 0.82 else { return 0 }
            let wanted = log2(0.18 / medianLuminance)
            return min(max(wanted, -0.35), 0.35)
        }
    }

    private func analyze(_ image: CIImage, extent: CGRect) throws -> ImageStatistics? {
        let dimension = Self.analysisDimension
        let width = CGFloat(dimension)
        let height = CGFloat(dimension)
        let translated = image.transformed(by: CGAffineTransform(translationX: -extent.minX,
                                                                  y: -extent.minY))
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: width / extent.width,
                                                                   y: height / extent.height))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let thumbnail = scaled.cropped(to: bounds)
        var pixels = [Float](repeating: 0, count: dimension * dimension * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            context.render(thumbnail, toBitmap: baseAddress,
                           rowBytes: dimension * 4 * MemoryLayout<Float>.size,
                           bounds: bounds, format: .RGBAf, colorSpace: workingColorSpace)
        }

        var luminances: [Double] = []
        luminances.reserveCapacity(dimension * dimension)
        var neutralR = 0.0
        var neutralG = 0.0
        var neutralB = 0.0
        var neutralCount = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3])
            guard alpha > 0.001 else { continue }
            let r = Double(pixels[offset])
            let g = Double(pixels[offset + 1])
            let b = Double(pixels[offset + 2])
            guard r.isFinite, g.isFinite, b.isFinite else { continue }
            let luminance = max(0, 0.2126 * r + 0.7152 * g + 0.0722 * b)
            luminances.append(luminance)

            let high = max(r, max(g, b))
            let low = min(r, min(g, b))
            if luminance >= 0.04, luminance <= 0.85,
               high > 0.0001, high - low <= max(0.025, high * 0.075) {
                neutralR += r
                neutralG += g
                neutralB += b
                neutralCount += 1
            }
        }
        guard !luminances.isEmpty else { return nil }
        luminances.sort()
        let median = luminances[luminances.count / 2]

        var gains: SIMD3<Double>?
        if neutralCount >= 8 {
            let r = neutralR / Double(neutralCount)
            let g = neutralG / Double(neutralCount)
            let b = neutralB / Double(neutralCount)
            let gray = (r + g + b) / 3
            if min(r, min(g, b)) > 0.0001 {
                gains = SIMD3(min(max(gray / r, 0.9), 1.1),
                             min(max(gray / g, 0.9), 1.1),
                             min(max(gray / b, 0.9), 1.1))
            }
        }
        return ImageStatistics(medianLuminance: median, neutralBalanceGains: gains)
    }

    private func applyWhiteBalanceGains(_ gains: SIMD3<Double>, to image: CIImage) throws -> CIImage {
        let filter = try makeFilter("CIColorMatrix")
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: gains.x, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: gains.y, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: gains.z, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        guard let output = filter.outputImage else {
            throw AtelierError.invalidConfiguration("自动白平衡矩阵无法生成输出。")
        }
        return output
    }

    private func applyTemperature(_ normalizedTemperature: Double, tint: Double,
                                  to image: CIImage) throws -> CIImage {
        let filter = try makeFilter("CITemperatureAndTint")
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
        // Lower destination white point warms the image; the UI's positive
        // normalized temperature must therefore lower, not raise, kelvin.
        let targetTemperature = min(max(6500 - normalizedTemperature * 1800, 2000), 50000)
        filter.setValue(CIVector(x: targetTemperature, y: tint * 60), forKey: "inputTargetNeutral")
        guard let output = filter.outputImage else {
            throw AtelierError.invalidConfiguration("色温/色调滤镜无法生成输出。")
        }
        return output
    }

    private func applyLUT(_ lut: LUTCube, to image: CIImage,
                          colorSpace: LUTColorSpace,
                          preciseSampling: Bool) throws -> (graded: CIImage, coverage: CIImage) {
        guard let encodeKernel = Self.lutEncodeKernel,
              let decodeKernel = Self.lutDecodeKernel,
              let coverageKernel = Self.lutCoverageKernel else {
            throw AtelierError.invalidConfiguration("Core Image LUT 编码/解码 kernel 编译失败。")
        }
        let mode: Float
        switch colorSpace {
        case .sRGB: mode = 0
        case .rec709: mode = 1
        case .linearSRGB: mode = 2
        case .displayP3: mode = 3
        case .rec709OETF: mode = 4
        }
        let domainMin = CIVector(x: CGFloat(lut.domainMin.x), y: CGFloat(lut.domainMin.y),
                                 z: CGFloat(lut.domainMin.z))
        let domainRange = CIVector(x: CGFloat(lut.domainMax.x - lut.domainMin.x),
                                   y: CGFloat(lut.domainMax.y - lut.domainMin.y),
                                   z: CGFloat(lut.domainMax.z - lut.domainMin.z))
        guard let encoded = encodeKernel.apply(extent: image.extent, arguments: [
            image, domainMin, domainRange, NSNumber(value: mode)
        ]) else {
            throw AtelierError.invalidConfiguration("LUT 输入编码或 DOMAIN 映射失败。")
        }
        guard let coverage = coverageKernel.apply(extent: image.extent, arguments: [
            image, domainMin, domainRange, NSNumber(value: mode)
        ]) else {
            throw AtelierError.invalidConfiguration("LUT DOMAIN 覆盖范围计算失败。")
        }

        var cubeComponents = lut.rgba
        guard cubeComponents.count == lut.size * lut.size * lut.size * 4 else {
            throw AtelierError.invalidLUT("LUT RGBA 数据长度不正确。")
        }
        for offset in stride(from: 3, to: cubeComponents.count, by: 4) {
            cubeComponents[offset] = 1
        }
        let cubeOutput: CIImage
        if preciseSampling {
            let columns = Int(ceil(sqrt(Double(lut.size))))
            let rows = (lut.size + columns - 1) / columns
            let width = columns * lut.size, height = rows * lut.size
            // Keep the longest side <=1536 even for 128³, and preserve every
            // source node. A single N²-wide strip exceeds older GPU limits.
            var atlas = [Float](repeating: 0, count: width * height * 4)
            for blue in 0..<lut.size {
                for green in 0..<lut.size {
                    let source = (blue * lut.size * lut.size + green * lut.size) * 4
                    let targetX = (blue % columns) * lut.size
                    let targetY = (blue / columns) * lut.size + green
                    let target = (targetY * width + targetX) * 4
                    atlas.replaceSubrange(target..<(target + lut.size * 4),
                                          with: cubeComponents[source..<(source + lut.size * 4)])
                }
            }
            let cubeData = atlas.withUnsafeBufferPointer { Data(buffer: $0) }
            let table = CIImage(bitmapData: cubeData,
                                bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                                size: CGSize(width: width, height: height),
                                format: .RGBAf, colorSpace: nil)
            let tableSampler = CISampler(image: table, options: [
                kCISamplerFilterMode: kCISamplerFilterNearest,
                kCISamplerWrapMode: kCISamplerWrapClamp
            ])
            guard let sampler = Self.lutSampleKernel,
                  let sampled = sampler.apply(extent: image.extent, roiCallback: { index, rect in
                      index == 1 ? table.extent : rect
                  }, arguments: [CISampler(image: encoded), tableSampler, NSNumber(value: lut.size),
                                   NSNumber(value: columns), NSNumber(value: rows)]) else {
                throw AtelierError.invalidLUT("Core Image 三线性 LUT 查表失败。")
            }
            cubeOutput = sampled
        } else {
            // Recipes without the v3 settings keep the existing backend.
            let cubeData = cubeComponents.withUnsafeBufferPointer { Data(buffer: $0) }
            let filter = try makeFilter("CIColorCube")
            filter.setValue(encoded, forKey: kCIInputImageKey)
            filter.setValue(lut.size, forKey: "inputCubeDimension")
            filter.setValue(cubeData, forKey: "inputCubeData")
            if filter.inputKeys.contains("inputExtrapolate") {
                filter.setValue(false, forKey: "inputExtrapolate")
            }
            guard let output = filter.outputImage else {
                throw AtelierError.invalidLUT("Core Image 无法接受此 LUT 尺寸或数据。")
            }
            cubeOutput = output
        }
        guard let decoded = decodeKernel.apply(extent: image.extent, arguments: [
            cubeOutput, NSNumber(value: mode)
        ]) else {
            throw AtelierError.invalidConfiguration("LUT 输出反解码失败。")
        }
        return (decoded, coverage)
    }

    private func fractionOutsideLUTDomain(_ coverage: CIImage, extent: CGRect) throws -> Double {
        let dimension = 32
        let bounds = CGRect(x: 0, y: 0, width: dimension, height: dimension)
        let translated = coverage.transformed(by: CGAffineTransform(translationX: -extent.minX,
                                                                     y: -extent.minY))
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: CGFloat(dimension) / extent.width,
                                                                   y: CGFloat(dimension) / extent.height))
        let thumbnail = scaled.cropped(to: bounds)
        var pixels = [Float](repeating: 0, count: dimension * dimension * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            context.render(thumbnail, toBitmap: baseAddress,
                           rowBytes: dimension * 4 * MemoryLayout<Float>.size,
                           bounds: bounds, format: .RGBAf, colorSpace: workingColorSpace)
        }
        let outsideCount = stride(from: 0, to: pixels.count, by: 4)
            .filter { pixels[$0] < 0.999 }.count
        return Double(outsideCount) / Double(dimension * dimension)
    }

    private func validate(_ lut: LUTCube) throws {
        let ranges = [lut.domainMax.x - lut.domainMin.x,
                      lut.domainMax.y - lut.domainMin.y,
                      lut.domainMax.z - lut.domainMin.z]
        let domainValues = [lut.domainMin.x, lut.domainMin.y, lut.domainMin.z,
                            lut.domainMax.x, lut.domainMax.y, lut.domainMax.z]
        guard (2...128).contains(lut.size),
              lut.rgba.count == lut.size * lut.size * lut.size * 4,
              domainValues.allSatisfy({ $0.isFinite && (-16...16).contains($0) }),
              ranges.allSatisfy({ $0.isFinite && $0 >= 0.000001 }),
              lut.rgba.allSatisfy({ $0.isFinite && (-16...16).contains($0) }) else {
            throw AtelierError.invalidLUT("LUT 尺寸、DOMAIN 或数据分量无效。")
        }
    }

    // MARK: - Pipeline stages

    /// Basic tone block: exposure/white balance/temperature/local tone/harmony/
    /// tonal curve. Runs before geometry in the accepted implementation order
    /// (legacy P0 position preserved for v1–v10 pixel compatibility).
    private func applyBasicTone(_ image: CIImage,
                                settings: AdjustmentSettings,
                                stats: ImageStatistics?,
                                report: inout ProcessingReport,
                                cancellation: CancellationToken?) throws -> CIImage {
        var working = image
        let automaticEV = settings.autoExposure ? (stats?.conservativeExposureEV ?? 0) : 0
        let totalEV = automaticEV + settings.exposureEV
        if abs(totalEV) > 0.0001 {
            working = try apply("CIExposureAdjust", to: working,
                                parameters: ["inputEV": NSNumber(value: totalEV)])
        }
        report.appliedExposureEV = totalEV

        if settings.autoWhiteBalance {
            if let gains = stats?.neutralBalanceGains {
                working = try applyWhiteBalanceGains(gains, to: working)
            } else {
                report.warnings.append("自动白平衡未找到足够可靠的中性像素，本图跳过自动白平衡。")
            }
        }
        if abs(settings.temperature) > 0.0001 || abs(settings.tint) > 0.0001 {
            working = try applyTemperature(settings.temperature, tint: settings.tint, to: working)
        }
        try cancellation?.check()

        if settings.saturation != 1 || settings.contrast != 1 ||
            settings.highlights != 0 || settings.shadows != 0 {
            let toneInput = working
            guard let kernel = Self.localToneKernel else {
                throw AtelierError.invalidConfiguration("Core Image 色调 kernel 编译失败。")
            }
            guard let adjusted = kernel.apply(extent: working.extent, arguments: [
                working,
                NSNumber(value: settings.saturation),
                NSNumber(value: settings.contrast),
                NSNumber(value: settings.highlights),
                NSNumber(value: settings.shadows)
            ]) else {
                throw AtelierError.invalidConfiguration("Core Image 色调 kernel 无法生成输出。")
            }
            working = adjusted
            if settings.saturation > 1, let harmony = settings.colorHarmony, harmony.enabled {
                guard let lightOnly = kernel.apply(extent: toneInput.extent, arguments: [
                    toneInput, NSNumber(value: 1), NSNumber(value: settings.contrast),
                    NSNumber(value: settings.highlights), NSNumber(value: settings.shadows)
                ]) else { throw AtelierError.invalidConfiguration("无法建立光线调整后的色彩参考。") }
                working = try ColorHarmonyEngine.protect(reference: lightOnly, candidate: working,
                                                        settings: harmony, scene: nil, context: context)
            }
        }

        if let tonal = settings.tonalCurve {
            working = try TonalCurveEngine.apply(working, settings: tonal)
        }
        return working
    }

    /// Global geometry block: auto straightening, explicit rotation, perspective.
    /// Runs after the basic tone block (legacy order) and before liquify.
    private func applyGeometry(_ image: CIImage,
                               settings: AdjustmentSettings,
                               report: inout ProcessingReport,
                               cancellation: CancellationToken?) throws -> CIImage {
        var working = image
        if settings.autoStraighten {
            working = try autoStraighten(working, report: &report, cancellation: cancellation)
        }
        if abs(settings.rotationDegrees) > 0.0001 {
            working = try rotate(working, degrees: settings.rotationDegrees)
            report.straighteningDegrees += settings.rotationDegrees
        }
        if settings.verticalPerspective != 0 || settings.horizontalPerspective != 0 {
            working = try applyPerspective(working,
                                           vertical: settings.verticalPerspective,
                                           horizontal: settings.horizontalPerspective)
        }
        return working
    }

    /// Liquify / face reshaping. Runs after tone and geometry, before the v11
    /// color tools, portrait refinement and local masks. Auto face-shape controls
    /// need Vision landmarks; manual strokes work without a face. Skips are
    /// recorded in the report and warnings, never silent.
    private func applyLiquify(_ image: CIImage,
                              settings: AdjustmentSettings,
                              report: inout ProcessingReport,
                              cancellation: CancellationToken?) throws -> CIImage {
        guard let liquify = settings.liquify, !liquify.isNeutral else { return image }
        var working = image
        let wantsFaceShape = !liquify.effectiveParameters.isNeutral
        var landmarks: FaceLandmarkSet?
        if wantsFaceShape {
            landmarks = FaceSemanticAnalyzer.detect(in: working, maxFaces: 1).first
        }
        if wantsFaceShape, landmarks == nil {
            let note = "未检测到可用人脸或本机 Vision 不可用，液化/美型（脸型与滑杆）已跳过；手动液化笔迹仍会应用。"
            var settingsWithoutFace = liquify
            settingsWithoutFace.parameters = FaceReshapeParameters()
            settingsWithoutFace.preset = .classic
            if !settingsWithoutFace.strokes.isEmpty {
                working = try FaceReshapeEngine.apply(to: working, landmarks: nil,
                                                      settings: settingsWithoutFace)
                report.liquify = LiquifyIntegrationReport(applied: true, faceCount: 0,
                    presetApplied: false, strokeCount: settingsWithoutFace.strokes.count, note: note)
            } else {
                report.liquify = LiquifyIntegrationReport(applied: false, faceCount: 0,
                    presetApplied: false, strokeCount: 0, note: note)
            }
            report.warnings.append(note)
        } else {
            working = try FaceReshapeEngine.apply(to: working, landmarks: landmarks,
                                                  settings: liquify)
            report.liquify = LiquifyIntegrationReport(
                applied: true, faceCount: landmarks == nil ? 0 : 1,
                presetApplied: wantsFaceShape && landmarks != nil,
                strokeCount: liquify.strokes.count,
                note: nil)
        }
        try cancellation?.check()
        return working
    }

    // MARK: - Certificate photo / background replacement (P1-B)

    /// Replaces the background and optionally crops to a certificate-photo size.
    ///
    /// Detection failures (no person / no face for the requested crop) are explicit
    /// skips recorded in the report and warnings; configuration errors such as a
    /// missing local background image throw instead of silently ignoring the
    /// setting. Prepared matte/face box are test/advanced-caller seams and skip the
    /// corresponding Vision pass.
    private func applyCertificatePhoto(_ image: CIImage,
                                       settings: CertificatePhotoSettings,
                                       preparedMatte: PersonMatte?,
                                       preparedFaceBox: CGRect?,
                                       report: inout ProcessingReport,
                                       cancellation: CancellationToken?) throws -> CIImage {
        try cancellation?.check()
        let extent = try validExtent(of: image)
        func skip(_ note: String) -> CIImage {
            report.certificatePhoto = CertificatePhotoReport(applied: false,
                                                             background: "",
                                                             coverage: 0,
                                                             outputPixelSize: extent.size,
                                                             note: note)
            report.warnings.append(note)
            return image
        }

        let matte: PersonMatte
        if let preparedMatte {
            matte = preparedMatte
        } else {
            do {
                matte = try PersonMatting.detect(in: image)
            } catch {
                return skip("未检测到可用人物（\(error.localizedDescription)）；证件照/换背景已跳过，原图保持不变。")
            }
        }
        guard matte.hasPerson else {
            return skip("未检测到可用人物（蒙版覆盖率 \(String(format: "%.2f%%", matte.coverage * 100))）；证件照/换背景已跳过，原图保持不变。")
        }

        var faceBox = preparedFaceBox
        if settings.size != nil, faceBox == nil {
            faceBox = FaceSemanticAnalyzer.detect(in: image, maxFaces: 1).first?.boundingBox
            guard faceBox != nil else {
                return skip("检测到人物但未检测到可用人脸，无法按证件照尺寸裁剪；证件照/换背景已跳过，原图保持不变。")
            }
        }

        let fill: BackgroundFill
        switch settings.backgroundSource {
        case .preset:
            fill = .preset(settings.backgroundPreset)
        case .customColor:
            fill = .color(settings.customBackground)
        case .image:
            guard let path = settings.backgroundImagePath,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AtelierError.invalidConfiguration("证件照背景图片来源为本地图片，但背景图片路径为空。")
            }
            fill = .image(try BackgroundReplacement.backgroundImage(
                contentsOf: URL(fileURLWithPath: path)))
        }

        var output = try BackgroundReplacement.apply(foreground: image, matte: matte,
                                                     fill: fill, settings: settings.shadow)
        var note: String?
        if let size = settings.size, let faceBox {
            var crop = settings.crop
            crop.size = size
            output = try IDPhotoLayout.render(photo: output, faceBox: faceBox, settings: crop)
            note = "证件照裁剪已改变画布尺寸为 \(Int(output.extent.width))×\(Int(output.extent.height))；局部蒙版/细节现按新 extent 归一化，请复核依赖位置的调整。"
        }
        let backgroundDescription: String
        switch settings.backgroundSource {
        case .preset:
            backgroundDescription = "预设·\(settings.backgroundPreset.title)"
        case .customColor:
            backgroundDescription = "自定义·\(settings.customBackground.hexString)"
        case .image:
            backgroundDescription = "本地图片·\((settings.backgroundImagePath as NSString?)?.lastPathComponent ?? "")"
        }
        report.certificatePhoto = CertificatePhotoReport(applied: true,
                                                         background: backgroundDescription,
                                                         coverage: matte.coverage,
                                                         outputPixelSize: output.extent.size,
                                                         note: note)
        if let note { report.warnings.append(note) }
        try cancellation?.check()
        return output
    }

    private func autoStraighten(_ image: CIImage, report: inout ProcessingReport,
                                cancellation: CancellationToken?) throws -> CIImage {
        try cancellation?.check()
        var detectedAngle: Double?
        do {
            let request = VNDetectHorizonRequest()
            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            try handler.perform([request])
            try cancellation?.check()
            if let observation = request.results?.first,
               observation.confidence >= 0.6, observation.angle.isFinite,
               abs(observation.angle) <= .pi / 12 {
                detectedAngle = observation.angle
            }
        } catch let error as AtelierError {
            throw error
        } catch {
            report.warnings.append("地平线识别不可用，尝试可靠直线估计。")
        }
        if detectedAngle == nil {
            detectedAngle = HorizonEstimator.angle(in: image, context: context)
            if detectedAngle != nil { report.warnings.append("自动水平采用显著直线估计，请复核构图。") }
        }
        guard let angle = detectedAngle else {
            report.warnings.append("未找到可靠地平线或显著水平线，自动水平已跳过。")
            return image
        }
        try cancellation?.check()
        report.straighteningDegrees += angle * 180 / .pi
        return try straighten(image, radians: angle)
    }

    private func rotate(_ image: CIImage, degrees: Double) throws -> CIImage {
        try straighten(image, radians: degrees * .pi / 180)
    }

    private func straighten(_ image: CIImage, radians: Double) throws -> CIImage {
        let filter = try makeFilter("CIStraightenFilter")
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(NSNumber(value: radians), forKey: "inputAngle")
        guard let output = filter.outputImage else {
            throw AtelierError.invalidConfiguration("水平旋转无法生成裁切后的输出。")
        }
        return output
    }

    private func applyPerspective(_ image: CIImage, vertical: Double,
                                  horizontal: Double) throws -> CIImage {
        let extent = try validExtent(of: image)
        let verticalShift = CGFloat(vertical) * extent.width * 0.22
        let horizontalShift = CGFloat(horizontal) * extent.height * 0.22
        let topLeft = CIVector(x: extent.minX + verticalShift,
                               y: extent.maxY + horizontalShift)
        let topRight = CIVector(x: extent.maxX - verticalShift,
                                y: extent.maxY - horizontalShift)
        let bottomLeft = CIVector(x: extent.minX - verticalShift,
                                  y: extent.minY - horizontalShift)
        let bottomRight = CIVector(x: extent.maxX + verticalShift,
                                   y: extent.minY + horizontalShift)
        let filter = try makeFilter("CIPerspectiveTransformWithExtent")
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: "inputExtent")
        filter.setValue(topLeft, forKey: "inputTopLeft")
        filter.setValue(topRight, forKey: "inputTopRight")
        filter.setValue(bottomLeft, forKey: "inputBottomLeft")
        filter.setValue(bottomRight, forKey: "inputBottomRight")
        guard let output = filter.outputImage else {
            throw AtelierError.invalidConfiguration("透视变换无法生成输出。")
        }
        let cropInsetX = max(0, max(topLeft.x - extent.minX,
                                   max(extent.maxX - topRight.x,
                                       max(bottomLeft.x - extent.minX, extent.maxX - bottomRight.x))))
        let cropInsetY = max(0, max(extent.maxY - topLeft.y,
                                   max(extent.maxY - topRight.y,
                                       max(bottomLeft.y - extent.minY, bottomRight.y - extent.minY))))
        let candidate = extent.insetBy(dx: cropInsetX + 2, dy: cropInsetY + 2)
        let safeRect = CGRect(x: ceil(candidate.minX), y: ceil(candidate.minY),
                              width: floor(candidate.maxX) - ceil(candidate.minX),
                              height: floor(candidate.maxY) - ceil(candidate.minY))
        guard safeRect.width > 1, safeRect.height > 1 else {
            throw AtelierError.invalidConfiguration("透视强度过大，无法保留有效的不透明裁切区域。")
        }
        // Clamp the already-valid interior before resampling so interpolation
        // cannot mix the crop boundary with transparent pixels.
        let cropped = output.cropped(to: safeRect).clampedToExtent()
        let shifted = cropped.transformed(by: CGAffineTransform(translationX: -safeRect.minX,
                                                                y: -safeRect.minY))
        let scaled = shifted.transformed(by: CGAffineTransform(scaleX: extent.width / safeRect.width,
                                                                y: extent.height / safeRect.height))
        return scaled.transformed(by: CGAffineTransform(translationX: extent.minX,
                                                        y: extent.minY)).cropped(to: extent)
    }

    private func apply(_ mask: LocalMask, to image: CIImage) throws -> CIImage {
        let extent = try validExtent(of: image)
        let maskImage = try renderMask(mask, extent: extent)
        var adjusted = image
        if abs(mask.exposureEV) > 0.0001 {
            adjusted = try apply("CIExposureAdjust", to: adjusted,
                                 parameters: ["inputEV": NSNumber(value: mask.exposureEV)])
        }
        if abs(mask.warmth) > 0.0001 {
            adjusted = try applyTemperature(mask.warmth, tint: 0, to: adjusted)
        }
        if abs(mask.saturation - 1) > 0.0001 {
            adjusted = try apply("CIColorControls", to: adjusted,
                                 parameters: ["inputSaturation": NSNumber(value: mask.saturation),
                                              "inputContrast": 1.0,
                                              "inputBrightness": 0.0])
        }
        let filter = try makeFilter("CIBlendWithMask")
        filter.setValue(adjusted, forKey: kCIInputImageKey)
        filter.setValue(image, forKey: "inputBackgroundImage")
        filter.setValue(maskImage, forKey: "inputMaskImage")
        guard let output = filter.outputImage else {
            throw AtelierError.invalidConfiguration("蒙版合成无法生成输出。")
        }
        return output.cropped(to: extent)
    }

    private func renderMask(_ mask: LocalMask, extent: CGRect) throws -> CIImage {
        let scale = min(1, CGFloat(Self.maximumMaskRasterDimension) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        guard let graySpace = CGColorSpaceCreateDeviceGray() as CGColorSpace? else {
            throw AtelierError.invalidConfiguration("无法创建蒙版灰度色彩空间。")
        }
        guard let bitmap = CGContext(data: nil, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: graySpace,
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw AtelierError.invalidConfiguration("无法分配蒙版位图。")
        }
        bitmap.setFillColor(gray: 0, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.setStrokeColor(gray: 1, alpha: 1)
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.setShouldAntialias(true)

        let minDimension = CGFloat(min(width, height))
        let radius = CGFloat(mask.radius) * minDimension
        switch mask.kind {
        case .radial:
            let center = pixelPoint(mask.start, width: width, height: height)
            let radiusX = max(abs(mask.end.x - mask.start.x) * Double(width), 0.5)
            let radiusY = max(abs(mask.end.y - mask.start.y) * Double(height), 0.5)
            bitmap.saveGState()
            bitmap.translateBy(x: center.x, y: center.y)
            bitmap.scaleBy(x: radiusX, y: radiusY)
            if mask.feather <= 0.0001 {
                bitmap.fillEllipse(in: CGRect(x: -1, y: -1, width: 2, height: 2))
            } else {
                let white = CGColor(gray: 1, alpha: 1)
                let black = CGColor(gray: 0, alpha: 1)
                let transitionStart = CGFloat(1 - mask.feather)
                guard let gradient = CGGradient(colorsSpace: graySpace,
                                                colors: [white, white, black] as CFArray,
                                                locations: [0, transitionStart, 1]) else {
                    bitmap.restoreGState()
                    throw AtelierError.invalidConfiguration("径向蒙版渐变创建失败。")
                }
                bitmap.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                          endCenter: .zero, endRadius: 1,
                                          options: [])
            }
            bitmap.restoreGState()

        case .linear:
            let start = pixelPoint(mask.start, width: width, height: height)
            let end = pixelPoint(mask.end, width: width, height: height)
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = max(hypot(dx, dy), 1)
            let direction = CGPoint(x: dx / length, y: dy / length)
            let transitionLength = max(length * CGFloat(mask.feather), 1 / max(scale, 0.0001))
            let center = CGPoint(x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5)
            let point0 = CGPoint(x: center.x - direction.x * transitionLength * 0.5,
                                 y: center.y - direction.y * transitionLength * 0.5)
            let point1 = CGPoint(x: center.x + direction.x * transitionLength * 0.5,
                                 y: center.y + direction.y * transitionLength * 0.5)
            guard let gradient = CGGradient(colorsSpace: graySpace,
                                            colors: [CGColor(gray: 1, alpha: 1),
                                                     CGColor(gray: 0, alpha: 1)] as CFArray,
                                            locations: [0, 1]) else {
                throw AtelierError.invalidConfiguration("线性蒙版渐变创建失败。")
            }
            bitmap.drawLinearGradient(gradient, start: point0, end: point1,
                                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        case .brush:
            let points = mask.points.map { pixelPoint($0, width: width, height: height) }
            bitmap.setLineWidth(max(radius * 2, 1))
            bitmap.setLineCap(.round)
            bitmap.setLineJoin(.round)
            if points.count == 1, let point = points.first {
                bitmap.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                              width: radius * 2, height: radius * 2))
            } else if let first = points.first {
                let path = CGMutablePath()
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                bitmap.addPath(path)
                bitmap.strokePath()
            }

        case .luminance, .color:
            bitmap.setFillColor(gray: 1, alpha: 1)
            bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        guard let cgImage = bitmap.makeImage() else {
            throw AtelierError.invalidConfiguration("无法生成蒙版图像。")
        }
        var raster = CIImage(cgImage: cgImage, options: [.colorSpace: workingColorSpace])
        if mask.kind == .brush, mask.feather > 0.0001, !mask.points.isEmpty {
            // Soften before scaling the capped raster: the blur radius then remains
            // proportional to the normalized brush size on large source images.
            let blurRadius = max(radius * CGFloat(mask.feather) * 0.5, 0.5)
            raster = try apply("CIGaussianBlur", to: raster.clampedToExtent(),
                               parameters: ["inputRadius": NSNumber(value: Double(blurRadius))])
                .cropped(to: raster.extent)
        }
        let imageScaleX = extent.width / CGFloat(width)
        let imageScaleY = extent.height / CGFloat(height)
        let scaled = raster.transformed(by: CGAffineTransform(scaleX: imageScaleX, y: imageScaleY))
        var output = scaled.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        if mask.inverted {
            output = try apply("CIColorInvert", to: output, parameters: [:]).cropped(to: extent)
        }
        return output
    }

    private func pixelPoint(_ point: MaskPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(x: point.x * Double(width), y: point.y * Double(height))
    }

    private func apply(_ name: String, to image: CIImage,
                       parameters: [String: Any]) throws -> CIImage {
        let filter = try makeFilter(name)
        filter.setValue(image, forKey: kCIInputImageKey)
        for (key, value) in parameters { filter.setValue(value, forKey: key) }
        guard let output = filter.outputImage else {
            throw AtelierError.invalidConfiguration("\(name) 无法生成输出。")
        }
        return output
    }

    private func makeFilter(_ name: String) throws -> CIFilter {
        guard let filter = CIFilter(name: name) else {
            throw AtelierError.invalidConfiguration("当前 macOS 不支持 Core Image 滤镜 \(name)。")
        }
        return filter
    }
}

/// Latest-wins gate for asynchronous preview work.
///
/// The app starts a render for a generation id and only publishes its results if
/// `admits(generation)` is still true when the render finishes. A newer request
/// begins a new generation, so a slow stale render can never overwrite fresher
/// pixels (the in-flight render itself is cancelled through its token).
public struct PreviewRequestGate {
    private var current = UUID()

    public init() {}

    /// Begins a new request generation and returns its id.
    public mutating func begin() -> UUID {
        current = UUID()
        return current
    }

    /// Invalidates every in-flight request (e.g. when the selection changes).
    public mutating func invalidate() {
        current = UUID()
    }

    /// True only for the newest generation; stale results must be dropped.
    public func admits(_ generation: UUID) -> Bool {
        generation == current
    }

    /// Current generation id, for checks that compare against the latest request
    /// without starting a new one.
    public var currentGeneration: UUID { current }
}

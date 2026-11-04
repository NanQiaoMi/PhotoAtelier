import Foundation
import CoreGraphics
import CoreImage

public enum AtelierError: LocalizedError {
    case invalidLUT(String)
    case imageRead(String)
    case imageWrite(String)
    case invalidConfiguration(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidLUT(let text): return "LUT 无效：\(text)"
        case .imageRead(let text): return "无法读取照片：\(text)"
        case .imageWrite(let text): return "无法导出照片：\(text)"
        case .invalidConfiguration(let text): return text
        case .cancelled: return "任务已取消"
        }
    }
}

public enum LUTColorSpace: String, Codable, CaseIterable {
    case sRGB, rec709, linearSRGB, displayP3, rec709OETF
    public var title: String {
        switch self {
        case .sRGB: return "sRGB · 显示参照"
        case .rec709: return "Rec.709 · Gamma 2.4"
        case .linearSRGB: return "Linear sRGB"
        case .displayP3: return "Display P3 · sRGB 曲线"
        case .rec709OETF: return "Rec.709 · 摄像机 OETF"
        }
    }
}

public enum ExportFormat: String, Codable, CaseIterable {
    case jpeg, tiff, png, heic
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    public var title: String {
        switch self {
        case .jpeg: return "JPEG · 高品质"
        case .tiff: return "TIFF · 16 bit"
        case .png: return "PNG · 16 bit"
        case .heic: return "HEIC · 高效有损"
        }
    }
}

public enum OutputColorSpace: String, Codable, CaseIterable {
    case sRGB, displayP3
    public var title: String { self == .sRGB ? "sRGB" : "Display P3" }
}

public enum MaskKind: String, Codable, CaseIterable {
    case radial, linear, brush, luminance, color
    public var title: String {
        switch self {
        case .radial: return "径向"
        case .linear: return "渐变"
        case .brush: return "画笔"
        case .luminance: return "亮度范围"
        case .color: return "颜色范围"
        }
    }
}

public struct MaskPoint: Codable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct LocalMask: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: MaskKind
    /// All mask coordinates use the corrected image extent, normalized, origin at bottom left.
    public var start: MaskPoint
    public var end: MaskPoint
    public var points: [MaskPoint]
    public var radius: Double
    public var feather: Double
    public var inverted: Bool
    public var enabled: Bool
    public var exposureEV: Double
    public var saturation: Double
    public var warmth: Double
    public var components: [MaskComponent]
    public var opacity: Double
    public var tint: Double
    public var contrast: Double
    public var highlights: Double
    public var shadows: Double
    public var sharpness: Double
    public var highlightProtection: Double
    public var colorProtection: Double
    public var stage: MaskStage
    public var restrictLuminance: Bool
    public var luminanceMin: Double
    public var luminanceMax: Double
    public var rangeSoftness: Double
    public var restrictColor: Bool
    public var color: MaskColor
    public var colorTolerance: Double
    public var colorSoftness: Double
    /// A semantic selection is recalculated per image, never stored as face coordinates.
    public var contentSelection: ContentSelectionTarget?
    public var detail: LocalDetailSettings?
    /// When present, remeasure this effective region on every photograph.
    /// Manual detail values remain stored and resume when adaptation is disabled.
    public var detailAdaptation: LocalDetailAdaptation?

    public init(id: UUID = UUID(), name: String = "局部调整", kind: MaskKind = .radial,
                start: MaskPoint = .init(x: 0.5, y: 0.5), end: MaskPoint = .init(x: 0.75, y: 0.75),
                points: [MaskPoint] = [], radius: Double = 0.12, feather: Double = 0.65,
                inverted: Bool = false, enabled: Bool = true, exposureEV: Double = 0.3,
                saturation: Double = 1, warmth: Double = 0,
                components: [MaskComponent] = [], opacity: Double = 1, tint: Double = 0,
                contrast: Double = 1, highlights: Double = 0, shadows: Double = 0,
                sharpness: Double = 0, highlightProtection: Double = 0.5,
                colorProtection: Double = 0.5, stage: MaskStage = .beforeLook,
                restrictLuminance: Bool = false, luminanceMin: Double = 0,
                luminanceMax: Double = 1, rangeSoftness: Double = 0.15,
                restrictColor: Bool = false, color: MaskColor = .init(red: 0.5, green: 0.5, blue: 0.5),
                colorTolerance: Double = 0.2, colorSoftness: Double = 0.15,
                contentSelection: ContentSelectionTarget? = nil, detail: LocalDetailSettings? = nil,
                detailAdaptation: LocalDetailAdaptation? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.start = start; self.end = end
        self.points = points; self.radius = radius; self.feather = feather
        self.inverted = inverted; self.enabled = enabled; self.exposureEV = exposureEV
        self.saturation = saturation; self.warmth = warmth
        self.components = components; self.opacity = opacity; self.tint = tint
        self.contrast = contrast; self.highlights = highlights; self.shadows = shadows
        self.sharpness = sharpness; self.highlightProtection = highlightProtection
        self.colorProtection = colorProtection; self.stage = stage
        self.restrictLuminance = restrictLuminance; self.luminanceMin = luminanceMin
        self.luminanceMax = luminanceMax; self.rangeSoftness = rangeSoftness
        self.restrictColor = restrictColor; self.color = color
        self.colorTolerance = colorTolerance; self.colorSoftness = colorSoftness
        self.contentSelection = contentSelection; self.detail = detail
        self.detailAdaptation = detailAdaptation
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, start, end, points, radius, feather, inverted, enabled
        case exposureEV, saturation, warmth
        case components, opacity, tint, contrast, highlights, shadows, sharpness
        case highlightProtection, colorProtection, stage, restrictLuminance
        case luminanceMin, luminanceMax, rangeSoftness, restrictColor, color
        case colorTolerance, colorSoftness
        case contentSelection, detail, detailAdaptation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "局部调整"
        kind = try container.decodeIfPresent(MaskKind.self, forKey: .kind) ?? .radial
        start = try container.decodeIfPresent(MaskPoint.self, forKey: .start) ?? .init(x: 0.5, y: 0.5)
        end = try container.decodeIfPresent(MaskPoint.self, forKey: .end) ?? .init(x: 0.75, y: 0.75)
        points = try container.decodeIfPresent([MaskPoint].self, forKey: .points) ?? []
        radius = try container.decodeIfPresent(Double.self, forKey: .radius) ?? 0.12
        feather = try container.decodeIfPresent(Double.self, forKey: .feather) ?? 0.65
        inverted = try container.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        exposureEV = try container.decodeIfPresent(Double.self, forKey: .exposureEV) ?? 0.3
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        warmth = try container.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        components = try container.decodeIfPresent([MaskComponent].self, forKey: .components) ?? []
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        sharpness = try container.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        // Old recipe files get no new local protection, preserving their pixels.
        highlightProtection = try container.decodeIfPresent(Double.self, forKey: .highlightProtection) ?? 0
        colorProtection = try container.decodeIfPresent(Double.self, forKey: .colorProtection) ?? 0
        stage = try container.decodeIfPresent(MaskStage.self, forKey: .stage) ?? .afterLook
        restrictLuminance = try container.decodeIfPresent(Bool.self, forKey: .restrictLuminance) ?? false
        luminanceMin = try container.decodeIfPresent(Double.self, forKey: .luminanceMin) ?? 0
        luminanceMax = try container.decodeIfPresent(Double.self, forKey: .luminanceMax) ?? 1
        rangeSoftness = try container.decodeIfPresent(Double.self, forKey: .rangeSoftness) ?? 0.15
        restrictColor = try container.decodeIfPresent(Bool.self, forKey: .restrictColor) ?? false
        color = try container.decodeIfPresent(MaskColor.self, forKey: .color) ?? .init(red: 0.5, green: 0.5, blue: 0.5)
        colorTolerance = try container.decodeIfPresent(Double.self, forKey: .colorTolerance) ?? 0.2
        colorSoftness = try container.decodeIfPresent(Double.self, forKey: .colorSoftness) ?? 0.15
        contentSelection = try container.decodeIfPresent(ContentSelectionTarget.self, forKey: .contentSelection)
        detail = try container.decodeIfPresent(LocalDetailSettings.self, forKey: .detail)
        detailAdaptation = try container.decodeIfPresent(LocalDetailAdaptation.self, forKey: .detailAdaptation)
        try LocalMaskValidator.validate(self)
    }

    public func encode(to encoder: Encoder) throws {
        try LocalMaskValidator.validate(self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(points, forKey: .points)
        try container.encode(radius, forKey: .radius)
        try container.encode(feather, forKey: .feather)
        try container.encode(inverted, forKey: .inverted)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(exposureEV, forKey: .exposureEV)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(warmth, forKey: .warmth)
        try container.encode(components, forKey: .components)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(tint, forKey: .tint)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(shadows, forKey: .shadows)
        try container.encode(sharpness, forKey: .sharpness)
        try container.encode(highlightProtection, forKey: .highlightProtection)
        try container.encode(colorProtection, forKey: .colorProtection)
        try container.encode(stage, forKey: .stage)
        try container.encode(restrictLuminance, forKey: .restrictLuminance)
        try container.encode(luminanceMin, forKey: .luminanceMin)
        try container.encode(luminanceMax, forKey: .luminanceMax)
        try container.encode(rangeSoftness, forKey: .rangeSoftness)
        try container.encode(restrictColor, forKey: .restrictColor)
        try container.encode(color, forKey: .color)
        try container.encode(colorTolerance, forKey: .colorTolerance)
        try container.encode(colorSoftness, forKey: .colorSoftness)
        try container.encodeIfPresent(contentSelection, forKey: .contentSelection)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(detailAdaptation, forKey: .detailAdaptation)
    }
}

public struct AdjustmentSettings: Codable, Equatable {
    /// New photographs preserve the decoded capture until the user chooses a proposal.
    public var autoExposure = false
    public var autoWhiteBalance = false
    public var exposureEV: Double = 0
    public var temperature: Double = 0
    public var tint: Double = 0
    public var contrast: Double = 1
    public var saturation: Double = 1
    public var highlights: Double = 0
    public var shadows: Double = 0
    /// Optional so older recipes keep their original tone response.
    public var tonalCurve: TonalCurveSettings? = .init()
    /// Rendered camera JPEGs may already be corrected; opt in to avoid double correction.
    public var lensCorrection = false
    public var lensProfileID: String? = nil
    /// Zero selects the camera database/EXIF value; positive values override it.
    public var lensCropFactor: Double = 0
    public var lensFocalLength: Double = 0
    public var autoStraighten = false
    public var rotationDegrees: Double = 0
    public var verticalPerspective: Double = 0
    public var horizontalPerspective: Double = 0
    public var lutIntensity: Double = 0.65
    public var lutColorSpace: LUTColorSpace = .sRGB
    public var preserveLuminance: Double = 0.65
    public var protectSkin: Double = 0.65
    public var protectNeutrals: Double = 0.5
    public var gamutCompression: Double = 0.8
    /// Absent in v1/v2 recipes: keeps their original rendering until explicitly enabled.
    public var colorHarmony: ColorHarmonySettings? = .init()
    /// Optional for pixel compatibility with recipes created before v8.
    public var creativeEffects: CreativeEffectsSettings? = nil
    /// Optional for exact compatibility with recipes written before v9.
    public var adaptiveLUT: AdaptiveLUTSettings? = nil
    /// Optional for exact compatibility with recipes written before v10.
    /// Absent or neutral settings keep the pre-v10 render path untouched.
    public var portrait: PortraitRefinementSettings? = nil
    /// Optional for exact compatibility with recipes written before v10.
    /// Absent or neutral reference-color settings keep the pre-v10 render path.
    public var referenceColor: ReferenceColorSettings? = nil
    /// Optional for exact compatibility with recipes written before v11.
    /// Absent or neutral color tools (curves/HSL/grading) keep the pre-v11 path.
    public var colorTools: ColorToolsSettings? = nil
    /// Optional for exact compatibility with recipes written before v11.
    /// Absent or neutral lens effects (vignette/CA) keep the pre-v11 path.
    public var lensEffects: LensEffectsSettings? = nil
    /// Optional for exact compatibility with recipes written before v11.
    /// Absent or neutral liquify settings (face presets/sliders/manual strokes)
    /// keep the pre-v11 path untouched.
    public var liquify: FaceReshapeSettings? = nil
    public var masks: [LocalMask] = []
    public init() {}
}

/// Per-photo record of which P1 color-tool stages actually ran, embedded in
/// `ProcessingReport` so batch manifests can state the applied color pipeline
/// instead of omitting it. `nil` means no active color tool (pre-v11 path).
public struct ColorToolsReport: Codable, Equatable {
    /// Names of the stages that ran, in pipeline order, e.g.
    /// `["curves", "hsl", "grading", "lensEffects"]`.
    public var stages: [String]
    public var vignetteAmount: Double
    public var chromaticAberration: Double
    public var note: String?

    public init(stages: [String], vignetteAmount: Double = 0,
                chromaticAberration: Double = 0, note: String? = nil) {
        self.stages = stages
        self.vignetteAmount = vignetteAmount
        self.chromaticAberration = chromaticAberration
        self.note = note
    }
}

/// User-facing reference-color ("AI 追色") settings stored in a v10 recipe.
///
/// The profile is measured from the reference image once and stored as plain
/// data, so applying the look never requires the reference photo to exist. This
/// is a global OKLab distribution match, not semantic segmentation and not a
/// guarantee of a commercial-grade aesthetic result.
///
/// `strength` is the OKLab blend amount (`0...1`); a strength of 0 is a neutral
/// no-op. `skinOnly` restricts the match to detected facial skin (Vision
/// landmarks plus colour rules). When no usable skin mask exists the pipeline
/// skips the stage explicitly and records why instead of silently applying the
/// match globally.
///
/// Non-neutral settings require recipe version 10 (`Recipe.validateVersion`).
public struct ReferenceColorSettings: Codable, Equatable {
    public var profile: ReferenceColorProfile
    public var strength: Double
    public var skinOnly: Bool

    public init(profile: ReferenceColorProfile, strength: Double = 0.65, skinOnly: Bool = false) {
        self.profile = profile
        self.strength = strength
        self.skinOnly = skinOnly
    }

    /// True when the setting cannot change pixels (zero or negative strength).
    public var isNeutral: Bool { !(strength > 0) }
}

/// Optional export resizing. A `.none` mode is the neutral value that keeps
/// legacy recipes on the unmodified full-size path.
public enum ExportResizeMode: String, Codable, CaseIterable {
    case none, longEdge, percent
    public var title: String {
        switch self {
        case .none: return "原始尺寸"
        case .longEdge: return "按长边像素"
        case .percent: return "按百分比"
        }
    }
}

public struct ExportResizeSettings: Codable, Equatable {
    public var mode: ExportResizeMode = .none
    /// Long edge in pixels; 16...32768 when `mode == .longEdge`.
    public var longEdge: Int = 4096
    /// Percentage of the processed size; 1...400 when `mode == .percent`.
    public var percent: Double = 100
    public init(mode: ExportResizeMode = .none, longEdge: Int = 4096, percent: Double = 100) {
        self.mode = mode; self.longEdge = longEdge; self.percent = percent
    }
    public var isNeutral: Bool { mode == .none }
}

public struct ExportSettings: Codable, Equatable {
    public var format: ExportFormat = .jpeg
    public var colorSpace: OutputColorSpace = .sRGB
    public var jpegQuality: Double = 0.94
    public var recursive = false
    public var suffix = "_graded"
    /// Removes camera identifiers, location and all original EXIF on export when true.
    public var stripMetadata = true
    /// Optional so recipes written before v10 keep their original export path.
    public var resize: ExportResizeSettings? = nil
    /// Optional template with {name}, {suffix} and {index}; nil keeps the legacy
    /// "<name><suffix>.<ext>" naming.
    public var fileNameTemplate: String? = nil
    public init() {}
}

public extension ExportSettings {
    /// True when any export extension field requires a v10 recipe. The app
    /// uses this predicate to auto-upgrade a recipe it is about to save, so a
    /// HEIC/resize/template export can be saved and loaded again instead of
    /// being rejected by its own version gate.
    var requiresVersion10Recipe: Bool {
        format == .heic
            || (resize.map { !$0.isNeutral } ?? false)
            || (fileNameTemplate?.isEmpty == false)
    }
}

public struct Recipe: Codable, Equatable {
    /// Version 9 adds opt-in per-photo LUT candidate evaluation.
    /// Version 10 adds portrait refinement, reference color and export extensions.
    /// Version 11 adds the P1 color tools, liquify and watermark fields.
    public var version = 9
    public var adjustments: AdjustmentSettings
    public var export: ExportSettings
    public var lutPath: String?
    public var lutIdentifier: String?
    public var automatic: AutomaticBatchRecipe?
    public init(adjustments: AdjustmentSettings = .init(), export: ExportSettings = .init(),
                lutPath: String? = nil, lutIdentifier: String? = nil,
                automatic: AutomaticBatchRecipe? = nil) {
        self.adjustments = adjustments; self.export = export
        self.lutPath = lutPath; self.lutIdentifier = lutIdentifier
        self.automatic = automatic
    }

    public func validateVersion() throws {
        guard (1...11).contains(version) else {
            throw AtelierError.invalidConfiguration("不支持的配方版本：\(version)")
        }
        let portraitSettings = [adjustments.portrait,
                                automatic?.baseline.portrait,
                                automatic?.referenceSettings.portrait]
        guard version >= 10 || portraitSettings.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("非中性的人像修复需要配方版本 10，不能静默降级。")
        }
        let referenceColors = [adjustments.referenceColor,
                               automatic?.baseline.referenceColor,
                               automatic?.referenceSettings.referenceColor]
        guard version >= 10 || referenceColors.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("参考图追色需要配方版本 10，不能静默降级。")
        }
        let colorToolGroups = [adjustments.colorTools,
                               automatic?.baseline.colorTools,
                               automatic?.referenceSettings.colorTools]
        guard version >= 11 || colorToolGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("曲线/HSL/颜色分级需要配方版本 11，不能静默降级。")
        }
        let lensEffectGroups = [adjustments.lensEffects,
                                automatic?.baseline.lensEffects,
                                automatic?.referenceSettings.lensEffects]
        guard version >= 11 || lensEffectGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("暗角/横向色差需要配方版本 11，不能静默降级。")
        }
        let liquifyGroups = [adjustments.liquify,
                             automatic?.baseline.liquify,
                             automatic?.referenceSettings.liquify]
        guard version >= 11 || liquifyGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("非中性的液化/美型需要配方版本 11，不能静默降级。")
        }
        let exportSettings = self.export
        let usesExtendedExport = exportSettings.requiresVersion10Recipe
        guard version >= 10 || !usesExtendedExport else {
            throw AtelierError.invalidConfiguration("HEIC 输出、导出缩放与文件名模板需要配方版本 10，不能静默降级。")
        }
        guard version >= 4 || automatic?.sceneIntent == nil else {
            throw AtelierError.invalidConfiguration("显式场景意图需要配方版本 4，不能静默降级。")
        }
        let curves = [adjustments.tonalCurve, automatic?.baseline.tonalCurve,
                      automatic?.referenceSettings.tonalCurve]
        guard version >= 5 || curves.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("非中性的亮度分区曲线需要配方版本 5，不能静默降级。")
        }
        let maskGroups = [adjustments.masks, automatic?.baseline.masks ?? [],
                          automatic?.referenceSettings.masks ?? []]
        let effects = [adjustments.creativeEffects, automatic?.baseline.creativeEffects,
                       automatic?.referenceSettings.creativeEffects]
        let adaptations = [adjustments.adaptiveLUT, automatic?.baseline.adaptiveLUT,
                           automatic?.referenceSettings.adaptiveLUT]
        guard version >= 9 || adaptations.allSatisfy({ $0 == nil || $0?.enabled == false }) else {
            throw AtelierError.invalidConfiguration("逐图 LUT 适配需要配方版本 9，不能静默降级。")
        }
        guard version >= 8 || effects.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("辉光、暗角与颗粒需要配方版本 8，不能静默降级。")
        }
        guard version >= 7 || maskGroups.joined().allSatisfy({
            $0.detailAdaptation == nil && ($0.detail?.noiseReduction ?? 0) == 0 && ($0.detail?.detailRecovery ?? 0) == 0
        }) else {
            throw AtelierError.invalidConfiguration("逐图细节适配、降噪与纹理增强需要配方版本 7，不能静默降级。")
        }
        guard version >= 6 || maskGroups.joined().allSatisfy({
            $0.contentSelection == nil && ($0.detail?.isNeutral ?? true)
        }) else {
            throw AtelierError.invalidConfiguration("内容感知选区或非中性细节处理需要配方版本 6，不能静默降级。")
        }
    }
}

public struct PhotoItem: Identifiable, Equatable {
    public let url: URL
    public let relativePath: String
    public var id: String { url.path }
    public init(url: URL, relativePath: String) { self.url = url; self.relativePath = relativePath }
}

/// Per-photo record of the liquify/face-reshape stage. `nil` means no active
/// liquify setting (pre-v11 path). A non-nil report with `applied == false`
/// documents that a face-dependent warp was requested but skipped (no usable
/// face), so batch manifests can say why instead of silently omitting it.
/// Pure math for preset-relative liquify sliders, shared by the UI and tests.
///
/// A preset contributes an offset on every slider; an explicit slider edit is
/// stored as a clamped offset so `preset + offset` can never leave `-1...1`
/// (which `FaceReshapeEngine.validate` would reject, failing the whole preview).
public enum LiquifySliderMath {
    /// Clamped explicit offset for a slider position showing `effective`.
    public static func explicitOffset(forEffective effective: Double,
                                      presetValue: Double) -> Double {
        guard effective.isFinite, presetValue.isFinite else { return 0 }
        return min(1, max(-1, effective - presetValue))
    }

    /// The effective value the slider should display after clamping.
    public static func clampedEffective(_ effective: Double, presetValue: Double) -> Double {
        let offset = explicitOffset(forEffective: effective, presetValue: presetValue)
        return min(1, max(-1, presetValue + offset))
    }
}

/// Brush footprint math shared by the canvas overlay and the warp field.
///
/// A `WarpStroke.radius` is a fraction of each image axis, so the real footprint
/// is an ellipse with pixel radii `(radius × width, radius × height)` — not a
/// circle based on the short edge. The overlay must use the same radii.
public enum LiquifyBrushGeometry {
    public static func pixelRadii(radius: Double, imageSize: CGSize) -> (x: Double, y: Double) {
        guard radius.isFinite, radius > 0,
              imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return (0, 0) }
        return (radius * Double(imageSize.width), radius * Double(imageSize.height))
    }
}

public struct LiquifyIntegrationReport: Codable, Equatable {
    public var applied: Bool
    public var faceCount: Int
    public var presetApplied: Bool
    public var strokeCount: Int
    public var note: String?

    public init(applied: Bool = false, faceCount: Int = 0,
                presetApplied: Bool = false, strokeCount: Int = 0,
                note: String? = nil) {
        self.applied = applied
        self.faceCount = faceCount
        self.presetApplied = presetApplied
        self.strokeCount = strokeCount
        self.note = note
    }
}

public struct ProcessingReport: Codable, Equatable {
    public var warnings: [String] = []
    public var appliedExposureEV: Double = 0
    public var lensCorrectionApplied = false
    public var lensProfile: String?
    public var straighteningDegrees: Double = 0
    public var sourceColorSpace = ""
    public var inputWasRAW = false
    public var analysis: AutomaticAnalysisRecord?
    public var colorQuality: ColorQualityReport?
    public var lutCompatibility: LUTCompatibilityReport?
    public var lutAdaptation: LUTAdaptationReport?
    public var contentSelection: ContentSelectionReport?
    public var localDetails: [LocalDetailPlan]?
    /// Per-photo portrait pass status; batch manifests use it to record
    /// "applied" versus "no usable face" without re-running detection.
    public var portrait: PortraitRefinementReport?
    /// Per-photo reference-color ("AI 追色") status. `nil` when the recipe has no
    /// active reference color; batch manifests use it to record whether the
    /// shared profile was applied or explicitly skipped.
    public var referenceColor: ReferenceColorReport?
    /// Per-photo P1 color-tool status (curves/HSL/grading/lens effects).
    /// `nil` when no color tool is active, keeping the pre-v11 path exact.
    public var colorTools: ColorToolsReport?
    /// Per-photo P1 liquify/face-reshape status. `nil` when liquify is absent or
    /// neutral; a report with `applied == false` records a face-dependent skip.
    public var liquify: LiquifyIntegrationReport?
    public init() {}
}

public struct LoadedPhoto {
    public let image: CIImage
    public let properties: [String: Any]
    public let report: ProcessingReport
    public init(image: CIImage, properties: [String: Any] = [:], report: ProcessingReport = .init()) {
        self.image = image; self.properties = properties; self.report = report
    }
}

public struct ProcessedPhoto {
    public let image: CIImage
    public let report: ProcessingReport
    /// Ephemeral coverage is shared within this photo's preview; never encoded in recipes/reports.
    public let contentSelections: ContentSelectionResult?
    public init(image: CIImage, report: ProcessingReport, contentSelections: ContentSelectionResult? = nil) {
        self.image = image; self.report = report; self.contentSelections = contentSelections
    }
}

public struct BatchSummary: Codable {
    public var succeeded: Int
    public var failed: Int
    public var cancelled: Bool
    public var manifestURL: URL?
    public init(succeeded: Int = 0, failed: Int = 0, cancelled: Bool = false, manifestURL: URL? = nil) {
        self.succeeded = succeeded; self.failed = failed; self.cancelled = cancelled; self.manifestURL = manifestURL
    }
}

public struct BatchEvent {
    public enum Kind { case started, processing, completed, failed, cancelled, finished }
    public let kind: Kind
    public let index: Int
    public let total: Int
    public let input: URL?
    public let output: URL?
    public let message: String
    public let report: ProcessingReport?
    public init(kind: Kind, index: Int, total: Int, input: URL? = nil,
                output: URL? = nil, message: String = "", report: ProcessingReport? = nil) {
        self.kind = kind; self.index = index; self.total = total
        self.input = input; self.output = output; self.message = message; self.report = report
    }
}

/// A cooperative, thread-safe cancellation flag; each batch owns its own instance.
public final class CancellationToken {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    public func check() throws { if isCancelled { throw AtelierError.cancelled } }
}

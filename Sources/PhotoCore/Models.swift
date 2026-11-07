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
    /// Optional for exact compatibility with recipes written before v12.
    /// Absent or `enabled == false` certificate settings keep the pre-v12 path.
    public var certificatePhoto: CertificatePhotoSettings? = nil
    /// Optional for exact compatibility with recipes written before v12.
    /// Absent or empty manual repair/clone strokes keep the pre-v12 render path.
    public var repairBrush: RepairBrushSettings? = nil
    /// Optional for exact compatibility with recipes written before v13.
    /// Absent or fully neutral (all strengths zero) make-up keeps the pre-v13 path.
    public var makeup: MakeupSettings? = nil
    /// Optional for exact compatibility with recipes written before v14.
    /// Absent or disabled studio backdrop refinement keeps the pre-v14 path.
    public var backdrop: BackdropRefinementSettings? = nil
    /// Optional for exact compatibility with recipes written before v15.
    /// Absent or disabled clothing refinement keeps the pre-v15 path.
    public var clothing: ClothingRefinementSettings? = nil
    /// Optional for exact compatibility with recipes written before v16.
    /// Absent or disabled body and hand skin refinement keeps the pre-v16 path.
    public var bodySkin: BodySkinRefinementSettings? = nil
    /// Optional for exact compatibility with recipes written before v17.
    /// Absent or disabled facial zonal wrinkle smoothing & anti-shine keeps the pre-v17 path.
    public var facialZonal: FacialZonalRefinementSettings? = nil
    public var masks: [LocalMask] = []
    public init() {}
}

/// Background source for certificate-photo / background replacement.
public enum CertificateBackgroundSource: String, Codable, CaseIterable, Identifiable {
    case preset, customColor, image

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .preset: return "标准背景色"
        case .customColor: return "自定义颜色"
        case .image: return "本地背景图片"
        }
    }
}

/// Certificate-photo / background-replacement settings (recipe v12).
///
/// `enabled == false` is the explicit neutral state: the field may be present in a
/// recipe but the engine skips the stage and keeps the pre-v12 pixel path exactly.
/// When `size` is nil the stage only replaces the background and keeps the
/// original extent; a non-nil size additionally crops to the exact preset pixel
/// size (300 DPI by default), which **changes the canvas extent** — later local
/// masks are normalized against the cropped image and should be reviewed.
///
/// This is a heuristic v1 cutout composition (Vision person segmentation + feather
/// + colored background + synthetic shadow), not commercial matting. Real-photo
/// aesthetic quality is not guaranteed.
public struct CertificatePhotoSettings: Codable, Equatable {
    public var enabled: Bool
    public var backgroundSource: CertificateBackgroundSource
    public var backgroundPreset: IDPhotoBackgroundPreset
    public var customBackground: SRGBColor
    /// Local file path used when `backgroundSource == .image`; network URLs are rejected.
    public var backgroundImagePath: String?
    public var shadow: BackgroundReplacementSettings
    /// `nil` = keep original framing (background replacement only).
    public var size: IDPhotoSize?
    public var crop: IDPhotoCropSettings
    /// Print-sheet preview geometry. Stored for UI/batch metadata; it never changes
    /// the processed photo pixels.
    public var print: PrintSheetSettings

    public init(enabled: Bool = false,
                backgroundSource: CertificateBackgroundSource = .preset,
                backgroundPreset: IDPhotoBackgroundPreset = .white,
                customBackground: SRGBColor = SRGBColor(red: 0.10, green: 0.30, blue: 0.70),
                backgroundImagePath: String? = nil,
                shadow: BackgroundReplacementSettings = BackgroundReplacementSettings(),
                size: IDPhotoSize? = nil,
                crop: IDPhotoCropSettings = IDPhotoCropSettings(),
                print: PrintSheetSettings = PrintSheetSettings()) {
        self.enabled = enabled
        self.backgroundSource = backgroundSource
        self.backgroundPreset = backgroundPreset
        self.customBackground = customBackground
        self.backgroundImagePath = backgroundImagePath
        self.shadow = shadow
        self.size = size
        self.crop = crop
        self.print = print
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, backgroundSource, backgroundPreset, customBackground
        case backgroundImagePath, shadow, size, crop, print
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        backgroundSource = try values.decodeIfPresent(CertificateBackgroundSource.self,
                                                     forKey: .backgroundSource) ?? .preset
        backgroundPreset = try values.decodeIfPresent(IDPhotoBackgroundPreset.self,
                                                     forKey: .backgroundPreset) ?? .white
        customBackground = try values.decodeIfPresent(SRGBColor.self,
                                                     forKey: .customBackground)
            ?? SRGBColor(red: 0.10, green: 0.30, blue: 0.70)
        backgroundImagePath = try values.decodeIfPresent(String.self, forKey: .backgroundImagePath)
        shadow = try values.decodeIfPresent(BackgroundReplacementSettings.self,
                                           forKey: .shadow) ?? BackgroundReplacementSettings()
        size = try values.decodeIfPresent(IDPhotoSize.self, forKey: .size)
        crop = try values.decodeIfPresent(IDPhotoCropSettings.self, forKey: .crop)
            ?? IDPhotoCropSettings()
        print = try values.decodeIfPresent(PrintSheetSettings.self, forKey: .print)
            ?? PrintSheetSettings()
    }

    /// Enabled false means "explicitly neutral": the engine and recipe gate must
    /// keep the pre-v12 pixel/version path.
    public var isNeutral: Bool { !enabled }

    public func validated() throws {
        guard isNeutral || backgroundSource != .image
                || (((backgroundImagePath?.count ?? 0) <= 4096)
                    && !(backgroundImagePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)) else {
            throw AtelierError.invalidConfiguration("证件照背景图片路径不能为空或过长。")
        }
        if backgroundSource == .customColor {
            _ = try customBackground.validated()
        }
        _ = try shadow.validated()
        _ = try crop.validated()
        _ = try print.validated()
    }
}

/// Per-photo record of the P1-B certificate-photo / background stage. `nil` means
/// no active certificate setting (pre-v12 path); `applied == false` documents an
/// explicit skip (no usable person/face), never a silent edit.
public struct CertificatePhotoReport: Codable, Equatable {
    public var applied: Bool
    public var background: String
    public var coverage: Double
    public var outputPixelSize: CGSize?
    public var note: String?

    public init(applied: Bool, background: String = "", coverage: Double = 0,
                outputPixelSize: CGSize? = nil, note: String? = nil) {
        self.applied = applied
        self.background = background
        self.coverage = coverage
        self.outputPixelSize = outputPixelSize
        self.note = note
    }
}

/// Studio backdrop smoothing & defect removal settings (recipe v14).
public struct BackdropRefinementSettings: Codable, Equatable {
    /// Master toggle for backdrop refinement. `false` leaves pixels unchanged.
    public var enabled: Bool = false
    /// Smoothing strength for backdrop paper wrinkles, seams, and lighting gradients (0...1).
    public var smoothing: Double = 0
    /// Cleanup strength for isolated dust spots, footprints, scuffs and tape on backdrop (0...1).
    public var cleanup: Double = 0
    /// Neutralize color casts across the backdrop (0...1).
    public var uniformity: Double = 0

    public init(enabled: Bool = false,
                smoothing: Double = 0,
                cleanup: Double = 0,
                uniformity: Double = 0) {
        self.enabled = enabled
        self.smoothing = smoothing
        self.cleanup = cleanup
        self.uniformity = uniformity
    }

    public var isNeutral: Bool {
        !enabled || (smoothing == 0 && cleanup == 0 && uniformity == 0)
    }

    public func validated() throws -> BackdropRefinementSettings {
        guard smoothing.isFinite, (0...1).contains(smoothing) else {
            throw AtelierError.invalidConfiguration("背景平整强度必须在 0...1 之间。")
        }
        guard cleanup.isFinite, (0...1).contains(cleanup) else {
            throw AtelierError.invalidConfiguration("背景去污强度必须在 0...1 之间。")
        }
        guard uniformity.isFinite, (0...1).contains(uniformity) else {
            throw AtelierError.invalidConfiguration("背景色调统一必须在 0...1 之间。")
        }
        return self
    }
}

/// Per-photo record of the P2-D studio backdrop refinement stage.
public struct BackdropRefinementReport: Codable, Equatable {
    public var applied: Bool
    public var appliedSteps: [String]
    public var note: String?

    public init(applied: Bool, appliedSteps: [String] = [], note: String? = nil) {
        self.applied = applied
        self.appliedSteps = appliedSteps
        self.note = note
    }
}

/// Settings for P2-F clothing wrinkle smoothing and fabric refinement.
public struct ClothingRefinementSettings: Codable, Equatable {
    /// Master toggle for clothing refinement. `false` leaves pixels unchanged.
    public var enabled: Bool = false
    /// Smoothing strength for unwanted fabric wrinkles and folds (0...1).
    public var wrinkleSmoothing: Double = 0
    /// Crease/seam line attenuation strength (0...1).
    public var creaseRemoval: Double = 0
    /// Texture retention: preserves fine fabric weave / knit pattern while smoothing folds (0...1, default 0.7).
    public var texturePreservation: Double = 0.7

    public init(enabled: Bool = false,
                wrinkleSmoothing: Double = 0,
                creaseRemoval: Double = 0,
                texturePreservation: Double = 0.7) {
        self.enabled = enabled
        self.wrinkleSmoothing = wrinkleSmoothing
        self.creaseRemoval = creaseRemoval
        self.texturePreservation = texturePreservation
    }

    public var isNeutral: Bool {
        !enabled || (wrinkleSmoothing == 0 && creaseRemoval == 0)
    }

    public func validated() throws -> ClothingRefinementSettings {
        guard wrinkleSmoothing.isFinite, (0...1).contains(wrinkleSmoothing) else {
            throw AtelierError.invalidConfiguration("衣物平整强度必须在 0...1 之间。")
        }
        guard creaseRemoval.isFinite, (0...1).contains(creaseRemoval) else {
            throw AtelierError.invalidConfiguration("衣物褶皱抑制必须在 0...1 之间。")
        }
        guard texturePreservation.isFinite, (0...1).contains(texturePreservation) else {
            throw AtelierError.invalidConfiguration("衣物织物肌理保护必须在 0...1 之间。")
        }
        return self
    }
}

/// Per-photo record of the P2-F clothing wrinkle smoothing stage.
public struct ClothingRefinementReport: Codable, Equatable {
    public var applied: Bool
    public var appliedSteps: [String]
    public var note: String?

    public init(applied: Bool = false, appliedSteps: [String] = [], note: String? = nil) {
        self.applied = applied
        self.appliedSteps = appliedSteps
        self.note = note
    }
}

/// Settings for P2-G body and hand skin refinement (neck smoothing, vein reduction, body tone harmonization).
public struct BodySkinRefinementSettings: Codable, Equatable {
    /// Master toggle for body and hand skin refinement. `false` leaves pixels unchanged.
    public var enabled: Bool = false
    /// Neck wrinkle and crease smoothing strength (0...1).
    public var neckSmoothing: Double = 0
    /// Body and limbs skin smoothing (0...1).
    public var bodySmoothing: Double = 0
    /// Hand and arm superficial vein & joint redness/darkness reduction (0...1).
    public var veinReduction: Double = 0
    /// Harmonize body and hand skin tone towards the face skin tone (0...1).
    public var bodyToneHarmonization: Double = 0
    /// Micro-texture retention: preserves fine skin pores while smoothing (0...1, default 0.7).
    public var texturePreservation: Double = 0.7

    public init(enabled: Bool = false,
                neckSmoothing: Double = 0,
                bodySmoothing: Double = 0,
                veinReduction: Double = 0,
                bodyToneHarmonization: Double = 0,
                texturePreservation: Double = 0.7) {
        self.enabled = enabled
        self.neckSmoothing = neckSmoothing
        self.bodySmoothing = bodySmoothing
        self.veinReduction = veinReduction
        self.bodyToneHarmonization = bodyToneHarmonization
        self.texturePreservation = texturePreservation
    }

    public var isNeutral: Bool {
        !enabled || (neckSmoothing == 0 && bodySmoothing == 0 && veinReduction == 0 && bodyToneHarmonization == 0)
    }

    public func validated() throws -> BodySkinRefinementSettings {
        guard neckSmoothing.isFinite, (0...1).contains(neckSmoothing) else {
            throw AtelierError.invalidConfiguration("颈纹平整强度必须在 0...1 之间。")
        }
        guard bodySmoothing.isFinite, (0...1).contains(bodySmoothing) else {
            throw AtelierError.invalidConfiguration("身体平整强度必须在 0...1 之间。")
        }
        guard veinReduction.isFinite, (0...1).contains(veinReduction) else {
            throw AtelierError.invalidConfiguration("青筋淡化强度必须在 0...1 之间。")
        }
        guard bodyToneHarmonization.isFinite, (0...1).contains(bodyToneHarmonization) else {
            throw AtelierError.invalidConfiguration("身体肤色统一强度必须在 0...1 之间。")
        }
        guard texturePreservation.isFinite, (0...1).contains(texturePreservation) else {
            throw AtelierError.invalidConfiguration("皮肤肌理保护必须在 0...1 之间。")
        }
        return self
    }
}

/// Per-photo record of the P2-G body and hand skin refinement stage.
public struct BodySkinRefinementReport: Codable, Equatable {
    public var applied: Bool
    public var appliedSteps: [String]
    public var note: String?

    public init(applied: Bool = false, appliedSteps: [String] = [], note: String? = nil) {
        self.applied = applied
        self.appliedSteps = appliedSteps
        self.note = note
    }
}

/// Settings for P2-H smart facial zonal wrinkle smoothing and anti-shine matte finish.
public struct FacialZonalRefinementSettings: Codable, Equatable {
    /// Master toggle for facial zonal refinement. `false` leaves pixels unchanged.
    public var enabled: Bool = false
    /// Dark circles reduction: lifts darkness and neutralizes purplish/bluish undertone in lower eyelid area (0...1).
    public var darkCircles: Double = 0
    /// Under-eye bags & tear troughs smoothing: lifts curvilinear crease shadow beneath eye orbital rim (0...1).
    public var eyeBags: Double = 0
    /// Nasolabial folds / smile lines smoothing: softens shadow grooves from nose wings down to mouth corners (0...1).
    public var nasolabialFolds: Double = 0
    /// Forehead wrinkles & glabellar frown lines smoothing: softens horizontal forehead lines and between-eyebrow vertical furrows (0...1).
    public var foreheadWrinkles: Double = 0
    /// Facial anti-shine / specular matte: suppresses harsh specular grease hotspots on T-zone and cheeks toward diffuse skin (0...1).
    public var antiShine: Double = 0
    /// Jawline & double-chin sculpting: softens submental shadow crease under chin to define clean mandibular contour (0...1).
    public var jawlineSculpting: Double = 0
    /// Micro-texture retention: preserves fine skin pores while smoothing (0...1, default 0.70).
    public var texturePreservation: Double = 0.70

    public init(enabled: Bool = false,
                darkCircles: Double = 0,
                eyeBags: Double = 0,
                nasolabialFolds: Double = 0,
                foreheadWrinkles: Double = 0,
                antiShine: Double = 0,
                jawlineSculpting: Double = 0,
                texturePreservation: Double = 0.70) {
        self.enabled = enabled
        self.darkCircles = darkCircles
        self.eyeBags = eyeBags
        self.nasolabialFolds = nasolabialFolds
        self.foreheadWrinkles = foreheadWrinkles
        self.antiShine = antiShine
        self.jawlineSculpting = jawlineSculpting
        self.texturePreservation = texturePreservation
    }

    public var isNeutral: Bool {
        !enabled || (darkCircles == 0 && eyeBags == 0 && nasolabialFolds == 0 && foreheadWrinkles == 0 && antiShine == 0 && jawlineSculpting == 0)
    }

    public func validated() throws -> FacialZonalRefinementSettings {
        guard darkCircles.isFinite, (0...1).contains(darkCircles) else {
            throw AtelierError.invalidConfiguration("黑眼圈淡化强度必须在 0...1 之间。")
        }
        guard eyeBags.isFinite, (0...1).contains(eyeBags) else {
            throw AtelierError.invalidConfiguration("眼袋泪沟平整强度必须在 0...1 之间。")
        }
        guard nasolabialFolds.isFinite, (0...1).contains(nasolabialFolds) else {
            throw AtelierError.invalidConfiguration("法令纹平整强度必须在 0...1 之间。")
        }
        guard foreheadWrinkles.isFinite, (0...1).contains(foreheadWrinkles) else {
            throw AtelierError.invalidConfiguration("抬头纹与川字纹平整强度必须在 0...1 之间。")
        }
        guard antiShine.isFinite, (0...1).contains(antiShine) else {
            throw AtelierError.invalidConfiguration("面部去油光强度必须在 0...1 之间。")
        }
        guard jawlineSculpting.isFinite, (0...1).contains(jawlineSculpting) else {
            throw AtelierError.invalidConfiguration("下颌线修容强度必须在 0...1 之间。")
        }
        guard texturePreservation.isFinite, (0...1).contains(texturePreservation) else {
            throw AtelierError.invalidConfiguration("皮肤肌理保护必须在 0...1 之间。")
        }
        return self
    }
}

/// Per-photo record of the P2-H facial zonal refinement stage.
public struct FacialZonalRefinementReport: Codable, Equatable {
    public var applied: Bool
    public var appliedSteps: [String]
    public var note: String?

    public init(applied: Bool = false, appliedSteps: [String] = [], note: String? = nil) {
        self.applied = applied
        self.appliedSteps = appliedSteps
        self.note = note
    }
}

/// Manual repair / clone brush strokes stored in a v12 recipe.
///
/// This is plain data: the pixels are produced by `RepairBrushEngine` in the
/// processing pipeline (after lens effects and before portrait refinement). An
/// empty stroke list is the neutral state; an absent field keeps the v1–v11
/// pixel path exact.
///
/// Semantics are deliberately not generative and not automatic defect detection:
/// the caller marks where to paint and the engine uses a low-frequency/donor-patch
/// heuristic (heal) or copies the offset source (clone). Strength/feather blends
/// happen in the **engine's working colour space** (the app pipeline uses extended
/// linear sRGB), so partial-strength pixel values differ from an sRGB-only unit
/// test even though geometry and alpha relations are identical.
///
/// Non-neutral settings require recipe version 12 (`Recipe.validateVersion`).
public struct RepairBrushSettings: Codable, Equatable {
    /// Strokes applied in array order; later strokes see the earlier result.
    public var strokes: [RepairStroke]

    public init(strokes: [RepairStroke] = []) {
        self.strokes = strokes
    }

    /// True when the setting cannot change pixels; the field may then be omitted.
    public var isNeutral: Bool { strokes.isEmpty }

    public func validate() throws {
        guard strokes.count <= RepairBrushEngine.maximumStrokeCount else {
            throw AtelierError.invalidConfiguration(
                "修复画笔笔迹数量不能超过 \(RepairBrushEngine.maximumStrokeCount) 笔。")
        }
        for (index, stroke) in strokes.enumerated() {
            do {
                try stroke.validate()
            } catch {
                throw AtelierError.invalidConfiguration(
                    "第 \(index + 1) 笔修复笔迹无效：\(error.localizedDescription)")
            }
        }
    }
}

/// Per-photo record of the P1-B manual repair stage. `nil` means the recipe has no
/// repair strokes (pre-v12 path); a non-nil report states how many strokes were
/// applied so batch manifests can record the per-photo repair status.
public struct RepairBrushReport: Codable, Equatable {
    public var applied: Bool
    public var strokeCount: Int
    public var healStrokeCount: Int
    public var cloneStrokeCount: Int
    public var note: String?

    public init(applied: Bool, strokeCount: Int = 0, healStrokeCount: Int = 0,
                cloneStrokeCount: Int = 0, note: String? = nil) {
        self.applied = applied
        self.strokeCount = strokeCount
        self.healStrokeCount = healStrokeCount
        self.cloneStrokeCount = cloneStrokeCount
        self.note = note
    }
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
    /// Optional watermark composited by the exporter after resizing and before
    /// encoding. Nil keeps legacy exports pixel-identical. A non-neutral
    /// watermark requires recipe version 11 (`Recipe.validateVersion`).
    public var watermark: WatermarkSettings? = nil
    /// Batch-only flag: when true and a non-neutral watermark is configured, a
    /// batch run writes both a watermarked and an unwatermarked copy per photo.
    /// Optional so recipes written before v11 keep decoding unchanged.
    public var watermarkDualVersion: Bool? = nil
    /// Optional offline customer delivery page generated from the exported files
    /// (static HTML album with thumbnails/previews + optional contact-sheet PDF).
    /// Nil keeps the legacy export path; a stored value requires recipe version
    /// 12 (`Recipe.validateVersion`). The gallery itself never touches the
    /// network and re-encodes images without metadata.
    public var deliveryPage: DeliverySettings? = nil
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

    /// True when the watermark changes pixels and therefore needs a v11 recipe.
    /// A neutral watermark (opacity <= 0) is a documented no-op, so v10 recipes
    /// carrying one stay loadable.
    var requiresVersion11Recipe: Bool {
        guard let watermark else { return false }
        return !watermark.isNeutral
    }

    /// True when any watermark payload is stored, even a neutral one. The save
    /// path uses this so watermark data round-trips in v11 instead of being
    /// written into a recipe whose v11 gate still permits it (neutral) but whose
    /// intent is a P1 export.
    var storesWatermarkData: Bool {
        watermark != nil
    }

    /// True when a batch run should write both watermark versions. Requires an
    /// active (non-neutral) watermark; a stale dual flag alone is ignored.
    var exportsDualWatermarkVersion: Bool {
        watermarkDualVersion == true && requiresVersion11Recipe
    }

    /// True when a customer delivery page is configured. The delivery payload is
    /// only represented in v12 recipes, so any stored value needs the v12 gate
    /// (there is no "neutral" delivery page: nil is the legacy path).
    var requiresVersion12Recipe: Bool {
        deliveryPage != nil
    }

    /// True when any delivery-page payload is stored. The save path bumps the
    /// recipe to v12 so the recipe can be loaded back instead of being rejected
    /// by the app's own v12 gate.
    var storesDeliveryPageData: Bool {
        deliveryPage != nil
    }
}

/// Per-photo record of the P1-C make-up stage. `nil` means no active make-up
/// (pre-v13 path); `applied == false` documents an explicit no-face skip so batch
/// manifests can state why instead of silently omitting the stage. `applied == true`
/// means the stage executed with usable face landmarks; because the masks are
/// heuristic, an individual face can still be a geometric no-op, so manifests must
/// not read `applied` as a guarantee of changed pixels.
public struct MakeupReport: Codable, Equatable {
    public var applied: Bool
    public var faceCount: Int
    public var note: String?

    public init(applied: Bool, faceCount: Int = 0, note: String? = nil) {
        self.applied = applied
        self.faceCount = faceCount
        self.note = note
    }
}

public extension MakeupSettings {
    /// UI persistence rule used by `AppModel`: only an all-default setting collapses
    /// to nil. A neutral setting whose colours or cheek radius were edited is kept
    /// so the ColorPicker selection survives until an intensity is raised. Such a
    /// setting is still `isNeutral` (no pixels change, old recipe versions stay
    /// legal), only its payload is retained.
    static func collapsed(_ settings: MakeupSettings) -> MakeupSettings? {
        settings == MakeupSettings() ? nil : settings
    }
}

public struct Recipe: Codable, Equatable {
    /// Version 9 adds opt-in per-photo LUT candidate evaluation.
    /// Version 10 adds portrait refinement, reference color and export extensions.
    /// Version 11 adds the P1 color tools, liquify and watermark fields.
    /// Version 12 adds certificate photo / background replacement, manual repair
    /// brush strokes and the customer delivery page export.
    /// Version 13 adds the heuristic make-up fields (lips/brows/blush/eyeshadow).
    /// Version 14 adds studio backdrop refinement and advanced make-up sculpting.
    /// Version 15 adds smart clothing wrinkle smoothing and crease removal.
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
        guard (1...17).contains(version) else {
            throw AtelierError.invalidConfiguration("不支持的配方版本：\(version)")
        }
        let facialZonalGroups = [adjustments.facialZonal,
                                 automatic?.baseline.facialZonal,
                                 automatic?.referenceSettings.facialZonal]
        guard version >= 17 || facialZonalGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("非中性的面部五区精修需要配方版本 17，不能静默降级。")
        }
        let bodySkinGroups = [adjustments.bodySkin,
                              automatic?.baseline.bodySkin,
                              automatic?.referenceSettings.bodySkin]
        guard version >= 16 || bodySkinGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("非中性的身体与手部美肤需要配方版本 16，不能静默降级。")
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
        let certificateGroups = [adjustments.certificatePhoto,
                                 automatic?.baseline.certificatePhoto,
                                 automatic?.referenceSettings.certificatePhoto]
        guard version >= 12 || certificateGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("证件照/换背景需要配方版本 12，不能静默降级。")
        }
        let repairGroups = [adjustments.repairBrush,
                            automatic?.baseline.repairBrush,
                            automatic?.referenceSettings.repairBrush]
        guard version >= 12 || repairGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("手动修复/仿制笔迹需要配方版本 12，不能静默降级。")
        }
        let makeupGroups = [adjustments.makeup,
                            automatic?.baseline.makeup,
                            automatic?.referenceSettings.makeup]
        guard version >= 14 || makeupGroups.allSatisfy({ $0 == nil || !$0!.requiresVersion14 }) else {
            throw AtelierError.invalidConfiguration("眼线/睫毛/美瞳/眼神光/高光修容等增强妆容需要配方版本 14，不能静默降级。")
        }
        let clothingGroups = [adjustments.clothing,
                              automatic?.baseline.clothing,
                              automatic?.referenceSettings.clothing]
        guard version >= 15 || clothingGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("非中性的衣物平整与祛皱需要配方版本 15，不能静默降级。")
        }
        let backdropGroups = [adjustments.backdrop,
                              automatic?.baseline.backdrop,
                              automatic?.referenceSettings.backdrop]
        guard version >= 14 || backdropGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("非中性的影棚背景修复需要配方版本 14，不能静默降级。")
        }
        guard version >= 13 || makeupGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("非中性的妆容需要配方版本 13，不能静默降级。")
        }
        let exportSettings = self.export
        let usesExtendedExport = exportSettings.requiresVersion10Recipe
        guard version >= 10 || !usesExtendedExport else {
            throw AtelierError.invalidConfiguration("HEIC 输出、导出缩放与文件名模板需要配方版本 10，不能静默降级。")
        }
        guard version >= 11 || !exportSettings.requiresVersion11Recipe else {
            throw AtelierError.invalidConfiguration("水印导出需要配方版本 11，不能静默降级。")
        }
        guard version >= 12 || !exportSettings.requiresVersion12Recipe else {
            throw AtelierError.invalidConfiguration("客户交付页导出需要配方版本 12，不能静默降级。")
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

    /// Session-only star rating (`0...5`) from the culling UI. Never written to
    /// recipes, manifests or disk: a new library scan starts with no ratings.
    public var rating: Int = 0
    /// Session-only "waste / reject" mark; the batch export can skip these.
    public var isRejected: Bool = false
    /// Session-only heuristic quality report from `QualityAnalyzer`; nil until the
    /// user runs auto-culling (or a caller injects one).
    public var qualityReport: QualityReport?

    public var id: String { url.path }

    public init(url: URL, relativePath: String, rating: Int = 0, isRejected: Bool = false,
                qualityReport: QualityReport? = nil) {
        self.url = url
        self.relativePath = relativePath
        self.rating = min(5, max(0, rating))
        self.isRejected = isRejected
        self.qualityReport = qualityReport
    }

    /// Heuristic recommendation when the photo was analyzed, nil otherwise.
    public var qualityRecommendation: QualityRecommendation? { qualityReport?.recommendation }
}

/// Session-only batch export selection options from the culling UI.
///
/// Deliberately **not** part of `ExportSettings`/`Recipe`: ratings and rejection
/// marks are per-library session state (never persisted, never version-gated), so
/// a saved recipe cannot silently skip different files on another machine. Callers
/// pass these options to `BatchProcessor.run(..., selection: ...)` for one run.
public struct ExportSelectionOptions: Codable, Equatable {
    /// Skip photos marked as rejected (waste) in the culling UI.
    public var skipRejectedPhotos: Bool = false
    /// Skip photos that have not been rated yet (`rating == 0`) and are not
    /// rejected; rated photos (even 1 star) are still exported.
    public var skipUnselectedPhotos: Bool = false

    public init(skipRejectedPhotos: Bool = false, skipUnselectedPhotos: Bool = false) {
        self.skipRejectedPhotos = skipRejectedPhotos
        self.skipUnselectedPhotos = skipUnselectedPhotos
    }

    /// True when the options cannot change which files are exported.
    public var isNeutral: Bool { !skipRejectedPhotos && !skipUnselectedPhotos }

    /// Compact manifest/status summary, e.g. `skipRejected+skipUnselected`.
    public var summary: String {
        var parts: [String] = []
        if skipRejectedPhotos { parts.append("skipRejected") }
        if skipUnselectedPhotos { parts.append("skipUnselected") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }
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
    /// Per-photo P1-B certificate/background status. `nil` when absent or
    /// disabled; `applied == false` records an explicit no-person/no-face skip.
    public var certificatePhoto: CertificatePhotoReport?
    /// Per-photo P1-B manual repair/clone status. `nil` when the recipe has no
    /// strokes; otherwise records the applied stroke counts for batch manifests.
    public var repairBrush: RepairBrushReport?
    /// Per-photo P1-C make-up status. `nil` when the recipe has no active make-up;
    /// `applied == false` records an explicit no-face skip for batch manifests.
    public var makeup: MakeupReport?
    /// Per-photo P2-D studio backdrop refinement status. `nil` when absent or disabled.
    public var backdrop: BackdropRefinementReport?
    /// Per-photo P2-F clothing refinement status. `nil` when absent or disabled.
    public var clothing: ClothingRefinementReport?
    /// Per-photo P2-G body and hand skin refinement status. `nil` when absent or disabled.
    public var bodySkin: BodySkinRefinementReport?
    /// Per-photo P2-H facial zonal refinement status. `nil` when absent or disabled.
    public var facialZonal: FacialZonalRefinementReport?
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
    /// Photos deliberately skipped by the session export selection options
    /// (rejected / unrated); never counted as failures.
    public var skipped: Int
    public var cancelled: Bool
    public var manifestURL: URL?
    public init(succeeded: Int = 0, failed: Int = 0, cancelled: Bool = false,
                manifestURL: URL? = nil, skipped: Int = 0) {
        self.succeeded = succeeded; self.failed = failed; self.cancelled = cancelled
        self.manifestURL = manifestURL; self.skipped = skipped
    }

    private enum CodingKeys: String, CodingKey {
        case succeeded, failed, skipped, cancelled, manifestURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        succeeded = try container.decode(Int.self, forKey: .succeeded)
        failed = try container.decode(Int.self, forKey: .failed)
        cancelled = try container.decode(Bool.self, forKey: .cancelled)
        manifestURL = try container.decodeIfPresent(URL.self, forKey: .manifestURL)
        // Older summaries did not have skip counts; decode them as zero.
        skipped = try container.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
    }
}

public struct BatchEvent {
    public enum Kind { case started, processing, completed, failed, cancelled, skipped, finished }
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

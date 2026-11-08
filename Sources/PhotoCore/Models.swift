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
    /// Optional for exact compatibility with recipes written before v18.
    /// Absent or disabled pet enhancement keeps the pre-v18 path.
    public var petEnhancement: PetEnhancementSettings? = nil
    /// Optional for exact compatibility with recipes written before v19.
    /// Absent or disabled sky enhancement keeps the pre-v19 path.
    public var sky: SkyEnhancementSettings? = nil
    /// Optional for exact compatibility with recipes written before v20.
    /// Absent or disabled multi-person refinement keeps the pre-v20 path.
    public var multiPerson: MultiPersonSettings? = nil
    /// Optional for exact compatibility with recipes written before v21.
    /// Absent or disabled eye & teeth refinement keeps the pre-v21 path.
    public var eyeTeeth: EyeTeethRefinementSettings? = nil
    /// Optional for exact compatibility with recipes written before v22.
    /// Absent or disabled body reshaping & posture refinement keeps the pre-v22 path.
    public var bodyReshape: BodyReshapeSettings? = nil
    /// Optional for exact compatibility with recipes written before v23.
    /// Absent or disabled double eyelid & aegyo sal refinement keeps the pre-v23 path.
    public var eyelidAegyoSal: EyelidAegyoSalSettings? = nil
    /// Optional for exact compatibility with recipes written before v24.
    /// Absent or disabled bokeh blur & depth-of-field synthesis keeps the pre-v24 path.
    public var bokehBlur: BokehBlurSettings? = nil
    /// Optional for exact compatibility with recipes written before v25.
    /// Absent or disabled hair color harmonization & gray hair removal keeps the pre-v25 path.
    public var hairColor: HairColorSettings? = nil
    /// Optional for exact compatibility with recipes written before v26.
    /// Absent or disabled facial hair, peach fuzz removal & mole management keeps the pre-v26 path.
    public var facialHair: FacialHairSettings? = nil
    /// Optional for exact compatibility with recipes written before v27.
    /// Absent or disabled expression, smile & lip shape enhancement keeps the pre-v27 path.
    public var expression: ExpressionSettings? = nil
    /// Optional for exact compatibility with recipes written before v28.
    /// Absent or disabled eye shape reshaping & mid-face balance keeps the pre-v28 path.
    public var eyeShape: EyeShapeSettings? = nil
    /// Optional for exact compatibility with recipes written before v29.
    /// Absent or disabled nose reshaping & 3D bridge contouring keeps the pre-v29 path.
    public var noseReshape: NoseReshapeSettings? = nil
    /// Optional for exact compatibility with recipes written before v30.
    /// Absent or disabled jawline & chin reshaping keeps the pre-v30 path.
    public var jawChinReshape: JawChinReshapeSettings? = nil
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

/// Studio catchlight patterns for iris and pupil reflection.
public enum EyeCatchlightPattern: String, Codable, CaseIterable, Identifiable {
    case off
    case naturalPoint   // 自然单点光 (Natural single round catchlight)
    case ringLight      // 时尚环形光 (Beauty ring light)
    case softboxSquare  // 柔光箱方光 (Studio square softbox)
    case dualStrip      // 双侧条形光 (Dual side strip softbox)
    case butterfly      // 经典蝶形光 (Paramount/butterfly overhead light)
    case starburst      // 璀璨星芒光 (Sparkling starburst)

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .naturalPoint: return "自然单点"
        case .ringLight: return "时尚环形"
        case .softboxSquare: return "方形柔光箱"
        case .dualStrip: return "双侧条形光"
        case .butterfly: return "经典蝶形"
        case .starburst: return "璀璨星芒"
        }
    }
}

/// Settings for P2-N eye catchlight, eyeglass anti-glare, sclera clarity and aesthetic teeth restoration.
public struct EyeTeethRefinementSettings: Codable, Equatable {
    /// Master toggle for eye & teeth refinement.
    public var enabled: Bool = false
    /// Eyeglass glare & white flare reduction (0...1).
    public var eyeglassGlareReduction: Double = 0
    /// Sclera bloodshot removal & yellow haze neutralization (0...1).
    public var scleraBloodshotRemoval: Double = 0
    /// Iris depth, clarity and edge contrast enhancement (0...1).
    public var irisClarity: Double = 0
    /// Catchlight pattern template.
    public var catchlightPattern: EyeCatchlightPattern = .off
    /// Catchlight brightness/opacity strength (0...1).
    public var catchlightStrength: Double = 0
    /// Catchlight relative size scale (0.5...2.0, default 1.0).
    public var catchlightScale: Double = 1.0

    /// Teeth stain, smoke/tea stains, and lip edge smudge cleanup (0...1).
    public var teethStainRemoval: Double = 0
    /// Enamel translucent specular sheen & 3D luster restoration (0...1).
    public var enamelSheen: Double = 0
    /// Gingival pink margin protection factor (0...1, default 0.8).
    public var gingivaProtection: Double = 0.8

    public init(enabled: Bool = false,
                eyeglassGlareReduction: Double = 0,
                scleraBloodshotRemoval: Double = 0,
                irisClarity: Double = 0,
                catchlightPattern: EyeCatchlightPattern = .off,
                catchlightStrength: Double = 0,
                catchlightScale: Double = 1.0,
                teethStainRemoval: Double = 0,
                enamelSheen: Double = 0,
                gingivaProtection: Double = 0.8) {
        self.enabled = enabled
        self.eyeglassGlareReduction = eyeglassGlareReduction
        self.scleraBloodshotRemoval = scleraBloodshotRemoval
        self.irisClarity = irisClarity
        self.catchlightPattern = catchlightPattern
        self.catchlightStrength = catchlightStrength
        self.catchlightScale = catchlightScale
        self.teethStainRemoval = teethStainRemoval
        self.enamelSheen = enamelSheen
        self.gingivaProtection = gingivaProtection
    }

    public var isNeutral: Bool {
        !enabled || (
            eyeglassGlareReduction == 0 &&
            scleraBloodshotRemoval == 0 &&
            irisClarity == 0 &&
            (catchlightPattern == .off || catchlightStrength == 0) &&
            teethStainRemoval == 0 &&
            enamelSheen == 0
        )
    }

    public func validated() throws -> EyeTeethRefinementSettings {
        guard eyeglassGlareReduction.isFinite, (0...1).contains(eyeglassGlareReduction) else {
            throw AtelierError.invalidConfiguration("眼镜去反光强度必须在 0...1 之间。")
        }
        guard scleraBloodshotRemoval.isFinite, (0...1).contains(scleraBloodshotRemoval) else {
            throw AtelierError.invalidConfiguration("眼白去红血丝强度必须在 0...1 之间。")
        }
        guard irisClarity.isFinite, (0...1).contains(irisClarity) else {
            throw AtelierError.invalidConfiguration("虹膜明眸清晰度必须在 0...1 之间。")
        }
        guard catchlightStrength.isFinite, (0...1).contains(catchlightStrength) else {
            throw AtelierError.invalidConfiguration("眼神光叠加强度必须在 0...1 之间。")
        }
        guard catchlightScale.isFinite, (0.5...2.0).contains(catchlightScale) else {
            throw AtelierError.invalidConfiguration("眼神光尺寸缩放必须在 0.5...2.0 之间。")
        }
        guard teethStainRemoval.isFinite, (0...1).contains(teethStainRemoval) else {
            throw AtelierError.invalidConfiguration("牙齿污渍净化强度必须在 0...1 之间。")
        }
        guard enamelSheen.isFinite, (0...1).contains(enamelSheen) else {
            throw AtelierError.invalidConfiguration("珐琅质自然光泽强度必须在 0...1 之间。")
        }
        guard gingivaProtection.isFinite, (0...1).contains(gingivaProtection) else {
            throw AtelierError.invalidConfiguration("牙龈保护系数必须在 0...1 之间。")
        }
        return self
    }
}

/// Report for P2-N eye catchlight, glare reduction, sclera bloodshot removal and aesthetic teeth restoration pass.
public struct EyeTeethRefinementReport: Codable, Equatable {
    public var applied: Bool
    public var faceCount: Int
    public var eyeglassGlareApplied: Bool
    public var scleraBloodshotApplied: Bool
    public var catchlightPattern: EyeCatchlightPattern
    public var teethStainApplied: Bool
    public var note: String?

    public init(applied: Bool,
                faceCount: Int = 0,
                eyeglassGlareApplied: Bool = false,
                scleraBloodshotApplied: Bool = false,
                catchlightPattern: EyeCatchlightPattern = .off,
                teethStainApplied: Bool = false,
                note: String? = nil) {
        self.applied = applied
        self.faceCount = faceCount
        self.eyeglassGlareApplied = eyeglassGlareApplied
        self.scleraBloodshotApplied = scleraBloodshotApplied
        self.catchlightPattern = catchlightPattern
        self.teethStainApplied = teethStainApplied
        self.note = note
    }
}

/// Settings for P2-O smart body reshaping & skeleton posture refinement.
public struct BodyReshapeSettings: Codable, Equatable {
    /// Master toggle for body reshaping. `false` leaves pixels unchanged.
    public var enabled: Bool = false
    /// Swan neck elongation and lateral narrowing (0...1).
    public var swanNeck: Double = 0
    /// Trapezius contraction and right-angle shoulder contouring (0...1).
    public var trapeziusContraction: Double = 0
    /// Overall body slimming and lateral torso reduction (0...1).
    public var bodySlimming: Double = 0
    /// Waist cinching and hourglass curve accentuation (0...1).
    public var waistCinching: Double = 0
    /// Leg lengthening and height proportion stretching (0...1).
    public var legLengthening: Double = 0
    /// Arm slimming and bicep/tricep width contraction (0...1).
    public var armSlimming: Double = 0
    /// Background distortion protection factor (0...1, default 0.8).
    public var backgroundProtection: Double = 0.8

    public init(enabled: Bool = false,
                swanNeck: Double = 0,
                trapeziusContraction: Double = 0,
                bodySlimming: Double = 0,
                waistCinching: Double = 0,
                legLengthening: Double = 0,
                armSlimming: Double = 0,
                backgroundProtection: Double = 0.8) {
        self.enabled = enabled
        self.swanNeck = swanNeck
        self.trapeziusContraction = trapeziusContraction
        self.bodySlimming = bodySlimming
        self.waistCinching = waistCinching
        self.legLengthening = legLengthening
        self.armSlimming = armSlimming
        self.backgroundProtection = backgroundProtection
    }

    public var isNeutral: Bool {
        !enabled || (
            swanNeck == 0 &&
            trapeziusContraction == 0 &&
            bodySlimming == 0 &&
            waistCinching == 0 &&
            legLengthening == 0 &&
            armSlimming == 0
        )
    }

    public func validated() throws -> BodyReshapeSettings {
        guard swanNeck.isFinite, (0...1).contains(swanNeck) else {
            throw AtelierError.invalidConfiguration("天鹅颈强度必须在 0...1 之间。")
        }
        guard trapeziusContraction.isFinite, (0...1).contains(trapeziusContraction) else {
            throw AtelierError.invalidConfiguration("直角肩/斜方肌收敛强度必须在 0...1 之间。")
        }
        guard bodySlimming.isFinite, (0...1).contains(bodySlimming) else {
            throw AtelierError.invalidConfiguration("整体瘦身强度必须在 0...1 之间。")
        }
        guard waistCinching.isFinite, (0...1).contains(waistCinching) else {
            throw AtelierError.invalidConfiguration("细腰收腹强度必须在 0...1 之间。")
        }
        guard legLengthening.isFinite, (0...1).contains(legLengthening) else {
            throw AtelierError.invalidConfiguration("腿部拉长强度必须在 0...1 之间。")
        }
        guard armSlimming.isFinite, (0...1).contains(armSlimming) else {
            throw AtelierError.invalidConfiguration("瘦手臂强度必须在 0...1 之间。")
        }
        guard backgroundProtection.isFinite, (0...1).contains(backgroundProtection) else {
            throw AtelierError.invalidConfiguration("背景保护系数必须在 0...1 之间。")
        }
        return self
    }
}

/// Report for P2-O body reshaping & skeleton posture refinement pass.
public struct BodyReshapeReport: Codable, Equatable {
    public var applied: Bool
    public var skeletonsDetected: Int
    public var note: String?

    public init(applied: Bool,
                skeletonsDetected: Int = 0,
                note: String? = nil) {
        self.applied = applied
        self.skeletonsDetected = skeletonsDetected
        self.note = note
    }
}

/// The four built-in double eyelid crease style patterns.
public enum EyelidStyle: String, Codable, CaseIterable, Identifiable {
    case off
    /// Classic East Asian in-fold / fan-shaped: narrow at inner canthus, widening toward outer canthus.
    case fan
    /// Elegant parallel crease: uniform height from inner to outer canthus.
    case parallel
    /// Crescent crease: highest in the center above the pupil, narrower at corners.
    case crescent
    /// European deep / wide parallel fold: prominent high elevation crease.
    case wide

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "关闭"
        case .fan: return "开扇型"
        case .parallel: return "平行型"
        case .crescent: return "新月型"
        case .wide: return "欧美型"
        }
    }
}

/// Settings for P2-P smart double eyelid sculpting, eyelid tape concealing & aegyo sal / lower lid micro-contouring.
public struct EyelidAegyoSalSettings: Codable, Equatable {
    /// Master toggle for double eyelid and aegyo sal refinement.
    public var enabled: Bool = false
    /// Double eyelid fold style template.
    public var eyelidStyle: EyelidStyle = .off
    /// Double eyelid crease shadow and fold definition strength (0...1).
    public var eyelidStrength: Double = 0
    /// Double eyelid crease relative elevation / height ratio (0.5...2.0, default 1.0).
    public var eyelidHeight: Double = 1.0
    /// Double eyelid fold lateral width extension (0...1, default 0.5).
    public var eyelidWidth: Double = 0.5

    /// Eyelid tape glare suppression, step-edge smoothing & tone blending (0...1).
    public var tapeConceal: Double = 0

    /// Aegyo sal (tear-trough orbicularis roll) highlight luminance (0...1).
    public var aegyoSalLuminance: Double = 0
    /// Aegyo sal lower crease shadow depth (0...1).
    public var aegyoSalShadow: Double = 0
    /// Aegyo sal roll width scale (0.5...1.5, default 1.0).
    public var aegyoSalWidth: Double = 1.0

    public init(enabled: Bool = false,
                eyelidStyle: EyelidStyle = .off,
                eyelidStrength: Double = 0,
                eyelidHeight: Double = 1.0,
                eyelidWidth: Double = 0.5,
                tapeConceal: Double = 0,
                aegyoSalLuminance: Double = 0,
                aegyoSalShadow: Double = 0,
                aegyoSalWidth: Double = 1.0) {
        self.enabled = enabled
        self.eyelidStyle = eyelidStyle
        self.eyelidStrength = eyelidStrength
        self.eyelidHeight = eyelidHeight
        self.eyelidWidth = eyelidWidth
        self.tapeConceal = tapeConceal
        self.aegyoSalLuminance = aegyoSalLuminance
        self.aegyoSalShadow = aegyoSalShadow
        self.aegyoSalWidth = aegyoSalWidth
    }

    public var isNeutral: Bool {
        !enabled || (
            (eyelidStyle == .off || eyelidStrength == 0) &&
            tapeConceal == 0 &&
            aegyoSalLuminance == 0 &&
            aegyoSalShadow == 0
        )
    }

    public func validated() throws -> EyelidAegyoSalSettings {
        guard eyelidStrength.isFinite, (0...1).contains(eyelidStrength) else {
            throw AtelierError.invalidConfiguration("双眼皮强度必须在 0...1 之间。")
        }
        guard eyelidHeight.isFinite, (0.5...2.0).contains(eyelidHeight) else {
            throw AtelierError.invalidConfiguration("双眼皮高度必须在 0.5...2.0 之间。")
        }
        guard eyelidWidth.isFinite, (0...1).contains(eyelidWidth) else {
            throw AtelierError.invalidConfiguration("双眼皮宽度必须在 0...1 之间。")
        }
        guard tapeConceal.isFinite, (0...1).contains(tapeConceal) else {
            throw AtelierError.invalidConfiguration("去双眼皮贴强度必须在 0...1 之间。")
        }
        guard aegyoSalLuminance.isFinite, (0...1).contains(aegyoSalLuminance) else {
            throw AtelierError.invalidConfiguration("卧蚕高光强度必须在 0...1 之间。")
        }
        guard aegyoSalShadow.isFinite, (0...1).contains(aegyoSalShadow) else {
            throw AtelierError.invalidConfiguration("卧蚕阴影强度必须在 0...1 之间。")
        }
        guard aegyoSalWidth.isFinite, (0.5...1.5).contains(aegyoSalWidth) else {
            throw AtelierError.invalidConfiguration("卧蚕宽度必须在 0.5...1.5 之间。")
        }
        return self
    }
}

/// Report for P2-P double eyelid sculpting, tape concealing and aegyo sal refinement pass.
public struct EyelidAegyoSalReport: Codable, Equatable {
    public var applied: Bool
    public var faceCount: Int
    public var eyelidApplied: Bool
    public var tapeConcealApplied: Bool
    public var aegyoSalApplied: Bool
    public var note: String?

    public init(applied: Bool,
                faceCount: Int = 0,
                eyelidApplied: Bool = false,
                tapeConcealApplied: Bool = false,
                aegyoSalApplied: Bool = false,
                note: String? = nil) {
        self.applied = applied
        self.faceCount = faceCount
        self.eyelidApplied = eyelidApplied
        self.tapeConcealApplied = tapeConcealApplied
        self.aegyoSalApplied = aegyoSalApplied
        self.note = note
    }
}

/// Optical diaphragm aperture shapes for bokeh highlights.
public enum BokehShape: String, Codable, CaseIterable, Identifiable {
    /// Modern wide-aperture round disc with spherical aberration edge glow.
    case circular
    /// 9-blade mechanical iris aperture with subtle polygonal facets.
    case polygonal
    /// Vintage Petzval / Helios style peripheral vortex swirl.
    case swirly
    /// Apodization / STF smooth transition creamy bokeh.
    case creamy

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .circular: return "圆形光斑 (现代大光圈)"
        case .polygonal: return "多边形光斑 (复古机械)"
        case .swirly: return "旋焦光斑 (Petzval漩涡)"
        case .creamy: return "柔焦奶化 (STF超平滑)"
        }
    }
}

/// Settings for P2-Q smart bokeh and optical depth-of-field synthesis.
public struct BokehBlurSettings: Codable, Equatable {
    /// Master toggle for bokeh depth of field.
    public var enabled: Bool = false
    /// Lens aperture / defocus blur radius (0...1, maps to 0~50px circle of confusion).
    public var apertureFocalSize: Double = 0
    /// Optical diaphragm aperture bokeh shape.
    public var bokehShape: BokehShape = .circular
    /// Focal plane position offset (-0.5...0.5, default 0: locked on subject).
    public var focalPlaneOffset: Double = 0
    /// Depth falloff gradient rate (0.2...2.0, default 1.0).
    public var depthFalloffRate: Double = 1.0
    /// Specular highlights brightness and optical burst boost (0...1, default 0.5).
    public var specularHighlightBoost: Double = 0.5
    /// Foreground subject edge bleed and fringing protection factor (0...1, default 0.85).
    public var edgeBleedProtection: Double = 0.85

    public init(enabled: Bool = false,
                apertureFocalSize: Double = 0,
                bokehShape: BokehShape = .circular,
                focalPlaneOffset: Double = 0,
                depthFalloffRate: Double = 1.0,
                specularHighlightBoost: Double = 0.5,
                edgeBleedProtection: Double = 0.85) {
        self.enabled = enabled
        self.apertureFocalSize = apertureFocalSize
        self.bokehShape = bokehShape
        self.focalPlaneOffset = focalPlaneOffset
        self.depthFalloffRate = depthFalloffRate
        self.specularHighlightBoost = specularHighlightBoost
        self.edgeBleedProtection = edgeBleedProtection
    }

    public var isNeutral: Bool {
        !enabled || apertureFocalSize == 0
    }

    public func validated() throws -> BokehBlurSettings {
        guard apertureFocalSize.isFinite, (0...1).contains(apertureFocalSize) else {
            throw AtelierError.invalidConfiguration("光圈虚化大小必须在 0...1 之间。")
        }
        guard focalPlaneOffset.isFinite, (-0.5...0.5).contains(focalPlaneOffset) else {
            throw AtelierError.invalidConfiguration("焦平面偏移必须在 -0.5...0.5 之间。")
        }
        guard depthFalloffRate.isFinite, (0.2...2.0).contains(depthFalloffRate) else {
            throw AtelierError.invalidConfiguration("景深过渡速率必须在 0.2...2.0 之间。")
        }
        guard specularHighlightBoost.isFinite, (0...1).contains(specularHighlightBoost) else {
            throw AtelierError.invalidConfiguration("高光光斑爆发度必须在 0...1 之间。")
        }
        guard edgeBleedProtection.isFinite, (0...1).contains(edgeBleedProtection) else {
            throw AtelierError.invalidConfiguration("主体边缘防溢色保护必须在 0...1 之间。")
        }
        return self
    }
}

/// Report for P2-Q bokeh blur and depth-of-field synthesis pass.
public struct BokehBlurReport: Codable, Equatable {
    public var applied: Bool
    public var bokehShape: BokehShape
    public var maxBlurRadius: Double
    public var note: String?

    public init(applied: Bool,
                bokehShape: BokehShape = .circular,
                maxBlurRadius: Double = 0,
                note: String? = nil) {
        self.applied = applied
        self.bokehShape = bokehShape
        self.maxBlurRadius = maxBlurRadius
        self.note = note
    }
}

/// Classic salon hair color tones for P2-R hair recoloring.
public enum HairTone: String, Codable, CaseIterable, Identifiable, Sendable {
    case original        // 保持原色
    case naturalBlack    // 自然黑茶
    case chestnutBrown   // 优雅栗棕
    case mochaDark       // 深摩卡棕
    case burgundyRed     // 醇厚红酒
    case coolLinen       // 冷灰亚麻
    case honeyGold       // 暖蜜金棕

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .original: return "保持原色"
        case .naturalBlack: return "自然黑茶"
        case .chestnutBrown: return "优雅栗棕"
        case .mochaDark: return "深摩卡棕"
        case .burgundyRed: return "醇厚红酒"
        case .coolLinen: return "冷灰亚麻"
        case .honeyGold: return "暖蜜金棕"
        }
    }

    public var toneIndex: Int {
        switch self {
        case .original: return 0
        case .naturalBlack: return 1
        case .chestnutBrown: return 2
        case .mochaDark: return 3
        case .burgundyRed: return 4
        case .coolLinen: return 5
        case .honeyGold: return 6
        }
    }

    public var targetRGB: (r: Double, g: Double, b: Double) {
        switch self {
        case .original: return (0.12, 0.10, 0.08)
        case .naturalBlack: return (0.08, 0.08, 0.09)
        case .chestnutBrown: return (0.38, 0.22, 0.12)
        case .mochaDark: return (0.24, 0.15, 0.10)
        case .burgundyRed: return (0.42, 0.12, 0.16)
        case .coolLinen: return (0.30, 0.28, 0.25)
        case .honeyGold: return (0.48, 0.35, 0.18)
        }
    }
}

/// Settings for P2-R smart hair color harmonization, gray hair removal & recoloring.
public struct HairColorSettings: Codable, Equatable, Sendable {
    /// Master toggle for hair color adjustments.
    public var enabled: Bool = false
    /// Gray / silver hair removal strength (0...1, default 0).
    public var grayHairRemoval: Double = 0
    /// Hair color harmonization strength (0...1, default 0).
    public var hairHarmonization: Double = 0
    /// Target salon hair color tone.
    public var hairTone: HairTone = .original
    /// Target salon hair tone tint strength (0...1, default 0).
    public var hairToneStrength: Double = 0
    /// Hair luminance adjustment (-0.5...0.5, default 0).
    public var hairLuminanceAdjust: Double = 0

    public init(enabled: Bool = false,
                grayHairRemoval: Double = 0,
                hairHarmonization: Double = 0,
                hairTone: HairTone = .original,
                hairToneStrength: Double = 0,
                hairLuminanceAdjust: Double = 0) {
        self.enabled = enabled
        self.grayHairRemoval = max(0.0, min(1.0, grayHairRemoval))
        self.hairHarmonization = max(0.0, min(1.0, hairHarmonization))
        self.hairTone = hairTone
        self.hairToneStrength = max(0.0, min(1.0, hairToneStrength))
        self.hairLuminanceAdjust = max(-0.5, min(0.5, hairLuminanceAdjust))
    }

    public var isNeutral: Bool {
        !enabled || (
            grayHairRemoval <= 0.0001 &&
            hairHarmonization <= 0.0001 &&
            (hairTone == .original || hairToneStrength <= 0.0001) &&
            abs(hairLuminanceAdjust) <= 0.0001
        )
    }

    public func validated() throws -> HairColorSettings {
        guard grayHairRemoval.isFinite, (0...1).contains(grayHairRemoval) else {
            throw AtelierError.invalidConfiguration("去白发强度必须在 0...1 之间。")
        }
        guard hairHarmonization.isFinite, (0...1).contains(hairHarmonization) else {
            throw AtelierError.invalidConfiguration("发色统一强度必须在 0...1 之间。")
        }
        guard hairToneStrength.isFinite, (0...1).contains(hairToneStrength) else {
            throw AtelierError.invalidConfiguration("发色调色强度必须在 0...1 之间。")
        }
        guard hairLuminanceAdjust.isFinite, (-0.5...0.5).contains(hairLuminanceAdjust) else {
            throw AtelierError.invalidConfiguration("发色明度调整必须在 -0.5...0.5 之间。")
        }
        return self
    }
}

/// Report for P2-R hair color harmonization & gray hair removal pass.
public struct HairColorReport: Codable, Equatable, Sendable {
    public var applied: Bool
    public var faceCount: Int
    public var grayHairApplied: Bool
    public var harmonizationApplied: Bool
    public var toneApplied: Bool
    public var note: String?

    public init(applied: Bool,
                faceCount: Int = 0,
                grayHairApplied: Bool = false,
                harmonizationApplied: Bool = false,
                toneApplied: Bool = false,
                note: String? = nil) {
        self.applied = applied
        self.faceCount = faceCount
        self.grayHairApplied = grayHairApplied
        self.harmonizationApplied = harmonizationApplied
        self.toneApplied = toneApplied
        self.note = note
    }
}

/// Mode for P2-S feature mole management.
public enum MoleManagementMode: String, Codable, Sendable, CaseIterable {
    case preserve = "preserve" // 默认保留特征痣
    case soften = "soften"     // 轻度淡化特征痣
    case remove = "remove"     // 完全消除特征痣

    public var localizedName: String {
        switch self {
        case .preserve: return "保留特征痣 (默认)"
        case .soften: return "轻度淡化"
        case .remove: return "完全消除"
        }
    }
}

/// Settings for P2-S smart facial hair, peach fuzz removal, beard shadow softening & feature mole management.
public struct FacialHairSettings: Codable, Equatable, Sendable {
    /// Master toggle for facial hair adjustments.
    public var enabled: Bool = false
    /// Upper lip peach fuzz removal strength (0...1, default 0).
    public var lipFuzzRemoval: Double = 0
    /// Beard shadow reduction / warming strength (0...1, default 0).
    public var beardShadowReduction: Double = 0
    /// Shaven stubble micro-speckle smoothing strength (0...1, default 0).
    public var stubbleSmoothing: Double = 0
    /// Feature mole management mode (.preserve, .soften, .remove).
    public var moleManagement: MoleManagementMode = .preserve
    /// Feature mole softening / removal intensity (0...1, default 0.5).
    public var moleRemovalIntensity: Double = 0.5

    public init(enabled: Bool = false,
                lipFuzzRemoval: Double = 0,
                beardShadowReduction: Double = 0,
                stubbleSmoothing: Double = 0,
                moleManagement: MoleManagementMode = .preserve,
                moleRemovalIntensity: Double = 0.5) {
        self.enabled = enabled
        self.lipFuzzRemoval = max(0.0, min(1.0, lipFuzzRemoval))
        self.beardShadowReduction = max(0.0, min(1.0, beardShadowReduction))
        self.stubbleSmoothing = max(0.0, min(1.0, stubbleSmoothing))
        self.moleManagement = moleManagement
        self.moleRemovalIntensity = max(0.0, min(1.0, moleRemovalIntensity))
    }

    public var isNeutral: Bool {
        !enabled || (
            lipFuzzRemoval <= 0.0001 &&
            beardShadowReduction <= 0.0001 &&
            stubbleSmoothing <= 0.0001 &&
            (moleManagement == .preserve || moleRemovalIntensity <= 0.0001)
        )
    }

    public func validated() throws -> FacialHairSettings {
        guard lipFuzzRemoval.isFinite, (0...1).contains(lipFuzzRemoval) else {
            throw AtelierError.invalidConfiguration("唇毛消除强度必须在 0...1 之间。")
        }
        guard beardShadowReduction.isFinite, (0...1).contains(beardShadowReduction) else {
            throw AtelierError.invalidConfiguration("胡青消除强度必须在 0...1 之间。")
        }
        guard stubbleSmoothing.isFinite, (0...1).contains(stubbleSmoothing) else {
            throw AtelierError.invalidConfiguration("胡茬平滑强度必须在 0...1 之间。")
        }
        guard moleRemovalIntensity.isFinite, (0...1).contains(moleRemovalIntensity) else {
            throw AtelierError.invalidConfiguration("特征痣处理强度必须在 0...1 之间。")
        }
        return self
    }
}

/// Report for P2-S facial hair, beard shadow & feature mole management pass.
public struct FacialHairReport: Codable, Equatable, Sendable {
    public var applied: Bool
    public var faceCount: Int
    public var lipFuzzApplied: Bool
    public var beardShadowApplied: Bool
    public var stubbleApplied: Bool
    public var moleApplied: Bool
    public var note: String?

    public init(applied: Bool,
                faceCount: Int = 0,
                lipFuzzApplied: Bool = false,
                beardShadowApplied: Bool = false,
                stubbleApplied: Bool = false,
                moleApplied: Bool = false,
                note: String? = nil) {
        self.applied = applied
        self.faceCount = faceCount
        self.lipFuzzApplied = lipFuzzApplied
        self.beardShadowApplied = beardShadowApplied
        self.stubbleApplied = stubbleApplied
        self.moleApplied = moleApplied
        self.note = note
    }
}

/// Settings for P2-T smart facial micro-expression, smile uplift & lip shape 3D enhancement.
public struct ExpressionSettings: Codable, Equatable, Sendable {
    /// Master toggle for expression & smile adjustments.
    public var enabled: Bool = false
    /// Smile degree / lip corner uplift (0...1, default 0).
    public var smileDegree: Double = 0
    /// Smile width modulation (-0.5...0.5, default 0).
    public var smileWidth: Double = 0
    /// Lip corner symmetry harmonization (0...1, default 0).
    public var lipSymmetry: Double = 0
    /// Philtrum shortening (0...1, default 0).
    public var philtrumShortening: Double = 0
    /// Upper lip plumping fullness (-0.5...0.5, default 0).
    public var upperLipPlump: Double = 0
    /// Lower lip plumping fullness (-0.5...0.5, default 0).
    public var lowerLipPlump: Double = 0
    /// 3D vermilion highlight and micro-shading (0...1, default 0).
    public var lip3DHighlight: Double = 0

    public init(enabled: Bool = false,
                smileDegree: Double = 0,
                smileWidth: Double = 0,
                lipSymmetry: Double = 0,
                philtrumShortening: Double = 0,
                upperLipPlump: Double = 0,
                lowerLipPlump: Double = 0,
                lip3DHighlight: Double = 0) {
        self.enabled = enabled
        self.smileDegree = max(0.0, min(1.0, smileDegree))
        self.smileWidth = max(-0.5, min(0.5, smileWidth))
        self.lipSymmetry = max(0.0, min(1.0, lipSymmetry))
        self.philtrumShortening = max(0.0, min(1.0, philtrumShortening))
        self.upperLipPlump = max(-0.5, min(0.5, upperLipPlump))
        self.lowerLipPlump = max(-0.5, min(0.5, lowerLipPlump))
        self.lip3DHighlight = max(0.0, min(1.0, lip3DHighlight))
    }

    public var isNeutral: Bool {
        !enabled || (
            smileDegree <= 0.0001 &&
            abs(smileWidth) <= 0.0001 &&
            lipSymmetry <= 0.0001 &&
            philtrumShortening <= 0.0001 &&
            abs(upperLipPlump) <= 0.0001 &&
            abs(lowerLipPlump) <= 0.0001 &&
            lip3DHighlight <= 0.0001
        )
    }

    public func validated() throws -> ExpressionSettings {
        guard smileDegree.isFinite, (0...1).contains(smileDegree) else {
            throw AtelierError.invalidConfiguration("微笑嘴角上扬程度必须在 0...1 之间。")
        }
        guard smileWidth.isFinite, (-0.5...0.5).contains(smileWidth) else {
            throw AtelierError.invalidConfiguration("微笑宽度必须在 -0.5...0.5 之间。")
        }
        guard lipSymmetry.isFinite, (0...1).contains(lipSymmetry) else {
            throw AtelierError.invalidConfiguration("唇角对称性校准必须在 0...1 之间。")
        }
        guard philtrumShortening.isFinite, (0...1).contains(philtrumShortening) else {
            throw AtelierError.invalidConfiguration("幼态人中缩短程度必须在 0...1 之间。")
        }
        guard upperLipPlump.isFinite, (-0.5...0.5).contains(upperLipPlump) else {
            throw AtelierError.invalidConfiguration("上唇丰满程度必须在 -0.5...0.5 之间。")
        }
        guard lowerLipPlump.isFinite, (-0.5...0.5).contains(lowerLipPlump) else {
            throw AtelierError.invalidConfiguration("下唇丰满程度必须在 -0.5...0.5 之间。")
        }
        guard lip3DHighlight.isFinite, (0...1).contains(lip3DHighlight) else {
            throw AtelierError.invalidConfiguration("唇峰珠光高光与立体阴影强度必须在 0...1 之间。")
        }
        return self
    }
}

/// Report for P2-T facial micro-expression, smile & lip shape enhancement pass.
public struct ExpressionReport: Codable, Equatable, Sendable {
    public var applied: Bool
    public var faceCount: Int
    public var averageSmileAdjustment: Double
    public var averagePlumpAdjustment: Double
    public var philtrumShortenedFaces: Int
    public var processingTimeMs: Double
    public var note: String?

    public init(applied: Bool = false,
                faceCount: Int = 0,
                averageSmileAdjustment: Double = 0,
                averagePlumpAdjustment: Double = 0,
                philtrumShortenedFaces: Int = 0,
                processingTimeMs: Double = 0,
                note: String? = nil) {
        self.applied = applied
        self.faceCount = faceCount
        self.averageSmileAdjustment = averageSmileAdjustment
        self.averagePlumpAdjustment = averagePlumpAdjustment
        self.philtrumShortenedFaces = philtrumShortenedFaces
        self.processingTimeMs = processingTimeMs
        self.note = note
    }
}

/// Settings for P2-U smart eye shape reshaping, canthoplasty & mid-face proportion balancing.
public struct EyeShapeSettings: Codable, Equatable, Sendable {
    /// Master toggle for eye shape adjustments.
    public var enabled: Bool = false
    /// Inner canthoplasty / 开内眼角 (0...1, default 0).
    public var innerCanthoplasty: Double = 0
    /// Outer canthoplasty & lower lid drop / 开外眼角与眼尾下至 (0...1, default 0).
    public var outerCanthoplasty: Double = 0
    /// Eye roundness vs almond/cat eye / 眼型圆润/猫眼微调 (-0.5...0.5, default 0).
    public var eyeRoundness: Double = 0
    /// Eye tilt / 眼位倾斜与走势校准 (-0.5...0.5, default 0).
    public var eyeTilt: Double = 0
    /// Interpupillary distance / 眼距微调 (-0.5...0.5, default 0).
    public var interpupillaryDistance: Double = 0
    /// Eye vertical position & mid-face balance / 眼位垂直微调与中庭比例缩短 (-0.5...0.5, default 0).
    public var eyeVerticalPosition: Double = 0
    /// Eye size and horizontal symmetry harmonization / 双眼大小与水平对称性校准 (0...1, default 0).
    public var eyeSymmetry: Double = 0

    public init(enabled: Bool = false,
                innerCanthoplasty: Double = 0,
                outerCanthoplasty: Double = 0,
                eyeRoundness: Double = 0,
                eyeTilt: Double = 0,
                interpupillaryDistance: Double = 0,
                eyeVerticalPosition: Double = 0,
                eyeSymmetry: Double = 0) {
        self.enabled = enabled
        self.innerCanthoplasty = max(0.0, min(1.0, innerCanthoplasty))
        self.outerCanthoplasty = max(0.0, min(1.0, outerCanthoplasty))
        self.eyeRoundness = max(-0.5, min(0.5, eyeRoundness))
        self.eyeTilt = max(-0.5, min(0.5, eyeTilt))
        self.interpupillaryDistance = max(-0.5, min(0.5, interpupillaryDistance))
        self.eyeVerticalPosition = max(-0.5, min(0.5, eyeVerticalPosition))
        self.eyeSymmetry = max(0.0, min(1.0, eyeSymmetry))
    }

    public var isNeutral: Bool {
        !enabled || (
            innerCanthoplasty <= 0.0001 &&
            outerCanthoplasty <= 0.0001 &&
            abs(eyeRoundness) <= 0.0001 &&
            abs(eyeTilt) <= 0.0001 &&
            abs(interpupillaryDistance) <= 0.0001 &&
            abs(eyeVerticalPosition) <= 0.0001 &&
            eyeSymmetry <= 0.0001
        )
    }

    public func validated() throws -> EyeShapeSettings {
        guard innerCanthoplasty.isFinite, (0...1).contains(innerCanthoplasty) else {
            throw AtelierError.invalidConfiguration("开内眼角程度必须在 0...1 之间。")
        }
        guard outerCanthoplasty.isFinite, (0...1).contains(outerCanthoplasty) else {
            throw AtelierError.invalidConfiguration("开外眼角程度必须在 0...1 之间。")
        }
        guard eyeRoundness.isFinite, (-0.5...0.5).contains(eyeRoundness) else {
            throw AtelierError.invalidConfiguration("眼型圆润度调节必须在 -0.5...0.5 之间。")
        }
        guard eyeTilt.isFinite, (-0.5...0.5).contains(eyeTilt) else {
            throw AtelierError.invalidConfiguration("眼位倾斜校准必须在 -0.5...0.5 之间。")
        }
        guard interpupillaryDistance.isFinite, (-0.5...0.5).contains(interpupillaryDistance) else {
            throw AtelierError.invalidConfiguration("眼距微调必须在 -0.5...0.5 之间。")
        }
        guard eyeVerticalPosition.isFinite, (-0.5...0.5).contains(eyeVerticalPosition) else {
            throw AtelierError.invalidConfiguration("眼位垂直与中庭微调必须在 -0.5...0.5 之间。")
        }
        guard eyeSymmetry.isFinite, (0...1).contains(eyeSymmetry) else {
            throw AtelierError.invalidConfiguration("双眼对称性校准必须在 0...1 之间。")
        }
        return self
    }
}

/// Report for P2-U smart eye shape reshaping, canthoplasty & mid-face proportion balancing pass.
public struct EyeShapeReport: Codable, Equatable, Sendable {
    public var applied: Bool
    public var faceCount: Int
    public var averageCanthoplasty: Double
    public var averageRoundness: Double
    public var averageTilt: Double
    public var processingTimeMs: Double
    public var note: String?

    public init(applied: Bool = false,
                faceCount: Int = 0,
                averageCanthoplasty: Double = 0,
                averageRoundness: Double = 0,
                averageTilt: Double = 0,
                processingTimeMs: Double = 0,
                note: String? = nil) {
        self.applied = applied
        self.faceCount = faceCount
        self.averageCanthoplasty = averageCanthoplasty
        self.averageRoundness = averageRoundness
        self.averageTilt = averageTilt
        self.processingTimeMs = processingTimeMs
        self.note = note
    }
}

/// Settings for P2-V smart nose reshaping, 3D bridge contouring & structural correction.
public struct NoseReshapeSettings: Codable, Equatable, Sendable {
    /// Master toggle for nose reshaping adjustments.
    public var enabled: Bool = false
    /// Narrow nose wings / 鼻翼收窄与精雕 (-0.5...0.5, default 0).
    public var narrowNoseWing: Double = 0
    /// Nose tip size / 鼻头立体微缩与塑形 (-0.5...0.5, default 0).
    public var noseTipSize: Double = 0
    /// Nose bridge width / 鼻梁挺拔度与骨骼收窄 (-0.5...0.5, default 0).
    public var noseBridgeWidth: Double = 0
    /// Nose pitch angle / 鼻唇角与仰俯角调节 (-0.5...0.5, default 0).
    public var nosePitchAngle: Double = 0
    /// Dorsal hump smoothing / 驼峰鼻背平缓抚平 (0...1, default 0).
    public var humpSmoothing: Double = 0
    /// Nose length modulation / 鼻长调节与中庭平衡 (-0.5...0.5, default 0).
    public var noseLength: Double = 0
    /// 3D dorsal highlight & sidewall micro-shading / 鼻梁立体高光与双侧修容 (0...1, default 0).
    public var nose3DContour: Double = 0

    public init(enabled: Bool = false,
                narrowNoseWing: Double = 0,
                noseTipSize: Double = 0,
                noseBridgeWidth: Double = 0,
                nosePitchAngle: Double = 0,
                humpSmoothing: Double = 0,
                noseLength: Double = 0,
                nose3DContour: Double = 0) {
        self.enabled = enabled
        self.narrowNoseWing = max(-0.5, min(0.5, narrowNoseWing))
        self.noseTipSize = max(-0.5, min(0.5, noseTipSize))
        self.noseBridgeWidth = max(-0.5, min(0.5, noseBridgeWidth))
        self.nosePitchAngle = max(-0.5, min(0.5, nosePitchAngle))
        self.humpSmoothing = max(0.0, min(1.0, humpSmoothing))
        self.noseLength = max(-0.5, min(0.5, noseLength))
        self.nose3DContour = max(0.0, min(1.0, nose3DContour))
    }

    public var isNeutral: Bool {
        !enabled || (
            abs(narrowNoseWing) <= 0.0001 &&
            abs(noseTipSize) <= 0.0001 &&
            abs(noseBridgeWidth) <= 0.0001 &&
            abs(nosePitchAngle) <= 0.0001 &&
            humpSmoothing <= 0.0001 &&
            abs(noseLength) <= 0.0001 &&
            nose3DContour <= 0.0001
        )
    }

    public func validated() throws -> NoseReshapeSettings {
        guard narrowNoseWing.isFinite, (-0.5...0.5).contains(narrowNoseWing) else {
            throw AtelierError.invalidConfiguration("鼻翼收窄程度必须在 -0.5...0.5 之间。")
        }
        guard noseTipSize.isFinite, (-0.5...0.5).contains(noseTipSize) else {
            throw AtelierError.invalidConfiguration("鼻头大小微调必须在 -0.5...0.5 之间。")
        }
        guard noseBridgeWidth.isFinite, (-0.5...0.5).contains(noseBridgeWidth) else {
            throw AtelierError.invalidConfiguration("鼻梁宽度调节必须在 -0.5...0.5 之间。")
        }
        guard nosePitchAngle.isFinite, (-0.5...0.5).contains(nosePitchAngle) else {
            throw AtelierError.invalidConfiguration("鼻尖仰俯角调节必须在 -0.5...0.5 之间。")
        }
        guard humpSmoothing.isFinite, (0...1).contains(humpSmoothing) else {
            throw AtelierError.invalidConfiguration("驼峰抚平强度必须在 0...1 之间。")
        }
        guard noseLength.isFinite, (-0.5...0.5).contains(noseLength) else {
            throw AtelierError.invalidConfiguration("鼻长微调程度必须在 -0.5...0.5 之间。")
        }
        guard nose3DContour.isFinite, (0...1).contains(nose3DContour) else {
            throw AtelierError.invalidConfiguration("鼻梁立体高光与修容强度必须在 0...1 之间。")
        }
        return self
    }
}

/// Report for P2-V smart nose reshaping, 3D bridge contouring & structural correction pass.
public struct NoseReshapeReport: Codable, Equatable, Sendable {
    public var applied: Bool
    public var faceCount: Int
    public var averageNoseWingAdjustment: Double
    public var averageBridgeAdjustment: Double
    public var humpSmoothedFaces: Int
    public var processingTimeMs: Double
    public var note: String?

    public init(applied: Bool = false,
                faceCount: Int = 0,
                averageNoseWingAdjustment: Double = 0,
                averageBridgeAdjustment: Double = 0,
                humpSmoothedFaces: Int = 0,
                processingTimeMs: Double = 0,
                note: String? = nil) {
        self.applied = applied
        self.faceCount = faceCount
        self.averageNoseWingAdjustment = averageNoseWingAdjustment
        self.averageBridgeAdjustment = averageBridgeAdjustment
        self.humpSmoothedFaces = humpSmoothedFaces
        self.processingTimeMs = processingTimeMs
        self.note = note
    }
}

/// Settings for P2-W smart jawline sculpting, chin reshaping & lower-face proportions.
public struct JawChinReshapeSettings: Codable, Equatable, Sendable {
    /// Master toggle for jaw & chin reshaping adjustments.
    public var enabled: Bool = false
    /// Narrow or broaden jaw angles & gonial width / 下颌角收窄与折角微雕 (-0.5...0.5, default 0).
    public var jawWidth: Double = 0
    /// Chin length modulation / 下巴长度调节与下庭平衡 (-0.5...0.5, default 0).
    public var chinLength: Double = 0
    /// Chin forward projection & perkiness / 下巴翘度微调（解决下巴后缩） (-0.5...0.5, default 0).
    public var chinProjection: Double = 0
    /// Chin shape sculpting / 下巴形态微雕（圆幼下巴 vs 精致V脸） (-0.5...0.5, default 0).
    public var chinShape: Double = 0
    /// Mandibular jawline tightening / 下颌缘紧致与线条清晰度 (0...1, default 0).
    public var jawlineTighten: Double = 0
    /// Chin 3D specular highlight & submental micro-shading / 下巴微光立体修容 (0...1, default 0).
    public var chinContour: Double = 0

    public init(enabled: Bool = false,
                jawWidth: Double = 0,
                chinLength: Double = 0,
                chinProjection: Double = 0,
                chinShape: Double = 0,
                jawlineTighten: Double = 0,
                chinContour: Double = 0) {
        self.enabled = enabled
        self.jawWidth = max(-0.5, min(0.5, jawWidth))
        self.chinLength = max(-0.5, min(0.5, chinLength))
        self.chinProjection = max(-0.5, min(0.5, chinProjection))
        self.chinShape = max(-0.5, min(0.5, chinShape))
        self.jawlineTighten = max(0.0, min(1.0, jawlineTighten))
        self.chinContour = max(0.0, min(1.0, chinContour))
    }

    public var isNeutral: Bool {
        !enabled || (
            abs(jawWidth) <= 0.0001 &&
            abs(chinLength) <= 0.0001 &&
            abs(chinProjection) <= 0.0001 &&
            abs(chinShape) <= 0.0001 &&
            jawlineTighten <= 0.0001 &&
            chinContour <= 0.0001
        )
    }

    public func validated() throws -> JawChinReshapeSettings {
        guard jawWidth.isFinite, (-0.5...0.5).contains(jawWidth) else {
            throw AtelierError.invalidConfiguration("下颌角收窄调节程度必须在 -0.5...0.5 之间。")
        }
        guard chinLength.isFinite, (-0.5...0.5).contains(chinLength) else {
            throw AtelierError.invalidConfiguration("下巴长度调节程度必须在 -0.5...0.5 之间。")
        }
        guard chinProjection.isFinite, (-0.5...0.5).contains(chinProjection) else {
            throw AtelierError.invalidConfiguration("下巴翘度微调程度必须在 -0.5...0.5 之间。")
        }
        guard chinShape.isFinite, (-0.5...0.5).contains(chinShape) else {
            throw AtelierError.invalidConfiguration("下巴形态微雕程度必须在 -0.5...0.5 之间。")
        }
        guard jawlineTighten.isFinite, (0...1).contains(jawlineTighten) else {
            throw AtelierError.invalidConfiguration("下颌缘紧致强度必须在 0...1 之间。")
        }
        guard chinContour.isFinite, (0...1).contains(chinContour) else {
            throw AtelierError.invalidConfiguration("下巴立体高光与修容强度必须在 0...1 之间。")
        }
        return self
    }
}

/// Report for P2-W smart jawline sculpting, chin reshaping & lower-face proportions pass.
public struct JawChinReshapeReport: Codable, Equatable, Sendable {
    public var applied: Bool
    public var faceCount: Int
    public var executionTime: Double?
    public var note: String?

    public init(applied: Bool = false,
                faceCount: Int = 0,
                executionTime: Double? = nil,
                note: String? = nil) {
        self.applied = applied
        self.faceCount = faceCount
        self.executionTime = executionTime
        self.note = note
    }
}

/// Settings for P2-I smart pet enhancement (fur fluffiness, eye brightening, muzzle moisture, coat dehaze, coat whiten).
public struct PetEnhancementSettings: Codable, Equatable {
    /// Master toggle for pet enhancement. `false` leaves pixels unchanged.
    public var enabled: Bool = false
    /// Fur fluffiness & micro-contrast enhancement (0...1, default 0).
    public var furFluffiness: Double = 0
    /// Pet eye brightening and catchlight sparkle (0...1, default 0).
    public var eyeBrightening: Double = 0
    /// Pet muzzle/snout moisture & depth enhancement (0...1, default 0).
    public var muzzleMoisture: Double = 0
    /// Coat dehaze & rich natural color purity (0...1, default 0).
    public var coatDehaze: Double = 0
    /// White & pale fur whitening / yellow-stain removal (0...1, default 0).
    public var coatWhiten: Double = 0
    /// Fine fur texture preservation (0...1, default 0.70).
    public var texturePreservation: Double = 0.70

    public init(enabled: Bool = false,
                furFluffiness: Double = 0,
                eyeBrightening: Double = 0,
                muzzleMoisture: Double = 0,
                coatDehaze: Double = 0,
                coatWhiten: Double = 0,
                texturePreservation: Double = 0.70) {
        self.enabled = enabled
        self.furFluffiness = furFluffiness
        self.eyeBrightening = eyeBrightening
        self.muzzleMoisture = muzzleMoisture
        self.coatDehaze = coatDehaze
        self.coatWhiten = coatWhiten
        self.texturePreservation = texturePreservation
    }

    public var isNeutral: Bool {
        !enabled || (furFluffiness == 0 && eyeBrightening == 0 && muzzleMoisture == 0 && coatDehaze == 0 && coatWhiten == 0)
    }

    public func validated() throws -> PetEnhancementSettings {
        guard furFluffiness.isFinite, (0...1).contains(furFluffiness) else {
            throw AtelierError.invalidConfiguration("毛发蓬松度必须在 0...1 之间。")
        }
        guard eyeBrightening.isFinite, (0...1).contains(eyeBrightening) else {
            throw AtelierError.invalidConfiguration("宠物明眸提亮必须在 0...1 之间。")
        }
        guard muzzleMoisture.isFinite, (0...1).contains(muzzleMoisture) else {
            throw AtelierError.invalidConfiguration("鼻吻润泽度必须在 0...1 之间。")
        }
        guard coatDehaze.isFinite, (0...1).contains(coatDehaze) else {
            throw AtelierError.invalidConfiguration("毛发去灰提纯度必须在 0...1 之间。")
        }
        guard coatWhiten.isFinite, (0...1).contains(coatWhiten) else {
            throw AtelierError.invalidConfiguration("白毛去黄必须在 0...1 之间。")
        }
        guard texturePreservation.isFinite, (0...1).contains(texturePreservation) else {
            throw AtelierError.invalidConfiguration("毛发肌理保护必须在 0...1 之间。")
        }
        return self
    }
}

/// Per-photo record of the P2-I pet enhancement stage.
public struct PetEnhancementReport: Codable, Equatable {
    public var applied: Bool
    public var petCount: Int
    public var appliedSteps: [String]
    public var note: String?

    public init(applied: Bool = false, petCount: Int = 0, appliedSteps: [String] = [], note: String? = nil) {
        self.applied = applied
        self.petCount = petCount
        self.appliedSteps = appliedSteps
        self.note = note
    }
}

/// Atmospheric procedural sky preset styles for P2-J.
public enum SkyPreset: String, Codable, CaseIterable, Identifiable {
    case none
    case azureClear
    case sunsetGlow
    case twilightLilac
    case dramaticClouds
    case morningDawn

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "原图天空（仅增强）"
        case .azureClear: return "湛蓝晴空"
        case .sunsetGlow: return "日落晚霞"
        case .twilightLilac: return "暮光紫霞"
        case .dramaticClouds: return "戏剧阴云"
        case .morningDawn: return "柔光晨曦"
        }
    }
}

/// Settings for P2-J smart sky detection, atmospheric relighting and replacement.
public struct SkyEnhancementSettings: Codable, Equatable {
    /// Master toggle for sky enhancement. `false` leaves pixels unchanged.
    public var enabled: Bool = false
    /// Sky vibrance & azure depth enhancement (0...1, default 0).
    public var skyVibrance: Double = 0
    /// Cloud structure & contrast enhancement (0...1, default 0).
    public var cloudContrast: Double = 0
    /// Sunset & golden hour atmospheric warmth (0...1, default 0).
    public var sunsetWarmth: Double = 0
    /// Procedural atmospheric sky preset replacement (default: .none).
    public var skyPreset: SkyPreset = .none
    /// Sky replacement opacity / blend strength (0...1, default 0.80).
    public var replacementOpacity: Double = 0.80
    /// Ambient light transfer onto foreground subject (0...1, default 0.35).
    public var foregroundRelight: Double = 0.35
    /// Horizon edge feathering & halo suppression (0...1, default 0.50).
    public var edgeFeather: Double = 0.50

    public init(enabled: Bool = false,
                skyVibrance: Double = 0,
                cloudContrast: Double = 0,
                sunsetWarmth: Double = 0,
                skyPreset: SkyPreset = .none,
                replacementOpacity: Double = 0.80,
                foregroundRelight: Double = 0.35,
                edgeFeather: Double = 0.50) {
        self.enabled = enabled
        self.skyVibrance = skyVibrance
        self.cloudContrast = cloudContrast
        self.sunsetWarmth = sunsetWarmth
        self.skyPreset = skyPreset
        self.replacementOpacity = replacementOpacity
        self.foregroundRelight = foregroundRelight
        self.edgeFeather = edgeFeather
    }

    public var isNeutral: Bool {
        !enabled || (skyVibrance == 0 && cloudContrast == 0 && sunsetWarmth == 0 && skyPreset == .none)
    }

    public func validated() throws -> SkyEnhancementSettings {
        guard skyVibrance.isFinite, (0...1).contains(skyVibrance) else {
            throw AtelierError.invalidConfiguration("天空湛蓝度必须在 0...1 之间。")
        }
        guard cloudContrast.isFinite, (0...1).contains(cloudContrast) else {
            throw AtelierError.invalidConfiguration("云层反差必须在 0...1 之间。")
        }
        guard sunsetWarmth.isFinite, (0...1).contains(sunsetWarmth) else {
            throw AtelierError.invalidConfiguration("晚霞氛围必须在 0...1 之间。")
        }
        guard replacementOpacity.isFinite, (0...1).contains(replacementOpacity) else {
            throw AtelierError.invalidConfiguration("天空置换不透明度必须在 0...1 之间。")
        }
        guard foregroundRelight.isFinite, (0...1).contains(foregroundRelight) else {
            throw AtelierError.invalidConfiguration("前景光照匹配必须在 0...1 之间。")
        }
        guard edgeFeather.isFinite, (0...1).contains(edgeFeather) else {
            throw AtelierError.invalidConfiguration("边缘羽化必须在 0...1 之间。")
        }
        return self
    }
}

/// Per-photo record of the P2-J sky enhancement stage.
public struct SkyEnhancementReport: Codable, Equatable {
    public var applied: Bool
    public var hasSkyDetected: Bool
    public var appliedSteps: [String]
    public var note: String?

    public init(applied: Bool = false, hasSkyDetected: Bool = false, appliedSteps: [String] = [], note: String? = nil) {
        self.applied = applied
        self.hasSkyDetected = hasSkyDetected
        self.appliedSteps = appliedSteps
        self.note = note
    }
}

// MARK: - P2-M Multi-Person Face Identification, Demographic Grouping & Profiles

/// Studio demographic roles for multi-person group retouching.
public enum PersonDemographicRole: String, Codable, CaseIterable, Identifiable {
    /// Female adult / bride (high smoothing, makeup enabled, rosiness).
    case femaleAdult = "femaleAdult"
    /// Male adult / groom (stubble & bone structure preservation, conservative smoothing, zero makeup).
    case maleAdult = "maleAdult"
    /// Child / infant (delicate skin protection, ultra-low smoothing, zero blemish removal, zero makeup).
    case child = "child"
    /// Senior / elder (age texture preservation, gentle blemish/age spot reduction, zero plastic finish).
    case elder = "elder"
    /// Unassigned / general default.
    case unassigned = "unassigned"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .femaleAdult: return "女性 / 新娘"
        case .maleAdult: return "男性 / 新郎"
        case .child: return "儿童 / 婴儿"
        case .elder: return "长辈 / 老人"
        case .unassigned: return "通用 / 未指定"
        }
    }

    public var icon: String {
        switch self {
        case .femaleAdult: return "person.crop.circle.badge.checkmark"
        case .maleAdult: return "person.crop.circle"
        case .child: return "figure.child"
        case .elder: return "figure.walk"
        case .unassigned: return "person"
        }
    }
}

/// Profile containing independent portrait, makeup and facial zonal overrides for a specific person or role.
public struct PersonPortraitProfile: Identifiable, Codable, Equatable {
    public var id: UUID
    /// Target detected face index (0, 1, 2...) or `nil` if this profile is a demographic role template.
    public var faceIndex: Int?
    /// Assigned demographic role.
    public var role: PersonDemographicRole
    /// Master toggle for this specific person's overrides.
    public var enabled: Bool
    /// Independent portrait retouch override (smoothing, blemish, teeth, eyes).
    public var portraitOverride: PortraitRefinementSettings?
    /// Independent makeup override (lips, blush, brows, eyes).
    public var makeupOverride: MakeupSettings?
    /// Independent facial zonal override (wrinkles, dark circles, eye bags, anti-shine).
    public var facialZonalOverride: FacialZonalRefinementSettings?
    /// Independent eye & teeth aesthetic refinement override.
    public var eyeTeethOverride: EyeTeethRefinementSettings?
    /// Independent body reshaping & posture refinement override.
    public var bodyReshapeOverride: BodyReshapeSettings?
    /// Independent double eyelid & aegyo sal refinement override.
    public var eyelidAegyoSalOverride: EyelidAegyoSalSettings?
    /// Independent hair color harmonization & gray hair removal override.
    public var hairColorOverride: HairColorSettings?
    /// Independent facial hair, peach fuzz removal & mole management override.
    public var facialHairOverride: FacialHairSettings?
    /// Independent facial micro-expression, smile & lip shape enhancement override.
    public var expressionOverride: ExpressionSettings?
    /// Independent eye shape reshaping, canthoplasty & mid-face proportion balance override.
    public var eyeShapeOverride: EyeShapeSettings?
    /// Independent nose reshaping, 3D bridge contouring & structural correction override.
    public var noseReshapeOverride: NoseReshapeSettings?
    /// Independent jawline sculpting, chin reshaping & lower-face proportions override.
    public var jawChinReshapeOverride: JawChinReshapeSettings?

    public init(id: UUID = UUID(),
                faceIndex: Int? = nil,
                role: PersonDemographicRole = .unassigned,
                enabled: Bool = true,
                portraitOverride: PortraitRefinementSettings? = nil,
                makeupOverride: MakeupSettings? = nil,
                facialZonalOverride: FacialZonalRefinementSettings? = nil,
                eyeTeethOverride: EyeTeethRefinementSettings? = nil,
                bodyReshapeOverride: BodyReshapeSettings? = nil,
                eyelidAegyoSalOverride: EyelidAegyoSalSettings? = nil,
                hairColorOverride: HairColorSettings? = nil,
                facialHairOverride: FacialHairSettings? = nil,
                expressionOverride: ExpressionSettings? = nil,
                eyeShapeOverride: EyeShapeSettings? = nil,
                noseReshapeOverride: NoseReshapeSettings? = nil,
                jawChinReshapeOverride: JawChinReshapeSettings? = nil) {
        self.id = id
        self.faceIndex = faceIndex
        self.role = role
        self.enabled = enabled
        self.portraitOverride = portraitOverride
        self.makeupOverride = makeupOverride
        self.facialZonalOverride = facialZonalOverride
        self.eyeTeethOverride = eyeTeethOverride
        self.bodyReshapeOverride = bodyReshapeOverride
        self.eyelidAegyoSalOverride = eyelidAegyoSalOverride
        self.hairColorOverride = hairColorOverride
        self.facialHairOverride = facialHairOverride
        self.expressionOverride = expressionOverride
        self.eyeShapeOverride = eyeShapeOverride
        self.noseReshapeOverride = noseReshapeOverride
        self.jawChinReshapeOverride = jawChinReshapeOverride
    }

    public var isNeutral: Bool {
        (!enabled) || (
            (portraitOverride == nil || portraitOverride!.isNeutral) &&
            (makeupOverride == nil || makeupOverride!.isNeutral) &&
            (facialZonalOverride == nil || facialZonalOverride!.isNeutral) &&
            (eyeTeethOverride == nil || eyeTeethOverride!.isNeutral) &&
            (bodyReshapeOverride == nil || bodyReshapeOverride!.isNeutral) &&
            (eyelidAegyoSalOverride == nil || eyelidAegyoSalOverride!.isNeutral) &&
            (hairColorOverride == nil || hairColorOverride!.isNeutral) &&
            (facialHairOverride == nil || facialHairOverride!.isNeutral) &&
            (expressionOverride == nil || expressionOverride!.isNeutral) &&
            (eyeShapeOverride == nil || eyeShapeOverride!.isNeutral) &&
            (noseReshapeOverride == nil || noseReshapeOverride!.isNeutral) &&
            (jawChinReshapeOverride == nil || jawChinReshapeOverride!.isNeutral)
        )
    }

    /// Default profile for a given demographic role.
    public static func defaultProfile(for role: PersonDemographicRole) -> PersonPortraitProfile {
        switch role {
        case .femaleAdult:
            return PersonPortraitProfile(
                role: .femaleAdult,
                portraitOverride: PortraitRefinementSettings(
                    blemishStrength: 0.60, keepSpots: false,
                    dodgeBurn: 0.45, structure: 0.20, texture: 0.35,
                    gloss: 0.30, teethWhiten: 0.35, eyeBrighten: 0.25
                ),
                makeupOverride: MakeupSettings(
                    lipIntensity: 0.40, browDensity: 0.25,
                    cheekIntensity: 0.30, eyeshadowIntensity: 0.20
                ),
                facialZonalOverride: FacialZonalRefinementSettings(
                    enabled: true,
                    darkCircles: 0.50,
                    eyeBags: 0.45,
                    nasolabialFolds: 0.45,
                    antiShine: 0.35
                ),
                eyeTeethOverride: EyeTeethRefinementSettings(
                    enabled: true,
                    scleraBloodshotRemoval: 0.35,
                    irisClarity: 0.30,
                    catchlightPattern: .ringLight,
                    catchlightStrength: 0.40,
                    teethStainRemoval: 0.30,
                    enamelSheen: 0.35
                )
            )
        case .maleAdult:
            return PersonPortraitProfile(
                role: .maleAdult,
                portraitOverride: PortraitRefinementSettings(
                    blemishStrength: 0.40, keepSpots: true,
                    dodgeBurn: 0.20, structure: 0.35, texture: 0.50,
                    gloss: 0.40, teethWhiten: 0.25, eyeBrighten: 0.15
                ),
                makeupOverride: MakeupSettings(),
                facialZonalOverride: FacialZonalRefinementSettings(
                    enabled: true,
                    darkCircles: 0.45,
                    eyeBags: 0.40,
                    nasolabialFolds: 0.30,
                    antiShine: 0.50,
                    jawlineSculpting: 0.35
                ),
                eyeTeethOverride: EyeTeethRefinementSettings(
                    enabled: true,
                    eyeglassGlareReduction: 0.40,
                    scleraBloodshotRemoval: 0.30,
                    irisClarity: 0.20,
                    catchlightPattern: .naturalPoint,
                    catchlightStrength: 0.25,
                    teethStainRemoval: 0.35,
                    enamelSheen: 0.25
                )
            )
        case .child:
            return PersonPortraitProfile(
                role: .child,
                portraitOverride: PortraitRefinementSettings(
                    blemishStrength: 0.05, keepSpots: true,
                    dodgeBurn: 0.10, structure: 0.0, texture: 0.10,
                    gloss: 0.10, teethWhiten: 0.0, eyeBrighten: 0.20
                ),
                makeupOverride: MakeupSettings(),
                facialZonalOverride: FacialZonalRefinementSettings(),
                eyeTeethOverride: EyeTeethRefinementSettings(
                    enabled: true,
                    irisClarity: 0.20,
                    catchlightPattern: .starburst,
                    catchlightStrength: 0.30,
                    enamelSheen: 0.20
                )
            )
        case .elder:
            return PersonPortraitProfile(
                role: .elder,
                portraitOverride: PortraitRefinementSettings(
                    blemishStrength: 0.45, keepSpots: true,
                    dodgeBurn: 0.25, structure: 0.20, texture: 0.60,
                    gloss: 0.30, teethWhiten: 0.30, eyeBrighten: 0.30
                ),
                makeupOverride: MakeupSettings(lipIntensity: 0.15),
                facialZonalOverride: FacialZonalRefinementSettings(
                    enabled: true,
                    darkCircles: 0.40,
                    eyeBags: 0.30,
                    nasolabialFolds: 0.25
                ),
                eyeTeethOverride: EyeTeethRefinementSettings(
                    enabled: true,
                    eyeglassGlareReduction: 0.40,
                    scleraBloodshotRemoval: 0.40,
                    teethStainRemoval: 0.40,
                    enamelSheen: 0.20
                )
            )
        case .unassigned:
            return PersonPortraitProfile(role: .unassigned)
        }
    }
}

/// Settings for multi-person face grouping, demographic presets and tone unification.
public struct MultiPersonSettings: Codable, Equatable {
    /// Master toggle for multi-person group retouching.
    public var enabled: Bool = false
    /// Multi-face skin tone unification strength (0...1, default 0).
    public var unifySkinTone: Double = 0
    /// Reference skin tone source (median or brightest).
    public var toneReference: PortraitToneReference = .auto
    /// Role-based default profiles.
    public var demographicDefaults: [PersonDemographicRole: PersonPortraitProfile] = [:]
    /// Individual overrides keyed by face index.
    public var individualProfiles: [PersonPortraitProfile] = []

    public init(enabled: Bool = false,
                unifySkinTone: Double = 0,
                toneReference: PortraitToneReference = .auto,
                demographicDefaults: [PersonDemographicRole: PersonPortraitProfile] = [:],
                individualProfiles: [PersonPortraitProfile] = []) {
        self.enabled = enabled
        self.unifySkinTone = unifySkinTone
        self.toneReference = toneReference
        self.demographicDefaults = demographicDefaults
        self.individualProfiles = individualProfiles
    }

    public var isNeutral: Bool {
        guard enabled else { return true }
        let hasUnify = unifySkinTone > 0.001
        let hasActiveDemographics = demographicDefaults.values.contains(where: { !$0.isNeutral })
        let hasActiveIndividuals = individualProfiles.contains(where: { !$0.isNeutral })
        return !hasUnify && !hasActiveDemographics && !hasActiveIndividuals
    }

    public func profile(for faceIndex: Int, detectedRole: PersonDemographicRole = .unassigned) -> PersonPortraitProfile? {
        if let individual = individualProfiles.first(where: { $0.faceIndex == faceIndex }) {
            return individual
        }
        if let roleDefault = demographicDefaults[detectedRole] {
            return roleDefault
        }
        return nil
    }
}

/// Per-photo report for the multi-person demographic grouping pass.
public struct MultiPersonReport: Codable, Equatable {
    public var applied: Bool
    public var faceCount: Int
    public var personRoles: [String]
    public var appliedSteps: [String]
    public var note: String?

    public init(applied: Bool = false,
                faceCount: Int = 0,
                personRoles: [String] = [],
                appliedSteps: [String] = [],
                note: String? = nil) {
        self.applied = applied
        self.faceCount = faceCount
        self.personRoles = personRoles
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
        guard (1...30).contains(version) else {
            throw AtelierError.invalidConfiguration("不支持的配方版本：\(version)")
        }
        let jawChinReshapeGroups = [adjustments.jawChinReshape,
                                    automatic?.baseline.jawChinReshape,
                                    automatic?.referenceSettings.jawChinReshape]
        var hasJawChinReshapeOverride = false
        if let multi = adjustments.multiPerson, multi.enabled {
            for p in multi.individualProfiles where p.enabled {
                if let o = p.jawChinReshapeOverride, !o.isNeutral { hasJawChinReshapeOverride = true; break }
            }
            if !hasJawChinReshapeOverride {
                for p in multi.demographicDefaults.values where p.enabled {
                    if let o = p.jawChinReshapeOverride, !o.isNeutral { hasJawChinReshapeOverride = true; break }
                }
            }
        }
        guard version >= 30 || (jawChinReshapeGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) && !hasJawChinReshapeOverride) else {
            throw AtelierError.invalidConfiguration("非中性的智能下颌角/下巴微雕与面部下庭轮廓重塑需要配方版本 30，不能静默降级。")
        }
        let noseReshapeGroups = [adjustments.noseReshape,
                                 automatic?.baseline.noseReshape,
                                 automatic?.referenceSettings.noseReshape]
        var hasNoseReshapeOverride = false
        if let multi = adjustments.multiPerson, multi.enabled {
            for p in multi.individualProfiles where p.enabled {
                if let o = p.noseReshapeOverride, !o.isNeutral { hasNoseReshapeOverride = true; break }
            }
            if !hasNoseReshapeOverride {
                for p in multi.demographicDefaults.values where p.enabled {
                    if let o = p.noseReshapeOverride, !o.isNeutral { hasNoseReshapeOverride = true; break }
                }
            }
        }
        guard version >= 29 || (noseReshapeGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) && !hasNoseReshapeOverride) else {
            throw AtelierError.invalidConfiguration("非中性的智能鼻部精致微雕、立体鼻梁高光与驼峰鼻/朝天鼻矫正需要配方版本 29，不能静默降级。")
        }
        let eyeShapeGroups = [adjustments.eyeShape,
                              automatic?.baseline.eyeShape,
                              automatic?.referenceSettings.eyeShape]
        var hasEyeShapeOverride = false
        if let multi = adjustments.multiPerson, multi.enabled {
            for p in multi.individualProfiles where p.enabled {
                if let o = p.eyeShapeOverride, !o.isNeutral { hasEyeShapeOverride = true; break }
            }
            if !hasEyeShapeOverride {
                for p in multi.demographicDefaults.values where p.enabled {
                    if let o = p.eyeShapeOverride, !o.isNeutral { hasEyeShapeOverride = true; break }
                }
            }
        }
        guard version >= 28 || (eyeShapeGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) && !hasEyeShapeOverride) else {
            throw AtelierError.invalidConfiguration("非中性的智能眼型微雕、开眼角与眼位中庭平衡需要配方版本 28，不能静默降级。")
        }
        let expressionGroups = [adjustments.expression,
                                automatic?.baseline.expression,
                                automatic?.referenceSettings.expression]
        var hasExpressionOverride = false
        if let multi = adjustments.multiPerson, multi.enabled {
            for p in multi.individualProfiles where p.enabled {
                if let o = p.expressionOverride, !o.isNeutral { hasExpressionOverride = true; break }
            }
            if !hasExpressionOverride {
                for p in multi.demographicDefaults.values where p.enabled {
                    if let o = p.expressionOverride, !o.isNeutral { hasExpressionOverride = true; break }
                }
            }
        }
        guard version >= 27 || (expressionGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) && !hasExpressionOverride) else {
            throw AtelierError.invalidConfiguration("非中性的智能面部微表情、微笑嘴角与唇形立体微雕需要配方版本 27，不能静默降级。")
        }
        let facialHairGroups = [adjustments.facialHair,
                                automatic?.baseline.facialHair,
                                automatic?.referenceSettings.facialHair]
        var hasFacialHairOverride = false
        if let multi = adjustments.multiPerson, multi.enabled {
            for p in multi.individualProfiles where p.enabled {
                if let o = p.facialHairOverride, !o.isNeutral { hasFacialHairOverride = true; break }
            }
            if !hasFacialHairOverride {
                for p in multi.demographicDefaults.values where p.enabled {
                    if let o = p.facialHairOverride, !o.isNeutral { hasFacialHairOverride = true; break }
                }
            }
        }
        guard version >= 26 || (facialHairGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) && !hasFacialHairOverride) else {
            throw AtelierError.invalidConfiguration("非中性的唇毛消除、胡青净化与特征痣管理需要配方版本 26，不能静默降级。")
        }
        let hairColorGroups = [adjustments.hairColor,
                               automatic?.baseline.hairColor,
                               automatic?.referenceSettings.hairColor]
        var hasHairColorOverride = false
        if let multi = adjustments.multiPerson, multi.enabled {
            for p in multi.individualProfiles where p.enabled {
                if let o = p.hairColorOverride, !o.isNeutral { hasHairColorOverride = true; break }
            }
            if !hasHairColorOverride {
                for p in multi.demographicDefaults.values where p.enabled {
                    if let o = p.hairColorOverride, !o.isNeutral { hasHairColorOverride = true; break }
                }
            }
        }
        guard version >= 25 || (hairColorGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) && !hasHairColorOverride) else {
            throw AtelierError.invalidConfiguration("非中性的发色统一与白发修整需要配方版本 25，不能静默降级。")
        }
        let bokehGroups = [adjustments.bokehBlur,
                           automatic?.baseline.bokehBlur,
                           automatic?.referenceSettings.bokehBlur]
        guard version >= 24 || bokehGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("非中性的大光圈景深虚化与光斑雕刻需要配方版本 24，不能静默降级。")
        }
        let eyelidGroups = [adjustments.eyelidAegyoSal,
                            automatic?.baseline.eyelidAegyoSal,
                            automatic?.referenceSettings.eyelidAegyoSal]
        guard version >= 23 || eyelidGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("非中性的双眼皮雕刻、双眼皮贴修饰与卧蚕塑形需要配方版本 23，不能静默降级。")
        }
        let bodyReshapeGroups = [adjustments.bodyReshape,
                                 automatic?.baseline.bodyReshape,
                                 automatic?.referenceSettings.bodyReshape]
        guard version >= 22 || bodyReshapeGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("非中性的全身身形美化与姿态骨骼点塑形需要配方版本 22，不能静默降级。")
        }
        let eyeTeethGroups = [adjustments.eyeTeeth,
                              automatic?.baseline.eyeTeeth,
                              automatic?.referenceSettings.eyeTeeth]
        guard version >= 21 || eyeTeethGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("非中性的眼神光与牙齿美学精修需要配方版本 21，不能静默降级。")
        }
        let multiPersonGroups = [adjustments.multiPerson,
                                 automatic?.baseline.multiPerson,
                                 automatic?.referenceSettings.multiPerson]
        guard version >= 20 || multiPersonGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("非中性的多人脸分组独立精修需要配方版本 20，不能静默降级。")
        }
        let skyGroups = [adjustments.sky,
                         automatic?.baseline.sky,
                         automatic?.referenceSettings.sky]
        guard version >= 19 || skyGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("非中性的天空氛围与置换需要配方版本 19，不能静默降级。")
        }
        let petGroups = [adjustments.petEnhancement,
                         automatic?.baseline.petEnhancement,
                         automatic?.referenceSettings.petEnhancement]
        guard version >= 18 || petGroups.allSatisfy({ $0 == nil || $0!.isNeutral }) else {
            throw AtelierError.invalidConfiguration("非中性的宠物写真美化需要配方版本 18，不能静默降级。")
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

/// An offline, non-destructive virtual copy (version branch) derived from a photo.
/// Stores independent adjustment settings and look without duplicating the physical image file on disk.
public struct VirtualCopy: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var adjustments: AdjustmentSettings
    public var lutIdentifier: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        adjustments: AdjustmentSettings,
        lutIdentifier: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.adjustments = adjustments
        self.lutIdentifier = lutIdentifier
        self.createdAt = createdAt
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

    /// Optional per-photo custom adjustment settings (P2-K). When nil, inherits folder recipe adjustments.
    public var adjustments: AdjustmentSettings? = nil

    /// Optional per-photo custom LUT identifier (P2-K).
    public var lutIdentifier: String? = nil

    /// Virtual copies (version branches) derived from this photo (P2-L).
    public var virtualCopies: [VirtualCopy] = []

    /// ID of the currently active virtual copy, or nil if the master version is active.
    public var activeCopyID: UUID? = nil

    /// Suffix appended to filename during batch export (e.g. "_v1", "_黑白").
    public var exportSuffix: String? = nil

    public var id: String { url.path }

    public init(url: URL, relativePath: String, rating: Int = 0, isRejected: Bool = false,
                qualityReport: QualityReport? = nil, adjustments: AdjustmentSettings? = nil,
                lutIdentifier: String? = nil, virtualCopies: [VirtualCopy] = [],
                activeCopyID: UUID? = nil, exportSuffix: String? = nil) {
        self.url = url
        self.relativePath = relativePath
        self.rating = min(5, max(0, rating))
        self.isRejected = isRejected
        self.qualityReport = qualityReport
        self.adjustments = adjustments
        self.lutIdentifier = lutIdentifier
        self.virtualCopies = virtualCopies
        self.activeCopyID = activeCopyID
        self.exportSuffix = exportSuffix
    }

    /// The currently active virtual copy, or nil if master is active.
    public var activeCopy: VirtualCopy? {
        guard let id = activeCopyID else { return nil }
        return virtualCopies.first { $0.id == id }
    }

    /// Effective adjustments taking active virtual copy into account.
    public var effectiveAdjustments: AdjustmentSettings? {
        activeCopy?.adjustments ?? adjustments
    }

    /// Effective LUT taking active virtual copy into account.
    public var effectiveLUTIdentifier: String? {
        activeCopy != nil ? activeCopy?.lutIdentifier : lutIdentifier
    }

    /// Heuristic recommendation when the photo was analyzed, nil otherwise.
    public var qualityRecommendation: QualityRecommendation? { qualityReport?.recommendation }
}

/// Base reference used for interactive split Before/After comparison.
public enum ComparisonMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case original = "原片"
    case master = "主版本"

    public var id: String { rawValue }
}

/// Mode for exporting virtual copies alongside master photos during batch export.
public enum VirtualCopyExportMode: String, Codable, CaseIterable, Equatable {
    /// Export whichever version is currently active for each photo.
    case activeOnly = "activeOnly"
    /// Export both the master version and all virtual copies with distinct filename suffixes.
    case allVersions = "allVersions"
    /// Export only the master version, ignoring any active virtual copies.
    case masterOnly = "masterOnly"

    public var title: String {
        switch self {
        case .activeOnly: return "仅导出当前选中版本"
        case .allVersions: return "导出所有版本与主版本"
        case .masterOnly: return "仅导出原图主版本"
        }
    }
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
    /// Batch export mode for virtual copies.
    public var virtualCopyMode: VirtualCopyExportMode = .activeOnly

    public init(skipRejectedPhotos: Bool = false, skipUnselectedPhotos: Bool = false,
                virtualCopyMode: VirtualCopyExportMode = .activeOnly) {
        self.skipRejectedPhotos = skipRejectedPhotos
        self.skipUnselectedPhotos = skipUnselectedPhotos
        self.virtualCopyMode = virtualCopyMode
    }

    /// True when the options cannot change which files are exported.
    public var isNeutral: Bool {
        !skipRejectedPhotos && !skipUnselectedPhotos && virtualCopyMode == .activeOnly
    }

    /// Compact manifest/status summary, e.g. `skipRejected+skipUnselected+virtualCopies:allVersions`.
    public var summary: String {
        var parts: [String] = []
        if skipRejectedPhotos { parts.append("skipRejected") }
        if skipUnselectedPhotos { parts.append("skipUnselected") }
        if virtualCopyMode != .activeOnly { parts.append("virtualCopies:\(virtualCopyMode.rawValue)") }
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
    /// Per-photo P2-I pet enhancement status. `nil` when absent or disabled.
    public var petEnhancement: PetEnhancementReport?
    /// Per-photo P2-J sky enhancement status. `nil` when absent or disabled.
    public var sky: SkyEnhancementReport?
    /// Per-photo P2-M multi-person demographic grouping and per-person profile status. `nil` when absent or disabled.
    public var multiPerson: MultiPersonReport?
    /// Per-photo P2-N eye catchlight, glare suppression and teeth refinement status. `nil` when absent or disabled.
    public var eyeTeeth: EyeTeethRefinementReport?
    /// Per-photo P2-O body reshaping & skeleton posture refinement status. `nil` when absent or disabled.
    public var bodyReshape: BodyReshapeReport?
    /// Per-photo P2-P double eyelid sculpting, tape concealing and aegyo sal refinement status. `nil` when absent or disabled.
    public var eyelidAegyoSal: EyelidAegyoSalReport?
    /// Per-photo P2-Q bokeh blur and depth-of-field synthesis status. `nil` when absent or disabled.
    public var bokehBlur: BokehBlurReport?
    /// Per-photo P2-R hair color harmonization & gray hair removal status. `nil` when absent or disabled.
    public var hairColor: HairColorReport?
    /// Per-photo P2-S facial hair, peach fuzz removal & feature mole management status. `nil` when absent or disabled.
    public var facialHair: FacialHairReport?
    /// Per-photo P2-T facial micro-expression, smile & lip shape enhancement status. `nil` when absent or disabled.
    public var expression: ExpressionReport?
    /// Per-photo P2-U eye shape reshaping, canthoplasty & mid-face balance status. `nil` when absent or disabled.
    public var eyeShape: EyeShapeReport?
    /// Per-photo P2-V nose reshaping, 3D bridge contouring & structural correction status. `nil` when absent or disabled.
    public var noseReshape: NoseReshapeReport?
    /// Per-photo P2-W jawline sculpting, chin reshaping & lower-face proportions status. `nil` when absent or disabled.
    public var jawChinReshape: JawChinReshapeReport?
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

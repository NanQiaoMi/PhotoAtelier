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
    case jpeg, tiff, png
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    public var title: String { self == .tiff ? "TIFF · 16 bit" : (self == .png ? "PNG · 16 bit" : "JPEG · 高品质") }
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
    public var masks: [LocalMask] = []
    public init() {}
}

public struct ExportSettings: Codable, Equatable {
    public var format: ExportFormat = .jpeg
    public var colorSpace: OutputColorSpace = .sRGB
    public var jpegQuality: Double = 0.94
    public var recursive = false
    public var suffix = "_graded"
    /// Removes camera identifiers, location and all original EXIF on export when true.
    public var stripMetadata = true
    public init() {}
}

public struct Recipe: Codable, Equatable {
    /// Version 8 adds independently adjustable creative effects.
    public var version = 8
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
        guard (1...8).contains(version) else {
            throw AtelierError.invalidConfiguration("不支持的配方版本：\(version)")
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
    public var contentSelection: ContentSelectionReport?
    public var localDetails: [LocalDetailPlan]?
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

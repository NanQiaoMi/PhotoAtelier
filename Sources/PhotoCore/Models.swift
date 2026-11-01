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
    case sRGB, rec709, linearSRGB
    public var title: String {
        switch self {
        case .sRGB: return "sRGB · 显示参照"
        case .rec709: return "Rec.709 · Gamma 2.4"
        case .linearSRGB: return "Linear sRGB"
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
    case radial, linear, brush
    public var title: String {
        switch self { case .radial: return "径向"; case .linear: return "渐变"; case .brush: return "画笔" }
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

    public init(id: UUID = UUID(), name: String = "局部调整", kind: MaskKind = .radial,
                start: MaskPoint = .init(x: 0.5, y: 0.5), end: MaskPoint = .init(x: 0.75, y: 0.75),
                points: [MaskPoint] = [], radius: Double = 0.12, feather: Double = 0.65,
                inverted: Bool = false, enabled: Bool = true, exposureEV: Double = 0.3,
                saturation: Double = 1, warmth: Double = 0) {
        self.id = id; self.name = name; self.kind = kind; self.start = start; self.end = end
        self.points = points; self.radius = radius; self.feather = feather
        self.inverted = inverted; self.enabled = enabled; self.exposureEV = exposureEV
        self.saturation = saturation; self.warmth = warmth
    }
}

public struct AdjustmentSettings: Codable, Equatable {
    public var autoExposure = true
    public var autoWhiteBalance = false
    public var exposureEV: Double = 0
    public var temperature: Double = 0
    public var tint: Double = 0
    public var contrast: Double = 1
    public var saturation: Double = 1
    public var highlights: Double = 0
    public var shadows: Double = 0
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
    public var version = 1
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
    public init(image: CIImage, report: ProcessingReport) { self.image = image; self.report = report }
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

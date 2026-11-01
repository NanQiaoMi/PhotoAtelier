import Foundation

/// Carries a chosen analysis direction and later manual refinements across a
/// batch without reusing one photograph's exposure value for every file.
public struct AutomaticBatchRecipe: Codable, Equatable {
    public var styleID: String
    public var baseline: AdjustmentSettings
    public var referenceSettings: AdjustmentSettings

    public init(styleID: String, baseline: AdjustmentSettings, referenceSettings: AdjustmentSettings) {
        self.styleID = styleID; self.baseline = baseline; self.referenceSettings = referenceSettings
    }

    public func validate() throws {
        guard ["balanced", "bright", "soft"].contains(styleID) else {
            throw AtelierError.invalidConfiguration("未知的自动分析方案：\(styleID)")
        }
        try PhotoEngine.validate(baseline)
        try PhotoEngine.validate(referenceSettings)
    }

    public func resolve(analysis: PhotoAnalysis, current: AdjustmentSettings) throws -> AdjustmentSettings {
        try validate()
        guard let proposal = analysis.proposals.first(where: { $0.id == styleID }) else {
            throw AtelierError.invalidConfiguration("分析结果缺少所选方案，未静默回退到其他方案。")
        }
        var result = Self.copyBasicAdjustments(from: proposal.settings, into: current)
        let reference = referenceSettings
        result.exposureEV = bound(result.exposureEV + current.exposureEV - reference.exposureEV, -8, 8)
        result.temperature = bound(result.temperature + current.temperature - reference.temperature, -1, 1)
        result.tint = bound(result.tint + current.tint - reference.tint, -1, 1)
        result.contrast = bound(result.contrast + current.contrast - reference.contrast, 0, 4)
        result.saturation = bound(result.saturation + current.saturation - reference.saturation, 0, 4)
        result.highlights = bound(result.highlights + current.highlights - reference.highlights, -1, 1)
        result.shadows = bound(result.shadows + current.shadows - reference.shadows, -1, 1)
        if current.autoExposure != reference.autoExposure { result.autoExposure = current.autoExposure }
        if current.autoWhiteBalance != reference.autoWhiteBalance { result.autoWhiteBalance = current.autoWhiteBalance }
        try PhotoEngine.validate(result)
        return result
    }

    /// LUT, geometry and local masks always remain the user's current values.
    public static func copyBasicAdjustments(from source: AdjustmentSettings,
                                           into current: AdjustmentSettings) -> AdjustmentSettings {
        var result = current
        result.autoExposure = source.autoExposure; result.autoWhiteBalance = source.autoWhiteBalance
        result.exposureEV = source.exposureEV; result.temperature = source.temperature; result.tint = source.tint
        result.contrast = source.contrast; result.saturation = source.saturation
        result.highlights = source.highlights; result.shadows = source.shadows
        return result
    }

    private func bound(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value))
    }
}

/// Compact per-photo evidence; masks and LUT are already in the batch recipe.
public struct AutomaticAnalysisRecord: Codable, Equatable {
    public let summary: String
    public let issues: [PhotoAnalysisFinding]
    public let metrics: PhotoAnalysisMetrics
    public let metadata: [PhotoAnalysisMetadataItem]
    public let content: [PhotoContentLabel]
    public let unsupportedReadings: [String]
    public let selectedProposal: String
    public let applied: AutomaticAppliedAdjustments
    public let colorScene: ColorSceneProfile?

    public init(analysis: PhotoAnalysis, selectedProposal: String, applied: AdjustmentSettings) {
        summary = analysis.summary; issues = analysis.issues; metrics = analysis.metrics
        metadata = analysis.metadata; content = analysis.content
        unsupportedReadings = analysis.unsupportedReadings; self.selectedProposal = selectedProposal
        self.applied = AutomaticAppliedAdjustments(applied)
        colorScene = analysis.colorScene
    }
}

public struct AutomaticAppliedAdjustments: Codable, Equatable {
    public let exposureEV: Double
    public let temperature: Double
    public let tint: Double
    public let contrast: Double
    public let saturation: Double
    public let highlights: Double
    public let shadows: Double
    public let autoWhiteBalance: Bool
    public let autoExposure: Bool

    public init(_ settings: AdjustmentSettings) {
        exposureEV = settings.exposureEV; temperature = settings.temperature; tint = settings.tint
        contrast = settings.contrast; saturation = settings.saturation
        highlights = settings.highlights; shadows = settings.shadows
        autoWhiteBalance = settings.autoWhiteBalance; autoExposure = settings.autoExposure
    }
}

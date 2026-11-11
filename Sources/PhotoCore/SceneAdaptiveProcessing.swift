import Foundation

/// Capture/processing intent, independent of the user's creative LUT.
public enum PhotoSceneIntent: String, Codable, CaseIterable, Identifiable {
    case automatic, portrait, landscape, night, backlit, highKey, lowKey
    case softAtmosphere, monochrome, preserveStyle
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return "按每张照片判断"
        case .portrait: return "自然人像"
        case .landscape: return "风光层次"
        case .night: return "保留夜色"
        case .backlit: return "逆光层次"
        case .highKey: return "保留高调"
        case .lowKey: return "保留暗调"
        case .softAtmosphere: return "保留柔雾"
        case .monochrome: return "保留黑白影调"
        case .preserveStyle: return "保留已有风格"
        }
    }
}

public enum PhotoSceneCategory: String, Codable {
    case general, portrait, landscape, night, backlit, highKey, lowKey
    case softAtmosphere, monochrome, preserveStyle
    public var title: String {
        self == .general ? "未确定题材 · 保守处理" : PhotoSceneIntent(rawValue: rawValue)!.title
    }
}

public enum PhotoSceneSelectionSource: String, Codable { case user, evidence, fallback }
public enum PhotoSceneTrait: String, Codable {
    case lowKey, highKey, softContrast, wideDynamicRange, highChroma, nearMonochrome
    case colorSeparation, measuredFaces
}

/// Face-box observations, not a skin mask or a target skin-lightness estimate.
public struct PhotoSubjectMeasurement: Codable, Equatable {
    public let faceCount: Int
    public let sampleCount: Int
    public let coverage: Double
    public let medianLuminance: Double
    public let p95Luminance: Double
    public let nearWhiteFraction: Double
    public init(faceCount: Int, sampleCount: Int, coverage: Double, medianLuminance: Double,
                p95Luminance: Double, nearWhiteFraction: Double) {
        self.faceCount = faceCount; self.sampleCount = sampleCount; self.coverage = coverage
        self.medianLuminance = medianLuminance; self.p95Luminance = p95Luminance
        self.nearWhiteFraction = nearWhiteFraction
    }
}

public struct SceneAdjustmentDelta: Codable, Equatable {
    public let title: String
    public let direction: String
    public var exposureEV: Double = 0
    public var contrast: Double = 0
    public var saturation: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    /// EV changes of luminance-zone anchors, independent of legacy percentages.
    public var tonalCurve: TonalCurveSettings? = nil
}

public struct PhotoSceneAssessment: Codable, Equatable {
    public let policyVersion: Int
    public let requestedIntent: PhotoSceneIntent
    public let category: PhotoSceneCategory
    public let selectionSource: PhotoSceneSelectionSource
    public let traits: [PhotoSceneTrait]
    public let evidence: [String]
    public let uncertainties: [String]
    public let subject: PhotoSubjectMeasurement?
    public let balanced: SceneAdjustmentDelta
    public let bright: SceneAdjustmentDelta
    public let soft: SceneAdjustmentDelta
}

/// Transparent, bounded photographic heuristics, not a trained aesthetic model.
/// Semantics require corroborating pixels; color alone never proves a lighting
/// error or the presence of an existing filter. Manual intent remains explicit.
enum SceneAdaptivePlanner {
    static func assess(metrics m: PhotoAnalysisMetrics, colors c: ColorSceneProfile,
                       labels: [PhotoContentLabel], subject: PhotoSubjectMeasurement?,
                       intent: PhotoSceneIntent = .automatic, iso: Double? = nil) -> PhotoSceneAssessment {
        var traits: [PhotoSceneTrait] = []
        var evidence = [String(format: "基础调整后 P50 %.3f，P05–P95 %.2f EV，近白 %.2f%%。",
                               m.medianLuminance, m.dynamicRangeStops, m.nearWhiteFraction * 100)]
        var uncertainties = ["题材与拍摄意图不能仅由 RGB 唯一确定；可手动指定，依据不是审美正确率。"]
        let low = m.medianLuminance < 0.04 && c.darkFraction > 0.70
        let high = (m.medianLuminance > 0.60 && m.p05Luminance > 0.12)
            || (m.medianLuminance > 0.50 && c.brightFraction > 0.12 && c.darkFraction < 0.15)
            || (m.medianLuminance > 0.70 && c.brightFraction > 0.65)
        let narrow = m.dynamicRangeStops < 2.5
        let broad = m.dynamicRangeStops > 6
        let chromatic = c.saturatedFraction > 0.35
        let gray = c.neutralFraction >= 0.995 && m.meanSaturation < 0.005 && m.dynamicRangeStops >= 3.5
        let soft = narrow && m.medianLuminance >= 0.04 && m.medianLuminance <= 0.60
            && m.p05Luminance > 0.025 && m.p95Luminance < 0.85
        if low { traits.append(.lowKey) }
        if high { traits.append(.highKey) }
        if narrow { traits.append(.softContrast) }
        if broad { traits.append(.wideDynamicRange) }
        if chromatic { traits.append(.highChroma); evidence.append("已有高彩度覆盖较多，自动方案不再增加彩度。") }
        if gray { traits.append(.nearMonochrome) }
        if c.warmFraction > 0.20 && c.coolFraction > 0.20 {
            traits.append(.colorSeparation)
            evidence.append("画面同时含暖/冷色族；只描述颜色分布，不据此判断混合灯光或白平衡错误。")
        }
        let face = subject.flatMap { s -> PhotoSubjectMeasurement? in
            guard s.faceCount > 0, s.sampleCount >= 8, s.coverage.isFinite, s.coverage >= 0.003,
                  s.medianLuminance.isFinite, s.p95Luminance.isFinite,
                  s.nearWhiteFraction.isFinite else { return nil }
            return s
        }
        if let face {
            traits.append(.measuredFaces)
            evidence.append(String(format: "%d 个人脸框内测得 P50 %.3f，覆盖 %.1f%%；不是肤色分割。",
                                   face.faceCount, face.medianLuminance, face.coverage * 100))
        }
        func hint(_ identifiers: Set<String>, threshold: Double) -> Bool {
            labels.contains { identifiers.contains($0.label.lowercased())
                && $0.confidence.isFinite && $0.confidence >= threshold }
        }
        let nightHint = hint(["night", "night_sky", "nighttime"], threshold: 0.65)
        let landscapeHint = hint(["landscape", "mountain", "mountain_range", "forest", "coast", "beach", "desert"], threshold: 0.55)
        let backlitFace = face.map { $0.medianLuminance < 0.08 && m.p95Luminance > 0.55
            && m.p95Luminance > $0.medianLuminance * 8 } ?? false
        let splitLight = m.p05Luminance < 0.025 && m.p95Luminance > 0.55
            && c.darkFraction > 0.35 && c.brightFraction > 0.08 && m.dynamicRangeStops > 5.5
        let category: PhotoSceneCategory
        let source: PhotoSceneSelectionSource
        if intent != .automatic {
            category = PhotoSceneCategory(rawValue: intent.rawValue)!
            source = .user
            evidence.append("用户指定“\(intent.title)”；这项选择不被标签覆盖。")
        } else {
            source = (backlitFace || face != nil || high || low || soft || gray || splitLight
                      || (nightHint && m.medianLuminance < 0.08) || landscapeHint) ? .evidence : .fallback
            if nightHint && m.medianLuminance < 0.08 && c.darkFraction > 0.70 {
                category = .night; evidence.append("夜景标签与暗部占比、低中位亮度同时支持保留夜色。")
            } else if backlitFace { category = .backlit }
            else if face != nil { category = .portrait }
            else if high { category = .highKey }
            else if low { category = .lowKey }
            else if soft { category = .softAtmosphere }
            else if gray { category = .monochrome }
            else if splitLight { category = .backlit }
            else if landscapeHint && m.dynamicRangeStops >= 2.5 && c.neutralFraction < 0.995 {
                category = .landscape; evidence.append("风光标签与非单一灰阶、一定亮度跨度相符，作为弱题材线索。")
            } else { category = .general }
        }
        if category == .softAtmosphere { evidence.append("窄亮度范围可能来自柔光、雾或后期意图，保留低对比，不自动去雾。") }
        if category == .highKey { evidence.append("保留高亮基调，不把雪景、留白或高调照片拉向 18% 灰。") }
        if category == .lowKey || category == .night { evidence.append("保留暗调与灯光关系，不把暗背景当成必须提亮的曝光错误。") }
        if category == .monochrome { uncertainties.append("近无彩色也可能是自然中性场景，不能证明原图是黑白作品。") }
        if category == .monochrome && c.neutralFraction < 0.95 {
            uncertainties.append("输入仍有明显彩色：此方向只限制自动加色，不执行黑白转换。")
        }
        if category == .backlit { uncertainties.append("明暗分离也可能是有意剪影；仅提供有限的层次方案，不强行提亮主体。") }
        if category == .portrait && face == nil { uncertainties.append("未测得可靠人脸框，不使用肤色猜测或编造面部曝光，只提供保守人像方向。") }
        if category == .general { uncertainties.append("题材证据不足或互相矛盾，回退为有限的基础调整。") }
        uncertainties.append("无法可靠判断图片是否已套滤镜；需要保留既有调色时，请选择“保留已有风格”。")

        let headroom = max(0, log2(0.98 / max(m.p99Luminance, 0.001)))
        let weakEV = (0.10...0.35).contains(m.medianLuminance) ? 0
            : clamp(log2(0.18 / max(m.medianLuminance, 0.0001)) * 0.25, -0.12, 0.12)
        var a = SceneAdjustmentDelta(title: "保留基调", direction: "题材不确定时保留现有整体亮度，不按灰参考压暗或提亮。")
        var b = SceneAdjustmentDelta(title: "暗亮分区", direction: "有明暗分离证据时分别处理阴影与亮部，不把整张照片一起提亮。")
        var d = SceneAdjustmentDelta(title: "亮部柔和", direction: "仅有亮部证据时柔化亮部，保留主体中间调。",
                                     contrast: broad ? -0.025 : 0, highlights: m.p95Luminance > 0.65 ? -0.03 : 0)
        switch category {
        case .preserveStyle:
            a = .init(title: "原有风格", direction: "不新增自动基础调整，完整保留用户现有基础结果。")
            b = .init(title: "原样比较", direction: "保留已有影调和配色，后续可手动微调。")
            d = .init(title: "保留配方", direction: "不推测原有风格是否错误，不重复加滤镜。")
        case .softAtmosphere:
            a = .init(title: "保留柔雾", direction: "保留柔和低对比，不增加对比、彩度或自动去雾。")
            b = .init(title: "轻盈柔光", direction: "仅在画面较暗且有高光余量时轻提亮。", exposureEV: m.medianLuminance < 0.35 ? 0.04 : 0)
            d = .init(title: "柔雾层次", direction: "保留雾感，仅在近白样本存在时轻收高光。", highlights: m.nearWhiteFraction > 0.01 ? -0.02 : 0)
        case .night, .lowKey:
            a = .init(title: category == .night ? "夜色原貌" : "暗调原貌", direction: "保持暗背景和灯光，不全局归一到中灰。")
            b = .init(title: "暗部可读", direction: "小幅改善暗部可读性，不承诺暗部信息可恢复。", exposureEV: 0.04, shadows: 0.015)
            d = .init(title: "灯光柔和", direction: "保留暗调，仅轻收明亮灯光。", highlights: m.p99Luminance > 0.8 ? -0.04 : 0)
        case .highKey:
            a = .init(title: "保留高调", direction: "保留明亮留白，不按灰卡亮度压暗。")
            b = .init(title: "亮部层次", direction: "只收回少量高光，不改变高亮基调。", highlights: -0.04)
            d = .init(title: "柔光留白", direction: "保持亮调与低彩度，不额外加色。", highlights: -0.02)
        case .backlit:
            a = .init(title: "明暗关系", direction: "保留逆光或剪影意图，不全局提亮。", highlights: -0.02, shadows: 0.015)
            b = .init(title: "阴影层次", direction: "轻提暗部、轻收高光；有意剪影可继续保留原图。", highlights: -0.035, shadows: 0.045)
            d = .init(title: "柔和逆光", direction: "轻收明暗跨度，不改变白点或暖光。", contrast: -0.02, highlights: -0.03, shadows: 0.02)
        case .portrait:
            let lift = face.map { $0.medianLuminance < 0.06 && m.p95Luminance < 0.6 ? 0.04 : 0 } ?? 0
            a = .init(title: "自然人像", direction: "参考人脸框内亮度，保留肤色差异；不规定统一肤色亮度。", exposureEV: lift)
            b = .init(title: "人像层次", direction: "在亮部余量内少量提亮，不自动增加肤色彩度。", exposureEV: lift + (face == nil ? 0.03 : 0.05))
            d = .init(title: "柔和肖像", direction: "仅在明暗跨度较大时轻收对比，不改变肤色白点。", contrast: broad ? -0.02 : 0, highlights: m.p95Luminance > 0.7 ? -0.02 : 0)
        case .monochrome:
            a = .init(title: "黑白影调", direction: "保持无彩色，不增加彩度或添加冷暖。")
            b = .init(title: "黑白层次", direction: "有余量时稍提亮，仅处理亮度。", exposureEV: 0.04)
            d = .init(title: "柔和灰阶", direction: "跨度较大时轻收对比，保持灰阶中性。", contrast: m.dynamicRangeStops > 4 ? -0.015 : 0)
        case .landscape:
            a = .init(title: "自然风光", direction: "根据亮度跨度处理层次，不自动改天空或植物色相。", exposureEV: weakEV, contrast: broad ? -0.02 : (m.dynamicRangeStops >= 3.5 ? 0.01 : 0))
            b = .init(title: "风光层次", direction: "在高光余量内轻提亮；仅低彩度彩色图可少量加彩度。", exposureEV: weakEV + 0.06,
                      contrast: broad ? -0.02 : (m.dynamicRangeStops >= 3.5 ? 0.02 : 0),
                      saturation: c.saturatedFraction < 0.10 && m.meanSaturation > 0.05 && m.meanSaturation < 0.35 ? 0.01 : 0)
            d = .init(title: "柔和远景", direction: "轻收明暗跨度，保留远景空气感。", exposureEV: weakEV,
                      contrast: m.dynamicRangeStops > 3.5 ? -0.02 : 0, highlights: m.p95Luminance > 0.65 ? -0.03 : 0)
        case .general: break
        }
        let highISO = iso.map { $0.isFinite && $0 >= 1600 } ?? false
        if highISO && (category == .night || category == .lowKey) {
            evidence.append("高 ISO 元数据提示慎重提暗部；ISO 本身不等于实测噪声，未执行降噪。")
            b.exposureEV = min(b.exposureEV, 0.02); b.shadows = min(b.shadows, 0.005)
        }
        // Use actual EV-sized zone changes rather than tiny legacy coefficients.
        // Scene intent determines which parts may change; source evidence sets
        // the magnitude. These are luminance regions, not semantic object masks.
        let shadowNeed = clamp(log2(0.08 / max(m.p05Luminance, 0.003)) * 0.18, 0, 0.65)
        let highlightNeed = clamp(log2(max(m.p95Luminance, 0.55) / 0.55) * 0.40, 0, 0.45)
        let whiteNeed = m.nearWhiteFraction > 0.01 ? -0.10 : 0.0
        switch category {
        case .preserveStyle: break
        case .night, .lowKey:
            b.tonalCurve = .init(shadowsEV: min(highISO ? 0.12 : 0.40, shadowNeed),
                                midtonesEV: highISO ? 0.03 : 0.08)
            d.tonalCurve = .init(highlightsEV: -highlightNeed, whitesEV: whiteNeed)
        case .highKey:
            b.tonalCurve = .init(highlightsEV: -min(0.20, highlightNeed), whitesEV: whiteNeed)
            d.tonalCurve = .init(highlightsEV: -min(0.12, highlightNeed))
        case .softAtmosphere:
            b.tonalCurve = .init(midtonesEV: m.medianLuminance < 0.20 ? 0.10 : 0)
            d.tonalCurve = .init(whitesEV: whiteNeed)
        case .backlit:
            a.tonalCurve = .init(shadowsEV: min(0.30, shadowNeed), highlightsEV: -highlightNeed)
            b.tonalCurve = .init(shadowsEV: min(0.65, shadowNeed + 0.15),
                                midtonesEV: 0.10, highlightsEV: -min(0.40, highlightNeed + 0.10),
                                whitesEV: whiteNeed)
            d.tonalCurve = .init(shadowsEV: min(0.25, shadowNeed), highlightsEV: -highlightNeed)
        case .portrait:
            // Frame measurements are observations, never a universal skin target.
            if let face, face.medianLuminance < 0.08 {
                let need = clamp(log2(0.08 / max(face.medianLuminance, 0.008)) * 0.20, 0, 0.40)
                a.tonalCurve = .init(shadowsEV: need * 0.5)
                b.tonalCurve = .init(shadowsEV: need, midtonesEV: need * 0.25,
                                    highlightsEV: -highlightNeed)
            }
            d.tonalCurve = .init(highlightsEV: -min(0.15, highlightNeed))
        case .landscape:
            if broad {
                a.tonalCurve = .init(shadowsEV: min(0.25, shadowNeed), highlightsEV: -highlightNeed)
            }
            b.tonalCurve = .init(shadowsEV: min(0.40, shadowNeed), midtonesEV: 0.10,
                                highlightsEV: -highlightNeed, whitesEV: whiteNeed)
            d.tonalCurve = .init(highlightsEV: -highlightNeed)
        case .monochrome:
            b.tonalCurve = .init(shadowsEV: min(0.15, shadowNeed), midtonesEV: 0.10)
            d.tonalCurve = .init(highlightsEV: -min(0.15, highlightNeed))
        case .general:
            let separatedShadows = m.p05Luminance < 0.06 && c.darkFraction > 0.15
                && m.dynamicRangeStops >= 3
            b.tonalCurve = .init(shadowsEV: separatedShadows ? min(0.45, shadowNeed) : 0,
                                highlightsEV: -highlightNeed, whitesEV: whiteNeed)
            d.tonalCurve = .init(highlightsEV: -min(0.25, highlightNeed))
        }
        if [a, b, d].contains(where: { $0.tonalCurve.map { !$0.isNeutral } ?? false }) {
            evidence.append("三方案按不同亮度区域给出 EV 曲线变化，保留最暗锚点；实际增量仍接受原尺寸渲染检查。")
        }
        func protect(_ delta: SceneAdjustmentDelta) -> SceneAdjustmentDelta {
            var value = delta
            value.exposureEV = clamp(value.exposureEV, -0.25, 0.40)
            if value.exposureEV > 0 { value.exposureEV = min(value.exposureEV, headroom) }
            if high { value.exposureEV = min(0, value.exposureEV) }
            if narrow { value.contrast = min(0, value.contrast) }
            if chromatic || gray || category == .portrait || category == .monochrome { value.saturation = 0 }
            return value
        }
        return PhotoSceneAssessment(policyVersion: 2, requestedIntent: intent, category: category,
            selectionSource: category == .general && intent == .automatic ? .fallback : source,
            traits: traits, evidence: evidence, uncertainties: uncertainties, subject: face,
            balanced: protect(a), bright: protect(b), soft: protect(d))
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value))
    }
}

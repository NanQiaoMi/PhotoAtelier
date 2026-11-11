import Foundation

/// Measurements of the effective, feathered selection in linear extended sRGB.
/// Exposure advice is an optional direction, not a defect or aesthetic score.
public struct LocalLightGuidance: Codable, Equatable {
    public let policyVersion: Int
    public let selectedP05Linear: Double
    public let selectedMedianLinear: Double
    public let selectedP95Linear: Double
    public let selectedP99MaxChannel: Double
    public let globalMedianLinear: Double
    public let globalP95Linear: Double
    public let predictedIntroducedHighlightFraction: Double
    public let predictedIntroducedShadowFraction: Double
    public let suggestedExposureEV: Double
    public let reason: String
    public var hasSuggestion: Bool { abs(suggestedExposureEV) >= 0.03 }
}

struct LocalLightSample {
    let luminance: Double
    let maximumChannel: Double
    let alpha: Double
    let coverage: Double
    var selectedWeight: Double { alpha * coverage }
}

enum LocalLightGuidancePlanner {
    static func assess(_ samples: [LocalLightSample]) -> LocalLightGuidance? {
        let globalWeight = samples.reduce(0) { $0 + $1.alpha }
        let selectedWeight = samples.reduce(0) { $0 + $1.selectedWeight }
        guard globalWeight > 0, selectedWeight >= 2,
              selectedWeight / globalWeight > 0.005 else { return nil }
        // Reuse one luminance ordering for the five luminance quantiles. The
        // maximum-channel distribution needs its own ordering, not six sorts.
        typealias Measurement = (value: Double, weight: Double)
        func quantiles(_ ordered: [Measurement], at fractions: [Double]) -> [Double] {
            let total = ordered.reduce(0) { $0 + $1.weight }
            var weight = 0.0
            var result: [Double] = []
            for value in ordered {
                weight += value.weight
                while result.count < fractions.count && weight >= total * fractions[result.count] {
                    result.append(value.value)
                }
                if result.count == fractions.count { return result }
            }
            return result + Array(repeating: ordered.last?.value ?? 0, count: fractions.count - result.count)
        }
        let ordered = samples.sorted { $0.luminance < $1.luminance }
        let selected: [Measurement] = ordered.compactMap {
            $0.selectedWeight > 0.0001 ? ($0.luminance, $0.selectedWeight) : nil
        }
        let global: [Measurement] = ordered.map { ($0.luminance, $0.alpha) }
        let channels: [Measurement] = samples.compactMap {
            $0.selectedWeight > 0.0001 ? ($0.maximumChannel, $0.selectedWeight) : nil
        }.sorted { $0.value < $1.value }
        let selectedQuantiles = quantiles(selected, at: [0.05, 0.50, 0.95])
        let globalQuantiles = quantiles(global, at: [0.50, 0.95])
        let p05 = selectedQuantiles[0], median = selectedQuantiles[1], p95 = selectedQuantiles[2]
        let channelP99 = quantiles(channels, at: [0.99])[0]
        let globalMedian = globalQuantiles[0], globalP95 = globalQuantiles[1]
        let darkFraction = samples.filter { $0.luminance < 0.12 }.reduce(0) { $0 + $1.alpha } / globalWeight

        var exposure = 0.0
        var reason = "选区没有足够的明暗分离证据，保留现有局部亮度；不向全图中位值归一。"
        if median <= 0.003 {
            reason = "选区接近纯黑，无法证明仍有可恢复细节，不自动提亮。"
        } else if p05 >= 0.98 {
            reason = "选区接近纯白，压暗不能恢复已丢失的细节，保留现有留白。"
        } else if median < 0.08 && globalP95 > max(0.20, median * 4) {
            let darkScene = globalMedian < 0.04 && darkFraction > 0.70
            exposure = min(darkScene ? 0.12 : 0.60, max(0, log2(0.12 / median) * 0.25))
            reason = darkScene
                ? "暗部与亮部存在分离，但全图为暗调；仅提供最多 +0.12 EV 的可读性选项。"
                : "选区较暗且全图仍有明亮区域；有限提亮以改善可读性，保留明暗关系。"
            // Luminance alone misses channel clipping on saturated red/blue.
            // Full-strength P99 headroom is conservative for feathered coverage.
            let headroom = max(0, log2(0.98 / max(channelP99, 0.0001)))
            if headroom < exposure {
                exposure = headroom
                reason += " 选区 P99 最大 RGB 通道接近上限，已按通道余量减弱。"
            }
        } else if median > 0.50 && median > globalMedian * 1.8 && p95 > 0.65 {
            exposure = -min(0.35, max(0, log2(p95 / 0.65) * 0.4))
            reason = "选区明显亮于整体，仅提供有限亮部柔化；不把亮部降到全图中位亮度。"
        }

        // Predict the exposure blend on the measured coverage, without relying
        // on highlight/color protection or a later output gamut mapper to hide
        // clipping. This is sampled guidance, not a full-resolution guarantee.
        func predicted(_ ev: Double) -> (high: Double, low: Double) {
            let gain = pow(2, ev)
            var high = 0.0, low = 0.0
            for sample in samples where sample.selectedWeight > 0.0001 {
                let factor = 1 + sample.coverage * (gain - 1)
                if sample.maximumChannel < 1 && sample.maximumChannel * factor >= 1 {
                    high += sample.selectedWeight
                }
                if sample.luminance > 0.002 && sample.luminance * factor <= 0.002 {
                    low += sample.selectedWeight
                }
            }
            return (high / selectedWeight, low / selectedWeight)
        }
        let requested = exposure
        var retained = 1.0
        for fraction in [1.0, 0.75, 0.5, 0.25, 0.0] {
            let value = requested * fraction
            let changes = predicted(value)
            if changes.high <= 0.005 && changes.low <= 0.005 {
                exposure = value; retained = fraction
                break
            }
        }
        if retained < 1 {
            reason += String(format: " 按实测覆盖估算新增越界后，保留 %.0f%% 建议强度。", retained * 100)
        }
        if abs(exposure) < 0.03 {
            exposure = 0
            reason += " 当前可用调整不足 0.03 EV，暂不提供一键变更。"
        }
        let changes = predicted(exposure)
        return LocalLightGuidance(policyVersion: 1, selectedP05Linear: p05,
            selectedMedianLinear: median, selectedP95Linear: p95, selectedP99MaxChannel: channelP99,
            globalMedianLinear: globalMedian, globalP95Linear: globalP95,
            predictedIntroducedHighlightFraction: changes.high, predictedIntroducedShadowFraction: changes.low,
            suggestedExposureEV: exposure, reason: reason)
    }
}

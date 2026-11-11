import CoreImage
import Foundation

public struct RegionalAdjustmentSuggestion: Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let evidence: String
    public let caution: String
    public let mask: LocalMask
    /// Absent in older saved analyses; measured on the effective mask coverage.
    public let lightGuidance: LocalLightGuidance?
    public let effectiveCoverage: Double?
}

/// Offers editable, spatially limited light adjustments from a corrected
/// global-only reference. Grid cells are observations, not subject segmentation.
public enum RegionalAdjustmentAnalyzer {
    /// `context` must render unpremultiplied RGBA, as PhotoEngine.context does.
    public static func suggestions(reference: CIImage, context: CIContext) throws -> [RegionalAdjustmentSuggestion] {
        let sample = try AutomaticSafetyEvaluator.sampledSource(reference, limit: 192)
        let width = Int(sample.extent.width), height = Int(sample.extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(sample, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: sample.extent, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        }
        var regions = Array(repeating: [(luma: Double, weight: Double)](), count: 9)
        var totalWeight = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let a = Double(pixels[offset + 3])
                let r = Double(pixels[offset]), g = Double(pixels[offset + 1]), b = Double(pixels[offset + 2])
                guard a.isFinite, a > 0.001, r.isFinite, g.isFinite, b.isFinite else { continue }
                let weight = min(1, a)
                totalWeight += weight
                let region = min(2, y * 3 / height) * 3 + min(2, x * 3 / width)
                regions[region].append((max(0, 0.2126 * r + 0.7152 * g + 0.0722 * b), weight))
            }
        }
        guard totalWeight > 0 else { return [] }
        struct Observation {
            let index: Int, median: Double, p90: Double, coverage: Double
        }
        let observations = regions.enumerated().compactMap { index, values -> Observation? in
            let sorted = values.sorted { $0.luma < $1.luma }
            let weight = sorted.reduce(0) { $0 + $1.weight }
            guard weight / totalWeight >= 0.04, sorted.count >= 8 else { return nil }
            func percentile(_ fraction: Double) -> Double {
                var sum = 0.0
                for value in sorted {
                    sum += value.weight
                    if sum >= weight * fraction { return value.luma }
                }
                return sorted.last!.luma
            }
            return Observation(index: index, median: percentile(0.5), p90: percentile(0.9),
                               coverage: weight / totalWeight)
        }
        guard let darkest = observations.min(by: { $0.median < $1.median }),
              let brightest = observations.max(by: { $0.median < $1.median }) else { return [] }
        var result: [RegionalAdjustmentSuggestion] = []
        func suggestion(_ region: Observation, shadow: Bool) throws -> RegionalAdjustmentSuggestion? {
            let row = region.index / 3, column = region.index % 3
            let position = ["上", "中", "下"][row] + ["左", "中", "右"][column]
            let center = MaskPoint(x: (Double(column) + 0.5) / 3, y: 1 - (Double(row) + 0.5) / 3)
            // At edge cells choose an inward radius endpoint so geometry is valid.
            let end = MaskPoint(x: center.x + (column == 2 ? -0.27 : 0.27),
                                y: center.y + (row == 0 ? -0.27 : 0.27))
            let name = "\(position) · \(shadow ? "阴影可读" : "柔化亮部")"
            let id = "region.\(region.index).\(shadow ? "shadow" : "highlight")"
            // Stable IDs make re-applying this suggestion replace its own mask
            // rather than silently stacking the same adjustment repeatedly.
            let maskID = UUID(uuidString: String(format: "DC0A0000-0000-4000-8000-%012d",
                                                 region.index * 2 + (shadow ? 1 : 2)))!
            var mask = LocalMask(id: maskID, name: name, kind: .radial, start: center, end: end,
                                 feather: 0.75, exposureEV: 0, highlightProtection: 0.65,
                                 colorProtection: 0.8, stage: .beforeLook, restrictLuminance: true,
                                 luminanceMin: shadow ? 0 : 0.65, luminanceMax: shadow ? 0.50 : 1,
                                 rangeSoftness: 0.15)
            let inspection = try LocalMaskEngine.inspect(mask, reference: reference, context: context)
            guard let guidance = inspection.lightGuidance, guidance.hasSuggestion,
                  shadow ? guidance.suggestedExposureEV > 0 : guidance.suggestedExposureEV < 0 else { return nil }
            mask.exposureEV = guidance.suggestedExposureEV
            return RegionalAdjustmentSuggestion(id: id, title: name,
                evidence: String(format: "定位网格 P50 %.3f、P90 %.3f（网格样本占 %.1f%%）。实际蒙版覆盖 %.1f%%；选区线性 P50 %.3f、P95 %.3f，P99 最大通道 %.3f。拟用曝光 %+.2f EV，限制到%@。%@",
                                 region.median, region.p90, region.coverage * 100,
                                 inspection.coverage * 100, guidance.selectedMedianLinear,
                                 guidance.selectedP95Linear, guidance.selectedP99MaxChannel, mask.exposureEV,
                                 shadow ? "较暗亮度范围" : "较亮亮度范围", guidance.reason),
                caution: "这是位置与亮度提示，不是主体边界或缺陷判断。越界估计基于最长边 384 的覆盖样本，不是原尺寸或后续叠加的保证；建立后检查覆盖，再细调。",
                mask: mask, lightGuidance: guidance, effectiveCoverage: inspection.coverage)
        }
        // A lone dark background or uniform high-key field is not evidence of
        // a local correction. Require a meaningful contrast with other regions.
        if darkest.median < 0.08, brightest.median > max(0.20, darkest.median * 4),
           darkest.p90 > 0.003 {
            if let value = try suggestion(darkest, shadow: true) { result.append(value) }
        }
        if brightest.median > 0.50, darkest.median < 0.22,
           brightest.median > darkest.median * 3 {
            if let value = try suggestion(brightest, shadow: false) { result.append(value) }
        }
        return result
    }
}

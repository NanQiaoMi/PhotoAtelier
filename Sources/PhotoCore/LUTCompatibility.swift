import Foundation

public struct LUTCompatibilityReport: Codable, Equatable {
    public let size: Int
    public let interpretation: LUTColorSpace
    public let outputOutsideUnitFraction: Double
    public let neutralColorShift: Double
    public let neutralToneReversals: Int
    public let warnings: [String]
    public let summary: String
}

/// A table audit, not an attempt to infer a transfer function from the filename,
/// TITLE, or pixel colors. Creative LUTs can intentionally trip these signals.
public enum LUTCompatibilityInspector {
    public static func inspect(_ lut: LUTCube, colorSpace: LUTColorSpace) -> LUTCompatibilityReport {
        let dimension = min(lut.size, 9)
        var outside = 0, total = 0
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    let normalized = SIMD3<Float>(Float(r), Float(g), Float(b)) / Float(dimension - 1)
                    let source = lut.domainMin + (lut.domainMax - lut.domainMin) * normalized
                    let c = lut.sample(source)
                    if min(c.x, min(c.y, c.z)) < 0 || max(c.x, max(c.y, c.z)) > 1 { outside += 1 }
                    total += 1
                }
            }
        }
        var maxTint = 0.0, reversals = 0
        var previousLuma: Double?
        for step in 0...32 {
            let value = Float(step) / 32
            let c = lut.sample(SIMD3<Float>(repeating: value))
            maxTint = max(maxTint, Double(max(c.x, max(c.y, c.z)) - min(c.x, min(c.y, c.z))))
            let luma = Double(0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z)
            if let previous = previousLuma, luma < previous - 0.005 { reversals += 1 }
            previousLuma = luma
        }
        let outsideFraction = Double(outside) / Double(max(1, total))
        var warnings: [String] = []
        if outsideFraction > 0.001 {
            warnings.append(String(format: "%.1f%% 的表格采样输出超出 0–1；请比较高光、彩色边缘与目标色域映射。", outsideFraction * 100))
        }
        if maxTint > 0.08 { warnings.append("中性灰经此表会明显着色；建议保留中性色保护并比较原片。") }
        if reversals > 0 { warnings.append("灰阶曲线存在亮度反转；可能是刻意风格，也可能与用途不匹配，请检查细节层次。") }
        if lut.size < 17 { warnings.append("此表采样较疏；渐变和肤色过渡需要检查是否出现色带。") }
        if lut.domainMin != SIMD3<Float>(repeating: 0) || lut.domainMax != SIMD3<Float>(repeating: 1) {
            warnings.append("已读取自定义输入范围；超出范围的照片颜色会逐渐降低 LUT 权重。")
        }
        let summary = "\(lut.size)³ · \(colorSpace.title) · " + (warnings.isEmpty ? "表格未发现上述数值风险，色彩用途仍需由作者说明确认。" : "发现 \(warnings.count) 项需比较的特征。")
        return LUTCompatibilityReport(size: lut.size, interpretation: colorSpace,
                                      outputOutsideUnitFraction: outsideFraction,
                                      neutralColorShift: maxTint, neutralToneReversals: reversals,
                                      warnings: warnings, summary: summary)
    }
}

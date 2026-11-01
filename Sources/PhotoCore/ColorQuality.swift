import CoreGraphics
import CoreImage
import Foundation

/// Measured changes relative to the globally corrected image. Fractions are
/// alpha weighted; a large change is a review signal, not an aesthetic score.
public struct ColorQualityReport: Codable, Equatable {
    public let scene: ColorSceneProfile
    public let protectionEnabled: Bool
    public let outputColorSpace: OutputColorSpace?
    public let sampleCount: Int
    public let addedChromaBefore: Double
    public let addedChromaAfter: Double
    public let hueShiftBefore: Double
    public let hueShiftAfter: Double
    public let neutralTintBefore: Double
    public let neutralTintAfter: Double
    public let outOfGamutBefore: Double
    public let outOfGamutAfter: Double
    public let summary: String
}

enum ColorQualityInspector {
    static func inspect(reference: CIImage, candidate: CIImage, final: CIImage,
                        scene: ColorSceneProfile, settings: ColorHarmonySettings?,
                        outputColorSpace: OutputColorSpace?, context: CIContext) throws -> ColorQualityReport {
        let extent = reference.extent
        let scale = min(1, 128 / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        func render(_ image: CIImage) -> [Float] {
            let resized = image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: .init(scaleX: CGFloat(width) / extent.width,
                                      y: CGFloat(height) / extent.height)).cropped(to: bounds)
            var pixels = [Float](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { buffer in
                context.render(resized, toBitmap: buffer.baseAddress!,
                               rowBytes: width * 4 * MemoryLayout<Float>.size, bounds: bounds,
                               format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
            }
            return pixels
        }
        let ref = render(reference), before = render(candidate), after = render(final)
        var beforeCounts = SIMD4<Double>(repeating: 0), afterCounts = beforeCounts
        var weight = 0.0, count = 0
        for offset in stride(from: 0, to: ref.count, by: 4) {
            let alpha = Double(ref[offset + 3])
            guard alpha.isFinite, alpha > 0.001 else { continue }
            let r = SIMD3<Double>(Double(ref[offset]), Double(ref[offset + 1]), Double(ref[offset + 2]))
            let b = SIMD3<Double>(Double(before[offset]), Double(before[offset + 1]), Double(before[offset + 2]))
            let a = SIMD3<Double>(Double(after[offset]), Double(after[offset + 1]), Double(after[offset + 2]))
            guard [r.x, r.y, r.z, b.x, b.y, b.z, a.x, a.y, a.z].allSatisfy(\.isFinite) else { continue }
            let w = min(1, alpha)
            beforeCounts += signals(reference: r, changed: b, target: outputColorSpace) * w
            afterCounts += signals(reference: r, changed: a, target: outputColorSpace) * w
            weight += w; count += 1
        }
        if weight > 0 { beforeCounts /= weight; afterCounts /= weight }
        let enabled = settings?.enabled == true
        let summary = String(format: "新增高色度 %.1f%% → %.1f%% · 明显色相变化 %.1f%% → %.1f%% · 中性染色 %.1f%% → %.1f%%。%@",
                             beforeCounts.x * 100, afterCounts.x * 100,
                             beforeCounts.y * 100, afterCounts.y * 100,
                             beforeCounts.z * 100, afterCounts.z * 100,
                             enabled ? "已按当前保护与输出设置处理，仍需比较照片意图。" : "未启用整体协调保护。")
        return ColorQualityReport(scene: scene, protectionEnabled: enabled,
                                  outputColorSpace: outputColorSpace, sampleCount: count,
                                  addedChromaBefore: beforeCounts.x, addedChromaAfter: afterCounts.x,
                                  hueShiftBefore: beforeCounts.y, hueShiftAfter: afterCounts.y,
                                  neutralTintBefore: beforeCounts.z, neutralTintAfter: afterCounts.z,
                                  outOfGamutBefore: beforeCounts.w, outOfGamutAfter: afterCounts.w,
                                  summary: summary)
    }

    private static func signals(reference: SIMD3<Double>, changed: SIMD3<Double>,
                                target: OutputColorSpace?) -> SIMD4<Double> {
        let luma: (SIMD3<Double>) -> Double = { 0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z }
        let refY = max(0, luma(reference)), changedY = max(0, luma(changed))
        let matched = refY > 0.00001 ? reference * min(256, max(0, changedY / refY)) : reference
        let refLab = lab(matched), changedLab = lab(changed)
        let refChroma = hypot(refLab.y, refLab.z), changedChroma = hypot(changedLab.y, changedLab.z)
        let chromaRisk = changedChroma > refChroma * 1.35 + 0.035
        let dot = refLab.y * changedLab.y + refLab.z * changedLab.z
        let cosine = dot / max(0.0000001, refChroma * changedChroma)
        let hueRisk = refChroma > 0.035 && changedChroma > 0.035 && cosine < cos(.pi / 6)
        let neutralRisk = refChroma < 0.025 && changedChroma > 0.05
        var rgb = changed
        if target == .displayP3 {
            rgb = SIMD3(0.8224619687 * changed.x + 0.1775380313 * changed.y,
                        0.0331941989 * changed.x + 0.9668058011 * changed.y,
                        0.0170826307 * changed.x + 0.0723974407 * changed.y + 0.9105199286 * changed.z)
        }
        let gamutRisk = min(rgb.x, min(rgb.y, rgb.z)) < -0.001 || max(rgb.x, max(rgb.y, rgb.z)) > 1.001
        return SIMD4(chromaRisk ? 1 : 0, hueRisk ? 1 : 0, neutralRisk ? 1 : 0, target != nil && gamutRisk ? 1 : 0)
    }

    private static func lab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        func root(_ value: Double) -> Double { cbrt(value) }
        let l = root(0.4122214708 * rgb.x + 0.5363325363 * rgb.y + 0.0514459929 * rgb.z)
        let m = root(0.2119034982 * rgb.x + 0.6806995451 * rgb.y + 0.1073969566 * rgb.z)
        let s = root(0.0883024619 * rgb.x + 0.2817188376 * rgb.y + 0.6299787005 * rgb.z)
        return SIMD3(0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s)
    }
}

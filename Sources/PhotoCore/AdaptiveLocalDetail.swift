import CoreImage
import Foundation

public enum LocalDetailIntent: String, Codable, CaseIterable {
    case automatic, portrait, texture, lowLight

    public var title: String {
        switch self {
        case .automatic: return "按区域实测"
        case .portrait: return "皮肤纹理优先"
        case .texture: return "真实层次优先"
        case .lowLight: return "暗部噪点优先"
        }
    }
}

/// Stores an intent, not the measurements or one photograph's resolved values.
public struct LocalDetailAdaptation: Codable, Equatable {
    public var intent: LocalDetailIntent
    public var strength: Double
    public init(intent: LocalDetailIntent = .automatic, strength: Double = 0.6) {
        self.intent = intent; self.strength = strength
    }
}

public struct LocalDetailMeasurements: Codable, Equatable {
    public let sampleCount: Int
    public let patchCount: Int
    public let medianLuminance: Double
    /// Robust HH residual in sqrt(linear Y), measured without resizing patches.
    /// This is a noise candidate, not a sensor-noise or grain classification.
    public let luminanceNoise: Double
    public let chromaNoise: Double
    public let textureFraction: Double
    public let strongEdgeFraction: Double
    public let nearBlackFraction: Double
    public let nearWhiteFraction: Double
    public let ambiguousFinePattern: Bool
}

public struct LocalDetailPlan: Codable, Equatable {
    public let policyVersion: Int
    public let maskID: UUID
    public let requestedIntent: LocalDetailIntent
    public let resolvedIntent: LocalDetailIntent
    public let status: String
    public let processingStage: String
    public let measurements: LocalDetailMeasurements
    /// Actual per-photo settings; manual settings are used instead when adaptation is off.
    public let settings: LocalDetailSettings
    /// Effective sqrt-luminance threshold passed to the renderer.
    public let noiseEstimate: Double
    public let evidence: [String]
    public let warnings: [String]
}

public enum AdaptiveLocalDetailAnalyzer {
    public static func validate(_ settings: LocalDetailAdaptation) throws {
        guard settings.strength.isFinite, (0...1).contains(settings.strength) else {
            throw AtelierError.invalidConfiguration("自适应细节强度必须是 0...1 的有限数值。")
        }
    }

    /// Samples at most nine 96px native-resolution patches inside the coverage.
    /// The overview only locates patches; it never estimates noise after resizing.
    /// `context` must render unpremultiplied RGBA, as PhotoEngine.context does.
    public static func analyze(reference: CIImage, coverage: CIImage, maskID: UUID,
                               target: ContentSelectionTarget?, adaptation: LocalDetailAdaptation,
                               context: CIContext, cancellation: CancellationToken? = nil,
                               isSpatiallyLimited: Bool = false) throws -> LocalDetailPlan {
        try validate(adaptation)
        try cancellation?.check()
        let extent = reference.extent
        guard !extent.isInfinite, !extent.isNull, extent.width.isFinite, extent.height.isFinite,
              extent.width >= 1, extent.height >= 1, coverage.extent == extent else {
            throw AtelierError.invalidConfiguration("区域细节测量需要一致、有限的参考图与蒙版。")
        }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func render(_ image: CIImage, bounds: CGRect) -> [Float] {
            let width = Int(bounds.width), height = Int(bounds.height)
            var data = [Float](repeating: 0, count: width * height * 4)
            data.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                               bounds: bounds, format: .RGBAf, colorSpace: linear)
            }
            return data
        }
        let source = reference.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
        let mask = coverage.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
        let scale = min(1, 96 / max(extent.width, extent.height))
        let overviewWidth = max(1, Int((extent.width * scale).rounded()))
        let overviewHeight = max(1, Int((extent.height * scale).rounded()))
        let overview = mask.transformed(by: .init(scaleX: CGFloat(overviewWidth) / extent.width,
                                                 y: CGFloat(overviewHeight) / extent.height))
        let overviewPixels = render(overview, bounds: CGRect(x: 0, y: 0, width: overviewWidth, height: overviewHeight))
        let maximumCoverage = stride(from: 0, to: overviewPixels.count, by: 4)
            .map { Double(overviewPixels[$0]) }.filter { $0.isFinite }.max() ?? 0
        var centers = Array(repeating: (x: 0.0, y: 0.0, weight: 0.0), count: 9)
        for y in 0..<overviewHeight {
            for x in 0..<overviewWidth {
                let offset = (y * overviewWidth + x) * 4
                let weight = Double(overviewPixels[offset])
                guard maximumCoverage > 0, weight.isFinite, weight > maximumCoverage * 0.1 else { continue }
                let cell = min(2, y * 3 / overviewHeight) * 3 + min(2, x * 3 / overviewWidth)
                centers[cell].x += (Double(x) + 0.5) / Double(overviewWidth) * weight
                // CIContext bitmap rows run from the top of the rendered bounds.
                centers[cell].y += (1 - (Double(y) + 0.5) / Double(overviewHeight)) * weight
                centers[cell].weight += weight
            }
        }
        struct Block {
            let luma: Double, maximum: Double, hh: Double, chromaHH: Double, gradient: Double, weight: Double
        }
        var blocks: [Block] = []
        var seen = Set<String>()
        var patches = 0
        let patchWidth = min(96, Int(extent.width)), patchHeight = min(96, Int(extent.height))
        for center in centers where center.weight > 0 {
            try cancellation?.check()
            let x = max(0, min(Int(extent.width) - patchWidth,
                               Int(center.x / center.weight * Double(extent.width)) - patchWidth / 2))
            let y = max(0, min(Int(extent.height) - patchHeight,
                               Int(center.y / center.weight * Double(extent.height)) - patchHeight / 2))
            guard seen.insert("\(x):\(y)").inserted else { continue }
            let bounds = CGRect(x: x, y: y, width: patchWidth, height: patchHeight)
            let pixels = render(source, bounds: bounds), weights = render(mask, bounds: bounds)
            patches += 1
            guard patchWidth >= 2, patchHeight >= 2 else { continue }
            for row in stride(from: 0, to: patchHeight - 1, by: 2) {
                for column in stride(from: 0, to: patchWidth - 1, by: 2) {
                    let offsets = [row * patchWidth + column, row * patchWidth + column + 1,
                                   (row + 1) * patchWidth + column, (row + 1) * patchWidth + column + 1].map { $0 * 4 }
                    var lumas: [Double] = [], redChroma: [Double] = [], blueChroma: [Double] = []
                    var maximum = -Double.infinity
                    var blockWeight = 1.0
                    for offset in offsets {
                        let alpha = Double(pixels[offset + 3]), weight = Double(weights[offset])
                        let rgb = (0..<3).map { Double(pixels[offset + $0]) }
                        guard alpha.isFinite, alpha >= 0.1, weight.isFinite, weight >= maximumCoverage * 0.5,
                              rgb.allSatisfy({ $0.isFinite && abs($0) < 65504 }) else { break }
                        let luma = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
                        lumas.append(max(0, luma)); maximum = max(maximum, rgb.max()!)
                        blockWeight = min(blockWeight, min(1, alpha) * min(1, weight / maximumCoverage))
                        redChroma.append(rgb[0] - luma); blueChroma.append(rgb[2] - luma)
                    }
                    guard lumas.count == 4 else { continue }
                    let root = lumas.map { sqrt($0) }
                    func hh(_ values: [Double]) -> Double { abs(values[0] - values[1] - values[2] + values[3]) * 0.5 }
                    let gx = abs(root[0] + root[2] - root[1] - root[3]) * 0.5
                    let gy = abs(root[0] + root[1] - root[2] - root[3]) * 0.5
                    blocks.append(Block(luma: lumas.reduce(0, +) * 0.25, maximum: maximum,
                                        hh: hh(root), chromaHH: max(hh(redChroma), hh(blueChroma)),
                                        gradient: hypot(gx, gy), weight: blockWeight))
                }
            }
        }
        func median(_ values: [Block], key: KeyPath<Block, Double>) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted { $0[keyPath: key] < $1[keyPath: key] }
            let target = sorted.reduce(0) { $0 + $1.weight } * 0.5
            var accumulated = 0.0
            for sample in sorted {
                accumulated += sample.weight
                if accumulated >= target { return sample[keyPath: key] }
            }
            return sorted.last![keyPath: key]
        }
        let candidates = blocks.filter { $0.gradient < 0.035 && $0.luma > 0.002 && $0.maximum < 0.98 }
        let noise = min(0.25, median(candidates, key: \.hh) / 0.67448975)
        let chromaNoise = min(0.25, median(candidates, key: \.chromaHH) / 0.67448975)
        let weight = max(0.000001, blocks.reduce(0) { $0 + $1.weight })
        func fraction(_ predicate: (Block) -> Bool) -> Double {
            blocks.filter(predicate).reduce(0) { $0 + $1.weight } / weight
        }
        let ambiguous = median(candidates, key: \.hh) > max(0.004, median(candidates, key: \.gradient) * 1.8)
        let measurements = LocalDetailMeasurements(sampleCount: blocks.count * 4, patchCount: patches,
            medianLuminance: median(blocks, key: \.luma), luminanceNoise: noise, chromaNoise: chromaNoise,
            textureFraction: fraction { $0.gradient > max(0.002, noise * 3.5) && $0.gradient < 0.12 },
            strongEdgeFraction: fraction { $0.gradient >= 0.12 },
            nearBlackFraction: fraction { $0.luma <= 0.002 },
            nearWhiteFraction: fraction { $0.maximum >= 0.985 },
            ambiguousFinePattern: ambiguous)
        return plan(measurements: measurements, maskID: maskID, target: target, adaptation: adaptation,
                    sufficientNoiseEvidence: candidates.count >= 32, isSpatiallyLimited: isSpatiallyLimited)
    }

    static func plan(measurements m: LocalDetailMeasurements, maskID: UUID,
                     target: ContentSelectionTarget?, adaptation: LocalDetailAdaptation,
                     sufficientNoiseEvidence: Bool = true, isSpatiallyLimited: Bool = false) -> LocalDetailPlan {
        let noiseEstimate = min(0.25, max(m.luminanceNoise,
            m.chromaNoise / max(0.1, 2 * sqrt(m.medianLuminance))))
        let intent: LocalDetailIntent
        if adaptation.intent != .automatic { intent = adaptation.intent }
        else if target == .faceSkin { intent = .portrait }
        else if m.medianLuminance < 0.1 && noiseEstimate > 0.005 { intent = .lowLight }
        else { intent = .texture }
        var settings = LocalDetailSettings()
        var warnings = ["颗粒、压缩纹理与细密图案可能混入噪点估计；请以 100% 画面检查。"]
        let sufficient = m.sampleCount >= 128
        let amount = sufficient ? adaptation.strength : 0
        let noiseRisk = min(1, max(0, (noiseEstimate - 0.001) / 0.018))
        let texture = m.textureFraction
        let evidenceWeight = sufficientNoiseEvidence && !m.ambiguousFinePattern ? 1.0 : 0.0
        if intent == .portrait {
            // Whole-person/background masks also contain fabric, hair and objects.
            let skinCandidate = target == .faceSkin || (target == nil && isSpatiallyLimited)
            settings.smoothing = skinCandidate ? amount * 0.3 * (1 - 0.7 * texture) * evidenceWeight : 0
            settings.textureRetention = 0.95
            settings.toneUniformity = skinCandidate ? amount * min(0.14, m.chromaNoise * 7) * evidenceWeight : 0
            settings.noiseReduction = amount * 0.35 * noiseRisk * evidenceWeight
            if !skinCandidate { warnings.append("全图、整个人物或背景不等于皮肤，未自动平整；请建立面部候选或手绘小范围。") }
        } else if intent == .lowLight {
            settings.noiseReduction = amount * 0.55 * noiseRisk * evidenceWeight
            settings.detailRecovery = 0
        } else {
            settings.noiseReduction = amount * 0.2 * noiseRisk * evidenceWeight
            // Evidence of structure permits enhancement, but a frame already
            // dense with texture/edges needs less additional acutance.
            let support = min(1, texture / 0.15)
            let existingDetailGuard = (1 - 0.85 * texture) * (1 - 0.85 * m.strongEdgeFraction)
            settings.detailRecovery = amount * 0.3 * support * existingDetailGuard * (1 - noiseRisk) * evidenceWeight
        }
        if !sufficient { warnings.append("选区有效样本不足，本图不自动改变细节。") }
        if !sufficientNoiseEvidence || m.ambiguousFinePattern {
            warnings.append("缺少平坦区域或细密图案存在歧义，未自动降噪或增强纹理。")
        }
        if m.nearWhiteFraction > 0.01 { warnings.append("部分通道接近显示白；若原文件已截断，压暗也无法恢复纹理。此测量不证明源数据剪切。") }
        if m.nearBlackFraction > 0.05 { warnings.append("部分区域接近黑位；无法据此证明暗部存在可恢复细节。") }
        if m.nearBlackFraction > 0.8 || m.nearWhiteFraction > 0.8 { settings = LocalDetailSettings() }
        return LocalDetailPlan(policyVersion: 1, maskID: maskID, requestedIntent: adaptation.intent,
            resolvedIntent: intent, status: sufficient ? "measured" : "insufficientSamples",
            processingStage: "beforeLocalColorAndLook", measurements: m,
            settings: settings, noiseEstimate: noiseEstimate,
            evidence: [String(format: "%d 个原像素样本 · %d 个局部块 · 线性亮度中位 %.3f", m.sampleCount, m.patchCount, m.medianLuminance),
                       String(format: "噪点候选 %.4f · 色度残差 %.4f · 结构占比 %.1f%% · 强边缘 %.1f%%", m.luminanceNoise, m.chromaNoise, m.textureFraction * 100, m.strongEdgeFraction * 100),
                       "采用\(intent.title)，细节先于局部光色和滤镜执行；不自动美白、统一肤色或生成纹理。"], warnings: warnings)
    }
}

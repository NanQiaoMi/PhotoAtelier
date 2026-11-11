import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Opt in per recipe. The user's LUT intensity remains an upper bound; the
/// resolved, per-photo parameters are evidence in the report, never recipe edits.
public struct AdaptiveLUTSettings: Codable, Equatable {
    public var enabled = true
    public var colorProtection = 0.65
    public var skinProtection = 0.8
    public var toneProtection = 0.75
    public var preserveSourceMonochrome = true
    public init() {}
}

/// Ephemeral semantic observations, reusable while the global reference is
/// unchanged. Pixel measurements always come from the actual LUT-stage image.
public struct LUTSemanticContext: Equatable {
    public let labels: [PhotoContentLabel]
    public let status: String
    public init(labels: [PhotoContentLabel] = [], status: String = "notAvailable") {
        self.labels = labels; self.status = status
    }

    public static func analyze(_ image: CIImage, cancellation: CancellationToken? = nil) throws -> Self {
        try cancellation?.check()
        let bounded = try AutomaticSafetyEvaluator.sampledSource(image, limit: 512)
        let request = VNClassifyImageRequest()
        do {
            try VNImageRequestHandler(ciImage: bounded, options: [:]).perform([request])
            try cancellation?.check()
            let labels = (request.results ?? []).prefix(5).compactMap { value -> PhotoContentLabel? in
                guard value.confidence.isFinite, value.confidence >= 0.15 else { return nil }
                return PhotoContentLabel(id: "vision.\(value.identifier)", label: value.identifier,
                    confidence: Double(value.confidence), source: "本机 Vision · 题材候选")
            }
            return Self(labels: labels, status: labels.isEmpty ? "noReliableLabels" : "measured")
        } catch {
            try cancellation?.check()
            return Self(status: "unavailable")
        }
    }
}

public struct LUTAdaptationMetrics: Codable, Equatable {
    public let introducedHighlights: Double
    public let introducedShadows: Double
    public let addedChroma: Double
    public let hueShift: Double
    public let neutralTint: Double?
    public let skinHueP90Degrees: Double?
    public let skinChromaGrowthP90: Double?
    public let detailLoss: Double?
    public let meanChange: Double
}

public struct LUTAdaptationCandidate: Codable, Equatable {
    public let id: String
    public let intensity: Double
    public let preserveLuminance: Double
    public let protectSkin: Double
    public let protectNeutrals: Double
    public let localProtection: Double
    public let metrics: LUTAdaptationMetrics
    /// Optional for reports written before policy 2. Sample quality does not
    /// establish native safety; nil nativeSafetyAccepted means not checked.
    public let sampleQualityAccepted: Bool?
    public let nativeSafetyAccepted: Bool?
    public let accepted: Bool
    public let reasons: [String]
}

public struct LUTAdaptationReport: Codable, Equatable {
    public let policyVersion: Int
    public let requestedIntensity: Double
    public let selectedCandidateID: String
    public let effectiveIntensity: Double
    public let scene: ColorSceneProfile
    public let contentLabels: [PhotoContentLabel]
    public let contentStatus: String
    public let faceStatus: String
    public let faceCount: Int
    public let skinSampleCount: Int
    public let sampleWidth: Int
    public let sampleHeight: Int
    public let monochromeLUT: Bool
    public let sourceMonochrome: Bool
    public let candidates: [LUTAdaptationCandidate]
    public let nativeCheckedCandidateIDs: [String]?
    public let nativeIntroducedHighlights: Double
    public let nativeIntroducedShadows: Double
    public let summary: String
    public let reasons: [String]
    public let scope: String
}

struct AdaptedLUTResult {
    let image: CIImage
    let report: LUTAdaptationReport
}

/// An explicit candidate search with local color/tone guards. This does not
/// estimate capture WB, choose a film for the user, or rank aesthetic quality.
enum LUTAdaptationEngine {
    typealias Renderer = (_ intensity: Double, _ luminance: Double, _ skin: Double, _ neutral: Double) throws -> CIImage

    private static let guardKernel = CIColorKernel(source: """
    float root(float x) { return sign(x) * pow(abs(x), 1.0 / 3.0); }
    vec3 lab(vec3 c) {
        vec3 v = vec3(root(dot(c, vec3(0.4122214708, 0.5363325363, 0.0514459929))),
                      root(dot(c, vec3(0.2119034982, 0.6806995451, 0.1073969566))),
                      root(dot(c, vec3(0.0883024619, 0.2817188376, 0.6299787005))));
        return vec3(dot(v, vec3(0.2104542553, 0.7936177850, -0.0040720468)),
                    dot(v, vec3(1.9779984951, -2.4285922050, 0.4505937099)),
                    dot(v, vec3(0.0259040371, 0.7827717662, -0.8086757660)));
    }
    vec3 target(vec3 c, float p3) {
        if (p3 < 0.5) { return c; }
        return vec3(0.8224619687 * c.r + 0.1775380313 * c.g,
                    0.0331941989 * c.r + 0.9668058011 * c.g,
                    0.0170826307 * c.r + 0.0723974407 * c.g + 0.9105199286 * c.b);
    }
    float edgeLimit(float r, float c) {
        float t = 1.0;
        if (c >= 0.99999 && r < 1.0 && c > r) { t = clamp((0.99998 - r) / (c - r), 0.0, 1.0); }
        if (c < -0.00009 && r >= -0.0001 && c < r) { t = min(t, clamp((-0.00008 - r) / (c - r), 0.0, 1.0)); }
        return t;
    }
    kernel vec4 adaptFilm(__sample ref, __sample changed, __sample face,
                          float colorProtection, float skinProtection,
                          float toneProtection, float level, float sourceGray, float p3) {
        float a = ref.a;
        if (a <= 0.000001) { return vec4(0.0); }
        vec3 r = ref.rgb / a;
        vec3 c = changed.a > 0.000001 ? changed.rgb / changed.a : r;
        float ry = max(0.0, dot(r, vec3(0.2126, 0.7152, 0.0722)));
        float cy = max(0.0, dot(c, vec3(0.2126, 0.7152, 0.0722)));
        vec3 rl = lab(ry > 0.00001 ? r * clamp(cy / ry, 0.0, 256.0) : r);
        vec3 cl = lab(c);
        float rc = length(rl.yz), cc = length(cl.yz);
        float hue = 0.5 * (1.0 - clamp(dot(rl.yz, cl.yz) / max(rc * cc, 0.000001), -1.0, 1.0));
        float hueRisk = smoothstep(0.05, 0.40, hue) * smoothstep(0.018, 0.045, rc)
                      * smoothstep(0.018, 0.045, cc);
        float growth = smoothstep(0.018 + rc * 0.3, 0.10 + rc * 0.6, cc - rc);
        float neutral = (1.0 - smoothstep(0.012, 0.045, rc)) * smoothstep(0.018, 0.08, cc);
        // Desaturation / a monochrome look never triggers a "restore color" rule.
        float colorRisk = max(hueRisk, max(growth, neutral));
        float protect = colorProtection * level * colorRisk * 0.85;
        float faceRisk = max(hueRisk, growth);
        protect = max(protect, clamp(face.r, 0.0, 1.0) * skinProtection * faceRisk * (0.55 + 0.4 * level));
        float ev = log2(max(cy, 0.00001) / max(ry, 0.00001));
        float tonalRisk = smoothstep(0.4, 1.4, abs(ev));
        protect = max(protect, toneProtection * level * tonalRisk * 0.9);
        c = mix(c, r, clamp(protect, 0.0, 0.97));
        if (sourceGray > 0.5) {
            float y = dot(c, vec3(0.2126, 0.7152, 0.0722));
            c = vec3(y);
        }
        // A continuous, per-pixel segment limit catches highlights smaller than
        // any analysis raster. Existing source HDR / negative values are retained.
        vec3 tr = target(r, p3), tc = target(c, p3);
        float limit = min(edgeLimit(tr.r, tc.r), min(edgeLimit(tr.g, tc.g), edgeLimit(tr.b, tc.b)));
        float newY = dot(c, vec3(0.2126, 0.7152, 0.0722));
        if (ry > 0.002 && newY <= 0.002 && newY < ry) {
            limit = min(limit, clamp((0.00201 - ry) / (newY - ry), 0.0, 1.0));
        }
        return vec4(mix(r, c, limit) * a, a);
    }
    """)

    static func validate(_ value: AdaptiveLUTSettings) throws {
        for (name, number) in [("颜色", value.colorProtection), ("肤色", value.skinProtection), ("影调", value.toneProtection)] {
            guard number.isFinite, (0...1).contains(number) else {
                throw AtelierError.invalidConfiguration("逐图 LUT \(name)保护必须在 0...1 范围内。")
            }
        }
    }

    static func apply(reference: CIImage, cube: LUTCube, settings: AdjustmentSettings,
                      selections: ContentSelectionResult?, semantics: LUTSemanticContext,
                      target: OutputColorSpace?, context: CIContext,
                      cancellation: CancellationToken?, render: Renderer) throws -> AdaptedLUTResult {
        try cancellation?.check()
        let options = settings.adaptiveLUT!
        let scene = try ColorSceneAnalyzer.analyze(image: reference, context: context)
        try cancellation?.check()
        let small = try AutomaticSafetyEvaluator.sampledSource(reference, limit: 192)
        let width = Int(small.extent.width), height = Int(small.extent.height)
        let sourcePixels = pixels(reference, width: width, height: height, context: context)
        try cancellation?.check()
        let skinMask = selections?.image(for: .faceSkin) ?? CIImage(color: .black).cropped(to: reference.extent)
        let skinPixels = pixels(skinMask, width: width, height: height, context: context, numeric: true)
        try cancellation?.check()
        let mono = isMonochrome(cube)
        var grayWeight = 0.0, visibleWeight = 0.0
        for i in stride(from: 0, to: sourcePixels.count, by: 4) where sourcePixels[i + 3] > 0.001 {
            let w = Double(sourcePixels[i + 3]); visibleWeight += w
            if abs(sourcePixels[i] - sourcePixels[i + 1]) < 0.00015,
               abs(sourcePixels[i + 1] - sourcePixels[i + 2]) < 0.00015 { grayWeight += w }
        }
        let sourceGray = options.preserveSourceMonochrome && visibleWeight > 0 && grayWeight / visibleWeight > 0.995
        var candidates: [LUTAdaptationCandidate] = []
        var chosen: (image: CIImage, candidate: LUTAdaptationCandidate,
                     highlights: Double, shadows: Double)?
        var nativeCheckedIDs: [String] = []
        var nativeRejectedCount = 0
        var skinCount = 0
        for offset in stride(from: 0, to: sourcePixels.count, by: 4) where skinPixels[offset] > 0.15 && sourcePixels[offset + 3] > 0.001 {
            let y = 0.2126 * sourcePixels[offset] + 0.7152 * sourcePixels[offset + 1] + 0.0722 * sourcePixels[offset + 2]
            if y > 0.008 && y < 0.95 { skinCount += 1 }
        }
        // Both exposure zones and measured color density change the searched
        // protections. A warm image alone never invokes white balance correction.
        let nightEvidence = semantics.labels.contains {
            $0.confidence >= 0.3 && ["night", "nightlife", "moonlight", "fireworks"].contains($0.label.lowercased())
        } && scene.darkFraction > 0.65
        let toneDemand = min(1, scene.darkFraction * 0.55 + scene.brightFraction * 0.9 + (nightEvidence ? 0.2 : 0))
        let colorDemand = min(1, scene.saturatedFraction * 0.7 + scene.colorDiversity * 0.3)
        for fraction in [1.0, 0.75, 0.5, 0.25, 0.0] {
            for level in fraction == 0 ? [0.0] : [0.25, 1.0] {
                try cancellation?.check()
                let intensity = settings.lutIntensity * fraction
                let luminance = min(1, settings.preserveLuminance + options.toneProtection * level * toneDemand * 0.3)
                let skin = mono ? 0 : min(1, settings.protectSkin + (skinCount >= 8 ? options.skinProtection * level * 0.2 : 0))
                let neutral = mono ? 0 : min(1, settings.protectNeutrals + options.colorProtection * level * colorDemand * 0.2)
                let initial = fraction == 0 ? reference : try render(intensity, luminance, skin, neutral)
                let candidate = fraction == 0 ? reference : try guarded(reference: reference, candidate: initial,
                    skin: skinMask, options: options, level: level, sourceGray: sourceGray,
                    target: target)
                let sample = pixels(candidate, width: width, height: height, context: context)
                try cancellation?.check()
                let metrics = try measure(reference: sourcePixels, candidate: sample, skin: skinPixels,
                                          width: width, height: height, target: target)
                let id = "\(Int(fraction * 100))-\(Int(level * 100))"
                var reasons = sampleQualityViolations(metrics, options: options, colorDemand: colorDemand, monochrome: mono)
                let sampleAccepted = reasons.isEmpty
                var nativeAccepted: Bool?
                var native = (highlights: 0.0, shadows: 0.0)
                if sampleAccepted && chosen == nil {
                    // Thresholding and resizing do not commute. A thumbnail's
                    // apparent crossing is diagnostic only; test the actual
                    // candidate before preferring it or trying the next one.
                    nativeCheckedIDs.append(id)
                    native = try AutomaticSafetyEvaluator.areaFractions(reference: reference,
                        candidate: candidate, context: context, outputColorSpace: target)
                    try cancellation?.check()
                    let clipped = try AutomaticSafetyEvaluator.hasIntroducedClipping(
                        reference: reference, candidate: candidate, context: context,
                        outputColorSpace: target)
                    try cancellation?.check()
                    nativeAccepted = !clipped && native.highlights == 0 && native.shadows == 0
                    if nativeAccepted == false {
                        nativeRejectedCount += 1
                        reasons.append("原尺寸检查发现新增高光或暗部剪切")
                    }
                }
                let record = LUTAdaptationCandidate(id: id,
                    intensity: intensity, preserveLuminance: luminance, protectSkin: skin,
                    protectNeutrals: neutral, localProtection: level, metrics: metrics,
                    sampleQualityAccepted: sampleAccepted, nativeSafetyAccepted: nativeAccepted,
                    accepted: nativeAccepted == true, reasons: reasons)
                candidates.append(record)
                // Search all strengths: arbitrary tables are not necessarily monotone.
                // Among feasible candidates prefer the requested look, then fewer guards.
                if record.accepted && chosen == nil {
                    chosen = (candidate, record, native.highlights, native.shadows)
                }
            }
        }
        guard let resolved = chosen else {
            throw AtelierError.invalidConfiguration("照片没有可验证的有限像素，逐图 LUT 适配已停止。")
        }
        try cancellation?.check()
        var reasons: [String] = []
        if nativeRejectedCount > 0 {
            reasons.append("\(nativeRejectedCount) 组候选未通过原尺寸剪切检查，已继续验证后续候选；未修改你的基础或局部参数。")
        }
        if scene.darkFraction > 0.65 { reasons.append("暗部覆盖较多，单独约束阴影压黑与亮度跨度，保留暗调。") }
        if nightEvidence { reasons.append("夜景题材候选与暗部像素证据相符，进一步保留夜色影调；未据标签提亮全图。") }
        if scene.brightFraction > 0.12 { reasons.append("亮部覆盖较多，增加亮度保持并逐像素限制新增高光剪切。") }
        if scene.saturatedFraction > 0.3 { reasons.append("原图已有浓色，重点限制新增色度与突兀色相，未做全图去色。") }
        if skinCount >= 8 { reasons.append("依据本机人脸地标的皮肤候选单独测量色相与色度；未把暖色物体一律当作人脸。") }
        else { reasons.append("没有足够可靠的面部皮肤样本，肤色指标未评估；保留全图与局部颜色保护。") }
        if semantics.status == "unavailable" { reasons.append("本机题材识别不可用，已按实测像素与选区保守适配。") }
        if sourceGray { reasons.append("原片接近中性黑白，保留黑白颜色关系，只采用胶片影调。") }
        if mono { reasons.append("表格为近黑白转换，允许降彩；未将黑白风格判为颜色丢失。") }
        if resolved.candidate.intensity < settings.lutIntensity { reasons.append("更强候选超过当前保护约束，已选择通过约束的较高强度。") }
        let summary = String(format: "逐图试渲染 %d 组 · 强度上限 %.0f%% → %.0f%% · %@",
            candidates.count, settings.lutIntensity * 100, resolved.candidate.intensity * 100,
            resolved.candidate.intensity == 0 ? "回退原色" : "已按照片限制局部光色变化")
        return AdaptedLUTResult(image: resolved.image, report: LUTAdaptationReport(policyVersion: 2,
            requestedIntensity: settings.lutIntensity, selectedCandidateID: resolved.candidate.id,
            effectiveIntensity: resolved.candidate.intensity, scene: scene, contentLabels: semantics.labels,
            contentStatus: semantics.status, faceStatus: selections?.report.faceStatus ?? "notRequested",
            faceCount: selections?.report.faceCount ?? 0, skinSampleCount: skinCount,
            sampleWidth: width, sampleHeight: height, monochromeLUT: mono, sourceMonochrome: sourceGray,
            candidates: candidates, nativeCheckedCandidateIDs: nativeCheckedIDs,
            nativeIntroducedHighlights: resolved.highlights,
            nativeIntroducedShadows: resolved.shadows, summary: summary, reasons: reasons,
            scope: "LUT 阶段：候选小样测量 + 当前输入分辨率的新增剪切检查；不包含后续蒙版、颗粒、整体协调和输出映射。题材标签是候选，颜色分布不证明白平衡错误，不保证审美最优。"))
    }

    private static func guarded(reference: CIImage, candidate: CIImage, skin: CIImage,
                                options: AdaptiveLUTSettings, level: Double,
                                sourceGray: Bool, target: OutputColorSpace?) throws -> CIImage {
        guard let guardKernel, let image = guardKernel.apply(extent: reference.extent, arguments: [
            reference, candidate, skin, NSNumber(value: options.colorProtection),
            NSNumber(value: options.skinProtection), NSNumber(value: options.toneProtection),
            NSNumber(value: level), NSNumber(value: sourceGray ? 1 : 0),
            NSNumber(value: target == .displayP3 ? 1 : 0)
        ]) else { throw AtelierError.invalidConfiguration("逐图 LUT 局部保护 kernel 无法运行。") }
        return image
    }

    private static func pixels(_ image: CIImage, width: Int, height: Int, context: CIContext, numeric: Bool = false) -> [Float] {
        let e = image.extent
        let resized = image.transformed(by: .init(translationX: -e.minX, y: -e.minY))
            .transformed(by: .init(scaleX: CGFloat(width) / e.width, y: CGFloat(height) / e.height))
        var result = [Float](repeating: 0, count: width * height * 4)
        result.withUnsafeMutableBytes { buffer in
            context.render(resized, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
                colorSpace: numeric ? nil : CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        }
        return result
    }

    private static func isMonochrome(_ cube: LUTCube) -> Bool {
        [SIMD3<Float>(0.8, 0.2, 0.1), SIMD3(0.15, 0.7, 0.2), SIMD3(0.1, 0.2, 0.8), SIMD3(0.4, 0.6, 0.3)].allSatisfy {
            let c = cube.sample($0)
            return max(c.x, max(c.y, c.z)) - min(c.x, min(c.y, c.z)) < 0.008
        }
    }

    static func measure(reference: [Float], candidate: [Float], skin: [Float],
                                width: Int, height: Int, target: OutputColorSpace?) throws -> LUTAdaptationMetrics {
        var total = 0.0, high = 0.0, low = 0.0, chroma = 0.0, hue = 0.0, neutral = 0.0, neutrals = 0.0, change = 0.0
        var skinHues: [(Double, Double)] = [], skinGrowth: [(Double, Double)] = []
        var edges = 0.0, lostEdges = 0.0
        func rgb(_ a: [Float], _ i: Int) -> SIMD3<Double> { SIMD3(Double(a[i]), Double(a[i + 1]), Double(a[i + 2])) }
        func y(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        func output(_ c: SIMD3<Double>) -> SIMD3<Double> {
            target == .displayP3 ? SIMD3(0.8224619687*c.x + 0.1775380313*c.y,
                0.0331941989*c.x + 0.9668058011*c.y,
                0.0170826307*c.x + 0.0723974407*c.y + 0.9105199286*c.z) : c
        }
        for i in stride(from: 0, to: reference.count, by: 4) {
            let alpha = Double(reference[i + 3])
            guard alpha.isFinite, alpha > 0.001 else { continue }
            let r = rgb(reference, i), c = rgb(candidate, i), weight = min(1, alpha)
            guard [r.x, r.y, r.z, c.x, c.y, c.z, Double(candidate[i + 3])].allSatisfy(\.isFinite) else {
                throw AtelierError.invalidConfiguration("逐图 LUT 候选产生非有限可见像素。")
            }
            total += weight
            let tr = output(r), tc = output(c)
            if (0..<3).contains(where: { tc[$0] >= 1 && tr[$0] < 1 }) { high += weight }
            if (y(c) <= 0.002 && y(r) > 0.002) || (0..<3).contains(where: { tc[$0] < -0.0001 && tr[$0] >= -0.0001 }) { low += weight }
            let expected = y(r) > 0.00001 ? r * min(256, max(0, y(c) / y(r))) : r
            let rl = lab(expected), cl = lab(c)
            let rc = hypot(rl.y, rl.z), cc = hypot(cl.y, cl.z)
            let angle = rc > 0.018 && cc > 0.018
                ? acos(min(1, max(-1, (rl.y*cl.y + rl.z*cl.z) / (rc*cc)))) * 180 / .pi : 0
            if cc > rc * 1.5 + 0.04 { chroma += weight }
            if angle > 35 { hue += weight }
            if rc < 0.018, y(r) > 0.015, y(r) < 0.85 { neutrals += weight; if cc > 0.045 { neutral += weight } }
            let originalLab = lab(r)
            change += sqrt(pow(originalLab.x - cl.x, 2) + pow(originalLab.y - cl.y, 2) + pow(originalLab.z - cl.z, 2)) * weight
            if skin[i] > 0.15, y(r) > 0.008, y(r) < 0.95 {
                let sw = weight * Double(skin[i])
                if rc > 0.018 && cc > 0.018 { skinHues.append((angle, sw)) }
                skinGrowth.append((max(0, cc - rc), sw))
            }
            // Relative local contrast, only along visible, meaningful reference
            // edges; no sharpening demand is imposed on intentionally flat areas.
            let pixel = i / 4
            let neighbors = [pixel % width + 1 < width ? i + 4 : nil,
                             pixel / width + 1 < height ? i + width * 4 : nil].compactMap { $0 }
            for neighbor in neighbors where reference[neighbor + 3] > 0.001 && y(r) > 0.005 {
                let ry2 = y(rgb(reference, neighbor)), cy2 = y(rgb(candidate, neighbor))
                let re = abs(log2((max(y(r), 0.001)) / max(ry2, 0.001)))
                let ce = abs(log2((max(y(c), 0.001)) / max(cy2, 0.001)))
                if re > 0.12 && re < 3 { edges += weight; if ce < re * 0.35 { lostEdges += weight } }
            }
        }
        guard total > 0 else { throw AtelierError.invalidConfiguration("逐图 LUT 适配没有有效可见样本。") }
        func p90(_ values: [(Double, Double)]) -> Double? {
            guard values.count >= 8 else { return nil }
            let sorted = values.sorted { $0.0 < $1.0 }, threshold = values.reduce(0) { $0 + $1.1 } * 0.9
            var weight = 0.0
            for value in sorted { weight += value.1; if weight >= threshold { return value.0 } }
            return sorted.last?.0
        }
        return LUTAdaptationMetrics(introducedHighlights: high / total, introducedShadows: low / total,
            addedChroma: chroma / total, hueShift: hue / total,
            neutralTint: neutrals >= 8 ? neutral / neutrals : nil,
            skinHueP90Degrees: p90(skinHues), skinChromaGrowthP90: p90(skinGrowth),
            detailLoss: edges >= 8 ? lostEdges / edges : nil, meanChange: change / total)
    }

    static func sampleQualityViolations(_ m: LUTAdaptationMetrics, options: AdaptiveLUTSettings,
                                        colorDemand: Double, monochrome: Bool) -> [String] {
        var result: [String] = []
        // Small-raster threshold crossings can be created by resizing even when
        // every native pixel is safe. Native area + extrema decide clipping.
        if m.addedChroma > 0.16 - options.colorProtection * (0.08 + 0.03 * colorDemand) { result.append("新增高色度覆盖过多") }
        if !monochrome, m.hueShift > 0.24 - options.colorProtection * 0.12 { result.append("大幅色相变化覆盖过多") }
        if let value = m.neutralTint, value > 0.55 - options.colorProtection * 0.3 { result.append("中性候选染色过多") }
        if let value = m.skinHueP90Degrees, value > 38 - options.skinProtection * 23 { result.append("面部候选色相变化过大") }
        if let value = m.skinChromaGrowthP90, value > 0.10 - options.skinProtection * 0.065 { result.append("面部候选新增色度过大") }
        if let value = m.detailLoss, value > 0.70 - options.toneProtection * 0.35 { result.append("局部亮度层次损失过多") }
        return result
    }

    private static func lab(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = cbrt(0.4122214708*c.x + 0.5363325363*c.y + 0.0514459929*c.z)
        let m = cbrt(0.2119034982*c.x + 0.6806995451*c.y + 0.1073969566*c.z)
        let s = cbrt(0.0883024619*c.x + 0.2817188376*c.y + 0.6299787005*c.z)
        return SIMD3(0.2104542553*l + 0.793617785*m - 0.0040720468*s,
                     1.9779984951*l - 2.428592205*m + 0.4505937099*s,
                     0.0259040371*l + 0.7827717662*m - 0.808675766*s)
    }
}

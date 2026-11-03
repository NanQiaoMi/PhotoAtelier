import CoreGraphics
import CoreImage
import Foundation

/// Evidence for the automatic proposal only, before later manual edits,
/// geometry, local masks, LUTs and output gamut mapping.
public struct AutomaticSafetyReport: Codable, Equatable {
    public let retainedFraction: Double
    public let requestedHighlightFraction: Double
    public let introducedHighlightFraction: Double
    public let requestedShadowFraction: Double
    public let introducedShadowFraction: Double
    public let exposureDeltaEV: Double
    /// Actual zone increments after the same retained-fraction check.
    public let tonalDelta: TonalCurveSettings?
    public let summary: String
    public let scope: String
}

struct AutomaticSafetyResult {
    let settings: AdjustmentSettings
    let report: AutomaticSafetyReport
}

/// Uses the same global processing path as export. Thresholds are evaluated
/// before area reduction so small highlights cannot vanish during downsampling.
enum AutomaticSafetyEvaluator {
    private static let maximumIntroducedFraction = 0.005
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let thresholdKernel = CIColorKernel(source: """
    vec3 safetyTarget(vec3 c, float p3) {
        if (p3 < 0.5) { return c; }
        return vec3(0.8224619687 * c.r + 0.1775380313 * c.g,
                    0.0331941989 * c.r + 0.9668058011 * c.g,
                    0.0170826307 * c.r + 0.0723974407 * c.g + 0.9105199286 * c.b);
    }
    kernel vec4 automaticThresholds(__sample reference, __sample candidate, float p3) {
        float a = reference.a;
        // Alpha zero in this numeric mask is reserved for invalid visible data.
        // A separate minimum reduction rejects even one such pixel.
        if (!(a >= 0.0 && a <= 1.0)) { return vec4(0.0); }
        if (a <= 0.001) { return vec4(0.0, 0.0, 0.0, 1.0); }
        vec3 r = reference.rgb / a;
        vec3 c = candidate.a > 0.000001 ? candidate.rgb / candidate.a : vec3(0.0);
        if (!(candidate.a > 0.000001 && candidate.a <= 1.0
            && abs(r.r) <= 65504.0 && abs(r.g) <= 65504.0 && abs(r.b) <= 65504.0
            && abs(c.r) <= 65504.0 && abs(c.g) <= 65504.0 && abs(c.b) <= 65504.0)) {
            return vec4(0.0);
        }
        vec3 tr = safetyTarget(r, p3), tc = safetyTarget(c, p3);
        float high = ((tc.r >= 1.0 && tr.r < 1.0) || (tc.g >= 1.0 && tr.g < 1.0)
                   || (tc.b >= 1.0 && tr.b < 1.0)) ? 1.0 : 0.0;
        float y = dot(r, vec3(0.2126, 0.7152, 0.0722));
        float cy = dot(c, vec3(0.2126, 0.7152, 0.0722));
        float low = ((cy <= 0.002 && y > 0.002) || (tc.r < -0.0001 && tr.r >= -0.0001)
                  || (tc.g < -0.0001 && tr.g >= -0.0001)
                  || (tc.b < -0.0001 && tr.b >= -0.0001)) ? 1.0 : 0.0;
        float weight = clamp(a, 0.0, 1.0);
        // Alpha=1 keeps these numeric accumulators independent of premultiplication.
        return vec4(high * weight, low * weight, weight, 1.0);
    }
    """)

    static func limit(source: CIImage, baseline: AdjustmentSettings,
                      requested: AdjustmentSettings, engine: PhotoEngine) throws -> AutomaticSafetyResult {
        try PhotoEngine.validate(baseline)
        try PhotoEngine.validate(requested)
        let sample = try sampledSource(source, limit: 192)
        let referenceSettings = globalSettings(baseline)
        let reference = try engine.process(sample, settings: referenceSettings, lut: nil).image
        let referencePixels = pixels(reference, context: engine.context)
        let requiresAreaReduction = source.extent.width > 192 || source.extent.height > 192
        let nativeReference = requiresAreaReduction
            ? try engine.process(source, settings: referenceSettings, lut: nil).image : reference
        var requestedFractions: (highlights: Double, shadows: Double)?

        for fraction in [1.0, 0.75, 0.5, 0.25, 0.0] {
            let value = interpolate(baseline: baseline, requested: requested, fraction: fraction)
            let candidate = try engine.process(sample, settings: globalSettings(value), lut: nil).image
            let sampled = try introduced(reference: referencePixels,
                                         candidate: pixels(candidate, context: engine.context))
            let measured: (highlights: Double, shadows: Double)
            if requiresAreaReduction {
                let nativeCandidate = try engine.process(source, settings: globalSettings(value), lut: nil).image
                measured = try areaFractions(reference: nativeReference, candidate: nativeCandidate,
                                             context: engine.context)
            } else { measured = sampled }
            if requestedFractions == nil { requestedFractions = measured }
            guard measured.highlights <= maximumIntroducedFraction + 1e-9,
                  measured.shadows <= maximumIntroducedFraction + 1e-9 else { continue }
            let initial = requestedFractions!
            let summary = fraction == 1
                ? "自动增量通过渲染阈值检查；仍需比较主体、层次和拍摄意图。"
                : String(format: "自动增量减弱至 %.0f%%：原建议新增高光越界 %.2f%%、黑位或负通道 %.2f%%。", fraction * 100, initial.highlights * 100, initial.shadows * 100)
            let report = AutomaticSafetyReport(
                retainedFraction: fraction,
                requestedHighlightFraction: initial.highlights,
                introducedHighlightFraction: measured.highlights,
                requestedShadowFraction: initial.shadows,
                introducedShadowFraction: measured.shadows,
                exposureDeltaEV: value.exposureEV - baseline.exposureEV,
                tonalDelta: TonalAdjustmentMath.difference(from: baseline.tonalCurve, to: value.tonalCurve),
                summary: summary,
                scope: "仅检查自动基础增量：在本次输入 \(Int(ceil(source.extent.width)))×\(Int(ceil(source.extent.height))) 的基础渲染上判定阈值后作面积统计，alpha 加权；新增 SDR 1.0 通道越界和 Y≤0.002 黑位或负通道各不超过 0.5%。原尺寸检查异常可见像素，另以最长边 192 取样复核。预览输入可能已缩小，导出按原图重新检查；比例受浮点归约精度影响。不含后续手调、LUT、几何、局部蒙版或质感滤镜；不是审美评分或传感器剪切检测。")
            return AutomaticSafetyResult(settings: value, report: report)
        }
        // At zero increment the two processing graphs are identical. Reaching
        // here means the reference cannot be checked reliably; do not approve it.
        throw AtelierError.invalidConfiguration("自动基础调整无法通过像素安全检查，请保留原参数并手动比较。")
    }

    static func areaFractions(reference: CIImage, candidate: CIImage, context: CIContext,
                              outputColorSpace: OutputColorSpace? = nil) throws
        -> (highlights: Double, shadows: Double) {
        guard let kernel = thresholdKernel,
              let flags = kernel.apply(extent: reference.extent, arguments: [reference, candidate,
                NSNumber(value: outputColorSpace == .displayP3 ? 1 : 0)]) else {
            throw AtelierError.invalidConfiguration("无法建立原尺寸自动基础调整阈值图。")
        }
        let region = [kCIInputExtentKey: CIVector(cgRect: reference.extent)]
        let minimum = flags.applyingFilter("CIAreaMinimum", parameters: region)
        var values = [Float](repeating: 0, count: 4)
        func render(_ image: CIImage) {
            values.withUnsafeMutableBytes { buffer in
                context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 16,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            }
        }
        render(minimum)
        guard values.allSatisfy(\.isFinite), values[3] >= 0.9999 else {
            throw AtelierError.invalidConfiguration("原尺寸基础渲染含异常可见像素，已停止自动建议。")
        }
        let average = flags.applyingFilter("CIAreaAverage", parameters: region)
        render(average)
        guard values.allSatisfy(\.isFinite), values[2] > 0 else {
            throw AtelierError.invalidConfiguration("自动基础调整的面积统计无有效可见像素。")
        }
        return (min(1, max(0, Double(values[0]) / Double(values[2]))),
                min(1, max(0, Double(values[1]) / Double(values[2]))))
    }

    static func globalSettings(_ settings: AdjustmentSettings) -> AdjustmentSettings {
        var value = settings
        value.autoExposure = false
        value.lensCorrection = false
        value.autoStraighten = false
        value.rotationDegrees = 0
        value.verticalPerspective = 0
        value.horizontalPerspective = 0
        value.masks = []
        value.creativeEffects = nil
        value.adaptiveLUT = nil
        return value
    }

    /// Checks extrema of the native threshold map, preserving even isolated
    /// highlights that an area-fraction tolerance would otherwise accept.
    static func hasIntroducedClipping(reference: CIImage, candidate: CIImage, context: CIContext,
                                       outputColorSpace: OutputColorSpace? = nil) throws -> Bool {
        guard let kernel = thresholdKernel,
              let flags = kernel.apply(extent: reference.extent, arguments: [reference, candidate,
                NSNumber(value: outputColorSpace == .displayP3 ? 1 : 0)]) else {
            throw AtelierError.invalidConfiguration("无法建立原尺寸剪切极值检查。")
        }
        let maximum = flags.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: reference.extent)])
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { buffer in
            context.render(maximum, toBitmap: buffer.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        }
        guard values.allSatisfy(\.isFinite) else {
            throw AtelierError.invalidConfiguration("原尺寸剪切极值检查产生异常数值。")
        }
        return values[0] > 0.000001 || values[1] > 0.000001
    }

    static func sampledSource(_ image: CIImage, limit: Int) throws -> CIImage {
        let extent = image.extent
        guard !extent.isNull, !extent.isInfinite, extent.origin.x.isFinite, extent.origin.y.isFinite,
              extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
            throw AtelierError.invalidConfiguration("自动安全检查需要有限且非空的图像范围。")
        }
        let scale = min(1, CGFloat(limit) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded(.up)))
        let height = max(1, Int((extent.height * scale).rounded(.up)))
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func interpolate(baseline: AdjustmentSettings, requested: AdjustmentSettings,
                                    fraction: Double) -> AdjustmentSettings {
        var value = requested
        func blend(_ from: Double, _ to: Double) -> Double { from + (to - from) * fraction }
        value.exposureEV = blend(baseline.exposureEV, requested.exposureEV)
        value.temperature = blend(baseline.temperature, requested.temperature)
        value.tint = blend(baseline.tint, requested.tint)
        value.contrast = blend(baseline.contrast, requested.contrast)
        value.saturation = blend(baseline.saturation, requested.saturation)
        value.highlights = blend(baseline.highlights, requested.highlights)
        value.shadows = blend(baseline.shadows, requested.shadows)
        value.tonalCurve = TonalAdjustmentMath.interpolate(from: baseline.tonalCurve,
                                                          to: requested.tonalCurve, fraction: fraction)
        value.autoExposure = false
        value.autoWhiteBalance = baseline.autoWhiteBalance
        return value
    }

    private static func pixels(_ image: CIImage, context: CIContext) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var values = [Float](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: image.extent, format: .RGBAf, colorSpace: space)
        }
        return values
    }

    private static func introduced(reference: [Float], candidate: [Float]) throws
        -> (highlights: Double, shadows: Double) {
        guard reference.count == candidate.count else {
            throw AtelierError.invalidConfiguration("自动安全检查的像素参考尺寸不匹配。")
        }
        var total = 0.0, highlights = 0.0, shadows = 0.0
        for index in stride(from: 0, to: reference.count, by: 4) {
            let alpha = Double(reference[index + 3])
            guard alpha.isFinite else { throw AtelierError.invalidConfiguration("安全检查遇到非有限透明度。") }
            guard alpha > 0.001 else { continue }
            let r = Double(reference[index]), g = Double(reference[index + 1]), b = Double(reference[index + 2])
            let cr = Double(candidate[index]), cg = Double(candidate[index + 1]), cb = Double(candidate[index + 2])
            guard [r, g, b, cr, cg, cb, Double(candidate[index + 3])].allSatisfy(\.isFinite) else {
                throw AtelierError.invalidConfiguration("自动基础调整产生非有限像素，已停止建议。")
            }
            let weight = min(1, alpha)
            total += weight
            if (cr >= 1 && r < 1) || (cg >= 1 && g < 1) || (cb >= 1 && b < 1) { highlights += weight }
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let cy = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb
            if (cy <= 0.002 && y > 0.002) || (cr < -0.0001 && r >= -0.0001)
                || (cg < -0.0001 && g >= -0.0001) || (cb < -0.0001 && b >= -0.0001) { shadows += weight }
        }
        guard total > 0 else { throw AtelierError.invalidConfiguration("照片没有可检查的非透明有限像素。") }
        return (highlights / total, shadows / total)
    }
}

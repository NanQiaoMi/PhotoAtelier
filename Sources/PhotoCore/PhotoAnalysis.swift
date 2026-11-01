import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

public enum PhotoAnalysisSeverity: String, Codable, CaseIterable {
    case info
    case low
    case moderate
    case high
}

public struct PhotoAnalysisFinding: Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let evidence: String
    public let direction: String
    public let severity: PhotoAnalysisSeverity
}

public struct PhotoAnalysisMetrics: Codable, Equatable {
    public let sampleWidth: Int
    public let sampleHeight: Int
    public let sampleCount: Int
    public let medianLuminance: Double
    public let p05Luminance: Double
    public let p95Luminance: Double
    public let p99Luminance: Double
    /// Fraction at or below 0.002 linear-light luminance; a display reference, not sensor black clipping.
    public let nearBlackFraction: Double
    /// Fraction with any extended-linear-sRGB channel at or above 0.985; not proof of clipping or recoverability.
    public let nearWhiteFraction: Double
    /// Fraction with any extended-linear-sRGB channel at or above SDR reference white (1.0).
    public let overDisplayWhiteFraction: Double
    public let dynamicRangeStops: Double
    /// Positive values mean the measured median is brighter than 18% linear gray.
    public let medianExposureFrom18PercentGrayEV: Double
    public let meanRed: Double
    public let meanGreen: Double
    public let meanBlue: Double
    public let neutralMeanRed: Double?
    public let neutralMeanGreen: Double?
    public let neutralMeanBlue: Double?
    /// Relative R-B and G-(R+B)/2 channel differences among neutral candidates.
    public let neutralWarmCast: Double?
    public let neutralGreenCast: Double?
    public let neutralSampleCount: Int
    public let neutralSampleFraction: Double
    public let meanSaturation: Double
    /// Fractions in 64 linear-luminance bins from 0 through 1.
    public let histogram: [Double]
    public let faceCount: Int
    /// Rule support score for these heuristics, not a probability or exposure accuracy.
    public let analysisConfidence: Double
}

public struct PhotoAnalysisMetadataItem: Codable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let value: String
}

public struct PhotoContentLabel: Codable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let confidence: Double
    public let source: String
}

public struct AutoAdjustmentProposal: Codable, Equatable, Identifiable {
    /// Stable across photos so batch automation can re-run a selected style per image.
    public let id: String
    public let title: String
    public let rationale: String
    public let confidence: Double
    public let confidenceBasis: String
    public let settings: AdjustmentSettings
    /// Optional so analyses written before automatic pixel checks still decode.
    public let safety: AutomaticSafetyReport?
}

public struct PhotoAnalysis: Codable, Equatable {
    public let summary: String
    public let issues: [PhotoAnalysisFinding]
    public let metrics: PhotoAnalysisMetrics
    /// Visible-pixel color distribution and positional guidance. Optional so
    /// analysis files created before scene analysis continue to decode.
    public let colorScene: ColorSceneProfile?
    public let metadata: [PhotoAnalysisMetadataItem]
    public let content: [PhotoContentLabel]
    public let proposals: [AutoAdjustmentProposal]
    /// Measurements that are absent or unsupported are listed here explicitly.
    public let unsupportedReadings: [String]
}

/// Pixel and metadata analysis for a single already-decoded image.
/// It never infers capture Kelvin from rendered RGB values.
public final class PhotoAnalyzer {
    private static let sampleLimit = 384
    private static let histogramBins = 64
    private let context: CIContext
    private let workingSpace: CGColorSpace
    private let engine = PhotoEngine()

    public init() {
        let working = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        self.workingSpace = working
        self.context = CIContext(options: [
            .workingColorSpace: working,
            .outputColorSpace: working,
            .workingFormat: CIFormat.RGBAf,
            .outputPremultiplied: false,
            .cacheIntermediates: false
        ])
    }

    public func analyze(image: CIImage,
                        properties: [String: Any],
                        sourceURL: URL? = nil,
                        baseline: AdjustmentSettings = .init()) throws -> PhotoAnalysis {
        try PhotoEngine.validate(baseline)
        let measured = try measure(image)
        let pixelMetrics = measured.metrics
        let vision = inspectContent(measured.image)
        let colorScene = try ColorSceneAnalyzer.analyze(image: image, context: context)
        let metrics = makeMetrics(pixelMetrics, faceCount: vision.faces.count)
        // Report the source measurements, but make suggestions from the user's
        // existing global result. Measuring the source and adding that correction
        // to an already brightened baseline would correct the same need twice.
        let globalReference = try engine.process(measured.image,
            settings: AutomaticSafetyEvaluator.globalSettings(baseline), lut: nil).image
        let adjustedMeasurements = try measure(globalReference).metrics
        let proposalMetrics = makeMetrics(adjustedMeasurements, faceCount: vision.faces.count)
        let proposalColors = try ColorSceneAnalyzer.analyze(image: globalReference, context: context)

        var unsupported: [String] = []
        var metadata = makeMetadata(image: image, properties: properties, sourceURL: sourceURL,
                                    unsupported: &unsupported)
        metadata.sort { $0.id < $1.id }
        if !pixelMetrics.neutralReliable {
            unsupported.append("未找到足量近中性候选；无法据此确定白平衡误差，保留用户的白平衡选择。")
        }
        unsupported.append("近中性 RGB 不能区分物体本色、现场灯光与白平衡误差；自动方案保留原有白平衡、冷暖和色调，不自行中和。")
        if properties["PhotoAtelierRAWAnalysis"] != nil {
            unsupported.append("RAW 高光指标基于解码后的线性 RGB 与 SDR 1.0 显示参考比较，不代表原始 sensel 饱和；未逐 sensel 读取黑白电平或噪声。")
        }
        unsupported.append(contentsOf: vision.failures)

        let issues = makeFindings(metrics: metrics, neutralReliable: pixelMetrics.neutralReliable,
                                  vision: vision)
        let proposals = try makeProposals(metrics: proposalMetrics, baseline: baseline,
                                          source: image, colorScene: proposalColors)
        let summary = makeSummary(metrics: metrics, proposal: proposals[0],
                                  vision: vision, colorScene: colorScene)
        return PhotoAnalysis(summary: summary, issues: issues, metrics: metrics,
                             colorScene: colorScene,
                             metadata: metadata, content: vision.labels,
                             proposals: proposals, unsupportedReadings: Array(Set(unsupported)).sorted())
    }

    private func makeMetrics(_ pixelMetrics: PixelMeasurements, faceCount: Int) -> PhotoAnalysisMetrics {
        PhotoAnalysisMetrics(
            sampleWidth: pixelMetrics.width,
            sampleHeight: pixelMetrics.height,
            sampleCount: pixelMetrics.count,
            medianLuminance: pixelMetrics.median,
            p05Luminance: pixelMetrics.p05,
            p95Luminance: pixelMetrics.p95,
            p99Luminance: pixelMetrics.p99,
            nearBlackFraction: pixelMetrics.nearBlackFraction,
            nearWhiteFraction: pixelMetrics.nearWhiteFraction,
            overDisplayWhiteFraction: pixelMetrics.overDisplayWhiteFraction,
            dynamicRangeStops: pixelMetrics.dynamicRangeStops,
            medianExposureFrom18PercentGrayEV: pixelMetrics.medianEV,
            meanRed: pixelMetrics.meanRed,
            meanGreen: pixelMetrics.meanGreen,
            meanBlue: pixelMetrics.meanBlue,
            neutralMeanRed: pixelMetrics.neutralMeanRed,
            neutralMeanGreen: pixelMetrics.neutralMeanGreen,
            neutralMeanBlue: pixelMetrics.neutralMeanBlue,
            neutralWarmCast: pixelMetrics.neutralWarmCast,
            neutralGreenCast: pixelMetrics.neutralGreenCast,
            neutralSampleCount: pixelMetrics.neutralCount,
            neutralSampleFraction: pixelMetrics.neutralFraction,
            meanSaturation: pixelMetrics.meanSaturation,
            histogram: pixelMetrics.histogram,
            faceCount: faceCount,
            analysisConfidence: pixelMetrics.confidence
        )
    }

    private struct PixelMeasurements {
        let width: Int
        let height: Int
        let count: Int
        let median: Double
        let p05: Double
        let p95: Double
        let p99: Double
        let nearBlackFraction: Double
        let nearWhiteFraction: Double
        let overDisplayWhiteFraction: Double
        let dynamicRangeStops: Double
        let medianEV: Double
        let meanRed: Double
        let meanGreen: Double
        let meanBlue: Double
        let neutralMeanRed: Double?
        let neutralMeanGreen: Double?
        let neutralMeanBlue: Double?
        let neutralWarmCast: Double?
        let neutralGreenCast: Double?
        let neutralCount: Int
        let neutralFraction: Double
        let neutralReliable: Bool
        let meanSaturation: Double
        let histogram: [Double]
        let confidence: Double
    }

    private struct VisionResult {
        var faces: [VNFaceObservation] = []
        var labels: [PhotoContentLabel] = []
        var failures: [String] = []
    }

    private func measure(_ image: CIImage) throws -> (metrics: PixelMeasurements, image: CIImage) {
        let extent = image.extent
        guard !extent.isNull, !extent.isInfinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else {
            throw AtelierError.invalidConfiguration("照片必须有有限且非空的图像范围，无法分析。")
        }

        let scale = min(1, CGFloat(Self.sampleLimit) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded(.up)))
        let height = max(1, Int((extent.height * scale).rounded(.up)))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let translated = image.transformed(by: CGAffineTransform(translationX: -extent.minX,
                                                                  y: -extent.minY))
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let sampledImage = scaled.cropped(to: bounds)
        let componentCount = width.multipliedReportingOverflow(by: height)
        guard !componentCount.overflow, componentCount.partialValue > 0,
              componentCount.partialValue <= Self.sampleLimit * Self.sampleLimit else {
            throw AtelierError.invalidConfiguration("照片分析采样尺寸无效。")
        }
        let floatCount = componentCount.partialValue.multipliedReportingOverflow(by: 4)
        guard !floatCount.overflow else { throw AtelierError.invalidConfiguration("照片分析采样缓冲区过大。") }
        var pixels = [Float](repeating: 0, count: floatCount.partialValue)
        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            context.render(sampledImage, toBitmap: baseAddress,
                           rowBytes: width * 4 * MemoryLayout<Float>.stride,
                           bounds: bounds, format: .RGBAf, colorSpace: workingSpace)
        }

        var luminances: [Double] = []
        luminances.reserveCapacity(componentCount.partialValue)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, sumSaturation = 0.0
        var neutralR = 0.0, neutralG = 0.0, neutralB = 0.0
        var neutralCount = 0
        var nearBlackCount = 0, nearWhiteCount = 0, overDisplayWhiteCount = 0
        var histogram = Array(repeating: 0.0, count: Self.histogramBins)

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3])
            guard alpha.isFinite, alpha > 0.001 else { continue }
            // This context renders unpremultiplied RGBA. Dividing these channels
            // by alpha again brightened translucent pixels and corrupted every
            // downstream color/luminance measurement.
            let red = Double(pixels[offset])
            let green = Double(pixels[offset + 1])
            let blue = Double(pixels[offset + 2])
            guard red.isFinite, green.isFinite, blue.isFinite else { continue }

            let luminance = max(0, 0.2126 * red + 0.7152 * green + 0.0722 * blue)
            let maximum = max(red, max(green, blue))
            let minimum = min(red, min(green, blue))
            let saturation = maximum > 0.0001 ? min(1, max(0, (maximum - minimum) / maximum)) : 0
            luminances.append(luminance)
            sumR += red; sumG += green; sumB += blue; sumSaturation += saturation
            if luminance <= 0.002 { nearBlackCount += 1 }
            if maximum >= 0.985 { nearWhiteCount += 1 }
            if maximum >= 1.0 { overDisplayWhiteCount += 1 }
            let bin = min(Self.histogramBins - 1, Int(min(1, luminance) * Double(Self.histogramBins - 1)))
            histogram[bin] += 1

            let neutralSpread = maximum - minimum
            if luminance >= 0.04, luminance <= 0.85, maximum > 0.0001,
               neutralSpread <= max(0.025, maximum * 0.075) {
                neutralR += red; neutralG += green; neutralB += blue
                neutralCount += 1
            }
        }

        guard !luminances.isEmpty else {
            throw AtelierError.invalidConfiguration("照片没有可分析的非透明有限像素。")
        }
        let denominator = Double(luminances.count)
        let sortedLuminances = luminances.sorted()
        let p05 = percentile(sortedLuminances, fraction: 0.05)
        let median = percentile(sortedLuminances, fraction: 0.50)
        let p95 = percentile(sortedLuminances, fraction: 0.95)
        let p99 = percentile(sortedLuminances, fraction: 0.99)
        let dynamicRange = log2(max(p95, 0.0001) / max(p05, 0.0001))
        let medianEV = log2(max(median, 0.0001) / 0.18)
        for index in histogram.indices { histogram[index] /= denominator }
        let neutralFraction = Double(neutralCount) / denominator
        let neutralReliable = neutralCount >= max(8, Int(denominator * 0.002))
        let neutralAverageR = neutralCount > 0 ? neutralR / Double(neutralCount) : nil
        let neutralAverageG = neutralCount > 0 ? neutralG / Double(neutralCount) : nil
        let neutralAverageB = neutralCount > 0 ? neutralB / Double(neutralCount) : nil
        let neutralMean = (neutralAverageR ?? 0) + (neutralAverageG ?? 0) + (neutralAverageB ?? 0)
        let warmCast: Double? = neutralCount > 0 && neutralMean > 0.0001
            ? ((neutralAverageR! - neutralAverageB!) / (neutralMean / 3)) : nil
        let greenCast: Double? = neutralCount > 0 && neutralMean > 0.0001
            ? ((neutralAverageG! - (neutralAverageR! + neutralAverageB!) / 2) / (neutralMean / 3)) : nil
        let confidence = min(0.93, 0.55 + 0.30 * min(1, sqrt(denominator / Double(Self.sampleLimit * Self.sampleLimit)))
                             + (neutralReliable ? 0.08 : 0))

        let metrics = PixelMeasurements(width: width, height: height, count: luminances.count,
                                        median: median, p05: p05, p95: p95, p99: p99,
                                        nearBlackFraction: Double(nearBlackCount) / denominator,
                                        nearWhiteFraction: Double(nearWhiteCount) / denominator,
                                        overDisplayWhiteFraction: Double(overDisplayWhiteCount) / denominator,
                                        dynamicRangeStops: max(0, dynamicRange), medianEV: medianEV,
                                        meanRed: sumR / denominator, meanGreen: sumG / denominator,
                                        meanBlue: sumB / denominator,
                                        neutralMeanRed: neutralAverageR, neutralMeanGreen: neutralAverageG,
                                        neutralMeanBlue: neutralAverageB, neutralWarmCast: warmCast,
                                        neutralGreenCast: greenCast, neutralCount: neutralCount,
                                        neutralFraction: neutralFraction, neutralReliable: neutralReliable,
                                        meanSaturation: sumSaturation / denominator,
                                        histogram: histogram, confidence: confidence)
        return (metrics, sampledImage)
    }

    private func inspectContent(_ image: CIImage) -> VisionResult {
        var result = VisionResult()
        let faceRequest = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(ciImage: image, options: [:]).perform([faceRequest])
            result.faces = faceRequest.results ?? []
        } catch {
            result.failures.append("本机 Vision 人脸检测不可用；未生成面部结论。")
        }

        let classification = VNClassifyImageRequest()
        do {
            try VNImageRequestHandler(ciImage: image, options: [:]).perform([classification])
            result.labels = (classification.results ?? []).prefix(5).compactMap { observation in
                guard observation.confidence >= 0.05, observation.confidence.isFinite else { return nil }
                return PhotoContentLabel(id: "vision.\(observation.identifier)",
                                         label: observation.identifier,
                                         confidence: min(1, max(0, Double(observation.confidence))),
                                         source: "本机 Vision")
            }
        } catch {
            result.failures.append("本机 Vision 场景分类不可用；未生成场景标签。")
        }
        if !result.faces.isEmpty {
            let confidence = result.faces.map { Double($0.confidence) }.reduce(0, +) / Double(result.faces.count)
            result.labels.append(PhotoContentLabel(id: "vision.faces",
                                                   label: "检测到 \(result.faces.count) 张人脸",
                                                   confidence: min(1, max(0, confidence)),
                                                   source: "本机 Vision 人脸检测"))
        }
        return result
    }

    private func makeMetadata(image: CIImage, properties: [String: Any], sourceURL: URL?,
                              unsupported: inout [String]) -> [PhotoAnalysisMetadataItem] {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        func add(_ id: String, _ label: String, _ value: String) -> PhotoAnalysisMetadataItem {
            PhotoAnalysisMetadataItem(id: id, label: label, value: value)
        }
        func numberText(_ value: Any?, suffix: String = "") -> String? {
            guard let value = numericValue(value), value.isFinite else { return nil }
            return String(format: "%.3g", value) + suffix
        }
        func unavailable(_ field: String) -> String {
            unsupported.append("\(field) 未在可读取的图像元数据中提供。")
            return "未知（元数据未提供）"
        }

        let rawAnalysis = properties["PhotoAtelierRAWAnalysis"] as? [String: Any]
        let originalRawWhiteBalance = rawAnalysis?["originalEXIFWhiteBalance"] as? [String: Any]

        let make = stringValue(tiff["Make"])
        let model = stringValue(tiff["Model"])
        let camera = [make, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let cameraValue = camera.isEmpty ? unavailable("相机品牌/型号") : camera
        let iso: String
        if let value = exif["ISOSpeedRatings"] as? [Any], !value.isEmpty {
            iso = value.compactMap { numberText($0) }.joined(separator: ", ")
        } else if let value = numberText(exif["ISOSpeedRatings"]) {
            iso = value
        } else { iso = unavailable("ISO") }
        let shutter: String
        if let seconds = numericValue(exif["ExposureTime"]), seconds.isFinite, seconds > 0 {
            let reciprocal = 1 / seconds
            if reciprocal >= 1, abs(reciprocal.rounded() - reciprocal) < 0.02 {
                shutter = "1/\(Int(reciprocal.rounded())) 秒"
            } else { shutter = String(format: "%.4g 秒", seconds) }
        } else { shutter = unavailable("快门时间") }
        let aperture = numberText(exif["FNumber"]).map { "f/\($0)" } ?? unavailable("光圈")
        let focalLength = numberText(exif["FocalLength"], suffix: " mm") ?? unavailable("实际焦距")
        let width = numericValue(properties[kCGImagePropertyPixelWidth as String]) ?? Double(image.extent.width)
        let height = numericValue(properties[kCGImagePropertyPixelHeight as String]) ?? Double(image.extent.height)
        let dimensions = "\(Int(max(1, width.rounded()))) × \(Int(max(1, height.rounded()))) px"
        let depthValue: String?
        if let depth = numberText(properties["Depth"] ?? properties["BitsPerPixel"]) {
            depthValue = "\(depth) bit"
        } else if let channelDepths = properties["BitsPerSample"] as? [Any] {
            let values = channelDepths.compactMap { numberText($0) }
            depthValue = values.isEmpty ? nil : "\(Set(values).sorted().joined(separator: "/")) bit/channel"
        } else if let depth = numberText(properties["BitsPerSample"]) {
            depthValue = "\(depth) bit/channel"
        } else { depthValue = nil }
        let depth = depthValue ?? unavailable("源文件位深")
        let decoderSpace = (image.colorSpace?.name as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageSpace = (decoderSpace?.isEmpty == false ? decoderSpace! : "未知（解码色彩空间未命名）")
        let profileName = stringValue(properties["ProfileName"]) ?? stringValue(properties["ICCProfileName"])
            ?? stringValue(tiff["ProfileName"])
        let hasICCData = properties["ICCProfile"] != nil
        let iccValue = profileName ?? (hasICCData ? "存在 ICC 配置数据，但未读取到其名称" : "未读取到 ICC 配置文件名称")
        if profileName == nil && !hasICCData {
            unsupported.append("未读取到源文件 ICC 配置文件名称或数据；下方仅报告解码图像色彩空间。")
        }
        let whiteBalanceMode: String
        if let raw = numericValue(originalRawWhiteBalance?["mode"] ?? exif["WhiteBalance"]) {
            whiteBalanceMode = raw == 0 ? "自动" : (raw == 1 ? "手动" : "EXIF 值 \(Int(raw))")
        } else { whiteBalanceMode = unavailable("拍摄白平衡模式") }

        var sourceKind = "静态图像（来源类型未知）"
        if let sourceURL {
            let ext = sourceURL.pathExtension.lowercased()
            let rawExtensions: Set<String> = ["dng", "arw", "nef", "nrw", "cr2", "cr3", "raf", "rw2", "orf", "pef", "srw"]
            if rawExtensions.contains(ext) { sourceKind = "RAW 文件（按扩展名识别；基于当前解码图像分析）" }
            else if ["jpg", "jpeg"].contains(ext) { sourceKind = "JPEG 静态成片（扩展名不证明相机来源）" }
            else if ext == "png" { sourceKind = "PNG 静态图像" }
            else if ["tif", "tiff"].contains(ext) { sourceKind = "TIFF 静态图像" }
        } else {
            unsupported.append("未提供源文件路径，无法按文件类型区分 RAW 与相机 JPEG。")
        }

        var result = [
            add("source.kind", "文件类型", sourceKind),
            add("camera", "相机", cameraValue),
            add("iso", "ISO", iso),
            add("shutter", "快门", shutter),
            add("aperture", "光圈", aperture),
            add("focalLength", "实际焦距", focalLength),
            add("dimensions", "当前解码图像尺寸", dimensions),
            add("bitDepth", rawAnalysis == nil ? "源文件位深" : "RAW 解码容器位深（非传感器 ADC 位深）", depth),
            add("colorSpace", "解码图像色彩空间", imageSpace),
            add("iccProfile", rawAnalysis == nil ? "ICC 配置文件" : "RAW 解码配置（非相机原始 ICC）", iccValue),
            add("whiteBalanceMode", "拍摄白平衡模式", whiteBalanceMode)
        ]
        if let rawAnalysis, let baseline = numericValue(rawAnalysis["baselineExposureEV"]), baseline.isFinite {
            result.append(add("rawBaselineExposure", "RAW 解码器基准曝光（保留相机归一化）", String(format: "%+.2f EV", baseline)))
        }

        // Capture Kelvin is a separate claim from rendered pixel color. Only the
        // RAW develop pipeline may supply a decoder white-point estimate.
        let rawKelvin = rawDecoderWhitePoint(rawAnalysis)
        if let rawKelvin {
            result.append(add("captureKelvin", rawKelvin.label, String(format: "%.0f K", rawKelvin.temperature)))
            if let tint = rawKelvin.tint {
                result.append(add("rawDecoderTint", "RAW 解码器色调估计", String(format: "%+.3g", tint)))
            }
        } else {
            result.append(add("captureKelvin", "拍摄色温 Kelvin", "未知（未提供拍摄 Kelvin；不会从 RGB 推断）"))
            unsupported.append("拍摄色温 Kelvin 未提供；不会从成片 RGB 通道反推拍摄温度。")
        }
        return result
    }

    private func rawDecoderWhitePoint(_ rawAnalysis: [String: Any]?) -> (temperature: Double, tint: Double?, label: String)? {
        // Values are explicitly tagged by the RAW development pipeline. Capture
        // Kelvin from EXIF is not standardized and is never guessed from pixels.
        guard let rawAnalysis,
              stringValue(rawAnalysis["decoder"]) == "CIRAWFilter",
              let whiteBalance = rawAnalysis["asShotWhiteBalance"] as? [String: Any],
              stringValue(whiteBalance["provenance"]) == "decoderEstimated" else { return nil }
        let temperatureValue = whiteBalance["temperatureKelvin"]
        guard let temperature = numericValue(temperatureValue),
              temperature.isFinite, (1_000...50_000).contains(temperature) else { return nil }
        let tint = numericValue(whiteBalance["tint"])
        let label = stringValue(whiteBalance["label"]) ?? "RAW解码器白点估计"
        return (temperature, tint.flatMap { $0.isFinite ? $0 : nil }, label)
    }

    private func makeFindings(metrics: PhotoAnalysisMetrics, neutralReliable: Bool,
                              vision: VisionResult) -> [PhotoAnalysisFinding] {
        var findings: [PhotoAnalysisFinding] = []
        let correction = -metrics.medianExposureFrom18PercentGrayEV
        if metrics.medianLuminance < 0.025 {
            findings.append(PhotoAnalysisFinding(id: "exposure.lowKeyScene", title: "极低中位亮度（相对 18% 灰参考）",
                                                 evidence: String(format: "P50 亮度 %.4f；低亮度可能来自夜景、剪影或有意压暗，不能单凭此值断言曝光错误。", metrics.medianLuminance),
                                                 direction: "建议只预览受限的逐张曝光变化，并确认主体与暗部意图。",
                                                 severity: .low))
        } else if metrics.medianLuminance > 0.82 {
            findings.append(PhotoAnalysisFinding(id: "exposure.highKeyScene", title: "高亮中位亮度（相对 18% 灰参考）",
                                                 evidence: String(format: "P50 亮度 %.3f（高于参考 %.2f EV）；高调、雪景或背光场景可能合理，不能单凭此值断言曝光错误。", metrics.medianLuminance, -correction),
                                                 direction: "避免把高调画面强行归一到中灰；建议以预览和主体细节判断。",
                                                 severity: .low))
        } else if correction > 0.3 {
            findings.append(PhotoAnalysisFinding(id: "exposure.dark", title: "中位亮度低于 18% 灰参考",
                                                 evidence: String(format: "中位亮度 %.3f（线性光），相对 18%% 灰低 %.2f EV；基于 %d 个有效样本。此为灰阶相对值，不单独证明曝光错误。", metrics.medianLuminance, correction, metrics.sampleCount),
                                                 direction: metrics.nearWhiteFraction > 0.01
                                                    ? "可小幅提升曝光并检查高光；近白像素已较多。"
                                                    : "可预览有限的曝光增量；先确认暗调是否出于拍摄意图。",
                                                 severity: correction > 1.2 ? .high : .moderate))
        } else if correction < -0.3 {
            findings.append(PhotoAnalysisFinding(id: "exposure.bright", title: "中位亮度高于 18% 灰参考",
                                                 evidence: String(format: "中位亮度 %.3f（线性光），相对参考高 %.2f EV；高调场景可能合理，不单独证明曝光错误。", metrics.medianLuminance, -correction),
                                                 direction: "可降低曝光，并优先检查高光是否仍保留层次。",
                                                 severity: metrics.nearWhiteFraction > 0.03 ? .high : .moderate))
        } else {
            findings.append(PhotoAnalysisFinding(id: "exposure.nearReference", title: "整体亮度接近参考区间",
                                                 evidence: String(format: "中位亮度 %.3f（线性光），相对 18%% 灰差值 %.2f EV。", metrics.medianLuminance, metrics.medianExposureFrom18PercentGrayEV),
                                                 direction: "曝光建议保持克制；可按主体和场景微调。", severity: .info))
        }

        if metrics.nearBlackFraction >= 0.02 {
            findings.append(PhotoAnalysisFinding(id: "level.nearBlack", title: "暗部接近显示黑位参考",
                                                 evidence: String(format: "%.1f%% 样本的解码线性亮度不高于 0.002；这不测量原始感光单元黑电平。", metrics.nearBlackFraction * 100),
                                                 direction: "可预览适度提升阴影；仅凭该指标不能判断原始暗部信息是否可恢复。",
                                                 severity: metrics.nearBlackFraction >= 0.12 ? .high : .moderate))
        }
        if metrics.nearWhiteFraction >= 0.01 {
            findings.append(PhotoAnalysisFinding(id: "level.nearWhite", title: "样本接近显示参考白位",
                                                 evidence: String(format: "%.1f%% 样本至少有一个扩展线性 RGB 通道达到 SDR 1.0 参考的 0.985；%.1f%% 实际达到或越过 1.0。两者都不等同原始感光单元饱和、剪切或可恢复性。", metrics.nearWhiteFraction * 100, metrics.overDisplayWhiteFraction * 100),
                                                 direction: "避免仅根据该比例继续提亮；在预览中检查高光细节与风格意图。",
                                                 severity: metrics.nearWhiteFraction >= 0.08 ? .high : .moderate))
        }
        if metrics.dynamicRangeStops < 2.5 || metrics.dynamicRangeStops > 8.5 {
            findings.append(PhotoAnalysisFinding(id: "contrast.range", title: metrics.dynamicRangeStops < 2.5 ? "像素对比范围较窄" : "亮度跨度较大",
                                                 evidence: String(format: "P05–P95 亮度范围约 %.2f EV；场景本身也会影响此指标。", metrics.dynamicRangeStops),
                                                 direction: metrics.dynamicRangeStops < 2.5
                                                    ? "保留雾景或柔光的低对比感；自动方案不因范围较窄而增加对比度。"
                                                    : "可降低对比度并单独收回高光、抬起阴影，避免压掉细节。",
                                                 severity: .low))
        }

        if neutralReliable, let warm = metrics.neutralWarmCast, let green = metrics.neutralGreenCast {
            let cast = max(abs(warm), abs(green))
            findings.append(PhotoAnalysisFinding(id: "whiteBalance.neutralSamples",
                                                 title: cast > 0.08 ? "近中性候选存在通道偏差" : "检测到近中性候选",
                                                 evidence: String(format: "%d 个中性候选（占 %.2f%%）；R-B 相对偏差 %+.3f，G 偏差 %+.3f。", metrics.neutralSampleCount, metrics.neutralSampleFraction * 100, warm, green),
                                                 direction: "近灰像素可能来自物体本色或有意灯光，不能证明白平衡错误。默认保留拍摄白点；确认参照后可手动开启有限自动白平衡。",
                                                 severity: cast > 0.15 ? .moderate : .info))
        } else {
            findings.append(PhotoAnalysisFinding(id: "whiteBalance.noNeutralEvidence",
                                                 title: "缺少可靠中性像素，白平衡不确定",
                                                 evidence: String(format: "仅有 %d 个中性候选（占 %.3f%%）；彩色主体可能被误当作白平衡参照。", metrics.neutralSampleCount, metrics.neutralSampleFraction * 100),
                                                 direction: "建议保留拍摄白点和现有白平衡选择，由用户确认参照；方案不自行更改白平衡开关。",
                                                 severity: .moderate))
        }
        if vision.faces.count > 0 {
            let meanConfidence = vision.faces.map { Double($0.confidence) }.reduce(0, +) / Double(vision.faces.count)
            findings.append(PhotoAnalysisFinding(id: "content.faces", title: "检测到人脸区域",
                                                 evidence: "本机 Vision 检测到 \(vision.faces.count) 张人脸，平均检测置信度 \(Int(meanConfidence * 100))%。",
                                                 direction: "全局曝光结果应复核面部亮度；不会自动添加局部蒙版。",
                                                 severity: .info))
        }
        return findings
    }

    private func makeProposals(metrics: PhotoAnalysisMetrics, baseline: AdjustmentSettings,
                               source: CIImage, colorScene: ColorSceneProfile) throws -> [AutoAdjustmentProposal] {
        // A median is not a semantic exposure target. Keep only half of its
        // weak directional signal and cap the change, preserving low/high key
        // and narrow-range scenes such as fog instead of normalizing them.
        let restrictedScene = metrics.medianLuminance < 0.04 || metrics.medianLuminance > 0.60
            || metrics.dynamicRangeStops < 3.5
        let exposureLimit = restrictedScene ? 0.10 : 0.25
        let measuredNeed = log2(0.18 / max(metrics.medianLuminance, 0.0001)) * 0.5
        let highlightHeadroom = max(0, log2(0.98 / max(metrics.p99Luminance, 0.001)))
        let constrained = clamp(measuredNeed, -exposureLimit, exposureLimit)
        // Check headroom even when only a small fraction of the frame is bright.
        let exposureNeed = constrained > 0 ? min(constrained, highlightHeadroom) : constrained
        let extraBright = min(restrictedScene ? 0.05 : 0.15,
                              max(0, highlightHeadroom - max(0, exposureNeed)))
        let softPull = min(0.08, 0.03 + max(0, metrics.p95Luminance - 0.65) * 0.10)
        let softenedNeed = clamp(exposureNeed - softPull, -exposureLimit, exposureLimit)
        let shadowEvidence = clamp(metrics.nearBlackFraction * 0.35
                                   + max(0, 0.015 - metrics.p05Luminance), 0, 0.06)
        let highlightEvidence = clamp(metrics.nearWhiteFraction * 0.40
                                      + max(0, metrics.p95Luminance - 0.82) * 0.10, 0, 0.08)
        let contrastNeed = restrictedScene ? 0 : clamp((5.5 - metrics.dynamicRangeStops) * 0.01, -0.05, 0.02)
        let softContrast = -min(0.05, max(0, (metrics.dynamicRangeStops - 4.0) * 0.01))
        let saturationHeadroom = clamp((0.45 - colorScene.saturatedFraction) / 0.35, 0, 1)
        let saturationLift = min(0.025, max(0, (0.22 - metrics.meanSaturation) * 0.08)) * saturationHeadroom
        let saturationSoftening = -min(0.03, max(0, (metrics.meanSaturation - 0.30) * 0.04))

        func settings(exposureDelta: Double, contrastDelta: Double, highlightDelta: Double,
                      shadowDelta: Double, saturationDelta: Double) -> AdjustmentSettings {
            var value = baseline
            value.autoExposure = false
            // Gray-looking objects can be warm by nature or by deliberate
            // lighting. Preserve the capture and any explicit user WB choice.
            value.autoWhiteBalance = baseline.autoWhiteBalance
            value.exposureEV = clamp(baseline.exposureEV + exposureDelta, -8, 8)
            value.contrast = clamp(baseline.contrast + contrastDelta, 0, 4)
            value.highlights = clamp(baseline.highlights + highlightDelta, -1, 1)
            value.shadows = clamp(baseline.shadows + shadowDelta, -1, 1)
            value.saturation = clamp(baseline.saturation + saturationDelta, 0, 4)
            return value
        }

        let whiteBalanceNote = baseline.autoWhiteBalance
            ? "沿用用户已开启的有限自动白平衡（仍会调整通道），保留手动冷暖和色调参数。"
            : "保留拍摄白点及现有冷暖/色调，不根据近灰像素自动中和。"
        let sceneNote = restrictedScene
            ? "低/高调或窄亮度范围仅作更小的曝光变化，不自动增加对比度。"
            : "中位亮度仅提供弱方向线索，不作为曝光错误的判断。"
        let basis = "规则支持度，不是审美正确率。基于原有基础调整后的像素估计增量，再实际渲染检查新增高光越界和黑位；不覆盖后续手调、LUT 或局部叠加。"
        func proposal(id: String, title: String, rationale: String, confidence: Double,
                      requested: AdjustmentSettings) throws -> AutoAdjustmentProposal {
            let result = try AutomaticSafetyEvaluator.limit(source: source, baseline: baseline,
                                                            requested: requested, engine: engine)
            return AutoAdjustmentProposal(id: id, title: title,
                rationale: String(format: "自动曝光增量 %+.2f EV（总补偿 %+.2f EV）。%@ %@ %@",
                                  result.report.exposureDeltaEV, result.settings.exposureEV,
                                  rationale, sceneNote, whiteBalanceNote),
                confidence: confidence, confidenceBasis: basis,
                settings: result.settings, safety: result.report)
        }
        let balanced = try proposal(id: "balanced", title: "保守还原",
            rationale: "小幅平衡曝光，按近黑/近白证据微调阴影与高光。",
            confidence: metrics.analysisConfidence,
            requested: settings(exposureDelta: exposureNeed, contrastDelta: contrastNeed,
                                highlightDelta: -highlightEvidence, shadowDelta: shadowEvidence,
                                saturationDelta: 0))
        let bright = try proposal(id: "bright", title: "明亮通透",
            rationale: "在高光余量允许时稍提亮，额外曝光最多 0.15 EV、总增量最多 0.40 EV，仅少量增加彩度。",
            confidence: max(0.35, metrics.analysisConfidence - 0.10),
            requested: settings(exposureDelta: exposureNeed + extraBright, contrastDelta: contrastNeed,
                                highlightDelta: -highlightEvidence, shadowDelta: shadowEvidence * 0.85,
                                saturationDelta: saturationLift))
        let soft = try proposal(id: "soft", title: "柔和氛围",
            rationale: "轻收曝光与高光，按亮度跨度少量柔化对比，不额外增加暖色。",
            confidence: max(0.30, metrics.analysisConfidence - 0.18),
            requested: settings(exposureDelta: softenedNeed, contrastDelta: softContrast,
                                highlightDelta: -min(0.10, highlightEvidence + 0.02),
                                shadowDelta: shadowEvidence * 0.7, saturationDelta: saturationSoftening))
        return [balanced, bright, soft]
    }

    private func makeSummary(metrics: PhotoAnalysisMetrics, proposal: AutoAdjustmentProposal,
                             vision: VisionResult, colorScene: ColorSceneProfile) -> String {
        let contentText = vision.labels.isEmpty ? "未生成可信内容标签" : "内容标签 \(vision.labels.prefix(3).map(\.label).joined(separator: "、"))"
        return String(format: "采样 %d×%d 像素：中位亮度 %.3f，P05–P95 跨度 %.2f EV，近黑 %.1f%%、近白 %.1f%%。%@。中性色 %.0f%%、高彩度区域 %.0f%%。可预览“%@”（总曝光补偿 %+.2f EV）；方案依据原有基础调整后的像素作有限变化并检查新增越界，保留原有白平衡，仍需结合主体和拍摄意图比较。",
                      metrics.sampleWidth, metrics.sampleHeight, metrics.medianLuminance,
                      metrics.dynamicRangeStops, metrics.nearBlackFraction * 100,
                      metrics.nearWhiteFraction * 100, contentText,
                      colorScene.neutralFraction * 100, colorScene.saturatedFraction * 100,
                      proposal.title,
                      proposal.settings.exposureEV)
    }

    private func percentile(_ sorted: [Double], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = clamp(fraction, 0, 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    private func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
        min(upper, max(lower, value))
    }
}

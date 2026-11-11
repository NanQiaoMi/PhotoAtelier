import CoreGraphics
import CoreImage
import Foundation

// MARK: - Public result model

/// Culling recommendation produced by the heuristic quality analyzer.
///
/// `keep` means "worth keeping as the burst winner", `review` means "let the
/// human decide" and `reject` means "likely technically unusable". The labels are
/// advisory only: this is a v1 heuristic, not a commercial AI culling service.
public enum QualityRecommendation: String, Codable, CaseIterable, Identifiable, Equatable {
    case keep
    case review
    case reject

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .keep: return "推荐保留"
        case .review: return "待复核"
        case .reject: return "建议淘汰"
        }
    }
}

/// Tunable thresholds for `QualityAnalyzer`.
///
/// All scores are in `0...1`. The defaults are conservative heuristics tuned on
/// synthetic fixtures only; real-photo preferences (genre, subject, artistic
/// intent) are out of scope for this v1 analyzer.
public struct QualityAnalysisSettings: Codable, Equatable {
    /// Longest edge of the internal grayscale analysis raster (no upscaling).
    public var analysisMaxDimension: Int = 512
    /// Eye height/width ratio below which an eye counts as closed.
    public var closedEyeOpennessThreshold: Double = 0.16
    /// Mean luma the exposure scorer prefers (linear-sRGB-encoded display luma).
    public var targetMeanLuma: Double = 0.45
    /// Luma at/below which a pixel counts as near-black clipping.
    public var shadowClipThreshold: Double = 0.02
    /// Luma at/above which a pixel counts as near-white clipping.
    public var highlightClipThreshold: Double = 0.98
    /// Overall score at/above which a photo is recommended for keeping.
    public var keepOverallScore: Double = 0.62
    /// Overall score below which a photo is recommended for rejection.
    public var reviewOverallScore: Double = 0.38
    /// Weight of the sharpness score in the overall score.
    public var sharpnessWeight: Double = 0.45
    /// Weight of the exposure score in the overall score.
    public var exposureWeight: Double = 0.30
    /// Weight of the eye score in the overall score (only when eyes were observed).
    public var eyeWeight: Double = 0.25

    public init() {}

    /// Structural validation used by the analyzer and (later) by the culling UI.
    public func validate() throws {
        guard (64...1_024).contains(analysisMaxDimension) else {
            throw AtelierError.invalidConfiguration("质量分析采样长边必须在 64...1024 之间。")
        }
        guard closedEyeOpennessThreshold.isFinite,
              (0.02...0.5).contains(closedEyeOpennessThreshold) else {
            throw AtelierError.invalidConfiguration("闭眼开合阈值必须在 0.02...0.5 之间。")
        }
        guard targetMeanLuma.isFinite, (0.1...0.9).contains(targetMeanLuma) else {
            throw AtelierError.invalidConfiguration("曝光目标亮度必须在 0.1...0.9 之间。")
        }
        guard shadowClipThreshold.isFinite, (0...0.2).contains(shadowClipThreshold) else {
            throw AtelierError.invalidConfiguration("阴影裁剪阈值必须在 0...0.2 之间。")
        }
        guard highlightClipThreshold.isFinite, (0.8...1).contains(highlightClipThreshold) else {
            throw AtelierError.invalidConfiguration("高光裁剪阈值必须在 0.8...1 之间。")
        }
        guard shadowClipThreshold < highlightClipThreshold else {
            throw AtelierError.invalidConfiguration("阴影裁剪阈值必须小于高光裁剪阈值。")
        }
        guard keepOverallScore.isFinite, (0.05...0.99).contains(keepOverallScore) else {
            throw AtelierError.invalidConfiguration("保留推荐阈值必须在 0.05...0.99 之间。")
        }
        guard reviewOverallScore.isFinite, (0...1).contains(reviewOverallScore),
              reviewOverallScore < keepOverallScore else {
            throw AtelierError.invalidConfiguration("淘汰推荐阈值必须在 0...1 且小于保留推荐阈值。")
        }
        let weights = [sharpnessWeight, exposureWeight, eyeWeight]
        guard weights.allSatisfy({ $0.isFinite && $0 >= 0 }), weights.reduce(0, +) > 0 else {
            throw AtelierError.invalidConfiguration("质量评分权重必须为非负有限值且不能全为 0。")
        }
    }
}

/// Per-photo quality report.
///
/// The score breakdown is intentionally exposed so the culling UI can explain the
/// recommendation instead of showing an opaque number. `nil` eye metrics mean no
/// usable eye geometry was supplied (no face detected or landmarks not injected);
/// the overall score then renormalizes the remaining weights.
public struct QualityReport: Codable, Equatable {
    /// Capture time supplied by the caller (EXIF or injected for tests).
    public var captureTime: Date?
    /// Number of face landmark sets supplied by the caller.
    public var faceCount: Int
    /// Number of usable eye outlines found in `faces`.
    public var eyeCount: Int
    /// Number of eyes below `closedEyeOpennessThreshold`.
    public var closedEyeCount: Int
    /// Minimum eye height/width ratio among usable eyes, `nil` when none.
    public var eyeOpenness: Double?
    /// Variance of the 4-neighbour Laplacian of the grayscale analysis raster.
    public var laplacianVariance: Double
    /// Mean squared Sobel/Tenengrad gradient magnitude of the analysis raster.
    public var tenengradEnergy: Double
    /// Normalized sharpness score in `0...1` (higher = sharper), contrast-invariant.
    public var sharpnessScore: Double
    /// Exposure score in `0...1` (higher = better exposed).
    public var exposureScore: Double
    /// Ratio of pixels at/below `shadowClipThreshold`.
    public var nearBlackRatio: Double
    /// Ratio of pixels at/above `highlightClipThreshold`.
    public var nearWhiteRatio: Double
    /// Mean display-referred luma in `0...1`.
    public var meanLuma: Double
    /// Standard deviation of display-referred luma in `0...1`.
    public var lumaContrast: Double
    /// Weighted overall score in `0...1`.
    public var overallScore: Double
    /// Advisory recommendation derived from `overallScore` and closed eyes.
    public var recommendation: QualityRecommendation
    /// Human-readable explanation strings (Chinese UI copy).
    public var reasons: [String]

    public init(captureTime: Date? = nil,
                faceCount: Int = 0,
                eyeCount: Int = 0,
                closedEyeCount: Int = 0,
                eyeOpenness: Double? = nil,
                laplacianVariance: Double = 0,
                tenengradEnergy: Double = 0,
                sharpnessScore: Double = 0,
                exposureScore: Double = 0,
                nearBlackRatio: Double = 0,
                nearWhiteRatio: Double = 0,
                meanLuma: Double = 0,
                lumaContrast: Double = 0,
                overallScore: Double = 0,
                recommendation: QualityRecommendation = .review,
                reasons: [String] = []) {
        self.captureTime = captureTime
        self.faceCount = faceCount
        self.eyeCount = eyeCount
        self.closedEyeCount = closedEyeCount
        self.eyeOpenness = eyeOpenness
        self.laplacianVariance = laplacianVariance
        self.tenengradEnergy = tenengradEnergy
        self.sharpnessScore = sharpnessScore
        self.exposureScore = exposureScore
        self.nearBlackRatio = nearBlackRatio
        self.nearWhiteRatio = nearWhiteRatio
        self.meanLuma = meanLuma
        self.lumaContrast = lumaContrast
        self.overallScore = overallScore
        self.recommendation = recommendation
        self.reasons = reasons
    }
}

// MARK: - Analyzer

/// Heuristic still-photo quality analysis used by culling (v1).
///
/// What it measures:
/// - **Sharpness**: contrast-normalized Laplacian variance plus a Tenengrad
///   gradient energy term on a downsampled display-referred grayscale raster.
///   This is a relative blur indicator, not a lens/MTF measurement: flat or
///   intentionally soft scenes (clear sky, heavy bokeh) score low even when the
///   photo is technically in focus, and must not be auto-rejected without review.
/// - **Exposure**: near-black / near-white clipping ratios plus mean luma
///   distance from `QualityAnalysisSettings.targetMeanLuma`; the luma contrast
///   (standard deviation) is reported for explanations.
/// - **Closed eyes**: an eye-outline height/width ratio heuristic over the
///   caller-supplied `FaceLandmarkSet` polygons. The analyzer never runs Vision
///   itself, so the caller decides when to pay for detection and tests can inject
///   landmarks directly.
///
/// The API is a pure function of the supplied image + landmarks: same input and
/// same machine produce the same report. All thresholds are advisory heuristics;
/// real-photo aesthetic judgement and commercial culling quality are explicitly
/// out of scope. Images are rendered opaque for analysis (alpha is not used).
public enum QualityAnalyzer {
    /// Display-referred conversion space for the analysis raster.
    static let analysisColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private static let defaultContext = CIContext(options: [
        .workingColorSpace: analysisColorSpace,
        .outputColorSpace: analysisColorSpace,
        .workingFormat: CIFormat.RGBA8,
        .cacheIntermediates: false
    ])

    /// Analyzes one image and returns a quality report.
    ///
    /// - Parameters:
    ///   - image: Source image; only its extent is sampled (downscaled to at most
    ///     `settings.analysisMaxDimension` on the longest edge).
    ///   - faces: Landmark geometry in normalized image coordinates. Passing an
    ///     empty array skips eye analysis and renormalizes the score weights.
    ///   - captureTime: Stored in the report for burst grouping / UI display.
    ///   - settings: Tunable thresholds; validated before rendering.
    ///   - context: Optional Core Image context (a shared sRGB context is used by
    ///     default).
    /// - Throws: `AtelierError.invalidConfiguration` for an invalid/empty extent,
    ///   invalid settings or malformed landmark data.
    public static func report(for image: CIImage,
                              faces: [FaceLandmarkSet] = [],
                              captureTime: Date? = nil,
                              settings: QualityAnalysisSettings = QualityAnalysisSettings(),
                              context: CIContext? = nil) throws -> QualityReport {
        try settings.validate()
        let raster = try analyzeRaster(image, maxDimension: settings.analysisMaxDimension,
                                       context: context ?? defaultContext)
        let eyes = eyeMetrics(for: faces, threshold: settings.closedEyeOpennessThreshold)
        return makeReport(raster: raster, faces: faces, eyes: eyes,
                          captureTime: captureTime, settings: settings)
    }

    // MARK: Metrics

    struct LumaRaster {
        var width: Int
        var height: Int
        var luma: [Double]  // row-major, top row first (display orientation)
    }

    struct EyeMetrics {
        var eyeCount: Int = 0
        var closedEyeCount: Int = 0
        var minimumOpenness: Double?
    }

    private static func analyzeRaster(_ image: CIImage,
                                      maxDimension: Int,
                                      context: CIContext) throws -> LumaRaster {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 1, extent.height > 1 else {
            throw AtelierError.invalidConfiguration("质量分析需要有限且非空的图像范围。")
        }
        let translated = image.transformed(by: CGAffineTransform(translationX: -extent.minX,
                                                                 y: -extent.minY))
        let scale = min(1, CGFloat(maxDimension) / max(extent.width, extent.height))
        let width = max(2, Int((extent.width * scale).rounded()))
        let height = max(2, Int((extent.height * scale).rounded()))
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        let resized: CIImage
        if scale < 0.9995 {
            resized = translated.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform",
                                parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
                .cropped(to: target)
        } else {
            resized = translated.cropped(to: target)
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(resized, toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                           bounds: target, format: .RGBA8, colorSpace: analysisColorSpace)
        }
        var luma = [Double](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            luma[index] = (0.2126 * Double(pixels[offset])
                + 0.7152 * Double(pixels[offset + 1])
                + 0.0722 * Double(pixels[offset + 2])) / 255.0
        }
        return LumaRaster(width: width, height: height, luma: luma)
    }

    /// Eye openness = outline bounding-box height / width. Vision eye outlines
    /// are roughly 0.3...0.5 open and 0.05...0.15 closed; profiles/occlusions
    /// produce degenerate outlines which are ignored.
    private static func eyeMetrics(for faces: [FaceLandmarkSet],
                                   threshold: Double) -> EyeMetrics {
        var result = EyeMetrics()
        for face in faces {
            for outline in [face.leftEye, face.rightEye] {
                let box = boundingBox(of: outline)
                guard let box, box.width > 1e-4, box.height.isFinite, box.width.isFinite else { continue }
                let openness = Double(box.height / box.width)
                guard openness.isFinite else { continue }
                result.eyeCount += 1
                result.minimumOpenness = min(result.minimumOpenness ?? openness, openness)
                if openness < threshold { result.closedEyeCount += 1 }
            }
        }
        return result
    }

    private static func boundingBox(of points: [CGPoint]) -> CGRect? {
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        var count = 0
        for point in points where point.x.isFinite && point.y.isFinite {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
            count += 1
        }
        guard count >= 3, maxX > minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func makeReport(raster: LumaRaster,
                                   faces: [FaceLandmarkSet],
                                   eyes: EyeMetrics,
                                   captureTime: Date?,
                                   settings: QualityAnalysisSettings) -> QualityReport {
        let luma = raster.luma
        let width = raster.width
        let height = raster.height
        let count = Double(width * height)
        let mean = luma.reduce(0, +) / count
        var variance = 0.0
        for value in luma {
            let delta = value - mean
            variance += delta * delta
        }
        variance /= count
        let contrast = variance.squareRoot()

        var nearBlack = 0
        var nearWhite = 0
        for value in luma {
            if value <= settings.shadowClipThreshold { nearBlack += 1 }
            if value >= settings.highlightClipThreshold { nearWhite += 1 }
        }
        let nearBlackRatio = Double(nearBlack) / count
        let nearWhiteRatio = Double(nearWhite) / count

        // Laplacian (4-neighbour, normalized by 4) variance and Tenengrad energy.
        var laplacianValues: [Double] = []
        laplacianValues.reserveCapacity(max(0, (width - 2) * (height - 2)))
        var gradientSum = 0.0
        var gradientCount = 0
        if width >= 3 && height >= 3 {
            for row in 1..<(height - 1) {
                for column in 1..<(width - 1) {
                    let center = luma[row * width + column]
                    let left = luma[row * width + column - 1]
                    let right = luma[row * width + column + 1]
                    let up = luma[(row - 1) * width + column]
                    let down = luma[(row + 1) * width + column]
                    laplacianValues.append((4 * center - left - right - up - down) / 4)
                    let gx = (right - left) / 2
                    let gy = (down - up) / 2
                    gradientSum += gx * gx + gy * gy
                    gradientCount += 1
                }
            }
        }
        let laplacianVariance = Self.variance(of: laplacianValues)
        let tenengradEnergy = gradientCount > 0 ? gradientSum / Double(gradientCount) : 0

        // Contrast-invariant sharpness: the Laplacian energy share of the total
        // luma variation. Sensitive to real detail, robust to exposure/contrast
        // changes, and saturating so extreme texture does not dominate the score.
        let edgeShare = laplacianVariance / (laplacianVariance + 0.16 * variance + 1e-8)
        let sharpnessScore = clamp(min(1, edgeShare * 1.5))

        let meanPenalty = min(1, abs(mean - settings.targetMeanLuma)
            / max(settings.targetMeanLuma, 1 - settings.targetMeanLuma))
        let clippingPenalty = min(1, (nearBlackRatio + nearWhiteRatio) * 4)
        let exposureScore = clamp(1 - 0.55 * meanPenalty - 0.85 * clippingPenalty)

        let eyeScore: Double?
        if eyes.eyeCount > 0, let openness = eyes.minimumOpenness {
            eyeScore = eyes.closedEyeCount > 0 ? 0 : clamp(min(1, openness / 0.30))
        } else {
            eyeScore = nil
        }

        let sharpWeight = settings.sharpnessWeight
        let exposureWeight = settings.exposureWeight
        let eyeWeight = settings.eyeWeight
        let overall: Double
        if let eyeScore, eyeWeight > 0 {
            let total = sharpWeight + exposureWeight + eyeWeight
            overall = total > 0
                ? (sharpWeight * sharpnessScore + exposureWeight * exposureScore + eyeWeight * eyeScore) / total
                : 0
        } else {
            let total = sharpWeight + exposureWeight
            overall = total > 0
                ? (sharpWeight * sharpnessScore + exposureWeight * exposureScore) / total
                : 0
        }

        var recommendation: QualityRecommendation
        if overall >= settings.keepOverallScore && eyes.closedEyeCount == 0 {
            recommendation = .keep
        } else if overall < settings.reviewOverallScore {
            recommendation = .reject
        } else {
            recommendation = .review
        }

        var reasons: [String] = []
        if laplacianVariance < 0.004 {
            reasons.append("清晰度偏低：可能是失焦或抖动（拉普拉斯方差 \(format(laplacianVariance))）。")
        } else if sharpnessScore > 0.55 {
            reasons.append("清晰度良好（归一化锐度 \(format(sharpnessScore))）。")
        } else {
            reasons.append("清晰度一般（归一化锐度 \(format(sharpnessScore))），建议放大复核。")
        }
        if nearWhiteRatio > 0.2 {
            reasons.append("高光大面积溢出（近白 \(percent(nearWhiteRatio))），可能过曝。")
        }
        if nearBlackRatio > 0.2 {
            reasons.append("暗部大面积压黑（近黑 \(percent(nearBlackRatio))），可能欠曝。")
        }
        if nearWhiteRatio <= 0.2 && nearBlackRatio <= 0.2 {
            reasons.append("曝光分布可接受（平均亮度 \(format(mean))，对比度 \(format(contrast))）。")
        }
        if eyes.eyeCount > 0 {
            if eyes.closedEyeCount > 0 {
                reasons.append("检测到 \(eyes.closedEyeCount)/\(eyes.eyeCount) 只眼睛接近闭合，推荐至多待复核。")
            } else {
                reasons.append("眼睛开合正常（最小开合比 \(format(eyes.minimumOpenness ?? 0))）。")
            }
        } else if !faces.isEmpty {
            reasons.append("人脸地标缺少可用眼睛轮廓，未参与闭眼评分。")
        }
        reasons.append("综合评分 \(format(overall)) → \(recommendation.title)；启发式 v1，请人工复核。")

        return QualityReport(captureTime: captureTime,
                             faceCount: faces.count,
                             eyeCount: eyes.eyeCount,
                             closedEyeCount: eyes.closedEyeCount,
                             eyeOpenness: eyes.minimumOpenness,
                             laplacianVariance: laplacianVariance,
                             tenengradEnergy: tenengradEnergy,
                             sharpnessScore: sharpnessScore,
                             exposureScore: exposureScore,
                             nearBlackRatio: nearBlackRatio,
                             nearWhiteRatio: nearWhiteRatio,
                             meanLuma: mean,
                             lumaContrast: contrast,
                             overallScore: overall,
                             recommendation: recommendation,
                             reasons: reasons)
    }

    // MARK: Small helpers

    private static func variance(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        var total = 0.0
        for value in values {
            let delta = value - mean
            total += delta * delta
        }
        return total / Double(values.count)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func format(_ value: Double) -> String {
        value.isFinite ? String(format: "%.3f", value) : "NaN"
    }

    private static func percent(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f%%", value * 100) : "NaN"
    }
}

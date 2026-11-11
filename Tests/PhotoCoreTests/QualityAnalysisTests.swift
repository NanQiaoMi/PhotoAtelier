import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

/// Synthetic-fixture tests for the P1-C heuristic culling analyzer.
///
/// Fixtures are generated checkerboards / gradients / uniform fields and blurred
/// with Core Image. Assertions only prove directional behaviour (sharp vs blurred,
/// clipped vs exposed, open vs closed eyes) and determinism on this machine; they
/// are **not** a real-photo aesthetic or commercial-AI-culling evaluation.
final class QualityAnalysisTests: XCTestCase {
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: - Fixtures

    private func makeImage(width: Int, height: Int,
                           pixel: (Int, Int) -> (Double, Double, Double)) -> CIImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue) = pixel(x, y)
                context.setFillColor(CGColor(colorSpace: colorSpace,
                                             components: [red, green, blue, 1])!)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return CIImage(cgImage: context.makeImage()!)
    }

    private func checkerboard(width: Int = 256, height: Int = 192,
                              cell: Int = 8) -> CIImage {
        makeImage(width: width, height: height) { x, y in
            let value = ((x / cell) + (y / cell)) % 2 == 0 ? 0.9 : 0.1
            return (value, value, value)
        }
    }

    private func blurred(_ image: CIImage, radius: Double) -> CIImage {
        image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
    }

    private func eyeRectangle(centerX: Double, centerY: Double,
                              width: Double, height: Double) -> [CGPoint] {
        [CGPoint(x: centerX - width / 2, y: centerY - height / 2),
         CGPoint(x: centerX + width / 2, y: centerY - height / 2),
         CGPoint(x: centerX + width / 2, y: centerY + height / 2),
         CGPoint(x: centerX - width / 2, y: centerY + height / 2)]
    }

    private func face(eyeHeight: Double, eyeWidth: Double = 0.10) -> FaceLandmarkSet {
        FaceLandmarkSet(boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
                        leftEye: eyeRectangle(centerX: 0.4, centerY: 0.5,
                                              width: eyeWidth, height: eyeHeight),
                        rightEye: eyeRectangle(centerX: 0.6, centerY: 0.5,
                                               width: eyeWidth, height: eyeHeight))
    }

    // MARK: - Sharpness / recommendation

    func testSharpCheckerboardIsRecommendedKeepAndBlurredVersionIsNot() throws {
        let sharp = try QualityAnalyzer.report(for: checkerboard())
        let blurred = try QualityAnalyzer.report(for: blurred(checkerboard(), radius: 12))

        XCTAssertGreaterThan(sharp.sharpnessScore, 0.5,
                             "checkerboard sharpness \(sharp.sharpnessScore) 应明显高于 0")
        XCTAssertLessThan(blurred.sharpnessScore, 0.10,
                          "高斯模糊后锐度应接近 0（实际 \(blurred.sharpnessScore)）")
        XCTAssertLessThan(blurred.laplacianVariance, sharp.laplacianVariance * 0.1)
        XCTAssertLessThan(blurred.tenengradEnergy, sharp.tenengradEnergy * 0.1)
        XCTAssertGreaterThan(sharp.overallScore, blurred.overallScore + 0.3,
                             "清晰图综合分应显著高于模糊图")
        XCTAssertEqual(sharp.recommendation, .keep,
                       "清晰且曝光正常的合成图应推荐保留：\(sharp.reasons)")
        XCTAssertNotEqual(blurred.recommendation, .keep,
                          "模糊图不应被推荐保留：\(blurred.reasons)")
        XCTAssertFalse(sharp.reasons.isEmpty, "报告必须带可解释原因")
        XCTAssertTrue(sharp.reasons.contains { $0.contains("清晰度") })
    }

    func testSharpnessIsContrastInvariantForTheSameTexture() throws {
        // Same checkerboard pattern at two contrast levels: the normalized
        // sharpness score should stay close (raw Laplacian variance scales with
        // contrast squared, the normalized score must not).
        let high = makeImage(width: 256, height: 192) { x, y in
            let value = ((x / 8) + (y / 8)) % 2 == 0 ? 0.95 : 0.05
            return (value, value, value)
        }
        let low = makeImage(width: 256, height: 192) { x, y in
            let value = ((x / 8) + (y / 8)) % 2 == 0 ? 0.55 : 0.45
            return (value, value, value)
        }
        let highReport = try QualityAnalyzer.report(for: high)
        let lowReport = try QualityAnalyzer.report(for: low)
        XCTAssertGreaterThan(highReport.laplacianVariance, lowReport.laplacianVariance * 4,
                             "原始拉普拉斯方差应随对比度平方增长")
        XCTAssertEqual(highReport.sharpnessScore, lowReport.sharpnessScore, accuracy: 0.15,
                       "归一化锐度应在对比度变化下基本不变")
    }

    // MARK: - Exposure

    func testExposureClippingIsDetectedInBothDirections() throws {
        let overexposed = try QualityAnalyzer.report(for: makeImage(width: 128, height: 96) { _, _ in
            (0.995, 0.995, 0.995)
        })
        let underexposed = try QualityAnalyzer.report(for: makeImage(width: 128, height: 96) { _, _ in
            (0.005, 0.005, 0.005)
        })
        let exposed = try QualityAnalyzer.report(for: checkerboard())

        XCTAssertGreaterThan(overexposed.nearWhiteRatio, 0.9,
                             "近白裁剪比例 \(overexposed.nearWhiteRatio) 应接近 1")
        XCTAssertLessThan(overexposed.exposureScore, 0.1)
        XCTAssertEqual(overexposed.recommendation, .reject)
        XCTAssertTrue(overexposed.reasons.contains { $0.contains("过曝") || $0.contains("溢出") })

        XCTAssertGreaterThan(underexposed.nearBlackRatio, 0.9,
                             "近黑裁剪比例 \(underexposed.nearBlackRatio) 应接近 1")
        XCTAssertLessThan(underexposed.exposureScore, 0.1)
        XCTAssertEqual(underexposed.recommendation, .reject)
        XCTAssertTrue(underexposed.reasons.contains { $0.contains("欠曝") || $0.contains("压黑") })

        XCTAssertLessThan(exposed.nearBlackRatio, 0.01)
        XCTAssertLessThan(exposed.nearWhiteRatio, 0.01)
        XCTAssertGreaterThan(exposed.exposureScore, 0.8)
        XCTAssertEqual(exposed.meanLuma, 0.5, accuracy: 0.1)
        XCTAssertGreaterThan(exposed.lumaContrast, 0.3)
    }

    func testSlightlyOverexposedGradientLosesExposureScore() throws {
        let strong = makeImage(width: 256, height: 192) { x, _ in
            let value = 0.4 + 0.5 * Double(x) / 255
            return (value, value, value)
        }
        let hot = makeImage(width: 256, height: 192) { x, _ in
            let value = 0.80 + 0.18 * Double(x) / 255
            return (value, value, value)
        }
        let strongReport = try QualityAnalyzer.report(for: strong)
        let hotReport = try QualityAnalyzer.report(for: hot)
        XCTAssertGreaterThan(strongReport.exposureScore, hotReport.exposureScore)
        XCTAssertGreaterThan(hotReport.meanLuma, strongReport.meanLuma)
    }

    // MARK: - Closed eyes (injected landmarks)

    func testOpenEyesKeepRecommendationAndClosedEyesBlockIt() throws {
        let image = checkerboard()
        let openFace = face(eyeHeight: 0.035)
        let closedFace = face(eyeHeight: 0.008)

        let open = try QualityAnalyzer.report(for: image, faces: [openFace])
        let closed = try QualityAnalyzer.report(for: image, faces: [closedFace])

        XCTAssertEqual(open.faceCount, 1)
        XCTAssertEqual(open.eyeCount, 2)
        XCTAssertEqual(open.closedEyeCount, 0)
        XCTAssertEqual(try XCTUnwrap(open.eyeOpenness), 0.35, accuracy: 0.01)
        XCTAssertEqual(open.recommendation, .keep)

        XCTAssertEqual(closed.faceCount, 1)
        XCTAssertEqual(closed.eyeCount, 2)
        XCTAssertEqual(closed.closedEyeCount, 2)
        XCTAssertEqual(try XCTUnwrap(closed.eyeOpenness), 0.08, accuracy: 0.01)
        XCTAssertLessThan(closed.overallScore, open.overallScore)
        XCTAssertNotEqual(closed.recommendation, .keep,
                          "闭眼照片即使锐利/曝光正常也不应推荐保留")
        XCTAssertTrue(closed.reasons.contains { $0.contains("闭合") || $0.contains("闭眼") })

        // A face without usable eye outlines is ignored, not fatal.
        let empty = try QualityAnalyzer.report(for: image, faces: [FaceLandmarkSet()])
        XCTAssertEqual(empty.faceCount, 1)
        XCTAssertEqual(empty.eyeCount, 0)
        XCTAssertNil(empty.eyeOpenness)
        XCTAssertEqual(empty.recommendation, .keep)
    }

    func testDegenerateAndNaNLandmarksAreIgnoredNotFatal() throws {
        let nanFace = FaceLandmarkSet(
            boundingBox: CGRect(x: CGFloat.nan, y: 0, width: 0.1, height: 0.1),
            leftEye: [CGPoint(x: CGFloat.nan, y: CGFloat.nan), CGPoint(x: 0.4, y: 0.5)],
            rightEye: [CGPoint(x: 0.6, y: 0.5)])
        let report = try QualityAnalyzer.report(for: checkerboard(), faces: [nanFace])
        XCTAssertEqual(report.faceCount, 1)
        XCTAssertEqual(report.eyeCount, 0)
        XCTAssertNil(report.eyeOpenness)
        XCTAssertTrue(report.overallScore.isFinite)
        XCTAssertTrue(report.laplacianVariance.isFinite)
        XCTAssertTrue(report.meanLuma.isFinite)
        XCTAssertTrue(report.reasons.allSatisfy { !$0.contains("nan") })
    }

    // MARK: - Validation / determinism

    func testInvalidImageExtentAndInvalidSettingsThrow() {
        let empty = CIImage(color: .clear).cropped(to: .zero)
        XCTAssertThrowsError(try QualityAnalyzer.report(for: empty))

        var badDimension = QualityAnalysisSettings()
        badDimension.analysisMaxDimension = 8
        XCTAssertThrowsError(try badDimension.validate())
        XCTAssertThrowsError(try QualityAnalyzer.report(for: checkerboard(), settings: badDimension))

        var badThreshold = QualityAnalysisSettings()
        badThreshold.closedEyeOpennessThreshold = Double.nan
        XCTAssertThrowsError(try badThreshold.validate())

        var badWeights = QualityAnalysisSettings()
        badWeights.sharpnessWeight = -1
        XCTAssertThrowsError(try badWeights.validate())

        var badRecommendationOrder = QualityAnalysisSettings()
        badRecommendationOrder.keepOverallScore = 0.2
        badRecommendationOrder.reviewOverallScore = 0.8
        XCTAssertThrowsError(try badRecommendationOrder.validate())
    }

    func testCustomThresholdsMapToRecommendations() throws {
        let image = checkerboard()
        let baseline = try QualityAnalyzer.report(for: image)
        XCTAssertEqual(baseline.recommendation, .keep)
        let score = baseline.overallScore

        var strictKeep = QualityAnalysisSettings()
        strictKeep.keepOverallScore = min(0.99, score + 0.05)
        strictKeep.reviewOverallScore = 0.05
        XCTAssertEqual(try QualityAnalyzer.report(for: image, settings: strictKeep).recommendation,
                       .review)

        var strictReview = QualityAnalysisSettings()
        strictReview.keepOverallScore = 0.95
        strictReview.reviewOverallScore = min(0.9, score + 0.05)
        XCTAssertEqual(try QualityAnalyzer.report(for: image, settings: strictReview).recommendation,
                       .reject)
    }

    func testDeterminismAndCaptureTimePassthrough() throws {
        let captureTime = Date(timeIntervalSince1970: 1_700_000_123)
        let image = blurred(checkerboard(), radius: 3)
        let first = try QualityAnalyzer.report(for: image, faces: [face(eyeHeight: 0.03)],
                                               captureTime: captureTime)
        let second = try QualityAnalyzer.report(for: image, faces: [face(eyeHeight: 0.03)],
                                                captureTime: captureTime)
        XCTAssertEqual(first, second, "相同输入必须得到逐字段一致的报告")
        XCTAssertEqual(first.captureTime, captureTime)
        XCTAssertTrue(first.overallScore.isFinite)
        XCTAssertTrue(first.reasons.allSatisfy { $0.contains("NaN") == false })
    }

    /// C4 integration: the heuristic report maps to session rating/rejection
    /// suggestions that never touch recipes/persistence.
    func testAutoCullReportMapsToSessionRatingAndRejection() throws {
        let sharpReport = try QualityAnalyzer.report(for: checkerboard())
        XCTAssertEqual(sharpReport.recommendation, .keep)
        let keep = PhotoSelection.autoCullAssignment(for: sharpReport)
        XCTAssertEqual(keep.rating, 5)
        XCTAssertFalse(keep.isRejected)

        let closedEyes = try QualityAnalyzer.report(for: checkerboard(),
                                                    faces: [face(eyeHeight: 0.008)])
        XCTAssertEqual(closedEyes.recommendation, .review)
        XCTAssertEqual(PhotoSelection.autoCullAssignment(for: closedEyes),
                       PhotoSelection.AutoCullAssignment(rating: 3, isRejected: false))

        let blurred = try QualityAnalyzer.report(for: blurred(checkerboard(), radius: 20))
        let rejectedAssignment = PhotoSelection.autoCullAssignment(for: blurred)
        if blurred.recommendation == .reject {
            XCTAssertEqual(rejectedAssignment.rating, 1)
            XCTAssertTrue(rejectedAssignment.isRejected)
        } else {
            XCTAssertEqual(blurred.recommendation, .review)
            XCTAssertEqual(rejectedAssignment.rating, 3)
            XCTAssertFalse(rejectedAssignment.isRejected)
        }

        // Applying to PhotoItem fills the report and the session suggestion.
        var items = [PhotoItem(url: URL(fileURLWithPath: "/tmp/one.png"),
                               relativePath: "one.png")]
        let applied = PhotoSelection.applyingAutoCull(
            reports: [items[0].id: sharpReport], to: &items)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(items[0].qualityReport, sharpReport)
        XCTAssertEqual(items[0].rating, 5)
        XCTAssertFalse(items[0].isRejected)
        XCTAssertEqual(items[0].qualityRecommendation, .keep)
    }

    func testAnalysisDimensionCapKeepsLargeImagesBoundedAndDeterministic() throws {
        let large = checkerboard(width: 1_024, height: 768, cell: 16)
        var small = QualityAnalysisSettings()
        small.analysisMaxDimension = 128
        let first = try QualityAnalyzer.report(for: large, settings: small)
        let second = try QualityAnalyzer.report(for: large, settings: small)
        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(first.sharpnessScore, 0.0)
        XCTAssertTrue(first.overallScore.isFinite)
    }
}

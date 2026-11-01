import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class AnalysisTests: XCTestCase {
    private let analyzer = PhotoAnalyzer()

    func testDarkerPixelsReceiveGreaterExposureRecommendation() throws {
        let dark = try analyzer.analyze(image: solidImage(red: 0.035, green: 0.035, blue: 0.035),
                                        properties: [:], sourceURL: URL(fileURLWithPath: "/tmp/dark.jpg"))
        let bright = try analyzer.analyze(image: solidImage(red: 0.65, green: 0.65, blue: 0.65),
                                          properties: [:], sourceURL: URL(fileURLWithPath: "/tmp/bright.jpg"))

        XCTAssertGreaterThan(dark.proposals[0].settings.exposureEV, bright.proposals[0].settings.exposureEV)
        XCTAssertEqual(dark.proposals.map(\.id), ["balanced", "bright", "soft"])
        XCTAssertEqual(bright.proposals.map(\.id), ["balanced", "bright", "soft"])
        XCTAssertGreaterThan(dark.metrics.sampleCount, 0)
        XCTAssertEqual(dark.metrics.histogram.count, 64)
        let encoded = try JSONEncoder().encode(dark)
        XCTAssertEqual(try JSONDecoder().decode(PhotoAnalysis.self, from: encoded), dark)
    }

    func testHighKeyUniformSceneIsNotForcedTowardMiddleGray() throws {
        let analysis = try analyzer.analyze(image: solidImage(red: 0.92, green: 0.92, blue: 0.92),
                                           properties: [:], sourceURL: URL(fileURLWithPath: "/tmp/high-key.jpg"))

        XCTAssertGreaterThan(analysis.metrics.medianLuminance, 0.82)
        XCTAssertGreaterThan(analysis.proposals[0].settings.exposureEV, -0.30)
        XCTAssertTrue(analysis.issues.contains { $0.id == "exposure.highKeyScene" })
        XCTAssertTrue(analysis.issues.first(where: { $0.id == "exposure.highKeyScene" })?.evidence.contains("不能单凭此值断言曝光错误") == true)
    }

    func testNeutralEvidenceEnablesWhiteBalanceButColoredPixelsDoNot() throws {
        let warmNeutral = try analyzer.analyze(image: solidImage(red: 0.21, green: 0.20, blue: 0.19),
                                               properties: [:], sourceURL: URL(fileURLWithPath: "/tmp/neutral.jpg"))
        let saturated = try analyzer.analyze(image: solidImage(red: 0.75, green: 0.12, blue: 0.025),
                                             properties: [:], sourceURL: URL(fileURLWithPath: "/tmp/color.jpg"))

        XCTAssertGreaterThan(warmNeutral.metrics.neutralSampleCount, 0)
        XCTAssertTrue(warmNeutral.proposals[0].settings.autoWhiteBalance)
        XCTAssertLessThanOrEqual(saturated.metrics.neutralSampleCount, warmNeutral.metrics.neutralSampleCount)
        XCTAssertFalse(saturated.proposals[0].settings.autoWhiteBalance)
        XCTAssertTrue(saturated.unsupportedReadings.contains { $0.contains("中性") })
    }

    func testJPEGWithoutCaptureKelvinIsReportedUnknownNotEstimatedFromRGB() throws {
        let analysis = try analyzer.analyze(image: solidImage(red: 0.35, green: 0.28, blue: 0.2),
                                           properties: [:], sourceURL: URL(fileURLWithPath: "/tmp/camera.jpg"))
        let kelvin = try XCTUnwrap(analysis.metadata.first(where: { $0.id == "captureKelvin" }))

        XCTAssertTrue(kelvin.value.contains("未知"))
        XCTAssertTrue(analysis.unsupportedReadings.contains { $0.contains("Kelvin") })
    }

    func testRAWDecoderWhitePointIsLabeledAsAnEstimate() throws {
        let properties: [String: Any] = [
            "PhotoAtelierRAWAnalysis": [
                "decoder": "CIRAWFilter",
                "asShotWhiteBalance": [
                    "temperatureKelvin": 5150.0,
                    "tint": 3.0,
                    "provenance": "decoderEstimated",
                    "label": "RAW解码器白点估计"
                ]
            ]
        ]
        let analysis = try analyzer.analyze(image: solidImage(red: 0.3, green: 0.3, blue: 0.3),
                                           properties: properties,
                                           sourceURL: URL(fileURLWithPath: "/tmp/raw.dng"))
        let whitePoint = try XCTUnwrap(analysis.metadata.first(where: { $0.id == "captureKelvin" }))

        XCTAssertEqual(whitePoint.label, "RAW解码器白点估计")
        XCTAssertEqual(whitePoint.value, "5150 K")
        XCTAssertFalse(analysis.unsupportedReadings.contains { $0.contains("拍摄色温 Kelvin 未提供") })
    }

    func testProposalsRemainValidAndPreserveLUTGeometryAndMasks() throws {
        var baseline = AdjustmentSettings()
        baseline.autoExposure = true
        baseline.lutIntensity = 0.83
        baseline.lutColorSpace = .linearSRGB
        baseline.lensCorrection = true
        baseline.lensProfileID = "camera/lens/profile"
        baseline.lensCropFactor = 1.5
        baseline.lensFocalLength = 35
        baseline.autoStraighten = true
        baseline.rotationDegrees = 2.5
        baseline.verticalPerspective = 0.08
        baseline.horizontalPerspective = -0.04
        baseline.masks = [LocalMask(name: "keep", exposureEV: 0.7, warmth: -0.1)]

        let analysis = try analyzer.analyze(image: solidImage(red: 0.18, green: 0.18, blue: 0.18),
                                           properties: [:], sourceURL: URL(fileURLWithPath: "/tmp/recipe.tiff"),
                                           baseline: baseline)
        for proposal in analysis.proposals {
            try PhotoEngine.validate(proposal.settings)
            XCTAssertFalse(proposal.settings.autoExposure)
            XCTAssertEqual(proposal.settings.lutIntensity, baseline.lutIntensity)
            XCTAssertEqual(proposal.settings.lutColorSpace, baseline.lutColorSpace)
            XCTAssertEqual(proposal.settings.lensCorrection, baseline.lensCorrection)
            XCTAssertEqual(proposal.settings.lensProfileID, baseline.lensProfileID)
            XCTAssertEqual(proposal.settings.lensCropFactor, baseline.lensCropFactor)
            XCTAssertEqual(proposal.settings.lensFocalLength, baseline.lensFocalLength)
            XCTAssertEqual(proposal.settings.autoStraighten, baseline.autoStraighten)
            XCTAssertEqual(proposal.settings.rotationDegrees, baseline.rotationDegrees)
            XCTAssertEqual(proposal.settings.verticalPerspective, baseline.verticalPerspective)
            XCTAssertEqual(proposal.settings.horizontalPerspective, baseline.horizontalPerspective)
            XCTAssertEqual(proposal.settings.masks, baseline.masks)
            XCTAssertTrue((0...1).contains(proposal.confidence))
        }
    }

    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let cgColor = CGColor(colorSpace: space, components: [red, green, blue, 1])!
        let color = CIColor(cgColor: cgColor)
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 72, height: 48))
    }
}

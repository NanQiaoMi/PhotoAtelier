import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class ColorSceneTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    func testHueFamiliesNeutralAndEntropyAreMeasuredFromPixels() throws {
        let warm = try ColorSceneAnalyzer.analyze(
            image: solid(red: 0.85, green: 0.28, blue: 0.10), context: makeContext())
        let cool = try ColorSceneAnalyzer.analyze(
            image: solid(red: 0.08, green: 0.42, blue: 0.90), context: makeContext())
        let neutral = try ColorSceneAnalyzer.analyze(
            image: solid(red: 0.22, green: 0.22, blue: 0.22), context: makeContext())

        XCTAssertEqual(warm.sampleCount, 72 * 48)
        XCTAssertGreaterThan(warm.warmFraction, 0.99)
        XCTAssertLessThan(warm.coolFraction, 0.01)
        XCTAssertEqual(warm.colorDiversity, 0, accuracy: 0.001)
        XCTAssertGreaterThan(cool.coolFraction, 0.99)
        XCTAssertLessThan(cool.warmFraction, 0.01)
        XCTAssertGreaterThan(neutral.neutralFraction, 0.99)
        XCTAssertEqual(neutral.saturatedFraction, 0, accuracy: 0.001)
        XCTAssertTrue(warm.summary.contains("不代表白平衡误差"))
    }

    func testAlphaWeightsColorAndLuminanceFractions() throws {
        let extent = CGRect(x: 0, y: 0, width: 90, height: 60)
        let transparent = CIImage(color: .clear).cropped(to: extent)
        let lowAlphaWarm = CIImage(color: color(red: 1, green: 0, blue: 0, alpha: 0.25))
            .cropped(to: CGRect(x: 0, y: 0, width: 45, height: 60))
            .composited(over: transparent)
        let opaqueCool = CIImage(color: color(red: 0, green: 0, blue: 1, alpha: 1))
            .cropped(to: CGRect(x: 45, y: 0, width: 45, height: 60))
            .composited(over: lowAlphaWarm)

        let profile = try ColorSceneAnalyzer.analyze(image: opaqueCool, context: makeContext())

        XCTAssertEqual(profile.sampleCount, 90 * 60)
        XCTAssertEqual(profile.warmFraction, 0.20, accuracy: 0.03)
        XCTAssertEqual(profile.coolFraction, 0.80, accuracy: 0.03)
        XCTAssertEqual(profile.darkFraction, 0.80, accuracy: 0.03)
    }

    func testNineRegionsUseImageTopAndBottomAndReportDirections() throws {
        let extent = CGRect(x: 0, y: 0, width: 90, height: 90)
        let lowerDark = CIImage(color: color(red: 0.02, green: 0.02, blue: 0.02))
            .cropped(to: extent)
        let upperBright = CIImage(color: color(red: 0.90, green: 0.90, blue: 0.90))
            .cropped(to: CGRect(x: 0, y: 45, width: 90, height: 45))
            .composited(over: lowerDark)

        let profile = try ColorSceneAnalyzer.analyze(image: upperBright, context: makeContext())
        let top = try XCTUnwrap(profile.regions.first { $0.id == "region.0.1" })
        let bottom = try XCTUnwrap(profile.regions.first { $0.id == "region.2.1" })

        XCTAssertEqual(profile.regions.count, 9)
        XCTAssertEqual(profile.regions.reduce(0) { $0 + $1.coverage }, 1, accuracy: 0.0001)
        XCTAssertEqual(top.normalizedCenterY, 1.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(bottom.normalizedCenterY, 5.0 / 6.0, accuracy: 0.0001)
        XCTAssertGreaterThan(top.luminance, 0.72)
        XCTAssertLessThan(bottom.luminance, 0.12)
        XCTAssertTrue(top.direction.contains("高光"))
        XCTAssertTrue(bottom.direction.contains("阴影"))
    }

    func testSamplingDoesNotUpscaleOrExceed192PixelsOnLongestSide() throws {
        let image = CIImage(color: color(red: 0.3, green: 0.4, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 500))

        let profile = try ColorSceneAnalyzer.analyze(image: image, context: makeContext())

        XCTAssertLessThanOrEqual(profile.sampleCount, 192 * 192)
        XCTAssertEqual(profile.sampleCount, 192 * 96)
    }

    func testTransparentImageAndLegacyPhotoAnalysisDecode() throws {
        let transparent = try ColorSceneAnalyzer.analyze(
            image: solid(red: 0.5, green: 0.2, blue: 0.1, alpha: 0), context: makeContext())
        XCTAssertEqual(transparent.sampleCount, 0)
        XCTAssertEqual(transparent.regions.count, 9)
        XCTAssertTrue(transparent.regions.allSatisfy { $0.coverage == 0 })

        let analysis = try PhotoAnalyzer().analyze(
            image: solid(red: 0.4, green: 0.2, blue: 0.1), properties: [:])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis))
                                   as? [String: Any])
        object.removeValue(forKey: "colorScene")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PhotoAnalysis.self, from: legacyData)

        XCTAssertNil(decoded.colorScene)
    }

    func testPhotoAnalysisDoesNotDivideUnpremultipliedChannelsByAlphaAgain() throws {
        let image = solid(red: 0.4, green: 0.2, blue: 0.1, alpha: 0.5)
        let analysis = try PhotoAnalyzer().analyze(image: image, properties: [:])

        XCTAssertEqual(analysis.metrics.meanRed, 0.4, accuracy: 0.01)
        XCTAssertEqual(analysis.metrics.meanGreen, 0.2, accuracy: 0.01)
        XCTAssertEqual(analysis.colorScene?.warmFraction ?? 0, 1, accuracy: 0.01)
    }

    private func solid(red: CGFloat, green: CGFloat, blue: CGFloat,
                       alpha: CGFloat = 1) -> CIImage {
        CIImage(color: color(red: red, green: green, blue: blue, alpha: alpha))
            .cropped(to: CGRect(x: 0, y: 0, width: 72, height: 48))
    }

    private func color(red: CGFloat, green: CGFloat, blue: CGFloat,
                       alpha: CGFloat = 1) -> CIColor {
        CIColor(red: red, green: green, blue: blue, alpha: alpha,
                colorSpace: linearSpace)!
    }

    private func makeContext() -> CIContext {
        CIContext(options: [
            .workingColorSpace: linearSpace,
            .outputColorSpace: linearSpace,
            .workingFormat: CIFormat.RGBAf,
            .outputPremultiplied: false,
            .cacheIntermediates: false
        ])
    }
}

import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class AutomaticSafetyTests: XCTestCase {
    private typealias RGBA = (r: Float, g: Float, b: Float, a: Float)

    private let analyzer = PhotoAnalyzer()
    private lazy var engine = PhotoEngine()
    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var renderContext = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: false,
        .cacheIntermediates: false
    ])

    func testDefaultAndAllProposalsPreserveBaselineWhiteBalanceAndAttachSafety() throws {
        XCTAssertFalse(AdjustmentSettings().autoExposure)

        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        baseline.autoWhiteBalance = false
        baseline.temperature = 0.12
        baseline.tint = -0.04
        let warmGray = flatImage(r: 0.21, g: 0.20, b: 0.19)

        let analysis = try analyzer.analyze(image: warmGray, properties: [:], baseline: baseline)
        XCTAssertEqual(analysis.proposals.map(\.id), ["balanced", "bright", "soft"])
        for proposal in analysis.proposals {
            XCTAssertFalse(proposal.settings.autoExposure)
            XCTAssertFalse(proposal.settings.autoWhiteBalance)
            XCTAssertEqual(proposal.settings.temperature, baseline.temperature, accuracy: 0.0001)
            XCTAssertEqual(proposal.settings.tint, baseline.tint, accuracy: 0.0001)
            let safety = try XCTUnwrap(proposal.safety)
            XCTAssertTrue(safety.retainedFraction.isFinite)
            XCTAssertTrue((0...1).contains(safety.retainedFraction))
            XCTAssertTrue(safety.exposureDeltaEV.isFinite)
        }
    }

    func testExplicitWhiteBalanceImprovesNeutralCastInRenderedPixels() throws {
        let source = flatImage(r: 0.21, g: 0.20, b: 0.19)
        var settings = AdjustmentSettings()
        settings.autoExposure = false
        settings.autoWhiteBalance = true

        let before = try render(source)
        let after = try render(try engine.process(source, settings: settings, lut: nil).image)
        let inputSpread = channelSpread(before)
        let outputSpread = channelSpread(after)

        XCTAssertGreaterThan(inputSpread, 0.015)
        XCTAssertLessThan(outputSpread, inputSpread * 0.1)
    }

    func testSparseHighlightSceneGetsSmallExposureChangeInProposalAndPixels() throws {
        let source = sparseHighlightImage()
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        let analysis = try analyzer.analyze(image: source, properties: [:], baseline: baseline)
        let balanced = try XCTUnwrap(analysis.proposals.first { $0.id == "balanced" })
        let delta = balanced.settings.exposureEV - baseline.exposureEV

        XCTAssertLessThanOrEqual(abs(delta), 0.25 + 0.0001)
        XCTAssertLessThanOrEqual(try XCTUnwrap(balanced.safety).exposureDeltaEV, 0.25 + 0.0001)

        let inputPixels = try render(source)
        let output = try engine.process(source, settings: balanced.settings, lut: nil).image
        let outputPixels = try render(output)
        let inputMedian = try XCTUnwrap(medianLuminance(inputPixels))
        let outputMedian = try XCTUnwrap(medianLuminance(outputPixels))
        XCTAssertLessThanOrEqual(log2(outputMedian / inputMedian), 0.30)
        XCTAssertLessThanOrEqual(introducedFraction(before: inputPixels, after: outputPixels,
                                                    threshold: 0.985), 0.005 + 0.0001)
    }

    func testFogHighKeyAndLowKeyRemainNearTheirInputTone() throws {
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        let fixtures: [(String, CIImage, ClosedRange<Double>)] = [
            ("fog", flatImage(r: 0.35, g: 0.35, b: 0.35), 0.25...0.45),
            ("high-key", flatImage(r: 0.92, g: 0.92, b: 0.92), 0.65...1.05),
            ("low-key", flatImage(r: 0.02, g: 0.02, b: 0.02), 0.01...0.03)
        ]

        for (name, source, acceptableMedian) in fixtures {
            let analysis = try analyzer.analyze(image: source, properties: [:], baseline: baseline)
            let inputMedian = try XCTUnwrap(medianLuminance(try render(source)), name)
            for proposal in analysis.proposals {
                XCTAssertLessThanOrEqual(proposal.settings.contrast, baseline.contrast + 0.0001,
                                         "\(name): low-range scenes should not receive automatic contrast lift")
                XCTAssertTrue(proposal.safety != nil, "\(name): each proposal carries a safety report")
            }

            let balanced = try XCTUnwrap(analysis.proposals.first { $0.id == "balanced" })
            let output = try engine.process(source, settings: balanced.settings, lut: nil).image
            let outputMedian = try XCTUnwrap(medianLuminance(try render(output)))
            XCTAssertTrue(acceptableMedian.contains(outputMedian), "\(name): P50 moved from \(inputMedian) to \(outputMedian)")
            XCTAssertLessThanOrEqual(abs(log2(outputMedian / inputMedian)), 0.30,
                                     "\(name): automatic correction should remain a small tonal change")
        }
    }

    func testSafetyEvaluatorBacksOffExposureToAvoidNewWhitePixels() throws {
        let source = twoToneImage(first: 0.60, second: 0.10, firstShare: 0.5)
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        var requested = baseline
        requested.exposureEV += 2.0

        let limited = try AutomaticSafetyEvaluator.limit(source: source, baseline: baseline,
                                                          requested: requested, engine: engine)
        XCTAssertLessThan(limited.report.retainedFraction, 1.0)
        XCTAssertGreaterThan(limited.report.requestedHighlightFraction, 0.49)
        XCTAssertLessThanOrEqual(limited.report.introducedHighlightFraction, 0.005 + 0.0001)
        XCTAssertGreaterThan(limited.report.exposureDeltaEV, 0)
        XCTAssertLessThan(limited.report.exposureDeltaEV, 2.0)

        let baselinePixels = try render(try engine.process(source, settings: baseline, lut: nil).image)
        let outputPixels = try render(try engine.process(source, settings: limited.settings, lut: nil).image)
        XCTAssertLessThanOrEqual(introducedFraction(before: baselinePixels, after: outputPixels,
                                                    threshold: 0.985), 0.005 + 0.0001)
    }

    func testSafetyEvaluatorBacksOffExposureToAvoidNewBlackPixels() throws {
        let source = twoToneImage(first: 0.60, second: 0.02, firstShare: 0.5)
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        var requested = baseline
        requested.exposureEV -= 4.0

        let limited = try AutomaticSafetyEvaluator.limit(source: source, baseline: baseline,
                                                          requested: requested, engine: engine)
        XCTAssertLessThan(limited.report.retainedFraction, 1.0)
        XCTAssertGreaterThan(limited.report.requestedShadowFraction, 0.49)
        XCTAssertLessThanOrEqual(limited.report.introducedShadowFraction, 0.005 + 0.0001)
        XCTAssertLessThan(limited.report.exposureDeltaEV, 0)

        let baselinePixels = try render(try engine.process(source, settings: baseline, lut: nil).image)
        let outputPixels = try render(try engine.process(source, settings: limited.settings, lut: nil).image)
        XCTAssertLessThanOrEqual(introducedFraction(before: baselinePixels, after: outputPixels,
                                                    threshold: 0.002, below: true), 0.005 + 0.0001)
    }

    func testSafetyUsesVisibleAlphaAndHandlesNonzeroExtent() throws {
        let source = transparentWhiteOverDarkImage().transformed(
            by: CGAffineTransform(translationX: 37, y: -19))
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        var requested = baseline
        requested.exposureEV = 2.0

        let limited = try AutomaticSafetyEvaluator.limit(source: source, baseline: baseline,
                                                          requested: requested, engine: engine)
        XCTAssertEqual(limited.report.retainedFraction, 1.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(limited.report.requestedHighlightFraction, 0.005)
        XCTAssertLessThanOrEqual(limited.report.introducedHighlightFraction, 0.005)

        let output = try engine.process(source, settings: limited.settings, lut: nil).image
        XCTAssertEqual(output.extent.origin.x, source.extent.origin.x, accuracy: 0.001)
        XCTAssertEqual(output.extent.origin.y, source.extent.origin.y, accuracy: 0.001)

        let invisible = pixelImage(width: 64, height: 64) { _, _ in (0.8, 0.8, 0.8, 0) }
        XCTAssertThrowsError(try AutomaticSafetyEvaluator.limit(source: invisible, baseline: baseline,
                                                                 requested: requested, engine: engine))
    }

    func testBaselinePixelsAreMeasuredBeforeAutomaticExposureDelta() throws {
        let source = twoToneImage(first: 0.10, second: 0.30, firstShare: 0.6)
        var noBaseline = AdjustmentSettings()
        noBaseline.autoExposure = false
        var raisedBaseline = noBaseline
        raisedBaseline.exposureEV = 0.8

        let unraised = try analyzer.analyze(image: source, properties: [:], baseline: noBaseline)
        let raised = try analyzer.analyze(image: source, properties: [:], baseline: raisedBaseline)
        let unraisedEV = try XCTUnwrap(unraised.proposals.first { $0.id == "balanced" }).settings.exposureEV
            - noBaseline.exposureEV
        let raisedEV = try XCTUnwrap(raised.proposals.first { $0.id == "balanced" }).settings.exposureEV
            - raisedBaseline.exposureEV

        XCTAssertGreaterThan(unraisedEV, raisedEV + 0.05)
        XCTAssertGreaterThanOrEqual(unraisedEV, -0.25)
        XCTAssertLessThanOrEqual(unraisedEV, 0.25 + 0.0001)
        XCTAssertGreaterThanOrEqual(raisedEV, -0.25)
        XCTAssertLessThanOrEqual(raisedEV, 0.25 + 0.0001)
    }

    func testPartiallyTransparentHighlightsUseAlphaWeightWithoutUnpremultiplyingAgain() throws {
        let baseline = AdjustmentSettings()
        var requested = baseline
        requested.exposureEV = 2
        func fixture(alpha: Float) -> CIImage {
            pixelImage(width: 256, height: 64) { x, _ in
                x < 128 ? (0.1, 0.1, 0.1, 1) : (0.6, 0.6, 0.6, alpha)
            }
        }
        let faint = try AutomaticSafetyEvaluator.limit(source: fixture(alpha: 0.005),
            baseline: baseline, requested: requested, engine: engine)
        XCTAssertEqual(faint.report.retainedFraction, 1)
        XCTAssertEqual(faint.report.introducedHighlightFraction, 0.005 / 1.005, accuracy: 0.00001)
        let visible = try AutomaticSafetyEvaluator.limit(source: fixture(alpha: 0.01),
            baseline: baseline, requested: requested, engine: engine)
        XCTAssertGreaterThan(visible.report.requestedHighlightFraction, 0.009)
        XCTAssertLessThan(visible.report.retainedFraction, 1)
        XCTAssertLessThanOrEqual(visible.report.introducedHighlightFraction, 0.005)
    }

    func testFineHighlightsAreThresholdedBeforeDownsampling() throws {
        let source = pixelImage(width: 384, height: 384) { x, y in
            let value: Float = (x + y) % 2 == 0 ? 0.98 : 0.10
            return (value, value, value, 1)
        }
        let baseline = AdjustmentSettings()
        var requested = baseline
        requested.exposureEV = 0.10
        let limited = try AutomaticSafetyEvaluator.limit(source: source, baseline: baseline,
            requested: requested, engine: engine)
        XCTAssertEqual(limited.report.requestedHighlightFraction, 0.5, accuracy: 0.001)
        XCTAssertLessThan(limited.report.retainedFraction, 1)
        XCTAssertLessThanOrEqual(limited.report.introducedHighlightFraction, 0.005)
        let before = try render(source)
        let after = try render(try engine.process(source, settings: limited.settings, lut: nil).image)
        XCTAssertLessThanOrEqual(introducedFraction(before: before, after: after, threshold: 1), 0.005)
        print("AUTO_SAFETY_NATIVE 384x384 requested=\(limited.report.requestedHighlightFraction) retained=\(limited.report.retainedFraction) introduced=\(limited.report.introducedHighlightFraction)")
    }

    func testContrastIncreaseThatCreatesNegativeChannelsIsReduced() throws {
        let source = twoToneImage(first: 0.03, second: 0.3, firstShare: 0.5)
        let baseline = AdjustmentSettings()
        var requested = baseline
        requested.contrast = 2
        let limited = try AutomaticSafetyEvaluator.limit(source: source, baseline: baseline,
            requested: requested, engine: engine)
        XCTAssertGreaterThan(limited.report.requestedShadowFraction, 0.49)
        XCTAssertLessThan(limited.report.retainedFraction, 1)
        XCTAssertLessThanOrEqual(limited.report.introducedShadowFraction, 0.005)
        let output = try render(try engine.process(source, settings: limited.settings, lut: nil).image)
        XCTAssertTrue(output.enumerated().filter { $0.offset % 4 != 3 }.allSatisfy { $0.element >= 0 })
    }

    func testNativeAreaCheckRejectsOneInvalidVisiblePixel() throws {
        let reference = flatImage(r: 0.3, g: 0.3, b: 0.3, width: 384, height: 384)
        for invalid: Float in [.nan, .infinity] {
            let candidate = pixelImage(width: 384, height: 384) { x, y in
                x == 17 && y == 23 ? (invalid, 0.3, 0.3, 1) : (0.3, 0.3, 0.3, 1)
            }
            XCTAssertThrowsError(try AutomaticSafetyEvaluator.areaFractions(
                reference: reference, candidate: candidate, context: engine.context))
        }
        let transparentInvalid = pixelImage(width: 384, height: 384) { x, y in
            x == 17 && y == 23 ? (.nan, 0, 0, 0) : (0.3, 0.3, 0.3, 1)
        }
        let finite = try AutomaticSafetyEvaluator.areaFractions(reference: transparentInvalid,
            candidate: transparentInvalid, context: engine.context)
        XCTAssertEqual(finite.highlights, 0)
        XCTAssertEqual(finite.shadows, 0)
    }

    func testOldAnalysisJSONWithoutSafetyStillDecodes() throws {
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        let analysis = try analyzer.analyze(image: flatImage(r: 0.3, g: 0.3, b: 0.3),
                                            properties: [:], baseline: baseline)
        let encoded = try JSONEncoder().encode(analysis)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var proposals = try XCTUnwrap(object["proposals"] as? [[String: Any]])
        for index in proposals.indices { proposals[index].removeValue(forKey: "safety") }
        object["proposals"] = proposals

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PhotoAnalysis.self, from: legacyData)
        XCTAssertTrue(decoded.proposals.allSatisfy { $0.safety == nil })
    }

    func testBatchRecipeCarriesOneManualDeltaAndRejectsNonFiniteCurrent() throws {
        let source = flatImage(r: 0.18, g: 0.18, b: 0.18)
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        let analysis = try analyzer.analyze(image: source, properties: [:], baseline: baseline)
        let reference = try XCTUnwrap(analysis.proposals.first { $0.id == "balanced" }).settings
        let recipe = AutomaticBatchRecipe(styleID: "balanced", baseline: baseline,
                                          referenceSettings: reference)

        var current = reference
        current.exposureEV += 0.20
        current.lutIntensity = 0.82
        current.masks = [LocalMask(name: "manual", exposureEV: 0.1)]
        let resolved = try recipe.resolve(analysis: analysis, current: current)
        XCTAssertEqual(resolved.exposureEV - reference.exposureEV, 0.20, accuracy: 0.001)
        XCTAssertEqual(resolved.lutIntensity, current.lutIntensity)
        XCTAssertEqual(resolved.masks, current.masks)

        var invalid = current
        invalid.exposureEV = .nan
        XCTAssertThrowsError(try recipe.resolve(analysis: analysis, current: invalid))
    }

    private func flatImage(r: Float, g: Float, b: Float,
                           width: Int = 64, height: Int = 64) -> CIImage {
        pixelImage(width: width, height: height) { _, _ in (r, g, b, 1) }
    }

    private func sparseHighlightImage() -> CIImage {
        pixelImage(width: 200, height: 100) { x, y in
            let index = y * 200 + x
            if index < 18_000 { return (0.05, 0.05, 0.05, 1) }
            if index < 19_780 { return (0.30, 0.30, 0.30, 1) }
            if index < 19_900 { return (0.70, 0.70, 0.70, 1) }
            return (1.0, 1.0, 1.0, 1)
        }
    }

    private func twoToneImage(first: Float, second: Float, firstShare: Double,
                              width: Int = 100, height: Int = 100) -> CIImage {
        let firstCount = Int(Double(width * height) * firstShare)
        return pixelImage(width: width, height: height) { x, y in
            let value = y * width + x < firstCount ? first : second
            return (value, value, value, 1)
        }
    }

    private func transparentWhiteOverDarkImage(width: Int = 64, height: Int = 64) -> CIImage {
        pixelImage(width: width, height: height) { x, _ in
            if x < width / 2 { return (0.10, 0.10, 0.10, 1) }
            return (1, 1, 1, 0)
        }
    }

    private func pixelImage(width: Int, height: Int,
                            pixel: (Int, Int) -> RGBA) -> CIImage {
        var components = [Float]()
        components.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                // CIImage bitmap data is premultiplied; callers specify straight RGB.
                components.append(value.r * value.a)
                components.append(value.g * value.a)
                components.append(value.b * value.a)
                components.append(value.a)
            }
        }
        let data = components.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        return CIImage(bitmapData: data,
                       bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                       size: CGSize(width: width, height: height),
                       format: .RGBAf,
                       colorSpace: linearColorSpace)
    }

    private func render(_ image: CIImage) throws -> [Float] {
        let bounds = image.extent.integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 0, height > 0 else { throw TestImageError.emptyExtent }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            renderContext.render(image, toBitmap: buffer.baseAddress!,
                                 rowBytes: width * 4 * MemoryLayout<Float>.stride,
                                 bounds: bounds, format: .RGBAf, colorSpace: linearColorSpace)
        }
        return pixels
    }

    private func channelSpread(_ pixels: [Float]) -> Double {
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3])
            guard alpha > 0.001 else { continue }
            red += Double(pixels[offset]) * alpha
            green += Double(pixels[offset + 1]) * alpha
            blue += Double(pixels[offset + 2]) * alpha
            weight += alpha
        }
        guard weight > 0 else { return 0 }
        let channels = [red / weight, green / weight, blue / weight]
        return (channels.max() ?? 0) - (channels.min() ?? 0)
    }

    private func medianLuminance(_ pixels: [Float]) -> Double? {
        var values: [Double] = []
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[offset + 3] > 0.001 else { continue }
            values.append(max(0, 0.2126 * Double(pixels[offset])
                              + 0.7152 * Double(pixels[offset + 1])
                              + 0.0722 * Double(pixels[offset + 2])))
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    private func introducedFraction(before: [Float], after: [Float], threshold: Float,
                                   below: Bool = false) -> Double {
        guard before.count == after.count, !before.isEmpty else { return 0 }
        var total = 0.0
        var introduced = 0.0
        for offset in stride(from: 0, to: before.count, by: 4) {
            let alpha = Double(before[offset + 3])
            guard alpha > 0.001 else { continue }
            let beforeValue = max(before[offset], max(before[offset + 1], before[offset + 2]))
            let afterValue = max(after[offset], max(after[offset + 1], after[offset + 2]))
            total += alpha
            let wasInRange = below ? beforeValue <= threshold : beforeValue >= threshold
            let isInRange = below ? afterValue <= threshold : afterValue >= threshold
            if !wasInRange && isInRange { introduced += alpha }
        }
        return total > 0 ? introduced / total : 0
    }

    private enum TestImageError: Error {
        case emptyExtent
    }
}

import CoreGraphics
import CoreImage
import Foundation
import Metal
import XCTest
@testable import PhotoCore

final class TonalCurveTests: XCTestCase {
    private typealias RGBA = (r: Float, g: Float, b: Float, a: Float)

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var cpuContext = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: true,
        .useSoftwareRenderer: true,
        .cacheIntermediates: false
    ])
    private lazy var renderContext = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: true,
        .cacheIntermediates: false
    ])
    private lazy var engine = PhotoEngine()
    private let analyzer = PhotoAnalyzer()

    func testNeutralCurveIsExactNoOpAndPreservesAlphaAndTranslatedExtent() throws {
        let source = image(width: 4, height: 1, pixels: [
            (0.0, 0.0, 0.0, 0.0), (0.04, 0.12, 0.28, 0.25),
            (0.18, 0.18, 0.18, 0.5), (0.8, 0.3, 0.1, 1)
        ]).transformed(by: CGAffineTransform(translationX: 37, y: -19))

        let output = try TonalCurveEngine.apply(source, settings: .init())

        XCTAssertEqual(output.extent.origin.x, source.extent.origin.x, accuracy: 0)
        XCTAssertEqual(output.extent.origin.y, source.extent.origin.y, accuracy: 0)
        XCTAssertEqual(output.extent.width, source.extent.width, accuracy: 0)
        XCTAssertEqual(output.extent.height, source.extent.height, accuracy: 0)
        XCTAssertEqual(try render(output, context: cpuContext),
                       try render(source, context: cpuContext))
    }

    func testShadowEVRaisesShadowKnotWithoutApplyingGlobalExposure() throws {
        let source = image(width: 3, height: 1, pixels: [
            (0.0625, 0.0625, 0.0625, 1), (0.6, 0.6, 0.6, 1), (1, 1, 1, 1)
        ])
        var settings = TonalCurveSettings()
        settings.shadowsEV = 1

        let pixels = try render(TonalCurveEngine.apply(source, settings: settings), context: cpuContext)

        XCTAssertEqual(pixels[0], 0.125, accuracy: 0.001)
        XCTAssertEqual(pixels[4], 0.6, accuracy: 0.001)
        XCTAssertEqual(pixels[8], 1, accuracy: 0.001)
    }

    func testCurvePreservesRGBRatiosAndKeepsNeutralGrayNeutral() throws {
        let scale = 0.18 / (0.2126 * 0.5 + 0.7152 + 0.0722 * 2)
        let source = image(width: 2, height: 1, pixels: [
            (Float(0.5 * scale), Float(scale), Float(2 * scale), 0.6),
            (0.18, 0.18, 0.18, 1)
        ])
        var settings = TonalCurveSettings()
        settings.midtonesEV = 0.75

        let pixels = try render(TonalCurveEngine.apply(source, settings: settings), context: cpuContext)

        XCTAssertGreaterThan(pixels[0], 0)
        XCTAssertEqual(pixels[0] / pixels[1], 0.5, accuracy: 0.002)
        XCTAssertEqual(pixels[2] / pixels[1], 2, accuracy: 0.002)
        XCTAssertEqual(pixels[3], 0.6, accuracy: 0.001)
        XCTAssertEqual(pixels[4], pixels[5], accuracy: 0.0001)
        XCTAssertEqual(pixels[5], pixels[6], accuracy: 0.0001)
        XCTAssertGreaterThan(pixels[4], 0.18)
    }

    func testBlackPixelsRemainBlackWhenBlackAndWhiteControlsMove() throws {
        let source = image(width: 2, height: 1, pixels: [
            (0, 0, 0, 0.5), (0.25, 0.25, 0.25, 1)
        ])
        var settings = TonalCurveSettings()
        settings.blacksEV = 3
        settings.whitesEV = 3

        let pixels = try render(TonalCurveEngine.apply(source, settings: settings), context: cpuContext)

        XCTAssertEqual(pixels[0], 0, accuracy: 0)
        XCTAssertEqual(pixels[1], 0, accuracy: 0)
        XCTAssertEqual(pixels[2], 0, accuracy: 0)
        XCTAssertEqual(pixels[3], 0.5, accuracy: 0.001)

        let nearBlackValues: [Float] = [1e-7, 5e-7, 9e-7, 1e-6, 1.1e-6, 2e-6]
        let nearBlack = image(width: nearBlackValues.count, height: 1,
            pixels: nearBlackValues.map { ($0, $0, $0, 1) })
        let darkPixels = try render(TonalCurveEngine.apply(nearBlack,
            settings: TonalCurveSettings(blacksEV: -3)), context: cpuContext)
        var previous = -Double.infinity
        for index in nearBlackValues.indices {
            let gray = Double(darkPixels[index * 4])
            XCTAssertTrue(gray.isFinite)
            XCTAssertGreaterThanOrEqual(gray + 1e-12, previous,
                                        "near-black curve reversed at \(nearBlackValues[index])")
            previous = gray
        }
    }

    func testExtremeAlternatingEVsProduceFiniteMonotoneSmoothGrayRamp() throws {
        let settings = TonalCurveSettings(blacksEV: 3, shadowsEV: -3, midtonesEV: 3,
                                          highlightsEV: -3, whitesEV: 3)
        try TonalCurveEngine.validate(settings)
        let count = 1024
        let ramp = image(width: count, height: 1, pixels: (0..<count).map { index in
            let value = Float(index) / Float(count - 1)
            return (value, value, value, 1)
        })

        let pixels = try render(TonalCurveEngine.apply(ramp, settings: settings), context: cpuContext)
        var previous = -Double.infinity
        for index in 0..<count {
            let offset = index * 4
            let red = Double(pixels[offset]), green = Double(pixels[offset + 1])
            let blue = Double(pixels[offset + 2]), alpha = Double(pixels[offset + 3])
            XCTAssertTrue(red.isFinite && green.isFinite && blue.isFinite && alpha.isFinite)
            XCTAssertEqual(red, green, accuracy: 0.0002)
            XCTAssertEqual(green, blue, accuracy: 0.0002)
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            XCTAssertGreaterThanOrEqual(luminance + 0.000001, previous,
                                        "gray ramp reversed near sample \(index)")
            if previous.isFinite {
                XCTAssertLessThanOrEqual(luminance - previous, 0.03,
                                         "visible one-step jump near sample \(index)")
            }
            previous = luminance
        }

        let model = MonotoneTonalCurve(settings: settings)
        let lowerLog = Foundation.log2(1e-8)
        let upperLog = Foundation.log2(65_504.0)
        var inputs = (0...16_384).map { index in
            Foundation.pow(2.0, lowerLog + (upperLog - lowerLog)
                * Double(index) / 16_384.0)
        }
        inputs.append(contentsOf: [0, 1e-7, 5e-7, 9e-7, 1e-6, 1.1e-6, 2e-6,
                                   0.0625, 0.18, 0.6, 1, 16, 60_000, 65_504])
        inputs.sort()
        var previousMapped = -Double.infinity
        for input in inputs {
            let mapped = model.evaluateLuminance(input)
            XCTAssertTrue(mapped.isFinite, "CPU curve returned a non-finite value at \(input)")
            XCTAssertGreaterThanOrEqual(mapped, previousMapped,
                                        "CPU curve reversed between input luminances at \(input)")
            previousMapped = mapped
        }
    }

    func testSoftwareAndMetalContextsRenderCurveWithinFloatTolerance() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available for the GPU comparison.")
        }
        let gpuContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: linearColorSpace,
            .outputColorSpace: linearColorSpace,
            .workingFormat: CIFormat.RGBAf,
            .outputPremultiplied: true,
            .cacheIntermediates: false
        ])
        let source = image(width: 96, height: 1, pixels: (0..<96).map { index in
            let x = Float(index) / 95
            let alpha: Float = index % 3 == 0 ? 0.4 : 1
            return (0.02 + 0.55 * x, 0.01 + 0.35 * x, 0.04 + 0.75 * x, alpha)
        })
        let settings = TonalCurveSettings(blacksEV: -0.3, shadowsEV: 0.65,
                                          midtonesEV: 0.2, highlightsEV: -0.35, whitesEV: 0.4)
        let output = try TonalCurveEngine.apply(source, settings: settings)
        let cpu = try render(output, context: cpuContext)
        let gpu = try render(output, context: gpuContext)

        XCTAssertEqual(cpu.count, gpu.count)
        for index in cpu.indices {
            XCTAssertTrue(cpu[index].isFinite && gpu[index].isFinite)
            XCTAssertEqual(cpu[index], gpu[index], accuracy: 0.001)
        }

        let nearBlackValues: [Float] = [1e-7, 5e-7, 9e-7, 1e-6, 1.1e-6, 2e-6]
        let nearBlack = image(width: nearBlackValues.count, height: 1,
            pixels: nearBlackValues.map { ($0, $0, $0, 1) })
        let blackSettings = TonalCurveSettings(blacksEV: -3)
        let blackModel = MonotoneTonalCurve(settings: blackSettings)
        let blackOutput = try TonalCurveEngine.apply(nearBlack, settings: blackSettings)
        let cpuBlack = try render(blackOutput, context: cpuContext)
        let gpuBlack = try render(blackOutput, context: gpuContext)
        var previousCPU = -Double.infinity
        var previousGPU = -Double.infinity
        for index in nearBlackValues.indices {
            let offset = index * 4
            let cpuGray = Double(cpuBlack[offset])
            let gpuGray = Double(gpuBlack[offset])
            XCTAssertTrue(cpuGray.isFinite && gpuGray.isFinite)
            XCTAssertGreaterThanOrEqual(cpuGray + 1e-12, previousCPU,
                                        "CPU near-black curve reversed at \(nearBlackValues[index])")
            XCTAssertGreaterThanOrEqual(gpuGray + 1e-12, previousGPU,
                                        "GPU near-black curve reversed at \(nearBlackValues[index])")
            XCTAssertEqual(cpuGray, gpuGray, accuracy: 1e-7)
            let expected = blackModel.evaluateLuminance(Double(nearBlackValues[index]))
            let tolerance = max(1e-12, abs(expected) * 0.00001)
            XCTAssertEqual(cpuGray, expected, accuracy: tolerance)
            XCTAssertEqual(gpuGray, expected, accuracy: tolerance)
            previousCPU = cpuGray
            previousGPU = gpuGray
        }

        let modelValues: [Float] = [1e-7, 5e-7, 9e-7, 1e-6, 1.1e-6, 2e-6,
                                    0.0001, 0.02, 0.0625, 0.18, 0.6, 1, 4, 16]
        let modelInput = image(width: modelValues.count, height: 1,
            pixels: modelValues.map { ($0, $0, $0, 1) })
        let modelCurve = MonotoneTonalCurve(settings: settings)
        let modelOutput = try TonalCurveEngine.apply(modelInput, settings: settings)
        let cpuModelPixels = try render(modelOutput, context: cpuContext)
        let gpuModelPixels = try render(modelOutput, context: gpuContext)
        for index in modelValues.indices {
            let input = Double(modelValues[index])
            let expected = modelCurve.evaluateLuminance(input)
            let tolerance = max(1e-12, abs(expected) * 0.00001)
            XCTAssertEqual(Double(cpuModelPixels[index * 4]), expected, accuracy: tolerance)
            XCTAssertEqual(Double(gpuModelPixels[index * 4]), expected, accuracy: tolerance)
        }

        let highGray = image(width: 1, height: 1, pixels: [(60_000, 60_000, 60_000, 1)])
        let whiteOutput = try TonalCurveEngine.apply(highGray,
            settings: TonalCurveSettings(whitesEV: 3))
        let cpuWhite = try render(whiteOutput, context: cpuContext)
        let gpuWhite = try render(whiteOutput, context: gpuContext)
        let expectedWhite = MonotoneTonalCurve(settings: TonalCurveSettings(whitesEV: 3))
            .evaluateLuminance(60_000)
        for channel in 0..<4 {
            XCTAssertTrue(cpuWhite[channel].isFinite && gpuWhite[channel].isFinite)
            let tolerance = max(0.000001, abs(Double(cpuWhite[channel])) * 0.00001)
            XCTAssertEqual(Double(cpuWhite[channel]), Double(gpuWhite[channel]), accuracy: tolerance)
        }
        XCTAssertEqual(Double(cpuWhite[0]), expectedWhite,
                       accuracy: max(0.000001, abs(expectedWhite) * 0.00001))
        XCTAssertEqual(Double(gpuWhite[0]), expectedWhite,
                       accuracy: max(0.000001, abs(expectedWhite) * 0.00001))
    }

    func testValidationAcceptsClosedEVBoundsAndRejectsEveryNonFiniteOrOutOfRangeField() throws {
        let fields: [WritableKeyPath<TonalCurveSettings, Double>] = [
            \.blacksEV, \.shadowsEV, \.midtonesEV, \.highlightsEV, \.whitesEV
        ]
        for field in fields {
            var lower = TonalCurveSettings(); lower[keyPath: field] = -3
            var upper = TonalCurveSettings(); upper[keyPath: field] = 3
            XCTAssertNoThrow(try TonalCurveEngine.validate(lower))
            XCTAssertNoThrow(try TonalCurveEngine.validate(upper))

            for invalid in [Double.nan, .infinity, -.infinity, -3.0001, 3.0001] {
                var settings = TonalCurveSettings()
                settings[keyPath: field] = invalid
                XCTAssertThrowsError(try TonalCurveEngine.validate(settings))
            }
        }
    }

    func testLegacyJSONWithoutCurveRemainsReadableAndOldRecipeCannotCarryNewCurve() throws {
        XCTAssertEqual(Recipe().version, 6)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Recipe()))
                                   as? [String: Any])
        object["version"] = 4
        var adjustments = try XCTUnwrap(object["adjustments"] as? [String: Any])
        adjustments.removeValue(forKey: "tonalCurve")
        object["adjustments"] = adjustments
        let legacy = try JSONDecoder().decode(Recipe.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.version, 4)
        XCTAssertNil(legacy.adjustments.tonalCurve)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("atelier-tonal-curve-recipe-\(UUID())", isDirectory: true)
        let input = root.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let processor = BatchProcessor()
        let accepted = try processor.run(items: [], inputRoot: input,
            outputRoot: root.appendingPathComponent("legacy-output"), recipe: legacy,
            lut: nil, cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertNotNil(accepted.manifestURL)

        var incompatible = legacy
        incompatible.adjustments.tonalCurve = TonalCurveSettings(highlightsEV: 0.25)
        XCTAssertThrowsError(try processor.run(items: [], inputRoot: input,
            outputRoot: root.appendingPathComponent("incompatible-output"), recipe: incompatible,
            lut: nil, cancellation: CancellationToken(), onEvent: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("incompatible-output").path))
    }

    func testAutomaticSafetyBacksOffWhiteOverflowAndKeepsExistingHalfPercentAllowance() throws {
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        var requested = baseline
        requested.tonalCurve = TonalCurveSettings(whitesEV: 3)

        let broadWhiteArea = image(width: 100, height: 100, pixels: (0..<10_000).map { index in
            let value: Float = index < 5_000 ? 0.95 : 0.2
            return (value, value, value, 1)
        })
        let backedOff = try AutomaticSafetyEvaluator.limit(source: broadWhiteArea, baseline: baseline,
            requested: requested, engine: engine)
        XCTAssertLessThan(backedOff.report.retainedFraction, 1)
        XCTAssertGreaterThan(backedOff.report.requestedHighlightFraction, 0.49)
        XCTAssertLessThanOrEqual(backedOff.report.introducedHighlightFraction, 0.005 + 0.000001)
        XCTAssertLessThan(try XCTUnwrap(backedOff.settings.tonalCurve).whitesEV, 3)

        let sparseWhiteArea = image(width: 100, height: 100, pixels: (0..<10_000).map { index in
            let value: Float = index < 40 ? 0.95 : 0.2
            return (value, value, value, 1)
        })
        let withinExistingAllowance = try AutomaticSafetyEvaluator.limit(source: sparseWhiteArea,
            baseline: baseline, requested: requested, engine: engine)
        XCTAssertEqual(withinExistingAllowance.report.retainedFraction, 1, accuracy: 0)
        XCTAssertGreaterThan(withinExistingAllowance.report.requestedHighlightFraction, 0.003)
        XCTAssertLessThanOrEqual(withinExistingAllowance.report.requestedHighlightFraction, 0.005 + 0.000001)
        XCTAssertEqual(try XCTUnwrap(withinExistingAllowance.settings.tonalCurve).whitesEV,
                       3, accuracy: 0.001)
    }

    func testAutomaticBatchCarriesCurveAndAppliesManualDeltaExactlyOnce() throws {
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        let sourceImage = image(width: 32, height: 16, pixels: (0..<512).map { index in
            let value = Float(index % 32) / 31 * 0.7 + 0.03
            return (value, value, value, 1)
        })
        let analyzed = try analyzer.analyze(image: sourceImage, properties: [:], baseline: baseline)
        let original = try XCTUnwrap(analyzed.proposals.first { $0.id == "balanced" })
        var proposalSettings = original.settings
        proposalSettings.tonalCurve = TonalCurveSettings(blacksEV: 0.1, shadowsEV: -0.15,
            midtonesEV: 0.2, highlightsEV: -0.1, whitesEV: 0.05)
        let proposal = AutoAdjustmentProposal(id: original.id, title: original.title,
            rationale: original.rationale, confidence: original.confidence,
            confidenceBasis: original.confidenceBasis, settings: proposalSettings, safety: original.safety)
        let proposals = analyzed.proposals.map { $0.id == proposal.id ? proposal : $0 }
        let customizedAnalysis = PhotoAnalysis(summary: analyzed.summary, issues: analyzed.issues,
            metrics: analyzed.metrics, colorScene: analyzed.colorScene,
            sceneAssessment: analyzed.sceneAssessment, metadata: analyzed.metadata,
            content: analyzed.content, proposals: proposals, unsupportedReadings: analyzed.unsupportedReadings)

        var current = proposalSettings
        current.tonalCurve = TonalCurveSettings(blacksEV: 0.3, shadowsEV: -0.25,
            midtonesEV: 0.35, highlightsEV: 0.02, whitesEV: -0.15)
        current.lutIntensity = 0.82
        current.masks = [LocalMask(name: "manual", exposureEV: 0.1)]
        let recipe = AutomaticBatchRecipe(styleID: "balanced", baseline: baseline,
                                          referenceSettings: proposalSettings)

        let resolved = try recipe.resolve(analysis: customizedAnalysis, current: current)
        let curve = try XCTUnwrap(resolved.tonalCurve)

        XCTAssertEqual(curve.blacksEV, 0.3, accuracy: 0.0001)
        XCTAssertEqual(curve.shadowsEV, -0.25, accuracy: 0.0001)
        XCTAssertEqual(curve.midtonesEV, 0.35, accuracy: 0.0001)
        XCTAssertEqual(curve.highlightsEV, 0.02, accuracy: 0.0001)
        XCTAssertEqual(curve.whitesEV, -0.15, accuracy: 0.0001)
        XCTAssertEqual(resolved.lutIntensity, current.lutIntensity)
        XCTAssertEqual(resolved.masks, current.masks)

        // Off stays off across scenes even when an old recipe's reference
        // never contained a curve. A new proposal must not silently enable it.
        var disabled = current
        disabled.tonalCurve = nil
        XCTAssertNil(try recipe.resolve(analysis: customizedAnalysis, current: disabled).tonalCurve)
        let noCurveReference = AutomaticBatchRecipe(styleID: "balanced", baseline: baseline,
            referenceSettings: disabled)
        XCTAssertNil(try noCurveReference.resolve(analysis: customizedAnalysis, current: disabled).tonalCurve)
    }

    private func image(width: Int, height: Int, pixels: [RGBA]) -> CIImage {
        precondition(pixels.count == width * height)
        var components = [Float]()
        components.reserveCapacity(width * height * 4)
        for pixel in pixels {
            // CIImage(bitmapData:) expects premultiplied RGBA samples.
            components.append(pixel.r * pixel.a)
            components.append(pixel.g * pixel.a)
            components.append(pixel.b * pixel.a)
            components.append(pixel.a)
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

    private func render(_ image: CIImage, context: CIContext) throws -> [Float] {
        let bounds = image.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { throw TestImageError.emptyExtent }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!,
                           rowBytes: width * 4 * MemoryLayout<Float>.stride,
                           bounds: bounds, format: .RGBAf, colorSpace: linearColorSpace)
        }
        // Keep the readback separate from the kernel under test. The legacy
        // software renderer's outputPremultiplied=false path uses an approximate
        // reciprocal even for alpha=1 (a plain 1.0 source reads as 0.99975586).
        // Read premultiplied samples and unpremultiply here using Swift division
        // so the unchanged CPU-mirror tolerance measures the tone curve itself.
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] > 0 {
            let alpha = pixels[offset + 3]
            for channel in 0..<3 { pixels[offset + channel] /= alpha }
        }
        return pixels
    }

    private enum TestImageError: Error {
        case emptyExtent
    }
}

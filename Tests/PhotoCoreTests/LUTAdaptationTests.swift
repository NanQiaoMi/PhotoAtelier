import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class LUTAdaptationTests: XCTestCase {
    private typealias Pixel = (r: Float, g: Float, b: Float, a: Float)

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .useSoftwareRenderer: true,
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: false,
        .cacheIntermediates: false
    ])

    func testNilOrDisabledAdaptationDoesNotAttachAnAdaptationReport() throws {
        let source = flat(0.24, 0.20, 0.16)
        let engine = PhotoEngine()

        var absent = AdjustmentSettings()
        absent.autoExposure = false
        absent.autoWhiteBalance = false
        absent.adaptiveLUT = nil
        absent.colorHarmony = nil
        absent.tonalCurve = nil
        absent.lutIntensity = 0.7
        absent.lutColorSpace = .linearSRGB
        let nonIdentityLUT = try cube(redBias: 0.12)
        let legacy = try engine.process(source, settings: absent, lut: nonIdentityLUT)
        XCTAssertNil(legacy.report.lutAdaptation)

        var disabled = absent
        var options = AdaptiveLUTSettings()
        options.enabled = false
        disabled.adaptiveLUT = options
        let disabledResult = try engine.process(source, settings: disabled, lut: nonIdentityLUT)
        XCTAssertNil(disabledResult.report.lutAdaptation)
        let oldPixels = try renderedValues(legacy.image)
        let disabledPixels = try renderedValues(disabledResult.image)
        XCTAssertEqual(disabledPixels.count, oldPixels.count)
        for index in oldPixels.indices {
            XCTAssertEqual(disabledPixels[index], oldPixels[index], accuracy: 0.00001,
                           "disabled adaptation must preserve the legacy LUT path at channel \(index)")
        }

        var enabledWithoutLUT = absent
        enabledWithoutLUT.adaptiveLUT = AdaptiveLUTSettings()
        let noLUT = try engine.process(source, settings: enabledWithoutLUT, lut: nil)
        XCTAssertNil(noLUT.report.lutAdaptation)
    }

    func testRecipeV9RoundTripsEnabledAdaptationAndOlderVersionsRejectIt() throws {
        var settings = AdjustmentSettings()
        var options = AdaptiveLUTSettings()
        options.enabled = true
        options.colorProtection = 0.37
        options.skinProtection = 0.58
        options.toneProtection = 0.91
        options.preserveSourceMonochrome = false
        settings.adaptiveLUT = options

        let recipe = Recipe(adjustments: settings)
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(Recipe.self, from: data)
        XCTAssertEqual(decoded.version, 9)
        XCTAssertEqual(decoded.adjustments.adaptiveLUT, options)
        XCTAssertNoThrow(try decoded.validateVersion())

        var legacy = decoded
        legacy.version = 8
        XCTAssertThrowsError(try legacy.validateVersion(), "v8 cannot silently discard enabled adaptation")
        legacy.adjustments.adaptiveLUT?.enabled = false
        XCTAssertNoThrow(try legacy.validateVersion(), "a disabled option remains compatible with v8")
        legacy.adjustments.adaptiveLUT = nil
        XCTAssertNoThrow(try legacy.validateVersion(), "older recipes can omit the optional setting")

        var automaticBaseline = AdjustmentSettings()
        automaticBaseline.adaptiveLUT = options
        var nestedBaseline = Recipe(automatic: AutomaticBatchRecipe(
            styleID: "balanced", baseline: automaticBaseline, referenceSettings: AdjustmentSettings()))
        nestedBaseline.version = 8
        XCTAssertThrowsError(try nestedBaseline.validateVersion(),
                             "v8 cannot discard adaptation stored in automatic.baseline")

        var automaticReference = AdjustmentSettings()
        automaticReference.adaptiveLUT = options
        var nestedReference = Recipe(automatic: AutomaticBatchRecipe(
            styleID: "balanced", baseline: AdjustmentSettings(), referenceSettings: automaticReference))
        nestedReference.version = 8
        XCTAssertThrowsError(try nestedReference.validateVersion(),
                             "v8 cannot discard adaptation stored in automatic.referenceSettings")

        var oldObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var oldAdjustments = try XCTUnwrap(oldObject["adjustments"] as? [String: Any])
        oldObject["version"] = 8
        oldAdjustments.removeValue(forKey: "adaptiveLUT")
        oldObject["adjustments"] = oldAdjustments
        let oldData = try JSONSerialization.data(withJSONObject: oldObject)
        let oldRecipe = try JSONDecoder().decode(Recipe.self, from: oldData)
        XCTAssertNil(oldRecipe.adjustments.adaptiveLUT,
                     "an encoded v8 payload without the new optional key remains nil")
    }

    func testAdaptiveProtectionRejectsOutOfRangeAndNonFiniteValues() {
        let properties: [WritableKeyPath<AdaptiveLUTSettings, Double>] = [
            \.colorProtection, \.skinProtection, \.toneProtection
        ]
        for keyPath in properties {
            for invalid in [-0.001, 1.001, Double.nan, Double.infinity] {
                var options = AdaptiveLUTSettings()
                options[keyPath: keyPath] = invalid
                var settings = AdjustmentSettings()
                settings.adaptiveLUT = options
                XCTAssertThrowsError(try PhotoEngine.validate(settings),
                                     "invalid value \(invalid) at \(keyPath)")
            }
        }
    }

    func testCandidateSearchUsesToneColorAndMeasuredSkinEvidence() throws {
        var settings = AdjustmentSettings()
        settings.preserveLuminance = 0
        settings.protectNeutrals = 0
        settings.protectSkin = 0
        settings.adaptiveLUT = AdaptiveLUTSettings()
        let lut = try cube()
        let neutral = flat(0.30, 0.30, 0.30)
        let brightSaturated = flat(0.92, 0.92, 0.02)

        func probe(_ image: CIImage, selections: ContentSelectionResult? = nil) throws
            -> (LUTAdaptationReport, [(Double, Double, Double, Double)]) {
            var calls: [(Double, Double, Double, Double)] = []
            let result = try adapt(image, cube: lut, settings: settings, selections: selections) {
                intensity, luminance, skin, neutrals in
                calls.append((intensity, luminance, skin, neutrals))
                return image
            }
            return (result.report, calls)
        }

        let neutralProbe = try probe(neutral)
        let colorProbe = try probe(brightSaturated)
        XCTAssertEqual(neutralProbe.0.candidates.count, 9)
        XCTAssertEqual(neutralProbe.1.count, 8, "the zero-strength reference candidate does not invoke the renderer")
        XCTAssertEqual(neutralProbe.1[0].1, 0, accuracy: 0.000001)
        XCTAssertEqual(neutralProbe.1[0].3, 0, accuracy: 0.000001)
        XCTAssertGreaterThan(colorProbe.1[0].1, neutralProbe.1[0].1,
                             "bright pixels increase the searched luminance protection")
        XCTAssertGreaterThan(colorProbe.1[0].3, neutralProbe.1[0].3,
                             "saturated pixels increase the searched neutral protection")

        let faceMask = flat(1, 1, 1, width: 16, height: 16)
        let selections = ContentSelectionResult(
            report: ContentSelectionReport(faceStatus: "measured", faceCount: 1),
            masks: [.faceSkin: faceMask])
        let withSkin = try probe(neutral, selections: selections)
        XCTAssertEqual(withSkin.0.skinSampleCount, 256)
        XCTAssertGreaterThan(withSkin.1[0].2, neutralProbe.1[0].2,
                             "skin protection changes only when a measured mask contributes samples")
    }

    func testMonochromeLUTAndSourceGrayAreReportedAndRemainGray() throws {
        var options = AdaptiveLUTSettings()
        options.preserveSourceMonochrome = true
        var settings = AdjustmentSettings()
        settings.adaptiveLUT = options
        let monochromeLUT = try cube(monochrome: true)

        let graySource = flat(0.32, 0.32, 0.32)
        let colorized = flat(0.48, 0.34, 0.20)
        let preserved = try adapt(graySource, cube: monochromeLUT, settings: settings) {
            _, _, _, _ in colorized
        }
        XCTAssertTrue(preserved.report.sourceMonochrome)
        XCTAssertTrue(preserved.report.monochromeLUT)
        let grayPixel = try pixel(preserved.image)
        XCTAssertEqual(grayPixel.r, grayPixel.g, accuracy: 0.002)
        XCTAssertEqual(grayPixel.g, grayPixel.b, accuracy: 0.002)

        let coloredSource = flat(0.70, 0.24, 0.12)
        let desaturated = try adapt(coloredSource, cube: monochromeLUT, settings: settings) {
            _, _, _, _ in
                coloredSource.applyingFilter("CIColorControls", parameters: ["inputSaturation": 0])
        }
        XCTAssertTrue(desaturated.report.monochromeLUT)
        let output = try pixel(desaturated.image)
        XCTAssertEqual(output.r, output.g, accuracy: 0.002)
        XCTAssertEqual(output.g, output.b, accuracy: 0.002)

        let slightlyWarmGray = flat(0.30, 0.296, 0.292)
        let warmGrayResult = try adapt(slightlyWarmGray, cube: cube(), settings: settings) {
            _, _, _, _ in slightlyWarmGray
        }
        XCTAssertFalse(warmGrayResult.report.sourceMonochrome,
                       "small but measurable warmth must not be classified as a black-and-white source")
        let warmPixel = try pixel(warmGrayResult.image)
        XCTAssertGreaterThan(warmPixel.r - warmPixel.b, 0.005)
    }

    func testWarmAndCoolIdentityCandidatesDoNotApplyWhiteBalance() throws {
        let lut = try cube()
        var settings = AdjustmentSettings()
        settings.temperature = 0
        settings.tint = 0
        settings.adaptiveLUT = AdaptiveLUTSettings()
        let fixtures: [(Pixel, CIImage)] = [
            ((0.62, 0.29, 0.10, 1), flat(0.62, 0.29, 0.10)),
            ((0.09, 0.27, 0.66, 1), flat(0.09, 0.27, 0.66))
        ]

        for (expected, source) in fixtures {
            let result = try adapt(source, cube: lut, settings: settings) {
                _, _, _, _ in source
            }
            let actual = try pixel(result.image)
            XCTAssertEqual(actual.r, expected.r, accuracy: 0.003)
            XCTAssertEqual(actual.g, expected.g, accuracy: 0.003)
            XCTAssertEqual(actual.b, expected.b, accuracy: 0.003)
        }
    }

    func testMeasuredNeutralTintRiskReducesAnActualCubeLUTCandidate() throws {
        let source = flat(0.25, 0.25, 0.25)
        let unsafeLUT = try cube(redBias: 0.55)
        var options = AdaptiveLUTSettings()
        options.colorProtection = 0
        options.skinProtection = 0
        options.toneProtection = 0
        options.preserveSourceMonochrome = false
        var settings = AdjustmentSettings()
        settings.lutIntensity = 0.65
        settings.preserveLuminance = 0
        settings.protectNeutrals = 0
        settings.protectSkin = 0
        settings.adaptiveLUT = options

        let result = try adapt(source, cube: unsafeLUT, settings: settings) { intensity, _, _, _ in
            try self.renderCube(unsafeLUT, on: source, intensity: intensity)
        }
        let rejected = try XCTUnwrap(result.report.candidates.first { !$0.accepted })
        XCTAssertEqual(rejected.sampleQualityAccepted, false)
        XCTAssertNil(rejected.nativeSafetyAccepted,
                     "a sample-quality rejection should not claim to have passed or failed native checking")
        XCTAssertTrue(rejected.reasons.contains { $0.contains("中性候选染色过多") })
        XCTAssertGreaterThan(rejected.metrics.meanChange, 0.02,
                             "the rejected record must come from rendered pixel measurements")
        XCTAssertGreaterThan(result.report.effectiveIntensity, 0,
                             "the search should retain a weaker feasible film look")
        XCTAssertLessThan(result.report.effectiveIntensity, result.report.requestedIntensity)
        XCTAssertTrue(result.report.candidates.contains { $0.accepted && $0.intensity > 0 })
        let selected = try XCTUnwrap(result.report.candidates.first {
            $0.id == result.report.selectedCandidateID
        })
        XCTAssertEqual(selected.sampleQualityAccepted, true)
        XCTAssertEqual(selected.nativeSafetyAccepted, true)
        let retained = try pixel(result.image)
        XCTAssertGreaterThan(retained.r - retained.g, 0,
                             "the selected lower-strength candidate remains a measurable look")
    }

    func testDownsampleOnlyShadowCrossingDoesNotRejectNativeSafeCandidate() throws {
        let width = 384, height = 384
        let patch = 64
        let start = (width - patch) / 2
        let source = bitmap(width: width, height: height) { x, y in
            guard (start..<(start + patch)).contains(x),
                  (start..<(start + patch)).contains(y) else {
                return (0.08, 0.08, 0.08, 1)
            }
            let value: Float = x.isMultiple(of: 2) ? 0.0023 : 0.0019
            return (value, value, value, 1)
        }
        let darkeningLUT = try cube(scale: 0.65)
        var settings = AdjustmentSettings()
        settings.lutIntensity = 1
        settings.lutColorSpace = .linearSRGB
        settings.adaptiveLUT = AdaptiveLUTSettings()

        let result = try adapt(source, cube: darkeningLUT, settings: settings) { intensity, _, _, _ in
            try self.renderCube(darkeningLUT, on: source, intensity: intensity)
        }
        let selected = try XCTUnwrap(result.report.candidates.first {
            $0.id == result.report.selectedCandidateID
        })

        // The engine's lazy CI graph may fuse guarded() with the sampling
        // transform. Re-measure materialized native RGBAf images below so this
        // regression does not assume graph fusion produces the same thumbnail.
        XCTAssertGreaterThan(result.report.effectiveIntensity, 0,
                             "a diagnostic sample crossing must not force the safe candidate to zero")
        XCTAssertEqual(result.report.nativeIntroducedShadows, 0, accuracy: 0.000001,
                       "native pixels on either side of the threshold do not create a new crossing")
        XCTAssertEqual(selected.sampleQualityAccepted, true)
        XCTAssertEqual(selected.nativeSafetyAccepted, true)
        XCTAssertTrue(selected.accepted)
        XCTAssertTrue(result.report.nativeCheckedCandidateIDs?.contains(selected.id) == true)
        XCTAssertEqual(result.report.policyVersion, 2)

        let nativeReference = try materialized(source)
        let nativeCandidate = try materialized(result.image)
        let sampleWidth = 192, sampleHeight = 192
        let referenceSamples = try sampledPixels(nativeReference, width: sampleWidth, height: sampleHeight)
        let candidateSamples = try sampledPixels(nativeCandidate, width: sampleWidth, height: sampleHeight)
        let skinSamples = [Float](repeating: 0, count: sampleWidth * sampleHeight * 4)
        let measured = try LUTAdaptationEngine.measure(reference: referenceSamples,
            candidate: candidateSamples, skin: skinSamples,
            width: sampleWidth, height: sampleHeight, target: nil)
        XCTAssertGreaterThan(measured.introducedShadows, 0.0001,
                             "materialized 192px pixels should contain the averaging-only threshold crossing")
        let options = try XCTUnwrap(settings.adaptiveLUT)
        let colorDemand = min(1, result.report.scene.saturatedFraction * 0.7
                              + result.report.scene.colorDiversity * 0.3)
        XCTAssertTrue(LUTAdaptationEngine.sampleQualityViolations(measured, options: options,
            colorDemand: colorDemand, monochrome: result.report.monochromeLUT).isEmpty,
            "sample clipping is diagnostic; non-clipping quality constraints still pass")
    }

    func testLegacyAdaptationReportWithoutNativeCheckFieldsStillDecodes() throws {
        let source = flat(0.25, 0.25, 0.25)
        let result = try adapt(source, cube: cube()) { _, _, _, _ in source }
        let data = try JSONEncoder().encode(result.report)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["policyVersion"] = 1
        object.removeValue(forKey: "nativeCheckedCandidateIDs")

        var candidateObjects = try XCTUnwrap(object["candidates"] as? [[String: Any]])
        for index in candidateObjects.indices {
            candidateObjects[index].removeValue(forKey: "sampleQualityAccepted")
            candidateObjects[index].removeValue(forKey: "nativeSafetyAccepted")
        }
        object["candidates"] = candidateObjects

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(LUTAdaptationReport.self, from: legacyData)
        XCTAssertEqual(legacy.policyVersion, 1)
        XCTAssertNil(legacy.nativeCheckedCandidateIDs)
        XCTAssertTrue(legacy.candidates.allSatisfy {
            $0.sampleQualityAccepted == nil && $0.nativeSafetyAccepted == nil
        })
    }

    func testAlphaNegativeAndExistingOutOfRangeValuesAreRetained() throws {
        let source = bitmap(width: 4, height: 4) { x, y in
            if x == 0 && y == 0 { return (1.18, -0.04, 0.25, 1) }
            if x == 1 && y == 0 { return (0.7, 0.3, 0.1, 0) }
            if x == 2 && y == 0 { return (0.48, 0.22, 0.10, 0.5) }
            return (0.22, 0.22, 0.22, 1)
        }
        let sourceAtBottomOrigin = try pixelAtCoreImageCoordinate(source, x: 0, y: 0)
        let sourceAtBitmapRowZero = try pixelAtCoreImageCoordinate(source, x: 0, y: 3)
        XCTAssertEqual(sourceAtBottomOrigin.r, 0.22, accuracy: 0.003)
        XCTAssertEqual(sourceAtBitmapRowZero.r, 1.18, accuracy: 0.003)

        let result = try adapt(source, cube: cube()) { _, _, _, _ in source }
        let extended = try pixel(result.image, x: 0, y: 0)
        XCTAssertEqual(extended.r, 1.18, accuracy: 0.003)
        XCTAssertEqual(extended.g, -0.04, accuracy: 0.003)
        let invisible = try pixel(result.image, x: 1, y: 0)
        XCTAssertEqual(invisible.a, 0, accuracy: 0.001)
        let translucent = try pixel(result.image, x: 2, y: 0)
        XCTAssertEqual(translucent.a, 0.5, accuracy: 0.002)
        XCTAssertEqual(translucent.r, 0.48, accuracy: 0.003)
        XCTAssertEqual(result.report.nativeIntroducedHighlights, 0, accuracy: 0.000001)
        XCTAssertEqual(result.report.nativeIntroducedShadows, 0, accuracy: 0.000001)
    }

    func testSinglePixelHighlightIsGuardedAtNativeResolution() throws {
        let width = 256, height = 256
        let source = flat(0.35, 0.35, 0.35, width: width, height: height)
        let brightPixel = bitmap(width: width, height: height) { x, y in
            x == width / 2 && y == height / 2 ? (1.4, 1.4, 1.4, 1) : (0.35, 0.35, 0.35, 1)
        }
        let result = try adapt(source, cube: cube()) { _, _, _, _ in brightPixel }
        let values = try renderedValues(result.image)
        let maximum = stride(from: 0, to: values.count, by: 4)
            .map { max(values[$0], max(values[$0 + 1], values[$0 + 2])) }
            .max() ?? 0

        XCTAssertGreaterThan(maximum, 0.35)
        XCTAssertLessThan(maximum, 1.0, "the isolated requested highlight must stay below the clipping boundary")
        XCTAssertEqual(result.report.nativeIntroducedHighlights, 0, accuracy: 0.000001)
    }

    func testDisplayP3ClippingMeasurementUsesTargetPrimaries() throws {
        let source = flat(0, 0.90, 0, width: 8, height: 8)
        let candidate = flat(0, 1.20, 0, width: 8, height: 8)
        let result = try adapt(source, cube: cube(), target: .displayP3) {
            _, _, _, _ in candidate
        }

        let output = try pixel(result.image)
        let p3Green = 0.0331941989 * Double(output.r) + 0.9668058011 * Double(output.g)
        XCTAssertLessThan(p3Green, 1.0)
        XCTAssertEqual(result.report.nativeIntroducedHighlights, 0, accuracy: 0.000001)
    }

    func testNoFaceStatusAndCancellationAreExplicit() throws {
        let source = flat(0.25, 0.25, 0.25)
        let noFace = ContentSelectionResult(
            report: ContentSelectionReport(faceStatus: "noDetection", faceCount: 0),
            masks: [:])
        let result = try adapt(source, cube: cube(), selections: noFace,
                               semantics: LUTSemanticContext(status: "unavailable")) { _, _, _, _ in source }
        XCTAssertEqual(result.report.faceStatus, "noDetection")
        XCTAssertEqual(result.report.faceCount, 0)
        XCTAssertEqual(result.report.skinSampleCount, 0)
        XCTAssertEqual(result.report.contentStatus, "unavailable")

        let cancelled = CancellationToken()
        cancelled.cancel()
        XCTAssertThrowsError(try adapt(source, cube: cube(), cancellation: cancelled) {
            _, _, _, _ in source
        }) { error in
            guard let atelierError = error as? AtelierError,
                  case .cancelled = atelierError else {
                return XCTFail("expected cooperative cancellation, got \(error)")
            }
        }
    }

    private func adapt(_ reference: CIImage,
                       cube: LUTCube,
                       settings inputSettings: AdjustmentSettings? = nil,
                       selections: ContentSelectionResult? = nil,
                       semantics: LUTSemanticContext = LUTSemanticContext(),
                       target: OutputColorSpace? = nil,
                       cancellation: CancellationToken? = nil,
                       render: LUTAdaptationEngine.Renderer? = nil) throws -> AdaptedLUTResult {
        var settings = inputSettings ?? AdjustmentSettings()
        if settings.adaptiveLUT == nil { settings.adaptiveLUT = AdaptiveLUTSettings() }
        let renderer: LUTAdaptationEngine.Renderer
        if let render {
            renderer = render
        } else {
            renderer = { _, _, _, _ in reference }
        }
        return try LUTAdaptationEngine.apply(reference: reference, cube: cube, settings: settings,
            selections: selections, semantics: semantics, target: target, context: context,
            cancellation: cancellation, render: renderer)
    }

    private func cube(monochrome: Bool = false, redBias: Float = 0, scale: Float = 1) throws -> LUTCube {
        var rows: [String] = []
        for blue in 0...1 {
            for green in 0...1 {
                for red in 0...1 {
                    let r = Float(red), g = Float(green), b = Float(blue)
                    if monochrome {
                        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                        rows.append("\(y) \(y) \(y)")
                    } else {
                        rows.append("\(min(1, r * scale + redBias)) \(g * scale) \(b * scale)")
                    }
                }
            }
        }
        return try LUTCube.parse("LUT_3D_SIZE 2\n" + rows.joined(separator: "\n"))
    }

    private func flat(_ r: Float, _ g: Float, _ b: Float,
                      width: Int = 16, height: Int = 16) -> CIImage {
        bitmap(width: width, height: height) { _, _ in (r, g, b, 1) }
    }

    private func bitmap(width: Int, height: Int,
                        pixel: (Int, Int) -> Pixel) -> CIImage {
        var components: [Float] = []
        components.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
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

    private func pixel(_ image: CIImage, x: Int = 0, y: Int = 0) throws -> Pixel {
        let bounds = CGRect(x: image.extent.minX + CGFloat(x),
                            y: image.extent.maxY - CGFloat(y) - 1,
                            width: 1, height: 1)
        return try pixel(in: image, bounds: bounds)
    }

    private func pixelAtCoreImageCoordinate(_ image: CIImage, x: Int, y: Int) throws -> Pixel {
        let bounds = CGRect(x: image.extent.minX + CGFloat(x), y: image.extent.minY + CGFloat(y),
                            width: 1, height: 1)
        return try pixel(in: image, bounds: bounds)
    }

    private func pixel(in image: CIImage, bounds: CGRect) throws -> Pixel {
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 16, bounds: bounds,
                           format: .RGBAf, colorSpace: linearColorSpace)
        }
        return (values[0], values[1], values[2], values[3])
    }

    private func renderCube(_ cube: LUTCube, on reference: CIImage, intensity: Double) throws -> CIImage {
        let cubeData = cube.rgba.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        let graded = reference.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": cube.size,
            "inputCubeData": cubeData
        ])
        guard let blendKernel,
              let output = blendKernel.apply(extent: reference.extent, arguments: [
                reference, graded, NSNumber(value: intensity)
              ]) else {
            throw AtelierError.invalidConfiguration("test LUT blend kernel could not render")
        }
        return output
    }

    private lazy var blendKernel = CIColorKernel(source: """
    kernel vec4 blendLUT(__sample reference, __sample graded, float amount) {
        if (reference.a <= 0.000001) { return vec4(0.0); }
        vec3 base = reference.rgb / reference.a;
        vec3 look = graded.a > 0.000001 ? graded.rgb / graded.a : base;
        return vec4(mix(base, look, clamp(amount, 0.0, 1.0)) * reference.a, reference.a);
    }
    """)

    private func renderedValues(_ image: CIImage) throws -> [Float] {
        let bounds = image.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { throw AtelierError.invalidConfiguration("test image is empty") }
        var values = [Float](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!,
                           rowBytes: width * 4 * MemoryLayout<Float>.stride,
                           bounds: bounds, format: .RGBAf, colorSpace: linearColorSpace)
        }
        return values
    }

    private func materialized(_ image: CIImage) throws -> CIImage {
        let bounds = image.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { throw AtelierError.invalidConfiguration("test image is empty") }
        let values = try renderedValues(image)
        let data = values.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        let bitmap = CIImage(bitmapData: data,
                             bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                             size: CGSize(width: width, height: height),
                             format: .RGBAf,
                             colorSpace: linearColorSpace)
        return bitmap.transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
    }

    private func sampledPixels(_ image: CIImage, width: Int, height: Int) throws -> [Float] {
        let extent = image.extent
        let resized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width,
                                               y: CGFloat(height) / extent.height))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        var values = [Float](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes { buffer in
            context.render(resized, toBitmap: buffer.baseAddress!,
                           rowBytes: width * 4 * MemoryLayout<Float>.stride,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: linearColorSpace)
        }
        return values
    }
}

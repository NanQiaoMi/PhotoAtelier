import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class AdaptiveDetailTests: XCTestCase {
    private typealias RGBA = (r: Float, g: Float, b: Float, a: Float)

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: true,
        .cacheIntermediates: false
    ])

    func testAnalyzerMeasuresFlatNoiseAndCoherentStructureAsDifferentEvidence() throws {
        let width = 96, height = 96
        let flat = image(width: width, height: height) { (x: Int, y: Int) -> RGBA in
            return (0.3, 0.3, 0.3, 1)
        }
        let noisy = image(width: width, height: height) { (x: Int, y: Int) -> RGBA in
            let code = (x * 73 + y * 151 + x * y * 19) % 101
            let noise: Double = (Double(code) / 100.0 - 0.5) * 0.016
            let value: Float = Float(0.3 + noise)
            return (value, value, value, 1)
        }
        let textured = image(width: width, height: height) { (x: Int, y: Int) -> RGBA in
            let xPhase = Double(x) * 2.0 * Double.pi / 16.0
            let yPhase = Double(y) * 2.0 * Double.pi / 18.0
            let xDetail: Double = 0.018 * sin(xPhase)
            let yDetail: Double = 0.012 * cos(yPhase)
            let value: Float = Float(0.3 + xDetail + yDetail)
            return (value, value, value, 1)
        }
        let adaptation = LocalDetailAdaptation(strength: 0)

        let flatPlan = try analyze(flat, adaptation: adaptation)
        let noisyPlan = try analyze(noisy, adaptation: adaptation)
        let texturePlan = try analyze(textured, adaptation: adaptation)

        XCTAssertEqual(flatPlan.measurements.sampleCount, noisyPlan.measurements.sampleCount)
        XCTAssertGreaterThan(noisyPlan.measurements.luminanceNoise,
                             flatPlan.measurements.luminanceNoise + 0.0001)
        XCTAssertGreaterThan(texturePlan.measurements.textureFraction,
                             noisyPlan.measurements.textureFraction)
        for plan in [flatPlan, noisyPlan, texturePlan] {
            XCTAssertTrue(plan.warnings.contains { $0.contains("混入噪点估计") },
                          "measured residuals must not be described as a reliable sensor-noise classification")
        }
    }

    func testBlackWhiteAndTransparentRegionsStayAtTheirEvidenceLimits() throws {
        let extent = CGRect(x: 37, y: -19, width: 96, height: 96)
        let black = image(width: 96, height: 96, origin: extent.origin) { (x: Int, y: Int) -> RGBA in
            return (0, 0, 0, 1)
        }
        let white = image(width: 96, height: 96, origin: extent.origin) { (x: Int, y: Int) -> RGBA in
            return (1, 1, 1, 1)
        }
        let transparent = image(width: 96, height: 96, origin: extent.origin) { (x: Int, y: Int) -> RGBA in
            return (0.3, 0.3, 0.3, 0)
        }

        let blackPlan = try analyze(black)
        let whitePlan = try analyze(white)
        let transparentPlan = try analyze(transparent)

        XCTAssertEqual(black.extent, extent)
        XCTAssertGreaterThan(blackPlan.measurements.nearBlackFraction, 0.99)
        XCTAssertTrue(blackPlan.settings.isNeutral, "black pixels do not prove recoverable texture")
        XCTAssertGreaterThan(whitePlan.measurements.nearWhiteFraction, 0.99)
        XCTAssertTrue(whitePlan.settings.isNeutral, "clipped white pixels do not prove recoverable texture")
        XCTAssertEqual(transparentPlan.measurements.sampleCount, 0)
        XCTAssertEqual(transparentPlan.status, "insufficientSamples")
        XCTAssertTrue(transparentPlan.settings.isNeutral)
        XCTAssertTrue(transparentPlan.warnings.contains { $0.contains("样本不足") })
    }

    func testAnalyzerMeasuresSemitransparentPixelsUnpremultipliedAndSkipsTransparentPixels() throws {
        let width = 96, height = 96
        func flatImage(alpha: Float) -> CIImage {
            image(width: width, height: height) { (x: Int, y: Int) -> RGBA in
                return (0.3, 0.3, 0.3, alpha)
            }
        }
        let coverage = coverageImage(width: width, height: height) { (x: Int, y: Int) in true }
        let engine = PhotoEngine()
        let opaque = flatImage(alpha: 1)
        let partial = flatImage(alpha: 0.4)
        let transparent = flatImage(alpha: 0)

        func measure(_ source: CIImage) throws -> LocalDetailPlan {
            try AdaptiveLocalDetailAnalyzer.analyze(
                reference: source, coverage: coverage, maskID: UUID(), target: nil,
                adaptation: LocalDetailAdaptation(), context: engine.context)
        }

        let opaquePlan = try measure(opaque)
        let partialPlan = try measure(partial)
        let transparentPlan = try measure(transparent)

        XCTAssertGreaterThan(opaquePlan.measurements.sampleCount, 0)
        XCTAssertEqual(partialPlan.measurements.sampleCount, opaquePlan.measurements.sampleCount,
                       "valid partial alpha must not be mistaken for reduced mask coverage")
        XCTAssertEqual(partialPlan.measurements.medianLuminance,
                       opaquePlan.measurements.medianLuminance, accuracy: 0.002,
                       "the analyzer must measure the unpremultiplied linear color")
        XCTAssertEqual(opaquePlan.measurements.medianLuminance, 0.3, accuracy: 0.002)
        XCTAssertEqual(transparentPlan.measurements.sampleCount, 0,
                       "fully transparent source pixels must not contribute color samples")
    }

    func testTranslatedExtentKeepsTheSameOriginalPixelMeasurements() throws {
        let width = 96, height = 96
        func patternedImage(origin: CGPoint) -> CIImage {
            image(width: width, height: height, origin: origin) { (x: Int, y: Int) -> RGBA in
                let xPhase = Double(x) * 2.0 * Double.pi / 19.0
                let yPhase = Double(y) * 2.0 * Double.pi / 23.0
                let xDetail: Double = 0.02 * sin(xPhase)
                let yDetail: Double = 0.01 * cos(yPhase)
                let value: Float = Float(0.31 + xDetail + yDetail)
                return (value, value, value, 1)
            }
        }

        let originPlan = try analyze(patternedImage(origin: .zero))
        let translatedPlan = try analyze(patternedImage(origin: CGPoint(x: -43, y: 29)))

        XCTAssertEqual(translatedPlan.measurements, originPlan.measurements)
        XCTAssertEqual(translatedPlan.measurements.sampleCount, 96 * 96)
    }

    func testHighFrequencyPixelsOutsideCoverageCannotChangeSelectedMeasurements() throws {
        let width = 192, height = 96
        let coverage = coverageImage(width: width, height: height) { (x: Int, y: Int) in x < width / 2 }
        func source(outsidePatterned: Bool) -> CIImage {
            image(width: width, height: height) { (x: Int, y: Int) -> RGBA in
                if x < width / 2 {
                    let code = (x * 41 + y * 67 + x * y * 7) % 97
                    let variation: Double = (Double(code) / 96.0 - 0.5) * 0.012
                    let value: Float = Float(0.3 + variation)
                    return (value, value, value, 1)
                }
                let value: Float = outsidePatterned && (x + y).isMultiple(of: 2) ? 0.02 : 0.98
                return (value, value, value, 1)
            }
        }

        let selectedOnly = try analyze(source(outsidePatterned: false), coverage: coverage)
        let patternedOutside = try analyze(source(outsidePatterned: true), coverage: coverage)

        XCTAssertGreaterThan(selectedOnly.measurements.sampleCount, 0)
        XCTAssertEqual(patternedOutside.measurements, selectedOnly.measurements,
                       "unselected high-frequency content must not leak into the measurement")
    }

    func testAmbiguousFinePatternProducesAWarningAndNoAutomaticNoiseOrTextureChange() throws {
        let checker = image(width: 96, height: 96) { (x: Int, y: Int) -> RGBA in
            let value: Float = (x + y).isMultiple(of: 2) ? 0.27 : 0.23
            return (value, value, value, 1)
        }

        let plan = try analyze(checker, adaptation: LocalDetailAdaptation(strength: 1))
        let portraitPlan = try analyze(checker,
            adaptation: LocalDetailAdaptation(intent: .portrait, strength: 1),
            isSpatiallyLimited: true)

        XCTAssertTrue(plan.measurements.ambiguousFinePattern)
        XCTAssertEqual(plan.settings.noiseReduction, 0, accuracy: 0.000001)
        XCTAssertEqual(plan.settings.detailRecovery, 0, accuracy: 0.000001)
        XCTAssertTrue(plan.warnings.contains { $0.contains("歧义") })
        XCTAssertTrue(portraitPlan.settings.isNeutral,
                      "ambiguous fine patterns must also disable portrait smoothing in a limited mask")
    }

    func testExplicitPortraitIntentDoesNotFlattenAFullFrameButCanUseFaceSkinEvidence() throws {
        let textured = image(width: 96, height: 96) { (x: Int, y: Int) -> RGBA in
            let xPhase = Double(x) * 2.0 * Double.pi / 16.0
            let yPhase = Double(y) * 2.0 * Double.pi / 18.0
            let xDetail: Double = 0.018 * sin(xPhase)
            let yDetail: Double = 0.012 * cos(yPhase)
            let value: Float = Float(0.3 + xDetail + yDetail)
            return (value, value, value, 1)
        }
        let portrait = LocalDetailAdaptation(intent: .portrait, strength: 1)
        let fullFrameMask = LocalMask(kind: .luminance, exposureEV: 0, detailAdaptation: portrait)
        var fullFrameSettings = AdjustmentSettings()
        fullFrameSettings.colorHarmony = nil
        fullFrameSettings.masks = [fullFrameMask]
        let fullFrameResult = try PhotoEngine().process(textured, settings: fullFrameSettings, lut: nil)
        let fullFramePlan = try XCTUnwrap(fullFrameResult.report.localDetails?.first)
        let faceSkinPlan = try analyze(textured, adaptation: portrait, target: .faceSkin,
                                       isSpatiallyLimited: false)

        XCTAssertTrue(fullFramePlan.settings.isNeutral,
                      "a full-frame mask is not evidence that the whole photograph is skin")
        XCTAssertGreaterThan(faceSkinPlan.settings.smoothing, 0,
                             "an explicit face-skin selection can authorize cautious portrait smoothing")
        let faceCoverage = coverageImage(width: 96, height: 96) { x, _ in x < 48 }
        let prepared = ContentSelectionResult(report: .init(), masks: [.faceSkin: faceCoverage])
        var semanticMask = LocalMask(kind: .luminance, exposureEV: 0,
                                     contentSelection: .faceSkin, detailAdaptation: portrait)
        var semanticSettings = fullFrameSettings
        let engine = PhotoEngine()
        semanticSettings.masks = [semanticMask]
        let base = try engine.process(textured, settings: semanticSettings, lut: nil,
                                       preparedContentSelections: prepared)
        XCTAssertGreaterThan(try XCTUnwrap(base.report.localDetails?.first).settings.smoothing, 0)
        semanticMask.inverted = true
        semanticSettings.masks = [semanticMask]
        let inverted = try engine.process(textured, settings: semanticSettings, lut: nil,
                                           preparedContentSelections: prepared)
        XCTAssertEqual(try XCTUnwrap(inverted.report.localDetails?.first).settings.smoothing, 0,
                       "an inverted face candidate is no longer evidence of skin")
        semanticMask.inverted = false
        semanticMask.components = [MaskComponent(operation: .add, kind: .radial)]
        semanticSettings.masks = [semanticMask]
        let expanded = try engine.process(textured, settings: semanticSettings, lut: nil,
                                           preparedContentSelections: prepared)
        XCTAssertEqual(try XCTUnwrap(expanded.report.localDetails?.first).settings.smoothing, 0,
                       "an expanded semantic mask cannot silently label added content as skin")
    }

    func testSubHalfOpacityCoverageStillProvidesUsableSamples() throws {
        let source = image(width: 96, height: 96) { (x: Int, y: Int) -> RGBA in
            let xPhase = Double(x) * 2.0 * Double.pi / 16.0
            let yPhase = Double(y) * 2.0 * Double.pi / 18.0
            let xDetail: Double = 0.018 * sin(xPhase)
            let yDetail: Double = 0.012 * cos(yPhase)
            let value: Float = Float(0.3 + xDetail + yDetail)
            return (value, value, value, 1)
        }
        var mask = LocalMask(kind: .luminance, exposureEV: 0,
                             detailAdaptation: LocalDetailAdaptation(strength: 0.8))
        mask.opacity = 0.2
        var settings = AdjustmentSettings()
        settings.colorHarmony = nil
        settings.masks = [mask]

        let result = try PhotoEngine().process(source, settings: settings, lut: nil)
        let plan = try XCTUnwrap(result.report.localDetails?.first)

        XCTAssertGreaterThan(plan.measurements.sampleCount, 0)
        XCTAssertEqual(plan.status, "measured",
                       "low opacity scales coverage but should not turn a populated selection into an empty one")
        XCTAssertEqual(plan.resolvedIntent, .texture)
    }

    func testDarknessAloneDoesNotSelectLowLightNoiseReduction() throws {
        let width = 96, height = 96
        let darkFlat = solidImage(0.04, width: width, height: height, origin: .zero)
        let darkNoise = image(width: width, height: height) { (x: Int, y: Int) -> RGBA in
            var hash = UInt32(x) &* 0x9E3779B9 &+ UInt32(y) &* 0x85EBCA6B &+ 0xC2B2AE35
            hash ^= hash >> 16
            hash = hash &* 0x7FEB352D
            hash ^= hash >> 15
            hash = hash &* 0x846CA68B
            hash ^= hash >> 16
            let uniformNoise = Double(hash) / Double(UInt32.max) - 0.5
            let noise: Double = uniformNoise * 0.012
            let value: Float = Float(0.04 + noise)
            return (value, value, value, 1)
        }
        let flatPlan = try analyze(darkFlat, adaptation: LocalDetailAdaptation(strength: 1))
        let noisyPlan = try analyze(darkNoise, adaptation: LocalDetailAdaptation(strength: 1))

        XCTAssertGreaterThan(flatPlan.measurements.medianLuminance, 0)
        XCTAssertLessThan(flatPlan.measurements.medianLuminance, 0.1)
        XCTAssertEqual(flatPlan.resolvedIntent, .texture,
                       "low brightness without noise evidence is not a low-light noise diagnosis")
        XCTAssertEqual(flatPlan.settings.noiseReduction, 0, accuracy: 0.000001)
        XCTAssertEqual(noisyPlan.resolvedIntent, .lowLight)
        XCTAssertGreaterThan(noisyPlan.noiseEstimate, 0.005)
        XCTAssertGreaterThan(noisyPlan.settings.noiseReduction, 0)
        XCTAssertEqual(noisyPlan.settings.detailRecovery, 0, accuracy: 0.000001)
    }

    func testAnalyzerRejectsInvalidStrengthAndMismatchedCoverageExtent() throws {
        XCTAssertThrowsError(try AdaptiveLocalDetailAnalyzer.validate(
            LocalDetailAdaptation(strength: .nan)))
        XCTAssertThrowsError(try AdaptiveLocalDetailAnalyzer.validate(
            LocalDetailAdaptation(strength: 1.01)))

        let reference = solidImage(0.3, width: 64, height: 64, origin: .zero)
        let wrongCoverage = coverageImage(width: 64, height: 64, origin: CGPoint(x: 1, y: 0)) { _, _ in true }
        XCTAssertThrowsError(try AdaptiveLocalDetailAnalyzer.analyze(
            reference: reference, coverage: wrongCoverage, maskID: UUID(), target: nil,
            adaptation: LocalDetailAdaptation(), context: context))
    }

    func testPhotoEngineCreatesPerPhotoPlansFromGlobalReferenceAndEffectiveCoverage() throws {
        let extent = CGRect(x: 11, y: -7, width: 96, height: 96)
        let maskID = UUID()
        let adaptiveMask = LocalMask(id: maskID, kind: .luminance, exposureEV: 0.5,
                                     detailAdaptation: LocalDetailAdaptation(strength: 1))
        var settings = AdjustmentSettings()
        settings.exposureEV = 1
        settings.colorHarmony = nil
        settings.masks = [adaptiveMask]
        let engine = PhotoEngine()

        let flat = solidImage(0.1, width: 96, height: 96, origin: extent.origin)
        let patterned = image(width: 96, height: 96, origin: extent.origin) { (x: Int, y: Int) -> RGBA in
            let value: Float = (x + y).isMultiple(of: 2) ? 0.11 : 0.09
            return (value, value, value, 1)
        }
        let first = try engine.process(flat, settings: settings, lut: nil)
        let second = try engine.process(patterned, settings: settings, lut: nil)
        let firstPlan = try XCTUnwrap(first.report.localDetails?.first)
        let secondPlan = try XCTUnwrap(second.report.localDetails?.first)

        XCTAssertEqual(first.report.localDetails?.count, 1)
        XCTAssertEqual(second.report.localDetails?.count, 1)
        XCTAssertEqual(firstPlan.maskID, maskID)
        XCTAssertEqual(secondPlan.maskID, maskID)
        XCTAssertEqual(firstPlan.measurements.medianLuminance, 0.2, accuracy: 0.025,
                       "the report measures after global exposure, before local-mask exposure")
        XCTAssertNotEqual(firstPlan.measurements, secondPlan.measurements,
                          "each image processed with the same recipe must receive fresh measurements")
        XCTAssertTrue(secondPlan.measurements.ambiguousFinePattern)
        XCTAssertTrue(firstPlan.noiseEstimate.isFinite && secondPlan.noiseEstimate.isFinite)
        XCTAssertGreaterThanOrEqual(firstPlan.noiseEstimate, 0)
        XCTAssertLessThanOrEqual(firstPlan.noiseEstimate, 0.25)
        XCTAssertEqual(try JSONDecoder().decode(ProcessingReport.self,
                                                from: JSONEncoder().encode(first.report)).localDetails,
                       first.report.localDetails)
        var oldReportObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first.report))
                                            as? [String: Any])
        oldReportObject.removeValue(forKey: "localDetails")
        let oldReport = try JSONDecoder().decode(
            ProcessingReport.self, from: JSONSerialization.data(withJSONObject: oldReportObject))
        XCTAssertNil(oldReport.localDetails, "older reports without local measurements remain readable")

        var rangedMask = LocalMask(kind: .luminance, exposureEV: 0,
                                   detailAdaptation: LocalDetailAdaptation(strength: 1))
        rangedMask.luminanceMax = 0.5
        rangedMask.rangeSoftness = 0
        var rangedSettings = AdjustmentSettings()
        rangedSettings.colorHarmony = nil
        rangedSettings.masks = [rangedMask]
        let splitTone = image(width: 96, height: 96) { (x: Int, y: Int) -> RGBA in
            let value: Float = x < 48 ? 0.2 : 0.8
            return (value, value, value, 1)
        }
        let ranged = try engine.process(splitTone, settings: rangedSettings, lut: nil)
        let rangedPlan = try XCTUnwrap(ranged.report.localDetails?.first)
        XCTAssertLessThan(rangedPlan.measurements.medianLuminance, 0.3,
                          "the analyzer must use the effective luminance-range coverage")
    }

    func testDisablingAdaptationRestoresStoredManualDetailSettings() throws {
        let width = 96, height = 96
        let source = image(width: width, height: height) { (x: Int, y: Int) -> RGBA in
            let xPhase = 2.0 * Double.pi * Double(x) / 12.0
            let yPhase = 2.0 * Double.pi * Double(y) / 12.0
            let xVariation: Double = 0.065 * sin(xPhase)
            let yVariation: Double = 0.05 * cos(yPhase)
            let mid: Double = 0.36 + xVariation + yVariation
            let fine: Double = (x + y).isMultiple(of: 2) ? 0.02 : -0.02
            let value = Float(mid + fine)
            return (value, value, value, 1)
        }
        let manual = LocalDetailSettings(smoothing: 0.75, textureRetention: 0.95, toneUniformity: 0)
        let maskID = UUID()
        let adaptedMask = LocalMask(id: maskID, kind: .luminance, exposureEV: 0,
                                   detail: manual,
                                   detailAdaptation: LocalDetailAdaptation(strength: 0))
        let manualMask = LocalMask(id: maskID, kind: .luminance, exposureEV: 0, detail: manual)
        var adaptedSettings = AdjustmentSettings()
        adaptedSettings.colorHarmony = nil
        adaptedSettings.masks = [adaptedMask]
        var manualSettings = adaptedSettings
        manualSettings.masks = [manualMask]
        let engine = PhotoEngine()

        let adapted = try engine.process(source, settings: adaptedSettings, lut: nil)
        let restoredManual = try engine.process(source, settings: manualSettings, lut: nil)
        let adaptedPlan = try XCTUnwrap(adapted.report.localDetails?.first)
        let adaptedPixels = render(adapted.image)
        let manualPixels = render(restoredManual.image)

        XCTAssertTrue(adaptedPlan.settings.isNeutral)
        XCTAssertNil(restoredManual.report.localDetails)
        XCTAssertGreaterThan(maximumDifference(adaptedPixels, manualPixels), 0.001,
                             "turning adaptation off must resume the stored manual detail controls")
    }

    func testDuplicateFullFrameAdaptiveMasksDoNotAmplifyTheDetailDelta() throws {
        let source = image(width: 96, height: 96) { (x: Int, y: Int) -> RGBA in
            let xPhase = Double(x) * 2.0 * Double.pi / 16.0
            let yPhase = Double(y) * 2.0 * Double.pi / 18.0
            let xDetail: Double = 0.018 * sin(xPhase)
            let yDetail: Double = 0.012 * cos(yPhase)
            let value: Float = Float(0.3 + xDetail + yDetail)
            return (value, value, value, 1)
        }
        let firstMask = LocalMask(kind: .luminance, exposureEV: 0,
                                  detailAdaptation: LocalDetailAdaptation(intent: .texture, strength: 1))
        let secondMask = LocalMask(kind: .luminance, exposureEV: 0,
                                   detailAdaptation: LocalDetailAdaptation(intent: .texture, strength: 1))
        var singleSettings = AdjustmentSettings()
        singleSettings.colorHarmony = nil
        singleSettings.masks = [firstMask]
        var overlappingSettings = singleSettings
        overlappingSettings.masks = [firstMask, secondMask]
        let engine = PhotoEngine()

        let single = try engine.process(source, settings: singleSettings, lut: nil)
        let overlapping = try engine.process(source, settings: overlappingSettings, lut: nil)
        let singlePlan = try XCTUnwrap(single.report.localDetails?.first)

        XCTAssertGreaterThan(singlePlan.settings.detailRecovery, 0,
                             "the comparison should exercise a non-neutral adaptive detail delta")
        XCTAssertEqual(overlapping.report.localDetails?.count, 2)
        XCTAssertLessThan(maximumDifference(render(single.image), render(overlapping.image)), 0.001,
                          "identical overlapping full-frame masks must not double the adaptive change")
    }

    func testAdaptiveDetailUsesGlobalReferenceBeforeLocalExposureAndLUT() throws {
        let width = 96, height = 96
        let source = image(width: width, height: height) { (x: Int, y: Int) -> RGBA in
            let xPhase = Double(x) * 2.0 * Double.pi / 12.0
            let yPhase = Double(y) * 2.0 * Double.pi / 15.0
            let xDetail: Double = 0.04 * sin(xPhase)
            let yDetail: Double = 0.03 * cos(yPhase)
            let value: Float = Float(0.16 + xDetail + yDetail)
            return (value, value, value, 1)
        }
        var mask = LocalMask(kind: .luminance, exposureEV: 2,
                             detailAdaptation: LocalDetailAdaptation(intent: .texture, strength: 1))
        mask.highlightProtection = 0
        mask.colorProtection = 0
        var settings = AdjustmentSettings()
        settings.colorHarmony = nil
        settings.lutIntensity = 1
        settings.lutColorSpace = .linearSRGB
        settings.preserveLuminance = 0
        settings.protectSkin = 0
        settings.protectNeutrals = 0
        settings.gamutCompression = 0
        settings.masks = [mask]
        let cube = try LUTCube.parse(testCubeText(size: 3) {
            (r: Double, g: Double, b: Double) -> (Double, Double, Double) in
            let red = r * r
            let green = g * g
            let blue = b * b
            return (red, green, blue)
        })
        let engine = PhotoEngine()

        let actual = try engine.process(source, settings: settings, lut: cube)
        let plan = try XCTUnwrap(actual.report.localDetails?.first)
        let detailFirst = try LocalDetailEngine.apply(source, settings: plan.settings,
                                                      noiseEstimate: plan.noiseEstimate)
        let exposedAfterDetail = try exposureAdjusted(detailFirst, ev: 2)
        var lookOnlySettings = settings
        lookOnlySettings.masks = []
        let expected = try engine.process(exposedAfterDetail, settings: lookOnlySettings, lut: cube)

        XCTAssertEqual(plan.processingStage, "beforeLocalColorAndLook")
        XCTAssertGreaterThan(plan.settings.detailRecovery, 0,
                             "the expected sequence must include active measured detail recovery")
        XCTAssertLessThan(maximumDifference(render(actual.image), render(expected.image)), 0.004,
                          "detail thresholds must be applied on the global reference before +2 EV and the LUT")
    }

    func testAdaptivePipelineLeavesZeroCoveragePixelsUnchanged() throws {
        let width = 96, height = 96
        let source = image(width: width, height: height) { (x: Int, y: Int) -> RGBA in
            if x < width / 2 {
                let xPhase = Double(x) * 2.0 * Double.pi / 16.0
                let yPhase = Double(y) * 2.0 * Double.pi / 18.0
                let xDetail: Double = 0.018 * sin(xPhase)
                let yDetail: Double = 0.012 * cos(yPhase)
                let value: Float = Float(0.32 + xDetail + yDetail)
                return (value, value, value, 1)
            }
            let xPhase = Double(x) * 2.0 * Double.pi / 17.0
            let yPhase = Double(y) * 2.0 * Double.pi / 19.0
            let xDetail: Double = 0.01 * sin(xPhase)
            let yDetail: Double = 0.008 * cos(yPhase)
            let value: Float = Float(0.72 + xDetail + yDetail)
            return (value, value, value, 1)
        }
        var mask = LocalMask(kind: .luminance, exposureEV: 0,
                             detailAdaptation: LocalDetailAdaptation(intent: .texture, strength: 1))
        mask.luminanceMax = 0.7
        mask.rangeSoftness = 0
        var settings = AdjustmentSettings()
        settings.colorHarmony = nil
        settings.masks = [mask]

        let engine = PhotoEngine()
        let coverage = try engine.localMaskImage(mask, reference: source)
        let coveragePixels = render(coverage)
        let result = try engine.process(source, settings: settings, lut: nil)
        let plan = try XCTUnwrap(result.report.localDetails?.first)
        let before = render(source)
        let after = render(result.image)

        XCTAssertGreaterThan(plan.settings.detailRecovery, 0)
        let leftCoverage = coveragePixels[(48 * width + 24) * 4]
        let rightCoverage = coveragePixels[(48 * width + 72) * 4]
        XCTAssertGreaterThan(leftCoverage, 0.95,
                             "the textured left region should be inside the display-luminance range")
        XCTAssertLessThan(rightCoverage, 0.05,
                          "the bright right region should be outside the effective range")
        for y in 0..<height {
            for x in 64..<width {
                let offset = (y * width + x) * 4
                for channel in 0..<4 {
                    XCTAssertEqual(after[offset + channel], before[offset + channel], accuracy: 0.001,
                                   "pixels outside the effective coverage must remain unchanged")
                }
            }
        }
    }

    func testNewDetailControlsReduceNoiseAndRetainSupportedFineStructure() throws {
        let width = 96, height = 96
        let noisy = image(width: width, height: height) { (x: Int, y: Int) -> RGBA in
            let code = (x * 73 + y * 151 + x * y * 19) % 101
            let value = Float(0.3 + (Double(code) / 100 - 0.5) * 0.04)
            return (value, value, value, 1)
        }
        let noiseReduced = try LocalDetailEngine.apply(
            noisy, settings: LocalDetailSettings(noiseReduction: 1), noiseEstimate: 0.03)
        let inputNoise = rmsLuminanceDeviation(render(noisy), width: width, height: height, center: 0.3)
        let outputNoise = rmsLuminanceDeviation(render(noiseReduced), width: width, height: height, center: 0.3)

        XCTAssertLessThan(outputNoise, inputNoise * 0.85,
                          "noise reduction should lower the residual on a flat field with synthetic variation")

        let checker = image(width: width, height: height) { (x: Int, y: Int) -> RGBA in
            let value: Float = (x + y).isMultiple(of: 2) ? 0.33 : 0.27
            return (value, value, value, 1)
        }
        let recovered = try LocalDetailEngine.apply(
            checker, settings: LocalDetailSettings(detailRecovery: 1), noiseEstimate: 0.005)
        let inputDetail = alternatingPairEnergy(render(checker), width: width, height: height)
        let outputDetail = alternatingPairEnergy(render(recovered), width: width, height: height)

        XCTAssertGreaterThan(outputDetail, inputDetail * 1.02,
                             "detail recovery should retain a measurable fine signal without fabricating a pattern")
    }

    func testCombinedLegacyAndNewDetailStagesStayWithinPointTwelveEV() throws {
        let width = 96, height = 96
        let source = image(width: width, height: height) { (x: Int, y: Int) -> RGBA in
            let code = (x * 73 + y * 151 + x * y * 19) % 101
            let noise: Double = (Double(code) / 100.0 - 0.5) * 0.02
            let fine: Double = (x + y).isMultiple(of: 2) ? 0.025 : -0.025
            let xPhase = Double(x) * 2.0 * Double.pi / 19.0
            let yPhase = Double(y) * 2.0 * Double.pi / 23.0
            let xDetail: Double = 0.11 * sin(xPhase)
            let yDetail: Double = 0.07 * cos(yPhase)
            let value: Float = Float(0.43 + xDetail + yDetail + fine + noise)
            return (value, value, value, 1)
        }
        let settings = LocalDetailSettings(smoothing: 1, textureRetention: 0.1,
                                           toneUniformity: 0.5, noiseReduction: 1, detailRecovery: 1)
        let output = try LocalDetailEngine.apply(source, settings: settings, noiseEstimate: 0.025)
        let before = render(source), after = render(output)
        var maximumEV = 0.0

        for index in stride(from: 0, to: before.count, by: 4) {
            let beforeLuma = luminance(before, at: index)
            let afterLuma = luminance(after, at: index)
            guard beforeLuma > 0.000001, afterLuma > 0.000001 else { continue }
            maximumEV = max(maximumEV, abs(log2(afterLuma / beforeLuma)))
        }

        XCTAssertGreaterThan(maximumEV, 0.005, "the source should exercise the combined detail path")
        XCTAssertLessThanOrEqual(maximumEV, 0.122,
                                 "smoothing plus noise reduction and recovery share one ±0.12 EV bound")
    }

    func testNewDetailControlsKeepFlatBlackAndWhiteFlatAndDoNotHaloAStrongEdge() throws {
        let settings = LocalDetailSettings(smoothing: 1, textureRetention: 0.1, toneUniformity: 1,
                                           noiseReduction: 1, detailRecovery: 1)
        let black = solidImage(0, width: 64, height: 64, origin: .zero)
        let white = solidImage(1, width: 64, height: 64, origin: .zero)
        let blackOutput = try LocalDetailEngine.apply(black, settings: settings, noiseEstimate: 0.1)
        let whiteOutput = try LocalDetailEngine.apply(white, settings: settings, noiseEstimate: 0.1)

        XCTAssertEqual(render(blackOutput), render(black), "a black plane has no texture to recover")
        XCTAssertEqual(render(whiteOutput), render(white), "a white plane has no texture to recover")

        let width = 80, height = 32
        let edge = image(width: width, height: height) { (x: Int, y: Int) -> RGBA in
            let value: Float = x < width / 2 ? 0.22 : 0.72
            return (value, value, value, 1)
        }
        let edgeOutput = try LocalDetailEngine.apply(edge, settings: settings, noiseEstimate: 0.08)
        let pixels = render(edgeOutput)
        var previousColumnMean = 0.0
        for x in 0..<width {
            var columnMean = 0.0
            for y in 0..<height {
                let value = Double(pixels[(y * width + x) * 4])
                XCTAssertGreaterThanOrEqual(value, 0.218)
                XCTAssertLessThanOrEqual(value, 0.722)
                columnMean += value / Double(height)
            }
            if x > 0 {
                XCTAssertGreaterThanOrEqual(columnMean + 0.003, previousColumnMean,
                                            "detail refinement must not create a bright/dark edge halo")
            }
            previousColumnMean = columnMean
        }
    }

    func testLowStrengthChromaCleanupKeepsSkinAndFabricHueAndLimitsSaturationLoss() throws {
        let source = image(width: 96, height: 64) { (x: Int, y: Int) -> RGBA in
            let code = (x * 13 + y * 7) % 11
            let jitter = Float(code - 5) * 0.0005
            if x < 48 {
                return (0.67 + jitter, 0.39 - jitter * 0.2, 0.28 - jitter * 0.5, 1)
            }
            return (0.24 + jitter, 0.43 - jitter * 0.3, 0.60 - jitter * 0.5, 1)
        }
        let output = try LocalDetailEngine.apply(
            source, settings: LocalDetailSettings(noiseReduction: 0.7), noiseEstimate: 0.006)
        let before = render(source), after = render(output)
        var checked = 0

        for index in stride(from: 0, to: before.count, by: 4) {
            let sourceChroma = opponentChroma(before, at: index)
            let outputChroma = opponentChroma(after, at: index)
            let sourceMagnitude = hypot(sourceChroma.red, sourceChroma.blue)
            let outputMagnitude = hypot(outputChroma.red, outputChroma.blue)
            guard sourceMagnitude > 0.05, outputMagnitude > 0.000001 else { continue }
            let normalizedCross = abs(sourceChroma.red * outputChroma.blue
                                      - sourceChroma.blue * outputChroma.red)
                / (sourceMagnitude * outputMagnitude)
            let retainedChroma = outputMagnitude / sourceMagnitude
            XCTAssertLessThan(normalizedCross, 0.01,
                              "noise cleanup must not rotate the opponent-color hue vector")
            XCTAssertGreaterThanOrEqual(retainedChroma, 0.875,
                                        "chroma reduction must remain within 12% plus small float tolerance")
            XCTAssertLessThanOrEqual(retainedChroma, 1.005)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testNeutralNewControlsPreserveLegacyLocalDetailOutput() throws {
        let source = image(width: 64, height: 64) { (x: Int, y: Int) -> RGBA in
            let xDetail: Double = 0.04 * sin(Double(x) * 0.31)
            let yDetail: Double = 0.025 * cos(Double(y) * 0.27)
            let value: Float = Float(0.34 + xDetail + yDetail)
            return (value, value * 0.92, value * 0.84, 1)
        }
        let legacy = LocalDetailSettings(smoothing: 0.6, textureRetention: 0.9, toneUniformity: 0.1)
        let withNeutralNewControls = LocalDetailSettings(
            smoothing: 0.6, textureRetention: 0.9, toneUniformity: 0.1,
            noiseReduction: 0, detailRecovery: 0)

        let legacyOutput = try LocalDetailEngine.apply(source, settings: legacy)
        let neutralOutput = try LocalDetailEngine.apply(source, settings: withNeutralNewControls)

        XCTAssertEqual(render(neutralOutput), render(legacyOutput),
                       "zero noise/recovery controls must keep the prior detail path pixel-identical")
    }

    func testNewDetailControlsPreserveAlphaAndStayWithinSDRForSDRInput() throws {
        let source = image(width: 32, height: 24, origin: CGPoint(x: -8, y: 13)) { (x: Int, y: Int) -> RGBA in
            let alpha: Float = [0, 0.25, 0.7, 1][x % 4]
            let redVariation: Double = 0.12 * sin(Double(x) * 0.43)
                + 0.02 * cos(Double(y) * 0.31)
            let greenVariation: Double = 0.08 * sin(Double(x + y) * 0.23)
            let blueVariation: Double = 0.05 * cos(Double(x - y) * 0.29)
            let red = Float(0.82 + redVariation)
            let green = Float(0.35 + greenVariation)
            let blue = Float(0.12 + blueVariation)
            return (min(0.99, max(0, red)), min(0.99, max(0, green)), min(0.99, max(0, blue)), alpha)
        }
        let output = try LocalDetailEngine.apply(
            source, settings: LocalDetailSettings(noiseReduction: 1, detailRecovery: 1), noiseEstimate: 0.02)
        let before = render(source)
        let after = render(output)

        XCTAssertEqual(output.extent, source.extent)
        for index in stride(from: 0, to: before.count, by: 4) {
            let alpha = Double(before[index + 3])
            XCTAssertEqual(after[index + 3], before[index + 3], accuracy: 0.002)
            for channel in 0..<3 {
                let value = Double(after[index + channel])
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, -0.002)
                XCTAssertLessThanOrEqual(value, alpha + 0.003,
                                         "premultiplied SDR channels must not exceed their alpha headroom")
            }
        }
    }

    func testNoiseAndRecoveryPreserveNegativeAndExtendedLinearValues() throws {
        let width = 96, height = 64
        let source = image(width: width, height: height) { (x: Int, y: Int) -> RGBA in
            let xPhase = Double(x) * 2.0 * Double.pi / 17.0
            let yPhase = Double(y) * 2.0 * Double.pi / 21.0
            let xVariation: Double = 0.012 * sin(xPhase)
            let yVariation: Double = 0.008 * cos(yPhase)
            let code = (x * 31 + y * 17 + x * y * 3) % 97
            let noise: Double = (Double(code) / 96.0 - 0.5) * 0.012
            let base: Double = x < width / 2 ? -0.22 : 1.24
            let value: Float = Float(base + xVariation + yVariation + noise)
            return (value, value, value, 1)
        }
        let settings = LocalDetailSettings(noiseReduction: 1, detailRecovery: 1)
        let output = try LocalDetailEngine.apply(source, settings: settings, noiseEstimate: 0.025)
        let before = render(source), after = render(output)
        var negativeSamples = 0
        var extendedSamples = 0

        XCTAssertEqual(output.extent, source.extent)
        for y in 4..<height - 4 {
            for x in 4..<width - 4 {
                let index = (y * width + x) * 4
                let beforeLuma = luminance(before, at: index)
                let afterLuma = luminance(after, at: index)
                XCTAssertEqual(after[index + 3], before[index + 3], accuracy: 0.002)
                for channel in 0..<3 { XCTAssertTrue(after[index + channel].isFinite) }
                XCTAssertGreaterThan(beforeLuma * afterLuma, 0,
                                     "detail processing must not flip negative or positive luminance")
                let relativeEV = abs(log2(abs(afterLuma / beforeLuma)))
                XCTAssertLessThanOrEqual(relativeEV, 0.122,
                                         "extended values should obey the same local exposure bound")
                if x < width / 2 {
                    XCTAssertLessThan(afterLuma, 0)
                    negativeSamples += 1
                } else {
                    XCTAssertGreaterThan(afterLuma, 1)
                    extendedSamples += 1
                }
            }
        }
        XCTAssertGreaterThan(negativeSamples, 0)
        XCTAssertGreaterThan(extendedSamples, 0)
    }

    func testNewDetailSettingsAndNoiseEstimateRejectInvalidBounds() {
        XCTAssertThrowsError(try LocalDetailEngine.validate(
            LocalDetailSettings(noiseReduction: .nan)))
        XCTAssertThrowsError(try LocalDetailEngine.validate(
            LocalDetailSettings(detailRecovery: .infinity)))
        XCTAssertThrowsError(try LocalDetailEngine.validate(
            LocalDetailSettings(noiseReduction: 1.01)))
        XCTAssertThrowsError(try LocalDetailEngine.validate(
            LocalDetailSettings(detailRecovery: -0.01)))
        XCTAssertThrowsError(try LocalDetailEngine.apply(
            solidImage(0.3, width: 8, height: 8, origin: .zero),
            settings: LocalDetailSettings(noiseReduction: 0.5), noiseEstimate: .nan))
        XCTAssertThrowsError(try LocalDetailEngine.apply(
            solidImage(0.3, width: 8, height: 8, origin: .zero),
            settings: LocalDetailSettings(detailRecovery: 0.5), noiseEstimate: 0.251))
    }

    func testRecipeSevenRoundTripsAdaptationAndVersionSixReadsOldDetailFields() throws {
        let mask = LocalMask(kind: .luminance, exposureEV: 0,
                             detail: LocalDetailSettings(smoothing: 0.3, textureRetention: 0.85,
                                                         toneUniformity: 0.1),
                             detailAdaptation: LocalDetailAdaptation(intent: .portrait, strength: 0.7))
        var settings = AdjustmentSettings()
        settings.masks = [mask]
        var current = Recipe(adjustments: settings)
        current.adjustments.masks[0].detail = LocalDetailSettings(
            smoothing: 0.3, textureRetention: 0.85, toneUniformity: 0.1,
            noiseReduction: 0.2, detailRecovery: 0.1)

        XCTAssertEqual(current.version, 8)
        current.version = 7
        XCTAssertNoThrow(try current.validateVersion())
        XCTAssertEqual(try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(current)), current)

        let oldDetail = LocalDetailSettings(smoothing: 0.3, textureRetention: 0.85, toneUniformity: 0.1)
        let oldMask = LocalMask(kind: .luminance, exposureEV: 0, detail: oldDetail)
        var oldSettings = AdjustmentSettings()
        oldSettings.masks = [oldMask]
        var legacy = Recipe(adjustments: oldSettings)
        legacy.version = 6
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))
                                   as? [String: Any])
        var adjustmentObject = try XCTUnwrap(object["adjustments"] as? [String: Any])
        var masks = try XCTUnwrap(adjustmentObject["masks"] as? [[String: Any]])
        var maskObject = try XCTUnwrap(masks.first)
        var detailObject = try XCTUnwrap(maskObject["detail"] as? [String: Any])
        detailObject.removeValue(forKey: "noiseReduction")
        detailObject.removeValue(forKey: "detailRecovery")
        maskObject.removeValue(forKey: "detailAdaptation")
        maskObject["detail"] = detailObject
        masks[0] = maskObject
        adjustmentObject["masks"] = masks
        object["adjustments"] = adjustmentObject

        let decodedLegacy = try JSONDecoder().decode(
            Recipe.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertNoThrow(try decodedLegacy.validateVersion())
        XCTAssertEqual(decodedLegacy.adjustments.masks[0].detail?.noiseReduction, 0)
        XCTAssertEqual(decodedLegacy.adjustments.masks[0].detail?.detailRecovery, 0)

        var versionSixWithAdaptation = decodedLegacy
        versionSixWithAdaptation.adjustments.masks[0].detailAdaptation = LocalDetailAdaptation(strength: 0)
        XCTAssertThrowsError(try versionSixWithAdaptation.validateVersion())
        var versionSixWithNewControl = decodedLegacy
        versionSixWithNewControl.adjustments.masks[0].detail = oldDetail
        versionSixWithNewControl.adjustments.masks[0].detail?.noiseReduction = 0.01
        XCTAssertThrowsError(try versionSixWithNewControl.validateVersion())
        var versionSixWithRecovery = decodedLegacy
        versionSixWithRecovery.adjustments.masks[0].detail = oldDetail
        versionSixWithRecovery.adjustments.masks[0].detail?.detailRecovery = 0.01
        XCTAssertThrowsError(try versionSixWithRecovery.validateVersion())

        var baseline = AdjustmentSettings()
        baseline.masks = [LocalMask(kind: .luminance, exposureEV: 0,
                                    detailAdaptation: LocalDetailAdaptation())]
        let automatic = AutomaticBatchRecipe(styleID: "balanced", baseline: baseline,
                                             referenceSettings: AdjustmentSettings())
        var versionSixBaseline = Recipe(automatic: automatic)
        versionSixBaseline.version = 6
        XCTAssertThrowsError(try versionSixBaseline.validateVersion(),
                             "baseline masks also require recipe version 7")
        var reference = AdjustmentSettings()
        reference.masks = [LocalMask(kind: .luminance, exposureEV: 0,
                                     detailAdaptation: LocalDetailAdaptation())]
        let automaticReference = AutomaticBatchRecipe(styleID: "balanced", baseline: AdjustmentSettings(),
                                                      referenceSettings: reference)
        var versionSixReference = Recipe(automatic: automaticReference)
        versionSixReference.version = 6
        XCTAssertThrowsError(try versionSixReference.validateVersion(),
                             "reference masks also require recipe version 7")
    }

    private func analyze(_ source: CIImage, coverage: CIImage? = nil,
                         adaptation: LocalDetailAdaptation = LocalDetailAdaptation(),
                         target: ContentSelectionTarget? = nil,
                         isSpatiallyLimited: Bool = false,
                         maskID: UUID = UUID()) throws -> LocalDetailPlan {
        let actualCoverage = coverage ?? coverageImage(
            width: Int(source.extent.width), height: Int(source.extent.height), origin: source.extent.origin) { _, _ in true }
        return try AdaptiveLocalDetailAnalyzer.analyze(
            reference: source, coverage: actualCoverage, maskID: maskID, target: target,
            adaptation: adaptation, context: context, isSpatiallyLimited: isSpatiallyLimited)
    }

    private func image(width: Int, height: Int, origin: CGPoint = .zero,
                       pixel: (Int, Int) -> RGBA) -> CIImage {
        var components = [Float]()
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
                       size: CGSize(width: width, height: height), format: .RGBAf,
                       colorSpace: linearColorSpace)
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    private func solidImage(_ value: Double, width: Int, height: Int, origin: CGPoint) -> CIImage {
        image(width: width, height: height, origin: origin) { _, _ in
            let sample = Float(value)
            return (sample, sample, sample, 1)
        }
    }

    private func coverageImage(width: Int, height: Int, origin: CGPoint = .zero,
                               selected: (Int, Int) -> Bool) -> CIImage {
        image(width: width, height: height, origin: origin) { x, y in
            let value: Float = selected(x, y) ? 1 : 0
            return (value, value, value, 1)
        }
    }

    private func render(_ image: CIImage) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: image.extent, format: .RGBAf, colorSpace: linearColorSpace)
        }
        return pixels
    }

    private func maximumDifference(_ lhs: [Float], _ rhs: [Float]) -> Double {
        zip(lhs, rhs).map { abs(Double($0 - $1)) }.max() ?? 0
    }

    private func luminance(_ pixels: [Float], at index: Int) -> Double {
        0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1])
            + 0.0722 * Double(pixels[index + 2])
    }

    private func opponentChroma(_ pixels: [Float], at index: Int) -> (red: Double, blue: Double) {
        let luma = luminance(pixels, at: index)
        return (Double(pixels[index]) - luma, Double(pixels[index + 2]) - luma)
    }

    private func exposureAdjusted(_ image: CIImage, ev: Double) throws -> CIImage {
        let filter = try XCTUnwrap(CIFilter(name: "CIExposureAdjust"))
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(NSNumber(value: ev), forKey: "inputEV")
        return try XCTUnwrap(filter.outputImage).cropped(to: image.extent)
    }

    private func testCubeText(size: Int,
                              transform: (Double, Double, Double) -> (Double, Double, Double)) -> String {
        var rows: [String] = []
        let divisor = Double(size - 1)
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let result = transform(Double(red) / divisor,
                                           Double(green) / divisor,
                                           Double(blue) / divisor)
                    rows.append("\(result.0) \(result.1) \(result.2)")
                }
            }
        }
        return "LUT_3D_SIZE \(size)\n" + rows.joined(separator: "\n")
    }

    private func rmsLuminanceDeviation(_ rgba: [Float], width: Int, height: Int, center: Double) -> Double {
        var squared = 0.0
        var count = 0
        for y in 4..<height - 4 {
            for x in 4..<width - 4 {
                let offset = (y * width + x) * 4
                let luma = 0.2126 * Double(rgba[offset]) + 0.7152 * Double(rgba[offset + 1])
                    + 0.0722 * Double(rgba[offset + 2])
                squared += (luma - center) * (luma - center)
                count += 1
            }
        }
        return sqrt(squared / Double(max(1, count)))
    }

    private func alternatingPairEnergy(_ rgba: [Float], width: Int, height: Int) -> Double {
        var total = 0.0
        var count = 0
        for y in 4..<height - 4 {
            for x in stride(from: 4, to: width - 4, by: 2) {
                let first = (y * width + x) * 4
                let second = first + 4
                let firstLuma = 0.2126 * Double(rgba[first]) + 0.7152 * Double(rgba[first + 1])
                    + 0.0722 * Double(rgba[first + 2])
                let secondLuma = 0.2126 * Double(rgba[second]) + 0.7152 * Double(rgba[second + 1])
                    + 0.0722 * Double(rgba[second + 2])
                total += abs(firstLuma - secondLuma)
                count += 1
            }
        }
        return total / Double(max(1, count))
    }
}

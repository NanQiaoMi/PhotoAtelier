import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import PhotoCore

final class SceneAdaptiveTests: XCTestCase {
    private typealias RGBA = (r: Float, g: Float, b: Float, a: Float)

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var renderContext = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: false,
        .cacheIntermediates: false
    ])
    private lazy var engine = PhotoEngine()

    func testSameMedianSeparatesRangeChromaAndHighlightEvidence() {
        let narrowMetrics = metrics(p05: 0.14, p95: 0.23, p99: 0.30,
                                   dynamicRange: log2(0.23 / 0.14))
        let broadMetrics = metrics(p05: 0.012, p95: 0.875, p99: 0.92,
                                   dynamicRange: log2(0.875 / 0.012))
        let narrow = assess(metrics: narrowMetrics,
                            colors: colors(warm: 0.25, cool: 0.25, neutral: 0.50))
        let broad = assess(metrics: broadMetrics,
                           colors: colors(warm: 0.20, cool: 0.20, neutral: 0.60,
                                          dark: 0.20, bright: 0.10))
        let chromatic = assess(metrics: metrics(p05: 0.012, p95: 0.875, p99: 0.92,
                                               dynamicRange: log2(0.875 / 0.012),
                                               meanSaturation: 0.45),
                               colors: colors(warm: 0.45, cool: 0.30, neutral: 0.25,
                                              saturated: 0.60, dark: 0.20, bright: 0.10))
        let noHighlight = assess(metrics: metrics(p05: 0.10, p95: 0.25, p99: 0.30,
                                                  dynamicRange: log2(0.25 / 0.10)),
                                 colors: colors(neutral: 0.7, dark: 0.1, bright: 0.02))
        let sparseHighlight = assess(metrics: metrics(p05: 0.10, p95: 0.25, p99: 0.99,
                                                      nearWhite: 0.02,
                                                      dynamicRange: log2(0.25 / 0.10)),
                                     colors: colors(neutral: 0.7, dark: 0.1, bright: 0.02))

        XCTAssertEqual(narrowMetrics.medianLuminance, broadMetrics.medianLuminance)
        XCTAssertEqual(narrow.category, .softAtmosphere)
        XCTAssertTrue(narrow.traits.contains(.softContrast))
        XCTAssertEqual(broad.category, .general)
        XCTAssertEqual(broad.selectionSource, .fallback)
        XCTAssertTrue(broad.traits.contains(.wideDynamicRange))
        XCTAssertTrue(chromatic.traits.contains(.highChroma))
        XCTAssertTrue(chromatic.traits.contains(.colorSeparation))
        XCTAssertEqual(chromatic.balanced.saturation, 0, accuracy: 0.000001)
        XCTAssertEqual(chromatic.bright.saturation, 0, accuracy: 0.000001)
        XCTAssertTrue(chromatic.evidence.contains { $0.contains("不据此判断混合灯光") })
        XCTAssertGreaterThan(noHighlight.bright.exposureEV, sparseHighlight.bright.exposureEV)
        XCTAssertEqual(sparseHighlight.bright.exposureEV, 0, accuracy: 0.000001)
    }

    func testExplicitIntentWinsContradictoryNightLabelButAutomaticUsesPixelEvidence() {
        let brightMetrics = metrics(median: 0.82, p05: 0.65, p95: 0.96, p99: 0.99,
                                   dynamicRange: log2(0.96 / 0.65), meanSaturation: 0.02)
        let brightColors = colors(neutral: 0.97, bright: 0.95)
        let nightLabel = [PhotoContentLabel(id: "vision.night", label: "night",
                                            confidence: 0.99, source: "test")]

        let automatic = assess(metrics: brightMetrics, colors: brightColors, labels: nightLabel)
        let explicit = assess(metrics: brightMetrics, colors: brightColors, labels: nightLabel,
                              intent: .night)

        XCTAssertEqual(automatic.category, .highKey)
        XCTAssertEqual(automatic.selectionSource, .evidence)
        XCTAssertEqual(explicit.category, .night)
        XCTAssertEqual(explicit.requestedIntent, .night)
        XCTAssertEqual(explicit.selectionSource, .user)
    }

    func testPortraitLabelAloneDoesNotCreateFaceEvidenceOrGuessWhitePoint() throws {
        let portraitLabel = PhotoContentLabel(id: "vision.portrait", label: "portrait",
                                              confidence: 0.99, source: "test")
        let colorMetrics = metrics(median: 0.30, p05: 0.08, p95: 0.65, p99: 0.80,
                                   dynamicRange: 3.0, meanSaturation: 0.65)
        let warmColors = colors(warm: 1, neutral: 0, saturated: 0.8)
        let labelOnly = assess(metrics: colorMetrics, colors: warmColors, labels: [portraitLabel])

        XCTAssertEqual(labelOnly.category, .general)
        XCTAssertEqual(labelOnly.selectionSource, .fallback)
        XCTAssertFalse(labelOnly.traits.contains(.measuredFaces))
        XCTAssertTrue(labelOnly.uncertainties.contains { $0.contains("题材证据不足") })

        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        baseline.autoWhiteBalance = false
        baseline.temperature = 0.14
        baseline.tint = -0.07
        let warmImage = solidImage(r: 0.72, g: 0.36, b: 0.20)
        let analysis = try PhotoAnalyzer().analyze(image: warmImage, properties: [:],
                                                   baseline: baseline, intent: .portrait)
        XCTAssertEqual(analysis.sceneAssessment?.requestedIntent, .portrait)
        for proposal in analysis.proposals {
            XCTAssertFalse(proposal.settings.autoWhiteBalance)
            XCTAssertEqual(proposal.settings.temperature, baseline.temperature, accuracy: 0.000001)
            XCTAssertEqual(proposal.settings.tint, baseline.tint, accuracy: 0.000001)
        }
    }

    func testHighKeyLowKeyAndHighISONightKeepTheirIntent() {
        let high = assess(metrics: metrics(median: 0.82, p05: 0.65, p95: 0.96, p99: 0.99,
                                           dynamicRange: 0.56, meanSaturation: 0.02),
                          colors: colors(neutral: 0.96, bright: 0.94), intent: .highKey)
        let lowMetrics = metrics(median: 0.018, p05: 0.007, p95: 0.04, p99: 0.10,
                                 nearBlack: 0.02, dynamicRange: log2(0.04 / 0.007))
        let lowColors = colors(neutral: 0.85, dark: 0.98)
        let low = assess(metrics: lowMetrics, colors: lowColors, intent: .lowKey)
        let night = assess(metrics: lowMetrics, colors: lowColors, intent: .night, iso: 6400)

        XCTAssertEqual(high.category, .highKey)
        XCTAssertEqual(high.balanced.exposureEV, 0, accuracy: 0.000001)
        XCTAssertLessThanOrEqual(high.bright.exposureEV, 0)
        XCTAssertEqual(low.category, .lowKey)
        XCTAssertEqual(low.balanced.exposureEV, 0, accuracy: 0.000001)
        XCTAssertLessThanOrEqual(low.bright.exposureEV, 0.04)
        XCTAssertEqual(night.category, .night)
        XCTAssertLessThanOrEqual(night.bright.exposureEV, 0.02)
        XCTAssertLessThanOrEqual(night.bright.shadows, 0.005)
        XCTAssertTrue(night.evidence.contains { $0.contains("ISO 本身不等于实测噪声") })
    }

    func testHighKeyLowKeyAndNightProposalsKeepRenderedTone() throws {
        let highImage = solidImage(r: 0.82, g: 0.82, b: 0.82)
        let darkImage = solidImage(r: 0.018, g: 0.018, b: 0.018)
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        let analyzer = PhotoAnalyzer()
        let high = try analyzer.analyze(image: highImage, properties: [:],
                                        baseline: baseline, intent: .highKey)
        let low = try analyzer.analyze(image: darkImage, properties: [:],
                                       baseline: baseline, intent: .lowKey)
        let exif: [String: Any] = [kCGImagePropertyExifDictionary as String: ["ISOSpeedRatings": [6400]]]
        let night = try analyzer.analyze(image: darkImage, properties: exif,
                                         baseline: baseline, intent: .night)

        func proposalMedian(_ analysis: PhotoAnalysis, source: CIImage, id: String = "balanced") throws -> Double {
            let proposal = try XCTUnwrap(analysis.proposals.first { $0.id == id })
            let pixels = try render(engine.process(source, settings: proposal.settings, lut: nil).image)
            return try XCTUnwrap(medianLuminance(pixels))
        }
        let highBefore = try XCTUnwrap(medianLuminance(try render(highImage)))
        let lowBefore = try XCTUnwrap(medianLuminance(try render(darkImage)))
        let highAfter = try proposalMedian(high, source: highImage)
        let lowAfter = try proposalMedian(low, source: darkImage)
        let nightAfter = try proposalMedian(night, source: darkImage)
        let nightBrightAfter = try proposalMedian(night, source: darkImage, id: "bright")

        XCTAssertEqual(highAfter, highBefore, accuracy: 0.002,
                       "High-key pixels must not be pulled toward middle gray.")
        XCTAssertEqual(lowAfter, lowBefore, accuracy: 0.001,
                       "Low-key pixels must not receive a global normalization lift.")
        XCTAssertEqual(nightAfter, lowBefore, accuracy: 0.001)
        XCTAssertLessThan(nightBrightAfter, 0.025,
                          "A night option may lift shadows slightly but should keep the scene dark.")
    }

    func testSceneAwareFindingsDoNotCallHighOrLowKeyAnExposureDefect() throws {
        let highKeyPixels = pixelImage(width: 100, height: 100) { x, y in
            let index = y * 100 + x
            if index < 200 { return (0.001, 0.001, 0.001, 1) }
            if index < 400 { return (1, 1, 1, 1) }
            return (0.85, 0.85, 0.85, 1)
        }
        let lowKeyPixels = pixelImage(width: 100, height: 100) { x, y in
            y * 100 + x < 200 ? (0.001, 0.001, 0.001, 1) : (0.02, 0.02, 0.02, 1)
        }
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        let fixtures: [(intent: PhotoSceneIntent, image: CIImage, category: PhotoSceneCategory,
                        findingIDs: [String])] = [
            (.highKey, highKeyPixels, .highKey, ["level.nearBlack", "level.nearWhite", "contrast.range"]),
            (.lowKey, lowKeyPixels, .lowKey, ["level.nearBlack", "contrast.range"]),
            (.preserveStyle, lowKeyPixels, .preserveStyle, ["level.nearBlack", "contrast.range"])
        ]

        for fixture in fixtures {
            let analysis = try PhotoAnalyzer().analyze(image: fixture.image, properties: [:],
                                                       baseline: baseline, intent: fixture.intent)
            let scene = try XCTUnwrap(analysis.sceneAssessment)
            XCTAssertEqual(scene.category, fixture.category)
            let exposure = try XCTUnwrap(analysis.issues.first { $0.id.hasPrefix("exposure.") })
            XCTAssertEqual(exposure.severity, .info)
            XCTAssertTrue(exposure.direction.contains(scene.balanced.direction),
                          "\(fixture.intent): exposure guidance must follow the selected scene direction")

            let observed = Dictionary(uniqueKeysWithValues: analysis.issues.map { ($0.id, $0) })
            for id in fixture.findingIDs {
                XCTAssertNotNil(observed[id], "\(fixture.intent): expected finding \(id)")
            }
            for id in ["level.nearBlack", "level.nearWhite", "contrast.range"] {
                guard let finding = observed[id] else { continue }
                XCTAssertTrue(finding.direction.contains(scene.balanced.direction),
                              "\(fixture.intent), \(id): guidance must follow the selected scene direction")
                if id == "level.nearBlack" {
                    XCTAssertTrue(finding.direction.contains("不能证明暗部信息可恢复"))
                } else if id == "level.nearWhite" {
                    XCTAssertTrue(finding.direction.contains("不承诺恢复源文件已经丢失的高光细节"))
                }
                if fixture.intent == .preserveStyle {
                    for correctivePhrase in ["建议提升曝光", "可提升曝光", "可抬起阴影", "建议降低曝光",
                                             "可降低曝光", "收回高光", "增加对比度"] {
                        XCTAssertFalse(finding.direction.contains(correctivePhrase),
                                       "Preserve-style guidance must not recommend correction: \(finding.direction)")
                    }
                }
            }
        }
    }

    func testSoftAtmosphereRenderedPixelsDoNotGainContrast() throws {
        let source = pixelImage(width: 96, height: 64) { x, _ in
            let value = Float(0.16 + 0.08 * Double(x) / 95)
            return (value, value, value, 1)
        }
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        baseline.contrast = 1.15
        let analysis = try PhotoAnalyzer().analyze(image: source, properties: [:],
                                                   baseline: baseline, intent: .softAtmosphere)
        let scene = try XCTUnwrap(analysis.sceneAssessment)
        XCTAssertEqual(scene.category, .softAtmosphere)
        for delta in [scene.balanced, scene.bright, scene.soft] {
            XCTAssertLessThanOrEqual(delta.contrast, 0)
            XCTAssertLessThanOrEqual(delta.saturation, 0)
        }

        let proposal = try XCTUnwrap(analysis.proposals.first { $0.id == "soft" })
        let before = try render(engine.process(source, settings: baseline, lut: nil).image)
        let after = try render(engine.process(source, settings: proposal.settings, lut: nil).image)
        assertPixelsEqual(before, after, accuracy: 0.00001)
    }

    func testMonochromeIntentKeepsRenderedProposalAchromatic() throws {
        let source = pixelImage(width: 80, height: 64) { x, _ in
            let value = Float(0.08 + 0.20 * Double(x) / 79)
            return (value, value, value, 1)
        }
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        baseline.saturation = 1.8
        let analysis = try PhotoAnalyzer().analyze(image: source, properties: [:],
                                                   baseline: baseline, intent: .monochrome)
        let scene = try XCTUnwrap(analysis.sceneAssessment)
        XCTAssertEqual(scene.category, .monochrome)
        for delta in [scene.balanced, scene.bright, scene.soft] {
            XCTAssertEqual(delta.saturation, 0, accuracy: 0.000001)
        }
        for proposal in analysis.proposals {
            XCTAssertEqual(proposal.settings.saturation, baseline.saturation, accuracy: 0.000001)
            assertAchromatic(try render(engine.process(source, settings: proposal.settings, lut: nil).image))
        }

        let coloredSource = solidImage(r: 0.62, g: 0.16, b: 0.07)
        let coloredAnalysis = try PhotoAnalyzer().analyze(image: coloredSource, properties: [:],
                                                          baseline: baseline, intent: .monochrome)
        XCTAssertTrue(try XCTUnwrap(coloredAnalysis.sceneAssessment).uncertainties
            .contains { $0.contains("不执行黑白转换") })
        let coloredProposal = try XCTUnwrap(coloredAnalysis.proposals.first { $0.id == "balanced" })
        let renderedColor = try render(engine.process(coloredSource, settings: coloredProposal.settings,
                                                      lut: nil).image)
        XCTAssertGreaterThan(meanSaturation(renderedColor), 0.35,
                             "Monochrome intent preserves existing color; it does not convert a color photo.")
    }

    func testPreserveStyleProducesZeroDeltasAndPixelIdenticalProposals() throws {
        let source = pixelImage(width: 72, height: 64) { x, y in
            let value = Float(0.08 + Double((x + y) % 48) * 0.012)
            return (value, value * 0.92, value * 0.84, 1)
        }
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        baseline.exposureEV = 0.18
        baseline.temperature = 0.11
        baseline.tint = -0.06
        baseline.contrast = 1.12
        baseline.saturation = 1.08
        baseline.highlights = -0.08
        baseline.shadows = 0.06
        let analysis = try PhotoAnalyzer().analyze(image: source, properties: [:],
                                                   baseline: baseline, intent: .preserveStyle)
        let scene = try XCTUnwrap(analysis.sceneAssessment)
        XCTAssertEqual(scene.category, .preserveStyle)
        XCTAssertEqual(scene.selectionSource, .user)
        for delta in [scene.balanced, scene.bright, scene.soft] {
            XCTAssertEqual(delta.exposureEV, 0, accuracy: 0.000001)
            XCTAssertEqual(delta.contrast, 0, accuracy: 0.000001)
            XCTAssertEqual(delta.saturation, 0, accuracy: 0.000001)
            XCTAssertEqual(delta.highlights, 0, accuracy: 0.000001)
            XCTAssertEqual(delta.shadows, 0, accuracy: 0.000001)
        }

        let before = try render(engine.process(source, settings: baseline, lut: nil).image)
        for proposal in analysis.proposals {
            XCTAssertEqual(proposal.settings, baseline)
            let after = try render(engine.process(source, settings: proposal.settings, lut: nil).image)
            assertPixelsEqual(before, after, accuracy: 0.00001)
        }
    }

    func testPreserveStyleBakesLegacyAutoExposureOnceAndKeepsRenderedPixels() throws {
        let source = solidImage(r: 0.06, g: 0.06, b: 0.06, width: 96, height: 80)
        var baseline = AdjustmentSettings()
        baseline.autoExposure = true
        baseline.exposureEV = 0
        let legacyRender = try render(engine.process(source, settings: baseline, lut: nil).image)
        let analysis = try PhotoAnalyzer().analyze(image: source, properties: [:],
                                                   baseline: baseline, intent: .preserveStyle)

        for proposal in analysis.proposals {
            XCTAssertFalse(proposal.settings.autoExposure,
                           "The measured legacy auto exposure must be fixed before proposals are applied.")
            XCTAssertEqual(try XCTUnwrap(proposal.safety).exposureDeltaEV, 0, accuracy: 0.000001)
            let proposalPixels = try render(engine.process(source, settings: proposal.settings, lut: nil).image)
            assertPixelsEqual(legacyRender, proposalPixels, accuracy: 0.0001)
        }
    }

    func testFaceMeasurementUsesBottomLeftRegionsAfterNonzeroExtentTranslation() throws {
        let source = verticalHalves(lower: 0.12, upper: 0.82, width: 96, height: 96)
            .transformed(by: CGAffineTransform(translationX: 31, y: -17))
        let lowerBox = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        let upperBox = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        let expectedLower = try XCTUnwrap(independentMedian(source, inside: lowerBox))
        let expectedUpper = try XCTUnwrap(independentMedian(source, inside: upperBox))
        let lower = try XCTUnwrap(FaceRegionAnalyzer.measure(image: source, regions: [lowerBox],
                                                             context: renderContext))
        let upper = try XCTUnwrap(FaceRegionAnalyzer.measure(image: source, regions: [upperBox],
                                                             context: renderContext))

        XCTAssertLessThan(expectedLower, expectedUpper - 0.4)
        XCTAssertEqual(lower.medianLuminance, expectedLower, accuracy: 0.002)
        XCTAssertEqual(upper.medianLuminance, expectedUpper, accuracy: 0.002)
        XCTAssertEqual(lower.coverage, 0.5, accuracy: 0.02)
        XCTAssertEqual(upper.coverage, 0.5, accuracy: 0.02)
        let assessment = assess(metrics: metrics(), colors: colors(neutral: 0.5), subject: lower)
        XCTAssertEqual(assessment.subject, lower)
        XCTAssertTrue(assessment.traits.contains(.measuredFaces))
    }

    func testFaceMeasurementAlphaWeightsVisiblePixels() throws {
        let source = pixelImage(width: 64, height: 64) { x, _ in
            x < 48 ? (1, 1, 1, 0.005) : (0.10, 0.10, 0.10, 1)
        }
        let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
        let subject = try XCTUnwrap(FaceRegionAnalyzer.measure(image: source, regions: [fullFrame],
                                                               context: renderContext))

        XCTAssertEqual(subject.sampleCount, 64 * 64)
        XCTAssertEqual(subject.coverage, 1, accuracy: 0.001)
        XCTAssertLessThan(subject.medianLuminance, 0.2,
                          "The many faint bright pixels must not outweigh fewer opaque dark pixels.")
        XCTAssertEqual(subject.nearWhiteFraction, 0.005 * 3072 / (1024 + 0.005 * 3072), accuracy: 0.002)
    }

    func testSceneAssessmentAndAnalysisRecordRoundTripAndLegacyJSONDecode() throws {
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        let analysis = try PhotoAnalyzer().analyze(image: solidImage(r: 0.8, g: 0.8, b: 0.8),
                                                   properties: [:], baseline: baseline,
                                                   intent: .highKey)
        let decoded = try JSONDecoder().decode(PhotoAnalysis.self, from: JSONEncoder().encode(analysis))
        XCTAssertEqual(decoded.sceneAssessment, analysis.sceneAssessment)
        XCTAssertEqual(decoded.sceneAssessment?.requestedIntent, .highKey)

        var legacyAnalysisObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis)) as? [String: Any])
        legacyAnalysisObject.removeValue(forKey: "sceneAssessment")
        let legacyAnalysis = try JSONDecoder().decode(PhotoAnalysis.self,
            from: JSONSerialization.data(withJSONObject: legacyAnalysisObject))
        XCTAssertNil(legacyAnalysis.sceneAssessment)

        let record = AutomaticAnalysisRecord(analysis: analysis, selectedProposal: "balanced",
                                             applied: try XCTUnwrap(analysis.proposals.first?.settings))
        XCTAssertEqual(record.sceneAssessment, analysis.sceneAssessment)
        let decodedRecord = try JSONDecoder().decode(AutomaticAnalysisRecord.self,
                                                     from: JSONEncoder().encode(record))
        XCTAssertEqual(decodedRecord, record)
        var legacyRecordObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        legacyRecordObject.removeValue(forKey: "sceneAssessment")
        let legacyRecord = try JSONDecoder().decode(AutomaticAnalysisRecord.self,
            from: JSONSerialization.data(withJSONObject: legacyRecordObject))
        XCTAssertNil(legacyRecord.sceneAssessment)
    }

    func testRecipeIntentRoundTripLegacyDefaultAndSupportedVersions() throws {
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        let reference = baseline
        let selected = AutomaticBatchRecipe(styleID: "balanced", baseline: baseline,
                                            referenceSettings: reference, sceneIntent: .night)
        XCTAssertEqual(try JSONDecoder().decode(AutomaticBatchRecipe.self,
            from: JSONEncoder().encode(selected)), selected)

        var oldAutomaticObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)) as? [String: Any])
        oldAutomaticObject.removeValue(forKey: "sceneIntent")
        let oldAutomatic = try JSONDecoder().decode(AutomaticBatchRecipe.self,
            from: JSONSerialization.data(withJSONObject: oldAutomaticObject))
        XCTAssertNil(oldAutomatic.sceneIntent, "Missing legacy intent means automatic scene selection.")

        // New recipes still default to v9; v11-v13 are only required when the
        // opt-in P1 color/liquify, P1-B certificate or P1-C make-up fields are used.
        let defaultRecipe = Recipe(automatic: selected)
        XCTAssertEqual(defaultRecipe.version, 9)
        for version in 1...13 {
            var recipe = Recipe(automatic: oldAutomatic)
            recipe.version = version
            XCTAssertEqual(try JSONDecoder().decode(Recipe.self,
                from: JSONEncoder().encode(recipe)).version, version)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneAdaptiveRecipeVersions-\(UUID().uuidString)", isDirectory: true)
        let input = root.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // v1-v21 are supported; 21 is the current version (P2-N eye & teeth refinement).
        for version in 1...25 {
            var recipe = Recipe()
            recipe.version = version
            XCTAssertNoThrow(try BatchProcessor().run(items: [], inputRoot: input,
                outputRoot: root.appendingPathComponent("version-\(version)"), recipe: recipe,
                lut: nil, cancellation: CancellationToken(), onEvent: { _ in }))
        }
        // Unknown future versions are rejected before the output directory is created.
        var unsupported = Recipe()
        unsupported.version = 27
        let rejectedOutput = root.appendingPathComponent("version-27")
        XCTAssertThrowsError(try BatchProcessor().run(items: [], inputRoot: input,
            outputRoot: rejectedOutput, recipe: unsupported, lut: nil,
            cancellation: CancellationToken(), onEvent: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedOutput.path))

        var silentlyDowngraded = Recipe(automatic: selected)
        silentlyDowngraded.version = 3
        XCTAssertThrowsError(try silentlyDowngraded.validateVersion())
        let downgradeOutput = root.appendingPathComponent("scene-intent-version-3")
        XCTAssertThrowsError(try BatchProcessor().run(items: [], inputRoot: input,
            outputRoot: downgradeOutput, recipe: silentlyDowngraded, lut: nil,
            cancellation: CancellationToken(), onEvent: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downgradeOutput.path))
    }

    func testBatchPassesSceneIntentIntoPerPhotoAnalysisAndKeepsLegacyAutomaticDefault() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneAdaptiveTests-\(UUID().uuidString)", isDirectory: true)
        let input = root.appendingPathComponent("input", isDirectory: true)
        let explicitOutput = root.appendingPathComponent("explicit", isDirectory: true)
        let legacyOutput = root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var export = ExportSettings()
        export.format = .png
        let photoURL = input.appendingPathComponent("high-key.png")
        try PhotoExporter.write(image: solidImage(r: 0.82, g: 0.82, b: 0.82), to: photoURL,
                                settings: export, sourceProperties: [:], context: engine.context)
        let items = try PhotoLoader.scan(folder: input, recursive: false)
        var baseline = AdjustmentSettings()
        baseline.autoExposure = false
        let explicit = AutomaticBatchRecipe(styleID: "balanced", baseline: baseline,
                                            referenceSettings: baseline, sceneIntent: .night)

        let explicitSummary = try BatchProcessor().run(items: items, inputRoot: input,
            outputRoot: explicitOutput, recipe: Recipe(automatic: explicit), lut: nil,
            cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(explicitSummary.succeeded, 1)
        let explicitIntent = try batchRequestedIntent(manifestURL: XCTUnwrap(explicitSummary.manifestURL))
        XCTAssertEqual(explicitIntent, PhotoSceneIntent.night.rawValue)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(explicit)) as? [String: Any])
        legacyObject.removeValue(forKey: "sceneIntent")
        let legacyAutomatic = try JSONDecoder().decode(AutomaticBatchRecipe.self,
            from: JSONSerialization.data(withJSONObject: legacyObject))
        let legacySummary = try BatchProcessor().run(items: items, inputRoot: input,
            outputRoot: legacyOutput, recipe: Recipe(automatic: legacyAutomatic), lut: nil,
            cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(legacySummary.succeeded, 1)
        let legacyIntent = try batchRequestedIntent(manifestURL: XCTUnwrap(legacySummary.manifestURL))
        XCTAssertEqual(legacyIntent, PhotoSceneIntent.automatic.rawValue)
    }

    private func assess(metrics metricsValue: PhotoAnalysisMetrics? = nil,
                        colors colorsValue: ColorSceneProfile? = nil,
                        labels: [PhotoContentLabel] = [],
                        subject: PhotoSubjectMeasurement? = nil,
                        intent: PhotoSceneIntent = .automatic,
                        iso: Double? = nil) -> PhotoSceneAssessment {
        SceneAdaptivePlanner.assess(metrics: metricsValue ?? metrics(),
                                    colors: colorsValue ?? colors(), labels: labels,
                                    subject: subject, intent: intent, iso: iso)
    }

    private func metrics(median: Double = 0.18, p05: Double = 0.12,
                         p95: Double = 0.30, p99: Double = 0.35,
                         nearBlack: Double = 0, nearWhite: Double = 0,
                         dynamicRange: Double = 1.3,
                         meanSaturation: Double = 0.1) -> PhotoAnalysisMetrics {
        PhotoAnalysisMetrics(sampleWidth: 64, sampleHeight: 64, sampleCount: 4096,
            medianLuminance: median, p05Luminance: p05, p95Luminance: p95,
            p99Luminance: p99, nearBlackFraction: nearBlack, nearWhiteFraction: nearWhite,
            overDisplayWhiteFraction: 0, dynamicRangeStops: dynamicRange,
            medianExposureFrom18PercentGrayEV: log2(max(median, 0.0001) / 0.18),
            meanRed: median, meanGreen: median, meanBlue: median,
            neutralMeanRed: nil, neutralMeanGreen: nil, neutralMeanBlue: nil,
            neutralWarmCast: nil, neutralGreenCast: nil, neutralSampleCount: 0,
            neutralSampleFraction: 0, meanSaturation: meanSaturation,
            histogram: Array(repeating: 1.0 / 64.0, count: 64), faceCount: 0,
            analysisConfidence: 0.8)
    }

    private func colors(warm: Double = 0, cool: Double = 0, neutral: Double = 1,
                        saturated: Double = 0, dark: Double = 0, bright: Double = 0,
                        diversity: Double = 0) -> ColorSceneProfile {
        ColorSceneProfile(sampleCount: 4096, warmFraction: warm, coolFraction: cool,
                          neutralFraction: neutral, saturatedFraction: saturated,
                          darkFraction: dark, brightFraction: bright,
                          colorDiversity: diversity, summary: "test fixture", regions: [])
    }

    private func solidImage(r: Float, g: Float, b: Float,
                            width: Int = 64, height: Int = 64) -> CIImage {
        pixelImage(width: width, height: height) { _, _ in (r, g, b, 1) }
    }

    private func verticalHalves(lower: Float, upper: Float,
                                width: Int, height: Int) -> CIImage {
        func color(_ value: Float) -> CIColor {
            CIColor(red: CGFloat(value), green: CGFloat(value), blue: CGFloat(value),
                    alpha: 1, colorSpace: linearColorSpace)!
        }
        let midpoint = CGFloat(height) / 2
        let lowerImage = CIImage(color: color(lower)).cropped(
            to: CGRect(x: 0, y: 0, width: CGFloat(width), height: midpoint))
        let upperImage = CIImage(color: color(upper)).cropped(
            to: CGRect(x: 0, y: midpoint, width: CGFloat(width), height: midpoint))
        return upperImage.composited(over: lowerImage)
            .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    }

    private func pixelImage(width: Int, height: Int,
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
        return CIImage(bitmapData: data, bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                       size: CGSize(width: width, height: height), format: .RGBAf,
                       colorSpace: linearColorSpace)
    }

    private func render(_ image: CIImage) throws -> [Float] {
        let bounds = image.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { throw TestImageError.emptyExtent }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            renderContext.render(image, toBitmap: buffer.baseAddress!,
                                 rowBytes: width * 4 * MemoryLayout<Float>.stride,
                                 bounds: bounds, format: .RGBAf, colorSpace: linearColorSpace)
        }
        return pixels
    }

    private func independentMedian(_ image: CIImage, inside region: CGRect) throws -> Double? {
        let bounds = image.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { throw TestImageError.emptyExtent }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            renderContext.render(image, toBitmap: buffer.baseAddress!,
                                 rowBytes: width * 4 * MemoryLayout<Float>.stride,
                                 bounds: bounds, format: .RGBAf, colorSpace: linearColorSpace)
        }
        let extent = image.extent
        var samples: [(luminance: Double, weight: Double)] = []
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                let alpha = Double(pixels[offset + 3])
                guard alpha > 0.001 else { continue }
                let normalizedX = (Double(bounds.minX) + Double(column) + 0.5 - Double(extent.minX))
                    / Double(extent.width)
                let normalizedY = (Double(bounds.maxY) - Double(row) - 0.5 - Double(extent.minY))
                    / Double(extent.height)
                guard region.contains(CGPoint(x: normalizedX, y: normalizedY)) else { continue }
                let luminance = 0.2126 * Double(pixels[offset])
                    + 0.7152 * Double(pixels[offset + 1])
                    + 0.0722 * Double(pixels[offset + 2])
                samples.append((luminance, min(1, alpha)))
            }
        }
        let sorted = samples.sorted { $0.luminance < $1.luminance }
        let totalWeight = sorted.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }
        var accumulated = 0.0
        for sample in sorted {
            accumulated += sample.weight
            if accumulated >= totalWeight * 0.5 { return sample.luminance }
        }
        return sorted.last?.luminance
    }

    private func assertPixelsEqual(_ lhs: [Float], _ rhs: [Float], accuracy: Float,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
        guard lhs.count == rhs.count else { return }
        for index in lhs.indices {
            XCTAssertEqual(lhs[index], rhs[index], accuracy: accuracy,
                           "Pixel component at offset \(index)", file: file, line: line)
        }
    }

    private func assertAchromatic(_ pixels: [Float],
                                  file: StaticString = #filePath, line: UInt = #line) {
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[offset + 3] > 0.001 else { continue }
            XCTAssertEqual(pixels[offset], pixels[offset + 1], accuracy: 0.0001,
                           "Red/green diverged at pixel offset \(offset)", file: file, line: line)
            XCTAssertEqual(pixels[offset + 1], pixels[offset + 2], accuracy: 0.0001,
                           "Green/blue diverged at pixel offset \(offset)", file: file, line: line)
        }
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

    private func meanSaturation(_ pixels: [Float]) -> Double {
        var saturationSum = 0.0
        var count = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[offset + 3] > 0.001 else { continue }
            let red = Double(pixels[offset]), green = Double(pixels[offset + 1]), blue = Double(pixels[offset + 2])
            let maximum = max(red, max(green, blue))
            let minimum = min(red, min(green, blue))
            saturationSum += maximum > 0.0001 ? max(0, (maximum - minimum) / maximum) : 0
            count += 1
        }
        return count > 0 ? saturationSum / count : 0
    }

    private func batchRequestedIntent(manifestURL: URL) throws -> String {
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first)
        let report = try XCTUnwrap(entry["report"] as? [String: Any])
        let record = try XCTUnwrap(report["analysis"] as? [String: Any])
        let assessment = try XCTUnwrap(record["sceneAssessment"] as? [String: Any])
        return try XCTUnwrap(assessment["requestedIntent"] as? String)
    }

    private enum TestImageError: Error { case emptyExtent }
}

import XCTest
import CoreImage
@testable import PhotoCore

final class BodySkinRefinementTests: XCTestCase {

    private var context: CIContext!

    override func setUp() {
        super.setUp()
        context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
    }

    override func tearDown() {
        context = nil
        super.tearDown()
    }

    func testBodySkinSettingsDefaultsAndValidation() throws {
        var settings = BodySkinRefinementSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.neckSmoothing, 0)
        XCTAssertEqual(settings.bodySmoothing, 0)
        XCTAssertEqual(settings.veinReduction, 0)
        XCTAssertEqual(settings.bodyToneHarmonization, 0)
        XCTAssertEqual(settings.texturePreservation, 0.7, accuracy: 0.001)
        XCTAssertTrue(settings.isNeutral)

        settings.enabled = true
        XCTAssertTrue(settings.isNeutral, "Still neutral if all smoothing/vein/tone strengths are 0")

        settings.neckSmoothing = 0.5
        XCTAssertFalse(settings.isNeutral)

        let validated = try settings.validated()
        XCTAssertEqual(validated.neckSmoothing, 0.5)

        var bad = settings
        bad.neckSmoothing = 1.2
        XCTAssertThrowsError(try bad.validated())

        bad = settings
        bad.bodySmoothing = -0.1
        XCTAssertThrowsError(try bad.validated())

        bad = settings
        bad.veinReduction = .nan
        XCTAssertThrowsError(try bad.validated())

        bad = settings
        bad.bodyToneHarmonization = 2.0
        XCTAssertThrowsError(try bad.validated())

        bad = settings
        bad.texturePreservation = -0.5
        XCTAssertThrowsError(try bad.validated())
    }

    func testRecipeVersion16Gating() throws {
        var neutral = AdjustmentSettings()
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: neutral, automatic: nil), 9)

        neutral.bodySkin = BodySkinRefinementSettings(enabled: false, neckSmoothing: 0.5)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: neutral, automatic: nil), 9)

        var active = AdjustmentSettings()
        active.bodySkin = BodySkinRefinementSettings(enabled: true, neckSmoothing: 0.5)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: active, automatic: nil), 16)

        var v15Recipe = Recipe(adjustments: active)
        v15Recipe.version = 15
        XCTAssertThrowsError(try v15Recipe.validateVersion()) { error in
            guard case AtelierError.invalidConfiguration(let msg) = error else {
                XCTFail("Expected invalidConfiguration but got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("版本 16"))
        }

        var v16Recipe = Recipe(adjustments: active)
        v16Recipe.version = 16
        XCTAssertNoThrow(try v16Recipe.validateVersion())
    }

    func testLegacyRecipeRoundTrip() throws {
        // A recipe without bodySkin decodes cleanly with bodySkin == nil
        let baseRecipe = Recipe()
        let encoder = JSONEncoder()
        let data = try encoder.encode(baseRecipe)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Recipe.self, from: data)
        XCTAssertNil(decoded.adjustments.bodySkin)

        // With bodySkin present
        var custom = Recipe()
        custom.version = 16
        custom.adjustments.bodySkin = BodySkinRefinementSettings(
            enabled: true,
            neckSmoothing: 0.65,
            bodySmoothing: 0.50,
            veinReduction: 0.40,
            bodyToneHarmonization: 0.35,
            texturePreservation: 0.80
        )
        let customData = try encoder.encode(custom)
        let decodedCustom = try decoder.decode(Recipe.self, from: customData)
        XCTAssertEqual(decodedCustom.adjustments.bodySkin, custom.adjustments.bodySkin)
        XCTAssertEqual(decodedCustom.version, 16)
    }

    func testNeutralSettingsLeavePixelsCompletelyUnchanged() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let testImage = CIImage(color: CIColor(red: 0.6, green: 0.4, blue: 0.3)).cropped(to: extent)

        let neutralSettings = BodySkinRefinementSettings(enabled: false, neckSmoothing: 0.5)
        let result = try BodySkinRefinementEngine.apply(
            testImage,
            settings: neutralSettings,
            personMatte: nil,
            faceLandmarks: nil,
            context: context
        )

        XCTAssertFalse(result.report.applied)
        XCTAssertTrue(result.image === testImage)
    }

    func testBodySkinSmoothsRoughnessOnExposedBody() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        let matteImage = CIImage(color: .white).cropped(to: extent)
        let personMatte = PersonMatte(mask: matteImage, coverage: 1.0, confidence: 1.0, hasPerson: true, settings: PersonMatteSettings())

        // Create warm skin tone with roughness ripple in body region (lower 60% of canvas)
        let skinWithBlemishes = createRGBImage(width: width, height: height) { x, y in
            let ripple = sin(Double(y) * 0.5) * 0.12
            // Warm skin tone (R > G > B)
            let r = 0.65 + ripple
            let g = 0.45 + ripple * 0.8
            let b = 0.35 + ripple * 0.6
            return (r: r, g: g, b: b)
        }

        let settings = BodySkinRefinementSettings(
            enabled: true,
            bodySmoothing: 0.85,
            texturePreservation: 0.20
        )

        let result = try BodySkinRefinementEngine.apply(
            skinWithBlemishes,
            settings: settings,
            personMatte: personMatte,
            faceLandmarks: [],
            context: context
        )

        XCTAssertTrue(result.report.applied)
        XCTAssertTrue(result.report.appliedSteps.contains(where: { $0.contains("bodySmoothing") }))

        let testRect = CGRect(x: 20, y: 20, width: 80, height: 40)
        let contrastBefore = measureVerticalContrast(image: skinWithBlemishes, rect: testRect)
        let contrastAfter = measureVerticalContrast(image: result.image, rect: testRect)

        XCTAssertLessThan(contrastAfter, contrastBefore * 0.80,
                          "Body smoothing must reduce skin ripple contrast (before=\(contrastBefore), after=\(contrastAfter))")
    }

    func testNeckCreaseSmoothingInNeckCorridor() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        let matteImage = CIImage(color: .white).cropped(to: extent)
        let personMatte = PersonMatte(mask: matteImage, coverage: 1.0, confidence: 1.0, hasPerson: true, settings: PersonMatteSettings())

        // Place face in upper canvas (y: 80...110)
        let faceBox = CGRect(x: 0.35, y: 0.65, width: 0.30, height: 0.25)
        let faceLandmarks = FaceLandmarkSet(boundingBox: faceBox, confidence: 0.99)

        // Place a horizontal neck crease shadow in neck corridor (y: 60...75)
        let neckCreaseImage = createRGBImage(width: width, height: height) { x, y in
            let isCrease = (y >= 65 && y <= 72)
            let dip = isCrease ? 0.20 : 0.0
            let r = 0.70 - dip
            let g = 0.50 - dip * 0.9
            let b = 0.40 - dip * 0.8
            return (r: r, g: g, b: b)
        }

        let settings = BodySkinRefinementSettings(
            enabled: true,
            neckSmoothing: 0.90,
            texturePreservation: 0.20
        )

        let result = try BodySkinRefinementEngine.apply(
            neckCreaseImage,
            settings: settings,
            personMatte: personMatte,
            faceLandmarks: [faceLandmarks],
            context: context
        )

        XCTAssertTrue(result.report.applied)
        XCTAssertTrue(result.report.appliedSteps.contains(where: { $0.contains("neckSmoothing") }))

        // Measure crease contrast in neck area
        let neckRect = CGRect(x: 52, y: 62, width: 24, height: 16)
        let contrastBefore = measureVerticalContrast(image: neckCreaseImage, rect: neckRect)
        let contrastAfter = measureVerticalContrast(image: result.image, rect: neckRect)

        XCTAssertLessThan(contrastAfter, contrastBefore * 0.85,
                          "Neck smoothing must soften crease shadow (before=\(contrastBefore), after=\(contrastAfter))")
    }

    func testVeinReductionAttenuatesCoolTonedVeins() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        let matteImage = CIImage(color: .white).cropped(to: extent)
        let personMatte = PersonMatte(mask: matteImage, coverage: 1.0, confidence: 1.0, hasPerson: true, settings: PersonMatteSettings())

        // Create warm skin with a cool blue/green vein strip at x: 60...68
        let veinImage = createRGBImage(width: width, height: height) { x, y in
            let isVein = (x >= 60 && x <= 68)
            if isVein {
                // Cool dark blue-green vein
                return (r: 0.45, g: 0.48, b: 0.52)
            } else {
                // Normal warm skin
                return (r: 0.70, g: 0.52, b: 0.42)
            }
        }

        let settings = BodySkinRefinementSettings(
            enabled: true,
            veinReduction: 0.90,
            texturePreservation: 0.20
        )

        let result = try BodySkinRefinementEngine.apply(
            veinImage,
            settings: settings,
            personMatte: personMatte,
            faceLandmarks: [],
            context: context
        )

        XCTAssertTrue(result.report.applied)
        XCTAssertTrue(result.report.appliedSteps.contains(where: { $0.contains("veinReduction") }))

        // Read pixel at center of vein before and after
        var pixelBefore = [UInt8](repeating: 0, count: 4)
        context.render(veinImage, toBitmap: &pixelBefore, rowBytes: 4, bounds: CGRect(x: 64, y: 40, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)

        var pixelAfter = [UInt8](repeating: 0, count: 4)
        context.render(result.image, toBitmap: &pixelAfter, rowBytes: 4, bounds: CGRect(x: 64, y: 40, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)

        let redGain = Int(pixelAfter[0]) - Int(pixelBefore[0])
        let blueLoss = Int(pixelBefore[2]) - Int(pixelAfter[2])

        XCTAssertGreaterThan(redGain, 5, "Vein reduction must restore skin warmth (Red channel)")
        XCTAssertGreaterThan(blueLoss, 5, "Vein reduction must suppress cool tone (Blue channel)")
    }

    func testFaceRegionStrictlyProtected() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        let matteImage = CIImage(color: .white).cropped(to: extent)
        let personMatte = PersonMatte(mask: matteImage, coverage: 1.0, confidence: 1.0, hasPerson: true, settings: PersonMatteSettings())

        let faceBox = CGRect(x: 0.35, y: 0.60, width: 0.30, height: 0.30)
        let faceLandmarks = FaceLandmarkSet(boundingBox: faceBox, confidence: 0.99)

        let testImage = createRGBImage(width: width, height: height) { x, y in
            let ripple = sin(Double(y) * 0.5) * 0.15
            return (r: 0.65 + ripple, g: 0.45 + ripple, b: 0.35 + ripple)
        }

        let settings = BodySkinRefinementSettings(
            enabled: true,
            neckSmoothing: 0.80,
            bodySmoothing: 0.80,
            veinReduction: 0.80,
            bodyToneHarmonization: 0.80,
            texturePreservation: 0.10
        )

        let result = try BodySkinRefinementEngine.apply(
            testImage,
            settings: settings,
            personMatte: personMatte,
            faceLandmarks: [faceLandmarks],
            context: context
        )

        XCTAssertTrue(result.report.applied)

        // Face region contrast must be intact
        let faceRect = CGRect(x: 45, y: 80, width: 38, height: 35)
        let faceContrastBefore = measureVerticalContrast(image: testImage, rect: faceRect)
        let faceContrastAfter = measureVerticalContrast(image: result.image, rect: faceRect)

        XCTAssertEqual(faceContrastBefore, faceContrastAfter, accuracy: 0.02,
                       "Face region must be protected from body skin smoothing")
    }

    func testBodyToneHarmonization() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        let matteImage = CIImage(color: .white).cropped(to: extent)
        let personMatte = PersonMatte(mask: matteImage, coverage: 1.0, confidence: 1.0, hasPerson: true, settings: PersonMatteSettings())

        let faceBox = CGRect(x: 0.35, y: 0.60, width: 0.30, height: 0.30)
        let faceLandmarks = FaceLandmarkSet(boundingBox: faceBox, confidence: 0.99)

        // Face is rosy fair skin (R: 0.85, G: 0.70, B: 0.65), body is dull yellowish skin (R: 0.65, G: 0.60, B: 0.40)
        let testImage = createRGBImage(width: width, height: height) { x, y in
            let inFace = (x >= 45 && x <= 80) && (y >= 75 && y <= 115)
            if inFace {
                return (r: 0.85, g: 0.70, b: 0.65)
            } else {
                return (r: 0.65, g: 0.60, b: 0.40)
            }
        }

        let settings = BodySkinRefinementSettings(
            enabled: true,
            bodyToneHarmonization: 0.80
        )

        let result = try BodySkinRefinementEngine.apply(
            testImage,
            settings: settings,
            personMatte: personMatte,
            faceLandmarks: [faceLandmarks],
            context: context
        )

        XCTAssertTrue(result.report.applied)
        XCTAssertTrue(result.report.appliedSteps.contains(where: { $0.contains("bodyToneHarmonization") }))

        // Check body pixel at (x: 40, y: 30) before and after
        var pixelBefore = [UInt8](repeating: 0, count: 4)
        context.render(testImage, toBitmap: &pixelBefore, rowBytes: 4, bounds: CGRect(x: 40, y: 30, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)

        var pixelAfter = [UInt8](repeating: 0, count: 4)
        context.render(result.image, toBitmap: &pixelAfter, rowBytes: 4, bounds: CGRect(x: 40, y: 30, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)

        // The body skin should have shifted towards rosy face tone (higher Blue relative to Green)
        let bgRatioBefore = Double(pixelBefore[2]) / max(1.0, Double(pixelBefore[1]))
        let bgRatioAfter = Double(pixelAfter[2]) / max(1.0, Double(pixelAfter[1]))

        XCTAssertGreaterThan(bgRatioAfter, bgRatioBefore, "Body tone harmonization must shift body chromaticity towards face anchor")
    }

    func testGracefulSkipWhenNoPersonDetected() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let testImage = CIImage(color: .blue).cropped(to: extent)
        let emptyMask = CIImage(color: .black).cropped(to: extent)
        let noPersonMatte = PersonMatte(mask: emptyMask, coverage: 0.0, confidence: 0.0, hasPerson: false, settings: PersonMatteSettings())

        let settings = BodySkinRefinementSettings(enabled: true, bodySmoothing: 0.5)
        let result = try BodySkinRefinementEngine.apply(
            testImage,
            settings: settings,
            personMatte: noPersonMatte,
            faceLandmarks: nil,
            context: context
        )

        XCTAssertFalse(result.report.applied)
        XCTAssertTrue(result.report.note?.contains("未检测到人物") == true)
    }

    // MARK: - Helpers

    private func createRGBImage(width: Int, height: Int, formula: (Int, Int) -> (r: Double, g: Double, b: Double)) -> CIImage {
        var pixelBytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = formula(x, y)
                let offset = (y * width + x) * 4
                pixelBytes[offset] = UInt8(max(0, min(1, r)) * 255.0)
                pixelBytes[offset + 1] = UInt8(max(0, min(1, g)) * 255.0)
                pixelBytes[offset + 2] = UInt8(max(0, min(1, b)) * 255.0)
                pixelBytes[offset + 3] = 255
            }
        }
        let data = Data(pixelBytes)
        return CIImage(bitmapData: data, bytesPerRow: width * 4,
                       size: CGSize(width: width, height: height),
                       format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    private func measureVerticalContrast(image: CIImage, rect: CGRect) -> Double {
        let w = Int(rect.width)
        let h = Int(rect.height)
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &buffer, rowBytes: w * 4,
                       bounds: rect, format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)

        var diffs: [Double] = []
        for y in 0..<(h - 1) {
            for x in 0..<w {
                let idx1 = (y * w + x) * 4
                let idx2 = ((y + 1) * w + x) * 4
                let luma1 = Double(buffer[idx1]) * 0.2126 + Double(buffer[idx1 + 1]) * 0.7152 + Double(buffer[idx1 + 2]) * 0.0722
                let luma2 = Double(buffer[idx2]) * 0.2126 + Double(buffer[idx2 + 1]) * 0.7152 + Double(buffer[idx2 + 2]) * 0.0722
                diffs.append(abs(luma1 - luma2) / 255.0)
            }
        }
        guard !diffs.isEmpty else { return 0 }
        return diffs.reduce(0, +) / Double(diffs.count)
    }
}

import XCTest
import CoreImage
@testable import PhotoCore

final class ClothingRefinementTests: XCTestCase {

    private var context: CIContext!

    override func setUp() {
        super.setUp()
        context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
    }

    override func tearDown() {
        context = nil
        super.tearDown()
    }

    func testClothingSettingsDefaultsAndValidation() throws {
        var settings = ClothingRefinementSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.wrinkleSmoothing, 0)
        XCTAssertEqual(settings.creaseRemoval, 0)
        XCTAssertEqual(settings.texturePreservation, 0.7, accuracy: 0.001)
        XCTAssertTrue(settings.isNeutral)

        settings.enabled = true
        XCTAssertTrue(settings.isNeutral, "Still neutral if smoothing and crease removal are 0")

        settings.wrinkleSmoothing = 0.5
        XCTAssertFalse(settings.isNeutral)

        let validated = try settings.validated()
        XCTAssertEqual(validated.wrinkleSmoothing, 0.5)

        var bad = settings
        bad.wrinkleSmoothing = 1.5
        XCTAssertThrowsError(try bad.validated())

        bad = settings
        bad.creaseRemoval = -0.1
        XCTAssertThrowsError(try bad.validated())

        bad = settings
        bad.texturePreservation = .nan
        XCTAssertThrowsError(try bad.validated())
    }

    func testRecipeVersion15Gating() throws {
        var neutral = AdjustmentSettings()
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: neutral, automatic: nil), 9)

        neutral.clothing = ClothingRefinementSettings(enabled: false, wrinkleSmoothing: 0.5)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: neutral, automatic: nil), 9)

        var active = AdjustmentSettings()
        active.clothing = ClothingRefinementSettings(enabled: true, wrinkleSmoothing: 0.5)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: active, automatic: nil), 15)

        var v14Recipe = Recipe(adjustments: active)
        v14Recipe.version = 14
        XCTAssertThrowsError(try v14Recipe.validateVersion()) { error in
            guard case AtelierError.invalidConfiguration(let msg) = error else {
                XCTFail("Expected invalidConfiguration but got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("版本 15"))
        }

        var v15Recipe = Recipe(adjustments: active)
        v15Recipe.version = 15
        XCTAssertNoThrow(try v15Recipe.validateVersion())
    }

    func testLegacyRecipeRoundTrip() throws {
        // A recipe without clothing field decodes cleanly with clothing == nil
        let baseRecipe = Recipe()
        let encoder = JSONEncoder()
        let data = try encoder.encode(baseRecipe)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Recipe.self, from: data)
        XCTAssertNil(decoded.adjustments.clothing)

        // With clothing present
        var custom = Recipe()
        custom.version = 15
        custom.adjustments.clothing = ClothingRefinementSettings(
            enabled: true,
            wrinkleSmoothing: 0.75,
            creaseRemoval: 0.60,
            texturePreservation: 0.80
        )
        let customData = try encoder.encode(custom)
        let decodedCustom = try decoder.decode(Recipe.self, from: customData)
        XCTAssertEqual(decodedCustom.adjustments.clothing, custom.adjustments.clothing)
        XCTAssertEqual(decodedCustom.version, 15)
    }

    func testNeutralSettingsLeavePixelsCompletelyUnchanged() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let testImage = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8)).cropped(to: extent)

        let neutralSettings = ClothingRefinementSettings(enabled: false, wrinkleSmoothing: 0.5)
        let result = try ClothingRefinementEngine.apply(
            testImage,
            settings: neutralSettings,
            personMatte: nil,
            faceLandmarks: nil,
            context: context
        )

        XCTAssertFalse(result.report.applied)
        XCTAssertTrue(result.image === testImage)
    }

    func testClothingRefinementSmoothsWrinklesOnPerson() throws {
        let width = 128
        let height = 128

        // 1. Create person matte: 1.0 in lower 70% of canvas, 0.0 in upper 30%
        let matteImage = createGradientImage(width: width, height: height) { x, y in
            y < 90 ? 1.0 : 0.0
        }
        let personMatte = PersonMatte(mask: matteImage, coverage: 0.7, confidence: 1.0, hasPerson: true, settings: PersonMatteSettings())

        // 2. Create clothing base color (dark blue shirt) with high-frequency wrinkles
        let wrinkledShirt = createRGBImage(width: width, height: height) { x, y in
            // High frequency crease pattern (sinusoidal luminance ripple)
            let wrinkle = sin(Double(y) * 0.45) * 0.15
            let r = 0.20 + wrinkle
            let g = 0.25 + wrinkle
            let b = 0.60 + wrinkle
            return (r: r, g: g, b: b)
        }

        let settings = ClothingRefinementSettings(
            enabled: true,
            wrinkleSmoothing: 0.85,
            creaseRemoval: 0.80,
            texturePreservation: 0.20
        )

        let result = try ClothingRefinementEngine.apply(
            wrinkledShirt,
            settings: settings,
            personMatte: personMatte,
            faceLandmarks: [],
            context: context
        )

        XCTAssertTrue(result.report.applied)
        XCTAssertTrue(result.report.appliedSteps.contains("wrinkleSmoothing"))

        // Measure variance / contrast before and after in clothing area (y: 20...60, x: 20...100)
        let contrastBefore = measureVerticalContrast(image: wrinkledShirt, rect: CGRect(x: 20, y: 20, width: 80, height: 40))
        let contrastAfter = measureVerticalContrast(image: result.image, rect: CGRect(x: 20, y: 20, width: 80, height: 40))

        XCTAssertLessThan(contrastAfter, contrastBefore * 0.65,
                          "Clothing refinement must significantly smooth out fabric wrinkle contrast (before=\(contrastBefore), after=\(contrastAfter))")
    }

    func testHeadAndFaceAreProtectedFromClothingSmoothing() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        let matteImage = CIImage(color: .white).cropped(to: extent)
        let personMatte = PersonMatte(mask: matteImage, coverage: 1.0, confidence: 1.0, hasPerson: true, settings: PersonMatteSettings())

        // Face in upper portion of image
        let faceBox = CGRect(x: 0.35, y: 0.60, width: 0.30, height: 0.30)
        let faceLandmarks = FaceLandmarkSet(boundingBox: faceBox, confidence: 0.99)

        // Create test image with distinct pattern in face region and clothing region
        let testImage = createRGBImage(width: width, height: height) { x, y in
            let ripple = sin(Double(y) * 0.5) * 0.20
            return (r: 0.5 + ripple, g: 0.5 + ripple, b: 0.5 + ripple)
        }

        let settings = ClothingRefinementSettings(
            enabled: true,
            wrinkleSmoothing: 0.90,
            creaseRemoval: 0.90,
            texturePreservation: 0.10
        )

        let result = try ClothingRefinementEngine.apply(
            testImage,
            settings: settings,
            personMatte: personMatte,
            faceLandmarks: [faceLandmarks],
            context: context
        )

        XCTAssertTrue(result.report.applied)

        // Face region contrast should be preserved (protected by head exclusion mask)
        let faceRect = CGRect(x: 45, y: 80, width: 38, height: 35)
        let faceContrastBefore = measureVerticalContrast(image: testImage, rect: faceRect)
        let faceContrastAfter = measureVerticalContrast(image: result.image, rect: faceRect)

        XCTAssertEqual(faceContrastBefore, faceContrastAfter, accuracy: 0.025,
                       "Face region must be protected from clothing wrinkle smoothing")
    }

    func testGracefulSkipWhenNoPersonDetected() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let testImage = CIImage(color: .blue).cropped(to: extent)
        let emptyMask = CIImage(color: .black).cropped(to: extent)
        let noPersonMatte = PersonMatte(mask: emptyMask, coverage: 0.0, confidence: 0.0, hasPerson: false, settings: PersonMatteSettings())

        let settings = ClothingRefinementSettings(enabled: true, wrinkleSmoothing: 0.5)
        let result = try ClothingRefinementEngine.apply(
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

    private func createGradientImage(width: Int, height: Int, formula: (Int, Int) -> Double) -> CIImage {
        var pixelBytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let val = max(0.0, min(1.0, formula(x, y)))
                pixelBytes[y * width + x] = UInt8(val * 255.0)
            }
        }
        let data = Data(pixelBytes)
        return CIImage(bitmapData: data, bytesPerRow: width,
                       size: CGSize(width: width, height: height),
                       format: .L8,
                       colorSpace: CGColorSpaceCreateDeviceGray())
    }

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

import XCTest
import CoreImage
@testable import PhotoCore

final class HairColorTests: XCTestCase {

    // Helper: create a 512x512 synthetic test image with hair base color (dark brunette)
    private func makeTestImage() -> CIImage {
        // Base dark hair color (0.12, 0.10, 0.08)
        let color = CIColor(red: 0.12, green: 0.10, blue: 0.08, alpha: 1.0)
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))
    }

    // Helper: create a mock face with usable geometry
    private func makeMockFace() -> FaceLandmarkSet {
        let contour = [
            CGPoint(x: 0.25, y: 0.25),
            CGPoint(x: 0.50, y: 0.15),
            CGPoint(x: 0.75, y: 0.25)
        ]
        return FaceLandmarkSet(
            boundingBox: CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.50),
            faceContour: contour
        )
    }

    // MARK: - 1. Neutrality & Default Values

    func testNeutralityAndDefaults() {
        let def = HairColorSettings()
        XCTAssertFalse(def.enabled)
        XCTAssertEqual(def.grayHairRemoval, 0)
        XCTAssertEqual(def.hairHarmonization, 0)
        XCTAssertEqual(def.hairTone, .original)
        XCTAssertEqual(def.hairToneStrength, 0)
        XCTAssertEqual(def.hairLuminanceAdjust, 0)
        XCTAssertTrue(def.isNeutral)

        // Setting values while disabled remains neutral
        let disabledWithVals = HairColorSettings(
            enabled: false,
            grayHairRemoval: 0.8,
            hairHarmonization: 0.5,
            hairTone: .chestnutBrown,
            hairToneStrength: 0.6
        )
        XCTAssertTrue(disabledWithVals.isNeutral)

        // Enabled with all zeros is neutral
        let enabledZero = HairColorSettings(enabled: true)
        XCTAssertTrue(enabledZero.isNeutral)

        // Enabled with active gray hair removal is not neutral
        let activeGray = HairColorSettings(enabled: true, grayHairRemoval: 0.5)
        XCTAssertFalse(activeGray.isNeutral)

        // Enabled with active harmonization is not neutral
        let activeHarm = HairColorSettings(enabled: true, hairHarmonization: 0.5)
        XCTAssertFalse(activeHarm.isNeutral)

        // Enabled with active salon tone is not neutral
        let activeTone = HairColorSettings(enabled: true, hairTone: .naturalBlack, hairToneStrength: 0.5)
        XCTAssertFalse(activeTone.isNeutral)

        // Enabled with tone but zero strength is neutral
        let toneZeroStrength = HairColorSettings(enabled: true, hairTone: .burgundyRed, hairToneStrength: 0.0)
        XCTAssertTrue(toneZeroStrength.isNeutral)
    }

    // MARK: - 2. Validation Bounds

    func testValidationBounds() {
        // Default valid
        XCTAssertNoThrow(try HairColorSettings().validated())

        // Clamping on constructor
        let clamped = HairColorSettings(
            enabled: true,
            grayHairRemoval: 1.5,
            hairHarmonization: -0.5,
            hairTone: .mochaDark,
            hairToneStrength: 2.0,
            hairLuminanceAdjust: 0.8
        )
        XCTAssertEqual(clamped.grayHairRemoval, 1.0)
        XCTAssertEqual(clamped.hairHarmonization, 0.0)
        XCTAssertEqual(clamped.hairToneStrength, 1.0)
        XCTAssertEqual(clamped.hairLuminanceAdjust, 0.5)
        XCTAssertNoThrow(try clamped.validated())
    }

    // MARK: - 3. Gray Hair Removal

    func testGrayHairRemovalDarkensSilverHair() {
        // Create an image that is bright silver in the crown hair area
        let silverColor = CIColor(red: 0.70, green: 0.70, blue: 0.70, alpha: 1.0)
        let silverImage = CIImage(color: silverColor).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))

        let face = makeMockFace()
        let settings = HairColorSettings(
            enabled: true,
            grayHairRemoval: 0.85
        )

        let result = HairColorEngine.apply(to: silverImage, faces: [face], settings: settings)
        XCTAssertTrue(result.report.applied)
        XCTAssertTrue(result.report.grayHairApplied)
        XCTAssertEqual(result.report.faceCount, 1)

        // Sample a pixel in the hair crown area (midX = 256, crownMidY ~ 256 + 256 * 0.40 ~ 360)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var originalPixel = [UInt8](repeating: 0, count: 4)
        var modifiedPixel = [UInt8](repeating: 0, count: 4)

        context.render(silverImage, toBitmap: &originalPixel, rowBytes: 4, bounds: CGRect(x: 256, y: 380, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        context.render(result.image, toBitmap: &modifiedPixel, rowBytes: 4, bounds: CGRect(x: 256, y: 380, width: 1, height: 1), format: .RGBA8, colorSpace: nil)

        // The silver pixel luminance should have been significantly reduced (darkened toward dark hair)
        XCTAssertLessThan(modifiedPixel[0], originalPixel[0])
        XCTAssertLessThan(modifiedPixel[1], originalPixel[1])
        XCTAssertLessThan(modifiedPixel[2], originalPixel[2])
    }

    // MARK: - 4. Hair Color Harmonization

    func testHairColorHarmonization() {
        // Create a brassy/yellow-orange mottled hair image (R=0.55, G=0.35, B=0.10)
        let brassyColor = CIColor(red: 0.55, green: 0.35, blue: 0.10, alpha: 1.0)
        let brassyImage = CIImage(color: brassyColor).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))

        let face = makeMockFace()
        let settings = HairColorSettings(
            enabled: true,
            hairHarmonization: 0.80
        )

        let result = HairColorEngine.apply(to: brassyImage, faces: [face], settings: settings)
        XCTAssertTrue(result.report.applied)
        XCTAssertTrue(result.report.harmonizationApplied)

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var originalPixel = [UInt8](repeating: 0, count: 4)
        var modifiedPixel = [UInt8](repeating: 0, count: 4)

        context.render(brassyImage, toBitmap: &originalPixel, rowBytes: 4, bounds: CGRect(x: 256, y: 380, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        context.render(result.image, toBitmap: &modifiedPixel, rowBytes: 4, bounds: CGRect(x: 256, y: 380, width: 1, height: 1), format: .RGBA8, colorSpace: nil)

        // Brassiness (Red minus Blue) should decrease as it harmonizes toward median hair
        let originalBrass = Int(originalPixel[0]) - Int(originalPixel[2])
        let modifiedBrass = Int(modifiedPixel[0]) - Int(modifiedPixel[2])
        XCTAssertLessThan(modifiedBrass, originalBrass)
    }

    // MARK: - 5. All Salon Hair Tones Apply

    func testAllSalonHairTonesApply() {
        let baseImage = makeTestImage()
        let face = makeMockFace()

        for tone in HairTone.allCases where tone != .original {
            let settings = HairColorSettings(
                enabled: true,
                hairTone: tone,
                hairToneStrength: 0.75
            )
            let result = HairColorEngine.apply(to: baseImage, faces: [face], settings: settings)
            XCTAssertTrue(result.report.applied, "Tone \(tone.rawValue) should report applied")
            XCTAssertTrue(result.report.toneApplied)
            XCTAssertNotNil(result.image)
        }
    }

    // MARK: - 6. Neutral Skips Processing

    func testNeutralSkipsProcessing() {
        let baseImage = makeTestImage()
        let face = makeMockFace()
        let neutral = HairColorSettings()

        let result = HairColorEngine.apply(to: baseImage, faces: [face], settings: neutral)
        XCTAssertFalse(result.report.applied)
        XCTAssertEqual(result.image, baseImage)
    }

    // MARK: - 7. Recipe Version Gate

    func testRecipeVersionGate() throws {
        var recipe = Recipe()
        recipe.version = 24
        recipe.adjustments.hairColor = HairColorSettings(enabled: true, grayHairRemoval: 0.6)

        // Version 24 should fail with non-neutral hair color
        XCTAssertThrowsError(try recipe.validateVersion()) { error in
            guard case let AtelierError.invalidConfiguration(msg) = error else {
                XCTFail("Expected invalidConfiguration error")
                return
            }
            XCTAssertTrue(msg.contains("配方版本 25"))
        }

        // Version 25 should succeed
        recipe.version = 25
        XCTAssertNoThrow(try recipe.validateVersion())

        // Future version (e.g. 28) should fail
        recipe.version = 28
        XCTAssertThrowsError(try recipe.validateVersion())
    }

    // MARK: - 8. Selective Sync

    func testSelectiveSyncHairColor() {
        var source = AdjustmentSettings()
        source.hairColor = HairColorSettings(enabled: true, grayHairRemoval: 0.7, hairTone: .chestnutBrown, hairToneStrength: 0.8)

        var target = AdjustmentSettings()
        var lut = "original"

        // Sync with hairColor disabled preserves target
        var optionsDisabled = AdjustmentSyncOptions.none
        optionsDisabled.hairColor = false
        var merged = AdjustmentSyncEngine.merge(source: source, into: target, options: optionsDisabled, targetLUT: &lut)
        XCTAssertNil(merged.hairColor)

        // Sync with hairColor enabled copies source
        var optionsEnabled = AdjustmentSyncOptions.none
        optionsEnabled.hairColor = true
        merged = AdjustmentSyncEngine.merge(source: source, into: target, options: optionsEnabled, targetLUT: &lut)
        XCTAssertEqual(merged.hairColor, source.hairColor)
    }

    // MARK: - 9. Multi-Person Per-Face Refinement

    func testPerPersonMultiFaceOverride() {
        let baseImage = makeTestImage()
        let face = makeMockFace()
        let settings = HairColorSettings(enabled: true, grayHairRemoval: 0.8)

        let perPersonImage = HairColorEngine.applyPerPerson(
            to: baseImage,
            face: face,
            faceIndex: 0,
            perFaceMask: nil,
            settings: settings
        )
        XCTAssertNotNil(perPersonImage)
        XCTAssertEqual(perPersonImage.extent, baseImage.extent)
    }
}

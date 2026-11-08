import XCTest
import CoreImage
import CoreGraphics
@testable import PhotoCore

final class EyeShapeTests: XCTestCase {

    // MARK: - Helpers

    private func makeTestFaceImage() -> (image: CIImage, face: FaceLandmarkSet) {
        let size = CGSize(width: 400, height: 400)
        let base = CIImage(color: CIColor(red: 0.85, green: 0.72, blue: 0.62, alpha: 1.0))
            .cropped(to: CGRect(origin: .zero, size: size))

        // Left eye (image-left): x in [0.28, 0.42], y in [0.57, 0.63]
        let leftEye: [CGPoint] = [
            CGPoint(x: 0.28, y: 0.60), // Outer canthus
            CGPoint(x: 0.32, y: 0.625), // Upper lid left
            CGPoint(x: 0.35, y: 0.63), // Upper lid apex
            CGPoint(x: 0.39, y: 0.62), // Upper lid right
            CGPoint(x: 0.42, y: 0.60), // Inner canthus
            CGPoint(x: 0.39, y: 0.58), // Lower lid right
            CGPoint(x: 0.35, y: 0.57), // Lower lid center
            CGPoint(x: 0.31, y: 0.58)  // Lower lid left
        ]

        // Right eye (image-right): x in [0.58, 0.72], y in [0.57, 0.63]
        let rightEye: [CGPoint] = [
            CGPoint(x: 0.58, y: 0.60), // Inner canthus
            CGPoint(x: 0.61, y: 0.62), // Upper lid left
            CGPoint(x: 0.65, y: 0.63), // Upper lid apex
            CGPoint(x: 0.68, y: 0.625), // Upper lid right
            CGPoint(x: 0.72, y: 0.60), // Outer canthus
            CGPoint(x: 0.69, y: 0.58), // Lower lid right
            CGPoint(x: 0.65, y: 0.57), // Lower lid center
            CGPoint(x: 0.61, y: 0.58)  // Lower lid left
        ]

        let face = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60),
            confidence: 0.98,
            faceContour: [
                CGPoint(x: 0.25, y: 0.75),
                CGPoint(x: 0.26, y: 0.30),
                CGPoint(x: 0.50, y: 0.20),
                CGPoint(x: 0.74, y: 0.30),
                CGPoint(x: 0.75, y: 0.75)
            ],
            leftEye: leftEye,
            rightEye: rightEye,
            leftPupil: CGPoint(x: 0.35, y: 0.60),
            rightPupil: CGPoint(x: 0.65, y: 0.60)
        )

        return (base, face)
    }

    // MARK: - 1. Neutral Settings & Defaults

    func testNeutralSettingsSkipWarp() {
        let (image, face) = makeTestFaceImage()
        let settings = EyeShapeSettings() // Default is disabled & neutral
        XCTAssertTrue(settings.isNeutral)

        let result = EyeShapeEngine.apply(to: image, faces: [face], settings: settings)
        XCTAssertFalse(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 0)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 2. Inner Canthoplasty

    func testInnerCanthoplastyWarp() {
        let (image, face) = makeTestFaceImage()
        let settings = EyeShapeSettings(enabled: true, innerCanthoplasty: 0.75)
        XCTAssertFalse(settings.isNeutral)

        let result = EyeShapeEngine.apply(to: image, faces: [face], settings: settings)
        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 1)
        XCTAssertGreaterThan(result.report.averageCanthoplasty, 0.3)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 3. Outer Canthoplasty & Lower Lid Drop

    func testOuterCanthoplastyWarp() {
        let (image, face) = makeTestFaceImage()
        let settings = EyeShapeSettings(enabled: true, outerCanthoplasty: 0.80)
        XCTAssertFalse(settings.isNeutral)

        let result = EyeShapeEngine.apply(to: image, faces: [face], settings: settings)
        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 1)
        XCTAssertGreaterThan(result.report.averageCanthoplasty, 0.35)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 4. Eye Roundness (Doe eye vs Cat eye)

    func testEyeRoundnessWarp() {
        let (image, face) = makeTestFaceImage()
        // Positive: round doe eye
        let roundSettings = EyeShapeSettings(enabled: true, eyeRoundness: 0.40)
        let roundResult = EyeShapeEngine.apply(to: image, faces: [face], settings: roundSettings)
        XCTAssertTrue(roundResult.report.applied)
        XCTAssertEqual(roundResult.report.averageRoundness, 0.40)

        // Negative: almond cat eye
        let catSettings = EyeShapeSettings(enabled: true, eyeRoundness: -0.35)
        let catResult = EyeShapeEngine.apply(to: image, faces: [face], settings: catSettings)
        XCTAssertTrue(catResult.report.applied)
        XCTAssertEqual(catResult.report.averageRoundness, -0.35)
    }

    // MARK: - 5. Eye Tilt Calibration

    func testEyeTiltWarp() {
        let (image, face) = makeTestFaceImage()
        // Positive: uplifted cat/phoenix eye
        let liftSettings = EyeShapeSettings(enabled: true, eyeTilt: 0.35)
        let liftResult = EyeShapeEngine.apply(to: image, faces: [face], settings: liftSettings)
        XCTAssertTrue(liftResult.report.applied)
        XCTAssertEqual(liftResult.report.averageTilt, 0.35)

        // Negative: puppy droop eye
        let droopSettings = EyeShapeSettings(enabled: true, eyeTilt: -0.30)
        let droopResult = EyeShapeEngine.apply(to: image, faces: [face], settings: droopSettings)
        XCTAssertTrue(droopResult.report.applied)
        XCTAssertEqual(droopResult.report.averageTilt, -0.30)
    }

    // MARK: - 6. Interpupillary Distance

    func testInterpupillaryDistanceWarp() {
        let (image, face) = makeTestFaceImage()
        let settings = EyeShapeSettings(enabled: true, interpupillaryDistance: 0.45)
        let result = EyeShapeEngine.apply(to: image, faces: [face], settings: settings)
        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 7. Eye Vertical Position & Mid-Face Shortening

    func testEyeVerticalPositionMidFaceBalance() {
        let (image, face) = makeTestFaceImage()
        // Positive: moves eyes downward to shorten mid-face length
        let shortenSettings = EyeShapeSettings(enabled: true, eyeVerticalPosition: 0.40)
        let result = EyeShapeEngine.apply(to: image, faces: [face], settings: shortenSettings)
        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 8. Eye Symmetry Harmonization

    func testEyeSymmetryHarmonization() {
        let (image, _) = makeTestFaceImage()

        // Create an asymmetrical face (right eye slightly higher and smaller)
        let leftEye: [CGPoint] = [
            CGPoint(x: 0.28, y: 0.60), CGPoint(x: 0.35, y: 0.64),
            CGPoint(x: 0.42, y: 0.60), CGPoint(x: 0.35, y: 0.56)
        ]
        let rightEye: [CGPoint] = [
            CGPoint(x: 0.60, y: 0.64), CGPoint(x: 0.65, y: 0.67),
            CGPoint(x: 0.70, y: 0.64), CGPoint(x: 0.65, y: 0.61)
        ]
        let asymmetricFace = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60),
            leftEye: leftEye,
            rightEye: rightEye,
            leftPupil: CGPoint(x: 0.35, y: 0.60),
            rightPupil: CGPoint(x: 0.65, y: 0.64)
        )

        let settings = EyeShapeSettings(enabled: true, eyeSymmetry: 0.80)
        let result = EyeShapeEngine.apply(to: image, faces: [asymmetricFace], settings: settings)
        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 9. Multi-Person Demographic Override

    func testSinglePersonAndMultiPersonProfileOverride() {
        let (image, face) = makeTestFaceImage()
        let settings = EyeShapeSettings(enabled: true, innerCanthoplasty: 0.50, eyeRoundness: 0.30)

        let perPersonResult = EyeShapeEngine.applyPerPerson(
            to: image,
            face: face,
            faceIndex: 0,
            settings: settings,
            perFaceMask: nil
        )
        XCTAssertTrue(perPersonResult.report.applied)
        XCTAssertEqual(perPersonResult.report.faceCount, 1)
        XCTAssertEqual(perPersonResult.image.extent, image.extent)
    }

    // MARK: - 10. Recipe Version 28 Gate

    func testRecipeVersion28Gate() throws {
        var recipe = Recipe()
        recipe.adjustments.eyeShape = EyeShapeSettings(enabled: true, innerCanthoplasty: 0.50)

        // Version 27 should fail loudly (cannot silently downgrade)
        recipe.version = 27
        XCTAssertThrowsError(try recipe.validateVersion())

        // Version 28 must pass
        recipe.version = 28
        XCTAssertNoThrow(try recipe.validateVersion())

        // Future version 33 should fail
        recipe.version = 33
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 33 is future unsupported")

        // PhotoEngine requiredRecipeVersion check
        let requiredVersion = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(requiredVersion, 28)
    }

    // MARK: - 11. Multi-Person EyeShape Override Requires Version 28

    func testMultiPersonEyeShapeOverrideRequiresVersion28() throws {
        var recipe = Recipe()
        var multi = MultiPersonSettings(enabled: true)
        let profile = PersonPortraitProfile(
            faceIndex: 0,
            role: .femaleAdult,
            enabled: true,
            eyeShapeOverride: EyeShapeSettings(enabled: true, outerCanthoplasty: 0.60)
        )
        multi.individualProfiles = [profile]
        recipe.adjustments.multiPerson = multi

        // Version 27 should fail
        recipe.version = 27
        XCTAssertThrowsError(try recipe.validateVersion())

        // Version 28 must succeed
        recipe.version = 28
        XCTAssertNoThrow(try recipe.validateVersion())

        let reqV = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(reqV, 28)
    }

    // MARK: - 12. Selective Sync

    func testSelectiveSyncEyeShape() {
        var source = AdjustmentSettings()
        source.eyeShape = EyeShapeSettings(enabled: true, innerCanthoplasty: 0.65, outerCanthoplasty: 0.55)

        let target = AdjustmentSettings()

        // Sync with eyeShape enabled
        var syncOptions = AdjustmentSyncOptions.none
        syncOptions.eyeShape = true
        var targetLUT = ""
        let merged = AdjustmentSyncEngine.merge(source: source, into: target, options: syncOptions, sourceLUT: "", targetLUT: &targetLUT)
        XCTAssertNotNil(merged.eyeShape)
        XCTAssertEqual(merged.eyeShape?.innerCanthoplasty, 0.65)
        XCTAssertEqual(merged.eyeShape?.outerCanthoplasty, 0.55)

        // Sync with eyeShape disabled
        syncOptions.eyeShape = false
        let mergedDisabled = AdjustmentSyncEngine.merge(source: source, into: target, options: syncOptions, sourceLUT: "", targetLUT: &targetLUT)
        XCTAssertNil(mergedDisabled.eyeShape)
    }

    // MARK: - 13. Parameter Validation

    func testValidationRanges() {
        var invalid = EyeShapeSettings(enabled: true)
        invalid.innerCanthoplasty = 1.5
        XCTAssertThrowsError(try invalid.validated())

        invalid = EyeShapeSettings(enabled: true)
        invalid.outerCanthoplasty = -0.1
        XCTAssertThrowsError(try invalid.validated())

        invalid = EyeShapeSettings(enabled: true)
        invalid.eyeRoundness = 0.8
        XCTAssertThrowsError(try invalid.validated())

        invalid = EyeShapeSettings(enabled: true)
        invalid.eyeTilt = -0.8
        XCTAssertThrowsError(try invalid.validated())

        invalid = EyeShapeSettings(enabled: true)
        invalid.interpupillaryDistance = 0.9
        XCTAssertThrowsError(try invalid.validated())

        invalid = EyeShapeSettings(enabled: true)
        invalid.eyeVerticalPosition = -0.7
        XCTAssertThrowsError(try invalid.validated())

        invalid = EyeShapeSettings(enabled: true)
        invalid.eyeSymmetry = 1.2
        XCTAssertThrowsError(try invalid.validated())

        let valid = EyeShapeSettings(
            enabled: true,
            innerCanthoplasty: 0.5,
            outerCanthoplasty: 0.5,
            eyeRoundness: 0.3,
            eyeTilt: -0.2,
            interpupillaryDistance: 0.1,
            eyeVerticalPosition: -0.1,
            eyeSymmetry: 0.5
        )
        XCTAssertNoThrow(try valid.validated())
    }
}

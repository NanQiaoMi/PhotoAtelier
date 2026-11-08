import XCTest
import CoreImage
import CoreGraphics
@testable import PhotoCore

final class NoseReshapeTests: XCTestCase {

    // MARK: - Helpers

    private func makeTestFaceImage() -> (image: CIImage, face: FaceLandmarkSet) {
        let size = CGSize(width: 400, height: 400)
        let base = CIImage(color: CIColor(red: 0.85, green: 0.72, blue: 0.62, alpha: 1.0))
            .cropped(to: CGRect(origin: .zero, size: size))

        let nose: [CGPoint] = [
            CGPoint(x: 0.50, y: 0.58), // radix (top)
            CGPoint(x: 0.50, y: 0.52), // mid bridge
            CGPoint(x: 0.50, y: 0.46), // tip
            CGPoint(x: 0.44, y: 0.44), // left alar
            CGPoint(x: 0.56, y: 0.44), // right alar
            CGPoint(x: 0.50, y: 0.42)  // subnasale (bottom)
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
            leftEye: [CGPoint(x: 0.35, y: 0.60)],
            rightEye: [CGPoint(x: 0.65, y: 0.60)],
            nose: nose
        )

        return (base, face)
    }

    // MARK: - 1. Neutral Settings & Defaults

    func testNeutralSettingsSkipWarp() {
        let (image, face) = makeTestFaceImage()
        let settings = NoseReshapeSettings()
        XCTAssertTrue(settings.isNeutral)

        let result = NoseReshapeEngine.apply(to: image, faces: [face], settings: settings)
        XCTAssertFalse(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 0)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 2. Narrow Nose Wing Warp

    func testNarrowNoseWingWarp() {
        let (image, face) = makeTestFaceImage()

        // Narrowing wings (positive value)
        let settingsNarrow = NoseReshapeSettings(enabled: true, narrowNoseWing: 0.40)
        let resNarrow = NoseReshapeEngine.apply(to: image, faces: [face], settings: settingsNarrow)
        XCTAssertTrue(resNarrow.report.applied)
        XCTAssertEqual(resNarrow.report.faceCount, 1)
        XCTAssertEqual(resNarrow.image.extent, image.extent)

        // Widening wings (negative value)
        let settingsWiden = NoseReshapeSettings(enabled: true, narrowNoseWing: -0.30)
        let resWiden = NoseReshapeEngine.apply(to: image, faces: [face], settings: settingsWiden)
        XCTAssertTrue(resWiden.report.applied)
        XCTAssertEqual(resWiden.report.faceCount, 1)
        XCTAssertEqual(resWiden.image.extent, image.extent)
    }

    // MARK: - 3. Nose Tip Size Reshaping

    func testNoseTipSizeShrinkAndEnlarge() {
        let (image, face) = makeTestFaceImage()

        // Shrinking bulbous tip (negative value)
        let settingsShrink = NoseReshapeSettings(enabled: true, noseTipSize: -0.40)
        let resShrink = NoseReshapeEngine.apply(to: image, faces: [face], settings: settingsShrink)
        XCTAssertTrue(resShrink.report.applied)
        XCTAssertEqual(resShrink.report.faceCount, 1)
        XCTAssertEqual(resShrink.image.extent, image.extent)

        // Enlarging tip (positive value)
        let settingsEnlarge = NoseReshapeSettings(enabled: true, noseTipSize: 0.35)
        let resEnlarge = NoseReshapeEngine.apply(to: image, faces: [face], settings: settingsEnlarge)
        XCTAssertTrue(resEnlarge.report.applied)
        XCTAssertEqual(resEnlarge.report.faceCount, 1)
        XCTAssertEqual(resEnlarge.image.extent, image.extent)
    }

    // MARK: - 4. Nose Bridge Width

    func testNoseBridgeWidthWarp() {
        let (image, face) = makeTestFaceImage()

        // Sculpting / narrowing bridge (negative value)
        let settingsNarrow = NoseReshapeSettings(enabled: true, noseBridgeWidth: -0.45)
        let resNarrow = NoseReshapeEngine.apply(to: image, faces: [face], settings: settingsNarrow)
        XCTAssertTrue(resNarrow.report.applied)
        XCTAssertEqual(resNarrow.report.faceCount, 1)

        // Broadening bridge (positive value)
        let settingsWide = NoseReshapeSettings(enabled: true, noseBridgeWidth: 0.40)
        let resWide = NoseReshapeEngine.apply(to: image, faces: [face], settings: settingsWide)
        XCTAssertTrue(resWide.report.applied)
        XCTAssertEqual(resWide.report.faceCount, 1)
    }

    // MARK: - 5. Nose Pitch Angle (Upturned / Hawk Correction)

    func testNosePitchAngleUpturnedAndDrooping() {
        let (image, face) = makeTestFaceImage()

        // Hawk nose correction (negative value: lifts tip)
        let settingsHawk = NoseReshapeSettings(enabled: true, nosePitchAngle: -0.40)
        let resHawk = NoseReshapeEngine.apply(to: image, faces: [face], settings: settingsHawk)
        XCTAssertTrue(resHawk.report.applied)
        XCTAssertEqual(resHawk.report.faceCount, 1)

        // Snub / upturned nose correction (positive value: lowers tip)
        let settingsSnub = NoseReshapeSettings(enabled: true, nosePitchAngle: 0.40)
        let resSnub = NoseReshapeEngine.apply(to: image, faces: [face], settings: settingsSnub)
        XCTAssertTrue(resSnub.report.applied)
        XCTAssertEqual(resSnub.report.faceCount, 1)
    }

    // MARK: - 6. Dorsal Hump Smoothing

    func testHumpSmoothingWarp() {
        let (image, face) = makeTestFaceImage()

        let settingsHump = NoseReshapeSettings(enabled: true, humpSmoothing: 0.70)
        let resHump = NoseReshapeEngine.apply(to: image, faces: [face], settings: settingsHump)
        XCTAssertTrue(resHump.report.applied)
        XCTAssertEqual(resHump.report.faceCount, 1)
        XCTAssertEqual(resHump.image.extent, image.extent)
    }

    // MARK: - 7. Nose Length Modulation & Mid-Face Balancing

    func testNoseLengthModulation() {
        let (image, face) = makeTestFaceImage()

        // Shortening nose for youthful mid-face balance (negative value)
        let settingsShort = NoseReshapeSettings(enabled: true, noseLength: -0.35)
        let resShort = NoseReshapeEngine.apply(to: image, faces: [face], settings: settingsShort)
        XCTAssertTrue(resShort.report.applied)
        XCTAssertEqual(resShort.report.faceCount, 1)

        // Lengthening nose (positive value)
        let settingsLong = NoseReshapeSettings(enabled: true, noseLength: 0.35)
        let resLong = NoseReshapeEngine.apply(to: image, faces: [face], settings: settingsLong)
        XCTAssertTrue(resLong.report.applied)
        XCTAssertEqual(resLong.report.faceCount, 1)
    }

    // MARK: - 8. 3D Contour Highlight & Micro-Shading

    func test3DContourHighlightAndShading() {
        let (image, face) = makeTestFaceImage()

        let settings3D = NoseReshapeSettings(enabled: true, nose3DContour: 0.80)
        let res3D = NoseReshapeEngine.apply(to: image, faces: [face], settings: settings3D)
        XCTAssertTrue(res3D.report.applied)
        XCTAssertEqual(res3D.report.faceCount, 1)
        XCTAssertEqual(res3D.image.extent, image.extent)

        // Guide mask generation directly
        let mask = NoseReshapeEngine.makeNose3DGuideMask(faces: [face], extent: image.extent)
        XCTAssertEqual(mask.extent, image.extent)
    }

    // MARK: - 9. Multi-Person Demographic Profile Override

    func testSinglePersonAndMultiPersonProfileOverride() {
        let (image, face) = makeTestFaceImage()
        let settings = NoseReshapeSettings(enabled: true, narrowNoseWing: 0.50, nose3DContour: 0.60)

        let perPersonResult = NoseReshapeEngine.applyPerPerson(
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

    // MARK: - 10. Recipe Version 29 Gate

    func testRecipeVersion29Gate() throws {
        var recipe = Recipe()
        recipe.adjustments.noseReshape = NoseReshapeSettings(enabled: true, narrowNoseWing: 0.30)

        // Version 28 should fail loudly (cannot silently downgrade)
        recipe.version = 28
        XCTAssertThrowsError(try recipe.validateVersion())

        // Version 29 must pass
        recipe.version = 29
        XCTAssertNoThrow(try recipe.validateVersion())

        // Future version 33 should fail
        recipe.version = 33
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 33 is future unsupported")

        // PhotoEngine requiredRecipeVersion check
        let requiredVersion = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(requiredVersion, 29)
    }

    // MARK: - 11. Multi-Person NoseReshape Override Requires Version 29

    func testMultiPersonNoseReshapeOverrideRequiresVersion29() throws {
        var recipe = Recipe()
        var multi = MultiPersonSettings(enabled: true)
        let profile = PersonPortraitProfile(
            faceIndex: 0,
            role: .femaleAdult,
            enabled: true,
            noseReshapeOverride: NoseReshapeSettings(enabled: true, noseTipSize: -0.30)
        )
        multi.individualProfiles = [profile]
        recipe.adjustments.multiPerson = multi

        // Version 28 should fail
        recipe.version = 28
        XCTAssertThrowsError(try recipe.validateVersion())

        // Version 29 must succeed
        recipe.version = 29
        XCTAssertNoThrow(try recipe.validateVersion())

        let reqV = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(reqV, 29)
    }

    // MARK: - 12. Selective Sync

    func testSelectiveSyncNoseReshape() {
        var source = AdjustmentSettings()
        source.noseReshape = NoseReshapeSettings(
            enabled: true,
            narrowNoseWing: 0.45,
            noseTipSize: -0.30,
            nose3DContour: 0.50
        )

        let target = AdjustmentSettings()

        // Sync with noseReshape enabled
        var syncOptions = AdjustmentSyncOptions.none
        syncOptions.noseReshape = true
        var targetLUT = ""
        let merged = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptions,
            sourceLUT: "",
            targetLUT: &targetLUT
        )
        XCTAssertNotNil(merged.noseReshape)
        XCTAssertEqual(merged.noseReshape?.narrowNoseWing, 0.45)
        XCTAssertEqual(merged.noseReshape?.noseTipSize, -0.30)
        XCTAssertEqual(merged.noseReshape?.nose3DContour, 0.50)

        // Sync with noseReshape disabled
        syncOptions.noseReshape = false
        let mergedDisabled = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptions,
            sourceLUT: "",
            targetLUT: &targetLUT
        )
        XCTAssertNil(mergedDisabled.noseReshape)
    }

    // MARK: - 13. Parameter Validation

    func testValidationRanges() {
        var invalid = NoseReshapeSettings(enabled: true)
        invalid.narrowNoseWing = 0.8
        XCTAssertThrowsError(try invalid.validated())

        invalid = NoseReshapeSettings(enabled: true)
        invalid.narrowNoseWing = -0.9
        XCTAssertThrowsError(try invalid.validated())

        invalid = NoseReshapeSettings(enabled: true)
        invalid.noseTipSize = 0.6
        XCTAssertThrowsError(try invalid.validated())

        invalid = NoseReshapeSettings(enabled: true)
        invalid.noseBridgeWidth = -0.7
        XCTAssertThrowsError(try invalid.validated())

        invalid = NoseReshapeSettings(enabled: true)
        invalid.nosePitchAngle = 0.9
        XCTAssertThrowsError(try invalid.validated())

        invalid = NoseReshapeSettings(enabled: true)
        invalid.humpSmoothing = 1.5
        XCTAssertThrowsError(try invalid.validated())

        invalid = NoseReshapeSettings(enabled: true)
        invalid.humpSmoothing = -0.2
        XCTAssertThrowsError(try invalid.validated())

        invalid = NoseReshapeSettings(enabled: true)
        invalid.noseLength = 0.7
        XCTAssertThrowsError(try invalid.validated())

        invalid = NoseReshapeSettings(enabled: true)
        invalid.nose3DContour = 1.2
        XCTAssertThrowsError(try invalid.validated())

        let valid = NoseReshapeSettings(
            enabled: true,
            narrowNoseWing: 0.35,
            noseTipSize: -0.25,
            noseBridgeWidth: -0.20,
            nosePitchAngle: 0.15,
            humpSmoothing: 0.50,
            noseLength: -0.10,
            nose3DContour: 0.65
        )
        XCTAssertNoThrow(try valid.validated())
    }

    // MARK: - 14. Edge Case: Empty Nose Landmarks Handled Gracefully

    func testEmptyNoseLandmarksHandledGracefully() {
        let (image, _) = makeTestFaceImage()
        let emptyFace = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.9,
            faceContour: [],
            leftEye: [],
            rightEye: [],
            nose: []
        )
        let settings = NoseReshapeSettings(enabled: true, narrowNoseWing: 0.30)
        let result = NoseReshapeEngine.apply(to: image, faces: [emptyFace], settings: settings)
        XCTAssertFalse(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 0)
    }
}

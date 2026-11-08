import XCTest
import CoreImage
import CoreGraphics
@testable import PhotoCore

final class EyebrowReshapeTests: XCTestCase {

    // MARK: - Helpers

    private func makeTestFaceImage() -> (image: CIImage, face: FaceLandmarkSet) {
        let size = CGSize(width: 400, height: 400)
        let base = CIImage(color: CIColor(red: 0.85, green: 0.72, blue: 0.62, alpha: 1.0))
            .cropped(to: CGRect(origin: .zero, size: size))

        let leftBrow: [CGPoint] = [
            CGPoint(x: 0.18, y: 0.68), // tail
            CGPoint(x: 0.28, y: 0.73), // arch
            CGPoint(x: 0.42, y: 0.70)  // head
        ]

        let rightBrow: [CGPoint] = [
            CGPoint(x: 0.58, y: 0.70), // head
            CGPoint(x: 0.72, y: 0.73), // arch
            CGPoint(x: 0.82, y: 0.68)  // tail
        ]

        let face = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.15, y: 0.20, width: 0.70, height: 0.65),
            confidence: 0.98,
            faceContour: [
                CGPoint(x: 0.20, y: 0.70),
                CGPoint(x: 0.25, y: 0.40),
                CGPoint(x: 0.50, y: 0.20),
                CGPoint(x: 0.75, y: 0.40),
                CGPoint(x: 0.80, y: 0.70)
            ],
            leftEye: [CGPoint(x: 0.35, y: 0.62)],
            rightEye: [CGPoint(x: 0.65, y: 0.62)],
            leftEyebrow: leftBrow,
            rightEyebrow: rightBrow,
            nose: [CGPoint(x: 0.50, y: 0.48)]
        )

        return (base, face)
    }

    // MARK: - 1. Neutral Settings & Defaults

    func testNeutralSettingsSkipWarp() {
        let (image, face) = makeTestFaceImage()
        let settings = EyebrowReshapeSettings()
        XCTAssertTrue(settings.isNeutral)

        let result = EyebrowReshapeEngine.apply(to: image, faces: [face], settings: settings)
        XCTAssertFalse(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 0)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 2. Eyebrow Tail Lift

    func testEyebrowTailLiftWarp() {
        let (image, face) = makeTestFaceImage()

        // Positive lift: raises drooping eyebrow tails
        let settingsLift = EyebrowReshapeSettings(enabled: true, browTailLift: 0.45)
        let resLift = EyebrowReshapeEngine.apply(to: image, faces: [face], settings: settingsLift)
        XCTAssertTrue(resLift.report.applied)
        XCTAssertEqual(resLift.report.faceCount, 1)
        XCTAssertEqual(resLift.image.extent, image.extent)

        // Negative lift: softens overly raised brows
        let settingsRelax = EyebrowReshapeSettings(enabled: true, browTailLift: -0.35)
        let resRelax = EyebrowReshapeEngine.apply(to: image, faces: [face], settings: settingsRelax)
        XCTAssertTrue(resRelax.report.applied)
        XCTAssertEqual(resRelax.report.faceCount, 1)
    }

    // MARK: - 3. Eyebrow Thickness Modulation

    func testEyebrowThicknessWarp() {
        let (image, face) = makeTestFaceImage()

        // Positive: thickens and plumps sparse brows
        let settingsThick = EyebrowReshapeSettings(enabled: true, browThickness: 0.40)
        let resThick = EyebrowReshapeEngine.apply(to: image, faces: [face], settings: settingsThick)
        XCTAssertTrue(resThick.report.applied)
        XCTAssertEqual(resThick.report.faceCount, 1)
        XCTAssertEqual(resThick.image.extent, image.extent)

        // Negative: thins out heavy brows
        let settingsThin = EyebrowReshapeSettings(enabled: true, browThickness: -0.35)
        let resThin = EyebrowReshapeEngine.apply(to: image, faces: [face], settings: settingsThin)
        XCTAssertTrue(resThin.report.applied)
        XCTAssertEqual(resThin.report.faceCount, 1)
    }

    // MARK: - 4. Eyebrow Length Extension

    func testEyebrowLengthWarp() {
        let (image, face) = makeTestFaceImage()

        // Positive: extends short brow tail
        let settingsLong = EyebrowReshapeSettings(enabled: true, browLength: 0.45)
        let resLong = EyebrowReshapeEngine.apply(to: image, faces: [face], settings: settingsLong)
        XCTAssertTrue(resLong.report.applied)
        XCTAssertEqual(resLong.report.faceCount, 1)
        XCTAssertEqual(resLong.image.extent, image.extent)

        // Negative: shortens long brow
        let settingsShort = EyebrowReshapeSettings(enabled: true, browLength: -0.30)
        let resShort = EyebrowReshapeEngine.apply(to: image, faces: [face], settings: settingsShort)
        XCTAssertTrue(resShort.report.applied)
        XCTAssertEqual(resShort.report.faceCount, 1)
    }

    // MARK: - 5. Bilateral Eyebrow Symmetry Calibration

    func testBilateralEyebrowSymmetryWarp() {
        let (image, _) = makeTestFaceImage()

        // Asymmetrical face with uneven left and right eyebrow heights
        let asymmetricalFace = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.15, y: 0.20, width: 0.70, height: 0.65),
            confidence: 0.98,
            faceContour: [
                CGPoint(x: 0.20, y: 0.70),
                CGPoint(x: 0.50, y: 0.20),
                CGPoint(x: 0.80, y: 0.70)
            ],
            leftEye: [CGPoint(x: 0.35, y: 0.62)],
            rightEye: [CGPoint(x: 0.65, y: 0.62)],
            leftEyebrow: [
                CGPoint(x: 0.18, y: 0.65), // Lower left tail
                CGPoint(x: 0.28, y: 0.70), // Lower left arch
                CGPoint(x: 0.42, y: 0.68)
            ],
            rightEyebrow: [
                CGPoint(x: 0.58, y: 0.72),
                CGPoint(x: 0.72, y: 0.76), // Higher right arch
                CGPoint(x: 0.82, y: 0.71)  // Higher right tail
            ],
            nose: [CGPoint(x: 0.50, y: 0.48)]
        )

        let settings = EyebrowReshapeSettings(enabled: true, browSymmetry: 0.75)
        let result = EyebrowReshapeEngine.apply(to: image, faces: [asymmetricalFace], settings: settings)
        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 1)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 6. Wild Brow Hair-Stroke Texture

    func testWildBrowTextureEnhancement() {
        let (image, face) = makeTestFaceImage()

        let settings = EyebrowReshapeSettings(enabled: true, wildBrowTexture: 0.80)
        let result = EyebrowReshapeEngine.apply(to: image, faces: [face], settings: settings)
        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 1)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 7. 3D Brow Ridge Highlight & Sub-Brow Shading

    func test3DBrowBoneHighlightAndSubBrowShading() {
        let (image, face) = makeTestFaceImage()

        let settings = EyebrowReshapeSettings(enabled: true, brow3DContour: 0.70)
        let result = EyebrowReshapeEngine.apply(to: image, faces: [face], settings: settings)
        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 1)
        XCTAssertEqual(result.image.extent, image.extent)

        // Direct guide mask test
        let guide = EyebrowReshapeEngine.makeEyebrowGuideMask(faces: [face], extent: image.extent)
        XCTAssertEqual(guide.extent, image.extent)
    }

    // MARK: - 8. Multi-Person Demographic Profile Override

    func testSinglePersonAndMultiPersonProfileOverride() {
        let (image, face) = makeTestFaceImage()
        let settings = EyebrowReshapeSettings(
            enabled: true,
            browTailLift: 0.35,
            browThickness: 0.25,
            browLength: 0.20,
            browSymmetry: 0.60
        )

        let perPersonResult = EyebrowReshapeEngine.applyPerPerson(
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

    // MARK: - 9. Recipe Version 32 Gate

    func testRecipeVersion32Gate() throws {
        var recipe = Recipe()
        recipe.adjustments.eyebrowReshape = EyebrowReshapeSettings(enabled: true, browTailLift: 0.30)

        // Version 31 should fail loudly (cannot silently downgrade)
        recipe.version = 31
        XCTAssertThrowsError(try recipe.validateVersion())

        // Version 32 must pass
        recipe.version = 32
        XCTAssertNoThrow(try recipe.validateVersion())

        // Future version 33 should fail
        recipe.version = 33
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 33 is future unsupported")

        // PhotoEngine requiredRecipeVersion check
        let requiredVersion = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(requiredVersion, 32)
    }

    // MARK: - 10. Multi-Person EyebrowReshape Override Requires Version 32

    func testMultiPersonEyebrowReshapeOverrideRequiresVersion32() throws {
        var recipe = Recipe()
        var multi = MultiPersonSettings(enabled: true)
        let profile = PersonPortraitProfile(
            faceIndex: 0,
            role: .femaleAdult,
            enabled: true,
            eyebrowReshapeOverride: EyebrowReshapeSettings(enabled: true, browThickness: 0.30)
        )
        multi.individualProfiles = [profile]
        recipe.adjustments.multiPerson = multi

        // Version 31 should fail
        recipe.version = 31
        XCTAssertThrowsError(try recipe.validateVersion())

        // Version 32 must succeed
        recipe.version = 32
        XCTAssertNoThrow(try recipe.validateVersion())

        let reqV = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(reqV, 32)
    }

    // MARK: - 11. Selective Sync

    func testSelectiveSyncEyebrowReshape() {
        var source = AdjustmentSettings()
        source.eyebrowReshape = EyebrowReshapeSettings(
            enabled: true,
            browTailLift: 0.35,
            browThickness: -0.20,
            browLength: 0.30,
            browSymmetry: 0.50,
            wildBrowTexture: 0.60,
            brow3DContour: 0.40
        )

        let target = AdjustmentSettings()

        // Sync with eyebrowReshape enabled
        var syncOptions = AdjustmentSyncOptions.none
        syncOptions.eyebrowReshape = true
        var targetLUT = ""
        let merged = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptions,
            sourceLUT: "",
            targetLUT: &targetLUT
        )
        XCTAssertNotNil(merged.eyebrowReshape)
        XCTAssertEqual(merged.eyebrowReshape?.browTailLift, 0.35)
        XCTAssertEqual(merged.eyebrowReshape?.browThickness, -0.20)
        XCTAssertEqual(merged.eyebrowReshape?.browLength, 0.30)
        XCTAssertEqual(merged.eyebrowReshape?.browSymmetry, 0.50)
        XCTAssertEqual(merged.eyebrowReshape?.wildBrowTexture, 0.60)
        XCTAssertEqual(merged.eyebrowReshape?.brow3DContour, 0.40)

        // Sync with eyebrowReshape disabled
        syncOptions.eyebrowReshape = false
        let mergedDisabled = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptions,
            sourceLUT: "",
            targetLUT: &targetLUT
        )
        XCTAssertNil(mergedDisabled.eyebrowReshape)
    }

    // MARK: - 12. Parameter Validation

    func testValidationRanges() {
        var invalid = EyebrowReshapeSettings(enabled: true)
        invalid.browTailLift = 0.8
        XCTAssertThrowsError(try invalid.validated())

        invalid = EyebrowReshapeSettings(enabled: true)
        invalid.browTailLift = -0.9
        XCTAssertThrowsError(try invalid.validated())

        invalid = EyebrowReshapeSettings(enabled: true)
        invalid.browThickness = 0.7
        XCTAssertThrowsError(try invalid.validated())

        invalid = EyebrowReshapeSettings(enabled: true)
        invalid.browLength = -0.8
        XCTAssertThrowsError(try invalid.validated())

        invalid = EyebrowReshapeSettings(enabled: true)
        invalid.browSymmetry = 1.3
        XCTAssertThrowsError(try invalid.validated())

        invalid = EyebrowReshapeSettings(enabled: true)
        invalid.browSymmetry = -0.1
        XCTAssertThrowsError(try invalid.validated())

        invalid = EyebrowReshapeSettings(enabled: true)
        invalid.wildBrowTexture = 1.5
        XCTAssertThrowsError(try invalid.validated())

        invalid = EyebrowReshapeSettings(enabled: true)
        invalid.brow3DContour = 1.4
        XCTAssertThrowsError(try invalid.validated())

        let valid = EyebrowReshapeSettings(
            enabled: true,
            browTailLift: 0.30,
            browThickness: -0.20,
            browLength: 0.25,
            browSymmetry: 0.60,
            wildBrowTexture: 0.50,
            brow3DContour: 0.40
        )
        XCTAssertNoThrow(try valid.validated())
    }

    // MARK: - 13. Edge Case: Sparse or Empty Eyebrow Handled Gracefully

    func testSparseOrEmptyEyebrowHandledGracefully() {
        let (image, _) = makeTestFaceImage()

        // Empty landmarks
        let emptyFace = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.9,
            faceContour: [],
            leftEye: [],
            rightEye: [],
            leftEyebrow: [],
            rightEyebrow: [],
            nose: []
        )
        let settings = EyebrowReshapeSettings(enabled: true, browTailLift: 0.30)
        let result = EyebrowReshapeEngine.apply(to: image, faces: [emptyFace], settings: settings)
        XCTAssertFalse(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 0)
        XCTAssertEqual(result.image.extent, image.extent)

        // Usable face but empty eyebrows (falls back to bounding box derived geometry)
        let faceWithoutBrows = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.9,
            faceContour: [
                CGPoint(x: 0.30, y: 0.70),
                CGPoint(x: 0.50, y: 0.20),
                CGPoint(x: 0.70, y: 0.70)
            ],
            leftEye: [CGPoint(x: 0.35, y: 0.60), CGPoint(x: 0.36, y: 0.61), CGPoint(x: 0.37, y: 0.60)],
            rightEye: [CGPoint(x: 0.65, y: 0.60), CGPoint(x: 0.66, y: 0.61), CGPoint(x: 0.67, y: 0.60)],
            leftEyebrow: [],
            rightEyebrow: [],
            nose: []
        )
        let resFallback = EyebrowReshapeEngine.apply(to: image, faces: [faceWithoutBrows], settings: settings)
        XCTAssertTrue(resFallback.report.applied)
        XCTAssertEqual(resFallback.report.faceCount, 1)
    }
}

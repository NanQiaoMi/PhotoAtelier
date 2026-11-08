import XCTest
import CoreImage
import CoreGraphics
@testable import PhotoCore

final class FacialContourTests: XCTestCase {

    // MARK: - Helpers

    private func makeTestFaceImage() -> (image: CIImage, face: FaceLandmarkSet) {
        let size = CGSize(width: 400, height: 400)
        let base = CIImage(color: CIColor(red: 0.85, green: 0.72, blue: 0.62, alpha: 1.0))
            .cropped(to: CGRect(origin: .zero, size: size))

        let contour: [CGPoint] = [
            CGPoint(x: 0.30, y: 0.72), // left temple
            CGPoint(x: 0.25, y: 0.52), // left zygoma peak
            CGPoint(x: 0.32, y: 0.38), // left cheek fossa / buccal hollow
            CGPoint(x: 0.38, y: 0.28), // left jawline
            CGPoint(x: 0.50, y: 0.22), // chin tip
            CGPoint(x: 0.62, y: 0.28), // right jawline
            CGPoint(x: 0.68, y: 0.38), // right cheek fossa / buccal hollow
            CGPoint(x: 0.75, y: 0.52), // right zygoma peak
            CGPoint(x: 0.70, y: 0.72)  // right temple
        ]

        let face = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60),
            confidence: 0.98,
            faceContour: contour,
            leftEye: [CGPoint(x: 0.38, y: 0.62)],
            rightEye: [CGPoint(x: 0.62, y: 0.62)],
            nose: [CGPoint(x: 0.50, y: 0.48)]
        )

        return (base, face)
    }

    // MARK: - 1. Neutral Settings & Defaults

    func testNeutralSettingsSkipWarp() {
        let (image, face) = makeTestFaceImage()
        let settings = FacialContourSettings()
        XCTAssertTrue(settings.isNeutral)

        let result = FacialContourEngine.apply(to: image, faces: [face], settings: settings)
        XCTAssertFalse(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 0)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 2. Temple Plumping

    func testTemplePlumpWarp() {
        let (image, face) = makeTestFaceImage()

        let settings = FacialContourSettings(enabled: true, templePlump: 0.65)
        let result = FacialContourEngine.apply(to: image, faces: [face], settings: settings)
        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 1)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 3. Cheekbone & Zygoma Narrowing

    func testCheekboneNarrowWarp() {
        let (image, face) = makeTestFaceImage()

        let settings = FacialContourSettings(enabled: true, cheekboneNarrow: 0.70)
        let result = FacialContourEngine.apply(to: image, faces: [face], settings: settings)
        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 1)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 4. Buccal Hollow & Cheek Plumping

    func testCheekPlumpWarp() {
        let (image, face) = makeTestFaceImage()

        let settings = FacialContourSettings(enabled: true, cheekPlump: 0.60)
        let result = FacialContourEngine.apply(to: image, faces: [face], settings: settings)
        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 1)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 5. Contour Curvature Smoothness

    func testContourSmoothnessWarp() {
        let (image, face) = makeTestFaceImage()

        let settings = FacialContourSettings(enabled: true, contourSmoothness: 0.80)
        let result = FacialContourEngine.apply(to: image, faces: [face], settings: settings)
        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 1)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 6. Apple Cheek Vertical Lift

    func testAppleCheekLiftWarp() {
        let (image, face) = makeTestFaceImage()

        // Positive lift: lifts and perks up apple cheeks
        let settingsLift = FacialContourSettings(enabled: true, appleCheekLift: 0.40)
        let resLift = FacialContourEngine.apply(to: image, faces: [face], settings: settingsLift)
        XCTAssertTrue(resLift.report.applied)
        XCTAssertEqual(resLift.report.faceCount, 1)
        XCTAssertEqual(resLift.image.extent, image.extent)

        // Negative lift: relaxes apple cheeks
        let settingsRelax = FacialContourSettings(enabled: true, appleCheekLift: -0.30)
        let resRelax = FacialContourEngine.apply(to: image, faces: [face], settings: settingsRelax)
        XCTAssertTrue(resRelax.report.applied)
        XCTAssertEqual(resRelax.report.faceCount, 1)
        XCTAssertEqual(resRelax.image.extent, image.extent)
    }

    // MARK: - 7. 3D Facial Contour Highlight & Micro-Shading

    func test3DContourHighlightAndShading() {
        let (image, face) = makeTestFaceImage()

        let settings3D = FacialContourSettings(enabled: true, contour3DShading: 0.75)
        let res3D = FacialContourEngine.apply(to: image, faces: [face], settings: settings3D)
        XCTAssertTrue(res3D.report.applied)
        XCTAssertEqual(res3D.report.faceCount, 1)
        XCTAssertEqual(res3D.image.extent, image.extent)

        // Direct guide mask generation
        let guide = FacialContourEngine.makeContour3DGuideMask(faces: [face], extent: image.extent)
        XCTAssertEqual(guide.extent, image.extent)
    }

    // MARK: - 8. Multi-Person Demographic Profile Override

    func testSinglePersonAndMultiPersonProfileOverride() {
        let (image, face) = makeTestFaceImage()
        let settings = FacialContourSettings(
            enabled: true,
            templePlump: 0.50,
            cheekboneNarrow: 0.40,
            cheekPlump: 0.30,
            contourSmoothness: 0.60
        )

        let perPersonResult = FacialContourEngine.applyPerPerson(
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

    // MARK: - 9. Recipe Version 31 Gate

    func testRecipeVersion31Gate() throws {
        var recipe = Recipe()
        recipe.adjustments.facialContour = FacialContourSettings(enabled: true, templePlump: 0.40)

        // Version 30 should fail loudly (cannot silently downgrade)
        recipe.version = 30
        XCTAssertThrowsError(try recipe.validateVersion())

        // Version 31 must pass
        recipe.version = 31
        XCTAssertNoThrow(try recipe.validateVersion())

        // Future version 33 should fail
        recipe.version = 33
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 33 is future unsupported")

        // PhotoEngine requiredRecipeVersion check
        let requiredVersion = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(requiredVersion, 31)
    }

    // MARK: - 10. Multi-Person FacialContour Override Requires Version 31

    func testMultiPersonFacialContourOverrideRequiresVersion31() throws {
        var recipe = Recipe()
        var multi = MultiPersonSettings(enabled: true)
        let profile = PersonPortraitProfile(
            faceIndex: 0,
            role: .femaleAdult,
            enabled: true,
            facialContourOverride: FacialContourSettings(enabled: true, cheekboneNarrow: 0.45)
        )
        multi.individualProfiles = [profile]
        recipe.adjustments.multiPerson = multi

        // Version 30 should fail
        recipe.version = 30
        XCTAssertThrowsError(try recipe.validateVersion())

        // Version 31 must succeed
        recipe.version = 31
        XCTAssertNoThrow(try recipe.validateVersion())

        let reqV = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(reqV, 31)
    }

    // MARK: - 11. Selective Sync

    func testSelectiveSyncFacialContour() {
        var source = AdjustmentSettings()
        source.facialContour = FacialContourSettings(
            enabled: true,
            templePlump: 0.45,
            cheekboneNarrow: 0.35,
            cheekPlump: 0.50,
            contourSmoothness: 0.60,
            appleCheekLift: 0.25,
            contour3DShading: 0.40
        )

        let target = AdjustmentSettings()

        // Sync with facialContour enabled
        var syncOptions = AdjustmentSyncOptions.none
        syncOptions.facialContour = true
        var targetLUT = ""
        let merged = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptions,
            sourceLUT: "",
            targetLUT: &targetLUT
        )
        XCTAssertNotNil(merged.facialContour)
        XCTAssertEqual(merged.facialContour?.templePlump, 0.45)
        XCTAssertEqual(merged.facialContour?.cheekboneNarrow, 0.35)
        XCTAssertEqual(merged.facialContour?.cheekPlump, 0.50)
        XCTAssertEqual(merged.facialContour?.contourSmoothness, 0.60)
        XCTAssertEqual(merged.facialContour?.appleCheekLift, 0.25)
        XCTAssertEqual(merged.facialContour?.contour3DShading, 0.40)

        // Sync with facialContour disabled
        syncOptions.facialContour = false
        let mergedDisabled = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptions,
            sourceLUT: "",
            targetLUT: &targetLUT
        )
        XCTAssertNil(mergedDisabled.facialContour)
    }

    // MARK: - 12. Parameter Validation

    func testValidationRanges() {
        var invalid = FacialContourSettings(enabled: true)
        invalid.templePlump = 1.4
        XCTAssertThrowsError(try invalid.validated())

        invalid = FacialContourSettings(enabled: true)
        invalid.templePlump = -0.2
        XCTAssertThrowsError(try invalid.validated())

        invalid = FacialContourSettings(enabled: true)
        invalid.cheekboneNarrow = 1.5
        XCTAssertThrowsError(try invalid.validated())

        invalid = FacialContourSettings(enabled: true)
        invalid.cheekPlump = -0.1
        XCTAssertThrowsError(try invalid.validated())

        invalid = FacialContourSettings(enabled: true)
        invalid.contourSmoothness = 1.2
        XCTAssertThrowsError(try invalid.validated())

        invalid = FacialContourSettings(enabled: true)
        invalid.appleCheekLift = 0.8
        XCTAssertThrowsError(try invalid.validated())

        invalid = FacialContourSettings(enabled: true)
        invalid.appleCheekLift = -0.9
        XCTAssertThrowsError(try invalid.validated())

        invalid = FacialContourSettings(enabled: true)
        invalid.contour3DShading = 1.5
        XCTAssertThrowsError(try invalid.validated())

        let valid = FacialContourSettings(
            enabled: true,
            templePlump: 0.50,
            cheekboneNarrow: 0.40,
            cheekPlump: 0.30,
            contourSmoothness: 0.60,
            appleCheekLift: 0.20,
            contour3DShading: 0.35
        )
        XCTAssertNoThrow(try valid.validated())
    }

    // MARK: - 13. Edge Case: Sparse or Empty Face Contour Handled Gracefully

    func testSparseContourHandledGracefully() {
        let (image, _) = makeTestFaceImage()
        let emptyFace = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.9,
            faceContour: [], // Empty contour
            leftEye: [],
            rightEye: [],
            nose: []
        )
        let settings = FacialContourSettings(enabled: true, cheekboneNarrow: 0.40)
        let result = FacialContourEngine.apply(to: image, faces: [emptyFace], settings: settings)
        XCTAssertFalse(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 0)
        XCTAssertEqual(result.image.extent, image.extent)

        // Minimal 3-point contour
        let minimalContourFace = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.9,
            faceContour: [
                CGPoint(x: 0.30, y: 0.70),
                CGPoint(x: 0.25, y: 0.50),
                CGPoint(x: 0.50, y: 0.20)
            ],
            leftEye: [CGPoint(x: 0.35, y: 0.60), CGPoint(x: 0.36, y: 0.61), CGPoint(x: 0.37, y: 0.60)],
            rightEye: [CGPoint(x: 0.65, y: 0.60), CGPoint(x: 0.66, y: 0.61), CGPoint(x: 0.67, y: 0.60)],
            nose: []
        )
        let resMinimal = FacialContourEngine.apply(to: image, faces: [minimalContourFace], settings: settings)
        XCTAssertTrue(resMinimal.report.applied)
        XCTAssertEqual(resMinimal.report.faceCount, 1)
    }
}

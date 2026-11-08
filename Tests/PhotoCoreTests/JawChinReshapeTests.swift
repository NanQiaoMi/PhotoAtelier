import XCTest
import CoreImage
import CoreGraphics
@testable import PhotoCore

final class JawChinReshapeTests: XCTestCase {

    // MARK: - Helpers

    private func makeTestFaceImage() -> (image: CIImage, face: FaceLandmarkSet) {
        let size = CGSize(width: 400, height: 400)
        let base = CIImage(color: CIColor(red: 0.85, green: 0.72, blue: 0.62, alpha: 1.0))
            .cropped(to: CGRect(origin: .zero, size: size))

        let contour: [CGPoint] = [
            CGPoint(x: 0.22, y: 0.65), // upper left jaw / earlobe
            CGPoint(x: 0.24, y: 0.50), // left cheek
            CGPoint(x: 0.28, y: 0.36), // left gonial angle (jaw corner)
            CGPoint(x: 0.38, y: 0.26), // left lower jawline
            CGPoint(x: 0.50, y: 0.22), // chin tip (gnathion / mentum)
            CGPoint(x: 0.62, y: 0.26), // right lower jawline
            CGPoint(x: 0.72, y: 0.36), // right gonial angle (jaw corner)
            CGPoint(x: 0.76, y: 0.50), // right cheek
            CGPoint(x: 0.78, y: 0.65)  // upper right jaw / earlobe
        ]

        let face = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60),
            confidence: 0.98,
            faceContour: contour,
            leftEye: [CGPoint(x: 0.35, y: 0.60)],
            rightEye: [CGPoint(x: 0.65, y: 0.60)],
            nose: [CGPoint(x: 0.50, y: 0.48)]
        )

        return (base, face)
    }

    // MARK: - 1. Neutral Settings & Defaults

    func testNeutralSettingsSkipWarp() {
        let (image, face) = makeTestFaceImage()
        let settings = JawChinReshapeSettings()
        XCTAssertTrue(settings.isNeutral)

        let result = JawChinReshapeEngine.apply(to: image, faces: [face], settings: settings)
        XCTAssertFalse(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 0)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 2. Narrow & Broaden Jaw Angle

    func testNarrowAndBroadenJawWidthWarp() {
        let (image, face) = makeTestFaceImage()

        // Narrow jaw angle (negative value: softens square jaw)
        let settingsNarrow = JawChinReshapeSettings(enabled: true, jawWidth: -0.40)
        let resNarrow = JawChinReshapeEngine.apply(to: image, faces: [face], settings: settingsNarrow)
        XCTAssertTrue(resNarrow.report.applied)
        XCTAssertEqual(resNarrow.report.faceCount, 1)
        XCTAssertEqual(resNarrow.image.extent, image.extent)

        // Broaden jaw angle (positive value: adds bone structure)
        let settingsBroad = JawChinReshapeSettings(enabled: true, jawWidth: 0.35)
        let resBroad = JawChinReshapeEngine.apply(to: image, faces: [face], settings: settingsBroad)
        XCTAssertTrue(resBroad.report.applied)
        XCTAssertEqual(resBroad.report.faceCount, 1)
        XCTAssertEqual(resBroad.image.extent, image.extent)
    }

    // MARK: - 3. Chin Length Shorten & Lengthen

    func testChinLengthShortenAndLengthen() {
        let (image, face) = makeTestFaceImage()

        // Shorten long chin (negative value: pulls upward)
        let settingsShort = JawChinReshapeSettings(enabled: true, chinLength: -0.40)
        let resShort = JawChinReshapeEngine.apply(to: image, faces: [face], settings: settingsShort)
        XCTAssertTrue(resShort.report.applied)
        XCTAssertEqual(resShort.report.faceCount, 1)
        XCTAssertEqual(resShort.image.extent, image.extent)

        // Lengthen short chin (positive value: extends downward)
        let settingsLong = JawChinReshapeSettings(enabled: true, chinLength: 0.40)
        let resLong = JawChinReshapeEngine.apply(to: image, faces: [face], settings: settingsLong)
        XCTAssertTrue(resLong.report.applied)
        XCTAssertEqual(resLong.report.faceCount, 1)
        XCTAssertEqual(resLong.image.extent, image.extent)
    }

    // MARK: - 4. Chin Projection & Forward Perkiness

    func testChinProjectionPerkiness() {
        let (image, face) = makeTestFaceImage()

        // Project chin forward/upward (positive value: resolves recessed chin)
        let settingsProj = JawChinReshapeSettings(enabled: true, chinProjection: 0.45)
        let resProj = JawChinReshapeEngine.apply(to: image, faces: [face], settings: settingsProj)
        XCTAssertTrue(resProj.report.applied)
        XCTAssertEqual(resProj.report.faceCount, 1)
        XCTAssertEqual(resProj.image.extent, image.extent)

        // Soften prominent chin (negative value)
        let settingsSoften = JawChinReshapeSettings(enabled: true, chinProjection: -0.30)
        let resSoften = JawChinReshapeEngine.apply(to: image, faces: [face], settings: settingsSoften)
        XCTAssertTrue(resSoften.report.applied)
        XCTAssertEqual(resSoften.report.faceCount, 1)
    }

    // MARK: - 5. Chin Shape Sculpting (V-Line vs Round)

    func testChinShapeVLineAndRound() {
        let (image, face) = makeTestFaceImage()

        // V-line chin (negative value: tapers bilateral slopes inward)
        let settingsVLine = JawChinReshapeSettings(enabled: true, chinShape: -0.45)
        let resVLine = JawChinReshapeEngine.apply(to: image, faces: [face], settings: settingsVLine)
        XCTAssertTrue(resVLine.report.applied)
        XCTAssertEqual(resVLine.report.faceCount, 1)
        XCTAssertEqual(resVLine.image.extent, image.extent)

        // Round youthful chin (positive value: rounds out chin curve)
        let settingsRound = JawChinReshapeSettings(enabled: true, chinShape: 0.40)
        let resRound = JawChinReshapeEngine.apply(to: image, faces: [face], settings: settingsRound)
        XCTAssertTrue(resRound.report.applied)
        XCTAssertEqual(resRound.report.faceCount, 1)
        XCTAssertEqual(resRound.image.extent, image.extent)
    }

    // MARK: - 6. Mandibular Jawline Tightening

    func testJawlineTightenWarp() {
        let (image, face) = makeTestFaceImage()

        let settingsTighten = JawChinReshapeSettings(enabled: true, jawlineTighten: 0.70)
        let resTighten = JawChinReshapeEngine.apply(to: image, faces: [face], settings: settingsTighten)
        XCTAssertTrue(resTighten.report.applied)
        XCTAssertEqual(resTighten.report.faceCount, 1)
        XCTAssertEqual(resTighten.image.extent, image.extent)
    }

    // MARK: - 7. 3D Chin Specular Highlight & Submental Shading

    func test3DChinContourHighlightAndShading() {
        let (image, face) = makeTestFaceImage()

        let settings3D = JawChinReshapeSettings(enabled: true, chinContour: 0.85)
        let res3D = JawChinReshapeEngine.apply(to: image, faces: [face], settings: settings3D)
        XCTAssertTrue(res3D.report.applied)
        XCTAssertEqual(res3D.report.faceCount, 1)
        XCTAssertEqual(res3D.image.extent, image.extent)

        // Direct guide mask test
        let guide = JawChinReshapeEngine.makeChin3DGuideMask(faces: [face], extent: image.extent)
        XCTAssertEqual(guide.extent, image.extent)
    }

    // MARK: - 8. Multi-Person Demographic Profile Override

    func testSinglePersonAndMultiPersonProfileOverride() {
        let (image, face) = makeTestFaceImage()
        let settings = JawChinReshapeSettings(
            enabled: true,
            jawWidth: -0.30,
            chinShape: -0.40,
            jawlineTighten: 0.60
        )

        let perPersonResult = JawChinReshapeEngine.applyPerPerson(
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

    // MARK: - 9. Recipe Version 30 Gate

    func testRecipeVersion30Gate() throws {
        var recipe = Recipe()
        recipe.adjustments.jawChinReshape = JawChinReshapeSettings(enabled: true, jawWidth: -0.30)

        // Version 29 should fail loudly (cannot silently downgrade)
        recipe.version = 29
        XCTAssertThrowsError(try recipe.validateVersion())

        // Version 30 must pass
        recipe.version = 30
        XCTAssertNoThrow(try recipe.validateVersion())

        // Future version 32 should fail
        recipe.version = 32
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 32 is future unsupported")

        // PhotoEngine requiredRecipeVersion check
        let requiredVersion = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(requiredVersion, 30)
    }

    // MARK: - 10. Multi-Person JawChinReshape Override Requires Version 30

    func testMultiPersonJawChinReshapeOverrideRequiresVersion30() throws {
        var recipe = Recipe()
        var multi = MultiPersonSettings(enabled: true)
        let profile = PersonPortraitProfile(
            faceIndex: 0,
            role: .femaleAdult,
            enabled: true,
            jawChinReshapeOverride: JawChinReshapeSettings(enabled: true, chinShape: -0.35)
        )
        multi.individualProfiles = [profile]
        recipe.adjustments.multiPerson = multi

        // Version 29 should fail
        recipe.version = 29
        XCTAssertThrowsError(try recipe.validateVersion())

        // Version 30 must succeed
        recipe.version = 30
        XCTAssertNoThrow(try recipe.validateVersion())

        let reqV = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(reqV, 30)
    }

    // MARK: - 11. Selective Sync

    func testSelectiveSyncJawChinReshape() {
        var source = AdjustmentSettings()
        source.jawChinReshape = JawChinReshapeSettings(
            enabled: true,
            jawWidth: -0.40,
            chinLength: 0.30,
            chinShape: -0.25,
            jawlineTighten: 0.50
        )

        let target = AdjustmentSettings()

        // Sync with jawChinReshape enabled
        var syncOptions = AdjustmentSyncOptions.none
        syncOptions.jawChinReshape = true
        var targetLUT = ""
        let merged = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptions,
            sourceLUT: "",
            targetLUT: &targetLUT
        )
        XCTAssertNotNil(merged.jawChinReshape)
        XCTAssertEqual(merged.jawChinReshape?.jawWidth, -0.40)
        XCTAssertEqual(merged.jawChinReshape?.chinLength, 0.30)
        XCTAssertEqual(merged.jawChinReshape?.chinShape, -0.25)
        XCTAssertEqual(merged.jawChinReshape?.jawlineTighten, 0.50)

        // Sync with jawChinReshape disabled
        syncOptions.jawChinReshape = false
        let mergedDisabled = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptions,
            sourceLUT: "",
            targetLUT: &targetLUT
        )
        XCTAssertNil(mergedDisabled.jawChinReshape)
    }

    // MARK: - 12. Parameter Validation

    func testValidationRanges() {
        var invalid = JawChinReshapeSettings(enabled: true)
        invalid.jawWidth = 0.8
        XCTAssertThrowsError(try invalid.validated())

        invalid = JawChinReshapeSettings(enabled: true)
        invalid.jawWidth = -0.9
        XCTAssertThrowsError(try invalid.validated())

        invalid = JawChinReshapeSettings(enabled: true)
        invalid.chinLength = 0.7
        XCTAssertThrowsError(try invalid.validated())

        invalid = JawChinReshapeSettings(enabled: true)
        invalid.chinProjection = -0.8
        XCTAssertThrowsError(try invalid.validated())

        invalid = JawChinReshapeSettings(enabled: true)
        invalid.chinShape = 0.9
        XCTAssertThrowsError(try invalid.validated())

        invalid = JawChinReshapeSettings(enabled: true)
        invalid.jawlineTighten = 1.4
        XCTAssertThrowsError(try invalid.validated())

        invalid = JawChinReshapeSettings(enabled: true)
        invalid.jawlineTighten = -0.2
        XCTAssertThrowsError(try invalid.validated())

        invalid = JawChinReshapeSettings(enabled: true)
        invalid.chinContour = 1.3
        XCTAssertThrowsError(try invalid.validated())

        let valid = JawChinReshapeSettings(
            enabled: true,
            jawWidth: -0.35,
            chinLength: 0.20,
            chinProjection: 0.25,
            chinShape: -0.30,
            jawlineTighten: 0.60,
            chinContour: 0.50
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
        let settings = JawChinReshapeSettings(enabled: true, jawWidth: -0.30)
        let result = JawChinReshapeEngine.apply(to: image, faces: [emptyFace], settings: settings)
        XCTAssertFalse(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 0)
        XCTAssertEqual(result.image.extent, image.extent)

        // Minimal 3-point contour
        let minimalContourFace = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            confidence: 0.9,
            faceContour: [
                CGPoint(x: 0.30, y: 0.40),
                CGPoint(x: 0.50, y: 0.20),
                CGPoint(x: 0.70, y: 0.40)
            ],
            leftEye: [CGPoint(x: 0.35, y: 0.60), CGPoint(x: 0.36, y: 0.61), CGPoint(x: 0.37, y: 0.60)],
            rightEye: [CGPoint(x: 0.65, y: 0.60), CGPoint(x: 0.66, y: 0.61), CGPoint(x: 0.67, y: 0.60)],
            nose: []
        )
        let resMinimal = JawChinReshapeEngine.apply(to: image, faces: [minimalContourFace], settings: settings)
        XCTAssertTrue(resMinimal.report.applied)
        XCTAssertEqual(resMinimal.report.faceCount, 1)
    }
}

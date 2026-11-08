import XCTest
import CoreImage
import CoreGraphics
@testable import PhotoCore

final class FacialBoneContourTests: XCTestCase {

    // MARK: - Helpers

    private func makeTestFaceImage() -> (image: CIImage, face: FaceLandmarkSet) {
        let size = CGSize(width: 400, height: 400)
        let base = CIImage(color: CIColor(red: 0.82, green: 0.70, blue: 0.60, alpha: 1.0))
            .cropped(to: CGRect(origin: .zero, size: size))

        let contour: [CGPoint] = [
            CGPoint(x: 0.28, y: 0.72), // left temple
            CGPoint(x: 0.25, y: 0.52), // left zygoma
            CGPoint(x: 0.32, y: 0.38), // left cheek
            CGPoint(x: 0.38, y: 0.24), // left jaw angle
            CGPoint(x: 0.45, y: 0.16),
            CGPoint(x: 0.50, y: 0.14), // chin
            CGPoint(x: 0.55, y: 0.16),
            CGPoint(x: 0.62, y: 0.24), // right jaw angle
            CGPoint(x: 0.68, y: 0.38), // right cheek
            CGPoint(x: 0.75, y: 0.52), // right zygoma
            CGPoint(x: 0.72, y: 0.72)  // right temple
        ]

        let face = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.20, y: 0.12, width: 0.60, height: 0.65),
            confidence: 0.98,
            faceContour: contour,
            leftEye: [CGPoint(x: 0.38, y: 0.62), CGPoint(x: 0.42, y: 0.62)],
            rightEye: [CGPoint(x: 0.58, y: 0.62), CGPoint(x: 0.62, y: 0.62)],
            leftEyebrow: [CGPoint(x: 0.30, y: 0.70), CGPoint(x: 0.42, y: 0.72)],
            rightEyebrow: [CGPoint(x: 0.58, y: 0.72), CGPoint(x: 0.70, y: 0.70)],
            nose: [CGPoint(x: 0.50, y: 0.58), CGPoint(x: 0.50, y: 0.44)],
            outerLips: [CGPoint(x: 0.45, y: 0.34), CGPoint(x: 0.50, y: 0.36), CGPoint(x: 0.55, y: 0.34)]
        )

        return (base, face)
    }

    private func renderPixel(_ image: CIImage, at point: CGPoint) -> (r: Double, g: Double, b: Double) {
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        var pixel: [UInt8] = [0, 0, 0, 0]
        let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: rect, format: .RGBA8, colorSpace: nil)
        return (Double(pixel[0]) / 255.0, Double(pixel[1]) / 255.0, Double(pixel[2]) / 255.0)
    }

    // MARK: - 1. Neutral Settings & Defaults

    func testNeutralSettingsSkipShading() {
        let (image, face) = makeTestFaceImage()
        let settings = FacialBoneContourSettings()
        XCTAssertTrue(settings.isNeutral)

        let result = FacialBoneContourEngine.apply(to: image, faces: [face], settings: settings)
        XCTAssertFalse(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 0)
        XCTAssertEqual(result.image.extent, image.extent)
    }

    // MARK: - 2. T-Zone Specular Highlight

    func testTZoneHighlightShading() {
        let (image, face) = makeTestFaceImage()
        let settings = FacialBoneContourSettings(enabled: true, tZoneHighlight: 0.85)
        let result = FacialBoneContourEngine.apply(to: image, faces: [face], settings: settings)

        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 1)

        // Midline nose bridge pixel (x=200, y=200) should increase in luminance
        let before = renderPixel(image, at: CGPoint(x: 200, y: 200))
        let after = renderPixel(result.image, at: CGPoint(x: 200, y: 200))
        XCTAssertGreaterThan(after.r, before.r)
        XCTAssertGreaterThan(after.g, before.g)
    }

    // MARK: - 3. C-Zone Highlight

    func testCZoneHighlightShading() {
        let (image, face) = makeTestFaceImage()
        let settings = FacialBoneContourSettings(enabled: true, cZoneHighlight: 0.85)
        let result = FacialBoneContourEngine.apply(to: image, faces: [face], settings: settings)

        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 1)

        // Lateral C-zone orbit pixel (x=130, y=240) should increase in luminance
        let before = renderPixel(image, at: CGPoint(x: 130, y: 240))
        let after = renderPixel(result.image, at: CGPoint(x: 130, y: 240))
        XCTAssertGreaterThan(after.r, before.r)
    }

    // MARK: - 4. Sub-zygomatic Cheek Contour Shadow

    func testCheekContourShadowShading() {
        let (image, face) = makeTestFaceImage()
        let settings = FacialBoneContourSettings(enabled: true, cheekContourShadow: 0.80)
        let result = FacialBoneContourEngine.apply(to: image, faces: [face], settings: settings)

        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 1)

        // Left sub-zygomatic cheek hollow pixel (x=135, y=160) should decrease in luminance
        let before = renderPixel(image, at: CGPoint(x: 135, y: 160))
        let after = renderPixel(result.image, at: CGPoint(x: 135, y: 160))
        XCTAssertLessThan(after.r, before.r)
    }

    // MARK: - 5. Mandibular Jawline Shadow

    func testJawlineShadowShading() {
        let (image, face) = makeTestFaceImage()
        let settings = FacialBoneContourSettings(enabled: true, jawlineShadow: 0.85)
        let result = FacialBoneContourEngine.apply(to: image, faces: [face], settings: settings)

        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 1)

        // Sub-mandibular neck pixel (x=200, y=55) should decrease in luminance
        let before = renderPixel(image, at: CGPoint(x: 200, y: 55))
        let after = renderPixel(result.image, at: CGPoint(x: 200, y: 55))
        XCTAssertLessThan(after.r, before.r)
    }

    // MARK: - 6. Facial Folding Angle

    func testFacialFoldingShading() {
        let (image, face) = makeTestFaceImage()
        let settings = FacialBoneContourSettings(enabled: true, facialFolding: 0.80)
        let result = FacialBoneContourEngine.apply(to: image, faces: [face], settings: settings)

        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 1)

        // Lateral flank (x=115, y=200) should be darkened (falloff)
        let lateralBefore = renderPixel(image, at: CGPoint(x: 115, y: 200))
        let lateralAfter = renderPixel(result.image, at: CGPoint(x: 115, y: 200))
        XCTAssertLessThan(lateralAfter.r, lateralBefore.r)

        // Midline (x=200, y=200) should have forward axial prominence boost
        let centerBefore = renderPixel(image, at: CGPoint(x: 200, y: 200))
        let centerAfter = renderPixel(result.image, at: CGPoint(x: 200, y: 200))
        XCTAssertGreaterThan(centerAfter.r, centerBefore.r)
    }

    // MARK: - 7. Philtrum & Cupid's Bow Highlight

    func testPhiltrumHighlightShading() {
        let (image, face) = makeTestFaceImage()
        let settings = FacialBoneContourSettings(enabled: true, philtrumHighlight: 0.90)
        let result = FacialBoneContourEngine.apply(to: image, faces: [face], settings: settings)

        XCTAssertTrue(result.report.applied)
        XCTAssertEqual(result.report.faceCount, 1)

        // Philtrum column pixel (x=200, y=160) should increase in luminance
        let before = renderPixel(image, at: CGPoint(x: 200, y: 160))
        let after = renderPixel(result.image, at: CGPoint(x: 200, y: 160))
        XCTAssertGreaterThan(after.r, before.r)
    }

    // MARK: - 8. Warmth Modulation

    func testContourToneWarmthModulation() {
        let (image, face) = makeTestFaceImage()
        let warmSettings = FacialBoneContourSettings(enabled: true, tZoneHighlight: 0.8, contourToneWarmth: 0.45)
        let coolSettings = FacialBoneContourSettings(enabled: true, tZoneHighlight: 0.8, contourToneWarmth: -0.45)

        let warmResult = FacialBoneContourEngine.apply(to: image, faces: [face], settings: warmSettings)
        let coolResult = FacialBoneContourEngine.apply(to: image, faces: [face], settings: coolSettings)

        let warmPixel = renderPixel(warmResult.image, at: CGPoint(x: 200, y: 200))
        let coolPixel = renderPixel(coolResult.image, at: CGPoint(x: 200, y: 200))

        // Warm setting has higher Red/Blue ratio than cool setting
        let warmRB = warmPixel.r / max(0.001, warmPixel.b)
        let coolRB = coolPixel.r / max(0.001, coolPixel.b)
        XCTAssertGreaterThan(warmRB, coolRB)
    }

    // MARK: - 9. Sparse or Missing Landmarks Handled Gracefully

    func testSparseOrEmptyFaceHandledGracefully() {
        let size = CGSize(width: 400, height: 400)
        let base = CIImage(color: CIColor(red: 0.8, green: 0.7, blue: 0.6, alpha: 1.0))
            .cropped(to: CGRect(origin: .zero, size: size))

        // 1. Completely empty landmarks (no usable geometry)
        let emptyFace = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            confidence: 0.90,
            faceContour: [],
            leftEye: [],
            rightEye: []
        )

        let settings = FacialBoneContourSettings(
            enabled: true,
            facialFolding: 0.5,
            tZoneHighlight: 0.5,
            cZoneHighlight: 0.5,
            cheekContourShadow: 0.5,
            jawlineShadow: 0.5,
            philtrumHighlight: 0.5
        )

        let emptyResult = FacialBoneContourEngine.apply(to: base, faces: [emptyFace], settings: settings)
        XCTAssertFalse(emptyResult.report.applied)
        XCTAssertEqual(emptyResult.report.faceCount, 0)
        XCTAssertEqual(emptyResult.image.extent, base.extent)

        // 2. Usable geometry on contour but missing eyebrows/lips (falls back to bounding box derived geometry)
        let partialFace = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60),
            confidence: 0.95,
            faceContour: [
                CGPoint(x: 0.30, y: 0.70),
                CGPoint(x: 0.25, y: 0.50),
                CGPoint(x: 0.50, y: 0.20),
                CGPoint(x: 0.75, y: 0.50),
                CGPoint(x: 0.70, y: 0.70)
            ],
            leftEye: [],
            rightEye: [],
            leftEyebrow: [],
            rightEyebrow: [],
            nose: [],
            outerLips: []
        )

        let partialResult = FacialBoneContourEngine.apply(to: base, faces: [partialFace], settings: settings)
        XCTAssertTrue(partialResult.report.applied)
        XCTAssertEqual(partialResult.report.faceCount, 1)
        XCTAssertEqual(partialResult.image.extent, base.extent)
    }

    // MARK: - 10. Validation Ranges

    func testValidationRanges() {
        var settings = FacialBoneContourSettings()
        XCTAssertNoThrow(try settings.validated())

        settings.facialFolding = 1.2
        XCTAssertThrowsError(try settings.validated())
        settings.facialFolding = 0.5

        settings.tZoneHighlight = -0.1
        XCTAssertThrowsError(try settings.validated())
        settings.tZoneHighlight = 0.5

        settings.cZoneHighlight = 1.5
        XCTAssertThrowsError(try settings.validated())
        settings.cZoneHighlight = 0.5

        settings.cheekContourShadow = 1.5
        XCTAssertThrowsError(try settings.validated())
        settings.cheekContourShadow = 0.5

        settings.jawlineShadow = -0.5
        XCTAssertThrowsError(try settings.validated())
        settings.jawlineShadow = 0.5

        settings.philtrumHighlight = 1.1
        XCTAssertThrowsError(try settings.validated())
        settings.philtrumHighlight = 0.5

        settings.contourToneWarmth = 0.8
        XCTAssertThrowsError(try settings.validated())
        settings.contourToneWarmth = -0.3
        XCTAssertNoThrow(try settings.validated())
    }

    // MARK: - 11. Recipe Version 33 Gate

    func testRecipeVersion33Gate() throws {
        var recipe = Recipe()
        recipe.adjustments.facialBoneContour = FacialBoneContourSettings(enabled: true, tZoneHighlight: 0.6)

        // Version 32 must fail
        recipe.version = 32
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 32 cannot encode non-neutral facialBoneContour")

        // Version 33 must pass
        recipe.version = 33
        XCTAssertNoThrow(try recipe.validateVersion())

        // Future version 34 should fail
        recipe.version = 34
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 34 is future unsupported")

        // PhotoEngine requiredRecipeVersion check
        let requiredVersion = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(requiredVersion, 33)
    }

    // MARK: - 12. Multi-Person FacialBoneContour Override Requires Version 33

    func testMultiPersonFacialBoneContourOverrideRequiresVersion33() throws {
        var recipe = Recipe()
        var profile = PersonPortraitProfile(role: .femaleAdult)
        profile.facialBoneContourOverride = FacialBoneContourSettings(enabled: true, cZoneHighlight: 0.7)
        recipe.adjustments.multiPerson = MultiPersonSettings(
            enabled: true,
            individualProfiles: [profile]
        )

        // Version 32 must fail
        recipe.version = 32
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 32 cannot encode multi-person facialBoneContourOverride")

        // Version 33 must succeed
        recipe.version = 33
        XCTAssertNoThrow(try recipe.validateVersion(), "Version 33 must encode multi-person facialBoneContourOverride")

        let reqV = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(reqV, 33)
    }

    // MARK: - 13. Single Person and Multi-Person Profile Override

    func testSinglePersonAndMultiPersonProfileOverride() {
        let (image, face) = makeTestFaceImage()
        let overrideSettings = FacialBoneContourSettings(enabled: true, tZoneHighlight: 0.75)

        let (outImage, report) = FacialBoneContourEngine.applyPerPerson(
            to: image,
            face: face,
            faceIndex: 0,
            settings: overrideSettings,
            perFaceMask: nil
        )

        XCTAssertTrue(report.applied)
        XCTAssertEqual(outImage.extent, image.extent)
    }

    // MARK: - 14. Selective Sync

    func testSelectiveSyncFacialBoneContour() {
        var source = AdjustmentSettings()
        source.facialBoneContour = FacialBoneContourSettings(
            enabled: true,
            facialFolding: 0.7,
            tZoneHighlight: 0.6,
            cZoneHighlight: 0.5,
            cheekContourShadow: 0.4,
            jawlineShadow: 0.3,
            philtrumHighlight: 0.2,
            contourToneWarmth: 0.1
        )

        let target = AdjustmentSettings()
        var options = AdjustmentSyncOptions.none
        options.facialBoneContour = true
        var targetLUT = ""
        let merged = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: options,
            sourceLUT: "",
            targetLUT: &targetLUT
        )
        XCTAssertEqual(merged.facialBoneContour, source.facialBoneContour)

        // When option is false, target remains untouched
        var options2 = AdjustmentSyncOptions.none
        options2.facialBoneContour = false
        var targetLUT2 = ""
        let merged2 = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: options2,
            sourceLUT: "",
            targetLUT: &targetLUT2
        )
        XCTAssertNil(merged2.facialBoneContour)
    }
}

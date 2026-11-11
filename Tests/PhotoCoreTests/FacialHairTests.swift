import XCTest
import CoreImage
import CoreGraphics
@testable import PhotoCore

final class FacialHairTests: XCTestCase {

    // MARK: - Helpers

    private func makeSyntheticFace() -> (image: CIImage, face: FaceLandmarkSet) {
        let width = 400
        let height = 400
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        // Warm clean skin base: R=0.82, G=0.64, B=0.55
        let baseImage = CIImage(color: CIColor(red: 0.82, green: 0.64, blue: 0.55)).cropped(to: extent)

        // Landmarks in normalized bottom-left coordinates
        // Face center ~ (0.5, 0.5), box ~ (0.2, 0.2, 0.6, 0.6)
        let box = CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60)
        let outerLips = [
            CGPoint(x: 0.40, y: 0.40),
            CGPoint(x: 0.50, y: 0.43),
            CGPoint(x: 0.60, y: 0.40),
            CGPoint(x: 0.50, y: 0.37)
        ]
        let nose = [
            CGPoint(x: 0.48, y: 0.52),
            CGPoint(x: 0.50, y: 0.50),
            CGPoint(x: 0.52, y: 0.52)
        ]
        let contour = [
            CGPoint(x: 0.25, y: 0.55),
            CGPoint(x: 0.28, y: 0.35),
            CGPoint(x: 0.35, y: 0.25),
            CGPoint(x: 0.50, y: 0.22), // Chin
            CGPoint(x: 0.65, y: 0.25),
            CGPoint(x: 0.72, y: 0.35),
            CGPoint(x: 0.75, y: 0.55)
        ]

        let face = FaceLandmarkSet(
            boundingBox: box,
            confidence: 0.98,
            faceContour: contour,
            nose: nose,
            outerLips: outerLips
        )
        return (baseImage, face)
    }

    private func samplePixel(image: CIImage, at point: CGPoint) -> (r: Float, g: Float, b: Float) {
        let ctx = CIContext()
        var pixel: [Float] = [0, 0, 0, 0]
        let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        ctx.render(image, toBitmap: &pixel, rowBytes: 16, bounds: rect, format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (pixel[0], pixel[1], pixel[2])
    }

    // MARK: - Tests

    func testNeutralityAndDefaults() {
        let def = FacialHairSettings()
        XCTAssertFalse(def.enabled)
        XCTAssertTrue(def.isNeutral)
        XCTAssertEqual(def.moleManagement, .preserve)

        var custom = FacialHairSettings(enabled: true, lipFuzzRemoval: 0.0, moleManagement: .preserve)
        XCTAssertTrue(custom.isNeutral)

        custom.lipFuzzRemoval = 0.5
        XCTAssertFalse(custom.isNeutral)

        let clamped = FacialHairSettings(
            enabled: true,
            lipFuzzRemoval: 1.5,
            beardShadowReduction: -0.5,
            stubbleSmoothing: 2.0,
            moleManagement: .remove,
            moleRemovalIntensity: 1.2
        )
        XCTAssertEqual(clamped.lipFuzzRemoval, 1.0)
        XCTAssertEqual(clamped.beardShadowReduction, 0.0)
        XCTAssertEqual(clamped.stubbleSmoothing, 1.0)
        XCTAssertEqual(clamped.moleRemovalIntensity, 1.0)
    }

    func testNeutralSkipsProcessing() {
        let (image, face) = makeSyntheticFace()
        let neutral = FacialHairSettings(enabled: false)
        let res = FacialHairEngine.apply(to: image, faces: [face], settings: neutral)
        XCTAssertFalse(res.report.applied)
        XCTAssertEqual(res.image, image)
    }

    func testValidationBounds() {
        var s = FacialHairSettings(enabled: true)
        XCTAssertNoThrow(try s.validated())

        s.lipFuzzRemoval = 1.2
        XCTAssertThrowsError(try s.validated())

        s.lipFuzzRemoval = 0.5
        s.beardShadowReduction = -0.1
        XCTAssertThrowsError(try s.validated())

        s.beardShadowReduction = 0.5
        s.stubbleSmoothing = .nan
        XCTAssertThrowsError(try s.validated())
    }

    func testLipFuzzRemovalLightensUpperLipFuzz() {
        let (baseImage, face) = makeSyntheticFace()

        // Place a dark filament/micro-spot in the upper lip philtrum (x: 200, y: 185)
        let spotX: CGFloat = 200
        let spotY: CGFloat = 185
        let spotColor = CIImage(color: CIColor(red: 0.25, green: 0.18, blue: 0.15)).cropped(to: CGRect(x: spotX - 1, y: spotY - 1, width: 3, height: 3))
        let imageWithFuzz = spotColor.composited(over: baseImage)

        let before = samplePixel(image: imageWithFuzz, at: CGPoint(x: spotX, y: spotY))
        XCTAssertLessThan(before.r, 0.40, "Before processing, upper lip spot should be dark")

        let settings = FacialHairSettings(
            enabled: true,
            lipFuzzRemoval: 0.85
        )
        let result = FacialHairEngine.apply(to: imageWithFuzz, faces: [face], settings: settings)
        XCTAssertTrue(result.report.applied)

        let after = samplePixel(image: result.image, at: CGPoint(x: spotX, y: spotY))
        XCTAssertGreaterThan(after.r, before.r, "Peach fuzz removal should significantly lighten the dark hair spot")
    }

    func testBeardShadowReductionWarmsAndLightensBeardArea() {
        let (baseImage, face) = makeSyntheticFace()

        // Create cold bluish shadow on chin (x: 200, y: 110)
        let chinX: CGFloat = 200
        let chinY: CGFloat = 110
        let coldShadow = CIImage(color: CIColor(red: 0.45, green: 0.45, blue: 0.58)).cropped(to: CGRect(x: 170, y: 95, width: 60, height: 30))
        let imageWithShadow = coldShadow.composited(over: baseImage)

        let before = samplePixel(image: imageWithShadow, at: CGPoint(x: chinX, y: chinY))
        let beforeBlueCast = before.b - (before.r * 0.5 + before.g * 0.5)
        XCTAssertGreaterThan(beforeBlueCast, 0.05, "Before processing, chin area should exhibit cold blue cast")

        let settings = FacialHairSettings(
            enabled: true,
            beardShadowReduction: 0.90
        )
        let result = FacialHairEngine.apply(to: imageWithShadow, faces: [face], settings: settings)
        XCTAssertTrue(result.report.applied)

        let after = samplePixel(image: result.image, at: CGPoint(x: chinX, y: chinY))
        XCTAssertGreaterThan(after.r, before.r, "Beard shadow correction should warm up red channel")
        let afterBlueCast = after.b - (after.r * 0.5 + after.g * 0.5)
        XCTAssertLessThan(afterBlueCast, beforeBlueCast, "Beard shadow correction should suppress cold blue cast")
    }

    func testStubbleSmoothingSuppressesHighFreqSpeckles() {
        let (baseImage, face) = makeSyntheticFace()

        // Place dark stubble dot on jawline (x: 150, y: 130)
        let stubbleX: CGFloat = 150
        let stubbleY: CGFloat = 130
        let stubbleDot = CIImage(color: CIColor(red: 0.15, green: 0.12, blue: 0.10)).cropped(to: CGRect(x: stubbleX - 1, y: stubbleY - 1, width: 2, height: 2))
        let imageWithStubble = stubbleDot.composited(over: baseImage)

        let before = samplePixel(image: imageWithStubble, at: CGPoint(x: stubbleX, y: stubbleY))
        XCTAssertLessThan(before.r, 0.30)

        let settings = FacialHairSettings(
            enabled: true,
            stubbleSmoothing: 0.90
        )
        let result = FacialHairEngine.apply(to: imageWithStubble, faces: [face], settings: settings)
        XCTAssertTrue(result.report.applied)

        let after = samplePixel(image: result.image, at: CGPoint(x: stubbleX, y: stubbleY))
        XCTAssertGreaterThan(after.r, before.r, "Stubble smoothing should suppress dark speckle")
    }

    func testMoleManagementPreserveSoftenRemove() {
        let (baseImage, face) = makeSyntheticFace()

        // Place a dark compact beauty mark / mole on cheek (x: 230, y: 220)
        let moleX: CGFloat = 230
        let moleY: CGFloat = 220
        let moleDot = CIImage(color: CIColor(red: 0.12, green: 0.08, blue: 0.07)).cropped(to: CGRect(x: moleX - 1, y: moleY - 1, width: 3, height: 3))
        let imageWithMole = moleDot.composited(over: baseImage)

        let before = samplePixel(image: imageWithMole, at: CGPoint(x: moleX, y: moleY))
        XCTAssertLessThan(before.r, 0.25)

        // 1. Preserve mode (default): should NOT modify mole
        let preserveSettings = FacialHairSettings(
            enabled: true,
            moleManagement: .preserve,
            moleRemovalIntensity: 0.8
        )
        let preserveRes = FacialHairEngine.apply(to: imageWithMole, faces: [face], settings: preserveSettings)
        let preservePixel = samplePixel(image: preserveRes.image, at: CGPoint(x: moleX, y: moleY))
        XCTAssertEqual(preservePixel.r, before.r, accuracy: 0.02, "Preserve mode should keep mole intact")

        // 2. Soften mode: should lighten mole moderately (~50%)
        let softenSettings = FacialHairSettings(
            enabled: true,
            moleManagement: .soften,
            moleRemovalIntensity: 0.8
        )
        let softenRes = FacialHairEngine.apply(to: imageWithMole, faces: [face], settings: softenSettings)
        let softenPixel = samplePixel(image: softenRes.image, at: CGPoint(x: moleX, y: moleY))
        XCTAssertGreaterThan(softenPixel.r, before.r + 0.10, "Soften mode should lighten mole contrast")

        // 3. Remove mode: should completely blend mole into skin
        let removeSettings = FacialHairSettings(
            enabled: true,
            moleManagement: .remove,
            moleRemovalIntensity: 0.95
        )
        let removeRes = FacialHairEngine.apply(to: imageWithMole, faces: [face], settings: removeSettings)
        let removePixel = samplePixel(image: removeRes.image, at: CGPoint(x: moleX, y: moleY))
        XCTAssertGreaterThan(removePixel.r, softenPixel.r, "Remove mode should lighten mole further toward base skin")
        XCTAssertGreaterThan(removePixel.r, 0.48, "Remove mode should in-fill mole with natural skin tone")
    }

    func testRecipeVersionGate() {
        var recipe = Recipe()
        recipe.adjustments.facialHair = FacialHairSettings(enabled: true, lipFuzzRemoval: 0.5)

        // Version 25 should fail for active facialHair
        recipe.version = 25
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 25 cannot encode non-neutral facialHair")

        // Version 26 should succeed
        recipe.version = 26
        XCTAssertNoThrow(try recipe.validateVersion())

        // Future version 34 should fail
        recipe.version = 34
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 34 is future unsupported")

        // PhotoEngine requiredRecipeVersion check
        let requiredVersion = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(requiredVersion, 26)
    }

    func testSelectiveSyncFacialHair() {
        var source = AdjustmentSettings()
        source.facialHair = FacialHairSettings(enabled: true, lipFuzzRemoval: 0.75, beardShadowReduction: 0.6)

        let target = AdjustmentSettings()
        var lut = "original"

        // Sync with facialHair = false
        var options = AdjustmentSyncOptions.none
        options.facialHair = false
        var merged = AdjustmentSyncEngine.merge(source: source, into: target, options: options, targetLUT: &lut)
        XCTAssertNil(merged.facialHair)

        // Sync with facialHair = true
        options.facialHair = true
        merged = AdjustmentSyncEngine.merge(source: source, into: target, options: options, targetLUT: &lut)
        XCTAssertNotNil(merged.facialHair)
        XCTAssertEqual(merged.facialHair?.lipFuzzRemoval, 0.75)
        XCTAssertEqual(merged.facialHair?.beardShadowReduction, 0.6)
    }

    func testPerPersonMultiFaceOverride() {
        let (baseImage, face) = makeSyntheticFace()
        let settings = FacialHairSettings(enabled: true, lipFuzzRemoval: 0.8)

        let res = FacialHairEngine.applyPerPerson(
            to: baseImage, face: face, faceIndex: 0,
            perFaceMask: nil, settings: settings
        )
        XCTAssertNotNil(res)
    }
}

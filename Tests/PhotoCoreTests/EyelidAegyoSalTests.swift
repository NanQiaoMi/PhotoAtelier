import XCTest
import CoreImage
@testable import PhotoCore

final class EyelidAegyoSalTests: XCTestCase {

    // Helper: create a 512x512 synthetic test image
    private func makeTestImage() -> CIImage {
        let color = CIColor(red: 0.85, green: 0.72, blue: 0.65, alpha: 1.0)
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))
    }

    // Helper: create mock landmark set with left and right eye geometry
    private func makeMockFace() -> FaceLandmarkSet {
        // Left eye centered around (180, 320), width ~60, height ~24
        let leftEye = (0..<8).map { i -> CGPoint in
            let angle = Double(i) / 8.0 * 2.0 * .pi
            return CGPoint(x: 180.0 + 30.0 * cos(angle), y: 320.0 + 12.0 * sin(angle))
        }
        // Right eye centered around (332, 320), width ~60, height ~24
        let rightEye = (0..<8).map { i -> CGPoint in
            let angle = Double(i) / 8.0 * 2.0 * .pi
            return CGPoint(x: 332.0 + 30.0 * cos(angle), y: 320.0 + 12.0 * sin(angle))
        }
        let leftPupil = CGPoint(x: 180.0, y: 320.0)
        let rightPupil = CGPoint(x: 332.0, y: 320.0)
        return FaceLandmarkSet(
            boundingBox: CGRect(x: 100, y: 150, width: 312, height: 312),
            leftEye: leftEye,
            rightEye: rightEye,
            leftPupil: leftPupil,
            rightPupil: rightPupil
        )
    }

    // MARK: - 1. Neutrality & Default Values

    func testNeutralityAndDefaults() {
        let def = EyelidAegyoSalSettings()
        XCTAssertFalse(def.enabled)
        XCTAssertEqual(def.eyelidStyle, .off)
        XCTAssertEqual(def.eyelidStrength, 0)
        XCTAssertEqual(def.eyelidHeight, 1.0)
        XCTAssertEqual(def.eyelidWidth, 0.5)
        XCTAssertEqual(def.tapeConceal, 0)
        XCTAssertEqual(def.aegyoSalLuminance, 0)
        XCTAssertEqual(def.aegyoSalShadow, 0)
        XCTAssertEqual(def.aegyoSalWidth, 1.0)
        XCTAssertTrue(def.isNeutral)

        // When enabled is false, setting non-zero values still remains neutral
        var disabledWithValues = def
        disabledWithValues.enabled = false
        disabledWithValues.eyelidStyle = .fan
        disabledWithValues.eyelidStrength = 0.8
        XCTAssertTrue(disabledWithValues.isNeutral)

        // When enabled is true but all strengths are 0 or style is off, it is neutral
        var enabledZero = def
        enabledZero.enabled = true
        XCTAssertTrue(enabledZero.isNeutral)

        // When style is off and eyelidStrength > 0, still neutral if tape and aegyo are 0
        var styleOff = def
        styleOff.enabled = true
        styleOff.eyelidStyle = .off
        styleOff.eyelidStrength = 0.7
        XCTAssertTrue(styleOff.isNeutral)

        // Non-neutral when style is fan and strength > 0
        var active = def
        active.enabled = true
        active.eyelidStyle = .fan
        active.eyelidStrength = 0.5
        XCTAssertFalse(active.isNeutral)
    }

    func testNeutralSkipsProcessing() {
        let image = makeTestImage()
        let face = makeMockFace()
        let neutralSettings = EyelidAegyoSalSettings()

        let (outImage, report) = EyelidAegyoSalRefinementEngine.apply(
            to: image, faces: [face], settings: neutralSettings
        )
        XCTAssertFalse(report.applied)
        XCTAssertEqual(outImage, image)
    }

    func testEmptyFacesSkipsProcessing() {
        let image = makeTestImage()
        let active = EyelidAegyoSalSettings(enabled: true, eyelidStyle: .crescent, eyelidStrength: 0.6)

        let (outImage, report) = EyelidAegyoSalRefinementEngine.apply(
            to: image, faces: [], settings: active
        )
        XCTAssertFalse(report.applied)
        XCTAssertEqual(report.faceCount, 0)
        XCTAssertEqual(outImage, image)
    }

    // MARK: - 2. Parameter Validation

    func testValidationBounds() {
        var s = EyelidAegyoSalSettings()
        XCTAssertNoThrow(try s.validated())

        // Eyelid strength bounds (0...1)
        s.eyelidStrength = -0.1
        XCTAssertThrowsError(try s.validated())
        s.eyelidStrength = 1.1
        XCTAssertThrowsError(try s.validated())
        s.eyelidStrength = 0.8

        // Eyelid height bounds (0.5...2.0)
        s.eyelidHeight = 0.4
        XCTAssertThrowsError(try s.validated())
        s.eyelidHeight = 2.1
        XCTAssertThrowsError(try s.validated())
        s.eyelidHeight = 1.2

        // Eyelid width bounds (0...1)
        s.eyelidWidth = -0.1
        XCTAssertThrowsError(try s.validated())
        s.eyelidWidth = 1.1
        XCTAssertThrowsError(try s.validated())
        s.eyelidWidth = 0.6

        // Tape conceal bounds (0...1)
        s.tapeConceal = -0.05
        XCTAssertThrowsError(try s.validated())
        s.tapeConceal = 1.05
        XCTAssertThrowsError(try s.validated())
        s.tapeConceal = 0.5

        // Aegyo sal luma bounds (0...1)
        s.aegyoSalLuminance = -0.2
        XCTAssertThrowsError(try s.validated())
        s.aegyoSalLuminance = 1.2
        XCTAssertThrowsError(try s.validated())
        s.aegyoSalLuminance = 0.4

        // Aegyo sal shadow bounds (0...1)
        s.aegyoSalShadow = -0.1
        XCTAssertThrowsError(try s.validated())
        s.aegyoSalShadow = 1.1
        XCTAssertThrowsError(try s.validated())
        s.aegyoSalShadow = 0.3

        // Aegyo sal width bounds (0.5...1.5)
        s.aegyoSalWidth = 0.3
        XCTAssertThrowsError(try s.validated())
        s.aegyoSalWidth = 1.8
        XCTAssertThrowsError(try s.validated())
        s.aegyoSalWidth = 1.0

        XCTAssertNoThrow(try s.validated())
    }

    // MARK: - 3. Double Eyelid Styles

    func testAllDoubleEyelidStyles() {
        let image = makeTestImage()
        let face = makeMockFace()
        let styles: [EyelidStyle] = [.fan, .parallel, .crescent, .wide]

        for style in styles {
            let settings = EyelidAegyoSalSettings(
                enabled: true,
                eyelidStyle: style,
                eyelidStrength: 0.65,
                eyelidHeight: 1.1,
                eyelidWidth: 0.6
            )
            let (outImage, report) = EyelidAegyoSalRefinementEngine.apply(
                to: image, faces: [face], settings: settings
            )
            XCTAssertTrue(report.applied, "Style \(style) should be applied")
            XCTAssertTrue(report.eyelidApplied, "Style \(style) eyelidApplied should be true")
            XCTAssertEqual(report.faceCount, 1)
            XCTAssertEqual(outImage.extent, image.extent)
        }
    }

    // MARK: - 4. Eyelid Tape Concealing

    func testEyelidTapeConcealing() {
        let image = makeTestImage()
        let face = makeMockFace()
        let settings = EyelidAegyoSalSettings(
            enabled: true,
            eyelidStyle: .off,
            tapeConceal: 0.75
        )
        let (outImage, report) = EyelidAegyoSalRefinementEngine.apply(
            to: image, faces: [face], settings: settings
        )
        XCTAssertTrue(report.applied)
        XCTAssertFalse(report.eyelidApplied)
        XCTAssertTrue(report.tapeConcealApplied)
        XCTAssertFalse(report.aegyoSalApplied)
        XCTAssertEqual(outImage.extent, image.extent)
    }

    // MARK: - 5. Aegyo Sal (卧蚕) Sculpting

    func testAegyoSalHighlightAndShadow() {
        let image = makeTestImage()
        let face = makeMockFace()
        let settings = EyelidAegyoSalSettings(
            enabled: true,
            eyelidStyle: .off,
            aegyoSalLuminance: 0.60,
            aegyoSalShadow: 0.45,
            aegyoSalWidth: 1.15
        )
        let (outImage, report) = EyelidAegyoSalRefinementEngine.apply(
            to: image, faces: [face], settings: settings
        )
        XCTAssertTrue(report.applied)
        XCTAssertFalse(report.eyelidApplied)
        XCTAssertFalse(report.tapeConcealApplied)
        XCTAssertTrue(report.aegyoSalApplied)
        XCTAssertEqual(outImage.extent, image.extent)
    }

    // MARK: - 6. Recipe Version & Validation

    func testRecipeVersionGate() throws {
        var recipe = Recipe()
        recipe.adjustments.eyelidAegyoSal = EyelidAegyoSalSettings(
            enabled: true,
            eyelidStyle: .parallel,
            eyelidStrength: 0.70
        )

        // Version 22 must fail for active eyelidAegyoSal
        recipe.version = 22
        XCTAssertThrowsError(try recipe.validateVersion(), "Active eyelidAegyoSal requires version 23")

        // Version 23 must succeed
        recipe.version = 23
        XCTAssertNoThrow(try recipe.validateVersion(), "Version 23 must validate successfully")

        // Version 28 is future unsupported
        recipe.version = 28
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 28 should be rejected")

        // Required version calculation
        let reqV = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(reqV, 23)
    }

    func testMultiPersonOverrideRequiresVersion23() throws {
        var recipe = Recipe()
        var profile = PersonPortraitProfile.defaultProfile(for: .femaleAdult)
        profile.faceIndex = 0
        profile.eyelidAegyoSalOverride = EyelidAegyoSalSettings(
            enabled: true,
            eyelidStyle: .fan,
            eyelidStrength: 0.60
        )
        recipe.adjustments.multiPerson = MultiPersonSettings(
            enabled: true,
            individualProfiles: [profile]
        )

        let reqV = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(reqV, 23)
    }

    // MARK: - 7. Selective Sync

    func testSelectiveSyncEyelidAegyoSal() {
        var source = AdjustmentSettings()
        source.eyelidAegyoSal = EyelidAegyoSalSettings(
            enabled: true,
            eyelidStyle: .crescent,
            eyelidStrength: 0.80,
            tapeConceal: 0.50,
            aegyoSalLuminance: 0.60
        )

        var target = AdjustmentSettings()
        target.eyelidAegyoSal = nil
        var targetLUT = ""

        // When eyelidAegyoSal is synced
        let syncOptsTrue = AdjustmentSyncOptions(eyelidAegyoSal: true)
        let merged = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptsTrue,
            sourceLUT: nil,
            targetLUT: &targetLUT
        )
        XCTAssertEqual(merged.eyelidAegyoSal?.eyelidStyle, EyelidStyle.crescent)
        XCTAssertEqual(merged.eyelidAegyoSal?.eyelidStrength, 0.80)
        XCTAssertEqual(merged.eyelidAegyoSal?.tapeConceal, 0.50)

        // When eyelidAegyoSal sync is opted out
        let syncOptsFalse = AdjustmentSyncOptions(eyelidAegyoSal: false)
        let skipped = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptsFalse,
            sourceLUT: nil,
            targetLUT: &targetLUT
        )
        XCTAssertNil(skipped.eyelidAegyoSal)
    }

    // MARK: - 8. Multi-Person Per-Face Override

    func testPerPersonEyelidRefinement() {
        let image = makeTestImage()
        let face = makeMockFace()
        let mask = CIImage(color: CIColor.white).cropped(to: face.boundingBox)
        let maskSet = FaceSemanticMaskSet(
            extent: image.extent,
            resolution: image.extent.size,
            faceBounds: face.boundingBox,
            confidence: 1.0,
            faceCount: 1,
            skin: mask,
            teeth: nil,
            sclera: nil,
            iris: nil,
            lips: nil,
            brows: nil
        )

        let perPersonSettings = EyelidAegyoSalSettings(
            enabled: true,
            eyelidStyle: .wide,
            eyelidStrength: 0.70,
            aegyoSalLuminance: 0.50
        )

        let outImage = EyelidAegyoSalRefinementEngine.applyPerPerson(
            to: image,
            face: face,
            faceIndex: 0,
            perFaceMask: maskSet,
            settings: perPersonSettings
        )
        XCTAssertEqual(outImage.extent, image.extent)
    }
}

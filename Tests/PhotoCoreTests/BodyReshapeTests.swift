import XCTest
import CoreImage
import CoreGraphics
import Vision
@testable import PhotoCore

final class BodyReshapeTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeTestSkeleton() -> HumanBodySkeleton {
        // Standard normalized full-body standing skeleton (0...1, bottom-left origin)
        var joints: [String: BodyJoint] = [:]
        func add(_ name: VNHumanBodyPoseObservation.JointName, _ x: Double, _ y: Double, _ conf: Float = 0.95) {
            let key = name.rawValue.rawValue
            joints[key] = BodyJoint(name: key, location: CGPoint(x: x, y: y), confidence: conf)
        }

        add(.neck, 0.50, 0.75)
        add(.leftShoulder, 0.40, 0.72)
        add(.rightShoulder, 0.60, 0.72)
        add(.leftElbow, 0.35, 0.58)
        add(.rightElbow, 0.65, 0.58)
        add(.leftWrist, 0.33, 0.45)
        add(.rightWrist, 0.67, 0.45)
        add(.root, 0.50, 0.50)
        add(.leftHip, 0.44, 0.48)
        add(.rightHip, 0.56, 0.48)
        add(.leftKnee, 0.43, 0.28)
        add(.rightKnee, 0.57, 0.28)
        add(.leftAnkle, 0.42, 0.08)
        add(.rightAnkle, 0.58, 0.08)

        return HumanBodySkeleton(joints: joints)
    }

    private func makeSyntheticImage(width: Int = 128, height: Int = 128) -> CIImage {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let bitmap = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)).cropped(to: bounds)
        return bitmap
    }

    // MARK: - Settings & Validation Tests

    func testBodyReshapeSettingsNeutrality() {
        var settings = BodyReshapeSettings()
        XCTAssertTrue(settings.isNeutral, "Default settings must be neutral")

        settings.enabled = true
        XCTAssertTrue(settings.isNeutral, "Enabled with all zeros must still be neutral")

        settings.swanNeck = 0.5
        XCTAssertFalse(settings.isNeutral, "Non-zero swanNeck must make settings active")

        settings.enabled = false
        XCTAssertTrue(settings.isNeutral, "Disabled settings must be neutral even with non-zero sliders")
    }

    func testBodyReshapeValidation() {
        var settings = BodyReshapeSettings(enabled: true)
        XCTAssertNoThrow(try settings.validated())

        // Test out-of-range checks
        settings.swanNeck = 1.5
        XCTAssertThrowsError(try settings.validated())

        settings.swanNeck = 0.5
        settings.trapeziusContraction = -0.2
        XCTAssertThrowsError(try settings.validated())

        settings.trapeziusContraction = 0.5
        settings.bodySlimming = .nan
        XCTAssertThrowsError(try settings.validated())

        settings.bodySlimming = 0.5
        settings.waistCinching = 2.0
        XCTAssertThrowsError(try settings.validated())

        settings.waistCinching = 0.5
        settings.legLengthening = -1.0
        XCTAssertThrowsError(try settings.validated())

        settings.legLengthening = 0.5
        settings.armSlimming = 1.1
        XCTAssertThrowsError(try settings.validated())

        settings.armSlimming = 0.5
        settings.backgroundProtection = -0.1
        XCTAssertThrowsError(try settings.validated())

        settings.backgroundProtection = 0.8
        XCTAssertNoThrow(try settings.validated())
    }

    func testHumanBodySkeletonCodable() throws {
        let skeleton = makeTestSkeleton()
        let data = try JSONEncoder().encode(skeleton)
        let decoded = try JSONDecoder().decode(HumanBodySkeleton.self, from: data)

        XCTAssertEqual(decoded, skeleton)
        XCTAssertNotNil(decoded.neck)
        XCTAssertEqual(decoded.neck?.x ?? 0, 0.50, accuracy: 1e-4)
        XCTAssertEqual(decoded.neck?.y ?? 0, 0.75, accuracy: 1e-4)
        XCTAssertNotNil(decoded.leftShoulder)
        XCTAssertNotNil(decoded.rightShoulder)
        XCTAssertNotNil(decoded.root)
    }

    // MARK: - Anatomical WarpField Tests

    func testSwanNeckWarpField() {
        let skeleton = makeTestSkeleton()
        let settings = BodyReshapeSettings(enabled: true, swanNeck: 0.75, backgroundProtection: 0)
        let field = BodyReshapeEngine.generateWarpField(
            imageSize: CGSize(width: 256, height: 256),
            skeletons: [skeleton],
            settings: settings,
            resolution: 64
        )

        XCTAssertFalse(field.isIdentity, "WarpField should not be identity when swanNeck > 0")

        // Neck is at (0.50, 0.75). Check left neck (0.45, 0.785) and right neck (0.55, 0.785)
        let leftDisp = field.displacement(at: CGPoint(x: 0.46, y: 0.785))
        let rightDisp = field.displacement(at: CGPoint(x: 0.54, y: 0.785))

        // Left neck should push to the right (+x), right neck should push to the left (-x)
        XCTAssertGreaterThan(leftDisp.x, 0, "Left neck should have positive x displacement (inward)")
        XCTAssertLessThan(rightDisp.x, 0, "Right neck should have negative x displacement (inward)")

        // Upper neck should push upward (+y)
        let upperDisp = field.displacement(at: CGPoint(x: 0.50, y: 0.81))
        XCTAssertGreaterThan(upperDisp.y, 0, "Upper neck should have positive y displacement (upward stretch)")
    }

    func testTrapeziusContractionWarpField() {
        let skeleton = makeTestSkeleton()
        let settings = BodyReshapeSettings(enabled: true, trapeziusContraction: 0.80, backgroundProtection: 0)
        let field = BodyReshapeEngine.generateWarpField(
            imageSize: CGSize(width: 256, height: 256),
            skeletons: [skeleton],
            settings: settings,
            resolution: 64
        )

        XCTAssertFalse(field.isIdentity)

        // Trapezius midpoint is around (0.45, 0.75) for left trapezius
        let trapDisp = field.displacement(at: CGPoint(x: 0.45, y: 0.75))
        // Downward depression: negative y
        XCTAssertLessThan(trapDisp.y, 0, "Left trapezius should have negative y displacement (downward depression)")

        // Shoulder acromion elevation: around left shoulder (0.40, 0.72)
        let acromionDisp = field.displacement(at: CGPoint(x: 0.38, y: 0.72))
        XCTAssertGreaterThan(acromionDisp.y, 0, "Acromion should have positive y displacement (horizontal shoulder flattening)")
    }

    func testBodySlimmingAndWaistCinching() {
        let skeleton = makeTestSkeleton()
        let settings = BodyReshapeSettings(enabled: true, bodySlimming: 0.60, waistCinching: 0.80, backgroundProtection: 0)
        let field = BodyReshapeEngine.generateWarpField(
            imageSize: CGSize(width: 256, height: 256),
            skeletons: [skeleton],
            settings: settings,
            resolution: 64
        )

        XCTAssertFalse(field.isIdentity)

        // Mid torso / waist level is around y = 0.60
        // Left flank is around x = 0.40, right flank is around x = 0.60
        let leftFlankDisp = field.displacement(at: CGPoint(x: 0.40, y: 0.60))
        let rightFlankDisp = field.displacement(at: CGPoint(x: 0.60, y: 0.60))

        XCTAssertGreaterThan(leftFlankDisp.x, 0, "Left flank should push to the right (+x)")
        XCTAssertLessThan(rightFlankDisp.x, 0, "Right flank should push to the left (-x)")
    }

    func testLegLengthening() {
        let skeleton = makeTestSkeleton()
        let settings = BodyReshapeSettings(enabled: true, legLengthening: 0.85, backgroundProtection: 0)
        let field = BodyReshapeEngine.generateWarpField(
            imageSize: CGSize(width: 256, height: 256),
            skeletons: [skeleton],
            settings: settings,
            resolution: 64
        )

        XCTAssertFalse(field.isIdentity)

        // Upper torso (y = 0.70) should not be pulled down significantly
        let torsoDisp = field.displacement(at: CGPoint(x: 0.50, y: 0.70))
        XCTAssertEqual(torsoDisp.y, 0.0, accuracy: 0.002, "Torso should remain anchored")

        // Mid shin level (y = 0.20) should have clear downward displacement (negative y)
        let shinDisp = field.displacement(at: CGPoint(x: 0.43, y: 0.20))
        XCTAssertLessThan(shinDisp.y, -0.005, "Shin should have significant downward displacement for leg lengthening")
    }

    func testArmSlimming() {
        let skeleton = makeTestSkeleton()
        let settings = BodyReshapeSettings(enabled: true, armSlimming: 0.75, backgroundProtection: 0)
        let field = BodyReshapeEngine.generateWarpField(
            imageSize: CGSize(width: 256, height: 256),
            skeletons: [skeleton],
            settings: settings,
            resolution: 64
        )

        XCTAssertFalse(field.isIdentity)

        // Left upper arm is from (0.40, 0.72) to (0.35, 0.58), mid arm around (0.375, 0.65)
        // Outer point is around (0.32, 0.65)
        let leftArmDisp = field.displacement(at: CGPoint(x: 0.32, y: 0.65))
        XCTAssertGreaterThan(leftArmDisp.x, 0, "Left outer arm should push inward (+x) toward the humerus")
    }

    func testBackgroundProtection() {
        let skeleton = makeTestSkeleton()
        let active = BodyReshapeSettings(
            enabled: true,
            swanNeck: 0.6,
            bodySlimming: 0.8,
            waistCinching: 0.8,
            backgroundProtection: 1.0
        )

        let fieldProtected = BodyReshapeEngine.generateWarpField(
            imageSize: CGSize(width: 256, height: 256),
            skeletons: [skeleton],
            settings: active,
            resolution: 64
        )

        // Far edge of the background (e.g., x = 0.05, y = 0.50, which is far from torso)
        let farBackground = CGPoint(x: 0.05, y: 0.50)
        let dispProtected = fieldProtected.displacement(at: farBackground)

        XCTAssertEqual(dispProtected.x, 0, accuracy: 1e-5, "Background point must have zero displacement under protection 1.0")
        XCTAssertEqual(dispProtected.y, 0, accuracy: 1e-5, "Background point must have zero displacement under protection 1.0")
    }

    // MARK: - Integration & Multi-Person Tests

    func testBodyReshapeEngineApply() throws {
        let image = makeSyntheticImage(width: 128, height: 128)
        let skeleton = makeTestSkeleton()

        // 1. Neutral settings
        let (neutralOut, neutralReport) = try BodyReshapeEngine.apply(
            image,
            settings: BodyReshapeSettings(),
            skeletons: [skeleton]
        )
        XCTAssertFalse(neutralReport.applied)
        XCTAssertEqual(neutralOut.extent, image.extent)

        // 2. Active settings
        let activeSettings = BodyReshapeSettings(
            enabled: true,
            swanNeck: 0.5,
            waistCinching: 0.5
        )
        let (warpedOut, warpedReport) = try BodyReshapeEngine.apply(
            image,
            settings: activeSettings,
            skeletons: [skeleton]
        )
        XCTAssertTrue(warpedReport.applied)
        XCTAssertEqual(warpedReport.skeletonsDetected, 1)
        XCTAssertEqual(warpedOut.extent, image.extent)

        // 3. No skeletons detected
        let (emptyOut, emptyReport) = try BodyReshapeEngine.apply(
            image,
            settings: activeSettings,
            skeletons: []
        )
        XCTAssertFalse(emptyReport.applied)
        XCTAssertEqual(emptyReport.skeletonsDetected, 0)
        XCTAssertEqual(emptyOut.extent, image.extent)
    }

    func testSelectiveSyncBodyReshape() {
        var source = AdjustmentSettings()
        source.bodyReshape = BodyReshapeSettings(
            enabled: true,
            swanNeck: 0.60,
            waistCinching: 0.70
        )

        let target = AdjustmentSettings()
        var targetLUT = "original-lut"

        // Sync with bodyReshape = true
        var optionsSync = AdjustmentSyncOptions.allAdjustments
        optionsSync.bodyReshape = true
        let mergedSync = AdjustmentSyncEngine.merge(source: source, into: target, options: optionsSync, targetLUT: &targetLUT)
        XCTAssertNotNil(mergedSync.bodyReshape)
        XCTAssertEqual(mergedSync.bodyReshape?.swanNeck, 0.60)
        XCTAssertEqual(mergedSync.bodyReshape?.waistCinching, 0.70)

        // Sync with bodyReshape = false
        var optionsNoSync = AdjustmentSyncOptions.allAdjustments
        optionsNoSync.bodyReshape = false
        let mergedNoSync = AdjustmentSyncEngine.merge(source: source, into: target, options: optionsNoSync, targetLUT: &targetLUT)
        XCTAssertNil(mergedNoSync.bodyReshape)
    }

    func testRecipeVersion22Gate() throws {
        var recipe = Recipe()
        recipe.adjustments.bodyReshape = BodyReshapeSettings(
            enabled: true,
            swanNeck: 0.5
        )

        // Version 21 must fail for active bodyReshape
        recipe.version = 21
        XCTAssertThrowsError(try recipe.validateVersion(), "Active bodyReshape requires version 22")

        // Version 22 must succeed
        recipe.version = 22
        XCTAssertNoThrow(try recipe.validateVersion(), "Version 22 must validate successfully")

        // Version 28 is future unsupported
        recipe.version = 28
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 28 should be rejected")

        // Required version calculation
        let reqV = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(reqV, 22)
    }
}

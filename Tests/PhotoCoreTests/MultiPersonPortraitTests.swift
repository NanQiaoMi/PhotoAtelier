import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class MultiPersonPortraitTests: XCTestCase {

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false
    ])

    // MARK: - Helpers

    private func makeEllipse(_ center: CGPoint, _ rx: Double, _ ry: Double, points: Int = 16) -> [CGPoint] {
        (0..<points).map { i in
            let angle = Double(i) / Double(points) * 2 * Double.pi
            return CGPoint(x: center.x + CGFloat(cos(angle) * rx),
                           y: center.y + CGFloat(sin(angle) * ry))
        }
    }

    private func makeFaceLandmarks(centerX: Double, centerY: Double,
                                   width: Double = 0.30, height: Double = 0.40) -> FaceLandmarkSet {
        let halfW = width / 2
        let halfH = height / 2
        let box = CGRect(x: centerX - halfW, y: centerY - halfH, width: width, height: height)
        let contour = makeEllipse(CGPoint(x: centerX, y: centerY), halfW, halfH)
        let leftEye = makeEllipse(CGPoint(x: centerX - halfW * 0.4, y: centerY + halfH * 0.15),
                                  halfW * 0.2, halfH * 0.1)
        let rightEye = makeEllipse(CGPoint(x: centerX + halfW * 0.4, y: centerY + halfH * 0.15),
                                   halfW * 0.2, halfH * 0.1)
        let lips = makeEllipse(CGPoint(x: centerX, y: centerY - halfH * 0.35),
                               halfW * 0.35, halfH * 0.12)
        let innerLips = makeEllipse(CGPoint(x: centerX, y: centerY - halfH * 0.35),
                                    halfW * 0.2, halfH * 0.05)
        let leftBrow = [CGPoint(x: centerX - halfW * 0.6, y: centerY + halfH * 0.35),
                        CGPoint(x: centerX - halfW * 0.2, y: centerY + halfH * 0.35),
                        CGPoint(x: centerX - halfW * 0.2, y: centerY + halfH * 0.30),
                        CGPoint(x: centerX - halfW * 0.6, y: centerY + halfH * 0.30)]
        let rightBrow = [CGPoint(x: centerX + halfW * 0.2, y: centerY + halfH * 0.35),
                         CGPoint(x: centerX + halfW * 0.6, y: centerY + halfH * 0.35),
                         CGPoint(x: centerX + halfW * 0.6, y: centerY + halfH * 0.30),
                         CGPoint(x: centerX + halfW * 0.2, y: centerY + halfH * 0.30)]

        return FaceLandmarkSet(
            boundingBox: box,
            confidence: 0.95,
            faceContour: contour,
            leftEye: leftEye,
            rightEye: rightEye,
            leftEyebrow: leftBrow,
            rightEyebrow: rightBrow,
            nose: makeEllipse(CGPoint(x: centerX, y: centerY), halfW * 0.15, halfH * 0.15),
            outerLips: lips,
            innerLips: innerLips,
            leftPupil: CGPoint(x: centerX - halfW * 0.4, y: centerY + halfH * 0.15),
            rightPupil: CGPoint(x: centerX + halfW * 0.4, y: centerY + halfH * 0.15)
        )
    }

    private func makeTwoFaceImage(face0Skin: (Float, Float, Float) = (0.70, 0.55, 0.45),
                                  face1Skin: (Float, Float, Float) = (0.50, 0.38, 0.30),
                                  face0Lip: (Float, Float, Float) = (0.75, 0.10, 0.15),
                                  face1Lip: (Float, Float, Float) = (0.50, 0.36, 0.30),
                                  face1Stubble: (Float, Float, Float)? = nil) -> CIImage {
        let width = 256
        let height = 128
        var pixels = [Float](repeating: 0, count: width * height * 4)

        for row in 0..<height {
            let y = 1.0 - (Double(row) + 0.5) / Double(height)
            for col in 0..<width {
                let x = (Double(col) + 0.5) / Double(width)
                let offset = (row * width + col) * 4

                // Background
                var color: (Float, Float, Float) = (0.20, 0.20, 0.22)

                // Face 0: center around (0.25, 0.5)
                let d0 = pow((x - 0.25) / 0.15, 2) + pow((y - 0.5) / 0.35, 2)
                if d0 <= 1.0 {
                    let lip0 = pow((x - 0.25) / 0.05, 2) + pow((y - 0.43) / 0.03, 2)
                    color = lip0 <= 1.0 ? face0Lip : face0Skin
                }

                // Face 1: center around (0.75, 0.5)
                let d1 = pow((x - 0.75) / 0.15, 2) + pow((y - 0.5) / 0.35, 2)
                if d1 <= 1.0 {
                    let lip1 = pow((x - 0.75) / 0.05, 2) + pow((y - 0.43) / 0.03, 2)
                    let stubble1 = pow((x - 0.75) / 0.08, 2) + pow((y - 0.34) / 0.035, 2)
                    if lip1 <= 1.0 {
                        color = face1Lip
                    } else if stubble1 <= 1.0, let stubble = face1Stubble {
                        color = stubble
                    } else {
                        color = face1Skin
                    }
                }

                pixels[offset] = color.0
                pixels[offset + 1] = color.1
                pixels[offset + 2] = color.2
                pixels[offset + 3] = 1.0
            }
        }

        let data = pixels.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        return CIImage(bitmapData: data,
                       bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                       size: CGSize(width: CGFloat(width), height: CGFloat(height)),
                       format: .RGBAf, colorSpace: linearColorSpace)
    }

    // MARK: - Tests

    func testPerFaceMasksSeparation() {
        let image = makeTwoFaceImage()
        let face0 = makeFaceLandmarks(centerX: 0.25, centerY: 0.5)
        let face1 = makeFaceLandmarks(centerX: 0.75, centerY: 0.5)

        let perFace = FaceSemanticAnalyzer.perFaceMasks(in: image, landmarks: [face0, face1], maxDimension: 128)
        XCTAssertEqual(perFace.count, 2)

        // Verify bounding boxes
        XCTAssertTrue(perFace[0].faceBounds.midX < 0.5)
        XCTAssertTrue(perFace[1].faceBounds.midX > 0.5)

        // Face 0 skin mask should exist and be isolated to left half
        XCTAssertNotNil(perFace[0].skin)
        XCTAssertNotNil(perFace[1].skin)

        // Sample skin mask of face 0 at right side (face 1 region) - should be 0
        var pixel = [Float](repeating: 0, count: 4)
        let rightSampleRect = CGRect(x: 180, y: 64, width: 1, height: 1)
        context.render(perFace[0].skin!, toBitmap: &pixel, rowBytes: 16, bounds: rightSampleRect, format: .RGBAf, colorSpace: linearColorSpace)
        XCTAssertEqual(pixel[0], 0.0, accuracy: 0.01, "Face 0 mask must not leak into Face 1 region")

        // Sample skin mask of face 1 at left side (face 0 region) - should be 0
        let leftSampleRect = CGRect(x: 64, y: 64, width: 1, height: 1)
        context.render(perFace[1].skin!, toBitmap: &pixel, rowBytes: 16, bounds: leftSampleRect, format: .RGBAf, colorSpace: linearColorSpace)
        XCTAssertEqual(pixel[0], 0.0, accuracy: 0.01, "Face 1 mask must not leak into Face 0 region")
    }

    func testDemographicRoleEstimationChild() {
        // Child: compact lower face (eyes low relative to cranium/chin)
        var child = makeFaceLandmarks(centerX: 0.5, centerY: 0.5, width: 0.30, height: 0.40)
        // Lower face ratio < 0.42
        child.leftEye = makeEllipse(CGPoint(x: 0.45, y: 0.38), 0.03, 0.02)
        child.rightEye = makeEllipse(CGPoint(x: 0.55, y: 0.38), 0.03, 0.02)
        child.leftPupil = CGPoint(x: 0.45, y: 0.38)
        child.rightPupil = CGPoint(x: 0.55, y: 0.38)

        let role = FaceSemanticAnalyzer.estimateDemographicRole(face: child, in: nil)
        XCTAssertEqual(role, .child, "Face with compact lower jaw should be recognized as child")
    }

    func testDemographicRoleEstimationFemaleAndMale() {
        let image = makeTwoFaceImage(
            face0Skin: (0.72, 0.56, 0.48),
            face1Skin: (0.58, 0.44, 0.36),
            face0Lip: (0.85, 0.12, 0.18),  // High red lip (female)
            face1Lip: (0.55, 0.42, 0.35),  // Muted lip matching skin (male)
            face1Stubble: (0.42, 0.35, 0.32) // Stubble shadow on chin (male)
        )
        let face0 = makeFaceLandmarks(centerX: 0.25, centerY: 0.5)
        let face1 = makeFaceLandmarks(centerX: 0.75, centerY: 0.5)

        let role0 = FaceSemanticAnalyzer.estimateDemographicRole(face: face0, in: image)
        XCTAssertEqual(role0, .femaleAdult, "High lip redness and smooth skin should be recognized as female/bride")

        let role1 = FaceSemanticAnalyzer.estimateDemographicRole(face: face1, in: image)
        XCTAssertEqual(role1, .maleAdult, "Muted lip and darker tone should be recognized as male/groom")
    }

    func testRecipeVersion20Validation() {
        var recipe = Recipe()
        recipe.version = 19
        recipe.adjustments.multiPerson = MultiPersonSettings(enabled: false)
        XCTAssertNoThrow(try recipe.validateVersion(), "Disabled multi-person is valid in version 19")

        // Active multi-person with non-neutral settings
        var activeMP = MultiPersonSettings(enabled: true)
        activeMP.unifySkinTone = 0.50
        recipe.adjustments.multiPerson = activeMP

        XCTAssertThrowsError(try recipe.validateVersion(), "Non-neutral multi-person requires version 20") { error in
            guard let atelierError = error as? AtelierError,
                  case .invalidConfiguration(let msg) = atelierError else {
                XCTFail("Expected invalidConfiguration error")
                return
            }
            XCTAssertTrue(msg.contains("配方版本 20"), "Error message should mention version 20")
        }

        // Bumping to version 20 should pass
        recipe.version = 20
        XCTAssertNoThrow(try recipe.validateVersion(), "Recipe version 20 should validate successfully")

        // Version 24 is currently invalid
        recipe.version = 24
        XCTAssertThrowsError(try recipe.validateVersion(), "Version > 23 should be rejected")
    }

    func testDefaultProfilesForAllDemographicRoles() {
        let female = PersonPortraitProfile.defaultProfile(for: .femaleAdult)
        XCTAssertEqual(female.role, .femaleAdult)
        XCTAssertGreaterThan(female.portraitOverride?.dodgeBurn ?? 0, 0.3)
        XCTAssertGreaterThan(female.makeupOverride?.lipIntensity ?? 0, 0.2)

        let male = PersonPortraitProfile.defaultProfile(for: .maleAdult)
        XCTAssertEqual(male.role, .maleAdult)
        XCTAssertTrue(male.portraitOverride?.keepSpots == true, "Male profile should preserve moles/spots")
        XCTAssertTrue(male.makeupOverride?.isNeutral == true, "Male profile should default to zero makeup")

        let child = PersonPortraitProfile.defaultProfile(for: .child)
        XCTAssertEqual(child.role, .child)
        XCTAssertEqual(child.portraitOverride?.blemishStrength ?? 1, 0.05, accuracy: 0.01)
        XCTAssertTrue(child.makeupOverride?.isNeutral == true)

        let elder = PersonPortraitProfile.defaultProfile(for: .elder)
        XCTAssertEqual(elder.role, .elder)
        XCTAssertGreaterThan(elder.portraitOverride?.texture ?? 0, 0.5, "Elder profile should preserve age texture")
    }

    func testPerPersonPortraitRefinementPipeline() throws {
        let image = makeTwoFaceImage()
        let face0 = makeFaceLandmarks(centerX: 0.25, centerY: 0.5)
        let face1 = makeFaceLandmarks(centerX: 0.75, centerY: 0.5)

        var adjustments = AdjustmentSettings()
        var multiPerson = MultiPersonSettings(enabled: true)
        // Person 1 (Face 0): Female bride with makeup
        let p0 = PersonPortraitProfile(
            faceIndex: 0,
            role: .femaleAdult,
            enabled: true,
            portraitOverride: PortraitRefinementSettings(dodgeBurn: 0.50),
            makeupOverride: MakeupSettings(lipIntensity: 0.80)
        )
        // Person 2 (Face 1): Male groom with zero makeup
        let p1 = PersonPortraitProfile(
            faceIndex: 1,
            role: .maleAdult,
            enabled: true,
            portraitOverride: PortraitRefinementSettings(blemishStrength: 0.30, keepSpots: true),
            makeupOverride: MakeupSettings() // Neutral makeup
        )
        multiPerson.individualProfiles = [p0, p1]
        adjustments.multiPerson = multiPerson

        let engine = PhotoEngine()
        let processed = try engine.process(
            image,
            settings: adjustments,
            lut: nil,
            preparedMakeupFaces: [face0, face1]
        )

        let report = processed.report
        XCTAssertNotNil(report.multiPerson)
        XCTAssertTrue(report.multiPerson?.applied == true)
        XCTAssertEqual(report.multiPerson?.faceCount, 2)
        XCTAssertEqual(report.multiPerson?.personRoles.count, 2)
        XCTAssertTrue(report.multiPerson?.appliedSteps.contains("portrait_1") == true)
        XCTAssertTrue(report.multiPerson?.appliedSteps.contains("portrait_2") == true)
        XCTAssertTrue(report.multiPerson?.appliedSteps.contains("makeup_1") == true)
        XCTAssertFalse(report.multiPerson?.appliedSteps.contains("makeup_2") == true, "Face 1 (male) had neutral makeup and should not run makeup")
    }

    func testMultiPersonSkinToneUnification() throws {
        // Face 0 is dark (0.40), Face 1 is bright (0.75)
        let image = makeTwoFaceImage(
            face0Skin: (0.40, 0.30, 0.25),
            face1Skin: (0.75, 0.60, 0.50)
        )
        let face0 = makeFaceLandmarks(centerX: 0.25, centerY: 0.5)
        let face1 = makeFaceLandmarks(centerX: 0.75, centerY: 0.5)

        var adjustments = AdjustmentSettings()
        var multiPerson = MultiPersonSettings(enabled: true)
        multiPerson.unifySkinTone = 0.90
        multiPerson.toneReference = .brightest
        adjustments.multiPerson = multiPerson

        let engine = PhotoEngine()
        let processed = try engine.process(
            image,
            settings: adjustments,
            lut: nil,
            preparedMakeupFaces: [face0, face1]
        )

        XCTAssertTrue(processed.report.multiPerson?.appliedSteps.contains("skinToneUnify") == true)

        // Sample Face 0 center skin after unification: it should be significantly brighter than 0.40
        var origPixel = [Float](repeating: 0, count: 4)
        var procPixel = [Float](repeating: 0, count: 4)
        let face0Rect = CGRect(x: 64, y: 70, width: 1, height: 1)
        context.render(image, toBitmap: &origPixel, rowBytes: 16, bounds: face0Rect, format: .RGBAf, colorSpace: linearColorSpace)
        context.render(processed.image, toBitmap: &procPixel, rowBytes: 16, bounds: face0Rect, format: .RGBAf, colorSpace: linearColorSpace)

        XCTAssertGreaterThan(procPixel[0], origPixel[0] + 0.04, "Dark face skin should be shifted brighter towards brightest reference")

        // Background pixel at (10, 10) must remain completely unaffected
        var bgOrig = [Float](repeating: 0, count: 4)
        var bgProc = [Float](repeating: 0, count: 4)
        let bgRect = CGRect(x: 10, y: 10, width: 1, height: 1)
        context.render(image, toBitmap: &bgOrig, rowBytes: 16, bounds: bgRect, format: .RGBAf, colorSpace: linearColorSpace)
        context.render(processed.image, toBitmap: &bgProc, rowBytes: 16, bounds: bgRect, format: .RGBAf, colorSpace: linearColorSpace)
        XCTAssertEqual(bgProc[0], bgOrig[0], accuracy: 0.001, "Background pixels must not be altered by skin tone unification")
    }

    func testSelectiveSyncMultiPerson() {
        var source = AdjustmentSettings()
        source.multiPerson = MultiPersonSettings(
            enabled: true,
            unifySkinTone: 0.65,
            toneReference: .median
        )

        var target = AdjustmentSettings()
        target.multiPerson = nil
        var targetLUT = ""

        // Test with multiPerson = true
        let syncOptsTrue = AdjustmentSyncOptions(multiPerson: true)
        let mergedTrue = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptsTrue,
            targetLUT: &targetLUT
        )
        XCTAssertNotNil(mergedTrue.multiPerson)
        XCTAssertEqual(mergedTrue.multiPerson?.unifySkinTone, 0.65)

        // Test with multiPerson = false
        let syncOptsFalse = AdjustmentSyncOptions(multiPerson: false)
        let mergedFalse = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptsFalse,
            targetLUT: &targetLUT
        )
        XCTAssertNil(mergedFalse.multiPerson, "Target should retain its nil multiPerson when option is false")
    }
}

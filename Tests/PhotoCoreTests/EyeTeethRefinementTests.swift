import XCTest
import CoreImage
import CoreGraphics
@testable import PhotoCore

final class EyeTeethRefinementTests: XCTestCase {

    private let context = CIContext(options: [.workingColorSpace: NSNull()])
    private let linearColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!

    // MARK: - Test Fixture Builders

    private func makeFaceImage(width: Int = 128, height: Int = 128) -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        }

        // Neutral gray background
        ctx.setFillColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)
        ctx.fill(extent)

        // Face oval: skin tone
        ctx.setFillColor(red: 0.85, green: 0.68, blue: 0.58, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 16, y: 16, width: 96, height: 96))

        // Left Eye (x: 32..48, y: 64..76): white sclera with a red capillary spot
        ctx.setFillColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 32, y: 64, width: 20, height: 12))
        // Red bloodshot capillary in sclera
        ctx.setFillColor(red: 0.90, green: 0.30, blue: 0.30, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 34, y: 68, width: 3, height: 3))
        // Iris: dark brown
        ctx.setFillColor(red: 0.25, green: 0.18, blue: 0.12, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 39, y: 66, width: 8, height: 8))

        // Right Eye (x: 76..96, y: 64..76): with eyeglass glare flare
        ctx.setFillColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 76, y: 64, width: 20, height: 12))
        ctx.setFillColor(red: 0.25, green: 0.18, blue: 0.12, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 81, y: 66, width: 8, height: 8))
        // Eyeglass glare hotspot (intense white reflection: 0.98, 0.98, 0.98)
        ctx.setFillColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 82, y: 68, width: 6, height: 6))

        // Mouth / Teeth (x: 48..80, y: 32..44)
        // Lips: red
        ctx.setFillColor(red: 0.85, green: 0.25, blue: 0.30, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 44, y: 30, width: 40, height: 16))
        // Teeth area: slightly yellowed teeth with a tea stain
        ctx.setFillColor(red: 0.88, green: 0.85, blue: 0.70, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 50, y: 34, width: 28, height: 8))
        // Tea / coffee yellow stain spot on tooth (high R, G, low B)
        ctx.setFillColor(red: 0.85, green: 0.75, blue: 0.40, alpha: 1.0)
        ctx.fill(CGRect(x: 62, y: 36, width: 4, height: 3))

        guard let cgImg = ctx.makeImage() else {
            return CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        }
        return CIImage(cgImage: cgImg)
    }

    private func makeFaceLandmarks() -> FaceLandmarkSet {
        // Coordinate system: normalized 0...1 with bottom-left origin
        let box = CGRect(x: 0.125, y: 0.125, width: 0.75, height: 0.75)
        // Left Eye: centered around x=0.32, y=0.55
        let leftEye = [
            CGPoint(x: 0.25, y: 0.55),
            CGPoint(x: 0.30, y: 0.59),
            CGPoint(x: 0.38, y: 0.59),
            CGPoint(x: 0.41, y: 0.55),
            CGPoint(x: 0.38, y: 0.51),
            CGPoint(x: 0.30, y: 0.51)
        ]
        // Right Eye: centered around x=0.68, y=0.55
        let rightEye = [
            CGPoint(x: 0.59, y: 0.55),
            CGPoint(x: 0.63, y: 0.59),
            CGPoint(x: 0.72, y: 0.59),
            CGPoint(x: 0.76, y: 0.55),
            CGPoint(x: 0.72, y: 0.51),
            CGPoint(x: 0.63, y: 0.51)
        ]
        // Inner lips / Teeth: centered around x=0.50, y=0.29
        let innerLips = [
            CGPoint(x: 0.39, y: 0.29),
            CGPoint(x: 0.45, y: 0.33),
            CGPoint(x: 0.55, y: 0.33),
            CGPoint(x: 0.61, y: 0.29),
            CGPoint(x: 0.55, y: 0.26),
            CGPoint(x: 0.45, y: 0.26)
        ]

        var landmarks = FaceLandmarkSet(boundingBox: box, confidence: 0.98)
        landmarks.leftEye = leftEye
        landmarks.rightEye = rightEye
        landmarks.leftPupil = CGPoint(x: 0.33, y: 0.55)
        landmarks.rightPupil = CGPoint(x: 0.67, y: 0.55)
        landmarks.innerLips = innerLips
        landmarks.outerLips = innerLips
        return landmarks
    }

    // MARK: - Unit Tests

    func testDefaultSettingsAreNeutral() {
        let settings = EyeTeethRefinementSettings()
        XCTAssertTrue(settings.isNeutral)

        let image = makeFaceImage()
        let face = makeFaceLandmarks()
        let (output, report) = EyeTeethRefinementEngine.apply(
            to: image,
            faces: [face],
            settings: settings
        )
        XCTAssertFalse(report.applied)
        XCTAssertEqual(output, image, "Neutral settings must return input image completely unchanged")
    }

    func testValidationRejectsOutOfRange() {
        var s = EyeTeethRefinementSettings(enabled: true)
        XCTAssertNoThrow(try s.validated())

        s.eyeglassGlareReduction = 1.2
        XCTAssertThrowsError(try s.validated())
        s.eyeglassGlareReduction = 0.5

        s.scleraBloodshotRemoval = -0.1
        XCTAssertThrowsError(try s.validated())
        s.scleraBloodshotRemoval = 0.5

        s.catchlightScale = 0.2 // Allowed range is 0.5...2.0
        XCTAssertThrowsError(try s.validated())
        s.catchlightScale = 1.0

        s.catchlightStrength = 2.0
        XCTAssertThrowsError(try s.validated())
        s.catchlightStrength = 0.5

        s.teethStainRemoval = 1.5
        XCTAssertThrowsError(try s.validated())
        s.teethStainRemoval = 0.5

        s.gingivaProtection = -0.5
        XCTAssertThrowsError(try s.validated())
    }

    func testCatchlightOverlayPatternGeneration() {
        let extent = CGRect(x: 0, y: 0, width: 200, height: 200)
        let face = makeFaceLandmarks()

        let patterns: [EyeCatchlightPattern] = [
            .naturalPoint, .ringLight, .softboxSquare, .dualStrip, .butterfly, .starburst
        ]

        for pat in patterns {
            let overlay = EyeTeethRefinementEngine.makeCatchlightOverlay(
                faces: [face],
                pattern: pat,
                scale: 1.0,
                extent: extent
            )
            XCTAssertNotNil(overlay, "Pattern \(pat) should generate non-nil overlay")

            // Verify pupil center has non-zero alpha
            var pixel = [Float](repeating: 0, count: 4)
            // Left pupil is around x: 66, y: 110 (with upper offset x: 64, y: 113)
            let sampleRect = CGRect(x: 64, y: 112, width: 1, height: 1)
            context.render(overlay!, toBitmap: &pixel, rowBytes: 16, bounds: sampleRect, format: .RGBAf, colorSpace: linearColorSpace)
            XCTAssertGreaterThan(pixel[3], 0.0, "Pattern \(pat) must produce active catchlight pixels near pupil")
        }
    }

    func testScleraBloodshotRemoval() {
        let image = makeFaceImage()
        let face = makeFaceLandmarks()

        var settings = EyeTeethRefinementSettings(enabled: true)
        settings.scleraBloodshotRemoval = 0.90

        let (processed, report) = EyeTeethRefinementEngine.apply(
            to: image,
            faces: [face],
            settings: settings
        )
        XCTAssertTrue(report.applied)
        XCTAssertTrue(report.scleraBloodshotApplied)

        // Sample red capillary spot at (35, 69)
        var origPixel = [Float](repeating: 0, count: 4)
        var procPixel = [Float](repeating: 0, count: 4)
        let sampleRect = CGRect(x: 35, y: 69, width: 1, height: 1)
        context.render(image, toBitmap: &origPixel, rowBytes: 16, bounds: sampleRect, format: .RGBAf, colorSpace: linearColorSpace)
        context.render(processed, toBitmap: &procPixel, rowBytes: 16, bounds: sampleRect, format: .RGBAf, colorSpace: linearColorSpace)

        // Red channel should be significantly neutralized
        let origRedExcess = origPixel[0] - (origPixel[1] + origPixel[2]) * 0.5
        let procRedExcess = procPixel[0] - (procPixel[1] + procPixel[2]) * 0.5
        XCTAssertLessThan(procRedExcess, origRedExcess, "Red bloodshot excess should be substantially reduced")
    }

    func testEyeglassGlareSuppression() {
        let image = makeFaceImage()
        let face = makeFaceLandmarks()

        var settings = EyeTeethRefinementSettings(enabled: true)
        settings.eyeglassGlareReduction = 0.95

        let (processed, report) = EyeTeethRefinementEngine.apply(
            to: image,
            faces: [face],
            settings: settings
        )
        XCTAssertTrue(report.applied)
        XCTAssertTrue(report.eyeglassGlareApplied)

        // Sample glare hotspot at (84, 70)
        var origPixel = [Float](repeating: 0, count: 4)
        var procPixel = [Float](repeating: 0, count: 4)
        let sampleRect = CGRect(x: 84, y: 70, width: 1, height: 1)
        context.render(image, toBitmap: &origPixel, rowBytes: 16, bounds: sampleRect, format: .RGBAf, colorSpace: linearColorSpace)
        context.render(processed, toBitmap: &procPixel, rowBytes: 16, bounds: sampleRect, format: .RGBAf, colorSpace: linearColorSpace)

        // Luminance of harsh glare should be suppressed
        XCTAssertLessThan(procPixel[0], origPixel[0], "Specular glare flare brightness should be pulled down")
        XCTAssertLessThan(procPixel[1], origPixel[1])
    }

    func testTeethStainRemovalAndEnamelSheen() {
        let image = makeFaceImage()
        let face = makeFaceLandmarks()

        var settings = EyeTeethRefinementSettings(enabled: true)
        settings.teethStainRemoval = 0.90
        settings.enamelSheen = 0.50

        let (processed, report) = EyeTeethRefinementEngine.apply(
            to: image,
            faces: [face],
            settings: settings
        )
        XCTAssertTrue(report.applied)
        XCTAssertTrue(report.teethStainApplied)

        // Sample tea stain on tooth at (63, 37)
        var origPixel = [Float](repeating: 0, count: 4)
        var procPixel = [Float](repeating: 0, count: 4)
        let sampleRect = CGRect(x: 63, y: 37, width: 1, height: 1)
        context.render(image, toBitmap: &origPixel, rowBytes: 16, bounds: sampleRect, format: .RGBAf, colorSpace: linearColorSpace)
        context.render(processed, toBitmap: &procPixel, rowBytes: 16, bounds: sampleRect, format: .RGBAf, colorSpace: linearColorSpace)

        // Blue channel should be boosted toward R/G to eliminate yellow stain
        XCTAssertGreaterThan(procPixel[2], origPixel[2], "Blue channel should be raised to neutralize yellow tea stain")
    }

    func testRecipeVersion21Validation() {
        var recipe = Recipe()
        recipe.version = 20
        recipe.adjustments.eyeTeeth = EyeTeethRefinementSettings(enabled: false)
        XCTAssertNoThrow(try recipe.validateVersion(), "Disabled eyeTeeth is valid in version 20")

        var activeET = EyeTeethRefinementSettings(enabled: true)
        activeET.scleraBloodshotRemoval = 0.50
        recipe.adjustments.eyeTeeth = activeET

        XCTAssertThrowsError(try recipe.validateVersion(), "Non-neutral eyeTeeth requires version 21") { error in
            guard let atelierError = error as? AtelierError,
                  case .invalidConfiguration(let msg) = atelierError else {
                XCTFail("Expected invalidConfiguration error")
                return
            }
            XCTAssertTrue(msg.contains("配方版本 21"), "Error message should mention version 21")
        }

        // Bumping to version 21 should validate
        recipe.version = 21
        XCTAssertNoThrow(try recipe.validateVersion(), "Recipe version 21 should validate successfully")

        // Future version 25 is rejected
        recipe.version = 25
        XCTAssertThrowsError(try recipe.validateVersion(), "Version > 24 should be rejected")
    }

    func testSelectiveSyncEyeTeeth() {
        var source = AdjustmentSettings()
        source.eyeTeeth = EyeTeethRefinementSettings(
            enabled: true,
            eyeglassGlareReduction: 0.60,
            scleraBloodshotRemoval: 0.50,
            catchlightPattern: .ringLight,
            catchlightStrength: 0.40
        )

        var target = AdjustmentSettings()
        target.eyeTeeth = nil
        var targetLUT = ""

        // Test with eyeTeeth = true
        let syncOptsTrue = AdjustmentSyncOptions(eyeTeeth: true)
        let mergedTrue = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptsTrue,
            sourceLUT: nil,
            targetLUT: &targetLUT
        )
        XCTAssertNotNil(mergedTrue.eyeTeeth)
        XCTAssertEqual(mergedTrue.eyeTeeth?.eyeglassGlareReduction, 0.60)
        XCTAssertEqual(mergedTrue.eyeTeeth?.catchlightPattern, EyeCatchlightPattern.ringLight)

        // Test with eyeTeeth = false
        let syncOptsFalse = AdjustmentSyncOptions(eyeTeeth: false)
        let mergedFalse = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptsFalse,
            sourceLUT: nil,
            targetLUT: &targetLUT
        )
        XCTAssertNil(mergedFalse.eyeTeeth, "Target eyeTeeth should remain nil when option is false")
    }

    func testMultiPersonEyeTeethProfileOverride() throws {
        let image = makeFaceImage()
        let face0 = makeFaceLandmarks()

        var adjustments = AdjustmentSettings()
        var multiPerson = MultiPersonSettings(enabled: true)
        // Female adult profile with ring light catchlight
        let p0 = PersonPortraitProfile(
            faceIndex: 0,
            role: .femaleAdult,
            enabled: true,
            eyeTeethOverride: EyeTeethRefinementSettings(
                enabled: true,
                catchlightPattern: .ringLight,
                catchlightStrength: 0.75,
                enamelSheen: 0.50
            )
        )
        multiPerson.individualProfiles = [p0]
        adjustments.multiPerson = multiPerson

        let engine = PhotoEngine()
        let processed = try engine.process(
            image,
            settings: adjustments,
            lut: nil,
            preparedMakeupFaces: [face0]
        )

        let report = processed.report
        XCTAssertNotNil(report.multiPerson)
        XCTAssertTrue(report.multiPerson?.applied == true)
        XCTAssertTrue(report.multiPerson?.appliedSteps.contains("eyeTeeth_1") == true, "Per-person eyeTeeth pass should be recorded in applied steps")
    }
}

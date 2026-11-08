import XCTest
import CoreImage
import CoreGraphics
@testable import PhotoCore

final class ExpressionTests: XCTestCase {

    // MARK: - Helper Methods

    /// Creates a synthetic test image with a mock face and lips.
    private func makeTestFaceImage() -> (image: CIImage, face: FaceLandmarkSet) {
        let size = CGSize(width: 400, height: 400)
        // Solid skin-tone background
        let base = CIImage(color: CIColor(red: 0.85, green: 0.68, blue: 0.58, alpha: 1.0))
            .cropped(to: CGRect(origin: .zero, size: size))

        // Normalized coordinates in bottom-left origin (0...1)
        // Mouth centered around (0.50, 0.35)
        let outerLips: [CGPoint] = [
            CGPoint(x: 0.40, y: 0.35), // Left commissure
            CGPoint(x: 0.43, y: 0.37), // Upper left contour
            CGPoint(x: 0.47, y: 0.38), // Left cupid's bow peak
            CGPoint(x: 0.50, y: 0.375), // Cupid's bow dip
            CGPoint(x: 0.53, y: 0.38), // Right cupid's bow peak
            CGPoint(x: 0.57, y: 0.37), // Upper right contour
            CGPoint(x: 0.60, y: 0.35), // Right commissure
            CGPoint(x: 0.57, y: 0.33), // Lower right contour
            CGPoint(x: 0.50, y: 0.32), // Lower vermilion bottom center
            CGPoint(x: 0.43, y: 0.33)  // Lower left contour
        ]

        let innerLips: [CGPoint] = [
            CGPoint(x: 0.42, y: 0.35),
            CGPoint(x: 0.50, y: 0.36),
            CGPoint(x: 0.58, y: 0.35),
            CGPoint(x: 0.50, y: 0.34)
        ]

        let nose: [CGPoint] = [
            CGPoint(x: 0.50, y: 0.52),
            CGPoint(x: 0.48, y: 0.44),
            CGPoint(x: 0.50, y: 0.43), // Subnasale
            CGPoint(x: 0.52, y: 0.44)
        ]

        let faceContour: [CGPoint] = [
            CGPoint(x: 0.30, y: 0.70),
            CGPoint(x: 0.32, y: 0.30),
            CGPoint(x: 0.50, y: 0.20), // Chin
            CGPoint(x: 0.68, y: 0.30),
            CGPoint(x: 0.70, y: 0.70)
        ]

        let face = FaceLandmarkSet(
            boundingBox: CGRect(x: 0.30, y: 0.20, width: 0.40, height: 0.60),
            confidence: 0.98,
            faceContour: faceContour,
            nose: nose,
            outerLips: outerLips,
            innerLips: innerLips
        )

        return (base, face)
    }

    // MARK: - 1. Neutral Settings & Geometry

    func testNeutralSettingsIsNoOp() {
        let (image, face) = makeTestFaceImage()
        let neutral = ExpressionSettings(enabled: false)
        let (output, report) = ExpressionEngine.apply(to: image, faces: [face], settings: neutral)

        XCTAssertFalse(report.applied)
        XCTAssertEqual(report.faceCount, 0)
        XCTAssertEqual(output.extent, image.extent)
    }

    func testExpressionGeometryExtraction() {
        let (_, face) = makeTestFaceImage()
        let geometry = ExpressionGeometry(face: face)

        XCTAssertNotNil(geometry)
        guard let g = geometry else { return }

        XCTAssertEqual(g.leftCorner.x, 0.40, accuracy: 0.001)
        XCTAssertEqual(g.rightCorner.x, 0.60, accuracy: 0.001)
        XCTAssertEqual(g.mouthCenter.x, 0.50, accuracy: 0.001)
        XCTAssertEqual(g.mouthWidth, 0.20, accuracy: 0.001)
        XCTAssertGreaterThan(g.mouthHeight, 0.04)
        XCTAssertEqual(g.cupidBow.y, 0.38, accuracy: 0.005)
        XCTAssertNotNil(g.subnasale)
        XCTAssertEqual(g.subnasale?.y ?? 0, 0.43, accuracy: 0.005)
        XCTAssertEqual(g.lowerVermilionBottom.y, 0.32, accuracy: 0.005)
    }

    // MARK: - 2. Smile Degree & Smile Width

    func testSmileDegreeGeneratesUpwardDisplacement() {
        let (_, face) = makeTestFaceImage()
        let settings = ExpressionSettings(enabled: true, smileDegree: 0.8)
        let field = ExpressionEngine.generateWarpField(faces: [face], settings: settings, imageSize: CGSize(width: 400, height: 400))

        XCTAssertFalse(field.isIdentity)
        XCTAssertGreaterThan(field.maximumMagnitude, 0.001)

        // Sample near left commissure (0.40, 0.35)
        // With row-major grid, row is calculated from (1 - y)
        // Left commissure should experience positive Y displacement (upward) and negative X displacement (outward)
        let col = Int(0.40 * Double(field.columns))
        let row = Int((1.0 - 0.35) * Double(field.rows))
        let offset = field.offsets[row * field.columns + col]

        XCTAssertGreaterThan(offset.y, 0.001, "Left commissure must be lifted upward")
        XCTAssertLessThan(offset.x, 0.0, "Left commissure must pull outward to the left")
    }

    func testSmileWidthModulation() {
        let (_, face) = makeTestFaceImage()
        // Widen smile
        let widenSettings = ExpressionSettings(enabled: true, smileWidth: 0.4)
        let widenField = ExpressionEngine.generateWarpField(faces: [face], settings: widenSettings, imageSize: CGSize(width: 400, height: 400))

        let leftCol = Int(0.40 * Double(widenField.columns))
        let rightCol = Int(0.60 * Double(widenField.columns))
        let row = Int((1.0 - 0.35) * Double(widenField.rows))

        let leftOffset = widenField.offsets[row * widenField.columns + leftCol]
        let rightOffset = widenField.offsets[row * widenField.columns + rightCol]

        XCTAssertLessThan(leftOffset.x, -0.0005, "Left corner pulls further left when widened")
        XCTAssertGreaterThan(rightOffset.x, 0.0005, "Right corner pulls further right when widened")
    }

    // MARK: - 3. Lip Corner Symmetry

    func testLipSymmetryHarmonization() {
        var (_, face) = makeTestFaceImage()
        // Introduce artificial tilt: left corner is lower (0.33), right corner is higher (0.37)
        face.outerLips[0] = CGPoint(x: 0.40, y: 0.33)
        face.outerLips[6] = CGPoint(x: 0.60, y: 0.37)

        let settings = ExpressionSettings(enabled: true, lipSymmetry: 1.0)
        let field = ExpressionEngine.generateWarpField(faces: [face], settings: settings, imageSize: CGSize(width: 400, height: 400))

        let leftCol = Int(0.40 * Double(field.columns))
        let rightCol = Int(0.60 * Double(field.columns))
        let leftRow = Int((1.0 - 0.33) * Double(field.rows))
        let rightRow = Int((1.0 - 0.37) * Double(field.rows))

        let leftOffset = field.offsets[leftRow * field.columns + leftCol]
        let rightOffset = field.offsets[rightRow * field.columns + rightCol]

        // Target Y is 0.35. Lower left corner (0.33) should be pulled upward (+Y)
        XCTAssertGreaterThan(leftOffset.y, 0.001, "Lower corner should be lifted towards symmetry")
        // Higher right corner (0.37) should be adjusted downward (-Y)
        XCTAssertLessThan(rightOffset.y, -0.001, "Higher corner should be lowered towards symmetry")
    }

    // MARK: - 4. Philtrum Shortening & Plumping

    func testPhiltrumShorteningDisplacement() {
        let (_, face) = makeTestFaceImage()
        let settings = ExpressionSettings(enabled: true, philtrumShortening: 0.7)
        let field = ExpressionEngine.generateWarpField(faces: [face], settings: settings, imageSize: CGSize(width: 400, height: 400))

        // Cupid's bow is around (0.50, 0.38)
        let col = Int(0.50 * Double(field.columns))
        let row = Int((1.0 - 0.38) * Double(field.rows))
        let offset = field.offsets[row * field.columns + col]

        XCTAssertGreaterThan(offset.y, 0.0005, "Cupid's bow must be displaced upward towards nose base")
    }

    func testUpperAndLowerLipPlump() {
        let (_, face) = makeTestFaceImage()
        let settings = ExpressionSettings(enabled: true, upperLipPlump: 0.5, lowerLipPlump: 0.5)
        let field = ExpressionEngine.generateWarpField(faces: [face], settings: settings, imageSize: CGSize(width: 400, height: 400))

        // Upper lip center is ~0.36
        let upperRow = Int((1.0 - 0.36) * Double(field.rows))
        let col = Int(0.50 * Double(field.columns))
        let upperOffset = field.offsets[upperRow * field.columns + col]
        XCTAssertGreaterThan(upperOffset.y, 0.0005, "Upper lip center displaced upward")

        // Lower lip center is ~0.335
        let lowerRow = Int((1.0 - 0.335) * Double(field.rows))
        let lowerOffset = field.offsets[lowerRow * field.columns + col]
        XCTAssertLessThan(lowerOffset.y, -0.0005, "Lower lip center displaced downward")
    }

    // MARK: - 5. 3D Lip Highlight & Micro-Shading

    func test3DLipHighlightExecution() {
        let (image, face) = makeTestFaceImage()
        let settings = ExpressionSettings(enabled: true, lip3DHighlight: 0.8)
        let (output, report) = ExpressionEngine.apply(to: image, faces: [face], settings: settings)

        XCTAssertTrue(report.applied)
        XCTAssertEqual(report.faceCount, 1)
        XCTAssertEqual(output.extent, image.extent)

        // Verify guide mask generation
        let guide = ExpressionEngine.makeLip3DGuideMask(faces: [face], extent: image.extent)
        XCTAssertEqual(guide.extent, image.extent)
    }

    // MARK: - 6. Demographic Profile Override & Per-Person Application

    func testMultiPersonPerPersonExpressionOverride() {
        let (image, face) = makeTestFaceImage()
        let profileSettings = ExpressionSettings(enabled: true, smileDegree: 0.9, upperLipPlump: 0.4)

        let processed = ExpressionEngine.applyPerPerson(
            to: image,
            face: face,
            faceIndex: 0,
            perFaceMask: nil,
            settings: profileSettings
        )

        XCTAssertEqual(processed.extent, image.extent)
    }

    // MARK: - 7. Recipe Version 27 Gating

    func testRecipeVersion27Validation() throws {
        var recipe = Recipe()
        recipe.adjustments.expression = ExpressionSettings(enabled: true, smileDegree: 0.5)

        // Version 26 should fail for active expression
        recipe.version = 26
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 26 cannot encode non-neutral expression")

        // Version 27 should succeed
        recipe.version = 27
        XCTAssertNoThrow(try recipe.validateVersion())

        // Future version 29 should fail
        recipe.version = 29
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 29 is future unsupported")

        // PhotoEngine requiredRecipeVersion check
        let requiredVersion = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(requiredVersion, 27)
    }

    func testMultiPersonExpressionOverrideRequiresVersion27() throws {
        var recipe = Recipe()
        var multi = MultiPersonSettings(enabled: true)
        let profile = PersonPortraitProfile(
            faceIndex: 0,
            role: .femaleAdult,
            enabled: true,
            expressionOverride: ExpressionSettings(enabled: true, smileDegree: 0.6)
        )
        multi.individualProfiles = [profile]
        recipe.adjustments.multiPerson = multi

        recipe.version = 26
        XCTAssertThrowsError(try recipe.validateVersion())

        recipe.version = 27
        XCTAssertNoThrow(try recipe.validateVersion())

        let reqV = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(reqV, 27)
    }

    // MARK: - 8. Selective Sync

    func testSelectiveSyncExpression() {
        var source = AdjustmentSettings()
        source.expression = ExpressionSettings(enabled: true, smileDegree: 0.7, philtrumShortening: 0.4)

        let target = AdjustmentSettings()
        var lut: String = ""

        // Sync with expression enabled
        let options = AdjustmentSyncOptions.allAdjustments
        let merged = AdjustmentSyncEngine.merge(source: source, into: target, options: options, sourceLUT: nil, targetLUT: &lut)

        XCTAssertNotNil(merged.expression)
        XCTAssertEqual(merged.expression?.smileDegree, 0.7)
        XCTAssertEqual(merged.expression?.philtrumShortening, 0.4)

        // Sync with expression disabled
        var noExprOptions = AdjustmentSyncOptions.none
        noExprOptions.expression = false
        let mergedNoExpr = AdjustmentSyncEngine.merge(source: source, into: target, options: noExprOptions, sourceLUT: nil, targetLUT: &lut)
        XCTAssertNil(mergedNoExpr.expression)
    }

    // MARK: - 9. Settings Validation

    func testExpressionSettingsValidation() {
        let valid = ExpressionSettings(
            enabled: true,
            smileDegree: 0.5,
            smileWidth: 0.2,
            lipSymmetry: 0.3,
            philtrumShortening: 0.4,
            upperLipPlump: 0.1,
            lowerLipPlump: -0.2,
            lip3DHighlight: 0.6
        )
        XCTAssertNoThrow(try valid.validated())

        // Out of bounds checks
        var invalid = valid
        invalid.smileDegree = 1.5
        XCTAssertThrowsError(try invalid.validated())

        invalid = valid
        invalid.smileWidth = 0.8
        XCTAssertThrowsError(try invalid.validated())

        invalid = valid
        invalid.upperLipPlump = -0.9
        XCTAssertThrowsError(try invalid.validated())
    }
}

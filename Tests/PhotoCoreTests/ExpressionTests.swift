import XCTest
import CoreImage
import CoreGraphics
@testable import PhotoCore

final class ExpressionTests: XCTestCase {

    private static let sharedContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false
    ])
    private var context: CIContext { Self.sharedContext }

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

    /// R3 (2026-11-14): the P2 review caught sample-10's natural smile turning
    /// into a "咧嘴" grimace because `smileDegree` lifted the corners
    /// unconditionally. A mouth that already smiles must keep its headroom
    /// small, so the same slider cannot pile a second smile on top of one that
    /// is already in the photo.
    func testSmileDegreeRespectsExistingSmile() {
        var (_, neutralFace) = makeTestFaceImage()
        // The fixture's own mouth is already a relaxed smile (corners at 0.35,
        // lip centre ≈ 0.35) - flatten it first so both cases are comparable.
        neutralFace.outerLips = neutralFace.outerLips.enumerated().map { index, point in
            // A neutral mouth: the commissures sit level with the lip centre.
            let levels: [Int: CGFloat] = [0: 0.35, 6: 0.35, 2: 0.375, 4: 0.375, 8: 0.32]
            return CGPoint(x: point.x, y: levels[index] ?? point.y)
        }
        var smilingFace = neutralFace
        // A broad grin: both corners raised well above the lip centre.
        smilingFace.outerLips = smilingFace.outerLips.enumerated().map { index, point in
            let levels: [Int: CGFloat] = [0: 0.40, 6: 0.40, 2: 0.395, 4: 0.395, 8: 0.31]
            return CGPoint(x: point.x, y: levels[index] ?? point.y)
        }

        let neutralGeometry = ExpressionGeometry(face: neutralFace)
        let smilingGeometry = ExpressionGeometry(face: smilingFace)
        XCTAssertNotNil(neutralGeometry)
        XCTAssertNotNil(smilingGeometry)
        guard let neutralGeometry, let smilingGeometry else { return }

        XCTAssertLessThan(neutralGeometry.existingSmileArc, smilingGeometry.existingSmileArc,
                          "fixture must give the grinning mouth the larger arc")
        XCTAssertGreaterThan(neutralGeometry.smileHeadroom, smilingGeometry.smileHeadroom,
                             "a mouth that already smiles must have less headroom")

        let settings = ExpressionSettings(enabled: true, smileDegree: 0.8)
        let neutralField = ExpressionEngine.generateWarpField(
            faces: [neutralFace], settings: settings, imageSize: CGSize(width: 400, height: 400))
        let smilingField = ExpressionEngine.generateWarpField(
            faces: [smilingFace], settings: settings, imageSize: CGSize(width: 400, height: 400))
        XCTAssertGreaterThan(neutralField.maximumMagnitude, smilingField.maximumMagnitude,
                             "the same smileDegree must move an already-smiling mouth less")
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

        // Future version 34 should fail
        recipe.version = 34
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 34 is future unsupported")

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

    // MARK: - 10. R8 Background Protection, Head-Roll Alignment & Lip Highlight Headroom

    func testExpressionWarpProtectsBackgroundOutsideFace() {
        func shiftedFace(dx: CGFloat) -> FaceLandmarkSet {
            let (_, baseFace) = makeTestFaceImage()
            func shift(_ pts: [CGPoint]) -> [CGPoint] {
                pts.map { CGPoint(x: $0.x + dx, y: $0.y) }
            }
            return FaceLandmarkSet(
                boundingBox: baseFace.boundingBox.offsetBy(dx: dx, dy: 0),
                confidence: baseFace.confidence,
                faceContour: shift(baseFace.faceContour),
                nose: shift(baseFace.nose),
                outerLips: shift(baseFace.outerLips),
                innerLips: shift(baseFace.innerLips)
            )
        }

        let leftFace = shiftedFace(dx: -0.22)
        let rightFace = shiftedFace(dx: 0.22)
        let settings = ExpressionSettings(enabled: true, smileDegree: 1.0, smileWidth: 0.5)
        let field = ExpressionEngine.generateWarpField(
            faces: [leftFace, rightFace],
            settings: settings,
            imageSize: CGSize(width: 800, height: 600)
        )

        for corner in [CGPoint(x: 0.02, y: 0.02),
                       CGPoint(x: 0.98, y: 0.98),
                       CGPoint(x: 0.02, y: 0.98),
                       CGPoint(x: 0.98, y: 0.02)] {
            let d = field.displacement(at: corner)
            let mag = (d.x * d.x + d.y * d.y).squareRoot()
            XCTAssertLessThan(mag, 1e-6, "Background outside face bounding boxes must stay anchored")
        }

        let leftCornerDisp = field.displacement(at: leftFace.outerLips[0])
        let rightCornerDisp = field.displacement(at: rightFace.outerLips[6])
        XCTAssertGreaterThan((leftCornerDisp.x * leftCornerDisp.x + leftCornerDisp.y * leftCornerDisp.y).squareRoot(), 0.001,
                             "First face must retain expression warp in multi-person scene")
        XCTAssertGreaterThan((rightCornerDisp.x * rightCornerDisp.x + rightCornerDisp.y * rightCornerDisp.y).squareRoot(), 0.001,
                             "Second face must retain expression warp in multi-person scene")
    }

    func testTiltedHeadAlignsSmileAndSymmetryToEyeAxis() throws {
        let (_, baseFace) = makeTestFaceImage()
        let pivot = CGPoint(x: 0.50, y: 0.50)
        let angle = -25.0 * Double.pi / 180.0
        let cosA = cos(angle)
        let sinA = sin(angle)

        func rotate(_ p: CGPoint) -> CGPoint {
            let dx = Double(p.x - pivot.x)
            let dy = Double(p.y - pivot.y)
            return CGPoint(
                x: pivot.x + CGFloat(dx * cosA - dy * sinA),
                y: pivot.y + CGFloat(dx * sinA + dy * cosA)
            )
        }

        let leftEye = [CGPoint(x: 0.40, y: 0.62), CGPoint(x: 0.44, y: 0.62)]
        let rightEye = [CGPoint(x: 0.56, y: 0.62), CGPoint(x: 0.60, y: 0.62)]
        let symmetricNeutralLips: [CGPoint] = [
            CGPoint(x: 0.40, y: 0.35),
            CGPoint(x: 0.43, y: 0.37),
            CGPoint(x: 0.47, y: 0.38),
            CGPoint(x: 0.50, y: 0.375),
            CGPoint(x: 0.53, y: 0.38),
            CGPoint(x: 0.57, y: 0.37),
            CGPoint(x: 0.60, y: 0.35),
            CGPoint(x: 0.57, y: 0.33),
            CGPoint(x: 0.50, y: 0.32),
            CGPoint(x: 0.43, y: 0.33)
        ]

        let tiltedFace = FaceLandmarkSet(
            boundingBox: baseFace.boundingBox,
            confidence: 0.98,
            faceContour: baseFace.faceContour.map(rotate),
            leftEye: leftEye.map(rotate),
            rightEye: rightEye.map(rotate),
            nose: baseFace.nose.map(rotate),
            outerLips: symmetricNeutralLips.map(rotate),
            innerLips: baseFace.innerLips.map(rotate)
        )

        let geometry = try XCTUnwrap(ExpressionGeometry(face: tiltedFace))
        XCTAssertEqual(geometry.rightAxis.x, cosA, accuracy: 0.02)
        XCTAssertEqual(geometry.rightAxis.y, sinA, accuracy: 0.02)
        XCTAssertEqual(geometry.upAxis.x, -sinA, accuracy: 0.02)
        XCTAssertEqual(geometry.upAxis.y, cosA, accuracy: 0.02)

        let symField = ExpressionEngine.generateWarpField(
            faces: [tiltedFace],
            settings: ExpressionSettings(enabled: true, lipSymmetry: 1.0),
            imageSize: CGSize(width: 400, height: 400)
        )
        XCTAssertLessThan(symField.maximumMagnitude, 1e-4,
                          "A symmetric smile on a tilted head must not be skewed by lipSymmetry")

        let smileField = ExpressionEngine.generateWarpField(
            faces: [tiltedFace],
            settings: ExpressionSettings(enabled: true, smileDegree: 0.8),
            imageSize: CGSize(width: 400, height: 400)
        )
        let leftDisp = smileField.displacement(at: geometry.leftCorner)
        let rightDisp = smileField.displacement(at: geometry.rightCorner)
        let leftUp = leftDisp.x * geometry.upAxis.x + leftDisp.y * geometry.upAxis.y
        let rightUp = rightDisp.x * geometry.upAxis.x + rightDisp.y * geometry.upAxis.y
        let leftRight = leftDisp.x * geometry.rightAxis.x + leftDisp.y * geometry.rightAxis.y
        let rightRight = rightDisp.x * geometry.rightAxis.x + rightDisp.y * geometry.rightAxis.y
        XCTAssertGreaterThan(leftUp, 0.001, "Left corner must lift along head upAxis")
        XCTAssertGreaterThan(rightUp, 0.001, "Right corner must lift along head upAxis")
        XCTAssertLessThan(leftRight, 0, "Left corner must move outward along -rightAxis")
        XCTAssertGreaterThan(rightRight, 0, "Right corner must move outward along +rightAxis")
    }

    func testLip3DHighlightUsesHeadroomWithoutClippingBrightRegions() {
        let (_, face) = makeTestFaceImage()
        let width = 400, height = 400
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

        func makeLipImage(lipRGB: (Float, Float, Float)) -> CIImage {
            var data = [Float](repeating: 0, count: width * height * 4)
            for row in 0..<height {
                for col in 0..<width {
                    let i = (row * width + col) * 4
                    // Place an HDR highlight pixel outside the face (bottom-left corner in CI coords).
                    if col < 40 && row < 40 {
                        data[i] = 1.40; data[i + 1] = 1.40; data[i + 2] = 1.40; data[i + 3] = 1.0
                    } else {
                        data[i] = lipRGB.0; data[i + 1] = lipRGB.1; data[i + 2] = lipRGB.2; data[i + 3] = 1.0
                    }
                }
            }
            return CIImage(
                bitmapData: Data(bytes: &data, count: data.count * MemoryLayout<Float>.stride),
                bytesPerRow: width * 16,
                size: CGSize(width: width, height: height),
                format: .RGBAf,
                colorSpace: linear
            )
        }

        func samplePixel(_ image: CIImage, x: Int, y: Int) -> Float {
            var px = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &px, rowBytes: 16,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBAf, colorSpace: linear)
            return px[0]
        }

        let settings = ExpressionSettings(enabled: true, lip3DHighlight: 1.0)
        let darkInput = makeLipImage(lipRGB: (0.15, 0.08, 0.08))
        let brightInput = makeLipImage(lipRGB: (0.85, 0.70, 0.68))

        let darkOut = ExpressionEngine.apply(to: darkInput, faces: [face], settings: settings).image
        let brightOut = ExpressionEngine.apply(to: brightInput, faces: [face], settings: settings).image

        // Upper lip tubercle sits near normalized (0.50, 0.365) -> pixel (200, 146)
        let darkDelta = samplePixel(darkOut, x: 200, y: 146) - 0.15
        let brightDelta = samplePixel(brightOut, x: 200, y: 146) - 0.85
        XCTAssertGreaterThan(darkDelta, 0.02, "Dark lip should receive visible pearlescent lift")
        XCTAssertLessThan(brightDelta, darkDelta * 0.5,
                          "Bright lip highlight must attenuate by headroom instead of clipping")

        let hdrOut = samplePixel(darkOut, x: 20, y: 20)
        XCTAssertEqual(hdrOut, 1.40, accuracy: 0.01,
                       "HDR pixels outside lip guide must pass through unclipped")
    }
}

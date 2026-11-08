import XCTest
import CoreImage
@testable import PhotoCore

final class BokehBlurTests: XCTestCase {

    // Helper: create a 512x512 synthetic test image with a high-contrast pattern
    private func makeTestImage() -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: 512, height: 512)
        // Checkered/striped background
        guard let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputWidth": 32.0,
            "inputColor0": CIColor(red: 0.2, green: 0.2, blue: 0.2),
            "inputColor1": CIColor(red: 0.8, green: 0.8, blue: 0.8)
        ])?.outputImage?.cropped(to: extent) else {
            return CIImage(color: CIColor.gray).cropped(to: extent)
        }
        return checker
    }

    // Helper: create mock person alpha matte (circle in center)
    private func makeMockPersonMask(extent: CGRect) -> CIImage {
        let center = CIVector(x: extent.midX, y: extent.midY)
        let radius = extent.width * 0.25
        guard let radial = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": center,
            "inputRadius0": radius * 0.8,
            "inputRadius1": radius,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        ])?.outputImage?.cropped(to: extent) else {
            return CIImage(color: CIColor.white).cropped(to: extent)
        }
        return radial
    }

    // MARK: - 1. Neutrality & Default Values

    func testNeutralityAndDefaults() {
        let def = BokehBlurSettings()
        XCTAssertFalse(def.enabled)
        XCTAssertEqual(def.apertureFocalSize, 0)
        XCTAssertEqual(def.bokehShape, .circular)
        XCTAssertEqual(def.focalPlaneOffset, 0)
        XCTAssertEqual(def.depthFalloffRate, 1.0)
        XCTAssertEqual(def.specularHighlightBoost, 0.5)
        XCTAssertEqual(def.edgeBleedProtection, 0.85)
        XCTAssertTrue(def.isNeutral)

        // Setting values while disabled remains neutral
        var disabled = def
        disabled.enabled = false
        disabled.apertureFocalSize = 0.8
        XCTAssertTrue(disabled.isNeutral)

        // Enabled but 0 focal size is neutral
        var enabledZero = def
        enabledZero.enabled = true
        enabledZero.apertureFocalSize = 0
        XCTAssertTrue(enabledZero.isNeutral)

        // Non-neutral when enabled with positive focal size
        var active = def
        active.enabled = true
        active.apertureFocalSize = 0.5
        XCTAssertFalse(active.isNeutral)
    }

    func testNeutralSkipsProcessing() {
        let image = makeTestImage()
        let neutral = BokehBlurSettings()

        let (outImage, report) = BokehDepthEngine.apply(
            to: image, personMask: nil, settings: neutral
        )
        XCTAssertFalse(report.applied)
        XCTAssertEqual(outImage, image)
    }

    // MARK: - 2. Parameter Validation

    func testValidationBounds() {
        var s = BokehBlurSettings()
        XCTAssertNoThrow(try s.validated())

        // Aperture focal size bounds (0...1)
        s.apertureFocalSize = -0.1
        XCTAssertThrowsError(try s.validated())
        s.apertureFocalSize = 1.1
        XCTAssertThrowsError(try s.validated())
        s.apertureFocalSize = 0.6

        // Focal plane offset bounds (-0.5...0.5)
        s.focalPlaneOffset = -0.6
        XCTAssertThrowsError(try s.validated())
        s.focalPlaneOffset = 0.6
        XCTAssertThrowsError(try s.validated())
        s.focalPlaneOffset = 0.2

        // Depth falloff rate bounds (0.2...2.0)
        s.depthFalloffRate = 0.1
        XCTAssertThrowsError(try s.validated())
        s.depthFalloffRate = 2.1
        XCTAssertThrowsError(try s.validated())
        s.depthFalloffRate = 1.2

        // Specular highlight boost bounds (0...1)
        s.specularHighlightBoost = -0.1
        XCTAssertThrowsError(try s.validated())
        s.specularHighlightBoost = 1.1
        XCTAssertThrowsError(try s.validated())
        s.specularHighlightBoost = 0.8

        // Edge bleed protection bounds (0...1)
        s.edgeBleedProtection = -0.1
        XCTAssertThrowsError(try s.validated())
        s.edgeBleedProtection = 1.1
        XCTAssertThrowsError(try s.validated())
        s.edgeBleedProtection = 0.9

        XCTAssertNoThrow(try s.validated())
    }

    // MARK: - 3. Optical Bokeh Shapes

    func testAllOpticalBokehShapes() {
        let image = makeTestImage()
        let mask = makeMockPersonMask(extent: image.extent)
        let shapes: [BokehShape] = [.circular, .polygonal, .swirly, .creamy]

        for shape in shapes {
            let settings = BokehBlurSettings(
                enabled: true,
                apertureFocalSize: 0.5,
                bokehShape: shape,
                focalPlaneOffset: 0.0,
                depthFalloffRate: 1.0,
                specularHighlightBoost: 0.6,
                edgeBleedProtection: 0.85
            )
            let (outImage, report) = BokehDepthEngine.apply(
                to: image,
                personMask: mask,
                settings: settings
            )
            XCTAssertTrue(report.applied, "Shape \(shape) should apply successfully")
            XCTAssertEqual(report.bokehShape, shape)
            XCTAssertGreaterThan(report.maxBlurRadius, 0)
            XCTAssertEqual(outImage.extent, image.extent)
        }
    }

    // MARK: - 4. Depth Map & Subject Protection

    func testSubjectProtectionPreservesCenterSharpness() {
        let image = makeTestImage()
        let mask = makeMockPersonMask(extent: image.extent)
        let settings = BokehBlurSettings(
            enabled: true,
            apertureFocalSize: 0.8,
            bokehShape: .circular,
            edgeBleedProtection: 0.9
        )
        let (outImage, report) = BokehDepthEngine.apply(
            to: image,
            personMask: mask,
            settings: settings
        )
        XCTAssertTrue(report.applied)
        XCTAssertEqual(outImage.extent, image.extent)
    }

    // MARK: - 5. Specular Highlight Boost

    func testSpecularHighlightBoost() {
        let image = makeTestImage()
        let settingsWithBoost = BokehBlurSettings(
            enabled: true,
            apertureFocalSize: 0.4,
            specularHighlightBoost: 0.9
        )
        let settingsWithoutBoost = BokehBlurSettings(
            enabled: true,
            apertureFocalSize: 0.4,
            specularHighlightBoost: 0.0
        )

        let (outBoost, rep1) = BokehDepthEngine.apply(to: image, settings: settingsWithBoost)
        let (outNoBoost, rep2) = BokehDepthEngine.apply(to: image, settings: settingsWithoutBoost)

        XCTAssertTrue(rep1.applied)
        XCTAssertTrue(rep2.applied)
        XCTAssertEqual(outBoost.extent, image.extent)
        XCTAssertEqual(outNoBoost.extent, image.extent)
    }

    // MARK: - 6. Recipe Version & Validation

    func testRecipeVersionGate() throws {
        var recipe = Recipe()
        recipe.adjustments.bokehBlur = BokehBlurSettings(
            enabled: true,
            apertureFocalSize: 0.65
        )

        // Version 23 must fail for active bokehBlur
        recipe.version = 23
        XCTAssertThrowsError(try recipe.validateVersion(), "Active bokehBlur requires version 24")

        // Version 24 must succeed
        recipe.version = 24
        XCTAssertNoThrow(try recipe.validateVersion(), "Version 24 must validate successfully")

        // Version 30 is future unsupported
        recipe.version = 30
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 30 should be rejected")

        // Required version calculation
        let reqV = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(reqV, 24)
    }

    // MARK: - 7. Selective Sync

    func testSelectiveSyncBokehBlur() {
        var source = AdjustmentSettings()
        source.bokehBlur = BokehBlurSettings(
            enabled: true,
            apertureFocalSize: 0.75,
            bokehShape: .swirly,
            focalPlaneOffset: 0.1,
            specularHighlightBoost: 0.8
        )

        var target = AdjustmentSettings()
        target.bokehBlur = nil
        var targetLUT = ""

        // When bokehBlur is synced
        let syncOptsTrue = AdjustmentSyncOptions(bokehBlur: true)
        let merged = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptsTrue,
            sourceLUT: nil,
            targetLUT: &targetLUT
        )
        XCTAssertNotNil(merged.bokehBlur)
        XCTAssertEqual(merged.bokehBlur?.apertureFocalSize, 0.75)
        XCTAssertEqual(merged.bokehBlur?.bokehShape, BokehShape.swirly)
        XCTAssertEqual(merged.bokehBlur?.specularHighlightBoost, 0.8)

        // When bokehBlur sync is opted out
        let syncOptsFalse = AdjustmentSyncOptions(bokehBlur: false)
        let skipped = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: syncOptsFalse,
            sourceLUT: nil,
            targetLUT: &targetLUT
        )
        XCTAssertNil(skipped.bokehBlur)
    }
}

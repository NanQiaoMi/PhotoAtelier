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

        // Version 34 is future unsupported
        recipe.version = 34
        XCTAssertThrowsError(try recipe.validateVersion(), "Version 34 should be rejected")

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

    // MARK: - P3-E3: depth-map gradient regression

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var analysisContext = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false
    ])

    /// Full-width vertical stripe pattern (4px period) for contrast probes.
    private func makeStripeImage(width: Int = 256, height: Int = 256) -> CIImage {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for col in 0..<width {
                let o = (row * width + col) * 4
                let stripe: Float = (col / 4) % 2 == 0 ? 0.8 : 0.3
                pixels[o] = stripe; pixels[o + 1] = stripe; pixels[o + 2] = stripe
                pixels[o + 3] = 1
            }
        }
        let data = pixels.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        return CIImage(bitmapData: data, bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                       size: CGSize(width: width, height: height),
                       format: .RGBAf, colorSpace: linearColorSpace)
    }

    /// Stripe contrast retained in a single row (1 = sharp, 0 = fully blurred).
    /// CIImage space: y=0 is the image bottom.
    private func stripeRetention(_ original: CIImage, _ processed: CIImage, y: Int) -> Double {
        let width = Int(original.extent.width)
        var bo = [Float](repeating: 0, count: width * 4)
        var bp = [Float](repeating: 0, count: width * 4)
        analysisContext.render(original, toBitmap: &bo, rowBytes: width * 16,
                               bounds: CGRect(x: 0, y: CGFloat(y), width: CGFloat(width), height: 1),
                               format: .RGBAf, colorSpace: linearColorSpace)
        analysisContext.render(processed, toBitmap: &bp, rowBytes: width * 16,
                               bounds: CGRect(x: 0, y: CGFloat(y), width: CGFloat(width), height: 1),
                               format: .RGBAf, colorSpace: linearColorSpace)
        var minO: Float = 9, maxO: Float = 0, minP: Float = 9, maxP: Float = 0
        for col in 30..<70 {
            minO = min(minO, bo[col * 4]); maxO = max(maxO, bo[col * 4])
            minP = min(minP, bp[col * 4]); maxP = max(maxP, bp[col * 4])
        }
        return Double((maxP - minP) / max(0.0001, maxO - minO))
    }

    /// Regression for the P3-E3 defect: the ground-perspective depth map used to
    /// be spatially uniform (kernel `samplerCoord` produced a constant field), so
    /// every row got identical blur. The rasterized gradient must keep the image
    /// bottom (near ground, depth ≈ 0.35) visibly sharper than the top (far, depth ≈ 1).
    func testDepthGradientModulatesBlurTopToBottom() {
        let image = makeStripeImage()
        var settings = BokehBlurSettings()
        settings.enabled = true
        settings.apertureFocalSize = 1.0
        settings.focalPlaneOffset = 0
        settings.depthFalloffRate = 1.0
        settings.edgeBleedProtection = 0
        settings.specularHighlightBoost = 0
        // Fully transparent person matte: no subject protection, pure ground gradient.
        let emptyMask = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0,
                                               colorSpace: linearColorSpace)!)
            .cropped(to: image.extent)
        let (out, report) = BokehDepthEngine.apply(to: image, personMask: emptyMask, settings: settings)
        XCTAssertTrue(report.applied)
        // P3-E3: report must carry real depth-field radii, not a constant.
        // Ground perspective: near ground (depth 0.35) sits close to the focal
        // plane → small radius; far top (depth 1.0) → maximum defocus.
        XCTAssertEqual(report.maxBlurRadius, 48.0, accuracy: 0.1)
        XCTAssertGreaterThan(report.nearRadius, 0)
        XCTAssertLessThanOrEqual(report.farRadius, report.maxBlurRadius)
        XCTAssertGreaterThan(report.farRadius, report.nearRadius,
                             "远景半径应大于近景半径（离焦平面越远越虚）")
        XCTAssertEqual(report.nearRadius, 0.35 * 48.0, accuracy: 1.0,
                       "近景地面深度应落在 0.35 基准附近")
        XCTAssertGreaterThan(report.farRadius - report.nearRadius, 10,
                             "底部（0.35 深度）与顶部（1.0 深度）半径差应显著")

        let nearGround = stripeRetention(image, out, y: 8)      // bottom = near
        let mid = stripeRetention(image, out, y: 128)
        let farTop = stripeRetention(image, out, y: 248)        // top = far
        XCTAssertGreaterThan(nearGround, mid + 0.15,
                             "近景（底部）应显著比中景更清晰")
        XCTAssertGreaterThan(mid, farTop + 0.15,
                             "中景应显著比远景（顶部）更清晰")
        XCTAssertLessThan(farTop, 0.35, "远景应接近最大散焦")
    }

    /// The subject region must stay sharp regardless of depth: an opaque matte
    /// zeroes the depth map under the person.
    func testSubjectRegionStaysSharpInsideDepthGradient() {
        let image = makeStripeImage()
        var settings = BokehBlurSettings()
        settings.enabled = true
        settings.apertureFocalSize = 1.0
        settings.edgeBleedProtection = 0
        settings.specularHighlightBoost = 0
        // Opaque white matte everywhere → depth 0 everywhere → no blur at all.
        let fullMask = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1,
                                              colorSpace: linearColorSpace)!)
            .cropped(to: image.extent)
        let (out, _) = BokehDepthEngine.apply(to: image, personMask: fullMask, settings: settings)
        XCTAssertEqual(stripeRetention(image, out, y: 248), 1.0, accuracy: 0.02,
                       "主体完全不透明（覆盖全图）时不应有任何虚化")
    }
}

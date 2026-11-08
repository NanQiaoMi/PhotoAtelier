import XCTest
import CoreImage
@testable import PhotoCore

final class SkyEnhancementTests: XCTestCase {

    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    func testSkyEnhancementSettingsDefaultsAndValidation() throws {
        var settings = SkyEnhancementSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.skyVibrance, 0)
        XCTAssertEqual(settings.cloudContrast, 0)
        XCTAssertEqual(settings.sunsetWarmth, 0)
        XCTAssertEqual(settings.skyPreset, .none)
        XCTAssertEqual(settings.replacementOpacity, 0.80)
        XCTAssertEqual(settings.foregroundRelight, 0.35)
        XCTAssertEqual(settings.edgeFeather, 0.50)
        XCTAssertTrue(settings.isNeutral)

        // Enabling with 0 strengths is still neutral
        settings.enabled = true
        XCTAssertTrue(settings.isNeutral)

        // Enabling with non-zero strength makes it active
        settings.skyVibrance = 0.5
        XCTAssertFalse(settings.isNeutral)

        _ = try settings.validated()

        // Validation throws for out-of-bounds parameters
        var invalid = settings
        invalid.skyVibrance = 1.5
        XCTAssertThrowsError(try invalid.validated())

        invalid = settings
        invalid.cloudContrast = -0.1
        XCTAssertThrowsError(try invalid.validated())

        invalid = settings
        invalid.sunsetWarmth = 2.0
        XCTAssertThrowsError(try invalid.validated())

        invalid = settings
        invalid.replacementOpacity = 1.05
        XCTAssertThrowsError(try invalid.validated())

        invalid = settings
        invalid.foregroundRelight = -0.01
        XCTAssertThrowsError(try invalid.validated())

        invalid = settings
        invalid.edgeFeather = 1.2
        XCTAssertThrowsError(try invalid.validated())
    }

    func testRecipeVersion19Gating() throws {
        var recipe = Recipe()
        recipe.version = 18
        // Neutral sky passes version 18
        recipe.adjustments.sky = SkyEnhancementSettings()
        try recipe.validateVersion()

        // Non-neutral sky must fail on version 18
        recipe.adjustments.sky = SkyEnhancementSettings(enabled: true, skyVibrance: 0.5)
        XCTAssertThrowsError(try recipe.validateVersion())

        // Version 19 must pass
        recipe.version = 19
        try recipe.validateVersion()

        // Future version 26 must fail
        recipe.version = 26
        XCTAssertThrowsError(try recipe.validateVersion())

        // Required recipe version calculation
        let reqV = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(reqV, 19)
    }

    func testLegacyRecipeRoundTrip() throws {
        var recipe = Recipe()
        recipe.version = 18
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(Recipe.self, from: data)
        XCTAssertNil(decoded.adjustments.sky)
    }

    func testNeutralSettingsLeavePixelsCompletelyUnchanged() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let input = createSyntheticLandscapeImage(extent: extent)

        let skyMask = createSyntheticSkyMask(extent: extent)

        // 1. Disabled
        let disabledSettings = SkyEnhancementSettings(enabled: false, skyVibrance: 0.8)
        let (disabledImage, disabledReport) = try SkyEnhancementEngine.apply(
            input, settings: disabledSettings, precomputedSkyMask: skyMask, context: context
        )
        XCTAssertFalse(disabledReport.applied)
        XCTAssertTrue(compareImagesExact(input, disabledImage, extent: extent))

        // 2. Enabled but neutral
        let neutralSettings = SkyEnhancementSettings(enabled: true)
        let (neutralImage, neutralReport) = try SkyEnhancementEngine.apply(
            input, settings: neutralSettings, precomputedSkyMask: skyMask, context: context
        )
        XCTAssertFalse(neutralReport.applied)
        XCTAssertTrue(compareImagesExact(input, neutralImage, extent: extent))
    }

    func testGracefulSkipWhenNoSkyDetected() throws {
        let extent = CGRect(x: 0, y: 0, width: 128, height: 128)
        let input = createSyntheticLandscapeImage(extent: extent)

        // An empty black mask representing no sky
        let blackMask = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        let settings = SkyEnhancementSettings(enabled: true, skyVibrance: 0.8)

        let (outImage, report) = try SkyEnhancementEngine.apply(
            input, settings: settings, precomputedSkyMask: blackMask, context: context
        )
        XCTAssertFalse(report.applied)
        XCTAssertTrue(compareImagesExact(input, outImage, extent: extent))
    }

    func testSkyVibranceRestoresAzureToneInWashedSky() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let input = createSyntheticLandscapeImage(extent: extent)
        let skyMask = createSyntheticSkyMask(extent: extent)

        let settings = SkyEnhancementSettings(enabled: true, skyVibrance: 0.80)
        let (resultImage, report) = try SkyEnhancementEngine.apply(
            input, settings: settings, precomputedSkyMask: skyMask, context: context
        )
        XCTAssertTrue(report.applied)
        XCTAssertTrue(report.appliedSteps.contains("湛蓝天色"))

        // Probe upper washed sky at (x: 64, y: 100)
        let before = samplePixel(input, at: (x: 64, y: 100), extent: extent)
        let after = samplePixel(resultImage, at: (x: 64, y: 100), extent: extent)

        // Blue channel should increase and (Blue - Red) delta should expand significantly
        let beforeDelta = before.b - before.r
        let afterDelta = after.b - after.r

        XCTAssertGreaterThan(afterDelta, beforeDelta + 0.08, "湛蓝天色还原应显著增强天穹的蓝/青色阶对比。")
    }

    func testCloudContrastEnhancesCumulusDefinition() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let input = createSyntheticLandscapeImage(extent: extent)
        let skyMask = createSyntheticSkyMask(extent: extent)

        let settings = SkyEnhancementSettings(enabled: true, cloudContrast: 0.85)
        let (resultImage, report) = try SkyEnhancementEngine.apply(
            input, settings: settings, precomputedSkyMask: skyMask, context: context
        )
        XCTAssertTrue(report.applied)
        XCTAssertTrue(report.appliedSteps.contains("云层反差"))

        // Measure local variance in the cloud region (x: 40...88, y: 75...95)
        let beforeVar = measureLocalContrast(image: input, rect: CGRect(x: 40, y: 75, width: 48, height: 20))
        let afterVar = measureLocalContrast(image: resultImage, rect: CGRect(x: 40, y: 75, width: 48, height: 20))

        XCTAssertGreaterThan(afterVar, beforeVar * 1.05, "云层反差应显著提升积云明暗纹理立体感。")
    }

    func testSunsetWarmthInjectsGlowNearHorizon() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let input = createSyntheticLandscapeImage(extent: extent)
        let skyMask = createSyntheticSkyMask(extent: extent)

        let settings = SkyEnhancementSettings(enabled: true, sunsetWarmth: 0.85)
        let (resultImage, report) = try SkyEnhancementEngine.apply(
            input, settings: settings, precomputedSkyMask: skyMask, context: context
        )
        XCTAssertTrue(report.applied)
        XCTAssertTrue(report.appliedSteps.contains("晚霞氛围"))

        // Probe near horizon at (x: 64, y: 60)
        let before = samplePixel(input, at: (x: 64, y: 60), extent: extent)
        let after = samplePixel(resultImage, at: (x: 64, y: 60), extent: extent)

        // Warm sunset amber increases R channel relative to B channel
        let beforeWarmth = before.r - before.b
        let afterWarmth = after.r - after.b

        XCTAssertGreaterThan(afterWarmth, beforeWarmth + 0.05, "晚霞氛围应向近地平线区域注入金橙暖光。")
    }

    func testProceduralSkyPresetReplacement() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let input = createSyntheticLandscapeImage(extent: extent)
        let skyMask = createSyntheticSkyMask(extent: extent)

        let settings = SkyEnhancementSettings(enabled: true, skyPreset: .sunsetGlow, replacementOpacity: 0.90)
        let (resultImage, report) = try SkyEnhancementEngine.apply(
            input, settings: settings, precomputedSkyMask: skyMask, context: context
        )
        XCTAssertTrue(report.applied)
        XCTAssertTrue(report.appliedSteps.contains { $0.contains("天空置换") })

        // Check sky color at zenith (y: 110)
        let zenith = samplePixel(resultImage, at: (x: 64, y: 110), extent: extent)
        // SunsetGlow zenith has purple/crimson tone
        XCTAssertGreaterThan(zenith.r, 0.20)
    }

    func testForegroundRelightingTransfersAmbientGlow() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let input = createSyntheticLandscapeImage(extent: extent)
        let skyMask = createSyntheticSkyMask(extent: extent)

        // Golden sunset preset with foreground relighting
        let settings = SkyEnhancementSettings(enabled: true, skyPreset: .sunsetGlow, foregroundRelight: 0.80)
        let (resultImage, report) = try SkyEnhancementEngine.apply(
            input, settings: settings, precomputedSkyMask: skyMask, context: context
        )
        XCTAssertTrue(report.applied)
        XCTAssertTrue(report.appliedSteps.contains("前景光照匹配"))

        // Probe ground foreground at (x: 64, y: 20)
        let beforeFG = samplePixel(input, at: (x: 64, y: 20), extent: extent)
        let afterFG = samplePixel(resultImage, at: (x: 64, y: 20), extent: extent)

        let beforeL = 0.2126 * beforeFG.r + 0.7152 * beforeFG.g + 0.0722 * beforeFG.b
        let afterL = 0.2126 * afterFG.r + 0.7152 * afterFG.g + 0.0722 * afterFG.b

        XCTAssertGreaterThan(afterL, beforeL * 1.01, "前景环境光照匹配应温和照亮地面与主体。")
    }

    func testEngineProcessPipelineIntegratesSkyEnhancement() throws {
        let extent = CGRect(x: 0, y: 0, width: 128, height: 128)
        let input = createSyntheticLandscapeImage(extent: extent)
        let skyMask = createSyntheticSkyMask(extent: extent)

        var adjustments = AdjustmentSettings()
        adjustments.sky = SkyEnhancementSettings(enabled: true, skyVibrance: 0.6, cloudContrast: 0.5)

        let engine = PhotoEngine()
        let processed = try engine.process(input, settings: adjustments, lut: nil, preparedSkyMask: skyMask)

        XCTAssertNotNil(processed.report.sky)
        XCTAssertTrue(processed.report.sky?.applied == true)
        XCTAssertTrue(processed.report.sky?.appliedSteps.contains("湛蓝天色") == true)
        XCTAssertTrue(processed.report.sky?.appliedSteps.contains("云层反差") == true)
    }

    // MARK: - Synthetic Fixtures & Helpers

    private func createSyntheticLandscapeImage(extent: CGRect) -> CIImage {
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        }

        // Lower half: dark green landscape ground (y: 0...50)
        ctx.setFillColor(red: 50.0/255.0, green: 90.0/255.0, blue: 40.0/255.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 50))

        // Upper half: washed-out pale sky with subtle gray clouds (y: 50...128)
        ctx.setFillColor(red: 220.0/255.0, green: 225.0/255.0, blue: 230.0/255.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 50, width: width, height: 78))

        // Synthetic cumulus cloud puffs in sky (y: 75...95)
        ctx.setFillColor(red: 245.0/255.0, green: 245.0/255.0, blue: 250.0/255.0, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 35, y: 75, width: 35, height: 20))
        ctx.fillEllipse(in: CGRect(x: 60, y: 78, width: 40, height: 22))

        ctx.setFillColor(red: 195.0/255.0, green: 200.0/255.0, blue: 205.0/255.0, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 45, y: 72, width: 30, height: 12))

        guard let cg = ctx.makeImage() else {
            return CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        }
        return CIImage(cgImage: cg)
    }

    private func createSyntheticSkyMask(extent: CGRect) -> CIImage {
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        }

        // Ground is 0.0
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 50))

        // Sky is 1.0
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 50, width: width, height: 78))

        guard let cg = ctx.makeImage() else {
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        }

        return CIImage(cgImage: cg).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3.0])
            .cropped(to: extent)
    }

    private func compareImagesExact(_ img1: CIImage, _ img2: CIImage, extent: CGRect) -> Bool {
        let width = Int(extent.width)
        let height = Int(extent.height)
        let rowBytes = width * 4
        var b1 = [UInt8](repeating: 0, count: rowBytes * height)
        var b2 = [UInt8](repeating: 0, count: rowBytes * height)

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        context.render(img1, toBitmap: &b1, rowBytes: rowBytes, bounds: extent, format: .RGBA8, colorSpace: cs)
        context.render(img2, toBitmap: &b2, rowBytes: rowBytes, bounds: extent, format: .RGBA8, colorSpace: cs)

        return b1 == b2
    }

    private func samplePixel(_ image: CIImage, at point: (x: Int, y: Int), extent: CGRect) -> (r: Double, g: Double, b: Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let probeRect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: probeRect, format: .RGBA8, colorSpace: cs)
        return (Double(pixel[0]) / 255.0, Double(pixel[1]) / 255.0, Double(pixel[2]) / 255.0)
    }

    private func measureLocalContrast(image: CIImage, rect: CGRect) -> Double {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        let rowBytes = width * 4
        var bitmap = [UInt8](repeating: 0, count: rowBytes * height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        context.render(image, toBitmap: &bitmap, rowBytes: rowBytes, bounds: image.extent, format: .RGBA8, colorSpace: cs)

        var values: [Double] = []
        let minX = Int(rect.minX), maxX = Int(rect.maxX)
        let minY = Int(rect.minY), maxY = Int(rect.maxY)

        for y in minY..<maxY {
            for x in minX..<maxX {
                let idx = (y * width + x) * 4
                if idx + 2 < bitmap.count {
                    let r = Double(bitmap[idx]) / 255.0
                    let g = Double(bitmap[idx + 1]) / 255.0
                    let b = Double(bitmap[idx + 2]) / 255.0
                    values.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
                }
            }
        }

        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return sqrt(variance)
    }
}

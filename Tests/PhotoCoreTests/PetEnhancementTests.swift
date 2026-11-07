import XCTest
import CoreImage
@testable import PhotoCore

final class PetEnhancementTests: XCTestCase {

    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    func testPetEnhancementSettingsDefaultsAndValidation() throws {
        var settings = PetEnhancementSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.furFluffiness, 0)
        XCTAssertEqual(settings.eyeBrightening, 0)
        XCTAssertEqual(settings.muzzleMoisture, 0)
        XCTAssertEqual(settings.coatDehaze, 0)
        XCTAssertEqual(settings.coatWhiten, 0)
        XCTAssertEqual(settings.texturePreservation, 0.70)
        XCTAssertTrue(settings.isNeutral)

        // Enabling with 0 strengths is still neutral
        settings.enabled = true
        XCTAssertTrue(settings.isNeutral)

        // Enabling with any non-zero strength makes it non-neutral
        settings.furFluffiness = 0.5
        XCTAssertFalse(settings.isNeutral)

        // Validation passes for valid range
        _ = try settings.validated()

        // Validation throws for out of bounds
        var invalid = settings
        invalid.furFluffiness = 1.5
        XCTAssertThrowsError(try invalid.validated())

        invalid = settings
        invalid.eyeBrightening = -0.1
        XCTAssertThrowsError(try invalid.validated())

        invalid = settings
        invalid.muzzleMoisture = 2.0
        XCTAssertThrowsError(try invalid.validated())

        invalid = settings
        invalid.coatDehaze = -0.5
        XCTAssertThrowsError(try invalid.validated())

        invalid = settings
        invalid.coatWhiten = 1.2
        XCTAssertThrowsError(try invalid.validated())

        invalid = settings
        invalid.texturePreservation = -0.01
        XCTAssertThrowsError(try invalid.validated())
    }

    func testRecipeVersion18Gating() throws {
        var recipe = Recipe()
        recipe.version = 17
        // Neutral pet settings should pass version 17
        recipe.adjustments.petEnhancement = PetEnhancementSettings()
        try recipe.validateVersion()

        // Non-neutral pet settings must fail on version 17
        recipe.adjustments.petEnhancement = PetEnhancementSettings(enabled: true, furFluffiness: 0.5)
        XCTAssertThrowsError(try recipe.validateVersion())

        // Version 18 must pass with non-neutral pet settings
        recipe.version = 18
        try recipe.validateVersion()

        // Unsupported future version 22 must fail
        recipe.version = 22
        XCTAssertThrowsError(try recipe.validateVersion())

        // Required recipe version calculation
        let requiredV = PhotoEngine.requiredRecipeVersion(adjustments: recipe.adjustments, automatic: nil)
        XCTAssertEqual(requiredV, 18)
    }

    func testLegacyRecipeRoundTrip() throws {
        var recipe = Recipe()
        recipe.version = 17
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(Recipe.self, from: data)
        XCTAssertNil(decoded.adjustments.petEnhancement)
    }

    func testNeutralSettingsLeavePixelsCompletelyUnchanged() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let input = createSyntheticCatImage(extent: extent)

        let target = PetTarget(boundingBox: CGRect(x: 0.15, y: 0.15, width: 0.70, height: 0.70))

        // 1. Disabled
        var disabledSettings = PetEnhancementSettings(enabled: false, furFluffiness: 0.8)
        let (disabledImage, disabledReport) = try PetEnhancementEngine.apply(
            input, settings: disabledSettings, targets: [target], context: context
        )
        XCTAssertFalse(disabledReport.applied)
        XCTAssertTrue(compareImagesExact(input, disabledImage, extent: extent))

        // 2. Enabled but all 0 strengths
        let neutralSettings = PetEnhancementSettings(enabled: true)
        let (neutralImage, neutralReport) = try PetEnhancementEngine.apply(
            input, settings: neutralSettings, targets: [target], context: context
        )
        XCTAssertFalse(neutralReport.applied)
        XCTAssertTrue(compareImagesExact(input, neutralImage, extent: extent))
    }

    func testGracefulSkipWhenNoPetDetected() throws {
        let extent = CGRect(x: 0, y: 0, width: 128, height: 128)
        let input = createSyntheticCatImage(extent: extent)

        let settings = PetEnhancementSettings(enabled: true, furFluffiness: 0.8)
        let (outImage, report) = try PetEnhancementEngine.apply(
            input, settings: settings, targets: [], context: context
        )
        XCTAssertFalse(report.applied)
        XCTAssertEqual(report.petCount, 0)
        XCTAssertTrue(compareImagesExact(input, outImage, extent: extent))
    }

    func testFurFluffinessEnhancesHighFrequencyMicroContrast() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let input = createSyntheticCatImage(extent: extent)

        let target = PetTarget(boundingBox: CGRect(x: 0.15, y: 0.15, width: 0.70, height: 0.70))
        let settings = PetEnhancementSettings(enabled: true, furFluffiness: 0.85, texturePreservation: 0.80)

        let (resultImage, report) = try PetEnhancementEngine.apply(
            input, settings: settings, targets: [target], context: context
        )
        XCTAssertTrue(report.applied)
        XCTAssertEqual(report.petCount, 1)

        // Measure local high-frequency variance/contrast in body area (x: 50...78, y: 40...60)
        let origVar = measureLocalContrast(image: input, rect: CGRect(x: 50, y: 40, width: 28, height: 20))
        let outVar = measureLocalContrast(image: resultImage, rect: CGRect(x: 50, y: 40, width: 28, height: 20))

        XCTAssertGreaterThan(outVar, origVar * 1.05, "毛发蓬松度应显著提升毛流微观对比度。")
    }

    func testEyeBrighteningLiftsShadowAndPreservesCatchlight() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let input = createSyntheticCatImage(extent: extent)

        let target = PetTarget(boundingBox: CGRect(x: 0.15, y: 0.15, width: 0.70, height: 0.70))
        let settings = PetEnhancementSettings(enabled: true, eyeBrightening: 0.80)

        let (resultImage, report) = try PetEnhancementEngine.apply(
            input, settings: settings, targets: [target], context: context
        )
        XCTAssertTrue(report.applied)

        // Left eye probe around headX - eyeSpacing = 128 * (0.50 - 0.70 * 0.16) = 128 * 0.388 ≈ 50, headY = 128 * (0.15 + 0.70 * 0.72) ≈ 83
        let beforeEye = samplePixel(input, at: (x: 50, y: 83), extent: extent)
        let afterEye = samplePixel(resultImage, at: (x: 50, y: 83), extent: extent)

        let beforeL = 0.2126 * beforeEye.r + 0.7152 * beforeEye.g + 0.0722 * beforeEye.b
        let afterL = 0.2126 * afterEye.r + 0.7152 * afterEye.g + 0.0722 * afterEye.b

        XCTAssertGreaterThan(afterL, beforeL * 1.04, "明眸提亮应提亮宠物眼眶晶状体暗部。")
    }

    func testMuzzleMoistureDeepensDarksAndBoostsHighlights() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let input = createSyntheticCatImage(extent: extent)

        let target = PetTarget(boundingBox: CGRect(x: 0.15, y: 0.15, width: 0.70, height: 0.70))
        let settings = PetEnhancementSettings(enabled: true, muzzleMoisture: 0.80)

        let (resultImage, report) = try PetEnhancementEngine.apply(
            input, settings: settings, targets: [target], context: context
        )
        XCTAssertTrue(report.applied)

        // Muzzle center: headX = 64, muzzleY = 128 * (0.15 + 0.70 * 0.59) ≈ 72
        let beforeMuzzle = samplePixel(input, at: (x: 64, y: 72), extent: extent)
        let afterMuzzle = samplePixel(resultImage, at: (x: 64, y: 72), extent: extent)

        let beforeL = 0.2126 * beforeMuzzle.r + 0.7152 * beforeMuzzle.g + 0.0722 * beforeMuzzle.b
        let afterL = 0.2126 * afterMuzzle.r + 0.7152 * afterMuzzle.g + 0.0722 * afterMuzzle.b

        // In muzzle dark area, it deepens the darks
        XCTAssertLessThanOrEqual(afterL, beforeL * 1.01)
    }

    func testCoatDehazeRemovesGrayHazeAndRestoresSaturation() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        // Create an image with a hazy golden retriever coat (low saturation, elevated black point)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            XCTFail("无法创建测试位图上下文")
            return
        }
        // Hazy golden fur base: RGB(180, 160, 140)
        ctx.setFillColor(red: 180.0/255.0, green: 160.0/255.0, blue: 140.0/255.0, alpha: 1.0)
        ctx.fill(extent)

        guard let cg = ctx.makeImage() else { return }
        let input = CIImage(cgImage: cg)

        let target = PetTarget(boundingBox: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.80))
        let settings = PetEnhancementSettings(enabled: true, coatDehaze: 0.80)

        let (resultImage, report) = try PetEnhancementEngine.apply(
            input, settings: settings, targets: [target], context: context
        )
        XCTAssertTrue(report.applied)

        let before = samplePixel(input, at: (x: 64, y: 50), extent: extent)
        let after = samplePixel(resultImage, at: (x: 64, y: 50), extent: extent)

        // Saturation = (max - min) / max
        let beforeSat = (max(before.r, max(before.g, before.b)) - min(before.r, min(before.g, before.b)))
        let afterSat = (max(after.r, max(after.g, after.b)) - min(after.r, min(after.g, after.b)))

        XCTAssertGreaterThan(afterSat, beforeSat * 1.05, "去灰应显著提升毛发色彩纯度与饱和度。")
    }

    func testCoatWhitenNeutralizesYellowishCast() throws {
        let width = 128
        let height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        // Pale fur with yellow discoloration: R=210, G=200, B=160
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            XCTFail("无法创建测试位图上下文")
            return
        }
        ctx.setFillColor(red: 210.0/255.0, green: 200.0/255.0, blue: 160.0/255.0, alpha: 1.0)
        ctx.fill(extent)

        guard let cg = ctx.makeImage() else { return }
        let input = CIImage(cgImage: cg)

        let target = PetTarget(boundingBox: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.80))
        let settings = PetEnhancementSettings(enabled: true, coatWhiten: 0.80)

        let (resultImage, report) = try PetEnhancementEngine.apply(
            input, settings: settings, targets: [target], context: context
        )
        XCTAssertTrue(report.applied)

        let before = samplePixel(input, at: (x: 64, y: 50), extent: extent)
        let after = samplePixel(resultImage, at: (x: 64, y: 50), extent: extent)

        // Blue channel should increase, reducing (R - B) gap
        let beforeYellowDiff = before.r - before.b
        let afterYellowDiff = after.r - after.b

        XCTAssertLessThan(afterYellowDiff, beforeYellowDiff * 0.85, "白毛去黄应显著中和发黄氧化色差。")
    }

    func testEngineProcessPipelineIntegratesPetEnhancement() throws {
        let extent = CGRect(x: 0, y: 0, width: 128, height: 128)
        let input = createSyntheticCatImage(extent: extent)

        var adjustments = AdjustmentSettings()
        adjustments.petEnhancement = PetEnhancementSettings(enabled: true, furFluffiness: 0.6, eyeBrightening: 0.5)

        let target = PetTarget(boundingBox: CGRect(x: 0.15, y: 0.15, width: 0.70, height: 0.70))
        let engine = PhotoEngine()
        let processed = try engine.process(input, settings: adjustments, lut: nil, preparedPetTargets: [target])

        XCTAssertNotNil(processed.report.petEnhancement)
        XCTAssertTrue(processed.report.petEnhancement?.applied == true)
        XCTAssertEqual(processed.report.petEnhancement?.petCount, 1)
        XCTAssertTrue(processed.report.petEnhancement?.appliedSteps.contains("毛发蓬松") == true)
        XCTAssertTrue(processed.report.petEnhancement?.appliedSteps.contains("明眸提亮") == true)
    }

    // MARK: - Helpers

    private func createSyntheticCatImage(extent: CGRect) -> CIImage {
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        }

        // Background neutral
        ctx.setFillColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1.0)
        ctx.fill(extent)

        // Animal torso (fur): ginger cat base (190, 120, 60)
        let torsoRect = CGRect(x: 25, y: 20, width: 78, height: 88)
        ctx.setFillColor(red: 190.0/255.0, green: 120.0/255.0, blue: 60.0/255.0, alpha: 1.0)
        ctx.fillEllipse(in: torsoRect)

        // High frequency fur stripes
        ctx.setFillColor(red: 130.0/255.0, green: 70.0/255.0, blue: 30.0/255.0, alpha: 1.0)
        for y in stride(from: 30, to: 80, by: 4) {
            ctx.fill(CGRect(x: 35, y: y, width: 58, height: 2))
        }

        // Eyes: dark socket + green iris (x ≈ 50 and 78, y ≈ 83)
        ctx.setFillColor(red: 40.0/255.0, green: 30.0/255.0, blue: 20.0/255.0, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 46, y: 79, width: 8, height: 8))
        ctx.fillEllipse(in: CGRect(x: 74, y: 79, width: 8, height: 8))

        // Iris
        ctx.setFillColor(red: 100.0/255.0, green: 160.0/255.0, blue: 60.0/255.0, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 47, y: 80, width: 6, height: 6))
        ctx.fillEllipse(in: CGRect(x: 75, y: 80, width: 6, height: 6))

        // Catchlight
        ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 49, y: 82, width: 2, height: 2))
        ctx.fillEllipse(in: CGRect(x: 77, y: 82, width: 2, height: 2))

        // Muzzle / nose: pinkish dark (150, 70, 70)
        ctx.setFillColor(red: 150.0/255.0, green: 70.0/255.0, blue: 70.0/255.0, alpha: 1.0)
        ctx.fillEllipse(in: CGRect(x: 60, y: 69, width: 8, height: 6))

        guard let cg = ctx.makeImage() else {
            return CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        }
        return CIImage(cgImage: cg)
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
        let width = Int(extent.width)
        let height = Int(extent.height)
        let rowBytes = width * 4
        var bitmap = [UInt8](repeating: 0, count: rowBytes * height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        context.render(image, toBitmap: &bitmap, rowBytes: rowBytes, bounds: extent, format: .RGBA8, colorSpace: cs)

        let idx = (point.y * width + point.x) * 4
        guard idx + 2 < bitmap.count else { return (0, 0, 0) }
        return (Double(bitmap[idx]) / 255.0, Double(bitmap[idx + 1]) / 255.0, Double(bitmap[idx + 2]) / 255.0)
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

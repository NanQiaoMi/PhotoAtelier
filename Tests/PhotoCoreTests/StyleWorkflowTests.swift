import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class StyleWorkflowTests: XCTestCase {
    private let engine = PhotoEngine()
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    func testLegacySettingsAndNeutralEffectsKeepTheirPixels() throws {
        var legacy = AdjustmentSettings()
        legacy.exposureEV = 0.13
        let data = try JSONEncoder().encode(legacy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "creativeEffects")
        let decoded = try JSONDecoder().decode(AdjustmentSettings.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.creativeEffects)
        var zero = decoded; zero.creativeEffects = .init()
        let source = fixture()
        let lut = LUTCube.builtIns[1].cube
        let a = try engine.process(source, settings: decoded, lut: lut, outputColorSpace: .displayP3)
        let b = try engine.process(source, settings: zero, lut: lut, outputColorSpace: .displayP3)
        XCTAssertEqual(pixels(a.image), pixels(b.image))
    }

    func testVersionEightRoundTripsAndRejectsDowngradesInEverySettingsSlot() throws {
        var current = AdjustmentSettings()
        current.creativeEffects = .init(bloom: 0.3, vignette: 0.2, grain: 0.1)
        let automatic = AutomaticBatchRecipe(styleID: "balanced", baseline: current, referenceSettings: current)
        let recipe = Recipe(adjustments: current, automatic: automatic)
        XCTAssertEqual(recipe.version, 8)
        let restored = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(restored, recipe)
        XCTAssertNoThrow(try restored.validateVersion())
        for slot in 0..<3 {
            for version in 1...7 {
                var settings = AdjustmentSettings()
                settings.creativeEffects = .init(grain: 0.1)
                var old = Recipe()
                old.version = version
                switch slot {
                case 0: old.adjustments = settings
                case 1: old.automatic = .init(styleID: "balanced", baseline: settings, referenceSettings: .init())
                default: old.automatic = .init(styleID: "balanced", baseline: .init(), referenceSettings: settings)
                }
                XCTAssertThrowsError(try old.validateVersion(), "version \(version), slot \(slot)")
            }
        }
        var old = Recipe(adjustments: current)
        old.adjustments.creativeEffects = .init()
        old.version = 1
        XCTAssertNoThrow(try old.validateVersion())
        current.creativeEffects?.bloom = .nan
        XCTAssertThrowsError(try PhotoEngine.validate(current))
    }

    func testEffectsFollowBothMaskStagesAndLUTButStayOutOfMeasurementReference() throws {
        let source = fixture()
        var settings = AdjustmentSettings()
        settings.colorHarmony = nil
        settings.gamutCompression = 0
        settings.exposureEV = 0.1
        settings.masks = [.init(kind: .radial, exposureEV: 0.2, stage: .beforeLook),
                          .init(kind: .linear, exposureEV: -0.1, stage: .afterLook)]
        let effects = CreativeEffectsSettings(bloom: 0.4, vignette: 0.7, grain: 0.8)
        let lut = LUTCube.builtIns[6].cube
        let before = try engine.process(source, settings: settings, lut: lut)
        let expected = try CreativeEffectsEngine.apply(effects, to: before.image, context: engine.context)
        settings.creativeEffects = effects
        let actual = try engine.process(source, settings: settings, lut: lut)
        XCTAssertEqual(pixels(expected), pixels(actual.image))
        let reference = try engine.maskReferenceImage(source, settings: settings)
        var basic = settings; basic.creativeEffects = nil; basic.masks = []
        let expectedReference = try engine.process(source, settings: basic, lut: nil)
        XCTAssertEqual(pixels(reference), pixels(expectedReference.image))
        XCTAssertNil(AutomaticSafetyEvaluator.globalSettings(settings).creativeEffects)
    }

    func testAutomaticBasicCopyPreservesUserEffectsAndLUTStrength() throws {
        var current = AdjustmentSettings()
        current.creativeEffects = .init(bloom: 0.4, vignette: 0.3, grain: 0.2)
        current.lutIntensity = 0.31
        var proposal = AdjustmentSettings()
        proposal.exposureEV = 0.2
        proposal.creativeEffects = .init(grain: 1)
        let copied = AutomaticBatchRecipe.copyBasicAdjustments(from: proposal, into: current)
        XCTAssertEqual(copied.creativeEffects, current.creativeEffects)
        XCTAssertEqual(copied.lutIntensity, current.lutIntensity)
        XCTAssertEqual(copied.exposureEV, 0.2)
    }

    func testNewEffectsMapToTargetEvenWhenLegacyRecipeHasNoHarmony() throws {
        var settings = AdjustmentSettings()
        settings.colorHarmony = nil
        settings.creativeEffects = .init(bloom: 0.5, grain: 1)
        let source = fixture()
        let unmapped = try engine.process(source, settings: settings, lut: nil)
        for target in OutputColorSpace.allCases {
            let expected = try OutputGamutMapper.map(unmapped.image, to: target, context: engine.context)
            let actual = try engine.process(source, settings: settings, lut: nil, outputColorSpace: target)
            XCTAssertEqual(pixels(actual.image), pixels(expected),
                           "enabling a new effect also enables target mapping for legacy recipes")
            XCTAssertNotNil(actual.report.colorQuality)
        }
        settings.creativeEffects = nil
        let old = try engine.process(source, settings: settings, lut: nil, outputColorSpace: .sRGB)
        let oldWithoutTarget = try engine.process(source, settings: settings, lut: nil)
        XCTAssertEqual(pixels(old.image), pixels(oldWithoutTarget.image), "old nil-harmony path remains unchanged")
    }

    func testNativeInspectionMatchesFullRenderWithEffectsAndBothOutputSpaces() throws {
        let source = fixture(size: 128)
        var settings = AdjustmentSettings()
        settings.creativeEffects = .init(bloom: 0.6, vignette: 0.8, grain: 0.7)
        let lut = LUTCube.builtIns[7].cube
        for space in OutputColorSpace.allCases {
            let result = try NativeInspectionRenderer(engine: engine).render(source, settings: settings,
                lut: lut, outputColorSpace: space, region: .init(center: .init(x: 0.63, y: 0.56), pixelSize: 64))
            let full = try engine.process(source, settings: settings, lut: lut, outputColorSpace: space)
            let raster = try XCTUnwrap(engine.context.createCGImage(full.image, from: full.image.extent,
                format: .RGBA8, colorSpace: space.cgColorSpace, deferred: false))
            let fullData = try XCTUnwrap(raster.dataProvider?.data)
            let owned = try XCTUnwrap(CGDataProvider(data: fullData))
            let fullCopy = try XCTUnwrap(CGImage(width: raster.width, height: raster.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: raster.bytesPerRow,
                space: space.cgColorSpace, bitmapInfo: raster.bitmapInfo, provider: owned,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let bounds = result.sampleBounds
            let crop = try XCTUnwrap(fullCopy.cropping(to: .init(x: bounds.minX,
                y: 128 - bounds.maxY, width: bounds.width, height: bounds.height)))
            let expected = bytes(crop), actual = bytes(result.after)
            XCTAssertEqual(expected.count, actual.count)
            XCTAssertLessThanOrEqual(zip(expected, actual).map { abs(Int($0) - Int($1)) }.max() ?? 999, 2)
            XCTAssertNotNil(result.report.colorQuality, "effects use the final target-aware color guard")
        }
    }

    private func fixture(size: Int = 64) -> CIImage {
        var data = [Float](repeating: 1, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let high: Float = (size/3...size/2).contains(x) && (size/3...size/2).contains(y) ? 0.8 : 0
                data[i] = 0.15 + Float(x) / Float(size) * 0.5 + high
                data[i + 1] = 0.12 + Float(y) / Float(size) * 0.4 + high
                data[i + 2] = 0.07 + Float(x + y) / Float(size * 2) * 0.3 + high
            }
        }
        return CIImage(bitmapData: data.withUnsafeBytes { Data($0) }, bytesPerRow: size * 16,
                       size: CGSize(width: size, height: size), format: .RGBAf, colorSpace: linear)
    }
    private func pixels(_ image: CIImage) -> [Float] {
        var result = [Float](repeating: 0, count: Int(image.extent.width * image.extent.height) * 4)
        result.withUnsafeMutableBytes { engine.context.render(image, toBitmap: $0.baseAddress!,
            rowBytes: Int(image.extent.width) * 16, bounds: image.extent, format: .RGBAf, colorSpace: linear) }
        return result
    }
    private func bytes(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { memory in
            let ctx = CGContext(data: memory.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: image.colorSpace!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}

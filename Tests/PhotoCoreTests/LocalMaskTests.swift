import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class LocalMaskTests: XCTestCase {
    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    func testLegacyMaskDecodesAfterLookAndRendersLikeLegacySettings() throws {
        let id = UUID()
        let legacyJSON: [String: Any] = [
            "id": id.uuidString,
            "name": "legacy",
            "kind": "radial",
            "start": ["x": 0.5, "y": 0.5],
            "end": ["x": 0.9, "y": 0.9],
            "points": [],
            "radius": 0.12,
            "feather": 0.0,
            "inverted": false,
            "enabled": true,
            "exposureEV": 1.0,
            "saturation": 1.0,
            "warmth": 0.0
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyJSON)
        let decoded = try JSONDecoder().decode(LocalMask.self, from: data)
        let legacySettingsMask = LocalMask(
            id: id, name: "legacy", kind: .radial,
            start: .init(x: 0.5, y: 0.5), end: .init(x: 0.9, y: 0.9),
            radius: 0.12, feather: 0, exposureEV: 1,
            highlightProtection: 0, colorProtection: 0, stage: .afterLook
        )

        XCTAssertEqual(decoded, legacySettingsMask)
        XCTAssertEqual(decoded.stage, .afterLook)
        XCTAssertEqual(decoded.highlightProtection, 0)
        XCTAssertEqual(decoded.colorProtection, 0)

        let engine = PhotoEngine()
        var settings = neutralSettings()
        settings.masks = [decoded]
        let source = solidImage(0.2, 0.2, 0.2,
                                extent: CGRect(x: 13, y: -7, width: 32, height: 24))
        let fromOldRecipe = try engine.process(source,
                                               settings: settings, lut: inversionCube()).image
        settings.masks = [legacySettingsMask]
        let fromExplicitLegacySettings = try engine.process(
            source,
            settings: settings, lut: inversionCube()).image
        let first = try pixel(fromOldRecipe, x: 29, y: 5, engine: engine)
        let second = try pixel(fromExplicitLegacySettings, x: 29, y: 5, engine: engine)
        for channel in 0..<4 {
            XCTAssertEqual(first[channel], second[channel], accuracy: 0.002)
        }

        let coverage = try engine.localMaskImage(decoded, reference: source)
        XCTAssertGreaterThan(try normalizedPixel(coverage, x: 0.5, y: 0.5, engine: engine)[0], 0.9)
        XCTAssertLessThan(try normalizedPixel(coverage, x: 0.95, y: 0.5, engine: engine)[0], 0.1)
        let inspection = try engine.inspectLocalMask(decoded, reference: source)
        XCTAssertGreaterThan(inspection.coverage, 0.3)
        XCTAssertLessThan(inspection.coverage, 0.7)
    }

    func testNewRecipeRoundTripsLocalMaskAndComponentFields() throws {
        let component = MaskComponent(
            operation: .subtract, kind: .linear,
            start: .init(x: 0.12, y: 0.33), end: .init(x: 0.82, y: 0.67),
            points: [.init(x: 0.2, y: 0.3), .init(x: 0.8, y: 0.7)],
            radius: 0.08, feather: 0.23
        )
        let mask = LocalMask(
            name: "round-trip", kind: .color,
            start: .init(x: 0.2, y: 0.4), end: .init(x: 0.7, y: 0.9),
            points: [.init(x: 0.1, y: 0.2)], radius: 0.17, feather: 0.31,
            inverted: true, enabled: true, exposureEV: -0.4, saturation: 1.2, warmth: 0.1,
            components: [component], opacity: 0.63, tint: -0.12, contrast: 1.3,
            highlights: -0.2, shadows: 0.3, sharpness: 0.7,
            highlightProtection: 0.4, colorProtection: 0.8, stage: .afterLook,
            restrictLuminance: true, luminanceMin: 0.14, luminanceMax: 0.88,
            rangeSoftness: 0.09, restrictColor: true,
            color: MaskColor(red: 0.31, green: 0.62, blue: 0.84),
            colorTolerance: 0.18, colorSoftness: 0.0625
        )
        var settings = neutralSettings()
        settings.masks = [mask]
        let recipe = Recipe(adjustments: settings)

        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(Recipe.self, from: data)

        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(recipe.version, 9)
        XCTAssertEqual(LocalMask().stage, .beforeLook)
        XCTAssertEqual(MaskComponent().kind, .brush)
    }

    func testLegacyRecipeVersionLoadsAndSupportedVersionsPassBatchValidation() throws {
        var settings = neutralSettings()
        settings.masks = [LocalMask(exposureEV: 0.2)]
        let data = try JSONEncoder().encode(Recipe(adjustments: settings))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 1
        var adjustments = try XCTUnwrap(object["adjustments"] as? [String: Any])
        var mask = try XCTUnwrap((adjustments["masks"] as? [[String: Any]])?.first)
        let oldFields: Set<String> = ["id", "name", "kind", "start", "end", "points", "radius", "feather", "inverted", "enabled", "exposureEV", "saturation", "warmth"]
        mask = mask.filter { oldFields.contains($0.key) }
        adjustments["masks"] = [mask]; object["adjustments"] = adjustments
        let legacy = try JSONDecoder().decode(Recipe.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.version, 1)
        XCTAssertEqual(legacy.adjustments.masks.first?.stage, .afterLook)
        XCTAssertEqual(legacy.adjustments.masks.first?.highlightProtection, 0)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("atelier-mask-recipe-\(UUID())")
        let input = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Recipes v1-v14 keep their legacy mask defaults and stay batch-runnable;
        // v14 is the current version (P1-F enhanced make-up fields are opt-in, so a v14
        // recipe without them is still valid; v10-v13 fields stay opt-in).
        for version in 1...14 {
            var recipe = legacy; recipe.version = version
            let summary = try BatchProcessor().run(items: [], inputRoot: input,
                outputRoot: root.appendingPathComponent("output-\(version)"), recipe: recipe,
                lut: nil, cancellation: CancellationToken(), onEvent: { _ in })
            XCTAssertNotNil(summary.manifestURL)
        }
        // An unknown future version is rejected before any output directory exists.
        var future = legacy; future.version = 15
        XCTAssertThrowsError(try BatchProcessor().run(items: [], inputRoot: input,
            outputRoot: root.appendingPathComponent("unsupported"), recipe: future,
            lut: nil, cancellation: CancellationToken(), onEvent: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unsupported").path))
    }

    func testInspectionDoesNotInflatePartiallyTransparentColors() throws {
        let engine = PhotoEngine(), extent = CGRect(x: -8, y: 13, width: 64, height: 40)
        let mask = LocalMask(kind: .luminance, exposureEV: 0)
        let opaque = try engine.inspectLocalMask(mask, reference: solidImage(0.2, 0.3, 0.4, extent: extent))
        let transparent = try engine.inspectLocalMask(mask, reference: solidImage(0.2, 0.3, 0.4, alpha: 0.35, extent: extent))
        XCTAssertEqual(transparent.medianLuminance, opaque.medianLuminance, accuracy: 0.005)
        XCTAssertEqual(transparent.coverage, opaque.coverage, accuracy: 0.005)
        XCTAssertEqual(transparent.suggestedExposureEV, 0, accuracy: 0.005)
    }

    func testEmptyInvertedBrushAndExactColorHaveConsistentCoverage() throws {
        let engine = PhotoEngine(), extent = CGRect(x: 0, y: 0, width: 48, height: 32)
        let source = solidImage(0, 0, 0, extent: extent)
        for stage in [MaskStage.beforeLook, .afterLook] {
            let empty = LocalMask(kind: .brush, inverted: true, exposureEV: 1,
                                  highlightProtection: 0, colorProtection: 0, stage: stage)
            let coverage = try engine.localMaskImage(empty, reference: source)
            let inspection = try engine.inspectLocalMask(empty, reference: source)
            XCTAssertEqual(try pixel(coverage, x: 24, y: 16, engine: engine)[0], 0, accuracy: 0.001)
            XCTAssertEqual(inspection.coverage, 0, accuracy: 0.001)
        }
        let exact = LocalMask(kind: .color, exposureEV: 0, color: .init(red: 0, green: 0, blue: 0),
                              colorTolerance: 0, colorSoftness: 0)
        XCTAssertGreaterThan(try pixel(engine.localMaskImage(exact, reference: source),
                                       x: 24, y: 16, engine: engine)[0], 0.99)
    }

    func testZeroOpacityAndDisabledMasksArePixelIdentity() throws {
        let engine = PhotoEngine()
        let source = twoBandImage(width: 64, height: 40,
                                  left: (0.08, 0.2, 0.5), right: (0.8, 0.5, 0.1))
        var settings = neutralSettings()
        settings.masks = [LocalMask(kind: .luminance, exposureEV: 2, opacity: 0,
                                    highlightProtection: 0, colorProtection: 0)]
        let zeroOpacity = try engine.process(source, settings: settings, lut: nil).image
        settings.masks = [LocalMask(kind: .luminance, enabled: false, exposureEV: 2,
                                    highlightProtection: 0, colorProtection: 0)]
        let disabled = try engine.process(source, settings: settings, lut: nil).image

        for point in [(16.0, 20.0), (48.0, 20.0)] {
            let before = try pixel(source, x: point.0, y: point.1, engine: engine)
            let afterZeroOpacity = try pixel(zeroOpacity, x: point.0, y: point.1, engine: engine)
            let afterDisabled = try pixel(disabled, x: point.0, y: point.1, engine: engine)
            for channel in 0..<4 {
                XCTAssertEqual(afterZeroOpacity[channel], before[channel], accuracy: 0.002)
                XCTAssertEqual(afterDisabled[channel], before[channel], accuracy: 0.002)
            }
        }
    }

    func testBrushComponentsAddSubtractAndIntersectAtRealPixelBoundaries() throws {
        let engine = PhotoEngine()
        let mask = LocalMask(kind: .brush, points: [], components: [
            MaskComponent(operation: .add, kind: .brush,
                          points: [.init(x: 0.1, y: 0.5), .init(x: 0.9, y: 0.5)],
                          radius: 0.06, feather: 0),
            MaskComponent(operation: .add, kind: .brush,
                          points: [.init(x: 0.5, y: 0.1), .init(x: 0.5, y: 0.9)],
                          radius: 0.06, feather: 0),
            MaskComponent(operation: .subtract, kind: .brush,
                          points: [.init(x: 0.5, y: 0.5)], radius: 0.04, feather: 0),
            MaskComponent(operation: .intersect, kind: .radial,
                          start: .init(x: 0.5, y: 0.5), end: .init(x: 0.62, y: 0.62),
                          feather: 0)
        ])
        let coverage = try engine.localMaskImage(mask,
                                                  reference: solidImage(0.3, 0.3, 0.3,
                                                                        extent: CGRect(x: 0, y: 0, width: 100, height: 100)))

        XCTAssertGreaterThan(try normalizedPixel(coverage, x: 0.42, y: 0.5, engine: engine)[0], 0.8,
                             "中间的减笔应留下相邻笔迹，且该处仍在相交区域内")
        XCTAssertGreaterThan(try normalizedPixel(coverage, x: 0.5, y: 0.42, engine: engine)[0], 0.8,
                             "第二条添加笔迹应保留自己的局部区域")
        XCTAssertLessThan(try normalizedPixel(coverage, x: 0.5, y: 0.5, engine: engine)[0], 0.1,
                          "减笔应在中心挖出实际空洞")
        XCTAssertLessThan(try normalizedPixel(coverage, x: 0.22, y: 0.5, engine: engine)[0], 0.1,
                          "相交应裁掉几何范围外的添加笔迹")
    }

    func testLuminanceRangeSelectsBrightAndDarkPixels() throws {
        let engine = PhotoEngine()
        let source = twoBandImage(width: 80, height: 40,
                                  left: (0.04, 0.04, 0.04), right: (0.85, 0.85, 0.85),
                                  originX: 17, originY: -9)
        let reference = try engine.maskReferenceImage(source, settings: neutralSettings())
        let brightMask = LocalMask(kind: .luminance, luminanceMin: 0.7,
                                   luminanceMax: 1, rangeSoftness: 0.04)
        let darkMask = LocalMask(kind: .luminance, luminanceMin: 0,
                                 luminanceMax: 0.35, rangeSoftness: 0.04)
        let bright = try engine.localMaskImage(brightMask, reference: reference)
        let dark = try engine.localMaskImage(darkMask, reference: reference)

        XCTAssertGreaterThan(try normalizedPixel(bright, x: 0.75, y: 0.5, engine: engine)[0], 0.9)
        XCTAssertLessThan(try normalizedPixel(bright, x: 0.25, y: 0.5, engine: engine)[0], 0.1)
        XCTAssertGreaterThan(try normalizedPixel(dark, x: 0.25, y: 0.5, engine: engine)[0], 0.9)
        XCTAssertLessThan(try normalizedPixel(dark, x: 0.75, y: 0.5, engine: engine)[0], 0.1)
    }

    func testMaskReferenceStaysGlobalOnlyAcrossMultipleLocalMasks() throws {
        let engine = PhotoEngine()
        let source = twoBandImage(width: 80, height: 40,
                                  left: (0.04, 0.04, 0.04), right: (0.85, 0.85, 0.85),
                                  originX: 11, originY: -6)
        let firstMask = LocalMask(
            kind: .radial,
            start: .init(x: 0.25, y: 0.5), end: .init(x: 0.49, y: 1),
            feather: 0, exposureEV: 2.5,
            highlightProtection: 0, colorProtection: 0
        )
        let rangeMask = LocalMask(
            kind: .luminance, exposureEV: 0.5,
            highlightProtection: 0, colorProtection: 0,
            luminanceMin: 0.5, luminanceMax: 1, rangeSoftness: 0.04
        )
        var settings = neutralSettings()
        settings.exposureEV = 0.5
        settings.lutIntensity = 1
        settings.masks = [firstMask, rangeMask]

        let reference = try engine.maskReferenceImage(source, settings: settings)
        let referenceLeft = try normalizedPixel(reference, x: 0.25, y: 0.5, engine: engine)[0]
        let referenceRight = try normalizedPixel(reference, x: 0.75, y: 0.5, engine: engine)[0]
        let secondMaskCoverage = try engine.localMaskImage(rangeMask, reference: reference)
        let leftCoverage = try normalizedPixel(secondMaskCoverage, x: 0.25, y: 0.5, engine: engine)[0]
        let rightCoverage = try normalizedPixel(secondMaskCoverage, x: 0.75, y: 0.5, engine: engine)[0]
        let processed = try engine.process(source, settings: settings, lut: nil).image
        let processedLeft = try normalizedPixel(processed, x: 0.25, y: 0.5, engine: engine)[0]
        let processedRight = try normalizedPixel(processed, x: 0.75, y: 0.5, engine: engine)[0]

        XCTAssertEqual(referenceLeft, 0.04 * pow(2, 0.5), accuracy: 0.015,
                       "参考图应包含全局曝光，但不包含局部蒙版")
        XCTAssertEqual(referenceRight, 0.85 * pow(2, 0.5), accuracy: 0.025)
        XCTAssertLessThan(leftCoverage, 0.1,
                          "首个蒙版提亮左区后，第二个蒙版仍应按全局参考排除它")
        XCTAssertGreaterThan(rightCoverage, 0.9)
        XCTAssertEqual(processedLeft, 0.04 * pow(2, 3), accuracy: 0.03)
        XCTAssertEqual(processedRight, 0.85 * 2, accuracy: 0.04)

        let colorSource = twoBandImage(width: 80, height: 40,
                                       left: (0.04, 0.01, 0.01), right: (0.85, 0.75, 0.75),
                                       originX: -4, originY: 12)
        let localColorChange = LocalMask(
            kind: .radial,
            start: .init(x: 0.25, y: 0.5), end: .init(x: 0.49, y: 1),
            feather: 0, exposureEV: 2.5,
            highlightProtection: 0, colorProtection: 0
        )
        var colorSettings = neutralSettings()
        colorSettings.exposureEV = 0.5
        let colorReference = try engine.maskReferenceImage(colorSource, settings: colorSettings)
        let sampledTarget = try engine.sampleMaskColor(at: .init(x: 0.25, y: 0.5),
                                                       reference: colorReference)
        XCTAssertEqual(sampledTarget.red, linearToSRGB(0.04 * pow(2, 0.5)), accuracy: 0.02,
                       "取色必须返回全局参考像素的编码 sRGB")
        XCTAssertEqual(sampledTarget.green, linearToSRGB(0.01 * pow(2, 0.5)), accuracy: 0.02)
        let colorMask = LocalMask(
            kind: .color, exposureEV: 0.5,
            highlightProtection: 0, colorProtection: 0,
            color: sampledTarget, colorTolerance: 0.015, colorSoftness: 0.02
        )
        colorSettings.masks = [localColorChange, colorMask]
        let colorCoverage = try engine.localMaskImage(colorMask, reference: colorReference)
        let colorProcessed = try engine.process(colorSource, settings: colorSettings, lut: nil).image

        XCTAssertGreaterThan(try normalizedPixel(colorCoverage, x: 0.25, y: 0.5, engine: engine)[0], 0.9)
        XCTAssertLessThan(try normalizedPixel(colorCoverage, x: 0.75, y: 0.5, engine: engine)[0], 0.1)
        XCTAssertGreaterThan(try normalizedPixel(colorProcessed, x: 0.25, y: 0.5, engine: engine)[0], 0.4,
                             "首个蒙版改变目标色后，后续颜色蒙版仍应匹配全局参考色")
        XCTAssertEqual(try normalizedPixel(colorProcessed, x: 0.75, y: 0.5, engine: engine)[0],
                       0.85 * pow(2, 0.5), accuracy: 0.035)
    }

    func testSampledSRGBColorSelectsOnlyTheTargetColorPatch() throws {
        let engine = PhotoEngine()
        let source = twoBandImage(width: 80, height: 40,
                                  left: (0.25, 0.04, 0.01), right: (0.01, 0.03, 0.4),
                                  originX: -12, originY: 23)
        let reference = try engine.maskReferenceImage(source, settings: neutralSettings())
        let sampled = try engine.sampleMaskColor(at: .init(x: 0.25, y: 0.5), reference: reference)
        XCTAssertEqual(sampled.red, linearToSRGB(0.25), accuracy: 0.02,
                       "取色结果应按编码 sRGB 返回，而不是线性通道")
        XCTAssertEqual(sampled.green, linearToSRGB(0.04), accuracy: 0.02)
        let mask = LocalMask(kind: .color, color: sampled,
                             colorTolerance: 0.02, colorSoftness: 0.04)
        let coverage = try engine.localMaskImage(mask, reference: reference)
        XCTAssertGreaterThan(try normalizedPixel(coverage, x: 0.25, y: 0.5, engine: engine)[0], 0.9)
        XCTAssertLessThan(try normalizedPixel(coverage, x: 0.75, y: 0.5, engine: engine)[0], 0.1)
    }

    func testInversionPrecedesRangeAndOpacityInEffectiveCoverage() throws {
        let engine = PhotoEngine()
        let reference = twoBandImage(width: 80, height: 40,
                                     left: (0.04, 0.04, 0.04), right: (0.85, 0.85, 0.85))
        let mask = LocalMask(
            kind: .radial,
            start: .init(x: 0.3, y: 0.5), end: .init(x: 0.65, y: 1),
            feather: 0, inverted: true, opacity: 0.5,
            restrictLuminance: true, luminanceMin: 0.7, luminanceMax: 1,
            rangeSoftness: 0.04
        )
        let coverage = try engine.localMaskImage(mask, reference: reference)

        XCTAssertLessThan(try normalizedPixel(coverage, x: 0.25, y: 0.5, engine: engine)[0], 0.05,
                          "反转后的暗区仍应由亮度范围排除")
        XCTAssertEqual(try normalizedPixel(coverage, x: 0.75, y: 0.5, engine: engine)[0], 0.5,
                       accuracy: 0.06, "通过范围的反转区域应再乘以 50% 不透明度")
    }

    func testLuminanceRangeInversionSelectsTheComplementBeforeOpacity() throws {
        let engine = PhotoEngine()
        let reference = twoBandImage(width: 80, height: 40,
                                     left: (0.04, 0.04, 0.04), right: (0.85, 0.85, 0.85))
        let mask = LocalMask(kind: .luminance, inverted: true, opacity: 0.4,
                             luminanceMin: 0.7, luminanceMax: 1, rangeSoftness: 0.04)
        let coverage = try engine.localMaskImage(mask, reference: reference)

        XCTAssertEqual(try normalizedPixel(coverage, x: 0.25, y: 0.5, engine: engine)[0], 0.4,
                       accuracy: 0.06, "范围蒙版反转后应覆盖亮度范围之外的暗区域")
        XCTAssertLessThan(try normalizedPixel(coverage, x: 0.75, y: 0.5, engine: engine)[0], 0.05,
                          "范围蒙版反转后应排除原本选中的亮区域")

        let colorReference = twoBandImage(width: 80, height: 40,
                                          left: (0.7, 0.03, 0.02), right: (0.02, 0.04, 0.7))
        let target = try engine.sampleMaskColor(at: .init(x: 0.25, y: 0.5),
                                                reference: colorReference)
        let colorMask = LocalMask(kind: .color, inverted: true, opacity: 0.4,
                                  color: target, colorTolerance: 0.02, colorSoftness: 0.04)
        let colorCoverage = try engine.localMaskImage(colorMask, reference: colorReference)
        XCTAssertLessThan(try normalizedPixel(colorCoverage, x: 0.25, y: 0.5, engine: engine)[0], 0.05)
        XCTAssertEqual(try normalizedPixel(colorCoverage, x: 0.75, y: 0.5, engine: engine)[0], 0.4,
                       accuracy: 0.06, "颜色范围反转应覆盖未匹配的颜色")
    }

    func testBeforeLookAndAfterLookStagesProduceDifferentPixelsWithSameLUT() throws {
        let engine = PhotoEngine()
        let source = solidImage(0.2, 0.2, 0.2,
                                extent: CGRect(x: 9, y: 15, width: 32, height: 24))
        let baseMask = LocalMask(kind: .luminance, exposureEV: 1,
                                 highlightProtection: 0, colorProtection: 0,
                                 stage: .beforeLook)
        var settings = neutralSettings()
        settings.masks = [baseMask]
        let beforeLook = try engine.process(source, settings: settings, lut: inversionCube()).image
        settings.masks = [LocalMask(kind: .luminance, exposureEV: 1,
                                    highlightProtection: 0, colorProtection: 0,
                                    stage: .afterLook)]
        let afterLook = try engine.process(source, settings: settings, lut: inversionCube()).image

        let before = try pixel(beforeLook, x: 25, y: 27, engine: engine)[0]
        let after = try pixel(afterLook, x: 25, y: 27, engine: engine)[0]
        XCTAssertGreaterThan(after, before + 0.2,
                             "同一非线性 LUT 下，LUT 前后调整应得到不同的实际像素")
    }

    func testLocalRenderKeepsNonzeroExtentAndSourceAlpha() throws {
        let engine = PhotoEngine()
        let extent = CGRect(x: 31, y: -14, width: 48, height: 30)
        let source = solidImage(0.2, 0.3, 0.4, alpha: 0.4, extent: extent)
        var settings = neutralSettings()
        settings.masks = [LocalMask(kind: .luminance, exposureEV: 1,
                                    highlightProtection: 0, colorProtection: 0)]
        let output = try engine.process(source, settings: settings, lut: nil).image
        let before = try pixel(source, x: 55, y: 1, engine: engine)
        let after = try pixel(output, x: 55, y: 1, engine: engine)

        XCTAssertEqual(output.extent, extent)
        XCTAssertEqual(after[3], before[3], accuracy: 0.002)
        XCTAssertEqual(after[0], before[0] * 2, accuracy: 0.01)
        XCTAssertEqual(after[1], before[1] * 2, accuracy: 0.01)
    }

    func testNormalizedFeatherIsSimilarAtPreviewAndFullResolution() throws {
        let engine = PhotoEngine()
        let mask = LocalMask(kind: .radial,
                             start: .init(x: 0.5, y: 0.5), end: .init(x: 0.72, y: 0.72),
                             feather: 0.6, exposureEV: 0)
        let preview = try engine.localMaskImage(
            mask, reference: solidImage(0.3, 0.3, 0.3,
                                        extent: CGRect(x: 37, y: -21, width: 80, height: 48)))
        let full = try engine.localMaskImage(
            mask, reference: solidImage(0.3, 0.3, 0.3,
                                        extent: CGRect(x: -11, y: 8, width: 320, height: 192)))
        let previewCoverage = try normalizedPixel(preview, x: 0.65, y: 0.5, engine: engine)[0]
        let fullCoverage = try normalizedPixel(full, x: 0.65, y: 0.5, engine: engine)[0]

        XCTAssertGreaterThan(previewCoverage, 0.1)
        XCTAssertLessThan(previewCoverage, 0.95)
        XCTAssertEqual(previewCoverage, fullCoverage, accuracy: 0.12,
                       "同一归一化位置的羽化覆盖不应随预览/全尺寸变化")
        XCTAssertEqual(preview.extent, CGRect(x: 37, y: -21, width: 80, height: 48))

        let brush = LocalMask(kind: .brush,
                              points: [.init(x: 0.15, y: 0.5), .init(x: 0.85, y: 0.5)],
                              radius: 0.055, feather: 0.75, exposureEV: 0)
        let brushPreview = try engine.localMaskImage(
            brush, reference: solidImage(0.3, 0.3, 0.3,
                                         extent: CGRect(x: 19, y: -30, width: 256, height: 160)))
        let brushFull = try engine.localMaskImage(
            brush, reference: solidImage(0.3, 0.3, 0.3,
                                         extent: CGRect(x: -8, y: 24, width: 4096, height: 2560)))
        let previewEdge = try normalizedPixel(brushPreview, x: 0.5, y: 0.57, engine: engine)[0]
        let fullEdge = try normalizedPixel(brushFull, x: 0.5, y: 0.57, engine: engine)[0]

        XCTAssertGreaterThan(previewEdge, 0.02, "预览采样点应落在可见的画笔羽化带")
        XCTAssertLessThan(previewEdge, 0.95, "画笔羽化带应保留柔和边缘")
        XCTAssertEqual(previewEdge, fullEdge, accuracy: 0.15,
                       "最长边超过 2048 像素的全尺寸图应保持归一化画笔羽化")
    }

    func testInspectionKeepsEmptyDarkAndWhiteSceneSuggestionsConservative() throws {
        let engine = PhotoEngine()
        let empty = try engine.inspectLocalMask(
            LocalMask(kind: .brush, points: []),
            reference: solidImage(0.1, 0.1, 0.1, extent: CGRect(x: 0, y: 0, width: 32, height: 32)))
        let dark = try engine.inspectLocalMask(
            LocalMask(kind: .luminance),
            reference: solidImage(0.001, 0.001, 0.001, extent: CGRect(x: 0, y: 0, width: 32, height: 32)))
        let white = try engine.inspectLocalMask(
            LocalMask(kind: .luminance),
            reference: solidImage(1, 1, 1, extent: CGRect(x: 0, y: 0, width: 32, height: 32)))
        let smallCoverage = try engine.inspectLocalMask(
            LocalMask(kind: .radial,
                      start: .init(x: 0.25, y: 0.5), end: .init(x: 0.255, y: 0.505),
                      feather: 0),
            reference: twoBandImage(width: 128, height: 64,
                                    left: (0.02, 0.02, 0.02), right: (0.8, 0.8, 0.8)))

        XCTAssertEqual(empty.coverage, 0, accuracy: 0.005)
        XCTAssertEqual(empty.suggestedExposureEV, 0, accuracy: 0.001)
        XCTAssertEqual(empty.suggestedHighlights, 0, accuracy: 0.001)
        XCTAssertEqual(empty.suggestedShadows, 0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(abs(dark.suggestedExposureEV), 0.25)
        XCTAssertLessThanOrEqual(abs(white.suggestedExposureEV), 0.25)
        XCTAssertLessThanOrEqual(abs(dark.suggestedHighlights), 0.25)
        XCTAssertLessThanOrEqual(abs(white.suggestedShadows), 0.25)
        XCTAssertLessThan(smallCoverage.coverage, 0.005)
        XCTAssertEqual(smallCoverage.suggestedExposureEV, 0, accuracy: 0.001)
        XCTAssertEqual(smallCoverage.suggestedHighlights, 0, accuracy: 0.001)
        XCTAssertEqual(smallCoverage.suggestedShadows, 0, accuracy: 0.001)
    }

    func testHighlightProtectionReducesExposureChangeOnBrightPixels() throws {
        let engine = PhotoEngine()
        let source = solidImage(0.95, 0.95, 0.95,
                                extent: CGRect(x: 0, y: 0, width: 32, height: 32))
        var settings = neutralSettings()
        settings.masks = [LocalMask(kind: .luminance, exposureEV: 1,
                                    highlightProtection: 0, colorProtection: 0)]
        let unprotected = try engine.process(source, settings: settings, lut: nil).image
        settings.masks = [LocalMask(kind: .luminance, exposureEV: 1,
                                    highlightProtection: 1, colorProtection: 0)]
        let protected = try engine.process(source, settings: settings, lut: nil).image
        let originalValue = try pixel(source, x: 16, y: 16, engine: engine)[0]
        let unprotectedValue = try pixel(unprotected, x: 16, y: 16, engine: engine)[0]
        let protectedValue = try pixel(protected, x: 16, y: 16, engine: engine)[0]

        XCTAssertGreaterThan(unprotectedValue, originalValue + 0.5)
        XCTAssertLessThan(protectedValue, unprotectedValue - 0.2)
        XCTAssertGreaterThan(protectedValue, originalValue)

        settings.masks = [LocalMask(kind: .luminance, exposureEV: -1,
                                    highlightProtection: 0, colorProtection: 0)]
        let unprotectedRecovery = try engine.process(source, settings: settings, lut: nil).image
        settings.masks = [LocalMask(kind: .luminance, exposureEV: -1,
                                    highlightProtection: 1, colorProtection: 0)]
        let protectedRecovery = try engine.process(source, settings: settings, lut: nil).image
        let recoveryWithoutProtection = try pixel(unprotectedRecovery, x: 16, y: 16, engine: engine)[0]
        let recoveryWithProtection = try pixel(protectedRecovery, x: 16, y: 16, engine: engine)[0]
        XCTAssertEqual(recoveryWithProtection, recoveryWithoutProtection, accuracy: 0.02,
                       "高光保护应限制提亮，不能削弱对高光的负 EV 恢复")
    }

    func testColorProtectionDoesNotReduceExposureOrDesaturation() throws {
        let engine = PhotoEngine()
        let source = solidImage(0.65, 0.16, 0.07,
                                extent: CGRect(x: 0, y: 0, width: 32, height: 32))
        var settings = neutralSettings()
        settings.masks = [LocalMask(kind: .luminance, exposureEV: 0.8,
                                    highlightProtection: 0, colorProtection: 0)]
        let exposed = try engine.process(source, settings: settings, lut: nil).image
        settings.masks = [LocalMask(kind: .luminance, exposureEV: 0.8,
                                    highlightProtection: 0, colorProtection: 1)]
        let protectedExposure = try engine.process(source, settings: settings, lut: nil).image

        settings.masks = [LocalMask(kind: .luminance, saturation: 0,
                                    highlightProtection: 0, colorProtection: 0)]
        let desaturated = try engine.process(source, settings: settings, lut: nil).image
        settings.masks = [LocalMask(kind: .luminance, saturation: 0,
                                    highlightProtection: 0, colorProtection: 1)]
        let protectedDesaturation = try engine.process(source, settings: settings, lut: nil).image

        let exposedPixel = try pixel(exposed, x: 16, y: 16, engine: engine)
        let protectedExposurePixel = try pixel(protectedExposure, x: 16, y: 16, engine: engine)
        let desaturatedPixel = try pixel(desaturated, x: 16, y: 16, engine: engine)
        let protectedDesaturationPixel = try pixel(protectedDesaturation, x: 16, y: 16, engine: engine)
        for channel in 0..<3 {
            XCTAssertEqual(protectedExposurePixel[channel], exposedPixel[channel], accuracy: 0.02,
                           "色彩保护不能衰减只改变亮度的曝光调整")
            XCTAssertEqual(protectedDesaturationPixel[channel], desaturatedPixel[channel], accuracy: 0.02,
                           "色彩保护不能抵消去饱和")
        }
        settings.masks = [LocalMask(kind: .luminance, exposureEV: 8,
                                    highlightProtection: 0, colorProtection: 0)]
        let extreme = try engine.process(source, settings: settings, lut: nil).image
        settings.masks[0].colorProtection = 1
        let extremeProtected = try engine.process(source, settings: settings, lut: nil).image
        let a = try pixel(extreme, x: 16, y: 16, engine: engine)
        let b = try pixel(extremeProtected, x: 16, y: 16, engine: engine)
        for channel in 0..<3 { XCTAssertEqual(a[channel], b[channel], accuracy: 0.05) }
    }

    func testInvalidRangesKindsPointCountsAndDuplicateIDsAreRejected() {
        var nonFinite = LocalMask()
        nonFinite.opacity = .nan
        assertRejected([nonFinite])

        let invertedRange = LocalMask(restrictLuminance: true,
                                      luminanceMin: 0.8, luminanceMax: 0.2)
        assertRejected([invertedRange])

        assertRejected([LocalMask(components: [MaskComponent(kind: .color)])])

        let tooManyPoints = Array(repeating: MaskPoint(x: 0.5, y: 0.5), count: 4097)
        assertRejected([LocalMask(components: [MaskComponent(kind: .brush, points: tooManyPoints)])])

        let repeatedID = UUID()
        assertRejected([
            LocalMask(id: repeatedID, enabled: false),
            LocalMask(id: repeatedID, enabled: false)
        ])
        assertRejected([LocalMask(id: repeatedID,
                                  components: [MaskComponent(id: repeatedID, kind: .brush,
                                                             points: [.init(x: 0.5, y: 0.5)])])])

        let fullStroke = Array(repeating: MaskPoint(x: 0.5, y: 0.5), count: 4096)
        var atLimit = neutralSettings()
        atLimit.masks = (0..<8).map { _ in LocalMask(kind: .brush, points: fullStroke) }
        XCTAssertNoThrow(try PhotoEngine.validate(atLimit), "跨蒙版总点数正好为 32768 时应接受")
        var overLimit = neutralSettings()
        overLimit.masks = (0..<9).map { _ in LocalMask(kind: .brush, points: fullStroke) }
        XCTAssertThrowsError(try PhotoEngine.validate(overLimit), "跨蒙版总点数超过 32768 时应拒绝")

        func components(_ count: Int) -> [MaskComponent] {
            (0..<count).map { _ in
                MaskComponent(kind: .brush, points: [.init(x: 0.5, y: 0.5)])
            }
        }
        var atGlobalComponentLimit = neutralSettings()
        atGlobalComponentLimit.masks = [
            LocalMask(components: components(32)),
            LocalMask(components: components(32))
        ]
        XCTAssertNoThrow(try PhotoEngine.validate(atGlobalComponentLimit),
                         "跨蒙版组件数正好为 64 时应接受")
        var overGlobalComponentLimit = neutralSettings()
        overGlobalComponentLimit.masks = [
            LocalMask(components: components(33)),
            LocalMask(components: components(32))
        ]
        XCTAssertThrowsError(try PhotoEngine.validate(overGlobalComponentLimit),
                             "跨蒙版组件数超过 64 时应拒绝")
    }

    private func neutralSettings() -> AdjustmentSettings {
        var settings = AdjustmentSettings()
        settings.autoExposure = false
        settings.autoWhiteBalance = false
        settings.exposureEV = 0
        settings.temperature = 0
        settings.tint = 0
        settings.contrast = 1
        settings.saturation = 1
        settings.highlights = 0
        settings.shadows = 0
        settings.rotationDegrees = 0
        settings.verticalPerspective = 0
        settings.horizontalPerspective = 0
        settings.lutIntensity = 1
        settings.preserveLuminance = 0
        settings.protectSkin = 0
        settings.protectNeutrals = 0
        settings.gamutCompression = 0
        // Keep these mask pixel assertions independent of the final color guard.
        settings.colorHarmony = nil
        return settings
    }

    private func assertRejected(_ masks: [LocalMask], file: StaticString = #filePath, line: UInt = #line) {
        var settings = neutralSettings()
        settings.masks = masks
        XCTAssertThrowsError(try PhotoEngine.validate(settings), file: file, line: line)
    }

    private func solidImage(_ red: Double, _ green: Double, _ blue: Double,
                            alpha: Double = 1, extent: CGRect) -> CIImage {
        let color = CIColor(red: red, green: green, blue: blue, alpha: alpha,
                            colorSpace: linearColorSpace)!
        return CIImage(color: color).cropped(to: extent)
    }

    private func twoBandImage(width: Int, height: Int,
                              left: (Double, Double, Double), right: (Double, Double, Double),
                              originX: CGFloat = 0, originY: CGFloat = 0) -> CIImage {
        let halfWidth = CGFloat(width) * 0.5
        let leftRect = CGRect(x: originX, y: originY, width: halfWidth, height: CGFloat(height))
        let rightRect = CGRect(x: originX + halfWidth, y: originY,
                               width: halfWidth, height: CGFloat(height))
        return solidImage(left.0, left.1, left.2, extent: leftRect)
            .composited(over: solidImage(right.0, right.1, right.2, extent: rightRect))
    }

    private func pixel(_ image: CIImage, x: Double, y: Double,
                       engine: PhotoEngine) throws -> [Float] {
        var components = [Float](repeating: 0, count: 4)
        let bounds = CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)
        components.withUnsafeMutableBytes { buffer in
            engine.context.render(image, toBitmap: buffer.baseAddress!,
                                  rowBytes: 4 * MemoryLayout<Float>.size,
                                  bounds: bounds, format: .RGBAf,
                                  colorSpace: linearColorSpace)
        }
        return components
    }

    private func normalizedPixel(_ image: CIImage, x: Double, y: Double,
                                 engine: PhotoEngine) throws -> [Float] {
        let extent = image.extent
        let pixelX = floor(Double(extent.minX) + x * Double(extent.width))
        let pixelY = floor(Double(extent.minY) + y * Double(extent.height))
        return try pixel(image, x: pixelX, y: pixelY, engine: engine)
    }

    private func linearToSRGB(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    private func inversionCube() throws -> LUTCube {
        try LUTCube.parse(cubeText { red, green, blue in
            (1 - red, 1 - green, 1 - blue)
        })
    }

    private func cubeText(value: (Float, Float, Float) -> (Float, Float, Float)) -> String {
        var rows: [String] = []
        for blue in 0...1 {
            for green in 0...1 {
                for red in 0...1 {
                    let output = value(Float(red), Float(green), Float(blue))
                    rows.append("\(output.0) \(output.1) \(output.2)")
                }
            }
        }
        return """
        TITLE "local mask stage test"
        LUT_3D_SIZE 2
        \(rows.joined(separator: "\n"))
        """
    }
}

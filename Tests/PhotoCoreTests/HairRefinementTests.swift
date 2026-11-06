import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class HairRefinementTests: XCTestCase {

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: true,
        .cacheIntermediates: false
    ])

    // MARK: - Parameters & Backward Compatibility

    func testHairParametersNeutralityAndValidation() throws {
        var settings = PortraitRefinementSettings()
        XCTAssertTrue(settings.isNeutral)

        settings.hairGapFilling = 0.5
        XCTAssertFalse(settings.isNeutral)
        settings.hairGapFilling = 0

        settings.hairGloss = 0.3
        XCTAssertFalse(settings.isNeutral)
        settings.hairGloss = 0

        settings.hairDarkening = 0.4
        XCTAssertFalse(settings.isNeutral)
        settings.hairDarkening = 0

        XCTAssertTrue(settings.isNeutral)

        // Validation bounds
        var invalid = PortraitRefinementSettings()
        invalid.hairGapFilling = 1.5
        XCTAssertThrowsError(try PortraitRefinementEngine.validate(invalid))

        invalid = PortraitRefinementSettings()
        invalid.hairGloss = -0.1
        XCTAssertThrowsError(try PortraitRefinementEngine.validate(invalid))

        invalid = PortraitRefinementSettings()
        invalid.hairDarkening = Double.nan
        XCTAssertThrowsError(try PortraitRefinementEngine.validate(invalid))
    }

    func testLegacyRecipeDecodingWithoutHairFields() throws {
        // Legacy JSON produced before P2-B without hair fields
        let legacyJSON = """
        {
            "blemishStrength": 0.2,
            "keepSpots": true,
            "dodgeBurn": 0.15,
            "structure": 0.1,
            "texture": 0.05,
            "gloss": 0.0,
            "teethWhiten": 0.3,
            "eyeBrighten": 0.25,
            "skinToneUnify": 0.0,
            "skinToneReference": "auto"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PortraitRefinementSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.blemishStrength, 0.2, accuracy: 1e-6)
        XCTAssertEqual(decoded.keepSpots, true)
        XCTAssertEqual(decoded.hairGapFilling, 0.0, "缺失的发缝填充必须默认解码为 0")
        XCTAssertEqual(decoded.hairGloss, 0.0, "缺失的秀发光泽必须默认解码为 0")
        XCTAssertEqual(decoded.hairDarkening, 0.0, "缺失的发色深邃必须默认解码为 0")

        // Full round-trip with hair fields
        var full = decoded
        full.hairGapFilling = 0.6
        full.hairGloss = 0.45
        full.hairDarkening = 0.35
        let encoded = try JSONEncoder().encode(full)
        let restored = try JSONDecoder().decode(PortraitRefinementSettings.self, from: encoded)
        XCTAssertEqual(full, restored)
    }

    // MARK: - Engine Rendering Tests

    func testHairGapFillingShadesScalpAndPreservesDarkHair() throws {
        let width = 120, height = 120
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        // Synthetic image:
        // Face occupies bottom-center [30...90, 10...60] (normalized [0.25...0.75, 0.08...0.50])
        // Hair region is [20...100, 60...115]
        // Scalp parting is along x in [56...64], y in [65...105] (bright warm skin tone)
        // Dark hair is in [20...55, 60...115] and [65...100, 60...115] (dark brown/black)
        let bitmap = renderImage(width: width, height: height) { x, y in
            if y >= 65 && y <= 105 && abs(x - 60) <= 3 {
                // Exposed scalp in parting: bright warm skin tone (R=0.65, G=0.52, B=0.45)
                return (r: 0.65, g: 0.52, b: 0.45, a: 1.0)
            } else if y >= 60 && y <= 115 && x >= 20 && x <= 100 {
                // Dense hair: dark tone (R=0.08, G=0.07, B=0.06)
                return (r: 0.08, g: 0.07, b: 0.06, a: 1.0)
            } else {
                // Background neutral gray (R=0.5, G=0.5, B=0.5)
                return (r: 0.50, g: 0.50, b: 0.50, a: 1.0)
            }
        }

        let faceBounds = CGRect(x: 0.25, y: 0.08, width: 0.50, height: 0.42)
        let maskSet = FaceSemanticMaskSet(
            extent: extent,
            resolution: CGSize(width: width, height: height),
            faceBounds: faceBounds,
            confidence: 0.95,
            faceCount: 1,
            skin: nil,
            teeth: nil,
            sclera: nil,
            iris: nil,
            lips: nil,
            brows: nil
        )

        // Neutral settings should return identical image
        let neutral = PortraitRefinementSettings()
        let untouched = try HairRefinementEngine.apply(bitmap, settings: neutral,
                                                      faceMasks: [maskSet], context: context)
        XCTAssertEqual(untouched, bitmap)

        // Active gap filling
        var active = PortraitRefinementSettings()
        active.hairGapFilling = 0.8
        let result = try HairRefinementEngine.apply(bitmap, settings: active,
                                                   faceMasks: [maskSet], context: context)

        let beforePixels = pixelData(bitmap)
        let afterPixels = pixelData(result)

        // Measure scalp pixel at (60, 75)
        let scalpOffset = (75 * width + 60) * 4
        let scalpBeforeR = beforePixels[scalpOffset]
        let scalpAfterR = afterPixels[scalpOffset]
        XCTAssertLessThan(scalpAfterR, scalpBeforeR - 0.08,
                          "发缝暴露的高亮头皮必须明显被加深填补")

        // Measure dark hair pixel at (35, 75)
        let hairOffset = (75 * width + 35) * 4
        let hairBeforeR = beforePixels[hairOffset]
        let hairAfterR = afterPixels[hairOffset]
        XCTAssertEqual(hairAfterR, hairBeforeR, accuracy: 0.015,
                       "原本就是暗发丝的区域发缝填充不应产生剧烈改变")

        // Measure background pixel at (10, 10)
        let bgOffset = (10 * width + 10) * 4
        XCTAssertEqual(afterPixels[bgOffset], beforePixels[bgOffset], accuracy: 0.001,
                       "人脸与头发框外的背景像素必须严格保持原样")
    }

    func testHairGlossBoostsCrownHighlights() throws {
        let width = 120, height = 120
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        let bitmap = renderImage(width: width, height: height) { x, y in
            if y >= 60 && y <= 115 && x >= 20 && x <= 100 {
                // Hair with subtle highlight in crown band (y around 70...88)
                if y >= 70 && y <= 88 {
                    return (r: 0.28, g: 0.24, b: 0.20, a: 1.0)
                } else {
                    return (r: 0.10, g: 0.09, b: 0.08, a: 1.0)
                }
            } else {
                return (r: 0.40, g: 0.40, b: 0.40, a: 1.0)
            }
        }

        let faceBounds = CGRect(x: 0.25, y: 0.08, width: 0.50, height: 0.42)
        let maskSet = FaceSemanticMaskSet(
            extent: extent,
            resolution: CGSize(width: width, height: height),
            faceBounds: faceBounds,
            confidence: 0.95,
            faceCount: 1,
            skin: nil,
            teeth: nil,
            sclera: nil,
            iris: nil,
            lips: nil,
            brows: nil
        )

        var settings = PortraitRefinementSettings()
        settings.hairGloss = 0.9
        let result = try HairRefinementEngine.apply(bitmap, settings: settings,
                                                   faceMasks: [maskSet], context: context)

        let before = pixelData(bitmap)
        let after = pixelData(result)

        // Crown highlight pixel at (60, 78)
        let offset = (78 * width + 60) * 4
        XCTAssertGreaterThan(after[offset], before[offset] + 0.015,
                             "发冠高光带必须呈现缎面天使光泽增益")
    }

    func testHairDarkeningSuppressesBrassinessAndDeepensMidtones() throws {
        let width = 120, height = 120
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        let bitmap = renderImage(width: width, height: height) { x, y in
            if y >= 60 && y <= 115 && x >= 20 && x <= 100 {
                // Brassy / faded yellowish hair (high red/green, low blue)
                return (r: 0.35, g: 0.28, b: 0.12, a: 1.0)
            } else {
                return (r: 0.50, g: 0.50, b: 0.50, a: 1.0)
            }
        }

        let faceBounds = CGRect(x: 0.25, y: 0.08, width: 0.50, height: 0.42)
        let maskSet = FaceSemanticMaskSet(
            extent: extent,
            resolution: CGSize(width: width, height: height),
            faceBounds: faceBounds,
            confidence: 0.95,
            faceCount: 1,
            skin: nil,
            teeth: nil,
            sclera: nil,
            iris: nil,
            lips: nil,
            brows: nil
        )

        var settings = PortraitRefinementSettings()
        settings.hairDarkening = 0.8
        let result = try HairRefinementEngine.apply(bitmap, settings: settings,
                                                   faceMasks: [maskSet], context: context)

        let before = pixelData(bitmap)
        let after = pixelData(result)

        let hairOffset = (75 * width + 45) * 4
        let beforeR = before[hairOffset]
        let afterR = after[hairOffset]
        let beforeB = before[hairOffset + 2]
        let afterB = after[hairOffset + 2]

        XCTAssertLessThan(afterR, beforeR - 0.03, "发色深邃应降低红黄色阶")
        // Brassiness ratio (R - B) should decrease
        let beforeBrassiness = beforeR - beforeB
        let afterBrassiness = afterR - afterB
        XCTAssertLessThan(afterBrassiness, beforeBrassiness, "枯黄杂色应被有效抑制")
    }

    func testPortraitPipelineIntegratesHairSteps() throws {
        let width = 120, height = 120
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let bitmap = renderImage(width: width, height: height) { _, _ in
            (r: 0.3, g: 0.3, b: 0.3, a: 1.0)
        }

        let faceBounds = CGRect(x: 0.25, y: 0.08, width: 0.50, height: 0.42)
        let maskSet = FaceSemanticMaskSet(
            extent: extent,
            resolution: CGSize(width: width, height: height),
            faceBounds: faceBounds,
            confidence: 0.95,
            faceCount: 1,
            skin: nil,
            teeth: nil,
            sclera: nil,
            iris: nil,
            lips: nil,
            brows: nil
        )

        var settings = PortraitRefinementSettings()
        settings.hairGapFilling = 0.5
        settings.hairGloss = 0.5
        settings.hairDarkening = 0.5

        let res = try PortraitRefinementEngine.apply(bitmap, settings: settings,
                                                    faceMasks: [maskSet], context: context)
        XCTAssertTrue(res.report.applied)
        XCTAssertTrue(res.report.appliedSteps.contains("hairGap"))
        XCTAssertTrue(res.report.appliedSteps.contains("hairGloss"))
        XCTAssertTrue(res.report.appliedSteps.contains("hairDarkening"))
    }

    // MARK: - Helpers

    private func renderImage(width: Int, height: Int,
                             generator: (Int, Int) -> (r: Float, g: Float, b: Float, a: Float)) -> CIImage {
        var data = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = generator(x, y)
                // In CIImage(bitmapData:...), row 0 is top. Map bottom-left y (Core Image coordinates) to row.
                let row = height - 1 - y
                let offset = (row * width + x) * 4
                data[offset + 0] = pixel.r
                data[offset + 1] = pixel.g
                data[offset + 2] = pixel.b
                data[offset + 3] = pixel.a
            }
        }
        return CIImage(bitmapData: Data(bytes: data, count: data.count * MemoryLayout<Float>.size),
                       bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                       size: CGSize(width: width, height: height),
                       format: .RGBAf,
                       colorSpace: linearColorSpace)
    }

    private func pixelData(_ image: CIImage) -> [Float] {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var raw = [Float](repeating: 0, count: width * height * 4)
        context.render(image,
                       toBitmap: &raw,
                       rowBytes: width * 4 * MemoryLayout<Float>.size,
                       bounds: image.extent,
                       format: .RGBAf,
                       colorSpace: linearColorSpace)
        var flipped = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let row = height - 1 - y
                let srcOffset = (row * width + x) * 4
                let dstOffset = (y * width + x) * 4
                for c in 0..<4 {
                    flipped[dstOffset + c] = raw[srcOffset + c]
                }
            }
        }
        return flipped
    }
}

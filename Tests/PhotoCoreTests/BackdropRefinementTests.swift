import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class BackdropRefinementTests: XCTestCase {

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: true,
        .cacheIntermediates: false
    ])

    // MARK: - Settings & Validation

    func testNeutralityAndValidation() throws {
        var settings = BackdropRefinementSettings()
        XCTAssertTrue(settings.isNeutral)

        settings.enabled = true
        XCTAssertTrue(settings.isNeutral, "强度全为 0 时即使 enabled 也保持中性")

        settings.smoothing = 0.5
        XCTAssertFalse(settings.isNeutral)
        settings.smoothing = 0

        settings.cleanup = 0.3
        XCTAssertFalse(settings.isNeutral)
        settings.cleanup = 0

        settings.uniformity = 0.4
        XCTAssertFalse(settings.isNeutral)
        settings.uniformity = 0

        XCTAssertTrue(settings.isNeutral)

        // Validation bounds
        var invalid = BackdropRefinementSettings(enabled: true, smoothing: 1.5)
        XCTAssertThrowsError(try invalid.validated())

        invalid = BackdropRefinementSettings(enabled: true, cleanup: -0.1)
        XCTAssertThrowsError(try invalid.validated())

        invalid = BackdropRefinementSettings(enabled: true, uniformity: Double.nan)
        XCTAssertThrowsError(try invalid.validated())
    }

    func testVersionGateEnforcesVersion14() throws {
        var recipe = Recipe()
        recipe.version = 13
        recipe.adjustments.backdrop = BackdropRefinementSettings(enabled: true, smoothing: 0.5)
        XCTAssertThrowsError(try recipe.validateVersion(), "非中性背景修复在配方版本低于 14 时必须报错阻止静默降级")

        recipe.version = 14
        XCTAssertNoThrow(try recipe.validateVersion())
    }

    func testLegacyRecipeDecoding() throws {
        var base = Recipe()
        base.version = 13
        base.adjustments.exposureEV = 0.2
        base.adjustments.backdrop = nil
        let baseData = try JSONEncoder().encode(base)

        let decoded = try JSONDecoder().decode(Recipe.self, from: baseData)
        XCTAssertNil(decoded.adjustments.backdrop, "旧配方未提供 backdrop 时必须解码为 nil")

        var updated = decoded
        updated.version = 14
        updated.adjustments.backdrop = BackdropRefinementSettings(enabled: true, smoothing: 0.6, cleanup: 0.4, uniformity: 0.2)
        let encoded = try JSONEncoder().encode(updated)
        let restored = try JSONDecoder().decode(Recipe.self, from: encoded)
        XCTAssertEqual(updated.adjustments.backdrop, restored.adjustments.backdrop)
    }

    // MARK: - Engine Rendering Tests

    func testBackdropSmoothingReducesWrinklesAndProtectsSubject() throws {
        let width = 120, height = 120

        // Synthetic scene:
        // Person occupies center [40...80, 20...100] (solid cyan color: R=0.1, G=0.7, B=0.8)
        // Backdrop is outside with a sharp horizontal fold/crease along y=60 (R=0.75 vs R=0.45)
        let bitmap = renderImage(width: width, height: height) { x, y in
            if x >= 40 && x <= 80 && y >= 20 && y <= 100 {
                // Subject
                return (r: 0.10, g: 0.70, b: 0.80, a: 1.0)
            } else {
                // Backdrop with paper crease along y=60
                let isCrease = abs(y - 60) <= 2
                let base: Float = isCrease ? 0.45 : 0.75
                return (r: base, g: base, b: base, a: 1.0)
            }
        }

        // Person mask (1.0 for person, 0.0 for background)
        let maskImage = renderImage(width: width, height: height) { x, y in
            if x >= 40 && x <= 80 && y >= 20 && y <= 100 {
                return (r: 1.0, g: 1.0, b: 1.0, a: 1.0)
            } else {
                return (r: 0.0, g: 0.0, b: 0.0, a: 1.0)
            }
        }

        let matte = PersonMatte(
            mask: maskImage,
            coverage: 0.25,
            confidence: 0.95,
            hasPerson: true,
            settings: PersonMatteSettings()
        )

        let settings = BackdropRefinementSettings(enabled: true, smoothing: 0.85)
        let (result, report) = try BackdropRefinementEngine.apply(
            bitmap, settings: settings, personMatte: matte, context: context
        )

        XCTAssertTrue(report.applied)
        XCTAssertTrue(report.appliedSteps.contains("smoothing"))

        let before = pixelData(bitmap)
        let after = pixelData(result)

        // 1. Check person pixel at (60, 60): MUST BE 100% UNCHANGED
        let personOffset = (60 * width + 60) * 4
        XCTAssertEqual(after[personOffset + 0], before[personOffset + 0], accuracy: 0.001)
        XCTAssertEqual(after[personOffset + 1], before[personOffset + 1], accuracy: 0.001)
        XCTAssertEqual(after[personOffset + 2], before[personOffset + 2], accuracy: 0.001)

        // 2. Check crease on backdrop at (20, 60) vs smooth backdrop at (20, 75)
        let creaseOffset = (60 * width + 20) * 4
        let flatOffset = (75 * width + 20) * 4
        let contrastBefore = abs(before[flatOffset] - before[creaseOffset])
        let contrastAfter = abs(after[flatOffset] - after[creaseOffset])

        XCTAssertLessThan(contrastAfter, contrastBefore * 0.60,
                          "背景纸折痕处的明暗落差应被平整降低")
    }

    func testBackdropCleanupRemovesIsolatedSpots() throws {
        let width = 120, height = 120

        // Synthetic scene:
        // Person at center [45...75, 20...100]
        // Background is light gray (0.75) with an isolated dark footprint/spot at (25, 80) (0.20)
        let bitmap = renderImage(width: width, height: height) { x, y in
            if x >= 45 && x <= 75 && y >= 20 && y <= 100 {
                return (r: 0.85, g: 0.60, b: 0.50, a: 1.0)
            } else if abs(x - 25) <= 2 && abs(y - 80) <= 2 {
                // High contrast dark dirt/footprint spot
                return (r: 0.20, g: 0.20, b: 0.20, a: 1.0)
            } else {
                return (r: 0.75, g: 0.75, b: 0.75, a: 1.0)
            }
        }

        let maskImage = renderImage(width: width, height: height) { x, y in
            if x >= 45 && x <= 75 && y >= 20 && y <= 100 {
                return (r: 1.0, g: 1.0, b: 1.0, a: 1.0)
            } else {
                return (r: 0.0, g: 0.0, b: 0.0, a: 1.0)
            }
        }

        let matte = PersonMatte(
            mask: maskImage,
            coverage: 0.22,
            confidence: 0.95,
            hasPerson: true,
            settings: PersonMatteSettings()
        )

        let settings = BackdropRefinementSettings(enabled: true, cleanup: 0.90)
        let (result, report) = try BackdropRefinementEngine.apply(
            bitmap, settings: settings, personMatte: matte, context: context
        )

        XCTAssertTrue(report.applied)
        XCTAssertTrue(report.appliedSteps.contains("cleanup"))

        let before = pixelData(bitmap)
        let after = pixelData(result)

        // Spot pixel at (25, 80)
        let spotOffset = (80 * width + 25) * 4
        let spotBefore = before[spotOffset]
        let spotAfter = after[spotOffset]

        XCTAssertGreaterThan(spotAfter, spotBefore + 0.30,
                             "孤立脏污脚印暗斑应被邻域浅色背景有效清除抚平")
    }

    func testBackdropWithoutPersonGracefullySkips() throws {
        let width = 100, height = 100
        let bitmap = renderImage(width: width, height: height) { _, _ in
            (r: 0.5, g: 0.5, b: 0.5, a: 1.0)
        }

        // Empty matte with hasPerson = false
        let emptyMatte = PersonMatte(
            mask: bitmap,
            coverage: 0.0,
            confidence: 0.0,
            hasPerson: false,
            settings: PersonMatteSettings()
        )

        let settings = BackdropRefinementSettings(enabled: true, smoothing: 0.5)
        let (result, report) = try BackdropRefinementEngine.apply(
            bitmap, settings: settings, personMatte: emptyMatte, context: context
        )

        XCTAssertFalse(report.applied)
        XCTAssertNotNil(report.note)
        XCTAssertEqual(result, bitmap, "无人物时必须原图返回，不改动任何像素")
    }

    // MARK: - Helpers

    private func renderImage(width: Int, height: Int,
                             generator: (Int, Int) -> (r: Float, g: Float, b: Float, a: Float)) -> CIImage {
        var data = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = generator(x, y)
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

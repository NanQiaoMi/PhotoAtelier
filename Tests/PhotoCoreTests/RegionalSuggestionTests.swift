import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class RegionalSuggestionTests: XCTestCase {
    private typealias RGBA = (r: Float, g: Float, b: Float, a: Float)

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var engine = PhotoEngine()

    func testTopAndBottomSuggestionsUseNormalizedCoordinatesWithTranslatedExtent() throws {
        let origin = CGPoint(x: 29, y: -17)
        let topLeft = gridImage(darkCell: (column: 0, rowFromTop: 0), origin: origin)
        let bottomRight = gridImage(darkCell: (column: 2, rowFromTop: 2), origin: .zero)

        let upper = try XCTUnwrap(RegionalAdjustmentAnalyzer.suggestions(
            reference: topLeft, context: engine.context).first { $0.mask.luminanceMax == 0.5 })
        let lower = try XCTUnwrap(RegionalAdjustmentAnalyzer.suggestions(
            reference: bottomRight, context: engine.context).first { $0.mask.luminanceMax == 0.5 })

        XCTAssertEqual(topLeft.extent.origin.x, origin.x, accuracy: 0)
        XCTAssertEqual(topLeft.extent.origin.y, origin.y, accuracy: 0)
        XCTAssertEqual(upper.mask.start.x, 1.0 / 6.0, accuracy: 0.01)
        XCTAssertEqual(upper.mask.start.y, 5.0 / 6.0, accuracy: 0.01)
        XCTAssertEqual(lower.mask.start.x, 5.0 / 6.0, accuracy: 0.01)
        XCTAssertEqual(lower.mask.start.y, 1.0 / 6.0, accuracy: 0.01)
        XCTAssertLessThan(upper.mask.end.y, upper.mask.start.y)
        XCTAssertGreaterThan(lower.mask.end.y, lower.mask.start.y)
    }

    func testUniformFieldsAndLowAlphaContrastDoNotCreateSuggestions() throws {
        let uniformBlack = solidImage(0.02, extent: CGRect(x: 0, y: 0, width: 96, height: 96))
        let uniformBright = solidImage(0.85, extent: CGRect(x: 0, y: 0, width: 96, height: 96))
        XCTAssertTrue(try RegionalAdjustmentAnalyzer.suggestions(
            reference: uniformBlack, context: engine.context).isEmpty)
        XCTAssertTrue(try RegionalAdjustmentAnalyzer.suggestions(
            reference: uniformBright, context: engine.context).isEmpty)

        let hiddenDarkRegion = bitmapImage(width: 96, height: 96) { x, y in
            if x < 32 && y < 32 { return (0.03, 0.03, 0.03, 0.0005) }
            return (0.3, 0.3, 0.3, 1)
        }
        XCTAssertTrue(try RegionalAdjustmentAnalyzer.suggestions(
            reference: hiddenDarkRegion, context: engine.context).isEmpty,
            "a low-alpha dark cell must not outweigh the visible uniform field")
    }

    func testSuggestionsAreStableValidAndOnlyChangeTheirMatchingToneRange() throws {
        let source = suggestionFixture()
        var settings = AdjustmentSettings()
        settings.autoExposure = false
        settings.autoWhiteBalance = true
        settings.temperature = 0.1
        settings.tint = -0.05
        settings.lutIntensity = 0.82
        settings.lutColorSpace = .sRGB
        settings.colorHarmony = nil

        let reference = try engine.maskReferenceImage(source, settings: settings)
        let first = try RegionalAdjustmentAnalyzer.suggestions(reference: reference, context: engine.context)
        let repeated = try RegionalAdjustmentAnalyzer.suggestions(reference: reference, context: engine.context)
        XCTAssertEqual(first.count, 2, "suggestions should contain at most one shadow and one highlight")
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)
        XCTAssertEqual(Set(first.map(\.mask.id)).count, first.count)
        XCTAssertTrue(settings.masks.isEmpty, "analysis should return suggestions without applying them")

        let shadow = try XCTUnwrap(first.first { $0.mask.luminanceMax == 0.5 })
        let highlight = try XCTUnwrap(first.first { $0.mask.luminanceMin == 0.65 })
        XCTAssertTrue(shadow.mask.restrictLuminance)
        XCTAssertEqual(shadow.mask.luminanceMin, 0, accuracy: 0)
        XCTAssertEqual(shadow.mask.luminanceMax, 0.5, accuracy: 0)
        XCTAssertTrue(highlight.mask.restrictLuminance)
        XCTAssertEqual(highlight.mask.luminanceMin, 0.65, accuracy: 0)
        XCTAssertEqual(highlight.mask.luminanceMax, 1, accuracy: 0)

        let before = try engine.process(source, settings: settings, lut: nil).image
        for suggestion in [shadow, highlight] {
            var selectedSettings = settings
            selectedSettings.masks.append(suggestion.mask)
            XCTAssertNoThrow(try PhotoEngine.validate(selectedSettings))
            XCTAssertTrue(selectedSettings.autoWhiteBalance)
            XCTAssertEqual(selectedSettings.temperature, settings.temperature, accuracy: 0)
            XCTAssertEqual(selectedSettings.tint, settings.tint, accuracy: 0)
            XCTAssertEqual(selectedSettings.lutIntensity, settings.lutIntensity, accuracy: 0)
            XCTAssertEqual(selectedSettings.lutColorSpace, settings.lutColorSpace)

            let after = try engine.process(source, settings: selectedSettings, lut: nil).image
            if suggestion.id == shadow.id {
                let darkBefore = luminance(try pixel(before, x: 16, y: 80))
                let darkAfter = luminance(try pixel(after, x: 16, y: 80))
                let midBefore = luminance(try pixel(before, x: 22, y: 80))
                let midAfter = luminance(try pixel(after, x: 22, y: 80))
                XCTAssertGreaterThan(darkAfter, darkBefore * 1.25)
                XCTAssertEqual(midAfter, midBefore, accuracy: 0.002,
                               "the nearby midtone should be excluded by the shadow luminance range")
            } else {
                let brightBefore = luminance(try pixel(before, x: 84, y: 16))
                let brightAfter = luminance(try pixel(after, x: 84, y: 16))
                let darkBefore = luminance(try pixel(before, x: 80, y: 16))
                let darkAfter = luminance(try pixel(after, x: 80, y: 16))
                XCTAssertLessThan(brightAfter, brightBefore * 0.9)
                XCTAssertEqual(darkAfter, darkBefore, accuracy: 0.002,
                               "the nearby dark pixel should be excluded by the highlight luminance range")
            }
        }
    }

    private func gridImage(darkCell: (column: Int, rowFromTop: Int), origin: CGPoint) -> CIImage {
        let extent = CGRect(origin: origin, size: CGSize(width: 96, height: 96))
        let cell = CGRect(x: origin.x + CGFloat(darkCell.column * 32),
                          y: origin.y + CGFloat((2 - darkCell.rowFromTop) * 32),
                          width: 32, height: 32)
        return solidImage(0.03, extent: cell).composited(over: solidImage(0.3, extent: extent))
    }

    private func suggestionFixture() -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: 96, height: 96)
        var result = solidImage(0.25, extent: extent)
        // Linear 0.40 encodes to about 0.665 sRGB, beyond the shadow range's
        // 0.575 feather edge, while remaining inside its radial feather.
        result = solidImage(0.03, extent: CGRect(x: 0, y: 64, width: 32, height: 32))
            .composited(over: result)
        result = solidImage(0.40, extent: CGRect(x: 20, y: 76, width: 4, height: 8))
            .composited(over: result)
        // Bright target at the lower-right cell, with a nearby dark pixel
        // inside its radial feather so the luminance floor excludes it.
        result = solidImage(0.9, extent: CGRect(x: 64, y: 0, width: 32, height: 32))
            .composited(over: result)
        result = solidImage(0.03, extent: CGRect(x: 76, y: 12, width: 8, height: 8))
            .composited(over: result)
        return result
    }

    private func solidImage(_ value: Double, alpha: Double = 1, extent: CGRect) -> CIImage {
        let color = CIColor(red: value, green: value, blue: value, alpha: alpha,
                            colorSpace: linearColorSpace)!
        return CIImage(color: color).cropped(to: extent)
    }

    private func bitmapImage(width: Int, height: Int,
                             pixel: (Int, Int) -> RGBA) -> CIImage {
        var components = [Float]()
        components.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                components.append(value.r * value.a)
                components.append(value.g * value.a)
                components.append(value.b * value.a)
                components.append(value.a)
            }
        }
        let data = components.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        return CIImage(bitmapData: data,
                       bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                       size: CGSize(width: width, height: height),
                       format: .RGBAf,
                       colorSpace: linearColorSpace)
    }

    private func pixel(_ image: CIImage, x: Int, y: Int) throws -> [Float] {
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { buffer in
            engine.context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 16,
                                  bounds: CGRect(x: x, y: y, width: 1, height: 1),
                                  format: .RGBAf, colorSpace: linearColorSpace)
        }
        return values
    }

    private func luminance(_ pixel: [Float]) -> Double {
        0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])
    }
}

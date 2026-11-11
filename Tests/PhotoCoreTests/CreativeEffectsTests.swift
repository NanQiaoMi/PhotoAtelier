import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class CreativeEffectsTests: XCTestCase {
    private typealias RGBA = (red: Float, green: Float, blue: Float, alpha: Float)
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linear,
        .outputColorSpace: linear,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: false,
        .useSoftwareRenderer: true,
        .cacheIntermediates: false
    ])

    func testSettingsDefaultToNeutralAndDecodeMissingStrengthsAsZero() throws {
        let settings = CreativeEffectsSettings()
        XCTAssertEqual(settings, CreativeEffectsSettings(bloom: 0, vignette: 0, grain: 0, halation: 0, mist: 0, fade: 0, bleachBypass: 0))
        XCTAssertTrue(settings.isNeutral)

        let decoded = try JSONDecoder().decode(
            CreativeEffectsSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, settings)
        let restored = try JSONDecoder().decode(CreativeEffectsSettings.self,
            from: JSONEncoder().encode(CreativeEffectsSettings(bloom: 0.2, vignette: 0.4, grain: 0.8, halation: 0.1, mist: 0.3, fade: 0.15, bleachBypass: 0.25)))
        XCTAssertEqual(restored, CreativeEffectsSettings(bloom: 0.2, vignette: 0.4, grain: 0.8, halation: 0.1, mist: 0.3, fade: 0.15, bleachBypass: 0.25))
    }

    func testValidationRejectsNonFiniteAndOutOfRangeStrengths() {
        let invalid: [CreativeEffectsSettings] = [
            .init(bloom: -.infinity), .init(bloom: .infinity), .init(bloom: .nan),
            .init(vignette: -0.001), .init(vignette: 1.001),
            .init(grain: -.infinity), .init(grain: .nan), .init(grain: .infinity),
            .init(halation: -0.01), .init(halation: 1.5),
            .init(mist: -.infinity), .init(mist: 1.01),
            .init(fade: -0.01), .init(fade: 1.2),
            .init(bleachBypass: .nan), .init(bleachBypass: 2.0)
        ]
        for settings in invalid {
            XCTAssertThrowsError(try CreativeEffectsEngine.validate(settings))
        }
        XCTAssertNoThrow(try CreativeEffectsEngine.validate(.init()))
        XCTAssertNoThrow(try CreativeEffectsEngine.validate(
            .init(bloom: 1, vignette: 1, grain: 1, halation: 1, mist: 1, fade: 1, bleachBypass: 1)))
    }

    func testHalationAndMistEffectsPreserveGeometryAndAlpha() throws {
        let spot = image(width: 48, height: 48) { x, y in
            (20...28).contains(x) && (20...28).contains(y)
                ? (2.5, 2.0, 1.8, 1.0)
                : (0.1, 0.1, 0.1, 1.0)
        }
        let halationApplied = try CreativeEffectsEngine.apply(
            .init(halation: 0.8), to: spot, context: context)
        XCTAssertEqual(halationApplied.extent, spot.extent)

        let mistApplied = try CreativeEffectsEngine.apply(
            .init(mist: 0.6), to: spot, context: context)
        XCTAssertEqual(mistApplied.extent, spot.extent)

        let fadeApplied = try CreativeEffectsEngine.apply(
            .init(fade: 0.5), to: spot, context: context)
        XCTAssertEqual(fadeApplied.extent, spot.extent)

        let bleachApplied = try CreativeEffectsEngine.apply(
            .init(bleachBypass: 0.5), to: spot, context: context)
        XCTAssertEqual(bleachApplied.extent, spot.extent)

        let halationPixels = try render(halationApplied)
        let haloPixel = pixel(halationPixels, width: 48, x: 18, y: 24)
        // Halation produces warm red-tinted light leaking into edge neighbors
        XCTAssertGreaterThan(haloPixel.red, 0.1)

        let mistPixels = try render(mistApplied)
        let darkPixel = pixel(mistPixels, width: 48, x: 5, y: 5)
        XCTAssertGreaterThan(darkPixel.red, 0.08)

        let fadePixels = try render(fadeApplied)
        let liftedPixel = pixel(fadePixels, width: 48, x: 5, y: 5)
        // Fade lifts deep shadow luminance
        XCTAssertGreaterThan(liftedPixel.red, 0.10)
    }

    func testNeutralSettingsReturnTheOriginalImageAndCancelledWorkThrows() throws {
        let source = solidImage(0.2, 0.3, 0.4, alpha: 0.6,
                               width: 20, height: 12, origin: CGPoint(x: -7, y: 19))
        let neutral = try CreativeEffectsEngine.apply(.init(), to: source, context: context)
        XCTAssertTrue(neutral === source)

        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try CreativeEffectsEngine.apply(
            .init(grain: 0.4), to: source, context: context, cancellation: token)) { error in
            XCTAssertEqual((error as? AtelierError)?.errorDescription,
                           AtelierError.cancelled.errorDescription)
        }
    }

    func testAllEffectsPreserveAlphaTranslatedExtentAndExtendedRange() throws {
        let source = image(width: 48, height: 32, origin: CGPoint(x: -23, y: 17)) { x, y in
            let alpha: Float = (x + y).isMultiple(of: 13) ? 0 : 0.35 + Float((x + 2 * y) % 5) * 0.1
            if (22...26).contains(x) && (14...18).contains(y) {
                return (2.4, 1.2, 0.7, alpha)
            }
            return (0.22 + Float(x) * 0.001, 0.12 + Float(y) * 0.001,
                    0.06 + Float(x + y) * 0.0005, alpha)
        }
        let settings = CreativeEffectsSettings(bloom: 0.8, vignette: 0.7, grain: 0.5)
        let output = try CreativeEffectsEngine.apply(settings, to: source, context: context)

        XCTAssertEqual(output.extent, source.extent)
        let input = try render(source)
        let result = try render(output)
        XCTAssertEqual(result.count, input.count)
        for offset in stride(from: 0, to: input.count, by: 4) {
            XCTAssertEqual(result[offset + 3], input[offset + 3], accuracy: 0.0005,
                           "alpha changed at pixel \(offset / 4)")
        }
        let center = pixel(result, width: 48, x: 24, y: 16)
        XCTAssertGreaterThan(center.red, 1.0, "extended linear input was clipped to SDR")
    }

    func testBloomAddsOnlySoftHighlightEnergyAndLeavesMidGrayAlone() throws {
        let flat = solidImage(0.2, 0.2, 0.2, width: 64, height: 64)
        let grayBloom = try CreativeEffectsEngine.apply(
            .init(bloom: 1), to: flat, context: context)
        let grayInput = try render(flat)
        let grayOutput = try render(grayBloom)
        for offset in stride(from: 0, to: grayInput.count, by: 4) {
            XCTAssertEqual(grayOutput[offset], grayInput[offset], accuracy: 0.0001)
            XCTAssertEqual(grayOutput[offset + 1], grayInput[offset + 1], accuracy: 0.0001)
            XCTAssertEqual(grayOutput[offset + 2], grayInput[offset + 2], accuracy: 0.0001)
        }

        let spot = image(width: 64, height: 64) { x, y in
            (27...36).contains(x) && (27...36).contains(y)
                ? (3.2, 2.4, 1.5, 1)
                : (0.08, 0.08, 0.08, 1)
        }
        let bloom = try CreativeEffectsEngine.apply(.init(bloom: 1), to: spot, context: context)
        let pixels = try render(bloom)
        let near = pixel(pixels, width: 64, x: 25, y: 31)
        let far = pixel(pixels, width: 64, x: 3, y: 3)
        XCTAssertGreaterThan(near.red, 0.08 + 0.001)
        XCTAssertEqual(far.red, 0.08, accuracy: 0.0005)
        XCTAssertGreaterThan(near.red, near.green)
        XCTAssertGreaterThan(near.green, near.blue)
    }

    func testBloomDoesNotClipSDRHighlightsOrClampNegativeAndHDRSourceValues() throws {
        let sdr = image(width: 80, height: 48) { x, y in
            if (34...45).contains(x) && (18...29).contains(y) {
                return (0.99, 0.94, 0.86, 1)
            }
            return (0.82, 0.74, 0.62, 1)
        }
        let sdrOutput = try render(CreativeEffectsEngine.apply(
            .init(bloom: 1), to: sdr, context: context))
        for offset in stride(from: 0, to: sdrOutput.count, by: 4) {
            XCTAssertTrue(sdrOutput[offset].isFinite && sdrOutput[offset + 1].isFinite
                          && sdrOutput[offset + 2].isFinite)
            XCTAssertLessThanOrEqual(max(sdrOutput[offset],
                                         max(sdrOutput[offset + 1], sdrOutput[offset + 2])), 1.0001)
        }

        let extended = solidImage(1.8, -0.25, 0.4, width: 32, height: 24)
        let extendedOutput = try render(CreativeEffectsEngine.apply(
            .init(vignette: 0.3), to: extended, context: context))
        let center = pixel(extendedOutput, width: 32, x: 16, y: 12)
        XCTAssertGreaterThan(center.red, 1.0, "HDR values must remain extended")
        XCTAssertLessThan(center.green, 0.0, "negative linear channels must not be clamped")
    }

    func testVignetteUsesSoftEllipseAndPreservesColorRatios() throws {
        let source = solidImage(0.4, 0.2, 0.1, width: 64, height: 40)
        let vignette = try CreativeEffectsEngine.apply(
            .init(vignette: 1), to: source, context: context)
        let pixels = try render(vignette)
        let center = pixel(pixels, width: 64, x: 32, y: 20)
        let side = pixel(pixels, width: 64, x: 0, y: 20)
        let corner = pixel(pixels, width: 64, x: 0, y: 0)

        XCTAssertGreaterThan(center.red, side.red)
        XCTAssertGreaterThan(side.red, corner.red)
        for sample in [center, side, corner] {
            XCTAssertEqual(sample.red / sample.green, 2, accuracy: 0.002)
            XCTAssertEqual(sample.green / sample.blue, 2, accuracy: 0.002)
            XCTAssertEqual(sample.alpha, 1, accuracy: 0.0001)
        }
        XCTAssertGreaterThan(corner.red, 0.2, "maximum vignette should remain gentle")
    }

    func testGrainIsDeterministicLowAmplitudeHuePreservingAndShadowDamped() throws {
        let source = image(width: 96, height: 48) { _, y in
            if y < 16 { return (0.001, 0.0005, 0.00025, 1) }
            if y < 32 { return (0.4, 0.2, 0.1, 1) }
            return (2.0, 1.0, 0.5, 1)
        }
        let settings = CreativeEffectsSettings(grain: 1)
        let first = try render(CreativeEffectsEngine.apply(settings, to: source, context: context))
        let second = try render(CreativeEffectsEngine.apply(settings, to: source, context: context))
        XCTAssertEqual(first, second, "the same coordinates and recipe must produce the same grain")

        var mean = 0.0
        var squared = 0.0
        var count = 0
        var maximumRelativeChange = 0.0
        for y in 16..<32 {
            for x in 0..<96 {
                let sample = pixel(first, width: 96, x: x, y: y)
                mean += Double(sample.red)
                squared += Double(sample.red * sample.red)
                count += 1
                maximumRelativeChange = max(maximumRelativeChange,
                    abs(Double(sample.red) - 0.4) / 0.4)
                XCTAssertEqual(sample.red / sample.green, 2, accuracy: 0.002)
                XCTAssertEqual(sample.green / sample.blue, 2, accuracy: 0.002)
            }
        }
        mean /= Double(count)
        let deviation = sqrt(max(0, squared / Double(count) - mean * mean))
        XCTAssertEqual(mean, 0.4, accuracy: 0.001,
                       "zero-mean grain should not shift the image brightness")
        XCTAssertGreaterThan(deviation, 0.0001)
        XCTAssertLessThan(maximumRelativeChange, 0.031)

        for y in 0..<16 {
            for x in 0..<96 {
                let sample = pixel(first, width: 96, x: x, y: y)
                XCTAssertEqual(sample.red, 0.001, accuracy: 0.000001)
            }
        }
    }

    func testGrainStatisticsStayComparableAcrossImageScales() throws {
        let small = solidImage(0.3, 0.3, 0.3, width: 64, height: 64)
        let large = solidImage(0.3, 0.3, 0.3, width: 128, height: 128)
        let settings = CreativeEffectsSettings(grain: 0.8)
        let smallPixels = try render(CreativeEffectsEngine.apply(settings, to: small, context: context))
        let largePixels = try render(CreativeEffectsEngine.apply(settings, to: large, context: context))
        let smallDeviation = standardDeviation(smallPixels, width: 64, xRange: 8..<56, yRange: 8..<56)
        let largeDeviation = standardDeviation(largePixels, width: 128, xRange: 16..<112, yRange: 16..<112)
        XCTAssertGreaterThan(smallDeviation, 0)
        XCTAssertGreaterThan(largeDeviation, 0)
        XCTAssertLessThan(abs(smallDeviation - largeDeviation), max(smallDeviation, largeDeviation) * 0.5)
    }

    func testRenderedROIMatchesTheSameCropFromTheFullGraph() throws {
        let source = image(width: 96, height: 64, origin: CGPoint(x: -17, y: 23)) { x, y in
            if (37...52).contains(x) && (24...39).contains(y) { return (2.5, 1.4, 0.8, 1) }
            return (0.12 + Float(x) * 0.0005,
                    0.08 + Float(y) * 0.0004,
                    0.05 + Float(x + y) * 0.0002, 0.7)
        }
        let effects = CreativeEffectsSettings(bloom: 0.9, vignette: 0.8, grain: 0.7)
        let output = try CreativeEffectsEngine.apply(effects, to: source, context: context)
        let fullBounds = output.extent.integral
        let fullPixels = try render(output, bounds: fullBounds)
        // Symmetric margins make the row/column offsets identical for either
        // bitmap row-origin convention, while still testing a true interior ROI.
        let roi = CGRect(x: -17 + 19, y: 23 + 14, width: 58, height: 36)
        let roiPixels = try render(output.cropped(to: roi), bounds: roi)
        let fullWidth = Int(fullBounds.width)
        let roiWidth = Int(roi.width), roiHeight = Int(roi.height)
        let xOffset = Int(roi.minX - fullBounds.minX)
        let yOffset = Int(roi.minY - fullBounds.minY)
        for y in 0..<roiHeight {
            for x in 0..<roiWidth {
                let fullOffset = ((y + yOffset) * fullWidth + x + xOffset) * 4
                let roiOffset = (y * roiWidth + x) * 4
                for channel in 0..<4 {
                    XCTAssertEqual(fullPixels[fullOffset + channel], roiPixels[roiOffset + channel],
                                   accuracy: 2.0 / 255.0)
                }
            }
        }
    }

    private func solidImage(_ red: Float, _ green: Float, _ blue: Float,
                            alpha: Float = 1, width: Int, height: Int,
                            origin: CGPoint = .zero) -> CIImage {
        image(width: width, height: height, origin: origin) { _, _ in
            (red, green, blue, alpha)
        }
    }

    private func image(width: Int, height: Int, origin: CGPoint = .zero,
                       pixel: (Int, Int) -> RGBA) -> CIImage {
        var components = [Float]()
        components.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let sample = pixel(x, y)
                // CIImage(bitmapData:) consumes premultiplied input samples.
                components.append(sample.red * sample.alpha)
                components.append(sample.green * sample.alpha)
                components.append(sample.blue * sample.alpha)
                components.append(sample.alpha)
            }
        }
        let data = components.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        let base = CIImage(bitmapData: data,
                           bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                           size: CGSize(width: width, height: height),
                           format: .RGBAf, colorSpace: linear)
        return origin == .zero ? base : base.transformed(
            by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    private func render(_ image: CIImage, bounds: CGRect? = nil) throws -> [Float] {
        let renderBounds = bounds ?? image.extent.integral
        let width = Int(renderBounds.width), height = Int(renderBounds.height)
        guard width > 0, height > 0 else { throw TestImageError.emptyExtent }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!,
                           rowBytes: width * 4 * MemoryLayout<Float>.stride,
                           bounds: renderBounds, format: .RGBAf, colorSpace: linear)
        }
        return pixels
    }

    private func pixel(_ pixels: [Float], width: Int, x: Int, y: Int) -> RGBA {
        let offset = (y * width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }

    private func standardDeviation(_ pixels: [Float], width: Int,
                                   xRange: Range<Int>, yRange: Range<Int>) -> Double {
        var sum = 0.0
        var squareSum = 0.0
        var count = 0
        for y in yRange {
            for x in xRange {
                let red = Double(pixels[(y * width + x) * 4])
                sum += red
                squareSum += red * red
                count += 1
            }
        }
        let mean = sum / Double(count)
        return sqrt(max(0, squareSum / Double(count) - mean * mean))
    }

    private enum TestImageError: Error {
        case emptyExtent
    }
}

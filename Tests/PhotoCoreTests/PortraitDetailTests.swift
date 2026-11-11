import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class PortraitDetailTests: XCTestCase {
    private typealias RGBA = (r: Float, g: Float, b: Float, a: Float)

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: true,
        .cacheIntermediates: false
    ])

    func testNeutralDetailIsPixelExactAndKeepsAlphaAndTranslatedExtent() throws {
        let extent = CGRect(x: 37, y: -19, width: 6, height: 1)
        let samples: [RGBA] = [
            (0.0, 0.0, 0.0, 0), (0.04, 0.12, 0.28, 0.25),
            (0.18, 0.18, 0.18, 0.5), (0.8, 0.3, 0.1, 1),
            (1.2, 0.22, 0.08, 1), (0.3, 0.7, 0.2, 0.65)
        ]
        let source = image(width: samples.count, height: 1, origin: extent.origin) { x, _ in samples[x] }

        let output = try LocalDetailEngine.apply(source, settings: LocalDetailSettings())

        XCTAssertEqual(output.extent, extent)
        XCTAssertEqual(try render(output), try render(source), "neutral detail processing must be an exact pixel identity")
        XCTAssertTrue(LocalDetailSettings().isNeutral)
    }

    func testMultiscaleSmoothingReducesMidFrequencyVariationAndRetainsFineTexture() throws {
        let width = 96, height = 96
        let source = image(width: width, height: height) { x, y in
            let mid = 0.36 + 0.065 * sin(2 * Double.pi * Double(x) / 12)
                + 0.05 * cos(2 * Double.pi * Double(y) / 12)
            let fine: Double = (x + y).isMultiple(of: 2) ? 0.02 : -0.02
            let value = Float(mid + fine)
            return (value, value, value, 1)
        }
        let settings = LocalDetailSettings(smoothing: 0.75, textureRetention: 0.95, toneUniformity: 0.1)
        let output = try LocalDetailEngine.apply(source, settings: settings)
        let before = try renderLuminance(source)
        let after = try renderLuminance(output)
        let beforeMidVariation = tileMeanDeviation(before, width: width, height: height, tile: 8)
        let afterMidVariation = tileMeanDeviation(after, width: width, height: height, tile: 8)
        let beforeFineEnergy = alternatingPairEnergy(before, width: width, height: height)
        let afterFineEnergy = alternatingPairEnergy(after, width: width, height: height)

        XCTAssertLessThan(afterMidVariation, beforeMidVariation * 0.85,
                          "smoothing should reduce the broad unevenness across neighboring tiles")
        XCTAssertGreaterThan(afterFineEnergy, beforeFineEnergy * 0.5,
                             "texture retention should keep a substantial share of the fine checker detail")
        let maximumChange = zip(before, after).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maximumChange, 0.15, "detail shaping should not make a large per-pixel brightness jump")
    }

    func testStrongDetailProcessingDoesNotCreateEdgeHalosOrOutOfRangeColor() throws {
        let width = 80, height = 32
        let source = image(width: width, height: height) { x, _ in
            if x < 40 { return (0.24, 0.12, 0.08, 1) }
            return (0.72, 0.42, 0.24, 1)
        }
        let output = try LocalDetailEngine.apply(
            source, settings: LocalDetailSettings(smoothing: 0.9, textureRetention: 0.85, toneUniformity: 0.35))
        let before = try render(source)
        let after = try render(output)
        var previousColumn = [Double](repeating: 0, count: 3)
        var largestLuminanceChange = 0.0
        for x in 0..<width {
            var currentColumn = [Double](repeating: 0, count: 3)
            for y in 0..<height {
                let index = (y * width + x) * 4
                let beforeLuma = 0.2126 * Double(before[index])
                    + 0.7152 * Double(before[index + 1]) + 0.0722 * Double(before[index + 2])
                let afterLuma = 0.2126 * Double(after[index])
                    + 0.7152 * Double(after[index + 1]) + 0.0722 * Double(after[index + 2])
                largestLuminanceChange = max(largestLuminanceChange, abs(afterLuma - beforeLuma))
                let beforeMaximum = max(before[index], max(before[index + 1], before[index + 2]))
                let beforeMinimum = min(before[index], min(before[index + 1], before[index + 2]))
                let afterMaximum = max(after[index], max(after[index + 1], after[index + 2]))
                let afterMinimum = min(after[index], min(after[index + 1], after[index + 2]))
                let beforeSaturation = Double(beforeMaximum - beforeMinimum) / max(0.0001, Double(beforeMaximum))
                let afterSaturation = Double(afterMaximum - afterMinimum) / max(0.0001, Double(afterMaximum))
                XCTAssertLessThanOrEqual(afterSaturation, beforeSaturation + 0.08,
                                         "detail refinement must not add conspicuous saturation")
                for channel in 0..<3 {
                    let adjusted = Double(after[index + channel])
                    XCTAssertGreaterThanOrEqual(adjusted, -0.01)
                    XCTAssertLessThanOrEqual(adjusted, 0.90,
                                             "the local detail pass must leave headroom below channel clipping")
                    currentColumn[channel] += adjusted / Double(height)
                    XCTAssertTrue(adjusted.isFinite)
                }
            }
            if x > 0 {
                for channel in 0..<3 {
                    XCTAssertGreaterThanOrEqual(currentColumn[channel] + 0.015, previousColumn[channel],
                                                "a monotone edge should not develop a bright/dark halo")
                }
            }
            previousColumn = currentColumn
        }
        XCTAssertLessThan(largestLuminanceChange, 0.15,
                          "a local detail pass should keep the per-pixel brightness change bounded")
        XCTAssertEqual(output.extent, source.extent)
    }

    func testToneUniformityPreservesMeanLuminanceAlphaTransparencyAndExtendedValues() throws {
        let width = 12, height = 8
        let extentOrigin = CGPoint(x: -23, y: 41)
        let source = image(width: width, height: height, origin: extentOrigin) { x, y in
            let alpha: Float = x < 3 ? 0 : (x < 6 ? 0.35 : 1)
            if x >= 9 { return (1.25, 0.36, 0.12, alpha) }
            let value = Float(0.23 + 0.04 * sin(Double(y) * 0.7) + 0.015 * cos(Double(x) * 0.8))
            return (value, value * 0.9, value * 0.8, alpha)
        }
        let output = try LocalDetailEngine.apply(
            source, settings: LocalDetailSettings(smoothing: 0.25, textureRetention: 0.95, toneUniformity: 0.8))
        let before = try render(source)
        let after = try render(output)

        XCTAssertEqual(output.extent, source.extent)
        XCTAssertEqual(meanLuminance(before), meanLuminance(after), accuracy: 0.025)
        for index in stride(from: 0, to: before.count, by: 4) {
            XCTAssertEqual(after[index + 3], before[index + 3], accuracy: 0.005,
                           "local detail must preserve the source alpha plane")
            XCTAssertTrue(after[index].isFinite && after[index + 1].isFinite && after[index + 2].isFinite)
        }
        XCTAssertEqual(after[3], 0, accuracy: 0.001, "fully transparent pixels must stay transparent")
        let extendedPixel = ((height / 2) * width + 10) * 4
        XCTAssertGreaterThan(after[extendedPixel], 1.0,
                             "extended linear values should not be clipped to the sRGB display range")
    }

    func testDetailSettingsRejectNonFiniteAndOutOfRangeValues() {
        XCTAssertThrowsError(try LocalDetailEngine.validate(
            LocalDetailSettings(smoothing: .nan)))
        XCTAssertThrowsError(try LocalDetailEngine.validate(
            LocalDetailSettings(textureRetention: .infinity)))
        XCTAssertThrowsError(try LocalDetailEngine.validate(
            LocalDetailSettings(smoothing: 1.01)))
        XCTAssertThrowsError(try LocalDetailEngine.validate(
            LocalDetailSettings(toneUniformity: -0.01)))
    }

    func testLegacyLocalMaskWithoutDetailAndContentSelectionDecodesNil() throws {
        let maskData = try JSONEncoder().encode(LocalMask())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: maskData) as? [String: Any])
        object.removeValue(forKey: "detail")
        object.removeValue(forKey: "contentSelection")

        let decoded = try JSONDecoder().decode(
            LocalMask.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertNil(decoded.detail)
        XCTAssertNil(decoded.contentSelection)
    }

    func testRecipeSixRoundTripsPortraitSettingsAndVersionFiveCannotHideThem() throws {
        var mask = LocalMask(kind: .luminance, exposureEV: 0)
        mask.detail = LocalDetailSettings(smoothing: 0.45, textureRetention: 0.92, toneUniformity: 0.3)
        mask.contentSelection = .people
        var settings = AdjustmentSettings()
        settings.masks = [mask]
        var recipe = Recipe(adjustments: settings)
        recipe.version = 6

        let decoded = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(decoded, recipe)
        XCTAssertNoThrow(try decoded.validateVersion())

        recipe.version = 5
        XCTAssertThrowsError(try recipe.validateVersion(),
                             "non-neutral portrait detail or content selection must not be silently downgraded")
    }

    func testRecipeFiveWithoutNewMaskSettingsRemainsValid() throws {
        var recipe = Recipe()
        recipe.version = 5

        XCTAssertNoThrow(try recipe.validateVersion())
    }

    func testActualVisionDoesNotTurnAnEmptyFrameIntoBackground() throws {
        let engine = PhotoEngine()
        let source = solidImage(0.25, extent: CGRect(x: 19, y: -11, width: 192, height: 128))
        let result = try ContentSelectionAnalyzer.analyze(reference: source,
            targets: Set(ContentSelectionTarget.allCases), context: engine.context)
        XCTAssertNil(result.image(for: .people))
        XCTAssertNil(result.image(for: .background))
        XCTAssertNil(result.image(for: .faceSkin))
        XCTAssertNotEqual(result.report.personStatus, "available")
        XCTAssertNotEqual(result.report.faceStatus, "available")
    }

    func testContentAnalysisHonorsPreCancellationAndEmptyTargets() throws {
        let engine = PhotoEngine()
        let source = solidImage(0.3, extent: CGRect(x: 0, y: 0, width: 64, height: 64))
        let empty = try ContentSelectionAnalyzer.analyze(reference: source, targets: [], context: engine.context)
        XCTAssertTrue(empty.masks.isEmpty)
        XCTAssertEqual(empty.report.personStatus, "notRequested")
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try ContentSelectionAnalyzer.analyze(reference: source,
            targets: [.people], context: engine.context, cancellation: token))
    }

    func testAlignedMaskStaysOpaqueAndComplementaryOnOneFractionalReferenceGrid() throws {
        let extent = CGRect(x: 13.25, y: -7.5, width: 1439.99999999999, height: 960.00000000001)
        let sourceMask = solidImage(0.7, extent: CGRect(x: 7, y: 3, width: 512, height: 341))
        let reference = solidImage(0.25, extent: extent)
        let engine = PhotoEngine()
        let people = ContentSelectionAnalyzer.alignedMask(sourceMask, extent: extent, inverted: false)
        let background = ContentSelectionAnalyzer.alignedMask(people, extent: extent, inverted: true)
        let p = try ContentSelectionAnalyzer.measure(people, over: reference, context: engine.context)
        let b = try ContentSelectionAnalyzer.measure(background, over: reference, context: engine.context)
        XCTAssertEqual(p.coverage, 0.7, accuracy: 0.003)
        XCTAssertEqual(b.coverage, 0.3, accuracy: 0.003)
        XCTAssertEqual(p.coverage + b.coverage, 1, accuracy: 0.003)
        for image in [people, background] {
            let rendered = try render(image.cropped(to: CGRect(x: 100, y: 100, width: 2, height: 2)))
            for i in stride(from: 3, to: rendered.count, by: 4) { XCTAssertEqual(rendered[i], 1, accuracy: 0.001) }
        }
    }

    func testInjectedPeopleAndBackgroundCoverageRemainDistinctAtTranslatedExtent() throws {
        let extent = CGRect(x: 27, y: -13, width: 48, height: 32)
        let peopleMask = coverageImage(width: 48, height: 32, origin: extent.origin) { x, y in
            (8..<24).contains(x) && (8..<24).contains(y)
        }
        let backgroundMask = coverageImage(width: 48, height: 32, origin: extent.origin) { x, y in
            !((8..<24).contains(x) && (8..<24).contains(y))
        }
        let result = ContentSelectionResult(
            report: .init(), masks: [.people: peopleMask, .background: backgroundMask])
        let reference = solidImage(0.3, extent: extent)
        let engine = PhotoEngine()
        let people = try engine.localMaskImage(
            LocalMask(kind: .luminance, exposureEV: 0, contentSelection: .people),
            reference: reference, contentSelections: result)
        let background = try engine.localMaskImage(
            LocalMask(kind: .luminance, exposureEV: 0, contentSelection: .background),
            reference: reference, contentSelections: result)

        XCTAssertEqual(people.extent, extent)
        XCTAssertEqual(background.extent, extent)
        XCTAssertGreaterThan(try pixel(people, x: 39, y: 1), 0.95)
        XCTAssertLessThan(try pixel(people, x: 67, y: 1), 0.05)
        XCTAssertLessThan(try pixel(background, x: 39, y: 1), 0.05)
        XCTAssertGreaterThan(try pixel(background, x: 67, y: 1), 0.95)
    }

    func testUnavailablePeopleSelectionFailsClosedBeforeInversionAndAddedGeometry() throws {
        let extent = CGRect(x: -9, y: 17, width: 40, height: 28)
        let unrelated = coverageImage(width: 40, height: 28, origin: extent.origin) { _, _ in true }
        let result = ContentSelectionResult(report: .init(), masks: [.background: unrelated])
        let mask = LocalMask(kind: .luminance, inverted: true, exposureEV: 0,
                             components: [MaskComponent(operation: .add, kind: .radial,
                                                        start: .init(x: 0.5, y: 0.5),
                                                        end: .init(x: 0.95, y: 0.95), feather: 0)],
                             contentSelection: .people)
        let reference = solidImage(0.25, extent: extent)
        let coverage = try PhotoEngine().localMaskImage(mask, reference: reference,
                                                        contentSelections: result)

        XCTAssertEqual(coverage.extent, extent)
        XCTAssertEqual(try pixel(coverage, x: 10, y: 30), 0, accuracy: 0.001,
                       "an unavailable target must stay empty even when inverted and geometry is added")
    }

    func testInjectedSelectionWithMismatchedExtentIsRejected() {
        let extent = CGRect(x: 0, y: 0, width: 24, height: 20)
        let wrongExtent = CGRect(x: 2, y: 0, width: 24, height: 20)
        let selection = coverageImage(width: 24, height: 20, origin: wrongExtent.origin) { _, _ in true }
        let result = ContentSelectionResult(report: .init(), masks: [.faceSkin: selection])
        let mask = LocalMask(kind: .luminance, exposureEV: 0, contentSelection: .faceSkin)

        XCTAssertThrowsError(try PhotoEngine().localMaskImage(
            mask, reference: solidImage(0.3, extent: extent), contentSelections: result))
    }

    private func image(width: Int, height: Int, origin: CGPoint = .zero,
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
        let bitmap = CIImage(bitmapData: data,
                             bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                             size: CGSize(width: width, height: height),
                             format: .RGBAf,
                             colorSpace: linearColorSpace)
        return bitmap.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    private func render(_ image: CIImage) throws -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: image.extent, format: .RGBAf, colorSpace: linearColorSpace)
        }
        return pixels
    }

    private func renderLuminance(_ image: CIImage) throws -> [Double] {
        let rgba = try render(image)
        return stride(from: 0, to: rgba.count, by: 4).map { index in
            0.2126 * Double(rgba[index]) + 0.7152 * Double(rgba[index + 1])
                + 0.0722 * Double(rgba[index + 2])
        }
    }

    private func coverageImage(width: Int, height: Int, origin: CGPoint = .zero,
                               selected: (Int, Int) -> Bool) -> CIImage {
        var values = [Float]()
        values.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: Float = selected(x, y) ? 1 : 0
                values.append(value); values.append(value); values.append(value); values.append(1)
            }
        }
        let data = values.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        return CIImage(bitmapData: data,
                       bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                       size: CGSize(width: width, height: height), format: .RGBAf,
                       colorSpace: linearColorSpace)
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    private func solidImage(_ value: Double, extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value, alpha: 1,
                               colorSpace: linearColorSpace)!).cropped(to: extent)
    }

    private func pixel(_ image: CIImage, x: Int, y: Int) throws -> Float {
        var value = [Float](repeating: 0, count: 4)
        value.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBAf, colorSpace: linearColorSpace)
        }
        return value[0]
    }

    private func tileMeanDeviation(_ values: [Double], width: Int, height: Int, tile: Int) -> Double {
        var means = [Double]()
        for originY in stride(from: 4, to: height - tile, by: tile) {
            for originX in stride(from: 4, to: width - tile, by: tile) {
                var sum = 0.0
                for y in originY..<originY + tile {
                    for x in originX..<originX + tile { sum += values[y * width + x] }
                }
                means.append(sum / Double(tile * tile))
            }
        }
        let mean = means.reduce(0, +) / Double(means.count)
        return sqrt(means.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(means.count))
    }

    private func alternatingPairEnergy(_ values: [Double], width: Int, height: Int) -> Double {
        var differences = [Double]()
        for y in 4..<height - 4 {
            for x in stride(from: 4, to: width - 4, by: 2) {
                differences.append(abs(values[y * width + x] - values[y * width + x + 1]))
            }
        }
        return differences.reduce(0, +) / Double(differences.count)
    }

    private func meanLuminance(_ pixels: [Float]) -> Double {
        let values = stride(from: 0, to: pixels.count, by: 4).map { index in
            0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1])
                + 0.0722 * Double(pixels[index + 2])
        }
        return values.reduce(0, +) / Double(values.count)
    }
}

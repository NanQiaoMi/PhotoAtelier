import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class RegionDetailSamplingTests: XCTestCase {
    private typealias RGBA = (r: Float, g: Float, b: Float, a: Float)

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: true,
        .cacheIntermediates: false
    ])

    func testMaskedSamplingIgnoresDifferentOutsideBackgroundsWhileLegacySamplingLeaksThem() throws {
        let width = 104, height = 88
        let origin = CGPoint(x: 13, y: -9)
        let selectedX = 24..<80
        let selectedY = 16..<72
        func isSelected(_ x: Int, _ y: Int) -> Bool {
            selectedX.contains(x) && selectedY.contains(y)
        }
        func subjectValue(_ x: Int, _ y: Int) -> Float {
            let middle = 0.35 + 0.08 * sin(2 * Double.pi * Double(x) / 20)
                + 0.06 * cos(2 * Double.pi * Double(y) / 24)
            return Float(middle)
        }
        func source(outside value: Float) -> CIImage {
            image(width: width, height: height, origin: origin) { x, y in
                let sample = isSelected(x, y) ? subjectValue(x, y) : value
                return (sample, sample, sample, 1)
            }
        }

        let darkBackground = source(outside: 0.05)
        let brightBackground = source(outside: 0.88)
        let coverage = coverageImage(width: width, height: height, origin: origin) { x, y in
            isSelected(x, y) ? 1 : 0
        }
        let plan = try LocalDetailSamplingPlan.measure(
            coverage: coverage, reference: darkBackground, context: context)
        let settings = LocalDetailSettings(smoothing: 1, textureRetention: 0.4)

        let isolatedDark = try LocalDetailEngine.apply(
            darkBackground, settings: settings, samplingMask: coverage, samplingPlan: plan)
        let isolatedBright = try LocalDetailEngine.apply(
            brightBackground, settings: settings, samplingMask: coverage, samplingPlan: plan)
        let legacyDark = try LocalDetailEngine.apply(
            darkBackground, settings: settings, samplingPlan: plan)
        let legacyBright = try LocalDetailEngine.apply(
            brightBackground, settings: settings, samplingPlan: plan)

        let originalPixels = try render(darkBackground)
        let isolatedDarkPixels = try render(isolatedDark)
        let isolatedBrightPixels = try render(isolatedBright)
        let legacyDarkPixels = try render(legacyDark)
        let legacyBrightPixels = try render(legacyBright)

        let isolatedDifference = maximumChannelDifference(
            isolatedDarkPixels, isolatedBrightPixels, width: width, height: height,
            including: isSelected)
        XCTAssertLessThan(isolatedDifference, 0.001,
                          "selected output must not inherit colors from outside its sampling mask")

        let boundaryContamination = meanLuminanceDifference(
            legacyDarkPixels, legacyBrightPixels, width: width, height: height) { x, y in
                guard isSelected(x, y) else { return false }
                return x < selectedX.lowerBound + 8 || x >= selectedX.upperBound - 8
                    || y < selectedY.lowerBound + 8 || y >= selectedY.upperBound - 8
            }
        XCTAssertGreaterThan(boundaryContamination, 0.002,
                             "the unmasked legacy path should expose measurable outside-background leakage")

        let selectedChange = maximumLuminanceDifference(
            originalPixels, isolatedDarkPixels, width: width, height: height, including: isSelected)
        XCTAssertGreaterThan(selectedChange, 0.001,
                             "the isolation assertion must exercise an actual detail adjustment")
        print("REGION_ISOLATION selectedMaxRGB=\(isolatedDifference) legacyBoundaryMeanLuma=\(boundaryContamination) activeMaxLuma=\(selectedChange)")
    }

    func testSamplingPlanSmoothsMidFrequencyVariationAndRetainsFineTexture() throws {
        let width = 128, height = 128
        let source = image(width: width, height: height) { x, y in
            let middle = 0.36 + 0.075 * sin(2 * Double.pi * Double(x) / 24)
                + 0.055 * cos(2 * Double.pi * Double(y) / 28)
            let fine: Double = (x + y).isMultiple(of: 2) ? 0.012 : -0.012
            let value = Float(middle + fine)
            return (value, value, value, 1)
        }
        let fullCoverage = coverageImage(width: width, height: height) { _, _ in 1 }
        let plan = try LocalDetailSamplingPlan.measure(
            coverage: fullCoverage, reference: source, context: context)
        let output = try LocalDetailEngine.apply(
            source,
            settings: LocalDetailSettings(smoothing: 1, textureRetention: 0.95),
            samplingPlan: plan)

        let before = try render(source)
        let after = try render(output)
        let beforeMiddleVariation = tileMeanDeviation(before, width: width, height: height, tile: 12)
        let afterMiddleVariation = tileMeanDeviation(after, width: width, height: height, tile: 12)
        let beforeFineEnergy = alternatingPairEnergy(before, width: width, height: height)
        let afterFineEnergy = alternatingPairEnergy(after, width: width, height: height)

        XCTAssertLessThan(afterMiddleVariation, beforeMiddleVariation * 0.85,
                          "the measured coarse scale should reduce broad, coherent variation")
        XCTAssertGreaterThan(afterFineEnergy, beforeFineEnergy * 0.6,
                             "high-frequency texture should retain a substantial part of its input energy")
        print("REGION_FREQUENCIES middleRatio=\(afterMiddleVariation / beforeMiddleVariation) fineRatio=\(afterFineEnergy / beforeFineEnergy)")
    }

    func testNoiseSamplingAlsoIgnoresOutsideColorsAndActuallyChangesSelectedNoise() throws {
        let width = 32, height = 28
        func selected(_ x: Int, _ y: Int) -> Bool { (6..<26).contains(x) && (6..<22).contains(y) }
        func source(outside: Float) -> CIImage {
            image(width: width, height: height) { x, y in
                let noise: Float = (x + y).isMultiple(of: 2) ? 0.018 : -0.018
                let value: Float = selected(x, y) ? 0.32 + noise : outside
                return (value, value, value, 1)
            }
        }
        let a = source(outside: 0.25), b = source(outside: 0.4)
        let mask = coverageImage(width: width, height: height) { x, y in selected(x, y) ? 1 : 0 }
        let settings = LocalDetailSettings(noiseReduction: 1, detailRecovery: 0.3)
        let isolatedA = try render(LocalDetailEngine.apply(a, settings: settings,
            noiseEstimate: 0.06, samplingMask: mask))
        let isolatedB = try render(LocalDetailEngine.apply(b, settings: settings,
            noiseEstimate: 0.06, samplingMask: mask))
        let legacyA = try render(LocalDetailEngine.apply(a, settings: settings, noiseEstimate: 0.06))
        let legacyB = try render(LocalDetailEngine.apply(b, settings: settings, noiseEstimate: 0.06))
        let isolatedDifference = maximumChannelDifference(isolatedA, isolatedB, width: width,
            height: height, including: selected)
        let legacyDifference = maximumChannelDifference(legacyA, legacyB, width: width,
            height: height, including: selected)
        let activeChange = maximumLuminanceDifference(try render(a), isolatedA, width: width,
            height: height, including: selected)
        XCTAssertLessThan(isolatedDifference, 0.00001)
        XCTAssertGreaterThan(legacyDifference, 0.0005)
        XCTAssertGreaterThan(activeChange, 0.001)
        print("REGION_NOISE isolatedMaxRGB=\(isolatedDifference) legacyMaxRGB=\(legacyDifference) activeMaxLuma=\(activeChange)")
    }

    func testIsolatedToneUniformityCanAdjustChromaWithoutChangingFlatLuminance() throws {
        let width = 64, height = 48
        let source = image(width: width, height: height) { x, _ in
            let chroma = Float(0.014 * sin(2 * Double.pi * Double(x) / 5))
            return (0.32 + chroma, 0.32 - chroma * 0.2126 / 0.7152, 0.32, 1)
        }
        let mask = coverageImage(width: width, height: height) { _, _ in 1 }
        let plan = try LocalDetailSamplingPlan.measure(coverage: mask, reference: source, context: context)
        let output = try LocalDetailEngine.apply(source, settings: LocalDetailSettings(toneUniformity: 0.7),
            samplingMask: mask, samplingPlan: plan)
        let before = try render(source), after = try render(output)
        XCTAssertGreaterThan(maximumChannelDifference(before, after, width: width, height: height,
            including: { _, _ in true }), 0.0001)
        XCTAssertLessThan(maximumLuminanceDifference(before, after, width: width, height: height,
            including: { _, _ in true }), 0.00001)
    }

    func testSamplingScaleDoesNotChangeWhenCoverageOpacityIsScaled() throws {
        let width = 64, height = 48
        let source = solidImage(0.32, width: width, height: height, origin: .zero)
        func selected(_ x: Int, _ y: Int) -> Bool {
            (11..<29).contains(x) && (9..<27).contains(y)
        }
        let opaqueCoverage = coverageImage(width: width, height: height) { x, y in
            selected(x, y) ? 1 : 0
        }
        let lowOpacityCoverage = coverageImage(width: width, height: height) { x, y in
            selected(x, y) ? 0.2 : 0
        }

        let opaquePlan = try LocalDetailSamplingPlan.measure(
            coverage: opaqueCoverage, reference: source, context: context)
        let lowOpacityPlan = try LocalDetailSamplingPlan.measure(
            coverage: lowOpacityCoverage, reference: source, context: context)

        XCTAssertEqual(opaquePlan.effectiveAreaPixels, Double(18 * 18), accuracy: 0.1)
        XCTAssertEqual(lowOpacityPlan.effectiveAreaPixels, opaquePlan.effectiveAreaPixels, accuracy: 0.1,
                       "mask opacity changes strength, not the number of selected source pixels")
        XCTAssertEqual(lowOpacityPlan.fineRadius, opaquePlan.fineRadius, accuracy: 0.0001)
        XCTAssertEqual(lowOpacityPlan.coarseRadius, opaquePlan.coarseRadius, accuracy: 0.0001)
    }

    func testMaskedCandidatePreservesAlphaTranslatedExtentAndExtendedSignedPixelsOutsideCoverage() throws {
        let width = 20, height = 16
        let origin = CGPoint(x: 37, y: -19)
        let source = image(width: width, height: height, origin: origin) { x, y in
            if x == 12 { return (1.35, 0.38, 0.16, 1) }
            if x == 13 { return (-0.12, 0.08, 0.2, 1) }
            if x >= 12 { return (0.62, 0.54, 0.47, 1) }

            let code = (x * 31 + y * 17 + x * y * 7) % 31
            let value = Float(0.30 + (Double(code) / 30 - 0.5) * 0.14)
            let alpha: Float = x == 0 ? 0 : (x == 1 ? 0.35 : 1)
            return (value, value * 0.92, value * 0.84, alpha)
        }
        let coverage = coverageImage(width: width, height: height, origin: origin) { x, _ in
            x < 12 ? 1 : 0
        }
        let plan = try LocalDetailSamplingPlan.measure(
            coverage: coverage, reference: source, context: context)
        let output = try LocalDetailEngine.apply(
            source,
            settings: LocalDetailSettings(noiseReduction: 1, detailRecovery: 0.8),
            noiseEstimate: 0.12,
            samplingMask: coverage,
            samplingPlan: plan)

        XCTAssertEqual(output.extent, source.extent)
        let before = try render(source)
        let after = try render(output)
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            XCTAssertEqual(after[offset + 3], before[offset + 3], accuracy: 0.0001,
                           "detail processing must preserve the source alpha plane")
        }
        XCTAssertEqual(before[3], 0, accuracy: 0.0001)
        XCTAssertEqual(after[3], 0, accuracy: 0.0001)

        let hdrOffset = 12 * 4
        let negativeOffset = 13 * 4
        XCTAssertGreaterThan(before[hdrOffset], 1)
        XCTAssertLessThan(before[negativeOffset], 0)
        for y in 0..<height {
            for x in 12..<width {
                let offset = (y * width + x) * 4
                for channel in 0..<4 {
                    XCTAssertEqual(after[offset + channel], before[offset + channel], accuracy: 0.00001,
                                   "zero-coverage candidate pixels, including HDR and negative values, must stay unchanged")
                }
            }
        }

        let selectedChange = maximumLuminanceDifference(
            before, after, width: width, height: height) { x, _ in x < 12 }
        XCTAssertGreaterThan(selectedChange, 0.001,
                             "alpha and off-mask checks must accompany a non-no-op selected adjustment")
    }

    func testSamplingMaskStaysAlignedForScaledSourceGraphsAtTranslatedExtents() throws {
        let width = 28, height = 24
        let source = image(width: width, height: height) { x, y in
            let code = (x * 37 + y * 23 + x * y * 11) % 29
            let value = Float(0.31 + (Double(code) / 28 - 0.5) * 0.16)
            return (value, value * 0.94, value * 0.88, 1)
        }
        let coverage = coverageImage(width: width, height: height) { x, y in
            (8..<20).contains(x) && (6..<18).contains(y) ? 1 : 0
        }
        let transform = CGAffineTransform(a: 1.5, b: 0, c: 0, d: 1.5, tx: 43, ty: -21)
        let scaledSource = source.transformed(by: transform)
        let scaledCoverage = coverage.transformed(by: transform)
        XCTAssertEqual(scaledSource.extent, scaledCoverage.extent)

        let plan = try LocalDetailSamplingPlan.measure(
            coverage: scaledCoverage, reference: scaledSource, context: context)
        let output = try LocalDetailEngine.apply(
            scaledSource,
            settings: LocalDetailSettings(noiseReduction: 1, detailRecovery: 0.8),
            noiseEstimate: 0.12,
            samplingMask: scaledCoverage,
            samplingPlan: plan)
        let sourcePixels = try render(scaledSource)
        let coveragePixels = try render(scaledCoverage)
        let outputPixels = try render(output)
        let outputWidth = Int(scaledSource.extent.width)
        let outputHeight = Int(scaledSource.extent.height)
        var maximumSelectedChange = 0.0
        for y in 0..<outputHeight {
            for x in 0..<outputWidth {
                let offset = (y * outputWidth + x) * 4
                if coveragePixels[offset] <= 0.001 {
                    for channel in 0..<4 {
                        XCTAssertEqual(outputPixels[offset + channel], sourcePixels[offset + channel],
                                       accuracy: 0.00001,
                                       "a transformed zero-coverage pixel must remain the original pixel")
                    }
                } else {
                    maximumSelectedChange = max(maximumSelectedChange,
                        abs(luminance(outputPixels, at: offset) - luminance(sourcePixels, at: offset)))
                }
            }
        }
        XCTAssertGreaterThan(maximumSelectedChange, 0.001,
                             "the transformed selection must exercise the masked detail kernel")
    }

    func testMeasuredScaleAndOutputStayStableWhenTheSameSelectionIsEmbeddedInALargerCanvas() throws {
        let selectionSize = 128
        let largeSize = 256
        let offset = 64
        func subject(_ x: Int, _ y: Int) -> RGBA {
            let value = Float(0.37
                + 0.075 * sin(2 * Double.pi * Double(x) / 22)
                + 0.055 * cos(2 * Double.pi * Double(y) / 26))
            return (value, value, value, 1)
        }

        let smallSource = image(width: selectionSize, height: selectionSize) { x, y in subject(x, y) }
        let smallCoverage = coverageImage(width: selectionSize, height: selectionSize) { _, _ in 1 }
        let largeSource = image(width: largeSize, height: largeSize) { x, y in
            if (offset..<offset + selectionSize).contains(x),
               (offset..<offset + selectionSize).contains(y) {
                return subject(x - offset, y - offset)
            }
            return (0.82, 0.82, 0.82, 1)
        }
        let largeCoverage = coverageImage(width: largeSize, height: largeSize) { x, y in
            (offset..<offset + selectionSize).contains(x)
                && (offset..<offset + selectionSize).contains(y) ? 1 : 0
        }

        let smallPlan = try LocalDetailSamplingPlan.measure(
            coverage: smallCoverage, reference: smallSource, context: context)
        let largePlan = try LocalDetailSamplingPlan.measure(
            coverage: largeCoverage, reference: largeSource, context: context)
        XCTAssertEqual(largePlan.effectiveAreaPixels, smallPlan.effectiveAreaPixels, accuracy: 0.1)
        XCTAssertEqual(largePlan.fineRadius, smallPlan.fineRadius, accuracy: 0.0001)
        XCTAssertEqual(largePlan.coarseRadius, smallPlan.coarseRadius, accuracy: 0.0001)

        let settings = LocalDetailSettings(smoothing: 1, textureRetention: 0.5)
        let smallOutput = try LocalDetailEngine.apply(
            smallSource, settings: settings, samplingMask: smallCoverage, samplingPlan: smallPlan)
        let largeOutput = try LocalDetailEngine.apply(
            largeSource, settings: settings, samplingMask: largeCoverage, samplingPlan: largePlan)
        let smallPixels = try render(smallOutput)
        let largePixels = try render(largeOutput)
        let interiorDifference = maximumMappedChannelDifference(
            smallPixels, width: selectionSize,
            largePixels, width: largeSize,
            smallRegion: 32..<96, largeOffset: offset)

        XCTAssertLessThan(interiorDifference, 0.001,
                          "the same source-pixel selection must keep its scale when the frame grows")
    }

    func testLegacyLocalDetailPlanJSONDecodesWhenSamplingIsAbsent() throws {
        let measurements = LocalDetailMeasurements(
            sampleCount: 256,
            patchCount: 1,
            medianLuminance: 0.3,
            luminanceNoise: 0.002,
            chromaNoise: 0.001,
            textureFraction: 0.1,
            strongEdgeFraction: 0,
            nearBlackFraction: 0,
            nearWhiteFraction: 0,
            ambiguousFinePattern: false)
        let legacyPlan = AdaptiveLocalDetailAnalyzer.plan(
            measurements: measurements,
            maskID: UUID(),
            target: nil,
            adaptation: LocalDetailAdaptation(),
            sampling: nil)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyPlan))
                                 as? [String: Any])
        json.removeValue(forKey: "sampling")
        if var settings = json["settings"] as? [String: Any] {
            settings.removeValue(forKey: "noiseReduction")
            settings.removeValue(forKey: "detailRecovery")
            json["settings"] = settings
        }

        let decoded = try JSONDecoder().decode(
            LocalDetailPlan.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertEqual(decoded.policyVersion, 1)
        XCTAssertNil(decoded.sampling)
        XCTAssertEqual(decoded.settings.noiseReduction, 0)
        XCTAssertEqual(decoded.settings.detailRecovery, 0)
    }

    func testSamplingMeasureAndApplyRejectInvalidExtentsAndPlanAreas() throws {
        let source = solidImage(0.3, width: 12, height: 12, origin: .zero)
        let wrongOriginCoverage = coverageImage(
            width: 12, height: 12, origin: CGPoint(x: 1, y: 0)) { _, _ in 1 }
        XCTAssertThrowsError(try LocalDetailSamplingPlan.measure(
            coverage: wrongOriginCoverage, reference: source, context: context))

        let infiniteImage = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3))
        XCTAssertThrowsError(try LocalDetailSamplingPlan.measure(
            coverage: infiniteImage, reference: infiniteImage, context: context))
        XCTAssertThrowsError(try LocalDetailEngine.apply(
            infiniteImage, settings: LocalDetailSettings(smoothing: 0.5)))

        XCTAssertThrowsError(try LocalDetailEngine.apply(
            source,
            settings: LocalDetailSettings(smoothing: 0.5),
            samplingMask: wrongOriginCoverage))
        for area in [-1.0, 120_000_001.0] {
            let invalidPlan = LocalDetailSamplingPlan(effectiveAreaPixels: area)
            XCTAssertThrowsError(try LocalDetailEngine.apply(
                source,
                settings: LocalDetailSettings(smoothing: 0.5),
                samplingPlan: invalidPlan),
                "apply must validate the sampling area before building a processing graph")
        }
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

    private func coverageImage(width: Int, height: Int, origin: CGPoint = .zero,
                               coverage: (Int, Int) -> Float) -> CIImage {
        image(width: width, height: height, origin: origin) { x, y in
            let value = coverage(x, y)
            return (value, value, value, 1)
        }
    }

    private func solidImage(_ value: Double, width: Int, height: Int, origin: CGPoint) -> CIImage {
        image(width: width, height: height, origin: origin) { _, _ in
            let sample = Float(value)
            return (sample, sample, sample, 1)
        }
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

    private func luminance(_ pixels: [Float], at offset: Int) -> Double {
        0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1])
            + 0.0722 * Double(pixels[offset + 2])
    }

    private func maximumChannelDifference(_ lhs: [Float], _ rhs: [Float],
                                          width: Int, height: Int,
                                          including included: (Int, Int) -> Bool) -> Double {
        var maximum = 0.0
        for y in 0..<height {
            for x in 0..<width where included(x, y) {
                let offset = (y * width + x) * 4
                for channel in 0..<4 {
                    maximum = max(maximum, abs(Double(lhs[offset + channel] - rhs[offset + channel])))
                }
            }
        }
        return maximum
    }

    private func maximumLuminanceDifference(_ lhs: [Float], _ rhs: [Float],
                                            width: Int, height: Int,
                                            including included: (Int, Int) -> Bool) -> Double {
        var maximum = 0.0
        for y in 0..<height {
            for x in 0..<width where included(x, y) {
                let offset = (y * width + x) * 4
                maximum = max(maximum, abs(luminance(lhs, at: offset) - luminance(rhs, at: offset)))
            }
        }
        return maximum
    }

    private func meanLuminanceDifference(_ lhs: [Float], _ rhs: [Float],
                                         width: Int, height: Int,
                                         including included: (Int, Int) -> Bool) -> Double {
        var total = 0.0
        var count = 0
        for y in 0..<height {
            for x in 0..<width where included(x, y) {
                let offset = (y * width + x) * 4
                total += abs(luminance(lhs, at: offset) - luminance(rhs, at: offset))
                count += 1
            }
        }
        return total / Double(max(1, count))
    }

    private func tileMeanDeviation(_ pixels: [Float], width: Int, height: Int, tile: Int) -> Double {
        var means = [Double]()
        for originY in stride(from: 4, to: height - tile, by: tile) {
            for originX in stride(from: 4, to: width - tile, by: tile) {
                var sum = 0.0
                for y in originY..<originY + tile {
                    for x in originX..<originX + tile {
                        sum += luminance(pixels, at: (y * width + x) * 4)
                    }
                }
                means.append(sum / Double(tile * tile))
            }
        }
        let mean = means.reduce(0, +) / Double(means.count)
        return sqrt(means.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(means.count))
    }

    private func alternatingPairEnergy(_ pixels: [Float], width: Int, height: Int) -> Double {
        var total = 0.0
        var count = 0
        for y in 4..<height - 4 {
            for x in stride(from: 4, to: width - 4, by: 2) {
                let first = (y * width + x) * 4
                total += abs(luminance(pixels, at: first) - luminance(pixels, at: first + 4))
                count += 1
            }
        }
        return total / Double(max(1, count))
    }

    private func maximumMappedChannelDifference(_ small: [Float], width smallWidth: Int,
                                                _ large: [Float], width largeWidth: Int,
                                                smallRegion: Range<Int>, largeOffset: Int) -> Double {
        let largeHeight = large.count / (largeWidth * 4)
        var maximum = 0.0
        for smallY in smallRegion {
            for smallX in smallRegion {
                let largeX = smallX + largeOffset
                let largeY = smallY + largeOffset
                guard largeY < largeHeight else { continue }
                let smallIndex = (smallY * smallWidth + smallX) * 4
                let largeIndex = (largeY * largeWidth + largeX) * 4
                for channel in 0..<4 {
                    maximum = max(maximum,
                                  abs(Double(small[smallIndex + channel] - large[largeIndex + channel])))
                }
            }
        }
        return maximum
    }
}

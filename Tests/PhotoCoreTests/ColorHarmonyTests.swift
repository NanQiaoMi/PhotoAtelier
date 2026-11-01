import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class ColorHarmonyTests: XCTestCase {
    private let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: colorSpace,
        .outputColorSpace: colorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: false,
        .cacheIntermediates: false
    ])

    func testNeutralTintIsReducedWithoutChangingCandidateLightness() throws {
        let extent = CGRect(x: 13, y: -7, width: 64, height: 48)
        let reference = solid(0.20, 0.20, 0.20, extent: extent)
        let candidate = solid(0.28, 0.19, 0.15, extent: extent)
        let output = try protect(reference, candidate)
        let before = try pixel(candidate, x: 20, y: 5)
        let after = try pixel(output, x: 20, y: 5)
        let beforeLab = oklab(before), afterLab = oklab(after)

        XCTAssertLessThan(hypot(afterLab.1, afterLab.2), hypot(beforeLab.1, beforeLab.2) * 0.65,
                          "中性区域新增的 OKLab 色度应明显回落")
        XCTAssertEqual(luminance(after), luminance(before), accuracy: 0.002,
                       "保护应保留 candidate 的线性亮度")
        XCTAssertEqual(after[3], before[3], accuracy: 0.001)
        XCTAssertEqual(output.extent, extent)
    }

    func testExposureAndDesaturationAreNotPulledTowardReferenceColor() throws {
        let extent = CGRect(x: 0, y: 0, width: 40, height: 32)
        let warmReference = solid(0.20, 0.13, 0.075, extent: extent)
        let exposureOnly = solid(0.40, 0.26, 0.15, extent: extent)
        let exposureOutput = try protect(warmReference, exposureOnly)
        assertPixelEqual(try pixel(exposureOutput, x: 9, y: 9),
                         try pixel(exposureOnly, x: 9, y: 9), accuracy: 0.003)

        let saturatedReference = solid(0.46, 0.12, 0.055, extent: extent)
        let desaturatedCandidate = solid(0.29, 0.17, 0.13, extent: extent)
        let desaturatedOutput = try protect(saturatedReference, desaturatedCandidate)
        assertPixelEqual(try pixel(desaturatedOutput, x: 9, y: 9),
                         try pixel(desaturatedCandidate, x: 9, y: 9), accuracy: 0.003)
    }

    func testAbruptHueChangeAndChromaGrowthRiskIsReduced() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 48)
        let reference = solid(0.035, 0.32, 0.39, extent: extent)
        let candidate = solid(0.48, 0.055, 0.36, extent: extent)
        let output = try protect(reference, candidate)
        let beforeLab = oklab(try pixel(candidate, x: 16, y: 16))
        let afterLab = oklab(try pixel(output, x: 16, y: 16))
        let refLab = oklab(try pixel(reference, x: 16, y: 16))
        let beforeDelta = hypot(beforeLab.1 - refLab.1, beforeLab.2 - refLab.2)
        let afterDelta = hypot(afterLab.1 - refLab.1, afterLab.2 - refLab.2)
        let risk = try pixel(ColorHarmonyEngine.chromaRiskMask(reference: reference,
                                                               candidate: candidate,
                                                               context: context),
                             x: 16, y: 16)[0]

        XCTAssertLessThan(afterDelta, beforeDelta * 0.65,
                          "突兀色相与色度增长应向 global-only 基线回收")
        XCTAssertGreaterThan(risk, 0.5)
        XCTAssertEqual(luminance(try pixel(output, x: 16, y: 16)),
                       luminance(try pixel(candidate, x: 16, y: 16)), accuracy: 0.003)
    }

    func testReferenceEdgesReceiveStrongerProtectionThanFlatRegions() throws {
        let width = 96, height = 40
        var referencePixels = [Float](repeating: 1, count: width * height * 4)
        var candidatePixels = referencePixels
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let luminance: Float = x < width / 2 ? 0.18 : (x % 2 == 0 ? 0.75 : 0.28)
                referencePixels[index] = luminance
                referencePixels[index + 1] = luminance
                referencePixels[index + 2] = luminance
                let tint: Float = luminance < 0.3 ? 0.04 : 0.0
                candidatePixels[index] = luminance + tint
                candidatePixels[index + 1] = luminance - tint * 0.4
                candidatePixels[index + 2] = luminance - tint * 0.65
            }
        }
        let reference = bitmap(referencePixels, width: width, height: height)
        let candidate = bitmap(candidatePixels, width: width, height: height)
        var settings = ColorHarmonySettings()
        settings.detailProtection = 1
        let output = try ColorHarmonyEngine.protect(reference: reference, candidate: candidate,
                                                     settings: settings, scene: nil, context: context)
        let flatReference = try pixel(reference, x: 10, y: 20)
        let flatCandidate = try pixel(candidate, x: 10, y: 20)
        let flatAfter = try pixel(output, x: 10, y: 20)
        // Sample a dark pixel inside the checker texture, not the transition seam.
        let edgeReference = try pixel(reference, x: 71, y: 20)
        let edgeCandidate = try pixel(candidate, x: 71, y: 20)
        let edgeAfter = try pixel(output, x: 71, y: 20)
        let flatResidual = chromaResidual(reference: flatReference, candidate: flatCandidate,
                                          output: flatAfter)
        let edgeResidual = chromaResidual(reference: edgeReference, candidate: edgeCandidate,
                                          output: edgeAfter)

        XCTAssertGreaterThan(flatResidual, 0.01, "平坦中性区域应仍能测到候选染色")
        XCTAssertLessThan(edgeResidual, flatResidual * 0.8,
                          "纹理边缘的染色残差应低于平坦区域")
    }

    func testDisabledAndZeroAmountReturnTheExactCandidateObject() throws {
        let extent = CGRect(x: -5, y: 17, width: 31, height: 23)
        let reference = solid(0.2, 0.2, 0.2, extent: extent)
        let candidate = solid(0.3, 0.12, 0.18, extent: extent)
        var settings = ColorHarmonySettings()
        settings.enabled = false
        let disabled = try ColorHarmonyEngine.protect(reference: reference, candidate: candidate,
                                                       settings: settings, scene: nil, context: context)
        XCTAssertTrue(disabled === candidate)
        settings.enabled = true
        settings.amount = 0
        let zero = try ColorHarmonyEngine.protect(reference: reference, candidate: candidate,
                                                   settings: settings, scene: nil, context: context)
        XCTAssertTrue(zero === candidate)
    }

    func testTransparentAndPartiallyTransparentPixelsKeepAlphaAndExtent() throws {
        let extent = CGRect(x: -11, y: 19, width: 32, height: 24)
        var referencePixels = [Float](repeating: 0, count: 32 * 24 * 4)
        var candidatePixels = referencePixels
        for y in 0..<24 {
            for x in 0..<32 {
                let index = (y * 32 + x) * 4
                let alpha: Float = x < 8 ? 0 : (x < 16 ? 0.35 : 1)
                referencePixels[index] = 0.20 * alpha
                referencePixels[index + 1] = 0.20 * alpha
                referencePixels[index + 2] = 0.20 * alpha
                referencePixels[index + 3] = alpha
                candidatePixels[index] = 0.31 * alpha
                candidatePixels[index + 1] = 0.08 * alpha
                candidatePixels[index + 2] = 0.16 * alpha
                candidatePixels[index + 3] = alpha
            }
        }
        let reference = bitmap(referencePixels, width: 32, height: 24)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        let candidate = bitmap(candidatePixels, width: 32, height: 24)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        let output = try protect(reference, candidate)

        XCTAssertEqual(output.extent, extent)
        let transparent = try pixel(output, x: -7, y: 22)
        let partial = try pixel(output, x: 0, y: 22)
        XCTAssertEqual(transparent[3], 0, accuracy: 0.001)
        XCTAssertEqual(partial[3], 0.35, accuracy: 0.01)
        XCTAssertTrue(partial.allSatisfy { $0.isFinite })
    }

    func testNonFiniteSettingsAreRejected() {
        var settings = ColorHarmonySettings()
        settings.amount = .nan
        XCTAssertThrowsError(try ColorHarmonyEngine.validate(settings))
        settings.amount = 0.5
        settings.saturatedProtection = .infinity
        XCTAssertThrowsError(try ColorHarmonyEngine.validate(settings))
    }

    private func protect(_ reference: CIImage, _ candidate: CIImage,
                         settings: ColorHarmonySettings = .init()) throws -> CIImage {
        try ColorHarmonyEngine.protect(reference: reference, candidate: candidate,
                                       settings: settings, scene: nil, context: context)
    }

    private func solid(_ red: Double, _ green: Double, _ blue: Double,
                       alpha: Double = 1, extent: CGRect) -> CIImage {
        let color = CIColor(red: red, green: green, blue: blue, alpha: alpha,
                            colorSpace: colorSpace)!
        return CIImage(color: color).cropped(to: extent)
    }

    private func bitmap(_ pixels: [Float], width: Int, height: Int) -> CIImage {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                       size: CGSize(width: width, height: height), format: .RGBAf,
                       colorSpace: colorSpace)
    }

    private func pixel(_ image: CIImage, x: Int, y: Int) throws -> [Float] {
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!,
                           rowBytes: 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBAf, colorSpace: colorSpace)
        }
        return values
    }

    private func oklab(_ rgb: [Float]) -> (Double, Double, Double) {
        let r = Double(rgb[0]), g = Double(rgb[1]), b = Double(rgb[2])
        func root(_ value: Double) -> Double { copysign(pow(abs(value), 1.0 / 3.0), value) }
        let l = root(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = root(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = root(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    private func chromaResidual(reference: [Float], candidate: [Float],
                                output: [Float]) -> Double {
        let refLab = oklab(reference)
        let outputLab = oklab(output)
        let referenceY = luminance(reference), candidateY = luminance(candidate)
        let exposureScale = referenceY > 0.00001
            ? pow(max(candidateY / referenceY, 0.00390625), 1.0 / 3.0)
            : 1
        return hypot(outputLab.1 - refLab.1 * exposureScale,
                     outputLab.2 - refLab.2 * exposureScale)
    }

    private func luminance(_ rgba: [Float]) -> Double {
        0.2126 * Double(rgba[0]) + 0.7152 * Double(rgba[1]) + 0.0722 * Double(rgba[2])
    }

    private func assertPixelEqual(_ lhs: [Float], _ rhs: [Float], accuracy: Float,
                                  file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<4 {
            XCTAssertEqual(lhs[channel], rhs[channel], accuracy: accuracy,
                           "channel \(channel)", file: file, line: line)
        }
    }
}

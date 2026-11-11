import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class LocalGuidanceTests: XCTestCase {
    private typealias RGBA = (red: Double, green: Double, blue: Double, alpha: Double)

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var engine = PhotoEngine()

    func testMidtonePatchDoesNotInheritTheGlobalExposureDifference() throws {
        let source = bitmapImage(width: 96, height: 96) { x, y in
            if (16..<48).contains(x) && (32..<64).contains(y) {
                return (0.25, 0.25, 0.25, 1)
            }
            return (0.7, 0.7, 0.7, 1)
        }
        let inspection = try engine.inspectLocalMask(centerMask(), reference: source)
        let guidance = try XCTUnwrap(inspection.lightGuidance)

        XCTAssertEqual(guidance.selectedMedianLinear, 0.25, accuracy: 0.025)
        XCTAssertEqual(guidance.globalMedianLinear, 0.7, accuracy: 0.025)
        XCTAssertFalse(guidance.hasSuggestion)
        XCTAssertLessThan(abs(guidance.suggestedExposureEV), 0.03)
        XCTAssertEqual(inspection.suggestedExposureEV, guidance.suggestedExposureEV, accuracy: 0.001)
        XCTAssertEqual(inspection.suggestedHighlights, 0, accuracy: 0.001)
        XCTAssertEqual(inspection.suggestedShadows, 0, accuracy: 0.001)
    }

    func testSupportedDarkLiftIsBoundedAndPreservesTheSelectedColorsRGBRatios() throws {
        let source = bitmapImage(width: 96, height: 96) { x, y in
            if (16..<48).contains(x) && (32..<64).contains(y) {
                return (0.018, 0.03, 0.04, 1)
            }
            return (0.32, 0.32, 0.32, 1)
        }
        let mask = centerMask()
        let inspection = try engine.inspectLocalMask(mask, reference: source)
        let guidance = try XCTUnwrap(inspection.lightGuidance)

        XCTAssertTrue(guidance.hasSuggestion)
        XCTAssertGreaterThan(guidance.suggestedExposureEV, 0)
        XCTAssertLessThanOrEqual(guidance.suggestedExposureEV, 0.6)
        XCTAssertEqual(inspection.suggestedExposureEV, guidance.suggestedExposureEV, accuracy: 0.001)

        var settings = neutralSettings()
        settings.masks = [LocalMask(id: mask.id, name: mask.name, kind: mask.kind,
                                    start: mask.start, end: mask.end, radius: mask.radius,
                                    feather: mask.feather, exposureEV: guidance.suggestedExposureEV,
                                    highlightProtection: 0, colorProtection: 0, stage: mask.stage)]
        let adjusted = try engine.process(source, settings: settings, lut: nil).image
        let before = try pixel(source, x: 32, y: 48)
        let after = try pixel(adjusted, x: 32, y: 48)

        XCTAssertGreaterThan(after[0], before[0])
        XCTAssertEqual(Double(after[0] / after[1]), Double(before[0] / before[1]), accuracy: 0.004)
        XCTAssertEqual(Double(after[1] / after[2]), Double(before[1] / before[2]), accuracy: 0.004)
    }

    func testUniformDarkWhiteTinyAndNearlyTransparentSelectionsStayWithoutAdvice() throws {
        let full = CGRect(x: 0, y: 0, width: 96, height: 96)
        let dark = try engine.inspectLocalMask(LocalMask(kind: .luminance),
                                               reference: solidImage(0.001, alpha: 1, extent: full))
        let white = try engine.inspectLocalMask(LocalMask(kind: .luminance),
                                                reference: solidImage(1, alpha: 1, extent: full))
        let tiny = LocalMask(kind: .radial, start: .init(x: 0.5, y: 0.5),
                             end: .init(x: 0.505, y: 0.505), feather: 0)
        let tinyInspection = try engine.inspectLocalMask(tiny, reference: solidImage(0.02, alpha: 1, extent: full))
        let transparent = try engine.inspectLocalMask(
            LocalMask(kind: .luminance),
            reference: solidImage(0.02, alpha: 0.0005, extent: full))

        for inspection in [dark, white, tinyInspection, transparent] {
            XCTAssertFalse(inspection.lightGuidance?.hasSuggestion ?? false)
            XCTAssertEqual(inspection.suggestedExposureEV, 0, accuracy: 0.001)
        }
    }

    func testNightSceneAdviceRespectsTheSmallLiftCap() throws {
        let source = bitmapImage(width: 96, height: 96) { x, _ in
            x < 77 ? (0.025, 0.025, 0.025, 1) : (0.24, 0.24, 0.24, 1)
        }
        let inspection = try engine.inspectLocalMask(LocalMask(kind: .luminance), reference: source)
        let guidance = try XCTUnwrap(inspection.lightGuidance)

        XCTAssertLessThan(guidance.globalMedianLinear, 0.04)
        XCTAssertGreaterThan(guidance.globalP95Linear, 0.20)
        XCTAssertGreaterThan(guidance.suggestedExposureEV, 0)
        XCTAssertLessThanOrEqual(guidance.suggestedExposureEV, 0.12 + 0.001)
        XCTAssertEqual(inspection.suggestedExposureEV, guidance.suggestedExposureEV, accuracy: 0.001)
    }

    func testNearClippingSaturatedRedConstrainsAnOtherwiseDarkLift() throws {
        let source = bitmapImage(width: 96, height: 96) { x, y in
            guard (16..<48).contains(x), (32..<64).contains(y) else {
                return (0.32, 0.32, 0.32, 1)
            }
            let localX = x - 16, localY = y - 32
            if (localX * 17 + localY * 31) % 50 == 0 {
                return (0.99, 0.008, 0.004, 1)
            }
            return (0.02, 0.02, 0.02, 1)
        }
        let inspection = try engine.inspectLocalMask(centerMask(), reference: source)
        let guidance = try XCTUnwrap(inspection.lightGuidance)

        XCTAssertGreaterThan(guidance.selectedP99MaxChannel, 0.97)
        XCTAssertLessThan(guidance.suggestedExposureEV, 0.03)
        XCTAssertFalse(guidance.hasSuggestion)
        XCTAssertLessThanOrEqual(guidance.predictedIntroducedHighlightFraction, 0.005 + 0.0001)
    }

    func testSameUnpremultipliedColorsKeepGuidanceAcrossAlphaAndTranslatedExtent() throws {
        func source(alpha: Double) -> CIImage {
            let image = bitmapImage(width: 96, height: 96) { x, y in
                if (16..<48).contains(x) && (32..<64).contains(y) {
                    return (0.02, 0.04, 0.06, alpha)
                }
                return (0.32, 0.32, 0.32, alpha)
            }
            return image.transformed(by: CGAffineTransform(translationX: 23, y: -11))
        }

        let mask = centerMask()
        let opaque = try engine.inspectLocalMask(mask, reference: source(alpha: 1))
        let translucent = try engine.inspectLocalMask(mask, reference: source(alpha: 0.35))
        let opaqueGuidance = try XCTUnwrap(opaque.lightGuidance)
        let translucentGuidance = try XCTUnwrap(translucent.lightGuidance)

        XCTAssertEqual(opaque.coverage, translucent.coverage, accuracy: 0.01)
        XCTAssertEqual(opaqueGuidance.selectedP05Linear, translucentGuidance.selectedP05Linear, accuracy: 0.01)
        XCTAssertEqual(opaqueGuidance.selectedMedianLinear, translucentGuidance.selectedMedianLinear, accuracy: 0.01)
        XCTAssertEqual(opaqueGuidance.selectedP95Linear, translucentGuidance.selectedP95Linear, accuracy: 0.01)
        XCTAssertEqual(opaqueGuidance.selectedP99MaxChannel, translucentGuidance.selectedP99MaxChannel, accuracy: 0.01)
        XCTAssertEqual(opaqueGuidance.globalMedianLinear, translucentGuidance.globalMedianLinear, accuracy: 0.01)
        XCTAssertEqual(opaqueGuidance.suggestedExposureEV, translucentGuidance.suggestedExposureEV, accuracy: 0.01)
        XCTAssertEqual(opaqueGuidance.hasSuggestion, translucentGuidance.hasSuggestion)
    }

    func testRegionalAdviceMatchesTheCoverageAndDirectionOfItsMeasuredMask() throws {
        let source = bitmapImage(width: 96, height: 96) { x, y in
            if (32..<64).contains(x) && (32..<64).contains(y) {
                return (0.85, 0.85, 0.85, 1)
            }
            return (0.20, 0.20, 0.20, 1)
        }
        let suggestions = try RegionalAdjustmentAnalyzer.suggestions(reference: source, context: engine.context)
        let highlight = try XCTUnwrap(suggestions.first { $0.mask.exposureEV < 0 })
        let measured = try engine.inspectLocalMask(highlight.mask, reference: source)
        let guidance = try XCTUnwrap(highlight.lightGuidance)
        let measuredGuidance = try XCTUnwrap(measured.lightGuidance)

        XCTAssertTrue(guidance.hasSuggestion)
        XCTAssertLessThan(guidance.suggestedExposureEV, 0)
        XCTAssertEqual(highlight.mask.exposureEV, guidance.suggestedExposureEV, accuracy: 0.001)
        XCTAssertEqual(highlight.effectiveCoverage ?? -1, measured.coverage, accuracy: 0.01)
        XCTAssertEqual(guidance, measuredGuidance)
        XCTAssertTrue(suggestions.allSatisfy { candidate in
            guard let evidence = candidate.lightGuidance else { return false }
            return evidence.hasSuggestion &&
                ((candidate.mask.exposureEV > 0 && evidence.suggestedExposureEV > 0) ||
                 (candidate.mask.exposureEV < 0 && evidence.suggestedExposureEV < 0))
        }, "a regional candidate must have measured evidence that supports its adjustment direction")
    }

    func testLegacyRegionalSuggestionJSONDecodesWithoutGuidanceFields() throws {
        let encodedMask = try JSONEncoder().encode(LocalMask())
        let maskObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedMask) as? [String: Any])
        let legacyJSON: [String: Any] = [
            "id": "region.legacy.shadow",
            "title": "Legacy shadow",
            "evidence": "Older regional evidence",
            "caution": "Review mask coverage",
            "mask": maskObject
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyJSON)
        let decoded = try JSONDecoder().decode(RegionalAdjustmentSuggestion.self, from: data)

        XCTAssertEqual(decoded.id, "region.legacy.shadow")
        XCTAssertNil(decoded.lightGuidance)
        XCTAssertNil(decoded.effectiveCoverage)
    }

    private func centerMask() -> LocalMask {
        LocalMask(kind: .radial, start: .init(x: 1.0 / 3.0, y: 0.5),
                  end: .init(x: 0.48, y: 0.65), feather: 0.05,
                  exposureEV: 0, highlightProtection: 0, colorProtection: 0,
                  stage: .beforeLook)
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
        settings.lutIntensity = 1
        settings.preserveLuminance = 0
        settings.protectSkin = 0
        settings.protectNeutrals = 0
        settings.gamutCompression = 0
        settings.colorHarmony = nil
        return settings
    }

    private func solidImage(_ value: Double, alpha: Double, extent: CGRect) -> CIImage {
        bitmapImage(width: Int(extent.width), height: Int(extent.height)) { _, _ in
            (value, value, value, alpha)
        }.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    private func bitmapImage(width: Int, height: Int,
                             pixel: (Int, Int) -> RGBA) -> CIImage {
        var components = [Float]()
        components.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                components.append(Float(value.red * value.alpha))
                components.append(Float(value.green * value.alpha))
                components.append(Float(value.blue * value.alpha))
                components.append(Float(value.alpha))
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
}

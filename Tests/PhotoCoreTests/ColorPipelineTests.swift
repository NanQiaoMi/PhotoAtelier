import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import PhotoCore

final class ColorPipelineTests: XCTestCase {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    func testFinalProtectionMeasuresAndReducesTintIntroducedByOverlappingMasks() throws {
        let engine = PhotoEngine()
        let source = image(0.22, 0.22, 0.22)
        var settings = neutral()
        var protection = ColorHarmonySettings(); protection.amount = 1
        settings.colorHarmony = protection
        settings.masks = [
            LocalMask(kind: .luminance, exposureEV: 0.2, warmth: 1,
                      highlightProtection: 0, colorProtection: 0, stage: .beforeLook),
            LocalMask(kind: .luminance, exposureEV: 0.1, warmth: 0.9, tint: 0.6,
                      highlightProtection: 0, colorProtection: 0, stage: .afterLook)
        ]
        let protected = try engine.process(source, settings: settings, lut: nil)
        settings.colorHarmony = nil
        let unprotected = try engine.process(source, settings: settings, lut: nil)
        let p = pixel(protected.image, engine: engine), u = pixel(unprotected.image, engine: engine)
        XCTAssertLessThan(spread(p), spread(u) * 0.65)
        XCTAssertEqual(luminance(p), luminance(u), accuracy: 0.005)
        let report = try XCTUnwrap(protected.report.colorQuality)
        XCTAssertTrue(report.protectionEnabled)
        XCTAssertGreaterThan(report.sampleCount, 0)
        XCTAssertGreaterThan(report.neutralTintBefore, report.neutralTintAfter)
        XCTAssertEqual(report.scene.regions.count, 9)
    }

    func testFinalReportSurvivesJSONAndDoesNotInventLUTCompatibilityWithoutLUT() throws {
        var settings = neutral()
        settings.masks = [LocalMask(kind: .luminance, exposureEV: 0.2)]
        let output = try PhotoEngine().process(image(0.3, 0.4, 0.2), settings: settings,
                                              lut: nil, outputColorSpace: .sRGB)
        let report = try XCTUnwrap(output.report.colorQuality)
        let restored = try JSONDecoder().decode(ProcessingReport.self, from: JSONEncoder().encode(output.report))
        XCTAssertEqual(restored.colorQuality?.outputColorSpace, .sRGB)
        XCTAssertEqual(restored.colorQuality?.sampleCount, report.sampleCount)
        XCTAssertNil(restored.lutCompatibility)
        XCTAssertLessThan(report.outOfGamutAfter, 0.001)
    }

    func testPreviewTargetPixelsAgreeWithSixteenBitExport() throws {
        let engine = PhotoEngine()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("atelier-color-roundtrip-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for target in OutputColorSpace.allCases {
            let processed = try engine.process(image(1.1, -0.08, 0.3), settings: neutral(), lut: nil,
                                               outputColorSpace: target)
            var export = ExportSettings(); export.colorSpace = target; export.format = .tiff
            let url = root.appendingPathComponent("\(target.rawValue).tiff")
            try PhotoExporter.write(image: processed.image, to: url, settings: export,
                                    sourceProperties: [:], context: engine.context)
            let reloaded = try PhotoLoader.load(url: url, lensCorrection: false)
            let expected = pixel(processed.image, engine: engine), actual = pixel(reloaded.image, engine: engine)
            for channel in 0..<4 { XCTAssertEqual(actual[channel], expected[channel], accuracy: 0.003) }
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(cg.bitsPerComponent, 16)
            XCTAssertEqual(cg.width, 48)
            XCTAssertEqual(cg.height, 32)
        }
    }

    func testGlobalSaturationGuardLimitsAddedColorWhileRetainingLight() throws {
        let engine = PhotoEngine(), source = image(0.55, 0.24, 0.13)
        var settings = neutral(); settings.saturation = 3
        var protection = ColorHarmonySettings(); protection.amount = 1
        settings.colorHarmony = protection
        let guarded = try engine.process(source, settings: settings, lut: nil).image
        settings.colorHarmony = nil
        let unchecked = try engine.process(source, settings: settings, lut: nil).image
        let p = pixel(guarded, engine: engine), u = pixel(unchecked, engine: engine)
        XCTAssertLessThan(spread(p), spread(u) * 0.9)
        XCTAssertEqual(luminance(p), luminance(u), accuracy: 0.005)
    }

    func testEngineAutoExposureDoesNotDivideStraightAlphaAgain() throws {
        let engine = PhotoEngine()
        var settings = neutral(); settings.autoExposure = true
        let opaque = try engine.process(image(0.6, 0.6, 0.6), settings: settings, lut: nil)
        let transparent = try engine.process(image(0.6, 0.6, 0.6, alpha: 0.25), settings: settings, lut: nil)
        XCTAssertEqual(opaque.report.appliedExposureEV, -0.35, accuracy: 0.001)
        XCTAssertEqual(opaque.report.appliedExposureEV, transparent.report.appliedExposureEV, accuracy: 0.001)
    }

    func testSelectionReferenceMatchesGuardedGlobalSaturation() throws {
        let engine = PhotoEngine(), source = image(0.55, 0.24, 0.13)
        var settings = neutral(); settings.saturation = 3
        let reference = try engine.maskReferenceImage(source, settings: settings)
        let global = try engine.process(source, settings: settings, lut: nil).image
        let r = pixel(reference, engine: engine), g = pixel(global, engine: engine)
        for channel in 0..<4 { XCTAssertEqual(r[channel], g[channel], accuracy: 0.001) }
    }

    private func neutral() -> AdjustmentSettings {
        var settings = AdjustmentSettings()
        settings.autoExposure = false; settings.autoWhiteBalance = false
        settings.protectNeutrals = 0; settings.protectSkin = 0; settings.preserveLuminance = 0
        return settings
    }
    private func image(_ r: Double, _ g: Double, _ b: Double, alpha: Double = 1) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, alpha: alpha, colorSpace: linear)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 48, height: 32))
    }
    private func pixel(_ image: CIImage, engine: PhotoEngine) -> [Float] {
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            engine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
                                  bounds: CGRect(x: 20, y: 16, width: 1, height: 1),
                                  format: .RGBAf, colorSpace: linear)
        }
        return pixel
    }
    private func spread(_ pixel: [Float]) -> Float { max(pixel[0], max(pixel[1], pixel[2])) - min(pixel[0], min(pixel[1], pixel[2])) }
    private func luminance(_ pixel: [Float]) -> Float { pixel[0] * 0.2126 + pixel[1] * 0.7152 + pixel[2] * 0.0722 }
}

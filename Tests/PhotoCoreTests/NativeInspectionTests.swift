import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class NativeInspectionTests: XCTestCase {
    private let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    func testRegionBoundsUseTopLeftNormalizedCoordinatesAndClampAllFourCorners() throws {
        let extent = CGRect(x: 23, y: -17, width: 400, height: 300)
        let cases: [(MaskPoint, CGRect)] = [
            (.init(x: 0, y: 0), CGRect(x: 23, y: 219, width: 64, height: 64)),
            (.init(x: 1, y: 0), CGRect(x: 359, y: 219, width: 64, height: 64)),
            (.init(x: 0, y: 1), CGRect(x: 23, y: -17, width: 64, height: 64)),
            (.init(x: 1, y: 1), CGRect(x: 359, y: -17, width: 64, height: 64))
        ]

        for (center, expected) in cases {
            XCTAssertEqual(try NativeInspectionRegion(center: center, pixelSize: 64).bounds(in: extent), expected)
        }

        let upperQuarter = try NativeInspectionRegion(
            center: .init(x: 0.25, y: 0.25), pixelSize: 64
        ).bounds(in: extent)
        XCTAssertEqual(upperQuarter, CGRect(x: 91, y: 176, width: 64, height: 64),
                       "normalized y=0 must select the top of a Core Image extent")
    }

    func testRegionBoundsRespectIntegerInteriorAndRequestedSizeCaps() throws {
        let extent = CGRect(x: -31, y: 47, width: 2400, height: 1800)

        XCTAssertEqual(try NativeInspectionRegion().bounds(in: extent),
                       CGRect(x: 785, y: 563, width: 768, height: 768))
        XCTAssertEqual(try NativeInspectionRegion(pixelSize: 1024).bounds(in: extent),
                       CGRect(x: 657, y: 435, width: 1024, height: 1024))

        let fractionalExtent = CGRect(x: 10.25, y: -3.4, width: 20.5, height: 18.8)
        XCTAssertEqual(try NativeInspectionRegion(pixelSize: 64).bounds(in: fractionalExtent),
                       CGRect(x: 11, y: -3, width: 19, height: 18),
                       "the returned sample must stay on the integer pixel grid inside the extent")
    }

    func testRegionRejectsInvalidSizesCentersAndExtents() {
        let validExtent = CGRect(x: 0, y: 0, width: 256, height: 256)
        for size in [63, 1025] {
            XCTAssertThrowsError(try NativeInspectionRegion(pixelSize: size).bounds(in: validExtent))
        }
        for center in [
            MaskPoint(x: .nan, y: 0.5), MaskPoint(x: 0.5, y: .infinity),
            MaskPoint(x: -0.001, y: 0.5), MaskPoint(x: 0.5, y: 1.001)
        ] {
            XCTAssertThrowsError(try NativeInspectionRegion(center: center).bounds(in: validExtent))
        }
        for extent in [
            CGRect.zero,
            CGRect.null,
            CGRect.infinite,
            CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 20)
        ] {
            XCTAssertThrowsError(try NativeInspectionRegion().bounds(in: extent))
        }
    }

    func testRendererReturnsRequestedROIForSmallAndTranslatedImages() throws {
        let extent = CGRect(x: 13, y: -9, width: 40, height: 28)
        let source = solidImage(extent: extent, red: 0.24, green: 0.31, blue: 0.42)
        let region = NativeInspectionRegion(center: .init(x: 0, y: 0), pixelSize: 768)
        let result = try NativeInspectionRenderer().render(source, settings: neutralSettings(), lut: nil,
                                                           region: region)

        XCTAssertEqual(result.outputExtent, extent)
        XCTAssertEqual(result.sampleBounds, extent)
        XCTAssertEqual(result.before.width, 40)
        XCTAssertEqual(result.before.height, 28)
        XCTAssertEqual(result.after.width, 40)
        XCTAssertEqual(result.after.height, 28)
    }

    func testRendererChecksCancellationBeforeRendering() {
        let source = solidImage(extent: CGRect(x: 0, y: 0, width: 32, height: 24),
                                red: 0.2, green: 0.3, blue: 0.4)
        let token = CancellationToken()
        token.cancel()

        XCTAssertThrowsError(try NativeInspectionRenderer().render(
            source, settings: neutralSettings(), lut: nil, cancellation: token
        )) { error in
            guard let atelierError = error as? AtelierError,
                  case .cancelled = atelierError else {
                return XCTFail("expected AtelierError.cancelled, got \(error)")
            }
        }
    }

    func testAfterAndBeforeMatchFullEngineRendersForOverlappingMasksLUTAndGeometry() throws {
        let engine = PhotoEngine()
        let source = patternedImage(width: 128, height: 96)
        let firstMask = LocalMask(
            name: "left overlap", kind: .radial,
            start: .init(x: 0.42, y: 0.52), end: .init(x: 0.78, y: 0.79),
            radius: 0.31, feather: 0.18, exposureEV: 0.38, saturation: 1.12,
            highlightProtection: 0, colorProtection: 0, stage: .beforeLook
        )
        let secondMask = LocalMask(
            name: "right overlap", kind: .radial,
            start: .init(x: 0.60, y: 0.48), end: .init(x: 0.91, y: 0.76),
            radius: 0.31, feather: 0.22, exposureEV: -0.24, warmth: 0.08,
            highlightProtection: 0, colorProtection: 0, stage: .afterLook
        )
        var settings = neutralSettings()
        settings.exposureEV = 0.16
        settings.rotationDegrees = 4.5
        settings.masks = [firstMask, secondMask]
        settings.lutIntensity = 0.82
        settings.lutColorSpace = .linearSRGB
        settings.preserveLuminance = 0
        settings.protectSkin = 0
        settings.protectNeutrals = 0
        settings.gamutCompression = 0
        settings.colorHarmony = nil
        let lut = try nonlinearCube()
        let region = NativeInspectionRegion(center: .init(x: 0.38, y: 0.64), pixelSize: 64)

        let native = try NativeInspectionRenderer(engine: engine).render(
            source, settings: settings, lut: lut, outputColorSpace: .sRGB, region: region
        )
        let fullAfter = try engine.process(source, settings: settings, lut: lut,
                                           outputColorSpace: .sRGB).image
        var globalOnlySettings = settings
        globalOnlySettings.masks = []
        globalOnlySettings.lutIntensity = 0
        let fullBefore = try engine.process(source, settings: globalOnlySettings, lut: nil,
                                            outputColorSpace: .sRGB).image

        XCTAssertEqual(native.outputExtent, fullAfter.extent)
        XCTAssertEqual(native.sampleBounds, try region.bounds(in: fullAfter.extent))
        let expectedAfter = try fullImage(fullAfter, extent: fullAfter.extent, context: engine.context)
        let expectedBefore = try fullImage(fullBefore, extent: fullBefore.extent, context: engine.context)
        assertMatchesFullImageCrop(native.after, fullImage: expectedAfter,
                                   fullExtent: fullAfter.extent, sampleBounds: native.sampleBounds)
        assertMatchesFullImageCrop(native.before, fullImage: expectedBefore,
                                   fullExtent: fullBefore.extent, sampleBounds: native.sampleBounds)
        XCTAssertGreaterThan(maximumByteDifference(native.before, native.after), 8,
                             "the local masks and nonlinear LUT should visibly change this sample")
    }

    func testLargeImageDetailPlanMeasuresNativePixelTexture() throws {
        let width = 1600, height = 1536
        let source = finePatternImage(width: width, height: height)
        var mask = LocalMask(kind: .luminance, exposureEV: 0)
        mask.detailAdaptation = LocalDetailAdaptation(intent: .lowLight, strength: 1)
        var settings = neutralSettings()
        settings.masks = [mask]

        let engine = PhotoEngine()
        let result = try NativeInspectionRenderer(engine: engine).render(
            source, settings: settings, lut: nil,
            region: NativeInspectionRegion(center: .init(x: 0.5, y: 0.5), pixelSize: 64)
        )
        let plan = try XCTUnwrap(result.report.localDetails?.first)
        let full = try engine.process(source, settings: settings, lut: nil)
        let fullPlan = try XCTUnwrap(full.report.localDetails?.first)
        let preview = source.transformed(by: .init(scaleX: 1500.0 / Double(width),
                                                   y: 1500.0 / Double(width)))
        let previewResult = try engine.process(preview, settings: settings, lut: nil)
        let previewPlan = try XCTUnwrap(previewResult.report.localDetails?.first)

        XCTAssertGreaterThan(width, 1500)
        XCTAssertGreaterThan(height, 1500)
        XCTAssertEqual(plan.measurements.patchCount, 9,
                       "the detail plan must cover the full source, not only the 64px inspection ROI")
        XCTAssertGreaterThan(plan.measurements.sampleCount, 128)
        XCTAssertGreaterThan(plan.measurements.luminanceNoise, 0.01,
                             "native-resolution random texture should remain visible in the measurements")
        XCTAssertEqual(plan.measurements, fullPlan.measurements,
                       "inspection must use the same full-source measurements as export")
        XCTAssertGreaterThan(abs(plan.measurements.luminanceNoise - previewPlan.measurements.luminanceNoise), 0.0001,
                             "resampling to the normal preview size must not replace native texture measurements")
    }

    private func neutralSettings() -> AdjustmentSettings {
        var settings = AdjustmentSettings()
        settings.autoExposure = false
        settings.autoWhiteBalance = false
        settings.colorHarmony = nil
        settings.protectSkin = 0
        settings.protectNeutrals = 0
        settings.preserveLuminance = 0
        settings.gamutCompression = 0
        settings.lutIntensity = 1
        return settings
    }

    private func solidImage(extent: CGRect, red: Double, green: Double, blue: Double) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue, alpha: 1,
                               colorSpace: linearSRGB)!).cropped(to: extent)
    }

    private func patternedImage(width: Int, height: Int) -> CIImage {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let fx = Float(x) / Float(max(1, width - 1))
                let fy = Float(y) / Float(max(1, height - 1))
                pixels[offset] = 0.12 + 0.68 * fx
                pixels[offset + 1] = 0.10 + 0.60 * fy
                pixels[offset + 2] = 0.12 + 0.28 * (1 - fx * fy)
            }
        }
        let bytes = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: bytes, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                       size: CGSize(width: width, height: height), format: .RGBAf,
                       colorSpace: linearSRGB)
    }

    private func finePatternImage(width: Int, height: Int) -> CIImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                // A fixed avalanche hash avoids phase alignment between a
                // periodic checkerboard and the analyzer's 2x2 sample grid.
                var code = UInt32(y * width + x) &+ 0x9e3779b9
                code = (code ^ (code >> 16)) &* 0x85ebca6b
                code = (code ^ (code >> 13)) &* 0xc2b2ae35
                code ^= code >> 16
                let value = UInt8(116 + code % 33)
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
            }
        }
        let bytes = Data(pixels)
        return CIImage(bitmapData: bytes, bytesPerRow: width * 4,
                       size: CGSize(width: width, height: height), format: .RGBA8,
                       colorSpace: sRGB)
    }

    private func nonlinearCube() throws -> LUTCube {
        var rows: [String] = []
        for blueIndex in 0...2 {
            for greenIndex in 0...2 {
                for redIndex in 0...2 {
                    let red = Float(redIndex) / 2
                    let green = Float(greenIndex) / 2
                    let blue = Float(blueIndex) / 2
                    rows.append("\(red * red) \(green * green) \(blue * blue)")
                }
            }
        }
        return try LUTCube.parse("""
        TITLE "native inspection nonlinear fixture"
        LUT_3D_SIZE 3
        \(rows.joined(separator: "\n"))
        """)
    }

    private func fullImage(_ image: CIImage, extent: CGRect, context: CIContext) throws -> CGImage {
        try XCTUnwrap(context.createCGImage(
            image, from: extent.integral, format: .RGBA8, colorSpace: sRGB
        ))
    }

    private func assertMatchesFullImageCrop(_ actual: CGImage, fullImage: CGImage,
                                           fullExtent: CGRect, sampleBounds: CGRect,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let integralExtent = fullExtent.integral
        // CGImage cropping rectangles are in top-left pixel coordinates; Core Image extents use bottom-left.
        let cropRect = CGRect(x: sampleBounds.minX - integralExtent.minX,
                              y: integralExtent.maxY - sampleBounds.maxY,
                              width: sampleBounds.width, height: sampleBounds.height)
        guard let expected = fullImage.cropping(to: cropRect) else {
            XCTFail("could not crop the full-resolution reference at \(cropRect)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        guard let actualData = actual.dataProvider?.data as Data?,
              let expectedData = expected.dataProvider?.data as Data? else {
            XCTFail("RGBA8 image bytes were unavailable", file: file, line: line)
            return
        }
        let commonWidth = min(actual.width, expected.width)
        let commonHeight = min(actual.height, expected.height)
        var maximumDifference = 0
        for y in 0..<commonHeight {
            for x in 0..<commonWidth {
                for channel in 0..<4 {
                    let actualOffset = y * actual.bytesPerRow + x * 4 + channel
                    let expectedOffset = y * expected.bytesPerRow + x * 4 + channel
                    maximumDifference = max(maximumDifference,
                        abs(Int(actualData[actualOffset]) - Int(expectedData[expectedOffset])))
                }
            }
        }
        XCTAssertLessThanOrEqual(maximumDifference, 2,
                                 "ROI bytes must match a full render cropped after RGBA8 output",
                                 file: file, line: line)
    }

    private func maximumByteDifference(_ lhs: CGImage, _ rhs: CGImage) -> Int {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              let lhsData = lhs.dataProvider?.data as Data?,
              let rhsData = rhs.dataProvider?.data as Data? else { return 0 }
        var difference = 0
        for y in 0..<lhs.height {
            for x in 0..<lhs.width {
                for channel in 0..<4 {
                    let lhsOffset = y * lhs.bytesPerRow + x * 4 + channel
                    let rhsOffset = y * rhs.bytesPerRow + x * 4 + channel
                    difference = max(difference, abs(Int(lhsData[lhsOffset]) - Int(rhsData[rhsOffset])))
                }
            }
        }
        return difference
    }
}

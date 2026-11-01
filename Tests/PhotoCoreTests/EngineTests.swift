import CoreGraphics
import CoreImage
import Vision
import XCTest
@testable import PhotoCore

final class EngineTests: XCTestCase {
    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    func testZeroIntensityLeavesImageUnchanged() throws {
        let engine = PhotoEngine()
        let source = solidImage(0.2, 0.4, 0.7, width: 16, height: 16)
        var settings = AdjustmentSettings()
        settings.autoExposure = false
        settings.lutIntensity = 0
        let processed = try engine.process(source, settings: settings, lut: inversionCube())

        let before = try pixel(source, x: 8, y: 8, engine: engine)
        let after = try pixel(processed.image, x: 8, y: 8, engine: engine)
        for component in 0..<3 {
            XCTAssertEqual(after[component], before[component], accuracy: 0.001)
        }
    }

    func testNonDefaultCubeDomainMatchesCPUSample() throws {
        let engine = PhotoEngine()
        let cube = try LUTCube.parse(cubeText(domainMinimum: 0.25, domainMaximum: 0.75) { r, g, b in
            (r, g, b)
        })
        var settings = neutralSettings()
        settings.lutColorSpace = .linearSRGB
        settings.lutIntensity = 1
        for value in [0.3, 0.44, 0.5, 0.7] {
            let source = solidImage(value, value, value, width: 8, height: 8)
            let processed = try engine.process(source, settings: settings, lut: cube)
            let actual = try pixel(processed.image, x: 4, y: 4, engine: engine)
            let expected = cube.sample(SIMD3<Float>(repeating: Float(value)))
            XCTAssertEqual(actual[0], expected.x, accuracy: 0.01)
            XCTAssertEqual(actual[1], expected.y, accuracy: 0.01)
            XCTAssertEqual(actual[2], expected.z, accuracy: 0.01)
        }
    }

    func testSRGBAndLinearLUTInputsUseDifferentTransferFunctions() throws {
        let engine = PhotoEngine()
        let source = solidImage(0.5, 0.5, 0.5, width: 8, height: 8)
        let cube = inversionCube()
        var sRGBSettings = neutralSettings()
        sRGBSettings.lutColorSpace = .sRGB
        sRGBSettings.lutIntensity = 1
        var linearSettings = sRGBSettings
        linearSettings.lutColorSpace = .linearSRGB

        let sRGB = try engine.process(source, settings: sRGBSettings, lut: cube).image
        let linear = try engine.process(source, settings: linearSettings, lut: cube).image
        let sRGBValue = try pixel(sRGB, x: 4, y: 4, engine: engine)[0]
        let linearValue = try pixel(linear, x: 4, y: 4, engine: engine)[0]

        XCTAssertLessThan(sRGBValue, 0.12)
        XCTAssertEqual(linearValue, 0.5, accuracy: 0.025)
        XCTAssertGreaterThan(linearValue - sRGBValue, 0.3)
    }

    func testOutOfDomainHighlightAndNegativeValuesFadeBackToOriginal() throws {
        let engine = PhotoEngine()
        let flatBlack = try LUTCube.parse(cubeText(domainMinimum: 0.25, domainMaximum: 0.75) { _, _, _ in
            (0, 0, 0)
        })
        var settings = neutralSettings()
        settings.lutColorSpace = .linearSRGB
        settings.gamutCompression = 1
        let highlight = solidImage(0.95, 0.95, 0.95, width: 8, height: 8)
        let negative = solidImage(-0.15, -0.1, -0.05, width: 8, height: 8)
        let gradedHighlight = try engine.process(highlight, settings: settings, lut: flatBlack).image
        let gradedNegative = try engine.process(negative, settings: settings, lut: flatBlack).image

        let originalHighlight = try pixel(highlight, x: 4, y: 4, engine: engine)[0]
        let outputHighlight = try pixel(gradedHighlight, x: 4, y: 4, engine: engine)[0]
        let originalNegative = try pixel(negative, x: 4, y: 4, engine: engine)[0]
        let outputNegative = try pixel(gradedNegative, x: 4, y: 4, engine: engine)[0]
        XCTAssertEqual(outputHighlight, originalHighlight, accuracy: 0.03)
        XCTAssertEqual(outputNegative, originalNegative, accuracy: 0.03)
    }

    func testFullNeutralProtectionReturnsOriginalEvenWithGamutCompression() throws {
        let engine = PhotoEngine()
        let source = solidImage(0.25, 0.25, 0.25, width: 8, height: 8)
        var settings = neutralSettings()
        settings.preserveLuminance = 1
        settings.protectNeutrals = 1
        settings.protectSkin = 1
        settings.gamutCompression = 1
        let output = try engine.process(source, settings: settings, lut: inversionCube()).image
        let before = try pixel(source, x: 4, y: 4, engine: engine)
        let after = try pixel(output, x: 4, y: 4, engine: engine)
        for component in 0..<3 {
            XCTAssertEqual(after[component], before[component], accuracy: 0.002)
        }
    }

    func testOneEVDoublesLinearExposure() throws {
        let engine = PhotoEngine()
        let source = solidImage(0.08, 0.12, 0.2, width: 16, height: 16)
        var settings = AdjustmentSettings()
        settings.autoExposure = false
        settings.exposureEV = 1
        let output = try engine.process(source, settings: settings, lut: nil)
        let before = try pixel(source, x: 8, y: 8, engine: engine)
        let after = try pixel(output.image, x: 8, y: 8, engine: engine)

        XCTAssertEqual(output.report.appliedExposureEV, 1, accuracy: 0.0001)
        for component in 0..<3 {
            XCTAssertEqual(after[component], before[component] * 2, accuracy: 0.003)
        }
    }

    func testPositiveWarmthAddsWarmColorGloballyAndInsideMask() throws {
        let engine = PhotoEngine(), source = solidImage(0.3, 0.3, 0.3, width: 32, height: 32)
        var settings = neutralSettings()
        settings.temperature = 0.7
        let warm = try engine.process(source, settings: settings, lut: nil).image
        let global = try pixel(warm, x: 16, y: 16, engine: engine)
        XCTAssertGreaterThan(global[0], global[2])
        settings.temperature = 0
        settings.masks = [LocalMask(start: .init(x: 0.5, y: 0.5), end: .init(x: 0.9, y: 0.9),
                                    feather: 0, exposureEV: 0, warmth: 0.7)]
        let masked = try engine.process(source, settings: settings, lut: nil).image
        let local = try pixel(masked, x: 16, y: 16, engine: engine)
        let outside = try pixel(masked, x: 0, y: 0, engine: engine)
        XCTAssertGreaterThan(local[0], local[2])
        XCTAssertEqual(outside[0], outside[2], accuracy: 0.002)
    }

    func testAutoExposureDoesNotForceHighKeyOrDeepShadowImagesToMiddleGray() throws {
        let engine = PhotoEngine()
        var settings = AdjustmentSettings()
        settings.autoExposure = true
        let low = try engine.process(solidImage(0.01, 0.01, 0.01, width: 8, height: 8),
                                     settings: settings, lut: nil)
        let high = try engine.process(solidImage(0.95, 0.95, 0.95, width: 8, height: 8),
                                      settings: settings, lut: nil)
        XCTAssertEqual(low.report.appliedExposureEV, 0, accuracy: 0.0001)
        XCTAssertEqual(high.report.appliedExposureEV, 0, accuracy: 0.0001)
    }

    func testAutomaticWhiteBalanceReducesMeasuredNeutralCastAndSkipsSaturatedScene() throws {
        let engine = PhotoEngine()
        var settings = neutralSettings()
        settings.autoWhiteBalance = true
        let neutral = solidImage(0.20, 0.21, 0.22, width: 64, height: 64)
        let balanced = try engine.process(neutral, settings: settings, lut: nil)
        let before = try pixel(neutral, x: 32, y: 32, engine: engine)
        let after = try pixel(balanced.image, x: 32, y: 32, engine: engine)
        XCTAssertLessThan(abs(after[0] - after[2]), abs(before[0] - before[2]) * 0.25)
        let saturated = solidImage(0.05, 0.20, 0.80, width: 64, height: 64)
        let unchanged = try engine.process(saturated, settings: settings, lut: nil)
        let saturatedBefore = try pixel(saturated, x: 32, y: 32, engine: engine)
        let saturatedAfter = try pixel(unchanged.image, x: 32, y: 32, engine: engine)
        for component in 0..<3 {
            XCTAssertEqual(saturatedBefore[component], saturatedAfter[component], accuracy: 0.002)
        }
        XCTAssertTrue(unchanged.report.warnings.contains { $0.contains("白平衡") })
    }

    func testRadialMaskUsesEllipseFromStartAndEndOnNonSquarePhoto() throws {
        let engine = PhotoEngine()
        var settings = AdjustmentSettings()
        settings.autoExposure = false
        settings.masks = [LocalMask(name: "ellipse", kind: .radial,
                                    start: MaskPoint(x: 0.5, y: 0.3),
                                    end: MaskPoint(x: 0.8, y: 0.7),
                                    radius: 0.01, feather: 0, exposureEV: 1)]
        let output = try engine.process(solidImage(0.1, 0.1, 0.1, width: 100, height: 50),
                                        settings: settings, lut: nil).image

        let center = try pixel(output, x: 50, y: 15, engine: engine)[0]
        let insideEllipse = try pixel(output, x: 76, y: 15, engine: engine)[0]
        let outsideEllipse = try pixel(output, x: 84, y: 15, engine: engine)[0]
        let outsideVertically = try pixel(output, x: 50, y: 42, engine: engine)[0]
        XCTAssertGreaterThan(center, 0.18)
        XCTAssertGreaterThan(insideEllipse, 0.18)
        XCTAssertLessThan(outsideEllipse, 0.12)
        XCTAssertLessThan(outsideVertically, 0.12)
    }

    func testInvertedRadialMaskProtectsCenterAndAdjustsOutside() throws {
        let engine = PhotoEngine()
        var settings = AdjustmentSettings()
        settings.autoExposure = false
        settings.masks = [LocalMask(name: "inverted", kind: .radial,
                                    start: MaskPoint(x: 0.5, y: 0.5),
                                    end: MaskPoint(x: 0.25, y: 0.25),
                                    feather: 0, inverted: true, exposureEV: 1)]
        let output = try engine.process(solidImage(0.1, 0.1, 0.1, width: 64, height: 64),
                                        settings: settings, lut: nil).image
        let center = try pixel(output, x: 32, y: 32, engine: engine)[0]
        let outside = try pixel(output, x: 4, y: 4, engine: engine)[0]
        XCTAssertEqual(center, 0.1, accuracy: 0.015)
        XCTAssertGreaterThan(outside, 0.18)
    }

    func testLinearMaskAndBrushMaskTrackTheirGeometry() throws {
        let engine = PhotoEngine()
        var linearSettings = AdjustmentSettings()
        linearSettings.autoExposure = false
        linearSettings.masks = [LocalMask(name: "linear", kind: .linear,
                                          start: MaskPoint(x: 0.2, y: 0.5),
                                          end: MaskPoint(x: 0.8, y: 0.5),
                                          feather: 0.1, exposureEV: 1)]
        let linear = try engine.process(solidImage(0.1, 0.1, 0.1, width: 100, height: 50),
                                        settings: linearSettings, lut: nil).image
        let startSide = try pixel(linear, x: 10, y: 25, engine: engine)[0]
        let endSide = try pixel(linear, x: 90, y: 25, engine: engine)[0]
        XCTAssertGreaterThan(startSide, 0.18)
        XCTAssertLessThan(endSide, 0.12)

        var brushSettings = AdjustmentSettings()
        brushSettings.autoExposure = false
        brushSettings.masks = [LocalMask(name: "brush", kind: .brush,
                                         points: [MaskPoint(x: 0.2, y: 0.5),
                                                  MaskPoint(x: 0.8, y: 0.5)],
                                         radius: 0.06, feather: 0, exposureEV: 1)]
        let brush = try engine.process(solidImage(0.1, 0.1, 0.1, width: 100, height: 50),
                                       settings: brushSettings, lut: nil).image
        let onStroke = try pixel(brush, x: 50, y: 25, engine: engine)[0]
        let offStroke = try pixel(brush, x: 50, y: 5, engine: engine)[0]
        XCTAssertGreaterThan(onStroke, 0.18)
        XCTAssertLessThan(offStroke, 0.12)
    }

    func testRotationAndPerspectiveKeepOpaqueImageEdges() throws {
        let engine = PhotoEngine()
        let source = solidImage(0.4, 0.5, 0.6, width: 80, height: 48)

        var rotationSettings = AdjustmentSettings()
        rotationSettings.autoExposure = false
        rotationSettings.rotationDegrees = 11
        let rotated = try engine.process(source, settings: rotationSettings, lut: nil).image
        XCTAssertTrue(try allPixelsOpaque(rotated, engine: engine))

        var perspectiveSettings = AdjustmentSettings()
        perspectiveSettings.autoExposure = false
        perspectiveSettings.verticalPerspective = 0.12
        perspectiveSettings.horizontalPerspective = -0.08
        let perspective = try engine.process(source, settings: perspectiveSettings, lut: nil).image
        XCTAssertTrue(try allPixelsOpaque(perspective, engine: engine))
    }

    func testAutoStraightenLevelsARealPixelLineAndKeepsOpaquePixels() throws {
        let engine = PhotoEngine()
        var settings = AdjustmentSettings()
        settings.autoExposure = false
        settings.autoStraighten = true
        let output = try engine.process(horizonImage(), settings: settings, lut: nil)
        XCTAssertTrue(try allPixelsOpaque(output.image, engine: engine))
        XCTAssertGreaterThan(abs(output.report.straighteningDegrees), 1)
        XCTAssertLessThanOrEqual(abs(output.report.straighteningDegrees), 15)
        let remainingSlope = try brightLineSlope(output.image, engine: engine)
        XCTAssertLessThan(abs(remainingSlope), 0.02, "自动拉直后，实际像素中的明亮直线应接近水平")
    }

    func testCancellationAndInvalidSettingsAreReported() throws {
        let engine = PhotoEngine()
        let image = solidImage(0.2, 0.2, 0.2, width: 8, height: 8)
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try engine.process(image, settings: AdjustmentSettings(), lut: nil,
                                                cancellation: token)) { error in
            XCTAssertEqual((error as? AtelierError)?.errorDescription, AtelierError.cancelled.errorDescription)
        }

        var invalid = AdjustmentSettings()
        invalid.rotationDegrees = .infinity
        XCTAssertThrowsError(try PhotoEngine.validate(invalid))
    }

    private func neutralSettings() -> AdjustmentSettings {
        var settings = AdjustmentSettings()
        settings.autoExposure = false
        settings.autoWhiteBalance = false
        settings.contrast = 1
        settings.saturation = 1
        settings.highlights = 0
        settings.shadows = 0
        settings.preserveLuminance = 0
        settings.protectSkin = 0
        settings.protectNeutrals = 0
        settings.gamutCompression = 0
        settings.lutIntensity = 1
        return settings
    }

    private func solidImage(_ red: Double, _ green: Double, _ blue: Double,
                            width: Int, height: Int) -> CIImage {
        let color = CIColor(red: red, green: green, blue: blue, alpha: 1,
                            colorSpace: linearColorSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0,
                                                        width: width, height: height))
    }

    private func pixel(_ image: CIImage, x: Int, y: Int, engine: PhotoEngine) throws -> [Float] {
        var components = [Float](repeating: 0, count: 4)
        let bounds = CGRect(x: x, y: y, width: 1, height: 1)
        components.withUnsafeMutableBytes { buffer in
            engine.context.render(image, toBitmap: buffer.baseAddress!,
                                  rowBytes: 4 * MemoryLayout<Float>.size,
                                  bounds: bounds, format: .RGBAf,
                                  colorSpace: linearColorSpace)
        }
        return components
    }

    private func allPixelsOpaque(_ image: CIImage, engine: PhotoEngine) throws -> Bool {
        let bounds = image.extent.integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 0, height > 0 else { return false }
        var components = [Float](repeating: 0, count: width * height * 4)
        components.withUnsafeMutableBytes { buffer in
            engine.context.render(image, toBitmap: buffer.baseAddress!,
                                  rowBytes: width * 4 * MemoryLayout<Float>.size,
                                  bounds: bounds, format: .RGBAf,
                                  colorSpace: linearColorSpace)
        }
        let alphaIndices = stride(from: 3, to: components.count, by: 4)
        if let index = alphaIndices.min(by: { components[$0] < components[$1] }), components[index] < 0.99 {
            print("Opaque check minimum alpha=\(components[index]) at x=\((index / 4) % width), y=\((index / 4) / width), extent=\(bounds)")
            return false
        }
        return true
    }

    private func horizonImage() -> CIImage {
        let width = 160
        let height = 100
        let gray = CGColorSpaceCreateDeviceGray()
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: gray,
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 0.35, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(gray: 0.9, alpha: 1)
        context.setLineWidth(4)
        context.move(to: CGPoint(x: 5, y: 35))
        context.addLine(to: CGPoint(x: width - 5, y: 65))
        context.strokePath()
        return CIImage(cgImage: context.makeImage()!, options: [.colorSpace: linearColorSpace])
    }

    private func brightLineSlope(_ image: CIImage, engine: PhotoEngine) throws -> Double {
        let bounds = image.extent.integral, width = Int(bounds.width), height = Int(bounds.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            engine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                                  bounds: bounds, format: .RGBAf, colorSpace: linearColorSpace)
        }
        var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4] > 0.75 {
                let xx = Double(x), yy = Double(y)
                n += 1; sx += xx; sy += yy; sxx += xx * xx; sxy += xx * yy
            }
        }
        XCTAssertGreaterThan(n, 30)
        return (sxy - sx * sy / n) / (sxx - sx * sx / n)
    }

    private func inversionCube() -> LUTCube {
        try! LUTCube.parse(cubeText { red, green, blue in
            (1 - red, 1 - green, 1 - blue)
        })
    }

    private func cubeText(domainMinimum: Float = 0, domainMaximum: Float = 1,
                          value: (Float, Float, Float) -> (Float, Float, Float)) -> String {
        var rows: [String] = []
        for blue in 0...1 {
            for green in 0...1 {
                for red in 0...1 {
                    let output = value(Float(red), Float(green), Float(blue))
                    rows.append("\(output.0) \(output.1) \(output.2)")
                }
            }
        }
        return """
        TITLE "engine test"
        LUT_3D_SIZE 2
        DOMAIN_MIN \(domainMinimum) \(domainMinimum) \(domainMinimum)
        DOMAIN_MAX \(domainMaximum) \(domainMaximum) \(domainMaximum)
        \(rows.joined(separator: "\n"))
        """
    }
}

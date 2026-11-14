import XCTest
import CoreImage
@testable import PhotoCore

final class FacialZonalRefinementTests: XCTestCase {

    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    ])

    func testFacialZonalSettingsDefaultsAndValidation() throws {
        var settings = FacialZonalRefinementSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.darkCircles, 0)
        XCTAssertEqual(settings.eyeBags, 0)
        XCTAssertEqual(settings.nasolabialFolds, 0)
        XCTAssertEqual(settings.foreheadWrinkles, 0)
        XCTAssertEqual(settings.antiShine, 0)
        XCTAssertEqual(settings.jawlineSculpting, 0)
        XCTAssertEqual(settings.texturePreservation, 0.70, accuracy: 0.001)
        XCTAssertTrue(settings.isNeutral)

        settings.enabled = true
        XCTAssertTrue(settings.isNeutral, "Still neutral if all strengths are 0")

        settings.eyeBags = 0.5
        XCTAssertFalse(settings.isNeutral)

        let validated = try settings.validated()
        XCTAssertEqual(validated.eyeBags, 0.5)

        var bad = settings
        bad.eyeBags = 1.2
        XCTAssertThrowsError(try bad.validated())

        bad = settings
        bad.darkCircles = -0.1
        XCTAssertThrowsError(try bad.validated())

        bad = settings
        bad.nasolabialFolds = .nan
        XCTAssertThrowsError(try bad.validated())

        bad = settings
        bad.foreheadWrinkles = 1.5
        XCTAssertThrowsError(try bad.validated())

        bad = settings
        bad.antiShine = -0.5
        XCTAssertThrowsError(try bad.validated())

        bad = settings
        bad.jawlineSculpting = 2.0
        XCTAssertThrowsError(try bad.validated())

        bad = settings
        bad.texturePreservation = -0.1
        XCTAssertThrowsError(try bad.validated())
    }

    func testRecipeVersion17Gating() throws {
        var neutral = AdjustmentSettings()
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: neutral, automatic: nil), 9)

        neutral.facialZonal = FacialZonalRefinementSettings(enabled: false, eyeBags: 0.5)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: neutral, automatic: nil), 9)

        var active = AdjustmentSettings()
        active.facialZonal = FacialZonalRefinementSettings(enabled: true, eyeBags: 0.5)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: active, automatic: nil), 17)

        var v16Recipe = Recipe(adjustments: active)
        v16Recipe.version = 16
        XCTAssertThrowsError(try v16Recipe.validateVersion()) { error in
            guard case AtelierError.invalidConfiguration(let msg) = error else {
                XCTFail("Expected invalidConfiguration but got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("版本 17"))
        }

        var v17Recipe = Recipe(adjustments: active)
        v17Recipe.version = 17
        XCTAssertNoThrow(try v17Recipe.validateVersion())

        // Neutral facial zonal should not trigger v17 requirement on older recipes
        var neutralSettings = AdjustmentSettings()
        neutralSettings.facialZonal = FacialZonalRefinementSettings(enabled: false, eyeBags: 0.5)
        var olderRecipe = Recipe(adjustments: neutralSettings)
        olderRecipe.version = 16
        XCTAssertNoThrow(try olderRecipe.validateVersion())
    }

    func testLegacyRecipeRoundTrip() throws {
        let baseRecipe = Recipe()
        let encoder = JSONEncoder()
        let data = try encoder.encode(baseRecipe)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Recipe.self, from: data)
        XCTAssertNil(decoded.adjustments.facialZonal)

        var custom = Recipe()
        custom.version = 17
        custom.adjustments.facialZonal = FacialZonalRefinementSettings(
            enabled: true,
            darkCircles: 0.60,
            eyeBags: 0.50,
            nasolabialFolds: 0.40,
            foreheadWrinkles: 0.30,
            antiShine: 0.70,
            jawlineSculpting: 0.50,
            texturePreservation: 0.80
        )
        let customData = try encoder.encode(custom)
        let decodedCustom = try decoder.decode(Recipe.self, from: customData)
        XCTAssertEqual(decodedCustom.adjustments.facialZonal, custom.adjustments.facialZonal)
        XCTAssertEqual(decodedCustom.version, 17)
    }

    func testNeutralSettingsLeavePixelsCompletelyUnchanged() throws {
        let width = 64
        let height = 64
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let original = CIImage(color: CIColor(red: 0.75, green: 0.55, blue: 0.45)).cropped(to: extent)

        let faceBox = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let face = FaceLandmarkSet(boundingBox: faceBox, confidence: 0.95)

        let neutralDisabled = FacialZonalRefinementSettings(enabled: false, eyeBags: 0.5)
        let resultDisabled = try FacialZonalRefinementEngine.apply(
            original, settings: neutralDisabled, faceLandmarks: [face], context: context
        )
        XCTAssertFalse(resultDisabled.report.applied)
        XCTAssertEqual(measureMaxDifference(a: original, b: resultDisabled.image, extent: extent), 0.0)

        let neutralZeros = FacialZonalRefinementSettings(enabled: true)
        let resultZeros = try FacialZonalRefinementEngine.apply(
            original, settings: neutralZeros, faceLandmarks: [face], context: context
        )
        XCTAssertFalse(resultZeros.report.applied)
        XCTAssertEqual(measureMaxDifference(a: original, b: resultZeros.image, extent: extent), 0.0)
    }

    /// R3 (2026-11-14): the zonal kernel used to return
    /// `clamp(current, 0.0, 1.0)` for every pixel of the photograph. The engine
    /// works in extended-linear-sRGB, where a real specular highlight exceeds
    /// 1.0, so enabling any zone silently clipped every highlight in the frame -
    /// including background and hair far from the face. Pixels outside the zone
    /// masks must pass through bit-identical, extended range included.
    func testHighlightsOutsideZoneMasksAreNeverClipped() throws {
        let width = 128, height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        // A flat face region plus a 1.4-linear highlight strip outside it.
        var components = [Float]()
        components.reserveCapacity(width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                // Row 0 is the top row; keep the strip near the top edge, well
                // outside the face box below it.
                let bright = row < 8
                let value: Float = bright ? 1.4 : 0.18
                components.append(value)
                components.append(value * (bright ? 1.35 : 0.62))
                components.append(value * (bright ? 1.25 : 0.45))
                components.append(1)
            }
        }
        let data = components.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        let source = CIImage(bitmapData: data,
                             bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                             size: CGSize(width: width, height: height),
                             format: .RGBAf,
                             colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)

        let face = FaceLandmarkSet(boundingBox: CGRect(x: 0.25, y: 0.15, width: 0.5, height: 0.5),
                                   confidence: 0.95)
        let settings = FacialZonalRefinementSettings(enabled: true, eyeBags: 1.0,
                                                     nasolabialFolds: 1.0, antiShine: 1.0)
        let result = try FacialZonalRefinementEngine.apply(
            source, settings: settings, faceLandmarks: [face], context: context)
        XCTAssertTrue(result.report.applied)

        func render(_ image: CIImage) -> [Float] {
            var buffer = [Float](repeating: 0, count: width * height * 4)
            buffer.withUnsafeMutableBytes { pointer in
                context.render(image, toBitmap: pointer.baseAddress!, rowBytes: width * 16,
                               bounds: extent, format: .RGBAf,
                               colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            }
            return buffer
        }
        let before = render(source)
        let after = render(result.image)
        var maximumDifference: Float = 0
        for row in 0..<8 {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                for channel in 0..<3 {
                    maximumDifference = max(maximumDifference,
                                            abs(before[offset + channel] - after[offset + channel]))
                }
            }
        }
        XCTAssertLessThan(maximumDifference, 1e-6,
                          "extended-range highlights outside every zone mask must be untouched")
        XCTAssertGreaterThan(after[(2 * width + 10) * 4], 1.3,
                             "the highlight itself must still be above 1.0 (not clipped)")
    }

    func testGracefulSkipWhenNoFaceDetected() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let original = CIImage(color: CIColor(red: 0.7, green: 0.5, blue: 0.4)).cropped(to: extent)

        let settings = FacialZonalRefinementSettings(enabled: true, eyeBags: 0.8)
        let resultNoFaces = try FacialZonalRefinementEngine.apply(
            original, settings: settings, faceLandmarks: [], context: context
        )
        XCTAssertFalse(resultNoFaces.report.applied)
        XCTAssertTrue(resultNoFaces.report.note?.contains("未检测到可用人脸") == true)
        XCTAssertEqual(measureMaxDifference(a: original, b: resultNoFaces.image, extent: extent), 0.0)

        let resultNilFaces = try FacialZonalRefinementEngine.apply(
            original, settings: settings, faceLandmarks: nil, context: context
        )
        XCTAssertFalse(resultNilFaces.report.applied)
    }

    func testEyeBagsLiftingReducesTroughShadow() throws {
        let width = 128
        let height = 128

        let faceBox = CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60)
        let face = FaceLandmarkSet(boundingBox: faceBox, confidence: 0.95)

        let image = createRGBImage(width: width, height: height) { x, y in
            let isUnderEye = (x >= 40 && x <= 88) && (y >= 60 && y <= 66)
            let shadow = isUnderEye ? 0.30 : 0.0
            return (r: 0.75 - shadow, g: 0.58 - shadow, b: 0.48 - shadow)
        }

        let settings = FacialZonalRefinementSettings(
            enabled: true,
            eyeBags: 0.90,
            texturePreservation: 0.20
        )

        let result = try FacialZonalRefinementEngine.apply(
            image, settings: settings, faceLandmarks: [face], context: context
        )

        XCTAssertTrue(result.report.applied)
        XCTAssertTrue(result.report.appliedSteps.contains("eyeBags"))

        let testRect = CGRect(x: 48, y: 58, width: 32, height: 12)
        let bitmapBefore = renderBitmap(image, width: width, height: height)
        let bitmapAfter = renderBitmap(result.image, width: width, height: height)

        let contrastBefore = measureVerticalContrast(from: bitmapBefore, width: width, rect: testRect)
        let contrastAfter = measureVerticalContrast(from: bitmapAfter, width: width, rect: testRect)

        XCTAssertGreaterThan(contrastBefore, 0.05, "Contrast before must be detectable")
        XCTAssertLessThan(contrastAfter, contrastBefore * 0.85,
                          "Eye bags lifting must reduce under-eye trough shadow (before=\(contrastBefore), after=\(contrastAfter))")
    }

    func testDarkCirclesNeutralization() throws {
        let width = 128
        let height = 128

        let faceBox = CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60)
        let face = FaceLandmarkSet(boundingBox: faceBox, confidence: 0.95)

        let image = createRGBImage(width: width, height: height) { x, y in
            let isDarkCircle = (x >= 35 && x <= 93) && (y >= 56 && y <= 66)
            if isDarkCircle {
                return (r: 0.45, g: 0.42, b: 0.52)
            } else {
                return (r: 0.76, g: 0.58, b: 0.48)
            }
        }

        let settings = FacialZonalRefinementSettings(
            enabled: true,
            darkCircles: 0.90,
            texturePreservation: 0.20
        )

        let result = try FacialZonalRefinementEngine.apply(
            image, settings: settings, faceLandmarks: [face], context: context
        )

        XCTAssertTrue(result.report.applied)
        XCTAssertTrue(result.report.appliedSteps.contains("darkCircles"))

        let bitmapBefore = renderBitmap(image, width: width, height: height)
        let bitmapAfter = renderBitmap(result.image, width: width, height: height)

        let originalProbe = samplePixel(from: bitmapBefore, width: width, x: 50, y: 60)
        let probe = samplePixel(from: bitmapAfter, width: width, x: 50, y: 60)

        XCTAssertGreaterThan(probe.r, originalProbe.r, "Dark circle red channel must be lifted (before=\(originalProbe.r), after=\(probe.r))")
        XCTAssertGreaterThan(probe.r, probe.b, "Dark circle must be warmed so R > B instead of bluish R < B")
    }

    func testNasolabialFoldsSmoothing() throws {
        let width = 128
        let height = 128

        let faceBox = CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60)
        let face = FaceLandmarkSet(boundingBox: faceBox, confidence: 0.95)

        let image = createRGBImage(width: width, height: height) { x, y in
            // R3 (2026-11-14): the fixture row index is top-down (bitmap row 0
            // is the top row), while the zone masks live in Core Image's
            // bottom-up coordinates. The fold therefore has to be drawn in the
            // rows the nasolabial mask actually covers (below the nose, above
            // the mouth corner) — before R3 the assertion only passed because
            // the engine blurred the whole frame.
            let isSmileLine = (x >= 48 && x <= 54) && (y >= 68 && y <= 78)
            let dip = isSmileLine ? 0.25 : 0.0
            return (r: 0.75 - dip, g: 0.58 - dip, b: 0.48 - dip)
        }

        let settings = FacialZonalRefinementSettings(
            enabled: true,
            nasolabialFolds: 0.90,
            texturePreservation: 0.20
        )

        let result = try FacialZonalRefinementEngine.apply(
            image, settings: settings, faceLandmarks: [face], context: context
        )

        XCTAssertTrue(result.report.applied)
        XCTAssertTrue(result.report.appliedSteps.contains("nasolabialFolds"))

        let foldRect = CGRect(x: 44, y: 68, width: 16, height: 8)
        let bitmapBefore = renderBitmap(image, width: width, height: height)
        let bitmapAfter = renderBitmap(result.image, width: width, height: height)

        let contrastBefore = measureHorizontalContrast(from: bitmapBefore, width: width, rect: foldRect)
        let contrastAfter = measureHorizontalContrast(from: bitmapAfter, width: width, rect: foldRect)

        XCTAssertGreaterThan(contrastBefore, 0.05, "Contrast before must be detectable")
        XCTAssertLessThan(contrastAfter, contrastBefore * 0.88,
                          "Nasolabial folds smoothing must reduce crease contrast (before=\(contrastBefore), after=\(contrastAfter))")
    }

    func testForeheadWrinklesSmoothing() throws {
        let width = 128
        let height = 128

        let faceBox = CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60)
        let face = FaceLandmarkSet(boundingBox: faceBox, confidence: 0.95)

        let image = createRGBImage(width: width, height: height) { x, y in
            // R3: the wrinkle has to sit in the rows the forehead zone covers
            // (above the brow line), not at the chin.
            let isWrinkle = (y >= 38 && y <= 42) && (x >= 35 && x <= 93)
            let dip = isWrinkle ? 0.25 : 0.0
            return (r: 0.75 - dip, g: 0.58 - dip, b: 0.48 - dip)
        }

        let settings = FacialZonalRefinementSettings(
            enabled: true,
            foreheadWrinkles: 0.90,
            texturePreservation: 0.20
        )

        let result = try FacialZonalRefinementEngine.apply(
            image, settings: settings, faceLandmarks: [face], context: context
        )

        XCTAssertTrue(result.report.applied)
        XCTAssertTrue(result.report.appliedSteps.contains("foreheadWrinkles"))

        let foreheadRect = CGRect(x: 45, y: 34, width: 38, height: 12)
        let bitmapBefore = renderBitmap(image, width: width, height: height)
        let bitmapAfter = renderBitmap(result.image, width: width, height: height)

        let contrastBefore = measureVerticalContrast(from: bitmapBefore, width: width, rect: foreheadRect)
        let contrastAfter = measureVerticalContrast(from: bitmapAfter, width: width, rect: foreheadRect)

        XCTAssertGreaterThan(contrastBefore, 0.05, "Contrast before must be detectable")
        XCTAssertLessThan(contrastAfter, contrastBefore * 0.85,
                          "Forehead wrinkle smoothing must soften horizontal crease (before=\(contrastBefore), after=\(contrastAfter))")
    }

    func testAntiShineCompressesSpecularGreaseHotspot() throws {
        let width = 128
        let height = 128

        let faceBox = CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60)
        let face = FaceLandmarkSet(boundingBox: faceBox, confidence: 0.95)

        let image = createRGBImage(width: width, height: height) { x, y in
            // R3: the specular hotspot has to sit in the anti-shine (T-zone)
            // mask, which covers the forehead and nose bridge.
            let isHotspot = (x >= 60 && x <= 68) && (y >= 38 && y <= 44)
            if isHotspot {
                return (r: 0.96, g: 0.95, b: 0.94)
            } else {
                return (r: 0.75, g: 0.58, b: 0.48)
            }
        }

        let settings = FacialZonalRefinementSettings(
            enabled: true,
            antiShine: 0.90,
            texturePreservation: 0.20
        )

        let result = try FacialZonalRefinementEngine.apply(
            image, settings: settings, faceLandmarks: [face], context: context
        )

        XCTAssertTrue(result.report.applied)
        XCTAssertTrue(result.report.appliedSteps.contains("antiShine"))

        let bitmapBefore = renderBitmap(image, width: width, height: height)
        let bitmapAfter = renderBitmap(result.image, width: width, height: height)

        let originalProbe = samplePixel(from: bitmapBefore, width: width, x: 64, y: 41)
        let shineProbe = samplePixel(from: bitmapAfter, width: width, x: 64, y: 41)

        XCTAssertGreaterThan(originalProbe.r, 0.85, "Original probe must be bright specular")
        XCTAssertLessThan(shineProbe.r, originalProbe.r * 0.97,
                          "Anti-shine must compress specular peak brightness (before=\(originalProbe.r), after=\(shineProbe.r))")
    }

    func testDoubleChinJawlineSculpting() throws {
        let width = 128
        let height = 128

        let faceBox = CGRect(x: 0.20, y: 0.25, width: 0.60, height: 0.60)
        let face = FaceLandmarkSet(boundingBox: faceBox, confidence: 0.95)

        let image = createRGBImage(width: width, height: height) { x, y in
            // R3: the submental crease belongs below the chin, which is where
            // the jawline zone mask is.
            let isSubmentalCrease = (y >= 99 && y <= 105) && (x >= 45 && x <= 83)
            let shadow = isSubmentalCrease ? 0.30 : 0.0
            return (r: 0.75 - shadow, g: 0.58 - shadow, b: 0.48 - shadow)
        }

        let settings = FacialZonalRefinementSettings(
            enabled: true,
            jawlineSculpting: 0.90,
            texturePreservation: 0.20
        )

        let result = try FacialZonalRefinementEngine.apply(
            image, settings: settings, faceLandmarks: [face], context: context
        )

        XCTAssertTrue(result.report.applied)
        XCTAssertTrue(result.report.appliedSteps.contains("jawlineSculpting"))

        let chinRect = CGRect(x: 50, y: 96, width: 28, height: 12)
        let bitmapBefore = renderBitmap(image, width: width, height: height)
        let bitmapAfter = renderBitmap(result.image, width: width, height: height)

        let contrastBefore = measureVerticalContrast(from: bitmapBefore, width: width, rect: chinRect)
        let contrastAfter = measureVerticalContrast(from: bitmapAfter, width: width, rect: chinRect)

        XCTAssertGreaterThan(contrastBefore, 0.05, "Contrast before must be detectable")
        XCTAssertLessThan(contrastAfter, contrastBefore * 0.85,
                          "Jawline sculpting must soften submental shadow crease (before=\(contrastBefore), after=\(contrastAfter))")
    }

    // MARK: - Test Helpers

    private func createRGBImage(width: Int, height: Int, colorAt: (Int, Int) -> (r: Double, g: Double, b: Double)) -> CIImage {
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = colorAt(x, y)
                let idx = (y * width + x) * 4
                pixelData[idx + 0] = UInt8(max(0, min(255, (c.r * 255.0).rounded())))
                pixelData[idx + 1] = UInt8(max(0, min(255, (c.g * 255.0).rounded())))
                pixelData[idx + 2] = UInt8(max(0, min(255, (c.b * 255.0).rounded())))
                pixelData[idx + 3] = 255
            }
        }
        let data = Data(pixelData)
        return CIImage(
            bitmapData: data,
            bytesPerRow: width * 4,
            size: CGSize(width: width, height: height),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
    }

    private func renderBitmap(_ image: CIImage, width: Int = 128, height: Int = 128) -> [UInt8] {
        var bitmap = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &bitmap, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return bitmap
    }

    private func samplePixel(from bitmap: [UInt8], width: Int = 128, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
        let idx = (y * width + x) * 4
        return (Double(bitmap[idx]) / 255.0, Double(bitmap[idx + 1]) / 255.0, Double(bitmap[idx + 2]) / 255.0)
    }

    private func measureVerticalContrast(from bitmap: [UInt8], width: Int = 128, rect: CGRect) -> Double {
        let minX = Int(rect.minX), maxX = Int(rect.maxX)
        let minY = Int(rect.minY), maxY = Int(rect.maxY)
        let h = maxY - minY
        let w = maxX - minX
        guard w > 0, h > 0 else { return 0 }

        var rowLumas = [Double](repeating: 0, count: h)
        for (i, y) in (minY..<maxY).enumerated() {
            var sum = 0.0
            for x in minX..<maxX {
                let idx = (y * width + x) * 4
                let luma = 0.2126 * Double(bitmap[idx]) + 0.7152 * Double(bitmap[idx + 1]) + 0.0722 * Double(bitmap[idx + 2])
                sum += luma
            }
            rowLumas[i] = sum / Double(w)
        }
        let maxLuma = rowLumas.max() ?? 0
        let minLuma = rowLumas.min() ?? 0
        return maxLuma - minLuma
    }

    private func measureHorizontalContrast(from bitmap: [UInt8], width: Int = 128, rect: CGRect) -> Double {
        let minX = Int(rect.minX), maxX = Int(rect.maxX)
        let minY = Int(rect.minY), maxY = Int(rect.maxY)
        let h = maxY - minY
        let w = maxX - minX
        guard w > 0, h > 0 else { return 0 }

        var colLumas = [Double](repeating: 0, count: w)
        for (i, x) in (minX..<maxX).enumerated() {
            var sum = 0.0
            for y in minY..<maxY {
                let idx = (y * width + x) * 4
                let luma = 0.2126 * Double(bitmap[idx]) + 0.7152 * Double(bitmap[idx + 1]) + 0.0722 * Double(bitmap[idx + 2])
                sum += luma
            }
            colLumas[i] = sum / Double(h)
        }
        let maxLuma = colLumas.max() ?? 0
        let minLuma = colLumas.min() ?? 0
        return maxLuma - minLuma
    }

    private func measureMaxDifference(a: CIImage, b: CIImage, extent: CGRect) -> Double {
        let w = Int(extent.width)
        let h = Int(extent.height)
        var bytesA = [UInt8](repeating: 0, count: w * h * 4)
        var bytesB = [UInt8](repeating: 0, count: w * h * 4)
        context.render(a, toBitmap: &bytesA, rowBytes: w * 4, bounds: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        context.render(b, toBitmap: &bytesB, rowBytes: w * 4, bounds: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)

        var maxDiff = 0
        for i in 0..<bytesA.count {
            let diff = abs(Int(bytesA[i]) - Int(bytesB[i]))
            if diff > maxDiff { maxDiff = diff }
        }
        return Double(maxDiff) / 255.0
    }
}

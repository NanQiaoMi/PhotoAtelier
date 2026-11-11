import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

/// Synthetic-fixture tests for C2 make-up tinting.
///
/// A painted face (skin ellipse + red lips + dark brows + eye dots) and hand-built
/// `FaceLandmarkSet` geometry feed `FaceSemanticAnalyzer`; no Vision/private photos
/// are involved. Assertions prove neutral identity, region selectivity, colour
/// bounds, multi-face application, determinism and NaN protection — **not** a
/// real-photo aesthetic evaluation (heuristic v1 make-up, non-professional).
final class MakeupEngineTests: XCTestCase {
    private typealias RGBA = (r: Float, g: Float, b: Float, a: Float)

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: true,
        .cacheIntermediates: false
    ])

    // MARK: - Painted fixtures

    private func makeImage(width: Int, height: Int,
                           pixel: (Int, Int) -> RGBA) -> CIImage {
        var components = [Float]()
        components.reserveCapacity(width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let value = pixel(column, row)
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
                       size: CGSize(width: CGFloat(width), height: CGFloat(height)),
                       format: .RGBAf, colorSpace: linearColorSpace)
    }

    /// One synthetic face: skin oval, red lips, dark brows, dark eyes.
    private func paintedFace(centerX: Double = 0.5, centerY: Double = 0.5,
                             scale: Double = 1.0,
                             lipColor: RGBA = (0.62, 0.12, 0.16, 1),
                             browColor: RGBA = (0.09, 0.07, 0.06, 1),
                             faceColor: RGBA = (0.68, 0.52, 0.42, 1)) -> CIImage {
        makeImage(width: 256, height: 256) { column, row in
            let x = (Double(column) + 0.5) / 256
            // Core Image bitmap row 0 is the TOP row; landmarks use bottom-left
            // normalized coordinates, so flip y here.
            let y = 1 - (Double(row) + 0.5) / 256
            func dx(_ value: Double, _ center: Double, _ radius: Double) -> Double {
                (value - center) / (radius * scale)
            }
            let face = dx(x, centerX, 0.30) * dx(x, centerX, 0.30)
                + dx(y, centerY, 0.36) * dx(y, centerY, 0.36)
            guard face <= 1 else { return (0.34, 0.33, 0.31, 1) }
            let lips = dx(x, centerX, 0.09) * dx(x, centerX, 0.09)
                + dx(y, centerY - 0.08 * scale, 0.028) * dx(y, centerY - 0.08 * scale, 0.028)
            if lips <= 1 { return lipColor }
            let leftBrow = dx(x, centerX - 0.08 * scale, 0.075) * dx(x, centerX - 0.08 * scale, 0.075)
                + dx(y, centerY + 0.10 * scale, 0.014) * dx(y, centerY + 0.10 * scale, 0.014)
            let rightBrow = dx(x, centerX + 0.08 * scale, 0.075) * dx(x, centerX + 0.08 * scale, 0.075)
                + dx(y, centerY + 0.10 * scale, 0.014) * dx(y, centerY + 0.10 * scale, 0.014)
            if leftBrow <= 1 || rightBrow <= 1 { return browColor }
            let leftEye = dx(x, centerX - 0.08 * scale, 0.045) * dx(x, centerX - 0.08 * scale, 0.045)
                + dx(y, centerY + 0.05 * scale, 0.018) * dx(y, centerY + 0.05 * scale, 0.018)
            let rightEye = dx(x, centerX + 0.08 * scale, 0.045) * dx(x, centerX + 0.08 * scale, 0.045)
                + dx(y, centerY + 0.05 * scale, 0.018) * dx(y, centerY + 0.05 * scale, 0.018)
            if leftEye <= 1 || rightEye <= 1 { return (0.07, 0.05, 0.05, 1) }
            return faceColor
        }
    }

    private func paintedDoubleFace() -> CIImage {
        makeImage(width: 384, height: 256) { column, row in
            let x = (Double(column) + 0.5) / 384
            let y = 1 - (Double(row) + 0.5) / 256
            // Two smaller faces at x = 0.28 and 0.72.
            for faceX in [0.28, 0.72] {
                let face = ((x - faceX) / 0.16) * ((x - faceX) / 0.16)
                    + ((y - 0.5) / 0.34) * ((y - 0.5) / 0.34)
                guard face <= 1 else { continue }
                let lips = ((x - faceX) / 0.05) * ((x - faceX) / 0.05)
                    + ((y - 0.44) / 0.016) * ((y - 0.44) / 0.016)
                if lips <= 1 { return (0.62, 0.12, 0.16, 1) }
                return (0.68, 0.52, 0.42, 1)
            }
            return (0.34, 0.33, 0.31, 1)
        }
    }

    /// Ellipse polygon in normalized bottom-left coordinates.
    private func ellipsePoints(center: CGPoint, rx: Double, ry: Double,
                               count: Int = 24) -> [CGPoint] {
        (0..<count).map { index in
            let angle = Double(index) / Double(count) * 2 * Double.pi
            return CGPoint(x: center.x + CGFloat(cos(angle) * rx),
                           y: center.y + CGFloat(sin(angle) * ry))
        }
    }

    private func rectanglePoints(center: CGPoint, halfWidth: Double,
                                 halfHeight: Double) -> [CGPoint] {
        [CGPoint(x: center.x - CGFloat(halfWidth), y: center.y - CGFloat(halfHeight)),
         CGPoint(x: center.x + CGFloat(halfWidth), y: center.y - CGFloat(halfHeight)),
         CGPoint(x: center.x + CGFloat(halfWidth), y: center.y + CGFloat(halfHeight)),
         CGPoint(x: center.x - CGFloat(halfWidth), y: center.y + CGFloat(halfHeight))]
    }

    /// Landmarks matching `paintedFace` (geometry is normalized to the image).
    private func faceLandmarks(centerX: CGFloat = 0.5, centerY: CGFloat = 0.5,
                               scale: CGFloat = 1) -> FaceLandmarkSet {
        let center = CGPoint(x: centerX, y: centerY)
        let lipCenter = CGPoint(x: centerX, y: centerY - 0.08 * scale)
        let leftEyeCenter = CGPoint(x: centerX - 0.08 * scale, y: centerY + 0.05 * scale)
        let rightEyeCenter = CGPoint(x: centerX + 0.08 * scale, y: centerY + 0.05 * scale)
        let leftBrowCenter = CGPoint(x: centerX - 0.08 * scale, y: centerY + 0.10 * scale)
        let rightBrowCenter = CGPoint(x: centerX + 0.08 * scale, y: centerY + 0.10 * scale)
        return FaceLandmarkSet(
            boundingBox: CGRect(x: centerX - 0.30 * scale, y: centerY - 0.36 * scale,
                                width: 0.60 * scale, height: 0.72 * scale),
            confidence: 1,
            faceContour: ellipsePoints(center: center, rx: 0.30 * Double(scale),
                                       ry: 0.36 * Double(scale), count: 32),
            leftEye: ellipsePoints(center: leftEyeCenter, rx: 0.045, ry: 0.018),
            rightEye: ellipsePoints(center: rightEyeCenter, rx: 0.045, ry: 0.018),
            leftEyebrow: rectanglePoints(center: leftBrowCenter, halfWidth: 0.075,
                                         halfHeight: 0.014),
            rightEyebrow: rectanglePoints(center: rightBrowCenter, halfWidth: 0.075,
                                          halfHeight: 0.014),
            nose: ellipsePoints(center: CGPoint(x: centerX, y: centerY - 0.02),
                                rx: 0.03, ry: 0.04),
            outerLips: ellipsePoints(center: lipCenter, rx: 0.09, ry: 0.028),
            innerLips: ellipsePoints(center: lipCenter, rx: 0.055, ry: 0.012),
            leftPupil: leftEyeCenter,
            rightPupil: rightEyeCenter)
    }

    private func doubleFaceLandmarks() -> [FaceLandmarkSet] {
        [faceLandmarks(centerX: 0.28, centerY: 0.5, scale: 0.6),
         faceLandmarks(centerX: 0.72, centerY: 0.5, scale: 0.6)]
    }

    // MARK: - Sampling

    private func render(_ image: CIImage) -> [Float] {
        let width = Int(image.extent.width.rounded())
        let height = Int(image.extent.height.rounded())
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: image.extent, format: .RGBAf, colorSpace: linearColorSpace)
        }
        return pixels
    }

    private func renderPixel(_ image: CIImage, x: Int, y: Int) -> [Float] {
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!,
                           rowBytes: 4 * MemoryLayout<Float>.stride,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBAf, colorSpace: linearColorSpace)
        }
        return values
    }

    private func colorDistance(_ first: [Float], _ second: [Float]) -> Double {
        let dr = Double(first[0] - second[0])
        let dg = Double(first[1] - second[1])
        let db = Double(first[2] - second[2])
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    private func luminance(_ values: [Float]) -> Double {
        0.2126 * Double(values[0]) + 0.7152 * Double(values[1]) + 0.0722 * Double(values[2])
    }

    private func maximumDifference(_ first: [Float], _ second: [Float]) -> Float {
        guard first.count == second.count else { return .greatestFiniteMagnitude }
        var maximum: Float = 0
        for index in first.indices {
            maximum = max(maximum, abs(first[index] - second[index]))
        }
        return maximum
    }

    // MARK: - Neutral identity

    func testNeutralSettingsAreExactIdentity() throws {
        let source = paintedFace()
        let baseline = render(source)
        let neutral = MakeupSettings()
        XCTAssertTrue(neutral.isNeutral)
        XCTAssertNoThrow(try neutral.validated())
        let output = try MakeupEngine.apply(to: source, faces: [faceLandmarks()],
                                            settings: neutral)
        XCTAssertEqual(maximumDifference(baseline, render(output)), 0,
                       "中性妆容必须不改变任何像素")
        // Neutral settings must not require a face at all.
        XCTAssertNoThrow(try MakeupEngine.apply(to: source, faces: [], settings: neutral))
    }

    // MARK: - Region selectivity

    func testLipTintChangesLipsAndLeavesOtherRegionsNearlyUntouched() throws {
        let source = paintedFace()
        let baselinePixels = render(source)
        var settings = MakeupSettings(lipColor: SRGBColor(red: 0.90, green: 0.10, blue: 0.25),
                                      lipIntensity: 0.85)
        let output = try MakeupEngine.apply(to: source, faces: [faceLandmarks()],
                                            settings: settings)
        // Sample the lip ring (between the outer and inner lip polygons): the
        // semantic lip matte intentionally excludes the inner/teeth region.
        let lipRingX = Int((0.5 + 0.075) * 256)
        let lip = renderPixel(output, x: lipRingX, y: 107)
        let lipBefore = renderPixel(source, x: lipRingX, y: 107)
        XCTAssertGreaterThan(colorDistance(lip, lipBefore), 0.03, "唇部环带应明显变化")

        // Background corner and a skin area away from lips stay bounded.
        let corner = renderPixel(output, x: 8, y: 8)
        let cornerBefore = renderPixel(source, x: 8, y: 8)
        XCTAssertLessThan(colorDistance(corner, cornerBefore), 1e-4, "背景不应被妆容影响")
        let skin = renderPixel(output, x: 200, y: 128)
        let skinBefore = renderPixel(source, x: 200, y: 128)
        XCTAssertLessThan(colorDistance(skin, skinBefore), 0.02, "非唇部皮肤变化应受限")

        // Determinism.
        let again = try MakeupEngine.apply(to: source, faces: [faceLandmarks()],
                                           settings: settings)
        XCTAssertEqual(maximumDifference(render(output), render(again)), 0)
        XCTAssertEqual(render(output).count, baselinePixels.count)
    }

    func testBrowDensityDarkensBrowsOnly() throws {
        let source = paintedFace()
        let settings = MakeupSettings(browDensity: 0.8)
        let output = try MakeupEngine.apply(to: source, faces: [faceLandmarks()],
                                            settings: settings)
        let browBefore = renderPixel(source, x: 107, y: 153)
        let browAfter = renderPixel(output, x: 107, y: 153)
        XCTAssertLessThan(luminance(browAfter), luminance(browBefore) - 0.01,
                          "眉色密度应使眉毛区域变暗")
        let lipBefore = renderPixel(source, x: 128, y: 107)
        let lipAfter = renderPixel(output, x: 128, y: 107)
        XCTAssertLessThan(colorDistance(lipAfter, lipBefore), 0.02, "眉妆不应改动唇部")
        let cornerBefore = renderPixel(source, x: 10, y: 10)
        let cornerAfter = renderPixel(output, x: 10, y: 10)
        XCTAssertLessThan(colorDistance(cornerAfter, cornerBefore), 1e-4)
    }

    func testCheekAndEyeshadowAreLocalToTheirRegions() throws {
        let source = paintedFace()
        // Cheek: derived from face bbox (midX ±0.38·w, midY −0.02·h).
        let cheek = MakeupSettings(cheekColor: SRGBColor(red: 0.95, green: 0.35, blue: 0.40),
                                   cheekIntensity: 0.7)
        let cheekOutput = try MakeupEngine.apply(to: source, faces: [faceLandmarks()],
                                                 settings: cheek)
        let cheekX = Int((0.5 - 0.38 * 0.60) * 256)
        let cheekY = Int((0.5 - 0.02 * 0.72) * 256)
        let cheekAfter = renderPixel(cheekOutput, x: cheekX, y: cheekY)
        let cheekBefore = renderPixel(source, x: cheekX, y: cheekY)
        XCTAssertGreaterThan(colorDistance(cheekAfter, cheekBefore), 0.01,
                             "腮红中心应变化")
        let lipBefore = renderPixel(source, x: 128, y: 107)
        let lipAfter = renderPixel(cheekOutput, x: 128, y: 107)
        XCTAssertLessThan(colorDistance(lipAfter, lipBefore), 0.02, "腮红不应改动唇部")

        // Eyeshadow: eyelid band above the eye box.
        let eyeshadow = MakeupSettings(eyeshadowColor: SRGBColor(red: 0.45, green: 0.25, blue: 0.65),
                                       eyeshadowIntensity: 0.8)
        let eyeOutput = try MakeupEngine.apply(to: source, faces: [faceLandmarks()],
                                               settings: eyeshadow)
        let eyeX = Int((0.5 - 0.08) * 256)
        let eyelidCenterY = 0.5 + 0.05
        let eyelidOffset = 0.30 * 0.036
        let eyeY = Int((eyelidCenterY + eyelidOffset) * 256)
        let eyeAfter = renderPixel(eyeOutput, x: eyeX, y: eyeY)
        let eyeBefore = renderPixel(source, x: eyeX, y: eyeY)
        XCTAssertGreaterThan(colorDistance(eyeAfter, eyeBefore), 0.01, "眼影区域应变化")
        let noseAfter = renderPixel(eyeOutput, x: 128, y: 90)
        let noseBefore = renderPixel(source, x: 128, y: 90)
        XCTAssertLessThan(colorDistance(noseAfter, noseBefore), 0.02, "眼影不应扩散到鼻部")
    }

    func testMultipleFacesBothReceiveLipTint() throws {
        let source = paintedDoubleFace()
        let settings = MakeupSettings(lipIntensity: 0.8)
        let output = try MakeupEngine.apply(to: source, faces: doubleFaceLandmarks(),
                                            settings: settings)
        for faceX in [0.28, 0.72] {
            let x = Int(faceX * 384)
            let y = Int(0.44 * 256)
            let before = renderPixel(source, x: x, y: y)
            let after = renderPixel(output, x: x, y: y)
            XCTAssertGreaterThan(colorDistance(after, before), 0.02,
                                 "两张脸的唇部都应被上色（x=\\(x)）")
        }
        // Background between the faces stays untouched.
        let between = renderPixel(output, x: 192, y: 8)
        let betweenBefore = renderPixel(source, x: 192, y: 8)
        XCTAssertLessThan(colorDistance(between, betweenBefore), 1e-4)
    }

    // MARK: - Boundaries / validation / failure

    func testValidationRejectsOutOfRangeColoursIntensitiesAndNaN() {
        XCTAssertThrowsError(try MakeupSettings(lipIntensity: 1.2).validated())
        XCTAssertThrowsError(try MakeupSettings(lipIntensity: -0.1).validated())
        XCTAssertThrowsError(try MakeupSettings(browDensity: Double.nan).validated())
        XCTAssertThrowsError(try MakeupSettings(cheekIntensity: Double.infinity).validated())
        XCTAssertThrowsError(try MakeupSettings(cheekRadius: 0.1).validated())
        XCTAssertThrowsError(try MakeupSettings(cheekRadius: 1.5).validated())
        XCTAssertThrowsError(try MakeupSettings(
            lipColor: SRGBColor(red: 1.2, green: 0, blue: 0)).validated())
        XCTAssertThrowsError(try MakeupSettings(
            eyeshadowColor: SRGBColor(red: .nan, green: 0, blue: 0)).validated())
        // Valid boundaries are accepted.
        XCTAssertNoThrow(try MakeupSettings(lipIntensity: 0).validated())
        XCTAssertNoThrow(try MakeupSettings(lipIntensity: 1, browDensity: 1,
                                            cheekIntensity: 1, cheekRadius: 0.2,
                                            eyeshadowIntensity: 1).validated())
        XCTAssertNoThrow(try MakeupSettings(cheekRadius: 1.0).validated())
        XCTAssertNoThrow(try MakeupSettings(
            lipColor: SRGBColor(red: 0, green: 0, blue: 0)).validated())
    }

    func testNoFaceFailsExplicitlyAndNaNLandmarksDoNotCrash() throws {
        let blank = makeImage(width: 64, height: 64) { _, _ in (0.5, 0.5, 0.5, 1) }
        var settings = MakeupSettings(lipIntensity: 0.5)
        XCTAssertThrowsError(try MakeupEngine.apply(to: blank, faces: [], settings: settings)) {
            XCTAssertTrue($0.localizedDescription.contains("人脸"),
                          "无脸时妆容必须显式报错：\($0.localizedDescription)")
        }

        // Landmarks with a few non-finite points still work (filtered by the
        // semantic analyzer) and never derive NaN pixels.
        var landmarks = faceLandmarks()
        landmarks.faceContour[0] = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
        landmarks.leftEyebrow[0] = CGPoint(x: .infinity, y: 0.5)
        landmarks.outerLips[1] = CGPoint(x: .nan, y: 0.4)
        settings = MakeupSettings(lipIntensity: 0.5, browDensity: 0.3,
                                  cheekIntensity: 0.4, eyeshadowIntensity: 0.4)
        let output = try MakeupEngine.apply(to: paintedFace(), faces: [landmarks],
                                            settings: settings)
        for value in render(output) where !value.isFinite {
            XCTFail("妆容输出包含非有限像素")
            break
        }
    }

    // MARK: - Round-2 review regressions

    func testFallbackPolygonMasksCoverPaleLipsAndLightBrows() throws {
        // Lips and brows have the SAME colour as skin, so FaceSemanticAnalysis
        // returns non-nil all-zero colour-gated mattes. The engine must detect the
        // empty coverage and fall back to the landmark polygons instead of silently
        // doing nothing.
        let source = paintedFace(lipColor: (0.68, 0.52, 0.42, 1),
                                 browColor: (0.68, 0.52, 0.42, 1))
        let semantic = FaceSemanticAnalyzer.masks(in: source, landmarks: [faceLandmarks()])
        XCTAssertFalse(MakeupEngine.isUsableMask(semantic.lips),
                       "唇色=肤色时语义唇蒙版应为空（用于证明回退路径）")
        XCTAssertFalse(MakeupEngine.isUsableMask(semantic.brows),
                       "眉色=肤色时语义眉蒙版应为空（用于证明回退路径）")

        let settings = MakeupSettings(lipColor: SRGBColor(red: 0.90, green: 0.10, blue: 0.25),
                                      lipIntensity: 0.8,
                                      browColor: SRGBColor(red: 0.20, green: 0.12, blue: 0.08),
                                      browDensity: 0.8)
        let output = try MakeupEngine.apply(to: source, faces: [faceLandmarks()],
                                            settings: settings)
        let lipRingX = Int((0.5 + 0.075) * 256)
        let lip = renderPixel(output, x: lipRingX, y: 107)
        let lipBefore = renderPixel(source, x: lipRingX, y: 107)
        XCTAssertGreaterThan(colorDistance(lip, lipBefore), 0.02,
                             "颜色门控漏检时唇部仍应通过多边形回退上妆")

        let browAfter = renderPixel(output, x: 107, y: 153)
        let browBefore = renderPixel(source, x: 107, y: 153)
        XCTAssertLessThan(luminance(browAfter), luminance(browBefore) - 0.005,
                          "颜色门控漏检时眉部仍应通过多边形回退压暗")
    }

    func testNearBlackTintStillDarkensAndSaturatedTintStaysBounded() throws {
        let source = paintedFace()
        // Black lip colour + full intensity must visibly darken (not a silent no-op).
        let blackLips = MakeupSettings(lipColor: SRGBColor(red: 0, green: 0, blue: 0),
                                       lipIntensity: 1)
        let blackOutput = try MakeupEngine.apply(to: source, faces: [faceLandmarks()],
                                                 settings: blackLips)
        let lipRingX = Int((0.5 + 0.075) * 256)
        let blackLip = renderPixel(blackOutput, x: lipRingX, y: 107)
        let lipBefore = renderPixel(source, x: lipRingX, y: 107)
        XCTAssertLessThan(luminance(blackLip), luminance(lipBefore) - 0.01,
                          "近黑唇色 + 强度 1 应产生可见压暗，而不是静默 no-op")

        // Fully saturated tint may exceed 1 in linear light; the engine bounds it.
        let saturated = MakeupSettings(lipColor: SRGBColor(red: 1, green: 0, blue: 0),
                                       lipIntensity: 1)
        let saturatedOutput = try MakeupEngine.apply(to: source, faces: [faceLandmarks()],
                                                     settings: saturated)
        for value in render(saturatedOutput) {
            XCTAssertTrue(value.isFinite)
            if value > 1.5 + 1e-3 {
                XCTFail("饱和妆容输出线性分量应被限制在 1.5 内，实际 \(value)")
                break
            }
        }
    }

    func testBlushIsClippedToFaceRegionWhenSkinMaskIsUnavailable() throws {
        // Grey (non-skin) face → the colour-gated skin matte is empty. The blush
        // must still be clipped to the face region instead of spilling outside the
        // face box.
        let source = paintedFace(faceColor: (0.45, 0.45, 0.45, 1))
        var landmarks = faceLandmarks()
        landmarks.outerLips = []
        landmarks.innerLips = []
        let semantic = FaceSemanticAnalyzer.masks(in: source, landmarks: [landmarks])
        XCTAssertFalse(MakeupEngine.isUsableMask(semantic.skin),
                       "灰色脸应产生空的皮肤掩版（用于证明无 skin 约束的回退）")

        let settings = MakeupSettings(cheekColor: SRGBColor(red: 0.95, green: 0.30, blue: 0.35),
                                      cheekIntensity: 0.9)
        let output = try MakeupEngine.apply(to: source, faces: [landmarks],
                                            settings: settings)
        // Point inside the geometric cheek ellipse but outside the face bbox: it
        // must stay untouched because blush is clipped by the face region.
        let outsidePoint = (x: Int(0.83 * 256), y: 128)
        let outsideAfter = renderPixel(output, x: outsidePoint.x, y: outsidePoint.y)
        let outsideBefore = renderPixel(source, x: outsidePoint.x, y: outsidePoint.y)
        XCTAssertLessThan(colorDistance(outsideAfter, outsideBefore), 1e-4,
                          "无皮肤约束时腮红也不得溢出脸框")
        // And the blush centre inside the face still changes.
        let cheekX = Int((0.5 - 0.38 * 0.60) * 256)
        let cheekY = Int((0.5 - 0.02 * 0.72) * 256)
        XCTAssertGreaterThan(colorDistance(renderPixel(output, x: cheekX, y: cheekY),
                                           renderPixel(source, x: cheekX, y: cheekY)),
                             0.005)
    }

    // MARK: - P1-F Enhanced Makeup Tests

    func testEyelinerAndEyelashLocalization() throws {
        let source = paintedFace()
        var settings = MakeupSettings()
        settings.eyelinerColor = SRGBColor(red: 0.05, green: 0.05, blue: 0.05)
        settings.eyelinerIntensity = 0.95
        settings.eyelashIntensity = 0.90

        let output = try MakeupEngine.apply(to: source, faces: [faceLandmarks()], settings: settings)

        // Upper eyelid region should darken
        let eyeUpperBefore = renderPixel(source, x: 107, y: 140)
        let eyeUpperAfter = renderPixel(output, x: 107, y: 140)
        XCTAssertLessThan(luminance(eyeUpperAfter), luminance(eyeUpperBefore), "眼线/睫毛应使上眼睑边缘变暗")

        // Lips and background must stay completely untouched
        let lipBefore = renderPixel(source, x: 128, y: 107)
        let lipAfter = renderPixel(output, x: 128, y: 107)
        XCTAssertLessThan(colorDistance(lipAfter, lipBefore), 1e-3, "眼线/睫毛不得影响唇部")

        let cornerBefore = renderPixel(source, x: 8, y: 8)
        let cornerAfter = renderPixel(output, x: 8, y: 8)
        XCTAssertLessThan(colorDistance(cornerAfter, cornerBefore), 1e-4, "眼线/睫毛不得影响背景")
    }

    func testIrisAndCatchlightEnhancement() throws {
        let source = paintedFace()
        var settings = MakeupSettings()
        settings.irisColor = SRGBColor(red: 0.20, green: 0.50, blue: 0.85) // Blue contact lens
        settings.irisIntensity = 0.90
        settings.catchlightIntensity = 0.85

        let output = try MakeupEngine.apply(to: source, faces: [faceLandmarks()], settings: settings)

        // Pupil/iris region should change toward blue/higher luminance (left pupil is at 0.42 * 256 = 108, 0.55 * 256 = 141)
        let pupilBefore = renderPixel(source, x: 108, y: 141)
        let pupilAfter = renderPixel(output, x: 108, y: 141)
        XCTAssertGreaterThan(colorDistance(pupilAfter, pupilBefore), 0.005, "瞳孔虹膜区域应有明显润色与眼神光变化")

        // Point outside the eye (e.g. cheek) must not be affected
        let cheekBefore = renderPixel(source, x: 60, y: 128)
        let cheekAfter = renderPixel(output, x: 60, y: 128)
        XCTAssertLessThan(colorDistance(cheekAfter, cheekBefore), 1e-3, "美瞳与眼神光不得溢出眼部")
    }

    func testFaceHighlightAndContourLocalization() throws {
        let source = paintedFace()

        // 1. Highlight
        var hlSettings = MakeupSettings()
        hlSettings.highlightIntensity = 0.90
        let hlOutput = try MakeupEngine.apply(to: source, faces: [faceLandmarks()], settings: hlSettings)

        // Forehead center should brighten
        let foreheadBefore = renderPixel(source, x: 128, y: 185)
        let foreheadAfter = renderPixel(hlOutput, x: 128, y: 185)
        XCTAssertGreaterThan(luminance(foreheadAfter), luminance(foreheadBefore), "面部高光应使额头中段提亮")

        // 2. Contour
        var ctSettings = MakeupSettings()
        ctSettings.contourIntensity = 0.90
        let ctOutput = try MakeupEngine.apply(to: source, faces: [faceLandmarks()], settings: ctSettings)

        // Jawline edge should darken
        let jawBefore = renderPixel(source, x: 80, y: 90)
        let jawAfter = renderPixel(ctOutput, x: 80, y: 90)
        XCTAssertLessThan(luminance(jawAfter), luminance(jawBefore), "面部修容应使下颌/侧颊暗化")
    }

    func testRecipeVersion14GateAndSilentDowngradeBan() throws {
        // 1. Basic makeup only requires v13
        var basic = MakeupSettings(lipIntensity: 0.5)
        XCTAssertFalse(basic.requiresVersion14)

        var recipeV13 = Recipe()
        recipeV13.version = 13
        recipeV13.adjustments.makeup = basic
        XCTAssertNoThrow(try recipeV13.validateVersion())

        // 2. Enhanced makeup requires v14
        var enhanced = MakeupSettings()
        enhanced.eyelinerIntensity = 0.4
        XCTAssertTrue(enhanced.requiresVersion14)

        var recipeV13Downgrade = Recipe()
        recipeV13Downgrade.version = 13
        recipeV13Downgrade.adjustments.makeup = enhanced
        XCTAssertThrowsError(try recipeV13Downgrade.validateVersion(), "增强妆容不能降级保存为 v13")

        var recipeV14 = Recipe()
        recipeV14.version = 14
        recipeV14.adjustments.makeup = enhanced
        XCTAssertNoThrow(try recipeV14.validateVersion(), "配方版本 14 正常支持增强妆容")

        // 3. PhotoEngine.requiredRecipeVersion
        var adjEnhanced = AdjustmentSettings()
        adjEnhanced.makeup = enhanced
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: adjEnhanced, automatic: nil), 14)

        var adjBasic = AdjustmentSettings()
        adjBasic.makeup = basic
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: adjBasic, automatic: nil), 13)

        var adjNeutral = AdjustmentSettings()
        adjNeutral.makeup = MakeupSettings()
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: adjNeutral, automatic: nil), 9)
    }

    func testBackwardCompatibilityOfDecodedJSON() throws {
        // Legacy v13 JSON with only lip and brow
        let legacyJSON = """
        {
          "lipColor": {"red": 0.8, "green": 0.2, "blue": 0.3},
          "lipIntensity": 0.5,
          "browColor": {"red": 0.2, "green": 0.1, "blue": 0.1},
          "browDensity": 0.4,
          "cheekColor": {"red": 0.9, "green": 0.4, "blue": 0.4},
          "cheekIntensity": 0.0,
          "cheekRadius": 0.5,
          "eyeshadowColor": {"red": 0.5, "green": 0.3, "blue": 0.4},
          "eyeshadowIntensity": 0.0
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(MakeupSettings.self, from: data)
        XCTAssertEqual(decoded.lipIntensity, 0.5)
        XCTAssertEqual(decoded.browDensity, 0.4)
        XCTAssertEqual(decoded.eyelinerIntensity, 0)
        XCTAssertEqual(decoded.eyelashIntensity, 0)
        XCTAssertEqual(decoded.irisIntensity, 0)
        XCTAssertEqual(decoded.catchlightIntensity, 0)
        XCTAssertEqual(decoded.highlightIntensity, 0)
        XCTAssertEqual(decoded.contourIntensity, 0)
        XCTAssertFalse(decoded.requiresVersion14)
    }
}

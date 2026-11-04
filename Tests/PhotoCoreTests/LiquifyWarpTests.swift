import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

/// Synthetic-fixture tests for P1-2 liquify/face reshaping.
///
/// Fixtures use painted pixels and hand-built `FaceLandmarkSet` geometry (no Vision
/// detection), so failures point at the warp field/math rather than a detector
/// revision. They prove containment, direction, boundedness and determinism — not
/// real-photo beauty quality. Real-photo aesthetic acceptance is not performed.
final class LiquifyWarpTests: XCTestCase {
    private typealias RGBA = (r: Float, g: Float, b: Float, a: Float)

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: true,
        .cacheIntermediates: false
    ])

    // MARK: - Fixtures

    private func makeImage(width: Int, height: Int, origin: CGPoint = .zero,
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
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

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

    private func luminance(_ pixels: [Float], width: Int, column: Int, row: Int) -> Float {
        let offset = (row * width + column) * 4
        return 0.2126 * pixels[offset] + 0.7152 * pixels[offset + 1] + 0.0722 * pixels[offset + 2]
    }

    private func maximumDifference(_ first: [Float], _ second: [Float]) -> Float {
        guard first.count == second.count else { return .greatestFiniteMagnitude }
        var maximum: Float = 0
        for index in first.indices {
            maximum = max(maximum, abs(first[index] - second[index]))
        }
        return maximum
    }

    private func finite(_ field: WarpField) -> Bool {
        field.offsets.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }

    // MARK: Synthetic landmarks

    /// Square 192×192 fixture face: bbox (0.25, 0.25, 0.5, 0.5), eyes at
    /// (0.41, 0.60)/(0.59, 0.60), nose around (0.5, 0.48), lips at (0.5, 0.36).
    private func syntheticLandmarks(center: CGPoint = CGPoint(x: 0.5, y: 0.5))
        -> FaceLandmarkSet {
        let halfWidth: CGFloat = 0.25
        func ellipse(halfWidthX: CGFloat, halfHeight: CGFloat, center: CGPoint,
                     count: Int) -> [CGPoint] {
            (0..<count).map { index in
                let angle = Double(index) / Double(count) * 2 * Double.pi
                return CGPoint(x: center.x + halfWidthX * CGFloat(cos(angle)),
                               y: center.y + halfHeight * CGFloat(sin(angle)))
            }
        }
        func eye(centerX: CGFloat) -> [CGPoint] {
            let halfWidth: CGFloat = 0.045
            let halfHeight: CGFloat = 0.022
            let y = center.y + 0.10
            return [
                CGPoint(x: centerX - halfWidth, y: y),
                CGPoint(x: centerX - halfWidth * 0.5, y: y + halfHeight),
                CGPoint(x: centerX + halfWidth * 0.5, y: y + halfHeight),
                CGPoint(x: centerX + halfWidth, y: y),
                CGPoint(x: centerX + halfWidth * 0.5, y: y - halfHeight),
                CGPoint(x: centerX - halfWidth * 0.5, y: y - halfHeight)
            ]
        }
        let leftEyeCenter = CGPoint(x: center.x - 0.09, y: center.y + 0.10)
        let rightEyeCenter = CGPoint(x: center.x + 0.09, y: center.y + 0.10)
        return FaceLandmarkSet(
            boundingBox: CGRect(x: center.x - halfWidth, y: center.y - halfWidth,
                                width: halfWidth * 2, height: halfWidth * 2),
            confidence: 1,
            faceContour: ellipse(halfWidthX: halfWidth, halfHeight: halfWidth,
                                 center: center, count: 32),
            leftEye: eye(centerX: leftEyeCenter.x),
            rightEye: eye(centerX: rightEyeCenter.x),
            leftEyebrow: [],
            rightEyebrow: [],
            nose: [
                CGPoint(x: center.x - 0.02, y: center.y + 0.02),
                CGPoint(x: center.x + 0.02, y: center.y + 0.02),
                CGPoint(x: center.x + 0.03, y: center.y - 0.02),
                CGPoint(x: center.x - 0.03, y: center.y - 0.02)
            ],
            outerLips: ellipse(halfWidthX: 0.05, halfHeight: 0.02,
                               center: CGPoint(x: center.x, y: center.y - 0.14), count: 16),
            innerLips: ellipse(halfWidthX: 0.03, halfHeight: 0.012,
                               center: CGPoint(x: center.x, y: center.y - 0.14), count: 16),
            leftPupil: leftEyeCenter,
            rightPupil: rightEyeCenter
        )
    }

    private func field(parameters: FaceReshapeParameters,
                       preset: FaceShapePreset = .classic,
                       strokes: [WarpStroke] = [],
                       backgroundProtection: Bool = true,
                       imageSize: CGSize = CGSize(width: 192, height: 192)) -> WarpField {
        FaceReshapeEngine.warpField(
            landmarks: syntheticLandmarks(),
            settings: FaceReshapeSettings(preset: preset, parameters: parameters,
                                          backgroundProtection: backgroundProtection,
                                          strokes: strokes),
            imageSize: imageSize)
    }

    private func texturedImage(width: Int = 96, height: Int = 96,
                               origin: CGPoint = .zero) -> CIImage {
        makeImage(width: width, height: height, origin: origin) { column, row in
            let value = Float(0.25 + 0.5 * Double(column) / Double(width))
            return (value, Float(row) / Float(height) * 0.5, Float(0.3), 1)
        }
    }

    private func verticalLineImage(size: Int = 192, spacing: Int = 12) -> CIImage {
        makeImage(width: size, height: size) { column, _ in
            let onLine = column % spacing == 0
            let value: Float = onLine ? 0.12 : 0.85
            return (value, value, value, 1)
        }
    }

    private func lineCenter(_ pixels: [Float], width: Int, height: Int,
                            row: Int, expected: Int, window: Int) -> Double {
        let row = max(0, min(height - 1, row))
        var bestColumn = expected
        var bestScore = -Float.greatestFiniteMagnitude
        let lower = max(0, expected - window)
        let upper = min(width - 1, expected + window)
        guard lower <= upper else { return Double(expected) }
        for column in lower...upper {
            let score = -luminance(pixels, width: width, column: column, row: row)
            if score > bestScore {
                bestScore = score
                bestColumn = column
            }
        }
        return Double(bestColumn)
    }

    // MARK: - Identity

    func testIdentityFieldAndNeutralSettingsKeepPixelsUnchanged() throws {
        let image = texturedImage()
        let empty = WarpField()
        XCTAssertTrue(empty.isIdentity)
        let unchanged = try empty.apply(to: image)
        XCTAssertEqual(maximumDifference(render(image), render(unchanged)), 0,
                       "an identity field must not resample the image")

        let neutralSettings = FaceReshapeSettings()
        XCTAssertTrue(neutralSettings.isNeutral)
        let neutralField = FaceReshapeEngine.warpField(landmarks: syntheticLandmarks(),
                                                       settings: neutralSettings,
                                                       imageSize: image.extent.size)
        XCTAssertTrue(neutralField.isIdentity)
        let neutralOutput = try FaceReshapeEngine.apply(to: image,
                                                        landmarks: syntheticLandmarks(),
                                                        settings: neutralSettings)
        XCTAssertEqual(maximumDifference(render(image), render(neutralOutput)), 0)

        // strength = 0 and classic preset also collapse to the neutral path.
        var zeroStrength = FaceReshapeSettings(preset: .round,
                                               parameters: FaceReshapeParameters(slimFace: 1))
        zeroStrength.strength = 0
        XCTAssertTrue(zeroStrength.isNeutral)
        XCTAssertTrue(FaceReshapeEngine.warpField(landmarks: syntheticLandmarks(),
                                                  settings: zeroStrength,
                                                  imageSize: image.extent.size).isIdentity)
        XCTAssertTrue(FaceShapePreset.classic.parameters.isNeutral)
    }

    // MARK: - Bounded / deterministic

    func testDisplacementIsBoundedFiniteAndDeterministic() throws {
        let extremes = FaceReshapeParameters(slimFace: 1, smallFace: 1, enlargeEyes: 1,
                                             narrowNose: 1, lipWidth: 1, chin: 1)
        let strokes = [
            WarpStroke(mode: .push,
                       points: [MaskPoint(x: 0.3, y: 0.3), MaskPoint(x: 0.7, y: 0.7)],
                       radius: 0.1, strength: 1),
            WarpStroke(mode: .smooth,
                       points: [MaskPoint(x: 0.3, y: 0.4), MaskPoint(x: 0.6, y: 0.4)],
                       radius: 0.08, strength: 0.8)
        ]
        var settings = FaceReshapeSettings(preset: .round, parameters: extremes, strokes: strokes)
        let first = FaceReshapeEngine.warpField(landmarks: syntheticLandmarks(),
                                                settings: settings,
                                                imageSize: CGSize(width: 192, height: 192))
        let second = FaceReshapeEngine.warpField(landmarks: syntheticLandmarks(),
                                                 settings: settings,
                                                 imageSize: CGSize(width: 192, height: 192))
        XCTAssertTrue(finite(first))
        XCTAssertEqual(first.offsets, second.offsets,
                       "the same landmarks/settings must produce the same field")
        XCTAssertLessThanOrEqual(first.maximumMagnitude, WarpField.maximumDisplacement + 1e-6,
                                 "the field must stay inside the displacement cap")

        // Rebuild/smooth strokes must not push the field past the cap either.
        settings.strokes.append(WarpStroke(mode: .rebuild,
                                           points: [MaskPoint(x: 0.5, y: 0.5)],
                                           radius: 0.1, strength: 1))
        let rebuilt = FaceReshapeEngine.warpField(landmarks: syntheticLandmarks(),
                                                  settings: settings,
                                                  imageSize: CGSize(width: 192, height: 192))
        XCTAssertTrue(finite(rebuilt))
        XCTAssertLessThanOrEqual(rebuilt.maximumMagnitude, WarpField.maximumDisplacement + 1e-6)

        let image = texturedImage()
        let firstOutput = try first.apply(to: image)
        let secondOutput = try second.apply(to: image)
        let firstPixels = render(firstOutput)
        let secondPixels = render(secondOutput)
        for index in firstPixels.indices {
            XCTAssertEqual(firstPixels[index], secondPixels[index], accuracy: 1e-6)
        }
        XCTAssertEqual(firstOutput.extent, image.extent)
    }

    // MARK: - Slider directions

    func testFaceSliderDirections() throws {
        let size = CGSize(width: 192, height: 192)
        func displacement(_ field: WarpField, _ point: CGPoint) -> SIMD2<Double> {
            field.displacement(at: point)
        }

        let slim = field(parameters: FaceReshapeParameters(slimFace: 1), imageSize: size)
        XCTAssertGreaterThan(displacement(slim, CGPoint(x: 0.25, y: 0.5)).x, 0.002,
                             "瘦脸：左侧轮廓应向脸中心内收")
        XCTAssertLessThan(displacement(slim, CGPoint(x: 0.75, y: 0.5)).x, -0.002,
                          "瘦脸：右侧轮廓应向脸中心内收")

        let small = field(parameters: FaceReshapeParameters(smallFace: 1), imageSize: size)
        XCTAssertGreaterThan(displacement(small, CGPoint(x: 0.5, y: 0.25)).y, 0.002,
                             "小脸：下巴轮廓应向上内收")

        let eyes = field(parameters: FaceReshapeParameters(enlargeEyes: 1), imageSize: size)
        XCTAssertGreaterThan(displacement(eyes, CGPoint(x: 0.45, y: 0.60)).x, 0.002,
                             "大眼：眼睛右侧应向外扩张")
        XCTAssertLessThan(displacement(eyes, CGPoint(x: 0.37, y: 0.60)).x, -0.002,
                          "大眼：眼睛左侧应向外扩张")

        let nose = field(parameters: FaceReshapeParameters(narrowNose: 1), imageSize: size)
        XCTAssertGreaterThan(displacement(nose, CGPoint(x: 0.473, y: 0.48)).x, 0.001,
                             "鼻翼：左侧应向鼻轴内收")
        XCTAssertLessThan(displacement(nose, CGPoint(x: 0.527, y: 0.48)).x, -0.001,
                          "鼻翼：右侧应向鼻轴内收")

        let lips = field(parameters: FaceReshapeParameters(lipWidth: 1), imageSize: size)
        XCTAssertGreaterThan(displacement(lips, CGPoint(x: 0.455, y: 0.36)).x, 0.001,
                             "嘴唇：左嘴角应向嘴中心内收")
        XCTAssertLessThan(displacement(lips, CGPoint(x: 0.545, y: 0.36)).x, -0.001,
                          "嘴唇：右嘴角应向嘴中心内收")

        let chin = field(parameters: FaceReshapeParameters(chin: 1), imageSize: size)
        XCTAssertLessThan(displacement(chin, CGPoint(x: 0.5, y: 0.25)).y, -0.002,
                          "下巴：正值应向下拉长下脸")
    }

    // MARK: - Presets

    func testSevenPresetsMapToDistinctNonNeutralParameters() {
        XCTAssertEqual(FaceShapePreset.allCases.count, 7)
        XCTAssertEqual(Set(FaceShapePreset.allCases.map(\.title)).count, 7)
        XCTAssertTrue(FaceShapePreset.classic.parameters.isNeutral)
        var seen: [FaceReshapeParameters] = []
        for preset in FaceShapePreset.allCases where preset != .classic {
            let parameters = preset.parameters
            XCTAssertFalse(parameters.isNeutral, "\(preset.title) 预设应产生非中性参数")
            XCTAssertFalse(seen.contains(parameters), "\(preset.title) 预设参数不应与其他预设完全相同")
            seen.append(parameters)
            let settings = FaceReshapeSettings(preset: preset)
            XCTAssertFalse(settings.isNeutral)
            let warp = FaceReshapeEngine.warpField(landmarks: syntheticLandmarks(),
                                                   settings: settings,
                                                   imageSize: CGSize(width: 192, height: 192))
            XCTAssertFalse(warp.isIdentity, "\(preset.title) 预设应产生非零位移场")
            XCTAssertLessThanOrEqual(warp.maximumMagnitude, WarpField.maximumDisplacement + 1e-6)
        }
        // Direction spot checks for presets whose dominant slider is known.
        let youthful = field(parameters: FaceShapePreset.youthful.parameters,
                             preset: .youthful, imageSize: CGSize(width: 192, height: 192))
        XCTAssertGreaterThan(youthful.displacement(at: CGPoint(x: 0.45, y: 0.60)).x, 0.001,
                             "幼态预设应包含大眼向外")
        let long = field(parameters: FaceShapePreset.long.parameters,
                        preset: .long, imageSize: CGSize(width: 192, height: 192))
        XCTAssertGreaterThan(long.displacement(at: CGPoint(x: 0.5, y: 0.25)).y, 0.001,
                             "长脸预设的下巴应上提（缩短）")
    }

    // MARK: - Manual strokes

    func testManualStrokesAreLocalAndRebuildSmoothReduceWarp() throws {
        let setup = FaceReshapeSettings()
        let pushPoints = [MaskPoint(x: 0.40, y: 0.55), MaskPoint(x: 0.60, y: 0.55)]
        let pushed = FaceReshapeEngine.warpField(
            landmarks: nil,
            settings: FaceReshapeSettings(strokes: [
                WarpStroke(mode: .push, points: pushPoints, radius: 0.06, strength: 0.9)
            ]),
            imageSize: CGSize(width: 192, height: 192))
        let centerDisplacement = pushed.displacement(at: CGPoint(x: 0.60, y: 0.55))
        XCTAssertGreaterThan((centerDisplacement.x * centerDisplacement.x
            + centerDisplacement.y * centerDisplacement.y).squareRoot(), 0.0005,
                             "手动推移应在笔迹处产生位移")
        let far = pushed.displacement(at: CGPoint(x: 0.05, y: 0.95))
        XCTAssertEqual(far.x, 0, accuracy: 1e-9, "笔迹影响必须局限在半径附近")
        XCTAssertEqual(far.y, 0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(pushed.maximumMagnitude, WarpField.maximumDisplacement + 1e-6)

        // Rebuild removes the local warp.
        var rebuiltSettings = FaceReshapeSettings(strokes: [
            WarpStroke(mode: .push, points: pushPoints, radius: 0.06, strength: 0.9),
            WarpStroke(mode: .rebuild, points: pushPoints, radius: 0.07, strength: 1)
        ])
        let rebuilt = FaceReshapeEngine.warpField(landmarks: nil, settings: rebuiltSettings,
                                                  imageSize: CGSize(width: 192, height: 192))
        let rebuiltDisplacement = rebuilt.displacement(at: CGPoint(x: 0.60, y: 0.55))
        XCTAssertLessThan((rebuiltDisplacement.x * rebuiltDisplacement.x
            + rebuiltDisplacement.y * rebuiltDisplacement.y).squareRoot(),
                          (centerDisplacement.x * centerDisplacement.x
                           + centerDisplacement.y * centerDisplacement.y).squareRoot() * 0.5,
                          "重建笔迹应显著削弱局部位移")

        // Smooth pass reduces field roughness.
        var rough = WarpField(columns: 32, rows: 32)
        rough.addGaussian(center: CGPoint(x: 0.5, y: 0.5), radius: 0.1,
                          displacement: SIMD2<Double>(0.02, 0))
        func roughness(_ field: WarpField) -> Double {
            var total = 0.0
            for row in 0..<field.rows {
                for column in 0..<field.columns {
                    let index = row * field.columns + column
                    let value = field.offsets[index]
                    if column + 1 < field.columns {
                        let next = field.offsets[index + 1]
                        total += Double(abs(next.x - value.x) + abs(next.y - value.y))
                    }
                }
            }
            return total
        }
        let beforeSmoothing = roughness(rough)
        rough.smooth(passes: 2)
        XCTAssertLessThan(roughness(rough), beforeSmoothing)

        // smooth stroke blends the field toward its smoothed version.
        let smoothStroke = WarpStroke(mode: .smooth, points: pushPoints,
                                      radius: 0.08, strength: 0.8)
        var smoothSettings = setup
        smoothSettings.strokes = [
            WarpStroke(mode: .push, points: pushPoints, radius: 0.06, strength: 0.9),
            smoothStroke
        ]
        let smoothed = FaceReshapeEngine.warpField(landmarks: nil, settings: smoothSettings,
                                                   imageSize: CGSize(width: 192, height: 192))
        XCTAssertTrue(finite(smoothed))
    }

    // MARK: - Straight lines / background protection

    func testWarpedImageKeepsBackgroundStraightLinesAndBendsFaceWithinThreshold() throws {
        let size = 192
        let source = verticalLineImage(size: size, spacing: 24)
        let before = render(source)
        let settings = FaceReshapeSettings(parameters: FaceReshapeParameters(slimFace: 1,
                                                                            smallFace: 0.5),
                                           backgroundProtection: true)
        let field = FaceReshapeEngine.warpField(landmarks: syntheticLandmarks(),
                                                settings: settings,
                                                imageSize: CGSize(width: size, height: size))
        let warped = try field.apply(to: source)
        let after = render(warped)
        XCTAssertEqual(warped.extent, source.extent)

        // Outside the face box + feather the field is zero: background lines and
        // pixels stay put (line positions identical, pixel deltas tiny).
        for row in [10, 182] {
            for expected in stride(from: 0, to: size, by: 24) {
                let beforeCenter = lineCenter(before, width: size, height: size,
                                              row: row, expected: expected, window: 4)
                let afterCenter = lineCenter(after, width: size, height: size,
                                             row: row, expected: expected, window: 4)
                XCTAssertEqual(beforeCenter, afterCenter, accuracy: 0.001,
                               "背景直线不应移动（row \\(row), x \\(expected)）")
            }
            for column in stride(from: 0, to: size, by: 4) {
                let beforeValue = luminance(before, width: size, column: column, row: row)
                let afterValue = luminance(after, width: size, column: column, row: row)
                XCTAssertEqual(beforeValue, afterValue, accuracy: 0.002,
                               "背景像素应保持不变（row \\(row), column \\(column)）")
            }
        }

        // Inside the face the lines may bend, but only within the displacement cap.
        var maximumShift = 0.0
        var measuredShifts = 0
        for row in stride(from: 60, to: 132, by: 8) {
            for expected in stride(from: 72, to: 145, by: 24) {
                let beforeCenter = lineCenter(before, width: size, height: size,
                                              row: row, expected: expected, window: 8)
                let afterCenter = lineCenter(after, width: size, height: size,
                                             row: row, expected: expected, window: 8)
                let shift = abs(afterCenter - beforeCenter)
                maximumShift = max(maximumShift, shift)
                measuredShifts += 1
            }
        }
        XCTAssertGreaterThan(measuredShifts, 0)
        XCTAssertGreaterThan(maximumShift, 0.5,
                             "脸内直线应出现可测位移（证明液化确实生效）")
        // Integer line-centre measurement adds up to ~1px of quantisation on top
        // of the 0.03×edge displacement cap.
        let pixelCap = (WarpField.maximumDisplacement * Double(size)).rounded(.up) + 1.5
        XCTAssertLessThanOrEqual(maximumShift, pixelCap,
                                 "脸内直线位移必须落在幅度上限内（0.03×长边 + 取整容差）")
    }

    // MARK: - NaN protection

    func testNaNInputsAreSanitizedOrRejected() throws {
        var invalid = FaceReshapeSettings()
        invalid.strength = Double.nan
        XCTAssertThrowsError(try FaceReshapeEngine.validate(invalid))
        invalid.strength = 1
        invalid.parameters.slimFace = Double.nan
        XCTAssertThrowsError(try FaceReshapeEngine.validate(invalid))
        invalid.parameters = FaceReshapeParameters()
        invalid.strokes = [WarpStroke(mode: .push,
                                      points: [MaskPoint(x: .nan, y: 0.5)],
                                      radius: 0.06, strength: 0.5)]
        XCTAssertThrowsError(try FaceReshapeEngine.validate(invalid))
        invalid.strokes = [WarpStroke(mode: .push,
                                      points: [MaskPoint(x: 0.5, y: 0.5)],
                                      radius: Double.nan, strength: 0.5)]
        XCTAssertThrowsError(try FaceReshapeEngine.validate(invalid))

        // Defensive sanitization: even without validation the field stays finite.
        let nanSettings = FaceReshapeSettings(
            preset: .classic,
            parameters: FaceReshapeParameters(slimFace: Double.nan, smallFace: .infinity,
                                              enlargeEyes: Double.nan, narrowNose: .infinity,
                                              lipWidth: Double.nan, chin: .infinity),
            strength: Double.nan,
            strokes: [WarpStroke(mode: .push,
                                 points: [MaskPoint(x: .nan, y: .nan)],
                                 radius: Double.nan, strength: Double.nan)])
        let nanField = FaceReshapeEngine.warpField(landmarks: syntheticLandmarks(),
                                                   settings: nanSettings,
                                                   imageSize: CGSize(width: 192, height: 192))
        XCTAssertTrue(nanField.isIdentity)
        XCTAssertTrue(finite(nanField))

        // NaN landmark points are filtered before geometry is used.
        var landmarks = syntheticLandmarks()
        landmarks.faceContour[0] = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
        landmarks.leftEye[0] = CGPoint(x: CGFloat.infinity, y: CGFloat.nan)
        landmarks.outerLips[0] = CGPoint(x: CGFloat.nan, y: 0)
        let fieldWithNaNLandmarks = FaceReshapeEngine.warpField(
            landmarks: landmarks,
            settings: FaceReshapeSettings(parameters: FaceReshapeParameters(slimFace: 1)),
            imageSize: CGSize(width: 192, height: 192))
        XCTAssertTrue(finite(fieldWithNaNLandmarks))

        // NaN control points are ignored by the field itself.
        var direct = WarpField(columns: 16, rows: 16)
        direct.addGaussian(center: CGPoint(x: CGFloat.nan, y: 0.5), radius: 0.1,
                           displacement: SIMD2<Double>(0.01, 0))
        direct.addGaussian(center: CGPoint(x: 0.5, y: 0.5), radius: Double.nan,
                           displacement: SIMD2<Double>(Double.nan, 0))
        XCTAssertTrue(direct.isIdentity)

        let image = texturedImage()
        let neutralResult = try FaceReshapeEngine.apply(to: image, landmarks: syntheticLandmarks(),
                                                        settings: nanSettings)
        XCTAssertEqual(maximumDifference(render(image), render(neutralResult)), 0)
    }

    // MARK: - Extent / alpha

    func testApplyPreservesTranslatedExtentAndAlpha() throws {
        let origin = CGPoint(x: 13, y: -7)
        let width = 64, height = 56
        let image = makeImage(width: width, height: height, origin: origin) { column, row in
            let alpha: Float = 0.35 + 0.65 * Float(column) / Float(width - 1)
            let value = Float(0.4 + 0.3 * Double(row) / Double(height - 1))
            return (value, value * 0.8, value * 0.6, alpha)
        }
        let stroke = WarpStroke(mode: .push,
                                points: [MaskPoint(x: 0.4, y: 0.5), MaskPoint(x: 0.6, y: 0.5)],
                                radius: 0.1, strength: 0.9)
        let settings = FaceReshapeSettings(strokes: [stroke])
        let field = FaceReshapeEngine.warpField(landmarks: nil, settings: settings,
                                                imageSize: image.extent.size)
        let warped = try field.apply(to: image)
        XCTAssertEqual(warped.extent, image.extent)

        let before = render(image)
        let after = render(warped)
        XCTAssertEqual(before.count, after.count)
        for index in stride(from: 3, to: after.count, by: 4) {
            // A warp resamples the image, so alpha may be interpolated; it must
            // stay finite and inside the opaque range.
            XCTAssertTrue(after[index].isFinite)
            XCTAssertGreaterThanOrEqual(after[index], -1e-6)
            XCTAssertLessThanOrEqual(after[index], 1 + 1e-6)
        }
        // Far from the stroke the map is the identity, so alpha is preserved.
        let cornerAlphaBefore = before[3]
        let cornerAlphaAfter = after[3]
        XCTAssertEqual(cornerAlphaBefore, cornerAlphaAfter, accuracy: 0.002)
        // The warp must actually change content around the stroke in normalized
        // coordinates, even though the extent origin is translated.
        let strokeX = Int(0.5 * Double(width))
        let strokeRow = height - 1 - Int(0.5 * Double(height))
        let offset = (strokeRow * width + strokeX) * 4
        XCTAssertGreaterThan(abs(after[offset] - before[offset]), 0.002)
        // Far corner stays unchanged.
        let corner = 0
        for channel in 0..<4 {
            XCTAssertEqual(before[corner + channel], after[corner + channel], accuracy: 0.002)
        }
    }

    // MARK: - Codable / validation

    func testSettingsCodableRoundTripAndValidation() throws {
        let stroke = WarpStroke(mode: .smooth,
                                points: [MaskPoint(x: 0.2, y: 0.3), MaskPoint(x: 0.7, y: 0.6)],
                                radius: 0.05, strength: 0.5)
        let settings = FaceReshapeSettings(preset: .youthful,
                                           parameters: FaceReshapeParameters(slimFace: 0.4, chin: -0.2),
                                           strength: 0.8, backgroundProtection: true,
                                           strokes: [stroke])
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(FaceReshapeSettings.self, from: encoded)
        XCTAssertEqual(decoded, settings)
        let expected = FaceReshapeParameters(slimFace: 0.6, smallFace: 0.25, enlargeEyes: 0.40,
                                             narrowNose: 0.15, lipWidth: 0.10, chin: -0.50)
        let effective = decoded.effectiveParameters
        XCTAssertEqual(effective.slimFace, expected.slimFace, accuracy: 1e-12)
        XCTAssertEqual(effective.smallFace, expected.smallFace, accuracy: 1e-12)
        XCTAssertEqual(effective.enlargeEyes, expected.enlargeEyes, accuracy: 1e-12)
        XCTAssertEqual(effective.narrowNose, expected.narrowNose, accuracy: 1e-12)
        XCTAssertEqual(effective.lipWidth, expected.lipWidth, accuracy: 1e-12)
        XCTAssertEqual(effective.chin, expected.chin, accuracy: 1e-12)
        XCTAssertNoThrow(try FaceReshapeEngine.validate(settings))

        // Legacy payloads without any key decode to neutral defaults.
        let legacy = try JSONDecoder().decode(FaceReshapeSettings.self,
                                              from: Data("{}".utf8))
        XCTAssertEqual(legacy.preset, .classic)
        XCTAssertTrue(legacy.isNeutral)
        XCTAssertEqual(legacy.strength, 1)
        XCTAssertTrue(legacy.backgroundProtection)
        XCTAssertTrue(legacy.strokes.isEmpty)

        var invalid = settings
        invalid.strength = 1.5
        XCTAssertThrowsError(try FaceReshapeEngine.validate(invalid))
        invalid.strength = 1
        invalid.parameters.slimFace = -1.5
        XCTAssertThrowsError(try FaceReshapeEngine.validate(invalid))
        invalid.parameters = FaceReshapeParameters()
        invalid.strokes = Array(repeating: stroke, count: FaceReshapeEngine.maximumStrokeCount + 1)
        XCTAssertThrowsError(try FaceReshapeEngine.validate(invalid))
    }
}

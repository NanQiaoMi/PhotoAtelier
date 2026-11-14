import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

/// Synthetic-fixture tests for `FaceSemanticAnalyzer`.
///
/// These fixtures paint a face from known landmark polygons with known linear-sRGB
/// colours, then assert matte values at hand-picked interior/exterior points. They
/// exercise the landmark→mask API without Vision, so a failure points at the
/// colour rules or the geometry rather than at a detector revision. Real-photo
/// aesthetic behaviour is explicitly **not** covered here.
final class FaceSemanticTests: XCTestCase {
    private typealias RGBA = (r: Float, g: Float, b: Float, a: Float)

    private let width = 512
    private let height = 384
    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: true,
        .cacheIntermediates: false
    ])

    // Linear-sRGB colours: the analyzer rasterizes the source in extended linear
    // sRGB and classifies CIELab, so the fixtures are defined in the same space.
    private let skinColor: RGBA = (0.55, 0.30, 0.20, 1)
    private let teethColor: RGBA = (0.85, 0.84, 0.78, 1)
    private let scleraColor: RGBA = (0.92, 0.92, 0.91, 1)
    private let irisColor: RGBA = (0.05, 0.15, 0.35, 1)
    private let pupilColor: RGBA = (0.01, 0.01, 0.012, 1)
    private let lipColor: RGBA = (0.35, 0.06, 0.06, 1)
    private let mouthColor: RGBA = (0.02, 0.01, 0.01, 1)
    private let browColor: RGBA = (0.05, 0.03, 0.02, 1)

    // MARK: - Synthetic face fixture

    private struct SyntheticFace {
        let center: CGPoint
        let scale: CGFloat

        var eyeY: CGFloat { center.y + 0.10 * scale }
        var browY: CGFloat { center.y + 0.145 * scale }
        var lipsY: CGFloat { center.y - 0.10 * scale }
        var leftPupil: CGPoint { CGPoint(x: center.x - 0.085 * scale, y: eyeY) }
        var rightPupil: CGPoint { CGPoint(x: center.x + 0.085 * scale, y: eyeY) }
        var contourHalfWidth: CGFloat { 0.18 * scale }
        var contourHalfHeight: CGFloat { 0.22 * scale }

        var contour: [CGPoint] {
            (0..<24).map { index in
                let angle = Double(index) / 24.0 * 2 * Double.pi
                return CGPoint(x: center.x + contourHalfWidth * CGFloat(cos(angle)),
                               y: center.y + contourHalfHeight * CGFloat(sin(angle)))
            }
        }

        func eye(centerX: CGFloat) -> [CGPoint] {
            let halfWidth = 0.045 * scale
            let halfHeight = 0.022 * scale
            return [
                CGPoint(x: centerX - halfWidth, y: eyeY),
                CGPoint(x: centerX - halfWidth * 0.5, y: eyeY + halfHeight),
                CGPoint(x: centerX + halfWidth * 0.5, y: eyeY + halfHeight),
                CGPoint(x: centerX + halfWidth, y: eyeY),
                CGPoint(x: centerX + halfWidth * 0.5, y: eyeY - halfHeight),
                CGPoint(x: centerX - halfWidth * 0.5, y: eyeY - halfHeight)
            ]
        }

        func brow(centerX: CGFloat) -> [CGPoint] {
            let halfHeight = 0.012 * scale
            return [
                CGPoint(x: centerX - 0.07 * scale, y: browY - halfHeight),
                CGPoint(x: centerX + 0.02 * scale, y: browY - halfHeight),
                CGPoint(x: centerX + 0.02 * scale, y: browY + halfHeight),
                CGPoint(x: centerX - 0.07 * scale, y: browY + halfHeight)
            ]
        }

        var outerLips: [CGPoint] { lipEllipse(halfWidth: 0.060, halfHeight: 0.026) }
        var innerLips: [CGPoint] { lipEllipse(halfWidth: 0.040, halfHeight: 0.015) }

        private func lipEllipse(halfWidth: CGFloat, halfHeight: CGFloat) -> [CGPoint] {
            (0..<12).map { index in
                let angle = Double(index) / 12.0 * 2 * Double.pi
                return CGPoint(x: center.x + halfWidth * scale * CGFloat(cos(angle)),
                               y: lipsY + halfHeight * scale * CGFloat(sin(angle)))
            }
        }

        var leftEye: [CGPoint] { eye(centerX: leftPupil.x) }
        var rightEye: [CGPoint] { eye(centerX: rightPupil.x) }
        var leftBrow: [CGPoint] { brow(centerX: leftPupil.x) }
        var rightBrow: [CGPoint] { brow(centerX: rightPupil.x) }
        var nose: [CGPoint] {
            [
                CGPoint(x: center.x - 0.02 * scale, y: center.y + 0.02 * scale),
                CGPoint(x: center.x + 0.02 * scale, y: center.y + 0.02 * scale),
                CGPoint(x: center.x + 0.03 * scale, y: center.y - 0.02 * scale),
                CGPoint(x: center.x - 0.03 * scale, y: center.y - 0.02 * scale)
            ]
        }

        var boundingBox: CGRect {
            CGRect(x: center.x - contourHalfWidth,
                   y: center.y - contourHalfHeight,
                   width: contourHalfWidth * 2,
                   height: contourHalfHeight * 2)
        }

        var landmarkSet: FaceLandmarkSet {
            FaceLandmarkSet(
                boundingBox: boundingBox,
                confidence: 1,
                faceContour: contour,
                leftEye: leftEye,
                rightEye: rightEye,
                leftEyebrow: leftBrow,
                rightEyebrow: rightBrow,
                nose: nose,
                outerLips: outerLips,
                innerLips: innerLips,
                leftPupil: leftPupil,
                rightPupil: rightPupil
            )
        }

        /// Iris radius in pixels, matching the analyzer's documented
        /// "iris radius = 0.20 x eye bounding-box width" heuristic.
        func irisRadiusPixels(imageWidth: CGFloat) -> CGFloat {
            0.20 * 0.09 * scale * imageWidth
        }
    }

    /// Geometry precomputed once per face so the pixel painter does not rebuild
    /// landmark arrays for every pixel.
    private struct PaintedFace {
        let center: CGPoint
        let scale: CGFloat
        let lipsY: CGFloat
        let leftEye: [CGPoint]
        let rightEye: [CGPoint]
        let leftBrow: [CGPoint]
        let rightBrow: [CGPoint]
        let outerLips: [CGPoint]
        let innerLips: [CGPoint]
        let leftPupil: CGPoint
        let rightPupil: CGPoint
        let irisRadiusPixels: CGFloat

        init(face: SyntheticFace, imageWidth: CGFloat) {
            center = face.center
            scale = face.scale
            lipsY = face.lipsY
            leftEye = face.leftEye
            rightEye = face.rightEye
            leftBrow = face.leftBrow
            rightBrow = face.rightBrow
            outerLips = face.outerLips
            innerLips = face.innerLips
            leftPupil = face.leftPupil
            rightPupil = face.rightPupil
            irisRadiusPixels = face.irisRadiusPixels(imageWidth: imageWidth)
        }

        func teethContains(_ point: CGPoint) -> Bool {
            abs(point.x - center.x) <= 0.012 * scale && abs(point.y - lipsY) <= 0.010 * scale
        }
    }

    /// `exposure` scales every linear-light channel. The fixture is defined in
    /// extended linear sRGB, so a scale below 1 is exactly what an underexposed
    /// photo looks like to the analyzer — the case the old absolute teeth/sclera
    /// gates could not handle.
    private func syntheticImage(faces: [SyntheticFace], exposure: Float = 1) -> CIImage {
        let paintedFaces = faces.map { PaintedFace(face: $0, imageWidth: CGFloat(width)) }
        var components = [Float](repeating: 0, count: width * height * 4)
        // The background is deliberately painted in the same skin colour as the
        // face: only the landmark contour can confine the skin matte, so a leak
        // would be caught by the assertions below.
        for index in 0..<(width * height) {
            let offset = index * 4
            components[offset] = skinColor.r * exposure
            components[offset + 1] = skinColor.g * exposure
            components[offset + 2] = skinColor.b * exposure
            components[offset + 3] = skinColor.a
        }
        for face in paintedFaces { paint(face, into: &components, exposure: exposure) }
        let data = components.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        return CIImage(bitmapData: data,
                       bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                       size: CGSize(width: CGFloat(width), height: CGFloat(height)),
                       format: .RGBAf, colorSpace: linearColorSpace)
    }

    private func paint(_ face: PaintedFace, into components: inout [Float],
                       exposure: Float = 1) {
        func write(_ color: RGBA, row: Int, column: Int) {
            let offset = (row * width + column) * 4
            components[offset] = color.r * exposure
            components[offset + 1] = color.g * exposure
            components[offset + 2] = color.b * exposure
            components[offset + 3] = color.a
        }
        // Lips: outer ring in lip colour, inner mouth dark, central dentition bright.
        forEachPixel(in: face.outerLips) { column, row, point in
            guard inside(point, polygon: face.outerLips) else { return }
            if inside(point, polygon: face.innerLips) {
                write(face.teethContains(point) ? teethColor : mouthColor, row: row, column: column)
            } else {
                write(lipColor, row: row, column: column)
            }
        }
        // Eyes: bright sclera outside the iris disc, saturated iris, dark pupil.
        for (eye, pupil) in [(face.leftEye, face.leftPupil), (face.rightEye, face.rightPupil)] {
            forEachPixel(in: eye) { column, row, point in
                guard inside(point, polygon: eye) else { return }
                let dx = (point.x - pupil.x) * CGFloat(width)
                let dy = (point.y - pupil.y) * CGFloat(height)
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance <= face.irisRadiusPixels * 0.4 {
                    write(pupilColor, row: row, column: column)
                } else if distance <= face.irisRadiusPixels {
                    write(irisColor, row: row, column: column)
                } else {
                    write(scleraColor, row: row, column: column)
                }
            }
        }
        // Brows: dark pixels inside the eyebrow polygons.
        for brow in [face.leftBrow, face.rightBrow] {
            forEachPixel(in: brow) { column, row, point in
                if inside(point, polygon: brow) { write(browColor, row: row, column: column) }
            }
        }
    }

    private func forEachPixel(in polygon: [CGPoint], _ body: (Int, Int, CGPoint) -> Void) {
        guard polygon.count >= 3 else { return }
        var minimumX = polygon[0].x, maximumX = polygon[0].x
        var minimumY = polygon[0].y, maximumY = polygon[0].y
        for point in polygon {
            minimumX = min(minimumX, point.x)
            maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumY = max(maximumY, point.y)
        }
        let firstColumn = max(0, Int((minimumX * CGFloat(width)).rounded(.down)))
        let lastColumn = min(width - 1, Int((maximumX * CGFloat(width)).rounded(.up)))
        let firstRow = max(0, Int(((1 - maximumY) * CGFloat(height)).rounded(.down)))
        let lastRow = min(height - 1, Int(((1 - minimumY) * CGFloat(height)).rounded(.up)))
        guard firstColumn <= lastColumn, firstRow <= lastRow else { return }
        for row in firstRow...lastRow {
            let pointY = 1 - (CGFloat(row) + 0.5) / CGFloat(height)
            for column in firstColumn...lastColumn {
                body(column, row, CGPoint(x: (CGFloat(column) + 0.5) / CGFloat(width), y: pointY))
            }
        }
    }

    private func inside(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var result = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            let denominator = previous.y - current.y
            let crosses = (current.y > point.y) != (previous.y > point.y)
                && point.x < (previous.x - current.x) * (point.y - current.y)
                    / (denominator == 0 ? 1e-12 : denominator) + current.x
            if crosses { result.toggle() }
            previous = current
        }
        return result
    }

    // MARK: - Sampling helpers

    private struct RenderedMask {
        let values: [Float] // red channel, row 0 = top of the image
        let maskWidth: Int
        let maskHeight: Int

        func value(at point: CGPoint) -> Float {
            let column = min(maskWidth - 1, max(0, Int(point.x * CGFloat(maskWidth))))
            let fromBottom = min(maskHeight - 1, max(0, Int(point.y * CGFloat(maskHeight))))
            let rowFromTop = maskHeight - 1 - fromBottom
            return values[rowFromTop * maskWidth + column]
        }
    }

    private func sampled(_ mask: CIImage?) -> RenderedMask? {
        guard let mask else { return nil }
        let maskWidth = Int(mask.extent.width)
        let maskHeight = Int(mask.extent.height)
        var pixels = [Float](repeating: 0, count: maskWidth * maskHeight * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(mask, toBitmap: buffer.baseAddress!, rowBytes: maskWidth * 16,
                           bounds: mask.extent, format: .RGBAf, colorSpace: linearColorSpace)
        }
        return RenderedMask(values: stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] },
                            maskWidth: maskWidth, maskHeight: maskHeight)
    }

    private func sampledAlpha(_ mask: CIImage?) -> [Float] {
        guard let mask else { return [] }
        let maskWidth = Int(mask.extent.width)
        let maskHeight = Int(mask.extent.height)
        var pixels = [Float](repeating: 0, count: maskWidth * maskHeight * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(mask, toBitmap: buffer.baseAddress!, rowBytes: maskWidth * 16,
                           bounds: mask.extent, format: .RGBAf, colorSpace: linearColorSpace)
        }
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }

    // MARK: - Tests

    func testSyntheticFaceMasksMatchSkinTeethEyesLipsAndBrowsRegions() throws {
        let face = SyntheticFace(center: CGPoint(x: 0.5, y: 0.46), scale: 1)
        let image = syntheticImage(faces: [face])
        let result = FaceSemanticAnalyzer.masks(image: image,
                                                faceBounds: face.boundingBox,
                                                landmarks: face.landmarkSet)

        XCTAssertEqual(result.extent, image.extent)
        XCTAssertEqual(result.resolution, CGSize(width: 512, height: 384))
        XCTAssertEqual(result.faceCount, 1)
        XCTAssertEqual(result.confidence, 1, accuracy: 1e-9)
        XCTAssertEqual(result.faceBounds.minX, face.boundingBox.minX, accuracy: 1e-6)
        XCTAssertEqual(result.faceBounds.width, face.boundingBox.width, accuracy: 1e-6)
        XCTAssertFalse(result.isEmpty)
        for mask in [result.skin, result.teeth, result.sclera, result.iris, result.lips, result.brows] {
            XCTAssertNotNil(mask, "all six landmark regions are present in this fixture")
            XCTAssertEqual(mask?.extent, image.extent)
        }

        let skin = try XCTUnwrap(sampled(result.skin))
        let teeth = try XCTUnwrap(sampled(result.teeth))
        let sclera = try XCTUnwrap(sampled(result.sclera))
        let iris = try XCTUnwrap(sampled(result.iris))
        let lips = try XCTUnwrap(sampled(result.lips))
        let brows = try XCTUnwrap(sampled(result.brows))

        // Skin: inside the contour and away from facial features.
        let cheek = CGPoint(x: face.center.x, y: face.center.y + 0.02)
        let browPoint = CGPoint(x: face.leftPupil.x - 0.03, y: face.browY)
        XCTAssertGreaterThan(skin.value(at: cheek), 0.9)
        XCTAssertLessThan(skin.value(at: CGPoint(x: 0.05, y: 0.05)), 0.01,
                          "the skin colour must not leak outside the face contour")
        XCTAssertLessThan(skin.value(at: face.leftPupil), 0.05,
                          "eye region is excluded from the skin matte")
        XCTAssertLessThan(skin.value(at: browPoint), 0.05,
                          "eyebrow region is excluded from the skin matte")

        // Teeth: bright neutral pixels inside the inner lips only.
        let teethCenter = CGPoint(x: face.center.x, y: face.lipsY)
        let mouthCorner = CGPoint(x: face.center.x - 0.028, y: face.lipsY)
        let lipRing = CGPoint(x: face.center.x - 0.050, y: face.lipsY)
        XCTAssertGreaterThan(teeth.value(at: teethCenter), 0.8)
        XCTAssertLessThan(teeth.value(at: mouthCorner), 0.1,
                          "the dark mouth interior must not be classified as teeth")
        XCTAssertLessThan(teeth.value(at: lipRing), 0.05,
                          "teeth must not bleed into the lip ring")

        // Sclera and iris: the eye polygon split by the iris disc.
        let irisRadius = face.irisRadiusPixels(imageWidth: CGFloat(width)) / CGFloat(width)
        let irisPoint = CGPoint(x: face.leftPupil.x + 0.7 * irisRadius, y: face.leftPupil.y)
        let scleraPoint = CGPoint(x: face.leftPupil.x + 1.5 * irisRadius, y: face.leftPupil.y)
        XCTAssertGreaterThan(sclera.value(at: scleraPoint), 0.8)
        XCTAssertLessThan(sclera.value(at: irisPoint), 0.05)
        XCTAssertGreaterThan(iris.value(at: irisPoint), 0.8)
        XCTAssertLessThan(iris.value(at: face.leftPupil), 0.1,
                          "the dark pupil is not part of the iris matte")
        XCTAssertLessThan(iris.value(at: scleraPoint), 0.05)

        // Lips and brows.
        XCTAssertGreaterThan(lips.value(at: lipRing), 0.8)
        XCTAssertLessThan(lips.value(at: teethCenter), 0.1)
        XCTAssertLessThan(lips.value(at: cheek), 0.05)
        XCTAssertGreaterThan(brows.value(at: browPoint), 0.7)
        XCTAssertLessThan(brows.value(at: face.leftPupil), 0.05)
        XCTAssertLessThan(brows.value(at: cheek), 0.05)

        // Far corners are exactly empty for every mask.
        let farCorner = CGPoint(x: 0.03, y: 0.97)
        for mask in [skin, teeth, sclera, iris, lips, brows] {
            XCTAssertLessThan(mask.value(at: farCorner), 0.001)
        }
    }

    /// R4 (2026-11-14): teeth and sclera mattes must follow the photo's own
    /// exposure, not an absolute brightness. The old gates (`L* > 60..76` for
    /// teeth, `L* > 64..80` for sclera) returned an **empty** matte on all three
    /// real portraits measured, because real enamel in an open mouth peaked at
    /// L* 58-60 and the brightest sclera at L* 38-45. This fixture renders the
    /// same face at three exposures; the mattes must cover the same anatomy at
    /// every one of them.
    func testTeethAndScleraMattesSurviveUnderexposure() throws {
        let face = SyntheticFace(center: CGPoint(x: 0.5, y: 0.46), scale: 1)
        let teethCenter = CGPoint(x: face.center.x, y: face.lipsY)
        let irisRadius = face.irisRadiusPixels(imageWidth: CGFloat(width)) / CGFloat(width)
        let scleraPoint = CGPoint(x: face.leftPupil.x + 1.5 * irisRadius, y: face.leftPupil.y)
        let mouthCorner = CGPoint(x: face.center.x - 0.028, y: face.lipsY)

        // 1.0 = correctly exposed, 0.35 ≈ a two-stop-underexposed portrait,
        // 0.15 ≈ a very dark frame. All three describe the same face.
        for exposure in [Float(1.0), 0.35, 0.15] {
            let image = syntheticImage(faces: [face], exposure: exposure)
            let result = FaceSemanticAnalyzer.masks(image: image, faceBounds: face.boundingBox,
                                                    landmarks: face.landmarkSet)
            let teeth = try XCTUnwrap(sampled(result.teeth), "teeth matte at exposure \(exposure)")
            let sclera = try XCTUnwrap(sampled(result.sclera), "sclera matte at exposure \(exposure)")

            XCTAssertGreaterThan(teeth.value(at: teethCenter), 0.5,
                                 "enamel must be found at exposure \(exposure)")
            XCTAssertLessThan(teeth.value(at: mouthCorner), 0.1,
                              "the dark mouth interior is not enamel, at exposure \(exposure)")
            XCTAssertGreaterThan(sclera.value(at: scleraPoint), 0.5,
                                 "sclera must be found at exposure \(exposure)")
        }
    }

    /// The other half of the relative teeth rule: making it exposure-robust must
    /// not make it fire on a **closed mouth**. Bright red lipstick has a very red
    /// lip ring and a light interior seam, which is the case most likely to slip
    /// through a loosened gate.
    func testClosedMouthWithLipstickProducesNoTeethMatte() throws {
        let width = 160, height = 160
        let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let skin: (Float, Float, Float) = (0.40, 0.24, 0.18)
        let lipstick: (Float, Float, Float) = (0.55, 0.10, 0.09)
        let seam: (Float, Float, Float) = (0.05, 0.02, 0.02)
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                var color = skin
                let dx = (Double(column) - 80) / 34, dy = (Double(row) - 70) / 12
                if dx * dx + dy * dy <= 1 {
                    color = abs(Double(row) - 70) < 1.2 ? seam : lipstick
                }
                pixels[offset] = color.0
                pixels[offset + 1] = color.1
                pixels[offset + 2] = color.2
                pixels[offset + 3] = 1
            }
        }
        let data = pixels.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        let image = CIImage(bitmapData: data, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height),
                            format: .RGBAf, colorSpace: linearColorSpace)

        func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> [CGPoint] {
            (0..<16).map { index in
                let angle = Double(index) / 16 * 2 * .pi
                return CGPoint(x: (cx + rx * cos(angle)) / 160, y: 1 - (cy + ry * sin(angle)) / 160)
            }
        }
        var face = FaceLandmarkSet(boundingBox: CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7),
                                   confidence: 1)
        face.faceContour = ellipse(80, 80, 60, 72)
        face.outerLips = ellipse(80, 70, 34, 12)
        face.innerLips = ellipse(80, 70, 30, 1.2)
        face.leftEye = ellipse(58, 52, 12, 6)
        face.rightEye = ellipse(102, 52, 12, 6)
        face.leftEyebrow = ellipse(58, 40, 14, 3)
        face.rightEyebrow = ellipse(102, 40, 14, 3)

        let result = FaceSemanticAnalyzer.masks(image: image, faceBounds: face.boundingBox,
                                                landmarks: face)
        let teeth = try XCTUnwrap(sampled(result.teeth))
        var maximum: Float = 0
        for row in 0..<teeth.maskHeight {
            for column in 0..<teeth.maskWidth {
                maximum = max(maximum, teeth.values[row * teeth.maskWidth + column])
            }
        }
        XCTAssertLessThan(maximum, 0.1,
                          "a closed mouth has no enamel; the teeth matte must stay empty")
    }

    func testMasksAreDeterministicSoftAndBounded() throws {
        let face = SyntheticFace(center: CGPoint(x: 0.5, y: 0.46), scale: 1)
        let image = syntheticImage(faces: [face])
        let first = FaceSemanticAnalyzer.masks(image: image, faceBounds: face.boundingBox,
                                               landmarks: face.landmarkSet)
        let second = FaceSemanticAnalyzer.masks(image: image, faceBounds: face.boundingBox,
                                                landmarks: face.landmarkSet)
        let pairs: [(CIImage?, CIImage?)] = [
            (first.skin, second.skin), (first.teeth, second.teeth),
            (first.sclera, second.sclera), (first.iris, second.iris),
            (first.lips, second.lips), (first.brows, second.brows)
        ]
        for (left, right) in pairs {
            let leftMask = try XCTUnwrap(sampled(left))
            let rightMask = try XCTUnwrap(sampled(right))
            XCTAssertEqual(leftMask.values.count, rightMask.values.count)
            XCTAssertEqual(leftMask.values.count, width * height)
            for index in leftMask.values.indices {
                XCTAssertEqual(leftMask.values[index], rightMask.values[index], accuracy: 1e-6,
                               "the same image and landmarks must produce the same matte")
            }
        }

        let skin = try XCTUnwrap(sampled(first.skin))
        var fractionalPixels = 0
        var maximum: Float = 0
        for value in skin.values {
            XCTAssertTrue(value.isFinite)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1.0001)
            if value > 0.1, value < 0.9 { fractionalPixels += 1 }
            maximum = max(maximum, value)
        }
        XCTAssertGreaterThan(maximum, 0.95)
        XCTAssertGreaterThan(fractionalPixels, 50,
                             "a feathered matte must contain a soft fractional band along the contour")

        // Alpha stays opaque so the matte can be multiplied into a treatment.
        let alpha = sampledAlpha(first.skin)
        XCTAssertEqual(alpha.count, width * height)
        for value in alpha {
            XCTAssertEqual(value, 1, accuracy: 0.001)
        }
    }

    func testEmptyLowConfidenceAndDegenerateInputReturnsEmptyMasks() throws {
        let face = SyntheticFace(center: CGPoint(x: 0.5, y: 0.46), scale: 1)
        let image = syntheticImage(faces: [face])

        let empty = FaceSemanticAnalyzer.masks(image: image, faceBounds: .zero,
                                               landmarks: FaceLandmarkSet())
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.skin)
        XCTAssertNil(empty.teeth)
        XCTAssertNil(empty.sclera)
        XCTAssertNil(empty.iris)
        XCTAssertNil(empty.lips)
        XCTAssertNil(empty.brows)
        XCTAssertEqual(empty.faceCount, 0)
        XCTAssertEqual(empty.extent, image.extent)
        XCTAssertFalse(FaceLandmarkSet().hasUsableGeometry)
        XCTAssertTrue(face.landmarkSet.hasUsableGeometry)

        let noFaces = FaceSemanticAnalyzer.masks(in: image, landmarks: [])
        XCTAssertTrue(noFaces.isEmpty)

        var lowConfidence = face.landmarkSet
        lowConfidence.confidence = 0.1
        let rejected = FaceSemanticAnalyzer.masks(image: image, faceBounds: face.boundingBox,
                                                  landmarks: lowConfidence)
        XCTAssertTrue(rejected.isEmpty, "faces below minimumConfidence must be ignored")

        let nanLandmarks = FaceLandmarkSet(
            boundingBox: face.boundingBox,
            confidence: 1,
            faceContour: [CGPoint(x: CGFloat.nan, y: 0.5), CGPoint(x: 0.5, y: CGFloat.nan),
                          CGPoint(x: 0.6, y: 0.6)],
            leftEye: [CGPoint(x: CGFloat.infinity, y: 0.5)],
            outerLips: []
        )
        let degenerate = FaceSemanticAnalyzer.masks(image: image, faceBounds: face.boundingBox,
                                                    landmarks: nanLandmarks)
        XCTAssertTrue(degenerate.isEmpty, "non-finite geometry must degrade to no masks")

        let zeroImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 0, height: 0))
        let zero = FaceSemanticAnalyzer.masks(image: zeroImage, faceBounds: face.boundingBox,
                                              landmarks: face.landmarkSet)
        XCTAssertTrue(zero.isEmpty)
        XCTAssertEqual(zero.extent, .zero)
        XCTAssertEqual(zero.resolution, .zero)

        // maxDimension is clamped to 32...1024.
        let tiny = FaceSemanticAnalyzer.masks(image: image, faceBounds: face.boundingBox,
                                              landmarks: face.landmarkSet, maxDimension: 0)
        XCTAssertEqual(tiny.resolution, CGSize(width: 32, height: 24))
        XCTAssertEqual(tiny.extent, image.extent)
        let huge = FaceSemanticAnalyzer.masks(image: image, faceBounds: face.boundingBox,
                                              landmarks: face.landmarkSet, maxDimension: 4096)
        XCTAssertEqual(huge.resolution, CGSize(width: 512, height: 384),
                       "the internal raster never upscales past the source image")
    }

    func testUnionCoversEveryFaceWhileSingleFaceMasksStayLocal() throws {
        let left = SyntheticFace(center: CGPoint(x: 0.27, y: 0.47), scale: 0.6)
        let right = SyntheticFace(center: CGPoint(x: 0.73, y: 0.47), scale: 0.6)
        let image = syntheticImage(faces: [left, right])
        let leftCheek = CGPoint(x: left.center.x, y: left.center.y + 0.02 * left.scale)
        let rightCheek = CGPoint(x: right.center.x, y: right.center.y + 0.02 * right.scale)

        let union = FaceSemanticAnalyzer.masks(in: image, landmarks: [left.landmarkSet, right.landmarkSet])
        XCTAssertEqual(union.faceCount, 2)
        XCTAssertFalse(union.isEmpty)
        let unionSkin = try XCTUnwrap(sampled(union.skin))
        XCTAssertGreaterThan(unionSkin.value(at: leftCheek), 0.8)
        XCTAssertGreaterThan(unionSkin.value(at: rightCheek), 0.8)
        XCTAssertEqual(union.faceBounds.minX, left.boundingBox.minX, accuracy: 1e-6)
        XCTAssertEqual(union.faceBounds.maxX, right.boundingBox.maxX, accuracy: 1e-6)

        let single = FaceSemanticAnalyzer.masks(image: image,
                                                faceBounds: left.boundingBox,
                                                landmarks: left.landmarkSet)
        let singleSkin = try XCTUnwrap(sampled(single.skin))
        XCTAssertEqual(single.faceCount, 1)
        XCTAssertGreaterThan(singleSkin.value(at: leftCheek), 0.8)
        XCTAssertLessThan(singleSkin.value(at: rightCheek), 0.01,
                          "one face's masks must not cover another face")
    }

    func testFaceBoundsFallBackToLandmarkGeometryWhenInvalid() throws {
        let face = SyntheticFace(center: CGPoint(x: 0.5, y: 0.46), scale: 1)
        let image = syntheticImage(faces: [face])
        var landmarks = face.landmarkSet
        landmarks.boundingBox = CGRect(x: CGFloat.nan, y: CGFloat.nan,
                                       width: CGFloat.nan, height: CGFloat.nan)
        let result = FaceSemanticAnalyzer.masks(
            image: image,
            faceBounds: CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10),
            landmarks: landmarks)
        XCTAssertFalse(result.isEmpty)
        XCTAssertFalse(result.faceBounds.isNull)
        XCTAssertEqual(result.faceBounds.minX, face.boundingBox.minX, accuracy: 1e-6)
        XCTAssertEqual(result.faceBounds.maxY, face.boundingBox.maxY, accuracy: 1e-6)
        let skin = try XCTUnwrap(sampled(result.skin))
        XCTAssertGreaterThan(skin.value(at: CGPoint(x: 0.5, y: 0.48)), 0.8)
    }

    func testDetectOnBlankFrameAndZeroBudgetIsSafe() throws {
        let blank = CIImage(color: CIColor(red: 0.18, green: 0.20, blue: 0.22, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 128, height: 96))
        XCTAssertEqual(FaceSemanticAnalyzer.detect(in: blank).count, 0)
        XCTAssertEqual(FaceSemanticAnalyzer.detect(in: blank, maxFaces: 0).count, 0)

        let degenerate = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 0, height: 0))
        XCTAssertEqual(FaceSemanticAnalyzer.detect(in: degenerate).count, 0)
    }
}

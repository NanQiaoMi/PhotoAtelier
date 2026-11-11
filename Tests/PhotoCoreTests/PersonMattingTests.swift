import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

/// Synthetic-fixture tests for B1 person matting + background replacement.
///
/// Fixtures are painted mattes and images; no Vision detection is required for
/// the compositing/matte tests. Assertions prove alpha/edge containment, pixel
/// replacement, shadow presence, explicit no-person errors and determinism —
/// **not** real-photo matting quality. Vision detection is only exercised for its
/// explicit failure path on a blank image.
final class PersonMattingTests: XCTestCase {
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
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 4 * MemoryLayout<Float>.stride,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBAf, colorSpace: linearColorSpace)
        }
        return values
    }

    private func luminance(_ values: [Float]) -> Float {
        0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]
    }

    /// Hard elliptical mask (coverage 1 inside, 0 outside) in pixel space.
    private func ellipseMask(width: Int, height: Int,
                             centerX: Double = 0.5, centerY: Double = 0.5,
                             radiusX: Double = 0.22, radiusY: Double = 0.32) -> CIImage {
        makeImage(width: width, height: height) { column, row in
            let x = (Double(column) + 0.5) / Double(width)
            let y = (Double(row) + 0.5) / Double(height)
            let dx = (x - centerX) / radiusX
            let dy = (y - centerY) / radiusY
            let inside = dx * dx + dy * dy <= 1
            let value: Float = inside ? 1 : 0
            return (value, value, value, 1)
        }
    }

    /// Person-like foreground: warm subject inside the ellipse, dark original
    /// background outside, and a green spill ring near the subject edge.
    private func spillForeground(width: Int, height: Int,
                                 centerX: Double = 0.5, centerY: Double = 0.5,
                                 radiusX: Double = 0.22, radiusY: Double = 0.32) -> CIImage {
        makeImage(width: width, height: height) { column, row in
            let x = (Double(column) + 0.5) / Double(width)
            let y = (Double(row) + 0.5) / Double(height)
            let dx = (x - centerX) / radiusX
            let dy = (y - centerY) / radiusY
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance <= 0.92 {
                return (0.80, 0.62, 0.50, 1)
            } else if distance <= 1.10 {
                return (0.05, 0.95, 0.10, 1)
            } else {
                return (0.10, 0.12, 0.10, 1)
            }
        }
    }

    private func matte(width: Int = 96, height: Int = 96,
                       feather: Double = 0.25,
                       edgeSoftness: Double = 0.12,
                       decontamination: Double = 0.0,
                       minimumCoverage: Double = 0.02) throws -> PersonMatte {
        let settings = PersonMatteSettings(feather: feather,
                                           edgeSoftness: edgeSoftness,
                                           edgeDecontamination: decontamination,
                                           minimumCoverage: minimumCoverage)
        let mask = ellipseMask(width: width, height: height)
        return try PersonMatting.matte(fromMask: mask, settings: settings, context: context)
    }

    private func solidColorReference(_ color: SRGBColor, width: Int, height: Int) -> CIImage {
        let ciColor = CIColor(red: CGFloat(color.red), green: CGFloat(color.green),
                              blue: CGFloat(color.blue), alpha: 1,
                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        return CIImage(color: ciColor)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    // MARK: - Matte refinement

    func testRefineFeathersHardMaskKeepsCenterAndBackgroundAndIsDeterministic() throws {
        // Wide feather + soft ramp so the synthetic 128px mask shows a measurable
        // semi-transparent band (defaults are tuned for photo resolution).
        let settings = PersonMatteSettings(feather: 0.5, edgeSoftness: 0.25,
                                           edgeDecontamination: 0, minimumCoverage: 0.02)
        let mask = ellipseMask(width: 128, height: 128)
        let refined = try PersonMatting.refine(mask: mask, settings: settings)
        XCTAssertEqual(refined.extent, mask.extent)
        let pixels = render(refined)
        let center = renderPixel(refined, x: 64, y: 64)
        let corner = renderPixel(refined, x: 2, y: 2)
        XCTAssertGreaterThan(center[0], 0.95, "蒙版中心应保持接近 1")
        XCTAssertLessThan(corner[0], 0.05, "蒙版外应回到接近 0")
        var edgeBandCount = 0
        var alphaIsOpaque = true
        for row in 0..<128 {
            for column in 0..<128 {
                let offset = (row * 128 + column) * 4
                let value = pixels[offset]
                if value > 0.05 && value < 0.95 { edgeBandCount += 1 }
                if abs(pixels[offset + 3] - 1) > 1e-4 { alphaIsOpaque = false }
            }
        }
        XCTAssertGreaterThan(edgeBandCount, 20, "羽化后应存在半透明过渡带")
        XCTAssertTrue(alphaIsOpaque, "覆盖蒙版应是不透明的灰度图")

        let matte = try PersonMatting.matte(fromMask: mask, settings: settings, context: context)
        XCTAssertTrue(matte.hasPerson)
        XCTAssertGreaterThan(matte.coverage, 0.02)
        XCTAssertLessThan(matte.coverage, 0.40)
        XCTAssertGreaterThan(matte.confidence, 0.2)
        XCTAssertLessThanOrEqual(matte.confidence, 1)

        let again = try PersonMatting.refine(mask: mask, settings: settings)
        XCTAssertEqual(maximumDifference(render(refined), render(again)), 0,
                       "纯函数细化必须确定性")
    }

    func testDecontaminationReducesEdgeSpillAndKeepsInterior() throws {
        let foreground = spillForeground(width: 96, height: 96)
        let personMatte = try matte(feather: 0.5, edgeSoftness: 0.3, decontamination: 0.8)
        let output = try PersonMatting.decontaminateEdges(foreground: foreground,
                                                          matte: personMatte,
                                                          strength: 1)

        // The spill ring straddles the matte edge; measure only the semi-transparent
        // transition band where decontamination actually acts.
        let before = render(foreground)
        let after = render(output)
        let maskPixels = render(personMatte.mask)
        var spillPixels = 0
        var saturationBefore = 0.0
        var saturationAfter = 0.0
        for row in 0..<96 {
            for column in 0..<96 {
                let offset = (row * 96 + column) * 4
                let coverage = maskPixels[offset]
                guard coverage > 0.2, coverage < 0.8 else { continue }
                let r = before[offset], g = before[offset + 1], b = before[offset + 2]
                guard g > r + 0.3, g > b + 0.3 else { continue }
                spillPixels += 1
                let maxBefore = max(r, g, b), minBefore = min(r, g, b)
                if maxBefore > 0.001 { saturationBefore += Double((maxBefore - minBefore) / maxBefore) }
                let maxAfter = max(after[offset], after[offset + 1], after[offset + 2])
                let minAfter = min(after[offset], after[offset + 1], after[offset + 2])
                if maxAfter > 0.001 { saturationAfter += Double((maxAfter - minAfter) / maxAfter) }
            }
        }
        XCTAssertGreaterThan(spillPixels, 10, "夹具应在蒙版过渡带内包含绿色溢色像素")
        XCTAssertLessThan(saturationAfter, saturationBefore * 0.85,
                          "边缘去色边应明显降低过渡带溢色饱和度")

        // The interior (coverage ≈ 1) stays untouched.
        let interior = renderPixel(output, x: 48, y: 48)
        let interiorBefore = renderPixel(foreground, x: 48, y: 48)
        for channel in 0..<3 {
            XCTAssertEqual(interior[channel], interiorBefore[channel], accuracy: 1e-3)
        }

        let again = try PersonMatting.decontaminateEdges(foreground: foreground,
                                                         matte: personMatte, strength: 1)
        XCTAssertEqual(maximumDifference(render(output), render(again)), 0)
    }

    // MARK: - Background replacement

    func testSolidColorReplacementPixelsExtentAlphaAndDeterminism() throws {
        let width = 96, height = 96
        let foreground = spillForeground(width: width, height: height)
        let personMatte = try matte(width: width, height: height,
                                    decontamination: 0)
        let color = SRGBColor(red: 0.10, green: 0.20, blue: 0.80)
        var settings = BackgroundReplacementSettings()
        settings.shadowEnabled = false
        settings.edgeDecontamination = 0
        let output = try BackgroundReplacement.apply(foreground: foreground, matte: personMatte,
                                                     fill: .color(color), settings: settings)
        XCTAssertEqual(output.extent, foreground.extent)

        let center = renderPixel(output, x: 48, y: 48)
        let sourceCenter = renderPixel(foreground, x: 48, y: 48)
        for channel in 0..<3 {
            XCTAssertEqual(center[channel], sourceCenter[channel], accuracy: 0.02,
                           "主体内部应保留前景像素")
        }
        let corner = renderPixel(output, x: 2, y: 2)
        let reference = renderPixel(solidColorReference(color, width: width, height: height),
                                    x: 2, y: 2)
        for channel in 0..<3 {
            XCTAssertEqual(corner[channel], reference[channel], accuracy: 1e-3,
                           "主体外应替换为纯色背景")
        }
        XCTAssertEqual(corner[3], 1, accuracy: 1e-4, "背景替换输出应不透明")
        XCTAssertEqual(center[3], 1, accuracy: 1e-4)

        let again = try BackgroundReplacement.apply(foreground: foreground, matte: personMatte,
                                                    fill: .color(color), settings: settings)
        XCTAssertEqual(maximumDifference(render(output), render(again)), 0,
                       "背景替换必须确定性")
    }

    func testImageBackgroundAndShadowComposite() throws {
        let width = 96, height = 96
        let foreground = spillForeground(width: width, height: height)
        let personMatte = try matte(width: width, height: height, decontamination: 0)
        // Two-tone local background: left red, right blue.
        let background = makeImage(width: width, height: height) { column, _ in
            column < width / 2 ? (0.75, 0.10, 0.10, 1) : (0.10, 0.10, 0.75, 1)
        }
        var shadowedSettings = BackgroundReplacementSettings()
        shadowedSettings.shadowEnabled = true
        shadowedSettings.shadowOpacity = 0.75
        shadowedSettings.shadowBlur = 0.18
        shadowedSettings.shadowOffsetY = -0.12
        shadowedSettings.edgeDecontamination = 0
        var flatSettings = shadowedSettings
        flatSettings.shadowEnabled = false

        let shadowed = try BackgroundReplacement.apply(foreground: foreground, matte: personMatte,
                                                       fill: .image(background),
                                                       settings: shadowedSettings)
        let flat = try BackgroundReplacement.apply(foreground: foreground, matte: personMatte,
                                                   fill: .image(background), settings: flatSettings)
        XCTAssertEqual(shadowed.extent, foreground.extent)

        // Background image is visible outside the person.
        let leftCorner = renderPixel(shadowed, x: 2, y: 2)
        XCTAssertGreaterThan(leftCorner[0], leftCorner[2] + 0.1, "应显示背景图片左半的红色")

        // Shadow darkens the background just below the subject (outside the matte).
        let belowY = 8
        let aboveY = height - 8
        let belowShadowed = luminance(renderPixel(shadowed, x: 48, y: belowY))
        let belowFlat = luminance(renderPixel(flat, x: 48, y: belowY))
        XCTAssertLessThan(belowShadowed, belowFlat - 0.01,
                          "主体下方背景应因阴影变暗")
        let aboveShadowed = luminance(renderPixel(shadowed, x: 48, y: aboveY))
        let aboveFlat = luminance(renderPixel(flat, x: 48, y: aboveY))
        XCTAssertEqual(aboveShadowed, aboveFlat, accuracy: 0.02,
                       "主体上方远离阴影处不应明显变暗")

        // Difference is bounded and deterministic.
        let difference = maximumDifference(render(shadowed), render(flat))
        XCTAssertGreaterThan(difference, 0.02)
        XCTAssertLessThan(difference, 0.9)
        let again = try BackgroundReplacement.apply(foreground: foreground, matte: personMatte,
                                                    fill: .image(background),
                                                    settings: shadowedSettings)
        XCTAssertEqual(maximumDifference(render(shadowed), render(again)), 0)
    }

    // MARK: - Explicit failures

    func testEmptyMatteAndMissingPersonFailExplicitly() throws {
        let emptyMask = makeImage(width: 32, height: 32) { _, _ in (0, 0, 0, 1) }
        let emptyMatte = try PersonMatting.matte(fromMask: emptyMask, context: context)
        XCTAssertFalse(emptyMatte.hasPerson)
        XCTAssertLessThan(emptyMatte.coverage, 0.02)
        let foreground = spillForeground(width: 64, height: 64)
        XCTAssertThrowsError(try BackgroundReplacement.apply(foreground: foreground,
                                                             matte: emptyMatte,
                                                             fill: .color(SRGBColor(red: 1, green: 1, blue: 1))))
        XCTAssertThrowsError(try PersonMatting.requirePerson(emptyMatte))
        do {
            _ = try PersonMatting.requirePerson(emptyMatte)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("人物"),
                          "无人物错误应明确说明原因：\(error.localizedDescription)")
        }
    }

    func testBlankImageDetectionFailsExplicitly() throws {
        let blank = makeImage(width: 96, height: 96) { _, _ in (0.5, 0.5, 0.5, 1) }
        do {
            _ = try PersonMatting.detect(in: blank, settings: PersonMatteSettings(), context: context)
            XCTFail("空白图像不应被识别为包含人物")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("人物") || message.contains("Vision"),
                          "检测失败应显式说明未检测到人物/Vision 不可用，实际：\(message)")
        }
    }

    func testBackgroundImageLoaderRejectsNetworkAndMissingFiles() {
        XCTAssertThrowsError(try BackgroundReplacement.backgroundImage(
            contentsOf: URL(string: "https://example.com/bg.png")!))
        let missing = URL(fileURLWithPath: "/tmp/photo-atelier-missing-bg-\(UUID().uuidString).png")
        XCTAssertThrowsError(try BackgroundReplacement.backgroundImage(contentsOf: missing))
    }

    func testColorAndSettingsValidationAndPresets() throws {
        let color = SRGBColor(hex: "#FF8000")
        XCTAssertNotNil(color)
        XCTAssertEqual(color!.red, 1, accuracy: 1e-3)
        XCTAssertEqual(color!.green, 128.0 / 255.0, accuracy: 1e-3)
        XCTAssertEqual(color!.blue, 0, accuracy: 1e-3)
        XCTAssertEqual(color!.hexString, "#FF8000")
        XCTAssertNil(SRGBColor(hex: "#GGGGGG"))
        XCTAssertNil(SRGBColor(hex: "12345"))
        XCTAssertThrowsError(try SRGBColor(red: 1.5, green: 0, blue: 0).validated())

        for preset in IDPhotoBackgroundPreset.allCases {
            XCTAssertNoThrow(try preset.color.validated())
            XCTAssertFalse(preset.title.isEmpty)
        }
        XCTAssertEqual(IDPhotoBackgroundPreset.white.color, SRGBColor(red: 1, green: 1, blue: 1))
        XCTAssertThrowsError(try PersonMatteSettings(feather: 2).validated())
        XCTAssertThrowsError(try PersonMatteSettings(edgeSoftness: 0).validated())
        XCTAssertThrowsError(try BackgroundReplacementSettings(shadowOpacity: 2).validated())
        XCTAssertThrowsError(try BackgroundReplacementSettings(shadowBlur: 0.9).validated())
        XCTAssertThrowsError(try BackgroundReplacementSettings(edgeDecontamination: -0.1).validated())
        XCTAssertNoThrow(try PersonMatteSettings().validated())
        XCTAssertNoThrow(try BackgroundReplacementSettings().validated())
    }

    // MARK: - Helpers

    private func maximumDifference(_ first: [Float], _ second: [Float]) -> Float {
        guard first.count == second.count else { return .greatestFiniteMagnitude }
        var maximum: Float = 0
        for index in first.indices {
            maximum = max(maximum, abs(first[index] - second[index]))
        }
        return maximum
    }
}

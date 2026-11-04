import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

/// Synthetic-fixture tests for the P1-1 color tools (HSL / curves / grading /
/// lens effects).
///
/// These tests prove algorithmic contracts (identity, monotonicity, band
/// selectivity, symmetry, determinism, NaN rejection) on generated fixtures.
/// They do not prove real-photo aesthetic quality; no user photos are read.
final class ColorToolsTests: XCTestCase {
    private let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: colorSpace,
        .outputColorSpace: colorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: false,
        .cacheIntermediates: false
    ])

    // MARK: - Identity

    func testNeutralSettingsReturnIdenticalImageObjects() throws {
        let image = try solid(linearRGB: (0.3, 0.2, 0.15),
                              extent: CGRect(x: 0, y: 0, width: 24, height: 18))
        let hslOutput = try HSLEngine.apply(HSLSettings(), to: image)
        XCTAssertTrue(hslOutput === image, "中性 HSL 必须返回同一 CIImage 对象")
        let curveOutput = try ColorCurveEngine.apply(ColorCurveSettings(), to: image)
        XCTAssertTrue(curveOutput === image, "中性曲线必须返回同一 CIImage 对象")
        let gradingOutput = try ColorGradingEngine.apply(ColorGradingSettings(), to: image)
        XCTAssertTrue(gradingOutput === image, "中性颜色分级必须返回同一 CIImage 对象")
        let lensOutput = try LensEffectsEngine.apply(LensEffectsSettings(), to: image)
        XCTAssertTrue(lensOutput === image, "中性镜头效果必须返回同一 CIImage 对象")
        let aggregate = try ColorToolsEngine.apply(ColorToolsSettings(), to: image)
        XCTAssertTrue(aggregate === image, "中性聚合调色必须返回同一 CIImage 对象")

        // A band with a non-zero hue shift is a real edit, not neutral; a wheel
        // with a non-zero hue but zero saturation/luminance is neutral because
        // the hue has no direction to act on.
        var hsl = HSLSettings()
        hsl.red.hueShiftDegrees = 90
        XCTAssertFalse(hsl.isNeutral, "有非零色相偏移的 HSL 不是中性设置")

        var grading = ColorGradingSettings()
        grading.shadows = ColorGradingWheel(hueDegrees: 200, saturation: 0, luminance: 0)
        grading.balance = 0.7
        let hueOnlyGrading = try ColorGradingEngine.apply(grading, to: image)
        XCTAssertTrue(hueOnlyGrading === image, "只有平衡与零强度色轮时分级应保持中性")
    }

    // MARK: - HSL

    func testHSLRedBandSelectiveSaturation() throws {
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)
        let redHue = try image(lightness: 0.70, a: 0.06, b: 0, extent: extent)
        let oppositeHue = try image(lightness: 0.70, a: -0.06, b: 0, extent: extent)
        let greenHue = try image(lightness: 0.70, a: -0.045, b: 0.045, extent: extent)

        var settings = HSLSettings()
        settings.red.saturation = 1
        let redOutput = try HSLEngine.apply(settings, to: redHue)
        let oppositeOutput = try HSLEngine.apply(settings, to: oppositeHue)
        let greenOutput = try HSLEngine.apply(settings, to: greenHue)

        let before = oklab(try pixel(redHue, x: 8, y: 8))
        let after = oklab(try pixel(redOutput, x: 8, y: 8))
        XCTAssertGreaterThan(after.chroma, before.chroma * 1.5,
                             "红带饱和度 +1 应明显提高红带像素彩度（前 \(before.chroma) 后 \(after.chroma)）")

        let oppositeBefore = oklab(try pixel(oppositeHue, x: 8, y: 8))
        let oppositeAfter = oklab(try pixel(oppositeOutput, x: 8, y: 8))
        XCTAssertEqual(oppositeAfter.chroma, oppositeBefore.chroma, accuracy: 1e-4,
                       "相反色相（180°）不应被红带影响")

        let greenBefore = oklab(try pixel(greenHue, x: 8, y: 8))
        let greenAfter = oklab(try pixel(greenOutput, x: 8, y: 8))
        XCTAssertEqual(greenAfter.chroma, greenBefore.chroma, accuracy: 1e-4,
                       "相邻带中心（135°）不应被红带影响")
        XCTAssertEqual(greenAfter.hueDegrees, greenBefore.hueDegrees, accuracy: 0.5)
    }

    func testHSLHueShiftMovesHueWithinBand() throws {
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)
        let redHue = try image(lightness: 0.70, a: 0.06, b: 0, extent: extent)
        let greenHue = try image(lightness: 0.70, a: -0.045, b: 0.045, extent: extent)
        var settings = HSLSettings()
        settings.red.hueShiftDegrees = 30

        let redOutput = try HSLEngine.apply(settings, to: redHue)
        let greenOutput = try HSLEngine.apply(settings, to: greenHue)
        let redBefore = oklab(try pixel(redHue, x: 8, y: 8))
        let redAfter = oklab(try pixel(redOutput, x: 8, y: 8))
        XCTAssertEqual(redAfter.hueDegrees, redBefore.hueDegrees + 30, accuracy: 2,
                       "红带色相 +30° 应旋转到约 30°")
        XCTAssertEqual(redAfter.chroma, redBefore.chroma, accuracy: 1e-3,
                       "只做色相旋转不应改变彩度")

        let greenBefore = oklab(try pixel(greenHue, x: 8, y: 8))
        let greenAfter = oklab(try pixel(greenOutput, x: 8, y: 8))
        XCTAssertEqual(greenAfter.hueDegrees, greenBefore.hueDegrees, accuracy: 0.5,
                       "相邻带中心不应被红带色相旋转影响")
    }

    func testHSLLuminanceIsBandSelective() throws {
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)
        let redHue = try image(lightness: 0.60, a: 0.06, b: 0, extent: extent)
        let greenHue = try image(lightness: 0.60, a: -0.045, b: 0.045, extent: extent)
        var settings = HSLSettings()
        settings.red.luminance = 1

        let redOutput = try HSLEngine.apply(settings, to: redHue)
        let greenOutput = try HSLEngine.apply(settings, to: greenHue)
        let redBefore = oklab(try pixel(redHue, x: 8, y: 8))
        let redAfter = oklab(try pixel(redOutput, x: 8, y: 8))
        XCTAssertEqual(redAfter.L, redBefore.L + HSLEngine.luminanceRange, accuracy: 0.01,
                       "红带亮度 +1 应在红带像素上提高 OKLab L")
        let greenBefore = oklab(try pixel(greenHue, x: 8, y: 8))
        let greenAfter = oklab(try pixel(greenOutput, x: 8, y: 8))
        XCTAssertEqual(greenAfter.L, greenBefore.L, accuracy: 0.002,
                       "相邻带中心不应被红带亮度影响")
    }

    func testHSLNeutralProtectionLeavesNearGrayPixels() throws {
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)
        let nearGray = try image(lightness: 0.5, a: 0.0015, b: 0, extent: extent)
        var settings = HSLSettings()
        settings.red = HSLBandAdjustment(hueShiftDegrees: 120, saturation: 1, luminance: 1)
        let output = try HSLEngine.apply(settings, to: nearGray)
        let before = oklab(try pixel(nearGray, x: 8, y: 8))
        let after = oklab(try pixel(output, x: 8, y: 8))
        XCTAssertEqual(after.L, before.L, accuracy: 2e-4, "中性保护应让近灰像素亮度不变")
        XCTAssertEqual(after.a, before.a, accuracy: 2e-4, "中性保护应让近灰像素不被染色")
        XCTAssertEqual(after.b, before.b, accuracy: 2e-4)
    }

    func testHSLSettingsCodableRoundTrip() throws {
        var settings = HSLSettings()
        settings.cyan = HSLBandAdjustment(hueShiftDegrees: -15, saturation: 0.4, luminance: -0.2)
        settings.magenta.saturation = 0.8
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HSLSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    // MARK: - Curves

    func testCurveIdentityTableAndEndpoints() throws {
        let identity = try ColorCurveEngine.lookupTable(for: [CurveControlPoint(x: 0, y: 0),
                                                             CurveControlPoint(x: 1, y: 1)])
        for index in 0..<identity.count {
            XCTAssertEqual(identity[index], Double(index) / Double(identity.count - 1), accuracy: 1e-9)
        }
        XCTAssertEqual(try ColorCurveEngine.sample([CurveControlPoint(x: 0, y: 0),
                                                    CurveControlPoint(x: 1, y: 1)], at: 0.5),
                       0.5, accuracy: 1e-9)

        let points = [CurveControlPoint(x: 0, y: 0.1),
                      CurveControlPoint(x: 0.5, y: 0.5),
                      CurveControlPoint(x: 1, y: 0.9)]
        let table = try ColorCurveEngine.lookupTable(for: points)
        XCTAssertEqual(table.first ?? -1, 0.1, accuracy: 1e-9, "端点必须精确通过控制点")
        XCTAssertEqual(table.last ?? -1, 0.9, accuracy: 1e-9, "端点必须精确通过控制点")
    }

    func testCurveMonotoneAndNoOvershoot() throws {
        let monotone = [CurveControlPoint(x: 0, y: 0),
                        CurveControlPoint(x: 0.1, y: 0.05),
                        CurveControlPoint(x: 0.5, y: 0.4),
                        CurveControlPoint(x: 0.9, y: 0.95),
                        CurveControlPoint(x: 1, y: 1)]
        let table = try ColorCurveEngine.lookupTable(for: monotone)
        XCTAssertEqual(table, table.sorted(), "单调控制点必须生成单调 LUT")
        XCTAssertTrue(table.allSatisfy { $0 >= 0 && $0 <= 1 })
        for index in 0..<(table.count - 1) {
            XCTAssertLessThanOrEqual(table[index + 1] - table[index], 0.2, "不应出现过冲/振铃")
        }

        let steep = [CurveControlPoint(x: 0, y: 0),
                     CurveControlPoint(x: 0.05, y: 0.9),
                     CurveControlPoint(x: 1, y: 1)]
        let steepTable = try ColorCurveEngine.lookupTable(for: steep)
        XCTAssertEqual(steepTable, steepTable.sorted(), "陡峭控制点也必须单调")
        XCTAssertTrue(steepTable.allSatisfy { $0 >= 0 && $0 <= 1 })
        for index in 0..<steepTable.count where Double(index) / 255 < 0.05 {
            XCTAssertLessThanOrEqual(steepTable[index], 0.9 + 1e-9, "陡峭曲线不应超过相邻控制点")
        }
    }

    func testCurveChannelAndLuminanceSemantics() throws {
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)
        let gray = try solid(linearRGB: (0.2, 0.2, 0.2), extent: extent)

        var channelCurves = ColorCurveSettings()
        channelCurves.red = [CurveControlPoint(x: 0, y: 0.1), CurveControlPoint(x: 1, y: 1)]
        let channelOutput = try ColorCurveEngine.apply(channelCurves, to: gray)
        let channelPixel = try pixel(channelOutput, x: 8, y: 8)
        XCTAssertGreaterThan(channelPixel[0], 0.2 + 0.005, "红通道曲线应提高红通道")
        XCTAssertEqual(channelPixel[1], 0.2, accuracy: 5e-4, "未设置的通道必须保持原值")
        XCTAssertEqual(channelPixel[2], 0.2, accuracy: 5e-4)

        var luminanceCurve = ColorCurveSettings()
        luminanceCurve.luminance = [CurveControlPoint(x: 0, y: 0),
                                    CurveControlPoint(x: 0.5, y: 0.6),
                                    CurveControlPoint(x: 1, y: 1)]
        let luminanceOutput = try ColorCurveEngine.apply(luminanceCurve, to: gray)
        let luminancePixel = try pixel(luminanceOutput, x: 8, y: 8)
        XCTAssertGreaterThan(luminancePixel[0], 0.2, "亮度曲线应提亮中间调")
        XCTAssertEqual(luminancePixel[0], luminancePixel[1], accuracy: 1e-5, "亮度曲线应保持灰度")
        XCTAssertEqual(luminancePixel[1], luminancePixel[2], accuracy: 1e-5)
        // The curve is applied in display-encoded sRGB: 0.2 linear ≈ 0.4845 sRGB
        // and the curve maps that to ≈0.58 sRGB ≈ 0.29 linear.
        XCTAssertEqual(Double(luminancePixel[0]), 0.29, accuracy: 0.03)
    }

    func testCurveValidationRejectsInvalidPoints() throws {
        let invalidSets: [[CurveControlPoint]] = [
            [CurveControlPoint(x: 0, y: 0)],
            (0..<17).map { CurveControlPoint(x: Double($0) / 16, y: Double($0) / 16) },
            [CurveControlPoint(x: 0.5, y: 0), CurveControlPoint(x: 0.5, y: 1)],
            [CurveControlPoint(x: -0.1, y: 0), CurveControlPoint(x: 1, y: 1)],
            [CurveControlPoint(x: 0, y: 0), CurveControlPoint(x: 1.1, y: 1)],
            [CurveControlPoint(x: 0, y: .nan), CurveControlPoint(x: 1, y: 1)],
            [CurveControlPoint(x: 0, y: 0), CurveControlPoint(x: 1, y: 1.2)]
        ]
        for points in invalidSets {
            XCTAssertThrowsError(try ColorCurveEngine.validate(points: points),
                                 "非法控制点必须被拒绝：\(points)")
            var settings = ColorCurveSettings()
            settings.red = points
            XCTAssertThrowsError(try ColorCurveEngine.apply(settings, to: solid(linearRGB: (0.2, 0.2, 0.2),
                                                                               extent: CGRect(x: 0, y: 0, width: 4, height: 4))))
        }
    }

    func testCurveSettingsCodableRoundTrip() throws {
        var settings = ColorCurveSettings()
        settings.red = [CurveControlPoint(x: 0, y: 0.05), CurveControlPoint(x: 1, y: 0.95)]
        settings.luminance = [CurveControlPoint(x: 0, y: 0),
                              CurveControlPoint(x: 0.5, y: 0.55),
                              CurveControlPoint(x: 1, y: 1)]
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ColorCurveSettings.self, from: data), settings)
    }

    // MARK: - Color grading

    func testGradingShadowsTintOnlyShadows() throws {
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)
        let dark = try solid(linearRGB: (0.008, 0.008, 0.008), extent: extent)
        let bright = try solid(linearRGB: (0.729, 0.729, 0.729), extent: extent)
        var settings = ColorGradingSettings()
        settings.shadows = ColorGradingWheel(hueDegrees: 0, saturation: 1, luminance: 0)

        let darkOutput = try ColorGradingEngine.apply(settings, to: dark)
        let brightOutput = try ColorGradingEngine.apply(settings, to: bright)
        let darkBefore = oklab(try pixel(dark, x: 8, y: 8))
        let darkAfter = oklab(try pixel(darkOutput, x: 8, y: 8))
        let brightBefore = oklab(try pixel(bright, x: 8, y: 8))
        let brightAfter = oklab(try pixel(brightOutput, x: 8, y: 8))

        XCTAssertGreaterThan(darkAfter.a, darkBefore.a + 0.02,
                             "阴影色轮应给暗部加红色偏（前 \(darkBefore.a) 后 \(darkAfter.a)）")
        XCTAssertLessThan(brightAfter.a, darkAfter.a * 0.2,
                          "高光像素几乎不受阴影色轮影响")
        XCTAssertGreaterThan(brightAfter.L, brightBefore.L - 0.01, "分级不应压暗高光")
    }

    func testGradingGlobalWheelAffectsAllTones() throws {
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)
        let dark = try solid(linearRGB: (0.03, 0.03, 0.03), extent: extent)
        let bright = try solid(linearRGB: (0.6, 0.6, 0.6), extent: extent)
        var settings = ColorGradingSettings()
        settings.global = ColorGradingWheel(hueDegrees: 90, saturation: 0.8, luminance: 0)

        for image in [dark, bright] {
            let output = try ColorGradingEngine.apply(settings, to: image)
            let before = oklab(try pixel(image, x: 8, y: 8))
            let after = oklab(try pixel(output, x: 8, y: 8))
            XCTAssertGreaterThan(after.b, before.b + 0.01, "全局色轮应给所有亮度区域加色偏")
        }
    }

    func testGradingBalanceMovesShadowWeight() throws {
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)
        let mid = try solid(linearRGB: (0.125, 0.125, 0.125), extent: extent)
        var settings = ColorGradingSettings()
        settings.shadows = ColorGradingWheel(hueDegrees: 0, saturation: 1, luminance: 0)
        settings.balance = 1
        let positive = oklab(try pixel(try ColorGradingEngine.apply(settings, to: mid), x: 8, y: 8))
        settings.balance = -1
        let negative = oklab(try pixel(try ColorGradingEngine.apply(settings, to: mid), x: 8, y: 8))
        XCTAssertGreaterThan(positive.a, negative.a + 0.005,
                             "balance 为正时中间调应获得更多阴影色轮权重")
    }

    func testGradingValidationRejectsInvalidValues() {
        var settings = ColorGradingSettings()
        settings.shadows.hueDegrees = 361
        XCTAssertThrowsError(try ColorGradingEngine.validate(settings))
        settings = ColorGradingSettings()
        settings.midtones.saturation = 1.1
        XCTAssertThrowsError(try ColorGradingEngine.validate(settings))
        settings = ColorGradingSettings()
        settings.highlights.luminance = .nan
        XCTAssertThrowsError(try ColorGradingEngine.validate(settings))
        settings = ColorGradingSettings()
        settings.balance = -2
        XCTAssertThrowsError(try ColorGradingEngine.validate(settings))
    }

    func testGradingSettingsCodableRoundTrip() throws {
        var settings = ColorGradingSettings()
        settings.shadows = ColorGradingWheel(hueDegrees: 210, saturation: 0.4, luminance: -0.1)
        settings.highlights = ColorGradingWheel(hueDegrees: 40, saturation: 0.3, luminance: 0.1)
        settings.balance = -0.3
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ColorGradingSettings.self, from: data), settings)
    }

    // MARK: - Lens effects

    func testVignetteCenterInvariantAndRadialSymmetry() throws {
        let width = 64, height = 48
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let gray = try solid(linearRGB: (0.2, 0.2, 0.2), extent: extent)
        let settings = LensEffectsSettings(vignetteAmount: 0.6, vignetteMidpoint: 0.5,
                                           vignetteFeather: 0.5, vignetteRoundness: 1)
        let output = try LensEffectsEngine.apply(settings, to: gray)
        XCTAssertEqual(output.extent, extent)

        let center = try pixel(output, x: width / 2, y: height / 2)
        XCTAssertEqual(center[0], 0.2, accuracy: 1e-5, "暗角中心必须不变")
        let corner = try pixel(output, x: 0, y: 0)
        XCTAssertLessThan(corner[0], 0.2 * 0.9, "暗角应压暗角落")

        for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1),
                       (10, 20), (width - 1 - 10, 20)] {
            let mirroredX = try pixel(output, x: width - 1 - x, y: y)
            let direct = try pixel(output, x: x, y: y)
            XCTAssertEqual(direct[0], mirroredX[0], accuracy: 1e-5,
                           "暗角应关于中心水平对称（\(x),\(y)）")
        }
        let topLeft = try pixel(output, x: 0, y: 0)
        let bottomRight = try pixel(output, x: width - 1, y: height - 1)
        XCTAssertEqual(topLeft[0], bottomRight[0], accuracy: 1e-5, "暗角应对角对称")
        XCTAssertEqual(corner[3], 1, accuracy: 1e-6)
    }

    func testVignetteNegativeAmountBrightensCorners() throws {
        let extent = CGRect(x: 0, y: 0, width: 32, height: 32)
        let gray = try solid(linearRGB: (0.2, 0.2, 0.2), extent: extent)
        let settings = LensEffectsSettings(vignetteAmount: -0.5)
        let output = try LensEffectsEngine.apply(settings, to: gray)
        XCTAssertGreaterThan(try pixel(output, x: 0, y: 0)[0], 0.2 * 1.1,
                             "负暗角强度应提亮角落")
        XCTAssertEqual(try pixel(output, x: 16, y: 16)[0], 0.2, accuracy: 1e-5)
    }

    func testVignetteRoundnessChangesFalloff() throws {
        let width = 64, height = 48
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let gray = try solid(linearRGB: (0.2, 0.2, 0.2), extent: extent)
        var circular = LensEffectsSettings(vignetteAmount: 0.6, vignetteMidpoint: 0.5,
                                           vignetteFeather: 0.5, vignetteRoundness: 1)
        let circularOutput = try LensEffectsEngine.apply(circular, to: gray)
        circular.vignetteRoundness = 0
        let squareOutput = try LensEffectsEngine.apply(circular, to: gray)
        // Normalized (0.5, 0.5) from the center: radius 0.707 (circle) vs 0.595
        // (superellipse), so the squarer falloff is less dark at this point.
        let sampleX = width / 2 + width / 4
        let sampleY = height / 2 + height / 4
        let circularPixel = try pixel(circularOutput, x: sampleX, y: sampleY)
        let squarePixel = try pixel(squareOutput, x: sampleX, y: sampleY)
        XCTAssertGreaterThan(squarePixel[0], circularPixel[0] + 0.002,
                             "圆度 0 的方形衰减在斜向应比圆形更亮")
    }

    func testChromaticAberrationMovesOnlyRedAndBlueChannels() throws {
        let width = 512, height = 512
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        // Radial gradient: radius increases outward, so a radial channel
        // displacement is measurable as a channel value difference.
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let centerX = Double(width) / 2, centerY = Double(height) / 2
        let maximumRadius = (centerX * centerX + centerY * centerY).squareRoot()
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) + 0.5 - centerX
                let dy = Double(y) + 0.5 - centerY
                let radius = (dx * dx + dy * dy).squareRoot() / maximumRadius
                let value = Float(min(max(radius, 0), 1))
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 1
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let radial = CIImage(bitmapData: data, bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                             size: CGSize(width: width, height: height),
                             format: .RGBAf, colorSpace: colorSpace)
        var settings = LensEffectsSettings()
        settings.chromaticAberrationRed = 1
        settings.chromaticAberrationBlue = -1
        let output = try LensEffectsEngine.apply(settings, to: radial)
        XCTAssertEqual(output.extent, extent, "色差不得改变图像几何")

        let sampleX = 480, sampleY = 480
        let source = try pixel(radial, x: sampleX, y: sampleY)
        let changed = try pixel(output, x: sampleX, y: sampleY)
        XCTAssertEqual(changed[1], source[1], accuracy: 1e-6, "绿色通道必须保持不动")
        XCTAssertEqual(changed[3], source[3], accuracy: 1e-6, "alpha 必须保持不动")
        XCTAssertGreaterThan(changed[0], source[0] + 1e-4, "红通道应向外径向位移（更亮）")
        XCTAssertLessThan(changed[2], source[2] - 1e-4, "蓝通道应向内径向位移（更暗）")

        // Radial symmetry: mirrored points around the center must match.
        let mirrored = try pixel(output, x: width - 1 - sampleX, y: height - 1 - sampleY)
        XCTAssertEqual(changed[0], mirrored[0], accuracy: 1e-5, "色差应关于中心对称")
        XCTAssertEqual(changed[2], mirrored[2], accuracy: 1e-5)
    }

    func testLensEffectsValidationRejectsInvalidValues() {
        var settings = LensEffectsSettings()
        settings.vignetteAmount = 1.5
        XCTAssertThrowsError(try LensEffectsEngine.validate(settings))
        settings = LensEffectsSettings()
        settings.vignetteMidpoint = -0.1
        XCTAssertThrowsError(try LensEffectsEngine.validate(settings))
        settings = LensEffectsSettings()
        settings.chromaticAberrationRed = .nan
        XCTAssertThrowsError(try LensEffectsEngine.validate(settings))
        settings = LensEffectsSettings()
        settings.vignetteFeather = .infinity
        XCTAssertThrowsError(try LensEffectsEngine.validate(settings))
    }

    func testLensEffectsSettingsCodableRoundTrip() throws {
        let settings = LensEffectsSettings(vignetteAmount: 0.4, vignetteMidpoint: 0.45,
                                           vignetteFeather: 0.6, vignetteRoundness: 0.7,
                                           chromaticAberrationRed: 0.2,
                                           chromaticAberrationBlue: -0.3)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(LensEffectsSettings.self, from: data), settings)
    }

    // MARK: - Cross-cutting contracts

    func testAggregateRunsCurvesThenHSLThenGrading() throws {
        let image = try gradient(width: 32, height: 24) { x, y in
            let t = Float(x) / 31
            let u = Float(y) / 23
            return (0.1 + 0.5 * t, 0.2 + 0.3 * u, 0.3 - 0.2 * t)
        }
        var curves = ColorCurveSettings()
        curves.luminance = [CurveControlPoint(x: 0, y: 0),
                            CurveControlPoint(x: 0.5, y: 0.6),
                            CurveControlPoint(x: 1, y: 1)]
        var hsl = HSLSettings()
        hsl.red.saturation = 0.5
        hsl.blue.luminance = -0.3
        var grading = ColorGradingSettings()
        grading.global = ColorGradingWheel(hueDegrees: 200, saturation: 0.2, luminance: 0.05)
        let settings = ColorToolsSettings(curves: curves, hsl: hsl, grading: grading)

        let aggregate = try ColorToolsEngine.apply(settings, to: image)
        var sequential = try ColorCurveEngine.apply(curves, to: image)
        sequential = try HSLEngine.apply(hsl, to: sequential)
        sequential = try ColorGradingEngine.apply(grading, to: sequential)

        let aggregatePixels = render(aggregate, width: 32, height: 24)
        let sequentialPixels = render(sequential, width: 32, height: 24)
        XCTAssertEqual(aggregatePixels, sequentialPixels, "聚合引擎必须按 曲线→HSL→分级 顺序执行")
        XCTAssertEqual(aggregate.extent, image.extent)
    }

    func testEnginesPreserveExtentAndAlpha() throws {
        let origin = CGPoint(x: -7, y: 11)
        let extent = CGRect(x: origin.x, y: origin.y, width: 32, height: 24)
        var pixels = [Float](repeating: 0, count: 32 * 24 * 4)
        for y in 0..<24 {
            for x in 0..<32 {
                let alpha: Float = x < 8 ? 0 : (x < 16 ? 0.5 : 1)
                let offset = (y * 32 + x) * 4
                pixels[offset] = 0.4 * alpha
                pixels[offset + 1] = 0.3 * alpha
                pixels[offset + 2] = 0.2 * alpha
                pixels[offset + 3] = alpha
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: 32 * 4 * MemoryLayout<Float>.stride,
                            size: CGSize(width: 32, height: 24), format: .RGBAf,
                            colorSpace: colorSpace)
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))

        var hsl = HSLSettings()
        hsl.red.saturation = 0.5
        var curves = ColorCurveSettings()
        curves.luminance = [CurveControlPoint(x: 0, y: 0.1), CurveControlPoint(x: 1, y: 0.9)]
        var grading = ColorGradingSettings()
        grading.global = ColorGradingWheel(hueDegrees: 30, saturation: 0.3, luminance: 0.1)
        let lens = LensEffectsSettings(vignetteAmount: 0.3, chromaticAberrationRed: 0.5)
        let outputs = [
            try HSLEngine.apply(hsl, to: image),
            try ColorCurveEngine.apply(curves, to: image),
            try ColorGradingEngine.apply(grading, to: image),
            try LensEffectsEngine.apply(lens, to: image)
        ]
        for output in outputs {
            XCTAssertEqual(output.extent, extent, "输出 extent 必须与输入一致")
            let transparent = try pixel(output, x: -6, y: 20)
            XCTAssertEqual(transparent[3], 0, accuracy: 1e-6)
            XCTAssertEqual(transparent[0], 0, accuracy: 1e-6, "全透明像素应保持为 0")
            let partial = try pixel(output, x: -7 + 10, y: 20)
            XCTAssertEqual(partial[3], 0.5, accuracy: 0.002, "部分透明像素 alpha 应保持")
            XCTAssertTrue(partial.allSatisfy { $0.isFinite })
        }
    }

    func testEnginesAreDeterministic() throws {
        let image = try gradient(width: 40, height: 32) { x, y in
            (Float(x) / 39, Float(y) / 31, 0.4)
        }
        var hsl = HSLSettings()
        hsl.cyan = HSLBandAdjustment(hueShiftDegrees: 20, saturation: 0.4, luminance: 0.2)
        var curves = ColorCurveSettings()
        curves.blue = [CurveControlPoint(x: 0, y: 0.05), CurveControlPoint(x: 1, y: 0.9)]
        var grading = ColorGradingSettings()
        grading.shadows = ColorGradingWheel(hueDegrees: 220, saturation: 0.3, luminance: -0.1)
        let lens = LensEffectsSettings(vignetteAmount: 0.4, chromaticAberrationBlue: 0.6)

        for applyOnce in [
            { try HSLEngine.apply(hsl, to: image) },
            { try ColorCurveEngine.apply(curves, to: image) },
            { try ColorGradingEngine.apply(grading, to: image) },
            { try LensEffectsEngine.apply(lens, to: image) }
        ] {
            let first = render(try applyOnce(), width: 40, height: 32)
            let second = render(try applyOnce(), width: 40, height: 32)
            XCTAssertEqual(first, second, "同一输入两次渲染必须逐像素一致")
        }
    }

    func testNaNRejectionAcrossEngines() {
        var hsl = HSLSettings()
        hsl.red.hueShiftDegrees = .nan
        XCTAssertThrowsError(try HSLEngine.validate(hsl))
        var grading = ColorGradingSettings()
        grading.global.saturation = .infinity
        XCTAssertThrowsError(try ColorGradingEngine.validate(grading))
        var lens = LensEffectsSettings()
        lens.chromaticAberrationBlue = .nan
        XCTAssertThrowsError(try LensEffectsEngine.validate(lens))
        var curves = ColorCurveSettings()
        curves.green = [CurveControlPoint(x: 0, y: .nan), CurveControlPoint(x: 1, y: 1)]
        XCTAssertThrowsError(try curves.validate())
        let image = solidImage(linearRGB: (0.2, 0.2, 0.2), extent: CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertThrowsError(try HSLEngine.apply(hsl, to: image))
        XCTAssertThrowsError(try LensEffectsEngine.apply(lens, to: image))
        XCTAssertThrowsError(try ColorToolsEngine.apply(ColorToolsSettings(hsl: hsl), to: image))
    }

    func testEnginesRejectInfiniteExtent() throws {
        let infinite = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1,
                                              colorSpace: colorSpace)!)
        var hsl = HSLSettings()
        hsl.red.saturation = 0.5
        var grading = ColorGradingSettings()
        grading.global.saturation = 0.5
        let lens = LensEffectsSettings(vignetteAmount: 0.5)
        XCTAssertThrowsError(try HSLEngine.apply(hsl, to: infinite))
        XCTAssertThrowsError(try ColorGradingEngine.apply(grading, to: infinite))
        XCTAssertThrowsError(try LensEffectsEngine.apply(lens, to: infinite))
        var curves = ColorCurveSettings()
        curves.red = [CurveControlPoint(x: 0, y: 0.1), CurveControlPoint(x: 1, y: 1)]
        XCTAssertThrowsError(try ColorCurveEngine.apply(curves, to: infinite))
    }

    func testColorToolsSettingsCodableRoundTrip() throws {
        var hsl = HSLSettings()
        hsl.yellow.saturation = 0.3
        var curves = ColorCurveSettings()
        curves.red = [CurveControlPoint(x: 0, y: 0), CurveControlPoint(x: 1, y: 0.9)]
        var grading = ColorGradingSettings()
        grading.highlights = ColorGradingWheel(hueDegrees: 60, saturation: 0.25, luminance: 0.05)
        let settings = ColorToolsSettings(curves: curves, hsl: hsl, grading: grading)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ColorToolsSettings.self, from: data), settings)
    }

    // MARK: - Fixtures and helpers

    private func solidImage(linearRGB: (Double, Double, Double), extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: linearRGB.0, green: linearRGB.1, blue: linearRGB.2,
                               alpha: 1, colorSpace: colorSpace)!)
            .cropped(to: extent)
    }

    private func solid(linearRGB: (Double, Double, Double), extent: CGRect) throws -> CIImage {
        solidImage(linearRGB: linearRGB, extent: extent)
    }

    /// Builds an in-gamut solid color from OKLab coordinates (values are clamped
    /// to the sRGB gamut so the fixture is a valid SDR pixel).
    private func image(lightness: Double, a: Double, b: Double, extent: CGRect) throws -> CIImage {
        let rgb = oklabToLinearRGB(lightness, a, b)
        let clamped = (min(max(rgb.0, 0), 1), min(max(rgb.1, 0), 1), min(max(rgb.2, 0), 1))
        return solidImage(linearRGB: clamped, extent: extent)
    }

    private func gradient(width: Int, height: Int,
                          pixel: (Int, Int) -> (Float, Float, Float)) -> CIImage {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let offset = (y * width + x) * 4
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = 1
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                       size: CGSize(width: width, height: height),
                       format: .RGBAf, colorSpace: colorSpace)
    }

    private func pixel(_ image: CIImage, x: Int, y: Int) throws -> [Float] {
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!,
                           rowBytes: 4 * MemoryLayout<Float>.stride,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBAf, colorSpace: colorSpace)
        }
        return values
    }

    private func render(_ image: CIImage, width: Int, height: Int) -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            context.render(image, toBitmap: baseAddress,
                           rowBytes: width * 4 * MemoryLayout<Float>.stride,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: colorSpace)
        }
        return pixels
    }

    private func oklab(_ rgba: [Float]) -> (L: Double, a: Double, b: Double, chroma: Double,
                                            hueDegrees: Double) {
        let r = Double(rgba[0]), g = Double(rgba[1]), b = Double(rgba[2])
        func root(_ value: Double) -> Double { copysign(pow(abs(value), 1.0 / 3.0), value) }
        let l = root(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = root(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = root(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let aValue = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bValue = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let chroma = (aValue * aValue + bValue * bValue).squareRoot()
        let hue = atan2(bValue, aValue) * 180.0 / Double.pi
        return (lightness, aValue, bValue, chroma, hue)
    }

    private func oklabToLinearRGB(_ lightness: Double, _ a: Double, _ b: Double) -> (Double, Double, Double) {
        let l = lightness + 0.3963377774 * a + 0.2158037573 * b
        let m = lightness - 0.1055613458 * a - 0.0638541728 * b
        let s = lightness - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l * l * l, m3 = m * m * m, s3 = s * s * s
        return (4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
                -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
                -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
    }
}

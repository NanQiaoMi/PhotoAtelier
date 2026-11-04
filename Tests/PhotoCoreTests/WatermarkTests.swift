import XCTest
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCore

/// Watermark renderer contract tests: placement, scale, opacity, alpha,
/// dual-version helper, explicit errors and determinism.
///
/// All fixtures are synthetic (solid canvases and generated PNG/JPEG files);
/// no user photos are read. Pixel assertions run in an explicit sRGB working
/// space so the expected blend values are stable. Fonts come from the local
/// system, so the tests assert structure/positions and bounded colours rather
/// than glyph-exact bitmaps.
final class WatermarkTests: XCTestCase {
    private let canvasExtent = CGRect(x: 0, y: 0, width: 320, height: 240)
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var renderContext = CIContext(options: [
        .workingColorSpace: sRGB,
        .outputColorSpace: sRGB,
        .cacheIntermediates: false
    ])
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    // MARK: - Text placement

    func testTextWatermarkNineGridAnchorsAndBounds() throws {
        let base = canvasImage()
        let basePixels = try rasterize(base)
        var centroids: [WatermarkAnchor: (x: Double, y: Double)] = [:]

        for anchor in WatermarkAnchor.allCases {
            var settings = WatermarkSettings()
            settings.kind = .text
            settings.text = "WM"
            settings.anchor = anchor
            settings.opacity = 1
            settings.scale = 2
            settings.color = .black
            let output = try WatermarkRenderer.render(on: base,
                                                      canvasExtent: canvasExtent,
                                                      settings: settings)
            XCTAssertEqual(output.extent, canvasExtent, "\(anchor)：输出尺寸必须与画布一致")
            let pixels = try rasterize(output)
            let region = try XCTUnwrap(changedRegion(pixels, comparedTo: basePixels),
                                       "\(anchor)：文字水印必须产生非空像素变化")
            XCTAssertGreaterThan(region.count, 30, "\(anchor)：文字水印覆盖像素过少")
            // "文字非空且不越界": the glyphs stay well inside the canvas.
            XCTAssertGreaterThanOrEqual(region.minX, 2, "\(anchor)：左侧越界")
            XCTAssertLessThanOrEqual(region.maxX, 317, "\(anchor)：右侧越界")
            XCTAssertGreaterThanOrEqual(region.minY, 2, "\(anchor)：上侧越界")
            XCTAssertLessThanOrEqual(region.maxY, 237, "\(anchor)：下侧越界")
            centroids[anchor] = (region.centroidX, region.centroidY)
        }

        // Columns: left < center < right for each row. Rows: top < center < bottom.
        for (left, center, right) in [
            (WatermarkAnchor.topLeft, WatermarkAnchor.topCenter, WatermarkAnchor.topRight),
            (.centerLeft, .center, .centerRight),
            (.bottomLeft, .bottomCenter, .bottomRight)
        ] {
            let leftValue = try XCTUnwrap(centroids[left])
            let centerValue = try XCTUnwrap(centroids[center])
            let rightValue = try XCTUnwrap(centroids[right])
            XCTAssertLessThan(leftValue.x, centerValue.x - 30, "\(left)/\(center) 横向顺序错误")
            XCTAssertLessThan(centerValue.x, rightValue.x - 30, "\(center)/\(right) 横向顺序错误")
        }
        for (top, center, bottom) in [
            (WatermarkAnchor.topLeft, WatermarkAnchor.centerLeft, WatermarkAnchor.bottomLeft),
            (.topCenter, .center, .bottomCenter),
            (.topRight, .centerRight, .bottomRight)
        ] {
            let topValue = try XCTUnwrap(centroids[top])
            let centerValue = try XCTUnwrap(centroids[center])
            let bottomValue = try XCTUnwrap(centroids[bottom])
            XCTAssertLessThan(topValue.y, centerValue.y - 30, "\(top)/\(center) 纵向顺序错误")
            XCTAssertLessThan(centerValue.y, bottomValue.y - 30, "\(center)/\(bottom) 纵向顺序错误")
        }
    }

    func testTextScaleIsProportionalAndCanvasAdaptive() throws {
        let scaleOne = try textRegion(scale: 2)
        let scaleTwo = try textRegion(scale: 4)
        XCTAssertGreaterThan(scaleTwo.width, scaleOne.width, "放大 scale 必须放大水印")
        XCTAssertGreaterThan(scaleTwo.height, scaleOne.height, "放大 scale 必须放大水印")
        let widthRatio = Double(scaleTwo.width) / Double(scaleOne.width)
        let heightRatio = Double(scaleTwo.height) / Double(scaleOne.height)
        XCTAssertEqual(widthRatio, 2, accuracy: 0.35, "文字宽度应随 scale 近似线性")
        XCTAssertEqual(heightRatio, 2, accuracy: 0.45, "文字高度应随 scale 近似线性")

        // Same settings on a canvas with double the shorter edge: the watermark
        // must scale with the canvas (resolution independent look).
        let largeCanvas = CGRect(x: 0, y: 0, width: 640, height: 480)
        let largeBase = canvasImage(extent: largeCanvas)
        var settings = textSettings("WM", anchor: .center, scale: 2)
        let largeOutput = try WatermarkRenderer.render(on: largeBase,
                                                       canvasExtent: largeCanvas,
                                                       settings: settings)
        let largePixels = try rasterize(largeOutput)
        let largeBasePixels = try rasterize(largeBase)
        let largeRegion = try XCTUnwrap(changedRegion(largePixels, comparedTo: largeBasePixels))
        let canvasRatio = Double(largeRegion.width) / Double(scaleOne.width)
        XCTAssertEqual(canvasRatio, 2, accuracy: 0.3, "水印尺寸应随画布短边自适应")
        XCTAssertEqual(largeOutput.extent, largeCanvas)
        settings = textSettings("WM", anchor: .center, scale: 2)
        XCTAssertNoThrow(try settings.validate())
    }

    func testCustomOffsetMovesWatermarkInsideCanvas() throws {
        let base = canvasImage()
        let basePixels = try rasterize(base)
        var centered = textSettings("X", anchor: .center, scale: 3)
        centered.offset = WatermarkOffset(x: 0, y: 0)
        let centeredRegion = try region(of: centered, on: base, basePixels: basePixels)

        var shifted = centered
        shifted.offset = WatermarkOffset(x: 0.2, y: 0)
        let shiftedRegion = try region(of: shifted, on: base, basePixels: basePixels)
        XCTAssertEqual(shiftedRegion.centroidX - centeredRegion.centroidX,
                       0.2 * Double(canvasExtent.width), accuracy: 12,
                       "自定义 x 偏移应按画布宽度比例平移")
        XCTAssertEqual(shiftedRegion.centroidY, centeredRegion.centroidY, accuracy: 12,
                       "仅 x 偏移不应改变纵向位置")

        var raised = centered
        raised.offset = WatermarkOffset(x: 0, y: 0.1)
        let raisedRegion = try region(of: raised, on: base, basePixels: basePixels)
        XCTAssertEqual(raisedRegion.centroidY - centeredRegion.centroidY,
                       -0.1 * Double(canvasExtent.height), accuracy: 10,
                       "正 y 偏移应向上移动（行号减小）")
        // Clamping: a large offset must not push the glyphs outside the canvas.
        var clamped = centered
        clamped.offset = WatermarkOffset(x: 1, y: 1)
        let clampedRegion = try region(of: clamped, on: base, basePixels: basePixels)
        XCTAssertGreaterThanOrEqual(clampedRegion.minX, 0)
        XCTAssertLessThanOrEqual(clampedRegion.maxX, Int(canvasExtent.width) - 1)
        XCTAssertGreaterThanOrEqual(clampedRegion.minY, 0)
        XCTAssertLessThanOrEqual(clampedRegion.maxY, Int(canvasExtent.height) - 1)
    }

    func testLongTextIsShrunkToStayInsideCanvas() throws {
        let base = canvasImage()
        let basePixels = try rasterize(base)
        var settings = textSettings(String(repeating: "WATERMARK ", count: 6), anchor: .center, scale: 3)
        settings.opacity = 1
        let output = try WatermarkRenderer.render(on: base,
                                                  canvasExtent: canvasExtent,
                                                  settings: settings)
        let pixels = try rasterize(output)
        let region = try XCTUnwrap(changedRegion(pixels, comparedTo: basePixels),
                                   "长文字水印不应为空")
        XCTAssertGreaterThan(region.count, 50)
        XCTAssertLessThanOrEqual(region.width, Int(canvasExtent.width),
                                 "长文字必须收缩到画布宽度以内而不是被截断")
        XCTAssertGreaterThanOrEqual(region.minX, 1)
        XCTAssertLessThanOrEqual(region.maxX, Int(canvasExtent.width) - 2)
        XCTAssertGreaterThanOrEqual(region.minY, 1)
        XCTAssertLessThanOrEqual(region.maxY, Int(canvasExtent.height) - 2)
    }

    // MARK: - Opacity

    func testTextOpacityBlendsBetweenDisabledAndFull() throws {
        let base = canvasImage()
        let basePixels = try rasterize(base)
        var settings = textSettings("OPACITY", anchor: .center, scale: 5)

        settings.opacity = 0
        let disabled = try WatermarkRenderer.render(on: base,
                                                    canvasExtent: canvasExtent,
                                                    settings: settings)
        let disabledPixels = try rasterize(disabled)
        XCTAssertEqual(disabledPixels.data, basePixels.data, "透明度 0 必须是逐像素恒等")

        settings.opacity = 1
        let full = try assimilate(settings, on: base)
        XCTAssertLessThanOrEqual(try darkestLuminance(full), 30,
                                 "不透明黑色文字内部应接近黑色")

        settings.opacity = 0.5
        let half = try assimilate(settings, on: base)
        let halfDarkest = try darkestLuminance(half)
        XCTAssertGreaterThanOrEqual(halfDarkest, 100, "半透明文字应明显变浅")
        XCTAssertLessThanOrEqual(halfDarkest, 170, "半透明文字仍应可见")

        settings.opacity = 0.25
        let quarter = try assimilate(settings, on: base)
        let quarterDarkest = try darkestLuminance(quarter)
        XCTAssertGreaterThan(quarterDarkest, halfDarkest, "更低透明度应更浅")
        XCTAssertLessThan(quarterDarkest, 230, "0.25 透明度仍应有可测变化")
    }

    func testImageWatermarkRespectsAlphaAndOpacity() throws {
        let watermarkURL = try makeImageFile(name: "half-alpha.png", width: 64, height: 64, type: .png) { context in
            context.setFillColor(CGColor(colorSpace: sRGB, components: [1, 0, 0, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
            // Right half stays fully transparent.
        }
        // Fixture sanity: left alpha 255, right alpha 0.
        XCTAssertEqual(try decodedAlpha(watermarkURL, x: 5, y: 32), 255, "水印图片不透明区 alpha 应为 255")
        XCTAssertEqual(try decodedAlpha(watermarkURL, x: 58, y: 32), 0, "水印图片透明区 alpha 应为 0")

        let base = canvasImage()
        let basePixels = try rasterize(base)
        var settings = WatermarkSettings()
        settings.kind = .image
        settings.imagePath = watermarkURL.path
        settings.anchor = .center
        settings.opacity = 1
        settings.scale = 1

        let output = try WatermarkRenderer.render(on: base,
                                                  canvasExtent: canvasExtent,
                                                  settings: settings)
        XCTAssertEqual(output.extent, canvasExtent)
        let pixels = try rasterize(output)
        let region = try XCTUnwrap(changedRegion(pixels, comparedTo: basePixels))
        // Only the opaque half changes pixels: target width is 0.18 * 240 = 43px.
        XCTAssertGreaterThan(region.count, 200)
        XCTAssertGreaterThanOrEqual(region.width, 14)
        XCTAssertLessThanOrEqual(region.width, 30)
        let sampleX = region.minX + region.width / 2
        let sampleY = region.minY + region.height / 2
        let opaquePixel = pixels.pixel(sampleX, sampleY)
        XCTAssertGreaterThanOrEqual(opaquePixel.r, 240, "不透明区应叠成红色: \(opaquePixel)")
        XCTAssertLessThanOrEqual(opaquePixel.g, 40)
        XCTAssertLessThanOrEqual(opaquePixel.b, 40)
        // Transparent half leaves the white canvas untouched.
        let transparentColumn = min(Int(canvasExtent.width) - 1, region.maxX + 5)
        let transparentPixel = pixels.pixel(transparentColumn, sampleY)
        XCTAssertGreaterThanOrEqual(transparentPixel.r, 250)
        XCTAssertGreaterThanOrEqual(transparentPixel.g, 250)
        XCTAssertGreaterThanOrEqual(transparentPixel.b, 250)

        // Same sample at 50% opacity: red stays dominant, G/B blend halfway.
        settings.opacity = 0.5
        let halfOutput = try WatermarkRenderer.render(on: base,
                                                      canvasExtent: canvasExtent,
                                                      settings: settings)
        let halfPixels = try rasterize(halfOutput)
        let halfPixel = halfPixels.pixel(sampleX, sampleY)
        XCTAssertGreaterThanOrEqual(halfPixel.r, 240)
        XCTAssertGreaterThanOrEqual(halfPixel.g, 100, "半透明红应混入白色: \(halfPixel)")
        XCTAssertLessThanOrEqual(halfPixel.g, 170)
        XCTAssertGreaterThanOrEqual(halfPixel.b, 100)
        XCTAssertLessThanOrEqual(halfPixel.b, 170)
    }

    func testOpaqueJPEGWatermarkRendersInsideCanvas() throws {
        let watermarkURL = try makeImageFile(name: "opaque.jpg", width: 80, height: 24, type: .jpeg) { context in
            context.setFillColor(CGColor(colorSpace: sRGB, components: [0.1, 0.4, 1, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 24))
        }
        let base = canvasImage()
        let basePixels = try rasterize(base)
        var settings = WatermarkSettings()
        settings.kind = .image
        settings.imagePath = watermarkURL.path
        settings.anchor = .bottomRight
        settings.opacity = 1
        settings.scale = 1
        let output = try WatermarkRenderer.render(on: base,
                                                  canvasExtent: canvasExtent,
                                                  settings: settings)
        let region = try XCTUnwrap(region(in: try rasterize(output), comparedTo: basePixels))
        XCTAssertGreaterThan(region.count, 100, "JPEG 图片水印必须被解码并叠加")
        XCTAssertLessThanOrEqual(region.maxX, Int(canvasExtent.width) - 1)
        XCTAssertLessThanOrEqual(region.maxY, Int(canvasExtent.height) - 1)
        let pixel = try rasterize(output).pixel(region.minX + region.width / 2,
                                                region.minY + region.height / 2)
        XCTAssertGreaterThan(pixel.b, 180, "蓝色 JPEG 水印应保持蓝色: \(pixel)")
    }

    // MARK: - Rotation

    func testRotationSwapsWideWatermarkBounds() throws {
        let watermarkURL = try makeImageFile(name: "wide.png", width: 120, height: 40, type: .png) { context in
            context.setFillColor(CGColor(colorSpace: sRGB, components: [0, 0.5, 1, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 40))
        }
        let base = canvasImage()
        let basePixels = try rasterize(base)
        var settings = WatermarkSettings()
        settings.kind = .image
        settings.imagePath = watermarkURL.path
        settings.anchor = .center
        settings.opacity = 1
        settings.scale = 1
        let upright = try region(of: settings, on: base, basePixels: basePixels)
        XCTAssertGreaterThan(upright.width, upright.height, "宽图片水印默认应为横向")

        settings.rotationDegrees = 90
        let rotated = try region(of: settings, on: base, basePixels: basePixels)
        XCTAssertLessThan(rotated.width, upright.width, "旋转 90° 后宽度应缩小")
        XCTAssertGreaterThan(rotated.height, upright.height, "旋转 90° 后高度应增大")
        let aspectAfter = Double(rotated.width) / Double(rotated.height)
        let aspectBefore = Double(upright.width) / Double(upright.height)
        XCTAssertEqual(aspectAfter, 1 / aspectBefore, accuracy: 0.5,
                       "旋转 90° 应近似交换宽高比")
    }

    func testRotationShrinkKeepsWatermarkInsideCanvas() throws {
        // Regression for review F1: fitting used to run on the upright content
        // only, so a legal large-scale/long text or wide image rotated by 90° was
        // silently clipped by the export crop. The fitted rotated bounding box must
        // keep a visible margin on every side.
        let base = canvasImage()
        let basePixels = try rasterize(base)
        let wideURL = try makeImageFile(name: "wide-rotation.png",
                                        width: 400, height: 100, type: .png) { context in
            context.setFillColor(CGColor(colorSpace: sRGB, components: [0, 0.5, 1, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        }

        var largeText = textSettings("WATERMARK", anchor: .center, scale: 20)
        largeText.rotationDegrees = 90
        var longText = textSettings(String(repeating: "WATERMARK ", count: 6),
                                    anchor: .center, scale: 3)
        longText.rotationDegrees = 90
        var diagonalText = longText
        diagonalText.rotationDegrees = 45
        var wideImage = WatermarkSettings()
        wideImage.kind = .image
        wideImage.imagePath = wideURL.path
        wideImage.anchor = .center
        wideImage.opacity = 1
        wideImage.scale = 20
        wideImage.rotationDegrees = 90
        var diagonalImage = wideImage
        diagonalImage.rotationDegrees = 45

        let cases: [(String, WatermarkSettings)] = [
            ("大字号文字 90°", largeText),
            ("长文字 90°", longText),
            ("长文字 45°", diagonalText),
            ("宽图片 90°", wideImage),
            ("宽图片 45°", diagonalImage)
        ]
        for (label, settings) in cases {
            let output = try WatermarkRenderer.render(on: base,
                                                      canvasExtent: canvasExtent,
                                                      settings: settings)
            let pixels = try rasterize(output)
            let region = try XCTUnwrap(changedRegion(pixels, comparedTo: basePixels),
                                       "\(label)：旋转后水印不应为空")
            XCTAssertGreaterThan(region.count, 50, "\(label)：旋转后水印覆盖过少")
            // 至少 2px 余量：任何一边触边都说明旋转后的内容被裁剪。
            XCTAssertGreaterThanOrEqual(region.minX, 2, "\(label)：左侧触边/被裁")
            XCTAssertLessThanOrEqual(region.maxX, Int(canvasExtent.width) - 3,
                                     "\(label)：右侧触边/被裁")
            XCTAssertGreaterThanOrEqual(region.minY, 2, "\(label)：上侧触边/被裁")
            XCTAssertLessThanOrEqual(region.maxY, Int(canvasExtent.height) - 3,
                                     "\(label)：下侧触边/被裁")
        }
    }

    // MARK: - Shadow / stroke

    func testOptionalShadowAndStrokeAddCoverage() throws {
        let base = canvasImage()
        let basePixels = try rasterize(base)
        var plain = textSettings("S", anchor: .center, scale: 6)
        plain.opacity = 1
        let plainRegion = try region(of: plain, on: base, basePixels: basePixels)

        var shadowed = plain
        shadowed.shadow = WatermarkShadow(color: .black, opacity: 0.7,
                                          offset: WatermarkOffset(x: 0.01, y: -0.01),
                                          blurFraction: 0.02)
        let shadowRegion = try region(of: shadowed, on: base, basePixels: basePixels)
        XCTAssertGreaterThan(shadowRegion.count, plainRegion.count,
                             "开启阴影后覆盖像素应增加")

        var stroked = plain
        stroked.stroke = WatermarkStroke(color: .black, widthPercent: 8)
        let strokeRegion = try region(of: stroked, on: base, basePixels: basePixels)
        XCTAssertGreaterThan(strokeRegion.count, plainRegion.count,
                             "开启描边后覆盖像素应增加")
    }

    func testImageShadowOffsetUsesShorterCanvasEdge() throws {
        // Regression for review F2: image shadows used canvas.width/height while
        // text shadows and the WatermarkShadow documentation use the canvas' shorter
        // edge. The visible shadow shift must therefore stay identical when only the
        // canvas width changes (320x240 vs 480x240: same shorter edge).
        let squareURL = try makeImageFile(name: "shadow-square.png",
                                          width: 40, height: 40, type: .png) { context in
            context.setFillColor(CGColor(colorSpace: sRGB, components: [0.2, 0.3, 0.9, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        func shadowShift(canvas: CGRect) throws -> Int {
            let base = canvasImage(extent: canvas)
            let basePixels = try rasterize(base)
            var settings = WatermarkSettings()
            settings.kind = .image
            settings.imagePath = squareURL.path
            settings.anchor = .center
            settings.opacity = 1
            settings.scale = 2
            settings.shadow = WatermarkShadow(color: .black, opacity: 0.8,
                                              offset: WatermarkOffset(x: 0.1, y: 0),
                                              blurFraction: 0)
            let withShadow = try region(of: settings, on: base, basePixels: basePixels)
            settings.shadow = nil
            let withoutShadow = try region(of: settings, on: base, basePixels: basePixels)
            return withShadow.width - withoutShadow.width
        }
        let narrowShift = try shadowShift(canvas: CGRect(x: 0, y: 0, width: 320, height: 240))
        let wideShift = try shadowShift(canvas: CGRect(x: 0, y: 0, width: 480, height: 240))
        let expected = Int((0.1 * 240).rounded()) // 0.1 x shorter edge (240) = 24 px
        XCTAssertTrue(abs(narrowShift - expected) <= 4,
                      "窄画布阴影 x 位移应约为 0.1×短边=\(expected)px，实际 \(narrowShift)")
        XCTAssertTrue(abs(wideShift - expected) <= 4,
                      "宽画布同一设置阴影位移也应按短边计算（\(expected)px），实际 \(wideShift)")
        XCTAssertTrue(abs(narrowShift - wideShift) <= 4,
                      "仅改变画布宽度不应改变阴影位移（短边一致）")
    }

    // MARK: - Dual version helper

    func testDualVersionHelperReturnsPlainAndWatermarked() throws {
        let base = canvasImage()
        let basePixels = try rasterize(base)
        var settings = textSettings("PAIR", anchor: .bottomRight, scale: 2)

        let versions = try WatermarkRenderer.renderVersions(on: base,
                                                            canvasExtent: canvasExtent,
                                                            settings: settings)
        XCTAssertTrue(versions.applied)
        XCTAssertEqual(try rasterize(versions.plain).data, basePixels.data,
                       "plain 版本必须是无水印原图")
        let watermarkedPixels = try rasterize(versions.watermarked)
        XCTAssertNotEqual(watermarkedPixels.data, basePixels.data,
                          "watermarked 版本必须与 plain 不同")
        XCTAssertNotNil(changedRegion(watermarkedPixels, comparedTo: basePixels))
        XCTAssertEqual(versions.watermarked.extent, canvasExtent)
        XCTAssertEqual(versions.plain.extent, canvasExtent)
        XCTAssertTrue(WatermarkRenderer.shouldApply(settings))
        XCTAssertFalse(WatermarkRenderer.shouldApply(nil))

        let noSettings = try WatermarkRenderer.renderVersions(on: base,
                                                              canvasExtent: canvasExtent,
                                                              settings: nil)
        XCTAssertFalse(noSettings.applied, "无设置时不应应用水印")
        XCTAssertEqual(try rasterize(noSettings.plain).data, basePixels.data)
        XCTAssertEqual(try rasterize(noSettings.watermarked).data, basePixels.data)

        settings.opacity = 0
        let neutral = try WatermarkRenderer.renderVersions(on: base,
                                                           canvasExtent: canvasExtent,
                                                           settings: settings)
        XCTAssertFalse(neutral.applied, "透明度 0 视为中性，不应应用水印")
        XCTAssertEqual(try rasterize(neutral.watermarked).data, basePixels.data)
        XCTAssertFalse(WatermarkRenderer.shouldApply(settings))
    }

    // MARK: - Errors

    func testEmptyTextAndMissingImageThrowExplicitErrors() throws {
        let base = canvasImage()
        var emptyText = WatermarkSettings()
        emptyText.text = "   \n "
        emptyText.opacity = 1
        XCTAssertThrowsError(try WatermarkRenderer.render(on: base,
                                                          canvasExtent: canvasExtent,
                                                          settings: emptyText)) { error in
            self.assertConfigurationError(error, contains: "水印文字")
        }

        var missingPath = WatermarkSettings()
        missingPath.kind = .image
        missingPath.imagePath = nil
        missingPath.opacity = 1
        XCTAssertThrowsError(try WatermarkRenderer.render(on: base,
                                                          canvasExtent: canvasExtent,
                                                          settings: missingPath)) { error in
            self.assertConfigurationError(error, contains: "图片水印")
        }

        var emptyPath = missingPath
        emptyPath.imagePath = "  "
        XCTAssertThrowsError(try WatermarkRenderer.render(on: base,
                                                          canvasExtent: canvasExtent,
                                                          settings: emptyPath)) { error in
            self.assertConfigurationError(error, contains: "图片水印")
        }

        let absent = try TestFiles.makeTemporaryDirectory()
        temporaryDirectories.append(absent)
        let absentURL = absent.appendingPathComponent("does-not-exist.png")
        var absentSettings = missingPath
        absentSettings.imagePath = absentURL.path
        XCTAssertThrowsError(try WatermarkRenderer.render(on: base,
                                                          canvasExtent: canvasExtent,
                                                          settings: absentSettings)) { error in
            guard let atelierError = error as? AtelierError,
                  case .imageRead(let message) = atelierError else {
                XCTFail("缺失水印图片应报 imageRead，实际：\(error)")
                return
            }
            XCTAssertTrue(message.contains("水印图片"), message)
            XCTAssertTrue(message.contains("does-not-exist.png"), message)
        }

        let corruptDirectory = try TestFiles.makeTemporaryDirectory()
        temporaryDirectories.append(corruptDirectory)
        let corruptURL = corruptDirectory.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: corruptURL)
        var corruptSettings = missingPath
        corruptSettings.imagePath = corruptURL.path
        XCTAssertThrowsError(try WatermarkRenderer.render(on: base,
                                                          canvasExtent: canvasExtent,
                                                          settings: corruptSettings)) { error in
            guard let atelierError = error as? AtelierError,
                  case .imageRead(let message) = atelierError else {
                XCTFail("损坏水印图片应报 imageRead，实际：\(error)")
                return
            }
            XCTAssertTrue(message.contains("水印图片"), message)
        }
    }

    func testValidationRejectsOutOfRangeValues() throws {
        func invalid(_ mutate: (inout WatermarkSettings) -> Void,
                     _ label: String,
                     file: StaticString = #filePath,
                     line: UInt = #line) {
            var settings = textSettings("VALID", anchor: .center, scale: 2)
            mutate(&settings)
            XCTAssertThrowsError(try settings.validate(), label, file: file, line: line) { error in
                guard let atelierError = error as? AtelierError,
                      case .invalidConfiguration = atelierError else {
                    XCTFail("\(label)：应报 invalidConfiguration，实际：\(error)", file: file, line: line)
                    return
                }
            }
        }
        invalid({ $0.opacity = 1.5 }, "透明度 > 1")
        invalid({ $0.opacity = -0.1 }, "透明度 < 0")
        invalid({ $0.opacity = .nan }, "透明度 NaN")
        invalid({ $0.scale = 0 }, "缩放 0")
        invalid({ $0.scale = .nan }, "缩放 NaN")
        invalid({ $0.scale = 25 }, "缩放过大")
        invalid({ $0.rotationDegrees = .nan }, "旋转 NaN")
        invalid({ $0.rotationDegrees = 200 }, "旋转过大")
        invalid({ $0.marginFraction = 0.5 }, "边距过大")
        invalid({ $0.marginFraction = .nan }, "边距 NaN")
        invalid({ $0.offset = WatermarkOffset(x: .nan, y: 0) }, "偏移 NaN")
        invalid({ $0.offset = WatermarkOffset(x: 1.5, y: 0) }, "偏移过大")
        invalid({ $0.color = WatermarkColor(red: 1.5, green: 0, blue: 0) }, "颜色分量越界")
        invalid({ $0.shadow = WatermarkShadow(opacity: 2) }, "阴影不透明度越界")
        invalid({ $0.shadow = WatermarkShadow(blurFraction: 0.5) }, "阴影模糊越界")
        invalid({ $0.shadow = WatermarkShadow(offset: WatermarkOffset(x: .nan, y: 0)) }, "阴影偏移 NaN")
        invalid({ $0.stroke = WatermarkStroke(widthPercent: 30) }, "描边宽度越界")

        var valid = textSettings("OK", anchor: .topLeft, scale: 1.5)
        valid.shadow = WatermarkShadow()
        valid.stroke = WatermarkStroke()
        XCTAssertNoThrow(try valid.validate())

        // NaN opacity must not be mistaken for a neutral no-op: rendering fails
        // loudly instead of silently drawing nothing.
        var nanOpacity = valid
        nanOpacity.opacity = .nan
        XCTAssertThrowsError(try WatermarkRenderer.render(on: canvasImage(),
                                                          canvasExtent: canvasExtent,
                                                          settings: nanOpacity))
    }

    // MARK: - Determinism & font boundaries

    func testRenderingIsDeterministic() throws {
        let base = canvasImage()
        var settings = textSettings("DETERMINISM", anchor: .bottomLeft, scale: 3)
        settings.opacity = 0.8
        settings.rotationDegrees = -12
        settings.shadow = WatermarkShadow()
        settings.stroke = WatermarkStroke()
        let first = try rasterize(try WatermarkRenderer.render(on: base,
                                                               canvasExtent: canvasExtent,
                                                               settings: settings))
        let second = try rasterize(try WatermarkRenderer.render(on: base,
                                                                canvasExtent: canvasExtent,
                                                                settings: settings))
        XCTAssertEqual(first.data, second.data, "相同输入必须产生逐字节相同的像素")
        settings.text = "DETERMINISM!"
        let changed = try rasterize(try WatermarkRenderer.render(on: base,
                                                                 canvasExtent: canvasExtent,
                                                                 settings: settings))
        XCTAssertNotEqual(first.data, changed.data, "不同文字应产生不同像素")
    }

    func testUnknownFontFallsBackAndChineseTextRenders() throws {
        let base = canvasImage()
        let basePixels = try rasterize(base)
        var unknownFont = textSettings("FONT", anchor: .center, scale: 3)
        unknownFont.fontName = "NoSuchFont-DoesNotExist-123"
        let fallbackRegion = try region(of: unknownFont, on: base, basePixels: basePixels)
        XCTAssertGreaterThan(fallbackRegion.count, 20, "未知字体应回退到系统字体而非渲染空白")

        let chinese = textSettings("光屿水印", anchor: .center, scale: 3)
        let chineseRegion = try region(of: chinese, on: base, basePixels: basePixels)
        XCTAssertGreaterThan(chineseRegion.count, 20, "中文水印应通过系统字体回退正常渲染")
    }

    // MARK: - Helpers

    private func canvasImage(extent: CGRect? = nil) -> CIImage {
        let rect = extent ?? canvasExtent
        let color = CIColor(red: 1, green: 1, blue: 1, alpha: 1, colorSpace: sRGB)!
        return CIImage(color: color).cropped(to: rect)
    }

    private func textSettings(_ text: String,
                              anchor: WatermarkAnchor,
                              scale: Double) -> WatermarkSettings {
        var settings = WatermarkSettings()
        settings.kind = .text
        settings.text = text
        settings.anchor = anchor
        settings.opacity = 1
        settings.scale = scale
        settings.color = .black
        return settings
    }

    private func region(of settings: WatermarkSettings,
                        on base: CIImage,
                        basePixels: Bitmap) throws -> Region {
        let output = try WatermarkRenderer.render(on: base,
                                                  canvasExtent: base.extent,
                                                  settings: settings)
        let pixels = try rasterize(output)
        guard let region = changedRegion(pixels, comparedTo: basePixels) else {
            XCTFail("水印未产生任何像素变化")
            throw AtelierError.imageWrite("测试期望水印变化但没有")
        }
        return region
    }

    private func textRegion(scale: Double) throws -> Region {
        let base = canvasImage()
        let basePixels = try rasterize(base)
        return try region(of: textSettings("WM", anchor: .center, scale: scale),
                          on: base,
                          basePixels: basePixels)
    }

    private func assimilate(_ settings: WatermarkSettings, on base: CIImage) throws -> Bitmap {
        let output = try WatermarkRenderer.render(on: base,
                                                  canvasExtent: base.extent,
                                                  settings: settings)
        return try rasterize(output)
    }

    private func darkestLuminance(_ bitmap: Bitmap) throws -> Double {
        var darkest = 255.0
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let pixel = bitmap.pixel(x, y)
                let luminance = (Double(pixel.r) + Double(pixel.g) + Double(pixel.b)) / 3
                darkest = min(darkest, luminance)
            }
        }
        return darkest
    }

    private func rasterize(_ image: CIImage) throws -> Bitmap {
        let extent = image.extent.integral
        guard extent.width >= 1, extent.height >= 1,
              let cgImage = renderContext.createCGImage(image, from: extent,
                                                       format: .RGBA8,
                                                       colorSpace: sRGB) else {
            throw AtelierError.imageWrite("测试无法渲染水印图像")
        }
        let width = cgImage.width
        let height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw AtelierError.imageWrite("测试无法创建像素缓冲") }
        return Bitmap(width: width, height: height, data: data)
    }

    private func changedRegion(_ rendered: Bitmap,
                               comparedTo base: Bitmap,
                               tolerance: Int = 4) -> Region? {
        XCTAssertEqual(rendered.width, base.width)
        XCTAssertEqual(rendered.height, base.height)
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        var count = 0
        var sumX = 0.0
        var sumY = 0.0
        for y in 0..<min(rendered.height, base.height) {
            for x in 0..<min(rendered.width, base.width) {
                let lhs = rendered.pixel(x, y)
                let rhs = base.pixel(x, y)
                let difference = max(abs(Int(lhs.r) - Int(rhs.r)),
                                     max(abs(Int(lhs.g) - Int(rhs.g)),
                                         max(abs(Int(lhs.b) - Int(rhs.b)),
                                             abs(Int(lhs.a) - Int(rhs.a)))))
                guard difference > tolerance else { continue }
                count += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                sumX += Double(x); sumY += Double(y)
            }
        }
        guard count > 0 else { return nil }
        return Region(minX: minX, maxX: maxX, minY: minY, maxY: maxY,
                      count: count,
                      centroidX: sumX / Double(count),
                      centroidY: sumY / Double(count))
    }

    private func region(in rendered: Bitmap, comparedTo base: Bitmap) -> Region? {
        changedRegion(rendered, comparedTo: base)
    }

    private func assertConfigurationError(_ error: Error,
                                          contains text: String,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) {
        guard let atelierError = error as? AtelierError,
              case .invalidConfiguration(let message) = atelierError else {
            XCTFail("期望 invalidConfiguration，实际：\(error)", file: file, line: line)
            return
        }
        XCTAssertTrue(message.contains(text), "错误信息应包含「\(text)」，实际：\(message)",
                      file: file, line: line)
    }

    private func makeImageFile(name: String,
                               width: Int,
                               height: Int,
                               type: UTType,
                               draw: (CGContext) -> Void) throws -> URL {
        let directory = try TestFiles.makeTemporaryDirectory()
        temporaryDirectories.append(directory)
        let url = directory.appendingPathComponent(name)
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AtelierError.imageWrite("测试水印图片上下文创建失败")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldAntialias(false)
        draw(context)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                type.identifier as CFString,
                                                                1, nil) else {
            throw AtelierError.imageWrite("测试水印图片编码失败")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AtelierError.imageWrite("测试水印图片写入失败")
        }
        return url
    }

    private func decodedAlpha(_ url: URL, x: Int, y: Int) throws -> UInt8 {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AtelierError.imageRead("测试无法解码水印图片")
        }
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered, x >= 0, y >= 0, x < width, y < height else {
            throw AtelierError.imageRead("测试水印图片像素越界")
        }
        return data[(y * width + x) * 4 + 3]
    }
}

/// Small RGBA8 raster helper for watermark pixel assertions.
private struct Bitmap {
    let width: Int
    let height: Int
    let data: [UInt8]

    func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let offset = (y * width + x) * 4
        return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
    }
}

/// Bounding box / centroid / count of pixels that differ from the base image,
/// in raster coordinates where row 0 is the visual top.
private struct Region {
    let minX: Int
    let maxX: Int
    let minY: Int
    let maxY: Int
    let count: Int
    let centroidX: Double
    let centroidY: Double

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

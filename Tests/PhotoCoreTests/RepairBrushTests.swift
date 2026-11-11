import XCTest
import CoreGraphics
import CoreImage
import Foundation
@testable import PhotoCore

/// Repair-brush contract tests on synthetic fixtures only (gradients, patches and
/// painted defects). They prove geometry, blending, feathering, determinism and
/// error behaviour; they do not claim real-photo retouch quality.
final class RepairBrushTests: XCTestCase {
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: colorSpace,
        .outputColorSpace: colorSpace,
        .cacheIntermediates: false
    ])

    // MARK: - Identity / determinism

    func testEmptyStrokeListReturnsTheInputImageUnchanged() throws {
        let base = try makeGradientBackground(width: 120, height: 80)
        let output = try RepairBrushEngine.apply(to: base, strokes: [])
        XCTAssertTrue(output === base, "空笔迹必须直接返回输入图像对象")
        XCTAssertEqual(try render(output), try render(base))
    }

    func testStrengthZeroIsPixelIdentity() throws {
        let base = try makeGradientBackground(width: 120, height: 80)
        var stroke = RepairStroke(mode: .clone,
                                  points: [MaskPoint(x: 0.3, y: 0.5), MaskPoint(x: 0.5, y: 0.5)],
                                  radius: 0.08, feather: 0.4, strength: 0)
        stroke.cloneOffset = MaskPoint(x: 0.5, y: 0)
        let output = try RepairBrushEngine.apply(to: base, strokes: [stroke])
        XCTAssertEqual(try render(output), try render(base), "strength=0 必须是逐像素恒等")
    }

    func testRenderingIsDeterministicForMixedStrokes() throws {
        let base = try makeGradientBackground(width: 160, height: 100)
        var heal = RepairStroke(mode: .heal,
                                points: [MaskPoint(x: 0.4, y: 0.3), MaskPoint(x: 0.4, y: 0.7)],
                                radius: 0.07, feather: 0.5, strength: 0.9)
        heal.id = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
        var clone = RepairStroke(mode: .clone,
                                 points: [MaskPoint(x: 0.7, y: 0.5)],
                                 radius: 0.06, feather: 0.3, strength: 1)
        clone.id = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!
        clone.cloneOffset = MaskPoint(x: -0.3, y: 0.1)
        let strokes = [heal, clone]
        let first = try RepairBrushEngine.apply(to: base, strokes: strokes)
        let second = try RepairBrushEngine.apply(to: base, strokes: strokes)
        XCTAssertEqual(try render(first), try render(second), "相同输入必须产生逐字节相同的输出")
    }

    // MARK: - Heal

    func testHealReducesDefectContrastAndLeavesOutsidePixelsUntouched() throws {
        let width = 240, height = 160
        let base = try makeGradientBackgroundWithDefect(width: width, height: height)
        let before = try render(base)
        let defect = defectRect(width: width, height: height)
        let ring = ringRect(width: width, height: height)
        let contrastBefore = abs(meanLuma(before, in: defect) - meanLuma(before, in: ring))
        XCTAssertGreaterThan(contrastBefore, 0.25, "夹具缺陷必须与邻域有足够对比")

        let stroke = RepairStroke(mode: .heal,
                                  points: [MaskPoint(x: 0.5, y: 0.36), MaskPoint(x: 0.5, y: 0.64)],
                                  radius: 0.09, feather: 0.6, strength: 1)
        let output = try RepairBrushEngine.apply(to: base, strokes: [stroke])
        XCTAssertEqual(output.extent, base.extent, "修复画笔不得改变图像 extent")
        let after = try render(output)
        let defectAfter = meanLuma(after, in: defect)
        let ringAfter = meanLuma(after, in: ring)
        let contrastAfter = abs(defectAfter - ringAfter)
        XCTAssertLessThan(contrastAfter, contrastBefore * 0.4,
                          "heal 后缺陷与邻域对比应显著下降（before \(contrastBefore)，after \(contrastAfter)）")
        XCTAssertGreaterThan(defectAfter, meanLuma(before, in: defect) + 0.15,
                             "heal 必须把暗缺陷拉回背景亮度方向")

        // 笔迹足迹之外的像素必须逐字节不变（左半幅与笔迹右侧远处）。
        for region in [rasterRect(x: 0, y: 0, width: 60, height: height, imageHeight: height),
                       rasterRect(x: 200, y: 0, width: 40, height: height, imageHeight: height)] {
            assertRegionsEqual(before, after, region)
        }
    }

    func testHealOnUniformBackgroundDoesNotIntroduceHueShift() throws {
        let base = try makeSolidImage(width: 120, height: 80, red: 0.45, green: 0.5, blue: 0.55)
        let stroke = RepairStroke(mode: .heal,
                                  points: [MaskPoint(x: 0.5, y: 0.5)],
                                  radius: 0.12, feather: 0.7, strength: 1)
        let output = try RepairBrushEngine.apply(to: base, strokes: [stroke])
        let rendered = try render(output)
        let center = rendered.pixel(x: 60, y: 40)
        XCTAssertEqual(center.red, 115, accuracy: 4, "均匀底色修补后中心颜色应接近原色")
        XCTAssertEqual(center.green, 128, accuracy: 4)
        XCTAssertEqual(center.blue, 140, accuracy: 4)
    }

    // MARK: - Clone

    func testCloneCopiesTheSourceRegionVerbatim() throws {
        let width = 240, height = 160
        let base = try makeBackgroundWithColourPatch(width: width, height: height,
                                                     patch: CGPoint(x: 180, y: 80),
                                                     red: 0.9, green: 0.1, blue: 0.1)
        let before = try render(base)
        let target = MaskPoint(x: 60.0 / Double(width), y: 80.0 / Double(height))
        var stroke = RepairStroke(mode: .clone, points: [target], radius: 0.06,
                                  feather: 0.4, strength: 1)
        stroke.cloneOffset = MaskPoint(x: 120.0 / Double(width), y: 0)
        let output = try RepairBrushEngine.apply(to: base, strokes: [stroke])
        let after = try render(output)
        let center = after.pixel(x: 60, y: 79)
        XCTAssertGreaterThan(center.red, 220, "clone 中心必须复制来源红色")
        XCTAssertLessThan(center.green, 60)
        XCTAssertLessThan(center.blue, 60)
        XCTAssertGreaterThan(meanRed(after, in: rasterRect(x: 54, y: 73, width: 12, height: 12,
                                                           imageHeight: height)), 200)
        // 来源区域不受影响。
        assertRegionsEqual(before, after, rasterRect(x: 165, y: 65, width: 30, height: 30,
                                                     imageHeight: height))
        _ = width
    }

    func testCloneCopiesSourceExactlyAtFullStrengthCore() throws {
        let base = try makeBackgroundWithColourPatch(width: 120, height: 80,
                                                     patch: CGPoint(x: 30, y: 40),
                                                     red: 0.2, green: 0.8, blue: 0.3)
        var stroke = RepairStroke(mode: .clone, points: [MaskPoint(x: 0.75, y: 0.5)],
                                  radius: 0.03, feather: 0, strength: 1)
        stroke.cloneOffset = MaskPoint(x: 30.0 / 120.0 - 0.75, y: 0)
        let output = try RepairBrushEngine.apply(to: base, strokes: [stroke])
        let after = try render(output)
        let center = after.pixel(x: 90, y: 39)
        XCTAssertEqual(center.red, 51, accuracy: 3)
        XCTAssertEqual(center.green, 204, accuracy: 3)
        XCTAssertEqual(center.blue, 76, accuracy: 3)
    }

    // MARK: - Footprint / feather

    func testStrokeFootprintDoesNotBleedOutsideItsBox() throws {
        let width = 240, height = 160
        let base = try makeGradientBackgroundWithDefect(width: width, height: height)
        let before = try render(base)
        var stroke = RepairStroke(mode: .clone,
                                  points: [MaskPoint(x: 0.5, y: 0.5)],
                                  radius: 0.08, feather: 0.3, strength: 1)
        stroke.cloneOffset = MaskPoint(x: 0.4, y: 0)
        let output = try RepairBrushEngine.apply(to: base, strokes: [stroke])
        let after = try render(output)
        XCTAssertEqual(output.extent, base.extent)
        // 足迹中心 (120,80) 控制点、半径 12.8、羽化 ~3px；包络 40x40 之外必须不变。
        let keep = rasterRect(x: 0, y: 0, width: width, height: height, imageHeight: height)
        let footprint = CGRect(x: 100, y: 60, width: 40, height: 40)
        var outsideChecked = 0
        for row in 0..<height {
            for column in 0..<width {
                let rasterPoint = CGPoint(x: Double(column), y: Double(row))
                if footprint.contains(rasterPoint) { continue }
                outsideChecked += 1
                let a = before.pixel(x: column, y: row), b = after.pixel(x: column, y: row)
                if a != b {
                    XCTFail("笔迹足迹外像素被修改：x=\(column), y=\(row)")
                    return
                }
            }
        }
        XCTAssertGreaterThan(outsideChecked, width * height / 2)
        _ = keep
    }

    func testFeatherSmoothsTheStrokeEdge() throws {
        let width = 240, height = 160
        // Wide patch: the whole clone disc must sample pure red, so the only
        // transition on the scan line comes from the stroke mask edge itself.
        let base = try makeImage(width: width, height: height) { x, y in
            if abs(Double(x) - 180) <= 30, abs(Double(y) - 80) <= 30 { return (0.9, 0.1, 0.1) }
            return (0.5, 0.5, 0.5)
        }
        var hard = RepairStroke(mode: .clone, points: [MaskPoint(x: 0.25, y: 0.5)],
                                radius: 0.08, feather: 0, strength: 1)
        hard.cloneOffset = MaskPoint(x: 0.5, y: 0)
        var soft = hard
        soft.id = UUID()
        soft.feather = 0.9
        let hardPixels = try render(try RepairBrushEngine.apply(to: base, strokes: [hard]))
        let softPixels = try render(try RepairBrushEngine.apply(to: base, strokes: [soft]))
        let hardTransition = transitionCount(hardPixels, row: 79, startX: 60, endX: 100)
        let softTransition = transitionCount(softPixels, row: 79, startX: 60, endX: 100)
        XCTAssertGreaterThan(hardTransition, 0, "硬边也应有少量抗锯齿过渡")
        XCTAssertGreaterThan(softTransition, hardTransition + 3,
                             "羽化必须产生更宽的平滑过渡（hard=\(hardTransition), soft=\(softTransition)）")
    }

    // MARK: - Edge cases / validation

    func testStrokeAtCanvasCornerStaysInsideAndFinite() throws {
        let width = 200, height = 140
        let base = try makeGradientBackground(width: width, height: height)
        let before = try render(base)
        var stroke = RepairStroke(mode: .clone, points: [MaskPoint(x: 0.02, y: 0.02)],
                                  radius: 0.1, feather: 0.5, strength: 1)
        stroke.cloneOffset = MaskPoint(x: 0.3, y: 0.3)
        var heal = RepairStroke(mode: .heal, points: [MaskPoint(x: 0.98, y: 0.98)],
                                radius: 0.1, feather: 0.5, strength: 1)
        heal.id = UUID()
        let output = try RepairBrushEngine.apply(to: base, strokes: [stroke, heal])
        XCTAssertEqual(output.extent, base.extent)
        let after = try render(output)
        XCTAssertNotEqual(before.data, after.data, "角落笔迹必须局部生效")
        // 中部区域不受两个角落笔迹影响。
        assertRegionsEqual(before, after,
                           rasterRect(x: 70, y: 40, width: 60, height: 60, imageHeight: height))
    }

    func testMultipleStrokesAreAppliedInOrder() throws {
        let width = 200, height = 140
        // Red patch at x=40, blue patch at x=160; clone each onto the centre band.
        let base = try makeImage(width: width, height: height) { x, y in
            let fx = Double(x), fy = Double(y)
            if abs(fx - 40) <= 10, abs(fy - 70) <= 10 { return (0.95, 0.05, 0.05) }
            if abs(fx - 160) <= 10, abs(fy - 70) <= 10 { return (0.05, 0.1, 0.95) }
            return (0.5, 0.5, 0.5)
        }
        var first = RepairStroke(mode: .clone, points: [MaskPoint(x: 0.4, y: 0.5)],
                                 radius: 0.05, feather: 0.2, strength: 1)
        first.cloneOffset = MaskPoint(x: -40.0 / 200.0, y: 0) // donor centre x=40
        var second = RepairStroke(mode: .clone, points: [MaskPoint(x: 0.6, y: 0.5)],
                                  radius: 0.05, feather: 0.2, strength: 1)
        second.id = UUID()
        second.cloneOffset = MaskPoint(x: 160.0 / 200.0 - 0.6, y: 0) // donor centre x=160
        let after = try render(try RepairBrushEngine.apply(to: base, strokes: [first, second]))
        let firstCenter = after.pixel(x: 80, y: 69)
        let secondCenter = after.pixel(x: 120, y: 69)
        XCTAssertGreaterThan(firstCenter.red, 200, "第一笔应复制红色")
        XCTAssertLessThan(firstCenter.green, 60)
        XCTAssertGreaterThan(secondCenter.blue, 200, "第二笔应复制蓝色且不被第一笔覆盖")
        XCTAssertLessThan(secondCenter.green, 60)
    }

    func testPixelRadiusUsesShorterImageEdge() {
        let stroke = RepairStroke(mode: .heal, points: [MaskPoint(x: 0.5, y: 0.5)], radius: 0.1)
        XCTAssertEqual(stroke.pixelRadius(for: CGRect(x: 0, y: 0, width: 400, height: 200)),
                       20, accuracy: 0.0001, "半径按短边 200×0.1=20px，而不是按宽 40px")
    }

    func testInvalidStrokesThrowExplicitErrors() throws {
        let base = try makeSolidImage(width: 40, height: 30, red: 0.5, green: 0.5, blue: 0.5)
        func expectInvalid(_ stroke: RepairStroke, _ label: String) {
            XCTAssertThrowsError(try RepairBrushEngine.apply(to: base, strokes: [stroke]), label) { error in
                guard let atelierError = error as? AtelierError,
                      case .invalidConfiguration = atelierError else {
                    XCTFail("\(label)：应抛 invalidConfiguration，实际 \(error)")
                    return
                }
            }
        }
        var valid = RepairStroke(mode: .heal, points: [MaskPoint(x: 0.5, y: 0.5)],
                                 radius: 0.1, feather: 0.5, strength: 1)
        XCTAssertNoThrow(try RepairBrushEngine.apply(to: base, strokes: [valid]))

        var emptyPoints = valid; emptyPoints.points = []
        expectInvalid(emptyPoints, "空点列")
        var nanPoint = valid; nanPoint.points = [MaskPoint(x: .nan, y: 0)]
        expectInvalid(nanPoint, "NaN 坐标")
        var nanRadius = valid; nanRadius.radius = .nan
        expectInvalid(nanRadius, "NaN 半径")
        var zeroRadius = valid; zeroRadius.radius = 0
        expectInvalid(zeroRadius, "零半径")
        var hugeRadius = valid; hugeRadius.radius = 0.9
        expectInvalid(hugeRadius, "超大半径")
        var badFeather = valid; badFeather.feather = 1.5
        expectInvalid(badFeather, "羽化越界")
        var nanFeather = valid; nanFeather.feather = .nan
        expectInvalid(nanFeather, "NaN 羽化")
        var badStrength = valid; badStrength.strength = -0.1
        expectInvalid(badStrength, "强度为负")
        var nanStrength = valid; nanStrength.strength = .nan
        expectInvalid(nanStrength, "NaN 强度")
        var infiniteOffset = valid; infiniteOffset.cloneOffset = MaskPoint(x: .infinity, y: 0)
        expectInvalid(infiniteOffset, "无穷来源偏移")
        var hugeOffset = valid; hugeOffset.cloneOffset = MaskPoint(x: 1.5, y: 0)
        expectInvalid(hugeOffset, "越界来源偏移")

        // 无效底图 extent 也应显式报错。
        let emptyImage = CIImage(color: .clear).cropped(to: .zero)
        XCTAssertThrowsError(try RepairBrushEngine.apply(to: emptyImage, strokes: [valid]))

        // 笔迹数量有上限。
        let tooMany = Array(repeating: valid, count: RepairBrushEngine.maximumStrokeCount + 1)
        XCTAssertThrowsError(try RepairBrushEngine.apply(to: base, strokes: tooMany),
                             "笔迹数量超过上限应显式报错")
    }

    // MARK: - Fixtures

    private func makeGradientBackground(width: Int, height: Int) throws -> CIImage {
        try makeImage(width: width, height: height) { x, _ in
            let fx = Double(x) / Double(max(width - 1, 1))
            let value = 0.25 + 0.5 * fx
            return (value, value, value)
        }
    }

    private func makeGradientBackgroundWithDefect(width: Int, height: Int) throws -> CIImage {
        let defect = defectRect(width: width, height: height)
        return try makeImage(width: width, height: height) { x, y in
            if defect.contains(CGPoint(x: Double(x), y: Double(y))) {
                return (0.08, 0.08, 0.08)
            }
            let fx = Double(x) / Double(max(width - 1, 1))
            let value = 0.25 + 0.5 * fx
            return (value, value, value)
        }
    }

    private func makeBackgroundWithColourPatch(width: Int, height: Int, patch: CGPoint,
                                               red: Double, green: Double, blue: Double) throws -> CIImage {
        try makeImage(width: width, height: height) { x, y in
            let dx = Double(x) - patch.x
            let dy = Double(y) - patch.y
            if abs(dx) <= 10, abs(dy) <= 10 { return (red, green, blue) }
            return (0.5, 0.5, 0.5)
        }
    }

    private func makeSolidImage(width: Int, height: Int,
                                red: Double, green: Double, blue: Double) throws -> CIImage {
        try makeImage(width: width, height: height) { _, _ in (red, green, blue) }
    }

    private func makeImage(width: Int, height: Int,
                           colour: (_ x: Int, _ y: Int) -> (Double, Double, Double)) throws -> CIImage {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AtelierError.imageWrite("测试底图创建失败")
        }
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue) = colour(x, y)
                context.setFillColor(CGColor(colorSpace: colorSpace,
                                             components: [CGFloat(red), CGFloat(green), CGFloat(blue), 1])!)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        guard let cgImage = context.makeImage() else {
            throw AtelierError.imageWrite("测试底图栅格化失败")
        }
        return CIImage(cgImage: cgImage)
    }

    private func defectRect(width: Int, height: Int) -> CGRect {
        CGRect(x: width / 2 - 6, y: height / 2 - 6, width: 12, height: 12)
    }

    private func ringRect(width: Int, height: Int) -> CGRect {
        // Right of the vertical heal stroke, same rows as the defect.
        CGRect(x: width / 2 + 24, y: height / 2 - 6, width: 12, height: 12)
    }

    /// Converts a top-down raster rectangle into the coordinates used by the
    /// raster helpers (row 0 is the visual top for `Bitmap`).
    private func rasterRect(x: Int, y: Int, width: Int, height: Int, imageHeight: Int) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    private func transitionCount(_ bitmap: Bitmap, row: Int, startX: Int, endX: Int) -> Int {
        var count = 0
        for x in startX...endX {
            let green = bitmap.pixel(x: x, y: row).green
            if green > 30 && green < 100 { count += 1 }
        }
        return count
    }

    // MARK: - Raster helpers

    private struct Bitmap: Equatable {
        let width: Int
        let height: Int
        let data: [UInt8]

        func pixel(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
            let offset = (y * width + x) * 4
            return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
        }
    }

    private func render(_ image: CIImage) throws -> Bitmap {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0,
              let cgImage = context.createCGImage(image, from: extent, format: .RGBA8,
                                                  colorSpace: colorSpace) else {
            throw AtelierError.imageWrite("测试渲染失败")
        }
        let width = cgImage.width, height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let bitmap = CGContext(data: buffer.baseAddress, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: colorSpace,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw AtelierError.imageWrite("测试位图读取失败") }
        return Bitmap(width: width, height: height, data: data)
    }

    private func meanLuma(_ bitmap: Bitmap, in rect: CGRect) -> Double {
        var total = 0.0, count = 0.0
        let minX = max(0, Int(rect.minX)), maxX = min(bitmap.width - 1, Int(rect.maxX) - 1)
        let minY = max(0, Int(rect.minY)), maxY = min(bitmap.height - 1, Int(rect.maxY) - 1)
        guard minX <= maxX, minY <= maxY else { return .nan }
        for y in minY...maxY {
            for x in minX...maxX {
                let pixel = bitmap.pixel(x: x, y: y)
                total += (Double(pixel.red) + Double(pixel.green) + Double(pixel.blue)) / 3.0 / 255.0
                count += 1
            }
        }
        return count > 0 ? total / count : .nan
    }

    private func meanRed(_ bitmap: Bitmap, in rect: CGRect) -> Double {
        var total = 0.0, count = 0.0
        let minX = max(0, Int(rect.minX)), maxX = min(bitmap.width - 1, Int(rect.maxX) - 1)
        let minY = max(0, Int(rect.minY)), maxY = min(bitmap.height - 1, Int(rect.maxY) - 1)
        guard minX <= maxX, minY <= maxY else { return .nan }
        for y in minY...maxY {
            for x in minX...maxX {
                total += Double(bitmap.pixel(x: x, y: y).red)
                count += 1
            }
        }
        return count > 0 ? total / count : .nan
    }

    private func assertRegionsEqual(_ lhs: Bitmap, _ rhs: Bitmap, _ rect: CGRect,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let minX = max(0, Int(rect.minX)), maxX = min(min(lhs.width, rhs.width) - 1, Int(rect.maxX) - 1)
        let minY = max(0, Int(rect.minY)), maxY = min(min(lhs.height, rhs.height) - 1, Int(rect.maxY) - 1)
        guard minX <= maxX, minY <= maxY else {
            XCTFail("空的比较区域 \(rect)", file: file, line: line)
            return
        }
        for y in minY...maxY {
            for x in minX...maxX {
                let a = lhs.pixel(x: x, y: y), b = rhs.pixel(x: x, y: y)
                if a != b {
                    XCTFail("像素被意外修改：x=\(x), y=\(y) before=\(a) after=\(b)",
                            file: file, line: line)
                    return
                }
            }
        }
    }
}

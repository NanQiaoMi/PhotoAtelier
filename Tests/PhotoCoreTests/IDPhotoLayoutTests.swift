import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

/// Pure-geometry tests for B1 certificate-photo cropping and print layouts.
///
/// All fixtures are synthetic (gradients + hand-set face boxes); nothing here is
/// a real-photo aesthetic evaluation. DPI math uses the documented 25.4 mm/inch
/// conversion with rounded whole pixels.
final class IDPhotoLayoutTests: XCTestCase {
    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: true,
        .cacheIntermediates: false
    ])

    // MARK: - Fixtures

    private func makeGradient(width: Int, height: Int) -> CIImage {
        var components = [Float]()
        components.reserveCapacity(width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let x = Float(column) / Float(width - 1)
                let y = Float(row) / Float(height - 1)
                components.append(0.1 + 0.8 * x)
                components.append(0.1 + 0.7 * y)
                components.append(0.2)
                components.append(1)
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

    // MARK: - Pixel sizes

    func testPixelSizesAt300And600DPI() {
        let expectedAt300: [IDPhotoSize: CGSize] = [
            .oneInch: CGSize(width: 295, height: 413),
            .twoInch: CGSize(width: 413, height: 579),
            .smallOneInch: CGSize(width: 260, height: 378),
            .largeOneInch: CGSize(width: 390, height: 567),
            .smallTwoInch: CGSize(width: 413, height: 531)
        ]
        for size in IDPhotoSize.allCases {
            let pixels = IDPhotoLayout.pixelSize(for: size, dpi: 300)
            XCTAssertEqual(pixels.width, expectedAt300[size]!.width,
                           "\(size.title) 300DPI 宽度像素")
            XCTAssertEqual(pixels.height, expectedAt300[size]!.height,
                           "\(size.title) 300DPI 高度像素")
            // Independent rounding at each DPI can differ by ±1 pixel from
            // exactly doubling the 300DPI value; both are valid whole-pixel sizes.
            let doubleDPI = IDPhotoLayout.pixelSize(for: size, dpi: 600)
            XCTAssertLessThanOrEqual(abs(doubleDPI.width - expectedAt300[size]!.width * 2), 1,
                                     "\(size.title) 600DPI 应约等于 300DPI 的双倍")
            XCTAssertLessThanOrEqual(abs(doubleDPI.height - expectedAt300[size]!.height * 2), 1)
        }
        // Millimetre definitions are the documented standard sizes.
        XCTAssertEqual(IDPhotoSize.oneInch.millimeters, CGSize(width: 25, height: 35))
        XCTAssertEqual(IDPhotoSize.twoInch.millimeters, CGSize(width: 35, height: 49))
        XCTAssertEqual(IDPhotoSize.smallOneInch.millimeters, CGSize(width: 22, height: 32))
        XCTAssertEqual(IDPhotoSize.largeOneInch.millimeters, CGSize(width: 33, height: 48))
        XCTAssertEqual(IDPhotoSize.smallTwoInch.millimeters, CGSize(width: 35, height: 45))
        XCTAssertEqual(IDPhotoLayout.pixelSize(for: .oneInch, dpi: 0), .zero)
    }

    // MARK: - Cropping

    func testCropRectPlacesHeadAtRatioAndCentresFace() throws {
        let sourceSize = CGSize(width: 1200, height: 1600)
        let faceBox = CGRect(x: 0.38, y: 0.42, width: 0.24, height: 0.20)
        var settings = IDPhotoCropSettings(size: .oneInch, dpi: 300)
        settings.headHeightRatio = 0.62
        settings.headTopMarginRatio = 0.08
        let rect = try IDPhotoLayout.cropRect(faceBox: faceBox, sourceSize: sourceSize,
                                              settings: settings)
        let target = IDPhotoLayout.pixelSize(for: .oneInch, dpi: 300)
        let targetAspect = Double(target.width) / Double(target.height)
        XCTAssertEqual(Double(rect.width) / Double(rect.height), targetAspect, accuracy: 1e-9,
                       "裁剪矩形宽高比必须匹配证件照像素比例")
        XCTAssertEqual(Double(rect.midX), 0.50 * 1200, accuracy: 2,
                       "人脸水平中心应落在裁剪中心（默认无偏移）")
        let headTop = (Double(faceBox.maxY) + 0.30 * Double(faceBox.height)) * 1600
        let margin = Double(rect.maxY) - headTop
        XCTAssertEqual(margin, settings.headTopMarginRatio * Double(rect.height), accuracy: 2,
                       "头顶留白应等于 headTopMarginRatio×裁剪高度")
        let headHeight = (Double(faceBox.maxY) + 0.30 * Double(faceBox.height)
                          - Double(faceBox.minY)) * 1600
        XCTAssertEqual(headHeight / Double(rect.height), settings.headHeightRatio, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxX, sourceSize.width)
        XCTAssertLessThanOrEqual(rect.maxY, sourceSize.height)
    }

    func testCropRectClampsToSourceBoundsNearEdges() throws {
        let sourceSize = CGSize(width: 800, height: 1000)
        let faceBox = CGRect(x: 0.84, y: 0.42, width: 0.15, height: 0.20)
        let rect = try IDPhotoLayout.cropRect(faceBox: faceBox, sourceSize: sourceSize,
                                              settings: IDPhotoCropSettings(size: .oneInch))
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertLessThanOrEqual(rect.maxX, sourceSize.width + 1e-6)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxY, sourceSize.height + 1e-6)
        // Horizontal offset still produces a valid in-bounds crop.
        var shifted = IDPhotoCropSettings(size: .oneInch)
        shifted.horizontalOffset = 0.2
        let shiftedRect = try IDPhotoLayout.cropRect(faceBox: faceBox, sourceSize: sourceSize,
                                                     settings: shifted)
        XCTAssertGreaterThanOrEqual(shiftedRect.minX, 0)
        XCTAssertLessThanOrEqual(shiftedRect.maxX, sourceSize.width + 1e-6)
    }

    func testRenderProducesExactPixelSizeAndPlausibleContent() throws {
        let width = 1200, height = 1600
        let photo = makeGradient(width: width, height: height)
        let faceBox = CGRect(x: 0.40, y: 0.42, width: 0.20, height: 0.20)
        var settings = IDPhotoCropSettings(size: .oneInch, dpi: 300)
        settings.horizontalOffset = 0
        let rendered = try IDPhotoLayout.render(photo: photo, faceBox: faceBox,
                                                settings: settings)
        let target = IDPhotoLayout.pixelSize(for: .oneInch, dpi: 300)
        XCTAssertEqual(rendered.extent, CGRect(origin: .zero, size: target),
                       "证件照输出必须是指定 DPI 下的精确像素尺寸")
        // The horizontal gradient means the centre color must be close to the
        // source color at the crop centre (Lanczos on a smooth gradient).
        let rect = try IDPhotoLayout.cropRect(faceBox: faceBox,
                                              sourceSize: CGSize(width: width, height: height),
                                              settings: settings)
        let centerX = Int(rect.midX)
        let centerY = Int(rect.midY)
        let sourceCenter = renderPixel(photo, x: centerX, y: centerY)
        let outputCenter = renderPixel(rendered, x: Int(target.width / 2),
                                       y: Int(target.height / 2))
        XCTAssertEqual(Double(outputCenter[0]), Double(sourceCenter[0]), accuracy: 0.05)
        XCTAssertEqual(Double(outputCenter[1]), Double(sourceCenter[1]), accuracy: 0.05)
        // Determinism.
        let again = try IDPhotoLayout.render(photo: photo, faceBox: faceBox,
                                             settings: settings)
        var first = [Float](repeating: 0, count: Int(target.width * target.height * 4))
        var second = first
        first.withUnsafeMutableBytes { buffer in
            context.render(rendered, toBitmap: buffer.baseAddress!,
                           rowBytes: Int(target.width) * 16,
                           bounds: rendered.extent, format: .RGBAf, colorSpace: linearColorSpace)
        }
        second.withUnsafeMutableBytes { buffer in
            context.render(again, toBitmap: buffer.baseAddress!,
                           rowBytes: Int(target.width) * 16,
                           bounds: again.extent, format: .RGBAf, colorSpace: linearColorSpace)
        }
        XCTAssertEqual(first, second)
    }

    func testCropValidationRejectsInvalidFaceBoxAndDPI() {
        XCTAssertThrowsError(try IDPhotoLayout.cropRect(faceBox: .zero,
                                                        sourceSize: CGSize(width: 100, height: 100)))
        XCTAssertThrowsError(try IDPhotoLayout.cropRect(faceBox: CGRect(x: 2, y: 2, width: 0.1, height: 0.1),
                                                        sourceSize: CGSize(width: 100, height: 100)))
        XCTAssertThrowsError(try IDPhotoLayout.cropRect(faceBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                                                        sourceSize: CGSize(width: 100, height: 100),
                                                        settings: IDPhotoCropSettings(dpi: 10)))
        XCTAssertThrowsError(try IDPhotoLayout.cropRect(faceBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                                                        sourceSize: CGSize(width: 1, height: 1)))
        XCTAssertThrowsError(try IDPhotoCropSettings(headHeightRatio: 1.2).validated())
        XCTAssertThrowsError(try IDPhotoCropSettings(headTopMarginRatio: -0.1).validated())
        XCTAssertThrowsError(try IDPhotoCropSettings(faceInflate: 2).validated())
    }

    // MARK: - Print layout

    func testPrintLayoutSixInchOneInchAutoGrid() throws {
        let settings = PrintSheetSettings(paper: .sixInch, dpi: 300,
                                          rows: nil, columns: nil,
                                          spacingMM: 2, marginMM: 3, photoSize: .oneInch)
        let layout = try IDPhotoLayout.printLayout(settings)
        XCTAssertEqual(layout.paperPixelSize, CGSize(width: 1200, height: 1800))
        XCTAssertEqual(layout.photoPixelSize, CGSize(width: 295, height: 413))
        XCTAssertEqual(layout.columns, 3)
        XCTAssertEqual(layout.rows, 4)
        XCTAssertEqual(layout.count, 12)
        XCTAssertEqual(layout.cellOrigins.count, 12)
        XCTAssertEqual(layout.marginPixels, 35)
        XCTAssertEqual(layout.spacingPixels, 24)

        // Centred grid, row-major from the bottom-left cell.
        let gridWidth = 3.0 * 295 + 2.0 * 24
        let gridHeight = 4.0 * 413 + 3.0 * 24
        XCTAssertEqual(layout.cellOrigins[0].x, (1200 - gridWidth) / 2, accuracy: 0.001)
        XCTAssertEqual(layout.cellOrigins[0].y, (1800 - gridHeight) / 2, accuracy: 0.001)
        XCTAssertEqual(layout.cellOrigins[1].x - layout.cellOrigins[0].x, 295 + 24, accuracy: 0.001)
        XCTAssertEqual(layout.cellOrigins[3].y - layout.cellOrigins[0].y, 413 + 24, accuracy: 0.001)

        // Every cell stays inside the paper with the documented margin.
        for origin in layout.cellOrigins {
            XCTAssertGreaterThanOrEqual(origin.x, layout.marginPixels - 0.5)
            XCTAssertGreaterThanOrEqual(origin.y, layout.marginPixels - 0.5)
            XCTAssertLessThanOrEqual(origin.x + 295, 1200 - layout.marginPixels + 0.5)
            XCTAssertLessThanOrEqual(origin.y + 413, 1800 - layout.marginPixels + 0.5)
        }
        // Determinism.
        let again = try IDPhotoLayout.printLayout(settings)
        XCTAssertEqual(layout, again)
    }

    func testPrintLayoutA4AutoGridAndExplicitCounts() throws {
        let auto = try IDPhotoLayout.printLayout(PrintSheetSettings(paper: .a4, dpi: 300,
                                                                    spacingMM: 3, marginMM: 5,
                                                                    photoSize: .oneInch))
        XCTAssertEqual(auto.paperPixelSize, CGSize(width: 2480, height: 3508))
        XCTAssertEqual(auto.columns, 7)
        XCTAssertEqual(auto.rows, 7)
        XCTAssertEqual(auto.count, 49)

        let explicit = try IDPhotoLayout.printLayout(PrintSheetSettings(paper: .sixInch, dpi: 300,
                                                                        rows: 2, columns: 3,
                                                                        spacingMM: 2, marginMM: 3,
                                                                        photoSize: .oneInch))
        XCTAssertEqual(explicit.rows, 2)
        XCTAssertEqual(explicit.columns, 3)
        XCTAssertEqual(explicit.count, 6)
    }

    func testPrintLayoutRejectsOverflowAndInvalidSettings() {
        // Five one-inch columns do not fit on a 6-inch sheet.
        XCTAssertThrowsError(try IDPhotoLayout.printLayout(
            PrintSheetSettings(paper: .sixInch, dpi: 300, rows: nil, columns: 5,
                               spacingMM: 2, marginMM: 3, photoSize: .oneInch)))
        XCTAssertThrowsError(try IDPhotoLayout.printLayout(
            PrintSheetSettings(paper: .sixInch, dpi: 300, rows: 0, columns: nil)))
        XCTAssertThrowsError(try IDPhotoLayout.printLayout(
            PrintSheetSettings(paper: .sixInch, dpi: 300, rows: 21, columns: nil)))
        XCTAssertThrowsError(try IDPhotoLayout.printLayout(
            PrintSheetSettings(paper: .sixInch, dpi: 0)))
        XCTAssertThrowsError(try IDPhotoLayout.printLayout(
            PrintSheetSettings(paper: .fiveInch, dpi: 300, marginMM: 50)))
        XCTAssertThrowsError(try PrintSheetSettings(spacingMM: -1).validated())
        XCTAssertThrowsError(try PrintSheetSettings(marginMM: 60).validated())
    }
}

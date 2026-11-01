import XCTest
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCore

final class IOTests: XCTestCase {
    func testScanFindsNestedImagesAndSkipsSymbolicLinks() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let nested = input.appendingPathComponent("album", isDirectory: true)
        let outside = temp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try TestFiles.writeFixture(to: nested.appendingPathComponent("kept.png"), width: 3, height: 2)
        try TestFiles.writeFixture(to: outside.appendingPathComponent("outside.png"), width: 2, height: 2)
        try FileManager.default.createSymbolicLink(
            at: input.appendingPathComponent("linked-file.png"),
            withDestinationURL: outside.appendingPathComponent("outside.png")
        )
        try FileManager.default.createSymbolicLink(
            at: input.appendingPathComponent("linked-folder", isDirectory: true),
            withDestinationURL: outside
        )

        let shallow = try PhotoLoader.scan(folder: input, recursive: false)
        let deep = try PhotoLoader.scan(folder: input, recursive: true)
        XCTAssertTrue(shallow.isEmpty)
        XCTAssertEqual(deep.map(\.relativePath), ["album/kept.png"])
    }

    func testLoadAppliesOrientationAndPreservesEmbeddedColorSpace() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let url = temp.appendingPathComponent("oriented.tiff")
        try TestFiles.writeFixture(to: url, width: 3, height: 2, orientation: 6, type: .tiff)

        let loaded = try PhotoLoader.load(url: url, lensCorrection: true)
        XCTAssertEqual(loaded.image.extent.width, 2, accuracy: 0.01)
        XCTAssertEqual(loaded.image.extent.height, 3, accuracy: 0.01)
        XCTAssertEqual((loaded.properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 1)
        XCTAssertFalse(loaded.report.inputWasRAW)
        XCTAssertFalse(loaded.report.lensCorrectionApplied)
        XCTAssertFalse(loaded.report.warnings.isEmpty)
        XCTAssertNotNil(loaded.image.colorSpace)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let originalPixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let expected = CIImage(cgImage: originalPixels).oriented(forExifOrientation: 6)
        let context = CIContext(options: [.cacheIntermediates: false])
        XCTAssertEqual(try TestFiles.renderedPixels(loaded.image, context: context),
                       try TestFiles.renderedPixels(expected, context: context))
    }

    func testPNGAndTIFFExportsAre16BitWithRequestedICCProfile() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let context = CIContext(options: [.cacheIntermediates: false])
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 3))
        let oldMetadata: [String: Any] = [
            kCGImagePropertyExifDictionary as String: ["DateTimeOriginal": "2020:01:02 03:04:05", "PixelXDimension": 999],
            kCGImagePropertyGPSDictionary as String: ["Latitude": 35.0, "LatitudeRef": "N"],
            kCGImagePropertyTIFFDictionary as String: ["Make": "Old Camera", "Orientation": 6, "ImageWidth": 999],
            kCGImagePropertyPixelWidth as String: 999,
            kCGImagePropertyPixelHeight as String: 777,
            kCGImagePropertyProfileName as String: "Old Profile"
        ]

        for format in [ExportFormat.png, .tiff] {
            var settings = ExportSettings()
            settings.format = format
            settings.colorSpace = .displayP3
            let url = temp.appendingPathComponent("output.\(format.fileExtension)")
            try PhotoExporter.write(image: image, to: url, settings: settings, sourceProperties: oldMetadata, context: context)

            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let rendered = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(rendered.bitsPerComponent, 16, "\(format) must use 16-bit components")
            XCTAssertEqual(rendered.width, 4)
            XCTAssertEqual(rendered.height, 3)
            let profileName = rendered.colorSpace?.name as String?
            XCTAssertTrue(profileName?.localizedCaseInsensitiveContains("p3") == true, "\(format) should embed Display P3")
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 1)
            XCTAssertEqual((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue, 4)
            XCTAssertEqual((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue, 3)
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String], "Default metadata stripping removes GPS")
            XCTAssertNotEqual(properties[kCGImagePropertyProfileName as String] as? String, "Old Profile")
            if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                XCTAssertNil(exif["DateTimeOriginal"], "Default metadata stripping removes source EXIF")
                if format == .tiff {
                    XCTAssertEqual((exif["ColorSpace"] as? NSNumber)?.intValue, 65_535)
                }
            }
        }
    }

    func testOptionalMetadataRetentionKeepsSelectedExifButRewritesDimensionsAndColorSpace() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let image = CIImage(color: CIColor(red: 0.1, green: 0.5, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let context = CIContext(options: [.cacheIntermediates: false])
        var settings = ExportSettings()
        settings.format = .tiff
        settings.colorSpace = .displayP3
        settings.stripMetadata = false
        let url = temp.appendingPathComponent("retained.tiff")
        let sourceProperties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                "DateTimeOriginal": "2020:01:02 03:04:05", "PixelXDimension": 999,
                "PixelYDimension": 888, "ColorSpace": 1
            ],
            kCGImagePropertyGPSDictionary as String: ["Latitude": 35.0, "LatitudeRef": "N"],
            kCGImagePropertyTIFFDictionary as String: ["Make": "Camera", "Orientation": 6, "ImageWidth": 999],
            kCGImagePropertyPixelWidth as String: 999,
            kCGImagePropertyPixelHeight as String: 888,
            kCGImagePropertyProfileName as String: "Old Profile"
        ]
        try PhotoExporter.write(image: image, to: url, settings: settings,
                                sourceProperties: sourceProperties, context: context)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        XCTAssertEqual(exif?["DateTimeOriginal"] as? String, "2020:01:02 03:04:05")
        XCTAssertNotEqual((exif?["PixelXDimension"] as? NSNumber)?.intValue, 999)
        XCTAssertEqual((exif?["ColorSpace"] as? NSNumber)?.intValue, 65_535)
        XCTAssertEqual((gps?["Latitude"] as? NSNumber)?.doubleValue, 35.0)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 1)
        XCTAssertNotEqual(properties[kCGImagePropertyProfileName as String] as? String, "Old Profile")
    }

    func testRepeatedExportNeverOverwritesExistingFile() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let image = CIImage(color: CIColor(red: 0.1, green: 0.3, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let context = CIContext(options: [.cacheIntermediates: false])
        var settings = ExportSettings()
        settings.format = .png
        let url = temp.appendingPathComponent("same.png")

        try PhotoExporter.write(image: image, to: url, settings: settings, sourceProperties: [:], context: context)
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try PhotoExporter.write(image: image, to: url, settings: settings,
                                                     sourceProperties: [:], context: context))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testRasterAndRAWCandidatesScanAndUnsupportedRAWFailsWithoutPreviewFallback() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let rasterAndRAWNames = [
            "one.JPG", "two.jpeg", "three.png", "four.TIFF", "five.tif",
            "canon.cr2", "canon.cr3", "nikon.nef", "sony.arw", "fuji.raf",
            "olympus.orf", "panasonic.rw2", "pentax.pef", "samsung.srw", "raw.dng"
        ]
        for name in rasterAndRAWNames + ["later.heic", "notes.txt"] {
            try Data("candidate".utf8).write(to: temp.appendingPathComponent(name))
        }
        let scanned = try PhotoLoader.scan(folder: temp, recursive: false)
        XCTAssertEqual(Set(scanned.map { $0.url.lastPathComponent }), Set(rasterAndRAWNames))

        // This is deliberately corrupt RAW payload, not a camera fixture. The
        // loader must report a RAW decoder error instead of returning an ImageIO
        // preview or treating unrelated bytes as a full-resolution source.
        let corruptRAW = temp.appendingPathComponent("raw.dng")
        XCTAssertThrowsError(try PhotoLoader.load(url: corruptRAW, lensCorrection: false)) { error in
            guard let atelierError = error as? AtelierError,
                  case .imageRead(let message) = atelierError else {
                XCTFail("Expected an explicit RAW imageRead error, got: \(error)")
                return
            }
            XCTAssertTrue(message.contains("RAW 解码失败"), message)
            XCTAssertTrue(message.contains("未使用内嵌 JPEG 预览图"), message)
        }
    }

    func testJPEGIsOpaque8BitSRGBWithNormalizedOrientation() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 5, height: 3))
        let output = temp.appendingPathComponent("photo.jpg")
        try PhotoExporter.write(image: image, to: output, settings: ExportSettings(),
                                sourceProperties: [:], context: PhotoEngine().context)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let encoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(encoded.bitsPerComponent, 8)
        XCTAssertEqual(encoded.width, 5); XCTAssertEqual(encoded.height, 3)
        XCTAssertTrue([CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(encoded.alphaInfo))
        XCTAssertTrue((encoded.colorSpace?.name as String? ?? "").lowercased().contains("srgb"))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue, 1)
    }
}

enum TestFiles {
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeFixture(to url: URL, width: Int, height: Int, orientation: Int = 1,
                             type: UTType = .png) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AtelierError.imageWrite("测试图片创建失败")
        }
        bitmap.setShouldAntialias(false)
        bitmap.setFillColor(CGColor(gray: 0.05, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let corners: [(Int, Int, CGColor)] = [
            (0, 0, CGColor(red: 0.95, green: 0.08, blue: 0.08, alpha: 1)),
            (width - 1, 0, CGColor(red: 0.08, green: 0.9, blue: 0.12, alpha: 1)),
            (0, height - 1, CGColor(red: 0.08, green: 0.15, blue: 0.95, alpha: 1)),
            (width - 1, height - 1, CGColor(red: 0.95, green: 0.8, blue: 0.08, alpha: 1))
        ]
        for (x, y, color) in corners {
            bitmap.setFillColor(color)
            bitmap.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
        guard let cgImage = bitmap.makeImage() else {
            throw AtelierError.imageWrite("测试图片栅格化失败")
        }
        let typeIdentifier = type.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, typeIdentifier, 1, nil) else {
            throw AtelierError.imageWrite("测试图片目标创建失败")
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyOrientation as String: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AtelierError.imageWrite("测试图片写入失败")
        }
    }

    static func renderedPixels(_ image: CIImage, context: CIContext) throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: colorSpace),
              let data = cgImage.dataProvider?.data else {
            throw AtelierError.imageWrite("测试图像渲染失败")
        }
        return data as Data
    }
}

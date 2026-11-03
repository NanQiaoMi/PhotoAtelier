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
        let newFormatNames = ["later.heic", "later.heif", "later.avif", "later.webp"]
        for name in rasterAndRAWNames + newFormatNames + ["notes.txt"] {
            try Data("candidate".utf8).write(to: temp.appendingPathComponent(name))
        }
        let scanned = try PhotoLoader.scan(folder: temp, recursive: false)
        XCTAssertEqual(Set(scanned.map { $0.url.lastPathComponent }), Set(rasterAndRAWNames + newFormatNames))

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

    // ImageIO HEIC encode/decode was verified on this machine (macOS 13.7.8); the
    // generator uses even dimensions. HEVC round-trips the flat 0.05-gray center
    // with a small loss, so the color assertion is deliberately conservative.
    func testHEICIsGeneratedAndDecodedThroughImageIO() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let url = temp.appendingPathComponent("generated.heic")
        try TestFiles.writeFixture(to: url, width: 8, height: 6, type: .heic)
        XCTAssertTrue(PhotoLoader.isSupportedCandidate(url))

        let loaded = try PhotoLoader.load(url: url, lensCorrection: false)
        XCTAssertEqual(loaded.image.extent.width, 8, accuracy: 0.01)
        XCTAssertEqual(loaded.image.extent.height, 6, accuracy: 0.01)
        XCTAssertFalse(loaded.report.inputWasRAW)
        XCTAssertNotNil(loaded.image.colorSpace)

        let context = CIContext(options: [.cacheIntermediates: false])
        var pixel = [UInt8](repeating: 0, count: 4)
        let center = CGRect(x: 4, y: 3, width: 1, height: 1)
        context.render(loaded.image, toBitmap: &pixel, rowBytes: 4, bounds: center,
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        for channel in 0..<3 {
            XCTAssertLessThanOrEqual(abs(Int(pixel[channel]) - 13), 20,
                                     "HEIC center pixel channel \(channel) drifted: \(pixel)")
        }

        // HEIF is the same container family with a different extension; it must
        // resolve as a candidate and decode through the same ImageIO path.
        let heif = temp.appendingPathComponent("generated.heif")
        try FileManager.default.copyItem(at: url, to: heif)
        let heifLoaded = try PhotoLoader.load(url: heif, lensCorrection: false)
        XCTAssertEqual(heifLoaded.image.extent.width, 8, accuracy: 0.01)

        let scanned = try PhotoLoader.scan(folder: temp, recursive: false)
        XCTAssertEqual(Set(scanned.map { $0.url.lastPathComponent }), ["generated.heic", "generated.heif"])
        let thumbnail = try PhotoLoader.thumbnail(url: url, maxDimension: 16)
        XCTAssertEqual(thumbnail.width, 8)
        XCTAssertEqual(thumbnail.height, 6)
    }

    // ImageIO decodes WebP on macOS 13 but cannot encode it, so the fixture is a
    // checked-in 44-byte 1x1 white WebP instead of a generated file.
    func testEmbeddedWebPFixtureIsDecodedAndScanned() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let data = try XCTUnwrap(Data(base64Encoded: TestFiles.webP1x1Base64))
        XCTAssertEqual(data.count, 44)
        let url = temp.appendingPathComponent("fixture.webp")
        try data.write(to: url)
        XCTAssertTrue(PhotoLoader.isSupportedCandidate(url))

        let loaded = try PhotoLoader.load(url: url, lensCorrection: false)
        XCTAssertEqual(loaded.image.extent.width, 1, accuracy: 0.01)
        XCTAssertEqual(loaded.image.extent.height, 1, accuracy: 0.01)

        let context = CIContext(options: [.cacheIntermediates: false])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(loaded.image, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        XCTAssertGreaterThanOrEqual(pixel[0], 250, "fixture must stay a white pixel: \(pixel)")
        XCTAssertGreaterThanOrEqual(pixel[1], 250, "fixture must stay a white pixel: \(pixel)")
        XCTAssertGreaterThanOrEqual(pixel[2], 250, "fixture must stay a white pixel: \(pixel)")

        let thumbnail = try PhotoLoader.thumbnail(url: url, maxDimension: 8)
        XCTAssertEqual(thumbnail.width, 1)
        XCTAssertEqual(thumbnail.height, 1)
        let scanned = try PhotoLoader.scan(folder: temp, recursive: false)
        XCTAssertEqual(scanned.map { $0.url.lastPathComponent }, ["fixture.webp"])
    }

    // macOS 13 ImageIO can decode AVIF but cannot encode it, so this test covers
    // the two verifiable halves: extension recognition + the explicit failure
    // path for an undecodable payload. A successful AVIF decode is NOT covered
    // here and is reported as unverified rather than faked.
    func testAVIFExtensionIsRecognizedAndUndecodablePayloadFailsExplicitly() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let corrupt = temp.appendingPathComponent("corrupt.avif")
        try Data("not an avif payload".utf8).write(to: corrupt)
        XCTAssertTrue(PhotoLoader.isSupportedCandidate(corrupt),
                      "AVIF must be recognized as a candidate extension")

        XCTAssertThrowsError(try PhotoLoader.load(url: corrupt, lensCorrection: false)) { error in
            guard let atelierError = error as? AtelierError,
                  case .imageRead(let message) = atelierError else {
                XCTFail("Expected an explicit imageRead error for corrupt AVIF, got: \(error)")
                return
            }
            XCTAssertTrue(message.contains("corrupt.avif"), message)
            XCTAssertTrue(message.contains("无法解析") || message.contains("无法解码"), message)
        }

        let scanned = try PhotoLoader.scan(folder: temp, recursive: false)
        XCTAssertEqual(scanned.map { $0.url.lastPathComponent }, ["corrupt.avif"])
    }

    // Multi-image containers must keep being rejected: a still-photo pipeline
    // cannot silently pick frame 0. Multi-page TIFF is generated by ImageIO; the
    // animated PNG fixture is a checked-in 2-frame APNG because ImageIO cannot
    // write APNG (it silently writes a single-frame PNG instead).
    func testMultiPageTIFFAndAnimatedPNGAreStillRejected() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let tiff = temp.appendingPathComponent("two-pages.tiff")
        try TestFiles.writeMultiPageTIFF(to: tiff, frameCount: 2)
        let tiffSource = try XCTUnwrap(CGImageSourceCreateWithURL(tiff as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(tiffSource), 2, "fixture must really contain two pages")
        XCTAssertThrowsError(try PhotoLoader.load(url: tiff, lensCorrection: false)) { error in
            guard let atelierError = error as? AtelierError,
                  case .imageRead(let message) = atelierError else {
                XCTFail("Expected explicit imageRead for multi-page TIFF, got: \(error)")
                return
            }
            XCTAssertTrue(message.contains("只处理单页静态照片"), message)
        }

        let apng = temp.appendingPathComponent("animated.png")
        try XCTUnwrap(Data(base64Encoded: TestFiles.animatedPNGBase64)).write(to: apng)
        let apngSource = try XCTUnwrap(CGImageSourceCreateWithURL(apng as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(apngSource), 2, "fixture must really be a 2-frame APNG")
        XCTAssertThrowsError(try PhotoLoader.load(url: apng, lensCorrection: false)) { error in
            guard let atelierError = error as? AtelierError,
                  case .imageRead(let message) = atelierError else {
                XCTFail("Expected explicit imageRead for animated PNG, got: \(error)")
                return
            }
            XCTAssertTrue(message.contains("只处理单页静态照片"), message)
        }
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
            throw AtelierError.imageWrite("测试图片写入失败（\(type.identifier)）")
        }
    }

    /// 1x1 white WebP (44 bytes). ImageIO decodes WebP on macOS 13 but cannot
    /// encode it, so decoding is covered by this embedded fixture.
    static let webP1x1Base64 = "UklGRiQAAABXRUJQVlA4IBgAAAAwAQCdASoBAAEAAwA0JaQAA3AA/vuUAAA="

    /// Two-frame animated PNG (1x1 frames). ImageIO cannot write APNG through
    /// CGImageDestination, so these verified PNG chunks are embedded verbatim.
    static let animatedPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAABAAAAAQAAAAAAAAAAAAEACgAAWn8w0AAAAA1JREFUCB1j+K/G8B8ABXICJUhdPgIAAAAaZmNUTAAAAAEAAAABAAAAAQAAAAAAAAAAAAEACgAAwQzaBAAAABFmZEFUAAAAAggdY/ivxvAfAAVyAiVbUZB7AAAAAElFTkSuQmCC"

    static func writeMultiPageTIFF(to url: URL, frameCount: Int) throws {
        guard frameCount >= 2 else {
            throw AtelierError.imageWrite("多页 TIFF 夹具至少需要 2 页")
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, frameCount, nil
        ) else {
            throw AtelierError.imageWrite("测试多页 TIFF 目标创建失败")
        }
        for index in 0..<frameCount {
            guard let image = solidImage(width: 4 + index, height: 4 + index) else {
                throw AtelierError.imageWrite("测试多页 TIFF 栅格化失败")
            }
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw AtelierError.imageWrite("测试多页 TIFF 写入失败")
        }
    }

    static func solidImage(width: Int, height: Int) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        bitmap.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return bitmap.makeImage()
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

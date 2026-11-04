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

    func testExportResizeLongEdgeAndPercentProduceExpectedPixels() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let image = CIImage(cgImage: try XCTUnwrap(TestFiles.solidImage(width: 1000, height: 800)))
        let context = PhotoEngine().context

        var settings = ExportSettings()
        settings.format = .png
        settings.resize = ExportResizeSettings(mode: .longEdge, longEdge: 500)
        let longEdgeURL = temp.appendingPathComponent("long-edge.png")
        try PhotoExporter.write(image: image, to: longEdgeURL, settings: settings,
                                sourceProperties: [:], context: context)
        let longEdgeSize = try TestFiles.imagePixelSize(longEdgeURL)
        XCTAssertEqual(longEdgeSize.width, 500)
        XCTAssertEqual(longEdgeSize.height, 400)

        settings.resize = ExportResizeSettings(mode: .percent, percent: 25)
        let percentURL = temp.appendingPathComponent("percent.png")
        try PhotoExporter.write(image: image, to: percentURL, settings: settings,
                                sourceProperties: [:], context: context)
        let percentSize = try TestFiles.imagePixelSize(percentURL)
        XCTAssertEqual(percentSize.width, 250)
        XCTAssertEqual(percentSize.height, 200)

        // Non-integer scales still produce an exact integer target size (no
        // ceil drift from the integral bounds used during encoding).
        settings.resize = ExportResizeSettings(mode: .longEdge, longEdge: 333)
        let oddURL = temp.appendingPathComponent("odd.png")
        try PhotoExporter.write(image: image, to: oddURL, settings: settings,
                                sourceProperties: [:], context: context)
        let oddSize = try TestFiles.imagePixelSize(oddURL)
        XCTAssertEqual(oddSize.width, 333)
        XCTAssertEqual(oddSize.height, 266)

        // Full-size export stays the default for recipes that never opt in.
        var plain = ExportSettings()
        plain.format = .png
        let plainURL = temp.appendingPathComponent("plain.png")
        try PhotoExporter.write(image: image, to: plainURL, settings: plain,
                                sourceProperties: [:], context: context)
        let plainSize = try TestFiles.imagePixelSize(plainURL)
        XCTAssertEqual(plainSize.width, 1000)
        XCTAssertEqual(plainSize.height, 800)
    }

    func testInvalidExportResizeIsRejectedBeforeWriting() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let image = CIImage(cgImage: try XCTUnwrap(TestFiles.solidImage(width: 16, height: 12)))
        let context = PhotoEngine().context
        var settings = ExportSettings()
        settings.format = .png
        settings.resize = ExportResizeSettings(mode: .longEdge, longEdge: 8)
        let url = temp.appendingPathComponent("invalid.png")
        XCTAssertThrowsError(try PhotoExporter.write(image: image, to: url, settings: settings,
                                                     sourceProperties: [:], context: context))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        settings.resize = ExportResizeSettings(mode: .percent, percent: 0)
        XCTAssertThrowsError(try PhotoExporter.write(image: image, to: url, settings: settings,
                                                     sourceProperties: [:], context: context))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testHeicExportWritesReadableFile() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let image = CIImage(cgImage: try XCTUnwrap(TestFiles.solidImage(width: 64, height: 48)))
        var settings = ExportSettings()
        settings.format = .heic
        settings.jpegQuality = 0.9
        let url = temp.appendingPathComponent("export.heic")
        try PhotoExporter.write(image: image, to: url, settings: settings,
                                sourceProperties: [:], context: PhotoEngine().context)
        let bytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(bytes, 0)
        let pixels = try TestFiles.imagePixelSize(url)
        XCTAssertEqual(pixels.width, 64)
        XCTAssertEqual(pixels.height, 48)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return XCTFail("HEIC 导出无法被 ImageIO 打开")
        }
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let loaded = try PhotoLoader.load(url: url, lensCorrection: false)
        XCTAssertEqual(Int(loaded.image.extent.width.rounded()), 64)
        XCTAssertEqual(Int(loaded.image.extent.height.rounded()), 48)
    }

    func testExportSettingsCodableBackwardCompatibility() throws {
        // Recipes written before v10 have neither resize nor fileNameTemplate.
        let legacyJSON = """
        {"format":"jpeg","colorSpace":"sRGB","jpegQuality":0.94,"recursive":false,
         "suffix":"_graded","stripMetadata":true}
        """
        let legacy = try JSONDecoder().decode(ExportSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.resize)
        XCTAssertNil(legacy.fileNameTemplate)

        var extended = legacy
        extended.format = .heic
        extended.resize = ExportResizeSettings(mode: .longEdge, longEdge: 2048)
        extended.fileNameTemplate = "{name}{suffix}-{index}"
        let decoded = try JSONDecoder().decode(ExportSettings.self,
                                              from: JSONEncoder().encode(extended))
        XCTAssertEqual(decoded, extended)
        XCTAssertEqual(decoded.resize?.longEdge, 2048)
        XCTAssertEqual(decoded.fileNameTemplate, "{name}{suffix}-{index}")
    }

    func testRecipeVersion10GateForExportExtensions() throws {
        func recipe(_ configure: (inout ExportSettings) -> Void) -> Recipe {
            var value = Recipe()
            value.version = 9
            configure(&value.export)
            return value
        }
        let resize = recipe { $0.resize = ExportResizeSettings(mode: .longEdge, longEdge: 2048) }
        XCTAssertThrowsError(try resize.validateVersion()) { error in
            XCTAssertTrue(error.localizedDescription.contains("版本 10"), error.localizedDescription)
        }
        let heic = recipe { $0.format = .heic }
        XCTAssertThrowsError(try heic.validateVersion())
        let template = recipe { $0.fileNameTemplate = "{name}{suffix}" }
        XCTAssertThrowsError(try template.validateVersion())

        var upgraded = resize
        upgraded.version = 10
        XCTAssertNoThrow(try upgraded.validateVersion())
        // Neutral extension fields stay v9-compatible: old pixels and paths unchanged.
        XCTAssertNoThrow(try Recipe().validateVersion())
        var legacyRecipe = Recipe()
        legacyRecipe.version = 9
        legacyRecipe.export.resize = ExportResizeSettings(mode: .none)
        XCTAssertNoThrow(try legacyRecipe.validateVersion())
        // The app saves through the same predicate, so an export extension can
        // never be persisted as a v9 recipe that its own loader rejects.
        XCTAssertFalse(legacyRecipe.export.requiresVersion10Recipe)
        var extendedExport = legacyRecipe.export
        extendedExport.format = .heic
        XCTAssertTrue(extendedExport.requiresVersion10Recipe)
        extendedExport.format = .jpeg
        extendedExport.resize = ExportResizeSettings(mode: .percent, percent: 50)
        XCTAssertTrue(extendedExport.requiresVersion10Recipe)
        extendedExport.resize = nil
        extendedExport.fileNameTemplate = "{name}{suffix}"
        XCTAssertTrue(extendedExport.requiresVersion10Recipe)
    }

    func testResizedExportKeepsEdgePixelsAndAlpha() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let image = CIImage(cgImage: try XCTUnwrap(TestFiles.solidImage(width: 96, height: 64)))
        let context = PhotoEngine().context

        // PNG/TIFF path (RGBA16): every edge pixel must keep full alpha and the
        // same colour as the interior. Without clampedToExtent the Lanczos filter
        // darkens the outer ring and drops its alpha.
        var png = ExportSettings()
        png.format = .png
        png.resize = ExportResizeSettings(mode: .longEdge, longEdge: 48)
        let pngURL = temp.appendingPathComponent("edge.png")
        try PhotoExporter.write(image: image, to: pngURL, settings: png,
                                sourceProperties: [:], context: context)
        let pngPixels = try TestFiles.rgba8Pixels(pngURL)
        XCTAssertEqual(pngPixels.width, 48)
        XCTAssertEqual(pngPixels.height, 32)
        let pngCenter = pngPixels.pixel(x: 24, y: 16)
        for (x, y) in [(0, 0), (47, 0), (0, 31), (47, 31), (0, 16), (47, 16), (24, 0), (24, 31)] {
            let edge = pngPixels.pixel(x: x, y: y)
            XCTAssertEqual(Int(edge.alpha), 255, "PNG alpha at \(x),\(y) was \(edge.alpha)")
            XCTAssertLessThanOrEqual(abs(Int(edge.red) - Int(pngCenter.red)), 2,
                                     "PNG edge (\(x),\(y)) red \(edge.red) vs centre \(pngCenter.red)")
        }

        // JPEG path (opaque white composite): a clamped uniform image must stay
        // uniform after lossy encoding, not brighten along the outer ring.
        var jpeg = ExportSettings()
        jpeg.format = .jpeg
        jpeg.jpegQuality = 0.95
        jpeg.resize = ExportResizeSettings(mode: .percent, percent: 50)
        let jpegURL = temp.appendingPathComponent("edge.jpg")
        try PhotoExporter.write(image: image, to: jpegURL, settings: jpeg,
                                sourceProperties: [:], context: context)
        let jpegPixels = try TestFiles.rgba8Pixels(jpegURL)
        XCTAssertEqual(jpegPixels.width, 48)
        XCTAssertEqual(jpegPixels.height, 32)
        let jpegCenter = jpegPixels.pixel(x: 24, y: 16)
        for (x, y) in [(0, 0), (47, 0), (0, 31), (47, 31)] {
            let edge = jpegPixels.pixel(x: x, y: y)
            XCTAssertLessThanOrEqual(abs(Int(edge.red) - Int(jpegCenter.red)), 6,
                                     "JPEG edge (\(x),\(y)) red \(edge.red) vs centre \(jpegCenter.red)")
        }
    }

    // MARK: - P1-7 watermark export integration

    func testExporterAppliesWatermarkAfterResizeWithPositionAndOpacity() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let context = PhotoEngine().context
        let image = CIImage(cgImage: try XCTUnwrap(TestFiles.solidImage(width: 200, height: 150)))

        var plain = ExportSettings()
        plain.format = .png
        plain.resize = ExportResizeSettings(mode: .longEdge, longEdge: 100)
        let plainURL = temp.appendingPathComponent("plain.png")
        try PhotoExporter.write(image: image, to: plainURL, settings: plain,
                                sourceProperties: [:], context: context)
        let plainPixels = try TestFiles.rgba8Pixels(plainURL)
        XCTAssertEqual(plainPixels.width, 100, "水印必须在 resize 之后叠加，导出尺寸按 resize 结果")
        XCTAssertEqual(plainPixels.height, 75)
        let reference = plainPixels.pixel(x: 10, y: 10)
        XCTAssertEqual(reference.alpha, 255)
        var plainIsUniform = true
        for y in 0..<plainPixels.height {
            for x in 0..<plainPixels.width {
                let pixel = plainPixels.pixel(x: x, y: y)
                if pixel.red != reference.red || pixel.green != reference.green
                    || pixel.blue != reference.blue || pixel.alpha != 255 {
                    plainIsUniform = false
                }
            }
        }
        XCTAssertTrue(plainIsUniform, "无水印导出应保持均匀面")
        XCTAssertEqual(try TestFiles.rgba8Pixels(plainURL).data, plainPixels.data,
                       "旧导出路径（无 watermark）应逐像素稳定")

        func writeWatermark(opacity: Double, name: String) throws -> URL {
            var settings = plain
            settings.watermark = WatermarkSettings(text: "WM", anchor: .bottomRight,
                                                   opacity: opacity, scale: 4, color: .white)
            let url = temp.appendingPathComponent(name)
            try PhotoExporter.write(image: image, to: url, settings: settings,
                                    sourceProperties: [:], context: context)
            return url
        }

        let fullPixels = try TestFiles.rgba8Pixels(try writeWatermark(opacity: 1, name: "full.png"))
        XCTAssertEqual(fullPixels.width, 100)
        XCTAssertEqual(fullPixels.height, 75)
        let fullBright = try XCTUnwrap(brightRegion(fullPixels, threshold: 220),
                                       "白色水印必须被渲染到导出文件")
        XCTAssertGreaterThan(fullBright.count, 20)
        XCTAssertGreaterThan(fullBright.minX, 45, "水印应位于画布右侧")
        XCTAssertGreaterThan(fullBright.minY, 30, "水印应位于画布下侧")
        XCTAssertLessThanOrEqual(fullBright.maxX, 99)
        XCTAssertLessThanOrEqual(fullBright.maxY, 74)
        let fullPeak = try XCTUnwrap(peakLuminance(fullPixels))
        XCTAssertGreaterThanOrEqual(fullPeak, 240, "不透明白色水印峰值应接近白")

        let halfPixels = try TestFiles.rgba8Pixels(try writeWatermark(opacity: 0.5, name: "half.png"))
        let halfPeak = try XCTUnwrap(peakLuminance(halfPixels))
        XCTAssertTrue((160...235).contains(halfPeak),
                      "50% 透明水印应落在半透明混合区间，实际峰值 \(halfPeak)")

        // Neutral opacity is the documented no-op: pixel-identical to the legacy path.
        let neutralPixels = try TestFiles.rgba8Pixels(try writeWatermark(opacity: 0, name: "neutral.png"))
        XCTAssertEqual(neutralPixels.data, plainPixels.data, "透明度 0 的水印必须逐像素等于旧导出路径")
    }

    func testExporterMissingWatermarkImageFailsExplicitlyWithoutOutput() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let image = CIImage(cgImage: try XCTUnwrap(TestFiles.solidImage(width: 40, height: 30)))
        var settings = ExportSettings()
        settings.format = .png
        settings.watermark = WatermarkSettings(kind: .image,
                                               imagePath: temp.appendingPathComponent("missing.png").path,
                                               opacity: 1)
        let url = temp.appendingPathComponent("out.png")
        XCTAssertThrowsError(try PhotoExporter.write(image: image, to: url, settings: settings,
                                                     sourceProperties: [:],
                                                     context: PhotoEngine().context)) { error in
            guard let atelierError = error as? AtelierError,
                  case .imageRead = atelierError else {
                XCTFail("缺失水印图片应报 imageRead，实际：\(error)")
                return
            }
            XCTAssertTrue(error.localizedDescription.contains("水印图片"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "水印图片缺失时不得留下半成品输出")
    }

    private func brightRegion(_ pixels: TestFiles.RGBA8Pixels, threshold: Int)
        -> (count: Int, minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        var count = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let pixel = pixels.pixel(x: x, y: y)
                let luminance = (Int(pixel.red) + Int(pixel.green) + Int(pixel.blue)) / 3
                guard luminance >= threshold else { continue }
                count += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return count == 0 ? nil : (count, minX, maxX, minY, maxY)
    }

    private func peakLuminance(_ pixels: TestFiles.RGBA8Pixels) -> Int? {
        var peak = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let pixel = pixels.pixel(x: x, y: y)
                peak = max(peak, (Int(pixel.red) + Int(pixel.green) + Int(pixel.blue)) / 3)
            }
        }
        return peak
    }

    // MARK: - P1-C C6 preview cancellation / analysis sampling

    func testPreviewRequestGateOnlyAdmitsNewestGeneration() {
        var gate = PreviewRequestGate()
        let first = gate.begin()
        XCTAssertTrue(gate.admits(first))
        let second = gate.begin()
        XCTAssertFalse(gate.admits(first), "a slow stale preview must not publish results")
        XCTAssertTrue(gate.admits(second))
        gate.invalidate()
        XCTAssertFalse(gate.admits(second))
        XCTAssertEqual(gate.currentGeneration, gate.currentGeneration)
    }

    func testEngineProcessHonoursCancellationToken() throws {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let image = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        let cancelled = CancellationToken()
        cancelled.cancel()
        XCTAssertThrowsError(try PhotoEngine().process(image, settings: AdjustmentSettings(),
                                                       lut: nil, cancellation: cancelled)) { error in
            guard case AtelierError.cancelled = error else {
                return XCTFail("expected AtelierError.cancelled, got \(error)")
            }
        }
    }

    func testAnalysisDownsamplingKeepsSceneAndProposalSemantics() throws {
        let full = try makeHorizontalGradientImage(width: 1200, height: 800)
        let sampled = PhotoEngine().analysisSample(full, maxDimension: 1200)
        XCTAssertEqual(sampled.extent.width, 1200, accuracy: 2,
                       "small images must not be upscaled or altered")
        let downsampled = PhotoEngine().analysisSample(full, maxDimension: 384)
        XCTAssertLessThanOrEqual(max(downsampled.extent.width, downsampled.extent.height), 384.5)

        let analyzer = PhotoAnalyzer()
        let fullAnalysis = try analyzer.analyze(image: full, properties: [:])
        let sampledAnalysis = try analyzer.analyze(image: downsampled, properties: [:])
        XCTAssertEqual(fullAnalysis.proposals.map(\.id), sampledAnalysis.proposals.map(\.id),
                       "analysis proposals must keep the same semantic styles")
        XCTAssertEqual(fullAnalysis.sceneAssessment?.category, sampledAnalysis.sceneAssessment?.category)
        XCTAssertEqual(fullAnalysis.metrics.medianLuminance,
                       sampledAnalysis.metrics.medianLuminance, accuracy: 0.02)
        XCTAssertEqual(fullAnalysis.metrics.sampleWidth, sampledAnalysis.metrics.sampleWidth)
    }

    private func makeHorizontalGradientImage(width: Int, height: Int) throws -> CIImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AtelierError.imageRead("无法创建测试位图上下文")
        }
        context.interpolationQuality = .none
        for x in 0..<width {
            let value = CGFloat(x) / CGFloat(max(1, width - 1))
            let color = CGColor(colorSpace: colorSpace,
                                components: [value, min(1, 0.15 + value * 0.8), 1 - value, 1])!
            context.setFillColor(color)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        guard let cgImage = context.makeImage() else {
            throw AtelierError.imageRead("无法生成测试渐变图")
        }
        return CIImage(cgImage: cgImage)
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

    struct RGBA8Pixels {
        let width: Int
        let height: Int
        let data: [UInt8]
        func pixel(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
            let offset = (y * width + x) * 4
            return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
        }
    }

    /// Decodes an exported file into 8-bit RGBA for pixel-content assertions.
    static func rgba8Pixels(_ url: URL) throws -> RGBA8Pixels {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AtelierError.imageRead("测试无法解码导出文件：\(url.lastPathComponent)")
        }
        let width = cgImage.width, height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &data, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AtelierError.imageRead("测试无法创建像素缓冲")
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RGBA8Pixels(width: width, height: height, data: data)
    }

    static func imagePixelSize(_ url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            throw AtelierError.imageRead("测试无法读取导出像素尺寸：\(url.lastPathComponent)")
        }
        return (width, height)
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

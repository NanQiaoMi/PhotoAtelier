import XCTest
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCore

/// Contract tests for the local customer delivery page: static offline HTML,
/// contact-sheet PDF, privacy stripping and determinism.
///
/// Every fixture is a synthetic Core Image graph or a generated JPEG; no user
/// photos are read. The tests assert structure, file counts, dimensions, page
/// geometry, privacy markers and byte determinism — not aesthetic quality.
final class DeliveryGalleryTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    // MARK: - HTML gallery

    func testWritesOfflineHTMLGalleryWithRelativeThumbnailsAndPreviews() throws {
        let root = try makeTemporaryDirectory()
        let output = root.appendingPathComponent("delivery", isDirectory: true)
        var settings = DeliverySettings()
        settings.title = "旅行交付 <精选>"
        settings.columnCount = 3
        settings.thumbnailMaxDimension = 320
        settings.previewMaxDimension = 960
        settings.includeContactSheet = true

        let images = [
            makeImage(width: 1_600, height: 1_200, color: (0.80, 0.30, 0.20)),
            makeImage(width: 1_200, height: 1_600, color: (0.20, 0.50, 0.80)),
            makeImage(width: 800, height: 800, color: (0.30, 0.70, 0.35))
        ]
        let result = try DeliveryGalleryWriter.write(images: images, settings: settings,
                                                     outputDirectory: output)
        XCTAssertEqual(result.photoCount, 3)

        let htmlURL = output.appendingPathComponent(DeliveryGalleryWriter.indexFileName)
        XCTAssertEqual(result.indexHTMLURL, htmlURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: htmlURL.path))
        XCTAssertNotNil(result.contactSheetURL)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.appendingPathComponent(DeliveryGalleryWriter.contactSheetFileName).path))

        // Generated thumbnails / previews exist with the expected fitted sizes.
        let expectedThumbnails = [(320, 240), (240, 320), (320, 320)]
        let expectedPreviews = [(960, 720), (720, 960), (800, 800)]
        for index in 0..<3 {
            let name = String(format: "%02d", index + 1)
            let thumbnailURL = output.appendingPathComponent("thumbs/\(name).jpg")
            let previewURL = output.appendingPathComponent("previews/\(name).jpg")
            XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path))
            XCTAssertEqual(try imageSize(thumbnailURL).width, expectedThumbnails[index].0)
            XCTAssertEqual(try imageSize(thumbnailURL).height, expectedThumbnails[index].1)
            XCTAssertEqual(try imageSize(previewURL).width, expectedPreviews[index].0)
            XCTAssertEqual(try imageSize(previewURL).height, expectedPreviews[index].1)
        }

        let html = try readText(htmlURL)
        XCTAssertTrue(html.contains("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("<style>"), "CSS 必须内嵌")
        XCTAssertTrue(html.contains("name=\"viewport\""))
        XCTAssertTrue(html.contains("旅行交付 &lt;精选&gt;"), "标题必须被 HTML 转义")
        XCTAssertTrue(html.contains("src=\"thumbs/01.jpg\""))
        XCTAssertTrue(html.contains("href=\"previews/01.jpg\""))
        XCTAssertTrue(html.contains("loading=\"lazy\""))
        XCTAssertEqual(occurrences(of: "<img ", in: html), 3, "HTML 图片数量必须等于照片数")
        XCTAssertEqual(occurrences(of: "<figure>", in: html), 3)
        XCTAssertFalse(html.lowercased().contains("http"), "交付页不得包含 http(s) 外链")
        XCTAssertFalse(html.contains("://"), "交付页不得使用任何外部 URL scheme")
        XCTAssertFalse(html.contains("<script"), "交付页不引入脚本")
        XCTAssertFalse(html.contains("@import"), "交付页不引入外部样式")
        XCTAssertFalse(html.contains(output.path), "交付页不得泄漏本地绝对路径")
        XCTAssertFalse(html.contains(root.path), "交付页不得泄漏临时目录路径")
    }

    func testHTMLAndGeneratedImagesAreByteDeterministic() throws {
        let root = try makeTemporaryDirectory()
        let settings = standardSettings(columns: 2, thumbnail: 320, preview: 640)
        let images = [
            makeImage(width: 900, height: 600, color: (0.7, 0.2, 0.3)),
            makeImage(width: 600, height: 900, color: (0.2, 0.6, 0.7))
        ]
        let first = try DeliveryGalleryWriter.write(images: images, settings: settings,
                                                    outputDirectory: root.appendingPathComponent("a"))
        let second = try DeliveryGalleryWriter.write(images: images, settings: settings,
                                                     outputDirectory: root.appendingPathComponent("b"))

        let firstHTML = try Data(contentsOf: first.indexHTMLURL)
        let secondHTML = try Data(contentsOf: second.indexHTMLURL)
        XCTAssertEqual(firstHTML, secondHTML, "相同输入必须生成逐字节相同的 HTML")

        for relative in ["thumbs/01.jpg", "thumbs/02.jpg", "previews/01.jpg", "previews/02.jpg"] {
            let firstData = try Data(contentsOf: first.thumbnailDirectoryURL
                .deletingLastPathComponent().appendingPathComponent(relative))
            let secondData = try Data(contentsOf: second.thumbnailDirectoryURL
                .deletingLastPathComponent().appendingPathComponent(relative))
            XCTAssertEqual(firstData, secondData, "\(relative) 必须逐字节确定")
        }

        // PDF bytes include Core Graphics' automatic creation date; the guarantee
        // is structural (page count + paper size + layout), not byte identity.
        let firstPDF = try XCTUnwrap(first.contactSheetURL)
        let secondPDF = try XCTUnwrap(second.contactSheetURL)
        let firstDocument = try XCTUnwrap(CGPDFDocument(firstPDF as CFURL))
        let secondDocument = try XCTUnwrap(CGPDFDocument(secondPDF as CFURL))
        XCTAssertEqual(firstDocument.numberOfPages, secondDocument.numberOfPages)
        for pageNumber in 1...max(1, firstDocument.numberOfPages) {
            let firstPage = try XCTUnwrap(firstDocument.page(at: pageNumber))
            let secondPage = try XCTUnwrap(secondDocument.page(at: pageNumber))
            XCTAssertEqual(firstPage.getBoxRect(.mediaBox), secondPage.getBoxRect(.mediaBox))
        }
    }

    // MARK: - Contact sheet PDF

    func testContactSheetPDFPageCountAndPaperSize() throws {
        let root = try makeTemporaryDirectory()
        let output = root.appendingPathComponent("delivery", isDirectory: true)
        var settings = standardSettings(columns: 4, thumbnail: 240, preview: 480)
        settings.includeContactSheet = true
        settings.contactSheetColumns = 4
        settings.paper = .a4
        settings.pageMarginFraction = 0.06

        let photoCount = 30
        let images = (0..<photoCount).map { index in
            makeImage(width: 200, height: 150,
                      color: (Double(index % 8) / 8, Double(index % 5) / 5, 0.4))
        }
        let layout = try DeliveryGalleryWriter.contactSheetLayout(photoCount: photoCount,
                                                                  settings: settings)
        XCTAssertGreaterThan(layout.capacityPerPage, 0)
        XCTAssertEqual(layout.capacityPerPage, layout.columns * layout.rowsPerPage)
        XCTAssertGreaterThan(layout.pageCount, 1, "30 张照片在 A4 4 列网格下应跨页")

        let result = try DeliveryGalleryWriter.write(images: images, settings: settings,
                                                     outputDirectory: output)
        let pdfURL = try XCTUnwrap(result.contactSheetURL)
        let document = try XCTUnwrap(CGPDFDocument(pdfURL as CFURL))
        XCTAssertEqual(document.numberOfPages, layout.pageCount, "PDF 页数必须与版面计算一致")
        let a4 = DeliveryPaperSize.a4.points
        for pageNumber in 1...document.numberOfPages {
            let page = try XCTUnwrap(document.page(at: pageNumber))
            let box = page.getBoxRect(.mediaBox)
            XCTAssertEqual(Double(box.width), Double(a4.width), accuracy: 0.5)
            XCTAssertEqual(Double(box.height), Double(a4.height), accuracy: 0.5)
        }
    }

    func testContactSheetPDFActuallyRendersTitleAndGridCells() throws {
        let root = try makeTemporaryDirectory()
        let output = root.appendingPathComponent("delivery", isDirectory: true)
        var settings = standardSettings(columns: 2, thumbnail: 240, preview: 480)
        settings.includeContactSheet = true
        settings.contactSheetColumns = 2
        settings.title = "PDF 内容验证"
        let images = [
            makeImage(width: 240, height: 180, color: (0.85, 0.25, 0.20)),
            makeImage(width: 180, height: 240, color: (0.20, 0.55, 0.85))
        ]
        let result = try DeliveryGalleryWriter.write(images: images, settings: settings,
                                                     outputDirectory: output)
        let pdfURL = try XCTUnwrap(result.contactSheetURL)
        let document = try XCTUnwrap(CGPDFDocument(pdfURL as CFURL))
        XCTAssertGreaterThanOrEqual(document.numberOfPages, 1)
        let a4 = DeliveryPaperSize.a4.points
        let width = Int(a4.width.rounded())
        let height = Int(a4.height.rounded())
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let rendered: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let page = document.page(at: 1) else { return false }
            context.drawPDFPage(page)
            return true
        }
        XCTAssertTrue(rendered, "无法把接触表 PDF 渲染成位图")
        var coloredPixels = 0
        var darkPixels = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
            if max(r, max(g, b)) - min(r, min(g, b)) > 24 { coloredPixels += 1 }
            if r < 90 && g < 90 && b < 90 { darkPixels += 1 }
        }
        XCTAssertGreaterThan(coloredPixels, 2_000, "PDF 必须真的画出缩略图网格，而不是空白页")
        XCTAssertGreaterThan(darkPixels, 20, "PDF 标题/编号文字必须被绘制")
    }

    func testContactSheetLetterPaperAndSinglePhoto() throws {
        let root = try makeTemporaryDirectory()
        let output = root.appendingPathComponent("delivery", isDirectory: true)
        var settings = standardSettings(columns: 1, thumbnail: 320, preview: 640)
        settings.includeContactSheet = true
        settings.paper = .letter
        settings.contactSheetColumns = 2
        let image = makeImage(width: 640, height: 480, color: (0.4, 0.4, 0.4))
        let result = try DeliveryGalleryWriter.write(images: [image], settings: settings,
                                                     outputDirectory: output)
        let pdfURL = try XCTUnwrap(result.contactSheetURL)
        let document = try XCTUnwrap(CGPDFDocument(pdfURL as CFURL))
        XCTAssertEqual(document.numberOfPages, 1)
        let letter = DeliveryPaperSize.letter.points
        let box = try XCTUnwrap(document.page(at: 1)).getBoxRect(.mediaBox)
        XCTAssertEqual(Double(box.width), Double(letter.width), accuracy: 0.5)
        XCTAssertEqual(Double(box.height), Double(letter.height), accuracy: 0.5)
    }

    func testLayoutPredictionMatchesPaginationBoundaries() throws {
        let settings = standardSettings(columns: 3, thumbnail: 320, preview: 640)
        let layout = try DeliveryGalleryWriter.contactSheetLayout(photoCount: 1, settings: settings)
        XCTAssertEqual(layout.pageCount, 1)
        let capacity = layout.capacityPerPage
        XCTAssertGreaterThan(capacity, 1)
        let fullPage = try DeliveryGalleryWriter.contactSheetLayout(photoCount: capacity,
                                                                    settings: settings)
        XCTAssertEqual(fullPage.pageCount, 1)
        let overflow = try DeliveryGalleryWriter.contactSheetLayout(photoCount: capacity + 1,
                                                                    settings: settings)
        XCTAssertEqual(overflow.pageCount, 2)
    }

    // MARK: - Empty album / validation

    func testEmptyAlbumThrowsExplicitlyWithoutCreatingOutput() throws {
        let root = try makeTemporaryDirectory()
        let output = root.appendingPathComponent("not-created", isDirectory: true)
        let settings = standardSettings(columns: 3, thumbnail: 320, preview: 640)
        XCTAssertThrowsError(try DeliveryGalleryWriter.write(images: [], settings: settings,
                                                             outputDirectory: output)) { error in
            guard let atelierError = error as? AtelierError,
                  case .invalidConfiguration(let message) = atelierError else {
                return XCTFail("空相册应报 invalidConfiguration，实际：\(error)")
            }
            XCTAssertTrue(message.contains("空相册") || message.contains("至少需要一张"),
                          message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "空相册失败时不得创建输出目录")
    }

    func testInvalidDeliverySettingsAreRejected() throws {
        func invalid(_ label: String, _ mutate: (inout DeliverySettings) -> Void) {
            var settings = DeliverySettings()
            mutate(&settings)
            XCTAssertThrowsError(try settings.validate(), label) { error in
                guard let atelierError = error as? AtelierError,
                      case .invalidConfiguration = atelierError else {
                    return XCTFail("\(label)：应报 invalidConfiguration，实际：\(error)")
                }
            }
        }
        invalid("空标题") { $0.title = "   " }
        invalid("标题过长") { $0.title = String(repeating: "长", count: 130) }
        invalid("列数 0") { $0.columnCount = 0 }
        invalid("列数 9") { $0.columnCount = 9 }
        invalid("缩略图过小") { $0.thumbnailMaxDimension = 32 }
        invalid("缩略图过大") { $0.thumbnailMaxDimension = 8_192 }
        invalid("预览过小") { $0.previewMaxDimension = 128 }
        invalid("预览小于缩略图") { $0.thumbnailMaxDimension = 800; $0.previewMaxDimension = 400 }
        invalid("接触表列数 0") { $0.contactSheetColumns = 0 }
        invalid("边距过大") { $0.pageMarginFraction = 0.5 }
        invalid("边距 NaN") { $0.pageMarginFraction = .nan }

        var valid = DeliverySettings()
        valid.title = "OK"
        XCTAssertNoThrow(try valid.validate())
    }

    // MARK: - Privacy

    func testPrivacyMetadataAndExternalLinksAreStripped() throws {
        let root = try makeTemporaryDirectory()
        let sourceURL = try makeMetadataHeavyJPEG(in: root)
        let sourceBytes = try readLatin1(sourceURL)
        XCTAssertTrue(sourceBytes.lowercased().contains("secretcam"),
                      "测试夹具必须先包含相机元数据，否则隐私断言没有意义")
        XCTAssertTrue(sourceBytes.lowercased().contains("serial12345"))

        let output = root.appendingPathComponent("delivery", isDirectory: true)
        var settings = standardSettings(columns: 2, thumbnail: 320, preview: 640)
        settings.includeContactSheet = true
        _ = try DeliveryGalleryWriter.write(fileURLs: [sourceURL], settings: settings,
                                            outputDirectory: output)

        let files = try generatedFileURLs(in: output)
        XCTAssertFalse(files.isEmpty)
        for url in files {
            let text = try readLatin1(url).lowercased()
            for marker in ["secretcam", "secretartist", "serial12345",
                           "gpslatitude", "gpslongitude", "http://", "https://"] {
                XCTAssertFalse(text.contains(marker),
                               "\(url.lastPathComponent) 泄漏隐私/外链标记：\(marker)")
            }
            XCTAssertFalse(text.contains(root.path.lowercased()),
                           "\(url.lastPathComponent) 泄漏本地绝对路径")
        }
    }

    func testSourceFileMetadataIsNotCopiedToThumbnails() throws {
        let root = try makeTemporaryDirectory()
        let sourceURL = try makeMetadataHeavyJPEG(in: root)
        let output = root.appendingPathComponent("delivery", isDirectory: true)
        var settings = standardSettings(columns: 1, thumbnail: 320, preview: 640)
        settings.includeContactSheet = false
        _ = try DeliveryGalleryWriter.write(fileURLs: [sourceURL], settings: settings,
                                            outputDirectory: output)

        let thumbnailURL = output.appendingPathComponent("thumbs/01.jpg")
        let thumbnailSource = try XCTUnwrap(CGImageSourceCreateWithURL(thumbnailURL as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(thumbnailSource, 0, nil) as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String], "缩略图不得带 GPS 字典")
        // ImageIO may synthesize a minimal TIFF dictionary (e.g. orientation) when
        // decoding any JPEG; what must never be copied is the camera/artist data.
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake as String], "缩略图不得携带相机厂商")
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel as String], "缩略图不得携带相机型号")
        XCTAssertNil(tiff?[kCGImagePropertyTIFFArtist as String], "缩略图不得携带作者信息")
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifBodySerialNumber as String], "缩略图不得携带相机序列号")
    }

    // MARK: - Captions / watermark notice

    func testCaptionsAreEscapedAndWatermarkNoticeIsHonest() throws {
        let root = try makeTemporaryDirectory()
        let images = [makeImage(width: 400, height: 300, color: (0.5, 0.5, 0.5))]
        var watermarked = standardSettings(columns: 1, thumbnail: 320, preview: 640)
        watermarked.includeContactSheet = false
        watermarked.watermarkedPreviews = true
        let first = try DeliveryGalleryWriter.write(
            photos: [DeliveryPhoto(image: images[0], caption: "A & B <x>")],
            settings: watermarked,
            outputDirectory: root.appendingPathComponent("watermarked"))
        let watermarkedHTML = try readText(first.indexHTMLURL)
        XCTAssertTrue(watermarkedHTML.contains("A &amp; B &lt;x&gt;"), "caption 必须被转义")
        XCTAssertFalse(watermarkedHTML.contains("<x>"), "caption 不得注入 HTML")
        XCTAssertTrue(watermarkedHTML.contains("预览图含水印"), "水印提示必须如实出现")

        var plain = watermarked
        plain.watermarkedPreviews = false
        let second = try DeliveryGalleryWriter.write(images: images, settings: plain,
                                                     outputDirectory: root.appendingPathComponent("plain"))
        let plainHTML = try readText(second.indexHTMLURL)
        XCTAssertFalse(plainHTML.contains("预览图含水印"))
    }

    // MARK: - Fail-before-write behaviour

    func testMissingSourceFileFailsBeforeCreatingOutput() throws {
        let root = try makeTemporaryDirectory()
        let missing = root.appendingPathComponent("missing-source.jpg")
        let output = root.appendingPathComponent("delivery", isDirectory: true)
        let settings = standardSettings(columns: 2, thumbnail: 320, preview: 640)
        XCTAssertThrowsError(try DeliveryGalleryWriter.write(
            photos: [DeliveryPhoto(fileURL: missing)],
            settings: settings,
            outputDirectory: output)) { error in
            guard let atelierError = error as? AtelierError,
                  case .imageRead(let message) = atelierError else {
                return XCTFail("缺失源图片应报 imageRead，实际：\(error)")
            }
            XCTAssertTrue(message.contains("源图片不存在"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "源图片缺失时不得创建输出目录")
    }

    func testFileURLSourceProducesGallery() throws {
        let root = try makeTemporaryDirectory()
        let sourceURL = try makePlainJPEG(width: 800, height: 600, in: root)
        let output = root.appendingPathComponent("delivery", isDirectory: true)
        var settings = standardSettings(columns: 2, thumbnail: 320, preview: 640)
        settings.includeContactSheet = false
        let result = try DeliveryGalleryWriter.write(fileURLs: [sourceURL], settings: settings,
                                                     outputDirectory: output)
        XCTAssertEqual(result.photoCount, 1)
        XCTAssertNil(result.contactSheetURL)
        XCTAssertEqual(try imageSize(output.appendingPathComponent("thumbs/01.jpg")).width, 320)
        XCTAssertEqual(try imageSize(output.appendingPathComponent("thumbs/01.jpg")).height, 240)
    }

    // MARK: - P1-E Delivery Enhancements

    func testDeliveryThemesRenderCustomCSSVariables() throws {
        let root = try makeTemporaryDirectory()
        let images = [makeImage(width: 400, height: 300, color: (0.5, 0.5, 0.5))]

        // Test 1: darkGold
        var settings1 = standardSettings(columns: 2, thumbnail: 200, preview: 400)
        settings1.theme = .darkGold
        let res1 = try DeliveryGalleryWriter.write(images: images, settings: settings1,
                                                   outputDirectory: root.appendingPathComponent("theme_gold"))
        let html1 = try readText(res1.indexHTMLURL)
        XCTAssertTrue(html1.contains("--bg: #0f1216"), "darkGold 主题背景变量应为 #0f1216")
        XCTAssertTrue(html1.contains("--accent: #d4af37"), "darkGold 主题强调色应为 #d4af37")

        // Test 2: classicSilver
        var settings2 = standardSettings(columns: 2, thumbnail: 200, preview: 400)
        settings2.theme = .classicSilver
        let res2 = try DeliveryGalleryWriter.write(images: images, settings: settings2,
                                                   outputDirectory: root.appendingPathComponent("theme_silver"))
        let html2 = try readText(res2.indexHTMLURL)
        XCTAssertTrue(html2.contains("--bg: #141619"), "classicSilver 主题背景变量应为 #141619")
        XCTAssertTrue(html2.contains("--accent: #93b4d7"), "classicSilver 主题强调色应为 #93b4d7")

        // Test 3: warmLight
        var settings3 = standardSettings(columns: 2, thumbnail: 200, preview: 400)
        settings3.theme = .warmLight
        let res3 = try DeliveryGalleryWriter.write(images: images, settings: settings3,
                                                   outputDirectory: root.appendingPathComponent("theme_warm"))
        let html3 = try readText(res3.indexHTMLURL)
        XCTAssertTrue(html3.contains("--bg: #f8f6f0"), "warmLight 主题背景变量应为 #f8f6f0")
        XCTAssertTrue(html3.contains("--accent: #a05a2c"), "warmLight 主题强调色应为 #a05a2c")
    }

    func testDeliveryHeroCoverSection() throws {
        let root = try makeTemporaryDirectory()
        let images = [
            makeImage(width: 600, height: 400, color: (0.9, 0.1, 0.1)),
            makeImage(width: 400, height: 600, color: (0.1, 0.9, 0.1))
        ]

        // 1. With coverPhotoIndex = 0
        var settingsWithCover = standardSettings(columns: 2, thumbnail: 200, preview: 400)
        settingsWithCover.coverPhotoIndex = 0
        let resWithCover = try DeliveryGalleryWriter.write(images: images, settings: settingsWithCover,
                                                           outputDirectory: root.appendingPathComponent("with_cover"))
        let htmlWithCover = try readText(resWithCover.indexHTMLURL)
        XCTAssertTrue(htmlWithCover.contains("class=\"hero-cover\""), "启用封面图时应生成 hero-cover 区域")
        XCTAssertTrue(htmlWithCover.contains("previews/01.jpg"), "hero-cover 应引用首张预览图")

        // 2. Without coverPhotoIndex
        var settingsNoCover = standardSettings(columns: 2, thumbnail: 200, preview: 400)
        settingsNoCover.coverPhotoIndex = nil
        let resNoCover = try DeliveryGalleryWriter.write(images: images, settings: settingsNoCover,
                                                         outputDirectory: root.appendingPathComponent("no_cover"))
        let htmlNoCover = try readText(resNoCover.indexHTMLURL)
        XCTAssertFalse(htmlNoCover.contains("class=\"hero-cover\""), "未启用封面图时不应生成 hero-cover 区域")
    }

    func testDeliverySubtitleAndPhotographer() throws {
        let root = try makeTemporaryDirectory()
        let images = [makeImage(width: 400, height: 300, color: (0.4, 0.4, 0.4))]
        var settings = standardSettings(columns: 2, thumbnail: 200, preview: 400)
        settings.title = "大理旅拍"
        settings.subtitle = "风花雪月 <2026>"
        settings.photographer = "摄影师阿木 & Studio"

        let res = try DeliveryGalleryWriter.write(images: images, settings: settings,
                                                  outputDirectory: root.appendingPathComponent("meta_test"))
        let html = try readText(res.indexHTMLURL)
        XCTAssertTrue(html.contains("<p class=\"subtitle\">风花雪月 &lt;2026&gt;</p>"), "副标题应渲染且进行 HTML 转义")
        XCTAssertTrue(html.contains("制作/摄影：摄影师阿木 &amp; Studio"), "摄影师署名应渲染且进行 HTML 转义")
    }

    func testDeliveryPrivacyAuditReportGeneration() throws {
        let root = try makeTemporaryDirectory()
        let images = [
            makeImage(width: 500, height: 400, color: (0.3, 0.3, 0.3)),
            makeImage(width: 500, height: 400, color: (0.6, 0.6, 0.6))
        ]

        // 1. With privacy audit enabled (default)
        var settingsWithAudit = standardSettings(columns: 2, thumbnail: 200, preview: 400)
        settingsWithAudit.includePrivacyAudit = true
        let resWithAudit = try DeliveryGalleryWriter.write(images: images, settings: settingsWithAudit,
                                                           outputDirectory: root.appendingPathComponent("with_audit"))
        XCTAssertNotNil(resWithAudit.privacyAuditURL)
        let auditURL = resWithAudit.privacyAuditURL!
        XCTAssertTrue(FileManager.default.fileExists(atPath: auditURL.path))

        let auditData = try Data(contentsOf: auditURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DeliveryPrivacyAuditReport.self, from: auditData)
        XCTAssertEqual(report.photoCount, 2)
        XCTAssertEqual(report.auditStatus, "PASSED_CLEAN")
        XCTAssertTrue(report.strippedCategories.contains(where: { $0.contains("GPS") }))
        XCTAssertTrue(report.strippedCategories.contains(where: { $0.contains("序列号") }))

        // Check HTML link
        let html = try readText(resWithAudit.indexHTMLURL)
        XCTAssertTrue(html.contains("privacy-audit.json"))

        // 2. With privacy audit disabled
        var settingsNoAudit = standardSettings(columns: 2, thumbnail: 200, preview: 400)
        settingsNoAudit.includePrivacyAudit = false
        let noAuditDir = root.appendingPathComponent("no_audit")
        let resNoAudit = try DeliveryGalleryWriter.write(images: images, settings: settingsNoAudit,
                                                         outputDirectory: noAuditDir)
        XCTAssertNil(resNoAudit.privacyAuditURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: noAuditDir.appendingPathComponent("privacy-audit.json").path))
    }

    func testDeliveryServerLifecycleAndPathTraversal() throws {
        let root = try makeTemporaryDirectory()
        let testDir = root.appendingPathComponent("server_site", isDirectory: true)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        let indexFile = testDir.appendingPathComponent("index.html")
        let indexContent = "<!DOCTYPE html><html><body><h1>Atelier Delivery Server Test</h1></body></html>"
        try indexContent.write(to: indexFile, atomically: true, encoding: .utf8)

        let secretFile = root.appendingPathComponent("secret.txt")
        try "SENSITIVE_SECRET".write(to: secretFile, atomically: true, encoding: .utf8)

        let server = DeliveryServer()
        XCTAssertFalse(server.isRunning)

        try server.start(directory: testDir, preferredPort: 18880)
        XCTAssertTrue(server.isRunning)
        XCTAssertGreaterThan(server.port, 0)
        XCTAssertNotNil(server.localURL)

        guard let localURL = server.localURL else {
            XCTFail("server.localURL must not be nil")
            server.stop()
            return
        }

        // Test 1: GET / or index.html should return 200 OK
        let expect200 = expectation(description: "GET / returns 200 OK")
        let task = URLSession.shared.dataTask(with: localURL) { data, response, error in
            XCTAssertNil(error)
            if let httpResp = response as? HTTPURLResponse {
                XCTAssertEqual(httpResp.statusCode, 200)
                XCTAssertTrue(httpResp.value(forHTTPHeaderField: "Content-Type")?.contains("text/html") ?? false)
            }
            if let data = data, let text = String(data: data, encoding: .utf8) {
                XCTAssertTrue(text.contains("Atelier Delivery Server Test"))
            }
            expect200.fulfill()
        }
        task.resume()
        wait(for: [expect200], timeout: 5.0)

        // Test 2: GET non-existent file should return 404
        let expect404 = expectation(description: "GET non-existent returns 404")
        let notFoundURL = localURL.appendingPathComponent("missing.jpg")
        let task404 = URLSession.shared.dataTask(with: notFoundURL) { _, response, error in
            XCTAssertNil(error)
            if let httpResp = response as? HTTPURLResponse {
                XCTAssertEqual(httpResp.statusCode, 404)
            }
            expect404.fulfill()
        }
        task404.resume()
        wait(for: [expect404], timeout: 5.0)

        // Test 3: Path traversal protection
        // A client sending raw GET /../secret.txt should be blocked with 403 Forbidden
        let port = server.port
        let clientFd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(clientFd, 0)
        if clientFd >= 0 {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

            let connectRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(clientFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            XCTAssertEqual(connectRes, 0, "Socket connection to delivery server failed")

            let rawRequest = "GET /../secret.txt HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
            _ = rawRequest.withCString { send(clientFd, $0, strlen($0), 0) }

            var buffer = [CChar](repeating: 0, count: 1024)
            let readBytes = recv(clientFd, &buffer, buffer.count - 1, 0)
            close(clientFd)

            XCTAssertGreaterThan(readBytes, 0)
            let responseString = String(cString: buffer)
            XCTAssertTrue(responseString.contains("403 Forbidden"), "路径穿越应返回 403 Forbidden")
            XCTAssertFalse(responseString.contains("SENSITIVE_SECRET"), "不得泄露目录外机密文件")
        }

        // Test 4: Clean stop
        server.stop()
        XCTAssertFalse(server.isRunning)
    }

    // MARK: - Helpers

    private func standardSettings(columns: Int, thumbnail: Int, preview: Int) -> DeliverySettings {
        var settings = DeliverySettings()
        settings.title = "客户交付"
        settings.columnCount = columns
        settings.thumbnailMaxDimension = thumbnail
        settings.previewMaxDimension = preview
        settings.includeContactSheet = true
        settings.contactSheetColumns = max(1, min(4, columns))
        settings.paper = .a4
        settings.pageMarginFraction = 0.06
        return settings
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = try TestFiles.makeTemporaryDirectory()
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeImage(width: Int, height: Int,
                           color: (Double, Double, Double)) -> CIImage {
        let ciColor = CIColor(red: CGFloat(color.0), green: CGFloat(color.1),
                              blue: CGFloat(color.2), alpha: 1, colorSpace: sRGB)
            ?? CIColor(red: CGFloat(color.0), green: CGFloat(color.1), blue: CGFloat(color.2))
        return CIImage(color: ciColor).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func readText(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Byte-preserving text view for privacy scans (ISO Latin-1 maps every byte
    /// 1:1, so ASCII metadata markers cannot hide behind invalid UTF-8).
    private func readLatin1(_ url: URL) throws -> String {
        String(data: try Data(contentsOf: url), encoding: .isoLatin1) ?? ""
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }

    private func imageSize(_ url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AtelierError.imageRead("测试无法解码交付页图片：\(url.lastPathComponent)")
        }
        return (image.width, image.height)
    }

    private func generatedFileURLs(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw AtelierError.imageRead("测试无法枚举交付页文件")
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    /// JPEG with GPS / camera make / serial / artist metadata so a privacy test
    /// can prove the delivery artefacts contain none of it.
    private func makeMetadataHeavyJPEG(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("metadata-source.jpg")
        let image = try makeCGImage(width: 640, height: 480, gray: 0.55)
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 35.6812,
                kCGImagePropertyGPSLongitude: 139.7671,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitudeRef: "E"
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "SECRETCAM",
                kCGImagePropertyTIFFModel: "SECRETMODEL",
                kCGImagePropertyTIFFArtist: "SECRETARTIST"
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifBodySerialNumber: "SERIAL12345"
            ],
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        try writeJPEG(image, properties: properties, to: url)
        return url
    }

    private func makePlainJPEG(width: Int, height: Int, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("plain-source.jpg")
        let image = try makeCGImage(width: width, height: height, gray: 0.5)
        try writeJPEG(image, properties: [kCGImageDestinationLossyCompressionQuality: 0.9], to: url)
        return url
    }

    private func makeCGImage(width: Int, height: Int, gray: CGFloat) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AtelierError.imageWrite("测试图像上下文创建失败")
        }
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw AtelierError.imageWrite("测试图像创建失败")
        }
        return image
    }

    private func writeJPEG(_ image: CGImage, properties: [CFString: Any], to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.jpeg.identifier as CFString,
                                                                1, nil) else {
            throw AtelierError.imageWrite("测试 JPEG 编码器创建失败")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AtelierError.imageWrite("测试 JPEG 写入失败")
        }
    }
}

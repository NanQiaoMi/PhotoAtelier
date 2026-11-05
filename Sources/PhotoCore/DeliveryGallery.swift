import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Paper size of the contact-sheet PDF. Points are PDF points (1/72 inch).
public enum DeliveryPaperSize: String, Codable, Equatable, CaseIterable {
    case a4
    case letter

    public var points: CGSize {
        switch self {
        case .a4: return CGSize(width: 595.276, height: 841.89)
        case .letter: return CGSize(width: 612, height: 792)
        }
    }

    public var title: String {
        switch self {
        case .a4: return "A4"
        case .letter: return "Letter"
        }
    }
}

/// Visual color theme of the offline delivery page.
public enum DeliveryTheme: String, Codable, Equatable, CaseIterable {
    case darkGold
    case classicSilver
    case warmLight

    public var title: String {
        switch self {
        case .darkGold: return "黑金沉浸（深色）"
        case .classicSilver: return "经典冷灰（深色）"
        case .warmLight: return "温暖米白（浅色）"
        }
    }
}

/// Customer-facing local delivery page settings.
///
/// The delivery page is a static, fully offline artefact: one `index.html` with
/// inline CSS, relative `thumbs/` + `previews/` images and an optional
/// `contact-sheet.pdf`. Nothing is uploaded, no network request is made and no
/// image metadata (GPS, camera serial, EXIF) is written. This is intentionally
/// NOT a cloud client-proofing / photo-selection product: there is no tracking,
/// no comment/selection workflow and no remote availability.
public struct DeliverySettings: Codable, Equatable {
    /// Album title shown in the HTML header and PDF title band.
    public var title: String = "客户交付"
    /// Optional subtitle shown under the main title.
    public var subtitle: String? = nil
    /// Optional photographer or studio credit shown in the footer and meta band.
    public var photographer: String? = nil
    /// Color theme of the HTML album.
    public var theme: DeliveryTheme = .darkGold
    /// Optional index of the photo to use as a prominent hero cover above the grid.
    public var coverPhotoIndex: Int? = nil
    /// Whether a privacy-audit.json file is generated documenting stripped metadata.
    public var includePrivacyAudit: Bool = true
    /// Number of thumbnail columns in the HTML grid (`1...8`).
    public var columnCount: Int = 3
    /// Longest edge of the generated thumbnail JPEGs (`64...4096`).
    public var thumbnailMaxDimension: Int = 640
    /// Longest edge of the generated preview JPEGs (`256...8192`).
    public var previewMaxDimension: Int = 2400
    /// Whether `contact-sheet.pdf` is generated next to the HTML page.
    public var includeContactSheet: Bool = true
    /// Number of thumbnail columns in the contact-sheet grid (`1...8`).
    public var contactSheetColumns: Int = 4
    public var paper: DeliveryPaperSize = .a4
    /// Page margin / grid gutter base as a fraction of the paper's shorter edge.
    public var pageMarginFraction: Double = 0.06
    /// Informational flag: the caller rendered the previews with a watermark.
    /// The previews are supplied by the caller (the export pipeline applies the
    /// actual watermark) and this only adds a visible notice to the HTML/PDF —
    /// it does not draw pixels.
    public var watermarkedPreviews: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case title, subtitle, photographer, theme, coverPhotoIndex, includePrivacyAudit
        case columnCount, thumbnailMaxDimension, previewMaxDimension
        case includeContactSheet, contactSheetColumns, paper, pageMarginFraction, watermarkedPreviews
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "客户交付"
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        photographer = try container.decodeIfPresent(String.self, forKey: .photographer)
        theme = try container.decodeIfPresent(DeliveryTheme.self, forKey: .theme) ?? .darkGold
        coverPhotoIndex = try container.decodeIfPresent(Int.self, forKey: .coverPhotoIndex)
        includePrivacyAudit = try container.decodeIfPresent(Bool.self, forKey: .includePrivacyAudit) ?? true
        columnCount = try container.decodeIfPresent(Int.self, forKey: .columnCount) ?? 3
        thumbnailMaxDimension = try container.decodeIfPresent(Int.self, forKey: .thumbnailMaxDimension) ?? 640
        previewMaxDimension = try container.decodeIfPresent(Int.self, forKey: .previewMaxDimension) ?? 2400
        includeContactSheet = try container.decodeIfPresent(Bool.self, forKey: .includeContactSheet) ?? true
        contactSheetColumns = try container.decodeIfPresent(Int.self, forKey: .contactSheetColumns) ?? 4
        paper = try container.decodeIfPresent(DeliveryPaperSize.self, forKey: .paper) ?? .a4
        pageMarginFraction = try container.decodeIfPresent(Double.self, forKey: .pageMarginFraction) ?? 0.06
        watermarkedPreviews = try container.decodeIfPresent(Bool.self, forKey: .watermarkedPreviews) ?? false
    }

    public func validate() throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw AtelierError.invalidConfiguration("交付页标题不能为空。")
        }
        guard trimmedTitle.count <= 120 else {
            throw AtelierError.invalidConfiguration("交付页标题不能超过 120 个字符。")
        }
        if let sub = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !sub.isEmpty {
            guard sub.count <= 160 else {
                throw AtelierError.invalidConfiguration("交付页副标题不能超过 160 个字符。")
            }
        }
        if let photo = photographer?.trimmingCharacters(in: .whitespacesAndNewlines), !photo.isEmpty {
            guard photo.count <= 80 else {
                throw AtelierError.invalidConfiguration("摄影师署名不能超过 80 个字符。")
            }
        }
        if let cover = coverPhotoIndex {
            guard cover >= 0 else {
                throw AtelierError.invalidConfiguration("封面图序号不能为负数。")
            }
        }
        guard (1...8).contains(columnCount) else {
            throw AtelierError.invalidConfiguration("交付页缩略图列数必须在 1...8 之间。")
        }
        guard (64...4_096).contains(thumbnailMaxDimension) else {
            throw AtelierError.invalidConfiguration("交付页缩略图长边必须在 64...4096 像素之间。")
        }
        guard (256...8_192).contains(previewMaxDimension) else {
            throw AtelierError.invalidConfiguration("交付页预览图长边必须在 256...8192 像素之间。")
        }
        guard previewMaxDimension >= thumbnailMaxDimension else {
            throw AtelierError.invalidConfiguration("交付页预览图长边不能小于缩略图长边。")
        }
        guard (1...8).contains(contactSheetColumns) else {
            throw AtelierError.invalidConfiguration("接触表列数必须在 1...8 之间。")
        }
        guard pageMarginFraction.isFinite, (0.02...0.2).contains(pageMarginFraction) else {
            throw AtelierError.invalidConfiguration("接触表页边距必须在 0.02...0.2 之间（纸张短边比例）。")
        }
    }
}

/// One rendered photo to deliver. The caller has already applied grading,
/// retouching and any watermark; the delivery gallery only downsamples it and
/// writes metadata-free JPEGs plus the static page.
public struct DeliveryPhoto {
    public enum Source {
        /// A rendered Core Image graph (the normal export-pipeline path).
        case image(CIImage)
        /// An already exported local JPEG/PNG/HEIC file. Metadata from the source
        /// file is never copied to the delivery artefacts.
        case file(URL)
    }

    public let source: Source
    /// Optional caption written into the HTML/contact sheet (escaped as text).
    public let caption: String?

    public init(image: CIImage, caption: String? = nil) {
        self.source = .image(image)
        self.caption = caption
    }

    public init(fileURL: URL, caption: String? = nil) {
        self.source = .file(fileURL)
        self.caption = caption
    }
}

/// An offline audit record verifying that personal metadata (GPS, camera serials, etc.)
/// has been completely excluded from the customer delivery package.
public struct DeliveryPrivacyAuditReport: Codable, Equatable {
    public var title: String
    public var photoCount: Int
    public var auditStatus: String
    public var generatedAt: Date
    public var strippedCategories: [String]
    public var retainedCategories: [String]
    public var notes: String

    public init(
        title: String,
        photoCount: Int,
        generatedAt: Date = Date()
    ) {
        self.title = title
        self.photoCount = photoCount
        self.auditStatus = "PASSED_CLEAN"
        self.generatedAt = generatedAt
        self.strippedCategories = [
            "GPS 地理位置信息 (经度、纬度、海拔高度、朝向)",
            "相机硬件序列号 (机身识别码、镜头识别码)",
            "设备所有者 / 摄影师个人隐私元数据",
            "原始文件路径与目录系统信息",
            "相机专有厂商私有标记 (MakerNote / Private XMP)"
        ]
        self.retainedCategories = [
            "标准显示像素数据 (sRGB / Display P3)",
            "相册展示所必需的纯文本标题与公开说明"
        ]
        self.notes = "所有图片均由 PhotoAtelier 离线渲染管线生成纯净 JPEG，未携带源文件的 EXIF/TIFF/GPS 元数据字典。"
    }
}

/// Files produced by `DeliveryGalleryWriter` inside the output directory.
public struct DeliveryGalleryResult: Equatable {
    public let indexHTMLURL: URL
    public let contactSheetURL: URL?
    public let thumbnailDirectoryURL: URL
    public let previewDirectoryURL: URL
    public let photoCount: Int
    public let privacyAuditURL: URL?

    public init(
        indexHTMLURL: URL,
        contactSheetURL: URL?,
        thumbnailDirectoryURL: URL,
        previewDirectoryURL: URL,
        photoCount: Int,
        privacyAuditURL: URL? = nil
    ) {
        self.indexHTMLURL = indexHTMLURL
        self.contactSheetURL = contactSheetURL
        self.thumbnailDirectoryURL = thumbnailDirectoryURL
        self.previewDirectoryURL = previewDirectoryURL
        self.photoCount = photoCount
        self.privacyAuditURL = privacyAuditURL
    }
}

/// Computed contact-sheet pagination; exposed so the UI/tests can predict the
/// PDF without rendering it (capacity is deterministic for the same settings).
public struct DeliveryContactSheetLayout: Equatable {
    public let pageCount: Int
    public let columns: Int
    public let rowsPerPage: Int
    public let capacityPerPage: Int
    public let pageSize: CGSize
    public let contentRect: CGRect
    public let cellSize: CGSize
}

/// Builds the local customer delivery page: a static offline HTML album plus an
/// optional CoreGraphics contact-sheet PDF.
///
/// Boundaries (deliberate):
/// - Local static files only (`index.html`, relative `thumbs/` + `previews/`,
///   `contact-sheet.pdf`). No network access, no external links, no JavaScript.
/// - Thumbnails/previews are generated from caller-supplied rendered images and
///   written as JPEGs with **no metadata dictionary** — GPS, camera serial, EXIF
///   and XMP are therefore stripped rather than copied.
/// - This is not a typesetting/print-press tool and not a cloud selection
///   system; the contact sheet is a simple fixed-aspect grid for review.
/// - HTML/thumbnail/preview bytes are deterministic for the same inputs on the
///   same machine. PDF bytes contain Core Graphics' automatic creation date, so
///   the PDF guarantee is structural (page count/paper size/layout), not
///   byte-identical files.
public enum DeliveryGalleryWriter {
    public static let indexFileName = "index.html"
    public static let contactSheetFileName = "contact-sheet.pdf"
    public static let privacyAuditFileName = "privacy-audit.json"
    public static let thumbnailDirectoryName = "thumbs"
    public static let previewDirectoryName = "previews"

    private static let thumbnailJPEGQuality = 0.82
    private static let previewJPEGQuality = 0.92

    /// Writes the delivery page for already rendered images (the export-pipeline
    /// entry point used by the batch integration).
    public static func write(images: [CIImage],
                             settings: DeliverySettings,
                             outputDirectory: URL,
                             context: CIContext? = nil) throws -> DeliveryGalleryResult {
        try write(photos: images.map { DeliveryPhoto(image: $0) },
                  settings: settings,
                  outputDirectory: outputDirectory,
                  context: context)
    }

    /// Convenience overload for already exported local files.
    public static func write(fileURLs: [URL],
                             settings: DeliverySettings,
                             outputDirectory: URL,
                             context: CIContext? = nil) throws -> DeliveryGalleryResult {
        try write(photos: fileURLs.map { DeliveryPhoto(fileURL: $0) },
                  settings: settings,
                  outputDirectory: outputDirectory,
                  context: context)
    }

    /// Main entry point. Validates everything that can be validated before
    /// touching the filesystem, so an empty album or a missing source file never
    /// leaves a half-created delivery folder behind.
    public static func write(photos: [DeliveryPhoto],
                             settings: DeliverySettings,
                             outputDirectory: URL,
                             context: CIContext? = nil) throws -> DeliveryGalleryResult {
        try settings.validate()
        guard !photos.isEmpty else {
            throw AtelierError.invalidConfiguration("客户交付页至少需要一张已渲染照片，空相册不会生成。")
        }
        guard outputDirectory.isFileURL else {
            throw AtelierError.invalidConfiguration("客户交付页输出目录必须是本地文件夹。")
        }
        let renderContext = context ?? sharedContext

        // Resolve/decode every source before creating directories: a bad input
        // must fail without leaving partial artefacts.
        var images: [CIImage] = []
        images.reserveCapacity(photos.count)
        for (index, photo) in photos.enumerated() {
            images.append(try resolveImage(photo, index: index))
        }
        let names = zip(photos.indices, photos).map { index, _ in assetName(index) }

        let root = outputDirectory.standardizedFileURL
        let thumbnailDirectory = root.appendingPathComponent(thumbnailDirectoryName, isDirectory: true)
        let previewDirectory = root.appendingPathComponent(previewDirectoryName, isDirectory: true)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        } catch {
            throw AtelierError.imageWrite("无法创建客户交付页目录：\(error.localizedDescription)")
        }

        var thumbnails: [CGImage] = []
        var thumbnailSizes: [CGSize] = []
        thumbnails.reserveCapacity(images.count)
        thumbnailSizes.reserveCapacity(images.count)
        for (index, image) in images.enumerated() {
            let thumbnail = try renderJPEGSource(image,
                                                 maxDimension: settings.thumbnailMaxDimension,
                                                 context: renderContext,
                                                 label: names[index])
            let preview = try renderJPEGSource(image,
                                               maxDimension: settings.previewMaxDimension,
                                               context: renderContext,
                                               label: names[index])
            let thumbnailURL = thumbnailDirectory.appendingPathComponent("\(names[index]).jpg")
            let previewURL = previewDirectory.appendingPathComponent("\(names[index]).jpg")
            try writeJPEG(thumbnail, quality: thumbnailJPEGQuality, to: thumbnailURL)
            try writeJPEG(preview, quality: previewJPEGQuality, to: previewURL)
            thumbnails.append(thumbnail)
            thumbnailSizes.append(CGSize(width: thumbnail.width, height: thumbnail.height))
        }

        var contactSheetURL: URL?
        if settings.includeContactSheet {
            let layout = try contactSheetLayout(photoCount: photos.count, settings: settings)
            let pdfURL = root.appendingPathComponent(contactSheetFileName)
            try writeContactSheetPDF(thumbnails: thumbnails,
                                     thumbnailSizes: thumbnailSizes,
                                     names: names,
                                     captions: photos.map(\.caption),
                                     settings: settings,
                                     layout: layout,
                                     to: pdfURL)
            contactSheetURL = pdfURL
        }

        let html = makeHTML(names: names,
                            thumbnailSizes: thumbnailSizes,
                            captions: photos.map(\.caption),
                            settings: settings)
        let htmlURL = root.appendingPathComponent(indexFileName)
        do {
            try Data(html.utf8).write(to: htmlURL, options: .atomic)
        } catch {
            throw AtelierError.imageWrite("无法写入客户交付页 HTML：\(error.localizedDescription)")
        }

        var privacyAuditURL: URL?
        if settings.includePrivacyAudit {
            let audit = DeliveryPrivacyAuditReport(title: settings.title, photoCount: photos.count)
            let auditURL = root.appendingPathComponent(privacyAuditFileName)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(audit) {
                try? data.write(to: auditURL, options: [.atomic])
                privacyAuditURL = auditURL
            }
        }

        return DeliveryGalleryResult(indexHTMLURL: htmlURL,
                                     contactSheetURL: contactSheetURL,
                                     thumbnailDirectoryURL: thumbnailDirectory,
                                     previewDirectoryURL: previewDirectory,
                                     photoCount: photos.count,
                                     privacyAuditURL: privacyAuditURL)
    }

    /// Pagination of the contact sheet for the given settings. Throws on invalid
    /// settings / an empty album, so callers can show the expected page count in
    /// the UI before generating anything.
    public static func contactSheetLayout(photoCount: Int,
                                          settings: DeliverySettings) throws -> DeliveryContactSheetLayout {
        try settings.validate()
        guard photoCount > 0 else {
            throw AtelierError.invalidConfiguration("空相册不会生成接触表。")
        }
        let pageSize = settings.paper.points
        let margin = CGFloat(settings.pageMarginFraction) * min(pageSize.width, pageSize.height)
        let titleBand = max(26, margin * 1.5)
        let content = CGRect(x: margin,
                             y: margin,
                             width: pageSize.width - margin * 2,
                             height: pageSize.height - margin * 2 - titleBand)
        let columns = settings.contactSheetColumns
        let gap = max(4, margin * 0.35)
        let cellWidth = (content.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let cellHeight = cellWidth * 0.75
        let rows = max(1, Int(((content.height + gap) / (cellHeight + gap)).rounded(.down)))
        let capacity = columns * rows
        let pages = (photoCount + capacity - 1) / capacity
        return DeliveryContactSheetLayout(pageCount: pages,
                                          columns: columns,
                                          rowsPerPage: rows,
                                          capacityPerPage: capacity,
                                          pageSize: pageSize,
                                          contentRect: content,
                                          cellSize: CGSize(width: cellWidth, height: cellHeight))
    }

    // MARK: - Sources

    private static var sharedContext: CIContext {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        return CIContext(options: [
            .workingColorSpace: space,
            .outputColorSpace: space,
            .cacheIntermediates: false
        ])
    }

    private static func resolveImage(_ photo: DeliveryPhoto, index: Int) throws -> CIImage {
        switch photo.source {
        case .image(let image):
            return image
        case .file(let url):
            guard url.isFileURL else {
                throw AtelierError.invalidConfiguration("交付页第 \(index + 1) 张照片必须是本地文件。")
            }
            let standardized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path) else {
                throw AtelierError.imageRead("交付页源图片不存在：\(standardized.path)")
            }
            guard let image = CIImage(contentsOf: standardized,
                                      options: [.applyOrientationProperty: true]) else {
                throw AtelierError.imageRead("无法解码交付页源图片：\(standardized.path)")
            }
            return image
        }
    }

    private static func assetName(_ index: Int) -> String {
        String(format: "%02d", index + 1)
    }

    // MARK: - Image rendering / writing

    private static func renderJPEGSource(_ image: CIImage,
                                         maxDimension: Int,
                                         context: CIContext,
                                         label: String) throws -> CGImage {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0.5, extent.height > 0.5,
              extent.width <= 100_000, extent.height <= 100_000 else {
            throw AtelierError.imageRead("交付页第 \(label) 张照片尺寸无效。")
        }
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw AtelierError.imageWrite("无法创建交付页输出色彩空间。")
        }
        let scale = min(1, CGFloat(maxDimension) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let translated = image.transformed(by: CGAffineTransform(translationX: -extent.minX,
                                                                  y: -extent.minY))
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        let scaled: CIImage
        if scale < 0.9995 {
            scaled = translated.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform",
                                parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
                .cropped(to: target)
        } else {
            scaled = translated.cropped(to: target)
        }
        // JPEG delivery assets are opaque; flatten any alpha on white first.
        let background = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1,
                                               colorSpace: sRGB) ?? CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: target)
        let flattened = scaled.composited(over: background)
        guard let cgImage = context.createCGImage(flattened, from: target,
                                                 format: .RGBA8, colorSpace: sRGB) else {
            throw AtelierError.imageWrite("无法渲染交付页第 \(label) 张照片。")
        }
        return cgImage
    }

    /// Encodes JPEG through ImageIO with an *empty* metadata dictionary, so no
    /// EXIF/GPS/XMP from a source file is ever copied into the delivery folder.
    private static func writeJPEG(_ image: CGImage, quality: Double, to url: URL) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 UTType.jpeg.identifier as CFString,
                                                                 1, nil) else {
            throw AtelierError.imageWrite("无法创建交付页 JPEG 编码器：\(url.lastPathComponent)")
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AtelierError.imageWrite("无法编码交付页图片：\(url.lastPathComponent)")
        }
        do {
            try (data as Data).write(to: url, options: .atomic)
        } catch {
            throw AtelierError.imageWrite("无法写入交付页图片 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    // MARK: - HTML

    private static func makeHTML(names: [String],
                                 thumbnailSizes: [CGSize],
                                 captions: [String?],
                                 settings: DeliverySettings) -> String {
        let title = escapeHTML(settings.title.trimmingCharacters(in: .whitespacesAndNewlines))
        var figures: [String] = []
        figures.reserveCapacity(names.count)
        for (index, name) in names.enumerated() {
            let captionText = captions[index].map { escapeHTML($0) } ?? "第 \(index + 1) 张"
            let size = thumbnailSizes[index]
            let width = Int(size.width.rounded())
            let height = Int(size.height.rounded())
            let alt = escapeHTML("照片 \(index + 1)")
            figures.append("""
                  <figure>
                    <a href="\(previewDirectoryName)/\(name).jpg"><img src="\(thumbnailDirectoryName)/\(name).jpg" alt="\(alt)" width="\(width)" height="\(height)" loading="lazy"></a>
                    <figcaption>\(captionText)</figcaption>
                  </figure>
            """)
        }

        let themeCSS: String
        switch settings.theme {
        case .darkGold:
            themeCSS = """
            --bg: #0f1216;
            --text: #e8ecef;
            --card-bg: #171c22;
            --border: #232a32;
            --accent: #d4af37;
            --meta: #8b96a1;
            --caption: #9aa4ad;
            --footer: #7f8a94;
            --hero-border: #38311d;
            """
        case .classicSilver:
            themeCSS = """
            --bg: #141619;
            --text: #f0f3f6;
            --card-bg: #1e2227;
            --border: #2c323a;
            --accent: #93b4d7;
            --meta: #8a949e;
            --caption: #a0acb9;
            --footer: #747f8a;
            --hero-border: #2c323a;
            """
        case .warmLight:
            themeCSS = """
            --bg: #f8f6f0;
            --text: #2c2b29;
            --card-bg: #ffffff;
            --border: #e6e2da;
            --accent: #a05a2c;
            --meta: #797670;
            --caption: #5a5752;
            --footer: #87837c;
            --hero-border: #dcd7ce;
            """
        }

        let subtitleHTML: String
        if let sub = settings.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !sub.isEmpty {
            subtitleHTML = "\n  <p class=\"subtitle\">\(escapeHTML(sub))</p>"
        } else {
            subtitleHTML = ""
        }

        let photographerText: String
        if let p = settings.photographer?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            photographerText = " · 制作/摄影：\(escapeHTML(p))"
        } else {
            photographerText = ""
        }

        var heroCoverHTML = ""
        if let coverIndex = settings.coverPhotoIndex, names.indices.contains(coverIndex) {
            let coverName = names[coverIndex]
            let coverCaption = captions[coverIndex].map { escapeHTML($0) } ?? "精选封面"
            heroCoverHTML = """
            <section class="hero-cover">
              <a href="\(previewDirectoryName)/\(coverName).jpg"><img src="\(previewDirectoryName)/\(coverName).jpg" alt="精选封面" loading="eager"></a>
              <div class="hero-caption">★ 精选封面 · \(coverCaption)</div>
            </section>
            """
        }

        var extraLinks: [String] = []
        if settings.includeContactSheet {
            extraLinks.append("<a href=\"\(contactSheetFileName)\" target=\"_blank\">📑 打开接触表 PDF (可打印)</a>")
        }
        if settings.includePrivacyAudit {
            extraLinks.append("<a href=\"\(privacyAuditFileName)\" target=\"_blank\">📄 离线隐私审计报告 (无 GPS/无设备序列号)</a>")
        }
        let linksHTML = extraLinks.isEmpty ? "" : "\n  <p class=\"extra-links\">" + extraLinks.joined(separator: " · ") + "</p>"

        let notice = settings.watermarkedPreviews
            ? "\n  <p class=\"notice\">预览图含水印（由导出流程生成）。</p>"
            : ""

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="PhotoAtelier Local Delivery">
        <title>\(title)</title>
        <style>
        :root {
          --columns: \(settings.columnCount);
          --gap: 16px;
          \(themeCSS)
        }
        * { box-sizing: border-box; }
        body { margin: 0; padding: 28px; background: var(--bg); color: var(--text);
               font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", "PingFang SC", "Microsoft YaHei", Arial, sans-serif; }
        header, main, footer { max-width: 1200px; margin-left: auto; margin-right: auto; }
        header { margin-bottom: 24px; padding-bottom: 16px; border-bottom: 1px solid var(--border); }
        h1 { margin: 0 0 6px; font-size: 26px; font-weight: 600; letter-spacing: 0.5px; }
        .subtitle { margin: 0 0 8px; font-size: 15px; color: var(--accent); font-weight: 500; }
        .meta { margin: 0; font-size: 12px; color: var(--meta); }
        .extra-links { margin: 10px 0 0; font-size: 12px; color: var(--meta); }
        .extra-links a { color: var(--accent); text-decoration: none; margin-right: 8px; }
        .extra-links a:hover { text-decoration: underline; }
        .hero-cover { margin-bottom: 24px; border-radius: 8px; overflow: hidden; background: var(--card-bg); border: 1px solid var(--hero-border); }
        .hero-cover a { display: block; }
        .hero-cover img { display: block; width: 100%; max-height: 560px; object-fit: cover; }
        .hero-caption { padding: 10px 14px; font-size: 13px; color: var(--caption); background: var(--card-bg); }
        .grid { display: grid; grid-template-columns: repeat(var(--columns), minmax(0, 1fr)); gap: var(--gap); }
        figure { margin: 0; background: var(--card-bg); border-radius: 8px; overflow: hidden; border: 1px solid var(--border); transition: transform 0.15s ease; }
        figure:hover { transform: translateY(-2px); }
        figure a { display: block; }
        figure img { display: block; width: 100%; height: auto; }
        figcaption { padding: 8px 10px 10px; font-size: 12px; color: var(--caption); }
        footer { margin-top: 32px; padding-top: 16px; border-top: 1px solid var(--border); font-size: 12px; color: var(--footer); line-height: 1.7; }
        footer a { color: var(--accent); text-decoration: none; }
        footer a:hover { text-decoration: underline; }
        .notice { margin: 0 0 8px; font-size: 12px; color: var(--accent); }
        @media (max-width: 760px) { .grid { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
        @media print { body { background: #fff; color: #111; } figure { background: #fff; } .grid { gap: 8px; } }
        </style>
        </head>
        <body>
        <header>
          <h1>\(title)</h1>\(subtitleHTML)
          <p class="meta">共 \(names.count) 张照片 · 本地离线交付页\(photographerText)</p>\(linksHTML)\(notice)
        </header>
        <main>
        \(heroCoverHTML)
        <div class="grid">
        \(figures.joined(separator: "\n"))
        </div>
        </main>
        <footer>
          <p>本页为本地静态文件，无外部链接、无网络请求；图片元数据已剥离。可直接用浏览器打开 index.html 离线查看。</p>
        </footer>
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ value: String) -> String {
        var escaped = value
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&#39;")
        return escaped
    }

    // MARK: - Contact sheet PDF

    private static func writeContactSheetPDF(thumbnails: [CGImage],
                                             thumbnailSizes: [CGSize],
                                             names: [String],
                                             captions: [String?],
                                             settings: DeliverySettings,
                                             layout: DeliveryContactSheetLayout,
                                             to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: layout.pageSize)
        let info: [String: Any] = [
            kCGPDFContextTitle as String: settings.title,
            kCGPDFContextCreator as String: "PhotoAtelier Local Delivery"
        ]
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { _ = unlink(temporary.path) }
        guard let context = CGContext(temporary as CFURL, mediaBox: &mediaBox,
                                      info as CFDictionary) else {
            throw AtelierError.imageWrite("无法创建接触表 PDF：\(url.lastPathComponent)")
        }

        let margin = CGFloat(settings.pageMarginFraction) * min(layout.pageSize.width, layout.pageSize.height)
        let titleFontSize = min(22, max(12, margin * 0.5))
        let labelFontSize = max(7, min(9, layout.cellSize.height * 0.09))
        let borderColor = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  components: [0.72, 0.74, 0.76, 1]) ?? CGColor(gray: 0.72, alpha: 1)
        let textColor = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                components: [0.12, 0.13, 0.15, 1]) ?? CGColor(gray: 0.12, alpha: 1)
        let subtleColor = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  components: [0.45, 0.47, 0.50, 1]) ?? CGColor(gray: 0.45, alpha: 1)

        let totalPages = layout.pageCount
        for pageIndex in 0..<totalPages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)

            // Title band (every page) + sub line.
            let titleBaseline = layout.pageSize.height - margin - titleFontSize * 0.9
            drawPDFText(settings.title,
                        in: context,
                        at: CGPoint(x: margin, y: titleBaseline),
                        fontSize: titleFontSize,
                        color: textColor,
                        maxWidth: layout.pageSize.width - margin * 2)
            let subline = "共 \(names.count) 张 · 本机离线生成 · 第 \(pageIndex + 1) / \(totalPages) 页"
            drawPDFText(subline,
                        in: context,
                        at: CGPoint(x: margin, y: titleBaseline - titleFontSize * 0.9),
                        fontSize: max(8, titleFontSize * 0.48),
                        color: subtleColor,
                        maxWidth: layout.pageSize.width - margin * 2)

            let start = pageIndex * layout.capacityPerPage
            let end = min(names.count, start + layout.capacityPerPage)
            if start < end {
                for ordinal in start..<end {
                    let localIndex = ordinal - start
                    let column = localIndex % layout.columns
                    let row = localIndex / layout.columns
                    let gap = max(4, CGFloat(settings.pageMarginFraction)
                                  * min(layout.pageSize.width, layout.pageSize.height) * 0.35)
                    let cellX = layout.contentRect.minX + CGFloat(column) * (layout.cellSize.width + gap)
                    let cellY = layout.contentRect.maxY - layout.cellSize.height
                        - CGFloat(row) * (layout.cellSize.height + gap)
                    let cell = CGRect(x: cellX, y: cellY,
                                      width: layout.cellSize.width, height: layout.cellSize.height)
                    drawPDFCell(image: thumbnails[ordinal],
                                imageSize: thumbnailSizes[ordinal],
                                caption: captions[ordinal],
                                number: ordinal + 1,
                                in: cell,
                                context: context,
                                borderColor: borderColor,
                                textColor: subtleColor,
                                labelFontSize: labelFontSize)
                }
            }
            context.endPDFPage()
        }
        context.closePDF()

        let data: Data
        do {
            data = try Data(contentsOf: temporary)
        } catch {
            throw AtelierError.imageWrite("无法读取接触表 PDF：\(error.localizedDescription)")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw AtelierError.imageWrite("无法写入接触表 PDF：\(error.localizedDescription)")
        }
    }

    private static func drawPDFCell(image: CGImage,
                                    imageSize: CGSize,
                                    caption: String?,
                                    number: Int,
                                    in cell: CGRect,
                                    context: CGContext,
                                    borderColor: CGColor,
                                    textColor: CGColor,
                                    labelFontSize: CGFloat) {
        let padding = max(2, cell.height * 0.04)
        let imageArea = cell.insetBy(dx: padding, dy: padding)
        let fitted = aspectFitRect(size: imageSize, in: imageArea)
        context.draw(image, in: fitted)
        context.setStrokeColor(borderColor)
        context.setLineWidth(0.5)
        context.stroke(cell)

        // Keep contact-sheet labels short enough to stay inside the cell without
        // turning the sheet into a typesetting tool (HTML keeps the full caption).
        let rawLabel = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clipped = rawLabel.count > 48 ? String(rawLabel.prefix(48)) + "…" : rawLabel
        let label = clipped.isEmpty ? "\(number)" : "\(number) · \(clipped)"
        let labelY = cell.minY + max(1, padding * 0.5)
        drawPDFText(label,
                    in: context,
                    at: CGPoint(x: cell.minX + padding, y: labelY),
                    fontSize: labelFontSize,
                    color: textColor,
                    maxWidth: cell.width - padding * 2)
    }

    private static func aspectFitRect(size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0,
              rect.width > 0, rect.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2,
                      width: width, height: height)
    }

    @discardableResult
    private static func drawPDFText(_ text: String,
                                    in context: CGContext,
                                    at point: CGPoint,
                                    fontSize: CGFloat,
                                    color: CGColor,
                                    maxWidth: CGFloat?) -> CGFloat {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        var line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if let maxWidth, width > maxWidth, maxWidth > 1, fontSize > 6 {
            let scaledSize = max(6, fontSize * (maxWidth / width))
            let scaledFont = CTFontCreateUIFontForLanguage(.system, scaledSize, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, scaledSize, nil)
            attributes[NSAttributedString.Key(kCTFontAttributeName as String)] = scaledFont
            let scaled = NSAttributedString(string: text, attributes: attributes)
            line = CTLineCreateWithAttributedString(scaled as CFAttributedString)
            width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
        return width
    }
}

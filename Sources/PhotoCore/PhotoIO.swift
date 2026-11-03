import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Reads supported still images without discarding their embedded color profile.
public enum PhotoLoader {
    /// Still-image extensions decoded through ImageIO. HEIC/HEIF/AVIF/WebP are
    /// container/codec families that macOS ImageIO can read; an extension is only
    /// a candidate, so a file is accepted only after `load` actually decodes it.
    private static let rasterExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "tif", "tiff",
        "heic", "heif", "avif", "webp"
    ]

    // These are scan candidates only. A filename extension does not guarantee
    // that the macOS 13 RAW decoder supports the camera or file variant.
    private static let rawExtensions: Set<String> = [
        "3fr", "ari", "arw", "bay", "cap", "cr2", "cr3", "crw", "dcs", "dcr",
        "dng", "drf", "eip", "erf", "fff", "gpr", "iiq", "k25", "kdc", "mdc",
        "mef", "mos", "mrw", "nef", "nrw", "orf", "pef", "ptx", "pxn", "r3d",
        "raf", "raw", "rw2", "rwl", "rwz", "sr2", "srf", "srw", "x3f"
    ]

    /// Loads a photo. EXIF orientation is applied to the pixels and normalized in the
    /// returned properties so a later export cannot rotate the image a second time.
    public static func load(url: URL, lensCorrection: Bool, lensProfileID: String? = nil,
                            lensCropFactor: Double = 0, lensFocalLength: Double = 0) throws -> LoadedPhoto {
        guard url.isFileURL else { throw AtelierError.imageRead("只支持本地照片文件") }
        let sourceURL = url.standardizedFileURL
        let isRAW = isRawCandidate(sourceURL)
        guard isRAW || rasterExtensions.contains(sourceURL.pathExtension.lowercased()) else {
            throw AtelierError.imageRead("不支持的照片格式：\(sourceURL.pathExtension)")
        }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            if isRAW { throw rawReadError(sourceURL.lastPathComponent) }
            throw AtelierError.imageRead("ImageIO 无法打开 \(sourceURL.lastPathComponent)")
        }

        let sourceProperties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        if !isRAW {
            try validateSourceDimensions(sourceProperties, filename: sourceURL.lastPathComponent)
        }
        var report = ProcessingReport()
        if !isRAW {
            let frameCount = CGImageSourceGetCount(source)
            guard frameCount > 0 else {
                throw AtelierError.imageRead("ImageIO 无法解析此文件（格式可能不受本机支持或文件已损坏）：\(sourceURL.lastPathComponent)")
            }
            guard frameCount == 1 else {
                throw AtelierError.imageRead("只处理单页静态照片，请先将多页 TIFF / 动画 PNG / HEIC 序列拆分为单张照片")
            }
        }

        var image: CIImage
        var sourceSpace: String
        var rawAnalysis: [String: Any]? = nil
        var inputProperties = sourceProperties
        if isRAW {
            let decoded = try decodeRAW(url: sourceURL, properties: sourceProperties)
            image = decoded.image
            sourceSpace = decoded.sourceColorSpace
            rawAnalysis = decoded.analysis
            inputProperties = decoded.properties
            report.inputWasRAW = true
        } else {
            guard let rasterImage = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true]) else {
                throw AtelierError.imageRead("无法解码图像：\(sourceURL.lastPathComponent)")
            }
            image = rasterImage
            sourceSpace = rasterImage.colorSpace?.name as String? ?? "系统默认"
        }

        if lensCorrection {
            let corrected = try LensCorrection.shared.correct(image, properties: inputProperties,
                                                               profileID: lensProfileID, cropFactor: lensCropFactor,
                                                               focalLength: lensFocalLength)
            image = corrected.image; report = corrected.report
        }
        report.inputWasRAW = isRAW

        guard isUsableExtent(image.extent) else {
            throw AtelierError.imageRead("图像尺寸无效：\(sourceURL.lastPathComponent)")
        }
        try validateProcessingExtent(image.extent, filename: sourceURL.lastPathComponent)

        var properties = inputProperties
        if let rawAnalysis {
            properties["PhotoAtelierRAWAnalysis"] = rawAnalysis
        }
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff["Orientation"] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        let width = Int(image.extent.width.rounded())
        let height = Int(image.extent.height.rounded())
        properties[kCGImagePropertyPixelWidth as String] = width
        properties[kCGImagePropertyPixelHeight as String] = height
        report.sourceColorSpace = sourceSpace
        return LoadedPhoto(image: image, properties: properties, report: report)
    }

    private static func decodeRAW(url: URL, properties: [String: Any]) throws
        -> (image: CIImage, sourceColorSpace: String, analysis: [String: Any], properties: [String: Any]) {
        guard let rawFilter = CIRAWFilter(imageURL: url) else {
            throw rawReadError(url.lastPathComponent)
        }
        let decoderProperties = rawFilter.properties as? [String: Any] ?? properties

        // CIRAWFilter's nativeSize is the full, unrotated sensor image. Keep the
        // full-resolution scale and reject oversized inputs before requesting output.
        rawFilter.scaleFactor = 1
        rawFilter.isDraftModeEnabled = false
        let nativeSize = rawFilter.nativeSize
        guard nativeSize.width.isFinite, nativeSize.height.isFinite,
              nativeSize.width > 0, nativeSize.height > 0 else {
            throw rawReadError(url.lastPathComponent)
        }
        try validateDimensions(width: Double(nativeSize.width),
                              height: Double(nativeSize.height),
                              filename: url.lastPathComponent)

        let orientation = try rawOrientation(from: decoderProperties, fallback: rawFilter.orientation,
                                             filename: url.lastPathComponent)
        rawFilter.orientation = orientation

        // Keep the decoder's as-shot neutral values. CIRAWFilter exposes these as
        // decoder-derived temperature/tint values; do not replace them with a new WB.
        // Disable optional camera rendering choices that would duplicate app edits.
        rawFilter.exposure = 0
        // Preserve the decoder's camera-dependent baseline normalization. It is
        // distinct from the user's exposure compensation, whose value is zero.
        let baselineExposure = Double(rawFilter.baselineExposure)
        rawFilter.shadowBias = 0
        rawFilter.boostAmount = 0
        rawFilter.boostShadowAmount = 1
        rawFilter.isGamutMappingEnabled = false
        rawFilter.isLensCorrectionEnabled = false
        rawFilter.luminanceNoiseReductionAmount = 0
        rawFilter.colorNoiseReductionAmount = 0
        rawFilter.sharpnessAmount = 0
        rawFilter.contrastAmount = 0
        rawFilter.detailAmount = 0
        rawFilter.moireReductionAmount = 0
        rawFilter.localToneMapAmount = 0
        rawFilter.extendedDynamicRangeAmount = 1
        rawFilter.linearSpaceFilter = nil

        // Only CIRAWFilter.outputImage is used for full-size RAW input. ImageIO's
        // embedded preview/thumbnail APIs are intentionally not a decode fallback.
        guard let decoded = rawFilter.outputImage, isUsableExtent(decoded.extent) else {
            throw rawReadError(url.lastPathComponent)
        }
        try validateProcessingExtent(decoded.extent, filename: url.lastPathComponent)

        // Keep the decoder's tagged graph. PhotoEngine/PhotoAnalyzer render it
        // into extended-linear sRGB through CIContext. Applying an explicit
        // matchedToWorkingSpace here would repeat a display transfer conversion.

        let temperature = Double(rawFilter.neutralTemperature)
        let tint = Double(rawFilter.neutralTint)
        let temperatureValue: Any = temperature.isFinite && (2_000...50_000).contains(temperature)
            ? NSNumber(value: temperature) : NSNull()
        let tintValue: Any = tint.isFinite && (-150...150).contains(tint)
            ? NSNumber(value: tint) : NSNull()
        let exif = decoderProperties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let originalWhiteBalance = exif[kCGImagePropertyExifWhiteBalance as String] ?? NSNull()
        let asShotWhiteBalance: [String: Any] = [
            "temperatureKelvin": temperatureValue,
            "tint": tintValue,
            "provenance": "decoderEstimated",
            "label": "RAW解码器白点估计"
        ]
        let originalEXIFWhiteBalance: [String: Any] = [
            "mode": originalWhiteBalance,
            "temperatureKelvin": NSNull(),
            "tint": NSNull(),
            "provenance": "originalEXIF"
        ]
        let analysis: [String: Any] = [
            "decoder": "CIRAWFilter",
            "decoderVersion": rawFilter.decoderVersion.rawValue,
            "workingColorSpace": "extendedLinearSRGB",
            "rendering": "scene-linear",
            "baselineExposureEV": baselineExposure.isFinite ? NSNumber(value: baselineExposure) : NSNull(),
            "asShotWhiteBalance": asShotWhiteBalance,
            "originalEXIFWhiteBalance": originalEXIFWhiteBalance
        ]
        let colorSpaceName = decoded.colorSpace?.name as String? ?? "unknown decoder profile"
        return (decoded, "RAW decoder → extendedLinearSRGB (scene-linear; source \(colorSpaceName))",
                analysis, decoderProperties)
    }

    private static func rawOrientation(from properties: [String: Any],
                                       fallback: CGImagePropertyOrientation,
                                       filename: String) throws -> CGImagePropertyOrientation {
        let rootValue = properties[kCGImagePropertyOrientation as String] as? NSNumber
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let tiffValue = tiff?[kCGImagePropertyTIFFOrientation as String] as? NSNumber
        guard let number = rootValue ?? tiffValue else { return fallback }
        let value = number.uint32Value
        guard (1...8).contains(value), let orientation = CGImagePropertyOrientation(rawValue: value) else {
            throw AtelierError.imageRead("RAW EXIF 方向无效：\(filename)")
        }
        return orientation
    }

    private static func rawReadError(_ filename: String) -> AtelierError {
        AtelierError.imageRead("RAW 解码失败：macOS RAW 解码器不支持此相机/格式，或文件已损坏；未使用内嵌 JPEG 预览图：\(filename)")
    }

    /// Returns raster files and common RAW decoder candidates in stable path order.
    /// A RAW candidate's camera/format support is confirmed only when it is decoded.
    /// Symbolic links are ignored so scans never leave the requested folder.
    public static func scan(folder: URL, recursive: Bool) throws -> [PhotoItem] {
        guard folder.isFileURL else { throw AtelierError.imageRead("扫描目录必须是本地文件夹") }
        let root = folder.standardizedFileURL
        guard try isDirectory(root), !(try isSymbolicLink(root)) else {
            throw AtelierError.imageRead("扫描路径不是普通文件夹：\(root.path)")
        }

        var candidates: [URL] = []
        if recursive {
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, error in
                    enumerationError = enumerationError ?? error
                    return false
                }
            ) else {
                throw AtelierError.imageRead("无法枚举文件夹：\(root.path)")
            }
            for case let url as URL in enumerator {
                if try isSymbolicLink(url) {
                    if (try? isDirectory(url)) == true { enumerator.skipDescendants() }
                    continue
                }
                if try isRegularFile(url), isSupportedCandidate(url) { candidates.append(url) }
            }
            if let error = enumerationError {
                throw AtelierError.imageRead("扫描文件夹失败：\(error.localizedDescription)")
            }
        } else {
            do {
                let urls = try FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
                for url in urls where !(try isSymbolicLink(url)) {
                    if try isRegularFile(url), isSupportedCandidate(url) { candidates.append(url) }
                }
            } catch let error as AtelierError {
                throw error
            } catch {
                throw AtelierError.imageRead("扫描文件夹失败：\(error.localizedDescription)")
            }
        }

        return candidates
            .map { $0.standardizedFileURL }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .compactMap { url in
                guard let relative = relativePath(of: url, under: root) else { return nil }
                return PhotoItem(url: url, relativePath: relative)
            }
    }

    /// Creates an orientation-correct thumbnail with its longest side bounded by
    /// `maxDimension` pixels.
    public static func thumbnail(url: URL, maxDimension: Int) throws -> CGImage {
        guard (1...4_096).contains(maxDimension) else {
            throw AtelierError.invalidConfiguration("缩略图尺寸必须在 1 到 4096 像素之间")
        }
        guard url.isFileURL else { throw AtelierError.imageRead("缩略图只支持本地照片文件") }
        let sourceURL = url.standardizedFileURL
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw AtelierError.imageRead("ImageIO 无法打开 \(sourceURL.lastPathComponent)")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        if let result = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return result
        }

        guard let image = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true]),
              isUsableExtent(image.extent) else {
            throw AtelierError.imageRead("无法生成缩略图：\(sourceURL.lastPathComponent)")
        }
        let longestSide = max(image.extent.width, image.extent.height)
        let scale = min(1, CGFloat(maxDimension) / longestSide)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let result = context.createCGImage(scaled, from: scaled.extent.integral) else {
            throw AtelierError.imageRead("无法渲染缩略图：\(sourceURL.lastPathComponent)")
        }
        return result
    }

    /// Whether a filename is even a candidate input, by extension only
    /// (raster formats plus RAW decoder candidates). A filename extension does not
    /// prove the file decodes; `load` still reports the real decode error.
    static func isSupportedCandidate(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return rasterExtensions.contains(fileExtension) || isRawCandidate(url)
    }

    private static func isRawCandidate(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        if rawExtensions.contains(fileExtension) { return true }
        return UTType(filenameExtension: fileExtension)?.conforms(to: .rawImage) == true
    }

    /// Relative path of `url` inside `root`, or nil when it is not below the root.
    static func relativePath(of url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    private static func isDirectory(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }

    private static func isRegularFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func isSymbolicLink(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    }

    private static func isUsableExtent(_ extent: CGRect) -> Bool {
        extent.width.isFinite && extent.height.isFinite && extent.width > 0 && extent.height > 0 &&
        extent.origin.x.isFinite && extent.origin.y.isFinite
    }

    private static func validateSourceDimensions(_ properties: [String: Any], filename: String) throws {
        guard let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue else { return }
        try validateDimensions(width: width, height: height, filename: filename)
    }

    private static func validateProcessingExtent(_ extent: CGRect, filename: String) throws {
        try validateDimensions(width: Double(extent.width), height: Double(extent.height), filename: filename)
    }

    private static func validateDimensions(width: Double, height: Double, filename: String) throws {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw AtelierError.imageRead("图像尺寸无效：\(filename)")
        }
        let safeWidth = ceil(width)
        let safeHeight = ceil(height)
        guard safeWidth <= 32_768, safeHeight <= 32_768, safeWidth * safeHeight <= 120_000_000 else {
            throw AtelierError.imageRead("照片超过安全尺寸上限（单边 32768 像素或 120 MP），已跳过：\(filename)")
        }
    }
}

/// Encodes an image using a fresh output profile and an atomic no-overwrite install.
public enum PhotoExporter {
    public static func write(
        image: CIImage,
        to url: URL,
        settings: ExportSettings,
        sourceProperties: [String: Any],
        context: CIContext
    ) throws {
        guard url.isFileURL else { throw AtelierError.imageWrite("导出路径必须是本地文件") }
        try validate(settings)
        guard isUsableExtent(image.extent) else { throw AtelierError.imageWrite("导出图像尺寸无效") }

        let destination = url.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw AtelierError.imageWrite("导出文件夹不存在：\(parent.path)")
        }

        let colorSpace: CGColorSpace
        switch settings.colorSpace {
        case .sRGB:
            guard let value = CGColorSpace(name: CGColorSpace.sRGB) else {
                throw AtelierError.imageWrite("无法创建 sRGB 色彩空间")
            }
            colorSpace = value
        case .displayP3:
            guard let value = CGColorSpace(name: CGColorSpace.displayP3) else {
                throw AtelierError.imageWrite("无法创建 Display P3 色彩空间")
            }
            colorSpace = value
        }

        let bounds = image.extent.integral
        guard bounds.width > 0, bounds.height > 0,
              bounds.width <= 32_768, bounds.height <= 32_768,
              bounds.width * bounds.height <= 120_000_000 else {
            throw AtelierError.imageWrite("处理后的图像超过安全尺寸上限（单边 32768 像素或 120 MP）")
        }
        let outputImage: CIImage
        let outputFormat: CIFormat
        switch settings.format {
        case .jpeg:
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: bounds)
            outputImage = image.composited(over: white).cropped(to: bounds)
            outputFormat = .RGBA8
        case .tiff, .png:
            outputImage = image.cropped(to: bounds)
            outputFormat = .RGBA16
        }

        // Materialize the complete render before handing it to ImageIO. A lazy
        // CGImage lets the encoder choose tiled evaluation of a RAW/filter graph,
        // which can differ from the inspected raster even with the same ICC.
        guard let cgImage = context.createCGImage(outputImage, from: bounds, format: outputFormat,
                                                colorSpace: colorSpace, deferred: false) else {
            throw AtelierError.imageWrite("无法将图像转换为目标色彩空间")
        }

        let typeIdentifier: String
        switch settings.format {
        case .jpeg: typeIdentifier = UTType.jpeg.identifier
        case .tiff: typeIdentifier = UTType.tiff.identifier
        case .png: typeIdentifier = UTType.png.identifier
        }

        var outputProperties: [String: Any] = [:]
        if !settings.stripMetadata {
            outputProperties = retainedMetadata(from: sourceProperties)
        }
        outputProperties[kCGImagePropertyOrientation as String] = 1
        outputProperties[kCGImagePropertyPixelWidth as String] = cgImage.width
        outputProperties[kCGImagePropertyPixelHeight as String] = cgImage.height
        var exifProperties = outputProperties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exifProperties["ColorSpace"] = settings.colorSpace == .sRGB ? 1 : 65_535
        outputProperties[kCGImagePropertyExifDictionary as String] = exifProperties
        if settings.format == .jpeg {
            outputProperties[kCGImageDestinationLossyCompressionQuality as String] = settings.jpegQuality
        }

        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { _ = Darwin.unlink(temporary.path) }

        guard let imageDestination = CGImageDestinationCreateWithURL(temporary as CFURL, typeIdentifier as CFString, 1, nil) else {
            throw AtelierError.imageWrite("无法创建临时导出文件")
        }
        CGImageDestinationAddImage(imageDestination, cgImage, outputProperties as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw AtelierError.imageWrite("图像编码失败")
        }

        // Exclusive rename commits the completed sibling temp file atomically and
        // fails if another file appeared at the destination while encoding.
        let installResult = temporary.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard installResult == 0 else {
            if errno == EEXIST {
                throw AtelierError.imageWrite("目标文件已存在，未覆盖：\(destination.lastPathComponent)")
            }
            throw AtelierError.imageWrite("无法安装导出文件：\(posixErrorDescription())")
        }
    }

    private static func validate(_ settings: ExportSettings) throws {
        guard settings.jpegQuality.isFinite, (0...1).contains(settings.jpegQuality) else {
            throw AtelierError.invalidConfiguration("JPEG 品质必须在 0 到 1 之间")
        }
        guard settings.suffix.count <= 80,
              !settings.suffix.contains("/"), !settings.suffix.contains("\\"),
              !settings.suffix.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AtelierError.invalidConfiguration("导出后缀包含无效字符或过长")
        }
    }

    private static func retainedMetadata(from source: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        let tiffKeys: Set<String> = ["Make", "Model", "DateTime", "Software", "Artist", "Copyright", "ImageDescription", "HostComputer", "DocumentName"]
        let exifKeys: Set<String> = [
            "DateTimeOriginal", "DateTimeDigitized", "ExposureTime", "FNumber", "ISOSpeedRatings",
            "ShutterSpeedValue", "ApertureValue", "BrightnessValue", "ExposureBiasValue", "MaxApertureValue",
            "MeteringMode", "Flash", "FocalLength", "SubjectArea", "LensModel", "LensMake", "WhiteBalance",
            "ExposureProgram", "LightSource", "SensingMethod", "SceneType", "SceneCaptureType",
            "DigitalZoomRatio", "FocalLengthIn35mmFilm", "Contrast", "Saturation", "Sharpness"
        ]
        let gpsKeys: Set<String> = [
            "GPSVersion", "LatitudeRef", "Latitude", "LongitudeRef", "Longitude", "AltitudeRef", "Altitude",
            "TimeStamp", "Satellites", "Status", "MeasureMode", "DOP", "SpeedRef", "Speed", "TrackRef",
            "Track", "ImgDirectionRef", "ImgDirection", "MapDatum", "DateStamp", "HPositioningError"
        ]
        for (dictionaryKey, allowedKeys) in [
            (kCGImagePropertyTIFFDictionary as String, tiffKeys),
            (kCGImagePropertyExifDictionary as String, exifKeys),
            (kCGImagePropertyGPSDictionary as String, gpsKeys)
        ] {
            guard let original = source[dictionaryKey] as? [String: Any] else { continue }
            let filtered = original.filter { allowedKeys.contains($0.key) }
            if !filtered.isEmpty { result[dictionaryKey] = filtered }
        }
        return result
    }

    private static func isUsableExtent(_ extent: CGRect) -> Bool {
        extent.width.isFinite && extent.height.isFinite && extent.width > 0 && extent.height > 0 &&
        extent.origin.x.isFinite && extent.origin.y.isFinite
    }

    private static func posixErrorDescription() -> String {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription
    }
}

import Foundation
import CoreGraphics
import CoreImage
import Darwin

public final class BatchProcessor {
    public init() {}

    public func run(
        items: [PhotoItem],
        inputRoot: URL,
        outputRoot: URL,
        recipe: Recipe,
        lut: LUTCube?,
        cancellation: CancellationToken,
        onEvent: @escaping (BatchEvent) -> Void
    ) throws -> BatchSummary {
        try validateRecipe(recipe)
        try PhotoEngine.validate(recipe.adjustments)
        try recipe.automatic?.validate()
        try validateRecipeLUT(recipe, supplied: lut)

        let fileManager = FileManager.default
        let input = try canonicalDirectory(inputRoot, create: false, label: "输入目录")
        let requestedOutput = outputRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard requestedOutput.isFileURL else {
            throw AtelierError.invalidConfiguration("输出目录必须是本地路径")
        }
        guard !directoriesOverlap(input, requestedOutput) else {
            throw AtelierError.invalidConfiguration("输入与输出目录不能相同，也不能互相包含")
        }

        do {
            try fileManager.createDirectory(at: requestedOutput, withIntermediateDirectories: true)
        } catch {
            throw AtelierError.imageWrite("无法为批次配方快照准备输出目录：\(error.localizedDescription)")
        }
        let output = try canonicalDirectory(requestedOutput, create: false, label: "输出目录")
        guard !directoriesOverlap(input, output) else {
            throw AtelierError.invalidConfiguration("输入与输出目录解析后发生重叠")
        }

        let runID = UUID().uuidString.lowercased()
        let manifestURL = output.appendingPathComponent("batch-\(runID).json", isDirectory: false)
        var manifest = BatchManifest(
            version: 4,
            runID: runID,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            recipe: recipe,
            exportSummary: describeExportSettings(recipe.export),
            warnings: recipe.lutPath == nil && recipe.lutIdentifier == nil && lut != nil
                ? ["当前配方未记录 LUT 路径或内置标识符，快照不能独立重放。"] : [],
            cancelled: false,
            entries: []
        )

        do {
            try createManifest(manifest, at: manifestURL)
        } catch {
            throw AtelierError.imageWrite("无法保存批次配方快照：\(error.localizedDescription)")
        }

        var summary = BatchSummary(manifestURL: manifestURL)
        onEvent(BatchEvent(kind: .started, index: 0, total: items.count, message: "开始批量处理"))
        let engine = PhotoEngine()
        // Watermark is an export-level stage: PhotoExporter applies it from
        // `recipe.export.watermark`. "Dual version" additionally writes a clean
        // copy of every photo, so a delivery can ship both variants in one run.
        let watermarkActive = WatermarkRenderer.shouldApply(recipe.export.watermark)
        let dualWatermark = recipe.export.exportsDualWatermarkVersion
        var cleanExportSettings = recipe.export
        cleanExportSettings.watermark = nil
        cleanExportSettings.watermarkDualVersion = nil
        // Customer delivery page: generated after the loop from the primary
        // exported files (already colour-managed and metadata-stripped), so an
        // album never holds full-resolution CI graphs in memory. The delivery
        // settings themselves are validated before the output directory exists.
        var effectiveDeliverySettings = recipe.export.deliveryPage
        if watermarkActive, effectiveDeliverySettings != nil {
            // The primary exported file contains the watermark, so the previews
            // shown to the client are watermarked too; keep the honest notice.
            effectiveDeliverySettings?.watermarkedPreviews = true
        }
        var deliveredFileURLs: [URL] = []

        for (offset, item) in items.enumerated() {
            let index = offset + 1
            if cancellation.isCancelled {
                summary.cancelled = true
                manifest.cancelled = true
                onEvent(BatchEvent(kind: .cancelled, index: offset, total: items.count, message: "任务已取消"))
                break
            }

            onEvent(BatchEvent(kind: .processing, index: index, total: items.count, input: item.url,
                               message: "正在处理 \(item.relativePath)"))
            let outcome: ItemOutcome = autoreleasepool {
                do {
                    try cancellation.check()
                    let sourceURL = try validateInput(item, under: input)
                    let loaded = try PhotoLoader.load(url: sourceURL, lensCorrection: recipe.adjustments.lensCorrection,
                                                      lensProfileID: recipe.adjustments.lensProfileID,
                                                      lensCropFactor: recipe.adjustments.lensCropFactor,
                                                      lensFocalLength: recipe.adjustments.lensFocalLength)
                    try cancellation.check()
                    var settings = recipe.adjustments
                    var report = loaded.report
                    if let automatic = recipe.automatic {
                        let analysis = try PhotoAnalyzer().analyze(image: loaded.image,
                                                                  properties: loaded.properties,
                                                                  sourceURL: sourceURL,
                                                                  baseline: automatic.baseline,
                                                                  intent: automatic.sceneIntent ?? .automatic)
                        try cancellation.check()
                        settings = try automatic.resolve(analysis: analysis, current: settings)
                        report.analysis = AutomaticAnalysisRecord(analysis: analysis,
                                                                  selectedProposal: automatic.styleID,
                                                                  applied: settings)
                    }
                    let processed = try engine.process(
                        loaded.image,
                        settings: settings,
                        lut: lut,
                        initialReport: report,
                        outputColorSpace: recipe.export.colorSpace,
                        cancellation: cancellation
                    )
                    try cancellation.check()
                    let baseURL = try makeOutputBaseURL(for: item.relativePath, under: output,
                                                        settings: recipe.export, index: index)
                    let outputURL = try writeUnique(
                        image: processed.image,
                        baseURL: baseURL,
                        settings: recipe.export,
                        sourceProperties: loaded.properties,
                        context: engine.context,
                        cancellation: cancellation
                    )
                    var watermarkFreeURL: URL?
                    if dualWatermark {
                        do {
                            try cancellation.check()
                            let cleanBaseURL = noWatermarkBaseURL(from: baseURL)
                            watermarkFreeURL = try writeUnique(
                                image: processed.image,
                                baseURL: cleanBaseURL,
                                settings: cleanExportSettings,
                                sourceProperties: loaded.properties,
                                context: engine.context,
                                cancellation: cancellation
                            )
                        } catch {
                            // Both versions are one deliverable: never leave a
                            // half-written pair. Remove the primary file before
                            // reporting the item as failed/cancelled.
                            _ = Darwin.unlink(outputURL.path)
                            throw error
                        }
                    }
                    return .success(output: outputURL, report: processed.report,
                                    watermarkFreeOutput: watermarkFreeURL)
                } catch {
                    return .failure(error)
                }
            }
            engine.context.clearCaches()

            switch outcome {
            case .success(let outputURL, let report, let watermarkFreeOutput):
                let entry = BatchManifestEntry(
                    input: item.relativePath,
                    output: relativePath(of: outputURL, under: output),
                    status: "completed",
                    message: "",
                    report: report,
                    watermarkApplied: watermarkActive ? true : nil,
                    watermarkFreeOutput: watermarkFreeOutput.flatMap { relativePath(of: $0, under: output) }
                )
                manifest.entries.append(entry)
                do {
                    try updateManifest(manifest, at: manifestURL)
                } catch {
                    let cleanupResult = Darwin.unlink(outputURL.path)
                    if let watermarkFreeOutput { _ = Darwin.unlink(watermarkFreeOutput.path) }
                    if cleanupResult == 0 || errno == ENOENT {
                        throw AtelierError.imageWrite("输出已撤销；无法原子更新批次清单：\(error.localizedDescription)")
                    }
                    let cleanupError = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription
                    throw AtelierError.imageWrite("批次清单更新失败：\(error.localizedDescription)；撤销本项输出也失败：\(cleanupError)")
                }
                deliveredFileURLs.append(outputURL)
                summary.succeeded += 1
                onEvent(BatchEvent(kind: .completed, index: index, total: items.count, input: item.url,
                                   output: outputURL, report: report))
                if cancellation.isCancelled {
                    // Export is an atomic per-photo boundary: persist the completed
                    // file first, then stop before starting another item.
                    summary.cancelled = true
                    manifest.cancelled = true
                    try updateManifestOrThrow(manifest, at: manifestURL)
                    onEvent(BatchEvent(kind: .cancelled, index: index, total: items.count, input: item.url,
                                       output: outputURL, message: "当前照片已完整保存并记录；后续项目已取消"))
                }

            case .failure(let error as AtelierError) where isCancellation(error):
                summary.cancelled = true
                manifest.cancelled = true
                manifest.entries.append(BatchManifestEntry(input: item.relativePath, output: nil,
                                                            status: "cancelled", message: error.localizedDescription,
                                                            report: nil))
                try updateManifestOrThrow(manifest, at: manifestURL)
                onEvent(BatchEvent(kind: .cancelled, index: offset, total: items.count, input: item.url,
                                   message: error.localizedDescription))
                break

            case .failure(let error):
                summary.failed += 1
                let message = error.localizedDescription
                manifest.entries.append(BatchManifestEntry(input: item.relativePath, output: nil,
                                                            status: "failed", message: message, report: nil))
                try updateManifestOrThrow(manifest, at: manifestURL)
                onEvent(BatchEvent(kind: .failed, index: index, total: items.count, input: item.url,
                                   message: message))
            }

            if summary.cancelled { break }
        }

        if let deliverySettings = effectiveDeliverySettings {
            if summary.cancelled {
                manifest.warnings.append("客户交付页未生成：批次已取消（已导出的照片仍保留）。")
            } else if deliveredFileURLs.isEmpty {
                manifest.warnings.append("客户交付页未生成：本次没有成功导出的照片。")
            } else {
                do {
                    let directory = try uniqueDirectoryURL(named: "delivery", under: output)
                    let result = try DeliveryGalleryWriter.write(fileURLs: deliveredFileURLs,
                                                                 settings: deliverySettings,
                                                                 outputDirectory: directory,
                                                                 context: engine.context)
                    manifest.deliveryPage = BatchDeliveryPageRecord(
                        directory: relativePath(of: directory, under: output) ?? directory.lastPathComponent,
                        html: relativePath(of: result.indexHTMLURL, under: output) ?? result.indexHTMLURL.lastPathComponent,
                        contactSheet: result.contactSheetURL.flatMap { relativePath(of: $0, under: output) },
                        photoCount: result.photoCount,
                        settings: deliverySettings
                    )
                } catch {
                    // The exported photos and the manifest are still valid; record
                    // the failure instead of discarding successful per-photo work.
                    manifest.warnings.append("客户交付页生成失败：\(error.localizedDescription)")
                }
            }
        }

        do {
            try updateManifest(manifest, at: manifestURL)
        } catch {
            throw AtelierError.imageWrite("无法保存批次最终状态：\(error.localizedDescription)")
        }
        onEvent(BatchEvent(kind: .finished, index: summary.succeeded + summary.failed, total: items.count,
                           message: summary.cancelled ? "批次已取消" : "批次完成"))
        return summary
    }
}

private enum ItemOutcome {
    case success(output: URL, report: ProcessingReport, watermarkFreeOutput: URL?)
    case failure(Error)
}

private struct BatchManifest: Codable {
    var version: Int
    var runID: String
    var createdAt: String
    var recipe: Recipe
    /// Human-readable record of the actual export parameters used by this run
    /// (the full settings are also embedded in `recipe`).
    var exportSummary: [String]
    var warnings: [String]
    var cancelled: Bool
    var entries: [BatchManifestEntry]
    /// Customer delivery page generated for this run (v4). Nil when the recipe
    /// did not request one or when a cancelled/failed run produced no page.
    var deliveryPage: BatchDeliveryPageRecord? = nil
}

/// Manifest record of the generated offline customer delivery page. Paths are
/// relative to the output root (never absolute local paths) and `settings` is the
/// effective settings actually used, so a delivery can be audited/replayed.
private struct BatchDeliveryPageRecord: Codable {
    var directory: String
    var html: String
    var contactSheet: String?
    var photoCount: Int
    var settings: DeliverySettings
}

private struct BatchManifestEntry: Codable {
    var input: String
    var output: String?
    var status: String
    var message: String
    var report: ProcessingReport?
    /// True when the primary output has the watermark composited in; nil when no
    /// watermark was active for this run.
    var watermarkApplied: Bool? = nil
    /// Relative path of the watermark-free copy produced by the dual-version
    /// switch (nil when the switch is off or no watermark is active).
    var watermarkFreeOutput: String? = nil
}

private func validateRecipe(_ recipe: Recipe) throws {
    try recipe.validateVersion()
    guard recipe.export.jpegQuality.isFinite, (0...1).contains(recipe.export.jpegQuality) else {
        throw AtelierError.invalidConfiguration("JPEG 品质必须在 0 到 1 之间")
    }
    guard recipe.export.suffix.count <= 80,
          !recipe.export.suffix.contains("/"), !recipe.export.suffix.contains("\\"),
          !recipe.export.suffix.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw AtelierError.invalidConfiguration("导出后缀包含无效字符或过长")
    }
    try validateExportExtensions(recipe.export)
    if let path = recipe.lutPath {
        guard !path.isEmpty, path.utf8.count <= 4_096 else {
            throw AtelierError.invalidConfiguration("配方 LUT 路径为空或过长")
        }
    }
    if let identifier = recipe.lutIdentifier {
        guard !identifier.isEmpty, identifier.count <= 128 else {
            throw AtelierError.invalidConfiguration("配方 LUT 标识符为空或过长")
        }
    }
}

private func validateExportExtensions(_ settings: ExportSettings) throws {
    if let resize = settings.resize, !resize.isNeutral {
        switch resize.mode {
        case .none:
            break
        case .longEdge:
            guard (16...32_768).contains(resize.longEdge) else {
                throw AtelierError.invalidConfiguration("导出长边必须是 16 到 32768 像素")
            }
        case .percent:
            guard resize.percent.isFinite, (1...400).contains(resize.percent) else {
                throw AtelierError.invalidConfiguration("导出尺寸百分比必须在 1 到 400 之间")
            }
        }
    }
    if let template = settings.fileNameTemplate {
        try validateFileNameTemplate(template)
    }
    // Structural watermark validation here (text non-empty / image path present,
    // numeric ranges) runs before the output directory is created. Missing or
    // undecodable watermark image files still surface per photo from the renderer
    // so one bad path does not abort the whole batch.
    if let watermark = settings.watermark {
        try watermark.validate()
    }
    // The delivery page is a whole-run artefact: validate it before creating the
    // output directory too (empty title, invalid column/size ranges).
    if let delivery = settings.deliveryPage {
        try delivery.validate()
    }
}

/// Only the three documented tokens are accepted; unknown placeholders would
/// otherwise leak literal braces into file names.
private func validateFileNameTemplate(_ template: String) throws {
    guard !template.isEmpty, template.count <= 120 else {
        throw AtelierError.invalidConfiguration("文件名模板不能为空，且不能超过 120 个字符")
    }
    guard !template.contains("/"), !template.contains("\\") else {
        throw AtelierError.invalidConfiguration("文件名模板不能包含路径分隔符")
    }
    guard !template.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw AtelierError.invalidConfiguration("文件名模板包含控制字符")
    }
    var remaining = template
    for token in ["{name}", "{suffix}", "{index}"] {
        remaining = remaining.replacingOccurrences(of: token, with: "")
    }
    guard !remaining.contains("{"), !remaining.contains("}") else {
        throw AtelierError.invalidConfiguration("文件名模板只支持 {name}、{suffix}、{index} 占位符")
    }
}

private func expandFileNameTemplate(_ template: String, name: String, suffix: String,
                                    index: Int) throws -> String {
    var expanded = template
        .replacingOccurrences(of: "{name}", with: name)
        .replacingOccurrences(of: "{suffix}", with: suffix)
        .replacingOccurrences(of: "{index}", with: String(index))
    guard !expanded.isEmpty, expanded != ".", expanded != "..", !expanded.hasPrefix("."),
          expanded.count <= 200, !expanded.contains("/"), !expanded.contains("\\") else {
        throw AtelierError.invalidConfiguration("文件名模板展开后无效：\(expanded)")
    }
    return expanded
}

private func describeExportSettings(_ settings: ExportSettings) -> [String] {
    var summary = ["format=\(settings.format.rawValue)",
                   "colorSpace=\(settings.colorSpace.rawValue)",
                   "suffix=\(settings.suffix)"]
    if let resize = settings.resize, !resize.isNeutral {
        switch resize.mode {
        case .none: summary.append("resize=none")
        case .longEdge: summary.append("resize=longEdge:\(resize.longEdge)")
        case .percent: summary.append("resize=percent:\(resize.percent)")
        }
    } else {
        summary.append("resize=none")
    }
    if let template = settings.fileNameTemplate {
        summary.append("fileNameTemplate=\(template)")
    }
    summary.append("stripMetadata=\(settings.stripMetadata)")
    if settings.format == .jpeg || settings.format == .heic {
        summary.append("quality=\(settings.jpegQuality)")
    }
    // Actual watermark parameters of this run, so a manifest can be audited
    // without decoding the embedded recipe.
    if let watermark = settings.watermark {
        summary.append("watermark=\(watermark.kind.rawValue)")
        summary.append("watermarkAnchor=\(watermark.anchor.rawValue)")
        summary.append("watermarkOpacity=\(watermark.opacity)")
        summary.append("watermarkScale=\(watermark.scale)")
        summary.append("watermarkRotation=\(watermark.rotationDegrees)")
        switch watermark.kind {
        case .text:
            summary.append("watermarkText=\(watermark.text)")
        case .image:
            summary.append("watermarkImage=\(watermark.imagePath ?? "")")
        }
    } else {
        summary.append("watermark=none")
    }
    summary.append("watermarkDualVersion=\(settings.exportsDualWatermarkVersion)")
    if let delivery = settings.deliveryPage {
        summary.append("deliveryPage=on")
        summary.append("deliveryTitle=\(delivery.title)")
        summary.append("deliveryColumns=\(delivery.columnCount)")
        summary.append("deliveryThumbnail=\(delivery.thumbnailMaxDimension)")
        summary.append("deliveryPreview=\(delivery.previewMaxDimension)")
        summary.append("deliveryContactSheet=\(delivery.includeContactSheet)")
        summary.append("deliveryPaper=\(delivery.paper.rawValue)")
        summary.append("deliveryWatermarkedPreviews=\(delivery.watermarkedPreviews)")
    } else {
        summary.append("deliveryPage=off")
    }
    return summary
}

/// Creates a new, never-overwriting delivery-page directory under the output
/// root. Uses the same symlink/path safety checks as per-photo output folders.
private func uniqueDirectoryURL(named baseName: String, under root: URL) throws -> URL {
    for index in 1...10_000 {
        let name = index == 1 ? baseName : "\(baseName)-\(index)"
        let candidate = root.appendingPathComponent(name, isDirectory: true)
        guard !pathEntryExists(candidate) else { continue }
        try ensureSafeDirectory(candidate, under: root)
        return candidate
    }
    throw AtelierError.imageWrite("无法找到未占用的交付页目录名")
}

/// Base URL for the watermark-free copy of the dual-version batch switch.
/// `_nowatermark` is appended to the stem so the existing unique-name loop and
/// no-overwrite semantics apply to the extra file as well.
private func noWatermarkBaseURL(from url: URL) -> URL {
    let fileName = url.lastPathComponent as NSString
    let extensionPart = fileName.pathExtension
    let stem = extensionPart.isEmpty ? url.lastPathComponent : fileName.deletingPathExtension
    let name = extensionPart.isEmpty ? "\(stem)_nowatermark" : "\(stem)_nowatermark.\(extensionPart)"
    return url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
}

private func validateRecipeLUT(_ recipe: Recipe, supplied: LUTCube?) throws {
    let hasReference = recipe.lutPath != nil || recipe.lutIdentifier != nil
    guard let supplied else {
        if hasReference { throw AtelierError.invalidConfiguration("配方指定了 LUT，但当前没有可用的 LUT") }
        return
    }
    guard isFiniteCube(supplied) else { throw AtelierError.invalidConfiguration("传入的 LUT 数据包含无效数值") }

    if let path = recipe.lutPath {
        guard !path.isEmpty else { throw AtelierError.invalidConfiguration("配方 LUT 路径为空") }
        let referenceURL = URL(fileURLWithPath: path)
        let loaded: LUTCube
        do {
            loaded = try LUTCube.load(url: referenceURL)
        } catch {
            throw AtelierError.invalidConfiguration("无法加载配方指定的 LUT：\(error.localizedDescription)")
        }
        guard cubesMatch(loaded, supplied) else {
            throw AtelierError.invalidConfiguration("传入的 LUT 与配方文件不一致")
        }
    }

    if let identifier = recipe.lutIdentifier {
        guard !identifier.isEmpty,
              let preset = LUTCube.builtIns.first(where: { $0.id == identifier }) ?? FilmLUTCatalog.preset(id: identifier) else {
            throw AtelierError.invalidConfiguration("配方引用了未知的内置 LUT：\(identifier)")
        }
        guard cubesMatch(preset.cube, supplied) else {
            throw AtelierError.invalidConfiguration("传入的 LUT 与配方内置标识符不一致")
        }
    }
}

private func cubesMatch(_ lhs: LUTCube, _ rhs: LUTCube) -> Bool {
    guard lhs.size == rhs.size, lhs.rgba.count == rhs.rgba.count,
          lhs.domainMin == rhs.domainMin, lhs.domainMax == rhs.domainMax else { return false }
    return zip(lhs.rgba, rhs.rgba).allSatisfy { abs($0 - $1) <= 0.000_001 }
}

private func isFiniteCube(_ cube: LUTCube) -> Bool {
    cube.rgba.allSatisfy(\.isFinite) && cube.domainMin.x.isFinite && cube.domainMin.y.isFinite &&
    cube.domainMin.z.isFinite && cube.domainMax.x.isFinite && cube.domainMax.y.isFinite && cube.domainMax.z.isFinite
}

private func canonicalDirectory(_ url: URL, create: Bool, label: String) throws -> URL {
    guard url.isFileURL else { throw AtelierError.invalidConfiguration("\(label)必须是本地路径") }
    if create {
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { throw AtelierError.imageWrite("无法创建\(label)：\(error.localizedDescription)") }
    }
    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw AtelierError.invalidConfiguration("\(label)不存在或不是文件夹：\(url.path)")
    }
    return resolved
}

private func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
    pathContains(lhs.path, rhs.path) || pathContains(rhs.path, lhs.path)
}

private struct DirectoryIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

/// Also catches case-insensitive filesystem aliases before creating an output
/// folder. The nearest existing output ancestor is compared to the input inode.
private func directoriesOverlap(_ input: URL, _ outputCandidate: URL) -> Bool {
    if pathsOverlap(input, outputCandidate) { return true }
    guard let inputIdentity = directoryIdentity(input.path) else { return false }
    if ancestorPaths(of: outputCandidate.path).contains(where: { directoryIdentity($0) == inputIdentity }) {
        return true
    }

    var outputIsDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: outputCandidate.path, isDirectory: &outputIsDirectory),
       outputIsDirectory.boolValue,
       let outputIdentity = directoryIdentity(outputCandidate.path) {
        return ancestorPaths(of: input.path).contains(where: { directoryIdentity($0) == outputIdentity })
    }
    return false
}

private func directoryIdentity(_ path: String) -> DirectoryIdentity? {
    var info = stat()
    let result = path.withCString { Darwin.lstat($0, &info) }
    guard result == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
    return DirectoryIdentity(device: info.st_dev, inode: info.st_ino)
}

private func ancestorPaths(of path: String) -> [String] {
    var result: [String] = []
    var current = URL(fileURLWithPath: path).standardizedFileURL.path
    while true {
        result.append(current)
        // Foundation URL deletingLastPathComponent turns "/" into "/.." on
        // macOS 13. Stop at the filesystem root rather than growing forever.
        if current == "/" { break }
        let parent = (current as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == current { break }
        current = parent
    }
    return result
}

private func pathContains(_ parent: String, _ child: String) -> Bool {
    if parent == child { return true }
    let prefix = parent.hasSuffix("/") ? parent : parent + "/"
    return child.hasPrefix(prefix)
}

private func validateInput(_ item: PhotoItem, under root: URL) throws -> URL {
    let url = item.url.standardizedFileURL
    guard url.isFileURL, pathContains(root.path, url.path), url.path != root.path else {
        throw AtelierError.imageRead("输入路径不在所选源目录内")
    }
    guard safeRelativeComponents(item.relativePath) != nil else {
        throw AtelierError.imageRead("输入相对路径无效")
    }
    let resolved = url.resolvingSymlinksInPath()
    guard pathContains(root.path, resolved.path) else {
        throw AtelierError.imageRead("输入符号链接指向源目录之外")
    }
    try rejectSymlinkComponents(url, under: root)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
        throw AtelierError.imageRead("输入不是普通照片文件")
    }
    return url
}

private func rejectSymlinkComponents(_ url: URL, under root: URL) throws {
    let relative = String(url.path.dropFirst(root.path.hasSuffix("/") ? root.path.count : root.path.count + 1))
    var cursor = root
    for component in relative.split(separator: "/") {
        cursor.appendPathComponent(String(component))
        let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true { throw AtelierError.imageRead("拒绝处理符号链接输入") }
    }
}

private func safeRelativeComponents(_ path: String) -> [String]? {
    guard !path.isEmpty, path.utf8.count <= 4_096, !path.hasPrefix("/"),
          !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
    return components
}

private func makeOutputBaseURL(for relativePath: String, under root: URL,
                               settings: ExportSettings, index: Int) throws -> URL {
    guard let components = safeRelativeComponents(relativePath), let fileName = components.last else {
        throw AtelierError.invalidConfiguration("输出相对路径无效")
    }
    var directory = root
    for component in components.dropLast() {
        directory.appendPathComponent(component, isDirectory: true)
        try ensureSafeDirectory(directory, under: root)
    }

    let original = fileName as NSString
    let extensionPart = original.pathExtension
    let stem = extensionPart.isEmpty ? fileName : original.deletingPathExtension
    let baseName: String
    if let template = settings.fileNameTemplate {
        baseName = try expandFileNameTemplate(template, name: stem, suffix: settings.suffix, index: index)
    } else {
        baseName = stem + settings.suffix
    }
    let outputName = baseName + "." + settings.format.fileExtension
    let result = directory.appendingPathComponent(outputName, isDirectory: false).standardizedFileURL
    guard pathContains(root.path, result.path), result.path != root.path else {
        throw AtelierError.invalidConfiguration("生成的输出路径超出目标目录")
    }
    return result
}

private func ensureSafeDirectory(_ directory: URL, under root: URL) throws {
    guard pathContains(root.path, directory.path) else { throw AtelierError.invalidConfiguration("输出子目录超出目标目录") }
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true, isDirectory.boolValue,
              pathContains(root.path, directory.resolvingSymlinksInPath().path) else {
            throw AtelierError.imageWrite("输出子目录不是安全的普通文件夹")
        }
    } else {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        catch { throw AtelierError.imageWrite("无法创建输出子目录：\(error.localizedDescription)") }
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true,
              pathContains(root.path, directory.resolvingSymlinksInPath().path) else {
            throw AtelierError.imageWrite("新建输出子目录解析后超出目标目录")
        }
    }
}

private func writeUnique(
    image: CIImage,
    baseURL: URL,
    settings: ExportSettings,
    sourceProperties: [String: Any],
    context: CIContext,
    cancellation: CancellationToken
) throws -> URL {
    let fileName = baseURL.lastPathComponent as NSString
    let extensionPart = fileName.pathExtension
    let stem = extensionPart.isEmpty ? baseURL.lastPathComponent : fileName.deletingPathExtension
    for index in 1...10_000 {
        try cancellation.check()
        let name = index == 1 ? "\(stem).\(extensionPart)" : "\(stem)_\(index).\(extensionPart)"
        let candidate = baseURL.deletingLastPathComponent().appendingPathComponent(name)
        guard !pathEntryExists(candidate) else { continue }
        do {
            try PhotoExporter.write(image: image, to: candidate, settings: settings,
                                    sourceProperties: sourceProperties, context: context)
            return candidate
        } catch {
            if pathEntryExists(candidate) { continue }
            throw error
        }
    }
    throw AtelierError.imageWrite("无法找到未占用的输出文件名")
}

private func pathEntryExists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

private func relativePath(of url: URL, under root: URL) -> String? {
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard url.path.hasPrefix(prefix) else { return nil }
    return String(url.path.dropFirst(prefix.count))
}

private func isCancellation(_ error: AtelierError) -> Bool {
    if case .cancelled = error { return true }
    return false
}

private func updateManifestOrThrow(_ manifest: BatchManifest, at url: URL) throws {
    do { try updateManifest(manifest, at: url) }
    catch { throw AtelierError.imageWrite("无法保存批次结果清单：\(error.localizedDescription)") }
}

private func createManifest(_ manifest: BatchManifest, at url: URL) throws {
    let data = try encodeManifest(manifest)
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    defer { _ = unlink(temporary.path) }
    try data.write(to: temporary, options: .atomic)
    let installResult = temporary.path.withCString { sourcePath in
        url.path.withCString { destinationPath in
            Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
        }
    }
    guard installResult == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func updateManifest(_ manifest: BatchManifest, at url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true else { throw AtelierError.imageWrite("批次清单路径被替换为符号链接") }
    let data = try encodeManifest(manifest)
    try data.write(to: url, options: .atomic)
}

private func encodeManifest(_ manifest: BatchManifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(manifest)
}

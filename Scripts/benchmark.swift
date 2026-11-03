// Performance benchmark for the local Photo Atelier processing pipeline.
//
// Boundaries (do not overstate these numbers):
// - The corpus is generated synthetic imagery, not real photographs. These are
//   pipeline timings, not a real-photo quality or aesthetic acceptance.
// - Timings are machine-specific and load-dependent; this script records numbers
//   only. It does not fail on a timing threshold. The first run establishes the
//   local reference; comparing against a fixed "expected" value would be fake
//   precision on a shared developer machine.
// - "Preview first frame" is a headless proxy for the app's preview pipeline
//   (decode -> scale to 1500 px long edge -> RGBAh bake -> PhotoEngine.process ->
//   RGBA8 render). It does not measure SwiftUI/AppKit drawing or UI thread cost.
// - RSS is process-wide. Peak RSS includes synthetic corpus generation, which
//   happens in the same process; phase RSS samples are recorded separately.
// - Batch export runs the real BatchProcessor over the corpus, but not the app's
//   UI batch bar; cancellation and progress UI are out of scope here.
//
// Compile against already-built PhotoCore objects (same approach as
// docs/adaptive-detail.md:62). From the repository root:
//   swift build -j 2
//   BIN="$(swift build --show-bin-path)"   # e.g. .build/x86_64-apple-macosx/debug
//   swiftc -I "$BIN" -I "$BIN/CLensfunBridge.build" Scripts/benchmark.swift \
//     "$BIN"/PhotoCore.build/*.o "$BIN"/CLensfunBridge.build/CLensfunBridge.c.o \
//     -o artifacts/p0-20261103/benchmark/benchmark
//   artifacts/p0-20261103/benchmark/benchmark [OUTPUT_JSON] [WORK_DIR]
// The object layout is SwiftPM's standard debug layout; --show-bin-path keeps the
// command portable across architectures and custom scratch directories.
//
// Output defaults to artifacts/p0-20261103/benchmark/benchmark.json and all
// generated inputs/exports stay under artifacts/ (gitignored). Input photographs
// outside the synthetic corpus are never read.

import CoreGraphics
import CoreImage
import CryptoKit
import Darwin
import Foundation
import ImageIO
import PhotoCore
import UniformTypeIdentifiers

// MARK: - Arguments and paths

let arguments = CommandLine.arguments
let manager = FileManager.default
let root = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true)
guard manager.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else {
    FileHandle.standardError.write(Data("benchmark: run from the repository root (Package.swift not found in \(root.path))\n".utf8))
    exit(2)
}
let outputURL = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "artifacts/p0-20261103/benchmark/benchmark.json")
let workRoot = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "artifacts/p0-20261103/benchmark", isDirectory: true)
let corpusRoot = workRoot.appendingPathComponent("corpus", isDirectory: true)
let runStamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
let exportRoot = workRoot.appendingPathComponent("export-\(runStamp)", isDirectory: true)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("benchmark: \(message)\n".utf8))
    exit(1)
}

// MARK: - Timing and memory helpers

func milliseconds(since start: CFAbsoluteTime) -> Double {
    ((CFAbsoluteTimeGetCurrent() - start) * 1000 * 1000).rounded() / 1000
}
struct BasicMemory {
    let residentBytes: UInt64
}

func currentMemory() -> BasicMemory {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    let resident = result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    return BasicMemory(residentBytes: resident)
}

func peakResidentBytes() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    // On macOS ru_maxrss is reported in bytes.
    return UInt64(max(0, usage.ru_maxrss))
}

// MARK: - Synthetic corpus

struct CorpusSpec {
    let longEdge: Int
    let format: String  // "jpeg", "png", "heic"
    var height: Int { max(1, longEdge * 2 / 3) }
    var filename: String {
        let ext = format == "jpeg" ? "jpg" : format
        return "synthetic_\(longEdge).\(ext)"
    }
    var displayName: String { "\(format.uppercased()) \(longEdge)px" }
}

let corpusSpecs: [CorpusSpec] = [1024, 4032, 8192].flatMap { edge in
    ["jpeg", "png", "heic"].map { CorpusSpec(longEdge: edge, format: $0) }
}

func drawFixture(into context: CGContext, width: Int, height: Int) {
    // Deterministic synthetic scene: sky gradient, sun, layered hills and a
    // colour-patch row. Content is irrelevant to timing; determinism is.
    let w = CGFloat(width), h = CGFloat(height)
    let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                         colors: [CGColor(srgbRed: 0.16, green: 0.27, blue: 0.36, alpha: 1),
                                  CGColor(srgbRed: 0.82, green: 0.72, blue: 0.54, alpha: 1)] as CFArray,
                         locations: [0, 1])!
    context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: .zero, options: [])
    context.setFillColor(CGColor(srgbRed: 0.98, green: 0.84, blue: 0.59, alpha: 1))
    context.fillEllipse(in: CGRect(x: w * 0.68, y: h * 0.66, width: w * 0.09, height: w * 0.09))
    for layer in 0..<4 {
        let path = CGMutablePath()
        path.move(to: .zero)
        let step = max(1, width / 160)
        for x in stride(from: 0, through: width, by: step) {
            let fx = CGFloat(x) / w
            let y = h * (0.52 - CGFloat(layer) * 0.09) + sin(fx * 9 + CGFloat(layer)) * h * (0.09 - CGFloat(layer) * 0.008)
            path.addLine(to: CGPoint(x: CGFloat(x), y: y))
        }
        path.addLine(to: CGPoint(x: w, y: 0))
        path.closeSubpath()
        context.setFillColor(CGColor(srgbRed: 0.25 - CGFloat(layer) * 0.035,
                                     green: 0.38 - CGFloat(layer) * 0.05,
                                     blue: 0.40 - CGFloat(layer) * 0.05, alpha: 1))
        context.addPath(path)
        context.fillPath()
    }
    let patches: [[CGFloat]] = [
        [0.45, 0.29, 0.23], [0.76, 0.58, 0.50], [0.36, 0.48, 0.61],
        [0.36, 0.43, 0.24], [0.51, 0.51, 0.68], [0.38, 0.74, 0.67],
        [0.86, 0.48, 0.16], [0.28, 0.35, 0.68], [0.75, 0.30, 0.36],
        [0.95, 0.95, 0.95], [0.46, 0.46, 0.46], [0.12, 0.12, 0.12],
    ]
    let patchSide = w * 0.045
    for (index, patch) in patches.enumerated() {
        context.setFillColor(CGColor(srgbRed: patch[0], green: patch[1], blue: patch[2], alpha: 1))
        context.fill(CGRect(x: w * 0.05 + CGFloat(index) * patchSide * 1.12,
                            y: h * 0.06, width: patchSide, height: patchSide))
    }
}

func writeFixture(_ spec: CorpusSpec, to url: URL) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: spec.longEdge, height: spec.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw AtelierError.imageWrite("无法创建合成语料位图：\(spec.filename)")
    }
    drawFixture(into: context, width: spec.longEdge, height: spec.height)
    guard let image = context.makeImage() else {
        throw AtelierError.imageWrite("无法生成合成语料图像：\(spec.filename)")
    }
    let type: CFString
    switch spec.format {
    case "jpeg": type = UTType.jpeg.identifier as CFString
    case "png": type = UTType.png.identifier as CFString
    case "heic": type = UTType.heic.identifier as CFString
    default: throw AtelierError.imageWrite("未知合成语料格式：\(spec.format)")
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
        throw AtelierError.imageWrite("ImageIO 无法创建 \(spec.format) 输出：\(spec.filename)")
    }
    var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
    if spec.format == "jpeg" { properties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw AtelierError.imageWrite("ImageIO 无法编码合成语料：\(spec.filename)")
    }
}

func fileSize(_ url: URL) -> Int {
    (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
}

func sha256(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Benchmark settings and rendering proxy

// A fixed, non-neutral set so the preview/batch phases exercise real processing
// rather than a short-circuit. All values are inside PhotoEngine.validate ranges.
func benchmarkSettings() -> AdjustmentSettings {
    var settings = AdjustmentSettings()
    settings.exposureEV = 0.25
    settings.temperature = 0.08
    settings.contrast = 1.08
    settings.saturation = 1.06
    settings.highlights = -0.1
    settings.shadows = 0.1
    return settings
}

func previewProxy(_ loaded: LoadedPhoto, engine: PhotoEngine, settings: AdjustmentSettings) throws -> CGImage {
    let extent = loaded.image.extent
    let scale = min(1, 1500 / max(extent.width, extent.height))
    let scaled = loaded.image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let working = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    // Mirrors PreviewRaster.make in the app: own the pixel bytes before AppKit.
    guard let baked = engine.context.createCGImage(scaled, from: scaled.extent.integral, format: .RGBAh,
                                                   colorSpace: working, deferred: false) else {
        throw AtelierError.imageRead("预览代理烘焙失败")
    }
    let processed = try engine.process(CIImage(cgImage: baked), settings: settings, lut: nil)
    let outputBounds = processed.image.extent.integral
    guard let rendered = engine.context.createCGImage(processed.image, from: outputBounds, format: .RGBA8,
                                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                                      deferred: false) else {
        throw AtelierError.imageRead("预览代理渲染失败")
    }
    return rendered
}

// MARK: - Run

var phaseRows: [String: Any] = [:]
var corpusRows: [[String: Any]] = []
var failures: [String] = []
let processStart = CFAbsoluteTimeGetCurrent()

do {
    try manager.createDirectory(at: workRoot, withIntermediateDirectories: true)
    try manager.createDirectory(at: corpusRoot, withIntermediateDirectories: true)

    // 1. Synthetic corpus generation.
    let generationStart = CFAbsoluteTimeGetCurrent()
    for spec in corpusSpecs {
        let url = corpusRoot.appendingPathComponent(spec.filename)
        try writeFixture(spec, to: url)
    }
    let generationMS = milliseconds(since: generationStart)
    let rssAfterGeneration = currentMemory().residentBytes
    var corpusBytes = 0
    for spec in corpusSpecs {
        let url = corpusRoot.appendingPathComponent(spec.filename)
        let size = fileSize(url)
        corpusBytes += size
        guard size > 0 else { fail("synthetic fixture is empty: \(spec.filename)") }
        corpusRows.append([
            "file": spec.filename,
            "format": spec.format,
            "longEdge": spec.longEdge,
            "bytes": size,
        ])
    }
    phaseRows["corpusGeneration"] = [
        "images": corpusSpecs.count,
        "totalBytes": corpusBytes,
        "milliseconds": generationMS,
    ] as [String: Any]

    // 2. Import: decode each synthetic photo through the app's loader.
    let importStart = CFAbsoluteTimeGetCurrent()
    var importRows: [[String: Any]] = []
    var importedCount = 0
    for spec in corpusSpecs {
        let url = corpusRoot.appendingPathComponent(spec.filename)
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let loaded = try PhotoLoader.load(url: url, lensCorrection: false)
            let loadMS = milliseconds(since: start)
            let width = Int(loaded.image.extent.width.rounded())
            let height = Int(loaded.image.extent.height.rounded())
            // The app's import path also builds a library thumbnail; thumbnail
            // decoding forces the pixels, so the import number is not a lazy
            // CIImage wrapper measurement.
            let thumbnailStart = CFAbsoluteTimeGetCurrent()
            _ = try PhotoLoader.thumbnail(url: url, maxDimension: 512)
            let thumbnailMS = milliseconds(since: thumbnailStart)
            importedCount += 1
            importRows.append([
                "file": spec.filename,
                "milliseconds": loadMS + thumbnailMS,
                "loadMilliseconds": loadMS,
                "thumbnailMilliseconds": thumbnailMS,
                "width": width,
                "height": height,
                "sourceColorSpace": loaded.report.sourceColorSpace,
            ])
            if width <= 0 || height <= 0 {
                failures.append("import produced an empty extent: \(spec.filename)")
            }
        } catch {
            failures.append("import failed for \(spec.filename): \(error.localizedDescription)")
            importRows.append(["file": spec.filename, "error": error.localizedDescription])
        }
    }
    let importMS = milliseconds(since: importStart)
    phaseRows["import"] = [
        "milliseconds": importMS,
        "perImage": importRows,
        "rssAfterBytes": currentMemory().residentBytes,
        "note": "load + 512px thumbnail (the app's import path also builds a library thumbnail)",
    ] as [String: Any]

    // 3. Analysis: PhotoAnalyzer on every fixture (first call includes Vision init).
    let analysisStart = CFAbsoluteTimeGetCurrent()
    let analyzer = PhotoAnalyzer()
    var analysisRows: [[String: Any]] = []
    var analyzedCount = 0
    for spec in corpusSpecs {
        let url = corpusRoot.appendingPathComponent(spec.filename)
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let loaded = try PhotoLoader.load(url: url, lensCorrection: false)
            let analysis = try analyzer.analyze(image: loaded.image, properties: loaded.properties, sourceURL: url)
            analyzedCount += 1
            analysisRows.append([
                "file": spec.filename,
                "milliseconds": milliseconds(since: start),
                "sampleWidth": analysis.metrics.sampleWidth,
                "sampleHeight": analysis.metrics.sampleHeight,
                "faceCount": analysis.metrics.faceCount,
                "proposals": analysis.proposals.count,
            ])
        } catch {
            failures.append("analysis failed for \(spec.filename): \(error.localizedDescription)")
            analysisRows.append(["file": spec.filename, "error": error.localizedDescription])
        }
    }
    let analysisMS = milliseconds(since: analysisStart)
    phaseRows["analysis"] = [
        "milliseconds": analysisMS,
        "perImage": analysisRows,
        "rssAfterBytes": currentMemory().residentBytes,
    ] as [String: Any]

    // 4. Preview first frame (headless proxy; see header boundaries).
    let previewStart = CFAbsoluteTimeGetCurrent()
    let engine = PhotoEngine()
    let settings = benchmarkSettings()
    var previewRows: [[String: Any]] = []
    var previewedCount = 0
    for spec in corpusSpecs {
        let url = corpusRoot.appendingPathComponent(spec.filename)
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let loaded = try PhotoLoader.load(url: url, lensCorrection: false)
            let rendered = try previewProxy(loaded, engine: engine, settings: settings)
            previewedCount += 1
            previewRows.append([
                "file": spec.filename,
                "milliseconds": milliseconds(since: start),
                "previewWidth": rendered.width,
                "previewHeight": rendered.height,
            ])
        } catch {
            failures.append("preview proxy failed for \(spec.filename): \(error.localizedDescription)")
            previewRows.append(["file": spec.filename, "error": error.localizedDescription])
        }
    }
    let previewMS = milliseconds(since: previewStart)
    phaseRows["previewFirstFrame"] = [
        "milliseconds": previewMS,
        "perImage": previewRows,
        "rssAfterBytes": currentMemory().residentBytes,
        "note": "headless decode -> 1500px bake -> PhotoEngine.process -> RGBA8 render; not SwiftUI drawing",
    ] as [String: Any]

    // 5. Batch export through the real BatchProcessor, with input hashes checked.
    var beforeHashes: [String: String] = [:]
    for spec in corpusSpecs {
        let url = corpusRoot.appendingPathComponent(spec.filename)
        beforeHashes[spec.filename] = try sha256(url)
    }
    let items = try PhotoLoader.scan(folder: corpusRoot, recursive: false)
    guard items.count == corpusSpecs.count else {
        fail("corpus scan returned \(items.count) items, expected \(corpusSpecs.count)")
    }
    var recipe = Recipe()
    recipe.version = 9
    recipe.adjustments = settings
    var exportSettings = ExportSettings()
    exportSettings.format = .jpeg
    exportSettings.colorSpace = .sRGB
    exportSettings.jpegQuality = 0.9
    exportSettings.suffix = "_bench"
    recipe.export = exportSettings

    let batchStart = CFAbsoluteTimeGetCurrent()
    var batchItemRows: [[String: Any]] = []
    var itemStartedAt: [Int: CFAbsoluteTime] = [:]
    var batchSummary = BatchSummary()
    let token = CancellationToken()
    do {
        batchSummary = try BatchProcessor().run(items: items, inputRoot: corpusRoot, outputRoot: exportRoot,
                                                recipe: recipe, lut: nil, cancellation: token) { event in
            switch event.kind {
            case .processing:
                itemStartedAt[event.index] = CFAbsoluteTimeGetCurrent()
            case .completed, .failed:
                let started = itemStartedAt[event.index] ?? CFAbsoluteTimeGetCurrent()
                var row: [String: Any] = [
                    "index": event.index,
                    "milliseconds": milliseconds(since: started),
                    "input": event.input?.lastPathComponent ?? "",
                ]
                if event.kind == .failed { row["error"] = event.message }
                batchItemRows.append(row)
            default:
                break
            }
        }
    } catch {
        failures.append("batch export failed: \(error.localizedDescription)")
    }
    let batchMS = milliseconds(since: batchStart)
    let exportedFiles = (try? manager.contentsOfDirectory(at: exportRoot, includingPropertiesForKeys: [.fileSizeKey]))?
        .filter { $0.pathExtension.lowercased() == "jpg" } ?? []
    var exportedBytes = 0
    for file in exportedFiles {
        exportedBytes += fileSize(file)
    }
    var afterHashes: [String: String] = [:]
    for spec in corpusSpecs {
        let url = corpusRoot.appendingPathComponent(spec.filename)
        afterHashes[spec.filename] = try? sha256(url)
    }
    if beforeHashes != afterHashes {
        failures.append("batch export modified the synthetic inputs (hash mismatch)")
    }
    phaseRows["batchExport"] = [
        "milliseconds": batchMS,
        "succeeded": batchSummary.succeeded,
        "failed": batchSummary.failed,
        "cancelled": batchSummary.cancelled,
        "exportedFiles": exportedFiles.count,
        "exportedBytes": exportedBytes,
        "perImage": batchItemRows,
        "manifest": batchSummary.manifestURL?.path ?? "",
        "rssAfterBytes": currentMemory().residentBytes,
    ] as [String: Any]

    // 6. Cross-checks: every phase must have covered the full corpus.
    if importedCount != corpusSpecs.count { failures.append("import covered \(importedCount)/\(corpusSpecs.count) fixtures") }
    if analyzedCount != corpusSpecs.count { failures.append("analysis covered \(analyzedCount)/\(corpusSpecs.count) fixtures") }
    if previewedCount != corpusSpecs.count { failures.append("preview covered \(previewedCount)/\(corpusSpecs.count) fixtures") }
    if batchSummary.succeeded != corpusSpecs.count { failures.append("batch exported \(batchSummary.succeeded)/\(corpusSpecs.count) fixtures") }
    if batchSummary.failed != 0 { failures.append("batch reported \(batchSummary.failed) failures") }
    if exportedFiles.count != corpusSpecs.count { failures.append("batch produced \(exportedFiles.count) export files, expected \(corpusSpecs.count)") }

    // 7. Report.
    let peak = peakResidentBytes()
    let totalMS = milliseconds(since: processStart)
    var report: [String: Any] = [
        "schemaVersion": 1,
        "generatedAt": ISO8601DateFormatter().string(from: Date()),
        "command": arguments.joined(separator: " "),
        "workRoot": workRoot.path,
        "corpus": corpusRows,
        "phases": phaseRows,
        "memory": [
            "peakResidentBytes": peak,
            "peakResidentMB": Double(peak) / 1_048_576,
            "rssAfterGenerationBytes": rssAfterGeneration,
            "note": "peakResidentBytes is process-wide (includes synthetic corpus generation); rssAfterBytes in each phase is a sample after that phase",
        ] as [String: Any],
        "totals": [
            "milliseconds": totalMS,
            "fixtures": corpusSpecs.count,
        ] as [String: Any],
        "baselineComparison": [
            "status": "record-only",
            "reason": "first benchmark run: no historical baseline on this machine; a fixed timing threshold would be pseudo-precision",
        ] as [String: Any],
        "boundaries": [
            "synthetic fixtures only: pipeline timings are not real-photo quality or aesthetic acceptance",
            "debug PhotoCore objects (built by swift build) are linked: numbers are not release-build throughput",
            "preview is a headless proxy, not SwiftUI/AppKit drawing or UI-thread latency",
            "batch export covers BatchProcessor throughput, not the app's batch UI, progress bar or cancellation UX",
            "RSS is process-wide and includes corpus generation; timings vary with machine load",
            "HEIC encoding on this host logs AppleAVE XPC fallback messages; ImageIO still finalizes valid HEIC files (decode is verified by the import phase)",
        ],
    ]
    if !failures.isEmpty { report["failures"] = failures }
    let outputData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try manager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try outputData.write(to: outputURL, options: .atomic)

    // Human-readable summary.
    print("benchmark: \(corpusSpecs.count) synthetic fixtures (\(corpusRows.count) rows), work root \(workRoot.path)")
    for (name, value) in phaseRows.sorted(by: { $0.key < $1.key }) {
        if let row = value as? [String: Any], let ms = row["milliseconds"] as? Double {
            var line = "  \(name): \(String(format: "%.1f", ms)) ms"
            if let succeeded = row["succeeded"] as? Int {
                line += "  succeeded=\(succeeded) failed=\(row["failed"] as? Int ?? -1) files=\(row["exportedFiles"] as? Int ?? -1)"
            }
            print(line)
        }
    }
    print(String(format: "  peak RSS %.1f MB", Double(peak) / 1_048_576))
    print("  JSON: \(outputURL.path)")
    if failures.isEmpty {
        print("benchmark: PASS")
    } else {
        for failure in failures { FileHandle.standardError.write(Data("benchmark: FAILURE \(failure)\n".utf8)) }
        exit(1)
    }
} catch {
    fail("unexpected error: \(error.localizedDescription)")
}

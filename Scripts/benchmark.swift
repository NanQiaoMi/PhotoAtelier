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
// - P1 capability phases are headless probes of the real PhotoCore engines:
//   "colorToolsAndLensEffects" renders curves/HSL/grading + vignette/CA at full
//   resolution, "liquify" uses a deterministic synthetic face-landmark geometry
//   (not a detected real face) plus a manual push stroke, and "watermark" renders
//   a text watermark with the system font. They measure pipeline cost only; they
//   are not a real-photo aesthetic, face-reshaping or typography acceptance.
// - schemaVersion 2 adds those P1 phases; the P0 phases keep their old meaning.
// - P1-B phases: "mattingAndBackground" builds a matte from a synthetic radial
//   gradient mask (NOT a Vision-detected person), then runs the real
//   BackgroundReplacement + IDPhotoLayout engines at full resolution;
//   "repairBrush" applies fixed heal+clone strokes with the real
//   RepairBrushEngine; "deliveryPage" writes a real static HTML album plus
//   contact-sheet PDF through DeliveryGalleryWriter (local file IO, disk-bound).
//   These are pipeline cost probes, not matting/retouch/print acceptance.
// - schemaVersion 3 adds those P1-B phases; earlier phases keep their meaning.
//
// Compile against already-built PhotoCore objects (same approach as
// docs/adaptive-detail.md:62). From the repository root:
//   swift build -j 2
//   BIN="$(swift build --show-bin-path)"   # e.g. .build/x86_64-apple-macosx/debug
//   swiftc -I "$BIN" -I "$BIN/CLensfunBridge.build" Scripts/benchmark.swift \
//     "$BIN"/PhotoCore.build/*.o "$BIN"/CLensfunBridge.build/CLensfunBridge.c.o \
//     -o artifacts/p1b-b7-verify/benchmark/benchmark
//   artifacts/p1b-b7-verify/benchmark/benchmark [OUTPUT_JSON] [WORK_DIR]
// The object layout is SwiftPM's standard debug layout; --show-bin-path keeps the
// command portable across architectures and custom scratch directories.
//
// Output defaults to artifacts/p1b-b7-verify/benchmark/benchmark.json and all
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
let outputURL = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "artifacts/p1b-b7-verify/benchmark/benchmark.json")
let workRoot = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "artifacts/p1b-b7-verify/benchmark", isDirectory: true)
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

// MARK: - P1 capability probes (headless, real PhotoCore engines)

/// Forces a lazy Core Image graph to execute at full resolution so timings cover
/// real pixel work, not just graph construction.
func renderFullResolution(_ image: CIImage, engine: PhotoEngine) throws -> CGImage {
    let bounds = image.extent.integral
    guard bounds.width >= 1, bounds.height >= 1,
          bounds.width < 20_000, bounds.height < 20_000,
          bounds.minX.isFinite, bounds.minY.isFinite else {
        throw AtelierError.imageRead("P1 能力渲染范围无效")
    }
    guard let rendered = engine.context.createCGImage(image, from: bounds, format: .RGBA8,
                                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                                      deferred: false) else {
        throw AtelierError.imageRead("P1 能力全分辨率渲染失败")
    }
    return rendered
}

/// Fixed non-neutral P1 color-tool payload (curves + HSL + grading).
func benchmarkColorToolsSettings() -> ColorToolsSettings {
    var curves = ColorCurveSettings()
    curves.luminance = [CurveControlPoint(x: 0, y: 0),
                        CurveControlPoint(x: 0.5, y: 0.58),
                        CurveControlPoint(x: 1, y: 1)]
    curves.red = [CurveControlPoint(x: 0, y: 0.02),
                  CurveControlPoint(x: 1, y: 0.98)]
    var hsl = HSLSettings()
    hsl.orange.saturation = 0.25
    hsl.blue.hueShiftDegrees = 8
    var grading = ColorGradingSettings()
    grading.shadows = ColorGradingWheel(hueDegrees: 210, saturation: 0.12, luminance: -0.02)
    grading.highlights = ColorGradingWheel(hueDegrees: 40, saturation: 0.10, luminance: 0.02)
    return ColorToolsSettings(curves: curves, hsl: hsl, grading: grading)
}

/// Fixed non-neutral lens-effects payload (vignette + lateral CA).
func benchmarkLensEffectsSettings() -> LensEffectsSettings {
    LensEffectsSettings(vignetteAmount: 0.35, vignetteMidpoint: 0.5, vignetteFeather: 0.5,
                        vignetteRoundness: 1, chromaticAberrationRed: 0.2,
                        chromaticAberrationBlue: -0.15)
}

/// Deterministic synthetic face geometry in normalized coordinates (bottom-left
/// origin). This is NOT a detected real face: the liquify phase only needs a
/// plausible landmark topology to exercise the automatic face-shape warp.
func syntheticFaceLandmarks() -> FaceLandmarkSet {
    func ellipse(center: CGPoint, radiusX: Double, radiusY: Double, count: Int) -> [CGPoint] {
        (0..<count).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(count)
            return CGPoint(x: center.x + radiusX * cos(angle),
                           y: center.y + radiusY * sin(angle))
        }
    }
    let box = CGRect(x: 0.30, y: 0.22, width: 0.40, height: 0.52)
    var contour: [CGPoint] = []
    for index in 0..<20 {
        let angle = Double.pi * 0.12 + Double.pi * 1.76 * Double(index) / 19
        contour.append(CGPoint(x: box.midX + box.width * 0.5 * cos(angle),
                               y: box.midY + box.height * 0.5 * sin(angle)))
    }
    let leftEyeCenter = CGPoint(x: box.minX + box.width * 0.32, y: box.minY + box.height * 0.62)
    let rightEyeCenter = CGPoint(x: box.minX + box.width * 0.68, y: box.minY + box.height * 0.62)
    let leftEye = ellipse(center: leftEyeCenter, radiusX: box.width * 0.10,
                          radiusY: box.height * 0.05, count: 8)
    let rightEye = ellipse(center: rightEyeCenter, radiusX: box.width * 0.10,
                           radiusY: box.height * 0.05, count: 8)
    let nose = [CGPoint(x: box.midX, y: box.minY + box.height * 0.44),
                CGPoint(x: box.midX - box.width * 0.06, y: box.minY + box.height * 0.50),
                CGPoint(x: box.midX + box.width * 0.06, y: box.minY + box.height * 0.50)]
    let outerLips = ellipse(center: CGPoint(x: box.midX, y: box.minY + box.height * 0.34),
                            radiusX: box.width * 0.16, radiusY: box.height * 0.06, count: 10)
    let innerLips = ellipse(center: CGPoint(x: box.midX, y: box.minY + box.height * 0.34),
                            radiusX: box.width * 0.08, radiusY: box.height * 0.025, count: 8)
    return FaceLandmarkSet(boundingBox: box, confidence: 0.99,
                           faceContour: contour,
                           leftEye: leftEye, rightEye: rightEye,
                           leftEyebrow: [], rightEyebrow: [],
                           nose: nose, outerLips: outerLips, innerLips: innerLips,
                           leftPupil: leftEyeCenter, rightPupil: rightEyeCenter)
}

/// Fixed non-neutral face-reshape payload: preset + sliders + one manual stroke.
func benchmarkFaceReshapeSettings() -> FaceReshapeSettings {
    FaceReshapeSettings(
        preset: .classic,
        parameters: FaceReshapeParameters(slimFace: 0.4, enlargeEyes: 0.3),
        strength: 1,
        backgroundProtection: true,
        strokes: [WarpStroke(mode: .push,
                             points: [MaskPoint(x: 0.52, y: 0.42),
                                      MaskPoint(x: 0.56, y: 0.44)],
                             radius: 0.10, strength: 0.5)])
}

/// Fixed text watermark payload (system font, bottom-right anchor).
func benchmarkWatermarkSettings() -> WatermarkSettings {
    WatermarkSettings(kind: .text, text: "光屿 PHOTO · P1 BENCH",
                      anchor: .bottomRight, opacity: 0.6, scale: 1.0,
                      rotationDegrees: 0)
}

// MARK: - P1-B capability probes (headless, real PhotoCore engines)

/// Synthetic elliptical coverage mask for the matting phase (white inside, black
/// outside). This is NOT a Vision detection result: it lets the real
/// BackgroundReplacement / IDPhotoLayout pipeline run headless on synthetic
/// fixtures without pretending to measure real person segmentation.
func syntheticPersonMask(extent: CGRect) -> CIImage {
    let filter = CIFilter(name: "CIRadialGradient")!
    let shortEdge = min(extent.width, extent.height)
    filter.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: "inputCenter")
    filter.setValue(shortEdge * 0.26, forKey: "inputRadius0")
    filter.setValue(shortEdge * 0.30, forKey: "inputRadius1")
    filter.setValue(CIColor(red: 1, green: 1, blue: 1), forKey: "inputColor0")
    filter.setValue(CIColor(red: 0, green: 0, blue: 0), forKey: "inputColor1")
    return filter.outputImage!.cropped(to: extent)
}

func benchmarkBackgroundSettings() -> BackgroundReplacementSettings {
    BackgroundReplacementSettings(shadowEnabled: true, shadowOpacity: 0.35,
                                  shadowBlur: 0.15, shadowOffsetX: 0,
                                  shadowOffsetY: -0.04, edgeDecontamination: 0.6)
}

/// Fixed heal + clone strokes for the repair phase (normalized coordinates).
func benchmarkRepairStrokes() -> [RepairStroke] {
    [RepairStroke(mode: .heal,
                  points: [MaskPoint(x: 0.40, y: 0.50), MaskPoint(x: 0.46, y: 0.52)],
                  radius: 0.035, feather: 0.5, strength: 1),
     RepairStroke(mode: .clone,
                  points: [MaskPoint(x: 0.60, y: 0.48), MaskPoint(x: 0.64, y: 0.50)],
                  radius: 0.035, feather: 0.5, strength: 1,
                  cloneOffset: MaskPoint(x: 0.10, y: 0.06))]
}

func benchmarkDeliverySettings() -> DeliverySettings {
    var settings = DeliverySettings()
    settings.title = "光屿 · P1-B 基准交付"
    settings.columnCount = 3
    settings.thumbnailMaxDimension = 640
    settings.previewMaxDimension = 1600
    settings.includeContactSheet = true
    settings.contactSheetColumns = 3
    settings.paper = .a4
    return settings
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

    // 5. P1 color tools + lens effects at full resolution (headless).
    let colorToolsStart = CFAbsoluteTimeGetCurrent()
    let colorToolsSettings = benchmarkColorToolsSettings()
    let lensEffectsSettings = benchmarkLensEffectsSettings()
    var colorToolsRows: [[String: Any]] = []
    var colorToolsCount = 0
    for spec in corpusSpecs {
        let url = corpusRoot.appendingPathComponent(spec.filename)
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let loaded = try PhotoLoader.load(url: url, lensCorrection: false)
            let toolsOutput = try ColorToolsEngine.apply(colorToolsSettings, to: loaded.image)
            let lensOutput = try LensEffectsEngine.apply(lensEffectsSettings, to: toolsOutput)
            let rendered = try renderFullResolution(lensOutput, engine: engine)
            colorToolsCount += 1
            colorToolsRows.append([
                "file": spec.filename,
                "milliseconds": milliseconds(since: start),
                "width": rendered.width,
                "height": rendered.height,
            ])
        } catch {
            failures.append("color tools phase failed for \(spec.filename): \(error.localizedDescription)")
            colorToolsRows.append(["file": spec.filename, "error": error.localizedDescription])
        }
    }
    phaseRows["colorToolsAndLensEffects"] = [
        "milliseconds": milliseconds(since: colorToolsStart),
        "perImage": colorToolsRows,
        "rssAfterBytes": currentMemory().residentBytes,
        "settings": [
            "curves": "luminance + red PCHIP curves",
            "hsl": "orange saturation +0.25, blue hue +8°",
            "grading": "shadows 210°/0.12, highlights 40°/0.10",
            "lensEffects": "vignette +0.35, CA red +0.20 / blue -0.15",
        ] as [String: Any],
        "note": "headless full-resolution render of the real ColorToolsEngine + LensEffectsEngine; not an aesthetic acceptance",
    ] as [String: Any]

    // 6. Liquify / face reshape on one JPEG per corpus size (headless probe).
    let liquifyStart = CFAbsoluteTimeGetCurrent()
    let liquifySpecs = corpusSpecs.filter { $0.format == "jpeg" }
    let reshapeSettings = benchmarkFaceReshapeSettings()
    let syntheticLandmarks = syntheticFaceLandmarks()
    var liquifyRows: [[String: Any]] = []
    var liquifyCount = 0
    for spec in liquifySpecs {
        let url = corpusRoot.appendingPathComponent(spec.filename)
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let loaded = try PhotoLoader.load(url: url, lensCorrection: false)
            let output = try FaceReshapeEngine.apply(to: loaded.image,
                                                     landmarks: syntheticLandmarks,
                                                     settings: reshapeSettings)
            let rendered = try renderFullResolution(output, engine: engine)
            liquifyCount += 1
            liquifyRows.append([
                "file": spec.filename,
                "milliseconds": milliseconds(since: start),
                "width": rendered.width,
                "height": rendered.height,
            ])
        } catch {
            failures.append("liquify phase failed for \(spec.filename): \(error.localizedDescription)")
            liquifyRows.append(["file": spec.filename, "error": error.localizedDescription])
        }
    }
    phaseRows["liquify"] = [
        "milliseconds": milliseconds(since: liquifyStart),
        "perImage": liquifyRows,
        "rssAfterBytes": currentMemory().residentBytes,
        "settings": ["preset": "classic", "parameters": "slimFace 0.4, enlargeEyes 0.3",
                     "strength": 1.0, "backgroundProtection": true,
                     "manualStrokes": 1] as [String: Any],
        "note": "deterministic synthetic face-landmark geometry (not a detected real face) + one manual push stroke; one JPEG per corpus size; not a beauty acceptance",
    ] as [String: Any]

    // 7. Text watermark render at full resolution (headless probe).
    let watermarkStart = CFAbsoluteTimeGetCurrent()
    let watermarkSettings = benchmarkWatermarkSettings()
    var watermarkRows: [[String: Any]] = []
    var watermarkCount = 0
    for spec in corpusSpecs {
        let url = corpusRoot.appendingPathComponent(spec.filename)
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let loaded = try PhotoLoader.load(url: url, lensCorrection: false)
            let watermarked = try WatermarkRenderer.render(on: loaded.image,
                                                           settings: watermarkSettings)
            let rendered = try renderFullResolution(watermarked, engine: engine)
            watermarkCount += 1
            watermarkRows.append([
                "file": spec.filename,
                "milliseconds": milliseconds(since: start),
                "width": rendered.width,
                "height": rendered.height,
            ])
        } catch {
            failures.append("watermark phase failed for \(spec.filename): \(error.localizedDescription)")
            watermarkRows.append(["file": spec.filename, "error": error.localizedDescription])
        }
    }
    phaseRows["watermark"] = [
        "milliseconds": milliseconds(since: watermarkStart),
        "perImage": watermarkRows,
        "rssAfterBytes": currentMemory().residentBytes,
        "settings": ["kind": "text", "text": "光屿 PHOTO · P1 BENCH",
                     "anchor": "bottomRight", "opacity": 0.6, "scale": 1.0,
                     "rotationDegrees": 0, "font": "system"] as [String: Any],
        "note": "headless full-resolution text watermark with the system font; not a typography or real-photo acceptance",
    ] as [String: Any]

    // 8. P1-B matting + background replacement + ID-photo crop (headless).
    let mattingStart = CFAbsoluteTimeGetCurrent()
    let matteSettings = PersonMatteSettings()
    let backgroundSettings = benchmarkBackgroundSettings()
    let idPhotoSettings = IDPhotoCropSettings(size: .oneInch, dpi: 300)
    let syntheticFaceBox = CGRect(x: 0.36, y: 0.34, width: 0.28, height: 0.32)
    var mattingRows: [[String: Any]] = []
    var mattingCount = 0
    for spec in corpusSpecs {
        let url = corpusRoot.appendingPathComponent(spec.filename)
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let loaded = try PhotoLoader.load(url: url, lensCorrection: false)
            let extent = loaded.image.extent
            let mask = syntheticPersonMask(extent: extent)
            let matteStart = CFAbsoluteTimeGetCurrent()
            let matte = try PersonMatting.matte(fromMask: mask, settings: matteSettings,
                                                context: engine.context)
            let matteMS = milliseconds(since: matteStart)
            let backgroundStart = CFAbsoluteTimeGetCurrent()
            let composited = try BackgroundReplacement.apply(
                foreground: loaded.image, matte: matte,
                fill: .preset(.blue), settings: backgroundSettings)
            let backgroundMS = milliseconds(since: backgroundStart)
            let idPhotoStart = CFAbsoluteTimeGetCurrent()
            let idPhoto = try IDPhotoLayout.render(photo: composited,
                                                   faceBox: syntheticFaceBox,
                                                   settings: idPhotoSettings)
            let rendered = try renderFullResolution(idPhoto, engine: engine)
            let idPhotoMS = milliseconds(since: idPhotoStart)
            mattingCount += 1
            mattingRows.append([
                "file": spec.filename,
                "milliseconds": milliseconds(since: start),
                "matteMilliseconds": matteMS,
                "backgroundMilliseconds": backgroundMS,
                "idPhotoMilliseconds": idPhotoMS,
                "coverage": matte.coverage,
                "hasPerson": matte.hasPerson,
                "idPhotoWidth": rendered.width,
                "idPhotoHeight": rendered.height,
            ])
        } catch {
            failures.append("matting phase failed for \(spec.filename): \(error.localizedDescription)")
            mattingRows.append(["file": spec.filename, "error": error.localizedDescription])
        }
    }
    phaseRows["mattingAndBackground"] = [
        "milliseconds": milliseconds(since: mattingStart),
        "perImage": mattingRows,
        "rssAfterBytes": currentMemory().residentBytes,
        "settings": ["matte": "synthetic radial-gradient mask (not a Vision detection)",
                     "background": "standard blue preset, shadow on",
                     "idPhoto": "一寸 300DPI 295×413 crop from synthetic face box"] as [String: Any],
        "note": "headless full-resolution real BackgroundReplacement + IDPhotoLayout engines; synthetic mask, not a matting-quality acceptance",
    ] as [String: Any]

    // 9. P1-B repair brush heal + clone (headless).
    let repairStart = CFAbsoluteTimeGetCurrent()
    let repairStrokes = benchmarkRepairStrokes()
    var repairRows: [[String: Any]] = []
    var repairCount = 0
    for spec in corpusSpecs {
        let url = corpusRoot.appendingPathComponent(spec.filename)
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let loaded = try PhotoLoader.load(url: url, lensCorrection: false)
            let repaired = try RepairBrushEngine.apply(to: loaded.image, strokes: repairStrokes)
            let rendered = try renderFullResolution(repaired, engine: engine)
            repairCount += 1
            repairRows.append([
                "file": spec.filename,
                "milliseconds": milliseconds(since: start),
                "width": rendered.width,
                "height": rendered.height,
            ])
        } catch {
            failures.append("repair phase failed for \(spec.filename): \(error.localizedDescription)")
            repairRows.append(["file": spec.filename, "error": error.localizedDescription])
        }
    }
    phaseRows["repairBrush"] = [
        "milliseconds": milliseconds(since: repairStart),
        "perImage": repairRows,
        "rssAfterBytes": currentMemory().residentBytes,
        "settings": ["strokes": 2, "modes": ["heal", "clone"],
                     "radius": 0.035, "feather": 0.5, "strength": 1.0] as [String: Any],
        "note": "headless full-resolution real RepairBrushEngine heal+clone on synthetic fixtures; not a retouch-quality acceptance",
    ] as [String: Any]

    // 10. P1-B local delivery page: static HTML + JPEG previews + contact-sheet PDF.
    let deliveryStart = CFAbsoluteTimeGetCurrent()
    let deliveryRoot = workRoot.appendingPathComponent("delivery", isDirectory: true)
    var deliveryRow: [String: Any] = [:]
    do {
        if manager.fileExists(atPath: deliveryRoot.path) {
            try manager.removeItem(at: deliveryRoot)
        }
        let fileURLs = corpusSpecs.map { corpusRoot.appendingPathComponent($0.filename) }
        let deliveryResult = try DeliveryGalleryWriter.write(
            fileURLs: fileURLs, settings: benchmarkDeliverySettings(),
            outputDirectory: deliveryRoot, context: engine.context)
        let thumbCount = (try? manager.contentsOfDirectory(
            at: deliveryResult.thumbnailDirectoryURL, includingPropertiesForKeys: nil))?.count ?? 0
        let previewCount = (try? manager.contentsOfDirectory(
            at: deliveryResult.previewDirectoryURL, includingPropertiesForKeys: nil))?.count ?? 0
        let htmlBytes = (try? manager.attributesOfItem(
            atPath: deliveryResult.indexHTMLURL.path)[.size] as? NSNumber)?.intValue ?? 0
        deliveryRow = [
            "milliseconds": milliseconds(since: deliveryStart),
            "photoCount": deliveryResult.photoCount,
            "htmlBytes": htmlBytes,
            "contactSheetGenerated": deliveryResult.contactSheetURL != nil,
            "thumbnailCount": thumbCount,
            "previewCount": previewCount,
        ]
        if thumbCount != corpusSpecs.count || previewCount != corpusSpecs.count {
            failures.append("delivery phase wrote \(thumbCount) thumbs/\(previewCount) previews, expected \(corpusSpecs.count) each")
        }
        if deliveryResult.contactSheetURL == nil {
            failures.append("delivery phase did not generate the contact-sheet PDF")
        }
    } catch {
        failures.append("delivery phase failed: \(error.localizedDescription)")
        deliveryRow = ["error": error.localizedDescription]
    }
    phaseRows["deliveryPage"] = [
        "milliseconds": milliseconds(since: deliveryStart),
        "perImage": [deliveryRow],
        "rssAfterBytes": currentMemory().residentBytes,
        "settings": ["title": "光屿 · P1-B 基准交付", "columns": 3,
                     "thumbnailMaxDimension": 640, "previewMaxDimension": 1600,
                     "contactSheet": true, "paper": "a4"] as [String: Any],
        "note": "headless real DeliveryGalleryWriter (local HTML + JPEG thumbs/previews + contact-sheet PDF); disk-bound, not a print/typography acceptance",
    ] as [String: Any]

    // 11. Batch export through the real BatchProcessor, with input hashes checked.
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
    if colorToolsCount != corpusSpecs.count { failures.append("color tools phase covered \(colorToolsCount)/\(corpusSpecs.count) fixtures") }
    if liquifyCount != liquifySpecs.count { failures.append("liquify phase covered \(liquifyCount)/\(liquifySpecs.count) fixtures") }
    if watermarkCount != corpusSpecs.count { failures.append("watermark phase covered \(watermarkCount)/\(corpusSpecs.count) fixtures") }
    if mattingCount != corpusSpecs.count { failures.append("matting phase covered \(mattingCount)/\(corpusSpecs.count) fixtures") }
    if repairCount != corpusSpecs.count { failures.append("repair phase covered \(repairCount)/\(corpusSpecs.count) fixtures") }
    if batchSummary.succeeded != corpusSpecs.count { failures.append("batch exported \(batchSummary.succeeded)/\(corpusSpecs.count) fixtures") }
    if batchSummary.failed != 0 { failures.append("batch reported \(batchSummary.failed) failures") }
    if exportedFiles.count != corpusSpecs.count { failures.append("batch produced \(exportedFiles.count) export files, expected \(corpusSpecs.count)") }

    // 7. Report.
    let peak = peakResidentBytes()
    let totalMS = milliseconds(since: processStart)
    var report: [String: Any] = [
        "schemaVersion": 3,
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
            "P1 color-tools/lens-effects and watermark phases are headless full-resolution renders of the real engines; they are not a real-photo aesthetic or typography acceptance",
            "P1 liquify phase uses deterministic synthetic face-landmark geometry, not a detected real face; timings only",
            "schemaVersion 2 adds the P1 phases; the P0 phases (corpus/import/analysis/preview/batch) keep their earlier meaning",
            "P1-B mattingAndBackground uses a synthetic radial-gradient person mask, not a Vision detection; Vision person segmentation is not timed on synthetic fixtures",
            "P1-B repairBrush applies fixed heal+clone strokes on synthetic fixtures; it is not a retouch-quality acceptance",
            "P1-B deliveryPage measures local file IO (static HTML + JPEG thumbs/previews + contact-sheet PDF); disk/CPU dependent, not a print/typography acceptance",
            "schemaVersion 3 adds the P1-B phases; P0/P1 phases keep their earlier meaning",
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

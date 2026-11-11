// Compile against existing PhotoCore debug objects; no SwiftPM command is run here.
// Example from the repository root:
// swiftc -I .build/x86_64-apple-macosx/debug -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build Scripts/evaluate_native_inspection.swift .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o -o /tmp/evaluate-native-inspection
// Originals are read only. The source index belongs in a private, ignored output directory.
import CoreFoundation
import CoreGraphics
import CoreImage
import CryptoKit
import Darwin
import Foundation
import ImageIO
import PhotoCore
import UniformTypeIdentifiers

private struct RectRecord: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x); y = Double(rect.origin.y)
        width = Double(rect.width); height = Double(rect.height)
    }
}

private struct PixelComparison: Codable {
    let width: Int
    let height: Int
    let comparedPixels: Int
    let maximumRGBByteDifference: Int
    let maximumAlphaByteDifference: Int
    let maximumRGBAByteDifference: Int
    let maximumErrorOver255: Double
}

private struct PlanSummary: Codable {
    let requestedIntent: String
    let resolvedIntent: String
    let status: String
    let patchCount: Int
    let sampleCount: Int
    let luminanceNoise: Double
    let chromaNoise: Double
    let textureFraction: Double
    let strongEdgeFraction: Double
}

private struct SampleMetric: Codable {
    let id: String
    let outputColorSpace: String?
    var inputWidth: Int? = nil
    var inputHeight: Int? = nil
    var sampleWidth: Int? = nil
    var sampleHeight: Int? = nil
    var sampleBounds: RectRecord? = nil
    var beforeComparison: PixelComparison? = nil
    var afterComparison: PixelComparison? = nil
    var detailPlan: PlanSummary? = nil
    var seconds: Double? = nil
    var sourceSHA256Unchanged: Bool? = nil
    var passed = false
    var failureStage: String? = nil
    var failureType: String? = nil
}

private struct InspectionReport: Codable {
    let id: String
    let outputColorSpace: String
    let inputWidth: Int
    let inputHeight: Int
    let outputExtent: RectRecord
    let sampleBounds: RectRecord
    let beforeComparison: PixelComparison
    let afterComparison: PixelComparison
    let detailPlan: PlanSummary
    let settings: AdjustmentSettings
    let processingReport: ProcessingReport
}

private struct PrivateSourceIndexEntry: Codable {
    let id: String
    let source: String
    let sha256Before: String?
    let sha256After: String?
    let unchanged: Bool
}

private struct ItemResult {
    let rows: [SampleMetric]
    let indexEntry: PrivateSourceIndexEntry
}

private let rawExtensions: Set<String> = [
    "3fr", "ari", "arw", "bay", "cap", "cr2", "cr3", "crw", "dcs", "dcr",
    "dng", "drf", "eip", "erf", "fff", "gpr", "iiq", "k25", "kdc", "mdc",
    "mef", "mos", "mrw", "nef", "nrw", "orf", "pef", "ptx", "pxn", "r3d",
    "raf", "raw", "rw2", "rwl", "rwz", "sr2", "srf", "srw", "x3f"
]

private func isRawCandidate(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return rawExtensions.contains(ext)
        || UTType(filenameExtension: ext)?.conforms(to: .rawImage) == true
}

private func isSameOrDescendant(_ child: String, of parent: String) -> Bool {
    let prefix = parent.hasSuffix("/") ? parent : parent + "/"
    return child == parent || child.hasPrefix(prefix)
}

private func overlaps(_ lhs: String, _ rhs: String) -> Bool {
    isSameOrDescendant(lhs, of: rhs) || isSameOrDescendant(rhs, of: lhs)
}

/// Resolves existing ancestor symlinks while preserving the not-yet-created suffix.
private func resolvedPathForNewDirectory(_ url: URL, manager: FileManager) -> String {
    var ancestor = url.standardizedFileURL
    var suffix: [String] = []
    while !manager.fileExists(atPath: ancestor.path), ancestor.path != "/" {
        suffix.insert(ancestor.lastPathComponent, at: 0)
        ancestor.deleteLastPathComponent()
    }
    var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
    for component in suffix { resolved.appendPathComponent(component) }
    return resolved.standardizedFileURL.path
}

private func digest(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func failureType(_ error: Error) -> String {
    String(reflecting: type(of: error))
}

private func cgImage(_ image: CIImage, extent: CGRect, colorSpace: CGColorSpace,
                     context: CIContext) throws -> CGImage {
    let bounds = extent.integral
    guard let raster = context.createCGImage(image, from: bounds, format: .RGBA8,
                                             colorSpace: colorSpace, deferred: false),
          raster.bitsPerComponent == 8, raster.bitsPerPixel == 32,
          raster.width == Int(bounds.width), raster.height == Int(bounds.height),
          let raw = raster.dataProvider?.data, let bytes = CFDataGetBytePtr(raw),
          CFDataGetLength(raw) >= raster.bytesPerRow * raster.height else {
        throw AtelierError.imageRead("full-image RGBA8 render failed")
    }
    // Materialize the complete reference before cropping; otherwise an image
    // provider could evaluate only the requested ROI and defeat this check.
    let owned = Data(bytes: bytes, count: CFDataGetLength(raw)) as CFData
    guard let provider = CGDataProvider(data: owned),
          let full = CGImage(width: raster.width, height: raster.height,
              bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: raster.bytesPerRow,
              space: colorSpace, bitmapInfo: raster.bitmapInfo, provider: provider,
              decode: nil, shouldInterpolate: false, intent: raster.renderingIntent) else {
        throw AtelierError.imageRead("full-image raster copy failed")
    }
    return full
}

private func cropFullImage(_ image: CIImage, outputExtent: CGRect, sampleBounds: CGRect,
                           colorSpace: CGColorSpace, context: CIContext) throws -> CGImage {
    let full = try cgImage(image, extent: outputExtent, colorSpace: colorSpace, context: context)
    let fullBounds = outputExtent.integral
    // CGImage crop uses top-left pixel coordinates; Core Image extents use bottom-left.
    let crop = CGRect(x: sampleBounds.minX - fullBounds.minX,
                      y: fullBounds.maxY - sampleBounds.maxY,
                      width: sampleBounds.width, height: sampleBounds.height)
    guard crop.minX >= 0, crop.minY >= 0,
          crop.maxX <= CGFloat(full.width), crop.maxY <= CGFloat(full.height),
          crop.width.rounded() == crop.width, crop.height.rounded() == crop.height,
          let result = full.cropping(to: crop), result.bitsPerComponent == 8,
          result.bitsPerPixel == 32 else {
        throw AtelierError.imageRead("full-image RGBA8 crop failed")
    }
    return result
}

private func providerBytes(_ image: CGImage) throws -> Data {
    guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
          image.bytesPerRow >= image.width * 4,
          let provider = image.dataProvider?.data,
          let pointer = CFDataGetBytePtr(provider) else {
        throw AtelierError.imageRead("RGBA8 provider bytes unavailable")
    }
    let length = CFDataGetLength(provider)
    // Cropped CGImages may expose only the last row's used pixels, without
    // trailing padding up to the parent image's full row stride.
    let requiredLength = (image.height - 1) * image.bytesPerRow + image.width * 4
    guard length >= requiredLength else {
        throw AtelierError.imageRead("RGBA8 provider bytes truncated")
    }
    // Copy from the provider so this check reads the actual raster bytes.
    return Data(bytes: pointer, count: requiredLength)
}

private func compareRGBA8(_ actual: CGImage, _ expected: CGImage) throws -> PixelComparison {
    guard actual.width == expected.width, actual.height == expected.height else {
        throw AtelierError.imageRead("ROI/reference pixel dimensions differ")
    }
    let actualBytes = try providerBytes(actual)
    let expectedBytes = try providerBytes(expected)
    var maxRGB = 0, maxAlpha = 0
    for y in 0..<actual.height {
        for x in 0..<actual.width {
            let a = y * actual.bytesPerRow + x * 4
            let e = y * expected.bytesPerRow + x * 4
            for channel in 0..<3 {
                maxRGB = max(maxRGB, abs(Int(actualBytes[a + channel]) - Int(expectedBytes[e + channel])))
            }
            maxAlpha = max(maxAlpha, abs(Int(actualBytes[a + 3]) - Int(expectedBytes[e + 3])))
        }
    }
    let difference = max(maxRGB, maxAlpha)
    return PixelComparison(width: actual.width, height: actual.height,
        comparedPixels: actual.width * actual.height,
        maximumRGBByteDifference: maxRGB, maximumAlphaByteDifference: maxAlpha,
        maximumRGBAByteDifference: difference, maximumErrorOver255: Double(difference) / 255)
}

private func savePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { throw AtelierError.imageWrite("PNG destination unavailable") }
    CGImageDestinationAddImage(destination, image,
        [kCGImagePropertyOrientation: 1] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw AtelierError.imageWrite("PNG write failed")
    }
}

private func sideBySide(_ before: CGImage, _ after: CGImage,
                        colorSpace: CGColorSpace) throws -> CGImage {
    guard before.width == after.width, before.height == after.height,
          let context = CGContext(data: nil, width: before.width * 2, height: before.height,
              bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw AtelierError.imageWrite("comparison raster unavailable")
    }
    context.interpolationQuality = .none
    let height = CGFloat(before.height), width = CGFloat(before.width)
    context.draw(before, in: CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(after, in: CGRect(x: width, y: 0, width: width, height: height))
    guard let output = context.makeImage() else {
        throw AtelierError.imageWrite("comparison raster unavailable")
    }
    return output
}

private func planSummary(_ plan: LocalDetailPlan) -> PlanSummary {
    PlanSummary(requestedIntent: plan.requestedIntent.rawValue,
        resolvedIntent: plan.resolvedIntent.rawValue, status: plan.status,
        patchCount: plan.measurements.patchCount, sampleCount: plan.measurements.sampleCount,
        luminanceNoise: plan.measurements.luminanceNoise,
        chromaNoise: plan.measurements.chromaNoise,
        textureFraction: plan.measurements.textureFraction,
        strongEdgeFraction: plan.measurements.strongEdgeFraction)
}

private func sampleSpaces(index: Int, total: Int) -> [OutputColorSpace] {
    if total == 1 { return [.sRGB, .displayP3] }
    return [index.isMultiple(of: 2) ? .sRGB : .displayP3]
}

private func sampleSuffix(_ colorSpace: OutputColorSpace) -> String {
    colorSpace == .sRGB ? "srgb" : "display-p3"
}

private func failedMetric(_ id: String, colorSpace: OutputColorSpace?, stage: String,
                          error: Error) -> SampleMetric {
    var row = SampleMetric(id: id, outputColorSpace: colorSpace?.rawValue)
    row.failureStage = stage
    row.failureType = failureType(error)
    return row
}

private func runSample(id: String, loaded: LoadedPhoto, settings: AdjustmentSettings,
                       detailMaskID: UUID, colorSpace: OutputColorSpace,
                       engine: PhotoEngine, renderer: NativeInspectionRenderer,
                       reportDirectory: URL, comparisonDirectory: URL,
                       encoder: JSONEncoder) -> SampleMetric {
    let started = Date()
    let suffix = sampleSuffix(colorSpace)
    var stage = "native-inspection"
    do {
        let region = NativeInspectionRegion(pixelSize: 512)
        let inspected = try renderer.render(loaded.image, settings: settings, lut: nil,
            outputColorSpace: colorSpace, initialReport: loaded.report, region: region)
        stage = "full-reference-process"
        let fullAfter = try engine.process(loaded.image, settings: settings, lut: nil,
            initialReport: loaded.report, outputColorSpace: colorSpace)
        var baseSettings = settings
        baseSettings.masks = []
        let fullBefore = try engine.process(loaded.image, settings: baseSettings, lut: nil,
            initialReport: loaded.report, outputColorSpace: colorSpace)
        guard inspected.outputExtent == fullAfter.image.extent,
              inspected.outputExtent == fullBefore.image.extent else {
            throw AtelierError.invalidConfiguration("output extents differ")
        }

        stage = "detail-plan"
        guard let inspectedPlan = inspected.report.localDetails?.first(where: { $0.maskID == detailMaskID }),
              let fullPlan = fullAfter.report.localDetails?.first(where: { $0.maskID == detailMaskID }),
              inspectedPlan.measurements == fullPlan.measurements else {
            throw AtelierError.invalidConfiguration("native and full-source detail measurements differ")
        }
        stage = "full-reference-render-and-crop"
        let colorProfile = colorSpace.cgColorSpace
        let expectedBefore = try cropFullImage(fullBefore.image, outputExtent: inspected.outputExtent,
            sampleBounds: inspected.sampleBounds, colorSpace: colorProfile, context: engine.context)
        let expectedAfter = try cropFullImage(fullAfter.image, outputExtent: inspected.outputExtent,
            sampleBounds: inspected.sampleBounds, colorSpace: colorProfile, context: engine.context)
        stage = "provider-byte-comparison"
        let beforeDiff = try compareRGBA8(inspected.before, expectedBefore)
        let afterDiff = try compareRGBA8(inspected.after, expectedAfter)

        stage = "write-roi-pngs"
        let stem = "\(id)-\(suffix)"
        try savePNG(inspected.before, to: comparisonDirectory.appendingPathComponent(stem + "-before.png"))
        try savePNG(inspected.after, to: comparisonDirectory.appendingPathComponent(stem + "-after.png"))
        let paired = try sideBySide(inspected.before, inspected.after, colorSpace: colorProfile)
        try savePNG(paired, to: comparisonDirectory.appendingPathComponent(stem + "-comparison.png"))

        let passed = beforeDiff.maximumRGBAByteDifference <= 2
            && afterDiff.maximumRGBAByteDifference <= 2
        let width = Int(loaded.image.extent.width.rounded())
        let height = Int(loaded.image.extent.height.rounded())
        let summary = planSummary(inspectedPlan)
        let report = InspectionReport(id: id, outputColorSpace: colorSpace.rawValue,
            inputWidth: width, inputHeight: height,
            outputExtent: RectRecord(inspected.outputExtent),
            sampleBounds: RectRecord(inspected.sampleBounds),
            beforeComparison: beforeDiff, afterComparison: afterDiff,
            detailPlan: summary, settings: settings, processingReport: inspected.report)
        try encoder.encode(report).write(to: reportDirectory.appendingPathComponent(stem + "-report.json"),
                                         options: .atomic)

        var row = SampleMetric(id: id, outputColorSpace: colorSpace.rawValue)
        row.inputWidth = width; row.inputHeight = height
        row.sampleWidth = inspected.after.width; row.sampleHeight = inspected.after.height
        row.sampleBounds = RectRecord(inspected.sampleBounds)
        row.beforeComparison = beforeDiff; row.afterComparison = afterDiff
        row.detailPlan = summary; row.seconds = Date().timeIntervalSince(started)
        row.passed = passed
        if !passed {
            row.failureStage = "pixel-equivalence"
            row.failureType = "maximum RGBA8 channel difference exceeded 2/255"
        }
        return row
    } catch {
        var row = failedMetric(id, colorSpace: colorSpace, stage: stage, error: error)
        row.seconds = Date().timeIntervalSince(started)
        return row
    }
}

private func evaluateItem(_ item: PhotoItem, id: String, ordinal: Int, total: Int,
                          engine: PhotoEngine, renderer: NativeInspectionRenderer,
                          output: URL, reportDirectory: URL, comparisonDirectory: URL,
                          encoder: JSONEncoder) -> ItemResult {
    let hashBefore = try? digest(item.url)
    var rows: [SampleMetric] = []

    if hashBefore != nil {
        do {
            let loaded = try PhotoLoader.load(url: item.url, lensCorrection: false)
            var settings = AdjustmentSettings()
            settings.autoExposure = false
            settings.autoWhiteBalance = false
            settings.colorHarmony = nil
            settings.protectSkin = 0
            settings.protectNeutrals = 0
            settings.preserveLuminance = 0
            settings.gamutCompression = 0

            var detailMask = LocalMask(name: "逐图自适应细节", kind: .luminance,
                                       exposureEV: 0, highlightProtection: 0.25,
                                       colorProtection: 0.25)
            detailMask.detailAdaptation = LocalDetailAdaptation(intent: .automatic, strength: 0.6)
            let detailMaskID = detailMask.id
            let localLightColor = LocalMask(name: "局部光色", kind: .radial,
                start: .init(x: 0.62, y: 0.52), end: .init(x: 0.82, y: 0.73),
                radius: 0.22, feather: 0.72, exposureEV: 0.12, saturation: 1.06,
                warmth: 0.04, contrast: 1.02, highlights: -0.05, shadows: 0.04,
                highlightProtection: 0.25, colorProtection: 0.25, stage: .afterLook)
            settings.masks = [detailMask, localLightColor]

            for target in sampleSpaces(index: ordinal, total: total) {
                rows.append(runSample(id: id, loaded: loaded, settings: settings,
                    detailMaskID: detailMaskID, colorSpace: target, engine: engine,
                    renderer: renderer, reportDirectory: reportDirectory,
                    comparisonDirectory: comparisonDirectory, encoder: encoder))
            }
        } catch {
            rows.append(failedMetric(id, colorSpace: nil, stage: "full-resolution-load", error: error))
        }
    } else {
        rows.append(SampleMetric(id: id, outputColorSpace: nil, failureStage: "source-sha256-before",
                                 failureType: "source could not be hashed"))
    }

    let hashAfter = try? digest(item.url)
    let unchanged = hashBefore != nil && hashBefore == hashAfter
    if !unchanged, rows.isEmpty {
        rows.append(SampleMetric(id: id, outputColorSpace: nil, failureStage: "source-sha256",
                                 failureType: "source could not be verified unchanged"))
    }
    for index in rows.indices {
        rows[index].sourceSHA256Unchanged = unchanged
        if !unchanged {
            rows[index].passed = false
            rows[index].failureStage = "source-sha256"
            rows[index].failureType = "source hash changed or could not be verified"
        }
    }

    return ItemResult(rows: rows, indexEntry: PrivateSourceIndexEntry(
        id: id, source: item.url.path, sha256Before: hashBefore,
        sha256After: hashAfter, unchanged: unchanged))
}

let arguments = CommandLine.arguments
let rawOnly = arguments.count == 4 && arguments[3] == "--raw-only"
guard arguments.count == 3 || rawOnly else {
    fputs("Usage: evaluate_native_inspection INPUT_DIRECTORY NEW_OUTPUT_DIRECTORY [--raw-only]\n", stderr)
    exit(2)
}

let manager = FileManager.default
let input = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
let output = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
guard input.path != output.path, !manager.fileExists(atPath: output.path) else {
    fputs("Evaluation requires a new output directory separate from the source.\n", stderr)
    exit(2)
}
let canonicalInput = input.resolvingSymlinksInPath().standardizedFileURL.path
let canonicalOutput = resolvedPathForNewDirectory(output, manager: manager)
guard !overlaps(canonicalInput, canonicalOutput), !overlaps(input.path, output.path) else {
    fputs("Input and output trees must not overlap.\n", stderr)
    exit(2)
}

do {
    // Keep the unresolved input URL here so PhotoLoader.scan can reject a symlink root.
    let scanned = try PhotoLoader.scan(folder: input, recursive: false)
    let items = rawOnly ? scanned.filter { isRawCandidate($0.url) } : scanned
    guard !items.isEmpty else {
        fputs(rawOnly ? "No supported RAW candidates.\n" : "No supported photographs.\n", stderr)
        exit(1)
    }

    let comparisonDirectory = output.appendingPathComponent("comparisons", isDirectory: true)
    let reportDirectory = output.appendingPathComponent("reports", isDirectory: true)
    try manager.createDirectory(at: comparisonDirectory, withIntermediateDirectories: true)
    try manager.createDirectory(at: reportDirectory, withIntermediateDirectories: true)

    let engine = PhotoEngine()
    let renderer = NativeInspectionRenderer(engine: engine)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var rows: [SampleMetric] = []
    var sourceIndex: [PrivateSourceIndexEntry] = []

    for (ordinal, item) in items.enumerated() {
        let id = String(format: "photo-%02d", ordinal + 1)
        let result = autoreleasepool {
            evaluateItem(item, id: id, ordinal: ordinal, total: items.count,
                         engine: engine, renderer: renderer, output: output,
                         reportDirectory: reportDirectory, comparisonDirectory: comparisonDirectory,
                         encoder: encoder)
        }
        rows.append(contentsOf: result.rows)
        sourceIndex.append(result.indexEntry)
        let completed = result.rows.filter(\.passed).count
        let failed = result.rows.count - completed
        print("\(id): \(completed) passing samples, \(failed) failures")
        fflush(stdout)
    }

    try encoder.encode(sourceIndex).write(to: output.appendingPathComponent("private-source-index.json"),
                                           options: .atomic)
    try encoder.encode(rows).write(to: output.appendingPathComponent("metrics.json"), options: .atomic)
    let failedSamples = rows.filter { !$0.passed }.count
    print("NATIVE INSPECTION: \(items.count) originals, \(rows.count - failedSamples)/\(rows.count) passing color-space samples, \(failedSamples) failures")
    if failedSamples > 0 { exit(1) }
} catch {
    fputs("NATIVE INSPECTION FAILED: \(failureType(error))\n", stderr)
    exit(1)
}

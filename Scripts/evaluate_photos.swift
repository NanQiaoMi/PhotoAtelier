// Compile against the already-built PhotoCore objects; see docs/targeted-tones.md.
// Local read-only photo evaluation. Outputs require a new, separate directory.
import AppKit
import CoreImage
import Foundation
import ImageIO
import PhotoCore

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("Usage: evaluate_photos INPUT_DIRECTORY NEW_OUTPUT_DIRECTORY") }
let input = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
let output = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
let manager = FileManager.default
let prefix = input.path.hasSuffix("/") ? input.path : input.path + "/"
guard input.path != output.path, !output.path.hasPrefix(prefix),
      !input.path.hasPrefix(output.path + "/"), !manager.fileExists(atPath: output.path) else {
    fatalError("Output must be a new directory outside the input tree")
}
let items = try PhotoLoader.scan(folder: input, recursive: false)
guard !items.isEmpty else { fatalError("No supported input photographs") }
try manager.createDirectory(at: output, withIntermediateDirectories: true)
let engine = PhotoEngine()
let analyzer = PhotoAnalyzer()
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
var index: [[String: String]] = []
var rows: [[String: Any]] = []
var thumbnails: [(id: String, images: [NSImage])] = []
var export = ExportSettings()
export.format = .jpeg
export.colorSpace = .sRGB
export.jpegQuality = 0.94

func small(_ image: CIImage, dimension: CGFloat) -> CIImage {
    let extent = image.extent
    let scale = min(1, dimension / max(extent.width, extent.height))
    return image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
        .transformed(by: .init(scaleX: scale, y: scale))
}

func pixels(_ image: CIImage) -> [Float] {
    let sample = small(image, dimension: 192)
    let bounds = sample.extent.integral
    let width = Int(bounds.width), height = Int(bounds.height)
    var values = [Float](repeating: 0, count: width * height * 4)
    values.withUnsafeMutableBytes { buffer in
        engine.context.render(sample, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                              bounds: bounds, format: .RGBAf,
                              colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    }
    return values
}

func measurement(reference: [Float], candidate: [Float]) -> [String: Any] {
    guard candidate.count == reference.count else { return ["error": "sample sizes differ"] }
    var squared = 0.0, maximum = 0.0, count = 0.0
    var lumas: [Double] = []
    var below = 0.0, above = 0.0, nonfinite = 0
    var originalZones = Array(repeating: 0.0, count: 3)
    var changedZones = Array(repeating: 0.0, count: 3)
    var weights = Array(repeating: 0.0, count: 3)
    for offset in stride(from: 0, to: candidate.count, by: 4) {
        guard candidate[offset + 3] > 0.001 else { continue }
        let c = (0..<3).map { Double(candidate[offset + $0]) }
        let r = (0..<3).map { Double(reference[offset + $0]) }
        guard c.allSatisfy(\.isFinite), r.allSatisfy(\.isFinite) else { nonfinite += 1; continue }
        let ry = 0.2126 * r[0] + 0.7152 * r[1] + 0.0722 * r[2]
        let cy = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        lumas.append(cy)
        if cy <= 0.002 { below += 1 }
        if c.max()! >= 1 { above += 1 }
        let zone = ry < 0.12 ? 0 : (ry < 0.55 ? 1 : 2)
        originalZones[zone] += ry; changedZones[zone] += cy; weights[zone] += 1
        for channel in 0..<3 {
            let diff = abs(c[channel] - r[channel])
            squared += diff * diff; maximum = max(maximum, diff); count += 1
        }
    }
    lumas.sort()
    let zones = (0..<3).map { zone -> [String: Any] in
        ["name": ["shadow", "midtone", "highlight"][zone], "samples": weights[zone],
         "meanLuminanceEVChange": log2(max(changedZones[zone], 1e-12) / max(originalZones[zone], 1e-12))]
    }
    return ["rgbRMS": sqrt(squared / max(1, count)), "maximumRGBChange": maximum,
            "medianLuminance": lumas.isEmpty ? 0 : lumas[lumas.count / 2],
            "nearBlackFraction": below / Double(max(1, lumas.count)),
            "displayWhiteFraction": above / Double(max(1, lumas.count)),
            "nonfiniteSamples": nonfinite, "zones": zones]
}

for (number, item) in items.enumerated() {
    autoreleasepool {
        let id = String(format: "photo-%02d", number + 1)
        index.append(["id": id, "source": item.url.path])
        do {
            let loaded = try PhotoLoader.load(url: item.url, lensCorrection: false)
            let analysis = try analyzer.analyze(image: loaded.image, properties: loaded.properties, sourceURL: item.url)
            try encoder.encode(analysis).write(to: output.appendingPathComponent(id + "-analysis.json"), options: .atomic)
            let preview = small(loaded.image, dimension: 1920)
            let reference = try engine.process(preview, settings: .init(), lut: nil, outputColorSpace: .sRGB).image
            let referencePixels = pixels(reference)
            let suggestions = try RegionalAdjustmentAnalyzer.suggestions(reference: reference, context: engine.context)
            try encoder.encode(suggestions).write(to: output.appendingPathComponent(id + "-regions.json"), options: .atomic)
            var images: [NSImage] = []
            var results: [[String: Any]] = []
            let choices: [(String, AdjustmentSettings)] = [("original", .init())]
                + analysis.proposals.map { ($0.id, $0.settings) }
            for (name, settings) in choices {
                let result = try engine.process(preview, settings: settings, lut: nil, outputColorSpace: .sRGB)
                let destination = output.appendingPathComponent("\(id)-\(name).jpg")
                try PhotoExporter.write(image: result.image, to: destination, settings: export,
                                        sourceProperties: [:], context: engine.context)
                if let image = NSImage(contentsOf: destination) { images.append(image) }
                var report = measurement(reference: referencePixels, candidate: pixels(result.image))
                report["id"] = name
                report["settings"] = try JSONSerialization.jsonObject(with: encoder.encode(settings))
                results.append(report)
            }
            for suggestion in suggestions {
                var settings = AdjustmentSettings()
                settings.masks = [suggestion.mask]
                let adjusted = try engine.process(preview, settings: settings, lut: nil, outputColorSpace: .sRGB)
                let name = id + "-" + suggestion.id + ".jpg"
                try PhotoExporter.write(image: adjusted.image, to: output.appendingPathComponent(name), settings: export,
                                        sourceProperties: [:], context: engine.context)
                var report = measurement(reference: referencePixels, candidate: pixels(adjusted.image))
                report["id"] = suggestion.id
                report["mask"] = try JSONSerialization.jsonObject(with: encoder.encode(suggestion.mask))
                results.append(report)
            }
            thumbnails.append((id, images))
            rows.append(["id": id, "width": Int(loaded.image.extent.width),
                         "height": Int(loaded.image.extent.height),
                         "analysis": try JSONSerialization.jsonObject(with: encoder.encode(analysis)),
                         "regionalSuggestions": try JSONSerialization.jsonObject(with: encoder.encode(suggestions)),
                         "results": results])
            print("\(id): \(Int(loaded.image.extent.width))x\(Int(loaded.image.extent.height)) \(analysis.sceneAssessment?.category.rawValue ?? "unknown")")
            fflush(stdout)
        } catch {
            rows.append(["id": id, "error": error.localizedDescription])
            print("\(id): FAILED \(error.localizedDescription)")
        }
    }
}
try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("source-index.json"), options: .atomic)
try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("evaluation.json"), options: .atomic)

// Contact sheets use neutral anonymous IDs; source names stay in the local index.
for start in stride(from: 0, to: thumbnails.count, by: 4) {
    let end = min(thumbnails.count, start + 4)
    let width = 1440, rowHeight = 300, header = 40
    let height = (end - start) * rowHeight + header
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
    let textStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white]
    for (column, title) in ["Original", "Balanced", "Bright", "Soft"].enumerated() {
        (title as NSString).draw(at: NSPoint(x: column * 360 + 12, y: height - 28), withAttributes: textStyle)
    }
    for row in start..<end {
        let y = height - header - (row - start + 1) * rowHeight
        for (column, image) in thumbnails[row].images.enumerated() {
            let scale = min(340 / image.size.width, 260 / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: CGFloat(column * 360 + 10) + (340 - size.width) / 2,
                                  y: CGFloat(y + 28) + (260 - size.height) / 2,
                                  width: size.width, height: size.height))
            (thumbnails[row].id as NSString)
                .draw(at: NSPoint(x: column * 360 + 12, y: y + 5), withAttributes: textStyle)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: output.appendingPathComponent(String(format: "contact-%02d.png", start / 4 + 1)))
}
let errors = rows.filter { $0["error"] != nil }.count
print("EVALUATION: \(items.count) inputs, \(rows.count - errors) completed, \(errors) failures; source files unchanged by this tool")
if errors > 0 { exit(1) }

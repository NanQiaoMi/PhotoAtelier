// Build against PhotoCore; see docs/adaptive-detail.md.
// Originals are read only. The private source index belongs in an ignored output directory.
import AppKit
import CoreImage
import CryptoKit
import Foundation
import PhotoCore

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("Usage: evaluate_adaptive_details INPUT_DIRECTORY NEW_OUTPUT_DIRECTORY") }
let manager = FileManager.default
let input = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
let output = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
guard input != output, !output.path.hasPrefix(input.path + "/"), !input.path.hasPrefix(output.path + "/"),
      !manager.fileExists(atPath: output.path) else { fatalError("Output must be new and outside the input tree") }
let items = try PhotoLoader.scan(folder: input, recursive: false)
guard !items.isEmpty else { fatalError("No supported photographs") }
try manager.createDirectory(at: output, withIntermediateDirectories: true)
let engine = PhotoEngine(), encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
var export = ExportSettings(); export.format = .png; export.colorSpace = .sRGB
var rows: [[String: Any]] = [], index: [[String: String]] = []
var failures = 0

func reduced(_ image: CIImage, limit: CGFloat) -> CIImage {
    let extent = image.extent, scale = min(1, limit / max(extent.width, extent.height))
    let width = max(1, Int((extent.width * scale).rounded())), height = max(1, Int((extent.height * scale).rounded()))
    return image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
        .transformed(by: .init(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
        .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
}

func pixels(_ image: CIImage) -> [Float] {
    let image = reduced(image, limit: 384), bounds = image.extent
    let width = Int(bounds.width), height = Int(bounds.height)
    var data = [Float](repeating: 0, count: width * height * 4)
    data.withUnsafeMutableBytes {
        engine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                              bounds: bounds, format: .RGBAf, colorSpace: linear)
    }
    return data
}

func measure(_ a: CIImage, _ b: CIImage) -> [String: Any] {
    let before = pixels(a), after = pixels(b)
    guard before.count == after.count else { return ["error": "size mismatch"] }
    var maxEV = 0.0, sum = 0.0, nonfinite = 0, introducedOverflow = 0
    for i in stride(from: 0, to: before.count, by: 4) where before[i + 3] > 0.01 {
        let source = (0..<3).map { Double(before[i + $0]) }, result = (0..<3).map { Double(after[i + $0]) }
        guard result.allSatisfy(\.isFinite) else { nonfinite += 1; continue }
        let y0 = 0.2126 * source[0] + 0.7152 * source[1] + 0.0722 * source[2]
        let y1 = 0.2126 * result[0] + 0.7152 * result[1] + 0.0722 * result[2]
        if y0 > 0.005, y1 > 0 { maxEV = max(maxEV, abs(log2(y1 / y0))) }
        if source.allSatisfy({ $0 >= 0 && $0 <= 1 }), result.contains(where: { $0 < -0.001 || $0 > 1.001 }) {
            introducedOverflow += 1
        }
        for c in 0..<3 { sum += pow(result[c] - source[c], 2) }
    }
    return ["sampledMaximumAbsEV": maxEV, "rgbRMS": sqrt(sum / Double(max(1, before.count / 4 * 3))),
            "nonfiniteSamples": nonfinite, "introducedOverflowSamples": introducedOverflow]
}

func write(_ image: CIImage, name: String) throws -> CIImage {
    let url = output.appendingPathComponent(name + ".png")
    try PhotoExporter.write(image: reduced(image, limit: 1920), to: url, settings: export,
                            sourceProperties: [:], context: engine.context)
    guard let decoded = CIImage(contentsOf: url) else { throw AtelierError.imageRead("无法复读评估导出") }
    return decoded
}

for (number, item) in items.enumerated() {
    autoreleasepool {
        let id = String(format: "photo-%02d", number + 1)
        do {
            let hash = SHA256.hash(data: try Data(contentsOf: item.url)).map { String(format: "%02x", $0) }.joined()
            index.append(["id": id, "source": item.url.path, "sha256": hash])
            let loaded = try PhotoLoader.load(url: item.url, lensCorrection: false)
            let reference = try engine.maskReferenceImage(loaded.image, settings: .init())
            let original = try write(reference, name: id + "-original")
            let mask = LocalMask(name: "逐图细节", kind: .luminance, exposureEV: 0,
                                 detailAdaptation: LocalDetailAdaptation())
            var settings = AdjustmentSettings(); settings.masks = [mask]
            let started = Date()
            let result = try engine.process(loaded.image, settings: settings, lut: nil)
            let candidate = try write(result.image, name: id + "-adaptive")
            try encoder.encode(result.report).write(to: output.appendingPathComponent(id + "-report.json"))
            var metrics = measure(original, candidate)
            metrics["id"] = id; metrics["seconds"] = Date().timeIntervalSince(started)
            metrics["inputWidth"] = Int(loaded.image.extent.width); metrics["inputHeight"] = Int(loaded.image.extent.height)
            metrics["intent"] = result.report.localDetails?.first?.resolvedIntent.rawValue ?? "missing"
            let finalHash = SHA256.hash(data: try Data(contentsOf: item.url)).map { String(format: "%02x", $0) }.joined()
            guard hash == finalHash else { throw AtelierError.invalidConfiguration("原片校验和变化") }
            rows.append(metrics)
            print("\(id): \(metrics["intent"]!) native \(Int(loaded.image.extent.width))×\(Int(loaded.image.extent.height))")
        } catch {
            failures += 1; rows.append(["id": id, "error": error.localizedDescription])
            print("\(id): FAILED \(error.localizedDescription)")
        }
    }
}
try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("private-source-index.json"))
try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("metrics.json"))
print("ADAPTIVE DETAIL: \(items.count - failures)/\(items.count), \(failures) failures")
if failures > 0 { exit(1) }

// Native-size, local-only acceptance for selected-region detail sampling.
// Build against PhotoCore as documented in docs/portrait-aware-refinement.md.
import CoreImage
import CryptoKit
import Foundation
import PhotoCore

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("Usage: evaluate_portrait_sampling INPUT_DIRECTORY NEW_OUTPUT_DIRECTORY") }
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
var export = ExportSettings(); export.format = .tiff; export.colorSpace = .displayP3
var rows: [[String: Any]] = [], privateIndex: [[String: String]] = []
var failures = 0

func hash(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

func pixels(_ image: CIImage, bounds: CGRect, numeric: Bool = false) -> [Float] {
    let width = Int(bounds.width), height = Int(bounds.height)
    var data = [Float](repeating: 0, count: width * height * 4)
    data.withUnsafeMutableBytes {
        engine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
            bounds: bounds, format: .RGBAf, colorSpace: numeric ? nil : linear)
    }
    return data
}

// Full native pixels in bounded tiles; no overview averaging of clipping/halos.
func measure(_ before: CIImage, _ after: CIImage, coverage: CIImage) -> [String: Any] {
    let extent = before.extent
    precondition(extent == after.extent && extent == coverage.extent)
    var maxEV = 0.0, outside = 0.0, selectedMax = 0.0, selectedSquared = 0.0
    var selectedCount = 0, nonfinite = 0, introducedOverflow = 0, alphaError = 0.0
    for y in stride(from: Int(extent.minY), to: Int(extent.maxY), by: 256) {
        for x in stride(from: Int(extent.minX), to: Int(extent.maxX), by: 256) {
            let tile = CGRect(x: x, y: y, width: min(256, Int(extent.maxX) - x),
                              height: min(256, Int(extent.maxY) - y))
            let a = pixels(before, bounds: tile), b = pixels(after, bounds: tile)
            let m = pixels(coverage, bounds: tile, numeric: true)
            for i in stride(from: 0, to: a.count, by: 4) {
                guard (0..<4).allSatisfy({ b[i + $0].isFinite }) else { nonfinite += 1; continue }
                alphaError = max(alphaError, abs(Double(a[i + 3] - b[i + 3])))
                guard a[i + 3] > 0.001 else { continue }
                let source = (0..<3).map { Double(a[i + $0]) }
                let result = (0..<3).map { Double(b[i + $0]) }
                if source.allSatisfy({ $0 >= 0 && $0 <= 1 }),
                   result.contains(where: { $0 < -0.0001 || $0 > 1.0001 }) { introducedOverflow += 1 }
                let change = (0..<3).map { abs(source[$0] - result[$0]) }.max() ?? 0
                if m[i] <= 0.000001 { outside = max(outside, change) }
                if m[i] > 0.1 {
                    selectedCount += 1; selectedMax = max(selectedMax, change)
                    selectedSquared += (0..<3).reduce(0) { $0 + pow(source[$1] - result[$1], 2) }
                    let y0 = source[0] * 0.2126 + source[1] * 0.7152 + source[2] * 0.0722
                    let y1 = result[0] * 0.2126 + result[1] * 0.7152 + result[2] * 0.0722
                    if y0 > 0.005 && y1 > 0 { maxEV = max(maxEV, abs(log2(y1 / y0))) }
                }
            }
        }
    }
    return ["nativeSelectedPixels": selectedCount, "selectedMaximumAbsEV": maxEV,
            "selectedMaximumRGBChange": selectedMax,
            "selectedRGBRMS": sqrt(selectedSquared / Double(max(1, selectedCount * 3))),
            "outsideMaskMaximumRGBChange": outside, "nonfinitePixels": nonfinite,
            "introducedOverflowPixels": introducedOverflow, "maximumAlphaError": alphaError]
}

func write(_ image: CIImage, _ name: String) throws -> CIImage {
    let url = output.appendingPathComponent(name + ".tiff")
    try PhotoExporter.write(image: image, to: url, settings: export, sourceProperties: [:], context: engine.context)
    guard let decoded = CIImage(contentsOf: url) else { throw AtelierError.imageRead("Cannot read acceptance export") }
    return decoded
}

for (number, item) in items.enumerated() {
    autoreleasepool {
        let id = String(format: "photo-%02d", number + 1), started = Date()
        do {
            let originalHash = try hash(item.url)
            privateIndex.append(["id": id, "source": item.url.path, "sha256": originalHash])
            let loaded = try PhotoLoader.load(url: item.url, lensCorrection: false)
            let reference = try engine.maskReferenceImage(loaded.image, settings: .init())
            let selections = try ContentSelectionAnalyzer.analyze(reference: reference,
                targets: [.faceSkin], context: engine.context)
            let mask = LocalMask(name: "人像选区实测", kind: .luminance, exposureEV: 0,
                highlightProtection: 0.65, colorProtection: 0.8, contentSelection: .faceSkin,
                detailAdaptation: LocalDetailAdaptation(intent: .portrait, strength: 0.6))
            var settings = AdjustmentSettings(); settings.masks = [mask]
            let result = try engine.process(loaded.image, settings: settings, lut: nil,
                preparedContentSelections: selections)
            try encoder.encode(result.report).write(to: output.appendingPathComponent(id + "-report.json"))
            guard let plan = result.report.localDetails?.first, let sampling = plan.sampling else {
                throw AtelierError.invalidConfiguration("Missing native sampling evidence")
            }
            var row: [String: Any] = ["id": id, "width": Int(reference.extent.width),
                "height": Int(reference.extent.height), "faceStatus": selections.report.faceStatus,
                "detailStatus": plan.status, "neutral": plan.settings.isNeutral,
                "effectiveAreaPixels": sampling.effectiveAreaPixels,
                "fineRadius": sampling.fineRadius, "coarseRadius": sampling.coarseRadius]
            if !plan.settings.isNeutral {
                let coverage = try engine.localMaskImage(mask, reference: reference, contentSelections: selections)
                let old = try LocalDetailEngine.apply(reference, settings: plan.settings,
                    noiseEstimate: plan.noiseEstimate, modernProtection: true)
                let isolated = try LocalDetailEngine.apply(reference, settings: plan.settings,
                    noiseEstimate: plan.noiseEstimate, modernProtection: true,
                    samplingMask: coverage, samplingPlan: sampling)
                func blend(_ candidate: CIImage) -> CIImage {
                    candidate.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: reference, kCIInputMaskImageKey: coverage
                    ]).cropped(to: reference.extent)
                }
                let base = try engine.process(loaded.image, settings: .init(), lut: nil)
                let original = try write(base.image, id + "-original")
                let processed = try write(result.image, id + "-portrait")
                _ = try write(blend(old), id + "-legacy-support")
                _ = try write(blend(isolated), id + "-isolated-support")
                _ = try write(coverage, id + "-mask")
                row["nativeCandidate"] = measure(reference, blend(isolated), coverage: coverage)
                row["legacyDifference"] = measure(blend(old), blend(isolated), coverage: coverage)
                row["exportRoundTrip"] = measure(original, processed, coverage: coverage)
            }
            guard try hash(item.url) == originalHash else { throw AtelierError.invalidConfiguration("Original hash changed") }
            row["seconds"] = Date().timeIntervalSince(started)
            rows.append(row)
            print("\(id): \(selections.report.faceStatus), \(plan.status), area \(Int(sampling.effectiveAreaPixels))")
        } catch {
            failures += 1; rows.append(["id": id, "error": error.localizedDescription])
            print("\(id): FAILED \(error.localizedDescription)")
        }
    }
}
try JSONSerialization.data(withJSONObject: privateIndex, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("private-source-index.json"))
try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("metrics.json"))
print("PORTRAIT SAMPLING: \(items.count - failures)/\(items.count), \(failures) failures; originals unchanged")
if failures > 0 { exit(1) }

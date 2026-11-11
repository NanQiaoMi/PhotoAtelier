// Build against PhotoCore as documented in docs/portrait-refinement.md.
// Reads local originals and writes anonymous derivatives to a new directory.
import AppKit
import CoreImage
import Foundation
import PhotoCore

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("Usage: evaluate_portraits INPUT_DIRECTORY NEW_OUTPUT_DIRECTORY") }
let input = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
let output = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
let manager = FileManager.default
guard input != output, !output.path.hasPrefix(input.path + "/"),
      !input.path.hasPrefix(output.path + "/"), !manager.fileExists(atPath: output.path) else {
    fatalError("Output must be a new directory outside the input tree")
}
let items = try PhotoLoader.scan(folder: input, recursive: false)
guard !items.isEmpty else { fatalError("No supported photographs") }
try manager.createDirectory(at: output, withIntermediateDirectories: true)
let engine = PhotoEngine()
let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
var export = ExportSettings()
export.format = .png; export.colorSpace = .sRGB
var rows: [[String: Any]] = []
var index: [[String: String]] = []
var failures = 0

func sampled(_ image: CIImage, limit: CGFloat) -> CIImage {
    let e = image.extent, scale = min(1, limit / max(e.width, e.height))
    return image.transformed(by: .init(translationX: -e.minX, y: -e.minY))
        .transformed(by: .init(scaleX: scale, y: scale))
}

func pixels(_ image: CIImage) -> [Float] {
    let extent = image.extent
    let scale = min(1, 384 / max(extent.width, extent.height))
    let width = max(1, Int((extent.width * scale).rounded()))
    let height = max(1, Int((extent.height * scale).rounded()))
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let sample = image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
        .transformed(by: .init(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
        .cropped(to: bounds)
    var data = [Float](repeating: 0, count: width * height * 4)
    data.withUnsafeMutableBytes {
        engine.context.render(sample, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                              bounds: bounds, format: .RGBAf, colorSpace: linear)
    }
    return data
}

func measure(_ before: CIImage, _ after: CIImage, mask: CIImage) -> [String: Any] {
    let a = pixels(before), b = pixels(after), m = pixels(mask)
    var maxEV = 0.0, outsideMax = 0.0, squared = 0.0
    var nonfinite = 0, introducedClips = 0
    for i in stride(from: 0, to: a.count, by: 4) where a[i + 3] > 0.001 {
        let source = (0..<3).map { Double(a[i + $0]) }
        let result = (0..<3).map { Double(b[i + $0]) }
        guard result.allSatisfy(\.isFinite) else { nonfinite += 1; continue }
        let y0 = zip(source, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
        let y1 = zip(result, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
        if y0 > 0.005, y1 > 0 { maxEV = max(maxEV, abs(log2(y1 / y0))) }
        if source.allSatisfy({ $0 >= 0 && $0 < 0.999 }),
           result.contains(where: { $0 < -0.0001 || $0 >= 1.001 }) { introducedClips += 1 }
        for c in 0..<3 {
            let d = abs(result[c] - source[c]); squared += d * d
            if m[i] < 0.00001 { outsideMax = max(outsideMax, d) }
        }
    }
    return ["maximumAbsLuminanceEV": maxEV, "outsideMaskMaximumRGBChange": outsideMax,
            "rgbRMS": sqrt(squared / Double(max(1, a.count / 4 * 3))),
            "nonfiniteSamples": nonfinite, "introducedClippedSamples": introducedClips]
}

func exported(_ name: String) throws -> CIImage {
    // Compare the actual color-managed exported files. Lazy graph transforms
    // can evaluate edge samples differently before full-size rasterization.
    guard let image = CIImage(contentsOf: output.appendingPathComponent(name + ".png")) else {
        throw AtelierError.imageRead("无法复读导出验收图像")
    }
    return image
}

func write(_ image: CIImage, _ name: String) throws {
    try PhotoExporter.write(image: image, to: output.appendingPathComponent(name + ".png"),
                            settings: export, sourceProperties: [:], context: engine.context)
}

for (number, item) in items.enumerated() {
    autoreleasepool {
        let id = String(format: "photo-%02d", number + 1)
        index.append(["id": id, "source": item.url.path])
        do {
            let loaded = try PhotoLoader.load(url: item.url, lensCorrection: false)
            let source = sampled(loaded.image, limit: 1920)
            let reference = try engine.maskReferenceImage(source, settings: .init())
            let started = Date()
            let selections = try ContentSelectionAnalyzer.analyze(reference: reference,
                targets: Set(ContentSelectionTarget.allCases), context: engine.context)
            let seconds = Date().timeIntervalSince(started)
            try encoder.encode(selections.report).write(to: output.appendingPathComponent(id + "-selections.json"))
            try write(reference, id + "-original")
            var variants: [[String: Any]] = []
            var naturalMasks: [LocalMask] = []
            for target in ContentSelectionTarget.allCases {
                guard let detected = selections.image(for: target) else { continue }
                try write(detected, id + "-" + target.rawValue + "-mask")
                let pink = CIImage(color: CIColor(red: 0.95, green: 0.18, blue: 0.4)).cropped(to: reference.extent)
                let tinted = pink.applyingFilter("CIDissolveTransition", parameters: [
                    "inputTargetImage": reference, "inputTime": 0.55
                ]).cropped(to: reference.extent)
                let overlay = tinted.applyingFilter("CIBlendWithMask", parameters: [
                    "inputBackgroundImage": reference, "inputMaskImage": detected
                ])
                try write(overlay, id + "-" + target.rawValue + "-overlay")
                var mask = LocalMask(name: target.title, kind: .luminance, exposureEV: 0,
                                     highlightProtection: 0.65, colorProtection: 0.8, contentSelection: target)
                let inspection = try engine.inspectLocalMask(mask, reference: reference, contentSelections: selections)
                if target == .people {
                    mask.exposureEV = inspection.lightGuidance?.hasSuggestion == true ? inspection.suggestedExposureEV : 0
                    naturalMasks.append(mask)
                } else if target == .faceSkin {
                    mask.detail = LocalDetailSettings(smoothing: 0.25, textureRetention: 0.9, toneUniformity: 0.12)
                    naturalMasks.append(mask)
                } else { continue }
                var settings = AdjustmentSettings(); settings.masks = [mask]
                let adjusted = try engine.process(source, settings: settings, lut: nil,
                                                  preparedContentSelections: selections)
                try write(adjusted.image, id + "-" + target.rawValue + "-natural")
                var stats = try measure(exported(id + "-original"), exported(id + "-" + target.rawValue + "-natural"),
                                        mask: exported(id + "-" + target.rawValue + "-mask"))
                stats["target"] = target.rawValue; stats["exposureEV"] = mask.exposureEV
                stats["coverage"] = inspection.coverage
                variants.append(stats)
                if target == .faceSkin {
                    settings.masks[0].detail = LocalDetailSettings(smoothing: 1, textureRetention: 0.9, toneUniformity: 1)
                    let strong = try engine.process(source, settings: settings, lut: nil,
                                                     preparedContentSelections: selections)
                    try write(strong.image, id + "-faceSkin-stress")
                    var stressStats = try measure(exported(id + "-original"), exported(id + "-faceSkin-stress"),
                                                  mask: exported(id + "-faceSkin-mask"))
                    stressStats["target"] = "faceSkin-stress"; variants.append(stressStats)
                }
            }
            var settings = AdjustmentSettings(); settings.masks = naturalMasks
            let combined = try engine.process(source, settings: settings, lut: nil,
                                               preparedContentSelections: selections)
            try write(combined.image, id + "-combined")
            try encoder.encode(Recipe(adjustments: settings)).write(to: output.appendingPathComponent(id + "-recipe.json"))
            let row: [String: Any] = ["id": id, "detectionSeconds": seconds,
                "personStatus": selections.report.personStatus, "faceStatus": selections.report.faceStatus,
                "faceCount": selections.report.faceCount, "coverage": selections.report.coverage, "variants": variants]
            rows.append(row)
            print("\(id): people=\(selections.report.personStatus) face=\(selections.report.faceStatus) detection=\(String(format: "%.3f", seconds))s")
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
print("PORTRAIT EVALUATION: \(items.count) inputs, \(items.count - failures) completed, \(failures) failures")
if failures > 0 { exit(1) }

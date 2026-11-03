// Compile with existing PhotoCore objects, as documented in docs/style-effects.md.
// Originals are read only; output must be a new directory outside both inputs.
import AppKit
import CoreImage
import CoreText
import CryptoKit
import Foundation
import ImageIO
import PhotoCore
import UniformTypeIdentifiers

struct StyleMetric: Codable {
    let id: String
    let raw: Bool
    let styleCount: Int
    let maximumNativeDifference: Int?
    let maximumExportDifference: Int?
    let sourceUnchanged: Bool
    let seconds: Double
}

func hash(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw AtelierError.invalidConfiguration(message) }
}
let engine = PhotoEngine()
func raster(_ image: CIImage, space: CGColorSpace) throws -> CGImage {
    guard let cg = engine.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space, deferred: false),
          let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
          let provider = CGDataProvider(data: Data(bytes: bytes, count: CFDataGetLength(data)) as CFData),
          let owned = CGImage(width: cg.width, height: cg.height, bitsPerComponent: cg.bitsPerComponent,
              bitsPerPixel: cg.bitsPerPixel, bytesPerRow: cg.bytesPerRow, space: cg.colorSpace ?? space,
              bitmapInfo: cg.bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
        throw AtelierError.imageRead("Cannot materialize comparison raster")
    }
    return owned
}
func bytes(_ image: CGImage) throws -> [UInt8] {
    var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try result.withUnsafeMutableBytes {
        guard let ctx = CGContext(data: $0.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: image.colorSpace!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AtelierError.imageRead("Comparison bitmap failed") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return result
}
func difference(_ a: CGImage, _ b: CGImage) throws -> Int {
    try require(a.width == b.width && a.height == b.height, "Comparison dimensions differ")
    return try zip(bytes(a), bytes(b)).map { abs(Int($0) - Int($1)) }.max() ?? 999
}
func png(_ image: CGImage, _ url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw AtelierError.imageWrite("PNG destination failed") }
    CGImageDestinationAddImage(destination, image, nil)
    try require(CGImageDestinationFinalize(destination), "PNG write failed")
}
func contact(_ cards: [(String, CGImage)], id: String, output: URL) throws {
    let w = 210, h = 182, columns = 7, rows = (cards.count + columns - 1) / columns
    guard let ctx = CGContext(data: nil, width: w * columns, height: h * rows, bitsPerComponent: 8,
        bytesPerRow: 0, space: OutputColorSpace.sRGB.cgColorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AtelierError.imageWrite("Contact bitmap failed") }
    ctx.setFillColor(CGColor(gray: 0.05, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w * columns, height: h * rows))
    for (i, card) in cards.enumerated() {
        let x = CGFloat((i % columns) * w + 5), y = CGFloat((rows - 1 - i / columns) * h)
        let scale = min(200 / CGFloat(card.1.width), 148 / CGFloat(card.1.height))
        let size = CGSize(width: CGFloat(card.1.width) * scale, height: CGFloat(card.1.height) * scale)
        ctx.draw(card.1, in: CGRect(x: x + (200 - size.width) / 2, y: y + 27 + (148 - size.height) / 2,
                                  width: size.width, height: size.height))
        let text = NSAttributedString(string: card.0, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
        ctx.textPosition = CGPoint(x: x, y: y + 8); CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
    }
    try png(ctx.makeImage()!, output.appendingPathComponent(id + "-styles.png"))
}

do {
    try require(CommandLine.arguments.count == 4, "Usage: evaluator <photo-folder> <raw-folder> <new-output>")
    let inputs = CommandLine.arguments[1...2].map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
    let output = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
    try require(!FileManager.default.fileExists(atPath: output.path), "Output already exists")
    let resolvedOutput = output.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(output.lastPathComponent)
    for root in inputs {
        try require(!resolvedOutput.path.hasPrefix(root.path + "/") && !root.path.hasPrefix(resolvedOutput.path + "/") && root != resolvedOutput,
                    "Input and output overlap")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var items = try PhotoLoader.scan(folder: inputs[0], recursive: false)
    let raws = try PhotoLoader.scan(folder: inputs[1], recursive: false).filter { $0.url.pathExtension.lowercased() == "cr2" }
    items += raws
    try require(!items.isEmpty && !raws.isEmpty, "Need rendered photos and a real CR2")
    var metrics: [StyleMetric] = []
    var sourceIndex: [[String: String]] = []
    for (ordinal, item) in items.enumerated() {
        let id = String(format: "S%03d", ordinal + 1)
        let metric = try autoreleasepool { () throws -> StyleMetric in
            let started = Date(), beforeHash = try hash(item.url)
            let loaded = try PhotoLoader.load(url: item.url, lensCorrection: false)
            let extent = loaded.image.extent, scale = min(1, 240 / max(extent.width, extent.height))
            let scaled = loaded.image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: .init(scaleX: scale, y: scale))
            let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            let baked = try requireRaster(scaled, space: linear)
            let small = CIImage(cgImage: baked)
            var settings = AdjustmentSettings()
            settings.creativeEffects = .init(bloom: 0.35, vignette: 0.25, grain: 0.3)
            var cards = [("Original", try raster(small, space: OutputColorSpace.sRGB.cgColorSpace))]
            for preset in LUTCube.builtIns {
                settings.lutIntensity = preset.recommendedIntensity
                let result = try engine.process(small, settings: settings, lut: preset.cube, outputColorSpace: .sRGB)
                cards.append((preset.name, try raster(result.image, space: OutputColorSpace.sRGB.cgColorSpace)))
                try require(result.report.colorQuality != nil, "Missing target-aware final color inspection")
            }
            try contact(cards, id: id, output: output)
            var nativeDifference: Int?, exportDifference: Int?
            if [0, 4, 8].contains(ordinal) || loaded.report.inputWasRAW {
                let preset = LUTCube.builtIns[5 + ordinal % 3]
                settings.lutIntensity = preset.recommendedIntensity
                for space in OutputColorSpace.allCases {
                    let result = try engine.process(loaded.image, settings: settings, lut: preset.cube, outputColorSpace: space)
                    let full = try raster(result.image, space: space.cgColorSpace)
                    let inspected = try NativeInspectionRenderer(engine: engine).render(loaded.image, settings: settings,
                        lut: preset.cube, outputColorSpace: space,
                        region: .init(center: .init(x: 0.57, y: 0.43), pixelSize: 512))
                    let bounds = inspected.sampleBounds
                    let crop = try unwrap(full.cropping(to: CGRect(x: bounds.minX - extent.minX,
                        y: extent.maxY - bounds.maxY, width: bounds.width, height: bounds.height)))
                    let delta = try difference(crop, inspected.after)
                    nativeDifference = max(nativeDifference ?? 0, delta)
                    try require(delta <= 2, "Native/full difference exceeds 2/255")
                    if space == .displayP3 {
                        var export = ExportSettings(); export.format = .tiff; export.colorSpace = space
                        let target = output.appendingPathComponent(id + "-p3.tiff")
                        try PhotoExporter.write(image: result.image, to: target, settings: export,
                            sourceProperties: loaded.properties, context: engine.context)
                        let decoded = try PhotoLoader.load(url: target, lensCorrection: false)
                        let reread = try raster(decoded.image, space: space.cgColorSpace)
                        exportDifference = try difference(full, reread)
                        try require(exportDifference! <= 2, "TIFF decode differs by over 2/255")
                    }
                }
            }
            let afterHash = try hash(item.url)
            sourceIndex.append(["id": id, "source": item.url.path, "before": beforeHash, "after": afterHash])
            try require(beforeHash == afterHash, "Source hash changed")
            return StyleMetric(id: id, raw: loaded.report.inputWasRAW, styleCount: LUTCube.builtIns.count,
                maximumNativeDifference: nativeDifference, maximumExportDifference: exportDifference,
                sourceUnchanged: beforeHash == afterHash, seconds: Date().timeIntervalSince(started))
        }
        metrics.append(metric); print("STYLE_SAMPLE \(id) PASS · \(String(format: "%.3f", metric.seconds))s"); fflush(stdout)
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(metrics).write(to: output.appendingPathComponent("metrics.json"), options: .atomic)
    try encoder.encode(sourceIndex).write(to: output.appendingPathComponent("private-source-index.json"), options: .atomic)
    print("STYLE_EVALUATION PASS · \(metrics.count) sources · \(LUTCube.builtIns.count) LUTs · native/TIFF <= 2/255")
} catch { fputs("STYLE_EVALUATION FAIL: \(error.localizedDescription)\n", stderr); exit(1) }

func unwrap<T>(_ value: T?) throws -> T {
    guard let value = value else { throw AtelierError.imageRead("Missing image result") }; return value
}
func requireRaster(_ image: CIImage, space: CGColorSpace) throws -> CGImage {
    // This preserves negative/HDR samples while creating a bounded preview source.
    try unwrap(engine.context.createCGImage(image, from: image.extent, format: .RGBAh, colorSpace: space, deferred: false))
}

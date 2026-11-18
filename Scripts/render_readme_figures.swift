// Renders the README figures from the real PhotoCore pipeline.
//
// Scope and honesty boundary:
// - Inputs are the synthetic fixtures under artifacts/demo/input only. No user
//   photograph is read, so nothing personal can enter the repository.
// - Every "after" frame is produced by PhotoEngine / PhotoAnalyzer in this repo,
//   not by an external editor. The figures document pipeline behaviour and UI
//   wiring; they are NOT photographic quality or aesthetic acceptance evidence
//   (synthetic gradients cannot stand in for camera files).
// - Figures are re-generatable: `swift Scripts/render_readme_figures.swift <out>`.
//
// Usage: render_readme_figures <OUTPUT_DIRECTORY>

import AppKit
import CoreImage
import Foundation
import ImageIO
import PhotoCore

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("Usage: render_readme_figures <OUTPUT_DIRECTORY>")
    exit(2)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let fixtureDir = root.appendingPathComponent("artifacts/demo/input", isDirectory: true)
let outputDir = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let engine = PhotoEngine()
let analyzer = PhotoAnalyzer()
let context = engine.context

// MARK: - I/O helpers

func load(_ name: String) throws -> LoadedPhoto {
    try PhotoLoader.load(url: fixtureDir.appendingPathComponent(name), lensCorrection: false)
}

func scaled(_ image: CIImage, longEdge: CGFloat) -> CIImage {
    let extent = image.extent
    let scale = min(1, longEdge / max(extent.width, extent.height))
    return image
        .transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
        .transformed(by: .init(scaleX: scale, y: scale))
}

func writeJPEG(_ image: CIImage, name: String, quality: Double = 0.94) throws {
    var settings = ExportSettings()
    settings.format = .jpeg
    settings.colorSpace = .sRGB
    settings.jpegQuality = quality
    let url = outputDir.appendingPathComponent(name)
    try PhotoExporter.write(image: image, to: url, settings: settings,
                            sourceProperties: [:], context: context)
    print("wrote \(name)")
}

/// Renders to 8-bit RGBA sRGB bytes (row-major, top row first after flip).
func rasterize(_ image: CIImage) -> (width: Int, height: Int, rgba: [UInt8]) {
    let bounds = image.extent.integral
    let width = Int(bounds.width), height = Int(bounds.height)
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    buffer.withUnsafeMutableBytes { raw in
        context.render(image, toBitmap: raw.baseAddress!, rowBytes: width * 4,
                       bounds: bounds, format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
    return (width, height, buffer)
}

func writeRaw(_ image: CIImage, name: String) throws {
    let (w, h, bytes) = rasterize(image)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: w * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true,
                           intent: .defaultIntent) else {
        throw AtelierError.imageWrite("raster failed: \(name)")
    }
    let url = outputDir.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw AtelierError.imageWrite("png destination failed: \(name)")
    }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw AtelierError.imageWrite("png encode failed: \(name)")
    }
    print("wrote \(name)")
}

// MARK: - 1. Auto proposal + film look on the valley fixture

let valley = try load("01_山谷合成测试图.png")
let valleyAnalysis = try analyzer.analyze(image: valley.image, properties: valley.properties)

func proposal(_ id: String) throws -> AdjustmentSettings {
    guard let chosen = valleyAnalysis.proposals.first(where: { $0.id == id }) else {
        throw AtelierError.invalidConfiguration("missing proposal \(id)")
    }
    return chosen.settings
}

let baselineOut = try engine.process(valley.image, settings: .init(), lut: nil,
                                     outputColorSpace: .sRGB).image
try writeJPEG(scaled(baselineOut, longEdge: 1280), name: "raw-valley-baseline.jpg")

// This fixture's own evidence selects "night / keep the darkness", whose
// balanced proposal is the identity transform — a correct decision, but it
// would make two identical panels in the figure. The "bright" proposal is the
// one that actually moves pixels here, so the figure shows it and states its
// measured parameters instead of implying the auto path always changes tone.
let bright = try proposal("bright")
let brightCurve = bright.tonalCurve ?? TonalCurveSettings()
print(String(format: "bright proposal: exposure %+.2f EV, shadows %+.3f, curve s%+.3f m%+.3f",
             bright.exposureEV, bright.shadows, brightCurve.shadowsEV, brightCurve.midtonesEV))
let balancedOut = try engine.process(valley.image, settings: bright, lut: nil,
                                     outputColorSpace: .sRGB).image
try writeJPEG(scaled(balancedOut, longEdge: 1280), name: "raw-valley-balanced.jpg")

// Film look: Classic Chrome approximation at 0.60 with the documented protections.
let classicChrome = FilmLUTCatalog.preset(id: "film-fuji-classic-chrome")!
var filmSettings = bright
filmSettings.lutIntensity = 0.60
filmSettings.preserveLuminance = 0.75
filmSettings.protectSkin = 0.85
filmSettings.protectNeutrals = 0.65
let filmOut = try engine.process(valley.image, settings: filmSettings, lut: classicChrome.cube,
                                 outputColorSpace: .sRGB).image
try writeJPEG(scaled(filmOut, longEdge: 1280), name: "raw-valley-film.jpg")

// Creative-effects stack (halation / mist / grain / vignette) on top of the film look.
var effectSettings = filmSettings
effectSettings.creativeEffects = CreativeEffectsSettings(
    bloom: 0.18, vignette: 0.22, grain: 0.16,
    halation: 0.25, mist: 0.15, fade: 0.10, bleachBypass: 0)
let effectOut = try engine.process(valley.image, settings: effectSettings, lut: classicChrome.cube,
                                   outputColorSpace: .sRGB).image
try writeJPEG(scaled(effectOut, longEdge: 1280), name: "raw-valley-effects.jpg")

// MARK: - 2. LUT catalogue contact sheet (all built-in presets, real renders)

let shelfSource = scaled(try load("02_色彩与中性阶测试图.png").image, longEdge: 720)
// The shelf shows the built-in catalogue plus the five attributed Fujifilm
// approximations (FilmLUTCatalog), so the figure renders the same set.
let shelfPresets = LUTCube.builtIns + FilmLUTCatalog.presets
for preset in shelfPresets {
    var settings = AdjustmentSettings()
    settings.lutIntensity = preset.recommendedIntensity
    settings.preserveLuminance = 0.65
    settings.protectSkin = 0.65
    settings.protectNeutrals = 0.5
    let rendered = try engine.process(shelfSource, settings: settings, lut: preset.cube,
                                      outputColorSpace: .sRGB).image
    try writeJPEG(rendered, name: "raw-lut-\(preset.id).jpg", quality: 0.9)
}
// Neutral reference frame for the same grid.
let shelfNeutral = try engine.process(shelfSource, settings: .init(), lut: nil,
                                      outputColorSpace: .sRGB).image
try writeJPEG(shelfNeutral, name: "raw-lut-original.jpg", quality: 0.9)

// Catalogue order + labels so the composer cannot drift from the real list.
let lutOrder = shelfPresets.map { ["id": $0.id, "name": $0.name, "group": $0.group.rawValue] }
try JSONSerialization.data(withJSONObject: lutOrder, options: [.prettyPrinted])
    .write(to: outputDir.appendingPathComponent("lut-order.json"))

// MARK: - 3. Five-zone tone response (measured from the engine, not plotted by hand)

// A 1024-step luminance ramp through the same curve the UI writes.
func rampImage(steps: Int) -> CIImage {
    let width = steps, height = 8
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let value = UInt8((Double(x) / Double(steps - 1) * 255).rounded())
            let offset = (y * width + x) * 4
            bytes[offset] = value; bytes[offset + 1] = value
            bytes[offset + 2] = value; bytes[offset + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                     bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                     provider: provider, decode: nil, shouldInterpolate: false,
                     intent: .defaultIntent)!
    return CIImage(cgImage: cg)
}

let curveSettings = AdjustmentSettings()
var zoned = curveSettings
zoned.tonalCurve = TonalCurveSettings(blacksEV: -0.60, shadowsEV: 0.35, midtonesEV: 0.20,
                                      highlightsEV: -0.45, whitesEV: 0.25)
let rampIn = rampImage(steps: 1024)
let rampOut = try engine.process(rampIn, settings: zoned, lut: nil, outputColorSpace: .sRGB).image
let inBytes = rasterize(rampIn).rgba
let outBytes = rasterize(rampOut).rgba
var curveSamples: [(Double, Double)] = []
for x in stride(from: 0, to: 1024, by: 8) {
    let i = (4 * 1024 + x) * 4  // middle row
    curveSamples.append((Double(inBytes[i]) / 255, Double(outBytes[i]) / 255))
}
let curveJSON = curveSamples.map { ["in": $0.0, "out": $0.1] }
let curveData = try JSONSerialization.data(withJSONObject: curveJSON, options: [.prettyPrinted])
try curveData.write(to: outputDir.appendingPathComponent("tone-curve.json"))
print("wrote tone-curve.json (\(curveSamples.count) samples)")

// Same five-zone curve applied to the valley fixture.
let zonedOut = try engine.process(valley.image, settings: zoned, lut: nil, outputColorSpace: .sRGB).image
try writeJPEG(scaled(zonedOut, longEdge: 1280), name: "raw-valley-zones.jpg")

// MARK: - 4. Local mask coverage (real LocalMaskEngine output)

let reference = try engine.maskReferenceImage(valley.image, settings: .init())
let radialMask = LocalMask(
    name: "径向示例", kind: .radial,
    start: MaskPoint(x: 0.72, y: 0.62), end: MaskPoint(x: 0.92, y: 0.85),
    radius: 0.20, feather: 0.75, exposureEV: 0.55, saturation: 1.05,
    highlightProtection: 0.5, colorProtection: 0.5)
let coverage = try engine.localMaskImage(radialMask, reference: reference)
let coverageGray = coverage.applyingFilter("CIColorMatrix", parameters: [
    "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
    "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
    "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
]).cropped(to: valley.image.extent)
try writeRaw(scaled(coverageGray, longEdge: 1280), name: "raw-mask-coverage.png")

var masked = AdjustmentSettings()
masked.masks = [radialMask]
let maskedOut = try engine.process(valley.image, settings: masked, lut: nil, outputColorSpace: .sRGB).image
try writeJPEG(scaled(maskedOut, longEdge: 1280), name: "raw-valley-masked.jpg")

// Luminance-range mask: shows that range masks key on measured pixels, not geometry.
let rangeMask = LocalMask(
    name: "亮度范围示例", kind: .luminance,
    radius: 0.12, feather: 0.5, exposureEV: -0.45,
    restrictLuminance: true, luminanceMin: 0.62, luminanceMax: 1.0, rangeSoftness: 0.18)
let rangeCoverage = try engine.localMaskImage(rangeMask, reference: reference)
let rangeGray = rangeCoverage.applyingFilter("CIColorMatrix", parameters: [
    "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
    "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
    "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
]).cropped(to: valley.image.extent)
try writeRaw(scaled(rangeGray, longEdge: 1280), name: "raw-mask-range.png")

var rangeApplied = AdjustmentSettings()
rangeApplied.masks = [rangeMask]
let rangeOut = try engine.process(valley.image, settings: rangeApplied, lut: nil,
                                  outputColorSpace: .sRGB).image
try writeJPEG(scaled(rangeOut, longEdge: 1280), name: "raw-valley-range-mask.jpg")

print("DONE")

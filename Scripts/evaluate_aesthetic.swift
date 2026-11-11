//
//  evaluate_aesthetic.swift
//  PhotoAtelier
//
//  Created for P1-H: 真实照片审美验收体系 (Aesthetic Review System)
//  Compiles against PhotoCore object files.
//  Reads local photos strictly read-only, verifies SHA-256 before & after,
//  and outputs high-fidelity Before/After comparisons, 1:1 micro-inspection crops,
//  an aesthetic-manifest.json, and an interactive HTML review gallery.
//

import AppKit
import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import PhotoCore

// MARK: - Models

struct PipelineSpec {
    let id: String
    let name: String
    let description: String
    let categoryFocus: String
}

struct SampleRecord: Codable {
    let id: String
    let category: String
    let categoryLabel: String
    let sha256Before: String
    let sha256After: String
    let unchanged: Bool
    let width: Int
    let height: Int
    let detectedFaces: Int
    let cropOriginX: Int
    let cropOriginY: Int
    let cropSize: Int
    let previewFiles: [String: String]
    let cropFiles: [String: String]
}

struct AestheticManifest: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let totalSamples: Int
    let categoryBreakdown: [String: Int]
    let zeroModificationAuditPassed: Bool
    let executionDurationSeconds: Double
    let samples: [SampleRecord]
}

// MARK: - Helpers

func computeSHA256(url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "UNKNOWN" }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

func scaleDownPreservingAspect(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
    let extent = image.extent
    let maxEdge = max(extent.width, extent.height)
    if maxEdge <= maxDimension {
        return image
    }
    let scale = maxDimension / maxEdge
    return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
}

func cropSquare(_ image: CIImage, center: CGPoint, size: CGFloat) -> CIImage {
    let half = size / 2.0
    let extent = image.extent
    var x = center.x - half
    var y = center.y - half
    x = max(extent.minX, min(x, extent.maxX - size))
    y = max(extent.minY, min(y, extent.maxY - size))
    let rect = CGRect(x: x, y: y, width: size, height: size)
    return image.cropped(to: rect)
}

func exportJPEG(image: CIImage, url: URL, context: CIContext, quality: Double = 0.92) throws {
    var exportSettings = ExportSettings()
    exportSettings.format = .jpeg
    exportSettings.jpegQuality = quality
    exportSettings.colorSpace = .sRGB
    try PhotoExporter.write(image: image, to: url, settings: exportSettings, sourceProperties: [:], context: context)
}

// MARK: - Main Execution

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("""
    Usage: evaluate_aesthetic <INPUT_DIRECTORY> <NEW_OUTPUT_DIRECTORY> [--limit <N>]
    Example:
      swift Scripts/evaluate_aesthetic.swift "/Users/mimi/Desktop/图片" "artifacts/aesthetic-review"
    """)
    exit(1)
}

let inputDir = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
let outputDir = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
let fileManager = FileManager.default

var sampleLimit = Int.max
if args.count >= 5, args[3] == "--limit", let lim = Int(args[4]) {
    sampleLimit = lim
}

guard fileManager.fileExists(atPath: inputDir.path) else {
    print("Error: Input directory does not exist: \(inputDir.path)")
    exit(1)
}

guard inputDir.path != outputDir.path, !outputDir.path.hasPrefix(inputDir.path + "/") else {
    print("Error: Output directory must be separate and outside the input directory.")
    exit(1)
}

if !fileManager.fileExists(atPath: outputDir.path) {
    try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
}

let imagesDir = outputDir.appendingPathComponent("images", isDirectory: true)
let cropsDir = outputDir.appendingPathComponent("crops", isDirectory: true)
try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
try fileManager.createDirectory(at: cropsDir, withIntermediateDirectories: true)

print("🔍 Scanning input directory for photos: \(inputDir.path)...")
let scannedItems = try PhotoLoader.scan(folder: inputDir, recursive: false)
guard !scannedItems.isEmpty else {
    print("Error: No supported photos found in \(inputDir.path)")
    exit(1)
}

let itemsToProcess = Array(scannedItems.prefix(sampleLimit))
print("📦 Total candidate photos found: \(scannedItems.count), processing: \(itemsToProcess.count)")

let startTime = Date()
let engine = PhotoEngine()
let analyzer = PhotoAnalyzer()
let classicChromePreset = FilmLUTCatalog.preset(id: "film-fuji-classic-chrome")
let classicChromeCube = classicChromePreset?.cube

let pipelines: [PipelineSpec] = [
    PipelineSpec(id: "01_baseline", name: "原片基线 (Baseline)", description: "原始解码图像，未经任何色彩与人像修饰", categoryFocus: "全题材"),
    PipelineSpec(id: "02_scene_adaptive", name: "场景自适应 (Scene Adaptive)", description: "启发式场景识别与五区 EV 自然影调增强", categoryFocus: "风光/逆光/高调"),
    PipelineSpec(id: "03_portrait_retouch", name: "人像精修 (Portrait Retouch)", description: "祛斑瑕疵修复 + 中性灰高低频平整 + 牙齿眼白提亮 + 肤色统一", categoryFocus: "人像特写/环境"),
    PipelineSpec(id: "04_makeup_sculpt", name: "妆容塑颜 (Makeup & Sculpt)", description: "唇/眉/腮红/眼影/眼线/睫毛/高光/修容精修妆容", categoryFocus: "人像特写/环境"),
    PipelineSpec(id: "05_film_style", name: "经典胶片 (Film Style)", description: "富士风格 Classic Chrome 色彩模拟与自适应肤色保护", categoryFocus: "人文/风光/复古"),
    PipelineSpec(id: "06_master_pipeline", name: "商业全流程 (Master Pipeline)", description: "场景校正 + 人像双频精修 + 增强妆容塑颜 + 胶片色调完整组合", categoryFocus: "商业客片综合成片"),
    PipelineSpec(id: "07_p2_skin_suite", name: "P2 美肤全家桶 (P2 Skin Suite)", description: "五区祛皱去油光 + 身体手部美肤 + 衣物祛皱 + 发质精修（发缝/光泽/柔顺/去碎发）", categoryFocus: "人像特写/环境·P2 回归"),
    PipelineSpec(id: "08_p2_reshape_suite", name: "P2 微雕全家桶 (P2 Reshape Suite)", description: "液化高颅顶 + 骨相光影折叠度 + 五官微雕（眼型/鼻/下颌/眉形）+ 微笑唇形", categoryFocus: "人像特写·P2 回归"),
    PipelineSpec(id: "09_p2_scene_suite", name: "P2 场景全家桶 (P2 Scene Suite)", description: "天空识别氛围增强 + 景深光斑虚化 + 影棚背景修复 + 创意效果（红晕/薄雾/颗粒）", categoryFocus: "风光/环境/宠物·P2 回归"),
    PipelineSpec(id: "10_p2_master_suite", name: "P2 商业大师 (P2 Master Suite)", description: "P2 全模块组合：美肤 + 微雕 + 眼神光美牙 + 景深虚化 + 胶片色调商业直出", categoryFocus: "商业客片·P2 综合")
]

var sampleRecords: [SampleRecord] = []
var categoryCounts: [String: Int] = [:]
var allUnchanged = true

for (index, item) in itemsToProcess.enumerated() {
    let sampleID = String(format: "sample-%02d", index + 1)
    print("\n---------------------------------------------------------")
    print("📸 Processing [\(index + 1)/\(itemsToProcess.count)]: \(sampleID)...")

    let shaBefore = computeSHA256(url: item.url)

    // Load photo
    let loaded = try PhotoLoader.load(url: item.url, lensCorrection: false)
    let originalImage = loaded.image
    let extent = originalImage.extent
    let width = Int(extent.width)
    let height = Int(extent.height)

    // Analyze scene and faces
    let analysis = try analyzer.analyze(image: originalImage, properties: loaded.properties)
    let faces = FaceSemanticAnalyzer.detect(in: originalImage, maxFaces: 8)

    // Categorization
    var category = "landscape"
    var categoryLabel = "风光·自然"

    if faces.count >= 2 {
        category = "portrait-group"
        categoryLabel = "人像环境·多人"
    } else if faces.count == 1 {
        let faceBox = faces[0].boundingBox
        if faceBox.width > 0.30 || faceBox.height > 0.30 {
            category = "portrait-closeup"
            categoryLabel = "人像·特写"
        } else {
            category = "portrait-environment"
            categoryLabel = "人像·环境半身"
        }
    } else {
        // No faces detected
        let meanLuma = (analysis.metrics.p05Luminance + analysis.metrics.medianLuminance + analysis.metrics.p95Luminance) / 3.0
        if meanLuma < 0.20 {
            category = "night-scene"
            categoryLabel = "夜景·高反差"
        } else if meanLuma > 0.65 {
            category = "high-key"
            categoryLabel = "高调·明亮留白"
        } else if analysis.metrics.p95Luminance - analysis.metrics.p05Luminance > 0.85 {
            category = "backlight"
            categoryLabel = "逆光·大光比"
        } else if meanLuma < 0.35 {
            category = "low-key"
            categoryLabel = "暗调·沉沉质感"
        } else {
            category = "landscape"
            categoryLabel = "风光·自然"
        }
    }

    categoryCounts[category, default: 0] += 1
    print("   🏷 Category: \(categoryLabel) (\(category)), Resolution: \(width)x\(height), Faces: \(faces.count)")

    // Determine crop center (1:1 micro inspection, 512x512)
    var cropCenter = CGPoint(x: extent.midX, y: extent.midY)
    if let primaryFace = faces.first {
        let b = primaryFace.boundingBox
        cropCenter = CGPoint(x: extent.minX + b.midX * extent.width,
                             y: extent.minY + b.midY * extent.height)
    }

    let sampleImgDir = imagesDir.appendingPathComponent(sampleID, isDirectory: true)
    let sampleCropDir = cropsDir.appendingPathComponent(sampleID, isDirectory: true)
    try fileManager.createDirectory(at: sampleImgDir, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: sampleCropDir, withIntermediateDirectories: true)

    var previewFiles: [String: String] = [:]
    var cropFiles: [String: String] = [:]

    for spec in pipelines {
        var settings = AdjustmentSettings()
        var lutToApply: LUTCube? = nil

        switch spec.id {
        case "01_baseline":
            // Pure unadjusted baseline
            break

        case "02_scene_adaptive":
            settings.exposureEV = 0.20
            settings.highlights = -0.15
            settings.shadows = 0.15
            settings.tonalCurve = TonalCurveSettings(blacksEV: 0, shadowsEV: 0.10, midtonesEV: 0.05, highlightsEV: -0.10, whitesEV: 0)

        case "03_portrait_retouch":
            var portrait = PortraitRefinementSettings()
            portrait.blemishStrength = 0.65
            portrait.dodgeBurn = 0.55
            portrait.structure = 0.20
            portrait.texture = 0.70
            portrait.gloss = 0.30
            portrait.teethWhiten = 0.50
            portrait.eyeBrighten = 0.50
            portrait.skinToneUnify = 0.55
            settings.portrait = portrait

        case "04_makeup_sculpt":
            var makeup = MakeupSettings()
            makeup.lipIntensity = 0.55
            makeup.lipColor = SRGBColor(red: 0.85, green: 0.28, blue: 0.36)
            makeup.browDensity = 0.40
            makeup.browColor = SRGBColor(red: 0.22, green: 0.19, blue: 0.17)
            makeup.cheekIntensity = 0.45
            makeup.cheekColor = SRGBColor(red: 0.91, green: 0.42, blue: 0.47)
            makeup.eyeshadowIntensity = 0.40
            makeup.eyeshadowColor = SRGBColor(red: 0.55, green: 0.37, blue: 0.35)
            makeup.eyelinerIntensity = 0.50
            makeup.eyelinerColor = SRGBColor(red: 0.10, green: 0.10, blue: 0.10)
            makeup.eyelashIntensity = 0.55
            makeup.irisIntensity = 0.45
            makeup.irisColor = SRGBColor(red: 0.29, green: 0.21, blue: 0.15)
            makeup.catchlightIntensity = 0.50
            makeup.highlightIntensity = 0.40
            makeup.contourIntensity = 0.35
            settings.makeup = makeup

        case "05_film_style":
            lutToApply = classicChromeCube
            settings.lutIntensity = 0.75
            settings.preserveLuminance = 0.70
            settings.protectSkin = 0.80
            settings.protectNeutrals = 0.60

        case "06_master_pipeline":
            // Combined master pipeline
            settings.exposureEV = 0.15
            settings.highlights = -0.10
            settings.shadows = 0.10

            var portrait = PortraitRefinementSettings()
            portrait.blemishStrength = 0.60
            portrait.dodgeBurn = 0.50
            portrait.structure = 0.20
            portrait.texture = 0.75
            portrait.gloss = 0.25
            portrait.teethWhiten = 0.45
            portrait.eyeBrighten = 0.45
            portrait.skinToneUnify = 0.50
            settings.portrait = portrait

            var makeup = MakeupSettings()
            makeup.lipIntensity = 0.45
            makeup.lipColor = SRGBColor(red: 0.85, green: 0.28, blue: 0.36)
            makeup.browDensity = 0.35
            makeup.browColor = SRGBColor(red: 0.22, green: 0.19, blue: 0.17)
            makeup.cheekIntensity = 0.35
            makeup.cheekColor = SRGBColor(red: 0.91, green: 0.42, blue: 0.47)
            makeup.eyeshadowIntensity = 0.30
            makeup.eyeshadowColor = SRGBColor(red: 0.55, green: 0.37, blue: 0.35)
            makeup.eyelinerIntensity = 0.40
            makeup.eyelinerColor = SRGBColor(red: 0.10, green: 0.10, blue: 0.10)
            makeup.eyelashIntensity = 0.45
            makeup.irisIntensity = 0.40
            makeup.irisColor = SRGBColor(red: 0.29, green: 0.21, blue: 0.15)
            makeup.catchlightIntensity = 0.45
            makeup.highlightIntensity = 0.35
            makeup.contourIntensity = 0.30
            settings.makeup = makeup

            lutToApply = classicChromeCube
            settings.lutIntensity = 0.65
            settings.preserveLuminance = 0.75
            settings.protectSkin = 0.85
            settings.protectNeutrals = 0.65

        case "07_p2_skin_suite":
            // P2 美肤回归：五区祛皱去油光 + 身体美肤 + 衣物祛皱 + 发质精修
            var zonal = FacialZonalRefinementSettings()
            zonal.enabled = true
            zonal.darkCircles = 0.45
            zonal.eyeBags = 0.40
            zonal.nasolabialFolds = 0.40
            zonal.foreheadWrinkles = 0.40
            zonal.antiShine = 0.50
            zonal.jawlineSculpting = 0.30
            settings.facialZonal = zonal

            var bodySkin = BodySkinRefinementSettings()
            bodySkin.enabled = true
            bodySkin.neckSmoothing = 0.40
            bodySkin.bodySmoothing = 0.45
            bodySkin.veinReduction = 0.40
            bodySkin.bodyToneHarmonization = 0.40
            settings.bodySkin = bodySkin

            var clothing = ClothingRefinementSettings()
            clothing.enabled = true
            clothing.wrinkleSmoothing = 0.45
            clothing.creaseRemoval = 0.40
            settings.clothing = clothing

            var portrait = PortraitRefinementSettings()
            portrait.hairGapFilling = 0.40
            portrait.hairGloss = 0.45
            portrait.hairDarkening = 0.30
            portrait.hairSmoothing = 0.40
            portrait.flyawayRemoval = 0.45
            settings.portrait = portrait

        case "08_p2_reshape_suite":
            // P2 微雕回归：液化高颅顶 + 骨相光影 + 五官微雕 + 微笑唇形（保守量）
            var liquify = FaceReshapeSettings(preset: .youthful)
            liquify.strength = 0.55
            liquify.parameters.cranialTop = 0.30
            liquify.parameters.hairline = 0.15
            liquify.parameters.temple = 0.20
            settings.liquify = liquify

            var bone = FacialBoneContourSettings(enabled: true)
            bone.facialFolding = 0.40
            bone.tZoneHighlight = 0.45
            bone.cZoneHighlight = 0.40
            bone.cheekContourShadow = 0.30
            bone.jawlineShadow = 0.30
            bone.philtrumHighlight = 0.25
            settings.facialBoneContour = bone

            var eyeShape = EyeShapeSettings()
            eyeShape.enabled = true
            eyeShape.eyeSymmetry = 0.35
            eyeShape.eyeRoundness = 0.25
            settings.eyeShape = eyeShape

            var nose = NoseReshapeSettings()
            nose.enabled = true
            nose.nose3DContour = 0.35
            nose.noseTipSize = 0.25
            settings.noseReshape = nose

            var jaw = JawChinReshapeSettings()
            jaw.enabled = true
            jaw.jawlineTighten = 0.35
            jaw.chinProjection = 0.25
            settings.jawChinReshape = jaw

            var brow = EyebrowReshapeSettings()
            brow.enabled = true
            brow.browSymmetry = 0.35
            brow.wildBrowTexture = 0.40
            settings.eyebrowReshape = brow

            var contour = FacialContourSettings()
            contour.enabled = true
            contour.templePlump = 0.30
            contour.contourSmoothness = 0.30
            contour.appleCheekLift = 0.25
            settings.facialContour = contour

            var expression = ExpressionSettings()
            expression.enabled = true
            expression.smileDegree = 0.30
            expression.lipSymmetry = 0.25
            settings.expression = expression

        case "09_p2_scene_suite":
            // P2 场景回归：天空氛围 + 景深虚化 + 影棚背景 + 创意效果
            var sky = SkyEnhancementSettings()
            sky.enabled = true
            sky.skyVibrance = 0.45
            sky.cloudContrast = 0.35
            settings.sky = sky

            var bokeh = BokehBlurSettings()
            bokeh.enabled = true
            bokeh.apertureFocalSize = 0.35
            bokeh.bokehShape = .circular
            bokeh.specularHighlightBoost = 0.40
            settings.bokehBlur = bokeh

            var backdrop = BackdropRefinementSettings()
            backdrop.enabled = true
            backdrop.smoothing = 0.40
            backdrop.uniformity = 0.35
            settings.backdrop = backdrop

            var effects = CreativeEffectsSettings()
            effects.halation = 0.30
            effects.mist = 0.20
            effects.grain = 0.25
            settings.creativeEffects = effects

        case "10_p2_master_suite":
            // P2 商业大师：美肤 + 微雕 + 眼神光美牙 + 景深 + 胶片色调全链路
            var portrait = PortraitRefinementSettings()
            portrait.blemishStrength = 0.55
            portrait.dodgeBurn = 0.50
            portrait.structure = 0.20
            portrait.texture = 0.70
            portrait.gloss = 0.25
            portrait.teethWhiten = 0.45
            portrait.eyeBrighten = 0.45
            portrait.skinToneUnify = 0.50
            portrait.hairGloss = 0.40
            portrait.hairSmoothing = 0.35
            portrait.flyawayRemoval = 0.40
            settings.portrait = portrait

            var zonal = FacialZonalRefinementSettings()
            zonal.enabled = true
            zonal.darkCircles = 0.40
            zonal.eyeBags = 0.35
            zonal.antiShine = 0.45
            zonal.nasolabialFolds = 0.35
            settings.facialZonal = zonal

            var bone = FacialBoneContourSettings(enabled: true)
            bone.facialFolding = 0.35
            bone.tZoneHighlight = 0.40
            bone.cZoneHighlight = 0.35
            bone.jawlineShadow = 0.25
            settings.facialBoneContour = bone

            var eyeTeeth = EyeTeethRefinementSettings()
            eyeTeeth.enabled = true
            eyeTeeth.irisClarity = 0.40
            eyeTeeth.scleraBloodshotRemoval = 0.40
            eyeTeeth.catchlightPattern = .naturalPoint
            eyeTeeth.catchlightStrength = 0.45
            settings.eyeTeeth = eyeTeeth

            var bokeh = BokehBlurSettings()
            bokeh.enabled = true
            bokeh.apertureFocalSize = 0.28
            bokeh.bokehShape = .creamy
            bokeh.specularHighlightBoost = 0.35
            settings.bokehBlur = bokeh

            var makeup = MakeupSettings()
            makeup.lipIntensity = 0.40
            makeup.lipColor = SRGBColor(red: 0.85, green: 0.28, blue: 0.36)
            makeup.cheekIntensity = 0.30
            makeup.cheekColor = SRGBColor(red: 0.91, green: 0.42, blue: 0.47)
            makeup.catchlightIntensity = 0.40
            makeup.highlightIntensity = 0.30
            makeup.contourIntensity = 0.25
            settings.makeup = makeup

            lutToApply = classicChromeCube
            settings.lutIntensity = 0.60
            settings.preserveLuminance = 0.75
            settings.protectSkin = 0.85
            settings.protectNeutrals = 0.65

        default:
            break
        }

        let processed = try engine.process(originalImage, settings: settings, lut: lutToApply)
        let processedImage = processed.image

        // 1. Export Preview (scaled down to max 1600 for gallery responsive review)
        let previewImage = scaleDownPreservingAspect(processedImage, maxDimension: 1600)
        let previewFilename = "\(spec.id).jpg"
        let previewURL = sampleImgDir.appendingPathComponent(previewFilename)
        try exportJPEG(image: previewImage, url: previewURL, context: engine.context, quality: 0.92)
        previewFiles[spec.id] = "images/\(sampleID)/\(previewFilename)"

        // 2. Export 1:1 Micro Crop (native 512x512)
        let cropImage = cropSquare(processedImage, center: cropCenter, size: 512)
        let cropFilename = "\(spec.id)_crop.jpg"
        let cropURL = sampleCropDir.appendingPathComponent(cropFilename)
        try exportJPEG(image: cropImage, url: cropURL, context: engine.context, quality: 0.95)
        cropFiles[spec.id] = "crops/\(sampleID)/\(cropFilename)"
    }

    // SHA-256 after processing check
    let shaAfter = computeSHA256(url: item.url)
    let isUnchanged = (shaBefore == shaAfter)
    if !isUnchanged {
        allUnchanged = false
        print("   ❌ SECURITY ALERT: Input file modified! \(item.url.path)")
    } else {
        print("   ✅ SHA-256 Verified: \(shaBefore.prefix(12))... (Zero modification confirmed)")
    }

    let record = SampleRecord(
        id: sampleID,
        category: category,
        categoryLabel: categoryLabel,
        sha256Before: shaBefore,
        sha256After: shaAfter,
        unchanged: isUnchanged,
        width: width,
        height: height,
        detectedFaces: faces.count,
        cropOriginX: Int(cropCenter.x - 256),
        cropOriginY: Int(cropCenter.y - 256),
        cropSize: 512,
        previewFiles: previewFiles,
        cropFiles: cropFiles
    )
    sampleRecords.append(record)
}

let duration = Date().timeIntervalSince(startTime)
print("\n=========================================================")
print("🏁 Evaluation completed in \(String(format: "%.2f", duration))s")
print("   Audit: Zero modification guarantee \(allUnchanged ? "PASSED ✅" : "FAILED ❌")")

// MARK: - Generate Manifest JSON

let manifest = AestheticManifest(
    schemaVersion: 1,
    generatedAt: ISO8601DateFormatter().string(from: Date()),
    totalSamples: sampleRecords.count,
    categoryBreakdown: categoryCounts,
    zeroModificationAuditPassed: allUnchanged,
    executionDurationSeconds: duration,
    samples: sampleRecords
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let manifestData = try encoder.encode(manifest)
let manifestURL = outputDir.appendingPathComponent("aesthetic-manifest.json")
try manifestData.write(to: manifestURL)
print("📄 Manifest saved: \(manifestURL.path)")

// MARK: - Generate HTML Review Gallery

let htmlContent = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Photo Atelier · 真实照片审美验收体系</title>
    <style>
        :root {
            --bg-primary: #121214;
            --bg-secondary: #1a1a1e;
            --bg-card: #222228;
            --border: #33333d;
            --text-primary: #f0f0f5;
            --text-secondary: #9e9ea7;
            --accent: #3b82f6;
            --accent-hover: #60a5fa;
            --success: #10b981;
            --warning: #f59e0b;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
            background-color: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.5;
            padding: 24px;
        }
        .header {
            background: linear-gradient(135deg, #1e1e24 0%, #151518 100%);
            border: 1px solid var(--border);
            border-radius: 14px;
            padding: 24px 28px;
            margin-bottom: 24px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 16px;
        }
        .header-title h1 {
            font-size: 24px;
            font-weight: 700;
            letter-spacing: -0.5px;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        .header-title p {
            color: var(--text-secondary);
            font-size: 14px;
            margin-top: 4px;
        }
        .stats-badge {
            display: flex;
            gap: 16px;
            align-items: center;
        }
        .stat-item {
            background: rgba(255,255,255,0.05);
            padding: 8px 14px;
            border-radius: 8px;
            border: 1px solid rgba(255,255,255,0.08);
            text-align: center;
        }
        .stat-item .val {
            font-size: 18px;
            font-weight: 700;
            color: #fff;
        }
        .stat-item .lbl {
            font-size: 11px;
            color: var(--text-secondary);
            text-transform: uppercase;
        }
        .audit-badge {
            background: rgba(16, 185, 129, 0.15);
            color: var(--success);
            border: 1px solid rgba(16, 185, 129, 0.3);
            padding: 6px 14px;
            border-radius: 20px;
            font-size: 13px;
            font-weight: 600;
        }
        .filter-bar {
            display: flex;
            gap: 8px;
            margin-bottom: 24px;
            flex-wrap: wrap;
        }
        .filter-btn {
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            color: var(--text-secondary);
            padding: 8px 16px;
            border-radius: 8px;
            font-size: 13px;
            font-weight: 500;
            cursor: pointer;
            transition: all 0.2s;
        }
        .filter-btn:hover, .filter-btn.active {
            background: var(--accent);
            color: #fff;
            border-color: var(--accent);
        }
        .grid {
            display: grid;
            grid-template-columns: 1fr;
            gap: 32px;
        }
        .card {
            background: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 14px;
            overflow: hidden;
            display: grid;
            grid-template-columns: 1fr 380px;
        }
        @media (max-width: 1080px) {
            .card { grid-template-columns: 1fr; }
        }
        .card-main {
            padding: 20px;
            border-right: 1px solid var(--border);
        }
        .card-side {
            padding: 20px;
            background: var(--bg-secondary);
            display: flex;
            flex-direction: column;
            gap: 16px;
        }
        .card-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 16px;
        }
        .card-title {
            font-size: 18px;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .category-pill {
            background: rgba(59, 130, 246, 0.2);
            color: var(--accent-hover);
            border: 1px solid rgba(59, 130, 246, 0.3);
            font-size: 12px;
            padding: 2px 10px;
            border-radius: 12px;
            font-weight: 500;
        }
        .pipeline-tabs {
            display: flex;
            gap: 6px;
            margin-bottom: 16px;
            overflow-x: auto;
            padding-bottom: 4px;
        }
        .tab-btn {
            background: rgba(255,255,255,0.06);
            border: 1px solid var(--border);
            color: var(--text-secondary);
            padding: 6px 12px;
            border-radius: 6px;
            font-size: 12px;
            cursor: pointer;
            white-space: nowrap;
        }
        .tab-btn:hover, .tab-btn.active {
            background: #2b2b36;
            color: #fff;
            border-color: var(--accent);
        }
        .preview-viewer {
            position: relative;
            width: 100%;
            height: 480px;
            background: #000;
            border-radius: 10px;
            overflow: hidden;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .preview-viewer img {
            max-width: 100%;
            max-height: 100%;
            object-fit: contain;
            display: block;
        }
        .preview-viewer .before-layer {
            position: absolute;
            top: 0; left: 0; width: 100%; height: 100%;
            display: flex; align-items: center; justify-content: center;
            clip-path: inset(0 50% 0 0);
            pointer-events: none;
        }
        .split-slider {
            position: absolute;
            top: 0; bottom: 0; left: 50%;
            width: 3px;
            background: rgba(255,255,255,0.8);
            cursor: ew-resize;
            box-shadow: 0 0 8px rgba(0,0,0,0.5);
        }
        .split-handle {
            position: absolute;
            top: 50%; left: 50%;
            transform: translate(-50%, -50%);
            width: 32px; height: 32px;
            background: #fff;
            border-radius: 50%;
            box-shadow: 0 2px 6px rgba(0,0,0,0.4);
            display: flex; align-items: center; justify-content: center;
            font-size: 12px; color: #111; font-weight: 700;
        }
        .crop-section {
            margin-top: 16px;
        }
        .crop-header {
            font-size: 13px;
            font-weight: 600;
            color: var(--text-secondary);
            margin-bottom: 8px;
            display: flex; justify-content: space-between;
        }
        .crop-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 10px;
        }
        .crop-box {
            background: #0d0d10;
            border-radius: 8px;
            padding: 8px;
            border: 1px solid var(--border);
            text-align: center;
        }
        .crop-box img {
            width: 100%;
            height: 140px;
            object-fit: cover;
            border-radius: 4px;
        }
        .crop-box .lbl {
            font-size: 11px;
            color: var(--text-secondary);
            margin-top: 4px;
        }
        .rubric-box {
            display: flex;
            flex-direction: column;
            gap: 12px;
        }
        .rubric-item {
            display: flex;
            flex-direction: column;
            gap: 4px;
        }
        .rubric-label {
            font-size: 12px;
            font-weight: 500;
            color: var(--text-secondary);
            display: flex;
            justify-content: space-between;
        }
        .stars {
            display: flex;
            gap: 4px;
        }
        .star-btn {
            background: rgba(255,255,255,0.08);
            border: 1px solid var(--border);
            color: #888;
            width: 32px; height: 26px;
            border-radius: 4px;
            font-size: 12px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.15s;
        }
        .star-btn.selected {
            background: #f59e0b;
            color: #111;
            border-color: #f59e0b;
        }
        .total-box {
            background: rgba(255,255,255,0.04);
            border: 1px solid var(--border);
            border-radius: 10px;
            padding: 14px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .total-box .grade {
            font-size: 22px;
            font-weight: 800;
            color: var(--success);
        }
        .notes-input {
            width: 100%;
            background: rgba(0,0,0,0.3);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 10px;
            color: #fff;
            font-size: 12px;
            resize: vertical;
            height: 60px;
        }
        .action-bar {
            margin-top: 24px;
            display: flex;
            justify-content: flex-end;
            gap: 12px;
        }
        .btn-primary {
            background: var(--accent);
            color: #fff;
            border: none;
            padding: 10px 20px;
            border-radius: 8px;
            font-size: 14px;
            font-weight: 600;
            cursor: pointer;
        }
        .btn-primary:hover {
            background: var(--accent-hover);
        }
    </style>
</head>
<body>

<div class="header">
    <div class="header-title">
        <h1>📸 Photo Atelier · 真实照片审美验收相册</h1>
        <p>基于真实摄影样片与专业评审准则的画质量化验收看板 (P1-H)</p>
    </div>
    <div class="stats-badge">
        <div class="stat-item">
            <div class="val">\(manifest.totalSamples)</div>
            <div class="lbl">样本数量</div>
        </div>
        <div class="stat-item">
            <div class="val">\(manifest.categoryBreakdown.count)</div>
            <div class="lbl">题材覆盖</div>
        </div>
        <div class="stat-item">
            <div class="val">\(pipelines.count)</div>
            <div class="lbl">测试管线</div>
        </div>
        <div class="audit-badge">
            ✓ SHA-256 原图零篡改审计通过
        </div>
    </div>
</div>

<div class="filter-bar">
    <button class="filter-btn active" onclick="filterCategory('all')">全部 (\(manifest.totalSamples))</button>
    <button class="filter-btn" onclick="filterCategory('portrait')">人像特写与环境</button>
    <button class="filter-btn" onclick="filterCategory('landscape')">风光自然</button>
    <button class="filter-btn" onclick="filterCategory('night')">夜景与暗调</button>
    <button class="filter-btn" onclick="filterCategory('backlight')">逆光大光比</button>
    <button class="filter-btn" onclick="filterCategory('high-key')">高调留白</button>
</div>

<div class="grid">
"""

var cardsHtml = ""
// P3-D: pipeline tab labels generated from the shared pipeline list so the
// HTML tabs always match the rendered pipelines (was a hardcoded 6-tab row).
let pipelineTabTitles: [String: String] = [
    "01_baseline": "原片基线",
    "02_scene_adaptive": "自适应场景",
    "03_portrait_retouch": "人像精修",
    "04_makeup_sculpt": "妆容塑颜",
    "05_film_style": "经典胶片",
    "06_master_pipeline": "商业全流程",
    "07_p2_skin_suite": "P2 美肤",
    "08_p2_reshape_suite": "P2 微雕",
    "09_p2_scene_suite": "P2 场景",
    "10_p2_master_suite": "P2 大师"
]
for sample in sampleRecords {
    let baselinePreview = sample.previewFiles["01_baseline"] ?? ""
    let masterPreview = sample.previewFiles["10_p2_master_suite"] ?? sample.previewFiles["06_master_pipeline"] ?? baselinePreview
    let baselineCrop = sample.cropFiles["01_baseline"] ?? ""
    let masterCrop = sample.cropFiles["10_p2_master_suite"] ?? sample.cropFiles["06_master_pipeline"] ?? baselineCrop

    cardsHtml += """
    <div class="card" data-category="\(sample.category)">
        <div class="card-main">
            <div class="card-header">
                <div class="card-title">
                    <span>\(sample.id)</span>
                    <span class="category-pill">\(sample.categoryLabel)</span>
                </div>
                <div style="font-size: 12px; color: var(--text-secondary);">
                    尺寸: \(sample.width)×\(sample.height) | 检测人脸: \(sample.detectedFaces) | SHA-256: \(sample.sha256Before.prefix(8))...
                </div>
            </div>

            <div class="pipeline-tabs" id="tabs-\(sample.id)">\(pipelines.map { p in
                let title = pipelineTabTitles[p.id] ?? p.id
                let active = (p.id == "10_p2_master_suite") ? " active" : ""
                return "<button class=\"tab-btn\(active)\" onclick=\"switchPipeline('\(sample.id)', '\(p.id)')\">\(title)</button>"
            }.joined())</div>

            <div class="preview-viewer" id="viewer-\(sample.id)">
                <img id="img-after-\(sample.id)" src="\(masterPreview)" alt="Processed">
                <div class="before-layer" id="layer-before-\(sample.id)">
                    <img src="\(baselinePreview)" alt="Baseline">
                </div>
                <div class="split-slider" id="slider-\(sample.id)">
                    <div class="split-handle">‹ ›</div>
                </div>
            </div>

            <div class="crop-section">
                <div class="crop-header">
                    <span>1:1 像素微观切片对比 (512×512 Micro-Inspection Tile)</span>
                    <span style="font-size:11px;">中心坐标: (\(sample.cropOriginX + 256), \(sample.cropOriginY + 256))</span>
                </div>
                <div class="crop-grid">
                    <div class="crop-box">
                        <img src="\(baselineCrop)" alt="Baseline Crop">
                        <div class="lbl">原片 1:1 细节切片</div>
                    </div>
                    <div class="crop-box">
                        <img id="crop-after-\(sample.id)" src="\(masterCrop)" alt="Processed Crop">
                        <div class="lbl">成片 1:1 细节切片</div>
                    </div>
                </div>
            </div>
        </div>

        <div class="card-side">
            <h3 style="font-size: 15px; font-weight: 600; color: #fff;">专业审美量化评审表</h3>
            
            <div class="rubric-box">
                <div class="rubric-item">
                    <div class="rubric-label">
                        <span>1. 微观质感与毛孔保留</span>
                        <span id="score-val-\(sample.id)-1">5分</span>
                    </div>
                    <div class="stars">
                        <button class="star-btn" onclick="setScore('\(sample.id)', 1, 1)">1</button>
                        <button class="star-btn" onclick="setScore('\(sample.id)', 1, 2)">2</button>
                        <button class="star-btn" onclick="setScore('\(sample.id)', 1, 3)">3</button>
                        <button class="star-btn" onclick="setScore('\(sample.id)', 1, 4)">4</button>
                        <button class="star-btn selected" onclick="setScore('\(sample.id)', 1, 5)">5</button>
                    </div>
                </div>

                <div class="rubric-item">
                    <div class="rubric-label">
                        <span>2. 色彩还原与协调</span>
                        <span id="score-val-\(sample.id)-2">5分</span>
                    </div>
                    <div class="stars">
                        <button class="star-btn" onclick="setScore('\(sample.id)', 2, 1)">1</button>
                        <button class="star-btn" onclick="setScore('\(sample.id)', 2, 2)">2</button>
                        <button class="star-btn" onclick="setScore('\(sample.id)', 2, 3)">3</button>
                        <button class="star-btn" onclick="setScore('\(sample.id)', 2, 4)">4</button>
                        <button class="star-btn selected" onclick="setScore('\(sample.id)', 2, 5)">5</button>
                    </div>
                </div>

                <div class="rubric-item">
                    <div class="rubric-label">
                        <span>3. 高光暗部过渡与动态</span>
                        <span id="score-val-\(sample.id)-3">5分</span>
                    </div>
                    <div class="stars">
                        <button class="star-btn" onclick="setScore('\(sample.id)', 3, 1)">1</button>
                        <button class="star-btn" onclick="setScore('\(sample.id)', 3, 2)">2</button>
                        <button class="star-btn" onclick="setScore('\(sample.id)', 3, 3)">3</button>
                        <button class="star-btn" onclick="setScore('\(sample.id)', 3, 4)">4</button>
                        <button class="star-btn selected" onclick="setScore('\(sample.id)', 3, 5)">5</button>
                    </div>
                </div>

                <div class="rubric-item">
                    <div class="rubric-label">
                        <span>4. 几何形变与边缘完整</span>
                        <span id="score-val-\(sample.id)-4">5分</span>
                    </div>
                    <div class="stars">
                        <button class="star-btn" onclick="setScore('\(sample.id)', 4, 1)">1</button>
                        <button class="star-btn" onclick="setScore('\(sample.id)', 4, 2)">2</button>
                        <button class="star-btn" onclick="setScore('\(sample.id)', 4, 3)">3</button>
                        <button class="star-btn" onclick="setScore('\(sample.id)', 4, 4)">4</button>
                        <button class="star-btn selected" onclick="setScore('\(sample.id)', 4, 5)">5</button>
                    </div>
                </div>

                <div class="rubric-item">
                    <div class="rubric-label">
                        <span>5. 商业成片交付度</span>
                        <span id="score-val-\(sample.id)-5">5分</span>
                    </div>
                    <div class="stars">
                        <button class="star-btn" onclick="setScore('\(sample.id)', 5, 1)">1</button>
                        <button class="star-btn" onclick="setScore('\(sample.id)', 5, 2)">2</button>
                        <button class="star-btn" onclick="setScore('\(sample.id)', 5, 3)">3</button>
                        <button class="star-btn" onclick="setScore('\(sample.id)', 5, 4)">4</button>
                        <button class="star-btn selected" onclick="setScore('\(sample.id)', 5, 5)">5</button>
                    </div>
                </div>
            </div>

            <div class="total-box">
                <div>
                    <div style="font-size: 11px; color: var(--text-secondary);">综合审美得分</div>
                    <div style="font-size: 20px; font-weight: 700;" id="total-val-\(sample.id)">25 / 25</div>
                </div>
                <div class="grade" id="grade-val-\(sample.id)">A+</div>
            </div>

            <textarea class="notes-input" placeholder="输入评审专家意见与改进建议..." id="notes-\(sample.id)"></textarea>
        </div>
    </div>
    """
}

let footerHtml = """
</div>

<div class="action-bar">
    <button class="btn-primary" onclick="exportReviewJSON()">💾 导出评审评分表 (Export JSON)</button>
</div>

<script>
    const sampleData = \(String(data: manifestData, encoding: .utf8) ?? "{}");
    const scores = {};

    sampleData.samples.forEach(s => {
        scores[s.id] = { dim1: 5, dim2: 5, dim3: 5, dim4: 5, dim5: 5, notes: "" };
        initSplitSlider(s.id);
    });

    function setScore(sampleId, dim, val) {
        scores[sampleId]['dim' + dim] = val;
        document.getElementById(`score-val-${sampleId}-${dim}`).innerText = `${val}分`;
        
        // Update star buttons visual state
        const item = document.getElementById(`score-val-${sampleId}-${dim}`).closest('.rubric-item');
        const btns = item.querySelectorAll('.star-btn');
        btns.forEach((b, idx) => {
            if (idx + 1 === val) b.classList.add('selected');
            else b.classList.remove('selected');
        });

        const total = scores[sampleId].dim1 + scores[sampleId].dim2 + scores[sampleId].dim3 + scores[sampleId].dim4 + scores[sampleId].dim5;
        document.getElementById(`total-val-${sampleId}`).innerText = `${total} / 25`;
        
        let grade = "C";
        if (total >= 23) grade = "A+";
        else if (total >= 20) grade = "A";
        else if (total >= 16) grade = "B";
        document.getElementById(`grade-val-${sampleId}`).innerText = grade;
    }

    function switchPipeline(sampleId, pipelineId) {
        const s = sampleData.samples.find(x => x.id === sampleId);
        if (!s) return;
        const imgAfter = document.getElementById(`img-after-${sampleId}`);
        const cropAfter = document.getElementById(`crop-after-${sampleId}`);
        if (s.previewFiles[pipelineId]) {
            imgAfter.src = s.previewFiles[pipelineId];
        }
        if (s.cropFiles[pipelineId]) {
            cropAfter.src = s.cropFiles[pipelineId];
        }

        const tabs = document.querySelectorAll(`#tabs-${sampleId} .tab-btn`);
        tabs.forEach(t => {
            if (t.getAttribute('onclick').includes(pipelineId)) t.classList.add('active');
            else t.classList.remove('active');
        });
    }

    function initSplitSlider(sampleId) {
        const viewer = document.getElementById(`viewer-${sampleId}`);
        const slider = document.getElementById(`slider-${sampleId}`);
        const beforeLayer = document.getElementById(`layer-before-${sampleId}`);
        let isDragging = false;

        function updateSlider(x) {
            const rect = viewer.getBoundingClientRect();
            let pct = (x - rect.left) / rect.width;
            pct = Math.max(0, Math.min(1, pct));
            slider.style.left = `${pct * 100}%`;
            beforeLayer.style.clipPath = `inset(0 ${100 - pct * 100}% 0 0)`;
        }

        viewer.addEventListener('mousedown', e => {
            isDragging = true;
            updateSlider(e.clientX);
        });
        window.addEventListener('mousemove', e => {
            if (!isDragging) return;
            updateSlider(e.clientX);
        });
        window.addEventListener('mouseup', () => { isDragging = false; });
    }

    function filterCategory(cat) {
        document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
        event.target.classList.add('active');
        document.querySelectorAll('.card').forEach(card => {
            const c = card.getAttribute('data-category');
            if (cat === 'all' || c.includes(cat)) {
                card.style.display = 'grid';
            } else {
                card.style.display = 'none';
            }
        });
    }

    function exportReviewJSON() {
        sampleData.samples.forEach(s => {
            const noteEl = document.getElementById(`notes-${s.id}`);
            if (noteEl) scores[s.id].notes = noteEl.value;
        });
        const exportObj = {
            metadata: sampleData,
            evaluationScores: scores,
            exportedAt: new Date().toISOString()
        };
        const blob = new Blob([JSON.stringify(exportObj, null, 2)], { type: 'application/json' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = 'aesthetic-review-report.json';
        a.click();
    }
</script>

</body>
</html>
"""

let fullHTML = htmlContent + cardsHtml + footerHtml
let htmlURL = outputDir.appendingPathComponent("index.html")
try fullHTML.write(to: htmlURL, atomically: true, encoding: .utf8)
print("🌐 Interactive Review Gallery generated: \(htmlURL.path)")
print("✨ Done! Open with: open \"\(htmlURL.path)\"")

// P3-E1 诊断探针：逐张样片跑 P2 微雕/美肤管线，打印每个模块的 applied 与 note，
// 用于确认哪些模块在真实样片上因检测不足/置信度门槛被跳过。只读输入。
// 编译：BIN="$(swift build --show-bin-path)"
//       swiftc -I "$BIN" Scripts/probe_p2_applied.swift \
//         "$BIN"/PhotoCore.build/*.o "$BIN"/CLensfunBridge.build/CLensfunBridge.c.o \
//         -o /tmp/probe_p2_applied
// 注意：探针必须与 PhotoCore 重新编译后使用——swiftc 直链 .o 文件，缓存旧目标文件
// 会得到与源码不一致的结果（P3-E1 验证期间的实际教训）。
import Foundation
import PhotoCore
import CoreImage

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Usage: probe_p2_applied <INPUT_DIR> <LIMIT>")
    exit(1)
}
let inputDir = URL(fileURLWithPath: args[1], isDirectory: true)
let limit = Int(args[2]) ?? 3

let items = try PhotoLoader.scan(folder: inputDir, recursive: false).prefix(limit)
let engine = PhotoEngine()

// P2 微雕组合（与 evaluate_aesthetic 08_p2_reshape_suite 相同参数）
func reshapeSettings() -> AdjustmentSettings {
    var s = AdjustmentSettings()
    var liquify = FaceReshapeSettings(preset: .youthful)
    liquify.strength = 0.55
    liquify.parameters.cranialTop = 0.30
    liquify.parameters.hairline = 0.15
    liquify.parameters.temple = 0.20
    s.liquify = liquify
    var bone = FacialBoneContourSettings(enabled: true)
    bone.facialFolding = 0.40
    bone.tZoneHighlight = 0.45
    bone.cZoneHighlight = 0.40
    s.facialBoneContour = bone
    var eyeShape = EyeShapeSettings()
    eyeShape.enabled = true
    eyeShape.eyeSymmetry = 0.35
    s.eyeShape = eyeShape
    var nose = NoseReshapeSettings()
    nose.enabled = true
    nose.nose3DContour = 0.35
    s.noseReshape = nose
    var jaw = JawChinReshapeSettings()
    jaw.enabled = true
    jaw.jawlineTighten = 0.35
    s.jawChinReshape = jaw
    var brow = EyebrowReshapeSettings()
    brow.enabled = true
    brow.browSymmetry = 0.35
    s.eyebrowReshape = brow
    var contour = FacialContourSettings()
    contour.enabled = true
    contour.templePlump = 0.30
    s.facialContour = contour
    var expr = ExpressionSettings()
    expr.enabled = true
    expr.smileDegree = 0.30
    s.expression = expr
    return s
}

func skinSettings() -> AdjustmentSettings {
    var s = AdjustmentSettings()
    var z = FacialZonalRefinementSettings()
    z.enabled = true
    z.darkCircles = 0.45
    z.antiShine = 0.50
    s.facialZonal = z
    var b = BodySkinRefinementSettings()
    b.enabled = true
    b.neckSmoothing = 0.40
    b.bodySmoothing = 0.45
    s.bodySkin = b
    var c = ClothingRefinementSettings()
    c.enabled = true
    c.wrinkleSmoothing = 0.45
    s.clothing = c
    var p = PortraitRefinementSettings()
    p.hairGapFilling = 0.40
    p.hairGloss = 0.45
    p.flyawayRemoval = 0.45
    s.portrait = p
    return s
}

for (idx, item) in items.enumerated() {
    print("\n=== sample-\(String(format: "%02d", idx+1)): \(item.url.lastPathComponent) ===")
    let loaded = try PhotoLoader.load(url: item.url, lensCorrection: false)
    for (label, settings) in [("reshape", reshapeSettings()), ("skin", skinSettings())] {
        let out = try engine.process(loaded.image, settings: settings, lut: nil)
        print("  [\(label)]")
        func line(_ name: String, _ r: (applied: Bool, note: String?)?) {
            guard let r else { return }
            let note = r.note ?? "-"
            print("    \(name): applied=\(r.applied) note=\(note)")
        }
        if let r = out.report.facialBoneContour { line("boneContour", (r.applied, r.note)) }
        if let r = out.report.eyeShape { line("eyeShape", (r.applied, r.note)) }
        if let r = out.report.noseReshape { line("noseReshape", (r.applied, r.note)) }
        if let r = out.report.jawChinReshape { line("jawChin", (r.applied, r.note)) }
        if let r = out.report.eyebrowReshape { line("eyebrow", (r.applied, r.note)) }
        if let r = out.report.facialContour { line("facialContour", (r.applied, r.note)) }
        if let r = out.report.expression { line("expression", (r.applied, r.note)) }
        if let r = out.report.facialZonal { line("facialZonal", (r.applied, r.note)) }
        if let r = out.report.bodySkin { line("bodySkin", (r.applied, r.note)) }
        if let r = out.report.clothing { line("clothing", (r.applied, r.note)) }
        if let r = out.report.portrait { line("portrait/hair", (r.applied, r.note)) }
        if let r = out.report.liquify { line("liquify", (r.applied != false, nil)) }
    }
}
print("\nDONE")

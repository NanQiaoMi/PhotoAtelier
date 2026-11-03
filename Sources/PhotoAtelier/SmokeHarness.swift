import AppKit
import CoreImage
import CryptoKit
import PhotoCore
import SwiftUI

/// Explicit local integration-test entry point; normal launches never use it.
/// It exercises application commands and renders its own SwiftUI view, without
/// driving other apps or synthesizing system mouse/keyboard events.
enum SmokeHarness {
    private static var session: SmokeSession?
    private static var portraitSession: PortraitSmokeSession?
    private static var nativeSession: NativeInspectionSmokeSession?
    private static var styleSession: StyleWorkflowSmokeSession?
    static func startIfRequested(model: AppModel) {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--style-self-test"), args.count > index + 3 {
            guard styleSession == nil else { return }
            let evidence = URL(fileURLWithPath: args[index + 3])
            let isolated = AppModel(libraryRoot: evidence.appendingPathComponent("library"),
                                   preferences: UserDefaults(suiteName: "PhotoAtelier.StyleTest.\(UUID())")!)
            let task = StyleWorkflowSmokeSession(model: isolated, input: URL(fileURLWithPath: args[index + 1]),
                output: URL(fileURLWithPath: args[index + 2]), evidence: evidence)
            styleSession = task; task.start(); return
        }
        if let index = args.firstIndex(of: "--native-inspection-self-test"), args.count > index + 3 {
            guard nativeSession == nil else { return }
            let task = NativeInspectionSmokeSession(model: model, input: URL(fileURLWithPath: args[index + 1]),
                output: URL(fileURLWithPath: args[index + 2]), evidence: URL(fileURLWithPath: args[index + 3]))
            nativeSession = task; task.start(); return
        }
        if let index = args.firstIndex(of: "--portrait-self-test"), args.count > index + 3 {
            guard portraitSession == nil else { return }
            let task = PortraitSmokeSession(model: model, input: URL(fileURLWithPath: args[index + 1]),
                output: URL(fileURLWithPath: args[index + 2]), evidence: URL(fileURLWithPath: args[index + 3]))
            portraitSession = task; task.start(); return
        }
        guard session == nil, let index = args.firstIndex(of: "--self-test"), args.count > index + 3 else { return }
        let task = SmokeSession(model: model, input: URL(fileURLWithPath: args[index + 1], isDirectory: true),
                                output: URL(fileURLWithPath: args[index + 2], isDirectory: true),
                                evidence: URL(fileURLWithPath: args[index + 3], isDirectory: true))
        session = task
        task.start()
    }
}

private final class SmokeSession {
    let model: AppModel
    let input: URL, output: URL, evidence: URL
    private var timer: Timer?
    private var phase = 0
    private let started = Date()
    private var originalHashes: [String: String] = [:]
    private var assertions: [String] = []
    private var originalMaskCoverage = 0.0
    private var exposureBeforePreserving = 0.0
    private var regionalExposureBeforeAdvice = 0.0

    init(model: AppModel, input: URL, output: URL, evidence: URL) {
        self.model = model; self.input = input; self.output = output; self.evidence = evidence
    }

    func start() {
        do {
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            guard LensCorrection.shared.profiles.count >= 1000 else {
                throw AtelierError.invalidConfiguration("应用未加载完整离线镜头数据库")
            }
            assertions.append("Native Lensfun runtime and offline database loaded")
            originalHashes = try hashes(in: input)
            try snapshot("01-empty.png", tab: 0)
            model.loadFolder(input)
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.advance() }
        } catch { finish(error: error) }
    }

    private func advance() {
        do {
            guard Date().timeIntervalSince(started) < 180 else { throw AtelierError.invalidConfiguration("应用流程验证超时（180 秒）") }
            if let error = model.errorMessage { throw AtelierError.invalidConfiguration(error) }
            if let error = model.analysisError { throw AtelierError.invalidConfiguration(error) }
            switch phase {
            case 0:
                guard !model.scanning, !model.previewBusy, !model.analysisBusy,
                      model.afterImage != nil, model.proposalPreviews.count == 3 else { return }
                guard model.photos.count >= 2, !LUTCube.builtIns.isEmpty else {
                    throw AtelierError.invalidConfiguration("测试需要至少两张合成照片和一个内置 LUT")
                }
                assertions.append("Folder scan and managed preview completed")
                guard let analysis = model.analysis, analysis.proposals.count == 3,
                      analysis.metrics.sampleCount > 100,
                      analysis.colorScene?.regions.count == 9 else {
                    throw AtelierError.invalidConfiguration("未生成基于真实像素的三种分析方案")
                }
                assertions.append("Pixel/metadata analysis and three rendered automatic proposals completed")
                assertions.append("Measured scene palette and nine positional regions completed")
                guard !model.adjustments.autoExposure, !model.adjustments.autoWhiteBalance,
                      analysis.proposals.allSatisfy({ proposal in
                          guard let safety = proposal.safety else { return false }
                          return !proposal.settings.autoExposure && !proposal.settings.autoWhiteBalance
                              && proposal.settings.temperature == 0 && proposal.settings.tint == 0
                              && abs(safety.exposureDeltaEV) <= 0.400001
                              && (0...1).contains(safety.retainedFraction)
                              && safety.introducedHighlightFraction <= 0.005001
                              && safety.introducedShadowFraction <= 0.005001
                      }) else { throw AtelierError.invalidConfiguration("新照片默认状态或三方案自动增量检查不符合保守约束") }
                assertions.append("Capture exposure/WB defaults preserved and three automatic increments checked at preview input resolution")
                try JSONEncoder().encode(analysis).write(to: evidence.appendingPathComponent("initial-analysis.json"), options: .atomic)
                try snapshot("02-library.png", tab: 0)
                model.adjustments.exposureEV = 0.5
                model.requestPreview(immediate: true)
                phase = 9
            case 9:
                guard !model.previewBusy, !model.analysisBusy, model.proposalPreviews.count == 3,
                      let analysis = model.analysis else { return }
                guard analysis.proposals.allSatisfy({ proposal in
                    guard let safety = proposal.safety else { return false }
                    return abs(proposal.settings.exposureEV - safety.exposureDeltaEV - 0.5) < 1e-8
                }) else { throw AtelierError.invalidConfiguration("手动基础参数变化后，方案仍使用过时的分析基线") }
                assertions.append("Editing manual base exposure refreshes proposal analysis without double correction")
                try JSONEncoder().encode(analysis).write(to: evidence.appendingPathComponent("manual-baseline-analysis.json"), options: .atomic)
                model.adjustments.exposureEV = 0
                model.requestPreview(immediate: true)
                phase = 10
            case 10:
                guard !model.previewBusy, !model.analysisBusy, model.proposalPreviews.count == 3,
                      let analysis = model.analysis, let preset = LUTCube.builtIns.first else { return }
                guard analysis.proposals.allSatisfy({ proposal in
                    guard let safety = proposal.safety else { return false }
                    return abs(proposal.settings.exposureEV - safety.exposureDeltaEV) < 1e-8
                }) else { throw AtelierError.invalidConfiguration("恢复基础参数后方案基线未同步恢复") }
                model.applyProposal("balanced")
                model.selectLUT(preset.id)
                model.adjustments.exposureEV += 0.2
                guard let lens = LensCorrection.shared.profiles.first(where: {
                    $0.maker == "Canon" && $0.name.contains("EF 24-70mm f/2.8L USM") && abs($0.cropFactor - 1) < 0.01
                }) else { throw AtelierError.invalidConfiguration("真实镜头测试配置不存在") }
                model.adjustments.lensCorrection = true
                model.adjustments.lensProfileID = lens.id
                model.adjustments.lensCropFactor = 1
                model.adjustments.lensFocalLength = 24
                model.requestPreview(immediate: true)
                phase = 1
            case 1:
                guard !model.previewBusy, !model.analysisBusy, model.afterImage != nil,
                      model.proposalPreviews.count == 3 else { return }
                guard model.previewReport.lensCorrectionApplied else {
                    throw AtelierError.invalidConfiguration("镜头配置未实际应用于预览：\(model.previewReport.warnings.joined(separator: "；"))")
                }
                assertions.append("Built-in LUT and exposure preview completed")
                guard let quality = model.previewReport.colorQuality,
                      quality.sampleCount > 0, quality.outputColorSpace == model.exportSettings.colorSpace,
                      model.previewReport.lutCompatibility != nil else {
                    throw AtelierError.invalidConfiguration("滤镜兼容或叠加颜色实测未生成")
                }
                assertions.append("LUT compatibility and final color-quality measurements completed")
                assertions.append("Real calibrated Lensfun geometry applied through app preview")
                try snapshot("02-analysis.png", tab: 0, compare: false)
                try snapshotView("02-automatic-safety.png", width: 420, height: 2400,
                                 content: AnalysisPanel(model: model, editParameters: {}).padding(24)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .background(AtelierPalette.panel))
                exposureBeforePreserving = model.adjustments.exposureEV
                model.setSceneIntent(.preserveStyle)
                phase = 11
            case 11:
                guard !model.previewBusy, !model.analysisBusy, model.proposalPreviews.count == 3,
                      let scene = model.analysis?.sceneAssessment else { return }
                guard scene.requestedIntent == .preserveStyle, scene.selectionSource == .user,
                      abs(model.adjustments.exposureEV - exposureBeforePreserving) < 1e-8,
                      model.analysis?.proposals.allSatisfy({ abs($0.safety?.exposureDeltaEV ?? 999) < 1e-8 }) == true,
                      model.recipe.automatic?.sceneIntent == .preserveStyle else {
                    throw AtelierError.invalidConfiguration("保留已有风格未固定当前基础结果或未写入配方")
                }
                assertions.append("Explicit preserve-style intent freezes visible base exposure and is retained in recipe")
                try JSONEncoder().encode(model.analysis).write(to: evidence.appendingPathComponent("preserve-style-analysis.json"), options: .atomic)
                try snapshotView("02-scene-intent.png", width: 420, height: 550,
                                 content: SceneIntentPanel(model: model).padding(24)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .background(AtelierPalette.panel))
                model.setSceneIntent(.automatic)
                phase = 12
            case 12:
                guard !model.previewBusy, !model.analysisBusy, model.proposalPreviews.count == 3,
                      let scene = model.analysis?.sceneAssessment else { return }
                guard scene.requestedIntent == .automatic, scene.selectionSource != .user else {
                    throw AtelierError.invalidConfiguration("恢复逐图判断后仍使用旧显式场景结果")
                }
                assertions.append("Returning to automatic intent refreshes evidence and all three scene-dependent proposals")
                model.adjustments.tonalCurve = TonalCurveSettings(shadowsEV: 0.35, midtonesEV: 0.07)
                model.requestPreview(immediate: true)
                phase = 13
            case 13:
                guard !model.previewBusy, !model.analysisBusy, model.proposalPreviews.count == 3,
                      let curve = model.adjustments.tonalCurve else { return }
                let savedRecipe = try JSONEncoder().encode(model.recipe)
                try savedRecipe.write(to: evidence.appendingPathComponent("tonal-recipe.json"), options: .atomic)
                let restored = try JSONDecoder().decode(Recipe.self, from: savedRecipe)
                let fields: [KeyPath<TonalCurveSettings, Double>] = [
                    \.blacksEV, \.shadowsEV, \.midtonesEV, \.highlightsEV, \.whitesEV
                ]
                guard abs(curve.shadowsEV - 0.35) < 1e-8, abs(curve.midtonesEV - 0.07) < 1e-8,
                      restored.version == 8, let decoded = restored.adjustments.tonalCurve,
                      fields.allSatisfy({ abs(decoded[keyPath: $0] - curve[keyPath: $0]) < 1e-12 }) else {
                    throw AtelierError.invalidConfiguration("五区手动微调或配方 v7 读写没有保留实际值")
                }
                assertions.append("Manual five-zone EV edits refresh preview and survive recipe v6 round-trip")
                try snapshotView("03-tonal-controls.png", width: 420, height: 430,
                                 content: TonalCurvePanel(model: model).padding(24)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .background(AtelierPalette.panel))
                model.maskKind = .radial
                model.maskDrawMode = .new
                model.addMask(start: .init(x: 0.52, y: 0.52), end: .init(x: 0.78, y: 0.77), points: [])
                if let index = model.activeMaskIndex {
                    model.adjustments.masks[index].exposureEV = 0.3
                    model.adjustments.masks[index].highlights = -0.2
                    model.adjustments.masks[index].sharpness = 0.2
                }
                model.showMaskCoverage = true
                model.requestPreview(immediate: true)
                phase = 2
            case 2:
                guard !model.previewBusy, model.afterImage != nil,
                      let inspection = model.maskInspection, model.maskOverlayImage != nil else { return }
                guard inspection.coverage > 0.005, inspection.coverage < 0.5,
                      model.selectedLocalMask?.stage == .beforeLook else {
                    throw AtelierError.invalidConfiguration("局部蒙版未生成实际覆盖或默认处理阶段错误")
                }
                originalMaskCoverage = inspection.coverage
                assertions.append("Local mask coverage, regional inspection and before-look adjustment completed")
                try snapshot("03-mask.png", tab: 2, compare: false)
                model.maskKind = .brush; model.maskDrawMode = .subtract
                model.brushRadius = 0.045; model.brushFeather = 0.5
                let stroke = [MaskPoint(x: 0.52, y: 0.43), MaskPoint(x: 0.52, y: 0.63)]
                model.addMask(start: stroke[0], end: stroke[1], points: stroke)
                model.cancelMaskInteraction()
                model.requestPreview(immediate: true)
                phase = 5
            case 5:
                guard !model.previewBusy, model.afterImage != nil,
                      let inspection = model.maskInspection, model.maskOverlayImage != nil else { return }
                guard model.selectedLocalMask?.components.count == 1,
                      inspection.coverage < originalMaskCoverage - 0.0001,
                      let originalMask = model.selectedMask else {
                    throw AtelierError.invalidConfiguration("减选笔迹没有减少有效蒙版覆盖")
                }
                assertions.append("Subtractive brush refinement reduces measured coverage with refreshed overlay")
                try snapshot("03-mask-refined.png", tab: 2, compare: false)
                let count = model.adjustments.masks.count
                model.duplicateSelectedMask()
                guard model.adjustments.masks.count == count + 1, model.selectedMask != originalMask else {
                    throw AtelierError.invalidConfiguration("蒙版复制没有生成独立标识")
                }
                model.moveSelectedMask(by: -1)
                model.moveSelectedMask(by: 1)
                model.deleteSelectedMask()
                model.selectedMask = originalMask
                try PhotoEngine.validate(model.adjustments)
                let encoded = try JSONEncoder().encode(model.recipe)
                let restored = try JSONDecoder().decode(Recipe.self, from: encoded)
                guard restored.adjustments.masks.count == count,
                      restored.adjustments.masks.first?.components.count == 1 else {
                    throw AtelierError.invalidConfiguration("配方没有保留蒙版修边数据")
                }
                assertions.append("Mask duplication, ordering, removal and recipe round-trip completed")
                model.addRangeMask(kind: .color)
                phase = 6
            case 6:
                guard !model.previewBusy, model.maskInspection != nil,
                      model.selectedLocalMask?.kind == .color else { return }
                model.pickMaskColor(at: .init(x: 0.3, y: 0.4))
                phase = 7
            case 7:
                guard !model.previewBusy, model.maskInspection != nil,
                      model.selectedLocalMask?.kind == .color,
                      model.selectedLocalMask?.restrictColor == true else { return }
                assertions.append("Asynchronous reference-color sampling and color-range preview completed")
                try snapshot("03-mask-color.png", tab: 2, compare: false)
                model.deleteSelectedMask()
                model.showMaskCoverage = false
                model.showMaskOverlay = false
                model.outputRoot = output
                model.exportSettings.format = .tiff
                model.exportSettings.colorSpace = .displayP3
                model.requestPreview(immediate: true)
                phase = 8
            case 8:
                guard !model.previewBusy,
                      model.previewReport.colorQuality?.outputColorSpace == .displayP3 else { return }
                assertions.append("Changing export space refreshes the preview to the same Display P3 target")
                try snapshot("03-color-harmony.png", tab: 1, compare: false)
                try snapshotView("03-color-harmony-controls.png", width: 420, height: 760,
                                 content: ColorHarmonyPanel(model: model).padding(24)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .background(AtelierPalette.panel))
                // The manual Canon profile above is a synthetic warp fixture.
                // Real camera files in a mixed batch must use their own EXIF match.
                if model.photos.contains(where: { ["cr2", "dng", "nef", "arw"].contains($0.url.pathExtension.lowercased()) }) {
                    model.adjustments.lensProfileID = nil
                    model.adjustments.lensCropFactor = 0
                    model.adjustments.lensFocalLength = 0
                }
                model.startBatch()
                guard model.batchRunning else { throw AtelierError.invalidConfiguration("批量任务没有启动") }
                phase = 3
            case 3:
                guard !model.batchRunning else { return }
                guard model.succeeded >= 2, let manifest = model.lastManifest,
                      FileManager.default.fileExists(atPath: manifest.path) else {
                    throw AtelierError.invalidConfiguration("批量导出未生成预期结果或报告")
                }
                guard try hashes(in: input) == originalHashes else {
                    throw AtelierError.invalidConfiguration("原图内容发生变化")
                }
                let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
                let entries = json?["entries"] as? [[String: Any]] ?? []
                let completed = entries.filter { $0["status"] as? String == "completed" }
                guard completed.count == model.succeeded,
                      completed.allSatisfy({ ($0["report"] as? [String: Any])?["analysis"] is [String: Any] }) else {
                    throw AtelierError.invalidConfiguration("逐张自动分析依据未写入批处理报告")
                }
                guard let savedRecipe = json?["recipe"] as? [String: Any], savedRecipe["version"] as? Int == 8,
                      completed.allSatisfy({ entry in
                          let report = entry["report"] as? [String: Any]
                          let quality = report?["colorQuality"] as? [String: Any]
                          return quality?["outputColorSpace"] as? String == "displayP3"
                              && report?["lutCompatibility"] is [String: Any]
                      }) else { throw AtelierError.invalidConfiguration("配方版本或逐张色彩保护报告未记录") }
                assertions.append("Recipe v6 and per-photo output gamut / color-protection reports retained")
                guard completed.allSatisfy({ entry in
                    let record = (entry["report"] as? [String: Any])?["analysis"] as? [String: Any]
                    guard let scene = record?["sceneAssessment"] as? [String: Any],
                          let category = scene["category"] as? String,
                          let evidence = scene["evidence"] as? [String] else { return false }
                    return !category.isEmpty && !evidence.isEmpty && scene["policyVersion"] as? Int == 2
                        && scene["requestedIntent"] as? String == "automatic"
                }) else { throw AtelierError.invalidConfiguration("逐图场景决策及证据未写入报告") }
                assertions.append("Each exported photo records its own scene policy, evidence and requested intent")
                guard completed.allSatisfy({ entry in
                    let record = (entry["report"] as? [String: Any])?["analysis"] as? [String: Any]
                    guard let safety = record?["proposalSafety"] as? [String: Any],
                          let highlights = safety["introducedHighlightFraction"] as? Double,
                          let shadows = safety["introducedShadowFraction"] as? Double,
                          let delta = safety["exposureDeltaEV"] as? Double,
                          let scope = safety["scope"] as? String, scope.contains("alpha"),
                          scope.contains("后续手调"), scope.contains("192"),
                          let requestedHighlights = safety["requestedHighlightFraction"] as? Double,
                          let requestedShadows = safety["requestedShadowFraction"] as? Double else { return false }
                    return highlights.isFinite && shadows.isFinite && delta.isFinite
                        && (0...1).contains(requestedHighlights) && (0...1).contains(requestedShadows)
                        && highlights <= 0.005001 && shadows <= 0.005001 && abs(delta) <= 0.400001
                }) else { throw AtelierError.invalidConfiguration("自动方案检查证据未逐张保存") }
                assertions.append("Per-photo proposal safety scope and finite introduced clipping measurements saved")
                let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "nrw", "arw", "raf", "rw2", "orf", "pef", "srw"]
                let rawItems = model.photos.filter { rawExtensions.contains($0.url.pathExtension.lowercased()) }
                for raw in rawItems {
                    guard completed.contains(where: {
                        $0["input"] as? String == raw.relativePath &&
                        ($0["report"] as? [String: Any])?["inputWasRAW"] as? Bool == true
                    }) else { throw AtelierError.invalidConfiguration("真实 RAW 未完成全分辨率批处理：\(raw.relativePath)") }
                }
                if !rawItems.isEmpty { assertions.append("Full-resolution RAW decode, analysis and export completed") }
                assertions.append("16-bit Display P3 TIFF batch and manifest completed")
                assertions.append("Per-photo analysis evidence and effective automatic settings recorded")
                assertions.append("Source hashes unchanged")
                if model.failed > 0 { assertions.append("Broken image isolated without aborting later images") }
                try snapshot("04-export.png", tab: 3)
                if let raw = rawItems.first {
                    model.selectPhoto(raw)
                    phase = 4
                } else { try startRegionalFixture() }
            case 4:
                guard !model.previewBusy, !model.analysisBusy, model.afterImage != nil,
                      model.proposalPreviews.count == 3, let analysis = model.analysis else { return }
                guard model.previewReport.inputWasRAW, analysis.metrics.sampleCount > 100,
                      analysis.metadata.contains(where: { $0.id == "source.kind" && $0.value.contains("RAW") }) else {
                    throw AtelierError.invalidConfiguration("真实 RAW 预览或拍摄信息分析未完成")
                }
                if model.selectedPhoto?.url.lastPathComponent == "04_Canon-EOS-1100D.CR2" {
                    guard (0.04...0.12).contains(analysis.metrics.medianLuminance) else {
                        throw AtelierError.invalidConfiguration("固定 Canon RAW 的线性中位亮度偏离独立解码参考，可能重复执行了传递函数转换")
                    }
                    assertions.append("RAW luminance agrees with independently measured linear decode reference")
                }
                try snapshot("05-raw-analysis.png", tab: 0, compare: false)
                assertions.append("Real camera RAW preview, metadata and three candidate renders completed")
                try startRegionalFixture()
            case 14:
                guard !model.scanning, !model.previewBusy, !model.analysisBusy,
                      model.afterImage != nil, model.regionalSuggestions.count == 2 else { return }
                guard model.adjustments.masks.isEmpty,
                      let shadow = model.regionalSuggestions.first(where: { $0.mask.luminanceMax == 0.5 }) else {
                    throw AtelierError.invalidConfiguration("局部建议未生成，或在用户采用前自动写入蒙版")
                }
                assertions.append("Positional light suggestions appear without automatically applying masks")
                try JSONEncoder().encode(model.regionalSuggestions)
                    .write(to: evidence.appendingPathComponent("regional-suggestions.json"), options: .atomic)
                try snapshotView("06-regional-suggestions.png", width: 420, height: 1100,
                                 content: RegionalSuggestionsPanel(model: model, editLocals: {}).padding(24)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .background(AtelierPalette.panel))
                model.applyRegionalSuggestion(shadow.id)
                phase = 15
            case 15:
                guard !model.previewBusy, let inspection = model.maskInspection,
                      model.maskOverlayImage != nil,
                      let shadow = model.regionalSuggestions.first(where: { $0.mask.luminanceMax == 0.5 }) else { return }
                guard model.adjustments.masks.count == 1, model.selectedMask == shadow.mask.id,
                      inspection.coverage > 0, model.selectedLocalMask?.restrictLuminance == true,
                      model.selectedLocalMask?.stage == .beforeLook else {
                    throw AtelierError.invalidConfiguration("采用建议未创建可编辑且限亮度范围的局部蒙版")
                }
                guard let guidance = inspection.lightGuidance, guidance == shadow.lightGuidance,
                      abs(inspection.coverage - (shadow.effectiveCoverage ?? -1)) < 1e-9,
                      abs(inspection.suggestedExposureEV - shadow.mask.exposureEV) < 1e-9 else {
                    throw AtelierError.invalidConfiguration("位置建议与真实蒙版的亮度依据或曝光不一致")
                }
                assertions.append("Positional advice and mask inspection share the same measured coverage, RGB headroom and exposure")
                regionalExposureBeforeAdvice = shadow.mask.exposureEV
                guard let index = model.activeMaskIndex else {
                    throw AtelierError.invalidConfiguration("缺少待采用曝光建议的蒙版")
                }
                model.adjustments.masks[index].highlights = 0.12
                model.adjustments.masks[index].shadows = 0.18
                model.applyMaskSuggestion()
                phase = 18
            case 18:
                guard !model.previewBusy, model.maskInspection != nil,
                      let shadow = model.regionalSuggestions.first(where: { $0.mask.luminanceMax == 0.5 }) else { return }
                guard abs((model.selectedLocalMask?.exposureEV ?? -100) - regionalExposureBeforeAdvice) < 1e-9,
                      model.selectedLocalMask?.highlights == 0.12, model.selectedLocalMask?.shadows == 0.18 else {
                    throw AtelierError.invalidConfiguration("区域曝光建议重新归一曝光或清除了其他局部微调")
                }
                assertions.append("One-click mask advice preserves regional exposure and manual highlight/shadow edits")
                model.applyRegionalSuggestion(shadow.id)
                phase = 16
            case 16:
                guard !model.previewBusy, model.maskInspection != nil else { return }
                guard model.adjustments.masks.count == 1 else {
                    throw AtelierError.invalidConfiguration("重复采用同一局部建议导致蒙版叠加")
                }
                assertions.append("Accepting a suggestion creates a measured editable mask; repeat acceptance replaces rather than stacks it")
                try snapshot("06-regional-mask.png", tab: 2, compare: false)
                try snapshotView("07-local-measurements.png", width: 420, height: 2650,
                                 content: MaskInspector(model: model).padding(24)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .background(AtelierPalette.panel))
                guard let index = model.activeMaskIndex else {
                    throw AtelierError.invalidConfiguration("缺少待检查的蒙版")
                }
                model.adjustments.masks[index].start = .init(x: 0.5, y: 0.5)
                model.adjustments.masks[index].end = .init(x: 0.58, y: 0.58)
                model.adjustments.masks[index].feather = 0.1
                model.adjustments.masks[index].restrictLuminance = false
                model.adjustments.masks[index].exposureEV = 0.27
                model.adjustments.masks[index].highlights = 0.17
                model.adjustments.masks[index].shadows = 0.11
                model.requestPreview(immediate: true)
                phase = 19
            case 19:
                guard !model.previewBusy, let inspection = model.maskInspection else { return }
                guard inspection.lightGuidance?.hasSuggestion == false else {
                    throw AtelierError.invalidConfiguration("中间调区域不应被全图亮度强迫矫正")
                }
                let before = model.adjustments.masks
                model.applyMaskSuggestion()
                guard model.adjustments.masks == before else {
                    throw AtelierError.invalidConfiguration("无调整依据时一键建议覆盖了手动参数")
                }
                assertions.append("Without supported light advice, one-click acceptance leaves manual local adjustments intact")
                model.applyProposal("balanced")
                phase = 20
            case 20:
                guard !model.previewBusy, !model.analysisBusy, model.automaticRecipe != nil,
                      let shadow = model.regionalSuggestions.first(where: { $0.mask.exposureEV > 0 }) else { return }
                guard model.applyRegionalSuggestion(shadow.id) else {
                    throw AtelierError.invalidConfiguration("自动分析就绪后未能采用局部建议")
                }
                phase = 21
            case 21:
                guard !model.previewBusy, !model.analysisBusy,
                      model.maskInspection?.lightGuidance?.hasSuggestion == true,
                      let shadow = model.regionalSuggestions.first(where: { $0.mask.exposureEV > 0 }),
                      let index = model.activeMaskIndex else { return }
                model.adjustments.masks[index].exposureEV = 0.21
                let before = model.adjustments.masks
                model.analysisBusy = true
                let acceptedWhileBusy = model.applyRegionalSuggestion(shadow.id)
                model.applyMaskSuggestion()
                model.analysisBusy = false
                guard !acceptedWhileBusy, model.adjustments.masks == before else {
                    throw AtelierError.invalidConfiguration("自动分析期间仍可采用过时局部建议")
                }
                assertions.append("Automatic analysis in progress blocks both positional and one-click mask acceptance")
                guard let next = model.photos.first(where: { $0.id != model.selectedID }) else {
                    throw AtelierError.invalidConfiguration("换图验证缺少第二张局部样本")
                }
                model.selectPhoto(next)
                guard model.analysis == nil, model.regionalSuggestions.isEmpty,
                      !model.applyRegionalSuggestion(shadow.id) else {
                    throw AtelierError.invalidConfiguration("自动换图后仍可采用旧照片的局部建议")
                }
                model.applyMaskSuggestion()
                guard model.adjustments.masks == before else {
                    throw AtelierError.invalidConfiguration("自动换图期间旧区域测量覆盖了局部参数")
                }
                assertions.append("Switching photos clears old measurements and rejects stale advice before new analysis")
                phase = 22
            case 22:
                guard !model.previewBusy, !model.analysisBusy, model.analysis != nil,
                      model.proposalPreviews.count == 3,
                      let shadow = model.regionalSuggestions.first(where: { $0.mask.exposureEV > 0 }) else { return }
                guard model.applyRegionalSuggestion(shadow.id) else {
                    throw AtelierError.invalidConfiguration("新照片自动分析与预览就绪后无法采用新建议")
                }
                assertions.append("Fresh regional advice becomes available after the new photo analysis and resolved preview")
                phase = 23
            case 23:
                guard !model.previewBusy, model.maskInspection?.lightGuidance?.hasSuggestion == true,
                      let index = model.activeMaskIndex else { return }
                model.adjustments.masks[index].exposureEV = 0.21
                let before = model.adjustments.masks
                model.exportSettings.recursive = false
                model.reloadFolder()
                model.applyMaskSuggestion()
                guard model.scanning, model.adjustments.masks == before else {
                    throw AtelierError.invalidConfiguration("目录重扫期间仍可采用旧蒙版测量")
                }
                assertions.append("Rescanning a folder blocks stale mask advice until the photo selection is resolved")
                phase = 17
            case 17:
                guard !model.scanning, !model.previewBusy else { return }
                let count = model.adjustments.masks.count
                guard model.selectedPhoto == nil, model.regionalSuggestions.isEmpty,
                      !model.applyRegionalSuggestion("region.0.shadow"),
                      model.adjustments.masks.count == count else {
                    throw AtelierError.invalidConfiguration("空文件夹仍可采用上张照片的局部建议")
                }
                assertions.append("Empty rescan clears old regional suggestions and rejects stale acceptance")
                finish(error: nil)
            default: break
            }
        } catch { finish(error: error) }
    }

    private func startRegionalFixture() throws {
        let directory = evidence.appendingPathComponent("regional-input", isDirectory: true)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func field(_ luminance: CGFloat, _ rect: CGRect) -> CIImage {
            CIImage(color: CIColor(red: luminance, green: luminance, blue: luminance,
                                   alpha: 1, colorSpace: space)!).cropped(to: rect)
        }
        let source = field(0.03, CGRect(x: 0, y: 512, width: 256, height: 256))
            .composited(over: field(0.9, CGRect(x: 512, y: 0, width: 256, height: 256)))
            .composited(over: field(0.25, CGRect(x: 0, y: 0, width: 768, height: 768)))
        var settings = ExportSettings(); settings.format = .png
        try PhotoExporter.write(image: source, to: nested.appendingPathComponent("regional.png"),
                                settings: settings, sourceProperties: [:], context: PhotoEngine().context)
        let second = field(0.045, CGRect(x: 0, y: 512, width: 256, height: 256))
            .composited(over: field(0.82, CGRect(x: 512, y: 0, width: 256, height: 256)))
            .composited(over: field(0.25, CGRect(x: 0, y: 0, width: 768, height: 768)))
        try PhotoExporter.write(image: second, to: nested.appendingPathComponent("regional-2.png"),
                                settings: settings, sourceProperties: [:], context: PhotoEngine().context)
        model.resetAdjustments()
        model.exportSettings.recursive = true
        model.loadFolder(directory)
        phase = 14
    }

    private func hashes(in directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[url.lastPathComponent] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }

    private func snapshot(_ filename: String, tab: Int, compare: Bool = true) throws {
        let content = ContentView(model: model, initialTab: tab, initialCompare: compare)
        try snapshotView(filename, width: 1400, height: 900, content: content)
    }

    private func snapshotView<Content: View>(_ filename: String, width: CGFloat, height: CGFloat,
                                            content: Content) throws {
        let host = NSHostingView(rootView: content.preferredColorScheme(.dark)
            .tint(AtelierPalette.accent).frame(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw AtelierError.imageWrite("无法创建界面验证快照")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw AtelierError.imageWrite("无法编码界面验证快照")
        }
        try data.write(to: evidence.appendingPathComponent(filename), options: .atomic)
        window.contentView = nil
    }

    private func finish(error: Error?) {
        guard phase != 99 else { return }
        phase = 99; timer?.invalidate()
        let report: [String: Any] = [
            "status": error == nil ? "passed" : "failed",
            "error": error?.localizedDescription ?? "",
            "assertions": assertions,
            "succeeded": model.succeeded,
            "failed": model.failed,
            "seconds": Date().timeIntervalSince(started),
            "lensProfiles": LensCorrection.shared.profiles.count,
            "note": "Application command integration and own-view rendering; not a mouse/keyboard interaction test."
        ]
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence.appendingPathComponent("app-smoke.json"), options: .atomic)
        } catch { fputs("Smoke report write failed: \(error)\n", stderr) }
        print("APP_SMOKE \(error == nil ? "PASS" : "FAIL") · \(assertions.count) checks · \(model.succeeded) exported · \(model.failed) isolated")
        if let error = error { fputs("\(error.localizedDescription)\n", stderr) }
        fflush(stdout); fflush(stderr)
        Darwin.exit(error == nil ? 0 : 1)
    }
}

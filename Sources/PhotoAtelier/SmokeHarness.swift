import AppKit
import CryptoKit
import PhotoCore
import SwiftUI

/// Explicit local integration-test entry point; normal launches never use it.
/// It exercises application commands and renders its own SwiftUI view, without
/// driving other apps or synthesizing system mouse/keyboard events.
enum SmokeHarness {
    private static var session: SmokeSession?
    static func startIfRequested(model: AppModel) {
        let args = CommandLine.arguments
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
                guard model.photos.count >= 2, let preset = LUTCube.builtIns.first else {
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
                try snapshot("02-library.png", tab: 0)
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
                guard let savedRecipe = json?["recipe"] as? [String: Any], savedRecipe["version"] as? Int == 3,
                      completed.allSatisfy({ entry in
                          let report = entry["report"] as? [String: Any]
                          let quality = report?["colorQuality"] as? [String: Any]
                          return quality?["outputColorSpace"] as? String == "displayP3"
                              && report?["lutCompatibility"] is [String: Any]
                      }) else { throw AtelierError.invalidConfiguration("配方版本或逐张色彩保护报告未记录") }
                assertions.append("Recipe v3 and per-photo output gamut / color-protection reports retained")
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
                } else { finish(error: nil) }
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
                finish(error: nil)
            default: break
            }
        } catch { finish(error: error) }
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

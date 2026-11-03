import AppKit
import CryptoKit
import PhotoCore
import SwiftUI

/// Opt-in, local application-command acceptance for a directory of portraits.
/// Normal launches never read a test folder or write acceptance evidence.
final class PortraitSmokeSession {
    private let model: AppModel
    private let input: URL, output: URL, evidence: URL
    private var timer: Timer?
    private var phase = 0
    private let started = Date()
    private var checks: [String] = []
    private var hashes: [String: String] = [:]
    private var firstCoverage = 0.0
    private var firstID: String?

    init(model: AppModel, input: URL, output: URL, evidence: URL) {
        self.model = model; self.input = input; self.output = output; self.evidence = evidence
    }

    func start() {
        do {
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            hashes = try sourceHashes()
            model.loadFolder(input)
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.advance() }
        } catch { finish(error) }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw AtelierError.invalidConfiguration(message) }
        checks.append(message)
    }

    private var ready: Bool { !model.scanning && !model.previewBusy && !model.analysisBusy && model.afterImage != nil }

    private func advance() {
        do {
            guard Date().timeIntervalSince(started) < 240 else {
                throw AtelierError.invalidConfiguration("人像应用流程验证超时（240 秒）")
            }
            if let error = model.errorMessage ?? model.analysisError { throw AtelierError.invalidConfiguration(error) }
            switch phase {
            case 0:
                guard ready, model.proposalPreviews.count == 3 else { return }
                try require(model.photos.count >= 2, "At least two real local portrait inputs loaded")
                firstID = model.selectedID
                model.addContentMask(.people); phase = 1
            case 1:
                guard ready, let report = model.previewReport.contentSelection else { return }
                try require(report.personStatus == "available" && (model.maskInspection?.coverage ?? 0) > 0.01,
                            "People button generates actual Vision coverage on the current portrait")
                try require(model.selectedLocalMask?.exposureEV == 0 && model.selectedLocalMask?.detail == nil,
                            "New semantic selection starts with neutral local adjustments")
                firstCoverage = report.coverage["people"] ?? 0
                try snapshot("portrait-people.png")
                model.addContentMask(.background); phase = 2
            case 2:
                guard ready, let report = model.previewReport.contentSelection else { return }
                let sum = (report.coverage["people"] ?? 0) + (report.coverage["background"] ?? 0)
                try require(abs(sum - 1) < 0.001 && model.maskOverlayImage != nil,
                            "Background button uses the detected person's complement and renders an overlay")
                model.addContentMask(.faceSkin); phase = 3
            case 3:
                guard ready, let report = model.previewReport.contentSelection else { return }
                try require(report.faceStatus == "available" && report.faceCount > 0
                            && (model.maskInspection?.coverage ?? 0) > 0.0005,
                            "Face candidate button generates landmark-based skin coverage")
                model.applyNaturalDetailStartingPoint(); phase = 4
            case 4:
                guard ready, let detail = model.selectedLocalMask?.detail else { return }
                try require(detail == LocalDetailSettings(smoothing: 0.25, textureRetention: 0.9, toneUniformity: 0.12),
                            "Gentle detail starting point is applied through the app command")
                var recipe = model.recipe
                try recipe.validateVersion()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(recipe)
                try data.write(to: evidence.appendingPathComponent("portrait-recipe.json"))
                try require(try JSONDecoder().decode(Recipe.self, from: data) == recipe && recipe.version == 8,
                            "Portrait recipe version seven round-trips all three semantic targets and detail")
                recipe.version = 5
                var rejected = false
                do { try recipe.validateVersion() } catch { rejected = true }
                try require(rejected, "Version five cannot silently carry new portrait operations")
                try snapshot("portrait-face-detail.png")
                if let index = model.activeMaskIndex { model.adjustments.masks[index].detail?.smoothing = 0.4 }
                if let index = model.activeMaskIndex {
                    model.adjustments.masks[index].detailAdaptation = LocalDetailAdaptation()
                }
                model.requestPreview(immediate: true); phase = 40
            case 40:
                guard ready, let plan = model.previewReport.localDetails?.first else { return }
                try require(plan.maskID == model.selectedMask && plan.resolvedIntent == .portrait
                            && plan.measurements.sampleCount >= 128,
                            "Adaptive face detail uses measured current coverage and chooses portrait intent")
                try require((model.selectedLocalMask?.detail?.smoothing ?? 0) == 0.4,
                            "Adaptive mode preserves the stored manual detail settings")
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(model.recipe).write(to: evidence.appendingPathComponent("adaptive-recipe.json"))
                var oldVersion = model.recipe; oldVersion.version = 6
                var rejected = false
                do { try oldVersion.validateVersion() } catch { rejected = true }
                try require(rejected, "Version six rejects adaptive detail instead of silently ignoring it")
                try adaptiveSnapshot()
                if let index = model.activeMaskIndex { model.adjustments.masks[index].detailAdaptation?.strength = 0 }
                model.requestPreview(immediate: true); phase = 41
            case 41:
                guard ready, let plan = model.previewReport.localDetails?.first else { return }
                try require(plan.settings.isNeutral, "Zero adaptive strength yields neutral detail without applying manual detail twice")
                if let index = model.activeMaskIndex { model.adjustments.masks[index].detailAdaptation?.strength = 0.6 }
                model.requestPreview(immediate: true); phase = 5
            case 5:
                guard ready else { return }
                try require(model.previewReport.contentSelection?.coverage["people"] == firstCoverage,
                            "Local-only parameter changes keep the current content reference stable")
                guard let next = model.photos.first(where: { $0.id != firstID }) else { return }
                model.selectPhoto(next)
                try require(model.maskOverlayImage == nil && model.maskInspection == nil
                            && model.previewReport.contentSelection == nil && model.previewReport.localDetails == nil,
                            "Switching photos immediately clears old overlay, measurements and detection status")
                phase = 6
            case 6:
                guard ready, let report = model.previewReport.contentSelection else { return }
                try require(report.personStatus == "available" && report.coverage["people"] != firstCoverage,
                            "The next portrait recomputes its content instead of reusing earlier geometry")
                try require(model.previewReport.localDetails?.first?.maskID == model.selectedMask,
                            "The next portrait recomputes and exposes its own local detail plan")
                try snapshot("portrait-next-photo.png")
                model.resetSelectedMaskAdjustments(); phase = 7
            case 7:
                guard ready else { return }
                try require(model.selectedLocalMask?.detail == nil && model.selectedLocalMask?.detailAdaptation == nil
                            && model.selectedLocalMask?.contentSelection == .faceSkin,
                            "Reset removes local detail without discarding its semantic selection")
                if let index = model.activeMaskIndex { model.adjustments.masks[index].detailAdaptation = LocalDetailAdaptation() }
                model.outputRoot = output; model.exportSettings.format = .tiff
                model.exportSettings.colorSpace = .displayP3
                model.startBatch(); phase = 8
            case 8:
                guard !model.batchRunning, let manifestURL = model.lastManifest else { return }
                try require(model.succeeded == model.photos.count && model.failed == 0,
                            "Real portrait batch exports every input as sixteen-bit Display P3 TIFF")
                let manifest = try JSONDecoder().decode(PortraitManifest.self, from: Data(contentsOf: manifestURL))
                let coverages = manifest.entries.compactMap { $0.report?.contentSelection?.coverage["people"] }
                try require(coverages.count == model.photos.count && Set(coverages).count > 1,
                            "Batch reports contain distinct per-photo semantic coverage")
                let plans = manifest.entries.compactMap { $0.report?.localDetails?.first }
                try require(plans.count == model.photos.count && Set(plans.map { $0.measurements.sampleCount }).count > 1,
                            "Full-size portrait exports contain independently measured adaptive detail plans")
                try require(try sourceHashes() == hashes, "All local original hashes remain unchanged")
                finish(nil)
            default: break
            }
        } catch { finish(error) }
    }

    private func sourceHashes() throws -> [String: String] {
        var values: [String: String] = [:]
        for item in try PhotoLoader.scan(folder: input, recursive: false) {
            values[item.relativePath] = SHA256.hash(data: try Data(contentsOf: item.url))
                .map { String(format: "%02x", $0) }.joined()
        }
        return values
    }

    private func snapshot(_ name: String) throws {
        let view = ContentView(model: model, initialTab: 2, initialCompare: false)
            .preferredColorScheme(.dark).frame(width: 1440, height: 960)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 960)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw AtelierError.imageWrite("无法创建人像界面快照")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw AtelierError.imageWrite("无法编码人像界面快照")
        }
        try data.write(to: evidence.appendingPathComponent(name), options: .atomic)
        window.contentView = nil
    }

    private func adaptiveSnapshot() throws {
        guard let mask = model.selectedLocalMask else { return }
        let view = AdaptiveDetailControls(model: model, mask: mask).padding(20)
            .frame(width: 430, height: 560).background(AtelierPalette.panel)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 430, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host; host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw AtelierError.imageWrite("无法创建逐图细节面板快照")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw AtelierError.imageWrite("无法编码逐图细节面板快照")
        }
        try data.write(to: evidence.appendingPathComponent("adaptive-detail-panel.png"))
        window.contentView = nil
    }

    private func finish(_ error: Error?) {
        guard phase != 99 else { return }
        phase = 99; timer?.invalidate()
        let report: [String: Any] = ["status": error == nil ? "passed" : "failed",
            "error": error?.localizedDescription ?? "", "assertions": checks,
            "seconds": Date().timeIntervalSince(started),
            "note": "App command integration and own-view rendering; not mouse or keyboard interaction."]
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence.appendingPathComponent("portrait-app-smoke.json"))
        } catch { fputs("Portrait smoke report failed: \(error)\n", stderr) }
        print("PORTRAIT_APP_SMOKE \(error == nil ? "PASS" : "FAIL") · \(checks.count) checks")
        if let error { fputs("\(error.localizedDescription)\n", stderr) }
        fflush(stdout); fflush(stderr); Darwin.exit(error == nil ? 0 : 1)
    }
}

private struct PortraitManifest: Decodable {
    struct Entry: Decodable { let report: ProcessingReport? }
    let entries: [Entry]
}

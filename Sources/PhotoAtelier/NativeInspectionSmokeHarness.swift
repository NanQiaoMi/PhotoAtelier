import AppKit
import CryptoKit
import PhotoCore
import SwiftUI

/// Explicit application-command acceptance; never runs on a normal launch.
final class NativeInspectionSmokeSession {
    private let model: AppModel
    private let input: URL, output: URL, evidence: URL
    private var timer: Timer?
    private var phase = 0
    private let started = Date()
    private var checks: [String] = []
    private var hashes: [String: String] = [:]
    private var expectedSettings: AdjustmentSettings?
    private var expectedNative: NativeInspectionFrame?
    private var expectedInput = ""

    init(model: AppModel, input: URL, output: URL, evidence: URL) {
        self.model = model; self.input = input; self.output = output; self.evidence = evidence
    }
    func start() {
        do {
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            DispatchQueue.global(qos: .utility).async { [self] in
                let result = Result { try sourceHashes() }
                DispatchQueue.main.async {
                    do {
                        self.hashes = try result.get()
                        self.model.loadFolder(self.input)
                        self.timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.advance() }
                    } catch { self.finish(error) }
                }
            }
        } catch { finish(error) }
    }
    private var ready: Bool {
        !model.scanning && !model.previewBusy && !model.analysisBusy && model.afterImage != nil
    }
    private var nativeReady: Bool { !model.nativeInspection.busy && model.nativeInspection.frame != nil }
    private func require(_ value: Bool, _ message: String) throws {
        guard value else { throw AtelierError.invalidConfiguration(message) }
        checks.append(message)
    }
    private func advance() {
        do {
            guard Date().timeIntervalSince(started) < 360 else {
                throw AtelierError.invalidConfiguration("原尺寸应用检查超时（360 秒）")
            }
            if let error = model.errorMessage ?? model.analysisError ?? model.nativeInspection.error {
                throw AtelierError.invalidConfiguration(error)
            }
            switch phase {
            case 0:
                guard ready, model.proposalPreviews.count == 3 else { return }
                try require(model.photos.count >= 2, "At least two real local inputs loaded")
                model.addContentMask(.faceSkin); phase = 1
            case 1:
                guard ready, let index = model.activeMaskIndex else { return }
                model.adjustments.masks[index].detailAdaptation = .init()
                model.requestPreview(immediate: true); phase = 2
            case 2:
                guard ready else { return }
                model.openNativeInspection()
                model.updateNativeInspection(pixelSize: 512)
                phase = 3
            case 3:
                guard nativeReady, let frame = model.nativeInspection.frame else { return }
                try require(model.showNativeInspection && frame.image.after.width == 512 && frame.image.after.height == 512,
                    "Native inspection opens with exactly 512 source pixels per side")
                try require(max(frame.image.overview.width, frame.image.overview.height) <= 360,
                    "Only a bounded navigation raster is retained")
                try require(frame.image.report.localDetails?.first?.measurements.sampleCount ?? 0 >= 128,
                    "Native face detail plan measures the full current source")
                try require(frame.resolvedSettings == model.adjustments && !frame.automatic,
                    "Manual inspection preserves current settings")
                try snapshot("native-manual.png")
                guard let index = model.activeMaskIndex else { throw AtelierError.invalidConfiguration("缺少当前蒙版") }
                model.adjustments.masks[index].detailAdaptation?.strength = 0.25
                try require(model.nativeInspection.frame == nil && model.nativeInspection.busy,
                    "Changing the selected detail strength immediately invalidates native pixels")
                model.requestPreview(immediate: true); phase = 31
            case 31:
                guard ready, nativeReady, let frame = model.nativeInspection.frame else { return }
                try require(frame.resolvedSettings.masks.first?.detailAdaptation?.strength == 0.25,
                    "The refreshed native result uses the selected detail strength")
                model.adjustments.exposureEV = 0.23
                try require(model.nativeInspection.frame == nil && model.nativeInspection.busy,
                    "Changing adjustments immediately invalidates the old native result")
                model.requestPreview(immediate: true); phase = 4
            case 4:
                guard ready, nativeReady, let frame = model.nativeInspection.frame else { return }
                try require(abs(frame.resolvedSettings.exposureEV - 0.23) < 0.000001,
                    "Native result uses the latest exposure instead of a stale request")
                model.updateNativeInspection(center: .init(x: 0, y: 0))
                model.updateNativeInspection(center: .init(x: 1, y: 1))
                try require(model.nativeInspection.frame == nil, "Rapid region changes clear earlier pixels")
                phase = 5
            case 5:
                guard nativeReady, let frame = model.nativeInspection.frame else { return }
                try require(frame.image.sampleBounds == model.nativeInspectionRegion.bounds(in: frame.image.outputExtent),
                    "Only the latest bottom-right output-region request is published")
                guard let style = model.analysis?.proposals.first?.id else { return }
                model.applyProposal(style); model.requestPreview(immediate: true); phase = 6
            case 6:
                guard ready else { return }
                expectedSettings = model.adjustments
                model.refreshNativeInspection(immediate: true, force: true)
                phase = 7
            case 7:
                guard nativeReady, let frame = model.nativeInspection.frame else { return }
                try require(frame.automatic && frame.image.report.analysis != nil,
                    "Automatic inspection performs full-source analysis and recipe resolution")
                try require(model.adjustments == expectedSettings,
                    "Full-source inspection does not overwrite the user's visible adjustment settings")
                try snapshot("native-automatic.png")
                guard let last = model.photos.last, last.id != model.selectedID else {
                    throw AtelierError.invalidConfiguration("需要不同的第二张输入")
                }
                model.refreshNativeInspection(immediate: true, force: true)
                model.selectPhoto(last)
                try require(model.nativeInspection.frame == nil && model.nativeInspection.busy,
                    "Switching photos cancels and clears the previous native result immediately")
                phase = 8
            case 8:
                guard ready, nativeReady, let frame = model.nativeInspection.frame, let photo = model.selectedPhoto else { return }
                try require(frame.image.report.localDetails?.first?.measurements.sampleCount ?? 0 >= 128,
                    "The replacement photo receives its own full-source detail plan")
                expectedNative = frame; expectedInput = photo.relativePath
                try snapshot("native-next-photo.png")
                model.refreshNativeInspection(immediate: true, force: true); phase = 81
            case 81:
                guard model.nativeInspection.workerActive else { return }
                model.closeNativeInspection()
                try require(!model.showNativeInspection && !model.nativeInspection.busy && model.nativeInspection.frame == nil,
                    "Closing inspection cancels work and releases the displayed rasters")
                model.openNativeInspection(); phase = 9
            case 9:
                guard nativeReady, let frame = model.nativeInspection.frame else { return }
                expectedNative = frame
                model.outputRoot = output; model.exportSettings.format = .tiff; model.exportSettings.colorSpace = .displayP3
                // Recheck using the same export space before comparing with the batch.
                model.refreshNativeInspection(immediate: true, force: true); phase = 10
            case 10:
                guard nativeReady, let frame = model.nativeInspection.frame else { return }
                expectedNative = frame
                model.refreshNativeInspection(immediate: true, force: true); phase = 101
            case 101:
                guard model.nativeInspection.workerActive else { return }
                model.startBatch()
                try require(!model.showNativeInspection && model.nativeInspection.frame == nil && !model.nativeInspection.busy,
                    "Starting batch export closes and invalidates inspection")
                try require(model.batchRunning && model.processed == 0 && model.currentFile == "准备导出…",
                    "Batch starts queued while the cancelled native worker drains")
                phase = 11
            case 11:
                if model.nativeInspection.workerActive {
                    try require(model.processed == 0 && model.currentFile == "准备导出…",
                        "Batch decoding waits until the active native worker exits")
                    return
                }
                guard !model.batchRunning, let manifest = model.lastManifest, let expectedNative else { return }
                try require(model.failed == 0 && model.succeeded == model.photos.count,
                    "All real inputs export successfully after native inspection")
                let batch = try JSONDecoder().decode(InspectionBatch.self, from: Data(contentsOf: manifest))
                let report = batch.entries.first { $0.input == expectedInput }?.report
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(expectedNative.image.report).write(to: evidence.appendingPathComponent("native-final-report.json"))
                try encoder.encode(expectedNative.resolvedSettings).write(to: evidence.appendingPathComponent("native-final-settings.json"))
                try encoder.encode(report).write(to: evidence.appendingPathComponent("batch-matched-report.json"))
                // Compare through the same manifest serialization boundary;
                // JSONDecoder can round floating point values by one ULP.
                let persistedExpected = try JSONDecoder().decode(ProcessingReport.self,
                    from: encoder.encode(expectedNative.image.report))
                try require(report?.localDetails == persistedExpected.localDetails,
                    "Automatic batch export and native inspection resolve identical per-photo detail plans")
                try require(abs((report?.appliedExposureEV ?? -100) - expectedNative.image.report.appliedExposureEV) < 0.000001,
                    "Automatic batch and native inspection apply the same resolved global exposure")
                phase = 12
                DispatchQueue.global(qos: .utility).async { [self] in
                    let result = Result { try sourceHashes() }
                    DispatchQueue.main.async {
                        do {
                            try self.require(try result.get() == self.hashes, "All local original hashes remain unchanged")
                            self.finish(nil)
                        } catch { self.finish(error) }
                    }
                }
            default: break
            }
        } catch { finish(error) }
    }

    private func sourceHashes() throws -> [String: String] {
        var result: [String: String] = [:]
        for item in try PhotoLoader.scan(folder: input, recursive: false) {
            let handle = try FileHandle(forReadingFrom: item.url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
            result[item.relativePath] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
    private func snapshot(_ name: String) throws {
        let host = NSHostingView(rootView: NativeInspectionView(model: model, controller: model.nativeInspection))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 780)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host; host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw AtelierError.imageWrite("无法创建原尺寸检查面板快照")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw AtelierError.imageWrite("无法编码原尺寸检查面板快照")
        }
        try data.write(to: evidence.appendingPathComponent(name), options: .atomic)
        window.contentView = nil
    }
    private func finish(_ error: Error?) {
        guard phase != 99 else { return }
        phase = 99; timer?.invalidate(); model.closeNativeInspection()
        let report: [String: Any] = ["status": error == nil ? "passed" : "failed", "error": error?.localizedDescription ?? "",
            "assertions": checks, "seconds": Date().timeIntervalSince(started),
            "note": "Application commands and own-view rendering, not mouse/keyboard/dialog acceptance."]
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence.appendingPathComponent("native-inspection-smoke.json"))
        } catch { fputs("Native inspection report failed: \(error)\n", stderr) }
        print("NATIVE_INSPECTION_APP \(error == nil ? "PASS" : "FAIL") · \(checks.count) checks")
        if let error { fputs("\(error.localizedDescription)\n", stderr) }
        fflush(stdout); fflush(stderr); Darwin.exit(error == nil ? 0 : 1)
    }
}

private struct InspectionBatch: Decodable {
    struct Entry: Decodable { let input: String; let report: ProcessingReport? }
    let entries: [Entry]
}

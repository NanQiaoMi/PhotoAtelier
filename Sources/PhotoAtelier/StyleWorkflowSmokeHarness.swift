import AppKit
import CoreImage
import CryptoKit
import PhotoCore
import SwiftUI

/// Explicit, isolated application-command checks; does not drive the mouse or dialogs.
final class StyleWorkflowSmokeSession {
    private let model: AppModel
    private let input: URL, output: URL, evidence: URL
    private var phase = 0
    private var timer: Timer?
    private let started = Date()
    private var checks: [String] = []
    private var sourceHashes: [String: String] = [:]
    private var reference: CIImage?
    private var countBeforeImport = 0
    private var heartbeat = Date()
    private var maximumImportHeartbeatGap = 0.0
    private var phaseStarted = Date()
    private var timings: [String: Double] = [:]
    private var retainedStyle: NSImage?

    init(model: AppModel, input: URL, output: URL, evidence: URL) {
        self.model = model; self.input = input; self.output = output; self.evidence = evidence
    }

    func start() {
        do {
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            DispatchQueue.global(qos: .utility).async { [self] in
                let result = Result { () throws -> [String: String] in
                    let hashes = try hashes()
                    // A nontrivial parser workload, built away from the UI thread.
                    let dimension = 64
                    var cube = "TITLE \"Acceptance Identity\"\nLUT_3D_SIZE 64\n"
                    for b in 0..<dimension {
                        for g in 0..<dimension {
                            for r in 0..<dimension {
                                cube += "\(Double(r)/63) \(Double(g)/63) \(Double(b)/63)\n"
                            }
                        }
                    }
                    try cube.write(to: evidence.appendingPathComponent("valid.cube"), atomically: true, encoding: .utf8)
                    try "LUT_3D_SIZE 3\n0 0 0\n".write(to: evidence.appendingPathComponent("invalid.cube"), atomically: true, encoding: .utf8)
                    return hashes
                }
                DispatchQueue.main.async {
                    do {
                        self.sourceHashes = try result.get()
                        self.model.loadFolder(self.input)
                        self.timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.advance() }
                    } catch { self.finish(error) }
                }
            }
        } catch { finish(error) }
    }

    private var ready: Bool { !model.scanning && !model.previewBusy && !model.analysisBusy && model.afterImage != nil }
    private func require(_ value: Bool, _ text: String) throws {
        guard value else { throw AtelierError.invalidConfiguration(text) }
        checks.append(text)
    }
    private func requestStyles(_ options: [LUTOption]) {
        model.stylePreviews.request(source: model.styleReference, options: options, adjustments: model.adjustments,
            outputSpace: model.exportSettings.colorSpace, colorContracts: model.lutColorContracts)
    }

    private func advance() {
        let now = Date()
        if phase == 1 { maximumImportHeartbeatGap = max(maximumImportHeartbeatGap, now.timeIntervalSince(heartbeat)) }
        heartbeat = now
        do {
            guard now.timeIntervalSince(started) < 300 else { throw AtelierError.invalidConfiguration("风格工作流验证超时") }
            if let error = model.errorMessage ?? model.analysisError ?? model.stylePreviews.error {
                throw AtelierError.invalidConfiguration(error)
            }
            switch phase {
            case 0:
                guard ready, !model.lutLibraryBusy, model.proposalPreviews.count == 3 else { return }
                try require(model.lutOptions.count == 14, "Thirteen built-in LUTs plus original color are available")
                countBeforeImport = model.lutOptions.count
                model.importLUTFiles([evidence.appendingPathComponent("valid.cube"), evidence.appendingPathComponent("invalid.cube")])
                model.outputRoot = output; model.startBatch()
                try require(!model.batchRunning, "Batch start waits for the LUT library mutation to finish")
                heartbeat = now; phaseStarted = now; phase = 1
            case 1:
                guard !model.lutLibraryBusy, ready else { return }
                timings["importSeconds"] = now.timeIntervalSince(phaseStarted)
                try require(model.lutOptions.count == countBeforeImport + 1 && model.lutLibraryMessages.count == 1,
                            "Multi-file LUT import isolates a corrupt file and retains the valid file")
                try require(model.lutImportCompleted == 2, "Import progress reaches both files")
                try require(maximumImportHeartbeatGap < 0.5, "Main run loop stays responsive during a 64-cube parse (gap under 500 ms)")
                model.importLUTFiles([evidence.appendingPathComponent("valid.cube"), evidence.appendingPathComponent("valid.cube")])
                model.cancelLUTImport(); phase = 11
            case 11:
                guard !model.lutLibraryBusy else { return }
                try require(model.lutOptions.count == countBeforeImport + 1,
                            "Cancelled LUT imports cannot append uncommitted files")
                let custom = model.selectedLUT
                model.adjustments.lutColorSpace = .displayP3; model.rememberLUTSpace()
                model.selectLUT("fresh-portrait"); model.selectLUT(custom)
                try require(model.adjustments.lutColorSpace == .displayP3, "Custom LUT color contract survives switching away and back")
                model.selectLUT("fresh-portrait"); model.adoptRecommendedLUTIntensity()
                model.requestPreview(immediate: true); phase = 2
            case 2:
                guard ready else { return }
                reference = model.styleReference
                model.adjustments.creativeEffects = .init(bloom: 0.35, vignette: 0.25, grain: 0.3)
                model.requestPreview(immediate: true); phaseStarted = now; phase = 3
            case 3:
                guard ready else { return }
                try require(reference === model.styleReference, "LUT and effects reuse the unchanged global measurement reference")
                requestStyles(Array(model.lutOptions.prefix(14))); phaseStarted = now; phase = 4
            case 4:
                guard !model.stylePreviews.busy, model.stylePreviews.images.count == 14 else { return }
                timings["fourteenStyleThumbnailsSeconds"] = now.timeIntervalSince(phaseStarted)
                try require(model.stylePreviews.images.values.allSatisfy { max($0.size.width, $0.size.height) <= 240 },
                            "All style comparison rasters are bounded to 240 pixels")
                try snapshot(StyleBrowserView(model: model, previews: model.stylePreviews, managesRequests: false), name: "style-browser.png", size: .init(width: 920, height: 700))
                retainedStyle = model.stylePreviews.images["none"]
                model.selectLUT("coastal-light"); model.requestPreview(immediate: true); phase = 41
            case 41:
                guard ready else { return }
                requestStyles(Array(model.lutOptions.prefix(14)))
                try require(!model.stylePreviews.busy && model.stylePreviews.images["none"] === retainedStyle,
                            "Choosing a LUT reuses existing style rasters instead of rebuilding the whole shelf")
                model.stylePreviews.cancel()
                requestStyles(Array(model.lutOptions.prefix(14)))
                requestStyles(Array(model.lutOptions.filter { $0.id == "coastal-light" }))
                phase = 5
            case 5:
                guard !model.stylePreviews.busy, model.stylePreviews.images.count == 1 else { return }
                try require(model.stylePreviews.images["coastal-light"] != nil,
                            "Cancelled style generations cannot repopulate the latest comparison")
                var invalid = model.adjustments
                invalid.creativeEffects = .init(grain: 2)
                model.stylePreviews.request(source: model.styleReference, options: Array(model.lutOptions.prefix(2)),
                    adjustments: invalid, outputSpace: model.exportSettings.colorSpace)
                phase = 51
            case 51:
                guard !model.stylePreviews.busy, model.stylePreviews.completed == 2 else { return }
                try require(model.stylePreviews.cardErrors.count == 2 && model.stylePreviews.error == nil,
                            "Failed style cards report separate errors and finish instead of stopping the list")
                for id in ["warm-light", "silver-salt", "creamy-soft", "coastal-light"] {
                    model.selectLUT(id); model.requestPreview(immediate: true)
                }
                model.selectLUT("fresh-portrait"); model.requestPreview(immediate: true)
                phaseStarted = now; phase = 6
            case 6:
                guard ready else { return }
                timings["latestPreviewSeconds"] = now.timeIntervalSince(phaseStarted)
                try require(model.selectedLUT == "fresh-portrait" && abs(model.adjustments.lutIntensity - 0.34) < 1e-9,
                            "Rapid look selection keeps the latest look and the user's chosen strength")
                model.openNativeInspection(); model.updateNativeInspection(pixelSize: 512); phase = 7
            case 7:
                guard !model.nativeInspection.busy, let frame = model.nativeInspection.frame else { return }
                try require(frame.resolvedSettings.creativeEffects == model.adjustments.creativeEffects,
                            "Native inspection resolves the same creative effects")
                try snapshot(ContentView(model: model, initialTab: 1), name: "effects-workbench.png", size: .init(width: 1400, height: 900))
                let encoded = try JSONEncoder().encode(model.recipe)
                let restored = try JSONDecoder().decode(Recipe.self, from: encoded)
                try require(restored.version == 8 && restored.adjustments.creativeEffects == model.adjustments.creativeEffects,
                            "Recipe v8 round-trips selected effects")
                model.closeNativeInspection()
                model.exportSettings.format = .tiff; model.exportSettings.colorSpace = .displayP3
                model.outputRoot = output; model.startBatch(); phase = 8
            case 8:
                guard !model.batchRunning, let manifest = model.lastManifest else { return }
                try require(model.succeeded == model.photos.count && model.failed == 0,
                            "All application inputs export as 16-bit Display P3 TIFF")
                let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
                let recipe = json?["recipe"] as? [String: Any]
                let adjustments = recipe?["adjustments"] as? [String: Any]
                try require(recipe?["version"] as? Int == 8 && adjustments?["creativeEffects"] != nil,
                            "Batch manifest freezes the v8 creative settings")
                phase = 9
                DispatchQueue.global(qos: .utility).async { [self] in
                    let result = Result { try hashes() }
                    DispatchQueue.main.async {
                        do { try self.require(try result.get() == self.sourceHashes, "All original source hashes remain unchanged"); self.finish(nil) }
                        catch { self.finish(error) }
                    }
                }
            default: break
            }
        } catch { finish(error) }
    }

    private func hashes() throws -> [String: String] {
        var result: [String: String] = [:]
        for item in try PhotoLoader.scan(folder: input, recursive: false) {
            result[item.relativePath] = SHA256.hash(data: try Data(contentsOf: item.url, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
    private func snapshot<V: View>(_ view: V, name: String, size: CGSize) throws {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua); window.contentView = host
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AtelierError.imageWrite("无法创建风格快照") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AtelierError.imageWrite("无法编码风格快照") }
        try data.write(to: evidence.appendingPathComponent(name), options: .atomic)
        window.contentView = nil
    }
    private func finish(_ error: Error?) {
        guard phase != 99 else { return }; phase = 99; timer?.invalidate(); model.stylePreviews.cancel()
        let report: [String: Any] = ["status": error == nil ? "passed" : "failed", "error": error?.localizedDescription ?? "",
            "assertions": checks, "seconds": Date().timeIntervalSince(started), "timings": timings,
            "maximumImportHeartbeatGap": maximumImportHeartbeatGap,
            "note": "Application commands and own-view snapshots, not mouse, keyboard or file-dialog acceptance."]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("style-workflow-smoke.json"), options: .atomic) }
        catch { fputs("Style workflow report failed\n", stderr) }
        print("STYLE_WORKFLOW_APP \(error == nil ? "PASS" : "FAIL") · \(checks.count) checks")
        if let error = error { fputs("\(error.localizedDescription)\n", stderr) }
        fflush(stdout); fflush(stderr); Darwin.exit(error == nil ? 0 : 1)
    }
}

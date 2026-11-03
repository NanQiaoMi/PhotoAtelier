import AppKit
import Combine
import CoreImage
import Foundation
import PhotoCore

struct NativeInspectionFrame {
    let image: NativeInspectionResult
    let resolvedSettings: AdjustmentSettings
    let automatic: Bool
    let seconds: Double
}

/// Called on the main thread; all decode and processing work is serial off-main.
/// Retains only the bounded result, never LoadedPhoto or its full RAW graph.
final class NativeInspectionController: ObservableObject {
    @Published private(set) var frame: NativeInspectionFrame?
    @Published private(set) var busy = false
    /// Unlike `busy`, cancellation leaves this true until synchronous work exits.
    @Published private(set) var workerActive = false
    @Published private(set) var error: String?
    private let queue: DispatchQueue
    private var pending: DispatchWorkItem?
    private var token: CancellationToken?
    private var generation = UUID()
    private var key: Key?
    private struct Key: Equatable {
        let url: URL
        let recipe: Recipe
        let lutID: String
        let region: NativeInspectionRegion
    }

    init(queue: DispatchQueue = DispatchQueue(label: "atelier.native-inspection", qos: .userInitiated)) {
        self.queue = queue
    }

    func cancel() {
        pending?.cancel(); token?.cancel(); generation = UUID()
        pending = nil; token = nil; key = nil; frame = nil; error = nil; busy = false
    }

    func request(photo: PhotoItem, recipe: Recipe, lut: LUTCube?, lutID: String,
                 region: NativeInspectionRegion, immediate: Bool = false, force: Bool = false) {
        let next = Key(url: photo.url, recipe: recipe, lutID: lutID, region: region)
        if !force, key == next, busy || frame != nil { return }
        cancel()
        key = next; busy = true
        let current = generation
        let token = CancellationToken(); self.token = token
        let item = DispatchWorkItem { [weak self] in
            guard let self, !token.isCancelled else { return }
            DispatchQueue.main.async { self.workerActive = true }
            let outcome: Result<NativeInspectionFrame, Error> = autoreleasepool {
                let engine = PhotoEngine()
                defer { engine.context.clearCaches() }
                return Result {
                    try token.check(); try recipe.validateVersion(); try region.validate()
                    try PhotoEngine.validate(recipe.adjustments); try recipe.automatic?.validate()
                    let started = Date()
                    let sourceStamp = try photo.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let loaded = try PhotoLoader.load(url: photo.url, lensCorrection: recipe.adjustments.lensCorrection,
                        lensProfileID: recipe.adjustments.lensProfileID, lensCropFactor: recipe.adjustments.lensCropFactor,
                        lensFocalLength: recipe.adjustments.lensFocalLength)
                    try token.check()
                    var settings = recipe.adjustments, report = loaded.report
                    if let automatic = recipe.automatic {
                        // Match BatchProcessor's full-source analysis and resolve order.
                        let analysis = try PhotoAnalyzer().analyze(image: loaded.image, properties: loaded.properties,
                            sourceURL: photo.url, baseline: automatic.baseline, intent: automatic.sceneIntent ?? .automatic)
                        try token.check()
                        settings = try automatic.resolve(analysis: analysis, current: settings)
                        report.analysis = AutomaticAnalysisRecord(analysis: analysis,
                            selectedProposal: automatic.styleID, applied: settings)
                    }
                    let rendered = try NativeInspectionRenderer(engine: engine).render(loaded.image,
                        settings: settings, lut: lut, outputColorSpace: recipe.export.colorSpace,
                        initialReport: report, region: region, cancellation: token)
                    try token.check()
                    let afterStamp = try photo.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    guard sourceStamp.contentModificationDate == afterStamp.contentModificationDate,
                          sourceStamp.fileSize == afterStamp.fileSize else {
                        throw AtelierError.imageRead("原文件在检查期间发生变化，请重新检查。")
                    }
                    return NativeInspectionFrame(image: rendered, resolvedSettings: settings,
                        automatic: recipe.automatic != nil, seconds: Date().timeIntervalSince(started))
                }
            }
            DispatchQueue.main.async {
                self.workerActive = false
                guard self.generation == current, !token.isCancelled else { return }
                self.busy = false; self.pending = nil; self.token = nil
                switch outcome {
                case .success(let frame): self.frame = frame
                case .failure(let error): self.error = error.localizedDescription; self.key = nil
                }
            }
        }
        pending = item
        queue.asyncAfter(deadline: .now() + (immediate ? 0 : 0.45), execute: item)
    }
}

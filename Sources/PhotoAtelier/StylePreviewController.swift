import AppKit
import Combine
import CoreImage
import PhotoCore

/// Small comparison rasters only. Full previews and exports keep their normal pipeline.
final class StylePreviewController: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var cardErrors: [String: String] = [:]
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    private let queue: DispatchQueue
    private let engine = PhotoEngine()
    private var token: CancellationToken?
    private var generation = UUID()
    private struct RequestKey: Equatable {
        let source: ObjectIdentifier
        let options: [String]
        let settings: AdjustmentSettings
        let outputSpace: OutputColorSpace
        let spaces: [String: String]
    }
    private var lastRequest: RequestKey?

    init(queue: DispatchQueue) { self.queue = queue }

    func cancel() {
        token?.cancel(); token = nil; generation = UUID()
        images = [:]; cardErrors = [:]; busy = false; completed = 0; total = 0; error = nil
        lastRequest = nil
    }

    func request(source: CIImage?, options: [LUTOption], adjustments: AdjustmentSettings,
                 outputSpace: OutputColorSpace, colorContracts: [String: String] = [:]) {
        guard let source = source, !options.isEmpty else { cancel(); return }
        var style = AdjustmentSettings()
        let remembered = colorContracts.filter { contract in options.contains { $0.id == contract.key } }
        style.lutIntensity = adjustments.lutIntensity
        style.preserveLuminance = adjustments.preserveLuminance
        style.protectSkin = adjustments.protectSkin
        style.protectNeutrals = adjustments.protectNeutrals
        style.gamutCompression = adjustments.gamutCompression
        style.colorHarmony = adjustments.colorHarmony
        style.creativeEffects = adjustments.creativeEffects
        let key = RequestKey(source: ObjectIdentifier(source), options: options.map(\.id), settings: style,
                             outputSpace: outputSpace, spaces: remembered)
        guard lastRequest != key else { return }
        cancel(); lastRequest = key
        let token = CancellationToken(); self.token = token
        let generation = self.generation
        busy = true; total = options.count
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, !token.isCancelled else { return }
            do {
                let small = try autoreleasepool { () throws -> CIImage in
                    let extent = source.extent
                    let scale = min(1, 240 / max(extent.width, extent.height))
                    let scaled = source.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
                        .transformed(by: .init(scaleX: scale, y: scale))
                    let working = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
                    guard let baked = self.engine.context.createCGImage(scaled, from: scaled.extent,
                                format: .RGBAh, colorSpace: working, deferred: false) else {
                        throw AtelierError.imageRead("无法准备风格缩图")
                    }
                    try token.check()
                    return CIImage(cgImage: baked)
                }
                self.renderNext(0, source: small, options: options, settings: style,
                                space: outputSpace, spaces: remembered, token: token, generation: generation)
            } catch { self.fail(error, token: token, generation: generation) }
        }
    }

    private func renderNext(_ index: Int, source: CIImage, options: [LUTOption], settings: AdjustmentSettings,
                            space: OutputColorSpace, spaces: [String: String], token: CancellationToken, generation: UUID) {
        // One card per queue job lets current-photo work enter between cards.
        queue.async { [weak self] in
            guard let self = self, !token.isCancelled else { return }
            do {
                let cg = try autoreleasepool { () throws -> CGImage in
                    var selected = settings
                    selected.lutColorSpace = options[index].path == nil ? .sRGB :
                        LUTColorSpace(rawValue: spaces[options[index].id] ?? "") ?? .sRGB
                    let result = try self.engine.process(source, settings: selected, lut: options[index].cube,
                                                         outputColorSpace: space, cancellation: token)
                    let raster = try PreviewRaster.make(result.image, context: self.engine.context,
                                                        colorSpace: space.cgColorSpace)
                    try token.check()
                    return raster
                }
                DispatchQueue.main.async {
                    guard self.generation == generation, !token.isCancelled else { return }
                    self.images[options[index].id] = NSImage(cgImage: cg, size: .zero)
                    self.completed = index + 1
                    if index + 1 == options.count { self.busy = false }
                    else { self.renderNext(index + 1, source: source, options: options, settings: settings,
                                          space: space, spaces: spaces, token: token, generation: generation) }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.generation == generation, !token.isCancelled else { return }
                    self.cardErrors[options[index].id] = error.localizedDescription
                    self.completed = index + 1
                    if index + 1 == options.count { self.busy = false }
                    else { self.renderNext(index + 1, source: source, options: options, settings: settings,
                                          space: space, spaces: spaces, token: token, generation: generation) }
                }
            }
        }
    }

    private func fail(_ error: Error, token: CancellationToken, generation: UUID) {
        DispatchQueue.main.async {
            guard self.generation == generation, !token.isCancelled else { return }
            self.busy = false; self.error = error.localizedDescription
        }
    }
}

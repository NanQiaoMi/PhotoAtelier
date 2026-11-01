import AppKit
import Combine
import CoreImage
import PhotoCore
import UniformTypeIdentifiers

struct LUTOption: Identifiable {
    let id: String
    let name: String
    let detail: String
    let cube: LUTCube?
    let path: String?
}

final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var inputRoot: URL?
    @Published var outputRoot: URL?
    @Published var photos: [PhotoItem] = []
    @Published var selectedID: String?
    @Published var adjustments = AdjustmentSettings()
    @Published var exportSettings = ExportSettings()
    @Published var lutOptions: [LUTOption] = []
    @Published var selectedLUT = "none"
    @Published var beforeImage: NSImage?
    @Published var afterImage: NSImage?
    @Published var histogram = Array(repeating: 0.0, count: 64)
    @Published var previewReport = ProcessingReport()
    @Published var previewBusy = false
    @Published var scanning = false
    @Published var batchRunning = false
    @Published var processed = 0
    @Published var succeeded = 0
    @Published var failed = 0
    @Published var currentFile = ""
    @Published var status = "选择一个照片文件夹，开始你的调色工作。"
    @Published var errorMessage: String?
    @Published var batchMessages: [String] = []
    @Published var selectedMask: UUID?
    @Published var drawingMask = false
    @Published var maskKind: MaskKind = .radial
    @Published var showMaskOverlay = true
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var lastManifest: URL?
    @Published var analysis: PhotoAnalysis?
    @Published var analysisBusy = false
    @Published var analysisError: String?
    @Published var proposalPreviews: [String: NSImage] = [:]
    @Published private(set) var automaticRecipe: AutomaticBatchRecipe?
    private let previewQueue = DispatchQueue(label: "atelier.preview", qos: .userInitiated)
    private let batchQueue = DispatchQueue(label: "atelier.batch", qos: .userInitiated)
    private let scanQueue = DispatchQueue(label: "atelier.scan", qos: .utility)
    private let analysisQueue = DispatchQueue(label: "atelier.analysis", qos: .userInitiated)
    private var analysisSourceKey: String?
    private var analysisGeneration = UUID()
    private var analysisBaseline = AdjustmentSettings()
    private var analysisImage: CIImage?
    private var proposalSettings: AdjustmentSettings?
    private var proposalLUTID: String?
    private var proposalToken: CancellationToken?
    private var pendingPreview: DispatchWorkItem?
    private var previewToken: CancellationToken?
    private var batchToken: CancellationToken?
    private var previewGeneration = UUID()
    private var scanGeneration = UUID()
    private var thumbnailPending = Set<String>()
    private let engine = PhotoEngine()
    /// Accessed only on previewQueue; retains one bounded preview, never the full RAW graph.
    private var cachedPreviewKey: String?
    private var cachedPreview: LoadedPhoto?
    private var rememberedSpaces: [String: String] = UserDefaults.standard.dictionary(forKey: "lutColorSpaces") as? [String: String] ?? [:]

    var selectedPhoto: PhotoItem? { photos.first { $0.id == selectedID } }
    var selectedOption: LUTOption? { lutOptions.first { $0.id == selectedLUT } }
    var activeMaskIndex: Int? { adjustments.masks.firstIndex { $0.id == selectedMask } }
    var recipe: Recipe {
        Recipe(adjustments: adjustments, export: exportSettings,
               lutPath: selectedOption?.path,
               lutIdentifier: selectedLUT == "none" || selectedOption?.path != nil ? nil : selectedLUT,
               automatic: automaticRecipe)
    }
    var progress: Double { photos.isEmpty ? 0 : Double(processed) / Double(photos.count) }

    private var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoAtelier", isDirectory: true)
    }

    init() {
        lutOptions = [LUTOption(id: "none", name: "原色", detail: "只做基础调整", cube: nil, path: nil)]
            + LUTCube.builtIns.map { LUTOption(id: $0.id, name: $0.name, detail: $0.detail, cube: $0.cube, path: nil) }
        let library = supportRoot.appendingPathComponent("LUTs", isDirectory: true)
        if let urls = try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil) {
            for url in urls.filter({ $0.pathExtension.lowercased() == "cube" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let cube = try? LUTCube.load(url: url) {
                    lutOptions.append(LUTOption(id: url.path, name: cube.title, detail: "自定义 LUT", cube: cube, path: url.path))
                }
            }
        }
    }

    func chooseInput() {
        let panel = NSOpenPanel()
        panel.title = "选择照片文件夹"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "打开文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFolder(url)
    }

    func loadFolder(_ url: URL) {
        guard !batchRunning else { return }
        pendingPreview?.cancel(); previewToken?.cancel(); previewGeneration = UUID()
        previewBusy = false; previewReport = .init(); histogram = Array(repeating: 0, count: 64)
        invalidateAnalysis()
        inputRoot = url
        photos = []; selectedID = nil; beforeImage = nil; afterImage = nil; thumbnails = [:]
        reloadFolder()
    }

    func reloadFolder() {
        guard let root = inputRoot, !batchRunning else { return }
        let generation = UUID(); scanGeneration = generation
        let recursive = exportSettings.recursive
        scanning = true; status = "正在扫描照片…"
        scanQueue.async { [weak self] in
            let result = Result { try PhotoLoader.scan(folder: root, recursive: recursive) }
            DispatchQueue.main.async {
                guard let self = self, self.scanGeneration == generation else { return }
                self.scanning = false
                switch result {
                case .success(let items):
                    self.photos = items
                    if !items.contains(where: { $0.id == self.selectedID }) { self.selectedID = items.first?.id }
                    self.status = items.isEmpty ? "此文件夹中没有支持的照片。" : "已载入 \(items.count) 张照片 · 原图保持不变"
                    self.requestPreview(immediate: true)
                case .failure(let error): self.present(error)
                }
            }
        }
    }

    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.title = "选择导出文件夹（与原图目录分开）"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "选择导出位置"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputRoot = url
    }

    func importLUT() {
        let panel = NSOpenPanel()
        panel.title = "导入 3D .cube LUT"
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 48_000_000 else { throw AtelierError.invalidLUT("文件超过 48 MB") }
            guard let text = String(data: data, encoding: .utf8) else { throw AtelierError.invalidLUT("请选择 UTF-8 文本 .cube") }
            let cube = try LUTCube.parse(text)
            let library = supportRoot.appendingPathComponent("LUTs", isDirectory: true)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let target = library.appendingPathComponent(UUID().uuidString + ".cube")
            try data.write(to: target, options: .atomic)
            lutOptions.append(LUTOption(id: target.path, name: cube.title, detail: "自定义 · 请确认输入空间", cube: cube, path: target.path))
            selectedLUT = target.path
            adjustments.lutColorSpace = .sRGB
            status = "已导入 \(cube.title)。请确认 LUT 的输入空间；Log / HDR LUT 需先转换。"
            requestPreview(immediate: true)
        } catch { present(error) }
    }

    func selectLUT(_ id: String) {
        selectedLUT = id
        if selectedOption?.path == nil { adjustments.lutColorSpace = .sRGB }
        else { adjustments.lutColorSpace = LUTColorSpace(rawValue: rememberedSpaces[id] ?? "") ?? .sRGB }
    }

    func rememberLUTSpace() {
        guard selectedOption?.path != nil else { return }
        rememberedSpaces[selectedLUT] = adjustments.lutColorSpace.rawValue
        UserDefaults.standard.set(rememberedSpaces, forKey: "lutColorSpaces")
    }

    func selectPhoto(_ photo: PhotoItem) {
        guard selectedID != photo.id else { return }
        selectedID = photo.id
        beforeImage = nil; afterImage = nil
        invalidateAnalysis()
        requestPreview(immediate: true)
    }

    func loadThumbnail(_ item: PhotoItem) {
        guard thumbnails[item.id] == nil, !thumbnailPending.contains(item.id) else { return }
        thumbnailPending.insert(item.id)
        scanQueue.async { [weak self] in
            let cg = try? PhotoLoader.thumbnail(url: item.url, maxDimension: 112)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.thumbnailPending.remove(item.id)
                if let cg = cg, self.photos.contains(where: { $0.id == item.id }) {
                    if self.thumbnails.count > 256 { self.thumbnails.removeAll(keepingCapacity: true) }
                    self.thumbnails[item.id] = NSImage(cgImage: cg, size: .zero)
                }
            }
        }
    }

    func requestPreview(immediate: Bool = false) {
        pendingPreview?.cancel(); previewToken?.cancel()
        let generation = UUID(); previewGeneration = generation
        guard let photo = selectedPhoto else { previewBusy = false; return }
        let settings = adjustments; let cube = selectedOption?.cube
        let token = CancellationToken(); previewToken = token
        previewBusy = true
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, !token.isCancelled else { return }
            do {
                let version = try photo.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let cacheParts: [String] = [photo.url.path, String(settings.lensCorrection),
                                            settings.lensProfileID ?? "auto", String(settings.lensCropFactor),
                                            String(settings.lensFocalLength),
                                            String(version.contentModificationDate?.timeIntervalSince1970 ?? 0),
                                            String(version.fileSize ?? 0)]
                let cacheKey = cacheParts.joined(separator: ":")
                let loaded: LoadedPhoto
                if self.cachedPreviewKey == cacheKey, let cached = self.cachedPreview {
                    loaded = cached
                } else {
                    let decoded = try PhotoLoader.load(url: photo.url, lensCorrection: settings.lensCorrection,
                                                       lensProfileID: settings.lensProfileID,
                                                       lensCropFactor: settings.lensCropFactor,
                                                       lensFocalLength: settings.lensFocalLength)
                    try token.check()
                    let extent = decoded.image.extent
                    let scale = min(1, 1500 / max(extent.width, extent.height))
                    let scaled = decoded.image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    let working = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
                    guard let baked = self.engine.context.createCGImage(scaled, from: scaled.extent,
                                                                         format: .RGBAh, colorSpace: working) else {
                        throw AtelierError.imageRead("预览解码失败")
                    }
                    loaded = LoadedPhoto(image: CIImage(cgImage: baked), properties: decoded.properties, report: decoded.report)
                    self.cachedPreviewKey = cacheKey; self.cachedPreview = loaded
                }
                try token.check()
                let small = loaded.image
                let output = try self.engine.process(small, settings: settings, lut: cube, initialReport: loaded.report, cancellation: token)
                let space = CGColorSpace(name: CGColorSpace.sRGB)!
                guard let before = self.engine.context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: space),
                      let after = self.engine.context.createCGImage(output.image, from: output.image.extent, format: .RGBA8, colorSpace: space) else {
                    throw AtelierError.imageRead("预览渲染失败")
                }
                let histogram = self.makeHistogram(output.image)
                try token.check()
                DispatchQueue.main.async {
                    guard self.previewGeneration == generation else { return }
                    self.beforeImage = NSImage(cgImage: before, size: .zero)
                    self.afterImage = NSImage(cgImage: after, size: .zero)
                    self.previewReport = output.report; self.histogram = histogram
                    self.previewBusy = false
                    self.enqueueAnalysis(loaded, photo: photo, key: cacheKey)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.previewGeneration == generation else { return }
                    self.previewBusy = false
                    if !token.isCancelled { self.afterImage = nil; self.present(error) }
                }
            }
        }
        pendingPreview = item
        previewQueue.asyncAfter(deadline: .now() + (immediate ? 0 : 0.22), execute: item)
    }

    private func invalidateAnalysis() {
        analysisGeneration = UUID(); analysisSourceKey = nil
        analysis = nil; analysisBusy = false; analysisError = nil; proposalPreviews = [:]
        analysisImage = nil; proposalSettings = nil; proposalLUTID = nil; proposalToken?.cancel()
    }

    func reanalyze() {
        guard !batchRunning else { return }
        invalidateAnalysis()
        requestPreview(immediate: true)
    }

    private func enqueueAnalysis(_ loaded: LoadedPhoto, photo: PhotoItem, key: String) {
        guard selectedID == photo.id else { return }
        guard analysisSourceKey != key else {
            refreshProposalPreviews()
            return
        }
        analysisSourceKey = key
        let generation = UUID(); analysisGeneration = generation
        analysis = nil; proposalToken?.cancel(); proposalSettings = nil; proposalLUTID = nil
        let baseline = automaticRecipe?.baseline ?? adjustments
        analysisBaseline = baseline
        analysisImage = loaded.image
        analysisBusy = true; analysisError = nil; proposalPreviews = [:]
        analysisQueue.async { [weak self] in
            let result = Result { () throws -> PhotoAnalysis in
                try autoreleasepool {
                    try PhotoAnalyzer().analyze(image: loaded.image, properties: loaded.properties,
                                               sourceURL: photo.url, baseline: baseline)
                }
            }
            DispatchQueue.main.async {
                guard let self = self, self.analysisGeneration == generation, self.selectedID == photo.id else { return }
                self.analysisBusy = false
                switch result {
                case .success(let analysis):
                    self.analysis = analysis
                    if var automatic = self.automaticRecipe,
                       let reference = analysis.proposals.first(where: { $0.id == automatic.styleID }) {
                        do {
                            self.adjustments = try automatic.resolve(analysis: analysis, current: self.adjustments)
                            automatic.referenceSettings = reference.settings
                            self.automaticRecipe = automatic
                            self.requestPreview(immediate: true)
                        } catch { self.analysisError = error.localizedDescription }
                    }
                    self.refreshProposalPreviews()
                case .failure(let error):
                    self.analysisError = error.localizedDescription
                }
            }
        }
    }

    private func refreshProposalPreviews() {
        guard let analysis = analysis, let image = analysisImage,
              proposalSettings != adjustments || proposalLUTID != selectedLUT else { return }
        proposalToken?.cancel()
        let token = CancellationToken(); proposalToken = token
        let current = adjustments; let cube = selectedOption?.cube
        proposalSettings = current; proposalLUTID = selectedLUT
        proposalPreviews = [:]
        let generation = analysisGeneration
        analysisQueue.async { [weak self] in
            do {
                let previews: [String: CGImage] = try autoreleasepool {
                    let engine = PhotoEngine()
                    let scale = min(1, 620 / max(image.extent.width, image.extent.height))
                    let small = image.transformed(by: .init(scaleX: scale, y: scale))
                    var result: [String: CGImage] = [:]
                    for proposal in analysis.proposals {
                        try token.check()
                        let settings = AutomaticBatchRecipe.copyBasicAdjustments(from: proposal.settings, into: current)
                        let processed = try engine.process(small, settings: settings, lut: cube, cancellation: token)
                        guard let cg = engine.context.createCGImage(processed.image, from: processed.image.extent,
                                                                   format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
                            throw AtelierError.imageRead("无法渲染自动方案预览")
                        }
                        result[proposal.id] = cg
                    }
                    return result
                }
                DispatchQueue.main.async {
                    guard let self = self, self.analysisGeneration == generation, !token.isCancelled else { return }
                    self.proposalPreviews = previews.mapValues { NSImage(cgImage: $0, size: .zero) }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self, self.analysisGeneration == generation, !token.isCancelled else { return }
                    self.analysisError = error.localizedDescription
                }
            }
        }
    }

    func applyProposal(_ id: String) {
        guard !batchRunning, let proposal = analysis?.proposals.first(where: { $0.id == id }) else { return }
        automaticRecipe = AutomaticBatchRecipe(styleID: id, baseline: analysisBaseline,
                                               referenceSettings: proposal.settings)
        adjustments = AutomaticBatchRecipe.copyBasicAdjustments(from: proposal.settings, into: adjustments)
        drawingMask = false
        status = "已采用“\(proposal.title)”。可继续微调；批量导出会逐张分析并叠加这些微调。"
        requestPreview(immediate: true)
    }

    func useManualParameters() {
        automaticRecipe = nil
        status = "已改为统一手动配方，保留当前参数。"
    }

    func saveAnalysis() {
        guard let analysis = analysis else { return }
        let panel = NSSavePanel(); panel.title = "保存照片分析"
        panel.nameFieldStringValue = "照片分析.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(analysis).write(to: url, options: .atomic)
            status = "详细分析已保存。"
        } catch { present(error) }
    }

    private func makeHistogram(_ image: CIImage) -> [Double] {
        let scale = 128 / max(image.extent.width, image.extent.height)
        let small = image.transformed(by: .init(scaleX: scale, y: scale))
        let width = max(1, Int(small.extent.width)), height = max(1, Int(small.extent.height))
        var data = [UInt8](repeating: 0, count: width * height * 4)
        engine.context.render(small, toBitmap: &data, rowBytes: width * 4,
                              bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var bins = Array(repeating: 0.0, count: 64)
        for i in stride(from: 0, to: data.count, by: 4) {
            let y = (0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])) / 255
            bins[min(63, Int(y * 63))] += 1
        }
        let maximum = max(1, bins.max() ?? 1)
        return bins.map { sqrt($0 / maximum) }
    }

    func startBatch() {
        guard !batchRunning, let input = inputRoot, !photos.isEmpty else { return }
        if outputRoot == nil { chooseOutput() }
        guard let output = outputRoot else { return }
        // Freeze the recipe and selection before moving work off the UI thread.
        let snapshot = recipe; let items = photos; let cube = selectedOption?.cube
        let token = CancellationToken(); batchToken = token
        batchRunning = true; processed = 0; succeeded = 0; failed = 0; lastManifest = nil
        batchMessages = []; currentFile = "准备导出…"; status = "批量处理中 · 使用当前统一配方"
        batchQueue.async { [weak self] in
            do {
                let summary = try BatchProcessor().run(items: items, inputRoot: input, outputRoot: output,
                                                      recipe: snapshot, lut: cube, cancellation: token) { event in
                    DispatchQueue.main.async { self?.consume(event) }
                }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.batchRunning = false; self.lastManifest = summary.manifestURL
                    self.succeeded = summary.succeeded; self.failed = summary.failed
                    self.status = "\(summary.cancelled ? "已取消" : "导出完成") · 成功 \(summary.succeeded) 张，失败 \(summary.failed) 张"
                    self.currentFile = ""
                }
            } catch {
                DispatchQueue.main.async { self?.batchRunning = false; self?.present(error) }
            }
        }
    }

    private func consume(_ event: BatchEvent) {
        switch event.kind {
        case .processing: currentFile = event.input?.lastPathComponent ?? ""
        case .completed: processed += 1; succeeded += 1
        case .failed: processed += 1; failed += 1
        default: break
        }
        if !event.message.isEmpty {
            batchMessages.append(event.message)
            if batchMessages.count > 200 { batchMessages.removeFirst() }
        }
    }

    func cancelBatch() { batchToken?.cancel(); status = "正在安全停止；已完成的照片保留。" }

    func resetAdjustments() {
        automaticRecipe = nil; invalidateAnalysis()
        adjustments = .init(); selectedLUT = "none"; selectedMask = nil; drawingMask = false
        requestPreview(immediate: true)
    }

    func addMask(start: MaskPoint, end: MaskPoint, points: [MaskPoint]) {
        let mask = LocalMask(name: "\(maskKind.title) \(adjustments.masks.count + 1)", kind: maskKind,
                             start: start, end: end, points: points)
        adjustments.masks.append(mask); selectedMask = mask.id; drawingMask = false
        status = "已添加局部蒙版；批量导出会将它应用到每张照片的相同相对位置。"
    }

    func deleteSelectedMask() {
        adjustments.masks.removeAll { $0.id == selectedMask }
        selectedMask = adjustments.masks.last?.id
    }

    func saveRecipe() {
        let panel = NSSavePanel(); panel.title = "保存调色配方"
        panel.nameFieldStringValue = "光屿配方.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(recipe).write(to: url, options: .atomic)
            status = "配方已保存。自定义 LUT 存在本机资料库中，跨设备使用时需一并复制 LUT。"
        } catch { present(error) }
    }

    func loadRecipe() {
        let panel = NSOpenPanel(); panel.title = "载入调色配方"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 4_000_000 else { throw AtelierError.invalidConfiguration("配方文件过大") }
            let saved = try JSONDecoder().decode(Recipe.self, from: data)
            guard saved.version == 1 else { throw AtelierError.invalidConfiguration("不支持此版本的配方") }
            try PhotoEngine.validate(saved.adjustments)
            try saved.automatic?.validate()
            var target = "none"
            if let path = saved.lutPath {
                let lutURL = URL(fileURLWithPath: path)
                if let existing = lutOptions.first(where: { $0.path == path }) { target = existing.id }
                else {
                    let cube = try LUTCube.load(url: lutURL)
                    lutOptions.append(LUTOption(id: path, name: cube.title, detail: "配方 LUT", cube: cube, path: path))
                    target = path
                }
            } else if let id = saved.lutIdentifier {
                guard lutOptions.contains(where: { $0.id == id }) else { throw AtelierError.invalidLUT("配方引用的内置 LUT 不存在") }
                target = id
            }
            adjustments = saved.adjustments; exportSettings = saved.export; selectedLUT = target
            automaticRecipe = saved.automatic; invalidateAnalysis()
            selectedMask = nil; drawingMask = false
            status = "配方已载入。"; reloadFolder(); requestPreview(immediate: true)
        } catch { present(error) }
    }

    func revealOutput() {
        guard let root = outputRoot else { return }
        NSWorkspace.shared.open(root)
    }

    func present(_ error: Error) { errorMessage = error.localizedDescription; status = error.localizedDescription }
}

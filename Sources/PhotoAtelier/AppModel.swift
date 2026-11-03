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

enum MaskDrawMode: String, CaseIterable {
    case new, add, subtract, intersect
    var title: String {
        switch self {
        case .new: return "新建"
        case .add: return "加选"
        case .subtract: return "减选"
        case .intersect: return "交集"
        }
    }
    var operation: MaskCombineMode? {
        switch self {
        case .new: return nil
        case .add: return .add
        case .subtract: return .subtract
        case .intersect: return .intersect
        }
    }
}

enum LocalMaskPreset: String, CaseIterable {
    case shadowDetail, highlightSoftness, subjectLift, colorSelection
    var title: String {
        switch self {
        case .shadowDetail: return "暗部细节"
        case .highlightSoftness: return "高光过渡"
        case .subjectLift: return "主体提亮"
        case .colorSelection: return "取样颜色"
        }
    }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var inputRoot: URL?
    @Published var outputRoot: URL?
    @Published var photos: [PhotoItem] = []
    @Published var selectedID: String?
    @Published var adjustments = AdjustmentSettings() {
        didSet { refreshNativeInspection() }
    }
    @Published var exportSettings = ExportSettings() {
        didSet { if oldValue.colorSpace != exportSettings.colorSpace { refreshNativeInspection() } }
    }
    @Published var lutOptions: [LUTOption] = []
    @Published var selectedLUT = "none" {
        didSet { refreshNativeInspection() }
    }
    @Published var showNativeInspection = false
    @Published private(set) var nativeInspectionRegion = NativeInspectionRegion()
    let nativeInspection: NativeInspectionController
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
    @Published var maskDrawMode: MaskDrawMode = .new
    @Published var brushRadius: Double = 0.06
    @Published var brushFeather: Double = 0.65
    @Published var maskEditMode = false
    @Published var pickingMaskColor = false
    @Published var showMaskCoverage = false
    @Published var maskOverlayOpacity: Double = 0.55
    @Published var maskOverlayImage: NSImage?
    @Published var maskInspection: MaskInspection?
    @Published private(set) var regionalSuggestions: [RegionalAdjustmentSuggestion] = []
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var lastManifest: URL?
    @Published var analysis: PhotoAnalysis?
    @Published var analysisBusy = false
    @Published var analysisError: String?
    @Published var proposalPreviews: [String: NSImage] = [:]
    @Published private(set) var automaticRecipe: AutomaticBatchRecipe?
    @Published private(set) var sceneIntent: PhotoSceneIntent = .automatic
    // Full-source decode/inspection/export share one serial resource queue.
    // A cancelled synchronous RAW stage must finish before the next decode.
    private let previewQueue = DispatchQueue(label: "atelier.photo-processing", qos: .userInitiated)
    private let scanQueue = DispatchQueue(label: "atelier.scan", qos: .utility)
    private let analysisQueue = DispatchQueue(label: "atelier.analysis", qos: .userInitiated)
    private var analysisSourceKey: String?
    private var analysisGeneration = UUID()
    private var analysisBaseline = AdjustmentSettings()
    private var analysisIntent: PhotoSceneIntent = .automatic
    private var analysisImage: CIImage?
    private var proposalSettings: AdjustmentSettings?
    private var proposalLUTID: String?
    private var proposalOutputSpace: OutputColorSpace?
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
    /// These graphs are bounded preview images and are accessed on previewQueue only.
    private var cachedMaskReference: CIImage?
    private var cachedMaskReferenceSettings: AdjustmentSettings?
    private var cachedMaskReferenceSource: String?
    private var cachedMaskReferencePhotoID: String?
    private var cachedContentTargets = Set<ContentSelectionTarget>()
    private var cachedContentSelections: ContentSelectionResult?
    private var rememberedSpaces: [String: String] = UserDefaults.standard.dictionary(forKey: "lutColorSpaces") as? [String: String] ?? [:]

    var selectedPhoto: PhotoItem? { photos.first { $0.id == selectedID } }
    var selectedOption: LUTOption? { lutOptions.first { $0.id == selectedLUT } }
    var activeMaskIndex: Int? { adjustments.masks.firstIndex { $0.id == selectedMask } }
    var maskInteractionActive: Bool { drawingMask || maskEditMode || pickingMaskColor }
    var selectedLocalMask: LocalMask? { adjustments.masks.first { $0.id == selectedMask } }
    private var maskPointCount: Int {
        adjustments.masks.reduce(0) { count, mask in
            count + mask.points.count + mask.components.reduce(0) { $0 + $1.points.count }
        }
    }
    private var maskComponentCount: Int { adjustments.masks.reduce(0) { $0 + $1.components.count } }
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
        nativeInspection = NativeInspectionController(queue: previewQueue)
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
        closeNativeInspection()
        nativeInspectionRegion = .init()
        cancelMaskInteraction()
        maskOverlayImage = nil; maskInspection = nil
        regionalSuggestions = []
        pendingPreview?.cancel(); previewToken?.cancel(); previewGeneration = UUID()
        previewBusy = false; previewReport = .init(); histogram = Array(repeating: 0, count: 64)
        invalidateAnalysis()
        inputRoot = url
        photos = []; selectedID = nil; beforeImage = nil; afterImage = nil; thumbnails = [:]
        reloadFolder()
    }

    func reloadFolder() {
        guard let root = inputRoot, !batchRunning else { return }
        nativeInspection.cancel()
        regionalSuggestions = []
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
        nativeInspection.cancel()
        nativeInspectionRegion.center = .init(x: 0.5, y: 0.5)
        cancelMaskInteraction()
        maskOverlayImage = nil; maskInspection = nil
        selectedID = photo.id
        beforeImage = nil; afterImage = nil
        regionalSuggestions = []
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
        refreshNativeInspection()
        pendingPreview?.cancel(); previewToken?.cancel()
        let generation = UUID(); previewGeneration = generation
        maskOverlayImage = nil; maskInspection = nil
        previewReport.contentSelection = nil
        previewReport.localDetails = nil
        guard let photo = selectedPhoto else {
            regionalSuggestions = []; previewBusy = false
            return
        }
        let settings = adjustments; let cube = selectedOption?.cube
        let outputSpace = exportSettings.colorSpace
        let selectedMask = selectedLocalMask
        let needsMaskOverlay = showMaskCoverage
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
                var referenceSettings = settings
                referenceSettings.masks = []
                let reference: CIImage
                if self.cachedMaskReferenceSource == cacheKey,
                   self.cachedMaskReferenceSettings == referenceSettings,
                   let cached = self.cachedMaskReference {
                    reference = cached
                } else {
                    reference = try self.engine.maskReferenceImage(small, settings: referenceSettings, cancellation: token)
                    self.cachedMaskReference = reference
                    self.cachedMaskReferenceSettings = referenceSettings
                    self.cachedMaskReferenceSource = cacheKey
                    self.cachedMaskReferencePhotoID = photo.id
                    self.cachedContentTargets = []
                    self.cachedContentSelections = nil
                }
                try token.check()
                let contentTargets = Set(settings.masks.filter { $0.enabled && $0.opacity > 0 }
                    .compactMap(\.contentSelection))
                let contentSelections: ContentSelectionResult?
                if contentTargets.isEmpty {
                    contentSelections = nil
                } else if self.cachedContentTargets == contentTargets, let cached = self.cachedContentSelections {
                    contentSelections = cached
                } else {
                    contentSelections = try ContentSelectionAnalyzer.analyze(reference: reference, targets: contentTargets,
                                                                              context: self.engine.context,
                                                                              cancellation: token)
                    try token.check()
                    self.cachedContentTargets = contentTargets
                    self.cachedContentSelections = contentSelections
                }
                let output = try self.engine.process(small, settings: settings, lut: cube, initialReport: loaded.report,
                                                     outputColorSpace: outputSpace, cancellation: token,
                                                     preparedContentSelections: contentSelections)
                let space = outputSpace.cgColorSpace
                guard let before = self.engine.context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: space),
                      let after = self.engine.context.createCGImage(output.image, from: output.image.extent, format: .RGBA8, colorSpace: space) else {
                    throw AtelierError.imageRead("预览渲染失败")
                }
                let histogram = self.makeHistogram(output.image)
                var maskOverlay: CGImage?
                var inspection: MaskInspection?
                let regionalSuggestions = try RegionalAdjustmentAnalyzer.suggestions(reference: reference,
                                                                                      context: self.engine.context)
                if let mask = selectedMask {
                    try token.check()
                    inspection = try self.engine.inspectLocalMask(mask, reference: reference,
                                                                  contentSelections: output.contentSelections)
                    if needsMaskOverlay {
                        let coverage = try self.engine.localMaskImage(mask, reference: reference,
                                                                      contentSelections: output.contentSelections)
                        let color = CIImage(color: CIColor(red: 0.95, green: 0.18, blue: 0.4)).cropped(to: reference.extent)
                        let clear = CIImage(color: .clear).cropped(to: reference.extent)
                        let overlay = color.applyingFilter("CIBlendWithMask", parameters: [
                            "inputBackgroundImage": clear, "inputMaskImage": coverage
                        ]).cropped(to: reference.extent)
                        guard let rendered = self.engine.context.createCGImage(overlay, from: overlay.extent,
                                                                              format: .RGBA8, colorSpace: space) else {
                            throw AtelierError.imageRead("无法渲染局部选区覆盖预览")
                        }
                        maskOverlay = rendered
                    }
                }
                try token.check()
                DispatchQueue.main.async {
                    guard self.previewGeneration == generation else { return }
                    self.beforeImage = NSImage(cgImage: before, size: .zero)
                    self.afterImage = NSImage(cgImage: after, size: .zero)
                    self.previewReport = output.report; self.histogram = histogram
                    self.regionalSuggestions = regionalSuggestions
                    if self.selectedMask == selectedMask?.id {
                        self.maskOverlayImage = maskOverlay.map { NSImage(cgImage: $0, size: .zero) }
                        self.maskInspection = inspection
                    }
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

    func setSceneIntent(_ intent: PhotoSceneIntent) {
        guard !batchRunning, sceneIntent != intent else { return }
        sceneIntent = intent
        if var automatic = automaticRecipe {
            if intent == .preserveStyle {
                // Freeze the currently visible global result instead of
                // removing a previously accepted automatic correction.
                automatic.baseline = adjustments
                automatic.referenceSettings = adjustments
            }
            automatic.sceneIntent = intent
            automaticRecipe = automatic
        }
        invalidateAnalysis()
        requestPreview(immediate: true)
    }

    private func enqueueAnalysis(_ loaded: LoadedPhoto, photo: PhotoItem, key: String) {
        guard selectedID == photo.id else { return }
        let baseline = automaticRecipe?.baseline ?? adjustments
        let intent = automaticRecipe?.sceneIntent ?? sceneIntent
        let baselineBasicsChanged = AutomaticBatchRecipe.copyBasicAdjustments(
            from: baseline, into: analysisBaseline) != analysisBaseline
        guard analysisSourceKey != key || baselineBasicsChanged || analysisIntent != intent else {
            refreshProposalPreviews()
            return
        }
        analysisSourceKey = key
        let generation = UUID(); analysisGeneration = generation
        analysis = nil; proposalToken?.cancel(); proposalSettings = nil; proposalLUTID = nil
        analysisBaseline = baseline
        analysisIntent = intent
        analysisImage = loaded.image
        analysisBusy = true; analysisError = nil; proposalPreviews = [:]
        analysisQueue.async { [weak self] in
            let result = Result { () throws -> PhotoAnalysis in
                try autoreleasepool {
                    try PhotoAnalyzer().analyze(image: loaded.image, properties: loaded.properties,
                                               sourceURL: photo.url, baseline: baseline, intent: intent)
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
              proposalSettings != adjustments || proposalLUTID != selectedLUT || proposalOutputSpace != exportSettings.colorSpace else { return }
        proposalToken?.cancel()
        let token = CancellationToken(); proposalToken = token
        let current = adjustments; let cube = selectedOption?.cube
        let outputSpace = exportSettings.colorSpace
        proposalSettings = current; proposalLUTID = selectedLUT
        proposalOutputSpace = outputSpace
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
                        let processed = try engine.process(small, settings: settings, lut: cube,
                                                           outputColorSpace: outputSpace, cancellation: token)
                        guard let cg = engine.context.createCGImage(processed.image, from: processed.image.extent,
                                                                   format: .RGBA8, colorSpace: outputSpace.cgColorSpace) else {
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
                                               referenceSettings: proposal.settings, sceneIntent: analysisIntent)
        adjustments = AutomaticBatchRecipe.copyBasicAdjustments(from: proposal.settings, into: adjustments)
        cancelMaskInteraction()
        status = "已采用“\(proposal.title)”。可继续微调；批量导出会逐张分析并叠加这些微调。"
        requestPreview(immediate: true)
    }

    func useManualParameters() {
        automaticRecipe = nil
        status = "已改为统一手动配方，保留当前参数。"
    }

    @discardableResult
    func applyRegionalSuggestion(_ id: String) -> Bool {
        guard !batchRunning, !previewBusy, !scanning, selectedPhoto != nil,
              !(automaticRecipe != nil && (analysisBusy || analysis == nil || analysisError != nil)),
              let suggestion = regionalSuggestions.first(where: { $0.id == id }) else { return false }
        cancelMaskInteraction()
        if let index = adjustments.masks.firstIndex(where: { $0.id == suggestion.mask.id }) {
            adjustments.masks[index] = suggestion.mask
        } else {
            guard adjustments.masks.count < 16 else {
                present(AtelierError.invalidConfiguration("蒙版数量已达上限，请先移除不需要的蒙版。"))
                return false
            }
            adjustments.masks.append(suggestion.mask)
        }
        selectedMask = suggestion.mask.id
        showMaskOverlay = true
        showMaskCoverage = true
        status = "已建立“\(suggestion.title)”可编辑蒙版；请检查覆盖，整批使用前复核其他构图。"
        requestPreview(immediate: true)
        return true
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
        closeNativeInspection()
        cancelMaskInteraction()
        // Freeze the recipe and selection before moving work off the UI thread.
        let snapshot = recipe; let items = photos; let cube = selectedOption?.cube
        let token = CancellationToken(); batchToken = token
        batchRunning = true; processed = 0; succeeded = 0; failed = 0; lastManifest = nil
        batchMessages = []; currentFile = "准备导出…"; status = "批量处理中 · 使用当前统一配方"
        previewQueue.async { [weak self] in
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

    func openNativeInspection() {
        guard !batchRunning, !scanning, selectedPhoto != nil else { return }
        cancelMaskInteraction()
        showNativeInspection = true
        refreshNativeInspection(immediate: true)
    }

    func closeNativeInspection() {
        showNativeInspection = false
        nativeInspection.cancel()
    }

    func updateNativeInspection(center: MaskPoint? = nil, pixelSize: Int? = nil) {
        guard !batchRunning else { return }
        var region = nativeInspectionRegion
        if let center { region.center = center }
        if let pixelSize { region.pixelSize = pixelSize }
        do { try region.validate() } catch { return }
        guard region != nativeInspectionRegion else { return }
        nativeInspectionRegion = region
        refreshNativeInspection()
    }

    func refreshNativeInspection(immediate: Bool = false, force: Bool = false) {
        guard showNativeInspection, !batchRunning, !scanning, let photo = selectedPhoto else {
            nativeInspection.cancel(); return
        }
        nativeInspection.request(photo: photo, recipe: recipe, lut: selectedOption?.cube,
            lutID: selectedLUT, region: nativeInspectionRegion, immediate: immediate, force: force)
    }

    func resetAdjustments() {
        sceneIntent = .automatic
        regionalSuggestions = []
        automaticRecipe = nil; invalidateAnalysis()
        cancelMaskInteraction(); maskOverlayImage = nil; maskInspection = nil
        adjustments = .init(); selectedLUT = "none"; selectedMask = nil; drawingMask = false
        requestPreview(immediate: true)
    }

    func addMask(start: MaskPoint, end: MaskPoint, points: [MaskPoint]) {
        guard !batchRunning, [.radial, .linear, .brush].contains(maskKind) else { return }
        guard maskKind != .brush || !points.isEmpty, points.count <= 4096 else { return }
        guard maskPointCount + points.count <= 32768 else {
            status = "笔迹总点数已达到 32768 点，请移除部分笔迹后再绘制。"; return
        }
        if let operation = maskDrawMode.operation {
            guard let index = activeMaskIndex else { status = "先选中一个蒙版，再添加或擦除区域。"; return }
            let current = adjustments.masks[index]
            let count = current.points.count + current.components.reduce(0) { $0 + $1.points.count }
            guard current.components.count < 64, maskComponentCount < 64, count + points.count <= 32768 else {
                status = "修边步骤或笔迹已达到上限，请移除不需要的修边后再绘制。"; return
            }
            adjustments.masks[index].components.append(MaskComponent(operation: operation, kind: maskKind,
                start: start, end: end, points: points, radius: brushRadius, feather: brushFeather))
            status = "已\(maskDrawMode.title)区域；可继续绘制，或点击完成修边。"
        } else {
            guard adjustments.masks.count < 16 else { status = "最多使用 16 个局部蒙版。"; return }
            let mask = LocalMask(name: "\(maskKind.title) \(adjustments.masks.count + 1)", kind: maskKind,
                                 start: start, end: end, points: points, radius: brushRadius,
                                 feather: brushFeather, exposureEV: 0)
            adjustments.masks.append(mask); selectedMask = mask.id; drawingMask = false
            status = "已建立选区。可采用区域实测建议，再微调局部参数。"
        }
        maskInspection = nil; showMaskCoverage = true
        requestPreview()
    }

    func addContentMask(_ target: ContentSelectionTarget) {
        guard !batchRunning, !scanning, selectedPhoto != nil, adjustments.masks.count < 16 else { return }
        cancelMaskInteraction()
        let mask = LocalMask(name: target.title, kind: .luminance, exposureEV: 0,
                             highlightProtection: 0.65, colorProtection: 0.8,
                             contentSelection: target)
        adjustments.masks.append(mask); selectedMask = mask.id
        showMaskCoverage = true; showMaskOverlay = true
        status = "正在检测“\(target.title)”；每张照片独立重算，请检查覆盖后调整。"
        requestPreview(immediate: true)
    }

    func applyNaturalDetailStartingPoint() {
        guard !batchRunning, !previewBusy, !scanning, selectedPhoto != nil,
              !(automaticRecipe != nil && (analysisBusy || analysis == nil || analysisError != nil)),
              let index = activeMaskIndex,
              maskInspection?.coverage ?? 0 > 0.0005 else { return }
        adjustments.masks[index].detail = LocalDetailSettings(smoothing: 0.25,
                                                             textureRetention: 0.9, toneUniformity: 0.12)
        adjustments.masks[index].detailAdaptation = nil
        status = "已采用轻度细节起点；请放大检查，其他局部光色参数保留。"
        requestPreview(immediate: true)
    }

    func addAdaptiveDetailMask() {
        guard !batchRunning, !scanning, selectedPhoto != nil, adjustments.masks.count < 16 else { return }
        cancelMaskInteraction()
        let mask = LocalMask(name: "整图 · 逐图细节", kind: .luminance, exposureEV: 0,
                             highlightProtection: 0.65, colorProtection: 0.8,
                             detailAdaptation: LocalDetailAdaptation())
        adjustments.masks.append(mask); selectedMask = mask.id
        showMaskCoverage = true; showMaskOverlay = true
        status = "已启用逐图细节；请查看本图方向与依据，人物皮肤需另建面部候选。"
        requestPreview(immediate: true)
    }

    func deleteSelectedMask() {
        guard !batchRunning else { return }
        cancelMaskInteraction()
        adjustments.masks.removeAll { $0.id == selectedMask }
        selectedMask = adjustments.masks.last?.id
        requestPreview()
    }

    func cancelMaskInteraction() {
        drawingMask = false; maskEditMode = false; pickingMaskColor = false
    }

    func maskSelectionChanged() {
        maskOverlayImage = nil; maskInspection = nil
        requestPreview()
    }

    func beginMaskDrawing() {
        guard !batchRunning, afterImage != nil else { return }
        if drawingMask { drawingMask = false; return }
        guard maskDrawMode == .new || activeMaskIndex != nil else {
            status = "先选中一个蒙版，再添加或擦除区域。"; return
        }
        cancelMaskInteraction()
        if maskKind == .luminance || maskKind == .color {
            guard maskDrawMode == .new else { maskKind = .brush; drawingMask = true; return }
            addRangeMask(kind: maskKind)
        } else { drawingMask = true }
        showMaskCoverage = true
    }

    func addRangeMask(kind: MaskKind) {
        guard !batchRunning, afterImage != nil, adjustments.masks.count < 16 else { return }
        var mask = LocalMask(name: "\(kind.title) \(adjustments.masks.count + 1)", kind: kind, exposureEV: 0)
        if kind == .luminance { mask.luminanceMin = 0.2; mask.luminanceMax = 0.8 }
        adjustments.masks.append(mask); selectedMask = mask.id
        cancelMaskInteraction(); showMaskCoverage = true
        if kind == .color { pickingMaskColor = true; status = "点击照片中的目标颜色取样；颜色按全局校正后的原色判断，不受 LUT 染色影响。" }
        requestPreview()
    }

    func addMaskPreset(_ preset: LocalMaskPreset) {
        guard !batchRunning, afterImage != nil, adjustments.masks.count < 16 else { return }
        var mask = LocalMask(name: preset.title, exposureEV: 0)
        switch preset {
        case .shadowDetail:
            mask.kind = .luminance; mask.luminanceMax = 0.5
            mask.shadows = 0.3; mask.exposureEV = 0.15
        case .highlightSoftness:
            mask.kind = .luminance; mask.luminanceMin = 0.62
            mask.highlights = -0.35; mask.exposureEV = -0.1
        case .subjectLift:
            mask.feather = 0.85; mask.exposureEV = 0.25; mask.highlightProtection = 0.75
        case .colorSelection:
            mask.kind = .color
        }
        adjustments.masks.append(mask); selectedMask = mask.id
        cancelMaskInteraction(); maskDrawMode = .new; showMaskCoverage = true
        if preset == .colorSelection { pickingMaskColor = true }
        status = preset == .subjectLift
            ? "已建立柔和径向选区，可编辑位置贴合主体；此选区不是自动主体识别。"
            : "已添加\(preset.title)。请查看覆盖区域后调整范围与强度。"
        requestPreview()
    }

    func duplicateSelectedMask() {
        guard !batchRunning, var mask = selectedLocalMask, adjustments.masks.count < 16 else { return }
        let points = mask.points.count + mask.components.reduce(0) { $0 + $1.points.count }
        guard maskPointCount + points <= 32768 else {
            status = "复制将超过笔迹总点数上限，请先减少修边笔迹。"; return
        }
        guard maskComponentCount + mask.components.count <= 64 else {
            status = "复制将超过修边总数上限，请先移除不需要的修边。"; return
        }
        mask.id = UUID(); mask.name = String((mask.name + " 副本").prefix(256))
        for index in mask.components.indices { mask.components[index].id = UUID() }
        adjustments.masks.append(mask); selectedMask = mask.id
        requestPreview()
    }

    func moveSelectedMask(by distance: Int) {
        guard !batchRunning, let index = activeMaskIndex else { return }
        let target = index + distance
        guard adjustments.masks.indices.contains(target) else { return }
        adjustments.masks.swapAt(index, target)
        requestPreview()
    }

    func moveMaskGeometry(id: UUID, start: MaskPoint, end: MaskPoint) {
        guard !batchRunning, let index = adjustments.masks.firstIndex(where: { $0.id == id }) else { return }
        adjustments.masks[index].start = start; adjustments.masks[index].end = end
        requestPreview()
    }

    func removeMaskComponent(_ id: UUID? = nil) {
        guard !batchRunning, let index = activeMaskIndex, !adjustments.masks[index].components.isEmpty else { return }
        if let id = id { adjustments.masks[index].components.removeAll { $0.id == id } }
        else { adjustments.masks[index].components.removeLast() }
        requestPreview()
    }

    func resetSelectedMaskAdjustments() {
        guard !batchRunning, let index = activeMaskIndex else { return }
        var mask = adjustments.masks[index]
        mask.exposureEV = 0; mask.highlights = 0; mask.shadows = 0; mask.contrast = 1
        mask.saturation = 1; mask.warmth = 0; mask.tint = 0; mask.sharpness = 0
        mask.detail = nil
        mask.detailAdaptation = nil
        adjustments.masks[index] = mask
        requestPreview()
    }

    func applyMaskSuggestion() {
        guard !batchRunning, !previewBusy, !scanning, selectedPhoto != nil, let index = activeMaskIndex,
              !(automaticRecipe != nil && (analysisBusy || analysis == nil || analysisError != nil)),
              let inspection = maskInspection, inspection.coverage > 0.005,
              inspection.lightGuidance?.hasSuggestion == true else { return }
        var mask = adjustments.masks[index]
        mask.exposureEV = inspection.suggestedExposureEV
        adjustments.masks[index] = mask
        status = "已采用选区曝光建议，保留其他局部微调；批处理使用当前局部参数。"
        requestPreview()
    }

    func pickMaskColor(at point: MaskPoint) {
        guard !batchRunning, !previewBusy, let id = selectedMask, let photoID = selectedID else { return }
        pickingMaskColor = false
        let generation = previewGeneration
        previewQueue.async { [weak self] in
            guard let self = self else { return }
            let result = Result { () throws -> MaskColor in
                guard self.cachedMaskReferencePhotoID == photoID, let reference = self.cachedMaskReference else {
                    throw AtelierError.invalidConfiguration("请等待本张照片预览完成后再取样。")
                }
                return try self.engine.sampleMaskColor(at: point, reference: reference)
            }
            DispatchQueue.main.async {
                guard self.selectedID == photoID, self.selectedMask == id,
                      self.previewGeneration == generation, !self.batchRunning,
                      let index = self.adjustments.masks.firstIndex(where: { $0.id == id }) else { return }
                switch result {
                case .success(let color):
                    self.adjustments.masks[index].color = color
                    self.adjustments.masks[index].restrictColor = true
                    self.status = "已取样全局校正后的原色。调节颜色容差和柔化，检查是否选中所需区域。"
                    self.requestPreview()
                case .failure(let error): self.status = error.localizedDescription
                }
            }
        }
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
            try saved.validateVersion()
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
            sceneIntent = saved.automatic?.sceneIntent ?? .automatic
            selectedMask = nil; cancelMaskInteraction(); maskOverlayImage = nil; maskInspection = nil
            status = "配方已载入。"; reloadFolder(); requestPreview(immediate: true)
        } catch { present(error) }
    }

    func revealOutput() {
        guard let root = outputRoot else { return }
        NSWorkspace.shared.open(root)
    }

    func present(_ error: Error) { errorMessage = error.localizedDescription; status = error.localizedDescription }
}

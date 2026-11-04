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
    var group: LUTPresetGroup? = nil
    var recommendedIntensity: Double? = nil
    var tags: [String] = []
    var provenance: LUTProvenance? = nil
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

/// UI-facing result of the background face detection used by the portrait tab.
/// Detection is explicit about unusable results instead of silently disabling
/// controls: the panel shows the summary and keeps the sliders disabled.
struct PortraitFaceStatus: Equatable {
    var isDetecting = false
    var hasCompleted = false
    var photoID: String?
    var detectedFaceCount = 0
    var maximumConfidence = 0.0
    var hasUsableSkinMask = false
    var summary = "切到“人像”页签会自动检测人脸。"
}

final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var inputRoot: URL?
    @Published var outputRoot: URL?
    @Published var photos: [PhotoItem] = []
    @Published var selectedID: String?
    @Published var adjustments = AdjustmentSettings() {
        didSet {
            refreshNativeInspection()
            recordUndoAdjustmentChange(from: oldValue)
        }
    }
    @Published var exportSettings = ExportSettings() {
        didSet { if oldValue.colorSpace != exportSettings.colorSpace { refreshNativeInspection() } }
    }
    @Published var lutOptions: [LUTOption] = []
    @Published private(set) var lutLibraryBusy = false
    @Published private(set) var lutImportCompleted = 0
    @Published private(set) var lutImportTotal = 0
    @Published private(set) var lutLibraryMessages: [String] = []
    @Published var showStyleBrowser = false {
        didSet { if !showStyleBrowser { stylePreviews.cancel() } }
    }
    /// Bounded global-adjustment reference; excludes masks, LUTs and effects.
    @Published private(set) var styleReference: CIImage?
    let stylePreviews: StylePreviewController
    @Published var selectedLUT = "none" {
        didSet {
            refreshNativeInspection()
            recordUndoLookChange(previousLUT: oldValue)
        }
    }
    /// Undo/redo availability for the menu; the snapshot stack stays private.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
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
    /// Per-item failures from the most recent open/drop import. Empty means the
    /// whole selection was accepted; entries are shown one by one, never hidden.
    @Published private(set) var importIssues: [String] = []
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
    /// Background face-detection state for the portrait inspector tab.
    @Published private(set) var portraitFaceStatus = PortraitFaceStatus()
    /// Reference-color ("AI 追色") UI state. The profile itself lives in
    /// `adjustments.referenceColor`; these are display-only and never persisted.
    /// The thumbnail is only shown while `referenceColorThumbnailProfile` still
    /// equals the active profile, so undo/recipe-load can never pair a stale
    /// thumbnail with a different profile.
    @Published private(set) var referenceColorThumbnail: NSImage?
    @Published private(set) var referenceColorThumbnailProfile: ReferenceColorProfile?
    @Published private(set) var referenceColorSourceName: String?
    @Published private(set) var referenceColorBusy = false
    // Full-source decode/inspection/export share one serial resource queue.
    // A cancelled synchronous RAW stage must finish before the next decode.
    private let previewQueue = DispatchQueue(label: "atelier.photo-processing", qos: .userInitiated)
    private let scanQueue = DispatchQueue(label: "atelier.scan", qos: .utility)
    private let analysisQueue = DispatchQueue(label: "atelier.analysis", qos: .userInitiated)
    private let lutQueue = DispatchQueue(label: "atelier.lut-library", qos: .userInitiated)
    /// Measures reference-color profiles off the main thread; kept separate from
    /// the preview/scan queues so importing a reference never blocks the editor.
    private let referenceQueue = DispatchQueue(label: "atelier.reference-color", qos: .userInitiated)
    private var lutImportToken: CancellationToken?
    private var analysisSourceKey: String?
    private var analysisGeneration = UUID()
    private var analysisBaseline = AdjustmentSettings()
    /// Parameter snapshots only: bounded, cheap to restore, never pixels.
    private var undoHistory = UndoHistory()
    /// Set while the model itself changes editing state (undo/redo, per-photo
    /// automatic resolution, multi-property commands) so those writes never
    /// enter the user's undo history.
    private var undoSuppressed = false
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
    private var portraitDetectionGeneration = UUID()
    private var referenceColorGeneration = UUID()
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
    private var cachedRegionalSuggestions: [RegionalAdjustmentSuggestion]?
    private var cachedLUTContext: LUTSemanticContext?
    private let libraryRootOverride: URL?
    private let preferences: UserDefaults
    private var rememberedSpaces: [String: String]
    var lutColorContracts: [String: String] {
        rememberedSpaces
    }
    var lutSpaceConfirmed: Bool { selectedOption?.path == nil || rememberedSpaces[selectedLUT] != nil }
    private var lutContractReady: Bool { lutSpaceConfirmed }

    var selectedPhoto: PhotoItem? { photos.first { $0.id == selectedID } }
    var selectedOption: LUTOption? { lutOptions.first { $0.id == selectedLUT } }
    var activeMaskIndex: Int? { adjustments.masks.firstIndex { $0.id == selectedMask } }
    var maskInteractionActive: Bool { drawingMask || maskEditMode || pickingMaskColor }
    var selectedLocalMask: LocalMask? { adjustments.masks.first { $0.id == selectedMask } }
    var canAddPortraitRefinement: Bool {
        guard !batchRunning, !previewBusy, !scanning, selectedPhoto != nil,
              !(automaticRecipe != nil && (analysisBusy || analysis == nil || analysisError != nil)) else { return false }
        return safePortraitMaskIndex != nil || adjustments.masks.count < 16
    }
    private var safePortraitMaskIndex: Int? {
        if let index = activeMaskIndex, isSafePortraitMask(adjustments.masks[index]) { return index }
        return adjustments.masks.firstIndex(where: isSafePortraitMask)
    }
    private func isSafePortraitMask(_ mask: LocalMask) -> Bool {
        mask.contentSelection == .faceSkin && mask.opacity > 0 && !mask.inverted
            && !mask.components.contains { $0.operation == .add }
    }
    private var maskPointCount: Int {
        adjustments.masks.reduce(0) { count, mask in
            count + mask.points.count + mask.components.reduce(0) { $0 + $1.points.count }
        }
    }
    private var maskComponentCount: Int { adjustments.masks.reduce(0) { $0 + $1.components.count } }
    var recipe: Recipe {
        var recipe = Recipe(adjustments: adjustments, export: exportSettings,
                            lutPath: selectedOption?.path,
                            lutIdentifier: selectedLUT == "none" || selectedOption?.path != nil ? nil : selectedLUT,
                            automatic: automaticRecipe)
        // v10 features: non-neutral portrait refinement, any reference-color
        // setting, and any export extension (HEIC/resize/template). Saving them
        // as v9 would be rejected by validateVersion() on load (silent downgrade
        // ban). The shared rule also covers the automatic recipe's
        // baseline/reference settings, so a hand-edited recipe cannot be saved as
        // v9 and then rejected by our own v10 gate.
        var requiredVersion = PhotoEngine.requiredRecipeVersion(adjustments: adjustments,
                                                                automatic: automaticRecipe)
        if exportSettings.requiresVersion10Recipe { requiredVersion = 10 }
        if requiredVersion > recipe.version { recipe.version = requiredVersion }
        return recipe
    }
    var progress: Double { photos.isEmpty ? 0 : Double(processed) / Double(photos.count) }

    private var supportRoot: URL {
        libraryRootOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoAtelier", isDirectory: true)
    }

    init(libraryRoot: URL? = nil, preferences: UserDefaults = .standard) {
        self.libraryRootOverride = libraryRoot
        self.preferences = preferences
        self.rememberedSpaces = preferences.dictionary(forKey: "lutColorSpaces") as? [String: String] ?? [:]
        nativeInspection = NativeInspectionController(queue: previewQueue)
        stylePreviews = StylePreviewController(queue: previewQueue)
        lutOptions = [LUTOption(id: "none", name: "原色", detail: "只做基础调整", cube: nil, path: nil)]
            + LUTCube.builtIns.map { LUTOption(id: $0.id, name: $0.name, detail: $0.detail, cube: $0.cube, path: nil,
                                               group: $0.group, recommendedIntensity: $0.recommendedIntensity, tags: $0.tags) }
        let library = supportRoot.appendingPathComponent("LUTs", isDirectory: true)
        lutLibraryBusy = true
        lutQueue.async { [weak self] in
            var options: [LUTOption] = FilmLUTCatalog.presets.map {
                LUTOption(id: $0.id, name: $0.name, detail: $0.detail, cube: $0.cube, path: nil,
                    group: $0.group, recommendedIntensity: $0.recommendedIntensity, tags: $0.tags, provenance: $0.provenance)
            }
            var failures = 0
            if let urls = try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil) {
                for url in urls.filter({ $0.pathExtension.lowercased() == "cube" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    if let cube = try? LUTCube.load(url: url) {
                        options.append(LUTOption(id: url.path, name: cube.title, detail: "自定义 · 请确认输入空间", cube: cube, path: url.path))
                    } else { failures += 1 }
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lutOptions += options.filter { option in !self.lutOptions.contains { $0.id == option.id } }
                if self.lutImportToken == nil { self.lutLibraryBusy = false }
                if failures > 0 { self.lutLibraryMessages = ["资料库中有 \(failures) 个 LUT 无法读取，已隔离；其余风格可继续使用。"] }
            }
        }
        #if DEBUG
        // Executed by every debug launch, including `--self-test`: the direct
        // assertion for the portrait limits/coverage/v10-upgrade contract.
        let portraitContractFailure = Self.portraitContractSelfCheckFailure()
        assert(portraitContractFailure == nil, portraitContractFailure ?? "")
        if ProcessInfo.processInfo.arguments.contains("--self-test") {
            print("PORTRAIT_CONTRACT_SELF_CHECK \(portraitContractFailure == nil ? "PASS" : "FAIL")"
                + " · maxFaces=\(Self.portraitMaximumFaces)"
                + " · minSkinCoverage=\(Self.portraitMinimumSkinCoverage)"
                + " · neutralVersion=\(Self.portraitRecipeVersion(PortraitRefinementSettings()))"
                + " · nonNeutralVersion=\(Self.portraitRecipeVersion(PortraitRefinementSettings(blemishStrength: 0.2)))")
        }
        #endif
    }

    func chooseInput() {
        let panel = NSOpenPanel()
        panel.title = "打开照片或文件夹"
        panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "导入"
        // No allowedContentTypes filter on purpose: some RAW/AVIF extensions map to
        // dynamic UTIs on macOS 13, and a filter would hide files the decoder can
        // actually read. Unsupported picks are reported one by one instead.
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importSelection(panel.urls)
    }

    func loadFolder(_ url: URL) {
        guard !batchRunning else { return }
        prepareLibraryTransition()
        inputRoot = url
        photos = []; selectedID = nil; beforeImage = nil; afterImage = nil; thumbnails = [:]
        reloadFolder()
    }

    /// Clears per-photo state before the library root changes. Extracted from
    /// `loadFolder` so a multi-select import can replace the library without a full
    /// folder rescan; the reset sequence itself is unchanged.
    private func prepareLibraryTransition() {
        // A different library starts a new editing session: snapshots captured
        // for the previous photos must not be undone onto the new selection.
        resetUndoHistory()
        // Import issues belong to the previous selection; never leave a stale
        // "N items were not imported" hint on the new library.
        importIssues = []
        closeNativeInspection()
        nativeInspectionRegion = .init()
        cancelMaskInteraction()
        maskOverlayImage = nil; maskInspection = nil
        styleReference = nil; stylePreviews.cancel()
        regionalSuggestions = []
        invalidatePortraitDetection()
        pendingPreview?.cancel(); previewToken?.cancel(); previewGeneration = UUID()
        previewBusy = false; previewReport = .init(); histogram = Array(repeating: 0, count: 64)
        invalidateAnalysis()
    }

    /// Imports explicitly opened or dropped files and folders off the main thread.
    /// Folders honor the recursive setting; files are validated by
    /// `PhotoSelection.resolve`. An import inside the already-open folder extends
    /// the library with de-duplication (a second import), anything else replaces
    /// the library root. Rejected inputs are collected per item and never abort the
    /// accepted photos. The scan generation token keeps repeated imports ordered.
    func importSelection(_ urls: [URL], extraIssues: [String] = []) {
        guard !batchRunning, !urls.isEmpty else {
            if !extraIssues.isEmpty { reportImportFailure(extraIssues.joined(separator: "\n")) }
            return
        }
        let inputs = urls.map { $0.standardizedFileURL }
        let generation = UUID(); scanGeneration = generation
        let carriedIssues = extraIssues
        scanning = true; importIssues = carriedIssues
        status = "正在导入所选项目…"
        let recursive = exportSettings.recursive
        let currentRoot = inputRoot
        let existing = photos
        scanQueue.async { [weak self] in
            guard let self = self else { return }
            var directoryURLs: [URL] = []
            var fileURLs: [URL] = []
            var issues: [String] = []
            for url in inputs {
                guard url.isFileURL else {
                    issues.append("\(url.absoluteString)：只支持本地文件")
                    continue
                }
                do {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true {
                        issues.append("\(url.lastPathComponent)：不跟随符号链接，已跳过")
                    } else if values.isDirectory == true {
                        directoryURLs.append(url)
                    } else {
                        fileURLs.append(url)
                    }
                } catch {
                    issues.append("\(url.lastPathComponent)：无法读取文件属性：\(error.localizedDescription)")
                }
            }

            var scannedURLs: [URL] = []
            for directory in directoryURLs {
                do {
                    scannedURLs += try PhotoLoader.scan(folder: directory, recursive: recursive).map(\.url)
                } catch {
                    issues.append("\(directory.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            let resolved = PhotoSelection.resolve(fileURLs: fileURLs)
            issues += resolved.issues.map { "\($0.url.lastPathComponent)：\($0.message)" }
            let importRoot = PhotoSelection.commonRoot(
                of: directoryURLs + resolved.items.map { $0.url.deletingLastPathComponent() }
            )

            DispatchQueue.main.async {
                guard self.scanGeneration == generation else { return }
                self.scanning = false
                let allIssues = carriedIssues + issues
                self.importIssues = allIssues
                defer {
                    if !allIssues.isEmpty {
                        self.errorMessage = "以下 \(allIssues.count) 个项目未导入：\n" + allIssues.joined(separator: "\n")
                    }
                }
                guard let root = importRoot else {
                    self.status = allIssues.isEmpty ? "没有可导入的照片。" : "没有可导入的照片，请查看未导入原因。"
                    return
                }
                let importedURLs = scannedURLs + resolved.items.map(\.url)
                if PhotoSelection.shouldAppend(incomingRoot: root, currentRoot: currentRoot) {
                    // Re-base to the open library root, not the dropped subfolder, so
                    // `relativePath` (used for batch output naming) stays stable.
                    let libraryRoot = currentRoot ?? root
                    let incoming = PhotoSelection.items(fileURLs: importedURLs, root: libraryRoot)
                    let merged = PhotoSelection.merge(existing: existing, incoming: incoming)
                    let added = merged.count - existing.count
                    self.photos = merged
                    self.status = added > 0
                        ? "已追加 \(added) 张照片 · 共 \(merged.count) 张 · 原图保持不变"
                        : "没有新增照片；重复或不支持的项目已记录。"
                    if self.selectedID == nil, let first = merged.first { self.selectPhoto(first) }
                } else {
                    let incoming = PhotoSelection.items(fileURLs: importedURLs, root: root)
                    self.prepareLibraryTransition()
                    self.inputRoot = root
                    self.photos = incoming
                    self.selectedID = incoming.first?.id
                    self.beforeImage = nil; self.afterImage = nil; self.thumbnails = [:]
                    self.status = incoming.isEmpty
                        ? "所选项目中没有被支持的照片。"
                        : "已载入 \(incoming.count) 张照片 · \(root.lastPathComponent) · 原图保持不变"
                    self.requestPreview(immediate: true)
                }
            }
        }
    }

    /// Re-opens the per-item import report in the alert; used by the library panel.
    func reviewImportIssues() {
        guard !importIssues.isEmpty else { return }
        errorMessage = "以下 \(importIssues.count) 个项目未导入：\n" + importIssues.joined(separator: "\n")
    }

    /// Records a drop that never produced a usable file URL (for example a text
    /// selection or an unreadable provider) so drag-and-drop failures stay visible.
    func reportImportFailure(_ message: String) {
        importIssues.append(message)
        errorMessage = "以下 \(importIssues.count) 个项目未导入：\n" + importIssues.joined(separator: "\n")
    }

    func reloadFolder() {
        guard let root = inputRoot, !batchRunning else { return }
        nativeInspection.cancel()
        regionalSuggestions = []
        // A rescan replaces the selection, so previous per-item import failures
        // are no longer relevant (W1 review nit F2).
        importIssues = []
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
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importLUTFiles(panel.urls)
    }

    func importLUTFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !batchRunning, lutImportToken == nil else { return }
        let token = CancellationToken(); lutImportToken = token
        let selectionAtStart = selectedLUT
        let library = supportRoot.appendingPathComponent("LUTs", isDirectory: true)
        lutLibraryBusy = true; lutImportCompleted = 0; lutImportTotal = urls.count; lutLibraryMessages = []
        lutQueue.async { [weak self] in
            var imported: [LUTOption] = []
            var failures: [String] = []
            for (index, url) in urls.enumerated() {
                if token.isCancelled { break }
                autoreleasepool {
                    do {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 48_000_000 else { throw AtelierError.invalidLUT("文件超过 48 MB") }
                        let data = try Data(contentsOf: url, options: .mappedIfSafe)
                        guard data.count <= 48_000_000 else { throw AtelierError.invalidLUT("文件超过 48 MB") }
                        guard let text = String(data: data, encoding: .utf8) else { throw AtelierError.invalidLUT("请选择 UTF-8 文本 .cube") }
                        let cube = try LUTCube.parse(text)
                        try token.check()
                        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
                        let target = library.appendingPathComponent(UUID().uuidString + ".cube")
                        try data.write(to: target, options: .atomic)
                        imported.append(LUTOption(id: target.path, name: cube.title, detail: "自定义 · 请确认输入空间", cube: cube, path: target.path))
                    } catch {
                        if !token.isCancelled { failures.append("第 \(index + 1) 个文件：\(error.localizedDescription)") }
                    }
                }
                DispatchQueue.main.async { [weak self] in self?.lutImportCompleted = index + 1 }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lutOptions += imported
                self.lutLibraryMessages = failures
                self.lutLibraryBusy = false; self.lutImportToken = nil
                if let last = imported.last, self.selectedLUT == selectionAtStart {
                    self.selectLUT(last.id); self.requestPreview(immediate: true)
                }
                self.status = "\(token.isCancelled ? "已停止导入" : "导入完成")：成功 \(imported.count)，失败 \(failures.count)。请按作者说明确认自定义 LUT 的输入空间。"
            }
        }
    }

    func cancelLUTImport() {
        lutImportToken?.cancel()
        if lutImportToken != nil { status = "正在停止导入；当前文件的解析返回后停止，已导入风格保留。" }
    }

    func adoptRecommendedLUTIntensity() {
        guard let strength = selectedOption?.recommendedIntensity else { return }
        adjustments.lutIntensity = strength
    }

    func selectLUT(_ id: String) {
        guard !batchRunning, lutOptions.contains(where: { $0.id == id }) else { return }
        performUndoableEdit("look.lutIdentifier") {
            selectedLUT = id
            if selectedOption?.path == nil { adjustments.lutColorSpace = .sRGB }
            else { adjustments.lutColorSpace = LUTColorSpace(rawValue: rememberedSpaces[id] ?? "") ?? .sRGB }
            if selectedOption?.provenance != nil, adjustments.adaptiveLUT == nil {
                adjustments.adaptiveLUT = .init()
                status = "已启用逐图胶片适配；LUT 强度作为上限，每张照片分别评估。"
            }
        }
    }

    func rememberLUTSpace() {
        guard selectedOption?.path != nil else { return }
        rememberedSpaces[selectedLUT] = adjustments.lutColorSpace.rawValue
        preferences.set(rememberedSpaces, forKey: "lutColorSpaces")
        requestPreview(immediate: true)
    }

    func setLUTColorSpace(_ space: LUTColorSpace) {
        adjustments.lutColorSpace = space
        rememberLUTSpace()
    }

    func selectPhoto(_ photo: PhotoItem) {
        guard selectedID != photo.id else { return }
        nativeInspection.cancel()
        nativeInspectionRegion.center = .init(x: 0.5, y: 0.5)
        cancelMaskInteraction()
        maskOverlayImage = nil; maskInspection = nil
        styleReference = nil; stylePreviews.cancel()
        invalidatePortraitDetection()
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
        guard lutContractReady else {
            afterImage = nil; previewBusy = false; previewReport = .init()
            status = "先依作者说明确认此自定义 LUT 的输入／输出空间，再进行逐图适配。"
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
                    let baked = try PreviewRaster.make(scaled, context: self.engine.context,
                                                        colorSpace: working, format: .RGBAh)
                    loaded = LoadedPhoto(image: CIImage(cgImage: baked), properties: decoded.properties, report: decoded.report)
                    self.cachedPreviewKey = cacheKey; self.cachedPreview = loaded
                }
                try token.check()
                let small = loaded.image
                var referenceSettings = settings
                referenceSettings.masks = []
                referenceSettings.creativeEffects = nil
                referenceSettings.adaptiveLUT = nil
                // These fields cannot affect a LUT-free, output-free reference.
                // Canonicalize them so changing a look reuses measurements.
                let defaults = AdjustmentSettings()
                referenceSettings.lutIntensity = 0
                referenceSettings.lutColorSpace = .sRGB
                referenceSettings.preserveLuminance = defaults.preserveLuminance
                referenceSettings.protectSkin = defaults.protectSkin
                referenceSettings.protectNeutrals = defaults.protectNeutrals
                referenceSettings.gamutCompression = defaults.gamutCompression
                referenceSettings.colorHarmony = nil
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
                    self.cachedRegionalSuggestions = nil
                    self.cachedLUTContext = nil
                }
                try token.check()
                var contentTargets = Set(settings.masks.filter { $0.enabled && $0.opacity > 0 }
                    .compactMap(\.contentSelection))
                let adaptive = settings.adaptiveLUT?.enabled == true && cube != nil && settings.lutIntensity > 0
                if adaptive { contentTargets.insert(.faceSkin) }
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
                let lutContext: LUTSemanticContext?
                if adaptive {
                    if let cached = self.cachedLUTContext { lutContext = cached }
                    else {
                        let measured = try LUTSemanticContext.analyze(reference, cancellation: token)
                        self.cachedLUTContext = measured; lutContext = measured
                    }
                } else { lutContext = nil }
                let output = try self.engine.process(small, settings: settings, lut: cube, initialReport: loaded.report,
                                                     outputColorSpace: outputSpace, cancellation: token,
                                                     preparedContentSelections: contentSelections, preparedLUTContext: lutContext)
                let space = outputSpace.cgColorSpace
                let before = try PreviewRaster.make(small, context: self.engine.context, colorSpace: space)
                let after = try PreviewRaster.make(output.image, context: self.engine.context, colorSpace: space)
                let histogram = self.makeHistogram(output.image)
                var maskOverlay: CGImage?
                var inspection: MaskInspection?
                let regionalSuggestions: [RegionalAdjustmentSuggestion]
                if let cached = self.cachedRegionalSuggestions { regionalSuggestions = cached }
                else {
                    regionalSuggestions = try RegionalAdjustmentAnalyzer.suggestions(reference: reference,
                                                                                      context: self.engine.context)
                    self.cachedRegionalSuggestions = regionalSuggestions
                }
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
                    if self.styleReference !== reference { self.styleReference = reference }
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
        performUndoableEdit("analysis.sceneIntent") {
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
                            let resolved = try automatic.resolve(analysis: analysis, current: self.adjustments)
                            self.undoSuppressed = true
                            self.adjustments = resolved
                            self.undoSuppressed = false
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
                        let cg = try PreviewRaster.make(processed.image, context: engine.context,
                                                        colorSpace: outputSpace.cgColorSpace)
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
        performUndoableEdit("analysis.proposal") {
            automaticRecipe = AutomaticBatchRecipe(styleID: id, baseline: analysisBaseline,
                                                   referenceSettings: proposal.settings, sceneIntent: analysisIntent)
            adjustments = AutomaticBatchRecipe.copyBasicAdjustments(from: proposal.settings, into: adjustments)
            cancelMaskInteraction()
        }
        status = "已采用“\(proposal.title)”。可继续微调；批量导出会逐张分析并叠加这些微调。"
        requestPreview(immediate: true)
    }

    func useManualParameters() {
        performUndoableEdit("analysis.manualMode") { automaticRecipe = nil }
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
        guard !batchRunning, !lutLibraryBusy, let input = inputRoot, !photos.isEmpty else { return }
        guard lutContractReady else { status = "请先确认自定义 LUT 的输入／输出空间，再开始批处理。"; return }
        if outputRoot == nil { chooseOutput() }
        guard let output = outputRoot else { return }
        closeNativeInspection()
        showStyleBrowser = false; stylePreviews.cancel()
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
        guard lutContractReady else { status = "请先确认自定义 LUT 空间，再做原尺寸检查。"; return }
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
        guard showNativeInspection, !batchRunning, !scanning, lutContractReady, let photo = selectedPhoto else {
            nativeInspection.cancel(); return
        }
        nativeInspection.request(photo: photo, recipe: recipe, lut: selectedOption?.cube,
            lutID: selectedLUT, region: nativeInspectionRegion, immediate: immediate, force: force)
    }

    // MARK: - Undo / redo

    private func undoSnapshot(adjustments: AdjustmentSettings, lutID: String,
                              automaticRecipe: AutomaticBatchRecipe?,
                              sceneIntent: PhotoSceneIntent) -> UndoSnapshot {
        UndoSnapshot(adjustments: adjustments, lutID: lutID,
                     lutColorSpace: adjustments.lutColorSpace,
                     automaticRecipe: automaticRecipe, sceneIntent: sceneIntent)
    }

    private var currentUndoSnapshot: UndoSnapshot {
        undoSnapshot(adjustments: adjustments, lutID: selectedLUT,
                     automaticRecipe: automaticRecipe, sceneIntent: sceneIntent)
    }

    /// Seeds the pre-edit state so the first ⌘Z returns to it.
    private func seedUndoBaseline(_ snapshot: UndoSnapshot, at date: Date) {
        guard undoHistory.isEmpty else { return }
        undoHistory.push(snapshot, key: UndoHistory.initialKey, at: date)
    }

    private func recordUndoAdjustmentChange(from previous: AdjustmentSettings) {
        guard !undoSuppressed else { return }
        guard let key = adjustments.undoEditKey(comparedTo: previous) else { return }
        let now = Date()
        seedUndoBaseline(undoSnapshot(adjustments: previous, lutID: selectedLUT,
                                      automaticRecipe: automaticRecipe, sceneIntent: sceneIntent), at: now)
        undoHistory.push(currentUndoSnapshot, key: key, at: now)
        refreshUndoAvailability()
    }

    private func recordUndoLookChange(previousLUT: String) {
        guard !undoSuppressed, previousLUT != selectedLUT else { return }
        let now = Date()
        seedUndoBaseline(undoSnapshot(adjustments: adjustments, lutID: previousLUT,
                                      automaticRecipe: automaticRecipe, sceneIntent: sceneIntent), at: now)
        undoHistory.push(currentUndoSnapshot, key: "look.lutIdentifier", at: now)
        refreshUndoAvailability()
    }

    /// Runs a command that touches several properties as one undo step.
    private func performUndoableEdit(_ key: String, _ body: () -> Void) {
        guard !undoSuppressed else { body(); return }
        let previous = currentUndoSnapshot
        let now = Date()
        undoSuppressed = true
        body()
        undoSuppressed = false
        let after = currentUndoSnapshot
        guard after != previous else { return }
        seedUndoBaseline(previous, at: now)
        undoHistory.push(after, key: key, at: now)
        refreshUndoAvailability()
    }

    private func refreshUndoAvailability() {
        canUndo = undoHistory.canUndo
        canRedo = undoHistory.canRedo
    }

    private func resetUndoHistory() {
        undoHistory.reset()
        refreshUndoAvailability()
    }

    /// Restores one snapshot as a whole. It must not record a new step and must not
    /// leave an automatic baseline from a different state in place, so analysis is
    /// re-run instead of showing proposals measured against the old baseline.
    private func restoreUndoSnapshot(_ snapshot: UndoSnapshot) {
        undoSuppressed = true
        if adjustments != snapshot.adjustments { adjustments = snapshot.adjustments }
        let lutID = lutOptions.contains { $0.id == snapshot.lutID } ? snapshot.lutID : "none"
        if selectedLUT != lutID { selectedLUT = lutID }
        if automaticRecipe != snapshot.automaticRecipe { automaticRecipe = snapshot.automaticRecipe }
        if sceneIntent != snapshot.sceneIntent { sceneIntent = snapshot.sceneIntent }
        undoSuppressed = false
        reconcileReferenceColorSource(restoredProfile: snapshot.adjustments.referenceColor?.profile,
                                      label: "profile（历史恢复）")
        if let selected = selectedMask, !adjustments.masks.contains(where: { $0.id == selected }) {
            selectedMask = adjustments.masks.last?.id
        }
        cancelMaskInteraction(); maskOverlayImage = nil; maskInspection = nil
        invalidateAnalysis()
        refreshUndoAvailability()
        requestPreview(immediate: true)
    }

    func undo() {
        guard !batchRunning else { return }
        guard let snapshot = undoHistory.undo() else { return }
        restoreUndoSnapshot(snapshot)
        status = "已撤销上一步编辑。"
    }

    func redo() {
        guard !batchRunning else { return }
        guard let snapshot = undoHistory.redo() else { return }
        restoreUndoSnapshot(snapshot)
        status = "已重做上一步编辑。"
    }

    func resetAdjustments() {
        performUndoableEdit("settings.reset") {
            sceneIntent = .automatic
            regionalSuggestions = []
            automaticRecipe = nil; invalidateAnalysis()
            cancelMaskInteraction(); maskOverlayImage = nil; maskInspection = nil
            adjustments = .init(); selectedLUT = "none"; selectedMask = nil; drawingMask = false
            referenceColorThumbnail = nil
            referenceColorThumbnailProfile = nil
            referenceColorSourceName = nil
        }
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

    func addPortraitRefinement() {
        guard canAddPortraitRefinement else { return }
        cancelMaskInteraction()
        if let index = safePortraitMaskIndex {
            var mask = adjustments.masks[index]
            mask.enabled = true
            if var adaptation = mask.detailAdaptation {
                adaptation.intent = .portrait
                mask.detailAdaptation = adaptation
            } else {
                mask.detailAdaptation = LocalDetailAdaptation(intent: .portrait, strength: 0.6)
            }
            adjustments.masks[index] = mask
            selectedMask = mask.id
        } else {
            let mask = LocalMask(name: "智能人像精修 · 面部皮肤候选", kind: .luminance,
                                 exposureEV: 0, highlightProtection: 0.65, colorProtection: 0.8,
                                 contentSelection: .faceSkin,
                                 detailAdaptation: LocalDetailAdaptation(intent: .portrait, strength: 0.6))
            adjustments.masks.append(mask)
            selectedMask = mask.id
        }
        showMaskCoverage = false
        showMaskOverlay = false
        status = "正在测量本张照片的面部候选；若未检测到可靠覆盖，细节处理会跳过。不会重置其他蒙版或已保存的局部参数。"
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

    // MARK: Portrait contract (limits, coverage, recipe version)

    /// The portrait pipeline (`PortraitSemanticMaskProvider`) evaluates at most
    /// four faces. The UI detection must use the same cap so the panel never
    /// reports a face count the retouch cannot actually process.
    static let portraitMaximumFaces = 4
    /// A skin matte covering no more than this fraction of the frame is treated
    /// as unusable (gray/blank frames, false positives). The rule lives in
    /// PhotoCore so the portrait inspector and the skin-limited reference-color
    /// stage share one threshold.
    static let portraitMinimumSkinCoverage = PhotoEngine.minimumSkinMaskCoverage

    static func isUsableSkinCoverage(_ coverage: Double) -> Bool {
        PhotoEngine.isUsableSkinCoverage(coverage)
    }

    /// Fraction of the frame covered by a soft matte, sampled by PhotoCore at most
    /// 128px on the longest edge; used only for UI state decisions, never output.
    static func portraitSkinCoverage(of mask: CIImage, context: CIContext) -> Double {
        PhotoEngine.skinMaskCoverage(of: mask, context: context)
    }

    /// True when the adjustment payload requires recipe version 10 because of the
    /// portrait field. The save path uses this so non-neutral portrait settings
    /// cannot silently be written as v9 (which `validateVersion` rejects).
    static func portraitRecipeNeedsVersion10(_ adjustments: AdjustmentSettings) -> Bool {
        !(adjustments.portrait?.isNeutral ?? true)
    }

    /// Version written for a portrait-only payload: neutral stays v9, any
    /// non-neutral control upgrades to v10.
    static func portraitRecipeVersion(_ settings: PortraitRefinementSettings) -> Int {
        settings.isNeutral ? 9 : 10
    }

    /// Direct debug assertion of the portrait contract. Runs on every debug app
    /// launch (including `--self-test`) and prints its result when smoke-testing,
    /// so the v10-upgrade rule and the face/coverage limits are exercised by the
    /// app itself instead of only by review.
    static func portraitContractSelfCheckFailure() -> String? {
        if portraitMaximumFaces != 4 {
            return "portraitMaximumFaces must stay 4 to match PortraitSemanticMaskProvider"
        }
        guard portraitMinimumSkinCoverage > 0 else {
            return "portraitMinimumSkinCoverage must be positive"
        }
        if isUsableSkinCoverage(0) || isUsableSkinCoverage(portraitMinimumSkinCoverage)
            || !isUsableSkinCoverage(portraitMinimumSkinCoverage * 2)
            || isUsableSkinCoverage(Double.nan) || isUsableSkinCoverage(Double.infinity) {
            return "isUsableSkinCoverage threshold behaviour is wrong"
        }
        if portraitRecipeVersion(PortraitRefinementSettings()) != 9 {
            return "neutral portrait settings must stay on recipe v9"
        }
        if portraitRecipeVersion(PortraitRefinementSettings(blemishStrength: 0.2)) != 10 {
            return "non-neutral portrait settings must save as recipe v10"
        }
        var neutral = AdjustmentSettings()
        neutral.portrait = PortraitRefinementSettings()
        if portraitRecipeNeedsVersion10(neutral) {
            return "explicitly neutral portrait settings must not require v10"
        }
        var active = AdjustmentSettings()
        active.portrait = PortraitRefinementSettings(teethWhiten: 0.3)
        if !portraitRecipeNeedsVersion10(active) {
            return "non-neutral portrait settings must require v10"
        }
        return nil
    }

    // MARK: Portrait refinement

    /// Requests face detection on a background queue. The panel stays disabled
    /// until a useful skin matte exists, and the summary states why.
    func requestPortraitDetection(force: Bool = true) {
        guard let photo = selectedPhoto, !batchRunning else {
            invalidatePortraitDetection()
            return
        }
        if !force, portraitFaceStatus.isDetecting == false,
           portraitFaceStatus.hasCompleted, portraitFaceStatus.photoID == photo.id {
            return
        }
        let generation = UUID(); portraitDetectionGeneration = generation
        portraitFaceStatus = PortraitFaceStatus(isDetecting: true, photoID: photo.id,
            summary: "正在检测人脸与皮肤蒙版（最多处理前 \(Self.portraitMaximumFaces) 张）…")
        let engine = self.engine
        analysisQueue.async { [weak self] in
            let result = Result { () throws ->
                (faces: [FaceLandmarkSet], usableSkin: Bool, maximumCoverage: Double) in
                let loaded = try PhotoLoader.load(url: photo.url, lensCorrection: false)
                let faces = FaceSemanticAnalyzer.detect(in: loaded.image, maxFaces: Self.portraitMaximumFaces)
                var maximumCoverage = 0.0
                for landmarks in faces {
                    guard let skin = FaceSemanticAnalyzer.masks(image: loaded.image,
                                                                faceBounds: landmarks.boundingBox,
                                                                landmarks: landmarks).skin else { continue }
                    let coverage = Self.portraitSkinCoverage(of: skin, context: engine.context)
                    maximumCoverage = max(maximumCoverage, coverage)
                    if Self.isUsableSkinCoverage(maximumCoverage) { break }
                }
                return (faces, Self.isUsableSkinCoverage(maximumCoverage), maximumCoverage)
            }
            DispatchQueue.main.async {
                guard let self = self, self.portraitDetectionGeneration == generation else { return }
                switch result {
                case .success(let detection):
                    let confidence = detection.faces.map(\.confidence).max() ?? 0
                    let coveragePercent = String(format: "%.3f%%", detection.maximumCoverage * 100)
                    if detection.faces.isEmpty {
                        self.portraitFaceStatus = PortraitFaceStatus(hasCompleted: true,
                            photoID: photo.id, summary:
                            "未检测到可用人脸：人像修复依赖本机 Vision 的人脸地标；侧脸、遮挡、小脸可能漏检。本机人像最多处理前 \(Self.portraitMaximumFaces) 张人脸，未检测到人脸时不应用人像调整。")
                    } else if !detection.usableSkin {
                        self.portraitFaceStatus = PortraitFaceStatus(hasCompleted: true,
                            photoID: photo.id, detectedFaceCount: detection.faces.count,
                            maximumConfidence: confidence,
                            summary: "检测到 \(detection.faces.count) 张人脸（本机最多处理前 \(Self.portraitMaximumFaces) 张），但皮肤蒙版覆盖不足（最高约 \(coveragePercent)，低于阈值 \(Self.portraitMinimumSkinCoverage * 100)%%）；人像整段跳过、不改像素，控件保持禁用。")
                    } else {
                        self.portraitFaceStatus = PortraitFaceStatus(hasCompleted: true,
                            photoID: photo.id, detectedFaceCount: detection.faces.count,
                            maximumConfidence: confidence, hasUsableSkinMask: true,
                            summary: "检测到 \(detection.faces.count) 张人脸（本机最多处理前 \(Self.portraitMaximumFaces) 张）· 最高置信度 \(Int((confidence * 100).rounded()))% · 皮肤覆盖约 \(coveragePercent)；人像调整只在这张照片的预览中应用。")
                    }
                case .failure(let error):
                    self.portraitFaceStatus = PortraitFaceStatus(hasCompleted: true, photoID: photo.id,
                        summary: "人脸检测未完成：\(error.localizedDescription)；人像调整未启用。")
                }
            }
        }
    }

    func invalidatePortraitDetection() {
        portraitDetectionGeneration = UUID()
        portraitFaceStatus = PortraitFaceStatus()
    }

    /// Applies one portrait-field edit. Neutral settings collapse back to `nil`
    /// so old recipes keep the exact pre-v10 decode/encode shape.
    func updatePortraitSettings(_ mutate: (inout PortraitRefinementSettings) -> Void) {
        var settings = adjustments.portrait ?? PortraitRefinementSettings()
        mutate(&settings)
        adjustments.portrait = settings.isNeutral ? nil : settings
    }

    func setPortraitToneReference(_ reference: PortraitToneReference) {
        var settings = adjustments.portrait ?? PortraitRefinementSettings()
        settings.skinToneReference = reference
        if settings.isNeutral { adjustments.portrait = nil } else { adjustments.portrait = settings }
    }

    /// Conservative "light retouch" starting point. Requires a usable face so the
    /// button cannot silently do nothing on a frame without landmarks.
    func applyLightPortraitStart() {
        guard portraitFaceStatus.hasUsableSkinMask, !batchRunning else {
            status = "未检测到可用人脸或皮肤蒙版，无法应用人像精修起点。"
            return
        }
        adjustments.portrait = PortraitRefinementSettings(
            blemishStrength: 0.25, dodgeBurn: 0.30, structure: 0.15, texture: 0.15,
            gloss: 0.15, teethWhiten: 0.20, eyeBrighten: 0.20, skinToneUnify: 0.20)
        status = "已应用轻度人像精修起点；请逐张预览确认，算法不保证真实照片效果。"
    }

    func resetPortraitSettings() {
        adjustments.portrait = nil
        status = "已归零人像调整。"
    }

    // MARK: Reference color ("AI 追色")

    /// Opens an image panel and measures the chosen photo into a reference profile.
    ///
    /// The reference photo is read locally only; the recipe stores the measured
    /// OKLab profile, never the image. This is a global colour-distribution match,
    /// not a face/object transfer and not a guarantee of a commercial-grade look.
    func chooseReferenceColorImage() {
        guard !batchRunning, !referenceColorBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择参考图（仅在本机测量色彩分布，不上传）"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadReferenceColor(from: url)
    }

    /// Measures `url` off the main thread and applies the resulting profile to the
    /// current edit. Failure is explicit: the previous profile (if any) stays and
    /// the error is surfaced instead of silently disabling the stage.
    func loadReferenceColor(from url: URL) {
        guard !batchRunning else { return }
        let generation = UUID(); referenceColorGeneration = generation
        let previous = adjustments.referenceColor
        referenceColorBusy = true
        referenceQueue.async { [weak self] in
            let result = Result { () throws -> (profile: ReferenceColorProfile, thumbnail: NSImage?) in
                let loaded = try PhotoLoader.load(url: url, lensCorrection: false)
                let profile = try ReferenceColorMatcher.profile(reference: loaded.image)
                let cg = try? PhotoLoader.thumbnail(url: url, maxDimension: 160)
                return (profile, cg.map { NSImage(cgImage: $0, size: .zero) })
            }
            DispatchQueue.main.async {
                guard let self = self, self.referenceColorGeneration == generation else { return }
                self.referenceColorBusy = false
                switch result {
                case .success(let loaded):
                    // Merge against the settings that are current *now*: an
                    // earlier `previous` capture would overwrite a strength /
                    // skin-only edit made while the measurement was running.
                    let current = self.adjustments.referenceColor ?? previous
                    self.adjustments.referenceColor = PhotoEngine.mergedReferenceColorSettings(
                        measured: loaded.profile, current: current)
                    self.referenceColorThumbnail = loaded.thumbnail
                    self.referenceColorThumbnailProfile = loaded.profile
                    self.referenceColorSourceName = url.lastPathComponent
                    self.status = "已建立参考图色彩 profile；追色只做全局 OKLab 分布匹配，不保证审美效果。"
                    self.requestPreview(immediate: true)
                case .failure(let error):
                    if self.adjustments.referenceColor == nil {
                        self.referenceColorThumbnail = nil
                        self.referenceColorThumbnailProfile = nil
                        self.referenceColorSourceName = nil
                    }
                    self.present(error)
                }
            }
        }
    }

    func clearReferenceColor() {
        referenceColorGeneration = UUID()
        referenceColorBusy = false
        adjustments.referenceColor = nil
        referenceColorThumbnail = nil
        referenceColorThumbnailProfile = nil
        referenceColorSourceName = nil
        status = "已清除参考图追色。"
        requestPreview(immediate: true)
    }

    /// Applies one reference-color edit. The profile is kept when only strength or
    /// the skin-only flag changes; a zero strength stays neutral in the engine.
    func updateReferenceColorSettings(_ mutate: (inout ReferenceColorSettings) -> Void) {
        guard var settings = adjustments.referenceColor else { return }
        mutate(&settings)
        settings.strength = min(max(settings.strength, 0), 1)
        adjustments.referenceColor = settings
    }

    func setReferenceColorStrength(_ value: Double) {
        updateReferenceColorSettings { $0.strength = value }
    }

    func setReferenceColorSkinOnly(_ enabled: Bool) {
        updateReferenceColorSettings { $0.skinOnly = enabled }
    }

    /// The thumbnail is display-only sugar; it is only shown while it still
    /// describes the active profile (undo/recipe-load can replace the profile).
    var referenceColorThumbnailMatchesProfile: Bool {
        guard let active = adjustments.referenceColor?.profile else { return false }
        return referenceColorThumbnail != nil && referenceColorThumbnailProfile == active
    }

    /// Keeps the display-only source label consistent with the active profile
    /// after a history restore or recipe load. When the restored profile no longer
    /// matches the retained thumbnail both are cleared and the label says where
    /// the profile came from, so the panel can never show a stale file name next
    /// to a placeholder thumbnail.
    private func reconcileReferenceColorSource(restoredProfile: ReferenceColorProfile?,
                                               label: String) {
        if let restoredProfile, restoredProfile == referenceColorThumbnailProfile,
           referenceColorThumbnail != nil {
            return
        }
        referenceColorThumbnail = nil
        referenceColorThumbnailProfile = nil
        referenceColorSourceName = restoredProfile == nil ? nil : label
    }

    func saveRecipe() {
        guard lutContractReady else { status = "先确认自定义 LUT 空间，再保存逐图适配配方。"; return }
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
            performUndoableEdit("recipe.load") {
                adjustments = saved.adjustments; exportSettings = saved.export; selectedLUT = target
                if saved.lutPath != nil { rememberLUTSpace() }
                automaticRecipe = saved.automatic; invalidateAnalysis()
                sceneIntent = saved.automatic?.sceneIntent ?? .automatic
                selectedMask = nil; cancelMaskInteraction(); maskOverlayImage = nil; maskInspection = nil
                // A recipe carries the measured profile, not the reference image:
                // drop any stale thumbnail so the panel never pairs them.
                referenceColorGeneration = UUID()
                referenceColorBusy = false
                referenceColorThumbnail = nil
                referenceColorThumbnailProfile = nil
                referenceColorSourceName = saved.adjustments.referenceColor == nil ? nil : "配方内 profile"
                status = "配方已载入。"
            }
            reloadFolder(); requestPreview(immediate: true)
        } catch { present(error) }
    }

    func revealOutput() {
        guard let root = outputRoot else { return }
        NSWorkspace.shared.open(root)
    }

    func present(_ error: Error) { errorMessage = error.localizedDescription; status = error.localizedDescription }
}

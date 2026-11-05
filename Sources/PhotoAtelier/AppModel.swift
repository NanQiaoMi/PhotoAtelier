import AppKit
import Combine
import CoreImage
import ImageIO
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
    @Published var selectedIDs: Set<String> = []

    // P1-D: Persistent non-destructive attribute library & pinned reference storage
    let libraryIndex = PhotoLibraryIndex()
    let referencePinStorage = ReferencePinStorage()
    @Published var isReferencePinned: Bool = false
    private(set) var lastReferenceColorURL: URL?
    private var currentCatalog: FolderCatalog?
    private var catalogSaveWorkItem: DispatchWorkItem?

    // P1-C culling session state: ratings/rejections/quality reports live on
    // `PhotoItem` and are deliberately never written to recipes or disk.
    @Published var cullFilter: PhotoCullFilter = .all
    @Published var exportSelectionOptions = ExportSelectionOptions()
    @Published var autoCullBusy = false
    @Published var autoCullProgress: Double = 0
    private var autoCullToken: CancellationToken?
    private let autoCullQueue = DispatchQueue(label: "PhotoAtelier.culling", qos: .userInitiated)
    @Published var adjustments = AdjustmentSettings() {
        didSet {
            refreshNativeInspection()
            recordUndoAdjustmentChange(from: oldValue)
        }
    }
    @Published var exportSettings = ExportSettings() {
        didSet { if oldValue.colorSpace != exportSettings.colorSpace { refreshNativeInspection() } }
    }
    /// Bounded-concurrency batch export width (1...8; 1 = serial). Session setting,
    /// deliberately not part of the recipe or the export settings: it only changes
    /// how fast the same pixels are produced, never the bytes.
    @Published var batchConcurrency: Int = ParallelBatch.defaultConcurrency {
        didSet {
            let clamped = ParallelBatch.effectiveConcurrency(batchConcurrency)
            if clamped != batchConcurrency { batchConcurrency = clamped }
        }
    }
    /// Latest-wins guard for async preview work; a slow render can never publish
    /// pixels over a newer request.
    private var previewGate = PreviewRequestGate()
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
    @Published var skipped = 0
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
    // P1 liquify / face-reshape editing state (settings live in adjustments.liquify).
    @Published var liquifyBrushActive = false
    @Published var liquifyBrushMode: WarpStroke.Mode = .push
    @Published var liquifyBrushRadius: Double = 0.08
    @Published var liquifyBrushStrength: Double = 0.6
    @Published private(set) var liquifyStrokeInProgress = false
    @Published private(set) var liquifyDraftStroke: WarpStroke?
    private var liquifyStrokeUndoBase: UndoSnapshot?
    private var liquifyStrokeLastPoint: MaskPoint?
    // P1-B manual repair / clone brush editing state (settings live in adjustments.repairBrush).
    @Published var repairBrushActive = false
    @Published var repairBrushMode: RepairBrushMode = .heal
    @Published var repairBrushRadius: Double = 0.06
    @Published var repairBrushFeather: Double = 0.5
    @Published var repairBrushStrength: Double = 1
    @Published var repairCloneSource: MaskPoint?
    @Published var repairSamplingCloneSource = false
    @Published private(set) var repairStrokeInProgress = false
    @Published private(set) var repairDraftStroke: RepairStroke?
    private var repairStrokeUndoBase: UndoSnapshot?
    private var repairStrokeLastPoint: MaskPoint?
    @Published var maskOverlayOpacity: Double = 0.55
    @Published var maskOverlayImage: NSImage?
    @Published var maskInspection: MaskInspection?
    @Published private(set) var regionalSuggestions: [RegionalAdjustmentSuggestion] = []
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var lastManifest: URL?
    /// Last generated customer delivery page (its index.html); nil until the
    /// "导出客户交付页" action succeeds once.
    @Published var lastDeliveryPage: URL?
    @Published private(set) var deliveryPageBusy = false
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

    /// Photos visible in the sidebar under the current session culling filter.
    var visiblePhotos: [PhotoItem] { PhotoSelection.filtered(photos, filter: cullFilter) }
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
        if exportSettings.requiresVersion10Recipe { requiredVersion = max(requiredVersion, 10) }
        // Any stored watermark payload needs v11 (its data only exists there), so
        // a saved recipe can be loaded back instead of failing our own v11 gate.
        // Approved P1-7 scope extension: this is the only AppModel change.
        if exportSettings.storesWatermarkData { requiredVersion = max(requiredVersion, 11) }
        // The delivery page payload only exists in v12 recipes; bumping on save
        // keeps the recipe loadable by our own v12 gate.
        if exportSettings.storesDeliveryPageData { requiredVersion = max(requiredVersion, 12) }
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
        self.isReferencePinned = referencePinStorage.hasPinnedReference
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
            var liquifyProbe = AdjustmentSettings()
            liquifyProbe.liquify = FaceReshapeSettings(preset: .youthful)
            let liquifyVersion = PhotoEngine.requiredRecipeVersion(adjustments: liquifyProbe,
                                                                   automatic: nil)
            var certificateProbe = AdjustmentSettings()
            certificateProbe.certificatePhoto = CertificatePhotoSettings(enabled: true, size: .oneInch)
            let certificateVersion = PhotoEngine.requiredRecipeVersion(adjustments: certificateProbe,
                                                                       automatic: nil)
            var makeupProbe = AdjustmentSettings()
            makeupProbe.makeup = MakeupSettings(lipIntensity: 0.5)
            let makeupVersion = PhotoEngine.requiredRecipeVersion(adjustments: makeupProbe,
                                                                  automatic: nil)
            print("PORTRAIT_CONTRACT_SELF_CHECK \(portraitContractFailure == nil ? "PASS" : "FAIL")"
                + " · maxFaces=\(Self.portraitMaximumFaces)"
                + " · minSkinCoverage=\(Self.portraitMinimumSkinCoverage)"
                + " · neutralVersion=\(Self.portraitRecipeVersion(PortraitRefinementSettings()))"
                + " · nonNeutralVersion=\(Self.portraitRecipeVersion(PortraitRefinementSettings(blemishStrength: 0.2)))"
                + " · liquifyVersion=\(liquifyVersion)"
                + " · certificateVersion=\(certificateVersion)"
                + " · makeupVersion=\(makeupVersion)")
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
        cancelLiquifyStroke()
        liquifyBrushActive = false
        cancelRepairStroke()
        repairBrushActive = false
        repairCloneSource = nil
        maskOverlayImage = nil; maskInspection = nil
        styleReference = nil; stylePreviews.cancel()
        regionalSuggestions = []
        invalidatePortraitDetection()
        pendingPreview?.cancel(); previewToken?.cancel(); previewGate.invalidate()
        previewBusy = false; previewReport = .init(); histogram = Array(repeating: 0, count: 64)
        invalidateAnalysis()
        // Culling session state belongs to the previous library: cancel any
        // in-flight auto-cull and return the filter to "all" (ratings live on the
        // replaced PhotoItem values, so they disappear with the library).
        autoCullToken?.cancel()
        autoCullToken = nil
        autoCullBusy = false
        autoCullProgress = 0
        cullFilter = .all
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
                    var merged = PhotoSelection.merge(existing: existing, incoming: incoming)
                    self.restoreCatalogAttributes(for: &merged, root: libraryRoot)
                    let added = merged.count - existing.count
                    self.photos = merged
                    self.status = added > 0
                        ? "已追加 \(added) 张照片 · 共 \(merged.count) 张 · 原图保持不变"
                        : "没有新增照片；重复或不支持的项目已记录。"
                    if self.selectedID == nil, let first = merged.first { self.selectPhoto(first) }
                } else {
                    var incoming = PhotoSelection.items(fileURLs: importedURLs, root: root)
                    self.restoreCatalogAttributes(for: &incoming, root: root)
                    self.prepareLibraryTransition()
                    self.inputRoot = root
                    self.photos = incoming
                    self.selectedID = incoming.first?.id
                    self.selectedIDs = incoming.first.map { [$0.id] } ?? []
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

    // MARK: - P1-D Library Persistence (Non-destructive attribute catalog)

    func restoreCatalogAttributes(for items: inout [PhotoItem], root: URL) {
        let catalog = libraryIndex.loadCatalog(forRoot: root)
        currentCatalog = catalog
        for i in items.indices {
            let rel = PhotoLibraryIndex.relativePath(of: items[i].url, relativeTo: root)
            if let rec = catalog.records[rel] {
                let (size, mtime) = PhotoLibraryIndex.fileAttributes(for: items[i].url) ?? (0, 0)
                if rec.matches(fileSize: size, modificationTimestamp: mtime) {
                    items[i].rating = rec.rating
                    items[i].isRejected = rec.isRejected
                    items[i].qualityReport = rec.qualityReport
                }
            }
        }
    }

    func saveCatalogDebounced() {
        catalogSaveWorkItem?.cancel()
        guard let root = inputRoot else { return }
        let currentPhotos = photos
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            var catalog = self.currentCatalog ?? self.libraryIndex.loadCatalog(forRoot: root)
            for photo in currentPhotos {
                self.libraryIndex.updateRecord(in: &catalog, for: photo.url, relativeTo: root) { rec in
                    rec.rating = photo.rating
                    rec.isRejected = photo.isRejected
                    rec.qualityReport = photo.qualityReport
                }
            }
            try? self.libraryIndex.saveCatalog(catalog, forRoot: root)
            DispatchQueue.main.async {
                self.currentCatalog = catalog
            }
        }
        catalogSaveWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35, execute: item)
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
                    var restoredItems = items
                    self.restoreCatalogAttributes(for: &restoredItems, root: root)
                    self.photos = restoredItems
                    if !restoredItems.contains(where: { $0.id == self.selectedID }) {
                        self.selectedID = restoredItems.first?.id
                    }
                    self.selectedIDs = self.selectedID.map { [$0] } ?? []
                    self.status = restoredItems.isEmpty ? "此文件夹中没有支持的照片。" : "已载入 \(restoredItems.count) 张照片 · 原图保持不变"
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
        selectPhotoInternal(photo, updateMultiSelect: true)
    }

    func togglePhotoSelection(_ photo: PhotoItem) {
        if selectedIDs.contains(photo.id) {
            selectedIDs.remove(photo.id)
            if selectedID == photo.id {
                if let nextID = selectedIDs.first, let nextPhoto = photos.first(where: { $0.id == nextID }) {
                    selectPhotoInternal(nextPhoto, updateMultiSelect: false)
                } else {
                    selectedID = nil
                    beforeImage = nil; afterImage = nil
                }
            }
        } else {
            selectedIDs.insert(photo.id)
            selectPhotoInternal(photo, updateMultiSelect: false)
        }
    }

    func selectAllPhotos() {
        selectedIDs = Set(photos.map(\.id))
        if selectedID == nil, let first = photos.first {
            selectPhotoInternal(first, updateMultiSelect: false)
        }
    }

    func clearPhotoSelection() {
        selectedIDs.removeAll()
        selectedID = nil
        beforeImage = nil; afterImage = nil
    }

    private func selectPhotoInternal(_ photo: PhotoItem, updateMultiSelect: Bool) {
        if updateMultiSelect {
            selectedIDs = [photo.id]
        }
        guard selectedID != photo.id else { return }
        nativeInspection.cancel()
        nativeInspectionRegion.center = .init(x: 0.5, y: 0.5)
        cancelMaskInteraction()
        cancelLiquifyStroke()
        liquifyBrushActive = false
        cancelRepairStroke()
        repairBrushActive = false
        repairCloneSource = nil
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
        let generation = previewGate.begin()
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
                    guard self.previewGate.admits(generation) else { return }
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
                    guard self.previewGate.admits(generation) else { return }
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
        // Analysis only needs a capped sample; the export path still uses the
        // full-resolution image, so downsampling here cannot change exported pixels.
        let analysisInput = engine.analysisSample(loaded.image)
        analysisImage = analysisInput
        analysisBusy = true; analysisError = nil; proposalPreviews = [:]
        analysisQueue.async { [weak self] in
            let result = Result { () throws -> PhotoAnalysis in
                try autoreleasepool {
                    try PhotoAnalyzer().analyze(image: analysisInput, properties: loaded.properties,
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
        // Freeze the recipe and the session culling selection before moving work
        // off the UI thread; neither ratings nor skip options are recipe data.
        let snapshot = recipe; let items = photos; let cube = selectedOption?.cube
        let selection = exportSelectionOptions
        let concurrency = ParallelBatch.effectiveConcurrency(batchConcurrency)
        let token = CancellationToken(); batchToken = token
        batchRunning = true; processed = 0; succeeded = 0; failed = 0; skipped = 0; lastManifest = nil
        batchMessages = []; currentFile = "准备导出…"; status = "批量处理中 · 使用当前统一配方"
        previewQueue.async { [weak self] in
            do {
                let summary = try BatchProcessor().run(items: items, inputRoot: input, outputRoot: output,
                                                      recipe: snapshot, lut: cube,
                                                      selection: selection,
                                                      maxConcurrency: concurrency,
                                                      cancellation: token) { event in
                    DispatchQueue.main.async { self?.consume(event) }
                }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.batchRunning = false; self.lastManifest = summary.manifestURL
                    self.succeeded = summary.succeeded; self.failed = summary.failed
                    self.skipped = summary.skipped
                    self.status = "\(summary.cancelled ? "已取消" : "导出完成") · 成功 \(summary.succeeded) 张，跳过 \(summary.skipped) 张，失败 \(summary.failed) 张"
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
        case .skipped: processed += 1
        default: break
        }
        if !event.message.isEmpty {
            batchMessages.append(event.message)
            if batchMessages.count > 200 { batchMessages.removeFirst() }
        }
    }

    func cancelBatch() { batchToken?.cancel(); status = "正在安全停止；已完成的照片保留。" }

    // MARK: - Culling / selection (P1-C C4)

    func setCullFilter(_ filter: PhotoCullFilter) {
        cullFilter = filter
        status = filter == .all
            ? "显示全部 \(photos.count) 张照片。"
            : "当前筛选：\(filter.title)；评级/废片为会话状态，不写配方。"
    }

    func setRating(_ rating: Int, for photoID: String) {
        guard let index = photos.firstIndex(where: { $0.id == photoID }) else { return }
        photos[index].rating = PhotoSelection.clampedRating(rating)
    }

    func rateSelectedPhoto(_ rating: Int) {
        let targets = selectedIDs.isEmpty ? (selectedID.map { [$0] } ?? []) : Array(selectedIDs)
        guard !targets.isEmpty else { return }
        let clamped = PhotoSelection.clampedRating(rating)
        for id in targets {
            setRating(clamped, for: id)
        }
        saveCatalogDebounced()
        status = targets.count > 1
            ? "已为选中的 \(targets.count) 张照片评 \(clamped) 星。"
            : (clamped == 0 ? "已清除当前照片的星级。" : "已为当前照片评 \(clamped) 星。")
    }

    func stepSelectedRating(by delta: Int) {
        guard let photo = selectedPhoto else { return }
        rateSelectedPhoto(PhotoSelection.steppedRating(photo.rating, delta: delta))
    }

    func toggleSelectedRejection() {
        let targets = selectedIDs.isEmpty ? (selectedID.map { [$0] } ?? []) : Array(selectedIDs)
        guard !targets.isEmpty else { return }
        let indices = targets.compactMap { id in photos.firstIndex(where: { $0.id == id }) }
        guard !indices.isEmpty else { return }
        let allRejected = indices.allSatisfy { photos[$0].isRejected }
        let newState = !allRejected
        for idx in indices {
            photos[idx].isRejected = newState
        }
        saveCatalogDebounced()
        status = targets.count > 1
            ? (newState ? "已将选中的 \(targets.count) 张照片标记为废片。" : "已取消选中照片的废片标记。")
            : (newState ? "已标记为废片；导出时可勾选「跳过废片」。" : "已取消废片标记。")
    }

    /// Runs the heuristic culling analysis in the background. Results are applied
    /// on the main thread; manual ratings/rejections are never overwritten.
    func runAutoCull() {
        guard !batchRunning, !autoCullBusy, !photos.isEmpty, !scanning else { return }
        let token = CancellationToken()
        autoCullToken = token
        autoCullBusy = true
        autoCullProgress = 0
        status = "自动挑图：正在分析 \(photos.count) 张照片（启发式 v1）…"
        let items = photos
        autoCullQueue.async { [weak self] in
            var reports: [String: QualityReport] = [:]
            var unreadable = 0
            for (offset, item) in items.enumerated() {
                if token.isCancelled { break }
                if let image = Self.cullingAnalysisImage(url: item.url) {
                    let faces = FaceSemanticAnalyzer.detect(in: image, maxFaces: 4)
                    if let report = try? QualityAnalyzer.report(for: image, faces: faces) {
                        reports[item.id] = report
                    } else {
                        unreadable += 1
                    }
                } else {
                    unreadable += 1
                }
                let progress = Double(offset + 1) / Double(items.count)
                DispatchQueue.main.async { [weak self] in
                    // A library transition nils the token; do not let a stale
                    // in-flight loop write progress over a newer library/session.
                    guard let self = self, self.autoCullToken === token else { return }
                    self.autoCullProgress = progress
                }
            }
            DispatchQueue.main.async {
                // A library transition nils the token: never apply stale results
                // to a different library (a user cancel keeps the token).
                guard let self = self, self.autoCullToken === token else { return }
                self.autoCullToken = nil
                self.autoCullBusy = false
                self.autoCullProgress = 1
                var updated = self.photos
                let applied = PhotoSelection.applyingAutoCull(reports: reports, to: &updated)
                self.photos = updated
                self.saveCatalogDebounced()
                let cancelled = token.isCancelled
                self.status = cancelled
                    ? "自动挑图已取消：已分析 \(applied) / \(items.count) 张，结果保留。"
                    : "自动挑图完成：分析 \(applied) 张" + (unreadable > 0 ? "，\(unreadable) 张读取失败" : "") + "；星级/废片建议已填入，未覆盖手动标记。"
            }
        }
    }

    func cancelAutoCull() {
        guard autoCullBusy else { return }
        autoCullToken?.cancel()
        status = "正在取消自动挑图；已分析结果会保留。"
    }

    /// Builds a ≤1024px analysis image from the file thumbnail so auto-culling
    /// does not decode full-resolution originals.
    private static func cullingAnalysisImage(url: URL) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                               options as CFDictionary) else {
            return nil
        }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - Customer delivery page

    /// Exports the currently selected photo as a standalone offline customer
    /// delivery page (static HTML album + optional contact-sheet PDF) into a new,
    /// never-overwritten folder under a user-chosen parent directory. Rendering
    /// runs on the shared preview queue, so the UI stays responsive; the file
    /// format itself is the B3 `DeliveryGalleryWriter` (no network, metadata-free
    /// JPEGs, relative paths only).
    func exportDeliveryPage() {
        guard !batchRunning, !deliveryPageBusy, lutContractReady,
              let photo = selectedPhoto, let delivery = exportSettings.deliveryPage else { return }
        // Validate before the folder picker and before any background render: an
        // invalid title/range must never create an empty "客户交付-*" folder or
        // spend time rendering a page that cannot be written.
        do {
            try delivery.validate()
        } catch {
            present(error)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择客户交付页的导出位置（会新建独立子文件夹）"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择位置"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let snapshot = recipe
        let cube = selectedOption?.cube
        deliveryPageBusy = true
        status = "正在生成客户交付页…"
        errorMessage = nil
        previewQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let token = CancellationToken()
                let loaded = try PhotoLoader.load(url: photo.url,
                                                  lensCorrection: snapshot.adjustments.lensCorrection,
                                                  lensProfileID: snapshot.adjustments.lensProfileID,
                                                  lensCropFactor: snapshot.adjustments.lensCropFactor,
                                                  lensFocalLength: snapshot.adjustments.lensFocalLength)
                let processed = try self.engine.process(loaded.image,
                                                        settings: snapshot.adjustments,
                                                        lut: cube,
                                                        initialReport: loaded.report,
                                                        outputColorSpace: snapshot.export.colorSpace,
                                                        cancellation: token)
                var image = processed.image
                var effective = delivery
                if let watermark = snapshot.export.watermark, !watermark.isNeutral {
                    image = try WatermarkRenderer.render(on: image, canvasExtent: image.extent,
                                                        settings: watermark)
                    // The preview file itself is watermarked; keep the notice honest.
                    effective.watermarkedPreviews = true
                }
                let directory = try Self.createDeliveryDirectory(in: parent, photo: photo)
                let result: DeliveryGalleryResult
                do {
                    result = try DeliveryGalleryWriter.write(images: [image], settings: effective,
                                                             outputDirectory: directory,
                                                             context: self.engine.context)
                } catch {
                    // Never leave a partially written "客户交付-*" folder behind.
                    try? FileManager.default.removeItem(at: directory)
                    throw error
                }
                DispatchQueue.main.async {
                    self.deliveryPageBusy = false
                    self.lastDeliveryPage = result.indexHTMLURL
                    self.status = "客户交付页已生成 · \(result.indexHTMLURL.deletingLastPathComponent().lastPathComponent)"
                }
            } catch {
                DispatchQueue.main.async {
                    self.deliveryPageBusy = false
                    self.present(error)
                }
            }
        }
    }

    /// Creates a fresh `客户交付-<photo stem>` folder. Existing folders are never
    /// reused, so a delivery page can never overwrite an earlier delivery.
    private static func createDeliveryDirectory(in parent: URL, photo: PhotoItem) throws -> URL {
        let stem = (photo.url.lastPathComponent as NSString).deletingPathExtension
        let base = "客户交付-\(stem.isEmpty ? "照片" : stem)"
        for index in 1...10_000 {
            let name = index == 1 ? base : "\(base)-\(index)"
            let candidate = parent.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { continue }
            do {
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            } catch {
                throw AtelierError.imageWrite("无法创建客户交付页目录：\(error.localizedDescription)")
            }
        }
        throw AtelierError.imageWrite("无法找到未占用的客户交付页目录名")
    }

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

    // MARK: - History stack inspection and jumping (P1-D)

    var historyEntries: [UndoHistory.Entry] { undoHistory.entries }
    var currentHistoryIndex: Int { undoHistory.currentIndex }

    func jumpToHistory(at index: Int) {
        guard !batchRunning else { return }
        guard let snapshot = undoHistory.jumpTo(index: index) else { return }
        restoreUndoSnapshot(snapshot)
        let title = undoHistory.entries.indices.contains(index) ? undoHistory.entries[index].title : "历史记录"
        status = "已跳转至历史记录：\(title)。"
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
        let generation = previewGate.currentGeneration
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
                      self.previewGate.admits(generation), !self.batchRunning,
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
        // P1-6 liquify contract: non-neutral liquify must save as v11, explicitly
        // neutral liquify must stay on the legacy version.
        var activeLiquify = AdjustmentSettings()
        activeLiquify.liquify = FaceReshapeSettings(preset: .youthful)
        if PhotoEngine.requiredRecipeVersion(adjustments: activeLiquify, automatic: nil) != 11 {
            return "non-neutral liquify settings must require recipe v11"
        }
        var neutralLiquify = AdjustmentSettings()
        neutralLiquify.liquify = FaceReshapeSettings()
        if PhotoEngine.requiredRecipeVersion(adjustments: neutralLiquify, automatic: nil) != 9 {
            return "explicitly neutral liquify settings must not require v11"
        }
        var strokeOnlyLiquify = AdjustmentSettings()
        strokeOnlyLiquify.liquify = FaceReshapeSettings(strokes: [
            WarpStroke(mode: .push, points: [MaskPoint(x: 0.4, y: 0.5), MaskPoint(x: 0.6, y: 0.5)],
                       radius: 0.08, strength: 0.6)
        ])
        if PhotoEngine.requiredRecipeVersion(adjustments: strokeOnlyLiquify, automatic: nil) != 11 {
            return "manual liquify strokes must require recipe v11"
        }
        // P1-6 review F1: preset+slider edits must stay inside the validated
        // -1...1 explicit range (otherwise the whole preview is rejected).
        if Self.liquifyExplicitValue(forEffective: -1, presetValue: 0.55) != -1 {
            return "liquify slider must clamp preset-relative offsets (negative side)"
        }
        if Self.liquifyExplicitValue(forEffective: 1, presetValue: -0.30) != 1 {
            return "liquify slider must clamp preset-relative offsets (positive side)"
        }
        if abs(Self.liquifyExplicitValue(forEffective: 0.2, presetValue: 0.55) - (-0.35)) > 1e-12 {
            return "liquify slider offset arithmetic is wrong"
        }
        // P1-6 review F5: a neutral setting with protection disabled must stay
        // stored so the toggle cannot bounce back.
        if Self.collapsedLiquifySettings(FaceReshapeSettings()) != nil {
            return "neutral liquify with default protection must collapse to nil"
        }
        var unprotected = FaceReshapeSettings()
        unprotected.backgroundProtection = false
        if Self.collapsedLiquifySettings(unprotected) == nil {
            return "neutral liquify with protection disabled must be kept"
        }
        // P1-B certificate photo contract: active settings require v12, while an
        // explicitly disabled (neutral) field keeps the legacy version path.
        var activeCertificate = AdjustmentSettings()
        activeCertificate.certificatePhoto = CertificatePhotoSettings(enabled: true,
                                                                      size: .oneInch)
        if PhotoEngine.requiredRecipeVersion(adjustments: activeCertificate, automatic: nil) != 12 {
            return "active certificate photo settings must require recipe v12"
        }
        var neutralCertificate = AdjustmentSettings()
        neutralCertificate.certificatePhoto = CertificatePhotoSettings(enabled: false,
                                                                        size: .oneInch)
        if PhotoEngine.requiredRecipeVersion(adjustments: neutralCertificate, automatic: nil) != 9 {
            return "explicitly neutral certificate settings must not require v12"
        }
        var legacyCertificateRecipe = Recipe(adjustments: activeCertificate)
        legacyCertificateRecipe.version = 11
        if (try? legacyCertificateRecipe.validateVersion()) != nil {
            return "v11 recipe must reject an active certificate stage"
        }
        var v12CertificateRecipe = legacyCertificateRecipe
        v12CertificateRecipe.version = 12
        if (try? v12CertificateRecipe.validateVersion()) == nil {
            return "v12 recipe must accept an active certificate stage"
        }
        if (try? CertificatePhotoSettings().validated()) == nil {
            return "default certificate settings must validate"
        }
        // P1-B v12 manual repair contract: non-empty strokes require v12, while an
        // empty/absent stroke list keeps the legacy version and v11 recipes reject it.
        var activeRepair = AdjustmentSettings()
        activeRepair.repairBrush = RepairBrushSettings(strokes: [
            RepairStroke(mode: .heal, points: [MaskPoint(x: 0.5, y: 0.5)], radius: 0.05)
        ])
        if PhotoEngine.requiredRecipeVersion(adjustments: activeRepair, automatic: nil) != 12 {
            return "non-empty repair brush strokes must require recipe v12"
        }
        var neutralRepair = AdjustmentSettings()
        neutralRepair.repairBrush = RepairBrushSettings()
        if PhotoEngine.requiredRecipeVersion(adjustments: neutralRepair, automatic: nil) != 9 {
            return "empty repair brush settings must not require v12"
        }
        var legacyRepairRecipe = Recipe(adjustments: activeRepair)
        legacyRepairRecipe.version = 11
        if (try? legacyRepairRecipe.validateVersion()) != nil {
            return "v11 recipe must reject non-empty repair brush strokes"
        }
        var v12RepairRecipe = legacyRepairRecipe
        v12RepairRecipe.version = 12
        if (try? v12RepairRecipe.validateVersion()) == nil {
            return "v12 recipe must accept repair brush strokes"
        }
        if (try? RepairBrushSettings().validate()) == nil {
            return "default repair brush settings must validate"
        }
        // S4: the repair-brush radius UI range must stay aligned with the engine
        // 0.0005...0.5 bounds; the clamp also guards non-finite slider input.
        if Self.repairBrushRadiusRange != 0.0005...0.5 {
            return "repair brush radius UI range must match the engine bounds"
        }
        if Self.clampedRepairBrushRadius(0.0005) != 0.0005
            || Self.clampedRepairBrushRadius(0.5) != 0.5
            || Self.clampedRepairBrushRadius(0.9) != 0.5
            || Self.clampedRepairBrushRadius(-1) != 0.0005
            || Self.clampedRepairBrushRadius(.nan) != 0.06 {
            return "repair brush radius clamp must match the engine 0.0005...0.5 bounds"
        }
        return nil
    }

    // MARK: Liquify / face reshaping (P1)

    /// Current liquify settings; `nil` means the pre-v11 path (no warp).
    var liquifySettings: FaceReshapeSettings {
        adjustments.liquify ?? FaceReshapeSettings()
    }

    /// Face-shape preset/slider controls need a detected face; manual strokes do not.
    var canEditLiquifyFaceShape: Bool {
        !batchRunning && afterImage != nil && portraitFaceStatus.detectedFaceCount > 0
    }

    var canDrawLiquify: Bool {
        !batchRunning && afterImage != nil && selectedPhoto != nil
    }

    var liquifyStatusNote: String {
        if batchRunning { return "批处理进行中，液化编辑暂不可用。" }
        if afterImage == nil { return "打开照片后可编辑液化/美型。" }
        if portraitFaceStatus.isDetecting { return "正在检测人脸；脸型预设与滑杆需要人脸地标。" }
        if portraitFaceStatus.detectedFaceCount == 0 {
            return "未检测到可用人脸：脸型预设与滑杆不可用；手动液化笔迹仍可使用并会记录到配方。"
        }
        return "检测到 \(portraitFaceStatus.detectedFaceCount) 张人脸；脸型与滑杆只作用于第一张脸，后续蒙版基于变形后的图像。"
    }

    /// Applies one liquify edit. A fully neutral setting collapses back to `nil`
    /// so old recipes keep the exact pre-v11 decode/encode shape — except when the
    /// user explicitly turned background protection off, which is kept so the
    /// toggle cannot silently bounce back (it changes no pixels).
    func updateLiquifySettings(_ mutate: (inout FaceReshapeSettings) -> Void) {
        var settings = adjustments.liquify ?? FaceReshapeSettings()
        mutate(&settings)
        adjustments.liquify = Self.collapsedLiquifySettings(settings)
    }

    /// `nil` only for a neutral setting whose protection flag is at its default;
    /// a neutral setting with protection disabled is stored (no pixel effect) so
    /// the UI toggle state survives.
    static func collapsedLiquifySettings(_ settings: FaceReshapeSettings) -> FaceReshapeSettings? {
        if settings.isNeutral, settings.backgroundProtection { return nil }
        return settings
    }

    /// Maps an effective slider value to the stored explicit offset. The preset
    /// contribution is subtracted and the result clamped to `-1...1`, so
    /// preset+offset can never leave the validated range (otherwise
    /// `PhotoEngine.validate` would reject the whole preview).
    static func liquifyExplicitValue(forEffective effective: Double,
                                     presetValue: Double) -> Double {
        LiquifySliderMath.explicitOffset(forEffective: effective, presetValue: presetValue)
    }

    /// One slash of a liquify slider: stores the clamped explicit offset while the
    /// slider displays the effective (preset+offset) value.
    func setLiquifyParameter(_ effective: Double,
                             _ keyPath: WritableKeyPath<FaceReshapeParameters, Double>) {
        updateLiquifySettings { settings in
            settings.parameters[keyPath: keyPath] = Self.liquifyExplicitValue(
                forEffective: effective,
                presetValue: settings.preset.parameters[keyPath: keyPath])
        }
    }

    func applyLiquifyPreset(_ preset: FaceShapePreset) {
        guard preset == .classic || canEditLiquifyFaceShape else {
            status = "未检测到可用人脸，无法应用脸型预设；可先使用手动液化笔迹。"
            return
        }
        updateLiquifySettings { $0.preset = preset }
        status = preset == .classic
            ? "已恢复经典（中性）脸型。"
            : "已应用「\(preset.title)」脸型预设；请预览确认后再保存配方。"
    }

    func resetLiquify() {
        cancelLiquifyStroke()
        liquifyBrushActive = false
        adjustments.liquify = nil
        status = "已归零液化/美型设置（含手动笔迹）。"
    }

    func removeLastLiquifyStroke() {
        guard var settings = adjustments.liquify, !settings.strokes.isEmpty else { return }
        settings.strokes.removeLast()
        adjustments.liquify = Self.collapsedLiquifySettings(settings)
        status = "已删除最后一笔手动液化笔迹。"
    }

    func clearLiquifyStrokes() {
        guard var settings = adjustments.liquify, !settings.strokes.isEmpty else { return }
        settings.strokes.removeAll()
        adjustments.liquify = Self.collapsedLiquifySettings(settings)
        status = "已清除全部手动液化笔迹。"
    }

    func toggleLiquifyBrush() {
        guard canDrawLiquify else {
            status = "当前没有可编辑的照片，无法进入液化画笔。"
            return
        }
        if liquifyBrushActive {
            cancelLiquifyStroke()
            liquifyBrushActive = false
            status = "已退出手动液化画笔。"
        } else {
            cancelMaskInteraction()
            selectedMask = nil
            repairBrushActive = false
            cancelRepairStroke()
            liquifyBrushActive = true
            status = "手动液化画笔已开启（\(liquifyBrushMode.title)）；在画布拖动绘制，松开后应用预览，⌘Z 可撤销整笔。"
        }
    }

    /// Starts one manual liquify stroke. Points are accumulated in
    /// `liquifyDraftStroke` (no recipe mutation) so a drag produces exactly one
    /// preview and one undo step.
    func beginLiquifyStroke(at point: MaskPoint) {
        guard liquifyBrushActive, canDrawLiquify, !liquifyStrokeInProgress else { return }
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x),
              (0...1).contains(point.y) else { return }
        liquifyDraftStroke = WarpStroke(mode: liquifyBrushMode, points: [point],
                                        radius: liquifyBrushRadius,
                                        strength: liquifyBrushStrength)
        liquifyStrokeLastPoint = point
        liquifyStrokeUndoBase = currentUndoSnapshot
        liquifyStrokeInProgress = true
    }

    func extendLiquifyStroke(to point: MaskPoint) {
        guard liquifyStrokeInProgress, var stroke = liquifyDraftStroke else { return }
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x),
              (0...1).contains(point.y) else { return }
        if let last = liquifyStrokeLastPoint {
            let dx = point.x - last.x
            let dy = point.y - last.y
            guard (dx * dx + dy * dy).squareRoot() >= 0.003 else { return }
        }
        guard stroke.points.count < FaceReshapeEngine.maximumStrokePoints else { return }
        stroke.points.append(point)
        liquifyDraftStroke = stroke
        liquifyStrokeLastPoint = point
    }

    /// Commits the draft stroke as one undoable edit and requests one preview.
    func endLiquifyStroke() {
        guard liquifyStrokeInProgress else { return }
        liquifyStrokeInProgress = false
        defer {
            liquifyDraftStroke = nil
            liquifyStrokeLastPoint = nil
            liquifyStrokeUndoBase = nil
        }
        guard let stroke = liquifyDraftStroke, stroke.points.count >= 2 else { return }
        undoSuppressed = true
        var settings = adjustments.liquify ?? FaceReshapeSettings()
        settings.strokes.append(stroke)
        adjustments.liquify = settings.isNeutral ? nil : settings
        undoSuppressed = false
        if let base = liquifyStrokeUndoBase {
            let now = Date()
            let after = currentUndoSnapshot
            if after != base {
                seedUndoBaseline(base, at: now)
                undoHistory.push(after, key: "liquify.stroke", at: now)
                refreshUndoAvailability()
            }
        }
        status = "已添加 1 笔\(stroke.mode.title)液化笔迹（共 \(liquifySettings.strokes.count) 笔）；可 ⌘Z 撤销整笔。"
        // The adjustments change above triggers ContentView's single debounced
        // preview request; requesting an immediate one here would cancel it and
        // render twice for no benefit.
    }

    func cancelLiquifyStroke() {
        liquifyStrokeInProgress = false
        liquifyDraftStroke = nil
        liquifyStrokeLastPoint = nil
        liquifyStrokeUndoBase = nil
    }

    // MARK: Certificate photo / background replacement (P1-B)

    /// Current certificate-photo settings; the field is optional for v1–v11
    /// recipe pixel compatibility and `enabled == false` is the neutral state.
    var certificatePhotoSettings: CertificatePhotoSettings {
        adjustments.certificatePhoto ?? CertificatePhotoSettings()
    }

    var certificateIsActive: Bool {
        adjustments.certificatePhoto.map { !$0.isNeutral } ?? false
    }

    /// Applies one certificate-photo edit. The field is kept while the panel is
    /// used (even disabled, which is explicitly neutral) so the UI state and
    /// background/shadow choices survive; reset removes it entirely.
    func updateCertificatePhoto(_ mutate: (inout CertificatePhotoSettings) -> Void) {
        var settings = adjustments.certificatePhoto ?? CertificatePhotoSettings()
        mutate(&settings)
        adjustments.certificatePhoto = settings
    }

    func setCertificatePhotoEnabled(_ enabled: Bool) {
        updateCertificatePhoto { settings in
            settings.enabled = enabled
            if enabled, settings.size == nil { settings.size = .oneInch }
        }
        status = enabled
            ? "证件照/换背景已启用：预览会逐张检测人物；无人物时显式跳过并说明。"
            : "证件照/换背景已关闭（显式中性）：不改像素，旧配方路径保持不变。"
    }

    func resetCertificatePhoto() {
        adjustments.certificatePhoto = nil
        status = "已移除证件照/换背景设置（配方回到 v1–v11 兼容路径）。"
    }

    /// Imports a local background image via the standard open panel. Only local
    /// image files are stored; nothing is uploaded or fetched from the network.
    func importCertificateBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "选择本地背景图片"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.prompt = "使用"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateCertificatePhoto { settings in
            settings.backgroundSource = .image
            settings.backgroundImagePath = url.path
            settings.enabled = true
            if settings.size == nil { settings.size = .oneInch }
        }
        status = "已选择本地背景图片：\(url.lastPathComponent)；预览按比例裁切填满画面。"
    }

    // MARK: Manual repair / clone brush (P1-B)

    /// UI/slider radius range, aligned with `RepairStroke`/`RepairBrushEngine`
    /// bounds (fraction of the shorter image edge). One source of truth for the
    /// panel slider, its binding clamp and the committed draft stroke.
    static let repairBrushRadiusRange: ClosedRange<Double> = 0.0005...0.5
    static let repairBrushDefaultRadius: Double = 0.06

    /// Clamps a slider value into the engine-accepted radius range; non-finite
    /// input (SwiftUI can hand us NaN while typing) falls back to the default.
    static func clampedRepairBrushRadius(_ value: Double) -> Double {
        guard value.isFinite else { return repairBrushDefaultRadius }
        return min(repairBrushRadiusRange.upperBound,
                   max(repairBrushRadiusRange.lowerBound, value))
    }

    /// Current manual repair-brush settings; `nil` means the pre-v12 path.
    var repairBrushSettings: RepairBrushSettings {
        adjustments.repairBrush ?? RepairBrushSettings()
    }

    var repairBrushIsActive: Bool {
        adjustments.repairBrush.map { !$0.isNeutral } ?? false
    }

    var canDrawRepairBrush: Bool {
        !batchRunning && afterImage != nil && selectedPhoto != nil
    }

    var repairStatusNote: String {
        if batchRunning { return "批处理进行中，修复画笔暂不可用。" }
        if afterImage == nil { return "打开照片后可手动修补/仿制；画笔只改预览与导出像素，不改原图。" }
        let strokes = repairBrushSettings.strokes
        guard !strokes.isEmpty else {
            return "尚未添加修复笔迹：heal 为启发式局部修补（非生成式），clone 原样复制来源像素。"
        }
        let heal = strokes.filter { $0.mode == .heal }.count
        return "共 \(strokes.count) 笔（修补 \(heal) · 仿制 \(strokes.count - heal)）；每笔可整体撤销。"
    }

    /// Applies one repair-brush edit. An empty stroke list collapses back to `nil`
    /// so recipes without manual repair keep the exact pre-v12 payload.
    func updateRepairBrushSettings(_ mutate: (inout RepairBrushSettings) -> Void) {
        var settings = adjustments.repairBrush ?? RepairBrushSettings()
        mutate(&settings)
        adjustments.repairBrush = settings.isNeutral ? nil : settings
    }

    func toggleRepairBrush() {
        guard canDrawRepairBrush || repairBrushActive else {
            status = "当前没有可编辑的照片，无法进入修复画笔。"
            return
        }
        if repairBrushActive {
            cancelRepairStroke()
            repairBrushActive = false
            repairSamplingCloneSource = false
            status = "已退出修复画笔。"
        } else {
            cancelMaskInteraction()
            selectedMask = nil
            cancelLiquifyStroke()
            liquifyBrushActive = false
            repairBrushActive = true
            repairSamplingCloneSource = repairBrushMode == .clone && repairCloneSource == nil
            status = repairBrushMode == .heal
                ? "修复画笔已开启（启发式修补，非生成式）：在画布拖动涂抹，松开后应用 1 笔，⌘Z 可撤销整笔。"
                : "仿制画笔已开启：先设置来源点，再拖动涂抹；松开后应用 1 笔，⌘Z 可撤销整笔。"
        }
    }

    func setRepairBrushMode(_ mode: RepairBrushMode) {
        repairBrushMode = mode
        repairSamplingCloneSource = mode == .clone && repairCloneSource == nil
        status = mode == .heal
            ? "修复画笔：拖动涂抹需要修补的区域。"
            : "仿制画笔：点击「设置仿制来源」后在画布选择来源点，再拖动涂抹。"
    }

    func beginRepairSamplingCloneSource() {
        guard canDrawRepairBrush else {
            status = "当前没有可编辑的照片，无法设置仿制来源。"
            return
        }
        if liquifyBrushActive {
            cancelLiquifyStroke()
            liquifyBrushActive = false
        }
        cancelMaskInteraction()
        repairBrushActive = true
        repairSamplingCloneSource = true
        status = "点击画布选择仿制来源点（之后的笔迹会从该点偏移复制）；Esc 可退出画笔。"
    }

    func sampleRepairCloneSource(at point: MaskPoint) {
        guard repairSamplingCloneSource else { return }
        guard point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else { return }
        let formattedX = String(format: "%.2f", point.x)
        let formattedY = String(format: "%.2f", point.y)
        repairCloneSource = point
        repairSamplingCloneSource = false
        status = "仿制来源已设为 (\(formattedX), \(formattedY))；拖动涂抹即可复制。"
    }

    func beginRepairStroke(at point: MaskPoint) {
        guard repairBrushActive, canDrawRepairBrush, !repairStrokeInProgress else { return }
        if repairSamplingCloneSource {
            sampleRepairCloneSource(at: point)
            return
        }
        guard point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else { return }
        if repairBrushMode == .clone, repairCloneSource == nil {
            status = "仿制画笔需要先设置来源点：点击「设置仿制来源」后在画布选择。"
            return
        }
        var stroke = RepairStroke(mode: repairBrushMode,
                                  points: [point],
                                  radius: Self.clampedRepairBrushRadius(repairBrushRadius),
                                  feather: min(1, max(0, repairBrushFeather)),
                                  strength: min(1, max(0, repairBrushStrength)))
        if repairBrushMode == .clone, let source = repairCloneSource {
            stroke.cloneOffset = MaskPoint(x: source.x - point.x, y: source.y - point.y)
        }
        repairDraftStroke = stroke
        repairStrokeLastPoint = point
        repairStrokeUndoBase = currentUndoSnapshot
        repairStrokeInProgress = true
    }

    func extendRepairStroke(to point: MaskPoint) {
        guard repairStrokeInProgress, var stroke = repairDraftStroke else { return }
        guard point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else { return }
        if let last = repairStrokeLastPoint {
            let dx = point.x - last.x
            let dy = point.y - last.y
            guard (dx * dx + dy * dy).squareRoot() >= 0.002 else { return }
        }
        guard stroke.points.count < RepairBrushEngine.maximumPointsPerStroke else { return }
        stroke.points.append(point)
        repairDraftStroke = stroke
        repairStrokeLastPoint = point
    }

    /// Commits the draft stroke as one undoable edit and lets ContentView's single
    /// debounced preview request render it. A single click is a valid one-point heal.
    func endRepairStroke() {
        guard repairStrokeInProgress else { return }
        repairStrokeInProgress = false
        defer {
            repairDraftStroke = nil
            repairStrokeLastPoint = nil
            repairStrokeUndoBase = nil
        }
        guard let stroke = repairDraftStroke, !stroke.points.isEmpty else { return }
        undoSuppressed = true
        var settings = adjustments.repairBrush ?? RepairBrushSettings()
        settings.strokes.append(stroke)
        adjustments.repairBrush = settings.isNeutral ? nil : settings
        undoSuppressed = false
        if let base = repairStrokeUndoBase {
            let now = Date()
            let after = currentUndoSnapshot
            if after != base {
                seedUndoBaseline(base, at: now)
                undoHistory.push(after, key: "repair.stroke", at: now)
                refreshUndoAvailability()
            }
        }
        let modeTitle = stroke.mode == .heal ? "修补" : "仿制"
        status = "已添加 1 笔\(modeTitle)笔迹（共 \(repairBrushSettings.strokes.count) 笔）；⌘Z 可撤销整笔。"
    }

    func cancelRepairStroke() {
        repairStrokeInProgress = false
        repairDraftStroke = nil
        repairStrokeLastPoint = nil
        repairStrokeUndoBase = nil
        repairSamplingCloneSource = false
    }

    func removeLastRepairStroke() {
        guard var settings = adjustments.repairBrush, !settings.strokes.isEmpty else { return }
        settings.strokes.removeLast()
        adjustments.repairBrush = settings.isNeutral ? nil : settings
        status = settings.isNeutral
            ? "已删除最后一笔修复笔迹；配方回到 v1–v11 兼容路径。"
            : "已删除最后一笔修复笔迹。"
    }

    func clearRepairStrokes() {
        guard let settings = adjustments.repairBrush, !settings.strokes.isEmpty else { return }
        let base = currentUndoSnapshot
        undoSuppressed = true
        adjustments.repairBrush = nil
        undoSuppressed = false
        let now = Date()
        let after = currentUndoSnapshot
        if after != base {
            seedUndoBaseline(base, at: now)
            undoHistory.push(after, key: "repair.clear", at: now)
            refreshUndoAvailability()
        }
        status = "已清除全部修复笔迹（配方回到 v1–v11 兼容路径）。"
    }

    // MARK: Make-up (P1-C)

    var makeupSettings: MakeupSettings {
        adjustments.makeup ?? MakeupSettings()
    }

    var makeupIsActive: Bool {
        adjustments.makeup.map { !$0.isNeutral } ?? false
    }

    /// Make-up needs usable face landmarks; controls stay disabled until the
    /// background portrait detection found at least one face.
    var canEditMakeup: Bool {
        !batchRunning && afterImage != nil && portraitFaceStatus.detectedFaceCount > 0
    }

    var makeupStatusNote: String {
        if batchRunning { return "批处理进行中，妆容编辑暂不可用。" }
        if afterImage == nil { return "打开照片后可编辑妆容。" }
        if portraitFaceStatus.isDetecting { return "正在检测人脸；妆容需要人脸地标。" }
        if portraitFaceStatus.detectedFaceCount == 0 {
            return "未检测到可用人脸：妆容已禁用（不会静默改图）。"
        }
        return "检测到 \(portraitFaceStatus.detectedFaceCount) 张人脸；妆容只作用于检测到的人脸区域，建议逐张预览。"
    }

    /// Applies one make-up edit. Only an all-default setting collapses back to
    /// `nil`: a neutral setting whose colour/radius was edited stays stored so the
    /// ColorPicker selection is not lost before an intensity is raised (the field is
    /// still neutral: no pixels change and old recipe versions stay legal).
    func updateMakeup(_ mutate: (inout MakeupSettings) -> Void) {
        var settings = adjustments.makeup ?? MakeupSettings()
        mutate(&settings)
        adjustments.makeup = MakeupSettings.collapsed(settings)
    }

    func resetMakeup() {
        adjustments.makeup = nil
        status = "已归零妆容设置。"
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
        lastReferenceColorURL = url
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
        lastReferenceColorURL = nil
        referenceColorGeneration = UUID()
        referenceColorBusy = false
        adjustments.referenceColor = nil
        referenceColorThumbnail = nil
        referenceColorThumbnailProfile = nil
        referenceColorSourceName = nil
        status = "已清除参考图追色。"
        requestPreview(immediate: true)
    }

    // MARK: - Pinned Reference across folders (P1-D)

    func pinCurrentReference() {
        guard let url = lastReferenceColorURL else { return }
        if let cg = try? PhotoLoader.thumbnail(url: url, maxDimension: 1024) {
            try? referencePinStorage.pinReference(image: cg, name: referenceColorSourceName ?? url.lastPathComponent)
            isReferencePinned = referencePinStorage.hasPinnedReference
            status = "已将当前参考图「\(referenceColorSourceName ?? url.lastPathComponent)」钉住到项目库，跨文件夹均可复用。"
        }
    }

    func unpinReference() {
        referencePinStorage.clearPinnedReference()
        isReferencePinned = referencePinStorage.hasPinnedReference
        status = "已取消钉住参考图。"
    }

    func applyPinnedReference() {
        guard !batchRunning, let pinned = referencePinStorage.loadPinnedReference() else { return }
        let ciImage = CIImage(cgImage: pinned.image)
        if let profile = try? ReferenceColorMatcher.profile(reference: ciImage) {
            let current = adjustments.referenceColor
            adjustments.referenceColor = PhotoEngine.mergedReferenceColorSettings(
                measured: profile, current: current)
            referenceColorThumbnail = NSImage(cgImage: pinned.image, size: .zero)
            referenceColorThumbnailProfile = profile
            referenceColorSourceName = "📌 " + pinned.name
            status = "已应用钉住参考图：「\(pinned.name)」"
            requestPreview(immediate: true)
        }
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

    // MARK: Color tools (P1)

    /// Applies one P1 color-tools edit. The value stays non-nil while the panel is
    /// being edited (a neutral tool can be mid-edit, e.g. a hue chosen before its
    /// saturation); the engine skips neutral values so pixels and the recipe
    /// version gate are unaffected. The explicit reset action clears it to `nil`.
    func updateColorTools(_ mutate: (inout ColorToolsSettings) -> Void) {
        var tools = adjustments.colorTools ?? ColorToolsSettings()
        mutate(&tools)
        adjustments.colorTools = tools
    }

    /// Applies one lens-effects edit (vignette / chromatic aberration). Kept
    /// non-nil for the same mid-edit reason as `updateColorTools`.
    func updateLensEffects(_ mutate: (inout LensEffectsSettings) -> Void) {
        var effects = adjustments.lensEffects ?? LensEffectsSettings()
        mutate(&effects)
        adjustments.lensEffects = effects
    }

    /// True when any P1 color tool can currently change pixels.
    var hasActiveColorTools: Bool {
        !(adjustments.colorTools?.isNeutral ?? true) || !(adjustments.lensEffects?.isNeutral ?? true)
    }

    func resetColorTools() {
        adjustments.colorTools = nil
        adjustments.lensEffects = nil
        status = "已归零曲线、HSL、颜色分级与镜头效果。"
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

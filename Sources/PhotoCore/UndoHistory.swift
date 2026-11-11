import Foundation

/// One restorable editing state: global adjustments, the selected look and the
/// automatic-analysis baseline they belong to.
///
/// Snapshots carry parameters only — never pixels or photographs — so the whole
/// history stays bounded and cheap to restore. Ephemeral state (mask coverage,
/// preview images, selected mask/photo) is deliberately excluded.
public struct UndoSnapshot: Codable, Equatable {
    public var adjustments: AdjustmentSettings
    /// LUT option id: "none", a built-in style id, or a custom LUT file path.
    public var lutID: String
    /// The LUT's declared input/output colour space. Stored beside `lutID`
    /// because switching a look can change it without touching any slider.
    public var lutColorSpace: LUTColorSpace
    /// Automatic proposal baseline. Restoring it keeps the analysis semantics
    /// stable after undo/redo instead of leaving a proposal without its baseline.
    public var automaticRecipe: AutomaticBatchRecipe?
    public var sceneIntent: PhotoSceneIntent

    public init(adjustments: AdjustmentSettings = .init(), lutID: String = "none",
                lutColorSpace: LUTColorSpace = .sRGB,
                automaticRecipe: AutomaticBatchRecipe? = nil,
                sceneIntent: PhotoSceneIntent = .automatic) {
        self.adjustments = adjustments
        self.lutID = lutID
        self.lutColorSpace = lutColorSpace
        self.automaticRecipe = automaticRecipe
        self.sceneIntent = sceneIntent
    }
}

public extension AdjustmentSettings {
    /// Names the first field that differs from `other`, for coalescing rapid
    /// edits of one control into a single undo step.
    ///
    /// Returns nil when the two settings are equal. Unknown future fields still
    /// produce one undo step through the "adjustments" fallback, so adding an
    /// option never silently drops history entries.
    func undoEditKey(comparedTo other: AdjustmentSettings) -> String? {
        guard self != other else { return nil }
        if autoExposure != other.autoExposure { return "basic.autoExposure" }
        if autoWhiteBalance != other.autoWhiteBalance { return "basic.autoWhiteBalance" }
        if exposureEV != other.exposureEV { return "basic.exposureEV" }
        if temperature != other.temperature { return "basic.temperature" }
        if tint != other.tint { return "basic.tint" }
        if contrast != other.contrast { return "basic.contrast" }
        if saturation != other.saturation { return "basic.saturation" }
        if highlights != other.highlights { return "basic.highlights" }
        if shadows != other.shadows { return "basic.shadows" }
        if tonalCurve != other.tonalCurve { return "curve.tonalCurve" }
        if lensCorrection != other.lensCorrection { return "lens.correction" }
        if lensProfileID != other.lensProfileID { return "lens.profile" }
        if lensCropFactor != other.lensCropFactor { return "lens.cropFactor" }
        if lensFocalLength != other.lensFocalLength { return "lens.focalLength" }
        if autoStraighten != other.autoStraighten { return "geometry.autoStraighten" }
        if rotationDegrees != other.rotationDegrees { return "geometry.rotation" }
        if verticalPerspective != other.verticalPerspective { return "geometry.verticalPerspective" }
        if horizontalPerspective != other.horizontalPerspective { return "geometry.horizontalPerspective" }
        if lutIntensity != other.lutIntensity { return "look.lutIntensity" }
        if lutColorSpace != other.lutColorSpace { return "look.lutColorSpace" }
        if preserveLuminance != other.preserveLuminance { return "look.preserveLuminance" }
        if protectSkin != other.protectSkin { return "look.protectSkin" }
        if protectNeutrals != other.protectNeutrals { return "look.protectNeutrals" }
        if gamutCompression != other.gamutCompression { return "look.gamutCompression" }
        if colorHarmony != other.colorHarmony { return "look.colorHarmony" }
        if creativeEffects != other.creativeEffects { return "look.creativeEffects" }
        if adaptiveLUT != other.adaptiveLUT { return "look.adaptiveLUT" }
        if masks != other.masks { return maskUndoEditKey(comparedTo: other.masks) }
        return "adjustments"
    }

    /// Merges rapid edits of one mask into a single step while keeping mask
    /// creation/deletion separate from parameter drags.
    private func maskUndoEditKey(comparedTo other: [LocalMask]) -> String {
        guard masks.count == other.count else { return "mask.structure" }
        for (before, current) in zip(other, masks) where before != current {
            return "mask.\(current.id.uuidString)"
        }
        return "mask.structure"
    }
}

/// Bounded undo/redo stack of `UndoSnapshot` values.
///
/// Editing operations call `push` with the state *after* the edit. Edits that
/// share one key and arrive within `mergeInterval` of each other (for example a
/// single slider drag) collapse into one entry, so one ⌘Z undoes the whole drag.
///
/// The stack is a value type and must be used from one thread (the main thread
/// in the app); it performs no locking.
public struct UndoHistory {
    public struct Entry: Codable, Equatable {
        public var snapshot: UndoSnapshot
        /// Coalescing key of the edit that produced this entry.
        public var key: String
        public var timestamp: Date
        public var title: String

        public init(snapshot: UndoSnapshot, key: String, timestamp: Date = Date(), title: String? = nil) {
            self.snapshot = snapshot
            self.key = key
            self.timestamp = timestamp
            self.title = title ?? UndoHistory.humanReadableTitle(for: key)
        }
    }

    /// Key used for the pre-edit baseline state, so the first ⌘Z returns to it.
    public static let initialKey = "__initial__"

    public static func humanReadableTitle(for key: String) -> String {
        if key == initialKey { return "原始状态" }
        if key.starts(with: "basic.exposure") { return "调整曝光" }
        if key.starts(with: "basic.temp") || key.starts(with: "basic.tint") { return "调整白平衡" }
        if key.starts(with: "basic.contrast") { return "调整对比度" }
        if key.starts(with: "basic.saturation") { return "调整饱和度" }
        if key.starts(with: "basic.highlights") || key.starts(with: "basic.shadows") { return "调整高光/阴影" }
        if key.starts(with: "curve.") { return "调整色调曲线" }
        if key.starts(with: "look.lut") { return "切换色彩风格" }
        if key.starts(with: "look.") { return "风格质感微调" }
        if key.starts(with: "geometry.") { return "几何与透视校正" }
        if key.starts(with: "lens.") { return "镜头畸变校正" }
        if key.starts(with: "mask.") { return "局部蒙版调节" }
        if key.starts(with: "portrait.") { return "人像精修/美型" }
        if key.starts(with: "makeup.") { return "AI 妆容" }
        if key.starts(with: "colorTools.") { return "高级调色" }
        if key.starts(with: "repair.") { return "修复画笔" }
        if key.starts(with: "idPhoto.") { return "证件照与背景" }
        if key.starts(with: "referenceColor") { return "AI 追色" }
        return "调整参数"
    }

    public let capacity: Int
    public let mergeInterval: TimeInterval
    public private(set) var entries: [Entry] = []
    public private(set) var currentIndex: Int = -1
    private var lastPushTime: Date?
    private let clock: () -> Date

    public init(capacity: Int = 50, mergeInterval: TimeInterval = 0.5,
                clock: @escaping () -> Date = { Date() }) {
        self.capacity = max(1, capacity)
        self.mergeInterval = max(0, mergeInterval)
        self.clock = clock
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var canUndo: Bool { currentIndex > 0 }
    public var canRedo: Bool { currentIndex >= 0 && currentIndex < entries.count - 1 }
    public var current: UndoSnapshot? { snapshot(at: currentIndex) }
    public var currentKey: String? {
        entries.indices.contains(currentIndex) ? entries[currentIndex].key : nil
    }

    /// Records the state after one edit. Returns false for a no-op edit (the
    /// snapshot equals the current one), which keeps duplicates out of history.
    @discardableResult
    public mutating func push(_ snapshot: UndoSnapshot, key: String, at date: Date? = nil) -> Bool {
        let moment = date ?? clock()
        if let current, current == snapshot { return false }
        // A new edit always drops the redo branch.
        if currentIndex < entries.count - 1 {
            entries.removeSubrange((currentIndex + 1)...)
            lastPushTime = nil
        }
        if !entries.isEmpty, entries[entries.count - 1].key == key,
           let lastTime = lastPushTime, moment.timeIntervalSince(lastTime) <= mergeInterval {
            entries[entries.count - 1].snapshot = snapshot
            entries[entries.count - 1].timestamp = moment
            lastPushTime = moment
            return true
        }
        entries.append(Entry(snapshot: snapshot, key: key, timestamp: moment))
        lastPushTime = moment
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        currentIndex = entries.count - 1
        return true
    }

    /// Steps back one entry and returns the state to restore, or nil at the
    /// oldest entry.
    @discardableResult
    public mutating func undo() -> UndoSnapshot? {
        guard canUndo else { return nil }
        currentIndex -= 1
        // Never coalesce a new edit into an entry that existed before undo/redo.
        lastPushTime = nil
        return snapshot(at: currentIndex)
    }

    /// Steps forward one entry and returns the state to restore, or nil when
    /// there is no redo branch.
    @discardableResult
    public mutating func redo() -> UndoSnapshot? {
        guard canRedo else { return nil }
        currentIndex += 1
        lastPushTime = nil
        return snapshot(at: currentIndex)
    }

    /// Directly jumps to a specific snapshot in the history stack.
    @discardableResult
    public mutating func jumpTo(index: Int) -> UndoSnapshot? {
        guard entries.indices.contains(index) else { return nil }
        currentIndex = index
        lastPushTime = nil
        return snapshot(at: currentIndex)
    }

    /// Forgets every entry, for example when a different folder is opened.
    public mutating func reset() {
        entries.removeAll()
        currentIndex = -1
        lastPushTime = nil
    }

    private func snapshot(at index: Int) -> UndoSnapshot? {
        guard entries.indices.contains(index) else { return nil }
        return entries[index].snapshot
    }
}

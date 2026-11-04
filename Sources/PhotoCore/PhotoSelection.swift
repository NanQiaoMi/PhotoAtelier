import Foundation

/// One input that could not become a photo, with a human-readable reason.
/// Import never drops an input silently: every rejected URL produces one issue.
public struct PhotoSelectionIssue: Equatable {
    public let url: URL
    public let message: String

    public init(url: URL, message: String) {
        self.url = url
        self.message = message
    }
}

/// Outcome of resolving explicitly opened/dropped files into a photo library.
public struct PhotoSelectionResult: Equatable {
    /// Common ancestor directory of the accepted files; nil when nothing was accepted.
    public let root: URL?
    /// Accepted files in stable path order, with `relativePath` computed under `root`.
    public let items: [PhotoItem]
    /// One entry per rejected unique input, in the original input order.
    public let issues: [PhotoSelectionIssue]

    public init(root: URL? = nil, items: [PhotoItem] = [], issues: [PhotoSelectionIssue] = []) {
        self.root = root
        self.items = items
        self.issues = issues
    }
}

/// Pure selection/merge helpers shared by the single-file, multi-select and
/// drag-and-drop import paths. Nothing here decodes pixels, touches AppKit or
/// mutates state, so the import rules are unit-testable.
public enum PhotoSelection {
    /// Resolves explicitly selected local files (not folders) into a photo batch.
    ///
    /// Rules:
    /// - Local regular files only; folders, symlinks and missing paths are reported.
    /// - The extension must be a candidate format (`PhotoLoader.isSupportedCandidate`);
    ///   a candidate still fails later in `PhotoLoader.load` if it does not decode.
    /// - Duplicate inputs are collapsed by standardized path before validation.
    /// - `root` is the common ancestor directory; items are sorted by path.
    public static func resolve(fileURLs: [URL]) -> PhotoSelectionResult {
        var accepted: [URL] = []
        var issues: [PhotoSelectionIssue] = []
        var seenInputs = Set<String>()

        for rawURL in fileURLs {
            guard rawURL.isFileURL else {
                issues.append(PhotoSelectionIssue(url: rawURL, message: "只支持本地照片文件"))
                continue
            }
            let url = rawURL.standardizedFileURL
            guard seenInputs.insert(url.path).inserted else { continue }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    issues.append(PhotoSelectionIssue(url: url, message: "不跟随符号链接，请选择该链接指向的真实照片"))
                    continue
                }
                if values.isDirectory == true {
                    issues.append(PhotoSelectionIssue(url: url, message: "这是文件夹，请按文件夹导入"))
                    continue
                }
                guard values.isRegularFile == true else {
                    issues.append(PhotoSelectionIssue(url: url, message: "不是普通文件"))
                    continue
                }
            } catch {
                issues.append(PhotoSelectionIssue(url: url, message: "无法读取文件属性：\(error.localizedDescription)"))
                continue
            }
            guard PhotoLoader.isSupportedCandidate(url) else {
                let fileExtension = url.pathExtension
                issues.append(PhotoSelectionIssue(
                    url: url,
                    message: fileExtension.isEmpty ? "没有扩展名，无法确认照片格式" : "不支持的照片格式：\(fileExtension)"
                ))
                continue
            }
            accepted.append(url)
        }

        let root = commonRoot(of: accepted.map { $0.deletingLastPathComponent() })
        let resolvedItems = root.map { PhotoSelection.items(fileURLs: accepted, root: $0) } ?? []
        return PhotoSelectionResult(root: root, items: resolvedItems, issues: issues)
    }

    /// Common ancestor directory of the given directories (each entry is treated
    /// as an absolute directory, not as a file). Returns "/" when only the volume
    /// root is shared, and nil for an empty input.
    public static func commonRoot(of directories: [URL]) -> URL? {
        var shared: [String]?
        for directory in directories {
            let components = directory.standardizedFileURL.pathComponents
            guard var current = shared else {
                shared = components
                continue
            }
            var prefix: [String] = []
            for index in 0..<min(current.count, components.count) {
                if current[index] != components[index] { break }
                prefix.append(current[index])
            }
            current = prefix
            shared = current
        }
        guard let components = shared else { return nil }
        if components.isEmpty || components == ["/"] { return URL(fileURLWithPath: "/", isDirectory: true) }
        return URL(fileURLWithPath: NSString.path(withComponents: components), isDirectory: true)
    }

    /// Builds deterministic `PhotoItem`s for absolute file URLs below `root`,
    /// dropping URLs outside the root and duplicate paths. Re-basing a folder scan
    /// onto a wider common root reuses this so relative paths stay consistent.
    public static func items(fileURLs: [URL], root: URL) -> [PhotoItem] {
        let standardizedRoot = root.standardizedFileURL
        var seen = Set<String>()
        var items: [PhotoItem] = []
        for rawURL in fileURLs {
            let url = rawURL.standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            guard let relative = PhotoLoader.relativePath(of: url, under: standardizedRoot) else { continue }
            items.append(PhotoItem(url: url, relativePath: relative))
        }
        return items.sorted(by: isOrderedBefore)
    }

    /// True when importing at `incomingRoot` should extend the library that is
    /// already open at `currentRoot` instead of replacing it. Only the open folder
    /// and its descendants count as a second import; a sibling/parent folder is a
    /// new library. Path-prefix checks append "/" so "/a/b" never matches "/a/bc".
    public static func shouldAppend(incomingRoot: URL, currentRoot: URL?) -> Bool {
        guard let currentRoot else { return false }
        let current = currentRoot.standardizedFileURL.path
        let incoming = incomingRoot.standardizedFileURL.path
        if incoming == current { return true }
        let prefix = current.hasSuffix("/") ? current : current + "/"
        return incoming.hasPrefix(prefix)
    }

    /// Merges a second import into the open library: de-duplicates by photo id
    /// (`PhotoItem.id` is the standardized path) and keeps a stable path order.
    public static func merge(existing: [PhotoItem], incoming: [PhotoItem]) -> [PhotoItem] {
        var seen = Set(existing.map(\.id))
        var combined = existing
        for item in incoming where seen.insert(item.id).inserted {
            combined.append(item)
        }
        return combined.sorted(by: isOrderedBefore)
    }

    // MARK: - Culling session helpers (P1-C C4)

    /// Ratings are session state in a fixed `0...5` range.
    public static let ratingRange = 0...5

    /// Clamps a rating into `0...5`.
    public static func clampedRating(_ rating: Int) -> Int {
        min(5, max(0, rating))
    }

    /// Rating after one keyboard/slider step (used by the UI shortcuts).
    public static func steppedRating(_ rating: Int, delta: Int) -> Int {
        clampedRating(rating + delta)
    }

    /// Auto-cull suggestion derived from one heuristic quality report.
    ///
    /// Mapping (documented, advisory only): `keep` → 5 stars, `review` → 3 stars,
    /// `reject` → 1 star plus the session rejection mark. Manual ratings are never
    /// overwritten by `applyingAutoCull`.
    public struct AutoCullAssignment: Codable, Equatable {
        public var rating: Int
        public var isRejected: Bool
        public init(rating: Int, isRejected: Bool) {
            self.rating = min(5, max(0, rating))
            self.isRejected = isRejected
        }
    }

    public static func autoCullAssignment(for report: QualityReport) -> AutoCullAssignment {
        switch report.recommendation {
        case .keep: return AutoCullAssignment(rating: 5, isRejected: false)
        case .review: return AutoCullAssignment(rating: 3, isRejected: false)
        case .reject: return AutoCullAssignment(rating: 1, isRejected: true)
        }
    }

    /// Applies auto-cull reports to matching photos without overwriting manual
    /// session edits (rating > 0 or an explicit rejection mark). Returns the number
    /// of photos that received a report.
    @discardableResult
    public static func applyingAutoCull(reports: [String: QualityReport],
                                        to items: inout [PhotoItem]) -> Int {
        var applied = 0
        for index in items.indices {
            guard let report = reports[items[index].id] else { continue }
            items[index].qualityReport = report
            if items[index].rating == 0 && !items[index].isRejected {
                let assignment = autoCullAssignment(for: report)
                items[index].rating = assignment.rating
                items[index].isRejected = assignment.isRejected
            }
            applied += 1
        }
        return applied
    }

    /// Sidebar filter over the session culling state.
    public static func filtered(_ items: [PhotoItem], filter: PhotoCullFilter) -> [PhotoItem] {
        items.filter(filter.matches)
    }

    /// True when the photo should be exported under the session options.
    public static func shouldExport(_ item: PhotoItem,
                                    options: ExportSelectionOptions) -> Bool {
        skipReason(for: item, options: options) == nil
    }

    /// Human-readable reason when the photo will be skipped, nil when exported.
    public static func skipReason(for item: PhotoItem,
                                  options: ExportSelectionOptions) -> String? {
        if options.skipRejectedPhotos && item.isRejected {
            return "已标记为废片，按导出设置跳过。"
        }
        if options.skipUnselectedPhotos && item.rating == 0 && !item.isRejected {
            return "尚未评级（未选），按导出设置跳过。"
        }
        return nil
    }

    private static func isOrderedBefore(_ lhs: PhotoItem, _ rhs: PhotoItem) -> Bool {
        switch lhs.relativePath.localizedStandardCompare(rhs.relativePath) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.url.path < rhs.url.path
        }
    }
}

/// Sidebar filter over the session culling state (ratings/rejections are not
/// persisted and are not recipe data).
public enum PhotoCullFilter: String, Codable, CaseIterable, Identifiable, Equatable {
    case all
    case recommended
    case kept
    case rejected

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "全部"
        case .recommended: return "推荐"
        case .kept: return "保留"
        case .rejected: return "废片"
        }
    }

    /// Filter predicate. `recommended` = heuristic keep recommendation or a
    /// manual 4–5 star rating; `kept` = not marked as waste; `rejected` = waste.
    public func matches(_ item: PhotoItem) -> Bool {
        switch self {
        case .all:
            return true
        case .recommended:
            return item.qualityRecommendation == .keep || item.rating >= 4
        case .kept:
            return !item.isRejected
        case .rejected:
            return item.isRejected
        }
    }
}

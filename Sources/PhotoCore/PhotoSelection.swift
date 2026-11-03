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

    private static func isOrderedBefore(_ lhs: PhotoItem, _ rhs: PhotoItem) -> Bool {
        switch lhs.relativePath.localizedStandardCompare(rhs.relativePath) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.url.path < rhs.url.path
        }
    }
}

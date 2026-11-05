import Foundation
import CryptoKit

/// Persistent record of user attributes for a single photo in a folder catalog.
/// This data is stored strictly in Application Support and NEVER modifies the original photo file.
public struct PhotoAttributeRecord: Codable, Equatable {
    public var relativePath: String
    public var fileSize: Int64
    public var modificationTimestamp: TimeInterval
    public var rating: Int
    public var isRejected: Bool
    public var qualityReport: QualityReport?
    public var updatedAt: Date

    public init(
        relativePath: String,
        fileSize: Int64,
        modificationTimestamp: TimeInterval,
        rating: Int = 0,
        isRejected: Bool = false,
        qualityReport: QualityReport? = nil,
        updatedAt: Date = Date()
    ) {
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.modificationTimestamp = modificationTimestamp
        self.rating = max(0, min(5, rating))
        self.isRejected = isRejected
        self.qualityReport = qualityReport
        self.updatedAt = updatedAt
    }

    /// Checks if the cached record matches the current physical file attributes.
    public func matches(fileSize: Int64, modificationTimestamp: TimeInterval) -> Bool {
        return self.fileSize == fileSize && abs(self.modificationTimestamp - modificationTimestamp) < 0.001
    }
}

/// A serialized catalog representing all cached attributes for an imported folder.
public struct FolderCatalog: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var rootPath: String
    public var records: [String: PhotoAttributeRecord]
    public var updatedAt: Date

    public init(
        version: Int = currentVersion,
        rootPath: String,
        records: [String: PhotoAttributeRecord] = [:],
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.rootPath = rootPath
        self.records = records
        self.updatedAt = updatedAt
    }
}

/// Manages offline, non-destructive persistence of photo ratings, rejection status,
/// and AI quality reports in ~/Library/Application Support/PhotoAtelier/catalogs/.
public final class PhotoLibraryIndex {
    public let storageDirectory: URL

    /// Default storage location in Application Support.
    public static var defaultStorageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("PhotoAtelier/catalogs", isDirectory: true)
    }

    public init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory ?? Self.defaultStorageDirectory
    }

    /// Computes the unique persistent catalog file URL for a given folder root.
    public func catalogURL(forRoot root: URL) -> URL {
        let standardized = root.standardizedFileURL.path
        let hash = SHA256.hash(data: Data(standardized.utf8))
        let hashString = hash.compactMap { String(format: "%02x", $0) }.prefix(16).joined()
        let folderName = root.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "folder"
        let filename = "catalog-\(folderName)-\(hashString).json"
        return storageDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    /// Loads the catalog for a given root URL. Returns an empty catalog if none exists or if decoding fails.
    public func loadCatalog(forRoot root: URL) -> FolderCatalog {
        let fileURL = catalogURL(forRoot: root)
        guard let data = try? Data(contentsOf: fileURL) else {
            return FolderCatalog(rootPath: root.standardizedFileURL.path)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(FolderCatalog.self, from: data)
        } catch {
            return FolderCatalog(rootPath: root.standardizedFileURL.path)
        }
    }

    /// Atomically persists the catalog to disk.
    public func saveCatalog(_ catalog: FolderCatalog, forRoot root: URL) throws {
        let fileURL = catalogURL(forRoot: root)
        let parentDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(catalog)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Helper to extract relative path from root.
    public static func relativePath(of fileURL: URL, relativeTo root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        if filePath.hasPrefix(rootPath) {
            let remainder = filePath.dropFirst(rootPath.count)
            return remainder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return fileURL.lastPathComponent
    }

    /// Retrieves file attributes safely without touching file contents.
    public static func fileAttributes(for fileURL: URL) -> (size: Int64, mtime: TimeInterval)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber,
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return (size.int64Value, modDate.timeIntervalSince1970)
    }

    /// Updates or inserts a record for a specific photo URL.
    public func updateRecord(
        in catalog: inout FolderCatalog,
        for fileURL: URL,
        relativeTo root: URL,
        mutation: (inout PhotoAttributeRecord) -> Void
    ) {
        let relPath = Self.relativePath(of: fileURL, relativeTo: root)
        let (size, mtime) = Self.fileAttributes(for: fileURL) ?? (0, 0)

        var record = catalog.records[relPath] ?? PhotoAttributeRecord(
            relativePath: relPath,
            fileSize: size,
            modificationTimestamp: mtime
        )
        record.fileSize = size
        record.modificationTimestamp = mtime
        mutation(&record)
        record.updatedAt = Date()
        catalog.records[relPath] = record
        catalog.updatedAt = Date()
    }

    /// Batch updates records for multiple photo URLs.
    public func batchUpdateRecords(
        in catalog: inout FolderCatalog,
        for fileURLs: [URL],
        relativeTo root: URL,
        mutation: (inout PhotoAttributeRecord) -> Void
    ) {
        for fileURL in fileURLs {
            updateRecord(in: &catalog, for: fileURL, relativeTo: root, mutation: mutation)
        }
    }

    /// Removes records for files that no longer exist in the specified file list.
    public func pruneMissingFiles(
        in catalog: inout FolderCatalog,
        existingURLs: [URL],
        relativeTo root: URL
    ) {
        let validRelativePaths = Set(existingURLs.map { Self.relativePath(of: $0, relativeTo: root) })
        catalog.records = catalog.records.filter { validRelativePaths.contains($0.key) }
        catalog.updatedAt = Date()
    }
}

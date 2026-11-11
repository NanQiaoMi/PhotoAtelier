import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Manages offline persistence for a pinned AI reference image, allowing the user
/// to keep a reference color target across different folder imports.
public final class ReferencePinStorage {
    public let directory: URL

    public static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("PhotoAtelier/pinned_reference", isDirectory: true)
    }

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    private var imageURL: URL {
        directory.appendingPathComponent("pinned_reference.png")
    }

    private var metaURL: URL {
        directory.appendingPathComponent("pinned_reference_meta.json")
    }

    public struct Metadata: Codable, Equatable {
        public var name: String
        public var pinnedDate: Date

        public init(name: String, pinnedDate: Date = Date()) {
            self.name = name
            self.pinnedDate = pinnedDate
        }
    }

    /// Checks if a pinned reference image exists on disk.
    public var hasPinnedReference: Bool {
        FileManager.default.fileExists(atPath: imageURL.path)
    }

    /// Saves a reference image and its title atomically.
    public func pinReference(image: CGImage, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Save image as PNG
        guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AtelierError.imageWrite("无法创建钉住参考图输出目标。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AtelierError.imageWrite("写入钉住参考图文件失败。")
        }

        // Save metadata
        let meta = Metadata(name: name)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(meta)
        try data.write(to: metaURL, options: [.atomic])
    }

    /// Loads the pinned reference image and its title, or nil if none exists.
    public func loadPinnedReference() -> (image: CGImage, name: String)? {
        guard hasPinnedReference,
              let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        var name = "已钉住参考图"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let metaData = try? Data(contentsOf: metaURL),
           let meta = try? decoder.decode(Metadata.self, from: metaData) {
            name = meta.name
        }
        return (cgImage, name)
    }

    /// Removes the pinned reference image and metadata.
    public func clearPinnedReference() {
        try? FileManager.default.removeItem(at: imageURL)
        try? FileManager.default.removeItem(at: metaURL)
    }
}

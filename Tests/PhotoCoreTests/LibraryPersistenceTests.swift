import XCTest
import CryptoKit
@testable import PhotoCore

final class LibraryPersistenceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoAtelierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - D1: PhotoLibraryIndex Tests

    func testCatalogPersistenceRoundTrip() throws {
        let storageDir = tempDir.appendingPathComponent("catalogs", isDirectory: true)
        let index = PhotoLibraryIndex(storageDirectory: storageDir)
        let root = tempDir.appendingPathComponent("ProjectPhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let photo1 = root.appendingPathComponent("img_001.jpg")
        let photo2 = root.appendingPathComponent("subfolder/img_002.jpg")
        try FileManager.default.createDirectory(at: photo2.deletingLastPathComponent(), withIntermediateDirectories: true)

        try Data(repeating: 1, count: 1024).write(to: photo1)
        try Data(repeating: 2, count: 2048).write(to: photo2)

        var catalog = index.loadCatalog(forRoot: root)
        XCTAssertEqual(catalog.records.count, 0)

        // Update photo 1
        index.updateRecord(in: &catalog, for: photo1, relativeTo: root) { record in
            record.rating = 5
            record.isRejected = false
            record.qualityReport = QualityReport(
                sharpnessScore: 0.95,
                exposureScore: 0.90,
                overallScore: 0.925,
                recommendation: .keep,
                reasons: ["清晰度高", "曝光适中"]
            )
        }

        // Update photo 2
        index.updateRecord(in: &catalog, for: photo2, relativeTo: root) { record in
            record.rating = 1
            record.isRejected = true
        }

        try index.saveCatalog(catalog, forRoot: root)

        // Reload via a fresh index instance
        let reloadIndex = PhotoLibraryIndex(storageDirectory: storageDir)
        let loaded = reloadIndex.loadCatalog(forRoot: root)

        XCTAssertEqual(loaded.records.count, 2)
        let r1 = try XCTUnwrap(loaded.records["img_001.jpg"])
        XCTAssertEqual(r1.rating, 5)
        XCTAssertFalse(r1.isRejected)
        XCTAssertEqual(r1.qualityReport?.overallScore, 0.925)
        XCTAssertEqual(r1.fileSize, 1024)

        let r2 = try XCTUnwrap(loaded.records["subfolder/img_002.jpg"])
        XCTAssertEqual(r2.rating, 1)
        XCTAssertTrue(r2.isRejected)
        XCTAssertEqual(r2.fileSize, 2048)
    }

    func testOriginalFilesAreNeverModified() throws {
        let storageDir = tempDir.appendingPathComponent("catalogs", isDirectory: true)
        let index = PhotoLibraryIndex(storageDirectory: storageDir)
        let root = tempDir.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let originalFile = root.appendingPathComponent("portrait.jpg")
        let originalBytes = Data("SAMPLE_PHOTO_PIXEL_DATA_DO_NOT_TOUCH".utf8)
        try originalBytes.write(to: originalFile)

        let initialHash = SHA256.hash(data: originalBytes)
        let initialAttrs = try FileManager.default.attributesOfItem(atPath: originalFile.path)
        let initialMtime = (initialAttrs[.modificationDate] as? Date)?.timeIntervalSince1970

        var catalog = index.loadCatalog(forRoot: root)
        for rating in 1...5 {
            index.updateRecord(in: &catalog, for: originalFile, relativeTo: root) { record in
                record.rating = rating
                record.isRejected = (rating == 1)
            }
            try index.saveCatalog(catalog, forRoot: root)
        }

        // Verify original file on disk is strictly untouched
        let currentBytes = try Data(contentsOf: originalFile)
        let currentHash = SHA256.hash(data: currentBytes)
        let currentAttrs = try FileManager.default.attributesOfItem(atPath: originalFile.path)
        let currentMtime = (currentAttrs[.modificationDate] as? Date)?.timeIntervalSince1970

        XCTAssertEqual(currentHash, initialHash, "原图文件的二进制哈希绝对不能被修改")
        XCTAssertEqual(currentMtime, initialMtime, "原图文件的修改时间戳绝对不能被触碰")
    }

    func testFingerprintMismatchInvalidatesOutdatedRecord() throws {
        let root = tempDir.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let photo = root.appendingPathComponent("test.jpg")
        try Data(repeating: 0, count: 500).write(to: photo)

        let attrs = try XCTUnwrap(PhotoLibraryIndex.fileAttributes(for: photo))
        let record = PhotoAttributeRecord(
            relativePath: "test.jpg",
            fileSize: attrs.size,
            modificationTimestamp: attrs.mtime,
            rating: 3
        )
        XCTAssertTrue(record.matches(fileSize: attrs.size, modificationTimestamp: attrs.mtime))

        // Simulated file modification: size changed
        XCTAssertFalse(record.matches(fileSize: attrs.size + 10, modificationTimestamp: attrs.mtime))
        // Simulated file modification: mtime changed
        XCTAssertFalse(record.matches(fileSize: attrs.size, modificationTimestamp: attrs.mtime + 5))
    }

    func testPruneMissingFiles() throws {
        let storageDir = tempDir.appendingPathComponent("catalogs", isDirectory: true)
        let index = PhotoLibraryIndex(storageDirectory: storageDir)
        let root = tempDir.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let p1 = root.appendingPathComponent("p1.jpg")
        let p2 = root.appendingPathComponent("p2.jpg")
        let p3 = root.appendingPathComponent("p3.jpg")
        try Data("1".utf8).write(to: p1)
        try Data("2".utf8).write(to: p2)
        try Data("3".utf8).write(to: p3)

        var catalog = index.loadCatalog(forRoot: root)
        index.updateRecord(in: &catalog, for: p1, relativeTo: root) { $0.rating = 1 }
        index.updateRecord(in: &catalog, for: p2, relativeTo: root) { $0.rating = 2 }
        index.updateRecord(in: &catalog, for: p3, relativeTo: root) { $0.rating = 3 }
        XCTAssertEqual(catalog.records.count, 3)

        // Prune keeping only p1 and p2
        index.pruneMissingFiles(in: &catalog, existingURLs: [p1, p2], relativeTo: root)
        XCTAssertEqual(catalog.records.count, 2)
        XCTAssertNotNil(catalog.records["p1.jpg"])
        XCTAssertNotNil(catalog.records["p2.jpg"])
        XCTAssertNil(catalog.records["p3.jpg"])
    }

    // MARK: - D2: History Jump & Human-Readable Titles

    func testHistoryJumpAndReadableTitles() {
        var history = UndoHistory(capacity: 10, mergeInterval: 0.1)
        let baseSnapshot = UndoSnapshot()

        history.push(baseSnapshot, key: UndoHistory.initialKey)
        XCTAssertEqual(history.entries.last?.title, "原始状态")

        var s1 = baseSnapshot
        s1.adjustments.exposureEV = 0.5
        history.push(s1, key: "basic.exposureEV")
        XCTAssertEqual(history.entries.last?.title, "调整曝光")

        var s2 = s1
        s2.lutID = "film.fuji"
        history.push(s2, key: "look.lutIntensity")
        XCTAssertEqual(history.entries.last?.title, "切换色彩风格")

        var s3 = s2
        s3.adjustments.saturation = 1.2
        history.push(s3, key: "basic.saturation")
        XCTAssertEqual(history.entries.last?.title, "调整饱和度")

        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history.currentIndex, 3)

        // Jump back to s1 (index 1)
        let jumped = history.jumpTo(index: 1)
        XCTAssertEqual(jumped, s1)
        XCTAssertEqual(history.currentIndex, 1)
        XCTAssertTrue(history.canRedo)
        XCTAssertTrue(history.canUndo)

        // Push new action after jump (clears redo)
        var s4 = s1
        s4.adjustments.contrast = 1.1
        history.push(s4, key: "basic.contrast")
        XCTAssertEqual(history.entries.last?.title, "调整对比度")
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.count, 3) // s0, s1, s4
    }

    func testBatchUpdateRecords() throws {
        let storageDir = tempDir.appendingPathComponent("catalogs", isDirectory: true)
        let index = PhotoLibraryIndex(storageDirectory: storageDir)
        let root = tempDir.appendingPathComponent("ProjectPhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let photoA = root.appendingPathComponent("a.jpg")
        let photoB = root.appendingPathComponent("b.jpg")
        try Data("A".utf8).write(to: photoA)
        try Data("B".utf8).write(to: photoB)

        var catalog = index.loadCatalog(forRoot: root)
        index.batchUpdateRecords(in: &catalog, for: [photoA, photoB], relativeTo: root) { record in
            record.rating = 4
            record.isRejected = false
        }
        try index.saveCatalog(catalog, forRoot: root)

        let reloaded = index.loadCatalog(forRoot: root)
        XCTAssertEqual(reloaded.records["a.jpg"]?.rating, 4)
        XCTAssertEqual(reloaded.records["b.jpg"]?.rating, 4)
    }

    func testEmptyOrCorruptCatalogRecoversGracefully() throws {
        let storageDir = tempDir.appendingPathComponent("catalogs", isDirectory: true)
        let index = PhotoLibraryIndex(storageDirectory: storageDir)
        let root = tempDir.appendingPathComponent("ProjectPhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let catalogFile = index.catalogURL(forRoot: root)
        try FileManager.default.createDirectory(at: catalogFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("CORRUPT_NOT_JSON".utf8).write(to: catalogFile)

        let recovered = index.loadCatalog(forRoot: root)
        XCTAssertEqual(recovered.records.count, 0)
        XCTAssertEqual(recovered.rootPath, root.standardizedFileURL.path)
    }

    func testHistoryAllKeyCategoriesHaveReadableTitles() {
        let keys = [
            UndoHistory.initialKey,
            "basic.exposureEV",
            "basic.temperature",
            "basic.contrast",
            "basic.saturation",
            "basic.highlights",
            "curve.points",
            "look.lutIntensity",
            "look.grain",
            "geometry.crop",
            "lens.distortion",
            "mask.brush",
            "portrait.skinSmooth",
            "makeup.lipColor",
            "colorTools.hsl",
            "repair.stroke",
            "idPhoto.background",
            "referenceColor.strength",
            "unknown.arbitrary"
        ]
        for key in keys {
            let title = UndoHistory.humanReadableTitle(for: key)
            XCTAssertFalse(title.isEmpty, "Title for key \(key) should not be empty")
        }
    }

    // MARK: - D3: Pinned Reference Storage

    func testReferencePinStorageSaveAndLoad() throws {
        let pinDir = tempDir.appendingPathComponent("pinned_ref", isDirectory: true)
        let storage = ReferencePinStorage(directory: pinDir)
        XCTAssertFalse(storage.hasPinnedReference)

        // Create 8x8 dummy CGImage
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let cgImage = try XCTUnwrap(context.makeImage())

        try storage.pinReference(image: cgImage, name: "秋季暖调样片")
        XCTAssertTrue(storage.hasPinnedReference)

        let loaded = try XCTUnwrap(storage.loadPinnedReference())
        XCTAssertEqual(loaded.name, "秋季暖调样片")
        XCTAssertEqual(loaded.image.width, 8)
        XCTAssertEqual(loaded.image.height, 8)

        storage.clearPinnedReference()
        XCTAssertFalse(storage.hasPinnedReference)
        XCTAssertNil(storage.loadPinnedReference())
    }
}

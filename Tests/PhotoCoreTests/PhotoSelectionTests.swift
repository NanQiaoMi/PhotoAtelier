import XCTest
import Foundation
@testable import PhotoCore

final class PhotoSelectionTests: XCTestCase {
    func testResolveSingleFileUsesParentDirectoryAsRoot() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("one.png")
        try TestFiles.writeFixture(to: file, width: 2, height: 2)

        let result = PhotoSelection.resolve(fileURLs: [file])

        XCTAssertEqual(result.root?.standardizedFileURL.path, temp.standardizedFileURL.path)
        XCTAssertEqual(result.items.map(\.url.lastPathComponent), ["one.png"])
        XCTAssertEqual(result.items.map(\.relativePath), ["one.png"])
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testResolveMultipleFilesUsesSharedRootAndStablePathOrder() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let nested = temp.appendingPathComponent("album", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = temp.appendingPathComponent("a.png")
        let second = nested.appendingPathComponent("b.png")
        try TestFiles.writeFixture(to: first, width: 2, height: 2)
        try TestFiles.writeFixture(to: second, width: 2, height: 2)

        // Deliberately pass the nested file first; the result must be path-sorted
        // and every relativePath must be relative to the shared root.
        let result = PhotoSelection.resolve(fileURLs: [second, first])

        XCTAssertEqual(result.root?.standardizedFileURL.path, temp.standardizedFileURL.path)
        XCTAssertEqual(result.items.map(\.relativePath), ["a.png", "album/b.png"])
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testResolveDeduplicatesSameFileSelectedTwice() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("dup.png")
        try TestFiles.writeFixture(to: file, width: 2, height: 2)
        let aliased = URL(fileURLWithPath: temp.path + "/./dup.png")

        let result = PhotoSelection.resolve(fileURLs: [file, aliased, file])

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.url.standardizedFileURL.path, file.standardizedFileURL.path)
        XCTAssertTrue(result.issues.isEmpty, "Duplicate inputs are de-duplicated, not reported as errors")
    }

    func testResolveReportsUnsupportedFormatsPerItemAndKeepsAcceptedFiles() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let photo = temp.appendingPathComponent("keep.png")
        let notes = temp.appendingPathComponent("notes.txt")
        let cube = temp.appendingPathComponent("style.cube")
        try TestFiles.writeFixture(to: photo, width: 2, height: 2)
        try Data("not a photo".utf8).write(to: notes)
        try Data("LUT_3D_SIZE 2".utf8).write(to: cube)

        let result = PhotoSelection.resolve(fileURLs: [notes, photo, cube])

        XCTAssertEqual(result.items.map(\.url.lastPathComponent), ["keep.png"])
        XCTAssertEqual(result.issues.map(\.url.lastPathComponent), ["notes.txt", "style.cube"])
        XCTAssertTrue(result.issues[0].message.contains("不支持的照片格式"))
        XCTAssertTrue(result.issues[0].message.contains("txt"), result.issues[0].message)
        XCTAssertEqual(result.root?.standardizedFileURL.path, temp.standardizedFileURL.path)
    }

    func testResolveReportsMissingFoldersSymlinksAndNonFileURLs() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let folder = temp.appendingPathComponent("album", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let missing = temp.appendingPathComponent("missing.png")
        let symlink = temp.appendingPathComponent("linked.png")
        let target = temp.appendingPathComponent("target.png")
        try TestFiles.writeFixture(to: target, width: 2, height: 2)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let result = PhotoSelection.resolve(fileURLs: [
            folder, missing, symlink, URL(string: "https://example.com/photo.jpg")!
        ])

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertNil(result.root)
        XCTAssertEqual(result.issues.count, 4)
        XCTAssertTrue(result.issues[0].message.contains("文件夹"), result.issues[0].message)
        XCTAssertTrue(result.issues[1].message.contains("无法读取文件属性"), result.issues[1].message)
        XCTAssertTrue(result.issues[2].message.contains("符号链接"), result.issues[2].message)
        XCTAssertTrue(result.issues[3].message.contains("本地"), result.issues[3].message)
    }

    func testResolveAcceptsNewFormatExtensionsAndRAWCandidates() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let names = ["still.heic", "still.heif", "still.avif", "still.webp", "camera.nef", "camera.dng"]
        var urls: [URL] = []
        for name in names {
            let url = temp.appendingPathComponent(name)
            // Extension-only candidates: resolve never decodes pixels.
            try Data("candidate".utf8).write(to: url)
            urls.append(url)
        }

        let result = PhotoSelection.resolve(fileURLs: urls)

        XCTAssertEqual(Set(result.items.map(\.url.lastPathComponent)), Set(names))
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.root?.standardizedFileURL.path, temp.standardizedFileURL.path)
    }

    func testCommonRootHandlesSingleSiblingAndVolumeRoots() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let alpha = temp.appendingPathComponent("alpha", isDirectory: true)
        let beta = temp.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)

        XCTAssertNil(PhotoSelection.commonRoot(of: []))
        XCTAssertEqual(PhotoSelection.commonRoot(of: [alpha])?.path, alpha.path)
        XCTAssertEqual(PhotoSelection.commonRoot(of: [alpha, beta])?.path, temp.path)
        // Prefix trap: "alphabet" must not be treated as a child of "alpha".
        let alphabet = temp.appendingPathComponent("alphabet", isDirectory: true)
        try FileManager.default.createDirectory(at: alphabet, withIntermediateDirectories: true)
        XCTAssertEqual(PhotoSelection.commonRoot(of: [alpha, alphabet])?.path, temp.path)
        XCTAssertEqual(
            PhotoSelection.commonRoot(of: [
                URL(fileURLWithPath: "/first", isDirectory: true),
                URL(fileURLWithPath: "/second", isDirectory: true)
            ])?.path,
            "/"
        )
    }

    func testShouldAppendOnlyForTheOpenFolderAndItsDescendants() throws {
        let open = URL(fileURLWithPath: "/photos/trip", isDirectory: true)

        XCTAssertTrue(PhotoSelection.shouldAppend(incomingRoot: open, currentRoot: open))
        XCTAssertTrue(PhotoSelection.shouldAppend(
            incomingRoot: URL(fileURLWithPath: "/photos/trip/day1", isDirectory: true),
            currentRoot: open
        ))
        XCTAssertFalse(PhotoSelection.shouldAppend(
            incomingRoot: URL(fileURLWithPath: "/photos/trip2", isDirectory: true),
            currentRoot: open
        ))
        XCTAssertFalse(PhotoSelection.shouldAppend(
            incomingRoot: URL(fileURLWithPath: "/photos", isDirectory: true),
            currentRoot: open
        ))
        XCTAssertFalse(PhotoSelection.shouldAppend(incomingRoot: open, currentRoot: nil))
    }

    func testMergeDeduplicatesSecondImportAndKeepsPathOrder() throws {
        let existing = [
            PhotoItem(url: URL(fileURLWithPath: "/lib/b.png"), relativePath: "b.png"),
            PhotoItem(url: URL(fileURLWithPath: "/lib/d.png"), relativePath: "d.png")
        ]
        let incoming = [
            PhotoItem(url: URL(fileURLWithPath: "/lib/c.png"), relativePath: "c.png"),
            PhotoItem(url: URL(fileURLWithPath: "/lib/b.png"), relativePath: "b.png"),
            PhotoItem(url: URL(fileURLWithPath: "/lib/a.png"), relativePath: "a.png")
        ]

        let merged = PhotoSelection.merge(existing: existing, incoming: incoming)

        XCTAssertEqual(merged.map(\.relativePath), ["a.png", "b.png", "c.png", "d.png"])
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count)
    }

    func testBuildItemsDropsPathsOutsideRootAndDeduplicates() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let inside = temp.appendingPathComponent("inside.png")
        let outside = temp.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).png")
        try TestFiles.writeFixture(to: inside, width: 2, height: 2)
        try TestFiles.writeFixture(to: outside, width: 2, height: 2)
        defer { try? FileManager.default.removeItem(at: outside) }

        let items = PhotoSelection.items(fileURLs: [inside, inside, outside], root: temp)

        XCTAssertEqual(items.map(\.relativePath), ["inside.png"])
        XCTAssertEqual(items.first?.url.standardizedFileURL.path, inside.standardizedFileURL.path)
    }

    /// Import semantics without AppKit: the first import opens the album, dropping
    /// its nested folder afterwards must append (de-duplicated) and keep every
    /// relativePath relative to the *open* root, not the dropped folder.
    func testSecondImportOfNestedFolderAppendsAndDeduplicates() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let album = temp.appendingPathComponent("album", isDirectory: true)
        let day = album.appendingPathComponent("day", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try TestFiles.writeFixture(to: album.appendingPathComponent("a.png"), width: 2, height: 2)
        try TestFiles.writeFixture(to: day.appendingPathComponent("b.png"), width: 2, height: 2)

        let library = try PhotoLoader.scan(folder: album, recursive: true)
        XCTAssertEqual(library.map(\.relativePath), ["a.png", "day/b.png"])

        // Second import: nested folder dropped while the album is already open.
        let dropped = try PhotoLoader.scan(folder: day, recursive: false)
        XCTAssertTrue(PhotoSelection.shouldAppend(incomingRoot: day, currentRoot: album))
        let reBased = PhotoSelection.items(fileURLs: dropped.map(\.url), root: album)
        XCTAssertEqual(reBased.map(\.relativePath), ["day/b.png"])
        XCTAssertEqual(PhotoSelection.merge(existing: library, incoming: reBased).count, 2,
                       "re-importing an already-open file must not duplicate the library")

        // Same file imported twice in one selection is de-duplicated by id too.
        let repeated = PhotoSelection.merge(existing: library, incoming: reBased + reBased)
        XCTAssertEqual(repeated.count, 2)
        XCTAssertEqual(repeated.map(\.relativePath), ["a.png", "day/b.png"])
    }
}

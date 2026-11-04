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

    // MARK: - P1-C culling session state (C4)

    private func photo(_ name: String, rating: Int = 0, rejected: Bool = false,
                       quality: QualityReport? = nil) -> PhotoItem {
        PhotoItem(url: URL(fileURLWithPath: "/lib/\(name)"), relativePath: name,
                  rating: rating, isRejected: rejected, qualityReport: quality)
    }

    private func quality(_ recommendation: QualityRecommendation) -> QualityReport {
        QualityReport(overallScore: recommendation == .keep ? 0.85 : 0.5,
                      recommendation: recommendation)
    }

    func testRatingClampAndSteppedRating() {
        XCTAssertEqual(PhotoSelection.clampedRating(-3), 0)
        XCTAssertEqual(PhotoSelection.clampedRating(7), 5)
        XCTAssertEqual(PhotoSelection.clampedRating(3), 3)
        XCTAssertEqual(PhotoSelection.steppedRating(5, delta: 1), 5)
        XCTAssertEqual(PhotoSelection.steppedRating(0, delta: -1), 0)
        XCTAssertEqual(PhotoSelection.steppedRating(2, delta: 1), 3)
        XCTAssertEqual(PhotoItem(url: URL(fileURLWithPath: "/x"), relativePath: "x",
                                 rating: 99).rating, 5,
                       "PhotoItem init 必须把评级夹取到 0...5")
    }

    func testCullFiltersCoverAllRecommendedKeptAndRejected() {
        let keep = photo("keep.png", quality: quality(.keep))
        let review = photo("review.png", quality: quality(.review))
        let aiReject = photo("ai-reject.png", quality: quality(.reject))
        let manualWaste = photo("waste.png", rating: 1, rejected: true)
        let starred = photo("star.png", rating: 5)
        let unrated = photo("unrated.png")
        let all = [keep, review, aiReject, manualWaste, starred, unrated]

        XCTAssertEqual(PhotoSelection.filtered(all, filter: .all).count, 6)
        XCTAssertEqual(PhotoSelection.filtered(all, filter: .recommended).map(\.relativePath),
                       ["keep.png", "star.png"],
                       "推荐=启发式 keep 或手动 4-5 星")
        XCTAssertEqual(PhotoSelection.filtered(all, filter: .kept).count, 5)
        XCTAssertEqual(PhotoSelection.filtered(all, filter: .rejected).map(\.relativePath),
                       ["waste.png"])
    }

    func testExportSelectionOptionsSkipLogic() {
        let clean = photo("clean.png", rating: 2)
        let unrated = photo("unrated.png")
        let waste = photo("waste.png", rating: 4, rejected: true)

        let neutral = ExportSelectionOptions()
        XCTAssertTrue(neutral.isNeutral)
        XCTAssertTrue(PhotoSelection.shouldExport(waste, options: neutral))
        XCTAssertTrue(PhotoSelection.shouldExport(unrated, options: neutral))

        let skipWaste = ExportSelectionOptions(skipRejectedPhotos: true)
        XCTAssertFalse(skipWaste.isNeutral)
        XCTAssertFalse(PhotoSelection.shouldExport(waste, options: skipWaste))
        XCTAssertTrue(PhotoSelection.shouldExport(unrated, options: skipWaste))
        XCTAssertTrue(try! XCTUnwrap(PhotoSelection.skipReason(for: waste, options: skipWaste))
            .contains("废片"))

        let skipUnrated = ExportSelectionOptions(skipUnselectedPhotos: true)
        XCTAssertFalse(PhotoSelection.shouldExport(unrated, options: skipUnrated))
        XCTAssertTrue(PhotoSelection.shouldExport(clean, options: skipUnrated))
        XCTAssertTrue(try! XCTUnwrap(PhotoSelection.skipReason(for: unrated, options: skipUnrated))
            .contains("未评级"))

        let both = ExportSelectionOptions(skipRejectedPhotos: true, skipUnselectedPhotos: true)
        XCTAssertFalse(PhotoSelection.shouldExport(waste, options: both))
        XCTAssertFalse(PhotoSelection.shouldExport(unrated, options: both))
        XCTAssertTrue(PhotoSelection.shouldExport(clean, options: both))
        XCTAssertEqual(both.summary, "skipRejected+skipUnselected")
        XCTAssertTrue(PhotoSelection.shouldExport(photo("zero-rated.png", rating: 0, rejected: true),
                                                  options: skipUnrated),
                      "只开 skipUnselected 时，0 星废片仍按评级规则导出；废片由 skipRejected 单独控制")
    }

    func testAutoCullAssignmentMappingAndManualPreservation() {
        XCTAssertEqual(PhotoSelection.autoCullAssignment(for: quality(.keep)),
                       PhotoSelection.AutoCullAssignment(rating: 5, isRejected: false))
        XCTAssertEqual(PhotoSelection.autoCullAssignment(for: quality(.review)).rating, 3)
        let rejected = PhotoSelection.autoCullAssignment(for: quality(.reject))
        XCTAssertEqual(rejected.rating, 1)
        XCTAssertTrue(rejected.isRejected)

        var items = [photo("fresh.png"), photo("manual.png", rating: 4),
                     photo("waste.png", rejected: true)]
        let applied = PhotoSelection.applyingAutoCull(
            reports: [items[0].id: quality(.keep),
                      items[1].id: quality(.reject),
                      items[2].id: quality(.keep)],
            to: &items)
        XCTAssertEqual(applied, 3)
        XCTAssertEqual(items[0].rating, 5, "未手动标记的照片应填入自动建议星级")
        XCTAssertEqual(items[0].qualityReport?.recommendation, .keep)
        XCTAssertEqual(items[1].rating, 4, "手动评级不得被自动挑图覆盖")
        XCTAssertEqual(items[1].qualityReport?.recommendation, .reject,
                       "报告仍应记录，便于 UI 显示建议")
        XCTAssertTrue(items[2].isRejected, "手动废片标记不得被自动挑图覆盖")
        XCTAssertEqual(items[2].rating, 0, "手动废片的星级保持不变")

        // Reports for unknown ids are ignored.
        var missing = [photo("solo.png")]
        XCTAssertEqual(PhotoSelection.applyingAutoCull(reports: ["unknown": quality(.keep)],
                                                       to: &missing), 0)
    }
}

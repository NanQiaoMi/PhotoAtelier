import XCTest
import CoreImage
import Foundation
@testable import PhotoCore

final class VirtualCopyTests: XCTestCase {

    func testVirtualCopyCreationAndEquality() throws {
        var adj = AdjustmentSettings()
        adj.exposureEV = 0.5
        adj.contrast = 1.2

        let id = UUID()
        let date = Date()
        let copy1 = VirtualCopy(
            id: id,
            name: "复古暖色",
            adjustments: adj,
            lutIdentifier: "kodak_gold",
            createdAt: date
        )

        let copy2 = VirtualCopy(
            id: id,
            name: "复古暖色",
            adjustments: adj,
            lutIdentifier: "kodak_gold",
            createdAt: date
        )

        XCTAssertEqual(copy1, copy2)
        XCTAssertEqual(copy1.id, id)
        XCTAssertEqual(copy1.name, "复古暖色")
        XCTAssertEqual(copy1.adjustments.exposureEV, 0.5)
        XCTAssertEqual(copy1.lutIdentifier, "kodak_gold")

        // JSON Codable round trip
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(copy1)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VirtualCopy.self, from: data)

        XCTAssertEqual(decoded.id, copy1.id)
        XCTAssertEqual(decoded.name, copy1.name)
        XCTAssertEqual(decoded.adjustments.exposureEV, copy1.adjustments.exposureEV)
        XCTAssertEqual(decoded.lutIdentifier, copy1.lutIdentifier)
    }

    func testPhotoItemVirtualCopiesProperties() {
        let url = URL(fileURLWithPath: "/tmp/sample.jpg")
        var masterAdj = AdjustmentSettings()
        masterAdj.exposureEV = 0.0

        var copy1Adj = AdjustmentSettings()
        copy1Adj.exposureEV = 1.0

        var copy2Adj = AdjustmentSettings()
        copy2Adj.exposureEV = -1.0

        let copy1 = VirtualCopy(id: UUID(), name: "高调", adjustments: copy1Adj, lutIdentifier: "portra_400")
        let copy2 = VirtualCopy(id: UUID(), name: "低调", adjustments: copy2Adj, lutIdentifier: "tri_x")

        var item = PhotoItem(
            url: url,
            relativePath: "sample.jpg",
            adjustments: masterAdj,
            lutIdentifier: "none",
            virtualCopies: [copy1, copy2]
        )

        // When activeCopyID is nil, should point to master
        XCTAssertNil(item.activeCopyID)
        XCTAssertNil(item.activeCopy)
        XCTAssertEqual(item.effectiveAdjustments?.exposureEV, 0.0)
        XCTAssertEqual(item.effectiveLUTIdentifier, "none")

        // Switch to copy 1
        item.activeCopyID = copy1.id
        XCTAssertEqual(item.activeCopy?.id, copy1.id)
        XCTAssertEqual(item.activeCopy?.name, "高调")
        XCTAssertEqual(item.effectiveAdjustments?.exposureEV, 1.0)
        XCTAssertEqual(item.effectiveLUTIdentifier, "portra_400")

        // Switch to copy 2
        item.activeCopyID = copy2.id
        XCTAssertEqual(item.activeCopy?.id, copy2.id)
        XCTAssertEqual(item.activeCopy?.name, "低调")
        XCTAssertEqual(item.effectiveAdjustments?.exposureEV, -1.0)
        XCTAssertEqual(item.effectiveLUTIdentifier, "tri_x")
    }

    func testPhotoAttributeRecordVirtualCopiesPersistenceRoundTrip() throws {
        var adj = AdjustmentSettings()
        adj.exposureEV = 0.75

        let copy1 = VirtualCopy(id: UUID(), name: "彩色胶片", adjustments: adj, lutIdentifier: "fuji_400h")
        let copy2 = VirtualCopy(id: UUID(), name: "黑白街头", adjustments: adj, lutIdentifier: "ilford_hp5")

        let record = PhotoAttributeRecord(
            relativePath: "portrait_002.jpg",
            fileSize: 2048576,
            modificationTimestamp: 1700000000.0,
            rating: 4,
            isRejected: false,
            qualityReport: nil,
            adjustments: adj,
            lutIdentifier: "none",
            virtualCopies: [copy1, copy2],
            updatedAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PhotoAttributeRecord.self, from: data)

        XCTAssertEqual(decoded.relativePath, "portrait_002.jpg")
        XCTAssertEqual(decoded.virtualCopies.count, 2)
        XCTAssertEqual(decoded.virtualCopies[0].name, "彩色胶片")
        XCTAssertEqual(decoded.virtualCopies[0].lutIdentifier, "fuji_400h")
        XCTAssertEqual(decoded.virtualCopies[1].name, "黑白街头")
        XCTAssertEqual(decoded.virtualCopies[1].lutIdentifier, "ilford_hp5")
    }

    func testFolderCatalogBackwardCompatibilityWithLegacyVersions() throws {
        // Legacy v1 JSON (no adjustments, no lutIdentifier, no virtualCopies)
        let v1JSON = """
        {
            "version": 1,
            "rootPath": "/Users/test/Photos",
            "records": {
                "photo1.jpg": {
                    "relativePath": "photo1.jpg",
                    "fileSize": 4096,
                    "modificationTimestamp": 1690000000.0,
                    "rating": 5,
                    "isRejected": false,
                    "updatedAt": "2026-11-01T12:00:00Z"
                }
            },
            "updatedAt": "2026-11-01T12:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalogV1 = try decoder.decode(FolderCatalog.self, from: v1JSON)
        XCTAssertEqual(catalogV1.records.count, 1)
        XCTAssertEqual(catalogV1.records["photo1.jpg"]?.virtualCopies, [], "v1 缺少 virtualCopies 时应优雅降级为空数组。")

        // Legacy v2 JSON (has adjustments and lutIdentifier, but no virtualCopies)
        let v2JSON = """
        {
            "version": 2,
            "rootPath": "/Users/test/Photos",
            "records": {
                "photo2.jpg": {
                    "relativePath": "photo2.jpg",
                    "fileSize": 8192,
                    "modificationTimestamp": 1695000000.0,
                    "rating": 3,
                    "isRejected": false,
                    "lutIdentifier": "classic_chrome",
                    "updatedAt": "2026-11-05T12:00:00Z"
                }
            },
            "updatedAt": "2026-11-05T12:00:00Z"
        }
        """.data(using: .utf8)!

        let catalogV2 = try decoder.decode(FolderCatalog.self, from: v2JSON)
        XCTAssertEqual(catalogV2.records.count, 1)
        XCTAssertEqual(catalogV2.records["photo2.jpg"]?.lutIdentifier, "classic_chrome")
        XCTAssertEqual(catalogV2.records["photo2.jpg"]?.virtualCopies, [], "v2 缺少 virtualCopies 时应优雅降级为空数组。")

        // Current catalog version must be 3
        XCTAssertEqual(FolderCatalog.currentVersion, 3)
    }

    func testPhotoSelectionExpandForExportActiveOnly() {
        let url = URL(fileURLWithPath: "/tmp/sample.jpg")
        var masterAdj = AdjustmentSettings(); masterAdj.exposureEV = 0.0
        var copyAdj = AdjustmentSettings(); copyAdj.exposureEV = 1.5

        let copy = VirtualCopy(id: UUID(), name: "高调", adjustments: copyAdj)
        var item = PhotoItem(url: url, relativePath: "sample.jpg", adjustments: masterAdj, virtualCopies: [copy])

        // When active is master
        let options = ExportSelectionOptions(virtualCopyMode: .activeOnly)
        let expandedMaster = PhotoSelection.expandForExport(items: [item], options: options)
        XCTAssertEqual(expandedMaster.count, 1)
        XCTAssertEqual(expandedMaster[0].adjustments?.exposureEV, 0.0)

        // When active is copy
        item.activeCopyID = copy.id
        let expandedCopy = PhotoSelection.expandForExport(items: [item], options: options)
        XCTAssertEqual(expandedCopy.count, 1)
        XCTAssertEqual(expandedCopy[0].adjustments?.exposureEV, 1.5)
    }

    func testPhotoSelectionExpandForExportMasterOnly() {
        let url = URL(fileURLWithPath: "/tmp/sample.jpg")
        var masterAdj = AdjustmentSettings(); masterAdj.exposureEV = -0.5
        var copyAdj = AdjustmentSettings(); copyAdj.exposureEV = 1.5

        let copy = VirtualCopy(id: UUID(), name: "高调", adjustments: copyAdj)
        var item = PhotoItem(url: url, relativePath: "sample.jpg", adjustments: masterAdj, virtualCopies: [copy])
        item.activeCopyID = copy.id // Even if copy is currently active

        let options = ExportSelectionOptions(virtualCopyMode: .masterOnly)
        let expanded = PhotoSelection.expandForExport(items: [item], options: options)
        XCTAssertEqual(expanded.count, 1)
        XCTAssertEqual(expanded[0].adjustments?.exposureEV, -0.5, "masterOnly 模式下必须导出主版本配方。")
        XCTAssertNil(expanded[0].activeCopyID)
    }

    func testPhotoSelectionExpandForExportAllVersions() {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        var masterAdj = AdjustmentSettings(); masterAdj.exposureEV = 0.0
        var copy1Adj = AdjustmentSettings(); copy1Adj.exposureEV = 1.0
        var copy2Adj = AdjustmentSettings(); copy2Adj.exposureEV = -1.0

        let copy1 = VirtualCopy(id: UUID(), name: "日系小清新", adjustments: copy1Adj)
        let copy2 = VirtualCopy(id: UUID(), name: "黑白/电影感", adjustments: copy2Adj)

        let item = PhotoItem(
            url: url,
            relativePath: "photo.jpg",
            adjustments: masterAdj,
            virtualCopies: [copy1, copy2]
        )

        let options = ExportSelectionOptions(virtualCopyMode: .allVersions)
        let expanded = PhotoSelection.expandForExport(items: [item], options: options)

        XCTAssertEqual(expanded.count, 3, "allVersions 模式下 1 个主版本 + 2 个副本应展开为 3 项。")

        // 1st: Master
        XCTAssertNil(expanded[0].activeCopyID)
        XCTAssertNil(expanded[0].exportSuffix)
        XCTAssertEqual(expanded[0].adjustments?.exposureEV, 0.0)

        // 2nd: Copy 1
        XCTAssertEqual(expanded[1].activeCopyID, copy1.id)
        XCTAssertEqual(expanded[1].exportSuffix, "_日系小清新")
        XCTAssertEqual(expanded[1].adjustments?.exposureEV, 1.0)

        // 3rd: Copy 2 (slash in name sanitized to underscore)
        XCTAssertEqual(expanded[2].activeCopyID, copy2.id)
        XCTAssertEqual(expanded[2].exportSuffix, "_黑白_电影感")
        XCTAssertEqual(expanded[2].adjustments?.exposureEV, -1.0)
    }

    func testSanitizeSuffix() {
        XCTAssertEqual(PhotoSelection.sanitizeSuffix("版本 1"), "版本_1")
        XCTAssertEqual(PhotoSelection.sanitizeSuffix("A/B:test*one?"), "A_B_test_one")
        XCTAssertEqual(PhotoSelection.sanitizeSuffix(""), "")
    }

    func testExportSelectionOptionsNeutralAndSummary() {
        let opt1 = ExportSelectionOptions()
        XCTAssertTrue(opt1.isNeutral)
        XCTAssertEqual(opt1.summary, "none")

        let opt2 = ExportSelectionOptions(skipRejectedPhotos: true, virtualCopyMode: .allVersions)
        XCTAssertFalse(opt2.isNeutral)
        XCTAssertTrue(opt2.summary.contains("skipRejected"))
        XCTAssertTrue(opt2.summary.contains("virtualCopies:allVersions"))
    }

    func testBatchProcessorRendersAllVirtualCopiesWithDistinctFiles() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let sampleURL = input.appendingPathComponent("sample.jpg")
        try PhotoExporter.write(image: image, to: sampleURL, settings: ExportSettings(), sourceProperties: [:], context: context)

        var masterAdj = AdjustmentSettings()
        masterAdj.exposureEV = 0.0

        var copyAdj = AdjustmentSettings()
        copyAdj.exposureEV = 1.0

        let copy = VirtualCopy(name: "高调", adjustments: copyAdj)
        let item = PhotoItem(
            url: sampleURL,
            relativePath: "sample.jpg",
            adjustments: masterAdj,
            virtualCopies: [copy]
        )

        var exportSettings = ExportSettings()
        exportSettings.suffix = "_edited"
        let recipe = Recipe(adjustments: masterAdj, export: exportSettings)
        let summary = try BatchProcessor().run(
            items: [item],
            inputRoot: input,
            outputRoot: output,
            recipe: recipe,
            lut: nil,
            selection: ExportSelectionOptions(virtualCopyMode: .allVersions),
            cancellation: CancellationToken(),
            onEvent: { _ in }
        )

        XCTAssertEqual(summary.succeeded, 2, "主版本与虚拟副本各成功导出 1 张。")
        XCTAssertEqual(summary.failed, 0)

        let masterOutputURL = output.appendingPathComponent("sample_edited.jpg")
        let copyOutputURL = output.appendingPathComponent("sample_edited_高调.jpg")

        XCTAssertTrue(FileManager.default.fileExists(atPath: masterOutputURL.path), "主版本导出文件应存在。")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyOutputURL.path), "虚拟副本导出文件应存在。")
    }
}

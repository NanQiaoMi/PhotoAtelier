import XCTest
@testable import PhotoCore

final class AdjustmentSyncTests: XCTestCase {

    func testAdjustmentSyncOptionsDefaultsAndPresets() {
        let def = AdjustmentSyncOptions()
        XCTAssertTrue(def.basicTone)
        XCTAssertTrue(def.whiteBalance)
        XCTAssertTrue(def.tonalCurves)
        XCTAssertTrue(def.hsl)
        XCTAssertTrue(def.colorGrading)
        XCTAssertTrue(def.lut)
        XCTAssertTrue(def.portraitRetouch)
        XCTAssertTrue(def.facialReshape)
        XCTAssertTrue(def.facialZonal)
        XCTAssertTrue(def.makeup)
        XCTAssertTrue(def.hair)
        XCTAssertTrue(def.clothing)
        XCTAssertTrue(def.bodySkin)
        XCTAssertTrue(def.backdrop)
        XCTAssertTrue(def.skyEnhancement)
        XCTAssertFalse(def.petEnhancement) // Pet enhancement off by default

        // Protection defaults: local masks, repair brush, geometry MUST be false by default
        XCTAssertFalse(def.localMasks, "局部蒙版应默认关闭以防止不同构图照片错位。")
        XCTAssertFalse(def.repairBrush, "仿制与修补笔刷应默认关闭以防止跨照片纹理错位。")
        XCTAssertFalse(def.geometry, "裁剪旋转应默认关闭以保护各自独立构图。")
        XCTAssertFalse(def.certificatePhoto)

        // Portrait preset
        let portrait = AdjustmentSyncOptions.portraitStudio
        XCTAssertTrue(portrait.portraitRetouch)
        XCTAssertTrue(portrait.facialReshape)
        XCTAssertTrue(portrait.makeup)
        XCTAssertTrue(portrait.hair)
        XCTAssertTrue(portrait.facialZonal)
        XCTAssertFalse(portrait.skyEnhancement)
        XCTAssertFalse(portrait.localMasks)

        // Landscape preset
        let landscape = AdjustmentSyncOptions.landscapeOutdoor
        XCTAssertTrue(landscape.basicTone)
        XCTAssertTrue(landscape.skyEnhancement)
        XCTAssertTrue(landscape.tonalCurves)
        XCTAssertFalse(landscape.portraitRetouch)
        XCTAssertFalse(landscape.makeup)

        // Color grading only
        let grading = AdjustmentSyncOptions.colorGradingOnly
        XCTAssertTrue(grading.colorGrading)
        XCTAssertTrue(grading.hsl)
        XCTAssertTrue(grading.tonalCurves)
        XCTAssertFalse(grading.basicTone)
        XCTAssertFalse(grading.portraitRetouch)

        // None
        let none = AdjustmentSyncOptions.none
        XCTAssertFalse(none.basicTone)
        XCTAssertFalse(none.whiteBalance)
        XCTAssertFalse(none.portraitRetouch)
        XCTAssertFalse(none.skyEnhancement)
    }

    func testSelectiveMergeCopiesOnlySelectedModules() {
        var source = AdjustmentSettings()
        source.exposureEV = 1.25
        source.temperature = 15.0
        source.contrast = 1.20
        var sourceTools = ColorToolsSettings()
        var hsl = HSLSettings()
        hsl.red.saturation = 0.50
        sourceTools.hsl = hsl
        source.colorTools = sourceTools
        source.portrait = PortraitRefinementSettings(blemishStrength: 0.70)
        source.sky = SkyEnhancementSettings(enabled: true, skyVibrance: 0.85)

        var target = AdjustmentSettings()
        target.exposureEV = 0.0
        target.temperature = 0.0
        target.contrast = 1.0
        target.portrait = PortraitRefinementSettings(blemishStrength: 0.0)
        target.sky = SkyEnhancementSettings(enabled: false)

        var targetLUT = "original"
        let sourceLUT = "film_gold"

        // Merge only color grading and LUT
        let options = AdjustmentSyncOptions.colorGradingOnly
        let result = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: options,
            sourceLUT: sourceLUT,
            targetLUT: &targetLUT
        )

        // Color tools & LUT should be copied
        XCTAssertEqual(result.colorTools?.hsl?.red.saturation, 0.50)
        XCTAssertEqual(targetLUT, "film_gold")

        // Unselected basic tone, portrait and sky MUST remain unchanged
        XCTAssertEqual(result.exposureEV, 0.0, "基础曝光未被选中，应保持目标原样。")
        XCTAssertEqual(result.contrast, 1.0, "基础对比度未被选中，应保持目标原样。")
        XCTAssertEqual(result.portrait?.blemishStrength, 0.0, "人像精修未被选中，应保持目标原样。")
        XCTAssertEqual(result.sky?.enabled, false, "天空增强未被选中，应保持目标原样。")
    }

    func testSelectiveMergeProtectsLocalMasksAndRepairBrushByDefault() {
        var source = AdjustmentSettings()
        source.exposureEV = 0.5
        source.masks = [
            LocalMask(name: "Face Mask", points: [MaskPoint(x: 0.2, y: 0.2), MaskPoint(x: 0.4, y: 0.4)])
        ]
        source.repairBrush = RepairBrushSettings(
            strokes: [RepairStroke(mode: .heal, points: [MaskPoint(x: 0.5, y: 0.5)], radius: 10, strength: 1.0)]
        )

        var target = AdjustmentSettings()
        target.exposureEV = -0.2
        target.masks = [
            LocalMask(name: "Sky Mask", points: [MaskPoint(x: 0.1, y: 0.9), MaskPoint(x: 0.9, y: 0.9)])
        ]
        target.repairBrush = RepairBrushSettings(
            strokes: [RepairStroke(mode: .clone, points: [MaskPoint(x: 0.1, y: 0.1)], radius: 15, strength: 0.8)]
        )

        var targetLUT = "lutA"
        let options = AdjustmentSyncOptions.allAdjustments // By default, localMasks and repairBrush are false

        let merged = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: options,
            sourceLUT: "lutB",
            targetLUT: &targetLUT
        )

        // Exposure & LUT should be updated
        XCTAssertEqual(merged.exposureEV, 0.5)
        XCTAssertEqual(targetLUT, "lutB")

        // Target's masks & repair strokes MUST be preserved 100%
        XCTAssertEqual(merged.masks.count, 1)
        XCTAssertEqual(merged.masks.first?.name, "Sky Mask")
        XCTAssertEqual(merged.repairBrush?.strokes.count, 1)
        XCTAssertEqual(merged.repairBrush?.strokes.first?.mode, .clone)
    }

    func testSelectiveMergeOptInCopiesLocalMasks() {
        var source = AdjustmentSettings()
        source.masks = [
            LocalMask(name: "Imported Mask", points: [MaskPoint(x: 0.3, y: 0.3)])
        ]

        var target = AdjustmentSettings()
        target.masks = []

        var targetLUT = "none"
        var options = AdjustmentSyncOptions.none
        options.localMasks = true // Explicit opt-in

        let merged = AdjustmentSyncEngine.merge(
            source: source,
            into: target,
            options: options,
            sourceLUT: nil,
            targetLUT: &targetLUT
        )

        XCTAssertEqual(merged.masks.count, 1)
        XCTAssertEqual(merged.masks.first?.name, "Imported Mask")
    }

    func testPhotoAttributeRecordAdjustmentsPersistenceRoundTrip() throws {
        var adjustments = AdjustmentSettings()
        adjustments.exposureEV = 0.75
        adjustments.portrait = PortraitRefinementSettings(blemishStrength: 0.6)
        adjustments.sky = SkyEnhancementSettings(enabled: true, skyVibrance: 0.8)

        let record = PhotoAttributeRecord(
            relativePath: "portrait_001.jpg",
            fileSize: 1048576,
            modificationTimestamp: 1700000000.0,
            rating: 5,
            isRejected: false,
            qualityReport: nil,
            adjustments: adjustments,
            lutIdentifier: "kodak_gold",
            updatedAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PhotoAttributeRecord.self, from: data)

        XCTAssertEqual(decoded.relativePath, "portrait_001.jpg")
        XCTAssertEqual(decoded.rating, 5)
        XCTAssertEqual(decoded.adjustments?.exposureEV, 0.75)
        XCTAssertEqual(decoded.adjustments?.portrait?.blemishStrength, 0.6)
        XCTAssertEqual(decoded.adjustments?.sky?.skyVibrance, 0.8)
        XCTAssertEqual(decoded.lutIdentifier, "kodak_gold")
    }

    func testFolderCatalogBackwardCompatibilityWithVersion1JSON() throws {
        // Synthesize a legacy version 1 catalog JSON that does NOT have adjustments or lutIdentifier fields
        let legacyJSON = """
        {
            "version": 1,
            "rootPath": "/Users/test/Photos",
            "records": {
                "img1.jpg": {
                    "relativePath": "img1.jpg",
                    "fileSize": 2048,
                    "modificationTimestamp": 1690000000.0,
                    "rating": 4,
                    "isRejected": false,
                    "updatedAt": "2026-11-01T12:00:00Z"
                }
            },
            "updatedAt": "2026-11-01T12:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(FolderCatalog.self, from: legacyJSON)

        XCTAssertEqual(catalog.records.count, 1)
        let rec = catalog.records["img1.jpg"]
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.rating, 4)
        XCTAssertFalse(rec?.isRejected ?? true)
        XCTAssertNil(rec?.adjustments, "旧版 catalog 解码时 adjustments 应优雅降级为 nil。")
        XCTAssertNil(rec?.lutIdentifier, "旧版 catalog 解码时 lutIdentifier 应优雅降级为 nil。")
    }

    func testPhotoItemPerPhotoAdjustments() {
        let url = URL(fileURLWithPath: "/tmp/sample.jpg")
        var custom = AdjustmentSettings()
        custom.exposureEV = -0.5
        custom.temperature = -10.0

        let item = PhotoItem(
            url: url,
            relativePath: "sample.jpg",
            rating: 3,
            isRejected: false,
            adjustments: custom,
            lutIdentifier: "fuji_pro"
        )

        XCTAssertEqual(item.rating, 3)
        XCTAssertEqual(item.adjustments?.exposureEV, -0.5)
        XCTAssertEqual(item.adjustments?.temperature, -10.0)
        XCTAssertEqual(item.lutIdentifier, "fuji_pro")
    }
}

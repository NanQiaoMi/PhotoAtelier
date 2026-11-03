import XCTest
import Foundation
import CoreImage
@testable import PhotoCore

final class BatchTests: XCTestCase {
    func testAutomaticBatchAnalyzesEachFileAndRecordsItsOwnEffectiveExposure() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = PhotoEngine().context
        var export = ExportSettings(); export.format = .png
        for (name, value) in [("dark.png", 0.06), ("bright.png", 0.55)] {
            let image = CIImage(color: CIColor(red: value, green: value, blue: value, alpha: 1, colorSpace: space)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
            try PhotoExporter.write(image: image, to: input.appendingPathComponent(name),
                                    settings: export, sourceProperties: [:], context: context)
        }
        let loaded = try PhotoLoader.load(url: input.appendingPathComponent("dark.png"), lensCorrection: false)
        let baseline = AdjustmentSettings()
        let analysis = try PhotoAnalyzer().analyze(image: loaded.image, properties: loaded.properties, baseline: baseline)
        let selected = try XCTUnwrap(analysis.proposals.first { $0.id == "bright" })
        var refined = selected.settings; refined.exposureEV += 0.1
        let automatic = AutomaticBatchRecipe(styleID: "bright", baseline: baseline, referenceSettings: selected.settings)
        let summary = try BatchProcessor().run(items: PhotoLoader.scan(folder: input, recursive: false),
                                               inputRoot: input, outputRoot: output,
                                               recipe: Recipe(adjustments: refined, automatic: automatic),
                                               lut: nil, cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(summary.succeeded, 2); XCTAssertEqual(summary.failed, 0)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(summary.manifestURL))) as? [String: Any])
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        var exposure: [String: Double] = [:]
        for entry in entries {
            let report = try XCTUnwrap(entry["report"] as? [String: Any])
            let evidence = try XCTUnwrap(report["analysis"] as? [String: Any])
            XCTAssertEqual(evidence["selectedProposal"] as? String, "bright")
            XCTAssertNotNil(evidence["metrics"])
            let scene = try XCTUnwrap(evidence["sceneAssessment"] as? [String: Any])
            XCTAssertEqual(scene["requestedIntent"] as? String, "automatic")
            XCTAssertNotNil(scene["evidence"])
            let applied = try XCTUnwrap(evidence["applied"] as? [String: Any])
            exposure[try XCTUnwrap(entry["input"] as? String)] = try XCTUnwrap(applied["exposureEV"] as? Double)
        }
        XCTAssertGreaterThan(try XCTUnwrap(exposure["dark.png"]), try XCTUnwrap(exposure["bright.png"]))
    }

    func testRejectsInputOutputOverlapBeforeCreatingOutput() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let output = input.appendingPathComponent("nested-output", isDirectory: true)

        XCTAssertThrowsError(try BatchProcessor().run(
            items: [], inputRoot: input, outputRoot: output, recipe: Recipe(), lut: nil,
            cancellation: CancellationToken(), onEvent: { _ in }
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testBadPhotoIsRecordedAndLaterPhotosStillComplete() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: input.appendingPathComponent("broken.png"))
        try TestFiles.writeFixture(to: input.appendingPathComponent("valid.png"), width: 3, height: 2)
        let items = try PhotoLoader.scan(folder: input, recursive: true)

        let summary = try BatchProcessor().run(
            items: items, inputRoot: input, outputRoot: output, recipe: Recipe(), lut: nil,
            cancellation: CancellationToken(), onEvent: { _ in }
        )

        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertFalse(summary.cancelled)
        let manifestURL = try XCTUnwrap(summary.manifestURL)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.filter { $0["status"] as? String == "completed" }.count, 1)
        XCTAssertEqual(entries.filter { $0["status"] as? String == "failed" }.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("valid_graded.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.appendingPathComponent("valid.png").path))
    }

    func testPreCancelledRunWritesSnapshotButNoPhotoOutput() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let photo = input.appendingPathComponent("one.png")
        try TestFiles.writeFixture(to: photo, width: 2, height: 2)
        let token = CancellationToken()
        token.cancel()

        let summary = try BatchProcessor().run(
            items: try PhotoLoader.scan(folder: input, recursive: false),
            inputRoot: input, outputRoot: output, recipe: Recipe(), lut: nil,
            cancellation: token, onEvent: { _ in }
        )

        XCTAssertEqual(summary.succeeded, 0)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertTrue(summary.cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(summary.manifestURL).path))
        let photoOutputs = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpg" }
        XCTAssertTrue(photoOutputs.isEmpty)
    }

    func testRecipeSnapshotPreparationFailureIsVisible() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let outputFile = temp.appendingPathComponent("output-file")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: outputFile.path, contents: Data("occupied".utf8)))

        XCTAssertThrowsError(try BatchProcessor().run(
            items: [], inputRoot: input, outputRoot: outputFile, recipe: Recipe(), lut: nil,
            cancellation: CancellationToken(), onEvent: { _ in }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("配方快照"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: outputFile), Data("occupied".utf8))
    }

    func testExplicitLUTReferenceCannotSilentlyFallBackWhenMissing() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        var recipe = Recipe()
        recipe.lutIdentifier = "missing-preset"

        XCTAssertThrowsError(try BatchProcessor().run(
            items: [], inputRoot: input, outputRoot: output, recipe: recipe, lut: nil,
            cancellation: CancellationToken(), onEvent: { _ in }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("LUT"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testPortraitRecipeV10BatchRecordsNoFaceSkipInManifest() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try TestFiles.writeFixture(to: input.appendingPathComponent("portrait-1.png"), width: 48, height: 32)

        var settings = AdjustmentSettings()
        settings.portrait = PortraitRefinementSettings(blemishStrength: 0.4, teethWhiten: 0.2)
        var recipe = Recipe(adjustments: settings)
        recipe.version = 10
        let summary = try BatchProcessor().run(items: PhotoLoader.scan(folder: input, recursive: false),
                                               inputRoot: input, outputRoot: output,
                                               recipe: recipe, lut: nil,
                                               cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(summary.failed, 0)

        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: XCTUnwrap(summary.manifestURL))) as? [String: Any])
        let manifestRecipe = try XCTUnwrap(manifest["recipe"] as? [String: Any])
        XCTAssertEqual(manifestRecipe["version"] as? Int, 10, "含有非中性人像字段的批量配方必须记录为 v10")
        let manifestAdjustments = try XCTUnwrap(manifestRecipe["adjustments"] as? [String: Any])
        let manifestPortrait = try XCTUnwrap(manifestAdjustments["portrait"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(manifestPortrait["blemishStrength"] as? Double), 0.4, accuracy: 1e-9)

        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        let report = try XCTUnwrap(entries.first?["report"] as? [String: Any])
        let portraitReport = try XCTUnwrap(report["portrait"] as? [String: Any],
                                           "无脸时也必须写人人像跳过状态，而不是省略")
        XCTAssertEqual(portraitReport["applied"] as? Bool, false)
        XCTAssertEqual(portraitReport["faceCount"] as? Int, 0)
        let note = try XCTUnwrap(portraitReport["note"] as? String)
        XCTAssertTrue(note.contains("人像修复已跳过"), "跳过原因必须可在清单中复核：\(note)")
    }
}

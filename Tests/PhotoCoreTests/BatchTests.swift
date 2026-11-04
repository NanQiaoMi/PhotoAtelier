import XCTest
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
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

    func testReferenceColorV10BatchAppliesSharedProfileAndRecordsSkip() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try TestFiles.writeFixture(to: input.appendingPathComponent("color-1.png"), width: 48, height: 32)
        try TestFiles.writeFixture(to: input.appendingPathComponent("color-2.png"), width: 40, height: 40)
        let items = try PhotoLoader.scan(folder: input, recursive: false)
        XCTAssertEqual(items.count, 2)

        // A shared reference profile, measured once and stored in the v10 recipe.
        let profile = try ReferenceColorMatcher.profile(reference: syntheticReference())
        var settings = AdjustmentSettings()
        settings.referenceColor = ReferenceColorSettings(profile: profile, strength: 0.8)
        var recipe = Recipe(adjustments: settings)
        recipe.version = 10

        let appliedOutput = temp.appendingPathComponent("output-applied", isDirectory: true)
        let appliedSummary = try BatchProcessor().run(items: items, inputRoot: input,
                                                      outputRoot: appliedOutput,
                                                      recipe: recipe, lut: nil,
                                                      cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(appliedSummary.succeeded, 2)
        XCTAssertEqual(appliedSummary.failed, 0)

        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: XCTUnwrap(appliedSummary.manifestURL))) as? [String: Any])
        let manifestRecipe = try XCTUnwrap(manifest["recipe"] as? [String: Any])
        XCTAssertEqual(manifestRecipe["version"] as? Int, 10, "含参考图追色的批量配方必须记录为 v10")
        let manifestAdjustments = try XCTUnwrap(manifestRecipe["adjustments"] as? [String: Any])
        let manifestReference = try XCTUnwrap(manifestAdjustments["referenceColor"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(manifestReference["strength"] as? Double), 0.8, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(manifestReference["skinOnly"] as? Bool), false)
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2, "每张照片都必须有自己的追色状态记录")
        for entry in entries {
            let report = try XCTUnwrap(entry["report"] as? [String: Any])
            let referenceReport = try XCTUnwrap(report["referenceColor"] as? [String: Any],
                                                "追色应用状态必须写入清单，而不是省略")
            XCTAssertEqual(referenceReport["applied"] as? Bool, true)
            XCTAssertEqual(try XCTUnwrap(referenceReport["strength"] as? Double), 0.8, accuracy: 1e-9)
            XCTAssertEqual(referenceReport["algorithmVersion"] as? Int,
                           ReferenceColorProfile.currentAlgorithmVersion)
        }

        // Skin-limited recipes on a face-less synthetic corpus must record an
        // explicit skip instead of silently applying a global match.
        var skinOnly = AdjustmentSettings()
        skinOnly.referenceColor = ReferenceColorSettings(profile: profile, strength: 0.8, skinOnly: true)
        var skinRecipe = Recipe(adjustments: skinOnly)
        skinRecipe.version = 10
        let skippedOutput = temp.appendingPathComponent("output-skipped", isDirectory: true)
        let skippedSummary = try BatchProcessor().run(items: items, inputRoot: input,
                                                      outputRoot: skippedOutput,
                                                      recipe: skinRecipe, lut: nil,
                                                      cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(skippedSummary.succeeded, 2)
        let skippedManifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: XCTUnwrap(skippedSummary.manifestURL))) as? [String: Any])
        let skippedEntries = try XCTUnwrap(skippedManifest["entries"] as? [[String: Any]])
        for entry in skippedEntries {
            let report = try XCTUnwrap(entry["report"] as? [String: Any])
            let referenceReport = try XCTUnwrap(report["referenceColor"] as? [String: Any])
            XCTAssertEqual(referenceReport["applied"] as? Bool, false)
            XCTAssertEqual(referenceReport["skinOnly"] as? Bool, true)
            let note = try XCTUnwrap(referenceReport["note"] as? String)
            XCTAssertTrue(note.contains("皮肤限定"), "跳过原因必须可在清单中复核：\(note)")
        }
    }

    private func syntheticReference(width: Int = 32, height: Int = 32) -> CIImage {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let t = Float(x) / Float(max(width - 1, 1))
                let offset = (y * width + x) * 4
                pixels[offset] = 0.55 + 0.30 * t
                pixels[offset + 1] = 0.38
                pixels[offset + 2] = 0.22 + 0.18 * t
                pixels[offset + 3] = 1
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data,
                       bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                       size: CGSize(width: width, height: height),
                       format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    }

    func testFileNameTemplateExpandsTokensAndManifestRecordsExportPlan() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try TestFiles.writeFixture(to: input.appendingPathComponent("alpha.png"), width: 8, height: 6)
        try TestFiles.writeFixture(to: input.appendingPathComponent("beta.png"), width: 8, height: 6)

        var export = ExportSettings()
        export.format = .png
        export.suffix = "_v"
        export.fileNameTemplate = "{name}{suffix}-{index}"
        var recipe = Recipe()
        recipe.version = 10
        recipe.export = export
        let summary = try BatchProcessor().run(
            items: PhotoLoader.scan(folder: input, recursive: false),
            inputRoot: input, outputRoot: output, recipe: recipe, lut: nil,
            cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(summary.succeeded, 2)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("alpha_v-1.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("beta_v-2.png").path))

        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: XCTUnwrap(summary.manifestURL))) as? [String: Any])
        XCTAssertEqual(manifest["version"] as? Int, 4)
        let exportSummary = try XCTUnwrap(manifest["exportSummary"] as? [String])
        XCTAssertTrue(exportSummary.contains("format=png"), "\(exportSummary)")
        XCTAssertTrue(exportSummary.contains("resize=none"), "\(exportSummary)")
        XCTAssertTrue(exportSummary.contains("stripMetadata=true"), "\(exportSummary)")
        XCTAssertTrue(exportSummary.contains { $0.hasPrefix("fileNameTemplate={name}{suffix}-{index}") },
                      "\(exportSummary)")
        let outputs = (try XCTUnwrap(manifest["entries"] as? [[String: Any]]))
            .compactMap { $0["output"] as? String }.sorted()
        XCTAssertEqual(outputs, ["alpha_v-1.png", "beta_v-2.png"])
    }

    func testTemplateRejectsUnknownTokenAndPathSeparatorBeforeOutputDir() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try TestFiles.writeFixture(to: input.appendingPathComponent("one.png"), width: 4, height: 3)
        let items = try PhotoLoader.scan(folder: input, recursive: false)
        for (index, template) in ["{bogus}", "{name}/{index}", ""].enumerated() {
            let output = temp.appendingPathComponent("output-\(index)", isDirectory: true)
            var recipe = Recipe()
            recipe.version = 10
            recipe.export.fileNameTemplate = template
            XCTAssertThrowsError(try BatchProcessor().run(
                items: items, inputRoot: input, outputRoot: output, recipe: recipe, lut: nil,
                cancellation: CancellationToken(), onEvent: { _ in })) { error in
                XCTAssertTrue(error.localizedDescription.contains("文件名模板"), error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testBatchResizeProducesExpectedPixelsAndRepeatedRunNeverOverwrites() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try TestFiles.writeFixture(to: input.appendingPathComponent("square.png"), width: 64, height: 64)

        var export = ExportSettings()
        export.format = .png
        export.resize = ExportResizeSettings(mode: .longEdge, longEdge: 32)
        var recipe = Recipe()
        recipe.version = 10
        recipe.export = export
        let items = try PhotoLoader.scan(folder: input, recursive: false)
        let first = try BatchProcessor().run(items: items, inputRoot: input, outputRoot: output,
                                             recipe: recipe, lut: nil,
                                             cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(first.succeeded, 1)
        let firstURL = output.appendingPathComponent("square_graded.png")
        let pixels = try TestFiles.imagePixelSize(firstURL)
        XCTAssertEqual(pixels.width, 32)
        XCTAssertEqual(pixels.height, 32)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: XCTUnwrap(first.manifestURL))) as? [String: Any])
        let exportSummary = try XCTUnwrap(manifest["exportSummary"] as? [String])
        XCTAssertTrue(exportSummary.contains("resize=longEdge:32"), "\(exportSummary)")

        // writeUnique's no-overwrite contract is unchanged: a second run keeps both files.
        let second = try BatchProcessor().run(items: items, inputRoot: input, outputRoot: output,
                                              recipe: recipe, lut: nil,
                                              cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(second.succeeded, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("square_graded_2.png").path))
        XCTAssertEqual(try TestFiles.imagePixelSize(firstURL).width, 32)
    }

    // MARK: - P1-7 watermark batch dual version

    func testWatermarkV11BatchDualVersionWritesBothFilesAndRecordsManifest() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        for name in ["one.png", "two.png"] {
            try TestFiles.writeFixture(to: input.appendingPathComponent(name), width: 64, height: 48)
        }
        var export = ExportSettings()
        export.format = .png
        export.watermark = WatermarkSettings(text: "WM", anchor: .bottomRight,
                                             opacity: 1, scale: 8, color: .white)
        export.watermarkDualVersion = true
        var recipe = Recipe(export: export)
        recipe.version = 11
        let items = try PhotoLoader.scan(folder: input, recursive: false)
        let summary = try BatchProcessor().run(items: items, inputRoot: input, outputRoot: output,
                                               recipe: recipe, lut: nil,
                                               cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(summary.succeeded, 2)
        XCTAssertEqual(summary.failed, 0)

        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: XCTUnwrap(summary.manifestURL))) as? [String: Any])
        XCTAssertEqual(manifest["version"] as? Int, 4, "水印双版本清单需记录到当前 schema 版本")
        let manifestRecipe = try XCTUnwrap(manifest["recipe"] as? [String: Any])
        XCTAssertEqual(manifestRecipe["version"] as? Int, 11)
        let exportSummary = try XCTUnwrap(manifest["exportSummary"] as? [String])
        XCTAssertTrue(exportSummary.contains("watermark=text"), "\(exportSummary)")
        XCTAssertTrue(exportSummary.contains("watermarkAnchor=bottomRight"), "\(exportSummary)")
        XCTAssertTrue(exportSummary.contains("watermarkDualVersion=true"), "\(exportSummary)")
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        for entry in entries {
            XCTAssertEqual(entry["watermarkApplied"] as? Bool, true)
            let watermarkedRelative = try XCTUnwrap(entry["output"] as? String)
            let cleanRelative = try XCTUnwrap(entry["watermarkFreeOutput"] as? String)
            XCTAssertTrue(cleanRelative.hasSuffix("_nowatermark.png"), cleanRelative)
            let watermarkedPixels = try TestFiles.rgba8Pixels(output.appendingPathComponent(watermarkedRelative))
            let cleanPixels = try TestFiles.rgba8Pixels(output.appendingPathComponent(cleanRelative))
            let watermarkedBright = brightPixelCount(watermarkedPixels, threshold: 240)
            let cleanBright = brightPixelCount(cleanPixels, threshold: 240)
            XCTAssertGreaterThan(watermarkedBright, cleanBright + 50,
                                 "带水印版本必须有可见白色水印像素")
            XCTAssertEqual(cleanBright, 0, "无水印版本不应出现水印像素")
        }
        let firstRunFiles = try pngFiles(in: output)
        XCTAssertEqual(firstRunFiles.count, 4, "2 张 × 带/无水印 = 4 个文件")
        var firstContents: [String: Data] = [:]
        for url in firstRunFiles { firstContents[url.lastPathComponent] = try Data(contentsOf: url) }

        // Second run into the same directory: both versions stay non-overwriting.
        let second = try BatchProcessor().run(items: items, inputRoot: input, outputRoot: output,
                                              recipe: recipe, lut: nil,
                                              cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(second.succeeded, 2)
        let allFiles = try pngFiles(in: output)
        XCTAssertEqual(allFiles.count, 8, "第二次运行不得覆盖第一次输出")
        for (name, content) in firstContents {
            let url = output.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "第一次输出 \(name) 被覆盖删除")
            XCTAssertEqual(try Data(contentsOf: url), content, "第一次输出 \(name) 被覆盖")
        }
    }

    func testWatermarkBatchSingleVersionRecordsAppliedAndNoCleanCopy() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try TestFiles.writeFixture(to: input.appendingPathComponent("single.png"), width: 48, height: 32)
        var export = ExportSettings()
        export.format = .png
        export.watermark = WatermarkSettings(text: "WM", anchor: .bottomRight, opacity: 1, scale: 2)
        var recipe = Recipe(export: export)
        recipe.version = 11
        let summary = try BatchProcessor().run(
            items: PhotoLoader.scan(folder: input, recursive: false),
            inputRoot: input, outputRoot: output, recipe: recipe, lut: nil,
            cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(try pngFiles(in: output).count, 1, "单版本只输出一个文件")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: XCTUnwrap(summary.manifestURL))) as? [String: Any])
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["watermarkApplied"] as? Bool, true)
        XCTAssertNil(entry["watermarkFreeOutput"] as? String)
        let exportSummary = try XCTUnwrap(manifest["exportSummary"] as? [String])
        XCTAssertTrue(exportSummary.contains("watermarkDualVersion=false"), "\(exportSummary)")
    }

    func testWatermarkBatchMissingImageFailsPerPhotoWithoutStrayOutputs() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try TestFiles.writeFixture(to: input.appendingPathComponent("photo.png"), width: 32, height: 24)
        var export = ExportSettings()
        export.format = .png
        export.watermark = WatermarkSettings(kind: .image,
                                             imagePath: temp.appendingPathComponent("missing.png").path,
                                             opacity: 1)
        var recipe = Recipe(export: export)
        recipe.version = 11
        let summary = try BatchProcessor().run(
            items: PhotoLoader.scan(folder: input, recursive: false),
            inputRoot: input, outputRoot: output, recipe: recipe, lut: nil,
            cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(summary.succeeded, 0, "水印图片缺失时该照片必须失败而不是静默导出无水印版")
        XCTAssertEqual(summary.failed, 1)
        XCTAssertTrue(try pngFiles(in: output).isEmpty, "失败项不得留下半成品输出")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: XCTUnwrap(summary.manifestURL))) as? [String: Any])
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["status"] as? String, "failed")
        let message = try XCTUnwrap(entry["message"] as? String)
        XCTAssertTrue(message.contains("水印图片"), message)
    }

    private func pngFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func brightPixelCount(_ pixels: TestFiles.RGBA8Pixels, threshold: Int) -> Int {
        var count = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let pixel = pixels.pixel(x: x, y: y)
                let luminance = (Int(pixel.red) + Int(pixel.green) + Int(pixel.blue)) / 3
                if luminance >= threshold { count += 1 }
            }
        }
        return count
    }

    // MARK: - B6 customer delivery page integration (manifest v4)

    func testBatchDeliveryPageGeneratesAlbumAndManifestV4() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try makeMetadataFixtureJPEG(at: input.appendingPathComponent("one.jpg"), width: 600, height: 400)
        try TestFiles.writeFixture(to: input.appendingPathComponent("two.png"), width: 64, height: 48)

        var export = ExportSettings()
        export.format = .png
        var delivery = DeliverySettings()
        delivery.title = "客户交付"
        delivery.columnCount = 2
        delivery.thumbnailMaxDimension = 320
        delivery.previewMaxDimension = 640
        delivery.includeContactSheet = true
        delivery.contactSheetColumns = 2
        export.deliveryPage = delivery
        var recipe = Recipe(export: export)
        recipe.version = 12

        let items = try PhotoLoader.scan(folder: input, recursive: false)
        let summary = try BatchProcessor().run(items: items, inputRoot: input, outputRoot: output,
                                                recipe: recipe, lut: nil,
                                                cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(summary.succeeded, 2)
        XCTAssertEqual(summary.failed, 0)

        let manifest = try manifestObject(summary)
        XCTAssertEqual(manifest["version"] as? Int, 4, "交付页集成需要清单 schema v4")
        let manifestRecipe = try XCTUnwrap(manifest["recipe"] as? [String: Any])
        XCTAssertEqual(manifestRecipe["version"] as? Int, 12)
        let exportSummary = try XCTUnwrap(manifest["exportSummary"] as? [String])
        XCTAssertTrue(exportSummary.contains("deliveryPage=on"), "\(exportSummary)")
        XCTAssertTrue(exportSummary.contains("deliveryColumns=2"), "\(exportSummary)")
        XCTAssertTrue(exportSummary.contains("deliveryContactSheet=true"), "\(exportSummary)")
        XCTAssertTrue(exportSummary.contains("deliveryWatermarkedPreviews=false"), "\(exportSummary)")

        let record = try XCTUnwrap(manifest["deliveryPage"] as? [String: Any])
        let directory = try XCTUnwrap(record["directory"] as? String)
        let htmlRelative = try XCTUnwrap(record["html"] as? String)
        let contactRelative = try XCTUnwrap(record["contactSheet"] as? String)
        XCTAssertEqual(record["photoCount"] as? Int, 2)
        let recordedSettings = try XCTUnwrap(record["settings"] as? [String: Any])
        XCTAssertEqual(recordedSettings["title"] as? String, "客户交付")
        XCTAssertEqual(recordedSettings["columnCount"] as? Int, 2)
        XCTAssertEqual(recordedSettings["thumbnailMaxDimension"] as? Int, 320)
        XCTAssertEqual(recordedSettings["includeContactSheet"] as? Bool, true)
        XCTAssertFalse(directory.hasPrefix("/"), "清单必须记录相对路径而不是绝对路径")

        let deliveryDirectory = output.appendingPathComponent(directory)
        let htmlURL = output.appendingPathComponent(htmlRelative)
        let pdfURL = output.appendingPathComponent(contactRelative)
        XCTAssertTrue(FileManager.default.fileExists(atPath: htmlURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))
        let html = try readLatin1(htmlURL)
        XCTAssertEqual(occurrences(of: "<img ", in: html), 2, "HTML 图片数量必须等于成功导出的照片数")
        XCTAssertFalse(html.lowercased().contains("http"), "交付页不得包含外链")
        XCTAssertFalse(html.contains("://"))
        XCTAssertFalse(html.contains(output.path), "交付页不得泄漏本地绝对路径")
        let pdfDocument = try XCTUnwrap(CGPDFDocument(pdfURL as CFURL))
        XCTAssertGreaterThanOrEqual(pdfDocument.numberOfPages, 1)

        // Privacy: the source JPEG carried GPS/camera/serial metadata; all delivery
        // artefacts (HTML/PDF/thumbs/previews) are re-encoded and must be clean.
        let deliveryFiles = try regularFiles(in: deliveryDirectory)
        XCTAssertFalse(deliveryFiles.isEmpty)
        for url in deliveryFiles {
            let text = try readLatin1(url).lowercased()
            for marker in ["secretcam", "secretartist", "serial12345",
                           "gpslatitude", "gpslongitude", "http://", "https://"] {
                XCTAssertFalse(text.contains(marker), "\(url.lastPathComponent) 泄漏 \(marker)")
            }
            XCTAssertFalse(text.contains(temp.path.lowercased()),
                           "\(url.lastPathComponent) 泄漏临时目录绝对路径")
        }

        // A second run must never overwrite the first delivery folder.
        let firstHTMLData = try Data(contentsOf: htmlURL)
        let second = try BatchProcessor().run(items: items, inputRoot: input, outputRoot: output,
                                               recipe: recipe, lut: nil,
                                               cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(second.succeeded, 2)
        let secondManifest = try manifestObject(second)
        let secondRecord = try XCTUnwrap(secondManifest["deliveryPage"] as? [String: Any])
        let secondDirectory = try XCTUnwrap(secondRecord["directory"] as? String)
        XCTAssertNotEqual(secondDirectory, directory, "交付页目录必须唯一，不覆盖第一次交付")
        XCTAssertEqual(try Data(contentsOf: htmlURL), firstHTMLData, "第一次交付页 HTML 被覆盖")
        let deliveryFolders = try FileManager.default.contentsOfDirectory(at: output,
                                                                          includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent.hasPrefix("delivery") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        XCTAssertEqual(deliveryFolders.count, 2)
    }

    func testInvalidDeliverySettingsAndV11GateRejectBeforeOutputDirectory() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try TestFiles.writeFixture(to: input.appendingPathComponent("one.png"), width: 32, height: 24)
        let items = try PhotoLoader.scan(folder: input, recursive: false)

        // Invalid delivery settings must fail before the output folder exists.
        var invalidExport = ExportSettings()
        var invalidDelivery = DeliverySettings()
        invalidDelivery.title = "   "
        invalidExport.deliveryPage = invalidDelivery
        var invalidRecipe = Recipe(export: invalidExport)
        invalidRecipe.version = 12
        let invalidOutput = temp.appendingPathComponent("output-invalid", isDirectory: true)
        XCTAssertThrowsError(try BatchProcessor().run(
            items: items, inputRoot: input, outputRoot: invalidOutput, recipe: invalidRecipe,
            lut: nil, cancellation: CancellationToken(), onEvent: { _ in })) { error in
            XCTAssertTrue(error.localizedDescription.contains("交付页标题"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidOutput.path))

        // A v11 recipe must reject a non-neutral delivery payload (v12 gate).
        var v11Export = ExportSettings()
        v11Export.deliveryPage = DeliverySettings()
        var v11Recipe = Recipe(export: v11Export)
        v11Recipe.version = 11
        let v11Output = temp.appendingPathComponent("output-v11", isDirectory: true)
        XCTAssertThrowsError(try BatchProcessor().run(
            items: items, inputRoot: input, outputRoot: v11Output, recipe: v11Recipe,
            lut: nil, cancellation: CancellationToken(), onEvent: { _ in })) { error in
            XCTAssertTrue(error.localizedDescription.contains("客户交付页"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("12"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: v11Output.path))
    }

    // MARK: - S5 delivery directory install contract

    func testDeliveryDirectoryInstallerIsAtomicAndCleansUpOnFailure() throws {
        let root = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let first = try DeliveryDirectoryInstaller.install(under: output, baseName: "delivery") { temporary in
            try "hello".write(to: temporary.appendingPathComponent("index.html"),
                              atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(first.directory.lastPathComponent, "delivery")
        XCTAssertEqual(try String(contentsOf: first.directory.appendingPathComponent("index.html"),
                                  encoding: .utf8), "hello")

        let second = try DeliveryDirectoryInstaller.install(under: output, baseName: "delivery") { temporary in
            try "second".write(to: temporary.appendingPathComponent("index.html"),
                               atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(second.directory.lastPathComponent, "delivery-2", "已存在的交付目录不得被覆盖")

        struct InstallFailure: Error {}
        XCTAssertThrowsError(try DeliveryDirectoryInstaller.install(under: output, baseName: "delivery") { temporary in
            try "partial".write(to: temporary.appendingPathComponent("partial.html"),
                                atomically: true, encoding: .utf8)
            throw InstallFailure()
        }, "body 失败必须向上抛错") { error in
            XCTAssertTrue(error is InstallFailure)
        }
        let entries = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).sorted()
        XCTAssertEqual(entries, ["delivery", "delivery-2"],
                       "失败后不得残留半成品 delivery 目录或 .delivery-*.tmp 临时目录")
        XCTAssertEqual(try String(contentsOf: first.directory.appendingPathComponent("index.html"),
                                  encoding: .utf8), "hello",
                       "失败的安装不得改动先前成功的交付目录")
    }

    func testBatchDeliveryPageSummaryUsesEffectiveWatermarkedPreviewSettings() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try TestFiles.writeFixture(to: input.appendingPathComponent("one.png"), width: 64, height: 48)

        var export = ExportSettings()
        export.format = .png
        export.watermark = WatermarkSettings(text: "WM", anchor: .bottomRight, opacity: 1, scale: 2)
        var delivery = DeliverySettings()
        delivery.title = "客户交付"
        delivery.columnCount = 2
        delivery.thumbnailMaxDimension = 320
        delivery.previewMaxDimension = 640
        delivery.watermarkedPreviews = false
        export.deliveryPage = delivery
        var recipe = Recipe(export: export)
        recipe.version = 12

        let summary = try BatchProcessor().run(
            items: PhotoLoader.scan(folder: input, recursive: false),
            inputRoot: input, outputRoot: output, recipe: recipe, lut: nil,
            cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(summary.succeeded, 1)
        let manifest = try manifestObject(summary)
        let exportSummary = try XCTUnwrap(manifest["exportSummary"] as? [String])
        XCTAssertTrue(exportSummary.contains("deliveryWatermarkedPreviews=true"),
                      "summary 必须记录生效后的水印提示：\(exportSummary)")
        XCTAssertTrue(exportSummary.contains("watermark=text"), "\(exportSummary)")

        let record = try XCTUnwrap(manifest["deliveryPage"] as? [String: Any])
        let recordedSettings = try XCTUnwrap(record["settings"] as? [String: Any])
        XCTAssertEqual(recordedSettings["watermarkedPreviews"] as? Bool, true,
                       "manifest 记录的生效设置必须与 summary 一致（预览图实际带水印）")
        let manifestRecipe = try XCTUnwrap(manifest["recipe"] as? [String: Any])
        let recipeExport = try XCTUnwrap(manifestRecipe["export"] as? [String: Any])
        let rawDelivery = try XCTUnwrap(recipeExport["deliveryPage"] as? [String: Any])
        XCTAssertEqual(rawDelivery["watermarkedPreviews"] as? Bool, false,
                       "配方快照保留用户原始设置，运行结果记录生效设置")
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["watermarkApplied"] as? Bool, true)
    }

    func testBatchSkipsRejectedAndUnratedPhotosAndRecordsManifest() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        for name in ["rated.png", "unrated.png", "waste.png"] {
            try TestFiles.writeFixture(to: input.appendingPathComponent(name), width: 16, height: 12)
        }
        var items = try PhotoLoader.scan(folder: input, recursive: false)
        for index in items.indices {
            switch items[index].relativePath {
            case "rated.png": items[index].rating = 3
            case "waste.png": items[index].isRejected = true
            default: break
            }
        }

        var export = ExportSettings(); export.format = .png
        var recipe = Recipe(export: export); recipe.version = 12
        var selection = ExportSelectionOptions()
        selection.skipRejectedPhotos = true
        selection.skipUnselectedPhotos = true
        let summary = try BatchProcessor().run(items: items, inputRoot: input, outputRoot: output,
                                               recipe: recipe, lut: nil, selection: selection,
                                               cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(summary.skipped, 2)
        XCTAssertEqual(summary.failed, 0, "跳过的照片不得计入失败")
        XCTAssertEqual(summary.cancelled, false)

        let manifest = try manifestObject(summary)
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 3)
        let skipped = entries.filter { $0["status"] as? String == "skipped" }
        XCTAssertEqual(skipped.count, 2)
        XCTAssertEqual(Set(skipped.compactMap { $0["input"] as? String }),
                       ["unrated.png", "waste.png"])
        for entry in skipped {
            XCTAssertNil(entry["output"] as? String, "被跳过项不得有输出路径")
            XCTAssertNil(entry["report"] as? [String: Any], "被跳过项未处理，不应有处理报告")
        }
        let completed = entries.filter { $0["status"] as? String == "completed" }
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?["input"] as? String, "rated.png")

        let selectionPayload = try XCTUnwrap(manifest["selection"] as? [String: Any],
                                             "清单必须记录本次会话的跳过选项")
        XCTAssertEqual(selectionPayload["skipRejectedPhotos"] as? Bool, true)
        XCTAssertEqual(selectionPayload["skipUnselectedPhotos"] as? Bool, true)
        let exportSummary = try XCTUnwrap(manifest["exportSummary"] as? [String])
        XCTAssertTrue(exportSummary.contains("exportSelection=skipRejected+skipUnselected"))

        // The same session with neutral options exports everything again.
        let allOutput = output.appendingPathComponent("all", isDirectory: true)
        let all = try BatchProcessor().run(items: items, inputRoot: input, outputRoot: allOutput,
                                           recipe: recipe, lut: nil,
                                           cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(all.succeeded, 3)
        XCTAssertEqual(all.skipped, 0)
        let allManifest = try manifestObject(all)
        XCTAssertNil(allManifest["selection"] as? [String: Any],
                     "中性选项不应写入清单 selection")
    }

    private func manifestObject(_ summary: BatchSummary) throws -> [String: Any] {
        let data = try Data(contentsOf: XCTUnwrap(summary.manifestURL))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
        }
        return count
    }

    private func readLatin1(_ url: URL) throws -> String {
        String(data: try Data(contentsOf: url), encoding: .isoLatin1) ?? ""
    }

    private func regularFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    /// JPEG carrying GPS / camera model / serial / artist metadata so the delivery
    /// privacy test proves those markers never survive export + re-encode.
    private func makeMetadataFixtureJPEG(at url: URL, width: Int, height: Int) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AtelierError.imageWrite("测试图像上下文创建失败")
        }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 35.6812,
                kCGImagePropertyGPSLongitude: 139.7671,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitudeRef: "E"
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "SECRETCAM",
                kCGImagePropertyTIFFModel: "SECRETMODEL",
                kCGImagePropertyTIFFArtist: "SECRETARTIST"
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifBodySerialNumber: "SERIAL12345"
            ],
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.jpeg.identifier as CFString,
                                                                1, nil) else {
            throw AtelierError.imageWrite("测试 JPEG 编码器创建失败")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AtelierError.imageWrite("测试 JPEG 写入失败")
        }
    }

    // MARK: - P1-C C6 parallel batch integration

    func testParallelAndSerialBatchExportsAreByteIdenticalAndKeepManifestOrder() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        for name in ["a.png", "b.png", "c.png", "d.png", "e.png"] {
            try TestFiles.writeFixture(to: input.appendingPathComponent(name), width: 64, height: 48)
        }
        var export = ExportSettings(); export.format = .png
        var recipe = Recipe(); recipe.export = export
        let items = try PhotoLoader.scan(folder: input, recursive: true)

        func run(maxConcurrency: Int, output: URL) throws -> BatchSummary {
            try BatchProcessor().run(items: items, inputRoot: input, outputRoot: output,
                                     recipe: recipe, lut: nil, maxConcurrency: maxConcurrency,
                                     cancellation: CancellationToken(), onEvent: { _ in })
        }
        let serialOutput = temp.appendingPathComponent("serial", isDirectory: true)
        let parallelOutput = temp.appendingPathComponent("parallel", isDirectory: true)
        let serial = try run(maxConcurrency: 1, output: serialOutput)
        let parallel = try run(maxConcurrency: 4, output: parallelOutput)
        XCTAssertEqual(serial.succeeded, items.count)
        XCTAssertEqual(parallel.succeeded, items.count)
        XCTAssertEqual(parallel.failed, 0)
        XCTAssertFalse(parallel.cancelled)

        func pngFiles(_ url: URL) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: url.path)
                .filter { $0.hasSuffix(".png") }.sorted()
        }
        let serialFiles = try pngFiles(serialOutput)
        let parallelFiles = try pngFiles(parallelOutput)
        XCTAssertEqual(serialFiles, parallelFiles, "parallel export must keep the same file names")
        for name in serialFiles {
            let serialBytes = try Data(contentsOf: serialOutput.appendingPathComponent(name))
            let parallelBytes = try Data(contentsOf: parallelOutput.appendingPathComponent(name))
            XCTAssertEqual(serialBytes, parallelBytes,
                           "parallel export must be byte-identical to serial export for \(name)")
        }

        func entryOrder(_ summary: BatchSummary) throws -> [String] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: try XCTUnwrap(summary.manifestURL))) as? [String: Any])
            let entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
            return entries.map { "\($0["input"] as? String ?? "?")|\($0["status"] as? String ?? "?")" }
        }
        let serialOrder = try entryOrder(serial)
        let parallelOrder = try entryOrder(parallel)
        XCTAssertEqual(parallelOrder, serialOrder, "manifest entries must be in input order")
        XCTAssertEqual(parallelOrder.map { $0.components(separatedBy: "|")[0] },
                       items.map(\.relativePath))
        XCTAssertTrue(parallelOrder.allSatisfy { $0.hasSuffix("|completed") })
    }

    func testCancelledParallelBatchKeepsOnlyCompletedWholeFilesAndOrderedManifest() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        for index in 0..<8 {
            try TestFiles.writeFixture(to: input.appendingPathComponent(String(format: "photo-%02d.png", index)),
                                       width: 320, height: 240)
        }
        var export = ExportSettings(); export.format = .png
        var recipe = Recipe(); recipe.export = export
        let items = try PhotoLoader.scan(folder: input, recursive: true)
        XCTAssertEqual(items.count, 8)
        let token = CancellationToken()
        let lock = NSLock()
        var completedEvents = 0
        // Cancel once two photos are complete (events are emitted from the worker
        // as each photo finishes), so later photos must stop without partial files.
        let summary = try BatchProcessor().run(items: items, inputRoot: input, outputRoot: output,
                                               recipe: recipe, lut: nil, maxConcurrency: 3,
                                               cancellation: token) { event in
            guard event.kind == .completed else { return }
            lock.lock()
            completedEvents += 1
            if completedEvents >= 2 { token.cancel() }
            lock.unlock()
        }
        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(summary.failed, 0, "cancelled work must never be counted as a photo failure")
        XCTAssertLessThan(summary.succeeded, items.count)
        let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        XCTAssertEqual(files.count, summary.succeeded, "no partial or orphan output may survive a cancel")
        for file in files {
            // Every surviving file is a complete decodable image.
            _ = try PhotoLoader.load(url: file, lensCorrection: false)
        }
        XCTAssertFalse(files.isEmpty)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: try XCTUnwrap(summary.manifestURL))) as? [String: Any])
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, items.count, "every input must be recorded exactly once")
        XCTAssertEqual(entries.map { $0["input"] as? String ?? "" }, items.map(\.relativePath))
        XCTAssertEqual(entries.filter { $0["status"] as? String == "completed" }.count, summary.succeeded)
        XCTAssertEqual(entries.filter { $0["status"] as? String == "cancelled" }.count,
                       items.count - summary.succeeded)
        XCTAssertEqual(entries.filter { $0["status"] as? String == "failed" }.count, 0)
        for entry in entries where entry["status"] as? String == "completed" {
            let relative = try XCTUnwrap(entry["output"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent(relative).path))
        }
    }

    func testParallelFailureIsolationAndConcurrencyClamp() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: input.appendingPathComponent("broken.png"))
        for name in ["valid-a.png", "valid-b.png", "valid-c.png"] {
            try TestFiles.writeFixture(to: input.appendingPathComponent(name), width: 32, height: 24)
        }
        let items = try PhotoLoader.scan(folder: input, recursive: true)
        XCTAssertEqual(items.count, 4)
        // A request outside 1...8 is clamped instead of crashing the export.
        let summary = try BatchProcessor().run(items: items, inputRoot: input, outputRoot: output,
                                               recipe: Recipe(), lut: nil, maxConcurrency: 64,
                                               cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(summary.succeeded, 3)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertFalse(summary.cancelled)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: try XCTUnwrap(summary.manifestURL))) as? [String: Any])
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["input"] as? String ?? "" }, items.map(\.relativePath))
        XCTAssertEqual(entries.filter { $0["status"] as? String == "completed" }.count, 3)
        XCTAssertEqual(entries.filter { $0["status"] as? String == "failed" }.count, 1)
    }

}

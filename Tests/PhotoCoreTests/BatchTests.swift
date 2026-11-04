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
        XCTAssertEqual(manifest["version"] as? Int, 3)
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
        XCTAssertEqual(manifest["version"] as? Int, 3, "水印双版本清单需记录到当前 schema 版本")
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
}

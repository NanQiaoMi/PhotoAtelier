// Build after the main agent has rebuilt PhotoCore with the current sources.
// Run from the repository root; the output must be a new Git-ignored directory.
// Example using the existing x86_64 debug objects:
// swiftc -I .build/x86_64-apple-macosx/debug \
//   -I .build/x86_64-apple-macosx/debug/CLensfunBridge.build \
//   Scripts/evaluate_film_luts.swift \
//   .build/x86_64-apple-macosx/debug/PhotoCore.build/*.o \
//   .build/x86_64-apple-macosx/debug/CLensfunBridge.build/CLensfunBridge.c.o \
//   -o /tmp/evaluate-film-luts
// Originals are read only. Artifacts contain anonymous sample IDs and hashes,
// never source filenames or paths; source images are not copied.

import AppKit
import CoreFoundation
import CoreGraphics
import CoreImage
import CoreText
import CryptoKit
import Darwin
import Foundation
import ImageIO
import PhotoCore
import UniformTypeIdentifiers

private enum InputGroup: String, Codable {
    case desktop
    case portrait
    case raw
}

private struct InputSample {
    let id: String
    let group: InputGroup
    let item: PhotoItem
}

private struct RectRecord: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.width)
        height = Double(rect.height)
    }
}

private struct SourceIndexEntry: Codable {
    let id: String
    let sha256Before: String
    let sha256After: String
    let unchanged: Bool
}

private struct SelectedCandidate: Codable {
    let id: String
    let intensity: Double
    let preserveLuminance: Double
    let protectSkin: Double
    let protectNeutrals: Double
    let localProtection: Double
}

private struct LUTRunRecord: Codable {
    let presetID: String
    let presetName: String
    let requestedIntensity: Double
    let fixedProcessingSeconds: Double
    let adaptiveProcessingSeconds: Double
    let selectedCandidate: SelectedCandidate
    let report: LUTAdaptationReport
}

private struct SampleRecord: Codable {
    let id: String
    let group: InputGroup
    let inputWasRAW: Bool
    let sourceWidth: Int
    let sourceHeight: Int
    let previewWidth: Int
    let previewHeight: Int
    let previewBitsPerComponent: Int
    let contentSelection: ContentSelectionReport
    let semanticLabels: [PhotoContentLabel]
    let semanticStatus: String
    let runs: [LUTRunRecord]
    let totalSeconds: Double
}

private struct HighResolutionRun: Codable {
    let outputColorSpace: OutputColorSpace
    let presetID: String
    let roiBounds: RectRecord
    let roiMaximumRGBAByteDifference: Int
    let roiMaximumErrorOver255: Double
    let fullAndROILUTReportsExactlyEqual: Bool
    let reportDifferencePaths: [String]
    let tiffBitsPerComponent: Int
    let tiffMaximumRGBAByteDifference: Int
    let tiffMaximumErrorOver255: Double
    let processingSeconds: Double
    let report: LUTAdaptationReport
}

private struct HighResolutionRecord: Codable {
    let id: String
    let group: InputGroup
    let inputWasRAW: Bool
    let width: Int
    let height: Int
    let contentSelection: ContentSelectionReport
    let semanticLabels: [PhotoContentLabel]
    let semanticStatus: String
    let runs: [HighResolutionRun]
}

private struct RicohTableNumbers: Codable {
    let size: Int
    let interpretationAssumption: String
    let outputOutsideUnitFraction: Double
    let neutralColorShift: Double
    let neutralToneReversals: Int
}

private struct RicohSampleRun: Codable {
    let sampleID: String
    let fixedProcessingSeconds: Double?
    let adaptiveProcessingSeconds: Double?
    let adaptiveReport: LUTAdaptationReport?
    let failureType: String?
}

private struct RicohCubeRecord: Codable {
    let cubeID: String
    let sha256: String
    let tableNumbers: RicohTableNumbers?
    let failureType: String?
    let sampleRuns: [RicohSampleRun]
}

private struct RicohDiagnostic: Codable {
    let interpretationNotice: String
    let mode: String
    let requestedIntensity: Double
    let cubesConsidered: Int
    let samplesPerCube: Int
    let cubes: [RicohCubeRecord]
}

private struct RunSummary: Codable {
    let status: String
    let sampleCount: Int
    let presetCount: Int
    let requestedIntensity: Double
    let previewMaximumEdge: Int
    let previewPixelFormat: String
    let contactSheetCount: Int
    let adaptiveReportCount: Int
    let reportsWithNineCandidates: Int
    let reportsWithoutIntroducedHighlightsOrShadows: Int
    let highResolutionCaseCount: Int
    let ricohCubeCount: Int
    let ricohFailureCount: Int
    let fullAndROIReportMismatchCount: Int
    let elapsedSeconds: Double
    let privacyNote: String
}

private struct FailureRecord: Codable {
    let status: String
    let code: String
}

private struct PreparedPreview {
    let image: CIImage
    let selections: ContentSelectionResult
    let semantics: LUTSemanticContext
}

private enum EvaluationFailure: Error {
    case check(String)
}

private func failureCode(_ error: Error) -> String {
    if let failure = error as? EvaluationFailure, case let .check(code) = failure { return code }
    return String(reflecting: type(of: error))
}

private let expectedIntensity = 0.65
private let previewLimit = 640

private func require(_ condition: @autoclosure () -> Bool, _ code: String) throws {
    guard condition() else { throw EvaluationFailure.check(code) }
}

private func resolvedPathForNewDirectory(_ url: URL, manager: FileManager) -> String {
    var ancestor = url.standardizedFileURL
    var suffix: [String] = []
    while !manager.fileExists(atPath: ancestor.path), ancestor.path != "/" {
        suffix.insert(ancestor.lastPathComponent, at: 0)
        ancestor.deleteLastPathComponent()
    }
    var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
    for component in suffix { resolved.appendPathComponent(component) }
    return resolved.standardizedFileURL.path
}

private func isSameOrDescendant(_ child: String, of parent: String) -> Bool {
    child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
}

private func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
    isSameOrDescendant(lhs, of: rhs) || isSameOrDescendant(rhs, of: lhs)
}

private func commandOutput(_ executable: URL, arguments: [String], cwd: URL) throws -> (Int32, String) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

private func verifyIgnoredOutput(_ outputPath: String) throws {
    let git = URL(fileURLWithPath: "/usr/bin/git")
    let rootResult = try commandOutput(git, arguments: ["rev-parse", "--show-toplevel"],
                                       cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    try require(rootResult.0 == 0, "notInsideGitRepository")
    let rootPath = URL(fileURLWithPath: rootResult.1.trimmingCharacters(in: .whitespacesAndNewlines))
        .standardizedFileURL.resolvingSymlinksInPath().path
    try require(isSameOrDescendant(outputPath, of: rootPath) && outputPath != rootPath,
                "outputMustBeInsideRepository")
    let relative = String(outputPath.dropFirst(rootPath.count + 1))
    let ignored = try commandOutput(git, arguments: ["check-ignore", "-q", "--no-index", "--", relative],
                                    cwd: URL(fileURLWithPath: rootPath))
    try require(ignored.0 == 0, "outputMustBeGitIgnored")
}

private func sha256(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func sortedItems(_ folder: URL) throws -> [PhotoItem] {
    try PhotoLoader.scan(folder: folder, recursive: false).sorted { $0.url.path < $1.url.path }
}

private func inputURL(_ path: String) -> URL {
    URL(fileURLWithPath: path).standardizedFileURL
}

private func materializeHalfPreview(_ image: CIImage, context: CIContext) throws -> CGImage {
    let extent = image.extent
    try require(!extent.isNull && !extent.isInfinite && extent.width.isFinite && extent.height.isFinite
                && extent.width > 0 && extent.height > 0, "invalidPreviewExtent")
    let scale = min(1, CGFloat(previewLimit) / max(extent.width, extent.height))
    let width = max(1, Int((extent.width * scale).rounded(.up)))
    let height = max(1, Int((extent.height * scale).rounded(.up)))
    try require(max(width, height) <= previewLimit, "previewExceeded640Pixels")
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let normalized = image
        .transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
        .transformed(by: .init(scaleX: scale, y: scale))
        .cropped(to: bounds)
    guard let half = context.createCGImage(normalized, from: bounds, format: .RGBAh,
                                          colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                          deferred: false) else {
        throw EvaluationFailure.check("halfFloatPreviewRenderFailed")
    }
    try require(half.bitsPerComponent == 16, "previewIsNotHalfFloat")
    return half
}

private func materializedRaster(_ image: CIImage, colorSpace: CGColorSpace,
                                context: CIContext) throws -> CGImage {
    let extent = image.extent.integral
    guard extent.width > 0, extent.height > 0,
          let rendered = context.createCGImage(image, from: extent, format: .RGBA8,
                                               colorSpace: colorSpace, deferred: false),
          let data = rendered.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data),
          let provider = CGDataProvider(data: Data(bytes: bytes, count: CFDataGetLength(data)) as CFData),
          let owned = CGImage(width: rendered.width, height: rendered.height,
                              bitsPerComponent: rendered.bitsPerComponent,
                              bitsPerPixel: rendered.bitsPerPixel,
                              bytesPerRow: rendered.bytesPerRow,
                              space: rendered.colorSpace ?? colorSpace,
                              bitmapInfo: rendered.bitmapInfo, provider: provider,
                              decode: nil, shouldInterpolate: false, intent: rendered.renderingIntent) else {
        throw EvaluationFailure.check("rasterMaterializationFailed")
    }
    return owned
}

private func maximumByteDifference(_ lhs: CGImage, _ rhs: CGImage) throws -> Int {
    try require(lhs.width == rhs.width && lhs.height == rhs.height, "comparisonDimensionsDiffer")
    try require(lhs.bitsPerPixel == rhs.bitsPerPixel && lhs.bitsPerComponent == rhs.bitsPerComponent,
                "comparisonPixelFormatsDiffer")
    guard let leftData = lhs.dataProvider?.data, let rightData = rhs.dataProvider?.data,
          let left = CFDataGetBytePtr(leftData), let right = CFDataGetBytePtr(rightData) else {
        throw EvaluationFailure.check("comparisonPixelsUnavailable")
    }
    let bytesPerPixel = lhs.bitsPerPixel / 8
    try require(bytesPerPixel == 4, "comparisonExpectedRGBA8")
    var maximum = 0
    for y in 0..<lhs.height {
        let leftRow = y * lhs.bytesPerRow
        let rightRow = y * rhs.bytesPerRow
        for x in 0..<lhs.width {
            let leftPixel = leftRow + x * bytesPerPixel
            let rightPixel = rightRow + x * bytesPerPixel
            for channel in 0..<bytesPerPixel {
                maximum = max(maximum, abs(Int(left[leftPixel + channel]) - Int(right[rightPixel + channel])))
            }
        }
    }
    return maximum
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw EvaluationFailure.check("contactSheetDestinationFailed")
    }
    CGImageDestinationAddImage(destination, image, nil)
    try require(CGImageDestinationFinalize(destination), "contactSheetWriteFailed")
}

private func writeContactSheet(_ cards: [(String, CGImage)], sampleID: String, to output: URL) throws {
    let cellWidth = 214, cellHeight = 186, columns = 4
    let rows = (cards.count + columns - 1) / columns
    guard let context = CGContext(data: nil, width: cellWidth * columns, height: cellHeight * rows,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: OutputColorSpace.sRGB.cgColorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw EvaluationFailure.check("contactSheetContextFailed")
    }
    context.setFillColor(CGColor(gray: 0.055, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: cellWidth * columns, height: cellHeight * rows))
    context.interpolationQuality = .high
    for (index, card) in cards.enumerated() {
        let originX = CGFloat((index % columns) * cellWidth)
        let originY = CGFloat((rows - 1 - index / columns) * cellHeight)
        let imageWidth = CGFloat(card.1.width), imageHeight = CGFloat(card.1.height)
        let scale = min(204 / imageWidth, 150 / imageHeight)
        let size = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        context.draw(card.1, in: CGRect(x: originX + (204 - size.width) / 2 + 5,
                                        y: originY + 28 + (150 - size.height) / 2,
                                        width: size.width, height: size.height))
        let title = NSAttributedString(string: card.0, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.white
        ])
        context.textPosition = CGPoint(x: originX + 7, y: originY + 8)
        CTLineDraw(CTLineCreateWithAttributedString(title), context)
    }
    guard let image = context.makeImage() else { throw EvaluationFailure.check("contactSheetImageFailed") }
    try writePNG(image, to: output.appendingPathComponent(sampleID + "-film-luts.png"))
}

private func baseSettings() -> AdjustmentSettings {
    var settings = AdjustmentSettings()
    settings.autoExposure = false
    settings.autoWhiteBalance = false
    settings.exposureEV = 0
    settings.temperature = 0
    settings.tint = 0
    settings.contrast = 1
    settings.saturation = 1
    settings.highlights = 0
    settings.shadows = 0
    settings.tonalCurve = nil
    settings.lensCorrection = false
    settings.lensProfileID = nil
    settings.lensCropFactor = 0
    settings.lensFocalLength = 0
    settings.autoStraighten = false
    settings.rotationDegrees = 0
    settings.verticalPerspective = 0
    settings.horizontalPerspective = 0
    settings.lutIntensity = expectedIntensity
    settings.lutColorSpace = .sRGB
    settings.preserveLuminance = 0.65
    settings.protectSkin = 0.65
    settings.protectNeutrals = 0.5
    settings.gamutCompression = 0
    settings.colorHarmony = nil
    settings.creativeEffects = nil
    settings.adaptiveLUT = nil
    settings.masks = []
    return settings
}

private func adaptiveSettings(from base: AdjustmentSettings) -> AdjustmentSettings {
    var settings = base
    settings.adaptiveLUT = AdaptiveLUTSettings()
    return settings
}

private func selectedCandidate(_ report: LUTAdaptationReport) throws -> SelectedCandidate {
    guard let selected = report.candidates.first(where: { $0.id == report.selectedCandidateID }) else {
        throw EvaluationFailure.check("selectedCandidateMissing")
    }
    return SelectedCandidate(id: selected.id, intensity: selected.intensity,
                             preserveLuminance: selected.preserveLuminance,
                             protectSkin: selected.protectSkin,
                             protectNeutrals: selected.protectNeutrals,
                             localProtection: selected.localProtection)
}

private func validateAdaptiveReport(_ report: LUTAdaptationReport) throws {
    try require(report.candidates.count == 9, "adaptiveReportCandidateCountNotNine")
    try require(report.nativeIntroducedHighlights == 0 && report.nativeIntroducedShadows == 0,
                "adaptiveReportIntroducedNativeClipping")
    try require(report.requestedIntensity == expectedIntensity, "adaptiveReportIntensityMismatch")
    let selected = report.candidates.first { $0.id == report.selectedCandidateID }
    try require(selected?.sampleQualityAccepted == true && selected?.nativeSafetyAccepted == true,
                "selectedCandidateMissingQualityOrNativeApproval")
    try require(report.nativeCheckedCandidateIDs?.contains(report.selectedCandidateID) == true,
                "selectedCandidateNotInNativeChecks")
}

private func reportDifferencePaths(_ lhs: LUTAdaptationReport,
                                   _ rhs: LUTAdaptationReport) -> [String] {
    var paths: [String] = []
    if lhs.policyVersion != rhs.policyVersion { paths.append("policyVersion") }
    if lhs.requestedIntensity != rhs.requestedIntensity { paths.append("requestedIntensity") }
    if lhs.selectedCandidateID != rhs.selectedCandidateID { paths.append("selectedCandidateID") }
    if lhs.effectiveIntensity != rhs.effectiveIntensity { paths.append("effectiveIntensity") }
    if lhs.scene != rhs.scene { paths.append("scene") }
    if lhs.contentLabels != rhs.contentLabels { paths.append("contentLabels") }
    if lhs.contentStatus != rhs.contentStatus { paths.append("contentStatus") }
    if lhs.faceStatus != rhs.faceStatus { paths.append("faceStatus") }
    if lhs.faceCount != rhs.faceCount { paths.append("faceCount") }
    if lhs.skinSampleCount != rhs.skinSampleCount { paths.append("skinSampleCount") }
    if lhs.sampleWidth != rhs.sampleWidth { paths.append("sampleWidth") }
    if lhs.sampleHeight != rhs.sampleHeight { paths.append("sampleHeight") }
    if lhs.monochromeLUT != rhs.monochromeLUT { paths.append("monochromeLUT") }
    if lhs.sourceMonochrome != rhs.sourceMonochrome { paths.append("sourceMonochrome") }
    if lhs.nativeCheckedCandidateIDs != rhs.nativeCheckedCandidateIDs { paths.append("nativeCheckedCandidateIDs") }
    if lhs.nativeIntroducedHighlights != rhs.nativeIntroducedHighlights {
        paths.append("nativeIntroducedHighlights")
    }
    if lhs.nativeIntroducedShadows != rhs.nativeIntroducedShadows {
        paths.append("nativeIntroducedShadows")
    }
    if lhs.summary != rhs.summary { paths.append("summary") }
    if lhs.reasons != rhs.reasons { paths.append("reasons") }
    if lhs.scope != rhs.scope { paths.append("scope") }
    if lhs.candidates.count != rhs.candidates.count { paths.append("candidates.count") }
    for index in 0..<min(lhs.candidates.count, rhs.candidates.count) {
        let left = lhs.candidates[index]
        let right = rhs.candidates[index]
        let prefix = "candidates[\(index)]"
        if left.id != right.id { paths.append(prefix + ".id") }
        if left.intensity != right.intensity { paths.append(prefix + ".intensity") }
        if left.preserveLuminance != right.preserveLuminance { paths.append(prefix + ".preserveLuminance") }
        if left.protectSkin != right.protectSkin { paths.append(prefix + ".protectSkin") }
        if left.protectNeutrals != right.protectNeutrals { paths.append(prefix + ".protectNeutrals") }
        if left.localProtection != right.localProtection { paths.append(prefix + ".localProtection") }
        if left.sampleQualityAccepted != right.sampleQualityAccepted { paths.append(prefix + ".sampleQualityAccepted") }
        if left.nativeSafetyAccepted != right.nativeSafetyAccepted { paths.append(prefix + ".nativeSafetyAccepted") }
        if left.accepted != right.accepted { paths.append(prefix + ".accepted") }
        if left.reasons != right.reasons { paths.append(prefix + ".reasons") }
        let leftMetrics = left.metrics
        let rightMetrics = right.metrics
        if leftMetrics.introducedHighlights != rightMetrics.introducedHighlights {
            paths.append(prefix + ".metrics.introducedHighlights")
        }
        if leftMetrics.introducedShadows != rightMetrics.introducedShadows {
            paths.append(prefix + ".metrics.introducedShadows")
        }
        if leftMetrics.addedChroma != rightMetrics.addedChroma { paths.append(prefix + ".metrics.addedChroma") }
        if leftMetrics.hueShift != rightMetrics.hueShift { paths.append(prefix + ".metrics.hueShift") }
        if leftMetrics.neutralTint != rightMetrics.neutralTint { paths.append(prefix + ".metrics.neutralTint") }
        if leftMetrics.skinHueP90Degrees != rightMetrics.skinHueP90Degrees {
            paths.append(prefix + ".metrics.skinHueP90Degrees")
        }
        if leftMetrics.skinChromaGrowthP90 != rightMetrics.skinChromaGrowthP90 {
            paths.append(prefix + ".metrics.skinChromaGrowthP90")
        }
        if leftMetrics.detailLoss != rightMetrics.detailLoss { paths.append(prefix + ".metrics.detailLoss") }
        if leftMetrics.meanChange != rightMetrics.meanChange { paths.append(prefix + ".metrics.meanChange") }
    }
    return paths.sorted()
}

private func encodeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

private func inputSamples(photoFolder: URL, portraitFolder: URL, rawFolder: URL) throws -> [InputSample] {
    let desktop = try sortedItems(photoFolder)
    let portraits = try sortedItems(portraitFolder)
    let raws = try sortedItems(rawFolder).filter { $0.url.pathExtension.lowercased() == "cr2" }
    try require(desktop.count == 13, "desktopFolderMustContain13Photos")
    try require(portraits.count == 3, "portraitFolderMustContain3Photos")
    try require(raws.count == 1, "rawFolderMustContainOneCR2")
    let all = desktop + portraits + raws
    return all.enumerated().map { offset, item in
        let group: InputGroup = offset < desktop.count ? .desktop
            : (offset < desktop.count + portraits.count ? .portrait : .raw)
        return InputSample(id: String(format: "S%03d", offset + 1), group: group, item: item)
    }
}

private func runPreviewSamples(_ samples: [InputSample], output: URL, engine: PhotoEngine,
                               preserveFirstFour: Bool) throws
    -> (records: [SampleRecord], prepared: [String: PreparedPreview], beforeHashes: [String: String]) {
    let presets = FilmLUTCatalog.presets
    try require(presets.count == 5, "filmCatalogMustContainFivePresets")
    var records: [SampleRecord] = []
    var prepared: [String: PreparedPreview] = [:]
    var beforeHashes: [String: String] = [:]
    let fixedBase = baseSettings()
    for (index, sample) in samples.enumerated() {
        let started = Date()
        let record = try autoreleasepool { () throws -> SampleRecord in
            let before = try sha256(sample.item.url)
            beforeHashes[sample.id] = before
            let loaded = try PhotoLoader.load(url: sample.item.url, lensCorrection: false)
            let previewCG = try materializeHalfPreview(loaded.image, context: engine.context)
            let preview = CIImage(cgImage: previewCG)
            let selections = try ContentSelectionAnalyzer.analyze(reference: preview,
                targets: [.faceSkin], context: engine.context)
            let semantics = try LUTSemanticContext.analyze(preview)
            let previewCard = try materializedRaster(preview, colorSpace: OutputColorSpace.sRGB.cgColorSpace,
                                                      context: engine.context)
            var cards: [(String, CGImage)] = [("Original", previewCard)]
            var runs: [LUTRunRecord] = []

            for (presetIndex, preset) in presets.enumerated() {
                var fixed = fixedBase
                fixed.adaptiveLUT = nil
                let fixedStarted = Date()
                let fixedResult = try engine.process(preview, settings: fixed, lut: preset.cube,
                                                     outputColorSpace: .sRGB)
                let fixedSeconds = Date().timeIntervalSince(fixedStarted)
                try require(fixedResult.report.lutAdaptation == nil, "fixedRunUnexpectedAdaptiveReport")
                cards.append(("L\(presetIndex + 1) Fixed", try materializedRaster(
                    fixedResult.image, colorSpace: OutputColorSpace.sRGB.cgColorSpace, context: engine.context)))

                let adaptive = adaptiveSettings(from: fixedBase)
                let adaptiveStarted = Date()
                let adaptiveResult = try engine.process(preview, settings: adaptive, lut: preset.cube,
                    outputColorSpace: .sRGB, preparedContentSelections: selections,
                    preparedLUTContext: semantics)
                let adaptiveSeconds = Date().timeIntervalSince(adaptiveStarted)
                guard let report = adaptiveResult.report.lutAdaptation else {
                    throw EvaluationFailure.check("adaptiveRunMissingReport")
                }
                try validateAdaptiveReport(report)
                cards.append(("L\(presetIndex + 1) Adaptive", try materializedRaster(
                    adaptiveResult.image, colorSpace: OutputColorSpace.sRGB.cgColorSpace, context: engine.context)))
                runs.append(LUTRunRecord(presetID: preset.id, presetName: preset.name,
                    requestedIntensity: expectedIntensity, fixedProcessingSeconds: fixedSeconds,
                    adaptiveProcessingSeconds: adaptiveSeconds, selectedCandidate: try selectedCandidate(report),
                    report: report))
            }
            try writeContactSheet(cards, sampleID: sample.id, to: output)
            if preserveFirstFour && index < 4 {
                prepared[sample.id] = PreparedPreview(image: preview,
                    selections: selections, semantics: semantics)
            }
            return SampleRecord(id: sample.id, group: sample.group,
                inputWasRAW: loaded.report.inputWasRAW,
                sourceWidth: Int(loaded.image.extent.width.rounded(.up)),
                sourceHeight: Int(loaded.image.extent.height.rounded(.up)),
                previewWidth: previewCG.width, previewHeight: previewCG.height,
                previewBitsPerComponent: previewCG.bitsPerComponent,
                contentSelection: selections.report, semanticLabels: semantics.labels,
                semanticStatus: semantics.status, runs: runs, totalSeconds: Date().timeIntervalSince(started))
        }
        records.append(record)
        print("FILM_LUT_SAMPLE \(sample.id) PASS")
        fflush(stdout)
    }
    return (records, prepared, beforeHashes)
}

private func cropTopLeftRegion(_ full: CGImage, imageExtent: CGRect, bounds: CGRect) throws -> CGImage {
    let crop = CGRect(x: bounds.minX - imageExtent.minX,
                      y: imageExtent.maxY - bounds.maxY,
                      width: bounds.width, height: bounds.height).integral
    guard let result = full.cropping(to: crop) else { throw EvaluationFailure.check("nativeRegionCropFailed") }
    return result
}

private func tiffRoundTrip(_ image: CIImage, id: String, colorSpace: OutputColorSpace,
                           output: URL, engine: PhotoEngine) throws -> (Int, Int) {
    let colorSuffix = colorSpace == .sRGB ? "srgb" : "p3"
    let target = output.appendingPathComponent("roundtrip-\(id)-\(colorSuffix).tiff")
    var verified = false
    defer { if verified { try? FileManager.default.removeItem(at: target) } }
    var settings = ExportSettings()
    settings.format = .tiff
    settings.colorSpace = colorSpace
    settings.stripMetadata = true
    try PhotoExporter.write(image: image, to: target, settings: settings,
                            sourceProperties: [:], context: engine.context)
    guard let source = CGImageSourceCreateWithURL(target as CFURL, nil),
          let decodedCG = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw EvaluationFailure.check("tiffReadbackFailed")
    }
    try require(decodedCG.bitsPerComponent == 16, "tiffReadbackNot16Bit")
    let decoded = try PhotoLoader.load(url: target, lensCorrection: false)
    let expected = try materializedRaster(image, colorSpace: colorSpace.cgColorSpace, context: engine.context)
    let actual = try materializedRaster(decoded.image, colorSpace: colorSpace.cgColorSpace, context: engine.context)
    let difference = try maximumByteDifference(expected, actual)
    print("FILM_LUT_TIFF \(id) \(colorSuffix) maxDifference=\(difference)"); fflush(stdout)
    try require(difference <= 2, "tiffRoundTripExceeds2Over255:\(id):\(colorSuffix):\(difference)")
    verified = true
    return (decodedCG.bitsPerComponent, difference)
}

private func runHighResolution(_ selected: [InputSample], sampleRecords: [SampleRecord],
                               output: URL, engine: PhotoEngine) throws -> [HighResolutionRecord] {
    let previews = Dictionary(uniqueKeysWithValues: sampleRecords.map { ($0.id, $0) })
    let presets = FilmLUTCatalog.presets
    let renderer = NativeInspectionRenderer(engine: engine)
    var records: [HighResolutionRecord] = []

    for sample in selected {
        let loaded = try PhotoLoader.load(url: sample.item.url, lensCorrection: false)
        try require(loaded.report.inputWasRAW == (sample.group == .raw), "highResolutionInputKindMismatch")
        let source = loaded.image
        let selections = try ContentSelectionAnalyzer.analyze(reference: source,
            targets: [.faceSkin], context: engine.context)
        let semantics = try LUTSemanticContext.analyze(source)
        if sample.group == .portrait {
            try require(selections.report.faceCount > 0, "highResolutionPortraitFaceNotDetected")
        }
        guard let previewRecord = previews[sample.id] else {
            throw EvaluationFailure.check("highResolutionSampleMissingPreviewRecord")
        }
        let preset: LUTPreset
        if sample.group == .portrait {
            guard let portraitPreset = presets.first(where: { $0.id == "film-fuji-astia" }) else {
                throw EvaluationFailure.check("portraitPresetMissing")
            }
            preset = portraitPreset
        } else {
            guard let rawPreset = presets.first(where: { $0.id == "film-fuji-classic-chrome" }) else {
                throw EvaluationFailure.check("rawPresetMissing")
            }
            preset = rawPreset
        }
        let settings = adaptiveSettings(from: baseSettings())
        var runs: [HighResolutionRun] = []

        for colorSpace in OutputColorSpace.allCases {
            let started = Date()
            let full = try engine.process(source, settings: settings, lut: preset.cube,
                outputColorSpace: colorSpace, preparedContentSelections: selections,
                preparedLUTContext: semantics)
            guard let report = full.report.lutAdaptation else {
                throw EvaluationFailure.check("highResolutionAdaptiveReportMissing")
            }
            try validateAdaptiveReport(report)

            let region = NativeInspectionRegion(center: .init(x: 0.57, y: 0.43), pixelSize: 512)
            let inspected = try renderer.render(source, settings: settings, lut: preset.cube,
                outputColorSpace: colorSpace, region: region)
            guard let inspectedReport = inspected.report.lutAdaptation else {
                throw EvaluationFailure.check("nativeInspectionAdaptiveReportMissing")
            }
            try validateAdaptiveReport(inspectedReport)
            let reportMatches = report == inspectedReport
            let reportDifferences = reportDifferencePaths(report, inspectedReport)

            let fullRaster = try materializedRaster(full.image, colorSpace: colorSpace.cgColorSpace,
                                                     context: engine.context)
            let fullCrop = try cropTopLeftRegion(fullRaster, imageExtent: full.image.extent.integral,
                                                  bounds: inspected.sampleBounds)
            let roiDifference = try maximumByteDifference(fullCrop, inspected.after)
            try require(roiDifference <= 2, "nativeROIComparisonExceeds2Over255")
            let (bits, tiffDifference) = try tiffRoundTrip(full.image, id: sample.id,
                colorSpace: colorSpace, output: output, engine: engine)
            runs.append(HighResolutionRun(outputColorSpace: colorSpace, presetID: preset.id,
                roiBounds: RectRecord(inspected.sampleBounds),
                roiMaximumRGBAByteDifference: roiDifference,
                roiMaximumErrorOver255: Double(roiDifference) / 255,
                fullAndROILUTReportsExactlyEqual: reportMatches,
                reportDifferencePaths: reportDifferences,
                tiffBitsPerComponent: bits,
                tiffMaximumRGBAByteDifference: tiffDifference,
                tiffMaximumErrorOver255: Double(tiffDifference) / 255,
                processingSeconds: Date().timeIntervalSince(started), report: report))
        }
        records.append(HighResolutionRecord(id: sample.id, group: sample.group,
            inputWasRAW: loaded.report.inputWasRAW,
            width: Int(source.extent.width.rounded(.up)), height: Int(source.extent.height.rounded(.up)),
            contentSelection: selections.report, semanticLabels: semantics.labels,
            semanticStatus: semantics.status, runs: runs))
        print("FILM_LUT_NATIVE \(sample.id) PASS")
        fflush(stdout)
        _ = previewRecord
    }
    return records
}

private func ricohCubeURLs(in folder: URL) throws -> [URL] {
    let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    try require(folderValues.isDirectory == true && folderValues.isSymbolicLink != true,
                "ricohCubeDirectoryMissingOrSymlink")
    let urls = try FileManager.default.contentsOfDirectory(at: folder,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
    return try urls.filter { url in
        guard url.pathExtension.lowercased() == "cube" else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }.sorted { $0.path < $1.path }
}

private func runRicohDiagnostics(folder: URL, samples: [InputSample], prepared: [String: PreparedPreview],
                                 engine: PhotoEngine) throws -> RicohDiagnostic {
    let urls = try ricohCubeURLs(in: folder)
    try require(!urls.isEmpty, "ricohDirectoryContainsNoCubeFiles")
    let chosenURLs = Array(urls.prefix(3))
    let fixedBase = baseSettings()
    var cubeRecords: [RicohCubeRecord] = []
    for (index, url) in chosenURLs.enumerated() {
        let cubeID = String(format: "C%03d", index + 1)
        let cubeHash = try sha256(url)
        let cube: LUTCube
        do {
            cube = try LUTCube.load(url: url)
        } catch {
            cubeRecords.append(RicohCubeRecord(cubeID: cubeID, sha256: cubeHash,
                tableNumbers: nil, failureType: String(reflecting: type(of: error)), sampleRuns: []))
            continue
        }
        let compatibility = LUTCompatibilityInspector.inspect(cube, colorSpace: .sRGB)
        let numbers = RicohTableNumbers(size: compatibility.size,
            interpretationAssumption: "sRGB gamma-encoded input assumption; not confirmed by the LUT author",
            outputOutsideUnitFraction: compatibility.outputOutsideUnitFraction,
            neutralColorShift: compatibility.neutralColorShift,
            neutralToneReversals: compatibility.neutralToneReversals)
        var sampleRuns: [RicohSampleRun] = []
        for sample in samples.prefix(4) {
            guard let preview = prepared[sample.id] else {
                throw EvaluationFailure.check("ricohPreviewAnalysisMissing")
            }
            do {
                var fixed = fixedBase
                fixed.adaptiveLUT = nil
                let fixedStarted = Date()
                let fixedResult = try engine.process(preview.image, settings: fixed, lut: cube,
                                                     outputColorSpace: .sRGB)
                try require(fixedResult.report.lutAdaptation == nil, "ricohFixedRunUnexpectedAdaptiveReport")
                let fixedSeconds = Date().timeIntervalSince(fixedStarted)
                let adaptiveStarted = Date()
                let adaptive = try engine.process(preview.image,
                    settings: adaptiveSettings(from: fixedBase), lut: cube, outputColorSpace: .sRGB,
                    preparedContentSelections: preview.selections, preparedLUTContext: preview.semantics)
                let adaptiveSeconds = Date().timeIntervalSince(adaptiveStarted)
                guard let report = adaptive.report.lutAdaptation else {
                    throw EvaluationFailure.check("ricohAdaptiveReportMissing")
                }
                try validateAdaptiveReport(report)
                sampleRuns.append(RicohSampleRun(sampleID: sample.id,
                    fixedProcessingSeconds: fixedSeconds, adaptiveProcessingSeconds: adaptiveSeconds,
                    adaptiveReport: report, failureType: nil))
            } catch {
                sampleRuns.append(RicohSampleRun(sampleID: sample.id,
                    fixedProcessingSeconds: nil, adaptiveProcessingSeconds: nil,
                    adaptiveReport: nil, failureType: String(reflecting: type(of: error))))
            }
        }
        cubeRecords.append(RicohCubeRecord(cubeID: cubeID, sha256: cubeHash,
            tableNumbers: numbers, failureType: nil, sampleRuns: sampleRuns))
    }
    return RicohDiagnostic(
        interpretationNotice: "Ricoh .cube 输入空间采用未经作者确认的 sRGB 假设；仅作兼容性与数值实验，不构成推荐或适配性结论。",
        mode: "numeric-and-processing-diagnostic-only", requestedIntensity: expectedIntensity,
        cubesConsidered: chosenURLs.count, samplesPerCube: min(4, samples.count), cubes: cubeRecords)
}

private func selectHighResolutionSamples(_ samples: [InputSample], records: [SampleRecord]) throws -> [InputSample] {
    let portraitsByID = Dictionary(uniqueKeysWithValues: records.filter { $0.group == .portrait }.map { ($0.id, $0) })
    let portraitInputs = samples.filter { $0.group == .portrait }
    let eligible = portraitInputs.compactMap { sample -> (InputSample, Int, Double)? in
        guard let record = portraitsByID[sample.id], record.contentSelection.faceCount > 0 else { return nil }
        return (sample, record.contentSelection.faceCount,
                record.contentSelection.coverage[ContentSelectionTarget.faceSkin.rawValue] ?? 0)
    }.sorted {
        if $0.1 != $1.1 { return $0.1 > $1.1 }
        if $0.2 != $1.2 { return $0.2 > $1.2 }
        return $0.0.id < $1.0.id
    }
    try require(eligible.count >= 2, "fewerThanTwoPortraitsHaveDetectedFaces")
    guard let raw = samples.first(where: { $0.group == .raw }) else {
        throw EvaluationFailure.check("rawSampleMissing")
    }
    return [eligible[0].0, eligible[1].0, raw]
}

private func evaluate(arguments: [String], createdOutput: inout URL?) throws {
    try require(arguments.count == 5 || arguments.count == 6,
        "usage: evaluate_film_luts <photo-folder> <portrait-folder> <raw-folder> <new-output> [ricoh-cube-directory]")
    let started = Date()
    let inputs = [inputURL(arguments[1]), inputURL(arguments[2]), inputURL(arguments[3])]
    let resolvedInputs = inputs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
    try require(Set(resolvedInputs).count == 3, "inputFoldersMustBeDistinct")
    for left in resolvedInputs.indices {
        for right in resolvedInputs.indices where right > left {
            try require(!pathsOverlap(resolvedInputs[left], resolvedInputs[right]), "inputFoldersMustNotOverlap")
        }
    }
    let requestedOutput = URL(fileURLWithPath: arguments[4]).standardizedFileURL
    try require(!FileManager.default.fileExists(atPath: requestedOutput.path), "outputDirectoryAlreadyExists")
    let parent = requestedOutput.deletingLastPathComponent()
    var parentIsDirectory: ObjCBool = false
    let parentExists = FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory)
    try require(parentExists && parentIsDirectory.boolValue, "outputParentMustExist")
    let outputPath = resolvedPathForNewDirectory(requestedOutput, manager: .default)
    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    for inputPath in resolvedInputs {
        try require(!pathsOverlap(outputPath, inputPath), "outputMustNotOverlapInputFolders")
    }
    try verifyIgnoredOutput(outputPath)
    let samples = try inputSamples(photoFolder: inputs[0], portraitFolder: inputs[1], rawFolder: inputs[2])
    let ricohFolder = arguments.count == 6 ? inputURL(arguments[5]) : nil
    if let ricohFolder {
        let resolvedRicoh = ricohFolder.resolvingSymlinksInPath().standardizedFileURL.path
        try require(resolvedInputs.allSatisfy { !pathsOverlap(resolvedRicoh, $0) }
                    && !pathsOverlap(outputPath, resolvedRicoh), "ricohFolderMustNotOverlapOtherFolders")
    }
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        createdOutput = output
    } catch {
        throw EvaluationFailure.check("outputDirectoryCreationFailed")
    }

    let engine = PhotoEngine()
    let previewResult = try runPreviewSamples(samples, output: output, engine: engine,
                                               preserveFirstFour: ricohFolder != nil)
    try encodeJSON(previewResult.records, to: output.appendingPathComponent("previews.json"))
    let selectedHighResolution = try selectHighResolutionSamples(samples, records: previewResult.records)
    let highResolution = try runHighResolution(selectedHighResolution,
        sampleRecords: previewResult.records, output: output, engine: engine)
    try encodeJSON(highResolution, to: output.appendingPathComponent("high-resolution.json"))
    let sourceIndex = try samples.map { sample -> SourceIndexEntry in
        guard let before = previewResult.beforeHashes[sample.id] else {
            throw EvaluationFailure.check("sourceHashBeforeMissing")
        }
        let after = try sha256(sample.item.url)
        try require(before == after, "sourceHashChanged")
        return SourceIndexEntry(id: sample.id, sha256Before: before, sha256After: after, unchanged: true)
    }
    try encodeJSON(sourceIndex, to: output.appendingPathComponent("source-index.json"))
    var ricoh: RicohDiagnostic?
    if let ricohFolder {
        let diagnostic = try runRicohDiagnostics(folder: ricohFolder, samples: samples,
            prepared: previewResult.prepared, engine: engine)
        ricoh = diagnostic
        try encodeJSON(diagnostic, to: output.appendingPathComponent("ricoh-diagnostics.json"))
    }

    let reports = previewResult.records.flatMap(\.runs).map(\.report)
        + highResolution.flatMap(\.runs).map(\.report)
        + (ricoh?.cubes.flatMap(\.sampleRuns).compactMap(\.adaptiveReport) ?? [])
    try require(reports.allSatisfy { $0.candidates.count == 9 }, "finalCandidateCountAuditFailed")
    try require(reports.allSatisfy {
        $0.nativeIntroducedHighlights == 0 && $0.nativeIntroducedShadows == 0
    }, "finalNativeClippingAuditFailed")

    let reportMismatchCount = highResolution.flatMap(\.runs).filter {
        !$0.fullAndROILUTReportsExactlyEqual
    }.count
    let ricohFailureCount = ricoh?.cubes.reduce(0) { count, cube in
        count + (cube.failureType == nil ? 0 : 1)
            + cube.sampleRuns.filter { $0.failureType != nil }.count
    } ?? 0
    let summary = RunSummary(
        status: reportMismatchCount == 0 && ricohFailureCount == 0
            ? "PASS" : "FAIL_DIAGNOSTIC_MISMATCH_OR_RICOH_ERRORS",
        sampleCount: samples.count,
        presetCount: FilmLUTCatalog.presets.count, requestedIntensity: expectedIntensity,
        previewMaximumEdge: previewLimit, previewPixelFormat: "RGBA half-float, extended linear sRGB",
        contactSheetCount: samples.count, adaptiveReportCount: reports.count,
        reportsWithNineCandidates: reports.filter { $0.candidates.count == 9 }.count,
        reportsWithoutIntroducedHighlightsOrShadows: reports.filter {
            $0.nativeIntroducedHighlights == 0 && $0.nativeIntroducedShadows == 0
        }.count,
        highResolutionCaseCount: highResolution.reduce(0) { $0 + $1.runs.count },
        ricohCubeCount: ricoh?.cubes.count ?? 0, ricohFailureCount: ricohFailureCount,
        fullAndROIReportMismatchCount: reportMismatchCount,
        elapsedSeconds: Date().timeIntervalSince(started),
        privacyNote: "Artifacts contain anonymous sample and cube IDs plus content hashes; no source names or paths, and no source image copies.")
    try encodeJSON(summary, to: output.appendingPathComponent("run-summary.json"))
    if reportMismatchCount > 0 {
        throw EvaluationFailure.check("fullAndROILUTReportsDiffer; see reportDifferencePaths")
    }
    if ricohFailureCount > 0 {
        throw EvaluationFailure.check("ricohDiagnosticsHaveFailures; see ricoh-diagnostics.json")
    }
    createdOutput = nil
    print("FILM_LUT_EVALUATION PASS · \(samples.count) samples · \(FilmLUTCatalog.presets.count) presets · \(reports.count) adaptive reports")
}

var createdOutput: URL?
do {
    try evaluate(arguments: CommandLine.arguments, createdOutput: &createdOutput)
} catch {
    if let createdOutput {
        try? encodeJSON(FailureRecord(status: "FAIL", code: failureCode(error)),
                        to: createdOutput.appendingPathComponent("failure.json"))
    }
    fputs("FILM_LUT_EVALUATION FAIL: \(failureCode(error))\n", stderr)
    exit(1)
}

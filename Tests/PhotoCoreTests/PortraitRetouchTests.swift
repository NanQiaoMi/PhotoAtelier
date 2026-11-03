import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

/// Synthetic-fixture tests for the W4 portrait refinement pass.
///
/// The fixtures are painted colours and hand-built semantic masks; assertions only
/// prove regional containment, bounded change, monotone direction and recipe
/// compatibility. They are **not** a real-photo aesthetic evaluation.
final class PortraitRetouchTests: XCTestCase {
    private typealias RGBA = (r: Float, g: Float, b: Float, a: Float)

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: true,
        .cacheIntermediates: false
    ])

    // MARK: - Fixtures and sampling

    private func makeImage(width: Int, height: Int,
                           pixel: (Int, Int) -> RGBA) -> CIImage {
        var components = [Float]()
        components.reserveCapacity(width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let value = pixel(column, row)
                components.append(value.r * value.a)
                components.append(value.g * value.a)
                components.append(value.b * value.a)
                components.append(value.a)
            }
        }
        let data = components.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        return CIImage(bitmapData: data,
                       bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                       size: CGSize(width: CGFloat(width), height: CGFloat(height)),
                       format: .RGBAf, colorSpace: linearColorSpace)
    }

    /// Builds an opaque coverage matte (RGB = value, alpha = 1).
    private func coverageMask(width: Int, height: Int,
                              selected: (Int, Int) -> Float) -> CIImage {
        var components = [Float]()
        components.reserveCapacity(width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let value = selected(column, row)
                components.append(value)
                components.append(value)
                components.append(value)
                components.append(1)
            }
        }
        let data = components.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        return CIImage(bitmapData: data,
                       bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                       size: CGSize(width: CGFloat(width), height: CGFloat(height)),
                       format: .RGBAf, colorSpace: linearColorSpace)
    }

    private func faceSet(extent: CGRect,
                         skin: CIImage? = nil,
                         teeth: CIImage? = nil,
                         sclera: CIImage? = nil,
                         brows: CIImage? = nil,
                         faceCount: Int = 1) -> FaceSemanticMaskSet {
        FaceSemanticMaskSet(extent: extent, resolution: CGSize(width: 512, height: 384),
                            faceBounds: CGRect(x: 0.35, y: 0.25, width: 0.3, height: 0.5),
                            confidence: 1, faceCount: faceCount,
                            skin: skin, teeth: teeth, sclera: sclera,
                            iris: nil, lips: nil, brows: brows)
    }

    /// Renders to RGBA float samples; row 0 is the top row (matches `makeImage`).
    private func render(_ image: CIImage) -> [Float] {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: image.extent, format: .RGBAf, colorSpace: linearColorSpace)
        }
        return pixels
    }

    private func luminance(_ pixels: [Float], width: Int, column: Int, row: Int) -> Float {
        let offset = (row * width + column) * 4
        return 0.2126 * pixels[offset] + 0.7152 * pixels[offset + 1] + 0.0722 * pixels[offset + 2]
    }

    private func luminancePlane(_ pixels: [Float], width: Int, height: Int) -> [Float] {
        var plane = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                plane[row * width + column] = luminance(pixels, width: width, column: column, row: row)
            }
        }
        return plane
    }

    private func boxBlur(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        guard radius > 0, width > 1, height > 1 else { return values }
        var horizontal = [Float](repeating: 0, count: values.count)
        var prefix = [Float](repeating: 0, count: width + 1)
        for row in 0..<height {
            let base = row * width
            prefix[0] = 0
            for column in 0..<width {
                prefix[column + 1] = prefix[column] + values[base + column]
            }
            for column in 0..<width {
                let low = max(0, column - radius)
                let high = min(width - 1, column + radius)
                horizontal[base + column] = (prefix[high + 1] - prefix[low]) / Float(high - low + 1)
            }
        }
        var output = [Float](repeating: 0, count: values.count)
        var verticalPrefix = [Float](repeating: 0, count: height + 1)
        for column in 0..<width {
            verticalPrefix[0] = 0
            for row in 0..<height {
                verticalPrefix[row + 1] = verticalPrefix[row] + horizontal[row * width + column]
            }
            for row in 0..<height {
                let low = max(0, row - radius)
                let high = min(height - 1, row + radius)
                output[row * width + column] = (verticalPrefix[high + 1] - verticalPrefix[low])
                    / Float(high - low + 1)
            }
        }
        return output
    }

    private func standardDeviation(_ values: [Float]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        let variance = values.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(values.count)
        return variance.squareRoot()
    }

    private func lab(red: Float, green: Float, blue: Float) -> (lightness: Double, aStar: Double, bStar: Double) {
        let r = Double(min(1, max(0, red)))
        let g = Double(min(1, max(0, green)))
        let b = Double(min(1, max(0, blue)))
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ value: Double) -> Double {
            value > 0.008856451679 ? pow(value, 1.0 / 3.0) : 7.787037 * value + 0.1379310345
        }
        let fx = f(max(x, 0)), fy = f(max(y, 0)), fz = f(max(z, 0))
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    private func meanLab(_ pixels: [Float], width: Int,
                         region: (Int, Int) -> Bool) -> (lightness: Double, aStar: Double, bStar: Double) {
        var lightness = 0.0, aStar = 0.0, bStar = 0.0, count = 0.0
        let height = pixels.count / (width * 4)
        for row in 0..<height {
            for column in 0..<width where region(column, row) {
                let offset = (row * width + column) * 4
                let value = lab(red: pixels[offset], green: pixels[offset + 1], blue: pixels[offset + 2])
                lightness += value.lightness
                aStar += value.aStar
                bStar += value.bStar
                count += 1
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        return (lightness / count, aStar / count, bStar / count)
    }

    private func maximumAbsoluteDifference(_ first: [Float], _ second: [Float],
                                          width: Int, height: Int,
                                          region: (Int, Int) -> Bool) -> Float {
        var maximum: Float = 0
        for row in 0..<height {
            for column in 0..<width where region(column, row) {
                let offset = (row * width + column) * 4
                for channel in 0..<3 {
                    maximum = max(maximum, abs(first[offset + channel] - second[offset + channel]))
                }
            }
        }
        return maximum
    }

    private func assertPixelsEqual(_ first: [Float], _ second: [Float],
                                   message: String, tolerance: Float = 1e-6,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(first.count, second.count, message, file: file, line: line)
        guard first.count == second.count else { return }
        for index in first.indices where abs(first[index] - second[index]) > tolerance {
            XCTFail("\(message): pixel \(index) differs by \(abs(first[index] - second[index]))",
                    file: file, line: line)
            return
        }
    }

    // MARK: - Neutral path

    func testNeutralPortraitSettingsKeepEngineRenderPixelIdentical() throws {
        let width = 64, height = 48
        let source = makeImage(width: width, height: height) { column, row in
            let value = Float(0.25 + 0.4 * Double(column) / Double(width))
            return (value, value * 0.8 + Float(row) / 400, value * 0.6, 1)
        }
        let engine = PhotoEngine()
        var withoutPortrait = AdjustmentSettings()
        withoutPortrait.contrast = 1.1
        let baseline = try engine.process(source, settings: withoutPortrait, lut: nil)

        var withPortrait = withoutPortrait
        withPortrait.portrait = PortraitRefinementSettings(skinToneReference: .brightest)
        let portrait = try engine.process(source, settings: withPortrait, lut: nil)

        XCTAssertNil(baseline.report.portrait)
        XCTAssertNil(portrait.report.portrait)
        assertPixelsEqual(try render(baseline.image), try render(portrait.image),
                          message: "neutral portrait settings must keep the pre-v10 render path pixel-identical")
        XCTAssertTrue(withPortrait.portrait?.isNeutral == true)
        XCTAssertTrue(PortraitRefinementSettings().isNeutral)
    }

    func testNonNeutralPortraitWithoutFaceDegradesExplicitlyAndLeavesPixels() throws {
        let source = makeImage(width: 64, height: 48) { _, _ in (0.2, 0.2, 0.2, 1) }
        let engine = PhotoEngine()
        let baseline = try engine.process(source, settings: AdjustmentSettings(), lut: nil)

        var settings = AdjustmentSettings()
        settings.portrait = PortraitRefinementSettings(blemishStrength: 0.5)
        let degraded = try engine.process(source, settings: settings, lut: nil)

        assertPixelsEqual(try render(baseline.image), try render(degraded.image),
                          message: "a frame without a usable face must not change pixels")
        let report = try XCTUnwrap(degraded.report.portrait)
        XCTAssertFalse(report.applied)
        XCTAssertEqual(report.faceCount, 0)
        XCTAssertNotNil(report.note)
        XCTAssertTrue(degraded.report.warnings.contains { $0.contains("人像修复已跳过") },
                      "skipping portrait work must be reported, never silent")
    }

    // MARK: - Blemish removal

    func testBlemishRepairReducesSpotContrastWithinSkinAndProtectsOtherRegions() throws {
        let width = 256, height = 192
        let spots: [(column: Int, row: Int)] = [(90, 100), (150, 70), (120, 140)]
        let mole = (column: 60, row: 50)
        let protection = (columns: 200...223, rows: 24...44)
        let skinColumns = 24...231
        let skinRows = 18...173
        func isSpot(_ column: Int, _ row: Int) -> Bool {
            spots.contains { spot in
                let dx = column - spot.column, dy = row - spot.row
                return dx * dx + dy * dy <= 6
            }
        }
        func isMole(_ column: Int, _ row: Int) -> Bool {
            let dx = column - mole.column, dy = row - mole.row
            return dx * dx + dy * dy <= 7
        }
        let source = makeImage(width: width, height: height) { column, row in
            let insideSkin = skinColumns.contains(column) && skinRows.contains(row)
            guard insideSkin else { return (0.10, 0.10, 0.10, 1) }
            if protection.columns.contains(column), protection.rows.contains(row) {
                return (0.05, 0.03, 0.02, 1)
            }
            if isMole(column, row) { return (0.05, 0.035, 0.028, 1) }
            if isSpot(column, row) { return (0.22, 0.14, 0.10, 1) }
            let texture = Float(0.004 * sin(Double(column) * 0.9) * cos(Double(row) * 0.7))
            return (0.55 + texture, 0.30 + texture, 0.20 + texture, 1)
        }
        let skinMask = coverageMask(width: width, height: height) { column, row in
            skinColumns.contains(column) && skinRows.contains(row) ? 1 : 0
        }
        let protectionMask = coverageMask(width: width, height: height) { column, row in
            protection.columns.contains(column) && protection.rows.contains(row) ? 1 : 0
        }
        let extent = source.extent

        let before = try render(source)
        let repaired = try PortraitRefinementEngine.apply(
            source,
            settings: PortraitRefinementSettings(blemishStrength: 1),
            faceMasks: [faceSet(extent: extent, skin: skinMask, brows: protectionMask)],
            context: context).image
        let after = try render(repaired)

        for spot in spots {
            let contrastBefore = spotContrast(before, width: width, center: spot)
            let contrastAfter = spotContrast(after, width: width, center: spot)
            XCTAssertLessThan(contrastAfter, contrastBefore * 0.6,
                              "blemish repair must reduce the spot's local contrast")
        }
        let keptMoleChange = abs(luminance(after, width: width, column: mole.column, row: mole.row)
            - luminance(before, width: width, column: mole.column, row: mole.row))
        XCTAssertGreaterThan(keptMoleChange, 0.03, "without keepSpots the dark mole is repaired")

        let outsideSkin: (Int, Int) -> Bool = { column, _ in !skinColumns.contains(column) }
        let protectionRegion: (Int, Int) -> Bool = { column, row in
            protection.columns.contains(column) && protection.rows.contains(row)
        }
        let cleanSkin: (Int, Int) -> Bool = { column, row in
            skinColumns.contains(column) && skinRows.contains(row)
                && !spots.contains(where: { abs(column - $0.column) <= 8 && abs(row - $0.row) <= 8 })
                && !(abs(column - mole.column) <= 8 && abs(row - mole.row) <= 8)
                && !(protection.columns.contains(column) && protection.rows.contains(row))
        }
        XCTAssertLessThan(maximumAbsoluteDifference(before, after, width: width, height: height,
                                                   region: outsideSkin), 0.001,
                          "non-skin pixels must stay unchanged")
        XCTAssertLessThan(maximumAbsoluteDifference(before, after, width: width, height: height,
                                                   region: protectionRegion), 0.001,
                          "eye/brow/lip/teeth protection regions must stay unchanged")
        XCTAssertLessThan(maximumAbsoluteDifference(before, after, width: width, height: height,
                                                   region: cleanSkin), 0.02,
                          "clean skin away from defects may only change slightly")

        let kept = try PortraitRefinementEngine.apply(
            source,
            settings: PortraitRefinementSettings(blemishStrength: 1, keepSpots: true),
            faceMasks: [faceSet(extent: extent, skin: skinMask, brows: protectionMask)],
            context: context).image
        let keptPixels = try render(kept)
        let keptMoleDelta = abs(luminance(keptPixels, width: width, column: mole.column, row: mole.row)
            - luminance(before, width: width, column: mole.column, row: mole.row))
        XCTAssertLessThan(keptMoleDelta, 0.01, "keepSpots must preserve very dark compact spots")
        XCTAssertLessThan(keptMoleDelta, keptMoleChange)
    }

    private func spotContrast(_ pixels: [Float], width: Int,
                              center: (column: Int, row: Int)) -> Float {
        let centerLuminance = luminance(pixels, width: width, column: center.column, row: center.row)
        var ringSum: Float = 0
        var ringCount: Float = 0
        for dy in -9...9 {
            for dx in -9...9 {
                let distanceSquared = dx * dx + dy * dy
                guard distanceSquared >= 36, distanceSquared <= 81 else { continue }
                let column = center.column + dx
                let row = center.row + dy
                guard column >= 0, column < width, row >= 0, row < pixels.count / (width * 4) else { continue }
                ringSum += luminance(pixels, width: width, column: column, row: row)
                ringCount += 1
            }
        }
        let ring = ringCount > 0 ? ringSum / ringCount : centerLuminance
        return ring - centerLuminance
    }

    // MARK: - Frequency separation

    func testFrequencySeparationControlsAreIndependentBoundedAndSkinOnly() throws {
        let width = 192, height = 144
        let skinColumns = 12...179
        let skinRows = 12...131
        let source = makeImage(width: width, height: height) { column, row in
            guard skinColumns.contains(column), skinRows.contains(row) else {
                return (0.10, 0.10, 0.10, 1)
            }
            let gradient = 0.35 + 0.32 * Double(column) / Double(width)
            let highlight = column > Int(Double(width) * 0.65) ? 0.25 : 0
            let checker = ((column + row) % 2 == 0) ? 0.025 : -0.025
            let value = Float(gradient + highlight + checker)
            return (value, value * 0.72, value * 0.55, 1)
        }
        let skinMask = coverageMask(width: width, height: height) { column, row in
            skinColumns.contains(column) && skinRows.contains(row) ? 1 : 0
        }
        let extent = source.extent
        let skinSet = faceSet(extent: extent, skin: skinMask)
        let beforePixels = try render(source)
        let beforeLuminance = luminancePlane(beforePixels, width: width, height: height)

        func apply(_ settings: PortraitRefinementSettings) throws -> (pixels: [Float], plane: [Float]) {
            let image = try PortraitRefinementEngine.apply(source, settings: settings,
                                                           faceMasks: [skinSet], context: context).image
            let pixels = try render(image)
            return (pixels, luminancePlane(pixels, width: width, height: height))
        }
        let skinRegion: (Int, Int) -> Bool = { skinColumns.contains($0) && skinRows.contains($1) }
        let outsideSkin: (Int, Int) -> Bool = { !skinColumns.contains($0) || !skinRows.contains($1) }

        // dodgeBurn: broad low-frequency variation shrinks.
        let dodge = try apply(PortraitRefinementSettings(dodgeBurn: 1))
        let beforeLow = boxBlur(beforeLuminance, width: width, height: height, radius: 12)
        let afterLow = boxBlur(dodge.plane, width: width, height: height, radius: 12)
        let lowBefore = standardDeviation(skinValues(beforeLow, width: width, height: height, region: skinRegion))
        let lowAfter = standardDeviation(skinValues(afterLow, width: width, height: height, region: skinRegion))
        XCTAssertLessThan(lowAfter, lowBefore * 0.8, "dodgeBurn must flatten broad skin lighting")

        // structure: mid-frequency local contrast grows.
        let structure = try apply(PortraitRefinementSettings(structure: 1))
        let beforeMid = midBand(beforeLuminance, width: width, height: height)
        let afterMid = midBand(structure.plane, width: width, height: height)
        let midBefore = standardDeviation(skinValues(beforeMid, width: width, height: height, region: skinRegion))
        let midAfter = standardDeviation(skinValues(afterMid, width: width, height: height, region: skinRegion))
        XCTAssertGreaterThan(midAfter, midBefore * 1.15, "structure must raise mid-frequency contrast")

        // texture: fine texture energy grows.
        let texture = try apply(PortraitRefinementSettings(texture: 1))
        let textureAfter = standardDeviation(skinValues(
            midBand(texture.plane, width: width, height: height), width: width, height: height, region: skinRegion))
        XCTAssertGreaterThan(textureAfter, midBefore * 1.15, "texture must amplify fine skin texture")

        // gloss: high-frequency energy drops in the bright part of the face.
        let brightRegion: (Int, Int) -> Bool = { column, row in
            skinColumns.contains(column) && skinRows.contains(row)
                && column > Int(Double(width) * 0.65)
        }
        let gloss = try apply(PortraitRefinementSettings(gloss: 1))
        let glossBefore = standardDeviation(skinValues(beforeMid, width: width, height: height, region: brightRegion))
        let glossAfter = standardDeviation(skinValues(
            midBand(gloss.plane, width: width, height: height), width: width, height: height, region: brightRegion))
        XCTAssertLessThan(glossAfter, glossBefore * 0.95, "gloss must dampen bright-area sheen detail")

        // Bounded change, finite values, non-skin untouched for every control.
        for run in [dodge, structure, texture, gloss] {
            for value in run.plane { XCTAssertTrue(value.isFinite) }
            let maximumDelta = maximumAbsoluteDifference(beforePixels, run.pixels, width: width, height: height,
                                                         region: skinRegion)
            XCTAssertLessThanOrEqual(maximumDelta, 0.18, "frequency shaping must stay bounded")
            XCTAssertLessThan(maximumAbsoluteDifference(beforePixels, run.pixels, width: width, height: height,
                                                        region: outsideSkin), 0.001,
                              "frequency shaping must never touch non-skin pixels")
        }
    }

    private func skinValues(_ values: [Float], width: Int, height: Int,
                            region: (Int, Int) -> Bool) -> [Float] {
        var output: [Float] = []
        for row in 0..<height {
            for column in 0..<width where region(column, row) {
                output.append(values[row * width + column])
            }
        }
        return output
    }

    private func midBand(_ values: [Float], width: Int, height: Int) -> [Float] {
        let smooth = boxBlur(values, width: width, height: height, radius: 2)
        return zip(values, smooth).map { $0 - $1 }
    }

    // MARK: - Teeth and sclera

    func testTeethWhitenAndScleraBrighteningStayInsideTheirMasks() throws {
        let width = 160, height = 120
        let teethColumns = 60...99, teethRows = 40...69
        let scleraColumns = 20...49, scleraRows = 30...49
        let source = makeImage(width: width, height: height) { column, row in
            if teethColumns.contains(column), teethRows.contains(row) {
                return (0.55, 0.50, 0.28, 1) // yellow teeth
            }
            if scleraColumns.contains(column), scleraRows.contains(row) {
                return (0.40, 0.40, 0.42, 1) // dull sclera
            }
            return (0.55, 0.30, 0.20, 1)
        }
        let extent = source.extent
        let teethMask = coverageMask(width: width, height: height) { column, row in
            teethColumns.contains(column) && teethRows.contains(row) ? 1 : 0
        }
        let scleraMask = coverageMask(width: width, height: height) { column, row in
            scleraColumns.contains(column) && scleraRows.contains(row) ? 1 : 0
        }
        let teethRegion: (Int, Int) -> Bool = { teethColumns.contains($0) && teethRows.contains($1) }
        let scleraRegion: (Int, Int) -> Bool = { scleraColumns.contains($0) && scleraRows.contains($1) }
        let outsideMasks: (Int, Int) -> Bool = { column, row in
            !(teethColumns.contains(column) && teethRows.contains(row))
                && !(scleraColumns.contains(column) && scleraRows.contains(row))
        }
        let before = try render(source)
        let beforeTeeth = meanLab(before, width: width, region: teethRegion)
        let beforeSclera = meanLab(before, width: width, region: scleraRegion)

        let whitened = try PortraitRefinementEngine.apply(
            source, settings: PortraitRefinementSettings(teethWhiten: 1),
            faceMasks: [faceSet(extent: extent, teeth: teethMask)], context: context).image
        let whitenedPixels = try render(whitened)
        let afterTeeth = meanLab(whitenedPixels, width: width, region: teethRegion)
        XCTAssertGreaterThan(afterTeeth.lightness, beforeTeeth.lightness + 1.5,
                             "teeth whitening must raise L*")
        XCTAssertLessThan(afterTeeth.bStar, beforeTeeth.bStar - 1.5,
                          "teeth whitening must remove yellow (b*)")
        XCTAssertLessThan(maximumAbsoluteDifference(before, whitenedPixels, width: width, height: height,
                                                   region: outsideMasks), 0.001,
                          "teeth whitening must not spill outside the teeth matte")

        let brightened = try PortraitRefinementEngine.apply(
            source, settings: PortraitRefinementSettings(eyeBrighten: 1),
            faceMasks: [faceSet(extent: extent, sclera: scleraMask)], context: context).image
        let brightenedPixels = try render(brightened)
        let afterSclera = meanLab(brightenedPixels, width: width, region: scleraRegion)
        XCTAssertGreaterThan(afterSclera.lightness, beforeSclera.lightness + 1.0,
                             "eye brightening must raise sclera L*")
        XCTAssertLessThan(afterSclera.aStar, beforeSclera.aStar,
                          "eye brightening must neutralize red in the sclera")
        XCTAssertLessThan(maximumAbsoluteDifference(before, brightenedPixels, width: width, height: height,
                                                   region: outsideMasks), 0.001,
                          "eye brightening must not spill outside the sclera matte")
    }

    // MARK: - Multi-face skin tone

    func testSkinToneUnificationConvergesTwoFacesAndStrengthZeroIsIdentity() throws {
        let width = 256, height = 160
        let leftColumns = 20...120, rightColumns = 136...236
        let rows = 16...143
        let leftSkin: RGBA = (0.55, 0.30, 0.20, 1)
        let rightSkin: RGBA = (0.38, 0.24, 0.16, 1)
        let source = makeImage(width: width, height: height) { column, row in
            guard rows.contains(row) else { return (0.10, 0.10, 0.10, 1) }
            if leftColumns.contains(column) { return leftSkin }
            if rightColumns.contains(column) { return rightSkin }
            return (0.10, 0.10, 0.10, 1)
        }
        let extent = source.extent
        let leftMask = coverageMask(width: width, height: height) { column, row in
            rows.contains(row) && leftColumns.contains(column) ? 1 : 0
        }
        let rightMask = coverageMask(width: width, height: height) { column, row in
            rows.contains(row) && rightColumns.contains(column) ? 1 : 0
        }
        let leftRegion: (Int, Int) -> Bool = { leftColumns.contains($0) && rows.contains($1) }
        let rightRegion: (Int, Int) -> Bool = { rightColumns.contains($0) && rows.contains($1) }
        let outsideSkin: (Int, Int) -> Bool = { column, _ in
            !leftColumns.contains(column) && !rightColumns.contains(column)
        }
        let before = try render(source)
        let leftBefore = meanLab(before, width: width, region: leftRegion)
        let rightBefore = meanLab(before, width: width, region: rightRegion)
        XCTAssertGreaterThan(abs(leftBefore.lightness - rightBefore.lightness), 3,
                             "fixture needs two clearly different skin tones")

        let unified = try PortraitRefinementEngine.apply(
            source,
            settings: PortraitRefinementSettings(skinToneUnify: 1, skinToneReference: .median),
            faceMasks: [faceSet(extent: extent, skin: leftMask),
                        faceSet(extent: extent, skin: rightMask)],
            context: context)
        let after = try render(unified.image)
        let leftAfter = meanLab(after, width: width, region: leftRegion)
        let rightAfter = meanLab(after, width: width, region: rightRegion)
        let beforeGap = abs(leftBefore.lightness - rightBefore.lightness)
        let afterGap = abs(leftAfter.lightness - rightAfter.lightness)
        XCTAssertLessThan(afterGap, beforeGap * 0.85,
                          "unified tones must move the two faces closer together")
        XCTAssertLessThan(maximumAbsoluteDifference(before, after, width: width, height: height,
                                                   region: outsideSkin), 0.001,
                          "skin-tone unification must stay inside the skin mattes")
        XCTAssertTrue(unified.report.applied)
        XCTAssertTrue(unified.report.appliedSteps.contains("skinTone"))
        XCTAssertEqual(unified.report.faceCount, 2)

        // skinToneUnify = 0 must be a complete no-op.
        let identity = try PortraitRefinementEngine.apply(
            source, settings: PortraitRefinementSettings(),
            faceMasks: [faceSet(extent: extent, skin: leftMask)], context: context)
        XCTAssertFalse(identity.report.applied)
        assertPixelsEqual(try render(identity.image), before,
                          message: "skinToneUnify = 0 must be a complete no-op")
    }

    // MARK: - Validation and recipe version gate

    func testPortraitValidationAndRecipeVersionGate() throws {
        var invalid = PortraitRefinementSettings()
        invalid.blemishStrength = 1.5
        XCTAssertThrowsError(try PortraitRefinementEngine.validate(invalid))
        invalid.blemishStrength = Double.nan
        XCTAssertThrowsError(try PortraitRefinementEngine.validate(invalid))

        var outOfRangeSettings = AdjustmentSettings()
        outOfRangeSettings.portrait = PortraitRefinementSettings(blemishStrength: 1.5)
        XCTAssertThrowsError(try PhotoEngine.validate(outOfRangeSettings))

        var nonNeutralSettings = AdjustmentSettings()
        nonNeutralSettings.portrait = PortraitRefinementSettings(blemishStrength: 0.6)
        XCTAssertNoThrow(try PhotoEngine.validate(nonNeutralSettings))

        var neutralSettings = AdjustmentSettings()
        neutralSettings.portrait = PortraitRefinementSettings()
        XCTAssertNoThrow(try PhotoEngine.validate(neutralSettings))

        var recipe = Recipe(adjustments: nonNeutralSettings)
        recipe.version = 9
        XCTAssertThrowsError(try recipe.validateVersion(),
                             "v9 must reject non-neutral portrait settings")
        recipe.version = 10
        XCTAssertNoThrow(try recipe.validateVersion())

        // v1...v9 keep working when the portrait field is absent or neutral.
        var legacyNeutral = Recipe(adjustments: neutralSettings)
        for version in 1...9 {
            legacyNeutral.version = version
            XCTAssertNoThrow(try legacyNeutral.validateVersion(), "version \(version)")
        }
        legacyNeutral.version = 1
        XCTAssertNoThrow(try legacyNeutral.validateVersion())

        // v10 round-trips through Codable.
        recipe.version = 10
        let encoded = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(Recipe.self, from: encoded)
        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(decoded.adjustments.portrait, nonNeutralSettings.portrait)

        // A recipe written before v10 has no portrait key and must still decode.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var adjustments = try XCTUnwrap(object["adjustments"] as? [String: Any])
        adjustments.removeValue(forKey: "portrait")
        object["adjustments"] = adjustments
        object["version"] = 9
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacyDecoded = try JSONDecoder().decode(Recipe.self, from: legacyData)
        XCTAssertNil(legacyDecoded.adjustments.portrait)
        XCTAssertEqual(legacyDecoded.version, 9)
        XCTAssertNoThrow(try legacyDecoded.validateVersion())
    }
}

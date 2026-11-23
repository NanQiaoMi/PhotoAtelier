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

    /// Optional mean for region samples that may legitimately be empty
    /// (fixture-dependent), used by the R2 light-direction assertions.
    private func optionalMean(_ values: [Float]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
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

    private func ringContrast(_ pixels: [Float], width: Int,
                              center: (column: Int, row: Int),
                              innerRadius: Int, outerRadius: Int) -> Float {
        let centerLuminance = luminance(pixels, width: width, column: center.column, row: center.row)
        let innerSquared = innerRadius * innerRadius
        let outerSquared = outerRadius * outerRadius
        let height = pixels.count / (width * 4)
        var ringSum: Float = 0
        var ringCount: Float = 0
        for dy in -outerRadius...outerRadius {
            for dx in -outerRadius...outerRadius {
                let distanceSquared = dx * dx + dy * dy
                guard distanceSquared >= innerSquared, distanceSquared <= outerSquared else { continue }
                let column = center.column + dx
                let row = center.row + dy
                guard column >= 0, column < width, row >= 0, row < height else { continue }
                ringSum += luminance(pixels, width: width, column: column, row: row)
                ringCount += 1
            }
        }
        let ring = ringCount > 0 ? ringSum / ringCount : centerLuminance
        return ring - centerLuminance
    }

    func testBlemishRepairRemovesLargerSpotsWithSoftEdgesAndNoBoundaryHalo() throws {
        let width = 512, height = 384
        let spots: [(column: Int, row: Int, radius: Int)] = [
            (150, 160, 7),
            (280, 210, 11),
            (52, 180, 7)
        ]
        let protection = (columns: 400...440, rows: 50...80)
        let skinColumns = 40...471
        let skinRows = 32...351

        func isSpot(_ column: Int, _ row: Int) -> Bool {
            spots.contains { spot in
                let dx = column - spot.column, dy = row - spot.row
                return dx * dx + dy * dy <= spot.radius * spot.radius
            }
        }

        let source = makeImage(width: width, height: height) { column, row in
            guard skinColumns.contains(column) && skinRows.contains(row) else {
                return (0.10, 0.10, 0.10, 1)
            }
            if protection.columns.contains(column), protection.rows.contains(row) {
                return (0.05, 0.03, 0.02, 1)
            }
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

        let before = render(source)
        let repaired = try PortraitRefinementEngine.apply(
            source,
            settings: PortraitRefinementSettings(blemishStrength: 1),
            faceMasks: [faceSet(extent: extent, skin: skinMask, brows: protectionMask)],
            context: context
        ).image
        let after = render(repaired)

        for spot in spots {
            let center = (spot.column, spot.row)
            let contrastBefore = ringContrast(before, width: width, center: center,
                                              innerRadius: spot.radius + 3, outerRadius: spot.radius + 7)
            let contrastAfter = ringContrast(after, width: width, center: center,
                                             innerRadius: spot.radius + 3, outerRadius: spot.radius + 7)
            XCTAssertLessThan(contrastAfter, contrastBefore * 0.50,
                              "R7 dual-scale blemish repair must reduce 7-11px spot contrast by >50%")
        }

        let outsideSkin: (Int, Int) -> Bool = { column, row in
            !(skinColumns.contains(column) && skinRows.contains(row))
        }
        let protectionRegion: (Int, Int) -> Bool = { column, row in
            protection.columns.contains(column) && protection.rows.contains(row)
        }
        let cleanSkinAndBoundary: (Int, Int) -> Bool = { column, row in
            skinColumns.contains(column) && skinRows.contains(row)
                && !spots.contains(where: {
                    abs(column - $0.column) <= $0.radius + 5 && abs(row - $0.row) <= $0.radius + 5
                })
                && !(protection.columns.contains(column) && protection.rows.contains(row))
        }
        XCTAssertLessThan(maximumAbsoluteDifference(before, after, width: width, height: height,
                                                   region: outsideSkin), 0.001,
                          "non-skin pixels must stay unchanged")
        XCTAssertLessThan(maximumAbsoluteDifference(before, after, width: width, height: height,
                                                   region: protectionRegion), 0.001,
                          "protection regions must stay unchanged")
        XCTAssertLessThan(maximumAbsoluteDifference(before, after, width: width, height: height,
                                                   region: cleanSkinAndBoundary), 0.02,
                          "normalised low-pass must not create boundary halos or alter clean skin")
    }

    func testBlemishRepairPreservesDiagonalCreasesLikeTearTroughsAndNasolabialFolds() throws {
        let width = 512, height = 384
        let skinColumns = 40...471
        let skinRows = 32...351
        let roundSpot = (column: 150, row: 190, radius: 8)
        let horizontalCrease = (column: 310, row: 120)
        let diagonalCrease = (column: 310, row: 260)

        func isRoundSpot(_ column: Int, _ row: Int) -> Bool {
            let dx = column - roundSpot.column, dy = row - roundSpot.row
            return dx * dx + dy * dy <= roundSpot.radius * roundSpot.radius
        }
        func isHorizontalCrease(_ column: Int, _ row: Int) -> Bool {
            abs(column - horizontalCrease.column) <= 24 && abs(row - horizontalCrease.row) <= 2
        }
        func isDiagonalCrease(_ column: Int, _ row: Int) -> Bool {
            let dx = Double(column - diagonalCrease.column)
            let dy = Double(row - diagonalCrease.row)
            let along = abs(dx + dy) / sqrt(2.0)
            let across = abs(dx - dy) / sqrt(2.0)
            return along <= 24.0 && across <= 2.5
        }

        let source = makeImage(width: width, height: height) { column, row in
            guard skinColumns.contains(column) && skinRows.contains(row) else {
                return (0.10, 0.10, 0.10, 1)
            }
            if isRoundSpot(column, row) { return (0.22, 0.14, 0.10, 1) }
            if isHorizontalCrease(column, row) || isDiagonalCrease(column, row) {
                return (0.24, 0.15, 0.11, 1)
            }
            let texture = Float(0.004 * sin(Double(column) * 0.9) * cos(Double(row) * 0.7))
            return (0.55 + texture, 0.30 + texture, 0.20 + texture, 1)
        }
        let skinMask = coverageMask(width: width, height: height) { column, row in
            skinColumns.contains(column) && skinRows.contains(row) ? 1 : 0
        }
        let extent = source.extent

        let before = render(source)
        let repaired = try PortraitRefinementEngine.apply(
            source,
            settings: PortraitRefinementSettings(blemishStrength: 1),
            faceMasks: [faceSet(extent: extent, skin: skinMask)],
            context: context
        ).image
        let after = render(repaired)

        let spotCenter = (roundSpot.column, roundSpot.row)
        let spotBefore = ringContrast(before, width: width, center: spotCenter,
                                      innerRadius: roundSpot.radius + 3, outerRadius: roundSpot.radius + 7)
        let spotAfter = ringContrast(after, width: width, center: spotCenter,
                                     innerRadius: roundSpot.radius + 3, outerRadius: roundSpot.radius + 7)
        XCTAssertLessThan(spotAfter, spotBefore * 0.50,
                          "round 8px blemish must still be removed")

        let horizBefore = luminance(before, width: width, column: horizontalCrease.column, row: horizontalCrease.row + 10)
            - luminance(before, width: width, column: horizontalCrease.column, row: horizontalCrease.row)
        let horizAfter = luminance(after, width: width, column: horizontalCrease.column, row: horizontalCrease.row + 10)
            - luminance(after, width: width, column: horizontalCrease.column, row: horizontalCrease.row)
        XCTAssertGreaterThan(horizAfter, horizBefore * 0.85,
                             "horizontal elongated crease must be preserved")

        let diagBefore = luminance(before, width: width, column: diagonalCrease.column - 10, row: diagonalCrease.row + 10)
            - luminance(before, width: width, column: diagonalCrease.column, row: diagonalCrease.row)
        let diagAfter = luminance(after, width: width, column: diagonalCrease.column - 10, row: diagonalCrease.row + 10)
            - luminance(after, width: width, column: diagonalCrease.column, row: diagonalCrease.row)
        XCTAssertGreaterThan(diagAfter, diagBefore * 0.85,
                             "45-degree diagonal crease (nasolabial/tear-trough proxy) must be preserved")
    }

    func testBlemishRepairKeepSpotsStillProtectsLargeDarkMoles() throws {
        let width = 512, height = 384
        let skinColumns = 40...471
        let skinRows = 32...351
        let mole = (column: 160, row: 180, radius: 6)
        let spot = (column: 300, row: 180, radius: 6)

        func inside(_ column: Int, _ row: Int, _ target: (column: Int, row: Int, radius: Int)) -> Bool {
            let dx = column - target.column, dy = row - target.row
            return dx * dx + dy * dy <= target.radius * target.radius
        }

        let source = makeImage(width: width, height: height) { column, row in
            guard skinColumns.contains(column) && skinRows.contains(row) else {
                return (0.10, 0.10, 0.10, 1)
            }
            if inside(column, row, mole) { return (0.05, 0.035, 0.028, 1) }
            if inside(column, row, spot) { return (0.22, 0.14, 0.10, 1) }
            let texture = Float(0.004 * sin(Double(column) * 0.9) * cos(Double(row) * 0.7))
            return (0.55 + texture, 0.30 + texture, 0.20 + texture, 1)
        }
        let skinMask = coverageMask(width: width, height: height) { column, row in
            skinColumns.contains(column) && skinRows.contains(row) ? 1 : 0
        }
        let extent = source.extent

        let before = render(source)
        let repaired = try PortraitRefinementEngine.apply(
            source,
            settings: PortraitRefinementSettings(blemishStrength: 1, keepSpots: true),
            faceMasks: [faceSet(extent: extent, skin: skinMask)],
            context: context
        ).image
        let after = render(repaired)

        let moleDelta = abs(luminance(after, width: width, column: mole.column, row: mole.row)
            - luminance(before, width: width, column: mole.column, row: mole.row))
        XCTAssertLessThan(moleDelta, 0.01, "keepSpots must protect 6px dark moles across both scales")

        let spotCenter = (spot.column, spot.row)
        let spotBefore = ringContrast(before, width: width, center: spotCenter,
                                      innerRadius: spot.radius + 3, outerRadius: spot.radius + 7)
        let spotAfter = ringContrast(after, width: width, center: spotCenter,
                                     innerRadius: spot.radius + 3, outerRadius: spot.radius + 7)
        XCTAssertLessThan(spotAfter, spotBefore * 0.50,
                          "regular 6px blemish must still be removed while keepSpots is on")
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

        // dodgeBurn (R2/R3 contract, 2026-11-12 / 2026-11-14 naturalness
        // reworks): broad low-frequency structure must SURVIVE — pulling toward
        // the face-wide mean flattened real light direction into a plastic,
        // uniformly lit face. The control now evens only blotchy deviation from
        // a skin-only, face-scale wide trend (the trend IS the lighting), so the
        // low-band standard deviation shrinks only slightly while the spatial
        // ordering of the lighting (dark side vs bright side) is preserved.
        let dodge = try apply(PortraitRefinementSettings(dodgeBurn: 1))
        let beforeLow = boxBlur(beforeLuminance, width: width, height: height, radius: 12)
        let afterLow = boxBlur(dodge.plane, width: width, height: height, radius: 12)
        let lowBefore = standardDeviation(skinValues(beforeLow, width: width, height: height, region: skinRegion))
        let lowAfter = standardDeviation(skinValues(afterLow, width: width, height: height, region: skinRegion))
        XCTAssertGreaterThan(lowAfter, lowBefore * 0.85,
                             "dodgeBurn must preserve broad skin lighting structure (R2)")
        XCTAssertLessThan(lowAfter, lowBefore * 1.02,
                          "dodgeBurn must still even out blotchy low-frequency patches (R2)")
        // Directional structure: the mean luminance of the darker third of the
        // skin region must stay darker than the brighter third (light direction
        // survives the pass).
        let darkSideMax = Double(width) * 0.4
        let brightSideMin = Double(width) * 0.6
        let darkSide = skinValues(beforeLow, width: width, height: height, region: { column, row in
            skinRegion(column, row) && Double(column) < darkSideMax
        })
        let brightSide = skinValues(beforeLow, width: width, height: height, region: { column, row in
            skinRegion(column, row) && Double(column) > brightSideMin
        })
        let afterDarkSide = skinValues(afterLow, width: width, height: height, region: { column, row in
            skinRegion(column, row) && Double(column) < darkSideMax
        })
        let afterBrightSide = skinValues(afterLow, width: width, height: height, region: { column, row in
            skinRegion(column, row) && Double(column) > brightSideMin
        })
        if let darkMean = optionalMean(darkSide), let brightMean = optionalMean(brightSide),
           let afterDarkMean = optionalMean(afterDarkSide), let afterBrightMean = optionalMean(afterBrightSide) {
            XCTAssertLessThan(darkMean, brightMean,
                              "fixture must have directional lighting to test against")
            XCTAssertLessThan(afterDarkMean, afterBrightMean,
                              "dodgeBurn must preserve the light-direction ordering (R2)")
        }

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

    /// R3 (2026-11-14): on a single-face photo the cross-face reference is the
    /// face itself, so the old implementation produced gains of exactly 1 and
    /// "肤色统一" did nothing. It must now even out the face's own blotchy
    /// chroma while leaving the face's mean tone where it was.
    func testSkinToneUnificationEvensSingleFaceChromaWithoutShiftingItsMean() throws {
        let width = 200, height = 160
        let skinRegion = { (column: Int, row: Int) in (20...179).contains(column) && (20...139).contains(row) }
        let blotchRegion = { (column: Int, row: Int) in (70...129).contains(column) && (60...99).contains(row) }
        let base: RGBA = (0.50, 0.32, 0.24, 1)
        let blotchy: RGBA = (0.56, 0.26, 0.20, 1)
        let source = makeImage(width: width, height: height) { column, row in
            guard skinRegion(column, row) else { return (0.10, 0.10, 0.10, 1) }
            return blotchRegion(column, row) ? blotchy : base
        }
        let mask = coverageMask(width: width, height: height) { column, row in
            skinRegion(column, row) ? 1 : 0
        }
        let outsideSkin: (Int, Int) -> Bool = { column, row in !skinRegion(column, row) }
        let before = try render(source)
        let blotchBefore = meanLab(before, width: width, region: blotchRegion)
        let skinBefore = meanLab(before, width: width, region: skinRegion)
        XCTAssertGreaterThan(abs(blotchBefore.aStar - skinBefore.aStar), 2,
                             "fixture needs a clearly blotchy red patch")

        let unified = try PortraitRefinementEngine.apply(
            source,
            settings: PortraitRefinementSettings(skinToneUnify: 1, skinToneReference: .auto),
            faceMasks: [faceSet(extent: source.extent, skin: mask)],
            context: context)
        let after = try render(unified.image)
        let blotchAfter = meanLab(after, width: width, region: blotchRegion)
        let skinAfter = meanLab(after, width: width, region: skinRegion)
        let beforeGap = abs(blotchBefore.aStar - skinBefore.aStar)
        let afterGap = abs(blotchAfter.aStar - skinAfter.aStar)
        XCTAssertLessThan(afterGap, beforeGap * 0.75,
                          "a single face's blotchy chroma must be evened out")
        XCTAssertEqual(skinAfter.lightness, skinBefore.lightness, accuracy: 1.5,
                       "the face's own mean lightness must not drift")
        XCTAssertEqual(skinAfter.bStar, skinBefore.bStar, accuracy: 1.5,
                       "the face's own mean warmth must not drift")
        XCTAssertLessThan(maximumAbsoluteDifference(before, after, width: width, height: height,
                                                   region: outsideSkin), 0.001,
                          "chroma evening must stay inside the skin matte")
        XCTAssertTrue(unified.report.appliedSteps.contains("skinTone"))
    }

    // MARK: - Skin smoothing (R6)

    /// R6 (2026-11-15): the portrait pass had no stage that *removes* skin
    /// texture. Every existing control adds detail (`structure` boosts mid
    /// contrast, `texture` amplifies the high band), and measured on three real
    /// portraits the whole pass raised skin high-frequency energy by 11% — a
    /// basic retouching app's most elementary operation was not expressible.
    ///
    /// This fixture is a flat skin field carrying a fine periodic texture plus
    /// one strong dark edge. Smoothing must flatten the texture, keep the edge,
    /// leave non-skin pixels alone, and leave protected features untouched.
    func testSkinSmoothingRemovesTextureKeepsEdgesAndStaysInSkin() throws {
        let width = 240, height = 180
        let skinColumns = 20...219
        let skinRows = 16...163
        let feature = (columns: 150...175, rows: 40...70)
        let edgeColumn = 110

        func isFeature(_ column: Int, _ row: Int) -> Bool {
            feature.columns.contains(column) && feature.rows.contains(row)
        }
        // Fine texture: a 1-pixel checkerboard at ±0.012 linear — pore scale.
        // The hard edge at `edgeColumn` is 0.30 linear, i.e. 25x the texture,
        // which is the ratio a nostril or lip line has against pores.
        let source = makeImage(width: width, height: height) { column, row in
            let insideSkin = skinColumns.contains(column) && skinRows.contains(row)
            guard insideSkin else { return (0.08, 0.08, 0.08, 1) }
            if isFeature(column, row) { return (0.05, 0.03, 0.02, 1) }
            let texture: Float = ((column + row) % 2 == 0) ? 0.012 : -0.012
            let edge: Float = column >= edgeColumn ? -0.15 : 0
            let base: Float = 0.55
            return (base + texture + edge, 0.30 + texture * 0.5 + edge,
                    0.20 + texture * 0.3 + edge, 1)
        }
        let skinMask = coverageMask(width: width, height: height) { column, row in
            skinColumns.contains(column) && skinRows.contains(row) ? 1 : 0
        }
        let featureMask = coverageMask(width: width, height: height) { column, row in
            isFeature(column, row) ? 1 : 0
        }
        let extent = source.extent

        let before = try render(source)
        let smoothed = try PortraitRefinementEngine.apply(
            source,
            settings: PortraitRefinementSettings(skinSmoothing: 1),
            faceMasks: [faceSet(extent: extent, skin: skinMask, brows: featureMask)],
            context: context)
        XCTAssertTrue(smoothed.report.appliedSteps.contains("smooth"),
                      "the smoothing stage must report itself")
        let after = try render(smoothed.image)

        // 1. Texture amplitude collapses. Measure the deviation from a 3x3 mean
        //    on clean skin away from the edge and the feature.
        func textureAmplitude(_ pixels: [Float]) -> Float {
            var sum: Float = 0
            var count: Float = 0
            for row in 30...120 {
                for column in 30...(edgeColumn - 6) {
                    let center = luminance(pixels, width: width, column: column, row: row)
                    var neighbourhood: Float = 0
                    for dy in -1...1 {
                        for dx in -1...1 where !(dx == 0 && dy == 0) {
                            neighbourhood += luminance(pixels, width: width,
                                                       column: column + dx, row: row + dy)
                        }
                    }
                    sum += abs(center - neighbourhood / 8)
                    count += 1
                }
            }
            return count > 0 ? sum / count : 0
        }
        let amplitudeBefore = textureAmplitude(before)
        let amplitudeAfter = textureAmplitude(after)
        XCTAssertGreaterThan(amplitudeBefore, 0.004, "fixture must actually carry texture")
        XCTAssertLessThan(amplitudeAfter, amplitudeBefore * 0.35,
                          "smoothing at 1.0 must remove most of the pore-scale texture")

        // 2. The strong edge survives. A smoothing pass that blurs everything
        //    would halve the step across it; the edge guard keeps it.
        func edgeStep(_ pixels: [Float]) -> Float {
            let left = luminance(pixels, width: width, column: edgeColumn - 1, row: 90)
            let right = luminance(pixels, width: width, column: edgeColumn + 1, row: 90)
            return abs(right - left)
        }
        let stepBefore = edgeStep(before)
        let stepAfter = edgeStep(after)
        XCTAssertGreaterThan(stepBefore, 0.10, "fixture edge must be a strong one")
        XCTAssertGreaterThan(stepAfter, stepBefore * 0.90,
                             "a strong edge must survive smoothing, not be blurred away")

        // 3. Nothing outside the skin matte moves.
        XCTAssertLessThan(maximumAbsoluteDifference(before, after, width: width, height: height,
                                                   region: { column, row in
                                                       !skinColumns.contains(column)
                                                           || !skinRows.contains(row)
                                                   }), 0.001,
                          "non-skin pixels must stay unchanged")

        // 4. Brows/lips/teeth/sclera/iris are excluded even where the colour
        //    classifier put them inside the matte.
        XCTAssertLessThan(maximumAbsoluteDifference(before, after, width: width, height: height,
                                                   region: isFeature), 0.02,
                          "protected features may only change slightly")

        // 5. Monotone and bounded: stronger settings remove more, never less.
        var previousAmplitude = Float.greatestFiniteMagnitude
        for amount in [0.25, 0.5, 0.75, 1.0] {
            let image = try PortraitRefinementEngine.apply(
                source,
                settings: PortraitRefinementSettings(skinSmoothing: amount),
                faceMasks: [faceSet(extent: extent, skin: skinMask, brows: featureMask)],
                context: context).image
            let amplitude = textureAmplitude(try render(image))
            XCTAssertLessThan(amplitude, previousAmplitude,
                              "smoothing \(amount) must remove more texture than the step before")
            previousAmplitude = amplitude
        }
    }

    /// R6: smoothing and `texture` act on the same band from opposite directions,
    /// so the pipeline order decides what the user gets. Smoothing runs first, so
    /// "磨皮 + 纹理" means "smooth, then put back as much grain as asked for".
    func testSmoothingRunsBeforeTheTextureStageSoReinjectionCanUndoIt() throws {
        let width = 200, height = 160
        let source = makeImage(width: width, height: height) { column, row in
            let texture: Float = ((column + row) % 2 == 0) ? 0.012 : -0.012
            return (0.55 + texture, 0.30 + texture, 0.20 + texture, 1)
        }
        let skinMask = coverageMask(width: width, height: height) { _, _ in 1 }
        let extent = source.extent
        let masks = [faceSet(extent: extent, skin: skinMask)]

        let smoothOnly = try PortraitRefinementEngine.apply(
            source, settings: PortraitRefinementSettings(skinSmoothing: 1),
            faceMasks: masks, context: context)
        let both = try PortraitRefinementEngine.apply(
            source, settings: PortraitRefinementSettings(skinSmoothing: 1, texture: 1),
            faceMasks: masks, context: context)

        XCTAssertEqual(smoothOnly.report.appliedSteps, ["smooth"])
        XCTAssertEqual(both.report.appliedSteps, ["smooth", "texture"],
                       "smoothing must be listed before texture")

        func amplitude(_ image: CIImage) throws -> Float {
            let pixels = try render(image)
            var sum: Float = 0
            var count: Float = 0
            for row in 20..<140 {
                for column in 20..<180 {
                    let center = luminance(pixels, width: width, column: column, row: row)
                    var neighbourhood: Float = 0
                    for dy in -1...1 {
                        for dx in -1...1 where !(dx == 0 && dy == 0) {
                            neighbourhood += luminance(pixels, width: width,
                                                       column: column + dx, row: row + dy)
                        }
                    }
                    sum += abs(center - neighbourhood / 8)
                    count += 1
                }
            }
            return count > 0 ? sum / count : 0
        }
        let smoothed = try amplitude(smoothOnly.image)
        let retextured = try amplitude(both.image)
        XCTAssertGreaterThan(retextured, smoothed,
                             "the texture stage must be able to put grain back after smoothing")
    }

    /// R6: the new field must decode as 0 from every recipe written before it
    /// existed, and must be rejected outside 0...1.
    func testSkinSmoothingDecodesLegacyRecipesAsNeutralAndValidatesRange() throws {
        var settings = PortraitRefinementSettings()
        settings.skinSmoothing = 0.6
        let encoded = try JSONEncoder().encode(settings)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "skinSmoothing")
        let legacy = try JSONDecoder().decode(
            PortraitRefinementSettings.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.skinSmoothing, 0, "a recipe written before R6 must decode as neutral")
        XCTAssertTrue(legacy.isNeutral, "an absent smoothing field must not make settings non-neutral")

        var invalid = PortraitRefinementSettings()
        invalid.skinSmoothing = 1.4
        XCTAssertThrowsError(try PortraitRefinementEngine.validate(invalid))
        invalid.skinSmoothing = -0.1
        XCTAssertThrowsError(try PortraitRefinementEngine.validate(invalid))

        var nonNeutral = AdjustmentSettings()
        nonNeutral.portrait = PortraitRefinementSettings(skinSmoothing: 0.5)
        var recipe = Recipe(adjustments: nonNeutral)
        recipe.version = 9
        XCTAssertThrowsError(try recipe.validateVersion(),
                             "smoothing alone is a v10 feature and cannot be saved as v9")
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

    // MARK: - P1-6 liquify integration

    func testLiquifyPipelineRunsAfterLegacyToneAndGeometryAndBeforeColorTools() throws {
        let width = 64, height = 48
        let source = makeImage(width: width, height: height) { column, row in
            let x = Float(column) / Float(width - 1)
            let y = Float(row) / Float(height - 1)
            return (min(1, 0.05 + 0.9 * x * x),
                    min(1, 0.08 + 0.75 * y),
                    min(1, 0.10 + 0.6 * x * y), 1)
        }
        let engine = PhotoEngine()
        let stroke = WarpStroke(mode: .push,
                                points: [MaskPoint(x: 0.35, y: 0.5), MaskPoint(x: 0.65, y: 0.5)],
                                radius: 0.12, strength: 0.9)
        let liquify = FaceReshapeSettings(strokes: [stroke])

        // Strong nonlinear tone + geometry + a nonlinear color tool make the
        // pipeline order observable from pixels.
        var toneAndGeometry = AdjustmentSettings()
        toneAndGeometry.exposureEV = 0.45
        toneAndGeometry.contrast = 2.4
        toneAndGeometry.saturation = 1.4
        toneAndGeometry.rotationDegrees = 9
        var curves = ColorCurveSettings()
        curves.luminance = [CurveControlPoint(x: 0, y: 0),
                            CurveControlPoint(x: 0.5, y: 0.75),
                            CurveControlPoint(x: 1, y: 1)]
        let colorTools = ColorToolsSettings(curves: curves)

        var combined = toneAndGeometry
        combined.liquify = liquify
        combined.colorTools = colorTools
        let actual = try engine.process(source, settings: combined, lut: nil)
        let liquifyReport = try XCTUnwrap(actual.report.liquify)
        XCTAssertTrue(liquifyReport.applied)
        XCTAssertEqual(liquifyReport.strokeCount, 1)

        // Accepted implementation order (Lead decision on review F2): legacy
        // pixel compatibility keeps 基础影调 → 几何 → 液化 → 调色工具. The plan
        // §4 ideal order (geometry → liquify → tone) is intentionally NOT used.
        let base = try engine.process(source, settings: toneAndGeometry, lut: nil)
        let warped = try FaceReshapeEngine.apply(to: base.image, landmarks: nil,
                                                 settings: liquify)
        let expected = try ColorToolsEngine.apply(colorTools, to: warped)
        assertPixelsEqual(try render(actual.image), try render(expected),
                          message: "真实顺序应为 基础影调→几何→液化→调色工具",
                          tolerance: 0.004)

        // The plan §4 order (tone last) must differ, proving tone runs before
        // geometry+liquify instead of after them.
        var geometryOnly = AdjustmentSettings()
        geometryOnly.rotationDegrees = 9
        let rotated = try engine.process(source, settings: geometryOnly, lut: nil)
        let warpedAfterRotation = try FaceReshapeEngine.apply(to: rotated.image,
                                                              landmarks: nil,
                                                              settings: liquify)
        var toneOnly = toneAndGeometry
        toneOnly.liquify = nil
        toneOnly.colorTools = nil
        toneOnly.rotationDegrees = 0
        let planOrder = try engine.process(warpedAfterRotation, settings: toneOnly, lut: nil)
        let actualPixels = try render(actual.image)
        let forwardTonePixels = try render(expected)
        XCTAssertGreaterThan(maximumAbsoluteDifference(forwardTonePixels,
                                                       try render(planOrder.image),
                                                       width: width, height: height,
                                                       region: { _, _ in true }),
                             0.002,
                             "影调若在液化之后像素必须不同，证明真实顺序为影调→几何→液化")

        // Liquify must run before the color tools: the reverse order differs.
        let toolsFirst = try ColorToolsEngine.apply(colorTools, to: base.image)
        let warpedAfterTools = try FaceReshapeEngine.apply(to: toolsFirst, landmarks: nil,
                                                           settings: liquify)
        XCTAssertGreaterThan(maximumAbsoluteDifference(actualPixels,
                                                       try render(warpedAfterTools),
                                                       width: width, height: height,
                                                       region: { _, _ in true }),
                             0.002,
                             "液化必须在调色工具之前；否则色阶响应会不同")

        // Missing and explicitly neutral liquify keep the pre-v11 path exactly.
        var withoutLiquify = combined
        withoutLiquify.liquify = nil
        var explicitlyNeutral = withoutLiquify
        explicitlyNeutral.liquify = FaceReshapeSettings()
        let baseline = try engine.process(source, settings: withoutLiquify, lut: nil)
        let neutralOutput = try engine.process(source, settings: explicitlyNeutral, lut: nil)
        assertPixelsEqual(try render(baseline.image), try render(neutralOutput.image),
                          message: "显式中性液化必须与缺少液化字段像素完全一致")
        XCTAssertNil(baseline.report.liquify)
        XCTAssertNil(neutralOutput.report.liquify)
    }

    func testLiquifySliderMathNeverStoresOutOfRangeExplicitParameters() throws {
        let keyPaths: [WritableKeyPath<FaceReshapeParameters, Double>] = [
            \.slimFace, \.smallFace, \.enlargeEyes, \.narrowNose, \.lipWidth, \.chin
        ]
        for preset in FaceShapePreset.allCases {
            for keyPath in keyPaths {
                let presetValue = preset.parameters[keyPath: keyPath]
                for effective in [-1.0, -0.55, 0.0, 0.4, 1.0] {
                    let explicit = LiquifySliderMath.explicitOffset(forEffective: effective,
                                                                    presetValue: presetValue)
                    XCTAssertTrue((-1...1).contains(explicit),
                                  "preset \(preset.title) endpoint \(effective) must stay in -1...1")
                    var parameters = FaceReshapeParameters()
                    parameters[keyPath: keyPath] = explicit
                    var settings = AdjustmentSettings()
                    settings.liquify = FaceReshapeSettings(preset: preset, parameters: parameters)
                    XCTAssertNoThrow(try FaceReshapeEngine.validate(settings.liquify!),
                                     "preset \(preset.title) endpoint \(effective) must validate")
                    XCTAssertNoThrow(try PhotoEngine.validate(settings),
                                     "preset \(preset.title) endpoint \(effective) must not fail the preview")
                    let effectiveAfter = settings.liquify!.effectiveParameters[keyPath: keyPath]
                    XCTAssertTrue((-1...1).contains(effectiveAfter))
                    XCTAssertEqual(effectiveAfter,
                                   LiquifySliderMath.clampedEffective(effective,
                                                                      presetValue: presetValue),
                                   accuracy: 1e-12)
                }
            }
        }
        // Reproduce the reviewer's failure case: round preset + slider dragged to -1.
        let roundPreset = FaceShapePreset.round.parameters
        let explicit = LiquifySliderMath.explicitOffset(forEffective: -1,
                                                        presetValue: roundPreset.slimFace)
        XCTAssertEqual(explicit, -1, accuracy: 1e-12)
        XCTAssertEqual(roundPreset.slimFace + explicit, -0.45, accuracy: 1e-12)
    }

    func testLiquifyBrushOverlayFootprintMatchesWarpFieldOnNonSquareImage() throws {
        // 3:2 landscape: a short-edge circle would understate the footprint.
        let imageSize = CGSize(width: 6000, height: 4000)
        let radii = LiquifyBrushGeometry.pixelRadii(radius: 0.08, imageSize: imageSize)
        XCTAssertEqual(radii.x, 480, accuracy: 1e-9)
        XCTAssertEqual(radii.y, 320, accuracy: 1e-9)
        XCTAssertNotEqual(radii.x, radii.y)

        // The warp field's actual support matches those normalized radii.
        var field = FaceReshapeEngine.warpField(
            landmarks: nil,
            settings: FaceReshapeSettings(strokes: [
                WarpStroke(mode: .push,
                           points: [MaskPoint(x: 0.4, y: 0.5), MaskPoint(x: 0.6, y: 0.5)],
                           radius: 0.08, strength: 1)
            ]),
            imageSize: imageSize)
        let center = CGPoint(x: 0.6, y: 0.5)
        func magnitude(_ point: CGPoint) -> Double {
            let value = field.displacement(at: point)
            return (value.x * value.x + value.y * value.y).squareRoot()
        }
        XCTAssertGreaterThan(magnitude(CGPoint(x: center.x + 0.08 * 0.5, y: center.y)),
                             0.0001, "横向作用区域内应有位移")
        XCTAssertGreaterThan(magnitude(CGPoint(x: center.x, y: center.y + 0.08 * 0.5)),
                             0.0001, "纵向作用区域内应有位移")
        XCTAssertEqual(magnitude(CGPoint(x: center.x + 0.08 * 1.5, y: center.y)), 0,
                       accuracy: 1e-9, "横向 1.5×半径外应为零位移")
        XCTAssertEqual(magnitude(CGPoint(x: center.x, y: center.y + 0.08 * 1.5)), 0,
                       accuracy: 1e-9, "纵向 1.5×半径外应为零位移")
    }

    func testLiquifyFacePresetWithoutFaceDegradesExplicitlyAndLeavesPixels() throws {
        let width = 64, height = 48
        let source = makeImage(width: width, height: height) { column, _ in
            let value = Float(0.2 + 0.5 * Double(column) / 64)
            return (value, value * 0.9, value * 0.8, 1)
        }
        let engine = PhotoEngine()
        let baseline = try engine.process(source, settings: AdjustmentSettings(), lut: nil)
        var settings = AdjustmentSettings()
        settings.liquify = FaceReshapeSettings(preset: .youthful)
        let degraded = try engine.process(source, settings: settings, lut: nil)

        assertPixelsEqual(try render(baseline.image), try render(degraded.image),
                          message: "a face-dependent liquify preset without a face must not change pixels")
        let report = try XCTUnwrap(degraded.report.liquify)
        XCTAssertFalse(report.applied)
        XCTAssertEqual(report.faceCount, 0)
        XCTAssertFalse(report.presetApplied)
        XCTAssertNotNil(report.note)
        XCTAssertTrue(degraded.report.warnings.contains { $0.contains("液化") },
                      "skipping liquify must be reported, never silent")
    }

    func testBatchManifestRecordsLiquifySkipForFaceDependentPreset() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = PhotoEngine().context
        let image = CIImage(color: CIColor(red: 0.3, green: 0.25, blue: 0.2, alpha: 1,
                                          colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 48, height: 48))
        var export = ExportSettings(); export.format = .png
        try PhotoExporter.write(image: image, to: input.appendingPathComponent("flat.png"),
                                settings: export, sourceProperties: [:], context: context)

        var settings = AdjustmentSettings()
        settings.liquify = FaceReshapeSettings(preset: .round)
        var recipe = Recipe(adjustments: settings)
        recipe.version = 11
        let summary = try BatchProcessor().run(items: PhotoLoader.scan(folder: input, recursive: false),
                                               inputRoot: input, outputRoot: output,
                                               recipe: recipe, lut: nil,
                                               cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(summary.succeeded, 1)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: XCTUnwrap(summary.manifestURL))) as? [String: Any])
        let recipePayload = try XCTUnwrap(manifest["recipe"] as? [String: Any])
        XCTAssertEqual(recipePayload["version"] as? Int, 11)
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first)
        let report = try XCTUnwrap(entry["report"] as? [String: Any])
        let liquify = try XCTUnwrap(report["liquify"] as? [String: Any],
                                    "batch manifest must record the liquify decision")
        XCTAssertEqual(liquify["applied"] as? Bool, false)
        XCTAssertEqual(liquify["faceCount"] as? Int, 0)
        XCTAssertEqual(liquify["presetApplied"] as? Bool, false)
        XCTAssertNotNil(liquify["note"] as? String)
    }

    // MARK: - P1-B manual repair / clone brush (v12)

    /// Paints a source with a dark defect, then checks: absent/empty repair is a
    /// pixel-identical pre-v12 path; a heal stroke reduces the defect contrast
    /// inside its footprint while leaving far pixels untouched; the report records
    /// the applied stroke counts for batch manifests.
    func testRepairBrushNeutralIsIdentityAndHealRunsInPipeline() throws {
        let width = 96, height = 64
        let source = makeImage(width: width, height: height) { column, row in
            let x = Float(column) / Float(width - 1)
            let y = Float(row) / Float(height - 1)
            // Dark 8×8 defect at the centre of a smooth gradient.
            if (44..<52).contains(column), (28..<36).contains(row) {
                return (0.05, 0.05, 0.05, 1)
            }
            return (0.25 + 0.5 * x, 0.30 + 0.4 * y, 0.35 + 0.3 * x, 1)
        }
        let engine = PhotoEngine()
        var baseline = AdjustmentSettings()
        baseline.exposureEV = 0.2
        baseline.contrast = 1.3
        var neutral = baseline
        neutral.repairBrush = RepairBrushSettings()
        let baseOut = try engine.process(source, settings: baseline, lut: nil)
        let neutralOut = try engine.process(source, settings: neutral, lut: nil)
        assertPixelsEqual(try render(baseOut.image), try render(neutralOut.image),
                          message: "空笔迹列表必须与缺少修复字段像素完全一致")
        XCTAssertNil(baseOut.report.repairBrush)
        XCTAssertNil(neutralOut.report.repairBrush)

        var withRepair = baseline
        withRepair.repairBrush = RepairBrushSettings(strokes: [
            RepairStroke(mode: .heal,
                         points: [MaskPoint(x: 0.5, y: 0.35), MaskPoint(x: 0.5, y: 0.65)],
                         radius: 0.12, feather: 0.5, strength: 1)
        ])
        let repaired = try engine.process(source, settings: withRepair, lut: nil)
        let report = try XCTUnwrap(repaired.report.repairBrush,
                                   "heal 笔迹必须记录到 ProcessingReport")
        XCTAssertTrue(report.applied)
        XCTAssertEqual(report.strokeCount, 1)
        XCTAssertEqual(report.healStrokeCount, 1)
        XCTAssertEqual(report.cloneStrokeCount, 0)

        let before = try render(baseOut.image)
        let after = try render(repaired.image)
        func meanLuma(_ pixels: [Float], column0: Int, row0: Int, w: Int, h: Int) -> Float {
            var total: Float = 0
            var count: Float = 0
            for row in row0..<(row0 + h) {
                for column in column0..<(column0 + w) {
                    total += luminance(pixels, width: width, column: column, row: row)
                    count += 1
                }
            }
            return total / count
        }
        // Defect vs a clean ring right of the vertical stroke (stroke x range is
        // roughly 40...56 px, so column 60...68 stays outside the healed footprint).
        let defectBefore = meanLuma(before, column0: 44, row0: 28, w: 8, h: 8)
        let ringBefore = meanLuma(before, column0: 60, row0: 28, w: 8, h: 8)
        let defectAfter = meanLuma(after, column0: 44, row0: 28, w: 8, h: 8)
        let ringAfter = meanLuma(after, column0: 60, row0: 28, w: 8, h: 8)
        XCTAssertLessThan(abs(defectAfter - ringAfter), abs(defectBefore - ringBefore) * 0.6,
                          "heal 后缺陷与邻域对比应至少下降 40%")
        XCTAssertEqual(ringAfter, ringBefore, accuracy: 0.01,
                       "heal 足迹外的干净区域不应被改变")

        // Far outside the stroke the pixels must stay byte-identical.
        XCTAssertEqual(try render(baseOut.image)[0], before[0], accuracy: 1e-6)
        let farDifference = maximumAbsoluteDifference(before, after, width: width, height: height,
                                                      region: { column, _ in column < 30 || column > 66 })
        XCTAssertLessThan(farDifference, 1e-4,
                          "修复笔迹不应影响足迹之外的像素")
    }

    /// The clone stage must sample the image *after* lens effects: the copied
    /// centre equals the lens-only output at the source position, not the original.
    func testRepairBrushRunsAfterLensEffectsAndCopiesPostStagePixels() throws {
        let width = 120, height = 80
        let source = makeImage(width: width, height: height) { column, row in
            let x = Float(column) / Float(width - 1)
            let y = Float(row) / Float(height - 1)
            return (0.15 + 0.6 * x, 0.12 + 0.5 * y, 0.18 + 0.4 * x * y, 1)
        }
        var lens = AdjustmentSettings()
        var effects = LensEffectsSettings()
        effects.vignetteAmount = -0.85
        lens.lensEffects = effects
        let engine = PhotoEngine()
        let lensOnly = try engine.process(source, settings: lens, lut: nil)

        var clone = RepairStroke(mode: .clone,
                                 points: [MaskPoint(x: 0.25, y: 0.5)],
                                 radius: 0.08, feather: 0, strength: 1)
        clone.cloneOffset = MaskPoint(x: 0.6, y: 0) // source centre x = 0.85
        var combined = lens
        combined.repairBrush = RepairBrushSettings(strokes: [clone])
        let repaired = try engine.process(source, settings: combined, lut: nil)
        XCTAssertEqual(repaired.report.repairBrush?.cloneStrokeCount, 1)

        let lensPixels = try render(lensOnly.image)
        let repairedPixels = try render(repaired.image)
        func meanRGB(_ pixels: [Float], column0: Int, row0: Int, w: Int, h: Int) -> (Float, Float, Float) {
            var r: Float = 0, g: Float = 0, b: Float = 0, count: Float = 0
            for row in row0..<(row0 + h) {
                for column in column0..<(column0 + w) {
                    let offset = (row * width + column) * 4
                    r += pixels[offset]; g += pixels[offset + 1]; b += pixels[offset + 2]
                    count += 1
                }
            }
            return (r / count, g / count, b / count)
        }
        let sourceMean = meanRGB(lensPixels, column0: 100, row0: 38, w: 4, h: 4)  // x≈0.85
        let targetBefore = meanRGB(lensPixels, column0: 28, row0: 38, w: 4, h: 4) // x≈0.25
        let targetAfter = meanRGB(repairedPixels, column0: 28, row0: 38, w: 4, h: 4)
        XCTAssertGreaterThan(abs(targetBefore.0 - sourceMean.0), 0.01,
                             "镜头暗角必须让来源与目标原本不同，否则顺序断言无意义")
        XCTAssertEqual(targetAfter.0, sourceMean.0, accuracy: 0.01,
                       "clone 必须复制镜头效果之后的像素（修复在镜头效果之后）")
        XCTAssertEqual(targetAfter.1, sourceMean.1, accuracy: 0.01)
        XCTAssertEqual(targetAfter.2, sourceMean.2, accuracy: 0.01)

        // Documented boundary: "before portrait" is guaranteed by the documented
        // stage order (lens → repair → portrait); observing it from pixels would
        // require a real face, which synthetic fixtures deliberately avoid.
    }

    /// B2 review F1: strength/feather blending happens in the engine working space
    /// (extended linear sRGB here), not in encoded sRGB. This pins the semantics
    /// that were previously only measured in an sRGB-space probe.
    func testRepairBrushPartialStrengthBlendsInEngineWorkingSpace() throws {
        let width = 80, height = 80
        let source = makeImage(width: width, height: height) { column, _ in
            if column < width / 2 { return (0.18, 0.18, 0.18, 1) }
            return (0.60, 0.02, 0.02, 1)
        }
        var settings = AdjustmentSettings()
        var stroke = RepairStroke(mode: .clone,
                                  points: [MaskPoint(x: 0.25, y: 0.5)],
                                  radius: 0.15, feather: 0, strength: 0.5)
        stroke.cloneOffset = MaskPoint(x: 0.5, y: 0)
        settings.repairBrush = RepairBrushSettings(strokes: [stroke])
        let output = try PhotoEngine().process(source, settings: settings, lut: nil)
        let pixels = try render(output.image)
        let offset = (40 * width + 20) * 4
        let red = pixels[offset], green = pixels[offset + 1], blue = pixels[offset + 2]
        // Linear-space mix: 0.5 × red donor + 0.5 × grey background.
        XCTAssertEqual(red, 0.5 * 0.60 + 0.5 * 0.18, accuracy: 0.02,
                       "强度 0.5 应在 working space（线性）混合")
        XCTAssertEqual(green, 0.5 * 0.02 + 0.5 * 0.18, accuracy: 0.02)
        XCTAssertEqual(blue, 0.5 * 0.02 + 0.5 * 0.18, accuracy: 0.02)
        // A naive encoded-sRGB mix would land clearly lower for red; keep this as
        // a guard that the blend is not silently moved into sRGB space later.
        func encodeSRGB(_ value: Float) -> Float {
            value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
        }
        func decodeSRGB(_ value: Float) -> Float {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let srgbMix = decodeSRGB(0.5 * encodeSRGB(0.60) + 0.5 * encodeSRGB(0.18))
        XCTAssertGreaterThan(abs(red - srgbMix), 0.02,
                             "若在 sRGB 编码空间混合会得到 \(srgbMix)，与线性工作空间明显不同")
    }

    /// S4: the panel slider/clamp range (app target, not unit-testable here) must
    /// stay aligned with the engine-accepted radius bounds; pin those bounds and
    /// make sure both extremes are usable in the real pipeline.
    func testRepairBrushRadiusBoundsMatchEngineContract() throws {
        for radius in [0.0005, 0.001, 0.06, 0.25, 0.5] {
            XCTAssertNoThrow(try RepairStroke(mode: .heal,
                                              points: [MaskPoint(x: 0.5, y: 0.5)],
                                              radius: radius).validate(),
                             "radius \(radius) must be accepted by the engine contract")
        }
        for radius in [0.000_499, 0.500_001, 0.0, -0.1, .nan, .infinity] {
            XCTAssertThrowsError(try RepairStroke(mode: .heal,
                                                  points: [MaskPoint(x: 0.5, y: 0.5)],
                                                  radius: radius).validate(),
                                 "radius \(radius) must be rejected by the engine contract")
        }
        // Both extremes run through the real pipeline without error and keep extent.
        let source = makeImage(width: 64, height: 48) { column, row in
            let x = Float(column) / 63, y = Float(row) / 47
            return (0.2 + 0.5 * x, 0.25 + 0.4 * y, 0.3 + 0.3 * x, 1)
        }
        for radius in [0.0005, 0.5] {
            var settings = AdjustmentSettings()
            settings.repairBrush = RepairBrushSettings(strokes: [
                RepairStroke(mode: .heal, points: [MaskPoint(x: 0.5, y: 0.5)], radius: radius)
            ])
            let output = try PhotoEngine().process(source, settings: settings, lut: nil)
            XCTAssertEqual(output.image.extent, source.extent)
            XCTAssertEqual(output.report.repairBrush?.strokeCount, 1)
        }
    }

    func testBatchManifestRecordsPerPhotoRepairBrushStatus() throws {
        let temp = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input", isDirectory: true)
        let output = temp.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let context = PhotoEngine().context
        let image = CIImage(color: CIColor(red: 0.3, green: 0.25, blue: 0.2, alpha: 1,
                                          colorSpace: linearColorSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 48, height: 48))
        var export = ExportSettings()
        export.format = .png
        try PhotoExporter.write(image: image, to: input.appendingPathComponent("flat.png"),
                                settings: export, sourceProperties: [:], context: context)

        var settings = AdjustmentSettings()
        settings.repairBrush = RepairBrushSettings(strokes: [
            RepairStroke(mode: .heal, points: [MaskPoint(x: 0.5, y: 0.5)], radius: 0.2)
        ])
        var recipe = Recipe(adjustments: settings)
        recipe.version = 12
        let summary = try BatchProcessor().run(items: PhotoLoader.scan(folder: input, recursive: false),
                                               inputRoot: input, outputRoot: output,
                                               recipe: recipe, lut: nil,
                                               cancellation: CancellationToken(), onEvent: { _ in })
        XCTAssertEqual(summary.succeeded, 1)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: XCTUnwrap(summary.manifestURL))) as? [String: Any])
        let recipePayload = try XCTUnwrap(manifest["recipe"] as? [String: Any])
        XCTAssertEqual(recipePayload["version"] as? Int, 12)
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        let report = try XCTUnwrap(try XCTUnwrap(entries.first)["report"] as? [String: Any])
        let repair = try XCTUnwrap(report["repairBrush"] as? [String: Any],
                                   "batch manifest must record the per-photo repair status")
        XCTAssertEqual(repair["applied"] as? Bool, true)
        XCTAssertEqual(repair["strokeCount"] as? Int, 1)
        XCTAssertEqual(repair["healStrokeCount"] as? Int, 1)
        XCTAssertEqual(repair["cloneStrokeCount"] as? Int, 0)
    }
}

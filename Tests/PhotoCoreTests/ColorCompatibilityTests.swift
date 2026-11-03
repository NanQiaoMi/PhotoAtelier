import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class ColorCompatibilityTests: XCTestCase {
    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var renderContext = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: false,
        .cacheIntermediates: false
    ])

    func testSparseP3LUTMatchesCPUAtOffGridInputs() throws {
        let sourceRGB = [0.08, 0.48, 0.12]
        let source = solid(sourceRGB, extent: CGRect(x: 0, y: 0, width: 8, height: 8))
        var settings = lutSettings(.displayP3)
        settings.colorHarmony = ColorHarmonySettings()
        settings.colorHarmony?.enabled = false
        for size in [2, 3, 4, 6, 9, 16, 17, 33] {
            let result = try PhotoEngine().process(source, settings: settings,
                                                  lut: affineColorCube(size: size, greenOffset: 0.10,
                                                                       greenSlope: 0.80)).image
            let actual = try pixel(result, x: 4, y: 4)
            let expected = cpuColorCube(sourceRGB, colorSpace: .displayP3,
                                        greenOffset: 0.10, greenSlope: 0.80)
            print("P3_LUT_OFF_GRID size=\(size) actual=\(actual) expected=\(expected)")
            assertRGBEqual(actual, expected, accuracy: 0.0003, "\(size)³ off-grid")
        }
    }

    func testPreciseLUTPreservesMixedAxisFunctionDomainAlphaAndExtent() throws {
        func transform(_ r: Double, _ g: Double, _ b: Double) -> [Double] {
            [0.1 + 0.2 * r + 0.2 * g * b,
             0.1 + 0.5 * g + 0.2 * max(0, r - 1.0 / 3.0),
             0.05 + 0.2 * b + 0.15 * r * g]
        }
        let lut = try colorCube(size: 4, inputRange: 0.1...0.9) { r, g, b in
            let value = transform(r, g, b)
            return (value[0], value[1], value[2])
        }
        var settings = lutSettings(.sRGB)
        settings.colorHarmony = ColorHarmonySettings()
        settings.colorHarmony?.enabled = false
        let extent = CGRect(x: 13, y: -6, width: 8, height: 8)
        for normalized in [[0.21, 0.37, 0.68], [0.73, 0.42, 0.24], [1.0, 0.0, 1.0]] {
            let linearInput = normalized.map { decodeSRGB(0.1 + 0.8 * $0) }
            let source = solid(linearInput, extent: extent, alpha: 0.35)
            let output = try PhotoEngine().process(source, settings: settings, lut: lut).image
            let expected = transform(normalized[0], normalized[1], normalized[2]).map(decodeSRGB)
            let actual = try pixel(output, x: 15, y: -4)
            XCTAssertEqual(output.extent, extent)
            XCTAssertEqual(actual[3], 0.35, accuracy: 0.001)
            assertRGBEqual(actual, expected, accuracy: 0.002)
        }
        let outsideInput = [1.05, 0.3, 0.2].map(decodeSRGB)
        let outside = solid(outsideInput, extent: extent, alpha: 0.35)
        let faded = try PhotoEngine().process(outside, settings: settings, lut: lut).image
        assertRGBEqual(try pixel(faded, x: 15, y: -4), outsideInput, accuracy: 0.002,
                       "域外颜色应回退至原色，而不是夹入 LUT 边界")
    }

    func testMaximumDimensionLUTAddressesLastNode() throws {
        let size = 128
        let text = "LUT_3D_SIZE \(size)\n"
            + String(repeating: "0 0 0\n", count: size * size * size - 1) + "1 0.5 0.25\n"
        let lut = try LUTCube.parse(text)
        var settings = lutSettings(.sRGB)
        settings.colorHarmony = ColorHarmonySettings()
        settings.colorHarmony?.enabled = false
        let input = solid([1, 1, 1], extent: CGRect(x: 0, y: 0, width: 8, height: 8))
        let output = try PhotoEngine().process(input, settings: settings, lut: lut).image
        assertRGBEqual(try pixel(output, x: 4, y: 4), [1, 0.5, 0.25].map(decodeSRGB),
                       accuracy: 0.002, "128³ 末节点必须可寻址，不能静默返回空纹理")
    }

    func testP3LUTAndSRGBLUTUseTheirTransferAndPrimaryMatrices() throws {
        let engine = PhotoEngine()
        // Land the P3 interpretation on exact lattice coordinates so this
        // comparison does not depend on low-resolution cube interpolation.
        let p3InputCodes = [6.0 / 16.0, 10.0 / 16.0, 4.0 / 16.0]
        let sourceRGB = p3ToSRGB(p3InputCodes.map(decodeSRGB))
        let p3RoundTripCodes = sRGBToP3(sourceRGB).map(encodeSRGB)
        for channel in 0..<3 {
            XCTAssertEqual(p3RoundTripCodes[channel], p3InputCodes[channel], accuracy: 0.00001,
                           "CPU 参考输入应落在 17³ P3 LUT 的节点上")
        }
        let source = solid(sourceRGB, extent: CGRect(x: 11, y: -7, width: 8, height: 8))
        let lut = try affineColorCube(size: 17)

        let p3Image = try engine.process(source,
                                         settings: lutSettings(.displayP3),
                                         lut: lut).image
        let sRGBImage = try engine.process(source,
                                           settings: lutSettings(.sRGB),
                                           lut: lut).image
        let p3Actual = try pixel(p3Image, x: 14, y: -4)
        let sRGBActual = try pixel(sRGBImage, x: 14, y: -4)
        let p3Expected = cpuColorCube(sourceRGB, colorSpace: .displayP3)
        let sRGBExpected = cpuColorCube(sourceRGB, colorSpace: .sRGB)

        assertRGBEqual(p3Actual, p3Expected, accuracy: 0.004)
        assertRGBEqual(sRGBActual, sRGBExpected, accuracy: 0.004)
        let expectedInterpretationDelta = (0..<3).map {
            abs(p3Expected[$0] - sRGBExpected[$0])
        }.max() ?? 0
        let actualInterpretationDelta = maxRGBDistance(p3Actual, sRGBActual)
        XCTAssertGreaterThan(expectedInterpretationDelta, 0.07,
                             "CPU 参考值应证明该有色 LUT 对主色解释有显著差异")
        XCTAssertEqual(actualInterpretationDelta, expectedInterpretationDelta, accuracy: 0.008,
                       "渲染差异应符合 CPU 矩阵与传递函数预测")
        XCTAssertGreaterThan(actualInterpretationDelta, 0.07,
                             "同一有色 LUT 按 P3 与 sRGB 解读应产生可测量的主色差异")
    }

    func testP3IdentityLUTRoundTripsP3GreenOutsideSRGB() throws {
        let p3GreenInLinearSRGB = p3ToSRGB([0, 1, 0])
        let extent = CGRect(x: -9, y: 17, width: 8, height: 8)
        let source = solid(p3GreenInLinearSRGB, extent: extent)
        let identity = try colorCube { ($0, $1, $2) }
        let output = try PhotoEngine().process(source,
                                               settings: lutSettings(.displayP3),
                                               lut: identity).image
        let actual = try pixel(output, x: -5, y: 21)

        assertRGBEqual(actual, p3GreenInLinearSRGB, accuracy: 0.008)
        XCTAssertLessThan(actual[0], -0.15, "P3 绿色转换到工作 sRGB 后应保留负红分量")
        XCTAssertGreaterThan(actual[1], 1.02, "P3 绿色转换到工作 sRGB 后应保留过范围绿分量")
        XCTAssertLessThan(actual[2], -0.04, "P3 绿色转换到工作 sRGB 后应保留负蓝分量")
    }

    func testRec709OETFAndGamma24AreDistinctAndMatchCPUDecoders() throws {
        let encodedOutput = [0.40, 0.55, 0.75]
        let constant = try colorCube { _, _, _ in
            (encodedOutput[0], encodedOutput[1], encodedOutput[2])
        }
        let source = solid([0.18, 0.24, 0.32], extent: CGRect(x: 0, y: 0, width: 8, height: 8))
        let engine = PhotoEngine()
        let gammaImage = try engine.process(source,
                                            settings: lutSettings(.rec709),
                                            lut: constant).image
        let oetfImage = try engine.process(source,
                                           settings: lutSettings(.rec709OETF),
                                           lut: constant).image
        let gammaActual = try pixel(gammaImage, x: 4, y: 4)
        let oetfActual = try pixel(oetfImage, x: 4, y: 4)

        for channel in 0..<3 {
            let code = encodedOutput[channel]
            XCTAssertEqual(gammaActual[channel], Float(decodeGamma24(code)), accuracy: 0.003)
            XCTAssertEqual(oetfActual[channel], Float(decodeRec709OETF(code)), accuracy: 0.003)
            XCTAssertGreaterThan(abs(oetfActual[channel] - gammaActual[channel]), 0.02,
                                 "Rec.709 OETF 与 Gamma 2.4 在该码值应有清晰差别")
        }
    }

    func testOutputMapperKeepsP3PrimaryInP3AndCompressesItForSRGB() throws {
        let p3GreenInLinearSRGB = p3ToSRGB([0, 1, 0])
        let extent = CGRect(x: 23, y: -12, width: 1, height: 1)
        let source = solid(p3GreenInLinearSRGB, extent: extent)
        let p3Output = try OutputGamutMapper.map(source, to: .displayP3, context: renderContext)
        let sRGBOutput = try OutputGamutMapper.map(source, to: .sRGB, context: renderContext)
        let p3Actual = try pixel(p3Output, x: 23, y: -12)
        let sRGBActual = try pixel(sRGBOutput, x: 23, y: -12)

        XCTAssertEqual(p3Output.extent, extent)
        XCTAssertEqual(sRGBOutput.extent, extent)
        assertRGBEqual(p3Actual, p3GreenInLinearSRGB, accuracy: 0.002,
                       "P3 内的像素应通过 P3 映射保持不变")
        let p3AfterSRGBMapping = sRGBToP3(Array(sRGBActual[0..<3]).map(Double.init))
        XCTAssertGreaterThan(maxComponent(p3AfterSRGBMapping) - minComponent(p3AfterSRGBMapping), 0.65,
                             "映射到 sRGB 后仍应保留绿色主色方向")
        XCTAssertLessThan(rgbDistance(p3AfterSRGBMapping, [0, 1, 0]), 0.35,
                          "sRGB 色域映射应尽量保留 P3 绿色的色相与亮度")
        for channel in 0..<3 {
            XCTAssertTrue(sRGBActual[channel].isFinite)
            XCTAssertGreaterThanOrEqual(sRGBActual[channel], -0.001)
            XCTAssertLessThanOrEqual(sRGBActual[channel], 1.001)
        }
    }

    func testOutputMapperBoundsNegativeAndOverexposedPixelsAndKeepsAlpha() throws {
        let extent = CGRect(x: -4, y: 29, width: 4, height: 1)
        let source = bitmap([
            -0.20, 0.40, 0.15, 1.00,
             1.80, 1.40, 1.20, 1.00,
             0.30, 0.20, 0.10, 0.35,
             0.00, 0.00, 0.00, 0.00
        ], width: 4, height: 1, origin: CGPoint(x: extent.minX, y: extent.minY))
        let mapped = try OutputGamutMapper.map(source, to: .sRGB, context: renderContext)
        XCTAssertEqual(mapped.extent, extent)

        let expectedAlpha: [Float] = [1, 1, 0.35, 0]
        for index in 0..<4 {
            let output = try pixel(mapped, x: index - 4, y: 29)
            XCTAssertTrue(output.allSatisfy(\.isFinite), "pixel \(index) 应为有限值")
            XCTAssertEqual(output[3], expectedAlpha[index], accuracy: 0.002,
                           "色域映射应保留 alpha")
            for channel in 0..<3 {
                XCTAssertGreaterThanOrEqual(output[channel], -0.001,
                                            "pixel \(index), channel \(channel) 应不低于目标下界")
                XCTAssertLessThanOrEqual(output[channel], 1.001,
                                         "pixel \(index), channel \(channel) 应不超过目标上界")
            }
        }
        let transparent = try pixel(mapped, x: -1, y: 29)
        XCTAssertEqual(transparent[0], 0, accuracy: 0.001)
        XCTAssertEqual(transparent[1], 0, accuracy: 0.001)
        XCTAssertEqual(transparent[2], 0, accuracy: 0.001)
    }

    func testEngineMapsV3OutputWhenProtectionIsOffButPreservesLegacyNil() throws {
        let p3GreenInLinearSRGB = p3ToSRGB([0, 1, 0])
        let extent = CGRect(x: 5, y: 8, width: 8, height: 8)
        let source = solid(p3GreenInLinearSRGB, extent: extent)
        let engine = PhotoEngine()

        var v3Off = AdjustmentSettings()
        v3Off.autoExposure = false
        v3Off.colorHarmony = ColorHarmonySettings()
        v3Off.colorHarmony?.enabled = false
        let mapped = try engine.process(source, settings: v3Off, lut: nil,
                                        outputColorSpace: .sRGB).image

        var legacy = v3Off
        legacy.colorHarmony = nil
        let legacyOutput = try engine.process(source, settings: legacy, lut: nil,
                                              outputColorSpace: .sRGB).image
        let mappedPixel = try pixel(mapped, x: 8, y: 11)
        let legacyPixel = try pixel(legacyOutput, x: 8, y: 11)

        XCTAssertEqual(mapped.extent, extent)
        for channel in 0..<3 {
            XCTAssertGreaterThanOrEqual(mappedPixel[channel], -0.001)
            XCTAssertLessThanOrEqual(mappedPixel[channel], 1.001)
        }
        assertRGBEqual(legacyPixel, p3GreenInLinearSRGB, accuracy: 0.002,
                       "旧配方没有 colorHarmony 时应保留既有扩展范围结果")
        XCTAssertLessThan(legacyPixel[0], 0)
        XCTAssertGreaterThan(legacyPixel[1], 1)
    }

    func testHarmonyOffAndZeroAmountAreExactNoOps() throws {
        let extent = CGRect(x: -3, y: 6, width: 12, height: 9)
        let reference = solid([0.20, 0.20, 0.20], extent: extent)
        let candidate = solid([0.31, 0.08, 0.16], extent: extent)

        var off = ColorHarmonySettings()
        off.enabled = false
        let disabled = try ColorHarmonyEngine.protect(reference: reference,
                                                       candidate: candidate,
                                                       settings: off,
                                                       scene: nil,
                                                       context: renderContext)
        var zeroAmount = ColorHarmonySettings()
        zeroAmount.amount = 0
        let zero = try ColorHarmonyEngine.protect(reference: reference,
                                                   candidate: candidate,
                                                   settings: zeroAmount,
                                                   scene: nil,
                                                   context: renderContext)

        XCTAssertTrue(disabled === candidate)
        XCTAssertTrue(zero === candidate)
        XCTAssertEqual(disabled.extent, extent)
        XCTAssertEqual(zero.extent, extent)
    }

    func testLegacyRecipeWithoutColorHarmonyDecodesAsNil() throws {
        var recipe = Recipe()
        recipe.version = 2
        let encoded = try JSONEncoder().encode(recipe)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var adjustments = try XCTUnwrap(object["adjustments"] as? [String: Any])
        XCTAssertNotNil(adjustments["colorHarmony"], "新配方编码应含可选字段")
        adjustments.removeValue(forKey: "colorHarmony")
        object["adjustments"] = adjustments

        let oldRecipe = try JSONDecoder().decode(Recipe.self,
                                                 from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(oldRecipe.adjustments.colorHarmony)
        XCTAssertEqual(oldRecipe.version, 2)
    }

    func testBatchAcceptsRecipeVersionsOneThroughTenAndRejectsEleven() throws {
        let root = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let processor = BatchProcessor()

        for version in 1...10 {
            var recipe = Recipe()
            recipe.version = version
            let output = root.appendingPathComponent("output-\(version)", isDirectory: true)
            let summary = try processor.run(items: [], inputRoot: input, outputRoot: output,
                                            recipe: recipe, lut: nil,
                                            cancellation: CancellationToken(), onEvent: { _ in })
            XCTAssertEqual(summary.succeeded, 0)
            XCTAssertEqual(summary.failed, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(summary.manifestURL).path))
        }

        var futureRecipe = Recipe()
        futureRecipe.version = 11
        let rejectedOutput = root.appendingPathComponent("output-11", isDirectory: true)
        XCTAssertThrowsError(try processor.run(items: [], inputRoot: input, outputRoot: rejectedOutput,
                                               recipe: futureRecipe, lut: nil,
                                               cancellation: CancellationToken(), onEvent: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedOutput.path),
                       "未知版本应在创建输出目录前被拒绝")
    }

    func testPortraitRecipeRequiresV10RoundTripsAndLegacyPayloadsKeepOldPath() throws {
        var settings = AdjustmentSettings()
        settings.portrait = PortraitRefinementSettings(blemishStrength: 0.5, teethWhiten: 0.3,
                                                       eyeBrighten: 0.2, skinToneUnify: 0.4,
                                                       skinToneReference: .brightest)
        var recipe = Recipe(adjustments: settings)
        recipe.version = 9
        XCTAssertThrowsError(try recipe.validateVersion(),
                             "v9 配方不得静默接受非中性人像字段")
        recipe.version = 10
        XCTAssertNoThrow(try recipe.validateVersion())

        let encoded = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(Recipe.self, from: encoded)
        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(decoded.adjustments.portrait, settings.portrait)
        XCTAssertEqual(decoded.version, 10)

        // Old recipes carry no portrait key: they must decode as nil and keep the
        // pre-v10 pixel path (identical to a neutral current recipe).
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var adjustments = try XCTUnwrap(object["adjustments"] as? [String: Any])
        adjustments.removeValue(forKey: "portrait")
        object["adjustments"] = adjustments
        object["version"] = 9
        let legacy = try JSONDecoder().decode(Recipe.self,
                                              from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.adjustments.portrait)
        XCTAssertNoThrow(try legacy.validateVersion())

        let extent = CGRect(x: 0, y: 0, width: 4, height: 4)
        let source = solid([0.32, 0.20, 0.14], extent: extent)
        let legacyImage = try PhotoEngine().process(source, settings: legacy.adjustments, lut: nil).image
        let neutralImage = try PhotoEngine().process(source, settings: AdjustmentSettings(), lut: nil).image
        let legacyPixel = try pixel(legacyImage, x: 1, y: 1)
        let neutralPixel = try pixel(neutralImage, x: 1, y: 1)
        for channel in 0..<4 {
            XCTAssertEqual(legacyPixel[channel], neutralPixel[channel], accuracy: 1e-9)
        }
    }

    func testLUT3DInputRangeMapsToScalarDomain() throws {
        let cube = try LUTCube.parse(cubeText(headers: ["LUT_3D_INPUT_RANGE -0.5 1.5"]))

        XCTAssertEqual(cube.domainMin, SIMD3<Float>(repeating: -0.5))
        XCTAssertEqual(cube.domainMax, SIMD3<Float>(repeating: 1.5))
        let midpoint = cube.sample(SIMD3<Float>(repeating: 0.5))
        XCTAssertEqual(midpoint.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(midpoint.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(midpoint.z, 0.5, accuracy: 0.0001)
    }

    func testLUT3DInputRangeRejectsDomainConflictsDuplicatesAndUnsafeNumbers() {
        let conflictingHeaders = [
            ["LUT_3D_INPUT_RANGE 0 1", "DOMAIN_MIN 0 0 0"],
            ["DOMAIN_MAX 1 1 1", "LUT_3D_INPUT_RANGE 0 1"],
            ["LUT_3D_INPUT_RANGE 0 1", "LUT_3D_INPUT_RANGE 0 1"]
        ]
        for headers in conflictingHeaders {
            XCTAssertThrowsError(try LUTCube.parse(cubeText(headers: headers)),
                                 "应拒绝互斥或重复的范围声明：\(headers)")
        }

        let unsafeRanges = [
            "LUT_3D_INPUT_RANGE 0 0",
            "LUT_3D_INPUT_RANGE 0 0.0000005",
            "LUT_3D_INPUT_RANGE NaN 1",
            "LUT_3D_INPUT_RANGE 0 Infinity",
            "LUT_3D_INPUT_RANGE -16.001 1",
            "LUT_3D_INPUT_RANGE 0 16.001"
        ]
        for header in unsafeRanges {
            XCTAssertThrowsError(try LUTCube.parse(cubeText(headers: [header])),
                                 "应拒绝不安全的输入范围：\(header)")
        }
    }

    private func lutSettings(_ colorSpace: LUTColorSpace) -> AdjustmentSettings {
        var settings = AdjustmentSettings()
        settings.autoExposure = false
        settings.lutIntensity = 1
        settings.lutColorSpace = colorSpace
        settings.preserveLuminance = 0
        settings.protectSkin = 0
        settings.protectNeutrals = 0
        settings.gamutCompression = 0
        // Exercise the legacy LUT math without the independent harmony stage.
        settings.colorHarmony = nil
        return settings
    }

    private func affineColorCube(size: Int, greenOffset: Double = 0.05,
                                 greenSlope: Double = 0.95) throws -> LUTCube {
        try colorCube(size: size) { red, green, blue in
            (0.05 + 0.10 * red + 0.04 * green,
             greenOffset + greenSlope * green,
             0.05 + 0.06 * red + 0.08 * blue)
        }
    }

    private func colorCube(size: Int = 2, inputRange: ClosedRange<Double>? = nil,
                           _ transform: (Double, Double, Double) -> (Double, Double, Double)) throws -> LUTCube {
        var rows: [String] = []
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let divisor = Double(size - 1)
                    let value = transform(Double(red) / divisor,
                                          Double(green) / divisor,
                                          Double(blue) / divisor)
                    rows.append("\(value.0) \(value.1) \(value.2)")
                }
            }
        }
        let range = inputRange.map { "LUT_3D_INPUT_RANGE \($0.lowerBound) \($0.upperBound)\n" } ?? ""
        return try LUTCube.parse("LUT_3D_SIZE \(size)\n" + range + rows.joined(separator: "\n"))
    }

    private func cubeText(headers: [String]) -> String {
        let rows = (0...1).flatMap { blue in
            (0...1).flatMap { green in
                (0...1).map { red in "\(red) \(green) \(blue)" }
            }
        }
        return (["LUT_3D_SIZE 2"] + headers + rows).joined(separator: "\n")
    }

    private func cpuColorCube(_ linearSRGB: [Double], colorSpace: LUTColorSpace,
                               greenOffset: Double = 0.05, greenSlope: Double = 0.95) -> [Double] {
        let lutInputLinear = colorSpace == .displayP3 ? sRGBToP3(linearSRGB) : linearSRGB
        let encoded = lutInputLinear.map(encodeSRGB)
        let cubeOutput = [
            0.05 + 0.10 * encoded[0] + 0.04 * encoded[1],
            greenOffset + greenSlope * encoded[1],
            0.05 + 0.06 * encoded[0] + 0.08 * encoded[2]
        ]
        let decoded = cubeOutput.map(decodeSRGB)
        return colorSpace == .displayP3 ? p3ToSRGB(decoded) : decoded
    }

    private func sRGBToP3(_ rgb: [Double]) -> [Double] {
        [
            0.8224619687 * rgb[0] + 0.1775380313 * rgb[1],
            0.0331941989 * rgb[0] + 0.9668058011 * rgb[1],
            0.0170826307 * rgb[0] + 0.0723974407 * rgb[1] + 0.9105199286 * rgb[2]
        ]
    }

    private func p3ToSRGB(_ rgb: [Double]) -> [Double] {
        [
            1.2249401763 * rgb[0] - 0.2249401763 * rgb[1],
            -0.0420569547 * rgb[0] + 1.0420569547 * rgb[1],
            -0.0196375546 * rgb[0] - 0.0786360456 * rgb[1] + 1.0982736001 * rgb[2]
        ]
    }

    private func encodeSRGB(_ value: Double) -> Double {
        let magnitude = abs(value)
        let encoded = magnitude <= 0.0031308
            ? 12.92 * magnitude
            : 1.055 * pow(magnitude, 1.0 / 2.4) - 0.055
        return value < 0 ? -encoded : encoded
    }

    private func decodeSRGB(_ value: Double) -> Double {
        let magnitude = abs(value)
        let decoded = magnitude <= 0.04045
            ? magnitude / 12.92
            : pow((magnitude + 0.055) / 1.055, 2.4)
        return value < 0 ? -decoded : decoded
    }

    private func decodeGamma24(_ value: Double) -> Double {
        (value < 0 ? -1 : 1) * pow(abs(value), 2.4)
    }

    private func decodeRec709OETF(_ value: Double) -> Double {
        let magnitude = abs(value)
        let decoded = magnitude < 0.081
            ? magnitude / 4.5
            : pow((magnitude + 0.099) / 1.099, 1.0 / 0.45)
        return value < 0 ? -decoded : decoded
    }

    private func solid(_ rgb: [Double], extent: CGRect, alpha: Double = 1) -> CIImage {
        CIImage(color: CIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: alpha,
                               colorSpace: linearColorSpace)!)
            .cropped(to: extent)
    }

    /// The input pixels use straight-alpha values; CIImage bitmap data uses premultiplied RGBA.
    private func bitmap(_ pixels: [Float], width: Int, height: Int, origin: CGPoint = .zero) -> CIImage {
        var premultiplied = pixels
        for offset in stride(from: 0, to: premultiplied.count, by: 4) {
            let alpha = premultiplied[offset + 3]
            premultiplied[offset] *= alpha
            premultiplied[offset + 1] *= alpha
            premultiplied[offset + 2] *= alpha
        }
        let data = premultiplied.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data,
                            bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                            size: CGSize(width: width, height: height),
                            format: .RGBAf,
                            colorSpace: linearColorSpace)
        return image.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
            .cropped(to: CGRect(origin: origin, size: CGSize(width: width, height: height)))
    }

    private func pixel(_ image: CIImage, x: Int, y: Int) throws -> [Float] {
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { buffer in
            renderContext.render(image, toBitmap: buffer.baseAddress!,
                                 rowBytes: 4 * MemoryLayout<Float>.size,
                                 bounds: CGRect(x: x, y: y, width: 1, height: 1),
                                 format: .RGBAf,
                                 colorSpace: linearColorSpace)
        }
        return values
    }

    private func assertRGBEqual(_ actual: [Float], _ expected: [Double], accuracy: Float,
                                _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<3 {
            XCTAssertEqual(actual[channel], Float(expected[channel]), accuracy: accuracy,
                           "\(message) channel \(channel)", file: file, line: line)
        }
    }

    private func maxRGBDistance(_ lhs: [Float], _ rhs: [Float]) -> Double {
        (0..<3).map { abs(Double(lhs[$0] - rhs[$0])) }.max() ?? 0
    }

    private func rgbDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        sqrt((0..<3).reduce(0) { $0 + pow(lhs[$1] - rhs[$1], 2) })
    }

    private func maxComponent(_ rgb: [Double]) -> Double { rgb.max() ?? 0 }
    private func minComponent(_ rgb: [Double]) -> Double { rgb.min() ?? 0 }
}

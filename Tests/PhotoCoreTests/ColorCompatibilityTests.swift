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
        let start = Date()
        let lut = try LUTCube.parse(text)
        let parseElapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(parseElapsed, 15.0, "128³ 文本解析应在 15 秒内完成，防止阻塞测试套件")
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

    func testBatchAcceptsRecipeVersionsOneThroughNineteenAndRejectsTwenty() throws {
        let root = try TestFiles.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let processor = BatchProcessor()

        for version in 1...21 {
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
        futureRecipe.version = 25
        let rejectedOutput = root.appendingPathComponent("output-25", isDirectory: true)
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

    // MARK: - Reference color ("AI 追色", v10)

    func testReferenceColorRequiresV10RoundTripsAndLegacyPayloadsKeepOldPath() throws {
        let profile = try ReferenceColorMatcher.profile(reference: warmReference())
        var settings = AdjustmentSettings()
        settings.referenceColor = ReferenceColorSettings(profile: profile, strength: 0.7)
        var recipe = Recipe(adjustments: settings)
        recipe.version = 9
        XCTAssertThrowsError(try recipe.validateVersion(),
                             "v9 配方不得静默接受非中性参考图追色")
        recipe.version = 10
        XCTAssertNoThrow(try recipe.validateVersion())

        let encoded = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(Recipe.self, from: encoded)
        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(decoded.adjustments.referenceColor, settings.referenceColor)
        XCTAssertEqual(decoded.version, 10)

        // A zero-strength reference color cannot change pixels, so a v9 recipe is
        // allowed to carry it (the gate rejects only non-neutral settings).
        var neutralSettings = settings
        neutralSettings.referenceColor?.strength = 0
        var neutralRecipe = Recipe(adjustments: neutralSettings)
        neutralRecipe.version = 9
        XCTAssertNoThrow(try neutralRecipe.validateVersion())

        // Old recipes carry no referenceColor key: they decode as nil and keep
        // the pre-v10 pixel path (identical to a neutral current recipe).
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var adjustments = try XCTUnwrap(object["adjustments"] as? [String: Any])
        adjustments.removeValue(forKey: "referenceColor")
        object["adjustments"] = adjustments
        object["version"] = 9
        let legacy = try JSONDecoder().decode(Recipe.self,
                                              from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.adjustments.referenceColor)
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

    func testReferenceColorValidationRejectsBrokenProfilesAndOutOfRangeStrength() throws {
        let profile = try ReferenceColorMatcher.profile(reference: warmReference())
        var settings = AdjustmentSettings()
        settings.referenceColor = ReferenceColorSettings(profile: profile, strength: 1.5)
        XCTAssertThrowsError(try PhotoEngine.validate(settings), "追色强度必须在 0...1")

        var nonFinite = settings
        nonFinite.referenceColor = ReferenceColorSettings(
            profile: ReferenceColorProfile(
                luminanceQuantiles: Array(repeating: .nan, count: 17),
                aQuantiles: profile.aQuantiles, bQuantiles: profile.bQuantiles,
                meanL: profile.meanL, meanA: profile.meanA, meanB: profile.meanB,
                sampleCount: profile.sampleCount),
            strength: 0.5)
        XCTAssertThrowsError(try PhotoEngine.validate(nonFinite), "损坏的 profile 必须在配方/引擎校验期拒绝")
    }

    func testReferenceColorNoReferenceAndZeroStrengthAreExactNoOps() throws {
        let candidate = coolCandidate()
        let engine = PhotoEngine()
        let baseline = try engine.process(candidate, settings: AdjustmentSettings(), lut: nil)
        XCTAssertNil(baseline.report.referenceColor, "无参考图时不写入追色报告")

        let profile = try ReferenceColorMatcher.profile(reference: warmReference())
        var zero = AdjustmentSettings()
        zero.referenceColor = ReferenceColorSettings(profile: profile, strength: 0)
        let zeroOutput = try engine.process(candidate, settings: zero, lut: nil)
        XCTAssertNil(zeroOutput.report.referenceColor, "强度 0 为中性，不应执行追色")
        for (x, y) in sampleGrid(width: 64, height: 48) {
            let before = try pixel(baseline.image, x: x, y: y)
            let after = try pixel(zeroOutput.image, x: x, y: y)
            for channel in 0..<4 {
                XCTAssertEqual(after[channel], before[channel], accuracy: 1e-9,
                               "强度 0 必须逐像素恒等（\(x),\(y) channel \(channel)）")
            }
        }

        var half = zero
        half.referenceColor?.strength = 0.5
        let halfOutput = try engine.process(candidate, settings: half, lut: nil)
        var maximumChange: Float = 0
        for (x, y) in sampleGrid(width: 64, height: 48) {
            let before = try pixel(baseline.image, x: x, y: y)
            let after = try pixel(halfOutput.image, x: x, y: y)
            maximumChange = max(maximumChange, Float(maxRGBDistance(after, before)))
        }
        XCTAssertGreaterThan(maximumChange, 0.0005, "非零强度必须产生可测变化（前后对比）")
        XCTAssertEqual(halfOutput.image.extent, candidate.extent)
    }

    func testReferenceColorMovesCandidateTowardReferenceAndRecordsReport() throws {
        let reference = warmReference(width: 64, height: 48)
        let profile = try ReferenceColorMatcher.profile(reference: reference)
        let candidate = coolCandidate(width: 64, height: 48)
        var settings = AdjustmentSettings()
        settings.referenceColor = ReferenceColorSettings(profile: profile, strength: 1)

        let output = try PhotoEngine().process(candidate, settings: settings, lut: nil)
        let before = chromaDistance(try meanOKLabChroma(candidate), profile)
        let after = chromaDistance(try meanOKLabChroma(output.image), profile)
        XCTAssertGreaterThan(before, 0.02, "合成夹具必须有可测的冷暖偏移")
        XCTAssertLessThan(after, before * 0.5,
                          "追色后 OKLab a/b 均值应明显向参考收敛（前 \(before) 后 \(after)）")
        XCTAssertEqual(output.report.referenceColor?.applied, true)
        XCTAssertEqual(output.report.referenceColor?.strength ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(output.report.referenceColor?.skinOnly, false)
        XCTAssertEqual(output.report.referenceColor?.algorithmVersion,
                       ReferenceColorProfile.currentAlgorithmVersion)
        XCTAssertEqual(output.image.extent, candidate.extent)

        var half = settings
        half.referenceColor?.strength = 0.5
        let halfOutput = try PhotoEngine().process(candidate, settings: half, lut: nil)
        let halfDistance = chromaDistance(try meanOKLabChroma(halfOutput.image), profile)
        XCTAssertGreaterThan(halfDistance, after, "半强度应比全强度更接近原图")
        XCTAssertLessThan(halfDistance, before, "半强度应比原图更接近参考")
    }

    func testReferenceColorSkinOnlyWithoutFaceSkipsExplicitly() throws {
        let profile = try ReferenceColorMatcher.profile(reference: warmReference())
        let candidate = coolCandidate()
        var settings = AdjustmentSettings()
        settings.referenceColor = ReferenceColorSettings(profile: profile, strength: 1, skinOnly: true)
        let output = try PhotoEngine().process(candidate, settings: settings, lut: nil)

        // No face in the synthetic fixture: the stage must not fall back to a
        // global match the user did not ask for.
        XCTAssertEqual(output.report.referenceColor?.applied, false)
        XCTAssertEqual(output.report.referenceColor?.skinOnly, true)
        XCTAssertTrue(output.report.referenceColor?.note?.contains("皮肤限定") == true,
                      "跳过原因必须写入报告：\(String(describing: output.report.referenceColor))")
        XCTAssertTrue(output.report.warnings.contains { $0.contains("皮肤限定") })
        let baseline = try PhotoEngine().process(candidate, settings: AdjustmentSettings(), lut: nil)
        for (x, y) in sampleGrid(width: 64, height: 48) {
            let before = try pixel(baseline.image, x: x, y: y)
            let after = try pixel(output.image, x: x, y: y)
            for channel in 0..<4 {
                XCTAssertEqual(after[channel], before[channel], accuracy: 1e-9,
                               "皮肤限定无脸时必须保持原图（\(x),\(y)）")
            }
        }
    }

    func testReferenceColorStageRunsBeforeLUT() throws {
        let profile = try ReferenceColorMatcher.profile(reference: warmReference())
        let candidate = coolCandidate()
        var matchOnly = AdjustmentSettings()
        matchOnly.referenceColor = ReferenceColorSettings(profile: profile, strength: 1)
        let matched = try PhotoEngine().process(candidate, settings: matchOnly, lut: nil).image

        // A non-identity LUT: if the reference match ran after the LUT, applying
        // the match to the LUT output would not reproduce this expected result.
        let lut = try colorCube(size: 2) { r, g, b in
            (min(1, 0.05 + 0.90 * r), min(1, 0.02 + 0.85 * g), min(1, 0.03 + 0.95 * b))
        }
        var both = matchOnly
        both.lutIntensity = 1
        let bothOutput = try PhotoEngine().process(candidate, settings: both, lut: lut).image
        var lutOnly = AdjustmentSettings()
        lutOnly.lutIntensity = 1
        let expected = try PhotoEngine().process(matched, settings: lutOnly, lut: lut).image
        for (x, y) in sampleGrid(width: 64, height: 48) {
            let actual = try pixel(bothOutput, x: x, y: y)
            let wanted = try pixel(expected, x: x, y: y)
            for channel in 0..<4 {
                XCTAssertEqual(actual[channel], wanted[channel], accuracy: 0.002,
                               "追色应在 LUT 之前应用（\(x),\(y) channel \(channel)）")
            }
        }
    }

    private func warmReference(width: Int = 32, height: Int = 32) -> CIImage {
        gradient(width: width, height: height) { x, y in
            let t = Float(x) / Float(max(width - 1, 1))
            let u = Float(y) / Float(max(height - 1, 1))
            return (0.55 + 0.30 * t, 0.38 + 0.25 * u, 0.22 + 0.18 * t)
        }
    }

    private func coolCandidate(width: Int = 64, height: Int = 48) -> CIImage {
        gradient(width: width, height: height) { x, y in
            let t = Float(x) / Float(max(width - 1, 1))
            let u = Float(y) / Float(max(height - 1, 1))
            return (0.30 + 0.35 * t, 0.38 + 0.30 * u, 0.55 + 0.20 * t)
        }
    }

    private func gradient(width: Int, height: Int,
                          pixel: (Int, Int) -> (Float, Float, Float)) -> CIImage {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let offset = (y * width + x) * 4
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = 1
            }
        }
        return bitmap(pixels, width: width, height: height)
    }

    private func sampleGrid(width: Int, height: Int) -> [(Int, Int)] {
        [(width / 4, height / 4), (width / 2, height / 2),
         (width * 3 / 4, height / 4), (width / 4, height * 3 / 4),
         (width * 3 / 4, height * 3 / 4)]
    }

    private func meanOKLabChroma(_ image: CIImage) throws -> (Double, Double) {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            renderContext.render(image, toBitmap: buffer.baseAddress!,
                                 rowBytes: width * 4 * MemoryLayout<Float>.size,
                                 bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                 format: .RGBAf, colorSpace: linearColorSpace)
        }
        var sumA = 0.0, sumB = 0.0, count = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[offset + 3] > 0.5 else { continue }
            let r = Double(pixels[offset]), g = Double(pixels[offset + 1]), b = Double(pixels[offset + 2])
            func root(_ value: Double) -> Double { copysign(pow(abs(value), 1.0 / 3.0), value) }
            let l = root(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = root(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = root(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
            let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
            sumA += a; sumB += bb; count += 1
        }
        return (sumA / count, sumB / count)
    }

    private func chromaDistance(_ mean: (Double, Double), _ profile: ReferenceColorProfile) -> Double {
        let da = mean.0 - profile.meanA
        let db = mean.1 - profile.meanB
        return (da * da + db * db).squareRoot()
    }

    func testPortraitVersionUpgradeContractForSavePath() throws {
        // Mirrors AppModel.portraitRecipeNeedsVersion10 / portraitRecipeVersion;
        // the app asserts the same rules directly in debug builds
        // (PORTRAIT_CONTRACT_SELF_CHECK) because this test target only links PhotoCore.
        var nilPortrait = AdjustmentSettings()
        XCTAssertNil(nilPortrait.portrait)
        var neutralPortrait = AdjustmentSettings()
        neutralPortrait.portrait = PortraitRefinementSettings()
        XCTAssertEqual(neutralPortrait.portrait?.isNeutral, true)
        var nonNeutralPortrait = AdjustmentSettings()
        nonNeutralPortrait.portrait = PortraitRefinementSettings(blemishStrength: 0.2)
        XCTAssertEqual(nonNeutralPortrait.portrait?.isNeutral, false)

        // Neutral payloads keep the v9 shape and pass the v9 gate.
        var neutralRecipe = Recipe(adjustments: neutralPortrait)
        neutralRecipe.version = 9
        XCTAssertNoThrow(try neutralRecipe.validateVersion())

        // Non-neutral portrait payloads must be written as v10.
        var legacyRecipe = Recipe(adjustments: nonNeutralPortrait)
        legacyRecipe.version = 9
        XCTAssertThrowsError(try legacyRecipe.validateVersion())
        var upgradedRecipe = Recipe(adjustments: nonNeutralPortrait)
        upgradedRecipe.version = 10
        XCTAssertNoThrow(try upgradedRecipe.validateVersion())

        // The upgraded payload keeps the portrait field; the neutral/absent one
        // keeps the old recipe shape (no portrait key).
        let upgradedJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(upgradedRecipe)) as? [String: Any])
        XCTAssertEqual(upgradedJSON["version"] as? Int, 10)
        XCTAssertNotNil((upgradedJSON["adjustments"] as? [String: Any])?["portrait"])

        var absentRecipe = Recipe(adjustments: nilPortrait)
        absentRecipe.version = 9
        let absentJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(absentRecipe)) as? [String: Any])
        XCTAssertNil((absentJSON["adjustments"] as? [String: Any])?["portrait"])
        XCTAssertNoThrow(try absentRecipe.validateVersion())
    }

    // MARK: - S3: skin coverage, automatic v10 gate, measurement merge

    func testSkinOnlyReferenceColorTreatsLowCoverageSkinMaskAsUnusable() throws {
        let engine = PhotoEngine()
        let extent = CGRect(x: 0, y: 0, width: 64, height: 48)

        // A non-nil but empty matte is what a grayscale/low-chroma face produces:
        // it must be rejected before any matching work.
        let empty = matteImage(width: 64, height: 48, extent: extent) { _, _ in 0 }
        XCTAssertEqual(PhotoEngine.skinMaskCoverage(of: empty, context: engine.context), 0, accuracy: 1e-9)
        XCTAssertNil(engine.usableSkinMask([maskSet(skin: empty, extent: extent)], extent: extent),
                     "全零皮肤蒙版必须判定为不可用")

        // A single covered pixel out of 3072 is below the 0.0005 threshold.
        let tiny = matteImage(width: 64, height: 48, extent: extent) { x, y in
            x == 0 && y == 0 ? 1 : 0
        }
        XCTAssertNil(engine.usableSkinMask([maskSet(skin: tiny, extent: extent)], extent: extent),
                     "覆盖低于 0.0005 的皮肤蒙版必须判定为不可用")

        // A real matte passes and its coverage is reported.
        let filled = matteImage(width: 64, height: 48, extent: extent) { _, _ in 0.5 }
        XCTAssertNotNil(engine.usableSkinMask([maskSet(skin: filled, extent: extent)], extent: extent))
        XCTAssertEqual(PhotoEngine.skinMaskCoverage(of: filled, context: engine.context), 0.5, accuracy: 0.002)

        // Threshold boundary behaviour is shared with the portrait inspector.
        XCTAssertEqual(PhotoEngine.minimumSkinMaskCoverage, 0.0005, accuracy: 1e-12)
        XCTAssertFalse(PhotoEngine.isUsableSkinCoverage(0))
        XCTAssertFalse(PhotoEngine.isUsableSkinCoverage(PhotoEngine.minimumSkinMaskCoverage))
        XCTAssertTrue(PhotoEngine.isUsableSkinCoverage(PhotoEngine.minimumSkinMaskCoverage * 2))
        XCTAssertFalse(PhotoEngine.isUsableSkinCoverage(.nan))
        XCTAssertFalse(PhotoEngine.isUsableSkinCoverage(.infinity))
    }

    func testAutomaticRecipeV10GateCoversAutomaticBaselineAndReferenceBranches() throws {
        let profile = try ReferenceColorMatcher.profile(reference: warmReference())

        // Non-neutral reference color in the automatic baseline: saving as v9
        // would be rejected by our own v10 gate on load.
        var referenceBaseline = AdjustmentSettings()
        referenceBaseline.referenceColor = ReferenceColorSettings(profile: profile, strength: 0.6)
        let automaticReference = AutomaticBatchRecipe(styleID: "balanced",
                                                      baseline: referenceBaseline,
                                                      referenceSettings: AdjustmentSettings())
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: AdjustmentSettings(),
                                                         automatic: automaticReference), 10)
        var referenceRecipe = Recipe(adjustments: AdjustmentSettings(), automatic: automaticReference)
        referenceRecipe.version = 9
        XCTAssertThrowsError(try referenceRecipe.validateVersion(),
                             "automatic baseline 的非中性追色也需要配方 v10")
        referenceRecipe.version = 10
        XCTAssertNoThrow(try referenceRecipe.validateVersion())

        // Non-neutral portrait in the automatic baseline.
        var portraitBaseline = AdjustmentSettings()
        portraitBaseline.portrait = PortraitRefinementSettings(blemishStrength: 0.3)
        let automaticPortrait = AutomaticBatchRecipe(styleID: "balanced",
                                                     baseline: portraitBaseline,
                                                     referenceSettings: AdjustmentSettings())
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: AdjustmentSettings(),
                                                         automatic: automaticPortrait), 10)
        var portraitRecipe = Recipe(adjustments: AdjustmentSettings(), automatic: automaticPortrait)
        portraitRecipe.version = 9
        XCTAssertThrowsError(try portraitRecipe.validateVersion())

        // Non-neutral reference color in the automatic reference settings.
        var referenceSettings = AdjustmentSettings()
        referenceSettings.referenceColor = ReferenceColorSettings(profile: profile, strength: 0.4)
        let automaticReferenceSettings = AutomaticBatchRecipe(styleID: "balanced",
                                                              baseline: AdjustmentSettings(),
                                                              referenceSettings: referenceSettings)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: AdjustmentSettings(),
                                                         automatic: automaticReferenceSettings), 10)

        // Neutral payloads keep v9.
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: AdjustmentSettings(),
                                                         automatic: nil), 9)
        var neutralPortrait = AdjustmentSettings()
        neutralPortrait.portrait = PortraitRefinementSettings()
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: neutralPortrait,
                                                         automatic: nil), 9)

        // Live adjustments are covered too (the W7 behaviour must not regress).
        var liveReference = AdjustmentSettings()
        liveReference.referenceColor = ReferenceColorSettings(profile: profile, strength: 0.7)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: liveReference,
                                                         automatic: nil), 10)
        var livePortrait = AdjustmentSettings()
        livePortrait.portrait = PortraitRefinementSettings(teethWhiten: 0.2)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: livePortrait,
                                                         automatic: nil), 10)
    }

    func testMergedReferenceColorSettingsKeepsEditsMadeDuringMeasurement() throws {
        let measured = try ReferenceColorMatcher.profile(reference: warmReference())
        let previousProfile = try ReferenceColorMatcher.profile(reference: coolCandidate())

        // A strength/skin-only edit made while the reference image was being
        // measured must survive; only the profile is replaced.
        let edited = ReferenceColorSettings(profile: previousProfile, strength: 0.3, skinOnly: true)
        let merged = PhotoEngine.mergedReferenceColorSettings(measured: measured, current: edited)
        XCTAssertEqual(merged.profile, measured)
        XCTAssertEqual(merged.strength, 0.3, accuracy: 1e-12)
        XCTAssertEqual(merged.skinOnly, true)

        // First import (no current settings) keeps the documented defaults.
        let defaults = PhotoEngine.mergedReferenceColorSettings(measured: measured, current: nil)
        XCTAssertEqual(defaults.profile, measured)
        XCTAssertEqual(defaults.strength, 0.65, accuracy: 1e-12)
        XCTAssertEqual(defaults.skinOnly, false)
    }

    private func maskSet(skin: CIImage, extent: CGRect) -> FaceSemanticMaskSet {
        FaceSemanticMaskSet(extent: extent,
                            resolution: CGSize(width: Int(extent.width), height: Int(extent.height)),
                            faceBounds: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                            confidence: 1, faceCount: 1,
                            skin: skin, teeth: nil, sclera: nil, iris: nil,
                            lips: nil, brows: nil)
    }

    private func matteImage(width: Int, height: Int, extent: CGRect,
                            coverage: (Int, Int) -> Double) -> CIImage {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = Float(min(max(coverage(x, y), 0), 1))
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 1
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data,
                            bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                            size: CGSize(width: width, height: height),
                            format: .RGBAf,
                            colorSpace: linearColorSpace)
        guard extent.origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    // MARK: - P1-5 color tools integration (v11)

    func testColorToolsRequireV11RoundTripsAndLegacyPayloadsKeepOldPath() throws {
        var settings = AdjustmentSettings()
        var curves = ColorCurveSettings()
        curves.luminance = [CurveControlPoint(x: 0, y: 0),
                            CurveControlPoint(x: 0.5, y: 0.6),
                            CurveControlPoint(x: 1, y: 1)]
        var hsl = HSLSettings()
        hsl.cyan.saturation = 0.4
        var grading = ColorGradingSettings()
        grading.highlights = ColorGradingWheel(hueDegrees: 40, saturation: 0.3, luminance: 0.1)
        settings.colorTools = ColorToolsSettings(curves: curves, hsl: hsl, grading: grading)
        settings.lensEffects = LensEffectsSettings(vignetteAmount: 0.4,
                                                   chromaticAberrationRed: 0.2)

        var recipe = Recipe(adjustments: settings)
        recipe.version = 10
        XCTAssertThrowsError(try recipe.validateVersion(),
                             "v10 配方不得静默接受非中性调色工具/镜头效果")
        recipe.version = 11
        XCTAssertNoThrow(try recipe.validateVersion())

        let encoded = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(Recipe.self, from: encoded)
        XCTAssertEqual(decoded, recipe, "v11 配方必须编码往返")
        XCTAssertEqual(decoded.adjustments.colorTools, settings.colorTools)
        XCTAssertEqual(decoded.adjustments.lensEffects, settings.lensEffects)

        // Lens effects alone also require v11.
        var lensOnly = AdjustmentSettings()
        lensOnly.lensEffects = LensEffectsSettings(vignetteAmount: 0.3)
        var lensRecipe = Recipe(adjustments: lensOnly)
        lensRecipe.version = 10
        XCTAssertThrowsError(try lensRecipe.validateVersion())

        // Old recipes carry no colorTools/lensEffects keys: decode as nil and keep
        // the pre-v11 pixel path (identical to a neutral current recipe).
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var adjustments = try XCTUnwrap(object["adjustments"] as? [String: Any])
        adjustments.removeValue(forKey: "colorTools")
        adjustments.removeValue(forKey: "lensEffects")
        object["adjustments"] = adjustments
        object["version"] = 9
        let legacy = try JSONDecoder().decode(Recipe.self,
                                              from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.adjustments.colorTools)
        XCTAssertNil(legacy.adjustments.lensEffects)
        XCTAssertNoThrow(try legacy.validateVersion())
        let extent = CGRect(x: 0, y: 0, width: 4, height: 4)
        let source = solid([0.32, 0.20, 0.14], extent: extent)
        let legacyPixel = try pixel(try PhotoEngine().process(source, settings: legacy.adjustments, lut: nil).image,
                                    x: 1, y: 1)
        let neutralPixel = try pixel(try PhotoEngine().process(source, settings: AdjustmentSettings(), lut: nil).image,
                                     x: 1, y: 1)
        for channel in 0..<4 {
            XCTAssertEqual(legacyPixel[channel], neutralPixel[channel], accuracy: 1e-9)
        }
    }

    func testNeutralColorToolsAreExactNoOpsAndRecordNothing() throws {
        var settings = AdjustmentSettings()
        settings.colorTools = ColorToolsSettings()
        settings.lensEffects = LensEffectsSettings()
        let extent = CGRect(x: 0, y: 0, width: 8, height: 8)
        let source = solid([0.3, 0.2, 0.15], extent: extent)
        let baseline = try PhotoEngine().process(source, settings: AdjustmentSettings(), lut: nil)
        let output = try PhotoEngine().process(source, settings: settings, lut: nil)
        let baselinePixel = try pixel(baseline.image, x: 3, y: 3)
        let outputPixel = try pixel(output.image, x: 3, y: 3)
        for channel in 0..<4 {
            XCTAssertEqual(outputPixel[channel], baselinePixel[channel], accuracy: 1e-9,
                           "中性调色工具必须保持预 v11 像素路径")
        }
        XCTAssertNil(output.report.colorTools, "中性调色工具不应写入报告")
    }

    func testColorToolsValidationRejectsInvalidSettings() throws {
        var badCurves = AdjustmentSettings()
        badCurves.colorTools = ColorToolsSettings(curves: ColorCurveSettings(
            red: [CurveControlPoint(x: 0.5, y: 0), CurveControlPoint(x: 0.5, y: 1)]))
        XCTAssertThrowsError(try PhotoEngine.validate(badCurves))
        var badHSL = AdjustmentSettings()
        var hsl = HSLSettings()
        hsl.red.saturation = 2
        badHSL.colorTools = ColorToolsSettings(hsl: hsl)
        XCTAssertThrowsError(try PhotoEngine.validate(badHSL))
        var badLens = AdjustmentSettings()
        badLens.lensEffects = LensEffectsSettings(vignetteAmount: .nan)
        XCTAssertThrowsError(try PhotoEngine.validate(badLens))
    }

    func testColorToolsReportRecordsAppliedStages() throws {
        var curves = ColorCurveSettings()
        curves.luminance = [CurveControlPoint(x: 0, y: 0),
                            CurveControlPoint(x: 0.5, y: 0.6),
                            CurveControlPoint(x: 1, y: 1)]
        var settings = AdjustmentSettings()
        settings.colorTools = ColorToolsSettings(curves: curves)
        settings.lensEffects = LensEffectsSettings(vignetteAmount: 0.4,
                                                   chromaticAberrationRed: -0.2)
        let extent = CGRect(x: 0, y: 0, width: 8, height: 8)
        let output = try PhotoEngine().process(solid([0.3, 0.2, 0.15], extent: extent),
                                               settings: settings, lut: nil)
        let report = try XCTUnwrap(output.report.colorTools)
        XCTAssertEqual(report.stages, ["curves", "lensEffects"])
        XCTAssertEqual(report.vignetteAmount, 0.4, accuracy: 1e-9)
        XCTAssertEqual(report.chromaticAberration, 0.2, accuracy: 1e-9)
    }

    func testRequiredRecipeVersionReturnsElevenForColorToolsAndLensEffects() throws {
        var curves = ColorCurveSettings()
        curves.red = [CurveControlPoint(x: 0, y: 0.1), CurveControlPoint(x: 1, y: 1)]
        var settings = AdjustmentSettings()
        settings.colorTools = ColorToolsSettings(curves: curves)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: settings, automatic: nil), 11)
        settings.colorTools = nil
        settings.lensEffects = LensEffectsSettings(vignetteAmount: 0.2)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: settings, automatic: nil), 11)

        let automatic = AutomaticBatchRecipe(styleID: "balanced", baseline: settings,
                                             referenceSettings: AdjustmentSettings())
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: AdjustmentSettings(),
                                                         automatic: automatic), 11)
        var recipe = Recipe(adjustments: AdjustmentSettings(), automatic: automatic)
        recipe.version = 10
        XCTAssertThrowsError(try recipe.validateVersion())
        recipe.version = 11
        XCTAssertNoThrow(try recipe.validateVersion())

        var neutral = AdjustmentSettings()
        neutral.colorTools = ColorToolsSettings()
        neutral.lensEffects = LensEffectsSettings()
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: neutral, automatic: nil), 9)
        var portrait = AdjustmentSettings()
        portrait.portrait = PortraitRefinementSettings(blemishStrength: 0.2)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: portrait, automatic: nil), 10)
    }

    func testColorToolsPipelineOrderToneThenToolsThenLensThenLUT() throws {
        let width = 24, height = 20
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let source = gradient(width: width, height: height) { x, y in
            let t = Float(x) / 23
            let u = Float(y) / 19
            return (0.12 + 0.45 * t, 0.18 + 0.30 * u, 0.30 - 0.15 * t)
        }
        var curves = ColorCurveSettings()
        curves.luminance = [CurveControlPoint(x: 0, y: 0),
                            CurveControlPoint(x: 0.5, y: 0.6),
                            CurveControlPoint(x: 1, y: 1)]
        var hsl = HSLSettings()
        hsl.red.saturation = 0.4
        var grading = ColorGradingSettings()
        grading.global = ColorGradingWheel(hueDegrees: 200, saturation: 0.2, luminance: 0.05)
        let colorTools = ColorToolsSettings(curves: curves, hsl: hsl, grading: grading)
        let lensEffects = LensEffectsSettings(vignetteAmount: 0.35, chromaticAberrationBlue: 0.4)
        let lut = try colorCube(size: 2) { r, g, b in
            (min(1, 0.05 + 0.90 * r), min(1, 0.02 + 0.85 * g), min(1, 0.03 + 0.95 * b))
        }

        var combined = AdjustmentSettings()
        combined.exposureEV = 0.4
        combined.colorTools = colorTools
        combined.lensEffects = lensEffects
        combined.lutIntensity = 1
        let combinedOutput = try PhotoEngine().process(source, settings: combined, lut: lut).image

        // Sequential reference: basic tone → color tools → lens effects → LUT.
        var toneOnly = AdjustmentSettings()
        toneOnly.exposureEV = 0.4
        var staged = try PhotoEngine().process(source, settings: toneOnly, lut: nil).image
        staged = try ColorToolsEngine.apply(colorTools, to: staged)
        staged = try LensEffectsEngine.apply(lensEffects, to: staged)
        var lutOnly = AdjustmentSettings()
        lutOnly.lutIntensity = 1
        let expected = try PhotoEngine().process(staged, settings: lutOnly, lut: lut).image

        for (x, y) in sampleGrid(width: width, height: height) {
            let actual = try pixel(combinedOutput, x: x, y: y)
            let wanted = try pixel(expected, x: x, y: y)
            for channel in 0..<4 {
                XCTAssertEqual(actual[channel], wanted[channel], accuracy: 0.003,
                               "管线顺序应为 基础影调→曲线/HSL/分级→镜头效果→LUT（\(x),\(y) ch\(channel)）")
            }
        }
    }

    // MARK: - P1-6 liquify recipe gate

    func testLiquifyRequiresV11RoundTripsAndNeutralStaysLegacy() throws {
        var settings = AdjustmentSettings()
        settings.liquify = FaceReshapeSettings(preset: .round,
                                               parameters: FaceReshapeParameters(slimFace: 0.4))
        var recipe = Recipe(adjustments: settings)
        recipe.version = 10
        XCTAssertThrowsError(try recipe.validateVersion()) { error in
            XCTAssertTrue(error.localizedDescription.contains("液化"),
                          "a v10 recipe with non-neutral liquify must be rejected explicitly")
        }
        recipe.version = 11
        XCTAssertNoThrow(try recipe.validateVersion())
        let encoded = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(Recipe.self, from: encoded)
        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(decoded.version, 11)
        XCTAssertEqual(decoded.adjustments.liquify?.preset, .round)
        XCTAssertEqual(try XCTUnwrap(decoded.adjustments.liquify?.parameters.slimFace),
                       0.4, accuracy: 1e-9)
        // Preset offsets stay additive on top of the explicit slider.
        XCTAssertEqual(try XCTUnwrap(decoded.adjustments.liquify?.effectiveParameters.slimFace),
                       0.95, accuracy: 1e-9)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: settings, automatic: nil), 11)

        // Explicitly neutral liquify keeps the legacy v9 payload and pixel path.
        var neutral = AdjustmentSettings()
        neutral.liquify = FaceReshapeSettings()
        XCTAssertNoThrow(try Recipe(adjustments: neutral).validateVersion())
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: neutral, automatic: nil), 9)

        // Manual strokes alone also require v11.
        var strokeOnly = AdjustmentSettings()
        strokeOnly.liquify = FaceReshapeSettings(strokes: [
            WarpStroke(mode: .push,
                       points: [MaskPoint(x: 0.4, y: 0.5), MaskPoint(x: 0.6, y: 0.5)],
                       radius: 0.08, strength: 0.6)
        ])
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: strokeOnly, automatic: nil), 11)

        // The automatic recipe's baseline/reference branches are covered too.
        var baselineSettings = AdjustmentSettings()
        baselineSettings.liquify = FaceReshapeSettings(preset: .youthful)
        let automatic = AutomaticBatchRecipe(styleID: "balanced",
                                             baseline: baselineSettings,
                                             referenceSettings: AdjustmentSettings())
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: AdjustmentSettings(),
                                                         automatic: automatic), 11)
        var automaticRecipe = Recipe(adjustments: AdjustmentSettings(), automatic: automatic)
        automaticRecipe.version = 10
        XCTAssertThrowsError(try automaticRecipe.validateVersion())
        automaticRecipe.version = 11
        XCTAssertNoThrow(try automaticRecipe.validateVersion())

        // v1–v10 payloads without the field decode as nil and keep the old path.
        var legacy = Recipe(adjustments: AdjustmentSettings())
        legacy.version = 10
        let legacyDecoded = try JSONDecoder().decode(Recipe.self,
            from: try JSONEncoder().encode(legacy))
        XCTAssertNil(legacyDecoded.adjustments.liquify)
        XCTAssertNoThrow(try legacyDecoded.validateVersion())
    }

    func testLiquifyValidationRejectsMalformedStrokesAndOutOfRangeStrength() {
        var settings = AdjustmentSettings()
        settings.liquify = FaceReshapeSettings(strokes: [
            WarpStroke(mode: .push, points: [MaskPoint(x: Double.nan, y: 0.5)],
                       radius: 0.08, strength: 0.6)
        ])
        XCTAssertThrowsError(try PhotoEngine.validate(settings))
        settings.liquify = FaceReshapeSettings(strength: 1.5)
        XCTAssertThrowsError(try PhotoEngine.validate(settings))
    }

    // MARK: - P1-7 watermark export recipe gate

    func testWatermarkExportRequiresV11AndRoundTrips() throws {
        var watermark = WatermarkSettings(text: "光屿 WATERMARK", anchor: .bottomRight,
                                          opacity: 0.85, scale: 1.5, rotationDegrees: 12)
        watermark.shadow = WatermarkShadow()
        watermark.stroke = WatermarkStroke()
        var export = ExportSettings()
        export.format = .png
        export.watermark = watermark
        export.watermarkDualVersion = true

        // v10 recipes must reject a non-neutral watermark instead of silently
        // dropping it; v11 accepts and round-trips the full settings.
        var v10 = Recipe(export: export)
        v10.version = 10
        XCTAssertThrowsError(try v10.validateVersion(), "v10 配方不得接受非中性水印") { error in
            XCTAssertTrue(error.localizedDescription.contains("水印"), error.localizedDescription)
        }
        var v11 = v10
        v11.version = 11
        XCTAssertNoThrow(try v11.validateVersion())
        let decoded = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(v11))
        XCTAssertEqual(decoded, v11)
        XCTAssertEqual(try XCTUnwrap(decoded.export.watermark), watermark)
        XCTAssertEqual(decoded.export.watermarkDualVersion, true)
        XCTAssertEqual(decoded.version, 11)

        // A neutral watermark is the documented no-op, so v10 stays loadable.
        var neutralExport = export
        neutralExport.watermark?.opacity = 0
        var neutralRecipe = Recipe(export: neutralExport)
        neutralRecipe.version = 10
        XCTAssertNoThrow(try neutralRecipe.validateVersion())

        // Save-side predicate: any stored payload upgrades to v11 (data only
        // exists there); the gate only rejects an active watermark.
        XCTAssertFalse(ExportSettings().storesWatermarkData)
        XCTAssertFalse(ExportSettings().requiresVersion11Recipe)
        XCTAssertTrue(neutralExport.storesWatermarkData)
        XCTAssertFalse(neutralExport.requiresVersion11Recipe)
        XCTAssertTrue(export.storesWatermarkData)
        XCTAssertTrue(export.requiresVersion11Recipe)
        XCTAssertTrue(export.exportsDualWatermarkVersion)
        XCTAssertFalse(ExportSettings().exportsDualWatermarkVersion)
        var staleDual = export
        staleDual.watermark = nil
        staleDual.watermarkDualVersion = true
        XCTAssertFalse(staleDual.exportsDualWatermarkVersion, "无水印时双版本开关应被忽略")
        XCTAssertFalse(staleDual.requiresVersion11Recipe)

        // v1–v10 recipes without the new keys decode as nil and keep the old path.
        let legacyJSON = """
        {"format":"jpeg","colorSpace":"sRGB","jpegQuality":0.94,"recursive":false,
         "suffix":"_graded","stripMetadata":true}
        """
        let legacy = try JSONDecoder().decode(ExportSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.watermark)
        XCTAssertNil(legacy.watermarkDualVersion)
        XCTAssertFalse(legacy.requiresVersion11Recipe)
        XCTAssertFalse(legacy.storesWatermarkData)
        var legacyRecipe = Recipe(export: legacy)
        legacyRecipe.version = 10
        XCTAssertNoThrow(try legacyRecipe.validateVersion(), "旧配方导出设置缺新字段时必须保持可加载")
        XCTAssertEqual(legacy.format, .jpeg)
        XCTAssertEqual(legacy.suffix, "_graded")
        XCTAssertTrue(legacy.stripMetadata)
    }

    // MARK: - P1-B certificate photo / background replacement (v12)

    func testCertificatePhotoRequiresV12RoundTripsAndNeutralStaysLegacy() throws {
        var settings = AdjustmentSettings()
        // Keep the stored floats binary-exact so the Codable roundtrip equality
        // check is not defeated by decimal literals (e.g. -0.035).
        settings.certificatePhoto = CertificatePhotoSettings(
            enabled: true, backgroundSource: .preset, backgroundPreset: .blue,
            shadow: BackgroundReplacementSettings(shadowEnabled: true,
                                                  shadowOpacity: 0.5,
                                                  shadowBlur: 0.25,
                                                  shadowOffsetX: 0,
                                                  shadowOffsetY: 0,
                                                  edgeDecontamination: 0.5),
            size: .oneInch)
        var recipe = Recipe(adjustments: settings)
        recipe.version = 11
        XCTAssertThrowsError(try recipe.validateVersion()) { error in
            XCTAssertTrue(error.localizedDescription.contains("证件照"),
                          "a v11 recipe with an active certificate stage must be rejected")
        }
        recipe.version = 12
        XCTAssertNoThrow(try recipe.validateVersion())
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: settings, automatic: nil), 12)
        let decoded = try JSONDecoder().decode(Recipe.self, from: try JSONEncoder().encode(recipe))
        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(decoded.adjustments.certificatePhoto?.size, .oneInch)
        XCTAssertEqual(decoded.adjustments.certificatePhoto?.backgroundPreset, .blue)
        XCTAssertEqual(decoded.adjustments.certificatePhoto?.enabled, true)

        // Enabled=false is explicitly neutral: old payloads/pixel path stay valid.
        var neutral = AdjustmentSettings()
        neutral.certificatePhoto = CertificatePhotoSettings(enabled: false, size: .oneInch)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: neutral, automatic: nil), 9)
        XCTAssertNoThrow(try Recipe(adjustments: neutral).validateVersion())
        var legacyV11 = Recipe(adjustments: neutral)
        legacyV11.version = 11
        XCTAssertNoThrow(try legacyV11.validateVersion())
        XCTAssertTrue(neutral.certificatePhoto?.isNeutral == true)

        // Absent field decodes as nil and keeps the legacy path.
        let absent = try JSONDecoder().decode(Recipe.self,
            from: try JSONEncoder().encode(Recipe(adjustments: AdjustmentSettings())))
        XCTAssertNil(absent.adjustments.certificatePhoto)
        XCTAssertNoThrow(try absent.validateVersion())

        // Automatic recipe baseline/reference branches are gated too.
        let automatic = AutomaticBatchRecipe(styleID: "balanced",
                                             baseline: settings,
                                             referenceSettings: AdjustmentSettings())
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: AdjustmentSettings(),
                                                         automatic: automatic), 12)
        var automaticRecipe = Recipe(adjustments: AdjustmentSettings(), automatic: automatic)
        automaticRecipe.version = 11
        XCTAssertThrowsError(try automaticRecipe.validateVersion())
        automaticRecipe.version = 12
        XCTAssertNoThrow(try automaticRecipe.validateVersion())

        // Version range and malformed settings fail loudly.
        var future = Recipe(adjustments: AdjustmentSettings())
        future.version = 25
        XCTAssertThrowsError(try future.validateVersion())
        var invalid = CertificatePhotoSettings(enabled: true)
        invalid.shadow.shadowOpacity = 2
        XCTAssertThrowsError(try PhotoEngine.validate({
            var value = AdjustmentSettings(); value.certificatePhoto = invalid; return value
        }()))
        var imageSource = CertificatePhotoSettings(enabled: true, backgroundSource: .image,
                                                   backgroundImagePath: "   ")
        XCTAssertThrowsError(try imageSource.validated())
    }

    // MARK: - P1-B manual repair / clone brush (v12)

    func testRepairBrushRequiresV12RoundTripsAndNeutralStaysLegacy() throws {
        var settings = AdjustmentSettings()
        var heal = RepairStroke(mode: .heal,
                                points: [MaskPoint(x: 0.25, y: 0.5), MaskPoint(x: 0.75, y: 0.5)],
                                radius: 0.08, feather: 0.4, strength: 0.9)
        heal.id = UUID(uuidString: "00000000-0000-0000-0000-00000000B501")!
        var clone = RepairStroke(mode: .clone,
                                 points: [MaskPoint(x: 0.5, y: 0.4), MaskPoint(x: 0.5, y: 0.6)],
                                 radius: 0.05, feather: 0.2, strength: 1)
        clone.id = UUID(uuidString: "00000000-0000-0000-0000-00000000B502")!
        clone.cloneOffset = MaskPoint(x: 0.25, y: -0.1)
        settings.repairBrush = RepairBrushSettings(strokes: [heal, clone])

        var recipe = Recipe(adjustments: settings)
        recipe.version = 11
        XCTAssertThrowsError(try recipe.validateVersion()) { error in
            XCTAssertTrue(error.localizedDescription.contains("修复"),
                          "a v11 recipe with stored repair strokes must be rejected")
        }
        recipe.version = 12
        XCTAssertNoThrow(try recipe.validateVersion())
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: settings, automatic: nil), 12)
        let decoded = try JSONDecoder().decode(Recipe.self, from: try JSONEncoder().encode(recipe))
        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(decoded.adjustments.repairBrush?.strokes.count, 2)
        XCTAssertEqual(decoded.adjustments.repairBrush?.strokes.first?.mode, .heal)
        XCTAssertEqual(decoded.adjustments.repairBrush?.strokes.last?.cloneOffset,
                       MaskPoint(x: 0.25, y: -0.1),
                       "clone source offset must survive the recipe roundtrip")

        // Empty stroke list is explicitly neutral: legacy version + pixel path.
        var neutral = AdjustmentSettings()
        neutral.repairBrush = RepairBrushSettings()
        XCTAssertTrue(neutral.repairBrush?.isNeutral == true)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: neutral, automatic: nil), 9)
        var neutralV11 = Recipe(adjustments: neutral)
        neutralV11.version = 11
        XCTAssertNoThrow(try neutralV11.validateVersion())
        XCTAssertNoThrow(try Recipe(adjustments: neutral).validateVersion())

        // Absent field decodes as nil and keeps the legacy path.
        let absent = try JSONDecoder().decode(Recipe.self,
            from: try JSONEncoder().encode(Recipe(adjustments: AdjustmentSettings())))
        XCTAssertNil(absent.adjustments.repairBrush)
        XCTAssertNoThrow(try absent.validateVersion())

        // Automatic baseline/reference branches are gated too.
        let automatic = AutomaticBatchRecipe(styleID: "balanced", baseline: settings,
                                             referenceSettings: AdjustmentSettings())
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: AdjustmentSettings(),
                                                         automatic: automatic), 12)
        var automaticRecipe = Recipe(adjustments: AdjustmentSettings(), automatic: automatic)
        automaticRecipe.version = 11
        XCTAssertThrowsError(try automaticRecipe.validateVersion())
        automaticRecipe.version = 12
        XCTAssertNoThrow(try automaticRecipe.validateVersion())

        // Malformed settings fail loudly through the shared engine validation.
        var tooManyStrokes = RepairBrushSettings(strokes: [heal])
        tooManyStrokes.strokes = (0..<(RepairBrushEngine.maximumStrokeCount + 1)).map { _ in heal }
        XCTAssertThrowsError(try PhotoEngine.validate({
            var value = AdjustmentSettings()
            value.repairBrush = tooManyStrokes
            return value
        }()))
        XCTAssertThrowsError(try RepairStroke(mode: .heal, points: []).validate())
        XCTAssertThrowsError(try RepairStroke(mode: .heal,
                                              points: [MaskPoint(x: 0.5, y: 0.5)],
                                              radius: 0.9).validate())
        XCTAssertThrowsError(try RepairStroke(mode: .clone,
                                              points: [MaskPoint(x: 0.5, y: 0.5)],
                                              cloneOffset: MaskPoint(x: -2, y: 0)).validate())
    }

    // MARK: - B6 customer delivery page (v12)

    func testDeliveryPageRequiresV12RoundTripsAndLegacyStaysNeutral() throws {
        var delivery = DeliverySettings()
        delivery.title = "客户交付 · 离线预览"
        delivery.columnCount = 2
        delivery.thumbnailMaxDimension = 320
        delivery.previewMaxDimension = 640
        delivery.includeContactSheet = true
        delivery.contactSheetColumns = 2
        delivery.paper = .letter
        delivery.pageMarginFraction = 0.05
        delivery.watermarkedPreviews = true

        var export = ExportSettings()
        export.format = .png
        export.deliveryPage = delivery
        var recipe = Recipe(export: export)
        recipe.version = 11
        XCTAssertThrowsError(try recipe.validateVersion(), "v11 配方不得接受客户交付页") { error in
            XCTAssertTrue(error.localizedDescription.contains("客户交付页"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("12"), error.localizedDescription)
        }
        recipe.version = 12
        XCTAssertNoThrow(try recipe.validateVersion())
        let decoded = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(try XCTUnwrap(decoded.export.deliveryPage), delivery)
        XCTAssertEqual(decoded.export.deliveryPage?.paper, .letter)
        XCTAssertEqual(decoded.export.deliveryPage?.watermarkedPreviews, true)

        // Predicates: any stored delivery payload needs v12, both for the gate and
        // for the save path's auto-upgrade (mirrors the v10/v11 rules).
        XCTAssertFalse(ExportSettings().requiresVersion12Recipe)
        XCTAssertFalse(ExportSettings().storesDeliveryPageData)
        XCTAssertNil(ExportSettings().deliveryPage)
        XCTAssertTrue(export.requiresVersion12Recipe)
        XCTAssertTrue(export.storesDeliveryPageData)
        var defaultExport = ExportSettings()
        defaultExport.watermark = WatermarkSettings(text: "WM")
        XCTAssertFalse(defaultExport.requiresVersion12Recipe, "水印只要求 v11，不应误触 v12")

        // Legacy payloads stay loadable: missing key decodes as nil, v11 recipes
        // without the field keep the old export path.
        let legacyJSON = """
        {"format":"jpeg","colorSpace":"sRGB","jpegQuality":0.94,"recursive":false,
         "suffix":"_graded","stripMetadata":true}
        """
        let legacy = try JSONDecoder().decode(ExportSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.deliveryPage)
        XCTAssertFalse(legacy.requiresVersion12Recipe)
        var legacyRecipe = Recipe(export: legacy)
        legacyRecipe.version = 11
        XCTAssertNoThrow(try legacyRecipe.validateVersion(), "缺 deliveryPage 的旧导出设置必须保持 v11 可加载")
        XCTAssertEqual(legacy.suffix, "_graded")
    }

    // MARK: - P1-C make-up (v13)

    func testMakeupRequiresV13RoundTripsAndNeutralStaysLegacy() throws {
        let makeup = MakeupSettings(lipColor: SRGBColor(red: 0.5, green: 0.25, blue: 0.75),
                                    lipIntensity: 0.5,
                                    browColor: SRGBColor(red: 0.25, green: 0.5, blue: 0.25),
                                    browDensity: 0.5,
                                    cheekColor: SRGBColor(red: 0.75, green: 0.5, blue: 0.5),
                                    cheekIntensity: 0.5,
                                    cheekRadius: 0.5,
                                    eyeshadowColor: SRGBColor(red: 0.5, green: 0.75, blue: 0.5),
                                    eyeshadowIntensity: 0.5)
        var settings = AdjustmentSettings()
        settings.makeup = makeup
        var recipe = Recipe(adjustments: settings)
        recipe.version = 12
        XCTAssertThrowsError(try recipe.validateVersion()) { error in
            XCTAssertTrue(error.localizedDescription.contains("妆容"),
                          "a v12 recipe with active make-up must be rejected")
        }
        recipe.version = 13
        XCTAssertNoThrow(try recipe.validateVersion())
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: settings, automatic: nil), 13)
        let decoded = try JSONDecoder().decode(Recipe.self, from: try JSONEncoder().encode(recipe))
        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(decoded.adjustments.makeup?.lipIntensity, 0.5)
        XCTAssertEqual(decoded.adjustments.makeup?.lipColor,
                       SRGBColor(red: 0.5, green: 0.25, blue: 0.75))

        // Explicitly neutral (all strengths zero) make-up keeps the legacy path.
        var neutral = AdjustmentSettings()
        neutral.makeup = MakeupSettings()
        XCTAssertTrue(neutral.makeup?.isNeutral == true)
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: neutral, automatic: nil), 9)
        var neutralV12 = Recipe(adjustments: neutral)
        neutralV12.version = 12
        XCTAssertNoThrow(try neutralV12.validateVersion())
        XCTAssertNil(try JSONDecoder().decode(Recipe.self,
            from: JSONEncoder().encode(Recipe(adjustments: AdjustmentSettings())))
            .adjustments.makeup)

        // Automatic recipe baseline/reference branches are gated too.
        let automatic = AutomaticBatchRecipe(styleID: "balanced",
                                             baseline: settings,
                                             referenceSettings: AdjustmentSettings())
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: AdjustmentSettings(),
                                                         automatic: automatic), 13)
        var automaticRecipe = Recipe(adjustments: AdjustmentSettings(), automatic: automatic)
        automaticRecipe.version = 12
        XCTAssertThrowsError(try automaticRecipe.validateVersion())
        automaticRecipe.version = 13
        XCTAssertNoThrow(try automaticRecipe.validateVersion())

        // Version range and malformed make-up fail loudly.
        var future = Recipe(adjustments: AdjustmentSettings())
        future.version = 25
        XCTAssertThrowsError(try future.validateVersion())
        XCTAssertThrowsError(try PhotoEngine.validate({
            var value = AdjustmentSettings()
            value.makeup = MakeupSettings(lipIntensity: 2)
            return value
        }()))
        XCTAssertThrowsError(try PhotoEngine.validate({
            var value = AdjustmentSettings()
            value.makeup = MakeupSettings(lipIntensity: 0.2, cheekRadius: 0.1)
            return value
        }()))
        // A neutral field with malformed nested values must not be rejected at the
        // pipeline entry (the v13 gate treats it as inert, same rule as S3).
        var neutralInvalid = AdjustmentSettings()
        var neutralMakeup = MakeupSettings()
        neutralMakeup.lipIntensity = 0
        neutralMakeup.cheekRadius = 0.1
        neutralInvalid.makeup = neutralMakeup
        XCTAssertNoThrow(try PhotoEngine.validate(neutralInvalid))
    }

    func testMakeupCollapseKeepsColourOnlyEditsWhileNeutral() throws {
        // F1 (C5 round 2): only an all-default setting collapses to nil; a neutral
        // setting with user-chosen colour/radius survives so the ColorPicker does
        // not snap back before an intensity is raised.
        XCTAssertNil(MakeupSettings.collapsed(MakeupSettings()))
        var colourOnly = MakeupSettings()
        colourOnly.lipColor = SRGBColor(red: 0.9, green: 0.1, blue: 0.2)
        let keptColour = try XCTUnwrap(MakeupSettings.collapsed(colourOnly))
        XCTAssertTrue(keptColour.isNeutral)
        XCTAssertEqual(keptColour.lipColor, SRGBColor(red: 0.9, green: 0.1, blue: 0.2))
        var radiusOnly = MakeupSettings()
        radiusOnly.cheekRadius = 0.8
        let keptRadius = try XCTUnwrap(MakeupSettings.collapsed(radiusOnly))
        XCTAssertEqual(keptRadius.cheekRadius, 0.8)
        XCTAssertTrue(keptRadius.isNeutral)

        var settings = AdjustmentSettings()
        settings.makeup = keptColour
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: settings,
                                                         automatic: nil), 9)
        var recipe = Recipe(adjustments: settings)
        recipe.version = 12
        XCTAssertNoThrow(try recipe.validateVersion())
        XCTAssertNoThrow(try PhotoEngine.validate(settings))

        var active = keptColour
        active.lipIntensity = 0.5
        let keptActive = try XCTUnwrap(MakeupSettings.collapsed(active))
        XCTAssertFalse(keptActive.isNeutral)
        var activeSettings = AdjustmentSettings()
        activeSettings.makeup = keptActive
        XCTAssertEqual(PhotoEngine.requiredRecipeVersion(adjustments: activeSettings,
                                                         automatic: nil), 13)
    }
}

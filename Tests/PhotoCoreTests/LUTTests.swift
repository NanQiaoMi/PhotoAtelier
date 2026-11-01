import XCTest
@testable import PhotoCore

final class LUTTests: XCTestCase {
    func testCubeUsesRedFastestAndTrilinearInterpolation() throws {
        let cube = try LUTCube.parse(cubeText(size: 2) { red, green, blue in
            (green, blue, red)
        })

        let sample = cube.sample(SIMD3<Float>(0.25, 0.5, 0.75))
        XCTAssertEqual(sample.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(sample.y, 0.75, accuracy: 0.0001)
        XCTAssertEqual(sample.z, 0.25, accuracy: 0.0001)
    }

    func testNonDefaultDomainClampsEdgesAndMapsCenter() throws {
        let text = cubeText(size: 2, domainMin: SIMD3<Float>(repeating: 0.25),
                            domainMax: SIMD3<Float>(repeating: 0.75)) { red, green, blue in
            (red, green, blue)
        }
        let cube = try LUTCube.parse(text)

        let midpoint = cube.sample(SIMD3<Float>(repeating: 0.5))
        XCTAssertEqual(midpoint.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(midpoint.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(midpoint.z, 0.5, accuracy: 0.0001)
        let below = cube.sample(SIMD3<Float>(repeating: 0))
        XCTAssertEqual(below.x, 0, accuracy: 0.0001)
        let above = cube.sample(SIMD3<Float>(repeating: 1))
        XCTAssertEqual(above.z, 1, accuracy: 0.0001)
    }

    func testRejectsWrongRowCountAndNonFiniteValues() {
        XCTAssertThrowsError(try LUTCube.parse("LUT_3D_SIZE 2\n0 0 0\n"))
        let invalid = "LUT_3D_SIZE 2\n" + Array(repeating: "0 0 0", count: 7).joined(separator: "\n") + "\nNaN 1 1\n"
        XCTAssertThrowsError(try LUTCube.parse(invalid))
    }

    func testRejectsInvalidDomainAndUnsupportedOneDimensionalLUT() {
        let invalidDomain = """
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.5 0 0
        DOMAIN_MAX 0.5 1 1
        """ + "\n" + Array(repeating: "0 0 0", count: 8).joined(separator: "\n")
        XCTAssertThrowsError(try LUTCube.parse(invalidDomain))
        XCTAssertThrowsError(try LUTCube.parse("LUT_1D_SIZE 2\n0 0 0\n0 0 0\n"))
    }

    func testRejectsNonstandardAlphaColumnsAndHugeFiniteOutput() {
        let alphaRows = "LUT_3D_SIZE 2\n" + Array(repeating: "0 0 0 1", count: 8).joined(separator: "\n")
        XCTAssertThrowsError(try LUTCube.parse(alphaRows))
        let oversizedRows = "LUT_3D_SIZE 2\n" + Array(repeating: "16.1 0 0", count: 8).joined(separator: "\n")
        XCTAssertThrowsError(try LUTCube.parse(oversizedRows))
    }

    func testParsesTitleAndCommentsAndFillsAlpha() throws {
        let text = """
        TITLE "Soft # daylight" # comment after title
        LUT_3D_SIZE 2
        """ + "\n" + Array(repeating: "0 0 0 # node", count: 8).joined(separator: "\n")
        let cube = try LUTCube.parse(text)
        XCTAssertEqual(cube.title, "Soft # daylight")
        XCTAssertEqual(cube.rgba.count, 8 * 4)
        XCTAssertTrue(stride(from: 3, to: cube.rgba.count, by: 4).allSatisfy { cube.rgba[$0] == 1 })
    }

    func testBuiltInPresetsAreSmallValidCubes() {
        let presets = LUTCube.builtIns
        XCTAssertGreaterThanOrEqual(presets.count, 4)
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
        for preset in presets {
            XCTAssertEqual(preset.cube.size, 17)
            XCTAssertEqual(preset.cube.rgba.count, 17 * 17 * 17 * 4)
            XCTAssertTrue(preset.cube.rgba.allSatisfy(\.isFinite))
        }
    }

    private func cubeText(size: Int,
                          domainMin: SIMD3<Float> = .zero,
                          domainMax: SIMD3<Float> = SIMD3<Float>(repeating: 1),
                          value: (Float, Float, Float) -> (Float, Float, Float)) -> String {
        let denominator = Float(size - 1)
        var rows: [String] = []
        for blueIndex in 0..<size {
            for greenIndex in 0..<size {
                for redIndex in 0..<size {
                    let red = Float(redIndex) / denominator
                    let green = Float(greenIndex) / denominator
                    let blue = Float(blueIndex) / denominator
                    let output = value(red, green, blue)
                    rows.append("\(output.0) \(output.1) \(output.2)")
                }
            }
        }
        return """
        TITLE "test LUT"
        LUT_3D_SIZE \(size)
        DOMAIN_MIN \(domainMin.x) \(domainMin.y) \(domainMin.z)
        DOMAIN_MAX \(domainMax.x) \(domainMax.y) \(domainMax.z)
        \(rows.joined(separator: "\n"))
        """
    }
}

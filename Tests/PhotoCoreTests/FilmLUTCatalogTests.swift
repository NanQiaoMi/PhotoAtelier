import XCTest
@testable import PhotoCore

final class FilmLUTCatalogTests: XCTestCase {
    private let expectedIDs = [
        "film-fuji-classic-chrome",
        "film-fuji-astia",
        "film-fuji-classic-neg",
        "film-fuji-eterna",
        "film-fuji-acros"
    ]

    func testCatalogHasStableIDsAndCompleteSourceMetadata() throws {
        let presets = FilmLUTCatalog.presets
        XCTAssertEqual(presets.map(\.id), expectedIDs)
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)

        for preset in presets {
            XCTAssertEqual(FilmLUTCatalog.preset(id: preset.id)?.id, preset.id)
            XCTAssertEqual(preset.cube.size, 33, preset.id)
            XCTAssertEqual(preset.cube.rgba.count, 33 * 33 * 33 * 4, preset.id)
            XCTAssertEqual(preset.cube.domainMin, SIMD3<Float>(repeating: 0), preset.id)
            XCTAssertEqual(preset.cube.domainMax, SIMD3<Float>(repeating: 1), preset.id)
            XCTAssertTrue(preset.cube.rgba.allSatisfy(\.isFinite), preset.id)
            XCTAssertTrue(preset.cube.rgba.allSatisfy { (0...1).contains($0) }, preset.id)

            let source = try XCTUnwrap(preset.provenance, preset.id)
            XCTAssertEqual(source.author, "Sadziu and contributors", preset.id)
            XCTAssertEqual(source.license, "MIT License", preset.id)
            XCTAssertTrue(source.sourceURL.contains("a6691ea0e880ddd5fd19d7ca2d48a502fb0e7e07"), preset.id)
            XCTAssertTrue(source.inputContract.contains("gamma-encoded sRGB"), preset.id)
            XCTAssertTrue(source.inputContract.contains("[0,1]"), preset.id)
            XCTAssertTrue(source.notice.contains("not an official Fujifilm LUT"), preset.id)
            XCTAssertTrue(preset.detail.contains("非官方"), preset.id)
        }

        XCTAssertNil(FilmLUTCatalog.preset(id: "film-fuji-missing"))
    }

    func testToneCurveLandmarksMatchPinnedRecipeParameters() throws {
        let expected: [String: (quarter: Double, threeQuarter: Double)] = [
            "film-fuji-classic-chrome": (0.215, 0.758),
            "film-fuji-astia": (0.262, 0.76),
            "film-fuji-classic-neg": (0.205, 0.77),
            "film-fuji-eterna": (0.2972, 0.715),
            "film-fuji-acros": (0.22, 0.77)
        ]

        for preset in FilmLUTCatalog.presets {
            let landmarks = try XCTUnwrap(expected[preset.id], preset.id)
            let quarter = luminance(preset.cube.sample(SIMD3<Float>(repeating: 0.25)))
            let threeQuarter = luminance(preset.cube.sample(SIMD3<Float>(repeating: 0.75)))
            XCTAssertEqual(quarter, landmarks.quarter, accuracy: 0.000003, preset.id)
            XCTAssertEqual(threeQuarter, landmarks.threeQuarter, accuracy: 0.000003, preset.id)
        }
    }

    func testGrayRampIsMonotoneAndAcrosRemovesChroma() throws {
        for preset in FilmLUTCatalog.presets {
            var previousLuminance = -Double.infinity
            for step in 0...64 {
                let value = Float(step) / 64
                let output = preset.cube.sample(SIMD3<Float>(repeating: value))
                let currentLuminance = luminance(output)
                XCTAssertGreaterThanOrEqual(currentLuminance + 0.00001, previousLuminance,
                                            "\(preset.id) gray ramp at \(step)")
                previousLuminance = currentLuminance
            }
        }

        let acros = try XCTUnwrap(FilmLUTCatalog.preset(id: "film-fuji-acros"))
        let coloredInput = SIMD3<Float>(0.12, 0.45, 0.88)
        let monochromeOutput = acros.cube.sample(coloredInput)
        XCTAssertEqual(monochromeOutput.x, monochromeOutput.y, accuracy: 0.000001)
        XCTAssertEqual(monochromeOutput.y, monochromeOutput.z, accuracy: 0.000001)
    }

    func testExistingBuiltinCatalogAndLegacyInitializerRemainUnattributed() throws {
        let originalBuiltins = LUTCube.builtIns
        XCTAssertEqual(originalBuiltins.count, 13)
        XCTAssertTrue(originalBuiltins.allSatisfy { $0.provenance == nil })

        let neutral = try XCTUnwrap(originalBuiltins.first { $0.id == "neutral" })
        let legacyPreset = LUTPreset(id: "legacy-call", name: "Legacy", detail: "Existing initializer",
                                     cube: neutral.cube)
        XCTAssertNil(legacyPreset.provenance)
        XCTAssertEqual(legacyPreset.group, .natural)
        XCTAssertEqual(legacyPreset.recommendedIntensity, 0.35, accuracy: 0.000001)
        XCTAssertTrue(legacyPreset.tags.isEmpty)
    }

    private func luminance(_ rgb: SIMD3<Float>) -> Double {
        0.2126 * Double(rgb.x) + 0.7152 * Double(rgb.y) + 0.0722 * Double(rgb.z)
    }
}

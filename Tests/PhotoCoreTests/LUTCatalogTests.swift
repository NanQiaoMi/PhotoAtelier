import XCTest
@testable import PhotoCore

final class LUTCatalogTests: XCTestCase {
    private let legacyIDs = ["neutral", "soft-film", "warm-light", "cool-clear", "golden-hour"]

    private let creativeMetadata: [(id: String, group: LUTPresetGroup, intensity: Double)] = [
        ("fresh-portrait", .portrait, 0.34),
        ("creamy-soft", .portrait, 0.32),
        ("teal-orange-film", .cinematic, 0.30),
        ("faded-vintage", .cinematic, 0.30),
        ("quiet-forest", .landscape, 0.34),
        ("coastal-light", .landscape, 0.32),
        ("silver-salt", .monochrome, 0.38),
        ("soft-monochrome", .monochrome, 0.36)
    ]

    func testLegacyPresetOrderAndFullTableHashesRemainUnchanged() throws {
        let presets = LUTCube.builtIns
        XCTAssertEqual(Array(presets.prefix(legacyIDs.count).map(\.id)), legacyIDs)

        // FNV-1a 64 over the big-endian bytes of every Float.bitPattern. These
        // values were recorded from the five pre-catalog tables before edits.
        let expectedHashes: [String: UInt64] = [
            "neutral": 0x92e557fb2586b4bd,
            "soft-film": 0x454bb408ac748114,
            "warm-light": 0x4da3deda35c357f1,
            "cool-clear": 0xe1def0d23a5a0b07,
            "golden-hour": 0xd56e644bb94ddf73
        ]

        for preset in presets.prefix(legacyIDs.count) {
            XCTAssertEqual(tableHash(preset.cube.rgba), expectedHashes[preset.id], preset.id)
        }

        let expectedMidGray: [String: SIMD3<Float>] = [
            "neutral": SIMD3<Float>(0.5, 0.5, 0.5),
            "soft-film": SIMD3<Float>(0.4975, 0.4975, 0.4975),
            "warm-light": SIMD3<Float>(0.5425, 0.5051, 0.4694),
            "cool-clear": SIMD3<Float>(0.47804, 0.5, 0.5305),
            "golden-hour": SIMD3<Float>(0.5252, 0.504536, 0.479336)
        ]
        for preset in presets.prefix(legacyIDs.count) {
            let actual = preset.cube.sample(SIMD3<Float>(repeating: 0.5))
            let expected = try XCTUnwrap(expectedMidGray[preset.id])
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.000001, preset.id)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.000001, preset.id)
            XCTAssertEqual(actual.z, expected.z, accuracy: 0.000001, preset.id)
        }
    }

    func testCatalogContainsEightOriginalCreativeLooksWithCompleteMetadata() throws {
        let presets = LUTCube.builtIns
        XCTAssertEqual(presets.count, 13)
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)

        for (index, metadata) in creativeMetadata.enumerated() {
            let preset = try XCTUnwrap(presets.dropFirst(legacyIDs.count).dropFirst(index).first)
            XCTAssertEqual(preset.id, metadata.id)
            XCTAssertEqual(preset.group, metadata.group)
            XCTAssertEqual(preset.recommendedIntensity, metadata.intensity, accuracy: 0.000001)
            XCTAssertTrue((0...1).contains(preset.recommendedIntensity), preset.id)
            XCTAssertFalse(preset.tags.isEmpty, preset.id)
            XCTAssertFalse(preset.detail.isEmpty, preset.id)
        }

        XCTAssertEqual(LUTPresetGroup.allCases.map(\.title), ["自然", "人像", "电影", "风光", "黑白"])
        for group in LUTPresetGroup.allCases {
            XCTAssertEqual(try JSONDecoder().decode(LUTPresetGroup.self,
                                                     from: JSONEncoder().encode(group)), group)
        }

        // The original four-argument initializer remains source compatible.
        let first = try XCTUnwrap(presets.first)
        let legacyInit = LUTPreset(id: "compat", name: "兼容", detail: "兼容旧调用", cube: first.cube)
        XCTAssertEqual(legacyInit.group, .natural)
        XCTAssertEqual(legacyInit.recommendedIntensity, 0.35, accuracy: 0.000001)
        XCTAssertTrue(legacyInit.tags.isEmpty)

        let bounded = LUTPreset(id: "bounded", name: "范围", detail: "强度范围", cube: first.cube,
                                recommendedIntensity: 5)
        XCTAssertEqual(bounded.recommendedIntensity, 1)
        let nonFinite = LUTPreset(id: "fallback", name: "回退", detail: "有限默认值", cube: first.cube,
                                  recommendedIntensity: .infinity)
        XCTAssertEqual(nonFinite.recommendedIntensity, 0.35, accuracy: 0.000001)
    }

    func testCreativeTablesAreFiniteBoundedOpaqueAndDistinct() throws {
        let presets = Array(LUTCube.builtIns.dropFirst(legacyIDs.count))
        let colors: [SIMD3<Float>] = [
            SIMD3<Float>(0.12, 0.12, 0.12),
            SIMD3<Float>(0.24, 0.48, 0.20),
            SIMD3<Float>(0.78, 0.48, 0.34),
            SIMD3<Float>(0.22, 0.48, 0.82),
            SIMD3<Float>(0.88, 0.90, 0.92),
            SIMD3<Float>(repeating: 0.5)
        ]

        for preset in presets {
            XCTAssertEqual(preset.cube.size, 17, preset.id)
            XCTAssertEqual(preset.cube.rgba.count, 17 * 17 * 17 * 4, preset.id)
            XCTAssertTrue(preset.cube.rgba.allSatisfy(\.isFinite), preset.id)
            for (offset, value) in preset.cube.rgba.enumerated() {
                if offset.isMultiple(of: 4) {
                    XCTAssertTrue((0...1).contains(value), "\(preset.id) channel at \(offset)")
                } else if offset % 4 == 3 {
                    XCTAssertEqual(value, 1, "\(preset.id) alpha at \(offset)")
                } else {
                    XCTAssertTrue((0...1).contains(value), "\(preset.id) channel at \(offset)")
                }
            }
        }

        for leftIndex in presets.indices {
            for rightIndex in presets.indices where rightIndex > leftIndex {
                var greatestDifference: Float = 0
                for color in colors {
                    let left = presets[leftIndex].cube.sample(color)
                    let right = presets[rightIndex].cube.sample(color)
                    greatestDifference = max(greatestDifference,
                                             max(abs(left.x - right.x),
                                                 max(abs(left.y - right.y), abs(left.z - right.z))))
                }
                XCTAssertGreaterThan(greatestDifference, 0.01,
                                     "\(presets[leftIndex].id) and \(presets[rightIndex].id) should react differently")
            }
        }
    }

    func testCreativeLooksPreserveNeutralityAndMonotoneGrayTones() throws {
        let presets = Array(LUTCube.builtIns.dropFirst(legacyIDs.count))
        let nearNeutralLevels: [Float] = [0, 0.04, 0.2, 0.5, 0.8, 0.96, 1]

        for preset in presets {
            var previousLuminance: Float = -1
            for step in 0...32 {
                let level = Float(step) / 32
                let result = preset.cube.sample(SIMD3<Float>(repeating: level))
                let outputLuminance = 0.2126 * result.x + 0.7152 * result.y + 0.0722 * result.z
                XCTAssertGreaterThanOrEqual(outputLuminance + 0.00001, previousLuminance, preset.id)
                previousLuminance = outputLuminance

                let channelSpread = max(result.x, max(result.y, result.z))
                    - min(result.x, min(result.y, result.z))
                XCTAssertLessThanOrEqual(channelSpread, 0.035, "gray-axis tint in \(preset.id) at \(level)")
            }

            for level in nearNeutralLevels {
                let input = SIMD3<Float>(level, min(level + 0.01, 1), max(level - 0.01, 0))
                let result = preset.cube.sample(input)
                let channelSpread = max(result.x, max(result.y, result.z))
                    - min(result.x, min(result.y, result.z))
                XCTAssertLessThanOrEqual(channelSpread, 0.055,
                                         "near-neutral tint in \(preset.id) at \(level)")
            }
        }
    }

    func testMonochromeLooksRemoveAllChroma() throws {
        let monochromeIDs: Set<String> = ["silver-salt", "soft-monochrome"]
        let presets = LUTCube.builtIns.filter { monochromeIDs.contains($0.id) }
        XCTAssertEqual(presets.count, monochromeIDs.count)

        for preset in presets {
            for offset in stride(from: 0, to: preset.cube.rgba.count, by: 4) {
                XCTAssertEqual(preset.cube.rgba[offset], preset.cube.rgba[offset + 1], "\(preset.id) node \(offset / 4)")
                XCTAssertEqual(preset.cube.rgba[offset + 1], preset.cube.rgba[offset + 2], "\(preset.id) node \(offset / 4)")
            }
            let sample = preset.cube.sample(SIMD3<Float>(0.82, 0.23, 0.61))
            XCTAssertEqual(sample.x, sample.y, accuracy: 0.000001, preset.id)
            XCTAssertEqual(sample.y, sample.z, accuracy: 0.000001, preset.id)
        }
    }

    private func tableHash(_ values: [Float]) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for value in values {
            let bits = value.bitPattern
            for shift in [24, 16, 8, 0] {
                hash ^= UInt64((bits >> shift) & 0xff)
                hash &*= 1_099_511_628_211
            }
        }
        return hash
    }
}

import CoreImage
import XCTest
@testable import PhotoCore

final class AutomaticTests: XCTestCase {
    func testSameChosenDirectionAdaptsToEachPhotoAndCarriesManualRefinement() throws {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func source(_ value: CGFloat) -> CIImage {
            CIImage(color: CIColor(red: value, green: value, blue: value, alpha: 1, colorSpace: space)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        var baseline = AdjustmentSettings()
        baseline.lutIntensity = 0.4; baseline.rotationDegrees = 2
        let dark = try PhotoAnalyzer().analyze(image: source(0.06), properties: [:], baseline: baseline)
        let bright = try PhotoAnalyzer().analyze(image: source(0.55), properties: [:], baseline: baseline)
        let reference = try XCTUnwrap(dark.proposals.first { $0.id == "bright" })
        let automatic = AutomaticBatchRecipe(styleID: "bright", baseline: baseline, referenceSettings: reference.settings)
        var refined = reference.settings
        refined.exposureEV += 0.2; refined.lutIntensity = 0.75
        refined.masks = [LocalMask(exposureEV: 0.4)]
        let darkSettings = try automatic.resolve(analysis: dark, current: refined)
        let brightSettings = try automatic.resolve(analysis: bright, current: refined)
        XCTAssertGreaterThan(darkSettings.exposureEV, brightSettings.exposureEV)
        XCTAssertEqual(darkSettings.exposureEV - reference.settings.exposureEV, 0.2, accuracy: 0.001)
        XCTAssertEqual(brightSettings.lutIntensity, 0.75)
        XCTAssertEqual(brightSettings.masks, refined.masks)
        XCTAssertEqual(brightSettings.rotationDegrees, 2)
        XCTAssertFalse(brightSettings.autoExposure, "Suggested EV must not be followed by a second automatic exposure adjustment")
        let roundtrip = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(
            Recipe(adjustments: refined, automatic: automatic)))
        XCTAssertEqual(roundtrip.automatic, automatic)
    }

    func testOldManualRecipeWithoutAutomaticFieldRemainsReadable() throws {
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(Recipe())) as? [String: Any])
        object.removeValue(forKey: "automatic")
        let loaded = try JSONDecoder().decode(Recipe.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(loaded.automatic)
    }
}

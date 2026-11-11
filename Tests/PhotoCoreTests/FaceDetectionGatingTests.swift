import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

/// Regression tests for the shared face-detection trigger list
/// (`PhotoEngine.requiresFaceDetection`) and for the pipeline-level dispatch
/// that feeds `detectedFaces` to every face-aware stage.
///
/// Background (P3-E1 bug): the trigger list previously omitted the P2-R
/// hair-color, P2-S facial-hair and all seven P2 reshape stages. A photo that
/// enabled only one of those nine stages skipped the shared Vision detection,
/// the stage read empty landmarks and reported 「未检测到可用人脸」 while the
/// user saw no effect. Tests that call the engines directly never exercise
/// this dispatch, and the `preparedMakeupFaces` injection bypasses the gate
/// itself, so coverage is split: the trigger matrix is asserted against the
/// static predicate (no Vision needed), and the pipeline tests below prove
/// each stage actually consumes landmarks handed to `PhotoEngine.process`.
/// The end-to-end fix was additionally verified on a real portrait with the
/// engine's own detection (Scripts/probe_p2_applied.swift).
final class FaceDetectionGatingTests: XCTestCase {

    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false
    ])

    // MARK: - Fixtures

    /// Synthetic portrait: skin ellipse + darker lips/brows/eyes, matching the
    /// landmark polygons returned by `makeFace`. Size 256×256 so engine-side
    /// downscaling keeps geometry usable.
    private func makeFaceImage() -> CIImage {
        let width = 256, height = 256
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let y = 1.0 - (Double(row) + 0.5) / Double(height)
            for col in 0..<width {
                let x = (Double(col) + 0.5) / Double(width)
                let offset = (row * width + col) * 4
                var color: (Float, Float, Float) = (0.15, 0.15, 0.16)
                let d = pow((x - 0.5) / 0.16, 2) + pow((y - 0.5) / 0.22, 2)
                if d <= 1.0 {
                    color = (0.70, 0.55, 0.45)
                    let lip = pow((x - 0.5) / 0.05, 2) + pow((y - 0.40) / 0.025, 2)
                    if lip <= 1.0 { color = (0.45, 0.10, 0.12) }
                    let brow = pow((x - 0.42) / 0.06, 2) + pow((y - 0.60) / 0.015, 2)
                    if brow <= 1.0 { color = (0.10, 0.07, 0.05) }
                }
                pixels[offset] = color.0
                pixels[offset + 1] = color.1
                pixels[offset + 2] = color.2
                pixels[offset + 3] = 1.0
            }
        }
        let data = pixels.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        return CIImage(bitmapData: data,
                       bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                       size: CGSize(width: width, height: height),
                       format: .RGBAf, colorSpace: linearColorSpace)
    }

    /// Landmarks aligned with `makeFaceImage` (normalized, bottom-left origin).
    private func makeFace() -> FaceLandmarkSet {
        func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, points: Int = 18) -> [CGPoint] {
            (0..<points).map { i in
                let angle = Double(i) / Double(points) * 2 * .pi
                return CGPoint(x: cx + CGFloat(cos(angle) * rx), y: cy + CGFloat(sin(angle) * ry))
            }
        }
        let brow = [CGPoint(x: 0.36, y: 0.615), CGPoint(x: 0.48, y: 0.615),
                    CGPoint(x: 0.48, y: 0.585), CGPoint(x: 0.36, y: 0.585)]
        return FaceLandmarkSet(
            boundingBox: CGRect(x: 0.30, y: 0.24, width: 0.40, height: 0.52),
            confidence: 0.95,
            faceContour: ellipse(0.5, 0.5, 0.18, 0.24),
            leftEye: ellipse(0.40, 0.56, 0.05, 0.03),
            rightEye: ellipse(0.60, 0.56, 0.05, 0.03),
            leftEyebrow: brow,
            rightEyebrow: brow.map { CGPoint(x: 1 - $0.x, y: $0.y) },
            nose: ellipse(0.5, 0.48, 0.04, 0.05),
            outerLips: ellipse(0.5, 0.40, 0.07, 0.04),
            innerLips: ellipse(0.5, 0.40, 0.035, 0.015, points: 10),
            leftPupil: CGPoint(x: 0.40, y: 0.56),
            rightPupil: CGPoint(x: 0.60, y: 0.56)
        )
    }

    // MARK: - Trigger-list unit tests (no Vision involved)

    func testReshapeAndHairStagesAloneTriggerFaceDetection() {
        // The nine stages that were missing from the pre-P3-E1 trigger list.
        var settings = AdjustmentSettings()
        settings.hairColor = HairColorSettings(enabled: true, grayHairRemoval: 0.4)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        settings.facialHair = FacialHairSettings(enabled: true, lipFuzzRemoval: 0.4)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        settings.expression = ExpressionSettings(enabled: true, smileDegree: 0.3)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        settings.eyeShape = EyeShapeSettings(enabled: true, eyeSymmetry: 0.35)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        settings.noseReshape = NoseReshapeSettings(enabled: true, nose3DContour: 0.35)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        settings.jawChinReshape = JawChinReshapeSettings(enabled: true, jawlineTighten: 0.35)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        settings.facialContour = FacialContourSettings(enabled: true, templePlump: 0.3)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        settings.eyebrowReshape = EyebrowReshapeSettings(enabled: true, browSymmetry: 0.35)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        settings.facialBoneContour = FacialBoneContourSettings(enabled: true, facialFolding: 0.4)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
    }

    func testPreExistingTriggersStillHold() throws {
        var settings = AdjustmentSettings()
        settings.portrait = PortraitRefinementSettings(hairGloss: 0.4)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        settings.makeup = MakeupSettings(lipIntensity: 0.4)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        settings.facialZonal = FacialZonalRefinementSettings(enabled: true, darkCircles: 0.4)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        settings.eyeTeeth = EyeTeethRefinementSettings(enabled: true, irisClarity: 0.4)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        settings.eyelidAegyoSal = EyelidAegyoSalSettings(enabled: true,
                                                         eyelidStyle: .fan, eyelidStrength: 0.4)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        settings.multiPerson = MultiPersonSettings(enabled: true, unifySkinTone: 0.6)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        settings.referenceColor = ReferenceColorSettings(
            profile: try ReferenceColorMatcher.profile(reference: makeFaceImage()),
            strength: 0.5, skinOnly: true)
        XCTAssertTrue(PhotoEngine.requiresFaceDetection(settings))
    }

    func testNonFaceSettingsDoNotTriggerFaceDetection() throws {
        var settings = AdjustmentSettings()
        settings.autoExposure = false
        settings.lutIntensity = 0.8
        settings.gamutCompression = 0.5
        XCTAssertFalse(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        // Disabled toggles must never trigger, even with non-zero parameters.
        settings.expression = ExpressionSettings(enabled: false, smileDegree: 0.9)
        settings.eyeShape = EyeShapeSettings(enabled: false, eyeSymmetry: 0.9)
        settings.facialBoneContour = FacialBoneContourSettings(enabled: false, facialFolding: 0.9)
        settings.hairColor = HairColorSettings(enabled: false, grayHairRemoval: 0.9)
        settings.facialHair = FacialHairSettings(enabled: false, lipFuzzRemoval: 0.9)
        XCTAssertFalse(PhotoEngine.requiresFaceDetection(settings))
        settings = AdjustmentSettings()
        // Global (non skin-limited) reference color needs no face masks.
        settings.referenceColor = ReferenceColorSettings(
            profile: try ReferenceColorMatcher.profile(reference: makeFaceImage()),
            strength: 0.5, skinOnly: false)
        XCTAssertFalse(PhotoEngine.requiresFaceDetection(settings))
    }

    // MARK: - Pipeline-level dispatch tests (PhotoEngine.process)

    /// Each of the nine fixed stages must run end-to-end through
    /// `PhotoEngine.process` when it is the only active stage. Before the fix
    /// these all reported `applied=false` with 「未检测到可用人脸」.
    func testSoloFaceStagesDetectFacesThroughProcess() throws {
        let image = makeFaceImage()
        let face = makeFace()
        let engine = PhotoEngine()

        func makeSettings(_ apply: (inout AdjustmentSettings) -> Void) -> AdjustmentSettings {
            var settings = AdjustmentSettings()
            apply(&settings)
            return settings
        }

        let cases: [(String, AdjustmentSettings,
                     (ProcessingReport) -> (Bool, String?))] = [
            ("hairColor", makeSettings { $0.hairColor = HairColorSettings(enabled: true, grayHairRemoval: 0.45) },
             { ($0.hairColor?.applied ?? false, $0.hairColor?.note) }),
            ("facialHair", makeSettings { $0.facialHair = FacialHairSettings(enabled: true, lipFuzzRemoval: 0.45) },
             { ($0.facialHair?.applied ?? false, $0.facialHair?.note) }),
            ("expression", makeSettings { $0.expression = ExpressionSettings(enabled: true, smileDegree: 0.35) },
             { ($0.expression?.applied ?? false, $0.expression?.note) }),
            ("eyeShape", makeSettings { $0.eyeShape = EyeShapeSettings(enabled: true, eyeSymmetry: 0.35) },
             { ($0.eyeShape?.applied ?? false, $0.eyeShape?.note) }),
            ("noseReshape", makeSettings { $0.noseReshape = NoseReshapeSettings(enabled: true, nose3DContour: 0.35) },
             { ($0.noseReshape?.applied ?? false, $0.noseReshape?.note) }),
            ("jawChinReshape", makeSettings { $0.jawChinReshape = JawChinReshapeSettings(enabled: true, jawlineTighten: 0.35) },
             { ($0.jawChinReshape?.applied ?? false, $0.jawChinReshape?.note) }),
            ("facialContour", makeSettings { $0.facialContour = FacialContourSettings(enabled: true, templePlump: 0.30) },
             { ($0.facialContour?.applied ?? false, $0.facialContour?.note) }),
            ("eyebrowReshape", makeSettings { $0.eyebrowReshape = EyebrowReshapeSettings(enabled: true, browSymmetry: 0.35) },
             { ($0.eyebrowReshape?.applied ?? false, $0.eyebrowReshape?.note) }),
            ("facialBoneContour", makeSettings { $0.facialBoneContour = FacialBoneContourSettings(enabled: true, facialFolding: 0.40) },
             { ($0.facialBoneContour?.applied ?? false, $0.facialBoneContour?.note) })
        ]

        for (name, settings, reportCheck) in cases {
            let processed = try engine.process(image, settings: settings, lut: nil,
                                               preparedMakeupFaces: [face])
            let (applied, note) = reportCheck(processed.report)
            XCTAssertTrue(applied, "\(name) 应在唯一启用人脸模块时成功应用（note=\(note ?? "-")）")
            XCTAssertEqual(processed.report.warnings.filter { $0.contains("未检测到可用人脸") }.count, 0,
                           "\(name) 不应再报「未检测到可用人脸」")
        }
    }

    /// No usable landmarks → the stage must still degrade explicitly (the
    /// dispatch fix must not turn a genuinely face-less photo into a silent
    /// no-report pass).
    func testSoloFaceStageWithoutFacesStillSkipsExplicitly() throws {
        var settings = AdjustmentSettings()
        settings.facialBoneContour = FacialBoneContourSettings(enabled: true, facialFolding: 0.40)
        let engine = PhotoEngine()
        // No preparedMakeupFaces and a face-less gradient image: the stage must
        // run its own detection now (trigger list includes it), find nothing
        // and record the explicit skip.
        let gradient = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.32,
                                              colorSpace: linearColorSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        let processed = try engine.process(gradient, settings: settings, lut: nil)
        let report = processed.report.facialBoneContour
        XCTAssertEqual(report?.applied, false)
        XCTAssertNotNil(report?.note)
        XCTAssertEqual(processed.report.warnings.filter { $0.contains("未检测到可用人脸") }.count, 1)
    }
}

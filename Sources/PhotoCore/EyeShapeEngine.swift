import CoreGraphics
import CoreImage
import Foundation

// MARK: - Eye Shape Engine

/// P2-U: Smart eye shape reshaping, canthoplasty & mid-face proportion balancing engine.
///
/// Features:
/// 1. 开内眼角 (Inner Canthoplasty / `innerCanthoplasty`):
///    Subtly opens and elongates the inner canthus towards the nasal bridge, smoothing epicanthic folds.
/// 2. 开外眼角与眼尾下至 (Outer Canthoplasty & Lower Lid Drop / `outerCanthoplasty`):
///    Expands the outer canthus laterally and slightly downward to enlarge the ocular contour.
/// 3. 眼型圆润/猫眼微调 (Eye Roundness & Contour Curvature / `eyeRoundness`):
///    Modulates upper and lower eyelid curvature (-0.5 almond/cat eye to +0.5 round doe eye).
/// 4. 眼位倾斜与走势校准 (Eye Tilt Calibration / `eyeTilt`):
///    Calibrates outer canthus slant (-0.5 puppy droop to +0.5 uplifted cat/phoenix eye).
/// 5. 眼距微调 (Interpupillary Distance / `interpupillaryDistance`):
///    Narrows or widens the space between the eyes to optimize golden facial ratio.
/// 6. 眼位垂直微调与中庭缩短 (Eye Vertical Position & Mid-Face Balance / `eyeVerticalPosition`):
///    Moves eyes downward to shorten mid-face length for a youthful look, or upward for mature proportions.
/// 7. 双眼大小与水平对称性校准 (Eye Symmetry Harmonization / `eyeSymmetry`):
///    Detects size and vertical height asymmetry between eyes, leveling heights and balancing sizes.
///
/// 100% offline, zero external model weights, Core Image & Metal accelerated via WarpField deformation.
public enum EyeShapeEngine {

    // MARK: - Public API

    /// Applies eye shape and proportion adjustments to all detected faces.
    public static func apply(
        to image: CIImage,
        faces: [FaceLandmarkSet],
        settings: EyeShapeSettings
    ) -> (image: CIImage, report: EyeShapeReport) {
        guard settings.enabled, !settings.isNeutral, !faces.isEmpty else {
            return (image, EyeShapeReport(applied: false, faceCount: 0, note: nil))
        }

        let startTime = Date().timeIntervalSinceReferenceDate
        let usableFaces = faces.filter { $0.hasUsableGeometry && (!$0.leftEye.isEmpty || !$0.rightEye.isEmpty) }
        guard !usableFaces.isEmpty else {
            return (image, EyeShapeReport(applied: false, faceCount: 0, note: "未检测到可用眼部关键点。"))
        }

        var working = image
        let field = generateWarpField(faces: usableFaces, settings: settings, imageSize: image.extent.size)
        if !field.isIdentity {
            do {
                working = try field.apply(to: working)
            } catch {
                // If warp fails, keep working as is
            }
        }

        let elapsedMs = (Date().timeIntervalSinceReferenceDate - startTime) * 1000.0
        let report = EyeShapeReport(
            applied: true,
            faceCount: usableFaces.count,
            averageCanthoplasty: (settings.innerCanthoplasty + settings.outerCanthoplasty) * 0.5,
            averageRoundness: settings.eyeRoundness,
            averageTilt: settings.eyeTilt,
            processingTimeMs: elapsedMs,
            note: nil
        )

        return (working, report)
    }

    /// Applies eye shape adjustments for a single person in multi-person demographic processing.
    public static func applyPerPerson(
        to image: CIImage,
        face: FaceLandmarkSet,
        faceIndex: Int,
        settings: EyeShapeSettings,
        perFaceMask: FaceSemanticMaskSet? = nil
    ) -> (image: CIImage, report: EyeShapeReport) {
        guard settings.enabled, !settings.isNeutral,
              face.hasUsableGeometry && (!face.leftEye.isEmpty || !face.rightEye.isEmpty) else {
            return (image, EyeShapeReport(applied: false, faceCount: 0, note: "人脸 \(faceIndex + 1) 未启用或参数中性。"))
        }

        let startTime = Date().timeIntervalSinceReferenceDate
        var working = image

        let field = generateWarpField(faces: [face], settings: settings, imageSize: image.extent.size)
        if !field.isIdentity {
            do {
                let warped = try field.apply(to: working)
                // If per-face skin mask is available, blend warped result within face region to isolate effect
                if let maskSet = perFaceMask, let faceMask = maskSet.skin ?? maskSet.lips {
                    working = warped.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: working,
                        kCIInputMaskImageKey: faceMask
                    ])
                } else {
                    working = warped
                }
            } catch {
                // Fallback to unwarped image
            }
        }

        let elapsedMs = (Date().timeIntervalSinceReferenceDate - startTime) * 1000.0
        let report = EyeShapeReport(
            applied: true,
            faceCount: 1,
            averageCanthoplasty: (settings.innerCanthoplasty + settings.outerCanthoplasty) * 0.5,
            averageRoundness: settings.eyeRoundness,
            averageTilt: settings.eyeTilt,
            processingTimeMs: elapsedMs,
            note: "完成人脸 \(faceIndex + 1) 眼型微雕。"
        )

        return (working, report)
    }

    // MARK: - Warp Field Generation

    /// Builds a WarpField displacement map tailored to the eye geometry of each face.
    public static func generateWarpField(
        faces: [FaceLandmarkSet],
        settings: EyeShapeSettings,
        imageSize: CGSize,
        resolution: Int = WarpField.defaultResolution
    ) -> WarpField {
        var field = WarpField(columns: resolution, rows: resolution)
        guard imageSize.width > 1, imageSize.height > 1, !settings.isNeutral else {
            return field
        }

        for face in faces {
            guard let geometry = EyeShapeGeometry(face: face, imageSize: imageSize) else { continue }
            addEyeShapeControls(to: &field, geometry: geometry, settings: settings, imageSize: imageSize)

            // Background protection around the eyes
            var protectedRect = geometry.boundingBox
            protectedRect = protectedRect.insetBy(dx: -geometry.boundingBox.width * 0.20,
                                                  dy: -geometry.boundingBox.height * 0.25)
            let feather = max(Double(geometry.boundingBox.width), Double(geometry.boundingBox.height)) * 0.25
            field.attenuateOutside(rect: protectedRect, feather: feather)
        }

        field.smooth(passes: 2)
        field.clampMagnitude()
        return field
    }

    // MARK: - Eye Shape Controls

    private static func addEyeShapeControls(
        to field: inout WarpField,
        geometry: EyeShapeGeometry,
        settings: EyeShapeSettings,
        imageSize: CGSize
    ) {
        // Process Left Eye (image-left)
        if let left = geometry.leftEyeMetrics {
            addSingleEyeControls(to: &field, eye: left, isLeftEye: true, settings: settings)
        }

        // Process Right Eye (image-right)
        if let right = geometry.rightEyeMetrics {
            addSingleEyeControls(to: &field, eye: right, isLeftEye: false, settings: settings)
        }

        // Interpupillary Distance (眼距微调)
        if abs(settings.interpupillaryDistance) > 0.0001,
           let left = geometry.leftEyeMetrics, let right = geometry.rightEyeMetrics {
            let avgWidth = (left.width + right.width) * 0.5
            let avgHeight = (left.height + right.height) * 0.5
            let shiftX = avgWidth * 0.32 * settings.interpupillaryDistance

            // Left eye: +distance moves -X (leftward, away from nose), -distance moves +X (rightward, toward nose)
            field.addGaussian(
                center: left.center,
                radiusX: avgWidth * 0.85,
                radiusY: avgHeight * 1.30,
                displacement: SIMD2<Double>(-shiftX, 0),
                falloff: .gaussian
            )

            // Right eye: +distance moves +X (rightward, away from nose), -distance moves -X (leftward, toward nose)
            field.addGaussian(
                center: right.center,
                radiusX: avgWidth * 0.85,
                radiusY: avgHeight * 1.30,
                displacement: SIMD2<Double>(shiftX, 0),
                falloff: .gaussian
            )
        }

        // Eye Vertical Position & Mid-Face Balance (眼位垂直微调与中庭比例缩短)
        if abs(settings.eyeVerticalPosition) > 0.0001 {
            let avgHeight = ((geometry.leftEyeMetrics?.height ?? 0.03) + (geometry.rightEyeMetrics?.height ?? 0.03)) * 0.5
            let avgWidth = ((geometry.leftEyeMetrics?.width ?? 0.06) + (geometry.rightEyeMetrics?.width ?? 0.06)) * 0.5
            // Positive moves eyes downward (-Y in bottom-left origin) to shorten mid-face length
            let shiftY = -avgHeight * 0.35 * settings.eyeVerticalPosition

            if let left = geometry.leftEyeMetrics {
                field.addGaussian(
                    center: left.center,
                    radiusX: avgWidth * 0.90,
                    radiusY: avgHeight * 1.35,
                    displacement: SIMD2<Double>(0, shiftY),
                    falloff: .gaussian
                )
            }
            if let right = geometry.rightEyeMetrics {
                field.addGaussian(
                    center: right.center,
                    radiusX: avgWidth * 0.90,
                    radiusY: avgHeight * 1.35,
                    displacement: SIMD2<Double>(0, shiftY),
                    falloff: .gaussian
                )
            }
        }

        // Eye Symmetry Harmonization (双眼大小与水平对称性校准)
        if settings.eyeSymmetry > 0.0001,
           let left = geometry.leftEyeMetrics, let right = geometry.rightEyeMetrics {
            // 1. Level eye vertical tilt/height difference
            let dy = (right.center.y - left.center.y) * 0.5 * settings.eyeSymmetry
            let avgHeight = (left.height + right.height) * 0.5
            let avgWidth = (left.width + right.width) * 0.5

            if abs(dy) > 0.00005 {
                field.addGaussian(
                    center: left.center,
                    radiusX: avgWidth * 0.80,
                    radiusY: avgHeight * 1.20,
                    displacement: SIMD2<Double>(0, dy),
                    falloff: .gaussian
                )
                field.addGaussian(
                    center: right.center,
                    radiusX: avgWidth * 0.80,
                    radiusY: avgHeight * 1.20,
                    displacement: SIMD2<Double>(0, -dy),
                    falloff: .gaussian
                )
            }

            // 2. Harmonize eye size disparity
            let leftSize = left.width * left.height
            let rightSize = right.width * right.height
            if leftSize > 0.0001, rightSize > 0.0001 {
                let sizeRatio = leftSize / rightSize
                if abs(sizeRatio - 1.0) > 0.02 {
                    let balanceFactor = min(0.35, abs(sizeRatio - 1.0) * 0.40) * settings.eyeSymmetry
                    if sizeRatio < 1.0 {
                        // Left eye is smaller: subtle expansion
                        expandEye(to: &field, eye: left, factor: balanceFactor)
                    } else {
                        // Right eye is smaller: subtle expansion
                        expandEye(to: &field, eye: right, factor: balanceFactor)
                    }
                }
            }
        }
    }

    private static func addSingleEyeControls(
        to field: inout WarpField,
        eye: SingleEyeMetrics,
        isLeftEye: Bool,
        settings: EyeShapeSettings
    ) {
        let ew = eye.width
        let eh = eye.height

        // 1. 开内眼角 (Inner Canthoplasty)
        if settings.innerCanthoplasty > 0.0001 {
            let canthoX = ew * 0.20 * settings.innerCanthoplasty
            // For left eye (image-left), inner canthus is at max X, so moving medially is +X
            // For right eye (image-right), inner canthus is at min X, so moving medially is -X
            let dx = isLeftEye ? canthoX : -canthoX
            let dy = -eh * 0.04 * settings.innerCanthoplasty // slight downward natural slant

            field.addGaussian(
                center: eye.innerCanthus,
                radiusX: ew * 0.42,
                radiusY: eh * 0.70,
                displacement: SIMD2<Double>(dx, dy),
                falloff: .gaussian
            )
        }

        // 2. 开外眼角与眼尾下至 (Outer Canthoplasty & Lower Lid Drop)
        if settings.outerCanthoplasty > 0.0001 {
            let canthoX = ew * 0.22 * settings.outerCanthoplasty
            // For left eye, outer canthus is at min X, moving laterally is -X
            // For right eye, outer canthus is at max X, moving laterally is +X
            let dx = isLeftEye ? -canthoX : canthoX
            // Droop outer canthus downward (-Y) for natural enlarged lower lid extension
            let dy = -eh * 0.18 * settings.outerCanthoplasty

            field.addGaussian(
                center: eye.outerCanthus,
                radiusX: ew * 0.45,
                radiusY: eh * 0.75,
                displacement: SIMD2<Double>(dx, dy),
                falloff: .gaussian
            )
        }

        // 3. 眼型圆润/猫眼微调 (Eye Roundness)
        if abs(settings.eyeRoundness) > 0.0001 {
            // Positive increases vertical aperture (round eye), negative flattens (almond/cat eye)
            let dy = eh * 0.38 * settings.eyeRoundness

            // Upper lid moves +Y
            field.addGaussian(
                center: eye.upperLidApex,
                radiusX: ew * 0.45,
                radiusY: eh * 0.55,
                displacement: SIMD2<Double>(0, dy),
                falloff: .gaussian
            )

            // Lower lid moves -Y
            field.addGaussian(
                center: eye.lowerLidCenter,
                radiusX: ew * 0.45,
                radiusY: eh * 0.55,
                displacement: SIMD2<Double>(0, -dy),
                falloff: .gaussian
            )
        }

        // 4. 眼位倾斜与走势校准 (Eye Tilt)
        if abs(settings.eyeTilt) > 0.0001 {
            // Positive lifts outer canthus (+Y) and lowers inner canthus slightly (-Y)
            let dyOuter = eh * 0.42 * settings.eyeTilt
            let dyInner = -eh * 0.12 * settings.eyeTilt

            field.addGaussian(
                center: eye.outerCanthus,
                radiusX: ew * 0.42,
                radiusY: eh * 0.68,
                displacement: SIMD2<Double>(0, dyOuter),
                falloff: .gaussian
            )

            field.addGaussian(
                center: eye.innerCanthus,
                radiusX: ew * 0.35,
                radiusY: eh * 0.55,
                displacement: SIMD2<Double>(0, dyInner),
                falloff: .gaussian
            )
        }
    }

    private static func expandEye(to field: inout WarpField, eye: SingleEyeMetrics, factor: Double) {
        let ew = eye.width
        let eh = eye.height
        let radX = ew * 0.75
        let radY = eh * 1.10
        let expandDist = factor * 0.008

        // Displace radially outward from eye center
        field.addGaussian(center: CGPoint(x: eye.center.x - ew * 0.3, y: eye.center.y),
                          radiusX: radX * 0.5, radiusY: radY * 0.5,
                          displacement: SIMD2<Double>(-expandDist, 0), falloff: .gaussian)
        field.addGaussian(center: CGPoint(x: eye.center.x + ew * 0.3, y: eye.center.y),
                          radiusX: radX * 0.5, radiusY: radY * 0.5,
                          displacement: SIMD2<Double>(expandDist, 0), falloff: .gaussian)
        field.addGaussian(center: CGPoint(x: eye.center.x, y: eye.center.y + eh * 0.3),
                          radiusX: radX * 0.5, radiusY: radY * 0.5,
                          displacement: SIMD2<Double>(0, expandDist), falloff: .gaussian)
        field.addGaussian(center: CGPoint(x: eye.center.x, y: eye.center.y - eh * 0.3),
                          radiusX: radX * 0.5, radiusY: radY * 0.5,
                          displacement: SIMD2<Double>(0, -expandDist), falloff: .gaussian)
    }
}

// MARK: - Internal Metrics & Geometry

public struct SingleEyeMetrics: Equatable {
    public var innerCanthus: CGPoint
    public var outerCanthus: CGPoint
    public var upperLidApex: CGPoint
    public var lowerLidCenter: CGPoint
    public var center: CGPoint
    public var width: Double
    public var height: Double

    public init(innerCanthus: CGPoint, outerCanthus: CGPoint,
                upperLidApex: CGPoint, lowerLidCenter: CGPoint,
                center: CGPoint, width: Double, height: Double) {
        self.innerCanthus = innerCanthus
        self.outerCanthus = outerCanthus
        self.upperLidApex = upperLidApex
        self.lowerLidCenter = lowerLidCenter
        self.center = center
        self.width = width
        self.height = height
    }
}

public struct EyeShapeGeometry: Equatable {
    public var boundingBox: CGRect
    public var leftEyeMetrics: SingleEyeMetrics?
    public var rightEyeMetrics: SingleEyeMetrics?

    public init?(face: FaceLandmarkSet, imageSize: CGSize) {
        guard face.hasUsableGeometry, !face.leftEye.isEmpty || !face.rightEye.isEmpty else { return nil }
        self.boundingBox = face.boundingBox

        if !face.leftEye.isEmpty {
            self.leftEyeMetrics = Self.extractMetrics(points: face.leftEye, pupil: face.leftPupil, isLeftEye: true)
        }
        if !face.rightEye.isEmpty {
            self.rightEyeMetrics = Self.extractMetrics(points: face.rightEye, pupil: face.rightPupil, isLeftEye: false)
        }

        if self.leftEyeMetrics == nil && self.rightEyeMetrics == nil {
            return nil
        }
    }

    private static func extractMetrics(points: [CGPoint], pupil: CGPoint?, isLeftEye: Bool) -> SingleEyeMetrics? {
        guard points.count >= 3 else { return nil }

        let minXPt = points.min(by: { $0.x < $1.x })!
        let maxXPt = points.max(by: { $0.x < $1.x })!
        let minYPt = points.min(by: { $0.y < $1.y })!
        let maxYPt = points.max(by: { $0.y < $1.y })!

        // For image-left eye, inner canthus faces face center (larger X), outer canthus faces temple (smaller X)
        // For image-right eye, inner canthus faces face center (smaller X), outer canthus faces temple (larger X)
        let inner = isLeftEye ? maxXPt : minXPt
        let outer = isLeftEye ? minXPt : maxXPt

        let upper = maxYPt
        let lower = minYPt

        let width = max(0.01, abs(Double(outer.x - inner.x)))
        let height = max(0.005, abs(Double(upper.y - lower.y)))

        let calculatedCenter = CGPoint(
            x: (inner.x + outer.x) * 0.5,
            y: (upper.y + lower.y) * 0.5
        )
        let eyeCenter = pupil ?? calculatedCenter

        return SingleEyeMetrics(
            innerCanthus: inner,
            outerCanthus: outer,
            upperLidApex: upper,
            lowerLidCenter: lower,
            center: eyeCenter,
            width: width,
            height: height
        )
    }
}

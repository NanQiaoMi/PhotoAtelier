import CoreGraphics
import CoreImage
import Foundation
import Vision

// MARK: - Skeleton Representation

/// A single recognized human body joint.
public struct BodyJoint: Codable, Equatable {
    public var name: String
    /// Normalized coordinates (0...1, bottom-left origin).
    public var location: CGPoint
    /// Vision detection confidence (0...1).
    public var confidence: Float

    public init(name: String, location: CGPoint, confidence: Float) {
        self.name = name
        self.location = location
        self.confidence = confidence
    }
}

/// Normalized 2D human skeletal posture representation.
public struct HumanBodySkeleton: Codable, Equatable {
    public var joints: [String: BodyJoint]

    public init(joints: [String: BodyJoint] = [:]) {
        self.joints = joints
    }

    public func location(for joint: VNHumanBodyPoseObservation.JointName, minConfidence: Float = 0.15) -> CGPoint? {
        guard let j = joints[joint.rawValue.rawValue], j.confidence >= minConfidence else {
            return nil
        }
        return j.location
    }

    public var neck: CGPoint? { location(for: .neck) }
    public var root: CGPoint? { location(for: .root) }
    public var leftShoulder: CGPoint? { location(for: .leftShoulder) }
    public var rightShoulder: CGPoint? { location(for: .rightShoulder) }
    public var leftElbow: CGPoint? { location(for: .leftElbow) }
    public var rightElbow: CGPoint? { location(for: .rightElbow) }
    public var leftWrist: CGPoint? { location(for: .leftWrist) }
    public var rightWrist: CGPoint? { location(for: .rightWrist) }
    public var leftHip: CGPoint? { location(for: .leftHip) }
    public var rightHip: CGPoint? { location(for: .rightHip) }
    public var leftKnee: CGPoint? { location(for: .leftKnee) }
    public var rightKnee: CGPoint? { location(for: .rightKnee) }
    public var leftAnkle: CGPoint? { location(for: .leftAnkle) }
    public var rightAnkle: CGPoint? { location(for: .rightAnkle) }
}

// MARK: - Body Reshape Engine

/// P2-O: Smart human body reshaping and skeletal posture refinement engine.
///
/// Combines native Apple Vision body pose detection (`VNDetectHumanBodyPoseRequest`) with
/// anatomical deformation vector fields (`WarpField`) executed entirely on Core Image / GPU.
public enum BodyReshapeEngine {

    /// Detects human body skeletons in an image.
    public static func detectSkeletons(in image: CIImage) -> [HumanBodySkeleton] {
        let request = VNDetectHumanBodyPoseRequest()
        request.usesCPUOnly = false
        do {
            try VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }
        var skeletons: [HumanBodySkeleton] = []
        for obs in observations {
            guard let points = try? obs.recognizedPoints(.all) else { continue }
            var jointDict: [String: BodyJoint] = [:]
            for (key, pt) in points {
                guard pt.confidence >= 0.10, pt.location.x.isFinite, pt.location.y.isFinite else { continue }
                let name = key.rawValue.rawValue
                jointDict[name] = BodyJoint(name: name, location: pt.location, confidence: pt.confidence)
            }
            if !jointDict.isEmpty {
                skeletons.append(HumanBodySkeleton(joints: jointDict))
            }
        }
        return skeletons
    }

    /// Generates a combined WarpField representing body reshaping deformation for all active subjects.
    public static func generateWarpField(
        imageSize: CGSize,
        skeletons: [HumanBodySkeleton],
        settings: BodyReshapeSettings,
        multiPerson: MultiPersonSettings? = nil,
        faceLandmarks: [FaceLandmarkSet]? = nil,
        resolution: Int = WarpField.defaultResolution
    ) -> WarpField {
        var field = WarpField(columns: resolution, rows: resolution)
        guard imageSize.width > 1, imageSize.height > 1, !skeletons.isEmpty else {
            return field
        }

        var allSegments: [(CGPoint, CGPoint, Double)] = []

        for (skeletonIndex, skeleton) in skeletons.enumerated() {
            // Resolve per-person overrides if multiPerson is active
            var activeSettings = settings
            if let multiPerson, multiPerson.enabled {
                if let faces = faceLandmarks, !faces.isEmpty {
                    let skelX = skeleton.neck?.x ?? skeleton.root?.x ?? 0.5
                    var bestFaceIdx = 0
                    var bestDist = Double.greatestFiniteMagnitude
                    for (fIdx, face) in faces.enumerated() {
                        let dist = abs(Double(face.boundingBox.midX - skelX))
                        if dist < bestDist {
                            bestDist = dist
                            bestFaceIdx = fIdx
                        }
                    }
                    if let prof = multiPerson.profile(for: bestFaceIdx), let override = prof.bodyReshapeOverride {
                        activeSettings = override
                    }
                } else if skeletonIndex < multiPerson.individualProfiles.count {
                    if let override = multiPerson.individualProfiles[skeletonIndex].bodyReshapeOverride {
                        activeSettings = override
                    }
                }
            }

            guard !activeSettings.isNeutral else { continue }

            // 1. Swan neck (天鹅颈)
            if activeSettings.swanNeck > 0 {
                addSwanNeck(to: &field, skeleton: skeleton, strength: activeSettings.swanNeck)
            }

            // 2. Trapezius contraction & right-angle shoulder (直角肩/斜方肌)
            if activeSettings.trapeziusContraction > 0 {
                addTrapeziusContraction(to: &field, skeleton: skeleton, strength: activeSettings.trapeziusContraction)
            }

            // 3. Body slimming (整体瘦身)
            if activeSettings.bodySlimming > 0 {
                addBodySlimming(to: &field, skeleton: skeleton, strength: activeSettings.bodySlimming)
            }

            // 4. Waist cinching (细腰收腹)
            if activeSettings.waistCinching > 0 {
                addWaistCinching(to: &field, skeleton: skeleton, strength: activeSettings.waistCinching)
            }

            // 5. Leg lengthening (长腿增高)
            if activeSettings.legLengthening > 0 {
                addLegLengthening(to: &field, skeleton: skeleton, strength: activeSettings.legLengthening)
            }

            // 6. Arm slimming (瘦手臂)
            if activeSettings.armSlimming > 0 {
                addArmSlimming(to: &field, skeleton: skeleton, strength: activeSettings.armSlimming)
            }

            // Collect anatomical segments for background protection
            allSegments.append(contentsOf: anatomicalSegments(for: skeleton))
        }

        guard !field.isIdentity else { return field }

        // Field smoothing to avoid sharp ridges
        field.smooth(passes: 2)

        // Background protection: attenuate displacement outside the subject envelope
        if settings.backgroundProtection > 0, !allSegments.isEmpty {
            field.attenuateOutsideEnvelope(segments: allSegments,
                                           protection: settings.backgroundProtection,
                                           feather: 0.08)
        }

        // Clamp maximum displacement to maintain natural anatomical boundaries
        field.clampMagnitude(WarpField.maximumDisplacement)

        return field
    }

    /// Applies smart body reshaping to `image`.
    public static func apply(
        _ image: CIImage,
        settings: BodyReshapeSettings,
        skeletons: [HumanBodySkeleton]? = nil,
        personMatte: PersonMatte? = nil,
        multiPerson: MultiPersonSettings? = nil,
        faceLandmarks: [FaceLandmarkSet]? = nil,
        context: CIContext? = nil,
        cancellation: CancellationToken? = nil
    ) throws -> (image: CIImage, report: BodyReshapeReport) {
        guard !settings.isNeutral else {
            return (image, BodyReshapeReport(applied: false, skeletonsDetected: 0, note: "身形塑形未启用或参数全为中性。"))
        }

        let validated = try settings.validated()
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width >= 2, extent.height >= 2 else {
            return (image, BodyReshapeReport(applied: false, skeletonsDetected: 0, note: "图像尺寸无效。"))
        }

        try cancellation?.check()

        let activeSkeletons: [HumanBodySkeleton]
        if let skeletons {
            activeSkeletons = skeletons
        } else {
            activeSkeletons = detectSkeletons(in: image)
        }

        guard !activeSkeletons.isEmpty else {
            let note = "未检测到人体骨骼姿态点，全身身形塑形已跳过（原图保持不变）。"
            return (image, BodyReshapeReport(applied: false, skeletonsDetected: 0, note: note))
        }

        try cancellation?.check()

        let field = generateWarpField(
            imageSize: extent.size,
            skeletons: activeSkeletons,
            settings: validated,
            multiPerson: multiPerson,
            faceLandmarks: faceLandmarks
        )

        guard !field.isIdentity else {
            return (image, BodyReshapeReport(applied: false, skeletonsDetected: activeSkeletons.count, note: "形变场为零位移，图像保持不变。"))
        }

        try cancellation?.check()

        let warped = try field.apply(to: image)
        let report = BodyReshapeReport(
            applied: true,
            skeletonsDetected: activeSkeletons.count,
            note: "已成功应用全身身形与骨骼点姿态微调（检测到 \(activeSkeletons.count) 个人体骨架）。"
        )
        return (warped, report)
    }

    // MARK: - Anatomical Deformation Helpers

    /// Swan neck: narrows neck laterally and slightly pulls upper neck upward.
    private static func addSwanNeck(to field: inout WarpField, skeleton: HumanBodySkeleton, strength: Double) {
        guard let neck = skeleton.neck else { return }
        let leftSh = skeleton.leftShoulder
        let rightSh = skeleton.rightShoulder
        let shoulderSpan: Double
        if let leftSh, let rightSh {
            shoulderSpan = max(0.10, abs(leftSh.x - rightSh.x))
        } else {
            shoulderSpan = 0.25
        }
        let neckWidth = shoulderSpan * 0.32
        let s = min(1, max(0, strength))

        // Lateral inward contraction (收细)
        let leftNeck = CGPoint(x: neck.x - neckWidth * 0.60, y: neck.y + 0.035)
        let rightNeck = CGPoint(x: neck.x + neckWidth * 0.60, y: neck.y + 0.035)
        field.addGaussian(center: leftNeck, radiusX: neckWidth * 0.65, radiusY: 0.05,
                          displacement: SIMD2(0.012 * s, 0), falloff: .gaussian)
        field.addGaussian(center: rightNeck, radiusX: neckWidth * 0.65, radiusY: 0.05,
                          displacement: SIMD2(-0.012 * s, 0), falloff: .gaussian)

        // Vertical elongation (拉伸)
        let upperNeck = CGPoint(x: neck.x, y: neck.y + 0.06)
        field.addGaussian(center: upperNeck, radiusX: neckWidth * 0.8, radiusY: 0.05,
                          displacement: SIMD2(0, 0.015 * s), falloff: .gaussian)
        let lowerNeck = CGPoint(x: neck.x, y: neck.y - 0.01)
        field.addGaussian(center: lowerNeck, radiusX: neckWidth * 0.8, radiusY: 0.035,
                          displacement: SIMD2(0, -0.005 * s), falloff: .gaussian)
    }

    /// Trapezius contraction: depresses the upper sloping trapezius line and elevates the acromion for a right-angle shoulder contour.
    private static func addTrapeziusContraction(to field: inout WarpField, skeleton: HumanBodySkeleton, strength: Double) {
        guard let neck = skeleton.neck else { return }
        let s = min(1, max(0, strength))

        if let leftSh = skeleton.leftShoulder {
            let leftTrap = CGPoint(x: (neck.x + leftSh.x) * 0.5, y: (neck.y + leftSh.y) * 0.5 + 0.015)
            let trapRadius = max(0.04, hypot(leftSh.x - neck.x, leftSh.y - neck.y) * 0.55)
            // Downward and inward depression
            field.addGaussian(center: leftTrap, radiusX: trapRadius, radiusY: trapRadius * 0.75,
                              displacement: SIMD2(-0.006 * s, -0.018 * s), falloff: .gaussian)
            // Acromion elevation for straight horizontal line
            field.addGaussian(center: leftSh, radiusX: trapRadius * 0.55, radiusY: trapRadius * 0.55,
                              displacement: SIMD2(-0.004 * s, 0.008 * s), falloff: .gaussian)
        }

        if let rightSh = skeleton.rightShoulder {
            let rightTrap = CGPoint(x: (neck.x + rightSh.x) * 0.5, y: (neck.y + rightSh.y) * 0.5 + 0.015)
            let trapRadius = max(0.04, hypot(rightSh.x - neck.x, rightSh.y - neck.y) * 0.55)
            // Downward and inward depression
            field.addGaussian(center: rightTrap, radiusX: trapRadius, radiusY: trapRadius * 0.75,
                              displacement: SIMD2(0.006 * s, -0.018 * s), falloff: .gaussian)
            // Acromion elevation
            field.addGaussian(center: rightSh, radiusX: trapRadius * 0.55, radiusY: trapRadius * 0.55,
                              displacement: SIMD2(0.004 * s, 0.008 * s), falloff: .gaussian)
        }
    }

    /// Overall body slimming: pushes the lateral torso inward toward the spine centerline.
    private static func addBodySlimming(to field: inout WarpField, skeleton: HumanBodySkeleton, strength: Double) {
        let topPt = skeleton.neck ?? skeleton.leftShoulder ?? skeleton.rightShoulder
        let bottomPt = skeleton.root ?? skeleton.leftHip ?? skeleton.rightHip
        guard let topPt, let bottomPt else { return }

        let spineX = (topPt.x + bottomPt.x) * 0.5
        let torsoHeight = max(0.15, topPt.y - bottomPt.y)
        let shoulderSpan = abs((skeleton.leftShoulder?.x ?? 0.6) - (skeleton.rightShoulder?.x ?? 0.4))
        let hipSpan = abs((skeleton.leftHip?.x ?? 0.6) - (skeleton.rightHip?.x ?? 0.4))
        let torsoWidth = max(0.14, max(shoulderSpan, hipSpan))
        let s = min(1, max(0, strength))

        // Three vertical levels across the torso
        let levels: [Double] = [0.25, 0.50, 0.75]
        for level in levels {
            let y = bottomPt.y + torsoHeight * level
            let leftFlank = CGPoint(x: spineX - torsoWidth * 0.54, y: y)
            let rightFlank = CGPoint(x: spineX + torsoWidth * 0.54, y: y)
            field.addGaussian(center: leftFlank, radiusX: torsoWidth * 0.45, radiusY: torsoHeight * 0.25,
                              displacement: SIMD2(0.018 * s, 0), falloff: .gaussian)
            field.addGaussian(center: rightFlank, radiusX: torsoWidth * 0.45, radiusY: torsoHeight * 0.25,
                              displacement: SIMD2(-0.018 * s, 0), falloff: .gaussian)
        }
    }

    /// Waist cinching: focal hourglass narrowing at the anatomical waist indentation level.
    private static func addWaistCinching(to field: inout WarpField, skeleton: HumanBodySkeleton, strength: Double) {
        let topPt = skeleton.neck ?? skeleton.leftShoulder ?? skeleton.rightShoulder
        let bottomPt = skeleton.root ?? skeleton.leftHip ?? skeleton.rightHip
        guard let topPt, let bottomPt else { return }

        let spineX = (topPt.x + bottomPt.x) * 0.5
        let torsoHeight = max(0.15, topPt.y - bottomPt.y)
        let shoulderSpan = abs((skeleton.leftShoulder?.x ?? 0.6) - (skeleton.rightShoulder?.x ?? 0.4))
        let hipSpan = abs((skeleton.leftHip?.x ?? 0.6) - (skeleton.rightHip?.x ?? 0.4))
        let torsoWidth = max(0.14, max(shoulderSpan, hipSpan))
        let s = min(1, max(0, strength))

        let waistY = bottomPt.y + torsoHeight * 0.42
        let leftWaist = CGPoint(x: spineX - torsoWidth * 0.48, y: waistY)
        let rightWaist = CGPoint(x: spineX + torsoWidth * 0.48, y: waistY)

        field.addGaussian(center: leftWaist, radiusX: torsoWidth * 0.38, radiusY: torsoHeight * 0.18,
                          displacement: SIMD2(0.024 * s, 0), falloff: .gaussian)
        field.addGaussian(center: rightWaist, radiusX: torsoWidth * 0.38, radiusY: torsoHeight * 0.18,
                          displacement: SIMD2(-0.024 * s, 0), falloff: .gaussian)
    }

    /// Leg lengthening: progressive downward stretch below hip level.
    private static func addLegLengthening(to field: inout WarpField, skeleton: HumanBodySkeleton, strength: Double) {
        let yHip = skeleton.root?.y ?? ((skeleton.leftHip?.y ?? 0.5) + (skeleton.rightHip?.y ?? 0.5)) * 0.5
        let yBottomCandidates = [skeleton.leftAnkle?.y, skeleton.rightAnkle?.y, skeleton.leftKnee?.y, skeleton.rightKnee?.y].compactMap { $0 }
        let yBottom = yBottomCandidates.min() ?? 0.0
        let legSpan = max(0.20, yHip - yBottom)
        let s = min(1, max(0, strength))

        let leftX = skeleton.leftHip?.x ?? skeleton.leftKnee?.x ?? 0.42
        let rightX = skeleton.rightHip?.x ?? skeleton.rightKnee?.x ?? 0.58

        // Thigh level (35% down)
        let yThigh = yHip - legSpan * 0.35
        field.addGaussian(center: CGPoint(x: leftX, y: yThigh), radiusX: 0.12, radiusY: legSpan * 0.25,
                          displacement: SIMD2(0, -0.012 * s), falloff: .gaussian)
        field.addGaussian(center: CGPoint(x: rightX, y: yThigh), radiusX: 0.12, radiusY: legSpan * 0.25,
                          displacement: SIMD2(0, -0.012 * s), falloff: .gaussian)

        // Shin / calf level (70% down)
        let yCalf = yHip - legSpan * 0.70
        let leftCalfX = skeleton.leftKnee?.x ?? leftX
        let rightCalfX = skeleton.rightKnee?.x ?? rightX
        field.addGaussian(center: CGPoint(x: leftCalfX, y: yCalf), radiusX: 0.12, radiusY: legSpan * 0.30,
                          displacement: SIMD2(0, -0.022 * s), falloff: .gaussian)
        field.addGaussian(center: CGPoint(x: rightCalfX, y: yCalf), radiusX: 0.12, radiusY: legSpan * 0.30,
                          displacement: SIMD2(0, -0.022 * s), falloff: .gaussian)

        // Ankle level (92% down)
        let yAnkle = yHip - legSpan * 0.92
        let leftAnkleX = skeleton.leftAnkle?.x ?? leftCalfX
        let rightAnkleX = skeleton.rightAnkle?.x ?? rightCalfX
        field.addGaussian(center: CGPoint(x: leftAnkleX, y: yAnkle), radiusX: 0.12, radiusY: legSpan * 0.25,
                          displacement: SIMD2(0, -0.028 * s), falloff: .gaussian)
        field.addGaussian(center: CGPoint(x: rightAnkleX, y: yAnkle), radiusX: 0.12, radiusY: legSpan * 0.25,
                          displacement: SIMD2(0, -0.028 * s), falloff: .gaussian)
    }

    /// Arm slimming: narrows the upper arm bicep/tricep silhouette toward the humerus bone axis.
    private static func addArmSlimming(to field: inout WarpField, skeleton: HumanBodySkeleton, strength: Double) {
        let s = min(1, max(0, strength))

        // Left arm
        if let sh = skeleton.leftShoulder, let elb = skeleton.leftElbow {
            let midArm = CGPoint(x: (sh.x + elb.x) * 0.5, y: (sh.y + elb.y) * 0.5)
            let armDx = elb.x - sh.x
            let armDy = elb.y - sh.y
            let armLen = max(0.05, hypot(armDx, armDy))
            // Outer normal pointing to the left
            var nx = -armDy / armLen
            var ny = armDx / armLen
            if nx > 0 { nx = -nx; ny = -ny }
            let outerPt = CGPoint(x: midArm.x + nx * (armLen * 0.25), y: midArm.y + ny * (armLen * 0.25))
            field.addGaussian(center: outerPt, radiusX: armLen * 0.40, radiusY: armLen * 0.40,
                              displacement: SIMD2(-nx * 0.018 * s, -ny * 0.018 * s), falloff: .gaussian)
        }

        // Right arm
        if let sh = skeleton.rightShoulder, let elb = skeleton.rightElbow {
            let midArm = CGPoint(x: (sh.x + elb.x) * 0.5, y: (sh.y + elb.y) * 0.5)
            let armDx = elb.x - sh.x
            let armDy = elb.y - sh.y
            let armLen = max(0.05, hypot(armDx, armDy))
            // Outer normal pointing to the right
            var nx = armDy / armLen
            var ny = -armDx / armLen
            if nx < 0 { nx = -nx; ny = -ny }
            let outerPt = CGPoint(x: midArm.x + nx * (armLen * 0.25), y: midArm.y + ny * (armLen * 0.25))
            field.addGaussian(center: outerPt, radiusX: armLen * 0.40, radiusY: armLen * 0.40,
                              displacement: SIMD2(-nx * 0.018 * s, -ny * 0.018 * s), falloff: .gaussian)
        }
    }

    /// Constructs bounding capsule segments for background envelope protection.
    private static func anatomicalSegments(for skeleton: HumanBodySkeleton) -> [(CGPoint, CGPoint, Double)] {
        var segments: [(CGPoint, CGPoint, Double)] = []

        // Head and neck
        if let neck = skeleton.neck {
            segments.append((neck, CGPoint(x: neck.x, y: min(1.0, neck.y + 0.14)), 0.10))
        }

        // Shoulders / Trapezius
        if let leftSh = skeleton.leftShoulder, let rightSh = skeleton.rightShoulder {
            segments.append((leftSh, rightSh, 0.09))
            if let neck = skeleton.neck {
                segments.append((neck, leftSh, 0.08))
                segments.append((neck, rightSh, 0.08))
            }
        }

        // Spine / Torso
        if let neck = skeleton.neck, let root = skeleton.root {
            segments.append((neck, root, 0.16))
        } else if let neck = skeleton.neck, let leftHip = skeleton.leftHip, let rightHip = skeleton.rightHip {
            let midHip = CGPoint(x: (leftHip.x + rightHip.x) * 0.5, y: (leftHip.y + rightHip.y) * 0.5)
            segments.append((neck, midHip, 0.16))
        }

        // Pelvis / Hips
        if let leftHip = skeleton.leftHip, let rightHip = skeleton.rightHip {
            segments.append((leftHip, rightHip, 0.14))
        }

        // Left arm
        if let leftSh = skeleton.leftShoulder, let leftElb = skeleton.leftElbow {
            segments.append((leftSh, leftElb, 0.08))
            if let leftWri = skeleton.leftWrist {
                segments.append((leftElb, leftWri, 0.07))
            }
        }

        // Right arm
        if let rightSh = skeleton.rightShoulder, let rightElb = skeleton.rightElbow {
            segments.append((rightSh, rightElb, 0.08))
            if let rightWri = skeleton.rightWrist {
                segments.append((rightElb, rightWri, 0.07))
            }
        }

        // Left leg
        if let leftHip = skeleton.leftHip, let leftKnee = skeleton.leftKnee {
            segments.append((leftHip, leftKnee, 0.10))
            if let leftAnk = skeleton.leftAnkle {
                segments.append((leftKnee, leftAnk, 0.09))
            }
        }

        // Right leg
        if let rightHip = skeleton.rightHip, let rightKnee = skeleton.rightKnee {
            segments.append((rightHip, rightKnee, 0.10))
            if let rightAnk = skeleton.rightAnkle {
                segments.append((rightKnee, rightAnk, 0.09))
            }
        }

        return segments
    }
}

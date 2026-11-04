import CoreGraphics
import CoreImage
import Foundation

// MARK: - Parameters

/// The seven built-in face-shape presets.
///
/// Presets are heuristic starting points expressed as offsets on the same six
/// sliders; they are additive with the user's explicit slider values and clamped
/// to `-1...1`. `classic` is the neutral preset (all offsets zero).
public enum FaceShapePreset: String, Codable, CaseIterable, Identifiable {
    case classic, youthful, heroic, boyish, round, long, square

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .classic: return "经典"
        case .youthful: return "幼态"
        case .heroic: return "英气"
        case .boyish: return "少年"
        case .round: return "圆脸"
        case .long: return "长脸"
        case .square: return "方脸"
        }
    }

    /// Heuristic per-preset offsets. Direction semantics are documented on
    /// `FaceReshapeParameters`.
    public var parameters: FaceReshapeParameters {
        switch self {
        case .classic:
            return FaceReshapeParameters()
        case .youthful:
            return FaceReshapeParameters(slimFace: 0.20, smallFace: 0.25, enlargeEyes: 0.40,
                                         narrowNose: 0.15, lipWidth: 0.10, chin: -0.30)
        case .heroic:
            return FaceReshapeParameters(slimFace: 0.50, smallFace: 0.15, enlargeEyes: 0,
                                         narrowNose: 0.35, lipWidth: 0.05, chin: 0.25)
        case .boyish:
            return FaceReshapeParameters(slimFace: 0.30, smallFace: 0.20, enlargeEyes: 0.20,
                                         narrowNose: 0.15, lipWidth: 0, chin: 0.10)
        case .round:
            return FaceReshapeParameters(slimFace: 0.55, smallFace: 0.40, enlargeEyes: 0.20,
                                         narrowNose: 0.10, lipWidth: 0.15, chin: -0.20)
        case .long:
            return FaceReshapeParameters(slimFace: 0.10, smallFace: -0.30, enlargeEyes: 0,
                                         narrowNose: 0.10, lipWidth: 0, chin: -0.35)
        case .square:
            return FaceReshapeParameters(slimFace: 0.35, smallFace: 0.10, enlargeEyes: 0,
                                         narrowNose: 0.25, lipWidth: 0, chin: 0.15)
        }
    }
}

/// Face-reshaping sliders, each in `-1...1` with `0` neutral.
///
/// Direction contract (positive value):
/// - `slimFace`: face contour moves inward horizontally (toward the face centre);
/// - `smallFace`: contour moves inward in both axes;
/// - `enlargeEyes`: eye region expands radially outward around each eye centre;
/// - `narrowNose`: nose sides move toward the nose axis;
/// - `lipWidth`: lip corners move toward the mouth centre (narrower mouth);
/// - `chin`: chin moves down (longer lower face); negative moves it up.
public struct FaceReshapeParameters: Codable, Equatable {
    public var slimFace: Double
    public var smallFace: Double
    public var enlargeEyes: Double
    public var narrowNose: Double
    public var lipWidth: Double
    public var chin: Double

    public init(slimFace: Double = 0, smallFace: Double = 0, enlargeEyes: Double = 0,
                narrowNose: Double = 0, lipWidth: Double = 0, chin: Double = 0) {
        self.slimFace = slimFace
        self.smallFace = smallFace
        self.enlargeEyes = enlargeEyes
        self.narrowNose = narrowNose
        self.lipWidth = lipWidth
        self.chin = chin
    }

    private enum CodingKeys: String, CodingKey {
        case slimFace, smallFace, enlargeEyes, narrowNose, lipWidth, chin
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        slimFace = try values.decodeIfPresent(Double.self, forKey: .slimFace) ?? 0
        smallFace = try values.decodeIfPresent(Double.self, forKey: .smallFace) ?? 0
        enlargeEyes = try values.decodeIfPresent(Double.self, forKey: .enlargeEyes) ?? 0
        narrowNose = try values.decodeIfPresent(Double.self, forKey: .narrowNose) ?? 0
        lipWidth = try values.decodeIfPresent(Double.self, forKey: .lipWidth) ?? 0
        chin = try values.decodeIfPresent(Double.self, forKey: .chin) ?? 0
    }

    /// All-neutral slider values.
    public var isNeutral: Bool {
        slimFace == 0 && smallFace == 0 && enlargeEyes == 0
            && narrowNose == 0 && lipWidth == 0 && chin == 0
    }

    /// Non-finite values are treated as neutral so a corrupt payload cannot
    /// produce NaN displacements.
    var sanitized: FaceReshapeParameters {
        func clean(_ value: Double) -> Double {
            value.isFinite ? min(1, max(-1, value)) : 0
        }
        return FaceReshapeParameters(slimFace: clean(slimFace), smallFace: clean(smallFace),
                                     enlargeEyes: clean(enlargeEyes), narrowNose: clean(narrowNose),
                                     lipWidth: clean(lipWidth), chin: clean(chin))
    }

    func adding(_ other: FaceReshapeParameters) -> FaceReshapeParameters {
        func sum(_ lhs: Double, _ rhs: Double) -> Double {
            let value = (lhs.isFinite ? lhs : 0) + (rhs.isFinite ? rhs : 0)
            return min(1, max(-1, value))
        }
        return FaceReshapeParameters(slimFace: sum(slimFace, other.slimFace),
                                     smallFace: sum(smallFace, other.smallFace),
                                     enlargeEyes: sum(enlargeEyes, other.enlargeEyes),
                                     narrowNose: sum(narrowNose, other.narrowNose),
                                     lipWidth: sum(lipWidth, other.lipWidth),
                                     chin: sum(chin, other.chin))
    }

    var allValues: [(name: String, value: Double)] {
        [("瘦脸", slimFace), ("小脸", smallFace), ("大眼", enlargeEyes),
         ("鼻翼", narrowNose), ("嘴唇", lipWidth), ("下巴", chin)]
    }
}

/// All liquify/face-reshaping parameters for one photo.
///
/// `preset` contributes offsets on top of the explicit `parameters`; both are
/// clamped and additive. `strength` scales the whole auto warp (`0...1`, `1` =
/// nominal). Manual `strokes` are applied after the automatic field, so users can
/// push/rebuild/smooth locally on top of a preset.
///
/// This is a heuristic v1 model: it does not understand identity, beauty ideals or
/// occlusion, only landmark geometry. It is not a commercial-grade beauty engine.
public struct FaceReshapeSettings: Codable, Equatable {
    public var preset: FaceShapePreset
    public var parameters: FaceReshapeParameters
    /// Global multiplier for the automatic face-shape warp.
    public var strength: Double
    /// Fade the automatic field to zero outside the detected face rectangle so
    /// background straight lines stay straight.
    public var backgroundProtection: Bool
    /// Manual liquify strokes, applied in order after the automatic warp.
    public var strokes: [WarpStroke]

    public init(preset: FaceShapePreset = .classic,
                parameters: FaceReshapeParameters = FaceReshapeParameters(),
                strength: Double = 1,
                backgroundProtection: Bool = true,
                strokes: [WarpStroke] = []) {
        self.preset = preset
        self.parameters = parameters
        self.strength = strength
        self.backgroundProtection = backgroundProtection
        self.strokes = strokes
    }

    private enum CodingKeys: String, CodingKey {
        case preset, parameters, strength, backgroundProtection, strokes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preset = try values.decodeIfPresent(FaceShapePreset.self, forKey: .preset) ?? .classic
        parameters = try values.decodeIfPresent(FaceReshapeParameters.self, forKey: .parameters)
            ?? FaceReshapeParameters()
        strength = try values.decodeIfPresent(Double.self, forKey: .strength) ?? 1
        backgroundProtection = try values.decodeIfPresent(Bool.self, forKey: .backgroundProtection) ?? true
        strokes = try values.decodeIfPresent([WarpStroke].self, forKey: .strokes) ?? []
    }

    /// Preset offsets plus explicit sliders, clamped to `-1...1`.
    public var effectiveParameters: FaceReshapeParameters {
        preset.parameters.adding(parameters)
    }

    /// True when the settings cannot change any pixel: no strokes, and either the
    /// effective sliders are zero or the global strength is zero.
    public var isNeutral: Bool {
        if !strokes.isEmpty { return false }
        guard strength.isFinite, strength > 0 else { return true }
        return effectiveParameters.isNeutral
    }
}

// MARK: - Engine

/// Builds a `WarpField` from `FaceLandmarkSet` geometry and `FaceReshapeSettings`.
public enum FaceReshapeEngine {
    /// Upper bound on stored manual strokes (bounds the field budget).
    public static let maximumStrokeCount = 64
    /// Upper bound on points per stroke.
    public static let maximumStrokePoints = 4096

    /// Validates ranges so a malformed recipe fails loudly instead of silently
    /// producing NaN geometry. `warpField` additionally sanitizes defensively.
    public static func validate(_ settings: FaceReshapeSettings) throws {
        guard settings.strength.isFinite, (0...1).contains(settings.strength) else {
            throw AtelierError.invalidConfiguration("液化强度必须在 0...1 之间。")
        }
        for item in settings.parameters.allValues {
            guard item.value.isFinite, (-1...1).contains(item.value) else {
                throw AtelierError.invalidConfiguration("液化\(item.name)参数必须在 -1...1 之间。")
            }
        }
        guard settings.strokes.count <= maximumStrokeCount else {
            throw AtelierError.invalidConfiguration("手动液化笔迹数量不能超过 \(maximumStrokeCount) 条。")
        }
        for (index, stroke) in settings.strokes.enumerated() {
            guard stroke.radius.isFinite, (0.001...0.5).contains(stroke.radius) else {
                throw AtelierError.invalidConfiguration("第 \(index + 1) 条液化笔迹半径超出 0.001...0.5。")
            }
            guard stroke.strength.isFinite, (0...1).contains(stroke.strength) else {
                throw AtelierError.invalidConfiguration("第 \(index + 1) 条液化笔迹强度必须在 0...1 之间。")
            }
            guard stroke.points.count <= maximumStrokePoints else {
                throw AtelierError.invalidConfiguration("第 \(index + 1) 条液化笔迹点数不能超过 \(maximumStrokePoints)。")
            }
            for point in stroke.points {
                guard point.x.isFinite, point.y.isFinite,
                      (0...1).contains(point.x), (0...1).contains(point.y) else {
                    throw AtelierError.invalidConfiguration("第 \(index + 1) 条液化笔迹坐标必须为 0...1 的有限值。")
                }
            }
        }
    }

    /// Builds the displacement field for one image.
    ///
    /// - Parameters:
    ///   - landmarks: Vision landmarks in normalized image coordinates. `nil` or
    ///     unusable landmarks skip the automatic face-shape part; manual strokes
    ///     still apply.
    ///   - settings: Preset/sliders/strength/strokes. Neutral settings return an
    ///     identity field.
    ///   - imageSize: Pixel size of the target image (for brush/radius scaling).
    ///   - resolution: Grid resolution per axis, clamped to `8...256`.
    public static func warpField(landmarks: FaceLandmarkSet?,
                                 settings: FaceReshapeSettings,
                                 imageSize: CGSize,
                                 resolution: Int = WarpField.defaultResolution) -> WarpField {
        let clampedResolution = max(8, min(256, resolution))
        var field = WarpField(columns: clampedResolution, rows: clampedResolution)
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 1, imageSize.height > 1 else { return field }
        let strength = settings.strength.isFinite ? min(1, max(0, settings.strength)) : 0
        let parameters = settings.effectiveParameters.sanitized
        let geometry = landmarks.flatMap { FaceReshapeGeometry(landmarks: $0, imageSize: imageSize) }

        if strength > 0, !parameters.isNeutral, let geometry {
            addFaceControls(to: &field, parameters: parameters, geometry: geometry,
                            strength: strength, imageSize: imageSize)
            field.smooth(passes: 2)
            if settings.backgroundProtection {
                let feather = max(Double(geometry.boundingBox.width),
                                  Double(geometry.boundingBox.height)) * 0.18
                field.attenuateOutside(rect: geometry.boundingBox, feather: feather)
            }
        }
        for stroke in settings.strokes {
            field.addStroke(stroke)
        }
        field.clampMagnitude()
        return field
    }

    /// Applies settings to an image. A neutral/invalid input returns the original
    /// image untouched (exact pre-v11 pixels).
    public static func apply(to image: CIImage,
                             landmarks: FaceLandmarkSet?,
                             settings: FaceReshapeSettings) throws -> CIImage {
        guard !settings.isNeutral else { return image }
        let field = warpField(landmarks: landmarks, settings: settings, imageSize: image.extent.size)
        guard !field.isIdentity else { return image }
        return try field.apply(to: image)
    }

    // MARK: Controls

    private static func addFaceControls(to field: inout WarpField,
                                        parameters: FaceReshapeParameters,
                                        geometry: FaceReshapeGeometry,
                                        strength: Double,
                                        imageSize: CGSize) {
        let width = Double(imageSize.width)
        let height = Double(imageSize.height)
        let boundingWidthPixels = Double(geometry.boundingBox.width) * width
        let boundingHeightPixels = Double(geometry.boundingBox.height) * height
        let center = CGPoint(x: geometry.boundingBox.midX, y: geometry.boundingBox.midY)

        func add(center point: CGPoint, radiusPixels: Double,
                 displacementPixels: SIMD2<Double>) {
            guard radiusPixels > 0.5, displacementPixels.x.isFinite,
                  displacementPixels.y.isFinite else { return }
            field.addGaussian(center: point,
                              radiusX: radiusPixels / width,
                              radiusY: radiusPixels / height,
                              displacement: SIMD2<Double>(displacementPixels.x / width,
                                                          displacementPixels.y / height),
                              falloff: .gaussian)
        }

        // Face outline: inward pull for slim/small face.
        let contourRadius = boundingWidthPixels * 0.28
        for point in geometry.contour {
            let dx = Double(center.x - point.x) * boundingWidthPixels
                * (0.16 * parameters.slimFace + 0.10 * parameters.smallFace) * strength
            let dy = Double(center.y - point.y) * boundingHeightPixels
                * (0.12 * parameters.smallFace + 0.015 * parameters.slimFace) * strength
            add(center: point, radiusPixels: contourRadius,
                displacementPixels: SIMD2<Double>(dx, dy))
        }

        // Eyes: radial expansion around each eye centre.
        if parameters.enlargeEyes != 0 {
            for eye in geometry.eyes {
                let ringRadius = eye.widthPixels * 0.55
                let amount = eye.widthPixels * 0.22 * parameters.enlargeEyes * strength
                guard abs(amount) > 0.05 else { continue }
                for index in 0..<8 {
                    let angle = Double(index) / 8 * 2 * Double.pi
                    let offsetX = cos(angle) * ringRadius
                    let offsetY = sin(angle) * ringRadius
                    let ringPoint = CGPoint(x: eye.center.x + offsetX / width,
                                            y: eye.center.y + offsetY / height)
                    add(center: ringPoint, radiusPixels: eye.widthPixels * 0.75,
                        displacementPixels: SIMD2<Double>(cos(angle) * amount,
                                                          sin(angle) * amount))
                }
            }
        }

        // Nose sides: toward the nose axis.
        if let nose = geometry.nose, parameters.narrowNose != 0 {
            let amount = nose.widthPixels * 0.28 * parameters.narrowNose * strength
            let offset = nose.widthPixels * 0.45
            add(center: CGPoint(x: nose.center.x - offset / width, y: nose.center.y),
                radiusPixels: nose.widthPixels * 0.6,
                displacementPixels: SIMD2<Double>(amount, 0))
            add(center: CGPoint(x: nose.center.x + offset / width, y: nose.center.y),
                radiusPixels: nose.widthPixels * 0.6,
                displacementPixels: SIMD2<Double>(-amount, 0))
        }

        // Lip corners: toward the mouth centre (narrower lips for positive values).
        if let lips = geometry.lips, parameters.lipWidth != 0 {
            let amount = lips.widthPixels * 0.22 * parameters.lipWidth * strength
            let offset = lips.widthPixels * 0.45
            add(center: CGPoint(x: lips.center.x - offset / width, y: lips.center.y),
                radiusPixels: lips.widthPixels * 0.4,
                displacementPixels: SIMD2<Double>(amount, 0))
            add(center: CGPoint(x: lips.center.x + offset / width, y: lips.center.y),
                radiusPixels: lips.widthPixels * 0.4,
                displacementPixels: SIMD2<Double>(-amount, 0))
        }

        // Chin: positive lengthens the lower face (moves the chin down = -y).
        if let chin = geometry.chin, parameters.chin != 0 {
            let amount = boundingHeightPixels * 0.10 * parameters.chin * strength
            add(center: chin, radiusPixels: boundingWidthPixels * 0.45,
                displacementPixels: SIMD2<Double>(0, -amount))
        }
    }
}

// MARK: - Geometry

/// Internal, sanitized geometry derived from `FaceLandmarkSet`. Missing regions
/// degrade to `nil` instead of producing NaN controls.
private struct FaceReshapeGeometry {
    let boundingBox: CGRect
    let contour: [CGPoint]
    let eyes: [(center: CGPoint, widthPixels: Double)]
    let nose: (center: CGPoint, widthPixels: Double)?
    let lips: (center: CGPoint, widthPixels: Double)?
    let chin: CGPoint?

    init?(landmarks: FaceLandmarkSet, imageSize: CGSize) {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 1, imageSize.height > 1 else { return nil }
        let contourPoints = landmarks.faceContour.filter(isFinite)
        var box = CGRect.zero
        if let rect = sanitizedRect(landmarks.boundingBox) {
            box = rect
        } else {
            let allPoints = contourPoints
                + landmarks.leftEye + landmarks.rightEye
                + landmarks.outerLips + landmarks.nose
            guard let union = unionBox(of: allPoints) else { return nil }
            box = union
        }
        guard box.width >= 0.02, box.height >= 0.02 else { return nil }
        boundingBox = box
        // Fall back to an ellipse when Vision omitted the contour so presets still
        // have a face outline to pull inward.
        contour = contourPoints.count >= 3
            ? contourPoints
            : (0..<24).map { index in
                let angle = Double(index) / 24 * 2 * Double.pi
                return CGPoint(x: box.midX + box.width / 2 * CGFloat(cos(angle)),
                               y: box.midY + box.height / 2 * CGFloat(sin(angle)))
            }

        var eyeList: [(center: CGPoint, widthPixels: Double)] = []
        for (region, pupil) in [(landmarks.leftEye, landmarks.leftPupil),
                                (landmarks.rightEye, landmarks.rightPupil)] {
            let points = region.filter(isFinite)
            guard points.count >= 3, let eyeBox = unionBox(of: points) else { continue }
            let widthPixels = Double(eyeBox.width) * Double(imageSize.width)
            guard widthPixels >= 3 else { continue }
            let center = pupil.flatMap { isFinite($0) ? $0 : nil } ?? centroid(points)
            eyeList.append((center: center, widthPixels: widthPixels))
        }
        eyes = eyeList

        let nosePoints = landmarks.nose.filter(isFinite)
        if nosePoints.count >= 3, let noseBox = unionBox(of: nosePoints) {
            let widthPixels = max(Double(noseBox.width) * Double(imageSize.width),
                                  Double(box.width) * Double(imageSize.width) * 0.10)
            nose = (centroid(nosePoints), widthPixels)
        } else {
            nose = nil
        }

        let lipPoints = landmarks.outerLips.filter(isFinite)
        if lipPoints.count >= 3, let lipBox = unionBox(of: lipPoints) {
            lips = (centroid(lipPoints), Double(lipBox.width) * Double(imageSize.width))
        } else {
            lips = nil
        }

        chin = contour.min { $0.y < $1.y }
    }
}

// MARK: - Small helpers

private func isFinite(_ point: CGPoint) -> Bool {
    point.x.isFinite && point.y.isFinite
}

private func sanitizedRect(_ rect: CGRect) -> CGRect? {
    guard rect.minX.isFinite, rect.minY.isFinite,
          rect.width.isFinite, rect.height.isFinite,
          rect.width > 0, rect.height > 0 else { return nil }
    return rect
}

private func centroid(_ points: [CGPoint]) -> CGPoint {
    let finite = points.filter(isFinite)
    guard !finite.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
    let sum = finite.reduce(into: CGPoint.zero) { partial, point in
        partial.x += point.x
        partial.y += point.y
    }
    return CGPoint(x: sum.x / CGFloat(finite.count), y: sum.y / CGFloat(finite.count))
}

private func unionBox(of points: [CGPoint]) -> CGRect? {
    var result = CGRect.null
    for point in points where isFinite(point) {
        result = result.union(CGRect(x: point.x, y: point.y, width: 0, height: 0))
    }
    return result.isNull ? nil : result
}

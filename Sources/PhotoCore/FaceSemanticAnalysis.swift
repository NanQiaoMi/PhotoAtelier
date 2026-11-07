import CoreGraphics
import CoreImage
import Foundation
import Vision

// MARK: - Landmark input

/// Landmark geometry for one face, expressed in **normalized image coordinates**.
///
/// Coordinate system: bottom-left origin, `x` and `y` in `0...1` relative to the
/// whole image. This matches Vision's normalized observation space and Core
/// Image's coordinate convention. Points produced by
/// `FaceSemanticAnalyzer.detect(in:maxFaces:)` have already been converted with
/// `VNFaceLandmarkRegion2D.pointsInImage(imageSize:)`, so callers never have to
/// apply the face bounding box themselves.
///
/// `boundingBox` is the face rectangle reported by the detector (same normalized,
/// bottom-left space). It is recorded in the result and used to reject empty
/// input; masks themselves are derived from the landmark polygons.
///
/// `confidence` is the detector confidence in `0...1`. `FaceSemanticAnalyzer`
/// ignores faces below `FaceSemanticAnalyzer.minimumConfidence`; synthetic
/// fixtures that build landmarks by hand can keep the default value of `1`.
///
/// Missing regions are represented by empty arrays (or `nil` pupils), which is
/// the normal situation for profile faces or occlusions. Every consumer of this
/// type must degrade per region instead of failing the whole face.
public struct FaceLandmarkSet: Equatable {
    /// Face rectangle in normalized image coordinates (bottom-left origin).
    public var boundingBox: CGRect
    /// Detector confidence in `0...1`.
    public var confidence: Double
    /// Face outline as returned by Vision's `faceContour` (jawline/forehead).
    public var faceContour: [CGPoint]
    /// Outline of the left eye (image-left) in normalized image coordinates.
    public var leftEye: [CGPoint]
    /// Outline of the right eye (image-right) in normalized image coordinates.
    public var rightEye: [CGPoint]
    public var leftEyebrow: [CGPoint]
    public var rightEyebrow: [CGPoint]
    /// Nose outline. Recorded for future use; the current masks do not cut a nose
    /// region out of the skin matte because dark nostrils are rejected by the
    /// skin colour gate instead.
    public var nose: [CGPoint]
    public var outerLips: [CGPoint]
    public var innerLips: [CGPoint]
    public var leftPupil: CGPoint?
    public var rightPupil: CGPoint?

    public init(boundingBox: CGRect = .zero,
                confidence: Double = 1,
                faceContour: [CGPoint] = [],
                leftEye: [CGPoint] = [],
                rightEye: [CGPoint] = [],
                leftEyebrow: [CGPoint] = [],
                rightEyebrow: [CGPoint] = [],
                nose: [CGPoint] = [],
                outerLips: [CGPoint] = [],
                innerLips: [CGPoint] = [],
                leftPupil: CGPoint? = nil,
                rightPupil: CGPoint? = nil) {
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.faceContour = faceContour
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.leftEyebrow = leftEyebrow
        self.rightEyebrow = rightEyebrow
        self.nose = nose
        self.outerLips = outerLips
        self.innerLips = innerLips
        self.leftPupil = leftPupil
        self.rightPupil = rightPupil
    }

    /// True when at least one polygon-shaped region has three or more finite
    /// points. A set without usable geometry produces no masks.
    public var hasUsableGeometry: Bool {
        let polygons = [faceContour, leftEye, rightEye, leftEyebrow,
                        rightEyebrow, nose, outerLips, innerLips]
        return polygons.contains { polygon in
            polygon.reduce(into: 0) { count, point in
                if point.x.isFinite, point.y.isFinite { count += 1 }
            } >= 3
        }
    }
}

// MARK: - Mask output

/// Soft semantic face masks produced by `FaceSemanticAnalyzer`.
///
/// Every non-`nil` mask has exactly the input image's `extent` and coordinate
/// system (bottom-left origin, same as `CIImage`). The matte is stored in the
/// RGB channels as a coverage value in `0...1` with alpha `1`; treat a mask as a
/// single-channel matte (`mask.red`) and multiply or blend the treatment by it.
///
/// Resolution: masks are computed on an internal raster whose longest edge is
/// `FaceSemanticAnalyzer.masks(..., maxDimension:)` (default 512, clamped to
/// 32...1024) and then scaled to the full image, so edges are soft at the raster
/// scale of a few pixels. They are intentionally low-resolution priors for
/// retouching, not per-pixel segmentation labels.
///
/// `nil` means the landmarks required for that mask were absent. A non-`nil`
/// mask can still be all zero: the geometry was available but no pixel matched
/// the colour evidence (for example a closed mouth contains no teeth pixels).
///
/// Degenerate input (a zero/NaN image extent, or landmarks without usable
/// geometry) safely returns an empty set; for a valid image extent the returned
/// `extent` is still the source extent with every mask `nil`.
///
/// Limitations: the colour rules are heuristics for common skin/teeth/sclera/
/// iris/lip/brow colours. Glasses, heavy makeup, deep occlusion, profile faces,
/// unusual white balance, grey/low-chroma irises and very small faces degrade or
/// remove individual masks. No face data is persisted and no identity is used.
public struct FaceSemanticMaskSet {
    /// Extent of the source image. Every non-`nil` mask matches it.
    public let extent: CGRect
    /// Pixel size of the internal matte raster before scaling to `extent`.
    public let resolution: CGSize
    /// Union of the processed face rectangles in normalized image coordinates.
    public let faceBounds: CGRect
    /// Lowest detector confidence among the faces that contributed geometry.
    public let confidence: Double
    /// Number of faces with usable landmark geometry that were merged in.
    public let faceCount: Int
    /// Face outline area that is skin-like, minus eyes, brows and lips.
    ///
    /// When a feature region is missing from the landmarks (profile face,
    /// occlusion, partial detection) its exclusion is simply skipped, so the
    /// skin matte may cover that part of the face. Callers should check the
    /// per-region masks they intend to protect before retouching.
    public let skin: CIImage?
    /// Bright, low-chroma pixels inside the inner lip polygon.
    public let teeth: CIImage?
    /// Bright, low-chroma pixels inside the eye polygons outside the iris disc.
    public let sclera: CIImage?
    /// Mid/low-lightness, higher-chroma pixels inside the iris disc.
    public let iris: CIImage?
    /// Reddish ring between the outer and inner lip polygons.
    public let lips: CIImage?
    /// Dark pixels inside the eyebrow polygons.
    public let brows: CIImage?

    /// True when no landmark region produced a mask at all.
    public var isEmpty: Bool {
        skin == nil && teeth == nil && sclera == nil && iris == nil
            && lips == nil && brows == nil
    }
}

// MARK: - Analyzer

/// Converts facial landmarks plus image colour into soft semantic masks.
///
/// Pipeline: rasterize the image to at most `maxDimension` on its longest edge in
/// extended linear sRGB, convert every raster pixel to CIELab (D65), build
/// polygon/disc regions from `FaceLandmarkSet`, gate the regions with simple
/// hue/lightness rules, feather the matte with a fixed-width Gaussian, then scale
/// it back to the input image extent.
///
/// The `landmarks`-based entry points never call Vision, which keeps them unit
/// testable with synthetic geometry. `detect(in:maxFaces:)` is the only Vision
/// path and returns an empty array for frames without a face (or when Vision is
/// unavailable), so callers must surface an explicit "no face" state instead of
/// assuming a detection failure is silent success.
///
/// Nothing in this type recognises identity, stores landmarks, or depends on a
/// model file: the rules are documented heuristics and their limitations are part
/// of the public contract above.
public enum FaceSemanticAnalyzer {
    /// Default longest edge of the internal matte raster.
    public static let defaultMaxDimension = 512
    /// Faces below this Vision confidence are ignored by `detect` and `masks`.
    public static let minimumConfidence: Double = 0.3

    private static let minimumRasterDimension = 32
    private static let maximumRasterDimension = 1024
    private static let visionLongestEdge = 1024
    private static let maximumFaces = 16
    /// Iris radius as a fraction of the eye polygon's bounding-box width.
    private static let irisRadiusToEyeWidth: CGFloat = 0.20

    private static let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let analysisContext = CIContext(options: [
        .workingColorSpace: linearColorSpace,
        .outputColorSpace: linearColorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: true,
        .cacheIntermediates: false
    ])

    // MARK: Public API

    /// Builds soft semantic masks for one face.
    ///
    /// - Parameters:
    ///   - image: Source image. The mask extent equals `image.extent`.
    ///   - faceBounds: Face rectangle in normalized bottom-left coordinates. When
    ///     it is not a valid, finite, non-empty rectangle the box is derived from
    ///     `landmarks` instead; it is recorded in the result and never skews the
    ///     landmark geometry (landmark points are already image-normalized).
    ///   - landmarks: Landmark geometry in normalized bottom-left coordinates.
    ///   - maxDimension: Longest edge of the internal raster, clamped to 32...1024.
    /// - Returns: The mask set; masks whose landmark regions are missing are `nil`
    ///   and low-confidence faces produce an empty set.
    public static func masks(image: CIImage,
                             faceBounds: CGRect,
                             landmarks: FaceLandmarkSet,
                             maxDimension: Int = defaultMaxDimension) -> FaceSemanticMaskSet {
        var face = landmarks
        if let resolved = sanitizedRect(faceBounds) { face.boundingBox = resolved }
        return makeMasks(image: image, faces: [face], maxDimension: maxDimension)
    }

    /// Builds the union of soft semantic masks for several faces.
    ///
    /// Masks from individual faces are combined with a per-pixel maximum, so the
    /// result is a matte that covers every detected face without double exposure
    /// where faces overlap. Face rectangles are unioned in `faceBounds` and the
    /// reported `confidence` is the lowest contributing confidence.
    public static func masks(in image: CIImage,
                             landmarks: [FaceLandmarkSet],
                             maxDimension: Int = defaultMaxDimension) -> FaceSemanticMaskSet {
        makeMasks(image: image, faces: landmarks, maxDimension: maxDimension)
    }

    /// Builds an array of soft semantic mask sets, one per detected face.
    ///
    /// Unlike `masks(in:landmarks:)` which unions all faces into a single composite matte,
    /// `perFaceMasks` keeps each face's skin, teeth, eyes, lips and brows strictly separated.
    /// This enables independent per-person demographic retouching and skin tone unification.
    public static func perFaceMasks(in image: CIImage,
                                    landmarks: [FaceLandmarkSet],
                                    maxDimension: Int = defaultMaxDimension) -> [FaceSemanticMaskSet] {
        makePerFaceMasks(image: image, faces: landmarks, maxDimension: maxDimension)
    }

    /// Estimates demographic role (female/bride, male/groom, child, elder, unassigned)
    /// using 100% local, private heuristics (facial geometry proportions + CIELab reflectance).
    public static func estimateDemographicRole(face: FaceLandmarkSet,
                                               in image: CIImage? = nil) -> PersonDemographicRole {
        computeDemographicRole(face: face, in: image)
    }

    /// Detects faces and converts Vision landmarks into normalized image points.
    ///
    /// The image is normalised to a zero-origin extent and downscaled so its
    /// longest edge is at most 1024 pixels before the request runs. Faces below
    /// `minimumConfidence` are filtered out and at most `maxFaces` (clamped to
    /// 0...16) are returned, ordered by descending confidence.
    ///
    /// Returns `[]` when the image is degenerate, no face is found, or the Vision
    /// request cannot run on this machine. Callers should treat `[]` as an
    /// explicit "no usable face" state and degrade visibly (disabling portrait
    /// controls) instead of silently continuing.
    public static func detect(in image: CIImage, maxFaces: Int = 8) -> [FaceLandmarkSet] {
        let limit = min(maximumFaces, max(0, maxFaces))
        guard limit > 0, let extent = sanitizedRect(image.extent) else { return [] }
        let normalized = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .cropped(to: CGRect(origin: .zero, size: extent.size))
        let scale = min(1, CGFloat(visionLongestEdge) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let rasterBounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let scaled = normalized
            .transformed(by: CGAffineTransform(scaleX: rasterBounds.width / extent.width,
                                               y: rasterBounds.height / extent.height))
            .cropped(to: rasterBounds)
        let request = VNDetectFaceLandmarksRequest()
        do {
            try VNImageRequestHandler(ciImage: scaled, options: [:]).perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }
        let size = rasterBounds.size
        let converted = observations.compactMap { observation -> FaceLandmarkSet? in
            guard observation.confidence.isFinite,
                  Double(observation.confidence) >= minimumConfidence,
                  let box = sanitizedRect(observation.boundingBox) else { return nil }
            let landmarks = observation.landmarks
            return FaceLandmarkSet(
                boundingBox: box,
                confidence: Double(observation.confidence),
                faceContour: normalizedRegion(landmarks?.faceContour, size: size),
                leftEye: normalizedRegion(landmarks?.leftEye, size: size),
                rightEye: normalizedRegion(landmarks?.rightEye, size: size),
                leftEyebrow: normalizedRegion(landmarks?.leftEyebrow, size: size),
                rightEyebrow: normalizedRegion(landmarks?.rightEyebrow, size: size),
                nose: normalizedRegion(landmarks?.nose, size: size),
                outerLips: normalizedRegion(landmarks?.outerLips, size: size),
                innerLips: normalizedRegion(landmarks?.innerLips, size: size),
                leftPupil: normalizedRegion(landmarks?.leftPupil, size: size).first,
                rightPupil: normalizedRegion(landmarks?.rightPupil, size: size).first
            )
        }
        let sorted = converted.sorted { left, right in
            if left.confidence != right.confidence { return left.confidence > right.confidence }
            if left.boundingBox.minX != right.boundingBox.minX {
                return left.boundingBox.minX < right.boundingBox.minX
            }
            return left.boundingBox.minY < right.boundingBox.minY
        }
        return Array(sorted.prefix(limit))
    }
}

// MARK: - Geometry

private struct FaceGeometry {
    let box: CGRect
    let confidence: Double
    let contour: [CGPoint]
    let eyes: [[CGPoint]]
    let pupils: [CGPoint?]
    let brows: [[CGPoint]]
    let outerLips: [CGPoint]
    let innerLips: [CGPoint]
}

private struct FaceColorWeights {
    let skin: [Float]
    let teeth: [Float]
    let sclera: [Float]
    let iris: [Float]
    let lips: [Float]
    let brows: [Float]
}

// MARK: - Implementation

private extension FaceSemanticAnalyzer {
    static func makeMasks(image: CIImage,
                          faces: [FaceLandmarkSet],
                          maxDimension: Int) -> FaceSemanticMaskSet {
        guard let extent = sanitizedRect(image.extent) else { return emptyMaskSet() }
        let limit = min(maximumRasterDimension, max(minimumRasterDimension, maxDimension))
        let scale = min(1, CGFloat(limit) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let resolution = CGSize(width: CGFloat(width), height: CGFloat(height))
        let geometries = Array(faces.prefix(maximumFaces)).compactMap { geometry(for: $0) }
        guard !geometries.isEmpty,
              let pixels = rasterize(image: image, extent: extent, width: width, height: height) else {
            return emptyMaskSet(extent: extent, resolution: resolution)
        }
        let colors = colorWeights(pixels: pixels, width: width, height: height)

        var skin: [Float]?
        var teeth: [Float]?
        var sclera: [Float]?
        var iris: [Float]?
        var lips: [Float]?
        var brows: [Float]?
        var mergedBounds = CGRect.null
        var mergedConfidence = 1.0

        for geometry in geometries {
            let layers = maskLayers(for: geometry, colors: colors, width: width, height: height)
            skin = maximum(skin, layers.skin)
            teeth = maximum(teeth, layers.teeth)
            sclera = maximum(sclera, layers.sclera)
            iris = maximum(iris, layers.iris)
            lips = maximum(lips, layers.lips)
            brows = maximum(brows, layers.brows)
            mergedBounds = mergedBounds.union(geometry.box)
            mergedConfidence = min(mergedConfidence, geometry.confidence)
        }

        return FaceSemanticMaskSet(
            extent: extent,
            resolution: resolution,
            faceBounds: mergedBounds.isNull ? .zero : mergedBounds,
            confidence: mergedConfidence,
            faceCount: geometries.count,
            skin: maskImage(skin, width: width, height: height, extent: extent),
            teeth: maskImage(teeth, width: width, height: height, extent: extent),
            sclera: maskImage(sclera, width: width, height: height, extent: extent),
            iris: maskImage(iris, width: width, height: height, extent: extent),
            lips: maskImage(lips, width: width, height: height, extent: extent),
            brows: maskImage(brows, width: width, height: height, extent: extent)
        )
    }

    static func makePerFaceMasks(image: CIImage,
                                 faces: [FaceLandmarkSet],
                                 maxDimension: Int) -> [FaceSemanticMaskSet] {
        guard let extent = sanitizedRect(image.extent) else { return [] }
        let limit = min(maximumRasterDimension, max(minimumRasterDimension, maxDimension))
        let scale = min(1, CGFloat(limit) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let resolution = CGSize(width: CGFloat(width), height: CGFloat(height))
        let geometries = Array(faces.prefix(maximumFaces)).compactMap { geometry(for: $0) }
        guard !geometries.isEmpty,
              let pixels = rasterize(image: image, extent: extent, width: width, height: height) else {
            return []
        }
        let colors = colorWeights(pixels: pixels, width: width, height: height)

        return geometries.map { geometry in
            let layers = maskLayers(for: geometry, colors: colors, width: width, height: height)
            return FaceSemanticMaskSet(
                extent: extent,
                resolution: resolution,
                faceBounds: geometry.box,
                confidence: geometry.confidence,
                faceCount: 1,
                skin: maskImage(layers.skin, width: width, height: height, extent: extent),
                teeth: maskImage(layers.teeth, width: width, height: height, extent: extent),
                sclera: maskImage(layers.sclera, width: width, height: height, extent: extent),
                iris: maskImage(layers.iris, width: width, height: height, extent: extent),
                lips: maskImage(layers.lips, width: width, height: height, extent: extent),
                brows: maskImage(layers.brows, width: width, height: height, extent: extent)
            )
        }
    }

    static func computeDemographicRole(face: FaceLandmarkSet, in image: CIImage?) -> PersonDemographicRole {
        // 1. Geometric proportions
        let chinY: CGFloat
        let topY: CGFloat
        if face.faceContour.count >= 3 {
            chinY = face.faceContour.map(\.y).min() ?? face.boundingBox.minY
            topY = face.faceContour.map(\.y).max() ?? face.boundingBox.maxY
        } else {
            chinY = face.boundingBox.minY
            topY = face.boundingBox.maxY
        }

        let eyePoints = face.leftEye + face.rightEye
        let eyeY: CGFloat
        if !eyePoints.isEmpty {
            eyeY = eyePoints.map(\.y).reduce(0, +) / CGFloat(eyePoints.count)
        } else if let pupil = face.leftPupil ?? face.rightPupil {
            eyeY = pupil.y
        } else {
            eyeY = face.boundingBox.midY
        }

        let totalHeight = max(CGFloat(0.001), topY - chinY)
        let lowerFaceRatio = (eyeY - chinY) / totalHeight
        // Infants and young children have round compact lower jaws and high cranial ratio
        if lowerFaceRatio < 0.42 {
            return .child
        }

        // 2. Optical reflectance & color analysis if image is provided
        guard let image, let extent = sanitizedRect(image.extent) else {
            return .unassigned
        }

        let box = sanitizedRect(face.boundingBox) ?? extent
        let sampleSize = 64
        guard let pixels = sampleFacePixels(image: image, faceBox: box, extent: extent, size: sampleSize) else {
            return .unassigned
        }

        func sampleRegion(minU: Double, maxU: Double, minV: Double, maxV: Double) -> (l: Float, a: Float, b: Float, count: Int, lVariance: Float) {
            var sumL: Float = 0
            var sumA: Float = 0
            var sumB: Float = 0
            var count = 0
            var lValues: [Float] = []
            let colStart = max(0, min(sampleSize - 1, Int(minU * Double(sampleSize))))
            let colEnd = max(0, min(sampleSize - 1, Int(maxU * Double(sampleSize))))
            let rowStart = max(0, min(sampleSize - 1, Int((1 - maxV) * Double(sampleSize))))
            let rowEnd = max(0, min(sampleSize - 1, Int((1 - minV) * Double(sampleSize))))

            guard colStart <= colEnd, rowStart <= rowEnd else { return (0, 0, 0, 0, 0) }

            for r in rowStart...rowEnd {
                for c in colStart...colEnd {
                    let offset = (r * sampleSize + c) * 4
                    let red = pixels[offset]
                    let green = pixels[offset + 1]
                    let blue = pixels[offset + 2]
                    let lab = labValue(red: red, green: green, blue: blue)
                    sumL += lab.lightness
                    sumA += lab.aStar
                    sumB += lab.bStar
                    lValues.append(lab.lightness)
                    count += 1
                }
            }
            guard count > 0 else { return (0, 0, 0, 0, 0) }
            let meanL = sumL / Float(count)
            let variance = lValues.reduce(0) { $0 + ($1 - meanL) * ($1 - meanL) } / Float(count)
            return (meanL, sumA / Float(count), sumB / Float(count), count, variance)
        }

        let lipBox = boundingBox(of: [face.outerLips])
        let lipMinU: Double
        let lipMaxU: Double
        let lipMinV: Double
        let lipMaxV: Double

        if let lb = lipBox, lb.width > 0, lb.height > 0 {
            lipMinU = max(0.1, min(0.9, Double((lb.minX - box.minX) / box.width)))
            lipMaxU = max(0.1, min(0.9, Double((lb.maxX - box.minX) / box.width)))
            lipMinV = max(0.05, min(0.9, Double((lb.minY - box.minY) / box.height)))
            lipMaxV = max(0.05, min(0.9, Double((lb.maxY - box.minY) / box.height)))
        } else {
            lipMinU = 0.35
            lipMaxU = 0.65
            lipMinV = 0.28
            lipMaxV = 0.40
        }

        // Chin (lower face, beard & stubble zone: below lips)
        let chinMaxV = max(0.05, lipMinV - 0.04)
        let chinMinV = max(0.01, chinMaxV - 0.18)
        let chinStats = sampleRegion(minU: 0.30, maxU: 0.70, minV: chinMinV, maxV: chinMaxV)

        // Cheeks (reference mid-face skin: to the left and right of lips/nose)
        let cheekMinV = lipMaxV
        let cheekMaxV = min(0.80, cheekMinV + 0.20)
        let leftCheek = sampleRegion(minU: max(0.05, lipMinU - 0.28), maxU: max(0.10, lipMinU - 0.05), minV: cheekMinV, maxV: cheekMaxV)
        let rightCheek = sampleRegion(minU: min(0.90, lipMaxU + 0.05), maxU: min(0.95, lipMaxU + 0.28), minV: cheekMinV, maxV: cheekMaxV)
        let cheekL = (leftCheek.l + rightCheek.l) * 0.5
        let cheekA = (leftCheek.a + rightCheek.a) * 0.5
        let cheekB = (leftCheek.b + rightCheek.b) * 0.5
        let cheekVariance = (leftCheek.lVariance + rightCheek.lVariance) * 0.5

        // Lips
        let lipStats = sampleRegion(minU: lipMinU, maxU: lipMaxU, minV: lipMinV, maxV: lipMaxV)

        // Forehead (for elder wrinkles and hairline)
        let foreheadStats = sampleRegion(minU: 0.30, maxU: 0.70, minV: 0.75, maxV: 0.90)

        guard chinStats.count > 0, (leftCheek.count > 0 || rightCheek.count > 0), lipStats.count > 0 else {
            return .unassigned
        }

        let lipRedness = lipStats.a - cheekA
        let stubbleDarkness = cheekL - chinStats.l
        let stubbleCoolness = cheekB - chinStats.b

        // Elder check: high variance in cheek nasolabial & forehead wrinkles + modest lightness
        if (cheekVariance > 65.0 || foreheadStats.lVariance > 60.0) && cheekL < 65.0 {
            return .elder
        }

        // Female check: strong red lip contrast OR smooth clean chin
        if lipRedness >= 6.0 {
            return .femaleAdult
        }

        // Male check: stubble shadow cools down yellow and darkens chin relative to cheek
        if stubbleDarkness > 2.0 || stubbleCoolness > 1.2 {
            return .maleAdult
        }

        // Soft fallback
        if lipRedness > 3.0 && stubbleDarkness < 1.0 {
            return .femaleAdult
        } else if stubbleDarkness > 0.8 || stubbleCoolness > 0.6 {
            return .maleAdult
        }

        return .unassigned
    }

    static func sampleFacePixels(image: CIImage,
                                 faceBox: CGRect,
                                 extent: CGRect,
                                 size: Int = 64) -> [Float]? {
        let pixelRect = CGRect(
            x: extent.minX + max(0, faceBox.minX) * extent.width,
            y: extent.minY + max(0, faceBox.minY) * extent.height,
            width: min(1, faceBox.width) * extent.width,
            height: min(1, faceBox.height) * extent.height
        )
        guard pixelRect.width > 2, pixelRect.height > 2 else { return nil }
        let cropped = image.cropped(to: pixelRect)
        let scaleX = CGFloat(size) / pixelRect.width
        let scaleY = CGFloat(size) / pixelRect.height
        let sampleBounds = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
        let scaled = cropped
            .transformed(by: CGAffineTransform(translationX: -pixelRect.minX, y: -pixelRect.minY))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: sampleBounds)

        var pixels = [Float](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            analysisContext.render(scaled, toBitmap: address,
                                   rowBytes: size * 4 * MemoryLayout<Float>.stride,
                                   bounds: sampleBounds, format: .RGBAf,
                                   colorSpace: linearColorSpace)
        }
        return pixels
    }

    struct FaceMaskLayers {
        let skin: [Float]?
        let teeth: [Float]?
        let sclera: [Float]?
        let iris: [Float]?
        let lips: [Float]?
        let brows: [Float]?
    }

    static func maskLayers(for geometry: FaceGeometry,
                           colors: FaceColorWeights,
                           width: Int,
                           height: Int) -> FaceMaskLayers {
        let eyeRegion: [Float]? = geometry.eyes.isEmpty
            ? nil : fillPolygons(geometry.eyes, width: width, height: height)
        var irisRegion: [Float]?
        if eyeRegion != nil {
            let discs = irisDiscs(eyes: geometry.eyes, pupils: geometry.pupils,
                                  width: width, height: height)
            if !discs.centers.isEmpty {
                irisRegion = fillDiscs(centers: discs.centers, radii: discs.radii,
                                       width: width, height: height)
            }
        }
        let browRegion: [Float]? = geometry.brows.isEmpty
            ? nil : fillPolygons(geometry.brows, width: width, height: height)
        let outerLipRegion: [Float]? = geometry.outerLips.count >= 3
            ? fillPolygons([geometry.outerLips], width: width, height: height) : nil
        let innerLipRegion: [Float]? = geometry.innerLips.count >= 3
            ? fillPolygons([geometry.innerLips], width: width, height: height) : nil

        var sclera: [Float]?
        var iris: [Float]?
        if let eyeRegion, let irisRegion {
            var scleraValues = eyeRegion
            var irisValues = eyeRegion
            for index in eyeRegion.indices where eyeRegion[index] > 0 {
                let outsideIris = 1 - irisRegion[index]
                scleraValues[index] = eyeRegion[index] * outsideIris * colors.sclera[index]
                irisValues[index] = eyeRegion[index] * irisRegion[index] * colors.iris[index]
            }
            sclera = scleraValues
            iris = irisValues
        }

        var lips: [Float]?
        if let outerLipRegion {
            var ring = outerLipRegion
            if let innerLipRegion {
                for index in ring.indices where ring[index] > 0 {
                    ring[index] = max(0, ring[index] - innerLipRegion[index])
                }
            }
            for index in ring.indices where ring[index] > 0 {
                ring[index] *= colors.lips[index]
            }
            lips = ring
        }

        var teeth: [Float]?
        if let innerLipRegion {
            var values = innerLipRegion
            for index in values.indices where values[index] > 0 {
                values[index] *= colors.teeth[index]
            }
            teeth = values
        }

        var brows: [Float]?
        if let browRegion {
            var values = browRegion
            for index in values.indices where values[index] > 0 {
                values[index] *= colors.brows[index]
            }
            brows = values
        }

        var skin: [Float]?
        if geometry.contour.count >= 3 {
            let contour = fillPolygons([geometry.contour], width: width, height: height)
            var values = contour
            for index in values.indices where contour[index] > 0 {
                // Excluded features must be cleared, not just skipped: `values`
                // starts as the contour fill and would otherwise keep a solid 1.
                if let eyeRegion, eyeRegion[index] > 0 { values[index] = 0; continue }
                if let browRegion, browRegion[index] > 0 { values[index] = 0; continue }
                if let outerLipRegion, outerLipRegion[index] > 0 { values[index] = 0; continue }
                values[index] = colors.skin[index]
            }
            skin = values
        }

        return FaceMaskLayers(skin: skin, teeth: teeth, sclera: sclera,
                              iris: iris, lips: lips, brows: brows)
    }

    static func geometry(for face: FaceLandmarkSet) -> FaceGeometry? {
        guard face.confidence.isFinite,
              face.confidence >= minimumConfidence else { return nil }
        let contour = sanitizedPoints(face.faceContour)
        var eyes: [[CGPoint]] = []
        var pupils: [CGPoint?] = []
        for (eye, pupil) in [(face.leftEye, face.leftPupil), (face.rightEye, face.rightPupil)] {
            let points = sanitizedPoints(eye)
            guard points.count >= 3 else { continue }
            eyes.append(points)
            pupils.append(pupil.flatMap { sanitizedPoint($0) })
        }
        var brows: [[CGPoint]] = []
        for brow in [face.leftEyebrow, face.rightEyebrow] {
            let points = sanitizedPoints(brow)
            if points.count >= 3 { brows.append(points) }
        }
        let outerLips = sanitizedPoints(face.outerLips)
        let innerLips = sanitizedPoints(face.innerLips)
        let usable = contour.count >= 3 || !eyes.isEmpty || !brows.isEmpty
            || outerLips.count >= 3 || innerLips.count >= 3
        guard usable else { return nil }
        let box = sanitizedRect(face.boundingBox)
            ?? boundingBox(of: [contour, outerLips, innerLips] + eyes + brows)
        guard let box else { return nil }
        return FaceGeometry(box: box, confidence: face.confidence,
                            contour: contour, eyes: eyes, pupils: pupils,
                            brows: brows, outerLips: outerLips, innerLips: innerLips)
    }

    static func rasterize(image: CIImage, extent: CGRect,
                          width: Int, height: Int) -> [Float]? {
        let rasterBounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let sample = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .cropped(to: CGRect(origin: .zero, size: extent.size))
            .transformed(by: CGAffineTransform(scaleX: rasterBounds.width / extent.width,
                                               y: rasterBounds.height / extent.height))
            .cropped(to: rasterBounds)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            analysisContext.render(sample, toBitmap: address,
                                   rowBytes: width * 4 * MemoryLayout<Float>.stride,
                                   bounds: rasterBounds, format: .RGBAf,
                                   colorSpace: linearColorSpace)
        }
        return pixels
    }

    static func maskImage(_ values: [Float]?, width: Int, height: Int,
                          extent: CGRect) -> CIImage? {
        guard let values, values.count == width * height, width > 0, height > 0 else { return nil }
        var rgba = [Float](repeating: 0, count: width * height * 4)
        for index in values.indices {
            let raw = values[index]
            let value = raw.isFinite ? min(1, max(0, raw)) : 0
            let offset = index * 4
            rgba[offset] = value
            rgba[offset + 1] = value
            rgba[offset + 2] = value
            rgba[offset + 3] = 1
        }
        let data = rgba.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        let bitmap = CIImage(bitmapData: data,
                             bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                             size: CGSize(width: CGFloat(width), height: CGFloat(height)),
                             format: .RGBAf, colorSpace: linearColorSpace)
        let feathered = forcingOpaque(
            gaussianBlurred(bitmap, radius: featherRadius(width: width, height: height))
                .cropped(to: bitmap.extent))
        let scale = CGAffineTransform(scaleX: extent.width / CGFloat(width),
                                      y: extent.height / CGFloat(height))
        return feathered
            .transformed(by: scale)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    static func gaussianBlurred(_ image: CIImage, radius: CGFloat) -> CIImage {
        guard radius > 0.05, let filter = CIFilter(name: "CIGaussianBlur") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return image }
        return output
    }

    /// Restores alpha to 1 after the Gaussian feather. `CIGaussianBlur` treats the
    /// area outside the raster as transparent, so image-border pixels would
    /// otherwise lose alpha; mattes are documented as opaque coverage in RGB.
    static func forcingOpaque(_ image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputAVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputBiasVector")
        return filter.outputImage ?? image
    }

    /// Feather width in raster pixels. Grows with the raster so the soft edge
    /// stays a few pixels wide at 512 and still exists at the 32-pixel floor.
    static func featherRadius(width: Int, height: Int) -> CGFloat {
        min(4, max(1, 0.0030 * CGFloat(max(width, height))))
    }

    static func emptyMaskSet(extent: CGRect = .zero,
                             resolution: CGSize = .zero) -> FaceSemanticMaskSet {
        FaceSemanticMaskSet(extent: extent, resolution: resolution, faceBounds: .zero,
                            confidence: 0, faceCount: 0, skin: nil, teeth: nil,
                            sclera: nil, iris: nil, lips: nil, brows: nil)
    }
}

// MARK: - Colour classification

private extension FaceSemanticAnalyzer {
    static func colorWeights(pixels: [Float], width: Int, height: Int) -> FaceColorWeights {
        let count = width * height
        var skin = [Float](repeating: 0, count: count)
        var teeth = [Float](repeating: 0, count: count)
        var sclera = [Float](repeating: 0, count: count)
        var iris = [Float](repeating: 0, count: count)
        var lips = [Float](repeating: 0, count: count)
        var brows = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let offset = index * 4
            let alpha = pixels[offset + 3]
            guard alpha.isFinite, alpha > 0.001 else { continue }
            let inverseAlpha = alpha < 1 ? 1 / alpha : 1
            let red = pixels[offset] * inverseAlpha
            let green = pixels[offset + 1] * inverseAlpha
            let blue = pixels[offset + 2] * inverseAlpha
            guard red.isFinite, green.isFinite, blue.isFinite else { continue }
            let lab = labValue(red: red, green: green, blue: blue)
            let lightness = lab.lightness
            let chroma = lab.chroma
            let aStar = lab.aStar
            let bStar = lab.bStar

            // Skin: broad CIELab prior for pale to deep tones (lightness range,
            // moderate warm chroma, positive a*/b*). Applied only inside the face
            // contour, so a skin-coloured background cannot leak in.
            let skinLightness = smoothstep(12, 22, lightness) * (1 - smoothstep(93, 98, lightness))
            let skinChroma = smoothstep(2.5, 6.5, chroma) * (1 - smoothstep(46, 58, chroma))
            let skinWarmth = smoothstep(0, 4, bStar) * (1 - smoothstep(38, 48, bStar))
            let skinRed = 1 - smoothstep(34, 46, aStar)
            skin[index] = skinLightness * skinChroma * skinWarmth * skinRed

            // Teeth: bright and nearly neutral inside the inner lip polygon.
            teeth[index] = smoothstep(60, 76, lightness) * (1 - smoothstep(11, 20, chroma))

            // Sclera: the brightest low-chroma part of the eye polygon.
            sclera[index] = smoothstep(64, 80, lightness) * (1 - smoothstep(8, 16, chroma))

            // Iris: mid/low lightness with clearly more chroma than the sclera.
            iris[index] = smoothstep(8, 18, chroma)
                * (1 - smoothstep(80, 92, lightness))
                * smoothstep(5, 12, lightness)

            // Lips: redness (a*) with bounded chroma/lightness, excluding the
            // very dark mouth interior so a closed mouth stays unmasked.
            lips[index] = smoothstep(7, 17, aStar)
                * (1 - smoothstep(52, 66, chroma))
                * (1 - smoothstep(84, 93, lightness))
                * smoothstep(4, 10, lightness)

            // Brows: dark hair/brow pixels inside the eyebrow polygons.
            brows[index] = (1 - smoothstep(40, 58, lightness)) * (1 - smoothstep(26, 36, chroma))
        }
        return FaceColorWeights(skin: skin, teeth: teeth, sclera: sclera,
                                iris: iris, lips: lips, brows: brows)
    }

    static func labValue(red: Float, green: Float, blue: Float) -> (lightness: Float, aStar: Float, bStar: Float, chroma: Float) {
        let r = Double(min(1, max(0, red)))
        let g = Double(min(1, max(0, green)))
        let b = Double(min(1, max(0, blue)))
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ value: Double) -> Double {
            value > 0.008856451679 ? pow(value, 1.0 / 3.0) : 7.787037 * value + 0.1379310345
        }
        let fx = f(max(x, 0))
        let fy = f(max(y, 0))
        let fz = f(max(z, 0))
        let lightness = 116 * fy - 16
        let aStar = 500 * (fx - fy)
        let bStar = 200 * (fy - fz)
        let chroma = sqrt(aStar * aStar + bStar * bStar)
        return (Float(lightness), Float(aStar), Float(bStar), Float(chroma))
    }

    static func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Raster geometry

private extension FaceSemanticAnalyzer {
    static func fillPolygons(_ polygons: [[CGPoint]], width: Int, height: Int) -> [Float] {
        var output = [Float](repeating: 0, count: width * height)
        for polygon in polygons {
            let points = sanitizedPoints(polygon)
            guard points.count >= 3 else { continue }
            var minimumX = points[0].x, maximumX = points[0].x
            var minimumY = points[0].y, maximumY = points[0].y
            for point in points {
                minimumX = min(minimumX, point.x)
                maximumX = max(maximumX, point.x)
                minimumY = min(minimumY, point.y)
                maximumY = max(maximumY, point.y)
            }
            let firstColumn = max(0, Int(floor(minimumX * CGFloat(width))))
            let lastColumn = min(width - 1, Int(ceil(maximumX * CGFloat(width))))
            let firstRow = max(0, Int(floor((1 - maximumY) * CGFloat(height))))
            let lastRow = min(height - 1, Int(ceil((1 - minimumY) * CGFloat(height))))
            guard firstColumn <= lastColumn, firstRow <= lastRow else { continue }
            for row in firstRow...lastRow {
                let pointY = 1 - (CGFloat(row) + 0.5) / CGFloat(height)
                for column in firstColumn...lastColumn {
                    let pointX = (CGFloat(column) + 0.5) / CGFloat(width)
                    if pointInside(CGPoint(x: pointX, y: pointY), polygon: points) {
                        output[row * width + column] = 1
                    }
                }
            }
        }
        return output
    }

    static func fillDiscs(centers: [CGPoint], radii: [CGFloat],
                          width: Int, height: Int) -> [Float] {
        var output = [Float](repeating: 0, count: width * height)
        for (index, center) in centers.enumerated() {
            guard index < radii.count,
                  center.x.isFinite, center.y.isFinite else { continue }
            let radius = max(0.5, radii[index])
            let centerX = center.x * CGFloat(width)
            let centerY = (1 - center.y) * CGFloat(height)
            let firstColumn = max(0, Int(floor(centerX - radius)))
            let lastColumn = min(width - 1, Int(ceil(centerX + radius)))
            let firstRow = max(0, Int(floor(centerY - radius)))
            let lastRow = min(height - 1, Int(ceil(centerY + radius)))
            guard firstColumn <= lastColumn, firstRow <= lastRow else { continue }
            for row in firstRow...lastRow {
                let dy = (CGFloat(row) + 0.5) - centerY
                for column in firstColumn...lastColumn {
                    let dx = (CGFloat(column) + 0.5) - centerX
                    if dx * dx + dy * dy <= radius * radius {
                        output[row * width + column] = 1
                    }
                }
            }
        }
        return output
    }

    static func irisDiscs(eyes: [[CGPoint]], pupils: [CGPoint?],
                          width: Int, height: Int) -> (centers: [CGPoint], radii: [CGFloat]) {
        var centers: [CGPoint] = []
        var radii: [CGFloat] = []
        for (index, eye) in eyes.enumerated() where eye.count >= 3 {
            let supplied = index < pupils.count ? pupils[index] : nil
            let center = supplied ?? centroid(of: eye)
            guard center.x.isFinite, center.y.isFinite else { continue }
            let box = boundingBox(of: [eye]) ?? .zero
            let eyeWidth = box.width * CGFloat(width)
            let radius = min(0.5 * CGFloat(max(width, height)),
                             max(1.5, irisRadiusToEyeWidth * eyeWidth))
            centers.append(center)
            radii.append(radius)
        }
        return (centers, radii)
    }

    static func pointInside(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var result = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            let denominator = previous.y - current.y
            let crosses = (current.y > point.y) != (previous.y > point.y)
                && point.x < (previous.x - current.x) * (point.y - current.y)
                    / (denominator == 0 ? 1e-12 : denominator) + current.x
            if crosses { result.toggle() }
            previous = current
        }
        return result
    }

    static func centroid(of points: [CGPoint]) -> CGPoint {
        let finite = points.filter { $0.x.isFinite && $0.y.isFinite }
        guard !finite.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let sum = finite.reduce(into: CGPoint.zero) { partial, point in
            partial.x += point.x
            partial.y += point.y
        }
        return CGPoint(x: sum.x / CGFloat(finite.count), y: sum.y / CGFloat(finite.count))
    }

    static func boundingBox(of polygons: [[CGPoint]]) -> CGRect? {
        var result = CGRect.null
        for polygon in polygons {
            for point in polygon where point.x.isFinite && point.y.isFinite {
                result = result.union(CGRect(x: point.x, y: point.y, width: 0, height: 0))
            }
        }
        return result.isNull ? nil : result
    }

    static func maximum(_ current: [Float]?, _ candidate: [Float]?) -> [Float]? {
        guard let candidate else { return current }
        guard var current else { return candidate }
        guard current.count == candidate.count else { return current }
        for index in current.indices {
            current[index] = max(current[index], candidate[index])
        }
        return current
    }
}

// MARK: - Small helpers

private extension FaceSemanticAnalyzer {
    static func sanitizedRect(_ rect: CGRect) -> CGRect? {
        guard rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    static func sanitizedPoint(_ point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    static func sanitizedPoints(_ points: [CGPoint]) -> [CGPoint] {
        points.filter { $0.x.isFinite && $0.y.isFinite }
    }

    static func normalizedRegion(_ region: VNFaceLandmarkRegion2D?,
                                 size: CGSize) -> [CGPoint] {
        guard let region, region.pointCount > 0,
              size.width > 0, size.height > 0 else { return [] }
        return region.pointsInImage(imageSize: size).compactMap { point in
            guard point.x.isFinite, point.y.isFinite else { return nil }
            return CGPoint(x: point.x / size.width, y: point.y / size.height)
        }
    }
}

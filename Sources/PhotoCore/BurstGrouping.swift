import CoreGraphics
import CoreImage
import Foundation

// MARK: - Input model

/// One photo candidate for burst / near-duplicate grouping.
///
/// Everything the grouper needs is plain data so callers can build candidates
/// from EXIF metadata and precomputed thumbnails without passing private photos
/// into the core:
/// - `captureTime` is the EXIF capture date (or an injected value for tests);
/// - `perceptualHash` is a 64-bit difference hash produced by
///   `BurstGrouping.perceptualHash(for:)` (or any compatible hash the caller
///   already computed);
/// - `quality` is the `QualityAnalyzer` report used to rank a group and pick the
///   recommended keep.
public struct BurstCandidate: Codable, Equatable, Identifiable {
    public var id: UUID
    /// Capture time; `nil` when EXIF is missing. Time-less candidates only group
    /// by perceptual-hash similarity (and otherwise stay singletons).
    public var captureTime: Date?
    /// 64-bit dHash of the thumbnail; `nil` when not computed.
    public var perceptualHash: UInt64?
    /// Precomputed quality report; `nil` candidates rank last within a group.
    public var quality: QualityReport?

    public init(id: UUID = UUID(),
                captureTime: Date? = nil,
                perceptualHash: UInt64? = nil,
                quality: QualityReport? = nil) {
        self.id = id
        self.captureTime = captureTime
        self.perceptualHash = perceptualHash
        self.quality = quality
    }
}

/// Tunable burst-grouping thresholds.
public struct BurstGroupingSettings: Codable, Equatable {
    /// Maximum capture-time gap (seconds) from the group anchor to join it.
    public var timeWindow: TimeInterval = 2.0
    /// Maximum Hamming distance (0...64) from the group anchor's dHash to join it.
    public var maximumHammingDistance: Int = 12
    /// How many top-ranked candidates per group are recommended to keep.
    public var recommendKeepCount: Int = 1

    public init() {}

    public func validate() throws {
        guard timeWindow.isFinite, (0...60).contains(timeWindow) else {
            throw AtelierError.invalidConfiguration("连拍时间窗必须在 0...60 秒之间。")
        }
        guard (0...64).contains(maximumHammingDistance) else {
            throw AtelierError.invalidConfiguration("感知哈希相似阈值必须在 0...64 之间。")
        }
        guard (0...16).contains(recommendKeepCount) else {
            throw AtelierError.invalidConfiguration("每组推荐保留数量必须在 0...16 之间。")
        }
    }
}

/// One burst / near-duplicate group, ranked best-first.
///
/// `recommendedKeepIDs` are the top `recommendKeepCount` ranked candidates; the
/// remaining ones are in `recommendedReviewIDs` (never silently deleted). Group
/// ordering is deterministic: by anchor capture time (time-less groups last),
/// then by the anchor id.
public struct BurstGroup: Codable, Equatable {
    /// Candidates ranked by quality (best first), ties broken by sharpness then id.
    public var candidates: [BurstCandidate]
    /// IDs recommended to keep (prefix of `candidates`).
    public var recommendedKeepIDs: [UUID]
    /// IDs that should be reviewed (remainder of `candidates`).
    public var recommendedReviewIDs: [UUID]

    public init(candidates: [BurstCandidate],
                recommendedKeepIDs: [UUID],
                recommendedReviewIDs: [UUID]) {
        self.candidates = candidates
        self.recommendedKeepIDs = recommendedKeepIDs
        self.recommendedReviewIDs = recommendedReviewIDs
    }

    /// Best candidate according to the ranking (nil for an empty group).
    public var recommendedCandidate: BurstCandidate? { candidates.first }

    /// True when the group is a burst / duplicate set rather than a singleton.
    public var isBurst: Bool { candidates.count > 1 }
}

// MARK: - Grouping

/// Deterministic burst grouping + dHash similarity.
///
/// Grouping algorithm (documented, heuristic v1):
/// 1. Candidates are sorted by `captureTime` (missing time last, then id).
/// 2. A candidate joins the current group only when both the capture-time gap
///    from the group **anchor** (first candidate) is within `timeWindow`
///    (when both times exist) **and** the dHash Hamming distance from the anchor
///    is within `maximumHammingDistance` (when both hashes exist).
/// 3. When only one signal is available it alone decides; with neither signal the
///    candidate starts a new group (never groups unrelated time-less photos).
/// 4. Each group is ranked by `QualityReport.overallScore`, then sharpness, then
///    id. The top `recommendKeepCount` become the recommended keep; the rest are
///    marked for review.
///
/// This is a local heuristic, not semantic burst detection: no face identity,
/// expression or scene understanding is used, and group membership should be
/// reviewed by a human before deleting anything.
public enum BurstGrouping {
    /// Groups candidates into bursts / near-duplicates and recommends keeps.
    public static func group(_ candidates: [BurstCandidate],
                             settings: BurstGroupingSettings = BurstGroupingSettings()) -> [BurstGroup] {
        guard !candidates.isEmpty else { return [] }
        // Never silently drop photos for an out-of-range tweak: clamp to the
        // documented ranges instead (UI validation rejects bad values up front).
        let effective = sanitized(settings)
        let sorted = candidates.sorted(by: candidateOrder)
        var rawGroups: [[BurstCandidate]] = []
        for candidate in sorted {
            if var current = rawGroups.last, canJoin(candidate, group: current, settings: effective) {
                current.append(candidate)
                rawGroups[rawGroups.count - 1] = current
            } else {
                rawGroups.append([candidate])
            }
        }
        let groups = rawGroups.map { makeGroup($0, settings: effective) }
        return groups.sorted(by: groupOrder)
    }

    /// Hamming distance between two 64-bit perceptual hashes.
    public static func hammingDistance(_ first: UInt64, _ second: UInt64) -> Int {
        (first ^ second).nonzeroBitCount
    }

    /// Computes a 64-bit difference hash (dHash) from a thumbnail image.
    ///
    /// The image is scaled to 9×8 and converted to display-referred luma; each of
    /// the 64 bits records whether the left pixel of a row is brighter than its
    /// right neighbour. The hash is scale-invariant, so callers may pass any
    /// thumbnail size and get comparable values.
    ///
    /// - Throws: `AtelierError.invalidConfiguration` for a degenerate extent.
    public static func perceptualHash(for image: CIImage,
                                      context: CIContext? = nil) throws -> UInt64 {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0.5, extent.height > 0.5 else {
            throw AtelierError.invalidConfiguration("感知哈希需要有限且非空的图像范围。")
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let working = context ?? defaultContext
        let translated = image.transformed(by: CGAffineTransform(translationX: -extent.minX,
                                                                 y: -extent.minY))
        let target = CGRect(x: 0, y: 0, width: 9, height: 8)
        let scaled = translated.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 9 / extent.width,
                                               y: 8 / extent.height))
            .cropped(to: target)
        var pixels = [UInt8](repeating: 0, count: 9 * 8 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            working.render(scaled, toBitmap: buffer.baseAddress!, rowBytes: 9 * 4,
                           bounds: target, format: .RGBA8, colorSpace: colorSpace)
        }
        var luma = [Double](repeating: 0, count: 9 * 8)
        for index in 0..<(9 * 8) {
            let offset = index * 4
            luma[index] = 0.2126 * Double(pixels[offset])
                + 0.7152 * Double(pixels[offset + 1])
                + 0.0722 * Double(pixels[offset + 2])
        }
        var hash: UInt64 = 0
        for row in 0..<8 {
            for column in 0..<8 {
                let left = luma[row * 9 + column]
                let right = luma[row * 9 + column + 1]
                if left > right {
                    hash |= (1 << UInt64(row * 8 + column))
                }
            }
        }
        return hash
    }

    // MARK: Internals

    /// Clamps settings into documented ranges (used when the caller bypasses
    /// `BurstGroupingSettings.validate()`), so grouping never drops photos.
    private static func sanitized(_ settings: BurstGroupingSettings) -> BurstGroupingSettings {
        var value = settings
        if !value.timeWindow.isFinite { value.timeWindow = 2 }
        value.timeWindow = min(60, max(0, value.timeWindow))
        value.maximumHammingDistance = min(64, max(0, value.maximumHammingDistance))
        value.recommendKeepCount = min(16, max(0, value.recommendKeepCount))
        return value
    }

    private static let defaultContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .workingFormat: CIFormat.RGBA8,
        .cacheIntermediates: false
    ])

    private static func candidateOrder(_ lhs: BurstCandidate, _ rhs: BurstCandidate) -> Bool {
        switch (lhs.captureTime, rhs.captureTime) {
        case let (left?, right?):
            if left != right { return left < right }
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case (nil, nil):
            break
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func canJoin(_ candidate: BurstCandidate,
                                group: [BurstCandidate],
                                settings: BurstGroupingSettings) -> Bool {
        guard let anchor = group.first else { return true }
        let timeMatches: Bool?
        switch (anchor.captureTime, candidate.captureTime) {
        case let (anchorTime?, candidateTime?):
            timeMatches = abs(candidateTime.timeIntervalSince(anchorTime)) <= settings.timeWindow
        default:
            timeMatches = nil
        }
        let hashMatches: Bool?
        if let anchorHash = anchor.perceptualHash, let candidateHash = candidate.perceptualHash {
            hashMatches = hammingDistance(anchorHash, candidateHash) <= settings.maximumHammingDistance
        } else {
            hashMatches = nil
        }
        switch (timeMatches, hashMatches) {
        case let (time?, hash?): return time && hash
        case let (time?, nil): return time
        case let (nil, hash?): return hash
        case (nil, nil): return false
        }
    }

    private static func makeGroup(_ candidates: [BurstCandidate],
                                  settings: BurstGroupingSettings) -> BurstGroup {
        let ranked = candidates.sorted(by: rankOrder)
        let keepCount = min(max(0, settings.recommendKeepCount), ranked.count)
        let keep = ranked.prefix(keepCount).map(\.id)
        let review = ranked.dropFirst(keepCount).map(\.id)
        return BurstGroup(candidates: ranked, recommendedKeepIDs: keep, recommendedReviewIDs: review)
    }

    private static func rankOrder(_ lhs: BurstCandidate, _ rhs: BurstCandidate) -> Bool {
        let lhsScore = normalizedOverall(lhs)
        let rhsScore = normalizedOverall(rhs)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        let lhsSharpness = normalizedSharpness(lhs)
        let rhsSharpness = normalizedSharpness(rhs)
        if lhsSharpness != rhsSharpness { return lhsSharpness > rhsSharpness }
        // Closed-eye reports are worse with an otherwise equal score.
        let lhsClosed = closedEyeCount(of: lhs), rhsClosed = closedEyeCount(of: rhs)
        if lhsClosed != rhsClosed { return lhsClosed < rhsClosed }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func normalizedOverall(_ candidate: BurstCandidate) -> Double {
        guard let score = candidate.quality?.overallScore, score.isFinite else { return 0 }
        return min(1, max(0, score))
    }

    private static func normalizedSharpness(_ candidate: BurstCandidate) -> Double {
        guard let score = candidate.quality?.sharpnessScore, score.isFinite else { return 0 }
        return min(1, max(0, score))
    }

    private static func closedEyeCount(of candidate: BurstCandidate) -> Int {
        max(0, candidate.quality?.closedEyeCount ?? 0)
    }

    private static func groupOrder(_ lhs: BurstGroup, _ rhs: BurstGroup) -> Bool {
        let lhsTime = lhs.candidates.first?.captureTime
        let rhsTime = rhs.candidates.first?.captureTime
        switch (lhsTime, rhsTime) {
        case let (left?, right?):
            if left != right { return left < right }
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case (nil, nil):
            break
        }
        let lhsID = lhs.candidates.first?.id.uuidString ?? ""
        let rhsID = rhs.candidates.first?.id.uuidString ?? ""
        return lhsID < rhsID
    }
}

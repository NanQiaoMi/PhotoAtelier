import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

/// Synthetic-fixture tests for the P1-C heuristic burst grouping.
///
/// Capture times, perceptual hashes and quality reports are injected directly, so
/// grouping logic is tested without real photos. Hash fixtures are coarse synthetic
/// patterns (checkerboard / stripes at 1/4-image scale): the dHash only captures
/// low-frequency gradient direction, so fine-grained checkerboards and smooth
/// monotonic gradients are intentionally not used as "different scene" fixtures.
final class BurstGroupingTests: XCTestCase {
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    private func makeImage(width: Int, height: Int,
                           pixel: (Int, Int) -> (Double, Double, Double)) -> CIImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue) = pixel(x, y)
                context.setFillColor(CGColor(colorSpace: colorSpace,
                                             components: [red, green, blue, 1])!)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return CIImage(cgImage: context.makeImage()!)
    }

    private func coarseChecker() -> CIImage {
        makeImage(width: 256, height: 192) { x, y in
            let value = ((x / 64) + (y / 48)) % 2 == 0 ? 0.9 : 0.1
            return (value, value, value)
        }
    }

    private func verticalStripes() -> CIImage {
        makeImage(width: 256, height: 192) { x, _ in
            let value = (x / 64) % 2 == 0 ? 0.9 : 0.1
            return (value, value, value)
        }
    }

    private func horizontalStripes() -> CIImage {
        makeImage(width: 256, height: 192) { _, y in
            let value = (y / 48) % 2 == 0 ? 0.9 : 0.1
            return (value, value, value)
        }
    }

    private func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private func quality(overall: Double,
                         sharpness: Double = 0.5,
                         closedEyes: Int = 0) -> QualityReport {
        QualityReport(faceCount: closedEyes > 0 ? 1 : 0,
                      eyeCount: closedEyes > 0 ? 2 : 0,
                      closedEyeCount: closedEyes,
                      sharpnessScore: sharpness,
                      exposureScore: 0.9,
                      overallScore: overall,
                      recommendation: .review,
                      reasons: ["fixture"])
    }

    private func candidate(_ suffix: Int,
                           timeOffset: TimeInterval? = 0,
                           hash: UInt64? = 0xABCD_0000_0000_1234,
                           overall: Double = 0.5,
                           sharpness: Double = 0.5,
                           closedEyes: Int = 0) -> BurstCandidate {
        BurstCandidate(id: id(suffix),
                       captureTime: timeOffset.map { baseTime.addingTimeInterval($0) },
                       perceptualHash: hash,
                       quality: quality(overall: overall, sharpness: sharpness,
                                        closedEyes: closedEyes))
    }

    // MARK: - Grouping

    func testGroupsBurstShotsByTimeWindowAndSplitsFarShots() {
        let candidates = [
            candidate(1, timeOffset: 0.0),
            candidate(2, timeOffset: 0.4),
            candidate(3, timeOffset: 0.8),
            candidate(4, timeOffset: 10.0),
            candidate(5, timeOffset: 10.5)
        ]
        let groups = BurstGrouping.group(candidates)
        XCTAssertEqual(groups.count, 2, "2 秒时间窗应把 0/0.4/0.8 秒归为一组，10 秒后另起一组")
        XCTAssertEqual(groups[0].candidates.count, 3)
        XCTAssertEqual(groups[1].candidates.count, 2)
        XCTAssertTrue(groups[0].isBurst)
        XCTAssertTrue(groups.allSatisfy { $0.candidates.count <= 3 })
        XCTAssertLessThan(groups[0].candidates.first!.captureTime!,
                          groups[1].candidates.first!.captureTime!)
    }

    func testDifferentSceneHashWithinTimeWindowSplits() {
        let groups = BurstGrouping.group([
            candidate(1, timeOffset: 0.0, hash: 0x0000_0000_0000_0000),
            candidate(2, timeOffset: 0.2, hash: 0xFFFF_FFFF_FFFF_FFFF)
        ])
        XCTAssertEqual(groups.count, 2,
                       "同一时间窗内哈希距离 64 的两张图必须分组（不同场景）")
        XCTAssertEqual(groups[0].candidates.count, 1)
        XCTAssertEqual(groups[1].candidates.count, 1)
    }

    func testNilCaptureTimeFallsBackToHashOrSingletons() {
        // Time-less duplicates with the same hash form one group.
        let duplicate = BurstGrouping.group([
            candidate(1, timeOffset: nil, hash: 0x1111_1111_1111_1111),
            candidate(2, timeOffset: nil, hash: 0x1111_1111_1111_1111)
        ])
        XCTAssertEqual(duplicate.count, 1)
        XCTAssertEqual(duplicate[0].candidates.count, 2)

        // Time-less candidates with different hashes stay separate.
        let different = BurstGrouping.group([
            candidate(3, timeOffset: nil, hash: 0x0000_0000_0000_0000),
            candidate(4, timeOffset: nil, hash: 0xFFFF_FFFF_FFFF_FFFF)
        ])
        XCTAssertEqual(different.count, 2)

        // No time and no hash: never group two unrelated candidates.
        let blind = BurstGrouping.group([
            candidate(5, timeOffset: nil, hash: nil),
            candidate(6, timeOffset: nil, hash: nil)
        ])
        XCTAssertEqual(blind.count, 2)
        XCTAssertEqual(blind[0].candidates.count, 1)
        XCTAssertEqual(blind[1].candidates.count, 1)

        // One dated + one time-less with matching hash: hash similarity is enough.
        let mixed = BurstGrouping.group([
            candidate(7, timeOffset: 0.0, hash: 0x2222_2222_2222_2222),
            candidate(8, timeOffset: nil, hash: 0x2222_2222_2222_2222)
        ])
        XCTAssertEqual(mixed.count, 1)
        XCTAssertEqual(mixed[0].candidates.count, 2)
    }

    func testGroupRankingAndRecommendations() {
        let worst = candidate(1, timeOffset: 0.0, overall: 0.40, sharpness: 0.4, closedEyes: 2)
        let mid = candidate(2, timeOffset: 0.3, overall: 0.80, sharpness: 0.7)
        let best = candidate(3, timeOffset: 0.6, overall: 0.90, sharpness: 0.9)
        let groups = BurstGrouping.group([worst, mid, best])
        XCTAssertEqual(groups.count, 1)
        let group = groups[0]
        XCTAssertEqual(group.candidates.map(\.id), [best.id, mid.id, worst.id],
                       "组内应按综合分/锐度从高到低排序")
        XCTAssertEqual(group.recommendedCandidate?.id, best.id)
        XCTAssertEqual(group.recommendedKeepIDs, [best.id], "默认每组推荐保留 1 张（最优）")
        XCTAssertEqual(group.recommendedReviewIDs, [mid.id, worst.id],
                       "其余照片进入待复核，不能被静默丢弃")

        var keepTwo = BurstGroupingSettings()
        keepTwo.recommendKeepCount = 2
        let keepTwoGroup = BurstGrouping.group([worst, mid, best], settings: keepTwo)[0]
        XCTAssertEqual(keepTwoGroup.recommendedKeepIDs, [best.id, mid.id])
        XCTAssertEqual(keepTwoGroup.recommendedReviewIDs, [worst.id])
    }

    func testClosedEyesBreakScoreTies() {
        let closed = candidate(1, timeOffset: 0.0, overall: 0.90, sharpness: 0.90, closedEyes: 2)
        let open = candidate(2, timeOffset: 0.3, overall: 0.90, sharpness: 0.90)
        let group = BurstGrouping.group([closed, open])[0]
        XCTAssertEqual(group.candidates.first?.id, open.id,
                       "同分时闭眼照片应排在睁眼照片之后")
    }

    func testEmptyInputAndDeterminism() {
        XCTAssertTrue(BurstGrouping.group([]).isEmpty)
        let candidates = [candidate(1), candidate(2, timeOffset: 0.2),
                          candidate(3, timeOffset: 0.4, overall: 0.9)]
        let first = BurstGrouping.group(candidates)
        let second = BurstGrouping.group(candidates)
        XCTAssertEqual(first, second, "相同输入必须得到相同分组与推荐顺序")
    }

    func testNaNQualityScoresAreClampedAndRankedDeterministically() {
        let nan = burstCandidateWithDate(1, overall: .nan, sharpness: .nan)
        let high = burstCandidateWithDate(2, overall: 5.0, sharpness: 5.0)
        let negative = burstCandidateWithDate(3, overall: -3.0, sharpness: -3.0)
        let group = BurstGrouping.group([nan, high, negative])[0]
        XCTAssertEqual(group.candidates.first?.id, high.id,
                       "超出 0...1 的评分必须被钳制且不崩溃")
        XCTAssertEqual(group.recommendedKeepIDs, [high.id])
        XCTAssertEqual(group.recommendedReviewIDs.count, 2)
    }

    private func burstCandidateWithDate(_ suffix: Int, overall: Double,
                                        sharpness: Double) -> BurstCandidate {
        BurstCandidate(id: id(suffix),
                       captureTime: baseTime.addingTimeInterval(Double(suffix) * 0.1),
                       perceptualHash: 0x3333_3333_3333_3333,
                       quality: QualityReport(sharpnessScore: sharpness,
                                              exposureScore: 0.9,
                                              overallScore: overall,
                                              recommendation: .review))
    }

    // MARK: - Perceptual hash

    func testHammingDistanceBasics() {
        XCTAssertEqual(BurstGrouping.hammingDistance(0, 0), 0)
        XCTAssertEqual(BurstGrouping.hammingDistance(0, 1), 1)
        XCTAssertEqual(BurstGrouping.hammingDistance(0, .max), 64)
        XCTAssertEqual(BurstGrouping.hammingDistance(0xAAAA_AAAA_AAAA_AAAA,
                                                     0x5555_5555_5555_5555), 64)
    }

    func testPerceptualHashIsDeterministicAndSimilarForBlur() throws {
        let checker = coarseChecker()
        let first = try BurstGrouping.perceptualHash(for: checker)
        let second = try BurstGrouping.perceptualHash(for: checker)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, 0, "粗尺度棋盘必须有非零 dHash")

        let blurred = checker.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 8])
            .cropped(to: checker.extent)
        let blurredHash = try BurstGrouping.perceptualHash(for: blurred)
        let distance = BurstGrouping.hammingDistance(first, blurredHash)
        XCTAssertLessThanOrEqual(distance, 12,
                                 "同场景轻微模糊的 dHash 距离应很小（实际 \(distance)）")
    }

    func testPerceptualHashSeparatesDifferentScenes() throws {
        let vertical = try BurstGrouping.perceptualHash(for: verticalStripes())
        let horizontal = try BurstGrouping.perceptualHash(for: horizontalStripes())
        let distance = BurstGrouping.hammingDistance(vertical, horizontal)
        XCTAssertGreaterThan(distance, 12,
                             "不同构图（竖条纹 vs 横条纹）的 dHash 距离应超过默认阈值（实际 \(distance)）")
    }

    func testPerceptualHashRejectsDegenerateExtent() {
        let empty = CIImage(color: .clear).cropped(to: .zero)
        XCTAssertThrowsError(try BurstGrouping.perceptualHash(for: empty))
    }

    // MARK: - Settings

    func testSettingsValidationRejectsOutOfRangeValues() {
        var badWindow = BurstGroupingSettings()
        badWindow.timeWindow = -1
        XCTAssertThrowsError(try badWindow.validate())

        var badHamming = BurstGroupingSettings()
        badHamming.maximumHammingDistance = 65
        XCTAssertThrowsError(try badHamming.validate())

        var badKeep = BurstGroupingSettings()
        badKeep.recommendKeepCount = 17
        XCTAssertThrowsError(try badKeep.validate())

        var nanWindow = BurstGroupingSettings()
        nanWindow.timeWindow = Double.nan
        XCTAssertThrowsError(try nanWindow.validate())

        XCTAssertNoThrow(try BurstGroupingSettings().validate())
    }

    func testInvalidSettingsAreClampedInsteadOfDroppingPhotos() {
        var zeroWindow = BurstGroupingSettings()
        zeroWindow.timeWindow = -5
        let groups = BurstGrouping.group([
            candidate(1, timeOffset: 0.0),
            candidate(2, timeOffset: 0.0)
        ], settings: zeroWindow)
        XCTAssertEqual(groups.count, 1, "非法时间窗应被钳制为 0 而不是丢弃全部照片")
        XCTAssertEqual(groups[0].candidates.count, 2)

        var hugeKeep = BurstGroupingSettings()
        hugeKeep.recommendKeepCount = 99
        let keepAll = BurstGrouping.group([
            candidate(1, timeOffset: 0.0),
            candidate(2, timeOffset: 0.1)
        ], settings: hugeKeep)[0]
        XCTAssertEqual(keepAll.recommendedKeepIDs.count, 2,
                       "推荐数量超过组大小时应按组大小截断")
        XCTAssertTrue(keepAll.recommendedReviewIDs.isEmpty)
    }
}

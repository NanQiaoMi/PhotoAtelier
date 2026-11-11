import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoCore

final class ReferenceColorMatchTests: XCTestCase {
    private let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: colorSpace,
        .outputColorSpace: colorSpace,
        .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: false,
        .cacheIntermediates: false
    ])

    // MARK: - Profile contract

    func testProfileRecordsVersionAndMonotoneQuantilesAndRoundTrips() throws {
        let reference = gradient(width: 48, height: 32) { x, y in
            let t = Float(x) / 47
            let u = Float(y) / 31
            return (0.20 + 0.55 * t, 0.24 + 0.40 * u, 0.60 - 0.30 * t)
        }
        let profile = try ReferenceColorMatcher.profile(reference: reference)

        XCTAssertEqual(profile.algorithmVersion, ReferenceColorProfile.currentAlgorithmVersion)
        XCTAssertEqual(profile.algorithmVersion, 1)
        XCTAssertEqual(profile.quantileCount, ReferenceColorProfile.quantileCount)
        XCTAssertEqual(profile.quantileCount, 17)
        XCTAssertEqual(profile.luminanceQuantiles.count, 17)
        XCTAssertEqual(profile.aQuantiles.count, 17)
        XCTAssertEqual(profile.bQuantiles.count, 17)
        XCTAssertGreaterThan(profile.sampleCount, 0)
        XCTAssertLessThanOrEqual(profile.sampleCount, ReferenceColorMatcher.defaultSampleLimit)
        XCTAssertTrue([profile.meanL, profile.meanA, profile.meanB].allSatisfy(\.isFinite))
        for channel in [profile.luminanceQuantiles, profile.aQuantiles, profile.bQuantiles] {
            XCTAssertEqual(channel, channel.sorted(), "分位数必须单调非降")
            XCTAssertTrue(channel.allSatisfy(\.isFinite))
        }
        XCTAssertNoThrow(try profile.validate())

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ReferenceColorProfile.self, from: data)
        XCTAssertEqual(decoded, profile, "profile 必须可 Codable 往返")
        XCTAssertNoThrow(try decoded.validate())
    }

    func testSampleLimitBoundsTheSampleCount() throws {
        let reference = gradient(width: 512, height: 512) { x, y in
            let t = Float(x + y) / 1022
            return (t, t * 0.8, 1 - t)
        }
        let profile = try ReferenceColorMatcher.profile(reference: reference, sampleLimit: 256)
        XCTAssertGreaterThan(profile.sampleCount, 0)
        XCTAssertLessThanOrEqual(profile.sampleCount, 256)
        XCTAssertEqual(profile.sampleCount, 256, "512×512 缩到 16×16 应采样 256 像素")
    }

    // MARK: - Identity and strength

    func testSameImageMatchIsApproximatelyIdentity() throws {
        let reference = gradient(width: 64, height: 48) { x, y in
            let t = Float(x) / 63
            let u = Float(y) / 47
            // Multi-hue content so the test is not a single neutral ramp.
            return (0.08 + 0.80 * t, 0.10 + 0.62 * u, 0.12 + 0.70 * (1 - t) * u)
        }
        let profile = try ReferenceColorMatcher.profile(reference: reference)
        let matched = try ReferenceColorMatcher.apply(profile, to: reference, strength: 1)

        XCTAssertEqual(matched.extent, reference.extent)
        let before = render(reference, width: 64, height: 48)
        let after = render(matched, width: 64, height: 48)
        var totalDelta = 0.0
        var maximumDelta = 0.0
        var opaquePixels = 0
        for offset in stride(from: 0, to: before.count, by: 4) {
            let alpha = before[offset + 3]
            XCTAssertEqual(after[offset + 3], alpha, accuracy: 0.000001)
            guard alpha > 0.5 else { continue }
            let delta = deltaE(oklab(before, offset), oklab(after, offset))
            totalDelta += delta
            maximumDelta = max(maximumDelta, delta)
            opaquePixels += 1
        }
        XCTAssertGreaterThan(opaquePixels, 0)
        let meanDelta = totalDelta / Double(opaquePixels)
        XCTAssertLessThan(meanDelta, 0.005, "同图追色应近似恒等（平均 ΔE OKLab）")
        XCTAssertLessThan(maximumDelta, 0.05, "同图追色逐像素误差应有限")
    }

    func testZeroStrengthReturnsTheIdenticalImageObject() throws {
        let reference = gradient(width: 32, height: 32) { x, y in
            (Float(x) / 31, Float(y) / 31, 0.5)
        }
        let profile = try ReferenceColorMatcher.profile(reference: reference)
        let zero = try ReferenceColorMatcher.apply(profile, to: reference, strength: 0)
        XCTAssertTrue(zero === reference, "strength=0 必须返回同一 CIImage 对象，不强制渲染")
    }

    func testStrengthAboveOneClampsToFullStrength() throws {
        let reference = gradient(width: 40, height: 40) { x, _ in
            (0.15 + Float(x) / 39 * 0.5, 0.30, 0.55)
        }
        let candidate = gradient(width: 40, height: 40) { x, _ in
            (0.60, 0.30 + Float(x) / 39 * 0.3, 0.20)
        }
        let profile = try ReferenceColorMatcher.profile(reference: reference)
        let full = try ReferenceColorMatcher.apply(profile, to: candidate, strength: 1)
        let clamped = try ReferenceColorMatcher.apply(profile, to: candidate, strength: 4)
        XCTAssertEqual(render(full, width: 40, height: 40),
                       render(clamped, width: 40, height: 40),
                       "strength > 1 应夹取到 1")
    }

    func testHalfStrengthMovesPartWayTowardTheReference() throws {
        let reference = coolGradient(width: 48, height: 48)
        let candidate = warmGradient(width: 48, height: 48)
        let profile = try ReferenceColorMatcher.profile(reference: reference)
        let half = try ReferenceColorMatcher.apply(profile, to: candidate, strength: 0.5)
        let full = try ReferenceColorMatcher.apply(profile, to: candidate, strength: 1)

        let candidateLab = try ReferenceColorMatcher.profile(reference: candidate)
        let halfLab = try ReferenceColorMatcher.profile(reference: half)
        let fullLab = try ReferenceColorMatcher.profile(reference: full)
        let before = chromaDistance(candidateLab, profile)
        let halfDistance = chromaDistance(halfLab, profile)
        let fullDistance = chromaDistance(fullLab, profile)
        XCTAssertGreaterThan(before, 0.02, "合成图必须有可测的冷暖偏移")
        XCTAssertLessThan(fullDistance, before * 0.5, "全强度应向参考色度收敛")
        XCTAssertGreaterThan(halfDistance, fullDistance, "半强度应介于原图与全强度之间")
        XCTAssertLessThan(halfDistance, before, "半强度应比原图更接近参考")
    }

    // MARK: - Convergence

    func testWarmCandidateConvergesTowardCoolReference() throws {
        let reference = coolGradient(width: 64, height: 48)
        let candidate = warmGradient(width: 64, height: 48)
        let referenceProfile = try ReferenceColorMatcher.profile(reference: reference)
        let candidateProfile = try ReferenceColorMatcher.profile(reference: candidate)
        let matched = try ReferenceColorMatcher.apply(referenceProfile, to: candidate, strength: 1)
        let matchedProfile = try ReferenceColorMatcher.profile(reference: matched)

        let before = chromaDistance(candidateProfile, referenceProfile)
        let after = chromaDistance(matchedProfile, referenceProfile)
        XCTAssertGreaterThan(before, 0.03, "候选图相对参考必须有明显冷暖偏移")
        XCTAssertLessThan(after, before * 0.5,
                          "追色后 OKLab a/b 均值距离应至少减半（前 \(before) 后 \(after)）")
    }

    func testCoolCandidateConvergesTowardWarmReference() throws {
        let reference = warmGradient(width: 64, height: 48)
        let candidate = coolGradient(width: 64, height: 48)
        let referenceProfile = try ReferenceColorMatcher.profile(reference: reference)
        let candidateProfile = try ReferenceColorMatcher.profile(reference: candidate)
        let matched = try ReferenceColorMatcher.apply(referenceProfile, to: candidate, strength: 1)
        let matchedProfile = try ReferenceColorMatcher.profile(reference: matched)

        let before = chromaDistance(candidateProfile, referenceProfile)
        let after = chromaDistance(matchedProfile, referenceProfile)
        XCTAssertGreaterThan(before, 0.03)
        XCTAssertLessThan(after, before * 0.5)
    }

    func testExtremeReferencesStayFiniteAndBounded() throws {
        let candidate = warmGradient(width: 48, height: 32)
        let candidateMeanL = try ReferenceColorMatcher.profile(reference: candidate).meanL
        let references: [(name: String, image: CIImage, samples: Int)] = [
            ("纯黑", solid(0, 0, 0, width: 24, height: 24), 24 * 24),
            ("纯白", solid(1, 1, 1, width: 24, height: 24), 24 * 24),
            ("纯红", solid(0.9, 0.02, 0.02, width: 24, height: 24), 24 * 24),
            ("单像素", solid(0.4, 0.7, 0.2, width: 1, height: 1), 1)
        ]
        for reference in references {
            let profile = try ReferenceColorMatcher.profile(reference: reference.image)
            XCTAssertEqual(profile.sampleCount, reference.samples, reference.name)
            let matched = try ReferenceColorMatcher.apply(profile, to: candidate, strength: 1)
            let pixels = render(matched, width: 48, height: 32)
            XCTAssertTrue(pixels.allSatisfy { $0.isFinite }, "\(reference.name) 参考不得产生 NaN/Inf")
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                XCTAssertGreaterThanOrEqual(pixels[offset], 0, reference.name)
                XCTAssertLessThanOrEqual(pixels[offset], 1, reference.name)
                XCTAssertGreaterThanOrEqual(pixels[offset + 1], 0, reference.name)
                XCTAssertLessThanOrEqual(pixels[offset + 1], 1, reference.name)
                XCTAssertGreaterThanOrEqual(pixels[offset + 2], 0, reference.name)
                XCTAssertLessThanOrEqual(pixels[offset + 2], 1, reference.name)
                XCTAssertEqual(pixels[offset + 3], 1, accuracy: 0.000001, reference.name)
            }
        }

        let blackProfile = try ReferenceColorMatcher.profile(
            reference: solid(0, 0, 0, width: 16, height: 16))
        let darkened = try ReferenceColorMatcher.profile(
            reference: try ReferenceColorMatcher.apply(blackProfile, to: candidate, strength: 1))
        XCTAssertLessThan(darkened.meanL, candidateMeanL - 0.02, "纯黑参考应压暗明度")

        let whiteProfile = try ReferenceColorMatcher.profile(
            reference: solid(1, 1, 1, width: 16, height: 16))
        let brightened = try ReferenceColorMatcher.profile(
            reference: try ReferenceColorMatcher.apply(whiteProfile, to: candidate, strength: 1))
        XCTAssertGreaterThan(brightened.meanL, candidateMeanL + 0.02, "纯白参考应提亮明度")
    }

    func testFlatCandidateWithDetailedReferenceStaysFinite() throws {
        let reference = coolGradient(width: 48, height: 32)
        let flat = solid(0.35, 0.35, 0.35, width: 32, height: 24)
        let profile = try ReferenceColorMatcher.profile(reference: reference)
        let matched = try ReferenceColorMatcher.apply(profile, to: flat, strength: 1)
        let pixels = render(matched, width: 32, height: 24)
        XCTAssertTrue(pixels.allSatisfy { $0.isFinite })
        // A flat candidate has degenerate per-channel quantiles; the transfer
        // maps it to the reference median instead of dividing by zero.
        let first = Array(pixels[0..<3])
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            XCTAssertEqual(pixels[offset], first[0], accuracy: 0.000001)
            XCTAssertEqual(pixels[offset + 1], first[1], accuracy: 0.000001)
            XCTAssertEqual(pixels[offset + 2], first[2], accuracy: 0.000001)
        }
    }

    // MARK: - Determinism

    func testSameInputProducesSameOutput() throws {
        let reference = gradient(width: 40, height: 32) { x, y in
            (0.2 + Float(x) / 39 * 0.6, 0.3 + Float(y) / 31 * 0.4, 0.5)
        }
        let candidate = gradient(width: 40, height: 32) { x, y in
            (0.55, 0.35 + Float(y) / 31 * 0.3, 0.2 + Float(x) / 39 * 0.2)
        }
        let firstProfile = try ReferenceColorMatcher.profile(reference: reference)
        let secondProfile = try ReferenceColorMatcher.profile(reference: reference)
        XCTAssertEqual(firstProfile, secondProfile, "同一参考图两次测量必须完全一致")

        let firstOutput = try ReferenceColorMatcher.apply(firstProfile, to: candidate, strength: 0.8)
        let secondOutput = try ReferenceColorMatcher.apply(firstProfile, to: candidate, strength: 0.8)
        XCTAssertEqual(render(firstOutput, width: 40, height: 32),
                       render(secondOutput, width: 40, height: 32),
                       "同一输入两次追色必须逐像素一致")
    }

    // MARK: - Alpha and extent

    func testTransparentPixelsAndAlphaArePreserved() throws {
        let reference = gradient(width: 48, height: 32) { x, _ in
            (0.25 + Float(x) / 47 * 0.5, 0.4, 0.7)
        }
        let profile = try ReferenceColorMatcher.profile(reference: reference)
        let origin = CGPoint(x: -9, y: 14)
        let candidate = makeImage(width: 48, height: 32, origin: origin) { x, _ in
            switch x {
            case ..<16: return (0.6, 0.3, 0.2, 0)
            case ..<32: return (0.6, 0.3, 0.2, 0.5)
            default: return (0.6, 0.3, 0.2, 1)
            }
        }
        let matched = try ReferenceColorMatcher.apply(profile, to: candidate, strength: 1)
        XCTAssertEqual(matched.extent, candidate.extent)

        let pixels = render(matched, width: 48, height: 32, origin: origin)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let x = (offset / 4) % 48
            let expectedAlpha: Float = x < 16 ? 0 : (x < 32 ? 0.5 : 1)
            XCTAssertEqual(pixels[offset + 3], expectedAlpha, accuracy: 0.00001, "alpha 必须保持")
            XCTAssertTrue(pixels[offset].isFinite)
            if expectedAlpha == 0 {
                XCTAssertEqual(pixels[offset], 0, accuracy: 0.000001)
                XCTAssertEqual(pixels[offset + 1], 0, accuracy: 0.000001)
                XCTAssertEqual(pixels[offset + 2], 0, accuracy: 0.000001)
            }
        }
    }

    // MARK: - Rejection paths

    func testInvalidInputsAreRejected() throws {
        let image = gradient(width: 24, height: 24) { x, _ in
            (Float(x) / 23, 0.4, 0.6)
        }
        let profile = try ReferenceColorMatcher.profile(reference: image)

        XCTAssertThrowsError(try ReferenceColorMatcher.apply(profile, to: image, strength: .nan))
        XCTAssertThrowsError(try ReferenceColorMatcher.apply(profile, to: image, strength: .infinity))
        XCTAssertThrowsError(try ReferenceColorMatcher.profile(reference: image, sampleLimit: 4))
        XCTAssertThrowsError(try ReferenceColorMatcher.profile(reference: image, sampleLimit: 4_000_000))

        let infinite = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1,
                                              colorSpace: colorSpace)!)
        XCTAssertThrowsError(try ReferenceColorMatcher.profile(reference: infinite))
        XCTAssertThrowsError(try ReferenceColorMatcher.apply(profile, to: infinite, strength: 1))

        let transparentOnly = makeImage(width: 16, height: 16) { _, _ in (0.5, 0.5, 0.5, 0) }
        XCTAssertThrowsError(try ReferenceColorMatcher.profile(reference: transparentOnly))
        XCTAssertThrowsError(try ReferenceColorMatcher.apply(profile, to: transparentOnly, strength: 1))
    }

    func testCorruptedProfilesAreRejected() throws {
        let image = gradient(width: 24, height: 24) { x, _ in
            (Float(x) / 23, 0.4, 0.6)
        }
        let valid = try ReferenceColorMatcher.profile(reference: image)
        XCTAssertNoThrow(try valid.validate())

        let nonFinite = ReferenceColorProfile(
            luminanceQuantiles: Array(repeating: Double.nan, count: 17),
            aQuantiles: valid.aQuantiles, bQuantiles: valid.bQuantiles,
            meanL: valid.meanL, meanA: valid.meanA, meanB: valid.meanB,
            sampleCount: valid.sampleCount)
        XCTAssertThrowsError(try nonFinite.validate())
        XCTAssertThrowsError(try ReferenceColorMatcher.apply(nonFinite, to: image, strength: 1))

        let wrongCount = ReferenceColorProfile(
            luminanceQuantiles: [0, 1], aQuantiles: valid.aQuantiles, bQuantiles: valid.bQuantiles,
            meanL: valid.meanL, meanA: valid.meanA, meanB: valid.meanB,
            sampleCount: valid.sampleCount)
        XCTAssertThrowsError(try wrongCount.validate())

        var nonMonotone = valid.luminanceQuantiles
        nonMonotone.swapAt(0, 16)
        let swapped = ReferenceColorProfile(
            luminanceQuantiles: nonMonotone, aQuantiles: valid.aQuantiles,
            bQuantiles: valid.bQuantiles, meanL: valid.meanL, meanA: valid.meanA,
            meanB: valid.meanB, sampleCount: valid.sampleCount)
        XCTAssertThrowsError(try swapped.validate())

        let futureVersion = ReferenceColorProfile(
            algorithmVersion: ReferenceColorProfile.currentAlgorithmVersion + 1,
            luminanceQuantiles: valid.luminanceQuantiles, aQuantiles: valid.aQuantiles,
            bQuantiles: valid.bQuantiles, meanL: valid.meanL, meanA: valid.meanA,
            meanB: valid.meanB, sampleCount: valid.sampleCount)
        XCTAssertThrowsError(try futureVersion.validate())
        XCTAssertThrowsError(try ReferenceColorMatcher.apply(futureVersion, to: image, strength: 1))

        let noSamples = ReferenceColorProfile(
            luminanceQuantiles: valid.luminanceQuantiles, aQuantiles: valid.aQuantiles,
            bQuantiles: valid.bQuantiles, meanL: valid.meanL, meanA: valid.meanA,
            meanB: valid.meanB, sampleCount: 0)
        XCTAssertThrowsError(try noSamples.validate())
    }

    // MARK: - Fixtures

    private func coolGradient(width: Int, height: Int) -> CIImage {
        gradient(width: width, height: height) { x, y in
            let t = Float(x) / Float(max(width - 1, 1))
            let u = Float(y) / Float(max(height - 1, 1))
            return (0.30 + 0.35 * t, 0.38 + 0.30 * u, 0.55 + 0.20 * t)
        }
    }

    private func warmGradient(width: Int, height: Int) -> CIImage {
        gradient(width: width, height: height) { x, y in
            let t = Float(x) / Float(max(width - 1, 1))
            let u = Float(y) / Float(max(height - 1, 1))
            return (0.55 + 0.30 * t, 0.38 + 0.25 * u, 0.22 + 0.18 * t)
        }
    }

    private func gradient(width: Int, height: Int,
                          origin: CGPoint = .zero,
                          pixel: (Int, Int) -> (Float, Float, Float)) -> CIImage {
        makeImage(width: width, height: height, origin: origin) { x, y in
            let (r, g, b) = pixel(x, y)
            return (r, g, b, 1)
        }
    }

    private func makeImage(width: Int, height: Int, origin: CGPoint = .zero,
                           pixel: (Int, Int) -> (Float, Float, Float, Float)) -> CIImage {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let offset = (y * width + x) * 4
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = a
            }
        }
        let image = bitmap(pixels, width: width, height: height)
        guard origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    private func solid(_ red: Float, _ green: Float, _ blue: Float,
                       width: Int, height: Int) -> CIImage {
        makeImage(width: width, height: height) { _, _ in (red, green, blue, 1) }
    }

    private func bitmap(_ pixels: [Float], width: Int, height: Int) -> CIImage {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data,
                       bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                       size: CGSize(width: width, height: height),
                       format: .RGBAf,
                       colorSpace: colorSpace)
    }

    private func render(_ image: CIImage, width: Int, height: Int,
                        origin: CGPoint = .zero) -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let bounds = CGRect(x: origin.x, y: origin.y,
                            width: CGFloat(width), height: CGFloat(height))
        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            context.render(image, toBitmap: baseAddress,
                           rowBytes: width * 4 * MemoryLayout<Float>.stride,
                           bounds: bounds, format: .RGBAf, colorSpace: colorSpace)
        }
        return pixels
    }

    private func oklab(_ pixels: [Float], _ offset: Int) -> (Double, Double, Double) {
        let r = Double(pixels[offset]), g = Double(pixels[offset + 1])
        let b = Double(pixels[offset + 2])
        func root(_ value: Double) -> Double { copysign(pow(abs(value), 1.0 / 3.0), value) }
        let l = root(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = root(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = root(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private func deltaE(_ lhs: (Double, Double, Double),
                        _ rhs: (Double, Double, Double)) -> Double {
        let dl = lhs.0 - rhs.0, da = lhs.1 - rhs.1, db = lhs.2 - rhs.2
        return (dl * dl + da * da + db * db).squareRoot()
    }

    private func chromaDistance(_ lhs: ReferenceColorProfile,
                                _ rhs: ReferenceColorProfile) -> Double {
        let da = lhs.meanA - rhs.meanA
        let db = lhs.meanB - rhs.meanB
        return (da * da + db * db).squareRoot()
    }
}

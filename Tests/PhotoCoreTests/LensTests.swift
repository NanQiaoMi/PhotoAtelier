import CoreGraphics
import CoreImage
import ImageIO
import XCTest
@testable import PhotoCore

final class LensTests: XCTestCase {
    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    func testVendoredLensfunDatabaseLoadsProfiles() {
        let correction = LensCorrection.shared
        XCTAssertTrue(correction.availabilityDescription.contains("0.3.4"),
                      correction.availabilityDescription)
        XCTAssertGreaterThan(correction.profiles.count, 1_000)
    }

    func testManualProfileUsesFocalAndCropOverridesWithoutExif() throws {
        let correction = LensCorrection.shared
        let profile = try canon2470Profile(in: correction.profiles)
        let source = gradientImage(width: 160, height: 120)
        let result = try correction.correct(source, properties: [:], profileID: profile.id,
                                            cropFactor: 1, focalLength: 24)

        XCTAssertTrue(result.report.lensCorrectionApplied, result.report.warnings.joined(separator: "\n"))
        XCTAssertEqual(result.report.lensProfile, "Canon Canon EF 24-70mm f/2.8L USM")
        XCTAssertEqual(result.image.extent.integral, source.extent.integral)
        XCTAssertTrue(try allPixelsOpaque(result.image))
        XCTAssertGreaterThan(try maximumInteriorDifference(source, result.image), 0.0001)
    }

    func testTranslatedExifOrientedImageKeepsItsVerticalOrientation() throws {
        let correction = LensCorrection.shared
        let profile = try canon2470Profile(in: correction.profiles)
        let base = verticalColorBands(width: 120, height: 80)
        let oriented = base.oriented(forExifOrientation: 6)
        let orientedExtent = oriented.extent.integral
        let source = oriented.transformed(by: CGAffineTransform(
            translationX: 31 - orientedExtent.minX,
            y: -17 - orientedExtent.minY))
        let extent = source.extent.integral
        XCTAssertNotEqual(extent.minX, 0)
        XCTAssertNotEqual(extent.minY, 0)

        let result = try correction.correct(source, properties: [:], profileID: profile.id,
                                            cropFactor: 1, focalLength: 24)
        XCTAssertTrue(result.report.lensCorrectionApplied, result.report.warnings.joined(separator: "\n"))
        XCTAssertEqual(result.image.extent.integral, extent)

        let left = CGPoint(x: extent.minX + extent.width * 0.25,
                           y: extent.minY + extent.height * 0.5)
        let right = CGPoint(x: extent.minX + extent.width * 0.75,
                            y: extent.minY + extent.height * 0.5)
        let originalLeft = try color(at: left, in: source)
        let originalRight = try color(at: right, in: source)
        let correctedLeft = try color(at: left, in: result.image)
        let correctedRight = try color(at: right, in: result.image)
        XCTAssertGreaterThan(abs(originalLeft.x - originalRight.x), 0.6,
                             "The orientation marker should place different colors at the left and right.")
        XCTAssertEqual(correctedLeft.x, originalLeft.x, accuracy: 0.15)
        XCTAssertEqual(correctedLeft.z, originalLeft.z, accuracy: 0.15)
        XCTAssertEqual(correctedRight.x, originalRight.x, accuracy: 0.15)
        XCTAssertEqual(correctedRight.z, originalRight.z, accuracy: 0.15)
    }

    func testManualProfileDoesNotInferCropFromLensCalibration() throws {
        let correction = LensCorrection.shared
        let profile = try canon2470Profile(in: correction.profiles)
        let result = try correction.correct(gradientImage(width: 80, height: 60), properties: [:],
                                            profileID: profile.id, cropFactor: 0, focalLength: 24)

        XCTAssertFalse(result.report.lensCorrectionApplied)
        XCTAssertTrue(result.report.warnings.contains { $0.contains("相机裁切系数") })
    }

    func testAutomaticMatchingSkipsAmbiguousLensProfiles() throws {
        let properties: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Canon",
                kCGImagePropertyTIFFModel as String: "Canon EOS 5D Mark IV"
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifLensMake as String: "Canon",
                kCGImagePropertyExifLensModel as String: "Canon EF 24-70mm f/2.8L USM",
                kCGImagePropertyExifFocalLength as String: 24.0
            ]
        ]
        let source = gradientImage(width: 80, height: 60)
        let result = try LensCorrection.shared.correct(source, properties: properties,
                                                       profileID: nil, cropFactor: 0)

        XCTAssertFalse(result.report.lensCorrectionApplied)
        XCTAssertTrue(result.report.warnings.contains { $0.contains("多个 profile") },
                      result.report.warnings.joined(separator: "\n"))
    }

    func testAutomaticMatchingAppliesUniqueCompatibleProfile() throws {
        let properties: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Canon",
                kCGImagePropertyTIFFModel as String: "Canon EOS 5D Mark IV"
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifLensMake as String: "Canon",
                kCGImagePropertyExifLensModel as String: "Canon EF 24-70mm f/2.8L II USM",
                kCGImagePropertyExifFocalLength as String: 24.0
            ]
        ]
        let source = gradientImage(width: 160, height: 120)
        let result = try LensCorrection.shared.correct(source, properties: properties,
                                                       profileID: nil, cropFactor: 0, focalLength: 0)

        XCTAssertTrue(result.report.lensCorrectionApplied, result.report.warnings.joined(separator: "\n"))
        XCTAssertEqual(result.report.lensProfile, "Canon Canon EF 24-70mm f/2.8L II USM")
        XCTAssertEqual(result.image.extent.integral, source.extent.integral)
        XCTAssertTrue(try allPixelsOpaque(result.image))
        XCTAssertGreaterThan(try maximumInteriorDifference(source, result.image), 0.0001)
    }

    func testMissingFocalLengthSafelyReturnsOriginalImage() throws {
        let source = gradientImage(width: 80, height: 60)
        let result = try LensCorrection.shared.correct(source, properties: [:],
                                                       profileID: nil, cropFactor: 0)

        XCTAssertFalse(result.report.lensCorrectionApplied)
        XCTAssertEqual(result.image.extent, source.extent)
        XCTAssertTrue(result.report.warnings.contains { $0.contains("FocalLength") })
    }

    func testManualProfileWithCameraMetadataChecksCompatibility() throws {
        let correction = LensCorrection.shared
        let profile = try canon2470Profile(in: correction.profiles)
        let properties: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Nikon Corporation",
                kCGImagePropertyTIFFModel as String: "Nikon D850"
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifFocalLength as String: 24.0
            ]
        ]
        let result = try correction.correct(gradientImage(width: 80, height: 60),
                                            properties: properties, profileID: profile.id,
                                            cropFactor: 1, focalLength: 0)

        XCTAssertFalse(result.report.lensCorrectionApplied)
        XCTAssertTrue(result.report.warnings.contains { $0.contains("不兼容") },
                      result.report.warnings.joined(separator: "\n"))
    }

    private func canon2470Profile(in profiles: [LensProfileSummary]) throws -> LensProfileSummary {
        let profile = profiles.first(where: {
            $0.maker == "Canon" && $0.name == "Canon EF 24-70mm f/2.8L USM" &&
                abs($0.cropFactor - 1) < 0.001
        })
        return try XCTUnwrap(profile, "Lensfun 0.3.4 DB 中缺少 Canon EF 24-70mm f/2.8L USM profile。")
    }

    private func gradientImage(width: Int, height: Int) -> CIImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let ring = ((x / 5) + (y / 5)) % 2 == 0
                pixels[offset] = UInt8((x * 255) / max(width - 1, 1))
                pixels[offset + 1] = UInt8((y * 255) / max(height - 1, 1))
                pixels[offset + 2] = ring ? 245 : 20
                pixels[offset + 3] = 255
            }
        }
        let bitmapColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: bitmapColorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pixels.withUnsafeBytes { buffer in
            context.data!.copyMemory(from: buffer.baseAddress!, byteCount: buffer.count)
        }
        return CIImage(cgImage: context.makeImage()!, options: [.colorSpace: bitmapColorSpace])
    }

    private func verticalColorBands(width: Int, height: Int) -> CIImage {
        let lower = CGRect(x: 0, y: 0, width: width, height: height / 2)
        let upper = CGRect(x: 0, y: height / 2, width: width, height: height - height / 2)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: lower)
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: upper)
        return blue.composited(over: red)
    }

    private func color(at point: CGPoint, in image: CIImage) throws -> SIMD4<Float> {
        var components = [Float](repeating: 0, count: 4)
        components.withUnsafeMutableBytes { buffer in
            CIContext().render(image, toBitmap: buffer.baseAddress!,
                               rowBytes: 4 * MemoryLayout<Float>.size,
                               bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                               format: .RGBAf, colorSpace: linearColorSpace)
        }
        return SIMD4(components[0], components[1], components[2], components[3])
    }

    private func allPixelsOpaque(_ image: CIImage) throws -> Bool {
        let bounds = image.extent.integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 0, height > 0 else { return false }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            CIContext().render(image, toBitmap: buffer.baseAddress!,
                               rowBytes: width * 4 * MemoryLayout<Float>.size,
                               bounds: bounds, format: .RGBAf, colorSpace: linearColorSpace)
        }
        return stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] >= 0.99 }
    }

    private func maximumInteriorDifference(_ lhs: CIImage, _ rhs: CIImage) throws -> Float {
        let bounds = lhs.extent.integral.insetBy(dx: 3, dy: 3)
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        let context = CIContext()
        var left = [Float](repeating: 0, count: width * height * 4)
        var right = [Float](repeating: 0, count: width * height * 4)
        left.withUnsafeMutableBytes { buffer in
            context.render(lhs, toBitmap: buffer.baseAddress!,
                           rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: bounds, format: .RGBAf, colorSpace: linearColorSpace)
        }
        right.withUnsafeMutableBytes { buffer in
            context.render(rhs, toBitmap: buffer.baseAddress!,
                           rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: bounds, format: .RGBAf, colorSpace: linearColorSpace)
        }
        return zip(left, right).enumerated().reduce(Float.zero) { current, item in
            let (index, values) = item
            return index % 4 == 3 ? current : max(current, abs(values.0 - values.1))
        }
    }
}

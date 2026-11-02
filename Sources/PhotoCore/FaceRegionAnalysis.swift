import CoreGraphics
import CoreImage
import Foundation

/// Measures the union of observed Vision face rectangles in normalized,
/// bottom-left coordinates. No skin segmentation or identity data is stored.
enum FaceRegionAnalyzer {
    static func measure(image: CIImage, regions: [CGRect], context: CIContext) throws -> PhotoSubjectMeasurement? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let boxes = regions.prefix(16).compactMap { box -> CGRect? in
            guard !box.isNull, !box.isInfinite, box.minX.isFinite, box.minY.isFinite,
                  box.width.isFinite, box.height.isFinite else { return nil }
            let clipped = box.intersection(unit)
            return !clipped.isNull && clipped.width * clipped.height >= 0.003 ? clipped : nil
        }
        guard !boxes.isEmpty else { return nil }
        let sample = try AutomaticSafetyEvaluator.sampledSource(image, limit: 384)
        let width = Int(sample.extent.width), height = Int(sample.extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(sample, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: sample.extent, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        }
        var samples: [(y: Double, weight: Double)] = []
        var visible = 0.0, faceWeight = 0.0, nearWhite = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let a = Double(pixels[offset + 3])
                let r = Double(pixels[offset]), g = Double(pixels[offset + 1]), b = Double(pixels[offset + 2])
                guard a.isFinite, a > 0.001, r.isFinite, g.isFinite, b.isFinite else { continue }
                let weight = min(1, a)
                visible += weight
                // CIContext bitmap rows start at the top, while Vision boxes
                // have a bottom-left origin. A measured quadrant test covers it.
                let point = CGPoint(x: (Double(x) + 0.5) / Double(width),
                                    y: 1 - (Double(y) + 0.5) / Double(height))
                guard boxes.contains(where: { $0.contains(point) }) else { continue }
                samples.append((max(0, 0.2126 * r + 0.7152 * g + 0.0722 * b), weight))
                faceWeight += weight
                if max(r, max(g, b)) >= 0.985 { nearWhite += weight }
            }
        }
        guard samples.count >= 8, visible > 0, faceWeight / visible >= 0.003 else { return nil }
        samples.sort { $0.y < $1.y }
        func percentile(_ fraction: Double) -> Double {
            var sum = 0.0
            for sample in samples {
                sum += sample.weight
                if sum >= faceWeight * fraction { return sample.y }
            }
            return samples.last!.y
        }
        return PhotoSubjectMeasurement(faceCount: boxes.count, sampleCount: samples.count,
            coverage: faceWeight / visible, medianLuminance: percentile(0.5),
            p95Luminance: percentile(0.95), nearWhiteFraction: nearWhite / faceWeight)
    }
}

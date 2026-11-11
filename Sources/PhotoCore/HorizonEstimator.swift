import CoreImage
import Foundation

/// Conservative Hough fallback for long, near-horizontal edges. It requires a
/// dominant line spanning most of the frame and otherwise returns no estimate.
enum HorizonEstimator {
    static func angle(in image: CIImage, context: CIContext) -> Double? {
        let extent = image.extent
        let scale = min(1, 256 / max(extent.width, extent.height))
        let width = max(1, Int(extent.width * scale)), height = max(1, Int(extent.height * scale))
        guard width > 20, height > 20 else { return nil }
        let small = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: .init(scaleX: scale, y: scale))
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes {
            context.render(small, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        }
        var luma = [Double](repeating: 0, count: width * height)
        for i in luma.indices {
            luma[i] = 0.2126 * Double(rgba[i * 4]) + 0.7152 * Double(rgba[i * 4 + 1]) + 0.0722 * Double(rgba[i * 4 + 2])
        }
        var edges: [(x: Double, y: Double, weight: Double)] = []
        for y in 2..<(height - 2) {
            for x in 2..<(width - 2) {
                let i = y * width + x
                guard rgba[i * 4 + 3] > 0.95 else { continue }
                let gx = luma[i + 1] - luma[i - 1], gy = luma[i + width] - luma[i - width]
                let magnitude = hypot(gx, gy)
                if magnitude > 0.015, abs(gx) < abs(gy) * 0.42 {
                    edges.append((Double(x), Double(y), magnitude))
                }
            }
        }
        guard edges.count >= 32 else { return nil }
        let weights = edges.map(\.weight).sorted()
        let threshold = weights[weights.count * 2 / 3]
        edges = edges.filter { $0.weight >= threshold }
        let total = edges.reduce(0) { $0 + $1.weight }
        let padding = Int(Double(width) * 0.3) + 3
        let bins = height + padding * 2 + 1
        var bestScore = 0.0, bestAngle = 0.0, bestIntercept = 0
        for step in -60...60 {
            let angle = Double(step) * 0.25 * .pi / 180, slope = tan(angle)
            var accumulator = [Double](repeating: 0, count: bins)
            for edge in edges {
                let index = Int((edge.y - edge.x * slope).rounded()) + padding
                if accumulator.indices.contains(index) { accumulator[index] += edge.weight }
            }
            if let index = accumulator.indices.max(by: { accumulator[$0] < accumulator[$1] }), accumulator[index] > bestScore {
                bestScore = accumulator[index]; bestAngle = angle; bestIntercept = index - padding
            }
        }
        guard total > 0, bestScore / total > 0.16 else { return nil }
        let support = edges.filter { abs($0.y - $0.x * tan(bestAngle) - Double(bestIntercept)) < 1.6 }
        guard let left = support.map(\.x).min(), let right = support.map(\.x).max(),
              right - left > Double(width) * 0.6 else { return nil }
        return bestAngle
    }
}

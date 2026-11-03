import CoreGraphics
import CoreImage
import Foundation

/// Repairs small blemishes inside a soft skin matte.
///
/// v1 algorithm (deterministic, heuristic):
/// 1. rasterize the image and masks to a bounded working raster in linear sRGB;
/// 2. band-pass the luminance with a box low-pass, then take the residual;
/// 3. estimate the residual median/MAD on skin pixels and flag residual outliers
///    (`3.2 * 1.4826 * MAD`, with an absolute floor);
/// 4. group outliers into 4-connected components and keep only small components
///    (a partial blemish, not a lighting edge or texture region);
/// 5. replace the high-frequency defect with the local low-frequency baseline,
///    blended by `strength x skin coverage`, ratio-capped so colour is preserved.
///
/// Protection: pixels under `protectionMask` (brows/lips/teeth/eyes) are never
/// sampled or repaired. `keepSpots` preserves very dark compact outliers (moles).
/// The repair is applied as a signed delta, so pixels outside the skin matte are
/// bit-identical to the input.
public enum BlemishRemovalEngine {
    /// Longest edge of the working raster. Blemishes need more detail than the
    /// 512px semantic matte, so this stage works at up to 1280 pixels.
    public static let maximumWorkDimension = 1280

    public static func apply(_ image: CIImage,
                             strength: Double,
                             keepSpots: Bool,
                             skinMask: CIImage,
                             protectionMask: CIImage?,
                             context: CIContext,
                             cancellation: CancellationToken? = nil) throws -> CIImage {
        guard strength > 0.0001 else { return image }
        let extent = image.extent
        guard let raster = PortraitRaster.render(image: image, extent: extent,
                                                 longestEdge: maximumWorkDimension,
                                                 masks: [skinMask, protectionMask],
                                                 context: context) else { return image }
        try cancellation?.check()
        let width = raster.width
        let height = raster.height
        let pixelCount = raster.pixelCount
        let skin = raster.coverages[0]
        let protection = raster.coverages.count > 1
            ? raster.coverages[1] : [Float](repeating: 0, count: pixelCount)

        var lightness = [Float](repeating: 0, count: pixelCount)
        for index in 0..<pixelCount {
            lightness[index] = PortraitRaster.luminance(raster.red[index],
                                                        raster.green[index],
                                                        raster.blue[index])
        }
        let blurRadius = max(4, Int((0.004 * Double(max(width, height))).rounded()))
        let low = PortraitRaster.boxBlur(lightness, width: width, height: height, radius: blurRadius)
        var residual = [Float](repeating: 0, count: pixelCount)
        for index in 0..<pixelCount {
            residual[index] = lightness[index] - low[index]
        }

        // Robust residual statistics sampled on skin pixels only.
        let sampleStride = max(1, pixelCount / 20000)
        var samples: [Float] = []
        samples.reserveCapacity(min(pixelCount, 20000))
        for index in stride(from: 0, to: pixelCount, by: sampleStride)
        where skin[index] > 0.5 && protection[index] < 0.05 {
            samples.append(residual[index])
        }
        guard samples.count >= 64 else { return image }
        samples.sort()
        let median = samples[samples.count / 2]
        let deviations = samples.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2]
        let threshold = max(Float(0.0025), 3.2 * 1.4826 * mad)
        try cancellation?.check()

        var candidates = [Bool](repeating: false, count: pixelCount)
        for index in 0..<pixelCount {
            guard skin[index] > 0.5, protection[index] < 0.05 else { continue }
            let deviation = residual[index] - median
            guard abs(deviation) > threshold else { continue }
            // keepSpots: preserve spots more than ~45% darker than the local
            // skin baseline (moles/freckles rather than small blemishes).
            if keepSpots && deviation < -0.60 * max(low[index], 0.05) { continue }
            candidates[index] = true
        }

        var repairMask = [Bool](repeating: false, count: pixelCount)
        var visited = [Bool](repeating: false, count: pixelCount)
        var component: [Int] = []
        var queue: [Int] = []
        // A blemish plus its low-pass halo is larger than the raw defect; lighting
        // gradients and texture regions exceed this relative area and are rejected.
        let maximumArea = max(200, pixelCount / 500)
        func enqueue(_ index: Int) {
            guard !visited[index], candidates[index] else { return }
            visited[index] = true
            queue.append(index)
        }
        for start in 0..<pixelCount where candidates[start] && !visited[start] {
            try cancellation?.check()
            component.removeAll(keepingCapacity: true)
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            visited[start] = true
            var head = 0
            while head < queue.count {
                let index = queue[head]
                head += 1
                component.append(index)
                let column = index % width
                let row = index / width
                if column > 0 { enqueue(index - 1) }
                if column + 1 < width { enqueue(index + 1) }
                if row > 0 { enqueue(index - width) }
                if row + 1 < height { enqueue(index + width) }
            }
            guard component.count >= 3, component.count <= maximumArea else { continue }
            // Reject line/ring-like structures (boundaries between protection
            // regions or between skin and background): real blemishes are
            // blob-shaped, so require a compact bounding-box fill.
            var minimumColumn = width, maximumColumn = 0
            var minimumRow = height, maximumRow = 0
            for index in component {
                let column = index % width
                let row = index / width
                minimumColumn = min(minimumColumn, column)
                maximumColumn = max(maximumColumn, column)
                minimumRow = min(minimumRow, row)
                maximumRow = max(maximumRow, row)
            }
            let boxArea = (maximumColumn - minimumColumn + 1) * (maximumRow - minimumRow + 1)
            let fill = Double(component.count) / Double(max(1, boxArea))
            guard fill >= 0.35 else { continue }
            for index in component { repairMask[index] = true }
        }

        var deltaRed = [Float](repeating: 0, count: pixelCount)
        var deltaGreen = deltaRed
        var deltaBlue = deltaRed
        for index in 0..<pixelCount where repairMask[index] {
            let current = lightness[index]
            guard current > 0.002 else { continue }
            let target = low[index] + median
            let ratio = Double(min(2.5, max(0.60, target / current)))
            let weight = Float(Double(strength) * Double(min(1, skin[index])))
            deltaRed[index] = Float(min(0.20, max(-0.20, Double(raster.red[index]) * (ratio - 1) * Double(weight))))
            deltaGreen[index] = Float(min(0.20, max(-0.20, Double(raster.green[index]) * (ratio - 1) * Double(weight))))
            deltaBlue[index] = Float(min(0.20, max(-0.20, Double(raster.blue[index]) * (ratio - 1) * Double(weight))))
        }
        let delta = PortraitRaster.deltaImage(red: deltaRed, green: deltaGreen, blue: deltaBlue,
                                              width: width, height: height, extent: extent)
        return PortraitRaster.add(delta: delta, to: image)
    }
}

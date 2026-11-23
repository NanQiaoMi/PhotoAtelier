import CoreGraphics
import CoreImage
import Foundation

/// Repairs small and medium blemishes inside a soft skin matte.
///
/// R7 dual-scale algorithm (deterministic, heuristic):
/// 1. rasterize the image and masks to a bounded working raster in linear sRGB;
/// 2. compute skin-weighted normalised box low-pass baselines at two scales:
///    - fine scale (`~0.4%` of long edge, min 4 px) for pores/small spots;
///    - medium scale (`~1.8%` of long edge, min 14 px) for 5-20 px blemishes;
///    normalised blurring (`boxBlur(L*w)/boxBlur(w)`) prevents background, hair,
///    or protected features from bleeding into the skin baseline as halos;
/// 3. estimate each scale's residual median/MAD on skin pixels and flag
///    outliers (`3.2/3.0 * 1.4826 * MAD`, with per-scale floors);
/// 4. group outliers into 4-connected components and filter by area, bounding
///    span, fill factor, and rotation-invariant second-moment elongation
///    (`sqrt(lambda1 / lambda2) <= 2.3` on medium scale) so circular/oval
///    blemishes pass while horizontal or diagonal creases (tear troughs,
///    nasolabial folds, wrinkles) are preserved;
/// 5. soften the medium mask with a 2 px feather and replace defects toward the
///    corresponding low-frequency baseline, blended by `strength x skin`,
///    ratio-capped so colour is preserved.
///
/// Protection: pixels under `protectionMask` (brows/lips/teeth/eyes) are never
/// sampled or repaired. `keepSpots` preserves very dark compact outliers (moles).
/// The repair is applied as a signed delta, so pixels outside the skin matte are
/// bit-identical to the input.
public enum BlemishRemovalEngine {
    /// Longest edge of the working raster. Blemishes need more detail than the
    /// 512px semantic matte, so this stage works at up to 1280 pixels.
    public static let maximumWorkDimension = 1280

    private struct ScaleConfig {
        let radius: Int
        let thresholdFloor: Float
        let madMultiplier: Float
        let minArea: Int
        let maxArea: Int
        let maxSpan: Int
        let minFill: Double
        let maxElongation: Double
    }

    private struct ScaleResult {
        let low: [Float]
        let median: Float
        let mask: [Bool]
    }

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

        var weight = [Float](repeating: 0, count: pixelCount)
        var lightness = [Float](repeating: 0, count: pixelCount)
        for index in 0..<pixelCount {
            let w = max(0, min(1, skin[index])) * (1 - max(0, min(1, protection[index])))
            weight[index] = w
            lightness[index] = PortraitRaster.luminance(raster.red[index],
                                                        raster.green[index],
                                                        raster.blue[index])
        }

        let longEdge = Double(max(width, height))
        let fineConfig = ScaleConfig(
            radius: max(4, Int((0.004 * longEdge).rounded())),
            thresholdFloor: 0.0025,
            madMultiplier: 3.2,
            minArea: 3,
            maxArea: max(200, pixelCount / 500),
            maxSpan: Int.max,
            minFill: 0.35,
            maxElongation: 2.3
        )

        let maxBlobRadius = max(12.0, 0.018 * longEdge)
        let mediumConfig = ScaleConfig(
            radius: max(14, Int((0.018 * longEdge).rounded())),
            thresholdFloor: 0.004,
            madMultiplier: 3.0,
            minArea: 25,
            maxArea: min(pixelCount / 80,
                         Int((Double.pi * maxBlobRadius * maxBlobRadius * 1.35).rounded())),
            maxSpan: Int((maxBlobRadius * 2.6).rounded()),
            minFill: 0.38,
            maxElongation: 2.3
        )

        guard let mediumResult = try detectScale(
            lightness: lightness, weight: weight, skin: skin, protection: protection,
            width: width, height: height, config: mediumConfig,
            keepSpots: keepSpots, darkGuardLow: nil, darkGuardMedian: 0,
            cancellation: cancellation
        ) else {
            return image
        }
        try cancellation?.check()

        guard let fineResult = try detectScale(
            lightness: lightness, weight: weight, skin: skin, protection: protection,
            width: width, height: height, config: fineConfig,
            keepSpots: keepSpots,
            darkGuardLow: mediumResult.low, darkGuardMedian: mediumResult.median,
            cancellation: cancellation
        ) else {
            return image
        }
        try cancellation?.check()

        var mediumMaskFloat = [Float](repeating: 0, count: pixelCount)
        var hasMediumSpots = false
        for index in 0..<pixelCount where mediumResult.mask[index] {
            mediumMaskFloat[index] = 1
            hasMediumSpots = true
        }
        let softMedium = PortraitRaster.boxBlur(mediumMaskFloat, width: width, height: height, radius: 2)
        let cleanMediumLow: [Float]
        if hasMediumSpots {
            var cleanWeight = weight
            for index in 0..<pixelCount where mediumResult.mask[index] {
                cleanWeight[index] = 0
            }
            cleanMediumLow = normalizedSkinLowPass(lightness: lightness, weight: cleanWeight,
                                                   width: width, height: height, radius: mediumConfig.radius)
        } else {
            cleanMediumLow = mediumResult.low
        }

        var deltaRed = [Float](repeating: 0, count: pixelCount)
        var deltaGreen = deltaRed
        var deltaBlue = deltaRed
        for index in 0..<pixelCount {
            guard skin[index] > 0.5, protection[index] < 0.05 else { continue }
            let medWeight = softMedium[index]
            let isFine = fineResult.mask[index]
            let maskFactor: Float
            let target: Float
            if medWeight > 0.01 {
                maskFactor = max(isFine ? 1 : 0, medWeight)
                target = cleanMediumLow[index] + mediumResult.median
            } else if isFine {
                maskFactor = 1
                target = fineResult.low[index] + fineResult.median
            } else {
                continue
            }

            let current = lightness[index]
            guard current > 0.002 else { continue }
            let ratio = Double(min(2.5, max(0.60, target / current)))
            let blend = Double(strength) * Double(min(1, skin[index])) * Double(maskFactor)
            deltaRed[index] = Float(min(0.20, max(-0.20, Double(raster.red[index]) * (ratio - 1) * blend)))
            deltaGreen[index] = Float(min(0.20, max(-0.20, Double(raster.green[index]) * (ratio - 1) * blend)))
            deltaBlue[index] = Float(min(0.20, max(-0.20, Double(raster.blue[index]) * (ratio - 1) * blend)))
        }

        let delta = PortraitRaster.deltaImage(red: deltaRed, green: deltaGreen, blue: deltaBlue,
                                              width: width, height: height, extent: extent)
        return PortraitRaster.add(delta: delta, to: image)
    }

    private static func normalizedSkinLowPass(lightness: [Float],
                                              weight: [Float],
                                              width: Int,
                                              height: Int,
                                              radius: Int) -> [Float] {
        let pixelCount = lightness.count
        var weighted = [Float](repeating: 0, count: pixelCount)
        for index in 0..<pixelCount {
            weighted[index] = lightness[index] * weight[index]
        }
        let numerator = PortraitRaster.boxBlur(weighted, width: width, height: height, radius: radius)
        let denominator = PortraitRaster.boxBlur(weight, width: width, height: height, radius: radius)
        var result = [Float](repeating: 0, count: pixelCount)
        for index in 0..<pixelCount {
            let coverage = denominator[index]
            result[index] = coverage > 0.02 ? (numerator[index] / coverage) : lightness[index]
        }
        return result
    }

    private static func detectScale(lightness: [Float],
                                    weight: [Float],
                                    skin: [Float],
                                    protection: [Float],
                                    width: Int,
                                    height: Int,
                                    config: ScaleConfig,
                                    keepSpots: Bool,
                                    darkGuardLow: [Float]?,
                                    darkGuardMedian: Float,
                                    cancellation: CancellationToken?) throws -> ScaleResult? {
        let pixelCount = lightness.count
        let low = normalizedSkinLowPass(lightness: lightness, weight: weight,
                                        width: width, height: height, radius: config.radius)
        var residual = [Float](repeating: 0, count: pixelCount)
        for index in 0..<pixelCount {
            residual[index] = lightness[index] - low[index]
        }

        let sampleStride = max(1, pixelCount / 20000)
        var samples: [Float] = []
        samples.reserveCapacity(min(pixelCount, 20000))
        for index in stride(from: 0, to: pixelCount, by: sampleStride)
        where skin[index] > 0.5 && protection[index] < 0.05 {
            samples.append(residual[index])
        }
        guard samples.count >= 64 else { return nil }
        samples.sort()
        let median = samples[samples.count / 2]
        let deviations = samples.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2]
        let threshold = max(config.thresholdFloor, config.madMultiplier * 1.4826 * mad)
        try cancellation?.check()

        var candidateSign = [Int8](repeating: 0, count: pixelCount)
        for index in 0..<pixelCount {
            guard skin[index] > 0.5, protection[index] < 0.05 else { continue }
            let deviation = residual[index] - median
            guard abs(deviation) > threshold else { continue }
            if keepSpots {
                if deviation < -0.60 * max(low[index], 0.05) { continue }
                if let darkGuardLow {
                    let broadDev = lightness[index] - darkGuardLow[index] - darkGuardMedian
                    if broadDev < -0.60 * max(darkGuardLow[index], 0.05) { continue }
                }
            }
            candidateSign[index] = deviation < 0 ? -1 : 1
        }

        var repairMask = [Bool](repeating: false, count: pixelCount)
        var visited = [Bool](repeating: false, count: pixelCount)
        var component: [Int] = []
        var queue: [Int] = []
        func enqueue(_ index: Int, sign: Int8) {
            guard !visited[index], candidateSign[index] == sign else { return }
            visited[index] = true
            queue.append(index)
        }

        for start in 0..<pixelCount where candidateSign[start] != 0 && !visited[start] {
            try cancellation?.check()
            let sign = candidateSign[start]
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
                if column > 0 { enqueue(index - 1, sign: sign) }
                if column + 1 < width { enqueue(index + 1, sign: sign) }
                if row > 0 { enqueue(index - width, sign: sign) }
                if row + 1 < height { enqueue(index + width, sign: sign) }
            }
            guard component.count >= config.minArea,
                  component.count <= config.maxArea else { continue }

            var minimumColumn = width, maximumColumn = 0
            var minimumRow = height, maximumRow = 0
            var sumX = 0.0, sumY = 0.0
            for index in component {
                let column = index % width
                let row = index / width
                minimumColumn = min(minimumColumn, column)
                maximumColumn = max(maximumColumn, column)
                minimumRow = min(minimumRow, row)
                maximumRow = max(maximumRow, row)
                sumX += Double(column)
                sumY += Double(row)
            }
            let boxWidth = maximumColumn - minimumColumn + 1
            let boxHeight = maximumRow - minimumRow + 1
            guard boxWidth <= config.maxSpan, boxHeight <= config.maxSpan else { continue }
            let boxArea = boxWidth * boxHeight
            let fill = Double(component.count) / Double(max(1, boxArea))
            guard fill >= config.minFill else { continue }

            if config.maxElongation.isFinite && component.count >= 12 {
                let count = Double(component.count)
                let meanX = sumX / count
                let meanY = sumY / count
                var sumXX = 0.0, sumYY = 0.0, sumXY = 0.0
                for index in component {
                    let dx = Double(index % width) - meanX
                    let dy = Double(index / width) - meanY
                    sumXX += dx * dx
                    sumYY += dy * dy
                    sumXY += dx * dy
                }
                let mu20 = sumXX / count + (1.0 / 12.0)
                let mu02 = sumYY / count + (1.0 / 12.0)
                let mu11 = sumXY / count
                let traceHalf = 0.5 * (mu20 + mu02)
                let diffHalf = 0.5 * (mu20 - mu02)
                let root = sqrt(diffHalf * diffHalf + mu11 * mu11)
                let lambda1 = traceHalf + root
                let lambda2 = max(1e-6, traceHalf - root)
                let elongation = sqrt(lambda1 / lambda2)
                guard elongation <= config.maxElongation else { continue }
            }

            for index in component { repairMask[index] = true }
        }

        return ScaleResult(low: low, median: median, mask: repairMask)
    }
}

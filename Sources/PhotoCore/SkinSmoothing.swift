import CoreGraphics
import CoreImage
import Foundation

/// Edge-aware skin smoothing — the "磨皮" step the pipeline never had.
///
/// Every other skin stage in this pipeline *adds* detail: `structure` boosts
/// mid-frequency contrast, `texture` amplifies the high band, `dodgeBurn` pulls
/// the low band onto a trend. Measured on three real portraits (2026-11-15), the
/// whole portrait pass therefore *raised* skin high-frequency energy by 11%, and
/// no combination of existing controls could lower it. A retouching app's most
/// basic operation — making skin smooth — was simply not expressible.
///
/// This stage is that operation. It removes a bounded fraction of the high band
/// (`luminance - local mean`) inside the skin matte, with three guards:
///
/// 1. **Normalised local mean.** The reference is `boxBlur(l·w) / boxBlur(w)`
///    over the skin weight `w`, not a plain blur. A plain blur near the face
///    boundary averages in the background, so pulling toward it would paint a
///    bright halo along the jaw; the normalised form only ever averages skin.
/// 2. **Edge guard in the photo's own units.** A pixel is smoothed only while
///    its deviation from the local mean is small *relative to this face's own
///    measured texture amplitude*. The threshold is a multiple of the median
///    deviation, never an absolute value — the same lesson R3/R4/R5 recorded:
///    an absolute threshold encodes one lighting setup and silently mis-fires on
///    every photo outside it. Eyes, nostrils, the lip line and the face contour
///    deviate by an order of magnitude more than pores, so they survive intact.
/// 3. **Protection regions.** Brows, lips, teeth, sclera and the iris are
///    subtracted from the weight, so no smoothing can reach them even where the
///    colour classifier leaks.
///
/// The result is applied as an equal-RGB delta scaled by skin coverage, so hue
/// and saturation are unchanged (an equal delta moves luminance by exactly that
/// amount, because the luminance weights sum to one).
public enum SkinSmoothingEngine {
    /// Raster cap. Matches the frequency-separation pass so the two operate on
    /// the same pixel grid and their deltas compose without resampling beats.
    public static let maximumWorkDimension = 2048

    public static func apply(_ image: CIImage,
                             amount: Double,
                             skinMask: CIImage,
                             protectionMask: CIImage?,
                             context: CIContext,
                             cancellation: CancellationToken? = nil) throws -> CIImage {
        guard amount > 0.0001 else { return image }
        let extent = image.extent
        guard let raster = PortraitRaster.render(image: image, extent: extent,
                                                 longestEdge: maximumWorkDimension,
                                                 masks: [skinMask, protectionMask],
                                                 context: context) else {
            return image
        }
        try cancellation?.check()

        let width = raster.width
        let height = raster.height
        let pixelCount = raster.pixelCount
        let skin = raster.coverages[0]
        let protection = raster.coverages.count > 1
            ? raster.coverages[1] : [Float](repeating: 0, count: pixelCount)

        // Effective skin weight: inside the matte and outside every protected
        // feature. Used for both the reference and the application, so the two
        // can never disagree about which pixels are skin.
        var weight = [Float](repeating: 0, count: pixelCount)
        for index in 0..<pixelCount {
            weight[index] = max(0, min(1, skin[index])) * (1 - max(0, min(1, protection[index])))
        }

        var lightness = [Float](repeating: 0, count: pixelCount)
        var maskedLightness = [Float](repeating: 0, count: pixelCount)
        for index in 0..<pixelCount {
            let value = PortraitRaster.luminance(raster.red[index],
                                                 raster.green[index],
                                                 raster.blue[index])
            lightness[index] = value
            maskedLightness[index] = value * weight[index]
        }

        // A few pixels wide: wide enough to swallow pore-scale texture, narrow
        // enough that the face's own light modelling is the *mean* it pulls
        // toward rather than the thing being removed.
        let shortEdge = Double(min(width, height))
        let radius = max(2, Int((0.0045 * shortEdge).rounded()))
        let numerator = PortraitRaster.boxBlur(maskedLightness, width: width, height: height, radius: radius)
        let denominator = PortraitRaster.boxBlur(weight, width: width, height: height, radius: radius)
        try cancellation?.check()

        var localMean = [Float](repeating: 0, count: pixelCount)
        // The median only needs a representative sample, not every skin pixel:
        // a strided draw of ~20k is far more than enough for a median and keeps
        // the sort off the critical path on a 2048-px raster (same pattern as
        // `BlemishRemoval`'s residual statistics).
        let sampleStride = max(1, pixelCount / 20000)
        var deviations = [Float]()
        deviations.reserveCapacity(pixelCount / sampleStride + 1)
        for index in 0..<pixelCount {
            let coverage = denominator[index]
            guard coverage > 0.02 else {
                localMean[index] = lightness[index]
                continue
            }
            let mean = numerator[index] / coverage
            localMean[index] = mean
            if weight[index] > 0.5, index % sampleStride == 0 {
                deviations.append(abs(lightness[index] - mean))
            }
        }

        // This face's own fine-texture amplitude. Everything below is expressed
        // as a multiple of it, so the guard travels with exposure, skin tone and
        // sensor noise instead of assuming one.
        let textureScale = median(of: deviations)
        // Clamped into a band that is meaningful in the extended-linear working
        // space (real skin sits at 0.05-0.30 there): below the floor the guard
        // would smooth nothing, above the ceiling it would flatten real features.
        let scale = min(0.05, max(0.0015, Double(textureScale)))
        let edgeStart = scale * 3.0
        let edgeEnd = scale * 7.0

        var deltaRed = [Float](repeating: 0, count: pixelCount)
        var deltaGreen = deltaRed
        var deltaBlue = deltaRed
        for index in 0..<pixelCount where weight[index] > 0.02 {
            let deviation = Double(lightness[index] - localMean[index])
            let magnitude = abs(deviation)
            // Full strength on texture, nothing on edges. `smoothstep` from
            // edgeStart to edgeEnd means the transition is gradual, so a
            // mid-strength feature (a freckle, a nostril wing) is softened
            // rather than either kept or erased outright.
            let edge = 1 - smoothstep(edgeStart, edgeEnd, magnitude)
            guard edge > 0.001 else { continue }
            let delta = Float(-deviation * amount * edge)
            let bounded = min(0.10, max(-0.10, delta)) * weight[index]
            deltaRed[index] = bounded
            deltaGreen[index] = bounded
            deltaBlue[index] = bounded
        }

        let delta = PortraitRaster.deltaImage(red: deltaRed, green: deltaGreen, blue: deltaBlue,
                                              width: width, height: height, extent: extent)
        return PortraitRaster.add(delta: delta, to: image)
    }

    /// Median of the sample set, or 0 when there is nothing to measure. Robust
    /// against the long tail of edge pixels, which is exactly why a mean would
    /// be the wrong statistic here.
    static func median(of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var sorted = values
        sorted.sort()
        return sorted[sorted.count / 2]
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}

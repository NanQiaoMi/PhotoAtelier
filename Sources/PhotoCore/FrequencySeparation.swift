import CoreGraphics
import CoreImage
import Foundation

/// Frequency-separation shaping for the skin matte.
///
/// The luminance is split into three bands with two box low-passes:
/// - low band (`blurLarge`): broad light/shadow variation → `dodgeBurn` pulls it
///   toward the **large-scale low frequency** (R2, 2026-11-12 naturalness rework:
///   previously it pulled toward the single face-wide mean, which flattened real
///   lighting gradients into a uniformly lit "plastic" face; pulling toward the
///   local low frequency only evens out blotchy sub-low-frequency patches while
///   preserving the studio light's spatial structure);
/// - mid band (`blurSmall - blurLarge`): local contrast → `structure` adds it
///   back (立体/结构);
/// - high band (`luminance - blurSmall`): fine texture → `texture` amplifies it,
///   while `gloss` dampens it in bright areas to soften specular sheen.
///
/// Every contribution is bounded before it is applied and the result is added as
/// a signed delta weighted by the skin matte, so non-skin pixels are untouched.
public enum FrequencySeparationEngine {
    /// R2: 2048 keeps pore-level bands meaningful on typical 12–24 MP inputs
    /// while bounding the box-blur cost; deltas are only ever downscaled onto
    /// larger images, never upscaled from a smaller raster (see PortraitRaster).
    public static let maximumWorkDimension = 2048

    public static func apply(_ image: CIImage,
                             settings: PortraitRefinementSettings,
                             skinMask: CIImage,
                             context: CIContext,
                             cancellation: CancellationToken? = nil) throws -> CIImage {
        let active = settings.dodgeBurn > 0 || settings.structure > 0
            || settings.texture > 0 || settings.gloss > 0
        guard active else { return image }
        let extent = image.extent
        guard let raster = PortraitRaster.render(image: image, extent: extent,
                                                 longestEdge: maximumWorkDimension,
                                                 masks: [skinMask], context: context) else {
            return image
        }
        try cancellation?.check()
        let width = raster.width
        let height = raster.height
        let pixelCount = raster.pixelCount
        let skin = raster.coverages[0]
        let shortEdge = Double(min(width, height))
        var lightness = [Float](repeating: 0, count: pixelCount)
        for index in 0..<pixelCount {
            lightness[index] = PortraitRaster.luminance(raster.red[index],
                                                        raster.green[index],
                                                        raster.blue[index])
        }
        let largeRadius = max(3, Int((0.015 * shortEdge).rounded()))
        // Medium scale carries "structure" (local contrast), high scale carries
        // texture/gloss; keeping them on separate radii makes the controls
        // independent instead of all acting on the same 2px band.
        let midRadius = max(2, Int((0.008 * shortEdge).rounded()))
        let smallRadius = max(1, Int((0.0018 * shortEdge).rounded()))
        let lowLarge = PortraitRaster.boxBlur(lightness, width: width, height: height, radius: largeRadius)
        let lowMid = PortraitRaster.boxBlur(lightness, width: width, height: height, radius: midRadius)
        let lowSmall = PortraitRaster.boxBlur(lightness, width: width, height: height, radius: smallRadius)
        try cancellation?.check()

        // R3 (2026-11-14): the dodge/burn reference is a *skin-only wide trend*
        // instead of the face-wide mean. A mean anchor removes a constant share
        // of every pixel's deviation from that mean, so on a face lit from one
        // side the bright side was systematically pulled down and the dark side
        // up - the light modelling was flattened even though the old test only
        // looked at the standard deviation.
        //
        // The trend is measured from skin pixels alone (hair and background must
        // not drag the reference down) over a radius wide enough to *carry the
        // lighting gradient itself* (about a face width at typical framing), so
        // what gets pulled out of `lowLarge` is mid-scale blotchiness and never
        // the modelling of the face.
        let wideRadius = max(8, Int((0.10 * shortEdge).rounded()))
        var maskedLightness = [Float](repeating: 0, count: pixelCount)
        for index in 0..<pixelCount {
            maskedLightness[index] = lightness[index] * skin[index]
        }
        let wideNumerator = PortraitRaster.boxBlur(maskedLightness, width: width, height: height, radius: wideRadius)
        let wideDenominator = PortraitRaster.boxBlur(skin, width: width, height: height, radius: wideRadius)

        // The face's own average skin level: the reference that makes "bright"
        // mean "bright for this face" in any working colour space.
        var weightedLightness = 0.0
        var totalWeight = 0.0
        for index in 0..<pixelCount where skin[index] > 0.3 {
            let weight = Double(skin[index])
            weightedLightness += Double(lowLarge[index]) * weight
            totalWeight += weight
        }
        let skinMeanLightness = totalWeight > 0 ? weightedLightness / totalWeight : 0

        /// The skin-only wide trend at `index`; falls back to the local large
        /// band where the skin matte has no coverage.
        func trendForPixel(_ index: Int) -> Double {
            let denominator = Double(wideDenominator[index])
            return denominator > 0.02
                ? Double(wideNumerator[index]) / denominator
                : Double(lowLarge[index])
        }

        var deltaRed = [Float](repeating: 0, count: pixelCount)
        var deltaGreen = deltaRed
        var deltaBlue = deltaRed
        for index in 0..<pixelCount where skin[index] > 0.02 {
            let current = Double(lightness[index])
            var delta = 0.0
            if settings.dodgeBurn > 0 {
                // R3: pull the low band toward the *wide skin trend*:
                // The lighting gradient itself (window light falling from the
                // left, a lit forehead against a shaded jaw) is the trend, so it
                // is left untouched: only the blotchy deviation from it is
                // evened out and the face keeps its modelling.
                let lowFrequency = Double(lowLarge[index])
                let trend = trendForPixel(index)
                // Pull the low band onto the wide trend. Because the trend is a
                // skin-only, face-scale average, this removes blotchy patches
                // while the light direction itself *is* the trend and therefore
                // survives untouched (no `structureKeep` attenuation needed).
                delta += (trend - lowFrequency) * 0.45 * settings.dodgeBurn
            }
            if settings.structure > 0 {
                let midContrast = current - Double(lowMid[index])
                delta += min(0.08, max(-0.08, midContrast * 0.55 * settings.structure))
            }
            if settings.texture > 0 {
                let highFrequency = current - Double(lowSmall[index])
                delta += highFrequency * 0.55 * settings.texture
            }
            if settings.gloss > 0 {
                let highFrequency = current - Double(lowSmall[index])
                // R3: the highlight gate used an ABSOLUTE luminance window
                // (0.55...0.85), which never fires in the extended-linear-sRGB
                // working space where real skin sits around 0.05-0.30 - gloss
                // was a silent no-op on every real photo. It is now relative to
                // the photo's own skin level, so "bright" means "bright for this
                // face" in any colour space.
                let relative = skinMeanLightness > 0.0001 ? current / skinMeanLightness : 1.0
                let highlight = smoothstep(1.15, 1.60, relative)
                delta -= highFrequency * 0.90 * settings.gloss * highlight
            }
            delta = min(0.16, max(-0.16, delta))
            let weight = Float(Double(skin[index]) * delta)
            deltaRed[index] = weight
            deltaGreen[index] = weight
            deltaBlue[index] = weight
        }
        let deltaImage = PortraitRaster.deltaImage(red: deltaRed, green: deltaGreen, blue: deltaBlue,
                                                   width: width, height: height, extent: extent)
        return PortraitRaster.add(delta: deltaImage, to: image)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}

import CoreGraphics
import CoreImage
import Foundation

/// Frequency-separation shaping for the skin matte.
///
/// The luminance is split into three bands with two box low-passes:
/// - low band (`blurLarge`): broad light/shadow variation → `dodgeBurn` pulls it
///   toward the skin's mean level (光影平整);
/// - mid band (`blurSmall - blurLarge`): local contrast → `structure` adds it
///   back (立体/结构);
/// - high band (`luminance - blurSmall`): fine texture → `texture` amplifies it,
///   while `gloss` dampens it in bright areas to soften specular sheen.
///
/// Every contribution is bounded before it is applied and the result is added as
/// a signed delta weighted by the skin matte, so non-skin pixels are untouched.
/// The operation is a deterministic v1 approximation, not a commercial-grade
/// dodge & burn or skin-frequency tool.
public enum FrequencySeparationEngine {
    public static let maximumWorkDimension = 1024

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

        var weightedLightness = 0.0
        var totalWeight = 0.0
        for index in 0..<pixelCount where skin[index] > 0.3 {
            let weight = Double(skin[index])
            weightedLightness += Double(lowLarge[index]) * weight
            totalWeight += weight
        }
        let meanLightness = totalWeight > 0 ? weightedLightness / totalWeight : 0

        var deltaRed = [Float](repeating: 0, count: pixelCount)
        var deltaGreen = deltaRed
        var deltaBlue = deltaRed
        for index in 0..<pixelCount where skin[index] > 0.02 {
            let current = Double(lightness[index])
            var delta = 0.0
            if settings.dodgeBurn > 0 {
                let lowFrequency = Double(lowLarge[index])
                delta += (meanLightness - lowFrequency) * 0.45 * settings.dodgeBurn
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
                let highlight = smoothstep(0.55, 0.85, current)
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

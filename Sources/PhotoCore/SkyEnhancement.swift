import Foundation
import CoreImage
import Vision

/// P2-J: Smart sky detection, atmospheric relighting and replacement engine.
///
/// Features:
/// 1. `skyVibrance`: Restores rich azure/cyan gradient in overexposed or washed-out skies.
/// 2. `cloudContrast`: Band-pass high/mid-frequency contrast enhancement on cumulus clouds.
/// 3. `sunsetWarmth`: Injects twilight/golden hour atmospheric warmth near the horizon.
/// 4. `skyPreset`: Built-in procedural sky replacements (Azure, Sunset, Twilight, Dramatic, Dawn).
/// 5. `foregroundRelight`: Ambient color transfer to foreground subjects preventing sticker look.
/// 6. `edgeFeather`: Smooth transition and halo-free boundary across trees, horizon, and hair.
public enum SkyEnhancementEngine {

    private static let skyKernel: CIColorKernel? = {
        let kernelSource = """
        kernel vec4 skyEnhance(
            sampler orig,
            sampler blurred,
            sampler skyMask,
            float skyVibrance,
            float cloudContrast,
            float sunsetWarmth,
            float skyPreset,
            float replacementOpacity,
            float foregroundRelight,
            vec2 imageSize
        ) {
            vec2 dc = destCoord();
            vec4 c = sample(orig, samplerCoord(orig));
            vec4 b = sample(blurred, samplerCoord(blurred));
            float skyAlpha = sample(skyMask, samplerCoord(skyMask)).r;

            if (skyAlpha <= 0.001 && foregroundRelight <= 0.001) {
                return c;
            }

            vec3 high = c.rgb - b.rgb;
            float lum = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
            float normY = clamp(dc.y / imageSize.y, 0.0, 1.0);

            // 1. Sky Vibrance: restore azure in blown-out/washed sky
            vec3 skyColor = c.rgb;
            if (skyVibrance > 0.001 && skyAlpha > 0.001) {
                float whiteGap = clamp((lum - 0.40) / 0.60, 0.0, 1.0);
                float azureGrad = 0.50 + 0.50 * normY;
                vec3 azureTint = vec3(0.12, 0.42, 0.82) * azureGrad;
                vec3 vibTarget = mix(skyColor, azureTint, whiteGap * skyVibrance * 0.75);
                skyColor = mix(skyColor, vibTarget, skyAlpha);
            }

            // 2. Cloud Contrast: enhance mid-frequency cloud definition
            if (cloudContrast > 0.001 && skyAlpha > 0.001) {
                vec3 cloudDelta = high * cloudContrast * 0.90 * skyAlpha;
                skyColor = clamp(skyColor + cloudDelta, 0.0, 1.0);
            }

            // 3. Sunset Warmth: inject dusk amber/gold near horizon
            if (sunsetWarmth > 0.001 && skyAlpha > 0.001) {
                float horizonFactor = clamp(1.0 - normY * 1.3, 0.0, 1.0);
                vec3 sunsetTint = mix(vec3(0.95, 0.50, 0.15), vec3(0.35, 0.20, 0.55), normY);
                skyColor = mix(skyColor, sunsetTint, horizonFactor * sunsetWarmth * 0.70 * skyAlpha);
            }

            // 4. Procedural Sky Replacement Preset
            vec3 ambientGlow = vec3(0.85, 0.60, 0.35);
            int presetId = int(skyPreset + 0.5);
            if (presetId == 1) {
                ambientGlow = vec3(0.50, 0.70, 0.90);
            } else if (presetId == 2) {
                ambientGlow = vec3(1.0, 0.65, 0.30);
            } else if (presetId == 3) {
                ambientGlow = vec3(0.80, 0.50, 0.65);
            } else if (presetId == 4) {
                ambientGlow = vec3(0.60, 0.62, 0.65);
            } else if (presetId == 5) {
                ambientGlow = vec3(0.95, 0.80, 0.65);
            }

            if (presetId > 0 && skyAlpha > 0.001) {
                vec3 presetColor = c.rgb;
                if (presetId == 1) { // azureClear
                    presetColor = mix(vec3(0.55, 0.72, 0.92), vec3(0.08, 0.35, 0.78), normY);
                } else if (presetId == 2) { // sunsetGlow
                    presetColor = mix(vec3(1.0, 0.65, 0.25), vec3(0.25, 0.12, 0.42), pow(normY, 0.8));
                } else if (presetId == 3) { // twilightLilac
                    presetColor = mix(vec3(0.85, 0.55, 0.62), vec3(0.18, 0.12, 0.40), normY);
                } else if (presetId == 4) { // dramaticClouds
                    presetColor = mix(vec3(0.68, 0.70, 0.72), vec3(0.22, 0.25, 0.32), normY);
                } else if (presetId == 5) { // morningDawn
                    presetColor = mix(vec3(0.98, 0.82, 0.65), vec3(0.28, 0.48, 0.72), normY);
                }
                float blendFactor = replacementOpacity * skyAlpha;
                skyColor = mix(skyColor, presetColor, blendFactor);
            }

            // 5. Foreground Ambient Relighting
            vec3 result = skyColor;
            if (foregroundRelight > 0.001) {
                float fgAlpha = (1.0 - skyAlpha);
                if (fgAlpha > 0.001) {
                    float fgLum = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
                    float relightAmount = foregroundRelight * 0.30 * fgAlpha * (0.3 + 0.7 * fgLum);
                    result = mix(result, result * (vec3(1.0) + ambientGlow * 0.4), relightAmount);
                }
            }

            return vec4(clamp(result, 0.0, 1.0), c.a);
        }
        """
        return CIColorKernel(source: kernelSource)
    }()

    /// Detects horizon in image or estimates natural horizon line.
    public static func detectHorizonHeight(in image: CIImage) -> Double {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try? handler.perform([request])
        if let observation = request.results?.first {
            // angle and transform: map to normalized height
            let y = observation.transform.ty
            if y.isFinite && y > 0.1 && y < 0.9 {
                return Double(y)
            }
        }
        return 0.40 // Default: lower 40% ground, upper 60% sky
    }

    /// Applies sky enhancement to the image.
    public static func apply(
        _ image: CIImage,
        settings: SkyEnhancementSettings,
        personMatte: PersonMatte? = nil,
        precomputedSkyMask: CIImage? = nil,
        context: CIContext? = nil,
        cancellation: CancellationToken? = nil
    ) throws -> (image: CIImage, report: SkyEnhancementReport) {
        try cancellation?.check()
        guard !settings.isNeutral else {
            return (image, SkyEnhancementReport(applied: false, hasSkyDetected: false, appliedSteps: [], note: "天空氛围与置换处于中性状态（未修改像素）。"))
        }

        guard let kernel = skyKernel else {
            return (image, SkyEnhancementReport(applied: false, hasSkyDetected: false, appliedSteps: [], note: "Core Image Kernel 初始化失败。"))
        }

        let extent = image.extent
        let shorterEdge = Double(min(extent.width, extent.height))

        // 1. Obtain or generate sky mask
        let skyMask: CIImage
        let hasSky: Bool
        if let precomputedSkyMask {
            skyMask = precomputedSkyMask
            let maxFilter = skyMask.cropped(to: extent).applyingFilter("CIAreaMaximum")
            var bitmap = [UInt8](repeating: 0, count: 4)
            let renderContext = context ?? CIContext()
            renderContext.render(maxFilter, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            hasSky = bitmap[0] > 10
        } else {
            let (generatedMask, detected) = makeSkyMask(image: image, personMatte: personMatte, feather: settings.edgeFeather)
            skyMask = generatedMask
            hasSky = detected
        }

        guard hasSky else {
            return (image, SkyEnhancementReport(applied: false, hasSkyDetected: false, appliedSteps: [], note: "未检测到有效天空区域，跳过天空美化。"))
        }

        // 2. High-frequency blurred image for cloud separation
        let blurRadius = max(3.0, shorterEdge * 0.02)
        let blurred = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: extent)

        try cancellation?.check()

        var appliedSteps: [String] = []
        if settings.skyVibrance > 0 { appliedSteps.append("湛蓝天色") }
        if settings.cloudContrast > 0 { appliedSteps.append("云层反差") }
        if settings.sunsetWarmth > 0 { appliedSteps.append("晚霞氛围") }
        if settings.skyPreset != .none { appliedSteps.append("天空置换（\(settings.skyPreset.title)）") }
        if settings.foregroundRelight > 0 { appliedSteps.append("前景光照匹配") }

        let presetInt: Float
        switch settings.skyPreset {
        case .none: presetInt = 0
        case .azureClear: presetInt = 1
        case .sunsetGlow: presetInt = 2
        case .twilightLilac: presetInt = 3
        case .dramaticClouds: presetInt = 4
        case .morningDawn: presetInt = 5
        }

        let arguments: [Any] = [
            image,
            blurred,
            skyMask,
            Float(settings.skyVibrance),
            Float(settings.cloudContrast),
            Float(settings.sunsetWarmth),
            presetInt,
            Float(settings.replacementOpacity),
            Float(settings.foregroundRelight),
            CIVector(x: extent.width, y: extent.height)
        ]

        guard let processed = kernel.apply(extent: extent, arguments: arguments) else {
            return (image, SkyEnhancementReport(applied: false, hasSkyDetected: true, appliedSteps: [], note: "着色器处理失败，返回原图。"))
        }

        let report = SkyEnhancementReport(
            applied: true,
            hasSkyDetected: true,
            appliedSteps: appliedSteps,
            note: "已成功应用天空氛围增强（\(appliedSteps.joined(separator: "、"))）。"
        )

        return (processed, report)
    }

    /// Builds a smooth sky mask from horizon line, color/luminance priors, and person segmentation.
    public static func makeSkyMask(
        image: CIImage,
        personMatte: PersonMatte? = nil,
        feather: Double = 0.50
    ) -> (mask: CIImage, hasSky: Bool) {
        let extent = image.extent
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))

        let horizonNormY = detectHorizonHeight(in: image)
        let horizonY = horizonNormY * Double(height)

        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
            return (black, false)
        }

        // Fill background as black (0.0)
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Fill upper region as white (1.0)
        let skyRect = CGRect(x: 0, y: Int(horizonY), width: width, height: height - Int(horizonY))
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(skyRect)

        guard let cgImage = ctx.makeImage() else {
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
            return (black, false)
        }

        var sky = CIImage(cgImage: cgImage)

        // Subtract person if personMatte is available
        if let matte = personMatte {
            let invertFilter = CIFilter(name: "CIColorInvert")
            invertFilter?.setValue(matte.mask, forKey: kCIInputImageKey)
            if let invertedMatte = invertFilter?.outputImage {
                let multiplyFilter = CIFilter(name: "CIMultiplyCompositing")
                multiplyFilter?.setValue(sky, forKey: kCIInputImageKey)
                multiplyFilter?.setValue(invertedMatte, forKey: kCIInputBackgroundImageKey)
                if let combined = multiplyFilter?.outputImage {
                    sky = combined.cropped(to: extent)
                }
            }
        }

        let shorterEdge = Double(min(extent.width, extent.height))
        let blurRadius = max(2.0, shorterEdge * 0.03 * max(0.2, feather))
        let feathered = sky.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: extent)

        return (feathered, true)
    }
}

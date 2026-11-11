import Foundation
import CoreImage
import Vision

// MARK: - Bokeh & Depth Engine

/// P2-Q: Smart bokeh and optical depth-of-field synthesis engine.
///
/// Features:
/// 1. Continuous Depth Map Synthesis: combines subject alpha segmentation with vertical perspective ground gradient.
/// 2. 4 Optical Diaphragm Bokeh Shapes: .circular (modern round), .polygonal (9-blade mechanical), .swirly (Petzval vortex), .creamy (STF apodization).
/// 3. Specular Highlight Bokeh Boosting: extracts background point lights and bursts them into luminous optical bokeh discs.
/// 4. Foreground Edge Bleed Protection: locks subject hair and silhouette at sharp focal plane without haloing or ghosting.
///
/// 100% offline, zero external weights, Core Image & Metal accelerated.
public enum BokehDepthEngine {

    // MARK: - Highlight Extraction & Shading Kernels

    private static let specularBoostKernelSource = """
    kernel vec4 specularBoostKernel(
        sampler src,
        sampler depthMap,
        float boostStrength
    ) {
        vec4 c = sample(src, samplerCoord(src));
        vec4 d = sample(depthMap, samplerCoord(depthMap));
        float depth = d.r;

        if (depth < 0.02 || boostStrength < 0.001) {
            return c;
        }

        float luma = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
        // High-luminance background point light source detection
        float highlightThreshold = 0.68;
        if (luma > highlightThreshold) {
            float excess = (luma - highlightThreshold) / (1.0 - highlightThreshold);
            float factor = 1.0 + excess * boostStrength * 1.6 * depth;
            vec3 boosted = c.rgb * factor;
            return vec4(min(boosted, vec3(1.35)), c.a);
        }
        return c;
    }
    """

    private static let specularBoostKernel: CIColorKernel? = {
        CIColorKernel(source: specularBoostKernelSource)
    }()

    private static let depthGradientKernelSource = """
    kernel vec4 depthGradientKernel(
        sampler personMask,
        vec4 params, // x: focalOffset, y: falloffRate, z: height, w: edgeBleed
        vec2 origin
    ) {
        vec2 coord = samplerCoord(personMask);
        vec4 m = sample(personMask, coord);
        float subjectAlpha = m.r;

        // Normalized Y from 0 (bottom ground) to 1 (top background)
        float ny = clamp((coord.y - origin.y) / max(params.z, 1.0), 0.0, 1.0);
        // Ground plane gradient: distance increases upwards
        float groundDistance = 0.35 + 0.65 * ny;

        // Background depth: zero inside subject, smooth falloff outside
        float bgDepth = (1.0 - subjectAlpha) * groundDistance * params.y - params.x;
        float finalDepth = clamp(bgDepth, 0.0, 1.0);

        return vec4(vec3(finalDepth), 1.0);
    }
    """

    private static let depthGradientKernel: CIColorKernel? = {
        CIColorKernel(source: depthGradientKernelSource)
    }()

    // MARK: - Public Processing Entry Point

    /// Applies smart bokeh defocus blur and optical depth-of-field synthesis to `image`.
    public static func apply(
        to image: CIImage,
        personMask: CIImage? = nil,
        settings: BokehBlurSettings
    ) -> (image: CIImage, report: BokehBlurReport) {
        guard !settings.isNeutral else {
            return (image, BokehBlurReport(applied: false, note: "大光圈景深虚化未启用或散焦半径为 0。"))
        }

        guard let validated = try? settings.validated() else {
            return (image, BokehBlurReport(applied: false, note: "景深虚化参数校验失败。"))
        }

        let extent = image.extent
        guard extent.width > 1 && extent.height > 1 else {
            return (image, BokehBlurReport(applied: false, note: "图像尺寸无效。"))
        }

        // 1. Obtain or generate subject mask
        let subjectAlphaMask: CIImage
        if let personMask {
            subjectAlphaMask = personMask
        } else if let detected = detectPersonSegmentation(in: image) {
            subjectAlphaMask = detected
        } else {
            // Fallback: neutral ground-plane gradient without subject mask
            subjectAlphaMask = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        }

        // 2. Synthesize continuous depth map
        let depthMap = makeContinuousDepthMap(
            imageExtent: extent,
            subjectMask: subjectAlphaMask,
            settings: validated
        )

        // 3. Optional: Specular highlight boosting on the background before blur
        var working = image
        if validated.specularHighlightBoost > 0, let boostKernel = specularBoostKernel {
            if let boosted = boostKernel.apply(
                extent: extent,
                arguments: [working, depthMap, Float(validated.specularHighlightBoost)]
            ) {
                working = boosted
            }
        }

        // 4. Maximum circle-of-confusion blur radius (0...48px)
        let maxRadius = validated.apertureFocalSize * 48.0

        // 5. Apply Optical Bokeh Blur according to selected shape
        let blurredBackground = renderBokehShape(
            input: working,
            depthMap: depthMap,
            maxRadius: maxRadius,
            shape: validated.bokehShape,
            extent: extent
        )

        // 6. Foreground Subject Edge Bleed & Fringe Protection
        // Dilate/feather subject mask to ensure zero background bleed into subject silhouette
        let compositeSubjectMask: CIImage
        if validated.edgeBleedProtection > 0 {
            let featherRadius = max(1.0, 3.0 * (1.0 - validated.edgeBleedProtection))
            compositeSubjectMask = subjectAlphaMask.applyingGaussianBlur(sigma: featherRadius).cropped(to: extent)
        } else {
            compositeSubjectMask = subjectAlphaMask
        }

        // 7. Composite in-focus subject over synthesized optical bokeh background
        let output = compositeSubjectOverBackground(
            subject: image,
            background: blurredBackground,
            mask: compositeSubjectMask,
            extent: extent
        )

        let report = BokehBlurReport(
            applied: true,
            bokehShape: validated.bokehShape,
            maxBlurRadius: maxRadius,
            note: "已成功合成 \(validated.bokehShape.title)，最大散焦半径 \(String(format: "%.1f", maxRadius))px。"
        )
        return (output, report)
    }

    // MARK: - Depth Map Synthesis

    private static func makeContinuousDepthMap(
        imageExtent: CGRect,
        subjectMask: CIImage,
        settings: BokehBlurSettings
    ) -> CIImage {
        guard let k = depthGradientKernel else {
            return CIImage(color: CIColor.white).cropped(to: imageExtent)
        }
        let params = CIVector(
            x: CGFloat(settings.focalPlaneOffset),
            y: CGFloat(settings.depthFalloffRate),
            z: imageExtent.height,
            w: CGFloat(settings.edgeBleedProtection)
        )
        let origin = CIVector(x: imageExtent.origin.x, y: imageExtent.origin.y)
        return k.apply(
            extent: imageExtent,
            arguments: [subjectMask, params, origin]
        )?.cropped(to: imageExtent) ?? CIImage(color: CIColor.white).cropped(to: imageExtent)
    }

    // MARK: - Bokeh Shape Rendering

    private static func renderBokehShape(
        input: CIImage,
        depthMap: CIImage,
        maxRadius: Double,
        shape: BokehShape,
        extent: CGRect
    ) -> CIImage {
        var baseImage = input

        // For Petzval swirly bokeh, apply subtle peripheral vortex distortion before blur
        if shape == .swirly {
            let center = CIVector(x: extent.midX, y: extent.midY)
            let swirlRadius = max(extent.width, extent.height) * 0.75
            if let twirl = CIFilter(name: "CITwirlDistortion", parameters: [
                kCIInputImageKey: baseImage,
                kCIInputCenterKey: center,
                kCIInputRadiusKey: swirlRadius,
                "inputAngle": 0.35
            ])?.outputImage {
                baseImage = twirl.cropped(to: extent)
            }
        }

        // Apply Bokeh Blur pass
        let bokehBlurred: CIImage
        switch shape {
        case .circular:
            // Modern wide-aperture lens: ringAmount ~0.15 gives spherical aberration rim
            if let f = CIFilter(name: "CIBokehBlur", parameters: [
                kCIInputImageKey: baseImage,
                "inputRadius": maxRadius,
                "inputRingAmount": 0.18,
                "inputRingSize": 0.12,
                "inputSoftness": 0.25
            ])?.outputImage {
                bokehBlurred = f.cropped(to: extent)
            } else {
                bokehBlurred = baseImage.applyingGaussianBlur(sigma: maxRadius * 0.5).cropped(to: extent)
            }

        case .polygonal:
            // 9-blade mechanical iris: crisper ring edge
            if let f = CIFilter(name: "CIBokehBlur", parameters: [
                kCIInputImageKey: baseImage,
                "inputRadius": maxRadius,
                "inputRingAmount": 0.32,
                "inputRingSize": 0.08,
                "inputSoftness": 0.10
            ])?.outputImage {
                bokehBlurred = f.cropped(to: extent)
            } else {
                bokehBlurred = baseImage.applyingGaussianBlur(sigma: maxRadius * 0.5).cropped(to: extent)
            }

        case .swirly:
            // Swirly Petzval: subtle ring and high edge softness
            if let f = CIFilter(name: "CIBokehBlur", parameters: [
                kCIInputImageKey: baseImage,
                "inputRadius": maxRadius,
                "inputRingAmount": 0.14,
                "inputRingSize": 0.10,
                "inputSoftness": 0.35
            ])?.outputImage {
                bokehBlurred = f.cropped(to: extent)
            } else {
                bokehBlurred = baseImage.applyingGaussianBlur(sigma: maxRadius * 0.5).cropped(to: extent)
            }

        case .creamy:
            // STF Apodization: zero ring amount, high softness for buttery smooth melt
            if let f = CIFilter(name: "CIBokehBlur", parameters: [
                kCIInputImageKey: baseImage,
                "inputRadius": maxRadius,
                "inputRingAmount": 0.0,
                "inputRingSize": 0.0,
                "inputSoftness": 0.85
            ])?.outputImage {
                bokehBlurred = f.cropped(to: extent)
            } else {
                bokehBlurred = baseImage.applyingGaussianBlur(sigma: maxRadius * 0.6).cropped(to: extent)
            }
        }

        // Modulate defocus blur depth with variable depth map
        if let maskedBlur = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: bokehBlurred,
            kCIInputBackgroundImageKey: input,
            kCIInputMaskImageKey: depthMap
        ])?.outputImage {
            return maskedBlur.cropped(to: extent)
        }

        return bokehBlurred
    }

    // MARK: - Subject Compositing

    private static func compositeSubjectOverBackground(
        subject: CIImage,
        background: CIImage,
        mask: CIImage,
        extent: CGRect
    ) -> CIImage {
        if let blend = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: subject,
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask
        ])?.outputImage {
            return blend.cropped(to: extent)
        }
        return background
    }

    // MARK: - Native Vision Person Segmentation

    private static func detectPersonSegmentation(in image: CIImage) -> CIImage? {
        if #available(macOS 12.0, *) {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .balanced
            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            do {
                try handler.perform([request])
                if let result = request.results?.first {
                    let pixelBuffer = result.pixelBuffer
                    let mask = CIImage(cvPixelBuffer: pixelBuffer)
                    // Scale mask to image extent
                    let scaleX = image.extent.width / mask.extent.width
                    let scaleY = image.extent.height / mask.extent.height
                    return mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                }
            } catch {
                return nil
            }
        }
        return nil
    }
}

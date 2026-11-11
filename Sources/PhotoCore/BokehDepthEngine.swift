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

        // 8. P3-E3: report the depth field's real defocus radii (bottom vs top)
        let (nearRadius, farRadius) = sampleDepthRadii(depthMap: depthMap, maxRadius: maxRadius, extent: extent)

        let report = BokehBlurReport(
            applied: true,
            bokehShape: validated.bokehShape,
            maxBlurRadius: maxRadius,
            nearRadius: nearRadius,
            farRadius: farRadius,
            note: "已成功合成 \(validated.bokehShape.title)，近景半径 \(String(format: "%.1f", nearRadius))px，远景半径 \(String(format: "%.1f", farRadius))px。"
        )
        return (output, report)
    }

    /// Samples the synthesized depth field at bottom-center and top-center and
    /// converts the depth values into actual defocus radii, so the report
    /// reflects the ground-perspective modulation (not a constant).
    private static func sampleDepthRadii(
        depthMap: CIImage,
        maxRadius: Double,
        extent: CGRect
    ) -> (near: Double, far: Double) {
        let width = 4  // 64-byte row alignment for RGBAf rendering
        let sampleContext = CIContext(options: [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false
        ])
        // Render a single 1px row at a CIImage y (y=minY is the image bottom).
        func rowDepth(y: CGFloat) -> Double {
            var bitmap = [Float](repeating: 0, count: width * 4)
            sampleContext.render(
                depthMap, toBitmap: &bitmap, rowBytes: width * 4 * MemoryLayout<Float>.stride,
                bounds: CGRect(x: extent.minX, y: y, width: CGFloat(width), height: 1),
                format: .RGBAf, colorSpace: nil
            )
            let sum = (0..<width).reduce(Float(0)) { $0 + bitmap[$1 * 4] }
            return Double(sum / Float(width))
        }
        let nearDepth = rowDepth(y: extent.minY)          // bottom = near ground
        let farDepth = rowDepth(y: extent.maxY - 1)       // top = far background
        return (nearDepth * maxRadius, farDepth * maxRadius)
    }

    // MARK: - Depth Map Synthesis

    /// Builds the ground-plane component of the depth map as a rasterized
    /// linear gradient (bottom/near `0.35` → top/far `1.0`), then applies
    /// `depthFalloffRate` scaling and `focalPlaneOffset` via CIColorMatrix.
    ///
    /// Why a rasterized gradient instead of computing `ny` from `samplerCoord`
    /// inside the depth kernel: the kernel-based vertical position produced a
    /// spatially uniform depth map in production (measured P3-E3: identical
    /// blur at every row), so the ground-perspective modulation never reached
    /// the output. Values are stored directly in linear intensity (RGBAf,
    /// extended linear sRGB) so the engine's working-space conversion cannot
    /// skew them; bitmap row 0 maps to the image bottom (CIImage y=0).
    private static func makeGroundGradient(
        extent: CGRect,
        settings: BokehBlurSettings
    ) -> CIImage {
        let height = max(2, Int(extent.height))
        // 4px-wide column: CIImage(bitmapData:) requires 64-byte row alignment
        // (4px × 4 comps × 4B = 64B); narrower rows are misread.
        let width = 4
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            // CIImage(bitmapData:) row 0 renders at the image TOP: row 0 =
            // far (1.0), last row = near ground (0.35).
            let t = Double(row) / Double(height - 1) // 0 = image top (far)
            let v = Float(1.0 - t * 0.65)            // top 1.0 → bottom 0.35
            for col in 0..<width {
                let o = (row * width + col) * 4
                pixels[o] = v; pixels[o + 1] = v; pixels[o + 2] = v; pixels[o + 3] = 1
            }
        }
        let data = pixels.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let column = CIImage(bitmapData: data,
                             bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                             size: CGSize(width: CGFloat(width), height: CGFloat(height)),
                             format: .RGBAf, colorSpace: linearColorSpace)
            .transformed(by: CGAffineTransform(scaleX: max(extent.width, 1) / CGFloat(width),
                                               y: extent.height / CGFloat(height)))
            .cropped(to: extent)
        // depth = clamp(ground × falloff − focalOffset)
        let falloff = CGFloat(settings.depthFalloffRate)
        let offset = CGFloat(settings.focalPlaneOffset)
        return column
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: falloff, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: falloff, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: falloff, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -offset, y: -offset, z: -offset, w: 0)
            ])
            .applyingFilter("CIColorClamp")
            .cropped(to: extent)
    }

    private static func makeContinuousDepthMap(
        imageExtent: CGRect,
        subjectMask: CIImage,
        settings: BokehBlurSettings
    ) -> CIImage {
        // Ground perspective gradient (rasterized; see makeGroundGradient).
        let ground = makeGroundGradient(extent: imageExtent, settings: settings)
        // Zero inside the subject: depth = ground × (1 − subjectAlpha). The
        // mask may carry premultiplied color, so derive the subject weight from
        // ALPHA (mask.r can be premultiplied down) and multiply channels via
        // CIColorMatrix with the subject term as a per-channel coefficient:
        //   depth.r = ground.r × (1 − subjectAlpha)
        // CIColorMatrix cannot reference a second image, so combine with
        // CIBlendWithMask: where the subject weight is high the output must be
        // 0, where it is 0 the output is the ground gradient. blend(input=black,
        // background=ground, mask=subjectAlpha×1) gives ground×(1−alpha) with
        // exact linear semantics.
        let subjectWeight = subjectMask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),   // r_out = a_in
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ]).cropped(to: imageExtent)
        let black = CIImage(color: CIColor.clear).cropped(to: imageExtent)
        let depth = black
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputImageKey: black,
                kCIInputBackgroundImageKey: ground,
                kCIInputMaskImageKey: subjectWeight
            ])
            .cropped(to: imageExtent)
        return depth.cropped(to: imageExtent)
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

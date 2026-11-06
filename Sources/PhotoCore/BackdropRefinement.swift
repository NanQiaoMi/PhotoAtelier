import CoreGraphics
import CoreImage
import Foundation

/// Studio backdrop smoothing, wrinkle elimination, defect cleanup and color uniformity.
///
/// Designed for studio portraits, commercial lookbooks, and certificate photos where
/// the photographer wants to polish the seamless background paper, canvas, or cyclorama
/// wall (smoothing paper wrinkles, creases, scuffs, footprints and lighting falloff)
/// while strictly preserving the person, hair, wardrobe, and natural contact shadows.
public enum BackdropRefinementEngine {

    private static let backdropKernel: CIColorKernel? = {
        let source = """
        kernel vec4 applyBackdropRefine(__sample source, __sample smoothed,
                                        __sample backgroundMask, __sample avgColor,
                                        float smoothing, float cleanup, float uniformity) {
            float alpha = clamp(source.a, 0.0, 1.0);
            if (alpha <= 0.000001) { return vec4(0.0); }

            // Background mask: 1.0 in background, 0.0 on person
            float bgWeight = clamp(backgroundMask.r, 0.0, 1.0);
            // Erode/protect subject boundary: if bgWeight is low, preserve source
            bgWeight = smoothstep(0.15, 0.80, bgWeight);
            if (bgWeight <= 0.00001) {
                return source;
            }

            vec3 color = source.rgb;
            vec3 smoothColor = smoothed.rgb;
            vec3 dominant = avgColor.rgb;

            float lumaDiff = abs(dot(color - smoothColor, vec3(0.2126, 0.7152, 0.0722)));

            // 1. Wrinkles, seams and lighting gradient smoothing
            if (smoothing > 0.0001) {
                float isFoldOrGradient = 1.0 - smoothstep(0.25, 0.65, lumaDiff);
                float smoothFactor = smoothing * bgWeight * 0.95 * isFoldOrGradient;
                color = mix(color, smoothColor, clamp(smoothFactor, 0.0, 1.0));
            }

            // 2. High-contrast isolated defect, dust, footprint and scuff cleanup
            if (cleanup > 0.0001) {
                float isDefect = smoothstep(0.02, 0.30, lumaDiff);
                float cleanupFactor = cleanup * bgWeight * 0.95 * isDefect;
                color = mix(color, smoothColor, clamp(cleanupFactor, 0.0, 1.0));
            }

            // 3. Background color cast uniformity
            if (uniformity > 0.0001) {
                vec3 unified = mix(color, dominant, 0.50);
                color = mix(color, unified, clamp(uniformity * bgWeight * 0.70, 0.0, 1.0));
            }

            return vec4(color, source.a);
        }
        """
        return CIColorKernel(source: source)
    }()

    /// Applies backdrop refinement to `image`.
    ///
    /// - Parameters:
    ///   - image: Working canvas in linear sRGB.
    ///   - settings: Backdrop refinement controls.
    ///   - personMatte: Optional pre-computed person matte. If nil, will detect via `PersonMatting`.
    ///   - context: CIContext for rendering/evaluation.
    ///   - cancellation: Optional cancellation token.
    public static func apply(_ image: CIImage,
                             settings: BackdropRefinementSettings,
                             personMatte: PersonMatte?,
                             context: CIContext,
                             cancellation: CancellationToken? = nil) throws -> (image: CIImage, report: BackdropRefinementReport) {
        guard !settings.isNeutral else {
            return (image, BackdropRefinementReport(applied: false, note: "影棚背景修复未启用或参数全为中性。"))
        }
        _ = try settings.validated()

        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 1, extent.height > 1 else {
            return (image, BackdropRefinementReport(applied: false, note: "图像尺寸无效。"))
        }

        try cancellation?.check()

        // Resolve person matte gracefully
        let activeMatte: PersonMatte?
        if let personMatte {
            activeMatte = personMatte
        } else {
            activeMatte = try? PersonMatting.detect(in: image, context: context)
        }

        guard let activeMatte, activeMatte.hasPerson else {
            return (image, BackdropRefinementReport(applied: false, note: "未检测到人物主体，影棚背景修复已跳过。"))
        }

        try cancellation?.check()

        guard let kernel = backdropKernel else {
            throw AtelierError.invalidConfiguration("初始化背景精修着色器失败。")
        }

        // Invert person mask to obtain background mask
        guard let invertFilter = CIFilter(name: "CIColorInvert") else {
            throw AtelierError.invalidConfiguration("背景反相滤镜不可用。")
        }
        invertFilter.setValue(activeMatte.mask, forKey: kCIInputImageKey)
        guard let backgroundMask = invertFilter.outputImage?.cropped(to: extent) else {
            throw AtelierError.invalidConfiguration("生成背景蒙版失败。")
        }

        // Generate smoothed background reference
        let shorterEdge = Double(min(extent.width, extent.height))
        let sigma = max(6.0, min(36.0, shorterEdge * 0.035))
        let smoothed = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)

        // Generate average background color reference for uniformity
        let avgColorSource: CIImage
        if settings.uniformity > 0.0001, let avgFilter = CIFilter(name: "CIAreaAverage") {
            avgFilter.setValue(smoothed, forKey: kCIInputImageKey)
            avgFilter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
            avgColorSource = avgFilter.outputImage?.clampedToExtent() ?? smoothed
        } else {
            avgColorSource = smoothed
        }

        try cancellation?.check()

        guard let output = kernel.apply(
            extent: extent,
            arguments: [
                image,
                smoothed,
                backgroundMask,
                avgColorSource,
                Float(settings.smoothing),
                Float(settings.cleanup),
                Float(settings.uniformity)
            ]
        ) else {
            throw AtelierError.invalidConfiguration("背景着色器执行失败。")
        }

        var steps: [String] = []
        if settings.smoothing > 0 { steps.append("smoothing") }
        if settings.cleanup > 0 { steps.append("cleanup") }
        if settings.uniformity > 0 { steps.append("uniformity") }

        return (output, BackdropRefinementReport(applied: true, appliedSteps: steps))
    }
}

import CoreGraphics
import CoreImage
import Foundation

/// SDR output mapping. Reduces OKLab chroma along a constant hue at fixed
/// perceptual lightness, rather than clipping individual RGB channels.
public enum OutputGamutMapper {
    private static let kernel = CIColorKernel(source: """
    float signedRoot(float v) { return sign(v) * pow(abs(v), 1.0 / 3.0); }
    vec3 toLab(vec3 c) {
        vec3 lms = vec3(dot(c, vec3(0.4122214708, 0.5363325363, 0.0514459929)),
                        dot(c, vec3(0.2119034982, 0.6806995451, 0.1073969566)),
                        dot(c, vec3(0.0883024619, 0.2817188376, 0.6299787005)));
        lms = vec3(signedRoot(lms.r), signedRoot(lms.g), signedRoot(lms.b));
        return vec3(dot(lms, vec3(0.2104542553, 0.7936177850, -0.0040720468)),
                    dot(lms, vec3(1.9779984951, -2.4285922050, 0.4505937099)),
                    dot(lms, vec3(0.0259040371, 0.7827717662, -0.8086757660)));
    }
    vec3 fromLab(vec3 c) {
        vec3 v = vec3(c.r + 0.3963377774 * c.g + 0.2158037573 * c.b,
                      c.r - 0.1055613458 * c.g - 0.0638541728 * c.b,
                      c.r - 0.0894841775 * c.g - 1.2914855480 * c.b);
        v = v * v * v;
        return vec3(dot(v, vec3(4.0767416621, -3.3077115913, 0.2309699292)),
                    dot(v, vec3(-1.2684380046, 2.6097574011, -0.3413193965)),
                    dot(v, vec3(-0.0041960863, -0.7034186147, 1.7076147010)));
    }
    vec3 targetRGB(vec3 c, float p3) {
        if (p3 < 0.5) { return c; }
        return vec3(0.8224619687 * c.r + 0.1775380313 * c.g,
                    0.0331941989 * c.r + 0.9668058011 * c.g,
                    0.0170826307 * c.r + 0.0723974407 * c.g + 0.9105199286 * c.b);
    }
    float inside(vec3 c) {
        return min(min(c.r, c.g), c.b) >= 0.0 && max(max(c.r, c.g), c.b) <= 1.0 ? 1.0 : 0.0;
    }
    kernel vec4 outputGamut(__sample source, float p3) {
        float alpha = source.a;
        if (alpha <= 0.000001) { return vec4(0.0); }
        vec3 rgb = source.rgb / alpha;
        vec3 target = targetRGB(rgb, p3);
        if (inside(target) > 0.5) { return source; }
        vec3 lab = toLab(clamp(rgb, vec3(-65504.0), vec3(65504.0)));
        // SDR cannot retain superwhite lightness. No HDR recovery is implied.
        lab.r = clamp(lab.r, 0.00001, 0.99999);
        float low = 0.0;
        float high = 1.0;
        for (int i = 0; i < 14; i++) {
            float mid = (low + high) * 0.5;
            vec3 trial = fromLab(vec3(lab.r, lab.g * mid, lab.b * mid));
            if (inside(targetRGB(trial, p3)) > 0.5) { low = mid; }
            else { high = mid; }
        }
        vec3 mapped = fromLab(vec3(lab.r, lab.g * low, lab.b * low));
        return vec4(mapped * alpha, alpha);
    }
    """)

    public static func map(_ image: CIImage, to colorSpace: OutputColorSpace,
                           context: CIContext) throws -> CIImage {
        let extent = image.extent
        guard !extent.isNull, !extent.isInfinite, extent.width.isFinite,
              extent.height.isFinite, extent.width > 0, extent.height > 0 else {
            throw AtelierError.invalidConfiguration("输出色域映射需要有限且非空的图像。")
        }
        guard let kernel, let output = kernel.apply(extent: extent, arguments: [
            image, NSNumber(value: colorSpace == .displayP3 ? 1 : 0)
        ]) else {
            throw AtelierError.invalidConfiguration("输出色域映射 kernel 无法运行。")
        }
        return output.cropped(to: extent)
    }
}

extension OutputColorSpace {
    public var cgColorSpace: CGColorSpace {
        CGColorSpace(name: self == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3)!
    }
}

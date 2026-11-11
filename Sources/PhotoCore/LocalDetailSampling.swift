import CoreGraphics
import CoreImage
import Foundation

/// Ephemeral scale evidence for the effective selection, never a face position
/// or a target skin color. Radii refer to pixels of the current input image.
public struct LocalDetailSamplingPlan: Codable, Equatable {
    public let effectiveAreaPixels: Double
    public let fineRadius: Double
    public let coarseRadius: Double

    public init(effectiveAreaPixels: Double) {
        self.effectiveAreaPixels = effectiveAreaPixels
        let diameter = 2 * sqrt(max(0, effectiveAreaPixels) / .pi)
        fineRadius = min(3, max(0.5, diameter * 0.006))
        coarseRadius = min(18, max(2, diameter * 0.035))
    }

    static func validate(_ plan: Self) throws {
        guard plan.effectiveAreaPixels.isFinite, (0...120_000_000).contains(plan.effectiveAreaPixels),
              plan.fineRadius.isFinite, (0.5...3).contains(plan.fineRadius),
              plan.coarseRadius.isFinite, (2...18).contains(plan.coarseRadius),
              plan.coarseRadius > plan.fineRadius else {
            throw AtelierError.invalidConfiguration("局部细节的选区面积或采样尺度无效。")
        }
    }

    /// An overview measures area only, not noise or texture. Normalize by the
    /// selection peak so changing mask opacity does not change the spatial band.
    public static func measure(coverage: CIImage, reference: CIImage,
                               context: CIContext) throws -> Self {
        let extent = reference.extent
        guard extent == coverage.extent, !extent.isNull, !extent.isInfinite,
              extent.origin.x.isFinite, extent.origin.y.isFinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width >= 1, extent.height >= 1,
              extent.width * extent.height <= 120_000_000 else {
            throw AtelierError.invalidConfiguration("局部细节采样需要相同且有限的参考图与蒙版范围。")
        }
        let scale = min(1, 192 / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        func values(_ image: CIImage, numeric: Bool) -> [Float] {
            let sample = image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: .init(scaleX: CGFloat(width) / extent.width,
                                      y: CGFloat(height) / extent.height))
            var data = [Float](repeating: 0, count: width * height * 4)
            data.withUnsafeMutableBytes {
                context.render(sample, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                    bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
                    colorSpace: numeric ? nil : CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
            }
            return data
        }
        let masks = values(coverage, numeric: true), source = values(reference, numeric: false)
        let peak = stride(from: 0, to: masks.count, by: 4).compactMap { index -> Double? in
            let value = Double(masks[index])
            return value.isFinite ? min(1, max(0, value)) : nil
        }.max() ?? 0
        var weight = 0.0
        if peak > 0 {
            for index in stride(from: 0, to: masks.count, by: 4) {
                let alpha = Double(source[index + 3]), selection = Double(masks[index])
                guard alpha.isFinite, selection.isFinite else { continue }
                weight += min(1, max(0, alpha)) * min(1, max(0, selection / peak))
            }
        }
        let result = Self(effectiveAreaPixels: weight / Double(width * height)
            * Double(extent.width * extent.height))
        try validate(result)
        return result
    }
}

enum LocalDetailSampling {
    private static let extremaKernel = CIColorKernel(source: """
    kernel vec4 selectedDetailExtrema(__sample guide, __sample mask, float outsideValue) {
        float value = outsideValue;
        if (mask.r > 0.000001 && mask.r <= 1.0 && guide.a > 0.000001) {
            value = guide.r / guide.a;
        }
        // Opaque scalar data: morphology must compare normalized log luminance,
        // not premultiplied values or the mask's feathering/opacity.
        return vec4(value, value, value, 1.0);
    }
    """)
    private static let weightingKernel = CIColorKernel(source: """
    kernel vec4 weightDetailGuide(__sample guide, __sample mask) {
        float w = mask.r;
        if (!(w >= 0.0 && w <= 1.0) || !(guide.a > 0.000001)) { return vec4(0.0); }
        // The guide already carries source alpha. Weighted convolution followed
        // by division by blurred alpha normalizes only valid selected samples.
        return guide * w;
    }
    """)

    static func weighted(_ guide: CIImage, coverage: CIImage) throws -> CIImage {
        guard guide.extent == coverage.extent, let kernel = weightingKernel,
              let result = kernel.apply(extent: guide.extent, arguments: [guide, coverage]) else {
            throw AtelierError.invalidConfiguration("无法建立选区内细节采样图。")
        }
        return result
    }

    static func extremaGuide(_ guide: CIImage, coverage: CIImage, maximum: Bool) throws -> CIImage {
        guard guide.extent == coverage.extent, let kernel = extremaKernel,
              let result = kernel.apply(extent: guide.extent,
                  arguments: [guide, coverage, NSNumber(value: maximum ? -32.0 : 32.0)]) else {
            throw AtelierError.invalidConfiguration("无法建立选区内边缘保护采样图。")
        }
        return result
    }
}

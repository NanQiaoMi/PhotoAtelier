import CoreGraphics
import CoreImage
import Foundation

/// Weighted measurements of rendered color and light across a photograph.
/// Warm/cool values describe hue families in the rendered pixels; they are not
/// white-balance errors and cannot be converted to capture Kelvin.
public struct ColorSceneProfile: Codable, Equatable {
    public let sampleCount: Int
    /// Alpha-weighted visible fraction with HSV-like saturation above 0.12 and hue below 70° or at/above 330°.
    public let warmFraction: Double
    /// Alpha-weighted visible fraction with HSV-like saturation above 0.12 and hue from 70° through below 330°.
    public let coolFraction: Double
    /// Alpha-weighted visible fraction with HSV-like saturation at or below 0.12.
    public let neutralFraction: Double
    /// Alpha-weighted visible fraction with HSV-like saturation at or above 0.55.
    public let saturatedFraction: Double
    /// Alpha-weighted visible fraction with extended-linear-sRGB luminance at or below 0.12.
    public let darkFraction: Double
    /// Alpha-weighted visible fraction with extended-linear-sRGB luminance at or above 0.72.
    public let brightFraction: Double
    /// Shannon entropy of 12 hue buckets for non-neutral pixels, normalized by ln(12).
    public let colorDiversity: Double
    public let summary: String
    public let regions: [ColorSceneRegion]

    public init(sampleCount: Int, warmFraction: Double, coolFraction: Double,
                neutralFraction: Double, saturatedFraction: Double,
                darkFraction: Double, brightFraction: Double,
                colorDiversity: Double, summary: String,
                regions: [ColorSceneRegion]) {
        self.sampleCount = sampleCount
        self.warmFraction = warmFraction
        self.coolFraction = coolFraction
        self.neutralFraction = neutralFraction
        self.saturatedFraction = saturatedFraction
        self.darkFraction = darkFraction
        self.brightFraction = brightFraction
        self.colorDiversity = colorDiversity
        self.summary = summary
        self.regions = regions
    }
}

public struct ColorSceneRegion: Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let direction: String
    public let luminance: Double
    public let saturation: Double
    /// Fraction of the image's visible alpha weight falling in this region.
    public let coverage: Double
    /// Region center in normalized image coordinates, origin at top left.
    public let normalizedCenterX: Double
    public let normalizedCenterY: Double

    public init(id: String, title: String, summary: String, direction: String,
                luminance: Double, saturation: Double, coverage: Double,
                normalizedCenterX: Double, normalizedCenterY: Double) {
        self.id = id
        self.title = title
        self.summary = summary
        self.direction = direction
        self.luminance = luminance
        self.saturation = saturation
        self.coverage = coverage
        self.normalizedCenterX = normalizedCenterX
        self.normalizedCenterY = normalizedCenterY
    }
}

/// Samples a bounded raster and reports pixel statistics, not semantic object masks.
/// The supplied context must be configured for unpremultiplied bitmap output.
public enum ColorSceneAnalyzer {
    private static let maximumDimension = 192
    private static let hueBucketCount = 12

    private struct RegionAccumulator {
        var alphaWeight = 0.0
        var luminanceSum = 0.0
        var saturationSum = 0.0
    }

    public static func analyze(image: CIImage, context: CIContext) throws -> ColorSceneProfile {
        let extent = image.extent
        guard !extent.isNull, !extent.isInfinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else {
            throw AtelierError.invalidConfiguration("照片必须有有限且非空的图像范围，无法分析色彩分布。")
        }

        let scale = min(1, CGFloat(maximumDimension) / max(extent.width, extent.height))
        let width = max(1, Int(ceil(extent.width * scale)))
        let height = max(1, Int(ceil(extent.height * scale)))
        guard width <= maximumDimension, height <= maximumDimension,
              width.multipliedReportingOverflow(by: height).overflow == false else {
            throw AtelierError.invalidConfiguration("照片色彩分析采样尺寸无效。")
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // The supplied context controls output alpha mode. PhotoAnalyzer and the
        // test contexts render unpremultiplied RGBA; applying an unpremultiply
        // filter here as well would divide translucent RGB twice.
        let sampledImage = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: bounds)
        let pixelCount = width * height
        var pixels = [Float](repeating: 0, count: pixelCount * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            context.render(sampledImage, toBitmap: baseAddress,
                           rowBytes: width * 4 * MemoryLayout<Float>.stride,
                           bounds: bounds, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        }

        var validCount = 0
        var totalAlpha = 0.0
        var warmWeight = 0.0, coolWeight = 0.0, neutralWeight = 0.0
        var saturatedWeight = 0.0, darkWeight = 0.0, brightWeight = 0.0
        var hueWeights = Array(repeating: 0.0, count: hueBucketCount)
        var regions = Array(repeating: RegionAccumulator(), count: 9)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let rawAlpha = Double(pixels[offset + 3])
                guard rawAlpha.isFinite, rawAlpha > 0.001 else { continue }
                let alpha = min(1, rawAlpha)
                let red = Double(pixels[offset])
                let green = Double(pixels[offset + 1])
                let blue = Double(pixels[offset + 2])
                guard red.isFinite, green.isFinite, blue.isFinite else { continue }

                validCount += 1
                totalAlpha += alpha
                // Luminance and saturation use the unpremultiplied pixel color;
                // alpha controls its contribution rather than dimming its color.
                let luminance = max(0, 0.2126 * red + 0.7152 * green + 0.0722 * blue)
                let hueRed = max(0, red), hueGreen = max(0, green), hueBlue = max(0, blue)
                let maximum = max(hueRed, max(hueGreen, hueBlue))
                let minimum = min(hueRed, min(hueGreen, hueBlue))
                let chroma = max(0, maximum - minimum)
                let saturation = maximum > 0.0001 ? min(1, chroma / maximum) : 0

                if luminance <= 0.12 { darkWeight += alpha }
                if luminance >= 0.72 { brightWeight += alpha }
                if saturation <= 0.12 {
                    neutralWeight += alpha
                } else {
                    let hue = hueDegrees(red: hueRed, green: hueGreen, blue: hueBlue,
                                         maximum: maximum, chroma: chroma)
                    let bucket = min(hueBucketCount - 1, Int(hue / 360 * Double(hueBucketCount)))
                    hueWeights[bucket] += alpha
                    if saturation >= 0.55 { saturatedWeight += alpha }
                    if hue < 70 || hue >= 330 {
                        warmWeight += alpha
                    } else {
                        coolWeight += alpha
                    }
                }

                // Core Image bitmap rows are addressed from the top edge here;
                // the 3x3 grid is positional guidance and never object segmentation.
                let column = min(2, x * 3 / width)
                let row = min(2, y * 3 / height)
                let regionIndex = row * 3 + column
                regions[regionIndex].alphaWeight += alpha
                regions[regionIndex].luminanceSum += luminance * alpha
                regions[regionIndex].saturationSum += saturation * alpha
            }
        }

        let profileRegions = (0..<9).map { index -> ColorSceneRegion in
            let accumulator = regions[index]
            let row = index / 3, column = index % 3
            let title = regionTitle(row: row, column: column)
            let coverage = totalAlpha > 0 ? accumulator.alphaWeight / totalAlpha : 0
            let luminance = accumulator.alphaWeight > 0
                ? accumulator.luminanceSum / accumulator.alphaWeight : 0
            let saturation = accumulator.alphaWeight > 0
                ? accumulator.saturationSum / accumulator.alphaWeight : 0
            let summary = regionSummary(luminance: luminance, saturation: saturation,
                                       hasPixels: accumulator.alphaWeight > 0)
            let direction = regionDirection(title: title, luminance: luminance,
                                            saturation: saturation,
                                            hasPixels: accumulator.alphaWeight > 0)
            return ColorSceneRegion(id: "region.\(row).\(column)", title: title,
                                    summary: summary, direction: direction,
                                    luminance: luminance, saturation: saturation,
                                    coverage: coverage,
                                    normalizedCenterX: (Double(column) + 0.5) / 3,
                                    normalizedCenterY: (Double(row) + 0.5) / 3)
        }

        guard totalAlpha > 0 else {
            return ColorSceneProfile(sampleCount: 0, warmFraction: 0, coolFraction: 0,
                                     neutralFraction: 0, saturatedFraction: 0,
                                     darkFraction: 0, brightFraction: 0, colorDiversity: 0,
                                     summary: "采样范围内没有可见像素，无法判断整体色彩与明暗。",
                                     regions: profileRegions)
        }

        let warm = warmWeight / totalAlpha
        let cool = coolWeight / totalAlpha
        let neutral = neutralWeight / totalAlpha
        let saturated = saturatedWeight / totalAlpha
        let dark = darkWeight / totalAlpha
        let bright = brightWeight / totalAlpha
        let chromaticWeight = hueWeights.reduce(0, +)
        let entropy: Double
        if chromaticWeight > 0 {
            entropy = -hueWeights.reduce(0.0) { partial, weight in
                guard weight > 0 else { return partial }
                let probability = weight / chromaticWeight
                return partial + probability * log(probability)
            } / log(Double(hueBucketCount))
        } else {
            entropy = 0
        }
        let diversity = min(1, max(0, entropy))
        let summary = makeSummary(warm: warm, cool: cool, neutral: neutral,
                                  saturated: saturated, dark: dark,
                                  bright: bright, diversity: diversity)
        return ColorSceneProfile(sampleCount: validCount, warmFraction: warm,
                                 coolFraction: cool, neutralFraction: neutral,
                                 saturatedFraction: saturated, darkFraction: dark,
                                 brightFraction: bright, colorDiversity: diversity,
                                 summary: summary, regions: profileRegions)
    }

    private static func hueDegrees(red: Double, green: Double, blue: Double,
                                   maximum: Double, chroma: Double) -> Double {
        guard chroma > 0.000001 else { return 0 }
        let value: Double
        if maximum == red {
            value = 60 * ((green - blue) / chroma).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            value = 60 * ((blue - red) / chroma + 2)
        } else {
            value = 60 * ((red - green) / chroma + 4)
        }
        return value < 0 ? value + 360 : value
    }

    private static func regionTitle(row: Int, column: Int) -> String {
        switch (row, column) {
        case (0, 0): return "左上区域"
        case (0, 1): return "上方中央区域"
        case (0, 2): return "右上区域"
        case (1, 0): return "左侧中央区域"
        case (1, 1): return "中央区域"
        case (1, 2): return "右侧中央区域"
        case (2, 0): return "左下区域"
        case (2, 1): return "下方中央区域"
        default: return "右下区域"
        }
    }

    private static func regionSummary(luminance: Double, saturation: Double,
                                      hasPixels: Bool) -> String {
        guard hasPixels else { return "没有可见像素。" }
        let light = luminance <= 0.12 ? "偏暗" : (luminance >= 0.72 ? "偏亮" : "亮度居中")
        let color = saturation <= 0.12 ? "色彩较淡" : (saturation >= 0.55 ? "色彩浓郁" : "色彩适中")
        return "\(light)，\(color)（平均亮度 \(Int((luminance * 100).rounded()))%，彩度 \(Int((saturation * 100).rounded()))%）。"
    }

    private static func regionDirection(title: String, luminance: Double,
                                        saturation: Double, hasPixels: Bool) -> String {
        guard hasPixels else { return "此处没有可见色彩样本，可忽略该区域提示。" }
        if luminance <= 0.12 {
            return "检查\(title)的主体细节；若需要，可轻提阴影并保留全图明暗关系。"
        }
        if luminance >= 0.72 {
            return "检查\(title)的高光纹理；若细节仍在，可轻收高光，避免整体压暗。"
        }
        if saturation >= 0.55 {
            return "\(title)已有较浓色彩；可先保持这里的彩度，再比较全图色彩调整。"
        }
        if saturation <= 0.12 {
            return "\(title)色彩较克制；若想增加氛围，可从小幅全图调整开始并复核肤色与中性物体。"
        }
        return "\(title)的亮度与彩度较均衡；如需强调主体，可比较该处与周围区域的明暗。"
    }

    private static func makeSummary(warm: Double, cool: Double, neutral: Double,
                                    saturated: Double, dark: Double, bright: Double,
                                    diversity: Double) -> String {
        let overall: String
        if neutral >= 0.55 { overall = "中性色占主导" }
        else if warm - cool >= 0.10 { overall = "暖色较多" }
        else if cool - warm >= 0.10 { overall = "冷色较多" }
        else { overall = "冷暖颜色分布接近" }
        let hueSpread = diversity < 0.30 ? "色相较集中" : (diversity < 0.68 ? "色相分布适中" : "色相覆盖较广")
        return String(format: "整体%@：暖色 %.0f%%、冷色 %.0f%%、中性色 %.0f%%；高彩度区域 %.0f%%，暗部 %.0f%%、亮部 %.0f%%。%@。暖冷描述画面像素色相，不代表白平衡误差或拍摄色温。",
                      overall, warm * 100, cool * 100, neutral * 100,
                      saturated * 100, dark * 100, bright * 100, hueSpread)
    }
}

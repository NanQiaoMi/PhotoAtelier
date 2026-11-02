import CoreGraphics
import CoreImage
import Foundation

public enum MaskCombineMode: String, Codable, CaseIterable {
    case add, subtract, intersect

    public var title: String {
        switch self {
        case .add: return "添加"
        case .subtract: return "减去"
        case .intersect: return "相交"
        }
    }
}

public struct MaskComponent: Codable, Equatable, Identifiable {
    public var id: UUID
    public var operation: MaskCombineMode
    public var kind: MaskKind
    public var start: MaskPoint
    public var end: MaskPoint
    public var points: [MaskPoint]
    public var radius: Double
    public var feather: Double

    public init(id: UUID = UUID(), operation: MaskCombineMode = .add,
                kind: MaskKind = .brush,
                start: MaskPoint = .init(x: 0.5, y: 0.5),
                end: MaskPoint = .init(x: 0.75, y: 0.75),
                points: [MaskPoint] = [], radius: Double = 0.12, feather: Double = 0.65) {
        self.id = id; self.operation = operation; self.kind = kind
        self.start = start; self.end = end; self.points = points
        self.radius = radius; self.feather = feather
    }
}

public struct MaskColor: Codable, Equatable {
    /// sRGB-encoded channel values in 0...1.
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }
}

public enum MaskStage: String, Codable, CaseIterable {
    case beforeLook, afterLook

    public var title: String {
        switch self {
        case .beforeLook: return "LUT 前"
        case .afterLook: return "LUT 后"
        }
    }
}

public struct MaskInspection: Equatable {
    public var coverage: Double
    public var medianLuminance: Double
    public var highlightFraction: Double
    public var shadowFraction: Double
    public var summary: String
    public var suggestedExposureEV: Double
    public var suggestedHighlights: Double
    public var suggestedShadows: Double
    public var lightGuidance: LocalLightGuidance?

    public init(coverage: Double, medianLuminance: Double,
                highlightFraction: Double, shadowFraction: Double,
                summary: String, suggestedExposureEV: Double,
                suggestedHighlights: Double, suggestedShadows: Double,
                lightGuidance: LocalLightGuidance? = nil) {
        self.coverage = coverage; self.medianLuminance = medianLuminance
        self.highlightFraction = highlightFraction; self.shadowFraction = shadowFraction
        self.summary = summary; self.suggestedExposureEV = suggestedExposureEV
        self.suggestedHighlights = suggestedHighlights
        self.suggestedShadows = suggestedShadows
        self.lightGuidance = lightGuidance
    }
}

enum LocalMaskValidator {
    static func validate(_ mask: LocalMask) throws {
        func require(_ value: Double, _ range: ClosedRange<Double>, _ label: String) throws {
            guard value.isFinite, range.contains(value) else {
                throw AtelierError.invalidConfiguration("蒙版\(label)超出允许范围 \(range.lowerBound)...\(range.upperBound)。")
            }
        }
        func point(_ value: MaskPoint, _ label: String) throws {
            try require(value.x, 0...1, "\(label) X")
            try require(value.y, 0...1, "\(label) Y")
        }

        guard mask.name.count <= 256 else {
            throw AtelierError.invalidConfiguration("蒙版名称不能超过 256 个字符。")
        }
        try point(mask.start, "起点")
        try point(mask.end, "终点")
        try require(mask.radius, 0...1, "半径")
        try require(mask.feather, 0...1, "羽化")
        try require(mask.exposureEV, -8...8, "曝光")
        try require(mask.saturation, 0...4, "饱和度")
        try require(mask.warmth, -1...1, "暖度")
        try require(mask.opacity, 0...1, "不透明度")
        try require(mask.tint, -1...1, "色调")
        try require(mask.contrast, 0...4, "对比度")
        try require(mask.highlights, -1...1, "高光")
        try require(mask.shadows, -1...1, "阴影")
        try require(mask.sharpness, 0...2, "锐化")
        try require(mask.highlightProtection, 0...1, "高光保护")
        try require(mask.colorProtection, 0...1, "颜色保护")
        try require(mask.luminanceMin, 0...1, "亮度下限")
        try require(mask.luminanceMax, 0...1, "亮度上限")
        guard mask.luminanceMin <= mask.luminanceMax else {
            throw AtelierError.invalidConfiguration("蒙版亮度下限不能高于上限。")
        }
        try require(mask.rangeSoftness, 0...1, "范围羽化")
        try require(mask.color.red, 0...1, "目标颜色红通道")
        try require(mask.color.green, 0...1, "目标颜色绿通道")
        try require(mask.color.blue, 0...1, "目标颜色蓝通道")
        // Color-distance values are normalized Delta E 76 (distance / 100).
        try require(mask.colorTolerance, 0...1, "颜色容差")
        try require(mask.colorSoftness, 0...1, "颜色范围羽化")
        if let detail = mask.detail { try LocalDetailEngine.validate(detail) }
        guard mask.contentSelection == nil || mask.kind == .luminance else {
            throw AtelierError.invalidConfiguration("内容感知选区必须使用全范围亮度基础，再通过修边限定。")
        }
        guard mask.points.count <= 4096, mask.components.count <= 64 else {
            throw AtelierError.invalidConfiguration("蒙版笔迹不能超过 4096 点，几何组件不能超过 64 个。")
        }

        var identifiers: Set<UUID> = [mask.id]
        var pointCount = mask.points.count
        for value in mask.points { try point(value, "画笔点") }
        for component in mask.components {
            guard identifiers.insert(component.id).inserted else {
                throw AtelierError.invalidConfiguration("蒙版中存在重复的组件标识。")
            }
            guard component.kind == .radial || component.kind == .linear || component.kind == .brush else {
                throw AtelierError.invalidConfiguration("几何组件只能使用径向、渐变或画笔类型。")
            }
            try point(component.start, "组件起点")
            try point(component.end, "组件终点")
            try require(component.radius, 0...1, "组件半径")
            try require(component.feather, 0...1, "组件羽化")
            guard component.points.count <= 4096 else {
                throw AtelierError.invalidConfiguration("单条蒙版笔迹不能超过 4096 点。")
            }
            pointCount += component.points.count
            for value in component.points { try point(value, "组件画笔点") }
        }
        guard pointCount <= 32768 else {
            throw AtelierError.invalidConfiguration("蒙版总点数不能超过 32768。")
        }
    }
}

enum LocalMaskEngine {
    private static let maximumRasterDimension = 2048
    private static let grayColorSpace = CGColorSpace(name: CGColorSpace.linearGray)!

    private static let combineKernel = CIColorKernel(source: """
    kernel vec4 combineCoverage(__sample current, __sample component, float operation) {
        float a = current.r;
        float b = component.r;
        float value = operation < 0.5 ? max(a, b)
                    : (operation < 1.5 ? a * (1.0 - b) : a * b);
        return vec4(value, value, value, 1.0);
    }
    """)

    private static let rangeKernel = CIColorKernel(source: """
    float encodeSRGB(float value) {
        value = clamp(value, 0.0, 1.0);
        return value <= 0.0031308 ? 12.92 * value
                                  : 1.055 * pow(value, 1.0 / 2.4) - 0.055;
    }
    float decodeSRGB(float value) {
        value = clamp(value, 0.0, 1.0);
        return value <= 0.04045 ? value / 12.92
                                : pow((value + 0.055) / 1.055, 2.4);
    }
    float labF(float value) {
        return value > 0.008856451679 ? pow(value, 1.0 / 3.0)
                                     : 7.787037 * value + 0.1379310345;
    }
    vec3 labFromLinearRGB(vec3 rgb) {
        float x = (0.4124564 * rgb.r + 0.3575761 * rgb.g + 0.1804375 * rgb.b) / 0.95047;
        float y = 0.2126729 * rgb.r + 0.7151522 * rgb.g + 0.0721750 * rgb.b;
        float z = (0.0193339 * rgb.r + 0.1191920 * rgb.g + 0.9503041 * rgb.b) / 1.08883;
        float fx = labF(max(x, 0.0));
        float fy = labF(max(y, 0.0));
        float fz = labF(max(z, 0.0));
        return vec3(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz));
    }
    float smoothRange(float value, float minimum, float maximum, float softness) {
        float lower = 1.0;
        float upper = 1.0;
        if (minimum > 0.0) {
            lower = softness > 0.000001
                ? smoothstep(minimum - softness * 0.5, minimum + softness * 0.5, value)
                : step(minimum, value);
        }
        if (maximum < 1.0) {
            upper = softness > 0.000001
                ? 1.0 - smoothstep(maximum - softness * 0.5, maximum + softness * 0.5, value)
                : 1.0 - step(maximum, value);
        }
        return lower * upper;
    }
    kernel vec4 applyRanges(__sample geometry, __sample reference,
                           float invert, float invertAfterRange, float luminanceEnabled,
                           float luminanceMin, float luminanceMax, float rangeSoftness,
                           float colorEnabled, vec3 targetColor,
                           float colorTolerance, float colorSoftness,
                           float opacity) {
        float alpha = reference.a;
        vec3 linear = alpha > 0.000001 ? reference.rgb / alpha : vec3(0.0);
        float coverage = geometry.r;
        if (invert > 0.5) { coverage = 1.0 - coverage; }
        if (luminanceEnabled > 0.5) {
            vec3 srgb = vec3(encodeSRGB(linear.r), encodeSRGB(linear.g), encodeSRGB(linear.b));
            float luminance = dot(srgb, vec3(0.2126, 0.7152, 0.0722));
            coverage *= smoothRange(luminance, luminanceMin, luminanceMax, rangeSoftness);
        }
        if (colorEnabled > 0.5) {
            vec3 targetLinear = vec3(decodeSRGB(targetColor.r), decodeSRGB(targetColor.g), decodeSRGB(targetColor.b));
            vec3 sourceLab = labFromLinearRGB(clamp(linear, vec3(0.0), vec3(1.0)));
            vec3 targetLab = labFromLinearRGB(targetLinear);
            float distance = length(sourceLab - targetLab) / 100.0;
            float upper = colorTolerance + colorSoftness;
            float match = colorSoftness > 0.000001
                ? 1.0 - smoothstep(colorTolerance, upper, distance)
                : (distance <= colorTolerance + 0.00001 ? 1.0 : 0.0);
            coverage *= match;
        }
        if (invertAfterRange > 0.5) { coverage = 1.0 - coverage; }
        coverage = clamp(coverage * opacity, 0.0, 1.0);
        return vec4(coverage, coverage, coverage, 1.0);
    }
    """)

    private static let protectionBlendKernel = CIColorKernel(source: """
    kernel vec4 blendProtected(__sample original, __sample adjusted,
                               __sample coverage,
                               float highlightProtection, float colorProtection) {
        float alpha = clamp(original.a, 0.0, 1.0);
        if (alpha <= 0.000001) { return vec4(0.0); }
        vec3 source = original.rgb / alpha;
        float adjustedAlpha = max(adjusted.a, 0.000001);
        vec3 changed = adjusted.rgb / adjustedAlpha;
        float sourceLuma = dot(source, vec3(0.2126, 0.7152, 0.0722));
        float changedLuma = dot(changed, vec3(0.2126, 0.7152, 0.0722));

        // Compare chroma only after matching the source to the adjusted luminance.
        // This leaves exposure intact and only limits added color on already-colorful pixels.
        vec3 exposureMatchedSource = source;
        if (abs(sourceLuma) > 0.0001) {
            // Local exposure accepts -8...8 EV, so exact exposure matching needs
            // a ratio range that includes 2^8 (256) without falsely labeling it chroma.
            float ratio = clamp(changedLuma / sourceLuma, -256.0, 256.0);
            exposureMatchedSource = source * ratio;
        }
        float sourceRange = max(max(source.r, source.g), source.b)
                          - min(min(source.r, source.g), source.b);
        float matchedRange = max(max(exposureMatchedSource.r, exposureMatchedSource.g),
                                 exposureMatchedSource.b)
                            - min(min(exposureMatchedSource.r, exposureMatchedSource.g),
                                  exposureMatchedSource.b);
        float changedRange = max(max(changed.r, changed.g), changed.b)
                           - min(min(changed.r, changed.g), changed.b);
        float sourceChroma = sourceRange / max(abs(sourceLuma), 0.025);
        float extraChroma = max(0.0, changedRange - matchedRange) / max(abs(changedLuma), 0.025);
        float colorfulSource = smoothstep(0.10, 0.35, sourceChroma);
        float addedColor = smoothstep(0.015, 0.12, extraChroma);
        float colorGuard = clamp(colorProtection * colorfulSource * addedColor, 0.0, 1.0);
        vec3 protectedChange = mix(changed, exposureMatchedSource, colorGuard);

        float brightening = smoothstep(0.0001, 0.03, max(changedLuma - sourceLuma, 0.0));
        float highlightWeight = smoothstep(0.65, 1.2, max(sourceLuma, 0.0));
        float highGuard = 1.0 - highlightProtection * highlightWeight * brightening;
        float weight = clamp(coverage.r * highGuard, 0.0, 1.0);
        vec3 result = mix(source, protectedChange, weight);
        return vec4(result * alpha, alpha);
    }
    """)

    static func isLegacyCompatibleAfterLook(_ mask: LocalMask) -> Bool {
        mask.stage == .afterLook && mask.components.isEmpty && mask.opacity == 1 &&
        mask.contentSelection == nil && (mask.detail?.isNeutral ?? true) &&
        mask.tint == 0 && mask.contrast == 1 && mask.highlights == 0 && mask.shadows == 0 &&
        mask.sharpness == 0 && mask.highlightProtection == 0 && mask.colorProtection == 0 &&
        !mask.restrictLuminance && !mask.restrictColor && mask.kind != .luminance && mask.kind != .color
    }

    static func coverage(for mask: LocalMask, reference: CIImage,
                         context: CIContext, contentSelections: ContentSelectionResult? = nil) throws -> CIImage {
        try LocalMaskValidator.validate(mask)
        let extent = reference.extent
        guard !extent.isNull, !extent.isInfinite, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else {
            throw AtelierError.invalidConfiguration("蒙版参考图必须有有限且非空的图像范围。")
        }
        guard mask.enabled, mask.opacity > 0, mask.kind != .brush || !mask.points.isEmpty || !mask.components.isEmpty else {
            return CIImage(color: .black).cropped(to: extent)
        }

        var contentImage: CIImage?
        if let target = mask.contentSelection {
            let result = try contentSelections ?? ContentSelectionAnalyzer.analyze(
                reference: reference, targets: [target], context: context)
            // A failed/empty semantic selection must remain empty, including
            // inverted masks and additions that would otherwise cover the frame.
            guard let detected = result.image(for: target) else {
                return CIImage(color: .black).cropped(to: extent)
            }
            guard detected.extent == extent else {
                throw AtelierError.invalidConfiguration("内容感知选区与参考图范围不一致。")
            }
            contentImage = detected
        }
        let baseKind: MaskKind = (mask.kind == .luminance || mask.kind == .color) ? .radial : mask.kind
        var combined: CIImage
        if let contentImage {
            combined = contentImage
        } else if mask.kind == .luminance || mask.kind == .color {
            combined = CIImage(color: .white).cropped(to: extent)
        } else {
            combined = try geometry(kind: baseKind, start: mask.start, end: mask.end,
                                    points: mask.points, radius: mask.radius,
                                    feather: mask.feather, extent: extent)
        }
        for component in mask.components {
            if component.kind == .brush, component.points.isEmpty { continue }
            let componentImage = try geometry(kind: component.kind, start: component.start,
                                              end: component.end, points: component.points,
                                              radius: component.radius, feather: component.feather,
                                              extent: extent)
            guard let kernel = combineKernel,
                  let output = kernel.apply(extent: extent, arguments: [
                    combined, componentImage,
                    NSNumber(value: component.operation == .add ? 0 : (component.operation == .subtract ? 1 : 2))
                  ]) else {
                throw AtelierError.invalidConfiguration("蒙版几何组件合并失败。")
            }
            combined = output.cropped(to: extent)
        }

        let luminanceEnabled = mask.kind == .luminance || mask.restrictLuminance
        let colorEnabled = mask.kind == .color || mask.restrictColor
        if !luminanceEnabled && !colorEnabled {
            // Geometry-only coverage must not trigger another RAW decode or
            // global correction pass during full-resolution local compositing.
            var output = combined
            if mask.inverted { output = output.applyingFilter("CIColorInvert") }
            if mask.opacity != 1 {
                output = output.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: CGFloat(mask.opacity), y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: CGFloat(mask.opacity), z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(mask.opacity), w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])
            }
            return output.cropped(to: extent)
        }
        let isRangeKind = mask.kind == .luminance || mask.kind == .color
        guard let kernel = rangeKernel,
              let output = kernel.apply(extent: extent, arguments: [
                combined, reference,
                NSNumber(value: mask.inverted && !isRangeKind ? 1 : 0),
                NSNumber(value: mask.inverted && isRangeKind ? 1 : 0),
                NSNumber(value: luminanceEnabled ? 1 : 0),
                NSNumber(value: mask.luminanceMin), NSNumber(value: mask.luminanceMax),
                NSNumber(value: mask.rangeSoftness),
                NSNumber(value: colorEnabled ? 1 : 0),
                CIVector(x: CGFloat(mask.color.red), y: CGFloat(mask.color.green), z: CGFloat(mask.color.blue)),
                NSNumber(value: mask.colorTolerance), NSNumber(value: mask.colorSoftness),
                NSNumber(value: mask.opacity)
              ]) else {
            throw AtelierError.invalidConfiguration("蒙版亮度/颜色范围无法生成覆盖图。")
        }
        return output.cropped(to: extent)
    }

    static func apply(_ mask: LocalMask, to image: CIImage, reference: CIImage,
                      context: CIContext, contentSelections: ContentSelectionResult? = nil,
                      makeFilter: (String) throws -> CIFilter,
                      applyTemperature: (Double, Double, CIImage) throws -> CIImage) throws -> CIImage {
        let extent = image.extent
        guard mask.enabled, mask.opacity > 0 else { return image }
        let coverageImage = try coverage(for: mask, reference: reference, context: context,
                                         contentSelections: contentSelections)
        if let target = mask.contentSelection, let contentSelections,
           contentSelections.image(for: target) == nil { return image }
        var adjusted = image
        if abs(mask.exposureEV) > 0.0001 {
            let filter = try makeFilter("CIExposureAdjust")
            filter.setValue(adjusted, forKey: kCIInputImageKey)
            filter.setValue(NSNumber(value: mask.exposureEV), forKey: "inputEV")
            guard let result = filter.outputImage else {
                throw AtelierError.invalidConfiguration("局部曝光无法生成输出。")
            }
            adjusted = result.cropped(to: extent)
        }
        if abs(mask.warmth) > 0.0001 || abs(mask.tint) > 0.0001 {
            adjusted = try applyTemperature(mask.warmth, mask.tint, adjusted).cropped(to: extent)
        }
        if mask.saturation != 1 || mask.contrast != 1 || mask.highlights != 0 || mask.shadows != 0 {
            guard let kernel = PhotoEngine.localToneKernel,
                  let output = kernel.apply(extent: extent, arguments: [
                    adjusted, NSNumber(value: mask.saturation), NSNumber(value: mask.contrast),
                    NSNumber(value: mask.highlights), NSNumber(value: mask.shadows)
                  ]) else {
                throw AtelierError.invalidConfiguration("局部色调 kernel 无法生成输出。")
            }
            adjusted = output.cropped(to: extent)
        }
        if let detail = mask.detail, !detail.isNeutral {
            adjusted = try LocalDetailEngine.apply(adjusted, settings: detail)
        }
        if mask.sharpness > 0.0001 {
            let filter = try makeFilter("CIUnsharpMask")
            let normalizedRadius = max(0.5, min(extent.width, extent.height) * 0.0015)
            filter.setValue(adjusted.clampedToExtent(), forKey: kCIInputImageKey)
            filter.setValue(NSNumber(value: Double(normalizedRadius)), forKey: kCIInputRadiusKey)
            filter.setValue(NSNumber(value: mask.sharpness), forKey: kCIInputIntensityKey)
            guard let output = filter.outputImage else {
                throw AtelierError.invalidConfiguration("局部锐化无法生成输出。")
            }
            adjusted = output.cropped(to: extent)
        }
        guard let blend = protectionBlendKernel,
              let output = blend.apply(extent: extent, arguments: [
                image, adjusted, coverageImage,
                NSNumber(value: mask.highlightProtection), NSNumber(value: mask.colorProtection)
              ]) else {
            throw AtelierError.invalidConfiguration("局部调整保护合成失败。")
        }
        return output.cropped(to: extent)
    }

    static func sampleColor(at point: MaskPoint, reference: CIImage,
                            context: CIContext) throws -> MaskColor {
        let extent = reference.extent
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y),
              !extent.isNull, !extent.isInfinite, extent.width > 0, extent.height > 0 else {
            throw AtelierError.invalidConfiguration("取色位置或参考图范围无效。")
        }
        let centerX = extent.minX + CGFloat(point.x) * extent.width
        let centerY = extent.minY + CGFloat(point.y) * extent.height
        let size = min(5.0, max(1.0, min(extent.width, extent.height) / 256.0))
        let regionSize = min(size, min(extent.width, extent.height))
        let clampedCenterX = min(extent.maxX - regionSize * 0.5,
                                 max(extent.minX + regionSize * 0.5, centerX))
        let clampedCenterY = min(extent.maxY - regionSize * 0.5,
                                 max(extent.minY + regionSize * 0.5, centerY))
        let region = CGRect(x: clampedCenterX - regionSize * 0.5,
                            y: clampedCenterY - regionSize * 0.5,
                            width: min(regionSize, extent.width),
                            height: min(regionSize, extent.height)).intersection(extent)
        let bounds = CGRect(x: 0, y: 0, width: 3, height: 3)
        let sampled = reference.cropped(to: region).transformed(by: CGAffineTransform(
            scaleX: 3 / max(region.width, 0.0001), y: 3 / max(region.height, 0.0001)))
            .transformed(by: CGAffineTransform(translationX: -region.minX * 3 / max(region.width, 0.0001),
                                                y: -region.minY * 3 / max(region.height, 0.0001)))
        let aligned = sampled.cropped(to: bounds)
        var pixels = [Float](repeating: 0, count: 3 * 3 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            context.render(aligned, toBitmap: address, rowBytes: 3 * 4 * MemoryLayout<Float>.size,
                           bounds: bounds, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        }
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var totalWeight = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3])
            guard alpha.isFinite, alpha > 0.001 else { continue }
            // PhotoEngine.context renders unpremultiplied RGBA. Keep its linear
            // RGB values as-is and use alpha only as the sample weight; dividing
            // by alpha here brightens fractional edge pixels and skews color picks.
            red += Double(pixels[offset]) * alpha
            green += Double(pixels[offset + 1]) * alpha
            blue += Double(pixels[offset + 2]) * alpha
            totalWeight += alpha
        }
        guard totalWeight > 0 else {
            throw AtelierError.invalidConfiguration("取色位置没有有效图像像素。")
        }
        return MaskColor(red: encodeSRGB(red / totalWeight),
                         green: encodeSRGB(green / totalWeight),
                         blue: encodeSRGB(blue / totalWeight))
    }

    static func inspect(_ mask: LocalMask, reference: CIImage,
                        context: CIContext, coverageImage suppliedCoverage: CIImage? = nil) throws -> MaskInspection {
        try LocalMaskValidator.validate(mask)
        let extent = reference.extent
        let coverageImage: CIImage
        if let suppliedCoverage {
            coverageImage = suppliedCoverage
        } else {
            coverageImage = try coverage(for: mask, reference: reference, context: context)
        }
        let dimension = min(384, max(1, Int(ceil(max(extent.width, extent.height)))))
        let width = max(1, Int((extent.width / max(extent.width, extent.height) * CGFloat(dimension)).rounded()))
        let height = max(1, Int((extent.height / max(extent.width, extent.height) * CGFloat(dimension)).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        func thumbnail(_ image: CIImage) -> CIImage {
            let translated = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            let scaled = translated.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width,
                                                                        y: CGFloat(height) / extent.height))
            return scaled.cropped(to: bounds)
        }
        var refPixels = [Float](repeating: 0, count: width * height * 4)
        var maskPixels = [Float](repeating: 0, count: width * height * 4)
        func render(_ image: CIImage, into pixels: inout [Float]) {
            pixels.withUnsafeMutableBytes { buffer in
                guard let address = buffer.baseAddress else { return }
                context.render(thumbnail(image), toBitmap: address,
                               rowBytes: width * 4 * MemoryLayout<Float>.size,
                               bounds: bounds, format: .RGBAf,
                               colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
            }
        }
        render(reference, into: &refPixels)
        render(coverageImage, into: &maskPixels)

        var selected: [WeightedValue] = []
        var globalSamples: [WeightedValue] = []
        var lightSamples: [LocalLightSample] = []
        selected.reserveCapacity(width * height / 2)
        globalSamples.reserveCapacity(width * height)
        lightSamples.reserveCapacity(width * height)
        var totalAlphaWeight = 0.0
        var totalCoverage = 0.0
        var totalWeight = 0.0
        var highlights = 0.0
        var shadows = 0.0
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            let alpha = Double(refPixels[offset + 3])
            guard alpha.isFinite, alpha > 0.001 else { continue }
            // PhotoEngine.context renders unpremultiplied RGBA. Read linear RGB
            // directly; use alpha as the area weight instead of dividing by it.
            let r = Double(refPixels[offset])
            let g = Double(refPixels[offset + 1])
            let b = Double(refPixels[offset + 2])
            guard r.isFinite, g.isFinite, b.isFinite else { continue }
            let luminance = srgbLuminance(r, g, b)
            let linearLuminance = max(0, 0.2126 * r + 0.7152 * g + 0.0722 * b)
            let globalWeight = min(1, max(0, alpha))
            let maskWeight = min(1, max(0, Double(maskPixels[offset])))
            let selectedWeight = globalWeight * maskWeight
            lightSamples.append(LocalLightSample(luminance: linearLuminance,
                maximumChannel: max(r, max(g, b)), alpha: globalWeight, coverage: maskWeight))
            globalSamples.append(WeightedValue(value: luminance, linearValue: linearLuminance,
                                               weight: globalWeight))
            totalAlphaWeight += globalWeight
            totalCoverage += selectedWeight
            if selectedWeight > 0.0001 {
                selected.append(WeightedValue(value: luminance, linearValue: linearLuminance,
                                              weight: selectedWeight))
                totalWeight += selectedWeight
                if luminance >= 0.8 { highlights += selectedWeight }
                if luminance <= 0.18 { shadows += selectedWeight }
            }
        }
        let coverageFraction = totalAlphaWeight > 0 ? totalCoverage / totalAlphaWeight : 0
        guard !selected.isEmpty, totalWeight >= 2 else {
            return MaskInspection(coverage: coverageFraction, medianLuminance: 0,
                                  highlightFraction: 0, shadowFraction: 0,
                                  summary: coverageFraction < 0.005
                                    ? String(format: "有效蒙版覆盖 %.3f%%，低于 0.5%%，不提供区域建议；选区不是主体识别。", coverageFraction * 100)
                                    : "蒙版区域没有足够的有效图像样本；选区不是主体识别。",
                                  suggestedExposureEV: 0, suggestedHighlights: 0, suggestedShadows: 0)
        }
        guard coverageFraction > 0.005 else {
            return MaskInspection(coverage: coverageFraction, medianLuminance: 0,
                                  highlightFraction: 0, shadowFraction: 0,
                                  summary: String(format: "有效蒙版覆盖 %.3f%%，低于 0.5%%，不提供区域建议；选区不是主体识别。", coverageFraction * 100),
                                  suggestedExposureEV: 0, suggestedHighlights: 0, suggestedShadows: 0)
        }
        selected.sort { $0.value < $1.value }
        let median = weightedMedian(selected, totalWeight: totalWeight, linear: false)
        globalSamples.sort { $0.value < $1.value }
        let globalMedian = weightedMedian(globalSamples, totalWeight: totalAlphaWeight, linear: false)
        let selectedHighlightFraction = highlights / totalWeight
        let selectedShadowFraction = shadows / totalWeight
        let guidance = LocalLightGuidancePlanner.assess(lightSamples)
        let ev = guidance?.suggestedExposureEV ?? 0
        let summary = String(format: "覆盖 %.1f%% · 区域中位 sRGB 亮度 %.2f（全图 %.2f）· 高光 %.0f%% · 阴影 %.0f%% · 候选曝光 %+.2f EV。%@ 选区不是主体识别。",
                             coverageFraction * 100, median, globalMedian,
                             selectedHighlightFraction * 100, selectedShadowFraction * 100, ev,
                             guidance?.reason ?? "有效样本不足，保留原值。")
        return MaskInspection(coverage: coverageFraction, medianLuminance: median,
                              highlightFraction: selectedHighlightFraction,
                              shadowFraction: selectedShadowFraction, summary: summary,
                              suggestedExposureEV: ev, suggestedHighlights: 0,
                              suggestedShadows: 0, lightGuidance: guidance)
    }

    private static func geometry(kind: MaskKind, start: MaskPoint, end: MaskPoint,
                                  points: [MaskPoint], radius: Double, feather: Double,
                                  extent: CGRect) throws -> CIImage {
        if kind == .luminance || kind == .color {
            return CIImage(color: .white).cropped(to: extent)
        }
        let scale = min(1, CGFloat(maximumRasterDimension) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        guard let bitmap = CGContext(data: nil, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: grayColorSpace,
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw AtelierError.invalidConfiguration("无法分配蒙版灰度栅格。")
        }
        bitmap.setFillColor(gray: 0, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.setStrokeColor(gray: 1, alpha: 1)
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.setShouldAntialias(true)
        let minDimension = CGFloat(min(width, height))
        let brushRadius = CGFloat(radius) * minDimension

        switch kind {
        case .radial:
            let center = pixelPoint(start, width: width, height: height)
            let radiusX = max(abs(end.x - start.x) * Double(width), 0.5)
            let radiusY = max(abs(end.y - start.y) * Double(height), 0.5)
            bitmap.saveGState()
            bitmap.translateBy(x: center.x, y: center.y)
            bitmap.scaleBy(x: radiusX, y: radiusY)
            if feather <= 0.0001 {
                bitmap.fillEllipse(in: CGRect(x: -1, y: -1, width: 2, height: 2))
            } else {
                guard let gradient = CGGradient(colorsSpace: grayColorSpace,
                                                colors: [CGColor(gray: 1, alpha: 1),
                                                         CGColor(gray: 1, alpha: 1),
                                                         CGColor(gray: 0, alpha: 1)] as CFArray,
                                                locations: [0, max(0, 1 - feather), 1]) else {
                    bitmap.restoreGState()
                    throw AtelierError.invalidConfiguration("径向蒙版羽化创建失败。")
                }
                bitmap.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                          endCenter: .zero, endRadius: 1, options: [])
            }
            bitmap.restoreGState()

        case .linear:
            let first = pixelPoint(start, width: width, height: height)
            let second = pixelPoint(end, width: width, height: height)
            let dx = second.x - first.x
            let dy = second.y - first.y
            let length = max(hypot(dx, dy), 1)
            let direction = CGPoint(x: dx / length, y: dy / length)
            let transitionLength = max(length * CGFloat(feather), 1)
            let center = CGPoint(x: (first.x + second.x) * 0.5, y: (first.y + second.y) * 0.5)
            guard let gradient = CGGradient(colorsSpace: grayColorSpace,
                                            colors: [CGColor(gray: 1, alpha: 1),
                                                     CGColor(gray: 0, alpha: 1)] as CFArray,
                                            locations: [0, 1]) else {
                throw AtelierError.invalidConfiguration("线性蒙版渐变创建失败。")
            }
            bitmap.drawLinearGradient(gradient,
                                      start: CGPoint(x: center.x - direction.x * transitionLength * 0.5,
                                                     y: center.y - direction.y * transitionLength * 0.5),
                                      end: CGPoint(x: center.x + direction.x * transitionLength * 0.5,
                                                   y: center.y + direction.y * transitionLength * 0.5),
                                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        case .brush:
            let pathPoints = points.map { pixelPoint($0, width: width, height: height) }
            if !pathPoints.isEmpty {
                bitmap.setLineWidth(max(brushRadius * 2, 1))
                bitmap.setLineCap(.round)
                bitmap.setLineJoin(.round)
                if pathPoints.count == 1, let only = pathPoints.first {
                    bitmap.fillEllipse(in: CGRect(x: only.x - brushRadius, y: only.y - brushRadius,
                                                  width: brushRadius * 2, height: brushRadius * 2))
                } else if let first = pathPoints.first {
                    let path = CGMutablePath()
                    path.move(to: first)
                    for value in pathPoints.dropFirst() { path.addLine(to: value) }
                    bitmap.addPath(path)
                    bitmap.strokePath()
                }
            }

        case .luminance, .color:
            break
        }

        guard let cgImage = bitmap.makeImage() else {
            throw AtelierError.invalidConfiguration("蒙版灰度栅格无法生成图像。")
        }
        let raster = CIImage(cgImage: cgImage, options: [.colorSpace: grayColorSpace])
        var softened = raster
        if kind == .brush, feather > 0.0001, !points.isEmpty {
            // Radius is calculated in the bounded raster's coordinate system, then
            // scaled with the raster so output resolution does not change softness.
            let blurRadius = max(0.5, brushRadius * CGFloat(feather) * 0.5)
            guard let blur = CIFilter(name: "CIGaussianBlur") else {
                throw AtelierError.invalidConfiguration("当前系统不支持画笔羽化滤镜。")
            }
            blur.setValue(raster, forKey: kCIInputImageKey)
            blur.setValue(NSNumber(value: Double(blurRadius)), forKey: kCIInputRadiusKey)
            guard let output = blur.outputImage else {
                throw AtelierError.invalidConfiguration("画笔羽化无法生成输出。")
            }
            softened = output.cropped(to: raster.extent)
        }
        let scaleX = extent.width / CGFloat(width)
        let scaleY = extent.height / CGFloat(height)
        return softened.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    private static func pixelPoint(_ point: MaskPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(x: point.x * Double(width), y: point.y * Double(height))
    }

    private static func encodeSRGB(_ value: Double) -> Double {
        let clamped = min(1, max(0, value))
        return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }

    private static func srgbLuminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let red = encodeSRGB(r)
        let green = encodeSRGB(g)
        let blue = encodeSRGB(b)
        return min(1, max(0, 0.2126 * red + 0.7152 * green + 0.0722 * blue))
    }

    private static func weightedMedian(_ values: [WeightedValue], totalWeight: Double,
                                       linear: Bool) -> Double {
        let ordered = linear ? values.sorted { $0.linearValue < $1.linearValue } : values
        var accumulated = 0.0
        for value in ordered {
            accumulated += value.weight
            if accumulated >= totalWeight * 0.5 {
                return linear ? value.linearValue : value.value
            }
        }
        guard let last = ordered.last else { return 0 }
        return linear ? last.linearValue : last.value
    }

    private struct WeightedValue {
        let value: Double
        let linearValue: Double
        let weight: Double
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value))
    }
}

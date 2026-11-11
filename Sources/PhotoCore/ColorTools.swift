import CoreGraphics
import CoreImage
import Foundation

// MARK: - Shared kernel math

/// Shared Core Image kernel-language snippets for the P1 color tools.
///
/// All color tools operate on **extended linear sRGB** (the engine's working
/// space) and convert to OKLab internally so hue/saturation/lightness edits are
/// perceptual. Kernels are kept as string snippets so each engine compiles one
/// self-contained kernel with the conversions it needs.
internal enum ColorToolKernelMath {
    /// OKLab conversion used by the HSL and color-grading kernels.
    ///
    /// The matrices are the standard Björn Ottosson OKLab coefficients, matching
    /// `OutputGamut.swift` and `ColorHarmony.swift` so the tools agree with the
    /// existing engine on what "OKLab" means.
    static let oklabFunctions = """
    float signedCubeRoot(float value) {
        return sign(value) * pow(abs(value), 1.0 / 3.0);
    }
    vec3 rgbToOKLab(vec3 rgb) {
        float l = 0.4122214708 * rgb.r + 0.5363325363 * rgb.g + 0.0514459929 * rgb.b;
        float m = 0.2119034982 * rgb.r + 0.6806995451 * rgb.g + 0.1073969566 * rgb.b;
        float s = 0.0883024619 * rgb.r + 0.2817188376 * rgb.g + 0.6299787005 * rgb.b;
        vec3 roots = vec3(signedCubeRoot(l), signedCubeRoot(m), signedCubeRoot(s));
        return vec3(
            0.2104542553 * roots.x + 0.7936177850 * roots.y - 0.0040720468 * roots.z,
            1.9779984951 * roots.x - 2.4285922050 * roots.y + 0.4505937099 * roots.z,
            0.0259040371 * roots.x + 0.7827717662 * roots.y - 0.8086757660 * roots.z
        );
    }
    vec3 oklabToRGB(vec3 lab) {
        float l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
        float m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
        float s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
        l = l * l * l;
        m = m * m * m;
        s = s * s * s;
        return vec3(
             4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        );
    }
    """

    /// sRGB display-transfer encode/decode used by the curve stage. The curve
    /// stage deliberately works in display-encoded sRGB so a curve drawn in a
    /// photo editor matches what the user sees, not linear light.
    static let srgbFunctions = """
    vec3 colorToolSRGBEncode(vec3 linear) {
        vec3 clamped = clamp(linear, vec3(0.0), vec3(1.0));
        vec3 low = clamped * 12.92;
        vec3 high = 1.055 * pow(clamped, vec3(1.0 / 2.4)) - 0.055;
        return mix(high, low, step(clamped, vec3(0.0031308)));
    }
    vec3 colorToolSRGBDecode(vec3 encoded) {
        vec3 clamped = clamp(encoded, vec3(0.0), vec3(1.0));
        vec3 low = clamped / 12.92;
        vec3 high = pow((clamped + 0.055) / 1.055, vec3(2.4));
        return mix(high, low, step(clamped, vec3(0.04045)));
    }
    """
}

// MARK: - Validation helpers

internal enum ColorToolValidation {
    static func require(_ value: Double, within range: ClosedRange<Double>, named name: String) throws {
        guard value.isFinite, range.contains(value) else {
            throw AtelierError.invalidConfiguration(
                "\(name) 必须是 \(range.lowerBound)...\(range.upperBound) 的有限数值。")
        }
    }

    /// Finite, non-empty extent required by every color-tool engine.
    static func validExtent(of image: CIImage) throws -> CGRect {
        let extent = image.extent
        guard !extent.isNull, !extent.isInfinite,
              extent.minX.isFinite, extent.minY.isFinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else {
            throw AtelierError.invalidConfiguration("调色工具需要有限且非空的图像范围。")
        }
        return extent
    }
}

// MARK: - HSL

/// The eight hue bands used by the HSL tool.
///
/// Band centers are evenly spaced OKLab hue angles (0°, 45°, … 315°). OKLab hue
/// is a perceptual angle, not a color-name wheel: sRGB primaries sit at roughly
/// 29° (red), 142° (green) and 264° (blue). The evenly spaced centers follow the
/// product design (8 color bands) and are documented here so callers do not
/// expect band centers to line up with hue names.
public enum HSLBand: String, Codable, CaseIterable, Equatable {
    case red, orange, yellow, green, cyan, blue, purple, magenta

    /// Center of the band in OKLab hue degrees (0...360).
    public var hueCenterDegrees: Double {
        switch self {
        case .red: return 0
        case .orange: return 45
        case .yellow: return 90
        case .green: return 135
        case .cyan: return 180
        case .blue: return 225
        case .purple: return 270
        case .magenta: return 315
        }
    }
}

/// One hue-band adjustment.
///
/// - `hueShiftDegrees` rotates the band's OKLab hue (-180...180).
/// - `saturation` scales OKLab chroma (-1...1; -1 removes the band's color,
///   +1 doubles it, clamped by the engine's chroma ceiling).
/// - `luminance` adds perceptual lightness (-1...1; ±0.15 OKLab L at full range).
public struct HSLBandAdjustment: Codable, Equatable {
    public var hueShiftDegrees: Double
    public var saturation: Double
    public var luminance: Double

    public init(hueShiftDegrees: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hueShiftDegrees = hueShiftDegrees
        self.saturation = saturation
        self.luminance = luminance
    }

    /// True when this band cannot change pixels.
    public var isNeutral: Bool {
        hueShiftDegrees == 0 && saturation == 0 && luminance == 0
    }
}

/// Eight-band HSL tool settings.
///
/// This is a pure value type: it does not touch pixels and is stored as-is in a
/// v11 recipe by the integration layer. Bands use a cosine window of ±45°, so a
/// pixel at one band's center receives weight 1 from that band, 0 from the
/// adjacent centers and a smooth 0.5 at the midpoint between two centers.
///
/// Neutral protection: the engine only applies band changes above a small OKLab
/// chroma threshold, so near-gray pixels are not tinted by a hue-band edit.
public struct HSLSettings: Codable, Equatable {
    public var red = HSLBandAdjustment()
    public var orange = HSLBandAdjustment()
    public var yellow = HSLBandAdjustment()
    public var green = HSLBandAdjustment()
    public var cyan = HSLBandAdjustment()
    public var blue = HSLBandAdjustment()
    public var purple = HSLBandAdjustment()
    public var magenta = HSLBandAdjustment()

    public init() {}

    public subscript(band: HSLBand) -> HSLBandAdjustment {
        get {
            switch band {
            case .red: return red
            case .orange: return orange
            case .yellow: return yellow
            case .green: return green
            case .cyan: return cyan
            case .blue: return blue
            case .purple: return purple
            case .magenta: return magenta
            }
        }
        set {
            switch band {
            case .red: red = newValue
            case .orange: orange = newValue
            case .yellow: yellow = newValue
            case .green: green = newValue
            case .cyan: cyan = newValue
            case .blue: blue = newValue
            case .purple: purple = newValue
            case .magenta: magenta = newValue
            }
        }
    }

    /// All bands in hue order.
    public var allBands: [(band: HSLBand, adjustment: HSLBandAdjustment)] {
        HSLBand.allCases.map { ($0, self[$0]) }
    }

    /// True when every band is neutral; the engine then returns the input image
    /// object unchanged (exact identity).
    public var isNeutral: Bool {
        HSLBand.allCases.allSatisfy { self[$0].isNeutral }
    }

    public func validate() throws {
        for band in HSLBand.allCases {
            let adjustment = self[band]
            try ColorToolValidation.require(adjustment.hueShiftDegrees, within: -180...180,
                                            named: "\(band.rawValue) 色相偏移")
            try ColorToolValidation.require(adjustment.saturation, within: -1...1,
                                            named: "\(band.rawValue) 饱和度")
            try ColorToolValidation.require(adjustment.luminance, within: -1...1,
                                            named: "\(band.rawValue) 亮度")
        }
    }
}

/// HSL eight-band engine.
///
/// Pipeline stage: after the basic tone stage and the curve stage, before color
/// grading (see `ColorToolsEngine`). Works in OKLab/OKLCh on extended linear
/// sRGB input and returns display-clamped [0,1] linear RGB, matching the rest of
/// the v11 color-tool chain.
///
/// Limits: the eight bands are a fixed hue partition with a ±45° cosine window;
/// very saturated colors can fall between band centers, and the chroma ceiling
/// (0.45 OKLab) plus the per-pixel guard prevent extreme clipping. This is a
/// color-grading heuristic, not a semantic color selector.
public enum HSLEngine {
    /// Chroma below this is treated as neutral and left untouched by band edits.
    public static let neutralChromaThreshold = 0.004
    /// Chroma guard fully opens at this value.
    public static let neutralChromaFullWeight = 0.025
    /// Maximum OKLab chroma after a band edit.
    public static let maximumChroma = 0.45
    /// OKLab lightness change at `luminance == ±1`.
    public static let luminanceRange = 0.15

    private static let kernel = CIColorKernel(source: ColorToolKernelMath.oklabFunctions + """
    float hslBandWeight(float hue, float center) {
        float distance = abs(hue - center);
        distance = min(distance, 360.0 - distance);
        float t = clamp(distance / 45.0, 0.0, 1.0);
        return 0.5 + 0.5 * cos(t * 3.14159265358979323846);
    }
    kernel vec4 applyHSLBands(__sample source,
                              float h0, float s0, float l0,
                              float h1, float s1, float l1,
                              float h2, float s2, float l2,
                              float h3, float s3, float l3,
                              float h4, float s4, float l4,
                              float h5, float s5, float l5,
                              float h6, float s6, float l6,
                              float h7, float s7, float l7) {
        float alpha = clamp(source.a, 0.0, 1.0);
        if (alpha <= 0.000001) { return vec4(0.0); }
        vec3 rgb = clamp(source.rgb / alpha, vec3(0.0), vec3(1.0));
        vec3 lab = rgbToOKLab(rgb);
        float chroma = length(lab.yz);
        if (chroma <= 0.000001) { return vec4(rgb * alpha, alpha); }
        float hue = atan(lab.z, lab.y) * 57.29577951308232;
        float hueShift = 0.0;
        float saturation = 0.0;
        float luminance = 0.0;
        hueShift += hslBandWeight(hue,   0.0) * h0; saturation += hslBandWeight(hue,   0.0) * s0; luminance += hslBandWeight(hue,   0.0) * l0;
        hueShift += hslBandWeight(hue,  45.0) * h1; saturation += hslBandWeight(hue,  45.0) * s1; luminance += hslBandWeight(hue,  45.0) * l1;
        hueShift += hslBandWeight(hue,  90.0) * h2; saturation += hslBandWeight(hue,  90.0) * s2; luminance += hslBandWeight(hue,  90.0) * l2;
        hueShift += hslBandWeight(hue, 135.0) * h3; saturation += hslBandWeight(hue, 135.0) * s3; luminance += hslBandWeight(hue, 135.0) * l3;
        hueShift += hslBandWeight(hue, 180.0) * h4; saturation += hslBandWeight(hue, 180.0) * s4; luminance += hslBandWeight(hue, 180.0) * l4;
        hueShift += hslBandWeight(hue, 225.0) * h5; saturation += hslBandWeight(hue, 225.0) * s5; luminance += hslBandWeight(hue, 225.0) * l5;
        hueShift += hslBandWeight(hue, 270.0) * h6; saturation += hslBandWeight(hue, 270.0) * s6; luminance += hslBandWeight(hue, 270.0) * l6;
        hueShift += hslBandWeight(hue, 315.0) * h7; saturation += hslBandWeight(hue, 315.0) * s7; luminance += hslBandWeight(hue, 315.0) * l7;
        float guard = smoothstep(0.004, 0.025, chroma);
        float rotateRadians = hueShift * guard * 0.017453292519943295;
        float cosine = cos(rotateRadians);
        float sine = sin(rotateRadians);
        vec2 rotated = vec2(lab.y * cosine - lab.z * sine,
                            lab.y * sine + lab.z * cosine);
        float targetChroma = clamp(chroma * (1.0 + saturation * guard), 0.0, 0.45);
        vec2 targetAB = normalize(rotated) * targetChroma;
        float targetL = clamp(lab.x + luminance * guard * 0.15, 0.0, 1.0);
        vec3 outputRGB = clamp(oklabToRGB(vec3(targetL, targetAB)), vec3(0.0), vec3(1.0));
        return vec4(outputRGB * alpha, alpha);
    }
    """)

    public static func validate(_ settings: HSLSettings) throws {
        try settings.validate()
    }

    /// Applies the eight-band HSL edit. A neutral setting returns `image` itself.
    public static func apply(_ settings: HSLSettings,
                             to image: CIImage,
                             cancellation: CancellationToken? = nil) throws -> CIImage {
        try validate(settings)
        guard !settings.isNeutral else { return image }
        let extent = try ColorToolValidation.validExtent(of: image)
        try cancellation?.check()
        guard let kernel else {
            throw AtelierError.invalidConfiguration("Core Image HSL kernel 编译失败。")
        }
        var arguments: [Any] = [image]
        for band in HSLBand.allCases {
            let adjustment = settings[band]
            arguments.append(NSNumber(value: adjustment.hueShiftDegrees))
            arguments.append(NSNumber(value: adjustment.saturation))
            arguments.append(NSNumber(value: adjustment.luminance))
        }
        guard let output = kernel.apply(extent: extent, arguments: arguments) else {
            throw AtelierError.invalidConfiguration("Core Image HSL kernel 无法生成输出。")
        }
        return output.cropped(to: extent)
    }
}

// MARK: - Aggregate

/// Aggregate of the P1 color tools in pipeline order: curves → HSL → grading.
///
/// The integration layer (P1-5) stores this value in a v11 recipe and applies it
/// between the basic tone stage and the lens-effects stage. Every field is
/// optional so recipes written before v11 decode with all tools absent.
///
/// Neutral settings (all fields nil or neutral) return the input image object
/// unchanged, which keeps the pre-v11 pixel path exact.
public struct ColorToolsSettings: Codable, Equatable {
    public var curves: ColorCurveSettings?
    public var hsl: HSLSettings?
    public var grading: ColorGradingSettings?

    public init(curves: ColorCurveSettings? = nil,
                hsl: HSLSettings? = nil,
                grading: ColorGradingSettings? = nil) {
        self.curves = curves
        self.hsl = hsl
        self.grading = grading
    }

    /// True when no tool can change pixels.
    public var isNeutral: Bool {
        (curves?.isNeutral ?? true) && (hsl?.isNeutral ?? true) && (grading?.isNeutral ?? true)
    }

    public func validate() throws {
        if let curves { try curves.validate() }
        if let hsl { try hsl.validate() }
        if let grading { try grading.validate() }
    }
}

/// Runs the P1 color tools in their documented order.
///
/// Pipeline stage: geometry → liquify → basic tone → **color tools** → lens
/// effects → portrait → reference color → local masks → LUT → output gamut.
public enum ColorToolsEngine {
    public static func apply(_ settings: ColorToolsSettings,
                             to image: CIImage,
                             cancellation: CancellationToken? = nil) throws -> CIImage {
        try settings.validate()
        var output = image
        if let curves = settings.curves, !curves.isNeutral {
            output = try ColorCurveEngine.apply(curves, to: output, cancellation: cancellation)
        }
        if let hsl = settings.hsl, !hsl.isNeutral {
            output = try HSLEngine.apply(hsl, to: output, cancellation: cancellation)
        }
        if let grading = settings.grading, !grading.isNeutral {
            output = try ColorGradingEngine.apply(grading, to: output, cancellation: cancellation)
        }
        return output
    }
}

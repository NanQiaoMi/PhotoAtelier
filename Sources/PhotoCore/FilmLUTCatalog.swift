import Foundation

/// Attribution attached to a preset whose look uses third-party material.
public struct LUTProvenance: Equatable, Sendable {
    public let author: String
    public let sourceURL: String
    public let license: String
    public let notice: String
    public let inputContract: String

    public init(author: String, sourceURL: String, license: String,
                notice: String, inputContract: String) {
        self.author = author
        self.sourceURL = sourceURL
        self.license = license
        self.notice = notice
        self.inputContract = inputContract
    }
}

/// Compact, deterministic approximations inspired by published Fujifilm recipe names.
/// These are not Fujifilm LUTs and do not reproduce camera processing.
public enum FilmLUTCatalog {
    private static let lutSize = 33
    private static let upstreamCommit = "a6691ea0e880ddd5fd19d7ca2d48a502fb0e7e07"
    private static let sourceURL = "https://github.com/sadziu/Fuji-Recipe-Converter/tree/\(upstreamCommit)"

    private static let provenance = LUTProvenance(
        author: "Sadziu and contributors",
        sourceURL: sourceURL,
        license: "MIT License",
        notice: "Independent hand-tuned approximation; not an official Fujifilm LUT, camera profile, or measured reproduction. See ThirdParty/FilmLUTs/ATTRIBUTION.md and LICENSE-MIT.txt.",
        inputContract: "Display-referred gamma-encoded sRGB RGB, domain [0,1]; output is gamma-encoded sRGB; 33-point 3D LUT with red changing fastest. No log conversion is included."
    )

    /// Five 33-point 3D looks generated in memory from the attributed recipes.
    public static let presets: [LUTPreset] = makeProfiles().map(makePreset)

    public static func preset(id: String) -> LUTPreset? {
        presets.first { $0.id == id }
    }

    private static func makePreset(_ profile: Profile) -> LUTPreset {
        LUTPreset(
            id: profile.id,
            name: profile.name,
            detail: profile.detail,
            cube: makeCube(profile),
            group: profile.group,
            recommendedIntensity: profile.recommendedIntensity,
            tags: profile.tags,
            provenance: provenance
        )
    }

    private static func makeProfiles() -> [Profile] {
        [
            Profile(
                id: "film-fuji-classic-chrome",
                name: "Classic Chrome 风格近似",
                detail: "低饱和、压深阴影的第三方手调近似；非官方机内渲染。",
                group: .cinematic,
                recommendedIntensity: 0.34,
                saturation: -16,
                shadow: 0.035,
                highlight: 0.008,
                hue: [.red: 6, .green: 8, .aqua: -6, .blue: -12],
                saturationByBand: [.red: -8, .yellow: -8, .green: -22,
                                   .aqua: -18, .blue: -22, .magenta: -15],
                luminanceByBand: [.red: -4, .aqua: -8, .blue: -12],
                tags: ["富士风格", "低饱和", "纪实"]
            ),
            Profile(
                id: "film-fuji-astia",
                name: "ASTIA 风格近似",
                detail: "柔和反差、轻微暖色保留的第三方手调近似；非官方机内渲染。",
                group: .portrait,
                recommendedIntensity: 0.34,
                saturation: 8,
                shadow: -0.012,
                highlight: 0.01,
                saturationByBand: [.orange: -6],
                luminanceByBand: [.orange: 4],
                tags: ["富士风格", "柔和", "人像"]
            ),
            Profile(
                id: "film-fuji-classic-neg",
                name: "Classic Neg 风格近似",
                detail: "复古色相分离和较深阴影的第三方手调近似；非官方机内渲染。",
                group: .cinematic,
                recommendedIntensity: 0.3,
                saturation: -10,
                shadow: 0.045,
                highlight: 0.02,
                hue: [.red: 4, .yellow: -8, .green: 18, .blue: -8],
                saturationByBand: [.red: 6, .yellow: -15, .green: -25,
                                   .aqua: -10, .blue: -12],
                luminanceByBand: [.red: -8, .green: -6, .blue: -6],
                grade: SplitTone(shadowHue: 185, shadowSaturation: 6,
                                 highlightHue: 45, highlightSaturation: 5),
                tags: ["富士风格", "复古", "色彩分离"]
            ),
            Profile(
                id: "film-fuji-eterna",
                name: "ETERNA 风格近似",
                detail: "低饱和、抬黑位并压低反差的第三方手调近似；非官方机内渲染。",
                group: .cinematic,
                recommendedIntensity: 0.3,
                saturation: -24,
                shadow: -0.04,
                highlight: -0.035,
                lift: 0.012,
                saturationByBand: [.green: -6],
                tags: ["富士风格", "低反差", "电影"]
            ),
            Profile(
                id: "film-fuji-acros",
                name: "ACROS 风格近似",
                detail: "黑白灰阶与较深阴影的第三方手调近似；不含胶片颗粒，也非官方机内渲染。",
                group: .monochrome,
                recommendedIntensity: 0.38,
                saturation: 0,
                shadow: 0.03,
                highlight: 0.02,
                monochrome: true,
                tags: ["富士风格", "黑白", "无颗粒"]
            )
        ]
    }

    private static func makeCube(_ profile: Profile) -> LUTCube {
        let transform = Transform(profile)
        let step = 1.0 / Double(lutSize - 1)
        var rgba: [Float] = []
        rgba.reserveCapacity(lutSize * lutSize * lutSize * 4)

        // .cube table order used by LUTCube: red varies fastest, then green, blue.
        for blueIndex in 0..<lutSize {
            let blue = Double(blueIndex) * step
            for greenIndex in 0..<lutSize {
                let green = Double(greenIndex) * step
                for redIndex in 0..<lutSize {
                    let red = Double(redIndex) * step
                    let output = transform.apply(RGB(red: red, green: green, blue: blue))
                    rgba.append(Float(output.red))
                    rgba.append(Float(output.green))
                    rgba.append(Float(output.blue))
                    rgba.append(1)
                }
            }
        }

        return LUTCube(
            title: profile.title,
            size: lutSize,
            domainMin: SIMD3<Float>(repeating: 0),
            domainMax: SIMD3<Float>(repeating: 1),
            rgba: rgba
        )
    }

    private enum Band: Int, CaseIterable, Hashable {
        case red, orange, yellow, green, aqua, blue, purple, magenta
    }

    private struct Profile {
        let id: String
        let name: String
        let detail: String
        let title: String
        let group: LUTPresetGroup
        let recommendedIntensity: Double
        let tags: [String]
        let saturation: Double
        let shadow: Double
        let highlight: Double
        let lift: Double
        let hue: [Double]
        let saturationByBand: [Double]
        let luminanceByBand: [Double]
        let monochrome: Bool
        let mix: [Double]
        let grade: SplitTone

        init(id: String, name: String, detail: String, group: LUTPresetGroup,
             recommendedIntensity: Double, saturation: Double,
             shadow: Double, highlight: Double, lift: Double = 0,
             hue: [Band: Double] = [:],
             saturationByBand: [Band: Double] = [:],
             luminanceByBand: [Band: Double] = [:],
             monochrome: Bool = false, mix: [Band: Double] = [:],
             grade: SplitTone = .neutral, tags: [String]) {
            self.id = id
            self.name = name
            self.detail = detail
            self.title = "Fuji-style \(name)"
            self.group = group
            self.recommendedIntensity = recommendedIntensity
            self.tags = tags
            self.saturation = saturation
            self.shadow = shadow
            self.highlight = highlight
            self.lift = lift
            self.hue = Self.bandValues(hue)
            self.saturationByBand = Self.bandValues(saturationByBand)
            self.luminanceByBand = Self.bandValues(luminanceByBand)
            self.monochrome = monochrome
            self.mix = Self.bandValues(mix)
            self.grade = grade
        }

        private static func bandValues(_ values: [Band: Double]) -> [Double] {
            Band.allCases.map { values[$0] ?? 0 }
        }
    }

    private struct SplitTone {
        let shadowHue: Double
        let shadowSaturation: Double
        let highlightHue: Double
        let highlightSaturation: Double

        static let neutral = SplitTone(shadowHue: 0, shadowSaturation: 0,
                                       highlightHue: 0, highlightSaturation: 0)
    }

    private struct RGB {
        var red: Double
        var green: Double
        var blue: Double
    }

    private struct CurvePoint {
        let x: Double
        let y: Double
    }

    /// Monotone cubic interpolation using the Fritsch-Carlson tangent limiter.
    private struct MonotoneCurve {
        private let points: [CurvePoint]
        private let tangents: [Double]

        init(points: [CurvePoint]) {
            self.points = points
            let segmentSlopes = (0..<(points.count - 1)).map { index in
                (points[index + 1].y - points[index].y)
                    / (points[index + 1].x - points[index].x)
            }
            var slopes = [Double](repeating: 0, count: points.count)
            slopes[0] = segmentSlopes[0]
            for index in 1..<(points.count - 1) {
                slopes[index] = segmentSlopes[index - 1] * segmentSlopes[index] <= 0
                    ? 0 : (segmentSlopes[index - 1] + segmentSlopes[index]) / 2
            }
            slopes[points.count - 1] = segmentSlopes[segmentSlopes.count - 1]

            for index in segmentSlopes.indices {
                let delta = segmentSlopes[index]
                if delta == 0 {
                    slopes[index] = 0
                    slopes[index + 1] = 0
                    continue
                }
                let a = slopes[index] / delta
                let b = slopes[index + 1] / delta
                let magnitude = a * a + b * b
                if magnitude > 9 {
                    let scale = 3 / sqrt(magnitude)
                    slopes[index] = scale * a * delta
                    slopes[index + 1] = scale * b * delta
                }
            }
            tangents = slopes
        }

        func value(at value: Double) -> Double {
            if value <= points[0].x { return points[0].y }
            if value >= points[points.count - 1].x { return points[points.count - 1].y }

            var index = 0
            while value > points[index + 1].x { index += 1 }
            let left = points[index]
            let right = points[index + 1]
            let width = right.x - left.x
            let position = (value - left.x) / width
            let positionSquared = position * position
            let positionCubed = positionSquared * position
            return (2 * positionCubed - 3 * positionSquared + 1) * left.y
                + (positionCubed - 2 * positionSquared + position) * width * tangents[index]
                + (-2 * positionCubed + 3 * positionSquared) * right.y
                + (positionCubed - positionSquared) * width * tangents[index + 1]
        }
    }

    private struct Transform {
        private static let bandHues = [0.0, 30, 60, 120, 180, 240, 270, 300, 360]
        private static let lumaRed = 0.2126
        private static let lumaGreen = 0.7152
        private static let lumaBlue = 0.0722

        private let profile: Profile
        private let curve: MonotoneCurve
        private let usesIdentityCurve: Bool
        private let saturationFactor: Double
        private let shadowTint: RGB
        private let highlightTint: RGB
        private let shadowTintAmount: Double
        private let highlightTintAmount: Double

        init(_ profile: Profile) {
            self.profile = profile
            let curveMid = Self.clamp(0.25 - profile.shadow, 0.06, 0.4)
                + profile.lift * 0.6
            let curveHigh = Self.clamp(0.75 + profile.highlight, 0.6, 0.93)
            curve = MonotoneCurve(points: [
                CurvePoint(x: 0, y: profile.lift),
                CurvePoint(x: 0.25, y: curveMid),
                CurvePoint(x: 0.5, y: 0.5),
                CurvePoint(x: 0.75, y: curveHigh),
                CurvePoint(x: 1, y: 1)
            ])
            usesIdentityCurve = abs(profile.shadow) < 1e-9
                && abs(profile.highlight) < 1e-9 && profile.lift == 0
            saturationFactor = 1 + (profile.monochrome ? 0 : profile.saturation) / 100
            shadowTint = Self.tintVector(profile.grade.shadowHue)
            highlightTint = Self.tintVector(profile.grade.highlightHue)
            shadowTintAmount = profile.grade.shadowSaturation / 100 * 0.22
            highlightTintAmount = profile.grade.highlightSaturation / 100 * 0.22
        }

        func apply(_ input: RGB) -> RGB {
            var red = input.red
            var green = input.green
            var blue = input.blue
            if !usesIdentityCurve {
                red = curve.value(at: red)
                green = curve.value(at: green)
                blue = curve.value(at: blue)
            }

            let maximum = max(red, max(green, blue))
            let minimum = min(red, min(green, blue))
            let chroma = maximum - minimum
            var luminance = Self.luminance(red: red, green: green, blue: blue)

            if profile.monochrome {
                if Self.hasNonZero(profile.mix), chroma > 1e-6 {
                    let hue = Self.hue(red: red, green: green, blue: blue,
                                       maximum: maximum, minimum: minimum)
                    let mix = Self.bandValue(profile.mix, hue: hue)
                    luminance = Self.clamp(
                        luminance * (1 + mix / 100 * 0.9 * min(1, chroma * 1.6)),
                        0, 1
                    )
                }
                red = luminance
                green = luminance
                blue = luminance
            } else if chroma > 1e-6 {
                let hue = Self.hue(red: red, green: green, blue: blue,
                                   maximum: maximum, minimum: minimum)
                if Self.hasNonZero(profile.hue) {
                    let angle = Self.bandValue(profile.hue, hue: hue) * 0.3 * Double.pi / 180
                    let cosine = cos(angle)
                    let sine = sin(angle)
                    let offset = (1 - cosine) / 3
                    let axisSine = sqrt(1.0 / 3.0) * sine
                    let rotatedRed = red * (cosine + offset)
                        + green * (offset - axisSine) + blue * (offset + axisSine)
                    let rotatedGreen = red * (offset + axisSine)
                        + green * (cosine + offset) + blue * (offset - axisSine)
                    let rotatedBlue = red * (offset - axisSine)
                        + green * (offset + axisSine) + blue * (cosine + offset)
                    red = rotatedRed
                    green = rotatedGreen
                    blue = rotatedBlue
                    luminance = Self.luminance(red: red, green: green, blue: blue)
                }

                var saturation = saturationFactor
                if Self.hasNonZero(profile.saturationByBand) {
                    saturation *= max(0, 1 + Self.bandValue(profile.saturationByBand, hue: hue) / 100)
                }
                if saturation != 1 {
                    red = luminance + (red - luminance) * saturation
                    green = luminance + (green - luminance) * saturation
                    blue = luminance + (blue - luminance) * saturation
                }

                if Self.hasNonZero(profile.luminanceByBand) {
                    let luminanceScale = 1 + Self.bandValue(profile.luminanceByBand, hue: hue)
                        / 100 * 0.9 * min(1, chroma * 1.6)
                    red *= luminanceScale
                    green *= luminanceScale
                    blue *= luminanceScale
                }
            } else if saturationFactor != 1 {
                red = luminance + (red - luminance) * saturationFactor
                green = luminance + (green - luminance) * saturationFactor
                blue = luminance + (blue - luminance) * saturationFactor
            }

            if shadowTintAmount != 0 || highlightTintAmount != 0 {
                luminance = Self.clamp(Self.luminance(red: red, green: green, blue: blue), 0, 1)
                let shadowWeight = (1 - luminance) * (1 - luminance) * shadowTintAmount
                let highlightWeight = luminance * luminance * highlightTintAmount
                red += shadowTint.red * shadowWeight + highlightTint.red * highlightWeight
                green += shadowTint.green * shadowWeight + highlightTint.green * highlightWeight
                blue += shadowTint.blue * shadowWeight + highlightTint.blue * highlightWeight
            }

            return RGB(red: Self.clamp(red, 0, 1),
                       green: Self.clamp(green, 0, 1),
                       blue: Self.clamp(blue, 0, 1))
        }

        private static func bandValue(_ values: [Double], hue: Double) -> Double {
            for index in 0..<8 where hue <= bandHues[index + 1] {
                let position = (hue - bandHues[index]) / (bandHues[index + 1] - bandHues[index])
                return values[index] + (values[(index + 1) % 8] - values[index]) * position
            }
            return values[0]
        }

        private static func hue(red: Double, green: Double, blue: Double,
                                maximum: Double, minimum: Double) -> Double {
            let chroma = maximum - minimum
            guard chroma >= 1e-9 else { return 0 }
            var value: Double
            if maximum == red {
                value = ((green - blue) / chroma).truncatingRemainder(dividingBy: 6)
            } else if maximum == green {
                value = (blue - red) / chroma + 2
            } else {
                value = (red - green) / chroma + 4
            }
            value *= 60
            return value < 0 ? value + 360 : value
        }

        private static func tintVector(_ hueDegrees: Double) -> RGB {
            let hue = hueDegrees / 60
            let x = 1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1)
            let color: RGB
            if hue < 1 { color = RGB(red: 1, green: x, blue: 0) }
            else if hue < 2 { color = RGB(red: x, green: 1, blue: 0) }
            else if hue < 3 { color = RGB(red: 0, green: 1, blue: x) }
            else if hue < 4 { color = RGB(red: 0, green: x, blue: 1) }
            else if hue < 5 { color = RGB(red: x, green: 0, blue: 1) }
            else { color = RGB(red: 1, green: 0, blue: x) }
            let luminance = Self.luminance(red: color.red, green: color.green, blue: color.blue)
            return RGB(red: color.red - luminance,
                       green: color.green - luminance,
                       blue: color.blue - luminance)
        }

        private static func luminance(red: Double, green: Double, blue: Double) -> Double {
            lumaRed * red + lumaGreen * green + lumaBlue * blue
        }

        private static func hasNonZero(_ values: [Double]) -> Bool {
            values.contains { $0 != 0 }
        }

        private static func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
            min(maximum, max(minimum, value))
        }

    }

    private static func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
        min(maximum, max(minimum, value))
    }
}

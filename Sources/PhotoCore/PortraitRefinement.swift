import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Reference skin tone used when unifying several faces.
public enum PortraitToneReference: String, Codable, CaseIterable {
    /// Median face tone; the default "no strong bias" choice.
    case auto
    /// Median face tone, explicitly requested.
    case median
    /// Brightest face tone.
    case brightest

    public var title: String {
        switch self {
        case .auto: return "自动（中位肤色）"
        case .median: return "中位肤色"
        case .brightest: return "最亮肤色"
        }
    }
}

/// Restrained portrait retouch controls.
///
/// The neutral value of every control is `0`, which keeps the original render
/// path untouched (recipes written before v10 decode without this field at all).
/// Values are normalized to `0...1`; `validate(_:)` rejects anything else so a
/// malformed recipe fails loudly instead of being silently clamped.
///
/// Non-neutral settings require recipe version 10 (`Recipe.validateVersion`).
/// `keepSpots` only has an effect while `blemishStrength > 0`.
public struct PortraitRefinementSettings: Codable, Equatable {
    /// Small blemish repair strength inside the skin matte.
    public var blemishStrength: Double = 0
    /// Preserve very dark, compact spots (moles/freckles) instead of repairing.
    public var keepSpots: Bool = false
    /// Evening out broad light/shadow variation on the skin.
    public var dodgeBurn: Double = 0
    /// Local mid-frequency contrast ("stereoscopic" structure).
    public var structure: Double = 0
    /// Fine-texture retention/enhancement.
    public var texture: Double = 0
    /// Softens specular gloss on the skin.
    public var gloss: Double = 0
    /// Teeth whitening strength.
    public var teethWhiten: Double = 0
    /// Sclera brightening strength (the iris is never touched).
    public var eyeBrighten: Double = 0
    /// Multi-face skin-tone consistency strength.
    public var skinToneUnify: Double = 0
    /// Which face supplies the reference tone for unification.
    public var skinToneReference: PortraitToneReference = .auto
    /// Hair parting and scalp gap filling strength 0...1 (0 = disabled).
    public var hairGapFilling: Double = 0
    /// Hair sheen and angel ring highlight strength 0...1 (0 = disabled).
    public var hairGloss: Double = 0
    /// Hair tone depth and brassiness suppression 0...1 (0 = disabled).
    public var hairDarkening: Double = 0
    /// Hair anti-frizz smoothing strength 0...1 (0 = disabled).
    public var hairSmoothing: Double = 0
    /// Flyaway and stray hair removal along head silhouette 0...1 (0 = disabled).
    public var flyawayRemoval: Double = 0

    public init(blemishStrength: Double = 0, keepSpots: Bool = false,
                dodgeBurn: Double = 0, structure: Double = 0, texture: Double = 0,
                gloss: Double = 0, teethWhiten: Double = 0, eyeBrighten: Double = 0,
                skinToneUnify: Double = 0, skinToneReference: PortraitToneReference = .auto,
                hairGapFilling: Double = 0, hairGloss: Double = 0, hairDarkening: Double = 0,
                hairSmoothing: Double = 0, flyawayRemoval: Double = 0) {
        self.blemishStrength = blemishStrength
        self.keepSpots = keepSpots
        self.dodgeBurn = dodgeBurn
        self.structure = structure
        self.texture = texture
        self.gloss = gloss
        self.teethWhiten = teethWhiten
        self.eyeBrighten = eyeBrighten
        self.skinToneUnify = skinToneUnify
        self.skinToneReference = skinToneReference
        self.hairGapFilling = hairGapFilling
        self.hairGloss = hairGloss
        self.hairDarkening = hairDarkening
        self.hairSmoothing = hairSmoothing
        self.flyawayRemoval = flyawayRemoval
    }

    private enum CodingKeys: String, CodingKey {
        case blemishStrength, keepSpots, dodgeBurn, structure, texture, gloss
        case teethWhiten, eyeBrighten, skinToneUnify, skinToneReference
        case hairGapFilling, hairGloss, hairDarkening
        case hairSmoothing, flyawayRemoval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blemishStrength = try container.decodeIfPresent(Double.self, forKey: .blemishStrength) ?? 0
        keepSpots = try container.decodeIfPresent(Bool.self, forKey: .keepSpots) ?? false
        dodgeBurn = try container.decodeIfPresent(Double.self, forKey: .dodgeBurn) ?? 0
        structure = try container.decodeIfPresent(Double.self, forKey: .structure) ?? 0
        texture = try container.decodeIfPresent(Double.self, forKey: .texture) ?? 0
        gloss = try container.decodeIfPresent(Double.self, forKey: .gloss) ?? 0
        teethWhiten = try container.decodeIfPresent(Double.self, forKey: .teethWhiten) ?? 0
        eyeBrighten = try container.decodeIfPresent(Double.self, forKey: .eyeBrighten) ?? 0
        skinToneUnify = try container.decodeIfPresent(Double.self, forKey: .skinToneUnify) ?? 0
        skinToneReference = try container.decodeIfPresent(PortraitToneReference.self, forKey: .skinToneReference) ?? .auto
        hairGapFilling = try container.decodeIfPresent(Double.self, forKey: .hairGapFilling) ?? 0
        hairGloss = try container.decodeIfPresent(Double.self, forKey: .hairGloss) ?? 0
        hairDarkening = try container.decodeIfPresent(Double.self, forKey: .hairDarkening) ?? 0
        hairSmoothing = try container.decodeIfPresent(Double.self, forKey: .hairSmoothing) ?? 0
        flyawayRemoval = try container.decodeIfPresent(Double.self, forKey: .flyawayRemoval) ?? 0
    }

    /// True when every masked control is at its neutral value. The tone reference
    /// enum is ignored because it has no effect while `skinToneUnify == 0`.
    public var isNeutral: Bool {
        blemishStrength == 0 && dodgeBurn == 0 && structure == 0 && texture == 0
            && gloss == 0 && teethWhiten == 0 && eyeBrighten == 0 && skinToneUnify == 0
            && hairGapFilling == 0 && hairGloss == 0 && hairDarkening == 0
            && hairSmoothing == 0 && flyawayRemoval == 0
    }
}

/// Per-photo record of what the portrait pass did, embedded in
/// `ProcessingReport` so the batch manifest can say "applied" or "no face".
public struct PortraitRefinementReport: Codable, Equatable {
    public var applied: Bool
    public var faceCount: Int
    public var appliedSteps: [String]
    public var note: String?

    public init(applied: Bool = false, faceCount: Int = 0,
                appliedSteps: [String] = [], note: String? = nil) {
        self.applied = applied
        self.faceCount = faceCount
        self.appliedSteps = appliedSteps
        self.note = note
    }
}

public struct PortraitRefinementResult {
    public let image: CIImage
    public let report: PortraitRefinementReport

    public init(image: CIImage, report: PortraitRefinementReport) {
        self.image = image
        self.report = report
    }
}

/// Detects faces (Vision) and converts them to per-face semantic masks.
///
/// The masks are deliberately kept per face so skin-tone unification can compare
/// face statistics. Detection failures are not silent: `masks(...)` returns an
/// empty array, and the caller records a "no usable face" note in the report.
public enum PortraitSemanticMaskProvider {
    public static func masks(in image: CIImage,
                             maxFaces: Int = 4,
                             maxDimension: Int = FaceSemanticAnalyzer.defaultMaxDimension) -> [FaceSemanticMaskSet] {
        FaceSemanticAnalyzer.detect(in: image, maxFaces: maxFaces)
            .map { landmarks in
                FaceSemanticAnalyzer.masks(image: image,
                                           faceBounds: landmarks.boundingBox,
                                           landmarks: landmarks,
                                           maxDimension: maxDimension)
            }
            .filter { !$0.isEmpty }
    }
}

/// Applies the portrait pipeline: blemish repair → frequency shaping → teeth →
/// sclera → multi-face skin-tone unification.
///
/// Pipeline placement: global tone/geometry → **portrait refinement** → local
/// masks/detail → LUT → output gamut. Every step is bounded, deterministic and
/// restricted to the matching semantic mask; the iris, brows, lips and teeth
/// regions are excluded from skin steps.
///
/// This is not a commercial-grade retouch engine: the rules are heuristics and
/// synthetic tests only prove regional containment and bounded change, not
/// aesthetic quality on real photographs.
public enum PortraitRefinementEngine {
    public static func validate(_ settings: PortraitRefinementSettings) throws {
        func require(_ value: Double, named name: String) throws {
            guard value.isFinite, (0...1).contains(value) else {
                throw AtelierError.invalidConfiguration("人像\(name)必须在 0...1 之间。")
            }
        }
        try require(settings.blemishStrength, named: "祛瑕疵强度")
        try require(settings.dodgeBurn, named: "光影平整")
        try require(settings.structure, named: "立体感")
        try require(settings.texture, named: "纹理")
        try require(settings.gloss, named: "光泽")
        try require(settings.teethWhiten, named: "牙齿美白")
        try require(settings.eyeBrighten, named: "眼白提亮")
        try require(settings.skinToneUnify, named: "肤色统一")
        try require(settings.hairGapFilling, named: "发缝填充强度")
        try require(settings.hairGloss, named: "秀发光泽强度")
        try require(settings.hairDarkening, named: "发色深邃强度")
        try require(settings.hairSmoothing, named: "秀发柔顺强度")
        try require(settings.flyawayRemoval, named: "边缘去碎发强度")
    }

    public static func apply(_ image: CIImage,
                             settings: PortraitRefinementSettings,
                             faceMasks: [FaceSemanticMaskSet],
                             landmarks: [FaceLandmarkSet] = [],
                             context: CIContext,
                             cancellation: CancellationToken? = nil) throws -> PortraitRefinementResult {
        try validate(settings)
        guard !settings.isNeutral else {
            return PortraitRefinementResult(image: image,
                                            report: PortraitRefinementReport(faceCount: faceMasks.count))
        }
        let faceCount = faceMasks.count
        guard faceCount > 0 else {
            return PortraitRefinementResult(image: image,
                report: PortraitRefinementReport(applied: false, faceCount: 0,
                                                 note: "未检测到可用人脸，人像修复已跳过（原图保持不变）。"))
        }

        let skinMask = unionMask(faceMasks.map(\.skin))
        let protectionMask = unionMask(faceMasks.flatMap { face in
            [face.brows, face.lips, face.teeth, face.sclera, face.iris]
        })
        let teethMask = unionMask(faceMasks.map(\.teeth))
        let scleraMask = unionMask(faceMasks.map(\.sclera))

        var current = image
        var steps: [String] = []
        var notes: [String] = []
        try cancellation?.check()

        let skinStrengths = [settings.blemishStrength, settings.dodgeBurn,
                             settings.structure, settings.texture, settings.gloss]
        if skinStrengths.contains(where: { $0 > 0 }) {
            guard let skinMask else {
                notes.append("缺少皮肤蒙版，祛瑕疵与光影/纹理步骤已跳过。")
                return finish(image, faceCount: faceCount, steps: steps, notes: notes)
            }
            if settings.blemishStrength > 0 {
                current = try BlemishRemovalEngine.apply(current,
                    strength: settings.blemishStrength, keepSpots: settings.keepSpots,
                    skinMask: skinMask, protectionMask: protectionMask,
                    context: context, cancellation: cancellation)
                steps.append("blemish")
            }
            if settings.dodgeBurn > 0 || settings.structure > 0
                || settings.texture > 0 || settings.gloss > 0 {
                current = try FrequencySeparationEngine.apply(current,
                    settings: settings, skinMask: skinMask,
                    context: context, cancellation: cancellation)
                if settings.dodgeBurn > 0 { steps.append("dodgeBurn") }
                if settings.structure > 0 { steps.append("structure") }
                if settings.texture > 0 { steps.append("texture") }
                if settings.gloss > 0 { steps.append("gloss") }
            }
        }
        try cancellation?.check()

        if settings.teethWhiten > 0 {
            // R3 (2026-11-14): a mask image can exist and still cover nothing -
            // the semantic layer only returns teeth pixels for an open mouth with
            // bright, low-chroma enamel. Checking coverage (not just presence)
            // stops the report from claiming "teeth" ran when it changed no pixel.
            if let teethMask, hasCoverage(teethMask, extent: image.extent, context: context) {
                current = try whitenTeeth(current, mask: teethMask,
                                          strength: settings.teethWhiten, context: context)
                steps.append("teeth")
            } else {
                notes.append("缺少牙齿蒙版（可能闭嘴、未露齿或牙齿偏暗），牙齿美白已跳过。")
            }
        }
        if settings.eyeBrighten > 0 {
            if let scleraMask, hasCoverage(scleraMask, extent: image.extent, context: context) {
                current = try brightenSclera(current, mask: scleraMask,
                                             strength: settings.eyeBrighten, context: context)
                steps.append("eye")
            } else {
                notes.append("缺少眼白蒙版（眼部过暗或低对比），眼白提亮已跳过。")
            }
        }
        try cancellation?.check()

        if settings.skinToneUnify > 0 {
            let perFaceSkin = faceMasks.compactMap(\.skin)
            if perFaceSkin.isEmpty {
                notes.append("缺少皮肤蒙版，面部肤色统一已跳过。")
            } else {
                current = try unifySkinTone(current, skinMasks: perFaceSkin,
                                            reference: settings.skinToneReference,
                                            strength: settings.skinToneUnify,
                                            context: context)
                steps.append("skinTone")
                if perFaceSkin.count < 2 {
                    notes.append("只检测到一张可用人脸，肤色统一按单脸色度平整执行。")
                }
            }
        }
        try cancellation?.check()

        // Hair refinement: gap filling, gloss sheen, tone depth, smoothing, flyaway removal
        if settings.hairGapFilling > 0 || settings.hairGloss > 0 || settings.hairDarkening > 0
            || settings.hairSmoothing > 0 || settings.flyawayRemoval > 0 {
            current = try HairRefinementEngine.apply(
                current, settings: settings, faceMasks: faceMasks,
                landmarks: landmarks, context: context, cancellation: cancellation
            )
            if settings.hairGapFilling > 0 { steps.append("hairGap") }
            if settings.hairGloss > 0 { steps.append("hairGloss") }
            if settings.hairDarkening > 0 { steps.append("hairDarkening") }
            if settings.hairSmoothing > 0 { steps.append("hairSmoothing") }
            if settings.flyawayRemoval > 0 { steps.append("flyawayRemoval") }
        }

        let note = notes.isEmpty ? nil : notes.joined(separator: " ")
        return PortraitRefinementResult(image: current,
            report: PortraitRefinementReport(applied: !steps.isEmpty, faceCount: faceCount,
                                             appliedSteps: steps, note: note))
    }

    private static func finish(_ image: CIImage, faceCount: Int,
                               steps: [String], notes: [String]) -> PortraitRefinementResult {
        PortraitRefinementResult(image: image,
            report: PortraitRefinementReport(applied: !steps.isEmpty, faceCount: faceCount,
                                             appliedSteps: steps,
                                             note: notes.isEmpty ? nil : notes.joined(separator: " ")))
    }

    static func unionMask(_ masks: [CIImage?]) -> CIImage? {
        PortraitRaster.union(masks)
    }

    /// True when `mask` actually covers something (its brightest pixel clears a
    /// low floor). A matte can be non-nil and still be entirely empty, which used
    /// to be reported as a successful step.
    static func hasCoverage(_ mask: CIImage, extent: CGRect,
                            context: CIContext) -> Bool {
        guard let raster = PortraitRaster.render(image: mask, extent: extent,
                                                 longestEdge: 256, masks: [],
                                                 context: context) else { return false }
        for index in 0..<raster.pixelCount where raster.red[index] > 0.05 {
            return true
        }
        return false
    }

    // MARK: Tooth whitening

    /// Raises `L*` and removes yellow (`b*`) inside the teeth matte. The change is
    /// capped at roughly 6 Lab units so teeth do not turn artificial white.
    static func whitenTeeth(_ image: CIImage, mask: CIImage,
                            strength: Double, context: CIContext) throws -> CIImage {
        guard let raster = PortraitRaster.render(image: image, extent: image.extent,
                                                 longestEdge: 1024, masks: [mask],
                                                 context: context) else { return image }
        let coverage = raster.coverages[0]
        var deltaRed = [Float](repeating: 0, count: raster.pixelCount)
        var deltaGreen = deltaRed
        var deltaBlue = deltaRed
        for index in 0..<raster.pixelCount where coverage[index] > 0.02 {
            let weight = Double(coverage[index]) * strength * 0.85
            let lab = PortraitRaster.lab(red: raster.red[index], green: raster.green[index],
                                         blue: raster.blue[index])
            let targetLightness = min(100, lab.lightness + 5.0 * weight)
            let targetYellow = lab.bStar * (1 - 0.45 * weight)
            let targetRed = lab.aStar * (1 - 0.20 * weight)
            let corrected = PortraitRaster.linearRGB(lightness: targetLightness, aStar: targetRed,
                                                     bStar: targetYellow)
            deltaRed[index] = corrected.0 - raster.red[index]
            deltaGreen[index] = corrected.1 - raster.green[index]
            deltaBlue[index] = corrected.2 - raster.blue[index]
        }
        let delta = PortraitRaster.deltaImage(red: deltaRed, green: deltaGreen, blue: deltaBlue,
                                              width: raster.width, height: raster.height,
                                              extent: image.extent)
        return PortraitRaster.add(delta: delta, to: image)
    }

    // MARK: Sclera brightening

    /// Brightens and neutralizes the sclera matte only; the iris matte is excluded
    /// by `FaceSemanticAnalyzer` and this pass never samples outside the mask.
    static func brightenSclera(_ image: CIImage, mask: CIImage,
                               strength: Double, context: CIContext) throws -> CIImage {
        guard let raster = PortraitRaster.render(image: image, extent: image.extent,
                                                 longestEdge: 1024, masks: [mask],
                                                 context: context) else { return image }
        let coverage = raster.coverages[0]
        var deltaRed = [Float](repeating: 0, count: raster.pixelCount)
        var deltaGreen = deltaRed
        var deltaBlue = deltaRed
        for index in 0..<raster.pixelCount where coverage[index] > 0.02 {
            let weight = Double(coverage[index]) * strength * 0.8
            let lab = PortraitRaster.lab(red: raster.red[index], green: raster.green[index],
                                         blue: raster.blue[index])
            let targetLightness = min(100, lab.lightness + 4.5 * weight)
            let targetRed = lab.aStar * (1 - 0.35 * weight)
            let targetYellow = lab.bStar * (1 - 0.35 * weight)
            let corrected = PortraitRaster.linearRGB(lightness: targetLightness, aStar: targetRed,
                                                     bStar: targetYellow)
            deltaRed[index] = corrected.0 - raster.red[index]
            deltaGreen[index] = corrected.1 - raster.green[index]
            deltaBlue[index] = corrected.2 - raster.blue[index]
        }
        let delta = PortraitRaster.deltaImage(red: deltaRed, green: deltaGreen, blue: deltaBlue,
                                              width: raster.width, height: raster.height,
                                              extent: image.extent)
        return PortraitRaster.add(delta: delta, to: image)
    }

    // MARK: Skin-tone unification

    /// Maps every face's skin pixels toward one shared reference tone, then evens
    /// out each face's own low-frequency colour variation toward its median
    /// chroma. Inter-face gains are limited to ±20% so identity and local texture
    /// survive; the mapping is a v1 approximation (per-face mean in linear RGB),
    /// not a perceptual transfer.
    static func unifySkinTone(_ image: CIImage, skinMasks: [CIImage],
                              reference: PortraitToneReference, strength: Double,
                              context: CIContext) throws -> CIImage {
        guard let raster = PortraitRaster.render(image: image, extent: image.extent,
                                                 longestEdge: 1024, masks: skinMasks,
                                                 context: context) else { return image }
        struct FaceTone {
            let coverageIndex: Int
            let red: Double
            let green: Double
            let blue: Double
            let aStar: Double
            let bStar: Double
            let weight: Double
        }
        var tones: [FaceTone] = []
        for (coverageIndex, coverage) in raster.coverages.enumerated() {
            var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
            var aStar = 0.0, bStar = 0.0
            for index in 0..<raster.pixelCount where coverage[index] > 0.25 {
                let sampleWeight = Double(coverage[index])
                red += Double(raster.red[index]) * sampleWeight
                green += Double(raster.green[index]) * sampleWeight
                blue += Double(raster.blue[index]) * sampleWeight
                let lab = PortraitRaster.lab(red: raster.red[index],
                                             green: raster.green[index],
                                             blue: raster.blue[index])
                aStar += lab.aStar * sampleWeight
                bStar += lab.bStar * sampleWeight
                weight += sampleWeight
            }
            guard weight >= 40 else { continue }
            tones.append(FaceTone(coverageIndex: coverageIndex,
                                  red: red / weight, green: green / weight,
                                  blue: blue / weight,
                                  aStar: aStar / weight, bStar: bStar / weight,
                                  weight: weight))
        }
        guard tones.count >= 1 else { return image }
        let sortedByLightness = tones.sorted {
            PortraitRaster.luminance($0.red, $0.green, $0.blue)
                < PortraitRaster.luminance($1.red, $1.green, $1.blue)
        }
        let referenceTone: FaceTone
        switch reference {
        case .auto, .median:
            referenceTone = sortedByLightness[sortedByLightness.count / 2]
        case .brightest:
            referenceTone = sortedByLightness[sortedByLightness.count - 1]
        }
        // R3 (2026-11-14): cross-face gains are identity on a single-face photo
        // (the reference face *is* the face), so the control used to be a silent
        // no-op exactly where it is used most. What "肤色统一" means in
        // retouching is evening out the face's own blotchy colour - red patches
        // on the cheeks, a yellow cast across one side. Each face's
        // low-frequency a*/b* is therefore pulled toward that face's own mean
        // chroma, which is a redistribution (the face mean is unchanged), so the
        // identity tone and the cross-face matching both survive.
        let chromaRadius = max(4, Int((0.055 * Double(min(raster.width, raster.height))).rounded()))

        var deltaRed = [Float](repeating: 0, count: raster.pixelCount)
        var deltaGreen = deltaRed
        var deltaBlue = deltaRed
        for tone in tones {
            let coverage = raster.coverages[tone.coverageIndex]
            let red = Float(clamp(referenceTone.red / max(tone.red, 1e-4), 0.80, 1.20))
            let green = Float(clamp(referenceTone.green / max(tone.green, 1e-4), 0.80, 1.20))
            let blue = Float(clamp(referenceTone.blue / max(tone.blue, 1e-4), 0.80, 1.20))

            // Local low-frequency chroma for this face, skin-weighted so hair,
            // background and mask fringes cannot drag the trend.
            var maskedA = [Float](repeating: 0, count: raster.pixelCount)
            var maskedB = [Float](repeating: 0, count: raster.pixelCount)
            var maskedCoverage = [Float](repeating: 0, count: raster.pixelCount)
            for index in 0..<raster.pixelCount where coverage[index] > 0.02 {
                let sampleWeight = coverage[index]
                let lab = PortraitRaster.lab(red: raster.red[index],
                                             green: raster.green[index],
                                             blue: raster.blue[index])
                maskedA[index] = Float(lab.aStar) * sampleWeight
                maskedB[index] = Float(lab.bStar) * sampleWeight
                maskedCoverage[index] = sampleWeight
            }
            let trendA = PortraitRaster.boxBlur(maskedA, width: raster.width,
                                                height: raster.height, radius: chromaRadius)
            let trendB = PortraitRaster.boxBlur(maskedB, width: raster.width,
                                                height: raster.height, radius: chromaRadius)
            let trendCoverage = PortraitRaster.boxBlur(maskedCoverage, width: raster.width,
                                                       height: raster.height, radius: chromaRadius)
            let meanA = tone.aStar
            let meanB = tone.bStar

            for index in 0..<raster.pixelCount where coverage[index] > 0.02 {
                let coverageWeight = Double(coverage[index]) * strength * 0.85
                let denominator = Double(trendCoverage[index])
                let localA = denominator > 0.02 ? Double(trendA[index]) / denominator : meanA
                let localB = denominator > 0.02 ? Double(trendB[index]) / denominator : meanB

                // Cross-face match: the per-channel RGB gain of the original
                // implementation, unchanged, so two faces converge in lightness
                // as well as hue.
                let gainedRed = Float(Double(raster.red[index]) * Double(red))
                let gainedGreen = Float(Double(raster.green[index]) * Double(green))
                let gainedBlue = Float(Double(raster.blue[index]) * Double(blue))
                let lab = PortraitRaster.lab(red: gainedRed, green: gainedGreen, blue: gainedBlue)

                // Intra-face evenness: pull the local low-frequency chroma to
                // the face mean, bounded at ±4 Lab units so natural warmth
                // (cheeks redder than the forehead) is reduced, not erased.
                let pullA = min(4.0, max(-4.0, (meanA - localA) * 0.55))
                let pullB = min(4.0, max(-4.0, (meanB - localB) * 0.55))
                let even = PortraitRaster.linearRGB(lightness: lab.lightness,
                                                    aStar: lab.aStar + pullA,
                                                    bStar: lab.bStar + pullB)

                deltaRed[index] = clamp(Float((Double(even.0) - Double(raster.red[index]))
                    * coverageWeight), -0.16, 0.16)
                deltaGreen[index] = clamp(Float((Double(even.1) - Double(raster.green[index]))
                    * coverageWeight), -0.16, 0.16)
                deltaBlue[index] = clamp(Float((Double(even.2) - Double(raster.blue[index]))
                    * coverageWeight), -0.16, 0.16)
            }
        }
        let delta = PortraitRaster.deltaImage(red: deltaRed, green: deltaGreen, blue: deltaBlue,
                                              width: raster.width, height: raster.height,
                                              extent: image.extent)
        return PortraitRaster.add(delta: delta, to: image)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value))
    }

    private static func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float {
        min(high, max(low, value))
    }
}

// MARK: - Shared raster helpers

/// Small, self-contained raster helper used by the portrait stages. Everything is
/// computed on a bounded working raster and applied back as a signed delta image,
/// so the caller's full-resolution pixels are never resampled through the whole
/// pipeline and neutral settings stay exact.
enum PortraitRaster {
    struct Raster {
        let width: Int
        let height: Int
        let red: [Float]
        let green: [Float]
        let blue: [Float]
        let alpha: [Float]
        let coverages: [[Float]]

        var pixelCount: Int { width * height }
    }

    /// R2 (2026-11-12 naturalness rework): skin deltas are computed on a raster
    /// up to 4096 px on the long edge and only downscaled, never upscaled, so a
    /// 1440-px photo gets a 1:1 delta instead of a 1024→1440 stretch that turned
    /// pore-level corrections into blotches ("细节粗糙" review finding).
    static let maximumWorkDimension = 4096

    static func render(image: CIImage, extent: CGRect, longestEdge: Int,
                       masks: [CIImage?], context: CIContext) -> Raster? {
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 1, extent.height > 1 else { return nil }
        let limit = min(maximumWorkDimension, max(64, longestEdge))
        let scale = min(1, CGFloat(limit) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        guard width > 1, height > 1 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        func oriented(_ source: CIImage) -> CIImage {
            source
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: bounds.width / extent.width,
                                                   y: bounds.height / extent.height))
                .cropped(to: bounds)
        }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            context.render(oriented(image), toBitmap: address,
                           rowBytes: width * 4 * MemoryLayout<Float>.stride,
                           bounds: bounds, format: .RGBAf, colorSpace: linearColorSpace)
        }
        var red = [Float](repeating: 0, count: width * height)
        var green = red, blue = red, alpha = red
        for index in 0..<(width * height) {
            let offset = index * 4
            let a = max(0, min(1, pixels[offset + 3]))
            let inverse = a > 0.000001 ? 1 / a : 0
            red[index] = pixels[offset] * inverse
            green[index] = pixels[offset + 1] * inverse
            blue[index] = pixels[offset + 2] * inverse
            alpha[index] = a
        }
        var coverages: [[Float]] = []
        for mask in masks {
            guard let mask else {
                coverages.append([Float](repeating: 0, count: width * height))
                continue
            }
            var maskPixels = [Float](repeating: 0, count: width * height * 4)
            maskPixels.withUnsafeMutableBytes { buffer in
                guard let address = buffer.baseAddress else { return }
                context.render(oriented(mask), toBitmap: address,
                               rowBytes: width * 4 * MemoryLayout<Float>.stride,
                               bounds: bounds, format: .RGBAf, colorSpace: linearColorSpace)
            }
            var coverage = [Float](repeating: 0, count: width * height)
            for index in 0..<coverage.count {
                coverage[index] = min(1, max(0, maskPixels[index * 4]))
            }
            coverages.append(coverage)
        }
        return Raster(width: width, height: height, red: red, green: green,
                      blue: blue, alpha: alpha, coverages: coverages)
    }

    static func deltaImage(red: [Float], green: [Float], blue: [Float],
                           width: Int, height: Int, extent: CGRect) -> CIImage {
        var rgba = [Float](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            let offset = index * 4
            rgba[offset] = red[index]
            rgba[offset + 1] = green[index]
            rgba[offset + 2] = blue[index]
            rgba[offset + 3] = 1
        }
        let data = rgba.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        let bitmap = CIImage(bitmapData: data,
                             bytesPerRow: width * 4 * MemoryLayout<Float>.stride,
                             size: CGSize(width: CGFloat(width), height: CGFloat(height)),
                             format: .RGBAf, colorSpace: linearColorSpace)
        return bitmap
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width),
                                               y: extent.height / CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    private static let additionKernel = CIColorKernel(source: """
    kernel vec4 addPortraitDelta(__sample base, __sample delta) {
        float alpha = base.a;
        if (!(alpha > 0.000001)) { return vec4(0.0); }
        vec3 linear = base.rgb / alpha;
        vec3 result = clamp(linear + delta.rgb, vec3(-16.0), vec3(16.0));
        return vec4(result * alpha, alpha);
    }
    """)

    static func add(delta: CIImage, to image: CIImage) -> CIImage {
        guard let kernel = additionKernel,
              let output = kernel.apply(extent: image.extent, arguments: [image, delta]) else {
            return image
        }
        return output
    }

    private static let maximumKernel = CIColorKernel(source: """
    kernel vec4 maximumMask(__sample first, __sample second) {
        float value = max(first.r, second.r);
        return vec4(value, value, value, 1.0);
    }
    """)

    static func union(_ masks: [CIImage?]) -> CIImage? {
        let available = masks.compactMap { $0 }
        guard var combined = available.first else { return nil }
        guard let kernel = maximumKernel else { return combined }
        for mask in available.dropFirst() {
            guard let output = kernel.apply(extent: combined.extent, arguments: [combined, mask]) else {
                continue
            }
            combined = output
        }
        return combined
    }

    static func boxBlur(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        let radius = max(0, radius)
        guard radius > 0, width > 1, height > 1 else { return values }
        var horizontal = [Float](repeating: 0, count: values.count)
        var prefix = [Float](repeating: 0, count: width + 1)
        for row in 0..<height {
            let base = row * width
            prefix[0] = 0
            for column in 0..<width {
                prefix[column + 1] = prefix[column] + values[base + column]
            }
            for column in 0..<width {
                let low = max(0, column - radius)
                let high = min(width - 1, column + radius)
                horizontal[base + column] = (prefix[high + 1] - prefix[low]) / Float(high - low + 1)
            }
        }
        var output = [Float](repeating: 0, count: values.count)
        var verticalPrefix = [Float](repeating: 0, count: height + 1)
        for column in 0..<width {
            verticalPrefix[0] = 0
            for row in 0..<height {
                verticalPrefix[row + 1] = verticalPrefix[row] + horizontal[row * width + column]
            }
            for row in 0..<height {
                let low = max(0, row - radius)
                let high = min(height - 1, row + radius)
                output[row * width + column] = (verticalPrefix[high + 1] - verticalPrefix[low])
                    / Float(high - low + 1)
            }
        }
        return output
    }

    static func luminance(_ red: Float, _ green: Float, _ blue: Float) -> Float {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    static func luminance(_ red: Double, _ green: Double, _ blue: Double) -> Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    // MARK: CIELab (D65)

    static func lab(red: Float, green: Float, blue: Float)
        -> (lightness: Double, aStar: Double, bStar: Double, chroma: Double) {
        let r = Double(min(1, max(0, red)))
        let g = Double(min(1, max(0, green)))
        let b = Double(min(1, max(0, blue)))
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ value: Double) -> Double {
            value > 0.008856451679 ? pow(value, 1.0 / 3.0) : 7.787037 * value + 0.1379310345
        }
        let fx = f(max(x, 0)), fy = f(max(y, 0)), fz = f(max(z, 0))
        let lightness = 116 * fy - 16
        let aStar = 500 * (fx - fy)
        let bStar = 200 * (fy - fz)
        let chroma = (aStar * aStar + bStar * bStar).squareRoot()
        return (lightness, aStar, bStar, chroma)
    }

    static func linearRGB(lightness: Double, aStar: Double, bStar: Double)
        -> (Float, Float, Float) {
        let fy = (lightness + 16) / 116
        let fx = fy + aStar / 500
        let fz = fy - bStar / 200
        func inverse(_ value: Double) -> Double {
            let cube = value * value * value
            return cube > 0.008856451679 ? cube : (value - 16.0 / 116.0) / 7.787037
        }
        let x = inverse(fx) * 0.95047
        let y = inverse(fy)
        let z = inverse(fz) * 1.08883
        let red = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let green = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let blue = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        return (Float(red), Float(green), Float(blue))
    }

    private static let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
}

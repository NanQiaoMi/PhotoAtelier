import Foundation

/// P2-K: Granular options for selective adjustment copying and multi-photo batch synchronization.
public struct AdjustmentSyncOptions: Codable, Equatable {
    /// Basic tone adjustments (exposure, contrast, saturation, highlights, shadows).
    public var basicTone: Bool = true

    /// White balance settings (color temperature and tint).
    public var whiteBalance: Bool = true

    /// Tonal and RGB curves.
    public var tonalCurves: Bool = true

    /// 8-channel HSL color adjustments.
    public var hsl: Bool = true

    /// 3-way color wheels and color grading.
    public var colorGrading: Bool = true

    /// Color harmony rules.
    public var colorHarmony: Bool = true

    /// 3D LUT filter profile and intensity/protection settings.
    public var lut: Bool = true

    /// Portrait retouching (blemish removal, skin smoothing, teeth whitening, eye brightening, skin tone).
    public var portraitRetouch: Bool = true

    /// Facial reshaping and feature morphing (liquify).
    public var facialReshape: Bool = true

    /// Facial zonal wrinkle smoothing and anti-shine matte.
    public var facialZonal: Bool = true

    /// Makeup styling (lips, blush, brows, eyeshadow, eyeliner, lashes, catchlight, contouring).
    public var makeup: Bool = true

    /// Hair aesthetics (hair sheen, parting filling, anti-frizz smoothing, flyaway removal).
    public var hair: Bool = true

    /// Clothing wrinkle smoothing.
    public var clothing: Bool = true

    /// Body and hand skin refinement (neck smoothing, vein reduction, body tone harmonization).
    public var bodySkin: Bool = true

    /// Studio backdrop smoothing & defect removal.
    public var backdrop: Bool = true

    /// Pet portrait enhancement (fur fluffiness, eye clarity, muzzle moisture, whitening).
    public var petEnhancement: Bool = false

    /// Smart sky enhancement and atmospheric replacement.
    public var skyEnhancement: Bool = true

    /// Multi-person demographic grouping, per-person profiles & skin tone unification.
    public var multiPerson: Bool = true

    /// Eye catchlight, eyeglass anti-glare, sclera clarity and teeth aesthetic restoration.
    public var eyeTeeth: Bool = true

    /// Smart body reshaping & skeleton posture refinement.
    public var bodyReshape: Bool = true

    /// Smart double eyelid sculpting, eyelid tape concealing & aegyo sal sculpting.
    public var eyelidAegyoSal: Bool = true

    /// Smart bokeh and optical depth-of-field synthesis.
    public var bokehBlur: Bool = true

    /// Smart hair color harmonization, gray hair removal & recoloring.
    public var hairColor: Bool = true

    /// Smart facial hair, peach fuzz removal, beard shadow softening & feature mole management.
    public var facialHair: Bool = true

    /// Smart facial micro-expression, smile & lip shape enhancement.
    public var expression: Bool = true

    /// Smart eye shape reshaping, canthoplasty & mid-face proportion balance.
    public var eyeShape: Bool = true

    /// Smart nose reshaping, 3D bridge contouring & structural correction.
    public var noseReshape: Bool = true

    /// Smart jawline sculpting, chin reshaping & lower-face proportions.
    public var jawChinReshape: Bool = true

    /// Smart temples, cheekbones & facial contour smoothness.
    public var facialContour: Bool = true

    /// Smart eyebrow reshaping, wild brow texture & symmetry calibration.
    public var eyebrowReshape: Bool = true

    /// Lens effects and corrections (vignette, chromatic aberration, profile correction).
    public var lensAndVignette: Bool = true

    /// Creative styling effects (grain, bloom).
    public var creativeEffects: Bool = true

    // MARK: - Protected Per-Photo Specifics (Disabled by default to avoid cross-photo errors)

    /// Local adjustment masks (brush, radial, linear, person segmentation).
    public var localMasks: Bool = false

    /// Manual blemish healing and clone stamp strokes.
    public var repairBrush: Bool = false

    /// Geometry transforms (rotation, perspective, straightening).
    public var geometry: Bool = false

    /// ID photo & background replacement cutout.
    public var certificatePhoto: Bool = false

    public init(
        basicTone: Bool = true,
        whiteBalance: Bool = true,
        tonalCurves: Bool = true,
        hsl: Bool = true,
        colorGrading: Bool = true,
        colorHarmony: Bool = true,
        lut: Bool = true,
        portraitRetouch: Bool = true,
        facialReshape: Bool = true,
        facialZonal: Bool = true,
        makeup: Bool = true,
        hair: Bool = true,
        clothing: Bool = true,
        bodySkin: Bool = true,
        backdrop: Bool = true,
        petEnhancement: Bool = false,
        skyEnhancement: Bool = true,
        multiPerson: Bool = true,
        eyeTeeth: Bool = true,
        bodyReshape: Bool = true,
        eyelidAegyoSal: Bool = true,
        bokehBlur: Bool = true,
        hairColor: Bool = true,
        facialHair: Bool = true,
        expression: Bool = true,
        eyeShape: Bool = true,
        noseReshape: Bool = true,
        jawChinReshape: Bool = true,
        facialContour: Bool = true,
        eyebrowReshape: Bool = true,
        lensAndVignette: Bool = true,
        creativeEffects: Bool = true,
        localMasks: Bool = false,
        repairBrush: Bool = false,
        geometry: Bool = false,
        certificatePhoto: Bool = false
    ) {
        self.basicTone = basicTone
        self.whiteBalance = whiteBalance
        self.tonalCurves = tonalCurves
        self.hsl = hsl
        self.colorGrading = colorGrading
        self.colorHarmony = colorHarmony
        self.lut = lut
        self.portraitRetouch = portraitRetouch
        self.facialReshape = facialReshape
        self.facialZonal = facialZonal
        self.makeup = makeup
        self.hair = hair
        self.clothing = clothing
        self.bodySkin = bodySkin
        self.backdrop = backdrop
        self.petEnhancement = petEnhancement
        self.skyEnhancement = skyEnhancement
        self.multiPerson = multiPerson
        self.eyeTeeth = eyeTeeth
        self.bodyReshape = bodyReshape
        self.eyelidAegyoSal = eyelidAegyoSal
        self.bokehBlur = bokehBlur
        self.hairColor = hairColor
        self.facialHair = facialHair
        self.expression = expression
        self.eyeShape = eyeShape
        self.noseReshape = noseReshape
        self.jawChinReshape = jawChinReshape
        self.facialContour = facialContour
        self.eyebrowReshape = eyebrowReshape
        self.lensAndVignette = lensAndVignette
        self.creativeEffects = creativeEffects
        self.localMasks = localMasks
        self.repairBrush = repairBrush
        self.geometry = geometry
        self.certificatePhoto = certificatePhoto
    }

    /// Selects all standard color grading and retouching modules (excluding composition-specific local masks and brush strokes).
    public static var allAdjustments: AdjustmentSyncOptions {
        AdjustmentSyncOptions(
            basicTone: true,
            whiteBalance: true,
            tonalCurves: true,
            hsl: true,
            colorGrading: true,
            colorHarmony: true,
            lut: true,
            portraitRetouch: true,
            facialReshape: true,
            facialZonal: true,
            makeup: true,
            hair: true,
            clothing: true,
            bodySkin: true,
            backdrop: true,
            petEnhancement: true,
            skyEnhancement: true,
            multiPerson: true,
            eyeTeeth: true,
            bodyReshape: true,
            eyelidAegyoSal: true,
            bokehBlur: true,
            hairColor: true,
            facialHair: true,
            expression: true,
            eyeShape: true,
            noseReshape: true,
            jawChinReshape: true,
            facialContour: true,
            eyebrowReshape: true,
            lensAndVignette: true,
            creativeEffects: true,
            localMasks: false,
            repairBrush: false,
            geometry: false,
            certificatePhoto: false
        )
    }

    /// Optimized for studio and wedding portrait synchronization.
    public static var portraitStudio: AdjustmentSyncOptions {
        AdjustmentSyncOptions(
            basicTone: true,
            whiteBalance: true,
            tonalCurves: true,
            hsl: true,
            colorGrading: true,
            colorHarmony: true,
            lut: true,
            portraitRetouch: true,
            facialReshape: true,
            facialZonal: true,
            makeup: true,
            hair: true,
            clothing: true,
            bodySkin: true,
            backdrop: true,
            petEnhancement: false,
            skyEnhancement: false,
            multiPerson: true,
            eyeTeeth: true,
            bodyReshape: true,
            eyelidAegyoSal: true,
            bokehBlur: true,
            hairColor: true,
            facialHair: true,
            expression: true,
            eyeShape: true,
            noseReshape: true,
            jawChinReshape: true,
            facialContour: true,
            eyebrowReshape: true,
            lensAndVignette: true,
            creativeEffects: false,
            localMasks: false,
            repairBrush: false,
            geometry: false,
            certificatePhoto: false
        )
    }

    /// Optimized for landscape and outdoor scenery synchronization.
    public static var landscapeOutdoor: AdjustmentSyncOptions {
        AdjustmentSyncOptions(
            basicTone: true,
            whiteBalance: true,
            tonalCurves: true,
            hsl: true,
            colorGrading: true,
            colorHarmony: true,
            lut: true,
            portraitRetouch: false,
            facialReshape: false,
            facialZonal: false,
            makeup: false,
            hair: false,
            clothing: false,
            bodySkin: false,
            backdrop: false,
            petEnhancement: false,
            skyEnhancement: true,
            bodyReshape: false,
            eyelidAegyoSal: false,
            bokehBlur: false,
            hairColor: false,
            facialHair: false,
            expression: false,
            eyeShape: false,
            noseReshape: false,
            jawChinReshape: false,
            facialContour: false,
            eyebrowReshape: false,
            lensAndVignette: true,
            creativeEffects: true,
            localMasks: false,
            repairBrush: false,
            geometry: false,
            certificatePhoto: false
        )
    }

    /// Synchronizes color grading and look/LUT parameters only.
    public static var colorGradingOnly: AdjustmentSyncOptions {
        AdjustmentSyncOptions(
            basicTone: false,
            whiteBalance: true,
            tonalCurves: true,
            hsl: true,
            colorGrading: true,
            colorHarmony: true,
            lut: true,
            portraitRetouch: false,
            facialReshape: false,
            facialZonal: false,
            makeup: false,
            hair: false,
            clothing: false,
            bodySkin: false,
            backdrop: false,
            petEnhancement: false,
            skyEnhancement: false,
            bodyReshape: false,
            eyelidAegyoSal: false,
            bokehBlur: false,
            hairColor: false,
            facialHair: false,
            expression: false,
            eyeShape: false,
            noseReshape: false,
            jawChinReshape: false,
            facialContour: false,
            eyebrowReshape: false,
            lensAndVignette: false,
            creativeEffects: false,
            localMasks: false,
            repairBrush: false,
            geometry: false,
            certificatePhoto: false
        )
    }

    /// Clears all selection flags.
    public static var none: AdjustmentSyncOptions {
        AdjustmentSyncOptions(
            basicTone: false,
            whiteBalance: false,
            tonalCurves: false,
            hsl: false,
            colorGrading: false,
            colorHarmony: false,
            lut: false,
            portraitRetouch: false,
            facialReshape: false,
            facialZonal: false,
            makeup: false,
            hair: false,
            clothing: false,
            bodySkin: false,
            backdrop: false,
            petEnhancement: false,
            skyEnhancement: false,
            bodyReshape: false,
            eyelidAegyoSal: false,
            bokehBlur: false,
            hairColor: false,
            facialHair: false,
            expression: false,
            eyeShape: false,
            noseReshape: false,
            jawChinReshape: false,
            facialContour: false,
            eyebrowReshape: false,
            lensAndVignette: false,
            creativeEffects: false,
            localMasks: false,
            repairBrush: false,
            geometry: false,
            certificatePhoto: false
        )
    }
}

/// Engine that performs non-destructive, selective adjustment merging.
public enum AdjustmentSyncEngine {

    /// Merges selected components from `source` into `target` according to `options`.
    ///
    /// - Parameters:
    ///   - source: Source adjustments containing values to copy.
    ///   - target: Existing target adjustments to be selectively modified.
    ///   - options: Granular module flags.
    ///   - sourceLUT: Optional LUT identifier associated with the source adjustments.
    ///   - targetLUT: In-out LUT identifier for the target adjustments.
    /// - Returns: A new `AdjustmentSettings` struct with selected parts updated and unselected parts preserved.
    public static func merge(
        source: AdjustmentSettings,
        into target: AdjustmentSettings,
        options: AdjustmentSyncOptions,
        sourceLUT: String? = nil,
        targetLUT: inout String
    ) -> AdjustmentSettings {
        var result = target

        // 1. Basic tone
        if options.basicTone {
            result.exposureEV = source.exposureEV
            result.contrast = source.contrast
            result.saturation = source.saturation
            result.highlights = source.highlights
            result.shadows = source.shadows
            result.autoExposure = source.autoExposure
        }

        // 2. White balance
        if options.whiteBalance {
            result.temperature = source.temperature
            result.tint = source.tint
            result.autoWhiteBalance = source.autoWhiteBalance
        }

        // 3. Tonal curves
        if options.tonalCurves {
            result.tonalCurve = source.tonalCurve
            if let srcTools = source.colorTools {
                var tools = result.colorTools ?? ColorToolsSettings()
                tools.curves = srcTools.curves
                result.colorTools = tools
            }
        }

        // 4. HSL
        if options.hsl {
            if let srcTools = source.colorTools {
                var tools = result.colorTools ?? ColorToolsSettings()
                tools.hsl = srcTools.hsl
                result.colorTools = tools
            }
        }

        // 5. Color grading
        if options.colorGrading {
            if let srcTools = source.colorTools {
                var tools = result.colorTools ?? ColorToolsSettings()
                tools.grading = srcTools.grading
                result.colorTools = tools
            }
        }

        // 6. Color harmony
        if options.colorHarmony {
            result.colorHarmony = source.colorHarmony
        }

        // 7. LUT & Adaptation
        if options.lut {
            result.lutIntensity = source.lutIntensity
            result.lutColorSpace = source.lutColorSpace
            result.preserveLuminance = source.preserveLuminance
            result.protectSkin = source.protectSkin
            result.protectNeutrals = source.protectNeutrals
            result.gamutCompression = source.gamutCompression
            result.adaptiveLUT = source.adaptiveLUT
            if let lut = sourceLUT {
                targetLUT = lut
            }
        }

        // 8. Portrait retouching
        if options.portraitRetouch {
            result.portrait = source.portrait
        }

        // 9. Facial reshape & liquify
        if options.facialReshape {
            result.liquify = source.liquify
        }

        // 10. Facial zonal wrinkle smoothing & anti-shine
        if options.facialZonal {
            result.facialZonal = source.facialZonal
        }

        // 11. Makeup
        if options.makeup {
            result.makeup = source.makeup
        }

        // 12. Clothing & Body skin
        if options.clothing {
            result.clothing = source.clothing
        }
        if options.bodySkin {
            result.bodySkin = source.bodySkin
        }

        // 13. Studio backdrop
        if options.backdrop {
            result.backdrop = source.backdrop
        }

        // 14. Pet enhancement
        if options.petEnhancement {
            result.petEnhancement = source.petEnhancement
        }

        // 15. Sky enhancement
        if options.skyEnhancement {
            result.sky = source.sky
        }

        // 15b. Multi-person demographic grouping & per-person profiles
        if options.multiPerson {
            result.multiPerson = source.multiPerson
        }

        // 15c. Eye catchlight & aesthetic teeth refinement
        if options.eyeTeeth {
            result.eyeTeeth = source.eyeTeeth
        }

        // 15d. Smart body reshaping & skeleton posture refinement
        if options.bodyReshape {
            result.bodyReshape = source.bodyReshape
        }

        // 15e. Smart double eyelid sculpting, eyelid tape concealing & aegyo sal sculpting
        if options.eyelidAegyoSal {
            result.eyelidAegyoSal = source.eyelidAegyoSal
        }

        // 15f. Smart bokeh & optical depth-of-field synthesis
        if options.bokehBlur {
            result.bokehBlur = source.bokehBlur
        }

        // 15g. Smart hair color harmonization, gray hair removal & recoloring
        if options.hairColor {
            result.hairColor = source.hairColor
        }

        // 15h. Smart facial hair, peach fuzz removal & feature mole management
        if options.facialHair {
            result.facialHair = source.facialHair
        }

        // 15i. Smart facial micro-expression, smile & lip shape enhancement
        if options.expression {
            result.expression = source.expression
        }

        // 15j. Smart eye shape reshaping, canthoplasty & mid-face proportion balance
        if options.eyeShape {
            result.eyeShape = source.eyeShape
        }

        // 15k. Smart nose reshaping, 3D bridge contouring & structural correction
        if options.noseReshape {
            result.noseReshape = source.noseReshape
        }

        // 15l. Smart jawline sculpting, chin reshaping & lower-face proportions
        if options.jawChinReshape {
            result.jawChinReshape = source.jawChinReshape
        }

        // 15m. Smart temples, cheekbones & facial contour smoothness
        if options.facialContour {
            result.facialContour = source.facialContour
        }

        // 15n. Smart eyebrow reshaping, wild brow texture & symmetry calibration
        if options.eyebrowReshape {
            result.eyebrowReshape = source.eyebrowReshape
        }

        // 16. Lens effects & corrections
        if options.lensAndVignette {
            result.lensEffects = source.lensEffects
            result.lensCorrection = source.lensCorrection
            result.lensProfileID = source.lensProfileID
            result.lensCropFactor = source.lensCropFactor
            result.lensFocalLength = source.lensFocalLength
        }

        // 17. Creative effects (grain, bloom)
        if options.creativeEffects {
            result.creativeEffects = source.creativeEffects
        }

        // 18. Local masks (only if explicitly opted-in)
        if options.localMasks {
            result.masks = source.masks
        }

        // 19. Repair brush strokes (only if explicitly opted-in)
        if options.repairBrush {
            result.repairBrush = source.repairBrush
        }

        // 20. Geometry (only if explicitly opted-in)
        if options.geometry {
            result.autoStraighten = source.autoStraighten
            result.rotationDegrees = source.rotationDegrees
            result.verticalPerspective = source.verticalPerspective
            result.horizontalPerspective = source.horizontalPerspective
        }

        // 21. Certificate photo (only if explicitly opted-in)
        if options.certificatePhoto {
            result.certificatePhoto = source.certificatePhoto
        }

        return result
    }
}

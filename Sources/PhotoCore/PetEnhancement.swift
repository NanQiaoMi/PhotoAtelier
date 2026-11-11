import Foundation
import CoreImage
import Vision

/// A detected pet target (Cat or Dog) with bounding box and classification details.
public struct PetTarget: Equatable {
    /// Bounding box in normalized coordinates (0...1) with bottom-left origin.
    public var boundingBox: CGRect
    /// Classification label (e.g. "Cat", "Dog").
    public var label: String
    /// Recognition confidence score (0...1).
    public var confidence: Float

    public init(boundingBox: CGRect, label: String = "Cat", confidence: Float = 0.9) {
        self.boundingBox = boundingBox
        self.label = label
        self.confidence = confidence
    }
}

/// P2-I: Smart pet portrait enhancement engine.
///
/// Provides dedicated, native, zero-external-model pet retouching:
/// 1. `furFluffiness`: Micro-contrast and high-frequency hair/fur definition booster.
/// 2. `eyeBrightening`: Pet eye socket shadow lifting and catchlight sparkle enhancement.
/// 3. `muzzleMoisture`: Velvety dark depth and specular moist reflections on nose/snout.
/// 4. `coatDehaze`: Eliminates atmospheric haze and enhances natural fur color purity.
/// 5. `coatWhiten`: Neutralizes yellowish discoloration on white and pale fur.
/// 6. `texturePreservation`: Preserves individual fur strands preventing plastic look.
public enum PetEnhancementEngine {

    private static let petKernel: CIColorKernel? = {
        let kernelSource = """
        kernel vec4 petEnhance(
            sampler orig,
            sampler blurred,
            sampler coatMask,
            sampler eyesMask,
            sampler muzzleMask,
            float furFluffiness,
            float eyeBrightening,
            float muzzleMoisture,
            float coatDehaze,
            float coatWhiten,
            float texturePreservation
        ) {
            vec4 c = sample(orig, samplerCoord(orig));
            vec4 b = sample(blurred, samplerCoord(blurred));
            float coat = sample(coatMask, samplerCoord(coatMask)).r;
            float eyes = sample(eyesMask, samplerCoord(eyesMask)).r;
            float muzzle = sample(muzzleMask, samplerCoord(muzzleMask)).r;

            float activeWeight = max(coat, max(eyes, muzzle));
            if (activeWeight <= 0.001) {
                return c;
            }

            vec3 high = c.rgb - b.rgb;
            float lum = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));

            // 1. Fur Fluffiness: micro-contrast & edge definition in coat
            vec3 fluffy = c.rgb;
            if (furFluffiness > 0.001 && coat > 0.001) {
                fluffy += high * furFluffiness * 0.85 * coat;
                fluffy = clamp(fluffy, 0.0, 1.0);
            }

            // 2. Pet Eye Brightening: shadow lift + catchlight boost in eye sockets
            vec3 eyeColor = fluffy;
            if (eyeBrightening > 0.001 && eyes > 0.001) {
                float eLum = dot(eyeColor, vec3(0.2126, 0.7152, 0.0722));
                float lift = eLum * (1.0 - eLum) * eyeBrightening * 0.75 * eyes;
                eyeColor += vec3(lift);
                if (eLum > 0.55) {
                    eyeColor += (eyeColor - 0.55) * eyeBrightening * 0.40 * eyes;
                }
                eyeColor = clamp(eyeColor, 0.0, 1.0);
            }

            // 3. Muzzle Moisture: deepen velvety darks & boost specular moisture gleam
            vec3 muzColor = eyeColor;
            if (muzzleMoisture > 0.001 && muzzle > 0.001) {
                float mLum = dot(muzColor, vec3(0.2126, 0.7152, 0.0722));
                float darkDip = (1.0 - mLum) * muzzleMoisture * 0.15 * muzzle;
                muzColor -= vec3(darkDip);
                if (mLum > 0.50) {
                    muzColor += (mLum - 0.50) * muzzleMoisture * 0.45 * muzzle;
                }
                muzColor = clamp(muzColor, 0.0, 1.0);
            }

            // 4. Coat Dehaze: remove gray veil, enhance rich color purity
            vec3 dehazed = muzColor;
            if (coatDehaze > 0.001 && coat > 0.001) {
                float factor = 0.04 * coatDehaze * coat;
                dehazed = (dehazed - vec3(factor)) / max(0.001, 1.0 - factor);
                dehazed = clamp(dehazed, 0.0, 1.0);
                float dLum = dot(dehazed, vec3(0.2126, 0.7152, 0.0722));
                dehazed = mix(vec3(dLum), dehazed, 1.0 + coatDehaze * 0.25 * coat);
                dehazed = clamp(dehazed, 0.0, 1.0);
            }

            // 5. White / Pale Coat Whiten: neutralize yellowish tint
            vec3 whitened = dehazed;
            if (coatWhiten > 0.001 && coat > 0.001) {
                float yellowExcess = max(0.0, min(whitened.r, whitened.g) - whitened.b);
                float wLum = dot(whitened, vec3(0.2126, 0.7152, 0.0722));
                float whitenAmount = coatWhiten * coat * clamp(wLum * 1.5, 0.0, 1.0);
                whitened.b += yellowExcess * whitenAmount * 0.75;
                whitened = clamp(whitened, 0.0, 1.0);
            }

            // 6. Texture Preservation: re-inject fine hair/fur definition
            vec3 finalRgb = whitened;
            if (texturePreservation > 0.001 && coat > 0.001) {
                finalRgb += high * texturePreservation * 0.35 * coat;
                finalRgb = clamp(finalRgb, 0.0, 1.0);
            }

            return vec4(finalRgb, c.a);
        }
        """
        return CIColorKernel(source: kernelSource)
    }()

    /// Detects cats and dogs in the image using Vision framework.
    public static func detectAnimals(in image: CIImage) -> [PetTarget] {
        let request = VNRecognizeAnimalsRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try? handler.perform([request])
        guard let results = request.results else { return [] }
        return results.compactMap { obs in
            guard obs.confidence >= 0.25 else { return nil }
            guard let matched = obs.labels.first(where: {
                let id = $0.identifier.lowercased()
                return id.contains("cat") || id.contains("dog")
            }) else { return nil }
            return PetTarget(boundingBox: obs.boundingBox, label: matched.identifier, confidence: obs.confidence)
        }
    }

    /// Applies pet enhancement to the image.
    public static func apply(
        _ image: CIImage,
        settings: PetEnhancementSettings,
        targets: [PetTarget]? = nil,
        context: CIContext? = nil,
        cancellation: CancellationToken? = nil
    ) throws -> (image: CIImage, report: PetEnhancementReport) {
        try cancellation?.check()
        guard !settings.isNeutral else {
            return (image, PetEnhancementReport(applied: false, petCount: 0, appliedSteps: [], note: "宠物美化处于中性状态（未修改像素）。"))
        }

        let detectedTargets: [PetTarget]
        if let targets {
            detectedTargets = targets
        } else {
            detectedTargets = detectAnimals(in: image)
        }

        guard !detectedTargets.isEmpty else {
            return (image, PetEnhancementReport(applied: false, petCount: 0, appliedSteps: [], note: "未检测到猫/狗宠物目标，跳过宠物美化。"))
        }

        guard let kernel = petKernel else {
            return (image, PetEnhancementReport(applied: false, petCount: detectedTargets.count, appliedSteps: [], note: "Core Image Kernel 初始化失败。"))
        }

        let extent = image.extent
        let shorterEdge = Double(min(extent.width, extent.height))

        // 1. Generate Masks
        let coatMask = makeAnimalCoatMask(targets: detectedTargets, extent: extent, shorterEdge: shorterEdge)
        let eyesMask = makePetEyesMask(targets: detectedTargets, extent: extent, shorterEdge: shorterEdge)
        let muzzleMask = makePetMuzzleMask(targets: detectedTargets, extent: extent, shorterEdge: shorterEdge)

        // 2. High-frequency blurred base for frequency separation
        let blurRadius = max(2.0, shorterEdge * 0.015)
        let blurred = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: extent)

        try cancellation?.check()

        var appliedSteps: [String] = []
        if settings.furFluffiness > 0 { appliedSteps.append("毛发蓬松") }
        if settings.eyeBrightening > 0 { appliedSteps.append("明眸提亮") }
        if settings.muzzleMoisture > 0 { appliedSteps.append("鼻吻润泽") }
        if settings.coatDehaze > 0 { appliedSteps.append("毛发去灰") }
        if settings.coatWhiten > 0 { appliedSteps.append("白毛去黄") }

        let arguments: [Any] = [
            image,
            blurred,
            coatMask,
            eyesMask,
            muzzleMask,
            Float(settings.furFluffiness),
            Float(settings.eyeBrightening),
            Float(settings.muzzleMoisture),
            Float(settings.coatDehaze),
            Float(settings.coatWhiten),
            Float(settings.texturePreservation)
        ]

        guard let processed = kernel.apply(extent: extent, arguments: arguments) else {
            return (image, PetEnhancementReport(applied: false, petCount: detectedTargets.count, appliedSteps: [], note: "着色器处理失败，返回原图。"))
        }

        let report = PetEnhancementReport(
            applied: true,
            petCount: detectedTargets.count,
            appliedSteps: appliedSteps,
            note: "已对 \(detectedTargets.count) 只宠物应用美化（\(appliedSteps.joined(separator: "、"))）。"
        )

        return (processed, report)
    }

    private static func makeBlackMask(extent: CGRect) -> CIImage {
        return CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
    }

    private static func makeAnimalCoatMask(targets: [PetTarget], extent: CGRect, shorterEdge: Double) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return makeBlackMask(extent: extent)
        }
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1.0, alpha: 1.0)

        for target in targets {
            let bbox = target.boundingBox
            let ax = bbox.origin.x * extent.width
            let ay = bbox.origin.y * extent.height
            let aw = bbox.width * extent.width
            let ah = bbox.height * extent.height

            // Main animal body & coat coverage
            let bodyRect = CGRect(x: ax + aw * 0.05, y: ay + ah * 0.05, width: aw * 0.90, height: ah * 0.90)
            ctx.fillEllipse(in: bodyRect)
        }

        guard let cgImage = ctx.makeImage() else {
            return makeBlackMask(extent: extent)
        }

        let rawMask = CIImage(cgImage: cgImage)
        let blurRadius = max(2.0, shorterEdge * 0.04)
        return rawMask.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: extent)
    }

    private static func makePetEyesMask(targets: [PetTarget], extent: CGRect, shorterEdge: Double) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return makeBlackMask(extent: extent)
        }
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1.0, alpha: 1.0)

        for target in targets {
            let bbox = target.boundingBox
            let ax = bbox.origin.x * extent.width
            let ay = bbox.origin.y * extent.height
            let aw = bbox.width * extent.width
            let ah = bbox.height * extent.height

            let headX = ax + aw * 0.50
            let headY = ay + ah * 0.72
            let eyeRadius = max(2.0, min(aw, ah) * 0.07)
            let eyeSpacing = aw * 0.16

            // Left eye
            let leftEyeRect = CGRect(x: headX - eyeSpacing - eyeRadius, y: headY + ah * 0.02 - eyeRadius, width: eyeRadius * 2, height: eyeRadius * 2)
            ctx.fillEllipse(in: leftEyeRect)

            // Right eye
            let rightEyeRect = CGRect(x: headX + eyeSpacing - eyeRadius, y: headY + ah * 0.02 - eyeRadius, width: eyeRadius * 2, height: eyeRadius * 2)
            ctx.fillEllipse(in: rightEyeRect)
        }

        guard let cgImage = ctx.makeImage() else {
            return makeBlackMask(extent: extent)
        }

        let rawMask = CIImage(cgImage: cgImage)
        let blurRadius = max(1.5, shorterEdge * 0.015)
        return rawMask.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: extent)
    }

    private static func makePetMuzzleMask(targets: [PetTarget], extent: CGRect, shorterEdge: Double) -> CIImage {
        let width = Int(max(1, extent.width))
        let height = Int(max(1, extent.height))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return makeBlackMask(extent: extent)
        }
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1.0, alpha: 1.0)

        for target in targets {
            let bbox = target.boundingBox
            let ax = bbox.origin.x * extent.width
            let ay = bbox.origin.y * extent.height
            let aw = bbox.width * extent.width
            let ah = bbox.height * extent.height

            let headX = ax + aw * 0.50
            let muzzleY = ay + ah * 0.59
            let muzzleW = aw * 0.24
            let muzzleH = ah * 0.16

            let muzzleRect = CGRect(x: headX - muzzleW * 0.50, y: muzzleY - muzzleH * 0.50, width: muzzleW, height: muzzleH)
            ctx.fillEllipse(in: muzzleRect)
        }

        guard let cgImage = ctx.makeImage() else {
            return makeBlackMask(extent: extent)
        }

        let rawMask = CIImage(cgImage: cgImage)
        let blurRadius = max(2.0, shorterEdge * 0.025)
        return rawMask.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: extent)
    }
}

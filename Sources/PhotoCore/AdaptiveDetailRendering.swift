import CoreImage
import Foundation

/// Combines per-mask adaptive detail candidates, all rendered from one shared
/// reference image, so overlapping masks do not feed processed pixels back into
/// later measurements or compound the detail operation.
enum AdaptiveDetailRenderer {
    private static let deltaAccumulationKernel = CIColorKernel(source: """
    kernel vec4 accumulateAdaptiveDelta(__sample sumSample,
                                        __sample weightedCandidateSample,
                                        __sample referenceSample) {
        vec3 sum = sumSample.rgb;
        if (!(abs(sum.r) <= 65504.0) || !(abs(sum.g) <= 65504.0)
            || !(abs(sum.b) <= 65504.0)) { sum = vec3(0.0); }

        float referenceAlpha = referenceSample.a;
        float candidateAlpha = weightedCandidateSample.a;
        if (!(referenceAlpha > 0.000001) || !(referenceAlpha <= 1.0)
            || !(candidateAlpha > 0.000001) || !(candidateAlpha <= 1.0)) {
            return vec4(sum, 1.0);
        }

        vec3 referenceColor = referenceSample.rgb / referenceAlpha;
        vec3 candidateColor = weightedCandidateSample.rgb / candidateAlpha;
        if (!(abs(referenceColor.r) <= 65504.0)
            || !(abs(referenceColor.g) <= 65504.0)
            || !(abs(referenceColor.b) <= 65504.0)
            || !(abs(candidateColor.r) <= 65504.0)
            || !(abs(candidateColor.g) <= 65504.0)
            || !(abs(candidateColor.b) <= 65504.0)) {
            return vec4(sum, 1.0);
        }

        vec3 delta = candidateColor - referenceColor;
        if (!(abs(delta.r) <= 65504.0) || !(abs(delta.g) <= 65504.0)
            || !(abs(delta.b) <= 65504.0)) { return vec4(sum, 1.0); }

        // Keep each accumulation representable in RGBAh while retaining signed
        // RGB deltas. Alpha is always one; coverage totals live in red instead.
        vec3 nextSum = clamp(sum + delta, vec3(-60000.0), vec3(60000.0));
        return vec4(nextSum, 1.0);
    }
    """)

    private static let coverageAccumulationKernel = CIColorKernel(source: """
    kernel vec4 accumulateAdaptiveCoverage(__sample sumSample,
                                          __sample coverageSample) {
        float accumulated = sumSample.r;
        if (!(accumulated >= 0.0) || !(accumulated <= 60000.0)) {
            accumulated = 0.0;
        }
        float coverage = coverageSample.r;
        if (!(coverage >= 0.0) || !(coverage <= 1.0)) {
            return vec4(accumulated, accumulated, accumulated, 1.0);
        }
        float total = min(60000.0, accumulated + coverage);
        return vec4(total, total, total, 1.0);
    }
    """)

    private static let finalBlendKernel = CIColorKernel(source: """
    kernel vec4 blendAdaptiveDelta(__sample referenceSample,
                                  __sample deltaSample,
                                  __sample coverageSample) {
        float alpha = referenceSample.a;
        if (!(alpha > 0.000001) || !(alpha <= 1.0)) { return referenceSample; }

        vec3 referenceColor = referenceSample.rgb / alpha;
        vec3 sumDelta = deltaSample.rgb;
        float sumCoverage = coverageSample.r;
        if (!(abs(referenceColor.r) <= 65504.0)
            || !(abs(referenceColor.g) <= 65504.0)
            || !(abs(referenceColor.b) <= 65504.0)
            || !(abs(sumDelta.r) <= 60000.0)
            || !(abs(sumDelta.g) <= 60000.0)
            || !(abs(sumDelta.b) <= 60000.0)
            || !(sumCoverage >= 0.0) || !(sumCoverage <= 60000.0)) {
            return referenceSample;
        }

        vec3 outputColor = referenceColor + sumDelta / max(1.0, sumCoverage);
        if (!(abs(outputColor.r) <= 65504.0)
            || !(abs(outputColor.g) <= 65504.0)
            || !(abs(outputColor.b) <= 65504.0)) { return referenceSample; }

        float sourceWithinSDR = referenceColor.r >= 0.0 && referenceColor.r <= 1.0
            && referenceColor.g >= 0.0 && referenceColor.g <= 1.0
            && referenceColor.b >= 0.0 && referenceColor.b <= 1.0 ? 1.0 : 0.0;
        if (sourceWithinSDR > 0.5
            && (outputColor.r < 0.0 || outputColor.r > 1.0
                || outputColor.g < 0.0 || outputColor.g > 1.0
                || outputColor.b < 0.0 || outputColor.b > 1.0)) {
            // The weighted result should be convex. If finite precision violates
            // that invariant, keep the source instead of clipping a channel.
            return referenceSample;
        }
        return vec4(outputColor * alpha, alpha);
    }
    """)

    static func apply(reference: CIImage,
                      masks: [LocalMask],
                      plans: [UUID: LocalDetailPlan],
                      context: CIContext,
                      contentSelections: ContentSelectionResult?,
                      cancellation: CancellationToken?) throws -> CIImage {
        guard !plans.isEmpty else { return reference }

        let extent = reference.extent
        guard !extent.isNull, !extent.isInfinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else {
            throw AtelierError.invalidConfiguration("自适应细节合成需要有限且非空的参考图范围。")
        }

        let activeMasks = masks.filter { mask in
            plans[mask.id]?.settings.isNeutral == false && mask.enabled && mask.opacity != 0
        }
        guard !activeMasks.isEmpty else { return reference }

        let opaqueZero = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: extent)
        var sumDelta = opaqueZero
        var sumCoverage = opaqueZero

        for mask in activeMasks {
            try cancellation?.check()
            guard let plan = plans[mask.id] else { continue }

            let coverage = try LocalMaskEngine.coverage(for: mask,
                                                        reference: reference,
                                                        context: context,
                                                        contentSelections: contentSelections)
            guard coverage.extent == extent else {
                throw AtelierError.invalidConfiguration("自适应细节覆盖图与参考图范围不一致。")
            }
            let candidate = try LocalDetailEngine.apply(reference,
                settings: plan.settings, noiseEstimate: plan.noiseEstimate,
                modernProtection: true, samplingMask: plan.sampling == nil ? nil : coverage,
                samplingPlan: plan.sampling)
            guard candidate.extent == extent else {
                throw AtelierError.invalidConfiguration("自适应细节候选与参考图范围不一致。")
            }
            let weightedCandidate = try LocalMaskEngine.protectAdaptiveCandidate(
                candidate, reference: reference, coverage: coverage, mask: mask)
            guard weightedCandidate.extent == extent else {
                throw AtelierError.invalidConfiguration("受保护的自适应细节候选与参考图范围不一致。")
            }

            guard let deltaKernel = deltaAccumulationKernel,
                  let nextDelta = deltaKernel.apply(extent: extent, arguments: [
                    sumDelta, weightedCandidate, reference
                  ]) else {
                throw AtelierError.invalidConfiguration("自适应细节变化量无法累加。")
            }
            guard let coverageKernel = coverageAccumulationKernel,
                  let nextCoverage = coverageKernel.apply(extent: extent, arguments: [
                    sumCoverage, coverage
                  ]) else {
                throw AtelierError.invalidConfiguration("自适应细节覆盖权重无法累加。")
            }
            sumDelta = nextDelta.cropped(to: extent)
            sumCoverage = nextCoverage.cropped(to: extent)
        }

        try cancellation?.check()
        guard let blendKernel = finalBlendKernel,
              let output = blendKernel.apply(extent: extent, arguments: [
                reference, sumDelta, sumCoverage
              ]) else {
            throw AtelierError.invalidConfiguration("自适应细节总合成失败。")
        }
        return output.cropped(to: extent)
    }
}

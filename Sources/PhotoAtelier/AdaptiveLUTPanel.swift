import SwiftUI
import PhotoCore

struct AdaptiveLUTPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("按每张照片适配 LUT", isOn: Binding(get: { model.adjustments.adaptiveLUT?.enabled == true },
                set: { enabled in
                    var value = model.adjustments.adaptiveLUT ?? AdaptiveLUTSettings()
                    value.enabled = enabled; model.adjustments.adaptiveLUT = value
                }))
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            if model.adjustments.adaptiveLUT?.enabled == true {
                Text("强度是上限。分别测量人脸皮肤候选、亮暗层次和颜色变化，试渲染后选择符合当前保护的组合；原片冷暖与手动参数保持你的意图。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(3)
                AdjustmentSlider(title: "局部颜色约束", value: binding(\.colorProtection), range: 0...1, percent: true)
                AdjustmentSlider(title: "面部颜色约束", value: binding(\.skinProtection), range: 0...1, percent: true)
                AdjustmentSlider(title: "局部影调约束", value: binding(\.toneProtection), range: 0...1, percent: true)
                Toggle("保留原片黑白", isOn: Binding(get: { model.adjustments.adaptiveLUT?.preserveSourceMonochrome ?? true },
                    set: { enabled in
                        var value = model.adjustments.adaptiveLUT ?? AdaptiveLUTSettings()
                        value.preserveSourceMonochrome = enabled; model.adjustments.adaptiveLUT = value
                    })).font(.system(size: 10)).toggleStyle(.checkbox)
                if !model.lutSpaceConfirmed {
                    Text("此 LUT 的空间尚未确认，请依作者说明选择并确认；逐图适配暂停。")
                        .font(.system(size: 10)).foregroundColor(.orange)
                }
            }
            if let source = model.selectedOption?.provenance {
                DisclosureGroup("此胶片风格的来源") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("\(source.author) · \(source.license)")
                        Text("第三方手调近似，非原厂 LUT，也不保证复现相机机内色彩。输入／输出均为正常 sRGB；RAW 已在解码后进入工作空间。")
                        if let url = URL(string: source.sourceURL) { Link("查看固定版本源码与许可", destination: url) }
                    }.font(.system(size: 9)).padding(.top, 6)
                }.font(.system(size: 10))
            }
            if let report = model.previewReport.lutAdaptation {
                DisclosureGroup("当前照片的适配依据") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(report.summary).foregroundColor(AtelierPalette.accent)
                        if !report.contentLabels.isEmpty {
                            Text("题材候选：" + report.contentLabels.prefix(3).map { "\($0.label) \(Int($0.confidence * 100))%" }.joined(separator: "、"))
                        }
                        Text("人脸 \(report.faceCount) · 皮肤样本 \(report.skinSampleCount) · \(report.sampleWidth)×\(report.sampleHeight) 小样")
                        ForEach(Array(report.reasons.enumerated()), id: \.offset) { _, reason in Text(reason) }
                        if let selected = report.candidates.first(where: { $0.id == report.selectedCandidateID }) {
                            Text(String(format: "实际亮度保持 %.0f%% · 肤色保护 %.0f%% · 中性保护 %.0f%%",
                                selected.preserveLuminance * 100, selected.protectSkin * 100, selected.protectNeutrals * 100))
                            Text(String(format: "当前分辨率新增剪切：亮部 %.4f%% · 暗部 %.4f%%",
                                report.nativeIntroducedHighlights * 100, report.nativeIntroducedShadows * 100))
                        }
                        DisclosureGroup("试渲染的组合") {
                            ForEach(report.candidates, id: \.id) { candidate in
                                Text(String(format: "%.0f%% / 局部保护 %.0f%%：%@%@", candidate.intensity * 100,
                                    candidate.localProtection * 100, candidateStatus(candidate),
                                    candidate.id == report.selectedCandidateID ? " · 已采用" : ""))
                            }
                        }
                        Text(report.scope).foregroundColor(AtelierPalette.muted)
                        Text("缩小预览与导出会各自测量当前分辨率；最终效果请用原尺寸检查。")
                            .foregroundColor(AtelierPalette.muted)
                    }.font(.system(size: 9)).lineSpacing(3).padding(.top, 7)
                }.font(.system(size: 10)).opacity(model.previewBusy ? 0.45 : 1)
            }
        }.disabled(model.selectedLUT == "none" || model.batchRunning)
    }

    private func candidateStatus(_ candidate: LUTAdaptationCandidate) -> String {
        if candidate.nativeSafetyAccepted == true { return "小样光色与原尺寸剪切检查通过" }
        if !candidate.reasons.isEmpty { return candidate.reasons.joined(separator: "、") }
        if candidate.sampleQualityAccepted == true { return "小样光色通过 · 未执行原尺寸检查" }
        return candidate.accepted ? "旧报告：小样约束通过" : "旧报告：未通过约束"
    }

    private func binding(_ key: WritableKeyPath<AdaptiveLUTSettings, Double>) -> Binding<Double> {
        Binding(get: { (model.adjustments.adaptiveLUT ?? AdaptiveLUTSettings())[keyPath: key] }, set: { number in
            var value = model.adjustments.adaptiveLUT ?? AdaptiveLUTSettings()
            value[keyPath: key] = number; model.adjustments.adaptiveLUT = value
        })
    }
}

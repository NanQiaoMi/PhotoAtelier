import SwiftUI
import PhotoCore

struct AdaptiveDetailControls: View {
    @ObservedObject var model: AppModel
    let mask: LocalMask

    private var active: LocalMask { model.adjustments.masks.first { $0.id == mask.id } ?? mask }
    private var plan: LocalDetailPlan? { model.previewReport.localDetails?.first { $0.maskID == mask.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("逐图测量并适配细节", isOn: Binding(get: { active.detailAdaptation != nil }, set: { enabled in
                update { $0.detailAdaptation = enabled ? LocalDetailAdaptation() : nil }
            })).toggleStyle(.switch).controlSize(.mini)
            if let adaptation = active.detailAdaptation {
                Picker("处理方向", selection: Binding(get: { active.detailAdaptation?.intent ?? .automatic }, set: { intent in
                    update { $0.detailAdaptation?.intent = intent }
                })) {
                    ForEach(LocalDetailIntent.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                AdjustmentSlider(title: "适配强度", value: Binding(get: {
                    active.detailAdaptation?.strength ?? adaptation.strength
                }, set: { amount in update { $0.detailAdaptation?.strength = amount } }), range: 0...1, percent: true)
                Text("每张重新测量当前覆盖，细节统一先于局部光色与滤镜执行；手动细节值暂存，关闭适配后恢复。曝光、光色与独立锐化仍按你的设置执行。")
                    .foregroundColor(AtelierPalette.muted)
                if active.contentSelection == .faceSkin && (active.inverted || active.components.contains { $0.operation == .add }) {
                    Text("加选或反选后不自动继承皮肤方向。需要精修皮肤，可单独手绘选区并选择皮肤纹理优先。")
                        .foregroundColor(AtelierPalette.muted)
                }
                if let plan {
                    Text("本图方向：\(plan.resolvedIntent.title)").foregroundColor(AtelierPalette.accent)
                    Text(String(format: "平整 %.0f%% · 保留纹理 %.0f%% · 色调均匀 %.0f%%\n噪点减弱 %.0f%% · 纹理增强 %.0f%%",
                        plan.settings.smoothing * 100, plan.settings.textureRetention * 100,
                        plan.settings.toneUniformity * 100, plan.settings.noiseReduction * 100,
                        plan.settings.detailRecovery * 100))
                    DisclosureGroup("测量依据与处理边界") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array((plan.evidence + plan.warnings).enumerated()), id: \.offset) { _, text in
                                Text(text).fixedSize(horizontal: false, vertical: true)
                            }
                        }.foregroundColor(AtelierPalette.muted)
                    }
                } else {
                    Text(model.previewBusy ? "正在测量当前区域…" : "选区不足或尚未完成预览。")
                        .foregroundColor(AtelierPalette.muted)
                }
                Text("此处依据预览图像；导出按原尺寸重新测量，细节强度可能不同。无法恢复源文件已丢失的纹理。")
                    .foregroundColor(AtelierPalette.muted)
            }
        }.font(.system(size: 9)).lineSpacing(4)
            .disabled(model.batchRunning || model.scanning || model.selectedPhoto == nil)
    }

    private func update(_ mutation: (inout LocalMask) -> Void) {
        guard !model.batchRunning, let index = model.adjustments.masks.firstIndex(where: { $0.id == mask.id }) else { return }
        mutation(&model.adjustments.masks[index])
        model.requestPreview()
    }
}

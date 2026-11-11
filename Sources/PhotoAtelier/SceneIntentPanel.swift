import PhotoCore
import SwiftUI

struct SceneIntentPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("题材与处理意图").font(.system(size: 11, weight: .medium))
            Picker("处理方向", selection: Binding(get: { model.sceneIntent }, set: { model.setSceneIntent($0) })) {
                ForEach(PhotoSceneIntent.allCases) { intent in Text(intent.title).tag(intent) }
            }.labelsHidden().font(.system(size: 11)).disabled(model.batchRunning)
            if let scene = model.analysis?.sceneAssessment {
                HStack(alignment: .firstTextBaseline) {
                    Text(scene.category.title).foregroundColor(AtelierPalette.accent)
                    Spacer()
                    Text(source(scene.selectionSource)).foregroundColor(AtelierPalette.muted)
                }.font(.system(size: 10, weight: .medium))
                Text(scene.balanced.direction).font(.system(size: 10)).lineSpacing(4)
                if let subject = scene.subject {
                    Text(String(format: "人脸框内实测：%d 处，P50 %.3f，覆盖 %.1f%%。框内并非全部为皮肤。",
                                subject.faceCount, subject.medianLuminance, subject.coverage * 100))
                        .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                }
                DisclosureGroup("判断依据与不确定性") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(scene.evidence.enumerated()), id: \.offset) { _, text in
                            Text(text).font(.system(size: 9))
                        }
                        ForEach(Array(scene.uncertainties.enumerated()), id: \.offset) { _, text in
                            Text(text).font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                        }
                    }.lineSpacing(3).padding(.top, 8)
                }.font(.system(size: 10))
            }
            Text(model.automaticRecipe == nil
                 ? "此处更新分析和三种预览；点击方案后用于逐张批处理。LUT 沿用你的选择。"
                 : "切换意图会逐张重算当前路线，并保留手动微调；“保留已有风格”会固定当前基础结果。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(AtelierPalette.raised.opacity(0.5)).cornerRadius(6)
    }

    private func source(_ source: PhotoSceneSelectionSource) -> String {
        switch source {
        case .user: return "用户指定"
        case .evidence: return "规则匹配"
        case .fallback: return "保守回退"
        }
    }
}

import SwiftUI
import PhotoCore

struct CreativeEffectsPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("质感滤镜", systemImage: "sparkles").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("归零") { model.adjustments.creativeEffects = nil }.font(.system(size: 10))
                    .disabled(model.adjustments.creativeEffects?.isNeutral ?? true)
            }.padding(.bottom, 8)
            AdjustmentSlider(title: "高光辉光", value: binding(\.bloom), range: 0...1, percent: true)
            AdjustmentSlider(title: "柔和暗角", value: binding(\.vignette), range: 0...1, percent: true)
            AdjustmentSlider(title: "胶片颗粒", value: binding(\.grain), range: 0...1, percent: true)
            Text("可与任意 LUT 叠加；默认关闭。颗粒和细节以原尺寸检查为准；辉光无法恢复已剪切的高光。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
        }.disabled(model.batchRunning)
    }

    private func binding(_ key: WritableKeyPath<CreativeEffectsSettings, Double>) -> Binding<Double> {
        Binding(get: { (model.adjustments.creativeEffects ?? .init())[keyPath: key] }, set: { value in
            var effects = model.adjustments.creativeEffects ?? .init()
            effects[keyPath: key] = value
            model.adjustments.creativeEffects = effects
        })
    }
}

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
            }.padding(.bottom, 4)

            // Quick Preset Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    quickPill("理光街拍") {
                        model.adjustments.creativeEffects = CreativeEffectsSettings(
                            bloom: 0, vignette: 0.32, grain: 0.28, halation: 0, mist: 0, fade: 0.16, bleachBypass: 0
                        )
                    }
                    quickPill("银盐留银") {
                        model.adjustments.creativeEffects = CreativeEffectsSettings(
                            bloom: 0, vignette: 0.25, grain: 0.32, halation: 0, mist: 0, fade: 0, bleachBypass: 0.40
                        )
                    }
                    quickPill("经典胶片") {
                        model.adjustments.creativeEffects = CreativeEffectsSettings(
                            bloom: 0, vignette: 0.25, grain: 0.32, halation: 0.35, mist: 0, fade: 0.12, bleachBypass: 0
                        )
                    }
                    quickPill("黑柔电影") {
                        model.adjustments.creativeEffects = CreativeEffectsSettings(
                            bloom: 0.20, vignette: 0, grain: 0.18, halation: 0.15, mist: 0.32, fade: 0, bleachBypass: 0
                        )
                    }
                    quickPill("日系哑光") {
                        model.adjustments.creativeEffects = CreativeEffectsSettings(
                            bloom: 0.18, vignette: 0, grain: 0, halation: 0, mist: 0.28, fade: 0.22, bleachBypass: 0
                        )
                    }
                    quickPill("复古暗角") {
                        model.adjustments.creativeEffects = CreativeEffectsSettings(
                            bloom: 0, vignette: 0.45, grain: 0.25, halation: 0, mist: 0, fade: 0.10, bleachBypass: 0
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .padding(.bottom, 4)

            AdjustmentSlider(title: "高光辉光", value: binding(\.bloom), range: 0...1, percent: true)
            AdjustmentSlider(title: "胶片红晕", value: binding(\.halation), range: 0...1, percent: true)
            AdjustmentSlider(title: "黑柔薄雾", value: binding(\.mist), range: 0...1, percent: true)
            AdjustmentSlider(title: "胶片褪色", value: binding(\.fade), range: 0...1, percent: true)
            AdjustmentSlider(title: "银盐留银", value: binding(\.bleachBypass), range: 0...1, percent: true)
            AdjustmentSlider(title: "柔和暗角", value: binding(\.vignette), range: 0...1, percent: true)
            AdjustmentSlider(title: "胶片颗粒", value: binding(\.grain), range: 0...1, percent: true)

            Text("可与任意色彩风格叠加；默认关闭。红晕模拟胶片背层光渗，薄雾提供黑柔柔焦漫射，褪色微抬暗部哑光，留银提升反差质感。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
        }.disabled(model.batchRunning)
    }

    private func quickPill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 6).padding(.vertical, 2.5)
                .background(AtelierPalette.raised)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func binding(_ key: WritableKeyPath<CreativeEffectsSettings, Double>) -> Binding<Double> {
        Binding(get: { (model.adjustments.creativeEffects ?? .init())[keyPath: key] }, set: { value in
            var effects = model.adjustments.creativeEffects ?? .init()
            effects[keyPath: key] = value
            model.adjustments.creativeEffects = effects
        })
    }
}

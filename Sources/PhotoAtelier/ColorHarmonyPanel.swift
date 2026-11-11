import SwiftUI
import PhotoCore

struct ColorHarmonyPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("整体与局部色彩协调", systemImage: "circle.lefthalf.filled")
                .font(.system(size: 11, weight: .medium))
            Toggle("启用叠加后的色彩保护", isOn: enabledBinding)
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
            if model.adjustments.colorHarmony?.enabled == true {
                VStack(spacing: 3) {
                    AdjustmentSlider(title: "防止过度染色", value: binding(\.amount), range: 0...1, percent: true)
                    AdjustmentSlider(title: "细节颜色保护", value: binding(\.detailProtection), range: 0...1, percent: true)
                    AdjustmentSlider(title: "高彩度区域保护", value: binding(\.saturatedProtection), range: 0...1, percent: true)
                }
                Text("比较全图风格与所有局部调整叠加后的颜色。保留亮度变化与已有冷暖，限制新增的强色度和突兀色相；降低强度可保留更多刻意风格。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
            } else {
                Text("当前使用旧版或已关闭保护；开启后会改变现有调色结果，可随时关闭比较。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
            }
            if let report = model.previewReport.colorQuality {
                DisclosureGroup("当前照片的实测变化") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(report.scene.summary)
                        Text(report.summary)
                        if let space = report.outputColorSpace {
                            Text(String(format: "%@ 域外采样 %.1f%% → %.1f%%", space.title,
                                        report.outOfGamutBefore * 100, report.outOfGamutAfter * 100))
                        }
                        Text("箭头表示保护与输出映射前后，参照是全局校正后的照片。变化大不等于难看；请关闭蒙版覆盖并对比原片。")
                            .foregroundColor(AtelierPalette.muted)
                    }.font(.system(size: 9)).lineSpacing(4).padding(.top, 9)
                }.font(.system(size: 10))
                .opacity(model.previewBusy ? 0.45 : 1)
            }
            HStack {
                Button("采用温和保护") {
                    var settings = model.adjustments.colorHarmony ?? ColorHarmonySettings()
                    settings.enabled = true; settings.amount = 0.75
                    settings.detailProtection = 0.8; settings.saturatedProtection = 0.8
                    model.adjustments.colorHarmony = settings
                    model.status = "已提高整体与细节保护；曝光和局部选区保持当前设置。"
                }
                Spacer()
                Button("滤镜减弱 20%") {
                    model.adjustments.lutIntensity *= 0.8
                }.disabled(model.selectedLUT == "none")
            }.font(.system(size: 9))
            if let compatibility = model.previewReport.lutCompatibility, model.selectedLUT != "none" {
                DisclosureGroup("LUT 兼容与表格检查") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(compatibility.summary)
                        ForEach(Array(compatibility.warnings.enumerated()), id: \.offset) { _, text in Text(text) }
                        Text(".cube 不声明原色、传递函数或拍摄 Log。检查通过也不能证明空间选择正确；请依作者用途说明。")
                            .foregroundColor(AtelierPalette.muted)
                    }.font(.system(size: 9)).lineSpacing(4).padding(.top, 9)
                }.font(.system(size: 10))
            }
            Text(model.adjustments.colorHarmony != nil
                 ? "预览与导出使用 \(model.exportSettings.colorSpace.title)，输出时按此色域收敛颜色。关闭防染色仍保留输出映射；P3 效果取决于屏幕。"
                 : "预览按导出的 \(model.exportSettings.colorSpace.title) 显示；旧配方保留原输出方式，启用保护后采用新色域映射。P3 效果取决于屏幕。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.adjustments.colorHarmony?.enabled == true }, set: { enabled in
            var value = model.adjustments.colorHarmony ?? ColorHarmonySettings()
            value.enabled = enabled; model.adjustments.colorHarmony = value
        })
    }

    private func binding(_ keyPath: WritableKeyPath<ColorHarmonySettings, Double>) -> Binding<Double> {
        Binding(get: { (model.adjustments.colorHarmony ?? ColorHarmonySettings())[keyPath: keyPath] },
                set: { newValue in
                    var value = model.adjustments.colorHarmony ?? ColorHarmonySettings()
                    value[keyPath: keyPath] = newValue; model.adjustments.colorHarmony = value
                })
    }
}

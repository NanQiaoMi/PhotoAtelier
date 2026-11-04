import PhotoCore
import SwiftUI

/// Right-inspector “人像” tab for the v1 portrait refinement engine.
///
/// The copy is deliberately explicit: this is a landmark + colour-rule heuristic,
/// not a face segmentation model, and real-photo aesthetic quality is not
/// guaranteed. Controls stay disabled until the background detection found a
/// face with a usable skin matte, and a frame without a face degrades visibly
/// instead of silently rendering nothing.
struct PortraitRetouchPanel: View {
    @ObservedObject var model: AppModel

    private var settings: PortraitRefinementSettings {
        model.adjustments.portrait ?? PortraitRefinementSettings()
    }
    private var status: PortraitFaceStatus { model.portraitFaceStatus }
    private var canEdit: Bool {
        status.hasUsableSkinMask && !model.batchRunning && !status.isDetecting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("人像精修 v1", systemImage: "person.crop.circle.badge.checkmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .padding(.bottom, 10)
            Text("基于本机 Vision 人脸地标与颜色规则的启发式处理：不是完整人脸分割，不保证真实照片效果。本机最多处理前 \(AppModel.portraitMaximumFaces) 张人脸；若检测到人脸但皮肤蒙版覆盖不足，人像整段跳过且不改像素。合成测试只验证区域约束与有界变化，未做真实照片审美验收。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 13)
            statusCard
            HStack(spacing: 8) {
                Button("轻度精修起点") { model.applyLightPortraitStart() }
                    .font(.system(size: 10))
                    .buttonStyle(.bordered)
                    .disabled(!canEdit)
                Button("归零") { model.resetPortraitSettings() }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundColor(model.adjustments.portrait == nil ? AtelierPalette.muted : AtelierPalette.accent)
                    .disabled(model.batchRunning || model.adjustments.portrait == nil)
                Spacer(minLength: 0)
            }.padding(.top, 12)
                .help("轻度起点只给出保守数值；是否适合本张照片需要你自己判断。")

            VStack(alignment: .leading, spacing: 0) {
                portraitSlider("祛瑕疵", \.blemishStrength)
                Toggle("保留痣 / 斑", isOn: keepSpotsBinding)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 11)).padding(.bottom, 13)
                    .help("开启后保留明显暗于周围皮肤的痣/斑，只修小瑕疵。")
                separator
                Group {
                    portraitSlider("光影平整", \.dodgeBurn)
                    portraitSlider("立体感", \.structure)
                    portraitSlider("纹理", \.texture)
                    portraitSlider("光泽", \.gloss)
                }
                separator
                Group {
                    portraitSlider("牙齿美白", \.teethWhiten)
                    portraitSlider("眼白提亮", \.eyeBrighten)
                }
                separator
                Group {
                    portraitSlider("面部肤色统一", \.skinToneUnify)
                    Picker("肤色参考", selection: toneReferenceBinding) {
                        ForEach(PortraitToneReference.allCases, id: \.self) { reference in
                            Text(reference.title).tag(reference)
                        }
                    }.font(.system(size: 10))
                        .disabled(settings.skinToneUnify == 0)
                        .help("自动/中位取中位肤色；最亮取最亮人脸作参考。")
                }
            }
            .padding(.top, 16)
            .disabled(!canEdit)
            .opacity(canEdit ? 1 : 0.45)

            separator
            Text("限制：眼镜、浓妆、遮挡、侧脸、极端白平衡、灰低彩度虹膜、闭嘴无牙齿会降低或取消对应步骤；未检测到人脸、或皮肤蒙版覆盖不足（低于 \(String(format: "%.2f", AppModel.portraitMinimumSkinCoverage * 100))%% 画面）时整段跳过且不改像素，控件保持禁用。效果不保证，请逐张预览。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.requestPortraitDetection(force: false) }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                if status.isDetecting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: status.hasUsableSkinMask ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundColor(status.hasUsableSkinMask ? AtelierPalette.accent : .orange.opacity(0.9))
                }
                Text(status.summary)
                    .font(.system(size: 9))
                    .foregroundColor(status.hasUsableSkinMask ? .white.opacity(0.8) : AtelierPalette.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            if !status.isDetecting {
                Button("重新检测人脸") { model.requestPortraitDetection() }
                    .font(.system(size: 9)).buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.accent)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var keepSpotsBinding: Binding<Bool> {
        Binding(get: { settings.keepSpots },
                set: { newValue in
                    model.updatePortraitSettings { $0.keepSpots = newValue }
                })
    }

    private var toneReferenceBinding: Binding<PortraitToneReference> {
        Binding(get: { settings.skinToneReference },
                set: { reference in model.setPortraitToneReference(reference) })
    }

    private func portraitSlider(_ title: String,
                                _ keyPath: WritableKeyPath<PortraitRefinementSettings, Double>) -> some View {
        AdjustmentSlider(title: title,
                         value: Binding(get: { settings[keyPath: keyPath] },
                                        set: { newValue in
                                            model.updatePortraitSettings { $0[keyPath: keyPath] = newValue }
                                        }),
                         range: 0...1, percent: true)
    }

    private var separator: some View {
        Rectangle().fill(AtelierPalette.line).frame(height: 1).padding(.vertical, 14)
    }
}

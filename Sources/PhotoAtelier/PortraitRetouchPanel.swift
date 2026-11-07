import AppKit
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
                separator
                Group {
                    Text("秀发精修与发缝")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.vertical, 4)
                    portraitSlider("发缝填充", \.hairGapFilling)
                    portraitSlider("秀发光泽", \.hairGloss)
                    portraitSlider("发色深邃", \.hairDarkening)
                    portraitSlider("秀发柔顺", \.hairSmoothing)
                    portraitSlider("边缘去碎发", \.flyawayRemoval)
                }
            }
            .padding(.top, 16)
            .disabled(!canEdit)
            .opacity(canEdit ? 1 : 0.45)

            Group {
                separator
                makeupSection
            }

            Group {
                separator
                clothingSection
            }

            Group {
                separator
                liquifySection
                separator
                repairSection
            }

            Group {
                separator
                Text("限制：眼镜、浓妆、遮挡、侧脸、极端白平衡、灰低彩度虹膜、闭嘴无牙齿会降低或取消对应步骤；未检测到人脸、或皮肤蒙版覆盖不足（低于 \(String(format: "%.2f", AppModel.portraitMinimumSkinCoverage * 100))%% 画面）时整段跳过且不改像素，控件保持禁用。效果不保证，请逐张预览。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
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

    // MARK: Make-up (P1-C)

    private var makeupSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("妆容与面部微调 v2", systemImage: "paintpalette")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                Spacer(minLength: 0)
                if model.adjustments.makeup != nil {
                    Button("归零") { model.resetMakeup() }
                        .font(.system(size: 9)).buttonStyle(.plain)
                        .foregroundColor(AtelierPalette.accent)
                        .disabled(model.batchRunning)
                }
            }
            Text("唇/眉/腮红/眼影/眼线/睫毛/美瞳/眼神光/修容高光为启发式面部精修；增强妆容需要配方 v14；无脸时整段禁用。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5).padding(.bottom, 8)
            Text(model.makeupStatusNote)
                .font(.system(size: 9))
                .foregroundColor(model.canEditMakeup ? AtelierPalette.accent : AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 0) {
                Group {
                    makeupColorRow(title: "唇色", color: makeupColorBinding(\.lipColor))
                    AdjustmentSlider(title: "唇色强度", value: makeupSliderBinding(\.lipIntensity),
                                     range: 0...1, percent: true)
                    makeupColorRow(title: "腮红色", color: makeupColorBinding(\.cheekColor))
                    AdjustmentSlider(title: "腮红强度", value: makeupSliderBinding(\.cheekIntensity),
                                     range: 0...1, percent: true)
                    AdjustmentSlider(title: "腮红半径", value: makeupSliderBinding(\.cheekRadius),
                                     range: 0.2...1.0, percent: true)
                }
                Group {
                    makeupColorRow(title: "眉色", color: makeupColorBinding(\.browColor))
                    AdjustmentSlider(title: "眉色密度", value: makeupSliderBinding(\.browDensity),
                                     range: 0...1, percent: true)
                    makeupColorRow(title: "眼影色", color: makeupColorBinding(\.eyeshadowColor))
                    AdjustmentSlider(title: "眼影强度", value: makeupSliderBinding(\.eyeshadowIntensity),
                                     range: 0...1, percent: true)
                    makeupColorRow(title: "眼线色", color: makeupColorBinding(\.eyelinerColor))
                    AdjustmentSlider(title: "眼线描绘", value: makeupSliderBinding(\.eyelinerIntensity),
                                     range: 0...1, percent: true)
                    AdjustmentSlider(title: "睫毛浓密", value: makeupSliderBinding(\.eyelashIntensity),
                                     range: 0...1, percent: true)
                }
                Group {
                    makeupColorRow(title: "美瞳色", color: makeupColorBinding(\.irisColor))
                    AdjustmentSlider(title: "美瞳润色", value: makeupSliderBinding(\.irisIntensity),
                                     range: 0...1, percent: true)
                    AdjustmentSlider(title: "眼神光提亮", value: makeupSliderBinding(\.catchlightIntensity),
                                     range: 0...1, percent: true)
                    AdjustmentSlider(title: "面部高光（T区/苹果肌）", value: makeupSliderBinding(\.highlightIntensity),
                                     range: 0...1, percent: true)
                    AdjustmentSlider(title: "暗部修容（下颌/侧颊）", value: makeupSliderBinding(\.contourIntensity),
                                     range: 0...1, percent: true)
                }
            }
            .disabled(!model.canEditMakeup)
            .opacity(model.canEditMakeup ? 1 : 0.45)
        }
    }

    private func makeupColorRow(title: String, color: Binding<Color>) -> some View {
        HStack {
            Text(title).font(.system(size: 10)).foregroundColor(.white.opacity(0.7))
            Spacer(minLength: 0)
            ColorPicker("", selection: color).labelsHidden().controlSize(.mini)
        }.padding(.bottom, 8)
    }

    private func makeupColorBinding(
        _ keyPath: WritableKeyPath<MakeupSettings, SRGBColor>
    ) -> Binding<Color> {
        Binding(
            get: {
                let value = model.makeupSettings[keyPath: keyPath]
                return Color(red: value.red, green: value.green, blue: value.blue)
            },
            set: { color in
                guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
                model.updateMakeup {
                    $0[keyPath: keyPath] = SRGBColor(red: Double(converted.redComponent),
                                                     green: Double(converted.greenComponent),
                                                     blue: Double(converted.blueComponent))
                }
            })
    }

    private func makeupSliderBinding(
        _ keyPath: WritableKeyPath<MakeupSettings, Double>
    ) -> Binding<Double> {
        Binding(
            get: { model.makeupSettings[keyPath: keyPath] },
            set: { value in
                model.updateMakeup { $0[keyPath: keyPath] = value }
            })
    }

    // MARK: Liquify / face reshaping (P1)

    private var liquifySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("液化 / 美型 v1", systemImage: "face.smiling")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                Spacer(minLength: 0)
                if model.adjustments.liquify != nil {
                    Button("归零") { model.resetLiquify() }
                        .font(.system(size: 9)).buttonStyle(.plain)
                        .foregroundColor(AtelierPalette.accent)
                        .disabled(model.batchRunning)
                }
            }
            Text("启发式位移场，不是商业级美型。脸型/滑杆需要人脸地标并只作用于第一张脸；手动液化笔迹在无脸时也可用。合成测试只验证方向/有界/局部性/直线保护，未做真实照片审美验收。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5).padding(.bottom, 9)
            Text(model.liquifyStatusNote)
                .font(.system(size: 9))
                .foregroundColor(model.canEditLiquifyFaceShape ? AtelierPalette.accent : AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)

            Picker("脸型预设", selection: liquifyPresetBinding) {
                ForEach(FaceShapePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }.font(.system(size: 10))
                .disabled(!model.canEditLiquifyFaceShape)

            VStack(alignment: .leading, spacing: 0) {
                Group {
                    liquifySlider("瘦脸", \.slimFace)
                    liquifySlider("小脸", \.smallFace)
                    liquifySlider("大眼", \.enlargeEyes)
                    liquifySlider("鼻翼", \.narrowNose)
                    liquifySlider("嘴唇", \.lipWidth)
                    liquifySlider("下巴", \.chin)
                }
                Group {
                    liquifySlider("高颅顶", \.cranialTop)
                    liquifySlider("发际线", \.hairline)
                    liquifySlider("丰太阳穴", \.temple)
                    AdjustmentSlider(title: "整体强度", value: liquifyStrengthBinding,
                                     range: 0...1, percent: true)
                    Toggle("保护背景直线（脸框外衰减）", isOn: liquifyBackgroundBinding)
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: 10)).padding(.bottom, 13)
                        .help("把自动脸型位移在脸框 + feather 之外衰减到 0，背景直线不弯；手动笔迹仍按用户意图生效。")
                }
            }
            .padding(.top, 8)
            .disabled(!model.canEditLiquifyFaceShape)
            .opacity(model.canEditLiquifyFaceShape ? 1 : 0.45)

            HStack(spacing: 8) {
                Button(model.liquifyBrushActive ? "关闭液化画笔" : "手动液化画笔") {
                    model.toggleLiquifyBrush()
                }
                .font(.system(size: 10)).buttonStyle(.bordered)
                .disabled(!model.canDrawLiquify)
                if !model.liquifySettings.strokes.isEmpty {
                    Text("\(model.liquifySettings.strokes.count) 笔")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(AtelierPalette.muted)
                    Button("撤销一笔") { model.removeLastLiquifyStroke() }
                        .font(.system(size: 9)).buttonStyle(.plain)
                        .foregroundColor(AtelierPalette.accent)
                        .disabled(model.batchRunning)
                    Button("清空") { model.clearLiquifyStrokes() }
                        .font(.system(size: 9)).buttonStyle(.plain)
                        .foregroundColor(AtelierPalette.muted)
                        .disabled(model.batchRunning)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)

            if model.liquifyBrushActive {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("笔迹模式", selection: liquifyBrushModeBinding) {
                        ForEach(WarpStroke.Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }.pickerStyle(.segmented).font(.system(size: 10)).padding(.top, 10)
                    AdjustmentSlider(title: "画笔半径", value: liquifyRadiusBinding,
                                     range: 0.02...0.3, percent: true).padding(.top, 10)
                    AdjustmentSlider(title: "画笔强度", value: liquifyStrengthBrushBinding,
                                     range: 0...1, percent: true)
                    Text("在画布拖动绘制；松开后应用一次预览并生成一个撤销步骤（⌘Z 撤销整笔）。极端叠加可能局部折叠，请逐张预览。")
                        .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// P1-B manual repair / clone brush. Heuristic and non-generative: heal paints
    /// a low-frequency + nearby-donor patch, clone copies the offset source. It is
    /// a v12 recipe field; an empty stroke list keeps the pre-v12 pixel path.
    private var repairSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("修复 / 仿制画笔 v1", systemImage: "bandage")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
            Text("手动指定涂抹区域：修补（heal）用低频与邻近纹理做启发式填充，非生成式、不重建结构；仿制（clone）按偏移原样复制来源像素。画笔只改预览与导出像素，不改原图；无笔迹时配方保持 v1–v11 兼容。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            HStack(spacing: 8) {
                Button(model.repairBrushActive ? "关闭修复画笔" : "修复画笔") {
                    model.toggleRepairBrush()
                }
                .font(.system(size: 10)).buttonStyle(.bordered)
                .disabled(!model.canDrawRepairBrush && !model.repairBrushActive)
                if model.repairBrushIsActive {
                    Text("\(model.repairBrushSettings.strokes.count) 笔")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(AtelierPalette.muted)
                    Button("撤销一笔") { model.removeLastRepairStroke() }
                        .font(.system(size: 9)).buttonStyle(.plain)
                        .foregroundColor(AtelierPalette.accent)
                        .disabled(model.batchRunning)
                    Button("清空") { model.clearRepairStrokes() }
                        .font(.system(size: 9)).buttonStyle(.plain)
                        .foregroundColor(AtelierPalette.muted)
                        .disabled(model.batchRunning)
                }
                Spacer(minLength: 0)
            }.padding(.top, 10)
            Text(model.repairStatusNote)
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            if model.repairBrushActive {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("模式", selection: repairModeBinding) {
                        ForEach(RepairBrushMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }.pickerStyle(.segmented).font(.system(size: 10)).padding(.top, 10)
                    if model.repairBrushMode == .clone {
                        HStack(spacing: 6) {
                            Button(model.repairSamplingCloneSource ? "点击画布选择来源…" : "设置仿制来源") {
                                model.beginRepairSamplingCloneSource()
                            }
                            .font(.system(size: 9)).buttonStyle(.plain)
                            .foregroundColor(AtelierPalette.accent)
                            if let source = model.repairCloneSource {
                                Text("来源 \(String(format: "%.2f", source.x)), \(String(format: "%.2f", source.y))")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(AtelierPalette.muted)
                            }
                            Spacer(minLength: 0)
                        }.padding(.top, 8)
                    }
                    AdjustmentSlider(title: "画笔半径", value: repairRadiusBinding,
                                     range: AppModel.repairBrushRadiusRange, percent: true).padding(.top, 10)
                    AdjustmentSlider(title: "羽化", value: repairFeatherBinding,
                                     range: 0...1, percent: true)
                    AdjustmentSlider(title: "强度", value: repairStrengthBinding,
                                     range: 0...1, percent: true)
                    Text("每笔松开后应用一次预览并生成一个撤销步骤（⌘Z 撤销整笔）；Esc 退出画笔。无笔迹时预览与旧配方像素完全一致。")
                        .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }
            }
        }
    }

    private var repairModeBinding: Binding<RepairBrushMode> {
        Binding(get: { model.repairBrushMode }, set: { model.setRepairBrushMode($0) })
    }

    private var repairRadiusBinding: Binding<Double> {
        Binding(get: { model.repairBrushRadius },
                set: { model.repairBrushRadius = AppModel.clampedRepairBrushRadius($0) })
    }

    private var repairFeatherBinding: Binding<Double> {
        Binding(get: { model.repairBrushFeather },
                set: { model.repairBrushFeather = min(1, max(0, $0)) })
    }

    private var repairStrengthBinding: Binding<Double> {
        Binding(get: { model.repairBrushStrength },
                set: { model.repairBrushStrength = min(1, max(0, $0)) })
    }

    private var liquifyPresetBinding: Binding<FaceShapePreset> {
        Binding(get: { model.liquifySettings.preset },
                set: { model.applyLiquifyPreset($0) })
    }

    private var liquifyStrengthBinding: Binding<Double> {
        Binding(get: { model.liquifySettings.strength },
                set: { newValue in model.updateLiquifySettings { $0.strength = newValue } })
    }

    private var liquifyBackgroundBinding: Binding<Bool> {
        Binding(get: { model.liquifySettings.backgroundProtection },
                set: { newValue in
                    model.updateLiquifySettings { $0.backgroundProtection = newValue }
                })
    }

    private var liquifyBrushModeBinding: Binding<WarpStroke.Mode> {
        Binding(get: { model.liquifyBrushMode },
                set: { model.liquifyBrushMode = $0 })
    }

    private var liquifyRadiusBinding: Binding<Double> {
        Binding(get: { model.liquifyBrushRadius },
                set: { model.liquifyBrushRadius = min(0.3, max(0.02, $0)) })
    }

    private var liquifyStrengthBrushBinding: Binding<Double> {
        Binding(get: { model.liquifyBrushStrength },
                set: { model.liquifyBrushStrength = min(1, max(0, $0)) })
    }

    /// -1...1 slider showing the effective value (preset + explicit offset); the
    /// explicit offset is stored so the preset contribution stays visible.
    private func liquifySlider(_ title: String,
                               _ keyPath: WritableKeyPath<FaceReshapeParameters, Double>) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.liquifySettings.effectiveParameters[keyPath: keyPath] },
                set: { newValue in
                    model.setLiquifyParameter(newValue, keyPath)
                }),
            range: -1...1)
    }

    // MARK: - Smart clothing wrinkle smoothing (P2-F)

    private var clothingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("智能衣物平整与祛皱", systemImage: "tshirt")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.clothingIsActive {
                    Button("重置") {
                        model.resetClothing()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }
            }

            Text("基于 Vision 人物抠图智能分离面料区域，平滑衣物折痕、压痕与穿着褶皱，保留微观编织纹理（cotton/wool/knit）与身体轮廓，严格保护面部、发型与裸露皮肤。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用衣物平整与祛皱", isOn: Binding(
                get: { model.clothingSettings.enabled },
                set: { model.setClothingEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.clothingSettings.enabled {
                VStack(spacing: 8) {
                    clothingSlider("衣物平整", \.wrinkleSmoothing,
                                   help: "抚平面料大面积折痕与散乱褶皱，使衣物平整贴合。")
                    clothingSlider("褶皱抑制", \.creaseRemoval,
                                   help: "抑制尖锐折痕、压褶线与深色折印。")
                    clothingSlider("织物肌理保护", \.texturePreservation,
                                   help: "保留衣物本身的微观编织纹理（棉麻质感、针织线圈），避免塑料假面感。")
                }
                .padding(.top, 10)
            }
        }
    }

    private func clothingSlider(_ title: String,
                                _ keyPath: WritableKeyPath<ClothingRefinementSettings, Double>,
                                help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.clothingSettings[keyPath: keyPath] },
                set: { val in
                    model.updateClothing { $0[keyPath: keyPath] = val }
                }
            ),
            range: 0...1
        )
        .help(help)
    }

    private var separator: some View {
        Rectangle().fill(AtelierPalette.line).frame(height: 1).padding(.vertical, 14)
    }
}

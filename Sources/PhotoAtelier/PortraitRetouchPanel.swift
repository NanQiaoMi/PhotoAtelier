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
        model.effectivePortrait(forPersonIndex: model.selectedPersonIndex)
    }
    private var status: PortraitFaceStatus { model.portraitFaceStatus }
    private var canEdit: Bool {
        status.hasUsableSkinMask && !model.batchRunning && !status.isDetecting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                Label("人像精修 v1", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.bottom, 10)
                Text("基于本机 Vision 人脸地标与颜色规则的启发式处理：不是完整人脸分割，不保证真实照片效果。本机最多处理前 \(AppModel.portraitMaximumFaces) 张人脸；若检测到人脸但皮肤蒙版覆盖不足，人像整段跳过且不改像素。合成测试只验证区域约束与有界变化，未做真实照片审美验收。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 13)
                statusCard

                if status.detectedFaceCount > 1 || (model.adjustments.multiPerson?.enabled ?? false) {
                    separator
                    multiPersonSection
                }

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
            }

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
                separator
                facialZonalSection
                separator
                eyeTeethSection
            }

            Group {
                separator
                bodySkinSection
                separator
                clothingSection
                separator
                bodyReshapeSection
            }

            Group {
                separator
                petEnhancementSection
                separator
                skyEnhancementSection
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

    // MARK: - Smart body reshaping & posture refinement (P2-O)

    private var bodyReshapeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("智能全身身形与姿态微调", systemImage: "figure.walk")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.bodyReshapeIsActive {
                    Button("重置") {
                        model.resetBodyReshape()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }
            }

            Text("基于 Vision 3D 骨骼关节与中轴线拟合，解剖学平滑塑形：天鹅颈、直角肩、躯干内收纤细、细腰收腹、腿部拉长增高与瘦手臂，严格保护背景直线不发生弯曲变形。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用全身身形与姿态微调", isOn: Binding(
                get: { model.bodyReshapeSettings.enabled },
                set: { model.setBodyReshapeEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.bodyReshapeSettings.enabled {
                VStack(spacing: 8) {
                    bodyReshapeSlider("天鹅颈 (颈部拉伸收细)", \.swanNeck,
                                      help: "拉长颈部线条并收细颈部横向宽度。")
                    bodyReshapeSlider("直角肩 (斜方肌收敛平整)", \.trapeziusContraction,
                                      help: "下压收敛斜方肌鼓包，平整肩峰轮廓。")
                    bodyReshapeSlider("整体瘦身 (躯干双侧收敛)", \.bodySlimming,
                                      help: "沿脊柱中轴线平滑内收躯干两侧轮廓。")
                    bodyReshapeSlider("细腰收腹 (沙漏曲线雕刻)", \.waistCinching,
                                      help: "腰部黄金分割点向心收拢，塑造优雅沙漏身材。")
                    bodyReshapeSlider("长腿增高 (下肢比例拉长)", \.legLengthening,
                                      help: "从骨盆髋部以下渐进向下延伸腿部比例。")
                    bodyReshapeSlider("瘦手臂 (大臂宽度收细)", \.armSlimming,
                                      help: "向肱骨中轴收拢大臂外侧宽度，消除蝴蝶袖。")
                    bodyReshapeSlider("背景保护 (防止背景线条扭曲)", \.backgroundProtection,
                                      range: 0...1,
                                      help: "限制形变场向背景边缘扩散，保护门窗地平线平直。")
                }
                .padding(.top, 10)
            }
        }
    }

    private func bodyReshapeSlider(_ title: String,
                                   _ keyPath: WritableKeyPath<BodyReshapeSettings, Double>,
                                   range: ClosedRange<Double> = 0...1,
                                   help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.bodyReshapeSettings[keyPath: keyPath] },
                set: { val in
                    model.updateBodyReshape { $0[keyPath: keyPath] = val }
                }
            ),
            range: range
        )
        .help(help)
    }

    // MARK: - Smart facial zonal wrinkle smoothing & anti-shine (P2-H)

    private var facialZonalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("面部五区精修与去油光", systemImage: "face.dashed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.facialZonalIsActive {
                    Button("重置") {
                        model.resetFacialZonal()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }
            }

            Text("基于面部几何精细分区：淡化下眼睑黑眼圈暗沉、抚平眼袋与泪沟凹陷阴影、消除鼻唇法令纹深部沟壑、抚平抬头纹与眉间川字纹，抑制 T 区面部油光并保留微观毛孔肌理，重塑下颌轮廓线。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用面部五区精修", isOn: Binding(
                get: { model.facialZonalSettings.enabled },
                set: { model.setFacialZonalEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.facialZonalSettings.enabled {
                VStack(spacing: 8) {
                    facialZonalSlider("祛黑眼圈", \.darkCircles,
                                      help: "淡化下眼睑由于微循环或色素沉积导致的蓝紫暗沉。")
                    facialZonalSlider("眼袋泪沟", \.eyeBags,
                                      help: "抚平下眼眶下缘弧形凹陷阴影槽与浮肿泪沟。")
                    facialZonalSlider("祛法令纹", \.nasolabialFolds,
                                      help: "抚平从鼻翼两侧延伸至嘴角旁的表情阴影沟壑。")
                    facialZonalSlider("抬头川字", \.foreheadWrinkles,
                                      help: "抚平额头横向纹理与两眉之间垂直川字皱纹阴影。")
                    facialZonalSlider("面部去油光", \.antiShine,
                                      help: "压制额头中央与鼻梁T区泛白反光，收敛为高级哑光质感。")
                    facialZonalSlider("下颌修容", \.jawlineSculpting,
                                      help: "淡化下巴底部重叠双下巴阴影，重塑清晰下颌轮廓线。")
                    facialZonalSlider("肌理保护", \.texturePreservation,
                                      help: "保留皮肤原生细腻微观毛孔，防止塑料感失真。")
                }
                .padding(.top, 10)
            }
        }
    }

    private func facialZonalSlider(_ title: String,
                                   _ keyPath: WritableKeyPath<FacialZonalRefinementSettings, Double>,
                                   help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.facialZonalSettings[keyPath: keyPath] },
                set: { val in
                    model.updateFacialZonal { $0[keyPath: keyPath] = val }
                }
            ),
            range: 0...1
        )
        .help(help)
    }

    // MARK: - Smart eye catchlight, anti-glare & aesthetic teeth refinement (P2-N)

    private var eyeTeethSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("明眸眼神光与牙齿美学", systemImage: "sparkles.rectangle.stack")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.eyeTeethIsActive {
                    Button("重置") {
                        model.resetEyeTeeth()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }
            }

            Text("眼神与笑容核心微雕：智能消除镜片眩光泛白反光、消除眼白红血丝与黄浊、提升虹膜层次与深邃度、6款摄影级眼神光模板注入、牙齿黄茶渍与唇膏溢色净化、恢复健康珐琅质微高光并保护粉红牙龈。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用眼神光与牙齿美学精修", isOn: Binding(
                get: { model.currentEyeTeethSettings.enabled },
                set: { model.setEyeTeethEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.currentEyeTeethSettings.enabled {
                VStack(spacing: 8) {
                    eyeTeethSlider("眼镜去反光", \.eyeglassGlareReduction,
                                   range: 0...1,
                                   help: "抑制眼镜镜片表面被闪光灯或反光板激发的白雾光斑，透视还原瞳孔与眼皮细节。")
                    eyeTeethSlider("眼白去红血丝", \.scleraBloodshotRemoval,
                                   range: 0...1,
                                   help: "净化巩膜红血丝与疲劳泛黄杂色，恢复清澈纯净瓷白感。")
                    eyeTeethSlider("虹膜明眸深邃", \.irisClarity,
                                   range: 0...1,
                                   help: "增强瞳孔周围虹膜放射状纹理与暗边环（Limbal Ring）反差，打造深邃神采。")

                    // Catchlight pattern picker
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("眼神光模板")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.8))
                            Spacer()
                            Picker("", selection: Binding(
                                get: { model.currentEyeTeethSettings.catchlightPattern },
                                set: { pat in
                                    model.updateEyeTeeth { $0.catchlightPattern = pat }
                                }
                            )) {
                                ForEach(EyeCatchlightPattern.allCases) { pat in
                                    Text(pat.displayName).tag(pat)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 110)
                        }

                        if model.currentEyeTeethSettings.catchlightPattern != .off {
                            eyeTeethSlider("眼神光强度", \.catchlightStrength,
                                           range: 0...1,
                                           help: "控制眼神光光斑的亮度与高光可见度。")
                            eyeTeethSlider("眼神光大小", \.catchlightScale,
                                           range: 0.5...2.0,
                                           help: "调节眼神光光斑相对瞳孔的尺寸比例（0.5x ~ 2.0x）。")
                        }
                    }
                    .padding(.vertical, 2)

                    Divider().background(Color.white.opacity(0.1)).padding(.vertical, 2)

                    eyeTeethSlider("牙渍唇膏净化", \.teethStainRemoval,
                                   range: 0...1,
                                   help: "净化牙齿表面黄茶渍、烟渍斑点与唇膏边缘溢色印记。")
                    eyeTeethSlider("珐琅质自然微光", \.enamelSheen,
                                   range: 0...1,
                                   help: "在牙齿迎光弧面重注入通透半高光，防止死板假白。")
                    eyeTeethSlider("牙龈粉润保护", \.gingivaProtection,
                                   range: 0...1,
                                   help: "严格锁定牙龈粉红色界限，防止美白时牙龈漂白失真。")
                }
                .padding(.top, 10)
            }
        }
    }

    private func eyeTeethSlider(_ title: String,
                                _ keyPath: WritableKeyPath<EyeTeethRefinementSettings, Double>,
                                range: ClosedRange<Double> = 0...1,
                                help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.currentEyeTeethSettings[keyPath: keyPath] },
                set: { val in
                    model.updateEyeTeeth { $0[keyPath: keyPath] = val }
                }
            ),
            range: range
        )
        .help(help)
    }

    // MARK: - Smart body and hand skin refinement (P2-G)

    private var bodySkinSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("身体与手部美肤", systemImage: "hand.raised")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.bodySkinIsActive {
                    Button("重置") {
                        model.resetBodySkin()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }
            }

            Text("智能识别人像颈部、肩臂与手部裸露皮肤，平整颈部横向折痕与颈纹阴影，抑制手背与手臂凸起青蓝静脉，中性灰平滑身体粗糙，并统一身体与面部的色温明度，保留微观毛孔肌理。面部五官受严格隔离保护。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用身体与手部美肤", isOn: Binding(
                get: { model.bodySkinSettings.enabled },
                set: { model.setBodySkinEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.bodySkinSettings.enabled {
                VStack(spacing: 8) {
                    bodySkinSlider("颈纹淡化", \.neckSmoothing,
                                   help: "抚平下颌与锁骨之间的横向颈纹阴影与折痕。")
                    bodySkinSlider("青筋淡化", \.veinReduction,
                                   help: "抑制手背与手臂的青蓝色凸起静脉与关节暗沉。")
                    bodySkinSlider("身体平整", \.bodySmoothing,
                                   help: "身体四肢中性灰磨皮，抚平皮肤粗糙与杂色。")
                    bodySkinSlider("肤色统一", \.bodyToneHarmonization,
                                   help: "将身体与手部色温与明度向面部肤色锚点统一。")
                    bodySkinSlider("肌理保护", \.texturePreservation,
                                   help: "保留真皮毛孔微观肌理，杜绝塑料假人感。")
                }
                .padding(.top, 10)
            }
        }
    }

    private func bodySkinSlider(_ title: String,
                                _ keyPath: WritableKeyPath<BodySkinRefinementSettings, Double>,
                                help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.bodySkinSettings[keyPath: keyPath] },
                set: { val in
                    model.updateBodySkin { $0[keyPath: keyPath] = val }
                }
            ),
            range: 0...1
        )
        .help(help)
    }

    // MARK: - Smart pet enhancement (P2-I)

    private var petEnhancementSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("智能宠物写真美化", systemImage: "pawprint.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.petEnhancementIsActive {
                    Button("重置") {
                        model.resetPetEnhancement()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }
            }

            Text("专为猫咪与狗狗写真打造：智能定位宠物身躯毛发、眼眶与鼻吻，增强毛发蓬松微观毛流，提亮双眸并聚集晶亮眼神光，加深鼻吻立体湿润感，去除环境光散射毛发灰蒙雾感，并中和浅色白毛发黄。100% 本地原生，无需外置模型。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用智能宠物写真美化", isOn: Binding(
                get: { model.petEnhancementSettings.enabled },
                set: { model.setPetEnhancementEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.petEnhancementSettings.enabled {
                VStack(spacing: 8) {
                    petEnhancementSlider("毛发蓬松", \.furFluffiness,
                                         help: "提取毛发高频微观毛流对比度，令皮毛根根分明、丰盈蓬松。")
                    petEnhancementSlider("明眸提亮", \.eyeBrightening,
                                         help: "提亮宠物眼眶晶状体暗部，强化晶莹眼神光高光。")
                    petEnhancementSlider("鼻吻润泽", \.muzzleMoisture,
                                         help: "加深鼻头深邃暗部并提亮水光高光，呈现湿润立体质感。")
                    petEnhancementSlider("毛发去灰", \.coatDehaze,
                                         help: "消除环境散射灰雾，还原毛发深黑、金黄、银灰的原生纯度。")
                    petEnhancementSlider("白毛去黄", \.coatWhiten,
                                         help: "中和浅色或白色宠物毛发上的氧化发黄，还原纯净白亮。")
                    petEnhancementSlider("肌理保护", \.texturePreservation,
                                         help: "重注入微观毛发真实纹理，防止平滑后出现橡皮擦糊感。")
                }
                .padding(.top, 10)
            }
        }
    }

    private func petEnhancementSlider(_ title: String,
                                      _ keyPath: WritableKeyPath<PetEnhancementSettings, Double>,
                                      help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.petEnhancementSettings[keyPath: keyPath] },
                set: { val in
                    model.updatePetEnhancement { $0[keyPath: keyPath] = val }
                }
            ),
            range: 0...1
        )
        .help(help)
    }

    // MARK: - Smart sky detection, atmospheric relighting & replacement (P2-J)

    private var skyEnhancementSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("智能天空氛围与置换", systemImage: "cloud.sun.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.skyEnhancementIsActive {
                    Button("重置") {
                        model.resetSkyEnhancement()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }
            }

            Text("外景婚纱与旅拍必备：智能识别天际线与天空区域，自适应排除人物主体。恢复过曝死白天空的湛蓝纯净层次，增强积云反差，渲染日落晚霞夕阳金红光晕，支持 5 款程序化天空置换，并自动向前景渗透环境漫射光消除贴纸感。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用智能天空氛围与置换", isOn: Binding(
                get: { model.skyEnhancementSettings.enabled },
                set: { model.setSkyEnhancementEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.skyEnhancementSettings.enabled {
                VStack(spacing: 8) {
                    Picker("天空预设", selection: Binding(
                        get: { model.skyEnhancementSettings.skyPreset },
                        set: { val in
                            model.updateSkyEnhancement { $0.skyPreset = val }
                        }
                    )) {
                        ForEach(SkyPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 10))

                    if model.skyEnhancementSettings.skyPreset != .none {
                        skyEnhancementSlider("置换不透明度", \.replacementOpacity,
                                             help: "程序化天空与原图的混合比例。")
                    }

                    skyEnhancementSlider("天空湛蓝", \.skyVibrance,
                                         help: "自适应提纯天空青蓝色阶，恢复泛白天穹的深邃蓝调。")
                    skyEnhancementSlider("云层反差", \.cloudContrast,
                                         help: "提升积云与层云的立体明暗反差，增强云层层次。")
                    skyEnhancementSlider("晚霞氛围", \.sunsetWarmth,
                                         help: "沿地平线注入夕阳金橙与晚霞色彩，营造黄昏意境。")
                    skyEnhancementSlider("前景光照匹配", \.foregroundRelight,
                                         help: "将天空光色自动向人物与前景渗透环境漫射，消除割裂感。")
                    skyEnhancementSlider("边缘羽化", \.edgeFeather,
                                         help: "地平线与发丝边缘自适应平滑羽化，防止硬切黑白边。")
                }
                .padding(.top, 10)
            }
        }
    }

    private func skyEnhancementSlider(_ title: String,
                                      _ keyPath: WritableKeyPath<SkyEnhancementSettings, Double>,
                                      help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.skyEnhancementSettings[keyPath: keyPath] },
                set: { val in
                    model.updateSkyEnhancement { $0[keyPath: keyPath] = val }
                }
            ),
            range: 0...1
        )
        .help(help)
    }

    private var separator: some View {
        Rectangle().fill(AtelierPalette.line).frame(height: 1).padding(.vertical, 14)
    }

    private var multiPersonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("多人分人属性感知与独立精修", systemImage: "person.2.crop.square.stack")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.adjustments.multiPerson?.enabled ?? false },
                    set: { enabled in
                        var mp = model.adjustments.multiPerson ?? MultiPersonSettings()
                        mp.enabled = enabled
                        model.adjustments.multiPerson = mp.isNeutral ? nil : mp
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            if model.adjustments.multiPerson?.enabled == true {
                Text("已识别 \(status.detectedFaceCount) 位人物。点选人员标签可针对单人独立精修（磨皮/除皱/妆容），未修改项沿用全局。")
                    .font(.system(size: 9))
                    .foregroundColor(AtelierPalette.muted)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button {
                            model.selectedPersonIndex = nil
                        } label: {
                            Text("全部人员")
                                .font(.system(size: 10, weight: model.selectedPersonIndex == nil ? .semibold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(model.selectedPersonIndex == nil ? AtelierPalette.accent.opacity(0.3) : Color(NSColor.controlBackgroundColor))
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(model.selectedPersonIndex == nil ? AtelierPalette.accent : Color.clear, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)

                        ForEach(0..<max(status.detectedFaceCount, model.adjustments.multiPerson?.individualProfiles.compactMap(\.faceIndex).max().map({ $0 + 1 }) ?? 0), id: \.self) { idx in
                            let role = model.assignedRole(forPersonIndex: idx)
                            Button {
                                model.selectedPersonIndex = idx
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: role.icon)
                                    Text("人物 \(idx + 1) · \(role.title)")
                                }
                                .font(.system(size: 10, weight: model.selectedPersonIndex == idx ? .semibold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(model.selectedPersonIndex == idx ? AtelierPalette.accent.opacity(0.3) : Color(NSColor.controlBackgroundColor))
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(model.selectedPersonIndex == idx ? AtelierPalette.accent : Color.clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let idx = model.selectedPersonIndex {
                    let role = model.assignedRole(forPersonIndex: idx)
                    HStack(spacing: 8) {
                        Picker("指定角色", selection: Binding(
                            get: { role },
                            set: { newRole in
                                model.setPersonRole(newRole, forPersonIndex: idx)
                            }
                        )) {
                            ForEach(PersonDemographicRole.allCases) { r in
                                Text(r.title).tag(r)
                            }
                        }
                        .font(.system(size: 10))

                        Button("应用推荐预设") {
                            model.applyRolePresetToPerson(role, forPersonIndex: idx)
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button("重置单人") {
                            model.resetPersonProfile(forPersonIndex: idx)
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundColor(AtelierPalette.muted)
                    }
                    .padding(.vertical, 4)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("多人肤色统一")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.85))
                        Spacer()
                        Text("\(Int(((model.adjustments.multiPerson?.unifySkinTone ?? 0) * 100).rounded()))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(AtelierPalette.muted)
                    }
                    Slider(
                        value: Binding(
                            get: { model.adjustments.multiPerson?.unifySkinTone ?? 0 },
                            set: { val in
                                var mp = model.adjustments.multiPerson ?? MultiPersonSettings(enabled: true)
                                mp.enabled = true
                                mp.unifySkinTone = val
                                model.adjustments.multiPerson = mp
                            }
                        ),
                        in: 0...1
                    )
                    .controlSize(.mini)

                    Picker("统一基准", selection: Binding(
                        get: { model.adjustments.multiPerson?.toneReference ?? .auto },
                        set: { ref in
                            var mp = model.adjustments.multiPerson ?? MultiPersonSettings(enabled: true)
                            mp.enabled = true
                            mp.toneReference = ref
                            model.adjustments.multiPerson = mp
                        }
                    )) {
                        ForEach(PortraitToneReference.allCases, id: \.self) { r in
                            Text(r.title).tag(r)
                        }
                    }
                    .font(.system(size: 10))
                    .disabled((model.adjustments.multiPerson?.unifySkinTone ?? 0) == 0)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
    }
}

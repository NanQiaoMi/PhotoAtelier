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
                Label("人像精修 · 场景化工作台", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.bottom, 10)
                statusCard

                if status.detectedFaceCount > 1 || (model.adjustments.multiPerson?.enabled ?? false) {
                    separator
                    multiPersonSection
                }

                separator
                PortraitActiveHUD(model: model, selectedCategory: $model.portraitSelectedCategory)
                PortraitCategoryTabBar(selectedCategory: $model.portraitSelectedCategory, model: model)
                    .padding(.bottom, 12)
            }

            VStack(alignment: .leading, spacing: 0) {
                switch model.portraitSelectedCategory {
                case .quickStyles:
                    quickStylesCategoryView
                case .skin:
                    skinCategoryView
                case .bone:
                    boneCategoryView
                case .features:
                    featuresCategoryView
                case .makeup:
                    makeupCategoryView
                case .body:
                    bodyCategoryView
                }
            }
            .disabled(!canEdit && model.portraitSelectedCategory != .quickStyles)
            .opacity((canEdit || model.portraitSelectedCategory == .quickStyles) ? 1 : 0.45)

            separator
            Text("提示：点击卡片右上角 👁️ 眼睛图标可临时旁路此效果；长按 👁️ 可即时闪现对比关闭效果。")
                .font(.system(size: 8.5)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .onAppear { model.requestPortraitDetection(force: false) }
    }

    // MARK: - Category Views

    private var quickStylesCategoryView: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("人像效果总控倍率", systemImage: "slider.horizontal.2.square")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(Int((model.portraitMasterIntensity * 100).rounded()))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(AtelierPalette.accent)
                }
                Slider(value: Binding(
                    get: { model.portraitMasterIntensity },
                    set: { model.setPortraitMasterIntensity($0) }
                ), in: 0...1.5, step: 0.05)
                .controlSize(.small)
                HStack {
                    Text("0% (无效果)").font(.system(size: 8)).foregroundColor(AtelierPalette.muted)
                    Spacer()
                    Text("100% (标准)").font(.system(size: 8)).foregroundColor(AtelierPalette.muted)
                    Spacer()
                    Text("150% (强化)").font(.system(size: 8)).foregroundColor(AtelierPalette.muted)
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(AtelierPalette.accent.opacity(0.3), lineWidth: 1)
            )

            Text("大师级商业人像预设")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.85))
                .padding(.top, 4)

            ForEach(PortraitPreset.builtIns) { preset in
                presetRow(preset)
            }

            HStack(spacing: 8) {
                Button("轻度精修起点") { model.applyLightPortraitStart() }
                    .font(.system(size: 10))
                    .buttonStyle(.bordered)
                    .disabled(!canEdit)
                Button("全部人像复位") { model.resetAllPortraitAdjustments() }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.accent)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
        }
    }

    private func presetRow(_ preset: PortraitPreset) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: preset.icon)
                    .font(.system(size: 10))
                    .foregroundColor(AtelierPalette.accent)
                Text(preset.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                Text("· \(preset.subtitle)")
                    .font(.system(size: 9))
                    .foregroundColor(AtelierPalette.muted)
                Spacer()
                Button("应用") {
                    model.applyPortraitPreset(preset)
                }
                .font(.system(size: 9, weight: .medium))
                .buttonStyle(.borderedProminent)
                .tint(AtelierPalette.accent)
                .controlSize(.mini)
                .disabled(!canEdit)
            }
            Text(preset.description)
                .font(.system(size: 8.5))
                .foregroundColor(AtelierPalette.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 4) {
                ForEach(preset.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 7.5))
                        .foregroundColor(.white.opacity(0.65))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var skinCategoryView: some View {
        VStack(alignment: .leading, spacing: 0) {
            PortraitCard(module: .skinRetouch, model: model) {
                VStack(alignment: .leading, spacing: 0) {
                    portraitSlider("祛瑕疵", \.blemishStrength)
                    Toggle("保留痣 / 斑", isOn: keepSpotsBinding)
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: 11)).padding(.bottom, 10)
                    separator
                    portraitSlider("光影平整", \.dodgeBurn)
                    portraitSlider("立体感", \.structure)
                    portraitSlider("纹理", \.texture)
                    portraitSlider("光泽", \.gloss)
                }
            }

            PortraitCard(module: .facialZonal, model: model) {
                facialZonalSection
            }

            PortraitCard(module: .skinToneUnify, model: model) {
                VStack(alignment: .leading, spacing: 0) {
                    portraitSlider("面部肤色统一", \.skinToneUnify)
                    Picker("肤色参考", selection: toneReferenceBinding) {
                        ForEach(PortraitToneReference.allCases, id: \.self) { reference in
                            Text(reference.title).tag(reference)
                        }
                    }
                    .font(.system(size: 10))
                    .disabled(settings.skinToneUnify == 0)
                }
            }

            PortraitCard(module: .bodySkin, model: model) {
                bodySkinSection
            }
        }
    }

    private var boneCategoryView: some View {
        VStack(alignment: .leading, spacing: 0) {
            PortraitCard(module: .facialBoneContour, model: model) {
                facialBoneContourSection
            }

            PortraitCard(module: .facialContour, model: model) {
                facialContourSection
            }

            PortraitCard(module: .jawChinReshape, model: model) {
                jawChinReshapeSection
            }
        }
    }

    private var featuresCategoryView: some View {
        VStack(alignment: .leading, spacing: 0) {
            PortraitCard(module: .noseReshape, model: model) {
                noseReshapeSection
            }

            PortraitCard(module: .eyebrowReshape, model: model) {
                eyebrowReshapeSection
            }

            PortraitCard(module: .eyeShape, model: model) {
                eyeShapeSection
            }

            PortraitCard(module: .eyelidAegyoSal, model: model) {
                eyelidAegyoSalSection
            }

            PortraitCard(module: .eyeTeeth, model: model) {
                eyeTeethSection
            }

            PortraitCard(module: .expression, model: model) {
                expressionSection
            }
        }
    }

    private var makeupCategoryView: some View {
        VStack(alignment: .leading, spacing: 0) {
            PortraitCard(module: .makeup, model: model) {
                makeupSection
            }

            PortraitCard(module: .hairRefine, model: model) {
                VStack(alignment: .leading, spacing: 0) {
                    portraitSlider("发缝填充", \.hairGapFilling)
                    portraitSlider("秀发光泽", \.hairGloss)
                    portraitSlider("发色深邃", \.hairDarkening)
                    portraitSlider("秀发柔顺", \.hairSmoothing)
                    portraitSlider("边缘去碎发", \.flyawayRemoval)
                }
            }

            PortraitCard(module: .hairColor, model: model) {
                hairColorSection
            }

            PortraitCard(module: .facialHair, model: model) {
                facialHairSection
            }
        }
    }

    private var bodyCategoryView: some View {
        VStack(alignment: .leading, spacing: 0) {
            PortraitCard(module: .bodyReshape, model: model) {
                bodyReshapeSection
            }

            PortraitCard(module: .clothing, model: model) {
                clothingSection
            }

            PortraitCard(module: .bokehBlur, model: model) {
                bokehBlurSection
            }

            VStack(alignment: .leading, spacing: 0) {
                liquifySection
                separator
                repairSection
            }
        }
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
            HStack(spacing: 8) {
                if !status.isDetecting {
                    Button("重新检测人脸") { model.requestPortraitDetection() }
                        .font(.system(size: 9)).buttonStyle(.plain)
                        .foregroundColor(AtelierPalette.accent)
                }
                Spacer()
                if status.detectedFaceCount > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            model.showFaceLandmarksHUD.toggle()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: model.showFaceLandmarksHUD ? "viewfinder.circle.fill" : "viewfinder.circle")
                            Text("五官定位")
                        }
                        .font(.system(size: 9, weight: model.showFaceLandmarksHUD ? .semibold : .regular))
                        .foregroundColor(model.showFaceLandmarksHUD ? AtelierPalette.accent : AtelierPalette.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(model.showFaceLandmarksHUD ? AtelierPalette.accent.opacity(0.18) : AtelierPalette.panel)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("在画布上高亮显示 Vision 算法识别出的五官关键点与轮廓")

                    Button {
                        model.triggerFocusOnFace()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "face.dashed")
                            Text("面部特写 (1:1)")
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(AtelierPalette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AtelierPalette.accent.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("一键缩放居中至面部五官，便于精细对比微雕细节")
                }
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
            Text("自然原生妆容 · 针对唇色、眼影、腮红、修容与眼神光质感进行高定美化。")
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
            Text("智能液化微雕 · 保持五官骨骼解剖比例自然协调，支持手动推拉液化。")
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
            Text("智能修复画笔 · 针对面部斑点与画面杂质进行无痕修补或仿制印章。")
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

    // MARK: - Smart double eyelid sculpting, tape concealing & aegyo sal sculpting (P2-P)

    private var eyelidAegyoSalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("双眼皮雕刻与卧蚕立体塑形", systemImage: "eye.trianglebadge.exclamationmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.eyelidAegyoSalIsActive {
                    Button("重置") {
                        model.resetEyelidAegyoSal()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }
            }

            Text("眼部精细轮廓雕刻：支持开扇型/平行型/新月型/欧美型4款双眼皮折痕生成，平抚双眼皮贴硬阶梯边缘与消除强反光，卧蚕珠光饱满提亮与立体下缘修容微雕。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用双眼皮与卧蚕精雕", isOn: Binding(
                get: { model.eyelidAegyoSalSettings.enabled },
                set: { model.setEyelidAegyoSalEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.eyelidAegyoSalSettings.enabled {
                VStack(spacing: 8) {
                    // Eyelid style picker
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("双眼皮形态")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.8))
                            Spacer()
                            Picker("", selection: Binding(
                                get: { model.eyelidAegyoSalSettings.eyelidStyle },
                                set: { style in
                                    model.updateEyelidAegyoSal { $0.eyelidStyle = style }
                                }
                            )) {
                                ForEach(EyelidStyle.allCases) { style in
                                    Text(style.title).tag(style)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 110)
                        }

                        if model.eyelidAegyoSalSettings.eyelidStyle != .off {
                            eyelidSlider("折痕深邃度", \.eyelidStrength,
                                         range: 0...1,
                                         help: "控制双眼皮折痕阴影与上方微高光的对比度与清晰度。")
                            eyelidSlider("折痕相对高度", \.eyelidHeight,
                                         range: 0.5...2.0,
                                         help: "调节双眼皮折痕与上睑缘之间的相对垂直间距（0.5x ~ 2.0x）。")
                            eyelidSlider("折痕延展宽度", \.eyelidWidth,
                                         range: 0...1,
                                         help: "调节双眼皮折痕向眼尾横向拉长延展的宽度范围。")
                        }
                    }
                    .padding(.vertical, 2)

                    Divider().background(Color.white.opacity(0.1)).padding(.vertical, 2)

                    eyelidSlider("去双眼皮贴反光", \.tapeConceal,
                                 range: 0...1,
                                 help: "智能检测上眼睑双眼皮贴边缘反光硬边并平滑柔焦，与自然肤色无缝融合。")

                    Divider().background(Color.white.opacity(0.1)).padding(.vertical, 2)

                    eyelidSlider("卧蚕饱满提亮", \.aegyoSalLuminance,
                                 range: 0...1,
                                 help: "在下睫毛下方眼轮匝肌隆起处注入自然珠光高光，打造饱满减龄效果。")
                    eyelidSlider("卧蚕下缘修容", \.aegyoSalShadow,
                                 range: 0...1,
                                 help: "在卧蚕凸起下缘轻微加深微雕立体阴影弧线，清晰界定卧蚕边界。")
                    eyelidSlider("卧蚕饱满宽度", \.aegyoSalWidth,
                                 range: 0.5...1.5,
                                 help: "控制下眼睑卧蚕凸起区域的垂直宽度与丰满范围（0.5x ~ 1.5x）。")
                }
                .padding(.top, 10)
            }
        }
    }

    private func eyelidSlider(_ title: String,
                              _ keyPath: WritableKeyPath<EyelidAegyoSalSettings, Double>,
                              range: ClosedRange<Double> = 0...1,
                              help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.eyelidAegyoSalSettings[keyPath: keyPath] },
                set: { val in
                    model.updateEyelidAegyoSal { $0[keyPath: keyPath] = val }
                }
            ),
            range: range
        )
        .help(help)
    }

    // MARK: - Smart hair color harmonization & gray hair removal (P2-R)

    private var hairColorSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("发色统一与白发消除", systemImage: "sparkles.square.filled.on.square")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.hairColorIsActive {
                    Button("重置") {
                        model.resetHairColor()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }
            }

            Text("秀发美学色彩精修：精准识别并消除散落白发与银丝缕，统一阳光暴晒或染发退色产生的斑驳色块，并提供7款自然沙龙发色微调。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用发色统一与白发修整", isOn: Binding(
                get: { model.hairColorSettings.enabled },
                set: { model.setHairColorEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.hairColorSettings.enabled {
                VStack(spacing: 8) {
                    hairColorSlider("白发消除强度", \.grayHairRemoval, range: 0...1,
                                    help: "智能压暗散落银白发丝，取样周边基底发色柔和过渡，避免黑头盔硬边。")
                    hairColorSlider("发色统一收敛", \.hairHarmonization, range: 0...1,
                                    help: "抑制发梢枯黄、退色与斑驳色差，将毛发色彩收敛至统一基准调。")

                    HStack {
                        Text("沙龙发色色调")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { model.hairColorSettings.hairTone },
                            set: { tone in
                                model.updateHairColor { $0.hairTone = tone }
                            }
                        )) {
                            ForEach(HairTone.allCases) { tone in
                                Text(tone.displayName).tag(tone)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 110)
                    }

                    if model.hairColorSettings.hairTone != .original {
                        hairColorSlider("发色调色强度", \.hairToneStrength, range: 0...1,
                                        help: "控制目标沙龙发色浓郁度，保留原生发丝明暗光影层次与高光。")
                    }

                    hairColorSlider("发色明度微调", \.hairLuminanceAdjust, range: -0.5...0.5,
                                    help: "提升或压暗头发整体明度（-50% ~ +50%）。")
                }
                .padding(.top, 8)
            }
        }
    }

    private func hairColorSlider(_ title: String,
                                 _ keyPath: WritableKeyPath<HairColorSettings, Double>,
                                 range: ClosedRange<Double> = 0...1,
                                 help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.hairColorSettings[keyPath: keyPath] },
                set: { val in
                    model.updateHairColor { $0[keyPath: keyPath] = val }
                }
            ),
            range: range
        )
        .help(help)
    }

    // MARK: - Smart facial hair, peach fuzz removal & feature mole management (P2-S)

    private var facialHairSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("唇毛胡青与特征痣精修", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.facialHairIsActive {
                    Button("重置") {
                        model.resetFacialHair()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }
            }

            Text("面部细节洁净精修：消除女性唇周暗色桃毛绒毛，中和男性剃须后下颌发青暗沉与胡茬颗粒，并提供特征痣保留、淡化或消除管理。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用唇毛胡青与特征痣精修", isOn: Binding(
                get: { model.facialHairSettings.enabled },
                set: { model.setFacialHairEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.facialHairSettings.enabled {
                VStack(spacing: 8) {
                    facialHairSlider("唇毛消除强度", \.lipFuzzRemoval, range: 0...1,
                                     help: "消除上唇微细暗色绒毛，保留唇红缘锐利度与自然毛孔质感。")
                    facialHairSlider("胡青消除与提亮", \.beardShadowReduction, range: 0...1,
                                     help: "消除下巴与下颌骨剃须后冷调发青发暗区域，补充暖润肤色并提升明度。")
                    facialHairSlider("胡茬黑点平滑", \.stubbleSmoothing, range: 0...1,
                                     help: "平滑下颌微小胡茬斑点，减少粗糙颗粒感。")

                    HStack {
                        Text("特征痣管理")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { model.facialHairSettings.moleManagement },
                            set: { mode in
                                model.updateFacialHair { $0.moleManagement = mode }
                            }
                        )) {
                            ForEach(MoleManagementMode.allCases, id: \.self) { mode in
                                Text(mode.localizedName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 130)
                    }

                    if model.facialHairSettings.moleManagement != .preserve {
                        facialHairSlider("特征痣修饰强度", \.moleRemovalIntensity, range: 0...1,
                                         help: "淡化或彻底消除面部深色特征痣的强度。")
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func facialHairSlider(_ title: String,
                                  _ keyPath: WritableKeyPath<FacialHairSettings, Double>,
                                  range: ClosedRange<Double> = 0...1,
                                  help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.facialHairSettings[keyPath: keyPath] },
                set: { val in
                    model.updateFacialHair { $0[keyPath: keyPath] = val }
                }
            ),
            range: range
        )
        .help(help)
    }

    // MARK: - Smart facial micro-expression, smile & lip shape enhancement (P2-T)

    private var expressionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("微表情与微笑唇形微雕", systemImage: "face.smiling")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.expressionIsActive {
                    Button("重置") {
                        model.resetExpression()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }
            }

            Text("面部微表情与唇形美学微雕：通过解剖学笑肌动力学上扬口角，调整微笑舒展宽度与左右唇角对称性，提拉丘比特弓实现幼态人中缩短，微雕上下唇丰满度，并叠加唇峰立体珠光高光。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用微表情与微笑唇形微雕", isOn: Binding(
                get: { model.expressionSettings.enabled },
                set: { model.setExpressionEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.expressionSettings.enabled {
                VStack(spacing: 8) {
                    expressionSlider("微笑嘴角上扬", \.smileDegree, range: 0...1,
                                     help: "模拟笑肌牵拉双侧口角自然向上、向外抬升，改善苦相嘴角下垂。")
                    expressionSlider("微笑宽度调节", \.smileWidth, range: -0.5...0.5,
                                     help: "横向微调嘴角舒展宽度：正值舒展大方，负值适度收紧。")
                    expressionSlider("唇角对称校准", \.lipSymmetry, range: 0...1,
                                     help: "自动平衡左右口角高低差，校准歪嘴笑与不对称表情。")
                    expressionSlider("幼态人中缩短", \.philtrumShortening, range: 0...1,
                                     help: "向上提拉上唇峰丘比特弓，缩短鼻底与唇峰距离，打造年轻幼态感。")
                    expressionSlider("上唇丰满度", \.upperLipPlump, range: -0.5...0.5,
                                     help: "独立调节上唇厚度与饱满弧度。")
                    expressionSlider("下唇丰满度", \.lowerLipPlump, range: -0.5...0.5,
                                     help: "独立调节下唇嘟嘟厚度与下边缘弧线。")
                    expressionSlider("唇峰珠光高光", \.lip3DHighlight, range: 0...1,
                                     help: "在唇珠及下唇微隆起处增加立体柔光高光，并增强下唇窝自然微阴影。")
                }
                .padding(.top, 8)
            }
        }
    }

    private func expressionSlider(_ title: String,
                                  _ keyPath: WritableKeyPath<ExpressionSettings, Double>,
                                  range: ClosedRange<Double> = 0...1,
                                  help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.expressionSettings[keyPath: keyPath] },
                set: { val in
                    model.updateExpression { $0[keyPath: keyPath] = val }
                }
            ),
            range: range
        )
        .help(help)
    }

    // MARK: - Smart eye shape reshaping & mid-face balance (P2-U)

    private var eyeShapeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("眼型微雕与眼位平衡", systemImage: "eye")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.eyeShapeIsActive {
                    Button("重置") {
                        model.resetEyeShape()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }
            }

            Text("眼部解剖学美学微雕：智能微开内外眼角，无辜眼尾下至延展，调节眼型圆润度与猫眼走势，校准眼位倾斜与高低眼，优化双眼间距与中庭垂直比例（幼态短中庭），平衡双眼对称性。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用眼型微雕与眼位平衡", isOn: Binding(
                get: { model.eyeShapeSettings.enabled },
                set: { model.setEyeShapeEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.eyeShapeSettings.enabled {
                VStack(spacing: 8) {
                    eyeShapeSlider("开内眼角", \.innerCanthoplasty, range: 0...1,
                                   help: "适度向鼻侧微开内眼角，平缓内眦赘皮，拉近内眼角距离。")
                    eyeShapeSlider("开外眼角与眼尾下至", \.outerCanthoplasty, range: 0...1,
                                   help: "向外横向延展外眼角并轻微向下微调，打造混血无辜大眼轮廓。")
                    eyeShapeSlider("眼型圆润度 (小鹿眼/猫眼)", \.eyeRoundness, range: -0.5...0.5,
                                   help: "正值增加上下眼睑弧度打造灵动小鹿圆眼，负值收紧眼睑形成狭长高级猫眼。")
                    eyeShapeSlider("眼位倾斜校准 (吊眼/下垂眼)", \.eyeTilt, range: -0.5...0.5,
                                   help: "旋转校准内外眼角倾斜轴：正值上扬外眼角（上扬魅惑），负值下垂外眼角（温柔无辜）。")
                    eyeShapeSlider("眼距微调", \.interpupillaryDistance, range: -0.5...0.5,
                                   help: "整体微调双眼间距：正值拉开眼距，负值聚拢眼距，协调三庭五眼。")
                    eyeShapeSlider("眼位垂直与中庭缩短", \.eyeVerticalPosition, range: -0.5...0.5,
                                   help: "整体垂直移动双眼：正值下移双眼缩短中庭打造幼态比例，负值上移双眼。")
                    eyeShapeSlider("双眼大小与对称性", \.eyeSymmetry, range: 0...1,
                                   help: "自动探测左右眼大小与高低差异，平抑倾斜高低眼与不对称大小眼。")
                }
                .padding(.top, 8)
            }
        }
    }

    private func eyeShapeSlider(_ title: String,
                                _ keyPath: WritableKeyPath<EyeShapeSettings, Double>,
                                range: ClosedRange<Double> = 0...1,
                                help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.eyeShapeSettings[keyPath: keyPath] },
                set: { val in
                    model.updateEyeShape { $0[keyPath: keyPath] = val }
                }
            ),
            range: range
        )
        .help(help)
    }

    // MARK: - Smart nose reshaping, 3D bridge contouring & structural correction (P2-V)

    private var noseReshapeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("鼻部微雕与立体塑形", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.noseReshapeIsActive {
                    Button("重置") {
                        model.resetNoseReshape()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }
            }

            Text("鼻部骨相精细微雕与立体光影重构：鼻翼宽窄收放、鼻头立体微缩聚拢、鼻梁山根挺拔收紧、朝天鼻下拉与鹰钩鼻微翘矫正、驼峰鼻背平缓抚平、鼻长中庭平衡调节，叠加 3D 鼻背珍珠高光与双侧修容阴影。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用鼻部微雕与立体塑形", isOn: Binding(
                get: { model.noseReshapeSettings.enabled },
                set: { model.setNoseReshapeEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.noseReshapeSettings.enabled {
                VStack(spacing: 8) {
                    noseReshapeSlider("鼻翼收窄", \.narrowNoseWing, range: -0.5...0.5,
                                      help: "横向内收鼻翼基底，改善鼻翼肥大外扩；负值适度放宽。")
                    noseReshapeSlider("鼻头立体微缩", \.noseTipSize, range: -0.5...0.5,
                                      help: "聚拢微缩圆钝鼻头肉感，雕刻小巧水滴鼻尖；负值适度饱满。")
                    noseReshapeSlider("鼻梁挺拔收窄", \.noseBridgeWidth, range: -0.5...0.5,
                                      help: "收紧鼻骨侧壁与山根宽度，打造挺拔骨相感；负值放宽。")
                    noseReshapeSlider("鼻尖仰俯角矫正", \.nosePitchAngle, range: -0.5...0.5,
                                      help: "纵向校准鼻尖走势：正值下拉鼻尖延长鼻小柱（矫正朝天鼻），负值微翘鼻尖（矫正鹰钩鼻与下垂）。")
                    noseReshapeSlider("驼峰鼻背抚平", \.humpSmoothing, range: 0...1,
                                      help: "平缓抚平鼻背中段骨性突出，呈现平直顺滑微弧侧颜。")
                    noseReshapeSlider("鼻长中庭平衡", \.noseLength, range: -0.5...0.5,
                                      help: "纵向微调鼻部长度：负值缩短鼻长打造幼态短中庭，正值拉长鼻梁。")
                    noseReshapeSlider("3D 鼻梁高光与修容", \.nose3DContour, range: 0...1,
                                      help: "沿鼻梁中轴线与鼻尖渲染立体珍珠高光，并在鼻骨两侧叠加柔和修容阴影。")
                }
                .padding(.top, 8)
            }
        }
    }

    private func noseReshapeSlider(_ title: String,
                                   _ keyPath: WritableKeyPath<NoseReshapeSettings, Double>,
                                   range: ClosedRange<Double> = 0...1,
                                   help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.noseReshapeSettings[keyPath: keyPath] },
                set: { val in
                    model.updateNoseReshape { $0[keyPath: keyPath] = val }
                }
            ),
            range: range
        )
        .help(help)
    }

    // MARK: - Smart jawline sculpting, chin reshaping & lower-face proportions (P2-W)

    private var jawChinReshapeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("下颌角与下巴微雕", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.jawChinReshapeIsActive {
                    Button("重置") {
                        model.resetJawChinReshape()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }
            }

            Text("下庭轮廓与骨相微雕：下颌角宽窄收放修饰方脸、下巴长短微调平衡下庭三庭比例、下巴微翘解决下巴后缩、精致小V脸与幼态圆下巴形态塑形、下颌缘吸脂感微紧致消除双下巴，叠加 3D 颏部高光与下颌修容阴影。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用下颌与下巴微雕", isOn: Binding(
                get: { model.jawChinReshapeSettings.enabled },
                set: { model.setJawChinReshapeEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.jawChinReshapeSettings.enabled {
                VStack(spacing: 8) {
                    jawChinReshapeSlider("下颌角收窄", \.jawWidth, range: -0.5...0.5,
                                         help: "横向内收双侧下颌角，柔化方脸国字脸棱角；正值微拓宽增强骨相感。")
                    jawChinReshapeSlider("下巴长度调节", \.chinLength, range: -0.5...0.5,
                                         help: "纵向微调颏下点位置：负值收短过长下巴平衡下庭，正值拉长后缩短下巴。")
                    jawChinReshapeSlider("下巴微翘立体感", \.chinProjection, range: -0.5...0.5,
                                         help: "微调下巴向前微翘立体感，改善下巴后缩痛点；负值柔化前突。")
                    jawChinReshapeSlider("下巴形态微雕", \.chinShape, range: -0.5...0.5,
                                         help: "微调下巴弧度：负值收尖雕琢精致小V脸，正值圆润饱满打造减龄幼态圆下巴。")
                    jawChinReshapeSlider("下颌缘紧致清晰", \.jawlineTighten, range: 0...1,
                                         help: "沿下颌缘向心紧致提拉，收紧双下巴与软组织松弛，凸显清晰下颌线。")
                    jawChinReshapeSlider("3D 下巴高光与修容", \.chinContour, range: 0...1,
                                         help: "在颏部中心渲染珍珠立体高光，并在下颌边缘叠加柔和修容阴影。")
                }
                .padding(.top, 8)
            }
        }
    }

    private func jawChinReshapeSlider(_ title: String,
                                      _ keyPath: WritableKeyPath<JawChinReshapeSettings, Double>,
                                      range: ClosedRange<Double> = 0...1,
                                      help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.jawChinReshapeSettings[keyPath: keyPath] },
                set: { val in
                    model.updateJawChinReshape { $0[keyPath: keyPath] = val }
                }
            ),
            range: range
        )
        .help(help)
    }

    // MARK: - Smart temples, cheekbones & facial contour smoothness (P2-X)

    private var facialContourSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("太阳穴/颧骨与外轮廓微雕", systemImage: "face.dashed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.facialContourIsActive {
                    Button("重置") {
                        model.resetFacialContour()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.accent)
                }
            }

            Text("太阳穴充盈、颧骨内推、面颊丰盈、外轮廓波折平滑、苹果肌提拉与3D立体光影。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用面部外轮廓微雕", isOn: Binding(
                get: { model.facialContourSettings.enabled },
                set: { model.setFacialContourEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.facialContourSettings.enabled {
                VStack(spacing: 8) {
                    facialContourSlider("太阳穴凹陷饱满", \.templePlump, range: 0...1,
                                        help: "横向向外充盈双侧太阳穴，平整发际线与颧弓衔接，改善菱形脸与凹陷感。")
                    facialContourSlider("颧骨外扩内推", \.cheekboneNarrow, range: 0...1,
                                        help: "横向向内微收双侧颧骨与颧弓最宽处，柔化生硬棱角，弱化骨相突兀感。")
                    facialContourSlider("面颊凹陷丰盈", \.cheekPlump, range: 0...1,
                                        help: "向外丰盈颧下与颊部凹陷软组织，消除干瘪吸腮感，恢复胶原蛋白年轻态。")
                    facialContourSlider("外轮廓波折平滑", \.contourSmoothness, range: 0...1,
                                        help: "沿太阳穴-颧弓-面颊消除阶梯波折，柔化外凸并充盈凹陷，一键打造流畅鹅蛋脸。")
                    facialContourSlider("苹果肌立体提拉", \.appleCheekLift, range: -0.5...0.5,
                                        help: "微调苹果肌高光点：正值向内上方提拉打造减龄幼态笑肌，负值舒缓过于隆起的苹果肌。")
                    facialContourSlider("3D 轮廓立体光影", \.contour3DShading, range: 0...1,
                                        help: "在双侧苹果肌渲染柔光立体高光，并在颧弓与颞部边缘叠加柔和微修容阴影。")
                }
                .padding(.top, 8)
            }
        }
    }

    private func facialContourSlider(_ title: String,
                                     _ keyPath: WritableKeyPath<FacialContourSettings, Double>,
                                     range: ClosedRange<Double> = 0...1,
                                     help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.facialContourSettings[keyPath: keyPath] },
                set: { val in
                    model.updateFacialContour { $0[keyPath: keyPath] = val }
                }
            ),
            range: range
        )
        .help(help)
    }

    // MARK: - Smart eyebrow reshaping, wild brow texture & symmetry calibration (P2-Y)

    private var eyebrowReshapeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("眉形微雕与野生眉", systemImage: "paintbrush.pointed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.eyebrowReshapeIsActive {
                    Button("重置") {
                        model.resetEyebrowReshape()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.accent)
                }
            }

            Text("眉尾提拉、粗细长短微调、双眉对称性校准、野生眉毛流质感与眉骨3D立体光影。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用智能眉形微雕", isOn: Binding(
                get: { model.eyebrowReshapeSettings.enabled },
                set: { model.setEyebrowReshapeEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.eyebrowReshapeSettings.enabled {
                VStack(spacing: 8) {
                    eyebrowReshapeSlider("眉尾走势提拉", \.browTailLift, range: -0.5...0.5,
                                         help: "微调双侧眉尾高度：正值向上提拉抚平八字眉疲态提振眼神，负值舒缓过于上挑的眉毛。")
                    eyebrowReshapeSlider("眉毛粗细饱满", \.browThickness, range: -0.5...0.5,
                                         help: "微调眉毛上下厚度：正值增粗饱满稀疏细弱眉毛，负值纤细化生硬浓黑粗眉。")
                    eyebrowReshapeSlider("眉身长度延展", \.browLength, range: -0.5...0.5,
                                         help: "沿眉弓向外延伸短眉眉梢，协调三庭五眼外侧横向比例；负值适度收敛短眉梢。")
                    eyebrowReshapeSlider("双眉对称校准", \.browSymmetry, range: 0...1,
                                         help: "智能检测左右眉毛高度与曲率差异，平滑向平衡中轴对称态微调，矫正高低眉。")
                    eyebrowReshapeSlider("野生眉毛流感", \.wildBrowTexture, range: 0...1,
                                         help: "强化微观毛流边缘对比与毛发立体质感，智能填补断眉与稀疏缺口，重塑羽状野生眉。")
                    eyebrowReshapeSlider("3D 眉骨立体光影", \.brow3DContour, range: 0...1,
                                         help: "在眉弓外侧迎光面渲染珍珠柔光高光，并在眉下眼窝凹陷处叠加柔和深邃微阴影。")
                }
                .padding(.top, 8)
            }
        }
    }

    private func eyebrowReshapeSlider(_ title: String,
                                      _ keyPath: WritableKeyPath<EyebrowReshapeSettings, Double>,
                                      range: ClosedRange<Double> = 0...1,
                                      help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.eyebrowReshapeSettings[keyPath: keyPath] },
                set: { val in
                    model.updateEyebrowReshape { $0[keyPath: keyPath] = val }
                }
            ),
            range: range
        )
        .help(help)
    }

    // MARK: - Smart facial bone 3D contour shading, facial folding angle & studio lighting (P2-Z)

    private var facialBoneContourSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("全脸骨相光影修容", systemImage: "sparkles.rectangle.stack")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.facialBoneContourIsActive {
                    Button("重置") {
                        model.resetFacialBoneContour()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.accent)
                }
            }

            Text("面部折叠度、T区/C区立体高光、面颊与下颌修容阴影、人中唇峰高光与修容色温。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用全脸骨相光影修容", isOn: Binding(
                get: { model.facialBoneContourSettings.enabled },
                set: { model.setFacialBoneContourEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.facialBoneContourSettings.enabled {
                VStack(spacing: 8) {
                    facialBoneContourSlider("面部折叠度", \.facialFolding, range: 0...1,
                                            help: "增强面部立体折叠度：侧脸光影柔和衰减，正脸中轴挺拔，使扁平大脸呈现出小巧紧凑的高折叠度骨相。")
                    facialBoneContourSlider("T 区立体高光", \.tZoneHighlight, range: 0...1,
                                            help: "额头中下部 + 印堂 + 鼻梁中轴线的物理级珍珠微光，立体拔高面部中段。")
                    facialBoneContourSlider("双侧 C 区高光", \.cZoneHighlight, range: 0...1,
                                            help: "外眼眶经太阳穴向颧骨上方弯曲的高光弧带，打造明星红毯级的饱满通透水光感。")
                    facialBoneContourSlider("面颊侧影修容", \.cheekContourShadow, range: 0...1,
                                            help: "颧下向口角延伸的自然渐变微阴影，收敛宽脸、雕琢超模级骨相结构。")
                    facialBoneContourSlider("下颌线下阴影", \.jawlineShadow, range: 0...1,
                                            help: "沿下颌骨底缘向颈部过渡的立体微阴影，消除光线平淡导致的面颈粘连，强化下颌线切割感。")
                    facialBoneContourSlider("人中唇峰高光", \.philtrumHighlight, range: 0...1,
                                            help: "双侧人中嵴与丘比特唇弓的点缀高光，增强面部下庭精致生动感与幼态立体感。")
                    facialBoneContourSlider("修容光影色温", \.contourToneWarmth, range: -0.5...0.5,
                                            help: "修容阴影与高光的色温倾向：正值偏暖金蜜桃更适合暖调肤色，负值偏中性冷茶调防止修容发脏。")
                }
                .padding(.top, 8)
            }
        }
    }

    private func facialBoneContourSlider(_ title: String,
                                         _ keyPath: WritableKeyPath<FacialBoneContourSettings, Double>,
                                         range: ClosedRange<Double> = 0...1,
                                         help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.facialBoneContourSettings[keyPath: keyPath] },
                set: { val in
                    model.updateFacialBoneContour { $0[keyPath: keyPath] = val }
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

    // MARK: - Smart bokeh and optical depth-of-field synthesis (P2-Q)

    private var bokehBlurSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("大光圈景深虚化与光斑雕刻", systemImage: "camera.aperture")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                if model.bokehBlurIsActive {
                    Button("重置") {
                        model.resetBokehBlur()
                    }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }
            }

            Text("商业人像与影棚镜头虚化：基于物理地面渐变与人物深度场，模拟大光圈镜头光学散焦；支持 4 款光学光圈形状（圆形/多边形/旋焦/柔焦奶化），提取背景点光源爆发通透光斑，并严密锁定主体边缘防止虚化溢色。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("启用大光圈景深虚化与光斑", isOn: Binding(
                get: { model.bokehBlurSettings.enabled },
                set: { model.setBokehBlurEnabled($0) }
            ))
            .font(.system(size: 10))
            .toggleStyle(.checkbox)
            .padding(.top, 10)

            if model.bokehBlurSettings.enabled {
                VStack(spacing: 8) {
                    Picker("光圈光斑形态", selection: Binding(
                        get: { model.bokehBlurSettings.bokehShape },
                        set: { val in
                            model.updateBokehBlur { $0.bokehShape = val }
                        }
                    )) {
                        ForEach(BokehShape.allCases) { shape in
                            Text(shape.title).tag(shape)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 10))

                    bokehSlider("光圈虚化大小", \.apertureFocalSize,
                                range: 0...1,
                                help: "控制模拟光圈孔径与背景散焦模糊半径（等效 0~50px 弥散圆）。")
                    bokehSlider("焦平面偏移", \.focalPlaneOffset,
                                range: -0.5...0.5,
                                help: "前后移动清晰对焦平面（负值靠前，正值向深景深延伸）。")
                    bokehSlider("景深衰减率", \.depthFalloffRate,
                                range: 0.2...2.0,
                                help: "调节随距离延伸的虚化衰减速率（模拟不同焦距镜头的景深过渡）。")
                    bokehSlider("高光光斑爆发", \.specularHighlightBoost,
                                range: 0...1,
                                help: "增强背景小光源与树隙透光的点光源亮度，形成晶莹剔透的高光光斑。")
                    bokehSlider("主体防溢色保护", \.edgeBleedProtection,
                                range: 0...1,
                                help: "强化人物主体轮廓保边滤波，彻底杜绝虚化背景反渗入发丝与边缘。")
                }
                .padding(.top, 10)
            }
        }
    }

    private func bokehSlider(_ title: String,
                             _ keyPath: WritableKeyPath<BokehBlurSettings, Double>,
                             range: ClosedRange<Double> = 0...1,
                             help: String) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(
                get: { model.bokehBlurSettings[keyPath: keyPath] },
                set: { val in
                    model.updateBokehBlur { $0[keyPath: keyPath] = val }
                }
            ),
            range: range
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

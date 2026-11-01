import AppKit
import SwiftUI
import PhotoCore

/// Selection, evidence and adjustments stay separate so the user can first
/// check the affected pixels, then judge the result without the overlay.
struct MaskInspector: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            creationTools
            coverageTools
            maskList
            if let mask = model.selectedLocalMask {
                selectedHeader(mask)
                selectionControls(mask)
                regionalEvidence
                lightControls(mask)
                colorControls(mask)
                harmonyControls(mask)
                managementControls(mask)
            } else {
                Text("先建立选区，再检查覆盖范围。可以用画笔补选、减去不需要的部分，或按亮度和颜色进一步限定。")
                    .font(.system(size: 10)).foregroundColor(AtelierPalette.muted).lineSpacing(5)
            }
            Text("几何选区按相对位置用于整批照片，不跟踪主体。亮度和颜色范围逐张重算；区域建议仅依据当前照片，采用的局部参数用于整批。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(5)
        }
    }

    private var creationTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("选中需要调整的区域", systemImage: "circle.dotted")
                .font(.system(size: 11, weight: .medium))
            Menu {
                ForEach(LocalMaskPreset.allCases, id: \.self) { preset in
                    Button(preset.title) { model.addMaskPreset(preset) }
                }
            } label: { Label("快速起点", systemImage: "sparkles") }
                .font(.system(size: 11)).disabled(model.afterImage == nil || model.adjustments.masks.count >= 16)
            Picker("选区工具", selection: $model.maskKind) {
                ForEach(MaskKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }.font(.system(size: 10))
            Picker("绘制操作", selection: $model.maskDrawMode) {
                ForEach(MaskDrawMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if model.maskKind == .brush {
                AdjustmentSlider(title: "笔刷半径", value: $model.brushRadius, range: 0.005...0.4, percent: true)
                AdjustmentSlider(title: "笔刷柔边", value: $model.brushFeather, range: 0...1, percent: true)
            }
            Button { model.beginMaskDrawing() } label: {
                Label(drawingTitle, systemImage: model.drawingMask ? "checkmark" : "plus.circle")
                    .font(.system(size: 11)).frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(AtelierPalette.raised).cornerRadius(6)
            }.buttonStyle(.plain).disabled(model.afterImage == nil ||
                (model.maskDrawMode == .new && model.adjustments.masks.count >= 16) ||
                (model.maskDrawMode != .new && model.selectedLocalMask == nil))
            if model.drawingMask {
                Text("拖动绘制；画笔也可单击点涂。加选、减选和交集可连续绘制多笔，完成后再次点击上方按钮。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.accent).lineSpacing(4)
            }
        }
    }

    private var drawingTitle: String {
        if model.drawingMask { return "完成修边" }
        if model.maskDrawMode == .new && (model.maskKind == .luminance || model.maskKind == .color) {
            return "建立\(model.maskKind.title)选区"
        }
        return model.maskDrawMode == .new ? "在照片上新建选区" : "在选中蒙版中\(model.maskDrawMode.title)"
    }

    private var coverageTools: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("显示实际覆盖区域", isOn: $model.showMaskCoverage)
            Toggle("显示形状轮廓", isOn: $model.showMaskOverlay)
            if model.showMaskCoverage {
                AdjustmentSlider(title: "覆盖显示透明度", value: $model.maskOverlayOpacity, range: 0.1...0.85, percent: true)
                Text("粉色表示实际调整权重，包含羽化、范围限制与修边。检查效果时关闭覆盖。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
            }
        }.toggleStyle(.checkbox).font(.system(size: 10))
    }

    private var maskList: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("局部蒙版").font(.system(size: 10, weight: .semibold))
                Spacer()
                Text("\(model.adjustments.masks.count) / 16")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(AtelierPalette.muted)
            }
            ForEach(model.adjustments.masks) { mask in
                Button {
                    model.cancelMaskInteraction()
                    model.selectedMask = mask.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: mask.enabled ? "circle.lefthalf.filled" : "circle.dashed")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mask.name).lineLimit(1)
                            Text("\(mask.kind.title) · \(Int(mask.opacity * 100))%\(mask.enabled ? "" : " · 已停用")")
                                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                        }
                        Spacer()
                        if model.selectedMask == mask.id { Image(systemName: "checkmark").foregroundColor(AtelierPalette.accent) }
                    }.font(.system(size: 10)).padding(9).frame(maxWidth: .infinity, alignment: .leading)
                        .background(model.selectedMask == mask.id ? AtelierPalette.raised : .clear).cornerRadius(5)
                }.buttonStyle(.plain)
            }
        }
    }

    private func selectedHeader(_ mask: LocalMask) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Divider()
            TextField("蒙版名称", text: Binding(get: {
                model.adjustments.masks.first { $0.id == mask.id }?.name ?? mask.name
            }, set: { text in
                update(mask.id) { $0.name = String(text.prefix(256)) }
            })).textFieldStyle(.roundedBorder).font(.system(size: 11))
            Toggle("启用此蒙版", isOn: binding(mask, \.enabled)).toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 10))
            AdjustmentSlider(title: "整体强度", value: binding(mask, \.opacity), range: 0...1, percent: true)
        }
    }

    private func selectionControls(_ mask: LocalMask) -> some View {
        DisclosureGroup("选区与边缘") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(mask.kind == .luminance || mask.kind == .color ? "反选范围与修边结果" : "反转基础选区与修边结果",
                       isOn: binding(mask, \.inverted))
                if mask.kind == .radial || mask.kind == .linear {
                    Toggle("编辑形状控制点", isOn: $model.maskEditMode)
                        .onChange(of: model.maskEditMode) { editing in
                            if editing { model.drawingMask = false; model.pickingMaskColor = false }
                        }
                    Text(mask.kind == .radial ? "拖动中心移动选区，拖动末端改变范围；修边笔迹保持原位。" : "拖动起点或终点调整渐变；修边笔迹保持原位。")
                        .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                }
                if mask.kind != .luminance && mask.kind != .color {
                    AdjustmentSlider(title: "基础选区羽化", value: binding(mask, \.feather), range: 0...1, percent: true)
                }
                if mask.kind == .brush {
                    AdjustmentSlider(title: "基础笔迹半径", value: binding(mask, \.radius), range: 0.005...0.4, percent: true)
                }
                if !mask.components.isEmpty {
                    Text("修边按下列顺序作用，再与范围限制取交集。")
                        .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                    ForEach(Array(mask.components.enumerated()), id: \.element.id) { index, component in
                        HStack {
                            Text("\(index + 1). \(component.operation.title) · \(component.kind.title)").font(.system(size: 9))
                            Spacer()
                            Button { model.removeMaskComponent(component.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).help("移除此修边步骤")
                        }
                    }
                    Button("撤回最后一步修边") { model.removeMaskComponent() }.font(.system(size: 10))
                }
                luminanceControls(mask)
                rangeColorControls(mask)
            }.padding(.top, 11).toggleStyle(.checkbox).font(.system(size: 10))
        }.font(.system(size: 11, weight: .medium))
    }

    private func luminanceControls(_ mask: LocalMask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if mask.kind == .luminance {
                Text("按亮度选择 · 与几何修边取交集").font(.system(size: 10))
            } else {
                Toggle("进一步限定亮度", isOn: binding(mask, \.restrictLuminance))
            }
            if mask.kind == .luminance || mask.restrictLuminance {
                AdjustmentSlider(title: "亮度下限", value: luminanceBinding(mask, lower: true), range: 0...1, percent: true)
                AdjustmentSlider(title: "亮度上限", value: luminanceBinding(mask, lower: false), range: 0...1, percent: true)
                AdjustmentSlider(title: "亮度范围柔化", value: binding(mask, \.rangeSoftness), range: 0...0.5, percent: true)
            }
        }
    }

    private func rangeColorControls(_ mask: LocalMask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if mask.kind == .color {
                Text("按取样颜色选择 · 与几何修边取交集").font(.system(size: 10))
            } else {
                Toggle("进一步限定颜色", isOn: binding(mask, \.restrictColor))
            }
            if mask.kind == .color || mask.restrictColor {
                ColorPicker("颜色中心", selection: colorBinding(mask), supportsOpacity: false)
                Button {
                    model.cancelMaskInteraction(); model.pickingMaskColor = true
                } label: {
                    Label(model.pickingMaskColor ? "点击照片取样…" : "从照片取样", systemImage: "eyedropper")
                }.disabled(model.previewBusy)
                AdjustmentSlider(title: "颜色容差", value: binding(mask, \.colorTolerance), range: 0.01...1, percent: true)
                AdjustmentSlider(title: "颜色边界柔化", value: binding(mask, \.colorSoftness), range: 0...0.5, percent: true)
                Text("取样依据全局校正后的原色，选区不随 LUT 风格变化。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
            }
        }
    }

    private var regionalEvidence: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("区域实测与建议").font(.system(size: 11, weight: .medium))
            if let inspection = model.maskInspection {
                HStack {
                    Text(String(format: "有效覆盖 %.1f%%", inspection.coverage * 100))
                    Spacer()
                    Text(String(format: "中位亮度 %.3f", inspection.medianLuminance))
                }.font(.system(size: 9, design: .monospaced)).foregroundColor(AtelierPalette.muted)
                Text(inspection.summary).font(.system(size: 10)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                Button("采用区域光线建议") { model.applyMaskSuggestion() }
                    .font(.system(size: 10)).disabled(model.previewBusy || inspection.coverage <= 0.005)
            } else {
                Text(model.previewBusy ? "正在测量有效选区…" : "调整选区后显示实测结果。")
                    .font(.system(size: 10)).foregroundColor(AtelierPalette.muted)
            }
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(AtelierPalette.raised.opacity(0.65)).cornerRadius(6)
    }

    private func lightControls(_ mask: LocalMask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("局部光线").font(.system(size: 11, weight: .medium)).padding(.bottom, 8)
            AdjustmentSlider(title: "曝光", value: binding(mask, \.exposureEV), range: -3...3, suffix: " EV")
            AdjustmentSlider(title: "高光", value: binding(mask, \.highlights), range: -1...1)
            AdjustmentSlider(title: "阴影", value: binding(mask, \.shadows), range: -1...1)
            AdjustmentSlider(title: "对比度", value: binding(mask, \.contrast), range: 0.5...1.5)
            AdjustmentSlider(title: "锐化", value: binding(mask, \.sharpness), range: 0...1, percent: true)
        }
    }

    private func colorControls(_ mask: LocalMask) -> some View {
        DisclosureGroup("局部颜色") {
            VStack(spacing: 4) {
                AdjustmentSlider(title: "饱和度", value: binding(mask, \.saturation), range: 0...2)
                AdjustmentSlider(title: "冷暖", value: binding(mask, \.warmth), range: -1...1)
                AdjustmentSlider(title: "绿 ↔ 洋红", value: binding(mask, \.tint), range: -1...1)
            }.padding(.top, 12)
        }.font(.system(size: 11, weight: .medium))
    }

    private func harmonyControls(_ mask: LocalMask) -> some View {
        DisclosureGroup("与整体协调") {
            VStack(alignment: .leading, spacing: 5) {
                Picker("作用顺序", selection: binding(mask, \.stage)) {
                    Text("全局风格之前").tag(MaskStage.beforeLook)
                    Text("全局风格之后").tag(MaskStage.afterLook)
                }.font(.system(size: 10))
                Text(mask.stage == .beforeLook
                     ? "局部校正后共同经过 LUT 和风格保护，适合统一整张照片的色调。"
                     : "在 LUT 之后进行局部收尾。旧配方保留此顺序，可自行切换并比较。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4).padding(.bottom, 8)
                AdjustmentSlider(title: "高光保护", value: binding(mask, \.highlightProtection), range: 0...1, percent: true)
                AdjustmentSlider(title: "色彩保护", value: binding(mask, \.colorProtection), range: 0...1, percent: true)
                Text("保护用于减轻局部提亮造成的高光溢出和过强色度。多个蒙版在各自作用阶段内按列表顺序叠加，可用强度和启用开关比较。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
                Text(model.adjustments.colorHarmony?.enabled == true
                     ? "已启用整体协调：所有局部与滤镜叠加后，再限制突兀色彩；可到“基础”比较和调整保护强度。"
                     : "整体协调保护未启用；如叠加后颜色过强，可在“基础”开启。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.accent).lineSpacing(4)
            }.padding(.top, 11)
        }.font(.system(size: 11, weight: .medium))
    }

    private func managementControls(_ mask: LocalMask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("复制") { model.duplicateSelectedMask() }.disabled(model.adjustments.masks.count >= 16)
                Spacer()
                Button { model.moveSelectedMask(by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(model.activeMaskIndex == 0).help("提前叠加顺序")
                Button { model.moveSelectedMask(by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(model.activeMaskIndex == model.adjustments.masks.count - 1).help("延后叠加顺序")
            }
            Button("重置此蒙版的调整参数") { model.resetSelectedMaskAdjustments() }
            Button("删除此蒙版", role: .destructive) { model.deleteSelectedMask() }
        }.font(.system(size: 10)).padding(.top, 4)
    }

    private func binding<T>(_ mask: LocalMask, _ keyPath: WritableKeyPath<LocalMask, T>) -> Binding<T> {
        Binding(get: { model.adjustments.masks.first { $0.id == mask.id }?[keyPath: keyPath] ?? mask[keyPath: keyPath] },
                set: { value in update(mask.id) { $0[keyPath: keyPath] = value } })
    }

    private func update(_ id: UUID, _ change: (inout LocalMask) -> Void) {
        guard !model.batchRunning, let index = model.adjustments.masks.firstIndex(where: { $0.id == id }) else { return }
        change(&model.adjustments.masks[index])
    }

    private func luminanceBinding(_ mask: LocalMask, lower: Bool) -> Binding<Double> {
        Binding(get: {
            let current = model.adjustments.masks.first { $0.id == mask.id } ?? mask
            return lower ? current.luminanceMin : current.luminanceMax
        }, set: { value in
            update(mask.id) { current in
                if lower { current.luminanceMin = min(value, current.luminanceMax) }
                else { current.luminanceMax = max(value, current.luminanceMin) }
            }
        })
    }

    private func colorBinding(_ mask: LocalMask) -> Binding<Color> {
        Binding(get: {
            let value = model.adjustments.masks.first { $0.id == mask.id }?.color ?? mask.color
            return Color(.sRGB, red: value.red, green: value.green, blue: value.blue)
        }, set: { value in
            guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
            update(mask.id) {
                $0.color = MaskColor(red: min(1, max(0, Double(color.redComponent))),
                                    green: min(1, max(0, Double(color.greenComponent))),
                                    blue: min(1, max(0, Double(color.blueComponent))))
            }
        })
    }
}

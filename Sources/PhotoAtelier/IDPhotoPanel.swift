import AppKit
import PhotoCore
import SwiftUI

/// Right-inspector “证件照 / 换背景” tab for the P1-B certificate stage.
///
/// This panel edits `AdjustmentSettings.certificatePhoto` (recipe v12). Every edit
/// goes through `AppModel.updateCertificatePhoto`, so the existing
/// `onChange(adjustments) → requestPreview()` token/debounce mechanism refreshes
/// the preview off the main thread and undo/redo keeps working.
///
/// Honest boundaries: Vision person segmentation + heuristic feathering is a v1
/// cutout, not commercial matting (hair/transparent clothing/complex backgrounds
/// are not guaranteed). When no person (or no face for a size crop) is detected
/// the engine skips the stage explicitly and the status card shows why. Cropping
/// to a print size changes the canvas extent: local masks are normalized against
/// the cropped image and should be reviewed afterwards.
struct IDPhotoPanel: View {
    @ObservedObject var model: AppModel

    private var settings: CertificatePhotoSettings {
        model.certificatePhotoSettings
    }
    private var isActive: Bool { model.certificateIsActive }
    private var canEdit: Bool { !model.batchRunning && model.afterImage != nil }
    private var report: CertificatePhotoReport? { model.previewReport.certificatePhoto }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("证件照 / 换背景 v1", systemImage: "person.crop.rectangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .padding(.bottom, 10)
            Text("本机 Vision 人物分割 + 启发式羽化/去色边 + 纯色/本地图片背景 + 合成阴影；证件照按 300DPI 像素精确裁剪。不是商业级抠图：头发丝、透明衣物、复杂背景与多人重叠不保证；合成测试只验证像素/几何契约，未做真实照片审美验收。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)

            Toggle("启用证件照 / 换背景（v12 配方）", isOn: enabledBinding)
                .toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 11)).padding(.bottom, 10)
                .disabled(!canEdit)
                .help("关闭为显式中性：不改像素、旧配方路径；开启后整段可以撤销。")

            statusCard
            Group {
            separator

            Group {
                panelHeading("背景")
                Picker("背景来源", selection: backgroundSourceBinding) {
                    ForEach(CertificateBackgroundSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }.font(.system(size: 10))
                if settings.backgroundSource == .preset {
                    HStack(spacing: 10) {
                        ForEach(IDPhotoBackgroundPreset.allCases) { preset in
                            Button {
                                model.updateCertificatePhoto { $0.backgroundPreset = preset }
                            } label: {
                                Circle()
                                    .fill(Color(red: preset.color.red,
                                                green: preset.color.green,
                                                blue: preset.color.blue))
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(
                                        settings.backgroundPreset == preset
                                            ? AtelierPalette.accent : Color.white.opacity(0.2),
                                        lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                            .help(preset.title)
                        }
                        Text(settings.backgroundPreset.title)
                            .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                        Spacer(minLength: 0)
                    }.padding(.vertical, 8)
                } else if settings.backgroundSource == .customColor {
                    HStack {
                        ColorPicker("背景颜色", selection: customColorBinding)
                            .font(.system(size: 10))
                            .disabled(!canEdit)
                        Text(settings.customBackground.hexString)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(AtelierPalette.muted)
                    }.padding(.vertical, 6)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Button("导入本地背景图片…") { model.importCertificateBackgroundImage() }
                            .font(.system(size: 10)).buttonStyle(.bordered)
                            .disabled(!canEdit)
                        Text(settings.backgroundImagePath?
                            .split(separator: "/").last.map(String.init) ?? "尚未选择背景图片")
                            .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                            .lineLimit(1).truncationMode(.middle)
                        Text("只支持本地图片文件；不联网、不上传。图片按比例裁切填满画面，不拉伸。")
                            .font(.system(size: 8)).foregroundColor(AtelierPalette.muted)
                            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 6)
                }
            }
            .disabled(!canEdit)
            .opacity(canEdit ? 1 : 0.5)

            separator
            Group {
                panelHeading("尺寸与裁剪")
                Picker("证件照尺寸", selection: sizeBinding) {
                    Text("不裁剪（仅换背景）").tag(IDPhotoSize?.none)
                    ForEach(IDPhotoSize.allCases) { size in
                        Text(size.title).tag(IDPhotoSize?.some(size))
                    }
                }.font(.system(size: 10))
                HStack {
                    Text("输出像素").font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                    Spacer(minLength: 0)
                    Text(pixelLabel).font(.system(size: 9, design: .monospaced))
                        .foregroundColor(AtelierPalette.muted)
                }.padding(.top, 5)
                Picker("DPI", selection: dpiBinding) {
                    Text("300 DPI").tag(300.0)
                    Text("600 DPI").tag(600.0)
                }.font(.system(size: 10)).padding(.top, 6)
                Group {
                    AdjustmentSlider(title: "头部高度比例", value: headHeightBinding, range: 0.40...0.80, percent: true)
                    AdjustmentSlider(title: "头顶留白", value: headTopMarginBinding, range: 0...0.25, percent: true)
                    AdjustmentSlider(title: "水平偏移", value: horizontalOffsetBinding, range: -0.3...0.3)
                    AdjustmentSlider(title: "头部膨胀（发际近似）", value: faceInflateBinding, range: 1.0...1.5, percent: true)
                }
                .disabled(settings.size == nil)
                .opacity(settings.size == nil ? 0.45 : 1)
                Text("裁剪改变画布尺寸；已有局部蒙版/细节按新 extent 归一化，请复核依赖位置的调整。")
                    .font(.system(size: 8)).foregroundColor(AtelierPalette.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!canEdit)
            .opacity(canEdit ? 1 : 0.5)

            separator
            Group {
                panelHeading("阴影与边缘")
                Toggle("合成投影", isOn: shadowEnabledBinding)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 10))
                AdjustmentSlider(title: "阴影不透明度", value: shadowOpacityBinding, range: 0...1, percent: true)
                AdjustmentSlider(title: "阴影模糊", value: shadowBlurBinding, range: 0...0.5, percent: true)
                    .help("0...0.5 是短边的比例参数；引擎内部按短边 10% 缩放为实际像素半径。")
                AdjustmentSlider(title: "阴影水平偏移", value: shadowOffsetXBinding, range: -0.3...0.3)
                AdjustmentSlider(title: "阴影垂直偏移", value: shadowOffsetYBinding, range: -0.3...0.3)
                AdjustmentSlider(title: "边缘去色边", value: edgeDecontaminationBinding, range: 0...1, percent: true)
                    .help("启发式去饱和，减轻原背景色在抠图边缘的残留；不是真正的背景色估计。")
            }
            .disabled(!canEdit)
            .opacity(canEdit ? 1 : 0.5)

            separator
            printSection
            }

            separator
            backdropSection

            separator
            HStack(spacing: 8) {
                Button("重置证件照设置") { model.resetCertificatePhoto() }
                    .font(.system(size: 10)).buttonStyle(.plain)
                    .foregroundColor(isActive ? AtelierPalette.accent : AtelierPalette.muted)
                    .disabled(!canEdit || model.adjustments.certificatePhoto == nil)
                Spacer(minLength: 0)
                Button("重置背景修复") { model.resetBackdrop() }
                    .font(.system(size: 10)).buttonStyle(.plain)
                    .foregroundColor(model.backdropIsActive ? AtelierPalette.accent : AtelierPalette.muted)
                    .disabled(!canEdit || model.adjustments.backdrop == nil)
            }
        }
        .onAppear {
            // Only refresh when this photo has certificate settings and no preview
            // exists yet. Slider/toggle edits already go through the normal
            // onChange(adjustments) token; an unconditional request here would run
            // Vision person segmentation on every tab switch.
            if model.adjustments.certificatePhoto != nil,
               model.previewReport.certificatePhoto == nil,
               !model.previewBusy {
                model.requestPreview()
            }
        }
    }

    // MARK: - Subviews

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 10))
                    .foregroundColor(statusColor)
                Text(statusText)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.8))
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            if isActive, let output = report?.outputPixelSize, report?.applied == true {
                Text("本次输出：\(Int(output.width))×\(Int(output.height)) px · 背景 \(report?.background ?? "")")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(AtelierPalette.muted)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .padding(.bottom, 8)
    }

    private var printSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeading("打印排版预览")
            Text("几何预览只计算纸张一行能放几张，不导出打印文件；最终打印需按打印机 DPI 与纸张设置复核。")
                .font(.system(size: 8)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            Picker("纸张", selection: paperBinding) {
                ForEach(PrintPaper.allCases) { paper in
                    Text(paper.title).tag(paper)
                }
            }.font(.system(size: 10))
            Picker("排版照片尺寸", selection: printPhotoSizeBinding) {
                ForEach(IDPhotoSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }.font(.system(size: 10)).padding(.top, 6)
            HStack(spacing: 8) {
                AdjustmentSlider(title: "间距", value: spacingBinding, range: 0...10, suffix: " mm")
                AdjustmentSlider(title: "边距", value: marginBinding, range: 0...10, suffix: " mm")
            }
            printSummary
        }
        .disabled(!canEdit)
        .opacity(canEdit ? 1 : 0.5)
    }

    private var printSummary: some View {
        Group {
            if let layout = try? IDPhotoLayout.printLayout(settings.print) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(layout.paperPixelSize.width))×\(Int(layout.paperPixelSize.height)) px · \(layout.columns)×\(layout.rows) = \(layout.count) 张")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(AtelierPalette.muted)
                    printGridPreview(layout)
                }.padding(.top, 8)
            } else {
                Text("当前排版参数无法放入纸张（间距/边距过大或照片尺寸不匹配），请调整。")
                    .font(.system(size: 9)).foregroundColor(.orange.opacity(0.9))
                    .padding(.top, 8)
            }
        }
    }

    private func printGridPreview(_ layout: PrintSheetLayout) -> some View {
        Canvas { context, size in
            let scale = min(size.width / layout.paperPixelSize.width,
                            size.height / layout.paperPixelSize.height)
            let originX = (size.width - layout.paperPixelSize.width * scale) / 2
            let originY = (size.height - layout.paperPixelSize.height * scale) / 2
            let paperRect = CGRect(x: originX, y: originY,
                                   width: layout.paperPixelSize.width * scale,
                                   height: layout.paperPixelSize.height * scale)
            context.fill(Path(paperRect), with: .color(.white.opacity(0.08)))
            context.stroke(Path(paperRect), with: .color(.white.opacity(0.2)), lineWidth: 0.8)
            for origin in layout.cellOrigins {
                let rect = CGRect(x: originX + origin.x * scale,
                                  y: originY + origin.y * scale,
                                  width: layout.photoPixelSize.width * scale,
                                  height: layout.photoPixelSize.height * scale)
                context.stroke(Path(rect), with: .color(.white.opacity(0.45)), lineWidth: 0.6)
            }
        }
        .frame(height: 92)
        .background(Color.black.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func panelHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.8))
            .padding(.bottom, 8)
    }

    private var separator: some View {
        Rectangle().fill(AtelierPalette.line).frame(height: 1).padding(.vertical, 14)
    }

    // MARK: - Status text

    private var statusSymbol: String {
        if model.batchRunning { return "hourglass" }
        if report?.applied == true { return "checkmark.circle" }
        if isActive { return "exclamationmark.triangle" }
        return "info.circle"
    }

    private var statusColor: Color {
        if report?.applied == true { return AtelierPalette.accent }
        if isActive { return .orange.opacity(0.9) }
        return AtelierPalette.muted
    }

    private var statusText: String {
        if model.batchRunning { return "批处理进行中：证件照设置会逐张应用到本批照片。" }
        guard isActive else { return "未启用：证件照会跳过，旧配方像素路径保持不变。开启后逐张检测人物。" }
        if model.previewBusy { return "正在生成预览（含人物检测与背景合成）…" }
        if let report {
            if report.applied {
                let coverage = String(format: "%.1f%%", report.coverage * 100)
                let note = report.note.map { "；" + $0 } ?? ""
                return "已应用：检测到人物（覆盖率约 " + coverage + "）" + note
            }
            return report.note ?? "未应用：没有检测到可用人物/人脸，原图保持不变。"
        }
        return model.afterImage == nil ? "打开照片后可预览证件照效果。" : "等待预览结果…"
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(get: { settings.enabled },
                set: { model.setCertificatePhotoEnabled($0) })
    }

    private var backgroundSourceBinding: Binding<CertificateBackgroundSource> {
        Binding(get: { settings.backgroundSource },
                set: { source in model.updateCertificatePhoto { $0.backgroundSource = source } })
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(red: settings.customBackground.red,
                      green: settings.customBackground.green,
                      blue: settings.customBackground.blue)
            },
            set: { color in
                guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
                model.updateCertificatePhoto {
                    $0.customBackground = SRGBColor(red: Double(converted.redComponent),
                                                    green: Double(converted.greenComponent),
                                                    blue: Double(converted.blueComponent))
                }
            })
    }

    private var sizeBinding: Binding<IDPhotoSize?> {
        Binding(get: { settings.size },
                set: { size in model.updateCertificatePhoto { $0.size = size } })
    }

    private var dpiBinding: Binding<Double> {
        Binding(get: { settings.crop.dpi },
                set: { dpi in model.updateCertificatePhoto { $0.crop.dpi = dpi } })
    }

    private var headHeightBinding: Binding<Double> {
        Binding(get: { settings.crop.headHeightRatio },
                set: { value in model.updateCertificatePhoto { $0.crop.headHeightRatio = value } })
    }

    private var headTopMarginBinding: Binding<Double> {
        Binding(get: { settings.crop.headTopMarginRatio },
                set: { value in model.updateCertificatePhoto { $0.crop.headTopMarginRatio = value } })
    }

    private var horizontalOffsetBinding: Binding<Double> {
        Binding(get: { settings.crop.horizontalOffset },
                set: { value in model.updateCertificatePhoto { $0.crop.horizontalOffset = value } })
    }

    private var faceInflateBinding: Binding<Double> {
        Binding(get: { settings.crop.faceInflate },
                set: { value in model.updateCertificatePhoto { $0.crop.faceInflate = value } })
    }

    private var shadowEnabledBinding: Binding<Bool> {
        Binding(get: { settings.shadow.shadowEnabled },
                set: { value in model.updateCertificatePhoto { $0.shadow.shadowEnabled = value } })
    }

    private var shadowOpacityBinding: Binding<Double> {
        Binding(get: { settings.shadow.shadowOpacity },
                set: { value in model.updateCertificatePhoto { $0.shadow.shadowOpacity = value } })
    }

    private var shadowBlurBinding: Binding<Double> {
        Binding(get: { settings.shadow.shadowBlur },
                set: { value in model.updateCertificatePhoto { $0.shadow.shadowBlur = value } })
    }

    private var shadowOffsetXBinding: Binding<Double> {
        Binding(get: { settings.shadow.shadowOffsetX },
                set: { value in model.updateCertificatePhoto { $0.shadow.shadowOffsetX = value } })
    }

    private var shadowOffsetYBinding: Binding<Double> {
        Binding(get: { settings.shadow.shadowOffsetY },
                set: { value in model.updateCertificatePhoto { $0.shadow.shadowOffsetY = value } })
    }

    private var edgeDecontaminationBinding: Binding<Double> {
        Binding(get: { settings.shadow.edgeDecontamination },
                set: { value in model.updateCertificatePhoto { $0.shadow.edgeDecontamination = value } })
    }

    private var paperBinding: Binding<PrintPaper> {
        Binding(get: { settings.print.paper },
                set: { value in model.updateCertificatePhoto { $0.print.paper = value } })
    }

    private var printPhotoSizeBinding: Binding<IDPhotoSize> {
        Binding(get: { settings.print.photoSize },
                set: { value in model.updateCertificatePhoto { $0.print.photoSize = value } })
    }

    private var spacingBinding: Binding<Double> {
        Binding(get: { settings.print.spacingMM },
                set: { value in model.updateCertificatePhoto { $0.print.spacingMM = value } })
    }

    private var marginBinding: Binding<Double> {
        Binding(get: { settings.print.marginMM },
                set: { value in model.updateCertificatePhoto { $0.print.marginMM = value } })
    }

    private var pixelLabel: String {
        let size = settings.size ?? settings.print.photoSize
        let pixels = IDPhotoLayout.pixelSize(for: size, dpi: settings.crop.dpi)
        return "\(Int(pixels.width))×\(Int(pixels.height)) px"
    }

    // MARK: - Studio Backdrop Refinement (P2-D)

    private var backdropSection: some View {
        Group {
            panelHeading("影棚纯色背景修复")
            Toggle("启用影棚背景修复", isOn: backdropEnabledBinding)
                .toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 10))
            AdjustmentSlider(title: "背景平整", value: backdropSmoothingBinding, range: 0...1, percent: true)
                .help("平滑无缝背景纸折痕、幕布褶皱、接缝与不均光影，保护主体与地面自然阴影。")
            AdjustmentSlider(title: "瑕疵去污", value: backdropCleanupBinding, range: 0...1, percent: true)
                .help("自动识别并消除背景纸上的脚印、灰尘点、胶带印与污渍。")
            AdjustmentSlider(title: "色调统一", value: backdropUniformityBinding, range: 0...1, percent: true)
                .help("消除背景杂色偏色，使纯色幕布色相均匀一致。")
        }
        .disabled(!canEdit)
        .opacity(canEdit ? 1 : 0.5)
    }

    private var backdropEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.backdropSettings.enabled },
            set: { model.setBackdropEnabled($0) }
        )
    }

    private var backdropSmoothingBinding: Binding<Double> {
        Binding(
            get: { model.backdropSettings.smoothing },
            set: { v in model.updateBackdrop { $0.smoothing = v } }
        )
    }

    private var backdropCleanupBinding: Binding<Double> {
        Binding(
            get: { model.backdropSettings.cleanup },
            set: { v in model.updateBackdrop { $0.cleanup = v } }
        )
    }

    private var backdropUniformityBinding: Binding<Double> {
        Binding(
            get: { model.backdropSettings.uniformity },
            set: { v in model.updateBackdrop { $0.uniformity = v } }
        )
    }
}

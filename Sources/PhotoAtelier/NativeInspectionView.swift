import SwiftUI
import PhotoCore

struct NativeInspectionView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: NativeInspectionController
    @Environment(\.displayScale) private var displayScale
    @State private var split = 0.5

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("原尺寸局部检查", systemImage: "viewfinder").font(.headline)
                Spacer()
                if controller.busy { ProgressView().controlSize(.small) }
                Button("重新检查") { model.refreshNativeInspection(immediate: true, force: true) }
                    .disabled(model.batchRunning || model.scanning)
                Button("返回调整") { model.closeNativeInspection() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("在导航图中点击要检查的位置。1 个图像像素对应 1 个屏幕物理像素，可滚动查看；拖动下方对比滑杆检查完整效果。")
                        .font(.system(size: 11)).foregroundColor(AtelierPalette.muted)
                    HStack(spacing: 20) {
                        navigator.frame(width: 250, height: 140)
                        VStack(alignment: .leading, spacing: 9) {
                            Picker("检查边长", selection: Binding(get: { model.nativeInspectionRegion.pixelSize },
                                set: { model.updateNativeInspection(pixelSize: $0) })) {
                                Text("512 px").tag(512); Text("768 px").tag(768); Text("1024 px").tag(1024)
                            }.frame(width: 230)
                            if let frame = controller.frame {
                                let r = frame.image
                                Text("原尺寸 \(Int(r.outputExtent.width)) × \(Int(r.outputExtent.height)) · 区域 \(r.after.width) × \(r.after.height) px")
                                Text(frame.automatic ? "已按批处理配方重新分析并求值；普通缩图预览可能不同。" : "采用当前手动参数，按原尺寸重新测量细节。")
                                Text(String(format: "本次检查 %.2f 秒 · %@", frame.seconds, model.exportSettings.colorSpace.title))
                                Text(String(format: "实际曝光 %+.2f EV · 色温偏移 %+.0f · Tint %+.0f\n对比 %.2f · 饱和 %.2f",
                                    r.report.appliedExposureEV, frame.resolvedSettings.temperature, frame.resolvedSettings.tint,
                                    frame.resolvedSettings.contrast, frame.resolvedSettings.saturation))
                            } else {
                                Text(controller.busy ? "正在按原尺寸处理，完成后显示本图实际参数…" : "检查结果已清除。")
                            }
                        }.font(.system(size: 10)).foregroundColor(AtelierPalette.muted)
                    }
                    adaptationStrengthControls
                    comparison.frame(height: 330).background(Color.black.opacity(0.25))
                    HStack {
                        Text("基础调整后（无局部 / LUT / 滤镜）")
                        Slider(value: $split, in: 0...1).frame(maxWidth: 350)
                        Text("当前完整效果")
                    }.font(.system(size: 10)).disabled(controller.frame == nil)
                    if let error = controller.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11))
                            .foregroundColor(.orange).textSelection(.enabled)
                    }
                    if let frame = controller.frame {
                        nativePlans(frame)
                    }
                    Text("检查显示色彩管理后的 8 位屏幕图像，不包含 JPEG 压缩或导出位深的编码差异。原尺寸分析不改变你的手动参数；检查完成不代表人工审美验收。")
                        .font(.system(size: 10)).foregroundColor(AtelierPalette.muted)
                }.padding(20)
            }
        }.frame(width: 900, height: 780)
            .background(AtelierPalette.panel).preferredColorScheme(.dark)
    }

    @ViewBuilder private var adaptationStrengthControls: some View {
        if let mask = model.selectedLocalMask, mask.detailAdaptation != nil {
            HStack {
                Text("\(mask.name) · 适配强度").font(.system(size: 10))
                Slider(value: Binding(get: {
                    model.selectedLocalMask?.detailAdaptation?.strength ?? 0
                }, set: { amount in
                    guard let index = model.activeMaskIndex else { return }
                    model.adjustments.masks[index].detailAdaptation?.strength = amount
                }), in: 0...1)
                Text(String(format: "%.0f%%", (model.selectedLocalMask?.detailAdaptation?.strength ?? 0) * 100))
                    .font(.system(size: 10, design: .monospaced)).frame(width: 36)
            }.disabled(model.batchRunning)
        }
    }

    private var navigator: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.2)
                if let frame = controller.frame {
                    let cg = frame.image.overview
                    let scale = min(geo.size.width / CGFloat(cg.width), geo.size.height / CGFloat(cg.height))
                    let size = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
                    let origin = CGPoint(x: (geo.size.width - size.width) / 2, y: (geo.size.height - size.height) / 2)
                    let extent = frame.image.outputExtent, bounds = frame.image.sampleBounds
                    Image(decorative: cg, scale: 1).resizable().frame(width: size.width, height: size.height)
                        .overlay(alignment: .topLeading) {
                            Rectangle().stroke(AtelierPalette.accent, lineWidth: 1)
                                .frame(width: bounds.width / extent.width * size.width,
                                       height: bounds.height / extent.height * size.height)
                                .offset(x: (bounds.minX - extent.minX) / extent.width * size.width,
                                        y: (extent.maxY - bounds.maxY) / extent.height * size.height)
                        }
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onEnded { event in
                        let rect = CGRect(origin: origin, size: size)
                        guard rect.contains(event.location) else { return }
                        model.updateNativeInspection(center: .init(
                            x: Double((event.location.x - origin.x) / size.width),
                            y: Double((event.location.y - origin.y) / size.height)))
                    })
                } else {
                    Text("原尺寸导航图").font(.system(size: 10)).foregroundColor(AtelierPalette.muted)
                }
            }
        }
    }

    private var comparison: some View {
        ScrollView([.horizontal, .vertical]) {
            if let frame = controller.frame {
                let result = frame.image
                let scale = max(1, displayScale)
                let width = CGFloat(result.after.width) / scale, height = CGFloat(result.after.height) / scale
                ZStack(alignment: .leading) {
                    Image(decorative: result.after, scale: scale).resizable().interpolation(.none)
                        .frame(width: width, height: height)
                    Image(decorative: result.before, scale: scale).resizable().interpolation(.none)
                        .frame(width: width, height: height)
                        .mask(alignment: .leading) { Rectangle().frame(width: width * split) }
                    Rectangle().fill(.white.opacity(0.85)).frame(width: 1 / scale, height: height)
                        .offset(x: width * split)
                }.frame(width: width, height: height).padding(8)
            } else {
                VStack(spacing: 12) {
                    if controller.busy { ProgressView() }
                    Text(controller.busy ? "正在原尺寸测量与渲染…" : "等待原尺寸检查")
                }.frame(width: 800, height: 310).font(.system(size: 11)).foregroundColor(AtelierPalette.muted)
            }
        }
    }

    private func nativePlans(_ frame: NativeInspectionFrame) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("原尺寸实际细节参数").font(.system(size: 12, weight: .medium))
            ForEach(frame.image.report.localDetails ?? [], id: \.maskID) { plan in
                VStack(alignment: .leading, spacing: 5) {
                    Text((model.adjustments.masks.first { $0.id == plan.maskID }?.name ?? "局部") + " · " + plan.resolvedIntent.title)
                        .foregroundColor(AtelierPalette.accent)
                    Text(String(format: "平整 %.1f%% · 纹理保留 %.1f%% · 色调均匀 %.1f%% · 降噪 %.1f%% · 纹理增强 %.1f%%",
                        plan.settings.smoothing * 100, plan.settings.textureRetention * 100,
                        plan.settings.toneUniformity * 100, plan.settings.noiseReduction * 100,
                        plan.settings.detailRecovery * 100))
                    DisclosureGroup("测量依据与边界") {
                        Text((plan.evidence + plan.warnings).joined(separator: "\n")).lineSpacing(4)
                    }.foregroundColor(AtelierPalette.muted)
                }.font(.system(size: 10))
            }
            if frame.image.report.localDetails?.isEmpty ?? true {
                Text("当前配方未启用逐图细节适配。").font(.system(size: 10)).foregroundColor(AtelierPalette.muted)
            }
        }
    }
}

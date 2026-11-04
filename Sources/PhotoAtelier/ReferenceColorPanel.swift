import PhotoCore
import SwiftUI

/// Right-inspector “追色” tab for the v1 reference-color match ("AI 追色").
///
/// The copy is deliberately explicit: this is a global OKLab distribution match
/// measured from a reference photo, not semantic segmentation, not an object
/// transfer and not a guarantee of a commercial-grade aesthetic result. The
/// reference photo is measured locally; the recipe stores only the profile data.
/// A zero strength is a neutral no-op and the preview keeps the existing token
/// mechanism, so dragging the slider never blocks the main thread.
struct ReferenceColorPanel: View {
    @ObservedObject var model: AppModel

    private var settings: ReferenceColorSettings? { model.adjustments.referenceColor }
    private var canEdit: Bool { settings != nil && !model.batchRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("参考图追色（AI 追色）", systemImage: "paintpalette")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .padding(.bottom, 10)
            Text("从一张参考图测量 OKLab 明度与色度分位数，再把当前照片的分布单调映射过去。这是全局色彩分布匹配，不是语义分割、不迁移物体或构图，也不保证审美效果；输出会夹取到 SDR 显示范围。合成测试只验证分布收敛与恒等性质，未做真实照片审美验收。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 13)
            referenceCard
            HStack(spacing: 8) {
                Button("导入参考图…") { model.chooseReferenceColorImage() }
                    .font(.system(size: 10))
                    .buttonStyle(.bordered)
                    .disabled(model.batchRunning || model.referenceColorBusy)
                Button("清除") { model.clearReferenceColor() }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundColor(settings == nil ? AtelierPalette.muted : AtelierPalette.accent)
                    .disabled(model.batchRunning || settings == nil)
                Spacer(minLength: 0)
            }.padding(.top, 12)

            VStack(alignment: .leading, spacing: 0) {
                AdjustmentSlider(title: "追色强度",
                                 value: Binding(get: { settings?.strength ?? 0 },
                                                set: { model.setReferenceColorStrength($0) }),
                                 range: 0...1, percent: true)
                Toggle("仅人像皮肤区域", isOn: Binding(
                    get: { settings?.skinOnly ?? false },
                    set: { model.setReferenceColorSkinOnly($0) }))
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 11)).padding(.bottom, 13)
                    .help("开启后只对检测到的皮肤区域应用追色；未检测到可用人脸/皮肤蒙版时整段跳过并在清单记录原因，不会偷偷改成全图追色。")
            }
            .padding(.top, 16)
            .disabled(!canEdit)
            .opacity(canEdit ? 1 : 0.45)

            separator
            Text("限制：分位数映射是全局统计近似，大图按有界降采样测量；强中性图会被中性/肤色保护减弱；高光超出 SDR 显示范围的部分在此阶段被夹取。参考图只在本地测量，不上传、不写入配方图片。用工具栏「前后对比」查看差异，强度 0 即恢复原样。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var referenceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.referenceColorBusy {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("正在本机测量参考图色彩分布…")
                        .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                }
            } else if let settings {
                HStack(alignment: .top, spacing: 9) {
                    if model.referenceColorThumbnailMatchesProfile,
                       let thumbnail = model.referenceColorThumbnail {
                        Image(nsImage: thumbnail)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.25))
                            .frame(width: 54, height: 54)
                            .overlay(Image(systemName: "photo")
                                .font(.system(size: 15)).foregroundColor(AtelierPalette.muted))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.referenceColorSourceName ?? "配方内 profile")
                            .font(.system(size: 10)).foregroundColor(.white.opacity(0.85))
                            .lineLimit(1)
                        Text("profile v\(settings.profile.algorithmVersion) · 采样 \(settings.profile.sampleCount) 像素 · 强度 \(Int((settings.strength * 100).rounded()))%")
                            .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                        if settings.skinOnly {
                            Text("仅皮肤区域应用；无可用人脸时显式跳过并在报告中记录。")
                                .font(.system(size: 9)).foregroundColor(.orange.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10)).foregroundColor(.orange.opacity(0.9))
                    Text("未导入参考图：导入后会在此显示缩略图与 profile 信息；未导入时不改变任何像素。")
                        .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var separator: some View {
        Rectangle().fill(AtelierPalette.line).frame(height: 1).padding(.vertical, 14)
    }
}

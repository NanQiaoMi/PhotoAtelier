import SwiftUI
import AppKit
import PhotoCore

struct TetheredWatchSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(alignment: .center) {
                HStack(spacing: 10) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(AtelierPalette.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("联机拍摄热文件夹监视")
                            .font(.system(size: 16, weight: .semibold))
                        Text("摄影棚联机实时导入 · 自动应用当前配方调色 · 即刻全屏预览")
                            .font(.system(size: 11))
                            .foregroundColor(AtelierPalette.muted)
                    }
                }
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Divider().background(AtelierPalette.line)

            // Status Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("监视状态")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    statusIndicator
                }

                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundColor(AtelierPalette.muted)
                        .font(.system(size: 12))
                    if let folder = model.tetheredConfig.folderURL {
                        Text(folder.path)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    } else {
                        Text("尚未选择热文件夹")
                            .font(.system(size: 11))
                            .foregroundColor(AtelierPalette.muted)
                    }
                    Spacer()
                    Button("选择文件夹…") {
                        model.chooseTetheredFolder()
                    }
                    .font(.system(size: 11))

                    if let folder = model.tetheredConfig.folderURL, FileManager.default.fileExists(atPath: folder.path) {
                        Button("在访达中显示") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                        }
                        .font(.system(size: 11))
                    }
                }
            }
            .padding(12)
            .background(Color.black.opacity(0.2))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AtelierPalette.line, lineWidth: 1))

            // Settings
            VStack(alignment: .leading, spacing: 12) {
                Text("联机配置")
                    .font(.system(size: 12, weight: .medium))

                Toggle(isOn: $model.tetheredConfig.autoSelectLatest) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("拍摄新照片后自动选中并全屏呈现")
                            .font(.system(size: 12))
                        Text("快门按下后即时渲染当前画质与调色配方，方便摄影师与客户在大屏即时审片。")
                            .font(.system(size: 10.5))
                            .foregroundColor(AtelierPalette.muted)
                    }
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: $model.tetheredConfig.includeSubfolders) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("监视子文件夹")
                            .font(.system(size: 12))
                        Text("支持按拍摄日期或卡槽在热文件夹中自动建立子目录的相机联机软件。")
                            .font(.system(size: 10.5))
                            .foregroundColor(AtelierPalette.muted)
                    }
                }
                .toggleStyle(.checkbox)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("文件写入平稳延时")
                            .font(.system(size: 12))
                        Spacer()
                        Text(String(format: "%.1f 秒", model.tetheredConfig.fileStabilityDelay))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AtelierPalette.accent)
                    }
                    Slider(value: $model.tetheredConfig.fileStabilityDelay, in: 0.2...2.0, step: 0.1)
                    Text("相机联机工具写入高像素 RAW 文件时，保证文件尺寸完全稳定后再读取，避免损坏。")
                        .font(.system(size: 10.5))
                        .foregroundColor(AtelierPalette.muted)
                }
            }
            .padding(12)
            .background(Color.black.opacity(0.15))
            .cornerRadius(8)

            // Workflow Guide
            DisclosureGroup("联机拍摄工作流设置指引") {
                VStack(alignment: .leading, spacing: 6) {
                    guideRow(number: "1", title: "配置相机联机工具", text: "在 Sony Imaging Edge / Canon EOS Utility / Capture One / Nikon NX 中，将照片保存目录指定为本机某个固定文件夹。")
                    guideRow(number: "2", title: "启动热文件夹监视", text: "在本面板选择该文件夹并点击「开始监视」。")
                    guideRow(number: "3", title: "边拍边调实时监看", text: "按下快门后数秒内，照片将自动追加至左侧胶卷并加载当前色彩风格与精修配方。")
                }
                .padding(.top, 6)
            }
            .font(.system(size: 11))
            .foregroundColor(AtelierPalette.muted)

            Spacer()

            // Control Actions
            HStack(spacing: 12) {
                if model.tetheredState.isWatching {
                    Button("停止监视") {
                        model.stopTetheredWatch()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 12))

                    Button("立即扫描") {
                        model.triggerTetheredScan()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 12))
                } else {
                    Button {
                        model.startTetheredWatch()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("开始监视")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .foregroundColor(AtelierPalette.background)
                        .background(model.tetheredConfig.folderURL == nil ? Color.gray : AtelierPalette.accent)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.tetheredConfig.folderURL == nil)
                }

                Spacer()

                Button("关闭") {
                    dismiss()
                }
                .font(.system(size: 12))
            }
        }
        .padding(20)
        .frame(minWidth: 520, maxWidth: 580, minHeight: 460)
        .background(AtelierPalette.background)
    }

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(statusColor)
        }
    }

    private var statusColor: Color {
        switch model.tetheredState {
        case .watching: return .green
        case .paused: return .yellow
        case .error: return .red
        case .idle: return AtelierPalette.muted
        }
    }

    private var statusText: String {
        switch model.tetheredState {
        case .watching: return "正在监视"
        case .paused: return "监视已暂停"
        case .error(let msg): return "错误：\(msg)"
        case .idle: return "未监视"
        }
    }

    private func guideRow(number: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(AtelierPalette.accent)
                .frame(width: 14, height: 14)
                .background(AtelierPalette.accent.opacity(0.15))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.9))
                Text(text).font(.system(size: 10.5)).foregroundColor(AtelierPalette.muted).lineSpacing(3)
            }
        }
    }
}

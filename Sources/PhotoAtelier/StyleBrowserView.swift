import SwiftUI
import PhotoCore

struct StyleBrowserView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var previews: StylePreviewController
    var managesRequests = true
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var category = "all"
    private var matches: [LUTOption] {
        model.lutOptions.filter { option in
            (category == "all" || (category == "custom" ? option.path != nil : option.group?.rawValue == category))
                && (search.isEmpty || ([option.name, option.detail] + option.tags)
                    .joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }
    private var visible: [LUTOption] { Array(matches.prefix(48)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("照片风格库").font(.title2.weight(.semibold))
                    Text("缩图基于当前基础调整；局部蒙版请在主预览确认，纹理请用原尺寸检查。")
                        .font(.caption).foregroundColor(AtelierPalette.muted)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack {
                TextField("搜索风格、颜色或标签", text: $search).textFieldStyle(.roundedBorder).frame(width: 245)
                Picker("分类", selection: $category) {
                    Text("全部").tag("all")
                    ForEach(LUTPresetGroup.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    Text("自定义").tag("custom")
                }.labelsHidden().frame(width: 150)
                Spacer()
                if previews.busy {
                    ProgressView().controlSize(.small)
                    Text("\(previews.completed)/\(previews.total)").font(.caption.monospacedDigit())
                }
                Button("导入 LUT…") { model.importLUT() }.disabled(model.batchRunning || model.lutLibraryBusy)
            }
            HStack(spacing: 15) {
                Text("\(model.selectedOption?.name ?? "原色")").font(.caption.weight(.semibold))
                    .foregroundColor(AtelierPalette.accent)
                Slider(value: $model.adjustments.lutIntensity, in: 0...1).frame(width: 160).disabled(model.selectedLUT == "none")
                Text("强度 \(Int((model.adjustments.lutIntensity * 100).rounded()))%").font(.caption.monospacedDigit())
                if let recommended = model.selectedOption?.recommendedIntensity {
                    Button("采用推荐 \(Int((recommended * 100).rounded()))%") { model.adoptRecommendedLUTIntensity() }
                        .font(.caption)
                }
                Spacer()
                Text("切换风格保留你的强度").font(.caption2).foregroundColor(AtelierPalette.muted)
            }.disabled(model.batchRunning)
            DisclosureGroup("理光风格与网络 LUT 来源") {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("ColorReps：理光 GR 风格，非理光官方")
                        HStack {
                            Link("Positive Film", destination: URL(string: "https://colorreps.com/lut/ricoh-gr-positive-film")!)
                            Link("Negative Film", destination: URL(string: "https://colorreps.com/lut/ricoh-gr-negative-film")!)
                            Link("Standard", destination: URL(string: "https://colorreps.com/lut/ricoh-gr-standard")!)
                        }
                    }
                    Text("从作者页面下载 .cube 后导入。作者未明确输入曲线与再分发许可，因此不随应用内置；请核实用途与空间，Log / ACES 表不能直接使用。")
                        .foregroundColor(AtelierPalette.muted)
                }.font(.caption2).padding(.top, 6)
            }.font(.caption)
            Group {
            if model.lutLibraryBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.lutImportTotal > 0 ? "后台导入 \(model.lutImportCompleted)/\(model.lutImportTotal)" : "读取自定义资料库…")
                    if model.lutImportTotal > 0 { Button("停止导入") { model.cancelLUTImport() } }
                }.font(.caption)
            }
            if let error = previews.error { Text(error).font(.caption).foregroundColor(.orange) }
            if previews.error != nil || !previews.cardErrors.isEmpty {
                Button("重试缩图") { previews.cancel(); refresh() }.font(.caption)
            }
            if model.previewBusy {
                Text("主预览正在更新；缩图会在基础调整完成后刷新。")
                    .font(.caption2).foregroundColor(AtelierPalette.muted)
            }
            if let message = model.lutLibraryMessages.first {
                Text(message + (model.lutLibraryMessages.count > 1 ? "；另有 \(model.lutLibraryMessages.count - 1) 项失败" : ""))
                    .font(.caption).foregroundColor(.orange).lineLimit(3)
            }
            }
            if model.styleReference == nil {
                Spacer(); Text("先打开照片，完成基础预览后即可比较风格。")
                    .foregroundColor(AtelierPalette.muted).frame(maxWidth: .infinity); Spacer()
            } else if visible.isEmpty {
                Spacer(); Text("没有匹配的风格").frame(maxWidth: .infinity); Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 174), spacing: 12)], spacing: 16) {
                        ForEach(visible) { option in
                            Button { model.selectLUT(option.id) } label: { card(option) }
                                .buttonStyle(.plain).disabled(model.batchRunning)
                        }
                    }.padding(3)
                }
            }
            HStack {
                Text("\(matches.count) 种风格\(matches.count > 48 ? " · 当前显示前 48 种，可搜索缩小范围" : "")")
                Spacer()
                Text("原创与署名胶片近似 · 自定义 LUT 请确认色彩空间")
            }.font(.caption2).foregroundColor(AtelierPalette.muted)
        }
        .padding(24).frame(width: 920, height: 700).background(AtelierPalette.background)
        .onAppear { refresh() }
        .onDisappear { if managesRequests { previews.cancel() } }
        .onChange(of: visible.map(\.id)) { _ in refresh() }
        .onChange(of: model.styleReference) { _ in refresh() }
        .onChange(of: model.adjustments) { _ in refresh() }
        .onChange(of: model.previewBusy) { _ in refresh() }
        .onChange(of: model.exportSettings.colorSpace) { _ in refresh() }
    }

    private func refresh() {
        guard managesRequests else { return }
        guard !model.previewBusy else { return }
        previews.request(source: model.styleReference, options: visible, adjustments: model.adjustments,
                         outputSpace: model.exportSettings.colorSpace, colorContracts: model.lutColorContracts)
    }

    private func card(_ option: LUTOption) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(AtelierPalette.raised)
                if let image = previews.images[option.id] {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if let error = previews.cardErrors[option.id] ?? previews.error {
                    VStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("无法生成缩图").font(.caption)
                    }.foregroundColor(.orange).frame(maxWidth: .infinity, maxHeight: .infinity).help(error)
                } else if previews.busy {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: "photo").foregroundColor(AtelierPalette.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if model.selectedLUT == option.id {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(AtelierPalette.accent)
                        .padding(8).background(Color.black.opacity(0.35)).clipShape(Circle()).padding(4)
                }
            }.frame(height: 128).clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(model.selectedLUT == option.id ? AtelierPalette.accent : .clear, lineWidth: 2))
            Text(option.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(option.detail).font(.system(size: 10)).foregroundColor(AtelierPalette.muted).lineLimit(2)
                .frame(height: 28, alignment: .topLeading)
        }.frame(maxWidth: .infinity, alignment: .leading).help(option.detail)
    }
}

import AppKit
import SwiftUI
import PhotoCore
import UniformTypeIdentifiers

enum AtelierPalette {
    static let background = Color(red: 0.062, green: 0.075, blue: 0.09)
    static let panel = Color(red: 0.092, green: 0.108, blue: 0.126)
    static let raised = Color(red: 0.135, green: 0.153, blue: 0.174)
    static let muted = Color(red: 0.55, green: 0.60, blue: 0.65)
    static let accent = Color(red: 0.78, green: 0.88, blue: 0.58)
    static let line = Color.white.opacity(0.07)
}

private struct InspectorTab: Identifiable {
    let id: Int
    let title: String
    let icon: String
}

/// Two-row (4x2) inspector tab grid. Replaces the 8-segment segmented Picker,
/// whose intrinsic width (336pt) overflowed the 312pt inspector and clipped the
/// last tab ("证件照") at the window edge.
private struct InspectorTabBar: View {
    @Binding var selection: Int
    private static let tabs: [InspectorTab] = [
        .init(id: 0, title: "分析", icon: "chart.bar.xaxis"),
        .init(id: 1, title: "基础", icon: "slider.horizontal.3"),
        .init(id: 2, title: "局部", icon: "circle.dashed"),
        .init(id: 3, title: "人像", icon: "person.crop.circle"),
        .init(id: 4, title: "追色", icon: "eyedropper.halffull"),
        .init(id: 5, title: "导出", icon: "square.and.arrow.up"),
        .init(id: 6, title: "调色", icon: "circle.lefthalf.filled"),
        .init(id: 7, title: "证件照", icon: "person.text.rectangle")
    ]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Self.tabs) { tab in
                let isSelected = selection == tab.id
                Button { selection = tab.id } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon).font(.system(size: 10, weight: .medium))
                        Text(tab.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .foregroundColor(isSelected ? AtelierPalette.accent : AtelierPalette.muted)
                    .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? AtelierPalette.accent.opacity(0.16) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? AtelierPalette.accent.opacity(0.55) : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .disabled(false)
            }
        }
    }
}

private struct HistoryPopoverView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("编辑历史记录", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Text("\(model.historyEntries.count) 步")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(AtelierPalette.muted)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            Divider().background(AtelierPalette.line)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.historyEntries.enumerated().reversed()), id: \.offset) { index, entry in
                        let isCurrent = index == model.currentHistoryIndex
                        Button {
                            model.jumpToHistory(at: index)
                            isPresented = false
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(isCurrent ? AtelierPalette.accent : Color.clear)
                                    .frame(width: 5, height: 5)
                                Text("#\(index)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(AtelierPalette.muted)
                                Text(entry.title)
                                    .font(.system(size: 10.5, weight: isCurrent ? .semibold : .regular))
                                    .foregroundColor(isCurrent ? AtelierPalette.accent : .white.opacity(0.85))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(Self.timeFormatter.string(from: entry.timestamp))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundColor(AtelierPalette.muted)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(isCurrent ? AtelierPalette.accent.opacity(0.12) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 260)

            Divider().background(AtelierPalette.line)

            Text("点击任意步骤可直接跳转状态 · 原片完全不变")
                .font(.system(size: 8.5))
                .foregroundColor(AtelierPalette.muted)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
        .frame(width: 250)
        .background(AtelierPalette.panel)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var inspectorTab = 0
    @State private var compare = true
    @State private var split = 0.5
    @State private var showLog = false
    @State private var showLensPicker = false
    @State private var dropTargeted = false
    @State private var showHistoryPopover = false
    /// Test/verification hook: `--initial-tab <0...7>` opens the inspector on a
    /// specific tab so layout screenshots do not depend on accessibility clicks.
    private static var defaultInspectorTab: Int {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--initial-tab"), args.count > index + 1,
           let value = Int(args[index + 1]) {
            return min(max(value, 0), 7)
        }
        return 0
    }

    init(model: AppModel, initialTab: Int = ContentView.defaultInspectorTab, initialCompare: Bool = true) {
        self.model = model
        self._inspectorTab = State(initialValue: initialTab)
        self._compare = State(initialValue: initialCompare)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(AtelierPalette.line).frame(height: 1)
            HStack(spacing: 0) {
                library.frame(width: 222)
                Rectangle().fill(AtelierPalette.line).frame(width: 1)
                VStack(spacing: 0) {
                    previewToolbar
                    PhotoCanvas(model: model, compare: compare, split: $split)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if inspectorTab == 0 { AnalysisProposalShelf(model: model) }
                    else { presetShelf }
                    batchBar
                }.frame(maxWidth: .infinity)
                Rectangle().fill(AtelierPalette.line).frame(width: 1)
                inspector.frame(width: 312)
            }
            footer
        }
        .background(AtelierPalette.background)
        .tint(AtelierPalette.accent)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
            importDroppedProviders(providers)
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AtelierPalette.accent, style: StrokeStyle(lineWidth: 2, dash: [9, 6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: model.adjustments) { _ in
            // One drag = one commit at stroke end; dragging never re-renders.
            if !model.liquifyStrokeInProgress && !model.repairStrokeInProgress {
                model.requestPreview()
            }
        }
        .onChange(of: model.selectedLUT) { _ in model.requestPreview() }
        .onChange(of: model.exportSettings.recursive) { _ in model.reloadFolder() }
        .onChange(of: model.exportSettings.colorSpace) { _ in model.requestPreview() }
        .onChange(of: model.selectedMask) { _ in model.maskSelectionChanged() }
        .onChange(of: model.showMaskCoverage) { showing in
            if showing { compare = false }
            model.requestPreview()
        }
        .onChange(of: model.maskInteractionActive) { active in if active { compare = false } }
        .onChange(of: model.liquifyBrushActive) { active in
            if active { compare = false; model.cancelMaskInteraction() }
        }
        .onChange(of: model.repairBrushActive) { active in
            if active { compare = false; model.cancelMaskInteraction() }
        }
        .onChange(of: model.maskDrawMode) { _ in model.drawingMask = false; model.maskEditMode = false }
        .onChange(of: model.maskKind) { kind in
            if kind == .luminance || kind == .color { model.drawingMask = false }
        }
        .onChange(of: inspectorTab) { tab in
            if tab != 2 { model.cancelMaskInteraction(); model.showMaskCoverage = false }
            if tab != 3 {
                model.cancelLiquifyStroke()
                model.liquifyBrushActive = false
                model.cancelRepairStroke()
                model.repairBrushActive = false
            }
            if tab == 3 { model.requestPortraitDetection(force: false) }
        }
        .onChange(of: model.selectedID) { _ in
            if inspectorTab == 3 { model.requestPortraitDetection(force: false) }
        }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: $showLog) { logSheet }
        .sheet(isPresented: $showLensPicker) { LensPicker(model: model) }
        .sheet(isPresented: $model.showStyleBrowser) { StyleBrowserView(model: model, previews: model.stylePreviews) }
        .sheet(isPresented: $model.showNativeInspection, onDismiss: {
            if !model.showNativeInspection { model.nativeInspection.cancel() }
        }) {
            NativeInspectionView(model: model, controller: model.nativeInspection)
        }
        .sheet(isPresented: $model.showTetheredSheet) {
            TetheredWatchSheet(model: model)
        }
        .sheet(isPresented: $model.showSelectiveSyncSheet) {
            SelectiveSyncSheet(model: model)
        }
        .alert("重命名虚拟副本", isPresented: $model.showRenameCopyAlert) {
            TextField("副本名称", text: $model.renameCopyNewName)
            Button("确定") {
                model.confirmRenameActiveVirtualCopy()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 28, weight: .light)).foregroundColor(AtelierPalette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("光屿").font(.system(size: 21, weight: .semibold, design: .serif))
                Text("PHOTO ATELIER").font(.system(size: 8, weight: .medium)).tracking(3).foregroundColor(AtelierPalette.muted)
            }
            Text("每一张，都恰到好处。")
                .font(.system(size: 12)).foregroundColor(AtelierPalette.muted).padding(.leading, 23)
            Spacer()
            toolButton("保存配方", icon: "square.and.arrow.down") { model.saveRecipe() }
            toolButton("载入配方", icon: "slider.horizontal.3") { model.loadRecipe() }.disabled(model.batchRunning)
            toolButton("风格库", icon: "square.grid.2x2") { model.showStyleBrowser = true }
            toolButton("导入 LUT", icon: "plus") { model.importLUT() }.disabled(model.batchRunning || model.lutLibraryBusy)
            Button {
                model.showTetheredSheet = true
            } label: {
                HStack(spacing: 5) {
                    if model.tetheredState.isWatching {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                    }
                    Image(systemName: "camera.viewfinder")
                    Text(model.tetheredState.isWatching ? "联机中" : "联机拍摄")
                }
                .font(.system(size: 11))
                .foregroundColor(model.tetheredState.isWatching ? AtelierPalette.accent : .white.opacity(0.65))
            }
            .buttonStyle(.plain)
            .help("摄影棚联机拍摄热文件夹实时监视与自动调色")
            Button(action: { model.chooseInput() }) {
                Label("打开照片", systemImage: "photo.on.rectangle").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .foregroundColor(AtelierPalette.background).background(AtelierPalette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).disabled(model.batchRunning)
                .help("打开单张/多张照片或文件夹；也可直接拖放到窗口")
        }
        .padding(.horizontal, 24).padding(.top, 17).padding(.bottom, 17)
        .background(AtelierPalette.panel)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionLabel("照片资料库")
                Spacer()
                Text(String(format: "%02d", model.photos.count)).font(.system(size: 11, design: .monospaced))
                    .foregroundColor(AtelierPalette.muted)
            }.padding(.horizontal, 18).padding(.top, 23)
            cullingControls
            if let root = model.inputRoot {
                HStack(spacing: 6) {
                    Label(root.lastPathComponent, systemImage: "folder.fill")
                        .font(.system(size: 12)).lineLimit(1).help(root.path)
                        .foregroundColor(.white.opacity(0.85))
                    if model.tetheredState.isWatching {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("联机").font(.system(size: 9, weight: .bold)).foregroundColor(.green)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 17)
            } else {
                HStack(spacing: 6) {
                    Text("尚未选择文件夹").font(.system(size: 11)).foregroundColor(AtelierPalette.muted)
                    if model.tetheredState.isWatching {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("联机中").font(.system(size: 9, weight: .bold)).foregroundColor(.green)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 17)
            }
            if !model.importIssues.isEmpty {
                Button { model.reviewImportIssues() } label: {
                    Label("\(model.importIssues.count) 个项目未导入", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10)).foregroundColor(.orange.opacity(0.9))
                }.buttonStyle(.plain).padding(.horizontal, 18).padding(.top, 9)
                    .help(model.importIssues.joined(separator: "\n"))
            }
            Toggle("包含子文件夹", isOn: $model.exportSettings.recursive)
                .font(.system(size: 11)).toggleStyle(.checkbox).foregroundColor(AtelierPalette.muted)
                .disabled(model.batchRunning).padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 18)
            Rectangle().fill(AtelierPalette.line).frame(height: 1)
            if model.scanning {
                Spacer(); ProgressView().controlSize(.small).frame(maxWidth: .infinity); Spacer()
            } else if model.photos.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: "photo.stack").font(.system(size: 28, weight: .ultraLight))
                    Text("让照片在这里相遇")
                        .font(.system(size: 12))
                    Text("JPEG · PNG · TIFF · HEIC · WebP\nAVIF · RAW · 也可拖入照片或文件夹")
                        .font(.system(size: 10)).multilineTextAlignment(.center).lineSpacing(5)
                }.foregroundColor(AtelierPalette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visiblePhotos.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 24, weight: .ultraLight))
                    Text("当前筛选「\(model.cullFilter.title)」下没有照片").font(.system(size: 11))
                    Button("显示全部照片") { model.setCullFilter(.all) }
                        .font(.system(size: 10)).buttonStyle(.plain).foregroundColor(AtelierPalette.accent)
                }.foregroundColor(AtelierPalette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(Array(model.visiblePhotos.enumerated()), id: \.element.id) { index, item in
                            photoRow(item, index: index)
                        }
                    }.padding(9)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("本机处理 · 原片保护", systemImage: "lock.shield")
                    .font(.system(size: 10, weight: .medium)).foregroundColor(AtelierPalette.accent.opacity(0.85))
                Text("自动方案逐张分析后处理。\n支持保留个人微调与局部蒙版。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(5)
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(Color.black.opacity(0.1))
        }.background(AtelierPalette.panel.opacity(0.5))
    }

    /// Sidebar culling filter + heuristic auto-cull trigger. Ratings/rejections
    /// are session-only state and never recipe data.
    private var cullingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("筛选", selection: Binding(get: { model.cullFilter },
                                             set: { model.setCullFilter($0) })) {
                ForEach(PhotoCullFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .help("按本地索引内的评级/废片/自动挑图建议筛选列表（不写配方，原片完全不变）")
            HStack(spacing: 8) {
                if model.autoCullBusy {
                    Button("取消自动挑图") { model.cancelAutoCull() }
                        .font(.system(size: 10)).buttonStyle(.plain)
                        .foregroundColor(AtelierPalette.accent)
                    ProgressView(value: model.autoCullProgress)
                        .progressViewStyle(.linear).frame(maxWidth: 84)
                } else {
                    Button("自动挑图") { model.runAutoCull() }
                        .font(.system(size: 10)).buttonStyle(.bordered)
                        .disabled(model.photos.isEmpty || model.scanning || model.batchRunning)
                        .help("启发式分析清晰度/曝光/闭眼并填入星级与废片建议；持久化至本地索引，原片完全不变。")
                }
                Spacer(minLength: 0)
            }
        }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 2)
    }

    /// Preview-toolbar rating controls (keyboard shortcuts Option+1–5 / Option+X,
    /// deliberately modified so plain digits/x still type into text fields).
    private var ratingControls: some View {
        HStack(spacing: 4) {
            Rectangle().fill(AtelierPalette.line).frame(width: 1, height: 12)
            if model.selectedIDs.count > 1 {
                Text("\(model.selectedIDs.count)项")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(AtelierPalette.accent)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(AtelierPalette.accent.opacity(0.15))
                    .clipShape(Capsule())

                Button {
                    model.showSelectiveSyncSheet = true
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("同步")
                    }
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(AtelierPalette.accent)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(AtelierPalette.accent.opacity(0.15))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("选择性同步当前调整参数至已选的 \(model.selectedIDs.count) 张照片 (Shift+Cmd+S)")
            }
            ForEach(1...5, id: \.self) { star in
                Button {
                    model.rateSelectedPhoto(star)
                } label: {
                    Image(systemName: (model.selectedPhoto?.rating ?? 0) >= star ? "star.fill" : "star")
                        .font(.system(size: 9))
                        .foregroundColor((model.selectedPhoto?.rating ?? 0) >= star
                                         ? .yellow.opacity(0.9) : AtelierPalette.muted)
                }.buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(star)")), modifiers: [.option])
                    .disabled(model.selectedPhoto == nil && model.selectedIDs.isEmpty)
                    .help("\(star) 星（快捷键 Option+\(star)；持久化至本地索引，原片完全不变）")
            }
            Button {
                model.toggleSelectedRejection()
            } label: {
                Image(systemName: model.selectedPhoto?.isRejected == true
                      ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: 9))
                    .foregroundColor(model.selectedPhoto?.isRejected == true
                                     ? .red.opacity(0.9) : AtelierPalette.muted)
            }.buttonStyle(.plain)
                .keyboardShortcut("x", modifiers: [.option])
                .disabled(model.selectedPhoto == nil && model.selectedIDs.isEmpty)
                .help("切换废片标记（快捷键 Option+X；持久化至本地索引，导出可跳过废片）")
        }
    }

    /// Sidebar row with culling badges: star rating, waste mark and the heuristic
    /// quality recommendation.
    private func photoRow(_ item: PhotoItem, index: Int) -> some View {
        let isPrimary = model.selectedID == item.id
        let isSelected = model.selectedIDs.contains(item.id) || isPrimary
        return Button {
            if NSEvent.modifierFlags.contains(.command) {
                model.togglePhotoSelection(item)
            } else {
                model.selectPhoto(item)
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.3))
                    if let image = model.thumbnails[item.id] {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: 47, height: 47).clipped()
                    } else {
                        Image(systemName: "photo").foregroundColor(AtelierPalette.muted)
                    }
                }.frame(width: 47, height: 47).clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(item.url.deletingPathExtension().lastPathComponent)
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        if item.isRejected {
                            Text("废片")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.red.opacity(0.95))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.red.opacity(0.16))
                                .clipShape(Capsule())
                        }
                    }
                    HStack(spacing: 5) {
                        Text(starsText(item.rating))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(item.rating > 0 ? .yellow.opacity(0.9)
                                             : AtelierPalette.muted.opacity(0.45))
                        if let recommendation = item.qualityRecommendation {
                            Text(recommendation.title)
                                .font(.system(size: 8))
                                .foregroundColor(Self.qualityBadgeColor(recommendation))
                        }
                        Text("\(String(format: "%02d", index + 1)) · \(item.url.pathExtension.uppercased())")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(AtelierPalette.muted)
                    }
                    if !item.virtualCopies.isEmpty {
                        HStack(spacing: 3) {
                            Button {
                                model.selectVirtualCopy(nil, for: item.id)
                            } label: {
                                Text("主")
                                    .font(.system(size: 8, weight: item.activeCopyID == nil ? .bold : .regular))
                                    .foregroundColor(item.activeCopyID == nil ? .white : AtelierPalette.muted)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(item.activeCopyID == nil ? AtelierPalette.accent.opacity(0.4) : AtelierPalette.raised)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }.buttonStyle(.plain)

                            ForEach(item.virtualCopies) { copy in
                                Button {
                                    model.selectVirtualCopy(copy.id, for: item.id)
                                } label: {
                                    Text(copy.name)
                                        .font(.system(size: 8, weight: item.activeCopyID == copy.id ? .bold : .regular))
                                        .foregroundColor(item.activeCopyID == copy.id ? .white : AtelierPalette.muted)
                                        .lineLimit(1)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(item.activeCopyID == copy.id ? Color.cyan.opacity(0.4) : AtelierPalette.raised)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                if isPrimary {
                    Circle().fill(AtelierPalette.accent).frame(width: 5, height: 5)
                } else if isSelected {
                    Circle().strokeBorder(AtelierPalette.accent, lineWidth: 1.5).frame(width: 5, height: 5)
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? AtelierPalette.raised : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).onAppear { model.loadThumbnail(item) }
        .contextMenu {
            Button("新建虚拟副本 (⌘N)") {
                model.createVirtualCopy(for: item.id)
            }
            if !item.virtualCopies.isEmpty {
                Menu("切换版本 (\(item.activeCopy?.name ?? "主版本"))") {
                    Button(item.activeCopyID == nil ? "✓ 主版本 (原图)" : "主版本 (原图)") {
                        model.selectVirtualCopy(nil, for: item.id)
                    }
                    Divider()
                    ForEach(item.virtualCopies) { copy in
                        Button(item.activeCopyID == copy.id ? "✓ \(copy.name)" : copy.name) {
                            model.selectVirtualCopy(copy.id, for: item.id)
                        }
                    }
                }
            }
            if let activeID = item.activeCopyID {
                Button("复制当前副本为新版本") {
                    model.duplicateVirtualCopy(activeID, for: item.id)
                }
                Button("重命名当前副本…") {
                    model.promptRenameActiveVirtualCopy()
                }
                Button("删除当前虚拟副本", role: .destructive) {
                    model.deleteVirtualCopy(activeID, for: item.id)
                }
            }

            Divider()

            Button("复制调整参数 (Cmd+Shift+C)") {
                model.copyAdjustments()
            }
            Button("粘贴调整参数 (Cmd+Shift+V)") {
                model.pasteAdjustments()
            }
            .disabled(model.copiedAdjustments == nil)

            if model.selectedIDs.count > 1 {
                Divider()
                Button("选择性同步到已选 \(model.selectedIDs.count) 张照片… (Shift+Cmd+S)") {
                    model.showSelectiveSyncSheet = true
                }
            }
        }
    }

    private func starsText(_ rating: Int) -> String {
        String(repeating: "★", count: rating) + String(repeating: "☆", count: max(0, 5 - rating))
    }

    private static func qualityBadgeColor(_ recommendation: QualityRecommendation) -> Color {
        switch recommendation {
        case .keep: return AtelierPalette.accent
        case .review: return .orange.opacity(0.9)
        case .reject: return .red.opacity(0.9)
        }
    }

    private var previewToolbar: some View {
        HStack(spacing: 12) {
            Group {
                Circle().fill(model.selectedPhoto == nil ? AtelierPalette.muted : AtelierPalette.accent).frame(width: 5, height: 5)
                Text(model.selectedPhoto?.url.lastPathComponent ?? "照片工作台")
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)

                if let photo = model.selectedPhoto {
                    Menu {
                        Button(photo.activeCopyID == nil ? "✓ 主版本 (原图)" : "主版本 (原图)") {
                            model.selectVirtualCopy(nil)
                        }
                        if !photo.virtualCopies.isEmpty {
                            Divider()
                            ForEach(photo.virtualCopies) { copy in
                                Button(photo.activeCopyID == copy.id ? "✓ \(copy.name)" : copy.name) {
                                    model.selectVirtualCopy(copy.id)
                                }
                            }
                        }
                        Divider()
                        Button("新建虚拟副本 (⌘N)") {
                            model.createVirtualCopy()
                        }
                        if let activeID = photo.activeCopyID {
                            Button("复制当前副本为新版本") {
                                _ = model.duplicateVirtualCopy(activeID)
                            }
                            Button("重命名当前副本…") {
                                model.promptRenameActiveVirtualCopy()
                            }
                            Button("删除当前虚拟副本", role: .destructive) {
                                model.deleteVirtualCopy(activeID)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.fill.on.square.fill")
                                .font(.system(size: 9))
                            Text(photo.activeCopy?.name ?? "主版本")
                                .font(.system(size: 10, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                        }
                        .foregroundColor(photo.activeCopyID != nil ? .cyan : AtelierPalette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(photo.activeCopyID != nil ? Color.cyan.opacity(0.15) : AtelierPalette.raised)
                        .clipShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            Spacer(minLength: 0)
            if model.previewBusy { ProgressView().controlSize(.mini) }
            Group {
                Button { model.undo() } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 10))
                        .foregroundColor(model.canUndo ? AtelierPalette.accent : AtelierPalette.muted)
                }.buttonStyle(.plain).disabled(!model.canUndo || model.batchRunning).help("撤销 ⌘Z")
                Button { model.redo() } label: {
                    Label("重做", systemImage: "arrow.uturn.forward")
                        .font(.system(size: 10))
                        .foregroundColor(model.canRedo ? AtelierPalette.accent : AtelierPalette.muted)
                }.buttonStyle(.plain).disabled(!model.canRedo || model.batchRunning).help("重做 ⇧⌘Z")
                Button { showHistoryPopover.toggle() } label: {
                    Label("历史", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundColor(model.historyEntries.count > 1 ? AtelierPalette.accent : AtelierPalette.muted)
                }.buttonStyle(.plain)
                    .disabled(model.historyEntries.isEmpty || model.batchRunning)
                    .help("查看与跳转历史记录")
                    .popover(isPresented: $showHistoryPopover, arrowEdge: .bottom) {
                        HistoryPopoverView(model: model, isPresented: $showHistoryPopover)
                    }
            }
            Button { model.openNativeInspection() } label: {
                Label("原尺寸检查", systemImage: "viewfinder")
                    .font(.system(size: 10)).foregroundColor(AtelierPalette.accent)
            }.buttonStyle(.plain)
                .disabled(model.afterImage == nil || model.previewBusy || model.analysisBusy || model.scanning || model.batchRunning)
            Group {
                Button { compare.toggle() } label: {
                    Label("前后对比", systemImage: "rectangle.lefthalf.inset.filled")
                        .font(.system(size: 10)).foregroundColor(compare ? AtelierPalette.accent : AtelierPalette.muted)
                }.buttonStyle(.plain).disabled(model.afterImage == nil || model.maskInteractionActive)
                if model.selectedPhoto?.activeCopyID != nil && compare {
                    Picker("", selection: $model.comparisonMode) {
                        Text("比对原片").tag(ComparisonMode.original)
                        Text("比对主版本").tag(ComparisonMode.master)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    .onChange(of: model.comparisonMode) { _ in
                        model.requestPreview(immediate: true)
                    }
                }
            }
            ratingControls
            Text("适合窗口").font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
        }.padding(.horizontal, 22).frame(height: 47)
    }

    private var presetShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionLabel("色彩风格")
                Text("\(model.lutOptions.count)")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(AtelierPalette.muted)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(AtelierPalette.raised))
                    .help("内置与导入的 LUT 风格总数")
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    Button { model.showStyleBrowser = true } label: {
                        HStack(spacing: 3) {
                            Text("全部 \(model.lutOptions.count) 种")
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(AtelierPalette.accent)
                        .lineLimit(1).fixedSize()
                    }.buttonStyle(.plain).help("打开风格库浏览全部 \(model.lutOptions.count) 种风格")
                    Button { model.showStyleBrowser = true } label: {
                        Image(systemName: "rectangle.grid.2x2")
                            .font(.system(size: 11)).foregroundColor(AtelierPalette.accent)
                            .frame(width: 18, height: 18)
                    }.buttonStyle(.plain).help("浏览全部 \(model.lutOptions.count) 种风格")
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.lutOptions.enumerated()), id: \.element.id) { index, option in
                            Button { model.selectLUT(option.id) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ZStack(alignment: .bottomLeading) {
                                        AtelierPalette.raised
                                        Image(systemName: option.id == "none" ? "circle.lefthalf.filled" : "camera.filters")
                                            .font(.system(size: 17, weight: .ultraLight)).foregroundColor(Color.white.opacity(0.8)).padding(10)
                                        if model.selectedLUT == option.id {
                                            Image(systemName: "checkmark.circle.fill").foregroundColor(AtelierPalette.accent)
                                                .font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(6)
                                        }
                                    }.frame(width: 96, height: 60).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(model.selectedLUT == option.id ? AtelierPalette.accent : .clear, lineWidth: 1.5))
                                    Text(option.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                        .frame(width: 96, alignment: .leading)
                                        .foregroundColor(model.selectedLUT == option.id ? AtelierPalette.accent : .white.opacity(0.8))
                                }.frame(width: 96, alignment: .leading).help(option.detail)
                            }.buttonStyle(.plain).disabled(model.batchRunning).id(index)
                        }
                        Color.clear.frame(width: 24, height: 1)
                    }.padding(.vertical, 2)
                }
                .onChange(of: model.selectedLUT) { selected in
                    guard let index = model.lutOptions.firstIndex(where: { $0.id == selected }) else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
            .overlay(alignment: .trailing) {
                LinearGradient(colors: [AtelierPalette.panel.opacity(0), AtelierPalette.panel.opacity(0.92)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 18).allowsHitTesting(false)
            }
        }.padding(.horizontal, 22).padding(.vertical, 16)
            .background(AtelierPalette.panel.opacity(0.65))
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack {
                sectionLabel("调色面板")
                Spacer()
                Button("重置") { model.resetAdjustments() }.buttonStyle(.plain)
                    .font(.system(size: 10)).foregroundColor(AtelierPalette.muted)
            }.padding(.horizontal, 20).padding(.top, 23)
            HistogramView(bins: model.histogram).frame(height: 57).padding(.horizontal, 20).padding(.top, 18)
            HStack {
                Text("阴影"); Spacer(); Text("中间调"); Spacer(); Text("高光")
            }.font(.system(size: 8, design: .monospaced)).foregroundColor(AtelierPalette.muted)
                .padding(.horizontal, 20).padding(.top, 5)
            InspectorTabBar(selection: $inspectorTab)
                .padding(.horizontal, 17).padding(.vertical, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if inspectorTab == 0 {
                        AnalysisPanel(model: model, editParameters: { inspectorTab = 1 })
                        RegionalSuggestionsPanel(model: model, editLocals: { inspectorTab = 2 }).padding(.top, 20)
                    }
                    else if inspectorTab == 1 { basicInspector }
                    else if inspectorTab == 2 { MaskInspector(model: model) }
                    else if inspectorTab == 3 { PortraitRetouchPanel(model: model) }
                    else if inspectorTab == 4 { ReferenceColorPanel(model: model) }
                    else if inspectorTab == 6 { ColorToolsPanel(model: model) }
                    else if inspectorTab == 7 { IDPhotoPanel(model: model) }
                    else { exportInspector }
                }.padding(.horizontal, 20).padding(.bottom, 24)
            }.disabled(model.batchRunning)
        }.background(AtelierPalette.panel)
    }

    private var basicInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
            panelHeading("光线与色彩", icon: "sun.max")
            Text("新照片保留拍摄曝光和白点；可先在“分析”比较有限的自动方案，再按意图微调。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4).padding(.bottom, 12)
            Toggle("自动曝光", isOn: $model.adjustments.autoExposure).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).padding(.bottom, 13)
                .help("显式开启旧式中灰估计，最多 ±0.35 EV；此开关不经过三方案的渲染增量检查。")
            AdjustmentSlider(title: "曝光补偿", value: $model.adjustments.exposureEV, range: -4...4, suffix: " EV")
            TonalCurvePanel(model: model).padding(.bottom, 14)
            if model.adjustments.tonalCurve == nil || model.adjustments.highlights != 0 || model.adjustments.shadows != 0 {
                DisclosureGroup("高光与阴影微调") {
                    AdjustmentSlider(title: "高光微调", value: $model.adjustments.highlights, range: -1...1)
                    AdjustmentSlider(title: "阴影微调", value: $model.adjustments.shadows, range: -1...1)
                }.font(.system(size: 10)).padding(.bottom, 12)
            }
            AdjustmentSlider(title: "对比度", value: $model.adjustments.contrast, range: 0.5...1.5)
            }
            separator
            Group {
            Toggle("自动白平衡", isOn: $model.adjustments.autoWhiteBalance).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).padding(.bottom, 13)
                .help("仅在确认中性参照后开启；近灰物体或现场暖光不一定是白平衡错误。")
            AdjustmentSlider(title: "冷暖", value: $model.adjustments.temperature, range: -1...1)
            AdjustmentSlider(title: "色调", value: $model.adjustments.tint, range: -1...1)
            AdjustmentSlider(title: "饱和度", value: $model.adjustments.saturation, range: 0...2)
            }
            separator
            Group {
            panelHeading("风格适配", icon: "circle.hexagongrid")
            Text(model.selectedOption?.name ?? "原色").font(.system(size: 11, weight: .medium)).foregroundColor(AtelierPalette.accent).padding(.bottom, 13)
            if let recommended = model.selectedOption?.recommendedIntensity {
                Button("采用推荐强度 \(Int((recommended * 100).rounded()))%") { model.adoptRecommendedLUTIntensity() }
                    .font(.system(size: 10)).padding(.bottom, 10)
            }
            Group {
                AdjustmentSlider(title: "LUT 强度", value: $model.adjustments.lutIntensity, range: 0...1, percent: true)
                Picker("LUT 色彩空间", selection: Binding(get: { model.adjustments.lutColorSpace },
                    set: { model.setLUTColorSpace($0) })) {
                    ForEach(LUTColorSpace.allCases, id: \.self) { Text($0.title).tag($0) }
                }.font(.system(size: 10)).padding(.bottom, 12).disabled(model.selectedOption?.path == nil)
                if model.selectedOption?.path != nil, !model.lutSpaceConfirmed {
                    Button("确认使用 \(model.adjustments.lutColorSpace.title)") { model.rememberLUTSpace() }
                        .font(.system(size: 10)).padding(.bottom, 8)
                }
                Text("仅支持输入／输出相同的空间与曲线。作者未声明时，选择只是你的解释，不能证明契约正确。P3、sRGB、Rec.709 曲线需区分；Log / HDR / ACES 需先转换。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4).padding(.bottom, 16)
                AdjustmentSlider(title: "保留原始亮度", value: $model.adjustments.preserveLuminance, range: 0...1, percent: true)
                AdjustmentSlider(title: "肤色保护", value: $model.adjustments.protectSkin, range: 0...1, percent: true)
                AdjustmentSlider(title: "中性色保护", value: $model.adjustments.protectNeutrals, range: 0...1, percent: true)
                if model.adjustments.colorHarmony == nil && model.adjustments.lutColorSpace != .displayP3 {
                    AdjustmentSlider(title: "旧版 sRGB 色域保护", value: $model.adjustments.gamutCompression, range: 0...1, percent: true)
                }
            }.disabled(model.selectedLUT == "none").opacity(model.selectedLUT == "none" ? 0.45 : 1)
            Text("保护是可调的色彩约束，无法判断所有风格是否适合每张照片。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
            }
            AdaptiveLUTPanel(model: model)
            separator
            Group {
                CreativeEffectsPanel(model: model)
                separator
                ColorHarmonyPanel(model: model)
            }
            separator
            Group {
            panelHeading("镜头与几何", icon: "viewfinder")
            Toggle("镜头畸变校正", isOn: $model.adjustments.lensCorrection).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).padding(.bottom, 13)
            Group {
                Button { showLensPicker = true } label: {
                    HStack {
                        Text(lensProfileName).font(.system(size: 10)).lineLimit(2)
                        Spacer(minLength: 3); Image(systemName: "magnifyingglass").font(.system(size: 10))
                    }.padding(9).background(AtelierPalette.raised).clipShape(RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain)
                HStack {
                    Text("焦距 mm").font(.system(size: 9))
                    TextField("自动", value: $model.adjustments.lensFocalLength, format: .number)
                        .textFieldStyle(.roundedBorder).font(.system(size: 10))
                    Text("裁切系数").font(.system(size: 9))
                    TextField("自动", value: $model.adjustments.lensCropFactor, format: .number)
                        .textFieldStyle(.roundedBorder).font(.system(size: 10))
                }.padding(.top, 9)
                Text("0 表示读取拍摄信息。JPEG 可能已被机内校正，确认后再启用；无可靠配置会跳过。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4).padding(.vertical, 11)
            }.disabled(!model.adjustments.lensCorrection)
            Toggle("自动水平校正", isOn: $model.adjustments.autoStraighten).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).padding(.bottom, 13)
            AdjustmentSlider(title: "手动旋转", value: $model.adjustments.rotationDegrees, range: -12...12, suffix: "°")
            AdjustmentSlider(title: "垂直透视", value: $model.adjustments.verticalPerspective, range: -0.3...0.3)
            AdjustmentSlider(title: "水平透视", value: $model.adjustments.horizontalPerspective, range: -0.3...0.3)
            Label(model.previewReport.lensCorrectionApplied ? "已校正：\(model.previewReport.lensProfile ?? "匹配镜头")" : "\(LensCorrection.shared.availabilityDescription)", systemImage: model.previewReport.lensCorrectionApplied ? "checkmark.circle" : "info.circle")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
            if !model.previewReport.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(model.previewReport.warnings.enumerated()), id: \.offset) { _, text in
                        Text(text).font(.system(size: 9)).foregroundColor(.orange.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.top, 13)
            }
            }
        }
    }

    private var exportInspector: some View {
        VStack(alignment: .leading, spacing: 15) {
            Group {
            panelHeading("为作品选择出口", icon: "square.and.arrow.up")
            Text("输出位置").font(.system(size: 10)).foregroundColor(AtelierPalette.muted)
            Button { model.chooseOutput() } label: {
                HStack {
                    Image(systemName: "folder")
                    Text(model.outputRoot?.lastPathComponent ?? "选择导出文件夹").lineLimit(1)
                    Spacer(); Image(systemName: "chevron.right").font(.system(size: 9))
                }.font(.system(size: 11)).padding(11).background(AtelierPalette.raised).clipShape(RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).help(model.outputRoot?.path ?? "输出必须与原图目录分开")
            Picker("格式", selection: $model.exportSettings.format) {
                ForEach(ExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }.font(.system(size: 11))
            Picker("输出色彩", selection: $model.exportSettings.colorSpace) {
                ForEach(OutputColorSpace.allCases, id: \.self) { Text($0.title).tag($0) }
            }.font(.system(size: 11))
            if model.exportSettings.format == .jpeg || model.exportSettings.format == .heic {
                AdjustmentSlider(title: "有损品质", value: $model.exportSettings.jpegQuality, range: 0.5...1, percent: true)
            }
            Picker("输出尺寸", selection: Binding(
                get: { model.exportSettings.resize?.mode ?? .none },
                set: { mode in
                    var resize = model.exportSettings.resize ?? ExportResizeSettings()
                    resize.mode = mode
                    model.exportSettings.resize = mode == .none ? nil : resize
                })) {
                ForEach(ExportResizeMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.font(.system(size: 11))
            if let resize = model.exportSettings.resize, resize.mode == .longEdge {
                HStack {
                    Text("长边像素").font(.system(size: 11))
                    TextField("4096", value: Binding(
                        get: { resize.longEdge },
                        set: { model.exportSettings.resize?.longEdge = min(32_768, max(16, $0)) }),
                        format: .number).textFieldStyle(.roundedBorder).font(.system(size: 11))
                }
            } else if let resize = model.exportSettings.resize, resize.mode == .percent {
                AdjustmentSlider(title: "尺寸百分比", value: Binding(
                    get: { resize.percent },
                    set: { model.exportSettings.resize?.percent = min(400, max(1, $0)) }),
                                  range: 1...400, percent: true)
            }
            }
            HStack {
                Text("批量并发").font(.system(size: 11))
                Spacer()
                Stepper(value: $model.batchConcurrency, in: 1...8) {
                    Text("\(model.batchConcurrency) 张并行").font(.system(size: 11))
                }.controlSize(.mini).disabled(model.batchRunning)
            }
            Text("1 = 串行（最省内存），4 = 默认，8 = 最快但更占内存；取消在每张照片完成后生效，已完成的照片保留。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
            Group {
            HStack {
                Text("文件名后缀").font(.system(size: 11))
                TextField("_graded", text: $model.exportSettings.suffix).textFieldStyle(.roundedBorder).font(.system(size: 11))
            }
            HStack {
                Text("文件名模板").font(.system(size: 11))
                TextField("留空＝原名+后缀", text: Binding(
                    get: { model.exportSettings.fileNameTemplate ?? "" },
                    set: { model.exportSettings.fileNameTemplate = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
            }
            Text("模板占位符：{name} 原名、{suffix} 后缀、{index} 序号；缩放/模板/HEIC 需要配方 v10；水印需要配方 v11；客户交付页需要配方 v12。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
            Group {
                watermarkSection
                deliveryPageSection
                selectionOptionsSection
            }
            Toggle("移除位置与相机隐私信息", isOn: $model.exportSettings.stripMetadata)
                .toggleStyle(.checkbox).font(.system(size: 10))
            Text("始终写入正确的输出色彩配置和方向。关闭隐私清理后，可保留原片中的部分拍摄参数。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(5)
            separator
            VStack(alignment: .leading, spacing: 12) {
                safetyRow("不覆盖原片或现有导出文件", icon: "checkmark.shield")
                safetyRow("单张失败，继续处理其他照片", icon: "arrow.triangle.branch")
                safetyRow("生成配方快照与逐张处理报告", icon: "doc.text")
                safetyRow("支持随时安全取消", icon: "pause.circle")
            }
            if let delivery = model.lastDeliveryPage {
                Button("在 Finder 查看客户交付页") { NSWorkspace.shared.activateFileViewerSelecting([delivery]) }
                    .font(.system(size: 11))
            }
            if let manifest = model.lastManifest {
                Button("在 Finder 查看处理报告") { NSWorkspace.shared.activateFileViewerSelecting([manifest]) }
                    .font(.system(size: 11)).padding(.top, 8)
            }
            }
        }
    }

    /// Exit-panel customer delivery page settings. The page itself is generated
    /// by `DeliveryGalleryWriter` (static HTML + relative thumbnails/previews +
    /// optional contact-sheet PDF); this section only edits the settings and
    /// triggers the one-off export action for the selected photo.
    private var deliveryPageSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("导出客户交付页（HTML + 接触表 PDF）", isOn: Binding(
                get: { model.exportSettings.deliveryPage != nil },
                set: { enabled in
                    model.exportSettings.deliveryPage = enabled ? DeliverySettings() : nil
                }))
                .toggleStyle(.checkbox).font(.system(size: 11))
            if let delivery = model.exportSettings.deliveryPage {
                Group {
                    Picker("配色风格", selection: Binding(
                        get: { delivery.theme },
                        set: { model.exportSettings.deliveryPage?.theme = $0 })) {
                        ForEach(DeliveryTheme.allCases, id: \.self) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }.font(.system(size: 11))
                    HStack {
                        Text("标题").font(.system(size: 11))
                        TextField("客户交付", text: Binding(
                            get: { delivery.title },
                            set: { model.exportSettings.deliveryPage?.title = $0 }))
                            .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    }
                    HStack {
                        Text("副标题").font(.system(size: 11))
                        TextField("可选（如：2026 春季写真）", text: Binding(
                            get: { delivery.subtitle ?? "" },
                            set: { model.exportSettings.deliveryPage?.subtitle = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    }
                    HStack {
                        Text("摄影师/机构").font(.system(size: 11))
                        TextField("可选署名（如：Studio Atelier）", text: Binding(
                            get: { delivery.photographer ?? "" },
                            set: { model.exportSettings.deliveryPage?.photographer = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    }
                    Stepper("缩略图列数：\(delivery.columnCount)", value: Binding(
                        get: { delivery.columnCount },
                        set: { model.exportSettings.deliveryPage?.columnCount = min(8, max(1, $0)) }),
                        in: 1...8).font(.system(size: 11))
                    Picker("缩略图长边", selection: Binding(
                        get: { delivery.thumbnailMaxDimension },
                        set: { value in
                            guard let current = model.exportSettings.deliveryPage else { return }
                            model.exportSettings.deliveryPage?.thumbnailMaxDimension = value
                            model.exportSettings.deliveryPage?.previewMaxDimension = max(current.previewMaxDimension, value)
                        })) {
                        Text("480 px").tag(480)
                        Text("640 px").tag(640)
                        Text("960 px").tag(960)
                        Text("1440 px").tag(1440)
                    }.font(.system(size: 11))
                }
                Group {
                    Toggle("设首张为顶部精选封面大图", isOn: Binding(
                        get: { delivery.coverPhotoIndex != nil },
                        set: { enabled in
                            model.exportSettings.deliveryPage?.coverPhotoIndex = enabled ? 0 : nil
                        }))
                        .toggleStyle(.checkbox).font(.system(size: 10))
                    Toggle("离线隐私审计报告 (privacy-audit.json)", isOn: Binding(
                        get: { delivery.includePrivacyAudit },
                        set: { model.exportSettings.deliveryPage?.includePrivacyAudit = $0 }))
                        .toggleStyle(.checkbox).font(.system(size: 10))
                    Toggle("生成接触表 PDF", isOn: Binding(
                        get: { delivery.includeContactSheet },
                        set: { model.exportSettings.deliveryPage?.includeContactSheet = $0 }))
                        .toggleStyle(.checkbox).font(.system(size: 10))
                    Toggle("预览图含水印提示", isOn: Binding(
                        get: { delivery.watermarkedPreviews },
                        set: { model.exportSettings.deliveryPage?.watermarkedPreviews = $0 }))
                        .toggleStyle(.checkbox).font(.system(size: 10))
                }
                Group {
                    let canExportDelivery = !model.batchRunning && !model.deliveryPageBusy && (model.selectedPhoto != nil || !model.selectedIDs.isEmpty)
                    let exportTitle: String = {
                        if model.deliveryPageBusy { return "正在生成客户交付页…" }
                        if model.selectedIDs.count > 1 {
                            return "导出客户交付页（已选 \(model.selectedIDs.count) 张照片）…"
                        } else {
                            return "导出客户交付页（当前照片）…"
                        }
                    }()
                    Button(exportTitle) {
                        model.exportDeliveryPage()
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 10))
                    .disabled(!canExportDelivery)

                    Text("生成独立文件夹（不覆盖既有交付页）：index.html 内嵌样式、只用相对路径缩略图/预览图，无外链/无网络请求；图片重新编码并剥离 GPS/相机序列号等元数据；接触表 PDF 为 A4 网格。")
                        .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
                }
                if let deliveryURL = model.lastDeliveryPage {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("局域网客户预览服务")
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Circle()
                                .fill(model.deliveryServerRunning ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(model.deliveryServerRunning ? "运行中" : "已停止")
                                .font(.system(size: 10))
                                .foregroundColor(model.deliveryServerRunning ? .green : AtelierPalette.muted)
                        }
                        if model.deliveryServerRunning {
                            if let local = model.deliveryServerLocalURL {
                                HStack {
                                    Text("本机:").font(.system(size: 10)).foregroundColor(AtelierPalette.muted)
                                    Text(local).font(.system(size: 10)).textSelection(.enabled)
                                    Button("打开") {
                                        if let u = URL(string: local) { NSWorkspace.shared.open(u) }
                                    }.font(.system(size: 9))
                                }
                            }
                            if let lan = model.deliveryServerLANURL {
                                HStack {
                                    Text("手机:").font(.system(size: 10)).foregroundColor(AtelierPalette.muted)
                                    Text(lan).font(.system(size: 10)).textSelection(.enabled)
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            Button(model.deliveryServerRunning ? "停止服务" : "启动本地预览服务") {
                                model.toggleDeliveryServer()
                            }
                            .buttonStyle(.bordered)
                            .font(.system(size: 10))

                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([deliveryURL])
                            }
                            .font(.system(size: 10))
                        }
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(6)
                }
            }
        }
    }

    /// Session culling selection for the next batch run. These options are NOT
    /// part of `ExportSettings`/`Recipe`: ratings and rejection marks never leave
    /// the in-memory session, and the manifest records skipped photos per entry.
    private var selectionOptionsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("挑图筛选（仅本次会话，不写入配方）")
                .font(.system(size: 10)).foregroundColor(AtelierPalette.muted)
            Toggle("跳过废片", isOn: Binding(
                get: { model.exportSelectionOptions.skipRejectedPhotos },
                set: { model.exportSelectionOptions.skipRejectedPhotos = $0 }))
                .toggleStyle(.checkbox).font(.system(size: 10))
            Toggle("跳过未评级照片", isOn: Binding(
                get: { model.exportSelectionOptions.skipUnselectedPhotos },
                set: { model.exportSelectionOptions.skipUnselectedPhotos = $0 }))
                .toggleStyle(.checkbox).font(.system(size: 10))
            Text("评级/废片是会话状态：不写配方、不持久化；跳过的照片在批次清单里记为 skipped 且不计失败。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
        }
    }

    /// Exit-panel watermark editor. The renderer is export-only, so edits do not
    /// touch the preview: they are applied by `PhotoExporter` after resize and
    /// before encoding (and by the batch dual-version switch).
    private var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("添加水印", isOn: Binding(
                get: { model.exportSettings.watermark != nil },
                set: { enabled in
                    model.exportSettings.watermark = enabled ? WatermarkSettings(text: "光屿 PHOTO") : nil
                    if !enabled { model.exportSettings.watermarkDualVersion = nil }
                }))
                .toggleStyle(.checkbox).font(.system(size: 11))
            if let watermark = model.exportSettings.watermark {
                Picker("水印类型", selection: Binding(
                    get: { watermark.kind },
                    set: { model.exportSettings.watermark?.kind = $0 })) {
                    Text("文字").tag(WatermarkSettings.Kind.text)
                    Text("图片").tag(WatermarkSettings.Kind.image)
                }.font(.system(size: 11))
                if watermark.kind == .text {
                    HStack {
                        Text("水印文字").font(.system(size: 11))
                        TextField("光屿 PHOTO", text: Binding(
                            get: { watermark.text },
                            set: { model.exportSettings.watermark?.text = $0 }))
                            .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("水印图片").font(.system(size: 11))
                        Button(watermark.imagePath.map { ($0 as NSString).lastPathComponent } ?? "选择本地图片…") {
                            chooseWatermarkImage()
                        }.buttonStyle(.bordered).font(.system(size: 10))
                        if watermark.imagePath != nil {
                            Button("清除") { model.exportSettings.watermark?.imagePath = nil }
                                .buttonStyle(.plain).font(.system(size: 10))
                                .foregroundColor(AtelierPalette.accent)
                        }
                    }
                }
                Picker("水印位置", selection: Binding(
                    get: { watermark.anchor },
                    set: { model.exportSettings.watermark?.anchor = $0 })) {
                    ForEach(WatermarkAnchor.allCases, id: \.self) { anchor in
                        Text(watermarkAnchorTitle(anchor)).tag(anchor)
                    }
                }.font(.system(size: 11))
                AdjustmentSlider(title: "水印透明度",
                                 value: Binding(get: { watermark.opacity },
                                                set: { model.exportSettings.watermark?.opacity = min(1, max(0, $0)) }),
                                 range: 0...1, percent: true)
                AdjustmentSlider(title: "水印缩放",
                                 value: Binding(get: { watermark.scale },
                                                set: { model.exportSettings.watermark?.scale = min(20, max(0.02, $0)) }),
                                 range: 0.2...4, percent: true)
                AdjustmentSlider(title: "水印旋转",
                                 value: Binding(get: { watermark.rotationDegrees },
                                                set: { model.exportSettings.watermark?.rotationDegrees = min(180, max(-180, $0)) }),
                                 range: -45...45, suffix: "°")
                Toggle("同时导出无水印版本", isOn: Binding(
                    get: { model.exportSettings.watermarkDualVersion == true },
                    set: { model.exportSettings.watermarkDualVersion = $0 ? true : nil }))
                    .toggleStyle(.checkbox).font(.system(size: 10))
                Text("水印只写入导出文件，不改变原图；旋转或超大字号时水印会自适应缩小以免被裁切。图片水印引用本地文件，缺失时导出会逐项明确报错。双版本会给每张照片额外输出一份 _nowatermark 副本。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineSpacing(4)
            }
        }
    }

    private func chooseWatermarkImage() {
        let panel = NSOpenPanel()
        panel.title = "选择水印图片（仅本地文件）"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "使用图片"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportSettings.watermark?.imagePath = url.path
    }

    private func watermarkAnchorTitle(_ anchor: WatermarkAnchor) -> String {
        switch anchor {
        case .topLeft: return "左上"
        case .topCenter: return "上中"
        case .topRight: return "右上"
        case .centerLeft: return "左中"
        case .center: return "居中"
        case .centerRight: return "右中"
        case .bottomLeft: return "左下"
        case .bottomCenter: return "下中"
        case .bottomRight: return "右下"
        }
    }

    private var batchBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AtelierPalette.line).frame(height: 1)
            HStack(spacing: 16) {
                if model.batchRunning {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.currentFile).font(.system(size: 10)).lineLimit(1)
                        ProgressView(value: model.progress).progressViewStyle(.linear).frame(maxWidth: 210)
                    }
                    Text("\(model.processed) / \(model.photos.count)").font(.system(size: 10, design: .monospaced)).foregroundColor(AtelierPalette.muted)
                    Spacer()
                    Button("安全取消") { model.cancelBatch() }.font(.system(size: 11)).buttonStyle(.bordered)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.photos.isEmpty ? "准备好你的下一组作品" : (model.automaticRecipe == nil ? "将当前配方应用于全部 \(model.photos.count) 张照片" : "逐张分析并处理全部 \(model.photos.count) 张照片"))
                            .font(.system(size: 11, weight: .medium))
                        Text("\(model.exportSettings.format.title)  ·  \(model.exportSettings.colorSpace.title)  ·  独立目录导出")
                            .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                        if model.skipped > 0 {
                            Text("上次跳过 \(model.skipped) 张（废片/未评级，见批次清单）")
                                .font(.system(size: 9)).foregroundColor(.orange.opacity(0.85))
                        }
                    }
                    Spacer(minLength: 4)
                    Button { inspectorTab = 5; model.startBatch() } label: {
                        HStack(spacing: 8) {
                            Text("批量导出"); Image(systemName: "arrow.up.right")
                        }.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 19).padding(.vertical, 12)
                            .foregroundColor(AtelierPalette.background).background(AtelierPalette.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).disabled(model.photos.isEmpty || model.previewBusy || model.scanning || model.lutLibraryBusy || (model.automaticRecipe != nil && model.analysisBusy))
                }
            }.padding(.horizontal, 22).frame(height: 77)
        }.background(AtelierPalette.panel)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: model.batchRunning ? "circle.dotted" : "circle.fill").font(.system(size: 5)).foregroundColor(AtelierPalette.accent)
            Text(model.status).font(.system(size: 9)).foregroundColor(AtelierPalette.muted).lineLimit(1)
            Spacer()
            if !model.batchMessages.isEmpty {
                Button("查看记录") { showLog = true }.buttonStyle(.plain).font(.system(size: 9)).foregroundColor(AtelierPalette.accent)
            }
            if model.outputRoot != nil {
                Button { model.revealOutput() } label: { Image(systemName: "folder") }.buttonStyle(.plain).foregroundColor(AtelierPalette.muted)
            }
            Text("LOCAL ONLY").font(.system(size: 8, design: .monospaced)).tracking(1).foregroundColor(AtelierPalette.muted)
        }.padding(.horizontal, 18).frame(height: 29).background(Color.black.opacity(0.2))
    }

    private var logSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("批量处理记录").font(.title3)
                Spacer(); Button("完成") { showLog = false }
            }
            ScrollView {
                Text(model.batchMessages.joined(separator: "\n\n"))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 650, height: 470)
    }

    private var separator: some View { Rectangle().fill(AtelierPalette.line).frame(height: 1).padding(.vertical, 20) }
    private var lensProfileName: String {
        guard let id = model.adjustments.lensProfileID else { return "自动识别镜头 · EXIF" }
        return LensCorrection.shared.profiles.first(where: { $0.id == id }).map { $0.maker + " " + $0.name } ?? "配置不可用 · 重新选择"
    }
    private func sectionLabel(_ title: String) -> some View { Text(title).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundColor(.white.opacity(0.8)) }
    private func panelHeading(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.9)).padding(.bottom, 17)
    }
    private func safetyRow(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 10)).foregroundColor(AtelierPalette.muted)
    }
    private func toolButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.system(size: 11)).foregroundColor(.white.opacity(0.65)) }.buttonStyle(.plain)
    }

    /// Resolves Finder drops (files and/or folders) into local file URLs. A drop
    /// without any readable file URL is reported to the model instead of being
    /// swallowed. Loading is asynchronous per provider; the model merges the
    /// result once, so a multi-item drop never interleaves library transitions.
    private func importDroppedProviders(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        var unreadable = 0
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? URL {
                    url = value
                }
                lock.lock()
                if let resolved = url, resolved.isFileURL { urls.append(resolved) } else { unreadable += 1 }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // Mixed drops must keep the per-provider failures inside the import
            // result; reporting them first would be cleared by importSelection.
            var issues: [String] = []
            if unreadable > 0 { issues.append("\(unreadable) 个拖放项目无法读取为本地文件") }
            if !urls.isEmpty {
                model.importSelection(urls, extraIssues: issues)
            } else if !issues.isEmpty {
                model.reportImportFailure(issues.joined(separator: "\n"))
            }
        }
    }

    private func presetColors(_ index: Int) -> [Color] {
        let palettes: [[Color]] = [
            [.init(red: 0.36, green: 0.40, blue: 0.42), .init(red: 0.16, green: 0.20, blue: 0.23)],
            [.init(red: 0.57, green: 0.58, blue: 0.40), .init(red: 0.22, green: 0.34, blue: 0.26)],
            [.init(red: 0.63, green: 0.40, blue: 0.29), .init(red: 0.22, green: 0.32, blue: 0.35)],
            [.init(red: 0.71, green: 0.57, blue: 0.40), .init(red: 0.37, green: 0.26, blue: 0.26)],
            [.init(red: 0.37, green: 0.52, blue: 0.58), .init(red: 0.19, green: 0.28, blue: 0.37)],
            [.init(red: 0.56, green: 0.53, blue: 0.52), .init(red: 0.17, green: 0.20, blue: 0.24)]
        ]
        return palettes[index % palettes.count]
    }
}

struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var suffix = ""
    var percent = false
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(.system(size: 10)).foregroundColor(.white.opacity(0.7))
                Spacer()
                Text(percent ? "\(Int(value * 100))%" : String(format: "%+.2f", value) + suffix)
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(AtelierPalette.muted)
            }
            Slider(value: $value, in: range).controlSize(.mini)
        }.padding(.bottom, 13)
    }
}

struct HistogramView: View {
    let bins: [Double]
    var body: some View {
        Canvas { context, size in
            guard bins.count > 1 else { return }
            var shape = Path()
            shape.move(to: .init(x: 0, y: size.height))
            for (index, value) in bins.enumerated() {
                shape.addLine(to: .init(x: Double(index) / Double(bins.count - 1) * size.width,
                                       y: size.height * (1 - value * 0.92)))
            }
            shape.addLine(to: .init(x: size.width, y: size.height)); shape.closeSubpath()
            context.fill(shape, with: .linearGradient(.init(colors: [AtelierPalette.accent.opacity(0.4), AtelierPalette.accent.opacity(0.06)]), startPoint: .zero, endPoint: .init(x: 0, y: size.height)))
            context.stroke(shape, with: .color(AtelierPalette.accent.opacity(0.55)), lineWidth: 0.7)
            for fraction in [0.25, 0.5, 0.75] {
                let x = size.width * fraction
                var line = Path(); line.move(to: .init(x: x, y: 0)); line.addLine(to: .init(x: x, y: size.height))
                context.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 1)
            }
        }.background(Color.black.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

import SwiftUI
import PhotoCore

enum AtelierPalette {
    static let background = Color(red: 0.062, green: 0.075, blue: 0.09)
    static let panel = Color(red: 0.092, green: 0.108, blue: 0.126)
    static let raised = Color(red: 0.135, green: 0.153, blue: 0.174)
    static let muted = Color(red: 0.55, green: 0.60, blue: 0.65)
    static let accent = Color(red: 0.78, green: 0.88, blue: 0.58)
    static let line = Color.white.opacity(0.07)
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var inspectorTab = 0
    @State private var compare = true
    @State private var split = 0.5
    @State private var showLog = false
    @State private var showLensPicker = false
    init(model: AppModel, initialTab: Int = 0, initialCompare: Bool = true) {
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
        .onChange(of: model.adjustments) { _ in model.requestPreview() }
        .onChange(of: model.selectedLUT) { _ in model.requestPreview() }
        .onChange(of: model.exportSettings.recursive) { _ in model.reloadFolder() }
        .onChange(of: model.exportSettings.colorSpace) { _ in model.requestPreview() }
        .onChange(of: model.selectedMask) { _ in model.maskSelectionChanged() }
        .onChange(of: model.showMaskCoverage) { showing in
            if showing { compare = false }
            model.requestPreview()
        }
        .onChange(of: model.maskInteractionActive) { active in if active { compare = false } }
        .onChange(of: model.maskDrawMode) { _ in model.drawingMask = false; model.maskEditMode = false }
        .onChange(of: model.maskKind) { kind in
            if kind == .luminance || kind == .color { model.drawingMask = false }
        }
        .onChange(of: inspectorTab) { tab in
            if tab != 2 { model.cancelMaskInteraction(); model.showMaskCoverage = false }
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
            Button(action: { model.chooseInput() }) {
                Label("打开文件夹", systemImage: "folder").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .foregroundColor(AtelierPalette.background).background(AtelierPalette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).disabled(model.batchRunning)
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
            if let root = model.inputRoot {
                Label(root.lastPathComponent, systemImage: "folder.fill")
                    .font(.system(size: 12)).lineLimit(1).help(root.path)
                    .foregroundColor(.white.opacity(0.85)).padding(.horizontal, 18).padding(.top, 17)
            } else {
                Text("尚未选择文件夹").font(.system(size: 11)).foregroundColor(AtelierPalette.muted)
                    .padding(.horizontal, 18).padding(.top, 17)
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
                    Text("JPEG · PNG · TIFF · RAW\n本机分析与非破坏性处理")
                        .font(.system(size: 10)).multilineTextAlignment(.center).lineSpacing(5)
                }.foregroundColor(AtelierPalette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(Array(model.photos.enumerated()), id: \.element.id) { index, item in
                            Button { model.selectPhoto(item) } label: {
                                HStack(spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.3))
                                        if let image = model.thumbnails[item.id] {
                                            Image(nsImage: image).resizable().scaledToFill().frame(width: 47, height: 47).clipped()
                                        } else { Image(systemName: "photo").foregroundColor(AtelierPalette.muted) }
                                    }.frame(width: 47, height: 47).clipShape(RoundedRectangle(cornerRadius: 4))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.url.deletingPathExtension().lastPathComponent)
                                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        Text("\(String(format: "%02d", index + 1))  ·  \(item.url.pathExtension.uppercased())")
                                            .font(.system(size: 9, design: .monospaced)).foregroundColor(AtelierPalette.muted)
                                    }
                                    Spacer(minLength: 0)
                                    if model.selectedID == item.id {
                                        Circle().fill(AtelierPalette.accent).frame(width: 5, height: 5)
                                    }
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(model.selectedID == item.id ? AtelierPalette.raised : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).onAppear { model.loadThumbnail(item) }
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

    private var previewToolbar: some View {
        HStack(spacing: 12) {
            Circle().fill(model.selectedPhoto == nil ? AtelierPalette.muted : AtelierPalette.accent).frame(width: 5, height: 5)
            Text(model.selectedPhoto?.url.lastPathComponent ?? "照片工作台")
                .font(.system(size: 11, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            if model.previewBusy { ProgressView().controlSize(.mini) }
            Button { model.openNativeInspection() } label: {
                Label("原尺寸检查", systemImage: "viewfinder")
                    .font(.system(size: 10)).foregroundColor(AtelierPalette.accent)
            }.buttonStyle(.plain)
                .disabled(model.afterImage == nil || model.previewBusy || model.analysisBusy || model.scanning || model.batchRunning)
            Button { compare.toggle() } label: {
                Label("前后对比", systemImage: "rectangle.lefthalf.inset.filled")
                    .font(.system(size: 10)).foregroundColor(compare ? AtelierPalette.accent : AtelierPalette.muted)
            }.buttonStyle(.plain).disabled(model.afterImage == nil || model.maskInteractionActive)
            Text("适合窗口").font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
        }.padding(.horizontal, 22).frame(height: 47)
    }

    private var presetShelf: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                sectionLabel("色彩风格")
                Text("LUT COLLECTION").font(.system(size: 8, weight: .medium)).tracking(1.5).foregroundColor(AtelierPalette.muted)
                Spacer()
                Button("比较全部 \(model.lutOptions.count) 种风格") { model.showStyleBrowser = true }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundColor(AtelierPalette.accent)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(model.lutOptions.enumerated()), id: \.element.id) { index, option in
                        Button { model.selectLUT(option.id) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                ZStack(alignment: .bottomLeading) {
                                    AtelierPalette.raised
                                    Image(systemName: option.id == "none" ? "circle.lefthalf.filled" : "camera.filters")
                                        .font(.system(size: 17, weight: .ultraLight)).foregroundColor(Color.white.opacity(0.8)).padding(10)
                                    if model.selectedLUT == option.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundColor(AtelierPalette.accent)
                                            .font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(6)
                                    }
                                }.frame(width: 94, height: 58).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(model.selectedLUT == option.id ? AtelierPalette.accent : .clear, lineWidth: 1.5))
                                Text(option.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                    .foregroundColor(model.selectedLUT == option.id ? AtelierPalette.accent : .white.opacity(0.8))
                            }.frame(width: 94, alignment: .leading).help(option.detail)
                        }.buttonStyle(.plain).disabled(model.batchRunning)
                    }
                }.padding(.vertical, 2)
            }
        }.padding(.horizontal, 22).padding(.vertical, 18)
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
            Picker("调整分类", selection: $inspectorTab) {
                Text("分析").tag(0); Text("基础").tag(1); Text("局部").tag(2); Text("导出").tag(3)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 17).padding(.vertical, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if inspectorTab == 0 {
                        AnalysisPanel(model: model, editParameters: { inspectorTab = 1 })
                        RegionalSuggestionsPanel(model: model, editLocals: { inspectorTab = 2 }).padding(.top, 20)
                    }
                    else if inspectorTab == 1 { basicInspector }
                    else if inspectorTab == 2 { MaskInspector(model: model) }
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
            if model.exportSettings.format == .jpeg {
                AdjustmentSlider(title: "JPEG 品质", value: $model.exportSettings.jpegQuality, range: 0.5...1, percent: true)
            }
            }
            Group {
            HStack {
                Text("文件名后缀").font(.system(size: 11))
                TextField("_graded", text: $model.exportSettings.suffix).textFieldStyle(.roundedBorder).font(.system(size: 11))
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
            if let manifest = model.lastManifest {
                Button("在 Finder 查看处理报告") { NSWorkspace.shared.activateFileViewerSelecting([manifest]) }
                    .font(.system(size: 11)).padding(.top, 8)
            }
            }
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
                    }
                    Spacer(minLength: 4)
                    Button { inspectorTab = 3; model.startBatch() } label: {
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

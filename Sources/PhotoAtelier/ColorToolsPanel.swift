import PhotoCore
import SwiftUI

/// Right-inspector “调色” tab for the P1 color tools.
///
/// The copy is deliberately explicit: curves/HSL/grading/lens effects are
/// heuristic color tools, not a commercial-grade color science suite. Curves are
/// applied in display-encoded sRGB; HSL and grading work in OKLab; the vignette
/// and chromatic aberration are display-scale approximations. Synthetic tests
/// only prove algorithmic contracts, not real-photo aesthetic quality.
///
/// Every edit goes through `AppModel.updateColorTools`/`updateLensEffects`, which
/// store the value in `AdjustmentSettings`; the existing
/// `onChange(adjustments) → requestPreview()` token mechanism therefore refreshes
/// the preview without blocking the main thread, and undo/redo keeps working.
struct ColorToolsPanel: View {
    @ObservedObject var model: AppModel

    @State private var curveChannel: CurveChannel = .luminance
    @State private var selectedCurvePoint: Int?
    @State private var hslBand: HSLBand = .red

    private enum CurveChannel: String, CaseIterable, Identifiable {
        case luminance, red, green, blue
        var id: String { rawValue }
        var title: String {
            switch self {
            case .luminance: return "亮度"
            case .red: return "红"
            case .green: return "绿"
            case .blue: return "蓝"
            }
        }
    }

    private var colorTools: ColorToolsSettings { model.adjustments.colorTools ?? ColorToolsSettings() }
    private var lensEffects: LensEffectsSettings { model.adjustments.lensEffects ?? LensEffectsSettings() }
    private var isActive: Bool { model.hasActiveColorTools }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("调色工具 v1", systemImage: "slider.horizontal.3")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .padding(.bottom, 10)
            Text("曲线 / HSL 8 色相带 / 三色轮颜色分级 / 镜头暗角与横向色差。曲线在显示编码 sRGB 上应用，HSL 与分级在 OKLab 上工作，暗角与色差是显示尺度近似。这是启发式调色工具，不是商业级色彩科学；合成测试只验证算法契约，未做真实照片审美验收。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            HStack(spacing: 8) {
                Circle()
                    .fill(isActive ? AtelierPalette.accent : AtelierPalette.muted.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(isActive ? "调色工具已生效（v11 配方）" : "全部中性：不改像素，旧配方路径")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                Spacer(minLength: 0)
                Button("归零") { model.resetColorTools() }
                    .font(.system(size: 10)).buttonStyle(.plain)
                    .foregroundColor(isActive ? AtelierPalette.accent : AtelierPalette.muted)
                    .disabled(model.batchRunning || !isActive)
            }.padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 0) {
                curveSection
                separator
                hslSection
                separator
                gradingSection
                separator
                lensSection
                separator
                Text("限制：曲线 2–16 个控制点、PCHIP 单调插值无过冲；HSL 8 带为均匀 OKLab 色相分区（±45° 余弦窗），低彩度像素受中性保护；分级按 OKLab 亮度分区并夹取色度/亮度偏移；暗角/色差为显示近似且有幅度上限。用工具栏「前后对比」查看差异。")
                    .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: curveChannel) { _ in selectedCurvePoint = nil }
    }

    // MARK: - Curves

    private var curveSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("曲线", icon: "chart.xyaxis.line")
            Text("选中通道后拖动控制点调整；点击曲线空白处添加控制点，2–16 个点，X 轴严格递增。亮度曲线在 RGB 通道曲线之后按 Rec.709 亮度缩放。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            Picker("曲线通道", selection: $curveChannel) {
                ForEach(CurveChannel.allCases) { channel in
                    Text(channel.title).tag(channel)
                }
            }.pickerStyle(.segmented).labelsHidden().padding(.bottom, 8)
            CurveGraph(points: displayedCurvePoints,
                       lut: displayedCurveLUT,
                       selectedIndex: $selectedCurvePoint,
                       onMove: moveCurvePoint,
                       onAdd: addCurvePoint)
            HStack(spacing: 8) {
                Button("线性") { setCurvePoints(nil) }
                Button("柔和对比") {
                    setCurvePoints([CurveControlPoint(x: 0, y: 0),
                                    CurveControlPoint(x: 0.25, y: 0.22),
                                    CurveControlPoint(x: 0.5, y: 0.5),
                                    CurveControlPoint(x: 0.75, y: 0.78),
                                    CurveControlPoint(x: 1, y: 1)])
                }
                Button("S 曲线") {
                    setCurvePoints([CurveControlPoint(x: 0, y: 0),
                                    CurveControlPoint(x: 0.25, y: 0.18),
                                    CurveControlPoint(x: 0.75, y: 0.82),
                                    CurveControlPoint(x: 1, y: 1)])
                }
                Spacer(minLength: 0)
                Button("删除点") { deleteSelectedCurvePoint() }
                    .disabled(selectedCurvePoint == nil || displayedCurvePoints.count <= 2)
            }.font(.system(size: 9)).buttonStyle(.plain)
                .foregroundColor(AtelierPalette.accent)
                .padding(.top, 8)
        }
    }

    private var identityCurve: [CurveControlPoint] {
        [CurveControlPoint(x: 0, y: 0), CurveControlPoint(x: 1, y: 1)]
    }

    private var displayedCurvePoints: [CurveControlPoint] {
        curvePoints(for: curveChannel) ?? identityCurve
    }

    private var displayedCurveLUT: [Double] {
        (try? ColorCurveEngine.lookupTable(for: curvePoints(for: curveChannel)))
            ?? (0..<ColorCurveEngine.lookupTableSize).map {
                Double($0) / Double(ColorCurveEngine.lookupTableSize - 1)
            }
    }

    private func curvePoints(for channel: CurveChannel) -> [CurveControlPoint]? {
        let curves = colorTools.curves
        switch channel {
        case .luminance: return curves?.luminance
        case .red: return curves?.red
        case .green: return curves?.green
        case .blue: return curves?.blue
        }
    }

    private func setCurvePoints(_ points: [CurveControlPoint]?) {
        let normalized: [CurveControlPoint]? = {
            guard let points, !isIdentityCurve(points) else { return nil }
            return points.sorted { $0.x < $1.x }
        }()
        model.updateColorTools { tools in
            var curves = tools.curves ?? ColorCurveSettings()
            switch curveChannel {
            case .luminance: curves.luminance = normalized
            case .red: curves.red = normalized
            case .green: curves.green = normalized
            case .blue: curves.blue = normalized
            }
            tools.curves = curves
        }
    }

    private func isIdentityCurve(_ points: [CurveControlPoint]) -> Bool {
        points.count == 2
            && abs(points[0].x) < 1e-9 && abs(points[0].y) < 1e-9
            && abs(points[1].x - 1) < 1e-9 && abs(points[1].y - 1) < 1e-9
    }

    private func moveCurvePoint(_ index: Int, _ point: CGPoint) {
        var points = displayedCurvePoints
        guard points.indices.contains(index) else { return }
        let minimumX = index > 0 ? points[index - 1].x + 0.005 : 0
        let maximumX = index < points.count - 1 ? points[index + 1].x - 0.005 : 1
        let x = min(max(Double(point.x), minimumX), max(minimumX, maximumX))
        let y = min(max(Double(point.y), 0), 1)
        points[index] = CurveControlPoint(x: x, y: y)
        setCurvePoints(points)
    }

    private func addCurvePoint(_ point: CGPoint) {
        var points = displayedCurvePoints
        guard points.count < ColorCurveEngine.maximumControlPoints else { return }
        let x = min(max(Double(point.x), 0.001), 0.999)
        let y = min(max(Double(point.y), 0), 1)
        let candidate = CurveControlPoint(x: x, y: y)
        points.append(candidate)
        points.sort { $0.x < $1.x }
        guard let index = points.firstIndex(where: { $0.x == candidate.x && $0.y == candidate.y }) else { return }
        selectedCurvePoint = index
        setCurvePoints(points)
    }

    private func deleteSelectedCurvePoint() {
        guard let index = selectedCurvePoint else { return }
        var points = displayedCurvePoints
        guard points.count > 2, points.indices.contains(index) else { return }
        points.remove(at: index)
        selectedCurvePoint = nil
        setCurvePoints(points)
    }

    // MARK: - HSL

    private var hslSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("HSL · 8 色相带", icon: "circle.hexagongrid")
            Text("色相带按 OKLab 色相角每 45° 分区（0°=红带中心），带间余弦平滑过渡；低彩度像素受中性保护。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            HStack(spacing: 4) {
                ForEach(HSLBand.allCases, id: \.self) { band in
                    Button {
                        hslBand = band
                    } label: {
                        VStack(spacing: 3) {
                            Circle()
                                .fill(Color(hue: band.hueCenterDegrees / 360,
                                            saturation: 0.75, brightness: 0.95))
                                .frame(width: 12, height: 12)
                                .overlay {
                                    if !hslAdjustment(band).isNeutral {
                                        Circle().stroke(Color.white.opacity(0.9), lineWidth: 1)
                                    }
                                }
                            Text(bandTitle(band)).font(.system(size: 8))
                                .foregroundColor(hslBand == band ? .white : AtelierPalette.muted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(hslBand == band ? Color.white.opacity(0.08) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain)
                }
            }.padding(.bottom, 10)
            let adjustment = hslAdjustment(hslBand)
            AdjustmentSlider(title: "色相偏移",
                             value: hslBinding(\.hueShiftDegrees), range: -180...180,
                             suffix: "°")
            AdjustmentSlider(title: "饱和度", value: hslBinding(\.saturation),
                             range: -1...1, percent: true)
            AdjustmentSlider(title: "亮度", value: hslBinding(\.luminance),
                             range: -1...1, percent: true)
            HStack {
                Spacer()
                Button("重置本带") { setHSLBand(HSLBandAdjustment()) }
                    .font(.system(size: 9)).buttonStyle(.plain)
                    .foregroundColor(adjustment.isNeutral ? AtelierPalette.muted : AtelierPalette.accent)
                    .disabled(adjustment.isNeutral)
            }
        }
    }

    private func bandTitle(_ band: HSLBand) -> String {
        switch band {
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .cyan: return "青"
        case .blue: return "蓝"
        case .purple: return "紫"
        case .magenta: return "洋红"
        }
    }

    private func hslAdjustment(_ band: HSLBand) -> HSLBandAdjustment {
        colorTools.hsl?[band] ?? HSLBandAdjustment()
    }

    private func setHSLBand(_ adjustment: HSLBandAdjustment) {
        model.updateColorTools { tools in
            var hsl = tools.hsl ?? HSLSettings()
            hsl[hslBand] = adjustment
            tools.hsl = hsl
        }
    }

    private func hslBinding(_ keyPath: WritableKeyPath<HSLBandAdjustment, Double>) -> Binding<Double> {
        Binding(get: { hslAdjustment(hslBand)[keyPath: keyPath] },
                set: { newValue in
                    var adjustment = hslAdjustment(hslBand)
                    adjustment[keyPath: keyPath] = newValue
                    setHSLBand(adjustment)
                })
    }

    // MARK: - Grading

    private var gradingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("颜色分级 · 三色轮", icon: "circle.grid.2x2")
            Text("按 OKLab 亮度在阴影/中间调/高光之间平滑分配色轮权重；balance 移动三个亮度枢轴。端点受保护，色度与亮度偏移有限幅。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            gradingWheel("阴影", keyPath: \.shadows)
            gradingWheel("中间调", keyPath: \.midtones)
            gradingWheel("高光", keyPath: \.highlights)
            gradingWheel("全局", keyPath: \.global)
            AdjustmentSlider(title: "平衡",
                             value: Binding(get: { colorTools.grading?.balance ?? 0 },
                                            set: { value in
                                                model.updateColorTools { tools in
                                                    var grading = tools.grading ?? ColorGradingSettings()
                                                    grading.balance = value
                                                    tools.grading = grading
                                                }
                                            }),
                             range: -1...1, percent: true)
        }
    }

    private func gradingWheel(_ title: String,
                              keyPath: WritableKeyPath<ColorGradingSettings, ColorGradingWheel>) -> some View {
        let wheel = gradingWheelValue(keyPath)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color(hue: wheel.hueDegrees / 360,
                                saturation: wheel.saturation, brightness: 0.92))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                Text(title).font(.system(size: 10)).foregroundColor(.white.opacity(0.75))
                Spacer()
                Text(wheel.isNeutral ? "中性" : String(format: "%.0f° · %.0f%%",
                                                       wheel.hueDegrees, wheel.saturation * 100))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(AtelierPalette.muted)
            }.padding(.bottom, 4)
            AdjustmentSlider(title: "色相",
                             value: gradingBinding(keyPath, \.hueDegrees), range: 0...360,
                             suffix: "°")
            AdjustmentSlider(title: "饱和度",
                             value: gradingBinding(keyPath, \.saturation), range: 0...1,
                             percent: true)
            AdjustmentSlider(title: "亮度",
                             value: gradingBinding(keyPath, \.luminance), range: -1...1,
                             percent: true)
        }
    }

    private func gradingWheelValue(_ keyPath: WritableKeyPath<ColorGradingSettings, ColorGradingWheel>)
        -> ColorGradingWheel {
        (colorTools.grading ?? ColorGradingSettings())[keyPath: keyPath]
    }

    private func gradingBinding(_ wheelKeyPath: WritableKeyPath<ColorGradingSettings, ColorGradingWheel>,
                                _ valueKeyPath: WritableKeyPath<ColorGradingWheel, Double>) -> Binding<Double> {
        Binding(get: { gradingWheelValue(wheelKeyPath)[keyPath: valueKeyPath] },
                set: { value in
                    model.updateColorTools { tools in
                        var grading = tools.grading ?? ColorGradingSettings()
                        var wheel = grading[keyPath: wheelKeyPath]
                        wheel[keyPath: valueKeyPath] = value
                        grading[keyPath: wheelKeyPath] = wheel
                        tools.grading = grading
                    }
                })
    }

    // MARK: - Lens effects

    private var lensSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("镜头效果 · 暗角 / 色差", icon: "camera.aperture")
            Text("暗角是径向增益（正值压暗角落、负值提亮，中心不变）；横向色差只沿径向移动红/蓝通道，绿通道与几何不变。两者都是显示近似，不是物理镜头标定。")
                .font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            AdjustmentSlider(title: "暗角强度", value: lensBinding(\.vignetteAmount),
                             range: -1...1, percent: true)
            AdjustmentSlider(title: "暗角中点", value: lensBinding(\.vignetteMidpoint),
                             range: 0...1, percent: true)
            AdjustmentSlider(title: "暗角羽化", value: lensBinding(\.vignetteFeather),
                             range: 0...1, percent: true)
            AdjustmentSlider(title: "暗角圆度", value: lensBinding(\.vignetteRoundness),
                             range: 0...1, percent: true)
            AdjustmentSlider(title: "红色差", value: lensBinding(\.chromaticAberrationRed),
                             range: -1...1, percent: true)
            AdjustmentSlider(title: "蓝色差", value: lensBinding(\.chromaticAberrationBlue),
                             range: -1...1, percent: true)
        }
    }

    private func lensBinding(_ keyPath: WritableKeyPath<LensEffectsSettings, Double>) -> Binding<Double> {
        Binding(get: { lensEffects[keyPath: keyPath] },
                set: { value in
                    model.updateLensEffects { effects in
                        effects[keyPath: keyPath] = value
                    }
                })
    }

    // MARK: - Shared chrome

    private func heading(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.85))
            .padding(.bottom, 7)
    }

    private var separator: some View {
        Rectangle().fill(AtelierPalette.line).frame(height: 1).padding(.vertical, 14)
    }
}

/// Minimal draggable curve editor: grid, identity diagonal, PCHIP curve and its
/// control points. Dragging a point moves it (X stays strictly increasing);
/// dragging empty space adds a point on release.
private struct CurveGraph: View {
    let points: [CurveControlPoint]
    let lut: [Double]
    @Binding var selectedIndex: Int?
    let onMove: (Int, CGPoint) -> Void
    let onAdd: (CGPoint) -> Void

    @State private var dragIndex: Int?
    @State private var pendingAdd: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, canvasSize in
                var grid = Path()
                for fraction in [0.25, 0.5, 0.75] {
                    let x = canvasSize.width * CGFloat(fraction)
                    let y = canvasSize.height * CGFloat(fraction)
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: canvasSize.height))
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: canvasSize.width, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(0.06)), lineWidth: 0.6)

                var diagonal = Path()
                diagonal.move(to: CGPoint(x: 0, y: canvasSize.height))
                diagonal.addLine(to: CGPoint(x: canvasSize.width, y: 0))
                context.stroke(diagonal, with: .color(.white.opacity(0.12)),
                               style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))

                if lut.count >= 2 {
                    var curve = Path()
                    for (index, value) in lut.enumerated() {
                        let x = CGFloat(Double(index) / Double(lut.count - 1)) * canvasSize.width
                        let y = CGFloat(1 - min(max(value, 0), 1)) * canvasSize.height
                        if index == 0 { curve.move(to: CGPoint(x: x, y: y)) }
                        else { curve.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(curve, with: .color(AtelierPalette.accent.opacity(0.9)),
                                   lineWidth: 1.4)
                }

                for (index, point) in points.enumerated() {
                    let center = CGPoint(x: CGFloat(point.x) * canvasSize.width,
                                         y: CGFloat(1 - point.y) * canvasSize.height)
                    let radius: CGFloat = index == selectedIndex ? 4.5 : 3.5
                    let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                      width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(index == selectedIndex ? .white : AtelierPalette.accent))
                }
            }
            .background(Color.black.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(AtelierPalette.line, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let normalized = normalizedPoint(value.location, in: size)
                        if let index = dragIndex {
                            onMove(index, normalized)
                            return
                        }
                        if let nearest = nearestPoint(to: value.location, in: size) {
                            dragIndex = nearest
                            selectedIndex = nearest
                            onMove(nearest, normalized)
                        } else {
                            pendingAdd = normalized
                        }
                    }
                    .onEnded { _ in
                        if dragIndex == nil, let pending = pendingAdd {
                            onAdd(pending)
                        }
                        dragIndex = nil
                        pendingAdd = nil
                    }
            )
        }
        .frame(height: 150)
    }

    private func normalizedPoint(_ location: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(max(location.x / size.width, 0), 1),
                       y: min(max(1 - location.y / size.height, 0), 1))
    }

    private func nearestPoint(to location: CGPoint, in size: CGSize) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, point) in points.enumerated() {
            let center = CGPoint(x: CGFloat(point.x) * size.width,
                                 y: CGFloat(1 - point.y) * size.height)
            let dx = center.x - location.x
            let dy = center.y - location.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance <= 14, best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }
}

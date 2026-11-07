import SwiftUI
import PhotoCore

private enum CanvasDragAction: Equatable {
    case draw
    case moveStart(UUID)
    case moveEnd(UUID)
    case pan
    case compare
    case liquify
    case repair
    case ignore
}

struct PhotoCanvas: View {
    @ObservedObject var model: AppModel
    let compare: Bool
    @Binding var split: Double
    @State private var draft: [MaskPoint] = []
    @State private var dragAction: CanvasDragAction?
    @State private var dragStartPoint: MaskPoint?
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var panOrigin = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AtelierPalette.background
                if let after = model.afterImage {
                    let fitted = fit(after.size, in: CGSize(width: max(1, geometry.size.width - 48), height: max(1, geometry.size.height - 64)))
                    photoContent(after, size: CGSize(width: fitted.width * zoom, height: fitted.height * zoom))
                        .offset(pan)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    canvasControls
                } else if model.previewBusy {
                    VStack(spacing: 15) {
                        ProgressView().controlSize(.small)
                        Text("正在生成色彩管理预览…").font(.system(size: 11)).foregroundColor(AtelierPalette.muted)
                    }
                } else {
                    emptyState
                }
            }.clipped()
        }
        .onChange(of: model.selectedID) { _ in
            zoom = 1
            pan = .zero
            panOrigin = .zero
            cancelCanvasGesture()
        }
        .onChange(of: model.drawingMask) { _ in cancelCanvasGesture() }
        .onChange(of: model.maskInteractionActive) { _ in cancelCanvasGesture() }
        .onChange(of: model.selectedMask) { _ in cancelCanvasGesture() }
        .onChange(of: model.maskKind) { _ in cancelCanvasGesture() }
        .onChange(of: model.maskDrawMode) { _ in cancelCanvasGesture() }
        .onChange(of: model.liquifyBrushActive) { _ in cancelCanvasGesture() }
        .onChange(of: model.repairBrushActive) { _ in cancelCanvasGesture() }
        .onChange(of: model.batchRunning) { running in
            if running { cancelCanvasGesture() }
        }
        .onExitCommand {
            if model.repairBrushActive {
                model.toggleRepairBrush()
                cancelCanvasGesture()
            } else if model.liquifyBrushActive {
                model.toggleLiquifyBrush()
                cancelCanvasGesture()
            } else if model.maskInteractionActive {
                model.cancelMaskInteraction()
                cancelCanvasGesture()
            }
        }
    }

    private var canvasControls: some View {
        VStack {
            Spacer()
            HStack(spacing: 5) {
                Button { zoom = 1; pan = .zero; panOrigin = .zero } label: { Text("适合").font(.system(size: 9)) }
                Button { zoom = max(1, zoom / 1.5); if zoom == 1 { pan = .zero; panOrigin = .zero } } label: { Image(systemName: "minus") }
                Text("\(Int(zoom * 100))%").font(.system(size: 9, design: .monospaced)).frame(width: 37)
                Button { zoom = min(6, zoom * 1.5) } label: { Image(systemName: "plus") }
                Spacer()
                if model.pickingMaskColor {
                    Label("点击照片取样颜色", systemImage: "eyedropper")
                        .font(.system(size: 10)).foregroundColor(AtelierPalette.accent)
                } else if model.repairBrushActive {
                    Label(model.repairSamplingCloneSource
                          ? "点击照片选择仿制来源"
                          : "拖动涂抹修复/仿制（松开应用）",
                          systemImage: "bandage")
                        .font(.system(size: 10)).foregroundColor(AtelierPalette.accent)
                } else if model.liquifyBrushActive {
                    Label("拖动绘制液化笔迹（松开应用）", systemImage: "drop")
                        .font(.system(size: 10)).foregroundColor(AtelierPalette.accent)
                } else if model.maskEditMode {
                    Label("拖动选中蒙版的控制点", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10)).foregroundColor(AtelierPalette.accent)
                } else if model.drawingMask {
                    Label("拖动绘制\(model.maskKind.title)蒙版", systemImage: "pencil.tip.crop.circle")
                        .font(.system(size: 10)).foregroundColor(AtelierPalette.accent)
                } else if zoom > 1 {
                    Text("拖动平移 · 双击复位").font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                } else if compare {
                    Text("拖动查看前后变化").font(.system(size: 9)).foregroundColor(AtelierPalette.muted)
                }
            }.buttonStyle(.plain).foregroundColor(AtelierPalette.muted)
                .padding(.horizontal, 21).padding(.bottom, 11)
        }
    }

    private func photoContent(_ after: NSImage, size: CGSize) -> some View {
        let comparisonVisible = compare && !model.maskInteractionActive
            && !model.liquifyBrushActive && !model.repairBrushActive
        return ZStack(alignment: .topLeading) {
            Image(nsImage: after).resizable().frame(width: size.width, height: size.height)

            if model.showMaskCoverage, let coverage = model.maskOverlayImage {
                Image(nsImage: coverage).resizable().interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .opacity(min(1, max(0, model.maskOverlayOpacity)))
                    .allowsHitTesting(false)
            }

            if comparisonVisible, let before = model.beforeImage {
                Image(nsImage: before).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
                    .mask(alignment: .leading) { Rectangle().frame(width: size.width * split) }
                Rectangle().fill(.white.opacity(0.8)).frame(width: 1).offset(x: size.width * split)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 9, weight: .bold)).foregroundColor(.black.opacity(0.8))
                    .frame(width: 26, height: 26).background(.white.opacity(0.9)).clipShape(Circle())
                    .offset(x: size.width * split - 13, y: size.height / 2 - 13)
                HStack {
                    Text(model.comparisonLeftTitle); Spacer(); Text(model.comparisonRightTitle)
                }.font(.system(size: 9, weight: .medium)).foregroundColor(.white)
                    .padding(11).background(LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
            }

            if model.showMaskOverlay && (!comparisonVisible || model.maskInteractionActive) {
                maskOutlines(size)
            }
            if !draft.isEmpty { draftOutline(size) }
            if model.liquifyBrushActive { liquifyOverlay(size) }
            if model.repairBrushActive { repairOverlay(size) }
            if model.maskEditMode { geometryHandles(size) }
        }
        .frame(width: size.width, height: size.height)
        .background(.black)
        .shadow(color: .black.opacity(0.3), radius: 18, x: 0, y: 8)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { event in handleDragChanged(event, size: size) }
            .onEnded { event in handleDragEnded(event, size: size) })
        .simultaneousGesture(SpatialTapGesture().onEnded { event in handleTap(event.location, size: size) })
        .onTapGesture(count: 2) {
            if !model.maskInteractionActive {
                zoom = 1
                pan = .zero
                panOrigin = .zero
            }
        }
    }

    private func handleDragChanged(_ event: DragGesture.Value, size: CGSize) {
        guard !model.batchRunning else {
            cancelCanvasGesture()
            return
        }
        if dragAction == nil {
            dragAction = actionForDrag(startLocation: event.startLocation, size: size)
            dragStartPoint = normalized(event.startLocation, size: size)
        }
        guard let action = dragAction else { return }
        switch action {
        case .draw:
            updateDraft(at: event.location, size: size)
        case .liquify:
            let point = normalized(event.location, size: size)
            if !model.liquifyStrokeInProgress {
                model.beginLiquifyStroke(at: normalized(event.startLocation, size: size))
            }
            model.extendLiquifyStroke(to: point)
        case .repair:
            if model.repairSamplingCloneSource { break }
            let point = normalized(event.location, size: size)
            if !model.repairStrokeInProgress {
                model.beginRepairStroke(at: normalized(event.startLocation, size: size))
            }
            model.extendRepairStroke(to: point)
        case .moveStart(let id):
            moveGeometry(id: id, handle: .start, to: event.location, size: size)
        case .moveEnd(let id):
            moveGeometry(id: id, handle: .end, to: event.location, size: size)
        case .pan:
            pan = CGSize(width: panOrigin.width + event.translation.width, height: panOrigin.height + event.translation.height)
        case .compare:
            split = min(0.98, max(0.02, event.location.x / max(1, size.width)))
        case .ignore:
            break
        }
    }

    private func handleDragEnded(_ event: DragGesture.Value, size: CGSize) {
        if case .repair? = dragAction {
            if model.repairStrokeInProgress {
                model.extendRepairStroke(to: normalized(event.location, size: size))
                model.endRepairStroke()
            }
        } else if case .liquify? = dragAction {
            model.extendLiquifyStroke(to: normalized(event.location, size: size))
            model.endLiquifyStroke()
        } else if case .draw? = dragAction, !model.batchRunning, model.drawingMask {
            updateDraft(at: event.location, size: size)
            finishDraft()
        } else if case .pan? = dragAction {
            panOrigin = pan
        }
        draft = []
        dragAction = nil
        dragStartPoint = nil
    }

    private func actionForDrag(startLocation: CGPoint, size: CGSize) -> CanvasDragAction {
        if model.pickingMaskColor || model.batchRunning { return .ignore }
        if model.repairBrushActive { return .repair }
        if model.liquifyBrushActive { return .liquify }
        if model.maskEditMode {
            return geometryHandle(at: startLocation, size: size) ?? .ignore
        }
        if model.drawingMask { return .draw }
        if zoom > 1 { return .pan }
        if compare { return .compare }
        return .ignore
    }

    private func handleTap(_ location: CGPoint, size: CGSize) {
        guard !model.batchRunning else { return }
        let point = normalized(location, size: size)
        if model.pickingMaskColor {
            model.pickMaskColor(at: point)
            return
        }
        if model.repairBrushActive {
            if model.repairSamplingCloneSource {
                model.sampleRepairCloneSource(at: point)
            } else {
                // A click without drag is a valid one-point heal dot.
                model.beginRepairStroke(at: point)
                model.endRepairStroke()
            }
            return
        }
        guard model.drawingMask else { return }
        if model.maskKind == .brush {
            model.addMask(start: point, end: point, points: [point])
        }
    }

    private func updateDraft(at location: CGPoint, size: CGSize) {
        guard model.drawingMask, model.maskKind == .radial || model.maskKind == .linear || model.maskKind == .brush else { return }
        let point = normalized(location, size: size)
        let start = dragStartPoint ?? point
        if draft.isEmpty { draft = [start] }
        switch model.maskKind {
        case .brush:
            if let last = draft.last, pixelDistance(last, point, size: size) >= 1.5, draft.count < 4096 {
                draft.append(point)
            }
        case .radial, .linear:
            if draft.count == 1 { draft.append(point) }
            else if draft.count > 1 { draft[1] = point }
        case .luminance, .color:
            break
        }
    }

    private func finishDraft() {
        guard let first = draft.first else { return }
        let last = draft.last ?? first
        switch model.maskKind {
        case .brush:
            model.addMask(start: first, end: last, points: Array(draft.prefix(4096)))
        case .radial, .linear:
            guard draft.count > 1, hypot(first.x - last.x, first.y - last.y) > 0.008 else { return }
            model.addMask(start: first, end: last, points: [])
        case .luminance, .color:
            break
        }
    }

    private func moveGeometry(id: UUID, handle: GeometryHandle, to location: CGPoint, size: CGSize) {
        guard !model.batchRunning, let mask = model.adjustments.masks.first(where: { $0.id == id }) else { return }
        let point = normalized(location, size: size)
        var start = mask.start
        var end = mask.end
        if handle == .start, mask.kind == .radial {
            let deltaX = point.x - mask.start.x
            let deltaY = point.y - mask.start.y
            let clampedDeltaX = min(1 - max(mask.start.x, mask.end.x), max(-min(mask.start.x, mask.end.x), deltaX))
            let clampedDeltaY = min(1 - max(mask.start.y, mask.end.y), max(-min(mask.start.y, mask.end.y), deltaY))
            start = MaskPoint(x: mask.start.x + clampedDeltaX, y: mask.start.y + clampedDeltaY)
            end = MaskPoint(x: mask.end.x + clampedDeltaX, y: mask.end.y + clampedDeltaY)
        } else if handle == .start {
            start = point
        } else {
            end = point
        }
        model.moveMaskGeometry(id: id, start: start, end: end)
    }

    private func geometryHandle(at location: CGPoint, size: CGSize) -> CanvasDragAction? {
        guard let mask = model.adjustments.masks.first(where: { $0.id == model.selectedMask }),
              mask.kind == .radial || mask.kind == .linear else { return nil }
        let startDistance = screenDistance(location, to: mask.start, size: size)
        let endDistance = screenDistance(location, to: mask.end, size: size)
        let hitRadius: CGFloat = 18
        if startDistance <= hitRadius && startDistance <= endDistance { return .moveStart(mask.id) }
        if endDistance <= hitRadius { return .moveEnd(mask.id) }
        return nil
    }

    private func maskOutlines(_ size: CGSize) -> some View {
        Canvas { context, _ in
            for mask in model.adjustments.masks where mask.enabled {
                let selected = mask.id == model.selectedMask
                if mask.kind == .radial || mask.kind == .linear || mask.kind == .brush {
                    drawOutline(kind: mask.kind, start: mask.start, end: mask.end, points: mask.points,
                                radius: mask.radius, color: AtelierPalette.accent, selected: selected, size: size, in: &context)
                }
                for component in mask.components {
                    drawOutline(kind: component.kind, start: component.start, end: component.end, points: component.points,
                                radius: component.radius, color: componentColor(component.operation),
                                selected: selected, size: size, in: &context)
                }
            }
        }.allowsHitTesting(false)
    }

    private func draftOutline(_ size: CGSize) -> some View {
        Canvas { context, _ in
            guard let first = draft.first, let last = draft.last else { return }
            let color = drawColor(model.maskDrawMode)
            let path = outline(kind: model.maskKind, start: first, end: last, points: draft,
                               radius: model.brushRadius, size: size)
            if model.maskKind == .brush, draft.count > 1 {
                let width = max(1, CGFloat(model.brushRadius) * min(size.width, size.height) * 2)
                context.stroke(path, with: .color(color.opacity(0.24)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            } else {
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: [5, 3]))
            }
        }.allowsHitTesting(false)
    }

    /// Repair brush overlay: committed strokes in orange (heal) / cyan (clone),
    /// the in-flight draft in the accent colour, plus the clone source marker.
    /// The circle radius mirrors `RepairStroke.pixelRadius` (short image edge), so
    /// the guide matches the mask footprint instead of a per-axis ellipse.
    private func repairOverlay(_ size: CGSize) -> some View {
        Canvas { context, canvasSize in
            func drawStroke(_ stroke: RepairStroke, color: Color, opacity: Double) {
                let radius = max(1.5, CGFloat(stroke.radius) * min(canvasSize.width, canvasSize.height))
                guard let first = stroke.points.first else { return }
                var path = Path()
                path.move(to: screen(first, size: canvasSize))
                for point in stroke.points.dropFirst() {
                    path.addLine(to: screen(point, size: canvasSize))
                }
                context.stroke(path, with: .color(color.opacity(opacity)),
                               style: StrokeStyle(lineWidth: radius * 2,
                                                  lineCap: .round, lineJoin: .round,
                                                  dash: [radius * 2 + 2, radius * 2 + 2]))
                if stroke.points.count == 1 {
                    let center = screen(first, size: canvasSize)
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - radius,
                                                          y: center.y - radius,
                                                          width: radius * 2,
                                                          height: radius * 2)),
                                   with: .color(color.opacity(opacity)), lineWidth: 1)
                }
            }
            for stroke in model.repairBrushSettings.strokes {
                let color: Color = stroke.mode == .heal ? .orange : .cyan
                drawStroke(stroke, color: color, opacity: 0.45)
            }
            if let draft = model.repairDraftStroke {
                let color: Color = draft.mode == .heal ? .orange : .cyan
                drawStroke(draft, color: color, opacity: 0.95)
            }
            if let source = model.repairCloneSource {
                let center = screen(source, size: canvasSize)
                let radius: CGFloat = 7
                var cross = Path()
                cross.move(to: CGPoint(x: center.x - radius - 3, y: center.y))
                cross.addLine(to: CGPoint(x: center.x + radius + 3, y: center.y))
                cross.move(to: CGPoint(x: center.x, y: center.y - radius - 3))
                cross.addLine(to: CGPoint(x: center.x, y: center.y + radius + 3))
                context.stroke(cross, with: .color(.white.opacity(0.9)), lineWidth: 1.2)
                context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                      width: radius * 2, height: radius * 2)),
                               with: .color(.white.opacity(0.9)), lineWidth: 1.2)
            }
        }.allowsHitTesting(false)
    }

    /// Liquify brush overlay: committed strokes in white, the in-flight draft in
    /// the accent colour. Drawn in screen space with the brush radius; it is a
    /// guide only (the warp preview appears after the stroke is committed).
    private func liquifyOverlay(_ size: CGSize) -> some View {
        Canvas { context, _ in
            // The real warp footprint is an ellipse: radius is a fraction of each
            // image axis, so overlay radii must be (radius × width, radius × height)
            // — matching LiquifyBrushGeometry. A short-edge circle would mislead
            // users on non-square images.
            func drawStroke(_ stroke: WarpStroke, color: Color) {
                guard let first = stroke.points.first else { return }
                let radii = LiquifyBrushGeometry.pixelRadii(radius: stroke.radius,
                                                            imageSize: size)
                let radiusX = CGFloat(radii.x)
                let radiusY = CGFloat(radii.y)
                guard radiusX > 0.5, radiusY > 0.5 else { return }
                var path = Path()
                path.move(to: screen(first, size: size))
                for point in stroke.points.dropFirst() {
                    path.addLine(to: screen(point, size: size))
                }
                // Sample the centreline and fill ellipses so the translucent
                // footprint matches the warped region on 3:2 / 16:9 canvases.
                let centers = sampledScreenPoints(stroke.points, size: size,
                                                  spacing: max(3, min(radiusX, radiusY)))
                for center in centers {
                    let rect = CGRect(x: center.x - radiusX, y: center.y - radiusY,
                                      width: radiusX * 2, height: radiusY * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.16)))
                }
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                if stroke.points.count < 2 {
                    let center = screen(first, size: size)
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - radiusX,
                                                          y: center.y - radiusY,
                                                          width: radiusX * 2,
                                                          height: radiusY * 2)),
                                   with: .color(color.opacity(0.6)), lineWidth: 1)
                }
            }
            for stroke in model.liquifySettings.strokes {
                drawStroke(stroke, color: .white.opacity(0.55))
            }
            if let draft = model.liquifyDraftStroke {
                drawStroke(draft, color: AtelierPalette.accent)
            }
        }.allowsHitTesting(false)
    }

    /// Screen-space samples along a normalized-space polyline, used by the
    /// liquify overlay so the ellipse footprint follows the whole stroke.
    private func sampledScreenPoints(_ points: [MaskPoint], size: CGSize,
                                     spacing: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        let step = max(1, spacing)
        var result: [CGPoint] = [screen(first, size: size)]
        var previous = screen(first, size: size)
        for point in points.dropFirst() {
            let target = screen(point, size: size)
            let distance = hypot(target.x - previous.x, target.y - previous.y)
            if distance >= step {
                let count = max(1, Int((distance / step).rounded(.down)))
                for index in 1...count {
                    let t = CGFloat(index) / CGFloat(count + 1)
                    result.append(CGPoint(x: previous.x + (target.x - previous.x) * t,
                                          y: previous.y + (target.y - previous.y) * t))
                }
            }
            result.append(target)
            previous = target
        }
        return result
    }

    private func geometryHandles(_ size: CGSize) -> some View {
        Canvas { context, _ in
            guard let mask = model.adjustments.masks.first(where: { $0.id == model.selectedMask }),
                  mask.kind == .radial || mask.kind == .linear else { return }
            drawHandle(mask.start, color: AtelierPalette.accent, size: size, in: &context)
            drawHandle(mask.end, color: .white, size: size, in: &context)
        }.allowsHitTesting(false)
    }

    private func drawHandle(_ point: MaskPoint, color: Color, size: CGSize, in context: inout GraphicsContext) {
        let center = screen(point, size: size)
        let outer = CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)
        let inner = CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
        context.fill(Path(ellipseIn: outer), with: .color(.black.opacity(0.85)))
        context.stroke(Path(ellipseIn: outer), with: .color(color), lineWidth: 1.5)
        context.fill(Path(ellipseIn: inner), with: .color(color))
    }

    private func drawOutline(kind: MaskKind, start: MaskPoint, end: MaskPoint, points: [MaskPoint], radius: Double,
                             color: Color, selected: Bool, size: CGSize, in context: inout GraphicsContext) {
        let path = outline(kind: kind, start: start, end: end, points: points, radius: radius, size: size)
        let lineWidth: CGFloat = selected ? 1.7 : 1.1
        if kind == .brush, points.count > 1 {
            let width = max(1, CGFloat(radius) * min(size.width, size.height) * 2)
            context.stroke(path, with: .color(color.opacity(selected ? 0.24 : 0.15)),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(color.opacity(selected ? 0.95 : 0.65)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: [4, 3]))
        } else {
            context.stroke(path, with: .color(color.opacity(selected ? 0.95 : 0.58)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: [5, 4]))
        }
    }

    private func outline(kind: MaskKind, start: MaskPoint, end: MaskPoint, points: [MaskPoint], radius: Double, size: CGSize) -> Path {
        let first = screen(start, size: size)
        let last = screen(end, size: size)
        var path = Path()
        switch kind {
        case .radial:
            let rx = max(3, abs(last.x - first.x))
            let ry = max(3, abs(last.y - first.y))
            path.addEllipse(in: CGRect(x: first.x - rx, y: first.y - ry, width: 2 * rx, height: 2 * ry))
        case .linear:
            path.move(to: first)
            path.addLine(to: last)
            let dx = last.x - first.x
            let dy = last.y - first.y
            let length = max(1, hypot(dx, dy))
            let vx = -dy / length * 30
            let vy = dx / length * 30
            path.move(to: CGPoint(x: first.x - vx, y: first.y - vy))
            path.addLine(to: CGPoint(x: first.x + vx, y: first.y + vy))
            path.move(to: CGPoint(x: last.x - vx, y: last.y - vy))
            path.addLine(to: CGPoint(x: last.x + vx, y: last.y + vy))
        case .brush:
            if points.count == 1, let point = points.first {
                let center = screen(point, size: size)
                let brushRadius = max(1, CGFloat(radius) * min(size.width, size.height))
                path.addEllipse(in: CGRect(x: center.x - brushRadius, y: center.y - brushRadius,
                                           width: brushRadius * 2, height: brushRadius * 2))
            } else if let point = points.first {
                path.move(to: screen(point, size: size))
                for point in points.dropFirst() { path.addLine(to: screen(point, size: size)) }
            }
        case .luminance, .color:
            break
        }
        return path
    }

    private func componentColor(_ operation: MaskCombineMode) -> Color {
        switch operation {
        case .add: return AtelierPalette.accent
        case .subtract: return .red
        case .intersect: return .purple
        }
    }

    private func drawColor(_ mode: MaskDrawMode) -> Color {
        switch mode {
        case .new, .add: return AtelierPalette.accent
        case .subtract: return .red
        case .intersect: return .purple
        }
    }

    private func cancelCanvasGesture() {
        draft = []
        dragAction = nil
        dragStartPoint = nil
        panOrigin = pan
        // A cancelled drag must not leave a half-finished liquify or repair
        // stroke that would keep suppressing previews / block the next stroke.
        model.cancelLiquifyStroke()
        model.cancelRepairStroke()
    }

    private enum GeometryHandle: Equatable { case start, end }

    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 25).stroke(AtelierPalette.accent.opacity(0.11), lineWidth: 1).frame(width: 100, height: 100).rotationEffect(.degrees(12))
                RoundedRectangle(cornerRadius: 20).fill(AtelierPalette.panel).frame(width: 82, height: 82)
                Image(systemName: "camera.aperture").font(.system(size: 39, weight: .ultraLight)).foregroundColor(AtelierPalette.accent.opacity(0.85))
            }.padding(.bottom, 30)
            Text("留住光，也留住真实的颜色。")
                .font(.system(size: 20, weight: .light, design: .serif)).foregroundColor(.white.opacity(0.9))
            Text("基础校正、风格适配与局部微调，融于同一道流程。")
                .font(.system(size: 11)).foregroundColor(AtelierPalette.muted).padding(.top, 12)
            Button { model.chooseInput() } label: {
                Label("选择照片文件夹", systemImage: "folder.badge.plus")
                    .font(.system(size: 11)).foregroundColor(AtelierPalette.accent)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(AtelierPalette.accent.opacity(0.3)))
            }.buttonStyle(.plain).padding(.top, 28)
            HStack(spacing: 18) {
                Label("本地处理", systemImage: "desktopcomputer")
                Label("保护原片", systemImage: "shield")
                Label("高位深导出", systemImage: "square.stack.3d.up")
            }.font(.system(size: 9)).foregroundColor(AtelierPalette.muted.opacity(0.8)).padding(.top, 35)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fit(_ image: CGSize, in area: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return area }
        let scale = min(area.width / image.width, area.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    private func normalized(_ point: CGPoint, size: CGSize) -> MaskPoint {
        let x = Double(point.x / max(1, size.width))
        let y = Double(point.y / max(1, size.height))
        return .init(x: min(1, max(0, x)), y: min(1, max(0, 1 - y)))
    }

    private func screen(_ point: MaskPoint, size: CGSize) -> CGPoint {
        .init(x: point.x * size.width, y: (1 - point.y) * size.height)
    }

    private func pixelDistance(_ first: MaskPoint, _ second: MaskPoint, size: CGSize) -> CGFloat {
        hypot(CGFloat(first.x - second.x) * size.width, CGFloat(first.y - second.y) * size.height)
    }

    private func screenDistance(_ point: CGPoint, to maskPoint: MaskPoint, size: CGSize) -> CGFloat {
        let target = screen(maskPoint, size: size)
        return hypot(point.x - target.x, point.y - target.y)
    }
}

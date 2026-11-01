import SwiftUI
import PhotoCore

struct PhotoCanvas: View {
    @ObservedObject var model: AppModel
    let compare: Bool
    @Binding var split: Double
    @State private var draft: [MaskPoint] = []
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
                    VStack {
                        Spacer()
                        HStack(spacing: 5) {
                            Button { zoom = 1; pan = .zero; panOrigin = .zero } label: { Text("适合").font(.system(size: 9)) }
                            Button { zoom = max(1, zoom / 1.5); if zoom == 1 { pan = .zero; panOrigin = .zero } } label: { Image(systemName: "minus") }
                            Text("\(Int(zoom * 100))%").font(.system(size: 9, design: .monospaced)).frame(width: 37)
                            Button { zoom = min(6, zoom * 1.5) } label: { Image(systemName: "plus") }
                            Spacer()
                            if model.drawingMask {
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
        .onChange(of: model.selectedID) { _ in zoom = 1; pan = .zero; panOrigin = .zero; draft = [] }
        .onChange(of: model.drawingMask) { drawing in
            draft = []
            if drawing { zoom = 1; pan = .zero; panOrigin = .zero }
        }
    }

    private func photoContent(_ after: NSImage, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: after).resizable().frame(width: size.width, height: size.height)
            if compare && !model.drawingMask, let before = model.beforeImage {
                Image(nsImage: before).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
                    .mask(alignment: .leading) { Rectangle().frame(width: size.width * split) }
                Rectangle().fill(.white.opacity(0.8)).frame(width: 1).offset(x: size.width * split)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 9, weight: .bold)).foregroundColor(.black.opacity(0.8))
                    .frame(width: 26, height: 26).background(.white.opacity(0.9)).clipShape(Circle())
                    .offset(x: size.width * split - 13, y: size.height / 2 - 13)
                HStack {
                    Text("原片"); Spacer(); Text("调色后")
                }.font(.system(size: 9, weight: .medium)).foregroundColor(.white)
                    .padding(11).background(LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
            }
            if model.showMaskOverlay && (!compare || model.drawingMask) {
                maskOutlines(size)
            }
            if !draft.isEmpty { draftOutline(size) }
        }
        .frame(width: size.width, height: size.height)
        .background(.black)
        .shadow(color: .black.opacity(0.3), radius: 18, x: 0, y: 8)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { event in
                if model.drawingMask {
                    let point = normalized(event.location, size: size)
                    if draft.isEmpty { draft = [normalized(event.startLocation, size: size)] }
                    if model.maskKind == .brush {
                        if draft.count < 4096 { draft.append(point) }
                    } else if draft.count == 1 { draft.append(point) }
                    else { draft[1] = point }
                } else if zoom > 1 {
                    pan = CGSize(width: panOrigin.width + event.translation.width, height: panOrigin.height + event.translation.height)
                } else if compare {
                    split = min(0.98, max(0.02, event.location.x / size.width))
                }
            }
            .onEnded { _ in
                if model.drawingMask, let first = draft.first, let last = draft.last, draft.count >= 2 {
                    let distance = hypot(first.x - last.x, first.y - last.y)
                    if distance > 0.008 || (model.maskKind == .brush && draft.count > 2) {
                        model.addMask(start: first, end: last, points: model.maskKind == .brush ? draft : [])
                    }
                    draft = []
                } else { panOrigin = pan }
            })
        .onTapGesture(count: 2) { zoom = 1; pan = .zero; panOrigin = .zero }
    }

    private func maskOutlines(_ size: CGSize) -> some View {
        Canvas { context, _ in
            for mask in model.adjustments.masks where mask.enabled {
                let selected = mask.id == model.selectedMask
                let path = outline(kind: mask.kind, start: mask.start, end: mask.end, points: mask.points, size: size)
                context.stroke(path, with: .color(selected ? AtelierPalette.accent : .white.opacity(0.55)),
                               style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: [5, 4]))
                let center = screen(mask.start, size: size)
                context.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(AtelierPalette.accent))
            }
        }.allowsHitTesting(false)
    }

    private func draftOutline(_ size: CGSize) -> some View {
        Canvas { context, _ in
            guard let first = draft.first, let last = draft.last else { return }
            let path = outline(kind: model.maskKind, start: first, end: last, points: draft, size: size)
            context.stroke(path, with: .color(AtelierPalette.accent), style: .init(lineWidth: model.maskKind == .brush ? 7 : 1.5, lineCap: .round, lineJoin: .round))
        }.allowsHitTesting(false)
    }

    private func outline(kind: MaskKind, start: MaskPoint, end: MaskPoint, points: [MaskPoint], size: CGSize) -> Path {
        let first = screen(start, size: size), last = screen(end, size: size)
        var path = Path()
        switch kind {
        case .radial:
            let rx = max(3, abs(last.x - first.x)), ry = max(3, abs(last.y - first.y))
            path.addEllipse(in: CGRect(x: first.x - rx, y: first.y - ry, width: 2 * rx, height: 2 * ry))
        case .linear:
            path.move(to: first); path.addLine(to: last)
            let dx = last.x - first.x, dy = last.y - first.y, length = max(1, hypot(dx, dy))
            let vx = -dy / length * 30, vy = dx / length * 30
            path.move(to: .init(x: first.x - vx, y: first.y - vy)); path.addLine(to: .init(x: first.x + vx, y: first.y + vy))
            path.move(to: .init(x: last.x - vx, y: last.y - vy)); path.addLine(to: .init(x: last.x + vx, y: last.y + vy))
        case .brush:
            if let point = points.first { path.move(to: screen(point, size: size)) }
            for point in points.dropFirst() { path.addLine(to: screen(point, size: size)) }
        }
        return path
    }

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
}

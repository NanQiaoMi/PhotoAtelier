import AppKit
import PhotoCore
import SwiftUI

/// Horizontal filmstrip shelf displaying live photo style thumbnails for all LUTs.
/// Features:
/// - Real-time rendered photo thumbnails for every style preset
/// - Category filter pills (全部 / 人像 / 电影 / 自然 / 风光 / 黑白 / 自定义)
/// - Inline style intensity slider and recommended strength badge
/// - One-click collapsible / expandable filmstrip for maximizing canvas workspace
/// - Hover elevation, active badge, and readable gradient scrim
struct PresetShelfView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var previews: StylePreviewController
    @AppStorage("isPresetShelfExpanded") private var isExpanded: Bool = true
    @State private var hoveredID: String? = nil
    @State private var selectedCategory: String = "all"

    private struct CategoryItem: Identifiable {
        let id: String
        let title: String
        let count: Int
    }

    private var categoryOptions: [CategoryItem] {
        var items: [CategoryItem] = [
            CategoryItem(id: "all", title: "全部", count: model.lutOptions.count)
        ]
        let groups: [(LUTPresetGroup, String)] = [
            (.portrait, "人像"),
            (.cinematic, "电影"),
            (.natural, "自然"),
            (.landscape, "风光"),
            (.monochrome, "黑白")
        ]
        for (g, title) in groups {
            let count = model.lutOptions.filter { $0.group == g }.count
            if count > 0 {
                items.append(CategoryItem(id: g.rawValue, title: title, count: count))
            }
        }
        let customCount = model.lutOptions.filter { $0.path != nil }.count
        if customCount > 0 {
            items.append(CategoryItem(id: "custom", title: "自定义", count: customCount))
        }
        return items
    }

    private var filteredOptions: [LUTOption] {
        if selectedCategory == "all" { return model.lutOptions }
        if selectedCategory == "custom" { return model.lutOptions.filter { $0.path != nil } }
        return model.lutOptions.filter { $0.group?.rawValue == selectedCategory }
    }

    private var activeOptionName: String {
        model.lutOptions.first(where: { $0.id == model.selectedLUT })?.name ?? "原色"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 7 : 0) {
            headerBar

            if isExpanded {
                categoryFilterRow
                filmstrip
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, isExpanded ? 10 : 7)
        .background(AtelierPalette.panel.opacity(0.92))
        .onAppear {
            model.requestStylePreviewsIfNeeded()
        }
        .onChange(of: model.styleReference) { _ in
            model.requestStylePreviewsIfNeeded()
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(AtelierPalette.muted)
                        .frame(width: 10)
                    Text("色彩风格")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                }
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "收起色彩风格栏，腾出更大画布空间" : "展开色彩风格栏，预览逐图效果")

            Text("\(model.lutOptions.count)")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(AtelierPalette.muted)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(AtelierPalette.raised))
                .help("内置与导入的色彩风格总数")

            if !isExpanded {
                HStack(spacing: 4) {
                    Text("当前:")
                        .font(.system(size: 9))
                        .foregroundColor(AtelierPalette.muted)
                    Text(activeOptionName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(AtelierPalette.accent)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AtelierPalette.raised)
                .clipShape(Capsule())
            }

            // Inline Intensity Slider when a style is selected
            if isExpanded && model.selectedLUT != "none" {
                HStack(spacing: 6) {
                    Text("浓度")
                        .font(.system(size: 9.5))
                        .foregroundColor(AtelierPalette.muted)
                    Slider(value: $model.adjustments.lutIntensity, in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 75)
                    Text("\(Int((model.adjustments.lutIntensity * 100).rounded()))%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(AtelierPalette.accent)
                        .frame(width: 28, alignment: .leading)

                    if let recommended = model.selectedOption?.recommendedIntensity,
                       abs(recommended - model.adjustments.lutIntensity) > 0.03 {
                        Button {
                            model.adoptRecommendedLUTIntensity()
                        } label: {
                            Text("推荐 \(Int((recommended * 100).rounded()))%")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(AtelierPalette.accent)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(AtelierPalette.accent.opacity(0.18))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("一键采用该风格推荐浓度")
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.black.opacity(0.22))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(.leading, 4)
            }

            if previews.busy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("渲染缩图 \(previews.completed)/\(previews.total)")
                        .font(.system(size: 8.5))
                        .foregroundColor(AtelierPalette.muted)
                }
                .padding(.leading, 6)
            }

            Spacer(minLength: 8)

            Button { model.showStyleBrowser = true } label: {
                HStack(spacing: 3) {
                    Text("风格库全览")
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(AtelierPalette.accent)
                .lineLimit(1).fixedSize()
            }
            .buttonStyle(.plain)
            .help("打开风格库全屏对比全部 \(model.lutOptions.count) 种色彩风格")
        }
    }

    // MARK: - Category Filter Row

    private var categoryFilterRow: some View {
        HStack(spacing: 5) {
            ForEach(categoryOptions) { cat in
                let isSel = selectedCategory == cat.id
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedCategory = cat.id
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(cat.title)
                        Text("\(cat.count)")
                            .font(.system(size: 7.5, design: .monospaced))
                            .foregroundColor(isSel ? AtelierPalette.background.opacity(0.85) : AtelierPalette.muted)
                    }
                    .font(.system(size: 9, weight: isSel ? .bold : .medium))
                    .foregroundColor(isSel ? AtelierPalette.background : .white.opacity(0.85))
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(isSel ? AtelierPalette.accent : AtelierPalette.raised.opacity(0.7))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Filmstrip ScrollView

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(filteredOptions.enumerated()), id: \.element.id) { index, option in
                        Button {
                            model.selectLUT(option.id)
                        } label: {
                            styleCard(option)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.batchRunning)
                        .id(option.id)
                        .onHover { isHovered in
                            hoveredID = isHovered ? option.id : nil
                        }
                    }
                    Color.clear.frame(width: 16, height: 1)
                }
                .padding(.vertical, 2)
            }
            .onChange(of: model.selectedLUT) { selected in
                guard filteredOptions.contains(where: { $0.id == selected }) else { return }
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(selected, anchor: .center) }
            }
        }
        .overlay(alignment: .trailing) {
            LinearGradient(
                colors: [AtelierPalette.panel.opacity(0), AtelierPalette.panel.opacity(0.92)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: 18).allowsHitTesting(false)
        }
    }

    // MARK: - Single Style Thumbnail Card

    private func styleCard(_ option: LUTOption) -> some View {
        let isSelected = model.selectedLUT == option.id
        let isHovered = hoveredID == option.id

        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                // Background placeholder with subtle mood color
                RoundedRectangle(cornerRadius: 6)
                    .fill(cardPlaceholderColor(option))

                // Rendered photo thumbnail
                if let img = previews.images[option.id] {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 102, height: 64)
                        .clipped()
                } else if previews.busy {
                    ZStack {
                        Color.black.opacity(0.3)
                        ProgressView().controlSize(.mini)
                    }
                } else {
                    ZStack {
                        Color.black.opacity(0.2)
                        Image(systemName: option.id == "none" ? "circle.lefthalf.filled" : "camera.filters")
                            .font(.system(size: 16, weight: .ultraLight))
                            .foregroundColor(Color.white.opacity(0.6))
                    }
                }

                // Gradient scrim for caption legibility
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.78)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 26)
                .frame(maxHeight: .infinity, alignment: .bottom)

                // Style name text inside the card
                Text(option.name)
                    .font(.system(size: 9.5, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? AtelierPalette.accent : .white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 3)

                // Selection checkmark
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(AtelierPalette.accent)
                        .font(.system(size: 11))
                        .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(4)
                }
            }
            .frame(width: 102, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isSelected ? AtelierPalette.accent : (isHovered ? Color.white.opacity(0.4) : Color.white.opacity(0.12)),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .shadow(color: isSelected ? AtelierPalette.accent.opacity(0.35) : .clear, radius: 4)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .frame(width: 102)
        .help("\(option.name) · \(option.detail)")
    }

    private func cardPlaceholderColor(_ option: LUTOption) -> Color {
        guard let group = option.group else { return AtelierPalette.raised }
        switch group {
        case .portrait: return Color(red: 0.16, green: 0.13, blue: 0.14)
        case .cinematic: return Color(red: 0.12, green: 0.14, blue: 0.16)
        case .natural: return Color(red: 0.14, green: 0.15, blue: 0.13)
        case .landscape: return Color(red: 0.12, green: 0.15, blue: 0.16)
        case .monochrome: return Color(red: 0.14, green: 0.14, blue: 0.14)
        }
    }
}

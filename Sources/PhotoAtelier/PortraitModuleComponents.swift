import AppKit
import PhotoCore
import SwiftUI

// MARK: - Portrait Card Component

/// A polished, modern card container for each portrait retouching module.
/// Features:
/// - Title & Icon
/// - Active dot indicator (golden glow when settings are non-neutral)
/// - Single-click 👁️ bypass toggle
/// - Hold-to-blink 👁️ instant visual delta comparison
/// - ⟲ Single-module reset button
struct PortraitCard<Content: View>: View {
    let module: PortraitModuleType
    @ObservedObject var model: AppModel
    let content: Content

    @State private var isHoldingBypass = false

    init(module: PortraitModuleType, model: AppModel, @ViewBuilder content: () -> Content) {
        self.module = module
        self.model = model
        self.content = content()
    }

    private var isActive: Bool {
        model.isPortraitModuleActive(module)
    }

    private var isBypassed: Bool {
        model.isPortraitModuleBypassed(module)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .opacity(isBypassed ? 0.35 : 1.0)
                .allowsHitTesting(!isBypassed)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isBypassed
                        ? Color.orange.opacity(0.4)
                        : (isActive ? AtelierPalette.accent.opacity(0.35) : Color.white.opacity(0.06)),
                    lineWidth: 1
                )
        )
        .padding(.bottom, 10)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: module.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? AtelierPalette.accent : .white.opacity(0.7))

            Text(module.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isActive ? .white : .white.opacity(0.85))

            if isActive {
                Circle()
                    .fill(isBypassed ? Color.orange : AtelierPalette.accent)
                    .frame(width: 5, height: 5)
                    .help(isBypassed ? "已临时旁路此效果" : "当前模块已生效微调")
            }

            Spacer(minLength: 4)

            if isBypassed {
                Text("已旁路")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.18))
                    .clipShape(Capsule())
            }

            // 👁️ Bypass & Hold-to-Preview Button
            Button {
                model.togglePortraitModuleBypass(module)
            } label: {
                Image(systemName: isBypassed ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 10))
                    .foregroundColor(
                        isBypassed
                            ? .orange
                            : (isActive ? AtelierPalette.accent : .white.opacity(0.35))
                    )
                    .padding(4)
                    .background(
                        (isBypassed || isHoldingBypass)
                            ? Color.orange.opacity(0.2)
                            : Color.white.opacity(0.05)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("点击临时停用/启用此模块效果；按住不放可瞬时比对关闭效果")
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isHoldingBypass {
                            isHoldingBypass = true
                            model.setPortraitModuleBypass(module, bypassed: true)
                        }
                    }
                    .onEnded { _ in
                        if isHoldingBypass {
                            isHoldingBypass = false
                            model.setPortraitModuleBypass(module, bypassed: false)
                        }
                    }
            )

            // ⟲ Single-module reset button
            if isActive {
                Button {
                    model.resetPortraitModule(module)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(4)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("将当前模块恢复为中性默认值")
            }
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Category Tab Bar

/// Clean, horizontal segmented pill bar for the 6 scenario categories.
struct PortraitCategoryTabBar: View {
    @Binding var selectedCategory: PortraitCategory
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(PortraitCategory.allCases) { category in
                    categoryPill(category)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
    }

    private func categoryPill(_ category: PortraitCategory) -> some View {
        let isSelected = (selectedCategory == category)
        let hasActiveModules = model.hasActiveModules(in: category)
        let isBypassedInside = model.hasBypassedModules(in: category)

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedCategory = category
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: category.icon)
                    .font(.system(size: 9))

                Text(category.title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))

                if hasActiveModules {
                    Circle()
                        .fill(isBypassedInside ? Color.orange : (isSelected ? AtelierPalette.background : AtelierPalette.accent))
                        .frame(width: 4, height: 4)
                }
            }
            .foregroundColor(isSelected ? AtelierPalette.background : .white.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isSelected
                    ? AtelierPalette.accent
                    : (hasActiveModules ? Color.white.opacity(0.1) : Color.white.opacity(0.04))
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.clear : (hasActiveModules ? AtelierPalette.accent.opacity(0.4) : Color.white.opacity(0.08)),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Active HUD Component

/// Interactive top banner displaying chips of currently modified portrait effects.
struct PortraitActiveHUD: View {
    @ObservedObject var model: AppModel
    @Binding var selectedCategory: PortraitCategory

    private var activeModules: [PortraitModuleType] {
        model.activePortraitModules
    }

    var body: some View {
        if !activeModules.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text("已启用效果 (\(activeModules.count))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(AtelierPalette.accent)

                    Spacer(minLength: 0)

                    if !model.portraitBypassedModules.isEmpty {
                        Button("恢复全部旁路") {
                            model.clearAllPortraitBypasses()
                        }
                        .font(.system(size: 8.5))
                        .buttonStyle(.plain)
                        .foregroundColor(.orange)
                    }

                    Button("全部复位") {
                        model.resetAllPortraitAdjustments()
                    }
                    .font(.system(size: 8.5))
                    .buttonStyle(.plain)
                    .foregroundColor(AtelierPalette.muted)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(activeModules) { mod in
                            chip(for: mod)
                        }
                    }
                }
            }
            .padding(8)
            .background(Color.black.opacity(0.24))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(AtelierPalette.accent.opacity(0.25), lineWidth: 1)
            )
            .padding(.bottom, 10)
        }
    }

    private func chip(for module: PortraitModuleType) -> some View {
        let isBypassed = model.isPortraitModuleBypassed(module)

        return HStack(spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedCategory = module.category
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: module.icon)
                        .font(.system(size: 7.5))
                    Text(module.shortTitle)
                        .font(.system(size: 8.5, weight: .medium))
                }
            }
            .buttonStyle(.plain)

            // Quick bypass toggle in chip
            Button {
                model.togglePortraitModuleBypass(module)
            } label: {
                Image(systemName: isBypassed ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 7.5))
                    .foregroundColor(isBypassed ? .orange : AtelierPalette.accent)
            }
            .buttonStyle(.plain)
            .help(isBypassed ? "点击恢复效果" : "点击旁路此效果")
        }
        .foregroundColor(isBypassed ? .orange : .white.opacity(0.85))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            isBypassed ? Color.orange.opacity(0.2) : Color.white.opacity(0.08)
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(isBypassed ? Color.orange.opacity(0.5) : Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

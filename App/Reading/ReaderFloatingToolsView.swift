import ReaderDomain
import SwiftUI

@MainActor
struct ReaderFloatingToolsView: View {
    let state: ReadingToolsPresentation
    let metrics: ReaderToolMetrics
    let appearance: ReaderToolAppearance
    let directoryAvailable: Bool
    let settingsAvailable: Bool
    let exitSaveFailed: Bool
    let rememberFocus: @MainActor (String) -> Void
    let open: @MainActor (ReadingToolPanel) -> Void
    @AccessibilityFocusState.Binding var focusedControl: String?
    // nil preserves the TXT edge dock and its existing memberwise call sites.
    var chapterContext: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var trayExpanded = false

    private var visible: Bool { state.visible && state.panel == nil }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if visible {
                if let chapterContext {
                    chapterPanel(chapterContext)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: ReaderMotion.hiddenTravel)))
                } else {
                    edgeDock
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .foregroundStyle(appearance.foreground).tint(appearance.accent)
        .animation(reduceMotion ? nil : ReaderMotion.toolVisibility, value: visible)
        .allowsHitTesting(visible && state.canInteract).accessibilityHidden(!visible)
    }

    private func chapterPanel(_ context: String) -> some View {
        let maximumHeight: CGFloat = metrics.compactHeight ? 144 : (dynamicType.isAccessibilitySize ? 300 : 240)
        return ViewThatFits(in: .vertical) {
            chapterPanelContent(context)
            ScrollView(.vertical) {
                chapterPanelContent(context)
            }
            .frame(height: maximumHeight)
            .accessibilityIdentifier("reader.tools.scroll")
        }
        .frame(maxWidth: ReaderVisualStyle.toolPanelMaximumWidth, maxHeight: maximumHeight)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(appearance.elevatedSurface)
                .shadow(color: appearance.shadow, radius: 14, x: 0, y: 5)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.9), lineWidth: 0.85)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("reader.tools.chapterPanel")
    }

    @ViewBuilder
    private func chapterPanelContent(_ context: String) -> some View {
        let stacked = dynamicType.isAccessibilitySize || (dynamicType >= .xxLarge && !metrics.compactHeight)
        if stacked {
            VStack(alignment: .leading, spacing: 10) {
                chapterSummary(context)
                if dynamicType.isAccessibilitySize {
                    VStack(spacing: 6) {
                        panelDirectoryButton(fillsWidth: true)
                        panelSettingsButton(fillsWidth: true)
                    }
                } else {
                    HStack(spacing: 8) {
                        panelDirectoryButton(fillsWidth: true)
                        panelSettingsButton(fillsWidth: true)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, metrics.compactHeight ? 10 : 12)
        } else {
            HStack(alignment: .center, spacing: 10) {
                chapterSummary(context)
                HStack(spacing: 6) {
                    panelDirectoryButton(fillsWidth: false)
                    panelSettingsButton(fillsWidth: false)
                }
                .layoutPriority(1)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, metrics.compactHeight ? 6 : 8)
        }
    }

    private func chapterSummary(_ context: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(appearance.accent)
                .frame(width: 3, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                if !metrics.compactHeight && !dynamicType.isAccessibilitySize {
                    Text("当前章节")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(appearance.secondary)
                        .accessibilityHidden(true)
                }
                Text(context)
                    .font(dynamicType.isAccessibilitySize
                          ? .system(.body, design: .serif).weight(.semibold)
                          : .system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(appearance.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("当前章节，\(context)")
                    .accessibilityIdentifier("reader.tools.chapterContext")
            }
        }
    }

    private func panelDirectoryButton(fillsWidth: Bool) -> some View {
        panelButton("目录", symbol: "list.bullet", panel: .directory, key: "directory",
                    available: directoryAvailable, fillsWidth: fillsWidth)
    }

    private func panelSettingsButton(fillsWidth: Bool) -> some View {
        panelButton("阅读设置", symbol: "textformat.size", panel: .settings, key: "settings",
                    available: settingsAvailable, fillsWidth: fillsWidth)
            .accessibilityHint("调整文字、行距和阅读背景")
    }

    private func panelButton(_ title: String, symbol: String, panel: ReadingToolPanel, key: String,
                             available: Bool, fillsWidth: Bool) -> some View {
        Button {
            guard visible, state.canInteract, available, !exitSaveFailed else { return }
            open(panel)
        } label: {
            Label(title, systemImage: symbol)
                .font(dynamicType.isAccessibilitySize ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                .imageScale(.medium)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minWidth: 44, maxWidth: fillsWidth ? .infinity : nil, minHeight: metrics.controlHeight)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, role: .primary, cornerRadius: 14))
        .disabled(!available || exitSaveFailed || !state.canInteract)
        .accessibilityIdentifier("reader.tools.\(key)")
        .accessibilityFocused($focusedControl, equals: key)
    }

    private var edgeDock: some View {
        ZStack(alignment: .bottomTrailing) {
            if trayExpanded {
                expandedDock
                    .transaction { $0.animation = nil }
                    .transition(.opacity)
            } else {
                dockSurface(cornerRadius: 26) { expandButton }
                    .transaction { $0.animation = nil }
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(reduceMotion ? nil : ReaderMotion.toolVisibility, value: trayExpanded)
        // The inactive controls are absent, not transparent retained AX/hit-test targets.
        // The stable outer view still owns tray state; no reader/model identity changes.
    }

    private var expandedDock: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                dockSurface(cornerRadius: 24) {
                    HStack(spacing: 4) { directoryButton; settingsButton; collapseButton }
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            dockSurface(cornerRadius: 22) {
                ScrollView(.vertical) {
                    VStack(spacing: 4) { directoryButton; settingsButton; collapseButton }
                }
                .frame(height: min(metrics.compactHeight ? 88 : 220, metrics.controlHeight * 3 + 8))
                .accessibilityIdentifier("reader.tools.scroll")
            }
        }
    }

    private var expandButton: some View {
        Button {
            guard visible, state.canInteract, !exitSaveFailed else { return }
            trayExpanded = true
            restoreFocus(to: directoryAvailable ? "directory" : (settingsAvailable ? "settings" : "dock.collapse"))
        } label: {
            Label("阅读工具", systemImage: "slider.horizontal.3")
                .font(dynamicType.isAccessibilitySize ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                .imageScale(.medium)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .frame(minWidth: 44, minHeight: metrics.controlHeight)
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, role: .primary, cornerRadius: 22))
        .disabled(exitSaveFailed || !state.canInteract)
        .accessibilityIdentifier("reader.tools.expand")
        .accessibilityHint("展开目录和排版工具")
        .accessibilityFocused($focusedControl, equals: "dock.expand")
    }

    private var collapseButton: some View {
        Button {
            guard visible, state.canInteract, !exitSaveFailed else { return }
            trayExpanded = false
            restoreFocus(to: "dock.expand")
        } label: {
            Label("收起", systemImage: "chevron.right")
                .font(dynamicType.isAccessibilitySize ? .body.weight(.medium) : .subheadline.weight(.medium))
                .imageScale(.medium)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .frame(minWidth: 44, minHeight: metrics.controlHeight)
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.secondary, cornerRadius: 18))
        .disabled(exitSaveFailed || !state.canInteract)
        .accessibilityIdentifier("reader.tools.collapse")
        .accessibilityFocused($focusedControl, equals: "dock.collapse")
    }

    private func restoreFocus(to target: String) {
        rememberFocus(target)
        focusedControl = target
    }

    private var directoryButton: some View {
        toolButton("目录", symbol: "list.bullet", panel: .directory, key: "directory")
            .disabled(!directoryAvailable || exitSaveFailed || !state.canInteract)
    }

    private var settingsButton: some View {
        toolButton("排版", symbol: "textformat.size", panel: .settings, key: "settings")
            .disabled(!settingsAvailable || exitSaveFailed || !state.canInteract)
            .accessibilityHint("调整字号、行距和阅读背景，立即应用并保存")
    }

    private func toolButton(_ title: String, symbol: String, panel: ReadingToolPanel, key: String) -> some View {
        Button { open(panel) } label: {
            Label(title, systemImage: symbol)
                .font(dynamicType.isAccessibilitySize ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                .imageScale(.medium)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .frame(minWidth: 44, minHeight: metrics.controlHeight)
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground, role: .primary, cornerRadius: 18))
        .accessibilityIdentifier("reader.tools.\(key)")
        .accessibilityFocused($focusedControl, equals: key)
    }

    private func dockSurface<Content: View>(cornerRadius: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(5)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(appearance.elevatedSurface)
                    .shadow(color: appearance.shadow, radius: 12, x: 0, y: 4)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(appearance.edge.opacity(0.9), lineWidth: 0.85)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

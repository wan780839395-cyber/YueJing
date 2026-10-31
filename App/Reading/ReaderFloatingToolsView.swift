import ReaderDomain
import SwiftUI

@MainActor
struct ReaderFloatingToolsView: View {
    @ObservedObject var model: ReaderViewModel
    let state: ReadingToolsPresentation
    let metrics: ReaderToolMetrics
    let appearance: ReaderToolAppearance
    let layout: LibraryLayout
    let rememberFocus: @MainActor (String) -> Void
    let open: @MainActor (ReadingToolPanel) -> Void
    @AccessibilityFocusState.Binding var focusedControl: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var trayExpanded = false

    private var visible: Bool { state.visible && state.panel == nil }

    var body: some View {
        Group {
            switch layout {
            case .direct: floatingCapsule
            case .tabs: edgeBar
            case .sidebar: edgeDock
            }
        }
        .foregroundStyle(appearance.foreground).tint(appearance.accent)
        .modifier(ReaderToolVisibility(visible: visible, hiddenOffset: ReaderMotion.hiddenTravel, reduceMotion: reduceMotion))
        .allowsHitTesting(visible && state.canInteract).accessibilityHidden(!visible)
        .onChange(of: layout) { _ in
            trayExpanded = false
            rememberFocus(layout == .sidebar ? "dock.expand" : "back")
            if focusedControl == "dock.expand" || focusedControl == "dock.collapse" {
                focusedControl = layout == .sidebar ? "dock.expand" : "back"
            }
        }
    }

    // These are overlay layouts inside the existing safe area, never viewport insets.
    private var verticalPair: some View {
        ScrollView(.vertical) {
            VStack(spacing: 4) { directoryButton; settingsButton }
        }
        .frame(height: min(metrics.compactHeight ? 88 : 220, metrics.controlHeight * 2 + 4))
    }

    private var floatingCapsule: some View {
        Group {
            if metrics.verticalButtons {
                dockSurface(cornerRadius: 26) { verticalPair }
            } else {
                ViewThatFits(in: .horizontal) {
                    dockSurface(cornerRadius: 26) {
                        HStack(spacing: 4) { directoryButton; settingsButton }
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    dockSurface(cornerRadius: 26) { verticalPair }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var edgeBar: some View {
        Group {
            if metrics.verticalButtons { verticalPair }
            else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        directoryButton.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 24).accessibilityHidden(true)
                        settingsButton.fixedSize(horizontal: true, vertical: false)
                    }
                    verticalPair
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(appearance.fill).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private var edgeDock: some View {
        Group {
            if trayExpanded {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        dockSurface(cornerRadius: 24) {
                            HStack(spacing: 4) { directoryButton; settingsButton; collapseButton }
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    dockSurface(cornerRadius: 24) {
                        ScrollView(.vertical) {
                            VStack(spacing: 4) { directoryButton; settingsButton; collapseButton }
                        }
                        .frame(height: min(metrics.compactHeight ? 88 : 220, metrics.controlHeight * 3 + 8))
                    }
                }
                .allowsHitTesting(trayExpanded && visible && state.canInteract)
                .accessibilityHidden(!trayExpanded || !visible)
                .transaction { $0.animation = nil }
                .transition(reduceMotion ? .identity : .asymmetric(insertion: .opacity, removal: .identity))
            } else {
                Button {
                    guard visible, state.canInteract, !model.exitSaveFailed else { return }
                    trayExpanded = true
                    restoreFocus(to: model.chapterTotal > 0 ? "directory" : (model.window != nil ? "settings" : "dock.collapse"))
                } label: {
                    Label("阅读工具", systemImage: "slider.horizontal.3")
                        .font(dynamicType.isAccessibilitySize ? .body.weight(.medium) : .subheadline.weight(.medium))
                        .imageScale(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .frame(minWidth: 44, minHeight: metrics.controlHeight)
                        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
                .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground, cornerRadius: 28)).disabled(model.exitSaveFailed || !state.canInteract)
                .background {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(appearance.fill.opacity(model.exitSaveFailed || !state.canInteract ? 0.4 : 1))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .accessibilityIdentifier("reader.tools.expand")
                .accessibilityHint("展开目录和排版工具")
                .accessibilityFocused($focusedControl, equals: "dock.expand")
                .allowsHitTesting(!trayExpanded && visible && state.canInteract)
                .accessibilityHidden(trayExpanded || !visible)
                .transaction { $0.animation = nil }
                .transition(reduceMotion ? .identity : .asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .animation(reduceMotion ? nil : ReaderMotion.dockPresentation, value: reduceMotion ? 0 : (trayExpanded ? 1 : 2))
        .transaction { if reduceMotion { $0.animation = nil } }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // Only insertion opacity presents the new branch. Removal is immediate;
        // actions/focus update synchronously, with no frame or layout animation.
        // Hidden tools / panels preserve expansion so lastPanelControl can regain its button.
    }

    private var collapseButton: some View {
        Button {
            guard visible, state.canInteract, !model.exitSaveFailed else { return }
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
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.secondary)).disabled(model.exitSaveFailed || !state.canInteract)
        .accessibilityIdentifier("reader.tools.collapse")
        .accessibilityFocused($focusedControl, equals: "dock.collapse")
    }

    private func restoreFocus(to target: String) {
        rememberFocus(target)
        focusedControl = target
    }

    private var directoryButton: some View {
        toolButton("目录", symbol: "list.bullet", panel: .directory, key: "directory")
            .disabled(model.chapterTotal == 0 || model.exitSaveFailed || !state.canInteract)
    }
    private var settingsButton: some View {
        toolButton("排版", symbol: "textformat.size", panel: .settings, key: "settings")
            .disabled(model.window == nil || model.exitSaveFailed || !state.canInteract)
            .accessibilityHint("调整字号、行距和阅读背景，立即应用并保存")
    }
    private func toolButton(_ title: String, symbol: String, panel: ReadingToolPanel, key: String) -> some View {
        Button { open(panel) } label: {
            Label(title, systemImage: symbol)
                .font(dynamicType.isAccessibilitySize ? .body.weight(.medium) : .subheadline.weight(.medium))
                .imageScale(.medium)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .frame(minWidth: 44, minHeight: metrics.controlHeight)
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground)).accessibilityIdentifier("reader.tools.\(key)")
        .accessibilityFocused($focusedControl, equals: key)
    }

    private func dockSurface<Content: View>(cornerRadius: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(appearance.fill).allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

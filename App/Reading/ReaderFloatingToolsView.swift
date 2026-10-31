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
            if metrics.verticalButtons { verticalPair }
            else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { directoryButton; settingsButton }
                        .fixedSize(horizontal: true, vertical: false)
                    verticalPair
                }
            }
        }
        .padding(4).frame(maxWidth: metrics.verticalButtons ? 280 : 340)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(appearance.edge, lineWidth: 0.5).allowsHitTesting(false)
        }
        .background(appearance.fill, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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
        .background(alignment: .top) {
            Rectangle().fill(appearance.edge).frame(height: 0.5).allowsHitTesting(false)
        }
        .background(appearance.fill)
    }

    private var edgeDock: some View {
        Group {
            if trayExpanded {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { directoryButton; settingsButton; collapseButton }
                        .fixedSize(horizontal: true, vertical: false)
                    ScrollView(.vertical) {
                        VStack(spacing: 4) { directoryButton; settingsButton; collapseButton }
                    }
                    .frame(height: min(metrics.compactHeight ? 88 : 220, metrics.controlHeight * 3 + 8))
                }
                .padding(4).frame(maxWidth: 340)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(appearance.edge, lineWidth: 0.5).allowsHitTesting(false)
                }
                .background(appearance.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Button {
                    guard visible, state.canInteract, !model.exitSaveFailed else { return }
                    trayExpanded = true
                    restoreFocus(to: model.chapterTotal > 0 ? "directory" : (model.window != nil ? "settings" : "dock.collapse"))
                } label: {
                    Label("阅读工具", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minWidth: 44, minHeight: metrics.controlHeight).padding(.horizontal, 12)
                }
                .buttonStyle(.plain).disabled(model.exitSaveFailed || !state.canInteract)
                .accessibilityIdentifier("reader.tools.expand")
                .accessibilityHint("展开目录和排版工具")
                .accessibilityFocused($focusedControl, equals: "dock.expand")
                .background {
                    Capsule().stroke(appearance.edge, lineWidth: 0.5).allowsHitTesting(false)
                }
                .background(appearance.fill, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // Expansion is immediate. Only the existing ReaderToolVisibility animates visibility.
        // Hidden tools / panels preserve expansion so lastPanelControl can regain its button.
    }

    private var collapseButton: some View {
        Button {
            guard visible, state.canInteract, !model.exitSaveFailed else { return }
            trayExpanded = false
            restoreFocus(to: "dock.expand")
        } label: {
            Label("收起", systemImage: "chevron.right")
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 44, minHeight: metrics.controlHeight).padding(.horizontal, 8)
        }
        .buttonStyle(.plain).disabled(model.exitSaveFailed || !state.canInteract)
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
                .frame(maxWidth: .infinity, minHeight: metrics.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("reader.tools.\(key)")
        .accessibilityFocused($focusedControl, equals: key)
    }
}

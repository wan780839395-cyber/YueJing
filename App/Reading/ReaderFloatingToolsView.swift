import ReaderDomain
import SwiftUI

@MainActor
struct ReaderFloatingToolsView: View {
    @ObservedObject var model: ReaderViewModel
    let state: ReadingToolsPresentation
    let metrics: ReaderToolMetrics
    let appearance: ReaderToolAppearance
    let rememberFocus: @MainActor (String) -> Void
    let open: @MainActor (ReadingToolPanel) -> Void
    @AccessibilityFocusState.Binding var focusedControl: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var trayExpanded = false

    private var visible: Bool { state.visible && state.panel == nil }

    var body: some View {
        edgeDock
        .foregroundStyle(appearance.foreground).tint(appearance.accent)
        .modifier(ReaderToolVisibility(visible: visible, hiddenOffset: ReaderMotion.hiddenTravel, reduceMotion: reduceMotion))
        .allowsHitTesting(visible && state.canInteract).accessibilityHidden(!visible)
    }

    private var edgeDock: some View {
        ZStack(alignment: .bottomTrailing) {
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
            .opacity(trayExpanded ? 1 : 0)
            .allowsHitTesting(trayExpanded && visible && state.canInteract)
            .accessibilityHidden(!trayExpanded || !visible)

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
            .opacity(trayExpanded ? 0 : 1)
            .allowsHitTesting(!trayExpanded && visible && state.canInteract)
            .accessibilityHidden(trayExpanded || !visible)
        }
        .transaction { $0.animation = nil }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // Both control groups retain their structural identity and bottom-right anchor.
        // Expansion does not mount a branch or start a second presentation animation.
        // Only the active group participates in hit testing and accessibility.
        // The existing outer visibility modifier still owns whole-tool reveal/hide.
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

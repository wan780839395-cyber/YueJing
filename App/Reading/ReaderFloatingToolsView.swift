import ReaderDomain
import SwiftUI

@MainActor
struct ReaderFloatingToolsView: View {
    @ObservedObject var model: ReaderViewModel
    let state: ReadingToolsPresentation
    let metrics: ReaderToolMetrics
    let appearance: ReaderToolAppearance
    let open: @MainActor (ReadingToolPanel) -> Void
    @AccessibilityFocusState.Binding var focusedControl: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType

    private var visible: Bool { state.visible && state.panel == nil }

    var body: some View {
        Group {
            if metrics.verticalButtons {
                VStack(spacing: 4) { directoryButton; settingsButton }
            } else {
                HStack(spacing: 4) { directoryButton; settingsButton }
            }
        }
        .padding(4).frame(maxWidth: metrics.verticalButtons ? 280 : (metrics.compactHeight || dynamicType.isAccessibilitySize ? 340 : 300))
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(appearance.fill)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(appearance.edge, lineWidth: 0.5)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .foregroundStyle(appearance.foreground).tint(appearance.accent)
        .modifier(ReaderToolVisibility(visible: visible, hiddenOffset: ReaderMotion.hiddenTravel, reduceMotion: reduceMotion))
        .allowsHitTesting(visible && state.canInteract).accessibilityHidden(!visible)
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

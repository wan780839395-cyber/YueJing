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

    private var visible: Bool { state.visible && state.panel == nil }

    var body: some View {
        Group {
            if metrics.verticalButtons {
                VStack(spacing: 4) { directoryButton; settingsButton }
            } else {
                HStack(spacing: 8) { directoryButton; settingsButton }
            }
        }
        .padding(6).frame(maxWidth: metrics.verticalButtons ? 280 : 340)
        .background(appearance.fill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(appearance.edge, lineWidth: 0.5) }
        .foregroundStyle(appearance.foreground).tint(appearance.accent)
        .opacity(visible ? 1 : 0).offset(y: reduceMotion || visible ? 0 : 8)
        .allowsHitTesting(visible && state.canInteract).accessibilityHidden(!visible)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.94), value: visible)
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
            Label(title, systemImage: symbol).font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: metrics.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("reader.tools.\(key)")
        .accessibilityFocused($focusedControl, equals: key)
    }
}

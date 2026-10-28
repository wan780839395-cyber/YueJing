import ReaderDomain
import SwiftUI
import TXTCore

@MainActor
struct ReaderFloatingToolsView: View {
    @ObservedObject var model: ReaderViewModel
    let state: ReadingToolsPresentation
    let metrics: ReaderToolMetrics
    let appearance: ReaderToolAppearance
    let active: @MainActor (ReadingToolPanel, UUID) -> Bool
    let open: @MainActor (ReadingToolPanel) -> Void
    let close: @MainActor (UUID) -> Void
    let selected: @MainActor (TXTChapter, UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let id = state.panelID {
                    if state.panel == .directory {
                        ReaderDirectorySheet(model: model.directory, presentationID: id,
                            isActive: { active(.directory, id) }, currentAnchor: model.directoryAnchor,
                            close: { close(id) }, appearance: appearance) { selected($0, id) }
                            .id(id).transition(.opacity)
                    } else {
                        ReaderSettingsView(preferences: settingsBinding(id), changed: {
                            if active(.settings, id) { model.settingsChanged() }
                        }, openingSummary: model.openingPerformanceSummary,
                            isActive: { active(.settings, id) }, close: { close(id) })
                            .id(id).transition(.opacity)
                    }
                }
            }
            .frame(height: state.panel == nil ? 0 : max(0, metrics.panelHeight - metrics.dockHeight))
            .clipped()
            Group {
                if metrics.verticalButtons {
                    VStack(spacing: 8) { directoryButton; settingsButton }
                } else {
                    HStack(spacing: 8) { directoryButton; settingsButton }
                }
            }
            .padding(8).frame(height: metrics.dockHeight)
        }
        .frame(maxWidth: .infinity)
        .frame(height: state.panel == nil ? metrics.dockHeight : metrics.panelHeight)
        .background(appearance.fill, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(appearance.edge, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .tint(appearance.accent).foregroundStyle(appearance.foreground)
        .preferredColorScheme(model.preferences.theme == .dark ? .dark : .light)
        // Reduced Motion switches geometry immediately; only the outer opacity may fade.
        .transaction { transaction in if reduceMotion { transaction.animation = nil } }
        .opacity(state.visible ? 1 : 0)
        .offset(y: reduceMotion || state.visible ? 0 : 8)
        .allowsHitTesting(state.visible && state.canInteract)
        .accessibilityHidden(!state.visible)
        // Only this tools container animates. No completion callback changes semantic state.
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .interactiveSpring(response: 0.32, dampingFraction: 0.90), value: state.mode)
    }
    private var directoryButton: some View {
        toolButton("目录", systemImage: "list.bullet", panel: .directory)
            .disabled(model.chapterTotal == 0 || model.exitSaveFailed || !state.canInteract)
            .accessibilityHint("显示当前章节并分页浏览目录")
    }
    private var settingsButton: some View {
        toolButton("设置", systemImage: "textformat.size", panel: .settings)
            .disabled(model.window == nil || model.exitSaveFailed || !state.canInteract)
            .accessibilityHint("调整文字和背景，设置立即生效")
    }
    private func toolButton(_ title: String, systemImage: String, panel: ReadingToolPanel) -> some View {
        Button { open(panel) } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 20)).accessibilityHidden(true)
                if !metrics.compactHeight { Text(title).font(.body) }
            }
            .frame(maxWidth: .infinity).frame(minHeight: metrics.controlHeight)
            .background(state.panel == panel ? appearance.accent.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain).accessibilityLabel(title)
        .accessibilityValue(state.panel == panel ? "已展开" : "")
    }
    private func settingsBinding(_ id: UUID) -> Binding<ReaderPreferences> {
        Binding(get: { model.preferences }, set: { value in
            guard active(.settings, id), !model.exitSaveFailed else { return }
            model.preferences = value
        })
    }
}

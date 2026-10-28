import ReaderDomain
import SwiftUI
import TXTCore

@MainActor
struct ReaderPanelHost: View {
    let session: ReaderPanelSession
    @ObservedObject var model: ReaderViewModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let active: @MainActor (ReadingToolPanel, UUID) -> Bool
    let close: @MainActor (UUID) -> Void
    let selected: @MainActor (TXTChapter, UUID) -> Void

    private var appearance: ReaderToolAppearance {
        ReaderToolAppearance(theme: model.preferences.theme, reduceTransparency: reduceTransparency)
    }

    var body: some View {
        Group {
            if session.panel == .directory {
                ReaderDirectorySheet(model: model.directory, presentationID: session.id,
                    isActive: { active(.directory, session.id) }, currentAnchor: model.directoryAnchor,
                    close: { close(session.id) }, appearance: appearance) { selected($0, session.id) }
            } else {
                ReaderSettingsView(preferences: settings, changed: {
                    if active(.settings, session.id) { model.settingsChanged() }
                }, openingSummary: model.openingPerformanceSummary,
                    isActive: { active(.settings, session.id) }, close: { close(session.id) }, appearance: appearance)
            }
        }
        .padding(.top, 18)
        .background(appearance.surface.ignoresSafeArea())
        .foregroundStyle(appearance.foreground).tint(appearance.accent)
        .environment(\.colorScheme, model.preferences.theme == .dark ? .dark : .light)
        .presentationDetents(session.panel == .directory ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier(session.panel == .directory ? "reader.panel.directory" : "reader.panel.settings")
    }

    private var settings: Binding<ReaderPreferences> {
        Binding(get: { model.preferences }, set: { value in
            guard active(.settings, session.id), !model.exitSaveFailed else { return }
            model.preferences = value
        })
    }
}

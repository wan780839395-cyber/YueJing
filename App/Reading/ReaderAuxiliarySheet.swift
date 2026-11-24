import ReaderDomain
import SwiftUI

@MainActor
struct ReaderAuxiliarySheet: View {
    let openingSummary: String?
    let appearance: ReaderToolAppearance
    let isActive: @MainActor () -> Bool
    var epubUsesAuthorTypography: Bool?
    var fontDiagnostics: [EPUBFontDiagnostic]?
    var compatibilityDetails: String?
    var runtimeDiagnostics: (@MainActor () async -> String)?
    @Environment(\.dismiss) private var dismiss
    @State private var runtimeSummary: String?

    private var combinedSummary: String? {
        let parts = [openingSummary, runtimeSummary].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            ReaderDiagnosticsView(
                openingSummary: combinedSummary,
                fontDiagnostics: fontDiagnostics,
                compatibilityDetails: compatibilityDetails,
                epubUsesAuthorTypography: epubUsesAuthorTypography,
                readerAppearance: appearance
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("完成").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("reader.info.close")
                }
            }
        }
        .tint(appearance.accent)
        .foregroundStyle(appearance.foreground)
        .environment(\.colorScheme, appearance.theme == .dark ? .dark : .light)
        .presentationDetents([.large])
        .task {
            guard isActive(), let runtimeDiagnostics else { return }
            let value = await runtimeDiagnostics()
            guard !Task.isCancelled, isActive() else { return }
            runtimeSummary = value
        }
    }
}

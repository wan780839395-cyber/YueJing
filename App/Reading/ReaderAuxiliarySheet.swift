import SwiftUI

@MainActor
struct ReaderAuxiliarySheet: View {
    enum Page: String, Identifiable { case diagnostics, license; var id: String { rawValue } }
    let page: Page
    let openingSummary: String?
    let appearance: ReaderToolAppearance
    @Environment(\.dismiss) private var dismiss
    @State private var license = ""

    var body: some View {
        NavigationStack {
            Group {
                if page == .diagnostics {
                    ReaderDiagnosticsView(openingSummary: openingSummary, readerAppearance: appearance)
                } else {
                    ScrollView {
                        Text(license)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background(appearance.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(appearance.edge.opacity(0.75), lineWidth: 0.75)
                                    .allowsHitTesting(false)
                            }
                            .padding(ReaderVisualStyle.panelHorizontalInset)
                    }
                    .background(appearance.surface.ignoresSafeArea())
                    .navigationTitle("GRDB · MIT")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
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
            guard page == .license else { return }
            if let url = Bundle.main.url(forResource: "GRDB-LICENSE", withExtension: "txt") {
                do { license = try String(contentsOf: url, encoding: .utf8) }
                catch { license = "许可文件读取失败。" }
            } else { license = "许可文件读取失败。" }
        }
    }
}

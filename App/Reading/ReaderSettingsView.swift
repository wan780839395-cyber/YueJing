import ReaderDomain
import SwiftUI

@MainActor
struct ReaderSettingsView: View {
    @Binding var preferences: ReaderPreferences
    let changed: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("文字") {
                    LabeledContent("字号", value: "\(Int(preferences.fontSize))")
                    Slider(value: $preferences.fontSize, in: 14...36, step: 1).accessibilityLabel("字号").accessibilityValue("\(Int(preferences.fontSize))")
                    LabeledContent("行距", value: "\(Int(preferences.lineSpacing))")
                    Slider(value: $preferences.lineSpacing, in: 0...20, step: 1).accessibilityLabel("行距").accessibilityValue("\(Int(preferences.lineSpacing))")
                }
                Section("背景") {
                    Picker("阅读背景", selection: $preferences.theme) {
                        ForEach(ReaderTheme.allCases, id: \.rawValue) { theme in Text(theme.title).tag(theme) }
                    }.pickerStyle(.segmented)
                }
                Section { NavigationLink("开源许可") { GRDBLicenseView() } }
            }
            .navigationTitle("阅读设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onChange(of: preferences) { _ in changed() }
        }
    }
}

@MainActor
private struct GRDBLicenseView: View {
    @State private var license = ""
    var body: some View {
        ScrollView { Text(license).font(.footnote).textSelection(.enabled).padding() }
            .navigationTitle("GRDB · MIT")
            .task {
                if let url = Bundle.main.url(forResource: "GRDB-LICENSE", withExtension: "txt") {
                    license = (try? String(contentsOf: url, encoding: .utf8)) ?? "许可文件读取失败。"
                } else { license = "许可文件读取失败。" }
            }
    }
}

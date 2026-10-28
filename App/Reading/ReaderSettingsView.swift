import ReaderDomain
import SwiftUI

@MainActor
struct ReaderSettingsView: View {
    @Binding var preferences: ReaderPreferences
    let changed: @MainActor () -> Void
    var openingSummary: String?
    let isActive: @MainActor () -> Bool
    let close: @MainActor () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @AccessibilityFocusState private var doneFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("调整会立即应用并自动保存。“完成”仅关闭设置，不会撤销调整。")
                        .font(.footnote).fixedSize(horizontal: false, vertical: true)
                }
                Section("文字") {
                    LabeledContent("字号", value: "\(Int(preferences.fontSize))")
                    Slider(value: $preferences.fontSize, in: 14...36, step: 1)
                        .frame(minHeight: 44).accessibilityLabel("字号")
                        .accessibilityValue("\(Int(preferences.fontSize))").accessibilityHint("调整后立即重排正文")
                    LabeledContent("行距", value: "\(Int(preferences.lineSpacing))")
                    Slider(value: $preferences.lineSpacing, in: 0...20, step: 1)
                        .frame(minHeight: 44).accessibilityLabel("行距")
                        .accessibilityValue("\(Int(preferences.lineSpacing))").accessibilityHint("调整后立即重排正文")
                }
                Section("背景") {
                    Picker("阅读背景", selection: $preferences.theme) {
                        ForEach(ReaderTheme.allCases, id: \.rawValue) { theme in Text(theme.title).tag(theme) }
                    }.pickerStyle(.menu).frame(minHeight: 44)
                }
                Section("更多") {
                    NavigationLink {
                        ReaderDiagnosticsView(openingSummary: openingSummary)
                    } label: { Label("诊断与耗时", systemImage: "ladybug") }
                    NavigationLink("开源许可") { GRDBLicenseView() }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("完成") { if isActive() { close() } }.frame(minHeight: 44).accessibilityFocused($doneFocused)
            } }
            .onChange(of: preferences) { _ in if isActive() { changed() } }
            .task {
                guard voiceOver else { return }
                await Task.yield()
                if !Task.isCancelled, isActive() { doneFocused = true }
            }
        }
        .accessibilityAction(.escape) { if isActive() { close() } }
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

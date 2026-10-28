import ReaderDomain
import SwiftUI

@MainActor
struct ReaderSettingsView: View {
    @Binding var preferences: ReaderPreferences
    let changed: @MainActor () -> Void
    var openingSummary: String?
    let isActive: @MainActor () -> Bool
    let close: @MainActor () -> Void
    let appearance: ReaderToolAppearance
    @State private var info: ReaderAuxiliarySheet.Page?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var dynamicType
    @AccessibilityFocusState private var closeFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("排版").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { if isActive() { close() } } label: {
                    Text("完成").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                    .accessibilityFocused($closeFocused)
                    .accessibilityIdentifier("reader.panel.close")
            }.padding(.horizontal, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("立即应用并自动保存").font(.caption).foregroundStyle(.secondary)
                    adjustment("字号", value: $preferences.fontSize, range: 14...36, key: "font")
                    adjustment("行距", value: $preferences.lineSpacing, range: 0...20, key: "spacing")
                    VStack(alignment: .leading, spacing: 10) {
                        Text("阅读背景").font(.subheadline.weight(.medium))
                        HStack(spacing: 10) {
                            ForEach(ReaderTheme.allCases, id: \.rawValue) { theme in themeButton(theme) }
                        }
                    }
                    Divider().overlay(appearance.edge)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) { diagnosticsButton; licenseButton }
                        VStack(alignment: .leading, spacing: 8) { diagnosticsButton; licenseButton }
                    }
                    .font(.footnote).frame(minHeight: 44).disabled(!isActive())
                    Text("“完成”只关闭面板，不撤销已应用的调整。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
        .onChange(of: preferences) { _ in if isActive() { changed() } }
        .task {
            guard voiceOver else { return }
            await Task.yield()
            if !Task.isCancelled, isActive() { closeFocused = true }
        }
        .sheet(item: $info, onDismiss: {
            if voiceOver, isActive() { closeFocused = true }
        }) { page in
            ReaderAuxiliarySheet(page: page, openingSummary: openingSummary, appearance: appearance)
        }
        .accessibilityAction(.escape) { if isActive() { close() } }
    }

    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, key: String) -> some View {
        let controls = HStack(spacing: 12) {
                Button { if isActive() { value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1) } } label: {
                    Image(systemName: "minus").font(.system(size: 18)).frame(minWidth: 44, minHeight: 44)
                }
                .disabled(!isActive() || value.wrappedValue <= range.lowerBound)
                .accessibilityLabel("减小\(title)").accessibilityIdentifier("reader.\(key).decrease")
                Text("\(Int(value.wrappedValue))").font(.body.monospacedDigit()).frame(minWidth: 30)
                    .accessibilityLabel("\(title)，\(Int(value.wrappedValue))")
                    .accessibilityIdentifier("reader.\(key).value")
                Button { if isActive() { value.wrappedValue = min(range.upperBound, value.wrappedValue + 1) } } label: {
                    Image(systemName: "plus").font(.system(size: 18)).frame(minWidth: 44, minHeight: 44)
                }
                .disabled(!isActive() || value.wrappedValue >= range.upperBound)
                .accessibilityLabel("增大\(title)").accessibilityIdentifier("reader.\(key).increase")
        }
        return VStack(spacing: 0) {
            if dynamicType.isAccessibilitySize {
                HStack { Text(title).font(.subheadline.weight(.medium)); Spacer(minLength: 0) }
                controls.frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 12) {
                    Text(title).font(.subheadline.weight(.medium)); Spacer(minLength: 8); controls
                }
            }
        }
    }

    private var diagnosticsButton: some View {
        Button { if isActive() { info = .diagnostics } } label: { Label("诊断与耗时", systemImage: "ladybug") }
            .frame(minHeight: 44).contentShape(Rectangle())
            .accessibilityIdentifier("reader.info.diagnostics")
    }
    private var licenseButton: some View {
        Button { if isActive() { info = .license } } label: { Text("开源许可") }
            .frame(minHeight: 44).contentShape(Rectangle())
            .accessibilityIdentifier("reader.info.license")
    }

    private func themeButton(_ theme: ReaderTheme) -> some View {
        let selected = preferences.theme == theme
        return Button { if isActive() { preferences.theme = theme } } label: {
            VStack(spacing: 7) {
                HStack {
                    Spacer()
                    if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
                    Spacer()
                }
                .frame(height: 32).foregroundStyle(Color(uiColor: theme.foreground))
                .background(Color(uiColor: theme.background), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(selected ? appearance.accent : appearance.edge, lineWidth: selected ? 2 : 0.5) }
                Text(theme.title).font(.caption)
            }.frame(maxWidth: .infinity, minHeight: 60).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!isActive())
        .accessibilityLabel(theme.title).accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityIdentifier("reader.theme.\(theme.rawValue)")
    }
}

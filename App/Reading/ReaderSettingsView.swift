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
    @State private var draft: ReaderPreferences
    @State private var info: ReaderAuxiliarySheet.Page?
    @State private var showRestore = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var dynamicType
    @AccessibilityFocusState private var closeFocused: Bool

    init(preferences: Binding<ReaderPreferences>, changed: @escaping @MainActor () -> Void,
         openingSummary: String? = nil, isActive: @escaping @MainActor () -> Bool,
         close: @escaping @MainActor () -> Void, appearance: ReaderToolAppearance) {
        _preferences = preferences; self.changed = changed; self.openingSummary = openingSummary
        self.isActive = isActive; self.close = close; self.appearance = appearance
        _draft = State(initialValue: preferences.wrappedValue.validated)
    }

    var body: some View {
        VStack(spacing: 8) {
            ReaderPanelHeader(title: "排版", appearance: appearance) {
                Button(action: finish) {
                    Text("完成").font(ReaderVisualStyle.panelActionFont)
                        .frame(minWidth: ReaderVisualStyle.panelActionMinimumWidth,
                               minHeight: ReaderVisualStyle.minimumControlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent))
                .disabled(!isActive())
                .accessibilityFocused($closeFocused)
                .accessibilityIdentifier("reader.panel.close")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ReaderTypographyPreview(preferences: draft, appearance: appearance)
                    typographySection
                    themeSection
                    presetsSection
                    moreSection
                }.padding(.horizontal, 20).padding(.bottom, 24)
            }
            .accessibilityIdentifier("reader.settings.scroll")
        }
        .onChange(of: preferences) { value in draft = value.validated }
        .task {
            guard voiceOver else { return }
            await Task.yield()
            if !Task.isCancelled, isActive() { closeFocused = true }
        }
        .confirmationDialog("恢复默认排版？", isPresented: $showRestore, titleVisibility: .visible) {
            Button("恢复字号与行距") { apply(.standard) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("恢复为字号 20、行距 7。保留当前阅读背景，不改变阅读位置。")
        }
        .sheet(item: $info, onDismiss: {
            if voiceOver, isActive() { closeFocused = true }
        }) { page in
            ReaderAuxiliarySheet(page: page, openingSummary: openingSummary, appearance: appearance)
        }
        .accessibilityAction(.escape) { finish() }
        // An interrupted gesture/dismissal must never write an obsolete panel's draft.
        .onDisappear { draft = preferences.validated }
    }

    private var typographySection: some View {
        ReaderSettingsSection(title: "文字", detail: "滑动预览，松手应用并自动保存", mark: "字", appearance: appearance) {
            VStack(alignment: .leading, spacing: 4) {
                ReaderSettingAdjustment(title: "字号", key: "font", value: $draft.fontSize, range: 14...36,
                    accent: appearance.accent, isActive: isActive, commit: commitDraft)
                Divider().overlay(appearance.edge)
                ReaderSettingAdjustment(title: "行距", key: "spacing", value: $draft.lineSpacing, range: 0...20,
                    accent: appearance.accent, isActive: isActive, commit: commitDraft)
            }
        }
    }

    private var themeSection: some View {
        ReaderSettingsSection(title: "阅读背景", detail: "仅影响阅读界面", mark: "色", appearance: appearance) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicType.isAccessibilitySize ? 130 : 76), spacing: 10)], spacing: 12) {
                ForEach(ReaderTheme.allCases, id: \.rawValue) { theme in themeButton(theme) }
            }
        }
    }

    private var presetsSection: some View {
        ReaderSettingsSection(title: "快捷排版", detail: "只调整字号和行距，保留当前背景", mark: "式", appearance: appearance) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicType.isAccessibilitySize ? 130 : 76), spacing: 8)], spacing: 10) {
                ForEach(ReaderTypographyPreset.allCases, id: \.rawValue) { preset in
                    let selected = preset.matches(draft)
                    Button { apply(preset) } label: {
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                Text(preset.title).font(.subheadline.weight(.medium))
                                if selected { Image(systemName: "checkmark").font(.caption).accessibilityHidden(true) }
                            }
                            Text("\(Int(preset.fontSize)) / \(Int(preset.lineSpacing))").font(.caption.monospacedDigit())
                        }
                        .frame(maxWidth: .infinity, minHeight: 52).padding(.horizontal, 4)
                        .background(selected ? appearance.accent.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? appearance.accent : appearance.edge, lineWidth: selected ? 1.5 : 0.5) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!isActive())
                    .accessibilityLabel("\(preset.title)排版，字号 \(Int(preset.fontSize))，行距 \(Int(preset.lineSpacing))")
                    .accessibilityValue(selected ? "已选择" : "未选择")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("reader.preset.\(preset.rawValue)")
                }
            }
            Button { if isActive() { showRestore = true } } label: {
                Label("恢复默认字号与行距", systemImage: "arrow.counterclockwise")
                    .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isActive() || ReaderTypographyPreset.standard.matches(draft))
            .accessibilityIdentifier("reader.typography.restore")
        }
    }

    private var moreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { diagnosticsButton; licenseButton }
                VStack(alignment: .leading, spacing: 4) { diagnosticsButton; licenseButton }
            }
            .font(.footnote).disabled(!isActive())
            Text("预览为示例文字，实际断行以正文为准。加减和快捷排版立即应用；“完成”只关闭，不撤销已应用的设置。")
                .font(.caption).foregroundStyle(appearance.foreground.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var diagnosticsButton: some View {
        Button { if isActive() { info = .diagnostics } } label: {
            Label("诊断与耗时", systemImage: "ladybug").frame(minHeight: 44).contentShape(Rectangle())
        }.accessibilityIdentifier("reader.info.diagnostics")
    }
    private var licenseButton: some View {
        Button { if isActive() { info = .license } } label: {
            Text("开源许可").frame(minHeight: 44).contentShape(Rectangle())
        }.accessibilityIdentifier("reader.info.license")
    }

    private func themeButton(_ theme: ReaderTheme) -> some View {
        let selected = draft.theme == theme
        return Button {
            guard isActive() else { return }
            draft.theme = theme; commitDraft()
        } label: {
            VStack(spacing: 6) {
                Text("阅").font(.system(size: 22))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .foregroundStyle(Color(uiColor: theme.foreground))
                    .background(Color(uiColor: theme.background), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill").font(.caption)
                                .foregroundStyle(appearance.accent).padding(4).accessibilityHidden(true)
                        }
                    }
                    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? appearance.accent : appearance.edge, lineWidth: selected ? 2 : 0.5) }
                Text(theme.title).font(.caption).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 64).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!isActive())
        .accessibilityLabel(theme.title).accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("reader.theme.\(theme.rawValue)")
    }

    private func apply(_ preset: ReaderTypographyPreset) {
        guard isActive() else { return }
        draft = preset.applying(to: draft); commitDraft()
    }
    private func commitDraft() {
        guard isActive() else { return }
        let value = draft.validated
        guard value != preferences else { return }
        preferences = value
        changed()
    }
    private func finish() {
        guard isActive() else { return }
        commitDraft(); close()
    }
}

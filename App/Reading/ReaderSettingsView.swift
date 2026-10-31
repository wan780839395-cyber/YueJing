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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minWidth: ReaderVisualStyle.panelActionMinimumWidth,
                               minHeight: ReaderVisualStyle.minimumControlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, surfaceInset: 0, outlined: true))
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
            VStack(alignment: .leading, spacing: 8) {
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
            threeOptionLayout(ReaderTheme.allCases) { theme in themeButton(theme) }
        }
    }

    private var presetsSection: some View {
        ReaderSettingsSection(title: "快捷排版", detail: "只调整字号和行距，保留当前背景", mark: "式", appearance: appearance) {
            VStack(spacing: 8) {
                threeOptionLayout(ReaderTypographyPreset.allCases) { preset in presetButton(preset) }
                restoreTypographyButton
            }
        }
    }

    @ViewBuilder
    private func threeOptionLayout<Option: Hashable, OptionView: View>(
        _ options: [Option],
        @ViewBuilder content: @escaping (Option) -> OptionView
    ) -> some View {
        if dynamicType.isAccessibilitySize {
            VStack(spacing: 8) {
                ForEach(options, id: \.self) { option in content(option) }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(options, id: \.self) { option in content(option) }
                }
                VStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in content(option) }
                }
            }
        }
    }

    private func presetButton(_ preset: ReaderTypographyPreset) -> some View {
        let selected = preset.matches(draft)
        let selectionMotionKey = reduceMotion ? 0 : (selected ? 1 : 2)
        let selectionAnimation = reduceMotion ? nil : ReaderMotion.selectionFeedback
        return Button { apply(preset) } label: {
            VStack(spacing: 4) {
                Text(preset.title)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Int(preset.fontSize)) / \(Int(preset.lineSpacing))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(appearance.foreground.opacity(selected ? 0.92 : 0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minWidth: 84, maxWidth: .infinity, minHeight: 56)
            .background {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                shape.fill(selected ? appearance.accent.opacity(0.12) : appearance.card)
                    .overlay {
                        shape.strokeBorder(selected ? appearance.accent : appearance.edge,
                                           lineWidth: selected ? 1.5 : 0.8)
                    }
                    .animation(selectionAnimation, value: selectionMotionKey)
                    .transaction { transaction in
                        if reduceMotion { transaction.animation = nil }
                    }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(appearance.accent)
                    .padding(6)
                    .opacity(selected ? 1 : 0)
                    .animation(selectionAnimation, value: selectionMotionKey)
                    .transaction { transaction in
                        if reduceMotion { transaction.animation = nil }
                    }
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isActive())
        .accessibilityLabel("\(preset.title)排版，字号 \(Int(preset.fontSize))，行距 \(Int(preset.lineSpacing))")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("reader.preset.\(preset.rawValue)")
    }

    private var restoreTypographyButton: some View {
        Button { if isActive() { showRestore = true } } label: {
            Label("恢复默认字号与行距", systemImage: "arrow.counterclockwise")
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: ReaderVisualStyle.minimumControlHeight, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, surfaceInset: 0, outlined: true))
        .disabled(!isActive() || ReaderTypographyPreset.standard.matches(draft))
        .accessibilityIdentifier("reader.typography.restore")
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
        let selectionMotionKey = reduceMotion ? 0 : (selected ? 1 : 2)
        let selectionAnimation = reduceMotion ? nil : ReaderMotion.selectionFeedback
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
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(appearance.accent)
                            .padding(4)
                            .opacity(selected ? 1 : 0)
                            .animation(selectionAnimation, value: selectionMotionKey)
                            .transaction { transaction in
                                if reduceMotion { transaction.animation = nil }
                            }
                            .accessibilityHidden(true)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(selected ? appearance.accent : appearance.edge, lineWidth: selected ? 2 : 0.5)
                            .animation(selectionAnimation, value: selectionMotionKey)
                            .transaction { transaction in
                                if reduceMotion { transaction.animation = nil }
                            }
                    }
                Text(theme.title).font(.caption).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.frame(minWidth: 84, maxWidth: .infinity, minHeight: 64).contentShape(Rectangle())
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

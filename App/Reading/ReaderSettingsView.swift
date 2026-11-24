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
    let selectedBodyFontID: String?
    let selectBodyFont: @MainActor (EPUBUserFont?) -> Void
    @State private var draft: ReaderPreferences
    @AppStorage(DeveloperMode.storageKey) private var developerMode = false
    @State private var showDiagnostics = false
    @State private var showRestore = false
    @State private var previewFontRevision = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var closeFocused: Bool
    init(
        preferences: Binding<ReaderPreferences>,
        changed: @escaping @MainActor () -> Void,
        openingSummary: String? = nil,
        isActive: @escaping @MainActor () -> Bool,
        close: @escaping @MainActor () -> Void,
        appearance: ReaderToolAppearance,
        selectedBodyFontID: String? = nil,
        selectBodyFont: @escaping @MainActor (EPUBUserFont?) -> Void = { _ in }
    ) {
        _preferences = preferences
        self.changed = changed
        self.openingSummary = openingSummary
        self.isActive = isActive
        self.close = close
        self.appearance = appearance
        self.selectedBodyFontID = selectedBodyFontID
        self.selectBodyFont = selectBodyFont
        _draft = State(initialValue: preferences.wrappedValue.validated)
    }

    var body: some View {
        GeometryReader { proxy in
            let pinPreview = proxy.size.height >= 580
                && !dynamicType.isAccessibilitySize
                && verticalSizeClass != .compact
            VStack(spacing: 10) {
                ReaderPanelHeader(title: "阅读设置", appearance: appearance) {
                    Button(action: finish) {
                        Text("完成").font(ReaderVisualStyle.panelActionFont.weight(.semibold))
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(minWidth: ReaderVisualStyle.panelActionMinimumWidth,
                                   minHeight: ReaderVisualStyle.minimumControlHeight)
                    }
                    .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, role: .primary))
                    .disabled(!isActive())
                    .accessibilityFocused($closeFocused)
                    .accessibilityIdentifier("reader.panel.close")
                }
                if pinPreview {
                    VStack(spacing: 8) {
                        typographyPreview(compactPinned: true)
                            .padding(.horizontal, ReaderVisualStyle.panelHorizontalInset)
                        Rectangle()
                            .fill(appearance.edge.opacity(0.45))
                            .frame(height: ReaderVisualStyle.panelDividerHeight)
                            .accessibilityHidden(true)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !pinPreview {
                            typographyPreview(compactPinned: false)
                        }
                        typographySection
                        themeSection
                        presetsSection
                        EPUBUserFontPicker(
                            selectedID: selectedBodyFontID,
                            isActive: isActive,
                            select: handleBodyFontSelection,
                            appearance: appearance,
                            context: .txt,
                            showsSpecimen: false
                        )
                        moreSection
                        ReadingTimeSummary(scope: .currentBook)
                            .foregroundStyle(appearance.secondary)
                    }
                    .padding(.horizontal, ReaderVisualStyle.panelHorizontalInset)
                    .padding(.top, 4)
                    .padding(.bottom, 26)
                }
                .accessibilityIdentifier("reader.settings.scroll")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(appearance.foreground)
        .tint(appearance.accent)
        .background(appearance.surface)
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
            Text("恢复为字号 20、行距 7。保留当前阅读背景与正文字体，不改变阅读位置。")
        }
        .onChange(of: developerMode) { enabled in
            if !enabled { showDiagnostics = false }
        }
        .sheet(isPresented: $showDiagnostics, onDismiss: {
            if voiceOver, isActive() { closeFocused = true }
        }) {
            if developerMode {
                ReaderAuxiliarySheet(openingSummary: openingSummary, appearance: appearance, isActive: isActive)
            }
        }
        .accessibilityAction(.escape) { finish() }
        // An interrupted gesture/dismissal must never write an obsolete panel's draft.
        .onDisappear { draft = preferences.validated }
    }

    private func typographyPreview(compactPinned: Bool) -> some View {
        ReaderTypographyPreview(
            preferences: draft,
            appearance: appearance,
            selectedFontID: selectedBodyFontID,
            context: .txt,
            fontReloadRevision: previewFontRevision,
            compactPinned: compactPinned,
            isActive: isActive
        )
    }

    private var typographySection: some View {
        ReaderSettingsSection(title: "文字与行距", detail: "滑动预览，松手应用并自动保存", appearance: appearance) {
            VStack(alignment: .leading, spacing: 10) {
                ReaderSettingAdjustment(title: "字号", key: "font", value: $draft.fontSize, range: 14...36,
                    accent: appearance.accent, isActive: isActive, commit: commitDraft)
                Rectangle()
                    .fill(appearance.edge.opacity(0.65))
                    .frame(height: 0.5)
                    .accessibilityHidden(true)
                ReaderSettingAdjustment(title: "行距", key: "spacing", value: $draft.lineSpacing, range: 0...20,
                    accent: appearance.accent, isActive: isActive, commit: commitDraft)
                restoreTypographyButton
            }
            .padding(14)
            .background(appearance.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(appearance.edge.opacity(0.7), lineWidth: 0.65)
                    .allowsHitTesting(false)
            }
        }
    }

    private var themeSection: some View {
        ReaderSettingsSection(title: "阅读纸色", detail: "仅影响阅读界面，不改变书架外观", appearance: appearance) {
            threeOptionLayout(ReaderTheme.allCases) { theme in themeButton(theme) }
        }
    }

    private var presetsSection: some View {
        ReaderSettingsSection(title: "快捷排版", detail: "只调整字号和行距，保留当前背景", appearance: appearance) {
            VStack(spacing: 10) {
                threeOptionLayout(ReaderTypographyPreset.allCases) { preset in presetButton(preset) }
                    .padding(5)
                    .background(appearance.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(appearance.edge.opacity(0.65), lineWidth: 0.6)
                            .allowsHitTesting(false)
                    }
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
                    .font(.subheadline.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? appearance.accent : appearance.foreground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Int(preset.fontSize)) / \(Int(preset.lineSpacing))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(selected ? appearance.accent.opacity(0.88) : appearance.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(minWidth: 84, maxWidth: .infinity, minHeight: 66)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: selected ? appearance.accent : appearance.foreground, cornerRadius: 14))
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? appearance.elevatedSurface : .clear)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(appearance.accent.opacity(0.45), lineWidth: 1)
                    }
                }
                .shadow(color: selected ? appearance.subtleShadow : .clear, radius: 4, x: 0, y: 1)
                .allowsHitTesting(false)
                .animation(selectionAnimation, value: selectionMotionKey)
                .transaction { transaction in
                    if reduceMotion { transaction.animation = nil }
                }
                .opacity(isActive() ? 1 : 0.4)
        }
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
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.secondary, role: .primary, cornerRadius: 14))
        .disabled(!isActive() || ReaderTypographyPreset.standard.matches(draft))
        .accessibilityIdentifier("reader.typography.restore")
    }

    private var moreSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(appearance.edge.opacity(0.6))
                .frame(height: 0.5)
                .padding(.vertical, 4)
                .accessibilityHidden(true)

            Text("设置会自动保存，点“完成”即可继续阅读。")
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if developerMode {
                diagnosticsButton
                    .font(.footnote.weight(.medium))
                    .disabled(!isActive())
            }
        }
    }

    private var diagnosticsButton: some View {
        Button { if developerMode, isActive() { showDiagnostics = true } } label: {
            Label("本书诊断", systemImage: "waveform.path.ecg")
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.sealAccent, role: .primary, cornerRadius: 12))
        .accessibilityIdentifier("reader.info.diagnostics")
    }

    private func themeButton(_ theme: ReaderTheme) -> some View {
        let selected = draft.theme == theme
        let selectionMotionKey = reduceMotion ? 0 : (selected ? 1 : 2)
        let selectionAnimation = reduceMotion ? nil : ReaderMotion.selectionFeedback
        return Button {
            guard isActive() else { return }
            draft.theme = theme; commitDraft()
        } label: {
            VStack(spacing: 8) {
                // Miniature paper specimen swatch
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("阅")
                            .font(.system(size: 18, weight: .semibold, design: .serif))
                            .foregroundStyle(Color(uiColor: theme.foreground))
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(appearance.accent)
                            .opacity(selected ? 1 : 0)
                            .animation(selectionAnimation, value: selectionMotionKey)
                            .transaction { if reduceMotion { $0.animation = nil } }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule()
                            .fill(Color(uiColor: theme.foreground).opacity(0.32))
                            .frame(height: 2.5)
                        Capsule()
                            .fill(Color(uiColor: theme.foreground).opacity(0.20))
                            .frame(width: 34, height: 2.5)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .background(Color(uiColor: theme.background), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            selected ? appearance.accent : appearance.edge.opacity(0.85),
                            lineWidth: selected ? 1.6 : 0.65
                        )
                }
                .accessibilityHidden(true)

                Text(theme.title)
                    .font(.caption.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? appearance.accent : appearance.foreground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(minWidth: 84, maxWidth: .infinity, minHeight: 74)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground, cornerRadius: 16))
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(selected ? appearance.selectedControl : appearance.card.opacity(0.55))
                .opacity(isActive() ? 1 : 0.4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .animation(selectionAnimation, value: selectionMotionKey)
                .transaction { transaction in
                    if reduceMotion { transaction.animation = nil }
                }
        }
        .disabled(!isActive())
        .accessibilityLabel(theme.title)
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("reader.theme.\(theme.rawValue)")
    }

    private func handleBodyFontSelection(_ font: EPUBUserFont?) {
        guard isActive() else { return }
        previewFontRevision &+= 1
        selectBodyFont(font)
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

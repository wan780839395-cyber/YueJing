import ReaderDomain
import SwiftUI

@MainActor
struct EPUBSettingsView: View {
    @AppStorage(DeveloperMode.storageKey) private var developerMode = false

    @Binding var preferences: ReaderPreferences
    @Binding var readingMode: EPUBReadingMode
    @Binding var layoutMode: EPUBLayoutMode
    let changed: @MainActor () -> Void
    var openingSummary: String?
    var effectiveLayoutMode: EPUBLayoutMode?
    var compatibilitySummary: String?
    var fontDiagnostics: [EPUBFontDiagnostic]
    var compatibilityDetails: String?
    let runtimeDiagnostics: (@MainActor () async -> String)?
    let isActive: @MainActor () -> Bool
    let close: @MainActor () -> Void
    let appearance: ReaderToolAppearance
    let userFontID: String?
    let onUserFontChange: @MainActor (EPUBUserFont?) -> Void
    @State private var draft: ReaderPreferences
    @State private var showDiagnostics = false
    @State private var showRestore = false
    @State private var previewFontRevision = 0
    private enum SettingsGroup: String { case common, more }
    @State private var settingsGroup: SettingsGroup = .common
    @State private var focusSourceOnAppear = false
    @AccessibilityFocusState private var controlFocus: String?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var closeFocused: Bool
    init(
        preferences: Binding<ReaderPreferences>,
        readingMode: Binding<EPUBReadingMode>,
        layoutMode: Binding<EPUBLayoutMode>,
        changed: @escaping @MainActor () -> Void,
        openingSummary: String? = nil,
        effectiveLayoutMode: EPUBLayoutMode? = nil,
        compatibilitySummary: String? = nil,
        fontDiagnostics: [EPUBFontDiagnostic] = [],
        compatibilityDetails: String? = nil,
        runtimeDiagnostics: (@MainActor () async -> String)? = nil,
        isActive: @escaping @MainActor () -> Bool,
        close: @escaping @MainActor () -> Void,
        appearance: ReaderToolAppearance,
        userFontID: String? = nil,
        onUserFontChange: @escaping @MainActor (EPUBUserFont?) -> Void = { _ in }
    ) {
        _preferences = preferences
        _readingMode = readingMode
        _layoutMode = layoutMode
        self.changed = changed
        self.openingSummary = openingSummary
        self.effectiveLayoutMode = effectiveLayoutMode
        self.compatibilitySummary = compatibilitySummary
        self.fontDiagnostics = fontDiagnostics
        self.compatibilityDetails = compatibilityDetails
        self.runtimeDiagnostics = runtimeDiagnostics
        self.isActive = isActive
        self.close = close
        self.appearance = appearance
        self.userFontID = userFontID
        self.onUserFontChange = onUserFontChange
        _draft = State(initialValue: preferences.wrappedValue.validated)
    }

    var body: some View {
        GeometryReader { proxy in
            let pinPreview = settingsGroup == .common
                && proxy.size.height >= 620
                && !dynamicType.isAccessibilitySize
                && verticalSizeClass != .compact
            VStack(spacing: 10) {
                ReaderPanelHeader(title: "阅读设置", appearance: appearance) {
                    Button(action: finish) {
                        Text("完成").font(ReaderVisualStyle.panelActionFont.weight(.semibold))
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(
                                minWidth: ReaderVisualStyle.panelActionMinimumWidth,
                                minHeight: ReaderVisualStyle.minimumControlHeight
                            )
                    }
                    .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, role: .primary))
                    .disabled(!isActive())
                    .accessibilityFocused($closeFocused)
                    .accessibilityIdentifier("reader.panel.close")
                }
                groupSelector
                    .padding(.horizontal, ReaderVisualStyle.panelHorizontalInset)
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
                        if settingsGroup == .common {
                            commonContent(includesPreview: !pinPreview)
                        } else {
                            moreContent
                        }
                    }
                    .padding(.horizontal, ReaderVisualStyle.panelHorizontalInset)
                    .padding(.top, 4)
                    .padding(.bottom, 26)
                }
                .id(settingsGroup)
                .accessibilityIdentifier("reader.settings.scroll")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(appearance.foreground)
        .tint(appearance.accent)
        .background(appearance.surface)
        .onChange(of: preferences) { value in
            draft = value.validated
        }
        .task {
            guard voiceOver else { return }
            await Task.yield()
            if !Task.isCancelled, isActive() {
                closeFocused = true
            }
        }
        .confirmationDialog(usesAuthorTypography ? "恢复作者原字号？" : "恢复默认排版？", isPresented: $showRestore, titleVisibility: .visible) {
            Button(usesAuthorTypography ? "恢复至 100%" : "恢复字号与行距") { apply(.standard) }
            Button("取消", role: .cancel) {}
        } message: {
            Text(usesAuthorTypography
                ? "只恢复作者文字比例至 100%。保留阅读器行距偏好、当前背景、正文字体和阅读位置。"
                : "恢复为字号 20、行距 7。保留当前阅读背景与正文字体，不改变阅读位置。")
        }
        .onChange(of: developerMode) { enabled in
            if !enabled { showDiagnostics = false }
        }
        .sheet(isPresented: $showDiagnostics, onDismiss: {
            guard voiceOver, isActive() else { return }
            if developerMode { controlFocus = "diagnostics" } else { closeFocused = true }
        }) {
            if developerMode {
                ReaderAuxiliarySheet(
                    openingSummary: openingSummary,
                    appearance: appearance,
                    isActive: isActive,
                    epubUsesAuthorTypography: usesAuthorTypography,
                    fontDiagnostics: fontDiagnostics,
                    compatibilityDetails: compatibilityDetails,
                    runtimeDiagnostics: runtimeDiagnostics
                )
            }
        }
        .accessibilityAction(.escape) { finish() }
        .onDisappear { draft = preferences.validated }
    }

    private var usesAuthorTypography: Bool { (effectiveLayoutMode ?? layoutMode) == .original }

    private var groupSelector: some View {
        HStack(spacing: 4) {
            groupButton("常用", symbol: "textformat.size", group: .common)
            groupButton("更多", symbol: "slider.horizontal.3", group: .more)
        }
        .padding(4)
        .background(appearance.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.65), lineWidth: 0.6)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设置分组")
    }

    private func groupButton(_ title: String, symbol: String, group: SettingsGroup) -> some View {
        let selected = settingsGroup == group
        return Button {
            guard isActive() else { return }
            focusSourceOnAppear = false
            if reduceMotion {
                settingsGroup = group
            } else {
                withAnimation(ReaderMotion.selectionFeedback) {
                    settingsGroup = group
                }
            }
            if voiceOver { controlFocus = "group.\(group.rawValue)" }
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(selected ? .semibold : .medium))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: selected ? appearance.accent : appearance.secondary, cornerRadius: 12))
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? appearance.elevatedSurface : .clear)
                .shadow(color: selected ? appearance.subtleShadow : .clear, radius: 4, x: 0, y: 1)
                .opacity(isActive() ? 1 : 0.4)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .disabled(!isActive())
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("epub.settings.group.\(group.rawValue)")
        .accessibilityFocused($controlFocus, equals: "group.\(group.rawValue)")
    }

    private func typographyPreview(compactPinned: Bool) -> some View {
        ReaderTypographyPreview(
            preferences: draft,
            appearance: appearance,
            selectedFontID: userFontID,
            context: usesAuthorTypography ? .epubOriginal : .epubReader,
            fontReloadRevision: previewFontRevision,
            compactPinned: compactPinned,
            isActive: isActive
        )
    }

    private func commonContent(includesPreview: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if includesPreview {
                typographyPreview(compactPinned: false)
            }
            sourceSummary
            if let compatibilitySummary {
                Text(compatibilitySummary)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(appearance.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(appearance.sealAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("epub.compatibility.summary")
            }
            typographySection
            themeSection
            presetsSection
            EPUBUserFontPicker(
                selectedID: userFontID,
                isActive: isActive,
                select: handleUserFontChange,
                appearance: appearance,
                context: .epub,
                showsSpecimen: false
            )
            ReadingTimeSummary()
        }
    }

    private var sourceSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                sourceDescription
                Spacer(minLength: 0)
                changeSourceButton
            }
            VStack(alignment: .leading, spacing: 8) { sourceDescription; changeSourceButton }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(appearance.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.7), lineWidth: 0.65)
                .allowsHitTesting(false)
        }
    }

    private var sourceDescription: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(usesAuthorTypography ? appearance.sealAccent : appearance.accent)
                .frame(width: 3, height: 32)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("本章排版")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(appearance.secondary)
                Text(usesAuthorTypography ? "作者原始排版" : "阅读器排版")
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(appearance.foreground)
                Text(usesAuthorTypography ? "文字按比例缩放，行高随文字同步" : "字号与行距可独立微调")
                    .font(.caption2)
                    .foregroundStyle(appearance.secondary)
                if let effectiveLayoutMode, effectiveLayoutMode != layoutMode {
                    Text("你的排版选择仍为\(layoutMode.title)。")
                        .font(.caption)
                        .foregroundStyle(appearance.sealAccent)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("epub.settings.effectiveSource")
    }

    private var changeSourceButton: some View {
        Button {
            guard isActive() else { return }
            focusSourceOnAppear = true
            settingsGroup = .more
        } label: {
            Label("更改", systemImage: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12).frame(minHeight: 44)
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, role: .primary, cornerRadius: 14))
        .disabled(!isActive())
        .accessibilityLabel("更改排版来源")
        .accessibilityIdentifier("epub.settings.changeSource")
    }

    private var moreContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReaderSettingsSection(title: "阅读行为", detail: "切换来源或方式，保留当前文本位置", appearance: appearance) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("排版来源").font(.subheadline.weight(.semibold))
                    modeOptions(EPUBLayoutMode.allCases) { mode in
                        modeButton(mode.title, selected: layoutMode == mode) { layoutMode = mode }
                            .accessibilityFocused($controlFocus, equals: "layout.\(mode.rawValue)")
                    }
                    .accessibilityIdentifier("epub.layoutMode")
                    .onAppear {
                        if focusSourceOnAppear, isActive() {
                            focusSourceOnAppear = false
                            if voiceOver { controlFocus = "layout.\(layoutMode.rawValue)" }
                        }
                    }
                    Text("原始排版尽量保留书中的样式。想自行调整行距，可选择阅读器排版。")
                        .font(.caption).foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    sectionDivider
                    Text("阅读方式").font(.subheadline.weight(.semibold))
                    modeOptions(EPUBReadingMode.allCases) { mode in
                        modeButton(mode.title, selected: readingMode == mode) { readingMode = mode }
                    }
                    .accessibilityIdentifier("epub.readingMode")
                }
            }
            sectionDivider
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

    // Explicit buttons keep each choice >=44pt and let long Dynamic Type labels wrap.
    private func modeOptions<Option: Hashable, Content: View>(
        _ options: [Option], @ViewBuilder content: @escaping (Option) -> Content
    ) -> some View {
        VStack(spacing: 4) {
            ForEach(options, id: \.self) { option in content(option) }
        }
        .padding(5)
        .background(appearance.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.65), lineWidth: 0.6)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }

    private func modeButton(_ title: String, selected: Bool, choose: @escaping @MainActor () -> Void) -> some View {
        Button {
            guard isActive() else { return }
            choose()
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? appearance.accent : appearance.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? appearance.accent : appearance.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: selected ? appearance.accent : appearance.foreground, cornerRadius: 12))
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? appearance.elevatedSurface : .clear)
                .shadow(color: selected ? appearance.subtleShadow : .clear, radius: 3, x: 0, y: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .disabled(!isActive())
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(appearance.edge.opacity(0.6))
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }

    private var authorScaleSummary: some View {
        Text("100% 为原书字号。样张仅供预览，不代表原书版式。")
            .font(.caption).foregroundStyle(appearance.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("epub.authorScale.summary")
    }

    private var typographySection: some View {
        ReaderSettingsSection(
            title: usesAuthorTypography ? "作者文字" : "文字与行距",
            detail: usesAuthorTypography ? "调整文字比例，松手应用" : "滑动预览，松手应用",
            appearance: appearance
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if usesAuthorTypography {
                    EPUBAuthorScaleAdjustment(value: $draft.fontSize, appearance: appearance,
                                              isActive: isActive, commit: commitDraft)
                    authorScaleSummary
                    Text("70%–180% · 行高随文字同比缩放")
                        .font(.caption).foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ReaderSettingAdjustment(
                        title: "字号",
                        key: "font",
                        value: $draft.fontSize,
                        range: 14...36,
                        accent: appearance.accent,
                        isActive: isActive,
                        commit: commitDraft
                    )
                    Rectangle()
                        .fill(appearance.edge.opacity(0.65))
                        .frame(height: 0.5)
                        .accessibilityHidden(true)
                    ReaderSettingAdjustment(
                        title: "行距",
                        key: "spacing",
                        value: $draft.lineSpacing,
                        range: 0...20,
                        accent: appearance.accent,
                        isActive: isActive,
                        commit: commitDraft
                    )
                }
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
            threeOptionLayout(ReaderTheme.allCases) { theme in
                themeButton(theme)
            }
        }
    }

    private var presetsSection: some View {
        ReaderSettingsSection(
            title: usesAuthorTypography ? "快捷比例" : "快捷排版",
            detail: usesAuthorTypography ? "只调整文字比例，保留阅读器行距偏好与背景" : "只调整字号和行距，保留当前背景",
            appearance: appearance
        ) {
            VStack(spacing: 8) {
                threeOptionLayout(ReaderTypographyPreset.allCases) { preset in
                    presetButton(preset)
                }
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
        let selected = usesAuthorTypography ? draft.fontSize == preset.fontSize : preset.matches(draft)
        let selectionMotionKey = reduceMotion ? 0 : (selected ? 1 : 2)
        let selectionAnimation = reduceMotion ? nil : ReaderMotion.selectionFeedback
        return Button { apply(preset) } label: {
            VStack(spacing: 4) {
                Text(presetTitle(preset))
                    .font(.subheadline.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? appearance.accent : appearance.foreground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(usesAuthorTypography ? "\(Int(preset.fontSize * 5))%" : "\(Int(preset.fontSize)) / \(Int(preset.lineSpacing))")
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
        .accessibilityLabel(usesAuthorTypography
            ? "\(presetTitle(preset))，作者文字比例 \(Int(preset.fontSize * 5))%"
            : "\(preset.title)排版，字号 \(Int(preset.fontSize))，行距 \(Int(preset.lineSpacing))")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("reader.preset.\(preset.rawValue)")
    }

    private var restoreTypographyButton: some View {
        Button {
            if isActive() { showRestore = true }
        } label: {
            Label(usesAuthorTypography ? "恢复作者原字号（100%）" : "恢复默认字号与行距", systemImage: "arrow.counterclockwise")
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: ReaderVisualStyle.minimumControlHeight, alignment: .center)
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.secondary, role: .primary, cornerRadius: 14))
        .disabled(!isActive() || (usesAuthorTypography ? draft.fontSize == 20 : ReaderTypographyPreset.standard.matches(draft)))
        .accessibilityIdentifier("reader.typography.restore")
    }

    private var diagnosticsButton: some View {
        Button {
            if developerMode, isActive() { showDiagnostics = true }
        } label: {
            Label("本书诊断", systemImage: "waveform.path.ecg")
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.sealAccent, role: .primary, cornerRadius: 12))
        .accessibilityIdentifier("reader.info.diagnostics")
        .accessibilityFocused($controlFocus, equals: "diagnostics")
    }

    private func themeButton(_ theme: ReaderTheme) -> some View {
        let selected = draft.theme == theme
        let selectionMotionKey = reduceMotion ? 0 : (selected ? 1 : 2)
        let selectionAnimation = reduceMotion ? nil : ReaderMotion.selectionFeedback
        return Button {
            guard isActive() else { return }
            draft.theme = theme
            commitDraft()
        } label: {
            VStack(spacing: 8) {
                // Miniature paper specimen swatch matching TXT reader
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
                .allowsHitTesting(false).accessibilityHidden(true)
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

    private func presetTitle(_ preset: ReaderTypographyPreset) -> String {
        guard usesAuthorTypography else { return preset.title }
        switch preset {
        case .compact: return "较小"
        case .standard: return "原字号"
        case .relaxed: return "较大"
        }
    }

    private func handleUserFontChange(_ font: EPUBUserFont?) {
        guard isActive() else { return }
        previewFontRevision &+= 1
        onUserFontChange(font)
    }

    private func apply(_ preset: ReaderTypographyPreset) {
        guard isActive() else { return }
        if usesAuthorTypography {
            // The existing preference is the scale contract; do not change reader line spacing.
            draft.fontSize = preset.fontSize
        } else {
            draft = preset.applying(to: draft)
        }
        commitDraft()
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
        commitDraft()
        close()
    }
}

/// Author-mode presentation only; the WebView owns proportional text/line-height scaling.
@MainActor
private struct EPUBAuthorScaleAdjustment: View {
    @Binding var value: Double
    let appearance: ReaderToolAppearance
    let isActive: @MainActor () -> Bool
    let commit: @MainActor () -> Void
    @State private var dragging = false
    @Environment(\.dynamicTypeSize) private var dynamicType

    private var percentage: String { "\(Int((value * 5).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dynamicType.isAccessibilitySize {
                title
                controls.frame(maxWidth: .infinity)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        title.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        controls
                    }
                    VStack(alignment: .leading, spacing: 8) { title; controls }
                }
            }
            Slider(value: sliderValue, in: 14...36, step: 1, onEditingChanged: { editing in
                dragging = editing
                if !editing, isActive() { commit() }
            })
            .tint(appearance.accent)
            .frame(minHeight: ReaderVisualStyle.minimumControlHeight)
            .disabled(!isActive())
            .accessibilityLabel("作者文字比例")
            .accessibilityValue(percentage)
            .accessibilityHint("100% 为作者原字号，每次调整 5 个百分点")
            .accessibilityIdentifier("reader.font.slider")
        }
    }

    private var title: some View {
        Text("文字比例").font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button { step(-1) } label: {
                Image(systemName: "minus").font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, cornerRadius: 22))
            .disabled(!isActive() || value <= 14)
            .accessibilityLabel("减小作者文字比例")
            .accessibilityIdentifier("reader.font.decrease")

            Text(percentage).font(.body.weight(.semibold).monospacedDigit())
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 64)
                .accessibilityLabel("作者文字比例，\(percentage)")
                .accessibilityIdentifier("reader.font.value")

            Button { step(1) } label: {
                Image(systemName: "plus").font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, cornerRadius: 22))
            .disabled(!isActive() || value >= 36)
            .accessibilityLabel("增大作者文字比例")
            .accessibilityIdentifier("reader.font.increase")
        }
        .padding(3)
        .background(appearance.accent.opacity(0.09), in: Capsule())
    }

    private var sliderValue: Binding<Double> {
        Binding(get: { value }, set: { proposed in
            guard isActive(), proposed.isFinite else { return }
            value = min(36, max(14, proposed.rounded()))
            // Keep the existing slider contract for keyboard and VoiceOver adjustments.
            if !dragging { commit() }
        })
    }

    private func step(_ delta: Double) {
        guard isActive() else { return }
        value = min(36, max(14, value + delta))
        commit()
    }
}

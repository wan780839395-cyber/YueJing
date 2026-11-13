import ReaderDomain
import SwiftUI

@MainActor
struct EPUBSettingsView: View {
    enum AuxiliaryPage: String, Identifiable {
        case diagnostics
        case license
        var id: String { rawValue }
    }

    @Binding var preferences: ReaderPreferences
    @Binding var readingMode: EPUBReadingMode
    @Binding var layoutMode: EPUBLayoutMode
    let changed: @MainActor () -> Void
    var openingSummary: String?
    var effectiveLayoutMode: EPUBLayoutMode?
    var compatibilitySummary: String?
    let runtimeDiagnostics: (@MainActor () async -> String)?
    let isActive: @MainActor () -> Bool
    let close: @MainActor () -> Void
    let appearance: ReaderToolAppearance
    @State private var draft: ReaderPreferences
    @State private var info: AuxiliaryPage?
    @State private var runtimeSummary: String?
    @State private var showRestore = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var dynamicType
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
        runtimeDiagnostics: (@MainActor () async -> String)? = nil,
        isActive: @escaping @MainActor () -> Bool,
        close: @escaping @MainActor () -> Void,
        appearance: ReaderToolAppearance
    ) {
        _preferences = preferences
        _readingMode = readingMode
        _layoutMode = layoutMode
        self.changed = changed
        self.openingSummary = openingSummary
        self.effectiveLayoutMode = effectiveLayoutMode
        self.compatibilitySummary = compatibilitySummary
        self.runtimeDiagnostics = runtimeDiagnostics
        self.isActive = isActive
        self.close = close
        self.appearance = appearance
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
                        .frame(
                            minWidth: ReaderVisualStyle.panelActionMinimumWidth,
                            minHeight: ReaderVisualStyle.minimumControlHeight
                        )
                }
                .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground, role: .primary))
                .disabled(!isActive())
                .accessibilityFocused($closeFocused)
                .accessibilityIdentifier("reader.panel.close")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if usesAuthorTypography {
                        authorScaleSummary
                    } else {
                        ReaderTypographyPreview(preferences: draft, appearance: appearance)
                    }
                    ReaderSettingsSection(title: "排版来源", detail: "默认尊重书籍排版；切换保留当前文本位置", appearance: appearance) {
                        Picker("排版来源", selection: $layoutMode) {
                            ForEach(EPUBLayoutMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(!isActive())
                        .accessibilityIdentifier("epub.layoutMode")
                        Text("原始排版保留安全支持的作者样式与未混淆字体；夜间背景优先保障可读性。复杂版式可能简化。")
                            .font(.caption).foregroundStyle(appearance.foreground.opacity(0.78))
                        if let compatibilitySummary {
                            Text(compatibilitySummary)
                                .font(.caption).foregroundStyle(appearance.foreground)
                                .accessibilityIdentifier("epub.compatibility.summary")
                        }
                    }
                    ReaderSettingsSection(title: "阅读方式", detail: "切换后保留当前文本位置", appearance: appearance) {
                        Picker("阅读方式", selection: $readingMode) {
                            ForEach(EPUBReadingMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(!isActive())
                        .accessibilityIdentifier("epub.readingMode")
                    }
                    typographySection
                    themeSection
                    presetsSection
                    epubScopeSection
                    moreSection
                    Text("当前版本：\(AppVersion.current.displayText)")
                        .font(.footnote)
                        .foregroundStyle(appearance.foreground.opacity(0.7))
                        .accessibilityIdentifier("app.version")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .accessibilityIdentifier("reader.settings.scroll")
        }
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
                ? "只恢复作者文字比例至 100%。保留阅读器行距偏好、当前背景和阅读位置。"
                : "恢复为字号 20、行距 7。保留当前阅读背景，不改变阅读位置。")
        }
        .sheet(item: $info, onDismiss: {
            if voiceOver, isActive() { closeFocused = true }
        }) { page in
            NavigationStack {
                Group {
                    if page == .diagnostics {
                        ReaderDiagnosticsView(openingSummary: [openingSummary, runtimeSummary].compactMap { $0 }.joined(separator: "\n\n"))
                            .task {
                                runtimeSummary = nil
                                guard isActive(), let runtimeDiagnostics else { return }
                                let value = await runtimeDiagnostics()
                                guard !Task.isCancelled, isActive() else { return }
                                runtimeSummary = value
                            }
                    } else {
                        ScrollView {
                            Text(LibraryLicenseView.bundledLicenseText())
                                .font(.footnote)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .navigationTitle("GRDB & ZIPFoundation · MIT")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { info = nil } label: {
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
        }
        .accessibilityAction(.escape) { finish() }
        .onDisappear { draft = preferences.validated }
    }

    private var usesAuthorTypography: Bool { (effectiveLayoutMode ?? layoutMode) == .original }

    private var authorScaleSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("作者文字比例").font(.caption.weight(.medium))
                .foregroundStyle(appearance.secondary)
            Text("\(Int((draft.fontSize * 5).rounded()))%")
                .font(.system(.title, design: .serif).weight(.medium).monospacedDigit())
            Text("100% 为作者原字号。这里只显示比例，不预览书内字体或版式。")
                .font(.footnote).foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(appearance.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("epub.authorScale.summary")
    }

    private var typographySection: some View {
        ReaderSettingsSection(
            title: usesAuthorTypography ? "作者文字" : "文字",
            detail: usesAuthorTypography ? "调整文字比例，松手应用并恢复文本位置" : "滑动预览，松手应用并按文本锚点恢复",
            appearance: appearance
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if usesAuthorTypography {
                    EPUBAuthorScaleAdjustment(value: $draft.fontSize, appearance: appearance,
                                              isActive: isActive, commit: commitDraft)
                    Text("70%–180%，100% 为作者原字号。保留字体、字重和文字层级；行高随文字同比缩放，不单独调整作者行距。仅调整文字，不做整页缩放；作者相对尺寸会随文字重排。")
                        .font(.caption).foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ReaderSettingAdjustment(
                        title: "字号",
                        key: "font",
                        value: $draft.fontSize,
                        range: 14...36,
                        accent: appearance.foreground,
                        isActive: isActive,
                        commit: commitDraft
                    )
                    Divider().overlay(appearance.edge)
                    ReaderSettingAdjustment(
                        title: "行距",
                        key: "spacing",
                        value: $draft.lineSpacing,
                        range: 0...20,
                        accent: appearance.foreground,
                        isActive: isActive,
                        commit: commitDraft
                    )
                }
            }
        }
    }

    private var themeSection: some View {
        ReaderSettingsSection(title: "阅读背景", detail: "仅影响阅读界面", appearance: appearance) {
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
                .padding(4)
                .background(appearance.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                restoreTypographyButton
            }
        }
    }

    private var epubScopeSection: some View {
        ReaderSettingsSection(title: "EPUB 首版范围", detail: "可重排阅读与安全限制", appearance: appearance) {
            Text("支持可重排 XHTML、本地静态图片及安全净化的作者 CSS、未混淆 TTF/OTF 字体。原始排版可按比例调整作者文字，行高同比缩放；切换阅读器排版可单独调整行距。复杂容器与表格不保证像素保真，不支持固定版式、DRM、混淆字体、脚本、表单、联网资源及 EPUB 书签。")
                .font(.caption)
                .foregroundStyle(appearance.foreground.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("epub.settings.scopeNote")
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
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(usesAuthorTypography ? "\(Int(preset.fontSize * 5))%" : "\(Int(preset.fontSize)) / \(Int(preset.lineSpacing))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(appearance.foreground.opacity(selected ? 0.92 : 0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(minWidth: 84, maxWidth: .infinity, minHeight: 68)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground))
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(selected ? appearance.surface : .clear)
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
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.secondary))
        .disabled(!isActive() || (usesAuthorTypography ? draft.fontSize == 20 : ReaderTypographyPreset.standard.matches(draft)))
        .accessibilityIdentifier("reader.typography.restore")
    }

    private var moreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { diagnosticsButton; licenseButton }
                VStack(alignment: .leading, spacing: 4) { diagnosticsButton; licenseButton }
            }
            .font(.footnote)
            .disabled(!isActive())
            Text("加减和快捷排版立即重排并恢复当前文本锚点；“完成”只关闭面板。")
                .font(.caption)
                .foregroundStyle(appearance.foreground.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var diagnosticsButton: some View {
        Button {
            if isActive() { info = .diagnostics }
        } label: {
            Label("诊断与耗时", systemImage: "ladybug").frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityIdentifier("reader.info.diagnostics")
    }

    private var licenseButton: some View {
        Button {
            if isActive() { info = .license }
        } label: {
            Text("开源许可").frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityIdentifier("reader.info.license")
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
            VStack(spacing: 6) {
                Text("阅").font(.system(size: 22))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(Color(uiColor: theme.foreground))
                    .background(Color(uiColor: theme.background), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(theme.title).font(.caption).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(minWidth: 84, maxWidth: .infinity, minHeight: 64)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected ? appearance.selection : .clear)
                    .allowsHitTesting(false)
                    .animation(selectionAnimation, value: selectionMotionKey)
                    .transaction { transaction in
                        if reduceMotion { transaction.animation = nil }
                    }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(appearance.foreground)
                    .padding(6)
                    .opacity(selected ? 1 : 0)
                    .animation(selectionAnimation, value: selectionMotionKey)
                    .transaction { transaction in
                        if reduceMotion { transaction.animation = nil }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground))
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
            .frame(minHeight: ReaderVisualStyle.minimumControlHeight)
            .disabled(!isActive())
            .accessibilityLabel("作者文字比例")
            .accessibilityValue(percentage)
            .accessibilityHint("100% 为作者原字号，每次调整 5 个百分点")
            .accessibilityIdentifier("reader.font.slider")
        }
    }

    private var title: some View {
        Text("文字比例").font(.subheadline.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button { step(-1) } label: {
                Image(systemName: "minus").font(.body.weight(.medium))
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground))
            .disabled(!isActive() || value <= 14)
            .accessibilityLabel("减小作者文字比例")
            .accessibilityIdentifier("reader.font.decrease")
            Text(percentage).font(.body.monospacedDigit())
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 64)
                .accessibilityLabel("作者文字比例，\(percentage)")
                .accessibilityIdentifier("reader.font.value")
            Button { step(1) } label: {
                Image(systemName: "plus").font(.body.weight(.medium))
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground))
            .disabled(!isActive() || value >= 36)
            .accessibilityLabel("增大作者文字比例")
            .accessibilityIdentifier("reader.font.increase")
        }
        .padding(2)
        .background(appearance.selection, in: Capsule())
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

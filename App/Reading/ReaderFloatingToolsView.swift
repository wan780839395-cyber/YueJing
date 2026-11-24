import ReaderDomain
import SwiftUI

/// Caps vertical height without stretching shorter content to `maxHeight`.
private struct BoundedHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let cappedHeight = min(proposal.height ?? maxHeight, maxHeight)
        let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: cappedHeight))
        return CGSize(width: size.width, height: min(size.height, cappedHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

@MainActor
struct ReaderFloatingToolsView: View {
    let state: ReadingToolsPresentation
    let metrics: ReaderToolMetrics
    let appearance: ReaderToolAppearance
    let directoryAvailable: Bool
    let settingsAvailable: Bool
    let exitSaveFailed: Bool
    let rememberFocus: @MainActor (String) -> Void
    let open: @MainActor (ReadingToolPanel) -> Void
    @AccessibilityFocusState.Binding var focusedControl: String?
    // Unified chapter panel for TXT and EPUB; nil or blank falls back to neutral unconfirmed text.
    var chapterContext: String? = nil
    var returnFromSearch: (@MainActor () -> Void)? = nil
    @ObservedObject var autoRead: AutoReadSession
    let speech: ReaderSpeechSession
    let autoReadMode: AutoReadMode
    let autoReadAvailable: Bool
    let speechAvailable: Bool
    let startAutoRead: @MainActor () -> Void
    let startSpeech: @MainActor () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var measuredContentHeight: CGFloat = 0

    private var visible: Bool { state.visible && state.panel == nil }
    private var canReturnFromSearch: Bool {
        returnFromSearch != nil && visible && state.canInteract && state.exitRequest == nil && !exitSaveFailed
    }
    private var resolvedChapterContext: String {
        let trimmed = chapterContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "章节尚未确认" : trimmed
    }

    var body: some View {
        let allowAnimation = !reduceMotion && !state.suspended
        ZStack(alignment: .bottomTrailing) {
            if autoRead.isRunning, state.canInteract, state.panel == nil, state.exitRequest == nil {
                dockSurface(cornerRadius: 18) {
                    HStack(spacing: 4) {
                        AutoReadControl(
                            session: autoRead,
                            mode: autoReadMode,
                            available: true,
                            appearance: appearance,
                            start: startAutoRead
                        )
                        ReaderSpeechControl(session: speech, available: speechAvailable, start: startSpeech)
                    }
                }
                .frame(maxWidth: ReaderVisualStyle.toolPanelMaximumWidth)
            } else if visible, state.canInteract {
                VStack(alignment: .trailing, spacing: 8) {
                    if canReturnFromSearch, let returnFromSearch {
                        dockSurface(cornerRadius: 26) {
                            returnFromSearchButton(action: returnFromSearch)
                        }
                        .transition(.opacity)
                    }
                    chapterPanel(resolvedChapterContext)
                        .transition(allowAnimation ? .opacity.combined(with: .offset(y: ReaderMotion.hiddenTravel)) : .identity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .foregroundStyle(appearance.foreground).tint(appearance.accent)
        .animation(allowAnimation ? ReaderMotion.toolVisibility : nil, value: visible)
        .animation(allowAnimation ? ReaderMotion.toolVisibility : nil, value: canReturnFromSearch)
        .transaction { transaction in
            if !allowAnimation { transaction.animation = nil }
        }
        .allowsHitTesting((visible || autoRead.isRunning) && state.canInteract && state.panel == nil)
        .accessibilityHidden(!visible && !autoRead.isRunning)
    }

    private func chapterPanel(_ context: String) -> some View {
        let maximumHeight: CGFloat = metrics.compactHeight ? 144 : (dynamicType.isAccessibilitySize ? 300 : 240)
        let topSheen = Color.white.opacity(appearance.theme == .dark ? 0.08 : 0.65)
        let needsScroll = measuredContentHeight > maximumHeight + 0.5
        return BoundedHeightLayout(maxHeight: maximumHeight) {
            Group {
                if needsScroll {
                    ScrollView(.vertical) {
                        measuredToolContent(context)
                    }
                    .frame(height: maximumHeight)
                } else {
                    measuredToolContent(context)
                }
            }
            .transaction { transaction in transaction.animation = nil }
            .onPreferenceChange(ToolContentHeightKey.self) { height in
                guard visible, state.canInteract else { return }
                if abs(measuredContentHeight - height) > 0.5 {
                    measuredContentHeight = height
                }
            }
        }
        .frame(maxWidth: ReaderVisualStyle.toolPanelMaximumWidth)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(appearance.elevatedSurface)
                .shadow(color: appearance.shadow, radius: 16, x: 0, y: 6)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [topSheen, appearance.edge.opacity(0.85)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.85
                        )
                }
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func measuredToolContent(_ context: String) -> some View {
        toolContent(context)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ToolContentHeightKey.self, value: proxy.size.height)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

    private func toolContent(_ context: String) -> some View {
        VStack(spacing: 0) {
            chapterPanelContent(context)
            Divider().padding(.horizontal, 12).accessibilityHidden(true)
            ReaderToolsPlaybackSection(
                autoRead: autoRead,
                speech: speech,
                autoReadMode: autoReadMode,
                autoReadAvailable: autoReadAvailable,
                speechAvailable: speechAvailable,
                appearance: appearance,
                startAutoRead: startAutoRead,
                startSpeech: startSpeech
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func chapterPanelContent(_ context: String) -> some View {
        let stacked = dynamicType.isAccessibilitySize || (dynamicType >= .xxLarge && !metrics.compactHeight)
        if stacked {
            VStack(alignment: .leading, spacing: 10) {
                chapterSummary(context)
                if dynamicType.isAccessibilitySize {
                    VStack(spacing: 6) {
                        panelDirectoryButton(fillsWidth: true)
                        panelSettingsButton(fillsWidth: true)
                    }
                } else {
                    HStack(spacing: 8) {
                        panelDirectoryButton(fillsWidth: true)
                        panelSettingsButton(fillsWidth: true)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, metrics.compactHeight ? 10 : 12)
        } else {
            HStack(alignment: .center, spacing: 10) {
                chapterSummary(context)
                Rectangle()
                    .fill(appearance.edge.opacity(0.65))
                    .frame(width: 0.5, height: 26)
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    panelDirectoryButton(fillsWidth: false)
                    panelSettingsButton(fillsWidth: false)
                }
                .layoutPriority(1)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, metrics.compactHeight ? 6 : 8)
        }
    }

    private func chapterSummary(_ context: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Capsule()
                .fill(appearance.accent)
                .frame(width: 3, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if !metrics.compactHeight && !dynamicType.isAccessibilitySize {
                    Text("当前章节")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(appearance.secondary)
                        .accessibilityHidden(true)
                }
                Text(context)
                    .font(dynamicType.isAccessibilitySize
                          ? .system(.body, design: .serif).weight(.semibold)
                          : .system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(appearance.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("当前章节，\(context)")
                    .accessibilityIdentifier("reader.tools.chapterContext")
            }
        }
    }

    private func panelDirectoryButton(fillsWidth: Bool) -> some View {
        panelButton("目录", accessibilityTitle: "目录", symbol: "list.bullet", panel: .directory, key: "directory",
                    available: directoryAvailable, fillsWidth: fillsWidth)
    }

    private func panelSettingsButton(fillsWidth: Bool) -> some View {
        panelButton("设置", accessibilityTitle: "阅读设置", symbol: "textformat.size", panel: .settings, key: "settings",
                    available: settingsAvailable, fillsWidth: fillsWidth)
            .accessibilityHint("调整文字、行距和阅读背景")
    }

    private func panelButton(_ title: String, accessibilityTitle: String, symbol: String, panel: ReadingToolPanel,
                             key: String, available: Bool, fillsWidth: Bool) -> some View {
        Button {
            guard visible, state.canInteract, available, !exitSaveFailed else { return }
            rememberFocus(key)
            open(panel)
        } label: {
            Label(title, systemImage: symbol)
                .font(dynamicType.isAccessibilitySize ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                .imageScale(.medium)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minWidth: 44, maxWidth: fillsWidth ? .infinity : nil, minHeight: metrics.controlHeight)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, role: .primary, cornerRadius: 16))
        .disabled(!available || exitSaveFailed || !state.canInteract)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityIdentifier("reader.tools.\(key)")
        .accessibilityFocused($focusedControl, equals: key)
    }

    private func returnFromSearchButton(action: @escaping @MainActor () -> Void) -> some View {
        Button {
            guard visible, state.canInteract, state.exitRequest == nil, !exitSaveFailed else { return }
            action()
        } label: {
            Label("回到搜索前", systemImage: "arrow.uturn.backward")
                .font(dynamicType.isAccessibilitySize ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                .imageScale(.medium)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .frame(minWidth: 44, minHeight: metrics.controlHeight)
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, role: .primary, cornerRadius: 22))
        .disabled(exitSaveFailed || !state.canInteract)
        .accessibilityLabel("回到搜索前")
        .accessibilityHint("返回搜索跳转前的位置")
        .accessibilityIdentifier("reader.tools.returnFromSearch")
        .accessibilityFocused($focusedControl, equals: "returnFromSearch")
    }

    private func dockSurface<Content: View>(cornerRadius: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        let topSheen = Color.white.opacity(appearance.theme == .dark ? 0.08 : 0.65)
        return content()
            .padding(5)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(appearance.elevatedSurface)
                    .shadow(color: appearance.shadow, radius: 14, x: 0, y: 5)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(colors: [topSheen, appearance.edge.opacity(0.85)],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 0.85
                            )
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

private struct ToolContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor
private struct ReaderToolsPlaybackSection: View {
    @ObservedObject var autoRead: AutoReadSession
    @ObservedObject var speech: ReaderSpeechSession
    let autoReadMode: AutoReadMode
    let autoReadAvailable: Bool
    let speechAvailable: Bool
    let appearance: ReaderToolAppearance
    let startAutoRead: @MainActor () -> Void
    let startSpeech: @MainActor () -> Void

    var body: some View {
        if speech.isActive {
            VStack(spacing: 0) {
                ReaderSpeechControl(session: speech, available: speechAvailable, start: startSpeech)
                if autoReadAvailable {
                    Button("切换为自动阅读", action: startAutoRead)
                        .font(.footnote)
                        .frame(minHeight: 44)
                }
            }
        } else {
            AdaptiveToolsRowLayout(horizontalSpacing: 2, verticalSpacing: 0) {
                AutoReadControl(
                    session: autoRead,
                    mode: autoReadMode,
                    available: autoReadAvailable,
                    appearance: appearance,
                    start: startAutoRead
                )
                ReaderSpeechControl(session: speech, available: speechAvailable, start: startSpeech)
            }
        }
    }
}

@MainActor
private struct AdaptiveToolsRowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let first = subviews[0].sizeThatFits(.unspecified)
        let second = subviews[1].sizeThatFits(.unspecified)
        let horizontalWidth = first.width + horizontalSpacing + second.width
        if let proposedWidth = proposal.width, proposedWidth.isFinite, horizontalWidth > proposedWidth + 0.5 {
            let wrappedFirst = subviews[0].sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
            let wrappedSecond = subviews[1].sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
            return CGSize(
                width: min(proposedWidth, max(wrappedFirst.width, wrappedSecond.width)),
                height: wrappedFirst.height + verticalSpacing + wrappedSecond.height
            )
        }
        return CGSize(width: horizontalWidth, height: max(first.height, second.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let first = subviews[0].sizeThatFits(.unspecified)
        let second = subviews[1].sizeThatFits(.unspecified)
        let horizontalWidth = first.width + horizontalSpacing + second.width
        if horizontalWidth > bounds.width + 0.5 {
            let wrappedFirst = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let wrappedSecond = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(
                at: CGPoint(x: bounds.midX - wrappedFirst.width / 2, y: bounds.minY),
                proposal: ProposedViewSize(width: wrappedFirst.width, height: wrappedFirst.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.midX - wrappedSecond.width / 2, y: bounds.minY + wrappedFirst.height + verticalSpacing),
                proposal: ProposedViewSize(width: wrappedSecond.width, height: wrappedSecond.height)
            )
        } else {
            let totalWidth = first.width + horizontalSpacing + second.width
            let startX = bounds.midX - totalWidth / 2
            subviews[0].place(
                at: CGPoint(x: startX, y: bounds.midY - first.height / 2),
                proposal: ProposedViewSize(width: first.width, height: first.height)
            )
            subviews[1].place(
                at: CGPoint(x: startX + first.width + horizontalSpacing, y: bounds.midY - second.height / 2),
                proposal: ProposedViewSize(width: second.width, height: second.height)
            )
        }
    }
}

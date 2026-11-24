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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType

    private var visible: Bool { state.visible && state.panel == nil }
    private var canReturnFromSearch: Bool {
        returnFromSearch != nil && visible && state.canInteract && state.exitRequest == nil && !exitSaveFailed
    }
    private var resolvedChapterContext: String {
        let trimmed = chapterContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "章节尚未确认" : trimmed
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if visible {
                VStack(alignment: .trailing, spacing: 8) {
                    if canReturnFromSearch, let returnFromSearch {
                        dockSurface(cornerRadius: 26) {
                            returnFromSearchButton(action: returnFromSearch)
                        }
                        .transition(.opacity)
                    }
                    chapterPanel(resolvedChapterContext)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: ReaderMotion.hiddenTravel)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .foregroundStyle(appearance.foreground).tint(appearance.accent)
        .animation(reduceMotion ? nil : ReaderMotion.toolVisibility, value: visible)
        .animation(reduceMotion ? nil : ReaderMotion.toolVisibility, value: canReturnFromSearch)
        .allowsHitTesting(visible && state.canInteract).accessibilityHidden(!visible)
    }

    private func chapterPanel(_ context: String) -> some View {
        let maximumHeight: CGFloat = metrics.compactHeight ? 144 : (dynamicType.isAccessibilitySize ? 300 : 240)
        let topSheen = Color.white.opacity(appearance.theme == .dark ? 0.08 : 0.65)
        return BoundedHeightLayout(maxHeight: maximumHeight) {
            ViewThatFits(in: .vertical) {
                chapterPanelContent(context)
                ScrollView(.vertical) {
                    chapterPanelContent(context)
                }
                .frame(height: maximumHeight)
            }
        }
        .frame(maxWidth: ReaderVisualStyle.toolPanelMaximumWidth)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(appearance.elevatedSurface)
                .shadow(color: appearance.shadow, radius: 16, x: 0, y: 6)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [topSheen, appearance.edge.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.85
                )
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [topSheen, appearance.edge.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.85
                    )
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

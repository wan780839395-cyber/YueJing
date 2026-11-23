import ReaderDomain
import SwiftUI
import UIKit

/// Presentation only: short chapter transitions must not revive opening chrome.
enum EPUBReaderLoadingPresentation {
    static func showsFeedback(initialOpening: Bool, phase: EPUBOpeningFeedback) -> Bool {
        initialOpening || phase != .quiet
    }

    static func restoresTools(initialOpening: Bool) -> Bool { initialOpening }
}

/// Read-only chrome summary. A navigation target is not a confirmed visible chapter.
/// Multiple TOC anchors in one document need finer location evidence; never guess the first.
enum EPUBReaderChapterContext {
    static func title(in items: [EPUBNavigationItem], path: String?, confirmedPath: String?) -> String? {
        guard let path, !path.isEmpty, path == confirmedPath else { return nil }
        let matches = items.filter { $0.path == path }
        guard matches.count == 1, let item = matches.first else { return nil }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}

@MainActor
struct EPUBReaderScreen: View {
    @ObservedObject var model: EPUBReaderViewModel
    let routeID: UUID
    let onExit: @MainActor () -> Void
    @State private var tools = ReadingToolsPresentation()
    @State private var lastPanelControl: String?
    @State private var selectedDetent: PresentationDetent = .large
    @State private var loadingFeedback = EPUBOpeningFeedback.quiet
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @ScaledMetric(relativeTo: .body) private var controlHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .headline) private var titleLine: CGFloat = 22
    @AccessibilityFocusState private var focusedControl: String?

    var body: some View {
        GeometryReader { geometry in
            let metrics = ReaderToolMetrics(
                height: geometry.size.height,
                scaledControl: controlHeight,
                titleLine: titleLine,
                accessibilityFont: dynamicType.isAccessibilitySize
            )
            let appearance = ReaderToolAppearance(
                theme: model.preferences.theme,
                reduceTransparency: reduceTransparency
            )
            ZStack {
                EPUBWebView(
                    request: model.navigationRequest,
                    preferences: model.preferences,
                    handle: model.webView,
                    onLocatorEvent: model.handleLocatorEvent,
                    onLoadFailure: model.handleLoadFailure,
                    onInternalLink: model.navigateToInternalLink,
                    onChapterBoundary: model.turnChapter,
                    onPreloadFailure: model.handlePreloadFailure,
                    interactionEnabled: model.ready && !model.loading && !model.exitSaveFailed &&
                        tools.canInteract && tools.panel == nil,
                    toolIntent: { tools.intent },
                    onToolsInteraction: handleToolsInteraction
                )
                .ignoresSafeArea(.container, edges: .bottom)
                .allowsHitTesting(model.acceptsCanvasTouch && tools.exitRequest == nil && tools.panel == nil)
                .accessibilityHidden(!model.ready || model.loading || tools.panel != nil || tools.exitRequest != nil)
                .accessibilityAction(named: Text("显示阅读工具")) { mutateTools { $0.show() } }
                .accessibilityAction(named: Text("退出阅读")) { exitReader() }
                .accessibilityAction(named: Text("下一屏")) { _ = model.webView.controller?.turnPage(.next) }
                .accessibilityAction(named: Text("上一屏")) { _ = model.webView.controller?.turnPage(.previous) }
                .overlay {
                    if model.openingPerformanceSummary == nil && (!model.ready || model.loading) {
                        Color(uiColor: model.preferences.theme.background)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .transition(.identity)
                    }
                }

                if model.loading && tools.exitRequest == nil && tools.valid &&
                    EPUBReaderLoadingPresentation.showsFeedback(
                        initialOpening: model.openingPerformanceSummary == nil, phase: loadingFeedback
                    ) {
                    VStack(spacing: 14) {
                        Text(model.title)
                            .font(.system(.headline, design: .serif).weight(.semibold))
                            .foregroundStyle(appearance.foreground)
                            .multilineTextAlignment(.center)
                        Group {
                            if loadingFeedback == .quiet {
                                Text("正在打开")
                                    .font(.subheadline)
                            } else {
                                HStack(spacing: 8) {
                                    ProgressView().tint(appearance.accent)
                                    Text(loadingFeedback == .detailed ? model.loadingStage :
                                        (model.openingPerformanceSummary == nil ? "正在打开" : "正在切换章节"))
                                        .font(.subheadline)
                                }
                            }
                        }
                        .foregroundStyle(appearance.secondary)
                        .frame(minHeight: 24)
                        if loadingFeedback == .detailed {
                            Text(model.openingPerformanceSummary == nil
                                ? "正在校验书籍并恢复阅读位置。可返回书架停止，已保存记录保留。"
                                : "正在定位目标章节。可返回书架停止，已保存记录保留。")
                                .font(.footnote)
                                .foregroundStyle(appearance.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if model.openingPerformanceSummary != nil {
                            Button { exitReader() } label: {
                                Text("返回书架，停止切换")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 16)
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(ReaderCompactButtonStyle(tint: appearance.sealAccent, role: .primary))
                            .disabled(!tools.canInteract)
                            .accessibilityIdentifier("epub.navigation.cancel")
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                    .frame(maxWidth: 320)
                    .background(appearance.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(appearance.edge.opacity(0.85), lineWidth: 0.75)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: appearance.shadow, radius: 14, x: 0, y: 6)
                    .padding(.horizontal, 24)
                    .accessibilityElement(children: model.openingPerformanceSummary == nil ? .combine : .contain)
                    .accessibilityIdentifier("epub.opening.feedback")
                    .accessibilityHidden(tools.panel != nil)
                    .transaction { $0.animation = nil }
                }

                if !model.loading && !model.ready && model.navigationRequest == nil && tools.exitRequest == nil && tools.valid {
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(appearance.accentSoft)
                                .frame(width: 52, height: 52)
                            Image(systemName: "book.closed")
                                .font(.title2.weight(.medium))
                                .foregroundStyle(appearance.accent)
                        }
                        .accessibilityHidden(true)
                        Text("暂时无法显示正文")
                            .font(.system(.headline, design: .serif).weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Button { Task { await model.retry() } } label: {
                            Text("重试打开")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 22)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, role: .primary))
                    }
                    .padding(24)
                    .background(appearance.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(appearance.edge, lineWidth: 0.75)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: appearance.shadow, radius: 14, x: 0, y: 6)
                    .accessibilityHidden(tools.panel != nil)
                    .disabled(tools.exitRequest != nil)
                }

                ZStack {
                    if tools.visible && tools.panel == nil {
                        edgeScrims(theme: model.preferences.theme)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : ReaderMotion.toolVisibility, value: tools.visible && tools.panel == nil)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                VStack(spacing: 0) {
                    titleBar(metrics: metrics, appearance: appearance)
                    if model.ready && !model.loading && tools.valid && tools.panel == nil,
                       let notice = model.compatibilityNotice {
                        compatibilityBanner(notice, appearance: appearance)
                    }
                    Spacer(minLength: 0)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                ReaderFloatingToolsView(
                    state: tools,
                    metrics: metrics,
                    appearance: appearance,
                    directoryAvailable: model.ready,
                    settingsAvailable: model.ready,
                    exitSaveFailed: model.exitSaveFailed,
                    rememberFocus: { lastPanelControl = $0 },
                    open: openPanel,
                    focusedControl: $focusedControl,
                    chapterContext: chapterContextText,
                    returnFromSearch: model.canReturnFromSearch ? { Task { await model.returnFromSearch() } } : nil
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            .foregroundStyle(appearance.foreground)
            .tint(appearance.accent)
        }
        .background(Color(uiColor: model.preferences.theme.background).ignoresSafeArea())
        .background {
            EPUBPresentationProbe(
                token: tools.valid && tools.canInteract && tools.panel == nil && tools.exitRequest == nil
                    ? model.presentationToken : nil,
                observed: model.recordPresentationFrame
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .environment(\.colorScheme, model.preferences.theme == .dark ? .dark : .light)
        .sheet(item: panelPresentation) { session in
            panelHost(session: session)
        }
        .task(id: routeID) {
            await model.load()
        }
        .task(id: model.loading) {
            loadingFeedback = .quiet
            guard model.loading else { return }
            let started = model.loadingFeedbackStart ?? ContinuousClock.now
            do {
                try await Task.sleep(until: started.advanced(by: EPUBOpeningFeedback.compactDelay), clock: .continuous)
                guard !Task.isCancelled, model.loading else { return }
                loadingFeedback = .compact
                try await Task.sleep(until: started.advanced(by: EPUBOpeningFeedback.detailedDelay), clock: .continuous)
                guard !Task.isCancelled, model.loading else { return }
                loadingFeedback = .detailed
            } catch { return } // Cancellation removes feedback; it never retries or delays navigation.
        }
        .task(id: tools.intent) {
            let intent = tools.intent
            guard voiceOver, tools.visible, tools.panel == nil else { return }
            await Task.yield()
            if !Task.isCancelled, tools.intent == intent, tools.panel == nil {
                focusedControl = lastPanelControl ?? "back"
            }
        }
        .onChange(of: model.loading) { loading in
            if loading, EPUBReaderLoadingPresentation.restoresTools(
                initialOpening: model.openingPerformanceSummary == nil
            ) { mutateTools { $0.forceCompact() } }
        }
        .onChange(of: model.exitSaveFailed) { failed in
            if failed { mutateTools { $0.forceCompact() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            mutateTools { $0.suspend() }
            Task { await model.suspend() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            mutateTools { $0.resume() }
            Task { await model.resume() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await model.releaseReaderMemory() }
        }
        .alert(
            "阅读提示",
            isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
        ) {
            if model.exitSaveFailed {
                Button("保留已保存位置并返回", role: .destructive) { exitReader(keepingSavedPosition: true) }
            } else {
                Button("知道了", role: .cancel) { model.message = nil }
            }
        } message: {
            Text(model.message ?? "")
        }
    }

    private var chapterContextText: String {
        guard tools.visible, tools.panel == nil else { return "章节尚未确认" }
        if model.loading { return "正在确认章节…" }
        return EPUBReaderChapterContext.title(
            in: model.navigationItems,
            path: model.currentPath,
            confirmedPath: model.presentationToken?.path
        ) ?? "章节尚未确认"
    }

    @ViewBuilder
    private func panelHost(session: ReaderPanelSession) -> some View {
        let appearance = ReaderToolAppearance(
            theme: model.preferences.theme,
            reduceTransparency: reduceTransparency
        )
        Group {
            if session.panel == .directory {
                EPUBContentsView(
                    sessionID: session.id,
                    items: model.navigationItems,
                    currentPath: model.currentPath,
                    currentFragment: model.currentFragment,
                    ownerActive: panelActive(.directory, session.id),
                    isActive: { panelActive(.directory, session.id) },
                    close: { closePanel(session.id) },
                    appearance: appearance,
                    selected: { item in selectNavigationItem(item, session.id) },
                    bookmarkActions: bookmarkActions(for: session.id),
                    searchActions: searchActions(for: session.id)
                )
                .id(session.id) // No query/presented/reveal state shared by quick reopens.
            } else {
                EPUBSettingsView(
                    preferences: settingsBinding(for: session.id),
                    readingMode: Binding(
                        get: { model.readingMode },
                        set: { mode in
                            guard panelActive(.settings, session.id) else { return }
                            model.setReadingMode(mode)
                        }
                    ),
                    layoutMode: Binding(
                        get: { model.layoutMode },
                        set: { mode in
                            guard panelActive(.settings, session.id) else { return }
                            model.setLayoutMode(mode)
                        }
                    ),
                    changed: {
                        if panelActive(.settings, session.id) {
                            model.settingsChanged()
                        }
                    },
                    openingSummary: model.diagnosticOpeningSummary,
                    effectiveLayoutMode: model.effectiveLayoutMode,
                    compatibilitySummary: model.compatibilitySummary,
                    fontDiagnostics: model.styleCompatibility?.fontDiagnostics ?? [],
                    compatibilityDetails: model.bookCompatibilityDetails,
                    runtimeDiagnostics: {
                        await model.webView.controller?.performanceSummary() ?? "阅读器已释放。"
                    },
                    isActive: { panelActive(.settings, session.id) },
                    close: { closePanel(session.id) },
                    appearance: appearance,
                    userFontID: model.userFontID,
                    onUserFontChange: { font in
                        guard panelActive(.settings, session.id) else { return }
                        model.setUserFont(font)
                    }
                )
            }
        }
        .padding(.top, ReaderVisualStyle.panelTopInset)
        .background(appearance.surface.ignoresSafeArea())
        .foregroundStyle(appearance.foreground)
        .tint(appearance.accent)
        .environment(\.colorScheme, model.preferences.theme == .dark ? .dark : .light)
        .presentationDetents(session.panel == .directory ? [.large] : [.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(ReaderVisualStyle.panelCornerRadius)
    }

    private func settingsBinding(for panelID: UUID) -> Binding<ReaderPreferences> {
        Binding(
            get: { model.preferences },
            set: { value in
                guard panelActive(.settings, panelID), !model.exitSaveFailed else { return }
                model.preferences = value
            }
        )
    }

    private func compatibilityBanner(_ notice: String, appearance: ReaderToolAppearance) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(notice)
                .font(.footnote)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)

            Button(action: model.dismissCompatibilityNotice) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 44, minHeight: ReaderVisualStyle.minimumControlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ReaderCompactButtonStyle(tint: appearance.secondary, cornerRadius: 12))
            .accessibilityLabel("关闭兼容排版提示")
            .accessibilityHint("关闭后仍可在排版设置查看兼容说明")
            .accessibilityIdentifier("epub.compatibility.dismiss")
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(appearance.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(appearance.sealAccent)
                .frame(width: 3)
                .padding(.leading, 10)
                .padding(.vertical, 12)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.9), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: appearance.subtleShadow, radius: 8, x: 0, y: 3)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        // Stay in the existing safe-area overlay; never inset or resize the reading canvas.
        .transition(.identity)
        .accessibilityIdentifier("epub.compatibility.notice")
    }

    private func titleBar(metrics: ReaderToolMetrics, appearance: ReaderToolAppearance) -> some View {
        let visible = tools.visible && tools.panel == nil
        return ZStack {
            if visible {
                titleBarContent(metrics: metrics, appearance: appearance)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -ReaderMotion.hiddenTravel)))
            }
        }
        .animation(reduceMotion ? nil : ReaderMotion.toolVisibility, value: visible)
        .allowsHitTesting(visible && tools.canInteract)
        .accessibilityHidden(!visible)
    }

    private func edgeScrims(theme: ReaderTheme) -> some View {
        let bg = Color(uiColor: theme.background)
        return VStack(spacing: 0) {
            LinearGradient(
                colors: [bg.opacity(0.96), bg.opacity(0.82), bg.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 82)
            .ignoresSafeArea(.container, edges: .top)
            Spacer(minLength: 0)
            LinearGradient(
                colors: [bg.opacity(0), bg.opacity(0.84), bg.opacity(0.96)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 88)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func titleBarContent(metrics: ReaderToolMetrics, appearance: ReaderToolAppearance) -> some View {
        let topSheen = Color.white.opacity(appearance.theme == .dark ? 0.08 : 0.65)
        return HStack(spacing: 10) {
            Button { exitReader() } label: {
                Group {
                    if tools.exitRequest != nil {
                        ProgressView().tint(appearance.accent)
                    } else {
                        Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold))
                    }
                }
                .foregroundStyle(appearance.foreground)
                .frame(minWidth: 44, minHeight: 44)
                .background(appearance.card.opacity(0.85), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(appearance.edge.opacity(0.55), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!tools.canInteract)
            .accessibilityLabel("返回书架")
            .accessibilityIdentifier("reader.exit")
            .accessibilityFocused($focusedControl, equals: "back")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.system(.headline, design: .serif).weight(.semibold))
                    .foregroundStyle(appearance.foreground)
                    .lineLimit(metrics.verticalButtons ? 2 : 1)
                    .accessibilityLabel("书名，\(model.title)")
                if !metrics.compactHeight {
                    Text("EPUB · \(model.readingMode.title)")
                        .font(.caption2)
                        .foregroundStyle(appearance.secondary)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !metrics.compactHeight && !dynamicType.isAccessibilitySize {
                Text(model.effectiveLayoutMode.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(appearance.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(appearance.accentSoft, in: Capsule())
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .frame(minHeight: metrics.titleHeight)
        .background(appearance.elevatedSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
                .allowsHitTesting(false)
        }
        .shadow(color: appearance.shadow, radius: 12, x: 0, y: 4)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .transaction { transaction in transaction.animation = nil }
    }

    private var panelPresentation: Binding<ReaderPanelSession?> {
        let expected = tools.panelID
        return Binding(
            get: {
                guard let id = tools.panelID, let panel = tools.panel else { return nil }
                return ReaderPanelSession(id: id, panel: panel)
            },
            set: { value in
                guard value == nil, let expected else { return }
                closePanel(expected)
            }
        )
    }

    private func panelActive(_ panel: ReadingToolPanel, _ id: UUID) -> Bool {
        tools.owns(panel, id: id) && !model.exitSaveFailed
    }

    private func mutateTools(_ change: (inout ReadingToolsPresentation) -> Void) {
        change(&tools)
    }

    private func openPanel(_ panel: ReadingToolPanel) {
        guard !model.exitSaveFailed, model.ready else { return }
        lastPanelControl = panel == .directory ? "directory" : "settings"
        mutateTools { $0.open(panel) }
    }

    private func closePanel(_ id: UUID) {
        mutateTools { _ = $0.closePanel(id: id) }
    }
    private func searchActions(for panelID: UUID) -> BookSearchActions {
        BookSearchActions(search: { query in
            guard panelActive(.directory, panelID), let reader = model.reader else { throw CancellationError() }
            return try await reader.searchBook(query)
        }, jump: { hit in
            try await model.jumpToSearchHit(hit, isActive: { panelActive(.directory, panelID) })
            mutateTools { _ = $0.chapterSelected(id: panelID) }
        })
    }

    private func bookmarkActions(for panelID: UUID) -> EPUBBookmarkActions {
        let active = { panelActive(.directory, panelID) }
        return EPUBBookmarkActions(list: {
            guard active(), let reader = model.reader else { throw EPUBError.staleSession }
            return try await reader.bookmarks()
        }, add: {
            try await model.addVisibleBookmark(isActive: active)
        }, remove: { bookmark in
            guard active(), let reader = model.reader else { throw EPUBError.staleSession }
            try await reader.deleteBookmark(id: bookmark.id)
        }, jump: { bookmark in
            try await model.jumpToBookmark(id: bookmark.id, isActive: active)
            mutateTools { _ = $0.chapterSelected(id: panelID) }
        })
    }


    private func selectNavigationItem(_ item: EPUBNavigationItem, _ id: UUID) {
        guard panelActive(.directory, id) else { return }
        var accepted = false
        mutateTools { accepted = $0.chapterSelected(id: id) }
        if accepted {
            model.go(to: item)
        }
    }

    private func handleToolsInteraction(_ event: ReadingToolsInteraction) {
        switch event {
        case .showAccessibility:
            mutateTools { $0.show() }
        case .exitAccessibility:
            exitReader()
        case .scrollingBegan:
            guard model.ready, !model.loading, tools.panel == nil else { return }
            mutateTools { $0.scrollingBegan() }
        case .tap(let expected, let decision):
            guard model.ready, !model.loading, !model.exitSaveFailed, decision == .toggle else { return }
            mutateTools { $0.bodyTapped(expected: expected) }
        }
    }

    private func exitReader(keepingSavedPosition: Bool = false) {
        var request: UUID?
        mutateTools { request = $0.beginExit() }
        guard let request else { return }
        Task {
            let succeeded: Bool
            if keepingSavedPosition {
                await model.leaveKeepingSavedPosition()
                succeeded = true
            } else {
                succeeded = await model.close()
            }
            var accepted = false
            mutateTools { accepted = $0.finishExit(request, succeeded: succeeded) }
            if accepted, succeeded {
                onExit()
            }
        }
    }
}

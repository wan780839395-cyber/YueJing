import ReaderDomain
import SwiftUI
import UIKit

@MainActor
struct EPUBReaderScreen: View {
    @ObservedObject var model: EPUBReaderViewModel
    let routeID: UUID
    let onExit: @MainActor () -> Void
    @State private var tools = ReadingToolsPresentation()
    @State private var lastPanelControl: String?
    @State private var selectedDetent: PresentationDetent = .large
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
                    interactionEnabled: model.ready && !model.loading && !model.exitSaveFailed &&
                        tools.canInteract && tools.panel == nil,
                    toolIntent: { tools.intent },
                    onToolsInteraction: handleToolsInteraction
                )
                .allowsHitTesting(!model.exitSaveFailed && tools.exitRequest == nil && tools.panel == nil)
                .accessibilityHidden(tools.panel != nil || tools.exitRequest != nil)
                .accessibilityAction(named: Text("显示阅读工具")) { mutateTools { $0.show() } }
                .accessibilityAction(named: Text("退出阅读")) { exitReader() }
                .accessibilityAction(named: Text("下一屏")) { _ = model.webView.controller?.turnPage(.next) }
                .accessibilityAction(named: Text("上一屏")) { _ = model.webView.controller?.turnPage(.previous) }

                if model.loading && tools.exitRequest == nil && tools.valid {
                    VStack(alignment: .leading, spacing: 12) {
                        ProgressView("正在打开章节…")
                        Text("正在校验 EPUB 资源并恢复阅读位置。可返回书架停止本次打开，已保存记录保留。")
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding()
                    .background(appearance.surface, in: RoundedRectangle(cornerRadius: 18))
                    .padding()
                    .accessibilityElement(children: .combine)
                    .accessibilityHidden(tools.panel != nil)
                }

                if !model.loading && !model.ready && model.navigationRequest == nil && tools.exitRequest == nil && tools.valid {
                    VStack(spacing: 16) {
                        Image(systemName: "book.closed").font(.largeTitle).accessibilityHidden(true)
                        Text("暂时无法显示正文").accessibilityAddTraits(.isHeader)
                        Button("重试打开") { Task { await model.retry() } }
                            .buttonStyle(.borderedProminent)
                            .frame(minHeight: 44)
                    }
                    .padding()
                    .background(appearance.surface, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityHidden(tools.panel != nil)
                    .disabled(tools.exitRequest != nil)
                }

                VStack(spacing: 0) {
                    titleBar(metrics: metrics, appearance: appearance)
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
                    focusedControl: $focusedControl
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .foregroundStyle(appearance.foreground)
            .tint(appearance.accent)
        }
        .background(Color(uiColor: model.preferences.theme.background).ignoresSafeArea())
        .environment(\.colorScheme, model.preferences.theme == .dark ? .dark : .light)
        .sheet(item: panelPresentation) { session in
            panelHost(session: session)
        }
        .task(id: routeID) {
            await model.load()
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
            if loading { mutateTools { $0.forceCompact() } }
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

    @ViewBuilder
    private func panelHost(session: ReaderPanelSession) -> some View {
        let appearance = ReaderToolAppearance(
            theme: model.preferences.theme,
            reduceTransparency: reduceTransparency
        )
        Group {
            if session.panel == .directory {
                EPUBContentsView(
                    items: model.navigationItems,
                    currentPath: model.currentPath,
                    currentFragment: model.currentFragment,
                    isActive: { panelActive(.directory, session.id) },
                    close: { closePanel(session.id) },
                    appearance: appearance,
                    selected: { item in selectNavigationItem(item, session.id) }
                )
            } else {
                EPUBSettingsView(
                    preferences: settingsBinding(for: session.id),
                    changed: {
                        if panelActive(.settings, session.id) {
                            model.settingsChanged()
                        }
                    },
                    openingSummary: model.openingPerformanceSummary,
                    isActive: { panelActive(.settings, session.id) },
                    close: { closePanel(session.id) },
                    appearance: appearance
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

    private func titleBarContent(metrics: ReaderToolMetrics, appearance: ReaderToolAppearance) -> some View {
        HStack(spacing: 6) {
            Button { exitReader() } label: {
                Group {
                    if tools.exitRequest != nil {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.down").font(.system(size: 18, weight: .medium))
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!tools.canInteract)
            .accessibilityLabel("返回书架")
            .accessibilityIdentifier("reader.exit")
            .accessibilityFocused($focusedControl, equals: "back")

            Text(model.title)
                .font(.headline)
                .lineLimit(metrics.verticalButtons ? 2 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("书名，\(model.title)")
        }
        .padding(.horizontal, 8)
        .frame(minHeight: metrics.titleHeight)
        .background(appearance.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
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

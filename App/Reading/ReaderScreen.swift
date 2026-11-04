import ReaderDomain
import SwiftUI
import TXTCore
import UIKit

@MainActor
struct ReaderScreen: View {
    @ObservedObject var model: ReaderViewModel
    let routeID: UUID
    let onExit: @MainActor () -> Void
    @State private var tools = ReadingToolsPresentation()
    @State private var lastPanelControl: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @ScaledMetric(relativeTo: .body) private var controlHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .headline) private var titleLine: CGFloat = 22
    @AccessibilityFocusState private var focusedControl: String?
    #if DEBUG
    @State private var hitProbe = ReaderHitProbeStore()
    #endif

    var body: some View {
        GeometryReader { geometry in
            let metrics = ReaderToolMetrics(height: geometry.size.height, scaledControl: controlHeight,
                titleLine: titleLine, accessibilityFont: dynamicType.isAccessibilitySize)
            let appearance = ReaderToolAppearance(theme: model.preferences.theme, reduceTransparency: reduceTransparency)
            ZStack {
                // Safe-area-sized from the start. Tools never reserve or resize this viewport.
                // UIKit retains the existing 16/24pt scroll-end insets and 20pt text side margins.
                ReaderViewport(window: model.window, preferences: model.preferences, handle: model.viewport,
                    routeID: routeID, onSceneInteraction: handleNativeScene,
                    // BEGIN READER DIAGNOSTICS viewport facts
                    diagnosticTools: tools, diagnosticLoading: model.loading,
                    diagnosticSaveFailed: model.exitSaveFailed, diagnosticScene: scenePhase,
                    // END READER DIAGNOSTICS viewport facts
                    onAnchor: model.visibleChanged, onExtend: model.extendWindow, onWidth: model.resized,
                    onSettled: model.scrollingEnded, onApplied: model.windowApplied,
                    toolIntent: { tools.intent }, onToolsInteraction: handleToolsInteraction)
                    .allowsHitTesting(!model.exitSaveFailed && tools.exitRequest == nil && tools.panel == nil)
                    .accessibilityHidden(tools.panel != nil || tools.exitRequest != nil)
                    .accessibilityAction(named: Text("显示阅读工具")) { mutateTools { $0.show() } }
                    .accessibilityAction(named: Text("退出阅读")) { exitReader() }
                if model.loading && tools.exitRequest == nil && tools.valid {
                    VStack(alignment: .leading, spacing: 12) {
                        ProgressView("正在打开书籍…")
                        Text("首次准备可能需要稍等。可返回书架停止本次打开，书籍与已保存位置保留。")
                            .font(.footnote).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding().background(appearance.surface, in: RoundedRectangle(cornerRadius: 18))
                    .padding().accessibilityElement(children: .combine)
                    .accessibilityHidden(tools.panel != nil)
                }
                if !model.loading && model.window == nil && tools.exitRequest == nil && tools.valid {
                    VStack(spacing: 16) {
                        Image(systemName: "book.closed").font(.largeTitle).accessibilityHidden(true)
                        Text("暂时无法显示正文").accessibilityAddTraits(.isHeader)
                        Button("重试打开") { Task { await model.retry() } }
                            .buttonStyle(.borderedProminent).frame(minHeight: 44)
                    }.padding().background(appearance.surface, in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityHidden(tools.panel != nil).disabled(tools.exitRequest != nil)
                }
                VStack(spacing: 0) {
                    titleBar(metrics: metrics, appearance: appearance)
                    Spacer(minLength: 0)
                }
            }
            // Secondary layout: tool content cannot resize or recenter the reading viewport.
            .overlay(alignment: .bottomTrailing) {
                ReaderFloatingToolsView(state: tools, metrics: metrics, appearance: appearance,
                    directoryAvailable: model.window != nil, settingsAvailable: model.window != nil,
                    exitSaveFailed: model.exitSaveFailed, rememberFocus: { lastPanelControl = $0 },
                    open: openPanel, focusedControl: $focusedControl)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            .foregroundStyle(appearance.foreground).tint(appearance.accent)
        }
        .background(Color(uiColor: model.preferences.theme.background).ignoresSafeArea())
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if ReaderHitProbeStore.legacyEnabled {
                ReaderHitProbeEndpoint(store: hitProbe, model: model, routeID: routeID, tools: tools)
                    .frame(width: 1, height: 1).allowsHitTesting(false)
            }
            if ReaderEntryProbe.enabled {
                ReaderEntryProbeEndpoint(store: hitProbe, model: model, routeID: routeID, tools: tools)
                    .frame(width: 1, height: 1).allowsHitTesting(false)
            }
        }
        #endif
        // Environment flows down this presentation; no window color-scheme preference.
        .environment(\.colorScheme, model.preferences.theme == .dark ? .dark : .light)
        .sheet(item: panelPresentation) { session in
            ReaderPanelHost(session: session, model: model, active: panelActive,
                close: closePanel, selected: selectChapter, selectedBookmark: selectBookmark)
        }
        .task(id: routeID) { await model.load() }
        .task(id: tools.intent) {
            let intent = tools.intent
            guard voiceOver, tools.visible, tools.panel == nil else { return }
            await Task.yield()
            if !Task.isCancelled, tools.intent == intent, tools.panel == nil {
                focusedControl = lastPanelControl ?? "back"
            }
        }
        .onChange(of: scenePhase) { phase in
            // BEGIN READER DIAGNOSTICS screen scene
            model.viewport.observeDiagnosticScene(phase)
            // END READER DIAGNOSTICS screen scene
            // Environment phase remains diagnostic only; the attached native scene owns recovery.
        }
        .onChange(of: model.loading) { loading in if loading { mutateTools { $0.forceCompact() } } }
        .onChange(of: model.exitSaveFailed) { failed in if failed { mutateTools { $0.forceCompact() } } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await model.releaseReaderMemory() }
        }
        // A sheet/temporary hierarchy change is not an exit. The route owner performs final close.
        .alert("阅读提示", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            if model.exitSaveFailed {
                Button("重试保存") { exitReader() }
                Button("保留已保存位置并返回", role: .destructive) { exitReader(keepingSavedPosition: true) }
            } else {
                Button("知道了", role: .cancel) { model.message = nil }
            }
        } message: { Text(model.message ?? "") }
    }

    private func handleNativeScene(_ event: ReaderSceneEvent) {
        guard model.viewport.isCurrent(event, routeID: routeID) else { return }
        if event.active { mutateTools { $0.resume() } }
        else { mutateTools { $0.suspend() } }
        // BEGIN READER DIAGNOSTICS scene tools completion
        model.viewport.controller?.interactionDiagnostics.sceneTools(tools)
        // END READER DIAGNOSTICS scene tools completion
        model.viewport.scheduleModelSceneTransition(event, routeID: routeID) { active in
            if active { await model.resume() } else { await model.suspend() }
        }
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
        .allowsHitTesting(visible && tools.canInteract).accessibilityHidden(!visible)
    }

    private func titleBarContent(metrics: ReaderToolMetrics, appearance: ReaderToolAppearance) -> some View {
        HStack(spacing: 6) {
            Button { exitReader() } label: {
                Group {
                    if tools.exitRequest != nil { ProgressView() }
                    else { Image(systemName: "chevron.down").font(.system(size: 18, weight: .medium)) }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!tools.canInteract)
            .accessibilityLabel("返回书架").accessibilityIdentifier("reader.exit")
            .accessibilityFocused($focusedControl, equals: "back")
            #if DEBUG
            .background {
                if ReaderHitProbeStore.enabled {
                    ReaderHitProbeMarker(store: hitProbe)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                }
            }
            #endif
            Text(model.title).font(.headline).lineLimit(metrics.verticalButtons ? 2 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("书名，\(model.title)")
        }
        .padding(.horizontal, 8).frame(minHeight: metrics.titleHeight)
        .background(appearance.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12).padding(.top, 6)
        // Keep title/layout updates out of the visibility transition.
        .transaction { transaction in transaction.animation = nil }
    }

    private var panelPresentation: Binding<ReaderPanelSession?> {
        let expected = tools.panelID
        return Binding(get: {
            guard let id = tools.panelID, let panel = tools.panel else { return nil }
            return ReaderPanelSession(id: id, panel: panel)
        }, set: { value in
            guard value == nil, let expected else { return }
            closePanel(expected)
        })
    }
    private func panelActive(_ panel: ReadingToolPanel, _ id: UUID) -> Bool {
        tools.owns(panel, id: id) && !model.exitSaveFailed
    }
    private func mutateTools(_ change: (inout ReadingToolsPresentation) -> Void) {
        let old = tools.panel == .directory ? tools.panelID : nil
        change(&tools)
        // BEGIN READER DIAGNOSTICS tools observation
        model.viewport.controller?.interactionDiagnostics.screenFacts(window: model.window != nil,
            loading: model.loading, saveFailed: model.exitSaveFailed, tools: tools)
        // END READER DIAGNOSTICS tools observation
        let next = tools.panel == .directory ? tools.panelID : nil
        if let old, old != next {
            model.directory.dismiss(presentation: old)
            model.endBookmarkPanel(old)
        }
    }
    private func openPanel(_ panel: ReadingToolPanel) {
        guard !model.exitSaveFailed else { return }
        if panel == .directory, model.window == nil { return }
        if panel == .settings, model.window == nil { return }
        lastPanelControl = panel == .directory ? "directory" : "settings"
        let previous = tools.panelID
        var next = tools
        next.open(panel)
        if panel == .directory, let id = next.panelID, id != previous, next.owns(.directory, id: id) {
            model.beginBookmarkPanel(id)
        }
        mutateTools { $0 = next }
    }
    private func closePanel(_ id: UUID) { mutateTools { _ = $0.closePanel(id: id) } }
    private func selectChapter(_ chapter: TXTChapter, _ id: UUID) {
        guard panelActive(.directory, id) else { return }
        var accepted = false
        mutateTools { accepted = $0.chapterSelected(id: id) }
        if accepted { model.go(to: chapter) }
    }
    private func selectBookmark(_ rendered: ReadingWindow, _ id: UUID) -> Bool {
        guard panelActive(.directory, id), model.applyBookmarkWindow(rendered, presentation: id) else { return false }
        var accepted = false
        mutateTools { accepted = $0.chapterSelected(id: id) }
        return accepted
    }
    private func handleToolsInteraction(_ event: ReadingToolsInteraction) {
        switch event {
        case .showAccessibility: mutateTools { $0.show() }
        case .exitAccessibility: exitReader()
        case .scrollingBegan:
            // BEGIN READER DIAGNOSTICS scrolling observation
            model.viewport.controller?.interactionDiagnostics.scrolling()
            // END READER DIAGNOSTICS scrolling observation
            guard model.window != nil, !model.loading, tools.panel == nil else { return }
            mutateTools { $0.scrollingBegan() }
        case .tap(let expected, let decision):
            // BEGIN READER DIAGNOSTICS screen tap
            let observation = model.viewport.diagnosticCallbackObservation
            observation?.parentTap(window: model.window != nil, loading: model.loading,
                saveFailed: model.exitSaveFailed, toggle: decision == .toggle,
                intentMatches: expected == tools.intent, tools: tools)
            defer { observation?.parentFinished(tools) }
            // END READER DIAGNOSTICS screen tap
            guard model.window != nil, !model.loading, !model.exitSaveFailed, decision == .toggle else { return }
            mutateTools { $0.bodyTapped(expected: expected) }
        }
    }
    private func exitReader(keepingSavedPosition: Bool = false) {
        var request: UUID?
        mutateTools { request = $0.beginExit() }
        guard let request else { return }
        Task {
            let succeeded: Bool
            if keepingSavedPosition { await model.leaveKeepingSavedPosition(); succeeded = true }
            else { succeeded = await model.close() }
            var accepted = false
            mutateTools { accepted = $0.finishExit(request, succeeded: succeeded) }
            if accepted, succeeded { onExit() }
        }
    }
}

#if DEBUG
// Test-only native geometry/AX bridge. Its added nodes may perturb SwiftUI/AX composition.
@MainActor
private struct ReaderHitProbeMarker: UIViewRepresentable {
    let store: ReaderHitProbeStore
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear; view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false; view.accessibilityElementsHidden = true
        store.exitMarker = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { store.exitMarker = view }
}

@MainActor
private struct ReaderHitProbeEndpoint: UIViewRepresentable {
    let store: ReaderHitProbeStore
    let model: ReaderViewModel
    let routeID: UUID
    let tools: ReadingToolsPresentation
    func makeUIView(context: Context) -> ReaderHitProbeValueView {
        let view = ReaderHitProbeValueView(frame: .zero)
        view.backgroundColor = .clear; view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true; view.accessibilityTraits = .staticText
        view.accessibilityIdentifier = "ui.fixture.reader.hitprobe"
        view.accessibilityLabel = "合成测试只读取证"
        view.store = store
        store.update(model: model, routeID: routeID, tools: tools)
        return view
    }
    func updateUIView(_ view: ReaderHitProbeValueView, context: Context) {
        store.update(model: model, routeID: routeID, tools: tools)
    }
}

@MainActor
private final class ReaderHitProbeValueView: UIView {
    var store: ReaderHitProbeStore?
    override var accessibilityValue: String? {
        get { store?.value(endpoint: self) }
        set { /* The diagnostic endpoint does not accept commands or mutate reading state. */ }
    }
}
#endif

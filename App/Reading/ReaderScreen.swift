import ReaderDomain
import SwiftUI
import TXTCore
import UIKit

@MainActor
struct ReaderScreen: View {
    @StateObject private var model: ReaderViewModel
    @State private var tools = ReadingToolsPresentation()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @ScaledMetric(relativeTo: .body) private var controlHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .headline) private var titleLine: CGFloat = 22
    @AccessibilityFocusState private var exitFocused: Bool

    init(bookID: String, service: LibraryService) {
        _model = StateObject(wrappedValue: ReaderViewModel(bookID: bookID, service: service))
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = ReaderToolMetrics(height: geometry.size.height, scaledControl: controlHeight,
                titleLine: titleLine, accessibilityFont: dynamicType.isAccessibilitySize)
            let appearance = ReaderToolAppearance(theme: model.preferences.theme, reduceTransparency: reduceTransparency)
            ZStack {
                ReaderViewport(window: model.window, preferences: model.preferences, handle: model.viewport,
                    onAnchor: model.visibleChanged, onExtend: model.extendWindow, onWidth: model.resized,
                    onSettled: model.scrollingEnded, onRemoved: model.disappeared, onApplied: model.windowApplied,
                    toolIntent: { tools.intent }, onToolsInteraction: handleToolsInteraction)
                    // Stable reading margins, independent of visibility/panel state. No moving anchor or fixed 84pt pad.
                    .padding(.top, metrics.topClearance).padding(.bottom, metrics.bottomClearance)
                    .allowsHitTesting(!model.exitSaveFailed && tools.exitRequest == nil && tools.panel == nil)
                    .accessibilityHidden(tools.panel != nil || tools.exitRequest != nil)
                    .accessibilityAction(named: Text("显示阅读工具")) { mutateTools { $0.show() } }
                    .accessibilityAction(named: Text("退出阅读")) { exitReader() }
                if model.loading {
                    VStack(alignment: .leading, spacing: 12) {
                        ProgressView("正在打开书籍…")
                        Text("首次打开旧书或需要重新准备阅读内容时，可能需要稍等。可返回书架停止本次打开，书籍与已保存位置保留。")
                            .font(.footnote).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding().background(appearance.surface, in: RoundedRectangle(cornerRadius: 18))
                    .padding().accessibilityElement(children: .combine)
                    .accessibilityHidden(tools.panel != nil)
                }
                if !model.loading && model.window == nil {
                    VStack(spacing: 16) {
                        Image(systemName: "book.closed").font(.largeTitle).accessibilityHidden(true)
                        Text("暂时无法显示正文").accessibilityAddTraits(.isHeader)
                        Button("重试打开") { Task { await model.retry() } }
                            .buttonStyle(.borderedProminent).frame(minHeight: 44)
                    }.padding().background(appearance.surface, in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityHidden(tools.panel != nil)
                        .disabled(tools.exitRequest != nil)
                }
                if let id = tools.panelID {
                    Button { closePanel(id) } label: { Color.black.opacity(model.preferences.theme == .dark ? 0.08 : 0.02) }
                        .buttonStyle(.plain).accessibilityHidden(true)
                }
                VStack(spacing: 0) {
                    titleCapsule(metrics: metrics, appearance: appearance)
                    Spacer(minLength: 0)
                }
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ReaderFloatingToolsView(model: model, state: tools, metrics: metrics, appearance: appearance,
                        active: panelActive, open: openPanel, close: closePanel, selected: selectChapter)
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
            .foregroundStyle(appearance.foreground).tint(appearance.accent)
        }
        .background(Color(uiColor: model.preferences.theme.background).ignoresSafeArea())
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                mutateTools { $0.resume(); if model.loading || model.window == nil { $0.forceCompact() } }
            } else { mutateTools { $0.suspend() } }
            Task {
                guard scenePhase == phase else { return }
                if phase == .active { await model.resume() } else { await model.suspend() }
            }
        }
        .onChange(of: model.loading) { loading in if loading { mutateTools { $0.forceCompact() } } }
        .onChange(of: model.exitSaveFailed) { failed in if failed { mutateTools { $0.forceCompact() } } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await model.releaseReaderMemory() }
        }
        .onDisappear { mutateTools { $0.invalidate() } }
        .alert("阅读提示", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            if model.exitSaveFailed {
                Button("重试保存") { exitReader() }
                Button("保留已保存位置并返回", role: .destructive) { exitReader(keepingSavedPosition: true) }
            } else {
                Button("知道了", role: .cancel) { model.message = nil }
            }
        } message: { Text(model.message ?? "") }
    }

    private func titleCapsule(metrics: ReaderToolMetrics, appearance: ReaderToolAppearance) -> some View {
        HStack(spacing: 8) {
            Button { exitReader() } label: {
                if tools.exitRequest != nil { ProgressView() }
                else { Label("返回书架", systemImage: "chevron.left").labelStyle(.iconOnly).font(.system(size: 18)) }
            }
            .frame(minWidth: 44, minHeight: 44).disabled(!tools.canInteract)
            .accessibilityLabel("返回书架").accessibilityFocused($exitFocused)
            Text(model.title).font(.headline).lineLimit(metrics.compactHeight ? 1 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("书名，\(model.title)")
        }
        .padding(.horizontal, 12).frame(height: metrics.titleHeight)
        .background(appearance.fill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(appearance.edge, lineWidth: 1) }
        .padding(.horizontal, 12).padding(.top, 6)
        .opacity(tools.visible ? 1 : 0)
        .offset(y: reduceMotion || tools.visible ? 0 : -8)
        .allowsHitTesting(tools.visible && tools.canInteract)
        .accessibilityHidden(!tools.visible || tools.panel != nil)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.20), value: tools.visible)
        .task(id: tools.intent) {
            let intent = tools.intent
            guard voiceOver, tools.visible, tools.panel == nil else { return }
            await Task.yield()
            if !Task.isCancelled, tools.intent == intent, tools.panel == nil { exitFocused = true }
        }
    }

    private func panelActive(_ panel: ReadingToolPanel, _ id: UUID) -> Bool {
        tools.owns(panel, id: id) && !model.exitSaveFailed
    }
    private func mutateTools(_ change: (inout ReadingToolsPresentation) -> Void) {
        let old = tools.panel == .directory ? tools.panelID : nil
        change(&tools)
        let next = tools.panel == .directory ? tools.panelID : nil
        if let old, old != next { model.directory.dismiss(presentation: old) }
    }
    private func openPanel(_ panel: ReadingToolPanel) {
        guard !model.exitSaveFailed else { return }
        if panel == .directory, model.chapterTotal == 0 { return }
        if panel == .settings, model.window == nil { return }
        mutateTools { $0.open(panel) }
    }
    private func closePanel(_ id: UUID) { mutateTools { _ = $0.closePanel(id: id) } }
    private func selectChapter(_ chapter: TXTChapter, _ id: UUID) {
        guard panelActive(.directory, id) else { return }
        var accepted = false
        mutateTools { accepted = $0.chapterSelected(id: id) }
        if accepted { model.go(to: chapter) }
    }
    private func handleToolsInteraction(_ event: ReadingToolsInteraction) {
        switch event {
        case .showAccessibility: mutateTools { $0.show() }
        case .exitAccessibility: exitReader()
        case .scrollingBegan:
            guard model.window != nil, !model.loading, tools.panel == nil else { return }
            mutateTools { $0.scrollingBegan() }
        case .tap(let expected, let decision):
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
            if accepted, succeeded { dismiss() }
        }
    }
}

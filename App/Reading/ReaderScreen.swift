import ReaderDomain
import SwiftUI
import UIKit

@MainActor
struct ReaderScreen: View {
    private enum Sheet: String, Identifiable { case chapters, settings, timing; var id: String { rawValue } }
    @StateObject private var model: ReaderViewModel
    @State private var sheet: Sheet?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(bookID: String, service: LibraryService) {
        _model = StateObject(wrappedValue: ReaderViewModel(bookID: bookID, service: service))
    }

    var body: some View {
        ZStack {
            ReaderViewport(window: model.window, preferences: model.preferences, handle: model.viewport,
                           onAnchor: model.visibleChanged, onExtend: model.extendWindow, onWidth: model.resized,
                           onSettled: model.scrollingEnded, onRemoved: model.disappeared, onApplied: model.windowApplied)
                .allowsHitTesting(!model.exitSaveFailed)
            if model.loading { ProgressView("正在打开书籍…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
            if !model.loading && model.window == nil {
                VStack(spacing: 16) {
                    Image(systemName: "book.closed").font(.largeTitle)
                    Text("暂时无法显示正文")
                    Button("重试打开") { Task { await model.retry() } }.buttonStyle(.borderedProminent)
                }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .background(Color(uiColor: model.preferences.theme.background))
        .navigationTitle(model.title).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { Task { if await model.close() { dismiss() } } } label: { Label("书架", systemImage: "chevron.left") }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { sheet = .timing } label: { Label("处理耗时", systemImage: "clock") }
                Button { sheet = .chapters } label: { Label("目录", systemImage: "list.bullet") }.disabled(model.chapterTotal == 0 || model.exitSaveFailed)
                Button { sheet = .settings } label: { Label("阅读设置", systemImage: "textformat.size") }.disabled(model.window == nil || model.exitSaveFailed)
            }
        }
        .task { await model.load() }
        .onChange(of: scenePhase) { phase in
            Task { if phase == .active { await model.resume() } else { await model.suspend() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await model.releaseReaderMemory() }
        }
        .sheet(item: $sheet) { selected in
            switch selected {
            case .chapters:
                NavigationStack {
                    List(model.chapters, id: \.id) { chapter in
                        Button(chapter.title ?? "正文开头") { model.go(to: chapter); sheet = nil }
                    }
                    .navigationTitle("目录")
                    .overlay { if model.chaptersLoading { ProgressView("读取目录…") } }
                    .task(id: model.directoryRevision) { await model.loadChapterPage(start: 0) }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("关闭") { sheet = nil } }
                        ToolbarItemGroup(placement: .bottomBar) {
                            Button("上一组") { Task { await model.loadChapterPage(start: max(0, model.chapterPageStart - model.chapterPageSize)) } }
                                .disabled(model.chapterPageStart == 0 || model.chaptersLoading)
                            Spacer()
                            Text("\(model.chapterPageStart + 1)–\(min(model.chapterTotal, model.chapterPageStart + model.chapters.count)) / \(model.chapterTotal)").font(.caption)
                            Spacer()
                            Button("下一组") { Task { await model.loadChapterPage(start: model.chapterPageStart + model.chapterPageSize) } }
                                .disabled(model.chapterPageStart + model.chapterPageSize >= model.chapterTotal || model.chaptersLoading)
                        }
                    }
                }
            case .settings:
                ReaderSettingsView(preferences: $model.preferences, changed: model.settingsChanged)
            case .timing:
                NavigationStack {
                    ScrollView { Text(model.openingPerformanceSummary ?? "尚未应用首个正文窗口。").padding() }
                        .navigationTitle("本次打开耗时")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { sheet = nil } } }
                }
            }
        }
        .alert("阅读提示", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            if model.exitSaveFailed {
                Button("重试保存") { Task { if await model.close() { dismiss() } } }
                Button("保留已保存位置并返回", role: .destructive) { Task { await model.leaveKeepingSavedPosition(); dismiss() } }
            } else {
                Button("知道了", role: .cancel) { model.message = nil }
            }
        } message: { Text(model.message ?? "") }
    }
}

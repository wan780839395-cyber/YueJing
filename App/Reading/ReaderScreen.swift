import ReaderDomain
import SwiftUI
import UIKit

@MainActor
struct ReaderScreen: View {
    private enum Sheet: Identifiable {
        case chapters(UUID), settings(UUID)
        var id: UUID { switch self { case .chapters(let id), .settings(let id): id } }
    }
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
            if model.loading {
                VStack(alignment: .leading, spacing: 12) {
                    ProgressView("正在打开书籍…")
                    Text("首次打开旧书或需要重新准备阅读内容时，可能需要稍等。可返回书架停止本次打开，书籍与已保存位置保留。")
                        .font(.footnote).fixedSize(horizontal: false, vertical: true)
                }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding().accessibilityElement(children: .combine)
            }
            if !model.loading && model.window == nil {
                VStack(spacing: 16) {
                    Image(systemName: "book.closed").font(.largeTitle).accessibilityHidden(true)
                    Text("暂时无法显示正文").accessibilityAddTraits(.isHeader)
                    Button("重试打开") { Task { await model.retry() } }.buttonStyle(.borderedProminent).frame(minHeight: 44)
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
                Button { sheet = .chapters(UUID()) } label: { Label("目录", systemImage: "list.bullet") }.accessibilityHint("定位当前章节，分页浏览目录").disabled(model.chapterTotal == 0 || model.exitSaveFailed)
                Button { sheet = .settings(UUID()) } label: { Label("阅读设置", systemImage: "textformat.size") }.accessibilityHint("调整文字和背景，或查看诊断与耗时").disabled(model.window == nil || model.exitSaveFailed)
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
            case .chapters(let id):
                ReaderDirectorySheet(model: model.directory, presentationID: id,
                    isActive: { sheet?.id == id }, currentAnchor: model.directoryAnchor) { chapter in
                    guard sheet?.id == id else { return }
                    model.go(to: chapter); sheet = nil
                }
            case .settings:
                ReaderSettingsView(preferences: $model.preferences, changed: model.settingsChanged,
                                   openingSummary: model.openingPerformanceSummary)
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

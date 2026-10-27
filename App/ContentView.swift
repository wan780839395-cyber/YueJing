import SwiftUI
import ReaderDomain

@MainActor
struct ContentView: View {
    @StateObject private var model = LibraryViewModel()
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.importDiagnostics.attempt != nil {
                    Section("本次导入状态") {
                        Text(model.importDiagnostics.callbackSummary)
                            .font(.headline)
                        Text("最后阶段：\(model.importDiagnostics.stage?.label ?? "尚未开始")")
                        if let failure = model.importDiagnostics.failure {
                            Text(failure.summary)
                            if let previous = model.importDiagnostics.failedAfter {
                                Text("出错前阶段：\(previous.label)")
                            }
                        }
                        DisclosureGroup("查看阶段记录") {
                            ForEach(Array(model.importDiagnostics.history.enumerated()), id: \.offset) { item in
                                Text("\(item.offset + 1). \(item.element.label)")
                                    .font(.caption)
                            }
                        }
                        Text("这里只显示本轮阶段，不记录书名、路径或正文。关闭选择器后仍可查看。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.books.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("把第一本书放进阅境", systemImage: "books.vertical")
                            .font(.title3)
                        Text("从“文件”选择 TXT，书籍会保存到应用内，原文件保持不变。")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical)
                }
                ForEach(model.books) { book in
                    NavigationLink(value: book.id) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(book.title).font(.headline).lineLimit(2)
                            Text("\(Double(book.byteCount) / 1048576, specifier: "%.2f") MiB · \(book.encodingRaw)")
                                .font(.caption).foregroundStyle(.secondary)
                            if let date = book.lastReadAt { Text(Date(timeIntervalSince1970: date), style: .date).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 6)
                    }
                }
                if model.importing {
                    HStack {
                        ProgressView()
                        Text(model.encodingChoice == nil ? "正在准备书籍…" : "等待选择文字")
                        Spacer()
                        Button("取消") { Task { await model.cancelImport() } }
                    }
                }
                if model.service == nil {
                    Button("重新打开书架") { Task { await model.start() } }
                }
            }
            .navigationTitle("阅境")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { model.beginFileSelection() } label: { Label("导入 TXT", systemImage: "plus") }
                        .disabled(!model.canBeginFileSelection)
                }
            }
            .navigationDestination(for: String.self) { id in
                if let service = model.service { ReaderScreen(bookID: id, service: service) }
            }
        }
        .task { await model.start() }
        .onChange(of: path) { value in if value.isEmpty { Task { await model.reload() } } }
        .background {
            if let session = model.fileSelection {
                DocumentPickerBridge.Presentation(session: session, onDismiss: model.documentPickerDismissed)
                    .id(session.id)
            }
        }
        .sheet(item: $model.encodingChoice) { choice in
            EncodingChoiceView(choice: choice, select: { model.choose($0, for: choice) }, cancel: { Task { await model.cancelImport() } })
                .interactiveDismissDisabled()
        }
        .alert("阅境", isPresented: Binding(
            get: { model.canPresentLibraryFeedback && model.message != nil },
            set: { if !$0 && model.canPresentLibraryFeedback { model.message = nil } })) {
            Button("知道了", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

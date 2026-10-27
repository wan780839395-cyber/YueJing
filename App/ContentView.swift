import SwiftUI
import ReaderDomain
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @StateObject private var model = LibraryViewModel()
    @State private var choosingFile = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
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
                    Button { choosingFile = true } label: { Label("导入 TXT", systemImage: "plus") }
                        .disabled(model.service == nil || model.importing)
                }
            }
            .navigationDestination(for: String.self) { id in
                if let service = model.service { ReaderScreen(bookID: id, service: service) }
            }
        }
        .task { await model.start() }
        .onChange(of: path) { value in if value.isEmpty { Task { await model.reload() } } }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.plainText], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.importFile(url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { model.message = "无法选择文件：\(error.localizedDescription)" }
            }
        }
        .sheet(item: $model.encodingChoice) { choice in
            EncodingChoiceView(choice: choice, select: { model.choose($0, for: choice) }, cancel: { Task { await model.cancelImport() } })
                .interactiveDismissDisabled()
        }
        .alert("阅境", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("知道了", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

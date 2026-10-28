import SwiftUI
import ReaderDomain
import UIKit

@MainActor
struct ContentView: View {
    @StateObject private var model = LibraryViewModel()
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let notice = model.notice {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(notice.title).font(.headline).accessibilityAddTraits(.isHeader)
                            Text(notice.detail).fixedSize(horizontal: false, vertical: true)
                            Button("关闭这条提示") { model.notice = nil }.frame(minHeight: 44)
                        }.padding(.vertical, 4)
                    }
                }
                if model.importing {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top) {
                                ProgressView().accessibilityHidden(true)
                                Text(model.importPresentation.title).font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(model.importPresentation.detail).font(.footnote)
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button(model.importPresentation.stopRequested ? "正在停止…" : "停止准备") {
                                Task { await model.cancelImport() }
                            }
                            .disabled(model.importPresentation.stopRequested)
                            .frame(minHeight: 44)
                            .accessibilityHint("请求停止并等待最终结果，已完成的入架不会被撤销")
                        }
                    }
                }
                if model.books.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("把第一本书放进阅境", systemImage: "books.vertical").font(.title3)
                            Text("从“文件”选择 TXT。应用只管理自己的副本，原文件保持不变。")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 8)
                    }
                } else {
                    Section("最近阅读与新加入") {
                        ForEach(model.books) { book in
                            NavigationLink(value: book.id) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(book.title).font(.headline)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let date = book.lastReadAt {
                                        HStack {
                                            Text("最近阅读")
                                            Text(Date(timeIntervalSince1970: date), style: .date)
                                        }.font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("新加入 · 尚未阅读").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 8)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityHint("打开正文，恢复已保存的阅读位置")
                        }
                    }
                }
                if model.service == nil {
                    Button("重新打开书架") { Task { await model.start() } }.frame(minHeight: 44)
                }
            }
            .navigationTitle("阅境")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink {
                        ReaderDiagnosticsView(importState: model.importDiagnostics, importSummary: model.processingSummary)
                    } label: { Label("诊断与耗时", systemImage: "ladybug") }
                    .disabled(!model.canPresentLibraryFeedback)
                    .accessibilityHint("查看本次导入的安全阶段记录与本地耗时")
                }
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await model.releaseProcessingCache() }
        }
        .onChange(of: path) { value in if value.isEmpty { Task { await model.reload() } } }
        .background {
            if let session = model.fileSelection {
                DocumentPickerBridge.Presentation(session: session, onDismiss: model.documentPickerDismissed).id(session.id)
            }
        }
        .sheet(item: $model.encodingChoice) { choice in
            EncodingChoiceView(choice: choice, select: { model.choose($0, for: choice) },
                cancel: { Task { await model.cancelImport() } }).interactiveDismissDisabled()
        }
        .alert("书架提示", isPresented: Binding(
            get: { model.canPresentLibraryFeedback && model.message != nil },
            set: { if !$0 && model.canPresentLibraryFeedback { model.message = nil } })) {
            Button("知道了", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

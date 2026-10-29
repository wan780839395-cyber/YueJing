import SwiftUI
import ReaderDomain
import UIKit

@MainActor
struct ContentView: View {
    @StateObject private var model: LibraryViewModel
    @StateObject private var readerRoutes = ReaderRouteOwner()
    @Environment(\.colorScheme) private var colorScheme

    private var appearance: LibraryAppearance { LibraryAppearance(colorScheme: colorScheme) }
    /// New static destinations must not compete with import or reading presentation.
    private var canOpenPlannedFeatures: Bool {
        model.service != nil && model.canPresentLibraryFeedback && !model.importing
            && model.encodingChoice?.id == nil && model.message == nil
            && readerRoutes.presentation?.id == nil
    }

    init() {
        _model = StateObject(wrappedValue: LibraryViewModel(makeService: Self.makeLibraryService))
    }

    private static func makeLibraryService() async throws -> LibraryService {
        #if DEBUG
        if ReadingUITestFixture.isRequested {
            return try await ReadingUITestFixture.makeService()
        }
        #endif
        return try await LibraryService.openDefault()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LibraryHeaderView(bookCount: model.books.count, appearance: appearance)
                        .listRowInsets(EdgeInsets(top: 8, leading: LibraryAppearance.horizontalInset,
                                                  bottom: 6, trailing: LibraryAppearance.horizontalInset))
                        .listRowSeparator(.hidden)
                        .listRowBackground(appearance.page)
                }
                if let notice = model.notice {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(notice.title).font(.headline).accessibilityAddTraits(.isHeader)
                            Text(notice.detail).fixedSize(horizontal: false, vertical: true)
                            Button("关闭这条提示") { model.notice = nil }.frame(minHeight: 44)
                        }.padding(.vertical, 4)
                    }
                    .listRowBackground(appearance.surface)
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
                    .listRowBackground(appearance.surface)
                }
                if model.books.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("把第一本书放进阅境", systemImage: "books.vertical").font(.title3)
                            Text("从“文件”选择 TXT。应用只管理自己的副本，原文件保持不变。")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 8)
                    }
                    .listRowBackground(appearance.surface)
                } else {
                    Section("最近阅读与新加入") {
                        ForEach(model.books) { book in
                            Button {
                                if let service = model.service { readerRoutes.open(bookID: book.id, service: service) }
                            } label: {
                                LibraryBookRow(book: book, appearance: appearance)
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityHint("打开正文，恢复已保存的阅读位置")
                            .listRowInsets(EdgeInsets(top: 0, leading: LibraryAppearance.horizontalInset,
                                                      bottom: 0, trailing: LibraryAppearance.horizontalInset))
                            .listRowSeparatorTint(appearance.edge)
                            .listRowBackground(appearance.page)
                        }
                    }
                }
                Section {
                    LibraryPlannedEntriesView(appearance: appearance, canOpenFeatures: canOpenPlannedFeatures)
                        .listRowInsets(EdgeInsets(top: 8, leading: LibraryAppearance.horizontalInset,
                                                  bottom: 0, trailing: LibraryAppearance.horizontalInset))
                        .listRowSeparator(.hidden)
                        .listRowBackground(appearance.page)
                }
                if model.service == nil {
                    Button("重新打开书架") { Task { await model.start() } }.frame(minHeight: 44)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(appearance.page.ignoresSafeArea())
            .foregroundStyle(appearance.foreground)
            .tint(appearance.accent)
            .navigationTitle("阅境")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(appearance.page, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink {
                        ReaderDiagnosticsView(importState: model.importDiagnostics, importSummary: model.processingSummary)
                    } label: {
                        Label("诊断与耗时", systemImage: "ladybug")
                            .frame(minWidth: 44, minHeight: LibraryAppearance.minimumControlHeight)
                    }
                    .disabled(!model.canPresentLibraryFeedback)
                    .accessibilityHint("查看本次导入的安全阶段记录与本地耗时")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { model.beginFileSelection() } label: {
                        Label("导入 TXT", systemImage: "plus")
                            .frame(minWidth: 44, minHeight: LibraryAppearance.minimumControlHeight)
                    }
                        .disabled(!model.canBeginFileSelection)
                }
            }
        }
        .accessibilityIdentifier("library.screen")
        .overlay(alignment: .topLeading) {
            #if DEBUG
            if ReadingUITestFixture.isRequested { ReadingUITestSchemeProbe() }
            #endif
        }
        .fullScreenCover(item: readerPresentation) { route in
            ReaderScreen(model: route.model, routeID: route.id) { readerRoutes.finishExit(route.id) }
                .id(route.id)
        }
        .task { await model.start() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await model.releaseProcessingCache() }
        }
        .onChange(of: readerRoutes.presentation?.id) { id in
            if id == nil { Task { await model.reload() } }
        }
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

    private var readerPresentation: Binding<ReaderPresentation?> {
        let expected = readerRoutes.presentation
        return Binding(get: { readerRoutes.presentation }, set: { value in
            guard value == nil, let expected else { return }
            readerRoutes.presentationEnded(expected)
        })
    }
}

import ReaderDomain
import SwiftUI

/// Real books in their existing order. No service, tasks, sorting or generated book data.
@MainActor
struct LibraryShelfContent: View {
    let books: [LibraryBook]
    let notice: LibraryNotice?
    let importing: Bool
    let importPresentation: LibraryImportPresentation
    let serviceUnavailable: Bool
    let layout: LibraryLayout
    let appearance: LibraryAppearance
    let canOpenFeatures: Bool
    let onOpenBook: (LibraryBook) -> Void
    let onDismissNotice: () -> Void
    let onCancelImport: () -> Void
    let onRetry: () -> Void
    let onOpenFeature: (LibraryPlannedFeature) -> Void

    var body: some View {
        List {
            Section {
                LibraryHeaderView(bookCount: books.count, appearance: appearance, showsShelfTitle: layout == .direct)
                    .listRowSeparator(.hidden)
                    .listRowBackground(appearance.page)
            }
            if let notice {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(notice.title).font(.headline).accessibilityAddTraits(.isHeader)
                        Text(notice.detail).fixedSize(horizontal: false, vertical: true)
                        Button("关闭这条提示", action: onDismissNotice).frame(minHeight: 44)
                    }.padding(.vertical, 4)
                }
                .listRowBackground(appearance.surface)
            }
            if importing {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            ProgressView().accessibilityHidden(true)
                            Text(importPresentation.title).font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(importPresentation.detail).font(.footnote)
                            .foregroundStyle(appearance.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(importPresentation.stopRequested ? "正在停止…" : "停止准备", action: onCancelImport)
                            .disabled(importPresentation.stopRequested).frame(minHeight: 44)
                            .accessibilityHint("请求停止并等待最终结果，已完成的入架不会被撤销")
                    }
                }
                .listRowBackground(appearance.surface)
            }
            if books.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("把第一本书放进阅境", systemImage: "books.vertical").font(.title3)
                        Text("从“文件”选择 TXT。应用只管理自己的副本，原文件保持不变。EPUB 规划中，未接入。")
                            .foregroundStyle(appearance.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 8)
                }
                .listRowBackground(appearance.surface)
            } else {
                Section("最近阅读与新加入") {
                    ForEach(books) { book in
                        Button { onOpenBook(book) } label: {
                            if layout == .direct { directBookRow(book) }
                            else { LibraryBookRow(book: book, appearance: appearance) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("打开正文，恢复已保存的阅读位置")
                        .listRowInsets(EdgeInsets(top: 0, leading: LibraryAppearance.horizontalInset,
                                                  bottom: 0, trailing: LibraryAppearance.horizontalInset))
                        .listRowSeparatorTint(appearance.edge.opacity(0.6))
                        .listRowBackground(appearance.page)
                    }
                }
            }
            if layout == .direct {
                Section {
                    LibraryPlannedEntriesView(appearance: appearance, canOpenFeatures: canOpenFeatures,
                                              features: LibraryPlannedFeature.modules, onOpenFeature: onOpenFeature)
                        .listRowSeparator(.hidden)
                        .listRowBackground(appearance.page)
                }
            }
            if serviceUnavailable {
                Button("重新打开书架", action: onRetry).frame(minHeight: 44)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(appearance.page.ignoresSafeArea())
        .foregroundStyle(appearance.foreground)
        .tint(appearance.accent)
    }

    private func directBookRow(_ book: LibraryBook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(book.title).font(LibraryAppearance.bookTitleFont)
                .foregroundStyle(appearance.foreground).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("TXT")
                if let date = book.lastReadAt { Text(Date(timeIntervalSince1970: date), style: .date) }
                else { Text("新加入 · 尚未阅读") }
            }
            .font(.caption).foregroundStyle(appearance.secondary)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

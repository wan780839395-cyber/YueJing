import ReaderDomain
import SwiftUI
import UIKit

@MainActor
struct ReaderBookmarksView: View {
    @ObservedObject var model: ReaderBookmarksViewModel
    let presentationID: UUID
    let isActive: @MainActor () -> Bool
    let close: @MainActor () -> Void
    let appearance: ReaderToolAppearance
    let prepare: @MainActor (String, BookmarkRequest) async throws -> ReadingWindow
    let apply: @MainActor (ReadingWindow) -> Bool
    @State private var pendingDeletion: ReadingBookmark?
    @State private var pendingRename: ReadingBookmark?
    @State private var editedName = ""
    @AccessibilityFocusState private var closeFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicType

    private var active: Bool { isActive() && model.owns(presentationID) }
    var body: some View {
        VStack(spacing: 0) {
            ReaderPanelHeader(title: "书签", appearance: appearance) {
                Button { if isActive() { close() } } label: {
                    Text("完成").font(ReaderVisualStyle.panelActionFont)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(minWidth: ReaderVisualStyle.panelActionMinimumWidth,
                               minHeight: ReaderVisualStyle.minimumControlHeight)
                }
                .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground, role: .primary))
                .accessibilityLabel("关闭书签").accessibilityIdentifier("reader.panel.close")
                .accessibilityFocused($closeFocused)
            }
            List {
                Section {
                    Button { if active { model.add() } } label: {
                        Label(model.existingAtCapture == nil ? "添加当前阅读位置" : "此位置已有书签",
                              systemImage: model.existingAtCapture == nil ? "bookmark" : "bookmark.fill")
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .disabled(!active || !model.canAdd)
                    .accessibilityIdentifier("reader.bookmarks.add")
                    if let explanation = model.positionMessage {
                        Text(explanation).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    }
                    if let notice = model.notice {
                        Text(notice).font(.footnote).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("reader.bookmarks.notice")
                    }
                    if let error = model.message {
                        Text(error).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("reader.bookmarks.error")
                        Button("重试读取书签") { if active { model.loadPage(model.page?.start ?? 0) } }
                            .frame(minHeight: 44).disabled(!active || model.isBusy)
                    }
                    if model.isBusy {
                        HStack {
                            ProgressView()
                            Text(model.activity == .jumping ? "正在准备位置…" : "正在处理书签…")
                        }.accessibilityElement(children: .combine)
                    }
                }.listRowBackground(appearance.surface)
                if let page = model.page {
                    Section {
                        if page.items.isEmpty && model.message == nil && !model.isBusy {
                            Text("尚无书签。在正文位置稳定后，可添加当前阅读位置。")
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("reader.bookmarks.empty")
                        }
                        ForEach(Array(page.items.enumerated()), id: \.element.id) { item in
                            bookmarkRow(item.element, ordinal: page.start + item.offset + 1)
                                .listRowBackground(appearance.surface)
                        }
                    }
                    if page.total > 0 {
                        Section {
                            Text("\(page.start + 1)–\(page.start + page.items.count) / \(page.total)")
                                .font(.footnote).accessibilityIdentifier("reader.bookmarks.count")
                            if dynamicType.isAccessibilitySize {
                                VStack(alignment: .leading) { pagingButtons(page) }
                            } else { HStack { pagingButtons(page) } }
                        }.listRowBackground(appearance.surface)
                    }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .background(appearance.surface)
            .accessibilityIdentifier("reader.bookmarks.list")
        }
        .confirmationDialog("删除这条书签？", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible) {
                if let bookmark = pendingDeletion {
                    Button("删除书签", role: .destructive) {
                        pendingDeletion = nil
                        if active { model.delete(bookmark) }
                    }.accessibilityIdentifier("reader.bookmarks.confirmDelete")
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: { Text("不会删除书籍或阅读进度。") }
        .alert("重命名书签", isPresented: Binding(
            get: { pendingRename != nil }, set: { if !$0 { pendingRename = nil } })) {
            TextField("书签名称", text: $editedName)
                .accessibilityIdentifier("reader.bookmarks.name")
            Button("保存") {
                if active, let bookmark = pendingRename { model.rename(bookmark, name: editedName) }
                pendingRename = nil
            }
            .disabled(!validName)
            .accessibilityIdentifier("reader.bookmarks.confirmRename")
            Button("取消", role: .cancel) { pendingRename = nil }
        } message: {
            Text(validName ? "最多80个字；留空恢复默认名称。" : "名称最多80个字，不可包含换行或控制字符。")
        }
        .task(id: presentationID) {
            guard active else { return }
            model.show()
            if UIAccessibility.isVoiceOverRunning { closeFocused = true }
        }
        .onChange(of: model.notice) { value in
            if active, UIAccessibility.isVoiceOverRunning, let value {
                UIAccessibility.post(notification: .announcement, argument: value)
            }
        }
        .onDisappear { pendingDeletion = nil; pendingRename = nil; closeFocused = false }
        .accessibilityAction(.escape) { if isActive() { close() } }
    }
    private func bookmarkRow(_ bookmark: ReadingBookmark, ordinal: Int) -> some View {
        let compatible = model.book.map { bookmark.anchor(matching: $0) != nil } ?? false
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if active { model.jump(bookmark, prepare: prepare, apply: apply) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bookmark.displayTitle)
                        .font(.body).fixedSize(horizontal: false, vertical: true)
                    Text("书签 \(ordinal) · \(Date(timeIntervalSince1970: bookmark.createdAt).formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote).foregroundStyle(appearance.foreground.opacity(0.7))
                    if !compatible {
                        Text("文字版本或位置不匹配，无法跳转。")
                            .font(.footnote).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!active || model.isBusy || !compatible)
            .accessibilityIdentifier("reader.bookmark.\(bookmark.id)")
            .accessibilityHint("跳转到此书签的文字位置")
            Button("重命名") {
                if active { editedName = bookmark.customName ?? ""; pendingRename = bookmark }
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(!active || model.isBusy)
            .accessibilityLabel("重命名书签 \(ordinal)")
            .accessibilityIdentifier("reader.bookmarks.rename.\(bookmark.id)")
            Button("删除") { if active { pendingDeletion = bookmark } }
                .buttonStyle(.borderless)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(!active || model.isBusy)
                .accessibilityLabel("删除书签 \(ordinal)")
                .accessibilityIdentifier("reader.bookmark.delete.\(bookmark.id)")
        }
        .accessibilityAction(named: Text("删除书签")) {
            if active && !model.isBusy { pendingDeletion = bookmark }
        }
    }
    private var validName: Bool {
        do { _ = try ReadingBookmark.validatedCustomName(editedName); return true }
        catch { return false }
    }
    @ViewBuilder private func pagingButtons(_ page: ReadingBookmarkPage) -> some View {
        Button("上一组书签") { if active { model.loadPage(max(0, page.start - ReadingBookmarkPage.pageSize)) } }
            .frame(minHeight: 44).disabled(!active || model.isBusy || page.start == 0)
        Button("下一组书签") { if active { model.loadPage(page.start + ReadingBookmarkPage.pageSize) } }
            .frame(minHeight: 44)
            .disabled(!active || model.isBusy || page.start + page.items.count >= page.total)
    }
}

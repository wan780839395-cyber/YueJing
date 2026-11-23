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
    private struct NameEditor {
        let bookmark: ReadingBookmark?
        let presentation: UUID
        var title: String { bookmark == nil ? "添加书签" : "重命名书签" }
    }
    @State private var nameEditor: NameEditor?
    @State private var showingNameEditor = false
    @State private var editedName = ""
    @AccessibilityFocusState private var closeFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicType

    private var active: Bool { isActive() && model.owns(presentationID) }

    var body: some View {
        VStack(spacing: 0) {
            ReaderPanelHeader(title: "书签", appearance: appearance) {
                Button { if isActive() { close() } } label: {
                    Text("完成").font(ReaderVisualStyle.panelActionFont.weight(.semibold))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .frame(minWidth: ReaderVisualStyle.panelActionMinimumWidth,
                               minHeight: ReaderVisualStyle.minimumControlHeight)
                }
                .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, role: .primary))
                .accessibilityLabel("关闭书签").accessibilityIdentifier("reader.panel.close")
                .accessibilityFocused($closeFocused)
            }
            List {
                Section {
                    Button { if active && model.canAdd { editName() } } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(appearance.sealAccent.opacity(0.14))
                                Image(systemName: model.existingAtCapture == nil ? "bookmark.fill" : "checkmark.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(appearance.sealAccent)
                            }
                            .frame(width: 34, height: 34)
                            .accessibilityHidden(true)

                            Text(model.existingAtCapture == nil ? "添加当前阅读位置" : "此位置已有书签")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(appearance.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .background(appearance.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(appearance.sealAccent.opacity(0.32), lineWidth: 0.75)
                                .allowsHitTesting(false)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!active || !model.canAdd)
                    .opacity((!active || !model.canAdd) ? 0.5 : 1)
                    .accessibilityIdentifier("reader.bookmarks.add")
                    .listRowSeparator(.hidden)

                    if let explanation = model.positionMessage {
                        Text(explanation)
                            .font(.footnote)
                            .foregroundStyle(appearance.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .listRowSeparator(.hidden)
                    }
                    if let notice = model.notice {
                        Text(notice)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(appearance.accent)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("reader.bookmarks.notice")
                            .listRowSeparator(.hidden)
                    }
                    if let error = model.message {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(appearance.sealAccent)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("reader.bookmarks.error")
                            .listRowSeparator(.hidden)
                        Button("重试读取书签") { if active { model.loadPage(model.page?.start ?? 0) } }
                            .frame(minHeight: 44).disabled(!active || model.isBusy)
                            .listRowSeparator(.hidden)
                    }
                    if model.isBusy {
                        HStack(spacing: 10) {
                            ProgressView().tint(appearance.accent)
                            Text(model.activity == .jumping ? "正在准备位置…" : "正在处理书签…")
                                .foregroundStyle(appearance.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .listRowSeparator(.hidden)
                    }
                }
                .listRowBackground(appearance.surface)

                if let page = model.page {
                    Section {
                        if page.items.isEmpty && model.message == nil && !model.isBusy {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("尚无书签。在正文位置稳定后，可添加当前阅读位置。")
                                    .font(.subheadline)
                                    .foregroundStyle(appearance.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("reader.bookmarks.empty")
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(appearance.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .listRowBackground(appearance.surface)
                            .listRowSeparator(.hidden)
                        }
                        ForEach(Array(page.items.enumerated()), id: \.element.id) { item in
                            bookmarkRow(item.element, ordinal: page.start + item.offset + 1)
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                .listRowBackground(appearance.surface)
                                .listRowSeparator(.hidden)
                        }
                    }
                    if page.total > 0 {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(page.start + 1)–\(page.start + page.items.count) / \(page.total)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(appearance.secondary)
                                    .accessibilityIdentifier("reader.bookmarks.count")
                                if dynamicType.isAccessibilitySize {
                                    VStack(alignment: .leading, spacing: 6) { pagingButtons(page) }
                                } else {
                                    HStack(spacing: 10) { pagingButtons(page) }
                                }
                            }
                        }
                        .listRowBackground(appearance.surface)
                        .listRowSeparator(.hidden)
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
        .alert(nameEditor?.title ?? "书签名称", isPresented: $showingNameEditor, presenting: nameEditor) { editor in
            TextField("书签名称", text: $editedName)
                .accessibilityIdentifier("reader.bookmarks.name")
            Button("保存") {
                guard active, editor.presentation == presentationID else { return }
                if let bookmark = editor.bookmark { model.rename(bookmark, name: editedName) }
                else { model.add(name: editedName) }
                nameEditor = nil
            }
            .disabled(!validName || !active || editor.presentation != presentationID ||
                      (editor.bookmark == nil && !model.canAdd))
            .accessibilityIdentifier(editor.bookmark == nil ? "reader.bookmarks.confirmAdd" : "reader.bookmarks.confirmRename")
            Button("取消", role: .cancel) { nameEditor = nil }
        } message: { editor in
            Text(validName ? (editor.bookmark == nil ? "可先填写名称再保存；留空使用默认名称，最多80个字。" :
                "最多80个字；留空恢复默认名称。") : "名称最多80个字，不可包含换行或控制字符。")
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
        .onDisappear { pendingDeletion = nil; nameEditor = nil; showingNameEditor = false; closeFocused = false }
        .accessibilityAction(.escape) { if isActive() { close() } }
    }

    private func bookmarkRow(_ bookmark: ReadingBookmark, ordinal: Int) -> some View {
        let compatible = model.book.map { bookmark.anchor(matching: $0) != nil } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if active { model.jump(bookmark, prepare: prepare, apply: apply) }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(compatible ? appearance.sealAccent : appearance.secondary.opacity(0.4))
                        .frame(width: 3, height: 34)
                        .padding(.top, 2)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(bookmark.displayTitle)
                            .font(.system(.body, design: .serif).weight(.medium))
                            .foregroundStyle(appearance.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("书签 \(ordinal) · \(Date(timeIntervalSince1970: bookmark.createdAt).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(appearance.secondary)
                        if !compatible {
                            Text("文字版本或位置不匹配，无法跳转。")
                                .font(.caption)
                                .foregroundStyle(appearance.sealAccent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!active || model.isBusy || !compatible)
            .accessibilityIdentifier("reader.bookmark.\(bookmark.id)")
            .accessibilityHint("跳转到此书签的文字位置")

            Group {
                if dynamicType.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) { bookmarkActions(bookmark, ordinal: ordinal) }
                } else {
                    HStack(spacing: 10) {
                        bookmarkActions(bookmark, ordinal: ordinal)
                        Spacer(minLength: 0)
                    }
                }
            }
            .font(.footnote.weight(.medium))
        }
        .padding(14)
        .background(appearance.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.7), lineWidth: 0.65)
                .allowsHitTesting(false)
        }
        .accessibilityAction(named: Text("删除书签")) {
            if active && !model.isBusy { pendingDeletion = bookmark }
        }
    }

    private func editName(_ bookmark: ReadingBookmark? = nil) {
        editedName = bookmark?.customName ?? ""
        nameEditor = NameEditor(bookmark: bookmark, presentation: presentationID)
        showingNameEditor = true
    }

    @ViewBuilder private func bookmarkActions(_ bookmark: ReadingBookmark, ordinal: Int) -> some View {
        Button { if active { editName(bookmark) } } label: {
            Label("重命名", systemImage: "pencil")
                .padding(.horizontal, 12).frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(appearance.foreground)
        .background(appearance.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .disabled(!active || model.isBusy)
        .accessibilityLabel("重命名书签 \(ordinal)")
        .accessibilityIdentifier("reader.bookmarks.rename.\(bookmark.id)")

        Button(role: .destructive) { if active { pendingDeletion = bookmark } } label: {
            Label("删除", systemImage: "trash")
                .padding(.horizontal, 12).frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(appearance.sealAccent)
        .background(appearance.sealAccent.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .disabled(!active || model.isBusy)
        .accessibilityLabel("删除书签 \(ordinal)")
        .accessibilityIdentifier("reader.bookmark.delete.\(bookmark.id)")
    }

    private var validName: Bool {
        do { _ = try ReadingBookmark.validatedCustomName(editedName); return true }
        catch { return false }
    }

    @ViewBuilder private func pagingButtons(_ page: ReadingBookmarkPage) -> some View {
        Button {
            if active { model.loadPage(max(0, page.start - ReadingBookmarkPage.pageSize)) }
        } label: {
            Text("上一组书签")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground, role: .primary))
        .disabled(!active || model.isBusy || page.start == 0)

        Button {
            if active { model.loadPage(page.start + ReadingBookmarkPage.pageSize) }
        } label: {
            Text("下一组书签")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground, role: .primary))
        .disabled(!active || model.isBusy || page.start + page.items.count >= page.total)
    }
}

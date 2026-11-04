import Combine
import Foundation
import ReaderDomain

/// Presentation-scoped operations. This model never writes reading progress or settings.
@MainActor
final class ReaderBookmarksViewModel: ObservableObject {
    enum Activity: Equatable { case loading, adding, deleting, renaming, jumping }
    @Published private(set) var page: ReadingBookmarkPage?
    @Published private(set) var activity: Activity?
    @Published private(set) var message: String?
    @Published private(set) var notice: String?
    @Published private(set) var positionMessage: String?
    @Published private(set) var existingAtCapture: ReadingBookmark?
    @Published private(set) var presentationID: UUID?
    private var reader: OpenedReader?
    private var capture: ReadingAnchor?
    private var current: @MainActor () -> Bool = { false }
    private var positionValid: @MainActor () -> Bool = { false }
    private var request: BookmarkRequest?
    private var operationID: UUID?
    private var task: Task<Void, Never>?

    var isBusy: Bool { activity != nil }
    var book: LibraryBook? { reader?.book }
    var canAdd: Bool {
        !isBusy && capture != nil && existingAtCapture == nil && current() && positionValid()
    }
    func owns(_ id: UUID) -> Bool { presentationID == id && current() }

    func present(reader: OpenedReader?, anchor: ReadingAnchor?, presentation: UUID,
                 current: @escaping @MainActor () -> Bool,
                 positionValid: @escaping @MainActor () -> Bool) {
        dismiss()
        self.reader = reader; capture = anchor; presentationID = presentation
        self.current = current; self.positionValid = positionValid
        positionMessage = anchor == nil ? "正文位置尚未稳定，请关闭面板、停止滚动后重新打开。" : nil
    }
    func dismiss(presentation: UUID? = nil) {
        if let presentation, presentationID != presentation { return }
        cancelOperation()
        presentationID = nil; reader = nil; capture = nil
        current = { false }; positionValid = { false }
        page = nil; message = nil; notice = nil; positionMessage = nil; existingAtCapture = nil
    }
    func invalidatePosition() {
        guard presentationID != nil else { return }
        if activity == .adding { cancelOperation() }
        capture = nil; existingAtCapture = nil
        positionMessage = "阅读位置已变化，请关闭面板后重新添加。"
    }
    func show() { if page == nil && !isBusy { loadPage(0) } }

    func loadPage(_ start: Int) {
        guard let owner = reader, let presentation = presentationID,
              let operation = begin(.loading) else { return }
        let captured = capture
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish(operation.id) }
            guard accepts(operation.id, presentation: presentation, owner: owner) else {
                operation.request.cancel(); return
            }
            do {
                let loaded = try await owner.bookmarkPage(start: start, request: operation.request)
                try operation.request.check()
                guard accepts(operation.id, presentation: presentation, owner: owner) else { return }
                page = loaded // A failed read never becomes an empty result.
                if let captured, positionValid() {
                    let existing = try await owner.bookmark(at: captured, request: operation.request)
                    try operation.request.check()
                    guard accepts(operation.id, presentation: presentation, owner: owner), positionValid() else { return }
                    existingAtCapture = existing
                }
                finish(operation.id)
            } catch is CancellationError {
                finish(operation.id)
            } catch {
                fail("书签暂不可用，可重试。原书和阅读进度未改变。", operation: operation.id,
                     presentation: presentation, owner: owner)
            }
        }
    }
    func add(name: String = "") {
        guard canAdd, let captured = capture, let owner = reader, let presentation = presentationID,
              let operation = begin(.adding) else { return }
        let bookmarkID = UUID()
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish(operation.id) }
            do {
                guard accepts(operation.id, presentation: presentation, owner: owner), positionValid() else {
                    operation.request.cancel(); finish(operation.id); return
                }
                let saved = try await owner.addBookmark(at: captured, id: bookmarkID, name: name, request: operation.request)
                // SQLite commit is authoritative. A cancelled presentation only suppresses stale UI.
                guard accepts(operation.id, presentation: presentation, owner: owner) else { return }
                existingAtCapture = saved; notice = "书签已保存。"
                finish(operation.id); loadPage(0)
            } catch is CancellationError {
                finish(operation.id)
            } catch is ReadingBookmark.NameValidationError {
                fail("名称最多80个字，不可包含换行或控制字符。书签未创建。", operation: operation.id,
                     presentation: presentation, owner: owner)
            } catch {
                fail("书签未保存，可重试。原书和阅读进度未改变。", operation: operation.id,
                     presentation: presentation, owner: owner)
            }
        }
    }
    func delete(_ bookmark: ReadingBookmark) {
        guard let owner = reader, bookmark.bookID == owner.book.id,
              let presentation = presentationID, let operation = begin(.deleting) else { return }
        let start = page?.start ?? 0
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish(operation.id) }
            guard accepts(operation.id, presentation: presentation, owner: owner) else {
                operation.request.cancel(); return
            }
            do {
                try await owner.deleteBookmark(id: bookmark.id, request: operation.request)
                guard accepts(operation.id, presentation: presentation, owner: owner) else { return }
                if existingAtCapture?.id == bookmark.id { existingAtCapture = nil }
                notice = "书签已删除，阅读进度未改变。"
                finish(operation.id); loadPage(start)
            } catch is CancellationError {
                finish(operation.id)
            } catch {
                fail("书签未删除，可重试。", operation: operation.id, presentation: presentation, owner: owner)
            }
        }
    }
    func rename(_ bookmark: ReadingBookmark, name: String) {
        guard let owner = reader, bookmark.bookID == owner.book.id,
              let presentation = presentationID, let operation = begin(.renaming) else { return }
        let start = page?.start ?? 0
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish(operation.id) }
            guard accepts(operation.id, presentation: presentation, owner: owner) else {
                operation.request.cancel(); return
            }
            do {
                let saved = try await owner.renameBookmark(id: bookmark.id, name: name, request: operation.request)
                guard accepts(operation.id, presentation: presentation, owner: owner) else { return }
                if existingAtCapture?.id == saved.id { existingAtCapture = saved }
                notice = saved.customName == nil ? "已恢复默认书签名称。" : "书签名称已保存。"
                finish(operation.id); loadPage(start)
            } catch is CancellationError { }
            catch is ReadingBookmark.NameValidationError {
                fail("名称最多80个字，不可包含换行或控制字符。", operation: operation.id,
                     presentation: presentation, owner: owner)
            } catch {
                fail("书签名称未保存，可重试。原位置和阅读进度未改变。", operation: operation.id,
                     presentation: presentation, owner: owner)
            }
        }
    }
    func jump(_ bookmark: ReadingBookmark,
              prepare: @escaping @MainActor (String, BookmarkRequest) async throws -> ReadingWindow,
              apply: @escaping @MainActor (ReadingWindow) -> Bool) {
        guard let owner = reader, bookmark.anchor(matching: owner.book) != nil,
              let presentation = presentationID, let operation = begin(.jumping) else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish(operation.id) }
            guard accepts(operation.id, presentation: presentation, owner: owner) else {
                operation.request.cancel(); return
            }
            do {
                let rendered = try await prepare(bookmark.id, operation.request)
                try operation.request.check()
                guard accepts(operation.id, presentation: presentation, owner: owner) else { return }
                if !apply(rendered) {
                    fail("阅读状态已变化，未跳转到书签。", operation: operation.id,
                         presentation: presentation, owner: owner)
                } else { finish(operation.id) }
            } catch is CancellationError {
                finish(operation.id)
            } catch is ReaderViewModel.BookmarkJumpError {
                fail("阅读状态正在变化，请稍后重试。原阅读进度未改变。", operation: operation.id,
                     presentation: presentation, owner: owner)
            } catch {
                fail("无法定位这条书签。文字版本或位置可能已不匹配，原阅读进度未改变。",
                     operation: operation.id, presentation: presentation, owner: owner)
            }
        }
    }
    private func begin(_ value: Activity) -> (id: UUID, request: BookmarkRequest)? {
        guard presentationID != nil, reader != nil, current(), !isBusy else { return nil }
        let id = UUID(), token = BookmarkRequest()
        operationID = id; request = token; activity = value; message = nil
        return (id, token)
    }
    private func accepts(_ id: UUID, presentation: UUID, owner: OpenedReader) -> Bool {
        operationID == id && presentationID == presentation && reader === owner && current()
    }
    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil; request = nil; task = nil; activity = nil
    }
    private func fail(_ text: String, operation: UUID, presentation: UUID, owner: OpenedReader) {
        guard accepts(operation, presentation: presentation, owner: owner) else { return }
        message = text; finish(operation)
    }
    private func cancelOperation() {
        request?.cancel(); task?.cancel()
        request = nil; task = nil; operationID = nil; activity = nil
    }
    deinit { request?.cancel(); task?.cancel() }
}

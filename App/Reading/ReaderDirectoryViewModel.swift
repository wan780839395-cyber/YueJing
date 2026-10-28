import Combine
import Foundation
import ReaderDomain

@MainActor
final class ReaderDirectoryViewModel: ObservableObject {
    @Published private(set) var state = DirectoryPresentation()
    @Published private(set) var ownerRevision = UUID()
    private var reader: OpenedReader?
    private var task: Task<Void, Never>?
    private var presented = false
    private var manuallyBrowsing = false
    private var displayedAnchor: ReadingAnchor?
    private var displayRevision = UUID()

    func attach(_ value: OpenedReader) {
        detach(); reader = value; ownerRevision = UUID()
    }
    func detach() {
        cancel(); reader = nil; presented = false; manuallyBrowsing = false
        displayedAnchor = nil; state = DirectoryPresentation(); ownerRevision = UUID(); displayRevision = UUID()
    }
    func dismiss(presentation: UUID? = nil) {
        if let presentation, !state.dismiss(presentation) { return }
        presented = false; cancel()
    }
    func cancel() { task?.cancel(); task = nil; state.cancel() }
    func present(around anchor: ReadingAnchor?, presentation: UUID) {
        guard !Task.isCancelled else { return }
        state.present(presentation)
        presented = true; manuallyBrowsing = false; displayedAnchor = anchor
        if let anchor { schedule(.current(anchor), reveal: true) }
    }
    func displayed(_ anchor: ReadingAnchor) {
        guard displayedAnchor != anchor else {
            // Resume a cancelled first lookup without refreshing a loaded/manual page.
            if presented, !manuallyBrowsing, state.page == nil, !state.loading {
                schedule(.current(anchor), reveal: true)
            }
            return
        }
        displayedAnchor = anchor; displayRevision = UUID()
        guard presented else { return }
        state.clearCurrent()
        // Automatic display changes may update the highlight, but never steal manual paging/focus.
        if !manuallyBrowsing { schedule(.current(anchor), reveal: state.page == nil) }
    }
    func retry() { requestCurrent() }
    func requestCurrent() {
        guard let displayedAnchor else { return }
        manuallyBrowsing = false; schedule(.current(displayedAnchor), reveal: true)
    }
    func loadPage(_ start: Int) {
        manuallyBrowsing = true; schedule(.page(start), reveal: false)
    }
    private func schedule(_ target: DirectoryRequest, reveal: Bool) {
        guard presented, let owner = reader, let id = state.begin(target) else { return }
        // Establish the intent BEFORE queuing the Task; old queued work cannot begin a new intent.
        task?.cancel()
        let revision = ownerRevision, display = displayRevision, current = state.page?.currentIndex
        task = Task {
            guard presented, ownerRevision == revision, reader === owner,
                  state.requestID == id, !Task.isCancelled else { return }
            do {
                let value: ReadingDirectoryPage
                switch target {
                case .current(let anchor): value = try await owner.directory(around: anchor)
                case .page(let start): value = try await owner.directoryPage(start: start, currentIndex: current)
                }
                try Task.checkCancellation()
                guard presented, ownerRevision == revision, reader === owner, state.requestID == id else { return }
                if state.apply(value, request: id, revealCurrent: reveal,
                               locationStillCurrent: display == displayRevision) { task = nil }
            } catch is CancellationError {
                if ownerRevision == revision, state.requestID == id { state.cancel(); task = nil }
            } catch {
                guard presented, ownerRevision == revision, reader === owner else { return }
                if state.fail("目录暂不可用。可重试，或关闭目录、返回书架后重新打开。原书与已保存位置保留。", request: id) { task = nil }
            }
        }
    }
}

import Foundation
import Testing
@testable import ReaderDomain

struct LibraryPresentationTests {
    @Test func importPresentationUsesActualStagesAndIgnoresRetiredAttempts() {
        var state = LibraryImportPresentation()
        let old = UUID(), current = UUID()
        state.begin(old); state.receive(.decodingStarted, for: old)
        #expect(state.phase == .decoding)
        state.begin(current); state.receive(.committed, for: old)
        #expect(state.phase == .waiting && state.active)
        state.receive(.coordinationStarted, for: current)
        #expect(state.phase == .copying)
        state.receive(.stagedReadStarted, for: current)
        #expect(state.phase == .reading)
        state.receive(.ambiguityDetected, for: current)
        #expect(state.phase == .choosing)
        state.receive(.decodingCompleted, for: current)
        #expect(state.phase == .registering)
        state.receive(.committed, for: current)
        #expect(state.phase == .committed)
        state.finish(current); state.receive(.decodingStarted, for: current)
        #expect(!state.active && state.phase == .committed)
    }
    @Test func stoppingIsPendingAndAnAuthoritativeCommitNeverBecomesCancelledNotice() {
        let id = UUID(); var state = LibraryImportPresentation(); state.begin(id)
        let first = state.requestStop(for: id), duplicate = state.requestStop(for: id)
        #expect(first && !duplicate && state.active && state.stopRequested)
        state.receive(.committed, for: id)
        #expect(state.phase == .committed && state.stopRequested)
        for duplicateBook in [false, true] {
            let notice = LibraryNotice.committed(duplicate: duplicateBook, stopRequested: true, preparationDeferred: true)
            #expect(notice != .cancelledBeforeCommit && notice != .selectionCancelled)
            #expect(notice.detail.contains("已经保存") && !notice.detail.contains("没有添加新书"))
        }
        state.finish(id)
        let lateStop = state.requestStop(for: id)
        #expect(!lateStop && !state.active)
    }
    @Test func deferredPreparationStillReportsTheCommittedBookAndPreservedPosition() {
        let ready = LibraryNotice.committed(duplicate: false, stopRequested: false, preparationDeferred: false)
        let deferred = LibraryNotice.committed(duplicate: false, stopRequested: false, preparationDeferred: true)
        #expect(ready.title == deferred.title)
        #expect(deferred.detail.contains("原件已保存") && deferred.detail.contains("位置保留"))
        let duplicate = LibraryNotice.committed(duplicate: true, stopRequested: false, preparationDeferred: false)
        #expect(duplicate.detail.contains("原阅读位置已保留"))
    }
    @Test func onlyTheActiveAttemptCanRequestStopAndSelectionCancellationIsDistinct() {
        let current = UUID(); var state = LibraryImportPresentation(); state.begin(current)
        let stale = state.requestStop(for: UUID())
        #expect(!stale && !state.stopRequested)
        #expect(LibraryNotice.selectionCancelled != .cancelledBeforeCommit)
        state.finish(UUID())
        #expect(state.active)
        state.finish(current)
        state.receive(.cancelRequested, for: current)
        #expect(!state.stopRequested)
    }
}

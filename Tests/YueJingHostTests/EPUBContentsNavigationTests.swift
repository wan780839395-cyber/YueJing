import ReaderDomain
import Testing
@testable import YueJing

/// Pure selection/filter/reveal policy checks, not proof of SwiftUI List rendering.
@MainActor
struct EPUBContentsNavigationTests {
    @Test func largeDirectoryResolvesFirstMiddleAndLast() {
        let items = (0..<10_000).map {
            EPUBNavigationItem(title: "章节 \($0 + 1)", path: "chapter-\($0).xhtml")
        }
        let all = EPUBContentsView.filteredIndices(in: items, query: "")
        #expect(all == Array(items.indices))
        for index in [0, 5_000, 9_999] {
            let current = EPUBContentsView.currentIndex(in: items, path: items[index].path, fragment: nil)
            #expect(current == index)
            var reveal = EPUBContentsRevealState()
            reveal.request(current)
            let initial = reveal.initialTarget()
            let mounted = reveal.mountedTarget(index)
            #expect(initial == index && mounted == index)
            #expect(reveal.requestID == nil)
        }
    }

    @Test func samePathPrefersFragmentThenFallsBackToFirstPath() {
        let items = [
            EPUBNavigationItem(title: "开头", path: "shared.xhtml"),
            EPUBNavigationItem(title: "第一节", path: "shared.xhtml", fragment: "first"),
            EPUBNavigationItem(title: "第二节", path: "shared.xhtml", fragment: "second"),
            EPUBNavigationItem(title: "重复锚点", path: "shared.xhtml", fragment: "second")
        ]
        #expect(EPUBContentsView.currentIndex(in: items, path: "shared.xhtml", fragment: "second") == 2)
        #expect(EPUBContentsView.currentIndex(in: items, path: "shared.xhtml", fragment: "first") == 1)
        for fragment in [nil, "", "missing"] as [String?] {
            #expect(EPUBContentsView.currentIndex(in: items, path: "shared.xhtml", fragment: fragment) == 0)
        }
        #expect(EPUBContentsView.currentIndex(in: items, path: "missing.xhtml", fragment: "second") == nil)
        #expect(EPUBContentsView.currentIndex(in: items, path: nil, fragment: "second") == nil)
    }

    @Test func filteringKeepsOriginalIndicesOrdinalsAndItems() {
        let items = [
            EPUBNavigationItem(title: "序", path: "a.xhtml"),
            EPUBNavigationItem(title: "山路", path: "shared.xhtml", fragment: "part", depth: 2),
            EPUBNavigationItem(title: "", path: "c.xhtml"),
            EPUBNavigationItem(title: "山顶", path: "shared.xhtml", fragment: "part", depth: 4),
            EPUBNavigationItem(title: "Finale", path: "last.xhtml")
        ]
        let matches = EPUBContentsView.filteredIndices(in: items, query: "  山\n")
        #expect(matches == [1, 3])
        #expect(matches.map { $0 + 1 } == [2, 4])
        #expect(matches.map { items[$0] } == [items[1], items[3]])
        #expect(items[1].id == items[3].id) // Index identity must not collapse duplicate hrefs.
        #expect(EPUBContentsView.filteredIndices(in: items, query: "4") == [3])
        #expect(EPUBContentsView.filteredIndices(in: items, query: "第 3 节") == [2])
        #expect(EPUBContentsView.filteredIndices(in: items, query: "finale") == [4])
        #expect(EPUBContentsView.filteredIndices(in: items, query: " \n ") == [0, 1, 2, 3, 4])
        // Clearing a filter restores the same original target; it is not a selection callback.
        let target = EPUBContentsView.currentIndex(in: items, path: "shared.xhtml", fragment: "part")
        #expect(target == 1)
        #expect(EPUBContentsView.filteredIndices(in: items, query: "").contains(1))
    }

    @Test func emptyAndUnmatchedDirectoriesHaveNoInventedTarget() {
        #expect(EPUBContentsView.currentIndex(in: [], path: "a.xhtml", fragment: nil) == nil)
        #expect(EPUBContentsView.filteredIndices(in: [], query: "") == [])
        #expect(EPUBContentsView.filteredIndices(in: [], query: "1") == [])
        let items = [EPUBNavigationItem(title: "序", path: "a.xhtml")]
        #expect(EPUBContentsView.filteredIndices(in: items, query: "不存在") == [])
        #expect(EPUBContentsView.filteredIndices(in: items, query: "0") == [])
        var reveal = EPUBContentsRevealState()
        reveal.request(nil)
        let initial = reveal.initialTarget()
        let mounted = reveal.mountedTarget(0)
        #expect(initial == nil && mounted == nil && reveal.requestID == nil)
    }

    @Test func lazyMountCorrectionIsBoundedAndOnlyForTheTarget() {
        var reveal = EPUBContentsRevealState()
        reveal.request(9_999)
        let prematureMount = reveal.mountedTarget(9_999)
        #expect(prematureMount == nil)
        let initial = reveal.initialTarget()
        let repeatedInitial = reveal.initialTarget()
        let otherRow = reveal.mountedTarget(0)
        #expect(initial == 9_999 && repeatedInitial == nil && otherRow == nil)
        let correction = reveal.mountedTarget(9_999)
        let repeatedMount = reveal.mountedTarget(9_999)
        let afterCompletion = reveal.initialTarget()
        #expect(correction == 9_999 && repeatedMount == nil && afterCompletion == nil)
    }

    @Test func cancellationAndNewRequestsInvalidateLateWork() {
        var reveal = EPUBContentsRevealState()
        reveal.request(500)
        let oldOwner = reveal.requestID
        let initial = reveal.initialTarget()
        #expect(initial == 500)
        // The view uses this same cancellation for drag, filtering, inactive and dismissal.
        reveal.cancel()
        let cancelledMount = reveal.mountedTarget(500)
        let cancelledInitial = reveal.initialTarget()
        #expect(cancelledMount == nil && cancelledInitial == nil)
        reveal.request(500) // Reopen/explicit return creates fresh ownership, even for the same row.
        #expect(reveal.requestID != nil && reveal.requestID != oldOwner)
        let newInitial = reveal.initialTarget()
        #expect(newInitial == 500)
        reveal.request(800)
        let lateOldMount = reveal.mountedTarget(500)
        let newTarget = reveal.initialTarget()
        #expect(lateOldMount == nil && newTarget == 800)
        reveal.cancel()
        #expect(reveal.targetIndex == nil && !reveal.initialIssued)
    }

    @Test func directoryAccessRequiresEveryLiveAndRenderedPermission() {
        for presented in [false, true] {
            for sceneActive in [false, true] {
                for ownerActive in [false, true] {
                    for liveOwnerActive in [false, true] {
                        let state = EPUBContentsAccess.resolve(
                            presented: presented, sceneActive: sceneActive,
                            ownerActive: ownerActive, liveOwnerActive: liveOwnerActive
                        )
                        #expect((state == .active) == (presented && sceneActive && ownerActive && liveOwnerActive))
                        if !presented { #expect(state == .notPresented) }
                        else if !sceneActive { #expect(state == .sceneInactive) }
                        else if !ownerActive || !liveOwnerActive { #expect(state == .ownerInactive) }
                    }
                }
            }
        }
    }

    @Test func directoryReopenAndForegroundNeverRestoreOldSessionAuthority() throws {
        var tools = ReadingToolsPresentation()
        tools.open(.directory)
        let first = try #require(tools.panelID)
        let closed = tools.closePanel(id: first)
        #expect(closed)
        tools.open(.directory)
        let second = try #require(tools.panelID)
        #expect(second != first && tools.owns(.directory, id: second))
        let staleClose = tools.closePanel(id: first)
        let staleSelection = tools.chapterSelected(id: first)
        #expect(!staleClose && !staleSelection && tools.panelID == second)
        tools.suspend()
        #expect(!tools.owns(.directory, id: second))
        let backgroundClose = tools.closePanel(id: second)
        #expect(!backgroundClose)
        tools.resume()
        #expect(!tools.owns(.directory, id: second))
        tools.open(.directory)
        let third = try #require(tools.panelID)
        #expect(third != second && tools.owns(.directory, id: third))
        let exitRequest = tools.beginExit()
        let exit = try #require(exitRequest)
        #expect(!tools.owns(.directory, id: third))
        let lateSelection = tools.chapterSelected(id: third)
        #expect(!lateSelection)
        let finished = tools.finishExit(exit, succeeded: true)
        #expect(finished && !tools.valid)
        tools.resume()
        #expect(!tools.canInteract)
    }

    @Test func chapterLoadingKeepsHiddenToolsAndDefersOnlyChapterFeedback() throws {
        for phase in [EPUBOpeningFeedback.quiet, .compact, .detailed] {
            #expect(EPUBReaderLoadingPresentation.showsFeedback(initialOpening: true, phase: phase))
            #expect(EPUBReaderLoadingPresentation.showsFeedback(initialOpening: false, phase: phase) == (phase != .quiet))
        }
        #expect(EPUBReaderLoadingPresentation.restoresTools(initialOpening: true))
        #expect(!EPUBReaderLoadingPresentation.restoresTools(initialOpening: false))
        var tools = ReadingToolsPresentation()
        tools.open(.directory)
        let session = try #require(tools.panelID)
        let selected = tools.chapterSelected(id: session)
        #expect(selected && tools.mode == .hidden)
        if EPUBReaderLoadingPresentation.restoresTools(initialOpening: false) { tools.forceCompact() }
        #expect(tools.mode == .hidden && !tools.owns(.directory, id: session))
        // Delayed feedback's cancel action uses the same exit gate, not forceCompact.
        let exit = tools.beginExit()
        #expect(exit != nil && tools.exitRequest == exit)
    }
}

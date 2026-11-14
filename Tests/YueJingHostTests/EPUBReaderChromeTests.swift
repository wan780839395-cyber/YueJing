import ReaderDomain
import Testing
@testable import YueJing

/// Read-only title mapping, not proof of SwiftUI rendering or native focus.
@MainActor
struct EPUBReaderChromeTests {
    @Test func confirmedUniquePathDisplaysOnlyItsTitle() {
        let items = [
            EPUBNavigationItem(title: "序", path: "intro.xhtml"),
            EPUBNavigationItem(title: "  雨停以后\n", path: "chapter.xhtml")
        ]
        #expect(EPUBReaderChapterContext.title(in: items, path: "chapter.xhtml", confirmedPath: "chapter.xhtml") == "雨停以后")
        #expect(EPUBReaderChapterContext.title(in: items, path: "intro.xhtml", confirmedPath: "intro.xhtml") == "序")
    }

    @Test func pendingOrMismatchedPathNeverInventsCurrentChapter() {
        let items = [EPUBNavigationItem(title: "目标章节", path: "target.xhtml")]
        #expect(EPUBReaderChapterContext.title(in: items, path: "target.xhtml", confirmedPath: nil) == nil)
        #expect(EPUBReaderChapterContext.title(in: items, path: "target.xhtml", confirmedPath: "old.xhtml") == nil)
        #expect(EPUBReaderChapterContext.title(in: items, path: nil, confirmedPath: "target.xhtml") == nil)
        #expect(EPUBReaderChapterContext.title(in: items, path: "", confirmedPath: "") == nil)
        #expect(EPUBReaderChapterContext.title(in: items, path: "unknown.xhtml", confirmedPath: "unknown.xhtml") == nil)
    }

    @Test func sharedDocumentAnchorsRemainUnknownWithoutVisibleAnchorEvidence() {
        let items = [
            EPUBNavigationItem(title: "第一节", path: "shared.xhtml", fragment: "first"),
            EPUBNavigationItem(title: "第二节", path: "shared.xhtml", fragment: "second")
        ]
        #expect(EPUBReaderChapterContext.title(in: items, path: "shared.xhtml", confirmedPath: "shared.xhtml") == nil)
        let duplicates = [items[0], items[0]]
        #expect(EPUBReaderChapterContext.title(in: duplicates, path: "shared.xhtml", confirmedPath: "shared.xhtml") == nil)
    }

    @Test func emptyTitlesAndLargeDirectoriesHaveDeterministicReadOnlyResults() {
        let blank = [EPUBNavigationItem(title: " \n\t", path: "blank.xhtml")]
        #expect(EPUBReaderChapterContext.title(in: blank, path: "blank.xhtml", confirmedPath: "blank.xhtml") == nil)
        #expect(EPUBReaderChapterContext.title(in: [], path: "none.xhtml", confirmedPath: "none.xhtml") == nil)
        let items = (0..<10_000).map { EPUBNavigationItem(title: "章节 \($0)", path: "\($0).xhtml") }
        let original = items
        for index in [0, 5_000, 9_999] {
            #expect(EPUBReaderChapterContext.title(in: items, path: "\(index).xhtml", confirmedPath: "\(index).xhtml") == "章节 \(index)")
        }
        #expect(items == original)
    }
}

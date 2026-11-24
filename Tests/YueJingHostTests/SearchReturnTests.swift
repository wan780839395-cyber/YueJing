import Foundation
import ReaderDomain
import Testing
@testable import YueJing

struct SearchReturnTests {
    @Test func epubSearchReturnPreservesFirstLocatorUntilConfirmedReturn() {
        let first = EPUBReadingPosition(bookID: "book", versionID: "edition", path: "one.xhtml",
                                        node: 4, utf16Offset: 13, viewportOffset: -24.5)
        let second = EPUBReadingPosition(bookID: "book", versionID: "edition", path: "two.xhtml",
                                         node: 1, utf16Offset: 7, viewportOffset: 18)
        var state = SearchReturn<EPUBReadingPosition>()
        let failed = UUID(), hit = UUID(), nextHit = UUID()
        state.stage(.remember(second), navigation: failed)
        state.cancelPending()
        state.stage(.remember(first), navigation: hit)
        state.confirm(navigation: failed)
        #expect(state.origin == nil)
        state.confirm(navigation: hit)
        #expect(state.origin == first)
        state.stage(.remember(second), navigation: nextHit)
        state.confirm(navigation: nextHit)
        #expect(state.origin == first)

        let interrupted = UUID(), retry = UUID()
        state.stage(.returned, navigation: interrupted)
        state.cancelPending()
        state.confirm(navigation: interrupted)
        #expect(state.origin == first)
        state.stage(.returned, navigation: retry)
        #expect(state.origin == first)
        state.confirm(navigation: retry)
        #expect(state.origin == nil)

        let obsolete = UUID()
        state.stage(.remember(first), navigation: obsolete)
        state = .init() // Same edition, new opening; the old acknowledgement arrives late.
        state.confirm(navigation: obsolete)
        #expect(state.origin == nil)
    }
}

import Foundation
import ReaderDomain
import Testing
import ZIPFoundation
@testable import YueJing

/// Model/authority tests using only synthetic EPUBs and injected validated locator events.
/// These do not claim to exercise font decoding, WKWebView rendering or actual timeout timing.
@MainActor
@Suite(.serialized)
struct EPUBWarningStateTests {
    @Test func epubWarningBadChapterToNormalRetainsOnlySessionHistory() async throws {
        try await withBook { model, _, _ in
            let bad = try #require(model.currentToken)
            try await acceptReady(model, token: bad, fallback: true)
            #expect(model.runtimeFontFallback && model.sessionFontFallbackObserved)
            #expect(model.compatibilityNotice?.contains("当前章节") == true)
            model.dismissCompatibilityNotice()
            #expect(model.compatibilityNotice == nil)

            let normalPath = try #require(model.spine.last)
            model.navigateToInternalLink(path: normalPath, fragment: nil)
            #expect(model.runtimeFontFallback == false && model.runtimeFontFallbackToken == nil)
            let normal = try await nextToken(model, after: bad)
            try await acceptReady(model, token: normal, fallback: false)
            #expect(model.runtimeFontFallback == false && model.runtimeFontFallbackToken == normal)
            #expect(model.compatibilitySummary == nil && model.compatibilityNotice == nil)
            #expect(model.sessionFontFallbackObserved)
            #expect(model.bookCompatibilityDetails?.contains("本次打开曾") == true)
            model.handleLocatorEvent(payload(bad, kind: .scroll, fallback: true))
            #expect(model.runtimeFontFallback == false && model.currentToken == normal)
            // A genuine new current problem is not suppressed by the previous chapter's dismissal.
            model.handleLocatorEvent(payload(normal, kind: .scroll, fallback: true))
            #expect(model.compatibilityNotice != nil)
        }
    }

    @Test func epubWarningReaderChoiceAndAuthorReturnDoNotInheritFallback() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: EPUBLayoutMode.defaultsKey)
        defer {
            if let saved { defaults.set(saved, forKey: EPUBLayoutMode.defaultsKey) }
            else { defaults.removeObject(forKey: EPUBLayoutMode.defaultsKey) }
        }
        try await withBook { model, _, _ in
            let author = try #require(model.currentToken)
            try await acceptReady(model, token: author, fallback: true)
            model.setLayoutMode(.reader)
            #expect(model.compatibilitySummary == nil && model.runtimeFontFallback == false)
            // Old author callbacks can arrive during settings sampling, before a new token exists.
            model.handleLocatorEvent(payload(author, kind: .scroll, fallback: true))
            #expect(model.runtimeFontFallback == false)
            let chosenReader = try await nextToken(model, after: author)
            try await acceptReady(model, token: chosenReader, fallback: true)
            #expect(model.layoutMode == .reader && model.effectiveLayoutMode == .reader)
            #expect(model.runtimeFontFallback == false && model.compatibilitySummary == nil)
            #expect(model.sessionFontFallbackObserved && model.bookCompatibilityDetails != nil)

            model.setLayoutMode(.original)
            model.handleLocatorEvent(payload(chosenReader, kind: .scroll, fallback: true))
            #expect(model.runtimeFontFallback == false)
            let restoredAuthor = try await nextToken(model, after: chosenReader)
            try await acceptReady(model, token: restoredAuthor, fallback: false)
            #expect(model.layoutMode == .original && model.compatibilitySummary == nil)
            #expect(model.runtimeFontFallback == false && model.sessionFontFallbackObserved)
        }
    }

    @Test func epubWarningSuccessfulExplicitRetryClearsCurrentFallback() async throws {
        try await withBook { model, _, _ in
            let timedOut = try #require(model.currentToken)
            // Inject the accepted fallback result; this test does not simulate the JS timeout itself.
            try await acceptReady(model, token: timedOut, fallback: true)
            model.dismissCompatibilityNotice()
            await model.retry()
            let recovered = try #require(model.currentToken)
            #expect(recovered != timedOut && model.runtimeFontFallback == false)
            try await acceptReady(model, token: recovered, fallback: false)
            #expect(model.compatibilityNotice == nil && model.compatibilitySummary == nil)
            #expect(model.sessionFontFallbackObserved && model.bookCompatibilityDetails != nil)
            await model.retry()
            let failedAgain = try #require(model.currentToken)
            try await acceptReady(model, token: failedAgain, fallback: true)
            #expect(model.compatibilityNotice != nil)
        }
    }

    @Test func epubWarningReopenRejectsPreviousSessionAndResetsRuntimeHistory() async throws {
        try await withBook { first, service, bookID in
            let oldToken = try #require(first.currentToken)
            try await acceptReady(first, token: oldToken, fallback: true)
            let closed = await first.close()
            #expect(closed && first.runtimeFontFallback == false)
            let reopened = EPUBReaderViewModel(bookID: bookID, service: service,
                                               readingMode: .scroll, layoutMode: .original)
            await reopened.load()
            let freshToken = try #require(reopened.currentToken)
            #expect(freshToken.sessionID != oldToken.sessionID)
            try await acceptReady(reopened, token: freshToken, fallback: false)
            reopened.handleLocatorEvent(payload(oldToken, kind: .ready, fallback: true))
            reopened.handleLocatorEvent(payload(oldToken, kind: .scroll, fallback: true))
            await Task.yield()
            #expect(reopened.runtimeFontFallback == false && reopened.sessionFontFallbackObserved == false)
            #expect(reopened.compatibilitySummary == nil && reopened.currentToken == freshToken)
            let reopenedClosed = await reopened.close()
            #expect(reopenedClosed)
        }
    }

    @Test func epubWarningRevocationRejectsQueuedReadyAndOldToken() async throws {
        try await withBook { model, _, _ in
            let revoked = try #require(model.currentToken)
            // Revoke synchronously before the scheduled markReady continuation can publish history.
            model.handleLocatorEvent(payload(revoked, kind: .ready, fallback: true))
            model.handleLoadFailure(URLError(.timedOut), token: revoked)
            model.handleLocatorEvent(payload(revoked, kind: .ready, fallback: true))
            await Task.yield()
            #expect(model.currentToken == nil && model.runtimeFontFallback == false)
            #expect(model.sessionFontFallbackObserved == false)
            await model.retry()
            let current = try #require(model.currentToken)
            try await acceptReady(model, token: current, fallback: false)
            model.handleLocatorEvent(payload(revoked, kind: .scroll, fallback: true))
            await Task.yield()
            #expect(model.runtimeFontFallback == false && model.sessionFontFallbackObserved == false)
        }
    }

    @Test func epubWarningCurrentScrollReplacesFallbackAndRearmsNotice() async throws {
        try await withBook { model, _, _ in
            let token = try #require(model.currentToken)
            try await acceptReady(model, token: token, fallback: false)
            model.handleLocatorEvent(payload(token, kind: .scroll, fallback: true))
            #expect(model.runtimeFontFallback && model.compatibilityNotice != nil)
            model.dismissCompatibilityNotice()
            model.handleLocatorEvent(payload(token, kind: .scroll, fallback: false))
            #expect(model.runtimeFontFallback == false && model.compatibilitySummary == nil)
            #expect(model.sessionFontFallbackObserved)
            model.handleLocatorEvent(payload(token, kind: .scroll, fallback: true))
            #expect(model.runtimeFontFallback && model.compatibilityNotice != nil)
            let invalid = EPUBLocatorPayload(kind: .scroll, sessionID: token.sessionID, epoch: token.epoch,
                path: token.path, node: -1, utf16Offset: 0, restoredNode: 0, restoredOffset: 0,
                scrollY: 0, viewportHeight: 700, contentHeight: 2000, visibleText: "", reason: nil)
            model.handleLocatorEvent(invalid)
            #expect(model.runtimeFontFallback) // Invalid coordinates cannot erase a real warning.
        }
    }

    @Test func epubWarningBookIssuesStayInDetailsWithoutCurrentChapterVerdict() async throws {
        try await withBook(includeBookIssue: true) { model, _, _ in
            let compatibility = try #require(model.styleCompatibility)
            #expect(compatibility.issues.contains(.fontUnavailable))
            let token = try #require(model.currentToken)
            try await acceptReady(model, token: token, fallback: false)
            #expect(model.compatibilitySummary == nil)
            #expect(model.bookCompatibilityDetails?.contains("部分作者字体不可用") == true)
            #expect(model.bookCompatibilityDetails?.contains("不代表当前章") == true)
            #expect(model.styleCompatibility == compatibility && model.sessionFontFallbackObserved == false)
        }
    }

    @Test func epubWarningSummaryDistinguishesForcedLayoutFromUserChoice() {
        let forced = EPUBStyleCompatibility(issues: [], usesReaderLayout: true)
        #expect(EPUBReaderViewModel.warningSummary(layoutMode: .original, compatibility: forced,
                                                  runtimeFontFallback: false)?.contains("自动") == true)
        #expect(EPUBReaderViewModel.warningSummary(layoutMode: .reader, compatibility: forced,
                                                  runtimeFontFallback: true) == nil)
        let bookHistory = EPUBStyleCompatibility(issues: [.fontUnavailable, .navigationUnavailable])
        #expect(EPUBReaderViewModel.warningSummary(layoutMode: .original, compatibility: bookHistory,
                                                  runtimeFontFallback: false) == nil)
        #expect(EPUBReaderViewModel.warningSummary(layoutMode: .original, compatibility: bookHistory,
                                                  runtimeFontFallback: true)?.contains("当前章节") == true)
        #expect(EPUBReaderViewModel.warningSummary(layoutMode: .reader, compatibility: bookHistory,
                                                  runtimeFontFallback: true) == nil)
    }

    @Test func epubWarningPendingRestorationDoesNotRecordFallback() async throws {
        try await withBook { model, _, _ in
            let token = try #require(model.currentToken)
            var pending = payload(token, kind: .ready, fallback: true)
            pending.restorationPending = true
            model.handleLocatorEvent(pending)
            await Task.yield()
            #expect(model.ready == false && model.runtimeFontFallback == false)
            #expect(model.sessionFontFallbackObserved == false)
            try await acceptReady(model, token: token, fallback: false)
            #expect(model.runtimeFontFallback == false && model.sessionFontFallbackObserved == false)
        }
    }

    private func payload(_ token: EPUBNavigationToken, kind: EPUBLocatorPayload.Kind,
                         fallback: Bool) -> EPUBLocatorPayload {
        EPUBLocatorPayload(kind: kind, sessionID: token.sessionID, epoch: token.epoch,
            path: token.path, node: 0, utf16Offset: 0, restoredNode: 0, restoredOffset: 0,
            scrollY: 0, viewportHeight: 700, contentHeight: 2000, visibleText: "", reason: nil,
            authorStyleFallback: fallback)
    }

    private func acceptReady(_ model: EPUBReaderViewModel, token: EPUBNavigationToken,
                             fallback: Bool) async throws {
        model.handleLocatorEvent(payload(token, kind: .ready, fallback: fallback))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.ready == false, model.currentToken == token, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.ready && model.currentToken == token)
    }

    private func nextToken(_ model: EPUBReaderViewModel, after previous: EPUBNavigationToken) async throws -> EPUBNavigationToken {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (model.currentToken == nil || model.currentToken == previous), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let token = try #require(model.currentToken)
        try #require(token != previous)
        return token
    }

    private func withBook(includeBookIssue: Bool = false,
                          _ body: @MainActor (EPUBReaderViewModel, LibraryService, String) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YueJing-Warnings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Synthetic.epub")
        try writeSyntheticEPUB(to: url, includeBookIssue: includeBookIssue)
        let service = LibraryService(store: try LibraryStore(root: root.appendingPathComponent("Managed")))
        let result = try await service.prepareReadingImport(url: url, ticket: UUID(), budget: ReaderStoragePolicy.budget())
        guard case .completed(let receipt) = result else { throw EPUBError.invalidPackage }
        let model = EPUBReaderViewModel(bookID: receipt.book.id, service: service,
                                        readingMode: .scroll, layoutMode: .original)
        await model.load()
        do { try await body(model, service, receipt.book.id) }
        catch { await model.leaveKeepingSavedPosition(); throw error }
        await model.leaveKeepingSavedPosition()
    }

    private func writeSyntheticEPUB(to url: URL, includeBookIssue: Bool) throws {
        let style = includeBookIssue
            ? "<style>@font-face { font-family: SyntheticMissing; src: local('SyntheticMissing'); } p { font-family: SyntheticMissing, serif; }</style>"
            : ""
        let opf = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee</dc:identifier><dc:title>Synthetic Warnings</dc:title><dc:language>en</dc:language></metadata>
          <manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>
          <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
        </package>
        """
        let entries: [(String, String)] = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", "<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" version=\"1.0\"><rootfiles><rootfile full-path=\"OPS/book.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"),
            ("OPS/book.opf", opf),
            ("OPS/c1.xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>One</title>\(style)</head><body><p>First synthetic chapter.</p></body></html>"),
            ("OPS/c2.xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Two</title></head><body><p>Second synthetic chapter.</p></body></html>"),
            ("OPS/nav.xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Contents</title></head><body><nav epub:type=\"toc\"><ol><li><a href=\"c1.xhtml\">One</a></li><li><a href=\"c2.xhtml\">Two</a></li></ol></nav></body></html>")
        ]
        let archive = try Archive(url: url, accessMode: .create)
        for (path, text) in entries {
            let data = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
    }
}

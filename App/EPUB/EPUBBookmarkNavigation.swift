import Foundation
import ReaderDomain

@MainActor
extension EPUBReaderViewModel {
    /// Bookmarks need a fresh viewport sample. The progress-saving API may fall back to its
    /// last payload; a stale sample must never stand in for the user's explicit selection.
    func addVisibleBookmark(isActive: () -> Bool) async throws -> Bool {
        guard isActive(), let token = presentationToken, let reader,
              let controller = webView.controller else { throw EPUBError.staleSession }
        let sample = await controller.sampleVisibleNow()
        try Task.checkCancellation()
        guard isActive(), presentationToken == token, self.reader === reader,
              webView.controller === controller else { throw EPUBError.staleSession }
        guard let sample, sample.sessionID == token.sessionID, sample.epoch == token.epoch,
              sample.path == token.path else { throw EPUBError.invalidPosition }
        let package = reader.publication.package
        let position = try EPUBLocationScript.makeValidatedPosition(
            bookID: reader.book.id, package: package, path: sample.path, node: sample.node,
            rawUTF16Offset: sample.utf16Offset, viewportOffset: sample.viewportOffset
        )
        let ordinalTitle = package.spine.firstIndex(of: sample.path).map { "第 \($0 + 1) 节" } ?? "阅读位置"
        let chapter = EPUBReaderChapterContext.title(in: navigationItems, path: sample.path, confirmedPath: token.path)
            .flatMap { $0.utf8.count <= 1024 ? $0 : nil } ?? ordinalTitle
        return try await reader.addBookmark(position, title: chapter, token: token)
    }

    func jumpToBookmark(id: String, isActive: () -> Bool) async throws {
        guard isActive(), let reader, let token = presentationToken else { throw EPUBError.staleSession }
        // Resolve by database identity again; never navigate to a stale list snapshot.
        let position = try await reader.bookmarkPosition(id: id)
        try Task.checkCancellation()
        guard isActive(), self.reader === reader, presentationToken == token else { throw EPUBError.staleSession }
        navigateExplicitly(path: position.path, fragment: nil, target: position)
    }
}

import Foundation
import ReaderDomain

@MainActor
extension EPUBReaderViewModel {
    /// Unlike progress flushing, explicit user locations may not fall back to a cached payload.
    func sampleVisiblePosition(reader: OpenedEPUBReader, token: EPUBNavigationToken,
                               isActive: () -> Bool) async throws -> EPUBReadingPosition {
        guard isActive(), presentationToken == token, self.reader === reader,
              token.sessionID == reader.reading.session.id,
              let controller = webView.controller else { throw EPUBError.staleSession }
        let sample = await controller.sampleVisibleNow()
        try Task.checkCancellation()
        guard isActive(), presentationToken == token, self.reader === reader,
              webView.controller === controller else { throw EPUBError.staleSession }
        guard let sample, sample.sessionID == token.sessionID, sample.epoch == token.epoch,
              sample.path == token.path else { throw EPUBError.invalidPosition }
        return try EPUBLocationScript.makeValidatedPosition(
            bookID: reader.book.id, package: reader.publication.package, path: sample.path, node: sample.node,
            rawUTF16Offset: sample.utf16Offset, viewportOffset: sample.viewportOffset
        )
    }

    func addVisibleBookmark(isActive: () -> Bool) async throws -> Bool {
        guard isActive(), let token = presentationToken, let reader else { throw EPUBError.staleSession }
        let position = try await sampleVisiblePosition(reader: reader, token: token, isActive: isActive)
        try Task.checkCancellation()
        guard isActive(), presentationToken == token, self.reader === reader else { throw EPUBError.staleSession }
        let package = reader.publication.package
        let ordinalTitle = package.spine.firstIndex(of: position.path).map { "第 \($0 + 1) 节" } ?? "阅读位置"
        let chapter = EPUBReaderChapterContext.title(in: navigationItems, path: position.path, confirmedPath: token.path)
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

import Foundation
import Testing
import TXTCore
@testable import ReaderDomain

actor ReaderTestGate {
    enum Failure: Error { case timeout }
    private var arrived = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        arrived = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func signal() { arrived = true }
    func wait() async throws {
        for _ in 0..<5000 {
            if arrived { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw Failure.timeout
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

func importForReader(_ text: String, fixture: DerivedBookFixture, service: LibraryService,
                     budget: DerivedBookBudget, observe: ImportStageObserver? = nil) async throws -> ImportReceipt {
    let source = fixture.root.appendingPathComponent("reader-" + UUID().uuidString + ".txt")
    try Data(text.utf8).write(to: source)
    let result = try await service.prepareReadingImport(url: source, ticket: UUID(), budget: budget, observe: observe)
    switch result {
    case .completed(let receipt): return receipt
    case .choose(let choice): return try await service.confirmReadingImport(ticket: choice.id, encoding: .utf8, budget: budget, observe: observe)
    }
}

func saveReaderAnchor(store: LibraryStore, book: LibraryBook, raw: Int, fraction: Double = 0.2) async throws -> ReadingAnchor {
    let start = try await store.beginReading(bookID: book.id, versionID: book.versionID)
    let anchor = ReadingAnchor(bookID: book.id, versionID: book.versionID, rawByteOffset: raw, lineFraction: fraction)
    try await store.finishReading(session: start.session, anchor: anchor, sequence: 1)
    return anchor
}

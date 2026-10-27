import Foundation
import TXTCore

/// One service-owned content result. Never stores a reading session, settings, or progress.
struct ProcessedBookCache {
    struct Entry: Sendable {
        let document: TXTDocument
        let chapters: [TXTChapter]?
    }
    let limit: Int
    private(set) var generation = UUID()
    private(set) var estimatedBytes = 0
    private var selectedBook: String?
    private var entry: Entry?

    init(limit: Int = 64 * 1024 * 1024) { self.limit = min(64 * 1024 * 1024, max(0, limit)) }

    mutating func invalidate() {
        generation = UUID(); entry = nil; estimatedBytes = 0; selectedBook = nil
    }

    mutating func begin(bookID: String? = nil) -> UUID {
        if bookID == nil || selectedBook != bookID { invalidate(); selectedBook = bookID }
        return generation
    }

    mutating func invalidate(ifCurrent token: UUID) {
        if generation == token { invalidate() }
    }

    mutating func lookup(_ book: LibraryBook, token: UUID) -> Entry? {
        guard token == generation else { return nil }
        guard let entry else { return nil }
        guard entry.document.documentID == book.id, entry.document.versionID == book.versionID,
              entry.document.encoding.rawValue == book.encodingRaw else { invalidate(); return nil }
        return entry
    }

    @discardableResult
    mutating func retain(_ document: TXTDocument, chapters: [TXTChapter]?, book: LibraryBook, token: UUID) -> Bool {
        guard token == generation, document.documentID == book.id, document.versionID == book.versionID,
              document.encoding.rawValue == book.encodingRaw else { return false }
        var estimate = document.estimatedRetainedBytes
        // Array capacity, value storage, and independently retained titles/IDs are all charged.
        if let chapters {
            let (storage, overflow) = chapters.capacity.multipliedReportingOverflow(by: MemoryLayout<TXTChapter>.stride)
            let (sum, sumOverflow) = estimate.addingReportingOverflow(storage)
            if overflow || sumOverflow { return false }
            estimate = sum
            for chapter in chapters {
                for text in [chapter.title ?? "", chapter.id, chapter.documentVersion] {
                    let (bytes, overflow) = text.utf8.count.multipliedReportingOverflow(by: 2)
                    let (next, sumOverflow) = estimate.addingReportingOverflow(bytes)
                    if overflow || sumOverflow { return false }
                    estimate = next
                }
            }
        }
        guard estimate <= limit else { entry = nil; estimatedBytes = 0; return false }
        selectedBook = book.id; entry = Entry(document: document, chapters: chapters); estimatedBytes = estimate
        return true
    }
}

struct ProcessingReuseStatistics: Sendable {
    var decodeCalls = 0
    var chapterCalls = 0
    var documentHits = 0
    var chapterHits = 0
    var retainedBytes = 0
}

import CryptoKit
import Foundation
import TXTCore

public struct OpenedBook: Sendable {
    public let book: LibraryBook
    public let document: TXTDocument
    public let chapters: [TXTChapter]
    public let reading: ReadingStart
}

public actor LibraryService {
    public nonisolated let store: LibraryStore
    private let processor = TXTProcessor()
    private struct Pending { let bytes: Data; let title: String; let encodings: [TXTEncoding] }
    private var pending: [UUID: Pending] = [:]
    private var cancelled: Set<UUID> = []

    public init(store: LibraryStore) { self.store = store }

    public static func openDefault() async throws -> LibraryService {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true).appendingPathComponent("YueJing", isDirectory: true)
        return LibraryService(store: try LibraryStore(root: folder))
    }

    public func prepareImport(url: URL, ticket: UUID) async throws -> ImportPreparation {
        try await store.beginImport(ticket)
        let staging = await store.stagingURL(ticket: ticket)
        var keepForChoice = false
        defer { if !keepForChoice { Self.removeStaging(staging) } }
        try check(ticket)
        guard url.isFileURL, url.pathExtension.lowercased() == "txt" else { throw LibraryError.notTXT }
        try Self.copyReadOnlySource(url, to: staging)
        try check(ticket)
        let data = try Data(contentsOf: staging, options: .mappedIfSafe)
        guard !data.isEmpty else { throw LibraryError.emptyFile }
        let identity = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = try await store.book(id: identity) {
            try check(ticket)
            return .completed(try await store.commitImport(ticket: ticket, proposed: existing))
        }
        let title = url.deletingPathExtension().lastPathComponent
        do {
            let document = try await processor.decode(data)
            guard document.utf16Count > 0 else { throw LibraryError.emptyFile }
            try check(ticket)
            return .completed(try await store.commitImport(ticket: ticket, proposed: Self.book(document, title: title)))
        } catch TXTError.ambiguousEncoding(let candidates) {
            let cards = try await previews(data, encodings: candidates.map(\.encoding))
            try check(ticket)
            pending[ticket] = Pending(bytes: data, title: title, encodings: candidates.map(\.encoding))
            keepForChoice = true
            return .choose(EncodingChoice(id: ticket, cards: cards))
        }
    }

    public func confirmImport(ticket: UUID, encoding: TXTEncoding) async throws -> ImportReceipt {
        guard let candidate = pending.removeValue(forKey: ticket) else { throw CancellationError() }
        let staging = await store.stagingURL(ticket: ticket)
        defer { Self.removeStaging(staging) }
        try check(ticket)
        guard candidate.encodings.contains(encoding) else { throw LibraryError.invalidEncoding }
        let document = try await processor.decode(candidate.bytes, using: encoding)
        guard document.utf16Count > 0 else { throw LibraryError.emptyFile }
        try check(ticket)
        return try await store.commitImport(ticket: ticket, proposed: Self.book(document, title: candidate.title))
    }

    public func cancelImport(_ ticket: UUID) async -> ImportCancellation {
        cancelled.insert(ticket)
        pending.removeValue(forKey: ticket)
        let result = await store.cancelImport(ticket)
        let url = await store.stagingURL(ticket: ticket)
        Self.removeStaging(url)
        return result
    }

    public func openBook(id: String) async throws -> OpenedBook {
        guard let book = try await store.book(id: id) else { throw LibraryError.missingBook }
        guard let encoding = book.encoding else { throw LibraryError.invalidEncoding }
        let url = try await store.fileURL(bookID: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryError.missingFile }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let document: TXTDocument
        do { document = try await processor.decode(data, using: encoding) }
        catch is CancellationError { throw CancellationError() }
        catch { throw LibraryError.changedFile }
        guard document.documentID == book.id, document.versionID == book.versionID else { throw LibraryError.changedFile }
        let chapters = try await processor.chapters(in: document)
        try Task.checkCancellation()
        let start = try await store.beginReading(bookID: id, versionID: document.versionID)
        do {
            try Task.checkCancellation()
            let valid = start.anchor.flatMap { anchor -> ReadingAnchor? in
                (try? document.offsets.utf16Offset(for: RawByteOffset(anchor.rawByteOffset))) != nil ? anchor : nil
            }
            let reading = ReadingStart(session: start.session, anchor: valid,
                                       ignoredIncompatibleProgress: start.ignoredIncompatibleProgress || (start.anchor != nil && valid == nil))
            return OpenedBook(book: book, document: document, chapters: chapters, reading: reading)
        } catch {
            try? await store.finishReading(session: start.session, anchor: nil, sequence: 1)
            throw error
        }
    }

    private func previews(_ data: Data, encodings: [TXTEncoding]) async throws -> [EncodingCard] {
        var documents: [TXTDocument] = []
        for encoding in encodings {
            try Task.checkCancellation()
            documents.append(try await processor.decode(data, using: encoding))
        }
        guard let reference = documents.first else { throw LibraryError.invalidEncoding }
        var firstDifference = data.count
        for other in documents.dropFirst() {
            var left = reference.text.unicodeScalars.makeIterator(), right = other.text.unicodeScalars.makeIterator()
            var position = 0, checked = 0
            while let scalar = left.next() {
                if checked % 1024 == 0 { try Task.checkCancellation() }; checked += 1
                guard scalar == right.next() else {
                    firstDifference = min(firstDifference, try reference.offsets.rawByteOffset(for: UTF16Offset(position)).value)
                    break
                }
                position += scalar.value > 0xFFFF ? 2 : 1
            }
        }
        // Use one original-byte interval for every card, including differences beyond the first 80 graphemes.
        var start = max(0, min(data.count, firstDifference) - 80)
        while start > 0 && !documents.allSatisfy({ (try? $0.offsets.utf16Offset(for: RawByteOffset(start))) != nil }) { start -= 1 }
        var end = min(data.count, start + 240)
        while end < data.count && !documents.allSatisfy({ (try? $0.offsets.utf16Offset(for: RawByteOffset(end))) != nil }) { end += 1 }
        let interval = try RawByteRange(location: RawByteOffset(start), length: end - start)
        return try documents.map { document in
            let range = try document.offsets.utf16Range(for: interval)
            let snippet = (document.text as NSString).substring(with: range.nsRange)
            return EncodingCard(encoding: document.encoding, text: snippet)
        }
    }

    private func check(_ ticket: UUID) throws {
        try Task.checkCancellation()
        if cancelled.contains(ticket) { throw CancellationError() }
    }

    private static func book(_ document: TXTDocument, title: String) -> LibraryBook {
        LibraryBook(id: document.documentID, title: title, encodingRaw: document.encoding.rawValue,
                    versionID: document.versionID, byteCount: document.originalBytes.count, utf16Count: document.utf16Count)
    }

    private static func copyReadOnlySource(_ source: URL, to destination: URL) throws {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        try Self.requireRegularFile(source)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?, copyError: Error?
        coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
            do {
                try Self.requireRegularFile(readable)
                try FileManager.default.copyItem(at: readable, to: destination)
                // copyItem must never leave an external symbolic link as the managed "copy".
                try Self.requireRegularFile(destination)
            }
            catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    private static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryError.notRegularFile }
    }

    private static func removeStaging(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
    }
}

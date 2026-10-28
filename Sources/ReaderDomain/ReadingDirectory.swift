import Foundation
import TXTCore

public enum ReadingDirectoryError: Error, Equatable, Sendable { case invalidRequest, incompleteMetadata }

public struct ReadingDirectoryPage: Sendable {
    public let start: Int
    public let total: Int
    public let currentIndex: Int?
    public let chapters: [TXTChapter]
    public init(start: Int, total: Int, currentIndex: Int?, chapters: [TXTChapter]) {
        self.start = start; self.total = total; self.currentIndex = currentIndex; self.chapters = chapters
    }
    public var rangeLabel: String {
        chapters.isEmpty ? "暂无章节" : "\(start + 1)–\(start + chapters.count) / \(total)"
    }
}

/// Read-only presentation query. O(log chapters) single-entry probes, then <=32 entries.
public enum ReadingDirectory {
    public static let pageSize = 32
    public typealias Loader = @Sendable (Int, Int) async throws -> [TXTChapter]
    public static func locate(anchor: ReadingAnchor, chapterCount: Int, byteCount: Int,
                              load: Loader) async throws -> ReadingDirectoryPage {
        guard chapterCount >= 0, byteCount >= 0, anchor.rawByteOffset >= 0,
              anchor.rawByteOffset <= byteCount else { throw ReadingDirectoryError.invalidRequest }
        try Task.checkCancellation()
        if chapterCount == 0 { return ReadingDirectoryPage(start: 0, total: 0, currentIndex: nil, chapters: []) }
        var low = 0, high = chapterCount
        while low < high {
            try Task.checkCancellation()
            let middle = low + (high - low) / 2
            let values = try await load(middle, 1)
            try Task.checkCancellation()
            guard values.count == 1, values[0].documentVersion == anchor.versionID else {
                throw ReadingDirectoryError.incompleteMetadata
            }
            if values[0].rawByteRange.location.value <= anchor.rawByteOffset { low = middle + 1 }
            else { high = middle }
        }
        guard low > 0 else { throw ReadingDirectoryError.invalidRequest }
        let current = low - 1, start = current / pageSize * pageSize
        let result = try await page(start: start, total: chapterCount, currentIndex: current,
                                    documentVersion: anchor.versionID, load: load)
        let selected = result.chapters[current - start]
        guard selected.documentVersion == anchor.versionID,
              selected.rawByteRange.location.value <= anchor.rawByteOffset,
              anchor.rawByteOffset < selected.rawByteRange.end.value ||
                (current == chapterCount - 1 && anchor.rawByteOffset == byteCount &&
                 selected.rawByteRange.end.value == byteCount) else { throw ReadingDirectoryError.invalidRequest }
        return result
    }
    public static func page(start: Int, total: Int, currentIndex: Int?, documentVersion: String,
                            load: Loader) async throws -> ReadingDirectoryPage {
        guard total >= 0, start >= 0, (total == 0 ? start == 0 : start < total),
              start % pageSize == 0 else { throw ReadingDirectoryError.invalidRequest }
        try Task.checkCancellation()
        if total == 0 { return ReadingDirectoryPage(start: 0, total: 0, currentIndex: nil, chapters: []) }
        let count = min(pageSize, total - start)
        let values = try await load(start, count)
        try Task.checkCancellation()
        guard values.count == count, values.allSatisfy({
            $0.documentVersion == documentVersion && $0.rawByteRange.length > 0 && $0.utf16Range.length > 0
        }) else { throw ReadingDirectoryError.incompleteMetadata }
        return ReadingDirectoryPage(start: start, total: total, currentIndex: currentIndex, chapters: values)
    }
}

public enum DirectoryRequest: Equatable, Sendable { case current(ReadingAnchor), page(Int) }
public struct DirectoryReveal: Equatable, Sendable {
    public let id: UUID
    public let chapterID: String
}

/// Consumed by the App directory model; failed/late requests preserve the last valid page.
public struct DirectoryPresentation: Sendable {
    public private(set) var page: ReadingDirectoryPage?
    public private(set) var message: String?
    public private(set) var requestID: UUID?
    public private(set) var reveal: DirectoryReveal?
    public private(set) var presentationID: UUID?
    private var target: DirectoryRequest?
    public init() {}
    public mutating func present(_ id: UUID) {
        if presentationID != id { cancel(); presentationID = id }
    }
    public func ownsPresentation(_ id: UUID) -> Bool { presentationID == id }
    @discardableResult public mutating func dismiss(_ id: UUID) -> Bool {
        guard presentationID == id else { return false }
        cancel(); presentationID = nil; return true
    }
    public var loading: Bool { requestID != nil }
    public mutating func begin(_ value: DirectoryRequest) -> UUID? {
        if requestID != nil, target == value { return nil }
        if requestID == nil, message == nil, case .page(let start) = value, page?.start == start { return nil }
        let id = UUID(); requestID = id; target = value; message = nil; reveal = nil; return id
    }
    @discardableResult public mutating func apply(_ value: ReadingDirectoryPage, request id: UUID,
                                                  revealCurrent: Bool = false, locationStillCurrent: Bool = true) -> Bool {
        guard requestID == id else { return false }
        page = locationStillCurrent ? value
            : ReadingDirectoryPage(start: value.start, total: value.total, currentIndex: nil, chapters: value.chapters)
        message = nil; requestID = nil; target = nil
        if revealCurrent, locationStillCurrent, let current = value.currentIndex,
           value.chapters.indices.contains(current - value.start) {
            reveal = DirectoryReveal(id: id, chapterID: value.chapters[current - value.start].id)
        }
        return true
    }
    @discardableResult public mutating func fail(_ text: String, request id: UUID) -> Bool {
        guard requestID == id else { return false }
        message = text; requestID = nil; target = nil; return true
    }
    public mutating func clearCurrent() {
        if let page { self.page = ReadingDirectoryPage(start: page.start, total: page.total, currentIndex: nil, chapters: page.chapters) }
        reveal = nil
    }
    public mutating func cancel() { requestID = nil; target = nil; reveal = nil }
}

extension OpenedReader {
    public func directory(around anchor: ReadingAnchor) async throws -> ReadingDirectoryPage {
        guard anchor.bookID == reading.session.bookID, anchor.versionID == reading.session.versionID else {
            throw LibraryError.invalidAnchor
        }
        _ = try await source.utf16Offset(for: RawByteOffset(anchor.rawByteOffset))
        return try await ReadingDirectory.locate(anchor: anchor, chapterCount: source.metadata.chapterCount,
            byteCount: source.metadata.byteCount, load: { [self] in try await chapterPage(start: $0, limit: $1) })
    }
    public func directoryPage(start: Int, currentIndex: Int?) async throws -> ReadingDirectoryPage {
        try await ReadingDirectory.page(start: start, total: source.metadata.chapterCount,
            currentIndex: currentIndex, documentVersion: reading.session.versionID,
            load: { [self] in try await chapterPage(start: $0, limit: $1) })
    }
}

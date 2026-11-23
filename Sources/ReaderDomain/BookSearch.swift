import Foundation

public enum BookSearchLocation: Equatable, Sendable {
    case txt(ReadingAnchor)
    case epub(EPUBReadingPosition)
}

public struct BookSearchHit: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let chapterTitle: String
    public let snippet: String
    public let location: BookSearchLocation
    public init(chapterTitle: String, snippet: String, location: BookSearchLocation) {
        self.chapterTitle = chapterTitle; self.snippet = snippet; self.location = location
    }
}

public struct BookSearchResults: Sendable {
    public let hits: [BookSearchHit]
    public let hasMore: Bool
    public init(hits: [BookSearchHit], hasMore: Bool) { self.hits = hits; self.hasMore = hasMore }
}

enum BookSearchMatcher {
    static let limit = 100
    enum QueryError: Error { case empty, tooLong }
    static func query(_ input: String) throws -> String {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw QueryError.empty }
        guard q.utf16.count <= 128 else { throw QueryError.tooLong }
        return q
    }

    /// Literal matches, always in the original UTF-16 coordinate space.
    static func matches(in text: String, query: String, limit: Int) throws -> [(offset: Int, snippet: String)] {
        try Task.checkCancellation()
        guard !query.isEmpty, !text.isEmpty, limit > 0 else { return [] }
        let source = text as NSString
        var offset = 0, hits: [(offset: Int, snippet: String)] = []
        while offset < source.length, hits.count < limit {
            try Task.checkCancellation()
            let m = source.range(of: query, options: .literal, range: NSRange(location: offset, length: source.length - offset))
            guard m.location != NSNotFound else { break }
            guard source.rangeOfComposedCharacterSequences(for: m) == m else {
                offset = NSMaxRange(source.rangeOfComposedCharacterSequence(at: m.location)); continue
            }
            offset = NSMaxRange(m)
            var left = max(0, m.location - 30), right = min(source.length, offset + 42)
            if left > 0 {
                let edge = source.rangeOfComposedCharacterSequence(at: left)
                if edge.location < left { left = NSMaxRange(edge) }
            }
            if right < source.length { right = source.rangeOfComposedCharacterSequence(at: right).location }
            let excerpt = source.substring(with: NSRange(location: left, length: right - left))
            hits.append((m.location, (left > 0 ? "…" : "") + excerpt + (right < source.length ? "…" : "")))
        }
        return hits
    }
}

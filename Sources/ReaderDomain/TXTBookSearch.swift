import Foundation
import TXTCore

extension OpenedReader {
    /// Scan the normalized reading stream, not the original file or a concatenation of chapters.
    /// At most one read window plus a query-sized unresolved suffix is passed to the matcher.
    func scanTXT(_ query: String) async throws -> BookSearchResults {
        let units = query.utf16.count, total = source.metadata.utf16Count
        let span = max(4096, units)
        var cursor = 0, carry = "", hits: [BookSearchHit] = []
        var directoryPage: ReadingDirectoryPage?
        while cursor < total {
            try Task.checkCancellation()
            let probe = cursor + min(span, total - cursor)
            let end = try await source.composedStart(at: probe)
            if end == cursor {
                // A single grapheme longer than even the query cannot participate. Find its
                // real end in the persisted boundary index without materializing the cluster.
                var low = probe + 1, high = total
                while low < high {
                    let mid = low + (high - low) / 2
                    if try await source.composedStart(at: mid) == cursor { low = mid + 1 }
                    else { high = mid }
                }
                cursor = low; carry = ""; continue
            }
            let range = try UTF16Range(location: UTF16Offset(cursor), length: end - cursor)
            let fragment = try await source.text(in: range)
            let base = cursor - carry.utf16.count, text = carry + fragment.text
            let matches = try BookSearchMatcher.matches(in: text, query: query,
                limit: BookSearchMatcher.limit + 1 - hits.count)
            for match in matches {
                try Task.checkCancellation()
                if hits.count == BookSearchMatcher.limit { return BookSearchResults(hits: hits, hasMore: true) }
                let offset = base + match.offset
                let raw = try await source.rawByteOffset(for: UTF16Offset(offset))
                let anchor = ReadingAnchor(bookID: book.id, versionID: book.versionID, rawByteOffset: raw.value)
                func chapter(in page: ReadingDirectoryPage?) -> TXTChapter? {
                    page?.chapters.first { $0.utf16Range.location.value <= offset && offset < $0.utf16Range.end.value }
                }
                if chapter(in: directoryPage) == nil { directoryPage = try await directory(around: anchor) }
                guard let current = chapter(in: directoryPage) else { throw ReadingDirectoryError.incompleteMetadata }
                hits.append(BookSearchHit(chapterTitle: current.title ?? "正文", snippet: match.snippet, location: .txt(anchor)))
            }
            // Discard completed candidates, including the entirety of the last non-overlapping
            // match. Round the first undecided position UP so a suffix never splits a grapheme.
            let ns = text as NSString
            let consumed = matches.last.map { $0.offset + units } ?? 0
            var suffix = max(consumed, ns.length - units + 1)
            if suffix < ns.length {
                let cluster = ns.rangeOfComposedCharacterSequence(at: suffix)
                if cluster.location != suffix { suffix = NSMaxRange(cluster) }
            }
            carry = ns.substring(from: suffix); cursor = end
        }
        return BookSearchResults(hits: hits, hasMore: false)
    }
}

import Foundation
import TXTCore

/// Sequential pull source for one playback. It holds one small normalized-text window,
/// not a viewport, chapter list or decoded document. Reading never commits progress.
public actor TXTSpeechCursor {
    public struct Fragment: Sendable {
        public let text: String
        public let anchor: ReadingAnchor
    }

    private let source: DerivedBookSource
    private let origin: ReadingAnchor
    private var offset: Int?
    private var remainder: Substring = ""
    private var reading = false
    static let windowUnits = 256

    public init(source: DerivedBookSource, origin: ReadingAnchor) {
        self.source = source
        self.origin = origin
    }

    public func next() async throws -> Fragment? {
        try Task.checkCancellation()
        guard !reading else { throw CancellationError() }
        reading = true
        defer { reading = false }
        let metadata = source.metadata
        guard origin.bookID == metadata.bookID, origin.versionID == metadata.versionID,
              origin.unit == "raw-byte-v1", origin.rawByteOffset >= metadata.bomByteCount,
              origin.rawByteOffset < metadata.byteCount else { throw LibraryError.invalidAnchor }
        let start: Int
        if let offset { start = offset }
        else { start = try await source.utf16Offset(for: RawByteOffset(origin.rawByteOffset)).value }
        guard start < metadata.utf16Count else { return nil }
        if remainder.isEmpty {
            let probe = start + min(Self.windowUnits, metadata.utf16Count - start)
            var end = try await source.composedStart(at: probe)
            if end <= start {
                // An arbitrarily large grapheme cannot fit. Stream its scalars without
                // skipping it, materializing it whole, or bisecting a surrogate pair.
                end = probe
                do { _ = try await source.rawByteOffset(for: UTF16Offset(end)) }
                catch TXTError.invalidUTF16Boundary { end -= 1 }
            }
            let range = try UTF16Range(location: UTF16Offset(start), length: end - start)
            let page = try await source.text(in: range)
            remainder = page.text[...]
        }
        let end = remainder.firstIndex(where: { "。！？.!?\n\u{2028}\u{2029}".contains($0) })
            .map { remainder.index(after: $0) } ?? remainder.endIndex
        let text = String(remainder[..<end])
        let raw = try await source.rawByteOffset(for: UTF16Offset(start))
        try Task.checkCancellation()
        offset = start + text.utf16.count
        remainder = remainder[end...]
        return Fragment(text: text, anchor: ReadingAnchor(bookID: metadata.bookID,
            versionID: metadata.versionID, rawByteOffset: raw.value))
    }
}

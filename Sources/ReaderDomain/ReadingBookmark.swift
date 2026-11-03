import Foundation
import GRDB

public struct ReadingBookmark: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "bookmarks"
    public let id: String
    public let bookID: String
    public let versionID: String
    public let unit: String
    public let rawByteOffset: Int
    public let createdAt: Double
    public let chapterTitleSnapshot: String?

    public init(id: String, bookID: String, versionID: String, unit: String = "raw-byte-v1",
                rawByteOffset: Int, createdAt: Double, chapterTitleSnapshot: String? = nil) {
        self.id = id; self.bookID = bookID; self.versionID = versionID; self.unit = unit
        self.rawByteOffset = rawByteOffset; self.createdAt = createdAt
        self.chapterTitleSnapshot = chapterTitleSnapshot
    }

    /// Structural compatibility only. OpenedReader additionally proves exact mapping and grapheme boundaries.
    public func anchor(matching book: LibraryBook) -> ReadingAnchor? {
        guard bookID == book.id, versionID == book.versionID, unit == "raw-byte-v1",
              rawByteOffset >= 0, rawByteOffset < book.byteCount else { return nil }
        return ReadingAnchor(bookID: bookID, versionID: versionID, rawByteOffset: rawByteOffset, lineFraction: 0)
    }
}

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
    public let customName: String?

    public var displayTitle: String { customName ?? chapterTitleSnapshot ?? "阅读位置" }

    public enum NameValidationError: Error, Equatable, Sendable {
        case tooLong
        case invalidCharacters
    }

    public static func validatedCustomName(_ input: String) throws -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // Unicode controls (Cc), not format characters (Cf): emoji ZWJ must remain valid.
        guard !name.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0)
        }) else { throw NameValidationError.invalidCharacters }
        guard name.count <= 80 else { throw NameValidationError.tooLong }
        return name
    }

    // Display metadata may change while a strict position lookup is suspended.
    func hasSamePosition(as other: ReadingBookmark) -> Bool {
        id == other.id && bookID == other.bookID && versionID == other.versionID &&
            unit == other.unit && rawByteOffset == other.rawByteOffset
    }

    public init(id: String, bookID: String, versionID: String, unit: String = "raw-byte-v1",
                rawByteOffset: Int, createdAt: Double, chapterTitleSnapshot: String? = nil, customName: String? = nil) {
        self.id = id; self.bookID = bookID; self.versionID = versionID; self.unit = unit
        self.rawByteOffset = rawByteOffset; self.createdAt = createdAt
        self.chapterTitleSnapshot = chapterTitleSnapshot
        self.customName = customName
    }

    /// Structural compatibility only. OpenedReader additionally proves exact mapping and grapheme boundaries.
    public func anchor(matching book: LibraryBook) -> ReadingAnchor? {
        guard bookID == book.id, versionID == book.versionID, unit == "raw-byte-v1",
              rawByteOffset >= 0, rawByteOffset < book.byteCount else { return nil }
        return ReadingAnchor(bookID: bookID, versionID: versionID, rawByteOffset: rawByteOffset, lineFraction: 0)
    }
}

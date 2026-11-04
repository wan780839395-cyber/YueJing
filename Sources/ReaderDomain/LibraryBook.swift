import Foundation
import GRDB
import TXTCore

public enum LibraryBookFormat: String, Codable, Sendable { case txt, epub }

public struct LibraryBook: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "books"
    public let id: String
    public let title: String
    public let encodingRaw: String
    public let versionID: String
    public let byteCount: Int
    public let utf16Count: Int
    public let addedAt: Double
    public var lastReadAt: Double?
    public var activeSession: String?
    /// EPUB uses a non-text discriminator; existing Codable/SQL columns remain byte-for-byte compatible.
    /// The v6 bookFormats record is independently checked before an EPUB session is granted.
    public var format: LibraryBookFormat { encodingRaw == "epub" ? .epub : .txt }

    public var encoding: TXTEncoding? { TXTEncoding(rawValue: encodingRaw) }

    public init(id: String, title: String, encodingRaw: String, versionID: String,
                byteCount: Int, utf16Count: Int, addedAt: Double = Date().timeIntervalSince1970,
                format: LibraryBookFormat = .txt) {
        self.id = id; self.title = title; self.encodingRaw = format == .epub ? "epub" : encodingRaw; self.versionID = versionID
        self.byteCount = byteCount; self.utf16Count = utf16Count; self.addedAt = addedAt
    }
}

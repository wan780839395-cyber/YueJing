import Foundation
import GRDB
import TXTCore

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

    public var encoding: TXTEncoding? { TXTEncoding(rawValue: encodingRaw) }

    public init(id: String, title: String, encodingRaw: String, versionID: String,
                byteCount: Int, utf16Count: Int, addedAt: Double = Date().timeIntervalSince1970) {
        self.id = id; self.title = title; self.encodingRaw = encodingRaw; self.versionID = versionID
        self.byteCount = byteCount; self.utf16Count = utf16Count; self.addedAt = addedAt
    }
}

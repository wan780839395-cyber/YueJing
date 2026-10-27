import Foundation

public struct ReadingAnchor: Sendable, Equatable {
    public let bookID: String
    public let versionID: String
    public let rawByteOffset: Int
    public let lineFraction: Double
    public let unit = "raw-byte-v1"

    public init(bookID: String, versionID: String, rawByteOffset: Int, lineFraction: Double = 0) {
        self.bookID = bookID; self.versionID = versionID; self.rawByteOffset = rawByteOffset
        self.lineFraction = lineFraction.isFinite ? min(1, max(0, lineFraction)) : 0
    }
}

public struct ReadingSession: Sendable, Equatable {
    public let id: String
    public let bookID: String
    public let versionID: String
}

public struct ReadingStart: Sendable {
    public let session: ReadingSession
    public let anchor: ReadingAnchor?
    public let ignoredIncompatibleProgress: Bool
}

import Foundation

public struct EPUBBookmark: Identifiable, Sendable, Equatable {
    public let id: String
    public let position: EPUBReadingPosition
    public let title: String
    public let createdAt: Date

    public init(id: String, position: EPUBReadingPosition, title: String, createdAt: Date) {
        self.id = id
        self.position = position
        self.title = title
        self.createdAt = createdAt
    }
}

public struct ReadingBookmarkPage: Sendable {
    public static let pageSize = 32
    public let start: Int
    public let total: Int
    public let items: [ReadingBookmark]

    public init(start: Int, total: Int, items: [ReadingBookmark]) {
        self.start = start; self.total = total; self.items = items
    }
    public var hasPrevious: Bool { start > 0 }
    public var hasNext: Bool { start < total && items.count < total - start }
}

import Foundation
import TXTCore

public struct ReadingLine: Sendable {
    public let range: UTF16Range
    public let rawByteStart: Int
    public let text: String
    public let top: Double
    public let baseline: Double
    public let height: Double
}

public struct ReadingSlice: Identifiable, Sendable {
    public var id: Int { range.location.value }
    public let range: UTF16Range
    public let lines: [ReadingLine]
    public let height: Double
}

public struct ReadingWindow: Identifiable, Sendable {
    public let id: UUID
    public let anchor: ReadingAnchor
    public let targetUTF16: Int
    public let preferences: ReaderPreferences
    public let bodyFont: TXTBodyFont?
    public let slices: [ReadingSlice]
    public let hasPrevious: Bool
    public let hasNext: Bool

    init(id: UUID, anchor: ReadingAnchor, targetUTF16: Int, preferences: ReaderPreferences,
         bodyFont: TXTBodyFont? = nil, slices: [ReadingSlice], hasPrevious: Bool, hasNext: Bool) {
        self.id = id; self.anchor = anchor; self.targetUTF16 = targetUTF16
        self.preferences = preferences; self.bodyFont = bodyFont; self.slices = slices
        self.hasPrevious = hasPrevious; self.hasNext = hasNext
    }
}

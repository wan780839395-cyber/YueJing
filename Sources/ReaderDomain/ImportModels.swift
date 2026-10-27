import Foundation
import TXTCore

public struct ImportReceipt: Sendable {
    public let book: LibraryBook
    public let duplicate: Bool
}

public struct EncodingChoice: Identifiable, Sendable {
    public let id: UUID
    public let cards: [EncodingCard]
}

public struct EncodingCard: Identifiable, Sendable {
    public var id: String { encoding.rawValue }
    public let encoding: TXTEncoding
    public let text: String
    public var title: String {
        switch encoding {
        case .utf8: "通用文本（UTF-8）"
        case .utf16LE: "Unicode 文本（小端）"
        case .utf16BE: "Unicode 文本（大端）"
        case .gb18030: "中文扩展文本（GB18030）"
        case .gbk: "常见中文文本（GBK）"
        }
    }
}

public enum ImportPreparation: Sendable {
    case completed(ImportReceipt)
    case choose(EncodingChoice)
}

public enum ImportCancellation: Sendable {
    case cancelled
    case alreadyCommitted(ImportReceipt)
}

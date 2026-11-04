import Foundation

public enum EPUBError: Error, LocalizedError, Sendable, Equatable {
    case invalidArchive
    case unsafePath
    case limitExceeded
    case invalidPackage
    case unsupportedContent
    case corruptResource
    case invalidPosition
    case staleSession

    public var errorDescription: String? {
        switch self {
        case .invalidArchive:
            "无法读取 EPUB 归档，文件可能损坏或格式无效。"
        case .unsafePath:
            "EPUB 包含不安全的资源路径，已拒绝导入。"
        case .limitExceeded:
            "EPUB 文件大小或条目数量超出安全限制。"
        case .invalidPackage:
            "EPUB 出版物结构或目录元数据不完整，无法打开。"
        case .unsupportedContent:
            "该 EPUB 含有加密、脚本、固定版式或当前版本暂不支持的内容。"
        case .corruptResource:
            "EPUB 正文或插图资源校验未通过，文件可能已损坏。"
        case .invalidPosition:
            "EPUB 阅读位置与当前版本或章节内容不匹配。"
        case .staleSession:
            "EPUB 阅读会话已结束，旧位置未写入。"
        }
    }
}

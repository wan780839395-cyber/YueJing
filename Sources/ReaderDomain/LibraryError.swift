import Foundation

public enum LibraryError: Error, LocalizedError, Sendable {
    case notTXT, notRegularFile, emptyFile, missingFile, changedFile, missingBook, invalidEncoding, invalidAnchor, closedSession
    case layoutCannotAdvance

    public var errorDescription: String? {
        switch self {
        case .notTXT: "请选择 TXT 文本文件。"
        case .notRegularFile: "请选择普通 TXT 文件；暂不支持目录或符号链接。"
        case .emptyFile: "文件没有正文，未加入书架。"
        case .missingFile: "书籍副本已缺失。请重新导入同一原文件，原阅读位置会保留。"
        case .changedFile: "检测到书籍副本内容已变化，暂不读取。原书架记录和阅读位置已保留，未自动覆盖副本。"
        case .missingBook: "书架中已找不到这本书，请重新导入。"
        case .invalidEncoding: "这本书记录的文字编码无法识别，请重新导入。"
        case .invalidAnchor: "阅读位置与当前书籍或内容版本不匹配。"
        case .closedSession: "阅读会话已结束，旧位置没有写入。"
        case .layoutCannotAdvance: "这段文字包含过长的字符组合，当前无法排版。原文件和阅读位置未改变。"
        }
    }
}

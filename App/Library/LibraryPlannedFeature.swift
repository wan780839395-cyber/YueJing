import Foundation

/// Static UI destinations only. These values are not persisted book formats.
enum LibraryPlannedFeature: String, Identifiable, Sendable {
    case epub
    case cover
    case comics
    case aiStory

    static let modules: [LibraryPlannedFeature] = [.comics, .aiStory]
    var id: String { rawValue }

    var title: String {
        switch self {
        case .epub: return "EPUB 格式"
        case .cover: return "封面展示"
        case .comics: return "漫画聚合"
        case .aiStory: return "AI 故事"
        }
    }

    var symbol: String {
        switch self {
        case .epub: return "book.closed"
        case .cover: return "photo"
        case .comics: return "square.stack"
        case .aiStory: return "sparkles"
        }
    }

    var summary: String {
        switch self {
        case .epub:
            return "仅预留格式说明与书架布局。当前导入和阅读仍只接入 TXT，这里不打开或解析 EPUB 文件。"
        case .cover:
            return "书架上的单字页是文字封面占位，不是从书籍提取的图片。本批不读取、解码、下载或缓存封面。"
        case .comics:
            return "入口与返回路径已预留，当前不提供漫画内容源、抓取、下载或漫画阅读器。"
        case .aiStory:
            return "仅预留独立故事模块的位置。未接入模型调用、服务连接、账户或额度，也不会自动发起请求。"
        }
    }

    var notes: [String] {
        switch self {
        case .epub:
            return ["与 TXT 共用书架的布局位置已预留。", "真实解析、目录和阅读位置能力需另行实现。", "实际导入继续使用现有 TXT 流程，不扩大文件准入。"]
        case .cover:
            return ["书名始终是主要信息，长标题完整换行。", "没有封面时保留文字页，不出现破图。", "真实图片读取、缓存和加载策略尚未接入。"]
        case .comics:
            return ["后续独立组织漫画内容，不混入小说目录。", "不内置或自动连接内容源。", "聚合规则与阅读方式待后续需求明确。"]
        case .aiStory:
            return ["普通阅读不依赖 AI。", "后续能力由用户主动配置并触发。", "故事结构、服务连接与保存方式尚未实现。"]
        }
    }
}

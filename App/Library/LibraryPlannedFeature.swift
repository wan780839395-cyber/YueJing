import Foundation

/// Static UI destinations only. These values are not persisted book formats.
enum LibraryPlannedFeature: String, Identifiable, Sendable {
    case epub
    case cover
    case comics
    case aiStory

    static let modules: [LibraryPlannedFeature] = [.comics, .aiStory]
    var id: String { rawValue }

    var isImplemented: Bool {
        switch self {
        case .epub, .cover: return true
        case .comics, .aiStory: return false
        }
    }

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
            return "已支持本地非 DRM、可重排 EPUB 2/3 导入与 WebKit 阅读（不静默转换为 TXT），支持 spine 阅读顺序、NCX/nav 目录、跨章与锚点跳转、字号/行距/主题设置及进度恢复。"
        case .cover:
            return "已支持从 EPUB OPF 声明的本地 JPEG/PNG 封面提取限尺寸缩略图（最长边不超过 512px），并在书架按需加载展示。"
        case .comics:
            return "入口与返回路径已预留，当前不提供漫画内容源、抓取、下载或漫画阅读器。"
        case .aiStory:
            return "仅预留独立故事模块的位置。未接入模型调用、服务连接、账户或额度，也不会自动发起请求。"
        }
    }

    var notes: [String] {
        switch self {
        case .epub:
            return [
                "第一版支持受支持 XHTML 正文、常见段落/标题/强调/列表及本地 JPEG/PNG 插图；不宣称完整 EPUB 规范或逐像素还原任意出版物 CSS。",
                "不支持固定版式（fixed-layout）、DRM/加密资源、脚本、表单、联网资源、音视频及 EPUB 书签；不破解 DRM。",
                "SVG、复杂 MathML 及嵌入字体不在本批保证范围，遇必须依赖这些能力的内容会明确拒绝并提示，不假称完整呈现。"
            ]
        case .cover:
            return [
                "书名始终是主要信息，长标题完整换行。",
                "TXT 书籍、未声明封面或可选封面损坏的 EPUB 自动回退文字封面占位，不阻断有效正文阅读。",
                "封面解码前检查像素与字节预算，限制缓存容量，不联网下载封面。"
            ]
        case .comics:
            return ["后续独立组织漫画内容，不混入小说目录。", "不内置或自动连接内容源。", "聚合规则与阅读方式待后续需求明确。"]
        case .aiStory:
            return ["普通阅读不依赖 AI。", "后续能力由用户主动配置并触发。", "故事结构、服务连接与保存方式尚未实现。"]
        }
    }
}

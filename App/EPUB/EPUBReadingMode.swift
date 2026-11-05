import Foundation

/// EPUB-only preference; does not change TXT preferences or persisted text anchors.
enum EPUBReadingMode: String, CaseIterable, Sendable {
    case scroll
    case paged

    static let defaultsKey = "epub.readingMode.v1"

    var title: String {
        switch self {
        case .scroll: "上下滚动"
        case .paged: "左右分页"
        }
    }
}

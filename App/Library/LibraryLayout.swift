import Foundation

/// Persist only the chosen UI layout, never a tab, drawer or presentation identity.
enum LibraryLayout: String, CaseIterable, Sendable {
    case direct = "a"
    case tabs = "b"
    case sidebar = "c"

    static let storageKey = "dev.yuejing.ui.libraryLayout.v1"
    static let defaultLayout: LibraryLayout = .tabs
    static func restored(from rawValue: String) -> LibraryLayout {
        LibraryLayout(rawValue: rawValue) ?? defaultLayout
    }
    var title: String {
        switch self {
        case .direct: "A · 书架直达"
        case .tabs: "B · 底部分区"
        case .sidebar: "C · 侧栏工作区"
        }
    }
}

enum LibrarySection: String, CaseIterable, Sendable {
    case shelf, explore, settings
    var title: String {
        switch self { case .shelf: "书架"; case .explore: "探索"; case .settings: "设置" }
    }
    var symbol: String {
        switch self { case .shelf: "books.vertical"; case .explore: "square.grid.2x2"; case .settings: "slider.horizontal.3" }
    }
}

enum LibraryInformationPage: Sendable { case diagnostics, license }
struct LibraryInformationRoute: Identifiable, Sendable {
    let id = UUID()
    let page: LibraryInformationPage
}

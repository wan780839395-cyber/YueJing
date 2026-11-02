import Foundation

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

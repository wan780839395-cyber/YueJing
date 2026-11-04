import Foundation
import ReaderDomain
import SwiftUI

/// Presentation only: the existing caller owns book identity and the open action.
@MainActor
struct LibraryBookRow: View {
    let book: LibraryBook
    let appearance: LibraryAppearance
    var coverLoader: (@Sendable (String) async -> Data?)? = nil
    @State private var hasEmbeddedCover = false

    private var formatBadge: String {
        switch book.format {
        case .txt:
            return "TXT"
        case .epub:
            let cached = LibraryCoverMemoryCache.shared.image(for: book.id + ":" + book.versionID) != nil
            return (hasEmbeddedCover || cached) ? "EPUB · 封面" : "EPUB · 文字占位"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            LibraryBookCoverView(
                book: book,
                appearance: appearance,
                coverLoader: coverLoader,
                onCoverResolved: { image in
                    hasEmbeddedCover = (image != nil)
                }
            )
            VStack(alignment: .leading, spacing: 7) {
                Text(book.title)
                    .font(LibraryAppearance.bookTitleFont)
                    .foregroundStyle(appearance.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = book.lastReadAt {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(formatBadge)
                            Text("最近阅读")
                            Text(Date(timeIntervalSince1970: date), style: .date)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(formatBadge) · 最近阅读")
                            Text(Date(timeIntervalSince1970: date), style: .date)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption).foregroundStyle(appearance.secondary)
                } else {
                    Text("\(formatBadge) · 新加入 · 尚未阅读")
                        .font(.caption).foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: LibraryAppearance.minimumControlHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

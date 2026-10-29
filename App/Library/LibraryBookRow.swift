import Foundation
import ReaderDomain
import SwiftUI

/// Presentation only: the existing caller owns book identity and the open action.
@MainActor
struct LibraryBookRow: View {
    let book: LibraryBook
    let appearance: LibraryAppearance

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            LibraryCoverPlaceholder(title: book.title, appearance: appearance)
            VStack(alignment: .leading, spacing: 7) {
                Text(book.title)
                    .font(LibraryAppearance.bookTitleFont)
                    .foregroundStyle(appearance.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = book.lastReadAt {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("TXT")
                            Text("最近阅读")
                            Text(Date(timeIntervalSince1970: date), style: .date)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TXT · 最近阅读")
                            Text(Date(timeIntervalSince1970: date), style: .date)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption).foregroundStyle(appearance.secondary)
                } else {
                    Text("TXT · 新加入 · 尚未阅读")
                        .font(.caption).foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: LibraryAppearance.minimumControlHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

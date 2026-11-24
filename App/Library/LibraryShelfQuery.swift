import Foundation
import ReaderDomain

/// Presentation state only. Filtering never changes the shelf order or a reader's location.
struct LibraryShelfQuery {
    var title = ""
    var format: LibraryShelfFormatFilter = .all

    var isFiltering: Bool { format != .all || !title.isEmpty }

    func results(in books: [LibraryBook]) -> [LibraryBook] {
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return books.filter { book in
            (format == .all || format.rawValue == book.format.rawValue) &&
                (needle.isEmpty || book.title.localizedStandardContains(needle))
        }
    }
}

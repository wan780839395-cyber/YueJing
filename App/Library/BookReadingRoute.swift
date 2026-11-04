import Foundation
import ReaderDomain

/// Single controlled presentation route wrapping existing TXT ReaderPresentation or EPUBReaderViewModel.
@MainActor
struct BookReadingRoute: Identifiable {
    enum Content {
        case txt(ReaderPresentation)
        case epub(EPUBReaderViewModel)
    }

    let id: UUID
    let bookID: String
    let format: LibraryBookFormat
    let content: Content

    init(txt presentation: ReaderPresentation, bookID: String) {
        self.id = presentation.id
        self.bookID = bookID
        self.format = .txt
        self.content = .txt(presentation)
    }

    init(epub model: EPUBReaderViewModel, id: UUID = UUID(), bookID: String) {
        self.id = id
        self.bookID = bookID
        self.format = .epub
        self.content = .epub(model)
    }
}

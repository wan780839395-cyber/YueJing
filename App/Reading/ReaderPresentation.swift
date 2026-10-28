import Foundation
import ReaderDomain

/// A route owns one model. A later open always receives a new identity and session.
@MainActor
struct ReaderPresentation: Identifiable {
    let id = UUID()
    let model: ReaderViewModel

    init(bookID: String, service: LibraryService) {
        model = ReaderViewModel(bookID: bookID, service: service)
    }
}

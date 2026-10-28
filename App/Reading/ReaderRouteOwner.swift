import Combine
import Foundation
import ReaderDomain

@MainActor
final class ReaderRouteOwner: ObservableObject {
    @Published private(set) var presentation: ReaderPresentation?

    func open(bookID: String, service: LibraryService) {
        guard presentation == nil else { return }
        presentation = ReaderPresentation(bookID: bookID, service: service)
    }

    /// Called only after this route's explicit exit has saved successfully.
    func finishExit(_ id: UUID) {
        guard presentation?.id == id else { return }
        presentation = nil
    }

    /// A presentation binding being cleared is an actual route end, unlike view disappearance.
    func presentationEnded(_ ended: ReaderPresentation) {
        if presentation?.id == ended.id { presentation = nil }
        // Capture the ended owner. This completion never consults or clears a newer route.
        Task { _ = await ended.model.close() }
    }
}

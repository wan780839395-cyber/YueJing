import Combine
import Foundation
import ReaderDomain

/// Single reading presentation owner. Delegates TXT routes to the unmodified ReaderRouteOwner.
@MainActor
final class BookReadingRouteOwner: ObservableObject {
    @Published private(set) var presentation: BookReadingRoute?
    private let txtRoutes = ReaderRouteOwner()
    private let epubRenderers = EPUBWarmRendererCache()

    func open(book: LibraryBook, service: LibraryService) {
        open(bookID: book.id, format: book.format, service: service)
    }

    func open(bookID: String, format: LibraryBookFormat = .txt, service: LibraryService) {
        guard presentation == nil else { return }
        switch format {
        case .txt:
            epubRenderers.leaveEPUB()
            guard txtRoutes.presentation == nil else { return }
            txtRoutes.open(bookID: bookID, service: service)
            guard let txtPresentation = txtRoutes.presentation else { return }
            presentation = BookReadingRoute(txt: txtPresentation, bookID: bookID)
        case .epub:
            let model = EPUBReaderViewModel(bookID: bookID, service: service, rendererCache: epubRenderers)
            presentation = BookReadingRoute(epub: model, bookID: bookID)
        }
    }

    /// Called only after this route's explicit exit has saved successfully.
    func finishExit(_ id: UUID) {
        guard let active = presentation, active.id == id else { return }
        if case .txt = active.content {
            txtRoutes.finishExit(id)
        }
        presentation = nil
    }

    /// A presentation binding being cleared is an actual route end, unlike view disappearance.
    func presentationEnded(_ ended: BookReadingRoute) {
        if presentation?.id == ended.id {
            presentation = nil
        }
        switch ended.content {
        case .txt(let txtPresentation):
            txtRoutes.presentationEnded(txtPresentation)
        case .epub(let epubModel):
            Task { _ = await epubModel.close() }
        }
    }
}

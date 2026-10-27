import Combine
import Foundation
import ReaderDomain

/// Sole owner of this presentation and its short-lived pending URL. Retained after a pure dismissal
/// so a late delegate callback can still arrive; replaced only when the next attempt begins.
@MainActor
final class FileSelectionSession: ObservableObject {
    enum Delivery { case selected(URL), empty, cancelled, missingSelectedURL }
    let id: UUID
    let coordinator: DocumentPickerBridge.Coordinator
    @Published var isPresented = false
    private var route: ImportPickerRoute
    private var pendingURL: URL?
    private var presentedOnce = false

    init(id: UUID, selected: @escaping @MainActor (UUID, [URL]) -> Void,
         cancelled: @escaping @MainActor (UUID) -> Void) {
        self.id = id
        route = ImportPickerRoute(id: id)
        coordinator = DocumentPickerBridge.Coordinator(id: id, selected: selected, cancelled: cancelled)
    }

    var dismissalConfirmed: Bool { route.dismissed }

    func presentOnce() {
        guard !presentedOnce else { return }
        presentedOnce = true
        isPresented = true
    }

    func receiveSelection(_ urls: [URL]) -> Bool {
        guard route.receive(urls.isEmpty ? .empty : .selected, for: id) else { return false }
        pendingURL = urls.first
        return true
    }

    func receiveCancellation() -> Bool { route.receive(.cancelled, for: id) }

    func requestDismissal() { isPresented = false }

    func confirmDismissal() -> Bool {
        isPresented = false
        return route.confirmDismissal(for: id)
    }

    func takeReady() -> Delivery? {
        guard let outcome = route.takeReady(for: id) else { return nil }
        let url = pendingURL
        pendingURL = nil
        switch outcome {
        case .selected:
            if let url { return .selected(url) }
            return .missingSelectedURL
        case .empty: return .empty
        case .cancelled: return .cancelled
        }
    }
}

import ReaderDomain
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct DocumentPickerBridge: UIViewControllerRepresentable {
    let session: FileSelectionSession

    func makeCoordinator() -> Coordinator { session.coordinator }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Open the external security-scoped URL; LibraryService still makes the durable private copy.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.plainText], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let id: UUID
        private let selected: @MainActor (UUID, [URL]) -> Void
        private let cancelled: @MainActor (UUID) -> Void

        init(id: UUID, selected: @escaping @MainActor (UUID, [URL]) -> Void,
             cancelled: @escaping @MainActor (UUID) -> Void) {
            self.id = id; self.selected = selected; self.cancelled = cancelled
            super.init()
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            selected(id, urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cancelled(id) }
    }

    /// A stable per-attempt host. onDisappear never decides a result or starts an import.
    @MainActor
    struct Presentation: View {
        @ObservedObject var session: FileSelectionSession
        let onDismiss: @MainActor (UUID) -> Void

        var body: some View {
            let active = session
            Color.clear
                .sheet(isPresented: $session.isPresented, onDismiss: { onDismiss(active.id) }) {
                    DocumentPickerBridge(session: active)
                }
                .onAppear { active.presentOnce() }
        }
    }
}

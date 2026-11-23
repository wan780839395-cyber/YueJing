import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// File providers can advertise TTF/OTF as generic items. Browse broadly; the
/// store still validates real SFNT bytes, file type, paths and quotas after selection.
@MainActor
struct EPUBFontFilePicker: UIViewControllerRepresentable {
    struct Attempt: Identifiable { let id = UUID() }
    enum Outcome: Equatable { case selected(URL), unsupported, unavailable, cancelled }
    static let browsingTypes: [UTType] = [.item]
    let complete: @MainActor (Outcome) -> Void

    static func selection(_ urls: [URL]) -> Outcome {
        guard urls.count == 1, let url = urls.first, url.isFileURL else { return .unavailable }
        guard ["ttf", "otf"].contains(url.pathExtension.lowercased()) else { return .unsupported }
        return .selected(url)
    }

    func makeCoordinator() -> Coordinator { Coordinator(complete) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Request a provider-supplied copy. The font store still validates and bounds its own import.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.browsingTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private var completion: (@MainActor (Outcome) -> Void)?
        init(_ completion: @escaping @MainActor (Outcome) -> Void) { self.completion = completion }
        private func finish(_ outcome: Outcome) {
            let callback = completion
            completion = nil
            callback?(outcome)
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(EPUBFontFilePicker.selection(urls))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(.cancelled) }
    }
}

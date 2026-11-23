import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import YueJing

@MainActor
struct EPUBFontFilePickerTests {
    @Test func genericProviderItemsAreBrowsableButOnlyFontURLsAreForwarded() {
        let types = EPUBFontFilePicker.browsingTypes
        #expect(types == [UTType.item])
        #expect(UTType.data.conforms(to: types[0]))
        let font = URL(fileURLWithPath: "/fixture/book.OTF")
        let ttf = URL(fileURLWithPath: "/fixture/book.ttf")
        #expect(EPUBFontFilePicker.selection([font]) == .selected(font))
        #expect(EPUBFontFilePicker.selection([ttf]) == .selected(ttf))
        #expect(EPUBFontFilePicker.selection([font.appendingPathExtension("zip")]) == .unsupported)
        #expect(EPUBFontFilePicker.selection([]) == .unavailable)
        #expect(EPUBFontFilePicker.selection([font, ttf]) == .unavailable)
        #expect(EPUBFontFilePicker.selection([URL(string: "https://example.invalid/book.ttf")!]) == .unavailable)
    }
    @Test func pickerDeliversFirstSelectionOrCancellationOnlyOnce() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        let url = URL(fileURLWithPath: "/fixture/font.ttf")
        var results: [EPUBFontFilePicker.Outcome] = []
        let first = EPUBFontFilePicker.Coordinator { results.append($0) }
        first.documentPickerWasCancelled(picker)
        first.documentPicker(picker, didPickDocumentsAt: [url])
        let second = EPUBFontFilePicker.Coordinator { results.append($0) }
        second.documentPicker(picker, didPickDocumentsAt: [url])
        second.documentPickerWasCancelled(picker)
        #expect(results == [.cancelled, .selected(url)])
    }
}

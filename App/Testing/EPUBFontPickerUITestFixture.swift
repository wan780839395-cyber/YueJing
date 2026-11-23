#if DEBUG && targetEnvironment(simulator)
import ReaderDomain
import SwiftUI
import UIKit

@MainActor
struct EPUBFontPickerUITestFixture: View {
    static var isRequested: Bool {
        let process = ProcessInfo.processInfo
        guard EPUBUITestFixture.isRequested,
              let raw = process.environment[EPUBUITestFixture.sessionEnvironmentKey],
              UUID(uuidString: raw) != nil else { return false }
        return process.arguments.contains("-epub-font-picker-fixture")
    }

    @State private var selectedID: String?
    @State private var didSelectOriginal = false
    @State private var export: SampleExport?
    @State private var exportStatus = ""

    var body: some View {
        ScrollView {
            Button("Export synthetic TTF") {
                do {
                    export = try SampleExport()
                } catch {
                    exportStatus = "Preparation failed"
                }
            }
            .accessibilityIdentifier("fixture.font.export")
            if !exportStatus.isEmpty {
                Text(exportStatus).accessibilityIdentifier("fixture.font.exportStatus")
            }
            EPUBUserFontPicker(selectedID: selectedID, isActive: { true }, select: { font in
                selectedID = font?.id
                didSelectOriginal = font == nil
            }, appearance: ReaderToolAppearance(theme: .paper, reduceTransparency: false))
            .padding()
            // Observe the real menu callback without writing any book preferences.
            if didSelectOriginal {
                Text("Original selected").accessibilityIdentifier("fixture.font.originalSelected")
            }
        }
        .sheet(item: $export) { sample in
            SampleExporter(url: sample.url) { saved in
                exportStatus = saved ? "Saved" : "Not saved"
                export = nil
            }
        }
    }
}

// Original 1,144-byte SFNT from EPUBFontLoadingHostTests.syntheticGeometricFontBase64.
// Nothing is written to Files until the driver confirms the system export sheet.
private struct SampleExport: Identifiable {
    let id = UUID()
    let url: URL

    init() throws {
        guard let raw = ProcessInfo.processInfo.environment[EPUBUITestFixture.sessionEnvironmentKey],
              let session = UUID(uuidString: raw),
              let bytes = Data(base64Encoded: Self.font, options: .ignoreUnknownCharacters) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YJFont-\(session.uuidString.prefix(8)).ttf")
        try bytes.write(to: url, options: .atomic)
    }

    private static let font = """
    AAEAAAAKAIAAAwAgT1MvMmYUbsEAAACsAAAAYGNtYXAAdABcAAABDAAAADxnbHlmvb57sgAAAUgA
    AACAaGVhZC8KPKEAAAHIAAAANmhoZWEM5glkAAACAAAAACRobXR4EZQAyAAAAiQAAAAMbG9jYQAc
    AFwAAAIwAAAACG1heHAABgANAAACOAAAACBuYW1lrwA06wAAAlgAAAH4cG9zdP+kAFYAAARQAAAA
    KAAEBdwBkAAFAAACigJYAAAASwKKAlgAAAFeADIA+gAAAgAFAwAAAAAAAAAAAAEAAAAAAAAAAAAA
    AABZSlRGAMAAIABBAyD/OAAAAyAAyAAAAAEAAAAAAfQCvAAAACAAAAAAAAIAAAADAAAAFAADAAEA
    AAAUAAQAKAAAAAYABAABAAIAIABB//8AAAAgAEH////h/8EAAQAAAAAAAAACAGQAAAOEArwAAwAH
    AAABAQEBAQEBAQBkAAADIAAA/UQCWAAA/agAAAK8AAD9RABkAAAB9AAAAAIAZAAACWACvAAHAAoA
    AAEBAQEBAQEBAQEBAGQDtgGQA7b+Pv8a/FT/GgFyApT+tgAAArwAAP1EAAAAyAAA/zgBQAAAAPAA
    AAEAAAABAABkdcbZXw889QADA+gAAAAA4xf8gAAAAADjF/yAAGQAAAlgArwAAAAIAAIAAAAAAAAA
    AQAAAyD/OAAACcQAZABkCWAAAQAAAAAAAAAAAAAAAAAAAAMD6ABkA+gAAAnEAGQAAAAcABwAQAABA
    AAAAwALAAIAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAADACWAAEAAAAAAAEAFAAAAAEAAAAAAAIABw
    AUAAEAAAAAAAMAGAAbAAEAAAAAAAQAHAAzAAEAAAAAAAUACwBPAAEAAAAAAAYAHABaAAMAAQQJAA
    EAKAB2AAMAAQQJAAIADgCeAAMAAQQJAAMAMACsAAMAAQQJAAQAOADcAAMAAQQJAAUAFgEUAAMAAQ
    QJAAYAOAEqWXVlSmluZ1Rlc3RHZW9tZXRyaWNSZWd1bGFyWXVlSmluZ1Rlc3RHZW9tZXRyaWMtMS
    4wWXVlSmluZ1Rlc3RHZW9tZXRyaWMgUmVndWxhclZlcnNpb24gMS4wWXVlSmluZ1Rlc3RHZW9tZX
    RyaWMtUmVndWxhcgBZAHUAZQBKAGkAbgBnAFQAZQBzAHQARwBlAG8AbQBlAHQAcgBpAGMAUgBlAG
    cAdQBsAGEAcgBZAHUAZQBKAGkAbgBnAFQAZQBzAHQARwBlAG8AbQBlAHQAcgBpAGMALQAxAC4AMA
    BZAHUAZQBKAGkAbgBnAFQAZQBzAHQARwBlAG8AbQBlAHQAcgBpAGMAIABSAGUAZwB1AGwAYQByAF
    YAZQByAHMAaQBvAG4AIAAxAC4AMABZAHUAZQBKAGkAbgBnAFQAZQBzAHQARwBlAG8AbQBlAHQAcg
    BpAGMALQBSAGUAZwB1AGwAYQByAAIAAAAAAAD/nAAyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwAAAAMA
    JA==
    """
}

@MainActor private struct SampleExporter: UIViewControllerRepresentable {
    let url: URL
    let finish: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finish) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finish: @MainActor (Bool) -> Void
        init(_ finish: @escaping @MainActor (Bool) -> Void) { self.finish = finish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls.count == 1)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
    }
}
#endif

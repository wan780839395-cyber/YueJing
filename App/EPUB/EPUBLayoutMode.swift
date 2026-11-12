import Foundation
import ReaderDomain

/// EPUB-only presentation preference. Missing/unknown values use author typography.
enum EPUBLayoutMode: String, CaseIterable, Sendable {
    case original
    case reader

    static let defaultsKey = "epub.layoutMode.v1"
    static func restored(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .original
    }

    /// Compatibility is local to the publication; never overwrites the saved preference.
    func effective(for compatibility: EPUBStyleCompatibility?) -> Self {
        self == .original && compatibility?.usesReaderLayout == true ? .reader : self
    }

    var title: String {
        switch self {
        case .original: "原始排版"
        case .reader: "阅读器排版"
        }
    }
}

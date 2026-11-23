import Foundation

/// Presentation only: not part of a book, Ready manifest or progress row.
enum EPUBUserFontPreference {
    static func validID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func key(_ bookID: String) -> String { "epub.bodyFont.v1." + bookID }
    static func restored(bookID: String, defaults: UserDefaults = .standard) -> String? {
        guard let id = defaults.string(forKey: key(bookID)), validID(id) else { return nil }
        return id
    }
    static func set(_ id: String?, bookID: String, defaults: UserDefaults = .standard) {
        if let id {
            guard validID(id) else { return }
            defaults.set(id, forKey: key(bookID))
        } else { defaults.removeObject(forKey: key(bookID)) }
    }
}

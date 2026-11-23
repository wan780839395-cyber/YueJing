import Combine
import Foundation
import ReaderDomain

/// Presentation only: not part of a book, Ready manifest or progress row.
@MainActor enum EPUBUserFontPreference {
    static let removed = PassthroughSubject<String, Never>()
    private static var pendingValues: [String: String] = [:]
    private enum RemovalError: Error { case alreadyInProgress }

    nonisolated static func validID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func key(_ bookID: String) -> String { "epub.bodyFont.v1." + bookID }
    private static func generationKey(_ id: String) -> String { "epub.fontGeneration." + id }

    // Legacy selections are bare digests. Rotate only the deleted font's generation:
    // no enumeration of book IDs or unrelated defaults, even for books not reopened yet.
    static func selectionValue(_ id: String, defaults: UserDefaults = .standard) -> String {
        if let pending = pendingValues[id] { return pending }
        guard let generation = defaults.string(forKey: generationKey(id)) else { return id }
        return id + ":" + generation
    }

    static func restored(bookID: String, defaults: UserDefaults = .standard) -> String? {
        guard let value = defaults.string(forKey: key(bookID)) else { return nil }
        let id = String(value.prefix(64))
        guard validID(id), value == selectionValue(id, defaults: defaults) else { return nil }
        return id
    }
    static func set(_ id: String?, bookID: String, defaults: UserDefaults = .standard) {
        if let id {
            guard validID(id) else { return }
            defaults.set(selectionValue(id, defaults: defaults), forKey: key(bookID))
        } else { defaults.removeObject(forKey: key(bookID)) }
    }

    static func remove(_ id: String) async throws {
        try await remove(id, store: .shared, defaults: .standard)
        removed.send(id) // independent of picker lifetime
    }

    static func remove(_ id: String, store: EPUBUserFontStore, defaults: UserDefaults) async throws {
        guard validID(id) else { throw EPUBError.unsafePath }
        guard pendingValues[id] == nil else { throw RemovalError.alreadyInProgress }
        let key = generationKey(id), previous = defaults.string(forKey: generationKey(id))
        // Record invalidation before unlink, so a restart during removal errs toward
        // following the book. Live readers see the old value until success; undo on failure.
        pendingValues[id] = selectionValue(id, defaults: defaults)
        defer { pendingValues.removeValue(forKey: id) }
        defaults.set(UUID().uuidString, forKey: key)
        do {
            try await store.removeFont(id: id)
        } catch {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
            throw error
        }
    }
}

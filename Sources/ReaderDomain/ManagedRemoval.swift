import Foundation
import GRDB
import os

/// Journal values are names, never paths. A new deletion of the same name supersedes the old ticket.
struct ManagedRemoval: Codable, FetchableRecord, Sendable {
    enum Kind: String, Codable, Sendable { case txt, epub, pack, ready, content, publication }
    let kind: Kind
    let name: String
    let token: String

    func enqueue(_ db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO managedRemovals(kind,name,token) VALUES(?,?,?)",
                       arguments: [kind.rawValue, name, token])
    }
    func finish(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM managedRemovals WHERE kind=? AND name=? AND token=?",
                       arguments: [kind.rawValue, name, token])
    }
}

/// Check each managed parent before looking at its child. Only ENOENT is a successful no-op;
/// permission/protection errors must leave the durable cleanup ticket in place.
enum ManagedFile {
    static func exists(_ url: URL, as type: FileAttributeType) throws -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == type else { throw LibraryError.notRegularFile }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return false
        }
    }

    static func remove(_ url: URL, as type: FileAttributeType) throws {
        if try exists(url, as: type) { try FileManager.default.removeItem(at: url) }
    }
}

/// Store actors own the reading authority, but more than one store may have the same
/// immutable pack open. Pin/unlink decisions for a generation must agree process-wide.
final class DerivedPackPin: Sendable {
    private static let counts = OSAllocatedUnfairLock(initialState: [String: Int]())
    let pointer: DerivedPointer

    init(_ pointer: DerivedPointer) {
        self.pointer = pointer
        Self.counts.withLock { $0[pointer.generation, default: 0] += 1 }
    }
    deinit {
        let generation = pointer.generation
        Self.counts.withLock { counts in
            if let n = counts[generation], n > 1 { counts[generation] = n - 1 }
            else { counts.removeValue(forKey: generation) }
        }
    }

    static func unlinkIfUnpinned(_ url: URL, generation: String) throws -> Bool {
        try counts.withLock { counts in
            guard counts[generation] == nil else { return false }
            try ManagedFile.remove(url, as: .typeRegular)
            return true
        }
    }
}

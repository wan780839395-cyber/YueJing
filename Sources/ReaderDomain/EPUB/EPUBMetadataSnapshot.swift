import Foundation

/// One open's exact database bytes and their decoded value. Not a session or file-read permit.
/// No caller can pair a different package with these bytes. Discarded after opening completes.
struct EPUBMetadataSnapshot: Sendable {
    private let metadata: Data
    let package: EPUBPackage
    let metadataSHA256: String

    init(metadata: Data) throws {
        package = try JSONDecoder().decode(EPUBPackage.self, from: metadata)
        self.metadata = metadata
        metadataSHA256 = EPUBResourceStore.digest(metadata)
    }

    /// Re-read within the session transaction, then compare actual bytes, never size/mtime.
    func matches(_ current: Data) -> Bool { metadata == current }
}

/// Actor-owned, bounded hashes only: does not retain package/text trees or skip resource checks.
struct EPUBMetadataFingerprintCache {
    private static let maximumEntries = 64
    private var cached: [String: String] = [:]
    private var order: [String] = []
    var count: Int { cached.count }

    static func canonical(_ package: EPUBPackage) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return EPUBResourceStore.digest(try encoder.encode(package))
    }

    mutating func resolve(_ snapshot: EPUBMetadataSnapshot) throws -> (digest: String, reused: Bool) {
        if let digest = cached[snapshot.metadataSHA256] {
            order.removeAll { $0 == snapshot.metadataSHA256 }
            order.append(snapshot.metadataSHA256)
            return (digest, true)
        }
        let digest = try Self.canonical(snapshot.package)
        if order.count >= Self.maximumEntries {
            cached.removeValue(forKey: order.removeFirst())
        }
        cached[snapshot.metadataSHA256] = digest
        order.append(snapshot.metadataSHA256)
        return (digest, false)
    }
}

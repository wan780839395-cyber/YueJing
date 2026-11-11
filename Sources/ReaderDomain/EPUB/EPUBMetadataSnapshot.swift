import Foundation

/// One open's fresh database bytes; decoded trees may be shared with a still-live content lease.
/// Never a session/file-read permit. Raw bytes are discarded after session confirmation.
struct EPUBMetadataSnapshot: Sendable {
    /// Constructible only from decoded real metadata in this file, never a caller-supplied pair.
    final class Decoded: Sendable {
        let package: EPUBPackage
        let metadataSHA256: String
        fileprivate init(package: EPUBPackage, metadataSHA256: String) {
            self.package = package; self.metadataSHA256 = metadataSHA256
        }
    }
    private let metadata: Data
    let decoded: Decoded
    var package: EPUBPackage { decoded.package }
    let metadataSHA256: String
    let decodeReused: Bool
    let reuseReason: EPUBOpeningTimings.MetadataReuseReason

    init(metadata: Data, reusing: Decoded? = nil, readyRoot: URL? = nil) throws {
        self.metadata = metadata
        metadataSHA256 = EPUBResourceStore.digest(metadata)
        if let reusing, reusing.metadataSHA256 == metadataSHA256 {
            decoded = reusing
            decodeReused = true
            reuseReason = .reused
        } else {
            var package = try JSONDecoder().decode(EPUBPackage.self, from: metadata)
            if let reference = package.ready {
                guard let readyRoot, UUID(uuidString: reference.directory) != nil else { throw EPUBError.corruptResource }
                // Attach only our own root; no URL from serialized metadata is trusted.
                package = try package.attachingNodes(folder: readyRoot.appendingPathComponent(reference.directory))
            }
            decoded = Decoded(package: package, metadataSHA256: metadataSHA256)
            decodeReused = false
            reuseReason = reusing == nil ? .noLeaseProof : .metadataChanged
        }
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

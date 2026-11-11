import CryptoKit
import Foundation

/// Versioned, small database descriptor. Offsets refer to one immutable node pack, never to the source ZIP.
public struct EPUBReadyReference: Codable, Sendable, Equatable {
    public struct Chapter: Codable, Sendable, Equatable {
        public let offset: Int
        public let bytes: Int
        public let sha256: String
    }
    public let revision: Int
    public let directory: String
    public let legacyPackageSHA256: String
    public let nodeBytes: Int
    public let nodeSHA256: String
    public let chapters: [String: Chapter]

    func hasSameContent(as other: Self) -> Bool {
        revision == other.revision && legacyPackageSHA256 == other.legacyPackageSHA256 &&
        nodeBytes == other.nodeBytes && nodeSHA256 == other.nodeSHA256 && chapters == other.chapters
    }
}

/// File operations are limited to generated UUID versions. Database publication is a separate CAS transaction.
/// The content pool owns leases and reclamation; this type never replaces an existing version directory.
enum EPUBReadyArtifact {
    static let nodeFile = "nodes.bin"
    static let maximumChapterBytes = 16 * 1024 * 1024

    static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw EPUBError.corruptResource }
    }

    static func folder(root: URL, reference: EPUBReadyReference) throws -> URL {
        guard reference.revision == 1, UUID(uuidString: reference.directory) != nil else { throw EPUBError.corruptResource }
        try requireDirectory(root.deletingLastPathComponent())
        try requireDirectory(root)
        let result = root.appendingPathComponent(reference.directory, isDirectory: true)
        try requireDirectory(result)
        return result
    }

    static func validate(_ reference: EPUBReadyReference, package: EPUBPackage) throws {
        guard reference.revision == 1, UUID(uuidString: reference.directory) != nil,
              reference.legacyPackageSHA256.count == 64, reference.nodeSHA256.count == 64,
              reference.nodeBytes >= 0, reference.nodeBytes <= EPUBLimits().expandedBytes,
              !package.spine.isEmpty, package.spine.count <= EPUBLimits().spineItems,
              Set(package.spine).count == package.spine.count,
              Set(reference.chapters.keys) == Set(package.spine), package.textNodes.isEmpty else { throw EPUBError.corruptResource }
        var offset = 0
        for path in package.spine {
            guard try EPUBResourcePath.canonical(path) == path,
                  let chapter = reference.chapters[path], chapter.offset == offset,
                  chapter.bytes > 0, chapter.bytes <= maximumChapterBytes,
                  chapter.bytes <= reference.nodeBytes - offset,
                  chapter.sha256.count == 64 else { throw EPUBError.corruptResource }
            offset += chapter.bytes
        }
        guard offset == reference.nodeBytes else { throw EPUBError.corruptResource }
    }

    /// Called only with a newly generated, empty destination. Original node numbering/UTF-16 text is preserved.
    static func writeNodes(package: EPUBPackage, folder: URL) throws -> EPUBPackage {
        guard package.ready == nil, !package.spine.isEmpty,
              Set(package.textNodes.keys) == Set(package.spine),
              package.spine.count <= EPUBLimits().spineItems else { throw EPUBError.invalidPackage }
        let url = folder.appendingPathComponent(nodeFile)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw EPUBError.corruptResource }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var chapters: [String: EPUBReadyReference.Chapter] = [:]
        var offset = 0
        var hasher = SHA256()
        for path in package.spine {
            try Task.checkCancellation()
            guard let nodes = package.textNodes[path], !nodes.isEmpty else { throw EPUBError.corruptResource }
            let data = try JSONEncoder().encode(nodes)
            guard data.count <= maximumChapterBytes, data.count <= EPUBLimits().expandedBytes - offset else { throw EPUBError.limitExceeded }
            chapters[path] = .init(offset: offset, bytes: data.count, sha256: EPUBResourceStore.digest(data))
            try handle.write(contentsOf: data)
            hasher.update(data: data)
            offset += data.count
        }
        try handle.synchronize()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let reference = EPUBReadyReference(revision: 1, directory: folder.lastPathComponent,
            legacyPackageSHA256: try EPUBMetadataFingerprintCache.canonical(package),
            nodeBytes: offset, nodeSHA256: digest, chapters: chapters)
        return package.withReady(reference)
    }

    static func writeManifest(package: EPUBPackage, folder: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(package)
        guard data.count <= 8 * 1024 * 1024 else { throw EPUBError.limitExceeded }
        try data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }

    static func verifyManifest(folder: URL, expectedSHA256: String) throws {
        try requireDirectory(folder.deletingLastPathComponent())
        try requireDirectory(folder)
        let url = folder.appendingPathComponent("manifest.json")
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, size <= 8 * 1024 * 1024 else { throw EPUBError.corruptResource }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: size + 1) ?? Data()
        guard data.count == size, EPUBResourceStore.digest(data) == expectedSHA256 else { throw EPUBError.corruptResource }
    }

    static func verifiedHandle(folder: URL, reference: EPUBReadyReference) throws -> FileHandle {
        try requireDirectory(folder.deletingLastPathComponent())
        try requireDirectory(folder)
        let url = folder.appendingPathComponent(nodeFile)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize == reference.nodeBytes else { throw EPUBError.corruptResource }
        return try FileHandle(forReadingFrom: url)
    }

    static func verifyNodes(package: EPUBPackage, folder: URL) throws {
        guard let reference = package.ready else { throw EPUBError.corruptResource }
        try validate(reference, package: package)
        let handle = try verifiedHandle(folder: folder, reference: reference)
        defer { try? handle.close() }
        var hasher = SHA256(), count = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard chunk.count <= reference.nodeBytes - count else { throw EPUBError.corruptResource }
            count += chunk.count
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == reference.nodeBytes, digest == reference.nodeSHA256 else { throw EPUBError.corruptResource }
    }
}

/// Bounded per-reader decoded chapters, not a process-wide full-book metadata cache.
/// Lock protects cache mutation only; file reads/decode happen outside the lock.
final class EPUBChapterNodes: @unchecked Sendable {
    private let folder: URL
    private let reference: EPUBReadyReference
    private let lock = NSLock()
    private var cache: [String: (nodes: [String], cost: Int)] = [:]
    private var order: [String] = []
    private var bytes = 0
    private static let maximumBytes = 8 * 1024 * 1024

    init(folder: URL, reference: EPUBReadyReference) { self.folder = folder; self.reference = reference }

    func nodes(at path: String) throws -> [String]? {
        guard let chapter = reference.chapters[path] else { return nil }
        if let hit = cached(path) { return hit }
        try Task.checkCancellation()
        let handle = try EPUBReadyArtifact.verifiedHandle(folder: folder, reference: reference)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(chapter.offset))
        let data = try handle.read(upToCount: chapter.bytes) ?? Data()
        guard data.count == chapter.bytes, EPUBResourceStore.digest(data) == chapter.sha256 else { throw EPUBError.corruptResource }
        let nodes = try JSONDecoder().decode([String].self, from: data)
        guard !nodes.isEmpty else { throw EPUBError.corruptResource }
        let cost = nodes.reduce(0) { $0 + $1.utf16.count * 2 + 32 }
        remember(path, nodes: nodes, cost: cost)
        return nodes
    }

    private func cached(_ path: String) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = cache[path] else { return nil }
        order.removeAll { $0 == path }; order.append(path)
        return hit.nodes
    }
    private func remember(_ path: String, nodes: [String], cost: Int) {
        guard cost <= Self.maximumBytes else { return }
        lock.lock(); defer { lock.unlock() }
        if let old = cache.removeValue(forKey: path) { bytes -= old.cost }
        order.removeAll { $0 == path }
        while !order.isEmpty && (order.count >= 4 || cost > Self.maximumBytes - bytes) {
            if let old = cache.removeValue(forKey: order.removeFirst()) { bytes -= old.cost }
        }
        cache[path] = (nodes, cost); order.append(path); bytes += cost
    }
}

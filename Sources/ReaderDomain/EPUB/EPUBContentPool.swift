import Foundation

/// File lifetime only: never a navigation, resource URL or progress-write capability.
/// Independent holders get independent tokens. Explicit release and deinit are idempotent.
public final class EPUBContentLease: Sendable {
    public let publication: EPUBPublication
    private let owner: EPUBContentPool
    private let token: UUID

    init(publication: EPUBPublication, owner: EPUBContentPool, token: UUID) {
        self.publication = publication; self.owner = owner; self.token = token
    }
    deinit {
        let owner = owner, token = token
        Task { await owner.release(token, retain: false) }
    }
    public func duplicate() async throws -> EPUBContentLease {
        try await owner.duplicate(token)
    }
    public func release() async { await owner.release(token, retain: false) }
    func finish(retain: Bool) async { await owner.release(token, retain: retain) }
}

/// One process-wide owner avoids separate LibraryService instances deleting each other's files.
/// No retained package/text-node trees: idle entries contain only small fingerprints and costs.
actor EPUBContentPool {
    static let shared = EPUBContentPool()
    struct Limits: Sendable {
        var diskBytes = 512 * 1024 * 1024 // Provisional budget, not a promised number of books.
        var entries = 64 // Bound metadata enumeration as well as disk bytes.
    }
    private struct Record: Codable, Sendable {
        let key: String
        let packageDigest: String
        let bytes: Int
        var touched: Date
    }
    private struct Entry {
        let root: URL
        let folder: URL
        var record: Record
        var tokens: Set<UUID> = []
        var retained = false
        var retired = false
        var persistent = false
    }
    private struct Holder {
        let folder: URL
        let publication: EPUBPublication
        let decoded: EPUBMetadataSnapshot.Decoded?
    }
    private var entries: [URL: Entry] = [:]
    private var holders: [UUID: Holder] = [:]
    private var packageFingerprints = EPUBMetadataFingerprintCache()
    private let limits: Limits
    private var reconciledReadyRoots: Set<URL> = []
    init(limits: Limits = Limits()) { self.limits = limits }

    /// Only borrow a package already held by an active/parked lease. Idle disk entries
    /// never retain full metadata; a fresh database SHA must match before reuse.
    func reusableMetadata(bookID: String, root: URL) -> EPUBMetadataSnapshot.Decoded? {
        for holder in holders.values {
            guard let entry = entries[holder.folder], entry.root == root, !entry.retired,
                  let decoded = holder.decoded, decoded.package.sourceSHA256 == bookID else { continue }
            return decoded
        }
        return nil
    }

    private static func requireDirectory(_ url: URL) throws {
        let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard v.isDirectory == true, v.isSymbolicLink != true else { throw EPUBError.corruptResource }
    }
    private static func size(_ package: EPUBPackage) throws -> Int {
        var total = 0
        guard package.resources.count <= EPUBLimits().entries else { throw EPUBError.limitExceeded }
        for resource in package.resources {
            guard resource.byteCount >= 0, resource.byteCount <= EPUBLimits().expandedBytes - total else {
                throw EPUBError.limitExceeded
            }
            total += resource.byteCount
        }
        return total
    }
    private func discover(_ root: URL) throws {
        let files = FileManager.default
        try Self.requireDirectory(root.deletingLastPathComponent())
        if !files.fileExists(atPath: root.path) {
            try files.createDirectory(at: root, withIntermediateDirectories: false)
        }
        try Self.requireDirectory(root)
        // Inspect only our UUID entries; never recursively delete an unknown path or follow a link.
        for folder in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: folder.lastPathComponent) != nil, entries[folder] == nil else { continue }
            do {
                try Self.requireDirectory(folder)
                let marker = folder.appendingPathComponent("receipt.json")
                let v = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard v.isRegularFile == true, v.isSymbolicLink != true, (v.fileSize ?? Int.max) <= 1024 else {
                    throw EPUBError.corruptResource
                }
                let input = try FileHandle(forReadingFrom: marker)
                defer { try? input.close() }
                let data = try input.read(upToCount: 1025) ?? Data()
                guard data.count <= 1024 else { throw EPUBError.corruptResource }
                let record = try JSONDecoder().decode(Record.self, from: data)
                guard record.bytes >= 0, record.bytes <= EPUBLimits().expandedBytes,
                      record.key.count == 64, record.packageDigest.count == 64 else { throw EPUBError.corruptResource }
                entries[folder] = Entry(root: root, folder: folder, record: record, retained: true)
            } catch {
                // Invalid cache metadata has no authority; only this unleased generated directory is removed.
                try? files.removeItem(at: folder)
            }
        }
    }

    /// Serialized preparation has no await: overlapping requests cannot publish duplicate work.
    /// Every acquisition, including hits, re-reads the original and all actual resource hashes.
    func acquire(bookID: String, archive: URL, snapshot: EPUBMetadataSnapshot, root: URL)
        throws -> (lease: EPUBContentLease, reused: Bool, timings: EPUBOpeningTimings) {
        try acquire(bookID: bookID, archive: archive, expected: snapshot.package, root: root, snapshot: snapshot)
    }

    func acquire(bookID: String, archive: URL, expected: EPUBPackage, root: URL)
        throws -> (lease: EPUBContentLease, reused: Bool, timings: EPUBOpeningTimings) {
        try acquire(bookID: bookID, archive: archive, expected: expected, root: root, snapshot: nil)
    }

    private func acquire(bookID: String, archive: URL, expected: EPUBPackage, root: URL,
                         snapshot: EPUBMetadataSnapshot?)
        throws -> (lease: EPUBContentLease, reused: Bool, timings: EPUBOpeningTimings) {
        try Task.checkCancellation()
        var timings = EPUBOpeningTimings()
        guard try timings.measure(.sourceVerification, { try EPUBResourceStore.sourceDigest(archive) }) == expected.sourceSHA256 else {
            throw LibraryError.changedFile
        }
        let fingerprint = try timings.measure(.packageFingerprint) {
            if let snapshot { return try packageFingerprints.resolve(snapshot) }
            return (digest: try EPUBMetadataFingerprintCache.canonical(expected), reused: false)
        }
        let digest = fingerprint.digest
        timings.packageFingerprintReused = fingerprint.reused
        // Optional cache failure must not prevent a valid first open using temporary storage.
        do { try discover(root) } catch {
            let fallback = root.deletingLastPathComponent().appendingPathComponent("Imports", isDirectory: true)
            try Self.requireDirectory(fallback.deletingLastPathComponent())
            if !FileManager.default.fileExists(atPath: fallback.path) {
                try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: false)
            }
            try Self.requireDirectory(fallback)
            return try build(bookID: bookID, archive: archive, expected: expected, root: fallback,
                             digest: digest, timings: timings, cacheable: false, decoded: snapshot?.decoded)
        }
        let key = EPUBResourceStore.digest(Data((bookID + "\n" + expected.versionID).utf8))
        let bytes = try Self.size(expected)
        let candidates = entries.values.filter { $0.root == root && $0.record.key == key && !$0.retired }
            .sorted { $0.record.touched > $1.record.touched }
        for entry in candidates {
            do {
                guard entry.record.packageDigest == digest, entry.record.bytes == bytes else { throw EPUBError.corruptResource }
                let publication = EPUBPublication(package: expected, resourceRoot: entry.folder.appendingPathComponent("resources"))
                timings.resourceVerificationRoute = .legacyCache // Serial legacy path has no lane breakdown.
                try timings.measure(.warmResourceVerification) { try EPUBPublicationCache.verifyResources(publication) }
                try Task.checkCancellation()
                let lease = grant(publication, folder: entry.folder, decoded: snapshot?.decoded)
                timings.contentCacheOutcome = .verifiedVersion
                timings.resourceCount = expected.resources.count
                timings.resourceBytes = bytes
                trim(root)
                return (lease, true, timings)
            } catch is CancellationError { throw CancellationError() }
            catch {
                timings.contentCacheOutcome = .rebuiltAfterInvalidation
                entries[entry.folder]?.retired = true
                removeIfUnused(entry.folder)
            }
        }
        do {
            return try build(bookID: bookID, archive: archive, expected: expected, root: root,
                             digest: digest, timings: timings, cacheable: true, decoded: snapshot?.decoded)
        } catch let error as CocoaError where error.code == .fileWriteNoPermission || error.code == .fileWriteVolumeReadOnly {
            let fallback = root.deletingLastPathComponent().appendingPathComponent("Imports", isDirectory: true)
            try Self.requireDirectory(fallback.deletingLastPathComponent())
            if !FileManager.default.fileExists(atPath: fallback.path) {
                try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: false)
            }
            try Self.requireDirectory(fallback)
            return try build(bookID: bookID, archive: archive, expected: expected, root: fallback,
                             digest: digest, timings: timings, cacheable: false, decoded: snapshot?.decoded)
        }
    }

    private func build(bookID: String, archive: URL, expected: EPUBPackage, root: URL,
                       digest: String, timings initialTimings: EPUBOpeningTimings, cacheable: Bool,
                       decoded: EPUBMetadataSnapshot.Decoded?)
        throws -> (lease: EPUBContentLease, reused: Bool, timings: EPUBOpeningTimings) {
        var timings = initialTimings
        let key = EPUBResourceStore.digest(Data((bookID + "\n" + expected.versionID).utf8))
        let bytes = try Self.size(expected)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: folder) } }
        let resources = folder.appendingPathComponent("resources", isDirectory: true)
        let package = try timings.measure(.rebuild) { try EPUBPackageParser.parse(archiveURL: archive, destination: resources) }
        guard package == expected else { throw EPUBError.corruptResource }
        try Task.checkCancellation()
        entries[folder] = Entry(root: root, folder: folder,
            record: Record(key: key, packageDigest: digest, bytes: bytes, touched: Date()), retired: !cacheable)
        // Equality above validates the rebuild; retain the existing tree, not a second decoded copy.
        let lease = grant(EPUBPublication(package: expected, resourceRoot: resources), folder: folder, decoded: decoded)
        timings.contentCacheOutcome = cacheable
            ? (initialTimings.contentCacheOutcome == .rebuiltAfterInvalidation ? .rebuiltAfterInvalidation : .rebuilt)
            : .temporary
        timings.resourceCount = package.resources.count
        timings.resourceBytes = bytes
        published = true
        trim(root)
        return (lease, false, timings)
    }

    private func grant(_ publication: EPUBPublication, folder: URL,
                       decoded: EPUBMetadataSnapshot.Decoded?) -> EPUBContentLease {
        let token = UUID()
        entries[folder]?.tokens.insert(token)
        entries[folder]?.record.touched = Date()
        holders[token] = Holder(folder: folder, publication: publication, decoded: decoded)
        return EPUBContentLease(publication: publication, owner: self, token: token)
    }
    func duplicate(_ token: UUID) throws -> EPUBContentLease {
        try Task.checkCancellation()
        guard let holder = holders[token], let entry = entries[holder.folder], !entry.retired else {
            throw EPUBError.staleSession
        }
        return grant(holder.publication, folder: holder.folder, decoded: holder.decoded)
    }
    func release(_ token: UUID, retain: Bool) {
        guard let holder = holders.removeValue(forKey: token), var entry = entries[holder.folder] else { return }
        entry.tokens.remove(token)
        entry.record.touched = Date()
        if retain && !entry.retired && !entry.persistent {
            do {
                try Self.requireDirectory(entry.root)
                try Self.requireDirectory(entry.folder)
                let marker = entry.folder.appendingPathComponent("receipt.json")
                // Atomic replace must not follow an existing symbolic link.
                if let values = try? marker.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                    throw EPUBError.corruptResource
                }
                try JSONEncoder().encode(entry.record).write(to: marker, options: .atomic)
                entry.retained = true
            } catch {
                // Optional caching failure cannot turn an already committed reading save into failure.
                entry.retained = false
            }
        }
        entries[holder.folder] = entry
        removeIfUnused(holder.folder)
        trim(entry.root)
    }
    private func removeIfUnused(_ folder: URL) {
        guard let entry = entries[folder], entry.tokens.isEmpty,
              entry.retired || (!entry.persistent && !entry.retained) else { return }
        // Only generated folders registered under this pool root are ever removed.
        do {
            try Self.requireDirectory(entry.root)
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
            entries.removeValue(forKey: folder)
        } catch {
            // Keep failed cleanup accounted for and eligible for a later bounded retry.
            entries[folder]?.retired = true
        }
    }
    private func trim(_ root: URL) {
        let all = entries.values.filter { $0.root == root && !$0.persistent }
        var bytes = all.reduce(0) { $0 + $1.record.bytes }
        var count = all.count
        for entry in all.sorted(by: { $0.record.touched < $1.record.touched }) where entry.tokens.isEmpty {
            guard entry.retired || bytes > limits.diskBytes || count > limits.entries else { continue }
            entries[entry.folder]?.retired = true
            removeIfUnused(entry.folder)
            if entries[entry.folder] == nil { bytes -= entry.record.bytes; count -= 1 }
        }
        // Active/parked leases may exceed a cache target; never evict their files.
    }
    func discardUnused(root: URL) {
        for entry in entries.values.filter({ $0.root == root && $0.tokens.isEmpty && !$0.persistent }) {
            entries[entry.folder]?.retired = true
            removeIfUnused(entry.folder)
        }
    }
}

extension EPUBContentPool {
    /// First-process reconciliation skips every live registered version, including pending database commits.
    /// A stale caller's reference list therefore cannot delete a concurrently published version.
    func reconcileReady(root: URL, referenced: Set<String>) throws {
        guard !reconciledReadyRoots.contains(root) else { return }
        try Self.requireDirectory(root.deletingLastPathComponent())
        let files = FileManager.default
        if !files.fileExists(atPath: root.path) { try files.createDirectory(at: root, withIntermediateDirectories: false) }
        try Self.requireDirectory(root)
        for folder in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  !referenced.contains(folder.lastPathComponent), entries[folder] == nil else { continue }
            // Removing a directory entry does not traverse a symlink. Never recursively enumerate unknown names.
            try files.removeItem(at: folder)
        }
        reconciledReadyRoots.insert(root)
    }

    /// Freeze a prepared import/migration without parsing the source again. A live lease protects the DB publication gap.
    func stageReady(publication: EPUBPublication, root: URL) throws -> EPUBContentLease {
        try Task.checkCancellation()
        try Self.requireDirectory(root.deletingLastPathComponent())
        let files = FileManager.default
        if !files.fileExists(atPath: root.path) { try files.createDirectory(at: root, withIntermediateDirectories: false) }
        try Self.requireDirectory(root)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        var published = false
        defer { if !published { try? files.removeItem(at: folder) } }
        let resources = folder.appendingPathComponent("resources", isDirectory: true)
        try EPUBPublicationCache.copyVerified(publication, to: resources)
        let compact = try EPUBReadyArtifact.writeNodes(package: publication.package, folder: folder)
        try EPUBReadyArtifact.writeManifest(package: compact, folder: folder)
        try EPUBReadyArtifact.verifyNodes(package: compact, folder: folder)
        try EPUBPublicationCache.verifyResources(EPUBPublication(package: compact, resourceRoot: resources))
        try Task.checkCancellation()
        let bound = try compact.attachingNodes(folder: folder)
        let digest = try EPUBMetadataFingerprintCache.canonical(compact)
        entries[folder] = Entry(root: root, folder: folder,
            record: Record(key: compact.sourceSHA256, packageDigest: digest,
                           bytes: try Self.size(compact), touched: Date()))
        let lease = grant(EPUBPublication(package: bound, resourceRoot: resources), folder: folder, decoded: nil)
        published = true
        return lease
    }

    /// Mark persistent only after the database commits the matching reference. No cancellation point here.
    func commitReady(directory: String, root: URL, replacing: String? = nil) {
        let folder = root.appendingPathComponent(directory, isDirectory: true)
        if entries[folder] != nil { entries[folder]?.persistent = true }
        if let replacing, replacing != directory, UUID(uuidString: replacing) != nil {
            let old = root.appendingPathComponent(replacing, isDirectory: true)
            if entries[old] != nil {
                entries[old]?.persistent = false; entries[old]?.retired = true
                removeIfUnused(old)
            } else {
                // All Ready readers register with this process-wide owner before reading.
                if (try? Self.requireDirectory(root)) != nil { try? FileManager.default.removeItem(at: old) }
            }
        }
    }

    func acquireReady(archive: URL, snapshot: EPUBMetadataSnapshot, root: URL) async throws
        -> (lease: EPUBContentLease, reused: Bool, timings: EPUBOpeningTimings) {
        try Task.checkCancellation()
        let package = snapshot.package
        guard let reference = package.ready else { throw EPUBError.corruptResource }
        try EPUBReadyArtifact.validate(reference, package: package)
        var timings = EPUBOpeningTimings()
        guard try timings.measure(.sourceVerification, { try EPUBResourceStore.sourceDigest(archive) }) == package.sourceSHA256 else {
            throw LibraryError.changedFile
        }
        let fingerprint = try timings.measure(.packageFingerprint) { try packageFingerprints.resolve(snapshot) }
        timings.packageFingerprintReused = fingerprint.reused
        let folder = try EPUBReadyArtifact.folder(root: root, reference: reference)
        try EPUBReadyArtifact.verifyManifest(folder: folder, expectedSHA256: fingerprint.digest)
        let publication = EPUBPublication(package: package, resourceRoot: folder.appendingPathComponent("resources"))
        let bytes = try Self.size(package)
        // Registration is a process-local fact, not a claim about OS page-cache/disk temperature.
        timings.resourceVerificationRoute = entries[folder] == nil ? .readyDisk : .readyRegistered
        if entries[folder] == nil {
            entries[folder] = Entry(root: root, folder: folder,
                record: Record(key: package.sourceSHA256, packageDigest: snapshot.metadataSHA256,
                               bytes: bytes, touched: Date()), persistent: true)
        }
        guard entries[folder]?.retired == false else { throw EPUBError.corruptResource }
        // Pin before await: a replacement/other open may retire, but cannot delete this version during verification.
        let lease = grant(publication, folder: folder, decoded: snapshot.decoded)
        do {
            let started = ContinuousClock.now
            try EPUBReadyArtifact.verifyNodes(package: package, folder: folder)
            timings.resourceVerification = try await EPUBPublicationCache.verifyResourcesConcurrentlyMeasured(publication)
            timings.record(.warmResourceVerification, since: started)
            try Task.checkCancellation()
            guard entries[folder]?.retired == false else { throw EPUBError.corruptResource }
            timings.contentCacheOutcome = .verifiedVersion
            timings.resourceCount = package.resources.count
            timings.resourceBytes = bytes
            return (lease, true, timings)
        } catch {
            await lease.release()
            throw error
        }
    }

    /// Recovery is permitted only when the freshly parsed source proves the exact old semantic package.
    func rebuildReady(archive: URL, expected: EPUBPackage, root: URL, work: URL) throws -> EPUBContentLease {
        defer { try? FileManager.default.removeItem(at: work) }
        let package = try EPUBPackageParser.parse(archiveURL: archive, destination: work)
        let expectedDigest = try expected.ready?.legacyPackageSHA256 ?? EPUBMetadataFingerprintCache.canonical(expected)
        guard try EPUBMetadataFingerprintCache.canonical(package) == expectedDigest else { throw EPUBError.corruptResource }
        if let reference = expected.ready {
            // The legacy digest alone must not authorize modified lightweight fields/indexes.
            guard package.sourceSHA256 == expected.sourceSHA256, package.parserVersion == expected.parserVersion,
                  package.title == expected.title, package.spine == expected.spine,
                  package.navigation == expected.navigation, package.resources == expected.resources,
                  package.coverPath == expected.coverPath else { throw EPUBError.corruptResource }
            for path in package.spine {
                guard let nodes = package.textNodes[path], let chapter = reference.chapters[path],
                      EPUBResourceStore.digest(try JSONEncoder().encode(nodes)) == chapter.sha256 else { throw EPUBError.corruptResource }
            }
        }
        return try stageReady(publication: EPUBPublication(package: package, resourceRoot: work), root: root)
    }
}

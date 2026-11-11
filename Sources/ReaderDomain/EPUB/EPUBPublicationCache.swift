import Foundation

/// Rebuildable, single-publication disk cache. Never stores sessions, preferences or progress.
/// Active readers own separate verified workspaces; only a closed workspace may transfer to a new reader.
enum EPUBPublicationCache {
    static func restore(package: EPUBPackage, cache: URL, destination: URL) throws -> EPUBPublication? {
        let files = FileManager.default
        guard files.fileExists(atPath: cache.path) else { return nil }
        do {
            try requireDirectory(cache.deletingLastPathComponent())
            try requireDirectory(cache)
            let marker = cache.appendingPathComponent("identity.txt")
            let values = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 256,
                  try String(contentsOf: marker, encoding: .utf8) == package.versionID else { return nil }
            let publication = EPUBPublication(package: package, resourceRoot: cache.appendingPathComponent("resources"))
            try copyVerified(publication, to: destination)
            return EPUBPublication(package: package, resourceRoot: destination)
        } catch is CancellationError {
            try? files.removeItem(at: destination)
            throw CancellationError()
        } catch {
            // Cache damage is recoverable from the still-verified original archive.
            try? files.removeItem(at: destination)
            return nil
        }
    }

    static func store(_ publication: EPUBPublication, cache: URL) throws {
        let files = FileManager.default
        let parent = cache.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        try requireDirectory(parent)
        let staged = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staged, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staged) }
        try copyVerified(publication, to: staged.appendingPathComponent("resources", isDirectory: true))
        try publication.package.versionID.write(to: staged.appendingPathComponent("identity.txt"), atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        // Single slot bounds retained disk use; active readers own independent workspaces.
        if files.fileExists(atPath: cache.path) { try files.removeItem(at: cache) }
        try files.moveItem(at: staged, to: cache)
        var excluded = cache
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
    }

    /// Warm ownership transfer still reads and hashes every resource, but writes no bytes.
    static func verifyResources(_ publication: EPUBPublication) throws {
        guard publication.package.parserVersion == EPUBFormat.parserVersion,
              !publication.package.spine.isEmpty,
              publication.package.resources.count <= EPUBLimits().entries else { throw EPUBError.corruptResource }
        try requireDirectory(publication.resourceRoot.deletingLastPathComponent())
        try requireDirectory(publication.resourceRoot)
        var total = 0
        var paths = Set<String>()
        for resource in publication.package.resources {
            try Task.checkCancellation()
            guard paths.insert(resource.path).inserted, resource.byteCount >= 0,
                  resource.byteCount <= EPUBLimits().expandedBytes - total else { throw EPUBError.limitExceeded }
            total += resource.byteCount
            // Enforces canonical paths, non-symlink components, regular files, exact size and actual SHA.
            _ = try EPUBResourceStore.data(resource: resource, root: publication.resourceRoot)
        }
    }

    /// At most four actual resource reads at once (<=64 MiB raw buffers with existing per-file limits).
    /// Preflight is serial; every leaf still uses the same path/type/size/full-SHA verifier.
    static func verifyResourcesConcurrently(_ publication: EPUBPublication) async throws {
        _ = try await verifyResourcesConcurrentlyMeasured(publication)
    }

    /// Same four lanes and verification order. Each task returns one bounded numeric aggregate.
    /// Failures/cancellation throw unchanged; no partial measurements are published as success.
    static func verifyResourcesConcurrentlyMeasured(_ publication: EPUBPublication) async throws -> EPUBResourceVerificationTimings {
        let started = ContinuousClock.now
        guard publication.package.parserVersion == EPUBFormat.parserVersion,
              !publication.package.spine.isEmpty,
              publication.package.resources.count <= EPUBLimits().entries else { throw EPUBError.corruptResource }
        try requireDirectory(publication.resourceRoot.deletingLastPathComponent())
        try requireDirectory(publication.resourceRoot)
        var total = 0
        var paths = Set<String>()
        for resource in publication.package.resources {
            try Task.checkCancellation()
            guard paths.insert(resource.path).inserted, resource.byteCount >= 0,
                  resource.byteCount <= EPUBLimits().expandedBytes - total else { throw EPUBError.limitExceeded }
            total += resource.byteCount
        }
        let resources = publication.package.resources
        let preflightSeconds = EPUBResourceVerificationTimings.seconds(since: started)
        let lanes = try await withThrowingTaskGroup(of: EPUBResourceVerificationTimings.Lane.self) { group in
            for lane in 0..<min(4, resources.count) {
                group.addTask {
                    var timings: EPUBResourceVerificationTimings.Lane? = .init(index: lane)
                    for index in stride(from: lane, to: resources.count, by: 4) {
                        try Task.checkCancellation()
                        _ = try EPUBResourceStore.data(resource: resources[index], root: publication.resourceRoot, timings: &timings)
                        timings?.resourceCount += 1
                        timings?.resourceBytes += resources[index].byteCount
                    }
                    return timings! // Created above; data never clears the lane-owned accumulator.
                }
            }
            var results: [EPUBResourceVerificationTimings.Lane] = []
            results.reserveCapacity(4)
            var firstError: (any Error)?
            // Like waitForAll(), drain ALL children before rethrowing the first error.
            // A simple throwing `for try await` would cancel siblings earlier than the original API.
            while !group.isEmpty {
                do {
                    while let result = try await group.next() { results.append(result) }
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            if let firstError { throw firstError }
            return results.sorted { $0.index < $1.index }
        }
        try Task.checkCancellation()
        return EPUBResourceVerificationTimings(preflightSeconds: preflightSeconds,
            wallSeconds: EPUBResourceVerificationTimings.seconds(since: started), lanes: lanes)
    }

    static func copyVerified(_ publication: EPUBPublication, to destination: URL) throws {
        let files = FileManager.default
        guard publication.package.parserVersion == EPUBFormat.parserVersion,
              !publication.package.spine.isEmpty,
              publication.package.resources.count <= EPUBLimits().entries,
              !files.fileExists(atPath: destination.path) else { throw EPUBError.corruptResource }
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        var total = 0
        var paths = Set<String>()
        var createdDirectories = Set<URL>()
        for resource in publication.package.resources {
            try Task.checkCancellation()
            guard paths.insert(resource.path).inserted, resource.byteCount >= 0,
                  resource.byteCount <= EPUBLimits().expandedBytes - total else { throw EPUBError.limitExceeded }
            total += resource.byteCount
            let data = try EPUBResourceStore.data(resource: resource, root: publication.resourceRoot)
            let url = destination.appendingPathComponent(resource.path)
            let parent = url.deletingLastPathComponent()
            if createdDirectories.insert(parent).inserted {
                try files.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try data.write(to: url, options: .atomic)
        }
    }

    private static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw EPUBError.corruptResource }
    }
}

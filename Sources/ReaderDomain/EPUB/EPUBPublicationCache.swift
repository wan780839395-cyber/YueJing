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
        try await withThrowingTaskGroup(of: Void.self) { group in
            for lane in 0..<min(4, resources.count) {
                group.addTask {
                    for index in stride(from: lane, to: resources.count, by: 4) {
                        try Task.checkCancellation()
                        _ = try EPUBResourceStore.data(resource: resources[index], root: publication.resourceRoot)
                    }
                }
            }
            try await group.waitForAll()
        }
        try Task.checkCancellation()
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

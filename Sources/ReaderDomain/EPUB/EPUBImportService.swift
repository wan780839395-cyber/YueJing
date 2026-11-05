import Foundation

/// Parsing stays off MainActor and is serialized; only the caller-owned workspace is removed on failure.
actor EPUBImportService {
    func prepare(archiveURL: URL, destination: URL) throws -> EPUBPublication {
        try Task.checkCancellation()
        let package = try EPUBPackageParser.parse(archiveURL: archiveURL, destination: destination)
        try Task.checkCancellation()
        return EPUBPublication(package: package, resourceRoot: destination)
    }
    func prepareForReading(archiveURL: URL, destination: URL, expected: EPUBPackage,
                           cache: URL) throws -> (publication: EPUBPublication, reused: Bool) {
        try Task.checkCancellation()
        // Verify original bytes on every open; no mtime/size-only cache trust.
        guard try EPUBResourceStore.sourceDigest(archiveURL) == expected.sourceSHA256 else { throw LibraryError.changedFile }
        if let restored = try EPUBPublicationCache.restore(package: expected, cache: cache, destination: destination) {
            try Task.checkCancellation()
            return (restored, true)
        }
        let fresh = try prepare(archiveURL: archiveURL, destination: destination)
        guard fresh.package == expected else { throw EPUBError.corruptResource }
        do {
            try EPUBPublicationCache.store(fresh, cache: cache)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A full verified open remains usable when optional caching runs out of disk space.
        }
        try Task.checkCancellation()
        return (fresh, false)
    }

    static func copyBounded(_ source: URL, to destination: URL, maximumBytes: Int) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard try input.seekToEnd() <= UInt64(maximumBytes) else { throw EPUBError.limitExceeded }
        try input.seek(toOffset: 0)
        guard !FileManager.default.fileExists(atPath: destination.path),
              FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw EPUBError.invalidArchive }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var total = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            total += chunk.count
            guard total <= maximumBytes else { throw EPUBError.limitExceeded }
            try output.write(contentsOf: chunk)
        }
        guard total > 0 else { throw EPUBError.invalidArchive }
        try output.synchronize()
    }
}

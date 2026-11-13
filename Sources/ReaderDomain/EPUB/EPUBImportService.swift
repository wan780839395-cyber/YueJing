import Foundation

/// Off-MainActor serialized parsing and one exclusively owned, closed-reader workspace.
actor EPUBImportService {
    // Exclusive ownership: only successfully closed readers may return a workspace.
    // A take empties the slot synchronously, before validation or any caller await.
    private var closedPublication: EPUBPublication?

    deinit {
        if let closedPublication { try? FileManager.default.removeItem(at: closedPublication.resourceRoot) }
    }

    /// Consumes ownership even when cancelled. The caller must never remove this folder afterwards.
    func retainClosed(_ publication: EPUBPublication) {
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: publication.resourceRoot)
            return
        }
        let previous = closedPublication
        closedPublication = publication
        if let previous { try? FileManager.default.removeItem(at: previous.resourceRoot) }
    }

    func prepare(archiveURL: URL, destination: URL, observe: EPUBPreparationObserver? = nil) throws -> EPUBPublication {
        try Task.checkCancellation()
        let package = try EPUBPackageParser.parse(archiveURL: archiveURL, destination: destination, observe: observe)
        try Task.checkCancellation()
        return EPUBPublication(package: package, resourceRoot: destination)
    }
    func prepareForReading(archiveURL: URL, destination: URL, expected: EPUBPackage,
                           cache: URL) throws -> (publication: EPUBPublication, reused: Bool, timings: EPUBOpeningTimings) {
        var timings = EPUBOpeningTimings()
        var candidate = closedPublication
        closedPublication = nil
        defer {
            // Includes mismatch, source failure and cancellation; never touches a transferred folder.
            if let candidate { try? FileManager.default.removeItem(at: candidate.resourceRoot) }
        }
        try Task.checkCancellation()
        // Verify original bytes on every open; no mtime/size-only cache trust.
        guard try timings.measure(.sourceVerification, { try EPUBResourceStore.sourceDigest(archiveURL) }) == expected.sourceSHA256 else { throw LibraryError.changedFile }
        if let retained = candidate {
            do {
                guard retained.package == expected else { throw EPUBError.corruptResource }
                try timings.measure(.warmResourceVerification) { try EPUBPublicationCache.verifyResources(retained) }
                try Task.checkCancellation()
                candidate = nil // Transfer the exact directory, with no resource writes or copies.
                return (retained, true, timings)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A damaged or incompatible closed workspace falls back to the existing disk cache/parser.
                try? FileManager.default.removeItem(at: retained.resourceRoot)
                candidate = nil
            }
        }
        if let restored = try timings.measure(.diskRestore, { try EPUBPublicationCache.restore(package: expected, cache: cache, destination: destination) }) {
            try Task.checkCancellation()
            return (restored, true, timings)
        }
        let fresh = try timings.measure(.rebuild) { try prepare(archiveURL: archiveURL, destination: destination) }
        guard fresh.package == expected else { throw EPUBError.corruptResource }
        do {
            try timings.measure(.cacheWrite) { try EPUBPublicationCache.store(fresh, cache: cache) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A full verified open remains usable when optional caching runs out of disk space.
        }
        try Task.checkCancellation()
        return (fresh, false, timings)
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

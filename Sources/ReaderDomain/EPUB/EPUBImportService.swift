import Foundation

/// Parsing stays off MainActor and is serialized; only the caller-owned workspace is removed on failure.
actor EPUBImportService {
    func prepare(archiveURL: URL, destination: URL) throws -> EPUBPublication {
        try Task.checkCancellation()
        let package = try EPUBPackageParser.parse(archiveURL: archiveURL, destination: destination)
        try Task.checkCancellation()
        return EPUBPublication(package: package, resourceRoot: destination)
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

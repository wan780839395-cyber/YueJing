import CoreFoundation
import CryptoKit
import Foundation
import ZIPFoundation

public struct EPUBExtractedEntry: Sendable, Equatable {
    public let path: String
    public let byteCount: Int
    public let sha256: String
    public let crc32: UInt32
    public let compressionMethod: UInt16

    public init(path: String, byteCount: Int, sha256: String, crc32: UInt32, compressionMethod: UInt16) {
        self.path = path
        self.byteCount = byteCount
        self.sha256 = sha256
        self.crc32 = crc32
        self.compressionMethod = compressionMethod
    }
}

public struct EPUBArchiveExtraction: Sendable, Equatable {
    public let sourceSHA256: String
    public let compressedByteCount: Int
    public let totalExpandedBytes: Int
    public let entries: [String: EPUBExtractedEntry]

    public init(
        sourceSHA256: String,
        compressedByteCount: Int,
        totalExpandedBytes: Int,
        entries: [String: EPUBExtractedEntry]
    ) {
        self.sourceSHA256 = sourceSHA256
        self.compressedByteCount = compressedByteCount
        self.totalExpandedBytes = totalExpandedBytes
        self.entries = entries
    }
}

public enum EPUBArchive {
    private static let chunkSize = 64 * 1024

    public static func extract(
        archiveURL: URL,
        to destination: URL,
        limits: EPUBLimits = EPUBLimits()
    ) throws -> EPUBArchiveExtraction {
        try Task.checkCancellation()
        guard limits.compressedBytes > 0,
              limits.entries > 0,
              limits.expandedBytes > 0,
              limits.xhtmlBytes > 0,
              limits.imageBytes > 0,
              limits.xmlBytes > 0 else {
            throw EPUBError.limitExceeded
        }

        try prepareDestination(destination)
        do {
            let sourceValues = try archiveURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if sourceValues.isSymbolicLink == true {
                throw EPUBError.unsafePath
            }
            guard sourceValues.isRegularFile == true,
                  let fileSize = sourceValues.fileSize,
                  fileSize >= 22 else {
                throw EPUBError.invalidArchive
            }
            guard fileSize <= limits.compressedBytes else {
                throw EPUBError.limitExceeded
            }

            let handle = try FileHandle(forReadingFrom: archiveURL)
            defer { try? handle.close() }

            let sourceSHA256 = try streamSHA256(handle: handle, expectedSize: fileSize, maxBytes: limits.compressedBytes)
            let expectedEntries = try validateZIPStructure(handle: handle, fileSize: fileSize, limits: limits)

            let archive: Archive
            do { archive = try Archive(url: archiveURL, accessMode: .read) }
            catch { throw EPUBError.invalidArchive }

            var totalExpandedBytes = 0
            var iteratedCount = 0
            var extracted: [String: EPUBExtractedEntry] = [:]
            var seenCanonical = Set<String>()
            var seenLowercased = Set<String>()

            for entry in archive {
                try Task.checkCancellation()
                iteratedCount += 1
                guard iteratedCount <= limits.entries else {
                    throw EPUBError.limitExceeded
                }

                switch entry.type {
                case .symlink:
                    throw EPUBError.unsafePath
                case .directory:
                    let rawDir = entry.path
                    let trimmed = rawDir.hasSuffix("/") ? String(rawDir.dropLast()) : rawDir
                    if !trimmed.isEmpty {
                        let canonicalDir = try EPUBResourcePath.canonical(trimmed)
                        _ = try safeDestinationURL(for: canonicalDir, under: destination, isDirectory: true)
                    }
                case .file:
                    let canonicalPath = try EPUBResourcePath.canonical(entry.path)
                    let lowerPath = canonicalPath.lowercased()
                    guard seenCanonical.insert(canonicalPath).inserted,
                          seenLowercased.insert(lowerPath).inserted else {
                        throw EPUBError.unsafePath
                    }

                    let expectedMeta = expectedEntries[canonicalPath]
                    let method = expectedMeta?.compressionMethod ?? (entry.isCompressed ? 8 : 0)
                    guard method == 0 || method == 8 else {
                        throw EPUBError.unsupportedContent
                    }

                    let itemLimit = byteLimit(for: canonicalPath, limits: limits)
                    guard entry.uncompressedSize <= UInt64(itemLimit),
                          entry.uncompressedSize <= UInt64(limits.expandedBytes) else {
                        throw EPUBError.limitExceeded
                    }

                    let fileURL = try safeDestinationURL(for: canonicalPath, under: destination, isDirectory: false)
                    guard !FileManager.default.fileExists(atPath: fileURL.path),
                          FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                        throw EPUBError.unsafePath
                    }

                    let outHandle = try FileHandle(forWritingTo: fileURL)
                    defer { try? outHandle.close() }

                    var entryHasher = SHA256()
                    var entryBytes = 0
                    let computedCRC: CRC32
                    do {
                        computedCRC = try archive.extract(entry, bufferSize: chunkSize, skipCRC32: false) { chunk in
                            try Task.checkCancellation()
                            entryBytes += chunk.count
                            totalExpandedBytes += chunk.count
                            guard entryBytes <= itemLimit,
                                  totalExpandedBytes <= limits.expandedBytes else {
                                throw EPUBError.limitExceeded
                            }
                            if !chunk.isEmpty {
                                entryHasher.update(data: chunk)
                                try outHandle.write(contentsOf: chunk)
                            }
                        }
                    } catch let error as EPUBError {
                        throw error
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as Archive.ArchiveError {
                        switch error {
                        case .invalidCompressionMethod:
                            throw EPUBError.unsupportedContent
                        case .uncontainedSymlink, .invalidEntryPath:
                            throw EPUBError.unsafePath
                        default:
                            throw EPUBError.invalidArchive
                        }
                    } catch {
                        throw EPUBError.invalidArchive
                    }

                    try outHandle.synchronize()
                    guard computedCRC == entry.checksum else {
                        throw EPUBError.corruptResource
                    }
                    guard UInt64(entryBytes) == entry.uncompressedSize else {
                        throw EPUBError.invalidArchive
                    }
                    if let expectedMeta {
                        guard computedCRC == expectedMeta.crc32 else {
                            throw EPUBError.corruptResource
                        }
                        guard entryBytes == expectedMeta.uncompressedSize else {
                            throw EPUBError.invalidArchive
                        }
                    }

                    let digest = entryHasher.finalize().map { String(format: "%02x", $0) }.joined()
                    extracted[canonicalPath] = EPUBExtractedEntry(
                        path: canonicalPath,
                        byteCount: entryBytes,
                        sha256: digest,
                        crc32: computedCRC,
                        compressionMethod: method
                    )
                }
            }

            guard iteratedCount == expectedEntries.totalRecordCount,
                  extracted.count == expectedEntries.files.count,
                  !extracted.isEmpty else {
                throw EPUBError.invalidArchive
            }

            return EPUBArchiveExtraction(
                sourceSHA256: sourceSHA256,
                compressedByteCount: fileSize,
                totalExpandedBytes: totalExpandedBytes,
                entries: extracted
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private struct ExpectedFileMeta {
        let compressionMethod: UInt16
        let crc32: UInt32
        let uncompressedSize: Int
    }

    private struct ValidatedZIPIndex {
        let totalRecordCount: Int
        let files: [String: ExpectedFileMeta]
        subscript(_ path: String) -> ExpectedFileMeta? { files[path] }
    }

    private static func prepareDestination(_ destination: URL) throws {
        let fm = FileManager.default
        let targetPath = destination.standardizedFileURL.path
        let trustedRoots = [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), fm.temporaryDirectory]
            .map { $0.standardizedFileURL.path }
            .filter { targetPath.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        guard let boundary = trustedRoots.max(by: { $0.count < $1.count }) else { throw EPUBError.unsafePath }
        var current = destination.deletingLastPathComponent().standardizedFileURL
        while current.path.count >= boundary.count {
            if fm.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true { throw EPUBError.unsafePath }
            }
            if current.path == boundary { break }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { throw EPUBError.unsafePath }
            current = parent
        }

        if fm.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true || values.isDirectory != true {
                throw EPUBError.unsafePath
            }
            let existing = try fm.contentsOfDirectory(atPath: destination.path)
            guard existing.isEmpty else {
                throw EPUBError.invalidArchive
            }
        } else {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw EPUBError.unsafePath
            }
        }
    }

    private static func safeDestinationURL(for canonicalPath: String, under destination: URL, isDirectory: Bool) throws -> URL {
        let fm = FileManager.default
        let parts = canonicalPath.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { throw EPUBError.unsafePath }

        var url = destination
        let dirCount = isDirectory ? parts.count : (parts.count - 1)
        if dirCount > 0 {
            for index in 0..<dirCount {
                url.appendPathComponent(parts[index], isDirectory: true)
                if fm.fileExists(atPath: url.path) {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true || values.isDirectory != true {
                        throw EPUBError.unsafePath
                    }
                } else {
                    try fm.createDirectory(at: url, withIntermediateDirectories: false)
                }
            }
        }
        if !isDirectory {
            url.appendPathComponent(parts[parts.count - 1], isDirectory: false)
            if fm.fileExists(atPath: url.path) {
                throw EPUBError.unsafePath
            }
        }
        return url
    }

    private static func streamSHA256(handle: FileHandle, expectedSize: Int, maxBytes: Int) throws -> String {
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        var total = 0
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            total += chunk.count
            guard total <= maxBytes else {
                throw EPUBError.limitExceeded
            }
            hasher.update(data: chunk)
        }
        guard total == expectedSize else {
            throw EPUBError.invalidArchive
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validateZIPStructure(
        handle: FileHandle,
        fileSize: Int,
        limits: EPUBLimits
    ) throws -> ValidatedZIPIndex {
        let maxEOCDSearch = min(fileSize, 22 + 65535)
        let tailOffset = fileSize - maxEOCDSearch
        try handle.seek(toOffset: UInt64(tailOffset))
        guard let tail = try handle.read(upToCount: maxEOCDSearch),
              tail.count == maxEOCDSearch else {
            throw EPUBError.invalidArchive
        }

        var foundEOCD: Int?
        var pos = tail.count - 22
        while pos >= 0 {
            if uint32LE(tail, at: pos) == 0x06054B50 {
                let commentLength = Int(uint16LE(tail, at: pos + 20))
                if pos + 22 + commentLength == tail.count {
                    foundEOCD = pos
                    break
                }
            }
            pos -= 1
        }
        guard let eocdPos = foundEOCD else {
            throw EPUBError.invalidArchive
        }

        let eocdFileOffset = tailOffset + eocdPos
        let diskNumber = uint16LE(tail, at: eocdPos + 4)
        let cdStartDisk = uint16LE(tail, at: eocdPos + 6)
        let diskEntries = uint16LE(tail, at: eocdPos + 8)
        let totalEntries = uint16LE(tail, at: eocdPos + 10)
        let cdSizeRaw = uint32LE(tail, at: eocdPos + 12)
        let cdOffsetRaw = uint32LE(tail, at: eocdPos + 16)

        guard diskNumber == 0, cdStartDisk == 0, diskEntries == totalEntries else {
            throw EPUBError.invalidArchive
        }
        guard totalEntries > 0,
              totalEntries != 0xFFFF,
              cdSizeRaw != 0xFFFFFFFF,
              cdOffsetRaw != 0xFFFFFFFF else {
            throw EPUBError.invalidArchive
        }
        let recordCount = Int(totalEntries)
        guard recordCount <= limits.entries else {
            throw EPUBError.limitExceeded
        }

        let cdSize = Int(cdSizeRaw)
        let cdOffset = Int(cdOffsetRaw)
        guard cdOffset >= 0,
              cdSize > 0,
              cdOffset + cdSize <= eocdFileOffset,
              (eocdFileOffset - (cdOffset + cdSize) == 0 || eocdFileOffset - (cdOffset + cdSize) == 76) else {
            throw EPUBError.invalidArchive
        }

        try handle.seek(toOffset: UInt64(cdOffset))
        guard let cdData = try handle.read(upToCount: cdSize),
              cdData.count == cdSize else {
            throw EPUBError.invalidArchive
        }

        var cursor = 0
        var seenCanonical = Set<String>()
        var seenLower = Set<String>()
        var files: [String: ExpectedFileMeta] = [:]
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(recordCount)
        var cumulativeDeclaredUncompressed = 0

        for _ in 0..<recordCount {
            try Task.checkCancellation()
            guard cursor + 46 <= cdData.count,
                  uint32LE(cdData, at: cursor) == 0x02014B50 else {
                throw EPUBError.invalidArchive
            }

            let cdFlags = uint16LE(cdData, at: cursor + 8)
            let cdMethod = uint16LE(cdData, at: cursor + 10)
            let cdCRC = uint32LE(cdData, at: cursor + 16)
            let cdCompSizeRaw = uint32LE(cdData, at: cursor + 20)
            let cdUncompSizeRaw = uint32LE(cdData, at: cursor + 24)
            let nameLen = Int(uint16LE(cdData, at: cursor + 28))
            let extraLen = Int(uint16LE(cdData, at: cursor + 30))
            let commentLen = Int(uint16LE(cdData, at: cursor + 32))
            let diskStart = uint16LE(cdData, at: cursor + 34)
            let extAttr = uint32LE(cdData, at: cursor + 38)
            let lfhOffsetRaw = uint32LE(cdData, at: cursor + 42)

            let recordLen = 46 + nameLen + extraLen + commentLen
            guard diskStart == 0,
                  nameLen > 0,
                  cursor + recordLen <= cdData.count else {
                throw EPUBError.invalidArchive
            }

            if (cdFlags & 0x0001) != 0 || (cdFlags & 0x0040) != 0 || cdMethod == 99 {
                throw EPUBError.unsupportedContent
            }
            let extraStart = cursor + 46 + nameLen
            let extraData = cdData.subdata(in: extraStart..<(extraStart + extraLen))
            if hasEncryptionExtraField(extraData) {
                throw EPUBError.unsupportedContent
            }
            guard cdMethod == 0 || cdMethod == 8 else {
                throw EPUBError.unsupportedContent
            }

            let unixType = (extAttr >> 16) & 0xF000
            if unixType == 0xA000 || unixType == 0x1000 || unixType == 0x2000 || unixType == 0x6000 || unixType == 0xC000 {
                throw EPUBError.unsafePath
            }

            guard cdCompSizeRaw != 0xFFFFFFFF,
                  cdUncompSizeRaw != 0xFFFFFFFF,
                  lfhOffsetRaw != 0xFFFFFFFF else {
                throw EPUBError.invalidArchive
            }
            let cdCompSize = Int(cdCompSizeRaw)
            let cdUncompSize = Int(cdUncompSizeRaw)
            let lfhOffset = Int(lfhOffsetRaw)

            let nameData = cdData.subdata(in: (cursor + 46)..<(cursor + 46 + nameLen))
            guard let rawPath = decodeEntryPath(nameData, utf8Flag: (cdFlags & (1 << 11)) != 0),
                  !rawPath.isEmpty else {
                throw EPUBError.unsafePath
            }

            guard lfhOffset >= 0, lfhOffset + 30 <= cdOffset else {
                throw EPUBError.invalidArchive
            }
            try handle.seek(toOffset: UInt64(lfhOffset))
            guard let lfhData = try handle.read(upToCount: 30),
                  lfhData.count == 30,
                  uint32LE(lfhData, at: 0) == 0x04034B50 else {
                throw EPUBError.invalidArchive
            }

            let lfhFlags = uint16LE(lfhData, at: 6)
            let lfhMethod = uint16LE(lfhData, at: 8)
            let lfhCRC = uint32LE(lfhData, at: 14)
            let lfhCompSize = Int(uint32LE(lfhData, at: 18))
            let lfhUncompSize = Int(uint32LE(lfhData, at: 22))
            let lfhNameLen = Int(uint16LE(lfhData, at: 26))
            let lfhExtraLen = Int(uint16LE(lfhData, at: 28))

            if (lfhFlags & 0x0001) != 0 || (lfhFlags & 0x0040) != 0 || lfhMethod == 99 {
                throw EPUBError.unsupportedContent
            }
            guard lfhMethod == 0 || lfhMethod == 8 else {
                throw EPUBError.unsupportedContent
            }
            guard lfhMethod == cdMethod, lfhNameLen == nameLen else {
                throw EPUBError.invalidArchive
            }

            let dataStart = lfhOffset + 30 + lfhNameLen + lfhExtraLen
            guard dataStart <= cdOffset else {
                throw EPUBError.invalidArchive
            }
            guard let lfhVarData = try handle.read(upToCount: lfhNameLen + lfhExtraLen),
                  lfhVarData.count == lfhNameLen + lfhExtraLen else {
                throw EPUBError.invalidArchive
            }
            let lfhNameData = lfhVarData.subdata(in: 0..<lfhNameLen)
            guard lfhNameData == nameData else {
                throw EPUBError.invalidArchive
            }
            if lfhExtraLen > 0 {
                let lfhExtraData = lfhVarData.subdata(in: lfhNameLen..<(lfhNameLen + lfhExtraLen))
                if hasEncryptionExtraField(lfhExtraData) {
                    throw EPUBError.unsupportedContent
                }
            }

            let usesDataDescriptor = ((cdFlags & 0x0008) != 0) || ((lfhFlags & 0x0008) != 0)
            if !usesDataDescriptor {
                if lfhCRC != cdCRC {
                    throw EPUBError.corruptResource
                }
                guard lfhCompSize == cdCompSize, lfhUncompSize == cdUncompSize else {
                    throw EPUBError.invalidArchive
                }
            }

            let dataEnd = dataStart + cdCompSize
            guard cdCompSize >= 0, cdUncompSize >= 0, dataEnd <= cdOffset else {
                throw EPUBError.invalidArchive
            }
            if cdMethod == 0 && cdCompSize != cdUncompSize {
                throw EPUBError.invalidArchive
            }
            ranges.append(lfhOffset..<dataEnd)

            let isDirectory = rawPath.hasSuffix("/") || (unixType == 0x4000)
            if isDirectory {
                guard cdCompSize == 0, cdUncompSize == 0 else {
                    throw EPUBError.invalidArchive
                }
                let trimmed = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
                guard !trimmed.isEmpty else { throw EPUBError.unsafePath }
                let canonicalDir = try EPUBResourcePath.canonical(trimmed)
                guard seenCanonical.insert(canonicalDir).inserted,
                      seenLower.insert(canonicalDir.lowercased()).inserted else { throw EPUBError.unsafePath }
            } else {
                let canonical = try EPUBResourcePath.canonical(rawPath)
                let lower = canonical.lowercased()
                guard seenCanonical.insert(canonical).inserted,
                      seenLower.insert(lower).inserted else {
                    throw EPUBError.unsafePath
                }
                let itemMax = byteLimit(for: canonical, limits: limits)
                cumulativeDeclaredUncompressed += cdUncompSize
                guard cdUncompSize <= itemMax,
                      cumulativeDeclaredUncompressed <= limits.expandedBytes else {
                    throw EPUBError.limitExceeded
                }
                files[canonical] = ExpectedFileMeta(
                    compressionMethod: cdMethod,
                    crc32: cdCRC,
                    uncompressedSize: cdUncompSize
                )
            }

            cursor += recordLen
        }

        guard cursor == cdData.count, !files.isEmpty else {
            throw EPUBError.invalidArchive
        }

        ranges.sort { $0.lowerBound < $1.lowerBound }
        for index in 1..<ranges.count {
            if ranges[index - 1].upperBound > ranges[index].lowerBound {
                throw EPUBError.invalidArchive
            }
        }

        return ValidatedZIPIndex(totalRecordCount: recordCount, files: files)
    }

    private static func byteLimit(for canonicalPath: String, limits: EPUBLimits) -> Int {
        let lower = canonicalPath.lowercased()
        if lower.hasSuffix(".xml") || lower.hasSuffix(".opf") || lower.hasSuffix(".ncx") {
            return min(limits.xmlBytes, limits.expandedBytes)
        } else if lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm") {
            return min(limits.xhtmlBytes, limits.expandedBytes)
        } else if lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") {
            return min(limits.imageBytes, limits.expandedBytes)
        }
        return limits.expandedBytes
    }

    private static func hasEncryptionExtraField(_ data: Data) -> Bool {
        var index = 0
        while index + 4 <= data.count {
            let headerID = uint16LE(data, at: index)
            let dataSize = Int(uint16LE(data, at: index + 2))
            if headerID == 0x0017 || headerID == 0x9901 {
                return true
            }
            guard index + 4 + dataSize <= data.count else { break }
            index += 4 + dataSize
        }
        return false
    }

    private static func decodeEntryPath(_ data: Data, utf8Flag: Bool) -> String? {
        if utf8Flag {
            return String(data: data, encoding: .utf8)
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let dosLatinUS = CFStringEncoding(0x0400)
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(dosLatinUS)
        return String(data: data, encoding: String.Encoding(rawValue: nsEncoding))
    }

    private static func uint16LE(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func uint32LE(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}

import CryptoKit
import Foundation
import TXTCore

/// Non-Sendable, synchronous implementation owned exclusively by one source/storage actor.
final class DerivedPackReader {
    let manifest: DerivedManifest
    let budget: DerivedBookBudget
    private let file: FileHandle
    private let digests: Data
    private var cache: [Int: Data] = [:]
    private var recency: [Int] = []
    private var closed = false
    private var metadataBytes: Int { DerivedBookFormat.headerBytes + digests.count }
    private var cacheLimit: Int { budget.maximumWorkingBytes / 4 }

    init(url: URL, pointer: DerivedPointer, book: LibraryBook, budget: DerivedBookBudget) throws {
        let f = DerivedBookFormat.self
        try f.regularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        do {
            let size = try f.integer(handle.seekToEnd())
            guard size >= f.headerBytes else { throw DerivedStorageError.corruptArtifact }
            guard size == pointer.byteCount else { throw DerivedStorageError.corruptArtifact }
            guard size <= budget.maximumArtifactBytes else { throw DerivedStorageError.budgetExceeded }
            let header = try f.read(handle, offset: 0, count: f.headerBytes, maximumBytes: budget.maximumMetadataBytes)
            guard header.prefix(8) == f.magic, f.isDigest(pointer.manifestSHA256),
                  f.digest(header) == pointer.manifestSHA256 else { throw DerivedStorageError.corruptArtifact }
            let length = try f.int(header, at: 8)
            guard length > 0, length <= f.headerBytes - 16,
                  header[(16 + length)...].allSatisfy({ $0 == 0 }) else { throw DerivedStorageError.corruptArtifact }
            let value: DerivedManifest
            do { value = try JSONDecoder().decode(DerivedManifest.self, from: header.subdata(in: 16..<(16 + length))) }
            catch { throw DerivedStorageError.corruptArtifact }
            try value.validate(book: book, pointer: pointer, budget: budget, fileBytes: size)
            let digestOffset = try f.add(f.headerBytes, value.payloadBytes)
            let table = try f.read(handle, offset: digestOffset, count: size - digestOffset,
                                   maximumBytes: budget.maximumMetadataBytes - f.headerBytes)
            guard f.digest(table) == value.digestTableSHA256 else { throw DerivedStorageError.corruptArtifact }
            self.file = handle; self.manifest = value; self.budget = budget; self.digests = table
        } catch { try? handle.close(); throw error }
    }
    func close() { if !closed { closed = true; cache = [:]; recency = []; try? file.close() } }
    func clearCache() { cache = [:]; recency = [] }
    func verifyAllPages() throws {
        for page in 0..<(digests.count / 32) { _ = try checkedPage(page) }
        clearCache()
    }
    private func checkedPage(_ page: Int) throws -> Data {
        let f = DerivedBookFormat.self
        guard !closed else { throw DerivedStorageError.closed }
        guard page >= 0, page < digests.count / 32 else { throw DerivedStorageError.corruptArtifact }
        if let value = cache[page] {
            recency.removeAll { $0 == page }; recency.append(page); return value
        }
        let relative = try f.multiply(page, f.pageBytes)
        let count = min(f.pageBytes, manifest.payloadBytes - relative)
        let data = try f.read(file, offset: f.add(f.headerBytes, relative), count: count, maximumBytes: f.pageBytes)
        let expected = digests.subdata(in: (page * 32)..<(page * 32 + 32))
        guard Data(SHA256.hash(data: data)) == expected else { throw DerivedStorageError.corruptArtifact }
        // Charge twice the payload plus a fixed container allowance. This is accounting, not RSS.
        while (cache.count + 1) * (2 * f.pageBytes + 256) > cacheLimit, let oldest = recency.first {
            recency.removeFirst(); cache.removeValue(forKey: oldest)
        }
        if 2 * f.pageBytes + 256 <= cacheLimit { cache[page] = data; recency.append(page) }
        return data
    }
    func working(_ bytes: Int) throws {
        guard try DerivedBookFormat.add(DerivedBookFormat.add(metadataBytes, cacheLimit), bytes) <= budget.maximumWorkingBytes else {
            throw DerivedStorageError.budgetExceeded
        }
    }
    func read(section: Int, offset: Int, count: Int) throws -> Data {
        let f = DerivedBookFormat.self
        guard (0..<6).contains(section), offset >= 0, count >= 0 else { throw DerivedStorageError.corruptArtifact }
        let descriptor = manifest.sections[section], length = try f.integer(descriptor.length)
        guard offset <= length, count <= length - offset else { throw DerivedStorageError.corruptArtifact }
        try working(f.multiply(count, 4))
        var result = Data(); result.reserveCapacity(count)
        var cursor = try f.add(f.integer(descriptor.offset), offset), remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            let page = cursor / f.pageBytes, local = cursor % f.pageBytes
            let data = try checkedPage(page), amount = min(remaining, data.count - local)
            guard amount > 0 else { throw DerivedStorageError.corruptArtifact }
            result.append(data.subdata(in: local..<(local + amount))); cursor += amount; remaining -= amount
        }
        return result
    }
    private func checkpoint(_ number: Int) throws -> (raw: Int, utf16: Int) {
        let data = try read(section: 2, offset: DerivedBookFormat.multiply(number, 16), count: 16)
        let raw = try DerivedBookFormat.int(data, at: 0), utf16 = try DerivedBookFormat.int(data, at: 8)
        guard raw >= manifest.bomBytes, raw <= manifest.rawBytes, utf16 <= manifest.utf16Units else {
            throw DerivedStorageError.corruptArtifact
        }
        if number == 0, raw != manifest.bomBytes || utf16 != 0 { throw DerivedStorageError.corruptArtifact }
        return (raw, utf16)
    }
    func exact(_ value: Int, raw: Bool) throws -> TXTBoundary {
        let invalid: TXTError = raw ? .invalidByteBoundary(RawByteOffset(value)) : .invalidUTF16Boundary(UTF16Offset(value))
        guard value >= (raw ? manifest.bomBytes : 0), value <= (raw ? manifest.rawBytes : manifest.utf16Units) else { throw invalid }
        var low = 0, high = manifest.scalars / 256 + 1
        while low < high {
            let middle = low + (high - low) / 2, point = try checkpoint(middle)
            if (raw ? point.raw : point.utf16) <= value { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { throw DerivedStorageError.corruptArtifact }
        let number = low - 1, point = try checkpoint(number)
        let start = number * 256, count = min(256, manifest.scalars - start)
        let widths = try read(section: 1, offset: start, count: count)
        var r = point.raw, u = point.utf16
        var match: TXTBoundary? = (raw ? r : u) == value ? TXTBoundary(rawByte: RawByteOffset(r), utf16: UTF16Offset(u)) : nil
        for width in widths {
            guard (1...8).contains(Int(width >> 1)) else { throw DerivedStorageError.corruptArtifact }
            r = try DerivedBookFormat.add(r, Int(width >> 1)); u = try DerivedBookFormat.add(u, Int(width & 1) + 1)
            if (raw ? r : u) == value { match = TXTBoundary(rawByte: RawByteOffset(r), utf16: UTF16Offset(u)) }
        }
        let end: (raw: Int, utf16: Int)
        if number + 1 < manifest.scalars / 256 + 1 { end = try checkpoint(number + 1) }
        else { end = (raw: manifest.rawBytes, utf16: manifest.utf16Units) }
        guard r == end.raw, u == end.utf16 else { throw DerivedStorageError.corruptArtifact }
        guard let match else { throw invalid }; return match
    }
    func text(_ range: UTF16Range) throws -> DerivedTextFragment {
        let f = DerivedBookFormat.self
        guard range.length <= budget.maximumReadUTF16 else { throw DerivedStorageError.budgetExceeded }
        guard range.end.value <= manifest.utf16Units else { throw TXTError.invalidRange }
        try working(f.multiply(range.length, 16))
        let start = try exact(range.location.value, raw: false).rawByte
        let end = try exact(range.end.value, raw: false).rawByte
        let data = try read(section: 0, offset: f.multiply(range.location.value, 2), count: f.multiply(range.length, 2))
        return DerivedTextFragment(text: try f.strictUTF16(data), range: range,
                                  rawRange: try RawByteRange(location: start, length: end.value - start.value))
    }
    func composedStart(_ location: Int) throws -> Int {
        let f = DerivedBookFormat.self
        guard location >= 0, location <= manifest.utf16Units else { throw TXTError.invalidRange }
        if location == manifest.utf16Units { return location }
        let block = location / f.graphemeUnits, base = block * f.graphemeUnits
        let data = try read(section: 3, offset: f.multiply(block, f.graphemeRecordBytes), count: f.graphemeRecordBytes)
        let predecessor = try f.int(data, at: 0)
        guard predecessor <= base else { throw DerivedStorageError.corruptArtifact }
        var found = predecessor
        for local in stride(from: location - base, through: 0, by: -1) {
            if data[8 + local / 8] & UInt8(1 << (local % 8)) != 0 { found = base + local; break }
        }
        _ = try exact(found, raw: false)
        return found
    }
    func chapters(start: Int, limit: Int) throws -> [TXTChapter] {
        let f = DerivedBookFormat.self
        guard start >= 0, start <= manifest.chapters, limit > 0 else { throw TXTError.invalidRange }
        guard limit <= budget.maximumChapterEntries else { throw DerivedStorageError.budgetExceeded }
        let count = min(limit, manifest.chapters - start)
        try working(f.multiply(count, 1024))
        var result: [TXTChapter] = []; result.reserveCapacity(count)
        for index in start..<(start + count) {
            let data = try read(section: 4, offset: f.multiply(index, f.chapterRecordBytes), count: f.chapterRecordBytes)
            let raw = try f.int(data, at: 0), rawLength = try f.int(data, at: 8)
            let utf16 = try f.int(data, at: 16), length = try f.int(data, at: 24), titleOffset = try f.int(data, at: 32)
            let titleLength = try f.uint64(data, at: 40)
            _ = try f.add(utf16, length); _ = try f.add(raw, rawLength)
            let titleSectionLength = try f.integer(manifest.sections[5].length)
            guard titleOffset <= titleSectionLength else { throw DerivedStorageError.corruptArtifact }
            let range = try UTF16Range(location: UTF16Offset(utf16), length: length)
            guard length > 0, range.end.value <= manifest.utf16Units,
                  try exact(utf16, raw: false).rawByte.value == raw,
                  try exact(range.end.value, raw: false).rawByte.value == f.add(raw, rawLength),
                  index != 0 || utf16 == 0,
                  index != manifest.chapters - 1 || range.end.value == manifest.utf16Units else { throw DerivedStorageError.corruptArtifact }
            if index > 0 {
                let previous = try read(section: 4, offset: f.multiply(index - 1, f.chapterRecordBytes), count: f.chapterRecordBytes)
                guard try f.add(f.int(previous, at: 16), f.int(previous, at: 24)) == utf16 else { throw DerivedStorageError.corruptArtifact }
            }
            let title: String?
            if titleLength == UInt64.max { title = nil }
            else {
                let bytes = try f.integer(titleLength)
                guard bytes <= 240 else { throw DerivedStorageError.corruptArtifact }
                let data = try read(section: 5, offset: titleOffset, count: bytes)
                guard let value = String(data: data, encoding: .utf8), value.utf16.count <= 80,
                      value.rangeOfCharacter(from: .newlines) == nil else { throw DerivedStorageError.corruptArtifact }
                title = value
            }
            result.append(TXTChapter(id: "\(manifest.versionID):\(raw)", documentVersion: manifest.versionID,
                title: title, utf16Range: range, rawByteRange: try RawByteRange(location: RawByteOffset(raw), length: rawLength)))
        }
        return result
    }
}

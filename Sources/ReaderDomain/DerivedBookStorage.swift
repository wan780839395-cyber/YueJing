import CryptoKit
import Foundation
import TXTCore

/// All full-document export work remains off MainActor. No import/reader calls this implicitly.
actor DerivedBookStorage {
    func stage(document: TXTDocument, chapters: [TXTChapter], permit: DerivedBuildPermit, url: URL,
               budget: DerivedBookBudget, inject: DerivedBuildInjection?) throws -> PreparedDerivedBook {
        let f = DerivedBookFormat.self, book = permit.book
        guard document.documentID == book.id, document.versionID == book.versionID,
              document.encoding.rawValue == book.encodingRaw, document.originalBytes.count == book.byteCount,
              document.utf16Count == book.utf16Count else { throw DerivedStorageError.versionMismatch }
        guard !chapters.isEmpty else { throw DerivedStorageError.corruptArtifact }
        let scalars = document.offsets.boundaryCount - 1
        var titleBytes = 0
        for chapter in chapters {
            try Task.checkCancellation()
            guard chapter.documentVersion == book.versionID, (chapter.title?.utf16.count ?? 0) <= 80 else {
                throw DerivedStorageError.versionMismatch
            }
            titleBytes = try f.add(titleBytes, chapter.title?.utf8.count ?? 0)
        }
        let lengths = [try f.multiply(document.utf16Count, 2), scalars,
                       try f.multiply(scalars / 256 + 1, 16),
                       try f.multiply((document.utf16Count - 1) / f.graphemeUnits + 1, f.graphemeRecordBytes),
                       try f.multiply(chapters.count, f.chapterRecordBytes), titleBytes]
        var sections: [DerivedSection] = [], cursor = 0
        for length in lengths {
            sections.append(DerivedSection(offset: UInt64(cursor), length: UInt64(length)))
            cursor = try f.add(cursor, length)
        }
        let digestBytes = try f.multiply((cursor - 1) / f.pageBytes + 1, 32)
        let fileBytes = try f.add(f.add(f.headerBytes, cursor), digestBytes)
        guard fileBytes <= budget.maximumArtifactBytes,
              try f.add(digestBytes, f.headerBytes) <= budget.maximumMetadataBytes else { throw DerivedStorageError.budgetExceeded }
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(atPath: url.path, contents: nil) else { throw DerivedStorageError.staleBuild }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.write(contentsOf: Data(repeating: 0, count: f.headerBytes))
        try inject?(.staged)
        let writer = DerivedPayloadWriter(file: file, budget: budget)
        try document.forEachUTF16Chunk { try writer.append($0) }
        try document.offsets.forEachWidthChunk { _, _, widths in try writer.append(Data(widths)) }
        try document.offsets.forEachWidthChunk { _, boundary, _ in
            var data = Data(); f.append(UInt64(boundary.rawByte.value), to: &data)
            f.append(UInt64(boundary.utf16.value), to: &data); try writer.append(data)
        }
        if scalars % 256 == 0 {
            var data = Data(); f.append(UInt64(book.byteCount), to: &data)
            f.append(UInt64(book.utf16Count), to: &data); try writer.append(data)
        }
        // Build global boundaries from the SAME complete NSString semantics used by the old engine.
        // A block contains a predecessor even when a single cluster spans arbitrarily many blocks.
        let text = document.text as NSString
        var boundaryStart = 0, nextBoundary = 0
        func advanceBoundary() throws {
            try Task.checkCancellation()
            let range = text.rangeOfComposedCharacterSequence(at: nextBoundary)
            guard range.location == nextBoundary, range.length > 0, range.length <= text.length - nextBoundary else {
                throw DerivedStorageError.corruptArtifact
            }
            boundaryStart = nextBoundary; nextBoundary += range.length
        }
        for start in stride(from: 0, to: text.length, by: f.graphemeUnits) {
            try Task.checkCancellation()
            let end = min(text.length, start + f.graphemeUnits)
            while nextBoundary <= start, nextBoundary < text.length { try advanceBoundary() }
            var data = Data(); f.append(UInt64(boundaryStart), to: &data)
            var bits = Data(repeating: 0, count: f.graphemeUnits / 8)
            if boundaryStart == start { bits[0] |= 1 }
            while nextBoundary < end {
                let local = nextBoundary - start
                guard local >= 0 else { throw DerivedStorageError.corruptArtifact }
                bits[local / 8] |= UInt8(1 << (local % 8)); try advanceBoundary()
            }
            data.append(bits); try writer.append(data)
        }
        var titleOffset = 0, chapterEnd = 0
        for chapter in chapters {
            try Task.checkCancellation()
            guard chapter.utf16Range.location.value == chapterEnd,
                  chapter.utf16Range.end.value <= book.utf16Count,
                  try document.offsets.rawByteRange(for: chapter.utf16Range) == chapter.rawByteRange,
                  chapter.id == "\(book.versionID):\(chapter.rawByteRange.location.value)" else {
                throw DerivedStorageError.corruptArtifact
            }
            chapterEnd = chapter.utf16Range.end.value
            var data = Data()
            for value in [chapter.rawByteRange.location.value, chapter.rawByteRange.length,
                          chapter.utf16Range.location.value, chapter.utf16Range.length, titleOffset] {
                f.append(UInt64(value), to: &data)
            }
            f.append(chapter.title.map { UInt64($0.utf8.count) } ?? UInt64.max, to: &data)
            try writer.append(data); titleOffset = try f.add(titleOffset, chapter.title?.utf8.count ?? 0)
        }
        guard chapterEnd == book.utf16Count else { throw DerivedStorageError.corruptArtifact }
        for chapter in chapters { if let title = chapter.title { try writer.append(Data(title.utf8)) } }
        try writer.finish()
        guard writer.payloadBytes == cursor, writer.digests.count == digestBytes else { throw DerivedStorageError.corruptArtifact }
        try inject?(.payloadWritten)
        let manifest = DerivedManifest(schema: 1, bookID: book.id, versionID: book.versionID,
            generation: permit.generation, encoding: book.encodingRaw, bomBytes: document.bomByteCount,
            rawBytes: book.byteCount, utf16Units: book.utf16Count, scalars: scalars, chapters: chapters.count,
            normalization: TXTDocument.normalizationVersion, decoder: f.decoderRevision,
            chapterRules: f.chapterRevision, graphemes: f.graphemeRevision, sections: sections,
            payloadBytes: cursor, digestTableSHA256: f.digest(writer.digests))
        let header = try manifest.header()
        let pointer = DerivedPointer(bookID: book.id, versionID: book.versionID, generation: permit.generation,
                                     manifestSHA256: f.digest(header), byteCount: fileBytes)
        try manifest.validate(book: book, pointer: pointer, budget: budget, fileBytes: fileBytes)
        try file.write(contentsOf: writer.digests)
        try file.seek(toOffset: 0); try file.write(contentsOf: header)
        try file.synchronize(); try inject?(.synchronized)
        try Task.checkCancellation()
        // Read-back all pages using the production validator before publishing the pointer.
        let verifier = try DerivedPackReader(url: url, pointer: pointer, book: book, budget: budget)
        try verifier.verifyAllPages(); verifier.close()
        return PreparedDerivedBook(pointer: pointer)
    }
}

private final class DerivedPayloadWriter {
    let file: FileHandle
    let budget: DerivedBookBudget
    var pending = Data()
    private(set) var payloadBytes = 0
    private(set) var digests = Data()
    init(file: FileHandle, budget: DerivedBookBudget) { self.file = file; self.budget = budget }

    func append(_ data: Data) throws {
        let f = DerivedBookFormat.self
        var position = 0
        while position < data.count {
            try Task.checkCancellation()
            let count = min(f.pageBytes - pending.count, data.count - position)
            pending.append(data.subdata(in: position..<(position + count))); position += count
            payloadBytes = try f.add(payloadBytes, count)
            guard try f.add(f.headerBytes, payloadBytes) <= budget.maximumArtifactBytes else { throw DerivedStorageError.budgetExceeded }
            if pending.count == f.pageBytes { try flush() }
        }
    }
    func finish() throws { if !pending.isEmpty { try flush() } }
    private func flush() throws {
        guard try DerivedBookFormat.add(digests.count, 32 + DerivedBookFormat.headerBytes) <= budget.maximumMetadataBytes else {
            throw DerivedStorageError.budgetExceeded
        }
        try file.write(contentsOf: pending); digests.append(contentsOf: SHA256.hash(data: pending))
        pending.removeAll(keepingCapacity: true)
    }
}

import CryptoKit
import Foundation
import TXTCore

public struct OpenedBook: Sendable {
    public let book: LibraryBook
    public let document: TXTDocument
    public let chapters: [TXTChapter]
    public let reading: ReadingStart
}

public actor LibraryService {
    public nonisolated let store: LibraryStore
    private let processor = TXTProcessor()
    private let derivedStorage = DerivedBookStorage()
    private struct Pending { let bytes: Data; let title: String; let encodings: [TXTEncoding] }
    private var pending: [UUID: Pending] = [:]
    private var cancelled: Set<UUID> = []
    private var processed: ProcessedBookCache
    private var reuse = ProcessingReuseStatistics()
    private var readingReuse = ReadingRouteStatistics()
    private struct ReadingBuild: Sendable {
        let id: UUID
        let bookID: String
        let versionID: String
        let encoding: String
        let task: Task<DerivedBookMetadata, Error>
        var consumers: Set<UUID>
    }
    private var readingBuild: ReadingBuild?

    public init(store: LibraryStore, processingCacheLimit: Int = 64 * 1024 * 1024) {
        self.store = store; processed = ProcessedBookCache(limit: processingCacheLimit)
    }

    /// Drops the service's reference and invalidates in-flight publishers. Active readers may retain theirs.
    public func releaseProcessingCache() { processed.invalidate(); readingBuild?.task.cancel() }

    func processingReuseStatistics() -> ProcessingReuseStatistics {
        var value = reuse; value.retainedBytes = processed.estimatedBytes; return value
    }

    public static func openDefault() async throws -> LibraryService {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true).appendingPathComponent("YueJing", isDirectory: true)
        return LibraryService(store: try LibraryStore(root: folder))
    }

    public func prepareImport(url: URL, ticket: UUID, measure: ProcessingMeasurementObserver? = nil,
                              observe: ImportStageObserver? = nil) async throws -> ImportPreparation {
        try await prepareImportCore(url: url, ticket: ticket, derivedBudget: nil, measure: measure, observe: observe)
    }
    public func prepareReadingImport(url: URL, ticket: UUID, budget: DerivedBookBudget,
                                    measure: ProcessingMeasurementObserver? = nil,
                                    observe: ImportStageObserver? = nil) async throws -> ImportPreparation {
        try await prepareImportCore(url: url, ticket: ticket, derivedBudget: budget, measure: measure, observe: observe)
    }
    private func prepareImportCore(url: URL, ticket: UUID, derivedBudget: DerivedBookBudget?,
                                  measure: ProcessingMeasurementObserver?, observe: ImportStageObserver?) async throws -> ImportPreparation {
        let generation = processed.begin()
        try await store.beginImport(ticket)
        let staging = await store.stagingURL(ticket: ticket)
        var keepForChoice = false
        defer { if !keepForChoice { Self.removeStaging(staging) } }
        try check(ticket)
        guard url.isFileURL, url.pathExtension.lowercased() == "txt" else { throw LibraryError.notTXT }
        try ProcessingMeasurement.timed(.privateCopy, observe: measure) {
            try Self.copyReadOnlySource(url, to: staging, observe: observe)
        }
        try check(ticket)
        observe?(.stagedReadStarted)
        let data = try ProcessingMeasurement.timed(.read, observe: measure) { try Data(contentsOf: staging, options: .mappedIfSafe) }
        observe?(.stagedReadCompleted)
        guard !data.isEmpty else { throw LibraryError.emptyFile }
        let identity = ProcessingMeasurement.timed(.hash, observe: measure) { Self.identity(data) }
        if let existing = try await store.book(id: identity) {
            try check(ticket)
            observe?(.duplicateFound)
            let receipt = try await store.commitImport(ticket: ticket, proposed: existing)
            observe?(.committed)
            if let derivedBudget { await persistImported(receipt, document: nil, budget: derivedBudget, measure: measure) }
            return .completed(receipt)
        }
        let title = url.deletingPathExtension().lastPathComponent
        do {
            observe?(.decodingStarted)
            let document = try await decode(data, measure: measure)
            observe?(.decodingCompleted)
            guard document.utf16Count > 0 else { throw LibraryError.emptyFile }
            try check(ticket)
            let receipt = try await store.commitImport(ticket: ticket, proposed: Self.book(document, title: title))
            if derivedBudget == nil, !receipt.duplicate, !Task.isCancelled { processed.retain(document, chapters: nil, book: receipt.book, token: generation) }
            observe?(.committed)
            if let derivedBudget { await persistImported(receipt, document: document, budget: derivedBudget, measure: measure) }
            return .completed(receipt)
        } catch TXTError.ambiguousEncoding(let candidates) {
            observe?(.ambiguityDetected)
            let cards = try await previews(data, encodings: candidates.map(\.encoding), measure: measure)
            observe?(.previewsReady)
            try check(ticket)
            pending[ticket] = Pending(bytes: data, title: title, encodings: candidates.map(\.encoding))
            keepForChoice = true
            return .choose(EncodingChoice(id: ticket, cards: cards))
        }
    }

    public func confirmImport(ticket: UUID, encoding: TXTEncoding, measure: ProcessingMeasurementObserver? = nil,
                              observe: ImportStageObserver? = nil) async throws -> ImportReceipt {
        try await confirmImportCore(ticket: ticket, encoding: encoding, derivedBudget: nil, measure: measure, observe: observe)
    }
    public func confirmReadingImport(ticket: UUID, encoding: TXTEncoding, budget: DerivedBookBudget,
                                     measure: ProcessingMeasurementObserver? = nil,
                                     observe: ImportStageObserver? = nil) async throws -> ImportReceipt {
        try await confirmImportCore(ticket: ticket, encoding: encoding, derivedBudget: budget, measure: measure, observe: observe)
    }
    private func confirmImportCore(ticket: UUID, encoding: TXTEncoding, derivedBudget: DerivedBookBudget?,
                                  measure: ProcessingMeasurementObserver?, observe: ImportStageObserver?) async throws -> ImportReceipt {
        let generation = processed.begin()
        guard let candidate = pending.removeValue(forKey: ticket) else { throw CancellationError() }
        let staging = await store.stagingURL(ticket: ticket)
        defer { Self.removeStaging(staging) }
        try check(ticket)
        guard candidate.encodings.contains(encoding) else { throw LibraryError.invalidEncoding }
        observe?(.decodingStarted)
        let document = try await decode(candidate.bytes, using: encoding, measure: measure)
        observe?(.decodingCompleted)
        guard document.utf16Count > 0 else { throw LibraryError.emptyFile }
        try check(ticket)
        let receipt = try await store.commitImport(ticket: ticket, proposed: Self.book(document, title: candidate.title))
        if derivedBudget == nil, !receipt.duplicate, !Task.isCancelled { processed.retain(document, chapters: nil, book: receipt.book, token: generation) }
        observe?(.committed)
        if let derivedBudget { await persistImported(receipt, document: document, budget: derivedBudget, measure: measure) }
        return receipt
    }

    public func cancelImport(_ ticket: UUID) async -> ImportCancellation {
        processed.invalidate()
        cancelled.insert(ticket)
        pending.removeValue(forKey: ticket)
        let result = await store.cancelImport(ticket)
        let url = await store.stagingURL(ticket: ticket)
        Self.removeStaging(url)
        return result
    }

    public func openBook(id: String, measure: ProcessingMeasurementObserver? = nil) async throws -> OpenedBook {
        let generation = processed.begin(bookID: id)
        var completed = false
        defer { if !completed { processed.invalidate(ifCurrent: generation) } }
        guard let book = try await store.book(id: id) else { throw LibraryError.missingBook }
        guard let encoding = book.encoding else { throw LibraryError.invalidEncoding }
        let url = try await store.fileURL(bookID: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryError.missingFile }
        let data = try ProcessingMeasurement.timed(.read, observe: measure) { try Data(contentsOf: url, options: .mappedIfSafe) }
        // Always inspect actual bytes, including on a warm hit. Size/mtime cannot prove integrity.
        guard ProcessingMeasurement.timed(.hash, observe: measure, { Self.identity(data) }) == book.id else { throw LibraryError.changedFile }
        let cached = processed.lookup(book, token: generation)
        let document: TXTDocument
        if let cached { document = cached.document; reuse.documentHits += 1 }
        else {
            do { document = try await decode(data, using: encoding, measure: measure) }
            catch is CancellationError { throw CancellationError() }
            catch { throw LibraryError.changedFile }
        }
        guard document.documentID == book.id, document.versionID == book.versionID else { throw LibraryError.changedFile }
        let chapters: [TXTChapter]
        if let ready = cached?.chapters { chapters = ready; reuse.chapterHits += 1 }
        else {
            reuse.chapterCalls += 1
            let start = ContinuousClock().now
            defer { ProcessingMeasurement.finish(.chapters, since: start, observe: measure) }
            chapters = try await processor.chapters(in: document)
        }
        try Task.checkCancellation()
        let start = try await store.beginReading(bookID: id, versionID: document.versionID)
        do {
            try Task.checkCancellation()
            let valid = start.anchor.flatMap { anchor -> ReadingAnchor? in
                (try? document.offsets.utf16Offset(for: RawByteOffset(anchor.rawByteOffset))) != nil ? anchor : nil
            }
            let reading = ReadingStart(session: start.session, anchor: valid,
                                       ignoredIncompatibleProgress: start.ignoredIncompatibleProgress || (start.anchor != nil && valid == nil))
            if Task.isCancelled { processed.invalidate(ifCurrent: generation) }
            else { processed.retain(document, chapters: chapters, book: book, token: generation) }
            completed = true
            return OpenedBook(book: book, document: document, chapters: chapters, reading: reading)
        } catch {
            try? await store.finishReading(session: start.session, anchor: nil, sequence: 1)
            throw error
        }
    }

    private static func identity(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func decode(_ bytes: Data, using encoding: TXTEncoding? = nil,
                        measure: ProcessingMeasurementObserver? = nil) async throws -> TXTDocument {
        reuse.decodeCalls += 1
        let start = ContinuousClock().now
        defer { ProcessingMeasurement.finish(.decode, since: start, observe: measure) }
        let observer: TXTDecodeObserver?
        if let measure { observer = { value in ProcessingMeasurement.decoder(value, observe: measure) } }
        else { observer = nil }
        return try await processor.decode(bytes, using: encoding, observe: observer)
    }

    private func previews(_ data: Data, encodings: [TXTEncoding], measure: ProcessingMeasurementObserver?) async throws -> [EncodingCard] {
        var documents: [TXTDocument] = []
        for encoding in encodings {
            try Task.checkCancellation()
            documents.append(try await decode(data, using: encoding, measure: measure))
        }
        guard let reference = documents.first else { throw LibraryError.invalidEncoding }
        var firstDifference = data.count
        for other in documents.dropFirst() {
            var left = reference.text.unicodeScalars.makeIterator(), right = other.text.unicodeScalars.makeIterator()
            var position = 0, checked = 0
            while let scalar = left.next() {
                if checked % 1024 == 0 { try Task.checkCancellation() }; checked += 1
                guard scalar == right.next() else {
                    firstDifference = min(firstDifference, try reference.offsets.rawByteOffset(for: UTF16Offset(position)).value)
                    break
                }
                position += scalar.value > 0xFFFF ? 2 : 1
            }
        }
        // Use one original-byte interval for every card, including differences beyond the first 80 graphemes.
        var start = max(0, min(data.count, firstDifference) - 80)
        while start > 0 && !documents.allSatisfy({ (try? $0.offsets.utf16Offset(for: RawByteOffset(start))) != nil }) { start -= 1 }
        var end = min(data.count, start + 240)
        while end < data.count && !documents.allSatisfy({ (try? $0.offsets.utf16Offset(for: RawByteOffset(end))) != nil }) { end += 1 }
        let interval = try RawByteRange(location: RawByteOffset(start), length: end - start)
        return try documents.map { document in
            let range = try document.offsets.utf16Range(for: interval)
            let snippet = (document.text as NSString).substring(with: range.nsRange)
            return EncodingCard(encoding: document.encoding, text: snippet)
        }
    }

    private func check(_ ticket: UUID) throws {
        try Task.checkCancellation()
        if cancelled.contains(ticket) { throw CancellationError() }
    }

    private static func book(_ document: TXTDocument, title: String) -> LibraryBook {
        LibraryBook(id: document.documentID, title: title, encodingRaw: document.encoding.rawValue,
                    versionID: document.versionID, byteCount: document.originalBytes.count, utf16Count: document.utf16Count)
    }

    private static func copyReadOnlySource(_ source: URL, to destination: URL, observe: ImportStageObserver?) throws {
        observe?(.scopeRequested)
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        observe?(access ? .scopeGranted : .scopeNotGranted)
        observe?(.sourceMetadataStarted)
        try Self.requireRegularFile(source)
        observe?(.sourceMetadataChecked)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?, copyError: Error?
        observe?(.coordinationStarted)
        coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
            observe?(.accessorStarted)
            do {
                try Self.requireRegularFile(readable)
                observe?(.coordinatedMetadataChecked)
                try FileManager.default.copyItem(at: readable, to: destination)
                // copyItem must never leave an external symbolic link as the managed "copy".
                try Self.requireRegularFile(destination)
                observe?(.copyCompleted)
            }
            catch { copyError = error }
        }
        observe?(.coordinationFinished)
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    private static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryError.notRegularFile }
    }

    private static func removeStaging(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
    }
}

extension LibraryService {
    /// Explicit construction also remains available as a regression/maintenance entry point.
    @discardableResult
    public func buildDerivedBook(id: String, budget: DerivedBookBudget) async throws -> DerivedBookMetadata {
        try await buildDerivedBook(id: id, budget: budget, inject: nil)
    }

    @discardableResult
    func buildDerivedBook(id: String, budget: DerivedBookBudget,
                          inject: DerivedBuildInjection?, imported: TXTDocument? = nil,
                          measure: ProcessingMeasurementObserver? = nil,
                          evictUnleased: Bool = false) async throws -> DerivedBookMetadata {
        let began = ContinuousClock().now
        defer { ProcessingMeasurement.finish(.derivedBuild, since: began, observe: measure) }
        let permit = try await store.reserveDerived(bookID: id, budget: budget, evictUnleased: evictUnleased)
        do {
            let book = permit.book
            guard let encoding = book.encoding else { throw LibraryError.invalidEncoding }
            let document: TXTDocument
            if let imported {
                document = imported; readingReuse.importedDocumentReuses += 1
            } else {
            let url = try await store.fileURL(bookID: id)
            guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryError.missingFile }
            do { try DerivedBookFormat.regularFile(url) }
            catch DerivedStorageError.corruptArtifact { throw LibraryError.notRegularFile }
            // Initial construction is deliberately the old complete decode/chapters algorithm.
            guard book.byteCount > 0 else { throw LibraryError.changedFile }
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            guard try input.seekToEnd() == UInt64(book.byteCount) else { throw LibraryError.changedFile }
            let bytes: Data
            do { bytes = try DerivedBookFormat.read(input, offset: 0, count: book.byteCount, maximumBytes: book.byteCount) }
            catch DerivedStorageError.corruptArtifact { throw LibraryError.changedFile }
            guard try input.seekToEnd() == UInt64(book.byteCount) else { throw LibraryError.changedFile }
            readingReuse.documentDecodes += 1
            do { document = try await processor.decode(bytes, using: encoding) }
            catch is CancellationError { throw CancellationError() }
            catch { throw LibraryError.changedFile }
            }
            guard document.documentID == book.id else { throw LibraryError.changedFile }
            guard document.versionID == book.versionID else { throw DerivedStorageError.versionMismatch }
            readingReuse.chapterBuilds += 1
            let chapterStart = ContinuousClock().now
            let chapters = try await processor.chapters(in: document)
            ProcessingMeasurement.finish(.chapters, since: chapterStart, observe: measure)
            let stage = try await store.derivedStagingURL(permit)
            let prepared = try await derivedStorage.stage(document: document, chapters: chapters, permit: permit,
                                                         url: stage, budget: budget, inject: inject)
            _ = try await store.publishDerived(prepared, permit: permit, inject: inject)
            return DerivedBookMetadata(bookID: id, versionID: book.versionID, encoding: encoding,
                bomByteCount: document.bomByteCount, byteCount: book.byteCount, utf16Count: book.utf16Count,
                chapterCount: chapters.count)
        } catch { await store.abandonDerived(permit); throw error }
    }

    /// At most one rebuild on opening failure. Mid-read corruption invalidates that handle;
    /// callers may explicitly reopen with rebuildIfNeeded, never silently loop or move progress.
    public func openDerivedBook(id: String, budget: DerivedBookBudget,
                                rebuildIfNeeded: Bool = false) async throws -> DerivedBookSource {
        do { return try await openDerivedOnce(id: id, budget: budget) }
        catch let failure as DerivedStorageError {
            guard rebuildIfNeeded, [.missingArtifact, .corruptArtifact, .incompatibleFormat, .versionMismatch].contains(failure) else { throw failure }
            _ = try await buildDerivedBook(id: id, budget: budget)
            return try await openDerivedOnce(id: id, budget: budget)
        }
    }

    private func openDerivedOnce(id: String, budget: DerivedBookBudget,
                                 measure: ProcessingMeasurementObserver? = nil) async throws -> DerivedBookSource {
        guard let book = try await store.book(id: id) else { throw LibraryError.missingBook }
        let lease: DerivedLease?
        do { lease = try await store.leaseDerived(bookID: id) }
        catch DerivedStorageError.missingArtifact { lease = nil }
        do {
            // Even an absent/broken cache never masks a missing/changed original.
            let url = try await store.fileURL(bookID: id)
            guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryError.missingFile }
            do { try DerivedBookFormat.regularFile(url) }
            catch DerivedStorageError.corruptArtifact { throw LibraryError.notRegularFile }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let verificationStart = ContinuousClock().now
            guard book.byteCount > 0, try file.seekToEnd() == UInt64(book.byteCount) else { throw LibraryError.changedFile }
            try file.seek(toOffset: 0)
            var hash = SHA256()
            var remaining = book.byteCount
            while remaining > 0 {
                try Task.checkCancellation()
                let count = min(64 * 1024, remaining)
                guard let block = try file.read(upToCount: count), !block.isEmpty, block.count <= count else { throw LibraryError.changedFile }
                hash.update(data: block); remaining -= block.count
            }
            // Size checks only reject obvious change; every expected byte still participates in SHA.
            let extra = try file.read(upToCount: 1)
            guard extra?.isEmpty != false, try file.seekToEnd() == UInt64(book.byteCount) else { throw LibraryError.changedFile }
            let identity = hash.finalize().map { String(format: "%02x", $0) }.joined()
            ProcessingMeasurement.finish(.sourceVerification, since: verificationStart, observe: measure)
            guard identity == book.id else { throw LibraryError.changedFile }
            guard let lease else { throw DerivedStorageError.missingArtifact }
            guard let current = try await store.book(id: id), current.versionID == book.versionID,
                  current.encodingRaw == book.encodingRaw, current.byteCount == book.byteCount,
                  current.utf16Count == book.utf16Count else { throw DerivedStorageError.versionMismatch }
            let artifact = try await store.derivedFileURL(lease)
            guard FileManager.default.fileExists(atPath: artifact.path) else { throw DerivedStorageError.missingArtifact }
            return try DerivedBookSource(url: artifact, lease: lease, book: book, budget: budget, store: store)
        } catch {
            if let lease {
                // Budget/caller cancellation does not make otherwise valid persistent data corrupt.
                if !(error is CancellationError), (error as? DerivedStorageError) != .budgetExceeded {
                    try? await store.invalidateDerived(lease.pointer)
                }
                await store.releaseDerivedLease(lease)
            }
            throw error
        }
    }
}

extension LibraryService {
    func readingRouteStatistics() -> ReadingRouteStatistics { readingReuse }

    private func persistImported(_ receipt: ImportReceipt, document: TXTDocument?, budget: DerivedBookBudget,
                                 measure: ProcessingMeasurementObserver?) async {
        guard !Task.isCancelled else { measure?(ProcessingMeasurement(phase: .derivedDeferred, seconds: 0)); return }
        let reusable = document.flatMap { value -> TXTDocument? in
            value.documentID == receipt.book.id && value.versionID == receipt.book.versionID &&
                value.encoding.rawValue == receipt.book.encodingRaw ? value : nil
        }
        do {
            if reusable == nil {
                do {
                    let ready = try await openDerivedOnce(id: receipt.book.id, budget: budget, measure: measure)
                    await ready.close(); measure?(ProcessingMeasurement(phase: .diskHit, seconds: 0)); return
                } catch let error as DerivedStorageError {
                    guard Self.recoverableDerived(error) else { throw error }
                }
            }
            _ = try await buildForReading(id: receipt.book.id, budget: budget, imported: reusable, measure: measure)
        } catch { measure?(ProcessingMeasurement(phase: .derivedDeferred, seconds: 0)) }
        // ImportReceipt is already committed truth. No derived error or late cancellation escapes.
    }
    private static func recoverableDerived(_ error: DerivedStorageError) -> Bool {
        [.missingArtifact, .corruptArtifact, .incompatibleFormat, .versionMismatch].contains(error)
    }
    private func releaseReadingBuild(_ id: UUID, consumer: UUID) {
        guard var current = readingBuild, current.id == id else { return }
        guard current.consumers.remove(consumer) != nil else { return }
        readingBuild = current
        if current.consumers.isEmpty {
            current.task.cancel()
            let pending = current.task
            Task { _ = try? await pending.value; self.finishReadingBuild(id) }
        }
    }
    private func finishReadingBuild(_ id: UUID) {
        if readingBuild?.id == id { readingBuild = nil }
    }
    private func buildForReading(id: String, budget: DerivedBookBudget, imported: TXTDocument?,
                                 measure: ProcessingMeasurementObserver?,
                                 inject: ReaderOpenInjection? = nil) async throws -> DerivedBookMetadata {
        guard let book = try await store.book(id: id) else { throw LibraryError.missingBook }
        var rechecked = false
        let consumer = UUID()
        let operation: ReadingBuild
        while true {
            try Task.checkCancellation()
            if var previous = readingBuild {
                if previous.bookID == id, previous.versionID == book.versionID,
                   previous.encoding == book.encodingRaw, !previous.consumers.isEmpty, !previous.task.isCancelled {
                    previous.consumers.insert(consumer); readingBuild = previous; operation = previous
                    break
                }
                previous.task.cancel(); _ = try? await previous.task.value
                if readingBuild?.id == previous.id { readingBuild = nil }
                continue // Every suspension can install a different producer; match again.
            }
            if imported == nil, !rechecked {
                rechecked = true
                do {
                    let ready = try await openDerivedOnce(id: id, budget: budget, measure: measure)
                    let metadata = ready.metadata; await ready.close(); return metadata
                } catch let error as DerivedStorageError { guard Self.recoverableDerived(error) else { throw error } }
                continue
            }
            let token = UUID()
            let task = Task {
                try await inject?(.buildStarted)
                try Task.checkCancellation()
                try await self.store.recoverDerivedStorage()
                return try await self.buildDerivedBook(id: id, budget: budget, inject: nil, imported: imported,
                                                       measure: measure, evictUnleased: true)
            }
            operation = ReadingBuild(id: token, bookID: id, versionID: book.versionID, encoding: book.encodingRaw,
                                     task: task, consumers: [consumer]); readingBuild = operation
            break
        }
        defer { releaseReadingBuild(operation.id, consumer: consumer) }
        return try await withTaskCancellationHandler {
            try await inject?(.buildJoined)
            try Task.checkCancellation()
            let result = try await operation.task.value
            try Task.checkCancellation(); return result
        } onCancel: {
            Task { await self.releaseReadingBuild(operation.id, consumer: consumer) }
        }
    }
    public func openReader(id: String, budget: DerivedBookBudget,
                           measure: ProcessingMeasurementObserver? = nil) async throws -> OpenedReader {
        try await openReader(id: id, budget: budget, measure: measure, inject: nil)
    }
    func openReader(id: String, budget: DerivedBookBudget, measure: ProcessingMeasurementObserver? = nil,
                    inject: ReaderOpenInjection?) async throws -> OpenedReader {
        processed.invalidate() // The product path never retains the legacy full-document cache.
        let permit = try await store.reserveReaderOpen(bookID: id)
        var source: DerivedBookSource?, session: ReadingSession?
        do {
            let value: DerivedBookSource, disposition: ReaderCacheDisposition
            do {
                value = try await openDerivedOnce(id: id, budget: budget, measure: measure)
                disposition = .diskHit; readingReuse.diskHits += 1
                measure?(ProcessingMeasurement(phase: .diskHit, seconds: 0))
            } catch let error as DerivedStorageError {
                guard Self.recoverableDerived(error) else { throw error }
                try Task.checkCancellation(); try await store.recoverDerivedStorage()
                readingReuse.rebuilds += 1
                _ = try await buildForReading(id: id, budget: budget, imported: nil, measure: measure, inject: inject)
                try Task.checkCancellation()
                value = try await openDerivedOnce(id: id, budget: budget, measure: measure); disposition = .rebuilt
            }
            source = value; try Task.checkCancellation()
            try await inject?(.sourceReady); try Task.checkCancellation()
            let start = try await store.beginReader(permit, versionID: value.metadata.versionID)
            session = start.session
            try await inject?(.sessionStarted); try Task.checkCancellation()
            var valid = start.anchor
            if let anchor = valid {
                do { _ = try await value.utf16Offset(for: RawByteOffset(anchor.rawByteOffset)) }
                catch is TXTError { valid = nil }
            }
            try Task.checkCancellation()
            let preferences = try await store.preferences()
            try await inject?(.preferencesLoaded); try Task.checkCancellation()
            try await store.confirmReaderOpen(permit, session: start.session)
            guard let book = try await store.book(id: id), book.versionID == value.metadata.versionID else { throw DerivedStorageError.versionMismatch }
            try Task.checkCancellation(); try await store.confirmReaderOpen(permit, session: start.session)
            let reading = ReadingStart(session: start.session, anchor: valid,
                ignoredIncompatibleProgress: start.ignoredIncompatibleProgress || (start.anchor != nil && valid == nil))
            await store.endReaderOpen(permit)
            try Task.checkCancellation()
            return OpenedReader(book: book, source: value, reading: reading, preferences: preferences, disposition: disposition, store: store)
        } catch {
            if let session { try? await store.finishReading(session: session, anchor: nil, sequence: 1) }
            if let source { await source.close() }
            await store.endReaderOpen(permit); throw error
        }
    }
}

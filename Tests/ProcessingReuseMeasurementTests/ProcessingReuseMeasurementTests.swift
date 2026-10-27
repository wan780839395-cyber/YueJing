import Darwin
import Foundation
import Testing
import TXTCore
@testable import ReaderDomain

/// One sequential synthetic path, run alone in Release by the existing Task 3 workflow.
@Suite(.serialized)
struct ProcessingReuseMeasurementTests {
    private struct Trace: Sendable {
        let continuation: AsyncStream<ProcessingMeasurement>.Continuation
        let task: Task<[ProcessingMeasurement], Never>
        init() {
            let pair = AsyncStream<ProcessingMeasurement>.makeStream(bufferingPolicy: .bufferingOldest(64))
            continuation = pair.continuation
            task = Task {
                var values: [ProcessingMeasurement] = []
                for await value in pair.stream { values.append(value) }
                return values
            }
        }
        var observer: ProcessingMeasurementObserver {
            let sink = continuation; return { _ = sink.yield($0) }
        }
        func finish() async -> [ProcessingMeasurement] { continuation.finish(); return await task.value }
    }

    private func rss() throws -> UInt64 {
        var info = mach_task_basic_info_data_t()
        let capacity = MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw LibraryError.missingFile }
        return info.resident_size
    }

    private func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: ContinuousClock().now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    private func emit(_ scenario: String, wall: Double, phases: [ProcessingMeasurement], before: UInt64,
                      after: UInt64, stats: ProcessingReuseStatistics) throws {
        let value: [String: Any] = ["scenario": scenario, "seconds": wall, "sample_bytes": 10 * 1024 * 1024,
            "rss_before_bytes": before, "rss_after_bytes": after,
            "decode_calls": stats.decodeCalls, "chapter_calls": stats.chapterCalls,
            "document_hits": stats.documentHits, "chapter_hits": stats.chapterHits,
            "retained_estimate_bytes": stats.retainedBytes,
            "phases": phases.map { ["phase": $0.phase.rawValue, "seconds": $0.seconds] as [String: Any] },
            "scope": "one synthetic attempt; process RSS boundaries, not peak; fixture remains live; no UIKit/first paint"]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print("PROCESSING_REUSE_METRIC " + String(decoding: data, as: UTF8.self))
    }

    private func open(_ scenario: String, id: String, service: LibraryService, store: LibraryStore) async throws {
        let trace = Trace(); defer { trace.continuation.finish() }
        let before = try rss(), start = ContinuousClock().now
        let opened = try await service.openBook(id: id, measure: trace.observer)
        let anchor = opened.reading.anchor ?? ReadingAnchor(bookID: id, versionID: opened.document.versionID,
                                                            rawByteOffset: opened.document.bomByteCount)
        let settings = try await store.preferences()
        let engine = ReadingLayoutEngine(bookID: id, document: opened.document)
        let window = try await engine.window(around: anchor, width: 310, preferences: settings, measure: trace.observer)
        let wall = elapsed(start), after = try rss()
        let phases = await trace.finish(), stats = await service.processingReuseStatistics()
        #expect(!window.slices.isEmpty && window.slices.count <= 7)
        if scenario == "first_open" { #expect(stats.decodeCalls == 1 && stats.chapterCalls == 1 && stats.documentHits == 1) }
        if scenario == "same_service_reopen" {
            #expect(stats.decodeCalls == 1 && stats.chapterCalls == 1 && stats.documentHits == 2 && stats.chapterHits == 1)
            #expect(!phases.contains { $0.phase == .decode || $0.phase == .chapters })
        }
        if scenario == "new_service_cold_cache" { #expect(stats.decodeCalls == 1 && stats.chapterCalls == 1 && stats.documentHits == 0) }
        try emit(scenario, wall: wall, phases: phases, before: before, after: after, stats: stats)
        let saved = window.slices.last?.lines.first?.rawByteStart ?? anchor.rawByteOffset
        try await store.finishReading(session: opened.reading.session,
            anchor: ReadingAnchor(bookID: id, versionID: opened.document.versionID, rawByteOffset: saved), sequence: 1)
    }

    @Test func syntheticImportFirstOpenReopenAndNewServiceColdCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YueJing-measure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            if root.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
               root.lastPathComponent.hasPrefix("YueJing-measure-") { try? FileManager.default.removeItem(at: root) }
        }
        // Same reproducible Chinese fixture rule as the existing kernel sample; generation/write excluded.
        let body = "山河清朗，书页记录晨光与行旅。\n"
        let block = Data(("第1章 基线\n" + String(repeating: body, count: 1024)).utf8), line = Data(body.utf8)
        let size = 10 * 1024 * 1024
        var bytes = Data(); bytes.reserveCapacity(size)
        for _ in 0..<(size / block.count) { bytes.append(block) }
        for _ in 0..<((size - bytes.count) / line.count) { bytes.append(line) }
        bytes.append(contentsOf: repeatElement(UInt8(0x20), count: size - bytes.count))
        let source = root.appendingPathComponent("synthetic.txt"); try bytes.write(to: source)
        let store = try LibraryStore(root: root.appendingPathComponent("Managed")), service = LibraryService(store: store)
        let trace = Trace(); defer { trace.continuation.finish() }
        let before = try rss(), start = ContinuousClock().now
        let preparation = try await service.prepareImport(url: source, ticket: UUID(), measure: trace.observer)
        let wall = elapsed(start), after = try rss()
        let phases = await trace.finish(), stats = await service.processingReuseStatistics()
        guard case .completed(let receipt) = preparation else { Issue.record("Expected deterministic synthetic import"); return }
        #expect(stats.decodeCalls == 1 && stats.retainedBytes > 0 && stats.retainedBytes <= 64 * 1024 * 1024)
        try emit("import", wall: wall, phases: phases, before: before, after: after, stats: stats)
        try await open("first_open", id: receipt.book.id, service: service, store: store)
        try await open("same_service_reopen", id: receipt.book.id, service: service, store: store)
        await service.releaseProcessingCache()
        let cold = LibraryService(store: store)
        try await open("new_service_cold_cache", id: receipt.book.id, service: cold, store: store)
        #expect(try Data(contentsOf: source) == bytes)
    }
}

import CryptoKit
import Darwin
import Foundation
import Testing
import TXTCore

private enum BaselineError: Error { case stopped(String) }

private struct MemoryReading: Sendable {
    let rss: UInt64
    let lifetimeHighWater: UInt64

    static func read() throws -> Self {
        var info = mach_task_basic_info_data_t()
        let capacity = MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw BaselineError.stopped("task_info failed: \(status)") }
        return Self(rss: info.resident_size, lifetimeHighWater: info.resident_size_max)
    }

    var fields: [String: Any] { ["rss_bytes": rss, "process_lifetime_rss_high_water_bytes": lifetimeHighWater] }
}

private struct EventWriter: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("txt-core-performance-\(UUID().uuidString).jsonl")
        try Data().write(to: url, options: .atomic)
    }

    func emit(_ fields: [String: Any]) throws {
        var event = fields
        event["event_id"] = UUID().uuidString
        event["uptime_seconds"] = ProcessInfo.processInfo.systemUptime
        event["report_filename"] = url.lastPathComponent
        let json = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        let line = json + Data([0x0A])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
        FileHandle.standardOutput.write(Data("TXT_PERF_EVENT ".utf8) + line)
    }
}

private func seconds(_ duration: Duration) -> Double {
    let value = duration.components
    return Double(value.seconds) + Double(value.attoseconds) / 1e18
}

private actor MemorySampler {
    private var maximum: UInt64
    private var count = 0
    private var previous: ContinuousClock.Instant
    private var largestGap = 0.0
    private var reason: String?
    private let start: ContinuousClock.Instant
    private let wallLimit: Double
    static let rssLimit: UInt64 = 1536 * 1024 * 1024

    init(before: MemoryReading, start: ContinuousClock.Instant, wallLimit: Double) {
        maximum = before.rss
        self.start = start
        previous = start
        self.wallLimit = wallLimit
    }

    func observe() throws {
        do {
            let memory = try MemoryReading.read()
            let now = ContinuousClock().now
            largestGap = max(largestGap, seconds(previous.duration(to: now)))
            previous = now
            maximum = max(maximum, memory.rss)
            count += 1
            if memory.rss > Self.rssLimit { throw BaselineError.stopped("RSS protection limit exceeded (1536 MiB)") }
            if seconds(start.duration(to: now)) > wallLimit { throw BaselineError.stopped("Phase wall-time protection limit exceeded (\(wallLimit) seconds)") }
        } catch {
            reason = String(describing: error)
            throw error
        }
    }

    func finish(after: MemoryReading, at end: ContinuousClock.Instant) -> (UInt64, Int, Double, String?) {
        maximum = max(maximum, after.rss)
        largestGap = max(largestGap, seconds(previous.duration(to: end)))
        previous = end
        return (maximum, count, largestGap, reason)
    }
}

private struct TimedValue<Value: Sendable>: Sendable {
    let value: Value
    let elapsed: Double
}

private func measure<Value: Sendable>(phase: String, size: Int, writer: EventWriter, wallLimit: Double,
                                    operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    let before = try MemoryReading.read()
    try writer.emit(["event": "phase_begin", "phase": phase, "sample_bytes": size, "memory": before.fields])
    guard before.rss <= MemorySampler.rssLimit else { throw BaselineError.stopped("RSS already exceeds protection limit before \(phase)") }
    let start = ContinuousClock().now
    let sampler = MemorySampler(before: before, start: start, wallLimit: wallLimit)
    do {
        let timed = try await withThrowingTaskGroup(of: TimedValue<Value>.self) { group in
            group.addTask {
                let value = try await operation()
                let end = ContinuousClock().now
                return TimedValue(value: value, elapsed: seconds(start.duration(to: end)))
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .milliseconds(100))
                    try await sampler.observe()
                }
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw BaselineError.stopped("No phase task result") }
            return first
        }
        let after = try MemoryReading.read()
        let (maximum, count, gap, reason) = await sampler.finish(after: after, at: ContinuousClock().now)
        if let reason { throw BaselineError.stopped(reason) }
        guard timed.elapsed <= wallLimit, after.rss <= MemorySampler.rssLimit else {
            throw BaselineError.stopped("Phase ended beyond protection limits")
        }
        try writer.emit(["event": "phase_end", "phase": phase, "sample_bytes": size, "status": "completed",
                         "wall_seconds": timed.elapsed, "before": before.fields, "after": after.fields,
                         "observed_rss_max_bytes": maximum, "interior_samples": count, "max_observation_gap_seconds": gap])
        return timed.value
    } catch {
        let elapsed = seconds(start.duration(to: ContinuousClock().now))
        let after = try MemoryReading.read()
        let (maximum, count, gap, reason) = await sampler.finish(after: after, at: ContinuousClock().now)
        try writer.emit(["event": "phase_end", "phase": phase, "sample_bytes": size, "status": "failed",
                         "wall_seconds_until_failure": elapsed, "before": before.fields, "after": after.fields,
                         "observed_rss_max_bytes": maximum, "interior_samples": count, "max_observation_gap_seconds": gap,
                         "error": String(describing: error), "guard_reason": reason.map { $0 as Any } ?? NSNull()])
        throw error
    }
}

private struct SyntheticSample: Sendable {
    let bytes: Data
    let chapters: Int
    let utf16Count: Int

    static func make(byteCount: Int) -> Self {
        let heading = "第1章 基线\n"
        let body = "山河清朗，书页记录晨光与行旅。\n"
        let blockText = heading + String(repeating: body, count: 1024)
        let block = Data(blockText.utf8), line = Data(body.utf8)
        var bytes = Data()
        bytes.reserveCapacity(byteCount)
        let blocks = byteCount / block.count
        for _ in 0..<blocks { bytes.append(block) }
        let lines = (byteCount - bytes.count) / line.count
        for _ in 0..<lines { bytes.append(line) }
        let padding = byteCount - bytes.count
        bytes.append(contentsOf: repeatElement(UInt8(0x20), count: padding))
        return Self(bytes: bytes, chapters: blocks,
                    utf16Count: blocks * blockText.utf16.count + lines * body.utf16.count + padding)
    }
}

struct TXTLargeFilePerformanceTests {
    @Test(.timeLimit(.minutes(8))) func automaticDecodeAndChaptersBaseline() async throws {
        let writer = try EventWriter()
        let sizes = [10 * 1024 * 1024, 50 * 1024 * 1024]
        try writer.emit(["event": "run_begin", "sizes_bytes": sizes, "pid": getpid(), "configuration": "Release",
                         "encoding": "BOM-less UTF-8, decode using defaults (automatic)", "sample_rule": "chinese-chapters-v1",
                         "rss_limit_bytes": MemorySampler.rssLimit, "decode_limit_seconds": 120, "chapters_limit_seconds": 60,
                         "sampling_target_seconds": 0.1, "memory_metric": "task_info MACH_TASK_BASIC_INFO bytes",
                         "high_water_scope": "entire test-host process lifetime; never reset between phases or sizes",
                         "order": "10 MiB then 50 MiB in one process; prior local payloads leave scope; allocator/system caches may remain"])
        for (index, size) in sizes.enumerated() {
            do {
                try await runSize(size, writer: writer)
                try writer.emit(["event": "after_payload_scope", "sample_bytes": size, "memory": try MemoryReading.read().fields])
            } catch {
                try writer.emit(["event": "run_stopped", "sample_bytes": size, "error": String(describing: error),
                                 "not_started_bytes": Array(sizes.dropFirst(index + 1))])
                throw error
            }
        }
        try writer.emit(["event": "run_complete", "completed_sizes": 2])
    }

    private func runSize(_ size: Int, writer: EventWriter) async throws {
        try writer.emit(["event": "size_begin", "sample_bytes": size, "before_fixture": try MemoryReading.read().fields])
        let sample = SyntheticSample.make(byteCount: size)
        let digest = SHA256.hash(data: sample.bytes).map { String(format: "%02x", $0) }.joined()
        try writer.emit(["event": "fixture_ready", "sample_bytes": sample.bytes.count, "sha256": digest,
                         "expected_chapters": sample.chapters, "expected_utf16_count": sample.utf16Count,
                         "memory_after_generation_before_decode": try MemoryReading.read().fields,
                         "fixture_live_bytes": sample.bytes.count, "fixture_and_hash_excluded_from_decode_timer": true])
        let processor = TXTProcessor()
        let document = try await measure(phase: "decode", size: size, writer: writer, wallLimit: 120) {
            try await processor.decode(sample.bytes)
        }
        try #require(document.encoding == .utf8)
        try #require(document.bomByteCount == 0)
        try #require(document.originalBytes == sample.bytes)
        try #require(document.documentID == digest)
        try #require(document.utf16Count == sample.utf16Count)
        let chapters = try await measure(phase: "chapters", size: size, writer: writer, wallLimit: 60) {
            try await processor.chapters(in: document)
        }
        try #require(chapters.count == sample.chapters)
        let first = try #require(chapters.first), last = try #require(chapters.last)
        try #require(first.rawByteRange.location.value == 0)
        try #require(last.rawByteRange.location.value + last.rawByteRange.length == size)
        try withExtendedLifetime((sample, document, chapters)) {
            try writer.emit(["event": "size_complete", "sample_bytes": size, "sha256": digest,
                             "utf16_count": document.utf16Count, "chapter_count": chapters.count,
                             "memory_with_fixture_document_mapping_and_chapters_live": try MemoryReading.read().fields])
        }
    }
}

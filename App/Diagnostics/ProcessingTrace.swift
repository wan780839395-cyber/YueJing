import Foundation
import ReaderDomain

/// Bounded local collection. UI publishes only after an operation completes.
@MainActor
struct ProcessingTrace {
    private let continuation: AsyncStream<ProcessingMeasurement>.Continuation
    private let consumer: Task<[ProcessingMeasurement], Never>
    init() {
        let pair = AsyncStream<ProcessingMeasurement>.makeStream(bufferingPolicy: .bufferingOldest(64))
        continuation = pair.continuation
        consumer = Task {
            var values: [ProcessingMeasurement] = []
            for await value in pair.stream { values.append(value) }
            return values
        }
    }
    var observer: ProcessingMeasurementObserver {
        let sink = continuation
        return { _ = sink.yield($0) }
    }
    func end() { continuation.finish() }
    func finish() async -> [ProcessingMeasurement] { end(); return await consumer.value }
}

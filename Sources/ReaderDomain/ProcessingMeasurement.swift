import Foundation

/// Local fixed phases and durations only. No title, path, document hash, or telemetry.
public struct ProcessingMeasurement: Sendable {
    public enum Phase: String, Sendable { case privateCopy, read, hash, decode, chapters, layout }
    public let phase: Phase
    public let seconds: Double

    static func finish(_ phase: Phase, since start: ContinuousClock.Instant, observe: ProcessingMeasurementObserver?) {
        let duration = start.duration(to: ContinuousClock().now).components
        observe?(Self(phase: phase, seconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18))
    }

    static func timed<Value>(_ phase: Phase, observe: ProcessingMeasurementObserver?, _ operation: () throws -> Value) rethrows -> Value {
        let start = ContinuousClock().now
        defer { finish(phase, since: start, observe: observe) }
        return try operation()
    }

    public static func summary(_ values: [Self]) -> String {
        let labels: [(Phase, String)] = [(.privateCopy, "私有复制"), (.read, "读取"), (.hash, "内容校验"),
            (.decode, "解码/索引"), (.chapters, "分章"), (.layout, "窗口布局")]
        return labels.compactMap { phase, label in
            let matches = values.filter { $0.phase == phase }
            guard !matches.isEmpty else { return nil }
            return label + String(format: " %.3fs", matches.reduce(0) { $0 + $1.seconds })
        }.joined(separator: "；")
    }
}

public typealias ProcessingMeasurementObserver = @Sendable (ProcessingMeasurement) -> Void

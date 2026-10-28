import Foundation
import TXTCore

/// Local fixed phases and durations only. No title, path, document hash, or telemetry.
public struct ProcessingMeasurement: Sendable {
    public enum Phase: String, Sendable {
        case privateCopy, read, hash, decode, chapters, layout
        case decoderTotal, scanConversion, normalizationIndex, unicodeScanBuild, decoderRawHash, decoderVersionHash
    }
    public let phase: Phase
    public let seconds: Double
    public let encoding: TXTEncoding?
    public let requestedEncoding: TXTEncoding?

    init(phase: Phase, seconds: Double, encoding: TXTEncoding? = nil, requestedEncoding: TXTEncoding? = nil) {
        self.phase = phase; self.seconds = seconds; self.encoding = encoding; self.requestedEncoding = requestedEncoding
    }

    static func decoder(_ metrics: TXTDecodeMetrics, observe: ProcessingMeasurementObserver) {
        observe(Self(phase: .decoderTotal, seconds: metrics.processorSeconds,
                     encoding: metrics.encoding, requestedEncoding: metrics.requestedEncoding))
        if metrics.gbScans > 0 {
            observe(Self(phase: .scanConversion, seconds: metrics.scanConversionSeconds))
            observe(Self(phase: .normalizationIndex, seconds: metrics.normalizationIndexSeconds))
        }
        if metrics.unicodeScans > 0 { observe(Self(phase: .unicodeScanBuild, seconds: metrics.unicodeScanBuildSeconds)) }
        observe(Self(phase: .decoderRawHash, seconds: metrics.rawHashSeconds))
        observe(Self(phase: .decoderVersionHash, seconds: metrics.versionHashSeconds))
    }

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
        let outer = labels.compactMap { phase, label -> String? in
            let matches = values.filter { $0.phase == phase }
            guard !matches.isEmpty else { return nil }
            return label + String(format: " %.3fs", matches.reduce(0) { $0 + $1.seconds })
        }.joined(separator: "；")
        let decodes = values.filter { $0.phase == .decoderTotal }
        guard !decodes.isEmpty else { return outer }
        let names = Set(decodes.compactMap { $0.encoding?.rawValue }).sorted().joined(separator: "/")
        let mode = decodes.contains { $0.requestedEncoding == nil } ? "含自动识别" : "固定编码"
        let details: [(Phase, String)] = [(.decoderTotal, "内核内部总时长"), (.scanConversion, "GB扫描/转换"),
            (.normalizationIndex, "GB规范化/索引"), (.unicodeScanBuild, "UTF扫描+规范化+索引（未拆分）"),
            (.decoderRawHash, "内核原始SHA"), (.decoderVersionHash, "正文版本SHA")]
        let inner = details.compactMap { phase, label -> String? in
            let matches = values.filter { $0.phase == phase }
            guard !matches.isEmpty else { return nil }
            return label + String(format: " %.3fs", matches.reduce(0) { $0 + $1.seconds })
        }.joined(separator: "；")
        return outer + "\n处理编码：" + (names.isEmpty ? "尚未确定" : names) + "（" + mode + "）\n" + inner
            + "\n内部项包含在解码/索引总时长内，不重复相加；外层差值含等待/调度。"
    }
}

public typealias ProcessingMeasurementObserver = @Sendable (ProcessingMeasurement) -> Void

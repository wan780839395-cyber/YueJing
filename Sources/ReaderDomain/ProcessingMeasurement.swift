import Foundation
import TXTCore

/// Local fixed phases and durations only. No title, path, document hash, or telemetry.
public struct ProcessingMeasurement: Sendable {
    public enum Phase: String, Sendable {
        case privateCopy, read, hash, decode, chapters, layout
        case sourceVerification, derivedBuild, diskHit, derivedDeferred, rangeRead
        case decoderTotal, scanConversion, normalizationIndex, unicodeScanBuild, decoderRawHash, decoderVersionHash
    }
    public let phase: Phase
    public let seconds: Double
    public let encoding: TXTEncoding?
    public let requestedEncoding: TXTEncoding?
    public let bytes: Int?
    public let logicalBytes: Int?
    public let budgetBytes: Int?

    init(phase: Phase, seconds: Double, encoding: TXTEncoding? = nil, requestedEncoding: TXTEncoding? = nil,
         bytes: Int? = nil, logicalBytes: Int? = nil, budgetBytes: Int? = nil) {
        self.phase = phase; self.seconds = seconds; self.encoding = encoding; self.requestedEncoding = requestedEncoding
        self.bytes = bytes; self.logicalBytes = logicalBytes; self.budgetBytes = budgetBytes
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
        var outer = labels.compactMap { phase, label -> String? in
            let matches = values.filter { $0.phase == phase }
            guard !matches.isEmpty else { return nil }
            return label + String(format: " %.3fs", matches.reduce(0) { $0 + $1.seconds })
        }.joined(separator: "；")
        let sourceChecks = values.filter { $0.phase == .sourceVerification }
        if !sourceChecks.isEmpty { outer += String(format: "\n源读取+完整SHA %.3fs（未拆分）", sourceChecks.reduce(0) { $0 + $1.seconds }) }
        if values.contains(where: { $0.phase == .diskHit }) { outer += "\n磁盘结果命中；仍完整校验原件。" }
        if values.contains(where: { $0.phase == .derivedDeferred }) { outer += "\n已入架；派生生成未完成，打开时限次重试。" }
        let builds = values.filter { $0.phase == .derivedBuild }
        if !builds.isEmpty { outer += String(format: "\n派生构建 %.3fs（含分章/写入/校验，不与内部项相加）", builds.reduce(0) { $0 + $1.seconds }) }
        let ranges = values.filter { $0.phase == .rangeRead }
        if !ranges.isEmpty {
            outer += "\n范围校验读取 " + String(ranges.reduce(0) { $0 + ($1.bytes ?? 0) }) + " B；保留逻辑计账 "
                + String(ranges.compactMap(\.logicalBytes).max() ?? 0) + " B / 预算 "
                + String(ranges.compactMap(\.budgetBytes).max() ?? 0) + " B（非RSS，读取耗时含在布局内）。"
        }
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

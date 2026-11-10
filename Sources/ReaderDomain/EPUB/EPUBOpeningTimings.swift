import Foundation

/// One opening's bounded, local timings. Never stores publication identities or content.
public struct EPUBOpeningTimings: Sendable {
    public enum ContentCacheOutcome: String, Sendable {
        case notRequested, verifiedVersion, rebuilt, rebuiltAfterInvalidation, temporary
    }
    public internal(set) var contentCacheOutcome: ContentCacheOutcome = .notRequested
    public internal(set) var resourceCount = 0
    public internal(set) var resourceBytes = 0
    public internal(set) var packageFingerprintReused = false
    public internal(set) var metadataDecodeReused = false
    public internal(set) var sessionBreakdown = EPUBSessionBreakdown()
    public enum Phase: String, CaseIterable, Sendable {
        case catalog, sourceVerification, packageFingerprint, warmResourceVerification, diskRestore, rebuild, cacheWrite, session
        var label: String {
            switch self {
            case .catalog: "书库/打开许可"
            case .sourceVerification: "原书读取+完整SHA"
            case .packageFingerprint: "规范指纹计算/复用"
            case .warmResourceVerification: "复用目录逐资源校验"
            case .diskRestore: "磁盘缓存校验/恢复"
            case .rebuild: "资源重新构建"
            case .cacheWrite: "缓存写入"
            case .session: "偏好/新会话确认"
            }
        }
    }
    public struct Sample: Sendable {
        public let phase: Phase
        public let seconds: Double
        public let succeeded: Bool
    }
    public private(set) var samples: [Sample] = []
    public init() {}

    mutating func record(_ phase: Phase, since start: ContinuousClock.Instant,
                         until end: ContinuousClock.Instant = ContinuousClock.now, succeeded: Bool = true) {
        guard samples.count < 16 else { return }
        let value = start.duration(to: end).components
        samples.append(Sample(phase: phase, seconds: Double(value.seconds) + Double(value.attoseconds) / 1e18,
                              succeeded: succeeded))
    }

    mutating func measure<T>(_ phase: Phase, _ operation: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        do {
            let value = try operation()
            record(phase, since: start)
            return value
        } catch {
            record(phase, since: start, succeeded: false)
            throw error
        }
    }

    public var summary: String {
        let cache = "准备链：metadata-snapshot-v1；规范指纹命中：\(packageFingerprintReused)\n" +
            "leased-metadata-v1；元数据解码复用：\(metadataDecodeReused)\n" +
            "内容缓存：\(contentCacheOutcome.rawValue)；资源清单 \(resourceCount) 项 / \(resourceBytes) 字节\n"
        return cache + Phase.allCases.flatMap { phase in
            samples.filter { $0.phase == phase }.map {
                phase.label + String(format: " %.3fs", $0.seconds) + ($0.succeeded ? "" : "（未成功，已回退）")
            }
        }.joined(separator: "\n") + (sessionBreakdown.samples.isEmpty ? "" : "\n\n" + sessionBreakdown.summary)
    }
}

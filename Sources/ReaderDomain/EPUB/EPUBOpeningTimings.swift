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
    public internal(set) var chapterIndexedMetadata = false
    public internal(set) var readyPreparationOccurred = false
    public enum MetadataReuseReason: String, Sendable {
        case notChecked, reused, noLeaseProof, metadataChanged
    }
    public internal(set) var metadataReuseReason: MetadataReuseReason = .notChecked
    public internal(set) var sessionBreakdown = EPUBSessionBreakdown()
    /// Successful Ready resource verification only; nil is unmeasured, never a zero-duration sample.
    public internal(set) var resourceVerification: EPUBResourceVerificationTimings?
    public enum ResourceVerificationRoute: String, Sendable {
        case notMeasured, readyRegistered, readyDisk, legacyCache
    }
    public internal(set) var resourceVerificationRoute: ResourceVerificationRoute = .notMeasured
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
            "元数据复用原因：\(metadataReuseReason.rawValue)\n" +
            "chapter-ready-v1；按章元数据：\(chapterIndexedMetadata)；本次迁移/重建：\(readyPreparationOccurred)\n" +
            "内容缓存：\(contentCacheOutcome.rawValue)；资源清单 \(resourceCount) 项 / \(resourceBytes) 字节\n"
        return cache + Phase.allCases.flatMap { phase in
            samples.filter { $0.phase == phase }.map {
                phase.label + String(format: " %.3fs", $0.seconds) + ($0.succeeded ? "" : "（未成功，已回退）")
            }
        }.joined(separator: "\n") + "\n资源细分通路：\(resourceVerificationRoute.rawValue)（进程注册状态，不代表OS磁盘冷热）\n" +
            (resourceVerification?.summary ?? "逐资源细分：未单列（未测或未成功；不是0耗时）") +
            "\n范围：仅Ready逐资源校验；原书SHA、manifest、节点包、复制/写入、重建不在细分内；旧磁盘恢复/串行缓存未单列。" +
            (sessionBreakdown.samples.isEmpty ? "" : "\n\n" + sessionBreakdown.summary)
    }
}

/// Fixed-size aggregates, returned only on complete success. No identities or per-resource samples.
/// Wall time includes serial preflight and task scheduling/join; lane sums are elapsed time,
/// neither CPU time nor the parallel critical path. Instrumentation overhead is included.
public struct EPUBResourceVerificationTimings: Sendable {
    public struct Lane: Sendable {
        public let index: Int
        public internal(set) var resourceCount = 0
        public internal(set) var resourceBytes = 0
        public internal(set) var pathPolicySeconds = 0.0
        public internal(set) var directorySeconds = 0.0
        public internal(set) var leafMetadataSeconds = 0.0
        public internal(set) var openReadCloseSeconds = 0.0
        public internal(set) var fullSHASeconds = 0.0

        init(index: Int) { self.index = index }
    }
    public let preflightSeconds: Double
    public let wallSeconds: Double
    public let lanes: [Lane] // At most four, sorted by index; empty lanes are not manufactured.
    public var resourceCount: Int { lanes.reduce(0) { $0 + $1.resourceCount } }
    public var resourceBytes: Int { lanes.reduce(0) { $0 + $1.resourceBytes } }

    static func seconds(since start: ContinuousClock.Instant, until end: ContinuousClock.Instant = ContinuousClock.now) -> Double {
        let value = start.duration(to: end).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    public var summary: String {
        let header = String(format: "Ready资源校验：并行墙钟 %.6fs（含串行预检 %.6fs、调度/汇合）；%d lane / %d项 / %d字节",
                            wallSeconds, preflightSeconds, lanes.count, resourceCount, resourceBytes)
        return header + "\n各lane阶段累计为经过时间，非CPU、非关键路径，不与墙钟相加：\n" + lanes.map { lane in
            String(format: "lane %d：%d项 / %d字节；路径/策略 %.6fs；目录/符链 %.6fs；叶类型/大小 %.6fs；打开/读取/关闭 %.6fs；完整SHA/比较 %.6fs",
                   lane.index, lane.resourceCount, lane.resourceBytes, lane.pathPolicySeconds,
                   lane.directorySeconds, lane.leafMetadataSeconds, lane.openReadCloseSeconds, lane.fullSHASeconds)
        }.joined(separator: "\n")
    }
}

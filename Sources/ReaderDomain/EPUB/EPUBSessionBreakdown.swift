import Foundation

/// One opening only. Fixed labels, bounded samples, no publication identity or content.
public struct EPUBSessionBreakdown: Sendable {
    public enum Phase: String, CaseIterable, Sendable {
        case preferencesCall, beginCall, confirmCall, releaseCall
        case actorAdmission, storeSetup, databaseEntry, bookRead, formatRead
        case metadataRead, metadataCompare, progressRead, progressDecode, positionValidation
        case rowUpdate, transactionReturn, storePublish, returnResume

        var isOuter: Bool {
            switch self {
            case .preferencesCall, .beginCall, .confirmCall, .releaseCall: true
            default: false
            }
        }
        var label: String {
            switch self {
            case .preferencesCall: "偏好调用（含等待）"
            case .beginCall: "会话创建调用（含等待）"
            case .confirmCall: "会话确认调用（含等待）"
            case .releaseCall: "打开许可释放调用（含等待）"
            case .actorAdmission: "调用→Store进入（调度/等待）"
            case .storeSetup: "许可检查/会话准备"
            case .databaseEntry: "请求事务→事务体进入（排队/事务开始）"
            case .bookRead: "书目读取"
            case .formatRead: "格式读取/版本检查前置"
            case .metadataRead: "完整元数据BLOB读取"
            case .metadataCompare: "完整元数据字节比对"
            case .progressRead: "进度BLOB读取"
            case .progressDecode: "进度解码"
            case .positionValidation: "位置/字素边界校验"
            case .rowUpdate: "会话UPDATE执行"
            case .transactionReturn: "事务体结束→write返回（含提交，非纯fsync）"
            case .storePublish: "内存会话登记"
            case .returnResume: "Store返回→调用方续执行"
            }
        }
    }

    public struct Sample: Sendable {
        public let phase: Phase
        public let seconds: Double
        public let succeeded: Bool
    }
    public private(set) var samples: [Sample] = []
    public internal(set) var metadataBytes = 0
    public init() {}

    mutating func record(_ phase: Phase, since start: ContinuousClock.Instant,
                         until end: ContinuousClock.Instant = ContinuousClock.now, succeeded: Bool = true) {
        guard samples.count < 24 else { return }
        let value = start.duration(to: end).components
        let seconds = max(0, Double(value.seconds) + Double(value.attoseconds) / 1e18)
        samples.append(Sample(phase: phase, seconds: seconds, succeeded: succeeded))
    }

    mutating func measure<T>(_ phase: Phase, _ operation: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        do {
            let result = try operation()
            record(phase, since: start)
            return result
        } catch {
            record(phase, since: start, succeeded: false)
            throw error
        }
    }

    mutating func merge(_ other: EPUBSessionBreakdown) {
        metadataBytes = other.metadataBytes
        for sample in other.samples {
            guard samples.count < 24 else { return }
            samples.append(sample)
        }
    }

    public var summary: String {
        guard !samples.isEmpty else { return "" }
        func lines(outer: Bool) -> String {
            samples.filter { $0.phase.isOuter == outer }.map {
                $0.phase.label + String(format: " %.3fs", $0.seconds) + ($0.succeeded ? "" : "（未成功）")
            }.joined(separator: "\n")
        }
        return "会话拆分：session-breakdown-v1；元数据读取 \(metadataBytes) B\n" +
            "外层调用（互不重叠，属于上方会话总耗时）：\n" + lines(outer: true) +
            "\n会话创建内部（不与外层重复相加）：\n" + lines(outer: false) +
            "\n均为同进程单调时钟墙钟时间，非CPU时间；少量胶水代码/计时开销未单列。"
    }
}

struct EPUBMeasuredReadingStart: Sendable {
    let start: EPUBReadingStart
    let details: EPUBSessionBreakdown
    let finishedAt: ContinuousClock.Instant
}

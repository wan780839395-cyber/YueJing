import Foundation
import OSLog
import Darwin

public enum EPUBPreparationStage: String, Sendable {
    case archive, package, chapters, navigation, resources, migration
    case readyCopy, readyNodes, readyVerify, complete

    public var label: String {
        switch self {
        case .archive: "正在校验并展开归档…"
        case .package: "正在检查出版物结构…"
        case .chapters: "正在处理章节与样式…"
        case .navigation: "正在检查目录与链接…"
        case .resources: "正在校验阅读资源…"
        case .migration: "正在核对旧阅读位置…"
        case .readyCopy: "正在准备阅读副本…"
        case .readyNodes: "正在保存章节索引…"
        case .readyVerify: "正在核验阅读副本…"
        case .complete: "书籍准备完成"
        }
    }
}

/// Fixed stages and numeric counters only. RSS is process-wide high-water, not a
/// per-book allocation estimate or proof of Jetsam. No book identity is recorded.
public struct EPUBPreparationSample: Sendable {
    public let stage: EPUBPreparationStage
    public let elapsedMilliseconds: Int
    public let completedChapters: Int
    public let totalChapters: Int
    public let outputBytes: Int
    public let peakChapterBytes: Int
    public let resourcePresenceChecks: Int
    public let resourcePresenceHits: Int
    public let processPeakRSSBytes: Int
    public let failureCode: String?
}

public typealias EPUBPreparationObserver = @Sendable (EPUBPreparationSample) -> Void

final class EPUBPreparationTrace {
    private static let logger = Logger(subsystem: "YueJing", category: "EPUBPreparation")
    private let started = ContinuousClock.now
    private let observer: EPUBPreparationObserver?
    private(set) var stage: EPUBPreparationStage = .archive
    var completedChapters = 0
    var totalChapters = 0
    var outputBytes = 0
    var peakChapterBytes = 0
    var resourcePresenceChecks = 0
    var resourcePresenceHits = 0

    init(observer: EPUBPreparationObserver? = nil) { self.observer = observer }

    func emit(_ stage: EPUBPreparationStage, failure: Error? = nil) {
        self.stage = stage
        let duration = started.duration(to: .now).components
        let milliseconds = Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
        var usage = rusage()
        let peak = getrusage(RUSAGE_SELF, &usage) == 0 ? Int(usage.ru_maxrss) : 0
        let code: String?
        if failure is CancellationError { code = "cancelled" }
        else if stage == .migration, failure != nil { code = "migration_inconsistent" }
        else if let error = failure as? EPUBError { code = error.reasonCode }
        else { code = failure == nil ? nil : "file_or_internal_failure" }
        let sample = EPUBPreparationSample(stage: stage, elapsedMilliseconds: milliseconds,
            completedChapters: completedChapters, totalChapters: totalChapters,
            outputBytes: outputBytes, peakChapterBytes: peakChapterBytes,
            resourcePresenceChecks: resourcePresenceChecks, resourcePresenceHits: resourcePresenceHits,
            processPeakRSSBytes: peak, failureCode: code)
        Self.logger.notice("stage=\(stage.rawValue, privacy: .public) ms=\(milliseconds) chapters=\(self.completedChapters)/\(self.totalChapters) output=\(self.outputBytes) chapterPeak=\(self.peakChapterBytes) pathChecks=\(self.resourcePresenceChecks) pathHits=\(self.resourcePresenceHits) processPeakRSS=\(peak) reason=\(code ?? "none", privacy: .public)")
        observer?(sample)
    }
}

extension EPUBError {
    public var reasonCode: String {
        switch self {
        case .invalidArchive: "archive_structure_or_crc"
        case .unsafePath: "unsafe_resource_path"
        case .limitExceeded: "processing_budget_exceeded"
        case .invalidPackage: "required_publication_structure"
        case .unsupportedContent: "unsupported_or_active_content"
        case .corruptResource: "resource_integrity_or_structure"
        case .invalidPosition: "position_version_mismatch"
        case .staleSession: "stale_reading_session"
        }
    }
}

extension EPUBPreparationStage {
    var importStage: ImportStage {
        switch self {
        case .archive, .package: .epubArchive
        case .chapters: .epubChapters
        case .navigation: .epubNavigation
        case .resources, .migration, .readyCopy, .readyNodes, .readyVerify, .complete: .epubReady
        }
    }
}

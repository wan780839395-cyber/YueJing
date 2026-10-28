import Foundation

/// Display-only state driven by actual import events, never a second commit authority.
public struct LibraryImportPresentation: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case waiting, copying, reading, decoding, choosing, registering, committed }
    public private(set) var attempt: UUID?
    public private(set) var phase: Phase = .waiting
    public private(set) var active = false
    public private(set) var stopRequested = false
    public init() {}
    public mutating func begin(_ id: UUID) {
        attempt = id; phase = .waiting; active = true; stopRequested = false
    }
    public mutating func receive(_ stage: ImportStage, for id: UUID) {
        guard active, attempt == id else { return }
        switch stage {
        case .scopeRequested, .scopeGranted, .scopeNotGranted, .sourceMetadataStarted,
             .sourceMetadataChecked, .coordinationStarted, .accessorStarted,
             .coordinatedMetadataChecked, .copyCompleted, .coordinationFinished:
            phase = .copying
        case .stagedReadStarted, .stagedReadCompleted: phase = .reading
        case .decodingStarted: phase = .decoding
        case .decodingCompleted: phase = .registering
        case .ambiguityDetected, .previewsReady, .encodingSheetRequested: phase = .choosing
        case .committed: phase = .committed
        case .cancelRequested: stopRequested = true
        default: break
        }
    }
    @discardableResult public mutating func requestStop(for id: UUID) -> Bool {
        guard active, attempt == id, !stopRequested else { return false }
        stopRequested = true; return true
    }
    public mutating func finish(_ id: UUID) { if attempt == id { active = false } }
    public var title: String {
        if stopRequested { return "正在停止准备…" }
        switch phase {
        case .waiting: return "正在准备导入…"
        case .copying: return "正在复制到应用…"
        case .reading: return "正在读取文字…"
        case .decoding: return "正在处理文字…"
        case .choosing: return "等待确认文字编码"
        case .registering: return "正在保存书籍…"
        case .committed: return "书籍已保存，正在准备阅读…"
        }
    }
    public var detail: String {
        stopRequested ? "正在等待停止结果。已经保存的书籍会保留，请稍候。"
            : "准备完成后即可从书架打开阅读。"
    }
}

/// Fixed, manually dismissible outcomes. No private book data enters diagnostics.
public struct LibraryNotice: Equatable, Sendable {
    public let title: String
    public let detail: String
    public static func committed(duplicate: Bool, stopRequested: Bool, preparationDeferred: Bool) -> Self {
        let title = duplicate ? "这本书已在书架" : "已加入书架"
        if stopRequested {
            return Self(title: title, detail: "停止请求到达时，书籍已经保存。原阅读位置保留，打开时会检查是否准备就绪。")
        }
        if preparationDeferred {
            return Self(title: title, detail: "原件已保存，阅读准备尚未完成。可打开重试，已保存位置保留。")
        }
        return Self(title: title, detail: duplicate ? "原阅读位置已保留。" : "可以开始阅读。")
    }
    public static let cancelledBeforeCommit = Self(title: "已停止导入", detail: "这次导入已停止，没有添加新书。")
    public static let selectionCancelled = Self(title: "已取消选择", detail: "未开始导入。")
}

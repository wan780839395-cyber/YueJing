import Foundation
import TXTCore

/// Only fixed vocabulary crosses into the visible diagnostic history. No URLs, titles, or text.
public enum ImportStage: String, Equatable, Sendable {
    case pickerWaiting, pickerClosedWithoutSelection, pickerClosed
    case selectedCallback, emptyCallback, failedCallback, cancellationCallback
    case delegateSelected, delegateEmpty, delegateCancelled, pickerHandoffMissing
    case accepted, rejectedUnavailable, rejectedBusy
    case scopeRequested, scopeGranted, scopeNotGranted, sourceMetadataStarted, sourceMetadataChecked
    case coordinationStarted, accessorStarted, coordinatedMetadataChecked, copyCompleted, coordinationFinished
    case stagedReadStarted, stagedReadCompleted, decodingStarted, decodingCompleted
    case ambiguityDetected, previewsReady, duplicateFound, committed
    case cancelRequested, cancelled, failed, encodingSheetRequested, alertRequested

    public var label: String {
        switch self {
        case .pickerWaiting: "等待在系统选择器中选文件"
        case .pickerClosedWithoutSelection: "选择器已关闭，未收到选中文件回调"
        case .pickerClosed: "选择器已关闭"
        case .selectedCallback: "已收到选中文件回调"
        case .emptyCallback: "收到成功回调，但没有文件"
        case .failedCallback: "收到选择文件失败回调"
        case .cancellationCallback: "收到明确的取消错误回调"
        case .delegateSelected: "已收到delegate选中文件回调"
        case .delegateEmpty: "已收到delegate空结果回调"
        case .delegateCancelled: "已收到delegate取消回调"
        case .pickerHandoffMissing: "选中回调已到达，但待处理文件缺失"
        case .accepted: "已接受本次导入"
        case .rejectedUnavailable: "未接受导入：书架尚未就绪"
        case .rejectedBusy: "未接受导入：已有导入正在处理"
        case .scopeRequested: "正在申请文件读取范围"
        case .scopeGranted: "读取范围申请返回 true"
        case .scopeNotGranted: "读取范围申请返回 false，继续原读取流程"
        case .sourceMetadataStarted: "正在检查源文件元数据"
        case .sourceMetadataChecked: "源文件普通文件检查通过"
        case .coordinationStarted: "开始协调读取，等待文件可用"
        case .accessorStarted: "协调读取回调已进入"
        case .coordinatedMetadataChecked: "协调后普通文件检查通过"
        case .copyCompleted: "应用副本复制及普通文件检查完成"
        case .coordinationFinished: "协调读取已返回"
        case .stagedReadStarted: "正在读取应用副本"
        case .stagedReadCompleted: "应用副本字节读取完成"
        case .decodingStarted: "正在解码文字"
        case .decodingCompleted: "文字解码完成"
        case .ambiguityDetected: "需要确认文字编码"
        case .previewsReady: "文字预览准备完成"
        case .duplicateFound: "已找到相同书籍"
        case .committed: "书架提交完成"
        case .cancelRequested: "已请求取消，等待原流程返回"
        case .cancelled: "导入已取消"
        case .failed: "导入未完成，请查看安全错误信息"
        case .encodingSheetRequested: "已请求显示文字确认页"
        case .alertRequested: "已请求显示结果提示"
        }
    }
}

public typealias ImportStageObserver = @Sendable (ImportStage) -> Void

/// Never copies an error's description, userInfo, associated text, or arbitrary domain.
public struct ImportSafeFailure: Equatable, Sendable {
    public enum Domain: String, Equatable, Sendable {
        case cocoa = "NSCocoaErrorDomain", posix = "NSPOSIXErrorDomain", url = "NSURLErrorDomain"
        case provider = "NSFileProviderErrorDomain", library = "Library", text = "TXT", cancellation = "Cancellation", other = "Other"
    }
    public enum Kind: String, Equatable, Sendable {
        case cancelled = "操作已取消", library = "应用文件检查未通过", text = "文字读取未完成"
        case unsupported = "暂不支持这种文字编码", damaged = "文字字节无法完整解码", external = "文件操作未完成"
    }
    public let domain: Domain
    public let code: Int?
    public let kind: Kind

    public init(_ error: Error) {
        if error is CancellationError {
            domain = .cancellation; code = nil; kind = .cancelled
        } else if error is LibraryError {
            domain = .library; code = nil; kind = .library
        } else if let error = error as? TXTError {
            domain = .text; code = nil
            switch error {
            case .unsupportedBOM: kind = .unsupported
            case .noSupportedEncoding, .malformedInput: kind = .damaged
            default: kind = .text
            }
        } else {
            let value = error as NSError
            switch value.domain {
            case NSCocoaErrorDomain: domain = .cocoa
            case NSPOSIXErrorDomain: domain = .posix
            case NSURLErrorDomain: domain = .url
            case "NSFileProviderErrorDomain": domain = .provider
            default: domain = .other
            }
            code = value.code
            kind = domain == .cocoa && value.code == NSUserCancelledError ? .cancelled : .external
        }
    }

    public var summary: String {
        kind.rawValue + "（" + domain.rawValue + (code.map { " / \($0)" } ?? "") + "）"
    }
}

public struct ImportDiagnosticState: Equatable, Sendable {
    public enum Callback: Equatable, Sendable { case none, selected, empty, failed, cancelled, delegateCancelled }
    public private(set) var attempt: UUID?
    public private(set) var pickerPresented = false
    public private(set) var callback: Callback = .none
    public private(set) var stage: ImportStage?
    public private(set) var history: [ImportStage] = []
    public private(set) var failure: ImportSafeFailure?
    public private(set) var failedAfter: ImportStage?

    public init() {}

    public mutating func begin(_ id: UUID) {
        self = Self(); attempt = id; pickerPresented = true
        record(.pickerWaiting, for: id)
    }

    public mutating func pickerClosed(for id: UUID) {
        guard attempt == id, pickerPresented else { return }
        pickerPresented = false
        if callback == .none { record(.pickerClosedWithoutSelection, for: id) }
        else { append(.pickerClosed) } // A late dismissal cannot replace reading/decoding progress.
    }

    @discardableResult
    public mutating func selected(for id: UUID, hasFile: Bool) -> Bool {
        guard attempt == id, callback == .none else { return false }
        callback = hasFile ? .selected : .empty
        record(hasFile ? .selectedCallback : .emptyCallback, for: id)
        return true
    }

    @discardableResult
    public mutating func delegateCancelled(for id: UUID) -> Bool {
        guard attempt == id, callback == .none else { return false }
        callback = .delegateCancelled
        record(.delegateCancelled, for: id)
        return true
    }

    @discardableResult
    public mutating func pickerFailed(_ error: Error, for id: UUID) -> Bool {
        guard attempt == id, callback == .none else { return false }
        let safe = ImportSafeFailure(error)
        callback = safe.kind == .cancelled ? .cancelled : .failed
        failure = safe; failedAfter = stage
        record(callback == .cancelled ? .cancellationCallback : .failedCallback, for: id)
        return true
    }

    public mutating func fail(_ error: Error, for id: UUID) {
        guard attempt == id else { return }
        failure = ImportSafeFailure(error); failedAfter = stage
        record(failure?.kind == .cancelled ? .cancelled : .failed, for: id)
    }

    public mutating func record(_ value: ImportStage, for id: UUID) {
        guard attempt == id else { return }
        stage = value; append(value)
    }

    private mutating func append(_ value: ImportStage) {
        if history.count < 64 { history.append(value) }
    }

    public var callbackSummary: String {
        switch callback {
        case .none: pickerPresented ? "尚未收到选中文件回调" : "选择器已关闭，未收到选中文件回调"
        case .selected: "已收到选中文件回调"
        case .empty: "已收到空结果回调，未选中文件"
        case .failed: "已收到失败回调，未收到选中文件回调"
        case .cancelled: "已收到明确取消错误回调，未选中文件"
        case .delegateCancelled: "已收到delegate取消回调，未选中文件"
        }
    }
}

import Foundation

/// Only the cancellation flag crosses executors; every access is protected by NSLock.
/// No IO or suspension occurs under the lock. Cancellation revokes transaction admission,
/// not an already admitted commit: callers must not check again after a successful write.
public final class BookmarkRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    public func check() throws {
        try Task.checkCancellation()
        if isCancelled { throw CancellationError() }
    }
}

import Foundation

struct EPUBParkState: Decodable, Sendable {
    let paths: [String]
    let imageBytes: Int
}

/// A bounded one-shot reply: a stalled WebContent process cannot strand an explicit exit.
@MainActor
final class EPUBParkReply {
    private var continuation: CheckedContinuation<EPUBParkState?, Never>?
    private var deadline: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<EPUBParkState?, Never>, onTimeout: @escaping @MainActor () -> Void = {}) {
        self.continuation = continuation
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.continuation != nil else { return }
            onTimeout()
            self.finish(nil)
        }
    }
    func finish(_ value: EPUBParkState?) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        continuation.resume(returning: value)
    }
}

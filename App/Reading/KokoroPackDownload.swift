import Foundation

enum KokoroDownloadError: Error { case response, length, space }

/// A single anonymous GET. URLSession and all mutable transfer state are confined to
/// the serial delegate queue (including cancellation and completion installation).
final class KokoroPackDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let archiveBytes: Int64 = 147_052_523
    static let official = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2")!
    static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else { return false }
        return host == "github.com" || host == "release-assets.githubusercontent.com" || host == "objects.githubusercontent.com"
    }
    static func accepts(_ response: URLResponse, expected: Int64) -> Bool {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, allowed(http.url) else { return false }
        return http.expectedContentLength == NSURLSessionTransferSizeUnknown || http.expectedContentLength == expected
    }

    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q }()
    private var session: URLSession?
    private var result: CheckedContinuation<Void, Error>?
    private var file: FileHandle?
    private var received: Int64 = 0
    private var percent = -1
    private var accepted = false
    private var cancelled = false
    private let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func fetch(to destination: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.addOperation { [self] in
                    guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                    result = continuation
                    do {
                        try Data().write(to: destination, options: .withoutOverwriting)
                        file = try FileHandle(forWritingTo: destination)
                        let config = URLSessionConfiguration.ephemeral
                        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
                        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 1800
                        let client = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                        session = client
                        var request = URLRequest(url: Self.official); request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                        client.dataTask(with: request).resume()
                    } catch { finish(.failure(error)) }
                }
            }
        } onCancel: {
            self.queue.addOperation { [self] in cancelled = true; finish(.failure(CancellationError())) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard result != nil, Self.allowed(request.url) else { completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        accepted = result != nil && Self.accepts(response, expected: Self.archiveBytes)
        completionHandler(accepted ? .allow : .cancel)
        if !accepted { finish(.failure(KokoroDownloadError.response)) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard accepted, result != nil, let file else { return }
        guard Int64(data.count) <= Self.archiveBytes - received else { finish(.failure(KokoroDownloadError.length)); return }
        do {
            try file.write(contentsOf: data); received += Int64(data.count)
            let p = Int(received * 100 / Self.archiveBytes)
            if p > percent { percent = p; progress(Double(p) / 100) }
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else if !accepted || received != Self.archiveBytes { finish(.failure(KokoroDownloadError.length)) }
        else { finish(.success(())) }
    }
    private func finish(_ outcome: Result<Void, Error>) {
        guard let continuation = result else { return }
        result = nil; session?.invalidateAndCancel(); session = nil
        var final = outcome
        do { try file?.close() } catch { if case .success = final { final = .failure(error) } }
        file = nil; continuation.resume(with: final)
    }
}

import Foundation

private final class StoryModelSessionPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Use the OS trust policy, but never resubmit using another HTTP credential.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return (.performDefaultHandling, nil)
        }
        return (.rejectProtectionSpace, nil)
    }
}

enum StoryModelTransport {
    /// Caller owns user confirmation and the immutable body. This method never retries,
    /// rewrites a URL, changes stream mode, or chooses a different model.
    static func complete(configuration: StoryModelConfiguration, body: Data,
                         onPartial: @escaping @Sendable (String) async -> Void) async throws -> String {
        try Task.checkCancellation()
        let key = try StoryModelVault.credential(for: configuration)
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpShouldHandleCookies = false
        request.httpBody = body

        let settings = URLSessionConfiguration.ephemeral
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        settings.urlCache = nil
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        settings.urlCredentialStorage = nil
        settings.timeoutIntervalForRequest = 45
        settings.timeoutIntervalForResource = 120
        let session = URLSession(configuration: settings, delegate: StoryModelSessionPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            try Task.checkCancellation()
            // The native async request handles cancellation while awaiting headers. Once it
            // returns, explicitly cancel its task even if the byte reader/callback is suspended.
            let (bytes, response) = try await session.bytes(for: request)
            let task = bytes.task
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let format = try responseFormat(response)
                return try await receive(bytes, format: format, onPartial: onPartial)
            } onCancel: { task.cancel() }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let safe = error as? StoryModelTransportError { throw safe }
            throw StoryModelTransportError.network
        }
    }

    static func responseFormat(_ response: URLResponse) throws -> StoryModelSSEParser.Format {
        guard let http = response as? HTTPURLResponse else { throw StoryModelTransportError.unsupportedResponse }
        guard (200..<300).contains(http.statusCode) else { throw StoryModelTransportError.http(http.statusCode) }
        guard http.statusCode != 206 else { throw StoryModelTransportError.truncated }
        guard response.expectedContentLength <= Int64(StoryModelSSEParser.maxBytes) else {
            throw StoryModelTransportError.responseTooLarge
        }
        switch http.mimeType?.lowercased() {
        case "text/event-stream": return .stream
        case "application/json": return .json
        default: throw StoryModelTransportError.unsupportedResponse
        }
    }

    static func receive<Bytes: AsyncSequence>(_ bytes: Bytes, format: StoryModelSSEParser.Format,
                                              onPartial: @Sendable (String) async -> Void) async throws -> String
        where Bytes.Element == UInt8 {
        var parser = StoryModelSSEParser(format: format)
        var nextPreview = ContinuousClock.now
        var pending = false
        for try await byte in bytes {
            try Task.checkCancellation()
            if try parser.feed(byte) {
                pending = true
                let now = ContinuousClock.now
                if now >= nextPreview {
                    await onPartial(parser.text)
                    pending = false
                    nextPreview = now.advanced(by: .milliseconds(100))
                }
            }
            if parser.done { break }
        }
        try Task.checkCancellation()
        let result = try parser.finish()
        if pending || format == .json { await onPartial(result) }
        try Task.checkCancellation()
        return result
    }
}

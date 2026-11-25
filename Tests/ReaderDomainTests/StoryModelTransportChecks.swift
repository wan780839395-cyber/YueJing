import Foundation
#if canImport(ReaderDomain)
@testable import ReaderDomain
#endif

private struct StoryModelCheckFailure: Error { let check: String }
private actor StoryModelPreviews {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

// Synthetic bytes and HTTP metadata only. Never touches the actual vault or URL loading system.
func checkStoryModelTransport() async throws {
    func check(_ ok: Bool, _ label: String) throws {
        if !ok { throw StoryModelCheckFailure(check: label) }
    }
    func rejects(_ expected: StoryModelTransportError, _ label: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch let actual as StoryModelTransportError where actual == expected { return }
        throw StoryModelCheckFailure(check: label)
    }
    func parse(_ input: String, _ format: StoryModelSSEParser.Format = .stream) throws -> String {
        var parser = StoryModelSSEParser(format: format)
        for byte in input.utf8 {
            _ = try parser.feed(byte)
            if parser.done { break }
        }
        return try parser.finish()
    }
    func frame(_ data: String) -> String { "data: \(data)\r\n\r\n" }
    let role = frame(#"{"choices":[{"index":0,"delta":{"role":"assistant","content":null}}]}"#)
    let first = frame(#"{"choices":[{"delta":{"content":"月🌙"}}]}"#)
    let second = frame(#"{"choices":[{"delta":{"content":"光"}}]}"#)
    let stop = frame(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
    let usage = frame(#"{"usage":{"completion_tokens":3},"choices":[]}"#)
    let done = frame("[DONE]")
    let stream = "\u{FEFF}: heartbeat\r\n\r\n" + role + first + second + stop + usage + done
    let whole = #"{"choices":[{"message":{"role":"assistant","content":"月光"},"finish_reason":"stop"}]}"#
    try check(try parse(first + done) == "月🌙", "terminal sentinel")
    try check(try parse(first + stop + usage) == "月🌙", "finished EOF")
    try check(try parse("data: {\ndata: \"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n" + done) == "x", "multiline data")
    try check(try parse(whole, .json) == "月光", "single JSON response")

    try rejects(.empty, "role only") { _ = try parse(role + done) }
    try rejects(.truncated, "no terminal evidence") { _ = try parse(first) }
    try rejects(.truncated, "torn final event") { _ = try parse(first + stop + "data: [DO") }
    try rejects(.truncated, "JSON missing stop") { _ = try parse(whole.replacingOccurrences(of: "\"stop\"", with: "null"), .json) }
    try rejects(.malformed, "bad packet") { _ = try parse(frame("{")) }
    try rejects(.malformed, "text after stop") { _ = try parse(first + stop + second + done) }
    try rejects(.providerError, "error envelope") { _ = try parse(first + frame(#"{"error":{"message":"synthetic"}}"#)) }
    try rejects(.providerError, "named error") { _ = try parse(first + "event: error\n\n") }
    try rejects(.refusal, "refusal delta") { _ = try parse(frame(#"{"choices":[{"delta":{"refusal":"no"}}]}"#)) }
    try rejects(.unsupportedTools, "tools delta") { _ = try parse(frame(#"{"choices":[{"delta":{"tool_calls":[{}]}}]}"#)) }
    try rejects(.length, "truncated by provider") { _ = try parse(first + stop.replacingOccurrences(of: "stop", with: "length")) }
    try rejects(.lineTooLong, "unterminated line bound") {
        var parser = StoryModelSSEParser(format: .stream)
        for _ in 0...StoryModelSSEParser.maxLine { _ = try parser.feed(65) }
    }
    try rejects(.responseTooLarge, "total bound") {
        var parser = StoryModelSSEParser(format: .json)
        for _ in 0...StoryModelSSEParser.maxBytes { _ = try parser.feed(32) }
    }

    let endpoint = "https://example.invalid/v1/chat/completions"
    let config = try StoryModelVault.configuration(endpoint: endpoint, model: "test/model")
    let changed = try StoryModelVault.configuration(endpoint: endpoint + "/", model: config.model)
    let composed = try StoryModelVault.configuration(endpoint: endpoint, model: "caf\u{E9}")
    let decomposed = try StoryModelVault.configuration(endpoint: endpoint, model: "cafe\u{301}")
    try check(config != changed && composed != decomposed, "credential binding uses exact bytes")
    for bad in ["http://example.invalid/chat", endpoint + "?", endpoint + "#x", "https://a:b@example.invalid/chat", "https://example.invalid"] {
        do { _ = try StoryModelVault.configuration(endpoint: bad, model: config.model) }
        catch StoryModelVaultError.invalidEndpoint { continue }
        throw StoryModelCheckFailure(check: "endpoint validation")
    }
    do {
        _ = try StoryModelVault.configuration(endpoint: endpoint, model: "\r\n")
        throw StoryModelCheckFailure(check: "model validation")
    } catch StoryModelVaultError.invalidModel {}
    do {
        try StoryModelVault.validateKey("test\r\nInjected: test")
        throw StoryModelCheckFailure(check: "header injection")
    } catch StoryModelVaultError.invalidKey {}
    for status in [307, 401, 429, 500] {
        guard let response = HTTPURLResponse(url: config.endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else { throw StoryModelCheckFailure(check: "HTTP fixture") }
        try rejects(.http(status), "HTTP status") { _ = try StoryModelTransport.responseFormat(response) }
    }

    func bytes(_ input: String) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in input.utf8 { continuation.yield(byte) }
            continuation.finish()
        }
    }
    let previews = StoryModelPreviews()
    let result = try await StoryModelTransport.receive(bytes(stream), format: .stream) { await previews.add($0) }
    let snapshots = await previews.values
    try check(result == "月🌙光" && snapshots == ["月🌙", result], "cumulative UTF-8 previews and final flush")

    // Cancel the child task from the first preview, not the test caller. Even with all
    // remaining bytes already buffered, receive must not turn this into a successful turn.
    let buffered = bytes(stream)
    let child = Task {
        try await StoryModelTransport.receive(buffered, format: .stream) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    do {
        _ = try await child.value
        throw StoryModelCheckFailure(check: "cancellation")
    } catch is CancellationError {}
}

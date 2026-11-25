import Foundation

// No associated values may contain request/response bytes, URL or provider diagnostics.
enum StoryModelTransportError: LocalizedError, Equatable {
    var errorDescription: String? {
        switch self {
        case .http(let status):
            if status == 401 || status == 403 { return "服务拒绝授权，请检查密钥及模型权限。" }
            if status == 429 { return "服务限流或额度不足，未自动重发。" }
            return "服务返回 HTTP \(status)，未保存本回合。"
        case .refusal: return "模型拒绝了这次生成，未保存本回合。"
        case .empty: return "服务没有返回正文，未保存本回合。"
        case .length: return "服务因输出长度限制而停止，未保存不完整正文。"
        case .truncated, .network: return "连接失败或回复中断，未自动重发；服务方可能已处理请求。"
        case .unsupportedTools: return "本次返回了工具调用，而不是故事正文。"
        case .responseTooLarge, .lineTooLong: return "服务回复超出接收上限，未保存本回合。"
        case .unsupportedResponse, .malformed, .providerError: return "服务响应不符合本次文本生成协议，未保存本回合。"
        }
    }

    case http(Int), network, unsupportedResponse, malformed, providerError
    case refusal, unsupportedTools, length, empty, truncated, responseTooLarge, lineTooLong
}

/// Byte-oriented framing: URLSession.AsyncBytes.lines would allocate an unbounded line first.
struct StoryModelSSEParser {
    enum Format { case stream, json }
    static let maxBytes = 2 * 1024 * 1024
    static let maxLine = 64 * 1024
    private static let maxEvent = 256 * 1024

    let format: Format
    private var total = 0
    private var line = Data()
    private var payload = Data() // One SSE event, or one bounded JSON response.
    private var firstLine = true
    private var skipLF = false
    private var stopped = false
    private(set) var done = false
    private(set) var text = ""

    init(format: Format) { self.format = format }

    /// True only when a complete event appended visible text.
    mutating func feed(_ byte: UInt8) throws -> Bool {
        guard total < Self.maxBytes else { throw StoryModelTransportError.responseTooLarge }
        total += 1
        if format == .json { payload.append(byte); return false }
        if skipLF {
            skipLF = false
            if byte == 10 { return false }
        }
        if byte == 10 || byte == 13 {
            skipLF = byte == 13
            defer { line.removeAll(keepingCapacity: true); firstLine = false }
            return try processLine()
        }
        guard line.count < Self.maxLine else { throw StoryModelTransportError.lineTooLong }
        line.append(byte)
        return false
    }

    private mutating func processLine() throws -> Bool {
        if firstLine && line.starts(with: [0xef, 0xbb, 0xbf]) { line.removeFirst(3) }
        guard let field = String(data: line, encoding: .utf8) else { throw StoryModelTransportError.malformed }
        if field.isEmpty {
            guard !payload.isEmpty else { return false }
            defer { payload.removeAll(keepingCapacity: true) }
            // Each data field contributes one LF, removed at dispatch per SSE framing.
            payload.removeLast()
            if payload.elementsEqual("[DONE]".utf8) { done = true; return false }
            return try consume(payload)
        }
        let colon = field.firstIndex(of: ":") ?? field.endIndex
        let name = field[..<colon]
        var value = field[colon...].dropFirst()
        if value.first == " " { value = value.dropFirst() }
        if name == "event" && value == "error" { throw StoryModelTransportError.providerError }
        guard name == "data" else { return false } // heartbeat, id, retry, etc.
        guard value.utf8.count + 1 <= Self.maxEvent - payload.count else {
            throw StoryModelTransportError.responseTooLarge
        }
        payload.append(contentsOf: value.utf8)
        payload.append(10)
        return false
    }

    private struct Present: Decodable { init(from decoder: Decoder) throws {} }
    private struct Packet: Decodable {
        let error: Present?
        let choices: [Choice]?
        let usage: Present?
    }
    private struct Choice: Decodable {
        let index: Int?
        let finish_reason: String?
        let delta: Message?
        let message: Message?
    }
    private struct Message: Decodable {
        let role: String?
        let content: String?
        let refusal: Present?
        let tool_calls: Present?
        let function_call: Present?
    }

    private mutating func consume(_ data: Data) throws -> Bool {
        guard let packet = try? JSONDecoder().decode(Packet.self, from: data) else {
            throw StoryModelTransportError.malformed
        }
        if packet.error != nil { throw StoryModelTransportError.providerError }
        if format == .stream, packet.choices?.isEmpty == true, packet.usage != nil { return false }
        guard let choices = packet.choices, choices.count == 1, let choice = choices.first,
              choice.index == nil || choice.index == 0 else { throw StoryModelTransportError.malformed }
        let message = format == .stream ? choice.delta : choice.message
        if message?.refusal != nil { throw StoryModelTransportError.refusal }
        if message?.tool_calls != nil || message?.function_call != nil { throw StoryModelTransportError.unsupportedTools }
        switch choice.finish_reason {
        case "length": throw StoryModelTransportError.length
        case "content_filter", "refusal": throw StoryModelTransportError.refusal
        case "tool_calls", "function_call": throw StoryModelTransportError.unsupportedTools
        case "stop", nil: break
        default: throw StoryModelTransportError.unsupportedResponse
        }
        guard !stopped, choice.delta == nil || choice.message == nil,
              message != nil || (format == .stream && choice.finish_reason == "stop" && choice.message == nil),
              message?.role == nil || message?.role == "assistant" else { throw StoryModelTransportError.malformed }
        stopped = choice.finish_reason == "stop"
        if let content = message?.content, !content.isEmpty {
            text.append(content)
            return true
        }
        return false
    }

    mutating func finish() throws -> String {
        if format == .json {
            guard !payload.isEmpty else { throw StoryModelTransportError.empty }
            _ = try consume(payload)
        } else if !line.isEmpty || !payload.isEmpty {
            // Never publish an event torn in the middle, even after an earlier stop chunk.
            throw StoryModelTransportError.truncated
        }
        guard stopped || done else { throw StoryModelTransportError.truncated }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoryModelTransportError.empty }
        return text
    }
}

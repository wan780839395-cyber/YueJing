import Foundation

// Keyed Foundation decoders discard duplicate members, and coercion via NSNumber loses
// distinctions ST relies on (false vs 0, 100001 vs 100001.0). Keep those distinctions
// until the preset has been projected onto the explicit snapshot allowlist.
enum StoryPresetJSON {
    case object([String: Self]), array([Self]), string(String), number(String), bool(Bool), null

    var object: [String: Self]? { if case let .object(value) = self { return value }; return nil }
    var array: [Self]? { if case let .array(value) = self { return value }; return nil }
    var string: String? { if case let .string(value) = self { return value }; return nil }
    var integer: Int? { if case let .number(value) = self { return Int(value) }; return nil }
    var bool: Bool? { if case let .bool(value) = self { return value }; return nil }
}

// No underlying errors, raw keys, field values or file names in diagnostics.
enum StoryPresetParseError: Error, LocalizedError {
    case limit, json, duplicateKey, format, definition, group, order

    var errorDescription: String? {
        switch self {
        case .limit: "预设超过大小、条目或文本上限。"
        case .json: "不是有效的 UTF-8 JSON。"
        case .duplicateKey: "JSON 对象含有重复字段。"
        case .format: "不是支持的 Chat Completion 预设。"
        case .definition: "提示词标识为空、无效或重复。"
        case .group: "需要唯一有效的全局排序组 100001。"
        case .order: "全局排序项无效或重复；enabled 必须为布尔值。"
        }
    }
}

struct StoryPresetJSONReader {
    private let bytes: [UInt8]
    private var index = 0
    private var nodes = 0
    private let decoder = JSONDecoder()

    init(_ data: Data) throws {
        guard data.count <= 2 * 1024 * 1024 else { throw StoryPresetParseError.limit }
        bytes = Array(data)
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { index = 3 }
    }

    mutating func read() throws -> StoryPresetJSON {
        let root = try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw StoryPresetParseError.json }
        return root
    }

    private var next: UInt8? { index < bytes.count ? bytes[index] : nil }
    private mutating func take(_ byte: UInt8) -> Bool {
        guard next == byte else { return false }; index += 1; return true
    }
    private mutating func whitespace() {
        while let b = next, b == 32 || b == 9 || b == 10 || b == 13 { index += 1 }
    }
    private mutating func literal(_ literal: String) throws {
        for b in literal.utf8 where !take(b) { throw StoryPresetParseError.json }
    }

    private mutating func value(depth: Int) throws -> StoryPresetJSON {
        nodes += 1
        guard nodes <= 32_768, depth <= 48 else { throw StoryPresetParseError.limit }
        whitespace()
        switch next {
        case 123: // object
            index += 1; whitespace()
            var result: [String: StoryPresetJSON] = [:]
            if take(125) { return .object(result) }
            repeat {
                whitespace()
                guard result.count < 512 else { throw StoryPresetParseError.limit }
                let key = try string()
                guard key.utf8.count <= 256 else { throw StoryPresetParseError.limit }
                guard result[key] == nil else { throw StoryPresetParseError.duplicateKey }
                whitespace(); guard take(58) else { throw StoryPresetParseError.json }
                result[key] = try value(depth: depth + 1); whitespace()
            } while take(44)
            guard take(125) else { throw StoryPresetParseError.json }
            return .object(result)
        case 91: // array
            index += 1; whitespace()
            var result: [StoryPresetJSON] = []
            if take(93) { return .array(result) }
            repeat {
                guard result.count < 4096 else { throw StoryPresetParseError.limit }
                result.append(try value(depth: depth + 1)); whitespace()
            } while take(44)
            guard take(93) else { throw StoryPresetParseError.json }
            return .array(result)
        case 34: return .string(try string())
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 110: try literal("null"); return .null
        default: return .number(try number())
        }
    }

    private mutating func string() throws -> String {
        let start = index
        guard take(34) else { throw StoryPresetParseError.json }
        var escaped = false
        while let byte = next {
            index += 1
            guard byte >= 32 else { throw StoryPresetParseError.json }
            if byte == 34 {
                let body = bytes[(start + 1)..<(index - 1)]
                guard let utf8 = String(bytes: body, encoding: .utf8) else { throw StoryPresetParseError.json }
                let text: String
                if escaped {
                    // Decode just the quoted scalar, never a keyed container. This also
                    // validates escapes and surrogate pairs. Do not forward decoder errors.
                    guard let decoded = try? decoder.decode(String.self, from: Data(bytes[start..<index])) else {
                        throw StoryPresetParseError.json
                    }
                    text = decoded
                } else { text = utf8 }
                guard text.utf8.count <= 256 * 1024 else { throw StoryPresetParseError.limit }
                return text
            }
            if byte == 92 { escaped = true; guard next != nil else { break }; index += 1 }
        }
        throw StoryPresetParseError.json
    }

    private mutating func digits() -> Bool {
        let start = index
        while let b = next, (48...57).contains(b) { index += 1 }
        return index != start
    }

    private mutating func number() throws -> String {
        let start = index
        _ = take(45)
        guard take(48) || digits() else { throw StoryPresetParseError.json }
        if take(46), !digits() { throw StoryPresetParseError.json }
        if take(101) || take(69) {
            _ = take(43) || take(45)
            guard digits() else { throw StoryPresetParseError.json }
        }
        guard index - start <= 128 else { throw StoryPresetParseError.limit }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
}

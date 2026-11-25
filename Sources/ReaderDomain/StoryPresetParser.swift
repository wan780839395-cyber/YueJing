import CryptoKit
import Foundation

public struct StoryPresetSummary: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let canSelect: Bool
}

public struct StoryPresetVersion: Codable, Equatable, Sendable {
    public let summary: StoryPresetSummary
    public let entries: [StoryPresetEntry]
    public let issues: [String]
    public let parameters: [String: String]
    public let ignoredFields: [String]
}

public struct StoryPresetEntry: Codable, Equatable, Sendable {
    public let identifier: String
    public let role: String
    public let enabled: Bool
    public let content: String
    public let isHistory: Bool
}

/// Offline ST 1.12.12 Chat Completion subset. Entries are inspection data, not a
/// partially usable request. Only `canSelect` permits later use of the active rows.
enum StoryPresetParser {
    private typealias Object = [String: StoryPresetJSON]
    private static let builtins: Set<String> = [
        "main", "nsfw", "jailbreak", "enhanceDefinitions", "dialogueExamples", "worldInfoBefore",
        "worldInfoAfter", "charDescription", "charPersonality", "personaDescription", "scenario"
    ]
    private static let promptFields: Set<String> = [
        "identifier", "name", "role", "content", "system_prompt", "marker", "injection_position",
        "injection_depth", "forbid_overrides"
    ]
    private static let ignoredKeys: Set<String> = [
        "custom_url", "reverse_proxy", "proxy_password", "api_key", "api_url_scale", "custom_include_headers",
        "name", "show_external_models", "openai_model", "custom_model"
    ]
    private static let ranges: [String: ClosedRange<Double>] = [
        "temperature": 0...2, "top_p": 0...1, "presence_penalty": -2...2, "frequency_penalty": -2...2
    ]

    static func parse(_ data: Data, fallbackName: String) throws -> StoryPresetVersion {
        var reader = try StoryPresetJSONReader(data)
        guard let root = try reader.read().object,
              root["spec"]?.string?.hasPrefix("chara_card") != true,
              root["first_mes"] == nil, root["entries"] == nil,
              let prompts = root["prompts"]?.array, let groups = root["prompt_order"]?.array else {
            throw StoryPresetParseError.format
        }
        guard prompts.count <= 1024, groups.count <= 128 else { throw StoryPresetParseError.limit }
        // ST identifier lookup is exact; Swift String equality folds canonically equivalent spellings.
        var definitions = [Data: Object]()
        for prompt in prompts {
            guard let obj = prompt.object, let id = identifier(obj),
                  definitions.updateValue(obj, forKey: Data(id.utf8)) == nil else {
                throw StoryPresetParseError.definition
            }
        }
        let rows = try globalOrder(groups)
        var issues: [String] = [], parameters: [String: String] = [:], ignored: [String] = []
        inspectSettings(root, issues: &issues, parameters: &parameters, ignored: &ignored)
        var entries: [StoryPresetEntry] = [], seen: Set<Data> = []
        for (index, item) in rows.enumerated() {
            guard let row = item.object, row.count == 2, let id = identifier(row),
                  let enabled = row["enabled"]?.bool, seen.insert(Data(id.utf8)).inserted else {
                throw StoryPresetParseError.order
            }
            let definition = definitions[Data(id.utf8)]
            let history = id == "chatHistory"
            let text = definition?["content"]?.string ?? ""
            let role = definition?["role"]?.string ?? ""
            let knownRole = ["system", "assistant", "user"].contains(role)
            entries.append(.init(identifier: id, role: history || !knownRole ? "" : role,
                                 enabled: enabled, content: history ? "" : text, isHistory: history))
            guard enabled else { continue }
            let location = "全局排序第 \(index + 1) 项："
            guard let definition else {
                issues.append(location + "找不到启用项的定义。")
                continue
            }
            if !definition.keys.allSatisfy(promptFields.contains) {
                issues.append(location + "含未支持的提示词字段。")
            }
            if let position = definition["injection_position"], position.integer != 0 {
                issues.append(location + "只支持相对注入位置。")
            }
            if history {
                if definition["marker"]?.bool != true || !emptyHistoryBody(definition["content"]) {
                    issues.append(location + "chatHistory 必须是无正文的历史标记。")
                }
            } else {
                if builtins.contains(id) || !absentOrFalse(definition["marker"]) || !absentOrFalse(definition["system_prompt"]) {
                    issues.append(location + "不支持内置条目或角色、世界资料依赖。")
                }
                if !knownRole || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(location + "角色不支持或缺少正文。")
                }
                if text.range(of: #"\{\{|\}\}|<(?:user|char|bot|group)>"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    issues.append(location + "含未展开的宏；不推测缺失的角色或其他资料。")
                }
            }
        }
        if !entries.contains(where: { $0.isHistory && $0.enabled }) {
            issues.append("chatHistory 缺失或未启用。")
        }
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = displayName(root["name"]?.string) ?? displayName(fallbackName) ?? "未命名预设"
        return .init(summary: .init(id: id, name: name, canSelect: issues.isEmpty), entries: entries,
                     issues: issues, parameters: parameters, ignoredFields: ignored)
    }

    private static func identifier(_ obj: Object) -> String? {
        guard let id = obj["identifier"]?.string, id.utf8.count <= 256,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return id
    }

    private static func displayName(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.prefix(96).filter { !CharacterSet.controlCharacters.contains($0) }
        let name = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func globalOrder(_ groups: [StoryPresetJSON]) throws -> [StoryPresetJSON] {
        var selected: [StoryPresetJSON]?
        for group in groups {
            guard let obj = group.object, let id = obj["character_id"]?.integer else { throw StoryPresetParseError.group }
            guard id == 100001 else { continue }
            guard selected == nil, obj.count == 2, let order = obj["order"]?.array else { throw StoryPresetParseError.group }
            guard order.count <= 1024 else { throw StoryPresetParseError.limit }
            selected = order
        }
        guard let selected else { throw StoryPresetParseError.group }
        return selected
    }

    private static func absentOrFalse(_ value: StoryPresetJSON?) -> Bool { value == nil || value?.bool == false }

    private static func emptyHistoryBody(_ value: StoryPresetJSON?) -> Bool {
        if case .null? = value { return true }
        return value == nil || value?.string == ""
    }

    private static func neutral(_ key: String, _ value: StoryPresetJSON) -> Bool {
        switch key {
        case "squash_system_messages", "wrap_in_quotes": value.bool == false
        case "send_if_empty", "custom_include_body", "custom_exclude_body", "new_chat_prompt": value.string == ""
        case "top_k", "top_a", "min_p", "names_behavior": value.integer == 0
        case "n", "repetition_penalty": value.integer == 1
        case "seed": value.integer == -1
        case "bias_preset_selected": value.string == "Default (none)"
        case "chat_completion_source": value.string == "openai"
        default: false
        }
    }

    private static func inspectSettings(_ root: Object, issues: inout [String], parameters: inout [String: String],
                                        ignored: inout [String]) {
        var unsupported = false
        for key in root.keys.sorted() where key != "prompts" && key != "prompt_order" {
            guard let value = root[key] else { continue }
            if let range = ranges[key] {
                if case let .number(raw) = value, let number = Double(raw), range.contains(number) {
                    parameters[key] = raw
                } else { issues.append("\(key)：参数类型或范围无效。") }
            } else if key == "openai_max_tokens" {
                if let n = value.integer, (1...2_147_483_647).contains(n) { parameters["max_tokens"] = String(n) }
                else { issues.append("openai_max_tokens：需要范围内的整数。") }
            } else if ignoredKeys.contains(key) || neutral(key, value) {
                ignored.append(key) // Never copy connection, header, or model values.
            } else {
                unsupported = true // Even an unknown key name can contain private data.
            }
        }
        if unsupported { issues.append("含未支持的顶层设置或非默认行为。") }
    }
}

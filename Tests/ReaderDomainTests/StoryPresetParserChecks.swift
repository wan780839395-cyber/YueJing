import Foundation
#if canImport(ReaderDomain)
@testable import ReaderDomain
#endif

private struct PresetCheckFailure: Error { let check: String }

// No files, bundles, credentials or services needed. Failures identify a check, not input bytes.
func checkStoryPresetParser() throws {
    func check(_ condition: Bool, _ label: String) throws {
        if !condition { throw PresetCheckFailure(check: label) }
    }
    func parse(_ source: String) throws -> StoryPresetVersion {
        try StoryPresetParser.parse(Data(source.utf8), fallbackName: "渡口")
    }
    func invalid(_ bytes: Data, _ label: String) throws {
        do { _ = try StoryPresetParser.parse(bytes, fallbackName: "检查") }
        catch is StoryPresetParseError { return }
        throw PresetCheckFailure(check: label)
    }

    // Synthetic ferry fixture (same text and selected order as examples/ferry.json).
    let ferry = #"""
    {"temperature":0.7,"top_p":0.9,"openai_max_tokens":480,"new_chat_prompt":"","squash_system_messages":false,
     "prompts":[{"identifier":"A","role":"system","content":"从一场雨写起。","system_prompt":false},
                {"identifier":"B","role":"system","content":"让人物先行动，再交代原因。"},
                {"identifier":"C","role":"system","content":"只写阿禾亲眼看见的事。"},
                {"identifier":"chatHistory","marker":true,"system_prompt":true}],
     "prompt_order":[{"character_id":100000,"order":[]},{"character_id":100001,"order":[
         {"identifier":"C","enabled":true},{"identifier":"A","enabled":false},
         {"identifier":"B","enabled":true},{"identifier":"chatHistory","enabled":true}]}]}
    """#
    func edit(_ from: String, _ to: String) -> String { ferry.replacingOccurrences(of: from, with: to) }
    func extra(_ fields: String) -> String { "{" + fields + "," + ferry.dropFirst() }
    let ready = try parse(ferry)
    try check(ready.summary.canSelect && ready.issues.isEmpty && ready.summary.name == "渡口", "ready")
    try check(ready.entries.map(\.identifier) == ["C", "A", "B", "chatHistory"], "order")
    try check(ready.entries.map(\.isHistory) == [false, false, false, true], "history position")
    try check(ready.entries.map(\.enabled) == [true, false, true, true], "switches")
    try check(ready.entries.prefix(3).map(\.role) == ["system", "system", "system"], "roles")
    try check(ready.entries.map(\.content) == ["只写阿禾亲眼看见的事。", "从一场雨写起。", "让人物先行动，再交代原因。", ""], "literal bodies")
    try check(ready.parameters == ["temperature":"0.7", "top_p":"0.9", "max_tokens":"480"], "mapped parameters")
    try check(ready.ignoredFields == ["new_chat_prompt", "squash_system_messages"], "neutral settings")

    let mixed = edit(#""system","content":"从一场雨写起。""#, #""assistant","content":"  A\n""#)
        .replacingOccurrences(of: #""A","enabled":false"#, with: #""A","enabled":true"#)
        .replacingOccurrences(of: #""system","content":"让人物先行动，再交代原因。""#, with: #""user","content":" B\t""#)
    let roles = try parse(mixed)
    try check(roles.summary.canSelect && roles.entries.filter(\.enabled).prefix(3).map(\.role) == ["system", "assistant", "user"], "mixed roles")
    try check(roles.entries[1].content == "  A\n" && roles.entries[2].content == " B\t", "escaped whitespace")
    try check(try parse(edit("从一场雨写起。", "{{char}}")).summary.canSelect, "disabled macro")
    try check(try parse(edit(#""C","role""#, #""C","injection_position":0,"injection_depth":9,"role""#)).summary.canSelect, "relative position")
    let missing = #""C","enabled":true"#
    let body = #""content":"只写阿禾亲眼看见的事。""#
    let blocked = [
        edit(body, #""content":"{{future::x}}""#), edit(body, #""content":"<ChAr>""#),
        edit(body, #""content":"{{user}}""#), edit(body, #""content":"}}""#),
        edit(body, #""content":"x","injection_position":1"#), edit(body, #""content":"x","injection_position":false"#),
        edit(body, #""content":"x","marker":0"#), edit(body, #""content":"x","custom_action":{}"#),
        edit(#""role":"system""#, #""role":"tool""#), edit(#""role":"system","#, ""),
        edit(#""C""#, #""charDescription""#), edit(missing, #""missing","enabled":true"#),
        edit(#""chatHistory","enabled":true"#, #""chatHistory","enabled":false"#),
        edit(#""marker":true"#, #""marker":1"#), edit(#""marker":true"#, #""marker":true,"content":"x""#),
        edit(#""temperature":0.7"#, #""temperature":true"#), edit(#""top_p":0.9"#, #""top_p":2"#),
        edit("480", "480.0"), edit("480", "2147483648"), extra(#""n":1.0"#), extra(#""wrap_in_quotes":0"#),
        extra(#""custom_include_body":"nonempty""#), extra(#""extensions":{}"#)
    ]
    for (n, source) in blocked.enumerated() {
        let result = try parse(source)
        try check(!result.summary.canSelect && !result.issues.isEmpty && result.entries.count == 4, "blocked \(n)")
    }

    let invalidSources = ["{}", "[]", "", ferry + "x", extra(#""entries":{}"#), extra(#""spec":"chara_card_v2""#),
        edit("100000", "100001"), edit("100001", "100002"), edit("100001", "100001.0"), edit("100001", "true"),
        edit(#""identifier":"A","role""#, #""identifier":"B","role""#),
        edit(missing, #""B","enabled":true"#), edit(missing, #""C","enabled":1"#), edit(missing, #""C","enabled":"true""#),
        edit(missing, #""C","enabled":true,"extra":0"#), edit("100001,", #"100001,"extra":0,"#),
        extra(#""temperature":0"#), extra(#""api_key":{"k":1,"\u006b":2}"#), edit("480", "0480"), edit("480", "1e"),
        edit("从一场雨写起。", #"\q"#), edit("从一场雨写起。", #"\uD800"#), edit("从一场雨写起。", String(repeating: "a", count: 262_145)),
        extra(#""api_key":"# + String(repeating: "[", count: 50) + "0" + String(repeating: "]", count: 50))]
    for (n, source) in invalidSources.enumerated() { try invalid(Data(source.utf8), "malformed \(n)") }
    try invalid(Data([0xff]), "encoding")
    let budget = 2 * 1024 * 1024
    let padded = Data(ferry.utf8) + Data(repeating: 32, count: budget - ferry.utf8.count)
    try check(try StoryPresetParser.parse(padded, fallbackName: "").summary.canSelect, "at byte limit")
    try invalid(padded + Data([32]), "above byte limit")

    let minimal = #"{"prompts":[],"prompt_order":[{"character_id":100001,"order":[]}]}"#
    let minimalResult = try parse(minimal)
    try check(!minimalResult.summary.canSelect && minimalResult.summary.id == "3f2d6e9662cc8675c9aa7ef838008b699e87b55c6d8d0b59e1ea8686ca445aa0", "raw digest")
    let bom = try StoryPresetParser.parse(Data([0xef,0xbb,0xbf]) + Data(ferry.utf8), fallbackName: "渡口")
    try check(bom.summary.id != ready.summary.id && bom.entries == ready.entries, "BOM identity")
    let longName = try parse(extra("\"name\":\"" + String(repeating: "月", count: 500) + "\"")).summary.name
    try check(longName == String(repeating: "月", count: 96), "bounded name")

    // Synthetic canaries only. Neither values nor arbitrary attacker-chosen field names belong in diagnostics.
    let local = #""api_key":"CANARY_key","custom_include_headers":{"h":"CANARY_header"},"openai_model":"CANARY_model","reverse_proxy":"CANARY_proxy""#
    for includeUnknown in [false, true] {
        let result = try parse(extra(local + (includeUnknown ? #","CANARY_field":"CANARY_value""# : "")))
        try check(result.summary.canSelect == !includeUnknown, "safe settings classification")
        try check(result.ignoredFields == ["api_key", "custom_include_headers", "new_chat_prompt", "openai_model", "reverse_proxy", "squash_system_messages"], "names only")
        let encoded = try JSONEncoder().encode(result)
        try check(!String(decoding: encoded, as: UTF8.self).contains("CANARY_"), "snapshot redaction")
        try check(try JSONDecoder().decode(StoryPresetVersion.self, from: encoded) == result, "snapshot round trip")
    }
}

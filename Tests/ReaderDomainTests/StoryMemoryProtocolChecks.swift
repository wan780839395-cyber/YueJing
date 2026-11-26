import Foundation
#if canImport(ReaderDomain)
import ReaderDomain
#endif

private struct MemoryCheckFailure: Error { let check: String }

func checkStoryMemoryProtocol() throws {
    typealias P = StoryMemoryProtocol
    typealias F = StoryMemoryFact
    func check(_ condition: Bool, _ label: String) throws {
        if !condition { throw MemoryCheckFailure(check: label) }
    }
    func rejects(_ label: String, _ run: () throws -> Void) throws {
        do { try run() } catch { return }
        throw MemoryCheckFailure(check: label)
    }
    func raw(_ facts: [F]) throws -> String { String(decoding: try JSONEncoder().encode(facts), as: UTF8.self) }
    func held(_ evidence: String, by holder: String = "甲", item: String = "钥匙") -> F {
        F(kind: "possession", subject: item, value: holder, evidence: evidence)
    }
    let receipt = held("甲接过钥匙。"), handback = held("甲把钥匙还给乙。", by: "乙")
    let promise = F(kind: "promise", subject: "甲｜乙｜明日｜南门｜会面", value: "已约定", evidence: "甲答应乙明日在南门会面。")
    let knows = F(kind: "knowledge", subject: "甲｜钥匙｜在｜木箱中", value: "已知", evidence: "甲知道钥匙在木箱中。")
    let alsoKnows = F(kind: "knowledge", subject: "甲｜账本｜在｜桌上", value: "已知", evidence: "甲知道账本在桌上。")
    let facts = [receipt, promise, knows, alsoKnows]
    let narration = "门开了。\n" + facts.map(\.evidence).joined(separator: "\n")
    let json = try raw(facts), reply = narration + P.marker + json
    try check(P.marker == "\n<YJ_MEMORY_V1>\n" && P.instruction.contains(P.marker), "reserved header")
    let good = P.split(reply)
    try check(good.narration == narration && good.changes == facts, "round trip / two knowledge slots")
    try F.validate([handback], narration: handback.evidence)
    let named = held("【林舟】拿着【铜铃】。", by: "林舟", item: "铜铃")
    try F.validate([named], narration: named.evidence)

    let positive = held("甲拿着钥匙。")
    for (i, context) in ["甲没拿着钥匙。", "甲拒绝接过钥匙。", "甲打算拿着钥匙。", "如果甲拿着钥匙。",
                         "守卫说甲拿着钥匙。", "传言如下：\n甲拿着钥匙。", "乙相信丙知道甲拿着钥匙。",
                         "乙说道：“开门。\n甲拿着钥匙。”", "「场景（灯亮了！甲拿着钥匙。）」",
                         "这是假设。甲拿着钥匙。", "原稿写道：\n甲拿着钥匙。", "甲拿着钥匙？"].enumerated() {
        try rejects("context \(i)") { try F.validate([positive], narration: context) }
        try rejects("not a positive sentence \(i)") { try F.validate([held(context)], narration: context) }
    }
    for (i, forged) in [held(positive.evidence, by: "乙"), held(positive.evidence, item: "地图"),
                        held(handback.evidence), F(kind: "promise", subject: "甲", value: "已约定", evidence: promise.evidence),
                        F(kind: "knowledge", subject: "甲", value: "已知", evidence: knows.evidence),
                        F(kind: "mood", subject: "钥匙", value: "甲", evidence: positive.evidence)].enumerated() {
        try rejects("relation \(i)") { try F.validate([forged], narration: forged.evidence) }
    }
    try rejects("conflicting holders") { try F.validate([receipt, handback], narration: receipt.evidence + handback.evidence) }
    try rejects("repeated slot") { try F.validate([knows, knows], narration: knows.evidence) }
    try rejects("count") { try F.validate(Array(repeating: receipt, count: 17), narration: narration) }
    try rejects("field bytes") { try F.validate([held(String(repeating: "甲", count: 150))], narration: narration) }
    try rejects("oversize narration") { try F.validate([], narration: String(repeating: "a", count: 131073)) }

    let duplicateKey = #"[{"kind":"possession","\u006bind":"possession","subject":"钥匙","value":"甲","evidence":"甲接过钥匙。"}]"#
    let extraKey = #"[{"kind":"possession","subject":"钥匙","value":"甲","evidence":"甲接过钥匙。","other":"x"}]"#
    for (i, tail) in ["", "[", "null", "[{}]", "[[],]", "[]\n说明", "```json\n[]\n```", duplicateKey, extraKey,
                      String(json.dropLast()) + ",]", "[]" + P.marker + "[]", String(repeating: " ", count: 12289) + "[]",
                      try raw([receipt, held("乙拿着地图。", by: "乙", item: "地图")])].enumerated() {
        try rejects("repair must throw \(i)") { _ = try P.parseChanges(tail, narration: narration) }
        let bad = P.split(narration + P.marker + tail)
        try check(bad.narration == narration && bad.changes == nil, "atomic failure preserves narration \(i)")
    }
    let absent = P.split(narration + "\n")
    try check(absent.narration == narration + "\n" && absent.changes == nil, "missing manifest")
    let noChange = P.split("门开了。" + P.marker + " \n[]\t")
    try check(noChange.narration == "门开了。" && noChange.changes == [], "explicit no change")
    for incomplete in ["[]", try raw([receipt]), try raw(Array(facts.dropLast()))] {
        let missing = P.split(narration + P.marker + incomplete)
        try check(missing.narration == narration && missing.changes == nil, "omissions even in mixed prose")
        try rejects("explicit repair cannot certify omissions") { _ = try P.parseChanges(incomplete, narration: narration) }
    }
    try check(P.localProposal(narration) == nil, "mixed prose is not fully reconstructible")
    let empty = P.split(P.marker + "[]")
    try check(empty.narration.isEmpty && empty.changes == [], "caller owns empty narration policy")
    let repaired = try P.parseChanges(json, narration: narration)
    try check(repaired == facts, "explicit repair")

    // Cover every cumulative chunk ending: in each marker character, inside JSON, and after it.
    for end in reply.indices where end >= reply.index(reply.startIndex, offsetBy: narration.count) {
        try check(P.visiblePrefix(String(reply[..<end])) == narration, "preview boundary")
    }
    try check(P.visiblePrefix(reply) == narration, "completed preview")
    let interrupted = P.split(narration + "\n<YJ_MEM")
    try check(interrupted.narration == narration && interrupted.changes == nil, "interrupted header")
    try check(P.visiblePrefix(narration + "\n<YJ_X") == narration + "\n<YJ_X", "release false prefix")

    let received = held("我从阿宁手里接过钥匙。", by: "我")
    let returned = held("我把钥匙还给了阿宁。", by: "阿宁")
    let known = F(kind: "knowledge", subject: "小青｜铜铃｜在｜桌上", value: "已知", evidence: "小青知道铜铃在桌上。")
    let slot = "我｜阿宁｜八月初三｜南门｜会面"
    let promised = F(kind: "promise", subject: slot, value: "已约定", evidence: "我答应阿宁八月初三在南门会面。")
    let fulfilled = F(kind: "promise", subject: slot, value: "已兑现", evidence: "我履行了与阿宁八月初三在南门会面的约定。")
    let breached = F(kind: "promise", subject: slot, value: "已失约", evidence: "我违背了与阿宁八月初三在南门会面的约定。")
    for state in [promised, fulfilled, breached] {
        let turn = [received, known, state]
        let body = "\n" + turn.map(\.evidence).joined(separator: "\n") + "  "
        try check(P.localProposal(body) == turn, "rebuild natural sentences in order")
        try F.validate(Array(turn.reversed()), narration: body)
        try check(P.split(body + P.marker + "[]").changes == nil, "no false empty on fully recognized prose")
    }
    try check(P.localProposal(returned.evidence) == [returned], "natural handback")
    let afterSpeech = "“晚安。”" + received.evidence
    try F.validate([received], narration: afterSpeech)
    try check(P.localProposal(afterSpeech) == nil && P.split(afterSpeech + P.marker + "[]").changes == nil, "speech isn't recoverable but can't hide the next change")
    for subject in ["阿宁｜我｜八月初三｜南门｜会面", "我｜阿宁｜八月初四｜南门｜会面", "我｜阿宁｜八月初三｜北门｜会面"] {
        let wrong = F(kind: "promise", subject: subject, value: fulfilled.value, evidence: fulfilled.evidence)
        try rejects("forged promise identity") { try F.validate([wrong], narration: fulfilled.evidence) }
    }
    try rejects("false fulfillment") {
        try F.validate([F(kind: "promise", subject: slot, value: fulfilled.value, evidence: breached.evidence)], narration: breached.evidence)
    }
    try rejects("giver is not recipient") { try F.validate([held(received.evidence, by: "阿宁")], narration: received.evidence) }
    for falseEvidence in ["我没有履行与阿宁八月初三在南门会面的约定。", "我打算履行与阿宁八月初三在南门会面的约定。",
                          "如果" + fulfilled.evidence, "有人说：“" + fulfilled.evidence + "”", "我没能阻止阿宁拿着钥匙。",
                          "【不是我】拿着钥匙。", "我履行了约定。", "阿宁失约了。", "我如期到了南门。"] {
        try check(P.localProposal(falseEvidence) == nil, "don't invent actor, status or identity")
        try rejects("forged terminal status in context") { try F.validate([fulfilled], narration: falseEvidence) }
    }
    for partial in ["", " \n", known.evidence + "尾句未完", known.evidence + "是吗？", "“" + known.evidence + "”",
                    received.evidence + returned.evidence, promised.evidence + breached.evidence,
                    String(repeating: "x", count: 131073)] {
        try check(P.localProposal(partial) == nil, "incomplete, ambiguous, conflicting or oversized local proposal")
    }
}

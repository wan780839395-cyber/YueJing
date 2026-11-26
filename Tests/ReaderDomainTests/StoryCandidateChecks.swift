import Foundation
#if canImport(ReaderDomain)
import ReaderDomain
#endif

private struct CandidateCheckFailure: Error {
    let label: String
}

func checkStoryCandidateChecks() throws {
    typealias Fact = StoryMemoryFact
    func check(_ label: String, _ narration: String, _ proposal: [Fact], accept: Bool) throws {
        let json = String(decoding: try JSONEncoder().encode(proposal), as: UTF8.self)
        let result = StoryMemoryProtocol.split(narration + StoryMemoryProtocol.marker + json)
        guard result.narration == narration, accept ? result.changes == proposal : result.changes == nil else {
            throw CandidateCheckFailure(label: label)
        }
    }
    let proposition = "《航程札记》藏在桌上"
    let knowledgeSlot = "阿砚｜" + proposition
    func knows(_ sentence: String, _ slot: String) -> Fact {
        Fact(kind: "knowledge", subject: slot, value: "已知", evidence: sentence)
    }
    let heard = "阿砚从信中得知" + proposition + "。"
    let exclusive = "只有阿砚一人知道" + proposition + "。"
    let read = "阿砚通读了《航程札记》。"
    let k = knows(heard, knowledgeSlot)
    try check("direct", heard, [k], accept: true)
    try check("exclusive", exclusive, [knows(exclusive, knowledgeSlot)], accept: true)
    try check("read", read, [Fact(kind: "knowledge", subject: "阿砚｜《航程札记》", value: "已读", evidence: read)], accept: true)
    try check("reading is not knowledge of contents", read, [knows(read, knowledgeSlot)], accept: false)
    try check("altered proposition", heard, [knows(heard, "阿砚｜《航程札记》藏在码头")], accept: false)
    try check("replaced relation", heard, [knows(heard, "阿砚｜《航程札记》｜在｜桌上")], accept: false)
    try check("legacy fact cannot be omitted", "甲拿着钥匙。" + heard, [k], accept: false)
    let named = "沈宜获悉" + proposition + "。"
    let namedFact = knows(named, "沈宜｜" + proposition)
    try check("narrated name", "来人姓沈，名宜。" + named, [namedFact], accept: true)
    try check("dialogue cannot license identity", "“来人姓沈，名宜。”" + named, [namedFact], accept: false)
    try check("partial manifest", heard + exclusive, [k], accept: false)
    for lead in ["阿砚在场，小青说", "甲听乙转述，", "若", "传闻", "她说：\n", "我不知道是否"] {
        let n = lead + heard
        try check("substring: " + lead, n, [k], accept: false)
        try check("whole forged attribution: " + lead, n, [knows(n, knowledgeSlot)], accept: false)
    }
    for n in ["阿砚和小青都知道", "阿砚问小青是否知道", "她知道", "阿砚并不知道", "阿砚以为"] {
        let sentence = n + proposition + "。"
        try check(n, sentence, [knows(sentence, knowledgeSlot)], accept: false)
    }
    try check("reported inside dialogue", "甲说：“先坐。" + heard + "”", [k], accept: false)
    let slot = "阿砚｜乙｜归还《航程札记》"
    let pact = "阿砚向乙承诺归还《航程札记》。"
    let fulfilled = "阿砚兑现了向乙许下的归还《航程札记》的承诺。"
    let broken = "阿砚违背了向乙许下的归还《航程札记》的承诺。"
    func promise(_ n: String, _ s: String, _ value: String) -> Fact {
        Fact(kind: "promise", subject: s, value: value, evidence: n)
    }
    for (n, state) in [(pact, "已约定"), (fulfilled, "已兑现"), (broken, "已失约")] {
        try check(state, n, [promise(n, slot, state)], accept: true)
        for wrongSlot in ["乙｜阿砚｜归还《航程札记》", "甲｜乙｜归还《航程札记》", "阿砚｜乙｜保管《航程札记》", "阿砚|乙|归还《航程札记》"] {
            try check("forged promise slot", n, [promise(n, wrongSlot, state)], accept: false)
        }
    }
    try check("fulfilled is not new promise", fulfilled, [promise(fulfilled, slot, "已约定")], accept: false)
    let notYet = "阿砚尚未向乙承诺归还《航程札记》。"
    try check("negated formation", notYet, [promise(notYet, slot, "已约定")], accept: false)
    for n in ["甲说" + pact, "阿砚尚未向乙承诺归还《航程札记》。", "阿砚正准备归还《航程札记》。", "阿砚没有兑现向乙许下的归还《航程札记》的承诺。", "阿砚兑现了向乙归还《航程札记》的承诺。"] {
        try check("not an attested state", n, [promise(n, slot, "已兑现")], accept: false)
    }
    for n in [heard, pact, broken, "阿砚开始怀疑乙。", "她没答应。", "他只在旁边听见了。"] {
        try check("empty with signal", n, [], accept: false)
    }
    try check("ordinary scene", "夜雨落在檐上。", [], accept: true)
    try check("late evidence", String(repeating: "雨落。", count: 1000) + heard, [k], accept: true)
    try check("sentence work bound", String(repeating: "。", count: 4096) + heard, [k], accept: false)
    try check("byte bound", String(repeating: "雨", count: 44000) + "。" + heard, [k], accept: false)
}

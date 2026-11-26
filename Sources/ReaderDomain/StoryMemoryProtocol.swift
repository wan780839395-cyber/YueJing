import Foundation

public struct StoryMemoryFact: Codable, Equatable, Sendable {
    public let kind: String
    public let subject: String
    public let value: String
    public let evidence: String

    public init(kind: String, subject: String, value: String, evidence: String) {
        self.kind = kind
        self.subject = subject
        self.value = value
        self.evidence = evidence
    }

    public static func validate(_ facts: [Self], narration: String) throws {
        guard facts.count <= 16 else { throw MemoryError.budget }
        // Index only the bounded manifest. Never search the narrative once per candidate.
        var proposed: [String: StoryMemoryFact] = [:]
        for f in facts {
            guard f.fitsFields else { throw MemoryError.budget }
            guard proposed.updateValue(f, forKey: f.evidence) == nil else { throw MemoryError.unattested }
        }
        let expected = try MemoryGrammar.scan(narration, requireEverySentence: false, proposed: proposed)
        if facts.isEmpty && CandidateProof.mayOmitChange(narration) { throw MemoryError.unsupported }
        guard facts.count == expected.count else { throw MemoryError.unattested }
        var unmatched = expected
        for fact in facts {
            guard fact.fitsFields else { throw MemoryError.budget }
            guard let i = unmatched.firstIndex(where: {
                $0 == fact && $0.evidence.utf8.elementsEqual(fact.evidence.utf8)
            }) else { throw MemoryError.unattested }
            unmatched.remove(at: i)
        }
    }

    fileprivate var fitsFields: Bool {
        kind.utf8.count <= 16 && subject.utf8.count <= 256 && value.utf8.count <= 64 && evidence.utf8.count <= 384
    }
}

private enum MemoryError: Error { case budget, unsupported, unattested, duplicateSlot, format }

private enum MemoryGrammar {
    // Closed lexical alternatives for unmarked prose; 【…】 explicitly delimits other proper names.
    // No wildcard clause, optional prefix or substring can become a participant or a proposition.
    static let named = "【(?![^】]*(?:不|未|没|假|若|疑|传言|据说|打算|可能|也许|准备|想要))[\\x{4E00}-\\x{9FFF}]{1,12}】"
    static let who = "(\(named)|我|阿[宁禾青远云舟明玉岚]|小[宁禾青远云舟明玉岚]|林舟|老周|[甲乙丙丁戊己庚辛壬癸])"
    static let item = "(\(named)|钥匙|铜钥匙|铜铃|信件|账本|地图|玉佩|令牌)"
    static let place = "(\(named)|南门|北门|码头|木箱中|桌上)"
    static let when = "(今日|明日|今夜|明早|[一二三四五六七八九十]月初[一二三四五六七八九十])"

    // Each match binds *all* fields. There is deliberately no generic 'text contains value' path.
    private enum Rule: CaseIterable, Sendable {
        case hold, receiveFrom, transfer, agree, fulfill, breach, know

        var pattern: String {
            switch self {
            case .hold: return who + "(?:拿着|接过了?)" + item
            case .receiveFrom: return who + "从" + who + "手里接过了?" + item
            case .transfer: return who + "把" + item + "(?:还给|交给)了?" + who
            case .agree: return who + "答应" + who + when + "在" + place + "会面"
            case .fulfill: return who + "(?:兑现|履行)了与" + who + when + "在" + place + "会面的约定"
            case .breach: return who + "(?:违背|违反)了与" + who + when + "在" + place + "会面的约定"
            case .know: return who + "知道" + item + "在" + place
            }
        }

        func fact(_ m: [String], _ evidence: String) -> StoryMemoryFact? {
            func result(_ kind: String, _ subject: String, _ value: String) -> StoryMemoryFact {
                StoryMemoryFact(kind: kind, subject: subject, value: value, evidence: evidence)
            }
            switch self {
            case .hold: return result("possession", m[1], m[0])
            case .receiveFrom: return m[0] == m[1] ? nil : result("possession", m[2], m[0])
            case .transfer: return m[0] == m[2] ? nil : result("possession", m[1], m[2])
            case .agree, .fulfill, .breach:
                guard m[0] != m[1] else { return nil }
                let slot = (m + ["会面"]).joined(separator: "｜")
                return result("promise", slot, self == .agree ? "已约定" : (self == .fulfill ? "已兑现" : "已失约"))
            case .know: return result("knowledge", [m[0], m[1], "在", m[2]].joined(separator: "｜"), "已知")
            }
        }
    }

    // Compile the fixed patterns once, not once per sentence of arbitrary narrative.
    private static let rules: [(Rule, NSRegularExpression)]? = try? Rule.allCases.map { rule in
        (rule, try NSRegularExpression(pattern: "\\A" + rule.pattern + "。\\z"))
    }

    private static func fact(for sentence: String) throws -> StoryMemoryFact? {
        guard let rules else { throw MemoryError.unsupported }
        guard sentence.utf8.count <= 384 else { return nil }
        let source = sentence as NSString
        let range = NSRange(location: 0, length: source.length)
        for (rule, regex) in rules {
            guard let match = regex.firstMatch(in: sentence, range: range) else { continue }
            let m = (1..<match.numberOfRanges).map { i -> String in
                let token = source.substring(with: match.range(at: i))
                return token.hasPrefix("【") ? String(token.dropFirst().dropLast()) : token
            }
            return rule.fact(m, sentence)
        }
        return nil
    }

    // Only an entire top-level declarative sentence counts. Newlines, colons and commas are NOT
    // sentence boundaries: a wrapped report/condition cannot manufacture a new assertion.
    static func scan(_ text: String, requireEverySentence: Bool, proposed: [String: StoryMemoryFact] = [:]) throws -> [StoryMemoryFact] {
        guard text.utf8.count <= 128 * 1024 else { throw MemoryError.budget }
        // An explicit imagined/reported scene can span several otherwise complete sentences.
        // Do not infer where that scene ends or whether a later retraction applies to it.
        let uncertain = ["据说", "听说", "传言", "传闻", "谣言", "假设", "假如", "如果", "设想", "想象", "幻想", "梦见", "梦境", "谎话", "只是梦", "并非事实", "并不属实"]
        guard !uncertain.contains(where: { text.contains($0) }) else { throw MemoryError.unsupported }
        let pairs: [Character: Character] = ["“":"”", "‘":"’", "「":"」", "『":"』", "《":"》", "〈":"〉", "（":"）", "(":")", "[":"]", "{":"}", "<":">", "\"":"\"", "'":"'", "`":"`", "【":"】", "〔":"〕", "［":"］", "«":"»"]
        let closers = Set(pairs.values)
        var stack: [Character] = []
        var facts: [StoryMemoryFact] = []
        var slots = Set<[String]>()
        var total = 0
        var start = text.startIndex
        var standaloneSpeech = false
        var prefixIsWhitespace = true
        var sentenceCount = 0
        var introduced = Set<String>()
        var usedCandidate = false
        var unresolved = false
        for index in text.indices {
            let c = text[index]
            if stack.last == c {
                stack.removeLast()
                if stack.isEmpty && standaloneSpeech {
                    standaloneSpeech = false
                    // A freestanding quoted sentence isn't evidence. Its following narration can be.
                    if "。！？!?".contains(text[text.index(before: index)]) {
                        if requireEverySentence { throw MemoryError.unsupported }
                        start = text.index(after: index)
                        prefixIsWhitespace = true
                    }
                }
                continue
            }
            if let end = pairs[c] {
                guard stack.count < 32 else { throw MemoryError.budget }
                if stack.isEmpty && "“「『\"".contains(c) {
                    standaloneSpeech = prefixIsWhitespace
                }
                prefixIsWhitespace = false
                stack.append(end); continue
            }
            if closers.contains(c) { throw MemoryError.unsupported }
            if !c.isWhitespace { prefixIsWhitespace = false }
            guard stack.isEmpty, "。！？!?".contains(c) else { continue }
            let next = text.index(after: index)
            let sentence = text[start..<next].trimmingCharacters(in: .whitespacesAndNewlines)
            sentenceCount += 1
            guard sentenceCount <= 4096 else { throw MemoryError.budget }
            var derived: StoryMemoryFact?
            if c == "。" {
                if !proposed.isEmpty, sentence.hasPrefix("来人姓"), let name = CandidateProof.introduction(sentence) {
                    guard introduced.count < 32 else { throw MemoryError.budget }
                    introduced.insert(name)
                }
                derived = try fact(for: sentence)
                if derived == nil, !proposed.isEmpty, sentence.utf8.count <= 384,
                   let f = proposed[sentence], sentence.utf8.elementsEqual(f.evidence.utf8),
                   CandidateProof.proves(f, introduced: introduced) {
                    derived = f
                    usedCandidate = true
                }
            }
            if let derived {
                if !facts.contains(derived) {
                    guard slots.insert([derived.kind, derived.subject]).inserted else { throw MemoryError.duplicateSlot }
                    total += derived.kind.utf8.count + derived.subject.utf8.count + derived.value.utf8.count + sentence.utf8.count
                    guard facts.count < 16, derived.fitsFields, total <= 4096 else { throw MemoryError.budget }
                    facts.append(derived)
                }
            } else if requireEverySentence {
                throw MemoryError.unsupported
            } else if !proposed.isEmpty && !unresolved {
                unresolved = CandidateProof.mayOmitChange(sentence)
            }
            start = next
            prefixIsWhitespace = true
        }
        guard stack.isEmpty else { throw MemoryError.unsupported }
        // Don't let one valid candidate conceal an unresolved outcome elsewhere in the turn.
        // A colon can open an unquoted report extending across multiple sentence stops.
        if usedCandidate && (unresolved || text.contains("：") || text.contains(":") ||
            !text[start...].allSatisfy(\.isWhitespace)) { throw MemoryError.unsupported }
        if requireEverySentence && (facts.isEmpty || !text[start...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            throw MemoryError.unsupported
        }
        return facts
    }
}

// A proposed slot is not a lexicon: even if the model calls “甲说乙” a name,
// it cannot occupy a person position. Check roles before assembling any sentence.
private enum CandidateProof {
    private static let identifier = #"[A-Z][a-z]{1,15}"#
    private static let person = compile("(?:" + MemoryGrammar.who + "|阿[\\x{4E00}-\\x{9FFF}])")
    private static let thing = compile("(?:" + MemoryGrammar.item + "|" + identifier + "|《[\\x{4E00}-\\x{9FFF}]{1,20}》)")
    private static let place = compile("(?:" + MemoryGrammar.place + "|" + identifier + ")")
    private static let time = compile(MemoryGrammar.when)

    // An earlier independent naming assertion licenses a bare name without a surname list.
    // No dialogue, model-proposed alias, or arbitrary sentence prefix populates this set.
    private static let naming = compile(#"来人姓([\p{Han}])，名([\p{Han}]{1,2})。"#)
    static func introduction(_ sentence: String) -> String? {
        guard sentence.utf8.count <= 40, let match = naming?.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) else { return nil }
        let s = sentence as NSString
        let name = s.substring(with: match.range(at: 1)) + s.substring(with: match.range(at: 2))
        guard !name.contains(where: { "我你他她它谁某说问称让听猜和与或但又才却未不没".contains($0) }) else { return nil }
        return name
    }

    private static func compile(_ expression: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "\\A(?:" + expression + ")\\z")
    }

    private static func matches(_ s: String, _ pattern: NSRegularExpression?) -> Bool {
        pattern?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // These signals can veto an empty proposal, never attest a nonempty one.
    private static let signals = try? NSRegularExpression(pattern:
        "知|晓|明白|清楚|发现|发觉|得悉|意识|认出|认得|揭开|看出|看懂|读|阅|看过|看完|翻看|翻过|秘密|内情|消息|瞒|听闻|听见|听到|目睹|在场|获悉|察觉|记得|明了|懂得|领悟|确信|坚信|深信|相信|信任|信赖|疑|猜|认为|觉得|以为|态度|喜欢|厌|爱慕|憎|恨|倾向|赞同|反对|担心|愿|决心|打算|想要|准备|答应|约|诺|兑现|履行|应允|应下|应承|答允|保证|誓|失信|食言|守信|说定|说好|许下")

    static func mayOmitChange(_ text: String) -> Bool {
        guard let signals else { return true }
        return signals.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func proves(_ f: StoryMemoryFact, introduced: Set<String>) -> Bool {
        let p = f.subject.components(separatedBy: "｜")
        func isPerson(_ s: String) -> Bool { matches(s, person) || introduced.contains(s) }
        guard p.count >= 2, isPerson(p[0]) else { return false }
        let a = p[0]
        func attests(_ body: String) -> Bool { f.evidence.utf8.elementsEqual((body + "。").utf8) }
        if f.kind == "knowledge" {
            if f.value == "已读", p.count == 2, matches(p[1], thing) {
                return ["读完了", "读过了", "读过", "通读了", "阅毕"].contains { attests(a + $0 + p[1]) }
            }
            guard f.value == "已知" else { return false }
            let proposition: String
            if p.count == 4, matches(p[1], thing), locationRelations.contains(p[2]), matches(p[3], place) {
                proposition = p[1] + p[2] + p[3]
            } else if p.count == 2, isLocationAssertion(p[1]) {
                proposition = p[1]
            } else { return false }
            for verb in ["知道", "得知", "获知", "获悉", "已经知道", "终于得知", "从信中得知", "读完后得知"] {
                if attests(a + verb + proposition) { return true }
            }
            return attests("只有" + a + "知道" + proposition) || attests("只有" + a + "一人知道" + proposition)
        }
        guard f.kind == "promise", p.count == 3 || p.count == 5, isPerson(p[1]),
              a.trimmingCharacters(in: brackets) != p[1].trimmingCharacters(in: brackets) else { return false }
        let b = p[1]
        let event: String
        if p.count == 5, matches(p[2], time), matches(p[3], place), p[4] == "会面" {
            event = p[2] + "在" + p[3] + p[4]
        } else if p.count == 3, isAction(p[2]) {
            event = p[2]
        } else { return false }
        switch f.value {
        case "已约定":
            return ["向", "对"].contains { prep in
                ["许诺", "承诺"].contains { attests(a + prep + b + $0 + event) }
            }
        case "已兑现", "已失约":
            let verbs = f.value == "已兑现" ? ["兑现了", "履行了"] : ["违背了", "违反了"]
            return verbs.contains { verb in
                // 向乙归还… identifies the recipient of the object, not of the promise.
                attests(a + verb + "向" + b + "许下的" + event + "的承诺") ||
                    attests(a + verb + "对" + b + "作出的" + event + "的承诺")
            }
        default: return false
        }
    }

    private static let brackets = CharacterSet(charactersIn: "【】")
    private static let locationRelations = ["在", "藏在", "放在", "位于"]
    private static func isLocationAssertion(_ text: String) -> Bool {
        locationRelations.contains { relation in
            let parts = text.components(separatedBy: relation)
            return parts.count == 2 && matches(parts[0], thing) && matches(parts[1], place)
        }
    }

    private static func isAction(_ text: String) -> Bool {
        ["归还", "交还", "送回", "带回", "保管", "交付"].contains { verb in
            text.hasPrefix(verb) && matches(String(text.dropFirst(verb.count)), thing)
        }
    }
}

public enum StoryMemoryProtocol {
    public static let marker = "\n<YJ_MEMORY_V1>\n"
    public static var instruction: String {
        """
        同一回复先写完整正文，正文后原样输出分隔符（前后各一个 LF），再输出严格 JSON 数组，不加代码围栏、说明或第二份清单。无确切变化写 []。例如：
        我从阿宁手里接过钥匙。\(marker)[{"kind":"possession","subject":"钥匙","value":"我","evidence":"我从阿宁手里接过钥匙。"}]
        evidence 必须逐字复制本回合独立、肯定的完整叙述句（含句号）；对白、否定、假设、计划、传闻、转述或不确定的一律不记。不要为凑清单改写剧情。
        自由提议证据确立的变化，以下是字段示例，不是剧情模板。使用全角｜分槽。
        人拿着物。人接过物。人把物还给人。人把物交给人。→ possession，subject=物，value=收取人或持有人。
        我答应阿宁八月初三在南门会面。→ promise，subject=我｜阿宁｜八月初三｜南门｜会面，value=已约定。后续正文如“我履行了与阿宁八月初三在南门会面的约定。”或“我违背了与阿宁八月初三在南门会面的约定。”，同槽分别写已兑现、已失约。不可从仅仅赴约、未到或打算赴约推断结果，不更换日期或地点。
        阿宁知道钥匙在木箱中。→ knowledge，subject=阿宁｜钥匙｜在｜木箱中，value=已知；每位知情人的不同命题分槽。
        新的 knowledge 可写 人｜完整命题（已知），明确读完则写 人｜文书（已读），不据阅读推断内容。promise 可写 许诺人｜受诺人｜完整事项，状态仅按明示的约定、兑现或失约。不要省略事项的谓词、对象或修饰，不混淆在场人、说话人和实际知情或许诺的人。
        人名照原文，不为验证器改写剧情、换名、加括号或凑句式。不得猜代词或从态度、意图补事实。不遗漏能提议的变化，最多16条，每槽最多一条；核不实的交由待办。
        """
    }

    public static func split(_ text: String) -> (narration: String, changes: [StoryMemoryFact]?) {
        guard let r = text.range(of: marker, options: .literal) else {
            // At EOF a reserved but unfinished header is not story text. A lone LF still is.
            let n = partialHeader(in: text)
            return (n > 1 ? String(text.dropLast(n)) : text, nil)
        }
        let narration = String(text[..<r.lowerBound])
        let tail = text[r.upperBound...]
        guard tail.utf8.count <= 12 * 1024 else { return (narration, nil) }
        return (narration, try? parseChanges(String(tail), narration: narration))
    }

    public static func visiblePrefix(_ cumulative: String) -> String {
        if let r = cumulative.range(of: marker, options: .literal) { return String(cumulative[..<r.lowerBound]) }
        return String(cumulative.dropLast(partialHeader(in: cumulative)))
    }

    private static func partialHeader(in text: String) -> Int {
        for n in (1..<marker.count).reversed() where text.hasSuffix(String(marker.prefix(n))) { return n }
        return 0
    }

    /// Offline recovery is all-or-nothing; unrecognized prose never becomes an empty proposal.
    public static func localProposal(_ narration: String) -> [StoryMemoryFact]? {
        try? MemoryGrammar.scan(narration, requireEverySentence: true)
    }

    public static func parseChanges(_ raw: String, narration: String) throws -> [StoryMemoryFact] {
        guard raw.utf8.count <= 12 * 1024 else { throw MemoryError.budget }
        var reader = ManifestReader(bytes: Array(raw.utf8))
        let facts = try reader.array()
        try StoryMemoryFact.validate(facts, narration: narration)
        return facts
    }
}

// Fixed-depth JSON reader: no ignored fields, duplicate keys (even escaped), trailing commas,
// nested containers or trailing prose. Delegate JSON string escaping/Unicode to Foundation.
private struct ManifestReader {
    let bytes: [UInt8]
    var i = 0

    mutating func whitespace() {
        while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 }
    }

    mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        guard i < bytes.count, bytes[i] == byte else { return false }
        i += 1
        return true
    }

    mutating func string() throws -> String {
        guard take(34) else { throw MemoryError.format }
        let start = i - 1
        while i < bytes.count {
            let b = bytes[i]; i += 1
            if b == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<i])) }
            if b == 92 { i += 1 }
        }
        throw MemoryError.format
    }

    mutating func array() throws -> [StoryMemoryFact] {
        guard take(91) else { throw MemoryError.format }
        var facts: [StoryMemoryFact] = []
        if !take(93) {
            repeat {
                guard facts.count < 16, take(123) else { throw MemoryError.format }
                var fields: [String: String] = [:]
                repeat {
                    let key = try string()
                    guard ["kind", "subject", "value", "evidence"].contains(key), fields[key] == nil, take(58) else { throw MemoryError.format }
                    fields[key] = try string()
                } while take(44)
                guard take(125), let k = fields["kind"], let s = fields["subject"], let v = fields["value"], let e = fields["evidence"] else { throw MemoryError.format }
                facts.append(StoryMemoryFact(kind: k, subject: s, value: v, evidence: e))
            } while take(44)
            guard take(93) else { throw MemoryError.format }
        }
        whitespace()
        guard i == bytes.count else { throw MemoryError.format }
        return facts
    }
}

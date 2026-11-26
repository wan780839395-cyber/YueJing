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
        let expected = try MemoryGrammar.scan(narration, requireEverySentence: false)
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
    static func scan(_ text: String, requireEverySentence: Bool) throws -> [StoryMemoryFact] {
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
                    }
                }
                continue
            }
            if let end = pairs[c] {
                guard stack.count < 32 else { throw MemoryError.budget }
                if stack.isEmpty && "“「『\"".contains(c) {
                    standaloneSpeech = text[start..<index].allSatisfy(\.isWhitespace)
                }
                stack.append(end); continue
            }
            if closers.contains(c) { throw MemoryError.unsupported }
            guard stack.isEmpty, "。！？!?".contains(c) else { continue }
            let next = text.index(after: index)
            let sentence = text[start..<next].trimmingCharacters(in: .whitespacesAndNewlines)
            if c == "。", let derived = try fact(for: sentence) {
                if !facts.contains(derived) {
                    guard slots.insert([derived.kind, derived.subject]).inserted else { throw MemoryError.duplicateSlot }
                    total += derived.kind.utf8.count + derived.subject.utf8.count + derived.value.utf8.count + sentence.utf8.count
                    guard facts.count < 16, derived.fitsFields, total <= 4096 else { throw MemoryError.budget }
                    facts.append(derived)
                }
            } else if requireEverySentence { throw MemoryError.unsupported }
            start = next
        }
        guard stack.isEmpty else { throw MemoryError.unsupported }
        if requireEverySentence && (facts.isEmpty || !text[start...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            throw MemoryError.unsupported
        }
        return facts
    }
}

public enum StoryMemoryProtocol {
    public static let marker = "\n<YJ_MEMORY_V1>\n"
    public static var instruction: String {
        """
        同一回复先写完整正文，正文后原样输出分隔符（前后各一个 LF），再输出严格 JSON 数组，不加代码围栏、说明或第二份清单。无确切变化写 []。例如：
        我从阿宁手里接过钥匙。\(marker)[{"kind":"possession","subject":"钥匙","value":"我","evidence":"我从阿宁手里接过钥匙。"}]
        evidence 必须逐字复制本回合独立、肯定的完整叙述句（含句号）；对白、否定、假设、计划、传闻、转述或不确定的一律不记。不要为凑清单改写剧情。
        句式与槽如下，槽分隔使用全角｜：
        人拿着物。人接过物。人把物还给人。人把物交给人。→ possession，subject=物，value=收取人或持有人。
        我答应阿宁八月初三在南门会面。→ promise，subject=我｜阿宁｜八月初三｜南门｜会面，value=已约定。后续正文如“我履行了与阿宁八月初三在南门会面的约定。”或“我违背了与阿宁八月初三在南门会面的约定。”，同槽分别写已兑现、已失约。不可从仅仅赴约、未到或打算赴约推断结果，不更换日期或地点。
        阿宁知道钥匙在木箱中。→ knowledge，subject=阿宁｜钥匙｜在｜木箱中，value=已知；每位知情人的不同命题分槽。
        用自然正文，不为记录换名或给专名加括号。人称如我、阿宁、小青、林舟、老周；物如钥匙、铜铃、信件、账本、地图；地点如南门、北门、码头、桌上；时间如今日、明日、今夜、明早或八月初三。只记可核实的受支持句式，不遗漏已识别变化，最多16条，每槽最多一条。
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

import Foundation

/// Returns an index in the original text. Never normalize the string used for a reading anchor.
public enum NarrationPhrase {
    public static func end(in text: Substring, limit: Int, continues: Bool = false) -> String.Index? {
        var i = text.startIndex, units = 0
        var terminal = false, soft: String.Index?
        while i < text.endIndex {
            let c = text[i], next = text.index(after: i)
            let width = text[i..<next].utf16.count
            if width > limit - units { break }
            if terminal && !"。！？.!?…」』”’\"）)】》".contains(c) { return i }
            units += width
            if c.isNewline { return next }
            // A period inside a number or a Latin token is not a pause for the synthesizer.
            if c == "." {
                let internalDot = i > text.startIndex && next < text.endIndex &&
                    text[text.index(before: i)].isASCII && text[text.index(before: i)].isLetterOrDigit &&
                    text[next].isASCII && text[next].isLetterOrDigit
                terminal = terminal || !internalDot
            } else if "。！？!?…".contains(c) { terminal = true }
            if (c.isWhitespace || "，,；;：:、".contains(c)) && units >= limit / 2 { soft = next }
            i = next
        }
        guard i > text.startIndex else { return nil }
        if !terminal && (i < text.endIndex || continues), let soft { return soft }
        return i
    }
}

private extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber }
}

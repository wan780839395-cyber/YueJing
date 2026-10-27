import Foundation

enum TXTChapters {
    static func split(_ document: TXTDocument) throws -> [TXTChapter] {
        guard document.utf16Count > 0 else { return [] }
        // Conservative whole-line headings: subtitles need an explicit separator.
        // Sentence punctuation and prose prefixes are not accepted as headings.
        let pattern = #"(?:第[0-9０-９一二三四五六七八九十百千万零〇两]{1,12}[章节回卷部篇](?:[ \t\u3000:：]+[^。！？!?；;，,.\r\n]{1,60})?|Chapter[ \t]+[0-9]{1,6}(?:[ \t:：]+[^。！？!?；;，,.\r\n]{1,60})?|序章|楔子|引子|尾声|后记)"#
        let expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        var headings: [(start: Int, title: String)] = [], position = 0
        var lineStart = document.text.startIndex
        while true {
            try Task.checkCancellation()
            let newline = document.text[lineStart...].firstIndex(of: "\n")
            let line = document.text[lineStart..<(newline ?? document.text.endIndex)]
            let original = String(line), title = original.trimmingCharacters(in: .whitespaces)
            let range = NSRange(location: 0, length: title.utf16.count)
            if range.length > 0, range.length <= 80, title.rangeOfCharacter(from: .newlines) == nil,
               let match = expression.firstMatch(in: title, range: range), match.range == range {
                headings.append((position, title))
            }
            position += original.utf16.count + 1
            guard let newline else { break }
            lineStart = document.text.index(after: newline)
        }
        var starts = headings
        if starts.first?.start != 0 { starts.insert((0, ""), at: 0) }
        return try starts.indices.map { index in
            let start = starts[index].start
            let end = index + 1 < starts.count ? starts[index + 1].start : document.utf16Count
            let range = try UTF16Range(location: UTF16Offset(start), length: end - start)
            let raw = try document.offsets.rawByteRange(for: range)
            return TXTChapter(id: "\(document.versionID):\(raw.location.value)", documentVersion: document.versionID,
                title: starts[index].title.isEmpty ? nil : starts[index].title, utf16Range: range, rawByteRange: raw)
        }
    }
}

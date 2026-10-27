import CoreGraphics
import CoreText
import Foundation
import TXTCore

/// Only bounded text windows and scalar metrics leave this actor; no CoreText object crosses isolation.
public actor ReadingLayoutEngine {
    private let document: TXTDocument
    private let bookID: String
    private var source: NSString?
    private let targetSliceLength = 512
    private let maximumLookaheadLength = 1024

    public init(bookID: String, document: TXTDocument) { self.bookID = bookID; self.document = document }

    public func window(around anchor: ReadingAnchor, width: Double, preferences: ReaderPreferences) throws -> ReadingWindow {
        try Task.checkCancellation()
        guard anchor.bookID == bookID, anchor.versionID == document.versionID else { throw LibraryError.invalidAnchor }
        guard width.isFinite, width >= 80, document.utf16Count > 0 else { throw LibraryError.layoutCannotAdvance }
        let target = try document.offsets.utf16Offset(for: RawByteOffset(anchor.rawByteOffset)).value
        if source == nil { source = document.text as NSString }
        guard let source else { throw LibraryError.layoutCannotAdvance }
        let settings = preferences.validated
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, CGFloat(settings.fontSize), nil)
        var start = composedStart(max(0, target - 2 * targetSliceLength), source: source)
        var slices = try slices(starting: start, source: source, font: font, width: width, settings: settings)
        if !slices.contains(where: { $0.range.location.value <= target &&
            (target < $0.range.end.value || (target == document.utf16Count && target == $0.range.end.value)) }) {
            start = composedStart(min(target, document.utf16Count - 1), source: source)
            slices = try self.slices(starting: start, source: source, font: font, width: width, settings: settings)
        }
        return ReadingWindow(id: UUID(), anchor: anchor, targetUTF16: target, preferences: settings, slices: slices,
                             hasPrevious: start > 0, hasNext: (slices.last?.range.end.value ?? 0) < document.utf16Count)
    }

    private func slices(starting start: Int, source: NSString, font: CTFont, width: Double,
                        settings: ReaderPreferences) throws -> [ReadingSlice] {
        var cursor = start, result: [ReadingSlice] = []
        for _ in 0..<7 where cursor < document.utf16Count {
            try Task.checkCancellation()
            let proposed = min(document.utf16Count, cursor + maximumLookaheadLength)
            let lookaheadEnd = composedStart(proposed, source: source)
            guard lookaheadEnd > cursor else { throw LibraryError.layoutCannotAdvance }
            let text = source.substring(with: NSRange(location: cursor, length: lookaheadEnd - cursor)) as NSString
            let attributed = NSAttributedString(string: text as String,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let typesetter = CTTypesetterCreateWithAttributedString(attributed as CFAttributedString)
            var position = 0, y = 0.0, lines: [ReadingLine] = []
            while position < text.length {
                try Task.checkCancellation()
                let count = CTTypesetterSuggestLineBreak(typesetter, position, width)
                let lineEnd = composedStart(min(lookaheadEnd, cursor + position + count), source: source) - cursor
                guard count > 0, lineEnd > position else { throw LibraryError.layoutCannotAdvance }
                let last = source.character(at: cursor + lineEnd - 1)
                let hardBreak = last == 0x0A || last == 0x0D || last == 0x2028 || last == 0x2029
                if lineEnd == text.length, lookaheadEnd < document.utf16Count, !hardBreak {
                    // The typesetter exhausted look-ahead, not a proven full layout line.
                    // Never turn that buffer edge into an artificial newline.
                    guard position > 0 else { throw LibraryError.layoutCannotAdvance }
                    break
                }
                let range = CFRange(location: position, length: lineEnd - position)
                let line = CTTypesetterCreateLine(typesetter, range)
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                let a = max(Double(ascent), Double(CTFontGetAscent(font)))
                let height = max(a + Double(descent + leading), settings.fontSize) + settings.lineSpacing
                let global = try UTF16Range(location: UTF16Offset(cursor + position), length: lineEnd - position)
                lines.append(ReadingLine(range: global,
                    rawByteStart: try document.offsets.rawByteOffset(for: global.location).value,
                    text: text.substring(with: NSRange(location: position, length: range.length)),
                    top: y, baseline: y + a, height: height))
                y += height; position = lineEnd
                if position >= targetSliceLength { break }
            }
            guard position > 0 else { throw LibraryError.layoutCannotAdvance }
            result.append(ReadingSlice(range: try UTF16Range(location: UTF16Offset(cursor), length: position),
                                       lines: lines, height: y))
            cursor += position
        }
        return result
    }

    private func composedStart(_ location: Int, source: NSString) -> Int {
        if location >= source.length { return source.length }
        return source.rangeOfComposedCharacterSequence(at: max(0, location)).location
    }
}

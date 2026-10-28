import CoreGraphics
import CoreText
import Foundation
import TXTCore

/// The product path. Only <=1024-unit fragments, seven slices and CoreText locals are held here.
/// The original ReadingLayoutEngine remains the full-document regression oracle.
public actor DerivedReadingLayoutEngine {
    private let source: DerivedBookSource
    private let targetSliceLength = 512
    private let maximumLookaheadLength = 1024
    public init(source: DerivedBookSource) { self.source = source }

    public func window(around anchor: ReadingAnchor, width: Double, preferences: ReaderPreferences,
                       measure: ProcessingMeasurementObserver? = nil) async throws -> ReadingWindow {
        let began = ContinuousClock().now
        defer { ProcessingMeasurement.finish(.layout, since: began, observe: measure) }
        let metadata = source.metadata
        guard anchor.bookID == metadata.bookID, anchor.versionID == metadata.versionID else { throw LibraryError.invalidAnchor }
        guard width.isFinite, width >= 80, metadata.utf16Count > 0 else { throw LibraryError.layoutCannotAdvance }
        try Task.checkCancellation()
        let before = await source.statistics()
        let target = try await source.utf16Offset(for: RawByteOffset(anchor.rawByteOffset)).value
        try Task.checkCancellation()
        let settings = preferences.validated
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, CGFloat(settings.fontSize), nil)
        var start = try await source.composedStart(at: max(0, target - 2 * targetSliceLength))
        var values = try await slices(starting: start, font: font, width: width, settings: settings)
        if !values.contains(where: { $0.range.location.value <= target &&
            (target < $0.range.end.value || (target == metadata.utf16Count && target == $0.range.end.value)) }) {
            start = try await source.composedStart(at: min(target, metadata.utf16Count - 1))
            values = try await slices(starting: start, font: font, width: width, settings: settings)
        }
        try Task.checkCancellation()
        let after = await source.statistics()
        try Task.checkCancellation()
        measure?(ProcessingMeasurement(phase: .rangeRead, seconds: 0,
            bytes: max(0, after.payloadBytesRead - before.payloadBytesRead), logicalBytes: after.retainedLogicalBytes,
            budgetBytes: after.maximumWorkingBytes))
        return ReadingWindow(id: UUID(), anchor: anchor, targetUTF16: target, preferences: settings, slices: values,
            hasPrevious: start > 0, hasNext: (values.last?.range.end.value ?? 0) < metadata.utf16Count)
    }
    private func slices(starting start: Int, font: CTFont, width: Double,
                        settings: ReaderPreferences) async throws -> [ReadingSlice] {
        let total = source.metadata.utf16Count
        var cursor = start, result: [ReadingSlice] = []
        for _ in 0..<7 where cursor < total {
            try Task.checkCancellation()
            let proposed = min(total, cursor + maximumLookaheadLength)
            let end = try await source.composedStart(at: proposed)
            guard end > cursor else { throw LibraryError.layoutCannotAdvance }
            let fragment = try await source.text(in: UTF16Range(location: UTF16Offset(cursor), length: end - cursor))
            try Task.checkCancellation()
            let text = fragment.text as NSString
            let attributed = NSAttributedString(string: fragment.text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let typesetter = CTTypesetterCreateWithAttributedString(attributed as CFAttributedString)
            var position = 0, y = 0.0, lines: [ReadingLine] = []
            while position < text.length {
                try Task.checkCancellation()
                let count = CTTypesetterSuggestLineBreak(typesetter, position, width)
                let lineEnd = try await source.composedStart(at: min(end, cursor + position + count)) - cursor
                guard count > 0, lineEnd > position, lineEnd <= text.length else { throw LibraryError.layoutCannotAdvance }
                let last = text.character(at: lineEnd - 1)
                let hardBreak = last == 0x0A || last == 0x0D || last == 0x2028 || last == 0x2029
                if lineEnd == text.length, end < total, !hardBreak {
                    guard position > 0 else { throw LibraryError.layoutCannotAdvance }; break
                }
                let range = CFRange(location: position, length: lineEnd - position)
                let line = CTTypesetterCreateLine(typesetter, range)
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                let a = max(Double(ascent), Double(CTFontGetAscent(font)))
                let height = max(a + Double(descent + leading), settings.fontSize) + settings.lineSpacing
                let global = try UTF16Range(location: UTF16Offset(cursor + position), length: lineEnd - position)
                let raw = try await source.rawByteOffset(for: global.location).value
                try Task.checkCancellation()
                lines.append(ReadingLine(range: global, rawByteStart: raw,
                    text: text.substring(with: NSRange(location: position, length: range.length)), top: y, baseline: y + a, height: height))
                y += height; position = lineEnd
                if position >= targetSliceLength { break }
            }
            guard position > 0 else { throw LibraryError.layoutCannotAdvance }
            result.append(ReadingSlice(range: try UTF16Range(location: UTF16Offset(cursor), length: position), lines: lines, height: y))
            cursor += position
        }
        return result
    }
}

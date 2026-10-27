import CoreGraphics
import CoreText
import Foundation

enum TXTPaginator {
    /// Called synchronously on TXTProcessor's executor. CF objects never leave this call.
    static func paginate(_ document: TXTDocument, layout: TXTPageLayout) throws -> [TXTPage] {
        guard layout.width.isFinite, layout.height.isFinite, layout.fontSize.isFinite, layout.lineSpacing.isFinite,
              layout.width > 0, layout.height > 0, layout.fontSize > 0, layout.lineSpacing >= 0 else { throw TXTError.invalidLayout }
        guard document.utf16Count > 0 else { return [] }
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, CGFloat(layout.fontSize), nil)
        var spacing = CGFloat(layout.lineSpacing)
        let paragraph = withUnsafePointer(to: &spacing) { pointer in
            let settings = [CTParagraphStyleSetting(spec: .lineSpacingAdjustment,
                valueSize: MemoryLayout<CGFloat>.size, value: UnsafeRawPointer(pointer))]
            return settings.withUnsafeBufferPointer { CTParagraphStyleCreate($0.baseAddress, $0.count) }
        }
        let attributed = NSAttributedString(string: document.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: CGFloat(layout.width), height: CGFloat(layout.height)), transform: nil)

        // Mapping permits scalar boundaries; page breaks additionally require full grapheme clusters.
        var breaks = [0], count = 0
        for character in document.text {
            count += String(character).utf16.count; breaks.append(count)
        }
        guard count == document.utf16Count else { throw TXTError.invalidCoreTextRange }
        var start = 0, pages: [TXTPage] = []
        while start < count {
            try Task.checkCancellation()
            // A zero requested length means "remaining text" to CoreText, not an empty page.
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            let sum = visible.location.addingReportingOverflow(visible.length)
            guard visible.location == start, visible.length >= 0, !sum.overflow, sum.partialValue <= count else {
                throw TXTError.invalidCoreTextRange
            }
            var low = 0, high = breaks.count
            while low < high {
                let middle = low + (high - low) / 2
                if breaks[middle] <= sum.partialValue { low = middle + 1 } else { high = middle }
            }
            guard low > 0, breaks[low - 1] > start else { throw TXTError.paginationCannotAdvance(UTF16Offset(start)) }
            let end = breaks[low - 1]
            let range = try UTF16Range(location: UTF16Offset(start), length: end - start)
            pages.append(TXTPage(documentVersion: document.versionID, utf16Range: range,
                                 rawByteRange: try document.offsets.rawByteRange(for: range)))
            start = end
        }
        return pages
    }
}

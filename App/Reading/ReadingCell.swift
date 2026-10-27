import CoreText
import ReaderDomain
import UIKit

@MainActor
final class ReadingCell: UITableViewCell {
    private let canvas = ReadingCanvas()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none; contentView.addSubview(canvas)
    }
    required init?(coder: NSCoder) { return nil }
    override func layoutSubviews() { super.layoutSubviews(); canvas.frame = contentView.bounds }
    override func prepareForReuse() { super.prepareForReuse(); canvas.clear() }
    func render(_ slice: ReadingSlice, preferences: ReaderPreferences) {
        backgroundColor = preferences.theme.background
        canvas.render(slice, preferences: preferences)
    }
}

@MainActor
private final class ReadingCanvas: UIView {
    private var slice: ReadingSlice?
    private var preferences = ReaderPreferences()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true; isAccessibilityElement = true; accessibilityTraits = .staticText
    }
    required init?(coder: NSCoder) { return nil }
    func render(_ value: ReadingSlice, preferences: ReaderPreferences) {
        slice = value; self.preferences = preferences; backgroundColor = preferences.theme.background
        accessibilityLabel = value.lines.map(\.text).joined()
        setNeedsDisplay()
    }
    func clear() { slice = nil; accessibilityLabel = nil; setNeedsDisplay() }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let slice else { return }
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, CGFloat(preferences.fontSize), nil)
        context.saveGState(); defer { context.restoreGState() }
        context.textMatrix = .identity
        context.translateBy(x: 20, y: bounds.height); context.scaleBy(x: 1, y: -1)
        // Line breaking and geometry were computed off-main. Only bounded, prebroken lines are drawn here.
        for line in slice.lines where line.top + line.height >= Double(rect.minY) && line.top <= Double(rect.maxY) {
            let text = NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): preferences.theme.foreground.cgColor,
            ])
            context.textPosition = CGPoint(x: 0, y: bounds.height - CGFloat(line.baseline))
            CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
        }
    }
}

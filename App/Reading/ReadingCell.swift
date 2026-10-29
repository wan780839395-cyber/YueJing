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
        contentView.backgroundColor = preferences.theme.background
        canvas.render(slice, preferences: preferences)
    }
    func setToolActions(_ actions: [UIAccessibilityCustomAction]) { canvas.accessibilityCustomActions = actions }

    #if DEBUG
    var canvasDrawSequence: Int { canvas.drawSequence }
    var canvasLastDrawBounds: CGRect { canvas.lastDrawBounds }
    var canvasLastDirtyRect: CGRect { canvas.lastDirtyRect }
    // Tests of the painter are separate from observations of UIKit's natural display cycle.
    func paintCanvasForTesting(_ rect: CGRect, in context: CGContext) { canvas.paint(rect, in: context) }
    #endif
}

@MainActor
private final class ReadingCanvas: UIView {
    private var slice: ReadingSlice?
    private var preferences = ReaderPreferences()
    #if DEBUG
    private(set) var drawSequence = 0
    private(set) var lastDrawBounds = CGRect.zero
    private(set) var lastDirtyRect = CGRect.zero
    #endif
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true; isAccessibilityElement = true; accessibilityTraits = .staticText
        backgroundColor = preferences.theme.background
        contentMode = .redraw
        accessibilityIdentifier = "reader.text.canvas"
    }
    required init?(coder: NSCoder) { return nil }
    func render(_ value: ReadingSlice, preferences: ReaderPreferences) {
        slice = value; self.preferences = preferences; backgroundColor = preferences.theme.background
        accessibilityLabel = value.lines.map(\.text).joined()
        setNeedsDisplay()
    }
    func clear() {
        slice = nil; accessibilityLabel = nil; accessibilityCustomActions = nil
        setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        paint(rect, in: context)
        #if DEBUG
        drawSequence += 1; lastDrawBounds = bounds; lastDirtyRect = rect
        #endif
    }
    fileprivate func paint(_ rect: CGRect, in context: CGContext) {
        // Cover the dirty region even during the empty interval between cell uses.
        context.saveGState()
        context.setBlendMode(.copy)
        context.setFillColor(preferences.theme.background.cgColor)
        context.fill(rect)
        context.restoreGState()
        guard let slice else { return }
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

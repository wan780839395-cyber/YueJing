import ReaderDomain
import UIKit
import UIKit.UIGestureRecognizerSubclass

@MainActor
final class ReaderViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    private let table = ReadingTableView(frame: .zero, style: .plain)
    private(set) var window: ReadingWindow?
    var onAnchor: (@MainActor (ReadingAnchor, UUID) -> Void)?
    var onExtend: (@MainActor (ReadingAnchor, UUID) -> Void)?
    var onWidth: (@MainActor (Double) -> Void)?
    var onSettled: (@MainActor (ReadingAnchor, UUID) -> Bool)?
    var toolIntent: (@MainActor () -> UUID)?
    var onToolsInteraction: (@MainActor (ReadingToolsInteraction) -> Void)?
    var interacting: Bool { table.isDragging || table.isDecelerating }
    private var restoring = false
    private var userInputSinceRestore = false
    private var previousWidth = 0.0
    private let toolsTap = ReadingToolsTapRecognizer()
    private var tapIntent: UUID?
    private var tapBeganDuringDeceleration = false
    private var tapBeganDuringDragging = false
    private var toolDecelerating = false

    override func viewDidLoad() {
        super.viewDidLoad()
        table.dataSource = self; table.delegate = self
        table.separatorStyle = .none; table.estimatedRowHeight = 0
        table.showsVerticalScrollIndicator = false
        table.accessibilityIdentifier = "reader.viewport"
        table.contentInset = UIEdgeInsets(top: 16, left: 0, bottom: 24, right: 0)
        table.register(ReadingCell.self, forCellReuseIdentifier: "text")
        table.onUserIntent = { [weak self] in
            self?.userInputSinceRestore = true; self?.onToolsInteraction?(.scrollingBegan)
        }
        toolsTap.addTarget(self, action: #selector(bodyTapped))
        toolsTap.delegate = self
        toolsTap.cancelsTouchesInView = false
        toolsTap.delaysTouchesBegan = false
        toolsTap.require(toFail: table.panGestureRecognizer)
        toolsTap.onTouchBegan = { [weak self] in
            guard let self else { return }
            // Latch the beginning, not merely the eventual tap-up state after UIKit stops inertia.
            tapBeganDuringDeceleration = tapBeganDuringDeceleration || table.isDecelerating || toolDecelerating
            tapBeganDuringDragging = tapBeganDuringDragging || table.isDragging
        }
        table.addGestureRecognizer(toolsTap)
        view.addSubview(table)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        table.frame = view.bounds
        let width = Double(view.bounds.width)
        if width >= 120, abs(width - previousWidth) > 0.5 { previousWidth = width; onWidth?(width) }
    }

    func setTheme(_ theme: ReaderTheme) {
        loadViewIfNeeded()
        view.backgroundColor = theme.background; table.backgroundColor = theme.background
    }

    func detachCallbacks() {
        onAnchor = nil; onExtend = nil; onWidth = nil; onSettled = nil
        toolIntent = nil; onToolsInteraction = nil
    }

    func apply(_ value: ReadingWindow, userNavigation: Bool, restoring point: ReaderViewportRestoration? = nil) {
        loadViewIfNeeded()
        restoring = true; userInputSinceRestore = false; window = value
        table.reloadData(); table.layoutIfNeeded()
        let row = value.slices.firstIndex { $0.range.location.value <= value.targetUTF16 && value.targetUTF16 < $0.range.end.value }
            ?? max(0, value.slices.count - 1)
        if value.slices.indices.contains(row) {
            let slice = value.slices[row]
            let line = slice.lines.first { $0.range.location.value <= value.targetUTF16 && value.targetUTF16 < $0.range.end.value }
                ?? slice.lines.last
            let rect = table.rectForRow(at: IndexPath(row: row, section: 0))
            let desired = rect.minY + CGFloat((line?.top ?? 0) + value.anchor.lineFraction * (line?.height ?? 0)) - table.adjustedContentInset.top
            let minimum = -table.adjustedContentInset.top
            let maximum = max(minimum, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
            table.setContentOffset(CGPoint(x: 0, y: min(maximum, max(minimum, desired))), animated: false)
        }
        if !userNavigation, let point, point.windowID == value.id,
           point.anchor.bookID == value.anchor.bookID, point.anchor.versionID == value.anchor.versionID {
            let minimum = -table.adjustedContentInset.top
            let maximum = max(minimum, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
            let desired = point.visibleTop - table.adjustedContentInset.top
            table.setContentOffset(CGPoint(x: 0, y: min(maximum, max(minimum, desired))), animated: false)
            userInputSinceRestore = point.userInputSinceRestore
        }
        restoring = false
        if userNavigation, let visible = actualVisibleAnchor() {
            userInputSinceRestore = true; onAnchor?(visible, value.id)
        }
    }

    /// Preserve the semantic target across repeated reflows until a real scrolling action changes it.
    func restorableAnchor() -> ReadingAnchor? {
        userInputSinceRestore ? actualVisibleAnchor() : window?.anchor
    }

    func restorationPoint() -> ReaderViewportRestoration? {
        guard let window, let anchor = restorableAnchor() else { return nil }
        return ReaderViewportRestoration(windowID: window.id, anchor: anchor,
            visibleTop: table.contentOffset.y + table.adjustedContentInset.top,
            userInputSinceRestore: userInputSinceRestore)
    }

    private func actualVisibleAnchor() -> ReadingAnchor? {
        guard let window else { return nil }
        let top = table.contentOffset.y + table.adjustedContentInset.top
        for path in (table.indexPathsForVisibleRows ?? []).sorted() where window.slices.indices.contains(path.row) {
            let slice = window.slices[path.row]
            let relative = max(0, Double(top - table.rectForRow(at: path).minY))
            guard let line = slice.lines.first(where: { $0.top + $0.height > relative }) else { continue }
            return ReadingAnchor(bookID: window.anchor.bookID, versionID: window.anchor.versionID,
                rawByteOffset: line.rawByteStart, lineFraction: min(1, max(0, (relative - line.top) / line.height)))
        }
        return nil
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { window?.slices.count ?? 0 }
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let window, window.slices.indices.contains(indexPath.row) else { return 0 }
        return CGFloat(window.slices[indexPath.row].height)
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "text", for: indexPath) as? ReadingCell,
              let window, window.slices.indices.contains(indexPath.row) else { return UITableViewCell() }
        cell.render(window.slices[indexPath.row], preferences: window.preferences)
        cell.setToolActions([
            UIAccessibilityCustomAction(name: "显示阅读工具", target: self, selector: #selector(showToolsAccessibility)),
            UIAccessibilityCustomAction(name: "退出阅读", target: self, selector: #selector(exitAccessibility))
        ])
        return cell
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === toolsTap, !UIAccessibility.isVoiceOverRunning else { return false }
        let point = touch.location(in: table)
        guard ReadingToolsGesturePolicy.central(x: Double(point.x), y: Double(point.y),
            width: Double(table.bounds.width), height: Double(table.bounds.height),
            originX: Double(table.bounds.minX), originY: Double(table.bounds.minY)) else { return false }
        tapIntent = toolIntent?()
        tapBeganDuringDeceleration = table.isDecelerating || toolDecelerating
        tapBeganDuringDragging = table.isDragging
        return true
    }
    @objc private func bodyTapped() {
        guard toolsTap.state == .ended, let intent = tapIntent else { return }
        let decision = ReadingToolsGesturePolicy.tap(beganDuringDeceleration: tapBeganDuringDeceleration,
            dragging: tapBeganDuringDragging || table.isDragging, decelerating: table.isDecelerating,
            voiceOver: UIAccessibility.isVoiceOverRunning)
        // UIKit retains its stop-on-touch behavior. This bridge never adjusts the content offset.
        onToolsInteraction?(.tap(intent, decision))
    }
    @objc private func showToolsAccessibility() -> Bool {
        guard let onToolsInteraction else { return false }
        onToolsInteraction(.showAccessibility); return true
    }
    @objc private func exitAccessibility() -> Bool {
        guard let onToolsInteraction else { return false }
        onToolsInteraction(.exitAccessibility); return true
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userInputSinceRestore = true; toolDecelerating = false
        onToolsInteraction?(.scrollingBegan)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !restoring, userInputSinceRestore, let window, let visible = actualVisibleAnchor() else { return }
        onAnchor?(visible, window.id)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        toolDecelerating = decelerate
        if !decelerate { endedScrolling() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { toolDecelerating = false; endedScrolling() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { if userInputSinceRestore { endedScrolling() } }

    private func endedScrolling() {
        guard !restoring, let window, let visible = actualVisibleAnchor(), let paths = table.indexPathsForVisibleRows else { return }
        if onSettled?(visible, window.id) == true { return }
        let rows = paths.map(\.row)
        if (window.hasPrevious && (rows.min() ?? 9) == 0) || (window.hasNext && (rows.max() ?? 0) >= window.slices.count - 2) {
            onExtend?(visible, window.id)
        }
    }
}

@MainActor
private final class ReadingToolsTapRecognizer: UITapGestureRecognizer {
    var onTouchBegan: (@MainActor () -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchBegan?(); super.touchesBegan(touches, with: event)
    }
}

@MainActor
private final class ReadingTableView: UITableView {
    var onUserIntent: (@MainActor () -> Void)?
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        onUserIntent?()
        return super.accessibilityScroll(direction)
    }
}

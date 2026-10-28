import ReaderDomain
import UIKit

@MainActor
final class ReaderViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let table = ReadingTableView(frame: .zero, style: .plain)
    private(set) var window: ReadingWindow?
    var onAnchor: (@MainActor (ReadingAnchor, UUID) -> Void)?
    var onExtend: (@MainActor (ReadingAnchor, UUID) -> Void)?
    var onWidth: (@MainActor (Double) -> Void)?
    var onSettled: (@MainActor (ReadingAnchor, UUID) -> Bool)?
    var onRemoved: (@MainActor () -> Void)?
    var interacting: Bool { table.isDragging || table.isDecelerating }
    private var restoring = false
    private var userInputSinceRestore = false
    private var previousWidth = 0.0

    override func viewDidLoad() {
        super.viewDidLoad()
        table.dataSource = self; table.delegate = self
        table.separatorStyle = .none; table.estimatedRowHeight = 0
        table.showsVerticalScrollIndicator = false
        table.contentInset = UIEdgeInsets(top: 16, left: 0, bottom: 24, right: 0)
        table.register(ReadingCell.self, forCellReuseIdentifier: "text")
        table.onUserIntent = { [weak self] in self?.userInputSinceRestore = true }
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

    func apply(_ value: ReadingWindow, userNavigation: Bool) {
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
        restoring = false
        if userNavigation, let visible = actualVisibleAnchor() {
            userInputSinceRestore = true; onAnchor?(visible, value.id)
        }
    }

    /// Preserve the semantic target across repeated reflows until a real scrolling action changes it.
    func restorableAnchor() -> ReadingAnchor? {
        userInputSinceRestore ? actualVisibleAnchor() : window?.anchor
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
        return cell
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { userInputSinceRestore = true }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !restoring, userInputSinceRestore, let window, let visible = actualVisibleAnchor() else { return }
        onAnchor?(visible, window.id)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { endedScrolling() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { endedScrolling() }
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
private final class ReadingTableView: UITableView {
    var onUserIntent: (@MainActor () -> Void)?
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        onUserIntent?()
        return super.accessibilityScroll(direction)
    }
}

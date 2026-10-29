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

    #if DEBUG
    func hitProbeSnapshot(exitRect: CGRect, actualWindow: UIWindow) -> [String: Any] {
        guard ReaderHitProbeStore.enabled, viewIfLoaded?.window === actualWindow else {
            return ["status": "unknown", "reason": "reader-window-mismatch"]
        }
        @MainActor func chain(_ hit: UIView?) -> [[String: Any]] {
            var result: [[String: Any]] = [], next = hit
            for _ in 0..<6 {
                guard let view = next else { break }
                let identifier = ["reader.viewport", "ui.fixture.reader.hitprobe"].contains(view.accessibilityIdentifier ?? "")
                    ? view.accessibilityIdentifier! : "other-or-none"
                result.append(["class": String(describing: type(of: view)), "identifier": identifier,
                    "frameInParent": ReaderHitProbeStore.rect(view.frame), "bounds": ReaderHitProbeStore.rect(view.bounds),
                    "hidden": view.isHidden, "alpha": Double(view.alpha), "interaction": view.isUserInteractionEnabled,
                    "clipsToBounds": view.clipsToBounds, "inTable": view === table || view.isDescendant(of: table),
                    "inReaderController": view === self.view || view.isDescendant(of: self.view)])
                next = view.superview
            }
            return result
        }
        let topPoint = CGPoint(x: exitRect.midX, y: exitRect.midY)
        var result: [String: Any] = ["status": "observed", "predictionOnlyNoTouchSent": true,
            "tracking": table.isTracking, "dragging": table.isDragging, "decelerating": table.isDecelerating,
            "offset": [Double(table.contentOffset.x), Double(table.contentOffset.y)],
            "panState": table.panGestureRecognizer.state.rawValue, "tapState": toolsTap.state.rawValue,
            "panEnabled": table.panGestureRecognizer.isEnabled, "tapEnabled": toolsTap.isEnabled,
            "latchedDecelerating": tapBeganDuringDeceleration, "latchedDragging": tapBeganDuringDragging,
            "toolDecelerating": toolDecelerating, "restoring": restoring,
            "topPointInWindow": [Double(topPoint.x), Double(topPoint.y)],
            "topHitChain": chain(actualWindow.hitTest(topPoint, with: nil))]
        // Public AX lookup only; unsupported/truncated/ambiguous containers remain unknown.
        let scope = parent?.viewIfLoaded ?? viewIfLoaded!
        var queue: [(AnyObject, Int)] = [(scope, 0)], seen: Set<ObjectIdentifier> = []
        var matches: [CGRect] = [], cursor = 0, truncated = false
        while cursor < queue.count && seen.count < 128 {
            let (object, depth) = queue[cursor]; cursor += 1
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if let view = object as? UIView {
                if view.accessibilityIdentifier == "ui.fixture.reader.hitprobe" { continue }
                if view.accessibilityIdentifier == "reader.tools.settings" { matches.append(view.accessibilityFrame) }
                guard depth < 8 else { truncated = true; continue }
                let count = view.accessibilityElementCount()
                if count > 0 && count <= 32 {
                    for index in 0..<count {
                        if let child = view.accessibilityElement(at: index) { queue.append((child as AnyObject, depth + 1)) }
                    }
                } else if count > 32 && count != NSNotFound { truncated = true }
                if view.subviews.count > 32 { truncated = true }
                queue += view.subviews.prefix(32).map { ($0 as AnyObject, depth + 1) }
            } else if let element = object as? UIAccessibilityElement {
                if element.accessibilityIdentifier == "reader.tools.settings" { matches.append(element.accessibilityFrame) }
            }
        }
        truncated = truncated || cursor < queue.count
        result["bottomAXSearch"] = ["visited": seen.count, "truncated": truncated, "matches": matches.count,
            "scopeClass": String(describing: type(of: scope))]
        if !truncated, matches.count == 1, ReaderHitProbeStore.valid(matches[0]) {
            let screenRect = matches[0], rect = actualWindow.convert(screenRect, from: nil as UIWindow?)
            if actualWindow.bounds.contains(rect) {
                let point = CGPoint(x: rect.midX, y: rect.midY)
                result["bottomStatus"] = "observed-public-AX-frame"
                result["bottomScreenRect"] = ReaderHitProbeStore.rect(screenRect)
                result["bottomWindowRect"] = ReaderHitProbeStore.rect(rect)
                result["bottomHitChain"] = chain(actualWindow.hitTest(point, with: nil))
            } else { result["bottomStatus"] = "unknown-outside-window" }
        } else { result["bottomStatus"] = "unknown-unavailable-or-ambiguous" }
        return result
    }
    #endif
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

#if DEBUG
@MainActor
final class ReaderHitProbeStore {
    static var enabled: Bool {
        ReadingUITestFixture.isRequested && ProcessInfo.processInfo.environment["YUEJING_READER_HIT_PROBE"] == "1"
            && UUID(uuidString: ProcessInfo.processInfo.environment["YUEJING_UI_TEST_SESSION"] ?? "") != nil
    }
    weak var exitMarker: UIView?
    private weak var model: ReaderViewModel?
    private var routeID: UUID?
    private var tools: ReadingToolsPresentation?
    private var contextUpdatedAt = 0.0
    private var sequence = 0
    private var getterCalls = 0
    private var geometryRevision = 0
    private var lastRect: CGRect?
    private var lastWindow: ObjectIdentifier?
    private var lastMarker: ObjectIdentifier?
    private var sampling = false
    func update(model: ReaderViewModel, routeID: UUID, tools: ReadingToolsPresentation) {
        self.model = model; self.routeID = routeID; self.tools = tools
        contextUpdatedAt = ProcessInfo.processInfo.systemUptime
    }
    static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }
    static func rect(_ rect: CGRect) -> [Any] {
        [rect.minX, rect.minY, rect.width, rect.height].map { $0.isFinite ? Double($0) as Any : "nonfinite" as Any }
    }
    func value(endpoint: UIView) -> String {
        guard Self.enabled, Thread.isMainThread else { return "{\"status\":\"unknown-disabled-or-thread\"}" }
        getterCalls += 1
        let started = ProcessInfo.processInfo.systemUptime
        var data: [String: Any] = ["schema": 1, "status": "unknown", "appPID": ProcessInfo.processInfo.processIdentifier,
            "bundle": Bundle.main.bundleIdentifier ?? "unknown", "nonce": ProcessInfo.processInfo.environment["YUEJING_UI_TEST_SESSION"] ?? "unknown",
            "startedUptime": started, "maximumGetterSamples": 32, "implicitAXReadsPossible": true,
            "getterCallNumber": getterCalls, "observationMayPerturbComposition": true, "contextUpdatedUptime": contextUpdatedAt]
        @MainActor func encoded(_ reason: String? = nil) -> String {
            if let reason { data["reason"] = reason }
            data["sequence"] = sequence; data["endedUptime"] = ProcessInfo.processInfo.systemUptime
            data["getterCallsAtEnd"] = getterCalls
            guard let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
                  let string = String(data: bytes, encoding: .utf8) else { return "{\"status\":\"unknown-encoding\"}" }
            return string
        }
        guard !sampling else { return encoded("reentrant-AX-read") }
        guard sequence < 32 else { return encoded("getter-sample-limit") }
        sequence += 1; sampling = true
        defer { sampling = false }
        guard let model, let tools, let routeID, let controller = model.viewport.controller,
              let actualWindow = controller.viewIfLoaded?.window, endpoint.window === actualWindow,
              let marker = exitMarker, marker.window === actualWindow else { return encoded("missing-or-mismatched-native-window") }
        data["routeID"] = routeID.uuidString; data["windowToken"] = String(describing: ObjectIdentifier(actualWindow))
        data["sceneToken"] = actualWindow.windowScene?.session.persistentIdentifier ?? "unknown"
        data["windowBounds"] = Self.rect(actualWindow.bounds); data["windowFrame"] = Self.rect(actualWindow.frame)
        data["keyWindow"] = actualWindow.isKeyWindow; data["sceneWindowCount"] = actualWindow.windowScene?.windows.count ?? 0
        data["intent"] = tools.intent.uuidString; data["canInteract"] = tools.canInteract; data["visible"] = tools.visible
        data["valid"] = tools.valid; data["suspended"] = tools.suspended; data["hasPanel"] = tools.panel != nil
        data["exitRequested"] = tools.exitRequest != nil; data["loading"] = model.loading; data["exitSaveFailed"] = model.exitSaveFailed
        switch tools.mode { case .hidden: data["mode"] = "hidden"; case .compact: data["mode"] = "compact"; case .panel: data["mode"] = "panel" }
        guard controller.toolIntent?() == tools.intent else { return encoded("stale-tools-context") }
        data["modelReadingWindowID"] = model.window?.id.uuidString ?? "none"
        data["controllerReadingWindowID"] = controller.window?.id.uuidString ?? "none"
        guard let readingID = model.window?.id, controller.window?.id == readingID else { return encoded("reading-window-version-mismatch") }
        data["readingWindowID"] = readingID.uuidString
        let rect = marker.convert(marker.bounds, to: actualWindow)
        guard Self.valid(rect), actualWindow.bounds.contains(rect) else { return encoded("invalid-marker-geometry") }
        let windowToken = ObjectIdentifier(actualWindow), markerToken = ObjectIdentifier(marker)
        if lastRect != rect || lastWindow != windowToken || lastMarker != markerToken {
            geometryRevision += 1; lastRect = rect; lastWindow = windowToken; lastMarker = markerToken
        }
        let screenRect = actualWindow.convert(rect, to: nil as UIWindow?)
        data["geometryRevision"] = geometryRevision; data["geometrySource"] = "native-button-background-marker-to-actual-window"
        data["markerToken"] = String(describing: markerToken)
        data["exitWindowRect"] = Self.rect(rect); data["exitScreenRect"] = Self.rect(screenRect)
        data["hit"] = controller.hitProbeSnapshot(exitRect: rect, actualWindow: actualWindow)
        data["status"] = "observed"
        return encoded()
    }
}
#endif

import ReaderDomain
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Transient input only: no book, position, session, or asynchronous work.
struct ReaderToolTouchContext {
    struct Touch {
        let id = UUID()
        let generation: UUID
        let intent: UUID
        var beganDuringDeceleration: Bool
        var beganDuringDragging: Bool
    }
    private(set) var active = true
    private(set) var generation = UUID()
    private(set) var toolDecelerating = false
    private(set) var touch: Touch?

    mutating func setActive(_ value: Bool, decelerating: Bool) {
        guard active != value else { return }
        active = value; generation = UUID(); touch = nil
        toolDecelerating = value && decelerating
    }
    mutating func begin(intent: UUID?, dragging: Bool, decelerating: Bool) -> UUID? {
        guard active, let intent else { return nil }
        let value = Touch(generation: generation, intent: intent,
            beganDuringDeceleration: decelerating || toolDecelerating, beganDuringDragging: dragging)
        touch = value
        return value.id
    }
    mutating func latch(_ id: UUID?, dragging: Bool, decelerating: Bool) {
        guard active, var value = touch, value.id == id, value.generation == generation else { return }
        value.beganDuringDeceleration = value.beganDuringDeceleration || decelerating || toolDecelerating
        value.beganDuringDragging = value.beganDuringDragging || dragging
        touch = value
    }
    mutating func cancel(_ id: UUID?) {
        guard touch?.id == id else { return }
        touch = nil
    }
    mutating func draggingBegan() { if active { toolDecelerating = false } }
    mutating func draggingEnded(decelerating: Bool) { if active { toolDecelerating = decelerating } }
    mutating func decelerationEnded() { toolDecelerating = false }
    mutating func finish(_ id: UUID?, dragging: Bool, decelerating: Bool,
                         voiceOver: Bool) -> (UUID, ReadingToolsTapDecision)? {
        guard active, let value = touch, value.id == id, value.generation == generation else { return nil }
        touch = nil
        let decision = ReadingToolsGesturePolicy.tap(beganDuringDeceleration: value.beganDuringDeceleration,
            dragging: value.beganDuringDragging || dragging, decelerating: decelerating, voiceOver: voiceOver)
        // Consume only the shadow; never stop UIKit or discard the touch-begin latch.
        toolDecelerating = decelerating
        return (value.intent, decision)
    }
}

// BEGIN READER DIAGNOSTICS recorder
/// Local, passive device diagnosis. No identifiers, text, coordinates, clocks or persistence.
/// Each VC owns its own facts; an old VC can never write into its replacement's recorder.
@MainActor
final class ReaderInteractionDiagnostics {
    enum Scene: String { case unknown = "?", active = "A", inactive = "I", background = "B" }
    enum Event: String {
        case attach = "att", replace = "new", detach = "det", revoke = "rev"
        case scene = "sc", handle = "h", phase = "vc", phaseDone = "vc+", tools = "tools"
        case receive = "rx", admitted = "ok", rejected = "no", began = "beg", latched = "lat"
        case touchEnd = "up", touchEndReturned = "up+", cancelled = "can", reset = "rst", resetReturned = "rst+"
        case target = "end", finish = "fin", callback = "cb", callbackReturned = "cb+"
        case parent = "par", parentDone = "par+", scroll = "scr"
    }
    enum Admission: String { case none = "-", accepted = "ok", other = "other", voiceOver = "VO", outside = "edge", noToken = "nil" }
    enum Decision: String { case none = "-", rejected = "nil", ignore = "ign", momentum = "stop", toggle = "tog" }
    enum Parent: String { case none = "-", noWindow = "win", loading = "load", saveFailed = "save", decision = "dec", cannotInteract = "off", staleIntent = "old", action = "act" }
    enum Mode: String { case unknown = "?", hidden = "h", compact = "c", panel = "p" }
    enum Recognizer: String { case unknown = "?", possible = "p", began = "b", changed = "c", ended = "e", cancelled = "x", failed = "f" }
    struct Tap {
        var admission: Admission = .none
        var began = false, touchEnded = false, target = false, cancelled = false, reset = false
        var token = false, generation = false, dragging = false, decelerating = false
        var latchedDrag = false, latchedDecel = false, callback = false, parentReceived = false
        var decision: Decision = .none
        var parent: Parent = .none
        var before: Mode = .unknown, after: Mode = .unknown
        var intentMatches = false, canInteract = false, finalVisible = false
        var resetState: Recognizer = .unknown
    }
    private weak var label: UILabel?
    private var events: [Event] = [] // Append-only, at most 64. Never a time series or ring of user data.
    private var taps = [Tap(), Tap()]
    private var attempts = 0
    private var tapOpen = false
    private var chainReset = false
    private var recordingAdmission = false
    private var inCallback = false
    private var sawScroll = false
    private var interrupted = false
    private var replacedOwner = false
    private var scene: Scene = .unknown
    private var owner = false, handleActive = true, enabled = true, contextActive = true
    private var dragging = false, decelerating = false, shadow = false
    private var mode: Mode = .unknown
    private var valid = false, suspended = false, canInteract = false, visible = false
    private var hasWindow = false, loading = false, saveFailed = false
    private var recognizer: Recognizer = .unknown

    private func append(_ event: Event) {
        if events.count < 64 { events.append(event) }
        paint()
    }
    private func changeTap(_ change: (inout Tap) -> Void) {
        guard tapOpen, (1...2).contains(attempts) else { return }
        change(&taps[attempts - 1])
    }
    private func toolMode(_ tools: ReadingToolsPresentation) -> Mode {
        switch tools.mode { case .hidden: .hidden; case .compact: .compact; case .panel: .panel }
    }
    func install(_ label: UILabel) { self.label = label; paint() }
    func observeScene(_ next: Scene) {
        // One reset per active -> nonactive transition, not again for inactive -> background.
        if scene == .active, next != .active {
            events.removeAll(keepingCapacity: true); taps = [Tap(), Tap()]; attempts = 0
            tapOpen = false; chainReset = false; recordingAdmission = false
            inCallback = false; sawScroll = false; interrupted = true
        }
        if next != scene { scene = next; append(.scene) }
    }
    func attach(scene: Scene, replacing: Bool) {
        owner = true; replacedOwner = replacing; observeScene(scene); append(replacing ? .replace : .attach)
    }
    func observeOwner(_ current: Bool) { owner = current; paint() }
    func detached() { owner = false; append(.detach) }
    func revoked() { append(.revoke) }
    func handlePhase(_ active: Bool, current: Bool) {
        owner = current
        if handleActive != active { handleActive = active; append(.handle) } else { paint() }
    }
    func sample(enabled: Bool, context: ReaderToolTouchContext, dragging: Bool, decelerating: Bool,
                state: UIGestureRecognizer.State) {
        self.enabled = enabled; contextActive = context.active; self.dragging = dragging
        self.decelerating = decelerating; shadow = context.toolDecelerating
        switch state {
        case .possible: recognizer = .possible
        case .began: recognizer = .began
        case .changed: recognizer = .changed
        case .ended: recognizer = .ended
        case .cancelled: recognizer = .cancelled
        case .failed: recognizer = .failed
        @unknown default: recognizer = .unknown
        }
        paint()
    }
    func phase(_ done: Bool) { append(done ? .phaseDone : .phase) }
    func sceneTools(_ tools: ReadingToolsPresentation) { observeTools(tools); append(.tools) }
    func observeTools(_ tools: ReadingToolsPresentation) {
        mode = toolMode(tools); valid = tools.valid; suspended = tools.suspended
        canInteract = tools.canInteract; visible = tools.visible && tools.panel == nil; paint()
    }
    func beginAdmission() {
        // Budget closes on a THIRD admission after reset, not on the second admission/end.
        // Keep reset-before-target ordering observable too; no timer guesses completion.
        if attempts == 2, chainReset { tapOpen = false }
        recordingAdmission = (!tapOpen || chainReset) && attempts < 2
        guard recordingAdmission else { return }
        attempts += 1; tapOpen = true; chainReset = false; append(.receive)
    }
    func admission(isTools: Bool, voiceOver: Bool, central: Bool, hasToken: Bool) {
        guard recordingAdmission else { return }
        let reason: Admission = !isTools ? .other : voiceOver ? .voiceOver : !central ? .outside : !hasToken ? .noToken : .accepted
        changeTap { $0.admission = reason }
        append(reason == .accepted ? .admitted : .rejected)
        // A rejected admission never gets a recognizer chain; do not wait forever for reset.
        if reason != .accepted { tapOpen = false }
        recordingAdmission = false
    }
    func token(_ id: UUID?, context: ReaderToolTouchContext, dragging: Bool, decelerating: Bool) {
        // Only equality facts survive this call. Never retain the UUID or context.
        changeTap {
            $0.token = id != nil && context.touch?.id == id
            $0.generation = context.touch?.generation == context.generation
            $0.dragging = dragging; $0.decelerating = decelerating
            $0.latchedDrag = context.touch?.beganDuringDragging ?? false
            $0.latchedDecel = context.touch?.beganDuringDeceleration ?? false
        }
    }
    func recognizerEvent(_ event: Event) {
        guard tapOpen || attempts == 0 else { return }
        changeTap {
            if event == .began { $0.began = true }
            if event == .touchEnd { $0.touchEnded = true }
            if event == .target { $0.target = true }
            if event == .cancelled { $0.cancelled = true }
            if event == .reset { $0.reset = true; $0.resetState = recognizer }
        }
        append(event)
        // Keep a late target/parent tail after reset observable until the next admission.
        if event == .resetReturned { chainReset = true }
    }
    func willFinish() { changeTap { $0.decision = .rejected }; recognizerEvent(.finish) }
    func callback(_ decision: ReadingToolsTapDecision, present: Bool) {
        changeTap {
            switch decision { case .ignore: $0.decision = .ignore; case .stopMomentum: $0.decision = .momentum; case .toggle: $0.decision = .toggle }
            $0.callback = present
        }
        inCallback = tapOpen; recognizerEvent(.callback)
    }
    func callbackReturned() { recognizerEvent(.callbackReturned); inCallback = false }
    func parentTap(window: Bool, loading: Bool, saveFailed: Bool, toggle: Bool,
                   intentMatches: Bool, tools: ReadingToolsPresentation) {
        // A revoked/old VC cannot attribute its late callback to the current VC's recorder.
        guard inCallback else { return }
        hasWindow = window; self.loading = loading; self.saveFailed = saveFailed
        changeTap {
            $0.parentReceived = true; $0.before = toolMode(tools)
            $0.intentMatches = intentMatches; $0.canInteract = tools.canInteract
            $0.parent = !window ? .noWindow : loading ? .loading : saveFailed ? .saveFailed : !toggle ? .decision
                : !tools.canInteract ? .cannotInteract : !intentMatches ? .staleIntent : .action
        }
        append(.parent)
    }
    func parentFinished(_ tools: ReadingToolsPresentation) {
        guard inCallback else { return }
        changeTap { $0.after = toolMode(tools); $0.finalVisible = tools.visible && tools.panel == nil }
        observeTools(tools); append(.parentDone)
    }
    func screenFacts(window: Bool, loading: Bool, saveFailed: Bool, tools: ReadingToolsPresentation) {
        hasWindow = window; self.loading = loading; self.saveFailed = saveFailed; observeTools(tools)
    }
    func scrolling() { if !sawScroll { sawScroll = true; append(.scroll) } }
    private func bit(_ value: Bool) -> String { value ? "1" : "0" }
    private func tapLine(_ index: Int) -> String {
        let t = taps[index]
        return "T\(index + 1) \(t.admission.rawValue) B\(bit(t.began))U\(bit(t.touchEnded))E\(bit(t.target)) X\(bit(t.cancelled))R\(bit(t.reset))\(t.resetState.rawValue) \(t.decision.rawValue)"
    }
    private func resultLine(_ index: Int) -> String {
        let t = taps[index]
        return " m\(bit(t.token))\(bit(t.generation)) d\(bit(t.dragging))\(bit(t.decelerating)) l\(bit(t.latchedDrag))\(bit(t.latchedDecel)) cb\(bit(t.callback))p\(bit(t.parentReceived)):\(t.parent.rawValue) \(t.before.rawValue)>\(t.after.rawValue) i\(bit(t.intentMatches))c\(bit(t.canInteract))v\(bit(t.finalVisible))"
    }
    private func paint() {
        label?.text = [
            "DIAG R\(bit(interrupted)) S:\(scene.rawValue) O\(bit(owner))N\(bit(replacedOwner)) H\(bit(handleActive)) E\(bit(enabled))C\(bit(contextActive))",
            "rx\(attempts)/2 end\(taps.filter { $0.target }.count)/2 g:\(recognizer.rawValue) d\(bit(dragging))\(bit(decelerating)) sh\(bit(shadow))",
            tapLine(0), resultLine(0), tapLine(1), resultLine(1),
            "P:\(mode.rawValue) v\(bit(visible)) c\(bit(canInteract)) V\(bit(valid))s\(bit(suspended)) w\(bit(hasWindow))l\(bit(loading))f\(bit(saveFailed))",
            "#\(events.count)/64 " + events.suffix(9).map(\.rawValue).joined(separator: ">")
        ].joined(separator: "\n")
    }
}
// END READER DIAGNOSTICS recorder

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
    private(set) var interactionContext = ReaderToolTouchContext()
    private var appliedTheme: ReaderTheme?
    private weak var sceneHandle: ReaderViewportHandle?
    private var sceneRouteID: UUID?
    private weak var boundScene: UIWindowScene?
    private(set) var sceneBindingID: UUID?
    var onSceneInteraction: (@MainActor (ReaderSceneEvent) -> Void)?
    private var sceneObservation: SceneObservation?

    // One selector target per binding. Even a late delivery retains its OLD immutable IDs.
    @MainActor
    private final class SceneObservation: NSObject {
        private weak var owner: ReaderViewController?
        private weak var scene: UIWindowScene?
        private let routeID: UUID
        private let binding: UUID
        init(owner: ReaderViewController, scene: UIWindowScene, routeID: UUID, binding: UUID) {
            self.owner = owner; self.scene = scene; self.routeID = routeID; self.binding = binding
            super.init()
            for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(receive(_:)), name: name, object: scene)
            }
        }
        @objc private func receive(_ notification: Notification) {
            owner?.sceneLifecycleChanged(notification, routeID: routeID, binding: binding)
        }
        func stop() {
            if let scene {
                for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
                    NotificationCenter.default.removeObserver(self, name: name, object: scene)
                }
            }
            owner = nil
        }
    }

    func prepareSceneAuthority(handle: ReaderViewportHandle, routeID: UUID) {
        guard sceneHandle !== handle || sceneRouteID != routeID else { return }
        revokeSceneBinding()
        sceneHandle = handle; sceneRouteID = routeID
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        bindCurrentScene()
    }
    // Only called after UIKit has attached the view, never from Representable make/update.
    private func bindCurrentScene() {
        guard let sceneHandle, let sceneRouteID,
              sceneHandle.ownsSceneController(self, routeID: sceneRouteID) else { return }
        guard let scene = viewIfLoaded?.window?.windowScene else { revokeSceneBinding(); return }
        if boundScene !== scene || sceneBindingID == nil {
            revokeSceneBinding()
            let binding = UUID()
            guard sceneHandle.beginSceneBinding(self, routeID: sceneRouteID, binding: binding) else { return }
            boundScene = scene; sceneBindingID = binding
            sceneObservation = SceneObservation(owner: self, scene: scene, routeID: sceneRouteID, binding: binding)
        }
        forwardScenePhase(scene.activationState == .foregroundActive, scene: scene)
    }
    func matchesSceneBinding(_ binding: UUID, scene: UIWindowScene? = nil) -> Bool {
        guard sceneBindingID == binding, let boundScene,
              viewIfLoaded?.window?.windowScene === boundScene else { return false }
        return scene == nil || scene === boundScene
    }
    // UIKit scene notifications are delivered on the main thread. Selector observation avoids
    // sending a non-Sendable Notification/scene through a Sendable closure or an extra Task.
    private func sceneLifecycleChanged(_ notification: Notification, routeID: UUID, binding: UUID) {
        guard routeID == sceneRouteID, binding == sceneBindingID,
              let scene = notification.object as? UIWindowScene, scene === boundScene else { return }
        switch notification.name {
        case UIScene.didActivateNotification:
            guard scene.activationState == .foregroundActive else { return }
            forwardScenePhase(true, scene: scene)
        case UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification:
            // willDeactivate is the immediate pause boundary; activationState may still be active.
            forwardScenePhase(false, scene: scene)
        default: return
        }
    }
    private func forwardScenePhase(_ active: Bool, scene: UIWindowScene) {
        guard let sceneRouteID, let binding = sceneBindingID else { return }
        sceneHandle?.acceptScenePhase(active, from: self, scene: scene, routeID: sceneRouteID, binding: binding)
    }
    private func revokeSceneBinding() {
        sceneObservation?.stop(); sceneObservation = nil
        if let binding = sceneBindingID { sceneHandle?.endSceneBinding(self, binding: binding) }
        boundScene = nil; sceneBindingID = nil
    }
    // BEGIN READER DIAGNOSTICS storage
    let interactionDiagnostics = ReaderInteractionDiagnostics()
    weak var diagnosticHandle: ReaderViewportHandle?
    private let interactionDiagnosticLabel = UILabel()
    private func sampleInteractionDiagnostics() {
        interactionDiagnostics.sample(enabled: toolsTap.isEnabled, context: interactionContext,
            dragging: table.isDragging, decelerating: table.isDecelerating, state: toolsTap.state)
    }
    // END READER DIAGNOSTICS storage

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
        toolsTap.onTouchBegan = { [weak self] id in self?.latchToolTouch(id) }
        toolsTap.onTouchCancelled = { [weak self] id in self?.cancelToolTouch(id) }
        table.addGestureRecognizer(toolsTap)
        view.addSubview(table)
        // BEGIN READER DIAGNOSTICS install
        toolsTap.onDiagnosticEvent = { [weak self] event, id in
            guard let self else { return }
            self.sampleInteractionDiagnostics()
            if event == .began {
                self.interactionDiagnostics.token(id, context: self.interactionContext,
                    dragging: self.table.isDragging, decelerating: self.table.isDecelerating)
            }
            self.interactionDiagnostics.recognizerEvent(event)
        }
        interactionDiagnosticLabel.isUserInteractionEnabled = false
        interactionDiagnosticLabel.isAccessibilityElement = false
        interactionDiagnosticLabel.accessibilityElementsHidden = true
        interactionDiagnosticLabel.numberOfLines = 8
        interactionDiagnosticLabel.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .monospacedSystemFont(ofSize: 10, weight: .regular), maximumPointSize: 13)
        interactionDiagnosticLabel.adjustsFontForContentSizeCategory = true
        interactionDiagnosticLabel.textColor = .white
        interactionDiagnosticLabel.backgroundColor = UIColor(white: 0, alpha: 1)
        view.addSubview(interactionDiagnosticLabel)
        interactionDiagnostics.install(interactionDiagnosticLabel)
        sampleInteractionDiagnostics()
        // END READER DIAGNOSTICS install
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        table.frame = view.bounds
        // BEGIN READER DIAGNOSTICS label frame
        // Last-event facts only; no per-frame/per-pixel recorder or polling.
        // Passive paint only: table frame, content insets and hit-testing stay unchanged.
        let diagnosticTop = view.safeAreaInsets.top + 52
        interactionDiagnosticLabel.frame = CGRect(x: 8, y: diagnosticTop,
            width: max(0, view.bounds.width - 16), height: min(144, max(0, view.bounds.height - diagnosticTop - 8)))
        // END READER DIAGNOSTICS label frame
        let width = Double(view.bounds.width)
        if width >= 120, abs(width - previousWidth) > 0.5 { previousWidth = width; onWidth?(width) }
    }

    @discardableResult
    func setTheme(_ theme: ReaderTheme) -> Bool {
        guard appliedTheme != theme else { return false }
        loadViewIfNeeded()
        let background = theme.background
        view.backgroundColor = background; table.backgroundColor = background
        appliedTheme = theme
        return true
    }

    func detachCallbacks() {
        revokeSceneBinding()
        sceneHandle = nil; sceneRouteID = nil; onSceneInteraction = nil
        // BEGIN READER DIAGNOSTICS revoke
        interactionDiagnostics.revoked()
        defer { sampleInteractionDiagnostics() }
        // END READER DIAGNOSTICS revoke
        setInteractionActive(false)
        onAnchor = nil; onExtend = nil; onWidth = nil; onSettled = nil
        toolIntent = nil; onToolsInteraction = nil
    }

    func setInteractionActive(_ active: Bool) {
        // BEGIN READER DIAGNOSTICS phase
        interactionDiagnostics.phase(false)
        defer { sampleInteractionDiagnostics(); interactionDiagnostics.phase(true) }
        // END READER DIAGNOSTICS phase
        guard interactionContext.active != active else { return }
        interactionContext.setActive(active, decelerating: table.isDecelerating)
        // Cancels/reset the existing recognizer; no replacement or overlapping gesture.
        toolsTap.isEnabled = active
    }

    func beginToolTouch() -> UUID? {
        interactionContext.begin(intent: toolIntent?(), dragging: table.isDragging, decelerating: table.isDecelerating)
    }
    func latchToolTouch(_ id: UUID?) {
        interactionContext.latch(id, dragging: table.isDragging, decelerating: table.isDecelerating)
        // BEGIN READER DIAGNOSTICS latch
        interactionDiagnostics.token(id, context: interactionContext, dragging: table.isDragging, decelerating: table.isDecelerating)
        interactionDiagnostics.recognizerEvent(.latched)
        // END READER DIAGNOSTICS latch
    }
    func cancelToolTouch(_ id: UUID?) { interactionContext.cancel(id) }
    @discardableResult
    func endToolTouch(_ id: UUID?) -> ReadingToolsTapDecision? {
        // BEGIN READER DIAGNOSTICS finish
        sampleInteractionDiagnostics()
        interactionDiagnostics.token(id, context: interactionContext, dragging: table.isDragging, decelerating: table.isDecelerating)
        interactionDiagnostics.willFinish()
        defer { sampleInteractionDiagnostics() }
        // END READER DIAGNOSTICS finish
        guard let (intent, decision) = interactionContext.finish(id, dragging: table.isDragging,
            decelerating: table.isDecelerating, voiceOver: UIAccessibility.isVoiceOverRunning) else { return nil }
        // UIKit retains its stop-on-touch behavior. This bridge never adjusts the content offset.
        // BEGIN READER DIAGNOSTICS callback
        diagnosticHandle?.beginDiagnosticDelivery(self)
        interactionDiagnostics.callback(decision, present: onToolsInteraction != nil)
        defer {
            interactionDiagnostics.callbackReturned()
            diagnosticHandle?.endDiagnosticDelivery(self)
        }
        // END READER DIAGNOSTICS callback
        onToolsInteraction?(.tap(intent, decision))
        return decision
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
        // BEGIN READER DIAGNOSTICS admission start
        interactionDiagnostics.beginAdmission()
        var diagnosticCentral = false
        defer {
            sampleInteractionDiagnostics()
            interactionDiagnostics.admission(isTools: gestureRecognizer === toolsTap,
                voiceOver: UIAccessibility.isVoiceOverRunning, central: diagnosticCentral, hasToken: toolsTap.touchID != nil)
        }
        // END READER DIAGNOSTICS admission start
        guard gestureRecognizer === toolsTap, !UIAccessibility.isVoiceOverRunning else { return false }
        let point = touch.location(in: table)
        guard ReadingToolsGesturePolicy.central(x: Double(point.x), y: Double(point.y),
            width: Double(table.bounds.width), height: Double(table.bounds.height),
            originX: Double(table.bounds.minX), originY: Double(table.bounds.minY)) else { return false }
        // BEGIN READER DIAGNOSTICS central passed
        diagnosticCentral = true
        // END READER DIAGNOSTICS central passed
        toolsTap.touchID = beginToolTouch()
        // BEGIN READER DIAGNOSTICS admission token
        interactionDiagnostics.token(toolsTap.touchID, context: interactionContext,
            dragging: table.isDragging, decelerating: table.isDecelerating)
        // END READER DIAGNOSTICS admission token
        return toolsTap.touchID != nil
    }
    @objc private func bodyTapped() {
        guard toolsTap.state == .ended else { return }
        // BEGIN READER DIAGNOSTICS target
        sampleInteractionDiagnostics(); interactionDiagnostics.recognizerEvent(.target)
        // END READER DIAGNOSTICS target
        endToolTouch(toolsTap.touchID)
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
        userInputSinceRestore = true; interactionContext.draggingBegan()
        // BEGIN READER DIAGNOSTICS drag facts
        sampleInteractionDiagnostics()
        // END READER DIAGNOSTICS drag facts
        onToolsInteraction?(.scrollingBegan)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !restoring, userInputSinceRestore, let window, let visible = actualVisibleAnchor() else { return }
        onAnchor?(visible, window.id)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        interactionContext.draggingEnded(decelerating: decelerate)
        // BEGIN READER DIAGNOSTICS drag end facts
        sampleInteractionDiagnostics()
        // END READER DIAGNOSTICS drag end facts
        if !decelerate { endedScrolling() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { interactionContext.decelerationEnded(); endedScrolling() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { if userInputSinceRestore { endedScrolling() } }

    private func endedScrolling() {
        // BEGIN READER DIAGNOSTICS settled facts
        sampleInteractionDiagnostics()
        // END READER DIAGNOSTICS settled facts
        guard !restoring, let window, let visible = actualVisibleAnchor(), let paths = table.indexPathsForVisibleRows else { return }
        if onSettled?(visible, window.id) == true { return }
        let rows = paths.map(\.row)
        if (window.hasPrevious && (rows.min() ?? 9) == 0) || (window.hasNext && (rows.max() ?? 0) >= window.slices.count - 2) {
            onExtend?(visible, window.id)
        }
    }

    #if DEBUG
    func hitProbeSnapshot(exitRect: CGRect, actualWindow: UIWindow, deadline: TimeInterval? = nil) -> [String: Any] {
        guard ReaderHitProbeStore.enabled, viewIfLoaded?.window === actualWindow else {
            return ["status": "unknown", "reason": "reader-window-mismatch"]
        }
        @MainActor func expired() -> Bool {
            deadline.map { ProcessInfo.processInfo.systemUptime >= $0 } ?? false
        }
        guard !expired() else { return ["status": "unknown", "reason": "entry-sample-deadline"] }
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
            "latchedDecelerating": interactionContext.touch?.beganDuringDeceleration ?? false,
            "latchedDragging": interactionContext.touch?.beganDuringDragging ?? false,
            "toolDecelerating": interactionContext.toolDecelerating, "restoring": restoring,
            "topPointInWindow": [Double(topPoint.x), Double(topPoint.y)],
            "topHitChain": chain(actualWindow.hitTest(topPoint, with: nil))]
        // Public AX lookup only; unsupported/truncated/ambiguous containers remain unknown.
        let scope = parent?.viewIfLoaded ?? viewIfLoaded!
        var queue: [(AnyObject, Int)] = [(scope, 0)], seen: Set<ObjectIdentifier> = []
        var matches: [CGRect] = [], cursor = 0, truncated = false
        while cursor < queue.count && seen.count < 128 && !expired() {
            let (object, depth) = queue[cursor]; cursor += 1
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if let view = object as? UIView {
                if ["ui.fixture.reader.hitprobe", "ui.fixture.reader.entryprobe"].contains(view.accessibilityIdentifier ?? "") { continue }
                if view.accessibilityIdentifier == "reader.tools.settings" { matches.append(view.accessibilityFrame) }
                guard depth < 8 else { truncated = true; continue }
                let count = view.accessibilityElementCount()
                if count > 0 && count <= 32 {
                    for index in 0..<count {
                        if expired() { truncated = true; break }
                        if let child = view.accessibilityElement(at: index) { queue.append((child as AnyObject, depth + 1)) }
                    }
                } else if count > 32 && count != NSNotFound { truncated = true }
                if view.subviews.count > 32 { truncated = true }
                queue += view.subviews.prefix(32).map { ($0 as AnyObject, depth + 1) }
            } else if let element = object as? UIAccessibilityElement {
                if element.accessibilityIdentifier == "reader.tools.settings" { matches.append(element.accessibilityFrame) }
            }
        }
        truncated = truncated || cursor < queue.count || expired()
        result["bottomAXSearch"] = ["visited": seen.count, "truncated": truncated, "matches": matches.count,
            "scopeClass": String(describing: type(of: scope))]
        if !truncated, matches.count == 1, ReaderHitProbeStore.valid(matches[0]) {
            let screenRect = matches[0], rect = actualWindow.convert(screenRect, from: nil as UIWindow?)
            if actualWindow.bounds.contains(rect), !expired() {
                let point = CGPoint(x: rect.midX, y: rect.midY)
                result["bottomStatus"] = "observed-public-AX-frame"
                result["bottomScreenRect"] = ReaderHitProbeStore.rect(screenRect)
                result["bottomWindowRect"] = ReaderHitProbeStore.rect(rect)
                result["bottomHitChain"] = chain(actualWindow.hitTest(point, with: nil))
            } else { result["bottomStatus"] = "unknown-outside-window" }
        } else { result["bottomStatus"] = "unknown-unavailable-or-ambiguous" }
        if expired() { result["status"] = "unknown"; result["reason"] = "entry-sample-deadline" }
        return result
    }
    #endif
}

@MainActor
private final class ReadingToolsTapRecognizer: UITapGestureRecognizer {
    var touchID: UUID?
    var onTouchBegan: (@MainActor (UUID?) -> Void)?
    var onTouchCancelled: (@MainActor (UUID?) -> Void)?
    // BEGIN READER DIAGNOSTICS recognizer observer
    var onDiagnosticEvent: (@MainActor (ReaderInteractionDiagnostics.Event, UUID?) -> Void)?
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onDiagnosticEvent?(.touchEnd, touchID)
        super.touchesEnded(touches, with: event)
        onDiagnosticEvent?(.touchEndReturned, touchID)
    }
    // END READER DIAGNOSTICS recognizer observer
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // BEGIN READER DIAGNOSTICS raw begin
        onDiagnosticEvent?(.began, touchID)
        // END READER DIAGNOSTICS raw begin
        onTouchBegan?(touchID); super.touchesBegan(touches, with: event)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        // BEGIN READER DIAGNOSTICS raw cancel
        onDiagnosticEvent?(.cancelled, touchID)
        // END READER DIAGNOSTICS raw cancel
        onTouchCancelled?(touchID); touchID = nil
        super.touchesCancelled(touches, with: event)
    }
    override func reset() {
        // BEGIN READER DIAGNOSTICS raw reset
        onDiagnosticEvent?(.reset, touchID)
        // END READER DIAGNOSTICS raw reset
        onTouchCancelled?(touchID); touchID = nil
        super.reset()
        // BEGIN READER DIAGNOSTICS raw reset returned
        onDiagnosticEvent?(.resetReturned, touchID)
        // END READER DIAGNOSTICS raw reset returned
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
    static var enabled: Bool { legacyEnabled || ReaderEntryProbe.enabled }
    static var legacyEnabled: Bool {
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
        sample(endpoint: endpoint, entrySequence: nil)
    }
    func entryValue(endpoint: UIView, requestSequence: Int) -> String {
        guard ReaderEntryProbe.enabled, (1...2).contains(requestSequence) else {
            return "{\"status\":\"unknown-entry-disabled-or-sequence\"}"
        }
        return sample(endpoint: endpoint, entrySequence: requestSequence)
    }
    private func sample(endpoint: UIView, entrySequence: Int?) -> String {
        guard Self.enabled, Thread.isMainThread else { return "{\"status\":\"unknown-disabled-or-thread\"}" }
        if entrySequence == nil { getterCalls += 1 }
        let started = ProcessInfo.processInfo.systemUptime
        var data: [String: Any] = ["schema": 1, "status": "unknown", "appPID": ProcessInfo.processInfo.processIdentifier,
            "bundle": Bundle.main.bundleIdentifier ?? "unknown", "nonce": ProcessInfo.processInfo.environment["YUEJING_UI_TEST_SESSION"] ?? "unknown",
            "startedUptime": started, "implicitAXReadsPossible": true,
            "observationMayPerturbComposition": true, "contextUpdatedUptime": contextUpdatedAt]
        let deadline = entrySequence == nil ? nil : Optional(started + 0.25)
        if entrySequence == nil {
            data["maximumGetterSamples"] = 32; data["getterCallNumber"] = getterCalls
        } else {
            data["sampleKind"] = "explicit-entry-request"; data["maximumRequestedSamples"] = 2
            data["cooperativeBudgetSeconds"] = 0.25; data["automaticAXReadsTriggerSampling"] = false
        }
        @MainActor func encoded(_ reason: String? = nil) -> String {
            if let reason { data["reason"] = reason }
            data["sequence"] = entrySequence ?? sequence; data["endedUptime"] = ProcessInfo.processInfo.systemUptime
            if entrySequence == nil { data["getterCallsAtEnd"] = getterCalls }
            guard let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
                  let string = String(data: bytes, encoding: .utf8) else { return "{\"status\":\"unknown-encoding\"}" }
            return string
        }
        guard !sampling else { return encoded("reentrant-AX-read") }
        if entrySequence == nil {
            guard sequence < 32 else { return encoded("getter-sample-limit") }
            sequence += 1
        }
        sampling = true
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
        let hit = controller.hitProbeSnapshot(exitRect: rect, actualWindow: actualWindow, deadline: deadline)
        data["hit"] = hit
        if let deadline, ProcessInfo.processInfo.systemUptime >= deadline {
            return encoded("entry-sample-deadline")
        }
        data["status"] = "observed"
        return encoded()
    }
}
#endif

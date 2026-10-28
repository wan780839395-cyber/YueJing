import Foundation

public enum ReadingToolPanel: Equatable, Sendable { case directory, settings }
public enum ReadingToolsMode: Equatable, Sendable {
    case hidden, compact, panel(ReadingToolPanel, UUID)
}

/// UI intent only. Never owns a reader, document, position or preferences snapshot.
public struct ReadingToolsPresentation: Equatable, Sendable {
    public private(set) var mode: ReadingToolsMode = .compact
    public private(set) var intent = UUID()
    public private(set) var suspended = false
    public private(set) var valid = true
    public private(set) var exitRequest: UUID?
    public init() {}
    public var canInteract: Bool { valid && !suspended && exitRequest == nil }
    public var visible: Bool { mode != .hidden }
    public var panel: ReadingToolPanel? { if case .panel(let panel, _) = mode { panel } else { nil } }
    public var panelID: UUID? { if case .panel(_, let id) = mode { id } else { nil } }
    public func owns(_ panel: ReadingToolPanel, id: UUID) -> Bool {
        canInteract && mode == .panel(panel, id)
    }
    public mutating func show() {
        guard canInteract, mode == .hidden else { return }
        set(.compact)
    }
    public mutating func bodyTapped(expected: UUID) {
        guard canInteract, intent == expected else { return }
        set(mode == .hidden ? .compact : mode == .compact ? .hidden : .compact)
    }
    public mutating func open(_ panel: ReadingToolPanel) {
        guard canInteract, self.panel != panel else { return }
        set(.panel(panel, UUID()))
    }
    @discardableResult public mutating func closePanel(id: UUID) -> Bool {
        guard canInteract, panelID == id else { return false }
        set(.compact); return true
    }
    @discardableResult public mutating func chapterSelected(id: UUID) -> Bool {
        guard owns(.directory, id: id) else { return false }
        set(.hidden); return true
    }
    public mutating func scrollingBegan() {
        guard canInteract, mode != .hidden else { return }
        set(.hidden)
    }
    public mutating func forceCompact() {
        guard valid, !suspended, exitRequest == nil else { return }
        set(.compact)
    }
    public mutating func suspend() { suspended = true; set(.hidden) }
    public mutating func resume() { guard valid else { return }; suspended = false }
    public mutating func beginExit() -> UUID? {
        guard canInteract else { return nil }
        let id = UUID(); exitRequest = id; set(.compact); return id
    }
    @discardableResult public mutating func finishExit(_ id: UUID, succeeded: Bool) -> Bool {
        guard valid, exitRequest == id else { return false }
        exitRequest = nil
        if succeeded { invalidate() } else { set(suspended ? .hidden : .compact) }
        return true
    }
    public mutating func invalidate() {
        valid = false; exitRequest = nil; set(.hidden)
    }
    private mutating func set(_ value: ReadingToolsMode) { mode = value; intent = UUID() }
}

public enum ReadingToolsTapDecision: Equatable, Sendable { case ignore, stopMomentum, toggle }
public enum ReadingToolsInteraction: Sendable {
    case tap(UUID, ReadingToolsTapDecision), scrollingBegan, showAccessibility, exitAccessibility
}
public enum ReadingToolsGesturePolicy {
    public static func central(x: Double, y: Double, width: Double, height: Double,
                               originX: Double = 0, originY: Double = 0) -> Bool {
        guard [x, y, width, height, originX, originY].allSatisfy(\.isFinite), width > 0, height > 0 else { return false }
        let localX = x - originX, localY = y - originY
        return localX >= width * 0.2 && localX <= width * 0.8 && localY >= height * 0.2 && localY <= height * 0.8
    }
    public static func tap(beganDuringDeceleration: Bool, dragging: Bool,
                           decelerating: Bool, voiceOver: Bool) -> ReadingToolsTapDecision {
        if voiceOver || dragging { return .ignore }
        if beganDuringDeceleration || decelerating { return .stopMomentum }
        return .toggle
    }
}

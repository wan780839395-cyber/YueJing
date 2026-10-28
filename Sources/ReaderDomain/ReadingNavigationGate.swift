import Foundation

/// Used by the actual viewport callback path. A pending jump owns its target until
/// that jump's window is applied; old-window scroll callbacks cannot replace it.
public struct ReadingNavigationGate: Sendable {
    public private(set) var navigation: UUID?
    private var expectedWindow: UUID?
    private var displayedWindow: UUID?
    public init() {}
    public mutating func begin() { navigation = UUID(); expectedWindow = nil }
    public mutating func expect(window: UUID, navigation token: UUID) {
        if navigation == token { expectedWindow = window }
    }
    public func accepts(window: UUID) -> Bool { navigation == nil && displayedWindow == window }
    public func isDisplayed(window: UUID) -> Bool { displayedWindow == window }
    @discardableResult
    public mutating func applied(window: UUID) -> Bool {
        if navigation != nil {
            guard expectedWindow == window else { displayedWindow = window; return false }
            navigation = nil; expectedWindow = nil; displayedWindow = window; return true
        }
        displayedWindow = window; return false
    }
    public mutating func reset() { navigation = nil; expectedWindow = nil; displayedWindow = nil }
}

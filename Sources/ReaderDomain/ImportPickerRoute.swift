import Foundation

/// One picker attempt. Contains no URL or document data; a result needs confirmed dismissal.
public struct ImportPickerRoute: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable { case selected, empty, cancelled }
    public let id: UUID
    public private(set) var dismissed = false
    public private(set) var outcome: Outcome?
    public private(set) var delivered = false

    public init(id: UUID) { self.id = id }

    @discardableResult
    public mutating func receive(_ value: Outcome, for attempt: UUID) -> Bool {
        guard attempt == id, outcome == nil, !delivered else { return false }
        outcome = value
        return true
    }

    @discardableResult
    public mutating func confirmDismissal(for attempt: UUID) -> Bool {
        guard attempt == id, !dismissed else { return false }
        dismissed = true
        return true
    }

    public mutating func takeReady(for attempt: UUID) -> Outcome? {
        guard attempt == id, dismissed, !delivered, let outcome else { return nil }
        delivered = true
        return outcome
    }
}

import Foundation

/// Single-destination value state for static planned-feature pages on the shelf stack.
struct LibraryPlannedNavigation: Equatable, Sendable {
    struct Route: Identifiable, Equatable, Sendable {
        let id: UUID
        let feature: LibraryPlannedFeature
    }

    private(set) var activeRoute: Route?
    private(set) var displayedFeature: LibraryPlannedFeature = .comics

    var isActive: Bool { activeRoute != nil }

    /// Accepts only an idle -> active transition while allowed; competing requests are ignored.
    @discardableResult
    mutating func begin(_ feature: LibraryPlannedFeature, allowed: Bool = true) -> Bool {
        guard allowed, activeRoute == nil else { return false }
        activeRoute = Route(id: UUID(), feature: feature)
        displayedFeature = feature
        return true
    }

    /// Clears the active route only when `id` matches the current route identity.
    @discardableResult
    mutating func end(id: UUID) -> Bool {
        guard activeRoute?.id == id else { return false }
        activeRoute = nil
        return true
    }
}

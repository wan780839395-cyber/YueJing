import Foundation

/// A pending navigation is not a return point. Only its renderer-confirmed
/// completion may publish the first origin or consume it after a return.
struct SearchReturn<Position> {
    enum Effect { case remember(Position), returned }

    private(set) var origin: Position?
    private var pending: (navigation: UUID, effect: Effect)?
    var pendingNavigation: UUID? { pending?.navigation }

    init() {}

    mutating func stage(_ effect: Effect?, navigation: UUID) {
        pending = effect.map { (navigation, $0) }
    }

    mutating func cancelPending() { pending = nil }

    mutating func confirm(navigation: UUID) {
        guard let pending, pending.navigation == navigation else { return }
        self.pending = nil
        switch pending.effect {
        case .remember(let position): if origin == nil { origin = position }
        case .returned: origin = nil
        }
    }
}

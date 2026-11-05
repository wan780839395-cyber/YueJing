import CoreGraphics

/// Reading direction, independent of the publication's resource URL or navigation epoch.
enum EPUBPageDirection: Int, Sendable {
    case previous = -1
    case next = 1
}

/// All measurements are UIScrollView points, not DOM offsets or persisted page numbers.
struct EPUBPageGeometry {
    let offset: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    var minimum: CGFloat { -topInset }
    var maximum: CGFloat { max(minimum, contentHeight - viewportHeight + bottomInset) }
    var valid: Bool {
        [offset, contentHeight, viewportHeight, topInset, bottomInset].allSatisfy(\.isFinite) &&
            viewportHeight > 0 && contentHeight >= 0
    }

    /// nil means the current chapter boundary, including chapters shorter than one screen.
    func destination(_ direction: EPUBPageDirection) -> CGFloat? {
        guard valid else { return nil }
        let current = min(max(offset, minimum), maximum)
        let overlap = min(64, viewportHeight * 0.15)
        let step = max(1, viewportHeight - overlap)
        let next = min(max(current + CGFloat(direction.rawValue) * step, minimum), maximum)
        return abs(next - current) > 1 ? next : nil
    }

    /// A deliberate second outward drag at a boundary, never a fling arriving from mid-chapter.
    func boundaryTurn(from startOffset: CGFloat, translation: CGPoint) -> EPUBPageDirection? {
        guard valid, startOffset.isFinite, translation.x.isFinite, translation.y.isFinite,
              abs(translation.y) >= 64, abs(translation.y) > abs(translation.x) * 1.5 else { return nil }
        if startOffset >= maximum - 2, offset >= maximum - 2, translation.y < 0 { return .next }
        if startOffset <= minimum + 2, offset <= minimum + 2, translation.y > 0 { return .previous }
        return nil
    }

    static func edgeDirection(at point: CGPoint, size: CGSize) -> EPUBPageDirection? {
        guard point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 112,
              point.y >= 56, point.y <= size.height - 56,
              point.x >= 0, point.x <= size.width else { return nil }
        if point.x <= size.width * 0.2 { return .previous }
        if point.x >= size.width * 0.8 { return .next }
        return nil
    }
}

import CoreGraphics
import Foundation
import ReaderDomain

/// One detached UI window's visual top; never a persisted position or a document cache.
struct ReaderViewportRestoration {
    let windowID: UUID
    let anchor: ReadingAnchor
    let visibleTop: CGFloat
    let userInputSinceRestore: Bool
}

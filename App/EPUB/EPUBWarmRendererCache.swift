import Combine
import Foundation
import ReaderDomain
import UIKit

/// Idle renderers for one route owner (at most one foreground route).
/// Content files are pinned by each parked controller, independently of the closed session.
@MainActor
final class EPUBWarmRendererCache {
    struct Limits {
        var totalRenderers = 3 // Includes the single foreground route; a ceiling, not a residency promise.
        var idleEstimatedBytes = 96 * 1024 * 1024
    }
    private struct Key: Hashable {
        let bookID: String
        let service: ObjectIdentifier
    }
    private struct Entry {
        let service: LibraryService // Keeps ObjectIdentifier from being recycled while the entry exists.
        let controller: EPUBWebViewController
        let estimatedBytes: Int
        let used: UInt64
    }
    private var entries: [Key: Entry] = [:]
    private var active: (key: Key, generation: UUID)?
    private weak var checkedOut: EPUBWebViewController?
    private var serial: UInt64 = 0
    private let limits: Limits
    private var observations: [AnyCancellable] = []
    private(set) var hits = 0
    private(set) var misses = 0
    private(set) var evictions = 0
    var idleCount: Int { entries.count }

    init(limits: Limits = Limits()) {
        self.limits = limits
        // Background is not invalidation. iOS can still terminate WebContent; the controller observes that.
        observations.append(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.discard() } })
    }

    func take(bookID: String, service: LibraryService) -> (controller: EPUBWebViewController?, generation: UUID) {
        let key = Key(bookID: bookID, service: ObjectIdentifier(service)), generation = UUID()
        active = (key, generation) // A late close from a superseded route may not repopulate the pool.
        let previous = entries.removeValue(forKey: key)
        checkedOut = nil
        trim(reservingForeground: true)
        guard let previous, previous.controller.hasParkedDocument else {
            previous?.controller.detachCallbacks()
            misses += 1
            return (nil, generation)
        }
        checkedOut = previous.controller
        hits += 1
        return (previous.controller, generation)
    }

    @discardableResult
    func retain(_ controller: EPUBWebViewController, bookID: String, service: LibraryService, generation: UUID) -> Bool {
        let key = Key(bookID: bookID, service: ObjectIdentifier(service))
        guard active?.key == key, active?.generation == generation, controller.hasParkedDocument else {
            controller.detachCallbacks()
            return false
        }
        active = nil; checkedOut = nil
        entries.removeValue(forKey: key)?.controller.detachCallbacks()
        let cost = controller.parkedEstimatedBytes
        guard cost <= limits.idleEstimatedBytes, limits.totalRenderers > 0 else {
            controller.detachCallbacks()
            return false
        }
        serial &+= 1
        entries[key] = Entry(service: service, controller: controller, estimatedBytes: cost, used: serial)
        trim(reservingForeground: false)
        return entries[key]?.controller === controller
    }

    func finish(_ generation: UUID) {
        guard active?.generation == generation else { return }
        active = nil; checkedOut = nil
    }

    /// Switching to TXT revokes the foreground reservation, not valid idle EPUB content.
    func leaveEPUB() {
        active = nil
        checkedOut?.discardParkedState()
        checkedOut = nil
        trim(reservingForeground: false)
    }

    private func trim(reservingForeground: Bool) {
        let countLimit = max(0, limits.totalRenderers - (reservingForeground ? 1 : 0))
        var bytes = entries.values.reduce(0) { $0 + $1.estimatedBytes }
        for (key, entry) in entries.sorted(by: { $0.value.used < $1.value.used }) {
            guard entries.count > countLimit || bytes > limits.idleEstimatedBytes || !entry.controller.hasParkedDocument else { continue }
            entries.removeValue(forKey: key)
            bytes -= entry.estimatedBytes
            entry.controller.detachCallbacks()
            evictions += 1
        }
    }

    func discard() {
        active = nil
        for entry in entries.values { entry.controller.detachCallbacks() }
        entries.removeAll()
        checkedOut?.discardParkedState()
        checkedOut = nil
    }
}

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
    private var diagnosticRoute: (key: Key, generation: UUID)? // Observation only; never grants cache admission.
    private weak var checkedOut: EPUBWebViewController?
    private var serial: UInt64 = 0
    private let limits: Limits
    private var observations: [AnyCancellable] = []
    private(set) var hits = 0
    private(set) var misses = 0
    private(set) var evictions = 0
    var idleCount: Int { entries.count }

    private final class DiagnosticRecord {
        let bookID: String
        weak var service: LibraryService?
        let sample: EPUBReopenDiagnostics.Sample
        init(bookID: String, service: LibraryService, sample: EPUBReopenDiagnostics.Sample) {
            self.bookID = bookID; self.service = service; self.sample = sample
        }
    }
    private var diagnosticRecords: [DiagnosticRecord] = []
    var diagnosticCount: Int { diagnosticRecords.count }

    private func record(_ sample: EPUBReopenDiagnostics.Sample, key: Key, service: LibraryService) {
        diagnosticRecords.removeAll { $0.service == nil }
        if diagnosticRecords.count == 64 { diagnosticRecords.removeFirst() }
        diagnosticRecords.append(DiagnosticRecord(bookID: key.bookID, service: service, sample: sample))
    }

    func diagnostics(bookID: String, service: LibraryService) -> EPUBReopenDiagnostics {
        var result = EPUBReopenDiagnostics()
        for row in diagnosticRecords where row.bookID == bookID && row.service === service {
            result.append(row.sample)
        }
        return result
    }

    func recordClose(_ trace: EPUBReopenDiagnostics, bookID: String, service: LibraryService, generation: UUID) {
        let key = Key(bookID: bookID, service: ObjectIdentifier(service))
        guard diagnosticRoute?.key == key, diagnosticRoute?.generation == generation else { return }
        for sample in trace.samples { record(sample, key: key, service: service) }
    }

    init(limits: Limits = Limits()) {
        self.limits = limits
        // Background is not invalidation. iOS can still terminate WebContent; the controller observes that.
        observations.append(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.discard(reason: .memoryWarning) } })
    }

    func take(bookID: String, service: LibraryService) -> (controller: EPUBWebViewController?, generation: UUID) {
        let key = Key(bookID: bookID, service: ObjectIdentifier(service)), generation = UUID()
        active = (key, generation) // A late close from a superseded route may not repopulate the pool.
        diagnosticRoute = (key, generation)
        let previous = entries.removeValue(forKey: key)
        checkedOut = nil
        trim(reservingForeground: true)
        guard let previous, previous.controller.hasParkedDocument else {
            if let previous {
                recordInvalidation(previous.controller, key: key, service: service)
            }
            record(.init(reason: previous == nil ? .takeMiss : .takeInvalid), key: key, service: service)
            previous?.controller.detachCallbacks()
            misses += 1
            return (nil, generation)
        }
        checkedOut = previous.controller
        hits += 1
        record(.init(reason: .takeHit), key: key, service: service)
        return (previous.controller, generation)
    }

    @discardableResult
    func retain(_ controller: EPUBWebViewController, bookID: String, service: LibraryService, generation: UUID) -> Bool {
        let key = Key(bookID: bookID, service: ObjectIdentifier(service))
        guard active?.key == key, active?.generation == generation else {
            var trace = EPUBReopenDiagnostics(); trace.record(.rejectInactiveRoute)
            recordClose(trace, bookID: bookID, service: service, generation: generation)
            controller.detachCallbacks()
            return false // A stale close must not overwrite the new route's diagnostics either.
        }
        guard controller.hasParkedDocument else {
            record(.init(reason: .rejectNotParked), key: key, service: service)
            controller.detachCallbacks()
            return false
        }
        active = nil; checkedOut = nil
        entries.removeValue(forKey: key)?.controller.detachCallbacks()
        let cost = controller.parkedEstimatedBytes
        guard cost <= limits.idleEstimatedBytes, limits.totalRenderers > 0 else {
            record(.init(reason: cost > limits.idleEstimatedBytes ? .rejectBudget : .rejectDisabled,
                         estimatedBytes: cost, imageBytes: controller.parkedCost?.imageBytes ?? 0,
                         xhtmlBytes: controller.parkedCost?.xhtmlBytes ?? 0, limitBytes: limits.idleEstimatedBytes),
                   key: key, service: service)
            controller.detachCallbacks()
            return false
        }
        serial &+= 1
        entries[key] = Entry(service: service, controller: controller, estimatedBytes: cost, used: serial)
        record(.init(reason: .retained, estimatedBytes: cost,
                     imageBytes: controller.parkedCost?.imageBytes ?? 0,
                     xhtmlBytes: controller.parkedCost?.xhtmlBytes ?? 0, limitBytes: limits.idleEstimatedBytes),
               key: key, service: service)
        trim(reservingForeground: false)
        return entries[key]?.controller === controller
    }

    func finish(_ generation: UUID) {
        guard active?.generation == generation else { return }
        active = nil; checkedOut = nil
    }

    /// Switching to TXT revokes the foreground reservation, not valid idle EPUB content.
    func leaveEPUB() {
        recordActive(.leftEPUB)
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
            if !entry.controller.hasParkedDocument {
                recordInvalidation(entry.controller, key: key, service: entry.service)
            }
            record(.init(reason: !entry.controller.hasParkedDocument ? .evictedInvalid :
                            (entries.count > countLimit ? .evictedCount : .evictedBytes),
                         estimatedBytes: entry.estimatedBytes, limitBytes: limits.idleEstimatedBytes),
                   key: key, service: entry.service)
            entries.removeValue(forKey: key)
            bytes -= entry.estimatedBytes
            entry.controller.detachCallbacks()
            evictions += 1
        }
    }

    private func recordInvalidation(_ controller: EPUBWebViewController, key: Key, service: LibraryService) {
        // Park success was already recorded on close. Only append subsequent invalidation causes.
        for sample in controller.parkDiagnostics.samples where sample.reason == .processTerminated || sample.reason == .parkInvalidated {
            record(sample, key: key, service: service)
        }
    }

    private func recordActive(_ reason: EPUBReopenDiagnostics.Reason) {
        if let active, let service = diagnosticRecords.last(where: {
            $0.bookID == active.key.bookID && $0.service.map { ObjectIdentifier($0) } == active.key.service
        })?.service {
            record(.init(reason: reason), key: active.key, service: service)
        }
    }

    func discard(reason: EPUBReopenDiagnostics.Reason = .explicitDiscard) {
        recordActive(reason)
        active = nil
        for (key, entry) in entries {
            record(.init(reason: reason), key: key, service: entry.service)
            entry.controller.detachCallbacks()
        }
        entries.removeAll()
        checkedOut?.discardParkedState()
        checkedOut = nil
    }
}

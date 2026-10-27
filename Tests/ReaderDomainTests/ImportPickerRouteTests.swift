import Foundation
import Testing
@testable import ReaderDomain

struct ImportPickerRouteTests {
    @Test func selectionBeforeDismissalWaitsAndIsDeliveredExactlyOnce() {
        let id = UUID()
        var route = ImportPickerRoute(id: id)
        let accepted = route.receive(.selected, for: id)
        let beforeDismissal = route.takeReady(for: id)
        #expect(accepted)
        #expect(beforeDismissal == nil)
        #expect(!route.delivered)
        let dismissed = route.confirmDismissal(for: id)
        let ready = route.takeReady(for: id)
        let repeated = route.takeReady(for: id)
        let duplicate = route.receive(.selected, for: id)
        #expect(dismissed)
        #expect(ready == .selected)
        #expect(repeated == nil)
        #expect(!duplicate)
        #expect(route.id == id && route.delivered)
    }

    @Test func selectionAfterDismissalIsNotLostOrInferredAsCancellation() {
        let id = UUID()
        var route = ImportPickerRoute(id: id)
        var diagnostics = ImportDiagnosticState()
        diagnostics.begin(id)
        let dismissed = route.confirmDismissal(for: id)
        diagnostics.pickerClosed(for: id)
        let early = route.takeReady(for: id)
        #expect(dismissed && early == nil)
        #expect(route.outcome == nil && diagnostics.callback == .none)
        let accepted = route.receive(.selected, for: id)
        diagnostics.record(.delegateSelected, for: id)
        let recorded = diagnostics.selected(for: id, hasFile: true)
        let ready = route.takeReady(for: id)
        #expect(accepted && recorded)
        #expect(ready == .selected)
        #expect(diagnostics.callback == .selected)
        #expect(diagnostics.history.contains(.delegateSelected))
        #expect(!diagnostics.history.contains(.delegateCancelled))
    }

    @Test func emptyDelegateResultStaysDistinctAndWaitsForDismissal() {
        let id = UUID()
        var route = ImportPickerRoute(id: id)
        let accepted = route.receive(.empty, for: id)
        let early = route.takeReady(for: id)
        #expect(accepted && early == nil)
        let dismissed = route.confirmDismissal(for: id)
        let ready = route.takeReady(for: id)
        let repeated = route.takeReady(for: id)
        #expect(dismissed && ready == .empty)
        #expect(repeated == nil)
        #expect(route.outcome != .selected && route.outcome != .cancelled)
    }

    @Test func explicitCancellationWorksBeforeOrAfterDismissalWithoutASelection() {
        for dismissFirst in [false, true] {
            let id = UUID()
            var route = ImportPickerRoute(id: id)
            var diagnostics = ImportDiagnosticState()
            diagnostics.begin(id)
            if dismissFirst {
                route.confirmDismissal(for: id)
                diagnostics.pickerClosed(for: id)
            }
            let accepted = route.receive(.cancelled, for: id)
            let recorded = diagnostics.delegateCancelled(for: id)
            let duplicateSelection = route.receive(.selected, for: id)
            if !dismissFirst {
                let early = route.takeReady(for: id)
                #expect(early == nil)
                route.confirmDismissal(for: id)
            }
            let ready = route.takeReady(for: id)
            #expect(accepted && recorded)
            #expect(!duplicateSelection)
            #expect(ready == .cancelled)
            #expect(diagnostics.callback == .delegateCancelled)
            #expect(diagnostics.failure == nil)
            #expect(!diagnostics.history.contains(.selectedCallback))
        }
    }

    @Test func oldCallbacksAndDuplicateDismissalsCannotConsumeTheCurrentRoute() {
        let old = UUID(), current = UUID()
        var route = ImportPickerRoute(id: current)
        let untouched = route
        let oldSelection = route.receive(.selected, for: old)
        let oldCancellation = route.receive(.cancelled, for: old)
        let oldDismissal = route.confirmDismissal(for: old)
        let oldReady = route.takeReady(for: old)
        #expect(!oldSelection && !oldCancellation && !oldDismissal && oldReady == nil)
        #expect(route == untouched)
        let dismissed = route.confirmDismissal(for: current)
        let duplicateDismissal = route.confirmDismissal(for: current)
        let pureClose = route.takeReady(for: current)
        #expect(dismissed && !duplicateDismissal && pureClose == nil)
        #expect(route.outcome == nil && !route.delivered)
        let accepted = route.receive(.selected, for: current)
        let conflictingCancellation = route.receive(.cancelled, for: current)
        let staleDrain = route.takeReady(for: old)
        let ready = route.takeReady(for: current)
        let repeated = route.takeReady(for: current)
        #expect(accepted && !conflictingCancellation)
        #expect(staleDrain == nil && ready == .selected && repeated == nil)
    }
}

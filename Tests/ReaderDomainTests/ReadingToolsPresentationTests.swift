import Foundation
import Testing
@testable import ReaderDomain

private func toolsPanelID(_ state: ReadingToolsPresentation) throws -> UUID {
    let id = state.panelID
    return try #require(id)
}

struct ReadingToolsPresentationTests {
    @Test func centralTapTogglesButAnOldTouchCannotOverrideANewerIntent() {
        var state = ReadingToolsPresentation()
        let initial = state.intent
        state.bodyTapped(expected: initial)
        #expect(state.mode == .hidden)
        state.bodyTapped(expected: initial)
        #expect(state.mode == .hidden)
        let next = state.intent
        state.bodyTapped(expected: next)
        #expect(state.mode == .compact)
    }
    @Test func activeScrollingHidesAndNeitherSettlingNorResumeAutomaticallyRevealsTools() {
        var state = ReadingToolsPresentation()
        state.scrollingBegan()
        #expect(state.mode == .hidden)
        let hidden = state.intent
        state.resume() // Does not synthesize a show intent after interaction/foregrounding.
        #expect(state.mode == .hidden && state.intent == hidden)
        state.show()
        #expect(state.mode == .compact)
    }
    @Test func panelCloseReturnsCompactAndChapterSelectionReturnsImmersive() throws {
        var state = ReadingToolsPresentation()
        state.open(.directory)
        let first = try toolsPanelID(state)
        let closed = state.closePanel(id: first)
        #expect(closed && state.mode == .compact)
        state.open(.directory)
        let second = try toolsPanelID(state)
        let selected = state.chapterSelected(id: second)
        #expect(selected && state.mode == .hidden && first != second)
        let late = state.closePanel(id: second)
        #expect(late == false && state.mode == .hidden)
    }
    @Test func rapidPanelSwitchRejectsOldCloseSelectionAndQueuedBodyTap() throws {
        var state = ReadingToolsPresentation()
        state.open(.directory)
        let old = try toolsPanelID(state), touch = state.intent
        state.open(.settings)
        let current = try toolsPanelID(state)
        let oldClose = state.closePanel(id: old), oldSelection = state.chapterSelected(id: old)
        state.bodyTapped(expected: touch)
        #expect(oldClose == false && oldSelection == false)
        #expect(state.owns(.settings, id: current) && current != old)
        state.open(.directory)
        let latest = try toolsPanelID(state)
        let staleSettingsClose = state.closePanel(id: current)
        #expect(staleSettingsClose == false && state.owns(.directory, id: latest))
    }
    @Test func suspensionRevokesPanelsAndTouchesWithoutRestoringThemOnResume() throws {
        var state = ReadingToolsPresentation()
        state.open(.directory)
        let panel = try toolsPanelID(state), touch = state.intent
        state.suspend()
        state.open(.settings); state.show(); state.bodyTapped(expected: touch)
        let late = state.closePanel(id: panel)
        #expect(late == false && state.mode == .hidden && state.canInteract == false)
        state.resume()
        #expect(state.canInteract && state.mode == .hidden)
        state.bodyTapped(expected: touch)
        #expect(state.mode == .hidden)
    }
    @Test func exitIsSingleFlightAndFailureRestoresAnExplicitExitPath() throws {
        var state = ReadingToolsPresentation()
        state.open(.settings)
        let pending = state.beginExit()
        let id = try #require(pending)
        let duplicate = state.beginExit()
        state.open(.directory); state.scrollingBegan()
        #expect(duplicate == nil && state.mode == .compact && state.canInteract == false)
        let wrong = state.finishExit(UUID(), succeeded: true)
        #expect(wrong == false && state.exitRequest == id)
        let failed = state.finishExit(id, succeeded: false)
        #expect(failed && state.canInteract && state.mode == .compact)
    }
    @Test func invalidatedReaderRejectsLateExitAndAllOldPresentationActions() throws {
        var state = ReadingToolsPresentation()
        let pending = state.beginExit()
        let id = try #require(pending)
        state.invalidate()
        let late = state.finishExit(id, succeeded: true)
        state.resume(); state.show(); state.forceCompact(); state.open(.settings)
        #expect(late == false && state.valid == false && state.mode == .hidden)
    }
    @Test func centralTapCoordinatesUseScrolledBoundsOriginAndRejectEdgesOrInvalidGeometry() {
        #expect(ReadingToolsGesturePolicy.central(x: 200, y: 300, width: 400, height: 600))
        #expect(ReadingToolsGesturePolicy.central(x: 235, y: 9300, width: 400, height: 600, originX: 35, originY: 9000))
        #expect(ReadingToolsGesturePolicy.central(x: 200, y: 284, width: 400, height: 600, originY: -16))
        #expect(ReadingToolsGesturePolicy.central(x: 200, y: 300, width: 400, height: 600, originY: 9000) == false)
        #expect(ReadingToolsGesturePolicy.central(x: 200, y: 10, width: 400, height: 600) == false)
        #expect(ReadingToolsGesturePolicy.central(x: .nan, y: 300, width: 400, height: 600) == false)
        #expect(ReadingToolsGesturePolicy.central(x: 0, y: 0, width: 0, height: 600) == false)
    }
    @Test func momentumIsLatchedAtTouchBeginEvenWhenTapUpIsAlreadyIdle() {
        #expect(ReadingToolsGesturePolicy.tap(beganDuringDeceleration: true, dragging: false, decelerating: false, voiceOver: false) == .stopMomentum)
        #expect(ReadingToolsGesturePolicy.tap(beganDuringDeceleration: false, dragging: false, decelerating: true, voiceOver: false) == .stopMomentum)
        #expect(ReadingToolsGesturePolicy.tap(beganDuringDeceleration: false, dragging: false, decelerating: false, voiceOver: false) == .toggle)
        #expect(ReadingToolsGesturePolicy.tap(beganDuringDeceleration: false, dragging: true, decelerating: false, voiceOver: false) == .ignore)
        #expect(ReadingToolsGesturePolicy.tap(beganDuringDeceleration: false, dragging: false, decelerating: false, voiceOver: true) == .ignore)
    }
    @Test func repeatedPanelOpenDoesNotAllocateAnotherSessionButExplicitCloseRevokesIt() throws {
        var state = ReadingToolsPresentation()
        state.open(.directory)
        let id = try toolsPanelID(state), intent = state.intent
        state.open(.directory)
        #expect(state.panelID == id && state.intent == intent)
        state.forceCompact()
        let late = state.chapterSelected(id: id)
        #expect(late == false && state.mode == .compact)
        state.show()
        #expect(state.mode == .compact)
    }
}

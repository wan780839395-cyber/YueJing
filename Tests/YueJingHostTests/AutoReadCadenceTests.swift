import Foundation
import Testing
@testable import YueJing

@MainActor
struct AutoReadCadenceTests {
    @Test func scrollClockAccumulatesSlowStepsWithoutCatchingUpAfterAStall() {
        var clock = AutoReadClock(mode: .scroll, now: 0)
        let first = clock.distance(at: 0.04, speed: 12, seconds: 8)
        let second = clock.distance(at: 0.09, speed: 12, seconds: 8)
        let delayed = clock.distance(at: 90, speed: 12, seconds: 8)
        #expect(first == nil && second == 1 && delayed == 1)
    }

    @Test func pageClockWaitsForItsIntervalAndBoundsPendingContent() {
        var clock = AutoReadClock(mode: .paged, now: 10)
        let early = clock.distance(at: 17.99, speed: 24, seconds: 8)
        let due = clock.distance(at: 18, speed: 24, seconds: 8)
        #expect(early == nil && due == 0)
        clock.record(.waiting, at: 18)
        clock.record(.waiting, at: 22)
        #expect(!clock.stalled(at: 29.99) && clock.stalled(at: 30))
        clock.record(.advanced, at: 30)
        let nextEarly = clock.distance(at: 32, speed: 24, seconds: 3)
        let nextDue = clock.distance(at: 33, speed: 24, seconds: 3)
        #expect(!clock.waiting && nextEarly == nil && nextDue == 0)
    }

    @Test func openingAnotherReaderRestoresOnlyPaceAndCancelsOldTicks() async throws {
        let suite = UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AutoReadSession(defaults: defaults)
        first.choose(48, for: .scroll); first.choose(12, for: .paged); first.choose(-1, for: .paged)
        var obsoleteCalls = 0
        first.start(mode: .scroll) { _ in obsoleteCalls += 1; return .advanced }
        #expect(first.isRunning)
        first.stop()
        let reopened = AutoReadSession(defaults: defaults)
        #expect(!reopened.isRunning && reopened.speed == 48 && reopened.seconds == 12)
        var endCalls = 0
        first.start(mode: .scroll) { _ in endCalls += 1; return .stop }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while first.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!first.isRunning && endCalls == 1 && obsoleteCalls == 0)
        first.stop()
    }
}

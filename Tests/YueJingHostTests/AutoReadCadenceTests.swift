import Foundation
import Testing
@testable import YueJing

@MainActor
struct AutoReadCadenceTests {
    @Test func scrollClockAccumulatesSlowStepsWithoutCatchingUpAfterAStall() {
        for scale: CGFloat in [2, 3] {
            for hz in [30, 60, 120] {
                var clock = AutoReadClock(mode: .scroll, now: 0, scale: scale)
                var total: CGFloat = 0, sawSubpoint = false
                for frame in 1...(2 * hz) {
                    let now = Double(frame) / Double(hz)
                    guard let d = clock.distance(at: now, speed: 12, seconds: 8) else { continue }
                    #expect(d >= 1 / scale && d * scale == (d * scale).rounded())
                    sawSubpoint = sawSubpoint || d < 1
                    total += d
                    clock.record(.advanced, at: now)
                }
                #expect(sawSubpoint && abs(total - 24) <= 1 / scale + 0.000001)
                let delayed = clock.distance(at: 90, speed: 72, seconds: 8)
                let resumed = clock.distance(at: 90.02, speed: 72, seconds: 8)
                #expect(delayed == nil && (resumed ?? 0) >= 1 && (resumed ?? 0) < 1.5)
                clock.record(.waiting, at: 90.02)
                let early = clock.distance(at: 90.03, speed: 72, seconds: 8)
                let retry = clock.distance(at: 92, speed: 72, seconds: 8)
                clock.record(.waiting, at: 92)
                #expect(early == nil && retry == 1 / scale)
                #expect(!clock.stalled(at: 102) && clock.stalled(at: 102.03))
            }
        }
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
        first.start(mode: .scroll) { _ in obsoleteCalls += 1; return .advanced }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while first.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!first.isRunning && endCalls == 1 && obsoleteCalls == 0)
        first.stop()

        weak var released: AutoReadSession?
        do {
            let transient = AutoReadSession(defaults: defaults)
            released = transient
            transient.start(mode: .scroll) { _ in obsoleteCalls += 1; return .advanced }
        }
        #expect(released == nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(endCalls == 1 && obsoleteCalls == 0)
    }
}

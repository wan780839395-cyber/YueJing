import Foundation
import Testing
@testable import YueJing

@MainActor
struct ReadingTimeLedgerTests {
    private final class Clock {
        var tick: Double = 100
        var wall = Date(timeIntervalSince1970: 86_390) // UTC, ten seconds before midnight.
        func advance(_ seconds: Double) { tick += seconds; wall.addTimeInterval(seconds) }
    }
    private func withLedger(_ test: (ReadingTimeLedger, Clock, () -> ReadingTimeLedger) -> Void) throws {
        let suite = UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = Clock()
        var utc = Calendar(identifier: .gregorian); utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        func reopen() -> ReadingTimeLedger {
            ReadingTimeLedger(defaults: defaults, uptime: { clock.tick }, now: { clock.wall }, calendar: { utc })
        }
        test(reopen(), clock, reopen)
    }

    @Test func readingTimeSplitsMidnightAndDoesNotResumeFromDisk() throws {
        try withLedger { ledger, clock, reopen in
            let owner = UUID()
            ledger.begin(owner: owner, book: "txt"); clock.advance(6)
            ledger.checkpoint(owner: owner); clock.advance(10)
            #expect(ledger.snapshot(book: "txt").today == 6)
            ledger.end(owner: owner); clock.advance(1000)
            let restored = reopen().snapshot(book: "txt")
            #expect(restored.today == 6 && restored.book == 16)
        }
    }
    @Test func readingTimeExcludesPausedTimeAndRejectsStaleRouteUpdates() throws {
        try withLedger { ledger, clock, _ in
            clock.advance(100); let a = UUID(), b = UUID()
            ledger.begin(owner: a, book: "txt"); clock.advance(11)
            ledger.begin(owner: a, book: "txt"); clock.advance(3)
            ledger.end(owner: a); clock.advance(500) // panel/background; no active interval
            ledger.begin(owner: a, book: "txt"); clock.advance(4)
            ledger.begin(owner: b, book: "epub"); clock.advance(7)
            ledger.checkpoint(owner: a); ledger.end(owner: a); clock.advance(5)
            ledger.end(owner: b); ledger.end(owner: b)
            #expect(ledger.snapshot(book: "epub").book == 12)
            #expect(ledger.snapshot(book: "txt").book == 18)
            ledger.forget(book: "txt")
            #expect(ledger.snapshot(book: "txt").book == 0 && ledger.snapshot(book: nil).today == 30)
        }
    }
    @Test func changingWallTimeDoesNotManufactureReadingHours() throws {
        try withLedger { ledger, clock, _ in
            let owner = UUID(); ledger.begin(owner: owner, book: "epub"); clock.advance(5)
            clock.wall.addTimeInterval(12 * 3600)
            ledger.end(owner: owner)
            #expect(ledger.snapshot(book: "epub").book == 5 && ledger.snapshot(book: nil).today == 5)
        }
    }
}

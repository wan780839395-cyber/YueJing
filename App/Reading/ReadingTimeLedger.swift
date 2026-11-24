import Combine
import Foundation

/// Only credited seconds are persisted, never an open interval that might include background time.
@MainActor
final class ReadingTimeLedger: ObservableObject {
    static let shared = ReadingTimeLedger()
    private struct Totals: Codable {
        var day = ""
        var today: TimeInterval = 0
        var books: [String: TimeInterval] = [:]
    }
    private struct Span {
        let owner: UUID
        let book: String
        let uptime: TimeInterval
        let wall: Date
    }
    private static let key = "reader.readingTime.v1"
    private let defaults: UserDefaults
    private let uptime: () -> TimeInterval
    private let now: () -> Date
    private let calendar: () -> Calendar
    private var span: Span?
    @Published private var totals: Totals

    init(defaults: UserDefaults = .standard,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         now: @escaping () -> Date = { Date() }, calendar: @escaping () -> Calendar = { .current }) {
        self.defaults = defaults; self.uptime = uptime; self.now = now; self.calendar = calendar
        totals = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Totals.self, from: $0) } ?? Totals()
    }

    func begin(owner: UUID, book: String) {
        guard span?.owner != owner || span?.book != book else { return }
        if let span { end(owner: span.owner) }
        span = Span(owner: owner, book: book, uptime: uptime(), wall: now())
    }
    func checkpoint(owner: UUID) { settle(owner: owner, continuing: true) }
    func end(owner: UUID) { settle(owner: owner, continuing: false) }

    private func dayKey(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.era, .year, .month, .day], from: date)
        return "\(c.era ?? 0)-\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
    private func credit(_ span: Span, until end: Date, tick: TimeInterval, to output: inout Totals) {
        let elapsed = max(0, tick - span.uptime)
        let cal = calendar(), day = dayKey(end, cal)
        if output.day != day { output.day = day; output.today = 0 }
        output.books[span.book, default: 0] += elapsed
        // Elapsed is measured by the monotonic clock. Wall time only assigns seconds to today's bucket.
        output.today += dayKey(span.wall, cal) == day ? elapsed : min(elapsed, max(0, end.timeIntervalSince(cal.startOfDay(for: end))))
    }
    private func settle(owner: UUID, continuing: Bool) {
        guard let old = span, old.owner == owner else { return }
        let tick = uptime(), end = now()
        span = continuing ? Span(owner: owner, book: old.book, uptime: tick, wall: end) : nil
        var next = totals
        credit(old, until: end, tick: tick, to: &next)
        save(next)
    }
    private func save(_ value: Totals) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.key); totals = value
    }
    func snapshot(book: String?) -> (today: TimeInterval, book: TimeInterval) {
        let end = now(); var current = totals
        if let span { credit(span, until: end, tick: uptime(), to: &current) }
        return (current.day == dayKey(end, calendar()) ? current.today : 0, book.flatMap { current.books[$0] } ?? 0)
    }
    func forget(book: String) {
        if let span, span.book == book { end(owner: span.owner) }
        var next = totals
        if next.books.removeValue(forKey: book) != nil { save(next) } // Today's reading still happened.
    }
}

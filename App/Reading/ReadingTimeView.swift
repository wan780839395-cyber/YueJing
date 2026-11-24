import SwiftUI

private struct ReadingTimeBookKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var readingTimeBook: String? {
        get { self[ReadingTimeBookKey.self] }
        set { self[ReadingTimeBookKey.self] = newValue }
    }
}

/// Bound to the reader route, not to gestures, page-turn ticks or a particular format.
@MainActor
struct ReadingTimeTracking: ViewModifier {
    let owner: UUID
    let readable: Bool
    @Environment(\.readingTimeBook) private var book
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    private var eligible: Bool { visible && readable && phase == .active && book != nil }

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true }
            .onChange(of: eligible) { active in
                if active, let book { ReadingTimeLedger.shared.begin(owner: owner, book: book) }
                else { ReadingTimeLedger.shared.end(owner: owner) }
            }
            .onDisappear { visible = false; ReadingTimeLedger.shared.end(owner: owner) }
            .task(id: eligible) {
                guard eligible else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard !Task.isCancelled else { return }
                    ReadingTimeLedger.shared.checkpoint(owner: owner)
                }
            }
    }
}

@MainActor
struct ReadingTimeSummary: View {
    @Environment(\.readingTimeBook) private var book
    @ObservedObject private var ledger = ReadingTimeLedger.shared

    var body: some View {
        // Only the statistics view refreshes; never invalidate the reading canvas just to show a clock.
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let snapshot = ledger.snapshot(book: book)
            VStack(alignment: .leading, spacing: 8) {
                Text("阅读时长").font(.headline).accessibilityAddTraits(.isHeader)
                metric("今日阅读", snapshot.today, id: "readingTime.today")
                if book != nil { metric("本书累计", snapshot.book, id: "readingTime.book") }
            }
            .padding(.vertical, 8)
        }
    }
    private func metric(_ label: String, _ duration: TimeInterval, id: String) -> some View {
        let minutes = Int(duration / 60)
        let value = duration <= 0 ? "0 分钟" : minutes == 0 ? "不足 1 分钟" : minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时 \(minutes % 60) 分钟"
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).monospacedDigit()
        }
        .font(.subheadline).accessibilityElement(children: .combine).accessibilityIdentifier(id)
    }
}

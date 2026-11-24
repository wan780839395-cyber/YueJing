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
    enum Scope { case today, currentBook }
    let scope: Scope
    @Environment(\.readingTimeBook) private var book
    @ObservedObject private var ledger = ReadingTimeLedger.shared

    init(scope: Scope) { self.scope = scope }

    var body: some View {
        switch scope {
        case .today:
            // Keep the date fresh if the settings stay open across midnight.
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text("今日已读 \(durationText(ledger.snapshot(book: nil).today))")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("readingTime.today")
            }
        case .currentBook:
            if let book {
                Text("这本书已读 \(durationText(ledger.snapshot(book: book).book))")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("readingTime.book")
            }
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "0 分钟" }
        let minutes = Int(duration / 60)
        guard minutes > 0 else { return "不足 1 分钟" }
        guard minutes >= 60 else { return "\(minutes) 分钟" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(remainder) 分钟"
    }
}

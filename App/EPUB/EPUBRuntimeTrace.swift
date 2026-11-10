import Foundation

/// Local main-actor recorder. No ObservableObject, I/O, publication identity or per-frame publication.
@MainActor
struct EPUBRuntimeTrace {
    enum Event: String, CaseIterable {
        case webViewCreationStarted, webViewCreated, documentLoad, documentFinished, locatorReady
        case promotion, navigation, windowRequested, windowCancelled
        case windowCommitted, windowDeferred, windowFailed, dragging, settled, momentumStopped
    }
    struct Entry {
        let event: Event
        let milliseconds: Double
    }
    private let started = ContinuousClock.now
    private(set) var entries: [Entry] = []
    private(set) var counts: [Event: Int] = [:]
    private var first: [Event: Double] = [:]

    mutating func record(_ event: Event) {
        let duration = started.duration(to: ContinuousClock.now).components
        let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        counts[event, default: 0] += 1
        if first[event] == nil { first[event] = ms }
        if entries.count == 128 { entries.removeFirst() }
        entries.append(Entry(event: event, milliseconds: ms))
    }

    var summary: String {
        let milestones = [Event.webViewCreationStarted, .webViewCreated, .documentLoad, .documentFinished, .locatorReady].compactMap { event in
            first[event].map { event.rawValue + String(format: " @%.1fms", $0) }
        }.joined(separator: "\n")
        let totals = Event.allCases.compactMap { event in counts[event].map { "\(event.rawValue)=\($0)" } }.joined(separator: " ")
        let recent = entries.map { String(format: "%.1fms ", $0.milliseconds) + $0.event.rawValue }.joined(separator: "\n")
        return "原生事件：控制器创建起计时（不是点击起点/首绘）\n" + milestones + "\n" + totals
            + "\n最近128条以内：\n" + recent
    }
}

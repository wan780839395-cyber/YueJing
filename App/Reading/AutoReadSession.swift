import Combine
import Foundation
import QuartzCore

enum AutoReadMode { case scroll, paged }
enum AutoReadStep { case advanced, waiting, stop }

/// Monotonic cadence. Missed frames never build up a backlog of pages or scroll distance.
struct AutoReadClock {
    let mode: AutoReadMode
    private var lastTick: TimeInterval
    private var pageStarted: TimeInterval
    private var fraction = 0.0
    private var waitingSince: TimeInterval?

    init(mode: AutoReadMode, now: TimeInterval) {
        self.mode = mode; lastTick = now; pageStarted = now
    }
    var waiting: Bool { waitingSince != nil }
    func stalled(at now: TimeInterval) -> Bool { waitingSince.map { now - $0 >= 12 } ?? false }
    mutating func distance(at now: TimeInterval, speed: Int, seconds: Int) -> CGFloat? {
        let elapsed = max(0, min(now - lastTick, 0.1)); lastTick = now
        if mode == .paged { return now - pageStarted >= Double(seconds) ? 0 : nil }
        fraction += elapsed * Double(speed)
        let whole = fraction.rounded(.down); fraction -= whole
        return whole > 0 ? CGFloat(whole) : nil
    }
    mutating func record(_ result: AutoReadStep, at now: TimeInterval) {
        switch result {
        case .advanced: waitingSince = nil; pageStarted = now
        case .waiting: if waitingSince == nil { waitingSince = now }; fraction = 0
        case .stop: break
        }
    }
}

@MainActor
final class AutoReadSession: ObservableObject {
    static let speeds = [12, 24, 36, 48, 72]
    static let intervals = [3, 5, 8, 12, 20, 30]
    @Published private(set) var isRunning = false
    @Published private(set) var speed: Int
    @Published private(set) var seconds: Int
    private let defaults: UserDefaults
    private static let speedKey = "reader.autoRead.pointsPerSecond.v1"
    private static let secondsKey = "reader.autoRead.pageSeconds.v1"
    private var runner: Task<Void, Never>?
    private var generation: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let speed = defaults.integer(forKey: Self.speedKey), seconds = defaults.integer(forKey: Self.secondsKey)
        self.speed = Self.speeds.contains(speed) ? speed : 24
        self.seconds = Self.intervals.contains(seconds) ? seconds : 8
    }
    func choose(_ value: Int, for mode: AutoReadMode) {
        switch mode {
        case .scroll where Self.speeds.contains(value): speed = value; defaults.set(value, forKey: Self.speedKey)
        case .paged where Self.intervals.contains(value): seconds = value; defaults.set(value, forKey: Self.secondsKey)
        default: break
        }
    }
    func start(mode: AutoReadMode, step: @escaping @MainActor (CGFloat) -> AutoReadStep) {
        guard !isRunning else { return }
        let id = UUID(); generation = id; isRunning = true
        var clock = AutoReadClock(mode: mode, now: CACurrentMediaTime())
        runner = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(clock.waiting || mode == .paged ? 100 : 33)) }
                catch { return }
                guard let self, self.generation == id, !Task.isCancelled else { return }
                let now = CACurrentMediaTime()
                if clock.stalled(at: now) { self.stop(); return }
                guard let distance = clock.distance(at: now, speed: self.speed, seconds: self.seconds) else { continue }
                let result = step(distance)
                guard self.generation == id else { return }
                if result == .stop { self.stop(); return }
                clock.record(result, at: now)
            }
        }
    }
    func stop() {
        guard isRunning else { return }
        generation = nil; runner?.cancel(); runner = nil; isRunning = false
    }
}

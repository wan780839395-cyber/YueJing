import Combine
import Foundation
import QuartzCore
import UIKit

enum AutoReadMode { case scroll, paged }
enum AutoReadStep { case advanced, waiting, stop }

/// Monotonic cadence. Missed frames never build up a backlog of pages or scroll distance.
struct AutoReadClock {
    let mode: AutoReadMode
    private var lastTick: TimeInterval
    private var pageStarted: TimeInterval
    private let scale: CGFloat
    private var residualPixels: CGFloat = 0
    private var waitingSince: TimeInterval?

    init(mode: AutoReadMode, now: TimeInterval, scale: CGFloat = 1) {
        self.scale = max(1, scale)
        self.mode = mode; lastTick = now; pageStarted = now
    }
    var waiting: Bool { waitingSince != nil }
    func stalled(at now: TimeInterval) -> Bool { waitingSince.map { now - $0 >= 12 } ?? false }
    mutating func distance(at now: TimeInterval, speed: Int, seconds: Int) -> CGFloat? {
        if mode == .paged { return now - pageStarted >= Double(seconds) ? 0 : nil }
        let elapsed = now - lastTick
        if waiting {
            // Probe at the old 100 ms cadence. Time spent loading isn't scroll debt.
            guard elapsed >= 0.1 else { return nil }
            lastTick = now
            return 1 / scale
        }
        guard elapsed > 0 else { return nil }
        lastTick = now
        guard elapsed <= 0.1 else { residualPixels = 0; return nil }
        residualPixels += CGFloat(elapsed) * CGFloat(speed) * scale
        let pixels = residualPixels.rounded(.down)
        residualPixels -= pixels
        return pixels > 0 ? pixels / scale : nil
    }
    mutating func record(_ result: AutoReadStep, at now: TimeInterval) {
        switch result {
        case .advanced: waitingSince = nil; pageStarted = now
        case .waiting: if waitingSince == nil { waitingSince = now }; residualPixels = 0
        case .stop: break
        }
    }
}

/// The run loop retains the link and its target, not this lifetime token. Dropping
/// the token invalidates the link even if no more frames arrive to run a callback.
private final class ScrollDisplayDriver {
    @MainActor private final class Target: NSObject {
        let tick: @MainActor (TimeInterval) -> Void
        init(tick: @escaping @MainActor (TimeInterval) -> Void) { self.tick = tick }
        @objc func frame(_ sender: CADisplayLink) { tick(sender.timestamp) }
    }

    private let link: CADisplayLink
    @MainActor init(tick: @escaping @MainActor (TimeInterval) -> Void) {
        link = CADisplayLink(target: Target(tick: tick), selector: #selector(Target.frame(_:)))
        link.add(to: .main, forMode: .common)
    }
    deinit { link.invalidate() }
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
    private var displayDriver: ScrollDisplayDriver?
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
        var clock = AutoReadClock(mode: mode, now: CACurrentMediaTime(), scale: mode == .scroll ? UIScreen.main.scale : 1)
        let tick: @MainActor (TimeInterval) -> Void = { [weak self] now in
            guard let self, self.generation == id else { return }
            if clock.stalled(at: now) { self.stop(); return }
            guard let distance = clock.distance(at: now, speed: self.speed, seconds: self.seconds) else { return }
            let result = step(distance)
            guard self.generation == id else { return } // A step may stop/restart synchronously.
            if result == .stop { self.stop(); return }
            clock.record(result, at: now)
        }
        if mode == .scroll {
            displayDriver = ScrollDisplayDriver(tick: tick)
            return
        }
        runner = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard let self, self.generation == id, !Task.isCancelled else { return }
                tick(CACurrentMediaTime())
            }
        }
    }
    func stop() {
        guard isRunning else { return }
        generation = nil; displayDriver = nil; runner?.cancel(); runner = nil; isRunning = false
    }
}

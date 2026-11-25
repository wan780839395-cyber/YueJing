import AVFAudio
import Combine
import UIKit

struct ReaderSpeechChunk {
    typealias Follow = @MainActor (@escaping @MainActor () -> Bool) -> Void
    let follow: Follow?
    let text: String
    let locate: @MainActor () -> Void

    init(text: String, follow: Follow? = nil, locate: @escaping @MainActor () -> Void) {
        self.text = text; self.follow = follow; self.locate = locate
    }
}

enum ReaderSpeechRate: String, CaseIterable {
    case slow = "稍慢", normal = "正常", fast = "稍快"
    var multiplier: Float {
        switch self { case .slow: 0.8; case .normal: 1; case .fast: 1.25 }
    }
}

/// The audio callbacks and bounded native text source drive playback, not SwiftUI visibility or a display link.
@MainActor
final class ReaderSpeechSession: ObservableObject {
    typealias Source = @MainActor () async throws -> ReaderSpeechChunk?
    enum Phase { case idle, playing, paused }
    @Published private(set) var phase = Phase.idle
    @Published var rate = ReaderSpeechRate.normal
    @Published private(set) var notice: String?
    @Published private(set) var isFollowing = true
    var isActive: Bool { phase != .idle }

    private let audio: any ReaderSpeechAudio
    private let foreground: @MainActor () -> Bool
    private var next: Source?
    private var generation = UUID()
    private var speaking: UUID?
    private var loader: Task<Void, Never>?
    private var queue: [ReaderSpeechChunk] = [] // Current sentence plus at most one lookahead.
    private var eof = false
    private var sourceError = false
    private var heard: (@MainActor () -> Void)?
    // Deliberately not published: utterances must not invalidate a hidden SwiftUI reader.
    private var heardFollow: ReaderSpeechChunk.Follow?
    private var followTicket = UUID()
    private var followSuspended = false
    private var needsCatchUp = false
    private var deferredLocation: (@MainActor () -> Void)?
    private var observers = Set<AnyCancellable>()

    init(audio: any ReaderSpeechAudio = OfflineReaderSpeechAudio(),
         foreground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.audio = audio; self.foreground = foreground
        let center = NotificationCenter.default
        center.publisher(for: AVAudioSession.interruptionNotification)
            .compactMap { @Sendable notification in notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt }
            .receive(on: DispatchQueue.main).sink { [weak self] type in
                if type == AVAudioSession.InterruptionType.began.rawValue { self?.pause() }
            }.store(in: &observers)
        center.publisher(for: AVAudioSession.routeChangeNotification)
            .compactMap { @Sendable notification in notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt }
            .receive(on: DispatchQueue.main).sink { [weak self] reason in
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }.store(in: &observers)
        center.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.restoreFinalLocation() }
            .store(in: &observers)
    }

    func start(next: @escaping Source) {
        stop(restorePosition: false)
        if !isFollowing { isFollowing = true }
        followSuspended = false
        notice = nil; self.next = next; phase = .playing
        pump()
    }

    func pause() {
        guard phase == .playing else { return }
        followTicket = UUID(); needsCatchUp = false
        phase = .paused; speaking = nil; audio.silence()
        // Keep even an in-flight fetch: the source may already have advanced its cursor.
    }

    func resume() {
        guard phase == .paused else { return }
        notice = nil; phase = .playing; pump()
    }

    func stop(restorePosition: Bool = true) {
        let location = restorePosition && isFollowing ? (heard ?? deferredLocation) : nil
        followTicket = UUID(); heardFollow = nil; needsCatchUp = false
        generation = UUID(); speaking = nil; loader?.cancel(); loader = nil
        next = nil; queue.removeAll(); heard = nil; eof = false; sourceError = false
        audio.silence(); phase = .idle; notice = nil
        deferredLocation = location
        restoreFinalLocation()
    }

    func detachFollow() {
        guard isActive, isFollowing else { return }
        followTicket = UUID(); needsCatchUp = false; isFollowing = false
    }

    func returnToSpeech() {
        guard isActive, !isFollowing else { return }
        isFollowing = true
        // This explicit action may reveal the current sentence even while audio is paused.
        offerHeardPosition(allowPaused: true)
    }

    func suspendFollowing() {
        followSuspended = true; followTicket = UUID()
        needsCatchUp = phase == .playing && isFollowing
    }

    func restoreWhenVisible() {
        guard foreground() else { return }
        followSuspended = false
        restoreFinalLocation()
        if needsCatchUp && phase == .playing { offerHeardPosition() }
    }

    func retryFollowIfNeeded() {
        guard phase == .playing, isFollowing, !followSuspended else { return }
        offerHeardPosition()
    }

    private func offerHeardPosition(allowPaused: Bool = false) {
        guard isFollowing, let follow = heardFollow, isActive, allowPaused || phase == .playing else { return }
        guard !followSuspended, foreground() else { needsCatchUp = true; return }
        needsCatchUp = false
        let ticket = UUID(), owner = generation
        followTicket = ticket
        follow { [weak self] in
            guard let self else { return false }
            return generation == owner && followTicket == ticket && isActive && isFollowing &&
                !followSuspended && foreground() && (allowPaused || phase == .playing)
        }
    }

    private func restoreFinalLocation() {
        guard foreground(), let location = deferredLocation else { return }
        deferredLocation = nil; location()
    }

    private func pump() {
        guard phase == .playing, let next else { return }
        if speaking == nil, let chunk = queue.first {
            let id = UUID(); speaking = id
            do {
                try audio.speak(chunk.text, multiplier: rate.multiplier, started: { [weak self] in
                    guard let self, speaking == id else { return }
                    heard = chunk.locate; heardFollow = chunk.follow; followTicket = UUID()
                    offerHeardPosition()
                }, ended: { [weak self] ok in
                    guard let self, speaking == id else { return }
                    if !ok { pause(); return }
                    heard = chunk.locate; speaking = nil; queue.removeFirst(); pump()
                })
            } catch { pause(); notice = "声音暂不可用，请检查音频输出后继续。"; return }
        }
        if eof && queue.isEmpty {
            let message = sourceError ? "未能读取下一段正文。" : heard == nil ? "当前位置没有可朗读的正文。" : nil
            stop(); notice = message; return
        }
        if speaking != nil, queue.count == 2 {
            audio.prepare(queue[1].text, multiplier: rate.multiplier)
        }
        guard loader == nil, !eof, queue.count < 2 else { return }
        let owner = generation
        loader = Task { [weak self] in
            do {
                let chunk = try await next()
                guard let self, generation == owner else { return }
                loader = nil
                if let chunk {
                    if chunk.text.rangeOfCharacter(from: .alphanumerics) != nil { queue.append(chunk) }
                } else { eof = true }
                pump()
            } catch {
                guard let self, generation == owner else { return }
                loader = nil; eof = true; sourceError = true; pump()
            }
        }
    }
}

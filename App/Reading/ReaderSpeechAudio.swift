import AVFAudio
import Foundation

@MainActor
protocol ReaderSpeechAudio: AnyObject {
    func speak(_ text: String, multiplier: Float, started: @escaping @MainActor () -> Void,
               ended: @escaping @MainActor (Bool) -> Void) throws
    func silence()
}

/// Only identity is inspected across the delegate hop; keep the object alive so its address cannot be recycled.
private struct SpeechIdentity: @unchecked Sendable { let utterance: AVSpeechUtterance }

@MainActor
final class SystemReaderSpeechAudio: NSObject, ReaderSpeechAudio, AVSpeechSynthesizerDelegate {
    private lazy var synthesizer: AVSpeechSynthesizer = {
        let synth = AVSpeechSynthesizer()
        synth.usesApplicationAudioSession = true
        synth.delegate = self
        return synth
    }()
    private var current: AVSpeechUtterance?
    private var started: (@MainActor () -> Void)?
    private var ended: (@MainActor (Bool) -> Void)?
    private var ownsAudio = false
    private let session = AVAudioSession.sharedInstance()

    func speak(_ text: String, multiplier: Float, started: @escaping @MainActor () -> Void,
               ended: @escaping @MainActor (Bool) -> Void) throws {
        if !ownsAudio {
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            ownsAudio = true
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * multiplier
        self.started = started
        self.ended = ended
        current = utterance
        synthesizer.speak(utterance)
    }

    func silence() {
        current = nil; started = nil; ended = nil
        guard ownsAudio else { return }
        synthesizer.stopSpeaking(at: .immediate)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        ownsAudio = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let event = SpeechIdentity(utterance: utterance)
        Task { @MainActor [weak self] in
            guard let self, current === event.utterance else { return }
            started?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        complete(SpeechIdentity(utterance: utterance), success: true)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        complete(SpeechIdentity(utterance: utterance), success: false)
    }

    private nonisolated func complete(_ event: SpeechIdentity, success: Bool) {
        Task { @MainActor [weak self] in
            guard let self, current === event.utterance else { return }
            let callback = ended
            current = nil; started = nil; ended = nil
            callback?(success)
        }
    }
}

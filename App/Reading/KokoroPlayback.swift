import AVFAudio
import Foundation

/// Synthesis yields mono float PCM. Build a bounded, in-memory WAV on a generic executor;
/// nothing derived from the reader's text is written to disk.
enum KokoroWave {
    enum Failure: Error { case invalidAudio, couldNotPlay }
    static func encode(_ pcm: KokoroPCM) async throws -> Data {
        let rate = pcm.sampleRate, count = pcm.samples.count
        guard (8_000...96_000).contains(rate), count > 0, count <= min(rate * 180, 4_500_000) else { throw Failure.invalidAudio }
        try Task.checkCancellation()
        let bytes = count * 2
        var data = Data(capacity: 44 + bytes)
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + bytes)); data.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(rate)); word(UInt32(rate * 2)); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(UInt32(bytes))
        var samples = [Int16](); samples.reserveCapacity(4096)
        for (index, sample) in pcm.samples.enumerated() {
            if index % 4096 == 0 { try Task.checkCancellation() }
            guard sample.isFinite else { throw Failure.invalidAudio }
            samples.append(Int16((max(-1, min(1, sample)) * 32767).rounded()).littleEndian)
            if samples.count == 4096 {
                samples.withUnsafeBytes { data.append(contentsOf: $0) }; samples.removeAll(keepingCapacity: true)
            }
        }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }; return data
    }
}

@MainActor
protocol KokoroWavePlaying: AnyObject {
    func play(_ data: Data, ended: @escaping @MainActor (Bool) -> Void) throws
    func stop()
}

@MainActor
final class KokoroWavePlayer: NSObject, KokoroWavePlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var ended: (@MainActor (Bool) -> Void)?
    private var active = false
    func play(_ data: Data, ended: @escaping @MainActor (Bool) -> Void) throws {
        let next = try AVAudioPlayer(data: data)
        let session = AVAudioSession.sharedInstance()
        if !active { try session.setCategory(.playback, mode: .spokenAudio); try session.setActive(true); active = true }
        next.delegate = self; self.ended = ended; player = next
        guard next.play() else { stop(); throw KokoroWave.Failure.couldNotPlay }
    }
    func stop() {
        ended = nil; player?.delegate = nil; player?.stop(); player = nil
        if active { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); active = false }
    }
    // The callback never reads the player across actors. Retain its identity until comparison.
    private struct Event: @unchecked Sendable { let player: AVAudioPlayer }
    private nonisolated func complete(_ event: Event, ok: Bool) {
        Task { @MainActor [weak self] in
            guard let self, player === event.player else { return }
            let callback = ended; ended = nil; player = nil; callback?(ok)
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { complete(Event(player: player), ok: flag) }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { complete(Event(player: player), ok: false) }
}

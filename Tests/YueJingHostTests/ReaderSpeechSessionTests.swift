import Foundation
import Testing
@testable import YueJing

@MainActor
struct ReaderSpeechSessionTests {
    private final class Audio: ReaderSpeechAudio {
        var texts: [String] = []
        var rates: [Float] = []
        var finish: (@MainActor (Bool) -> Void)?
        func speak(_ text: String, multiplier: Float, started: @escaping @MainActor () -> Void,
                   ended: @escaping @MainActor (Bool) -> Void) throws {
            texts.append(text); rates.append(multiplier); finish = ended; started()
        }
        func silence() { finish = nil }
    }
    private func waitFor(_ predicate: @MainActor () -> Bool) async throws {
        let until = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
        try #require(predicate())
    }

    @Test func builtAppDeclaresAudioBackgroundMode() throws {
        let modes = try #require(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])
        #expect(modes == ["audio"])
    }

    @Test func pauseReplaysHeardSentenceAndRejectsOldCompletion() async throws {
        let audio = Audio(), session = ReaderSpeechSession(audio: audio, foreground: { true })
        var index = 0, located = -1
        session.start {
            guard index < 3 else { return nil }; let n = index; index += 1
            return ReaderSpeechChunk(text: String(n)) { located = n }
        }
        try await waitFor { index == 2 && audio.texts == ["0"] }
        let old = try #require(audio.finish)
        session.pause(); old(true); session.rate = .fast; session.resume()
        #expect(audio.texts == ["0", "0"] && audio.rates.last == ReaderSpeechRate.fast.multiplier)
        old(true); session.stop()
        #expect(located == 0 && !session.isActive && index == 2)
    }
    @Test func backgroundPlaybackAdvancesAndRestoresOnlyWhenVisible() async throws {
        let audio = Audio()
        var active = true, index = 0, locations: [Int] = []
        let session = ReaderSpeechSession(audio: audio, foreground: { active })
        session.start {
            guard index < 2 else { return nil }; let n = index; index += 1
            return ReaderSpeechChunk(text: String(n)) { locations.append(n) }
        }
        try await waitFor { index == 2 && audio.texts == ["0"] }
        active = false; audio.finish?(true)
        try await waitFor { audio.texts == ["0", "1"] }; audio.finish?(true)
        try await waitFor { !session.isActive }; #expect(locations.isEmpty)
        active = true; session.restoreWhenVisible(); session.restoreWhenVisible()
        #expect(locations == [1])
    }
    @Test func lateSourceCannotStartAudioInNewBook() async throws {
        let audio = Audio(), session = ReaderSpeechSession(audio: audio, foreground: { true })
        var gate: CheckedContinuation<Void, Never>?
        var returned = false, delivered = false
        session.start {
            await withCheckedContinuation { gate = $0 }; returned = true
            return ReaderSpeechChunk(text: "旧") { Issue.record("旧会话不能定位") }
        }
        try await waitFor { gate != nil }
        session.start {
            if delivered { return nil }; delivered = true
            return ReaderSpeechChunk(text: "新") { }
        }
        gate?.resume(); try await waitFor { returned && audio.texts == ["新"] }
        session.stop(restorePosition: false); #expect(audio.texts == ["新"])
    }
}

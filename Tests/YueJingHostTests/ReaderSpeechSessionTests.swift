import Foundation
import Testing
@testable import YueJing

@MainActor
struct ReaderSpeechSessionTests {
    private final class Audio: ReaderSpeechAudio {
        var texts: [String] = []
        var rates: [Float] = []
        var begin: (@MainActor () -> Void)?
        var immediateStart = true
        var finish: (@MainActor (Bool) -> Void)?
        func speak(_ text: String, multiplier: Float, started: @escaping @MainActor () -> Void,
                   ended: @escaping @MainActor (Bool) -> Void) throws {
            texts.append(text); rates.append(multiplier); finish = ended; begin = started
            if immediateStart { started() }
        }
        func silence() { finish = nil }
    }
    private func waitFor(_ predicate: @MainActor () -> Bool) async throws {
        let until = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
        try #require(predicate())
    }

    @Test func installedMandarinVoicePrefersQualityWithoutSwitchingDialect() {
        let voices = [(id: "standard", language: "zh-CN", quality: 1),
                      (id: "better", language: "zh_Hans_CN", quality: 2),
                      (id: "hk", language: "zh-HK", quality: 3)]
        #expect(SystemReaderSpeechAudio.mandarinVoiceID(voices, systemID: "standard") == "better")
        #expect(SystemReaderSpeechAudio.mandarinVoiceID(voices + [("another", "zh-CN", 2)], systemID: "better") == "better")
        #expect(SystemReaderSpeechAudio.mandarinVoiceID([], systemID: "standard") == "standard")
        #expect(SystemReaderSpeechAudio.mandarinVoiceID([], systemID: nil) == nil)
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
    @Test func speechFollowUsesAudibleStartAndManualReturnNotPrefetch() async throws {
        let audio = Audio(), session = ReaderSpeechSession(audio: audio, foreground: { true })
        audio.immediateStart = false
        var i = 0, reveals: [Int] = [], stops: [Int] = []
        var valid: (@MainActor () -> Bool)?
        session.start {
            guard i < 3 else { return nil }; let n = i; i += 1
            return ReaderSpeechChunk(text: String(n), follow: { lease in
                if lease() { reveals.append(n) }; valid = lease
            }, locate: { stops.append(n) })
        }
        try await waitFor { i == 2 && audio.texts == ["0"] }; #expect(reveals.isEmpty)
        audio.begin?(); #expect(reveals == [0] && valid?() == true)
        let staleStart = try #require(audio.begin)
        session.detachFollow(); #expect(valid?() == false && session.phase == .playing)
        audio.finish?(true); try await waitFor { audio.texts == ["0", "1"] }; audio.begin?()
        #expect(reveals == [0]); session.returnToSpeech(); #expect(reveals == [0, 1])
        session.pause(); staleStart(); #expect(valid?() == false && reveals == [0, 1])
        session.detachFollow(); session.stop(); #expect(stops.isEmpty)
    }

    @Test func speechFollowCoalescesWhileLockedAndDoesNotReattachOnUnlock() async throws {
        let audio = Audio(); var active = true, i = 0, reveals: [Int] = []
        let session = ReaderSpeechSession(audio: audio, foreground: { active })
        session.start {
            let n = i; i += 1
            return ReaderSpeechChunk(text: String(n), follow: { lease in
                if lease() { reveals.append(n) }
            }, locate: {})
        }
        try await waitFor { reveals == [0] }; session.suspendFollowing(); active = false
        audio.finish?(true); try await waitFor { audio.texts.count == 2 }
        audio.finish?(true); try await waitFor { audio.texts.count == 3 }; #expect(reveals == [0])
        active = true; session.restoreWhenVisible(); session.restoreWhenVisible(); #expect(reveals == [0, 2])
        session.detachFollow(); session.suspendFollowing(); active = false
        audio.finish?(true); try await waitFor { audio.texts.count == 4 }
        active = true; session.restoreWhenVisible(); #expect(!session.isFollowing && reveals == [0, 2])
        session.returnToSpeech(); #expect(reveals == [0, 2, 3]); session.stop(restorePosition: false)
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

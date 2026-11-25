import Foundation
import Testing
@testable import YueJing

@MainActor
struct KokoroRoutingTests {
    private final class System: ReaderSpeechAudio {
        var texts: [String] = []
        func speak(_ text: String, multiplier: Float, started: @escaping @MainActor () -> Void,
                   ended: @escaping @MainActor (Bool) -> Void) throws { texts.append(text); started() }
        func silence() {}
    }
    private final class Player: KokoroWavePlaying {
        var waves: [Data] = []
        var end: (@MainActor (Bool) -> Void)?
        func play(_ data: Data, ended: @escaping @MainActor (Bool) -> Void) throws { waves.append(data); end = ended }
        func stop() { end = nil }
    }
    private actor ControlledRender {
        var requests: [String] = []
        var gate: CheckedContinuation<Data, Never>?
        func render(_ text: String) async -> Data {
            requests.append(text); return await withCheckedContinuation { gate = $0 }
        }
        func finish() { gate?.resume(returning: Data([1])); gate = nil }
    }
    private func until(_ test: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await test()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let observed = await test(); try #require(observed)
    }
    @Test func unavailablePackOrSynthesisFailureUsesSystemOnSameSentence() async throws {
        let system = System(), player = Player(); var directory: URL?, starts = 0
        let router = OfflineReaderSpeechAudio(directory: { directory }, render: { _,_,_ in throw KokoroWave.Failure.invalidAudio }, player: player, system: system)
        try router.speak("无包", multiplier: 1, started: { starts += 1 }, ended: { _ in })
        directory = URL(fileURLWithPath: "/synthetic/pack")
        try router.speak("坏包", multiplier: 1, started: { starts += 1 }, ended: { _ in })
        try await until { starts == 2 }; #expect(system.texts == ["无包", "坏包"] && player.waves.isEmpty)
        router.silence()
    }
    @Test func offlinePrefetchIsSilentAndLateRenderCannotRestartPlayback() async throws {
        let system = System(), player = Player(), synth = ControlledRender(); var starts = 0, ends = 0
        let router = OfflineReaderSpeechAudio(directory: { URL(fileURLWithPath: "/synthetic/pack") }, render: { text,_,_ in await synth.render(text) }, player: player, system: system)
        router.prepare("首句", multiplier: 1); try await until { await synth.requests == ["首句"] }
        #expect(player.waves.isEmpty); try router.speak("首句", multiplier: 1, started: { starts += 1 }, ended: { ok in if ok { ends += 1 } })
        #expect(starts == 0); await synth.finish(); try await until { starts == 1 }
        player.end?(true); #expect(ends == 1 && system.texts.isEmpty)
        try router.speak("晚回", multiplier: 1, started: { starts += 1 }, ended: { _ in ends += 1 }); try await until { await synth.requests == ["首句", "晚回"] }
        router.silence(); await synth.finish(); await Task.yield(); #expect(starts == 1 && ends == 1 && player.waves.count == 1 && system.texts.isEmpty)
    }
    @Test func kokoroWaveIsBoundedMonoPCMAndRejectsInvalidOutput() async throws {
        let wav = try await KokoroWave.encode(KokoroPCM(samples: [-1, 0, 1], sampleRate: 24_000))
        #expect(wav.count == 50 && String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(Array(wav.suffix(6)) == [1, 128, 0, 0, 255, 127])
        await #expect(throws: KokoroWave.Failure.self) { _ = try await KokoroWave.encode(KokoroPCM(samples: [.nan], sampleRate: 24_000)) }
        await #expect(throws: KokoroWave.Failure.self) { _ = try await KokoroWave.encode(KokoroPCM(samples: [], sampleRate: 0)) }
    }
}

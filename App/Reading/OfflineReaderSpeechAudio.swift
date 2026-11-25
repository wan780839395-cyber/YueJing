import Foundation

/// One router per reader. No model, network or audio session is opened merely by opening a book.
@MainActor
final class OfflineReaderSpeechAudio: ReaderSpeechAudio {
    typealias Render = @Sendable (String, Float, URL) async throws -> Data
    private struct Key: Equatable { let text: String; let speed: Float; let directory: URL }
    private let directory: @MainActor () -> URL?
    private let render: Render
    private let releaseRenderer: @Sendable () async -> Void
    private let player: any KokoroWavePlaying
    private let system: any ReaderSpeechAudio
    private var prepared: (Key, Task<Data, Error>)?
    private var current: Task<Void, Never>?
    private var ticket = UUID()
    private var failedPack: URL?
    private var usingSystem = false
    private var usedRenderer = false
    private var release: Task<Void, Never>?

    convenience init() {
        let renderer = KokoroRenderer()
        self.init(directory: {
            let store = KokoroPackStore.shared
            return store.useKokoro ? store.installedDirectory : nil
        }, render: { text, speed, dir in
            let pcm = try await renderer.render(text: text, speed: speed, directory: dir)
            return try await KokoroWave.encode(pcm)
        }, releaseRenderer: { await renderer.reset() }, player: KokoroWavePlayer(), system: SystemReaderSpeechAudio())
    }
    init(directory: @escaping @MainActor () -> URL?, render: @escaping Render,
         releaseRenderer: @escaping @Sendable () async -> Void = {},
         player: any KokoroWavePlaying, system: any ReaderSpeechAudio) {
        self.directory = directory; self.render = render; self.releaseRenderer = releaseRenderer
        self.player = player; self.system = system
    }
    private func makeRender(_ key: Key) -> Task<Data, Error> {
        usedRenderer = true
        let priorRelease = release
        return Task { [render] in
            await priorRelease?.value; try Task.checkCancellation()
            return try await render(key.text, key.speed, key.directory)
        }
    }
    func prepare(_ text: String, multiplier: Float) {
        guard let dir = directory(), failedPack != dir else { return }
        let key = Key(text: text, speed: multiplier, directory: dir)
        guard prepared?.0 != key else { return }; prepared?.1.cancel(); prepared = (key, makeRender(key))
    }
    func speak(_ text: String, multiplier: Float, started: @escaping @MainActor () -> Void,
               ended: @escaping @MainActor (Bool) -> Void) throws {
        let id = UUID(); ticket = id
        guard let dir = directory(), failedPack != dir else {
            prepared?.1.cancel(); prepared = nil; player.stop(); usingSystem = true
            try system.speak(text, multiplier: multiplier, started: started, ended: ended); return
        }
        if usingSystem { system.silence(); usingSystem = false }
        let key = Key(text: text, speed: multiplier, directory: dir)
        let task: Task<Data, Error>
        if let (old, pending) = prepared, old == key { task = pending }
        else { prepared?.1.cancel(); task = makeRender(key) }
        prepared = nil
        current = Task { [weak self] in
            do {
                let data = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard let self, ticket == id, !Task.isCancelled else { return }
                guard directory() == dir else { throw CancellationError() }
                try player.play(data) { [weak self] ok in
                    guard let self, ticket == id else { return }
                    // A failure after audible start is not permission to replay the sentence on top of it.
                    if !ok { failedPack = dir }; ended(ok)
                }
                started()
            } catch {
                guard let self, ticket == id, !Task.isCancelled else { return }
                failedPack = dir; prepared?.1.cancel(); prepared = nil; player.stop(); usingSystem = true
                do { try system.speak(text, multiplier: multiplier, started: started, ended: ended) }
                catch { ended(false) }
            }
        }
    }
    func silence() {
        ticket = UUID(); current?.cancel(); current = nil; prepared?.1.cancel(); prepared = nil
        if usingSystem { system.silence(); usingSystem = false }; player.stop(); failedPack = nil
        if usedRenderer { usedRenderer = false; release = Task { [releaseRenderer] in await releaseRenderer() } }
    }
}

import Foundation
@_implementationOnly import CKokoro

struct KokoroPCM: Sendable {
    let samples: [Float]
    let sampleRate: Int
}

enum KokoroRenderError: Error {
    case invalidText, invalidSpeed, invalidPack, initializationFailed, generationFailed
}

/// Keep one renderer in the reading service. Native pointers never leave its executor.
actor KokoroRenderer {
    private var instance: Instance?

    func render(text: String, speed: Float, directory: URL) throws -> KokoroPCM {
        // The two reader cursors cap at 256 / 280 UTF-16 units, not UTF-8 bytes.
        guard text.utf16.count <= 280, text.utf8.count <= 840, !text.utf8.contains(0),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KokoroRenderError.invalidText
        }
        guard speed.isFinite, (0.5...2).contains(speed) else { throw KokoroRenderError.invalidSpeed }
        try Task.checkCancellation()
        guard directory.isFileURL else { throw KokoroRenderError.invalidPack }
        let root = directory.standardizedFileURL
        if instance?.directory != root {
            reset() // Never keep two models resident while switching packs.
            instance = try Instance(directory: root)
        }
        guard let instance else { throw KokoroRenderError.initializationFailed }
        try Task.checkCancellation()
        var view = YJKokoroView()
        guard let owner = YJKokoroGenerate(instance.handle, text, speed, &view) else {
            throw KokoroRenderError.generationFailed
        }
        defer { YJKokoroFreeAudio(owner) }
        try Task.checkCancellation()
        guard let base = view.samples else { throw KokoroRenderError.generationFailed }
        let samples = try UnsafeBufferPointer(start: base, count: Int(view.count)).map { value in
            guard value.isFinite else { throw KokoroRenderError.generationFailed }
            return min(1, max(-1, value))
        }
        return KokoroPCM(samples: samples, sampleRate: Int(view.sampleRate))
    }

    func reset() { instance = nil }

    // Non-Sendable RAII owner, used synchronously on this actor only.
    private final class Instance {
        let handle: OpaquePointer
        let directory: URL

        init(directory: URL) throws {
            let root = directory.path
            guard directory.lastPathComponent == "kokoro-int8-multi-lang-v1_1",
                  !root.contains(","), !root.utf8.contains(0) else { throw KokoroRenderError.invalidPack }
            // The installer authenticates the whole archive. Preflight accidental partial
            // installs before passing paths to native code (not a parser for untrusted ONNX).
            func size(_ name: String) -> Int? {
                let url = directory.appendingPathComponent(name)
                guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      v.isRegularFile == true else { return nil }
                return v.fileSize
            }
            guard let model = ["model.int8.onnx", "model.onnx"].first(where: { size($0) == 114_203_914 }),
                  size("voices.bin") == 53_790_720, size("tokens.txt") == 1_111,
                  size("lexicon-zh.txt") == 2_120_131, size("lexicon-us-en.txt") == 5_956_885,
                  size("phone-zh.fst") == 88_630, size("date-zh.fst") == 59_154,
                  size("number-zh.fst") == 64_482,
                  ["phontab", "phonindex", "phondata", "intonations"].allSatisfy({
                      (size("espeak-ng-data/" + $0) ?? 0) > 0
                  }) else { throw KokoroRenderError.invalidPack }
            guard let handle = YJKokoroOpen(root, model) else { throw KokoroRenderError.initializationFailed }
            self.handle = handle
            self.directory = directory
        }

        deinit { YJKokoroClose(handle) }
    }
}

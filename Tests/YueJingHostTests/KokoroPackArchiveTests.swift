import AVFAudio
import Foundation
import Testing
@testable import YueJing

struct KokoroPackArchiveTests {
    @Test func wrongLengthAndWrongDigestLeavePriorInstallationUntouched() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("private", isDirectory: true)
        let source = base.appendingPathComponent("folder", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: source.appendingPathComponent("model"))
        let index = try KokoroPackIndex(text: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad 3 model")
        let disk = KokoroPackDisk(root: root, index: index)
        let live = try await disk.install(from: source)
        let downloaded = base.appendingPathComponent("download")
        try Data().write(to: downloaded)

        #expect(KokoroPackArchive.compressedBytes == 147_052_523)
        #expect(KokoroPackIndex.archiveSHA256 == "259c9c8bc906d6078e4e0570421885dabb68b539c2f970fcbb890a58eeaf3e9c")
        await #expect(throws: KokoroPackArchive.PinError.size) { _ = try await disk.installArchive(from: downloaded) }
        // Right length, wrong SHA. A decoder error here would not satisfy this assertion.
        let file = try FileHandle(forWritingTo: downloaded)
        try file.truncate(atOffset: 147_052_523)
        try file.close()
        await #expect(throws: KokoroPackArchive.PinError.digest) { _ = try await disk.installArchive(from: downloaded) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await disk.installArchive(from: downloaded)
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        // Check before restore, which itself scavenges abandoned stages.
        #expect(try fm.contentsOfDirectory(atPath: root.path) == [live.lastPathComponent])
        #expect(try Data(contentsOf: live.appendingPathComponent("model")) == Data("abc".utf8))
        let restored = try await disk.restore()
        #expect(restored == live)
    }

    @Test
    func officialArchiveAtomicallyReplacesDirectoryWithOnlyIndexedMembers() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: base) }
        let archive: URL
        if let path = ProcessInfo.processInfo.environment["KOKORO_TEST_ARCHIVE"], !path.isEmpty {
            archive = URL(fileURLWithPath: path)
        } else {
            archive = base.appendingPathComponent("official.tar.bz2")
            try await KokoroPackDownload(progress: { _ in }).fetch(to: archive)
        }
        let root = base.appendingPathComponent("install", isDirectory: true)
        let prior = root.appendingPathComponent(KokoroPackIndex.rootName, isDirectory: true)
        try fm.createDirectory(at: prior, withIntermediateDirectories: true)
        try Data().write(to: prior.appendingPathComponent("prior"))
        let disk = KokoroPackDisk(root: root)
        let live = try await disk.installArchive(from: archive)
        #expect(prior == live)
        let members = try KokoroPackIndex.official().members
        var expected = Set<String>()
        for member in members {
            var parts = member.path.split(separator: "/")[...]
            while !parts.isEmpty {
                expected.insert(parts.joined(separator: "/"))
                parts = parts.dropLast()
            }
        }
        let actual = try fm.subpathsOfDirectory(atPath: live.path)
        #expect(Set(actual) == expected) // Includes dirs; rejects leftover script, temp file or prior marker.
        #expect(try fm.contentsOfDirectory(atPath: root.path) == [live.lastPathComponent])
        let flags = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(flags.isExcludedFromBackup == true)
        let restored = try await disk.restore() // Independent per-file size and SHA check of installed bytes.
        #expect(restored == live)

        let pcm = try await KokoroRenderer().render(text: "今天是晴天。", speed: 1, directory: live)
        let count = pcm.samples.count
        let allFinite = pcm.samples.allSatisfy(\.isFinite)
        let nonSilent = pcm.samples.contains { abs($0) > 0.0001 } // Above 16-bit WAV quantization noise.
        #expect(pcm.sampleRate == 24_000)
        #expect(count > 0)
        #expect(allFinite)
        #expect(nonSilent)

        // Validate the playback format in memory without playing or saving the utterance.
        let wave = try await KokoroWave.encode(pcm)
        let audio = try AVAudioPlayer(data: wave)
        #expect(audio.numberOfChannels == 1)
        #expect(audio.format.sampleRate == 24_000)
        #expect(abs(audio.duration - Double(count) / 24_000) <= 1.0 / 24_000)
    }
}

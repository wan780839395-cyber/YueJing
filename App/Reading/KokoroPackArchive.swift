@_implementationOnly import CKokoroBZip
import CryptoKit
import Darwin
import Foundation

/// Decoder for this one pinned release, not a general tar importer.
enum KokoroPackArchive {
    enum PinError: Error { case size, digest }
    static let compressedBytes = 147_052_523
    private static let chunkSize = 256 * 1024

    static func extract(_ source: URL, to stage: URL, index: KokoroPackIndex) throws {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw KokoroPackError.invalid }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_nlink == 1 else { throw KokoroPackError.invalid }
        guard info.st_size == Int64(compressedBytes) else { throw PinError.size }

        // Hash into an unlinked private snapshot. Never reopen a pathname or feed a
        // mutable download to the decoder after verifying different bytes.
        let path = stage.appendingPathComponent(".archive").path
        let tmp = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard tmp >= 0 else { throw KokoroPackError.storage }
        let snapshot = FileHandle(fileDescriptor: tmp, closeOnDealloc: true)
        defer { try? snapshot.close() }
        guard unlink(path) == 0 else { throw KokoroPackError.storage }
        var remaining = compressedBytes
        var sha = SHA256()
        while remaining > 0 {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let data = try input.read(upToCount: min(chunkSize, remaining)), !data.isEmpty,
                      data.count <= remaining else { throw PinError.size }
                sha.update(data: data)
                try snapshot.write(contentsOf: data)
                remaining -= data.count
            }
        }
        guard (try input.read(upToCount: 1))?.isEmpty != false else { throw PinError.size }
        guard KokoroPackIndex.hex(sha.finalize()) == KokoroPackIndex.archiveSHA256 else { throw PinError.digest }
        try Task.checkCancellation()
        try snapshot.seek(toOffset: 0)
        guard let stream = kokoro_bzip_open(tmp) else { throw KokoroPackError.invalid }
        defer { kokoro_bzip_close(stream) }
        let tar = Tar(stream: stream)
        try tar.unpack(to: stage, index: index)
    }

    private final class Tar {
        let stream: OpaquePointer
        var remaining = 215_562_240 // Complete GNU tar, including headers and final record padding.
        init(stream: OpaquePointer) { self.stream = stream }

        func read(_ count: Int) throws -> Data {
            try Task.checkCancellation()
            guard count >= 0, count <= chunkSize, count <= remaining else { throw KokoroPackError.invalid }
            if count == 0 { return Data() }
            var data = Data(count: count)
            let n = data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
                kokoro_bzip_read(stream, buf.baseAddress, Int32(count))
            }
            guard n == Int32(count) else { throw KokoroPackError.invalid }
            remaining -= count
            return data
        }

        func unpack(to stage: URL, index: KokoroPackIndex) throws {
            let prefix = KokoroPackIndex.rootName + "/"
            var files = [String: KokoroPackIndex.Member]()
            var directories: Set<String> = [prefix]
            for member in index.members {
                files[prefix + member.path] = member
                var parent = prefix
                for component in member.path.split(separator: "/").dropLast() {
                    parent += String(component) + "/"
                    directories.insert(parent)
                }
            }
            guard files.count == 376 else { throw KokoroPackError.invalid }
            var sawHelper = false
            while true {
                let header = try read(512)
                if header.allSatisfy({ $0 == 0 }) { break }
                let (name, type, size) = try Self.parse(Array(header))
                switch type {
                case 53: // '5': only exact ancestor directories; never apply archive metadata.
                    guard size == 0, directories.remove(name) != nil else { throw KokoroPackError.invalid }
                case 48: // '0': regular file
                    if name == prefix + "dict/generate_user_dict.py" {
                        guard !sawHelper, size == 545 else { throw KokoroPackError.invalid }
                        sawHelper = true
                        _ = try read(size) // The official tar contains this helper. Never materialize it.
                    } else {
                        guard let member = files.removeValue(forKey: name), size == member.bytes else {
                            throw KokoroPackError.invalid
                        }
                        try write(member, to: stage.appendingPathComponent(member.path))
                    }
                    guard try read((512 - size % 512) % 512).allSatisfy({ $0 == 0 }) else { throw KokoroPackError.invalid }
                default: throw KokoroPackError.invalid // Includes links, devices, GNU long names and PAX overrides.
                }
            }
            // Exactly 16 zero blocks in this release. Require both tar and bzip2 EOF.
            guard files.isEmpty, directories.isEmpty, sawHelper, remaining == 15 * 512,
                  try read(remaining).allSatisfy({ $0 == 0 }) else { throw KokoroPackError.invalid }
            var extra: UInt8 = 0
            guard kokoro_bzip_read(stream, &extra, 1) == 0 else { throw KokoroPackError.invalid }
        }

        private func write(_ member: KokoroPackIndex.Member, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw KokoroPackError.storage }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var left = member.bytes
            var sha = SHA256()
            while left > 0 {
                try autoreleasepool {
                    let data = try read(min(left, chunkSize))
                    sha.update(data: data)
                    try output.write(contentsOf: data)
                    left -= data.count
                }
            }
            try output.close()
            guard KokoroPackIndex.hex(sha.finalize()) == member.digest else { throw KokoroPackError.invalid }
        }

        // Old GNU header: fixed width, NUL-terminated short ASCII name and octal fields.
        // Reject prefix/sparse/extended metadata rather than interpreting another dialect.
        private static func parse(_ h: [UInt8]) throws -> (String, UInt8, Int) {
            guard h.count == 512, h[257..<265].elementsEqual("ustar  \0".utf8),
                  h[157..<257].allSatisfy({ $0 == 0 }), h[345...].allSatisfy({ $0 == 0 }),
                  let end = h[..<100].firstIndex(of: 0), end > 0,
                  h[..<end].allSatisfy({ (32...126).contains($0) }), h[end..<100].allSatisfy({ $0 == 0 }),
                  h[135] == 0, h[154] == 0, h[155] == 32 else { throw KokoroPackError.invalid }
            let checksum = h[..<148].reduce(8 * 32) { $0 + Int($1) } + h[156...].reduce(0) { $0 + Int($1) }
            guard try octal(h[148..<154]) == checksum else { throw KokoroPackError.invalid }
            return (String(decoding: h[..<end], as: UTF8.self), h[156], try octal(h[124..<135]))
        }

        private static func octal(_ field: ArraySlice<UInt8>) throws -> Int {
            // At most eleven octal digits (33 bits); iOS targets are 64-bit.
            guard field.count <= 11, field.allSatisfy({ (48...55).contains($0) }) else { throw KokoroPackError.invalid }
            return field.reduce(0) { $0 * 8 + Int($1 - 48) }
        }
    }
}

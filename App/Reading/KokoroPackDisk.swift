import CryptoKit
import Darwin
import Foundation

/// All disk operations are synchronous on this actor, including the commit point.
/// No task can observe or reuse another installation's staging directory.
actor KokoroPackDisk {
    private let root: URL
    private let testIndex: KokoroPackIndex?
    private let fm = FileManager.default
    private var live: URL { root.appendingPathComponent(KokoroPackIndex.rootName, isDirectory: true) }
    private var staging: URL { root.appendingPathComponent(".staging", isDirectory: true) }

    init(root: URL, index: KokoroPackIndex? = nil) {
        self.root = root
        self.testIndex = index
    }

    func restore() throws -> URL? {
        guard fm.fileExists(atPath: root.path) else { return nil }
        try? clearStaging() // Failed reclamation must not hide a valid live install.
        guard fm.fileExists(atPath: live.path) else { return nil }
        try Self.transfer(from: live, to: nil, index: testIndex ?? KokoroPackIndex.official())
        return live
    }

    func install(from source: URL) throws -> URL {
        try Task.checkCancellation()
        try Self.requireLocal(source)
        let index = try testIndex ?? KokoroPackIndex.official()
        return try stagedInstall { try Self.coordinatedCopy(from: source, to: $0, index: index) }
    }

    func installArchive(from url: URL) throws -> URL {
        try Task.checkCancellation()
        try Self.requireLocal(url)
        let index = try KokoroPackIndex.official()
        return try stagedInstall { try KokoroPackArchive.extract(url, to: $0, index: index) }
    }

    private func stagedInstall(populate: (URL) throws -> Void) throws -> URL {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var privateRoot = root
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try privateRoot.setResourceValues(flags)
        try clearStaging()
        let stage = staging
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }

        try populate(stage)
        try Task.checkCancellation()
        if fm.fileExists(atPath: live.path) {
            // Same APFS volume. A failed exchange leaves both names unchanged;
            // a successful exchange leaves the old pack under the disposable name.
            guard renamex_np(stage.path, live.path, UInt32(RENAME_SWAP)) == 0 else { throw KokoroPackError.storage }
        } else {
            guard rename(stage.path, live.path) == 0 else { throw KokoroPackError.storage }
        }
        return live
    }

    func remove() throws {
        try Task.checkCancellation()
        try clearStaging()
        guard fm.fileExists(atPath: live.path) else { return }
        guard rename(live.path, staging.path) == 0 else { throw KokoroPackError.storage }
        // Already uninstalled. Retry any interrupted reclamation on next launch.
        try? fm.removeItem(at: staging)
    }

    private func clearStaging() throws {
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
    }

    private static func requireLocal(_ url: URL) throws {
        guard url.isFileURL, (url.host ?? "").isEmpty || url.host == "localhost",
              url.path.hasPrefix("/"), !url.path.utf8.contains(0),
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw KokoroPackError.invalid }
    }

    private static func coordinatedCopy(from source: URL, to stage: URL, index: KokoroPackIndex) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        // Reject a selected symlink before coordination can resolve it.
        _ = try physicalFolder(source)
        var result: Result<Void, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { url in
            result = Result { try transfer(from: url, to: stage, index: index) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw KokoroPackError.invalid }
        try result.get()
    }

    /// Canonicalize the picker-authorized directory, not its (possibly inaccessible)
    /// parent. Bind the physical name to the directory opened without following links.
    private static func physicalFolder(_ url: URL) throws -> String {
        try requireLocal(url)
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw KokoroPackError.invalid }
        defer { _ = close(fd) }
        guard let physical = realpath(path, nil) else { throw KokoroPackError.invalid }
        defer { free(physical) }
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, lstat(physical, &named) == 0,
              opened.st_ino == named.st_ino, opened.st_dev == named.st_dev else { throw KokoroPackError.invalid }
        return String(cString: physical)
    }

    private static func transfer(from source: URL, to stage: URL?, index: KokoroPackIndex) throws {
        let folder = try physicalFolder(source)
        // Open only compiled-in names. Never enumerate, copy metadata, or execute
        // anything supplied by the picker, including manifests and helper scripts.
        for member in index.members {
            try Task.checkCancellation()
            try autoreleasepool {
                try copyMember(member, path: folder + "/" + member.path, to: stage?.appendingPathComponent(member.path))
            }
        }
    }

    private static func copyMember(_ member: KokoroPackIndex.Member, path: String, to target: URL?) throws {
        // O_NOFOLLOW_ANY checks every component during the actual open, not just
        // the leaf at preflight. NONBLOCK prevents a substituted FIFO from hanging.
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else { throw KokoroPackError.invalid }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_nlink == 1, info.st_size == Int64(member.bytes) else { throw KokoroPackError.invalid }

        let output: FileHandle?
        if let target {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let outFD = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
            guard outFD >= 0 else { throw KokoroPackError.storage }
            output = FileHandle(fileDescriptor: outFD, closeOnDealloc: true)
        } else {
            output = nil
        }
        var hash = SHA256()
        var remaining = member.bytes
        while remaining > 0 {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let data = try input.read(upToCount: min(256 * 1024, remaining)), !data.isEmpty else {
                    throw KokoroPackError.invalid
                }
                hash.update(data: data)
                try output?.write(contentsOf: data)
                remaining -= data.count
            }
        }
        try output?.close()
        guard (try input.read(upToCount: 1))?.isEmpty != false,
              KokoroPackIndex.hex(hash.finalize()) == member.digest else { throw KokoroPackError.invalid }
    }
}

import Darwin
import Foundation

public struct EPUBUserFont: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let mediaType: String
}

/// A single immutable file per lowercase SHA-256. Derive metadata from verified bytes
/// on reopen, so there is no index/blob pair that could be partially committed.
public actor EPUBUserFontStore {
    public static let shared = EPUBUserFontStore(root: URL.applicationSupportDirectory
        .appendingPathComponent("EPUBUserFonts", isDirectory: true))

    private let root: URL
    private static let maxFonts = 512 // Bound metadata/work even for tiny fonts.
    public static let maxFontMiB = 16
    public static let maxFontBytes = maxFontMiB * 1024 * 1024

    init(root: URL) { self.root = root }

    public func list() throws -> [EPUBUserFont] {
        try withLibrary { try inventory().fonts.sorted { $0.id < $1.id } }
    }

    public func importFont(from source: URL) throws -> EPUBUserFont {
        try Self.requireLocalURL(source)
        let ext = source.pathExtension.lowercased()
        guard ext == "ttf" || ext == "otf" else { throw EPUBError.unsupportedContent }
        let bytes = try Self.coordinatedRead(source)
        let font = try Self.describe(bytes)
        guard font.mediaType == "font/" + ext else { throw EPUBError.unsupportedContent }

        return try withLibrary {
            let current = try inventory()
            if let existing = current.fonts.first(where: { $0.id == font.id }) { return existing }
            guard current.fonts.count < Self.maxFonts,
                  bytes.count <= EPUBAuthorStyles.maxTotalFontBytes - current.bytes else {
                throw EPUBError.limitExceeded
            }
            try bytes.write(to: root.appendingPathComponent(font.id), options: .atomic)
            return font
        }
    }

    /// Only accept library identities, never a picker URL. unlink is non-recursive.
    public func removeFont(id: String) throws {
        guard Self.isID(id) else { throw EPUBError.unsafePath }
        try withLibrary {
            _ = try stored(id) // no-follow regular file, valid SFNT and matching digest
            guard unlink(root.appendingPathComponent(id).path) == 0 else { throw Self.posixError() }
        }
    }

    public func data(for id: String) throws -> Data {
        guard Self.isID(id) else { throw EPUBError.unsafePath }
        return try withLibrary { try stored(id).bytes }
    }

    private static func isID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func describe(_ bytes: Data) throws -> EPUBUserFont {
        // The validator returns the canonical type from the SFNT, not the hint.
        let type = try EPUBAuthorStyles.verifyFontData(bytes, declaredMediaType: "font/ttf", maximumBytes: maxFontBytes)
        let id = EPUBResourceStore.digest(bytes)
        let names = EPUBFontIdentity.extract(fromValidatedSFNT: bytes, maximumBytes: maxFontBytes)
        let name = names?.fullName ?? names?.family ?? names?.postScriptName ?? "Font \(id.prefix(12))"
        return EPUBUserFont(id: id, displayName: name, mediaType: type)
    }

    private func stored(_ id: String) throws -> (font: EPUBUserFont, bytes: Data) {
        let bytes = try Self.readRegular(root.appendingPathComponent(id))
        let font = try Self.describe(bytes)
        guard font.id == id else { throw EPUBError.corruptResource }
        return (font, bytes)
    }

    private func inventory() throws -> (fonts: [EPUBUserFont], bytes: Int) {
        let ids = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard ids.count <= Self.maxFonts else { throw EPUBError.limitExceeded }
        var fonts: [EPUBUserFont] = [], total = 0
        for id in ids {
            guard Self.isID(id) else { throw EPUBError.corruptResource }
            let record = try stored(id)
            guard record.bytes.count <= EPUBAuthorStyles.maxTotalFontBytes - total else {
                throw EPUBError.limitExceeded
            }
            total += record.bytes.count
            fonts.append(record.font)
        }
        return (fonts, total)
    }

    /// Serialize quota check + publish even across two stores opened on the same root.
    private static let libraryLock = NSLock()

    private func withLibrary<T>(_ body: () throws -> T) throws -> T {
        try Self.requireLocalURL(root)
        Self.libraryLock.lock()
        defer { Self.libraryLock.unlock() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var info = stat()
        guard lstat(root.path, &info) == 0 else { throw Self.posixError() }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw EPUBError.unsafePath }
        return try body()
    }

    private static func requireLocalURL(_ url: URL) throws {
        guard url.isFileURL, (url.host ?? "").isEmpty || url.host?.lowercased() == "localhost",
              url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw EPUBError.unsafePath }
    }

    private static func coordinatedRead(_ source: URL) throws -> Data {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        // Refuse a link even if the coordinator were to return its resolved URL.
        var metadata = stat()
        guard lstat(source.path, &metadata) == 0 else { throw posixError() }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw EPUBError.unsafePath }
        var result: Result<Data, Error>?, coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { url in
            result = Result { try readRegular(url) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw EPUBError.corruptResource }
        return try result.get()
    }

    private static func readRegular(_ url: URL) throws -> Data {
        try requireLocalURL(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size > 0 else { throw EPUBError.corruptResource }
        guard info.st_size <= Int64(maxFontBytes) else { throw EPUBError.limitExceeded }
        // Size is only a preflight: bound every actual read and probe one byte for growth.
        let expected = Int(info.st_size)
        var bytes = Data()
        bytes.reserveCapacity(expected)
        while bytes.count < expected {
            let size = min(64 * 1024, expected - bytes.count)
            guard let chunk = try handle.read(upToCount: size), !chunk.isEmpty else { throw EPUBError.corruptResource }
            bytes.append(chunk)
        }
        guard (try handle.read(upToCount: 1))?.isEmpty != false else { throw EPUBError.corruptResource }
        return bytes
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

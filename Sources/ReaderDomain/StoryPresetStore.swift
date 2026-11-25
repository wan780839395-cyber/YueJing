import Foundation
import GRDB

public enum StoryPresetStorageError: Error, LocalizedError {
    case invalidFile, tooLarge, unavailable, blocked, storage
    public var errorDescription: String? {
        switch self {
        case .invalidFile: return "请选择可读取的 JSON 文件，不要选择目录或链接。"
        case .tooLarge: return "预设超过 2 MiB，未导入。"
        case .unavailable: return "找不到这个预设版本。"
        case .blocked: return "这个预设有未支持的设置，不能用于新故事。"
        case .storage: return "预设未能读取或保存，请重试。"
        }
    }
}

extension LibraryService {
    /// Read only a user-picked local/provider file; no bookmarks, logs, raw payload storage or networking.
    public func importStoryPreset(from url: URL) async throws -> StoryPresetVersion {
        guard url.isFileURL, url.pathExtension.lowercased() == "json" else { throw StoryPresetStorageError.invalidFile }
        let bytes = try Self.readPresetFile(url)
        try Task.checkCancellation()
        let version = try StoryPresetParser.parse(bytes, fallbackName: url.deletingPathExtension().lastPathComponent)
        return try await store.saveStoryPreset(version)
    }

    private static func readPresetFile(_ url: URL) throws -> Data {
        let limit = 2 * 1024 * 1024
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        func check(_ file: URL) throws {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw StoryPresetStorageError.invalidFile }
            if let size = info.fileSize, size > limit { throw StoryPresetStorageError.tooLarge }
        }
        do {
            try check(url)
            var coordinationError: NSError?
            var result: Result<Data, Error> = .failure(StoryPresetStorageError.invalidFile)
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { local in
                result = Result {
                    try check(local)
                    let handle = try FileHandle(forReadingFrom: local)
                    defer { try? handle.close() }
                    var data = Data()
                    while let part = try handle.read(upToCount: min(65536, limit + 1 - data.count)), !part.isEmpty {
                        try Task.checkCancellation()
                        data.append(part)
                        guard data.count <= limit else { throw StoryPresetStorageError.tooLarge }
                    }
                    return data
                }
            }
            guard coordinationError == nil else { throw StoryPresetStorageError.invalidFile }
            return try result.get()
        } catch is CancellationError { throw CancellationError() }
        catch let e as StoryPresetStorageError { throw e }
        catch { throw StoryPresetStorageError.invalidFile }
    }
}

enum StoryPresetRows {
    static func list(_ db: Database) throws -> [StoryPresetSummary] {
        try Row.fetchAll(db, sql: "SELECT id,name,canSelect FROM storyPresetVersions ORDER BY importedAt DESC,id").map {
            StoryPresetSummary(id: $0["id"], name: $0["name"], canSelect: $0["canSelect"])
        }
    }

    static func read(_ id: String, in db: Database) throws -> StoryPresetVersion {
        guard let data = try Data.fetchOne(db, sql: "SELECT snapshot FROM storyPresetVersions WHERE id=?", arguments: [id]) else {
            throw StoryPresetStorageError.unavailable
        }
        let value = try JSONDecoder().decode(StoryPresetVersion.self, from: data)
        guard value.summary.id == id, value.summary.canSelect == value.issues.isEmpty else { throw StoryPresetStorageError.storage }
        return value
    }

    static func insert(_ value: StoryPresetVersion, in db: Database) throws -> StoryPresetVersion {
        try Task.checkCancellation()
        let s = value.summary
        let encoded = try JSONEncoder().encode(value)
        try db.execute(sql: """
            INSERT INTO storyPresetVersions(id,name,canSelect,snapshot,importedAt) VALUES(?,?,?,?,?)
            ON CONFLICT(id) DO NOTHING
            """, arguments: [s.id, s.name, s.canSelect, encoded, Date().timeIntervalSinceReferenceDate])
        let stored = try read(s.id, in: db)
        try Task.checkCancellation()
        return stored
    }

    static func bind(_ id: String, session: UUID, in db: Database) throws {
        try db.execute(sql: """
            UPDATE storySessions SET presetID=? WHERE id=? AND presetID IS NULL
                AND EXISTS(SELECT 1 FROM storyPresetVersions WHERE id=? AND canSelect=1)
            """, arguments: [id, session.uuidString, id])
        guard db.changesCount == 1 else { throw StoryPresetStorageError.blocked }
    }

    static func protect<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch is CancellationError { throw CancellationError() }
        catch let error as StoryPresetStorageError { throw error }
        catch { throw StoryPresetStorageError.storage }
    }
}

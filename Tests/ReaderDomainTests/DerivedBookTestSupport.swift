import CoreFoundation
import Foundation
import GRDB
import Testing
import TXTCore
@testable import ReaderDomain

struct DerivedBookFixture: Sendable {
    let root: URL
    let managed: URL
    let store: LibraryStore
    let service: LibraryService
    let document: TXTDocument
    let chapters: [TXTChapter]
    let book: LibraryBook
    let budget: DerivedBookBudget

    static func limits(read: Int = 16384, chapters: Int = 32, artifact: Int = 4 * 1024 * 1024) throws -> DerivedBookBudget {
        try DerivedBookBudget(maximumArtifactBytes: artifact, maximumStoredBytes: 32 * 1024 * 1024,
            maximumMetadataBytes: 256 * 1024, maximumWorkingBytes: 4 * 1024 * 1024,
            maximumReadUTF16: read, maximumChapterEntries: chapters)
    }
    static func bytes(_ text: String, encoding: TXTEncoding, bom: Bool = false) throws -> Data {
        let converter: String.Encoding
        let prefix: [UInt8]
        switch encoding {
        case .utf8: converter = .utf8; prefix = bom ? [0xEF, 0xBB, 0xBF] : []
        case .utf16LE: converter = .utf16LittleEndian; prefix = bom ? [0xFF, 0xFE] : []
        case .utf16BE: converter = .utf16BigEndian; prefix = bom ? [0xFE, 0xFF] : []
        case .gbk:
            converter = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosChineseSimplif.rawValue)))
            prefix = []
        case .gb18030: converter = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0632)); prefix = []
        }
        return Data(prefix) + (try #require(text.data(using: converter, allowLossyConversion: false)))
    }
    init(bytes: Data? = nil, encoding: TXTEncoding = .utf8) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("YueJing-derived-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        managed = root.appendingPathComponent("Managed", isDirectory: true)
        store = try LibraryStore(root: managed); service = LibraryService(store: store)
        budget = try Self.limits()
        let data = bytes ?? Data("第一章 起点\r\nabc😀e\u{301}\r\n第二章 终点\r\n中文\r".utf8)
        document = try await TXTProcessor().decode(data, using: encoding)
        chapters = try await TXTProcessor().chapters(in: document)
        let proposed = LibraryBook(id: document.documentID, title: "派生合成回归", encodingRaw: encoding.rawValue,
            versionID: document.versionID, byteCount: data.count, utf16Count: document.utf16Count)
        let ticket = UUID(); try await store.beginImport(ticket)
        try data.write(to: await store.stagingURL(ticket: ticket))
        book = try await store.commitImport(ticket: ticket, proposed: proposed).book
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func artifact() async throws -> (URL, DerivedPointer) {
        let lease = try await store.leaseDerived(bookID: book.id)
        let url = try await store.derivedFileURL(lease)
        await store.releaseDerivedLease(lease); return (url, lease.pointer)
    }
    func changeByte(section: Int?, at relative: Int = 0) async throws {
        let (url, _) = try await artifact()
        let handle = try FileHandle(forUpdating: url); defer { try? handle.close() }
        let header = try DerivedBookFormat.read(handle, offset: 0, count: 4096, maximumBytes: 4096)
        let size = try DerivedBookFormat.int(header, at: 8)
        let manifest = try JSONDecoder().decode(DerivedManifest.self, from: header.subdata(in: 16..<(16 + size)))
        let offset = try section.map { try DerivedBookFormat.add(4096, DerivedBookFormat.integer(manifest.sections[$0].offset)) } ?? 0
        let data = try DerivedBookFormat.read(handle, offset: offset + relative, count: 1, maximumBytes: 1)
        try handle.seek(toOffset: UInt64(offset + relative)); try handle.write(contentsOf: Data([data[0] ^ 1]))
    }
    /// Tests malicious authenticated metadata, rather than merely tripping the outer digest.
    func rewriteHeader(_ mutate: (inout [String: Any]) throws -> Void) async throws {
        let (url, pointer) = try await artifact()
        let handle = try FileHandle(forUpdating: url); defer { try? handle.close() }
        let header = try DerivedBookFormat.read(handle, offset: 0, count: 4096, maximumBytes: 4096)
        let size = try DerivedBookFormat.int(header, at: 8)
        var object = try #require(JSONSerialization.jsonObject(with: header.subdata(in: 16..<(16 + size))) as? [String: Any])
        try mutate(&object)
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var output = DerivedBookFormat.magic; DerivedBookFormat.append(UInt64(json.count), to: &output); output.append(json)
        guard output.count <= 4096 else { throw DerivedStorageError.budgetExceeded }
        output.append(Data(repeating: 0, count: 4096 - output.count))
        try handle.seek(toOffset: 0); try handle.write(contentsOf: output); try handle.synchronize()
        let queue = try DatabaseQueue(path: managed.appendingPathComponent("library.sqlite").path)
        let digest = DerivedBookFormat.digest(output)
        try await queue.write { db in
            try db.execute(sql: "UPDATE derivedArtifacts SET manifestSHA256 = ? WHERE bookID = ? AND generation = ?",
                           arguments: [digest, pointer.bookID, pointer.generation])
        }
    }
    func savedAnchor() async throws -> ReadingAnchor {
        let reading = try await store.beginReading(bookID: book.id, versionID: book.versionID)
        let boundary = try document.offsets.rawByteOffset(for: UTF16Offset(0)).value
        let anchor = ReadingAnchor(bookID: book.id, versionID: book.versionID, rawByteOffset: boundary, lineFraction: 0.3)
        try await store.finishReading(session: reading.session, anchor: anchor, sequence: 1)
        return anchor
    }
}

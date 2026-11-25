import CryptoKit
import Foundation
import TXTCore

extension LibraryService {
    /// No reading lease or progress writes. Read from the managed catalog, not the Files URL.
    public func storyOpening(for requested: LibraryBook) async throws -> String {
        try Task.checkCancellation()
        guard let book = try await store.book(id: requested.id), book.versionID == requested.versionID,
              book.format == requested.format, book.addedAt == requested.addedAt else { throw LibraryError.missingBook }
        switch book.format {
        case .epub:
            let url = try await store.epubFileURL(bookID: book.id)
            guard try EPUBResourceStore.sourceDigest(url) == book.id else { throw LibraryError.changedFile }
            let snapshot = try await store.storedEPUBSnapshot(bookID: book.id)
            guard snapshot.package.versionID == book.versionID else { throw LibraryError.changedFile }
            return try StoryOpeningText.from(package: snapshot.package)
        case .txt:
            guard let encoding = book.encoding else { throw LibraryError.invalidEncoding }
            let url = try await store.fileURL(bookID: book.id)
            let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, attrs.fileSize == book.byteCount else {
                throw LibraryError.changedFile
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var digest = SHA256(), prefix = Data(), count = 0
            let limit = 64 * 1024
            while let chunk = try file.read(upToCount: limit), !chunk.isEmpty {
                try Task.checkCancellation()
                guard chunk.count <= book.byteCount - count else { throw LibraryError.changedFile }
                count += chunk.count
                digest.update(data: chunk)
                prefix.append(contentsOf: chunk.prefix(limit - prefix.count))
            }
            guard count == book.byteCount, digest.finalize().map({ String(format: "%02x", $0) }).joined() == book.id else {
                throw LibraryError.changedFile
            }
            let decoder = TXTProcessor()
            // A verified file may be cut inside a 2–4 byte scalar. Only trim an artificial trailing boundary.
            let trimLimit = count > prefix.count ? 3 : 0
            for trim in 0...trimLimit {
                try Task.checkCancellation()
                do {
                    let document = try await decoder.decode(Data(prefix.dropLast(trim)), using: encoding)
                    let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { return StoryOpeningText.from(text: text) }
                    break
                } catch TXTError.malformedInput(_, let offset) where trim < trimLimit && offset.value >= prefix.count - trim - 4 {
                    continue
                }
            }
        }
        throw StoryLaunchError.missingOpening
    }
}

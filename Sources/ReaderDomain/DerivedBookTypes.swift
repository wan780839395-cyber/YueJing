import Foundation
import TXTCore

public enum DerivedStorageError: Error, Equatable, Sendable {
    case missingArtifact, corruptArtifact, incompatibleFormat, versionMismatch
    case budgetExceeded, staleBuild, closed
}

/// Admission and logical working-set budgets, never an RSS promise. No implicit book-size limit.
public struct DerivedBookBudget: Sendable {
    public let maximumArtifactBytes: Int
    public let maximumStoredBytes: Int
    public let maximumMetadataBytes: Int
    public let maximumWorkingBytes: Int
    public let maximumReadUTF16: Int
    public let maximumChapterEntries: Int

    public init(maximumArtifactBytes: Int, maximumStoredBytes: Int, maximumMetadataBytes: Int,
                maximumWorkingBytes: Int, maximumReadUTF16: Int, maximumChapterEntries: Int) throws {
        guard maximumArtifactBytes >= 4096, maximumStoredBytes >= maximumArtifactBytes,
              maximumMetadataBytes >= 4096, maximumWorkingBytes >= 131072,
              maximumMetadataBytes <= maximumWorkingBytes / 2,
              maximumReadUTF16 > 0, maximumReadUTF16 <= maximumWorkingBytes / 16,
              maximumChapterEntries > 0, maximumChapterEntries <= maximumWorkingBytes / 1024 else {
            throw DerivedStorageError.budgetExceeded
        }
        self.maximumArtifactBytes = maximumArtifactBytes; self.maximumStoredBytes = maximumStoredBytes
        self.maximumMetadataBytes = maximumMetadataBytes; self.maximumWorkingBytes = maximumWorkingBytes
        self.maximumReadUTF16 = maximumReadUTF16; self.maximumChapterEntries = maximumChapterEntries
    }
}

public struct DerivedBookMetadata: Sendable {
    public let bookID: String
    public let versionID: String
    public let encoding: TXTEncoding
    public let bomByteCount: Int
    public let byteCount: Int
    public let utf16Count: Int
    public let chapterCount: Int
}

public struct DerivedTextFragment: Sendable {
    public let text: String
    public let range: UTF16Range
    public let rawRange: RawByteRange
}

struct DerivedPointer: Sendable, Equatable {
    let bookID: String
    let versionID: String
    let generation: String
    let manifestSHA256: String
    let byteCount: Int
}

struct DerivedBuildPermit: Sendable {
    let book: LibraryBook
    let generation: String
    let previousGeneration: String?
}

struct DerivedLease: Sendable {
    let id: UUID
    let pointer: DerivedPointer
}

enum DerivedBuildStep: Equatable, Sendable { case staged, payloadWritten, synchronized, beforePublish, renamed, published }
typealias DerivedBuildInjection = @Sendable (DerivedBuildStep) throws -> Void

struct PreparedDerivedBook: Sendable {
    let pointer: DerivedPointer
}

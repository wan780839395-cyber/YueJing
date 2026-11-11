import Foundation

public struct EPUBReadingPosition: Codable, Sendable, Equatable {
    public let bookID: String
    public let versionID: String
    public let unit: String
    public let path: String
    public let node: Int
    public let utf16Offset: Int

    public init(bookID: String, versionID: String, path: String, node: Int, utf16Offset: Int,
                unit: String = EPUBFormat.positionUnit) {
        self.bookID = bookID; self.versionID = versionID; self.unit = unit
        self.path = path; self.node = node; self.utf16Offset = utf16Offset
    }

    public func validate(in package: EPUBPackage) throws {
        guard bookID == package.sourceSHA256, versionID == package.versionID,
              package.parserVersion == EPUBFormat.parserVersion, unit == EPUBFormat.positionUnit,
              package.spine.contains(path), let nodes = try package.nodes(at: path),
              nodes.indices.contains(node), utf16Offset >= 0 else { throw EPUBError.invalidPosition }
        let text = nodes[node]
        guard utf16Offset <= text.utf16.count else { throw EPUBError.invalidPosition }
        // A DOM UTF-16 offset must be a Swift Character boundary, not half a surrogate or grapheme.
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        guard let index = String.Index(utf16Index, within: text),
              index == text.endIndex || text.indices.contains(index) else { throw EPUBError.invalidPosition }
    }
}

public struct EPUBReadingStart: Sendable {
    public let session: ReadingSession
    public let position: EPUBReadingPosition?
    public let ignoredIncompatibleProgress: Bool
}

/// Immutable capability for a single page/layout generation. No web callback may invent an epoch.
public struct EPUBNavigationToken: Sendable, Equatable {
    public let sessionID: String
    public let epoch: UUID
    public let path: String
    public init(sessionID: String, epoch: UUID = UUID(), path: String) {
        self.sessionID = sessionID; self.epoch = epoch; self.path = path
    }
}

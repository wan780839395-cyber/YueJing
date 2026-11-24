import Foundation
import ReaderDomain

/// One forward-only cursor per playback. Only this actor opens the chapter indexes;
/// the viewport is neither advanced nor queried to obtain the next utterance.
actor EPUBSpeechCursor {
    struct Passage: Sendable {
        let text: String
        let position: EPUBReadingPosition
    }

    static let maxUTF16 = 280
    private let package: EPUBPackage
    private var chapter: Int
    private var node: Int
    private var offset: Int
    private var index: String.Index?
    private var nodes: [String]?

    init(package: EPUBPackage, path: String, node: Int, rawOffset: Int) throws {
        guard let chapter = package.spine.firstIndex(of: path), node >= 0, rawOffset >= 0 else {
            throw EPUBError.invalidPosition
        }
        self.package = package
        self.chapter = chapter
        self.node = node
        self.offset = rawOffset
    }

    func next() throws -> Passage? {
        while package.spine.indices.contains(chapter) {
            try Task.checkCancellation()
            let path = package.spine[chapter]
            if nodes == nil {
                guard let loaded = try package.nodes(at: path), loaded.indices.contains(node),
                      let snapped = EPUBLocationScript.snapUTF16OffsetToCharacterBoundary(offset, in: loaded[node]) else {
                    throw EPUBError.invalidPosition
                }
                offset = snapped
                index = String.Index(utf16Offset: snapped, in: loaded[node])
                // Legacy indexes store the sanitizer's synthetic anchor as a singleton chapter.
                nodes = loaded == ["图片页"] || loaded == ["空白页"] ? [] : loaded
            }
            guard let nodes, node < nodes.count else {
                chapter += 1; node = 0; offset = 0; index = nil; self.nodes = nil
                continue
            }
            let text = nodes[node]
            let start = index ?? text.startIndex, startOffset = offset
            guard start < text.endIndex else { node += 1; offset = 0; index = nil; continue }
            guard let end = NarrationPhrase.end(in: text[start...], limit: Self.maxUTF16) else {
                throw EPUBError.limitExceeded
            }
            let slice = text[start..<end]
            offset += slice.utf16.count
            let spoken = slice.drop(while: { $0.isWhitespace })
            let position = EPUBReadingPosition(bookID: package.sourceSHA256, versionID: package.versionID,
                path: path, node: node, utf16Offset: startOffset + text[start..<spoken.startIndex].utf16.count)
            index = end
            if end == text.endIndex { node += 1; offset = 0; index = nil }
            if !spoken.isEmpty { return Passage(text: String(spoken), position: position) }
        }
        return nil
    }
}

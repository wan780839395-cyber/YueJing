import Foundation

public enum EPUBFormat {
    public static let parserVersion = "epub-dom-v1"
    public static let positionUnit = "epub-text-node-utf16-v1"
    public static let authorStyleRevision = 1
}

public struct EPUBResource: Codable, Sendable, Equatable {
    public let path: String
    public let mediaType: String
    public let sha256: String
    public let byteCount: Int
    public init(path: String, mediaType: String, sha256: String, byteCount: Int) {
        self.path = path; self.mediaType = mediaType; self.sha256 = sha256; self.byteCount = byteCount
    }
}

public struct EPUBNavigationItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path + "#" + (fragment ?? "") }
    public let title: String
    public let path: String
    public let fragment: String?
    public let depth: Int
    public init(title: String, path: String, fragment: String? = nil, depth: Int = 0) {
        self.title = title; self.path = path; self.fragment = fragment; self.depth = depth
    }
}

/// Text nodes correspond to deterministic yj-tN spans in sanitized XHTML, not ZIP byte offsets.
public struct EPUBPackage: Codable, Sendable, Equatable {
    public let sourceSHA256: String
    public let parserVersion: String
    public let title: String
    public let spine: [String]
    public let navigation: [EPUBNavigationItem]
    public let resources: [EPUBResource]
    public let textNodes: [String: [String]]
    public let coverPath: String?
    public let ready: EPUBReadyReference?
    public let authorStyleRevision: Int?
    private var chapterNodes: EPUBChapterNodes? = nil
    private enum CodingKeys: String, CodingKey {
        case sourceSHA256, parserVersion, title, spine, navigation, resources, textNodes, coverPath, ready
        case authorStyleRevision
    }
    public init(sourceSHA256: String, parserVersion: String = EPUBFormat.parserVersion, title: String,
                spine: [String], navigation: [EPUBNavigationItem], resources: [EPUBResource],
                textNodes: [String: [String]], coverPath: String?, ready: EPUBReadyReference? = nil,
                authorStyleRevision: Int? = EPUBFormat.authorStyleRevision) {
        self.sourceSHA256 = sourceSHA256; self.parserVersion = parserVersion; self.title = title
        self.spine = spine; self.navigation = navigation; self.resources = resources
        self.textNodes = textNodes; self.coverPath = coverPath
        self.ready = ready
        self.authorStyleRevision = authorStyleRevision
    }
    public var versionID: String { sourceSHA256 + ":" + parserVersion }
    public func resource(at path: String) -> EPUBResource? { resources.first { $0.path == path } }

    public func nodes(at path: String) throws -> [String]? {
        if ready == nil { return textNodes[path] }
        guard let chapterNodes else { throw EPUBError.corruptResource }
        return try chapterNodes.nodes(at: path)
    }

    func withReady(_ reference: EPUBReadyReference) -> EPUBPackage {
        EPUBPackage(sourceSHA256: sourceSHA256, parserVersion: parserVersion, title: title,
                    spine: spine, navigation: navigation, resources: resources,
                    textNodes: [:], coverPath: coverPath, ready: reference, authorStyleRevision: authorStyleRevision)
    }

    func attachingNodes(folder: URL) throws -> EPUBPackage {
        guard let ready else { return self }
        try EPUBReadyArtifact.validate(ready, package: self)
        var copy = self
        copy.chapterNodes = EPUBChapterNodes(folder: folder, reference: ready)
        return copy
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceSHA256 == rhs.sourceSHA256 && lhs.parserVersion == rhs.parserVersion &&
        lhs.title == rhs.title && lhs.spine == rhs.spine && lhs.navigation == rhs.navigation &&
        lhs.resources == rhs.resources && lhs.textNodes == rhs.textNodes &&
        lhs.coverPath == rhs.coverPath && lhs.ready == rhs.ready && lhs.authorStyleRevision == rhs.authorStyleRevision
    }
}

public struct EPUBPublication: Sendable {
    public let package: EPUBPackage
    public let resourceRoot: URL
    public init(package: EPUBPackage, resourceRoot: URL) {
        self.package = package; self.resourceRoot = resourceRoot
    }
}

public struct EPUBLimits: Sendable {
    public var compressedBytes = 100 * 1024 * 1024
    public var entries = 4096
    public var expandedBytes = 256 * 1024 * 1024
    public var xhtmlBytes = 8 * 1024 * 1024
    public var imageBytes = 16 * 1024 * 1024
    public var xmlBytes = 2 * 1024 * 1024
    public var spineItems = 2048
    public init() {}
}

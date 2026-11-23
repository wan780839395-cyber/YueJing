import Foundation

extension EPUBStyleCompatibility {
    // At the 128-row persistence cap an omitted candidate may no longer be visible.
    // Neither a generic fontUnavailable flag nor a CSS hint alone warrants a reparse.
    var mayContainEmbeddedWOFF2: Bool {
        fontDiagnostics.count == 128 || fontDiagnostics.contains { $0.source == .embedded && $0.format == .woff2 }
    }
}

/// A presentation-only revision never changes the persisted text-position version.
/// Prove every old chapter's text and all non-XHTML resources before publishing.
enum EPUBAuthorStyleMigration {
    static func validate(previous: EPUBPackage, replacement: EPUBPackage) throws {
        guard previous.needsAuthorStyleUpgrade,
              replacement.authorStyleRevision == EPUBFormat.authorStyleRevision,
              !replacement.needsAuthorStyleUpgrade,
              previous.sourceSHA256 == replacement.sourceSHA256,
              previous.parserVersion == replacement.parserVersion,
              previous.title == replacement.title,
              previous.spine == replacement.spine,
              previous.navigation == replacement.navigation,
              previous.coverPath == replacement.coverPath else { throw EPUBError.corruptResource }
        if let ready = previous.ready { try EPUBReadyArtifact.validate(ready, package: previous) }
        if let ready = replacement.ready { try EPUBReadyArtifact.validate(ready, package: replacement) }
        if previous.needsWOFF2Upgrade || replacement.woff2Revision != nil, let old = previous.ready, let new = replacement.ready {
            // CAS publication: both complete node packs (not just individual index claims) must match.
            guard old.nodeBytes == new.nodeBytes, old.nodeSHA256 == new.nodeSHA256,
                  old.chapters == new.chapters else { throw EPUBError.corruptResource }
        }
        for path in previous.spine {
            guard try nodeDigest(previous, path: path) == nodeDigest(replacement, path: path) else {
                throw EPUBError.corruptResource
            }
        }
        guard Set(previous.resources.map(\.path)).count == previous.resources.count,
              Set(replacement.resources.map(\.path)).count == replacement.resources.count else {
            throw EPUBError.corruptResource
        }
        for resource in previous.resources where resource.mediaType == "application/xhtml+xml" {
            guard replacement.resource(at: resource.path)?.mediaType == "application/xhtml+xml" else {
                throw EPUBError.corruptResource
            }
        }
        for resource in previous.resources where resource.mediaType != "application/xhtml+xml" {
            guard replacement.resource(at: resource.path) == resource else { throw EPUBError.corruptResource }
        }
        for resource in replacement.resources where previous.resource(at: resource.path) == nil {
            guard ["font/ttf", "font/otf"].contains(resource.mediaType) else { throw EPUBError.corruptResource }
        }
    }

    private static func nodeDigest(_ package: EPUBPackage, path: String) throws -> String {
        if let ready = package.ready {
            guard let chapter = ready.chapters[path] else { throw EPUBError.corruptResource }
            return chapter.sha256
        }
        guard let nodes = package.textNodes[path] else { throw EPUBError.corruptResource }
        return EPUBResourceStore.digest(try JSONEncoder().encode(nodes))
    }
}

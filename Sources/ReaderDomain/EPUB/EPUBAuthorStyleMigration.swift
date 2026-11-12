import Foundation

/// A presentation-only revision never changes the persisted text-position version.
/// Prove every old chapter's text and all non-XHTML resources before publishing.
enum EPUBAuthorStyleMigration {
    static func validate(previous: EPUBPackage, replacement: EPUBPackage) throws {
        guard previous.needsAuthorStyleUpgrade,
              replacement.authorStyleRevision == EPUBFormat.authorStyleRevision,
              previous.sourceSHA256 == replacement.sourceSHA256,
              previous.parserVersion == replacement.parserVersion,
              previous.title == replacement.title,
              previous.spine == replacement.spine,
              previous.navigation == replacement.navigation,
              previous.coverPath == replacement.coverPath else { throw EPUBError.corruptResource }
        if let ready = previous.ready { try EPUBReadyArtifact.validate(ready, package: previous) }
        if let ready = replacement.ready { try EPUBReadyArtifact.validate(ready, package: replacement) }
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

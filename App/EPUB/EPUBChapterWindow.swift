import Foundation
import ReaderDomain

/// A bounded rendering capability, not a reading-position or navigation authority.
enum EPUBChapterWindow {
    static let defaultChapters = 5
    static let maximumChapters = 64
    static let maximumXHTMLBytes = 40 * 1024 * 1024

    static func paths(in spine: [String], around path: String, count: Int = defaultChapters) -> [String] {
        guard let index = spine.firstIndex(of: path) else { return [] }
        let limit = max(defaultChapters, min(count, maximumChapters))
        let start = max(0, min(index - 2, spine.count - defaultChapters))
        return Array(spine[start..<min(spine.count, start + limit)])
    }

    static func paths(in package: EPUBPackage, around path: String, count: Int) -> [String] {
        var bytes = 0
        return paths(in: package.spine, around: path, count: count).prefix { item in
            let next = package.resource(at: item)?.byteCount ?? maximumXHTMLBytes
            guard next >= 0, next <= maximumXHTMLBytes - bytes else { return false }
            bytes += next
            return true
        }.map { $0 }
    }

    /// Install only the immediately adjacent missing chapter per transaction.
    /// A distant image must not hold the next readable chapter behind Promise.all.
    static func nextPaths(desired: [String], installed: Set<String>, current: String) -> [String] {
        guard let center = desired.firstIndex(of: current) else { return [] }
        var available = installed.intersection(Set(desired))
        available.insert(current)
        if let next = desired.indices.dropFirst(center + 1).first(where: { !available.contains(desired[$0]) }) {
            available.insert(desired[next])
        } else if let previous = desired.indices.prefix(center).reversed().first(where: { !available.contains(desired[$0]) }) {
            available.insert(desired[previous])
        }
        return desired.filter { available.contains($0) }
    }

    /// Run away from the main actor. Only validated, sanitized package resources are read.
    static func invocation(publication: EPUBPublication, token: EPUBNavigationToken,
                           installedPaths: Set<String>, urls: [String: String], chapterCount: Int = defaultChapters) throws -> String {
        let desired = paths(in: publication.package, around: token.path, count: chapterCount)
        let paths = nextPaths(desired: desired, installed: installedPaths, current: token.path)
        guard !paths.isEmpty, paths.count <= maximumChapters else { throw EPUBError.invalidPackage }
        var byteCount = 0
        var chapters: [[String: Any]] = []
        for path in paths {
            try Task.checkCancellation()
            guard let resource = publication.package.resource(at: path),
                  resource.mediaType == "application/xhtml+xml",
                  resource.byteCount >= 0,
                  resource.byteCount <= EPUBLimits().xhtmlBytes else { throw EPUBError.corruptResource }
            byteCount += resource.byteCount
            guard byteCount <= maximumXHTMLBytes else { throw EPUBError.limitExceeded }
            if installedPaths.contains(path) { continue }
            guard let index = publication.package.spine.firstIndex(of: path),
                  let nodes = publication.package.textNodes[path], let url = urls[path],
                  let xhtml = String(data: try EPUBResourceStore.data(path: path, publication: publication), encoding: .utf8)
            else { throw EPUBError.corruptResource }
            chapters.append(["path": path, "index": index, "xhtml": xhtml, "url": url,
                             "lengths": nodes.map { $0.utf16.count }])
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "sessionID": token.sessionID, "epoch": token.epoch.uuidString,
            "chapters": chapters, "keepPaths": paths, "limit": min(maximumChapters, max(defaultChapters, chapterCount))
        ])
        return "window.__yjEpub && window.__yjEpub.syncWindow(\(String(decoding: data, as: UTF8.self)));"
    }
}

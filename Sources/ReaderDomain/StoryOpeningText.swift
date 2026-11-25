import Foundation

/// Only the selected chapter contributes prose. Older sessions keep their stored excerpt.
enum StoryOpeningText {
    static let limit = 1400
    static let chapterPattern = #"^\s*(?:第\s*[零〇一二两三四五六七八九十百千万0-9０-９]+\s*[章节回]|chapter\s+(?:[0-9]+|one|[ivxlcdm]+)\b)"#

    static func bounded(_ value: String) -> String {
        let prefix = value.prefix(limit + 1)
        guard prefix.count > limit else { return String(prefix) }
        let clipped = prefix.prefix(limit)
        if let i = clipped.suffix(200).lastIndex(where: { "。！？!?\n".contains($0) }) {
            return String(clipped[...i]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(clipped)
    }

    static func from(text: String) -> String {
        // Input is already strictly decoded from a bounded prefix. Match headings, not prose mentions.
        let lines = text.components(separatedBy: .newlines)
        let headings = lines.indices.filter { i in
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard line.count <= 90, let match = line.range(of: chapterPattern, options: [.regularExpression, .caseInsensitive]) else { return false }
            let suffix = line[match.upperBound...]
            return suffix.isEmpty || (suffix.first.map { $0.isWhitespace || $0 == ":" || $0 == "：" } == true &&
                !suffix.contains(where: { "。！？!?；;，,.".contains($0) }))
        }
        guard let first = headings.first else { return bounded(text) }
        let end = headings.dropFirst().first ?? lines.endIndex
        return bounded(lines[first..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func from(package: EPUBPackage) throws -> String {
        let preferred = package.navigation.first { item in
            item.title.range(of: chapterPattern, options: [.regularExpression, .caseInsensitive]) != nil
                && package.spine.contains(item.path)
        }
        let paths = (preferred.map { [$0.path] } ?? []) + Array(package.spine.prefix(32))
        var visited = Set<String>()
        for path in paths where visited.insert(path).inserted {
            try Task.checkCancellation()
            let nodes = try package.nodes(at: path) ?? []
            var start = nodes.startIndex
            let headings = package.navigation.filter { $0.path == path }
            if let selected = preferred, selected.path == path, selected.fragment != nil {
                if let i = nodes.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == selected.title.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                    start = i
                } else if headings.count > 1 {
                    // Metadata does not map fragment IDs to nodes. Never silently substitute the preface.
                    throw StoryLaunchError.missingOpening
                }
            }
            let following = Set(headings.drop(while: { $0 != preferred }).dropFirst().map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) })
            var text = ""
            for (offset, node) in nodes[start...].enumerated() {
                try Task.checkCancellation()
                let part = node.trimmingCharacters(in: .whitespacesAndNewlines)
                if offset > 0, following.contains(part) { break }
                guard !part.isEmpty, part != "图片页", part != "空白页" else { continue }
                if !text.isEmpty { text.append("\n") }
                text += part.prefix(max(0, limit + 1 - text.count))
                if text.count > limit { break }
            }
            if !text.isEmpty { return bounded(text) }
        }
        throw StoryLaunchError.missingOpening
    }
}

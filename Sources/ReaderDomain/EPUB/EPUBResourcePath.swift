import Foundation

public enum EPUBResourcePath {
    /// Validates and canonicalizes a raw archive entry path without percent-decoding raw ZIP names.
    public static func canonical(_ path: String) throws -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.hasSuffix("/") else {
            throw EPUBError.unsafePath
        }
        try validateScalars(in: normalized, allowHash: false)
        try validatePercentSequences(in: normalized)

        let rawSegments = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawSegments.isEmpty else { throw EPUBError.unsafePath }
        var segments: [String] = []
        segments.reserveCapacity(rawSegments.count)
        for raw in rawSegments {
            let segment = String(raw).precomposedStringWithCanonicalMapping
            guard !segment.isEmpty, segment != ".", segment != ".." else {
                throw EPUBError.unsafePath
            }
            segments.append(segment)
        }
        return segments.joined(separator: "/")
    }

    /// Resolves a relative URI reference (`href`) against a canonical document path using one strict rule.
    public static func resolve(_ href: String, relativeTo path: String) throws -> (path: String, fragment: String?) {
        guard !href.isEmpty else { throw EPUBError.unsafePath }
        try validateScalars(in: href, allowHash: true)

        let hashParts = href.split(separator: "#", omittingEmptySubsequences: false)
        guard hashParts.count == 1 || hashParts.count == 2 else {
            throw EPUBError.unsafePath
        }

        let rawPathPart = String(hashParts[0])
        let resolvedFragment: String?
        if hashParts.count == 2 {
            let rawFragment = String(hashParts[1])
            guard !rawFragment.isEmpty else { throw EPUBError.unsafePath }
            try validatePercentSequences(in: rawFragment)
            guard let decodedFragment = rawFragment.removingPercentEncoding?.precomposedStringWithCanonicalMapping,
                  isValidFragmentID(decodedFragment) else {
                throw EPUBError.unsafePath
            }
            resolvedFragment = decodedFragment
        } else {
            resolvedFragment = nil
        }

        if rawPathPart.isEmpty {
            guard resolvedFragment != nil, !path.isEmpty else {
                throw EPUBError.unsafePath
            }
            return (try canonical(path), resolvedFragment)
        }

        guard !rawPathPart.hasPrefix("/"), !rawPathPart.hasSuffix("/") else {
            throw EPUBError.unsafePath
        }
        try validatePercentSequences(in: rawPathPart)
        guard let decodedPath = rawPathPart.removingPercentEncoding else {
            throw EPUBError.unsafePath
        }
        try validateScalars(in: decodedPath, allowHash: false)
        guard !decodedPath.contains("%"),
              !decodedPath.hasPrefix("/"),
              !decodedPath.hasSuffix("/") else {
            throw EPUBError.unsafePath
        }

        var stack: [String]
        if path.isEmpty {
            stack = []
        } else if path.hasSuffix("/") {
            let trimmed = String(path.dropLast())
            let baseDir = try canonical(trimmed)
            stack = baseDir.split(separator: "/").map(String.init)
        } else {
            let baseFile = try canonical(path)
            stack = Array(baseFile.split(separator: "/").dropLast().map(String.init))
        }

        let segments = decodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { throw EPUBError.unsafePath }
        for rawSegment in segments {
            let segment = String(rawSegment).precomposedStringWithCanonicalMapping
            guard !segment.isEmpty else { throw EPUBError.unsafePath }
            if segment == "." {
                continue
            } else if segment == ".." {
                guard !stack.isEmpty else { throw EPUBError.unsafePath }
                stack.removeLast()
            } else {
                stack.append(segment)
            }
        }

        guard !stack.isEmpty else { throw EPUBError.unsafePath }
        let joined = stack.joined(separator: "/")
        return (try canonical(joined), resolvedFragment)
    }

    public static func isValidFragmentID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        for scalar in id.unicodeScalars {
            if scalar.value <= 0x20 || scalar.value == 0x7F {
                return false
            }
            switch scalar {
            case "\"", "'", "<", ">", "&", "#", "\\", "/", "?":
                return false
            default:
                break
            }
        }
        return true
    }

    public static func relativeHref(from sourcePath: String, to targetPath: String, fragment: String? = nil) -> String {
        let sourceDir = Array(sourcePath.split(separator: "/").dropLast().map(String.init))
        let targetParts = targetPath.split(separator: "/").map(String.init)
        var common = 0
        while common < sourceDir.count && common < max(0, targetParts.count - 1) && sourceDir[common] == targetParts[common] {
            common += 1
        }
        var relParts: [String] = Array(repeating: "..", count: sourceDir.count - common)
        for index in common..<targetParts.count {
            relParts.append(percentEncodeSegment(targetParts[index]))
        }
        let pathPart = relParts.joined(separator: "/")
        if let fragment, !fragment.isEmpty {
            return pathPart + "#" + percentEncodeFragment(fragment)
        }
        return pathPart
    }

    private static func validateScalars(in value: String, allowHash: Bool) throws {
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                throw EPUBError.unsafePath
            }
            switch scalar {
            case "\\", ":", "?":
                throw EPUBError.unsafePath
            case "#" where !allowHash:
                throw EPUBError.unsafePath
            default:
                break
            }
        }
    }

    private static func validatePercentSequences(in value: String) throws {
        let utf8 = Array(value.utf8)
        var index = 0
        while index < utf8.count {
            if utf8[index] == 0x25 { // '%'
                guard index + 2 < utf8.count,
                      let high = hexValue(utf8[index + 1]),
                      let low = hexValue(utf8[index + 2]) else {
                    throw EPUBError.unsafePath
                }
                let byte = (high << 4) | low
                if byte < 0x20 || byte == 0x7F ||
                    byte == 0x2F || byte == 0x5C || byte == 0x3A ||
                    byte == 0x2E || byte == 0x3F || byte == 0x23 {
                    throw EPUBError.unsafePath
                }
                index += 3
            } else {
                index += 1
            }
        }
    }

    private static func hexValue(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case 0x30...0x39: return ascii - 0x30
        case 0x41...0x46: return ascii - 0x41 + 10
        case 0x61...0x66: return ascii - 0x61 + 10
        default: return nil
        }
    }

    private static func percentEncodeSegment(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/\\:?#%\"")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    private static func percentEncodeFragment(_ fragment: String) -> String {
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.remove(charactersIn: "#\\/?%\"<>")
        return fragment.addingPercentEncoding(withAllowedCharacters: allowed) ?? fragment
    }
}

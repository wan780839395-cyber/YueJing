import Foundation

public enum EPUBStyleIssue: String, Codable, Sendable, Hashable {
    case optionalResourceMissing
    case fontUnavailable
    case styleComplexity
    case localImportCycle
    case unsupportedStyleCondition
}

public struct EPUBStyleCompatibility: Codable, Sendable, Equatable {
    public let issues: [EPUBStyleIssue]
    public let usesReaderLayout: Bool

    public init(issues: [EPUBStyleIssue] = [], usesReaderLayout: Bool = false) {
        self.issues = Array(Set(issues)).sorted { $0.rawValue < $1.rawValue }
        self.usesReaderLayout = usesReaderLayout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedIssues = try container.decodeIfPresent([EPUBStyleIssue].self, forKey: .issues) ?? []
        let decodedFallback = try container.decodeIfPresent(Bool.self, forKey: .usesReaderLayout) ?? false
        self.init(issues: decodedIssues, usesReaderLayout: decodedFallback)
    }

    private enum CodingKeys: String, CodingKey {
        case issues
        case usesReaderLayout
    }
}

public enum EPUBStyleProcessingError: Error, Sendable, Equatable {
    case complexityExceeded
}

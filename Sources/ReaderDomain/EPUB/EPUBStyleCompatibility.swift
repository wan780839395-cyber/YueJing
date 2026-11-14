import Foundation

public enum EPUBStyleIssue: String, Codable, Sendable, Hashable {
    case optionalResourceMissing
    case fontUnavailable
    case styleComplexity
    case localImportCycle
    case unsupportedStyleCondition
    case navigationUnavailable
    case malformedOptionalStyle
    case invalidOptionalFont
    case obfuscatedFontOmitted
    case manifestImageRecovered
}

public struct EPUBStyleCompatibility: Codable, Sendable, Equatable {
    public let issues: [EPUBStyleIssue]
    public let usesReaderLayout: Bool
    public let fontDiagnostics: [EPUBFontDiagnostic]

    public init(issues: [EPUBStyleIssue] = [], usesReaderLayout: Bool = false,
                fontDiagnostics: [EPUBFontDiagnostic] = []) {
        self.issues = Array(Set(issues)).sorted { $0.rawValue < $1.rawValue }
        self.usesReaderLayout = usesReaderLayout
        self.fontDiagnostics = EPUBFontDiagnostic.bounded(fontDiagnostics)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedIssues = try container.decodeIfPresent([EPUBStyleIssue].self, forKey: .issues) ?? []
        let decodedFallback = try container.decodeIfPresent(Bool.self, forKey: .usesReaderLayout) ?? false
        let fonts = try container.decodeIfPresent([EPUBFontDiagnostic].self, forKey: .fontDiagnostics) ?? []
        self.init(issues: decodedIssues, usesReaderLayout: decodedFallback, fontDiagnostics: fonts)
    }

    private enum CodingKeys: String, CodingKey {
        case issues
        case usesReaderLayout
        case fontDiagnostics
    }
}

public enum EPUBStyleProcessingError: Error, Sendable, Equatable {
    case complexityExceeded
    case malformedStylesheet
    case invalidFontStructure
}

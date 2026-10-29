import Foundation

/// Convenience values only; the selected name is not persisted or coupled to reading theme.
public enum ReaderTypographyPreset: String, CaseIterable, Sendable {
    case compact, standard, relaxed

    public var title: String {
        switch self { case .compact: "紧凑"; case .standard: "标准"; case .relaxed: "宽松" }
    }
    public var fontSize: Double {
        switch self { case .compact: 17; case .standard: 20; case .relaxed: 24 }
    }
    public var lineSpacing: Double {
        switch self { case .compact: 5; case .standard: 7; case .relaxed: 10 }
    }
    public func applying(to preferences: ReaderPreferences) -> ReaderPreferences {
        ReaderPreferences(fontSize: fontSize, lineSpacing: lineSpacing, theme: preferences.theme)
    }
    public func matches(_ preferences: ReaderPreferences) -> Bool {
        preferences.fontSize == fontSize && preferences.lineSpacing == lineSpacing
    }
}

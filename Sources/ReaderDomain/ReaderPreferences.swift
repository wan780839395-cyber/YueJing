import Foundation

public enum ReaderTheme: String, Codable, Sendable, CaseIterable {
    case paper, light, dark
    public var title: String {
        switch self { case .paper: "纸色"; case .light: "白色"; case .dark: "深色" }
    }
}

public struct ReaderPreferences: Codable, Sendable, Equatable {
    public var fontSize: Double
    public var lineSpacing: Double
    public var theme: ReaderTheme

    public init(fontSize: Double = 20, lineSpacing: Double = 7, theme: ReaderTheme = .paper) {
        self.fontSize = fontSize.isFinite ? min(36, max(14, fontSize)) : 20
        self.lineSpacing = lineSpacing.isFinite ? min(20, max(0, lineSpacing)) : 7
        self.theme = theme
    }
    public var validated: Self { Self(fontSize: fontSize, lineSpacing: lineSpacing, theme: theme) }
}

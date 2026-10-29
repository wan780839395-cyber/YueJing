import Foundation
import Testing
@testable import ReaderDomain

struct ReaderTypographyPresetTests {
    @Test func presetsKeepTheCurrentThemeAndStayWithinExistingRanges() {
        for theme in ReaderTheme.allCases {
            let original = ReaderPreferences(fontSize: 35, lineSpacing: 19, theme: theme)
            for preset in ReaderTypographyPreset.allCases {
                let applied = preset.applying(to: original)
                #expect(applied.theme == theme)
                #expect(applied == applied.validated)
                #expect((14...36).contains(applied.fontSize))
                #expect((0...20).contains(applied.lineSpacing))
                #expect(preset.matches(applied))
                let matchedCount = ReaderTypographyPreset.allCases.filter { $0.matches(applied) }.count
                #expect(matchedCount == 1)
            }
        }
    }

    @Test func standardRestoresExistingTypographyWithoutForcingThePaperTheme() {
        let original = ReaderPreferences(fontSize: 36, lineSpacing: 20, theme: .dark)
        let restored = ReaderTypographyPreset.standard.applying(to: original)
        let defaults = ReaderPreferences()
        #expect(restored.fontSize == defaults.fontSize)
        #expect(restored.lineSpacing == defaults.lineSpacing)
        #expect(restored.theme == .dark)
        #expect(original.fontSize == 36 && original.lineSpacing == 20)
    }

    @Test func customTypographyDoesNotClaimToMatchAPreset() {
        let custom = ReaderPreferences(fontSize: 21, lineSpacing: 8, theme: .light)
        let matched = ReaderTypographyPreset.allCases.contains { $0.matches(custom) }
        #expect(!matched)
    }

    @Test func applyingAPresetKeepsTheOriginalPreferencesJSONContract() throws {
        let legacy = Data(#"{"fontSize":28,"lineSpacing":11,"theme":"dark"}"#.utf8)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: legacy)
        let applied = ReaderTypographyPreset.relaxed.applying(to: decoded)
        let data = try JSONEncoder().encode(applied)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Set(["fontSize", "lineSpacing", "theme"]))
        let reloaded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(reloaded == applied)
        #expect(reloaded.theme == .dark)
    }
}

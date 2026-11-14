import Foundation
import Testing
@testable import ReaderDomain

struct EPUBUnicodeRangeTests {
    @Test func rangesNormalizeSinglesIntervalsWildcardsAndOverlaps() throws {
        let cases = [
            ("u+0041", "U+41"), ("U+4??", "U+400-4FF"), ("U+???", "U+0-FFF"),
            ("U+61-7a, U+0041-005A, U+5b-60, U+41", "U+41-7A"),
            ("U+0,U+10FFFF,U+1F600", "U+0,U+1F600,U+10FFFF"),
            ("U+?????", "U+0-FFFFF"), ("U+10????", "U+100000-10FFFF")
        ]
        for (input, expected) in cases {
            #expect(EPUBUnicodeRange.normalize(input) == expected)
            #expect(try EPUBUnicodeRange.normalize(tokens: EPUBAuthorStyles.CSSTokenizer.tokenize(input)) == expected)
        }
    }

    @Test func rangesRejectMalformedOutOfBoundsAndExcessiveWork() throws {
        let invalid = ["", "U+", "U+110000", "U+FFFFFF", "U+??????", "U+4?F", "U+42-41", "U+1-", "U+ 41", "U+41,", "U+0000041", "U+41;src:url(a)", "U+41/42", "U+٤١", "U+4??-5FF"]
        for input in invalid { #expect(EPUBUnicodeRange.normalize(input) == nil) }
        #expect(EPUBUnicodeRange.normalize(Array(repeating: "U+41", count: 128).joined(separator: ",")) == "U+41")
        #expect(EPUBUnicodeRange.normalize(Array(repeating: "U+41", count: 129).joined(separator: ",")) == nil)
        #expect(EPUBUnicodeRange.normalize(String(repeating: " ", count: 4096) + "U+41") == nil)
        #expect(try EPUBUnicodeRange.normalize(tokens: EPUBAuthorStyles.CSSTokenizer.tokenize("url(a)")) == nil)
    }

    @Test func invalidSubsetStillAuditsUnsafeSource() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for range in ["U+41", "U+110000"] {
            #expect(throws: EPUBError.unsupportedContent) {
                try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
                    "@font-face{font-family:Example;src:url(https://example.invalid/font.ttf);unicode-range:\(range)}",
                    sourcePath: "OPS/style.css", documentPath: "OPS/c.xhtml", manifestByPath: [:], destination: root)
            }
        }
    }
}

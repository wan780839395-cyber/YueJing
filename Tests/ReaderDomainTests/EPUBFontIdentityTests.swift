import Foundation
import Testing
@testable import ReaderDomain

struct EPUBFontIdentityTests {
    @Test func packageIdentityKeepsCSSAliasAndInternalNamesOptIn() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let font = makeSFNT(makeName([.init(16, "Internal Family"), .init(4, "Internal Regular"), .init(8, "Unverified Vendor")]))
        let archive = root.appendingPathComponent("identity.epub")
        let xhtml = "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Fixture</title><style>@font-face{font-family:'CSS Alias';src:url(font.ttf)}p{font-family:'CSS Alias'}</style></head><body><p>Original text</p></body></html>"
        try EPUBTestSupport.writeEPUB3(at: archive,
            chapters: [.init(id: "c", path: "c.xhtml", title: "Fixture", bodyXHTML: xhtml)],
            manifestExtra: "<item id='font' href='font.ttf' media-type='font/ttf'/>", extraEntries: [("OPS/font.ttf", font)])
        let original = try Data(contentsOf: archive)
        let package = try EPUBPackageParser.parse(archiveURL: archive, destination: root.appendingPathComponent("prepared"))
        let rows = package.styleCompatibility?.fontDiagnostics ?? []
        let row = try #require(rows.first(where: { $0.family == "CSS Alias" }))
        #expect(row.identity?.family == "Internal Family")
        #expect(row.identity?.manufacturer == "Unverified Vendor")
        #expect(!EPUBFontDiagnostic.summary(rows).contains("Internal"))
        #expect(EPUBFontDiagnostic.summary(rows, includeNames: true).contains("CSS Alias"))
        #expect(EPUBFontDiagnostic.summary(rows, includeNames: true).contains("Internal Family"))
        #expect(try Data(contentsOf: archive) == original)
        #expect(package.textNodes["OPS/c.xhtml"] == ["Original text"])
        #expect(package.resource(at: "OPS/font.ttf")?.sha256 == EPUBResourceStore.digest(font))
    }

    @Test func validatedSFNTExtractsAllFieldsWithoutMutatingBytes() throws {
        let names = makeName([.init(1, "Legacy Family"), .init(16, "Synthetic Family"),
            .init(4, "Synthetic Regular"), .init(6, "Synthetic-Regular"),
            .init(5, "Version 1.002"), .init(8, "Synthetic Vendor")])
        for otf in [false, true] {
            let data = makeSFNT(names, otf: otf)
            let original = data
            #expect(try EPUBAuthorStyles.verifyFontData(data, declaredMediaType: "font/ttf") == (otf ? "font/otf" : "font/ttf"))
            let identity = try #require(EPUBFontIdentity.extract(fromValidatedSFNT: data))
            #expect(identity == EPUBFontIdentity(family: "Synthetic Family", fullName: "Synthetic Regular",
                postScriptName: "Synthetic-Regular", version: "Version 1.002", manufacturer: "Synthetic Vendor"))
            #expect(data == original)
        }
    }

    @Test func typographicFamilyWinsBeforeLanguageAndLegacyIsFallback() {
        let records: [Record] = [.init(1, "Legacy English"), .init(16, "排印家族", language: 0x0804)]
        #expect(extract(records)?.family == "排印家族")
        #expect(extract([.init(16, "https://invalid.example"), .init(1, "Legacy")])?.family == "Legacy")
        #expect(extract([.init(16, "Unsupported", platform: 1, encoding: 0), .init(1, "Legacy")])?.family == "Legacy")
    }

    @Test func languageSelectionIsDeterministicWithFirstRecordTieBreak() {
        let records: [Record] = [.init(4, "French", language: 0x040c),
            .init(4, "Neutral", platform: 0, encoding: 4, language: 0), .init(4, "English")]
        #expect(extract(records)?.fullName == "English")
        #expect(extract(Array(records.reversed()))?.fullName == "English")
        #expect(extract(Array(records.prefix(2)))?.fullName == "Neutral")
        #expect(extract([.init(4, "First"), .init(4, "Second")])?.fullName == "First")
    }

    @Test func formatOneLanguageTagsAreBoundedAndReferencedSafely() {
        let records: [Record] = [.init(4, "French", language: 0x8000), .init(4, "English", language: 0x8001)]
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: makeSFNT(makeName(records, tags: ["fr", "en-US"])))?.fullName == "English")
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: makeSFNT(makeName(records, tags: ["fr"])))?.fullName == "French")
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: makeSFNT(makeName(records, tags: ["https://invalid", "en-US"])))?.fullName == "English")
        #expect(extract([.init(4, "Unbound", language: 0x8000)]) == nil)
        var badTag = makeName([.init(4, "Unbound", language: 0x8000)], tags: ["en"])
        put16(0xffff, into: &badTag, at: 22) // Language record string offset.
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: makeSFNT(badTag)) == nil)
    }

    @Test func supportedUnicodeEncodingsAndSupplementaryLettersDecodeStrictly() {
        for encoding in 0...4 {
            #expect(extract([.init(1, "Unicode", platform: 0, encoding: encoding, language: 0)])?.family == "Unicode")
        }
        for encoding in [0, 1, 10] {
            #expect(extract([.init(1, "\u{10400} Font", encoding: encoding)])?.family == "\u{10400} Font")
        }
        for record in [Record(1, "Legacy", platform: 1, encoding: 0),
                       Record(1, "Reserved", platform: 0, encoding: 99),
                       Record(1, "Codepage", encoding: 3), Record(1, "Unknown", platform: 99)] {
            #expect(extract([record]) == nil)
            #expect(extract([record, .init(4, "Retained")])?.fullName == "Retained")
        }
    }

    @Test func malformedUTF16OmitsOnlyTheAffectedOptionalName() throws {
        let malformed: [[UInt8]] = [[0xd8, 0x00], [0xdc, 0x00], [0xd8, 0, 0, 65],
            [0xd8, 0, 0xd8, 1], [0, 65, 0], [0, 65, 0, 0, 0, 66]]
        for bytes in malformed {
            let names = makeName([.init(16, bytes: bytes), .init(1, "Fallback"), .init(8, "Retained")])
            let data = makeSFNT(names)
            #expect(try EPUBAuthorStyles.verifyFontData(data, declaredMediaType: "font/ttf") == "font/ttf")
            let identity = try #require(EPUBFontIdentity.extract(fromValidatedSFNT: data))
            #expect(identity.family == "Fallback")
            #expect(identity.manufacturer == "Retained")
        }
    }

    @Test func stringBoundsUseNameTableEndNotRemainingFontBytes() {
        var names = makeName([.init(4, "Bad"), .init(1, "Retained")])
        put16(names.count, into: &names, at: 16) // Offset relative to storage, beyond table.
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: makeSFNT(names))?.fullName == nil)
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: makeSFNT(names))?.family == "Retained")
        put16(0xffff, into: &names, at: 16)
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: makeSFNT(names))?.family == "Retained")
        var ending = makeName([.init(1, "A")])
        put16(4, into: &ending, at: 14) // Starts inside but extends beyond name table.
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: makeSFNT(ending)) == nil)
    }

    @Test func truncatedAndOverflowingDirectoryInputsAreSafe() {
        let valid = makeSFNT(makeName([.init(1, "Family")]))
        for length in 0..<60 {
            #expect(EPUBFontIdentity.extract(fromValidatedSFNT: Data(valid.prefix(length))) == nil)
        }
        for field in [20, 24] {
            var bad = valid
            put32(UInt32.max, into: &bad, at: field)
            #expect(EPUBFontIdentity.extract(fromValidatedSFNT: bad) == nil)
        }
        var overlap = valid
        put32(12, into: &overlap, at: 20)
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: overlap) == nil)
        var duplicate = valid
        put32(0x6e616d65, into: &duplicate, at: 28)
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: duplicate) == nil)
        var missing = valid
        put32(0x74657374, into: &missing, at: 12)
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: missing) == nil)
        for magic in [UInt32(0x774f4646), 0x774f4632, 0x74746366, 0xffffffff] {
            var unsupported = valid
            put32(magic, into: &unsupported, at: 0)
            #expect(EPUBFontIdentity.extract(fromValidatedSFNT: unsupported) == nil)
        }
    }

    @Test func invalidNameHeadersOmitMetadataWithoutFailingStructuralFontGate() throws {
        for (offset, value) in [(0, 2), (2, 1025), (4, 0), (4, 0xffff)] {
            var names = makeName([.init(1, "Family")])
            put16(value, into: &names, at: offset)
            let data = makeSFNT(names)
            #expect(try EPUBAuthorStyles.verifyFontData(data, declaredMediaType: "font/ttf") == "font/ttf")
            #expect(EPUBFontIdentity.extract(fromValidatedSFNT: data) == nil)
        }
        var absentLanguageHeader = Data(repeating: 0, count: 6)
        put16(1, into: &absentLanguageHeader, at: 0)
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: makeSFNT(absentLanguageHeader)) == nil)
    }

    @Test func inputTableNameRecordAndLanguageBudgetsAreIndependent() {
        var data = makeSFNT(makeName([.init(1, "Family")]))
        put16(257, into: &data, at: 4)
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: data) == nil)
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: Data(repeating: 0, count: 8 * 1024 * 1024 + 1)) == nil)
        var names = makeName([.init(1, "Family")])
        names.append(Data(repeating: 0, count: 256 * 1024 + 1 - names.count))
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: makeSFNT(names)) == nil)
        #expect(extract(Array(repeating: Record(1, "A"), count: 1024))?.family == "A")
        #expect(extract(Array(repeating: Record(1, "A"), count: 1025)) == nil)
        let tagged: [Record] = [.init(1, "Family", language: 0x8000)]
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: makeSFNT(makeName(tagged, tags: Array(repeating: "en", count: 64))))?.family == "Family")
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: makeSFNT(makeName(tagged, tags: Array(repeating: "en", count: 65)))) == nil)
    }

    @Test func aggregateStringBudgetCountsUnsupportedAndRepeatedRecords() {
        // Aliased records prevent large allocation while declaring exactly 64 KiB.
        var records = [Record(1, "A")] + Array(repeating: Record(0, "B"), count: 64)
        var names = makeName(records)
        for index in 1..<65 {
            put16(index == 64 ? 1022 : 1024, into: &names, at: 6 + index * 12 + 8)
            put16(0, into: &names, at: 6 + index * 12 + 10)
        }
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: makeSFNT(names))?.family == "A")
        put16(1024, into: &names, at: 6 + 64 * 12 + 8) // 64 KiB + 2.
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: makeSFNT(names)) == nil)
        records.append(.init(4, bytes: Array(repeating: 65, count: 1026)))
        #expect(extract(records)?.family == "A")
        #expect(extract(records)?.fullName == nil)
    }

    @Test func safeNamesAndPostScriptRulesRejectPrivateOrOversizedValues() {
        for value in ["https://example.invalid/font", "/private/font.ttf", "C:\\private\\font.ttf",
                      "../font", "www.example", "A\nB", String(repeating: "a", count: 129),
                      String(repeating: "字", count: 43)] {
            #expect(extract([.init(1, value), .init(4, value), .init(5, value), .init(8, value)]) == nil)
        }
        #expect(extract([.init(1, String(repeating: "a", count: 128))])?.family?.utf8.count == 128)
        for value in ["Contains Space", "Bad(Name)", "中文", String(repeating: "A", count: 64)] {
            #expect(extract([.init(6, value)]) == nil)
        }
        #expect(extract([.init(6, String(repeating: "A", count: 63))])?.postScriptName?.count == 63)
        #expect(extract([.init(11, "https://example.invalid/vendor"), .init(12, "https://example.invalid/designer")]) == nil)
    }

    @Test func summaryRequiresExplicitNameConsentForEveryIdentityField() {
        let identity = EPUBFontIdentity(family: "HiddenFamily", fullName: "HiddenFull",
            postScriptName: "HiddenPS", version: "HiddenVersion", manufacturer: "HiddenVendor")
        let row = EPUBFontDiagnostic(family: "CSSAlias", source: .embedded, format: .ttf, outcome: .verified, identity: identity)
        let hidden = EPUBFontDiagnostic.summary([row])
        let visible = EPUBFontDiagnostic.summary([row], includeNames: true)
        for value in ["CSSAlias", "HiddenFamily", "HiddenFull", "HiddenPS", "HiddenVersion", "HiddenVendor"] {
            #expect(!hidden.contains(value))
            #expect(visible.contains(value))
        }
        #expect(visible.contains("manufacturer(unverified)="))
        #expect(!hidden.contains("internalFamily="))
        #expect(EPUBFontDiagnostic.bounded(Array(repeating: row, count: 200)).count == 1)
    }

    @Test func oldDiagnosticJSONAndNewIdentityRoundTripRemainCompatible() throws {
        let legacy = Data(#"{"family":"Alias","source":"embedded","format":"ttf","declaredFormat":"unspecified","declaredMIME":"unspecified","outcome":"verified"}"#.utf8)
        let row = try JSONDecoder().decode(EPUBFontDiagnostic.self, from: legacy)
        #expect(row.identity == nil)
        #expect(row.family == "Alias")
        let identity = EPUBFontIdentity(family: "Family", fullName: "Full", postScriptName: "Font-Regular", version: "Version 1", manufacturer: "Unverified Vendor")
        let current = EPUBFontDiagnostic(source: .embedded, outcome: .verified, identity: identity)
        #expect(try JSONDecoder().decode(EPUBFontDiagnostic.self, from: JSONEncoder().encode(current)) == current)
        #expect(Set([identity, identity]).count == 1)
        let null = Data(#"{"source":"embedded","format":"ttf","declaredFormat":"unspecified","declaredMIME":"unspecified","outcome":"verified","identity":null}"#.utf8)
        #expect(try JSONDecoder().decode(EPUBFontDiagnostic.self, from: null).identity == nil)
    }

    @Test func decodedIdentityCannotBypassSafeNamePrivacyPolicy() throws {
        let unsafe = Data(#"{"family":"https://example.invalid/font","fullName":"/private/book","postScriptName":"Bad Name","version":"www.example","manufacturer":"../private"}"#.utf8)
        let identity = try JSONDecoder().decode(EPUBFontIdentity.self, from: unsafe)
        #expect(identity == EPUBFontIdentity())
        let row = EPUBFontDiagnostic(source: .embedded, outcome: .verified, identity: identity)
        let summary = EPUBFontDiagnostic.summary([row], includeNames: true)
        for forbidden in ["https:", "/private", "www.example", "Bad Name"] { #expect(!summary.contains(forbidden)) }
    }

    @Test func dataWithNonzeroStartIndexUsesRelativeByteOffsets() {
        let font = makeSFNT(makeName([.init(1, "Slice")]))
        let padded = Data([0, 1, 2, 3]) + font
        let sliced = padded.dropFirst(4)
        #expect(EPUBFontIdentity.extract(fromValidatedSFNT: sliced)?.family == "Slice")
    }

    private struct Record {
        let id: Int
        let bytes: [UInt8]
        let platform: Int
        let encoding: Int
        let language: Int
        init(_ id: Int, _ text: String, platform: Int = 3, encoding: Int = 1, language: Int = 0x0409) {
            self.init(id, bytes: text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] },
                      platform: platform, encoding: encoding, language: language)
        }
        init(_ id: Int, bytes: [UInt8], platform: Int = 3, encoding: Int = 1, language: Int = 0x0409) {
            self.id = id; self.bytes = bytes; self.platform = platform; self.encoding = encoding; self.language = language
        }
    }

    private func extract(_ records: [Record]) -> EPUBFontIdentity? {
        EPUBFontIdentity.extract(fromValidatedSFNT: makeSFNT(makeName(records)))
    }

    private func makeName(_ records: [Record], tags: [String]? = nil) -> Data {
        let metadataLength = 6 + records.count * 12 + (tags.map { 2 + $0.count * 4 } ?? 0)
        var result = Data(repeating: 0, count: metadataLength)
        put16(tags == nil ? 0 : 1, into: &result, at: 0)
        put16(records.count, into: &result, at: 2)
        put16(metadataLength, into: &result, at: 4)
        var storage = Data()
        for (index, record) in records.enumerated() {
            let at = 6 + index * 12
            for (field, value) in [record.platform, record.encoding, record.language, record.id, record.bytes.count, storage.count].enumerated() {
                put16(value, into: &result, at: at + field * 2)
            }
            storage.append(contentsOf: record.bytes)
        }
        if let tags {
            let at = 6 + records.count * 12
            put16(tags.count, into: &result, at: at)
            for (index, tag) in tags.enumerated() {
                let bytes = tag.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }
                put16(bytes.count, into: &result, at: at + 2 + index * 4)
                put16(storage.count, into: &result, at: at + 4 + index * 4)
                storage.append(contentsOf: bytes)
            }
        }
        result.append(storage)
        return result
    }

    // Synthetic tables accepted by the existing structural gate, not renderable font fixtures.
    private func makeSFNT(_ names: Data, otf: Bool = false) -> Data {
        var head = Data(repeating: 0, count: 54)
        put32(0x5f0f3cf5, into: &head, at: 12)
        let tables: [(String, Data)] = [("name", names), ("head", head), (otf ? "CFF " : "glyf", Data([0]))]
        var result = Data(repeating: 0, count: 60)
        put32(otf ? 0x4f54544f : 0x00010000, into: &result, at: 0)
        put16(tables.count, into: &result, at: 4)
        for (index, table) in tables.enumerated() {
            let at = 12 + index * 16
            for (offset, byte) in table.0.utf8.enumerated() { result[at + offset] = byte }
            put32(UInt32(result.count), into: &result, at: at + 8)
            put32(UInt32(table.1.count), into: &result, at: at + 12)
            result.append(table.1)
            while !result.count.isMultiple(of: 4) { result.append(0) }
        }
        return result
    }

    private func put16(_ value: Int, into data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 8) & 255); data[offset + 1] = UInt8(value & 255)
    }

    private func put32(_ value: UInt32, into data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8((value >> (24 - index * 8)) & 255) }
    }
}

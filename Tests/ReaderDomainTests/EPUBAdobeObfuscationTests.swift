import Foundation
import Testing
@testable import ReaderDomain

struct EPUBAdobeObfuscationTests {
    private let urn = "urn:uuid:00112233-4455-6677-8899-aabbccddeeff"
    private let key = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                            0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])

    @Test func adobeSelectsFirstUUIDURNNotUniqueIdentifier() throws {
        let document = opf("""
            <dc:identifier id='isbn'>urn:isbn:9780000000000</dc:identifier>
            <dc:identifier id='first'>\(urn)</dc:identifier>
            <dc:identifier id='chosen'>urn:uuid:ffffffff-ffff-ffff-ffff-ffffffffffff</dc:identifier>
            """)
        let original = Data(document)
        #expect(try EPUBFontObfuscation.adobeKey(opfData: document, limit: 8192) == key)
        let idpf = try #require(EPUBFontObfuscation.idpfKey(opfData: document, limit: 8192))
        #expect(idpf.count == 20)
        #expect(idpf != key)
        #expect(document == original)
        #expect(try EPUBFontObfuscation.adobeKey(opfData: opf("<dc:identifier>\(urn)</dc:identifier>", unique: ""), limit: 8192) == key)
    }

    @Test func adobeUUIDBytesAreBigEndianAndCaseInsensitiveWithOuterXMLWhitespace() throws {
        let document = opf("<dc:identifier> &#9;&#10;URN:UUID:00112233-4455-6677-8899-AABBCCDDEEFF&#13; </dc:identifier>")
        #expect(try EPUBFontObfuscation.adobeKey(opfData: document, limit: 8192) == key)
        let split = opf("<dc:identifier>urn:uuid:00112233-<![CDATA[4455-6677-8899-aabbccddeeff]]></dc:identifier>")
        #expect(try EPUBFontObfuscation.adobeKey(opfData: split, limit: 8192) == key)
    }

    @Test func adobeMissingOrInvalidUUIDDoesNotUseIDPFOrLaterUUID() throws {
        for value in ["urn:uuid:", "urn:uuid:not-a-uuid", "urn:uuid:00112233445566778899aabbccddeeff",
                      "urn:uuid:{00112233-4455-6677-8899-aabbccddeeff}",
                      "urn:uuid:00112233_4455-6677-8899-aabbccddeeff",
                      "urn:uuid:00112233-4455-6677-8899-aabbccddeefg",
                      "urn:uuid:00112233-4455-6677-8899-aabbccddeef",
                      "urn:uuid:00112233-4455-6677-8899-aabbccddeeff0",
                      "urn:uuid:00112233-4455-6677-8899-aabbccdd eef",
                      "urn:uuid:00112233-4455-6677-8899-aabbccddeeff&#160;"] {
            let document = opf("<dc:identifier>\(value)</dc:identifier><dc:identifier id='chosen'>\(urn)</dc:identifier>")
            #expect(try EPUBFontObfuscation.adobeKey(opfData: document, limit: 8192) == nil)
        }
        for body in ["", "<dc:identifier id='chosen'>isbn-only</dc:identifier>",
                     "<dc:identifier>00112233-4455-6677-8899-aabbccddeeff</dc:identifier>",
                     "<dc:identifier>\(urn)<b/></dc:identifier><dc:identifier>\(urn)</dc:identifier>"] {
            #expect(try EPUBFontObfuscation.adobeKey(opfData: opf(body), limit: 8192) == nil)
        }
    }

    @Test func adobeSelectsOnlyDirectDublinCoreIdentifiersUnderOPFMetadata() throws {
        let decoys = """
            <identifier>urn:uuid:ffffffff-ffff-ffff-ffff-ffffffffffff</identifier>
            <dc:identifier xmlns:dc='urn:wrong'>urn:uuid:ffffffff-ffff-ffff-ffff-ffffffffffff</dc:identifier>
            <wrapper><dc:identifier>urn:uuid:ffffffff-ffff-ffff-ffff-ffffffffffff</dc:identifier></wrapper>
            <dc:identifier>\(urn)</dc:identifier>
            """
        #expect(try EPUBFontObfuscation.adobeKey(opfData: opf(decoys), limit: 8192) == key)
        let prefixed = Data("<p:package xmlns:p='http://www.idpf.org/2007/opf'><p:metadata><identifier xmlns='http://purl.org/dc/elements/1.1/'>\(urn)</identifier></p:metadata></p:package>".utf8)
        #expect(try EPUBFontObfuscation.adobeKey(opfData: prefixed, limit: 8192) == key)
        for xml in ["<package xmlns='urn:wrong'><metadata><dc:identifier xmlns:dc='http://purl.org/dc/elements/1.1/'>\(urn)</dc:identifier></metadata></package>",
                    "<package xmlns='http://www.idpf.org/2007/opf'><metadata xmlns='urn:wrong'><dc:identifier xmlns:dc='http://purl.org/dc/elements/1.1/'>\(urn)</dc:identifier></metadata></package>"] {
            #expect(try EPUBFontObfuscation.adobeKey(opfData: Data(xml.utf8), limit: 8192) == nil)
        }
    }

    @Test func adobeIdentifierParsingKeepsXMLAndTextBudgets() throws {
        #expect(throws: EPUBError.limitExceeded) {
            try EPUBFontObfuscation.adobeKey(opfData: opf("<dc:identifier>\(urn)</dc:identifier>"), limit: 16)
        }
        let oversizedUUID = "<dc:identifier>urn:uuid:\(String(repeating: "a", count: 4096))</dc:identifier>"
        let laterUUID = "<dc:identifier>\(urn)</dc:identifier>"
        #expect(try EPUBFontObfuscation.adobeKey(opfData: opf(oversizedUUID + laterUUID), limit: 16384) == nil)
        let unrelated = "<dc:identifier>isbn:\(String(repeating: "a", count: 8192))</dc:identifier>"
        #expect(try EPUBFontObfuscation.adobeKey(opfData: opf(unrelated + laterUUID), limit: 16384) == key)
        let whitespace = String(repeating: " ", count: 5000)
        #expect(try EPUBFontObfuscation.adobeKey(opfData: opf("<dc:identifier>\(whitespace)\(urn)</dc:identifier>"), limit: 8192) == key)
        #expect(throws: EPUBError.invalidPackage) {
            try EPUBFontObfuscation.adobeKey(opfData: Data("<package>".utf8), limit: 8192)
        }
    }

    @Test func adobeKnownAnswerUsesSixteenByteRepeatedKey() throws {
        // Fixed byte vector, not expected bytes generated by the implementation under test.
        let source = Data(repeating: 0xff, count: 32)
        let expected = Data([0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88,
                             0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00,
                             0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88,
                             0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00])
        #expect(try EPUBFontObfuscation.restoreAdobe(source, key: key) == expected)
        #expect(try EPUBFontObfuscation.restoreAdobe(expected, key: key) == source)
        #expect(source == Data(repeating: 0xff, count: 32))
    }

    @Test func adobeRestoresExactly1024BytesAndPreservesTail() throws {
        for length in [1023, 1024, 1025, 1040, 1200] {
            let source = Data(repeating: 0, count: length)
            let original = Data(source)
            let restored = try EPUBFontObfuscation.restoreAdobe(source, key: key)
            let prefix = Data(Array(repeating: Array(key), count: 64).flatMap { $0 }.prefix(min(length, 1024)))
            #expect(restored.prefix(min(length, 1024)) == prefix)
            #expect(restored.dropFirst(1024) == source.dropFirst(1024))
            #expect(restored.count == source.count)
            #expect(try EPUBFontObfuscation.restoreAdobe(restored, key: key) == source)
            #expect(source == original)
        }
    }

    @Test func adobeHandlesShortInputAndNonzeroDataSliceIndices() throws {
        for length in [1, 3, 15, 16, 17] {
            let source = Data(repeating: 0, count: length)
            let expected = Data((Array(key) + Array(key)).prefix(length))
            #expect(try EPUBFontObfuscation.restoreAdobe(source, key: key) == expected)
        }
        let backing = Data([0xaa, 0xbb, 0xff, 0xff, 0xff, 0xcc])
        let source = backing[2..<5]
        let keyBacking = Data([0xaa, 0xbb]) + key
        let keySlice = keyBacking[2..<18]
        #expect(source.startIndex == 2)
        #expect(keySlice.startIndex == 2)
        #expect(try EPUBFontObfuscation.restoreAdobe(source, key: keySlice) == Data([0xff, 0xee, 0xdd]))
        #expect(backing == Data([0xaa, 0xbb, 0xff, 0xff, 0xff, 0xcc]))
        #expect(keyBacking == Data([0xaa, 0xbb]) + key)
    }

    @Test func adobeRejectsEmptyInputWrongKeyLengthsAndOversizedFonts() throws {
        #expect(throws: EPUBError.corruptResource) { try EPUBFontObfuscation.restoreAdobe(Data(), key: key) }
        for length in [0, 15, 17, 20] {
            #expect(throws: EPUBError.corruptResource) {
                try EPUBFontObfuscation.restoreAdobe(Data([1]), key: Data(repeating: 1, count: length))
            }
        }
        #expect(throws: EPUBError.limitExceeded) {
            try EPUBFontObfuscation.restoreAdobe(Data(repeating: 0, count: EPUBAuthorStyles.maxFontBytes + 1), key: key)
        }
    }

    @Test func adobeWrongSixteenByteKeyRequiresPostRestoreStructureValidation() throws {
        let source = structuralSFNT()
        #expect(try EPUBAuthorStyles.verifyFontData(source, declaredMediaType: "font/ttf") == "font/ttf")
        let obfuscated = try EPUBFontObfuscation.restoreAdobe(source, key: key)
        let saved = Data(obfuscated)
        let restored = try EPUBFontObfuscation.restoreAdobe(obfuscated, key: key)
        #expect(restored == source)
        #expect(try EPUBAuthorStyles.verifyFontData(restored, declaredMediaType: "font/ttf") == "font/ttf")
        let wrong = try EPUBFontObfuscation.restoreAdobe(obfuscated, key: Data(repeating: 0xff, count: 16))
        #expect(wrong != source)
        #expect(throws: EPUBError.corruptResource) { try EPUBAuthorStyles.verifyFontData(wrong, declaredMediaType: "font/ttf") }
        #expect(obfuscated == saved)
        #expect(source == structuralSFNT())
    }

    @Test func adobeAlgorithmIdentifierIsExactAndUnknownEncryptionStillRejected() throws {
        let manifest = ["OPS/font.ttf": "font/ttf"]
        let entries: Set<String> = ["OPS/font.ttf"]
        let exact = "http://ns.adobe.com/pdf/enc#RC"
        #expect(try EPUBFontObfuscation.declarations(data: encryption(exact), manifest: manifest, entries: entries, limit: 8192) == ["OPS/font.ttf": .adobe])
        for algorithm in ["https://ns.adobe.com/pdf/enc#RC", "http://ns.adobe.com/pdf/enc#rc", exact + " ", "http://ns.adobe.com/adept", "urn:unknown"] {
            #expect(throws: EPUBError.unsupportedContent) {
                try EPUBFontObfuscation.declarations(data: encryption(algorithm), manifest: manifest, entries: entries, limit: 8192)
            }
        }
    }

    private func opf(_ body: String, unique: String = " unique-identifier='chosen'") -> Data {
        Data("<package xmlns='http://www.idpf.org/2007/opf'\(unique)><metadata xmlns:dc='http://purl.org/dc/elements/1.1/'>\(body)</metadata></package>".utf8)
    }

    private func encryption(_ algorithm: String) -> Data {
        Data("<encryption xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><EncryptedData xmlns='http://www.w3.org/2001/04/xmlenc#'><EncryptionMethod Algorithm='\(algorithm)'/><CipherData><CipherReference URI='OPS/font.ttf'/></CipherData></EncryptedData></encryption>".utf8)
    }

    /// Minimal original structural fixture only; not proof of rendering or authentic glyphs.
    private func structuralSFNT() -> Data {
        var data = Data(repeating: 0, count: 116)
        data.replaceSubrange(0..<12, with: [0, 1, 0, 0, 0, 2, 0, 32, 0, 1, 0, 0])
        data.replaceSubrange(12..<16, with: Array("glyf".utf8))
        data[23] = 100; data[27] = 16
        data.replaceSubrange(28..<32, with: Array("head".utf8))
        data[39] = 44; data[43] = 54
        data.replaceSubrange(56..<60, with: [0x5f, 0x0f, 0x3c, 0xf5])
        return data
    }
}

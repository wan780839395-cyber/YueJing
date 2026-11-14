import CryptoKit
import Foundation
import Testing
import ZIPFoundation
@testable import ReaderDomain

struct EPUBFontCompletionTests {
    @Test func fontDiagnosticNamesAreOptInBoundedAndLegacyCompatible() throws {
        let row = EPUBFontDiagnostic(family: "Synthetic Serif", localName: "Synthetic Local", source: .local, outcome: .localOmitted)
        #expect(!EPUBFontDiagnostic.summary([row]).contains("Synthetic"))
        #expect(EPUBFontDiagnostic.summary([row], includeNames: true).contains("Synthetic Local"))
        for name in ["/private/books/title", "https://example.invalid/font", "a\nb", String(repeating: "a", count: 129), "../secret", "www.example"] {
            #expect(EPUBFontDiagnostic.safeName(name) == nil)
        }
        #expect(EPUBFontDiagnostic.safeName("思源宋体 SC") == "思源宋体 SC")
        #expect(EPUBFontDiagnostic.formatCategory("font/ttf") == .ttf)
        #expect(EPUBFontDiagnostic.formatCategory("font/otf") == .otf)
        let rows = (0..<200).map { EPUBFontDiagnostic(family: "Face\($0)", source: .embedded, outcome: .verified) }
        let compatibility = EPUBStyleCompatibility(fontDiagnostics: rows + rows)
        #expect(compatibility.fontDiagnostics.count == 128)
        #expect(try JSONDecoder().decode(EPUBStyleCompatibility.self, from: JSONEncoder().encode(compatibility)) == compatibility)
        let legacy = try JSONDecoder().decode(EPUBStyleCompatibility.self, from: Data("{\"issues\":[],\"usesReaderLayout\":false}".utf8))
        #expect(legacy.fontDiagnostics.isEmpty)
    }

    @Test func idpfKeyUsesSelectedIdentifierExactXMLWhitespaceAndRejectsAmbiguity() throws {
        func opf(_ content: String) -> Data {
            Data("<package xmlns='http://www.idpf.org/2007/opf' unique-identifier='chosen'><metadata xmlns:dc='http://purl.org/dc/elements/1.1/'>\(content)</metadata></package>".utf8)
        }
        let key = try #require(EPUBFontObfuscation.idpfKey(opfData: opf("<dc:identifier id='other'>wrong</dc:identifier><dc:identifier id='chosen'> a &#9;b&#13;&#10;c </dc:identifier>"), limit: 8192))
        #expect(key.map { String(format: "%02x", $0) }.joined() == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(try EPUBFontObfuscation.idpfKey(opfData: opf("<dc:identifier id='chosen'>a&#160;bc</dc:identifier>"), limit: 8192) != key)
        for body in ["<dc:identifier id='other'>abc</dc:identifier>",
                     "<dc:identifier id='chosen'>abc</dc:identifier><dc:identifier id='chosen'>abc</dc:identifier>",
                     "<dc:identifier id='chosen'><b>abc</b></dc:identifier>",
                     "<identifier id='chosen'>abc</identifier>"] {
            #expect(try EPUBFontObfuscation.idpfKey(opfData: opf(body), limit: 8192) == nil)
        }
        let source = Data((0..<1200).map { UInt8($0 % 251) })
        let restored = try EPUBFontObfuscation.restoreIDPF(source, key: key)
        #expect(restored.prefix(1040) != source.prefix(1040))
        #expect(restored.suffix(160) == source.suffix(160))
        #expect(try EPUBFontObfuscation.restoreIDPF(restored, key: key) == source)
        #expect(try EPUBFontObfuscation.restoreIDPF(Data([1, 2, 3]), key: key).count == 3)
        #expect(throws: EPUBError.corruptResource) { try EPUBFontObfuscation.restoreIDPF(source, key: Data([1])) }
    }

    @Test func packageWOFFAndIDPFProduceVerifiedPrivateSFNTWithoutChangingArchiveOrNodes() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let woff = makeWOFF()
        let sfnt = try EPUBWOFFDecoder.decode(woff)
        #expect(try EPUBAuthorStyles.verifyFontData(sfnt, declaredMediaType: "font/ttf") == "font/ttf")
        let key = Data(Insecure.SHA1.hash(data: Data("urn:uuid:synthetic-epub3".utf8)))
        for (index, source) in [woff, try EPUBFontObfuscation.restoreIDPF(sfnt, key: key), try EPUBFontObfuscation.restoreIDPF(woff, key: key)].enumerated() {
            let archive = root.appendingPathComponent("source\(index).epub")
            try writeBook(archive, font: source, mediaType: index == 1 ? "font/otf" : "font/woff",
                          encryption: index == 0 ? nil : "http://www.idpf.org/2008/embedding")
            let original = try Data(contentsOf: archive)
            let destination = root.appendingPathComponent("prepared\(index)")
            let package = try EPUBPackageParser.parse(archiveURL: archive, destination: destination)
            let resource = try #require(package.resource(at: "OPS/Fonts/font.woff"))
            let derived = try Data(contentsOf: destination.appendingPathComponent(resource.path))
            #expect(derived == sfnt)
            #expect(resource.mediaType == "font/ttf")
            #expect(resource.sha256 == EPUBResourceStore.digest(derived))
            #expect(resource.byteCount == derived.count)
            #expect(try Data(contentsOf: archive) == original)
            #expect(package.sourceSHA256 == EPUBResourceStore.digest(original))
            #expect(package.textNodes["OPS/Text/c.xhtml"] == ["Synthetic text"])
            #expect(package.styleCompatibility?.issues.contains(.fontUnavailable) == false)
            #expect(package.styleCompatibility?.fontDiagnostics.contains(where: { $0.outcome == (index == 0 ? .convertedWOFF : .restoredIDPF) }) == true)
            #expect(!EPUBFontDiagnostic.summary(package.styleCompatibility?.fontDiagnostics ?? []).contains("Synthetic Body"))
        }
    }

    @Test func packageFontOmissionsDiagnoseWOFF2LocalMissingAndSubsetWithoutCapabilities() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let samples: [(Data, String, String, EPUBFontDiagnostic.Outcome)] = [
            (Data([0x77, 0x4f, 0x46, 0x32] + Array(repeating: 0, count: 44)), "font/woff2", "", .unsupportedFormat),
            (makeWOFF(), "font/woff", "unicode-range: U+110000;", .unsupportedSubset)
        ]
        for (index, sample) in samples.enumerated() {
            let archive = root.appendingPathComponent("omit\(index).epub")
            try writeBook(archive, font: sample.0, mediaType: sample.1, extraDescriptor: sample.2)
            let package = try EPUBPackageParser.parse(archiveURL: archive, destination: root.appendingPathComponent("omit\(index)"))
            #expect(package.resource(at: "OPS/Fonts/font.woff") == nil)
            #expect(package.styleCompatibility?.fontDiagnostics.contains(where: { $0.outcome == sample.3 }) == true)
            #expect(package.styleCompatibility?.issues.contains(.fontUnavailable) == true)
            #expect(package.textNodes["OPS/Text/c.xhtml"] == ["Synthetic text"])
        }
        let legacyFont = try EPUBWOFFDecoder.decode(makeWOFF())
        let legacyArchive = root.appendingPathComponent("legacy-subset.epub")
        try writeBook(legacyArchive, font: legacyFont, mediaType: "font/ttf", extraDescriptor: "unicode-range: U+0041-005A;")
        let legacyDestination = root.appendingPathComponent("legacy-subset")
        let replacement = try EPUBPackageParser.parse(archiveURL: legacyArchive, destination: legacyDestination)
        let retained = try #require(replacement.resource(at: "OPS/Fonts/font.woff"))
        #expect(retained.sha256 == EPUBResourceStore.digest(legacyFont))
        let sanitized = String(decoding: try Data(contentsOf: legacyDestination.appendingPathComponent("OPS/Text/c.xhtml")), as: UTF8.self)
        #expect(sanitized.contains("@font-face") && sanitized.contains("unicode-range: U+41-5A"))
        #expect(replacement.styleCompatibility?.issues.contains(.fontUnavailable) == false)
        let previous = EPUBPackage(sourceSHA256: replacement.sourceSHA256, title: replacement.title,
            spine: replacement.spine, navigation: replacement.navigation, resources: replacement.resources,
            textNodes: replacement.textNodes, coverPath: replacement.coverPath, authorStyleRevision: 4)
        try EPUBAuthorStyleMigration.validate(previous: previous, replacement: replacement)
        let result = try EPUBAuthorStyles.sanitizeStylesheetWithCompatibility(
            "@font-face{font-family:Missing;src:local('Synthetic Local'),url(absent.ttf)}",
            sourcePath: "OPS/style.css", documentPath: "OPS/c.xhtml", manifestByPath: [:], destination: root)
        #expect(result.referencedFonts.isEmpty)
        #expect(result.styleCompatibility.fontDiagnostics.contains(where: { $0.source == .local && $0.localName == "Synthetic Local" }))
        #expect(result.styleCompatibility.fontDiagnostics.contains(where: { $0.source == .missing && $0.outcome == .missingFile }))
    }

    @Test func packageWOFFSubsetKeepsRangeDigestArchiveAndCoordinates() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("subset.epub")
        let woff = makeWOFF(), sfnt = try EPUBWOFFDecoder.decode(woff)
        try writeBook(archive, font: woff, mediaType: "font/woff", extraDescriptor: "unicode-range: U+4??, U+0041-005A;")
        let original = try Data(contentsOf: archive)
        let destination = root.appendingPathComponent("subset")
        let package = try EPUBPackageParser.parse(archiveURL: archive, destination: destination)
        let resource = try #require(package.resource(at: "OPS/Fonts/font.woff"))
        #expect(resource.mediaType == "font/ttf" && resource.sha256 == EPUBResourceStore.digest(sfnt))
        #expect(try Data(contentsOf: destination.appendingPathComponent(resource.path)) == sfnt)
        #expect(try Data(contentsOf: archive) == original)
        #expect(package.textNodes["OPS/Text/c.xhtml"] == ["Synthetic text"])
        #expect(package.styleCompatibility?.issues.contains(.fontUnavailable) == false)
        let css = String(decoding: try Data(contentsOf: destination.appendingPathComponent("OPS/Text/c.xhtml")), as: UTF8.self)
        #expect(css.contains("unicode-range: U+41-5A,U+400-4FF"))
        let previous = EPUBPackage(sourceSHA256: package.sourceSHA256, title: package.title,
            spine: package.spine, navigation: package.navigation,
            resources: package.resources.filter { $0.path != resource.path }, textNodes: package.textNodes,
            coverPath: package.coverPath, authorStyleRevision: 5)
        try EPUBAuthorStyleMigration.validate(previous: previous, replacement: package)
    }

    @Test func fontPreparationRejectsIntegrityDriftAndUnknownEncryption() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = makeWOFF()
        let entry = EPUBExtractedEntry(path: "font.woff", byteCount: data.count, sha256: String(repeating: "0", count: 64), crc32: 0, compressionMethod: 0)
        try data.write(to: root.appendingPathComponent("font.woff"))
        let preparation = EPUBFontPreparation(entries: [entry.path: entry], algorithms: [:], idpfKey: nil)
        #expect(throws: EPUBError.corruptResource) { try preparation.verify(path: entry.path, under: root, declaredMediaType: "font/woff") }
        #expect(preparation.resources.isEmpty)
        #expect(throws: EPUBError.unsafePath) { try preparation.verify(path: "../outside.ttf", under: root, declaredMediaType: "font/ttf") }
        #expect(try Data(contentsOf: root.appendingPathComponent(entry.path)) == data)
        let archive = root.appendingPathComponent("unknown.epub")
        try writeBook(archive, font: data, mediaType: "font/woff", encryption: "https://example.invalid/encryption")
        #expect(throws: EPUBError.unsupportedContent) {
            try EPUBPackageParser.parse(archiveURL: archive, destination: root.appendingPathComponent("unknown"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unknown").path))
    }

    @Test func packageAdobeRestoresSFNTAndWOFFWithIndependentKeyAndPreservesCoordinates() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data([0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
        let identifiers = "<dc:identifier id='chosen'>not-the-adobe-key</dc:identifier><dc:identifier>urn:uuid:00112233-4455-6677-8899-aabbccddeeff</dc:identifier><dc:identifier>urn:uuid:11111111-1111-1111-1111-111111111111</dc:identifier>"
        let woff = makeWOFF(), sfnt = try EPUBWOFFDecoder.decode(woff)
        for (index, plain) in [sfnt, woff].enumerated() {
            let archive = root.appendingPathComponent("adobe\(index).epub")
            try writeBook(archive, font: EPUBFontObfuscation.restoreAdobe(plain, key: key),
                mediaType: index == 0 ? "font/ttf" : "font/woff", encryption: "http://ns.adobe.com/pdf/enc#RC", identifiers: identifiers)
            let original = try Data(contentsOf: archive), destination = root.appendingPathComponent("adobe\(index)")
            let package = try EPUBPackageParser.parse(archiveURL: archive, destination: destination)
            let resource = try #require(package.resource(at: "OPS/Fonts/font.woff"))
            #expect(try Data(contentsOf: destination.appendingPathComponent(resource.path)) == sfnt)
            #expect(resource.mediaType == "font/ttf" && resource.sha256 == EPUBResourceStore.digest(sfnt))
            #expect(package.styleCompatibility?.fontDiagnostics.contains(where: { $0.outcome == .restoredAdobe }) == true)
            #expect(package.styleCompatibility?.issues.contains(.fontUnavailable) == false)
            #expect(package.textNodes["OPS/Text/c.xhtml"] == ["Synthetic text"])
            #expect(try Data(contentsOf: archive) == original)
            let previous = EPUBPackage(sourceSHA256: package.sourceSHA256, title: package.title,
                spine: package.spine, navigation: package.navigation,
                resources: package.resources.filter { $0.path != resource.path }, textNodes: package.textNodes,
                coverPath: package.coverPath, authorStyleRevision: 5)
            try EPUBAuthorStyleMigration.validate(previous: previous, replacement: package)
        }
    }

    @Test func packageAdobeMissingMalformedOrWrongKeyNeverPublishesFont() throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 0x11, count: 16)
        let encrypted = try EPUBFontObfuscation.restoreAdobe(EPUBWOFFDecoder.decode(makeWOFF()), key: key)
        let cases: [(String, EPUBFontDiagnostic.Outcome)] = [
            ("<dc:identifier id='chosen'>isbn-only</dc:identifier>", .obfuscationKeyUnavailable),
            ("<dc:identifier>urn:uuid:invalid</dc:identifier><dc:identifier>urn:uuid:11111111-1111-1111-1111-111111111111</dc:identifier>", .obfuscationKeyUnavailable),
            ("<dc:identifier>urn:uuid:22222222-2222-2222-2222-222222222222</dc:identifier>", .invalidStructure)
        ]
        for (index, sample) in cases.enumerated() {
            let archive = root.appendingPathComponent("badkey\(index).epub")
            try writeBook(archive, font: encrypted, mediaType: "font/ttf", encryption: "http://ns.adobe.com/pdf/enc#RC", identifiers: sample.0)
            let original = try Data(contentsOf: archive)
            let package = try EPUBPackageParser.parse(archiveURL: archive, destination: root.appendingPathComponent("badkey\(index)"))
            #expect(package.resource(at: "OPS/Fonts/font.woff") == nil)
            #expect(package.styleCompatibility?.fontDiagnostics.contains(where: { $0.outcome == sample.1 }) == true)
            #expect(package.styleCompatibility?.issues.contains(.fontUnavailable) == true)
            #expect(package.textNodes["OPS/Text/c.xhtml"] == ["Synthetic text"])
            #expect(try Data(contentsOf: archive) == original)
        }
    }

    @Test func fontPreparationCancellationDoesNotWriteOrPublish() async throws {
        let root = try EPUBTestSupport.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = makeWOFF()
        let url = root.appendingPathComponent("font.woff")
        try source.write(to: url)
        let cancelledWithoutPublication = await Task.detached {
            let entry = EPUBExtractedEntry(path: "font.woff", byteCount: source.count,
                sha256: EPUBResourceStore.digest(source), crc32: 0, compressionMethod: 0)
            let preparation = EPUBFontPreparation(entries: [entry.path: entry], algorithms: [:], idpfKey: nil)
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try preparation.verify(path: entry.path, under: root, declaredMediaType: "font/woff")
                return false
            } catch is CancellationError { return preparation.resources.isEmpty && preparation.identities.isEmpty }
            catch { return false }
        }.value
        #expect(cancelledWithoutPublication)
        #expect(try Data(contentsOf: url) == source)
    }

    private func writeBook(_ url: URL, font: Data, mediaType: String, encryption: String? = nil, extraDescriptor: String = "", identifiers: String? = nil) throws {
        let xhtml = "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Synthetic</title><style>@font-face{font-family:'Synthetic Body';src:url(../Fonts/font.woff);\(extraDescriptor)}p{font-family:'Synthetic Body'}</style></head><body><p>Synthetic text</p></body></html>"
        var extra = [("OPS/Fonts/font.woff", font)]
        if let encryption {
            extra.append(("META-INF/encryption.xml", Data("<encryption xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><EncryptedData xmlns='http://www.w3.org/2001/04/xmlenc#'><EncryptionMethod Algorithm='\(encryption)'/><CipherData><CipherReference URI='OPS/Fonts/font.woff'/></CipherData></EncryptedData></encryption>".utf8)))
        }
        if let identifiers {
            let opf = "<package xmlns='http://www.idpf.org/2007/opf' version='3.0' unique-identifier='chosen'><metadata xmlns:dc='http://purl.org/dc/elements/1.1/'>\(identifiers)<dc:title>Synthetic</dc:title></metadata><manifest><item id='c' href='Text/c.xhtml' media-type='application/xhtml+xml'/><item id='font' href='Fonts/font.woff' media-type='\(mediaType)'/></manifest><spine><itemref idref='c'/></spine></package>"
            var entries = [(path: "mimetype", data: Data("application/epub+zip".utf8), method: CompressionMethod.none)]
            entries.append(("META-INF/container.xml", Data("<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container' version='1.0'><rootfiles><rootfile full-path='OPS/book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>".utf8), .none))
            entries.append(("OPS/book.opf", Data(opf.utf8), .none))
            entries.append(("OPS/Text/c.xhtml", Data(xhtml.utf8), .none))
            entries.append(contentsOf: extra.map { ($0.0, $0.1, .none) })
            try EPUBTestSupport.writeZIP(at: url, entries: entries)
            return
        }
        try EPUBTestSupport.writeEPUB3(at: url, chapters: [.init(id: "c", path: "Text/c.xhtml", title: "Synthetic", bodyXHTML: xhtml)],
            manifestExtra: "<item id='font' href='Fonts/font.woff' media-type='\(mediaType)'/>", extraEntries: extra)
    }

    /// Original structural fixture, not a font claimed to render real glyphs.
    private func makeWOFF() -> Data {
        var head = Data(repeating: 0, count: 54)
        head.replaceSubrange(12..<16, with: [0x5f, 0x0f, 0x3c, 0xf5])
        let tables = [("glyf", Data(repeating: 1, count: 16)), ("head", head)]
        var result = Data(repeating: 0, count: 84)
        func set32(_ at: Int, _ value: UInt32) {
            for i in 0..<4 { result[at + i] = UInt8(truncatingIfNeeded: value >> (24 - i * 8)) }
        }
        set32(0, 0x774f4646); set32(4, 0x00010000); result[13] = 2; set32(16, 116)
        for (index, table) in tables.enumerated() {
            let record = 44 + index * 20
            result.replaceSubrange(record..<(record + 4), with: table.0.utf8)
            set32(record + 4, UInt32(result.count)); set32(record + 8, UInt32(table.1.count)); set32(record + 12, UInt32(table.1.count))
            var padded = table.1
            while padded.count % 4 != 0 { padded.append(0) }
            var checksum: UInt32 = 0
            for offset in stride(from: 0, to: padded.count, by: 4) {
                var word: UInt32 = 0
                for i in 0..<4 { word = (word << 8) | UInt32(padded[offset + i]) }
                checksum = checksum &+ word
            }
            set32(record + 16, checksum); result.append(padded)
        }
        set32(8, UInt32(result.count))
        return result
    }
}

import CryptoKit
import Foundation
import Testing
import ZIPFoundation
@testable import ReaderDomain

struct EPUBArchiveTests {
    @Test func epubArchiveExtractsStoredAndDeflatedEntriesWithVerifiedDigests() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let zipURL = root.appendingPathComponent("valid.epub")
        let storedPayload = Data("application/epub+zip".utf8)
        let deflatedPayload = Data(String(repeating: "章节正文内容-UTF8-测试段落\n", count: 256).utf8)
        let nfdName = "OPS/caf\u{0065}\u{0301}.xhtml"
        let nfcName = "OPS/caf\u{00E9}.xhtml"

        try EPUBTestSupport.writeZIP(
            at: zipURL,
            entries: [
                ("mimetype", storedPayload, .none),
                ("OPS/", Data(), .none),
                ("OPS/chapter1.xhtml", deflatedPayload, .deflate),
                (nfdName, Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"/>".utf8), .deflate)
            ]
        )

        let dest = root.appendingPathComponent("extracted", isDirectory: true)
        let extraction = try EPUBArchive.extract(archiveURL: zipURL, to: dest)
        let rawArchiveBytes = try Data(contentsOf: zipURL)
        let expectedSourceSHA = SHA256.hash(data: rawArchiveBytes).map { String(format: "%02x", $0) }.joined()

        #expect(extraction.sourceSHA256 == expectedSourceSHA)
        #expect(extraction.compressedByteCount == rawArchiveBytes.count)
        #expect(extraction.entries.count == 3)
        #expect(extraction.entries["mimetype"]?.compressionMethod == 0)
        #expect(extraction.entries["mimetype"]?.byteCount == storedPayload.count)
        #expect(extraction.entries["OPS/chapter1.xhtml"]?.compressionMethod == 8)
        #expect(extraction.entries["OPS/chapter1.xhtml"]?.byteCount == deflatedPayload.count)
        #expect(extraction.entries["OPS/chapter1.xhtml"]?.sha256 == EPUBResourceStore.digest(deflatedPayload))
        #expect(extraction.entries[nfcName] != nil)
        #expect( try Data(contentsOf: dest.appendingPathComponent("OPS/chapter1.xhtml")) == deflatedPayload)
    }

    @Test func epubArchiveRejectsUnsafePathsAndEncodedTraversals() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let badPaths = [
            "",
            "/OPS/one.xhtml",
            "OPS/one.xhtml/",
            "../outside.xhtml",
            "OPS/../two.xhtml",
            "OPS/./two.xhtml",
            "OPS//two.xhtml",
            "OPS\\two.xhtml",
            "C:OPS/two.xhtml",
            "http://example.com/two.xhtml",
            "OPS/two.xhtml?query=1",
            "OPS/two.xhtml#frag",
            "OPS/null\u{0000}.xhtml",
            "OPS/null%00.xhtml",
            "OPS/sep%2Fevil.xhtml",
            "OPS/sep%5Cevil.xhtml",
            "OPS/%2e%2e/evil.xhtml",
            "OPS/colon%3Aevil.xhtml",
            "OPS/bad%ZZ.xhtml",
            "OPS/bad%2"
        ]
        for bad in badPaths {
            #expect(throws: EPUBError.unsafePath) {
                _ = try EPUBResourcePath.canonical(bad)
            }
            if !bad.isEmpty && !bad.hasSuffix("/") {
                let zipURL = root.appendingPathComponent(UUID().uuidString + ".epub")
                let data = EPUBTestSupport.craftRawZIP(entries: [RawZIPEntrySpec(cdPath: bad)])
                try data.write(to: zipURL)
                let dest = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                #expect(throws: EPUBError.unsafePath) {
                    _ = try EPUBArchive.extract(archiveURL: zipURL, to: dest)
                }
                #expect(!FileManager.default.fileExists(atPath: dest.path))
            }
        }

        let resolved = try EPUBResourcePath.resolve("../Images/cover%20art.png#fig-1", relativeTo: "OPS/Text/ch1.xhtml")
        #expect(resolved.path == "OPS/Images/cover art.png" && resolved.fragment == "fig-1")
        let sameDoc = try EPUBResourcePath.resolve("#section-2", relativeTo: "OPS/Text/ch1.xhtml")
        #expect(sameDoc.path == "OPS/Text/ch1.xhtml" && sameDoc.fragment == "section-2")

        for unsafeHref in [
            "../../escape.xhtml",
            "/absolute.xhtml",
            "https://example.com/a.xhtml",
            "javascript:alert(1)",
            "ch1.xhtml#a#b",
            "ch1.xhtml#",
            "a%2Fb.xhtml",
            "%2e%2e/escape.xhtml"
        ] {
            #expect(throws: EPUBError.unsafePath) {
                _ = try EPUBResourcePath.resolve(unsafeHref, relativeTo: "OPS/Text/ch1.xhtml")
            }
        }
    }

    @Test func epubArchiveRejectsDuplicateAndUnicodeCollidingCanonicalPaths() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let collisionPairs: [(String, String)] = [
            ("OPS/ch1.xhtml", "OPS/ch1.xhtml"),
            ("OPS/e\u{0301}.xhtml", "OPS/\u{00E9}.xhtml"),
            ("OPS/Chapter.xhtml", "OPS/chapter.xhtml")
        ]

        for (first, second) in collisionPairs {
            let zipURL = root.appendingPathComponent(UUID().uuidString + ".epub")
            let raw = EPUBTestSupport.craftRawZIP(
                entries: [
                    RawZIPEntrySpec(cdPath: first, payload: Data("first".utf8)),
                    RawZIPEntrySpec(cdPath: second, payload: Data("second".utf8))
                ]
            )
            try raw.write(to: zipURL)
            let dest = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            #expect(throws: EPUBError.unsafePath) {
                _ = try EPUBArchive.extract(archiveURL: zipURL, to: dest)
            }
            #expect(!FileManager.default.fileExists(atPath: dest.path))
        }
        let duplicateDirectory = root.appendingPathComponent("duplicate-directory.epub")
        try EPUBTestSupport.craftRawZIP(entries: [
            RawZIPEntrySpec(cdPath: "OPS/", payload: Data(), externalFileAttributes: 0o040755 << 16),
            RawZIPEntrySpec(cdPath: "OPS/", payload: Data(), externalFileAttributes: 0o040755 << 16),
            RawZIPEntrySpec(cdPath: "OPS/body.xhtml")
        ]).write(to: duplicateDirectory)
        #expect(throws: EPUBError.unsafePath) {
            _ = try EPUBArchive.extract(archiveURL: duplicateDirectory, to: root.appendingPathComponent("duplicate-dir-out"))
        }
    }

    @Test func epubArchiveRejectsSymbolicLinksAndDestinationLinkEscapes() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let symlinkAttr: UInt32 = (0o120777 << 16)
        let zipURL = root.appendingPathComponent("symlink.epub")
        let raw = EPUBTestSupport.craftRawZIP(
            entries: [
                RawZIPEntrySpec(
                    cdPath: "OPS/link.xhtml",
                    payload: Data("/etc/passwd".utf8),
                    externalFileAttributes: symlinkAttr
                )
            ]
        )
        try raw.write(to: zipURL)
        let dest = root.appendingPathComponent("dest", isDirectory: true)
        #expect(throws: EPUBError.unsafePath) {
            _ = try EPUBArchive.extract(archiveURL: zipURL, to: dest)
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))

        let validZip = root.appendingPathComponent("good.epub")
        try EPUBTestSupport.writeZIP(
            at: validZip,
            entries: [("mimetype", Data("application/epub+zip".utf8), .none)]
        )
        let targetDir = root.appendingPathComponent("realTarget", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let symlinkDest = root.appendingPathComponent("symlinkDest")
        try FileManager.default.createSymbolicLink(at: symlinkDest, withDestinationURL: targetDir)
        #expect(throws: EPUBError.unsafePath) {
            _ = try EPUBArchive.extract(archiveURL: validZip, to: symlinkDest)
        }
    }

    @Test func epubArchiveRejectsCRCMismatchesAfterStreamingExtraction() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }

        // Case 1: Stored entry where payload byte is flipped so extracted stream CRC != header checksum.
        let payload = Data("Stored payload for CRC verification".utf8)
        let originalCRC = EPUBTestSupport.crc32(payload)
        let badCRC = originalCRC ^ 0xFFFFFFFF
        let rawStored = EPUBTestSupport.craftRawZIP(
            entries: [
                RawZIPEntrySpec(
                    cdPath: "OPS/stored.xhtml",
                    payload: payload,
                    cdCRCOverride: badCRC,
                    lfhCRCOverride: badCRC
                )
            ]
        )
        let storedURL = root.appendingPathComponent("bad-stored-crc.epub")
        try rawStored.write(to: storedURL)
        let storedDest = root.appendingPathComponent("stored-dest", isDirectory: true)
        #expect(throws: EPUBError.corruptResource) {
            _ = try EPUBArchive.extract(archiveURL: storedURL, to: storedDest)
        }
        #expect(!FileManager.default.fileExists(atPath: storedDest.path))

        // Case 2: Deflated entry where CD/LFH CRC mismatch or corrupted checksum is detected.
        let deflatedURL = root.appendingPathComponent("deflated.epub")
        try EPUBTestSupport.writeZIP(
            at: deflatedURL,
            entries: [("OPS/ch1.xhtml", Data(String(repeating: "Deflate CRC check ", count: 64).utf8), .deflate)]
        )
        var deflatedBytes = try Data(contentsOf: deflatedURL)
        EPUBTestSupport.corruptFirstEntryCRC(&deflatedBytes)
        let mutatedDeflatedURL = root.appendingPathComponent("bad-deflated-crc.epub")
        try deflatedBytes.write(to: mutatedDeflatedURL)
        let deflatedDest = root.appendingPathComponent("deflated-dest", isDirectory: true)
        #expect(throws: EPUBError.corruptResource) {
            _ = try EPUBArchive.extract(archiveURL: mutatedDeflatedURL, to: deflatedDest)
        }
        #expect(!FileManager.default.fileExists(atPath: deflatedDest.path))
    }

    @Test func epubArchiveRejectsTruncatedAndInconsistentHeaders() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }

        let emptyURL = root.appendingPathComponent("empty.epub")
        try Data().write(to: emptyURL)
        let garbageURL = root.appendingPathComponent("garbage.epub")
        try Data("not a zip archive at all".utf8).write(to: garbageURL)

        let declaredMismatch = EPUBTestSupport.craftRawZIP(
            entries: [RawZIPEntrySpec(cdPath: "OPS/a.xhtml")],
            eocdDeclaredEntries: 2
        )
        let declaredMismatchURL = root.appendingPathComponent("declared-mismatch.epub")
        try declaredMismatch.write(to: declaredMismatchURL)

        let truncatedCD = EPUBTestSupport.craftRawZIP(
            entries: [RawZIPEntrySpec(cdPath: "OPS/a.xhtml")],
            truncateCDBy: 6
        )
        let truncatedCDURL = root.appendingPathComponent("truncated-cd.epub")
        try truncatedCD.write(to: truncatedCDURL)

        let nameMismatch = EPUBTestSupport.craftRawZIP(
            entries: [RawZIPEntrySpec(cdPath: "OPS/a.xhtml", lfhPath: "OPS/b.xhtml")]
        )
        let nameMismatchURL = root.appendingPathComponent("name-mismatch.epub")
        try nameMismatch.write(to: nameMismatchURL)

        let truncatedPayload = EPUBTestSupport.craftRawZIP(
            entries: [RawZIPEntrySpec(cdPath: "OPS/a.xhtml", payload: Data("0123456789".utf8), truncatePayloadBy: 4)]
        )
        let truncatedPayloadURL = root.appendingPathComponent("truncated-payload.epub")
        try truncatedPayload.write(to: truncatedPayloadURL)

        for badURL in [emptyURL, garbageURL, declaredMismatchURL, truncatedCDURL, nameMismatchURL, truncatedPayloadURL] {
            let dest = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            #expect(throws: EPUBError.invalidArchive) {
                _ = try EPUBArchive.extract(archiveURL: badURL, to: dest)
            }
            #expect(!FileManager.default.fileExists(atPath: dest.path))
        }
    }

    @Test func epubArchiveEnforcesCompressedAndStreamedExpansionBudgets() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let zipURL = root.appendingPathComponent("budget.epub")
        let xmlPayload = Data(repeating: 0x41, count: 2048)
        let xhtmlPayload = Data(repeating: 0x42, count: 4096)
        let imagePayload = Data(repeating: 0x43, count: 4096)

        try EPUBTestSupport.writeZIP(
            at: zipURL,
            entries: [
                ("META-INF/container.xml", xmlPayload, .deflate),
                ("OPS/ch1.xhtml", xhtmlPayload, .deflate),
                ("OPS/cover.png", imagePayload, .deflate)
            ]
        )

        var compressedLimit = EPUBLimits()
        compressedLimit.compressedBytes = 32
        var xmlLimit = EPUBLimits()
        xmlLimit.xmlBytes = 512
        var xhtmlLimit = EPUBLimits()
        xhtmlLimit.xhtmlBytes = 1024
        var imageLimit = EPUBLimits()
        imageLimit.imageBytes = 1024
        var totalLimit = EPUBLimits()
        totalLimit.expandedBytes = 5000

        for limits in [compressedLimit, xmlLimit, xhtmlLimit, imageLimit, totalLimit] {
            let dest = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            #expect(throws: EPUBError.limitExceeded) {
                _ = try EPUBArchive.extract(archiveURL: zipURL, to: dest, limits: limits)
            }
            #expect(!FileManager.default.fileExists(atPath: dest.path))
        }

        // Also test a deflated archive whose header lies about uncompressedSize (claiming 16 bytes for a 4096-byte stream).
        let bombURL = root.appendingPathComponent("lying-bomb.epub")
        try EPUBTestSupport.writeZIP(
            at: bombURL,
            entries: [("OPS/ch1.xhtml", xhtmlPayload, .deflate)]
        )
        var bombBytes = try Data(contentsOf: bombURL)
        EPUBTestSupport.overrideFirstEntryUncompressedSize(&bombBytes, fakeSize: 16)
        try bombBytes.write(to: bombURL)
        var streamLimit = EPUBLimits()
        streamLimit.expandedBytes = 512
        let bombDest = root.appendingPathComponent("bomb-dest", isDirectory: true)
        #expect(throws: EPUBError.limitExceeded) {
            _ = try EPUBArchive.extract(archiveURL: bombURL, to: bombDest, limits: streamLimit)
        }
        #expect(!FileManager.default.fileExists(atPath: bombDest.path))
    }

    @Test func epubArchiveEnforcesMaximumEntryCountBudget() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let zipURL = root.appendingPathComponent("entries.epub")
        try EPUBTestSupport.writeZIP(
            at: zipURL,
            entries: [
                ("OPS/1.xhtml", Data("1".utf8), .none),
                ("OPS/2.xhtml", Data("2".utf8), .none),
                ("OPS/3.xhtml", Data("3".utf8), .none),
                ("OPS/4.xhtml", Data("4".utf8), .none)
            ]
        )

        var strictLimits = EPUBLimits()
        strictLimits.entries = 3
        let failedDest = root.appendingPathComponent("failed", isDirectory: true)
        #expect(throws: EPUBError.limitExceeded) {
            _ = try EPUBArchive.extract(archiveURL: zipURL, to: failedDest, limits: strictLimits)
        }
        #expect(!FileManager.default.fileExists(atPath: failedDest.path))

        strictLimits.entries = 4
        let passedDest = root.appendingPathComponent("passed", isDirectory: true)
        let extracted = try EPUBArchive.extract(archiveURL: zipURL, to: passedDest, limits: strictLimits)
        #expect(extracted.entries.count == 4)
    }

    @Test func epubArchiveRejectsEncryptedAndUnsupportedCompressionEntries() throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }

        // 1. Encrypted entry in CD/LFH (bit 0 set, which ZIPFoundation's iterator would otherwise silently omit).
        let encryptedCD = EPUBTestSupport.craftRawZIP(
            entries: [
                RawZIPEntrySpec(cdPath: "mimetype", payload: Data("application/epub+zip".utf8)),
                RawZIPEntrySpec(cdPath: "OPS/secret.xhtml", cdFlags: 0x0801, lfhFlags: 0x0801)
            ]
        )
        // 2. Encrypted flag set only in LFH.
        let encryptedLFH = EPUBTestSupport.craftRawZIP(
            entries: [
                RawZIPEntrySpec(cdPath: "OPS/secret.xhtml", cdFlags: 0x0800, lfhFlags: 0x0801)
            ]
        )
        // 3. WinZip AES extra field 0x9901.
        let aesExtra = Data([0x01, 0x99, 0x07, 0x00, 0x02, 0x00, 0x41, 0x45, 0x03, 0x08, 0x00])
        let aesZip = EPUBTestSupport.craftRawZIP(
            entries: [
                RawZIPEntrySpec(cdPath: "OPS/aes.xhtml", extraField: aesExtra)
            ]
        )
        // 4. Unsupported compression methods (12 = bzip2, 14 = lzma, 99 = AES).
        let bzip2Zip = EPUBTestSupport.craftRawZIP(
            entries: [RawZIPEntrySpec(cdPath: "OPS/bzip2.xhtml", cdCompressionMethod: 12)]
        )
        let lzmaZip = EPUBTestSupport.craftRawZIP(
            entries: [RawZIPEntrySpec(cdPath: "OPS/lzma.xhtml", cdCompressionMethod: 14)]
        )

        for raw in [encryptedCD, encryptedLFH, aesZip, bzip2Zip, lzmaZip] {
            let url = root.appendingPathComponent(UUID().uuidString + ".epub")
            try raw.write(to: url)
            let dest = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            #expect(throws: EPUBError.unsupportedContent) {
                _ = try EPUBArchive.extract(archiveURL: url, to: dest)
            }
            #expect(!FileManager.default.fileExists(atPath: dest.path))
        }
    }

    @Test func epubArchiveRespectsTaskCancellationAndCleansDestination() async throws {
        let root = try EPUBTestSupport.makeWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
        let zipURL = root.appendingPathComponent("cancel.epub")
        try EPUBTestSupport.writeEPUB3(at: zipURL)
        let dest = root.appendingPathComponent("cancelled-dest", isDirectory: true)

        let task = Task<EPUBArchiveExtraction, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try EPUBArchive.extract(archiveURL: zipURL, to: dest)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }
}

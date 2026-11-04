import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZIPFoundation
@testable import ReaderDomain

struct EPUBSyntheticChapter: Sendable, Equatable {
    let id: String
    let path: String
    let title: String
    let headingID: String
    let bodyXHTML: String

    init(
        id: String,
        path: String,
        title: String,
        headingID: String = "heading",
        bodyXHTML: String? = nil
    ) {
        self.id = id
        self.path = path
        self.title = title
        self.headingID = headingID
        if let bodyXHTML {
            self.bodyXHTML = bodyXHTML
        } else {
            self.bodyXHTML = """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(title)</title></head><body><h1 id="\(headingID)">\(title)</h1><p>A😀e\u{301} &amp; &lt;正文&gt; \(title)</p><p>结尾段落。</p></body></html>
            """
        }
    }
}

struct RawZIPEntrySpec: Sendable {
    var cdPath: String
    var lfhPath: String?
    var payload: Data
    var cdCompressionMethod: UInt16
    var lfhCompressionMethod: UInt16?
    var cdFlags: UInt16
    var lfhFlags: UInt16?
    var cdCRCOverride: UInt32?
    var lfhCRCOverride: UInt32?
    var cdCompressedSizeOverride: UInt32?
    var lfhCompressedSizeOverride: UInt32?
    var cdUncompressedSizeOverride: UInt32?
    var lfhUncompressedSizeOverride: UInt32?
    var externalFileAttributes: UInt32
    var extraField: Data
    var truncatePayloadBy: Int

    init(
        cdPath: String,
        lfhPath: String? = nil,
        payload: Data = Data("synthetic-payload".utf8),
        cdCompressionMethod: UInt16 = 0,
        lfhCompressionMethod: UInt16? = nil,
        cdFlags: UInt16 = 0x0800,
        lfhFlags: UInt16? = nil,
        cdCRCOverride: UInt32? = nil,
        lfhCRCOverride: UInt32? = nil,
        cdCompressedSizeOverride: UInt32? = nil,
        lfhCompressedSizeOverride: UInt32? = nil,
        cdUncompressedSizeOverride: UInt32? = nil,
        lfhUncompressedSizeOverride: UInt32? = nil,
        externalFileAttributes: UInt32 = (0o100644 << 16),
        extraField: Data = Data(),
        truncatePayloadBy: Int = 0
    ) {
        self.cdPath = cdPath
        self.lfhPath = lfhPath
        self.payload = payload
        self.cdCompressionMethod = cdCompressionMethod
        self.lfhCompressionMethod = lfhCompressionMethod
        self.cdFlags = cdFlags
        self.lfhFlags = lfhFlags
        self.cdCRCOverride = cdCRCOverride
        self.lfhCRCOverride = lfhCRCOverride
        self.cdCompressedSizeOverride = cdCompressedSizeOverride
        self.lfhCompressedSizeOverride = lfhCompressedSizeOverride
        self.cdUncompressedSizeOverride = cdUncompressedSizeOverride
        self.lfhUncompressedSizeOverride = lfhUncompressedSizeOverride
        self.externalFileAttributes = externalFileAttributes
        self.extraField = extraField
        self.truncatePayloadBy = truncatePayloadBy
    }
}

enum EPUBTestSupport {
    static let defaultChapters: [EPUBSyntheticChapter] = [
        EPUBSyntheticChapter(id: "ch1", path: "one.xhtml", title: "第一章 晨雾"),
        EPUBSyntheticChapter(id: "ch2", path: "two.xhtml", title: "第二章 远航")
    ]

    static func makeWorkspace(prefix: String = "YueJing-EPUB-") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func pngData(width: Int = 64, height: Int = 64) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.22, green: 0.48, blue: 0.38, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    static func jpegData(width: Int = 64, height: Int = 64) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.65, green: 0.35, blue: 0.20, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    static func writeZIP(
        at url: URL,
        entries: [(path: String, data: Data, method: CompressionMethod)]
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data, method) in entries {
            if path.hasSuffix("/") {
                try archive.addEntry(with: path, type: .directory, uncompressedSize: Int64(0), compressionMethod: .none) { _, _ in Data() }
            } else {
                try archive.addEntry(
                    with: path,
                    type: .file,
                    uncompressedSize: Int64(data.count),
                    compressionMethod: method
                ) { offset, size in
                    let start = Int(offset)
                    return data.subdata(in: start..<(start + size))
                }
            }
        }
    }

    @discardableResult
    static func writeEPUB3(
        at url: URL,
        title: String = "合成EPUB测试",
        chapters: [EPUBSyntheticChapter] = defaultChapters,
        spineOrder: [String]? = nil,
        coverData: Data? = nil,
        coverHref: String = "cover.png",
        coverMediaType: String = "image/png",
        coverProperty: Bool = true,
        navXHTML: String? = nil,
        includeNavInSpine: Bool = false,
        metadataExtra: String = "",
        manifestExtra: String = "",
        spineItemProperties: [String: String] = [:],
        extraEntries: [(String, Data)] = [],
        compress: Bool = true
    ) throws -> URL {
        var manifestLines: [String] = []
        for chapter in chapters {
            manifestLines.append(
                "<item id=\"\(chapter.id)\" href=\"\(chapter.path)\" media-type=\"application/xhtml+xml\"/>"
            )
        }
        manifestLines.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        if coverData != nil {
            let propAttr = coverProperty ? " properties=\"cover-image\"" : ""
            manifestLines.append("<item id=\"cover\" href=\"\(coverHref)\" media-type=\"\(coverMediaType)\"\(propAttr)/>")
        }
        if !manifestExtra.isEmpty {
            manifestLines.append(manifestExtra)
        }

        let orderedIDs = spineOrder ?? (includeNavInSpine ? (["nav"] + chapters.map(\.id)) : chapters.map(\.id))
        let spineLines = orderedIDs.map { id -> String in
            if let prop = spineItemProperties[id], !prop.isEmpty {
                return "<itemref idref=\"\(id)\" properties=\"\(prop)\"/>"
            }
            return "<itemref idref=\"\(id)\"/>"
        }

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:synthetic-epub3</dc:identifier><dc:title>\(title)</dc:title><dc:language>zh</dc:language>\(metadataExtra)</metadata>
        <manifest>\(manifestLines.joined())</manifest>
        <spine>\(spineLines.joined())</spine>
        </package>
        """

        let defaultNavLinks = chapters.map {
            "<li><a href=\"\($0.path)#\($0.headingID)\">\($0.title)</a></li>"
        }.joined()
        let resolvedNav = navXHTML ?? """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol>\(defaultNavLinks)</ol></nav></body></html>
        """

        var entries: [(path: String, data: Data, method: CompressionMethod)] = [
            ("mimetype", Data("application/epub+zip".utf8), .none),
            (
                "META-INF/container.xml",
                Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" version=\"1.0\"><rootfiles><rootfile full-path=\"OPS/book.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8),
                compress ? .deflate : .none
            ),
            ("OPS/book.opf", Data(opf.utf8), compress ? .deflate : .none),
            ("OPS/nav.xhtml", Data(resolvedNav.utf8), compress ? .deflate : .none)
        ]

        for chapter in chapters {
            entries.append(("OPS/" + chapter.path, Data(chapter.bodyXHTML.utf8), compress ? .deflate : .none))
        }
        if let coverData {
            entries.append(("OPS/" + coverHref, coverData, compress ? .deflate : .none))
        }
        for (extraPath, extraData) in extraEntries {
            entries.append((extraPath, extraData, compress ? .deflate : .none))
        }

        try writeZIP(at: url, entries: entries)
        return url
    }

    @discardableResult
    static func writeEPUB2(
        at url: URL,
        title: String = "合成EPUB2测试",
        chapters: [EPUBSyntheticChapter] = defaultChapters,
        spineOrder: [String]? = nil,
        coverData: Data? = nil,
        coverHref: String = "images/cover.jpg",
        coverMediaType: String = "image/jpeg",
        ncxXML: String? = nil,
        extraEntries: [(String, Data)] = [],
        compress: Bool = true
    ) throws -> URL {
        var manifestLines: [String] = []
        for chapter in chapters {
            manifestLines.append(
                "<item id=\"\(chapter.id)\" href=\"\(chapter.path)\" media-type=\"application/xhtml+xml\"/>"
            )
        }
        manifestLines.append("<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>")
        let coverMeta: String
        if coverData != nil {
            manifestLines.append("<item id=\"cover-img\" href=\"\(coverHref)\" media-type=\"\(coverMediaType)\"/>")
            coverMeta = "<meta name=\"cover\" content=\"cover-img\"/>"
        } else {
            coverMeta = ""
        }

        let orderedIDs = spineOrder ?? chapters.map(\.id)
        let spineLines = orderedIDs.map { "<itemref idref=\"\($0)\"/>" }

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:synthetic-epub2</dc:identifier><dc:title>\(title)</dc:title><dc:language>zh</dc:language>\(coverMeta)</metadata>
        <manifest>\(manifestLines.joined())</manifest>
        <spine toc="ncx">\(spineLines.joined())</spine>
        </package>
        """

        let defaultNavPoints = chapters.enumerated().map { idx, chapter in
            "<navPoint id=\"np-\(idx + 1)\" playOrder=\"\(idx + 1)\"><navLabel><text>\(chapter.title)</text></navLabel><content src=\"\(chapter.path)#\(chapter.headingID)\"/></navPoint>"
        }.joined()
        let resolvedNCX = ncxXML ?? """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="urn:uuid:synthetic-epub2"/></head><docTitle><text>\(title)</text></docTitle><navMap>\(defaultNavPoints)</navMap></ncx>
        """

        var entries: [(path: String, data: Data, method: CompressionMethod)] = [
            ("mimetype", Data("application/epub+zip".utf8), .none),
            (
                "META-INF/container.xml",
                Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" version=\"1.0\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8),
                compress ? .deflate : .none
            ),
            ("OEBPS/content.opf", Data(opf.utf8), compress ? .deflate : .none),
            ("OEBPS/toc.ncx", Data(resolvedNCX.utf8), compress ? .deflate : .none)
        ]

        for chapter in chapters {
            entries.append(("OEBPS/" + chapter.path, Data(chapter.bodyXHTML.utf8), compress ? .deflate : .none))
        }
        if let coverData {
            entries.append(("OEBPS/" + coverHref, coverData, compress ? .deflate : .none))
        }
        for (extraPath, extraData) in extraEntries {
            entries.append((extraPath, extraData, compress ? .deflate : .none))
        }

        try writeZIP(at: url, entries: entries)
        return url
    }

    static func craftRawZIP(
        entries: [RawZIPEntrySpec],
        eocdDeclaredEntries: UInt16? = nil,
        truncateCDBy: Int = 0
    ) -> Data {
        var fileBytes = Data()
        var cdBytes = Data()

        for spec in entries {
            let lfhOffset = UInt32(fileBytes.count)
            let cdNameData = Data(spec.cdPath.utf8)
            let lfhNameData = Data((spec.lfhPath ?? spec.cdPath).utf8)
            let computedCRC = crc32(spec.payload)
            let cdCRC = spec.cdCRCOverride ?? computedCRC
            let lfhCRC = spec.lfhCRCOverride ?? cdCRC

            let actualPayload: Data
            if spec.truncatePayloadBy > 0 && spec.truncatePayloadBy <= spec.payload.count {
                actualPayload = spec.payload.prefix(spec.payload.count - spec.truncatePayloadBy)
            } else {
                actualPayload = spec.payload
            }

            let cdCompSize = spec.cdCompressedSizeOverride ?? UInt32(spec.payload.count)
            let lfhCompSize = spec.lfhCompressedSizeOverride ?? cdCompSize
            let cdUncompSize = spec.cdUncompressedSizeOverride ?? UInt32(spec.payload.count)
            let lfhUncompSize = spec.lfhUncompressedSizeOverride ?? cdUncompSize
            let lfhFlags = spec.lfhFlags ?? spec.cdFlags
            let lfhMethod = spec.lfhCompressionMethod ?? spec.cdCompressionMethod

            // Local File Header (30 bytes + name + extra)
            appendUInt32(&fileBytes, 0x04034B50)
            appendUInt16(&fileBytes, 20)
            appendUInt16(&fileBytes, lfhFlags)
            appendUInt16(&fileBytes, lfhMethod)
            appendUInt16(&fileBytes, 0)
            appendUInt16(&fileBytes, 0)
            appendUInt32(&fileBytes, lfhCRC)
            appendUInt32(&fileBytes, lfhCompSize)
            appendUInt32(&fileBytes, lfhUncompSize)
            appendUInt16(&fileBytes, UInt16(lfhNameData.count))
            appendUInt16(&fileBytes, UInt16(spec.extraField.count))
            fileBytes.append(lfhNameData)
            fileBytes.append(spec.extraField)
            fileBytes.append(actualPayload)

            // Central Directory Header (46 bytes + name + extra)
            appendUInt32(&cdBytes, 0x02014B50)
            appendUInt16(&cdBytes, 0x031E) // Unix
            appendUInt16(&cdBytes, 20)
            appendUInt16(&cdBytes, spec.cdFlags)
            appendUInt16(&cdBytes, spec.cdCompressionMethod)
            appendUInt16(&cdBytes, 0)
            appendUInt16(&cdBytes, 0)
            appendUInt32(&cdBytes, cdCRC)
            appendUInt32(&cdBytes, cdCompSize)
            appendUInt32(&cdBytes, cdUncompSize)
            appendUInt16(&cdBytes, UInt16(cdNameData.count))
            appendUInt16(&cdBytes, UInt16(spec.extraField.count))
            appendUInt16(&cdBytes, 0)
            appendUInt16(&cdBytes, 0)
            appendUInt16(&cdBytes, 0)
            appendUInt32(&cdBytes, spec.externalFileAttributes)
            appendUInt32(&cdBytes, lfhOffset)
            cdBytes.append(cdNameData)
            cdBytes.append(spec.extraField)
        }

        let cdOffset = UInt32(fileBytes.count)
        let fullCDSize = UInt32(cdBytes.count)
        if truncateCDBy > 0 && truncateCDBy <= cdBytes.count {
            fileBytes.append(cdBytes.prefix(cdBytes.count - truncateCDBy))
        } else {
            fileBytes.append(cdBytes)
        }

        let count = eocdDeclaredEntries ?? UInt16(entries.count)
        appendUInt32(&fileBytes, 0x06054B50)
        appendUInt16(&fileBytes, 0)
        appendUInt16(&fileBytes, 0)
        appendUInt16(&fileBytes, count)
        appendUInt16(&fileBytes, count)
        appendUInt32(&fileBytes, fullCDSize)
        appendUInt32(&fileBytes, cdOffset)
        appendUInt16(&fileBytes, 0)

        return fileBytes
    }

    static func crc32(_ data: Data) -> UInt32 {
        data.crc32(checksum: 0)
    }

    static func encodeUTF16(_ string: String, bigEndian: Bool, includeBOM: Bool = true) -> Data {
        var out = Data()
        if includeBOM {
            out.append(contentsOf: bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE])
        }
        for unit in string.utf16 {
            let high = UInt8((unit >> 8) & 0xFF)
            let low = UInt8(unit & 0xFF)
            if bigEndian {
                out.append(high)
                out.append(low)
            } else {
                out.append(low)
                out.append(high)
            }
        }
        return out
    }

    static func corruptFirstEntryCRC(_ archiveBytes: inout Data) {
        guard archiveBytes.count >= 22 else { return }
        let cdOffset = Int(archiveBytes[archiveBytes.count - 6])
            | (Int(archiveBytes[archiveBytes.count - 5]) << 8)
            | (Int(archiveBytes[archiveBytes.count - 4]) << 16)
            | (Int(archiveBytes[archiveBytes.count - 3]) << 24)
        guard cdOffset + 20 <= archiveBytes.count else { return }
        archiveBytes[14] ^= 0xFF
        archiveBytes[cdOffset + 16] ^= 0xFF
    }

    static func overrideFirstEntryUncompressedSize(_ archiveBytes: inout Data, fakeSize: UInt32) {
        guard archiveBytes.count >= 26 else { return }
        let cdOffset = Int(archiveBytes[archiveBytes.count - 6])
            | (Int(archiveBytes[archiveBytes.count - 5]) << 8)
            | (Int(archiveBytes[archiveBytes.count - 4]) << 16)
            | (Int(archiveBytes[archiveBytes.count - 3]) << 24)
        guard cdOffset + 28 <= archiveBytes.count else { return }
        let le: [UInt8] = [
            UInt8(fakeSize & 0xFF),
            UInt8((fakeSize >> 8) & 0xFF),
            UInt8((fakeSize >> 16) & 0xFF),
            UInt8((fakeSize >> 24) & 0xFF)
        ]
        archiveBytes.replaceSubrange(22..<26, with: le)
        archiveBytes.replaceSubrange((cdOffset + 24)..<(cdOffset + 28), with: le)
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}

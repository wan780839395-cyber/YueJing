#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import ReaderDomain
import UniformTypeIdentifiers
import ZIPFoundation

/// Isolated DEBUG fixture for EPUB UI and Host tests. Never touches the user's real library.
enum EPUBUITestFixture {
    static let sessionEnvironmentKey = "YUEJING_EPUB_UI_TEST_SESSION"
    static let illustratedBookTitle = "EPUBTest-Illustrated-A"
    static let noCoverBookTitle = "EPUBTest-NoCover-B"
    static let txtCompanionTitle = "TXTTest-Companion-C"

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment[sessionEnvironmentKey] != nil
    }

    static func makeService() async throws -> LibraryService {
        guard let raw = ProcessInfo.processInfo.environment[sessionEnvironmentKey],
              let session = UUID(uuidString: raw) else {
            throw FixtureError.invalidSession
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YueJing-EPUB-UI-Fixtures", isDirectory: true)
            .appendingPathComponent(session.uuidString, isDirectory: true)
        let inputs = root.appendingPathComponent("SyntheticInputs", isDirectory: true)
        let managed = root.appendingPathComponent("Managed", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let store = try LibraryStore(root: managed)
        let service = LibraryService(store: store)

        if try await store.books().isEmpty {
            // Reset only a new isolated DEBUG fixture, never a process relaunch of it.
            UserDefaults.standard.removeObject(forKey: EPUBLayoutMode.defaultsKey)
            UserDefaults.standard.removeObject(forKey: EPUBReadingMode.defaultsKey)
            let txtURL = inputs.appendingPathComponent(txtCompanionTitle).appendingPathExtension("txt")
            let txtBody = "第一章 TXT_COMPANION_START\n" + (1...16).map { line in
                "TXT_C_LINE_\(line) 合成对照 TXT 文本，用于验证 EPUB 与 TXT 共存且互不串书。\n"
            }.joined() + "TXT_COMPANION_END\n"
            try (Data([0xEF, 0xBB, 0xBF]) + Data(txtBody.utf8)).write(to: txtURL, options: .atomic)
            let txtResult = try await service.prepareReadingImport(
                url: txtURL,
                ticket: UUID(),
                budget: ReaderStoragePolicy.budget()
            )
            guard case .completed = txtResult else {
                throw FixtureError.unexpectedImportOutcome
            }

            let noCoverURL = inputs.appendingPathComponent(noCoverBookTitle).appendingPathExtension("epub")
            try writeNoCoverEPUB(to: noCoverURL, title: noCoverBookTitle)
            let noCoverResult = try await service.prepareReadingImport(
                url: noCoverURL,
                ticket: UUID(),
                budget: ReaderStoragePolicy.budget()
            )
            guard case .completed = noCoverResult else {
                throw FixtureError.unexpectedImportOutcome
            }

            let illustratedURL = inputs.appendingPathComponent(illustratedBookTitle).appendingPathExtension("epub")
            let coverPNG = try makePNGData(width: 640, height: 900)
            try writeIllustratedEPUB(to: illustratedURL, title: illustratedBookTitle, coverData: coverPNG)
            let illustratedResult = try await service.prepareReadingImport(
                url: illustratedURL,
                ticket: UUID(),
                budget: ReaderStoragePolicy.budget()
            )
            guard case .completed = illustratedResult else {
                throw FixtureError.unexpectedImportOutcome
            }
        }
        return service
    }

    static func makePNGData(width: Int = 640, height: Int = 900) throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw FixtureError.imageCreationFailed
        }
        context.setFillColor(CGColor(red: 0.22, green: 0.44, blue: 0.38, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.86, green: 0.82, blue: 0.72, alpha: 1))
        context.fill(CGRect(x: width / 8, y: height / 8, width: width * 3 / 4, height: height * 3 / 4))
        guard let cgImage = context.makeImage() else {
            throw FixtureError.imageCreationFailed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw FixtureError.imageCreationFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.imageCreationFailed
        }
        return output as Data
    }

    static func writeIllustratedEPUB(
        to url: URL,
        title: String = illustratedBookTitle,
        coverData: Data? = nil
    ) throws {
        let coverBytes = try coverData ?? makePNGData(width: 640, height: 900)
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:11111111-2222-3333-4444-555555555555</dc:identifier>
            <dc:title>\(title)</dc:title>
            <dc:language>zh-Hans</dc:language>
          </metadata>
          <manifest>
            <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch3" href="text/ch3.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="cover-img" href="images/cover.png" media-type="image/png" properties="cover-image"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
            <itemref idref="ch3"/>
          </spine>
        </package>
        """

        let ch1Paragraphs = (1...32).map { index in
            "<p id=\"c1-p\(index)\">EPUB_A_C1_P\(index) 晨雾中的山谷章节正文，包含<em>强调语义</em>与<strong>重点词句</strong>以及字符边界 A😀e\u{301} 校验文本。</p>"
        }.joined(separator: "\n")
        let ch1 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>第一章 晨雾启程</title></head>
          <body>
            <h1 id="ch1-top">第一章 EPUB_CH1_START</h1>
            <ul>
              <li>导读条目一：结构化列表保留</li>
              <li>导读条目二：本地插图与段落排版</li>
            </ul>
            <img src="../images/cover.png" alt="章节插图"/>
            \(ch1Paragraphs)
            <p id="ch1-end">EPUB_CH1_END 第一章末尾。</p>
          </body>
        </html>
        """

        let ch2FirstHalf = (1...14).map { index in
            "<p id=\"c2-p\(index)\">EPUB_A_C2_P\(index) 第二章远山回响前段正文，用于跨章目录跳转与滚动锚点测试。</p>"
        }.joined(separator: "\n")
        let ch2SecondHalf = (15...32).map { index in
            "<p id=\"c2-p\(index)\">EPUB_A_C2_P\(index) 第二章远山回响后段正文，验证子节 fragment 锚点跳转与恢复。</p>"
        }.joined(separator: "\n")
        let ch2 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>第二章 远山回响</title></head>
          <body>
            <h1 id="ch2-top">第二章 EPUB_CH2_START</h1>
            \(ch2FirstHalf)
            <h2 id="sec-mid">第二节 EPUB_CH2_MID_ANCHOR</h2>
            \(ch2SecondHalf)
            <p id="ch2-end">EPUB_CH2_END 第二章末尾。</p>
          </body>
        </html>
        """

        let ch3Paragraphs = (1...20).map { index in
            "<p id=\"c3-p\(index)\">EPUB_A_C3_P\(index) 第三章归途终章正文内容，验证多章节完整阅读体验。</p>"
        }.joined(separator: "\n")
        let ch3 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>第三章 归途终章</title></head>
          <body>
            <h1 id="ch3-top">第三章 EPUB_CH3_START</h1>
            \(ch3Paragraphs)
            <p id="ch3-end">EPUB_CH3_END 第三章末尾。</p>
          </body>
        </html>
        """

        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head><title>目录</title></head>
          <body>
            <nav epub:type="toc">
              <ol>
                <li><a href="text/ch1.xhtml#ch1-top">第一章 晨雾启程</a></li>
                <li>
                  <a href="text/ch2.xhtml#ch2-top">第二章 远山回响</a>
                  <ol>
                    <li><a href="text/ch2.xhtml#sec-mid">第二节 山腰锚点</a></li>
                  </ol>
                </li>
                <li><a href="text/ch3.xhtml#ch3-top">第三章 归途终章</a></li>
              </ol>
            </nav>
          </body>
        </html>
        """

        let entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/content.opf", Data(opf.utf8)),
            ("OEBPS/nav.xhtml", Data(nav.utf8)),
            ("OEBPS/text/ch1.xhtml", Data(ch1.utf8)),
            ("OEBPS/text/ch2.xhtml", Data(ch2.utf8)),
            ("OEBPS/text/ch3.xhtml", Data(ch3.utf8)),
            ("OEBPS/images/cover.png", coverBytes)
        ]
        try writeArchive(entries: entries, to: url)
    }

    static func writeNoCoverEPUB(
        to url: URL,
        title: String = noCoverBookTitle,
        corruptOptionalCoverData: Data? = nil
    ) throws {
        let coverManifest = corruptOptionalCoverData == nil
            ? ""
            : "<item id=\"bad-cover\" href=\"images/bad.png\" media-type=\"image/png\" properties=\"cover-image\"/>"
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:66666666-7777-8888-9999-000000000000</dc:identifier>
            <dc:title>\(title)</dc:title>
            <dc:language>zh-Hans</dc:language>
          </metadata>
          <manifest>
            <item id="b1" href="text/b1.xhtml" media-type="application/xhtml+xml"/>
            <item id="b2" href="text/b2.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            \(coverManifest)
          </manifest>
          <spine>
            <itemref idref="b1"/>
            <itemref idref="b2"/>
          </spine>
        </package>
        """

        let b1Paragraphs = (1...16).map { index in
            "<p id=\"b1-p\(index)\">EPUB_B_C1_P\(index) 无封面回退测试正文，验证书架文字占位与独立阅读会话。</p>"
        }.joined(separator: "\n")
        let b1 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>第一卷 无封起始</title></head>
          <body>
            <h1 id="b1-top">第一卷 EPUB_NOCOVER_START</h1>
            \(b1Paragraphs)
            <p id="b1-end">EPUB_NOCOVER_END</p>
          </body>
        </html>
        """

        let b2 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>第二卷 无封续章</title></head>
          <body>
            <h1 id="b2-top">第二卷 EPUB_NOCOVER_CH2</h1>
            <p>EPUB_B_C2_P1 第二卷正文内容。</p>
          </body>
        </html>
        """

        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head><title>目录</title></head>
          <body>
            <nav epub:type="toc">
              <ol>
                <li><a href="text/b1.xhtml#b1-top">第一卷 无封起始</a></li>
                <li><a href="text/b2.xhtml#b2-top">第二卷 无封续章</a></li>
              </ol>
            </nav>
          </body>
        </html>
        """

        var entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/content.opf", Data(opf.utf8)),
            ("OEBPS/nav.xhtml", Data(nav.utf8)),
            ("OEBPS/text/b1.xhtml", Data(b1.utf8)),
            ("OEBPS/text/b2.xhtml", Data(b2.utf8))
        ]
        if let corruptOptionalCoverData {
            entries.append(("OEBPS/images/bad.png", corruptOptionalCoverData))
        }
        try writeArchive(entries: entries, to: url)
    }

    static func writeCustomXHTMLEPUB(to url: URL, title: String, bodyXHTML: String) throws {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:99999999-0000-1111-2222-333333333333</dc:identifier>
            <dc:title>\(title)</dc:title>
            <dc:language>zh-Hans</dc:language>
          </metadata>
          <manifest>
            <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
          </spine>
        </package>
        """
        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head><title>目录</title></head>
          <body>
            <nav epub:type="toc"><ol><li><a href="text/ch1.xhtml">第一章</a></li></ol></nav>
          </body>
        </html>
        """
        let entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/content.opf", Data(opf.utf8)),
            ("OEBPS/nav.xhtml", Data(nav.utf8)),
            ("OEBPS/text/ch1.xhtml", Data(bodyXHTML.utf8))
        ]
        try writeArchive(entries: entries, to: url)
    }

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    static func writeArchive(entries: [(String, Data)], to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        guard let archive = Archive(url: url, accessMode: .create) else {
            throw FixtureError.archiveCreationFailed
        }
        for (path, data) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: path == "mimetype" ? .none : .deflate
            ) { offset, size in
                data.subdata(in: Int(offset)..<(Int(offset) + size))
            }
        }
    }

    enum FixtureError: Error {
        case invalidSession
        case unexpectedImportOutcome
        case imageCreationFailed
        case archiveCreationFailed
    }
}
#endif

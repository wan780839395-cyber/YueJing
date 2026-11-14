import CryptoKit
import Foundation

/// IDPF and Adobe font obfuscation are not DRM. Unknown encryption remains a hard rejection.
enum EPUBFontObfuscation {
    enum Algorithm: String { case idpf = "http://www.idpf.org/2008/embedding", adobe = "http://ns.adobe.com/pdf/enc#RC" }

    static func declarations(data: Data, manifest: [String: String], entries: Set<String>, limit: Int) throws -> [String: Algorithm] {
        let prepared = try EPUBXMLSupport.prepareXMLData(data, limit: limit)
        let delegate = Delegate(manifest: manifest, entries: entries)
        try EPUBXMLSupport.parse(prepared, delegate: delegate)
        guard delegate.sawRoot, !delegate.fonts.isEmpty else { throw EPUBError.unsupportedContent }
        return delegate.fonts
    }

    static func omittedFonts(data: Data, manifest: [String: String], entries: Set<String>, limit: Int) throws -> Set<String> {
        Set(try declarations(data: data, manifest: manifest, entries: entries, limit: limit).keys)
    }

    static func restoreIDPF(_ data: Data, key: Data) throws -> Data {
        guard key.count == 20, !data.isEmpty else { throw EPUBError.corruptResource }
        guard data.count <= EPUBAuthorStyles.maxFontBytes else { throw EPUBError.limitExceeded }
        var restored = Data(data)
        for index in 0..<min(1040, restored.count) { restored[index] ^= key[key.startIndex + index % 20] }
        return restored
    }

    static func idpfKey(opfData: Data, limit: Int) throws -> Data? {
        let delegate = IdentifierDelegate()
        try EPUBXMLSupport.parse(EPUBXMLSupport.prepareXMLData(opfData, limit: limit), delegate: delegate)
        guard delegate.matches == 1, !delegate.invalid else { return nil }
        let value = String(String.UnicodeScalarView(delegate.text.unicodeScalars.filter {
            ![UInt32(0x20), 0x09, 0x0D, 0x0A].contains($0.value)
        }))
        guard !value.isEmpty else { return nil }
        // Required by EPUB 3.3 §4.4, never used for resource integrity.
        return Data(Insecure.SHA1.hash(data: Data(value.utf8)))
    }

    /// Adobe uses the first UUID URN in OPF metadata, not package@unique-identifier.
    /// A malformed first UUID URN must not silently select a later, different key.
    static func adobeKey(opfData: Data, limit: Int) throws -> Data? {
        let delegate = AdobeIdentifierDelegate()
        try EPUBXMLSupport.parse(EPUBXMLSupport.prepareXMLData(opfData, limit: limit), delegate: delegate)
        return delegate.key
    }

    /// XOR is not authentication: the caller must validate the restored font before publishing it.
    static func restoreAdobe(_ data: Data, key: Data) throws -> Data {
        guard key.count == 16, !data.isEmpty else { throw EPUBError.corruptResource }
        guard data.count <= EPUBAuthorStyles.maxFontBytes else { throw EPUBError.limitExceeded }
        var restored = Data(data)
        for offset in 0..<min(1024, restored.count) {
            restored[restored.startIndex + offset] ^= key[key.startIndex + offset % 16]
        }
        return restored
    }

    private static func adobeUUIDKey(_ urn: String) -> Data? {
        // Parse textual UUID byte pairs in network (big-endian) order, never native UUID memory.
        let bytes = Array(urn.utf8)
        guard bytes.count == 45, urn.prefix(9).lowercased() == "urn:uuid:" else { return nil }
        let uuid = Array(bytes.dropFirst(9))
        let hyphens: Set<Int> = [8, 13, 18, 23]
        var digits: [UInt8] = []
        for (offset, byte) in uuid.enumerated() {
            if hyphens.contains(offset) {
                guard byte == 0x2D else { return nil }
            } else {
                switch byte {
                case 0x30...0x39: digits.append(byte - 0x30)
                case 0x41...0x46: digits.append(byte - 0x41 + 10)
                case 0x61...0x66: digits.append(byte - 0x61 + 10)
                default: return nil
                }
            }
        }
        var key = Data()
        for offset in stride(from: 0, to: digits.count, by: 2) {
            key.append((digits[offset] << 4) | digits[offset + 1])
        }
        return key
    }

    private final class AdobeIdentifierDelegate: EPUBXMLBaseDelegate {
        private var namespaces: [[String: String]] = []
        private var stack: [String] = []
        private var collecting = false
        private var invalid = false
        private var selected = false
        private var text = ""
        private var textBytes = 0
        private var discarding = false
        private(set) var key: Data?

        override func handleStartElement(name: String, localName: String, prefix: String?,
                                          attributes: [String: String], parser: XMLParser) throws {
            var ns = namespaces.last ?? [:]
            for (name, value) in attributes {
                if name == "xmlns" { ns[""] = value }
                else if name.hasPrefix("xmlns:") { ns[String(name.dropFirst(6))] = value }
            }
            let uri = ns[prefix ?? ""] ?? ""
            if collecting { invalid = true }
            if !selected, stack == ["{http://www.idpf.org/2007/opf}package", "{http://www.idpf.org/2007/opf}metadata"],
               localName == "identifier", uri == "http://purl.org/dc/elements/1.1/" {
                collecting = true; invalid = false; text = ""; textBytes = 0; discarding = false
            }
            stack.append("{\(uri)}\(localName)"); namespaces.append(ns)
        }

        override func handleEndElement(name: String, localName: String, prefix: String?, parser: XMLParser) throws {
            if collecting, stack.count == 3 {
                let value = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
                if value.prefix(9).lowercased() == "urn:uuid:" {
                    selected = true
                    if !invalid { key = EPUBFontObfuscation.adobeUUIDKey(value) }
                }
                collecting = false
            }
            _ = stack.popLast(); namespaces.removeLast()
        }

        override func handleCharacters(_ string: String, parser: XMLParser) throws {
            guard collecting, !discarding else { return }
            for scalar in string.unicodeScalars {
                // Discard arbitrary leading XML whitespace without retaining it.
                if text.isEmpty, [UInt32(0x20), 0x09, 0x0D, 0x0A].contains(scalar.value) { continue }
                let size = String(scalar).utf8.count
                guard size <= 4096 - textBytes else {
                    invalid = true; discarding = true; return // Optional key failure, not whole-book rejection.
                }
                text.unicodeScalars.append(scalar); textBytes += size
                if textBytes >= 9, !text.lowercased().hasPrefix("urn:uuid:") {
                    discarding = true; return // Unrelated identifiers need no further storage.
                }
            }
        }
    }

    private final class IdentifierDelegate: EPUBXMLBaseDelegate {
        var namespaces: [[String: String]] = []
        var stack: [String] = []
        var selectedID: String?
        var matches = 0
        var text = ""
        var collecting = false
        var invalid = false
        override func handleStartElement(name: String, localName: String, prefix: String?,
                                          attributes: [String: String], parser: XMLParser) throws {
            var ns = namespaces.last ?? [:]
            for (key, value) in attributes {
                if key == "xmlns" { ns[""] = value }
                else if key.hasPrefix("xmlns:") { ns[String(key.dropFirst(6))] = value }
            }
            if collecting { invalid = true }
            if stack.isEmpty, localName == "package", ns[prefix ?? ""] == "http://www.idpf.org/2007/opf" {
                selectedID = attributes["unique-identifier"]
            }
            if let selectedID, !selectedID.isEmpty, attributes["id"] == selectedID {
                matches += 1
                if stack == ["package", "metadata"], localName == "identifier",
                   ns[prefix ?? ""] == "http://purl.org/dc/elements/1.1/" {
                    collecting = true
                } else { invalid = true }
            }
            stack.append(localName); namespaces.append(ns)
        }
        override func handleEndElement(name: String, localName: String, prefix: String?, parser: XMLParser) throws {
            if stack.count == 3 { collecting = false }
            _ = stack.popLast(); namespaces.removeLast()
        }
        override func handleCharacters(_ string: String, parser: XMLParser) throws {
            if collecting {
                guard string.utf8.count <= 4096 - text.utf8.count else { invalid = true; collecting = false; return }
                text += string
            }
        }
    }

    private final class Delegate: EPUBXMLBaseDelegate {
        let manifest: [String: String]
        let entries: Set<String>
        var fonts: [String: Algorithm] = [:]
        var sawRoot = false
        var stack: [String] = []
        var namespaces: [[String: String]] = []
        var algorithm: String?
        var resource: String?
        var sawCipherData = false

        init(manifest: [String: String], entries: Set<String>) {
            self.manifest = manifest
            self.entries = entries
        }

        override func handleStartElement(name: String, localName: String, prefix: String?,
                                          attributes: [String: String], parser: XMLParser) throws {
            var ns = namespaces.last ?? [:]
            for (key, value) in attributes {
                if key == "xmlns" { ns[""] = value }
                else if key.hasPrefix("xmlns:") { ns[String(key.dropFirst(6))] = value }
            }
            let ordinary = attributes.filter { $0.key != "xmlns" && !$0.key.hasPrefix("xmlns:") }
            let uri = ns[prefix ?? ""]
            switch (stack.last, localName) {
            case (nil, "encryption"):
                guard !sawRoot, ordinary.isEmpty,
                      uri == "urn:oasis:names:tc:opendocument:xmlns:container" else { throw EPUBError.unsupportedContent }
                sawRoot = true
            case ("encryption", "EncryptedData"):
                guard ordinary.isEmpty, uri == "http://www.w3.org/2001/04/xmlenc#" else { throw EPUBError.unsupportedContent }
                algorithm = nil; resource = nil; sawCipherData = false
            case ("EncryptedData", "EncryptionMethod"):
                guard algorithm == nil, ordinary.count == 1, let value = ordinary["Algorithm"],
                      ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"].contains(value),
                      uri == "http://www.w3.org/2001/04/xmlenc#" else { throw EPUBError.unsupportedContent }
                algorithm = value
            case ("EncryptedData", "CipherData"):
                guard !sawCipherData, ordinary.isEmpty, uri == "http://www.w3.org/2001/04/xmlenc#" else { throw EPUBError.unsupportedContent }
                sawCipherData = true
            case ("CipherData", "CipherReference"):
                guard resource == nil, ordinary.count == 1, let raw = ordinary["URI"],
                      uri == "http://www.w3.org/2001/04/xmlenc#" else { throw EPUBError.unsupportedContent }
                let resolved = try EPUBResourcePath.resolve(raw, relativeTo: "__archive_root__")
                guard resolved.fragment == nil, entries.contains(resolved.path),
                      let type = manifest[resolved.path],
                      EPUBAuthorStyles.isSupportedFontManifestMediaType(type) ||
                        ["font/woff", "font/woff2", "application/font-woff"].contains(type) else { throw EPUBError.unsupportedContent }
                resource = resolved.path
            default: throw EPUBError.unsupportedContent
            }
            stack.append(localName); namespaces.append(ns)
        }

        override func handleEndElement(name: String, localName: String, prefix: String?, parser: XMLParser) throws {
            guard stack.popLast() == localName else { throw EPUBError.unsupportedContent }
            namespaces.removeLast()
            if localName == "EncryptedData" {
                guard let algorithm, let kind = Algorithm(rawValue: algorithm), sawCipherData,
                      let resource, fonts[resource] == nil else {
                    throw EPUBError.unsupportedContent
                }
                fonts[resource] = kind
            }
        }

        override func handleCharacters(_ string: String, parser: XMLParser) throws {
            guard string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EPUBError.unsupportedContent }
        }
    }
}

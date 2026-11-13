import Foundation

/// Recognizes metadata only; never decrypts or serves protected bytes.
enum EPUBFontObfuscation {
    static func omittedFonts(data: Data, manifest: [String: String], entries: Set<String>, limit: Int) throws -> Set<String> {
        let prepared = try EPUBXMLSupport.prepareXMLData(data, limit: limit)
        let delegate = Delegate(manifest: manifest, entries: entries)
        try EPUBXMLSupport.parse(prepared, delegate: delegate)
        guard delegate.sawRoot, !delegate.fonts.isEmpty else { throw EPUBError.unsupportedContent }
        return delegate.fonts
    }

    private final class Delegate: EPUBXMLBaseDelegate {
        let manifest: [String: String]
        let entries: Set<String>
        var fonts: Set<String> = []
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
                guard algorithm != nil, sawCipherData, let resource, fonts.insert(resource).inserted else {
                    throw EPUBError.unsupportedContent
                }
            }
        }

        override func handleCharacters(_ string: String, parser: XMLParser) throws {
            guard string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EPUBError.unsupportedContent }
        }
    }
}

import Foundation

/// One unpublished extraction only. Does not touch the ZIP, library records or positions.
final class EPUBFontPreparation {
    struct Omitted: Error { let reason: EPUBFontDiagnostic.Outcome; let format: EPUBFontDiagnostic.Format }
    let entries: [String: EPUBExtractedEntry]
    let algorithms: [String: EPUBFontObfuscation.Algorithm]
    let idpfKey: Data?
    let adobeKey: Data?
    private(set) var identities: [String: EPUBFontIdentity] = [:]
    private(set) var resources: [String: EPUBResource] = [:]
    private(set) var outcomes: [String: EPUBFontDiagnostic.Outcome] = [:]
    private(set) var formats: [String: EPUBFontDiagnostic.Format] = [:]
    private var totalInputBytes = 0
    private var totalOutputBytes = 0
    private var omissions: [String: Omitted] = [:]

    init(entries: [String: EPUBExtractedEntry], algorithms: [String: EPUBFontObfuscation.Algorithm], idpfKey: Data?, adobeKey: Data? = nil) {
        self.entries = entries; self.algorithms = algorithms; self.idpfKey = idpfKey; self.adobeKey = adobeKey
    }

    func verify(path: String, under root: URL, declaredMediaType: String) throws -> String {
        guard try EPUBResourcePath.canonical(path) == path else { throw EPUBError.unsafePath }
        if let resource = resources[path] { return resource.mediaType }
        if let omitted = omissions[path] { throw omitted }
        guard let entry = entries[path] else { throw EPUBError.invalidPackage }
        guard entry.byteCount > 0 else { throw EPUBError.corruptResource }
        guard entry.byteCount <= EPUBAuthorStyles.maxFontBytes,
              entry.byteCount <= EPUBAuthorStyles.maxTotalFontBytes - totalInputBytes else { throw EPUBError.limitExceeded }
        // This walks every path component and refuses symlinks before any read/write.
        let url = try EPUBAuthorStyles.safeExistingFileURL(for: path, under: root, missingError: .corruptResource)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              values.fileSize == entry.byteCount else { throw EPUBError.corruptResource }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let original = try handle.read(upToCount: entry.byteCount + 1) ?? Data()
        guard original.count == entry.byteCount, EPUBResourceStore.digest(original) == entry.sha256 else {
            throw EPUBError.corruptResource // Integrity failure is never a presentation fallback.
        }
        totalInputBytes += original.count
        try Task.checkCancellation()
        var data = original
        var outcome: EPUBFontDiagnostic.Outcome = .verified
        var format = EPUBFontDiagnostic.formatCategory(declaredMediaType)
        func omit(_ reason: EPUBFontDiagnostic.Outcome) throws -> Never {
            let omission = Omitted(reason: reason, format: format)
            omissions[path] = omission
            throw omission
        }
        if let algorithm = algorithms[path] {
            switch algorithm {
            case .idpf:
                guard let idpfKey else { try omit(.obfuscationKeyUnavailable) }
                data = try EPUBFontObfuscation.restoreIDPF(data, key: idpfKey)
                outcome = .restoredIDPF
            case .adobe:
                guard let adobeKey else { try omit(.obfuscationKeyUnavailable) }
                data = try EPUBFontObfuscation.restoreAdobe(data, key: adobeKey)
                outcome = .restoredAdobe
            }
        }
        let magic = Array(data.prefix(4))
        if magic == [0x77, 0x4f, 0x46, 0x32] {
            format = .woff2
            try omit(.unsupportedFormat) // No bounded Brotli + transform decoder in this target.
        }
        if magic == [0x77, 0x4f, 0x46, 0x46] {
            format = .woff
            do { data = try EPUBWOFFDecoder.decode(data) }
            catch EPUBError.corruptResource { try omit(.invalidStructure) }
            catch EPUBError.unsupportedContent { try omit(.unsupportedFormat) }
            if outcome == .verified { outcome = .convertedWOFF }
        } else if magic == [0x00, 0x01, 0x00, 0x00] || magic == [0x74, 0x72, 0x75, 0x65] {
            format = .ttf
        } else if magic == [0x4f, 0x54, 0x54, 0x4f] {
            format = .otf
        } else { format = .other }
        let mediaType: String
        do { mediaType = try EPUBAuthorStyles.verifyFontData(data, declaredMediaType: declaredMediaType) }
        catch EPUBError.corruptResource { try omit(.invalidStructure) }
        catch EPUBError.unsupportedContent { try omit(.unsupportedFormat) }
        let identity = EPUBFontIdentity.extract(fromValidatedSFNT: data)
        guard data.count <= EPUBAuthorStyles.maxTotalFontBytes - totalOutputBytes else { throw EPUBError.limitExceeded }
        try Task.checkCancellation()
        if data != original { try data.write(to: url, options: .atomic) }
        totalOutputBytes += data.count
        resources[path] = EPUBResource(path: path, mediaType: mediaType,
            sha256: EPUBResourceStore.digest(data), byteCount: data.count)
        outcomes[path] = outcome; formats[path] = format
        identities[path] = identity
        return mediaType
    }
}

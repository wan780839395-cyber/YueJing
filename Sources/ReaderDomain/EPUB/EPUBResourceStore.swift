import CryptoKit
import Foundation

/// An immutable validated publication. No file URL is exposed to WebKit.
public enum EPUBResourceStore {
    public static func data(path: String, publication: EPUBPublication) throws -> Data {
        guard let resource = publication.package.resource(at: path) else { throw EPUBError.corruptResource }
        return try data(resource: resource, root: publication.resourceRoot)
    }

    /// Internal bulk-copy path: the caller is iterating the package's exact resource
    /// records already. Keep all path, symlink, size and SHA checks without N searches.
    static func data(resource: EPUBResource, root: URL) throws -> Data {
        let path = resource.path
        guard try EPUBResourcePath.canonical(path) == path,
              ["application/xhtml+xml", "image/jpeg", "image/png", "image/webp"].contains(resource.mediaType),
              resource.byteCount >= 0,
              resource.byteCount <= (resource.mediaType == "application/xhtml+xml" ? 8 : 16) * 1024 * 1024
        else { throw EPUBError.corruptResource }
        var url = root
        let rootValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw EPUBError.corruptResource }
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw EPUBError.corruptResource }
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, values.fileSize == resource.byteCount else { throw EPUBError.corruptResource }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let data = try input.read(upToCount: resource.byteCount + 1) ?? Data()
        guard data.count == resource.byteCount, digest(data) == resource.sha256 else { throw EPUBError.corruptResource }
        return data
    }

    public static func digest(_ data: Data) -> String {
        hexadecimal(SHA256.hash(data: data))
    }

    private static func hexadecimal(_ digest: SHA256.Digest) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(alphabet[Int(byte >> 4)])
            bytes.append(alphabet[Int(byte & 15)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func sourceDigest(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= EPUBLimits().compressedBytes else { throw EPUBError.invalidArchive }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(); var count = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            count += chunk.count
            guard count <= EPUBLimits().compressedBytes else { throw EPUBError.limitExceeded }
            hash.update(data: chunk)
        }
        guard count == size else { throw EPUBError.corruptResource }
        return hexadecimal(hash.finalize())
    }
}

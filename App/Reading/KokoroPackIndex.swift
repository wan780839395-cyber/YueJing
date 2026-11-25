import CryptoKit
import Foundation

enum KokoroPackError: Error { case invalid, storage }

/// An app resource derived from the digest-verified upstream archive, never from Files.
struct KokoroPackIndex: Sendable {
    static let rootName = "kokoro-int8-multi-lang-v1_1"
    static let archiveSHA256 = "259c9c8bc906d6078e4e0570421885dabb68b539c2f970fcbb890a58eeaf3e9c"
    private static let indexSHA256 = "6557d05836593bea0db5a76e0ff47822adcda5dfb3946a96cf2ccb767fc8f9cf"

    struct Member: Sendable {
        let path: String
        let bytes: Int
        let digest: String
    }
    let members: [Member]

    static func official() throws -> Self {
        guard let url = Bundle.main.url(forResource: "KokoroPack-v1_1", withExtension: "sha256") else {
            throw KokoroPackError.invalid
        }
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        guard hex(SHA256.hash(data: Data(text.utf8))) == indexSHA256 else { throw KokoroPackError.invalid }
        return try Self(text: text)
    }

    init(text: String) throws {
        var seen = Set<String>()
        members = try text.split(separator: "\n").map { line in
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count == 3, fields[0].utf8.count == 64,
                  fields[0].allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  let size = Int(fields[1]), size > 0 else { throw KokoroPackError.invalid }
            let path = String(fields[2])
            guard !path.contains("\\"), !path.utf8.contains(0),
                  path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  seen.insert(path.lowercased()).inserted else { throw KokoroPackError.invalid }
            return Member(path: path, bytes: size, digest: String(fields[0]))
        }
        guard !members.isEmpty else { throw KokoroPackError.invalid }
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

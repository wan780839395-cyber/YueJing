import Foundation
import ImageIO

/// Narrow compatibility for inert EPUB declarations and static raster resources.
/// No DTD is passed to XMLParser and no external identifier is ever fetched.
enum EPUBCompatibility {
    static func removingStandardDoctype(from xml: String) throws -> String {
        guard xml.range(of: "<!doctype", options: .caseInsensitive) != nil else { return xml }
        let trivia = #"[ \t\r\n]*(?:(?:<!--[\s\S]*?-->|<\?[^?]*\?>)[ \t\r\n]*)*"#
        let pattern = #"\A("# + trivia + #")<!DOCTYPE[ \t\r\n]+(html|ncx)(?:[ \t\r\n]+PUBLIC[ \t\r\n]+(["'])([^"']+)\3[ \t\r\n]+(["'])([^"']+)\5)?[ \t\r\n]*>"#
        let expression = try NSRegularExpression(pattern: pattern)
        let fullRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = expression.firstMatch(in: xml, range: fullRange),
              let rootRange = Range(match.range(at: 2), in: xml),
              let prefixRange = Range(match.range(at: 1), in: xml),
              let declarationRange = Range(NSRange(location: match.range(at: 1).length,
                                                   length: match.range.length - match.range(at: 1).length), in: xml)
        else { throw EPUBError.invalidPackage }
        // Do not accept a declaration hidden in a comment or PI, nor duplicate declarations.
        guard xml[prefixRange].range(of: "<!doctype", options: .caseInsensitive) == nil else {
            throw EPUBError.invalidPackage
        }
        let root = String(xml[rootRange])
        if match.range(at: 4).location == NSNotFound {
            guard root == "html" else { throw EPUBError.invalidPackage }
        } else {
            guard let publicRange = Range(match.range(at: 4), in: xml),
                  let systemRange = Range(match.range(at: 6), in: xml) else { throw EPUBError.invalidPackage }
            let allowed: [String: (String, String)] = [
                "-//W3C//DTD XHTML 1.1//EN": ("html", "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd"),
                "-//W3C//DTD XHTML 1.0 Strict//EN": ("html", "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd"),
                "-//W3C//DTD XHTML 1.0 Transitional//EN": ("html", "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd"),
                "-//W3C//DTD XHTML 1.0 Frameset//EN": ("html", "http://www.w3.org/TR/xhtml1/DTD/xhtml1-frameset.dtd"),
                "-//NISO//DTD ncx 2005-1//EN": ("ncx", "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd")
            ]
            guard let expected = allowed[String(xml[publicRange])], expected.0 == root,
                  String(xml[systemRange]) == expected.1 else { throw EPUBError.invalidPackage }
        }
        let suffix = String(xml[declarationRange.upperBound...])
        let rootExpression = try NSRegularExpression(pattern: #"\A"# + trivia + #"<([A-Za-z_][A-Za-z0-9_.:-]*)(?=[ \t\r\n/>])"#)
        guard let rootMatch = rootExpression.firstMatch(in: suffix, range: NSRange(suffix.startIndex..<suffix.endIndex, in: suffix)),
              let actualRoot = Range(rootMatch.range(at: 1), in: suffix), suffix[actualRoot] == root else {
            throw EPUBError.invalidPackage
        }
        var result = xml
        result.removeSubrange(declarationRange)
        guard result.range(of: "<!doctype", options: .caseInsensitive) == nil else { throw EPUBError.invalidPackage }
        return result
    }

    /// WebP is new input, so unlike legacy PNG/JPEG headers it must be fully decoded
    /// within finite byte/pixel bounds before being published as a served resource.
    static func verifyStaticWebP(_ data: Data) throws {
        guard data.count >= 20, data.count <= 16 * 1024 * 1024 else { throw EPUBError.corruptResource }
        let bytes = [UInt8](data)
        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) |
                (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }
        guard Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WEBP".utf8),
              UInt64(word(4)) + 8 == UInt64(bytes.count) else { throw EPUBError.corruptResource }
        var offset = 12
        var imageChunks = 0
        var canvas: (width: Int64, height: Int64)?
        while offset < bytes.count {
            guard bytes.count - offset >= 8 else { throw EPUBError.corruptResource }
            let size = Int(word(offset + 4))
            guard size <= bytes.count - offset - 8 else { throw EPUBError.corruptResource }
            let kind = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
            if kind == "ANIM" || kind == "ANMF" { throw EPUBError.unsupportedContent }
            if kind == "VP8X" {
                guard size == 10, offset == 12, canvas == nil else { throw EPUBError.corruptResource }
                guard bytes[offset + 8] & 0x02 == 0 else { throw EPUBError.unsupportedContent }
                func dimension(_ start: Int) -> Int64 {
                    1 + Int64(bytes[start]) + (Int64(bytes[start + 1]) << 8) + (Int64(bytes[start + 2]) << 16)
                }
                let w = dimension(offset + 12), h = dimension(offset + 15)
                guard w <= 16_384, h <= 16_384, w * h <= 40_000_000 else { throw EPUBError.limitExceeded }
                canvas = (w, h)
            }
            if kind == "VP8 " || kind == "VP8L" { imageChunks += 1 }
            let padded = size + size % 2
            guard padded <= bytes.count - offset - 8 else { throw EPUBError.corruptResource }
            offset += 8 + padded
        }
        guard offset == bytes.count, imageChunks == 1,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw EPUBError.corruptResource }
        let w = width.int64Value, h = height.int64Value
        guard w > 0, h > 0, w <= 16_384, h <= 16_384, w * h <= 40_000_000 else { throw EPUBError.limitExceeded }
        if let canvas {
            guard canvas.width == w, canvas.height == h else { throw EPUBError.corruptResource }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == Int(w), image.height == Int(h) else { throw EPUBError.corruptResource }
    }
}

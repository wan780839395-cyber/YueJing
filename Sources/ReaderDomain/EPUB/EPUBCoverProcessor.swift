import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Serial image decoding with predecode pixel limits and a bounded thumbnail cache.
public actor EPUBCoverProcessor {
    public static let shared = EPUBCoverProcessor()
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    public init() {}

    public func thumbnail(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= EPUBLimits().imageBytes, !Task.isCancelled else { return nil }
        let key = EPUBResourceStore.digest(data)
        if let value = cache[key] { return value }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let type = CGImageSourceGetType(source),
                  [UTType.jpeg.identifier, UTType.png.identifier].contains(type as String),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16384, height <= 16384,
                  width * height <= 40_000_000 else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  image.width <= 512, image.height <= 512 else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination), output.length <= 2 * 1024 * 1024 else { return nil }
            let result = output as Data
            while !order.isEmpty && (order.count >= 8 || cache.values.reduce(0, { $0 + $1.count }) + result.count > 4 * 1024 * 1024) {
                cache.removeValue(forKey: order.removeFirst())
            }
            cache[key] = result; order.append(key)
            return result
        }
    }
    public func clear() { cache.removeAll(); order.removeAll() }
}

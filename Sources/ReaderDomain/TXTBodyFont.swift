import CoreGraphics
import CoreText
import Foundation

/// An unregistered face shared by layout and drawing. The only stored reference
/// is an immutable CGFont backed by a data provider, with no mutable font cache.
public struct TXTBodyFont: @unchecked Sendable {
    private let face: CGFont

    public init?(data: Data) {
        guard (try? EPUBAuthorStyles.verifyFontData(data, declaredMediaType: "font/ttf",
                                                    maximumBytes: EPUBUserFontStore.maxFontBytes)) != nil,
              let provider = CGDataProvider(data: data as CFData),
              let face = CGFont(provider), face.numberOfGlyphs > 0 else { return nil }
        self.face = face
    }

    public func makeCTFont(size: CGFloat) -> CTFont {
        CTFontCreateWithGraphicsFont(face, size, nil, nil)
    }
}

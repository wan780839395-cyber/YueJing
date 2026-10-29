import CoreFoundation
import CoreGraphics
import Testing
import TXTCore
import UIKit
@testable import ReaderDomain
@testable import YueJing

@MainActor
@Suite(.serialized)
struct ReadingCanvasRenderingTests {
    @Test func dirtyRegionCoversTheSentinelInEveryThemeAndPreservesOutsidePixels() throws {
        let cell = try makeCell(theme: .paper)
        let canvas = try self.canvas(in: cell)
        for theme in [ReaderTheme.paper, .dark, .light] {
            cell.render(try slice(text: "CANVAS 汉字 e\u{301}"), preferences: ReaderPreferences(theme: theme))
            let dirty = CGRect(x: 0, y: canvas.bounds.midY - 6, width: canvas.bounds.width, height: 12)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3; format.opaque = false; format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(size: canvas.bounds.size, format: format).image { output in
                output.cgContext.setFillColor(UIColor.magenta.cgColor)
                output.cgContext.fill(canvas.bounds)
                output.cgContext.clip(to: dirty)
                canvas.draw(dirty)
            }
            let bitmap = try Bitmap(try #require(image.cgImage))
            #expect(bitmap.matches(theme.background, x: 30, y: bitmap.height / 2))
            #expect(bitmap.matches(.magenta, x: 30, y: 3))
        }
    }

    @Test func reuseRemovesOldInkAndAccessibilityActionsWithoutResettingTheTheme() throws {
        let cell = try makeCell(theme: .paper)
        let canvas = try self.canvas(in: cell)
        for theme in [ReaderTheme.paper, .dark, .light] {
            cell.render(try slice(text: "CANVAS 汉字 e\u{301}"), preferences: ReaderPreferences(theme: theme))
            cell.setToolActions([UIAccessibilityCustomAction(name: "Synthetic old action") { _ in true }])
            let before = try backingImage(canvas)
            let fresh = try makeCell(theme: theme)
            let reference = try backingImage(try self.canvas(in: fresh))
            let sameThemeRaster = before.bytes == reference.bytes
            #expect(sameThemeRaster, "A theme change on the same cell must match a fresh rendering")
            #expect(before.hasInk(on: theme.background))
            #expect(canvas.accessibilityLabel == "CANVAS 汉字 e\u{301}")
            cell.prepareForReuse()
            let cleared = try backingImage(canvas)
            #expect(cleared.isUniform(theme.background))
            #expect(canvas.accessibilityLabel == nil)
            #expect(canvas.accessibilityCustomActions?.isEmpty ?? true)
            cell.render(try slice(text: "NEW"), preferences: ReaderPreferences(theme: theme))
            #expect(canvas.accessibilityLabel == "NEW")
            #expect(try backingImage(canvas).hasInk(on: theme.background))
        }
    }

    @Test func fractionalResizeRerasterizesToTheSameImageAsAFreshCanvas() throws {
        let cell = try makeCell(theme: .paper)
        let canvas = try self.canvas(in: cell)
        let initial = try backingImage(canvas)
        let enlarged = CGSize(width: 280.75, height: 126.25)
        cell.frame.size = enlarged; cell.setNeedsLayout(); cell.layoutIfNeeded()
        #expect(canvas.frame == cell.contentView.bounds)
        #expect(canvas.layer.needsDisplay())
        let resized = try backingImage(canvas)
        let fresh = try makeCell(theme: .paper, size: enlarged)
        let reference = try backingImage(try self.canvas(in: fresh))
        #expect(resized.width > initial.width && resized.height > initial.height)
        #expect(resized.width == reference.width && resized.height == reference.height)
        let sameRaster = resized.bytes == reference.bytes
        #expect(sameRaster, "Resizing must redraw the original glyphs, not stretch the cached bitmap")
        #expect(resized.hasInk(on: ReaderTheme.paper.background))
    }

    private func makeCell(theme: ReaderTheme, size: CGSize = CGSize(width: 240.25, height: 80.5)) throws -> ReadingCell {
        #expect(Bundle.main.bundleIdentifier == "dev.yuejing.app", "Run inside the real YueJing App host")
        let cell = ReadingCell(style: .default, reuseIdentifier: "synthetic-canvas")
        cell.frame = CGRect(origin: .zero, size: size)
        cell.render(try slice(text: "CANVAS 汉字 e\u{301}"), preferences: ReaderPreferences(theme: theme))
        cell.setNeedsLayout(); cell.layoutIfNeeded()
        let view = try canvas(in: cell)
        view.contentScaleFactor = 3
        return cell
    }

    private func slice(text: String) throws -> ReadingSlice {
        let range = try UTF16Range(location: UTF16Offset(0), length: text.utf16.count)
        let line = ReadingLine(range: range, rawByteStart: 0, text: text, top: 4.25, baseline: 25.25, height: 31.25)
        return ReadingSlice(range: range, lines: [line], height: 80.5)
    }

    private func canvas(in cell: ReadingCell) throws -> UIView {
        try #require(cell.contentView.subviews.first { $0.accessibilityIdentifier == "reader.text.canvas" })
    }

    private func backingImage(_ canvas: UIView) throws -> Bitmap {
        canvas.layer.displayIfNeeded()
        let contents = try #require(canvas.layer.contents) as AnyObject
        try #require(CFGetTypeID(contents) == CGImage.typeID, "The canvas backing content must be a CGImage")
        // The CF type check above is required: Swift cannot conditionally downcast CF objects.
        return try Bitmap(contents as! CGImage)
    }

    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) throws {
            width = image.width; height = image.height
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            bytes = Array(UnsafeBufferPointer(start: data, count: width * height * 4))
        }

        func matches(_ color: UIColor, x: Int, y: Int) -> Bool {
            guard let expected = components(color) else { return false }
            return matches(expected, x: x, y: y)
        }

        private func components(_ color: UIColor) -> [Int]? {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
            return [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
        }

        private func matches(_ expected: [Int], x: Int, y: Int) -> Bool {
            let start = (y * width + x) * 4
            return (0..<4).allSatisfy { abs(Int(bytes[start + $0]) - expected[$0]) <= 2 }
        }

        func hasInk(on background: UIColor) -> Bool {
            guard let expected = components(background) else { return false }
            for y in 2..<(height - 2) {
                for x in 2..<(width - 2) where matches(expected, x: x, y: y) == false { return true }
            }
            return false
        }

        func isUniform(_ color: UIColor) -> Bool {
            guard let expected = components(color) else { return false }
            // Exclude the outermost raster pixels: fractional bounds can partially cover those pixels.
            for y in 2..<(height - 2) {
                for x in 2..<(width - 2) where matches(expected, x: x, y: y) == false { return false }
            }
            return true
        }
    }
}

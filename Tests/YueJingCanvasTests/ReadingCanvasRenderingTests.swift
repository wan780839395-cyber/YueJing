import CoreGraphics
import Testing
import TXTCore
import UIKit
@testable import ReaderDomain
@testable import YueJing

@MainActor
@Suite(.serialized)
struct ReadingCanvasRenderingTests {
    private let oldText = "CANVAS 汉字 e\u{301}"

    @Test func dirtyRegionCoversTheSentinelInEveryThemeAndPreservesOutsidePixels() throws {
        let window = try makeWindow()
        defer { window.isHidden = true; window.rootViewController = nil }
        let pixels = try PixelOracle(scale: window.screen.scale)
        try verifyCoverageOracle(pixels)
        let cell = try makeCell(theme: .paper)
        let canvas = try self.canvas(in: cell)
        let bounds = canvas.bounds
        // Deliberately asymmetric: a vertically flipped reader cannot pass by sampling the middle.
        let dirty = CGRect(x: 0, y: 8, width: bounds.width, height: 28)
        let sentinel = try pixels.raster(size: bounds.size) { paintSentinel(in: $0, bounds: bounds) }
        for theme in [ReaderTheme.paper, .dark, .light, .paper] {
            cell.render(try slice(text: oldText), preferences: ReaderPreferences(theme: theme))
            // The synthetic glyphs are well away from the right edge. Independently draw
            // background-only coverage there; do not assume a particular fractional blend.
            let edgeReference = try pixels.raster(size: bounds.size) { context in
                paintSentinel(in: context, bounds: bounds)
                context.clip(to: dirty)
                context.setBlendMode(.copy)
                context.setFillColor(theme.background.cgColor); context.fill(dirty)
            }
            let sequence = cell.canvasDrawSequence
            let bitmap = try pixels.raster(size: bounds.size) { context in
                paintSentinel(in: context, bounds: bounds)
                context.clip(to: dirty)
                // This calls the shared painter, NOT UIView.draw or a natural-display oracle.
                cell.paintCanvasForTesting(dirty, in: context)
            }
            #expect(cell.canvasDrawSequence == sequence)
            expectPixels(bitmap.matches(theme.background, x: Int(4 * pixels.scale), y: Int(12 * pixels.scale)), "Dirty background")
            expectPixels(bitmap.preservesOutside(dirty, from: sentinel, scale: pixels.scale), "Fully outside pixels changed")
            expectPixels(bitmap.matchesPartial(dirty, reference: edgeReference, scale: pixels.scale), "Partially covered edge differs from clipped background")
            expectPixels(bitmap.excludes(.magenta, in: dirty, scale: pixels.scale), "Sentinel remains inside dirty region")
            expectPixels(bitmap.hasInk(on: theme.background, in: dirty, scale: pixels.scale), "Missing glyph ink")
        }
    }

    @Test func reuseRemovesOldInkAndAccessibilityActionsWithoutResettingTheTheme() async throws {
        let window = try makeWindow()
        defer { window.isHidden = true; window.rootViewController = nil }
        let pixels = try PixelOracle(scale: window.screen.scale)
        let cell = try makeCell(theme: .paper)
        try mount(cell, in: window, slot: 0)
        try await waitForNaturalDraw(cell, after: 0)
        let canvas = try self.canvas(in: cell)
        for theme in [ReaderTheme.paper, .dark, .light, .paper] {
            // Prepare all references before freezing the action epoch. Whole-point origins
            // preserve the target's pixel phase without occluding any of the four canvases.
            let fresh = try makeCell(theme: theme)
            let newReference = try makeCell(theme: theme, text: "NEW")
            let silent = try makeCell(theme: theme)
            try mount(fresh, in: window, slot: 1)
            try mount(newReference, in: window, slot: 2)
            try mount(silent, in: window, slot: 3)
            defer { fresh.removeFromSuperview(); newReference.removeFromSuperview(); silent.removeFromSuperview() }
            for prepared in [fresh, newReference, silent] { try await waitForNaturalDraw(prepared, after: 0) }
            let reference = try sample(fresh, pixels: pixels)
            let newInk = try sample(newReference, pixels: pixels)
            let silentBefore = try sample(silent, pixels: pixels)
            let silentSequence = silent.canvasDrawSequence

            let beforeRender = cell.canvasDrawSequence
            cell.render(try slice(text: oldText), preferences: ReaderPreferences(theme: theme))
            cell.setToolActions([UIAccessibilityCustomAction(name: "Synthetic old action") { _ in true }])
            try requireInvalidation(cell, after: beforeRender)
            try await waitForNaturalDraw(cell, after: beforeRender)
            let rendered = try sample(cell, pixels: pixels)
            expectPixels(rendered.samePixels(as: reference), "A theme change must match a fresh canvas")
            expectPixels(rendered.hasInk(on: theme.background, in: canvas.bounds, scale: pixels.scale), "Theme lost glyph ink")
            #expect(canvas.accessibilityLabel == oldText)

            let beforeClear = cell.canvasDrawSequence
            cell.prepareForReuse()
            try requireInvalidation(cell, after: beforeClear)
            #expect(canvas.accessibilityLabel == nil)
            #expect(canvas.accessibilityCustomActions?.isEmpty ?? true)
            try await waitForNaturalDraw(cell, after: beforeClear)
            let cleared = try sample(cell, pixels: pixels)
            expectPixels(cleared.isUniform(theme.background, in: canvas.bounds, scale: pixels.scale), "Reuse left old ink")

            let beforeNew = cell.canvasDrawSequence
            cell.render(try slice(text: "NEW"), preferences: ReaderPreferences(theme: theme))
            try requireInvalidation(cell, after: beforeNew)
            try await waitForNaturalDraw(cell, after: beforeNew)
            let restored = try sample(cell, pixels: pixels)
            expectPixels(restored.samePixels(as: newInk), "New text differs from fresh canvas")
            expectPixels(restored.hasInk(on: theme.background, in: canvas.bounds, scale: pixels.scale), "New text has no ink")
            #expect(canvas.accessibilityLabel == "NEW")

            // No-action control shares every natural waiting phase and the same sampler.
            #expect(silent.canvasDrawSequence == silentSequence)
            let silentAfter = try sample(silent, pixels: pixels)
            #expect(silent.canvasDrawSequence == silentSequence)
            expectPixels(silentAfter.samePixels(as: silentBefore), "No-action control pixels changed")
            expectPixels(silentAfter.hasInk(on: theme.background, in: canvas.bounds, scale: pixels.scale), "No-action control lost ink")
        }
    }

    @Test func fractionalResizeRerasterizesToTheSameImageAsAFreshCanvas() async throws {
        let window = try makeWindow()
        defer { window.isHidden = true; window.rootViewController = nil }
        let pixels = try PixelOracle(scale: window.screen.scale)
        let enlarged = CGSize(width: 280.75, height: 126.25)
        let cell = try makeCell(theme: .paper)
        let fresh = try makeCell(theme: .paper, size: enlarged)
        let control = try makeCell(theme: .paper)
        let canvas = try self.canvas(in: cell)
        let controlCanvas = try self.canvas(in: control)
        // Disable the actual production resize trigger BEFORE establishing its baseline.
        controlCanvas.contentMode = .scaleToFill
        try mount(cell, in: window, slot: 0, slotSize: enlarged)
        try mount(fresh, in: window, slot: 1, slotSize: enlarged)
        try mount(control, in: window, slot: 2, slotSize: enlarged)
        for prepared in [cell, fresh, control] { try await waitForNaturalDraw(prepared, after: 0) }
        let initial = try sample(cell, pixels: pixels)
        let reference = try sample(fresh, pixels: pixels)
        let sequence = cell.canvasDrawSequence
        let controlSequence = control.canvasDrawSequence

        // The action contains no render, explicit display invalidation, or forced display.
        cell.frame.size = enlarged; cell.setNeedsLayout(); cell.layoutIfNeeded()
        control.frame.size = enlarged; control.setNeedsLayout(); control.layoutIfNeeded()
        #expect(canvas.frame == cell.contentView.bounds)
        #expect(controlCanvas.frame == control.contentView.bounds)
        try requireInvalidation(cell, after: sequence)
        try #require(!controlCanvas.layer.needsDisplay(), "The disabled-redraw control unexpectedly invalidated")
        try #require(control.canvasDrawSequence == controlSequence)
        try await waitForNaturalDraw(cell, after: sequence)
        let resized = try sample(cell, pixels: pixels)
        #expect(resized.width > initial.width && resized.height > initial.height)
        expectPixels(resized.samePixels(as: reference), "Resize must rerasterize, not stretch cached glyphs")
        expectPixels(resized.hasInk(on: ReaderTheme.paper.background, in: canvas.bounds, scale: pixels.scale), "Resize lost ink")

        // The SAME sampler must expose the stale raster, not repair the disabled redraw.
        try #require(control.canvasDrawSequence == controlSequence, "The negative control naturally redrew; oracle is inconclusive")
        #expect(control.canvasLastDrawBounds != controlCanvas.bounds)
        let stale = try sample(control, pixels: pixels)
        #expect(control.canvasDrawSequence == controlSequence)
        expectPixels(!stale.samePixels(as: reference), "Sampler concealed the missing resize redraw")
        print("Canvas resize negative control rejected: no new draw, stale bounds and pixels")
    }

    // Keep Bitmap (and its hundreds of thousands of bytes) outside assertion macro capture.
    private func expectPixels(_ success: Bool, _ message: String) {
        #expect(success, "\(message)")
    }

    private func paintSentinel(in context: CGContext, bounds: CGRect) {
        context.setFillColor(UIColor.magenta.cgColor); context.fill(bounds)
        context.setFillColor(UIColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 4))
        context.setFillColor(UIColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: bounds.height - 8, width: bounds.width, height: 8))
    }

    private func verifyCoverageOracle(_ pixels: PixelOracle) throws {
        // Pixel-space table: outside/touching, fully covered, half covered, quarter covered.
        let cases: [(CGRect, Int)] = [
            (CGRect(x: 1, y: 0, width: 1, height: 1), 0),
            (CGRect(x: -1, y: 0, width: 1, height: 1), 0),
            (CGRect(x: 0, y: 1, width: 1, height: 1), 0),
            (CGRect(x: 0, y: -1, width: 1, height: 1), 0),
            (CGRect(x: 0, y: 0, width: 1, height: 1), 1),
            (CGRect(x: 0, y: 0, width: 0.5, height: 1), 2),
            (CGRect(x: 0.5, y: 0, width: 1, height: 1), 2),
            (CGRect(x: 0, y: 0, width: 1, height: 0.5), 2),
            (CGRect(x: 0, y: 0.5, width: 1, height: 1), 2),
            (CGRect(x: 0.5, y: 0.5, width: 1, height: 1), 2),
        ]
        for (rect, expected) in cases {
            let actual = Bitmap.coverage(x: 0, y: 0, dirtyPixels: rect)
            #expect(actual == expected, "Coverage classification for \(rect)")
        }
        let size = CGSize(width: 8, height: 8), bounds = CGRect(origin: .zero, size: CGSize(width: 8, height: 8))
        let dirty = CGRect(x: 2, y: 2, width: 2 + 0.5 / pixels.scale, height: 2 + 0.5 / pixels.scale)
        let sentinel = try pixels.raster(size: size) { context in
            context.setFillColor(UIColor.magenta.cgColor); context.fill(bounds)
        }
        let filled = try pixels.raster(size: size) { context in
            context.setFillColor(UIColor.magenta.cgColor); context.fill(bounds)
            context.clip(to: dirty); context.setBlendMode(.copy)
            context.setFillColor(UIColor.white.cgColor); context.fill(dirty)
        }
        expectPixels(filled.preservesOutside(dirty, from: sentinel, scale: pixels.scale), "Oracle positive: outside")
        expectPixels(filled.matchesPartial(dirty, reference: filled, scale: pixels.scale), "Oracle positive: partial")
        expectPixels(filled.excludes(.magenta, in: dirty, scale: pixels.scale), "Oracle positive: interior")
        // Change one byte outside, on a partial edge, and restore sentinel inside.
        for point in [(0, 0), (filled.width - 1, 0), (0, filled.height - 1), (filled.width - 1, filled.height - 1)] {
            let bad = filled.changingByte(x: point.0, y: point.1)
            expectPixels(!bad.preservesOutside(dirty, from: sentinel, scale: pixels.scale), "Oracle missed external one-byte change")
        }
        let edgeX = Int(floor(dirty.maxX * pixels.scale)), edgeY = Int(3 * pixels.scale)
        let wrongEdge = filled.changingByte(x: edgeX, y: edgeY)
        expectPixels(!wrongEdge.matchesPartial(dirty, reference: filled, scale: pixels.scale), "Oracle missed partial-edge change")
        expectPixels(!sentinel.matchesPartial(dirty, reference: filled, scale: pixels.scale), "Oracle missed unpainted partial edge")
        let inside = Int(3 * pixels.scale)
        let uncleared = filled.replacingPixel(x: inside, y: inside, from: sentinel)
        expectPixels(!uncleared.excludes(.magenta, in: dirty, scale: pixels.scale), "Oracle missed interior sentinel")
        print("Coverage oracle: classification and outside/partial/interior fault controls completed")
    }

    private func makeWindow() throws -> UIWindow {
        try #require(Bundle.main.bundleIdentifier == "dev.yuejing.app", "Use the real YueJing App host")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }, "An active App-host scene is required")
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        let controller = UIViewController()
        controller.view.backgroundColor = .white
        window.rootViewController = controller
        window.isHidden = false // Do not replace the App's key window or its route owner.
        return window
    }

    private func makeCell(theme: ReaderTheme, size: CGSize = CGSize(width: 240.25, height: 80.5),
                          text: String? = nil) throws -> ReadingCell {
        let cell = ReadingCell(style: .default, reuseIdentifier: "synthetic-canvas")
        cell.frame = CGRect(origin: .zero, size: size)
        cell.render(try slice(text: text ?? oldText), preferences: ReaderPreferences(theme: theme))
        cell.setNeedsLayout(); cell.layoutIfNeeded()
        return cell
    }

    private func mount(_ cell: ReadingCell, in window: UIWindow, slot: Int,
                       slotSize: CGSize = CGSize(width: 240.25, height: 80.5)) throws {
        let root = try #require(window.rootViewController?.view)
        // Integer-point strides preserve phase in either orientation; no overlapping references.
        let strideX = ceil(slotSize.width) + 16, strideY = ceil(slotSize.height) + 16
        let columns = max(1, Int(floor((window.bounds.width - 16) / strideX)))
        cell.frame.origin = CGPoint(x: 16 + CGFloat(slot % columns) * strideX,
                                    y: 16 + CGFloat(slot / columns) * strideY)
        root.addSubview(cell)
        cell.setNeedsLayout(); cell.layoutIfNeeded()
        let canvas = try self.canvas(in: cell)
        try #require(canvas.window === window && !window.isHidden)
        try #require(window.bounds.contains(cell.convert(cell.bounds, to: window)), "Fixture must remain visible")
        try #require(canvas.contentScaleFactor == window.screen.scale)
    }

    private func slice(text: String) throws -> ReadingSlice {
        let range = try UTF16Range(location: UTF16Offset(0), length: text.utf16.count)
        let line = ReadingLine(range: range, rawByteStart: 0, text: text, top: 4.25, baseline: 25.25, height: 31.25)
        return ReadingSlice(range: range, lines: [line], height: 80.5)
    }

    private func canvas(in cell: ReadingCell) throws -> UIView {
        try #require(cell.contentView.subviews.first { $0.accessibilityIdentifier == "reader.text.canvas" })
    }

    private func requireInvalidation(_ cell: ReadingCell, after sequence: Int) throws {
        let canvas = try self.canvas(in: cell)
        try #require(cell.canvasDrawSequence == sequence, "Action must invalidate, not synchronously draw")
        try #require(canvas.layer.needsDisplay(), "Production action did not invalidate the canvas")
    }

    private func waitForNaturalDraw(_ cell: ReadingCell, after sequence: Int) async throws {
        let canvas = try self.canvas(in: cell)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if cell.canvasDrawSequence > sequence && cell.canvasLastDrawBounds == canvas.bounds && !canvas.layer.needsDisplay() {
                return
            }
            // Condition polling yields MainActor to UIKit. Elapsed time alone NEVER means success.
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(cell.canvasDrawSequence > sequence && cell.canvasLastDrawBounds == canvas.bounds && !canvas.layer.needsDisplay(),
                     "Natural draw timed out: sequence \(sequence) -> \(cell.canvasDrawSequence), bounds \(canvas.bounds), last \(cell.canvasLastDrawBounds), dirty rect \(cell.canvasLastDirtyRect)")
    }

    private func sample(_ cell: ReadingCell, pixels: PixelOracle) throws -> Bitmap {
        let canvas = try self.canvas(in: cell)
        try #require(canvas.window != nil && cell.canvasDrawSequence > 0)
        try #require(!canvas.layer.needsDisplay(), "Sampling cannot complete pending display work")
        try #require(canvas.contentScaleFactor == pixels.scale)
        let sequence = cell.canvasDrawSequence
        let bitmap = try pixels.raster(size: canvas.bounds.size) { canvas.layer.render(in: $0) }
        try #require(cell.canvasDrawSequence == sequence && !canvas.layer.needsDisplay(), "Sampling caused a canvas draw/invalidation")
        // This observes a layer-tree raster, NOT the GPU screen or a physical-device seam.
        return bitmap
    }

    @MainActor
    private struct PixelOracle {
        let scale: CGFloat
        let rowsAreTopDown: Bool

        init(scale: CGFloat) throws {
            try #require(scale > 0 && scale.isFinite)
            self.scale = scale
            let card = Self.image(size: CGSize(width: 12, height: 20), scale: scale) { context in
                context.setFillColor(UIColor.green.cgColor); context.fill(CGRect(x: 0, y: 0, width: 12, height: 20))
                context.setFillColor(UIColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 12, height: 4))
                context.setFillColor(UIColor.blue.cgColor); context.fill(CGRect(x: 0, y: 15, width: 12, height: 5))
            }
            let raw = try Bitmap(try #require(card.cgImage), rowsAreTopDown: true)
            let x = Int(scale), top = Int(scale), bottom = Int(18 * scale)
            let forward = raw.matches(.red, x: x, y: top) && raw.matches(.blue, x: x, y: bottom)
            let reverse = raw.matches(.blue, x: x, y: top) && raw.matches(.red, x: x, y: bottom)
            try #require(forward || reverse, "RGBA/row orientation calibration failed")
            try #require(raw.matches(.green, x: x, y: Int(10 * scale)), "sRGB/alpha calibration failed")
            rowsAreTopDown = forward
            print("Canvas pixel calibration: scale=\(scale), rowsAreTopDown=\(forward)")
        }

        func raster(size: CGSize, paint: (CGContext) -> Void) throws -> Bitmap {
            let image = Self.image(size: size, scale: scale, paint: paint)
            return try Bitmap(try #require(image.cgImage), rowsAreTopDown: rowsAreTopDown)
        }

        private static func image(size: CGSize, scale: CGFloat, paint: (CGContext) -> Void) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale; format.opaque = false; format.preferredRange = .standard
            return UIGraphicsImageRenderer(size: size, format: format).image { paint($0.cgContext) }
        }
    }

    @MainActor
    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        let rowsAreTopDown: Bool

        init(_ image: CGImage, rowsAreTopDown: Bool) throws {
            width = image.width; height = image.height; self.rowsAreTopDown = rowsAreTopDown
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            bytes = Array(UnsafeBufferPointer(start: data, count: width * height * 4))
        }

        private init(width: Int, height: Int, bytes: [UInt8], rowsAreTopDown: Bool) {
            self.width = width; self.height = height; self.bytes = bytes; self.rowsAreTopDown = rowsAreTopDown
        }

        func samePixels(as other: Bitmap) -> Bool {
            width == other.width && height == other.height && rowsAreTopDown == other.rowsAreTopDown && bytes == other.bytes
        }

        func matches(_ color: UIColor, x: Int, y: Int) -> Bool {
            guard let expected = components(color) else { return false }
            return matches(expected, x: x, y: y)
        }

        private func components(_ color: UIColor) -> [Int]? {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let converted = color.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
                  let c = converted.components, c.count == 4 else { return nil }
            return [c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3]].map { Int(($0 * 255).rounded()) }
        }

        private func offset(x: Int, y: Int) -> Int { ((rowsAreTopDown ? y : height - 1 - y) * width + x) * 4 }

        private func matches(_ expected: [Int], x: Int, y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            let start = offset(x: x, y: y)
            return (0..<4).allSatisfy { abs(Int(bytes[start + $0]) - expected[$0]) <= 1 }
        }

        // Only partially covered LAST rows/columns are excluded; no blanket 2px border blind spot.
        private func allCoveredPixels(in rect: CGRect, scale: CGFloat, match: (Int, Int) -> Bool) -> Bool {
            let left = max(0, Int(ceil(rect.minX * scale))), right = min(width, Int(floor(rect.maxX * scale)))
            let top = max(0, Int(ceil(rect.minY * scale))), bottom = min(height, Int(floor(rect.maxY * scale)))
            guard left < right, top < bottom else { return false }
            for y in top..<bottom { for x in left..<right where !match(x, y) { return false } }
            return true
        }

        func isUniform(_ color: UIColor, in rect: CGRect, scale: CGFloat) -> Bool {
            guard let expected = components(color) else { return false }
            return allCoveredPixels(in: rect, scale: scale) { matches(expected, x: $0, y: $1) }
        }

        func excludes(_ color: UIColor, in rect: CGRect, scale: CGFloat) -> Bool {
            guard let expected = components(color) else { return false }
            return allCoveredPixels(in: rect, scale: scale) { !matches(expected, x: $0, y: $1) }
        }

        func hasInk(on color: UIColor, in rect: CGRect, scale: CGFloat) -> Bool {
            guard let expected = components(color) else { return false }
            var covered = false
            let allBackground = allCoveredPixels(in: rect, scale: scale) { x, y in
                covered = true; return matches(expected, x: x, y: y)
            }
            return covered && !allBackground
        }

        // 0 = zero area, 1 = full pixel, 2 = partial pixel. Touching is not coverage.
        static func coverage(x: Int, y: Int, dirtyPixels: CGRect) -> Int {
            let left = max(CGFloat(x), dirtyPixels.minX), right = min(CGFloat(x + 1), dirtyPixels.maxX)
            let top = max(CGFloat(y), dirtyPixels.minY), bottom = min(CGFloat(y + 1), dirtyPixels.maxY)
            guard right > left, bottom > top else { return 0 }
            return right - left == 1 && bottom - top == 1 ? 1 : 2
        }

        func preservesOutside(_ dirty: CGRect, from reference: Bitmap, scale: CGFloat) -> Bool {
            matchesCoverage(0, dirty: dirty, reference: reference, scale: scale)
        }

        func matchesPartial(_ dirty: CGRect, reference: Bitmap, scale: CGFloat) -> Bool {
            matchesCoverage(2, dirty: dirty, reference: reference, scale: scale)
        }

        private func matchesCoverage(_ kind: Int, dirty: CGRect, reference: Bitmap, scale: CGFloat) -> Bool {
            guard width == reference.width, height == reference.height, rowsAreTopDown == reference.rowsAreTopDown else { return false }
            let rect = CGRect(x: dirty.minX * scale, y: dirty.minY * scale,
                              width: dirty.width * scale, height: dirty.height * scale)
            var checked = 0, differences = 0, first: [String] = []
            for y in 0..<height {
                for x in 0..<width where Self.coverage(x: x, y: y, dirtyPixels: rect) == kind {
                    checked += 1
                    let a = offset(x: x, y: y), b = reference.offset(x: x, y: y)
                    if (0..<4).contains(where: { bytes[a + $0] != reference.bytes[b + $0] }) {
                        differences += 1
                        if first.count < 8 { first.append("(\(x),\(y))") }
                    }
                }
            }
            if differences > 0 || checked == 0 {
                print("Coverage kind=\(kind) size=\(width)x\(height) scale=\(scale) dirty=\(dirty) checked=\(checked) differences=\(differences) first=\(first)")
            }
            return checked > 0 && differences == 0
        }

        func changingByte(x: Int, y: Int) -> Bitmap {
            var modified = bytes
            modified[offset(x: x, y: y)] ^= 1
            return Bitmap(width: width, height: height, bytes: modified, rowsAreTopDown: rowsAreTopDown)
        }

        func replacingPixel(x: Int, y: Int, from reference: Bitmap) -> Bitmap {
            var modified = bytes
            let a = offset(x: x, y: y), b = reference.offset(x: x, y: y)
            for channel in 0..<4 { modified[a + channel] = reference.bytes[b + channel] }
            return Bitmap(width: width, height: height, bytes: modified, rowsAreTopDown: rowsAreTopDown)
        }
    }
}

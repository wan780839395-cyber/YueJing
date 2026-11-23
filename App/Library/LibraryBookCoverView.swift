import Foundation
import ReaderDomain
import SwiftUI
import UIKit

/// Bounded decoded cover cache on MainActor to avoid retaining all shelf covers in memory.
@MainActor
final class LibraryCoverMemoryCache {
    static let shared = LibraryCoverMemoryCache()
    private let maxEntries = 8
    private var images: [String: UIImage] = [:]
    private var order: [String] = []

    func image(for key: String) -> UIImage? {
        guard let value = images[key] else { return nil }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return value
    }

    func insert(_ image: UIImage, for key: String) {
        if images[key] != nil, let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        while order.count >= maxEntries {
            let oldest = order.removeFirst()
            images.removeValue(forKey: oldest)
        }
        images[key] = image
        order.append(key)
    }

    func clear() {
        images.removeAll()
        order.removeAll()
    }
}

/// Lazy per-book cover view with pixel-safe validation and automatic typographic placeholder fallback.
@MainActor
struct LibraryBookCoverView: View {
    let book: LibraryBook
    let appearance: LibraryAppearance
    var size: CGSize = CGSize(width: LibraryAppearance.coverWidth, height: LibraryAppearance.coverHeight)
    var coverLoader: (@Sendable (String) async -> Data?)? = nil
    var onCoverResolved: (@MainActor (UIImage?) -> Void)? = nil
    @State private var resolvedCover: (key: String, image: UIImage?)?

    private var cacheKey: String { book.id + ":" + book.versionID }
    private var cornerRadius: CGFloat { max(6, min(11, size.width * 0.13)) }

    private var displayedCoverImage: UIImage? {
        guard book.format == .epub else { return nil }
        if let resolvedCover, resolvedCover.key == cacheKey {
            return resolvedCover.image
        }
        return LibraryCoverMemoryCache.shared.image(for: cacheKey)
    }

    var body: some View {
        let isLarge = size.width >= 72
        ZStack {
            if let displayed = displayedCoverImage {
                Image(uiImage: displayed)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .overlay(alignment: .leading) {
                        // Subtle physical book-spine lighting crease
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.20),
                                Color.white.opacity(0.16),
                                Color.black.opacity(0.06),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(6, size.width * 0.13))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(appearance.edge.opacity(0.75), lineWidth: 0.6)
                    }
                    .shadow(color: appearance.shadow, radius: isLarge ? 9 : 4, x: 0, y: isLarge ? 5 : 2)
                    .accessibilityHidden(true)
            } else {
                LibraryCoverPlaceholder(
                    title: book.title,
                    appearance: appearance,
                    formatLabel: book.format == .epub ? "EPUB" : "TXT",
                    size: size
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: cacheKey) {
            let key = cacheKey
            guard book.format == .epub else {
                resolvedCover = (key, nil)
                onCoverResolved?(nil)
                return
            }
            if let cached = LibraryCoverMemoryCache.shared.image(for: key) {
                resolvedCover = (key, cached)
                onCoverResolved?(cached)
                return
            }
            let resolved = await Self.resolveCoverImage(for: book, loader: coverLoader)
            guard !Task.isCancelled else { return }
            resolvedCover = (key, resolved)
            onCoverResolved?(resolved)
        }
    }

    static func resolveCoverImage(
        for book: LibraryBook,
        loader: (@Sendable (String) async -> Data?)?
    ) async -> UIImage? {
        guard book.format == .epub, let loader else { return nil }
        let key = book.id + ":" + book.versionID
        if let cached = LibraryCoverMemoryCache.shared.image(for: key) {
            return cached
        }
        guard let rawData = await loader(book.id),
              !rawData.isEmpty,
              rawData.count <= 2 * 1024 * 1024,
              !Task.isCancelled else {
            return nil
        }
        guard let validatedPNG = await EPUBCoverProcessor.shared.thumbnail(rawData),
              !Task.isCancelled,
              let image = UIImage(data: validatedPNG),
              let cgImage = image.cgImage,
              cgImage.width > 0, cgImage.height > 0,
              cgImage.width <= 512, cgImage.height <= 512 else {
            return nil
        }
        LibraryCoverMemoryCache.shared.insert(image, for: key)
        return image
    }
}

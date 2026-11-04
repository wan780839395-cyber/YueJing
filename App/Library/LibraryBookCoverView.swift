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
    var coverLoader: (@Sendable (String) async -> Data?)? = nil
    var onCoverResolved: (@MainActor (UIImage?) -> Void)? = nil
    @State private var coverImage: UIImage?

    private var cacheKey: String { book.id + ":" + book.versionID }

    var body: some View {
        ZStack {
            if let displayed = coverImage ?? (book.format == .epub ? LibraryCoverMemoryCache.shared.image(for: cacheKey) : nil) {
                Image(uiImage: displayed)
                    .resizable()
                    .scaledToFill()
                    .frame(width: LibraryAppearance.coverWidth, height: LibraryAppearance.coverHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(appearance.edge.opacity(0.65), lineWidth: 0.5)
                    }
                    .accessibilityHidden(true)
            } else {
                LibraryCoverPlaceholder(title: book.title, appearance: appearance)
            }
        }
        .frame(width: LibraryAppearance.coverWidth, height: LibraryAppearance.coverHeight)
        .task(id: cacheKey) {
            guard book.format == .epub else {
                coverImage = nil
                onCoverResolved?(nil)
                return
            }
            if let cached = LibraryCoverMemoryCache.shared.image(for: cacheKey) {
                coverImage = cached
                onCoverResolved?(cached)
                return
            }
            let resolved = await Self.resolveCoverImage(for: book, loader: coverLoader)
            guard !Task.isCancelled else { return }
            coverImage = resolved
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

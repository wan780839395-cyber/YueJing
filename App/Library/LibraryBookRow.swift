import Foundation
import ReaderDomain
import SwiftUI

/// Pure formatting of real persisted LibraryBook metrics; never invents progress or author metadata.
enum LibraryBookMetrics {
    static func volumeLabel(for book: LibraryBook) -> String? {
        fileSizeLabel(book.byteCount)
    }

    private static func fileSizeLabel(_ bytes: Int) -> String? {
        guard bytes > 0 else { return nil }
        let kb = 1024.0
        let mb = kb * kb
        let gb = mb * kb
        let value = Double(bytes)
        if value >= gb {
            return String(format: "%.1f GB", value / gb)
        }
        if value >= mb {
            return String(format: "%.1f MB", value / mb)
        }
        let roundedKB = max(1, Int((value / kb).rounded()))
        return "\(roundedKB) KB"
    }
    static func encodingLabel(for book: LibraryBook) -> String? {
        guard book.format == .txt else { return nil }
        switch book.encodingRaw {
        case "GB18030-2000": return "GB18030"
        case "GBK-95": return "GBK"
        case "": return nil
        default: return book.encodingRaw
        }
    }

    static func shortDate(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(date: .numeric, time: .omitted)
    }

    static func shortTimestamp(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(date: .numeric, time: .shortened)
    }

    static func editionSummary(for book: LibraryBook) -> String {
        var parts: [String] = []
        if let encoding = encodingLabel(for: book) {
            parts.append(encoding)
        }
        if let volume = volumeLabel(for: book) {
            parts.append(volume)
        }
        parts.append("入架 " + shortTimestamp(book.addedAt))
        return parts.joined(separator: " · ")
    }

    static func formatBadge(for book: LibraryBook, hasEmbeddedCover: Bool) -> String {
        switch book.format {
        case .txt:
            return "TXT"
        case .epub:
            return hasEmbeddedCover ? "EPUB · 封面" : "EPUB · 文字占位"
        }
    }
}

/// Editorial list card for a real book. Caller owns book identity and the open action.
@MainActor
struct LibraryBookRow: View {
    let book: LibraryBook
    let appearance: LibraryAppearance
    var coverLoader: (@Sendable (String) async -> Data?)? = nil
    var showsEditionDetails: Bool = false
    @State private var resolvedCoverKey: String?

    private var coverKey: String { book.id + ":" + book.versionID }

    private var formatBadge: String {
        let hasResolved = resolvedCoverKey == coverKey
        let cached = book.format == .epub && LibraryCoverMemoryCache.shared.image(for: coverKey) != nil
        return LibraryBookMetrics.formatBadge(for: book, hasEmbeddedCover: hasResolved || cached)
    }
    private var volumeText: String? { LibraryBookMetrics.volumeLabel(for: book) }

    var body: some View {
        HStack(alignment: .center, spacing: 15) {
            LibraryBookCoverView(
                book: book,
                appearance: appearance,
                coverLoader: coverLoader,
                onCoverResolved: { image in
                    resolvedCoverKey = image == nil ? nil : coverKey
                }
            )
            VStack(alignment: .leading, spacing: 7) {
                Text(book.title)
                    .font(LibraryAppearance.bookTitleFont)
                    .foregroundStyle(appearance.foreground)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(formatBadge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(book.format == .epub ? appearance.accent : appearance.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            (book.format == .epub ? appearance.accentSoft : appearance.subtleSurface),
                            in: Capsule()
                        )
                    if let volumeText {
                        Text(volumeText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(appearance.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if showsEditionDetails {
                    editionDisambiguator
                }

                if let date = book.lastReadAt {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("最近阅读")
                            Text("·").accessibilityHidden(true)
                            Text(Date(timeIntervalSince1970: date), style: .date)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("最近阅读")
                            Text(Date(timeIntervalSince1970: date), style: .date)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                } else {
                    Text("新加入 · 尚未阅读")
                        .font(.caption)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(appearance.secondary.opacity(0.65))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: LibraryAppearance.minimumControlHeight, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.75), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: appearance.cardShadow, radius: 6, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
    }

    private var editionDisambiguator: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle()
                .fill(appearance.sealAccent)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text("同名副本 · \(LibraryBookMetrics.editionSummary(for: book))")
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(appearance.foreground.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(appearance.sealSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Spotlight folio card for the top book on the shelf (most recently read or newly added).
@MainActor
struct LibraryHeroBookCard: View {
    let book: LibraryBook
    let appearance: LibraryAppearance
    var coverLoader: (@Sendable (String) async -> Data?)? = nil
    var showsEditionDetails: Bool = false
    @State private var resolvedCoverKey: String?
    @Environment(\.dynamicTypeSize) private var dynamicType

    private var coverKey: String { book.id + ":" + book.versionID }

    private var formatBadge: String {
        let hasResolved = resolvedCoverKey == coverKey
        let cached = book.format == .epub && LibraryCoverMemoryCache.shared.image(for: coverKey) != nil
        return LibraryBookMetrics.formatBadge(for: book, hasEmbeddedCover: hasResolved || cached)
    }
    private var volumeText: String? { LibraryBookMetrics.volumeLabel(for: book) }
    private var hasBeenRead: Bool { book.lastReadAt != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(hasBeenRead ? appearance.sealAccent : appearance.accent)
                    .frame(width: 3, height: 13)
                Text(hasBeenRead ? "案头续读" : "新卷入斋")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(hasBeenRead ? appearance.sealAccent : appearance.accent)
                Spacer(minLength: 8)
                if let volumeText {
                    Text(volumeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(appearance.secondary)
                }
            }
            .accessibilityHidden(true)

            Group {
                if dynamicType.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) {
                        coverView
                        detailsColumn
                    }
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        coverView
                        detailsColumn
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [appearance.elevatedSurface, appearance.surface],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                // Whisper-quiet editorial aura in the upper-right corner
                RadialGradient(
                    colors: [
                        (hasBeenRead ? appearance.sealAccent : appearance.accent).opacity(appearance.isDarkSurface ? 0.11 : 0.065),
                        Color.clear
                    ],
                    center: .topTrailing,
                    startRadius: 8,
                    endRadius: 170
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(appearance.isDarkSurface ? 0.10 : 0.75),
                            appearance.edge.opacity(0.85)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.85
                )
                .allowsHitTesting(false)
        }
        .shadow(color: appearance.shadow, radius: 15, x: 0, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var coverView: some View {
        LibraryBookCoverView(
            book: book,
            appearance: appearance,
            size: CGSize(width: LibraryAppearance.heroCoverWidth, height: LibraryAppearance.heroCoverHeight),
            coverLoader: coverLoader,
            onCoverResolved: { image in
                resolvedCoverKey = image == nil ? nil : coverKey
            }
        )
    }

    private var detailsColumn: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Keep title as the first accessible text inside the combined button.
            Text(book.title)
                .font(LibraryAppearance.heroBookTitleFont)
                .foregroundStyle(appearance.foreground)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(formatBadge)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(book.format == .epub ? appearance.accent : appearance.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(
                    book.format == .epub ? appearance.accentSoft : appearance.subtleSurface,
                    in: Capsule()
                )

            if showsEditionDetails {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Circle()
                        .fill(appearance.sealAccent)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text("同名副本 · \(LibraryBookMetrics.editionSummary(for: book))")
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(appearance.foreground.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(appearance.sealSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let date = book.lastReadAt {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("最近阅读")
                    Text(Date(timeIntervalSince1970: date), style: .date)
                }
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("新加入 · 尚未阅读")
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Text(hasBeenRead ? "继续阅读" : "启卷阅读")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(appearance.accent)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(appearance.accentSoft, in: Capsule())
            .padding(.top, 2)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Editorial 2-column gallery card for the shelf collection.
@MainActor
struct LibraryBookGridCard: View {
    let book: LibraryBook
    let appearance: LibraryAppearance
    var coverLoader: (@Sendable (String) async -> Data?)? = nil
    var showsEditionDetails: Bool = false
    @State private var resolvedCoverKey: String?

    private var coverKey: String { book.id + ":" + book.versionID }

    private var formatBadge: String {
        let hasResolved = resolvedCoverKey == coverKey
        let cached = book.format == .epub && LibraryCoverMemoryCache.shared.image(for: coverKey) != nil
        return LibraryBookMetrics.formatBadge(for: book, hasEmbeddedCover: hasResolved || cached)
    }
    private var volumeText: String? { LibraryBookMetrics.volumeLabel(for: book) }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(appearance.subtleSurface.opacity(0.75))
                LibraryBookCoverView(
                    book: book,
                    appearance: appearance,
                    size: CGSize(width: 72, height: 102),
                    coverLoader: coverLoader,
                    onCoverResolved: { image in
                        resolvedCoverKey = image == nil ? nil : coverKey
                    }
                )
                .padding(.vertical, 14)
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(LibraryAppearance.bookTitleFont)
                    .foregroundStyle(appearance.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(formatBadge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(book.format == .epub ? appearance.accent : appearance.secondary)
                        .lineLimit(1)
                    if let volumeText, !showsEditionDetails {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(appearance.secondary.opacity(0.65))
                            .accessibilityHidden(true)
                        Text(volumeText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(appearance.secondary)
                            .lineLimit(1)
                    }
                }

                if showsEditionDetails {
                    Text("同名 · \(LibraryBookMetrics.editionSummary(for: book))")
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(appearance.sealAccent)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(appearance.sealSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                if let date = book.lastReadAt {
                    HStack(spacing: 4) {
                        Text("最近阅读")
                        Text(Date(timeIntervalSince1970: date), style: .date)
                    }
                    .font(.caption2)
                    .foregroundStyle(appearance.secondary)
                    .lineLimit(1)
                } else {
                    Text("新加入 · 尚未阅读")
                        .font(.caption2)
                        .foregroundStyle(appearance.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.75), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: appearance.cardShadow, radius: 6, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
    }
}

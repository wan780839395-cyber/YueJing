import ReaderDomain
import SwiftUI

/// Real books in their existing order. No service, tasks, sorting or generated book data.
@MainActor
struct LibraryShelfContent: View {
    private enum ShelfLayoutMode: String {
        case gallery
        case list
    }

    let books: [LibraryBook]
    let notice: LibraryNotice?
    let importing: Bool
    let importPresentation: LibraryImportPresentation
    let serviceUnavailable: Bool
    let appearance: LibraryAppearance
    var coverLoader: (@Sendable (String) async -> Data?)? = nil
    var canImport: Bool = true
    let onOpenBook: (LibraryBook) -> Void
    let onDismissNotice: () -> Void
    let onCancelImport: () -> Void
    let onRetry: () -> Void
    var onImport: (() -> Void)? = nil

    @AppStorage("dev.yuejing.ui.shelfLayout.v1") private var layoutRawValue: String = ShelfLayoutMode.gallery.rawValue
    @State private var formatFilter: LibraryShelfFormatFilter = .all
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layoutMode: ShelfLayoutMode {
        if dynamicType.isAccessibilitySize { return .list }
        return ShelfLayoutMode(rawValue: layoutRawValue) ?? .gallery
    }

    private var txtCount: Int { books.filter { $0.format == .txt }.count }
    private var epubCount: Int { books.filter { $0.format == .epub }.count }

    private var effectiveFilter: LibraryShelfFormatFilter {
        guard txtCount > 0 && epubCount > 0 else { return .all }
        return formatFilter
    }

    private var displayedBooks: [LibraryBook] {
        switch effectiveFilter {
        case .all: return books
        case .epub: return books.filter { $0.format == .epub }
        case .txt: return books.filter { $0.format == .txt }
        }
    }

    var body: some View {
        let visibleBooks = displayedBooks
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                LibraryHeaderView(
                    bookCount: books.count,
                    appearance: appearance,
                    showsShelfTitle: false,
                    txtCount: txtCount,
                    epubCount: epubCount,
                    selectedFilter: effectiveFilter,
                    onSelectFilter: { chosen in
                        if reduceMotion { formatFilter = chosen }
                        else { withAnimation(ReaderMotion.selectionFeedback) { formatFilter = chosen } }
                    }
                )

                if let notice {
                    LibraryNoticeBanner(notice: notice, appearance: appearance, dismiss: onDismissNotice)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }

                if importing {
                    importingCard
                }

                if serviceUnavailable {
                    serviceUnavailableCard
                } else if books.isEmpty {
                    emptyStudyCard
                } else {
                    if let leadBook = visibleBooks.first {
                        Button { onOpenBook(leadBook) } label: {
                            LibraryHeroBookCard(
                                book: leadBook,
                                appearance: appearance,
                                coverLoader: coverLoader
                            )
                        }
                        .id(leadBook.id + ":" + leadBook.versionID)
                        .buttonStyle(ShelfCardButtonStyle())
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("打开正文，恢复已保存的阅读位置")
                    }

                    let restBooks = Array(visibleBooks.dropFirst())
                    if !restBooks.isEmpty {
                        collectionHeader(count: restBooks.count)
                        if layoutMode == .gallery {
                            let columns = [
                                GridItem(.flexible(), spacing: 14, alignment: .top),
                                GridItem(.flexible(), spacing: 14, alignment: .top)
                            ]
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(restBooks) { book in
                                    Button { onOpenBook(book) } label: {
                                        LibraryBookGridCard(
                                            book: book,
                                            appearance: appearance,
                                            coverLoader: coverLoader
                                        )
                                    }
                                    .buttonStyle(ShelfCardButtonStyle())
                                    .accessibilityElement(children: .combine)
                                    .accessibilityHint("打开正文，恢复已保存的阅读位置")
                                }
                            }
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(restBooks) { book in
                                    Button { onOpenBook(book) } label: {
                                        LibraryBookRow(
                                            book: book,
                                            appearance: appearance,
                                            coverLoader: coverLoader
                                        )
                                    }
                                    .buttonStyle(ShelfCardButtonStyle())
                                    .accessibilityElement(children: .combine)
                                    .accessibilityHint("打开正文，恢复已保存的阅读位置")
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, LibraryAppearance.horizontalInset)
            .padding(.top, 8)
            .padding(.bottom, LibraryAppearance.contentBottomSpacing)
        }
        .background(appearance.page.ignoresSafeArea())
        .foregroundStyle(appearance.foreground)
        .tint(appearance.accent)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: notice != nil)
    }

    private func collectionHeader(count: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(appearance.accent)
                    .frame(width: 3, height: 15)
                    .accessibilityHidden(true)
                Text("藏书阁")
                    .font(LibraryAppearance.sectionTitleFont)
                    .foregroundStyle(appearance.foreground)
                    .accessibilityAddTraits(.isHeader)
                Text("\(count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(appearance.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(appearance.subtleSurface, in: Capsule())
            }
            Spacer(minLength: 8)
            if !dynamicType.isAccessibilitySize {
                HStack(spacing: 2) {
                    layoutToggleButton(mode: .gallery, label: "画廊视图", symbol: "square.grid.2x2")
                    layoutToggleButton(mode: .list, label: "编目视图", symbol: "list.bullet")
                }
                .padding(3)
                .background(appearance.subtleSurface, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(appearance.edge.opacity(0.6), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.top, 6)
    }

    private func layoutToggleButton(mode: ShelfLayoutMode, label: String, symbol: String) -> some View {
        let selected = layoutMode == mode
        return Button {
            layoutRawValue = mode.rawValue
        } label: {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? appearance.accent : appearance.secondary)
                .frame(minWidth: 44, minHeight: 34)
                .background {
                    if selected {
                        Capsule().fill(appearance.elevatedSurface)
                            .shadow(color: appearance.cardShadow, radius: 3, x: 0, y: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(label)
        .accessibilityValue(selected ? "当前" : "未选中")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("library.shelf.layout.\(mode.rawValue)")
    }

    private var importingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                ProgressView()
                    .tint(appearance.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("装帧准备中")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appearance.accent)
                    Text(importPresentation.title)
                        .font(.headline)
                        .foregroundStyle(appearance.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(importPresentation.detail)
                .font(.footnote)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onCancelImport) {
                Text(importPresentation.stopRequested ? "正在停止…" : "停止准备")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
            }
            .buttonStyle(AppControlButtonStyle(
                foreground: appearance.sealAccent,
                surface: appearance.sealSoft,
                border: appearance.sealAccent.opacity(0.32),
                cornerRadius: 14
            ))
            .disabled(importPresentation.stopRequested)
            .accessibilityHint("请求停止并等待最终结果，已完成的入架不会被撤销")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
                .strokeBorder(appearance.accent.opacity(0.35), lineWidth: 0.85)
                .allowsHitTesting(false)
        }
        .shadow(color: appearance.cardShadow, radius: 8, x: 0, y: 3)
    }

    private var emptyStudyCard: some View {
        VStack(alignment: .center, spacing: 18) {
            EmptyStudyArtwork(appearance: appearance)
                .padding(.top, 8)

            VStack(spacing: 8) {
                Text("把第一本书放进阅境")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(appearance.foreground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text("从「文件」选取 TXT 或本地非 DRM 可重排 EPUB。应用仅管理私有副本，你的原文件始终完整保留。")
                    .font(.subheadline)
                    .foregroundStyle(appearance.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let onImport {
                Button(action: onImport) {
                    Label("从文件导入书籍", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 22)
                        .frame(minHeight: 48)
                }
                .buttonStyle(AppControlButtonStyle(
                    foreground: appearance.isDarkSurface ? Color.black.opacity(0.9) : Color.white,
                    surface: appearance.accent,
                    cornerRadius: 24
                ))
                .disabled(!canImport)
                .accessibilityHint("打开系统文件选择器，支持 TXT 与非 DRM 可重排 EPUB")
                .accessibilityIdentifier("library.empty.import")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    capabilityPill("TXT 编码识别", symbol: "doc.plaintext")
                    capabilityPill("EPUB 原版重排", symbol: "book")
                    capabilityPill("离线本地保存", symbol: "lock.shield")
                }
                VStack(spacing: 6) {
                    capabilityPill("TXT 编码识别", symbol: "doc.plaintext")
                    capabilityPill("EPUB 原版重排", symbol: "book")
                    capabilityPill("离线本地保存", symbol: "lock.shield")
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.8), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: appearance.cardShadow, radius: 10, x: 0, y: 4)
    }

    private func capabilityPill(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.medium))
            .foregroundStyle(appearance.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(appearance.subtleSurface, in: Capsule())
    }

    private var serviceUnavailableCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("书架暂时无法打开", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(appearance.foreground)
            Text("本地书库尚未就绪，可尝试重新连接。你的书籍与已保存进度不会被清除。")
                .font(.footnote)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onRetry) {
                Text("重新打开书架")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
            }
            .buttonStyle(AppControlButtonStyle(
                foreground: appearance.accent,
                surface: appearance.accentSoft,
                border: appearance.accent.opacity(0.32),
                cornerRadius: 14
            ))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
                .strokeBorder(appearance.edge, lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }
}

/// Subtle tactile press response for shelf cards; respects Reduce Motion.
@MainActor
private struct ShelfCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Minimalist open-folio & sunlit study arch artwork for the empty bookshelf.
@MainActor
private struct EmptyStudyArtwork: View {
    let appearance: LibraryAppearance

    var body: some View {
        ZStack {
            // Soft sunlit arch backdrop
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [appearance.accentSoft, appearance.subtleSurface.opacity(0.45)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 88, height: 102)
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .strokeBorder(appearance.accent.opacity(0.24), lineWidth: 0.8)
                .frame(width: 88, height: 102)

            // Open folio pages
            Path { path in
                // Left page
                path.move(to: CGPoint(x: 18, y: 40))
                path.addQuadCurve(to: CGPoint(x: 44, y: 46), control: CGPoint(x: 32, y: 38))
                path.addLine(to: CGPoint(x: 44, y: 74))
                path.addQuadCurve(to: CGPoint(x: 18, y: 68), control: CGPoint(x: 32, y: 66))
                path.closeSubpath()
                // Right page
                path.move(to: CGPoint(x: 44, y: 46))
                path.addQuadCurve(to: CGPoint(x: 70, y: 40), control: CGPoint(x: 56, y: 38))
                path.addLine(to: CGPoint(x: 70, y: 68))
                path.addQuadCurve(to: CGPoint(x: 44, y: 74), control: CGPoint(x: 56, y: 66))
                path.closeSubpath()
            }
            .fill(appearance.elevatedSurface)
            .frame(width: 88, height: 102)

            Path { path in
                path.move(to: CGPoint(x: 18, y: 40))
                path.addQuadCurve(to: CGPoint(x: 44, y: 46), control: CGPoint(x: 32, y: 38))
                path.addQuadCurve(to: CGPoint(x: 70, y: 40), control: CGPoint(x: 56, y: 38))
                path.addLine(to: CGPoint(x: 70, y: 68))
                path.addQuadCurve(to: CGPoint(x: 44, y: 74), control: CGPoint(x: 56, y: 66))
                path.addQuadCurve(to: CGPoint(x: 18, y: 68), control: CGPoint(x: 32, y: 66))
                path.closeSubpath()
                path.move(to: CGPoint(x: 44, y: 46))
                path.addLine(to: CGPoint(x: 44, y: 74))
            }
            .stroke(appearance.accent, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .frame(width: 88, height: 102)

            // Red-seal sun dot above folio
            Circle()
                .fill(appearance.sealAccent)
                .frame(width: 8, height: 8)
                .offset(y: -25)
        }
        .accessibilityHidden(true)
    }
}

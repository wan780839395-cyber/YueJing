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
    @Binding var query: LibraryShelfQuery
    let canManageBooks: Bool
    let onDeleteBook: (LibraryBook) -> Void
    let onOpenBook: (LibraryBook) -> Void
    var onStartStory: ((LibraryBook) -> Void)? = nil
    let onDismissNotice: () -> Void
    let onCancelImport: () -> Void
    let onRetry: () -> Void
    var onImport: (() -> Void)? = nil

    @AppStorage("dev.yuejing.ui.shelfLayout.v1") private var layoutRawValue: String = ShelfLayoutMode.gallery.rawValue
    @State private var pendingDeletion: LibraryBook?
    @FocusState private var searching: Bool
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layoutMode: ShelfLayoutMode {
        if dynamicType.isAccessibilitySize { return .list }
        return ShelfLayoutMode(rawValue: layoutRawValue) ?? .gallery
    }

    private var txtCount: Int { books.filter { $0.format == .txt }.count }
    private var epubCount: Int { books.filter { $0.format == .epub }.count }


    var body: some View {
        let visibleBooks = query.results(in: books)
        let titleCounts = Dictionary(grouping: books, by: \.title).mapValues(\.count)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                LibraryHeaderView(
                    bookCount: books.count,
                    appearance: appearance,
                    showsShelfTitle: false,
                    txtCount: txtCount,
                    epubCount: epubCount,
                    selectedFilter: query.format,
                    onSelectFilter: { chosen in
                        if reduceMotion { query.format = chosen }
                        else { withAnimation(ReaderMotion.selectionFeedback) { query.format = chosen } }
                    }
                )
                if !serviceUnavailable && (!books.isEmpty || query.isFiltering) { titleSearch }

                if let notice {
                    LibraryNoticeBanner(notice: notice, appearance: appearance, dismiss: onDismissNotice)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }

                if importing {
                    importingCard
                }

                if serviceUnavailable {
                    serviceUnavailableCard
                } else if visibleBooks.isEmpty && query.isFiltering {
                    noMatchesCard
                } else if books.isEmpty {
                    emptyStudyCard
                } else if query.isFiltering {
                    searchResultsHeader(count: visibleBooks.count)
                    shelfCollection(visibleBooks, titleCounts: titleCounts)
                } else {
                    if let leadBook = visibleBooks.first {
                        bookButton(leadBook) {
                            LibraryHeroBookCard(
                                book: leadBook,
                                appearance: appearance,
                                coverLoader: coverLoader,
                                showsEditionDetails: (titleCounts[leadBook.title] ?? 0) > 1
                            )
                        }
                        .id(leadBook.id + ":" + leadBook.versionID)
                    }

                    let restBooks = Array(visibleBooks.dropFirst())
                    if !restBooks.isEmpty {
                        collectionHeader(count: restBooks.count)
                        shelfCollection(restBooks, titleCounts: titleCounts)
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
        .alert(item: $pendingDeletion) { book in
            Alert(title: Text("删除《\(book.title)》？"),
                  message: Text(deletionMessage(for: book, duplicateCount: titleCounts[book.title] ?? 1)),
                  primaryButton: .destructive(Text("删除")) { if canManageBooks { onDeleteBook(book) } },
                  secondaryButton: .cancel(Text("取消")))
        }
    }

    @ViewBuilder
    private func shelfCollection(_ items: [LibraryBook], titleCounts: [String: Int]) -> some View {
        if layoutMode == .gallery {
            let columns = [
                GridItem(.flexible(), spacing: 14, alignment: .top),
                GridItem(.flexible(), spacing: 14, alignment: .top)
            ]
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(items) { book in
                    bookButton(book) {
                        LibraryBookGridCard(
                            book: book,
                            appearance: appearance,
                            coverLoader: coverLoader,
                            showsEditionDetails: (titleCounts[book.title] ?? 0) > 1
                        )
                    }
                }
            }
        } else {
            LazyVStack(spacing: 12) {
                ForEach(items) { book in
                    bookButton(book) {
                        LibraryBookRow(
                            book: book,
                            appearance: appearance,
                            coverLoader: coverLoader,
                            showsEditionDetails: (titleCounts[book.title] ?? 0) > 1
                        )
                    }
                }
            }
        }
    }

    private var titleSearch: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle((searching || !query.title.isEmpty) ? appearance.accent : appearance.secondary)
                .accessibilityHidden(true)
            TextField("搜索书名", text: $query.title)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($searching).submitLabel(.search).onSubmit { searching = false }
                .accessibilityIdentifier("library.shelf.search")
            if !query.title.isEmpty {
                Button { query.title = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(appearance.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空书名搜索")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, query.title.isEmpty ? 12 : 4)
        .frame(minHeight: 46)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    (searching || !query.title.isEmpty) ? appearance.accent.opacity(0.55) : appearance.edge.opacity(0.85),
                    lineWidth: searching ? 1.1 : 0.75
                )
                .allowsHitTesting(false)
        }
        .shadow(color: appearance.cardShadow, radius: 4, x: 0, y: 1)
    }

    private var noMatchesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(appearance.accentSoft)
                        .frame(width: 44, height: 44)
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appearance.accent)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("没有匹配的书")
                        .font(.system(.headline, design: .serif).weight(.semibold))
                        .foregroundStyle(appearance.foreground)
                        .accessibilityAddTraits(.isHeader)
                    Text(noMatchesDescription)
                        .font(.subheadline)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                query = LibraryShelfQuery()
                searching = false
            } label: {
                Label("查看全部藏书", systemImage: "arrow.counterclockwise")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
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
                .strokeBorder(appearance.edge.opacity(0.8), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: appearance.cardShadow, radius: 6, x: 0, y: 2)
        .accessibilityIdentifier("library.shelf.noMatches")
    }

    private var noMatchesDescription: String {
        let trimmed = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && query.format != .all {
            return "在 \(query.format.title) 中未找到包含“\(trimmed)”的书名，可切换筛选或查看全部藏书。"
        }
        if !trimmed.isEmpty {
            return "未找到包含“\(trimmed)”的书名，试试其他关键词，或查看全部藏书。"
        }
        if query.format != .all {
            return "当前书架暂无 \(query.format.title) 书籍，可查看全部藏书。"
        }
        return "试试其他书名，或查看全部藏书。"
    }

    private func searchResultsHeader(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(appearance.accent)
                        .frame(width: 3, height: 15)
                        .accessibilityHidden(true)
                    Text("匹配结果")
                        .font(LibraryAppearance.sectionTitleFont)
                        .foregroundStyle(appearance.foreground)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(count) / \(books.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(appearance.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(appearance.accentSoft, in: Capsule())
                }
                Spacer(minLength: 8)
                if !dynamicType.isAccessibilitySize {
                    layoutToggleStrip
                }
            }

            HStack(spacing: 8) {
                Text(activeFilterSummary)
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    query = LibraryShelfQuery()
                    searching = false
                } label: {
                    Text("清除筛选")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AppControlButtonStyle(foreground: appearance.accent, cornerRadius: 12))
                .accessibilityIdentifier("library.shelf.clearFilter")
            }
        }
        .padding(.top, 2)
    }

    private var activeFilterSummary: String {
        let trimmed = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if query.format != .all { parts.append("格式：\(query.format.title)") }
        if !trimmed.isEmpty { parts.append("书名含“\(trimmed)”") }
        return parts.isEmpty ? "正在筛选书架" : parts.joined(separator: " · ")
    }

    private func deletionMessage(for book: LibraryBook, duplicateCount: Int) -> String {
        var facts: [String] = [book.format.rawValue.uppercased()]
        if let encoding = LibraryBookMetrics.encodingLabel(for: book) {
            facts.append(encoding)
        }
        if let volume = LibraryBookMetrics.volumeLabel(for: book) {
            facts.append(volume)
        }
        facts.append("入架 " + LibraryBookMetrics.shortTimestamp(book.addedAt))
        if let lastReadAt = book.lastReadAt {
            facts.append("最近阅读 " + LibraryBookMetrics.shortDate(lastReadAt))
        } else {
            facts.append("尚未阅读")
        }
        let identity = facts.joined(separator: " · ")
        let duplicateWarning = duplicateCount > 1
            ? "书架上共有 \(duplicateCount) 本同名书籍，本次仅删除此副本。\n"
            : ""
        return "\(duplicateWarning)当前副本：\(identity)。\n将删除这本 \(book.format.rawValue.uppercased()) 在阅境中的副本、阅读进度、书签及关联本地故事存档。不会删除“文件”中的原件或共享字体。"
    }
    private func bookButton<Label: View>(_ book: LibraryBook, @ViewBuilder label: () -> Label) -> some View {
        Button { searching = false; onOpenBook(book) } label: { label() }
            .buttonStyle(ShelfCardButtonStyle())
            .accessibilityElement(children: .combine)
            .accessibilityHint("打开正文，恢复已保存的阅读位置")
            .contextMenu {
                if let onStartStory {
                    Button {
                        searching = false
                        onStartStory(book)
                    } label: {
                        SwiftUI.Label("从本书开启 AI 故事", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("library.book.startStory.\(book.id)")
                }
                Button(role: .destructive) { requestDeletion(book) } label: {
                    SwiftUI.Label("删除书籍", systemImage: "trash")
                }
            }
            .accessibilityAction(named: Text("从本书开启 AI 故事")) {
                guard canManageBooks, let onStartStory else { return }
                searching = false
                onStartStory(book)
            }
            .accessibilityAction(named: Text("删除书籍")) { requestDeletion(book) }
            .disabled(!canManageBooks)
    }

    private func requestDeletion(_ book: LibraryBook) {
        guard canManageBooks, pendingDeletion == nil else { return }
        searching = false
        pendingDeletion = book
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
                layoutToggleStrip
            }
        }
        .padding(.top, 6)
    }

    private var layoutToggleStrip: some View {
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
            importPhaseStrip

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

    private var activeImportStep: Int {
        switch importPresentation.phase {
        case .waiting, .copying: 0
        case .reading, .decoding, .choosing, .epubArchive: 1
        case .epubChapters, .epubNavigation: 2
        case .registering, .committed, .epubReady: 3
        }
    }

    private var importPhaseStrip: some View {
        let steps = ["读取原件", "解析内容", "编排结构", "写入书架"]
        let activeIndex = activeImportStep
        let tint = importPresentation.stopRequested ? appearance.sealAccent : appearance.accent
        return HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, label in
                let reached = index <= activeIndex
                VStack(alignment: .leading, spacing: 4) {
                    Capsule()
                        .fill(reached ? tint : appearance.edge.opacity(0.45))
                        .frame(height: 3)
                    if !dynamicType.isAccessibilitySize {
                        Text(label)
                            .font(.caption2.weight(index == activeIndex ? .semibold : .regular))
                            .foregroundStyle(index == activeIndex ? tint : appearance.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
        .accessibilityHidden(true)
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

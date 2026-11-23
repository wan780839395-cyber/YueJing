import ReaderDomain
import SwiftUI
import TXTCore

/// Keeps the existing directory subtree/identifiers intact. The default remains Directory.
@MainActor
struct ReaderContentsSheet: View {
    let model: ReaderViewModel
    @ObservedObject var bookmarks: ReaderBookmarksViewModel
    let presentationID: UUID
    let isActive: @MainActor () -> Bool
    let close: @MainActor () -> Void
    let appearance: ReaderToolAppearance
    let selectedChapter: @MainActor (TXTChapter) -> Void
    let selectedBookmark: @MainActor (ReadingWindow) -> Bool
    var searchActions: BookSearchActions? = nil
    private enum ContentsTab {
        case directory
        case bookmarks
        case search
    }
    @State private var activeTab: ContentsTab = .directory
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if dynamicType.isAccessibilitySize {
                    VStack(spacing: 4) { sectionButtons }
                } else {
                    HStack(spacing: 4) { sectionButtons }
                }
            }
            .padding(4)
            .background(appearance.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(appearance.edge.opacity(0.65), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, ReaderVisualStyle.panelHorizontalInset)

            if activeTab == .bookmarks {
                ReaderBookmarksView(model: bookmarks, presentationID: presentationID, isActive: isActive,
                    close: close, appearance: appearance,
                    prepare: { try await model.prepareBookmarkWindow(id: $0, presentation: presentationID, request: $1) },
                    apply: selectedBookmark)
            } else if activeTab == .search, let searchActions {
                BookSearchView(
                    sessionID: presentationID,
                    active: isActive(),
                    isPanelActive: isActive,
                    actions: searchActions,
                    appearance: appearance,
                    close: close
                )
            } else {
                ReaderDirectorySheet(model: model.directory, presentationID: presentationID,
                    isActive: isActive, currentAnchor: model.directoryAnchor,
                    close: close, appearance: appearance, selected: selectedChapter)
            }
        }
        .onDisappear { model.endBookmarkPanel(presentationID) }
    }

    @ViewBuilder private var sectionButtons: some View {
        sectionButton(
            title: "目录",
            symbol: "list.bullet",
            tab: .directory,
            selectedTint: appearance.accent,
            identifier: "reader.contents.directory"
        )
        sectionButton(
            title: "书签",
            symbol: "bookmark",
            tab: .bookmarks,
            selectedTint: appearance.sealAccent,
            identifier: "reader.contents.bookmarks",
            beforeSelect: { model.refreshBookmarkCapture(presentationID) }
        )
        if searchActions != nil {
            sectionButton(
                title: "搜正文",
                symbol: "magnifyingglass",
                tab: .search,
                selectedTint: appearance.accent,
                identifier: "reader.contents.search"
            )
        }
    }

    private func sectionButton(
        title: String,
        symbol: String,
        tab: ContentsTab,
        selectedTint: Color,
        identifier: String,
        beforeSelect: (@MainActor () -> Void)? = nil
    ) -> some View {
        let selected = activeTab == tab
        return Button {
            if isActive() && !bookmarks.isBusy && activeTab != tab {
                beforeSelect?()
                if reduceMotion { activeTab = tab }
                else { withAnimation(ReaderMotion.selectionFeedback) { activeTab = tab } }
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? selectedTint : appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(appearance.elevatedSurface)
                            .shadow(color: appearance.subtleShadow, radius: 4, x: 0, y: 1)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "已选择" : "")
        .accessibilityIdentifier(identifier)
        .disabled(!isActive() || bookmarks.isBusy)
    }
}

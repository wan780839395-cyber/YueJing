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
    @State private var showingBookmarks = false
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if dynamicType.isAccessibilitySize {
                    VStack(spacing: 2) { sectionButtons }
                } else { HStack(spacing: 8) { sectionButtons } }
            }.padding(.horizontal, 16)
            if showingBookmarks {
                ReaderBookmarksView(model: bookmarks, presentationID: presentationID, isActive: isActive,
                    close: close, appearance: appearance,
                    prepare: { try await model.prepareBookmarkWindow(id: $0, presentation: presentationID, request: $1) },
                    apply: selectedBookmark)
            } else {
                ReaderDirectorySheet(model: model.directory, presentationID: presentationID,
                    isActive: isActive, currentAnchor: model.directoryAnchor,
                    close: close, appearance: appearance, selected: selectedChapter)
            }
        }
        .onDisappear { model.endBookmarkPanel(presentationID) }
    }
    @ViewBuilder private var sectionButtons: some View {
        Button {
            if isActive() && !bookmarks.isBusy { showingBookmarks = false }
        } label: {
            Text("目录").fontWeight(showingBookmarks ? .regular : .semibold)
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                .background(showingBookmarks ? Color.clear : appearance.selection,
                            in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityValue(showingBookmarks ? "" : "已选择")
        .accessibilityIdentifier("reader.contents.directory")
        .disabled(!isActive() || bookmarks.isBusy)
        Button {
            if isActive() && !bookmarks.isBusy { showingBookmarks = true }
        } label: {
            Text("书签").fontWeight(showingBookmarks ? .semibold : .regular)
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                .background(showingBookmarks ? appearance.selection : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityValue(showingBookmarks ? "已选择" : "")
        .accessibilityIdentifier("reader.contents.bookmarks")
        .disabled(!isActive() || bookmarks.isBusy)
    }
}

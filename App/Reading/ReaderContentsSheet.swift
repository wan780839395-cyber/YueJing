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
            if isActive() && !bookmarks.isBusy {
                if reduceMotion { showingBookmarks = false }
                else { withAnimation(ReaderMotion.selectionFeedback) { showingBookmarks = false } }
            }
        } label: {
            Label("目录", systemImage: "list.bullet")
                .font(.subheadline.weight(showingBookmarks ? .medium : .semibold))
                .foregroundStyle(showingBookmarks ? appearance.secondary : appearance.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    if !showingBookmarks {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(appearance.elevatedSurface)
                            .shadow(color: appearance.subtleShadow, radius: 4, x: 0, y: 1)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(showingBookmarks ? "" : "已选择")
        .accessibilityIdentifier("reader.contents.directory")
        .disabled(!isActive() || bookmarks.isBusy)

        Button {
            if isActive() && !bookmarks.isBusy && !showingBookmarks {
                model.refreshBookmarkCapture(presentationID)
                if reduceMotion { showingBookmarks = true }
                else { withAnimation(ReaderMotion.selectionFeedback) { showingBookmarks = true } }
            }
        } label: {
            Label("书签", systemImage: "bookmark")
                .font(.subheadline.weight(showingBookmarks ? .semibold : .medium))
                .foregroundStyle(showingBookmarks ? appearance.sealAccent : appearance.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    if showingBookmarks {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(appearance.elevatedSurface)
                            .shadow(color: appearance.subtleShadow, radius: 4, x: 0, y: 1)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(showingBookmarks ? "已选择" : "")
        .accessibilityIdentifier("reader.contents.bookmarks")
        .disabled(!isActive() || bookmarks.isBusy)
    }
}

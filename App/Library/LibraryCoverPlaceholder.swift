import SwiftUI

/// A fixed-ratio typographic placeholder, not an extracted or downloaded cover.
@MainActor
struct LibraryCoverPlaceholder: View {
    let title: String
    let appearance: LibraryAppearance

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(appearance.coverSurface.opacity(0.82))
            Rectangle().fill(appearance.accent.opacity(0.12))
                .frame(width: 3).padding(.vertical, 4)
            Rectangle().fill(appearance.accent.opacity(0.25))
                .frame(width: 0.5)
                .padding(.vertical, 8).padding(.leading, 6)
            Text(String(title.first ?? "阅"))
                // This glyph is artwork; the actual book title uses Dynamic Type.
                .font(.system(size: 22, weight: .medium, design: .serif))
                .foregroundStyle(appearance.foreground)
                .frame(maxWidth: .infinity)
            Rectangle().fill(appearance.accent.opacity(0.3))
                .frame(width: 16, height: 0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 8)
        }
        .frame(width: LibraryAppearance.coverWidth, height: LibraryAppearance.coverHeight)
        .accessibilityHidden(true)
    }
}

import SwiftUI

/// A fixed-ratio typographic placeholder, not an extracted or downloaded cover.
@MainActor
struct LibraryCoverPlaceholder: View {
    let title: String
    let appearance: LibraryAppearance

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(appearance.coverSurface)
            Rectangle().fill(appearance.secondary.opacity(0.25))
                .frame(width: 1)
                .padding(.vertical, 7).padding(.leading, 4)
            Text(String(title.first ?? "阅"))
                // This glyph is artwork; the actual book title uses Dynamic Type.
                .font(.system(size: 22, weight: .medium, design: .serif))
                .foregroundStyle(appearance.foreground)
                .frame(maxWidth: .infinity)
        }
        .frame(width: LibraryAppearance.coverWidth, height: LibraryAppearance.coverHeight)
        .accessibilityHidden(true)
    }
}

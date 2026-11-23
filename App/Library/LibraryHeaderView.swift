import SwiftUI

@MainActor
struct LibraryHeaderView: View {
    let bookCount: Int
    let appearance: LibraryAppearance
    var showsShelfTitle: Bool = true
    var txtCount: Int = 0
    var epubCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                YueJingBrandMark(tint: appearance.accent, sealTint: appearance.sealAccent, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("阅境 · 本地书斋")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appearance.secondary)
                    Text(showsShelfTitle ? "书架" : "开卷，自有一境。")
                        .font(showsShelfTitle ? LibraryAppearance.titleFont : .system(.title2, design: .serif).weight(.semibold))
                        .foregroundStyle(appearance.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 8)
                Text("\(bookCount) 册")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(appearance.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(appearance.accentSoft, in: Capsule())
                    .fixedSize(horizontal: true, vertical: false)
            }

            if showsShelfTitle {
                Text("开卷，自有一境。")
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if bookCount > 0 && (txtCount > 0 || epubCount > 0) {
                HStack(spacing: 8) {
                    if epubCount > 0 {
                        statChip("EPUB", count: epubCount, tint: appearance.accent, fill: appearance.accentSoft)
                    }
                    if txtCount > 0 {
                        statChip("TXT", count: txtCount, tint: appearance.secondary, fill: appearance.subtleSurface)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .foregroundStyle(appearance.foreground)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func statChip(_ label: String, count: Int, tint: Color, fill: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
            Text("\(count)")
                .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(fill, in: Capsule())
    }
}

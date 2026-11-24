import ReaderDomain
import SwiftUI

enum LibraryShelfFormatFilter: String, CaseIterable, Sendable {
    case all, epub, txt

    var title: String {
        switch self {
        case .all: "全部"
        case .epub: "EPUB"
        case .txt: "TXT"
        }
    }
}

@MainActor
struct LibraryHeaderView: View {
    let bookCount: Int
    let appearance: LibraryAppearance
    var showsShelfTitle: Bool = true
    var txtCount: Int = 0
    var epubCount: Int = 0
    var selectedFilter: LibraryShelfFormatFilter = .all
    var onSelectFilter: ((LibraryShelfFormatFilter) -> Void)? = nil

    private var showsInteractiveFilter: Bool {
        onSelectFilter != nil && (selectedFilter != .all || (txtCount > 0 && epubCount > 0))
    }

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

            if showsInteractiveFilter {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterChip(.all, count: bookCount)
                        filterChip(.epub, count: epubCount)
                        filterChip(.txt, count: txtCount)
                    }
                    .padding(.vertical, 2)
                }
            } else if bookCount > 0 && (txtCount > 0 || epubCount > 0) {
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

    private func filterChip(_ filter: LibraryShelfFormatFilter, count: Int) -> some View {
        let selected = selectedFilter == filter
        return Button {
            onSelectFilter?(filter)
        } label: {
            HStack(spacing: 5) {
                Text(filter.title)
                    .font(.caption.weight(selected ? .semibold : .medium))
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .opacity(selected ? 0.9 : 0.72)
            }
            .foregroundStyle(selected ? appearance.accent : appearance.secondary)
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: 36)
            .background(
                selected ? appearance.accentSoft : appearance.surface,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        selected ? appearance.accent.opacity(0.45) : appearance.edge.opacity(0.75),
                        lineWidth: selected ? 1 : 0.65
                    )
                    .allowsHitTesting(false)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("筛选\(filter.title)，共 \(count) 册")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("library.shelf.filter.\(filter.rawValue)")
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

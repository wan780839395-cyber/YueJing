import ReaderDomain
import SwiftUI

/// One compact editorial toast card; all outcome text and explicit dismissal remain available.
@MainActor
struct LibraryNoticeBanner: View {
    let notice: LibraryNotice
    let appearance: LibraryAppearance
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(appearance.foreground)
                    .accessibilityAddTraits(.isHeader)
                Text(notice.detail)
                    .font(.footnote)
                    .foregroundStyle(appearance.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

            Button(action: dismiss) {
                Label("关闭这条提示", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(AppControlButtonStyle(foreground: appearance.secondary, cornerRadius: 12))
            .accessibilityIdentifier("library.notice.dismiss")
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(appearance.accent)
                .frame(width: 3)
                .padding(.leading, 10)
                .padding(.vertical, 12)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(appearance.accent.opacity(0.32), lineWidth: 0.85)
                .allowsHitTesting(false)
        }
        .shadow(color: appearance.cardShadow, radius: 6, x: 0, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.notice")
    }
}

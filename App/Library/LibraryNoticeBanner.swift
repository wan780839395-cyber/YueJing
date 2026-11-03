import ReaderDomain
import SwiftUI

/// One compact row; all outcome text and the explicit dismissal remain available.
@MainActor
struct LibraryNoticeBanner: View {
    let notice: LibraryNotice
    let appearance: LibraryAppearance
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(notice.detail).font(.footnote).foregroundStyle(appearance.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button(action: dismiss) {
                Label("关闭这条提示", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.notice.dismiss")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.notice")
    }
}

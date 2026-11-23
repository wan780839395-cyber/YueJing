import ReaderDomain
import SwiftUI

/// A fixed, non-private sample. SwiftUI illustrates style, not the reader's CoreText line breaks.
@MainActor
struct ReaderTypographyPreview: View {
    let preferences: ReaderPreferences
    let appearance: ReaderToolAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appearance.sealAccent)
                            .frame(width: 6, height: 6)
                        Text("书页预览")
                            .font(.caption.weight(.semibold))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 8)
                    Text("\(Int(preferences.fontSize)) 号 · 行距 \(Int(preferences.lineSpacing)) · \(preferences.theme.title)")
                        .font(.caption.monospacedDigit())
                        .fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("书页预览")
                        .font(.caption.weight(.semibold))
                    Text("\(Int(preferences.fontSize)) 号 · 行距 \(Int(preferences.lineSpacing)) · \(preferences.theme.title)")
                        .font(.caption.monospacedDigit())
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Color(uiColor: preferences.theme.foreground).opacity(0.62))

            Rectangle()
                .fill(Color(uiColor: preferences.theme.foreground).opacity(0.10))
                .frame(height: 0.5)

            Text("晚风翻过书页，\n故事在此刻继续。")
                .font(.custom("PingFangSC-Regular", fixedSize: CGFloat(preferences.fontSize)))
                .lineSpacing(CGFloat(preferences.lineSpacing))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                .foregroundStyle(Color(uiColor: preferences.theme.foreground))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Color(uiColor: preferences.theme.background), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.85), lineWidth: 0.85)
                .allowsHitTesting(false)
        }
        .shadow(color: appearance.subtleShadow, radius: 8, x: 0, y: 3)
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("排版示例，字号 \(Int(preferences.fontSize))，行距 \(Int(preferences.lineSpacing))，\(preferences.theme.title)背景")
        .accessibilityIdentifier("reader.typography.preview")
    }
}

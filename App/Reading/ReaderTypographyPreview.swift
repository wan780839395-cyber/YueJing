import ReaderDomain
import SwiftUI

/// A fixed, non-private sample. SwiftUI illustrates style, not the reader's CoreText line breaks.
@MainActor
struct ReaderTypographyPreview: View {
    let preferences: ReaderPreferences
    let appearance: ReaderToolAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("效果预览").font(.caption.weight(.medium))
                Spacer(minLength: 8)
                Text("\(Int(preferences.fontSize)) 号 · 行距 \(Int(preferences.lineSpacing))")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(appearance.foreground.opacity(0.7))
            Text("晚风翻过书页，\n故事在此刻继续。")
                .font(.custom("PingFangSC-Regular", fixedSize: CGFloat(preferences.fontSize)))
                .lineSpacing(CGFloat(preferences.lineSpacing))
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .foregroundStyle(Color(uiColor: preferences.theme.foreground))
                .accessibilityHidden(true)
        }
        .padding(16)
        .background(Color(uiColor: preferences.theme.background), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(appearance.edge, lineWidth: 0.5) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("排版示例，字号 \(Int(preferences.fontSize))，行距 \(Int(preferences.lineSpacing))，\(preferences.theme.title)背景")
        .accessibilityIdentifier("reader.typography.preview")
    }
}

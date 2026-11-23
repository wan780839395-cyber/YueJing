import ReaderDomain
import SwiftUI
import TXTCore

@MainActor
struct EncodingChoiceView: View {
    let choice: EncodingChoice
    var appearance: LibraryAppearance? = nil
    let select: @MainActor (TXTEncoding) -> Void
    let cancel: @MainActor () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var activeAppearance: LibraryAppearance {
        appearance ?? LibraryAppearance(colorScheme: colorScheme)
    }

    var body: some View {
        let style = activeAppearance
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("选择正确编码")
                            .font(.system(.title3, design: .serif).weight(.semibold))
                            .foregroundStyle(style.foreground)
                            .accessibilityAddTraits(.isHeader)
                        Text("同一段文字有几种识别结果。请选择读起来正常的一份；也可以取消，书架不会新增记录。")
                            .font(.subheadline)
                            .foregroundStyle(style.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(choice.cards) { card in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .center, spacing: 8) {
                                Text(card.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(style.accent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(style.accentSoft, in: Capsule())
                                Spacer(minLength: 0)
                                Text("样文预览")
                                    .font(.caption)
                                    .foregroundStyle(style.secondary)
                            }

                            Text(card.text)
                                .font(.system(.body, design: .serif))
                                .lineSpacing(5)
                                .foregroundStyle(style.foreground)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(style.subtleSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            Button { select(card.encoding) } label: {
                                Label("使用这份文字", systemImage: "checkmark.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 46)
                            }
                            .buttonStyle(AppControlButtonStyle(
                                foreground: style.isDarkSurface ? Color.black.opacity(0.9) : Color.white,
                                surface: style.accent,
                                cornerRadius: 14
                            ))
                            .accessibilityLabel("使用\(card.title)编码的文字")
                        }
                        .padding(16)
                        .background(style.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
                                .strokeBorder(style.edge.opacity(0.85), lineWidth: 0.75)
                                .allowsHitTesting(false)
                        }
                        .shadow(color: style.cardShadow, radius: 6, x: 0, y: 2)
                    }
                }
                .padding(LibraryAppearance.horizontalInset)
            }
            .background(style.page.ignoresSafeArea())
            .foregroundStyle(style.foreground)
            .tint(style.accent)
            .navigationTitle("确认文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(style.page, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(style.controlColorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: cancel)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }
}

import ReaderDomain
import SwiftUI

@MainActor
struct ReaderDiagnosticsView: View {
    var importState: ImportDiagnosticState?
    var importSummary: String?
    var openingSummary: String?
    var fontDiagnostics: [EPUBFontDiagnostic]?
    var compatibilityDetails: String?
    var libraryAppearance: LibraryAppearance? = nil
    var readerAppearance: ReaderToolAppearance? = nil
    @State private var includeFontNames = false
    @Environment(\.colorScheme) private var colorScheme

    private var pageBackground: Color {
        if let libraryAppearance { return libraryAppearance.page }
        if let readerAppearance { return readerAppearance.surface }
        return LibraryAppearance(colorScheme: colorScheme).page
    }

    private var cardBackground: Color {
        if let libraryAppearance { return libraryAppearance.surface }
        if let readerAppearance { return readerAppearance.card }
        return LibraryAppearance(colorScheme: colorScheme).surface
    }

    private var edgeColor: Color {
        if let libraryAppearance { return libraryAppearance.edge }
        if let readerAppearance { return readerAppearance.edge }
        return LibraryAppearance(colorScheme: colorScheme).edge
    }

    private var foregroundColor: Color {
        if let libraryAppearance { return libraryAppearance.foreground }
        if let readerAppearance { return readerAppearance.foreground }
        return LibraryAppearance(colorScheme: colorScheme).foreground
    }

    private var secondaryColor: Color {
        if let libraryAppearance { return libraryAppearance.secondary }
        if let readerAppearance { return readerAppearance.secondary }
        return LibraryAppearance(colorScheme: colorScheme).secondary
    }

    private var accentColor: Color {
        if let libraryAppearance { return libraryAppearance.accent }
        if let readerAppearance { return readerAppearance.accent }
        return LibraryAppearance(colorScheme: colorScheme).accent
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accentColor)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    Text("仅本机固定阶段和时长，不包含书名、路径、正文或书籍校验值。窗口已应用不等于真实首绘。")
                        .font(.footnote)
                        .foregroundStyle(secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.24), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }

                if let state = importState {
                    diagnosticCard("本次导入", symbol: "tray.and.arrow.down") {
                        if state.attempt == nil {
                            Text("本次尚无导入记录。")
                                .font(.subheadline)
                                .foregroundStyle(secondaryColor)
                        } else {
                            Text(state.callbackSummary)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                            if let stage = state.stage {
                                Text("阶段：\(stage.label)")
                                    .font(.footnote)
                                    .foregroundStyle(secondaryColor)
                            }
                            if let failure = state.failure {
                                Text(failure.summary)
                                    .font(.footnote)
                                    .foregroundStyle(foregroundColor)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let failedAfter = state.failedAfter {
                                Text("出错前：\(failedAfter.label)")
                                    .font(.footnote)
                                    .foregroundStyle(secondaryColor)
                            }
                            DisclosureGroup("阶段记录") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(state.history.enumerated()), id: \.offset) { item in
                                        Text("\(item.offset + 1). \(item.element.label)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(secondaryColor)
                                    }
                                }
                                .padding(.top, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.subheadline.weight(.medium))
                        }
                        if let importSummary {
                            Text(importSummary)
                                .font(.caption.monospaced())
                                .foregroundStyle(secondaryColor)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if importState == nil || openingSummary != nil {
                    diagnosticCard("本次打开", symbol: "clock") {
                        Text(openingSummary ?? "尚未应用首个正文窗口。")
                            .font(.caption.monospaced())
                            .foregroundStyle(foregroundColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let compatibilityDetails {
                    diagnosticCard("兼容记录（历史）", symbol: "doc.text.magnifyingglass") {
                        Text(compatibilityDetails)
                            .font(.footnote)
                            .foregroundStyle(secondaryColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let fontDiagnostics {
                    diagnosticCard("字体声明（本机）", symbol: "textformat") {
                        Toggle("包含字体名称（可选）", isOn: $includeFontNames)
                            .font(.subheadline.weight(.medium))
                            .tint(accentColor)
                            .accessibilityIdentifier("reader.diagnostics.fontNames")
                        Text("名称来自书内声明，不等于发行方认证。仅在需要核查官方来源时开启；分享前请检查。不会自动上传或下载字体。")
                            .font(.caption)
                            .foregroundStyle(secondaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(EPUBFontDiagnostic.summary(fontDiagnostics, includeNames: includeFontNames))
                            .font(.caption.monospaced())
                            .foregroundStyle(foregroundColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("reader.diagnostics.fonts")
                    }
                }
            }
            .padding(LibraryAppearance.horizontalInset)
        }
        .background(pageBackground.ignoresSafeArea())
        .foregroundStyle(foregroundColor)
        .tint(accentColor)
        .navigationTitle("诊断与耗时")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func diagnosticCard<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(foregroundColor)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(edgeColor.opacity(0.8), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }
}

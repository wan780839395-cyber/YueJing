import CoreGraphics
import CoreText
import ReaderDomain
import SwiftUI

/// Shared, sole main specimen ("书页预览") for TXT and EPUB settings sheets.
/// Uses the actual local CGFont/CTFont for user-selected library fonts and never
/// claims to render an EPUB's embedded fonts or exact reading-canvas line breaks.
@MainActor
struct ReaderTypographyPreview: View {
    enum Context: Equatable, Sendable {
        case txt
        case epubReader
        case epubOriginal
    }

    private enum FontLoadState {
        case defaultFont
        case loading(id: String)
        case loaded(id: String, face: CGFont, displayName: String)
        case failed(id: String)
    }

    private struct LoadKey: Equatable {
        let fontID: String?
        let localRevision: Int
        let externalRevision: Int
    }

    let preferences: ReaderPreferences
    let appearance: ReaderToolAppearance
    var selectedFontID: String? = nil
    var context: Context = .txt
    var fontReloadRevision: Int = 0
    var isActive: @MainActor () -> Bool = { true }

    @State private var fontState: FontLoadState
    @State private var localRevision = 0
    @Environment(\.dynamicTypeSize) private var dynamicType

    init(
        preferences: ReaderPreferences,
        appearance: ReaderToolAppearance,
        selectedFontID: String? = nil,
        context: Context = .txt,
        fontReloadRevision: Int = 0,
        isActive: @escaping @MainActor () -> Bool = { true }
    ) {
        self.preferences = preferences
        self.appearance = appearance
        self.selectedFontID = selectedFontID
        self.context = context
        self.fontReloadRevision = fontReloadRevision
        self.isActive = isActive
        _fontState = State(initialValue: selectedFontID.map { .loading(id: $0) } ?? .defaultFont)
    }

    private var validated: ReaderPreferences { preferences.validated }

    private var effectiveFontState: FontLoadState {
        guard let selectedFontID else { return .defaultFont }
        switch fontState {
        case .loaded(let id, _, _) where id == selectedFontID:
            return fontState
        case .failed(let id) where id == selectedFontID:
            return fontState
        default:
            return .loading(id: selectedFontID)
        }
    }

    private var samplePointSize: CGFloat {
        CGFloat(validated.fontSize)
    }

    private var sampleLineSpacing: CGFloat {
        switch context {
        case .txt, .epubReader:
            return CGFloat(validated.lineSpacing)
        case .epubOriginal:
            // Original EPUB mode scales line height proportionally with text scale.
            return CGFloat((validated.fontSize / 20.0) * 7.0)
        }
    }

    private var sampleFace: CGFont? {
        if case .loaded(_, let face, _) = effectiveFontState { return face }
        return nil
    }

    private var metricsSummary: String {
        switch context {
        case .txt, .epubReader:
            return "\(Int(validated.fontSize)) 号 · 行距 \(Int(validated.lineSpacing)) · \(validated.theme.title)"
        case .epubOriginal:
            return "比例 \(Int((validated.fontSize * 5).rounded()))% · \(validated.theme.title)"
        }
    }

    private var paperForeground: Color {
        Color(uiColor: validated.theme.foreground)
    }

    private var footerNote: String {
        switch (context, effectiveFontState) {
        case (.txt, .defaultFont):
            return "系统默认字形示意，实际断行以正文为准。"
        case (.txt, .loading):
            return "正在读取本地字体文件，暂以默认字形占位。"
        case (.txt, .loaded):
            return "当前以本地所选字体预览，实际断行以正文为准。"
        case (.txt, .failed):
            return "本地字体不可用，已回退系统默认字形显示。"
        case (.epubReader, .defaultFont):
            return "跟随原书时以系统默认字形示意，不呈现原书内嵌字体。"
        case (.epubReader, .loading):
            return "正在读取本地字体文件，暂以默认字形占位。"
        case (.epubReader, .loaded):
            return "当前以本地所选字体预览字号、行距与纸色，实际断行以正文为准。"
        case (.epubReader, .failed):
            return "本地字体不可用，已回退默认字形，不呈现原书内嵌字体。"
        case (.epubOriginal, .defaultFont):
            return "仅示意字号比例与纸色，不呈现原书内嵌字体与版式。"
        case (.epubOriginal, .loading):
            return "正在读取本地字体文件，预览不呈现原书内嵌字体与版式。"
        case (.epubOriginal, .loaded):
            return "已按本地所选字体示意比例与纸色，不呈现原书内嵌字体与版式。"
        case (.epubOriginal, .failed):
            return "本地字体不可用，已回退默认字形示意比例，不呈现原书内嵌字体与版式。"
        }
    }

    private var accessibilityDescription: String {
        let layoutSummary: String
        switch context {
        case .txt, .epubReader:
            layoutSummary = "书页预览，字号 \(Int(validated.fontSize))，行距 \(Int(validated.lineSpacing))，\(validated.theme.title)背景"
        case .epubOriginal:
            layoutSummary = "书页预览，作者文字比例 \(Int((validated.fontSize * 5).rounded()))%，\(validated.theme.title)背景"
        }
        let fontSummary: String
        switch effectiveFontState {
        case .defaultFont:
            fontSummary = context == .txt ? "系统默认字体" : "跟随原书，以系统默认字形示意，不呈现原书内嵌字体"
        case .loading:
            fontSummary = "正在载入所选字体"
        case .loaded(_, _, let displayName):
            fontSummary = "本地字体 \(displayName)"
        case .failed:
            fontSummary = "所选字体载入失败，已回退系统默认字体"
        }
        return "\(layoutSummary)，\(fontSummary)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
                .padding(.trailing, 14)

            Rectangle()
                .fill(paperForeground.opacity(0.10))
                .frame(height: 0.5)
                .accessibilityHidden(true)

            fontStatusRow

            ReaderSpecimenText(face: sampleFace, size: samplePointSize, lineSpacing: sampleLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                .foregroundStyle(paperForeground)
                .opacity(isLoadingFont ? 0.52 : 1)
                .accessibilityHidden(true)

            Text(footerNote)
                .font(.caption2)
                .foregroundStyle(paperForeground.opacity(0.60))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color(uiColor: validated.theme.background), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            // Miniature notched bookmark ribbon tucked into the top edge of the sample page
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 8, y: 0))
                path.addLine(to: CGPoint(x: 8, y: 15))
                path.addLine(to: CGPoint(x: 4, y: 11.5))
                path.addLine(to: CGPoint(x: 0, y: 15))
                path.closeSubpath()
            }
            .fill(appearance.sealAccent.opacity(0.88))
            .frame(width: 8, height: 15)
            .padding(.trailing, 16)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.85), lineWidth: 0.85)
                .allowsHitTesting(false)
        }
        .shadow(color: appearance.subtleShadow, radius: 8, x: 0, y: 3)
        .padding(.bottom, 4)
        .task(id: LoadKey(fontID: selectedFontID, localRevision: localRevision, externalRevision: fontReloadRevision)) {
            await loadFontIfNeeded()
        }
        .onReceive(EPUBUserFontPreference.removed) { removedID in
            guard removedID == selectedFontID else { return }
            fontState = .failed(id: removedID)
            localRevision &+= 1
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier("reader.typography.preview")
    }

    private var isLoadingFont: Bool {
        if case .loading = effectiveFontState { return true }
        return false
    }

    @ViewBuilder
    private var headerRow: some View {
        Group {
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    previewBadge
                    Text(metricsSummary)
                        .font(.caption.monospacedDigit())
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 8) {
                        previewBadge
                        Spacer(minLength: 8)
                        Text(metricsSummary)
                            .font(.caption.monospacedDigit())
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        previewBadge
                        Text(metricsSummary)
                            .font(.caption.monospacedDigit())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .foregroundStyle(paperForeground.opacity(0.65))
    }

    private var previewBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(appearance.sealAccent)
                .frame(width: 6, height: 6)
            Text("书页预览")
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var fontStatusRow: some View {
        switch effectiveFontState {
        case .defaultFont:
            HStack(spacing: 5) {
                Image(systemName: "textformat")
                    .font(.caption2.weight(.semibold))
                Text(context == .txt ? "系统默认字体" : "跟随原书 · 默认示意")
                    .font(.caption2.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(paperForeground.opacity(0.68))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(paperForeground.opacity(0.07), in: Capsule())

        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(appearance.accent)
                Text("正在载入所选字体…")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(appearance.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(appearance.accentSoft, in: Capsule())

        case .loaded(_, _, let displayName):
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                Text(displayName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(appearance.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(appearance.accentSoft, in: Capsule())

        case .failed:
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                Text("所选字体不可用 · 已回退默认")
                    .font(.caption2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(appearance.sealAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(appearance.sealAccent.opacity(validated.theme == .dark ? 0.20 : 0.11), in: Capsule())
        }
    }

    private func loadFontIfNeeded() async {
        guard let id = selectedFontID else {
            fontState = .defaultFont
            return
        }
        guard EPUBUserFontPreference.validID(id) else {
            fontState = .failed(id: id)
            return
        }
        guard isActive() else { return }
        fontState = .loading(id: id)
        do {
            let bytes = try await EPUBUserFontStore.shared.data(for: id)
            guard !Task.isCancelled, isActive(), selectedFontID == id else { return }
            guard let provider = CGDataProvider(data: bytes as CFData),
                  let face = CGFont(provider) else {
                fontState = .failed(id: id)
                return
            }
            let names = EPUBFontIdentity.extract(fromValidatedSFNT: bytes)
            let fallbackName = EPUBFontDiagnostic.safeName(face.fullName as String?)
                ?? EPUBFontDiagnostic.safeName(face.postScriptName as String?)
            let displayName = names?.fullName ?? names?.family ?? names?.postScriptName ?? fallbackName ?? "已选字体"
            fontState = .loaded(id: id, face: face, displayName: displayName)
        } catch {
            guard !Task.isCancelled, isActive(), selectedFontID == id else { return }
            fontState = .failed(id: id)
        }
    }
}

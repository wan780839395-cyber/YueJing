import ReaderDomain
import SwiftUI

@MainActor
struct EPUBUserFontCard: View {
    let selectionName: String
    let fonts: [EPUBUserFont]
    let selectedID: String?
    let preview: Font?
    let isLoading: Bool
    let isImporting: Bool
    let isDeleting: Bool
    let notice: String?
    let isError: Bool
    let appearance: ReaderToolAppearance
    let select: (EPUBUserFont?) -> Void
    let openFiles: () -> Void
    let requestRemoval: (EPUBUserFont) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasCustomSelection: Bool { selectedID != nil }

    private var controlSurface: Color { appearance.elevatedSurface }

    private var selectionCaption: String {
        if fonts.isEmpty {
            return isLoading ? "当前字体 · 读取中" : "当前字体"
        }
        return "当前字体 · 库内 \(fonts.count) 款"
    }

    private var specimenStatusText: String {
        if selectedID == nil { return "跟随原书" }
        if preview != nil { return selectionName }
        return isLoading ? "正在载入样张…" : "默认字形示例"
    }

    private var specimenAccessibilityLabel: String {
        let prefix = selectedID == nil ? "字体样张，当前跟随原书" : "字体样张，\(selectionName)"
        return "\(prefix)：山间有风，书中有光。Aa 123"
    }

    var body: some View {
        ReaderSettingsSection(
            title: "正文字体",
            detail: "仅对本书生效，可随时切回原书字体",
            appearance: appearance
        ) {
            VStack(alignment: .leading, spacing: 10) {
                fontSelectionMenu

                if hasCustomSelection {
                    specimenCard
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                }

                if isLoading && fonts.isEmpty {
                    loadingRow
                } else if !isLoading && fonts.isEmpty {
                    emptyLibraryHint
                }

                actionBar

                if let notice, !notice.isEmpty {
                    noticeBanner(notice)
                }

                if !fonts.isEmpty {
                    Menu {
                        ForEach(fonts) { font in
                            Button(font.displayName) { requestRemoval(font) }
                        }
                    } label: {
                        Label(isDeleting ? "正在删除…" : "从字体库删除…", systemImage: "trash")
                            .frame(minHeight: ReaderVisualStyle.minimumControlHeight)
                    }
                    .disabled(isLoading || isImporting || isDeleting)
                    .accessibilityIdentifier("epub.font.removeMenu")
                    footnoteSummary
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                appearance.card,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(appearance.edge.opacity(0.7), lineWidth: 0.65)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : ReaderMotion.selectionFeedback, value: hasCustomSelection)
        }
    }

    private var fontSelectionMenu: some View {
        Menu {
            Button {
                select(nil)
            } label: {
                if selectedID == nil {
                    Label("跟随原书", systemImage: "checkmark")
                } else {
                    Text("跟随原书")
                }
            }
            if !fonts.isEmpty {
                Divider()
                ForEach(fonts) { font in
                    Button {
                        select(font)
                    } label: {
                        if font.id == selectedID {
                            Label(font.displayName, systemImage: "checkmark")
                        } else {
                            Text(font.displayName)
                        }
                    }
                }
            } else {
                Divider()
                Text(isLoading ? "正在读取字体库…" : "暂无已导入字体")
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(hasCustomSelection ? appearance.accentSoft : appearance.surface)
                    Image(systemName: "textformat")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(hasCustomSelection ? appearance.accent : appearance.secondary)
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectionCaption)
                        .font(.caption)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(selectionName)
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                        .foregroundStyle(appearance.foreground)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(appearance.accent)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(hasCustomSelection ? appearance.accent : appearance.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: ReaderVisualStyle.minimumControlHeight, alignment: .leading)
            .background(
                controlSurface,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        hasCustomSelection ? appearance.accent.opacity(0.45) : appearance.edge.opacity(0.75),
                        lineWidth: hasCustomSelection ? 1.0 : 0.65
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: appearance.subtleShadow, radius: 4, x: 0, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(isImporting || isDeleting)
        .opacity(isImporting || isDeleting ? 0.55 : 1)
        .accessibilityLabel("当前书的正文字体")
        .accessibilityValue(isLoading ? "\(selectionName)，正在读取字体库" : selectionName)
        .accessibilityHint(fonts.isEmpty ? "当前暂无已导入字体，可选择跟随原书或从下方导入" : "轻点选择跟随原书或已导入字体")
        .accessibilityIdentifier("epub.font.selection")
    }

    private var specimenCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            specimenHeader
                .padding(.trailing, 14)
            Rectangle()
                .fill(Color(uiColor: appearance.theme.foreground).opacity(0.10))
                .frame(height: 0.5)
                .accessibilityHidden(true)
            Text("山间有风，书中有光。\nAa Bb 123")
                .font(preview ?? .system(.body, design: .serif))
                .lineSpacing(5)
                .foregroundStyle(Color(uiColor: appearance.theme.foreground))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            Color(uiColor: appearance.theme.background),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 7, y: 0))
                path.addLine(to: CGPoint(x: 7, y: 13))
                path.addLine(to: CGPoint(x: 3.5, y: 10))
                path.addLine(to: CGPoint(x: 0, y: 13))
                path.closeSubpath()
            }
            .fill(appearance.sealAccent.opacity(0.88))
            .frame(width: 7, height: 13)
            .padding(.trailing, 14)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.85), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(specimenAccessibilityLabel)
    }

    @ViewBuilder
    private var specimenHeader: some View {
        if dynamicType.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                specimenBadge
                specimenStatus
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    specimenBadge
                    Spacer(minLength: 8)
                    specimenStatus
                }
                VStack(alignment: .leading, spacing: 4) {
                    specimenBadge
                    specimenStatus
                }
            }
        }
    }

    private var specimenBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(appearance.sealAccent)
                .frame(width: 5.5, height: 5.5)
            Text("字体样张")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(uiColor: appearance.theme.foreground).opacity(0.65))
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var specimenStatus: some View {
        Text(specimenStatusText)
            .font(.caption.weight(.medium))
            .foregroundStyle(appearance.accent)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(appearance.accent)
                .accessibilityHidden(true)
            Text("正在读取已导入字体…")
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var emptyLibraryHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tray")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(appearance.accent)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text("字体库暂无自定义字体。支持导入本机或 iCloud 中已下载的 TTF / OTF（单文件 ≤ \(EPUBUserFontStore.maxFontMiB) MiB，共 ≤ 32 MiB）。")
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            appearance.surface.opacity(appearance.theme == .dark ? 0.55 : 0.72),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.55), lineWidth: 0.6)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("epub.font.empty")
    }

    @ViewBuilder
    private var actionBar: some View {
        if hasCustomSelection {
            if dynamicType.isAccessibilitySize {
                VStack(spacing: 8) {
                    importButton
                    followOriginalButton
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        importButton
                        followOriginalButton
                    }
                    VStack(spacing: 8) {
                        importButton
                        followOriginalButton
                    }
                }
            }
        } else {
            importButton
        }
    }

    private var importButton: some View {
        Button(action: openFiles) {
            Group {
                if isImporting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(appearance.accent)
                            .accessibilityHidden(true)
                        Text("正在导入字体…")
                    }
                } else {
                    Label(hasCustomSelection ? "导入字体" : "从“文件”导入字体", systemImage: "folder.badge.plus")
                }
            }
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: ReaderVisualStyle.minimumControlHeight)
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, role: .primary, cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(appearance.accent.opacity(0.32), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .disabled(isImporting || isDeleting)
        .accessibilityLabel(isImporting ? "正在导入字体" : "从文件导入字体")
        .accessibilityHint("打开系统文件选取本机或 iCloud 中已下载的 TTF 或 OTF 字体")
        .accessibilityIdentifier("epub.font.import")
    }

    private var followOriginalButton: some View {
        Button { select(nil) } label: {
            Label("跟随原书", systemImage: "arrow.uturn.backward")
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: dynamicType.isAccessibilitySize ? .infinity : nil,
                       minHeight: ReaderVisualStyle.minimumControlHeight)
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.secondary, role: .primary, cornerRadius: 14))
        .disabled(isImporting || isDeleting)
        .accessibilityLabel("切回跟随原书字体")
        .accessibilityIdentifier("epub.font.followOriginal")
    }

    private func noticeBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.footnote)
                .foregroundStyle(isError ? appearance.sealAccent : appearance.accent)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(appearance.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isError
                ? appearance.sealAccent.opacity(appearance.theme == .dark ? 0.18 : 0.10)
                : appearance.accentSoft,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(isError ? appearance.sealAccent : appearance.accent)
                .frame(width: 3)
                .padding(.leading, 7)
                .padding(.vertical, 8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    (isError ? appearance.sealAccent : appearance.accent).opacity(0.32),
                    lineWidth: 0.65
                )
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("epub.font.notice")
    }

    private var footnoteSummary: some View {
        Text("仅对本书生效 · 支持 TTF / OTF（单文件 ≤ \(EPUBUserFontStore.maxFontMiB) MiB，字体库 ≤ 32 MiB）")
            .font(.caption)
            .foregroundStyle(appearance.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

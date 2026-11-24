import SwiftUI

@MainActor
struct LibraryExploreContent: View {
    let appearance: LibraryAppearance
    let canOpenFeatures: Bool
    let onOpenFeature: (LibraryPlannedFeature) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        YueJingBrandMark(tint: appearance.accent, sealTint: appearance.sealAccent, size: 24)
                        Text("探索 · 远景陈列")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(appearance.secondary)
                    }
                    Text("探索更多故事")
                        .font(AppVisualStyle.pageTitleFont)
                        .foregroundStyle(appearance.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("以下模块均为未来规划入口，当前版本保持纯离线阅读，不接入内容源、抓取或 AI 服务。")
                        .font(.subheadline)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)

                LibraryPlannedEntriesView(
                    appearance: appearance,
                    canOpenFeatures: canOpenFeatures,
                    features: LibraryPlannedFeature.modules,
                    onOpenFeature: onOpenFeature
                )
            }
            .padding(.horizontal, LibraryAppearance.horizontalInset)
            .padding(.top, 8)
            .padding(.bottom, LibraryAppearance.contentBottomSpacing)
        }
        .background(appearance.page.ignoresSafeArea())
        .foregroundStyle(appearance.foreground)
    }
}

@MainActor
struct LibrarySettingsContent<Options: View>: View {
    let appearance: LibraryAppearance
    let options: Options

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("书斋设置")
                        .font(AppVisualStyle.pageTitleFont)
                        .foregroundStyle(appearance.foreground)
                        .accessibilityAddTraits(.isHeader)
                    Text("调整书架外观，查看支持的书籍格式与版本信息。")
                        .font(.subheadline)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)

                options
            }
            .padding(.horizontal, LibraryAppearance.horizontalInset)
            .padding(.top, 8)
            .padding(.bottom, LibraryAppearance.contentBottomSpacing)
        }
        .background(appearance.page.ignoresSafeArea())
        .foregroundStyle(appearance.foreground)
    }
}

/// Guarded settings actions without another route owner.
@MainActor
struct LibraryManagementOptions: View {
    let appearance: LibraryAppearance
    let appAppearance: AppAppearance
    @Binding var developerMode: Bool
    let canChange: Bool
    let onAppearance: (AppAppearance) -> Void
    let onOpenFeature: (LibraryPlannedFeature) -> Void
    let onInformation: (LibraryInformationPage) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            appearanceSection
            ReadingTimeSummary()
            formatsSection
            aboutSection
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionTitle("外观氛围")
                Spacer(minLength: 8)
                Menu {
                    ForEach(AppAppearance.allCases, id: \.self) { option in
                        Button { onAppearance(option) } label: {
                            if option == appAppearance { Label("\(option.title) · 当前", systemImage: "checkmark") }
                            else { Text(option.title) }
                        }
                        .accessibilityLabel("App 外观，\(option.title)")
                        .accessibilityValue(option == appAppearance ? "当前" : "未选中")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(appAppearance.title)
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(appearance.accent)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 44, minHeight: 36)
                    .background(appearance.accentSoft, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .disabled(!canChange)
                .accessibilityLabel("App 外观")
                .accessibilityValue(appAppearance.title)
                .accessibilityHint("仅改变管理界面，不改变阅读背景")
                .accessibilityIdentifier("library.appAppearance")
            }

            Group {
                if dynamicType.isAccessibilitySize {
                    VStack(spacing: 10) {
                        ForEach(AppAppearance.allCases, id: \.self) { option in
                            appearanceCard(option)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(AppAppearance.allCases, id: \.self) { option in
                            appearanceCard(option)
                        }
                    }
                }
            }

            Text("外观仅改变书架与管理界面，阅读正文主题请在阅读设置中独立调节。")
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func appearanceCard(_ option: AppAppearance) -> some View {
        let previewStyle = AppVisualStyle(appearance: option, colorScheme: systemColorScheme)
        let selected = option == appAppearance
        return Button {
            onAppearance(option)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // Live miniature palette preview of the appearance
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(previewStyle.page)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(previewStyle.accent)
                                .frame(width: 14, height: 14)
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(previewStyle.foreground.opacity(0.75))
                                .frame(width: 30, height: 5)
                            Spacer(minLength: 0)
                            Circle()
                                .fill(previewStyle.sealAccent)
                                .frame(width: 5, height: 5)
                        }
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(previewStyle.surface)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(previewStyle.edge, lineWidth: 0.5)
                            }
                            .overlay(alignment: .leading) {
                                HStack(spacing: 5) {
                                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                        .fill(previewStyle.coverSurface)
                                        .frame(width: 12, height: 16)
                                    VStack(alignment: .leading, spacing: 3) {
                                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                            .fill(previewStyle.foreground.opacity(0.65))
                                            .frame(width: 28, height: 3.5)
                                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                            .fill(previewStyle.secondary.opacity(0.55))
                                            .frame(width: 18, height: 3)
                                    }
                                }
                                .padding(.horizontal, 5)
                            }
                            .frame(height: 26)
                    }
                    .padding(7)
                }
                .frame(height: 58)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(previewStyle.edge.opacity(0.85), lineWidth: 0.6)
                }
                .accessibilityHidden(true)

                HStack(alignment: .center, spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title)
                            .font(.subheadline.weight(selected ? .semibold : .medium))
                            .foregroundStyle(appearance.foreground)
                        if dynamicType.isAccessibilitySize {
                            Text(option.subtitle)
                                .font(.caption)
                                .foregroundStyle(appearance.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline)
                        .foregroundStyle(selected ? appearance.accent : appearance.secondary.opacity(0.45))
                        .accessibilityHidden(true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(appearance.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(appearance.accentSoft.opacity(appearance.isDarkSurface ? 0.45 : 0.30))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        selected ? appearance.accent : appearance.edge.opacity(0.8),
                        lineWidth: selected ? 1.6 : 0.75
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: appearance.cardShadow, radius: selected ? 8 : 4, x: 0, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canChange)
        .opacity(canChange ? 1 : 0.45)
        .animation(reduceMotion ? nil : ReaderMotion.selectionFeedback, value: selected)
        .accessibilityLabel("外观主题，\(option.title)，\(option.subtitle)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("library.appearance.option.\(option.rawValue)")
    }

    private var formatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("格式与书籍显示")
            LibraryPlannedEntriesView(
                appearance: appearance,
                canOpenFeatures: canChange,
                features: [.epub, .cover],
                onOpenFeature: onOpenFeature
            )
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("关于阅境")
            VStack(spacing: 0) {
                settingsActionRow(title: "开源许可", detail: "查看阅境使用的开源组件及许可", symbol: "doc.text") {
                    onInformation(.license)
                }
                .accessibilityIdentifier("library.about.license")
                rowDivider
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(appearance.subtleSurface)
                        Image(systemName: "info.circle")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(appearance.secondary)
                    }
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前版本")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(appearance.foreground)
                        Text(AppVersion.current.displayText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(appearance.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("app.version")
                rowDivider
                Toggle(isOn: $developerMode) {
                    HStack(alignment: .center, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(developerMode ? appearance.sealSoft : appearance.subtleSurface)
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(developerMode ? appearance.sealAccent : appearance.secondary)
                        }
                        .frame(width: 34, height: 34)
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("开发者模式")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(appearance.foreground)
                                if developerMode && !dynamicType.isAccessibilitySize {
                                    Text("已开启")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(appearance.sealAccent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(appearance.sealSoft, in: Capsule())
                                        .accessibilityHidden(true)
                                }
                            }
                            Text("在书架和阅读设置中显示本机诊断入口。")
                                .font(.caption)
                                .foregroundStyle(appearance.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .tint(appearance.sealAccent)
                .disabled(!canChange)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .accessibilityLabel("开发者模式")
                .accessibilityHint("在书架和阅读设置中显示诊断信息")
                .accessibilityIdentifier("library.developerMode")
                if developerMode {
                    rowDivider
                    settingsActionRow(
                        title: "导入诊断",
                        detail: "查看本次导入的阶段与耗时",
                        symbol: "waveform.path.ecg",
                        iconTint: appearance.sealAccent,
                        iconFill: appearance.sealSoft,
                        badge: "仅本机"
                    ) {
                        onInformation(.diagnostics)
                    }
                    .accessibilityIdentifier("library.importDiagnostics")
                }
            }
            .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
                    .strokeBorder(appearance.edge.opacity(0.8), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .shadow(color: appearance.cardShadow, radius: 6, x: 0, y: 2)

            // Quiet studio colophon signature
            HStack(spacing: 12) {
                YueJingBrandMark(tint: appearance.accent, sealTint: appearance.sealAccent, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("阅境 · 专注本地离线阅读")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appearance.foreground.opacity(0.88))
                    Text("原文件只读保留 · 零云端追踪")
                        .font(.caption2)
                        .foregroundStyle(appearance.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(appearance.subtleSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(appearance.edge.opacity(0.6), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        }
    }
    private func settingsActionRow(
        title: String,
        detail: String,
        symbol: String,
        iconTint: Color? = nil,
        iconFill: Color? = nil,
        badge: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let resolvedTint = iconTint ?? appearance.accent
        let resolvedFill = iconFill ?? appearance.accentSoft
        return Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(resolvedFill)
                    Image(systemName: symbol)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(resolvedTint)
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(appearance.foreground)
                        if let badge, !dynamicType.isAccessibilitySize {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(resolvedTint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(resolvedFill, in: Capsule())
                                .accessibilityHidden(true)
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(appearance.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.secondary.opacity(0.65))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: 0))
        .disabled(!canChange)
    }
    private var rowDivider: some View {
        Rectangle()
            .fill(appearance.edge.opacity(0.65))
            .frame(height: 0.5)
            .padding(.leading, 60)
            .accessibilityHidden(true)
    }

    private func sectionTitle(_ title: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(appearance.accent)
                .frame(width: 3, height: 15)
                .accessibilityHidden(true)
            Text(title)
                .font(LibraryAppearance.sectionTitleFont)
                .foregroundStyle(appearance.foreground)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

@MainActor
struct LibraryLicenseView: View {
    let appearance: LibraryAppearance

    // Immutable bundled resources, read on demand; never replaces or invents license text.
    static func bundledLicenseText() -> String {
        guard let grdbURL = Bundle.main.url(forResource: "GRDB-LICENSE", withExtension: "txt"),
              let grdb = try? String(contentsOf: grdbURL, encoding: .utf8), !grdb.isEmpty,
              let zipURL = Bundle.main.url(forResource: "ZIPFoundation-LICENSE", withExtension: "txt"),
              let zip = try? String(contentsOf: zipURL, encoding: .utf8), !zip.isEmpty else {
            return "许可文件读取失败。"
        }
        return "GRDB.swift · MIT\n\n" + grdb + "\n\n---\n\nZIPFoundation · MIT\n\n" + zip
    }

    private static let text: String = bundledLicenseText()

    var body: some View {
        ScrollView {
            Text(Self.text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
                        .strokeBorder(appearance.edge.opacity(0.8), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
                .padding(LibraryAppearance.horizontalInset)
        }
        .foregroundStyle(appearance.foreground)
        .background(appearance.page.ignoresSafeArea())
        .navigationTitle("GRDB & ZIPFoundation · MIT")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(appearance.page, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(appearance.controlColorScheme, for: .navigationBar)
    }
}

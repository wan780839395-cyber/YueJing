import ReaderDomain
import SwiftUI

@MainActor
struct LibraryPlannedEntriesView: View {
    let appearance: LibraryAppearance
    let canOpenFeatures: Bool
    var features: [LibraryPlannedFeature] = LibraryPlannedFeature.modules
    let onOpenFeature: (LibraryPlannedFeature) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicType

    private var moduleFeatures: [LibraryPlannedFeature] {
        features.filter { LibraryPlannedFeature.modules.contains($0) }
    }

    private var infoFeatures: [LibraryPlannedFeature] {
        features.filter { !LibraryPlannedFeature.modules.contains($0) }
    }

    private var primaryButtonForeground: Color {
        appearance.isDarkSurface ? Color.black.opacity(0.9) : Color.white
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !moduleFeatures.isEmpty {
                let storyFeature = moduleFeatures.first { $0 == .aiStory }
                let otherModules = moduleFeatures.filter { $0 != .aiStory }

                if let storyFeature {
                    aiStoryPortalCard(storyFeature)
                }

                if !otherModules.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("规划中模块")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(appearance.secondary)
                                .accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 8)
                            Text("入口预留")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(appearance.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(appearance.subtleSurface, in: Capsule())
                        }

                        VStack(spacing: 12) {
                            ForEach(otherModules) { feature in
                                moduleCard(feature)
                            }
                        }
                    }
                }
            }

            if !infoFeatures.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(infoFeatures.enumerated()), id: \.element.id) { index, feature in
                        if index > 0 {
                            Rectangle()
                                .fill(appearance.edge.opacity(0.65))
                                .frame(height: 0.5)
                                .padding(.leading, 60)
                                .accessibilityHidden(true)
                        }
                        informationButton(feature)
                    }
                }
                .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
                        .strokeBorder(appearance.edge.opacity(0.8), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
                .shadow(color: appearance.cardShadow, radius: 6, x: 0, y: 2)
            }

            Text(features.contains(.comics)
                 ? "AI 故事已支持选书选角、预设导入及自配 BYOK 确认后生成；漫画聚合仍为规划入口。"
                 : "已支持本地 TXT 与非 DRM 可重排 EPUB 2/3（含内嵌封面与文字占位回退）；支持 EPUB 本地书签，不支持固定版式、DRM、脚本及联网资源。")
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!canOpenFeatures)
    }

    private func aiStoryPortalCard(_ feature: LibraryPlannedFeature) -> some View {
        Button {
            StoryHaptics.selection()
            onOpenFeature(feature)
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                        Text("AI 故事 · 活页书境")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(appearance.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(appearance.accentSoft, in: Capsule())

                    Spacer(minLength: 8)

                    Text("已开放")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(appearance.sealAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(appearance.sealSoft, in: Capsule())
                }

                Group {
                    if dynamicType.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 12) {
                            portalHeadline(feature)
                        }
                    } else {
                        HStack(alignment: .center, spacing: 16) {
                            StoryLivingSigilView(
                                roleKind: .canon,
                                roleName: "阅境书境",
                                appearance: appearance,
                                size: 62
                            )
                            portalHeadline(feature)
                            Spacer(minLength: 0)
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        portalTag("真实正文开篇")
                        portalTag("原著 / 原创角色")
                        portalTag("预设与 BYOK")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            portalTag("真实正文开篇")
                            portalTag("原著 / 原创角色")
                        }
                        portalTag("预设与 BYOK")
                    }
                }

                HStack(spacing: 8) {
                    Text("进入 AI 故事剧场")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(primaryButtonForeground)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .background(appearance.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [
                        appearance.surface,
                        appearance.surface.opacity(0.94),
                        appearance.accentSoft.opacity(appearance.isDarkSurface ? 0.42 : 0.52)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay {
                StoryShimmerBorder(cornerRadius: 24, appearance: appearance)
            }
            .shadow(color: appearance.cardShadow, radius: 14, x: 0, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: 24))
        .accessibilityLabel("\(feature.title)，支持真实正文开篇、原著与原创角色、叙事预设及 BYOK 模型生成")
        .accessibilityHint("进入 AI 故事列表或新建故事")
        .accessibilityIdentifier("library.planned.entry.\(feature.rawValue)")
    }

    private func portalHeadline(_ feature: LibraryPlannedFeature) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("从你的小说，亲身入戏")
                .font(.system(.title3, design: .serif).weight(.bold))
                .foregroundStyle(appearance.foreground)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text("任选书架中的 TXT / EPUB，借原著人物双目或自创身份切入原著开篇，每轮经你预览确认后推进剧情。")
                .font(.footnote)
                .lineSpacing(3)
                .foregroundStyle(appearance.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func portalTag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(appearance.foreground.opacity(0.86))
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(appearance.subtleSurface.opacity(0.85), in: Capsule())
    }

    private func moduleCard(_ feature: LibraryPlannedFeature) -> some View {
        let implemented = feature.isImplemented
        let statusBadge = implemented ? "已开放" : "规划中"
        let subtitle = implemented ? "选书选角 · 预设与 BYOK 生成" : "未接入 · 查看预留说明"
        let axLabel = implemented ? "\(feature.title)，支持叙事预设与 BYOK 模型生成" : "\(feature.title)，规划中，未接入"
        let axHint = implemented ? "进入 AI 故事，选择小说、角色与可选预设" : "查看静态规划说明，不启动服务"
        return Button {
            onOpenFeature(feature)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(implemented ? appearance.accentSoft : appearance.subtleSurface)
                        Image(systemName: feature.symbol)
                            .font(.body.weight(.medium))
                            .foregroundStyle(implemented ? appearance.accent : appearance.secondary)
                    }
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)

                    Spacer(minLength: 0)

                    Text(statusBadge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(implemented ? appearance.accent : appearance.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(implemented ? appearance.accentSoft : appearance.subtleSurface, in: Capsule())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(feature.title)
                        .font(.system(.headline, design: .serif).weight(.semibold))
                        .foregroundStyle(appearance.foreground)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(appearance.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        implemented ? appearance.accent.opacity(0.35) : appearance.edge.opacity(0.8),
                        lineWidth: 0.75
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: appearance.cardShadow, radius: 6, x: 0, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: LibraryAppearance.cardCornerRadius))
        .accessibilityLabel(axLabel)
        .accessibilityHint(axHint)
        .accessibilityIdentifier("library.planned.entry.\(feature.rawValue)")
    }

    private func informationButton(_ feature: LibraryPlannedFeature) -> some View {
        let statusLabel = feature.isImplemented ? "已支持（首版范围）" : "预留"
        let axLabel = feature.isImplemented
            ? "\(feature.title)，已支持，首版范围与限制说明"
            : "\(feature.title)，规划中，未接入"
        return Button {
            onOpenFeature(feature)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(feature.isImplemented ? appearance.accentSoft : appearance.subtleSurface)
                    Image(systemName: feature.symbol)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(feature.isImplemented ? appearance.accent : appearance.secondary)
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(appearance.foreground)
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(feature.isImplemented ? appearance.accent : appearance.secondary)
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
        .accessibilityLabel(axLabel)
        .accessibilityHint("查看支持范围与限制说明，不启动服务")
        .accessibilityIdentifier("library.planned.entry.\(feature.rawValue)")
    }
}

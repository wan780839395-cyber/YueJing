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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !moduleFeatures.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("更多故事模块")
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

                Group {
                    if dynamicType.isAccessibilitySize {
                        VStack(spacing: 12) {
                            ForEach(moduleFeatures) { feature in moduleCard(feature) }
                        }
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(moduleFeatures) { feature in moduleCard(feature) }
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
                 ? "漫画聚合与 AI 故事仍为规划入口，以上故事扩展均未接入。"
                 : "已支持本地 TXT 与非 DRM 可重排 EPUB 2/3（含内嵌封面与文字占位回退）；支持 EPUB 本地书签，不支持固定版式、DRM、脚本及联网资源。")
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!canOpenFeatures)
    }

    private func moduleCard(_ feature: LibraryPlannedFeature) -> some View {
        Button {
            onOpenFeature(feature)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(appearance.subtleSurface)
                        Image(systemName: feature.symbol)
                            .font(.body.weight(.medium))
                            .foregroundStyle(appearance.accent)
                    }
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)

                    Spacer(minLength: 0)

                    Text("规划中")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(appearance.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(appearance.subtleSurface, in: Capsule())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(feature.title)
                        .font(.system(.headline, design: .serif).weight(.semibold))
                        .foregroundStyle(appearance.foreground)
                    Text("未接入 · 查看预留说明")
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
                    .strokeBorder(appearance.edge.opacity(0.8), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .shadow(color: appearance.cardShadow, radius: 6, x: 0, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: LibraryAppearance.cardCornerRadius))
        .accessibilityLabel("\(feature.title)，规划中，未接入")
        .accessibilityHint("查看静态规划说明，不启动服务")
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

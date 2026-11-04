import SwiftUI

@MainActor
struct LibraryPlannedEntriesView: View {
    let appearance: LibraryAppearance
    let canOpenFeatures: Bool
    var features: [LibraryPlannedFeature] = LibraryPlannedFeature.modules
    let onOpenFeature: (LibraryPlannedFeature) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(features.contains(.comics) ? "更多故事" : "格式与书籍显示").font(.footnote).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(features.contains(.comics) ? "入口预留" : "首版范围说明").font(.caption)
            }
            .foregroundStyle(appearance.secondary)
            Group {
                if dynamicType.isAccessibilitySize {
                    VStack(spacing: 10) {
                        ForEach(features.filter { LibraryPlannedFeature.modules.contains($0) }) { feature in moduleButton(feature) }
                    }
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(features.filter { LibraryPlannedFeature.modules.contains($0) }) { feature in moduleButton(feature) }
                    }
                }
            }
            .padding(features.contains(where: { LibraryPlannedFeature.modules.contains($0) }) ? 4 : 0)
            .background(appearance.groupSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(spacing: 0) {
                ForEach(features.filter { !LibraryPlannedFeature.modules.contains($0) }) { feature in informationButton(feature) }
            }
            Text(features.contains(.comics)
                 ? "漫画聚合与 AI 故事仍为规划入口，以上故事扩展均未接入。"
                 : "已支持本地 TXT 与非 DRM 可重排 EPUB 2/3（含内嵌封面与文字占位回退）；不支持固定版式、DRM、脚本、联网资源及 EPUB 书签。")
                .font(.caption).foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 24)
        .disabled(!canOpenFeatures)
    }

    private func moduleButton(_ feature: LibraryPlannedFeature) -> some View {
        Button {
            onOpenFeature(feature)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: feature.symbol)
                    .font(.subheadline).foregroundStyle(appearance.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(feature.title).font(.subheadline.weight(.medium))
                        .foregroundStyle(appearance.foreground)
                    Text("规划中 · 未接入").font(.caption2).foregroundStyle(appearance.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: LibraryAppearance.entryCornerRadius, style: .continuous))
        }
        .buttonStyle(AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: LibraryAppearance.entryCornerRadius))
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(feature.title) · \(statusLabel)")
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(appearance.foreground)
            .frame(maxWidth: .infinity, minHeight: LibraryAppearance.minimumControlHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: 0))
        .accessibilityLabel(axLabel)
        .accessibilityHint("查看支持范围与限制说明，不启动服务")
        .accessibilityIdentifier("library.planned.entry.\(feature.rawValue)")
    }
}

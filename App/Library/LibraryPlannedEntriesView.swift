import SwiftUI

@MainActor
struct LibraryPlannedEntriesView: View {
    let appearance: LibraryAppearance
    let canOpenFeatures: Bool
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(appearance.edge).frame(height: 0.5)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("更多故事").font(.footnote).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text("入口预留").font(.caption)
            }
            .foregroundStyle(appearance.secondary)
            if dynamicType.isAccessibilitySize {
                VStack(spacing: 10) {
                    ForEach(LibraryPlannedFeature.modules) { feature in moduleLink(feature) }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(LibraryPlannedFeature.modules) { feature in moduleLink(feature) }
                }
            }
            VStack(spacing: 0) {
                informationLink(.epub)
                informationLink(.cover)
            }
            Text("当前仅支持 TXT 导入，以上扩展均未接入。")
                .font(.caption).foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .disabled(!canOpenFeatures)
    }

    private func moduleLink(_ feature: LibraryPlannedFeature) -> some View {
        NavigationLink {
            LibraryPlannedFeatureView(feature: feature)
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
            .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.entryCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: LibraryAppearance.entryCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(feature.title)，规划中，未接入")
        .accessibilityHint("查看静态规划说明，不启动服务")
        .accessibilityIdentifier("library.planned.entry.\(feature.rawValue)")
    }

    private func informationLink(_ feature: LibraryPlannedFeature) -> some View {
        NavigationLink {
            LibraryPlannedFeatureView(feature: feature)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(feature.title) · 预留")
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(appearance.accent)
            .frame(maxWidth: .infinity, minHeight: LibraryAppearance.minimumControlHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(feature.title)，规划中，未接入")
        .accessibilityHint("查看静态规划说明，不启动服务")
        .accessibilityIdentifier("library.planned.entry.\(feature.rawValue)")
    }
}

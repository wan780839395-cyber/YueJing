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
                Text("入口预留").font(.caption)
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
            Text("当前仅支持 TXT 导入，以上扩展均未接入。")
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
        Button {
            onOpenFeature(feature)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(feature.title) · 预留")
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
        .accessibilityLabel("\(feature.title)，规划中，未接入")
        .accessibilityHint("查看静态规划说明，不启动服务")
        .accessibilityIdentifier("library.planned.entry.\(feature.rawValue)")
    }
}

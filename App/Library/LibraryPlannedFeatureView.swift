import SwiftUI

@MainActor
struct LibraryPlannedFeatureView: View {
    let feature: LibraryPlannedFeature
    let appearance: LibraryAppearance

    init(feature: LibraryPlannedFeature, appearance: LibraryAppearance) {
        self.feature = feature
        self.appearance = appearance
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(feature.isImplemented ? appearance.accentSoft : appearance.subtleSurface)
                            Image(systemName: feature.symbol)
                                .font(.title2.weight(.medium))
                                .foregroundStyle(feature.isImplemented ? appearance.accent : appearance.secondary)
                        }
                        .frame(width: 52, height: 52)
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(feature.isImplemented ? "已支持 · 首版范围" : "布局预留 · 未接入")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(feature.isImplemented ? appearance.accent : appearance.secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(
                                    feature.isImplemented ? appearance.accentSoft : appearance.subtleSurface,
                                    in: Capsule()
                                )
                            Text(feature.title)
                                .font(.system(.title2, design: .serif).weight(.semibold))
                                .foregroundStyle(appearance.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }

                    Text(feature.summary)
                        .font(.body)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
                        .strokeBorder(appearance.edge.opacity(0.8), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("详细说明")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appearance.foreground)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(Array(feature.notes.enumerated()), id: \.offset) { index, note in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(appearance.accent)
                                .frame(width: 20, height: 20)
                                .background(appearance.accentSoft, in: Circle())
                                .accessibilityHidden(true)
                            Text(note)
                                .font(.subheadline)
                                .foregroundStyle(appearance.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
                        .strokeBorder(appearance.edge.opacity(0.8), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }

                Text(feature.isImplemented
                     ? "此页只说明当前首版支持范围与安全边界。使用系统返回即可回到上一页。"
                     : "此页只说明预留范围，不会启动导入、下载或生成任务。使用系统返回即可回到书架。")
                    .font(.footnote)
                    .foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LibraryAppearance.horizontalInset)
        }
        .foregroundStyle(appearance.foreground)
        .background(appearance.page.ignoresSafeArea())
        .tint(appearance.accent)
        .navigationTitle(feature.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(appearance.page, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(appearance.controlColorScheme, for: .navigationBar)
        .accessibilityIdentifier("library.planned.\(feature.rawValue)")
    }
}

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
                Image(systemName: feature.symbol)
                    .font(.largeTitle).foregroundStyle(appearance.accent)
                    .accessibilityHidden(true)
                Text("布局预留 · 未接入")
                    .font(.caption).foregroundStyle(appearance.accent)
                Text(feature.title)
                    .font(.system(.title, design: .serif).weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(feature.summary)
                    .font(.body).foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(appearance.edge).frame(height: 0.5)
                    .accessibilityHidden(true)
                ForEach(feature.notes, id: \.self) { note in
                    Text(note)
                        .font(.subheadline).foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("此页只说明预留范围，不会启动导入、下载或生成任务。使用系统返回即可回到书架。")
                    .font(.footnote).foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

import SwiftUI

@MainActor
struct LibraryExploreContent: View {
    let appearance: LibraryAppearance
    let canOpenFeatures: Bool
    let onOpenFeature: (LibraryPlannedFeature) -> Void

    var body: some View {
        List {
            Section {
                Text("探索更多故事").font(AppVisualStyle.pageTitleFont).accessibilityAddTraits(.isHeader)
                Text("以下能力均为规划，未接入内容源或 AI 服务。")
                    .font(.footnote).foregroundStyle(appearance.secondary).fixedSize(horizontal: false, vertical: true)
                LibraryPlannedEntriesView(appearance: appearance, canOpenFeatures: canOpenFeatures,
                                          features: LibraryPlannedFeature.modules, onOpenFeature: onOpenFeature)
            }.listRowBackground(appearance.page)
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .background(appearance.page.ignoresSafeArea()).foregroundStyle(appearance.foreground)
    }
}

@MainActor
struct LibrarySettingsContent<Options: View>: View {
    let appearance: LibraryAppearance
    let options: Options
    var body: some View {
        List {
            options
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden)
        .background(appearance.page.ignoresSafeArea()).foregroundStyle(appearance.foreground)
    }
}

/// Guarded settings actions without another route owner.
@MainActor
struct LibraryManagementOptions: View {
    let appearance: LibraryAppearance
    let appAppearance: AppAppearance
    let canChange: Bool
    let onAppearance: (AppAppearance) -> Void
    let onOpenFeature: (LibraryPlannedFeature) -> Void
    let onInformation: (LibraryInformationPage) -> Void

    var body: some View {
        Section {
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
                optionLabel("外观", value: appAppearance.title, symbol: "paintpalette")
            }
            .buttonStyle(AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: 0))
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparatorTint(appearance.edge.opacity(0.6))
            .disabled(!canChange)
            .accessibilityLabel("App 外观").accessibilityValue(appAppearance.title)
            .accessibilityHint("仅改变管理界面，不改变阅读背景")
            .accessibilityIdentifier("library.appAppearance")
        } header: {
            Text("外观")
        } footer: {
            Text("外观仅改变管理界面，不改变阅读背景。")
                .font(.footnote).fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(appearance.groupSurface)
        Section("格式与书籍显示") {
            LibraryPlannedEntriesView(appearance: appearance, canOpenFeatures: canChange,
                                      features: [.epub, .cover], onOpenFeature: onOpenFeature)
        }.listRowBackground(appearance.surface)
        Section("本地信息") {
            Button { onInformation(.diagnostics) } label: {
                Label("诊断与耗时", systemImage: "ladybug").frame(minHeight: 44)
            }.disabled(!canChange)
            Button { onInformation(.license) } label: {
                Label("开源许可", systemImage: "doc.text").frame(minHeight: 44)
            }.disabled(!canChange)
        }.listRowBackground(appearance.surface)
    }

    @ViewBuilder
    private func optionLabel(_ title: String, value: String, symbol: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.body.weight(.medium)).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                Text(value).font(.subheadline).foregroundStyle(appearance.secondary).fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down").font(.caption.weight(.medium)).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.medium))
                HStack(spacing: 8) {
                    Text(value).font(.subheadline).foregroundStyle(appearance.secondary)
                    Image(systemName: "chevron.down").font(.caption.weight(.medium)).accessibilityHidden(true)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(Rectangle())
    }
}

@MainActor
struct LibraryLicenseView: View {
    let appearance: LibraryAppearance
    // One immutable bundled resource, read on demand; never replaces or invents license text.
    private static let text: String = {
        guard let url = Bundle.main.url(forResource: "GRDB-LICENSE", withExtension: "txt"),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return "许可文件读取失败。" }
        return value
    }()

    var body: some View {
        ScrollView {
            Text(Self.text).font(.footnote).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(22)
        }
        .foregroundStyle(appearance.foreground).background(appearance.page.ignoresSafeArea())
        .navigationTitle("GRDB · MIT").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(appearance.page, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(appearance.controlColorScheme, for: .navigationBar)
    }
}

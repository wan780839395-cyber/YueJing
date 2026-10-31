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

/// Same guarded actions in A's system menu and B/C's settings, without another route owner.
@MainActor
struct LibraryManagementOptions: View {
    let asMenu: Bool
    let appearance: LibraryAppearance
    let appAppearance: AppAppearance
    let layout: LibraryLayout
    let canChange: Bool
    let onAppearance: (AppAppearance) -> Void
    let onLayout: (LibraryLayout) -> Void
    let onOpenFeature: (LibraryPlannedFeature) -> Void
    let onInformation: (LibraryInformationPage) -> Void

    var body: some View {
        Section("外观与入口") {
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
                Label("外观 · \(appAppearance.title)", systemImage: "paintpalette")
                    .font(AppVisualStyle.actionFont).frame(minHeight: 44)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!canChange)
            .accessibilityLabel("App 外观").accessibilityValue(appAppearance.title)
            .accessibilityHint("仅改变管理界面，不改变阅读背景")
            .accessibilityIdentifier("library.appAppearance")
            Menu {
                ForEach(LibraryLayout.allCases, id: \.self) { option in
                    Button { onLayout(option) } label: {
                        if option == layout { Label("\(option.title) · 当前", systemImage: "checkmark") }
                        else { Text(option.title) }
                    }
                    .accessibilityValue(option == layout ? "当前" : "未选中")
                }
            } label: {
                Label("入口 · \(layout.title)", systemImage: "rectangle.3.group")
                    .font(AppVisualStyle.actionFont).frame(minHeight: 44)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!canChange)
            .accessibilityIdentifier("library.layout")
        }.listRowBackground(appearance.surface)
        Section("格式与书籍显示") {
            if asMenu {
                Button("EPUB 格式 · 规划中，未接入") { onOpenFeature(.epub) }
                    .disabled(!canChange).accessibilityIdentifier("library.planned.entry.epub")
                Button("封面展示 · 规划中，未接入") { onOpenFeature(.cover) }
                    .disabled(!canChange).accessibilityIdentifier("library.planned.entry.cover")
            } else {
                LibraryPlannedEntriesView(appearance: appearance, canOpenFeatures: canChange,
                                          features: [.epub, .cover], onOpenFeature: onOpenFeature)
            }
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

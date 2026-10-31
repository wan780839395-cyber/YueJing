import SwiftUI

/// Presentation only. The parent owns guarded bindings, routes and all business work.
@MainActor
struct LibraryNavigationShell<Shelf: View, Explore: View, Settings: View>: View {
    let layout: LibraryLayout
    @Binding var section: LibrarySection
    @Binding var drawerPresented: Bool
    let canNavigate: Bool
    let appearance: LibraryAppearance
    let onDrawerSection: (LibrarySection) -> Void
    let onDrawerInformation: (LibraryInformationPage) -> Void
    let shelf: Shelf
    let explore: Explore
    let settings: Settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var focusedControl: Focus?
    private enum Focus: Hashable { case menu, close }

    var body: some View {
        ZStack(alignment: .leading) {
            rootContent
                .allowsHitTesting(!drawerPresented)
                .accessibilityHidden(drawerPresented)
            drawerLayer
        }
        .background(appearance.page.ignoresSafeArea())
        .foregroundStyle(appearance.foreground)
        .tint(appearance.accent)
        .toolbar {
            if layout == .sidebar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { drawerPresented = true } label: {
                        Label("菜单", systemImage: "line.3.horizontal")
                            .labelStyle(.iconOnly)
                            .font(AppVisualStyle.actionFont).imageScale(.medium)
                            .foregroundStyle(appearance.accent)
                            .frame(minWidth: 44, minHeight: 44)
                            .background {
                                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                                shape.fill(appearance.surface)
                                    .overlay { shape.strokeBorder(appearance.edge, lineWidth: 0.8) }
                                    .allowsHitTesting(false)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canNavigate || drawerPresented)
                    .accessibilityHidden(drawerPresented)
                    .accessibilityFocused($focusedControl, equals: .menu)
                    .accessibilityIdentifier("library.sidebar.open")
                }
            }
        }
        .onChange(of: drawerPresented) { open in focusedControl = open ? .close : .menu }
    }

    @ViewBuilder private var rootContent: some View {
        switch layout {
        case .direct:
            shelf
        case .tabs:
            TabView(selection: $section) {
                shelf.tag(LibrarySection.shelf).tabItem { Label("书架", systemImage: "books.vertical") }
                explore.tag(LibrarySection.explore).tabItem { Label("探索", systemImage: "square.grid.2x2") }
                settings.tag(LibrarySection.settings).tabItem { Label("设置", systemImage: "slider.horizontal.3") }
            }
            .toolbarBackground(appearance.surface, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarColorScheme(appearance.controlColorScheme, for: .tabBar)
        case .sidebar:
            switch section {
            case .shelf: shelf
            case .explore: explore
            case .settings: settings
            }
        }
    }

    private var drawerLayer: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if drawerPresented {
                    Button { drawerPresented = false } label: {
                        Color.black.opacity(0.22).ignoresSafeArea()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭侧栏")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Button { drawerPresented = false } label: {
                                Label("关闭菜单", systemImage: "xmark")
                                    .font(AppVisualStyle.actionFont).imageScale(.medium)
                                    .padding(.horizontal, 12).frame(minHeight: 44)
                                    .background {
                                        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        shape.fill(appearance.page)
                                            .overlay { shape.strokeBorder(appearance.edge, lineWidth: 0.8) }
                                            .allowsHitTesting(false)
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityFocused($focusedControl, equals: .close)
                            Text("阅境 · 工作区").font(.title2).accessibilityAddTraits(.isHeader)
                            ForEach(LibrarySection.allCases, id: \.self) { item in
                                Button { onDrawerSection(item) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Label(item.title, systemImage: item.symbol)
                                        Spacer(minLength: 4)
                                        if item == section { Text("当前").font(.caption) }
                                    }
                                    .font(AppVisualStyle.actionFont).imageScale(.medium)
                                    .padding(.horizontal, 12).padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .background {
                                        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        shape.fill(item == section ? appearance.accent.opacity(0.1) : appearance.surface)
                                            .overlay { shape.strokeBorder(item == section ? appearance.accent : appearance.edge, lineWidth: 0.8) }
                                            .allowsHitTesting(false)
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(!canNavigate)
                                .accessibilityValue(item == section ? "当前" : "未选中")
                            }
                            Divider().overlay(appearance.edge)
                            Text("格式、外观与布局请进入设置").font(.footnote)
                                .foregroundStyle(appearance.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("诊断与耗时") { onDrawerInformation(.diagnostics) }.frame(minHeight: 44)
                                .disabled(!canNavigate)
                            Button("开源许可") { onDrawerInformation(.license) }.frame(minHeight: 44)
                                .disabled(!canNavigate)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: min(300, max(0, proxy.size.width - 32)), height: proxy.size.height)
                    .background(appearance.surface)
                    .overlay(alignment: .trailing) { Rectangle().fill(appearance.edge).frame(width: 0.5) }
                    .accessibilityAction(.escape) { drawerPresented = false }
                    .accessibilityIdentifier("library.sidebar")
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: drawerPresented)
            .transaction { if reduceMotion { $0.animation = nil } }
        }
        .allowsHitTesting(drawerPresented)
    }
}

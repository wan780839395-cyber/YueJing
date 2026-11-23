import SwiftUI

/// Presentation only. The parent owns guarded bindings, routes and all business work.
@MainActor
struct LibraryNavigationShell<Shelf: View, Explore: View, Settings: View>: View {
    @Binding var section: LibrarySection
    @Binding var drawerPresented: Bool
    let canNavigate: Bool
    let appearance: LibraryAppearance
    @AccessibilityFocusState.Binding var focusedControl: String?
    let shelf: Shelf
    let explore: Explore
    let settings: Settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        rootContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                floatingTabDock
                    .padding(.horizontal, LibraryAppearance.horizontalInset)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                    .allowsHitTesting(!drawerPresented && canNavigate)
                    .accessibilityHidden(drawerPresented)
            }
            .allowsHitTesting(!drawerPresented)
            .accessibilityHidden(drawerPresented)
            .background(appearance.page.ignoresSafeArea())
        .foregroundStyle(appearance.foreground)
        .tint(appearance.accent)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { drawerPresented = true } label: {
                    Label("菜单", systemImage: "line.3.horizontal")
                        .labelStyle(.iconOnly)
                        .font(AppVisualStyle.actionFont).imageScale(.medium)
                        .foregroundStyle(appearance.foreground)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: 12))
                .disabled(!canNavigate || drawerPresented)
                .accessibilityHidden(drawerPresented)
                .accessibilityFocused($focusedControl, equals: "library.menu")
                .accessibilityIdentifier("library.sidebar.open")
            }
        }
    }

    @ViewBuilder private var rootContent: some View {
        switch section {
        case .shelf: shelf
        case .explore: explore
        case .settings: settings
        }
    }

    private var floatingTabDock: some View {
        HStack(spacing: 4) {
            ForEach(LibrarySection.allCases, id: \.self) { item in
                let selected = section == item
                Button {
                    guard canNavigate, !drawerPresented else { return }
                    if reduceMotion {
                        section = item
                    } else {
                        withAnimation(ReaderMotion.tabSwitch) {
                            section = item
                        }
                    }
                } label: {
                    Group {
                        if dynamicType.isAccessibilitySize {
                            VStack(spacing: 2) {
                                Image(systemName: item.symbol)
                                    .font(.body.weight(selected ? .semibold : .regular))
                                    .accessibilityHidden(true)
                                Text(item.title)
                                    .font(.caption.weight(selected ? .semibold : .medium))
                                    .lineLimit(1)
                            }
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: item.symbol)
                                    .font(.subheadline.weight(selected ? .semibold : .regular))
                                    .accessibilityHidden(true)
                                Text(item.title)
                                    .font(.subheadline.weight(selected ? .semibold : .medium))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .foregroundStyle(selected ? appearance.accent : appearance.secondary)
                    .padding(.horizontal, dynamicType.isAccessibilitySize ? 8 : 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background {
                        if selected {
                            Capsule()
                                .fill(appearance.accentSoft)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canNavigate || drawerPresented)
                .accessibilityLabel(item.title)
                .accessibilityValue(selected ? "当前" : "未选中")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("library.tab.\(item.rawValue)")
            }
        }
        .padding(5)
        .frame(maxWidth: 420)
        .background(appearance.elevatedSurface, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(appearance.edge.opacity(0.85), lineWidth: 0.85)
                .allowsHitTesting(false)
        }
        .shadow(color: appearance.shadow, radius: 14, x: 0, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.dock")
    }
}

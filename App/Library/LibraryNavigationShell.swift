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

    var body: some View {
        rootContent
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

}

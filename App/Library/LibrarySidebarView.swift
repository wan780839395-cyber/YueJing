import SwiftUI

/// A presentation-only overlay above the NavigationStack, not inside its content area.
/// The parent retains section, route, import and reader ownership and guards.
@MainActor
struct LibrarySidebarView: View {
    let section: LibrarySection
    @Binding var presented: Bool
    let canNavigate: Bool
    let appearance: LibraryAppearance
    let onSection: (LibrarySection) -> Void
    let onInformation: (LibraryInformationPage) -> Void
    @AccessibilityFocusState.Binding var focusedControl: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = min(304, max(0, proxy.size.width - 64))
            ZStack(alignment: .leading) {
                if presented {
                    Button { presented = false } label: {
                        Color.black.opacity(0.24).ignoresSafeArea()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭侧栏")
                    .transition(.opacity)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            header.padding(.bottom, 16)
                            Text("导航").font(.caption).foregroundStyle(appearance.secondary)
                                .padding(.horizontal, 12)
                            ForEach(LibrarySection.allCases, id: \.self) { item in
                                Button { onSection(item) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: item.symbol)
                                            .frame(width: 22).accessibilityHidden(true)
                                        Text(item.title)
                                        Spacer(minLength: 0)
                                    }
                                    .font(AppVisualStyle.actionFont)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .background {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(item == section ? appearance.softSelection : .clear)
                                            .allowsHitTesting(false)
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: 12))
                                .disabled(!canNavigate)
                                .accessibilityValue(item == section ? "当前" : "未选中")
                            }
                            Spacer(minLength: 24)
                            Divider().overlay(appearance.edge).padding(.horizontal, 12)
                            Text("格式与外观请进入设置").font(.footnote)
                                .foregroundStyle(appearance.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                            informationButton("诊断与耗时", symbol: "waveform.path.ecg", page: .diagnostics)
                            informationButton("开源许可", symbol: "doc.text", page: .license)
                        }
                        .frame(maxWidth: .infinity, minHeight: max(0, proxy.size.height - 32), alignment: .topLeading)
                        .padding(16)
                    }
                    .frame(width: width, height: proxy.size.height)
                    .background(appearance.surface.ignoresSafeArea(.container, edges: .vertical))
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(appearance.edge).frame(width: 0.5)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    .accessibilityAction(.escape) { presented = false }
                    .accessibilityIdentifier("library.sidebar")
                    .transition(reduceMotion ? .opacity : .move(edge: .leading))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: presented)
            .transaction { if reduceMotion { $0.animation = nil } }
        }
        .foregroundStyle(appearance.foreground)
        .tint(appearance.accent)
        .allowsHitTesting(presented)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("阅境").font(.headline).accessibilityAddTraits(.isHeader)
                Text("阅读与书库").font(.caption).foregroundStyle(appearance.secondary)
            }
            .padding(.leading, 12).padding(.top, 8)
            Spacer(minLength: 0)
            Button { presented = false } label: {
                Label("关闭菜单", systemImage: "xmark").labelStyle(.iconOnly)
                    .font(AppVisualStyle.actionFont)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(AppControlButtonStyle(foreground: appearance.secondary, cornerRadius: 12))
            .keyboardShortcut(.cancelAction)
            .accessibilityFocused($focusedControl, equals: "library.close")
            .accessibilityIdentifier("library.sidebar.close")
        }
    }

    private func informationButton(_ title: String, symbol: String, page: LibraryInformationPage) -> some View {
        Button { onInformation(page) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 22).accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(AppControlButtonStyle(foreground: appearance.secondary, cornerRadius: 12))
        .disabled(!canNavigate)
    }
}

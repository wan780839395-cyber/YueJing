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
            let width = min(312, max(0, proxy.size.width - 60))
            ZStack(alignment: .leading) {
                if presented {
                    Button { presented = false } label: {
                        Color.black.opacity(appearance.isDarkSurface ? 0.52 : 0.28).ignoresSafeArea()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭侧栏")
                    .transition(.opacity)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            header.padding(.bottom, 12)

                            sectionCaption("书斋导航")
                            VStack(spacing: 4) {
                                ForEach(LibrarySection.allCases, id: \.self) { item in
                                    let selected = item == section
                                    Button { onSection(item) } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: item.symbol)
                                                .font(.body.weight(selected ? .semibold : .regular))
                                                .foregroundStyle(selected ? appearance.accent : appearance.secondary)
                                                .frame(width: 24)
                                                .accessibilityHidden(true)
                                            Text(item.title)
                                                .font(.body.weight(selected ? .semibold : .regular))
                                                .foregroundStyle(selected ? appearance.foreground : appearance.secondary)
                                            Spacer(minLength: 0)
                                            if selected {
                                                Circle()
                                                    .fill(appearance.accent)
                                                    .frame(width: 6, height: 6)
                                                    .accessibilityHidden(true)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .background {
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(selected ? appearance.accentSoft : .clear)
                                                .allowsHitTesting(false)
                                        }
                                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                    .buttonStyle(AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: 14))
                                    .disabled(!canNavigate)
                                    .accessibilityValue(selected ? "当前" : "未选中")
                                }
                            }

                            Spacer(minLength: 24)

                            Rectangle()
                                .fill(appearance.edge.opacity(0.75))
                                .frame(height: 0.5)
                                .padding(.horizontal, 8)
                                .accessibilityHidden(true)

                            sectionCaption("书斋信息")
                                .padding(.top, 4)

                            VStack(spacing: 4) {
                                informationButton("诊断与耗时", symbol: "waveform.path.ecg", page: .diagnostics)
                                informationButton("开源许可", symbol: "doc.text", page: .license)
                            }

                            HStack(spacing: 8) {
                                Circle()
                                    .fill(appearance.accent)
                                    .frame(width: 7, height: 7)
                                    .accessibilityHidden(true)
                                Text("当前外观：\(appearance.appAppearance.title)")
                                    .font(.caption)
                                    .foregroundStyle(appearance.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(appearance.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.top, 6)
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
                    .shadow(color: appearance.shadow, radius: 18, x: 6, y: 0)
                    .accessibilityAction(.escape) { presented = false }
                    .accessibilityIdentifier("library.sidebar")
                    .transition(reduceMotion ? .opacity : .move(edge: .leading))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: presented)
            .transaction { if reduceMotion { $0.animation = nil } }
        }
        .foregroundStyle(appearance.foreground)
        .tint(appearance.accent)
        .allowsHitTesting(presented)
    }

    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(appearance.secondary)
            .padding(.horizontal, 12)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            YueJingBrandMark(tint: appearance.accent, sealTint: appearance.sealAccent, size: 34)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("阅境")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("开卷，自有一境")
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
            }
            Spacer(minLength: 0)
            Button { presented = false } label: {
                Label("关闭菜单", systemImage: "xmark").labelStyle(.iconOnly)
                    .font(AppVisualStyle.actionFont)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(AppControlButtonStyle(foreground: appearance.secondary, surface: appearance.subtleSurface, cornerRadius: 12))
            .keyboardShortcut(.cancelAction)
            .accessibilityFocused($focusedControl, equals: "library.close")
            .accessibilityIdentifier("library.sidebar.close")
        }
        .padding(.top, 6)
    }

    private func informationButton(_ title: String, symbol: String, page: LibraryInformationPage) -> some View {
        Button { onInformation(page) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(appearance.secondary.opacity(0.6))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(AppControlButtonStyle(foreground: appearance.secondary, cornerRadius: 12))
        .disabled(!canNavigate)
    }
}

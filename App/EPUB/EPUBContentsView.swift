import ReaderDomain
import SwiftUI
import UIKit

@MainActor
struct EPUBContentsView: View {
    let items: [EPUBNavigationItem]
    let currentPath: String?
    let currentFragment: String?
    let isActive: @MainActor () -> Bool
    let close: @MainActor () -> Void
    let appearance: ReaderToolAppearance
    let selected: @MainActor (EPUBNavigationItem) -> Void
    @AccessibilityFocusState private var closeFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicType

    static func currentIndex(in items: [EPUBNavigationItem], path currentPath: String?, fragment currentFragment: String?) -> Int? {
        guard let currentPath else { return nil }
        if let currentFragment, !currentFragment.isEmpty,
           let exact = items.firstIndex(where: { $0.path == currentPath && $0.fragment == currentFragment }) {
            return exact
        }
        return items.firstIndex(where: { $0.path == currentPath })
    }

    var body: some View {
        // Resolve once for the whole render, never once per lazy row/header branch.
        let selectedIndex = Self.currentIndex(in: items, path: currentPath, fragment: currentFragment)
        VStack(spacing: 0) {
            ReaderPanelHeader(title: "目录", appearance: appearance) {
                Button {
                    if isActive() { close() }
                } label: {
                    Text("完成").font(ReaderVisualStyle.panelActionFont)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(
                            minWidth: ReaderVisualStyle.panelActionMinimumWidth,
                            minHeight: ReaderVisualStyle.minimumControlHeight
                        )
                }
                .buttonStyle(ReaderCompactButtonStyle(tint: appearance.foreground, role: .primary))
                .disabled(!isActive())
                .accessibilityLabel("关闭目录")
                .accessibilityFocused($closeFocused)
                .accessibilityIdentifier("reader.panel.close")
            }
            summaryHeader(currentIndex: selectedIndex)
            List {
                if items.isEmpty {
                    Text("暂无目录。")
                        .foregroundStyle(appearance.secondary)
                        .listRowBackground(appearance.surface)
                } else {
                    ForEach(items.indices, id: \.self) { index in
                        let item = items[index]
                        let isCurrent = (selectedIndex == index)
                        Button {
                            guard isActive() else { return }
                            selected(item)
                        } label: {
                            ReaderDirectoryChapterRow(
                                title: item.title.isEmpty ? "第 \(index + 1) 节" : item.title,
                                ordinal: index + 1,
                                totalCount: items.count,
                                isCurrent: isCurrent,
                                appearance: appearance
                            )
                            .padding(.leading, CGFloat(min(max(item.depth, 0), 4)) * 12)
                        }
                        .accessibilityIdentifier("reader.chapter.\(index)")
                        .accessibilityValue(isCurrent ? "当前章节" : "")
                        .accessibilityHint("阅读本章")
                        .buttonStyle(.plain)
                        .listRowBackground(isCurrent ? appearance.selection : appearance.surface)
                        .listRowSeparator(.hidden)
                    }
                }
                Section {
                    Text("当前支持 EPUB 目录与章节/锚点跳转；EPUB 书签暂未纳入本批范围。")
                        .font(.caption)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("epub.directory.scopeNote")
                }
                .listRowBackground(appearance.surface)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(appearance.surface)
        }
        .task {
            guard UIAccessibility.isVoiceOverRunning else { return }
            await Task.yield()
            if !Task.isCancelled, isActive() {
                closeFocused = true
            }
        }
        .accessibilityAction(.escape) {
            if isActive() { close() }
        }
    }

    private func summaryHeader(currentIndex: Int?) -> some View {
        VStack(spacing: 8) {
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    totalCountBadge
                    summaryDetailText(currentIndex: currentIndex)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        totalCountBadge
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 12)
                        summaryDetailText(currentIndex: currentIndex)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        totalCountBadge
                        summaryDetailText(currentIndex: currentIndex)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Rectangle()
                .fill(appearance.edge)
                .frame(height: ReaderVisualStyle.panelDividerHeight)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, ReaderVisualStyle.panelHorizontalInset)
        .padding(.top, 8)
        .background(appearance.surface)
    }

    private var totalCountBadge: some View {
        Text("共 \(items.count) 章")
            .font(.system(.subheadline, design: .serif).weight(.medium).monospacedDigit())
            .foregroundStyle(appearance.foreground)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("总章节数，共 \(items.count) 章")
            .accessibilityIdentifier("reader.directory.total")
    }

    private func summaryDetailText(currentIndex: Int?) -> some View {
        let text: String
        if let currentIndex {
            text = "当前第 \(currentIndex + 1) 章 · 共 \(items.count) 章"
        } else if !items.isEmpty {
            text = "共 \(items.count) 章"
        } else {
            text = "暂无章节"
        }
        return Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(appearance.foreground.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
    }
}

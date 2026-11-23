import ReaderDomain
import SwiftUI
import TXTCore
import UIKit

@MainActor
struct ReaderDirectorySheet: View {
    @ObservedObject var model: ReaderDirectoryViewModel
    let presentationID: UUID
    let isActive: @MainActor () -> Bool
    let currentAnchor: @MainActor () -> ReadingAnchor?
    let close: @MainActor () -> Void
    let appearance: ReaderToolAppearance
    let selected: @MainActor (TXTChapter) -> Void
    @AccessibilityFocusState private var focusedChapterID: String?
    @AccessibilityFocusState private var closeFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        VStack(spacing: 0) {
            ReaderPanelHeader(title: "目录", appearance: appearance) {
                Button { if active { close() } } label: {
                    Text("完成").font(ReaderVisualStyle.panelActionFont.weight(.semibold))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(minWidth: ReaderVisualStyle.panelActionMinimumWidth,
                               minHeight: ReaderVisualStyle.minimumControlHeight)
                }
                .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, role: .primary))
                .accessibilityLabel("关闭目录")
                .accessibilityFocused($closeFocused)
                .accessibilityIdentifier("reader.panel.close")
            }
            if let page = model.state.page, page.total > 0 {
                directorySummaryHeader(page: page)
            }
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    List {
                        if let message = model.state.message {
                            Section {
                                Text(message).fixedSize(horizontal: false, vertical: true)
                                Button("重试目录") { if active { model.retry() } }.frame(minHeight: 44)
                            }
                            .listRowBackground(appearance.surface)
                        }
                        if let page = model.state.page {
                            if page.chapters.isEmpty {
                                Text("暂无目录。")
                                    .foregroundStyle(appearance.secondary)
                                    .listRowBackground(appearance.surface)
                            }
                            ForEach(Array(page.chapters.enumerated()), id: \.element.id) { item in
                                let current = page.currentIndex == page.start + item.offset
                                let owner = model.ownerRevision
                                Button {
                                    guard active, model.ownerRevision == owner else { return }
                                    selected(item.element)
                                } label: {
                                    ReaderDirectoryChapterRow(title: item.element.title ?? "正文开头",
                                        ordinal: page.start + item.offset + 1, totalCount: page.total,
                                        isCurrent: current, appearance: appearance)
                                }
                                .id(item.element.id)
                                .accessibilityIdentifier("reader.chapter.\(page.start + item.offset)")
                                .accessibilityFocused($focusedChapterID, equals: item.element.id)
                                .accessibilityValue(current ? "当前章节" : "")
                                .accessibilityHint("阅读本章")
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                                .listRowBackground(appearance.surface)
                                .listRowSeparator(.hidden)
                            }
                        } else if !model.state.loading, model.state.message == nil {
                            Text("正文显示后会定位当前章节。")
                                .foregroundStyle(appearance.secondary)
                                .listRowBackground(appearance.surface)
                        }
                        if model.state.loading && (model.state.page?.chapters.isEmpty ?? true) {
                            HStack(spacing: 10) {
                                ProgressView().tint(appearance.accent)
                                Text("正在读取目录…").foregroundStyle(appearance.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .listRowBackground(appearance.surface)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(appearance.surface)
                    .task(id: model.state.reveal?.id) {
                        guard let reveal = model.state.reveal else { return }
                        await Task.yield()
                        guard !Task.isCancelled, active, model.state.reveal == reveal else { return }
                        proxy.scrollTo(reveal.chapterID, anchor: .center)
                        if UIAccessibility.isVoiceOverRunning { closeFocused = false; focusedChapterID = reveal.chapterID }
                    }
                    if let page = model.state.page, !page.chapters.isEmpty {
                        ReaderDirectoryFooter(rangeLabel: page.rangeLabel,
                            loading: model.state.loading,
                            previousDisabled: page.start == 0 || model.state.loading,
                            nextDisabled: page.start + page.chapters.count >= page.total || model.state.loading,
                            appearance: appearance,
                            requestCurrent: { if active { model.requestCurrent() } },
                            loadPrevious: { if active { model.loadPage(max(0, page.start - ReadingDirectory.pageSize)) } },
                            loadNext: { if active { model.loadPage(page.start + ReadingDirectory.pageSize) } })
                            .disabled(!active)
                    }
                }
            }
            .task(id: model.ownerRevision) {
                guard isActive(), !Task.isCancelled else { return }
                model.present(around: currentAnchor(), presentation: presentationID)
            }
            .task(id: model.state.presentationID) {
                guard UIAccessibility.isVoiceOverRunning, active else { return }
                await Task.yield()
                if !Task.isCancelled, active, model.state.reveal == nil { closeFocused = true }
            }
            .onDisappear { model.dismiss(presentation: presentationID); focusedChapterID = nil; closeFocused = false }
        }
        .accessibilityAction(.escape) { if active { close() } }
    }

    private var active: Bool { isActive() && model.state.ownsPresentation(presentationID) }

    private func directorySummaryHeader(page: ReadingDirectoryPage) -> some View {
        VStack(spacing: 8) {
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    totalCountBadge(total: page.total)
                    summaryDetailText(page: page)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        totalCountBadge(total: page.total)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 12)
                        summaryDetailText(page: page)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        totalCountBadge(total: page.total)
                        summaryDetailText(page: page)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let currentIndex = page.currentIndex, page.total > 0 {
                let fraction = min(1, max(0.02, Double(currentIndex + 1) / Double(page.total)))
                GeometryReader { bar in
                    ZStack(alignment: .leading) {
                        Capsule().fill(appearance.edge.opacity(0.45))
                        Capsule()
                            .fill(appearance.accent)
                            .frame(width: max(8, bar.size.width * fraction))
                    }
                }
                .frame(height: 3)
                .padding(.top, 2)
                .accessibilityHidden(true)
            }
            Rectangle()
                .fill(appearance.edge.opacity(0.6))
                .frame(height: ReaderVisualStyle.panelDividerHeight)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, ReaderVisualStyle.panelHorizontalInset)
        .padding(.top, 10)
        .background(appearance.surface)
    }

    private func totalCountBadge(total: Int) -> some View {
        Text("共 \(total) 章")
            .font(.system(.subheadline, design: .serif).weight(.semibold).monospacedDigit())
            .foregroundStyle(appearance.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 3.5)
            .background(appearance.accentSoft, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("总章节数，共 \(total) 章")
            .accessibilityIdentifier("reader.directory.total")
    }

    private func summaryDetailText(page: ReadingDirectoryPage) -> some View {
        let text: String
        if let currentIndex = page.currentIndex {
            text = "当前第 \(currentIndex + 1) 章 · 本组 \(page.start + 1)–\(page.start + page.chapters.count)"
        } else if !page.chapters.isEmpty {
            text = "本组第 \(page.start + 1)–\(page.start + page.chapters.count) 章"
        } else {
            text = "暂无章节"
        }
        return Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(appearance.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

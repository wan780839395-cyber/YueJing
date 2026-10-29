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
    var body: some View {
        VStack(spacing: 0) {
            ReaderPanelHeader(title: "目录", appearance: appearance) {
                Button { if active { close() } } label: {
                    Text("完成").font(ReaderVisualStyle.panelActionFont)
                        .frame(minWidth: ReaderVisualStyle.panelActionMinimumWidth,
                               minHeight: ReaderVisualStyle.minimumControlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent))
                .accessibilityLabel("关闭目录")
                .accessibilityFocused($closeFocused)
                .accessibilityIdentifier("reader.panel.close")
            }
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    List {
                        if let message = model.state.message {
                            Section {
                                Text(message).fixedSize(horizontal: false, vertical: true)
                                Button("重试目录") { if active { model.retry() } }.frame(minHeight: 44)
                            }
                        }
                        if let page = model.state.page {
                            if page.chapters.isEmpty { Text("暂无目录。") }
                            ForEach(Array(page.chapters.enumerated()), id: \.element.id) { item in
                                let current = page.currentIndex == page.start + item.offset
                                let owner = model.ownerRevision
                                Button {
                                    guard active, model.ownerRevision == owner else { return }
                                    selected(item.element)
                                } label: {
                                    ReaderDirectoryChapterRow(title: item.element.title ?? "正文开头",
                                        ordinal: page.start + item.offset + 1, isCurrent: current, appearance: appearance)
                                }
                                .id(item.element.id)
                                .accessibilityIdentifier("reader.chapter.\(page.start + item.offset)")
                                .accessibilityFocused($focusedChapterID, equals: item.element.id)
                                .accessibilityValue(current ? "当前章节" : "")
                                .accessibilityHint("阅读本章")
                                .listRowBackground(current ? appearance.accent.opacity(0.08) : appearance.surface)
                                .listRowSeparatorTint(appearance.edge)
                            }
                        } else if !model.state.loading, model.state.message == nil {
                            Text("正文显示后会定位当前章节。")
                        }
                        if model.state.loading {
                            HStack { ProgressView(); Text("正在读取目录…") }.accessibilityElement(children: .combine)
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
}

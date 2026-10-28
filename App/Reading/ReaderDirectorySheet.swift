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
            HStack {
                Text("目录").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { if active { close() } } label: { Label("关闭目录", systemImage: "xmark") }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    .accessibilityFocused($closeFocused)
                    .accessibilityIdentifier("reader.panel.close")
            }.padding(.horizontal, 16)
            ScrollViewReader { proxy in
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
                            HStack(alignment: .top, spacing: 12) {
                                Text(item.element.title ?? "正文开头")
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                if current { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }.frame(minHeight: 44, alignment: .leading)
                        }
                        .id(item.element.id)
                        .accessibilityIdentifier("reader.chapter.\(page.start + item.offset)")
                        .accessibilityFocused($focusedChapterID, equals: item.element.id)
                        .accessibilityValue(current ? "当前章节" : "")
                        .accessibilityHint("阅读本章")
                        .listRowBackground(current ? appearance.accent.opacity(0.08) : appearance.surface)
                    }
                } else if !model.state.loading, model.state.message == nil {
                    Text("正文显示后会定位当前章节。")
                }
                if model.state.loading {
                    HStack { ProgressView(); Text("正在读取目录…") }.accessibilityElement(children: .combine)
                }
                if let page = model.state.page, !page.chapters.isEmpty {
                    Section {
                        Button("回到当前章节") { if active { model.requestCurrent() } }.frame(minHeight: 44)
                        Text(page.rangeLabel).font(.footnote).accessibilityLabel("目录范围，\(page.rangeLabel)")
                        HStack {
                            Button("上一组") { if active { model.loadPage(max(0, page.start - ReadingDirectory.pageSize)) } }
                                .disabled(page.start == 0 || model.state.loading)
                            Spacer()
                            Button("下一组") { if active { model.loadPage(page.start + ReadingDirectory.pageSize) } }
                                .disabled(page.start + page.chapters.count >= page.total || model.state.loading)
                        }.frame(minHeight: 44)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .task(id: model.state.reveal?.id) {
                guard let reveal = model.state.reveal else { return }
                await Task.yield()
                guard !Task.isCancelled, active, model.state.reveal == reveal else { return }
                proxy.scrollTo(reveal.chapterID, anchor: .center)
                if UIAccessibility.isVoiceOverRunning { closeFocused = false; focusedChapterID = reveal.chapterID }
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

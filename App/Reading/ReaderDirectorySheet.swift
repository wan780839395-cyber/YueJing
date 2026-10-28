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
    let selected: @MainActor (TXTChapter) -> Void
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var focusedChapterID: String?
    var body: some View {
        NavigationStack {
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
                        Button {
                            guard active else { return }
                            selected(item.element); dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text(item.element.title ?? "正文开头")
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                if current { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }.frame(minHeight: 44, alignment: .leading)
                        }
                        .id(item.element.id)
                        .accessibilityFocused($focusedChapterID, equals: item.element.id)
                        .accessibilityValue(current ? "当前章节" : "")
                        .accessibilityHint("阅读本章")
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
            .task(id: model.state.reveal?.id) {
                guard let reveal = model.state.reveal else { return }
                await Task.yield()
                guard !Task.isCancelled, active, model.state.reveal == reveal else { return }
                proxy.scrollTo(reveal.chapterID, anchor: .center)
                if UIAccessibility.isVoiceOverRunning { focusedChapterID = reveal.chapterID }
            }
            }
            .navigationTitle("目录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { if active { dismiss() } }.frame(minHeight: 44) } }
            .task(id: model.ownerRevision) {
                guard isActive(), !Task.isCancelled else { return }
                model.present(around: currentAnchor(), presentation: presentationID)
            }
            .onDisappear { model.dismiss(presentation: presentationID); focusedChapterID = nil }
        }
    }
    private var active: Bool { isActive() && model.state.ownsPresentation(presentationID) }
}

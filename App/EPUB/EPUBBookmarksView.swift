import ReaderDomain
import SwiftUI
import UIKit

@MainActor
struct EPUBBookmarkActions {
    let list: @MainActor () async throws -> [EPUBBookmark]
    let add: @MainActor () async throws -> Bool
    let remove: @MainActor (EPUBBookmark) async throws -> Void
    let jump: @MainActor (EPUBBookmark) async throws -> Void
}

@MainActor
struct EPUBBookmarksView: View {
    private enum Activity: Equatable {
        case loading
        case adding
        case deleting
        case jumping

        var statusText: String {
            switch self {
            case .loading: return "正在读取书签…"
            case .adding: return "正在添加书签…"
            case .deleting: return "正在删除书签…"
            case .jumping: return "正在跳转至书签位置…"
            }
        }
    }

    let sessionID: UUID
    let active: Bool
    let isPanelActive: @MainActor () -> Bool
    let actions: EPUBBookmarkActions
    let appearance: ReaderToolAppearance
    @Binding var isBusy: Bool

    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.scenePhase) private var scenePhase

    @State private var bookmarks: [EPUBBookmark] = []
    @State private var loaded = false
    @State private var activity: Activity?
    @State private var notice: String?
    @State private var errorMessage: String?
    @State private var pendingDeletion: EPUBBookmark?
    @State private var mounted = false
    @State private var generation = UUID()
    @State private var activeTask: Task<Void, Never>?

    private var canInteract: Bool {
        mounted && active && scenePhase == .active && isPanelActive()
    }

    private var isRunning: Bool {
        activity != nil
    }

    var body: some View {
        List {
            Section {
                addBookmarkButton
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)

                if let notice {
                    Text(notice)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(appearance.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("epub.bookmarks.notice")
                }

                if let errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(appearance.sealAccent)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("epub.bookmarks.error")

                        Button {
                            loadBookmarks()
                        } label: {
                            Label("重试读取书签", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .frame(minHeight: ReaderVisualStyle.minimumControlHeight)
                        }
                        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, role: .primary, cornerRadius: 12))
                        .disabled(!canInteract || isRunning)
                        .accessibilityIdentifier("epub.bookmarks.retry")
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 6, trailing: 20))
                    .listRowSeparator(.hidden)
                }

                if let activity {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(appearance.accent)
                        Text(activity.statusText)
                            .font(.footnote)
                            .foregroundStyle(appearance.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("epub.bookmarks.loading")
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 6, trailing: 20))
                    .listRowSeparator(.hidden)
                }
            }
            .listRowBackground(appearance.surface)

            Section {
                if loaded && bookmarks.isEmpty && errorMessage == nil && !isRunning {
                    emptyStateCard
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(appearance.surface)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(Array(bookmarks.enumerated()), id: \.element.id) { entry in
                        bookmarkRow(entry.element, ordinal: entry.offset + 1)
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                            .listRowBackground(appearance.surface)
                            .listRowSeparator(.hidden)
                    }
                }
            }

            if !bookmarks.isEmpty {
                Section {
                    Text("共 \(bookmarks.count) 条书签")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("epub.bookmarks.count")
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 16, trailing: 20))
                .listRowBackground(appearance.surface)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(appearance.surface)
        .accessibilityIdentifier("epub.bookmarks.list")
        .confirmationDialog(
            "删除这条书签？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let bookmark = pendingDeletion {
                Button("删除书签", role: .destructive) {
                    pendingDeletion = nil
                    deleteBookmark(bookmark)
                }
                .accessibilityIdentifier("epub.bookmarks.confirmDelete")
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("不会删除书籍或阅读进度。")
        }
        .onAppear {
            mounted = true
            if canInteract && !loaded && !isRunning {
                loadBookmarks()
            }
        }
        .onChange(of: active) { available in
            if available {
                if canInteract && !loaded && !isRunning {
                    loadBookmarks()
                }
            } else {
                cancelInFlightWork()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                cancelInFlightWork()
            } else if canInteract && !loaded && !isRunning {
                loadBookmarks()
            }
        }
        .onChange(of: sessionID) { _ in
            resetForNewSession()
        }
        .onChange(of: notice) { value in
            guard canInteract, UIAccessibility.isVoiceOverRunning, let value else { return }
            UIAccessibility.post(notification: .announcement, argument: value)
        }
        .onChange(of: errorMessage) { value in
            guard canInteract, UIAccessibility.isVoiceOverRunning, let value else { return }
            UIAccessibility.post(notification: .announcement, argument: value)
        }
        .onDisappear {
            mounted = false
            cancelInFlightWork()
        }
    }

    private var addBookmarkButton: some View {
        Button {
            addCurrentBookmark()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(appearance.sealAccent.opacity(0.14))
                    Image(systemName: "bookmark.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appearance.sealAccent)
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

                Text("添加当前阅读位置")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(appearance.foreground)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(appearance.sealAccent)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(appearance.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(appearance.sealAccent.opacity(0.32), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canInteract || isRunning)
        .opacity((!canInteract || isRunning) ? 0.5 : 1)
        .accessibilityHint("将当前阅读位置保存为书签")
        .accessibilityIdentifier("epub.bookmarks.add")
    }

    private var emptyStateCard: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(appearance.sealAccent.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "bookmark.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(appearance.sealAccent)
            }
            .accessibilityHidden(true)

            Text("尚无书签。点击上方「添加当前阅读位置」，即可记录并随时回到此处。")
                .font(.subheadline)
                .foregroundStyle(appearance.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("epub.bookmarks.empty")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(appearance.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.65), lineWidth: 0.65)
                .allowsHitTesting(false)
        }
    }

    private func bookmarkRow(_ bookmark: EPUBBookmark, ordinal: Int) -> some View {
        let trimmed = bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "书签 \(ordinal)" : trimmed
        let timestamp = bookmark.createdAt.formatted(date: .abbreviated, time: .shortened)

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                jumpToBookmark(bookmark)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(appearance.sealAccent)
                        .frame(width: 3, height: 34)
                        .padding(.top, 2)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(.body, design: .serif).weight(.medium))
                            .foregroundStyle(appearance.foreground)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("书签 \(ordinal) · \(timestamp)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(appearance.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appearance.secondary.opacity(0.65))
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: ReaderVisualStyle.minimumControlHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canInteract || isRunning)
            .opacity((!canInteract || isRunning) ? 0.5 : 1)
            .accessibilityLabel("\(title)，书签 \(ordinal)")
            .accessibilityHint("跳转到此书签位置")
            .accessibilityIdentifier("epub.bookmark.\(bookmark.id)")

            Group {
                if dynamicType.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        deleteButton(for: bookmark, ordinal: ordinal, title: title)
                    }
                } else {
                    HStack(spacing: 10) {
                        deleteButton(for: bookmark, ordinal: ordinal, title: title)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(14)
        .background(appearance.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.7), lineWidth: 0.65)
                .allowsHitTesting(false)
        }
        .accessibilityAction(named: Text("删除书签")) {
            guard canInteract, !isRunning else { return }
            pendingDeletion = bookmark
        }
    }

    private func deleteButton(for bookmark: EPUBBookmark, ordinal: Int, title: String) -> some View {
        Button(role: .destructive) {
            guard canInteract, !isRunning else { return }
            pendingDeletion = bookmark
        } label: {
            Label("删除", systemImage: "trash")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12)
                .frame(minHeight: ReaderVisualStyle.minimumControlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(appearance.sealAccent)
        .background(appearance.sealAccent.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .disabled(!canInteract || isRunning)
        .opacity((!canInteract || isRunning) ? 0.45 : 1)
        .accessibilityLabel("删除书签 \(ordinal)，\(title)")
        .accessibilityIdentifier("epub.bookmark.delete.\(bookmark.id)")
    }

    private func isGuardSatisfied(expectedGeneration: UUID) -> Bool {
        !Task.isCancelled && mounted && isPanelActive() && generation == expectedGeneration
    }

    private func beginActivity(_ kind: Activity) -> UUID? {
        guard canInteract, !isRunning else { return nil }
        let token = UUID()
        generation = token
        activity = kind
        isBusy = true
        notice = nil
        errorMessage = nil
        return token
    }

    private func finishActivity(expectedGeneration: UUID) {
        guard mounted, isPanelActive(), generation == expectedGeneration else { return }
        activity = nil
        isBusy = false
        activeTask = nil
    }

    private func cancelInFlightWork() {
        generation = UUID()
        activeTask?.cancel()
        activeTask = nil
        pendingDeletion = nil
        activity = nil
        isBusy = false
    }

    private func resetForNewSession() {
        cancelInFlightWork()
        bookmarks = []
        loaded = false
        notice = nil
        errorMessage = nil
        if canInteract {
            loadBookmarks()
        }
    }

    private func loadBookmarks() {
        guard let token = beginActivity(.loading) else { return }
        let listAction = actions.list
        activeTask = Task { @MainActor in
            defer { finishActivity(expectedGeneration: token) }
            do {
                let items = try await listAction()
                guard isGuardSatisfied(expectedGeneration: token) else { return }
                bookmarks = items
                loaded = true
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard isGuardSatisfied(expectedGeneration: token) else { return }
                errorMessage = Self.errorMessage(for: error, during: .loading)
            }
        }
    }

    private func addCurrentBookmark() {
        guard let token = beginActivity(.adding) else { return }
        let addAction = actions.add
        let listAction = actions.list
        activeTask = Task { @MainActor in
            defer { finishActivity(expectedGeneration: token) }
            do {
                let inserted = try await addAction()
                guard isGuardSatisfied(expectedGeneration: token) else { return }
                notice = inserted ? "已添加当前阅读位置。" : "当前位置已有书签。"
                do {
                    let items = try await listAction()
                    guard isGuardSatisfied(expectedGeneration: token) else { return }
                    bookmarks = items
                    loaded = true
                    errorMessage = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard isGuardSatisfied(expectedGeneration: token) else { return }
                    errorMessage = "书签已更新，但列表刷新失败，请重试。"
                }
            } catch is CancellationError {
                return
            } catch {
                guard isGuardSatisfied(expectedGeneration: token) else { return }
                errorMessage = Self.errorMessage(for: error, during: .adding)
            }
        }
    }

    private func deleteBookmark(_ bookmark: EPUBBookmark) {
        guard let token = beginActivity(.deleting) else { return }
        let removeAction = actions.remove
        let listAction = actions.list
        activeTask = Task { @MainActor in
            defer { finishActivity(expectedGeneration: token) }
            do {
                try await removeAction(bookmark)
                guard isGuardSatisfied(expectedGeneration: token) else { return }
                notice = "已删除书签。"
                do {
                    let items = try await listAction()
                    guard isGuardSatisfied(expectedGeneration: token) else { return }
                    bookmarks = items
                    loaded = true
                    errorMessage = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard isGuardSatisfied(expectedGeneration: token) else { return }
                    bookmarks.removeAll { $0.id == bookmark.id }
                    errorMessage = "书签已删除，但列表刷新失败，请重试。"
                }
            } catch is CancellationError {
                return
            } catch {
                guard isGuardSatisfied(expectedGeneration: token) else { return }
                errorMessage = Self.errorMessage(for: error, during: .deleting)
            }
        }
    }

    private func jumpToBookmark(_ bookmark: EPUBBookmark) {
        guard let token = beginActivity(.jumping) else { return }
        let jumpAction = actions.jump
        activeTask = Task { @MainActor in
            defer { finishActivity(expectedGeneration: token) }
            do {
                try await jumpAction(bookmark)
                // Successful jump closes the sheet via the caller; never mutate closed state.
                guard isGuardSatisfied(expectedGeneration: token) else { return }
            } catch is CancellationError {
                return
            } catch {
                guard isGuardSatisfied(expectedGeneration: token) else { return }
                errorMessage = Self.errorMessage(for: error, during: .jumping)
            }
        }
    }

    private static func errorMessage(for error: Error, during activity: Activity) -> String {
        if let epubError = error as? EPUBError {
            switch epubError {
            case .staleSession:
                return "阅读会话已变化，请关闭面板后重试。"
            case .invalidPosition:
                switch activity {
                case .adding:
                    return "当前页面位置尚未稳定，请稍后再添加书签。"
                case .jumping:
                    return "该书签位置与当前章节版本不匹配，无法跳转。"
                case .loading, .deleting:
                    return "阅读位置暂不可用，请稍后重试。"
                }
            case .limitExceeded:
                return "书签数量已达上限。"
            default:
                return epubError.errorDescription ?? fallbackMessage(for: activity)
            }
        }
        return fallbackMessage(for: activity)
    }

    private static func fallbackMessage(for activity: Activity) -> String {
        switch activity {
        case .loading: return "读取书签失败，请稍后重试。"
        case .adding: return "添加书签失败，请稍后重试。"
        case .deleting: return "删除书签失败，请稍后重试。"
        case .jumping: return "跳转书签失败，请稍后重试。"
        }
    }
}

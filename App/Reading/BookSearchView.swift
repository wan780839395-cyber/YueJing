import ReaderDomain
import SwiftUI
import UIKit

@MainActor
struct BookSearchActions {
    let search: @MainActor (String) async throws -> BookSearchResults
    let jump: @MainActor (BookSearchHit) async throws -> Void
}

@MainActor
struct BookSearchView: View {
    static let maxQueryUTF16Length = 128
    static let resultCap = 100

    private enum Activity: Equatable {
        case searching
        case jumping

        var statusText: String {
            switch self {
            case .searching: return "正在搜索正文…"
            case .jumping: return "正在跳转至匹配位置…"
            }
        }
    }

    private enum FailureKind: Equatable {
        case search(query: String)
        case jump(hit: BookSearchHit)

        var retryTitle: String {
            switch self {
            case .search: return "重试搜索"
            case .jump: return "重试跳转"
            }
        }
    }

    let sessionID: UUID
    let active: Bool
    let isPanelActive: @MainActor () -> Bool
    let actions: BookSearchActions
    let appearance: ReaderToolAppearance
    var close: (@MainActor () -> Void)? = nil

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicType
    @AccessibilityFocusState private var closeFocused: Bool
    @FocusState private var queryFocused: Bool

    @State private var query = ""
    @State private var results: BookSearchResults?
    @State private var activity: Activity?
    @State private var errorMessage: String?
    @State private var failure: FailureKind?
    @State private var validationMessage: String?
    @State private var mounted = false
    @State private var generation = UUID()
    @State private var activeTask: Task<Void, Never>?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedUTF16Count: Int {
        trimmedQuery.utf16.count
    }

    private var isQueryTooLong: Bool {
        trimmedUTF16Count > Self.maxQueryUTF16Length
    }

    private var canInteract: Bool {
        mounted && active && scenePhase == .active && isPanelActive()
    }

    private var isRunning: Bool {
        activity != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let close {
                ReaderPanelHeader(title: "搜正文", appearance: appearance) {
                    Button {
                        guard isPanelActive() else { return }
                        cancelInFlightWork()
                        queryFocused = false
                        close()
                    } label: {
                        Text("完成")
                            .font(ReaderVisualStyle.panelActionFont.weight(.semibold))
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(
                                minWidth: ReaderVisualStyle.panelActionMinimumWidth,
                                minHeight: ReaderVisualStyle.minimumControlHeight
                            )
                    }
                    .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, role: .primary))
                    .accessibilityLabel("关闭搜正文")
                    .accessibilityFocused($closeFocused)
                    .accessibilityIdentifier("reader.panel.close")
                }
            }

            searchControls

            List {
                if activity != nil || errorMessage != nil || (results.map { !$0.hits.isEmpty } ?? false) {
                    Section {
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
                            .accessibilityIdentifier("book.search.loading")
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 6, trailing: 20))
                            .listRowSeparator(.hidden)
                        }

                        if let errorMessage {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(appearance.sealAccent)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("book.search.error")

                                if let failure {
                                    Button {
                                        retryFailedOperation()
                                    } label: {
                                        Label(failure.retryTitle, systemImage: "arrow.clockwise")
                                            .font(.subheadline.weight(.medium))
                                            .padding(.horizontal, 12)
                                            .frame(minHeight: ReaderVisualStyle.minimumControlHeight)
                                    }
                                    .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, role: .primary, cornerRadius: 12))
                                    .disabled(!canInteract || isRunning)
                                    .accessibilityIdentifier("book.search.retry")
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 6, trailing: 20))
                            .listRowSeparator(.hidden)
                        }

                        if let results, !results.hits.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(results.hasMore
                                    ? "已显示前 \(results.hits.count) 条匹配"
                                    : "共找到 \(results.hits.count) 条匹配")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(appearance.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("book.search.count")

                                if results.hasMore {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "info.circle")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(appearance.accent)
                                            .padding(.top, 1)
                                            .accessibilityHidden(true)
                                        Text("匹配结果超过 \(Self.resultCap) 条上限，仅显示前 \(results.hits.count) 条，请缩小关键词范围。")
                                            .font(.footnote)
                                            .foregroundStyle(appearance.accent)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(appearance.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("book.search.limit")
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listRowBackground(appearance.surface)
                }

                Section {
                    if let results {
                        if results.hits.isEmpty && !isRunning {
                            stateCard(
                                symbol: "magnifyingglass",
                                text: "未找到匹配的正文内容，请尝试其他关键词。",
                                identifier: "book.search.noMatches"
                            )
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(appearance.surface)
                            .listRowSeparator(.hidden)
                        } else {
                            ForEach(Array(results.hits.enumerated()), id: \.element.id) { entry in
                                hitRow(entry.element, ordinal: entry.offset + 1)
                                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                    .listRowBackground(appearance.surface)
                                    .listRowSeparator(.hidden)
                            }
                        }
                    } else if !isRunning && errorMessage == nil {
                        stateCard(
                            symbol: "text.magnifyingglass",
                            text: "输入关键词后点按「搜索」，在当前书籍正文中查找匹配位置。",
                            identifier: "book.search.empty"
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(appearance.surface)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(appearance.surface)
            .accessibilityIdentifier("book.search.list")
        }
        .background(appearance.surface)
        .onAppear {
            mounted = true
        }
        .onChange(of: active) { available in
            if !available {
                queryFocused = false
                cancelInFlightWork()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                queryFocused = false
                cancelInFlightWork()
            }
        }
        .onChange(of: sessionID) { _ in
            resetForNewSession()
        }
        .onChange(of: errorMessage) { value in
            guard canInteract, UIAccessibility.isVoiceOverRunning, let value else { return }
            UIAccessibility.post(notification: .announcement, argument: value)
        }
        .task(id: sessionID) {
            guard close != nil, UIAccessibility.isVoiceOverRunning else { return }
            await Task.yield()
            if !Task.isCancelled, canInteract {
                closeFocused = true
            }
        }
        .onDisappear {
            mounted = false
            queryFocused = false
            closeFocused = false
            cancelInFlightWork()
        }
        .accessibilityAction(.escape) {
            guard let close, isPanelActive() else { return }
            cancelInFlightWork()
            queryFocused = false
            close()
        }
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if dynamicType.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        searchInputField
                        submitButton(fullWidth: true)
                    }
                } else {
                    HStack(spacing: 8) {
                        searchInputField
                        submitButton(fullWidth: false)
                    }
                }
            }

            if isQueryTooLong {
                Text("关键词最多 \(Self.maxQueryUTF16Length) 个 UTF-16 字符（当前 \(trimmedUTF16Count)）。")
                    .font(.footnote)
                    .foregroundStyle(appearance.sealAccent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("book.search.tooLong")
            } else if let validationMessage {
                Text(validationMessage)
                    .font(.footnote)
                    .foregroundStyle(appearance.sealAccent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("book.search.validation")
            }
        }
        .foregroundStyle(appearance.foreground)
        .padding(.horizontal, ReaderVisualStyle.panelHorizontalInset)
        .padding(.vertical, 8)
        .background(appearance.surface)
        .disabled(!canInteract)
    }

    private var searchInputField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(appearance.accent)
                .padding(.leading, 12)
                .accessibilityHidden(true)

            TextField("搜索本书正文", text: Binding(
                get: { query },
                set: { handleQueryEdit($0) }
            ))
            .focused($queryFocused)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            .onSubmit { submitSearch() }
            .padding(.trailing, query.isEmpty ? 12 : 0)
            .accessibilityIdentifier("book.search.query")

            if !query.isEmpty {
                Button {
                    guard canInteract else { return }
                    clearQueryAndState()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(minWidth: ReaderVisualStyle.minimumControlHeight, minHeight: ReaderVisualStyle.minimumControlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ReaderCompactButtonStyle(tint: appearance.secondary))
                .accessibilityLabel("清空搜索词")
                .accessibilityIdentifier("book.search.clear")
            }
        }
        .frame(minHeight: ReaderVisualStyle.minimumControlHeight)
        .background(appearance.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    (isQueryTooLong ? appearance.sealAccent : appearance.edge).opacity(0.8),
                    lineWidth: 0.7
                )
                .allowsHitTesting(false)
        }
    }

    private func submitButton(fullWidth: Bool) -> some View {
        Button {
            submitSearch()
        } label: {
            Text("搜索")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: !fullWidth, vertical: false)
                .padding(.horizontal, 14)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: ReaderVisualStyle.minimumControlHeight)
        }
        .buttonStyle(ReaderCompactButtonStyle(tint: appearance.accent, role: .primary, cornerRadius: 14))
        .disabled(!canInteract || trimmedQuery.isEmpty || isQueryTooLong || isRunning)
        .accessibilityIdentifier("book.search.submit")
    }

    private func stateCard(symbol: String, text: String, identifier: String) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(appearance.accentSoft)
                    .frame(width: 44, height: 44)
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(appearance.accent)
            }
            .accessibilityHidden(true)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(appearance.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
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

    private func hitRow(_ hit: BookSearchHit, ordinal: Int) -> some View {
        let trimmedTitle = hit.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let chapterTitle = trimmedTitle.isEmpty ? "正文" : trimmedTitle

        return Button {
            jump(to: hit)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(appearance.accent)
                    .frame(width: 3, height: 34)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(chapterTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(appearance.accent)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Text("#\(ordinal)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(appearance.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Text(hit.snippet)
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(appearance.foreground)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.secondary.opacity(0.65))
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: ReaderVisualStyle.minimumControlHeight, alignment: .leading)
            .background(appearance.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(appearance.edge.opacity(0.7), lineWidth: 0.65)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canInteract || isRunning)
        .opacity((!canInteract || isRunning) ? 0.5 : 1)
        .accessibilityLabel("\(chapterTitle)，第 \(ordinal) 条匹配，\(hit.snippet)")
        .accessibilityHint("跳转到正文中的此处位置")
        .accessibilityIdentifier("book.search.hit.\(ordinal - 1)")
    }

    private func handleQueryEdit(_ newValue: String) {
        guard canInteract, newValue != query else { return }
        query = newValue
        resetSearchState()
    }

    private func clearQueryAndState() {
        query = ""
        resetSearchState()
    }

    private func resetSearchState() {
        cancelInFlightWork()
        results = nil
        errorMessage = nil
        failure = nil
        validationMessage = nil
    }

    private func submitSearch() {
        guard canInteract, !isRunning else { return }
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else {
            cancelInFlightWork()
            validationMessage = "请输入关键词后再搜索。"
            return
        }
        guard trimmed.utf16.count <= Self.maxQueryUTF16Length else {
            cancelInFlightWork()
            validationMessage = nil
            return
        }
        queryFocused = false
        runSearch(for: trimmed)
    }

    private func runSearch(for trimmed: String) {
        guard canInteract else { return }
        cancelInFlightWork()
        let token = UUID()
        generation = token
        activity = .searching
        results = nil
        errorMessage = nil
        failure = nil
        validationMessage = nil

        let searchAction = actions.search
        activeTask = Task { @MainActor in
            defer { finishActivity(expectedGeneration: token) }
            do {
                let fetched = try await searchAction(trimmed)
                guard isGuardSatisfied(expectedGeneration: token) else { return }
                results = fetched
                errorMessage = nil
                failure = nil
            } catch is CancellationError {
                return
            } catch {
                guard isGuardSatisfied(expectedGeneration: token) else { return }
                errorMessage = Self.errorMessage(for: error, during: .searching)
                failure = .search(query: trimmed)
            }
        }
    }

    private func jump(to hit: BookSearchHit) {
        guard canInteract, !isRunning else { return }
        queryFocused = false
        let token = UUID()
        generation = token
        activity = .jumping
        errorMessage = nil
        failure = nil

        let jumpAction = actions.jump
        activeTask = Task { @MainActor in
            defer { finishActivity(expectedGeneration: token) }
            do {
                try await jumpAction(hit)
                // Successful jump closes the sheet via the caller; never mutate closed state.
                guard isGuardSatisfied(expectedGeneration: token) else { return }
            } catch is CancellationError {
                return
            } catch {
                guard isGuardSatisfied(expectedGeneration: token) else { return }
                errorMessage = Self.errorMessage(for: error, during: .jumping)
                failure = .jump(hit: hit)
            }
        }
    }

    private func retryFailedOperation() {
        guard canInteract, !isRunning, let failure else { return }
        switch failure {
        case .search(let failedQuery):
            let current = trimmedQuery
            guard !current.isEmpty, current.utf16.count <= Self.maxQueryUTF16Length else { return }
            runSearch(for: current == failedQuery ? failedQuery : current)
        case .jump(let hit):
            jump(to: hit)
        }
    }

    private func isGuardSatisfied(expectedGeneration: UUID) -> Bool {
        !Task.isCancelled && mounted && active && scenePhase == .active && isPanelActive() && generation == expectedGeneration
    }

    private func finishActivity(expectedGeneration: UUID) {
        guard mounted, generation == expectedGeneration else { return }
        activity = nil
        activeTask = nil
    }

    private func cancelInFlightWork() {
        generation = UUID()
        activeTask?.cancel()
        activeTask = nil
        activity = nil
    }

    private func resetForNewSession() {
        queryFocused = false
        clearQueryAndState()
    }

    private static func errorMessage(for error: Error, during activity: Activity) -> String {
        if let epubError = error as? EPUBError {
            switch epubError {
            case .staleSession:
                return "阅读会话已变化，请关闭面板后重试。"
            case .invalidPosition:
                return "该搜索结果与当前章节版本不匹配，无法跳转。"
            case .corruptResource:
                return "章节内容读取异常，无法完成搜索。"
            default:
                return fallbackMessage(for: activity)
            }
        }
        if let libraryError = error as? LibraryError {
            switch libraryError {
            case .closedSession:
                return "阅读会话已变化，请关闭面板后重试。"
            case .invalidAnchor:
                return "该搜索结果位置暂不可用，无法跳转。"
            default:
                return fallbackMessage(for: activity)
            }
        }
        return fallbackMessage(for: activity)
    }

    private static func fallbackMessage(for activity: Activity) -> String {
        switch activity {
        case .searching: return "搜索正文失败，请稍后重试。"
        case .jumping: return "跳转至搜索结果失败，请稍后重试。"
        }
    }
}

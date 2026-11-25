import Foundation
import ReaderDomain
import SwiftUI

/// Native iOS 16.6 SwiftUI Story Theater for an active `StorySession`.
/// Clearly distinguishes real book opening ("本书原文") from offline turns ("离线演绎").
@MainActor
struct StorySessionTheaterView: View {
    private static let maxActionLength = 400
    private static let quickPrompts: [(title: String, text: String)] = [
        ("试探追问", "我稳住气息，直视对方眼睛追问眼下异样的真正来历。"),
        ("暗中观察", "我暂不打草惊蛇，放慢脚步留意四周细节与退路。"),
        ("果断破局", "我不再等待局势发酵，率先迈出一步打破眼前的僵局。"),
        ("表明立场", "我沉声亮明自己的身份与态度，观察在场众人的反应。")
    ]

    let session: StorySession
    @ObservedObject var model: LibraryViewModel
    let appearance: LibraryAppearance
    let isRouteActive: Bool
    let onBackToHub: () -> Void
    let onNewStory: (String) -> Void

    @State private var turns: [StoryTurn] = []
    @State private var hasLoadedTurns = false
    @State private var isLoadingTurns = false
    @State private var isSubmittingTurn = false
    @State private var loadErrorMessage: String?
    @State private var submitBannerMessage: String?
    @State private var actionDraft: String = ""
    @State private var isOpeningExpanded = true
    @State private var isPresentingLockedPreset = false
    @State private var isPresentingModelConfig = false
    @State private var modelConfig: StoryModelConfiguration?
    @State private var pendingDraft: StoryGenerationDraft?
    @State private var isPreparingDraft = false
    @State private var isGeneratingRemote = false
    @State private var streamingActionText: String = ""
    @State private var streamingNarration: String = ""
    @State private var atmospherePulse = 0

    @State private var isViewActive = false
    @State private var loadGeneration = UUID()
    @State private var activeSubmitID: UUID?
    @State private var activePrepareID: UUID?
    @State private var activeGenerateID: UUID?
    @State private var loadTask: Task<Void, Never>?
    @State private var submitTask: Task<Void, Never>?
    @State private var prepareTask: Task<Void, Never>?
    @State private var generateTask: Task<Void, Never>?

    @FocusState private var isActionFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmedAction: String {
        actionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isActionTooLong: Bool {
        trimmedAction.count > Self.maxActionLength
    }

    private var isBusyWithTurn: Bool {
        isSubmittingTurn || isPreparingDraft || isGeneratingRemote
    }

    private var canSubmitAction: Bool {
        isRouteActive
            && model.service != nil
            && hasLoadedTurns
            && loadErrorMessage == nil
            && !isLoadingTurns
            && !isBusyWithTurn
            && !trimmedAction.isEmpty
            && !isActionTooLong
    }

    private var primaryButtonForeground: Color {
        appearance.isDarkSurface ? Color.black.opacity(0.9) : Color.white
    }

    var body: some View {
        ZStack {
            StoryAtmosphereCanvas(appearance: appearance, pulseToken: atmospherePulse)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            sessionHeaderCard
                            openingProseCard
                            turnsSection
                            footerActionsRow
                            Color.clear
                                .frame(height: 12)
                                .id("story.theater.bottom")
                        }
                        .padding(.horizontal, LibraryAppearance.horizontalInset)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: turns.count) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                }

                actionComposerBar
            }
        }
        .accessibilityIdentifier("story.session.screen")
        .sheet(isPresented: $isPresentingLockedPreset) {
            if let lockedPresetID = session.presetID {
                StoryLockedPresetSheet(
                    presetID: lockedPresetID,
                    model: model,
                    appearance: appearance
                )
            }
        }
        .sheet(isPresented: $isPresentingModelConfig) {
            StoryModelConfigSheet(appearance: appearance) { updated in
                modelConfig = updated
            }
        }
        .sheet(item: $pendingDraft) { draft in
            StoryGenerationConfirmSheet(
                draft: draft,
                appearance: appearance,
                onConfirm: { confirmed in
                    pendingDraft = nil
                    startRemoteGeneration(draft: confirmed)
                },
                onCancel: {
                    pendingDraft = nil
                    submitBannerMessage = "已取消发送，未发起网络请求。"
                }
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") {
                    isActionFocused = false
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appearance.accent)
                .accessibilityIdentifier("story.keyboard.done")
            }
        }
        .onAppear {
            isViewActive = true
            refreshModelConfig()
            triggerLoadTurns()
        }
        .onDisappear {
            isViewActive = false
            cancelAllAsyncWork()
        }
        .onChange(of: session.id) { _ in
            resetForSessionChange()
            triggerLoadTurns()
        }
        .onChange(of: isRouteActive) { active in
            if !active {
                isActionFocused = false
                cancelAllAsyncWork()
            } else if isViewActive && !hasLoadedTurns && !isLoadingTurns {
                triggerLoadTurns()
            }
        }
    }

    // MARK: - Header & Opening

    private var sessionHeaderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                StorySoulSigilView(
                    roleKind: session.roleKind,
                    roleName: session.roleName,
                    appearance: appearance,
                    size: 48
                )

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(modelConfig == nil ? "离线演绎 · 未配模型" : "支持离线与 BYOK 生成")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(appearance.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(appearance.accentSoft, in: Capsule())

                        roleBadge(session.roleKind)
                        Spacer(minLength: 0)
                    }

                    Text("《\(session.bookTitle)》")
                        .font(AppVisualStyle.heroBookTitleFont)
                        .foregroundStyle(appearance.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("当前角色")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appearance.secondary)
                    Text(session.roleName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appearance.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text("已演 \(turns.count) 幕")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(appearance.accent)
                }

                if !session.premise.isEmpty {
                    Text(session.premise)
                        .font(.subheadline)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("记录时间 · \(session.createdAt.formatted(date: .numeric, time: .shortened))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(appearance.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(appearance.subtleSurface.opacity(0.68), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("story.session.role")

            if let lockedPresetID = session.presetID {
                Button {
                    isActionFocused = false
                    isPresentingLockedPreset = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.doc")
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                        Text("本局锁定预设 · \(StoryPresetWorkshopView.shortHash(lockedPresetID))")
                            .font(.caption.weight(.semibold).monospaced())
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("查看")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(appearance.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: LibraryAppearance.minimumControlHeight, alignment: .leading)
                    .background(appearance.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看本局锁定的叙事预设版本")
                .accessibilityHint("只读查看，主动联网模型生成时将按本局锁定版本组装")
                .accessibilityIdentifier("story.session.lockedPreset")
            }

            Button {
                isActionFocused = false
                isPresentingModelConfig = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: modelConfig == nil ? "key" : "network")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                    Text(modelConfig.map { "BYOK 模型 · \($0.model)" } ?? "配置 BYOK 模型（可选联网生成）")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(modelConfig == nil ? "配置" : "管理")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(appearance.foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: LibraryAppearance.minimumControlHeight, alignment: .leading)
                .background(appearance.subtleSurface.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isBusyWithTurn)
            .accessibilityLabel(modelConfig == nil ? "配置自带密钥模型接口" : "管理已配置的模型接口")
            .accessibilityIdentifier("story.session.modelConfig")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay {
            cardBorder(appearance.edge.opacity(0.8))
        }
        .shadow(color: appearance.cardShadow, radius: 8, x: 0, y: 3)
    }

    private var openingProseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(appearance.accent)
                        .frame(width: 3, height: 15)
                        .accessibilityHidden(true)
                    Text("本书原文 · 真实开篇")
                        .font(LibraryAppearance.sectionTitleFont)
                        .foregroundStyle(appearance.foreground)
                        .accessibilityAddTraits(.isHeader)
                }

                Spacer(minLength: 8)

                Button {
                    if reduceMotion {
                        isOpeningExpanded.toggle()
                    } else {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            isOpeningExpanded.toggle()
                        }
                    }
                } label: {
                    Text(isOpeningExpanded ? "收起原文" : "展开原文")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appearance.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(appearance.accentSoft, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("story.session.toggleOpening")
            }

            if isOpeningExpanded {
                Text(session.opening)
                    .font(.system(.body, design: .serif))
                    .lineSpacing(8)
                    .foregroundStyle(appearance.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("story.session.opening")
            } else {
                Text(session.opening)
                    .font(.system(.subheadline, design: .serif))
                    .lineSpacing(5)
                    .lineLimit(3)
                    .foregroundStyle(appearance.secondary)
                    .accessibilityIdentifier("story.session.opening")
            }

            HStack(spacing: 6) {
                Image(systemName: "book.closed")
                    .font(.caption2)
                    .foregroundStyle(appearance.secondary)
                    .accessibilityHidden(true)
                Text("以上为书架中本书的真实原文节选；下方回合会明确标注为“离线演绎”或具体“模型生成”来源。")
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay {
            cardBorder(appearance.edge.opacity(0.8))
        }
        .shadow(color: appearance.cardShadow, radius: 6, x: 0, y: 2)
    }

    // MARK: - Offline Turns Feed

    private var turnsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isLoadingTurns && turns.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(appearance.accent)
                    Text("正在恢复本地演绎存档…")
                        .font(.subheadline)
                        .foregroundStyle(appearance.secondary)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(appearance.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay { cardBorder(appearance.edge.opacity(0.7)) }
                .accessibilityIdentifier("story.turns.loading")
            }

            if let loadErrorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Text("未能读取已保存的演绎回合")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appearance.foreground)
                    Text(loadErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        triggerLoadTurns()
                    } label: {
                        Label("重新读取存档", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 38)
                    }
                    .buttonStyle(AppControlButtonStyle(
                        foreground: appearance.accent,
                        surface: appearance.accentSoft,
                        border: appearance.accent.opacity(0.28),
                        cornerRadius: 12
                    ))
                    .accessibilityIdentifier("story.turns.retry")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(appearance.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay { cardBorder(appearance.sealAccent.opacity(0.45)) }
                .accessibilityIdentifier("story.turns.error")
            }

            if !turns.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(turns) { turn in
                        turnRow(turn)
                            .id(turn.id)
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                .accessibilityIdentifier("story.turns.list")
            }

            if isGeneratingRemote {
                streamingDraftCard
            }
        }
    }

    private var streamingDraftCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !streamingActionText.isEmpty {
                HStack {
                    Spacer(minLength: 28)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(session.roleName) · 行动（生成中）")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(appearance.accent)
                        Text(streamingActionText)
                            .font(.subheadline)
                            .foregroundStyle(appearance.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(appearance.accentSoft.opacity(0.75), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(appearance.accent)
                        .scaleEffect(0.85)
                    Text("模型流式生成中（临时预览 · 未落盘）")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(appearance.accent)
                    Spacer(minLength: 4)
                    Button("取消生成") {
                        cancelRemoteGeneration(showBanner: true)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.sealAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(appearance.sealSoft, in: Capsule())
                    .accessibilityIdentifier("story.streaming.cancel")
                }

                Text(streamingNarration.isEmpty ? "正在等待远端模型返回首个片段…" : streamingNarration)
                    .font(.system(.body, design: .serif))
                    .lineSpacing(8)
                    .foregroundStyle(streamingNarration.isEmpty ? appearance.secondary : appearance.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("story.streaming.text")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
            .overlay { cardBorder(appearance.accent.opacity(0.55)) }
        }
        .accessibilityIdentifier("story.streaming.card")
    }

    private func turnRow(_ turn: StoryTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Player Action Bubble (right-aligned)
            HStack {
                Spacer(minLength: 28)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(session.roleName) · 行动")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(appearance.accent)
                    Text(turn.action)
                        .font(.subheadline)
                        .lineSpacing(4)
                        .foregroundStyle(appearance.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(appearance.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(appearance.accent.opacity(0.32), lineWidth: 0.8)
                        .allowsHitTesting(false)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("story.turn.action.\(turn.sequence)")
            }

            // Persisted Narration Card: distinguish remote model vs offline turn via turn.modelName
            let remoteModel = turn.modelName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isRemoteModel = (remoteModel?.isEmpty == false)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(isRemoteModel
                         ? "模型生成 · \(remoteModel!) · 第 \(turn.sequence) 幕"
                         : "离线演绎 · 第 \(turn.sequence) 幕")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isRemoteModel ? appearance.accent : appearance.sealAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isRemoteModel ? appearance.accentSoft : appearance.sealSoft, in: Capsule())
                    Spacer(minLength: 0)
                }

                Text(turn.narration)
                    .font(.system(.body, design: .serif))
                    .lineSpacing(8)
                    .foregroundStyle(appearance.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
            .overlay {
                cardBorder(appearance.sealAccent.opacity(0.28))
            }
            .shadow(color: appearance.cardShadow, radius: 6, x: 0, y: 2)
            .accessibilityIdentifier("story.turn.narration.\(turn.sequence)")
        }
    }

    private var footerActionsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                backToHubButton
                newAnotherStoryButton
            }
            VStack(spacing: 10) {
                backToHubButton
                newAnotherStoryButton
            }
        }
        .padding(.top, 6)
    }

    private var backToHubButton: some View {
        Button {
            isActionFocused = false
            onBackToHub()
        } label: {
            Text("返回故事列表")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: appearance.accent,
            surface: appearance.accentSoft,
            border: appearance.accent.opacity(0.28),
            cornerRadius: 14
        ))
        .accessibilityIdentifier("story.session.backToHub")
    }

    private var newAnotherStoryButton: some View {
        Button {
            isActionFocused = false
            onNewStory(session.bookID)
        } label: {
            Text("新建另一段开局")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: appearance.foreground,
            surface: appearance.subtleSurface,
            border: appearance.edge.opacity(0.8),
            cornerRadius: 14
        ))
        .accessibilityIdentifier("story.session.new")
    }

    // MARK: - Bottom Action Composer

    private var actionComposerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let submitBannerMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(appearance.sealAccent)
                        .accessibilityHidden(true)
                    Text(submitBannerMessage)
                        .font(.caption)
                        .foregroundStyle(appearance.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        self.submitBannerMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(appearance.secondary)
                            .frame(minWidth: 28, minHeight: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭提示")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(appearance.sealSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("story.action.banner")
            }

            // Quick intent starter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(Self.quickPrompts.enumerated()), id: \.offset) { idx, prompt in
                        Button {
                            actionDraft = prompt.text
                            submitBannerMessage = nil
                        } label: {
                            Text(prompt.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(appearance.accent)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(appearance.accentSoft, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusyWithTurn || isLoadingTurns)
                        .accessibilityIdentifier("story.action.quickChip.\(idx)")
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("输入你的行动、台词或抉择（1–400 字）…", text: $actionDraft, axis: .vertical)
                        .font(.subheadline)
                        .lineLimit(1...4)
                        .focused($isActionFocused)
                        .disabled(isBusyWithTurn)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(appearance.subtleSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    isActionTooLong ? appearance.sealAccent : appearance.edge.opacity(0.9),
                                    lineWidth: isActionTooLong ? 1.2 : 0.8
                                )
                                .allowsHitTesting(false)
                        }
                        .accessibilityIdentifier("story.action.input")

                    Text("\(trimmedAction.count)/\(Self.maxActionLength)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isActionTooLong ? appearance.sealAccent : appearance.secondary)
                        .accessibilityIdentifier("story.action.count")
                }

                VStack(spacing: 6) {
                    Button {
                        submitAction()
                    } label: {
                        Group {
                            if isSubmittingTurn {
                                ProgressView()
                                    .tint(appearance.accent)
                            } else {
                                Text("离线演绎")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .frame(minWidth: 74, minHeight: 36)
                    }
                    .buttonStyle(AppControlButtonStyle(
                        foreground: appearance.accent,
                        surface: appearance.accentSoft,
                        border: appearance.accent.opacity(0.32),
                        cornerRadius: 12
                    ))
                    .disabled(!canSubmitAction)
                    .accessibilityLabel("提交行动并生成离线演绎")
                    .accessibilityIdentifier("story.action.submit")

                    Button {
                        triggerPrepareRemoteGeneration()
                    } label: {
                        Group {
                            if isPreparingDraft || isGeneratingRemote {
                                ProgressView()
                                    .tint(primaryButtonForeground)
                            } else {
                                Text("AI 生成")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .frame(minWidth: 74, minHeight: 36)
                    }
                    .buttonStyle(AppControlButtonStyle(
                        foreground: primaryButtonForeground,
                        surface: appearance.accent,
                        cornerRadius: 12
                    ))
                    .disabled(!canSubmitAction)
                    .accessibilityLabel("准备并确认向 BYOK 模型发送生成请求")
                    .accessibilityIdentifier("story.action.generateRemote")
                }
            }
        }
        .padding(.horizontal, LibraryAppearance.horizontalInset)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(appearance.surface.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(appearance.edge.opacity(0.75))
                .frame(height: 0.6)
        }
    }

    // MARK: - Helpers

    private func roleBadge(_ kind: StoryRoleKind) -> some View {
        let isCanon = kind == .canon
        return Text(isCanon ? "原著角色" : "原创角色")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isCanon ? appearance.accent : appearance.sealAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(isCanon ? appearance.accentSoft : appearance.sealSoft, in: Capsule())
    }

    private func cardBorder(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
            .strokeBorder(color, lineWidth: 0.75)
            .allowsHitTesting(false)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo("story.theater.bottom", anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo("story.theater.bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Async Store Integration (Stale-Writeback & Conflict Guarded)

    private func resetForSessionChange() {
        cancelAllAsyncWork()
        turns = []
        hasLoadedTurns = false
        loadErrorMessage = nil
        submitBannerMessage = nil
        actionDraft = ""
        isOpeningExpanded = true
    }

    private func cancelAllAsyncWork() {
        loadGeneration = UUID()
        activeSubmitID = nil
        activePrepareID = nil
        activeGenerateID = nil
        loadTask?.cancel()
        loadTask = nil
        submitTask?.cancel()
        submitTask = nil
        prepareTask?.cancel()
        prepareTask = nil
        generateTask?.cancel()
        generateTask = nil
        pendingDraft = nil
        streamingActionText = ""
        streamingNarration = ""
        isLoadingTurns = false
        isSubmittingTurn = false
        isPreparingDraft = false
        isGeneratingRemote = false
    }

    private func refreshModelConfig() {
        modelConfig = try? StoryModelVault.load()
    }

    private func cancelRemoteGeneration(showBanner: Bool) {
        activeGenerateID = nil
        generateTask?.cancel()
        generateTask = nil
        isGeneratingRemote = false
        streamingActionText = ""
        streamingNarration = ""
        if showBanner {
            submitBannerMessage = "已取消模型生成，未保存半回合，也不会自动重试。"
        }
    }

    private func triggerPrepareRemoteGeneration() {
        guard canSubmitAction, let service = model.service else { return }
        guard let config = try? StoryModelVault.load() else {
            modelConfig = nil
            isPresentingModelConfig = true
            submitBannerMessage = "请先配置 HTTPS OpenAI 兼容模型接口与 API Key，再发起联网生成。"
            return
        }
        modelConfig = config

        let actionText = trimmedAction
        let expectedCount = turns.count
        let currentSession = session
        let reqID = UUID()

        activePrepareID = reqID
        isPreparingDraft = true
        submitBannerMessage = nil
        isActionFocused = false
        prepareTask?.cancel()

        prepareTask = Task { @MainActor in
            defer {
                if activePrepareID == reqID {
                    isPreparingDraft = false
                    activePrepareID = nil
                    prepareTask = nil
                }
            }
            do {
                let draft = try await service.prepareStoryGeneration(
                    session: currentSession,
                    expectedCount: expectedCount,
                    action: actionText,
                    configuration: config
                )
                guard !Task.isCancelled,
                      activePrepareID == reqID,
                      isViewActive,
                      isRouteActive,
                      session.id == currentSession.id else { return }
                pendingDraft = draft
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      activePrepareID == reqID,
                      isViewActive,
                      isRouteActive,
                      session.id == currentSession.id else { return }
                if let store = model.service?.store {
                    let refreshed = try? await store.storyTurns(sessionID: currentSession.id)
                    guard !Task.isCancelled,
                          activePrepareID == reqID,
                          isViewActive,
                          isRouteActive,
                          session.id == currentSession.id else { return }
                    if let refreshed {
                        let sorted = refreshed.sorted { $0.sequence < $1.sequence }
                        if sorted.count != turns.count {
                            turns = sorted
                            submitBannerMessage = "存档已更新，已同步最新回合；请重新发起发送前确认。"
                            return
                        }
                    }
                }
                submitBannerMessage = "未能准备模型请求：\(error.localizedDescription)"
            }
        }
    }

    private func startRemoteGeneration(draft: StoryGenerationDraft) {
        guard isViewActive, isRouteActive, !isGeneratingRemote, let service = model.service else { return }
        let targetSessionID = session.id
        let reqID = UUID()

        activeGenerateID = reqID
        isGeneratingRemote = true
        streamingActionText = trimmedAction
        streamingNarration = ""
        submitBannerMessage = nil
        generateTask?.cancel()

        generateTask = Task { @MainActor in
            defer {
                if activeGenerateID == reqID {
                    isGeneratingRemote = false
                    activeGenerateID = nil
                    generateTask = nil
                    streamingActionText = ""
                    streamingNarration = ""
                }
            }
            do {
                let newTurn = try await service.generateStoryTurn(draft) { cumulativeText in
                    await MainActor.run {
                        guard !Task.isCancelled,
                              activeGenerateID == reqID,
                              isViewActive,
                              isRouteActive,
                              session.id == targetSessionID else { return }
                        streamingNarration = cumulativeText
                    }
                }
                guard !Task.isCancelled,
                      activeGenerateID == reqID,
                      isViewActive,
                      isRouteActive,
                      session.id == targetSessionID else { return }

                if !turns.contains(where: { $0.id == newTurn.id || $0.sequence == newTurn.sequence }) {
                    if reduceMotion {
                        turns.append(newTurn)
                    } else {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                            turns.append(newTurn)
                        }
                    }
                    turns.sort { $0.sequence < $1.sequence }
                }
                actionDraft = ""
                atmospherePulse &+= 1
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      activeGenerateID == reqID,
                      isViewActive,
                      isRouteActive,
                      session.id == targetSessionID else { return }
                if let store = model.service?.store {
                    let refreshed = try? await store.storyTurns(sessionID: targetSessionID)
                    guard !Task.isCancelled,
                          activeGenerateID == reqID,
                          isViewActive,
                          isRouteActive,
                          session.id == targetSessionID else { return }
                    if let refreshed {
                        let sorted = refreshed.sorted { $0.sequence < $1.sequence }
                        if sorted.count != turns.count {
                            turns = sorted
                            submitBannerMessage = "存档已同步；本次模型生成中断，未保存半回合。"
                            return
                        }
                    }
                }
                submitBannerMessage = "模型生成中断或失败（未保存半回合，不自动重试）：\(error.localizedDescription)"
            }
        }
    }

    private func triggerLoadTurns() {
        guard isViewActive, isRouteActive, let store = model.service?.store else { return }
        let generation = UUID()
        let targetSessionID = session.id
        loadGeneration = generation
        loadTask?.cancel()
        isLoadingTurns = true
        loadErrorMessage = nil

        loadTask = Task { @MainActor in
            defer {
                if loadGeneration == generation {
                    isLoadingTurns = false
                    loadTask = nil
                }
            }
            do {
                let loaded = try await store.storyTurns(sessionID: targetSessionID)
                guard !Task.isCancelled,
                      loadGeneration == generation,
                      isViewActive,
                      isRouteActive,
                      session.id == targetSessionID else { return }
                turns = loaded.sorted { $0.sequence < $1.sequence }
                hasLoadedTurns = true
            } catch {
                guard !Task.isCancelled,
                      loadGeneration == generation,
                      isViewActive,
                      isRouteActive,
                      session.id == targetSessionID else { return }
                loadErrorMessage = error.localizedDescription
            }
        }
    }

    private func submitAction() {
        guard canSubmitAction, let store = model.service?.store else { return }
        let actionText = trimmedAction
        let expectedCount = turns.count
        let targetSessionID = session.id
        let requestID = UUID()

        activeSubmitID = requestID
        isSubmittingTurn = true
        submitBannerMessage = nil
        isActionFocused = false
        submitTask?.cancel()

        submitTask = Task { @MainActor in
            defer {
                if activeSubmitID == requestID {
                    isSubmittingTurn = false
                    activeSubmitID = nil
                    submitTask = nil
                }
            }
            do {
                let newTurn = try await store.playStoryTurn(
                    sessionID: targetSessionID,
                    expectedCount: expectedCount,
                    action: actionText
                )
                guard !Task.isCancelled,
                      activeSubmitID == requestID,
                      isViewActive,
                      isRouteActive,
                      session.id == targetSessionID else { return }

                if !turns.contains(where: { $0.id == newTurn.id || $0.sequence == newTurn.sequence }) {
                    if reduceMotion {
                        turns.append(newTurn)
                    } else {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                            turns.append(newTurn)
                        }
                    }
                    turns.sort { $0.sequence < $1.sequence }
                }
                actionDraft = ""
                atmospherePulse &+= 1
            } catch {
                guard !Task.isCancelled,
                      activeSubmitID == requestID,
                      isViewActive,
                      isRouteActive,
                      session.id == targetSessionID else { return }

                // Re-read persisted turns on conflict or write failure so state stays consistent.
                let refreshed = try? await store.storyTurns(sessionID: targetSessionID)
                guard !Task.isCancelled,
                      activeSubmitID == requestID,
                      isViewActive,
                      isRouteActive,
                      session.id == targetSessionID else { return }

                if let refreshed {
                    let sorted = refreshed.sorted { $0.sequence < $1.sequence }
                    if sorted.count != turns.count {
                        turns = sorted
                        submitBannerMessage = "存档已更新，已重新同步最新演绎记录；你可以继续提交当前行动。"
                    } else {
                        submitBannerMessage = "未能完成本轮演绎：\(error.localizedDescription)"
                    }
                } else {
                    submitBannerMessage = "未能完成本轮演绎：\(error.localizedDescription)"
                }
            }
        }
    }
}

import Foundation
import ReaderDomain
import SwiftUI

/// Native iOS 16.6 SwiftUI Story Theater for an active `StorySession`.
/// Presents book-first long-form typography with clear chapter/prose hierarchy.
/// New turns are exclusively generated via user-confirmed BYOK model requests;
/// persisted legacy offline turns remain readable with honest source attribution.
@MainActor
struct StorySessionTheaterView: View {
    private static let maxActionLength = 400
    private static let countHintThreshold = 320

    private struct FormattedProse: Equatable {
        let chapterHeading: String?
        let paragraphs: [String]
    }

    let session: StorySession
    @ObservedObject var model: LibraryViewModel
    let appearance: LibraryAppearance
    let isRouteActive: Bool
    var isDeletingSession: Bool = false
    var externalErrorMessage: String? = nil
    var onDismissExternalError: () -> Void = {}
    let onBackToHub: () -> Void
    let onNewStory: (String) -> Void
    var onRequestDelete: (() -> Void)? = nil

    @State private var turns: [StoryTurn] = []
    @State private var hasLoadedTurns = false
    @State private var isLoadingTurns = false
    @State private var loadErrorMessage: String?
    @State private var submitBannerMessage: String?
    @State private var actionDraft: String = ""
    @State private var isOpeningExpanded = true
    @State private var isImmersiveReading = false
    @State private var isPresentingLockedPreset = false
    @State private var isPresentingModelConfig = false
    @State private var isPresentingStyleSheet = false
    @State private var activeRecipe: StoryVisualRecipe = .standard
    @State private var pendingStyleDraft: StoryStyleDraft?
    @State private var isDirectingStyle = false
    @State private var styleFeedbackMessage: String?
    @State private var modelConfig: StoryModelConfiguration?
    @State private var pendingDraft: StoryGenerationDraft?
    @State private var isPreparingDraft = false
    @State private var isGeneratingRemote = false
    @State private var streamingActionText: String = ""
    @State private var streamingNarration: String = ""
    @State private var atmospherePulse = 0

    @State private var isViewActive = false
    @State private var loadGeneration = UUID()
    @State private var activePrepareID: UUID?
    @State private var activeGenerateID: UUID?
    @State private var activeStyleID: UUID?
    @State private var loadTask: Task<Void, Never>?
    @State private var prepareTask: Task<Void, Never>?
    @State private var generateTask: Task<Void, Never>?
    @State private var styleTask: Task<Void, Never>?

    @FocusState private var isActionFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType

    private var trimmedAction: String {
        actionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isActionTooLong: Bool {
        trimmedAction.count > Self.maxActionLength
    }

    private var isBusyWithTurn: Bool {
        isPreparingDraft || isGeneratingRemote || isDeletingSession
    }

    private var canDeleteInTheater: Bool {
        onRequestDelete != nil
            && !isPreparingDraft
            && !isGeneratingRemote
            && !isDirectingStyle
            && pendingDraft == nil
            && pendingStyleDraft == nil
            && !isDeletingSession
            && isRouteActive
    }

    private var canSubmitRemoteAction: Bool {
        isRouteActive
            && model.service != nil
            && modelConfig != nil
            && hasLoadedTurns
            && loadErrorMessage == nil
            && !isLoadingTurns
            && !isBusyWithTurn
            && !trimmedAction.isEmpty
            && !isActionTooLong
    }

    private var resolvedStyle: StoryResolvedStyle {
        StoryResolvedStyle.resolve(recipe: activeRecipe, base: appearance)
    }

    private var primaryButtonForeground: Color {
        resolvedStyle.primaryButtonForeground
    }

    private var formattedOpening: FormattedProse {
        Self.formatProse(session.opening)
    }

    var body: some View {
        let style = resolvedStyle
        return ZStack {
            style.pageBackground
                .ignoresSafeArea()
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: activeRecipe)

            StoryStyledAtmosphereCanvas(style: style, pulseToken: atmospherePulse)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            bookMasthead
                            openingReadingSection
                            turnsSection
                            if !isImmersiveReading {
                                footerActionsRow
                            }
                            Color.clear
                                .frame(height: isImmersiveReading
                                       ? ((externalErrorMessage != nil || submitBannerMessage != nil) ? 132 : 80)
                                       : 16)
                                .id("story.theater.bottom")
                        }
                        .padding(.horizontal, LibraryAppearance.horizontalInset)
                        .padding(.top, 10)
                        .padding(.bottom, 16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: turns.count) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: isGeneratingRemote) { generating in
                        if generating {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                }

                if !isImmersiveReading {
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [style.pageBackground.opacity(0), style.pageBackground.opacity(0.92)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 14)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                        actionComposerBar
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if isImmersiveReading {
                    immersiveFloatingDock(style: style)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
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
                if updated != nil {
                    submitBannerMessage = nil
                }
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
        .sheet(isPresented: $isPresentingStyleSheet) {
            StoryStyleCompareSheet(
                recipe: $activeRecipe,
                appearance: appearance,
                hasModelConfig: modelConfig != nil,
                isDirectingStyle: isDirectingStyle,
                styleStatusMessage: styleFeedbackMessage,
                onRequestAIDirect: {
                    prepareAIDirectStyle()
                },
                onCancelAIDirect: {
                    cancelStyleDirection(showBanner: true)
                },
                onOpenModelConfig: {
                    isPresentingModelConfig = true
                }
            )
        }
        .sheet(item: $pendingStyleDraft) { draft in
            StoryStyleConfirmSheet(
                draft: draft,
                appearance: appearance,
                onConfirm: { confirmed in
                    pendingStyleDraft = nil
                    startAIDirectStyle(draft: confirmed)
                },
                onCancel: {
                    pendingStyleDraft = nil
                    submitBannerMessage = "已取消 AI 判型，未发起网络请求，保持当前风格。"
                }
            )
        }
        .onChange(of: activeRecipe) { _ in
            atmospherePulse &+= 1
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    toggleImmersiveReading()
                } label: {
                    Image(systemName: isImmersiveReading ? "rectangle.compress.vertical" : "book.pages")
                        .font(.body.weight(.medium))
                        .foregroundStyle(resolvedStyle.accent)
                        .frame(minWidth: 44, minHeight: LibraryAppearance.minimumControlHeight)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(isImmersiveReading ? "退出专注阅读并显示行动栏" : "开启专注阅读，收起外围控件")
                .accessibilityValue(isImmersiveReading ? "专注阅读中" : "标准模式")
                .accessibilityIdentifier("story.session.immersiveToggle")

                Menu {
                    Button {
                        isActionFocused = false
                        isPresentingStyleSheet = true
                    } label: {
                        Label("书境视觉风格", systemImage: "wand.and.stars")
                    }
                    .disabled(isDeletingSession)

                    Button {
                        isActionFocused = false
                        isPresentingModelConfig = true
                    } label: {
                        Label("BYOK 模型配置", systemImage: "key")
                    }
                    .disabled(isBusyWithTurn)

                    if session.presetID != nil {
                        Button {
                            isActionFocused = false
                            isPresentingLockedPreset = true
                        } label: {
                            Label("查看锁定预设", systemImage: "lock.doc")
                        }
                    }

                    if activeRecipe != .standard {
                        Button {
                            StoryHaptics.selection()
                            activeRecipe = .standard
                        } label: {
                            Label("还原默认风格", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(isDirectingStyle || isDeletingSession)
                    }

                    if let onRequestDelete {
                        Divider()
                        Button(role: .destructive) {
                            isActionFocused = false
                            onRequestDelete()
                        } label: {
                            Label("删除本局故事", systemImage: "trash")
                        }
                        .disabled(!canDeleteInTheater)
                    }
                } label: {
                    Group {
                        if isDeletingSession {
                            ProgressView()
                                .tint(resolvedStyle.sealAccent)
                                .scaleEffect(0.85)
                        } else {
                            Image(systemName: "ellipsis.circle")
                                .font(.body.weight(.medium))
                                .foregroundStyle(resolvedStyle.accent)
                        }
                    }
                    .frame(minWidth: 44, minHeight: LibraryAppearance.minimumControlHeight)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("更多故事操作")
                .accessibilityHint(
                    onRequestDelete == nil
                        ? "包含视觉风格、模型配置与还原风格"
                        : (canDeleteInTheater ? "包含视觉风格、模型配置、还原风格与删除本局故事" : "生成或确认预览进行中，暂不可删除")
                )
                .accessibilityIdentifier("story.session.more")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") {
                    isActionFocused = false
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(resolvedStyle.accent)
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
            refreshModelConfig()
            triggerLoadTurns()
        }
        .onChange(of: isRouteActive) { active in
            if !active {
                isActionFocused = false
                cancelAllAsyncWork()
            } else if isViewActive && !hasLoadedTurns && !isLoadingTurns {
                refreshModelConfig()
                triggerLoadTurns()
            }
        }
    }

    // MARK: - Editorial Masthead

    private var bookMasthead: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                StoryLivingSigilView(
                    roleKind: session.roleKind,
                    roleName: session.roleName,
                    appearance: appearance,
                    size: dynamicType.isAccessibilitySize ? 38 : 48
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text("《\(session.bookTitle)》")
                        .font(resolvedStyle.bookTitleFont)
                        .foregroundStyle(resolvedStyle.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    HStack(spacing: 6) {
                        roleBadge(session.roleKind)
                        Text(session.roleName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(resolvedStyle.foreground)
                            .lineLimit(1)
                        if !turns.isEmpty {
                            Text("· \(turns.count) 幕")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(resolvedStyle.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("story.session.role")

            if !session.premise.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(resolvedStyle.accent.opacity(0.65))
                        .frame(width: 2)
                        .accessibilityHidden(true)
                    Text(session.premise)
                        .font(.footnote)
                        .lineSpacing(4)
                        .foregroundStyle(resolvedStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !isImmersiveReading {
                // Compact utility pills: style compare / AI director, model status, locked preset
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        styleControlPill
                        modelStatusPill
                        if let lockedPresetID = session.presetID {
                            lockedPresetPill(lockedPresetID)
                        }
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            styleControlPill
                            modelStatusPill
                        }
                        if let lockedPresetID = session.presetID {
                            lockedPresetPill(lockedPresetID)
                        }
                    }
                }
                .transition(.opacity)
            }

            if isDirectingStyle {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(resolvedStyle.accent)
                        .scaleEffect(0.85)
                    Text("正在由模型判定本局视觉风格…")
                        .font(.caption)
                        .foregroundStyle(resolvedStyle.secondary)
                    Spacer(minLength: 4)
                    Button("取消") {
                        cancelStyleDirection(showBanner: true)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(resolvedStyle.sealAccent)
                    .accessibilityIdentifier("story.style.inlineCancel")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(resolvedStyle.surface.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("story.style.directingBanner")
            }
        }
        .padding(.vertical, 6)
    }

    private var styleControlPill: some View {
        Button {
            isActionFocused = false
            isPresentingStyleSheet = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                Text(resolvedStyle.shortLabel)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(resolvedStyle.accent)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(minHeight: 34)
            .background(resolvedStyle.accentSoft, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDeletingSession)
        .accessibilityLabel("视觉风格对照与 AI 判型，当前 \(resolvedStyle.shortLabel)")
        .accessibilityIdentifier("story.session.styleControl")
    }

    private var modelStatusPill: some View {
        Button {
            isActionFocused = false
            isPresentingModelConfig = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: modelConfig == nil ? "key" : "sparkles")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                Text(modelConfig.map { $0.model } ?? "未配置模型")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(modelConfig == nil ? appearance.sealAccent : appearance.accent)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(minHeight: 34)
            .background(
                (modelConfig == nil ? appearance.sealSoft : appearance.accentSoft),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusyWithTurn)
        .accessibilityLabel(modelConfig == nil ? "配置自带密钥模型接口" : "管理已配置的模型接口")
        .accessibilityIdentifier("story.session.modelConfig")
    }

    private func lockedPresetPill(_ presetID: String) -> some View {
        Button {
            isActionFocused = false
            isPresentingLockedPreset = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "lock.doc")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                Text("预设 · \(StoryPresetWorkshopView.shortHash(presetID).prefix(8))")
                    .font(.caption.weight(.medium).monospaced())
                    .lineLimit(1)
            }
            .foregroundStyle(appearance.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(minHeight: 34)
            .background(appearance.subtleSurface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看本局锁定的叙事预设版本")
        .accessibilityHint("只读查看，发送模型请求时将按本局锁定版本组装")
        .accessibilityIdentifier("story.session.lockedPreset")
    }

    // MARK: - Book-First Opening Reading Section

    private var openingReadingSection: some View {
        let prose = formattedOpening
        let style = resolvedStyle
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                Text("本书原文")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(style.accentSoft, in: Capsule())

                Text(session.createdAt.formatted(date: .numeric, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(style.secondary)

                Spacer(minLength: 8)

                if !turns.isEmpty || !isOpeningExpanded {
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
                            .foregroundStyle(style.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("story.session.toggleOpening")
                }
            }

            if isOpeningExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    if let heading = prose.chapterHeading {
                        VStack(alignment: .center, spacing: 8) {
                            Text(heading)
                                .font(style.chapterHeadingFont)
                                .foregroundStyle(style.foreground)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)

                            HStack(spacing: 8) {
                                Rectangle()
                                    .fill(style.accent.opacity(0.38))
                                    .frame(width: 28, height: 0.75)
                                Circle()
                                    .fill(style.accent.opacity(0.8))
                                    .frame(width: 4, height: 4)
                                Rectangle()
                                    .fill(style.accent.opacity(0.38))
                                    .frame(width: 28, height: 0.75)
                            }
                            .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }

                    VStack(alignment: .leading, spacing: 13) {
                        ForEach(Array(prose.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .font(style.proseFont)
                                .lineSpacing(style.proseLineSpacing)
                                .foregroundStyle(style.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .accessibilityIdentifier("story.session.opening")
            } else {
                Text(prose.chapterHeading ?? prose.paragraphs.first ?? session.opening)
                    .font(style.proseFont)
                    .lineSpacing(5)
                    .lineLimit(2)
                    .foregroundStyle(style.secondary)
                    .accessibilityIdentifier("story.session.opening")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous)
                .strokeBorder(style.edge.opacity(0.75), lineWidth: 0.7)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Story Turns Feed

    private var turnsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if isLoadingTurns && turns.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(appearance.accent)
                    Text("正在恢复本局已保存的剧情…")
                        .font(.subheadline)
                        .foregroundStyle(appearance.secondary)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(appearance.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityIdentifier("story.turns.loading")
            }

            if let loadErrorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Text("未能读取已保存的剧情回合")
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
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(appearance.sealAccent.opacity(0.45), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
                .accessibilityIdentifier("story.turns.error")
            }

            if !turns.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
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
        let style = resolvedStyle
        return VStack(alignment: .leading, spacing: 12) {
            if !streamingActionText.isEmpty {
                playerActionBlock(text: streamingActionText, subtitle: "\(session.roleName) · 落笔中")
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(style.accent)
                        .scaleEffect(0.85)
                    Text("模型续写中（未落盘）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(style.accent)
                    Spacer(minLength: 4)
                    Button("取消") {
                        cancelRemoteGeneration(showBanner: true)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.sealAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(style.sealSoft, in: Capsule())
                    .accessibilityLabel("取消本次模型生成")
                    .accessibilityIdentifier("story.streaming.cancel")
                }

                if streamingNarration.isEmpty {
                    Text("正在等待远端模型返回首个片段…")
                        .font(style.proseFont)
                        .foregroundStyle(style.secondary)
                        .accessibilityIdentifier("story.streaming.text")
                } else {
                    let streamed = Self.formatProse(streamingNarration)
                    VStack(alignment: .leading, spacing: 12) {
                        if let heading = streamed.chapterHeading {
                            Text(heading)
                                .font(style.chapterHeadingFont)
                                .foregroundStyle(style.foreground)
                        }
                        ForEach(Array(streamed.paragraphs.enumerated()), id: \.offset) { idx, p in
                            let isLast = idx == streamed.paragraphs.count - 1
                            Text(isLast ? "\(p) ▍" : p)
                                .font(style.proseFont)
                                .lineSpacing(style.proseLineSpacing)
                                .foregroundStyle(style.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("story.streaming.text")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous)
                    .strokeBorder(style.accent.opacity(0.55), lineWidth: 0.95)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("story.streaming.card")
    }

    private func turnRow(_ turn: StoryTurn) -> some View {
        let remoteModel = turn.modelName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isRemoteModel = (remoteModel?.isEmpty == false)
        let formatted = Self.formatProse(turn.narration)

        let style = resolvedStyle
        return VStack(alignment: .leading, spacing: 14) {
            // Ornamental act divider
            HStack(spacing: 10) {
                Rectangle()
                    .fill(style.edge.opacity(0.65))
                    .frame(height: 0.6)
                Text("✦ 第 \(turn.sequence) 幕 ✦")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isRemoteModel ? style.accent : style.secondary)
                Rectangle()
                    .fill(style.edge.opacity(0.65))
                    .frame(height: 0.6)
            }
            .padding(.vertical, 2)
            .accessibilityHidden(true)

            playerActionBlock(text: turn.action, subtitle: session.roleName)
                .accessibilityIdentifier("story.turn.action.\(turn.sequence)")

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(isRemoteModel
                         ? "AI 生成 · \(remoteModel!) · 第 \(turn.sequence) 幕"
                         : "历史离线记录 · 第 \(turn.sequence) 幕")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isRemoteModel ? style.accent : style.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(
                            isRemoteModel ? style.accentSoft : style.subtleSurface,
                            in: Capsule()
                        )
                    Spacer(minLength: 0)
                }

                if let heading = formatted.chapterHeading {
                    Text(heading)
                        .font(style.chapterHeadingFont)
                        .foregroundStyle(style.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 13) {
                    ForEach(Array(formatted.paragraphs.enumerated()), id: \.offset) { _, p in
                        Text(p)
                            .font(style.proseFont)
                            .lineSpacing(style.proseLineSpacing)
                            .foregroundStyle(style.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        isRemoteModel ? style.accent.opacity(0.32) : style.edge.opacity(0.75),
                        lineWidth: 0.75
                    )
                    .allowsHitTesting(false)
            }
            .accessibilityIdentifier("story.turn.narration.\(turn.sequence)")
        }
    }

    private func playerActionBlock(text: String, subtitle: String) -> some View {
        let style = resolvedStyle
        let cornerRadius = max(10, style.cardCornerRadius - 4)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.line")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(style.accent)
                    .accessibilityHidden(true)
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.accent)
            }
            Text(text)
                .font(style.proseFont)
                .lineSpacing(5)
                .foregroundStyle(style.foreground.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .background(style.accentSoft.opacity(0.72), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(style.accent)
                .frame(width: 2.5)
                .padding(.vertical, 10)
                .padding(.leading, 8)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private func immersiveFloatingDock(style: StoryResolvedStyle) -> some View {
        VStack(spacing: 10) {
            if externalErrorMessage != nil || submitBannerMessage != nil {
                statusBanners(style: style)
                    .padding(.horizontal, LibraryAppearance.horizontalInset)
                    .shadow(color: Color.black.opacity(style.isDark ? 0.3 : 0.1), radius: 10, x: 0, y: 3)
            }

            HStack(spacing: 10) {
                if isGeneratingRemote {
                    Button {
                        cancelRemoteGeneration(showBanner: true)
                    } label: {
                        Label("取消生成", systemImage: "stop.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(style.sealAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(minHeight: LibraryAppearance.minimumControlHeight)
                            .background(style.surface.opacity(0.95), in: Capsule())
                            .overlay {
                                Capsule()
                                    .strokeBorder(style.sealAccent.opacity(0.45), lineWidth: 0.9)
                                    .allowsHitTesting(false)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("story.immersive.cancel")
                } else {
                    Button {
                        if modelConfig == nil {
                            isPresentingModelConfig = true
                        } else {
                            exitImmersiveAndCompose()
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: modelConfig == nil ? "key" : "pencil.and.outline")
                                .font(.subheadline.weight(.semibold))
                                .accessibilityHidden(true)
                            Text(modelConfig == nil
                                 ? "配置模型"
                                 : (trimmedAction.isEmpty ? "执笔行动" : "继续草稿（\(trimmedAction.count)字）"))
                                .font(.subheadline.weight(.semibold))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(primaryButtonForeground)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .frame(minHeight: LibraryAppearance.minimumControlHeight)
                        .background(style.accent, in: Capsule())
                        .shadow(color: style.accent.opacity(style.isDark ? 0.34 : 0.22), radius: 12, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusyWithTurn)
                    .accessibilityLabel(modelConfig == nil ? "配置 BYOK 模型接口" : "展开底部行动输入栏并继续输入")
                    .accessibilityIdentifier("story.immersive.compose")
                }
            }
        }
        .padding(.bottom, 14)
    }

    private func toggleImmersiveReading() {
        StoryHaptics.selection()
        isActionFocused = false
        if reduceMotion {
            isImmersiveReading.toggle()
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                isImmersiveReading.toggle()
            }
        }
    }

    private func exitImmersiveAndCompose() {
        StoryHaptics.selection()
        if reduceMotion {
            isImmersiveReading = false
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                isImmersiveReading = false
            }
        }
        Task { @MainActor in
            await Task.yield()
            if isViewActive && isRouteActive && !isImmersiveReading && !isBusyWithTurn {
                isActionFocused = true
            }
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
        .padding(.top, 4)
    }

    private var backToHubButton: some View {
        Button {
            isActionFocused = false
            onBackToHub()
        } label: {
            Text("返回故事列表")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: appearance.secondary,
            surface: appearance.subtleSurface.opacity(0.75),
            border: appearance.edge.opacity(0.65),
            cornerRadius: 14
        ))
        .accessibilityIdentifier("story.session.backToHub")
    }

    private var newAnotherStoryButton: some View {
        Button {
            isActionFocused = false
            onNewStory(session.bookID)
        } label: {
            Text("新建另一段故事")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: appearance.accent,
            surface: appearance.accentSoft.opacity(0.75),
            border: appearance.accent.opacity(0.24),
            cornerRadius: 14
        ))
        .accessibilityIdentifier("story.session.new")
    }

    // MARK: - Clean Single-Track Action Composer

    private func statusBanners(style: StoryResolvedStyle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let externalErrorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(style.sealAccent)
                        .accessibilityHidden(true)
                    Text("未能删除本局故事：\(externalErrorMessage)")
                        .font(.caption)
                        .foregroundStyle(style.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        onDismissExternalError()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(style.secondary)
                            .frame(minWidth: 28, minHeight: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭删除错误提示")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(style.sealSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .background(style.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style.sealAccent.opacity(0.32), lineWidth: 0.7)
                        .allowsHitTesting(false)
                }
                .accessibilityIdentifier("story.session.deleteError")
            }

            if let submitBannerMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(style.sealAccent)
                        .accessibilityHidden(true)
                    Text(submitBannerMessage)
                        .font(.caption)
                        .foregroundStyle(style.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        self.submitBannerMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(style.secondary)
                            .frame(minWidth: 28, minHeight: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭提示")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(style.sealSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .background(style.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style.sealAccent.opacity(0.32), lineWidth: 0.7)
                        .allowsHitTesting(false)
                }
                .accessibilityIdentifier("story.action.banner")
            }
        }
    }

    private var actionComposerBar: some View {
        let style = resolvedStyle
        return VStack(alignment: .leading, spacing: 8) {
            if externalErrorMessage != nil || submitBannerMessage != nil {
                statusBanners(style: style)
            }
            if modelConfig == nil {
                unconfiguredModelGuideBar
            } else {
                configuredInputRow
            }
        }
        .padding(.horizontal, LibraryAppearance.horizontalInset)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(resolvedStyle.surface.opacity(0.97))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(resolvedStyle.edge.opacity(0.75))
                .frame(height: 0.5)
        }
    }

    private var unconfiguredModelGuideBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("需要配置 BYOK 模型接口")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(resolvedStyle.foreground)
                Text("配置后可输入行动，并在每次发送前预览确认")
                    .font(.caption)
                    .foregroundStyle(resolvedStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button {
                isActionFocused = false
                isPresentingModelConfig = true
            } label: {
                Text("去配置")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: LibraryAppearance.minimumControlHeight)
            }
            .buttonStyle(AppControlButtonStyle(
                foreground: primaryButtonForeground,
                surface: resolvedStyle.accent,
                cornerRadius: 14
            ))
            .accessibilityLabel("配置自带密钥模型接口以继续生成故事")
            .accessibilityIdentifier("story.action.configureModel")
        }
    }

    private var configuredInputRow: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("写下你的行动或台词…", text: $actionDraft, axis: .vertical)
                    .font(.subheadline)
                    .foregroundStyle(resolvedStyle.foreground)
                    .lineLimit(1...4)
                    .focused($isActionFocused)
                    .disabled(isBusyWithTurn)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(resolvedStyle.subtleSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                isActionTooLong
                                    ? resolvedStyle.sealAccent
                                    : (isActionFocused ? resolvedStyle.accent.opacity(0.85) : resolvedStyle.edge.opacity(0.85)),
                                lineWidth: (isActionTooLong || isActionFocused) ? 1.25 : 0.75
                            )
                            .allowsHitTesting(false)
                    }
                    .shadow(
                        color: isActionFocused ? resolvedStyle.accent.opacity(resolvedStyle.isDark ? 0.22 : 0.14) : .clear,
                        radius: 8,
                        x: 0,
                        y: 2
                    )
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isActionFocused)
                    .accessibilityIdentifier("story.action.input")

                Button {
                    triggerPrepareRemoteGeneration()
                } label: {
                    Group {
                        if isPreparingDraft || isGeneratingRemote {
                            ProgressView()
                                .tint(primaryButtonForeground)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.subheadline.weight(.bold))
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(AppControlButtonStyle(
                    foreground: primaryButtonForeground,
                    surface: resolvedStyle.accent,
                    cornerRadius: 22
                ))
                .disabled(!canSubmitRemoteAction)
                .accessibilityLabel("预览请求并确认向模型发送")
                .accessibilityIdentifier("story.action.generateRemote")
            }

            if trimmedAction.count >= Self.countHintThreshold || isActionTooLong {
                Text("\(trimmedAction.count)/\(Self.maxActionLength)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isActionTooLong ? resolvedStyle.sealAccent : resolvedStyle.secondary)
                    .padding(.trailing, 54)
                    .accessibilityIdentifier("story.action.count")
            }
        }
    }

    // MARK: - Formatting & Helpers

    private static func formatProse(_ raw: String) -> FormattedProse {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return FormattedProse(chapterHeading: nil, paragraphs: [raw])
        }

        if lines.count >= 2, looksLikeChapterHeading(lines[0]) {
            return FormattedProse(
                chapterHeading: lines[0],
                paragraphs: Array(lines.dropFirst())
            )
        }
        return FormattedProse(chapterHeading: nil, paragraphs: lines)
    }

    private static func looksLikeChapterHeading(_ line: String) -> Bool {
        let count = line.count
        guard count >= 2, count <= 36 else { return false }
        // Exclude dialogue or full prose sentences ending in terminal punctuation
        if line.hasSuffix("。") || line.hasSuffix("！") || line.hasSuffix("？")
            || line.hasSuffix("”") || line.hasSuffix("」") || line.hasSuffix("\"") {
            return false
        }
        if line.hasPrefix("第") && (line.contains("章") || line.contains("回") || line.contains("节") || line.contains("卷")) {
            return true
        }
        if line.hasPrefix("序章") || line.hasPrefix("楔子") || line.hasPrefix("尾声") || line.hasPrefix("引子") {
            return true
        }
        let lower = line.lowercased()
        if lower.hasPrefix("chapter ") || lower.hasPrefix("prologue") {
            return true
        }
        return count <= 18 && !line.contains("，") && !line.contains("。")
    }

    private func roleBadge(_ kind: StoryRoleKind) -> some View {
        let isCanon = kind == .canon
        return Text(isCanon ? "原著" : "原创")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isCanon ? appearance.accent : appearance.sealAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(isCanon ? appearance.accentSoft : appearance.sealSoft, in: Capsule())
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo("story.theater.bottom", anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.28)) {
                proxy.scrollTo("story.theater.bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Async Store & BYOK Generation Lifecycle

    private func resetForSessionChange() {
        cancelAllAsyncWork()
        turns = []
        hasLoadedTurns = false
        loadErrorMessage = nil
        submitBannerMessage = nil
        styleFeedbackMessage = nil
        activeRecipe = .standard
        isImmersiveReading = false
        actionDraft = ""
        isOpeningExpanded = true
    }

    private func cancelAllAsyncWork() {
        loadGeneration = UUID()
        activePrepareID = nil
        activeGenerateID = nil
        activeStyleID = nil
        loadTask?.cancel()
        loadTask = nil
        prepareTask?.cancel()
        prepareTask = nil
        generateTask?.cancel()
        generateTask = nil
        styleTask?.cancel()
        styleTask = nil
        pendingDraft = nil
        pendingStyleDraft = nil
        streamingActionText = ""
        streamingNarration = ""
        isLoadingTurns = false
        isPreparingDraft = false
        isGeneratingRemote = false
        isDirectingStyle = false
    }

    private func cancelStyleDirection(showBanner: Bool) {
        activeStyleID = nil
        styleTask?.cancel()
        styleTask = nil
        pendingStyleDraft = nil
        isDirectingStyle = false
        if showBanner {
            submitBannerMessage = "已取消 AI 判型，保持当前视觉风格。"
        }
    }

    private func prepareAIDirectStyle() {
        guard isViewActive, isRouteActive, !isDirectingStyle, !isDeletingSession else { return }
        guard let config = try? StoryModelVault.load() else {
            modelConfig = nil
            isPresentingModelConfig = true
            submitBannerMessage = "请先配置 OpenAI 兼容模型接口（HTTPS 或已授权的局域网 HTTP），再由 AI 判定视觉风格。"
            return
        }
        modelConfig = config
        styleFeedbackMessage = nil
        pendingStyleDraft = StoryStyleDirector.prepare(session: session, configuration: config)
    }

    private func startAIDirectStyle(draft: StoryStyleDraft) {
        guard isViewActive, isRouteActive, !isDirectingStyle, !isDeletingSession else { return }
        let targetSessionID = session.id
        let reqID = UUID()

        activeStyleID = reqID
        isDirectingStyle = true
        styleFeedbackMessage = nil
        submitBannerMessage = nil
        styleTask?.cancel()

        styleTask = Task { @MainActor in
            defer {
                if activeStyleID == reqID {
                    isDirectingStyle = false
                    activeStyleID = nil
                    styleTask = nil
                }
            }
            do {
                let recipe = try await StoryStyleDirector.generate(draft)
                guard !Task.isCancelled,
                      activeStyleID == reqID,
                      isViewActive,
                      isRouteActive,
                      session.id == targetSessionID else { return }
                if reduceMotion {
                    activeRecipe = recipe
                } else {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        activeRecipe = recipe
                    }
                }
                StoryHaptics.success()
                let resolved = StoryResolvedStyle.resolve(recipe: recipe, base: appearance)
                submitBannerMessage = "AI 已为本局切换为「\(resolved.shortLabel)」（随时可点击顶部风格胶囊对照或还原默认）。"
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      activeStyleID == reqID,
                      isViewActive,
                      isRouteActive,
                      session.id == targetSessionID else { return }
                let msg = "AI 判型失败，已维持当前风格：\(error.localizedDescription)"
                styleFeedbackMessage = msg
                submitBannerMessage = msg
            }
        }
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
        guard canSubmitRemoteAction, let service = model.service else { return }
        guard let config = try? StoryModelVault.load() else {
            modelConfig = nil
            isPresentingModelConfig = true
            submitBannerMessage = "请先配置 OpenAI 兼容模型接口（HTTPS 或已授权的局域网 HTTP）。"
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
        atmospherePulse &+= 1
        StoryHaptics.impact(.medium)
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
                StoryHaptics.success()
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
}

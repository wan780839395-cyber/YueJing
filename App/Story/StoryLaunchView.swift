import Foundation
import ReaderDomain
import SwiftUI

/// Local story launch and resume flow under Explore -> AI Story.
/// Reuses `LibraryViewModel` book catalog & import pipeline; never invokes remote AI models.
@MainActor
struct StoryLaunchView: View {
    private enum Route: Equatable {
        case hub
        case setup
        case session(StorySession)
    }

    private enum FocusField: Hashable {
        case roleName
        case premise
    }

    private static let maxRoleNameLength = 60
    private static let maxPremiseLength = 400

    @ObservedObject var model: LibraryViewModel
    let appearance: LibraryAppearance
    var isRouteActive: Bool = true
    var preselectedBookID: String? = nil

    @State private var route: Route = .hub
    @State private var consumedPreselectedBookID: String?
    @State private var sessions: [StorySession] = []
    @State private var isLoadingSessions = false
    @State private var hasLoadedSessions = false
    @State private var loadErrorMessage: String?

    @State private var selectedBookID: String?
    @State private var roleKind: StoryRoleKind = .canon
    @State private var roleName: String = ""
    @State private var premise: String = ""
    @State private var selectedPreset: StoryPresetSummary?
    @State private var isPresentingPresetManage = false
    @State private var isPresentingPresetPicker = false
    @State private var isPresentingModelConfig = false
    @State private var isStartingStory = false
    @State private var startErrorMessage: String?
    @State private var importStatusBanner: String?
    @State private var pendingDeleteSession: StorySession?
    @State private var deletingSessionID: UUID?
    @State private var deleteErrorMessage: String?

    @State private var pendingImportTicket: UUID?
    @State private var isViewActive = false
    @State private var loadGeneration = UUID()
    @State private var loadTask: Task<Void, Never>?
    @State private var activeStartRequestID: UUID?
    @State private var startTask: Task<Void, Never>?
    @State private var activeDeleteRequestID: UUID?
    @State private var deleteTask: Task<Void, Never>?
    @State private var hubAtmospherePulse = 0

    @FocusState private var focusedField: FocusField?
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedBook: LibraryBook? {
        guard let selectedBookID else { return nil }
        return model.books.first { $0.id == selectedBookID }
    }

    private var trimmedRoleName: String {
        roleName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPremise: String {
        premise.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isRoleNameTooLong: Bool {
        trimmedRoleName.count > Self.maxRoleNameLength
    }

    private var isPremiseTooLong: Bool {
        trimmedPremise.count > Self.maxPremiseLength
    }

    private var isRoleInputValid: Bool {
        !trimmedRoleName.isEmpty && !isRoleNameTooLong && !isPremiseTooLong
    }

    private var canTriggerImport: Bool {
        isRouteActive && model.canBeginFileSelection && !isStartingStory
    }

    private var canSubmitStory: Bool {
        isRouteActive && model.service != nil && selectedBook != nil
            && isRoleInputValid && !isStartingStory
            && !model.importing && !model.deletingBook && model.canPresentLibraryFeedback
    }

    private var navigationTitleText: String {
        switch route {
        case .hub:
            return "AI 故事"
        case .setup:
            return "新建故事"
        case .session:
            return "故事剧场"
        }
    }

    var body: some View {
        ZStack {
            appearance.page.ignoresSafeArea()

            if case .session = route {
                EmptyView()
            } else {
                StoryAtmosphereCanvas(appearance: appearance, pulseToken: hubAtmospherePulse)
                    .ignoresSafeArea()
            }

            Group {
                switch route {
                case .hub:
                    hubContent
                case .setup:
                    setupContent
                case .session(let activeSession):
                    sessionContent(activeSession)
                }
            }
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.985)),
                removal: .opacity
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(appearance.foreground)
        .tint(appearance.accent)
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(route != .hub)
        .toolbarBackground(appearance.page, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(appearance.controlColorScheme, for: .navigationBar)
        .toolbar {
            if route != .hub {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        returnToHub()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.subheadline.weight(.semibold))
                                .accessibilityHidden(true)
                            Text("故事列表")
                                .font(AppVisualStyle.actionFont)
                        }
                        .foregroundStyle(appearance.accent)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 44, minHeight: LibraryAppearance.minimumControlHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(AppControlButtonStyle(foreground: appearance.accent, cornerRadius: 12))
                    .accessibilityLabel("返回故事列表")
                    .accessibilityIdentifier("story.nav.back")
                }
            }
            if route == .hub {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 6) {
                        Button {
                            isPresentingModelConfig = true
                        } label: {
                            Image(systemName: "key")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(appearance.accent)
                                .frame(minWidth: 36, minHeight: LibraryAppearance.minimumControlHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(AppControlButtonStyle(
                            foreground: appearance.accent,
                            surface: appearance.accentSoft,
                            border: appearance.accent.opacity(0.28),
                            cornerRadius: 12
                        ))
                        .accessibilityLabel("配置 BYOK 模型接口")
                        .accessibilityIdentifier("story.model.open")

                        Button {
                            isPresentingPresetManage = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.caption.weight(.semibold))
                                    .accessibilityHidden(true)
                                Text("预设")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(appearance.accent)
                            .padding(.horizontal, 10)
                            .frame(minWidth: 44, minHeight: LibraryAppearance.minimumControlHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(AppControlButtonStyle(
                            foreground: appearance.accent,
                            surface: appearance.accentSoft,
                            border: appearance.accent.opacity(0.28),
                            cornerRadius: 12
                        ))
                        .disabled(model.service == nil)
                        .accessibilityLabel("管理与导入叙事预设")
                        .accessibilityIdentifier("story.presets.open")
                    }
                }
            }
        }
        .sheet(isPresented: $isPresentingModelConfig) {
            StoryModelConfigSheet(appearance: appearance) { _ in }
        }
        .sheet(isPresented: $isPresentingPresetManage) {
            StoryPresetWorkshopView(
                model: model,
                appearance: appearance,
                mode: .manage
            )
        }
        .sheet(isPresented: $isPresentingPresetPicker) {
            StoryPresetWorkshopView(
                model: model,
                appearance: appearance,
                mode: .pick(selectedID: selectedPreset?.id) { chosen in
                    selectedPreset = chosen
                }
            )
        }
        .confirmationDialog(
            "删除这段故事？",
            isPresented: Binding(
                get: { pendingDeleteSession != nil },
                set: { presented in
                    if !presented { pendingDeleteSession = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteSession
        ) { target in
            Button("删除故事与全部回合", role: .destructive) {
                confirmDeleteSession(target)
            }
            .accessibilityIdentifier("story.delete.confirm")
            Button("取消", role: .cancel) {
                pendingDeleteSession = nil
            }
            .accessibilityIdentifier("story.delete.cancel")
        } message: { target in
            Text("《\(target.bookTitle)》 · \(Self.roleKindTitle(target.roleKind))「\(target.roleName)」\n创建时间：\(target.createdAt.formatted(date: .numeric, time: .shortened))\n\n将永久删除这段故事及其中所有已保存回合，不会删除书架中的原书或阅读书签。")
        }
        .accessibilityIdentifier("story.screen")
        .onAppear {
            isViewActive = true
            handleStoryImport(model.lastStoryImport)
            applyPreselectedBookIfNeeded()
        }
        .task {
            isViewActive = true
            await loadSessions()
        }
        .onDisappear {
            handleDisappear()
        }
        .onChange(of: isRouteActive) { active in
            if !active {
                tearDownAllAsyncWork(clearPendingImport: true)
            }
        }
        .onChange(of: model.service != nil) { available in
            if available && isRouteActive && isViewActive && !hasLoadedSessions {
                triggerReloadSessions()
            }
        }
        .onChange(of: model.books) { currentBooks in
            if let selectedBookID, !currentBooks.contains(where: { $0.id == selectedBookID }) {
                self.selectedBookID = nil
            }
        }
        .onChange(of: model.lastStoryImport) { event in
            handleStoryImport(event)
        }
        .onChange(of: model.importDiagnostics) { diagnostics in
            clearPendingImportIfTerminated(diagnostics)
        }
        .onChange(of: preselectedBookID) { _ in
            applyPreselectedBookIfNeeded()
        }
    }

    // MARK: - Hub View

    private var hubContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hubHeader

                if model.service == nil {
                    serviceUnavailableCard
                } else if isLoadingSessions && sessions.isEmpty {
                    loadingCard
                } else {
                    if let loadErrorMessage {
                        loadErrorCard(message: loadErrorMessage)
                    }

                    if let deleteErrorMessage {
                        deleteErrorBanner(message: deleteErrorMessage)
                    }

                    if sessions.isEmpty && loadErrorMessage == nil {
                        emptySessionsCard
                    } else if !sessions.isEmpty {
                        newStoryActionRow
                        sessionsSection
                    } else {
                        newStoryActionRow
                    }
                }
            }
            .padding(.horizontal, LibraryAppearance.horizontalInset)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
    }

    private var hubHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("AI 故事 · BYOK 模型生成")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(appearance.accentSoft, in: Capsule())
                Spacer(minLength: 8)
            }
            Text("从书架开启 AI 故事")
                .font(AppVisualStyle.sectionTitleFont)
                .foregroundStyle(appearance.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("选一本已导入或新导入的小说，设定原著或原创角色并可选绑定叙事预设；配置自带密钥（BYOK）模型后，每次行动经你预览确认即可生成新剧情，记录保存在本地可随时恢复。")
                .font(.subheadline)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(appearance.accent)
            Text("正在读取本地故事记录…")
                .font(.subheadline)
                .foregroundStyle(appearance.secondary)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay {
            cardBorder(appearance.edge.opacity(0.8))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("story.sessions.loading")
    }

    private var serviceUnavailableCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("书架服务尚未就绪")
                .font(.headline)
                .foregroundStyle(appearance.foreground)
            Text("请等待书架初始化完成后再进入本地故事开局。")
                .font(.subheadline)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay {
            cardBorder(appearance.edge.opacity(0.8))
        }
    }

    private func loadErrorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(appearance.sealAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("未能读取本地故事记录")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appearance.foreground)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                triggerReloadSessions()
            } label: {
                Label("重新读取", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: LibraryAppearance.minimumControlHeight)
            }
            .buttonStyle(AppControlButtonStyle(
                foreground: appearance.accent,
                surface: appearance.accentSoft,
                border: appearance.accent.opacity(0.28),
                cornerRadius: 16
            ))
            .disabled(isLoadingSessions)
            .accessibilityIdentifier("story.sessions.retry")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay {
            cardBorder(appearance.sealAccent.opacity(0.45))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("story.sessions.error")
    }

    private var emptySessionsCard: some View {
        VStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(appearance.accentSoft)
                Image(systemName: "sparkles")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(appearance.accent)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("还没有本地故事开局")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(appearance.foreground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("基于已导入的小说或现场导入 TXT / EPUB，选择原著或原创角色即可开启故事并保存在本地，随时可继续阅读与推进。")
                    .font(.subheadline)
                    .foregroundStyle(appearance.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                openSetup(preselectedBookID: nil)
            } label: {
                Label("选择小说开始", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22)
                    .frame(minHeight: 48)
            }
            .buttonStyle(AppControlButtonStyle(
                foreground: primaryButtonForeground,
                surface: appearance.accent,
                cornerRadius: 24
            ))
            .accessibilityHint("选择书架小说或导入新书，设定角色并开启故事")
            .accessibilityIdentifier("story.action.new")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.8), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: appearance.cardShadow, radius: 10, x: 0, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("story.sessions.empty")
    }

    private var newStoryActionRow: some View {
        Button {
            openSetup(preselectedBookID: nil)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.body.weight(.semibold))
                    .accessibilityHidden(true)
                Text("新建故事")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: primaryButtonForeground,
            surface: appearance.accent,
            cornerRadius: 18
        ))
        .accessibilityHint("选择小说与角色，开启一段新故事")
        .accessibilityIdentifier("story.action.new")
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: "已保存的故事", badge: "\(sessions.count)")

            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, item in
                sessionItemContainer(item, isLatest: index == 0)
            }

            Text("原书从书架删除后，对应的本地故事记录也会一并清除。")
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private func deleteErrorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(appearance.sealAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("未能删除故事")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.foreground)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button {
                deleteErrorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(appearance.secondary)
                    .frame(minWidth: 28, minHeight: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭删除错误提示")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.sealSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(appearance.sealAccent.opacity(0.42), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("story.delete.error")
    }

    private func sessionItemContainer(_ item: StorySession, isLatest: Bool) -> some View {
        let isDeletingThis = deletingSessionID == item.id
        return ZStack(alignment: .topTrailing) {
            Button {
                openSession(item)
            } label: {
                sessionRowCard(item, isLatest: isLatest, isDeleting: isDeletingThis)
            }
            .buttonStyle(AppControlButtonStyle(foreground: appearance.foreground, cornerRadius: LibraryAppearance.cardCornerRadius))
            .disabled(deletingSessionID != nil)
            .accessibilityLabel("继续故事，\(item.bookTitle)，\(Self.roleKindTitle(item.roleKind))，\(item.roleName)")
            .accessibilityHint("打开已保存的角色信息与书内开篇")
            .accessibilityIdentifier("story.session.item.\(item.id.uuidString)")
            .contextMenu {
                Button(role: .destructive) {
                    requestDeleteSession(item)
                } label: {
                    Label("删除此故事", systemImage: "trash")
                }
                .disabled(deletingSessionID != nil)
            }

            Menu {
                Button(role: .destructive) {
                    requestDeleteSession(item)
                } label: {
                    Label("删除此故事", systemImage: "trash")
                }
            } label: {
                Group {
                    if isDeletingThis {
                        ProgressView()
                            .tint(appearance.sealAccent)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(appearance.secondary)
                    }
                }
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
            }
            .disabled(deletingSessionID != nil)
            .padding(.top, 10)
            .padding(.trailing, 10)
            .accessibilityLabel("更多操作，\(item.bookTitle)，\(item.roleName)")
            .accessibilityIdentifier("story.session.menu.\(item.id.uuidString)")
        }
    }

    private func sessionRowCard(_ item: StorySession, isLatest: Bool, isDeleting: Bool = false) -> some View {
        Group {
            if isLatest {
                heroPortalCard(item, isDeleting: isDeleting)
            } else {
                archiveStoryCard(item, isDeleting: isDeleting)
            }
        }
        .opacity(isDeleting ? 0.55 : 1.0)
        .scaleEffect(isDeleting ? 0.98 : 1.0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isDeleting)
    }

    private func heroPortalCard(_ item: StorySession, isDeleting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                    Text("最近入戏")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(appearance.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(appearance.accentSoft, in: Capsule())

                roleBadge(item.roleKind)
                Spacer(minLength: 6)
                Text(item.createdAt.formatted(date: .numeric, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(appearance.secondary)
                    .padding(.trailing, 30)
            }

            HStack(alignment: .center, spacing: 14) {
                StoryLivingSigilView(
                    roleKind: item.roleKind,
                    roleName: item.roleName,
                    appearance: appearance,
                    size: dynamicType.isAccessibilitySize ? 44 : 56
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text("《\(item.bookTitle)》")
                        .font(.system(.title3, design: .serif).weight(.bold))
                        .foregroundStyle(appearance.foreground)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("扮演 · \(item.roleName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appearance.accent)
                        .fixedSize(horizontal: false, vertical: true)

                    if !item.premise.isEmpty {
                        Text(item.premise)
                            .font(.caption)
                            .foregroundStyle(appearance.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(appearance.accent.opacity(0.65))
                    .frame(width: 2)
                    .accessibilityHidden(true)
                Text(item.opening)
                    .font(.system(.footnote, design: .serif))
                    .lineSpacing(4)
                    .foregroundStyle(appearance.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            HStack {
                Text(isDeleting ? "正在删除…" : "继续这段书境")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.accent)
                Spacer(minLength: 8)
                Image(systemName: "arrow.right.circle.fill")
                    .font(.body)
                    .foregroundStyle(appearance.accent)
                    .accessibilityHidden(true)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    appearance.surface,
                    appearance.surface.opacity(0.92),
                    appearance.accentSoft.opacity(appearance.isDarkSurface ? 0.35 : 0.45)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            StoryShimmerBorder(cornerRadius: 22, appearance: appearance)
        }
        .shadow(color: appearance.cardShadow, radius: 12, x: 0, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func archiveStoryCard(_ item: StorySession, isDeleting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                roleBadge(item.roleKind)
                Spacer(minLength: 8)
                Text(item.createdAt.formatted(date: .numeric, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(appearance.secondary)
                    .padding(.trailing, 30)
            }

            HStack(alignment: .center, spacing: 12) {
                StorySoulSigilView(
                    roleKind: item.roleKind,
                    roleName: item.roleName,
                    appearance: appearance,
                    size: 38
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.bookTitle)
                        .font(.system(.headline, design: .serif).weight(.semibold))
                        .foregroundStyle(appearance.foreground)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("扮演：\(item.roleName)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(appearance.foreground.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(appearance.secondary.opacity(0.65))
                            .accessibilityHidden(true)
                    }
                }
            }

            if !item.premise.isEmpty {
                Text(item.premise)
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Text(item.opening)
                .font(.system(.footnote, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(appearance.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay {
            cardBorder(appearance.edge.opacity(0.8))
        }
        .shadow(color: appearance.cardShadow, radius: 6, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
    }

    // MARK: - Setup View

    private var setupContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                bookSelectionSection
                roleSetupSection
                presetSelectionSection
                if let startErrorMessage {
                    startErrorCard(message: startErrorMessage)
                }
                startActionSection
            }
            .padding(.horizontal, LibraryAppearance.horizontalInset)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var presetSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "3. 叙事预设（可选）", badge: selectedPreset == nil ? "已跳过" : "已选用")

            VStack(alignment: .leading, spacing: 12) {
                if let preset = selectedPreset {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(appearance.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("版本指纹 · \(StoryPresetWorkshopView.shortHash(preset.id)) · 开局后锁定（用于确认后的模型生成）")
                                .font(.caption.monospaced())
                                .foregroundStyle(appearance.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                    }
                } else {
                    Text("默认跳过预设。如需绑定 ST Chat Completion JSON 版本供确认后的 BYOK 模型生成使用，可从预设工坊导入并选用无问题版本。")
                        .font(.footnote)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        presetPickerTriggerButton
                        if selectedPreset != nil {
                            clearPresetButton
                        }
                    }
                    VStack(spacing: 8) {
                        presetPickerTriggerButton
                        if selectedPreset != nil {
                            clearPresetButton
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
            .overlay {
                cardBorder(selectedPreset != nil ? appearance.accent.opacity(0.45) : appearance.edge.opacity(0.8))
            }
            .shadow(color: appearance.cardShadow, radius: 6, x: 0, y: 2)
        }
    }

    private var presetPickerTriggerButton: some View {
        Button {
            focusedField = nil
            isPresentingPresetPicker = true
        } label: {
            Label(selectedPreset == nil ? "选择或导入预设 JSON" : "更换预设版本", systemImage: "slider.horizontal.3")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: LibraryAppearance.minimumControlHeight)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: appearance.accent,
            surface: appearance.accentSoft,
            border: appearance.accent.opacity(0.28),
            cornerRadius: 14
        ))
        .disabled(isStartingStory || model.service == nil)
        .accessibilityIdentifier("story.setup.selectPreset")
    }

    private var clearPresetButton: some View {
        Button {
            selectedPreset = nil
        } label: {
            Text("改为跳过")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: LibraryAppearance.minimumControlHeight)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: appearance.secondary,
            surface: appearance.subtleSurface,
            border: appearance.edge.opacity(0.8),
            cornerRadius: 14
        ))
        .disabled(isStartingStory)
        .accessibilityIdentifier("story.setup.clearPreset")
    }

    private var bookSelectionSection: some View {
        let titleCounts = Dictionary(grouping: model.books, by: \.title).mapValues(\.count)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                sectionHeader(title: "1. 选择小说", badge: model.books.isEmpty ? nil : "\(model.books.count)")
                Spacer(minLength: 8)
                if !model.books.isEmpty {
                    Button {
                        beginImportBook()
                    } label: {
                        Label("导入新书", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(minHeight: LibraryAppearance.minimumControlHeight)
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(AppControlButtonStyle(
                        foreground: appearance.accent,
                        surface: appearance.accentSoft,
                        border: appearance.accent.opacity(0.28),
                        cornerRadius: 16
                    ))
                    .disabled(!canTriggerImport)
                    .accessibilityHint("打开文件选择器导入 TXT 或本地非 DRM EPUB，成功后自动选中")
                    .accessibilityIdentifier("story.setup.importBook")
                }
            }

            if model.importing {
                importingProgressCard
            }

            if let importStatusBanner {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(appearance.accent)
                        .accessibilityHidden(true)
                    Text(importStatusBanner)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(appearance.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(appearance.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityIdentifier("story.setup.importNotice")
            }

            if model.books.isEmpty {
                emptyShelfSetupCard
            } else {
                VStack(spacing: 10) {
                    ForEach(model.books) { book in
                        bookChoiceRow(
                            book,
                            selected: book.id == selectedBookID,
                            showsEditionDetails: (titleCounts[book.title] ?? 0) > 1
                        )
                    }
                }
            }
        }
    }

    private var emptyShelfSetupCard: some View {
        VStack(alignment: .center, spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.title2.weight(.medium))
                .foregroundStyle(appearance.accent)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("书架还没有导入小说")
                    .font(.system(.headline, design: .serif).weight(.semibold))
                    .foregroundStyle(appearance.foreground)
                    .multilineTextAlignment(.center)
                Text("支持导入本地 TXT 与非 DRM 可重排 EPUB。导入成功后会自动入架并选中这本书。")
                    .font(.footnote)
                    .foregroundStyle(appearance.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                beginImportBook()
            } label: {
                Label("导入 TXT / EPUB", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .frame(minHeight: 46)
            }
            .buttonStyle(AppControlButtonStyle(
                foreground: primaryButtonForeground,
                surface: appearance.accent,
                cornerRadius: 22
            ))
            .disabled(!canTriggerImport)
            .accessibilityHint("打开系统文件选择器导入书籍")
            .accessibilityIdentifier("story.setup.importBook")
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay {
            cardBorder(appearance.edge.opacity(0.8))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("story.setup.emptyShelf")
    }

    private var importingProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(appearance.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.importPresentation.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appearance.foreground)
                    Text(model.importPresentation.detail)
                        .font(.caption)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Button {
                Task { await model.cancelImport() }
            } label: {
                Text(model.importPresentation.stopRequested ? "正在停止…" : "停止准备")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: LibraryAppearance.minimumControlHeight)
            }
            .buttonStyle(AppControlButtonStyle(
                foreground: appearance.sealAccent,
                surface: appearance.sealSoft,
                border: appearance.sealAccent.opacity(0.28),
                cornerRadius: 14
            ))
            .disabled(model.importPresentation.stopRequested)
            .accessibilityIdentifier("story.setup.cancelImport")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay {
            cardBorder(appearance.accent.opacity(0.35))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("story.setup.importing")
    }

    private func bookChoiceRow(_ book: LibraryBook, selected: Bool, showsEditionDetails: Bool) -> some View {
        Button {
            focusedField = nil
            startErrorMessage = nil
            importStatusBanner = nil
            if reduceMotion {
                selectedBookID = book.id
            } else {
                withAnimation(ReaderMotion.selectionFeedback) {
                    selectedBookID = book.id
                }
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                LibraryBookCoverView(
                    book: book,
                    appearance: appearance,
                    size: CGSize(width: 40, height: 56),
                    coverLoader: model.coverLoader
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(book.title)
                        .font(LibraryAppearance.bookTitleFont)
                        .foregroundStyle(appearance.foreground)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Text(book.format == .epub ? "EPUB" : "TXT")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(book.format == .epub ? appearance.accent : appearance.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(
                                book.format == .epub ? appearance.accentSoft : appearance.subtleSurface,
                                in: Capsule()
                            )
                        if let volume = LibraryBookMetrics.volumeLabel(for: book) {
                            Text(volume)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(appearance.secondary)
                        }
                    }

                    if showsEditionDetails {
                        Text("同名副本 · \(LibraryBookMetrics.editionSummary(for: book))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(appearance.sealAccent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? appearance.accent : appearance.secondary.opacity(0.45))
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: LibraryAppearance.minimumControlHeight, alignment: .leading)
            .background(appearance.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(appearance.accentSoft.opacity(appearance.isDarkSurface ? 0.40 : 0.25))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        selected ? appearance.accent : appearance.edge.opacity(0.8),
                        lineWidth: selected ? 1.5 : 0.75
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isStartingStory)
        .accessibilityLabel("\(book.title)，\(book.format == .epub ? "EPUB" : "TXT")")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("story.setup.book.\(book.id)")
    }

    private var roleSetupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: "2. 角色铸印", badge: nil)

            VStack(alignment: .leading, spacing: 16) {
                // Live reactive sigil preview card
                HStack(spacing: 14) {
                    StoryLivingSigilView(
                        roleKind: roleKind,
                        roleName: trimmedRoleName,
                        appearance: appearance,
                        size: dynamicType.isAccessibilitySize ? 42 : 52
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        roleBadge(roleKind)
                        Text(trimmedRoleName.isEmpty ? "等待角色名…" : trimmedRoleName)
                            .font(.system(.headline, design: .serif).weight(.bold))
                            .foregroundStyle(trimmedRoleName.isEmpty ? appearance.secondary : appearance.foreground)
                            .lineLimit(2)
                        Text(selectedBook.map { "即将踏入《\($0.title)》" } ?? "选择一本小说后即可生成星印开局")
                            .font(.caption)
                            .foregroundStyle(appearance.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(appearance.subtleSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("角色来源")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(appearance.foreground)

                    Group {
                        if dynamicType.isAccessibilitySize {
                            VStack(spacing: 8) {
                                roleKindButton(.canon)
                                roleKindButton(.original)
                            }
                        } else {
                            HStack(spacing: 10) {
                                roleKindButton(.canon)
                                roleKindButton(.original)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("角色名（必填）")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(appearance.foreground)
                        Spacer(minLength: 8)
                        Text("\(trimmedRoleName.count)/\(Self.maxRoleNameLength)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(isRoleNameTooLong ? appearance.sealAccent : appearance.secondary)
                    }

                    TextField(
                        roleKind == .canon ? "输入书中原著角色名" : "输入你想扮演的原创角色名",
                        text: $roleName
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(false)
                    .focused($focusedField, equals: .roleName)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .premise }
                    .disabled(isStartingStory)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .frame(minHeight: LibraryAppearance.minimumControlHeight)
                    .background(appearance.subtleSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isRoleNameTooLong ? appearance.sealAccent : appearance.edge.opacity(0.85),
                                lineWidth: 0.85
                            )
                            .allowsHitTesting(false)
                    }
                    .accessibilityIdentifier("story.setup.roleName")

                    if isRoleNameTooLong {
                        Text("角色名不能超过 \(Self.maxRoleNameLength) 字。")
                            .font(.caption)
                            .foregroundStyle(appearance.sealAccent)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("身份或切入说明（选填）")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(appearance.foreground)
                        Spacer(minLength: 8)
                        Text("\(trimmedPremise.count)/\(Self.maxPremiseLength)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(isPremiseTooLong ? appearance.sealAccent : appearance.secondary)
                    }

                    TextField(
                        roleKind == .canon ? "可选：切入章节、立场或开局想法" : "可选：简短身份、性格或入场方式",
                        text: $premise,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .focused($focusedField, equals: .premise)
                    .disabled(isStartingStory)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: 88, alignment: .topLeading)
                    .background(appearance.subtleSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isPremiseTooLong ? appearance.sealAccent : appearance.edge.opacity(0.85),
                                lineWidth: 0.85
                            )
                            .allowsHitTesting(false)
                    }
                    .accessibilityIdentifier("story.setup.premise")

                    if isPremiseTooLong {
                        Text("身份说明不能超过 \(Self.maxPremiseLength) 字。")
                            .font(.caption)
                            .foregroundStyle(appearance.sealAccent)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
            .overlay {
                cardBorder(appearance.edge.opacity(0.8))
            }
            .shadow(color: appearance.cardShadow, radius: 6, x: 0, y: 2)
        }
    }

    private func roleKindButton(_ kind: StoryRoleKind) -> some View {
        let selected = roleKind == kind
        let title = Self.roleKindTitle(kind)
        let subtitle = kind == .canon ? "扮演原书已有角色" : "以新身份进入故事"
        let tint = kind == .canon ? appearance.accent : appearance.sealAccent
        let soft = kind == .canon ? appearance.accentSoft : appearance.sealSoft
        return Button {
            startErrorMessage = nil
            if reduceMotion {
                roleKind = kind
            } else {
                withAnimation(ReaderMotion.selectionFeedback) {
                    roleKind = kind
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? tint : appearance.foreground)
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline)
                        .foregroundStyle(selected ? tint : appearance.secondary.opacity(0.45))
                        .accessibilityHidden(true)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: LibraryAppearance.minimumControlHeight, alignment: .leading)
            .background(selected ? soft : appearance.subtleSurface.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? tint : appearance.edge.opacity(0.7), lineWidth: selected ? 1.4 : 0.75)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isStartingStory)
        .accessibilityLabel("\(title)，\(subtitle)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("story.setup.roleKind.\(kind.rawValue)")
    }

    private func startErrorCard(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(appearance.sealAccent)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(appearance.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.sealSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(appearance.sealAccent.opacity(0.38), lineWidth: 0.85)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("story.setup.error")
    }

    private var startActionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                beginStartStory()
            } label: {
                HStack(spacing: 8) {
                    if isStartingStory {
                        ProgressView()
                            .tint(primaryButtonForeground)
                        Text("正在读取书内开篇…")
                            .font(.subheadline.weight(.semibold))
                    } else {
                        Image(systemName: "book.closed")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityHidden(true)
                        Text("进入故事剧场")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(AppControlButtonStyle(
                foreground: primaryButtonForeground,
                surface: appearance.accent,
                cornerRadius: 18
            ))
            .disabled(!canSubmitStory)
            .accessibilityHint("读取书内真实开篇并在本地创建故事存档，进入剧场后再按需发起模型生成")
            .accessibilityIdentifier("story.setup.start")

            Text(setupSubmitHint)
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var setupSubmitHint: String {
        if model.importing {
            return "正在导入书籍，请等待导入完成后再进入故事。"
        }
        if selectedBook == nil {
            return "请先选择一本小说，或点击“导入新书”。"
        }
        if trimmedRoleName.isEmpty {
            return "请填写角色名（1–\(Self.maxRoleNameLength) 字）。"
        }
        if isRoleNameTooLong || isPremiseTooLong {
            return "请将角色名控制在 \(Self.maxRoleNameLength) 字以内、身份说明控制在 \(Self.maxPremiseLength) 字以内。"
        }
        return "将读取书内真实开篇并在本地保存故事存档（此步不联网）；进入剧场后可配置 BYOK 模型并经确认生成新回合。"
    }

    // MARK: - Active Session View

    private func sessionContent(_ active: StorySession) -> some View {
        StorySessionTheaterView(
            session: active,
            model: model,
            appearance: appearance,
            isRouteActive: isRouteActive,
            isDeletingSession: deletingSessionID == active.id,
            externalErrorMessage: deleteErrorMessage,
            onDismissExternalError: {
                deleteErrorMessage = nil
            },
            onBackToHub: {
                returnToHub()
            },
            onNewStory: { bookID in
                let matchingBook = model.books.contains { $0.id == bookID } ? bookID : nil
                openSetup(preselectedBookID: matchingBook)
            },
            onRequestDelete: {
                requestDeleteSession(active)
            }
        )
    }

    // MARK: - Shared Styling Helpers

    private var primaryButtonForeground: Color {
        appearance.isDarkSurface ? Color.black.opacity(0.9) : Color.white
    }

    private func sectionHeader(title: String, badge: String?) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(appearance.accent)
                .frame(width: 3, height: 15)
                .accessibilityHidden(true)
            Text(title)
                .font(LibraryAppearance.sectionTitleFont)
                .foregroundStyle(appearance.foreground)
                .accessibilityAddTraits(.isHeader)
            if let badge {
                Text(badge)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(appearance.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(appearance.accentSoft, in: Capsule())
            }
        }
    }

    private func roleBadge(_ kind: StoryRoleKind) -> some View {
        let isCanon = kind == .canon
        return Text(Self.roleKindTitle(kind))
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

    // MARK: - Actions & Async Lifecycle

    private func applyPreselectedBookIfNeeded() {
        guard let targetBookID = preselectedBookID else {
            consumedPreselectedBookID = nil
            return
        }
        guard isRouteActive,
              consumedPreselectedBookID != targetBookID,
              model.books.contains(where: { $0.id == targetBookID }) else {
            return
        }
        consumedPreselectedBookID = targetBookID
        openSetup(preselectedBookID: targetBookID)
    }

    private func openSetup(preselectedBookID: String?) {
        focusedField = nil
        cancelActiveStart()
        selectedBookID = preselectedBookID
        roleKind = .canon
        roleName = ""
        premise = ""
        selectedPreset = nil
        startErrorMessage = nil
        importStatusBanner = nil
        pendingImportTicket = nil
        route = .setup
    }

    private func openSession(_ session: StorySession) {
        StoryHaptics.selection()
        focusedField = nil
        cancelActiveStart()
        pendingImportTicket = nil
        hubAtmospherePulse &+= 1
        if reduceMotion {
            route = .session(session)
        } else {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                route = .session(session)
            }
        }
    }

    private func returnToHub() {
        focusedField = nil
        cancelActiveStart()
        pendingImportTicket = nil
        importStatusBanner = nil
        startErrorMessage = nil
        route = .hub
        triggerReloadSessions()
    }

    private func beginImportBook() {
        guard canTriggerImport else { return }
        focusedField = nil
        startErrorMessage = nil
        let previousSelectionID = model.fileSelection?.id
        model.beginFileSelection()
        if let newID = model.fileSelection?.id, newID != previousSelectionID {
            pendingImportTicket = newID
            importStatusBanner = nil
        }
    }

    private func handleStoryImport(_ event: StoryImportEvent?) {
        guard isRouteActive, isViewActive,
              let event, let pending = pendingImportTicket,
              event.id == pending else { return }
        pendingImportTicket = nil
        selectedBookID = event.book.id
        startErrorMessage = nil
        importStatusBanner = "已自动选中《\(event.book.title)》"
    }

    private func clearPendingImportIfTerminated(_ diagnostics: ImportDiagnosticState) {
        guard let pending = pendingImportTicket, diagnostics.attempt == pending else { return }
        let terminalCallback: Bool
        switch diagnostics.callback {
        case .delegateCancelled, .cancelled, .empty, .failed:
            terminalCallback = true
        case .none, .selected:
            terminalCallback = false
        }
        let terminalStage: Bool
        switch diagnostics.stage {
        case .cancelled, .failed, .pickerHandoffMissing,
             .rejectedUnavailable, .rejectedBusy, .alertRequested:
            terminalStage = true
        default:
            terminalStage = false
        }
        if terminalCallback || terminalStage {
            pendingImportTicket = nil
        }
    }

    private func triggerReloadSessions() {
        guard isRouteActive, isViewActive else { return }
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            await loadSessions()
        }
    }

    private func loadSessions() async {
        guard isRouteActive, isViewActive, let service = model.service else { return }
        let generation = UUID()
        loadGeneration = generation
        isLoadingSessions = true
        loadErrorMessage = nil
        defer {
            if loadGeneration == generation {
                isLoadingSessions = false
            }
        }
        do {
            let loaded = try await service.store.storySessions()
            guard isRouteActive, isViewActive, !Task.isCancelled, loadGeneration == generation else { return }
            sessions = loaded
            hasLoadedSessions = true
        } catch is CancellationError {
            return
        } catch {
            guard isRouteActive, isViewActive, !Task.isCancelled, loadGeneration == generation else { return }
            loadErrorMessage = Self.safeStoryErrorMessage(error)
        }
    }

    private func beginStartStory() {
        guard canSubmitStory, startTask == nil, let service = model.service, let book = selectedBook else { return }
        focusedField = nil
        let name = trimmedRoleName
        let detail = trimmedPremise
        let kind = roleKind
        let presetID = selectedPreset?.id
        guard !name.isEmpty, name.count <= Self.maxRoleNameLength, detail.count <= Self.maxPremiseLength else {
            startErrorMessage = StoryLaunchError.invalidRole.errorDescription
            return
        }

        let requestID = UUID()
        activeStartRequestID = requestID
        isStartingStory = true
        startErrorMessage = nil
        pendingImportTicket = nil

        startTask = Task { @MainActor in
            defer {
                if activeStartRequestID == requestID {
                    isStartingStory = false
                    activeStartRequestID = nil
                    startTask = nil
                }
            }
            do {
                let created = try await service.startStory(
                    book: book,
                    roleKind: kind,
                    roleName: name,
                    premise: detail,
                    presetID: presetID
                )
                guard isRouteActive, isViewActive, !Task.isCancelled, activeStartRequestID == requestID else { return }
                sessions.removeAll { $0.id == created.id }
                sessions.insert(created, at: 0)
                hasLoadedSessions = true
                loadErrorMessage = nil
                route = .session(created)
            } catch is CancellationError {
                return
            } catch {
                guard isRouteActive, isViewActive, !Task.isCancelled, activeStartRequestID == requestID else { return }
                startErrorMessage = Self.safeStoryErrorMessage(error)
            }
        }
    }

    private func cancelActiveStart() {
        activeStartRequestID = nil
        startTask?.cancel()
        startTask = nil
        isStartingStory = false
    }

    private func requestDeleteSession(_ target: StorySession) {
        guard isRouteActive, isViewActive, deletingSessionID == nil, model.service != nil else { return }
        deleteErrorMessage = nil
        pendingDeleteSession = target
    }

    private func confirmDeleteSession(_ target: StorySession) {
        guard isRouteActive, isViewActive, deletingSessionID == nil, let store = model.service?.store else {
            pendingDeleteSession = nil
            return
        }
        pendingDeleteSession = nil
        deleteErrorMessage = nil

        let requestID = UUID()
        activeDeleteRequestID = requestID
        deletingSessionID = target.id
        deleteTask?.cancel()

        deleteTask = Task { @MainActor in
            defer {
                if activeDeleteRequestID == requestID {
                    deletingSessionID = nil
                    activeDeleteRequestID = nil
                    deleteTask = nil
                }
            }
            do {
                try await store.deleteStorySession(id: target.id)
                guard !Task.isCancelled,
                      activeDeleteRequestID == requestID,
                      isRouteActive,
                      isViewActive else { return }

                let removeBlock = {
                    sessions.removeAll { $0.id == target.id }
                }
                if reduceMotion {
                    removeBlock()
                } else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        removeBlock()
                    }
                }

                if case .session(let active) = route, active.id == target.id {
                    route = .hub
                }
                StoryHaptics.success()
                hubAtmospherePulse &+= 1
                triggerReloadSessions()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      activeDeleteRequestID == requestID,
                      isRouteActive,
                      isViewActive else { return }
                deleteErrorMessage = Self.safeStoryErrorMessage(error)
            }
        }
    }

    private func cancelActiveDelete() {
        activeDeleteRequestID = nil
        deleteTask?.cancel()
        deleteTask = nil
        deletingSessionID = nil
        pendingDeleteSession = nil
    }

    private func handleDisappear() {
        // Keep pendingImportTicket while this route stays active and the matching ticket is still in flight or awaiting reappear handoff.
        let keepPendingImport = isRouteActive
            && pendingImportTicket != nil
            && (model.fileSelection?.id == pendingImportTicket
                || model.lastStoryImport?.id == pendingImportTicket)
        tearDownAllAsyncWork(clearPendingImport: !keepPendingImport)
    }

    private func tearDownAllAsyncWork(clearPendingImport: Bool) {
        isViewActive = false
        focusedField = nil
        loadGeneration = UUID()
        loadTask?.cancel()
        loadTask = nil
        isLoadingSessions = false
        cancelActiveStart()
        cancelActiveDelete()
        consumedPreselectedBookID = nil
        if clearPendingImport {
            pendingImportTicket = nil
        }
    }

    private static func roleKindTitle(_ kind: StoryRoleKind) -> String {
        switch kind {
        case .canon:
            return "原著角色"
        case .original:
            return "原创角色"
        }
    }

    private static func safeStoryErrorMessage(_ error: Error) -> String {
        if let storyError = error as? StoryLaunchError, let description = storyError.errorDescription {
            return description
        }
        if let libraryError = error as? LibraryError, let description = libraryError.errorDescription {
            return description
        }
        return "操作未完成：\(LibraryViewModel.safeImportFailureSummary(error))"
    }
}

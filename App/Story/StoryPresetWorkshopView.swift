import Foundation
import ReaderDomain
import SwiftUI
import UniformTypeIdentifiers

/// Native iOS 16.6 SwiftUI workshop for importing, inspecting, and optionally selecting
/// SillyTavern Chat Completion JSON narrative presets inside AI Story.
/// Never parses files locally or logs file contents; delegates security-scoped reading to `LibraryService`.
@MainActor
struct StoryPresetWorkshopView: View {
    enum Mode {
        case manage
        case pick(selectedID: String?, onSelect: (StoryPresetSummary?) -> Void)
    }

    @ObservedObject var model: LibraryViewModel
    let appearance: LibraryAppearance
    let mode: Mode

    @State private var presets: [StoryPresetSummary] = []
    @State private var isLoading = false
    @State private var loadErrorMessage: String?
    @State private var isPresentingImporter = false
    @State private var isImporting = false
    @State private var importFeedback: (isError: Bool, message: String)?
    @State private var inspectingVersion: StoryPresetVersion?
    @State private var isLoadingDetail = false

    @State private var isViewActive = false
    @State private var loadGeneration = UUID()
    @State private var importRequestID: UUID?
    @State private var detailRequestID: UUID?
    @State private var loadTask: Task<Void, Never>?
    @State private var importTask: Task<Void, Never>?
    @State private var detailTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var primaryButtonForeground: Color {
        appearance.isDarkSurface ? Color.black.opacity(0.9) : Color.white
    }

    private var selectedPresetID: String? {
        if case .pick(let selectedID, _) = mode {
            return selectedID
        }
        return nil
    }

    private var canImportPreset: Bool {
        model.service != nil && !isImporting && !isLoadingDetail
    }

    var body: some View {
        NavigationStack {
            Group {
                if let version = inspectingVersion {
                    StoryPresetDetailView(
                        version: version,
                        appearance: appearance,
                        isLockedBanner: false,
                        pickAction: pickActionFor(version.summary),
                        onBackToList: {
                            withMotion { inspectingVersion = nil }
                        }
                    )
                } else {
                    presetListContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(appearance.page.ignoresSafeArea())
            .foregroundStyle(appearance.foreground)
            .tint(appearance.accent)
            .navigationTitle(inspectingVersion == nil ? "叙事预设" : "预设结构预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(appearance.page, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(appearance.controlColorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if inspectingVersion != nil {
                        Button {
                            withMotion { inspectingVersion = nil }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.subheadline.weight(.semibold))
                                    .accessibilityHidden(true)
                                Text("列表")
                                    .font(AppVisualStyle.actionFont)
                            }
                            .foregroundStyle(appearance.accent)
                            .frame(minWidth: 44, minHeight: LibraryAppearance.minimumControlHeight)
                        }
                        .accessibilityIdentifier("story.preset.detail.back")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .font(AppVisualStyle.actionFont)
                    .foregroundStyle(appearance.accent)
                    .accessibilityIdentifier("story.preset.close")
                }
            }
        }
        .fileImporter(
            isPresented: $isPresentingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleFileImportResult(result)
        }
        .onAppear {
            isViewActive = true
            triggerLoadPresets()
        }
        .onDisappear {
            isViewActive = false
            cancelAllTasks()
        }
        .accessibilityIdentifier("story.preset.workshop")
    }

    // MARK: - List Content

    private var presetListContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                workshopHeaderCard
                importActionCard

                if let importFeedback {
                    feedbackBanner(isError: importFeedback.isError, message: importFeedback.message)
                }

                if case .pick(_, let onSelect) = mode {
                    skipPresetRow(onSelect: onSelect)
                }

                if model.service == nil {
                    statusCard(title: "本地存储尚未就绪", detail: "请等待书架服务初始化完成后再导入或查看叙事预设。")
                } else if isLoading && presets.isEmpty {
                    loadingRow(text: "正在读取本地预设版本…")
                        .accessibilityIdentifier("story.preset.loading")
                } else if let loadErrorMessage {
                    errorCard(message: loadErrorMessage)
                } else if presets.isEmpty {
                    emptyStateCard
                } else {
                    presetListSection
                }
            }
            .padding(.horizontal, LibraryAppearance.horizontalInset)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
    }

    private var workshopHeaderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("ST Chat Completion JSON")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(appearance.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(appearance.accentSoft, in: Capsule())
                Text("导入与预览完全离线")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(appearance.sealAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(appearance.sealSoft, in: Capsule())
                Spacer(minLength: 0)
            }

            Text("预设工坊的导入、解析与结构预览均在本地完成，永不上网。绑定到故事开局后，仅在你于剧场主动确认发送 BYOK 模型请求时按本局版本组装。")
                .font(.footnote)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay { cardBorder(appearance.edge.opacity(0.8)) }
    }

    private var importActionCard: some View {
        Button {
            importFeedback = nil
            isPresentingImporter = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(primaryButtonForeground.opacity(0.16))
                        .frame(width: 40, height: 40)
                    if isImporting {
                        ProgressView()
                            .tint(primaryButtonForeground)
                    } else {
                        Image(systemName: "doc.badge.plus")
                            .font(.headline)
                            .foregroundStyle(primaryButtonForeground)
                            .accessibilityHidden(true)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(isImporting ? "正在导入并校验预设…" : "从“文件”导入预设 JSON")
                        .font(.subheadline.weight(.semibold))
                    Text("独立于图书导入，仅接受 ST Chat Completion JSON")
                        .font(.caption)
                        .opacity(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .opacity(0.8)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: primaryButtonForeground,
            surface: appearance.accent,
            cornerRadius: 16
        ))
        .disabled(!canImportPreset)
        .accessibilityLabel("从系统文件导入叙事预设 JSON")
        .accessibilityIdentifier("story.preset.import")
    }

    private func skipPresetRow(onSelect: @escaping (StoryPresetSummary?) -> Void) -> some View {
        let isSkipped = selectedPresetID == nil
        return Button {
            onSelect(nil)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSkipped ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                    .foregroundStyle(isSkipped ? appearance.accent : appearance.secondary.opacity(0.5))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("跳过预设（不绑定版本）")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appearance.foreground)
                    Text("直接开启故事，稍后可另建故事绑定预设")
                        .font(.caption)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: LibraryAppearance.minimumControlHeight, alignment: .leading)
            .background(isSkipped ? appearance.accentSoft : appearance.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSkipped ? appearance.accent : appearance.edge.opacity(0.8), lineWidth: isSkipped ? 1.3 : 0.75)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("story.preset.skip")
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("尚未导入任何叙事预设")
                .font(.headline)
                .foregroundStyle(appearance.foreground)
            Text("点击上方按钮从系统“文件”选择 SillyTavern Chat Completion JSON。导入后会按内容生成固定版本指纹，便于诊断结构与开局绑定。")
                .font(.subheadline)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay { cardBorder(appearance.edge.opacity(0.8)) }
        .accessibilityIdentifier("story.preset.empty")
    }

    private var presetListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(appearance.accent)
                    .frame(width: 3, height: 15)
                    .accessibilityHidden(true)
                Text("已导入版本")
                    .font(LibraryAppearance.sectionTitleFont)
                    .foregroundStyle(appearance.foreground)
                    .accessibilityAddTraits(.isHeader)
                Text("\(presets.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(appearance.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(appearance.accentSoft, in: Capsule())
            }

            if isLoadingDetail {
                loadingRow(text: "正在读取预设结构详情…")
            }

            VStack(spacing: 12) {
                ForEach(presets) { summary in
                    presetSummaryRow(summary)
                }
            }
            .accessibilityIdentifier("story.preset.list")
        }
    }

    private func presetSummaryRow(_ summary: StoryPresetSummary) -> some View {
        let isSelected = selectedPresetID == summary.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(summary.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(appearance.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        presetStatusBadge(canSelect: summary.canSelect)
                    }

                    Text("版本指纹 · \(Self.shortHash(summary.id))")
                        .font(.caption.monospaced())
                        .foregroundStyle(appearance.secondary)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    inspectButton(summary)
                    if case .pick(_, let onSelect) = mode {
                        choosePresetButton(summary, isSelected: isSelected, onSelect: onSelect)
                    }
                }
                VStack(spacing: 8) {
                    inspectButton(summary)
                    if case .pick(_, let onSelect) = mode {
                        choosePresetButton(summary, isSelected: isSelected, onSelect: onSelect)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? appearance.accentSoft.opacity(0.6) : appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay {
            cardBorder(isSelected ? appearance.accent : appearance.edge.opacity(0.8))
        }
        .accessibilityIdentifier("story.preset.row.\(Self.shortHash(summary.id))")
    }

    private func inspectButton(_ summary: StoryPresetSummary) -> some View {
        Button {
            triggerLoadDetail(id: summary.id)
        } label: {
            Label("结构与诊断", systemImage: "list.bullet.rectangle")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: appearance.accent,
            surface: appearance.accentSoft,
            border: appearance.accent.opacity(0.28),
            cornerRadius: 12
        ))
        .disabled(isLoadingDetail)
        .accessibilityIdentifier("story.preset.inspect.\(Self.shortHash(summary.id))")
    }

    private func choosePresetButton(
        _ summary: StoryPresetSummary,
        isSelected: Bool,
        onSelect: @escaping (StoryPresetSummary?) -> Void
    ) -> some View {
        Button {
            onSelect(summary)
            dismiss()
        } label: {
            Text(summary.canSelect ? (isSelected ? "已选用" : "选用此版本") : "含问题不可选")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: summary.canSelect ? primaryButtonForeground : appearance.secondary,
            surface: summary.canSelect ? appearance.accent : appearance.subtleSurface,
            cornerRadius: 12
        ))
        .disabled(!summary.canSelect)
        .accessibilityIdentifier("story.preset.select.\(Self.shortHash(summary.id))")
    }

    private func presetStatusBadge(canSelect: Bool) -> some View {
        Text(canSelect ? "无问题 · 可选" : "含诊断问题")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(canSelect ? appearance.accent : appearance.sealAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(canSelect ? appearance.accentSoft : appearance.sealSoft, in: Capsule())
    }

    private func feedbackBanner(isError: Bool, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(isError ? appearance.sealAccent : appearance.accent)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(appearance.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isError ? appearance.sealSoft : appearance.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("story.preset.feedback")
    }

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("未能读取本地预设列表")
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.footnote)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                triggerLoadPresets()
            } label: {
                Label("重新读取", systemImage: "arrow.clockwise")
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
            .accessibilityIdentifier("story.preset.retry")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { cardBorder(appearance.sealAccent.opacity(0.45)) }
        .accessibilityIdentifier("story.preset.error")
    }

    private func statusCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(appearance.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func loadingRow(text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().tint(appearance.accent)
            Text(text).font(.subheadline).foregroundStyle(appearance.secondary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func cardBorder(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
            .strokeBorder(color, lineWidth: 0.75)
            .allowsHitTesting(false)
    }

    private func pickActionFor(_ summary: StoryPresetSummary) -> (() -> Void)? {
        guard case .pick(_, let onSelect) = mode, summary.canSelect else { return nil }
        return {
            onSelect(summary)
            dismiss()
        }
    }

    private func withMotion(_ body: () -> Void) {
        if reduceMotion {
            body()
        } else {
            withAnimation(.easeInOut(duration: 0.22), body)
        }
    }

    static func shortHash(_ id: String) -> String {
        String(id.prefix(12))
    }

    // MARK: - Async Store / Service Integration

    private func cancelAllTasks() {
        loadGeneration = UUID()
        importRequestID = nil
        detailRequestID = nil
        loadTask?.cancel()
        loadTask = nil
        importTask?.cancel()
        importTask = nil
        detailTask?.cancel()
        detailTask = nil
        isLoading = false
        isImporting = false
        isLoadingDetail = false
    }

    private func triggerLoadPresets() {
        guard isViewActive, let store = model.service?.store else { return }
        let generation = UUID()
        loadGeneration = generation
        loadTask?.cancel()
        isLoading = true
        loadErrorMessage = nil

        loadTask = Task { @MainActor in
            defer {
                if loadGeneration == generation {
                    isLoading = false
                    loadTask = nil
                }
            }
            do {
                let loaded = try await store.storyPresets()
                guard !Task.isCancelled, loadGeneration == generation, isViewActive else { return }
                presets = loaded
            } catch {
                guard !Task.isCancelled, loadGeneration == generation, isViewActive else { return }
                loadErrorMessage = error.localizedDescription
            }
        }
    }

    private func handleFileImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                // User cancelled or returned empty selection
                return
            }
            triggerImportPreset(from: url)
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError {
                return
            }
            importFeedback = (true, "未能打开所选文件：\(error.localizedDescription)")
        }
    }

    private func triggerImportPreset(from url: URL) {
        guard isViewActive, !isImporting, let service = model.service else { return }
        let reqID = UUID()
        importRequestID = reqID
        isImporting = true
        importFeedback = nil
        importTask?.cancel()

        importTask = Task { @MainActor in
            defer {
                if importRequestID == reqID {
                    isImporting = false
                    importRequestID = nil
                    importTask = nil
                }
            }
            do {
                let version = try await service.importStoryPreset(from: url)
                guard !Task.isCancelled, importRequestID == reqID, isViewActive else { return }
                presets.removeAll { $0.id == version.summary.id }
                presets.insert(version.summary, at: 0)
                loadErrorMessage = nil
                if version.summary.canSelect {
                    importFeedback = (false, "已导入「\(version.summary.name)」并完成本地结构校验（导入过程不联网）。")
                } else {
                    importFeedback = (true, "已导入「\(version.summary.name)」，但检出 \(version.issues.count) 项诊断问题，暂不可用于开局绑定。")
                }
                withMotion {
                    inspectingVersion = version
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, importRequestID == reqID, isViewActive else { return }
                importFeedback = (true, "预设导入失败：\(error.localizedDescription)")
            }
        }
    }

    private func triggerLoadDetail(id: String) {
        guard isViewActive, !isLoadingDetail, let store = model.service?.store else { return }
        let reqID = UUID()
        detailRequestID = reqID
        isLoadingDetail = true
        detailTask?.cancel()

        detailTask = Task { @MainActor in
            defer {
                if detailRequestID == reqID {
                    isLoadingDetail = false
                    detailRequestID = nil
                    detailTask = nil
                }
            }
            do {
                let version = try await store.storyPreset(id: id)
                guard !Task.isCancelled, detailRequestID == reqID, isViewActive else { return }
                withMotion {
                    inspectingVersion = version
                }
            } catch {
                guard !Task.isCancelled, detailRequestID == reqID, isViewActive else { return }
                importFeedback = (true, "未能读取该预设版本详情：\(error.localizedDescription)")
            }
        }
    }
}

/// Read-only inspection view for a `StoryPresetVersion`: ordered role timeline,
/// enabled/disabled status, history slot anchor, diagnostics, parameters, and ignored fields.
@MainActor
struct StoryPresetDetailView: View {
    let version: StoryPresetVersion
    let appearance: LibraryAppearance
    let isLockedBanner: Bool
    var pickAction: (() -> Void)? = nil
    var onBackToList: (() -> Void)? = nil

    @State private var expandedIndices: Set<Int> = []
    @State private var showTechnicalFields = false

    private var primaryButtonForeground: Color {
        appearance.isDarkSurface ? Color.black.opacity(0.9) : Color.white
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryHeaderCard

                if !version.issues.isEmpty {
                    issuesCard
                }

                entriesTimelineSection

                if !version.parameters.isEmpty || !version.ignoredFields.isEmpty {
                    technicalDetailsCard
                }

                if let pickAction {
                    Button(action: pickAction) {
                        Text("为本局选用此版本")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(AppControlButtonStyle(
                        foreground: primaryButtonForeground,
                        surface: appearance.accent,
                        cornerRadius: 16
                    ))
                    .accessibilityIdentifier("story.preset.detail.pick")
                }
            }
            .padding(.horizontal, LibraryAppearance.horizontalInset)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .accessibilityIdentifier("story.preset.detail")
    }

    private var summaryHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(isLockedBanner ? "本局锁定版本" : (version.summary.canSelect ? "无问题 · 可选用" : "含诊断问题"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(version.summary.canSelect ? appearance.accent : appearance.sealAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(version.summary.canSelect ? appearance.accentSoft : appearance.sealSoft, in: Capsule())

                Text("共 \(version.entries.count) 条目")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(appearance.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(appearance.subtleSurface, in: Capsule())
                Spacer(minLength: 0)
            }

            Text(version.summary.name)
                .font(AppVisualStyle.heroBookTitleFont)
                .foregroundStyle(appearance.foreground)
                .fixedSize(horizontal: false, vertical: true)

            Text("SHA-256 · \(StoryPresetWorkshopView.shortHash(version.summary.id))")
                .font(.caption.monospaced())
                .foregroundStyle(appearance.secondary)

            Text("预设导入与预览均在本地离线完成；若绑定至故事开局，将在你主动确认 BYOK 联网模型生成时按此版本组装。")
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(appearance.subtleSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay { cardBorder(appearance.edge.opacity(0.8)) }
    }

    private var issuesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(appearance.sealAccent)
                    .accessibilityHidden(true)
                Text("诊断问题（\(version.issues.count)）")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(appearance.foreground)
            }

            ForEach(Array(version.issues.enumerated()), id: \.offset) { idx, issue in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(idx + 1).")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(appearance.sealAccent)
                    Text(issue)
                        .font(.footnote)
                        .foregroundStyle(appearance.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.sealSoft, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay { cardBorder(appearance.sealAccent.opacity(0.45)) }
        .accessibilityIdentifier("story.preset.detail.issues")
    }

    private var entriesTimelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(appearance.accent)
                    .frame(width: 3, height: 15)
                    .accessibilityHidden(true)
                Text("按序提示词轨道")
                    .font(LibraryAppearance.sectionTitleFont)
                    .foregroundStyle(appearance.foreground)
                    .accessibilityAddTraits(.isHeader)
            }

            if version.entries.isEmpty {
                Text("此预设不包含条目。")
                    .font(.subheadline)
                    .foregroundStyle(appearance.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(appearance.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(version.entries.enumerated()), id: \.offset) { index, entry in
                        entryRow(index: index, entry: entry)
                    }
                }
            }
        }
    }

    private func entryRow(index: Int, entry: StoryPresetEntry) -> some View {
        let isExpanded = expandedIndices.contains(index)
        let roleTint: Color = entry.isHistory
            ? appearance.sealAccent
            : (entry.role.lowercased() == "system" ? appearance.accent : appearance.foreground)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("#\(index + 1)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(appearance.secondary)

                Text(entry.isHistory ? "历史插槽" : entry.role)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(roleTint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(
                        (entry.isHistory ? appearance.sealSoft : appearance.accentSoft),
                        in: Capsule()
                    )

                Text(entry.enabled ? "已启用" : "已停用")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(entry.enabled ? appearance.foreground.opacity(0.85) : appearance.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(appearance.subtleSurface, in: Capsule())

                Spacer(minLength: 4)

                if !entry.identifier.isEmpty {
                    Text(entry.identifier)
                        .font(.caption2.monospaced())
                        .foregroundStyle(appearance.secondary)
                        .lineLimit(1)
                }
            }

            if entry.isHistory {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(appearance.sealAccent)
                        .accessibilityHidden(true)
                    Text("对话历史注入位置（History Slot）")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(appearance.foreground)
                }
            } else if !entry.content.isEmpty {
                Button {
                    if isExpanded {
                        expandedIndices.remove(index)
                    } else {
                        expandedIndices.insert(index)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.content)
                            .font(.footnote)
                            .lineSpacing(4)
                            .foregroundStyle(entry.enabled ? appearance.foreground : appearance.secondary)
                            .lineLimit(isExpanded ? nil : 3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if entry.content.count > 90 {
                            Text(isExpanded ? "收起内容" : "展开完整内容")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(appearance.accent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            entry.isHistory ? appearance.sealSoft.opacity(0.45) : appearance.surface,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .opacity(entry.enabled ? 1.0 : 0.65)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    entry.isHistory ? appearance.sealAccent.opacity(0.45) : appearance.edge.opacity(0.75),
                    style: entry.isHistory ? StrokeStyle(lineWidth: 1, dash: [5, 3]) : StrokeStyle(lineWidth: 0.75)
                )
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("story.preset.entry.\(index)")
    }

    private var technicalDetailsCard: some View {
        DisclosureGroup(isExpanded: $showTechnicalFields) {
            VStack(alignment: .leading, spacing: 12) {
                if !version.parameters.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已识别参数（\(version.parameters.count)）")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(appearance.accent)
                        ForEach(version.parameters.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .firstTextBaseline) {
                                Text(key)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(appearance.secondary)
                                Spacer(minLength: 8)
                                Text(version.parameters[key] ?? "")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(appearance.foreground)
                            }
                        }
                    }
                }

                if !version.ignoredFields.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已忽略字段（\(version.ignoredFields.count)）")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(appearance.secondary)
                        Text(version.ignoredFields.joined(separator: " · "))
                            .font(.caption.monospaced())
                            .foregroundStyle(appearance.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text("参数与已忽略字段")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appearance.foreground)
        }
        .padding(16)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay { cardBorder(appearance.edge.opacity(0.75)) }
        .accessibilityIdentifier("story.preset.detail.technical")
    }

    private func cardBorder(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
            .strokeBorder(color, lineWidth: 0.75)
            .allowsHitTesting(false)
    }
}

/// Read-only sheet presented from `StorySessionTheaterView` to inspect the session's locked preset version.
@MainActor
struct StoryLockedPresetSheet: View {
    let presetID: String
    @ObservedObject var model: LibraryViewModel
    let appearance: LibraryAppearance

    @State private var version: StoryPresetVersion?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isViewActive = false
    @State private var loadGeneration = UUID()
    @State private var loadTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let version {
                    StoryPresetDetailView(
                        version: version,
                        appearance: appearance,
                        isLockedBanner: true
                    )
                } else if isLoading {
                    VStack(spacing: 12) {
                        ProgressView().tint(appearance.accent)
                        Text("正在读取本局锁定预设…")
                            .font(.subheadline)
                            .foregroundStyle(appearance.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Text("未能读取锁定预设版本")
                            .font(.headline)
                        Text(errorMessage ?? "本地存档中未找到指纹 \(StoryPresetWorkshopView.shortHash(presetID)) 对应的预设版本。")
                            .font(.footnote)
                            .foregroundStyle(appearance.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("重新读取") {
                            triggerLoad()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appearance.accent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(appearance.page.ignoresSafeArea())
            .foregroundStyle(appearance.foreground)
            .navigationTitle("本局锁定预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(AppVisualStyle.actionFont)
                        .foregroundStyle(appearance.accent)
                        .accessibilityIdentifier("story.preset.locked.close")
                }
            }
        }
        .onAppear {
            isViewActive = true
            triggerLoad()
        }
        .onDisappear {
            isViewActive = false
            loadGeneration = UUID()
            loadTask?.cancel()
            loadTask = nil
        }
        .accessibilityIdentifier("story.preset.locked.sheet")
    }

    private func triggerLoad() {
        guard isViewActive, let store = model.service?.store else { return }
        let gen = UUID()
        loadGeneration = gen
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil

        loadTask = Task { @MainActor in
            defer {
                if loadGeneration == gen {
                    isLoading = false
                    loadTask = nil
                }
            }
            do {
                let loaded = try await store.storyPreset(id: presetID)
                guard !Task.isCancelled, loadGeneration == gen, isViewActive else { return }
                version = loaded
            } catch {
                guard !Task.isCancelled, loadGeneration == gen, isViewActive else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}

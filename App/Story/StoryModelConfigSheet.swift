import Foundation
import ReaderDomain
import SwiftUI

/// Native iOS 16.6 SwiftUI BYOK model configuration sheet.
/// Reads/writes only via `StoryModelVault` static synchronous APIs; never stores or logs API keys in view state after save.
@MainActor
struct StoryModelConfigSheet: View {
    let appearance: LibraryAppearance
    let onSaved: (StoryModelConfiguration?) -> Void

    @State private var existingConfig: StoryModelConfiguration?
    @State private var endpointText: String = ""
    @State private var modelNameText: String = ""
    @State private var apiKeyText: String = ""
    @State private var feedbackMessage: (isError: Bool, text: String)?
    @State private var isConfirmingClear = false

    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable {
        case endpoint
        case model
        case apiKey
    }

    private var primaryButtonForeground: Color {
        appearance.isDarkSurface ? Color.black.opacity(0.9) : Color.white
    }

    private var trimmedEndpoint: String {
        endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedModel: String {
        modelNameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedKey: String {
        apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isEndpointHTTPS: Bool {
        guard let url = URL(string: trimmedEndpoint),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return false
        }
        return true
    }

    private var canSave: Bool {
        isEndpointHTTPS && !trimmedModel.isEmpty && !trimmedKey.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    introCard
                    if let existingConfig {
                        activeConfigCard(existingConfig)
                    }
                    formCard

                    if let feedbackMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: feedbackMessage.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(feedbackMessage.isError ? appearance.sealAccent : appearance.accent)
                                .accessibilityHidden(true)
                            Text(feedbackMessage.text)
                                .font(.footnote)
                                .foregroundStyle(appearance.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(
                            feedbackMessage.isError ? appearance.sealSoft : appearance.accentSoft,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .accessibilityIdentifier("story.model.feedback")
                    }

                    saveButton

                    if existingConfig != nil {
                        clearButton
                    }
                }
                .padding(.horizontal, LibraryAppearance.horizontalInset)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(appearance.page.ignoresSafeArea())
            .foregroundStyle(appearance.foreground)
            .tint(appearance.accent)
            .navigationTitle("BYOK 模型配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(appearance.page, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(appearance.controlColorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(AppVisualStyle.actionFont)
                        .foregroundStyle(appearance.accent)
                        .accessibilityIdentifier("story.model.close")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { focusedField = nil }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appearance.accent)
                }
            }
        }
        .confirmationDialog(
            "删除本地模型配置？",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("删除配置", role: .destructive) {
                clearConfiguration()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清除已保存的接口地址、模型名与 API Key。清除后仍可阅读已保存的故事原文与历史记录，重新配置后可继续生成新回合。")
        }
        .onAppear {
            loadCurrentConfiguration()
        }
        .accessibilityIdentifier("story.model.sheet")
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("自带密钥 · BYOK")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(appearance.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(appearance.accentSoft, in: Capsule())
                Text("仅主动确认后联网")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(appearance.sealAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(appearance.sealSoft, in: Capsule())
                Spacer(minLength: 0)
            }
            Text("配置你自己的 OpenAI 兼容 HTTPS chat/completions 接口后，可在故事剧场中主动发起真实模型生成；每次发送前都会展示完整请求清单并由你确认，可能产生第三方服务计费。")
                .font(.footnote)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay { cardBorder(appearance.edge.opacity(0.8)) }
    }

    private func activeConfigCard(_ config: StoryModelConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当前已保存配置（Key 已加密保存，不回显）")
                .font(.caption.weight(.semibold))
                .foregroundStyle(appearance.accent)
            Text(config.endpoint.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(appearance.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Text("模型 · \(config.model)")
                .font(.caption.monospaced())
                .foregroundStyle(appearance.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.accentSoft.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("story.model.savedSummary")
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("完整 HTTPS chat/completions 接口地址")
                    .font(.subheadline.weight(.medium))
                TextField("https://example.com/v1/chat/completions", text: $endpointText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($focusedField, equals: .endpoint)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .model }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(appearance.subtleSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                (!trimmedEndpoint.isEmpty && !isEndpointHTTPS) ? appearance.sealAccent : appearance.edge.opacity(0.85),
                                lineWidth: 0.85
                            )
                            .allowsHitTesting(false)
                    }
                    .accessibilityIdentifier("story.model.endpoint")

                if !trimmedEndpoint.isEmpty && !isEndpointHTTPS {
                    Text("请输入有效的完整 HTTPS URL（例如 https://.../v1/chat/completions）。")
                        .font(.caption)
                        .foregroundStyle(appearance.sealAccent)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("模型名称")
                    .font(.subheadline.weight(.medium))
                TextField("例如 gpt-4o-mini / deepseek-chat", text: $modelNameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($focusedField, equals: .model)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .apiKey }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(appearance.subtleSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(appearance.edge.opacity(0.85), lineWidth: 0.85)
                            .allowsHitTesting(false)
                    }
                    .accessibilityIdentifier("story.model.name")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API Key")
                    .font(.subheadline.weight(.medium))
                SecureField(existingConfig == nil ? "输入你的 API Key" : "更新配置时需重新输入 API Key", text: $apiKeyText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($focusedField, equals: .apiKey)
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(appearance.subtleSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(appearance.edge.opacity(0.85), lineWidth: 0.85)
                            .allowsHitTesting(false)
                    }
                    .accessibilityIdentifier("story.model.apiKey")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay { cardBorder(appearance.edge.opacity(0.8)) }
    }

    private var saveButton: some View {
        Button {
            saveConfiguration()
        } label: {
            Text("保存本地配置")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: primaryButtonForeground,
            surface: appearance.accent,
            cornerRadius: 16
        ))
        .disabled(!canSave)
        .accessibilityIdentifier("story.model.save")
    }

    private var clearButton: some View {
        Button {
            isConfirmingClear = true
        } label: {
            Text("删除已保存配置")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: appearance.sealAccent,
            surface: appearance.sealSoft,
            border: appearance.sealAccent.opacity(0.32),
            cornerRadius: 16
        ))
        .accessibilityIdentifier("story.model.clear")
    }

    private func cardBorder(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
            .strokeBorder(color, lineWidth: 0.75)
            .allowsHitTesting(false)
    }

    private func loadCurrentConfiguration() {
        do {
            let loaded = try StoryModelVault.load()
            existingConfig = loaded
            if let loaded {
                endpointText = loaded.endpoint.absoluteString
                modelNameText = loaded.model
            }
            apiKeyText = ""
        } catch {
            feedbackMessage = (true, "读取本地模型配置失败：\(error.localizedDescription)")
        }
    }

    private func saveConfiguration() {
        focusedField = nil
        guard canSave else { return }
        do {
            try StoryModelVault.save(endpoint: trimmedEndpoint, model: trimmedModel, apiKey: trimmedKey)
            let reloaded = try StoryModelVault.load()
            existingConfig = reloaded
            apiKeyText = ""
            feedbackMessage = (false, "已安全保存模型配置。后续可在故事剧场主动发起确认后生成。")
            onSaved(reloaded)
        } catch {
            feedbackMessage = (true, "保存配置失败：\(error.localizedDescription)")
        }
    }

    private func clearConfiguration() {
        focusedField = nil
        do {
            try StoryModelVault.clear()
            existingConfig = nil
            endpointText = ""
            modelNameText = ""
            apiKeyText = ""
            feedbackMessage = (false, "已删除本地模型配置。")
            onSaved(nil)
        } catch {
            feedbackMessage = (true, "删除配置失败：\(error.localizedDescription)")
        }
    }
}

/// Pre-flight confirmation sheet shown before sending a real BYOK network request.
/// Displays full target endpoint, model, preset name (or none), billing warning,
/// ordered session-only messages, and parameters.
@MainActor
struct StoryGenerationConfirmSheet: View {
    let draft: StoryGenerationDraft
    let appearance: LibraryAppearance
    let onConfirm: (StoryGenerationDraft) -> Void
    let onCancel: () -> Void

    @State private var expandedMessageIndices: Set<Int> = []
    @State private var showParameters = false

    private var primaryButtonForeground: Color {
        appearance.isDarkSurface ? Color.black.opacity(0.9) : Color.white
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    targetSummaryCard
                    billingNoticeCard
                    messagesPreviewSection
                    if !draft.parameters.isEmpty {
                        parametersSection
                    }
                }
                .padding(.horizontal, LibraryAppearance.horizontalInset)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) {
                confirmFooterBar
            }
            .background(appearance.page.ignoresSafeArea())
            .foregroundStyle(appearance.foreground)
            .tint(appearance.accent)
            .navigationTitle("发送前确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(appearance.page, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(appearance.controlColorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { onCancel() }
                        .font(AppVisualStyle.actionFont)
                        .foregroundStyle(appearance.secondary)
                        .accessibilityIdentifier("story.genConfirm.cancelTop")
                }
            }
        }
        .accessibilityIdentifier("story.genConfirm.sheet")
    }

    private var targetSummaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("即将向你配置的远端接口发送本局上下文")
                .font(.subheadline.weight(.semibold))
            infoRow(label: "完整端点", value: draft.endpoint.absoluteString, monospaced: true)
            infoRow(label: "目标模型", value: draft.model, monospaced: true)
            infoRow(label: "应用预设", value: draft.presetName ?? "未使用预设", monospaced: false)
            infoRow(label: "发送消息", value: "仅本局上下文（共 \(draft.messages.count) 条）", monospaced: false)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay { cardBorder(appearance.edge.opacity(0.8)) }
        .accessibilityIdentifier("story.genConfirm.summary")
    }

    private func infoRow(label: String, value: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(appearance.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .footnote.weight(.medium))
                .foregroundStyle(appearance.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var billingNoticeCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "network")
                .font(.subheadline)
                .foregroundStyle(appearance.sealAccent)
                .accessibilityHidden(true)
            Text("确认后将发起真实网络请求并可能产生第三方模型服务计费。生成中途取消或断流不会保存半回合，也不会自动重试。")
                .font(.caption)
                .foregroundStyle(appearance.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.sealSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("story.genConfirm.billingNotice")
    }

    private var messagesPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按序发送的消息（仅本局）")
                .font(LibraryAppearance.sectionTitleFont)
                .accessibilityAddTraits(.isHeader)

            ForEach(Array(draft.messages.enumerated()), id: \.offset) { idx, msg in
                let expanded = expandedMessageIndices.contains(idx)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("#\(idx + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(appearance.secondary)
                        Text(msg.role)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(appearance.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(appearance.accentSoft, in: Capsule())
                        Spacer(minLength: 0)
                        Text("\(msg.content.count) 字")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(appearance.secondary)
                    }

                    Button {
                        if expanded {
                            expandedMessageIndices.remove(idx)
                        } else {
                            expandedMessageIndices.insert(idx)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(msg.content)
                                .font(.footnote)
                                .lineSpacing(4)
                                .foregroundStyle(appearance.foreground)
                                .lineLimit(expanded ? nil : 3)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if msg.content.count > 90 {
                                Text(expanded ? "收起" : "展开查看全文")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(appearance.accent)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(appearance.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(appearance.edge.opacity(0.75), lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
                .accessibilityIdentifier("story.genConfirm.message.\(idx)")
            }
        }
    }

    private var parametersSection: some View {
        DisclosureGroup(isExpanded: $showParameters) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(draft.parameters.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key).font(.caption.monospaced()).foregroundStyle(appearance.secondary)
                        Spacer(minLength: 8)
                        Text(draft.parameters[key] ?? "").font(.caption.monospaced()).foregroundStyle(appearance.foreground)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text("请求参数（\(draft.parameters.count)）")
                .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { cardBorder(appearance.edge.opacity(0.75)) }
        .accessibilityIdentifier("story.genConfirm.parameters")
    }

    private var confirmFooterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                cancelBtn
                confirmBtn
            }
            VStack(spacing: 8) {
                confirmBtn
                cancelBtn
            }
        }
        .padding(.horizontal, LibraryAppearance.horizontalInset)
        .padding(.vertical, 12)
        .background(appearance.surface.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle().fill(appearance.edge.opacity(0.75)).frame(height: 0.6)
        }
    }

    private var cancelBtn: some View {
        Button {
            onCancel()
        } label: {
            Text("取消不发送")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: appearance.secondary,
            surface: appearance.subtleSurface,
            border: appearance.edge.opacity(0.8),
            cornerRadius: 14
        ))
        .accessibilityIdentifier("story.genConfirm.cancel")
    }

    private var confirmBtn: some View {
        Button {
            onConfirm(draft)
        } label: {
            Text("确认并发送生成")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: primaryButtonForeground,
            surface: appearance.accent,
            cornerRadius: 14
        ))
        .accessibilityIdentifier("story.genConfirm.send")
    }

    private func cardBorder(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
            .strokeBorder(color, lineWidth: 0.75)
            .allowsHitTesting(false)
    }
}

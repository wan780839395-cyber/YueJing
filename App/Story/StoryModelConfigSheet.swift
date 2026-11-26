import Foundation
import ReaderDomain
import SwiftUI

/// Native iOS 16.6 SwiftUI BYOK model configuration sheet.
/// Reads/writes only via `StoryModelVault` static synchronous APIs; supports HTTPS by default
/// and explicit single-address LAN HTTP authorization; never stores or logs keys after save.
@MainActor
struct StoryModelConfigSheet: View {
    let appearance: LibraryAppearance
    let onSaved: (StoryModelConfiguration?) -> Void

    @State private var existingConfig: StoryModelConfiguration?
    @State private var endpointText: String = ""
    @State private var programmaticEndpointSnapshot: String?
    @State private var approvedLANEndpoint: String?
    @State private var modelNameText: String = ""
    @State private var apiKeyText: String = ""
    @State private var feedbackMessage: (isError: Bool, text: String)?
    @State private var isConfirmingClear = false
    @State private var showLANHelp = false
    @State private var fetchedModels: [String] = []
    @State private var modelFilterText: String = ""
    @State private var isFetchingModels = false
    @State private var catalogFeedback: (isError: Bool, text: String)?
    @State private var activeFetchID: UUID?
    @State private var fetchTask: Task<Void, Never>?
    @State private var isViewActive = false

    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable {
        case endpoint
        case model
        case apiKey
        case modelFilter
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

    private var lanCandidateEndpoint: String? {
        guard !isEndpointHTTPS, !trimmedEndpoint.isEmpty else { return nil }
        return StoryModelVault.lanEndpointCandidate(trimmedEndpoint)
    }

    private var isEndpointLANHTTP: Bool {
        lanCandidateEndpoint != nil
    }

    private var isEndpointValidFormat: Bool {
        isEndpointHTTPS || isEndpointLANHTTP
    }

    private var isLoopbackHTTPInput: Bool {
        guard !isEndpointHTTPS,
              let url = URL(string: trimmedEndpoint),
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    private var effectiveEndpoint: String {
        lanCandidateEndpoint ?? trimmedEndpoint
    }

    private var savedNormalizedLANEndpoint: String? {
        guard let saved = existingConfig?.endpoint.absoluteString,
              StoryModelVault.lanEndpointCandidate(saved) == saved else {
            return nil
        }
        return saved
    }

    private var currentApprovedLANEndpoint: String? {
        guard let candidate = lanCandidateEndpoint,
              approvedLANEndpoint == candidate else {
            return nil
        }
        return candidate
    }

    private var matchesSavedEndpointExactly: Bool {
        guard let saved = existingConfig?.endpoint.absoluteString else { return false }
        return effectiveEndpoint == saved
    }

    private var canKeepSavedKey: Bool {
        trimmedKey.isEmpty && matchesSavedEndpointExactly
    }

    private var resolvedCatalogURL: URL? {
        if isEndpointHTTPS {
            return try? StoryModelCatalog.url(endpoint: trimmedEndpoint, approvedLANEndpoint: nil)
        }
        if let approved = currentApprovedLANEndpoint {
            return try? StoryModelCatalog.url(endpoint: approved, approvedLANEndpoint: approved)
        }
        return nil
    }

    private var canFetchModels: Bool {
        guard resolvedCatalogURL != nil, !isFetchingModels else { return false }
        if isEndpointLANHTTP {
            return currentApprovedLANEndpoint != nil
        }
        return !trimmedKey.isEmpty || matchesSavedEndpointExactly
    }

    private var canSave: Bool {
        guard !trimmedModel.isEmpty else { return false }
        if isEndpointLANHTTP {
            return currentApprovedLANEndpoint != nil
        }
        return isEndpointHTTPS && (!trimmedKey.isEmpty || canKeepSavedKey)
    }

    private var filteredModels: [String] {
        let q = modelFilterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return fetchedModels }
        return fetchedModels.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("OpenAI 兼容接口 · 仅确认后联网，可能产生服务商计费")
                        .font(.footnote)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
            .navigationTitle("模型配置")
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
            "删除模型配置？",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("删除配置", role: .destructive) {
                clearConfiguration()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清除接口地址、模型、密钥，并撤销已保存的明文 HTTP 授权；已有故事记录不受影响。")
        }
        .onAppear {
            isViewActive = true
            loadCurrentConfiguration()
        }
        .onDisappear {
            isViewActive = false
            cancelModelFetch(clearResults: false)
        }
        .onChange(of: endpointText) { newValue in
            if programmaticEndpointSnapshot == newValue {
                programmaticEndpointSnapshot = nil
                return
            }
            programmaticEndpointSnapshot = nil
            approvedLANEndpoint = nil
            if !apiKeyText.isEmpty {
                apiKeyText = ""
            }
            cancelModelFetch(clearResults: true)
            catalogFeedback = nil
        }
        .onChange(of: apiKeyText) { _ in
            cancelModelFetch(clearResults: true)
            catalogFeedback = nil
        }
        .accessibilityIdentifier("story.model.sheet")
    }

    private func activeConfigCard(_ config: StoryModelConfiguration) -> some View {
        let isSavedLAN = config.endpoint.scheme?.lowercased() == "http"
        return VStack(alignment: .leading, spacing: 5) {
            Text(isSavedLAN ? "已保存 · 私网 / Tailscale 明文 HTTP" : "已保存配置（密钥不回显）")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSavedLAN ? appearance.sealAccent : appearance.accent)
            Text(config.endpoint.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(appearance.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Text("模型 · \(config.model)")
                .font(.caption.monospaced())
                .foregroundStyle(appearance.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (isSavedLAN ? appearance.sealSoft : appearance.accentSoft).opacity(0.72),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityIdentifier("story.model.savedSummary")
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("接口地址")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 4)
                    Button {
                        showLANHelp.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text("局域网 / Tailscale 说明")
                                .font(.caption2.weight(.medium))
                            Image(systemName: showLANHelp ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(appearance.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("story.model.lanHelpToggle")
                }

                TextField("https://.../v1/chat/completions", text: $endpointText)
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
                                (!trimmedEndpoint.isEmpty && !isEndpointValidFormat) ? appearance.sealAccent : appearance.edge.opacity(0.85),
                                lineWidth: 0.85
                            )
                            .allowsHitTesting(false)
                    }
                    .accessibilityIdentifier("story.model.endpoint")

                if showLANHelp {
                    Text("支持局域网私网或 Tailscale（100.64.0.0/10）IPv4，示例：http://100.80.1.2:2048/v1（在电脑运行 tailscale ip -4 获取，勿填手机 localhost）。仅凭 IP 不代表隧道在线，使用前请先连接 Tailscale。")
                        .font(.caption2)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("story.model.lanHint")
                }

                if !trimmedEndpoint.isEmpty && !isEndpointValidFormat {
                    Text(isLoopbackHTTPInput
                         ? "127.0.0.1 / localhost 是手机本机地址，请改填电脑私网 IPv4 或 tailscale ip -4（如 http://100.80.1.2:2048/v1）。"
                         : "请填写完整 HTTPS 地址，或带端口的局域网私网 / Tailscale（100.64.0.0/10）IPv4 HTTP 地址（/v1 或聊天路径）。")
                        .font(.caption)
                        .foregroundStyle(appearance.sealAccent)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let lanCandidate = lanCandidateEndpoint {
                    lanApprovalCard(normalizedURL: lanCandidate)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("模型")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 4)
                    if isFetchingModels {
                        Button("取消") {
                            cancelModelFetch(clearResults: false)
                            catalogFeedback = (false, "已取消获取模型列表。")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appearance.sealAccent)
                        .accessibilityIdentifier("story.model.cancelFetch")
                    } else {
                        Button {
                            triggerFetchModels()
                        } label: {
                            Label("获取列表", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(canFetchModels ? appearance.accent : appearance.secondary.opacity(0.5))
                        .disabled(!canFetchModels)
                        .accessibilityLabel("主动获取当前接口的模型列表")
                        .accessibilityIdentifier("story.model.fetchModels")
                    }
                }

                TextField("如 gpt-4o-mini（可手填）", text: $modelNameText)
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

                if let catalogURL = resolvedCatalogURL {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("GET \(catalogURL.absoluteString)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(appearance.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if catalogURL.scheme?.lowercased() == "http" {
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .font(.caption2)
                                    .foregroundStyle(appearance.sealAccent)
                                    .accessibilityHidden(true)
                                Text("明文 HTTP：点击“获取列表”才请求，所填 Token 将明文发送。")
                                    .font(.caption2)
                                    .foregroundStyle(appearance.sealAccent)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityIdentifier("story.model.catalogPlaintextNotice")
                        }
                    }
                    .accessibilityIdentifier("story.model.catalogDestination")
                }

                if isFetchingModels {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(appearance.accent)
                            .scaleEffect(0.85)
                        Text("正在获取模型列表…")
                            .font(.caption)
                            .foregroundStyle(appearance.secondary)
                    }
                    .padding(.top, 2)
                    .accessibilityIdentifier("story.model.fetching")
                }

                if let catalogFeedback {
                    Text(catalogFeedback.text)
                        .font(.caption)
                        .foregroundStyle(catalogFeedback.isError ? appearance.sealAccent : appearance.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("story.model.catalogFeedback")
                }

                if !fetchedModels.isEmpty {
                    fetchedModelsPickerBlock
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(isEndpointLANHTTP ? "访问 Token（可留空）" : "API Key")
                    .font(.subheadline.weight(.medium))
                SecureField(
                    matchesSavedEndpointExactly
                        ? "留空沿用当前地址已存密钥"
                        : (isEndpointLANHTTP ? "可留空（无认证），仅用于当前地址" : "输入 API Key"),
                    text: $apiKeyText
                )
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

                if isEndpointLANHTTP {
                    Text(matchesSavedEndpointExactly
                         ? "留空沿用已存设置；修改地址会清空已输入 Token。"
                         : "新建私网 / Tailscale HTTP 地址可留空，不沿用其他地址密钥。")
                        .font(.caption2)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            Text("保存配置")
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
            Text("删除配置")
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

    private func lanApprovalCard(normalizedURL: String) -> some View {
        let isApproved = approvedLANEndpoint == normalizedURL
        let isPersistedForSameURL = savedNormalizedLANEndpoint == normalizedURL
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isApproved ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(isApproved ? appearance.accent : appearance.sealAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isApproved
                         ? (isPersistedForSameURL ? "已复用同址保存的 HTTP 授权" : "已授权此私网 / Tailscale 明文 HTTP 地址")
                         : "需确认私网 / Tailscale 明文 HTTP 风险")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appearance.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(normalizedURL)
                        .font(.caption2.monospaced())
                        .foregroundStyle(appearance.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("story.model.lanNormalizedURL")
                }
            }

            Text("明文 HTTP 不加密，网络路径可能读取内容与 Token；仅凭 IP 不代表 Tailscale 隧道在线，请先确认连接。仅授权以上精确地址，改址自动重置。")
                .font(.caption2)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isApproved {
                if isPersistedForSameURL {
                    Button {
                        focusedField = nil
                        isConfirmingClear = true
                    } label: {
                        Text("撤销授权并清除配置")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(AppControlButtonStyle(
                        foreground: appearance.sealAccent,
                        surface: appearance.surface,
                        border: appearance.sealAccent.opacity(0.35),
                        cornerRadius: 10
                    ))
                    .accessibilityIdentifier("story.model.revokeSavedLAN")
                } else {
                    Button {
                        cancelModelFetch(clearResults: true)
                        catalogFeedback = nil
                        approvedLANEndpoint = nil
                    } label: {
                        Text("取消本次授权")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(AppControlButtonStyle(
                        foreground: appearance.secondary,
                        surface: appearance.surface,
                        border: appearance.edge.opacity(0.8),
                        cornerRadius: 10
                    ))
                    .accessibilityIdentifier("story.model.unapproveLAN")
                }
            } else {
                Button {
                    StoryHaptics.selection()
                    approvedLANEndpoint = normalizedURL
                } label: {
                    Text("确认明文风险并授权此地址")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(AppControlButtonStyle(
                    foreground: appearance.sealAccent,
                    surface: appearance.surface,
                    border: appearance.sealAccent.opacity(0.45),
                    cornerRadius: 10
                ))
                .accessibilityIdentifier("story.model.approveLAN")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (isApproved ? appearance.accentSoft : appearance.sealSoft).opacity(0.85),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    (isApproved ? appearance.accent : appearance.sealAccent).opacity(0.35),
                    lineWidth: 0.8
                )
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("story.model.lanApprovalCard")
    }

    private func setEndpointProgrammatically(_ newValue: String) {
        if endpointText != newValue {
            programmaticEndpointSnapshot = newValue
            endpointText = newValue
        }
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
                let savedURL = loaded.endpoint.absoluteString
                setEndpointProgrammatically(savedURL)
                modelNameText = loaded.model
                if StoryModelVault.lanEndpointCandidate(savedURL) == savedURL {
                    approvedLANEndpoint = savedURL
                } else {
                    approvedLANEndpoint = nil
                }
            } else {
                approvedLANEndpoint = nil
            }
            apiKeyText = ""
        } catch {
            feedbackMessage = (true, "读取本地模型配置失败：\(error.localizedDescription)")
        }
    }

    private var fetchedModelsPickerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if fetchedModels.count > 6 {
                TextField("筛选模型名（共 \(fetchedModels.count) 个）", text: $modelFilterText)
                    .font(.caption)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($focusedField, equals: .modelFilter)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(appearance.subtleSurface.opacity(0.8), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityIdentifier("story.model.filter")
            }

            if filteredModels.isEmpty {
                Text("没有匹配的模型名，可清空筛选或在上方直接手动填写。")
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredModels, id: \.self) { candidate in
                            let selected = trimmedModel == candidate
                            Button {
                                modelNameText = candidate
                                StoryHaptics.selection()
                                catalogFeedback = (false, "已填入「\(candidate)」，保存后生效。")
                            } label: {
                                HStack(spacing: 8) {
                                    Text(candidate)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(selected ? appearance.accent : appearance.foreground)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(appearance.accent)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                .background(
                                    selected ? appearance.accentSoft : appearance.subtleSurface.opacity(0.55),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("选择模型 \(candidate)")
                            .accessibilityValue(selected ? "已填入" : "未选择")
                        }
                    }
                }
                .frame(maxHeight: 196)
                .accessibilityIdentifier("story.model.catalogList")
            }
        }
        .padding(10)
        .background(appearance.subtleSurface.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func cancelModelFetch(clearResults: Bool) {
        activeFetchID = nil
        fetchTask?.cancel()
        fetchTask = nil
        isFetchingModels = false
        if clearResults {
            fetchedModels = []
            modelFilterText = ""
        }
    }

    private func triggerFetchModels() {
        focusedField = nil
        guard isViewActive, canFetchModels else { return }
        let requestedEndpoint = effectiveEndpoint
        let requestedKey = trimmedKey
        let requestedApprovedLAN = currentApprovedLANEndpoint
        let requestID = UUID()

        activeFetchID = requestID
        isFetchingModels = true
        catalogFeedback = nil
        fetchedModels = []
        modelFilterText = ""
        fetchTask?.cancel()

        fetchTask = Task { @MainActor in
            defer {
                if activeFetchID == requestID {
                    isFetchingModels = false
                    activeFetchID = nil
                    fetchTask = nil
                }
            }
            do {
                let models = try await StoryModelCatalog.fetch(
                    endpoint: requestedEndpoint,
                    apiKey: requestedKey,
                    approvedLANEndpoint: requestedApprovedLAN
                )
                guard !Task.isCancelled,
                      activeFetchID == requestID,
                      isViewActive,
                      effectiveEndpoint == requestedEndpoint,
                      trimmedKey == requestedKey,
                      currentApprovedLANEndpoint == requestedApprovedLAN else {
                    return
                }
                fetchedModels = models
                if models.isEmpty {
                    catalogFeedback = (true, "未返回可用模型，可手动填写。")
                } else {
                    catalogFeedback = (false, "已获取 \(models.count) 个模型，选择后需点击保存。")
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      activeFetchID == requestID,
                      isViewActive,
                      effectiveEndpoint == requestedEndpoint,
                      trimmedKey == requestedKey,
                      currentApprovedLANEndpoint == requestedApprovedLAN else {
                    return
                }
                catalogFeedback = (true, "获取模型列表失败（可继续手动填写）：\(error.localizedDescription)")
            }
        }
    }

    private func saveConfiguration() {
        focusedField = nil
        guard canSave else { return }
        let targetEndpoint = effectiveEndpoint
        let approvedLAN = currentApprovedLANEndpoint
        do {
            if canKeepSavedKey {
                try StoryModelVault.saveKeepingKey(
                    endpoint: targetEndpoint,
                    model: trimmedModel,
                    approvedLANEndpoint: approvedLAN
                )
            } else {
                try StoryModelVault.save(
                    endpoint: targetEndpoint,
                    model: trimmedModel,
                    apiKey: trimmedKey,
                    approvedLANEndpoint: approvedLAN
                )
            }
            let reloaded = try StoryModelVault.load()
            existingConfig = reloaded
            if let reloaded {
                let savedURL = reloaded.endpoint.absoluteString
                setEndpointProgrammatically(savedURL)
                approvedLANEndpoint = (StoryModelVault.lanEndpointCandidate(savedURL) == savedURL) ? savedURL : nil
            } else {
                approvedLANEndpoint = nil
            }
            apiKeyText = ""
            feedbackMessage = (
                false,
                approvedLAN != nil
                    ? "已保存明文 HTTP 配置（仅限此精确地址）。"
                    : "已保存模型配置。"
            )
            onSaved(reloaded)
        } catch {
            feedbackMessage = (true, "保存配置失败：\(error.localizedDescription)")
        }
    }

    private func clearConfiguration() {
        focusedField = nil
        cancelModelFetch(clearResults: true)
        catalogFeedback = nil
        do {
            try StoryModelVault.clear()
            existingConfig = nil
            approvedLANEndpoint = nil
            setEndpointProgrammatically("")
            modelNameText = ""
            apiKeyText = ""
            feedbackMessage = (false, "已删除配置并撤销明文 HTTP 授权。")
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

    private var isPlaintextHTTP: Bool {
        draft.endpoint.scheme?.lowercased() == "http"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    targetSummaryCard
                    if isPlaintextHTTP {
                        plaintextHTTPNoticeCard
                    }
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
            Text(isPlaintextHTTP ? "即将向已授权的私网 / Tailscale HTTP 接口发送本局上下文" : "即将向你配置的远端接口发送本局上下文")
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

    private var plaintextHTTPNoticeCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.subheadline)
                .foregroundStyle(appearance.sealAccent)
                .accessibilityHidden(true)
            Text("明文 HTTP 提醒：本次将通过未加密 HTTP 向 \(draft.endpoint.absoluteString) 发送本局上下文并接收回复；仅凭 IP 不代表 Tailscale 隧道在线，请确认网络与电脑服务可信后再发送。")
                .font(.caption)
                .foregroundStyle(appearance.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.sealSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(appearance.sealAccent.opacity(0.38), lineWidth: 0.8)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("story.genConfirm.plaintextNotice")
    }

    private var billingNoticeCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "network")
                .font(.subheadline)
                .foregroundStyle(appearance.sealAccent)
                .accessibilityHidden(true)
            Text(isPlaintextHTTP
                 ? "确认后将向已授权的私网 / Tailscale 电脑服务发起真实网络请求。生成中途取消或断流不会保存半回合，也不会自动重试。"
                 : "确认后将发起真实网络请求并可能产生第三方模型服务计费。生成中途取消或断流不会保存半回合，也不会自动重试。")
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

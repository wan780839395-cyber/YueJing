import Foundation
import ReaderDomain
import SwiftUI

/// Lightweight modal sheet for inspecting pending per-session story memory items
/// and explicitly initiating user-confirmed memory repair without interrupting normal reading.
@MainActor
struct StoryMemoryRepairSheet: View {
    let bookTitle: String
    let pendingTurns: [StoryTurn]
    let highlightedTurnID: UUID?
    let hasModelConfig: Bool
    let isLoadingPending: Bool
    let preparingTurnID: UUID?
    let isRepairing: Bool
    let repairingSequence: Int?
    let isOtherNetworkBusy: Bool
    let statusMessage: String?
    let appearance: LibraryAppearance
    @Binding var pendingDraft: StoryMemoryRepairDraft?
    let onRefreshPending: () -> Void
    let onPrepareRepair: (StoryTurn) -> Void
    let onConfirmRepair: (StoryMemoryRepairDraft) -> Void
    let onCancelDraft: () -> Void
    let onCancelRepair: () -> Void
    let onOpenModelConfig: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var primaryButtonForeground: Color {
        appearance.isDarkSurface ? Color.black.opacity(0.9) : Color.white
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("《\(bookTitle)》· 已保存正文不受影响，仅在确认预览后补记缺失的本局记忆，不会生成新回合。")
                        .font(.footnote)
                        .foregroundStyle(appearance.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let statusMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .font(.caption)
                                .foregroundStyle(appearance.sealAccent)
                                .accessibilityHidden(true)
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundStyle(appearance.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(appearance.sealSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityIdentifier("story.memory.status")
                    }

                    if isRepairing {
                        repairingBanner
                    }

                    if !hasModelConfig {
                        unconfiguredModelCard
                    }

                    if isLoadingPending && pendingTurns.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(appearance.accent)
                            Text("正在检查本局待补记幕次…")
                                .font(.subheadline)
                                .foregroundStyle(appearance.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(appearance.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityIdentifier("story.memory.loading")
                    } else if pendingTurns.isEmpty {
                        emptyPendingCard
                    } else {
                        pendingTurnsList
                    }
                }
                .padding(.horizontal, LibraryAppearance.horizontalInset)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(appearance.page.ignoresSafeArea())
            .foregroundStyle(appearance.foreground)
            .tint(appearance.accent)
            .navigationTitle("本局记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(appearance.page, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(appearance.controlColorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        onRefreshPending()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline.weight(.medium))
                    }
                    .disabled(isLoadingPending || preparingTurnID != nil || isRepairing)
                    .accessibilityLabel("重新检查本地待补记幕次")
                    .accessibilityIdentifier("story.memory.refresh")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .font(AppVisualStyle.actionFont)
                    .foregroundStyle(appearance.accent)
                    .accessibilityIdentifier("story.memory.close")
                }
            }
            .sheet(item: $pendingDraft) { draft in
                StoryMemoryRepairConfirmSheet(
                    draft: draft,
                    appearance: appearance,
                    onConfirm: { confirmed in
                        onConfirmRepair(confirmed)
                    },
                    onCancel: {
                        onCancelDraft()
                    }
                )
            }
        }
        .accessibilityIdentifier("story.memory.sheet")
    }

    private var repairingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(appearance.accent)
                .scaleEffect(0.85)
            Text(repairingSequence.map { "正在补记第 \($0) 幕记忆…" } ?? "正在补记本局记忆…")
                .font(.caption.weight(.medium))
                .foregroundStyle(appearance.foreground)
            Spacer(minLength: 4)
            Button("取消") {
                onCancelRepair()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(appearance.sealAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(appearance.sealSoft, in: Capsule())
            .accessibilityLabel("取消本次记忆补记")
            .accessibilityIdentifier("story.memory.sheetCancel")
        }
        .padding(12)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(appearance.accent.opacity(0.35), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("story.memory.repairingCard")
    }

    private var unconfiguredModelCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("未配置模型接口")
                    .font(.subheadline.weight(.semibold))
                Text("补记需要向已配置的 OpenAI 兼容接口发送本幕正文，请先配置模型。")
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("去配置") {
                onOpenModelConfig()
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .buttonStyle(AppControlButtonStyle(
                foreground: primaryButtonForeground,
                surface: appearance.accent,
                cornerRadius: 10
            ))
            .disabled(isRepairing || preparingTurnID != nil || isOtherNetworkBusy)
            .accessibilityIdentifier("story.memory.configureModel")
        }
        .padding(14)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.8), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }

    private var emptyPendingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(appearance.accent)
                    .accessibilityHidden(true)
                Text("暂无待补记幕次")
                    .font(.subheadline.weight(.semibold))
            }
            Text("当前所有已保存回合均无本局记忆缺口，无需额外联网操作。")
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(appearance.edge.opacity(0.75), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("story.memory.empty")
    }

    private var pendingTurnsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("待补记幕次（共 \(pendingTurns.count) 幕）")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appearance.foreground)
                .accessibilityAddTraits(.isHeader)

            ForEach(pendingTurns) { turn in
                let isHighlighted = highlightedTurnID == turn.id
                let isPreparingThisTurn = preparingTurnID == turn.id
                let canTrigger = hasModelConfig
                    && preparingTurnID == nil
                    && !isRepairing
                    && !isOtherNetworkBusy
                    && pendingDraft == nil

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("第 \(turn.sequence) 幕")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(appearance.foreground)
                        Text("正文已保存 · 待补记")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(appearance.sealAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(appearance.sealSoft, in: Capsule())
                        Spacer(minLength: 4)
                    }

                    Text(turn.narration.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.footnote)
                        .lineSpacing(3)
                        .foregroundStyle(appearance.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        onPrepareRepair(turn)
                    } label: {
                        HStack(spacing: 6) {
                            if isPreparingThisTurn {
                                ProgressView()
                                    .tint(primaryButtonForeground)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.caption.weight(.semibold))
                                    .accessibilityHidden(true)
                            }
                            Text("预览并补记第 \(turn.sequence) 幕")
                                .font(.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(AppControlButtonStyle(
                        foreground: primaryButtonForeground,
                        surface: appearance.accent,
                        cornerRadius: 12
                    ))
                    .disabled(!canTrigger)
                    .accessibilityLabel("预览发送清单并补记第 \(turn.sequence) 幕本局记忆")
                    .accessibilityIdentifier("story.memory.prepare.\(turn.sequence)")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(appearance.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            isHighlighted ? appearance.sealAccent.opacity(0.65) : appearance.edge.opacity(0.75),
                            lineWidth: isHighlighted ? 1.2 : 0.75
                        )
                        .allowsHitTesting(false)
                }
                .accessibilityIdentifier("story.memory.pending.\(turn.sequence)")
            }
        }
    }
}

/// Pre-flight confirmation sheet shown before sending a memory-repair network request.
/// Displays exact endpoint, model, target act scope, billing notice, HTTP plaintext warning,
/// and the complete frozen message list.
@MainActor
struct StoryMemoryRepairConfirmSheet: View {
    let draft: StoryMemoryRepairDraft
    let appearance: LibraryAppearance
    let onConfirm: (StoryMemoryRepairDraft) -> Void
    let onCancel: () -> Void

    @State private var expandedMessageIndices: Set<Int> = []

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
                    summaryCard
                    if isPlaintextHTTP {
                        plaintextHTTPNoticeCard
                    }
                    billingNoticeCard
                    messagesPreviewSection
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
            .navigationTitle("确认补记记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(appearance.page, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(appearance.controlColorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { onCancel() }
                        .font(AppVisualStyle.actionFont)
                        .foregroundStyle(appearance.secondary)
                        .accessibilityIdentifier("story.memoryConfirm.cancelTop")
                }
            }
        }
        .accessibilityIdentifier("story.memoryConfirm.sheet")
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isPlaintextHTTP
                 ? "即将向已授权的明文 HTTP 接口补记第 \(draft.sequence) 幕记忆"
                 : "即将向你配置的接口补记第 \(draft.sequence) 幕记忆")
                .font(.subheadline.weight(.semibold))
            infoRow(label: "完整端点", value: draft.endpoint.absoluteString, monospaced: true)
            infoRow(label: "目标模型", value: draft.model, monospaced: true)
            infoRow(label: "补记范围", value: "仅整理第 \(draft.sequence) 幕已保存正文记忆，不生成新回合", monospaced: false)
            infoRow(label: "发送消息", value: "共 \(draft.messages.count) 条（仅本幕补记指令与正文）", monospaced: false)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous))
        .overlay { cardBorder(appearance.edge.opacity(0.8)) }
        .accessibilityIdentifier("story.memoryConfirm.summary")
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
            Text("明文 HTTP 提醒：本次将通过未加密 HTTP 向 \(draft.endpoint.absoluteString) 发送第 \(draft.sequence) 幕正文用于补记并接收结果，网络路径可能读取内容与密钥（部分明文域名可能受系统 ATS 拦截）。")
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
        .accessibilityIdentifier("story.memoryConfirm.plaintextNotice")
    }

    private var billingNoticeCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "network")
                .font(.subheadline)
                .foregroundStyle(appearance.sealAccent)
                .accessibilityHidden(true)
            Text(isPlaintextHTTP
                 ? "确认后将向已授权的明文 HTTP 接口发起一次真实网络请求，仅用于补记本幕记忆。取消或失败会保留正文与待补记项，不会自动重试。"
                 : "确认后将发起一次真实网络请求并可能产生第三方模型服务计费，仅用于补记本幕记忆。取消或失败会保留正文与待补记项，不会自动重试。")
                .font(.caption)
                .foregroundStyle(appearance.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.sealSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("story.memoryConfirm.billingNotice")
    }

    private var messagesPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按序发送的消息（共 \(draft.messages.count) 条）")
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
                .accessibilityIdentifier("story.memoryConfirm.message.\(idx)")
            }
        }
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
        .accessibilityIdentifier("story.memoryConfirm.cancel")
    }

    private var confirmBtn: some View {
        Button {
            onConfirm(draft)
        } label: {
            Text("确认并补记")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(AppControlButtonStyle(
            foreground: primaryButtonForeground,
            surface: appearance.accent,
            cornerRadius: 14
        ))
        .accessibilityIdentifier("story.memoryConfirm.send")
    }

    private func cardBorder(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)
            .strokeBorder(color, lineWidth: 0.75)
            .allowsHitTesting(false)
    }
}

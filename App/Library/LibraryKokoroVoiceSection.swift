import Foundation
import SwiftUI

/// Compact optional offline Kokoro voice pack controls embedded in library settings.
@MainActor
struct LibraryKokoroVoiceSection: View {
    let appearance: LibraryAppearance
    let canChange: Bool
    @ObservedObject private var store = KokoroPackStore.shared

    @State private var isRemoveConfirmationPresented = false
    @State private var isRemoving = false

    @Environment(\.dynamicTypeSize) private var dynamicType

    private var isInstalled: Bool { store.installedDirectory != nil }
    private var isBusy: Bool { store.isInstalling || isRemoving }
    private var isActivelyInstalling: Bool { store.isInstalling && !isRemoving }
    private var canInteract: Bool { canChange && !isBusy }

    private var trimmedStatusText: String {
        store.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var clampedDownloadProgress: Double? {
        guard let value = store.downloadProgress, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    private var isFailureStatus: Bool {
        guard !isBusy, !trimmedStatusText.isEmpty else { return false }
        let lowered = trimmedStatusText.lowercased()
        let failureTokens = [
            "失败", "错误", "无法", "未能", "未安装新语音包",
            "缺少", "无效", "不支持", "未找到", "损坏",
            "超时", "空间不足", "中断", "断开", "异常", "未完成", "重试",
            "error", "fail", "missing", "invalid", "timeout"
        ]
        return failureTokens.contains { lowered.contains($0) }
    }

    private var quietIdleStatusText: String? {
        guard !isBusy, !isFailureStatus, !trimmedStatusText.isEmpty else { return nil }
        if trimmedStatusText == "未安装本地语音包" || trimmedStatusText == "本地语音包已就绪" {
            return nil
        }
        return trimmedStatusText
    }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: LibraryAppearance.cardCornerRadius, style: .continuous)

        VStack(alignment: .leading, spacing: 10) {
            sectionHeader

            VStack(spacing: 0) {
                if isRemoving {
                    indeterminateRow(message: "正在移除离线语音包…")
                } else if isActivelyInstalling {
                    installingContent
                } else if isInstalled {
                    installedContent
                } else {
                    uninstalledContent
                }
            }
            .background(appearance.surface, in: cardShape)
            .clipShape(cardShape)
            .overlay {
                cardShape
                    .strokeBorder(appearance.edge.opacity(0.8), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .shadow(color: appearance.cardShadow, radius: 6, x: 0, y: 2)

            Text("离线语音仅在本机合成，不上传正文；未安装或不可用时自动使用系统语音。")
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(
            "移除离线语音包？",
            isPresented: $isRemoveConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("移除语音包", role: .destructive) {
                confirmRemove()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后将释放存储空间，听书会自动回退到系统语音。")
        }
        .onChange(of: canChange) { allowed in
            if !allowed {
                isRemoveConfirmationPresented = false
            }
        }
        .onChange(of: store.isInstalling) { installing in
            if installing {
                isRemoveConfirmationPresented = false
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(appearance.accent)
                .frame(width: 3, height: 15)
                .accessibilityHidden(true)
            Text("听书语音")
                .font(LibraryAppearance.sectionTitleFont)
                .foregroundStyle(appearance.foreground)
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private var installedContent: some View {
        Toggle(isOn: $store.useKokoro) {
            VStack(alignment: .leading, spacing: 2) {
                Text("使用 Kokoro 离线语音")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(appearance.foreground)
                Text(store.useKokoro ? "当前优先使用离线语音，不可用时自动回退系统语音。" : "当前使用系统语音，开启后优先使用离线语音。")
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(appearance.accent)
        .disabled(!canInteract)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityLabel("使用 Kokoro 离线语音")
        .accessibilityValue(store.useKokoro ? "已开启，当前使用 Kokoro 离线语音" : "已关闭，当前使用系统语音")
        .accessibilityHint("关闭时使用系统语音，开启后优先使用已下载的离线语音包")
        .accessibilityIdentifier("library.voice.kokoro.toggle")

        if isFailureStatus {
            rowDivider
            failureRow(message: trimmedStatusText)
        }

        rowDivider

        Button(role: .destructive) {
            guard canInteract, isInstalled else { return }
            isRemoveConfirmationPresented = true
        } label: {
            Text("移除离线语音包")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: LibraryAppearance.minimumControlHeight, alignment: .leading)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(AppControlButtonStyle(foreground: appearance.sealAccent, cornerRadius: 0))
        .disabled(!canInteract)
        .accessibilityLabel("移除离线语音包")
        .accessibilityHint("删除应用内已下载的语音包并回退到系统语音")
        .accessibilityIdentifier("library.voice.kokoro.remove")
    }

    @ViewBuilder
    private var uninstalledContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("系统语音")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(appearance.foreground)
            Text("默认使用系统语音；可按需下载 Kokoro 离线语音包。")
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isFailureStatus {
                failureNotice(message: trimmedStatusText)
                    .padding(.top, 2)
            } else if let quietStatus = quietIdleStatusText {
                Text(quietStatus)
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("library.voice.kokoro.status")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)

        rowDivider

        Button {
            startDownload()
        } label: {
            Text(isFailureStatus ? "重试下载离线语音包（约 147 MB）" : "下载离线语音包（约 147 MB）")
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: LibraryAppearance.minimumControlHeight, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(AppControlButtonStyle(foreground: appearance.accent, cornerRadius: 0))
        .disabled(!canInteract)
        .accessibilityLabel(isFailureStatus ? "重试下载离线语音包，约 147 MB" : "下载离线语音包，约 147 MB")
        .accessibilityHint(isFailureStatus ? "重新下载并安装 Kokoro 离线语音包" : "下载并安装 Kokoro 离线语音包，用于本地离线听书")
        .accessibilityIdentifier("library.voice.kokoro.download")
    }

    @ViewBuilder
    private var installingContent: some View {
        if let progress = clampedDownloadProgress {
            downloadProgressRow(progress: progress)
        } else {
            indeterminateRow(message: trimmedStatusText.isEmpty ? "正在校验并安装离线语音包…" : trimmedStatusText)
        }

        if store.canCancelDownload {
            rowDivider
            Button(role: .cancel) {
                cancelDownload()
            } label: {
                Text("取消下载")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: LibraryAppearance.minimumControlHeight, alignment: .leading)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AppControlButtonStyle(foreground: appearance.sealAccent, cornerRadius: 0))
            .disabled(!canChange)
            .accessibilityLabel("取消下载离线语音包")
            .accessibilityHint("停止当前下载，继续使用系统语音")
            .accessibilityIdentifier("library.voice.kokoro.cancel")
        }
    }

    private func downloadProgressRow(progress: Double) -> some View {
        let percent = Int((progress * 100).rounded())
        let labelText = trimmedStatusText.isEmpty ? "正在下载离线语音包…" : trimmedStatusText

        return VStack(alignment: .leading, spacing: 8) {
            if dynamicType.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(labelText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(appearance.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(percent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(appearance.secondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(labelText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(appearance.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text("\(percent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(appearance.secondary)
                }
            }

            ProgressView(value: progress, total: 1)
                .progressViewStyle(.linear)
                .tint(appearance.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(labelText)
        .accessibilityValue("\(percent)%")
        .accessibilityIdentifier("library.voice.kokoro.progress")
    }

    private func indeterminateRow(message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(appearance.accent)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(appearance.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: LibraryAppearance.minimumControlHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityIdentifier("library.voice.kokoro.status")
    }

    private func failureRow(message: String) -> some View {
        failureNotice(message: message)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    private func failureNotice(message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(appearance.sealAccent)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .foregroundStyle(appearance.sealAccent)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("语音包错误：\(message)")
        .accessibilityIdentifier("library.voice.kokoro.status")
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(appearance.edge.opacity(0.65))
            .frame(height: 0.5)
            .padding(.leading, 14)
            .accessibilityHidden(true)
    }

    private func startDownload() {
        guard canInteract else { return }
        Task { @MainActor in
            await store.downloadAndInstall()
        }
    }

    private func cancelDownload() {
        guard canChange, store.canCancelDownload, !isRemoving else { return }
        store.cancelDownload()
    }

    private func confirmRemove() {
        guard canInteract, isInstalled else { return }
        isRemoving = true
        Task { @MainActor in
            defer { isRemoving = false }
            await store.remove()
        }
    }
}

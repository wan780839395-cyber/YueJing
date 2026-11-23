import CoreText
import ReaderDomain
import SwiftUI

@MainActor
struct EPUBUserFontPicker: View {
    let selectedID: String?
    let isActive: @MainActor () -> Bool
    let select: @MainActor (EPUBUserFont?) -> Void
    let appearance: ReaderToolAppearance
    @State private var fonts: [EPUBUserFont] = []
    @State private var attempt: EPUBFontFilePicker.Attempt?
    // A provider may dismiss its sheet before delivering the delegate callback.
    @State private var activeAttemptID: UUID?
    @State private var importing = false
    @State private var loading = true
    @State private var notice: String?
    @State private var isError = false
    @State private var preview: Font?
    @State private var importTask: Task<Void, Never>?

    private var selectionName: String {
        guard let selectedID else { return "跟随原书" }
        return fonts.first { $0.id == selectedID }?.displayName ?? (loading ? "正在读取字体…" : "所选字体不可用")
    }

    var body: some View {
        EPUBUserFontCard(selectionName: selectionName, fonts: fonts, selectedID: selectedID, preview: preview,
            isLoading: loading, isImporting: importing, notice: notice, isError: isError, appearance: appearance,
            select: { font in
                guard isActive(), !importing else { return }
                notice = nil; isError = false; select(font)
            }, openFiles: {
                guard isActive(), !importing, attempt == nil else { return }
                let next = EPUBFontFilePicker.Attempt()
                notice = nil; isError = false; activeAttemptID = next.id; attempt = next
            })
        .task { await refreshList() }
        .task(id: selectedID) {
            preview = nil
            guard let selectedID else { return }
            do {
                let bytes = try await EPUBUserFontStore.shared.data(for: selectedID)
                guard !Task.isCancelled, isActive() else { return }
                guard let provider = CGDataProvider(data: bytes as CFData), let face = CGFont(provider) else {
                    report("无法预览所选字体，可选择跟随原书。", error: true); return
                }
                preview = Font(CTFontCreateWithGraphicsFont(face, 19, nil, nil))
            } catch {
                if !Task.isCancelled, isActive() { report("所选字体不可用，可重新导入或选择跟随原书。", error: true) }
            }
        }
        .sheet(item: $attempt) { presented in
            EPUBFontFilePicker { outcome in
                guard activeAttemptID == presented.id, isActive() else { return }
                activeAttemptID = nil
                attempt = nil
                switch outcome {
                case .selected(let url): importSelection(url)
                case .unsupported: report("请选择 .ttf 或 .otf 字体文件；如果是压缩包，请先解压。", error: true)
                case .unavailable: report("没有取得可读取的文件。请先在“文件”中下载字体，再重试。", error: true)
                case .cancelled: break
                }
            }
        }
        .onDisappear { importTask?.cancel(); importTask = nil; importing = false }
    }

    private func importSelection(_ url: URL) {
        importTask?.cancel(); importing = true; notice = nil
        importTask = Task { @MainActor in
            defer { if !Task.isCancelled { importing = false } }
            do {
                let font = try await EPUBUserFontStore.shared.importFont(from: url)
                guard !Task.isCancelled, isActive() else { return }
                let existed = fonts.contains { $0.id == font.id }
                fonts = sorted(fonts.filter { $0.id != font.id } + [font])
                select(font)
                report((existed ? "字体已在库中：" : "已导入：") + font.displayName, error: false)
            } catch EPUBError.limitExceeded {
                if !Task.isCancelled, isActive() { report("超过字体容量限制：单个最多 8 MiB，字体库共 32 MiB。", error: true) }
            } catch EPUBError.corruptResource {
                if !Task.isCancelled, isActive() { report("文件不是完整的 TTF/OTF 字体，请重新下载后再试。", error: true) }
            } catch EPUBError.unsupportedContent {
                if !Task.isCancelled, isActive() { report("此文件不是支持的 TTF/OTF 字体，修改后缀不能转换格式。", error: true) }
            } catch {
                if !Task.isCancelled, isActive() { report("无法读取或保存文件。请先在“文件”中下载，或存到“我的 iPhone”后重试。", error: true) }
            }
        }
    }
    private func sorted(_ records: [EPUBUserFont]) -> [EPUBUserFont] {
        records.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    private func report(_ text: String, error: Bool) { notice = text; isError = error }
    private func refreshList() async {
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            let available = try await EPUBUserFontStore.shared.list()
            guard !Task.isCancelled, isActive() else { return }
            fonts = sorted(available)
        } catch {
            if !Task.isCancelled, isActive() { report("暂时无法读取字体库。", error: true) }
        }
    }
}

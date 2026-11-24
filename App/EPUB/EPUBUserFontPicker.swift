import CoreText
import ReaderDomain
import SwiftUI

@MainActor
struct EPUBUserFontPicker: View {
    enum Context: Equatable, Sendable {
        case epub
        case txt

        var defaultOptionTitle: String {
            switch self {
            case .epub: return "跟随原书"
            case .txt: return "系统默认"
            }
        }

        var sectionDetail: LocalizedStringKey {
            switch self {
            case .epub: return "仅对本书生效，可随时切回原书字体"
            case .txt: return "仅对本书生效，可随时切回系统默认字体"
            }
        }

        var resetAccessibilityLabel: String {
            switch self {
            case .epub: return "切回跟随原书字体"
            case .txt: return "切回系统默认字体"
            }
        }

        var emptySelectionHint: String {
            switch self {
            case .epub: return "当前暂无已导入字体，可选择跟随原书或从下方导入"
            case .txt: return "当前暂无已导入字体，可保持系统默认或从下方导入"
            }
        }

        var populatedSelectionHint: String {
            switch self {
            case .epub: return "轻点选择跟随原书或已导入字体"
            case .txt: return "轻点选择系统默认或已导入字体"
            }
        }

        var deleteAlertMessage: String {
            switch self {
            case .epub: return "仅删除阅境字体库中的副本，不影响原字体文件。使用它的所有书籍将跟随原书字体。"
            case .txt: return "仅删除阅境字体库中的副本，不影响原字体文件。使用它的书籍将恢复默认字体（EPUB 将跟随原书）。"
            }
        }

        var previewFailureNotice: String {
            switch self {
            case .epub: return "无法预览所选字体，可选择跟随原书。"
            case .txt: return "无法预览所选字体，可切回系统默认。"
            }
        }

        var unavailableFontNotice: String {
            switch self {
            case .epub: return "所选字体不可用，可重新导入或选择跟随原书。"
            case .txt: return "所选字体不可用，可重新导入或切回系统默认。"
            }
        }
    }

    private struct PreviewKey: Equatable {
        let selectedID: String?
        let showsSpecimen: Bool
    }

    let selectedID: String?
    let isActive: @MainActor () -> Bool
    let select: @MainActor (EPUBUserFont?) -> Void
    let appearance: ReaderToolAppearance
    let context: Context
    let showsSpecimen: Bool
    @State private var fonts: [EPUBUserFont] = []
    @State private var attempt: EPUBFontFilePicker.Attempt?
    // A provider may dismiss its sheet before delivering the delegate callback.
    @State private var activeAttemptID: UUID?
    @State private var importing = false
    @State private var pendingRemoval: EPUBUserFont?
    @State private var deleting = false
    @State private var listRevision = UUID()
    @State private var loading = true
    @State private var notice: String?
    @State private var isError = false
    @State private var preview: Font?
    @State private var importTask: Task<Void, Never>?

    init(
        selectedID: String?,
        isActive: @escaping @MainActor () -> Bool,
        select: @escaping @MainActor (EPUBUserFont?) -> Void,
        appearance: ReaderToolAppearance,
        context: Context = .epub,
        showsSpecimen: Bool = true
    ) {
        self.selectedID = selectedID
        self.isActive = isActive
        self.select = select
        self.appearance = appearance
        self.context = context
        self.showsSpecimen = showsSpecimen
    }

    private var selectionName: String {
        guard let selectedID else { return context.defaultOptionTitle }
        return fonts.first { $0.id == selectedID }?.displayName ?? (loading ? "正在读取字体…" : "所选字体不可用")
    }

    var body: some View {
        EPUBUserFontCard(selectionName: selectionName, fonts: fonts, selectedID: selectedID, preview: preview,
            isLoading: loading, isImporting: importing, isDeleting: deleting,
            notice: notice, isError: isError, appearance: appearance,
            context: context, showsSpecimen: showsSpecimen, isActive: isActive(),
            select: { font in
                guard isActive(), !importing, !deleting, font.map({ fonts.contains($0) }) != false else { return }
                notice = nil; isError = false; select(font)
            }, openFiles: {
                guard isActive(), !importing, !deleting, attempt == nil else { return }
                let next = EPUBFontFilePicker.Attempt()
                notice = nil; isError = false; activeAttemptID = next.id; attempt = next
            }, requestRemoval: { font in
                guard canRemove(font) else { return }
                pendingRemoval = font
            })
        .alert(item: $pendingRemoval) { font in
            Alert(title: Text("删除“\(font.displayName)”？"),
                  message: Text(context.deleteAlertMessage),
                  primaryButton: .destructive(Text("删除")) { removeConfirmed(font) },
                  secondaryButton: .cancel(Text("取消")))
        }
        .onReceive(EPUBUserFontPreference.removed) { id in
            if pendingRemoval?.id == id { pendingRemoval = nil }
            if selectedID == id { preview = nil }
            fonts.removeAll { $0.id == id }
            listRevision = UUID()
        }
        .task(id: listRevision) { await refreshList() }
        .task(id: PreviewKey(selectedID: selectedID, showsSpecimen: showsSpecimen)) {
            preview = nil
            guard showsSpecimen, let selectedID else { return }
            do {
                let bytes = try await EPUBUserFontStore.shared.data(for: selectedID)
                guard !Task.isCancelled, isActive() else { return }
                guard let provider = CGDataProvider(data: bytes as CFData), let face = CGFont(provider) else {
                    report(context.previewFailureNotice, error: true); return
                }
                preview = Font(CTFontCreateWithGraphicsFont(face, 19, nil, nil))
            } catch {
                if !Task.isCancelled, isActive() { report(context.unavailableFontNotice, error: true) }
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

    private func canRemove(_ font: EPUBUserFont) -> Bool {
        isActive() && !deleting && !importing && !loading && attempt == nil && fonts.contains(font)
    }

    private func removeConfirmed(_ font: EPUBUserFont) {
        guard canRemove(font) else { return }
        deleting = true
        notice = nil
        Task { @MainActor in
            defer { deleting = false }
            do {
                try await EPUBUserFontPreference.remove(font.id)
                if isActive() { report("已从字体库删除：" + font.displayName, error: false) }
            } catch {
                guard isActive() else { return }
                report("未能删除字体库副本，字体选择未更改。请重新打开字体设置后再试。", error: true)
            }
        }
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
                if !Task.isCancelled, isActive() { report("超过字体容量限制：单个最多 \(EPUBUserFontStore.maxFontMiB) MiB，字体库共 32 MiB。", error: true) }
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

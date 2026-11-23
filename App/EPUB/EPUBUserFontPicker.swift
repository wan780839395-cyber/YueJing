import SwiftUI
import CoreText
import UniformTypeIdentifiers
import ReaderDomain

@MainActor
struct EPUBUserFontPicker: View {
    let selectedID: String?
    let isActive: @MainActor () -> Bool
    let select: @MainActor (EPUBUserFont?) -> Void
    @State private var fonts: [EPUBUserFont] = []
    @State private var showingFiles = false
    @State private var importing = false
    @State private var problem: String?
    @State private var preview: Font?
    @State private var importTask: Task<Void, Never>?

    private var selectionName: String {
        guard let selectedID else { return "跟随原书" }
        return fonts.first { $0.id == selectedID }?.displayName ?? "已选字体（未找到名称）"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("正文字体").font(.headline)
            Menu {
                Button("跟随原书") { if isActive() { select(nil) } }
                ForEach(fonts) { font in
                    Button { if isActive() { select(font) } } label: {
                        if font.id == selectedID { Label(font.displayName, systemImage: "checkmark") }
                        else { Text(font.displayName) }
                    }
                }
            } label: {
                Label(selectionName, systemImage: "textformat").frame(minHeight: 44)
            }
            .disabled(importing)
            .accessibilityLabel("当前书的正文字体：\(selectionName)")
            .accessibilityIdentifier("epub.font.selection")
            Text("山间有风，书中有光。Aa 123").font(preview ?? .body)
                .accessibilityLabel("字体预览：山间有风，书中有光。Aa 123")
            Button { showingFiles = true } label: {
                Label(importing ? "正在导入…" : "从文件导入字体", systemImage: "folder").frame(minHeight: 44)
            }.disabled(importing || !isActive()).accessibilityIdentifier("epub.font.import")
            Text("仅更换这本书的正文。支持 TTF、OTF，单个最多 8 MiB。")
                .font(.footnote).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.footnote).accessibilityIdentifier("epub.font.notice") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await refreshList() }
        .task(id: selectedID) {
            preview = nil
            guard let selectedID else { return }
            do {
                let bytes = try await EPUBUserFontStore.shared.data(for: selectedID)
                guard !Task.isCancelled, isActive() else { return }
                guard let provider = CGDataProvider(data: bytes as CFData), let face = CGFont(provider) else {
                    problem = "无法预览所选字体，可选择跟随原书。"; return
                }
                preview = Font(CTFontCreateWithGraphicsFont(face, 19, nil, nil))
            } catch {
                if !Task.isCancelled, isActive() { problem = "所选字体不可用，可重新导入或选择跟随原书。" }
            }
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: ["ttf", "otf"].compactMap { UTType(filenameExtension: $0) },
                      allowsMultipleSelection: false) { result in
            guard isActive() else { return }
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importTask?.cancel()
                importing = true; problem = nil
                importTask = Task { @MainActor in
                    defer { if !Task.isCancelled { importing = false } }
                    do {
                        let font = try await EPUBUserFontStore.shared.importFont(from: url)
                        guard !Task.isCancelled, isActive() else { return }
                        await refreshList()
                        guard !Task.isCancelled, isActive() else { return }
                        select(font)
                    } catch EPUBError.limitExceeded {
                        if !Task.isCancelled, isActive() { problem = "超过字体容量限制（单个 8 MiB，字体库 32 MiB）。" }
                    } catch {
                        if !Task.isCancelled, isActive() { problem = "未能导入。请选取完整的本地 TTF 或 OTF 字体。" }
                    }
                }
            case .failure(let error):
                let e = error as NSError
                if !(e.domain == NSCocoaErrorDomain && e.code == NSUserCancelledError) { problem = "无法读取所选文件。" }
            }
        }
        .onDisappear { importTask?.cancel(); importTask = nil; importing = false }
    }

    private func refreshList() async {
        do {
            let available = try await EPUBUserFontStore.shared.list()
            guard !Task.isCancelled, isActive() else { return }
            fonts = available.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        } catch {
            if !Task.isCancelled, isActive() { problem = "暂时无法读取字体库。" }
        }
    }
}

import Combine
import Foundation
import ReaderDomain
import TXTCore

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var service: LibraryService?
    @Published private(set) var books: [LibraryBook] = []
    @Published private(set) var importing = false
    @Published var encodingChoice: EncodingChoice?
    @Published var message: String?
    @Published private(set) var importDiagnostics = ImportDiagnosticState()
    private var ticket: UUID?
    private var importTask: Task<Void, Never>?
    private var stageSink: (id: UUID, continuation: AsyncStream<ImportStage>.Continuation)?
    private var starting = false
    private var reloadGeneration = UUID()

    func start() async {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        guard service == nil else { await reload(); return }
        do { service = try await LibraryService.openDefault(); await reload() }
        catch { message = "无法打开书架：\(ImportSafeFailure(error).summary)" }
    }

    func reload() async {
        guard let service else { return }
        reloadGeneration = UUID()
        let generation = reloadGeneration
        do { let result = try await service.store.books(); if generation == reloadGeneration { books = result } }
        catch { message = "读取书架失败：\(ImportSafeFailure(error).summary)" }
    }

    func beginFileSelection() -> UUID {
        let id = UUID()
        importDiagnostics.begin(id)
        return id
    }

    func fileSelectionClosed(attempt: UUID) {
        importDiagnostics.pickerClosed(for: attempt)
    }

    func fileSelectionResult(_ result: Result<[URL], Error>, attempt: UUID) {
        switch result {
        case .success(let urls):
            guard importDiagnostics.selected(for: attempt, hasFile: !urls.isEmpty) else { return }
            guard let url = urls.first else {
                showImportMessage("选择器返回了空结果，请重试。", id: attempt)
                return
            }
            importFile(url, id: attempt)
        case .failure(let error):
            guard importDiagnostics.pickerFailed(error, for: attempt) else { return }
            showImportMessage("选择文件未完成：\(ImportSafeFailure(error).summary)", id: attempt)
        }
    }

    private func importFile(_ url: URL, id: UUID) {
        guard let service else {
            importDiagnostics.record(.rejectedUnavailable, for: id)
            showImportMessage("书架尚未就绪，暂未接受导入。", id: id)
            return
        }
        guard !importing else {
            importDiagnostics.record(.rejectedBusy, for: id)
            showImportMessage("已有导入正在处理，暂未接受这次请求。", id: id)
            return
        }
        ticket = id; importing = true
        importDiagnostics.record(.accepted, for: id)
        importTask = Task {
            let observation = stageObservation(id: id)
            do {
                let result = try await service.prepareImport(url: url, ticket: id,
                    observe: { _ = observation.continuation.yield($0) })
                observation.continuation.finish()
                await observation.task.value
                if stageSink?.id == id { stageSink = nil }
                guard ticket == id else { _ = await service.cancelImport(id); return }
                switch result {
                case .completed(let receipt): await finish(receipt, id: id)
                case .choose(let choice):
                    encodingChoice = choice
                    importDiagnostics.record(.encodingSheetRequested, for: id)
                }
            } catch {
                observation.continuation.finish()
                await observation.task.value
                if stageSink?.id == id { stageSink = nil }
                await failed(error, id: id)
            }
        }
    }

    func choose(_ encoding: TXTEncoding, for choice: EncodingChoice) {
        guard let service, ticket == choice.id, encodingChoice?.id == choice.id else { return }
        encodingChoice = nil
        importTask = Task {
            let observation = stageObservation(id: choice.id)
            do {
                let receipt = try await service.confirmImport(ticket: choice.id, encoding: encoding,
                    observe: { _ = observation.continuation.yield($0) })
                observation.continuation.finish()
                await observation.task.value
                if stageSink?.id == choice.id { stageSink = nil }
                await finish(receipt, id: choice.id)
            } catch {
                observation.continuation.finish()
                await observation.task.value
                if stageSink?.id == choice.id { stageSink = nil }
                await failed(error, id: choice.id)
            }
        }
    }

    func cancelImport() async {
        guard let id = ticket, let service else { return }
        if let stageSink, stageSink.id == id { _ = stageSink.continuation.yield(.cancelRequested) }
        else { importDiagnostics.record(.cancelRequested, for: id) }
        importTask?.cancel()
        let result = await service.cancelImport(id)
        guard ticket == id else { return }
        switch result {
        case .alreadyCommitted(let receipt): await finish(receipt, id: id)
        case .cancelled:
            ticket = nil; importing = false; encodingChoice = nil
            importDiagnostics.record(.cancelled, for: id)
            showImportMessage("已取消，未添加新书。", id: id)
            await reload()
        }
    }

    private func finish(_ receipt: ImportReceipt, id: UUID) async {
        guard ticket == id else { return }
        ticket = nil; importing = false; encodingChoice = nil
        showImportMessage(receipt.duplicate ? "这本书已在书架，原阅读位置已保留。" : "已加入书架。", id: id)
        await reload()
    }

    private func failed(_ error: Error, id: UUID) async {
        guard ticket == id else { return }
        // Ask the commit authority before reporting cancellation; a late cancel may lose to commit.
        if let service, case .alreadyCommitted(let receipt) = await service.cancelImport(id) {
            await finish(receipt, id: id); return
        }
        ticket = nil; importing = false; encodingChoice = nil
        importDiagnostics.fail(error, for: id)
        showImportMessage("未能导入：\(ImportSafeFailure(error).summary)", id: id)
        await reload()
    }

    /// A single consumer preserves service event order; drain it before publishing a result or sheet.
    private func stageObservation(id: UUID) -> (continuation: AsyncStream<ImportStage>.Continuation, task: Task<Void, Never>) {
        let pair = AsyncStream<ImportStage>.makeStream(bufferingPolicy: .bufferingOldest(32))
        stageSink = (id, pair.continuation)
        let task = Task { [weak self] in
            for await stage in pair.stream {
                guard let self, self.ticket == id else { continue }
                self.importDiagnostics.record(stage, for: id)
            }
        }
        return (pair.continuation, task)
    }

    private func showImportMessage(_ value: String, id: UUID) {
        guard importDiagnostics.attempt == id else { return }
        importDiagnostics.record(.alertRequested, for: id)
        message = value
    }
}

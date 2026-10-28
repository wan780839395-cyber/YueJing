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
    @Published var notice: LibraryNotice?
    @Published private(set) var importPresentation = LibraryImportPresentation()
    @Published private(set) var importDiagnostics = ImportDiagnosticState()
    @Published private(set) var fileSelection: FileSelectionSession?
    @Published private(set) var processingSummary: String?
    private var selectionReceivedAt: ContinuousClock.Instant?
    private var importMeasurements: [ProcessingMeasurement] = []
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

    var canPresentLibraryFeedback: Bool { fileSelection?.dismissalConfirmed ?? true }
    var canBeginFileSelection: Bool { service != nil && !importing && canPresentLibraryFeedback }

    func beginFileSelection() {
        guard canBeginFileSelection else { return }
        let id = UUID()
        notice = nil
        selectionReceivedAt = nil; importMeasurements = []; processingSummary = nil
        importDiagnostics.begin(id)
        fileSelection = FileSelectionSession(id: id,
            selected: { [weak self] id, urls in self?.documentPickerSelected(id, urls: urls) },
            cancelled: { [weak self] id in self?.documentPickerCancelled(id) })
    }

    func documentPickerDismissed(_ id: UUID) {
        guard let session = fileSelection, session.id == id, session.confirmDismissal() else { return }
        importDiagnostics.pickerClosed(for: id)
        handlePickerResult(session)
    }

    private func documentPickerSelected(_ id: UUID, urls: [URL]) {
        guard let session = fileSelection, session.id == id, session.receiveSelection(urls) else { return }
        selectionReceivedAt = ContinuousClock().now
        importDiagnostics.record(urls.isEmpty ? .delegateEmpty : .delegateSelected, for: id)
        importDiagnostics.selected(for: id, hasFile: !urls.isEmpty)
        session.requestDismissal()
        handlePickerResult(session)
    }

    private func documentPickerCancelled(_ id: UUID) {
        guard let session = fileSelection, session.id == id, session.receiveCancellation() else { return }
        importDiagnostics.delegateCancelled(for: id)
        session.requestDismissal()
        handlePickerResult(session)
    }

    private func handlePickerResult(_ session: FileSelectionSession) {
        guard fileSelection?.id == session.id, let result = session.takeReady() else { return }
        switch result {
        case .selected(let url): importFile(url, id: session.id)
        case .empty: showImportMessage("选择器返回了空结果，请重试。", id: session.id)
        case .cancelled: notice = .selectionCancelled
        case .missingSelectedURL:
            importDiagnostics.record(.pickerHandoffMissing, for: session.id)
            showImportMessage("已收到选择回调，但待处理文件缺失，请重试。", id: session.id)
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
        importPresentation.begin(id)
        importDiagnostics.record(.accepted, for: id)
        importTask = Task {
            let observation = stageObservation(id: id)
            let timing = ProcessingTrace()
            defer { timing.end() }
            do {
                let result = try await service.prepareReadingImport(url: url, ticket: id, budget: ReaderStoragePolicy.budget(), measure: timing.observer,
                    observe: { _ = observation.continuation.yield($0) })
                observation.continuation.finish()
                await observation.task.value
                await collectTiming(timing, id: id)
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
                await collectTiming(timing, id: id)
                if stageSink?.id == id { stageSink = nil }
                await failed(error, id: id)
            }
        }
    }

    func choose(_ encoding: TXTEncoding, for choice: EncodingChoice) {
        guard let service, ticket == choice.id, encodingChoice?.id == choice.id,
              !importPresentation.stopRequested else { return }
        encodingChoice = nil
        importTask = Task {
            let observation = stageObservation(id: choice.id)
            let timing = ProcessingTrace()
            defer { timing.end() }
            do {
                let receipt = try await service.confirmReadingImport(ticket: choice.id, encoding: encoding, budget: ReaderStoragePolicy.budget(), measure: timing.observer,
                    observe: { _ = observation.continuation.yield($0) })
                observation.continuation.finish()
                await observation.task.value
                await collectTiming(timing, id: choice.id)
                if stageSink?.id == choice.id { stageSink = nil }
                await finish(receipt, id: choice.id)
            } catch {
                observation.continuation.finish()
                await observation.task.value
                await collectTiming(timing, id: choice.id)
                if stageSink?.id == choice.id { stageSink = nil }
                await failed(error, id: choice.id)
            }
        }
    }

    func cancelImport() async {
        guard let id = ticket, let service else { return }
        guard importPresentation.requestStop(for: id) else { return }
        if let stageSink, stageSink.id == id { _ = stageSink.continuation.yield(.cancelRequested) }
        else { importDiagnostics.record(.cancelRequested, for: id) }
        importTask?.cancel()
        let result = await service.cancelImport(id)
        guard ticket == id else { return }
        switch result {
        case .alreadyCommitted(let receipt): await finish(receipt, id: id)
        case .cancelled:
            ticket = nil; importing = false; encodingChoice = nil
            importPresentation.finish(id)
            importDiagnostics.record(.cancelled, for: id)
            notice = .cancelledBeforeCommit
            await reload()
        }
    }

    private func finish(_ receipt: ImportReceipt, id: UUID) async {
        guard ticket == id else { return }
        let stopped = importPresentation.stopRequested
        let deferred = importMeasurements.contains { $0.phase == .derivedDeferred }
        importPresentation.finish(id)
        ticket = nil; importing = false; encodingChoice = nil
        notice = .committed(duplicate: receipt.duplicate, stopRequested: stopped, preparationDeferred: deferred)
        await reload()
        if importDiagnostics.attempt == id, let start = selectionReceivedAt {
            let elapsed = start.duration(to: ContinuousClock().now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            processingSummary = String(format: "选中回调→入架 %.3fs（含等待）\n", seconds)
                + ProcessingMeasurement.summary(importMeasurements)
                + "\n系统选择/下载阶段未测；仅本地摘要。"
        }
    }

    func releaseProcessingCache() async { await service?.releaseProcessingCache() }

    private func collectTiming(_ trace: ProcessingTrace, id: UUID) async {
        let values = await trace.finish()
        guard ticket == id else { return }
        importMeasurements.append(contentsOf: values)
        processingSummary = ProcessingMeasurement.summary(importMeasurements)
    }

    private func failed(_ error: Error, id: UUID) async {
        guard ticket == id else { return }
        // Ask the commit authority before reporting cancellation; a late cancel may lose to commit.
        if let service, case .alreadyCommitted(let receipt) = await service.cancelImport(id) {
            await finish(receipt, id: id); return
        }
        ticket = nil; importing = false; encodingChoice = nil
        importPresentation.finish(id)
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
                self.importPresentation.receive(stage, for: id)
            }
        }
        return (pair.continuation, task)
    }

    private func showImportMessage(_ value: String, id: UUID) {
        guard importDiagnostics.attempt == id else { return }
        importDiagnostics.record(.alertRequested, for: id)
        notice = nil
        message = value
    }
}

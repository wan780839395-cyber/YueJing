import Combine
import Foundation
import ReaderDomain
import TXTCore

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var title = "正在打开"
    @Published private(set) var chapterTotal = 0
    @Published private(set) var window: ReadingWindow?
    @Published var preferences = ReaderPreferences()
    @Published private(set) var loading = true
    @Published private(set) var exitSaveFailed = false
    @Published var message: String?
    @Published private(set) var openingPerformanceSummary: String?
    let viewport = ReaderViewportHandle()
    let directory = ReaderDirectoryViewModel()
    private let bookID: String
    private let service: LibraryService
    private var reader: OpenedReader?
    private var anchor: ReadingAnchor?
    private var userPosition = false
    private var sequence: Int64 = 0
    private var preferencesSequence: Int64 = 0
    private var width = 0.0
    private var generation = UUID()
    private var lifecycle = UUID()
    private var positionRevision: UInt64 = 0
    private var layoutNeedsRefresh = false
    private var closing = false
    private var suspended = false
    private var automaticRecoveryUsed = false
    private var navigationGate = ReadingNavigationGate()
    private var openTask: Task<OpenedReader, Error>?
    private var layoutTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var openingStarted: ContinuousClock.Instant?
    private var openingMeasurements: [ProcessingMeasurement] = []

    init(bookID: String, service: LibraryService) { self.bookID = bookID; self.service = service }

    func load() async {
        guard reader == nil, openTask == nil, !closing, !suspended else { return }
        lifecycle = UUID(); let request = lifecycle
        loading = true; openingStarted = ContinuousClock().now
        openingMeasurements = []; openingPerformanceSummary = nil
        let timing = ProcessingTrace(); defer { timing.end() }
        do {
            let budget = try ReaderStoragePolicy.budget(), service = service, id = bookID
            let task = Task { try await service.openReader(id: id, budget: budget, measure: timing.observer) }
            openTask = task
            let opened = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard lifecycle == request, !closing, !suspended, !Task.isCancelled else {
                try? await opened.close(); return
            }
            let measurements = await timing.finish()
            guard lifecycle == request, !closing, !suspended, !Task.isCancelled else {
                try? await opened.close(); return
            }
            openTask = nil; reader = opened; title = opened.book.title
            navigationGate.reset()
            preferences = opened.preferences
            automaticRecoveryUsed = automaticRecoveryUsed || opened.cacheDisposition == .rebuilt
            anchor = opened.reading.anchor ?? ReadingAnchor(bookID: bookID, versionID: opened.source.metadata.versionID,
                                                             rawByteOffset: opened.source.metadata.bomByteCount)
            userPosition = false; sequence = 0; preferencesSequence = 0
            chapterTotal = opened.source.metadata.chapterCount; directory.attach(opened)
            openingMeasurements = measurements
            if opened.reading.ignoredIncompatibleProgress {
                message = "旧位置与当前文字不匹配，已从开头显示；未覆盖旧记录。"
            }
            requestWindow()
        } catch {
            guard lifecycle == request else { return }
            openTask = nil; loading = false
            if !(error is CancellationError) { message = ReaderStoragePolicy.failureMessage(error) }
        }
    }

    func resized(_ fullWidth: Double) {
        let usable = fullWidth - 40
        guard usable >= 80, abs(usable - width) > 0.5 else { return }
        width = usable; requestWindow()
    }
    func retry() async {
        guard !closing, !exitSaveFailed else { return }
        if reader == nil { await load() } else { await restartReader() }
    }
    func visibleChanged(_ value: ReadingAnchor, windowID: UUID) {
        guard !closing, !suspended, !exitSaveFailed, let reader,
              navigationGate.accepts(window: windowID),
              value.bookID == reader.reading.session.bookID, value.versionID == reader.reading.session.versionID else { return }
        anchor = value; userPosition = true; sequence += 1; positionRevision &+= 1
        let serial = sequence, request = lifecycle
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(700)); try Task.checkCancellation()
                _ = try await reader.saveProgress(value, sequence: serial)
            } catch is CancellationError { }
            catch { if lifecycle == request, !closing { message = "位置暂未保存，原记录已保留。" } }
        }
    }
    func extendWindow(_ visible: ReadingAnchor, windowID: UUID) {
        guard !closing, !suspended, !exitSaveFailed, navigationGate.accepts(window: windowID) else { return }
        anchor = visible; requestWindow()
    }
    func scrollingEnded(_ visible: ReadingAnchor, windowID: UUID) -> Bool {
        if navigationGate.navigation != nil, navigationGate.isDisplayed(window: windowID),
           !closing, !suspended, !exitSaveFailed {
            if layoutNeedsRefresh, !viewport.interacting { requestWindow() }
            return true // Reschedule the jump, never adopt the old scroll position.
        }
        guard !closing, !suspended, layoutNeedsRefresh, !exitSaveFailed, navigationGate.accepts(window: windowID) else { return false }
        anchor = visible; requestWindow(); return true
    }
    func go(to chapter: TXTChapter) {
        guard let reader, !closing, !suspended, !exitSaveFailed,
              chapter.documentVersion == reader.reading.session.versionID else { return }
        positionRevision &+= 1
        navigationGate.begin()
        anchor = ReadingAnchor(bookID: bookID, versionID: chapter.documentVersion, rawByteOffset: chapter.rawByteRange.location.value)
        requestWindow()
    }
    func directoryAnchor() -> ReadingAnchor? {
        guard let reader, !closing, !suspended, !exitSaveFailed,
              let id = viewport.controller?.window?.id, navigationGate.isDisplayed(window: id),
              let value = viewport.anchor(), value.bookID == reader.reading.session.bookID,
              value.versionID == reader.reading.session.versionID else { return nil }
        return value
    }
    func settingsChanged() {
        guard let reader, !closing, !suspended, !exitSaveFailed else { return }
        requestWindow(); settingsTask?.cancel(); preferencesSequence += 1
        let value = preferences.validated, serial = preferencesSequence, request = lifecycle
        settingsTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation()
                _ = try await reader.savePreferences(value, sequence: serial)
            } catch is CancellationError { }
            catch { if lifecycle == request, !closing { message = "阅读设置暂未保存。" } }
        }
    }
    func flush() async {
        guard !closing, let reader else { return }
        let request = lifecycle
        let reliable = userPosition ? viewport.anchor() : nil
        if let reliable, navigationGate.navigation == nil { anchor = reliable }
        saveTask?.cancel(); settingsTask?.cancel()
        sequence += 1; preferencesSequence += 1
        let serial = sequence, settingsSerial = preferencesSequence, settings = preferences.validated
        do {
            if let reliable { _ = try await reader.saveProgress(reliable, sequence: serial) }
            guard lifecycle == request, !closing else { return }
            _ = try await reader.savePreferences(settings, sequence: settingsSerial)
        } catch { if lifecycle == request, !closing { message = "保存未完成，已保存记录仍保留。" } }
    }
    func suspend() async {
        guard !closing else { return }
        suspended = true; lifecycle = UUID(); generation = UUID()
        let request = lifecycle, owner = reader
        openTask?.cancel(); openTask = nil
        layoutTask?.cancel(); directory.cancel()
        await flush()
        guard lifecycle == request, suspended, !closing else { return }
        await owner?.releasePageCache()
    }
    func resume() async {
        guard !closing else { return }
        suspended = false
        if reader == nil { await load() } else { requestWindow() }
    }
    func releaseReaderMemory() async {
        let request = lifecycle, owner = reader
        await service.releaseProcessingCache()
        guard lifecycle == request else { return }
        await owner?.releasePageCache()
    }
    func close() async -> Bool {
        guard !closing else { return false }
        closing = true; lifecycle = UUID(); generation = UUID()
        openTask?.cancel(); openTask = nil; layoutTask?.cancel(); directory.dismiss()
        saveTask?.cancel(); settingsTask?.cancel()
        let reliable = userPosition ? viewport.anchor() : nil
        if let reliable { anchor = reliable }
        sequence += 1; preferencesSequence += 1
        let old = reader
        do {
            if let old { try await old.close(anchor: reliable, sequence: sequence,
                                              preferences: preferences.validated, preferencesSequence: preferencesSequence) }
            reader = nil; window = nil; chapterTotal = 0; directory.detach()
            return true
        } catch {
            closing = false; exitSaveFailed = true
            message = "最后保存失败。可重试，或保留已保存的位置返回书架。"
            return false
        }
    }
    func leaveKeepingSavedPosition() async {
        closing = true; lifecycle = UUID(); generation = UUID()
        openTask?.cancel(); openTask = nil; layoutTask?.cancel(); directory.dismiss()
        saveTask?.cancel(); settingsTask?.cancel()
        if let reader { try? await reader.close(sequence: sequence + 1) }
        reader = nil; window = nil; chapterTotal = 0; directory.detach()
    }
    private func restartReader() async {
        guard !closing, !suspended, !exitSaveFailed else { return }
        lifecycle = UUID(); generation = UUID()
        let request = lifecycle, old = reader
        openTask?.cancel(); openTask = nil; directory.dismiss()
        layoutTask = nil; saveTask?.cancel(); settingsTask?.cancel()
        let reliable = userPosition ? viewport.anchor() : nil
        sequence += 1; preferencesSequence += 1; loading = true
        do {
            if let old { try await old.close(anchor: reliable, sequence: sequence,
                                              preferences: preferences.validated, preferencesSequence: preferencesSequence) }
            guard lifecycle == request, !closing, !suspended else { return }
            reader = nil; window = nil; chapterTotal = 0; directory.detach(); userPosition = false
            await load()
        } catch {
            guard lifecycle == request else { return }
            loading = false; exitSaveFailed = true; message = "恢复前保存失败，未建立新会话或覆盖原位置。"
        }
    }
    private func readFailed(_ error: Error, owner: OpenedReader) async {
        guard reader === owner, !closing, !suspended, !exitSaveFailed else { return }
        if let failure = error as? DerivedStorageError,
           [.corruptArtifact, .missingArtifact, .closed].contains(failure), !automaticRecoveryUsed {
            automaticRecoveryUsed = true
            await restartReader()
        } else { message = ReaderStoragePolicy.failureMessage(error); loading = false }
    }
    private func requestWindow() {
        guard let reader, let anchor, !closing, !suspended, !exitSaveFailed, width >= 80 else { return }
        layoutTask?.cancel(); generation = UUID(); layoutNeedsRefresh = true
        let request = generation, life = lifecycle, settings = preferences, currentWidth = width, revision = positionRevision
        let navigation = navigationGate.navigation
        let timing = openingStarted == nil ? nil : ProcessingTrace()
        layoutTask = Task {
            defer { timing?.end() }
            do {
                let rendered = try await reader.window(around: anchor, width: currentWidth, preferences: settings, measure: timing?.observer)
                let measurements = await timing?.finish() ?? []
                try Task.checkCancellation()
                guard request == generation, life == lifecycle, !closing, !suspended, self.reader === reader else { return }
                guard revision == positionRevision, !viewport.interacting else {
                    if !viewport.interacting { requestWindow() }; return
                }
                layoutNeedsRefresh = false; openingMeasurements.append(contentsOf: measurements)
                let isNavigation = navigation != nil && navigationGate.navigation == navigation
                if isNavigation, let navigation { navigationGate.expect(window: rendered.id, navigation: navigation) }
                viewport.onNextRestoreIsNavigation = isNavigation; window = rendered; loading = false
            } catch is CancellationError { }
            catch {
                guard request == generation, life == lifecycle, !closing else { return }
                layoutNeedsRefresh = false; await readFailed(error, owner: reader)
            }
        }
    }
    /// UIKit application completion is not a displayed-pixels/first-paint timestamp.
    func windowApplied(_ id: UUID) {
        guard !closing, !suspended, window?.id == id else { return }
        let navigationApplied = navigationGate.applied(window: id)
        if let visible = directoryAnchor() {
            if navigationApplied { visibleChanged(visible, windowID: id) }
            directory.displayed(visible)
        }
        guard navigationGate.navigation == nil else { return }
        guard let started = openingStarted else { return }
        openingStarted = nil
        let elapsed = started.duration(to: ContinuousClock().now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let summary = String(format: "打开请求→窗口已应用 %.3fs\n", seconds)
            + ProcessingMeasurement.summary(openingMeasurements) + "\n进程重启/正文首绘未测；仅本地摘要。"
        let request = lifecycle
        Task { if lifecycle == request, !closing { openingPerformanceSummary = summary } }
    }
}

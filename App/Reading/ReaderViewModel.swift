import Combine
import Foundation
import ReaderDomain
import TXTCore

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var title = "正在打开"
    @Published private(set) var chapters: [TXTChapter] = []
    @Published private(set) var window: ReadingWindow?
    @Published var preferences = ReaderPreferences()
    @Published private(set) var loading = true
    @Published private(set) var exitSaveFailed = false
    @Published var message: String?
    @Published private(set) var openingPerformanceSummary: String?
    private var openingStarted: ContinuousClock.Instant?
    private var openingMeasurements: [ProcessingMeasurement] = []
    let viewport = ReaderViewportHandle()
    private let bookID: String
    private let service: LibraryService
    private var engine: ReadingLayoutEngine?
    private var session: ReadingSession?
    private var anchor: ReadingAnchor?
    private var userPosition = false
    private var sequence: Int64 = 0
    private var width = 0.0
    private var generation = UUID()
    private var positionRevision: UInt64 = 0
    private var layoutNeedsRefresh = false
    private var lifecycle = UUID()
    private var closing = false
    private var preferencesLoaded = false
    private var layoutTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?

    init(bookID: String, service: LibraryService) { self.bookID = bookID; self.service = service }

    func load() async {
        guard engine == nil, !closing else { return }
        lifecycle = UUID(); loading = true
        let request = lifecycle
        openingStarted = ContinuousClock().now; openingMeasurements = []; openingPerformanceSummary = nil
        let timing = ProcessingTrace()
        defer { timing.end() }
        do {
            let opened = try await service.openBook(id: bookID, measure: timing.observer)
            let measurements = await timing.finish()
            guard lifecycle == request, !closing, !Task.isCancelled else {
                try? await service.store.finishReading(session: opened.reading.session, anchor: nil, sequence: 1)
                return
            }
            title = opened.book.title; chapters = opened.chapters; session = opened.reading.session
            openingMeasurements = measurements
            anchor = opened.reading.anchor ?? ReadingAnchor(bookID: bookID, versionID: opened.document.versionID,
                                                            rawByteOffset: opened.document.bomByteCount)
            engine = ReadingLayoutEngine(bookID: bookID, document: opened.document)
            preferences = try await service.store.preferences()
            preferencesLoaded = true
            if opened.reading.ignoredIncompatibleProgress { message = "旧位置与当前文字不匹配，已从开头显示；未覆盖旧记录。" }
            requestWindow()
        } catch {
            if !(error is CancellationError), lifecycle == request { message = error.localizedDescription; loading = false }
        }
    }

    func resized(_ fullWidth: Double) {
        let usable = fullWidth - 40
        guard usable >= 80, abs(usable - width) > 0.5 else { return }
        width = usable; requestWindow()
    }

    func retry() async {
        guard !closing else { return }
        guard engine != nil else { await load(); return }
        do {
            if !preferencesLoaded { preferences = try await service.store.preferences(); preferencesLoaded = true }
            loading = true
            requestWindow()
        } catch { loading = false; message = error.localizedDescription }
    }

    func visibleChanged(_ value: ReadingAnchor) {
        guard !closing, let session, value.bookID == session.bookID, value.versionID == session.versionID else { return }
        anchor = value; userPosition = true; sequence += 1; positionRevision &+= 1
        let serial = sequence
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(700))
                try Task.checkCancellation()
                _ = try await service.store.saveProgress(session: session, anchor: value, sequence: serial)
            } catch is CancellationError { }
            catch { message = "位置暂未保存：\(error.localizedDescription)" }
        }
    }

    func extendWindow(_ visible: ReadingAnchor) {
        guard !closing else { return }
        anchor = visible; requestWindow()
    }

    func scrollingEnded(_ visible: ReadingAnchor) -> Bool {
        guard !closing, layoutNeedsRefresh else { return false }
        anchor = visible; requestWindow()
        return true
    }

    func go(to chapter: TXTChapter) {
        guard let session, !closing else { return }
        positionRevision &+= 1
        anchor = ReadingAnchor(bookID: bookID, versionID: session.versionID, rawByteOffset: chapter.rawByteRange.location.value)
        requestWindow(userNavigation: true)
    }

    func settingsChanged() {
        guard !closing else { return }
        requestWindow()
        settingsTask?.cancel()
        let value = preferences.validated
        settingsTask = Task {
            do { try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation(); try await service.store.savePreferences(value) }
            catch is CancellationError { }
            catch { message = "阅读设置暂未保存：\(error.localizedDescription)" }
        }
    }

    func flush() async {
        guard !closing, let session else { return }
        if userPosition, let visible = viewport.anchor() { anchor = visible }
        saveTask?.cancel(); settingsTask?.cancel()
        do {
            if userPosition, let anchor { sequence += 1; _ = try await service.store.saveProgress(session: session, anchor: anchor, sequence: sequence) }
            if preferencesLoaded { try await service.store.savePreferences(preferences) }
        } catch { message = "保存未完成：\(error.localizedDescription)" }
    }

    func close() async -> Bool {
        guard !closing else { return false }
        closing = true; lifecycle = UUID(); generation = UUID()
        layoutTask?.cancel(); saveTask?.cancel(); settingsTask?.cancel()
        if userPosition, let visible = viewport.anchor() { anchor = visible }
        do {
            if preferencesLoaded { try await service.store.savePreferences(preferences) }
            if let session {
                sequence += 1
                try await service.store.finishReading(session: session, anchor: userPosition ? anchor : nil, sequence: sequence)
            }
            session = nil; engine = nil; window = nil
            return true
        } catch {
            closing = false; exitSaveFailed = true
            message = "最后保存失败。可重试，或保留已保存的位置返回书架。\(error.localizedDescription)"
            return false
        }
    }

    func leaveKeepingSavedPosition() async {
        closing = true; lifecycle = UUID(); generation = UUID()
        layoutTask?.cancel(); saveTask?.cancel(); settingsTask?.cancel()
        if let session { try? await service.store.finishReading(session: session, anchor: nil, sequence: sequence + 1) }
        session = nil; engine = nil; window = nil
    }

    func disappeared() {
        Task { _ = await close() }
    }

    private func requestWindow(userNavigation: Bool = false) {
        guard !closing, let engine, let anchor, width >= 80 else { return }
        layoutTask?.cancel(); generation = UUID()
        layoutNeedsRefresh = true
        let request = generation, settings = preferences, currentWidth = width, revision = positionRevision
        let timing = openingStarted == nil ? nil : ProcessingTrace()
        layoutTask = Task {
            defer { timing?.end() }
            do {
                let rendered = try await engine.window(around: anchor, width: currentWidth, preferences: settings,
                                                       measure: timing?.observer)
                let measurements = await timing?.finish() ?? []
                try Task.checkCancellation()
                guard request == generation, !closing else { return }
                guard revision == positionRevision, !viewport.interacting else {
                    // The old window may still receive real scrolling while background layout runs.
                    // Keep the newest visible anchor, and only re-request once interaction has settled.
                    if !viewport.interacting { requestWindow() }
                    return
                }
                layoutNeedsRefresh = false
                openingMeasurements.append(contentsOf: measurements)
                viewport.onNextRestoreIsNavigation = userNavigation
                window = rendered; loading = false
            } catch is CancellationError { }
            catch { if request == generation { layoutNeedsRefresh = false; loading = false; message = error.localizedDescription } }
        }
    }

    /// Called after UIKit applies a window. Actual display/first paint is deliberately unmeasured.
    func windowApplied(_ id: UUID) {
        guard !closing, window?.id == id, let started = openingStarted else { return }
        openingStarted = nil
        let elapsed = started.duration(to: ContinuousClock().now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let summary = String(format: "打开→窗口已应用 %.3fs\n", seconds)
            + ProcessingMeasurement.summary(openingMeasurements) + "\n正文首绘未测；仅本地摘要。"
        let request = lifecycle
        // Avoid publishing during a SwiftUI representable update.
        Task { if lifecycle == request, !closing { openingPerformanceSummary = summary } }
    }
}

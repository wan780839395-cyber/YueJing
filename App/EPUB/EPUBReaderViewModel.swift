import Combine
import Foundation
import ReaderDomain
import UIKit

@MainActor
final class EPUBReaderViewModel: ObservableObject {
    @Published private(set) var title = "正在打开"
    @Published private(set) var navigationItems: [EPUBNavigationItem] = []
    @Published private(set) var spine: [String] = []
    @Published private(set) var currentPath: String?
    @Published private(set) var currentFragment: String?
    @Published private(set) var currentPosition: EPUBReadingPosition?
    @Published private(set) var navigationRequest: EPUBNavigationRequest?
    @Published var preferences = ReaderPreferences()
    @Published private(set) var readingMode: EPUBReadingMode
    @Published private(set) var layoutMode: EPUBLayoutMode
    @Published private(set) var userFontID: String?
    @Published private var userFontUnavailable = false
    private var fontRemovalObservation: AnyCancellable?
    @Published private(set) var styleCompatibility: EPUBStyleCompatibility?
    // Runtime state belongs to the accepted visible token, never to the whole book.
    @Published private(set) var runtimeFontFallback = false
    @Published private(set) var runtimeFontFallbackToken: EPUBNavigationToken?
    @Published private(set) var sessionFontFallbackObserved = false
    @Published private var compatibilityNoticeDismissed = false

    var effectiveLayoutMode: EPUBLayoutMode { layoutMode.effective(for: styleCompatibility) }
    var compatibilitySummary: String? {
        if userFontUnavailable { return "本书选择的字体暂不可用，已按原排版显示。可在字体设置中重新选择。" }
        return Self.warningSummary(layoutMode: layoutMode, compatibility: styleCompatibility,
                            runtimeFontFallback: runtimeFontFallback && runtimeFontFallbackToken == currentToken)
    }

    /// Import-time, book-wide facts and this opening's history, not a current-chapter verdict.
    /// Runtime history is intentionally not persisted or inherited by a new reader session.
    var bookCompatibilityDetails: String? {
        let labels: [EPUBStyleIssue: String] = [
            .optionalResourceMissing: "部分可选资源缺失", .fontUnavailable: "部分作者字体不可用",
            .styleComplexity: "部分作者样式超出安全复杂度", .localImportCycle: "样式存在循环引用",
            .unsupportedStyleCondition: "部分样式条件不受支持", .navigationUnavailable: "部分链接或目录不可用",
            .malformedOptionalStyle: "部分可选样式无效", .invalidOptionalFont: "部分可选字体无效",
            .obfuscatedFontOmitted: "部分混淆字体已省略", .manifestImageRecovered: "部分图片已兼容恢复"
        ]
        var details: [String] = []
        if let compatibility = styleCompatibility {
            if !compatibility.issues.isEmpty {
                details.append("本书导入时的兼容记录（不代表当前章）：" +
                    compatibility.issues.map { labels[$0] ?? $0.rawValue }.joined(separator: "；") + "。")
            }
            if compatibility.usesReaderLayout {
                details.append("本书作者排版需兼容处理；选择原始排版时会自动使用阅读器排版，偏好不变。")
            }
        }
        if sessionFontFallbackObserved {
            details.append("本次打开曾检测到作者字体回退；不代表当前章仍在回退，重新打开会重新检测。")
        }
        return details.isEmpty ? nil : details.joined(separator: "\n")
    }

    static func warningSummary(layoutMode: EPUBLayoutMode, compatibility: EPUBStyleCompatibility?,
                               runtimeFontFallback: Bool) -> String? {
        // An explicit reader choice is not a compatibility failure, even with book-level issues.
        guard layoutMode == .original else { return nil }
        if compatibility?.usesReaderLayout == true {
            return "本书作者排版不可用，已自动使用阅读器兼容排版；你的原始排版偏好保留。"
        }
        if runtimeFontFallback {
            return "当前章节部分作者字体不可用，已使用替代字体；其余安全样式保留。"
        }
        return nil
    }

    private func resetCurrentRuntimeWarning() {
        userFontUnavailable = false
        runtimeFontFallback = false
        runtimeFontFallbackToken = nil
        compatibilityNoticeDismissed = false
    }

    private func recordRuntimeFontFallback(_ fallback: Bool, token: EPUBNavigationToken) {
        guard !closing, !suspended, !exitSaveFailed, currentToken == token,
              navigationRequest?.token == token, navigationRequest?.layoutMode == effectiveLayoutMode else { return }
        let currentFallback = effectiveLayoutMode == .original && fallback
        if currentFallback && !runtimeFontFallback { compatibilityNoticeDismissed = false }
        runtimeFontFallbackToken = token
        runtimeFontFallback = currentFallback
        if currentFallback { sessionFontFallbackObserved = true }
    }
    var compatibilityNotice: String? { compatibilityNoticeDismissed ? nil : compatibilitySummary }
    func dismissCompatibilityNotice() { compatibilityNoticeDismissed = true }
    @Published private(set) var loading = true
    @Published private(set) var ready = false {
        didSet { if ready { refreshRemovedFontIfNeeded() } }
    }
    @Published private(set) var promotingVisibleChapter = false
    // Native motion is not a save/navigation permission. Keep the same touch
    // target while a resident chapter receives its new authority asynchronously.
    var acceptsCanvasTouch: Bool {
        !loading && !closing && !suspended && !exitSaveFailed && (ready || promotingVisibleChapter)
    }
    @Published private(set) var exitSaveFailed = false
    @Published var message: String?
    @Published private(set) var openingPerformanceSummary: String?
    @Published private(set) var openingPresentationSummary: String?
    @Published private(set) var loadingStage = "正在校验并准备书籍…"

    let webView: EPUBWebViewHandle
    let autoRead: AutoReadSession
    let speech: ReaderSpeechSession
    private let rendererCache: EPUBWarmRendererCache?
    private let rendererGeneration: UUID
    private let bookID: String
    private let service: LibraryService
    private(set) var reader: OpenedEPUBReader?
    private(set) var currentToken: EPUBNavigationToken? {
        didSet {
            if oldValue != currentToken { resetCurrentRuntimeWarning() }
        }
    }
    private var sequence: Int64 = 0
    private var preferencesSequence: Int64 = 0
    private typealias SearchCompletion = SearchReturn<EPUBReadingPosition>.Effect
    @Published private var searchReturn = SearchReturn<EPUBReadingPosition>()
    private var lifecycle = UUID() {
        didSet { searchReturn = .init() }
    }
    private var generation = UUID() {
        didSet { searchReturn.cancelPending() }
    }
    // A playback belongs to the route/reader, not to a WK epoch (resume mints a new one).
    private var speechID: UUID?
    private var onSpeechRevoked: (@MainActor () -> Void)?
    private var pendingSpeechLocation: EPUBReadingPosition?
    private var resumeAfterSettling = false
    @Published private(set) var suspending = false
    @Published private(set) var closing = false
    @Published private(set) var suspended = false
    @Published private(set) var sceneReadyRevision: UInt64 = 0
    private var shouldPersistOnReady = false
    private var hasUserPosition = false
    private var openTask: Task<OpenedEPUBReader, Error>?
    private var navigationTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var closeTask: Task<Bool, Never>?
    private var promotionTask: Task<Void, Never>?
    private var openingStarted: ContinuousClock.Instant?
    private var openingResourcesReady: ContinuousClock.Instant?
    private var openingObservation: EPUBOpeningObservation
    private var openingAttempted = false
    private(set) var openingAttemptCount = 0
    var loadingFeedbackStart: ContinuousClock.Instant? { openingStarted }

    var presentationToken: EPUBNavigationToken? {
        ready && !loading && !closing && !suspended && !exitSaveFailed ? currentToken : nil
    }

    // Explicit destinations and reflows mint a new origin. Only an observed
    // promotion in the resident DOM keeps it across the chapter's epoch change.
    @Published private(set) var documentOrigin: EPUBNavigationToken?
    var autoReadOwner: EPUBNavigationToken? {
        guard acceptsSearch, !loading, message == nil, ready || promotingVisibleChapter,
              let documentOrigin, reader?.reading.session.id == documentOrigin.sessionID else { return nil }
        return documentOrigin
    }

    private(set) var speechRestoreID: UUID?
#if DEBUG
    private(set) var debugSpeechCaptureOutcome = "none"
    private(set) var debugFirstBackgroundFailure: String?

    var debugMessageCode: String {
        guard let message else { return "none" }
        switch message {
        case "保存未完成，已保存记录仍保留。": return "flush_save_failed"
        case "阅读设置暂未保存。": return "settings_save_failed"
        case "位置暂未保存，原记录已保留。": return "scroll_save_failed"
        case "最后保存失败，未覆盖已保存记录。请返回书架后重新打开。": return "close_save_failed"
        case "章节内容校验或定位未通过，原阅读位置已保留。": return "locator_error"
        case "章节定位坐标无效，未写入进度。": return "invalid_position"
        case "相邻章节预载未完成，当前正文与已保存位置保留。可通过目录重试该章。": return "preload_failed"
        case "章节加载未能及时完成，可重试打开；原书与已保存位置保留。": return "load_timed_out"
        case "尚未取得当前阅读位置，本次未更换字体。": return "font_target_missing"
        case "旧位置与当前章节版本不匹配，已从开头显示；未覆盖旧记录。": return "incompatible_progress"
        case "这本书没有可显示的章节内容。": return "empty_spine"
        case "跨章位置交接未完成，已保存记录保留。请重试打开。": return "chapter_handoff_failed"
        default: return "other"
        }
    }

    var debugSpeechNoticeCode: String {
        guard let notice = speech.notice else { return "none" }
        switch notice {
        case "声音暂不可用，请检查音频输出后继续。": return "audio_unavailable"
        case "未能读取下一段正文。": return "next_passage_failed"
        case "当前位置没有可朗读的正文。": return "no_speakable_text"
        default: return "other"
        }
    }

    private func recordDebugBackgroundFailure(_ source: String, error: Error) {
        guard debugFirstBackgroundFailure == nil else { return }
        let category: String
        if error is CancellationError {
            category = "cancellation"
        } else if let epubError = error as? EPUBError {
            switch epubError {
            case .invalidArchive: category = "epub_invalid_archive"
            case .unsafePath: category = "epub_unsafe_path"
            case .limitExceeded: category = "epub_limit_exceeded"
            case .invalidPackage: category = "epub_invalid_package"
            case .unsupportedContent: category = "epub_unsupported_content"
            case .corruptResource: category = "epub_corrupt_resource"
            case .invalidPosition: category = "epub_invalid_position"
            case .staleSession: category = "epub_stale_session"
            }
        } else if error is LibraryError {
            category = "library_error"
        } else if let urlError = error as? URLError {
            category = "url_\(urlError.code.rawValue)"
        } else {
            category = "other_error"
        }
        debugFirstBackgroundFailure = "\(source):\(category)"
    }
#endif

    func revokeSpeech() {
        speechRestoreID = nil
        let stop = onSpeechRevoked
        speechID = nil
        pendingSpeechLocation = nil
        onSpeechRevoked = nil
        stop?()
    }

    func noteViewportReadiness() {
        sceneReadyRevision &+= 1
    }

    func startSpeech() {
        guard let source = speechSource(onRevoke: { [weak self] in
            self?.speech.stop(restorePosition: false)
        }) else { return }
        speech.start(next: source)
    }

    func startAutoRead() -> Bool {
        guard !suspending, !suspended, !closing, closeTask == nil, !exitSaveFailed,
              let owner = autoReadOwner, let token = presentationToken,
              webView.controller?.beginAutoRead(for: token) == true else { return false }
        revokeSpeech()
        autoRead.start(mode: readingMode == .scroll ? .scroll : .paged) { [weak self] distance in
            self?.autoReadStep(from: owner, distance: distance) ?? .stop
        }
        return true
    }

    func stopAutoRead() {
        webView.controller?.cancelAutoPage()
        autoRead.stop()
    }

    func speechSource(onRevoke: @escaping @MainActor () -> Void) -> ReaderSpeechSession.Source? {
        guard acceptsSearch, message == nil, let token = presentationToken, let reader,
              reader.reading.session.id == token.sessionID else {
            #if DEBUG
            debugSpeechCaptureOutcome = "source_rejected"
            #endif
            return nil
        }
        revokeSpeech()
        let owner = UUID()
        speechID = owner
        onSpeechRevoked = onRevoke
        var cursor: EPUBSpeechCursor?
        return { [weak self] in
            guard let self, self.speechID == owner, self.reader === reader else {
                #if DEBUG
                self?.debugSpeechCaptureOutcome = "revoked_before_capture"
                #endif
                throw CancellationError()
            }
            if cursor == nil {
                guard self.presentationToken == token, let controller = self.webView.controller else {
                    #if DEBUG
                    self.debugSpeechCaptureOutcome = "sample_invalid_token"
                    #endif
                    throw EPUBError.invalidPosition
                }
                guard let sample = await controller.sampleSpeechStart(for: token) else {
                    #if DEBUG
                    self.debugSpeechCaptureOutcome = "sample_nil"
                    #endif
                    throw EPUBError.invalidPosition
                }
                guard self.speechID == owner, self.acceptsSearch, self.presentationToken == token,
                      self.webView.controller === controller else {
                    #if DEBUG
                    self.debugSpeechCaptureOutcome = "sample_invalid_token"
                    #endif
                    throw EPUBError.invalidPosition
                }
                guard sample.path == token.path else {
                    #if DEBUG
                    self.debugSpeechCaptureOutcome = "sample_wrong_path"
                    #endif
                    throw EPUBError.invalidPosition
                }
                do {
                    cursor = try EPUBSpeechCursor(package: reader.publication.package, path: sample.path,
                                                  node: sample.node, rawOffset: sample.utf16Offset)
                } catch {
                    #if DEBUG
                    self.debugSpeechCaptureOutcome = "cursor_init_failed"
                    #endif
                    throw error
                }
            }
            let passage: EPUBSpeechCursor.Passage?
            do {
                passage = try await cursor?.next()
            } catch {
                #if DEBUG
                if !(error is CancellationError) {
                    self.debugSpeechCaptureOutcome = "cursor_failed"
                }
                #endif
                throw error
            }
            try Task.checkCancellation()
            guard self.speechID == owner, self.reader === reader else {
                #if DEBUG
                self.debugSpeechCaptureOutcome = "revoked_after_cursor"
                #endif
                throw CancellationError()
            }
            guard let passage else {
                #if DEBUG
                self.debugSpeechCaptureOutcome = "cursor_empty"
                #endif
                return nil
            }
            #if DEBUG
            self.debugSpeechCaptureOutcome = "captured"
            #endif
            return ReaderSpeechChunk(text: passage.text) { [weak self] in
                guard let self, self.speechID == owner, self.reader === reader,
                      !self.closing, self.closeTask == nil, !self.exitSaveFailed else { return }
                // Single-use. Navigation must not re-enter stop() during its own locate callback.
                self.onSpeechRevoked = nil
                self.speechID = nil
                if self.suspending || self.suspended {
                    self.pendingSpeechLocation = passage.position
                } else {
                    self.navigateExplicitly(path: passage.position.path, fragment: nil, target: passage.position)
                    self.speechRestoreID = owner
                }
            }
        }
    }

    func autoReadStep(from owner: EPUBNavigationToken, distance: CGFloat) -> AutoReadStep {
        guard autoReadOwner == owner, let controller = webView.controller else { return .stop }
        guard !promotingVisibleChapter, let token = presentationToken else { return .waiting }
        return controller.autoReadStep(for: token, distance: distance)
    }
    private var acceptsSearch: Bool {
        !suspending && !suspended && !closing && closeTask == nil && !exitSaveFailed
    }

    var canReturnFromSearch: Bool {
        // A failed load has no presentation token. Allow an explicit retry in that state.
        acceptsSearch && searchReturn.origin != nil && !loading && (presentationToken != nil || navigationRequest == nil)
    }

    var diagnosticOpeningSummary: String? {
        let parts = [openingPerformanceSummary, openingPresentationSummary, webView.controller?.lastReadinessFailure].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    init(bookID: String, service: LibraryService, readingMode: EPUBReadingMode? = nil,
         rendererCache: EPUBWarmRendererCache? = nil, openingIntent: ContinuousClock.Instant? = nil,
         processOpenOrdinal: Int? = nil, openingTitle: String? = nil, layoutMode: EPUBLayoutMode? = nil,
         autoRead: AutoReadSession? = nil, speech: ReaderSpeechSession? = nil) {
        self.bookID = bookID
        self.service = service
        self.autoRead = autoRead ?? AutoReadSession()
        self.speech = speech ?? ReaderSpeechSession()
        self.rendererCache = rendererCache
        let retained = rendererCache?.take(bookID: bookID, service: service)
        rendererGeneration = retained?.generation ?? UUID()
        webView = EPUBWebViewHandle(preparedController: retained?.controller)
        self.readingMode = readingMode ?? EPUBReadingMode(
            rawValue: UserDefaults.standard.string(forKey: EPUBReadingMode.defaultsKey) ?? ""
        ) ?? .scroll
        self.layoutMode = layoutMode ?? EPUBLayoutMode.restored()
        self.userFontID = EPUBUserFontPreference.restored(bookID: bookID)
        openingObservation = EPUBOpeningObservation(intentAt: openingIntent, processOpenOrdinal: processOpenOrdinal,
                                                    rendererTaken: rendererCache.map { _ in retained?.controller != nil })
        preferences = ReaderPreferences(theme: EPUBPresentationThemeHint.read())
        if let openingTitle { title = openingTitle }
        fontRemovalObservation = EPUBUserFontPreference.removed.sink { [weak self] id in
            guard let self, self.userFontID == id else { return }
            self.userFontID = nil
            self.userFontUnavailable = false
            self.refreshRemovedFontIfNeeded()
        }
    }

    /// Start alongside the system presentation; load() still admits only one active opening.
    func startOpeningFromRoute() {
        Task { @MainActor [weak self] in await self?.load() }
    }

    func recordPresentationFrame(_ token: EPUBNavigationToken) {
        guard presentationToken == token, openingObservation.observedFrame(token) else { return }
        openingPresentationSummary = openingObservation.summary
    }

    private func recordReopenReason(_ reason: EPUBReopenDiagnostics.Reason) {
        var trace = EPUBReopenDiagnostics(); trace.record(reason)
        recordReopenTrace(trace)
    }

    private func recordReopenTrace(_ trace: EPUBReopenDiagnostics) {
        rendererCache?.recordClose(trace, bookID: bookID, service: service, generation: rendererGeneration)
    }

    func setReadingMode(_ mode: EPUBReadingMode) {
        guard mode != readingMode, ready, !closing, !suspended, !exitSaveFailed else { return }
        readingMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: EPUBReadingMode.defaultsKey)
        settingsChanged()
    }

    func setLayoutMode(_ mode: EPUBLayoutMode) {
        guard mode != layoutMode, ready, !closing, !suspended, !exitSaveFailed else { return }
        layoutMode = mode
        resetCurrentRuntimeWarning()
        UserDefaults.standard.set(mode.rawValue, forKey: EPUBLayoutMode.defaultsKey)
        settingsChanged()
    }

    private func refreshRemovedFontIfNeeded() {
        if ready, userFontID == nil, navigationRequest?.userFontID != nil { setUserFont(nil) }
    }

    func setUserFont(_ font: EPUBUserFont?) {
        let id = font?.id
        let removedFromPresentation = id == nil && userFontID == nil && navigationRequest?.userFontID != nil
        let selectionValue = id.map { EPUBUserFontPreference.selectionValue($0) }
        guard (id != userFontID || removedFromPresentation), id.map(EPUBUserFontPreference.validID) != false,
              let reader, let token = currentToken, ready, !closing, !suspended, !exitSaveFailed else { return }
        revokeSpeech()
        let life = lifecycle
        navigationTask?.cancel()
        navigationTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let sampled = await self.webView.sampleNow()
            guard self.lifecycle == life, self.currentToken == token, self.ready,
                  !self.closing, !self.suspended, !self.exitSaveFailed, !Task.isCancelled else { return }
            guard selectionValue == id.map({ EPUBUserFontPreference.selectionValue($0) }) else { return }
            var target = self.currentPosition.flatMap { $0.path == token.path ? $0 : nil }
            if let sampled, sampled.sessionID == token.sessionID, sampled.epoch == token.epoch,
               self.webView.controller?.renderedChapterPaths.contains(sampled.path) == true,
               let live = try? EPUBLocationScript.makeValidatedPosition(bookID: reader.book.id,
                    package: reader.publication.package, path: sampled.path, node: sampled.node,
                    rawUTF16Offset: sampled.utf16Offset, viewportOffset: sampled.viewportOffset) { target = live }
            guard let target else {
                self.message = "尚未取得当前阅读位置，本次未更换字体。"
                return
            }
            self.userFontID = id
            if !removedFromPresentation { EPUBUserFontPreference.set(id, bookID: self.bookID) }
            await self.beginChapterNavigation(path: target.path, targetPosition: target, fragment: nil,
                preserveTargetAnchor: true, persistOnReady: false, reloadDocument: false)
        }
    }

    func load() async {
        guard reader == nil, openTask == nil, !closing, !suspended else { return }
        guard !openingAttempted else { return }
        openingAttempted = true
        openingAttemptCount += 1
        lifecycle = UUID()
        let request = lifecycle
        loading = true
        ready = false
        resetCurrentRuntimeWarning()
        openingStarted = ContinuousClock.now
        openingObservation.beganLoading()
        openingPresentationSummary = openingObservation.summary
        openingResourcesReady = nil
        loadingStage = "正在校验并准备书籍…"
        openingPerformanceSummary = nil
        do {
            let service = service
            let id = bookID
            let task = Task { [weak self] in
                try await service.openEPUB(id: id) { [weak self] sample in
                    Task { @MainActor [weak self] in
                        guard let self, self.lifecycle == request, self.reader == nil,
                              self.loading, !self.closing, !self.suspended else { return }
                        self.loadingStage = sample.stage.label + (sample.totalChapters > 0
                            ? " \(sample.completedChapters)/\(sample.totalChapters)" : "")
                    }
                }
            }
            openTask = task
            let opened = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard lifecycle == request, !closing, !suspended, !Task.isCancelled else {
                try? await opened.abandon()
                if lifecycle == request {
                    webView.discardPendingReopen()
                    rendererCache?.finish(rendererGeneration)
                }
                return
            }
            openTask = nil
            reader = opened
            openingResourcesReady = ContinuousClock.now
            title = opened.book.title
            preferences = opened.preferences.validated
            EPUBPresentationThemeHint.remember(preferences.theme)
            let package = opened.publication.package
            styleCompatibility = package.styleCompatibility
            spine = package.spine
            if package.navigation.isEmpty {
                navigationItems = package.spine.enumerated().map { index, path in
                    EPUBNavigationItem(title: "第 \(index + 1) 节", path: path, fragment: nil, depth: 0)
                }
            } else {
                navigationItems = package.navigation
            }
            sequence = 0
            preferencesSequence = 0
            if opened.reading.ignoredIncompatibleProgress {
                message = "旧位置与当前章节版本不匹配，已从开头显示；未覆盖旧记录。"
            }
            if let saved = opened.reading.position {
                currentPosition = saved
                currentPath = saved.path
                currentFragment = nil
                hasUserPosition = true
                await beginChapterNavigation(
                    path: saved.path,
                    targetPosition: saved,
                    fragment: nil,
                    preserveTargetAnchor: true,
                    persistOnReady: false,
                    reloadDocument: false // Cold/mismatched renderer still takes the normal full-load path.
                )
            } else if let firstPath = package.spine.first {
                currentPosition = nil
                currentPath = firstPath
                currentFragment = nil
                hasUserPosition = false
                await beginChapterNavigation(
                    path: firstPath,
                    targetPosition: nil,
                    fragment: nil,
                    preserveTargetAnchor: false,
                    persistOnReady: false,
                    reloadDocument: false
                )
            } else {
                loading = false
                message = "这本书没有可显示的章节内容。"
            }
        } catch {
            guard lifecycle == request else { return }
            webView.discardPendingReopen()
            rendererCache?.finish(rendererGeneration)
            openTask = nil
            loading = false
            ready = false
            navigationRequest = nil
            if !(error is CancellationError) {
                message = Self.safeFailureMessage(error)
            }
        }
    }

    func retry() async {
        guard !closing, !exitSaveFailed else { return }
        revokeSpeech()
        openingObservation.interrupt(.retry)
        openingPresentationSummary = openingObservation.summary
        if reader == nil {
            openingAttempted = false // Explicit user retry, not the view's fallback load entry.
            await load()
        } else if let path = currentPath ?? reader?.publication.package.spine.first {
            loading = true
            await beginChapterNavigation(
                path: path,
                targetPosition: currentPosition?.path == path ? currentPosition : nil,
                fragment: currentFragment,
                preserveTargetAnchor: currentPosition?.path == path,
                persistOnReady: hasUserPosition,
                reloadDocument: true
            )
        }
    }

    func go(to item: EPUBNavigationItem) {
        navigateToInternalLink(path: item.path, fragment: item.fragment)
    }

    /// Called only by the live viewport at a chapter boundary. Never wrap the spine.
    @discardableResult
    func turnChapter(_ direction: EPUBPageDirection, from token: EPUBNavigationToken) -> Bool {
        guard ready, !loading, !closing, !suspended, !exitSaveFailed,
              currentToken == token, let reader,
              let index = reader.publication.package.spine.firstIndex(of: token.path) else { return false }
        let nextIndex = index + direction.rawValue
        let paths = reader.publication.package.spine
        guard paths.indices.contains(nextIndex) else { return false }
        revokeSpeech()
        // Close the old epoch's UI admission synchronously, before the task can suspend.
        ready = false
        currentToken = nil
        generation = UUID()
        hasUserPosition = true
        currentFragment = nil
        saveTask?.cancel()
        navigationTask?.cancel()
        navigationTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await self?.beginChapterNavigation(
                path: paths[nextIndex], targetPosition: nil, fragment: nil,
                preserveTargetAnchor: false, persistOnReady: true, reloadDocument: true,
                startAtEnd: direction == .previous
            )
        }
        return true
    }

    func navigateToInternalLink(path: String, fragment: String?) {
        navigateExplicitly(path: path, fragment: fragment, target: nil)
    }

    func jumpToSearchHit(_ hit: BookSearchHit, isActive: () -> Bool) async throws {
        guard isActive(), acceptsSearch, let reader, let token = presentationToken else { throw EPUBError.staleSession }
        let life = lifecycle, gen = generation
        @MainActor func checkSelection() throws {
            try Task.checkCancellation()
            guard isActive(), acceptsSearch, lifecycle == life, generation == gen,
                  self.reader === reader, presentationToken == token else { throw EPUBError.staleSession }
        }
        let target = try await reader.resolveSearchHit(hit)
        try checkSelection()
        let origin: EPUBReadingPosition
        if let remembered = searchReturn.origin {
            origin = remembered
        } else {
            origin = try await sampleVisiblePosition(reader: reader, token: token, isActive: isActive)
            try checkSelection()
        }
        navigateExplicitly(path: target.path, fragment: nil, target: target, searchCompletion: .remember(origin))
    }

    func returnFromSearch() async {
        guard !Task.isCancelled, canReturnFromSearch, let reader, let origin = searchReturn.origin else { return }
        do {
            try origin.validate(in: reader.publication.package)
            navigateExplicitly(path: origin.path, fragment: nil, target: origin, searchCompletion: .returned)
        } catch {
            message = Self.safeFailureMessage(error)
        }
    }

    /// Shared admission/revocation for TOC, document links and a resolved bookmark.
    func navigateExplicitly(path: String, fragment: String?, target: EPUBReadingPosition?) {
        navigateExplicitly(path: path, fragment: fragment, target: target, searchCompletion: nil)
    }

    private func navigateExplicitly(path: String, fragment: String?, target: EPUBReadingPosition?,
                                    searchCompletion: SearchCompletion?) {
        guard let reader, !closing, !suspended, !exitSaveFailed,
              reader.publication.package.spine.contains(path) else {
            return
        }
        // Revoke old observations before scheduling: a queued scroll promotion must not
        // cancel this explicit user destination or overwrite its pending fragment.
        revokeSpeech()
        webView.controller?.cancelAutoPage()
        ready = false
        loading = true
        loadingStage = "正在定位目标章节…"
        currentToken = nil
        generation = UUID()
        let intent = generation
        currentPath = path
        hasUserPosition = true
        currentFragment = fragment
        message = nil
        webView.clearPayload()
        promotionTask?.cancel()
        promotionTask = nil
        saveTask?.cancel()
        navigationTask?.cancel()
        navigationTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.generation == intent else { return }
            await self.beginChapterNavigation(
                path: path,
                targetPosition: target,
                fragment: fragment,
                preserveTargetAnchor: target != nil,
                persistOnReady: true,
                reloadDocument: false,
                searchCompletion: searchCompletion
            )
        }
    }

    func settingsChanged() {
        guard let reader, !closing, !suspended, !exitSaveFailed else { return }
        let validated = preferences.validated
        preferences = validated
        guard navigationRequest?.preferences != validated || navigationRequest?.readingMode != readingMode ||
                navigationRequest?.layoutMode != layoutMode else { return }
        let targetPath = currentPath ?? currentPosition?.path ?? reader.publication.package.spine.first
        guard let path = targetPath else { return }
        revokeSpeech()
        let preserved = currentPosition?.path == path ? currentPosition : nil

        settingsTask?.cancel()
        preferencesSequence += 1
        let prefSerial = preferencesSequence
        let life = lifecycle
        settingsTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                guard let self, self.lifecycle == life, !self.closing, let activeReader = self.reader else { return }
                _ = try await activeReader.savePreferences(validated, sequence: prefSerial)
            } catch is CancellationError {
            } catch {
                if let self, self.lifecycle == life, !self.closing {
                    #if DEBUG
                    self.recordDebugBackgroundFailure("settings", error: error)
                    #endif
                    self.message = "阅读设置暂未保存。"
                }
            }
        }

        navigationTask?.cancel()
        navigationTask = Task { @MainActor [weak self] in
            guard let self, self.lifecycle == life, !Task.isCancelled else { return }
            let token = self.currentToken
            var target = preserved
            if self.ready, let token, let sampled = await self.webView.sampleNow(),
               self.currentToken == token, sampled.sessionID == token.sessionID, sampled.epoch == token.epoch,
               self.webView.controller?.renderedChapterPaths.contains(sampled.path) == true,
               let position = try? EPUBLocationScript.makeValidatedPosition(
                   bookID: reader.book.id, package: reader.publication.package, path: sampled.path,
                   node: sampled.node, rawUTF16Offset: sampled.utf16Offset, viewportOffset: sampled.viewportOffset) {
                target = position
            }
            guard self.lifecycle == life, !Task.isCancelled, self.currentToken == token else { return }
            await self.beginChapterNavigation(
                path: target?.path ?? path,
                targetPosition: target,
                fragment: target == nil ? self.currentFragment : nil,
                preserveTargetAnchor: target != nil,
                persistOnReady: self.hasUserPosition || target != nil,
                reloadDocument: false
            )
        }
    }

    private func beginChapterNavigation(
        path: String,
        targetPosition: EPUBReadingPosition?,
        fragment: String?,
        preserveTargetAnchor: Bool,
        persistOnReady: Bool,
        reloadDocument: Bool,
        startAtEnd: Bool = false,
        searchCompletion: SearchCompletion? = nil
    ) async {
        guard !Task.isCancelled, let reader, !closing, !suspended, !exitSaveFailed else { return }
        webView.controller?.cancelAutoPage()
        promotionTask?.cancel()
        promotionTask = nil
        saveTask?.cancel()
        generation = UUID()
        let gen = generation
        let life = lifecycle
        promotingVisibleChapter = false
        ready = false
        currentToken = nil
        // Reflow stays inside the settings panel. Global loading compacts tools and
        // dismisses that panel; only full loads set it here (explicit jumps set it earlier).
        if reloadDocument { loading = true }
        loadingStage = "正在排版章节并恢复位置…"
        do {
            let token = try await reader.beginNavigation(path: path)
            guard !Task.isCancelled, lifecycle == life, generation == gen, !closing, !suspended, self.reader === reader else { return }
            documentOrigin = token
            currentToken = token
            searchReturn.stage(searchCompletion, navigation: gen)
            currentPath = path
            shouldPersistOnReady = persistOnReady
            webView.clearPayload()
            navigationRequest = EPUBNavigationRequest(
                id: UUID(),
                token: token,
                publication: reader.publication,
                targetPosition: targetPosition,
                fragment: fragment,
                preferences: preferences.validated,
                preserveTargetAnchor: preserveTargetAnchor,
                reloadDocument: reloadDocument,
                startAtEnd: startAtEnd,
                readingMode: readingMode, layoutMode: effectiveLayoutMode, userFontID: userFontID
            )
            // Do not wait for SwiftUI reconciliation to revoke the old viewport epoch.
            if let request = navigationRequest { webView.controller?.apply(request) }
        } catch is CancellationError {
        } catch {
            guard lifecycle == life, generation == gen, !closing else { return }
            loading = false
            ready = false
            navigationRequest = nil
            message = Self.safeFailureMessage(error)
        }
    }

    func handleLocatorEvent(_ payload: EPUBLocatorPayload) {
        guard !closing, !suspended, !exitSaveFailed,
              let reader, let token = currentToken,
              payload.sessionID == reader.reading.session.id,
              payload.epoch == token.epoch else { return }
        if payload.path != token.path {
            guard payload.kind == .scroll, ready,
                  webView.controller?.renderedChapterPaths.contains(payload.path) == true else { return }
            promoteVisibleChapter(payload, from: token)
            return
        }
        webView.recordPayload(payload)
        switch payload.kind {
        case .error:
            generation = UUID()
            currentToken = nil
            webView.controller?.rejectPresentation(for: token)
            promotingVisibleChapter = false
            loading = false
            ready = false
            navigationRequest = nil
            message = "章节内容校验或定位未通过，原阅读位置已保留。"
        case .ready:
            guard !payload.restorationPending else { return }
            promotingVisibleChapter = false
            // A seamless promotion was already marked ready before publishing the request.
            // Do not replace its real observed position with a synthetic ready fallback.
            if navigationRequest?.preserveViewport == true {
                guard webView.controller?.acknowledgePresentation(for: token) != false else {
                    handleLoadFailure(EPUBError.invalidPosition, token: token)
                    return
                }
                ready = true
                loading = false
                recordRuntimeFontFallback(payload.authorStyleFallback, token: token)
                userFontUnavailable = userFontID != nil && payload.userFontUnavailable
                return
            }
            let node = payload.restoredNode
            let rawOffset = payload.restoredOffset
            guard let position = try? EPUBLocationScript.makeValidatedPosition(
                bookID: reader.book.id,
                package: reader.publication.package,
                path: token.path,
                node: node,
                rawUTF16Offset: rawOffset,
                viewportOffset: navigationRequest?.preserveTargetAnchor == true
                    ? navigationRequest?.targetPosition?.viewportOffset : payload.viewportOffset
            ) else {
                generation = UUID()
                currentToken = nil
                webView.controller?.rejectPresentation(for: token)
                loading = false
                ready = false
                navigationRequest = nil
                message = "章节定位坐标无效，未写入进度。"
                return
            }
            if searchReturn.pendingNavigation != nil && (navigationRequest?.targetPosition != position || position.utf16Offset != rawOffset) {
                rejectUnconfirmedPosition(token)
                return
            }
            let life = lifecycle
            let gen = generation
            let expectedToken = token
            let persist = shouldPersistOnReady
            Task { @MainActor [weak self] in
                guard let self,
                      self.lifecycle == life,
                      self.generation == gen,
                      !self.closing,
                      !self.suspended,
                      self.currentToken == expectedToken,
                      let activeReader = self.reader else {
                    return
                }
                do {
                    let marked = try await activeReader.markReady(expectedToken)
                    guard self.lifecycle == life,
                          self.generation == gen,
                          !self.closing,
                          !self.suspended,
                          self.currentToken == expectedToken else {
                        return
                    }
                    guard marked else {
                        self.rejectUnconfirmedPosition(expectedToken)
                        return
                    }
                    // No suspension between the accepted presentation and publishing ready.
                    let acknowledged = self.webView.controller?.acknowledgePresentation(for: expectedToken)
                    guard acknowledged == true || (acknowledged == nil && self.searchReturn.pendingNavigation == nil) else {
                        self.handleLoadFailure(EPUBError.invalidPosition, token: expectedToken)
                        return
                    }
                    self.currentPosition = position
                    self.ready = true
                    self.loading = false
                    // Commit only the current generation's displayed destination, never its request.
                    if self.searchReturn.pendingNavigation != nil {
                        if self.acceptsSearch { self.searchReturn.confirm(navigation: gen) }
                        else { self.searchReturn.cancelPending() }
                    }
                    self.recordRuntimeFontFallback(payload.authorStyleFallback, token: expectedToken)
                    self.userFontUnavailable = self.userFontID != nil && payload.userFontUnavailable
                    if let started = self.openingStarted {
                        self.openingObservation.becameReady(expectedToken)
                        self.openingPresentationSummary = self.openingObservation.summary
                        self.openingStarted = nil
                        let elapsed = started.duration(to: ContinuousClock.now).components
                        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                        let preparation = started.duration(to: self.openingResourcesReady ?? started).components
                        let preparationSeconds = Double(preparation.seconds) + Double(preparation.attoseconds) / 1e18
                        self.openingPerformanceSummary = String(
                            format: "打开→章节就绪 %.3fs\n资源准备 %.3fs；章节排版/恢复 %.3fs\n首绘未单列；仅本地摘要。",
                            seconds, preparationSeconds, max(0, seconds - preparationSeconds)
                        ) + (activeReader.reusedResources
                            ? "\n多本版本内容命中：本次整书解析0、资源复制0；原书和逐资源SHA仍完整校验。"
                            : "\n本次重新构建资源缓存。")
                            + "\n" + activeReader.openingTimings.summary
                            + "\n" + (self.rendererCache?.diagnostics(bookID: self.bookID, service: self.service).summary
                                       ?? "复用原因：reopen-reasons-v1；未配置页面缓存")
                            + "\n细分项未覆盖全部等待/调度，不与上方总耗时重复相加。"
                    }
                    if persist {
                        self.hasUserPosition = true
                        self.sequence += 1
                        let serial = self.sequence
                        _ = try await activeReader.save(position, sequence: serial, token: expectedToken)
                    }
                } catch is CancellationError {
                    if self.lifecycle == life, self.generation == gen,
                       self.currentToken == expectedToken, !self.ready {
                        self.rejectUnconfirmedPosition(expectedToken)
                    }
                } catch {
                    if self.lifecycle == life, self.generation == gen,
                       self.currentToken == expectedToken, !self.ready {
                        self.rejectUnconfirmedPosition(expectedToken)
                    }
                    if self.lifecycle == life, !self.closing {
                        self.message = Self.safeFailureMessage(error)
                    }
                }
            }
        case .scroll:
            guard ready else { return }
            guard let position = try? EPUBLocationScript.makeValidatedPosition(
                bookID: reader.book.id,
                package: reader.publication.package,
                path: token.path,
                node: payload.node,
                rawUTF16Offset: payload.utf16Offset,
                viewportOffset: payload.viewportOffset
            ) else {
                return
            }
            recordRuntimeFontFallback(payload.authorStyleFallback, token: token)
            currentPosition = position
            hasUserPosition = true
            sequence += 1
            let serial = sequence
            let life = lifecycle
            let expectedToken = token
            saveTask?.cancel()
            saveTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    try Task.checkCancellation()
                    guard let self,
                          self.lifecycle == life,
                          !self.closing,
                          !self.suspended,
                          self.currentToken == expectedToken,
                          self.ready,
                          let activeReader = self.reader else {
                        return
                    }
                    _ = try await activeReader.save(position, sequence: serial, token: expectedToken)
                } catch is CancellationError {
                } catch {
                    if let self, self.lifecycle == life, !self.closing {
                        #if DEBUG
                        self.recordDebugBackgroundFailure("scroll_save", error: error)
                        #endif
                        self.message = "位置暂未保存，原记录已保留。"
                    }
                }
            }
        }
    }

    /// Rendering neighbors never calls this. Only a validated visible locator can promote.
    private func promoteVisibleChapter(_ payload: EPUBLocatorPayload, from oldToken: EPUBNavigationToken) {
        guard currentToken == oldToken, let reader, let position = try? EPUBLocationScript.makeValidatedPosition(
            bookID: reader.book.id, package: reader.publication.package, path: payload.path,
            node: payload.node, rawUTF16Offset: payload.utf16Offset,
            viewportOffset: payload.viewportOffset
        ) else { return }
        saveTask?.cancel()
        navigationTask?.cancel()
        promotionTask?.cancel()
        generation = UUID()
        let gen = generation
        let life = lifecycle
        // Revoke old UI admission synchronously; the scroll view and its DOM stay alive.
        promotingVisibleChapter = true
        currentToken = nil
        ready = false
        promotionTask = Task { @MainActor [weak self] in
            do {
                let token = try await reader.beginNavigation(path: payload.path)
                guard let self, !Task.isCancelled, self.lifecycle == life, self.generation == gen,
                      !self.closing, !self.suspended, self.reader === reader else { return }
                let marked = try await reader.markReady(token)
                guard marked, !Task.isCancelled, self.lifecycle == life, self.generation == gen,
                      !self.closing, !self.suspended, self.reader === reader else { return }
                self.currentToken = token
                self.currentPath = payload.path
                self.currentPosition = position
                self.currentFragment = nil
                self.hasUserPosition = true
                self.shouldPersistOnReady = false
                self.webView.clearPayload()
                self.navigationRequest = EPUBNavigationRequest(
                    id: UUID(), token: token, publication: reader.publication,
                    targetPosition: nil, fragment: nil, preferences: self.preferences.validated,
                    preserveTargetAnchor: false, reloadDocument: false,
                    readingMode: self.readingMode, preserveViewport: true, layoutMode: self.effectiveLayoutMode,
                    userFontID: self.userFontID
                )
                // Apply immediately: SwiftUI updates may arrive after the user exits the page.
                if let request = self.navigationRequest { self.webView.controller?.apply(request) }
                self.sequence += 1
                _ = try await reader.save(position, sequence: self.sequence, token: token)
            } catch is CancellationError {
            } catch {
                guard let self, self.lifecycle == life, self.generation == gen else { return }
                self.promotingVisibleChapter = false
                self.ready = false
                self.message = "跨章位置交接未完成，已保存记录保留。请重试打开。"
            }
        }
    }

    /// Capture a crossing that happened immediately before a save/exit, not a speculative preload.
    private func settleVisibleChapter() async {
        await awaitVisiblePromotion()
        guard !closing, !suspended, ready, let token = currentToken else { return }
        if let sample = await webView.sampleNow(), currentToken == token,
           sample.sessionID == token.sessionID, sample.epoch == token.epoch,
           sample.path != token.path,
           webView.controller?.renderedChapterPaths.contains(sample.path) == true {
            promoteVisibleChapter(sample, from: token)
        }
        // The sample itself, or a concurrent scroll observer during IPC, can
        // start the handoff. Close/suspend must not outrun its acknowledgement.
        await awaitVisiblePromotion()
    }

    private func awaitVisiblePromotion() async {
        await promotionTask?.value
        guard let request = navigationRequest, request.preserveViewport else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while currentToken == request.token, !ready, !closing, !suspended, message == nil, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        }
    }

    func handlePreloadFailure() {
        guard !closing, !suspended else { return }
        message = "相邻章节预载未完成，当前正文与已保存位置保留。可通过目录重试该章。"
    }

    func handleLoadFailure(_ error: Error, token: EPUBNavigationToken) {
        guard !closing, !suspended, currentToken == token else { return }
        webView.controller?.cancelAutoPage()
        promotingVisibleChapter = false
        // Revoke callback ownership before any suspended markReady/save continuation resumes.
        generation = UUID()
        currentToken = nil
        saveTask?.cancel()
        navigationTask?.cancel()
        promotionTask?.cancel()
        webView.clearPayload()
        loading = false
        ready = false
        navigationRequest = nil
        if !(error is CancellationError) {
            message = (error as? URLError)?.code == .timedOut
                ? "章节加载未能及时完成，可重试打开；原书与已保存位置保留。"
                : Self.safeFailureMessage(error)
        }
    }

    func flush() async {
        await settleVisibleChapter()
        guard !closing, let reader else { return }
        let life = lifecycle
        saveTask?.cancel()
        settingsTask?.cancel()
        if ready, let token = currentToken, let sampled = await webView.sampleNow(),
           lifecycle == life, !closing, currentToken == token,
           sampled.sessionID == reader.reading.session.id,
           sampled.epoch == token.epoch,
           sampled.path == token.path,
           let validated = try? EPUBLocationScript.makeValidatedPosition(
               bookID: reader.book.id,
               package: reader.publication.package,
               path: token.path,
               node: sampled.node,
               rawUTF16Offset: sampled.utf16Offset,
               viewportOffset: sampled.viewportOffset
           ) {
            if sampled.scrollY > 1 || sampled.scrollX > 1 {
                hasUserPosition = true
            }
            if hasUserPosition {
                currentPosition = validated
            }
        }
        guard lifecycle == life, !closing else { return }
        sequence += 1
        preferencesSequence += 1
        let serial = sequence
        let prefSerial = preferencesSequence
        let settings = preferences.validated
        do {
            if ready, hasUserPosition, let position = currentPosition, let token = currentToken, position.path == token.path {
                _ = try await reader.save(position, sequence: serial, token: token)
            }
            guard lifecycle == life, !closing else { return }
            _ = try await reader.savePreferences(settings, sequence: prefSerial)
        } catch is CancellationError {
        } catch {
            if lifecycle == life, !closing {
                #if DEBUG
                recordDebugBackgroundFailure("flush", error: error)
                #endif
                message = "保存未完成，已保存记录仍保留。"
            }
        }
    }

    private func rejectUnconfirmedPosition(_ token: EPUBNavigationToken) {
        webView.controller?.rejectPresentation(for: token)
        // Normally rejectPresentation delivers onLoadFailure synchronously. A detached
        // controller cannot do so; don't strand a pending search (especially a return).
        if searchReturn.pendingNavigation != nil { handleLoadFailure(EPUBError.invalidPosition, token: token) }
    }

    func suspend() async {
        guard !closing, !suspended, !suspending else { return }
        stopAutoRead()
        suspending = true
        openingObservation.interrupt(.background)
        openingPresentationSummary = openingObservation.summary
        await settleVisibleChapter()
        suspended = true
        suspending = false
        resetCurrentRuntimeWarning()
        lifecycle = UUID()
        generation = UUID()
        openTask?.cancel()
        openTask = nil
        navigationTask?.cancel()
        navigationTask = nil
        let application = UIApplication.shared
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = application.beginBackgroundTask(withName: "dev.yuejing.epub.suspend") {
            if bgTask != .invalid {
                application.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        defer {
            if bgTask != .invalid {
                application.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        await flush()
        if resumeAfterSettling { resumeAfterSettling = false; await resume() }
    }

    func resume() async {
        guard !closing else { return }
        if suspending { resumeAfterSettling = true; return }
        guard suspended else { return }
        suspended = false
        lifecycle = UUID()
        if let target = pendingSpeechLocation {
            pendingSpeechLocation = nil
            navigateExplicitly(path: target.path, fragment: nil, target: target)
            return
        }
        if reader == nil {
            openingAttempted = false // Preserve existing resume of a suspended opening.
            await load()
        } else if let path = currentPath ?? reader?.publication.package.spine.first {
            await beginChapterNavigation(
                path: path,
                targetPosition: currentPosition?.path == path ? currentPosition : nil,
                fragment: currentFragment,
                preserveTargetAnchor: currentPosition?.path == path,
                persistOnReady: false,
                reloadDocument: false
            )
        }
    }

    func releaseReaderMemory() async {
        await service.releaseProcessingCache()
        await EPUBCoverProcessor.shared.clear()
    }

    func close() async -> Bool {
        if let closeTask { return await closeTask.value }
        stopAutoRead()
        revokeSpeech()
        let task = Task { @MainActor in await self.performClose() }
        closeTask = task
        sceneReadyRevision &+= 1
        return await task.value
    }

    private func performClose() async -> Bool {
        guard !closing else { return false }
        await settleVisibleChapter()
        guard !closing else { return false }
        closing = true
        lifecycle = UUID()
        generation = UUID()
        openTask?.cancel()
        openTask = nil
        navigationTask?.cancel()
        navigationTask = nil
        saveTask?.cancel()
        settingsTask?.cancel()
        let wasReady = ready
        recordReopenReason(.closeStarted)
        if !wasReady { recordReopenReason(.closeNotReady) }
        let activeToken = currentToken
        if wasReady, let reader, let token = activeToken, let sampled = await webView.sampleNow(),
           sampled.sessionID == reader.reading.session.id,
           sampled.epoch == token.epoch,
           sampled.path == token.path,
           let validated = try? EPUBLocationScript.makeValidatedPosition(
               bookID: reader.book.id,
               package: reader.publication.package,
               path: token.path,
               node: sampled.node,
               rawUTF16Offset: sampled.utf16Offset,
               viewportOffset: sampled.viewportOffset
           ) {
            if sampled.scrollY > 1 || sampled.scrollX > 1 {
                hasUserPosition = true
            }
            if hasUserPosition {
                currentPosition = validated
            }
        }

        let finalPosition: EPUBReadingPosition? = (wasReady && hasUserPosition) ? currentPosition : nil
        let finalToken: EPUBNavigationToken? = (wasReady && finalPosition != nil) ? activeToken : nil
        sequence += 1
        preferencesSequence += 1
        let old = reader
        // A renderer needs its own file-lifetime lease before closing releases the reader's lease.
        // Failure to obtain this optional pin only disables the hot cache, not the reading save.
        var rendererLease: EPUBContentLease?
        var retainedRenderer = false
        if wasReady, rendererCache != nil, let old { rendererLease = try? await old.leaseForRenderer() }
        if wasReady, rendererCache != nil, rendererLease == nil { recordReopenReason(.leaseUnavailable) }
        do {
            if let old {
                try await old.close(
                    position: finalPosition,
                    sequence: sequence,
                    token: finalToken,
                    preferences: preferences.validated
                )
                EPUBPresentationThemeHint.remember(preferences.theme)
            }
            if let controller = webView.controller {
                if wasReady, let rendererCache, let rendererLease,
                   await controller.parkForReopen(lease: rendererLease) {
                    recordReopenTrace(controller.parkDiagnostics)
                    webView.releaseParkedController(controller)
                    retainedRenderer = rendererCache.retain(controller, bookID: bookID, service: service, generation: rendererGeneration)
                } else {
                    recordReopenTrace(controller.parkDiagnostics)
                    webView.detach(controller)
                }
            } else {
                recordReopenReason(.controllerMissing)
            }
            webView.detachAll() // Includes an unmounted prepared controller; transferred handles are already empty.
            if !retainedRenderer { await rendererLease?.release() }
            rendererCache?.finish(rendererGeneration)
            reader = nil
            navigationRequest = nil
            currentToken = nil
            ready = false
            return true
        } catch {
            recordReopenReason(.saveFailed)
            await rendererLease?.release()
            rendererCache?.finish(rendererGeneration)
            closing = false
            exitSaveFailed = true
            message = "最后保存失败，未覆盖已保存记录。请返回书架后重新打开。"
            return false
        }
    }

    func leaveKeepingSavedPosition() async {
        stopAutoRead()
        revokeSpeech()
        recordReopenReason(.abandoned)
        closing = true
        lifecycle = UUID()
        generation = UUID()
        openTask?.cancel()
        openTask = nil
        navigationTask?.cancel()
        navigationTask = nil
        promotionTask?.cancel()
        promotionTask = nil
        saveTask?.cancel()
        settingsTask?.cancel()
        if let reader {
            try? await reader.close(
                position: nil,
                sequence: sequence + 1,
                token: nil,
                preferences: preferences.validated
            )
        }
        webView.detachAll()
        rendererCache?.finish(rendererGeneration)
        reader = nil
        navigationRequest = nil
        currentToken = nil
        ready = false
    }

    static func safeFailureMessage(_ error: Error) -> String {
        if error is EPUBStyleProcessingError {
            return "作者样式复杂度超过安全处理范围，暂无法安全完成排版；原书和进度已保留。"
        }
        if let libError = error as? LibraryError {
            return libError.errorDescription ?? "读取未完成，原书和已保存位置已保留。"
        }
        if let epubError = error as? EPUBError {
            switch epubError {
            case .invalidArchive:
                return "EPUB 归档已损坏或格式无效，原书架记录与位置已保留。"
            case .limitExceeded:
                return "EPUB 章节或资源超出安全体积限制，暂无法打开。"
            case .corruptResource:
                return "检测到 EPUB 章节或资源校验不匹配，未覆盖原记录与已保存位置。"
            case .invalidPackage:
                return "EPUB 包结构或阅读顺序无效，暂无法显示正文。"
            case .invalidPosition:
                return "阅读位置与当前章节内容不匹配，原已保存记录未改变。"
            case .staleSession:
                return "当前阅读会话已过期，请重新打开。"
            default:
                return "暂不支持该 EPUB 内容特性（如 DRM、固定版式、脚本或外部资源）。"
            }
        }
        return "读取未完成，原书和已保存位置已保留。"
    }
}

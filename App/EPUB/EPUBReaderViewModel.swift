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
    @Published private(set) var loading = true
    @Published private(set) var ready = false
    @Published private(set) var exitSaveFailed = false
    @Published var message: String?
    @Published private(set) var openingPerformanceSummary: String?
    @Published private(set) var loadingStage = "正在校验并准备书籍…"

    let webView: EPUBWebViewHandle
    private let rendererCache: EPUBWarmRendererCache?
    private let rendererGeneration: UUID
    private let bookID: String
    private let service: LibraryService
    private(set) var reader: OpenedEPUBReader?
    private(set) var currentToken: EPUBNavigationToken?
    private var sequence: Int64 = 0
    private var preferencesSequence: Int64 = 0
    private var lifecycle = UUID()
    private var generation = UUID()
    private var closing = false
    private var suspended = false
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

    init(bookID: String, service: LibraryService, readingMode: EPUBReadingMode? = nil,
         rendererCache: EPUBWarmRendererCache? = nil) {
        self.bookID = bookID
        self.service = service
        self.rendererCache = rendererCache
        let retained = rendererCache?.take(bookID: bookID, service: service)
        rendererGeneration = retained?.generation ?? UUID()
        webView = EPUBWebViewHandle(preparedController: retained?.controller)
        self.readingMode = readingMode ?? EPUBReadingMode(
            rawValue: UserDefaults.standard.string(forKey: EPUBReadingMode.defaultsKey) ?? ""
        ) ?? .scroll
    }

    func setReadingMode(_ mode: EPUBReadingMode) {
        guard mode != readingMode, ready, !closing, !suspended, !exitSaveFailed else { return }
        readingMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: EPUBReadingMode.defaultsKey)
        settingsChanged()
    }

    func load() async {
        guard reader == nil, openTask == nil, !closing, !suspended else { return }
        lifecycle = UUID()
        let request = lifecycle
        loading = true
        ready = false
        openingStarted = ContinuousClock.now
        openingResourcesReady = nil
        loadingStage = "正在校验并准备书籍…"
        openingPerformanceSummary = nil
        do {
            let service = service
            let id = bookID
            let task = Task { try await service.openEPUB(id: id) }
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
            let package = opened.publication.package
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
        if reader == nil {
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
        guard let reader, !closing, !suspended, !exitSaveFailed,
              reader.publication.package.spine.contains(path) else {
            return
        }
        // Revoke old observations before scheduling: a queued scroll promotion must not
        // cancel this explicit user destination or overwrite its pending fragment.
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
                targetPosition: nil,
                fragment: fragment,
                preserveTargetAnchor: false,
                persistOnReady: true,
                reloadDocument: false
            )
        }
    }

    func settingsChanged() {
        guard let reader, !closing, !suspended, !exitSaveFailed else { return }
        let validated = preferences.validated
        preferences = validated
        guard navigationRequest?.preferences != validated || navigationRequest?.readingMode != readingMode else { return }
        let targetPath = currentPath ?? currentPosition?.path ?? reader.publication.package.spine.first
        guard let path = targetPath else { return }
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
                    self.message = "阅读设置暂未保存。"
                }
            }
        }

        navigationTask?.cancel()
        navigationTask = Task { @MainActor [weak self] in
            await self?.beginChapterNavigation(
                path: path,
                targetPosition: preserved,
                fragment: preserved == nil ? self?.currentFragment : nil,
                preserveTargetAnchor: preserved != nil,
                persistOnReady: (self?.hasUserPosition ?? false) || preserved != nil,
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
        startAtEnd: Bool = false
    ) async {
        guard !Task.isCancelled, let reader, !closing, !suspended, !exitSaveFailed else { return }
        promotionTask?.cancel()
        promotionTask = nil
        saveTask?.cancel()
        generation = UUID()
        let gen = generation
        let life = lifecycle
        ready = false
        currentToken = nil
        // Reflow stays inside the settings panel. Global loading compacts tools and
        // dismisses that panel; only full loads set it here (explicit jumps set it earlier).
        if reloadDocument { loading = true }
        loadingStage = "正在排版章节并恢复位置…"
        do {
            let token = try await reader.beginNavigation(path: path)
            guard !Task.isCancelled, lifecycle == life, generation == gen, !closing, !suspended, self.reader === reader else { return }
            currentToken = token
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
                readingMode: readingMode
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
            loading = false
            ready = false
            navigationRequest = nil
            message = "章节内容校验或定位未通过，原阅读位置已保留。"
        case .ready:
            // A seamless promotion was already marked ready before publishing the request.
            // Do not replace its real observed position with a synthetic ready fallback.
            if navigationRequest?.preserveViewport == true {
                ready = true
                loading = false
                return
            }
            let node = payload.restoredNode
            let rawOffset = payload.restoredOffset
            guard let position = try? EPUBLocationScript.makeValidatedPosition(
                bookID: reader.book.id,
                package: reader.publication.package,
                path: token.path,
                node: node,
                rawUTF16Offset: rawOffset
            ) else {
                loading = false
                ready = false
                navigationRequest = nil
                message = "章节定位坐标无效，未写入进度。"
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
                          self.currentToken == expectedToken,
                          marked else {
                        return
                    }
                    self.currentPosition = position
                    self.ready = true
                    self.loading = false
                    if let started = self.openingStarted {
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
                            + "\n细分项未覆盖全部等待/调度，不与上方总耗时重复相加。"
                    }
                    if persist {
                        self.hasUserPosition = true
                        self.sequence += 1
                        let serial = self.sequence
                        _ = try await activeReader.save(position, sequence: serial, token: expectedToken)
                    }
                } catch is CancellationError {
                } catch {
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
                rawUTF16Offset: payload.utf16Offset
            ) else {
                return
            }
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
            node: payload.node, rawUTF16Offset: payload.utf16Offset
        ) else { return }
        saveTask?.cancel()
        navigationTask?.cancel()
        promotionTask?.cancel()
        generation = UUID()
        let gen = generation
        let life = lifecycle
        // Revoke old UI admission synchronously; the scroll view and its DOM stay alive.
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
                    readingMode: self.readingMode, preserveViewport: true
                )
                // Apply immediately: SwiftUI updates may arrive after the user exits the page.
                if let request = self.navigationRequest { self.webView.controller?.apply(request) }
                self.sequence += 1
                _ = try await reader.save(position, sequence: self.sequence, token: token)
            } catch is CancellationError {
            } catch {
                guard let self, self.lifecycle == life, self.generation == gen else { return }
                self.ready = false
                self.message = "跨章位置交接未完成，已保存记录保留。请重试打开。"
            }
        }
    }

    /// Capture a crossing that happened immediately before a save/exit, not a speculative preload.
    private func settleVisibleChapter() async {
        await promotionTask?.value
        if navigationRequest?.preserveViewport == true {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !ready, !closing, !suspended, message == nil, ContinuousClock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
        }
        guard !closing, !suspended, ready, let token = currentToken,
              let sample = await webView.sampleNow(), currentToken == token,
              sample.sessionID == token.sessionID, sample.epoch == token.epoch,
              sample.path != token.path,
              webView.controller?.renderedChapterPaths.contains(sample.path) == true else { return }
        promoteVisibleChapter(sample, from: token)
        await promotionTask?.value
    }

    func handlePreloadFailure() {
        guard !closing, !suspended else { return }
        message = "相邻章节预载未完成，当前正文与已保存位置保留。可通过目录重试该章。"
    }

    func handleLoadFailure(_ error: Error, token: EPUBNavigationToken) {
        guard !closing, !suspended, currentToken == token else { return }
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
               rawUTF16Offset: sampled.utf16Offset
           ) {
            if sampled.scrollY > 1 {
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
        } catch {
            if lifecycle == life, !closing {
                message = "保存未完成，已保存记录仍保留。"
            }
        }
    }

    func suspend() async {
        guard !closing, !suspended else { return }
        await settleVisibleChapter()
        suspended = true
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
    }

    func resume() async {
        guard !closing else { return }
        guard suspended else { return }
        suspended = false
        lifecycle = UUID()
        if reader == nil {
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
        let task = Task { @MainActor in await self.performClose() }
        closeTask = task
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
               rawUTF16Offset: sampled.utf16Offset
           ) {
            if sampled.scrollY > 1 {
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
        do {
            if let old {
                try await old.close(
                    position: finalPosition,
                    sequence: sequence,
                    token: finalToken,
                    preferences: preferences.validated
                )
            }
            if let controller = webView.controller {
                if wasReady, let rendererCache, let rendererLease,
                   await controller.parkForReopen(lease: rendererLease) {
                    webView.releaseParkedController(controller)
                    retainedRenderer = rendererCache.retain(controller, bookID: bookID, service: service, generation: rendererGeneration)
                } else {
                    webView.detach(controller)
                }
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
            await rendererLease?.release()
            rendererCache?.finish(rendererGeneration)
            closing = false
            exitSaveFailed = true
            message = "最后保存失败，未覆盖已保存记录。请返回书架后重新打开。"
            return false
        }
    }

    func leaveKeepingSavedPosition() async {
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

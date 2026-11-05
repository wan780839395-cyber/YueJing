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
    @Published private(set) var loading = true
    @Published private(set) var ready = false
    @Published private(set) var exitSaveFailed = false
    @Published var message: String?
    @Published private(set) var openingPerformanceSummary: String?

    let webView = EPUBWebViewHandle()
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
    private var openingStarted: ContinuousClock.Instant?

    init(bookID: String, service: LibraryService) {
        self.bookID = bookID
        self.service = service
    }

    func load() async {
        guard reader == nil, openTask == nil, !closing, !suspended else { return }
        lifecycle = UUID()
        let request = lifecycle
        loading = true
        ready = false
        openingStarted = ContinuousClock.now
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
                return
            }
            openTask = nil
            reader = opened
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
                    reloadDocument: true
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
                    reloadDocument: true
                )
            } else {
                loading = false
                message = "这本书没有可显示的章节内容。"
            }
        } catch {
            guard lifecycle == request else { return }
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
        guard let reader, !closing, !suspended, !exitSaveFailed,
              reader.publication.package.spine.contains(item.path) else {
            return
        }
        hasUserPosition = true
        currentFragment = item.fragment
        navigationTask?.cancel()
        navigationTask = Task { @MainActor [weak self] in
            await self?.beginChapterNavigation(
                path: item.path,
                targetPosition: nil,
                fragment: item.fragment,
                preserveTargetAnchor: false,
                persistOnReady: true,
                reloadDocument: true
            )
        }
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
        hasUserPosition = true
        currentFragment = fragment
        navigationTask?.cancel()
        navigationTask = Task { @MainActor [weak self] in
            await self?.beginChapterNavigation(
                path: path,
                targetPosition: nil,
                fragment: fragment,
                preserveTargetAnchor: false,
                persistOnReady: true,
                reloadDocument: true
            )
        }
    }

    func settingsChanged() {
        guard let reader, !closing, !suspended, !exitSaveFailed else { return }
        let validated = preferences.validated
        preferences = validated
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
        guard let reader, !closing, !suspended, !exitSaveFailed else { return }
        saveTask?.cancel()
        generation = UUID()
        let gen = generation
        let life = lifecycle
        ready = false
        do {
            let token = try await reader.beginNavigation(path: path)
            guard lifecycle == life, generation == gen, !closing, !suspended, self.reader === reader else { return }
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
                startAtEnd: startAtEnd
            )
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
              let reader,
              let token = currentToken,
              payload.sessionID == reader.reading.session.id,
              payload.epoch == token.epoch,
              payload.path == token.path else {
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
                        self.openingPerformanceSummary = String(
                            format: "打开请求→EPUB 章节已就绪 %.3fs\n进程重启/首绘未单列；仅本地摘要。",
                            seconds
                        )
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

    func handleLoadFailure(_ error: Error, token: EPUBNavigationToken) {
        guard !closing, !suspended, currentToken == token else { return }
        loading = false
        ready = false
        navigationRequest = nil
        if !(error is CancellationError) {
            message = Self.safeFailureMessage(error)
        }
    }

    func flush() async {
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
                webView.detach(controller)
            }
            reader = nil
            navigationRequest = nil
            currentToken = nil
            ready = false
            return true
        } catch {
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
        if let controller = webView.controller {
            webView.detach(controller)
        }
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

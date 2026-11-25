import Foundation
import ReaderDomain
import SwiftUI
import Testing
import UIKit
@testable import YueJing

@MainActor
@Suite(.serialized)
struct TXTSpeechFollowHostTests {
    private final class MockSpeechAudio: ReaderSpeechAudio {
        var texts: [String] = []
        var immediateStart = false
        var begin: (@MainActor () -> Void)?
        var finish: (@MainActor (Bool) -> Void)?
        var silenceCalls = 0

        func speak(_ text: String, multiplier: Float, started: @escaping @MainActor () -> Void,
                   ended: @escaping @MainActor (Bool) -> Void) throws {
            texts.append(text)
            begin = started
            finish = ended
            if immediateStart { started() }
        }

        func silence() {
            silenceCalls += 1
            begin = nil
            finish = nil
        }

        func fireStarted() {
            let callback = begin
            begin = nil
            callback?()
        }

        func fireFinished(_ ok: Bool = true) {
            let callback = finish
            finish = nil
            begin = nil
            callback?(ok)
        }
    }

    @Test func audibleStartFollowsMinimallyWithoutMovingVisibleLinesOrPrefetch() async throws {
        let audio = MockSpeechAudio()
        audio.immediateStart = false
        let speech = ReaderSpeechSession(audio: audio, foreground: { true })
        try await withTXTReader(speech: speech) { model, controller, table, _, _ in
            let initial = try #require(model.window)
            let initialOffset = table.contentOffset.y
            model.startSpeech()
            try await waitUntil("chunk0Queued") { audio.texts.count == 1 && audio.begin != nil }
            // Prefetch/queueing alone must never move the viewport before audible start.
            #expect(table.contentOffset.y == initialOffset)

            audio.fireStarted()
            #expect(table.contentOffset.y == initialOffset)
            #expect(model.window?.id == initial.id)

            var visibleUnmoved = 0
            var revealedOffset: CGFloat?
            var revealedText: String?
            for _ in 0..<80 {
                let beforeCount = audio.texts.count
                audio.fireFinished(true)
                try await waitUntil("nextChunkQueued") { audio.texts.count == beforeCount + 1 && audio.begin != nil }
                let beforeStartOffset = table.contentOffset.y
                // Lookahead/queueing of the next chunk must not move before audible start.
                #expect(beforeStartOffset == initialOffset)
                audio.fireStarted()
                if table.contentOffset.y > initialOffset + 0.5 {
                    revealedOffset = table.contentOffset.y
                    revealedText = audio.texts.last
                    break
                }
                visibleUnmoved += 1
            }

            let movedTo = try #require(revealedOffset)
            let spoken = try #require(revealedText)
            #expect(visibleUnmoved >= 5)
            #expect(model.window?.id == initial.id)
            // Minimal reveal scrolls just enough to expose the offscreen line, not a full viewport jump.
            let delta = movedTo - initialOffset
            #expect(delta > 0 && delta < table.bounds.height * 0.5)
            let prefix = String(spoken.prefix(14))
            let targetLine = try #require(initial.slices.flatMap(\.lines).first(where: { $0.text.contains(prefix) }))
            let targetAnchor = ReadingAnchor(bookID: initial.anchor.bookID, versionID: initial.anchor.versionID,
                                             rawByteOffset: targetLine.rawByteStart)
            #expect(controller.isSpeechTargetVisible(targetAnchor, utf16: targetLine.range.location.value))
            #expect(controller.revealSpeechTarget(targetAnchor, utf16: targetLine.range.location.value) == .alreadyVisible)
            #expect(table.contentOffset.y == movedTo)

            // Verify minimal upward reveal brings an offscreen line above the viewport cleanly to visibleTop.
            table.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
            table.layoutIfNeeded()
            let firstLine = try #require(initial.slices.first?.lines.first)
            let firstAnchor = ReadingAnchor(bookID: initial.anchor.bookID, versionID: initial.anchor.versionID,
                                            rawByteOffset: firstLine.rawByteStart)
            #expect(!controller.isSpeechTargetVisible(firstAnchor, utf16: firstLine.range.location.value))
            #expect(controller.revealSpeechTarget(firstAnchor, utf16: firstLine.range.location.value) == .revealed)
            #expect(controller.isSpeechTargetVisible(firstAnchor, utf16: firstLine.range.location.value))
            #expect(abs(table.contentOffset.y - (-table.adjustedContentInset.top)) < 1)
        }
    }

    @Test func crossWindowFollowRendersBoundedWindowWithoutConsumingLeaseAndRejectsStaleTakeover() async throws {
        let audio = MockSpeechAudio()
        audio.immediateStart = false
        let speech = ReaderSpeechSession(audio: audio, foreground: { true })
        try await withTXTReader(speech: speech) { model, controller, table, _, _ in
            let initial = try #require(model.window)
            try #require(initial.hasNext)
            model.startSpeech()
            try await waitUntil("crossStart") { audio.texts.count == 1 && audio.begin != nil }
            audio.fireStarted()

            // Advance audibly until the first chunk outside Window 1 triggers bounded cross-window rendering.
            for _ in 0..<180 {
                let before = audio.texts.count
                audio.fireFinished(true)
                try await waitUntil("crossAdvance") { audio.texts.count == before + 1 && audio.begin != nil }
                let spoken = try #require(audio.texts.last)
                audio.fireStarted()
                if !windowContainsText(initial, spoken) { break }
            }

            try await waitUntil("crossWindowPublished") { model.window?.id != initial.id }
            let secondWindow = try #require(model.window)
            // Speech lease must NOT be consumed by cross-window follow.
            #expect(model.speech.isActive && model.speech.phase == .playing && model.speech.isFollowing)

            apply(secondWindow, model, controller)
            #expect(controller.isSpeechTargetVisible(secondWindow.anchor, utf16: secondWindow.targetUTF16))

            // Playback continues pulling chunks after cross-window follow.
            let countAfterCross = audio.texts.count
            audio.fireFinished(true)
            try await waitUntil("postCrossChunk") { audio.texts.count == countAfterCross + 1 && audio.begin != nil }
            audio.fireStarted()
            #expect(model.speech.isActive && model.speech.phase == .playing && model.speech.isFollowing)

            // Advance to the first chunk outside `secondWindow` so a cross-window render publishes before apply.
            try #require(secondWindow.hasNext)
            for _ in 0..<180 {
                let before = audio.texts.count
                audio.fireFinished(true)
                try await waitUntil("staleAdvance") { audio.texts.count == before + 1 && audio.begin != nil }
                let spoken = try #require(audio.texts.last)
                audio.fireStarted()
                if !windowContainsText(secondWindow, spoken) { break }
            }
            try await waitUntil("pendingCrossWindow") { model.window?.id != secondWindow.id }
            try #require(controller.window?.id == secondWindow.id)

            // Manual drag takeover before apply must reject/revert the stale cross-window follow
            // while keeping speech playing and detaching follow.
            controller.scrollViewWillBeginDragging(table)
            #expect(model.window?.id == secondWindow.id)
            #expect(!model.speech.isFollowing)
            #expect(model.speech.isActive && model.speech.phase == .playing)

            // In-flight async cross-window follow started by returnToSpeech must also be rejected
            // if immediately taken over by manual drag before the async layout completes.
            model.speech.returnToSpeech()
            controller.scrollViewWillBeginDragging(table)
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.window?.id == secondWindow.id && !model.speech.isFollowing && model.speech.isActive)

            // Subsequent chunks while detached must keep playing without replacing the user's window.
            let detachedCount = audio.texts.count
            audio.fireFinished(true)
            try await waitUntil("detachedChunk") { audio.texts.count == detachedCount + 1 && audio.begin != nil }
            audio.fireStarted()
            try await Task.sleep(for: .milliseconds(60))
            #expect(model.window?.id == secondWindow.id && !model.speech.isFollowing && model.speech.isActive)
        }
    }

    @Test func manualDragAndBrowsingDetachKeepSpeechPlayingReturnWorksWhilePausedAndExitStops() async throws {
        let audio = MockSpeechAudio()
        audio.immediateStart = true
        let speech = ReaderSpeechSession(audio: audio, foreground: { true })
        try await withTXTReader(speech: speech) { model, controller, table, service, book in
            let initial = try #require(model.window)
            model.startSpeech()
            try await waitUntil("manualStart") { model.speech.isActive && audio.texts.count == 1 }

            // 1) Manual drag detaches follow and keeps speech playing.
            controller.scrollViewWillBeginDragging(table)
            table.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
            table.layoutIfNeeded()
            controller.scrollViewDidScroll(table)
            #expect(!model.speech.isFollowing && model.speech.isActive && model.speech.phase == .playing)

            audio.fireFinished(true)
            try await waitUntil("manualChunk2") { audio.texts.count == 2 }
            #expect(abs(table.contentOffset.y - 600) < 1)

            // 2) Pause causes no movement; returnToSpeech while paused reveals current sentence without resuming audio.
            model.speech.pause()
            #expect(model.speech.phase == .paused && abs(table.contentOffset.y - 600) < 1)
            model.speech.returnToSpeech()
            #expect(model.speech.isFollowing && model.speech.phase == .paused)
            #expect(model.window?.id == initial.id)
            #expect(table.contentOffset.y < 100)

            // 3) Resume replays current heard chunk cleanly (lease remained intact).
            model.speech.resume()
            try await waitUntil("manualResume") { model.speech.phase == .playing && audio.texts.count == 3 }

            // 4) Chapter jump (user browsing) detaches follow and keeps speech playing.
            let dirPresentation = UUID()
            model.directory.present(around: model.directoryAnchor(), presentation: dirPresentation)
            try await waitUntil("chaptersLoaded") { (model.directory.state.page?.chapters.count ?? 0) >= 2 }
            let chapter2 = try #require(model.directory.state.page?.chapters[1])
            model.directory.dismiss(presentation: dirPresentation)

            model.go(to: chapter2)
            #expect(!model.speech.isFollowing && model.speech.isActive && model.speech.phase == .playing)
            try await waitUntil("chapter2Rendered") {
                model.window?.anchor.rawByteOffset == chapter2.rawByteRange.location.value
            }
            let chapterWindow = try #require(model.window)
            apply(chapterWindow, model, controller, userNavigation: model.viewport.onNextRestoreIsNavigation)
            let browsedAnchor = try #require(controller.visibleNavigationAnchor())
            #expect(browsedAnchor.rawByteOffset == chapter2.rawByteRange.location.value)
            #expect(model.speech.isActive && model.speech.phase == .playing && !model.speech.isFollowing)

            // 5) Exit still stops speech and preserves the user's detached browsing position.
            try #require(await model.close())
            #expect(!model.speech.isActive)
            let reopened = try await service.openReader(id: book.id, budget: ReaderStoragePolicy.budget())
            #expect(reopened.reading.anchor == browsedAnchor)
            try await reopened.close()
        }
    }

    @Test func lockSuspendsFollowWithoutMovementAndUnlockFollowsLatestOnceAfterReadiness() async throws {
        var foreground = true
        let audio = MockSpeechAudio()
        audio.immediateStart = true
        let speech = ReaderSpeechSession(audio: audio, foreground: { foreground })
        let autoRead = AutoReadSession()
        try await withTXTUI(autoRead: autoRead, speech: speech) { model, routeID, scene in
            let controller = try #require(model.viewport.controller)
            let table = try #require(controller.view.subviews.compactMap { $0 as? UITableView }.first)
            let initialAnchor = try #require(controller.restorableAnchor())

            model.startSpeech()
            try await waitUntil("lockSpeechStart") { model.speech.isActive && audio.texts.count == 1 }

            // 1) Lock while playing & following: advance across screens/windows with ZERO movement while locked.
            foreground = false
            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
            NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: scene)
            try await waitUntil("lockSuspended") {
                model.suspended && !model.viewport.isSceneActiveForControls(routeID: routeID)
            }
            let lockedWindowID = try #require(model.window?.id)
            let lockedOffset = table.contentOffset.y

            for _ in 0..<95 {
                let before = audio.texts.count
                audio.fireFinished(true)
                try await waitUntil("lockedAdvance") { audio.texts.count == before + 1 || !model.speech.isActive }
                if !model.speech.isActive { break }
            }
            try #require(model.speech.isActive && model.speech.phase == .playing && model.speech.isFollowing)
            #expect(model.window?.id == lockedWindowID)
            #expect(table.contentOffset.y == lockedOffset)

            let latestText = try #require(audio.texts.last)
            let latestPrefix = String(latestText.prefix(14))

            // Unlock: follow latest ONCE after genuine readiness (window resumed & applied).
            foreground = true
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
            try await waitUntil("unlockFollowedLatest") {
                !model.suspended &&
                !model.loading &&
                !model.layoutNeedsRefresh &&
                model.viewport.isSceneActiveForControls(routeID: routeID) &&
                model.window?.id == controller.window?.id &&
                (controller.window?.slices.contains(where: { slice in
                    slice.lines.contains(where: { $0.text.contains(latestPrefix) })
                }) ?? false)
            }
            let followedWindow = try #require(controller.window)
            #expect(followedWindow.id != lockedWindowID)
            #expect(controller.isSpeechTargetVisible(followedWindow.anchor, utf16: followedWindow.targetUTF16))
            #expect(model.speech.isActive && model.speech.phase == .playing && model.speech.isFollowing)
            let followedAnchor = try #require(controller.restorableAnchor())
            #expect(followedAnchor.rawByteOffset > initialAnchor.rawByteOffset)

            // 2) Lock while PAUSED -> unlock -> no movement.
            model.speech.pause()
            #expect(model.speech.phase == .paused)
            let pausedAnchor = try #require(controller.restorableAnchor())
            foreground = false
            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
            NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: scene)
            try await waitUntil("pausedLockSuspend") {
                model.suspended && !model.viewport.isSceneActiveForControls(routeID: routeID)
            }
            foreground = true
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
            try await waitUntil("pausedUnlockReady") {
                !model.suspended &&
                !model.loading &&
                !model.layoutNeedsRefresh &&
                model.viewport.isSceneActiveForControls(routeID: routeID) &&
                model.window?.id == controller.window?.id
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.speech.phase == .paused && model.speech.isFollowing)
            #expect(controller.restorableAnchor()?.rawByteOffset == pausedAnchor.rawByteOffset)

            // 3) Detach before lock -> advance while locked -> unlock -> stays detached with no movement.
            model.speech.resume()
            try await waitUntil("resumedBeforeDetach") { model.speech.phase == .playing }
            model.speech.detachFollow()
            #expect(!model.speech.isFollowing)
            let detachedAnchor = try #require(controller.restorableAnchor())
            foreground = false
            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
            NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: scene)
            try await waitUntil("detachedLockSuspend") {
                model.suspended && !model.viewport.isSceneActiveForControls(routeID: routeID)
            }
            for _ in 0..<10 {
                let before = audio.texts.count
                audio.fireFinished(true)
                try await waitUntil("detachedLockedAdvance") { audio.texts.count == before + 1 || !model.speech.isActive }
                if !model.speech.isActive { break }
            }
            foreground = true
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
            try await waitUntil("detachedUnlockReady") {
                !model.suspended &&
                !model.loading &&
                !model.layoutNeedsRefresh &&
                model.viewport.isSceneActiveForControls(routeID: routeID) &&
                model.window?.id == controller.window?.id
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(!model.speech.isFollowing && model.speech.isActive && model.speech.phase == .playing)
            #expect(controller.restorableAnchor()?.rawByteOffset == detachedAnchor.rawByteOffset)
        }
    }

    private func windowContainsText(_ window: ReadingWindow, _ text: String) -> Bool {
        let prefix = String(text.prefix(14))
        guard !prefix.isEmpty else { return false }
        return window.slices.contains { slice in
            slice.lines.contains { $0.text.contains(prefix) }
        }
    }

    private func apply(_ window: ReadingWindow, _ model: ReaderViewModel, _ controller: ReaderViewController,
                       userNavigation: Bool = false) {
        model.viewport.onNextRestoreIsNavigation = false
        controller.apply(window, userNavigation: userNavigation)
        model.viewport.applied(controller)
        model.windowApplied(window.id)
    }

    private func waitUntil(_ label: String, sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Timed out waiting for \(label)", sourceLocation: sourceLocation)
    }

    private func makeMultiChapterFixtureText() -> String {
        var lines: [String] = ["Chapter 1\n"]
        for i in 1...120 { lines.append("Sentence \(i) of the synthetic speech follow fixture\n") }
        lines.append("Chapter 2\n")
        for i in 121...240 { lines.append("Sentence \(i) of the synthetic speech follow fixture\n") }
        lines.append("Chapter 3\n")
        for i in 241...360 { lines.append("Sentence \(i) of the synthetic speech follow fixture\n") }
        return lines.joined()
    }

    private func withTXTReader(
        speech: ReaderSpeechSession,
        _ check: @MainActor (ReaderViewModel, ReaderViewController, UITableView, LibraryService, LibraryBook) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TXT-SpeechFollow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Synthetic.txt")
        try (Data([0xEF, 0xBB, 0xBF]) + Data(makeMultiChapterFixtureText().utf8)).write(to: source)
        let service = LibraryService(store: try LibraryStore(root: root.appendingPathComponent("Managed")))
        let imported = try await service.prepareReadingImport(url: source, ticket: UUID(), budget: ReaderStoragePolicy.budget())
        guard case .completed(let receipt) = imported else { Issue.record("UTF-8 fixture did not import"); return }
        let model = ReaderViewModel(bookID: receipt.book.id, service: service, speech: speech)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: scene), controller = ReaderViewController()
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        host.rootViewController = controller; host.isHidden = false
        defer {
            speech.stop(restorePosition: false)
            host.isHidden = true
            host.rootViewController = nil
        }
        controller.view.frame = host.bounds; controller.view.layoutIfNeeded()
        model.viewport.attach(controller)
        controller.onAnchor = model.visibleChanged
        do {
            model.resized(390); await model.load()
            try await waitUntil("readerLoaded") { model.window != nil && !model.loading }
            let initial = try #require(model.window)
            apply(initial, model, controller)
            let table = try #require(controller.view.subviews.compactMap { $0 as? UITableView }.first)
            try await check(model, controller, table, service, receipt.book)
            if model.window != nil { _ = await model.close() }
        } catch {
            _ = await model.close()
            throw error
        }
    }

    private func withTXTUI(
        autoRead: AutoReadSession,
        speech: ReaderSpeechSession,
        _ check: @MainActor (ReaderViewModel, UUID, UIWindowScene) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TXT-SpeechFollowUI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Synthetic.txt")
        try (Data([0xEF, 0xBB, 0xBF]) + Data(makeMultiChapterFixtureText().utf8)).write(to: source)
        let service = LibraryService(store: try LibraryStore(root: root.appendingPathComponent("Managed")))
        let imported = try await service.prepareReadingImport(url: source, ticket: UUID(), budget: ReaderStoragePolicy.budget())
        guard case .completed(let receipt) = imported else { Issue.record("Synthetic TXT fixture did not import"); return }
        let routeID = UUID()
        let model = ReaderViewModel(bookID: receipt.book.id, service: service, autoRead: autoRead, speech: speech)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let host = UIWindow(windowScene: scene)
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        let hosting = UIHostingController(rootView: ReaderScreen(model: model, routeID: routeID) {})
        host.rootViewController = hosting
        host.isHidden = false
        defer {
            autoRead.stop()
            speech.stop(restorePosition: false)
            host.isHidden = true
            host.rootViewController = nil
        }
        try await waitUntil("txtSpeechFollowInitialReady") {
            model.window != nil &&
            !model.loading &&
            !model.layoutNeedsRefresh &&
            model.viewport.isSceneActiveForControls(routeID: routeID) &&
            model.autoReadingAvailable &&
            model.speechAvailable
        }
        try await check(model, routeID, scene)
        if model.window != nil { _ = await model.close() }
    }
}

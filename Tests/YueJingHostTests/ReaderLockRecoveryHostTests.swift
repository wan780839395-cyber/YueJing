import Foundation
import ReaderDomain
import SwiftUI
import Testing
import UIKit
@testable import YueJing

@MainActor
@Suite(.serialized)
struct ReaderLockRecoveryHostTests {
    private final class MockSpeechAudio: ReaderSpeechAudio {
        var texts: [String] = []
        var finish: (@MainActor (Bool) -> Void)?
        var silenceCalls = 0

        func speak(_ text: String, multiplier: Float, started: @escaping @MainActor () -> Void,
                   ended: @escaping @MainActor (Bool) -> Void) throws {
            texts.append(text)
            finish = ended
            started()
        }

        func silence() {
            silenceCalls += 1
            finish = nil
        }
    }

    @Test func txtSpeechBackgroundPlaybackAndUnlockReadinessRecovery() async throws {
        var foreground = true
        let audio = MockSpeechAudio()
        let speech = ReaderSpeechSession(audio: audio, foreground: { foreground })
        let autoRead = AutoReadSession()
        try await withTXTUI(autoRead: autoRead, speech: speech) { model, routeID, scene in
            model.startSpeech()
            try await waitUntil("txtSpeechStart") { model.speech.isActive && !audio.texts.isEmpty }

            foreground = false
            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
            NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: scene)
            try await waitUntil("txtSpeechSuspend") { model.suspended && !model.viewport.isSceneActiveForControls(routeID: routeID) }
            #expect(model.speech.isActive)
            #expect(!model.autoRead.isRunning)

            try await finishBookWhileSuspended(audio, speech: model.speech)

            foreground = true
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
            model.speech.restoreWhenVisible()
            try await waitUntil("txtSpeechResume") {
                !model.suspended &&
                model.viewport.isSceneActiveForControls(routeID: routeID) &&
                model.autoReadingAvailable
            }
            #expect(!model.autoRead.isRunning)
            #expect(model.window != nil)
        }
    }

    @Test func txtAutoReadLockRecoveryAndRejectionGates() async throws {
        let audio = MockSpeechAudio()
        let speech = ReaderSpeechSession(audio: audio, foreground: { true })
        let autoRead = AutoReadSession()
        try await withTXTUI(autoRead: autoRead, speech: speech) { model, routeID, scene in
            var publishedChanges = 0
            let observation = model.objectWillChange.sink { _ in publishedChanges += 1 }
            defer { observation.cancel() }

            // 1) Auto-read NOT started before lock -> recovers availability on unlock without auto-starting.
            try #require(model.autoReadingAvailable && model.viewport.isSceneActiveForControls(routeID: routeID))
            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
            try await waitUntil("txtAutoReadIdleSuspend") { model.suspended && !model.viewport.isSceneActiveForControls(routeID: routeID) }
            #expect(!model.autoReadingAvailable)

            let beforeUnlock = publishedChanges
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
            try await waitUntil("txtAutoReadIdleResume") {
                !model.suspended &&
                model.viewport.isSceneActiveForControls(routeID: routeID) &&
                model.autoReadingAvailable
            }
            #expect(publishedChanges > beforeUnlock)
            #expect(!model.autoRead.isRunning)

            // 2) Auto-read STARTED before lock -> stops on lock, recovers button availability on unlock, never auto-starts.
            model.startAutoReading()
            try await waitUntil("txtAutoReadRunning") { model.autoRead.isRunning }
            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
            try await waitUntil("txtAutoReadSuspend") { model.suspended && !model.autoRead.isRunning }
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
            try await waitUntil("txtAutoReadResume") {
                !model.suspended &&
                model.viewport.isSceneActiveForControls(routeID: routeID) &&
                model.autoReadingAvailable
            }
            #expect(!model.autoRead.isRunning)

            // 3) Stale routeID and closing reject scene/auto-read readiness.
            #expect(!model.viewport.isSceneActiveForControls(routeID: UUID()))
            #expect(await model.close())
            #expect(!model.autoReadingAvailable)
        }
    }

    private func finishBookWhileSuspended(_ audio: MockSpeechAudio, speech: ReaderSpeechSession) async throws {
        let initial = audio.texts.count
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while speech.isActive && ContinuousClock.now < deadline {
            let finish = audio.finish
            audio.finish = nil
            finish?(true)
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(!speech.isActive && speech.notice == nil)
        #expect(audio.texts.count > initial)
    }

    @Test func epubSpeechBackgroundPlaybackAndUnlockReadinessRecovery() async throws {
        var foreground = true
        let audio = MockSpeechAudio()
        let speech = ReaderSpeechSession(audio: audio, foreground: { foreground })
        let autoRead = AutoReadSession()
        try await withEPUBUI(autoRead: autoRead, speech: speech) { model, routeID, scene in
            model.startSpeech()
            try await waitUntil("epubSpeechStart", diagnostics: { epubDiagnostics(model, routeID: routeID, scene: scene) }) { model.speech.isActive && !audio.texts.isEmpty }
            #expect(model.speech.notice == nil && model.message == nil)

            foreground = false
            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
            NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: scene)
            try await waitUntil("epubSpeechSuspend", diagnostics: { epubDiagnostics(model, routeID: routeID, scene: scene) }) { model.suspended && !model.webView.isSceneActiveForControls(routeID: routeID) }
            #expect(model.speech.isActive)
            #expect(!model.autoRead.isRunning)

            try await finishBookWhileSuspended(audio, speech: model.speech)

            foreground = true
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
            model.speech.restoreWhenVisible()
            try await waitUntil("epubSpeechResume", diagnostics: { epubDiagnostics(model, routeID: routeID, scene: scene) }) {
                !model.suspended &&
                model.webView.isSceneActiveForControls(routeID: routeID) &&
                model.presentationToken != nil &&
                model.autoReadOwner != nil
            }
            #expect(!model.autoRead.isRunning)
            #expect(model.ready)
            #expect(model.message == nil && model.speech.notice == nil)
        }
    }

    @Test func epubAutoReadLockRecoveryAndRejectionGates() async throws {
        let audio = MockSpeechAudio()
        let speech = ReaderSpeechSession(audio: audio, foreground: { true })
        let autoRead = AutoReadSession()
        try await withEPUBUI(autoRead: autoRead, speech: speech) { model, routeID, scene in
            var publishedChanges = 0
            let observation = model.objectWillChange.sink { _ in publishedChanges += 1 }
            defer { observation.cancel() }

            // 1) Auto-read NOT started before lock -> quick lock/unlock serializes and recovers readiness without auto-starting.
            try #require(model.presentationToken != nil && model.autoReadOwner != nil)
            try #require(model.webView.isSceneActiveForControls(routeID: routeID))
            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
            try await waitUntil("epubAutoReadQuickLockUnlock", diagnostics: { epubDiagnostics(model, routeID: routeID, scene: scene) }) {
                model.webView.modelSceneTask == nil &&
                !model.suspended &&
                model.webView.isSceneActiveForControls(routeID: routeID) &&
                model.presentationToken != nil &&
                model.autoReadOwner != nil
            }
            #expect(publishedChanges > 0)
            #expect(!model.autoRead.isRunning)
            #expect(model.message == nil)

            // 2) Auto-read STARTED before lock -> stops on lock, recovers availability on unlock, never auto-starts.
            try #require(model.startAutoRead())
            try await waitUntil("epubAutoReadRunning", diagnostics: { epubDiagnostics(model, routeID: routeID, scene: scene) }) { model.autoRead.isRunning }
            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
            try await waitUntil("epubAutoReadSuspend", diagnostics: { epubDiagnostics(model, routeID: routeID, scene: scene) }) { model.suspended && !model.autoRead.isRunning }
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
            try await waitUntil("epubAutoReadResume", diagnostics: { epubDiagnostics(model, routeID: routeID, scene: scene) }) {
                !model.suspended &&
                model.webView.isSceneActiveForControls(routeID: routeID) &&
                model.presentationToken != nil &&
                model.autoReadOwner != nil
            }
            #expect(!model.autoRead.isRunning)
            #expect(model.message == nil && model.debugFirstBackgroundFailure == nil)

            let cancelledFlush = Task { @MainActor in await model.flush() }
            cancelledFlush.cancel()
            await cancelledFlush.value
            #expect(model.message == nil && model.autoReadOwner != nil)

            // 3) Stale routeID and close reject readiness.
            #expect(!model.webView.isSceneActiveForControls(routeID: UUID()))
            #expect(await model.close())
            #expect(model.presentationToken == nil && model.autoReadOwner == nil)
        }
    }

    private func waitUntil(
        _ label: String,
        diagnostics: @MainActor () -> String = { "" },
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        let ok = condition()
        let summary = ok ? "" : {
            let details = diagnostics()
            let text = details.isEmpty ? label : "\(label): \(details)"
            print("LOCK_RECOVERY_WAIT_TIMEOUT \(text) line=\(sourceLocation.line)")
            return text
        }()
        try #require(ok, "\(summary)", sourceLocation: sourceLocation)
    }

    private func epubDiagnostics(_ model: EPUBReaderViewModel, routeID: UUID, scene: UIWindowScene) -> String {
        let controller = model.webView.controller
        let hasWindow = controller?.viewIfLoaded?.window != nil
        let boundSceneState = controller?.viewIfLoaded?.window?.windowScene?.activationState.rawValue ?? -1
        return [
            "ready=\(model.ready)",
            "loading=\(model.loading)",
            "suspended=\(model.suspended)",
            "suspending=\(model.suspending)",
            "closing=\(model.closing)",
            "req=\(model.navigationRequest != nil)",
            "curTok=\(model.currentToken != nil)",
            "origin=\(model.documentOrigin != nil)",
            "presTok=\(model.presentationToken != nil)",
            "autoOwner=\(model.autoReadOwner != nil)",
            "autoRun=\(model.autoRead.isRunning)",
            "speechActive=\(model.speech.isActive)",
            "hasMessage=\(model.message != nil)",
            "sceneActive=\(model.webView.isSceneActiveForControls(routeID: routeID))",
            "interActive=\(model.webView.interactionActive)",
            "sceneTask=\(model.webView.modelSceneTask != nil)",
            "sceneState=\(scene.activationState.rawValue)",
            "ctrl=\(controller != nil)",
            "ctrlWin=\(hasWindow)",
            "ctrlSceneState=\(boundSceneState)",
            "hasReadinessFailure=\(controller?.lastReadinessFailure != nil)",
            "msgCode=\(model.debugMessageCode)",
            "speechNotice=\(model.debugSpeechNoticeCode)",
            "speechCap=\(model.debugSpeechCaptureOutcome)",
            "sampleCap=\(controller?.debugSpeechSampleOutcome ?? "none")",
            "bgFail=\(model.debugFirstBackgroundFailure ?? "none")"
        ].joined(separator: " ")
    }

    private func withTXTUI(autoRead: AutoReadSession, speech: ReaderSpeechSession,
                           _ check: @MainActor (ReaderViewModel, UUID, UIWindowScene) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TXT-LockUI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Synthetic.txt")
        let text = "Chapter 1\n" + (1...120).map { "Line \($0) of synthetic lock recovery content.\n" }.joined()
        try (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: source)
        let service = LibraryService(store: try LibraryStore(root: root.appendingPathComponent("Managed")))
        let imported = try await service.prepareReadingImport(url: source, ticket: UUID(), budget: ReaderStoragePolicy.budget())
        guard case .completed(let receipt) = imported else {
            Issue.record("Synthetic TXT fixture did not import")
            return
        }
        let routeID = UUID()
        let model = ReaderViewModel(bookID: receipt.book.id, service: service, autoRead: autoRead, speech: speech)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let host = UIWindow(windowScene: scene)
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        let controller = UIHostingController(rootView: ReaderScreen(model: model, routeID: routeID) {})
        host.rootViewController = controller
        host.isHidden = false
        defer {
            autoRead.stop()
            speech.stop(restorePosition: false)
            host.isHidden = true
            host.rootViewController = nil
        }
        try await waitUntil("txtInitialReady") {
            model.window != nil &&
            !model.loading &&
            model.viewport.isSceneActiveForControls(routeID: routeID) &&
            model.autoReadingAvailable
        }
        try await check(model, routeID, scene)
        if model.window != nil { _ = await model.close() }
    }

    private func withEPUBUI(autoRead: AutoReadSession, speech: ReaderSpeechSession,
                            _ check: @MainActor (EPUBReaderViewModel, UUID, UIWindowScene) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EPUB-LockUI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryService(store: try LibraryStore(root: root.appendingPathComponent("Managed")))
        let source = root.appendingPathComponent("Synthetic.epub")
        try EPUBUITestFixture.writeIllustratedEPUB(to: source)
        let imported = try await service.prepareReadingImport(url: source, ticket: UUID(), budget: ReaderStoragePolicy.budget())
        guard case .completed(let receipt) = imported else {
            Issue.record("Synthetic EPUB fixture did not import")
            return
        }
        let routeID = UUID()
        let model = EPUBReaderViewModel(bookID: receipt.book.id, service: service, readingMode: .scroll,
                                        layoutMode: .reader, autoRead: autoRead, speech: speech)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let host = UIWindow(windowScene: scene)
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        let controller = UIHostingController(rootView: EPUBReaderScreen(model: model, routeID: routeID) {})
        host.rootViewController = controller
        host.isHidden = false
        defer {
            autoRead.stop()
            speech.stop(restorePosition: false)
            host.isHidden = true
            host.rootViewController = nil
        }
        try await waitUntil("epubInitialReady", diagnostics: { epubDiagnostics(model, routeID: routeID, scene: scene) }) {
            model.ready &&
            !model.loading &&
            model.presentationToken != nil &&
            model.autoReadOwner != nil &&
            model.webView.isSceneActiveForControls(routeID: routeID)
        }
        try await check(model, routeID, scene)
        if model.reader != nil { _ = await model.close() }
    }
}

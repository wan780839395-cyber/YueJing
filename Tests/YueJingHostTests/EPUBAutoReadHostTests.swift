import Foundation
import ReaderDomain
import Testing
import UIKit
import WebKit
@testable import YueJing

@MainActor
@Suite(.serialized)
struct EPUBAutoReadHostTests {
    @Test func epubAutoReadAdvancesAcrossResidentChaptersAndStopsAtBookEnd() async throws {
        for layout in EPUBLayoutMode.allCases {
            for mode in EPUBReadingMode.allCases {
                try await withBook { service, id in
                    try await withReader(service, id, mode, layout) { model, controller in
                        let owner = try #require(model.autoReadOwner)
                        let first = try #require(model.presentationToken)
                        try #require(controller.beginAutoRead(for: first))
                        let scroll = controller.webView.scrollView
                        var checkedHandoff = false
                        controller.onLocatorEvent = { payload in
                            model.handleLocatorEvent(payload)
                            if model.promotingVisibleChapter {
                                checkedHandoff = true
                                let frozen = scroll.contentOffset
                                #expect(model.autoReadStep(from: owner, distance: 1) == .waiting)
                                #expect(scroll.contentOffset == frozen)
                            }
                        }
                        let before = scroll.contentOffset
                        let firstStep = model.autoReadStep(from: owner, distance: mode == .paged ? 0 : 3)
                        try #require(firstStep == .advanced)
                        if mode == .paged {
                            #expect(abs(scroll.contentOffset.x - before.x - scroll.bounds.width) < 1)
                        } else {
                            #expect(abs(scroll.contentOffset.y - before.y - 3) < 1)
                        }
                        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
                        var step = firstStep
                        while step != .stop && ContinuousClock.now < deadline {
                            // Let the real WebKit scroll observer and epoch handoff run.
                            try await Task.sleep(for: .milliseconds(120))
                            step = model.autoReadStep(from: owner, distance: mode == .paged ? 0 : 400)
                        }
                        try #require(step == .stop)
                        try await until { model.ready && model.currentPosition?.path == model.spine.last }
                        #expect(model.autoReadOwner == owner && model.presentationToken != first)
                        #expect(checkedHandoff)
                        #expect(controller.documentLoadCount == 1)
                        let end = scroll.contentOffset
                        #expect(model.autoReadStep(from: owner, distance: 1) == .stop)
                        #expect(scroll.contentOffset == end)
                        #expect(await model.close())
                    }
                }
            }
        }
    }

    @Test func epubAutoReadEdgeTouchPausesWithoutTurningAndReopensAtConfirmedAnchor() async throws {
        try await withBook { service, id in
            var confirmed: EPUBReadingPosition?
            var oldOwner: EPUBNavigationToken?
            try await withReader(service, id, .paged, .reader) { model, controller in
                let owner = try #require(model.autoReadOwner)
                oldOwner = owner
                let token = try #require(model.presentationToken)
                let scroll = controller.webView.scrollView
                let edge = CGPoint(x: scroll.bounds.width * 0.95, y: scroll.bounds.midY)
                // A manual edge hit-test that hasn't replied must not turn after start.
                controller.handleViewportTap(at: edge)
                try #require(controller.beginAutoRead(for: token))
                try #require(model.autoReadStep(from: owner, distance: 0) == .advanced)
                let pausedOffset = scroll.contentOffset
                let session = AutoReadSession()
                session.start(mode: .paged) { model.autoReadStep(from: owner, distance: $0) }
                let shield = EPUBAutoReadPauseSurface.Surface(frame: controller.view.bounds)
                shield.pause = session.stop
                controller.view.addSubview(shield)
                #expect(controller.view.hitTest(edge, with: nil) === shield)
                shield.touchesBegan([], with: nil)
                shield.removeFromSuperview()
                #expect(!session.isRunning)
                try await until {
                    guard model.ready, let payload = model.webView.latestPayload,
                          payload.epoch == token.epoch, payload.kind == .scroll else { return false }
                    return abs(payload.scrollX - Double(pausedOffset.x)) < 1
                }
                await model.flush()
                #expect(scroll.contentOffset == pausedOffset)
                let sample = try #require(await controller.sampleVisibleNow())
                confirmed = try #require(model.currentPosition)
                #expect(confirmed?.path == sample.path && confirmed?.node == sample.node && confirmed?.utf16Offset == sample.utf16Offset)
                #expect(await model.close())
            }
            try await withReader(service, id, .paged, .reader) { model, controller in
                #expect(model.navigationRequest?.targetPosition == confirmed)
                #expect(model.currentPosition == confirmed)
                let old = try #require(oldOwner)
                let offset = controller.webView.scrollView.contentOffset
                #expect(model.autoReadStep(from: old, distance: 0) == .stop)
                #expect(controller.webView.scrollView.contentOffset == offset)
                #expect(await model.close())
            }
        }
    }

    @Test func epubAutoReadRejectsOldOwnerDuringAndAfterExplicitNavigation() async throws {
        try await withBook { service, id in
            try await withReader(service, id, .scroll, .original) { model, controller in
                let owner = try #require(model.autoReadOwner)
                let old = try #require(model.presentationToken)
                let path = try #require(model.spine.last)
                model.navigateExplicitly(path: path, fragment: nil, target: nil)
                #expect(model.autoReadStep(from: owner, distance: 4) == .stop)
                try await until { model.ready && model.presentationToken?.path == path }
                let offset = controller.webView.scrollView.contentOffset
                #expect(controller.autoReadStep(for: old, distance: 4) == .stop)
                #expect(model.autoReadStep(from: owner, distance: 4) == .stop)
                #expect(controller.webView.scrollView.contentOffset == offset)
                let current = try #require(model.autoReadOwner)
                await model.suspend()
                #expect(model.autoReadStep(from: current, distance: 4) == .stop)
                await model.resume()
                try await until { model.presentationToken != nil }
                #expect(model.autoReadStep(from: current, distance: 4) == .stop)
                let live = try #require(model.presentationToken)
                model.handleLoadFailure(EPUBError.invalidPosition, token: live)
                #expect(model.autoReadOwner == nil)
                #expect(await model.close())
            }
        }
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }

    private func withBook(_ body: @MainActor (LibraryService, String) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = LibraryService(store: try LibraryStore(root: root.appendingPathComponent("Managed")))
        let url = root.appendingPathComponent("Synthetic.epub")
        try EPUBUITestFixture.writeIllustratedEPUB(to: url)
        let result = try await service.prepareReadingImport(url: url, ticket: UUID(), budget: ReaderStoragePolicy.budget())
        guard case .completed(let receipt) = result else { throw EPUBError.invalidPackage }
        try await body(service, receipt.book.id)
    }

    private func withReader(_ service: LibraryService, _ id: String, _ mode: EPUBReadingMode, _ layout: EPUBLayoutMode,
                            _ body: @MainActor (EPUBReaderViewModel, EPUBWebViewController) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        let model = EPUBReaderViewModel(bookID: id, service: service, readingMode: mode, layoutMode: layout)
        let controller = EPUBWebViewController()
        model.webView.attach(controller)
        controller.onLocatorEvent = model.handleLocatorEvent
        controller.onLoadFailure = model.handleLoadFailure
        controller.onPreloadFailure = model.handlePreloadFailure
        window.rootViewController = controller
        window.isHidden = false
        defer { controller.detachCallbacks(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        await model.load()
        try await until { model.presentationToken != nil && controller.renderedChapterPaths.count == model.spine.count }
        try await body(model, controller)
    }
}

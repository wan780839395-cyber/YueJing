import Foundation
import ReaderDomain
import SwiftUI
import Testing
import UIKit
import WebKit
import XCTest
@testable import YueJing

@MainActor
@Suite(.serialized)
struct EPUBReaderHostTests {
    @Test func epubOpeningObservationRejectsStaleFramesAndLabelsColdAdmission() throws {
        let start = ContinuousClock.now
        let token = EPUBNavigationToken(sessionID: "synthetic-opening", path: "OEBPS/ch1.xhtml")
        let stale = EPUBNavigationToken(sessionID: "synthetic-opening", path: "OEBPS/ch1.xhtml")
        var observation = EPUBOpeningObservation(intentAt: start, processOpenOrdinal: 1, rendererTaken: false)
        #expect(observation.summary.contains("本进程首次 EPUB 开书"))
        #expect(observation.summary.contains("未取得"))
        let frameBeforeReady = observation.observedFrame(token, at: start)
        #expect(!frameBeforeReady)
        observation.beganLoading(at: start.advanced(by: .milliseconds(2)))
        observation.becameReady(token, at: start.advanced(by: .milliseconds(362)))
        let staleFrame = observation.observedFrame(stale, at: start.advanced(by: .milliseconds(380)))
        #expect(!staleFrame)
        let frameBeforeReadyTime = observation.observedFrame(token, at: start.advanced(by: .milliseconds(300)))
        #expect(!frameBeforeReadyTime)
        let acceptedFrame = observation.observedFrame(token, at: start.advanced(by: .milliseconds(395)))
        #expect(acceptedFrame)
        let duplicateFrame = observation.observedFrame(token, at: start.advanced(by: .milliseconds(400)))
        #expect(!duplicateFrame)
        #expect(observation.summary.contains("0.395s") && observation.summary.contains("0.033s"))
        #expect(!observation.summary.contains(token.sessionID) && !observation.summary.contains(token.path))
        #expect(observation.summary.contains("不是像素首绘"))
        let completedSummary = observation.summary
        observation.interrupt(.background)
        observation.interrupt(.retry)
        #expect(observation.summary == completedSummary && observation.interruption == nil)
        for reason in [EPUBOpeningObservation.Interruption.retry, .background] {
            var interrupted = EPUBOpeningObservation(intentAt: start, processOpenOrdinal: 2, rendererTaken: true)
            interrupted.beganLoading(at: start)
            interrupted.becameReady(token, at: start)
            interrupted.interrupt(reason)
            let interruptedFrame = interrupted.observedFrame(token, at: start)
            #expect(!interruptedFrame)
            #expect(interrupted.summary.contains("不纳入正常开书耗时样本"))
        }
        let unknown = EPUBOpeningObservation(intentAt: nil, processOpenOrdinal: nil, rendererTaken: nil)
        #expect(unknown.summary.contains("未配置页面缓存") && !unknown.summary.contains("0.000s"))
        #expect(EPUBOpeningFeedback.phase(elapsedSeconds: 0.279) == .quiet)
        #expect(EPUBOpeningFeedback.phase(elapsedSeconds: 0.280) == .compact)
        #expect(EPUBOpeningFeedback.phase(elapsedSeconds: 0.999) == .compact)
        #expect(EPUBOpeningFeedback.phase(elapsedSeconds: 1) == .detailed)
        #expect(EPUBOpeningFeedback.compactDelay == .milliseconds(280))
        #expect(EPUBOpeningFeedback.detailedDelay == .seconds(1))
        let suite = "YueJing-opening-hint-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invalid-theme", forKey: EPUBPresentationThemeHint.key)
        #expect(EPUBPresentationThemeHint.read(from: defaults) == .paper)
        EPUBPresentationThemeHint.remember(.dark, in: defaults)
        #expect(EPUBPresentationThemeHint.read(from: defaults) == .dark)
    }

    @Test func epubOpeningRouteStartsOnceAndObservesMountedPresentation() async throws {
        let savedHint = UserDefaults.standard.object(forKey: EPUBPresentationThemeHint.key)
        defer {
            if let savedHint { UserDefaults.standard.set(savedHint, forKey: EPUBPresentationThemeHint.key) }
            else { UserDefaults.standard.removeObject(forKey: EPUBPresentationThemeHint.key) }
        }
        try await withHostFixture { fixture in
            let archive = fixture.root.appendingPathComponent("Opening.epub")
            try EPUBUITestFixture.writeIllustratedEPUB(to: archive, title: "Opening Synthetic")
            let receipt = try await fixture.install(archive)
            let routes = BookReadingRouteOwner()
            routes.open(book: receipt.book, service: fixture.service)
            let route = try #require(routes.presentation)
            guard case .epub(let model) = route.content else { throw EPUBError.invalidPackage }
            #expect(model.title == receipt.book.title && model.presentationToken == nil)
            let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(15))
            while model.currentToken == nil && model.loading, ContinuousClock.now < admissionDeadline {
                try await Task.sleep(for: .milliseconds(10)) // Let the route task, not this test, start first.
            }
            #expect(model.openingAttemptCount == 1)
            await model.load() // The later view entry must not open a second session.
            let token = try #require(model.currentToken)
            let host = UIHostingController(rootView: EPUBReaderScreen(model: model, routeID: route.id) {
                routes.finishExit(route.id)
            })
            do {
                try await fixture.withHostedController(host) {
                    do {
                        try await waitUntilReady(model: model, expectedToken: token)
                    } catch {
                        print("EPUB_OPENING_FAILURE ready=\(model.ready) loading=\(model.loading) request=\(model.navigationRequest != nil) message=\(String(describing: model.message))")
                        if let controller = model.webView.controller {
                            print("EPUB_OPENING_CONTROLLER active=\(controller.activeRequest != nil) loads=\(controller.documentLoadCount) window=\(controller.viewIfLoaded?.window != nil) bounds=\(controller.viewIfLoaded?.bounds ?? .zero)")
                            if controller.activeRequest == nil { print(await controller.performanceSummary()) }
                            let snapshot = XCTestExpectation(description: "Read-only failed opening snapshot")
                            controller.webView.__evaluateJavaScript(
                                "JSON.stringify({visibility:document.visibilityState,width:innerWidth,height:innerHeight,images:Array.from(document.images).map(i=>({complete:i.complete,width:i.naturalWidth})),state:window.__yjEpub ? window.__yjEpub.sampleStatus() : null,diagnostics:window.__yjEpub ? window.__yjEpub.diagnostics() : null})",
                                inFrame: nil, in: EPUBLocationScript.world
                            ) { value, snapshotError in
                                print("EPUB_OPENING_JS \(String(describing: value)) error=\(String(describing: snapshotError))")
                                snapshot.fulfill()
                            }
                            let snapshotResult = await XCTWaiter.fulfillment(of: [snapshot], timeout: 2)
                            print("EPUB_OPENING_SNAPSHOT_RESULT \(snapshotResult.rawValue)")
                        }
                        throw error // Preserve the original failure; diagnostics cannot turn it into a pass.
                    }
                    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while model.openingPresentationSummary?.contains("点击→正文揭示后的显示帧机会 未取得") != false,
                          ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(model.openingPresentationSummary?.contains("点击→正文揭示后的显示帧机会 未取得") == false)
                    #expect(model.presentationToken == token)
                    #expect(model.webView.controller?.documentLoadCount == 1)
                    let summary = model.openingPresentationSummary
                    model.recordPresentationFrame(EPUBNavigationToken(sessionID: token.sessionID, path: token.path))
                    #expect(model.openingPresentationSummary == summary)
                    await model.load()
                    #expect(model.currentToken == token)
                    #expect(model.webView.controller?.documentLoadCount == 1)
                    #expect(await model.close())
                    #expect(model.presentationToken == nil)
                    routes.finishExit(route.id)
                    #expect(routes.presentation == nil)
                }
            } catch {
                _ = await model.close()
                throw error
            }
            routes.open(bookID: "missing-synthetic-book", format: .epub, service: fixture.service)
            let failedRoute = try #require(routes.presentation)
            guard case .epub(let failed) = failedRoute.content else { throw EPUBError.invalidPackage }
            let failureDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while failed.loading, ContinuousClock.now < failureDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(!failed.loading && failed.message != nil)
            #expect(failed.openingAttemptCount == 1)
            let originalError = failed.message
            await failed.load() // Mounting after an early failure must not silently retry.
            #expect(failed.openingAttemptCount == 1 && failed.message == originalError && !failed.loading)
            await failed.retry()
            #expect(failed.openingAttemptCount == 2 && !failed.ready && !failed.loading)
            #expect(await failed.close())
            routes.finishExit(failedRoute.id)
        }
    }

    @Test func epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position() async throws {
        verifyLargeDirectorySelection()
        var trace = EPUBRuntimeTrace()
        for _ in 0..<200 { trace.record(.windowRequested) }
        #expect(trace.entries.count == 128 && trace.counts[.windowRequested] == 200)
        #expect(trace.entries.allSatisfy { $0.milliseconds.isFinite && $0.milliseconds >= 0 })
        try await withHostFixture { fixture in
            let archiveURL = fixture.root.appendingPathComponent("Illustrated.epub")
            try EPUBUITestFixture.writeIllustratedEPUB(to: archiveURL, title: "Host Illustrated")
            let receipt = try await fixture.install(archiveURL)
            let reader = try await fixture.service.openEPUB(id: receipt.book.id)
            let path = try #require(reader.publication.package.spine.first)
            let token = try await reader.beginNavigation(path: path)
            verifyReadinessDeadline(publication: reader.publication, token: token, preferences: reader.preferences)

            let sampleText = "A😀e\u{301}尾"
            #expect(EPUBLocationScript.snapUTF16OffsetToCharacterBoundary(-1, in: sampleText) == nil)
            #expect(EPUBLocationScript.snapUTF16OffsetToCharacterBoundary(999, in: sampleText) == nil)
            // Surrogate pair interior (offset 2 inside 😀 at UTF-16 1..<3) snaps to 1.
            #expect(EPUBLocationScript.snapUTF16OffsetToCharacterBoundary(2, in: sampleText) == 1)
            // Combining acute interior (offset 4 inside e\u{301} at UTF-16 3..<5) snaps to 3.
            #expect(EPUBLocationScript.snapUTF16OffsetToCharacterBoundary(4, in: sampleText) == 3)

            let controller = EPUBWebViewController()
            // Match SwiftUI's makeUIViewController: theme arrives before UIKit hosts the view.
            #expect(!controller.isViewLoaded)
            controller.applyTheme(reader.preferences.theme)
            let installedWebView = try #require(controller.webView)
            #expect(controller.view.subviews.compactMap { $0 as? WKWebView }.count == 1)
            controller.setupWebViewIfNeeded()
            controller.applyTheme(reader.preferences.theme)
            #expect(controller.webView === installedWebView)
            #expect(controller.view.subviews.compactMap { $0 as? WKWebView }.count == 1)
            try await fixture.withHostedController(controller) {
                #expect(controller.webView === installedWebView)
                #expect(controller.view.subviews.compactMap { $0 as? WKWebView }.count == 1)
                let firstPayload = try await loadAndAwaitReady(
                    controller: controller,
                    request: EPUBNavigationRequest(
                        id: UUID(),
                        token: token,
                        publication: reader.publication,
                        targetPosition: nil,
                        fragment: nil,
                        preferences: reader.preferences,
                        preserveTargetAnchor: false,
                        reloadDocument: true
                    )
                )
                #expect(firstPayload.kind == .ready)
                #expect(firstPayload.sessionID == reader.reading.session.id)
                #expect(firstPayload.epoch == token.epoch)
                #expect(firstPayload.path == path)
                #expect(firstPayload.visibleText.contains("EPUB_CH1_START"))
                #expect(controller.resourceHandler.servedPaths.contains(path))
                #expect(controller.resourceHandler.servedPaths.contains("OEBPS/images/cover.png"))
                #expect(controller.webView.scrollView.pinchGestureRecognizer?.isEnabled != true)
                #expect(controller.webView.scrollView.zoomScale == 1)
                let performance = await controller.performanceSummary()
                #expect(performance.contains("documentLoad") && performance.contains("locatorReady"))
                #expect(performance.contains("sampleCount") && !performance.contains("OEBPS/"))
                #expect(!performance.contains("EPUB_CH1_START"))
                let domSummary = try await controller.evaluateLocatorJavaScriptForTesting(
                    """
                    (function() {
                        var img = document.querySelector('img');
                        return {
                            h1: document.querySelectorAll('h1').length,
                            em: document.querySelectorAll('em').length,
                            strong: document.querySelectorAll('strong').length,
                            li: document.querySelectorAll('li').length,
                            imgLoaded: Boolean(img && img.complete && img.naturalWidth > 0)
                        };
                    })();
                    """
                ) as? [String: Any]
                #expect((domSummary?["h1"] as? Int ?? 0) >= 1)
                #expect((domSummary?["em"] as? Int ?? 0) >= 1)
                #expect((domSummary?["strong"] as? Int ?? 0) >= 1)
                #expect((domSummary?["li"] as? Int ?? 0) >= 2)
                #expect(domSummary?["imgLoaded"] as? Bool == true)
                controller.expireReadiness(for: token)
                #expect(controller.activeRequest?.token == token) // Ready content never expires.
                try await verifyViewportWhitespaceTap(controller)

                #expect(try await reader.markReady(token))
                let nodes = try #require(try reader.publication.package.nodes(at: path))
                let targetNode = try #require(nodes.firstIndex(where: { $0.contains("EPUB_A_C1_P18") }))
                let targetPosition = try EPUBLocationScript.makeValidatedPosition(
                    bookID: receipt.book.id,
                    package: reader.publication.package,
                    path: path,
                    node: targetNode,
                    rawUTF16Offset: 0
                )
                #expect(try await reader.save(targetPosition, sequence: 1, token: token))
                try await reader.close(position: targetPosition, sequence: 2, token: token, preferences: reader.preferences)
            }

            let reopened = try await fixture.service.openEPUB(id: receipt.book.id)
            let saved = try #require(reopened.reading.position)
            #expect(saved.path == path && saved.node > 5)
            let reopenToken = try await reopened.beginNavigation(path: saved.path)
            let reopenController = EPUBWebViewController()
            try await fixture.withHostedController(reopenController) {
                let restoredPayload = try await loadAndAwaitReady(
                    controller: reopenController,
                    request: EPUBNavigationRequest(
                        id: UUID(),
                        token: reopenToken,
                        publication: reopened.publication,
                        targetPosition: saved,
                        fragment: nil,
                        preferences: reopened.preferences,
                        preserveTargetAnchor: true,
                        reloadDocument: true
                    )
                )
                #expect(restoredPayload.restoredNode == saved.node)
                #expect(restoredPayload.restoredOffset == saved.utf16Offset)
                #expect(restoredPayload.scrollY > 50)
                #expect(restoredPayload.visibleText.contains("EPUB_A_C1_P18"))
                #expect(reopenController.webView.scrollView.pinchGestureRecognizer?.isEnabled != true)
                #expect(reopenController.webView.scrollView.zoomScale == 1)
            }
            try await reopened.close(position: saved, sequence: 1, token: reopenToken, preferences: reopened.preferences)
        }
        try await verifySameBookWarmRenderer()
    }

    @Test func epubSecurityRejectsScriptsFormsExternalResourcesAndKeepsIsolatedLocatorWorking() async throws {
        try await withHostFixture { fixture in
            let scriptedURL = fixture.root.appendingPathComponent("Scripted.epub")
            try EPUBUITestFixture.writeCustomXHTMLEPUB(
                to: scriptedURL,
                title: "Scripted EPUB",
                bodyXHTML: """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml">
                  <head><title>Bad</title><script>window.__evil = 1;</script></head>
                  <body><p>Should be rejected at import</p></body>
                </html>
                """
            )
            await #expect(throws: EPUBError.unsupportedContent) {
                _ = try await fixture.install(scriptedURL)
            }
            #expect(try await fixture.store.books().isEmpty)
            let formURL = fixture.root.appendingPathComponent("Form.epub")
            try EPUBUITestFixture.writeCustomXHTMLEPUB(to: formURL, title: "Form EPUB",
                bodyXHTML: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Form</title></head><body><form action=\"https://example.com/\"><input/></form><p>Reject</p></body></html>")
            await #expect(throws: EPUBError.unsupportedContent) { _ = try await fixture.install(formURL) }
            #expect(try await fixture.store.books().isEmpty)

            let validURL = fixture.root.appendingPathComponent("ValidForSecurity.epub")
            try EPUBUITestFixture.writeIllustratedEPUB(to: validURL, title: "Security Host Book")
            let receipt = try await fixture.install(validURL)
            let reader = try await fixture.service.openEPUB(id: receipt.book.id)
            let path = try #require(reader.publication.package.spine.first)
            let token = try await reader.beginNavigation(path: path)
            let nodes = try #require(try reader.publication.package.nodes(at: path))

            // Construct a raw hostile XHTML payload matching the expected yj-tN text nodes,
            // plus inline scripts, event handlers, and an external network image to test WebKit controls directly.
            let spansMarkup = nodes.enumerated().map { idx, text in
                "<p><span id=\"yj-t\(idx)\">\(EPUBContentPolicy.escapeXMLText(text))</span></p>"
            }.joined(separator: "\n")
            let hostileXHTML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head>
                <title>Hostile Override</title>
                <script>window.__publicationScriptExecuted = "yes";</script>
              </head>
              <body onload="window.__onloadExecuted = 'yes'">
                <img id="ext-probe" src="https://example.com/evil.png" onerror="window.__onerrorExecuted = 'yes'"/>
                \(spansMarkup)
              </body>
            </html>
            """

            let controller = EPUBWebViewController()
            controller.resourceHandler.rawXHTMLOverrideForTesting[path] = Data(hostileXHTML.utf8)
            try await fixture.withHostedController(controller) {
                let payload = try await loadAndAwaitReady(
                    controller: controller,
                    request: EPUBNavigationRequest(
                        id: UUID(),
                        token: token,
                        publication: reader.publication,
                        targetPosition: nil,
                        fragment: nil,
                        preferences: reader.preferences,
                        preserveTargetAnchor: false,
                        reloadDocument: true
                    )
                )
                #expect(controller.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
                #expect(payload.kind == .ready)
                #expect(payload.epoch == token.epoch)
                #expect(payload.visibleText.contains("EPUB_CH1_START"))

                let check = try await controller.evaluateLocatorJavaScriptForTesting(
                    """
                    (function() {
                        var ext = document.getElementById('ext-probe');
                        return {
                            locatorInstalled: Boolean(window.__yjEpubInstalled),
                            extWidth: ext ? (ext.naturalWidth || 0) : -1
                        };
                    })();
                    """
                ) as? [String: Any]
                #expect(check?["locatorInstalled"] as? Bool == true)
                #expect((check?["extWidth"] as? Int ?? -1) == 0)

                let pageGlobals = try await controller.evaluatePageJavaScriptForTesting(
                    "Boolean(window.__publicationScriptExecuted || window.__onloadExecuted || window.__onerrorExecuted)"
                ) as? Bool
                #expect(pageGlobals == false)

                // Verify navigation policy denies external HTTP, file://, wrong epoch host, and unscheduled spine chapter.
                for forbidden in [
                    "https://example.com/outside",
                    "file:///etc/passwd",
                    "yjepub://wrong-host/OEBPS/text/ch1.xhtml",
                    "yjepub://\(EPUBResourceCapability.host(for: token))/OEBPS/text/ch2.xhtml"
                ] {
                    let url = try #require(URL(string: forbidden))
                    controller.webView.load(URLRequest(url: url))
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while !controller.deniedNavigations.contains(url.absoluteString), ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(controller.deniedNavigations.contains(url.absoluteString))
                }
                #expect(controller.deniedNavigations.count >= 4)
            }
            try await reader.close(position: nil, sequence: 1, token: nil, preferences: reader.preferences)
        }
    }

    @Test func epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks() async throws {
        try await withHostFixture { fixture in
            let archiveURL = fixture.root.appendingPathComponent("Reflow.epub")
            try EPUBUITestFixture.writeIllustratedEPUB(to: archiveURL, title: "Host Reflow")
            let receipt = try await fixture.install(archiveURL)

            let model = EPUBReaderViewModel(bookID: receipt.book.id, service: fixture.service)
            let controller = EPUBWebViewController()
            model.webView.attach(controller)
            controller.onLocatorEvent = { [weak model] payload in
                print("EPUB_SYNTHETIC_REFLOW_EVENT kind=\(payload.kind) path=\(payload.path) node=\(payload.node) restored=\(payload.restoredNode) epoch=\(payload.epoch) current=\(String(describing: model?.currentToken)) ready=\(model?.ready ?? false)")
                model?.handleLocatorEvent(payload)
            }
            controller.onLoadFailure = { [weak model] error, token in model?.handleLoadFailure(error, token: token) }
            controller.onInternalLink = { [weak model] path, fragment in model?.navigateToInternalLink(path: path, fragment: fragment) }

            try await fixture.withHostedController(controller) {
                await model.load()
                let initialRequest = try #require(model.navigationRequest)
                controller.apply(initialRequest)
                try await waitUntilReady(model: model, expectedToken: initialRequest.token)

                let firstToken = try #require(model.currentToken)
                let package = try #require(model.reader?.publication.package)
                let ch1Nodes = try #require(try package.nodes(at: firstToken.path))
                let anchorNode = try #require(ch1Nodes.firstIndex(where: { $0.contains("EPUB_A_C1_P20") }))
                let scrolledPayload = EPUBLocatorPayload(
                    kind: .scroll,
                    sessionID: firstToken.sessionID,
                    epoch: firstToken.epoch,
                    path: firstToken.path,
                    node: anchorNode,
                    utf16Offset: 4,
                    restoredNode: anchorNode,
                    restoredOffset: 4,
                    scrollY: 420,
                    viewportHeight: 700,
                    contentHeight: 2400,
                    visibleText: ch1Nodes[anchorNode],
                    reason: nil
                )
                model.handleLocatorEvent(scrolledPayload)
                let savedAnchor = try #require(model.currentPosition)
                #expect(savedAnchor.node == anchorNode && savedAnchor.utf16Offset == 4)
                let loadsBeforeReflow = controller.documentLoadCount

                // Apply typography + dark theme change, minting a new navigation epoch.
                model.preferences = ReaderPreferences(fontSize: 28, lineSpacing: 14, theme: .dark)
                model.settingsChanged()
                try await waitForNewToken(model: model, previous: firstToken)
                let reflowRequest = try #require(model.navigationRequest)
                let reflowToken = reflowRequest.token
                #expect(reflowToken.epoch != firstToken.epoch)
                #expect(!model.loading, "In-place typography must not dismiss the active settings panel")

                // Stale callback from the old epoch (attempting to reset to node 0) must be ignored.
                let stalePayload = EPUBLocatorPayload(
                    kind: .scroll,
                    sessionID: firstToken.sessionID,
                    epoch: firstToken.epoch,
                    path: firstToken.path,
                    node: 0,
                    utf16Offset: 0,
                    restoredNode: 0,
                    restoredOffset: 0,
                    scrollY: 0,
                    viewportHeight: 700,
                    contentHeight: 2400,
                    visibleText: "stale",
                    reason: nil
                )
                model.handleLocatorEvent(stalePayload)
                #expect(model.currentPosition == savedAnchor)

                controller.apply(reflowRequest)
                try await waitUntilReady(model: model, expectedToken: reflowToken)
                #expect(model.currentPosition == savedAnchor)
                let fontStyle = try await controller.evaluateLocatorJavaScriptForTesting(
                    "window.getComputedStyle(document.body).fontSize"
                ) as? String
                #expect(fontStyle == "28px")
                #expect(controller.documentLoadCount == loadsBeforeReflow)
                controller.apply(reflowRequest)
                #expect(controller.documentLoadCount == loadsBeforeReflow)
                model.settingsChanged()
                #expect(model.navigationRequest == reflowRequest)

                // Navigate to Chapter 2 mid-section fragment via TOC item and gate old reflowToken callbacks.
                let ch2MidItem = try #require(model.navigationItems.first(where: { $0.fragment == "sec-mid" }))
                model.go(to: ch2MidItem)
                try await waitForNewToken(model: model, previous: reflowToken)
                let ch2Request = try #require(model.navigationRequest)
                #expect(ch2Request.fragment == "sec-mid")
                #expect(ch2Request.targetPosition == nil)
                #expect(!ch2Request.preserveViewport)
                print("EPUB_SYNTHETIC_FRAGMENT_REQUEST mode=\(ch2Request.readingMode.rawValue) fragment=\(ch2Request.fragment ?? "none") loads=\(controller.documentLoadCount)")
                model.handleLocatorEvent(
                    EPUBLocatorPayload(
                        kind: .scroll,
                        sessionID: reflowToken.sessionID,
                        epoch: reflowToken.epoch,
                        path: reflowToken.path,
                        node: 0,
                        utf16Offset: 0,
                        restoredNode: 0,
                        restoredOffset: 0,
                        scrollY: 0,
                        viewportHeight: 700,
                        contentHeight: 2400,
                        visibleText: "stale-reflow",
                        reason: nil
                    )
                )
                controller.apply(ch2Request)
                do {
                    try await waitUntilReady(model: model, expectedToken: ch2Request.token, minimumNode: 6)
                } catch {
                    if error is CancellationError || Task.isCancelled { throw error }
                    // Read-only synthetic-fixture evidence after the original assertion fails.
                    // Do not navigate again, extend its deadline, or substitute this sample for readiness.
                    let geometry = try? await controller.evaluateLocatorJavaScriptForTesting("""
                    (function() {
                        var chapter = document.querySelector('[data-yj-chapter="OEBPS/text/ch2.xhtml"]');
                        var target = chapter && chapter.querySelector('[data-yj-original-id="sec-mid"], [id="sec-mid"]');
                        function rects(element) {
                            return element ? Array.from(element.getClientRects(), function(r) {
                                return {x:r.x, y:r.y, width:r.width, height:r.height};
                            }) : [];
                        }
                        var sample = window.__yjEpub && window.__yjEpub.sampleNow();
                        return JSON.stringify({readyState:document.readyState, chapterFound:!!chapter,
                            targetFound:!!target, targetRects:rects(target), chapterRects:rects(chapter),
                            scrollX:window.scrollX, scrollY:window.scrollY,
                            viewportWidth:window.innerWidth, viewportHeight:window.innerHeight,
                            sampleNode:sample ? sample.node : null,
                            sampleOffset:sample ? sample.utf16Offset : null});
                    })()
                    """)
                    print("EPUB_SYNTHETIC_FRAGMENT_FAILURE geometry=\(geometry as? String ?? "unavailable") nativeOffset=\(controller.webView.scrollView.contentOffset) nativeSize=\(controller.webView.scrollView.contentSize)")
                    throw error
                }
                #expect(model.currentPosition?.path == "OEBPS/text/ch2.xhtml")
                #expect((model.currentPosition?.node ?? 0) > 5)

                let closed = await model.close()
                #expect(closed)
            }

            let reopened = try await fixture.service.openEPUB(id: receipt.book.id)
            #expect(reopened.preferences == ReaderPreferences(fontSize: 28, lineSpacing: 14, theme: .dark))
            #expect(reopened.reading.position?.path == "OEBPS/text/ch2.xhtml")
            #expect((reopened.reading.position?.node ?? 0) > 5)
            try await reopened.close(position: nil, sequence: 1, token: nil, preferences: reopened.preferences)
        }
        try await verifyPagingAndChapterBoundaryNavigation()
    }

    @Test func epubShelfCoverThumbnailDisplaysAndMissingOrDamagedCoversFallbackCleanly() async throws {
        try await withHostFixture { fixture in
            LibraryCoverMemoryCache.shared.clear()
            await EPUBCoverProcessor.shared.clear()

            let coverURL = fixture.root.appendingPathComponent("WithCover.epub")
            let rawCover = try EPUBUITestFixture.makePNGData(width: 1000, height: 1400)
            try EPUBUITestFixture.writeIllustratedEPUB(to: coverURL, title: "Cover Book", coverData: rawCover)
            let coverReceipt = try await fixture.install(coverURL)

            let brokenCoverURL = fixture.root.appendingPathComponent("BrokenCover.epub")
            try EPUBUITestFixture.writeNoCoverEPUB(
                to: brokenCoverURL,
                title: "Broken Cover Book",
                corruptOptionalCoverData: Data("not-a-valid-image".utf8)
            )
            let brokenReceipt = try await fixture.install(brokenCoverURL)

            let noCoverURL = fixture.root.appendingPathComponent("NoCover.epub")
            try EPUBUITestFixture.writeNoCoverEPUB(to: noCoverURL, title: "No Cover Book")
            let noCoverReceipt = try await fixture.install(noCoverURL)

            let store = fixture.store
            let loader: @Sendable (String) async -> Data? = { id in
                try? await store.epubCover(bookID: id)
            }

            let validImage = try #require(await LibraryBookCoverView.resolveCoverImage(for: coverReceipt.book, loader: loader))
            let cgImage = try #require(validImage.cgImage)
            #expect(cgImage.width <= 512 && cgImage.height <= 512)
            #expect(max(cgImage.width, cgImage.height) == 512)
            #expect(LibraryCoverMemoryCache.shared.image(for: coverReceipt.book.id + ":" + coverReceipt.book.versionID) != nil)

            let brokenImage = await LibraryBookCoverView.resolveCoverImage(for: brokenReceipt.book, loader: loader)
            #expect(brokenImage == nil)
            let missingImage = await LibraryBookCoverView.resolveCoverImage(for: noCoverReceipt.book, loader: loader)
            #expect(missingImage == nil)

            let appearance = LibraryAppearance(colorScheme: .light, appAppearance: .mist)
            let hosting = UIHostingController(
                rootView: VStack {
                    LibraryBookRow(book: coverReceipt.book, appearance: appearance, coverLoader: loader)
                    LibraryBookRow(book: brokenReceipt.book, appearance: appearance, coverLoader: loader)
                    LibraryBookRow(book: noCoverReceipt.book, appearance: appearance, coverLoader: loader)
                }
            )
            try await fixture.withHostedController(hosting) {
                hosting.view.layoutIfNeeded()
                #expect(hosting.sizeThatFits(in: CGSize(width: 390, height: 1000)).height > 180)
            }

            let routeOwner = BookReadingRouteOwner()
            routeOwner.open(book: coverReceipt.book, service: fixture.service)
            let activeRoute = try #require(routeOwner.presentation)
            #expect(activeRoute.format == .epub && activeRoute.bookID == coverReceipt.book.id)
            routeOwner.finishExit(activeRoute.id)
            #expect(routeOwner.presentation == nil)

            let licenseText = LibraryLicenseView.bundledLicenseText()
            #expect(licenseText.contains("GRDB"))
            #expect(licenseText.contains("ZIPFoundation"))
            #expect(LibraryPlannedFeature.epub.isImplemented)
            #expect(LibraryPlannedFeature.cover.isImplemented)
        }
    }

    @Test func epubCompatibilityWebKitLoadsStaticImagePageAndRestoresAnchor() async throws {
        try await verifyStaticImagePageAndRestore(mislabeledJPEG: false)
        try await verifyStaticImagePageAndRestore(mislabeledJPEG: true)
        try await verifyClampedShortChapterReadiness()
    }

    private func verifyStaticImagePageAndRestore(mislabeledJPEG: Bool) async throws {
        try await withHostFixture { fixture in
            let archive = fixture.root.appendingPathComponent("SyntheticImagePage.epub")
            let webp = try #require(Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvAUAAAAfQtI4UtP+BiOh/AAA="))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).jpegData(withCompressionQuality: 1) { context in
                UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
            let imageData = mislabeledJPEG ? jpeg : webp
            let container = "<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" version=\"1.0\"><rootfiles><rootfile full-path=\"OPS/package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"
            let opf = "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"2.0\" unique-identifier=\"uid\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"uid\">synthetic-image-page</dc:identifier><dc:title>Synthetic image page</dc:title><dc:language>en</dc:language></metadata><manifest><item id=\"page\" href=\"page.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/><item id=\"image\" href=\"page.webp\" media-type=\"image/webp\"/></manifest><spine toc=\"ncx\"><itemref idref=\"page\"/></spine></package>"
            // Keep the URL unchanged: acceptance must use bytes, never the suffix.
            let packageXML = mislabeledJPEG ? opf.replacingOccurrences(of: "media-type=\"image/webp\"", with: "media-type=\"image/png\"") : opf
            let ncx = "<!DOCTYPE ncx PUBLIC \"-//NISO//DTD ncx 2005-1//EN\" \"http://www.daisy.org/z3986/2005/ncx-2005-1.dtd\"><ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><head/><docTitle><text>Synthetic image page</text></docTitle><navMap><navPoint id=\"p1\" playOrder=\"1\"><navLabel><text>Image page</text></navLabel><content src=\"page.xhtml#plate\"/></navPoint></navMap></ncx>"
            let page = "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\"><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Synthetic image page</title></head><body><svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" id=\"plate\" version=\"1.1\" width=\"100%\" height=\"100%\" viewBox=\"0 0 2 2\" preserveAspectRatio=\"xMidYMid meet\"><image width=\"2\" height=\"2\" xlink:href=\"page.webp\"/></svg></body></html>"
            try EPUBUITestFixture.writeArchive(entries: [
                ("mimetype", Data("application/epub+zip".utf8)),
                ("META-INF/container.xml", Data(container.utf8)),
                ("OPS/package.opf", Data(packageXML.utf8)), ("OPS/toc.ncx", Data(ncx.utf8)),
                ("OPS/page.xhtml", Data(page.utf8)), ("OPS/page.webp", imageData)
            ], to: archive)
            let receipt = try await fixture.install(archive)
            let reader = try await fixture.service.openEPUB(id: receipt.book.id)
            #expect(reader.publication.package.resource(at: "OPS/page.webp")?.mediaType == (mislabeledJPEG ? "image/jpeg" : "image/webp"))
            let path = "OPS/page.xhtml"
            #expect(try reader.publication.package.nodes(at: path) == ["图片页"])
            let position = EPUBReadingPosition(bookID: reader.book.id, versionID: reader.book.versionID,
                                               path: path, node: 0, utf16Offset: 0)
            let token = try await reader.beginNavigation(path: path)
            let controller = EPUBWebViewController()
            try await fixture.withHostedController(controller) {
                let payload = try await loadAndAwaitReady(controller: controller, request: EPUBNavigationRequest(
                    id: UUID(), token: token, publication: reader.publication, targetPosition: nil,
                    fragment: nil, preferences: reader.preferences, preserveTargetAnchor: false, reloadDocument: true))
                #expect(payload.kind == .ready && payload.path == path)
                #expect(payload.sessionID == reader.reading.session.id && payload.epoch == token.epoch)
                #expect(payload.visibleText.contains("图片页"))
                try await expectSyntheticImagePageLoaded(controller)
                #expect(try await reader.markReady(token))
                #expect(try await reader.save(position, sequence: 1, token: token))
                try await reader.close(position: position, sequence: 2, token: token, preferences: reader.preferences)
            }
            let freshService = LibraryService(store: try LibraryStore(root: fixture.root.appendingPathComponent("Managed", isDirectory: true)))
            let reopened = try await freshService.openEPUB(id: receipt.book.id)
            #expect(reopened.publication.package.resource(at: "OPS/page.webp")?.mediaType == (mislabeledJPEG ? "image/jpeg" : "image/webp"))
            let saved = try #require(reopened.reading.position)
            #expect(saved == position)
            let reopenToken = try await reopened.beginNavigation(path: path)
            let reopenController = EPUBWebViewController()
            try await fixture.withHostedController(reopenController) {
                let restored = try await loadAndAwaitReady(controller: reopenController, request: EPUBNavigationRequest(
                    id: UUID(), token: reopenToken, publication: reopened.publication, targetPosition: saved,
                    fragment: nil, preferences: reopened.preferences, preserveTargetAnchor: true, reloadDocument: true))
                #expect(restored.restoredNode == 0 && restored.restoredOffset == 0)
                #expect(restored.visibleText.contains("图片页"))
                try await expectSyntheticImagePageLoaded(reopenController)
                #expect(try await reopened.markReady(reopenToken))
                try await reopened.close(position: saved, sequence: 1, token: reopenToken, preferences: reopened.preferences)
            }
        }
    }

    private func expectSyntheticImagePageLoaded(_ controller: EPUBWebViewController) async throws {
        let summary = try await controller.evaluateLocatorJavaScriptForTesting("""
            (function() {
                var image = document.querySelector('img');
                return { loaded: Boolean(image && image.complete && image.naturalWidth === 2 && image.naturalHeight === 2),
                         svg: document.querySelectorAll('svg').length,
                         anchors: document.querySelectorAll('#yj-t0').length,
                         text: document.getElementById('yj-t0')?.textContent };
            })();
            """) as? [String: Any]
        #expect(summary?["loaded"] as? Bool == true)
        #expect(summary?["svg"] as? Int == 0)
        #expect(summary?["anchors"] as? Int == 1)
        #expect(summary?["text"] as? String == "图片页")
        #expect(controller.webView.scrollView.pinchGestureRecognizer?.isEnabled != true)
        #expect(controller.webView.scrollView.zoomScale == 1)
        #expect(controller.resourceHandler.servedPaths.contains("OPS/page.webp"))
    }

    private func verifySameBookWarmRenderer() async throws {
        try await withHostFixture { fixture in
            let archive = fixture.root.appendingPathComponent("WarmRenderer.epub")
            try EPUBUITestFixture.writeIllustratedEPUB(to: archive, title: "Warm Renderer")
            let receipt = try await fixture.install(archive)
            let cache = EPUBWarmRendererCache()
            defer { cache.discard() }
            @MainActor
            func makeModel() -> EPUBReaderViewModel {
                EPUBReaderViewModel(bookID: receipt.book.id, service: fixture.service,
                                    readingMode: .scroll, rendererCache: cache)
            }
            @MainActor
            func bind(_ model: EPUBReaderViewModel, _ controller: EPUBWebViewController) {
                controller.onLocatorEvent = { model.handleLocatorEvent($0) }
                controller.onLoadFailure = { model.handleLoadFailure($0, token: $1) }
                controller.onChapterBoundary = { model.turnChapter($0, from: $1) }
            }
            let first = makeModel()
            let controller = first.webView.makeController()
            bind(first, controller)
            try await fixture.withHostedController(controller) {
                await first.load()
                let initial = try #require(first.currentToken)
                try await waitUntilReady(model: first, expectedToken: initial)
                try await waitForChapterWindow(controller, count: 3)
                #expect(controller.documentLoadCount == 1 && controller.closedDocumentReuseCount == 0)
                #expect(!controller.webView.isHidden)
                let oldReader = try #require(first.reader)
                let root = oldReader.publication.resourceRoot
                _ = try await controller.evaluateLocatorJavaScriptForTesting("""
                window.__warmDocument = document;
                window.__warmNode = document.querySelector('[data-yj-chapter]');
                window.__warmImage = document.querySelector('img');
                window.scrollTo(0, 500); true;
                """)
                let oldPayload = try #require(await controller.sampleVisibleNow())
                #expect(oldPayload.scrollY > 0)
                first.handleLocatorEvent(oldPayload)
                #expect(await first.close())
                #expect(controller.hasParkedDocument && controller.activeRequest == nil)
                #expect(controller.onLocatorEvent == nil && controller.webView.isHidden)
                #expect(await controller.sampleVisibleNow() == nil)
                #expect(try await oldReader.markReady(initial) == false)

                let second = makeModel()
                let reused = second.webView.makeController()
                #expect(reused === controller)
                // A delayed dismantle belonging to the old SwiftUI route must be harmless.
                first.webView.detach(controller)
                #expect(controller.hasParkedDocument)
                bind(second, reused)
                await second.load()
                let fresh = try #require(second.currentToken)
                #expect(fresh.sessionID != initial.sessionID)
                try await waitUntilReady(model: second, expectedToken: fresh)
                let latestReader = try #require(second.reader)
                #expect(latestReader.publication.resourceRoot == root)
                #expect(second.currentPosition == latestReader.reading.position)
                #expect(controller.documentLoadCount == 1 && controller.closedDocumentReuseCount == 1)
                #expect(!controller.webView.isHidden)
                let sameDOM = try await controller.evaluateLocatorJavaScriptForTesting("""
                document === window.__warmDocument && document.querySelector('[data-yj-chapter]') === window.__warmNode &&
                document.querySelector('img') === window.__warmImage;
                """) as? Bool
                #expect(sameDOM == true)
                let beforeStale = second.currentPosition
                second.handleLocatorEvent(oldPayload)
                #expect(second.currentPosition == beforeStale && second.currentToken == fresh)
                try await waitForChapterWindow(controller, count: 3)
                #expect(await second.close())
                #expect(controller.hasParkedDocument)

                // A new verified directory must not inherit even a visually valid old DOM.
                try FileManager.default.removeItem(at: root.appendingPathComponent(initial.path))
                let third = makeModel()
                #expect(third.webView.makeController() === controller)
                bind(third, controller)
                await third.load()
                let recovered = try #require(third.currentToken)
                try await waitUntilReady(model: third, expectedToken: recovered)
                #expect(third.reader?.publication.resourceRoot != root)
                #expect(controller.documentLoadCount == 2 && controller.closedDocumentReuseCount == 1)
                #expect(!controller.webView.isHidden)
                try await waitForChapterWindow(controller, count: 3)
                #expect(await third.close())
                #expect(controller.hasParkedDocument)
                cache.discard() // Same path used for memory warning/background; no session cache survives.
                #expect(!controller.hasParkedDocument)
                let fourth = makeModel()
                let cold = fourth.webView.makeController()
                #expect(cold !== controller && cold.documentLoadCount == 0)
                cold.detachCallbacks()
            }
        }
    }

    @Test func epubRecentBooksReusePagesAcrossSwitchesAndEvictOnlyIdleLRU() async throws {
        try await withHostFixture { fixture in
            let cache = EPUBWarmRendererCache()
            defer { cache.discard() }
            var ids: [String] = []
            for title in ["Recent A", "Recent B", "Recent C", "Recent D"] {
                let archive = fixture.root.appendingPathComponent(title + ".epub")
                try EPUBUITestFixture.writeIllustratedEPUB(to: archive, title: title)
                ids.append(try await fixture.install(archive).book.id)
            }
            @MainActor
            func openAndClose(_ id: String, expected: EPUBWebViewController? = nil,
                              root: URL? = nil, changedLayout: Bool = false) async throws -> (EPUBWebViewController, URL) {
                let model = EPUBReaderViewModel(bookID: id, service: fixture.service,
                    readingMode: changedLayout ? .paged : .scroll, rendererCache: cache)
                let controller = model.webView.makeController()
                if let expected { #expect(controller === expected) }
                let loads = controller.documentLoadCount
                controller.onLocatorEvent = { model.handleLocatorEvent($0) }
                controller.onLoadFailure = { model.handleLoadFailure($0, token: $1) }
                var actualRoot: URL?
                try await fixture.withHostedController(controller, preservingParked: true) {
                    await model.load()
                    let token = try #require(model.currentToken)
                    try await waitUntilReady(model: model, expectedToken: token)
                    #expect(model.openingPerformanceSummary?.contains("reopen-reasons-v1") == true)
                    if expected != nil {
                        #expect(model.reader?.openingTimings.metadataReuseReason == .reused)
                        #expect(cache.diagnostics(bookID: id, service: fixture.service).samples.last?.reason == .takeHit)
                    }
                    try await waitForChapterWindow(controller, count: 3)
                    actualRoot = model.reader?.publication.resourceRoot
                    if let root { #expect(actualRoot == root) }
                    #expect(controller.documentLoadCount == loads + (expected == nil ? 1 : 0))
                    #expect(await model.close())
                    #expect(controller.hasParkedDocument)
                    #expect(cache.diagnostics(bookID: id, service: fixture.service).samples.last?.reason == .retained)
                }
                #expect(cache.idleCount <= 3)
                return (controller, try #require(actualRoot))
            }
            let a = try await openAndClose(ids[0])
            let b = try await openAndClose(ids[1])
            _ = try await openAndClose(ids[2])
            #expect(cache.idleCount == 3)
            NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            #expect(cache.idleCount == 3) // Background alone does not invalidate content or pages.
            _ = try await openAndClose(ids[0], expected: a.0, root: a.1, changedLayout: true)
            #expect(a.0.closedDocumentReuseCount == 1)
            _ = try await openAndClose(ids[3])
            #expect(!b.0.hasParkedDocument && cache.evictions >= 1)
            #expect(cache.diagnostics(bookID: ids[1], service: fixture.service).samples.contains { $0.reason == .evictedCount })
            let bAgain = try await openAndClose(ids[1], root: b.1)
            #expect(bAgain.0 !== b.0) // Warm disk recovery after renderer eviction, same resource root.
            let opening = EPUBReaderViewModel(bookID: ids[1], service: fixture.service,
                                             readingMode: .scroll, rendererCache: cache)
            let duringOpen = opening.webView.makeController()
            #expect(duringOpen === bAgain.0)
            duringOpen.onLocatorEvent = { opening.handleLocatorEvent($0) }
            duringOpen.onLoadFailure = { opening.handleLoadFailure($0, token: $1) }
            cache.discard() // Between take/mount and apply: keep the new route's business callbacks.
            #expect(cache.diagnostics(bookID: ids[1], service: fixture.service).samples.last?.reason == .explicitDiscard)
            #expect(duringOpen.onLocatorEvent != nil && duringOpen.onLoadFailure != nil)
            try await fixture.withHostedController(duringOpen) {
                await opening.load()
                let token = try #require(opening.currentToken)
                try await waitUntilReady(model: opening, expectedToken: token)
                #expect(duringOpen.documentLoadCount == 2)
                #expect(await opening.close())
            }
            #expect(cache.idleCount == 0)
            #expect(FileManager.default.fileExists(atPath: b.1.path))
            try await verifyReopenDiagnostics(fixture: fixture, bookID: ids[0])
        }
    }

    // MARK: - Helpers

    private func verifyReopenDiagnostics(fixture: HostFixture, bookID: String) async throws {
        let mib = 1024 * 1024
        let syntheticChapterBytes = Array(repeating: 24 * 1024, count: 1633)
        let longBookCost = EPUBRendererCost(xhtmlBytes: syntheticChapterBytes.reduce(0, +), imageBytes: 12 * mib)
        #expect(longBookCost.total == 16 * mib + 12 * mib + syntheticChapterBytes.reduce(0) { $0 + $1 * 2 })
        #expect(longBookCost.total > EPUBWarmRendererCache.Limits().idleEstimatedBytes)
        #expect(EPUBRendererCost(xhtmlBytes: 40 * mib, imageBytes: 0).total == 96 * mib)
        var bounded = EPUBReopenDiagnostics()
        for _ in 0..<100 { bounded.record(.takeMiss) }
        #expect(bounded.samples.count == 16)
        let ledger = EPUBWarmRendererCache()
        let old = ledger.take(bookID: "synthetic-private-id", service: fixture.service)
        let current = ledger.take(bookID: "synthetic-private-id", service: fixture.service)
        var failed = EPUBReopenDiagnostics(); failed.record(.saveFailed)
        ledger.recordClose(failed, bookID: "synthetic-private-id", service: fixture.service, generation: old.generation)
        #expect(!ledger.diagnostics(bookID: "synthetic-private-id", service: fixture.service).samples.contains { $0.reason == .saveFailed })
        ledger.recordClose(failed, bookID: "synthetic-private-id", service: fixture.service, generation: current.generation)
        #expect(ledger.diagnostics(bookID: "synthetic-private-id", service: fixture.service).samples.last?.reason == .saveFailed)
        ledger.discard(reason: .memoryWarning)
        #expect(ledger.diagnostics(bookID: "synthetic-private-id", service: fixture.service).samples.last?.reason == .memoryWarning)
        ledger.finish(current.generation)
        var abandoned = EPUBReopenDiagnostics(); abandoned.record(.abandoned)
        ledger.recordClose(abandoned, bookID: "synthetic-private-id", service: fixture.service, generation: current.generation)
        #expect(ledger.diagnostics(bookID: "synthetic-private-id", service: fixture.service).samples.last?.reason == .abandoned)
        #expect(!ledger.retain(EPUBWebViewController(), bookID: "synthetic-private-id", service: fixture.service, generation: current.generation))
        #expect(ledger.diagnostics(bookID: "synthetic-private-id", service: fixture.service).samples.last?.reason == .rejectInactiveRoute)
        #expect(!ledger.diagnostics(bookID: "synthetic-private-id", service: fixture.service).summary.contains("synthetic-private-id"))
        #expect(ledger.diagnostics(bookID: "foreign", service: fixture.service).samples.isEmpty)
        for index in 0..<80 { _ = ledger.take(bookID: "synthetic-\(index)", service: fixture.service) }
        #expect(ledger.diagnosticCount == 64)
        #expect(ledger.diagnostics(bookID: "synthetic-private-id", service: fixture.service).samples.isEmpty)
        ledger.discard()

        var timeoutCount = 0
        var pendingReply: EPUBParkReply?
        let timedOut: EPUBParkState? = await withCheckedContinuation { continuation in
            pendingReply = EPUBParkReply(continuation) { timeoutCount += 1 }
        }
        #expect(timedOut == nil && timeoutCount == 1)
        pendingReply?.finish(EPUBParkState(paths: [], imageBytes: 0)) // Late reply must not complete twice.
        #expect(timeoutCount == 1)

        // Exercise real park/admission and next-open reason propagation, without a private book.
        for scenario in ["budget", "invalid-state", "process-terminated"] {
            var limits = EPUBWarmRendererCache.Limits()
            if scenario == "budget" { limits.idleEstimatedBytes = 1 }
            let cache = EPUBWarmRendererCache(limits: limits)
            let model = EPUBReaderViewModel(bookID: bookID, service: fixture.service, readingMode: .scroll, rendererCache: cache)
            let controller = model.webView.makeController()
            controller.onLocatorEvent = { model.handleLocatorEvent($0) }
            controller.onLoadFailure = { model.handleLoadFailure($0, token: $1) }
            try await fixture.withHostedController(controller, preservingParked: true) {
                await model.load()
                let token = try #require(model.currentToken)
                try await waitUntilReady(model: model, expectedToken: token)
                try await waitForChapterWindow(controller, count: 3)
                if scenario == "invalid-state" {
                    _ = try await controller.evaluateLocatorJavaScriptForTesting(
                        "window.__yjEpub.parkForReopen = function() { return {paths: [], imageBytes: 0}; }; true;")
                }
                #expect(await model.close())
                let close = cache.diagnostics(bookID: bookID, service: fixture.service)
                if scenario == "budget" {
                    let rejected = try #require(close.samples.last)
                    #expect(rejected.reason == .rejectBudget && rejected.limitBytes == 1)
                    #expect(rejected.estimatedBytes == 16 * mib + rejected.imageBytes + rejected.xhtmlBytes * 2)
                    #expect(!controller.hasParkedDocument && cache.idleCount == 0)
                } else if scenario == "invalid-state" {
                    #expect(close.samples.contains { $0.reason == .parkInvalidState })
                    #expect(!controller.hasParkedDocument && cache.idleCount == 0)
                } else {
                    #expect(controller.hasParkedDocument)
                    controller.webViewWebContentProcessDidTerminate(controller.webView)
                    #expect(!controller.hasParkedDocument)
                }
                if scenario == "process-terminated" {
                    let source = try await fixture.service.openEPUB(id: bookID)
                    let lease = try await source.leaseForRenderer()
                    #expect(await controller.parkForReopen(lease: lease) == false)
                    #expect(controller.parkDiagnostics.samples.contains { $0.reason == .processTerminated })
                    #expect(controller.parkDiagnostics.samples.last?.reason == .parkNotReady)
                    await lease.release()
                    try await source.abandon()
                }
            }
            let again = cache.take(bookID: bookID, service: fixture.service)
            #expect(again.controller == nil)
            let next = cache.diagnostics(bookID: bookID, service: fixture.service)
            #expect(next.samples.last?.reason == (scenario == "process-terminated" ? .takeInvalid : .takeMiss))
            if scenario == "process-terminated" {
                #expect(next.samples.filter { $0.reason == .parked }.count == 1)
                #expect(next.samples.filter { $0.reason == .processTerminated }.count == 1)
            }
            if scenario == "process-terminated" { #expect(next.samples.contains { $0.reason == .processTerminated }) }
            cache.finish(again.generation)
            cache.discard()
        }
    }

    private struct HostFixture {
        let root: URL
        let store: LibraryStore
        let service: LibraryService

        func install(_ url: URL) async throws -> ImportReceipt {
            let result = try await service.prepareReadingImport(
                url: url,
                ticket: UUID(),
                budget: ReaderStoragePolicy.budget()
            )
            guard case .completed(let receipt) = result else {
                throw EPUBError.invalidPackage
            }
            return receipt
        }

        @MainActor
        func withHostedController(_ controller: UIViewController, preservingParked: Bool = false,
                                  _ body: @MainActor () async throws -> Void) async throws {
            let scene = try #require(
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first
            )
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
            defer {
                if let webController = controller as? EPUBWebViewController,
                   !preservingParked || !webController.hasParkedDocument {
                    webController.detachCallbacks()
                }
                window.isHidden = true
                window.rootViewController = nil
            }
            window.rootViewController = controller
            window.isHidden = false
            controller.loadViewIfNeeded()
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            try await body()
        }
    }

    private func withHostFixture(_ body: @MainActor (HostFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YueJing-EPUBHost-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("Managed", isDirectory: true))
        let service = LibraryService(store: store)
        try await body(HostFixture(root: root, store: store, service: service))
    }

    private func loadAndAwaitReady(
        controller: EPUBWebViewController,
        request: EPUBNavigationRequest
    ) async throws -> EPUBLocatorPayload {
        let readyExpectation = XCTestExpectation(description: "EPUB WebKit locator ready")
        var capturedPayload: EPUBLocatorPayload?
        var capturedError: Error?
        controller.onLocatorEvent = { payload in
            guard payload.epoch == request.token.epoch else { return }
            if payload.kind == .ready {
                capturedPayload = payload
                readyExpectation.fulfill()
            } else if payload.kind == .error {
                capturedError = EPUBError.invalidPosition
                readyExpectation.fulfill()
            }
        }
        controller.onLoadFailure = { error, token in
            guard token == request.token else { return }
            capturedError = error
            readyExpectation.fulfill()
        }
        controller.apply(request)
        let waitResult = await XCTWaiter.fulfillment(of: [readyExpectation], timeout: 15)
        try #require(waitResult == .completed)
        if let capturedError {
            throw capturedError
        }
        return try #require(capturedPayload)
    }

    private func waitUntilReady(
        model: EPUBReaderViewModel,
        expectedToken: EPUBNavigationToken,
        minimumNode: Int? = nil
    ) async throws {
        print("EPUB_SYNTHETIC_READY_WAIT expected=\(expectedToken) minimumNode=\(String(describing: minimumNode))")
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        // DOM ready and the asynchronous scroll-position report are separate callbacks.
        // Await the requested observable position within the same original deadline.
        func positionReady() -> Bool {
            minimumNode.map { (model.currentPosition?.node ?? -1) >= $0 } ?? true
        }
        while !(model.ready && !model.loading && model.currentToken == expectedToken && positionReady()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if !(model.ready && !model.loading && model.currentToken == expectedToken && positionReady()) {
            print("EPUB_SYNTHETIC_READY_FAILURE expected=\(expectedToken) current=\(String(describing: model.currentToken)) position=\(String(describing: model.currentPosition)) minimumNode=\(String(describing: minimumNode))")
        }
        try #require(model.ready && !model.loading && model.currentToken == expectedToken)
        try #require(positionReady())
    }

    private func waitForNewToken(
        model: EPUBReaderViewModel,
        previous: EPUBNavigationToken
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (model.navigationRequest?.token == nil || model.navigationRequest?.token == previous), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.navigationRequest?.token != nil && model.navigationRequest?.token != previous)
    }

    private func verifyReadinessDeadline(publication: EPUBPublication, token: EPUBNavigationToken,
                                         preferences: ReaderPreferences) {
        let controller = EPUBWebViewController()
        var failed: [EPUBNavigationToken] = []
        controller.onLoadFailure = { error, token in
            #expect((error as? URLError)?.code == .timedOut)
            failed.append(token)
        }
        func request(_ token: EPUBNavigationToken) -> EPUBNavigationRequest {
            EPUBNavigationRequest(id: UUID(), token: token, publication: publication, targetPosition: nil,
                                  fragment: nil, preferences: preferences, preserveTargetAnchor: false, reloadDocument: true)
        }
        // No sleeps: expire before the scheduled navigation task can run.
        controller.apply(request(token))
        let next = EPUBNavigationToken(sessionID: token.sessionID, path: token.path)
        controller.expireReadiness(for: next)
        #expect(controller.activeRequest?.token == token && failed.isEmpty)
        controller.expireReadiness(for: token)
        #expect(controller.activeRequest == nil && failed == [token])
        controller.apply(request(next))
        controller.expireReadiness(for: token)
        #expect(controller.activeRequest?.token == next && failed == [token])
        controller.detachCallbacks()
        controller.expireReadiness(for: next)
        #expect(failed == [token])
    }

    private func verifyViewportWhitespaceTap(_ controller: EPUBWebViewController) async throws {
        let intent = UUID()
        var toggles = 0
        controller.toolIntent = { intent }
        controller.onToolsInteraction = { event in
            if case .tap(let expected, .toggle) = event {
                #expect(expected == intent); toggles += 1
            }
        }
        defer { controller.toolIntent = nil; controller.onToolsInteraction = nil }
        // Place a genuinely empty surface below the old central 20%-80% gate.
        _ = try await controller.evaluateLocatorJavaScriptForTesting("""
        (function() {
            var blank = document.createElementNS('http://www.w3.org/1999/xhtml', 'div');
            blank.id = 'test-tap-blank';
            blank.style.cssText = 'position:fixed;left:0;right:0;bottom:0;height:80px;z-index:9999;background:white';
            document.body.appendChild(blank); return true;
        })();
        """)
        let point = CGPoint(x: controller.webView.bounds.midX, y: controller.webView.bounds.height - 20)
        controller.handleViewportTap(at: point)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while toggles == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(toggles == 1)
        controller.handleViewportTap(at: point)
        controller.scrollViewWillBeginDragging(controller.webView.scrollView)
        _ = try await controller.evaluateLocatorJavaScriptForTesting("true;")
        #expect(toggles == 1) // A subsequent drag revokes the pending hit-test.
        controller.scrollViewDidEndDragging(controller.webView.scrollView, willDecelerate: false)
        let dragStopped = try await controller.evaluateLocatorJavaScriptForTesting("window.__yjEpub.sampleStatus().scrollActive") as? Bool
        #expect(dragStopped == false)
        controller.scrollViewWillBeginDragging(controller.webView.scrollView)
        controller.scrollViewDidEndDragging(controller.webView.scrollView, willDecelerate: true)
        controller.handleViewportTap(at: point, beganDuringDeceleration: true)
        let momentumStopped = try await controller.evaluateLocatorJavaScriptForTesting("window.__yjEpub.sampleStatus().scrollActive") as? Bool
        #expect(momentumStopped == false && toggles == 1)
        _ = try await controller.evaluateLocatorJavaScriptForTesting("""
        document.getElementById('test-tap-blank').innerHTML = '<a href="#" style="display:block;width:100%;height:100%">link</a>'; true;
        """)
        controller.handleViewportTap(at: point)
        // An ordered IPC barrier ensures the prior hit-test callback has returned.
        _ = try await controller.evaluateLocatorJavaScriptForTesting("true;")
        #expect(toggles == 1) // Links remain publication interactions, not tool toggles.
        controller.interactionEnabled = false
        controller.handleViewportTap(at: point)
        #expect(toggles == 1)
        controller.interactionEnabled = true
        _ = try await controller.evaluateLocatorJavaScriptForTesting("document.getElementById('test-tap-blank').remove(); true;")
    }

    private func verifyClampedShortChapterReadiness() async throws {
        try await withHostFixture { fixture in
            let archive = fixture.root.appendingPathComponent("ClampedShortChapter.epub")
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80), format: format).pngData { context in
                UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
            }
            let container = "<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\" version=\"1.0\"><rootfiles><rootfile full-path=\"OPS/package.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"
            let opf = "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"2.0\" unique-identifier=\"uid\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"uid\">clamped-short</dc:identifier><dc:title>Clamped short</dc:title><dc:language>en</dc:language></metadata><manifest><item id=\"long\" href=\"long.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"short\" href=\"short.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/><item id=\"image\" href=\"image.png\" media-type=\"image/png\"/></manifest><spine toc=\"ncx\"><itemref idref=\"long\"/><itemref idref=\"short\"/></spine></package>"
            let ncx = "<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><head/><docTitle><text>Clamped short</text></docTitle><navMap><navPoint id=\"p1\" playOrder=\"1\"><navLabel><text>Long</text></navLabel><content src=\"long.xhtml\"/></navPoint><navPoint id=\"p2\" playOrder=\"2\"><navLabel><text>Short</text></navLabel><content src=\"short.xhtml\"/></navPoint></navMap></ncx>"
            let longBody = (0..<60).map { "<p>Synthetic paragraph \($0) repeated to fill the viewport.</p>" }.joined()
            let long = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Long</title></head><body>\(longBody)</body></html>"
            let short = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Short</title></head><body><img src=\"image.png\" alt=\"\"/><img src=\"image.png\" alt=\"\"/></body></html>"
            try EPUBUITestFixture.writeArchive(entries: [
                ("mimetype", Data("application/epub+zip".utf8)), ("META-INF/container.xml", Data(container.utf8)),
                ("OPS/package.opf", Data(opf.utf8)), ("OPS/toc.ncx", Data(ncx.utf8)),
                ("OPS/long.xhtml", Data(long.utf8)), ("OPS/short.xhtml", Data(short.utf8)), ("OPS/image.png", image)
            ], to: archive)
            let receipt = try await fixture.install(archive)
            let reader = try await fixture.service.openEPUB(id: receipt.book.id)
            let controller = EPUBWebViewController()
            try await fixture.withHostedController(controller) {
                let firstToken = try await reader.beginNavigation(path: "OPS/long.xhtml")
                _ = try await loadAndAwaitReady(controller: controller, request: EPUBNavigationRequest(
                    id: UUID(), token: firstToken, publication: reader.publication, targetPosition: nil,
                    fragment: nil, preferences: reader.preferences, preserveTargetAnchor: false, reloadDocument: true))
                try await waitForChapterWindow(controller, count: 2)
                let shortToken = try await reader.beginNavigation(path: "OPS/short.xhtml")
                let payload = try await loadAndAwaitReady(controller: controller, request: EPUBNavigationRequest(
                    id: UUID(), token: shortToken, publication: reader.publication, targetPosition: nil,
                    fragment: nil, preferences: reader.preferences, preserveTargetAnchor: false, reloadDocument: false))
                #expect(payload.path == shortToken.path && payload.epoch == shortToken.epoch)
                #expect(payload.restoredNode == 0 && payload.restoredOffset == 0)
                #expect(controller.documentLoadCount == 1)
                #expect(controller.webView.scrollView.isScrollEnabled)
                let visible = try #require(await controller.sampleVisibleNow())
                #expect(visible.path == "OPS/long.xhtml") // Real viewport still begins in the predecessor.
                let before = controller.webView.scrollView.contentOffset.y
                _ = try await controller.evaluateLocatorJavaScriptForTesting("window.scrollBy(0, -100); true;")
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while controller.webView.scrollView.contentOffset.y >= before, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(controller.webView.scrollView.contentOffset.y < before)
                #expect(try await reader.markReady(shortToken))
                try await reader.close(position: nil, sequence: 1, token: shortToken, preferences: reader.preferences)
            }
        }
    }

    private func verifyLargeDirectorySelection() {
        let items = (0..<1633).map {
            EPUBNavigationItem(title: "Synthetic chapter \($0)", path: "Text/c\($0).xhtml")
        }
        for index in [0, 816, 1632] {
            #expect(EPUBContentsView.currentIndex(in: items, path: items[index].path, fragment: nil) == index)
        }
        #expect(EPUBContentsView.currentIndex(in: items, path: nil, fragment: nil) == nil)
        #expect(EPUBContentsView.currentIndex(in: items, path: "missing.xhtml", fragment: nil) == nil)
        #expect(EPUBContentsView.currentIndex(in: [], path: "empty.xhtml", fragment: nil) == nil)
        let anchors = [
            EPUBNavigationItem(title: "Chapter", path: "c.xhtml"),
            EPUBNavigationItem(title: "Middle", path: "c.xhtml", fragment: "middle"),
            EPUBNavigationItem(title: "End", path: "c.xhtml", fragment: "end")
        ]
        #expect(EPUBContentsView.currentIndex(in: anchors, path: "c.xhtml", fragment: "end") == 2)
        #expect(EPUBContentsView.currentIndex(in: anchors, path: "c.xhtml", fragment: "unknown") == 0)
        #expect(EPUBContentsView.currentIndex(in: anchors, path: "c.xhtml", fragment: "") == 0)
    }

    private func verifyPageGeometry() {
        let spine = (0..<12).map { "chapter-\($0).xhtml" }
        #expect(EPUBChapterWindow.paths(in: spine, around: spine[0]) == Array(spine[0..<5]))
        #expect(EPUBChapterWindow.paths(in: spine, around: spine[6]) == Array(spine[4..<9]))
        #expect(EPUBChapterWindow.paths(in: spine, around: spine[11]) == Array(spine[7..<12]))
        #expect(EPUBChapterWindow.paths(in: ["only.xhtml"], around: "only.xhtml") == ["only.xhtml"])
        #expect(EPUBChapterWindow.paths(in: spine, around: "unknown.xhtml").isEmpty)
        #expect(EPUBChapterWindow.paths(in: [], around: "unknown.xhtml").isEmpty)
        let shortSpine = (0..<128).map { "short-\($0).xhtml" }
        #expect(EPUBChapterWindow.paths(in: shortSpine, around: shortSpine[0], count: 10).count == 10)
        #expect(EPUBChapterWindow.paths(in: shortSpine, around: shortSpine[0], count: 1000).count == 64)
        #expect(EPUBChapterWindow.maximumXHTMLBytes == 40 * 1024 * 1024)
        let desired = Array(spine[0..<5])
        var installed: Set<String> = [spine[2]]
        for next in [3, 4, 1, 0] {
            let plan = EPUBChapterWindow.nextPaths(desired: desired, installed: installed, current: spine[2])
            #expect(Set(plan).subtracting(installed) == Set([spine[next]]))
            #expect(plan == desired.filter { installed.contains($0) || $0 == spine[next] })
            installed = Set(plan)
        }
        #expect(EPUBChapterWindow.nextPaths(desired: desired, installed: installed, current: spine[2]) == desired)
        #expect(EPUBChapterWindow.nextPaths(desired: [], installed: installed, current: spine[2]).isEmpty)
        #expect(EPUBChapterWindow.nextPaths(desired: desired, installed: [spine[0]], current: spine[0]) == [spine[0], spine[1]])
        let g1 = EPUBPageGeometry(offset: 0, contentHeight: 2000, viewportHeight: 600, topInset: 0, bottomInset: 0)
        #expect(g1.valid)
        #expect(g1.minimum == 0)
        #expect(g1.maximum == 1400)

        #expect(!EPUBPageGeometry(offset: .nan, contentHeight: 2000, viewportHeight: 600).valid)
        #expect(!EPUBPageGeometry(offset: 0, contentHeight: .infinity, viewportHeight: 600).valid)
        #expect(!EPUBPageGeometry(offset: 0, contentHeight: 2000, viewportHeight: 0).valid)
        #expect(!EPUBPageGeometry(offset: 0, contentHeight: 2000, viewportHeight: -100).valid)
        #expect(!EPUBPageGeometry(offset: 0, contentHeight: -10, viewportHeight: 600).valid)
        #expect(EPUBPageGeometry(offset: .nan, contentHeight: 2000, viewportHeight: 600).destination(.next) == nil)
        #expect(EPUBPageGeometry(offset: .nan, contentHeight: 2000, viewportHeight: 600).destination(.previous) == nil)

        #expect(g1.destination(.previous) == nil)
        let next1 = g1.destination(.next)
        #expect(next1 != nil && abs((next1 ?? 0) - 536) < 1)

        let gMid = EPUBPageGeometry(offset: 536, contentHeight: 2000, viewportHeight: 600)
        let prevMid = gMid.destination(.previous)
        #expect(prevMid != nil && abs((prevMid ?? 0) - 0) < 1)
        let nextMid = gMid.destination(.next)
        #expect(nextMid != nil && abs((nextMid ?? 0) - 1072) < 1)

        let gNearEnd = EPUBPageGeometry(offset: 1300, contentHeight: 2000, viewportHeight: 600)
        let nextEnd = gNearEnd.destination(.next)
        #expect(nextEnd != nil && abs((nextEnd ?? 0) - 1400) < 1)

        let gAtEnd = EPUBPageGeometry(offset: 1400, contentHeight: 2000, viewportHeight: 600)
        #expect(gAtEnd.destination(.next) == nil)
        let prevEnd = gAtEnd.destination(.previous)
        #expect(prevEnd != nil && abs((prevEnd ?? 0) - 864) < 1)

        let shortG = EPUBPageGeometry(offset: 0, contentHeight: 400, viewportHeight: 600)
        #expect(shortG.valid)
        #expect(shortG.minimum == 0)
        #expect(shortG.maximum == 0)
        #expect(shortG.destination(.next) == nil)
        #expect(shortG.destination(.previous) == nil)
        #expect(shortG.continuation(direction: .next) == .next)
        #expect(shortG.continuation(direction: .previous) == .previous)

        let insetG = EPUBPageGeometry(offset: 0, contentHeight: 2000, viewportHeight: 600, topInset: 56, bottomInset: 56)
        #expect(insetG.valid)
        #expect(insetG.minimum == -56)
        #expect(insetG.maximum == 1456)

        let topBoundary = EPUBPageGeometry(offset: 0, contentHeight: 2000, viewportHeight: 600)
        #expect(topBoundary.continuation(direction: .previous) == .previous)
        #expect(topBoundary.continuation(direction: .next) == nil)
        let notAtTop = EPUBPageGeometry(offset: 50, contentHeight: 2000, viewportHeight: 600)
        #expect(notAtTop.continuation(direction: .previous) == nil)
        let bottomBoundary = EPUBPageGeometry(offset: 1400, contentHeight: 2000, viewportHeight: 600)
        #expect(bottomBoundary.continuation(direction: .next) == .next)
        #expect(bottomBoundary.continuation(direction: .previous) == nil)
        #expect(gNearEnd.continuation(direction: .next) == nil)
        #expect(EPUBPageGeometry(offset: .nan, contentHeight: 2000, viewportHeight: 600).continuation(direction: .next) == nil)
        #expect(EPUBPageGeometry.horizontalDestination(.next, offset: 0, contentWidth: 1200, viewportWidth: 400) == 400)
        #expect(EPUBPageGeometry.horizontalDestination(.previous, offset: 400, contentWidth: 1200, viewportWidth: 400) == 0)
        #expect(EPUBPageGeometry.horizontalDestination(.next, offset: 800, contentWidth: 1200, viewportWidth: 400) == nil)
        #expect(EPUBPageGeometry.horizontalDestination(.next, offset: 0, contentWidth: 400, viewportWidth: 400) == nil)
        #expect(EPUBPageGeometry.horizontalDestination(.next, offset: .nan, contentWidth: 1200, viewportWidth: 400) == nil)
        #expect(EPUBPageGeometry.horizontalDestination(.next, offset: 0, contentWidth: 1200, viewportWidth: 0) == nil)
        #expect(AppVersion(info: ["CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "42"]).displayText == "9.8.7（构建 42）")
        #expect(AppVersion(info: [:]).displayText == "未知（构建 未知）")

        let screenSize = CGSize(width: 400, height: 800)
        #expect(EPUBPageGeometry.edgeDirection(at: CGPoint(x: 40, y: 400), size: screenSize) == .previous)
        #expect(EPUBPageGeometry.edgeDirection(at: CGPoint(x: 80, y: 400), size: screenSize) == .previous)
        #expect(EPUBPageGeometry.edgeDirection(at: CGPoint(x: 350, y: 400), size: screenSize) == .next)
        #expect(EPUBPageGeometry.edgeDirection(at: CGPoint(x: 320, y: 400), size: screenSize) == .next)
        #expect(EPUBPageGeometry.edgeDirection(at: CGPoint(x: 200, y: 400), size: screenSize) == nil)
        #expect(EPUBPageGeometry.edgeDirection(at: CGPoint(x: 40, y: 30), size: screenSize) == nil)
        #expect(EPUBPageGeometry.edgeDirection(at: CGPoint(x: 350, y: 760), size: screenSize) == nil)
        #expect(EPUBPageGeometry.edgeDirection(at: CGPoint(x: -10, y: 400), size: screenSize) == nil)
        #expect(EPUBPageGeometry.edgeDirection(at: CGPoint(x: 450, y: 400), size: screenSize) == nil)
        #expect(EPUBPageGeometry.edgeDirection(at: CGPoint(x: 40, y: 400), size: CGSize(width: 400, height: 100)) == nil)
        #expect(EPUBPageGeometry.edgeDirection(at: CGPoint(x: CGFloat.nan, y: 400), size: screenSize) == nil)
    }

    private func verifyPagingAndChapterBoundaryNavigation() async throws {
        verifyPageGeometry()
        try await verifyHorizontalPagination()

        try await withHostFixture { fixture in
            let archiveURL = fixture.root.appendingPathComponent("Paging.epub")
            try EPUBUITestFixture.writeIllustratedEPUB(to: archiveURL, title: "Host Paging")
            let receipt = try await fixture.install(archiveURL)

            let model = EPUBReaderViewModel(bookID: receipt.book.id, service: fixture.service, readingMode: .scroll)
            let controller = EPUBWebViewController()
            model.webView.attach(controller)
            controller.onLocatorEvent = { [weak model] payload in model?.handleLocatorEvent(payload) }
            controller.onLoadFailure = { [weak model] error, token in model?.handleLoadFailure(error, token: token) }
            controller.onInternalLink = { [weak model] path, fragment in model?.navigateToInternalLink(path: path, fragment: fragment) }
            controller.onChapterBoundary = { [weak model] direction, token in
                model?.turnChapter(direction, from: token) ?? false
            }

            try await fixture.withHostedController(controller) {
                // UIKit may omit the recognizer entirely when zooming is unavailable.
                #expect(controller.webView.scrollView.pinchGestureRecognizer?.isEnabled != true)
                #expect(controller.webView.scrollView.zoomScale == 1)
                #expect(controller.webView.scrollView.alwaysBounceVertical == true)
                #expect(controller.webView.scrollView.showsVerticalScrollIndicator == false)

                await model.load()
                let initialRequest = try #require(model.navigationRequest)
                controller.apply(initialRequest)
                try await waitUntilReady(model: model, expectedToken: initialRequest.token)
                try await waitForChapterWindow(controller, count: 3)
                #expect(model.currentToken == initialRequest.token)
                #expect(model.currentPosition?.path == initialRequest.token.path)
                #expect(controller.documentLoadCount == 1)
                _ = try await controller.evaluateLocatorJavaScriptForTesting("window.__continuousDocument = document; window.__continuousNode = document.querySelector('[data-yj-chapter]'); true;")

                let ch1Token = try #require(model.currentToken)
                #expect(ch1Token.path == "OEBPS/text/ch1.xhtml")

                let prevAtFirst = controller.turnPage(.previous, animated: false)
                #expect(prevAtFirst == false)
                #expect(model.currentToken == ch1Token)

                let nextTurned = controller.turnPage(.next, animated: false)
                #expect(nextTurned == true)
                #expect(controller.webView.scrollView.contentOffset.y > 0)
                // UIScrollView updates synchronously; WebKit's DOM scroll position crosses IPC.
                // Wait for the observable result, not an arbitrary immediate JS sample.
                var sampleAfterTurn = await controller.sampleVisibleNow()
                let scrollDeadline = Date().addingTimeInterval(2)
                while (sampleAfterTurn?.scrollY ?? 0) <= 0 && Date() < scrollDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                    sampleAfterTurn = await controller.sampleVisibleNow()
                }
                #expect(sampleAfterTurn != nil)
                #expect((sampleAfterTurn?.scrollY ?? 0) > 0)

                let scroll = controller.webView.scrollView
                // Both sides of the boundary are rendered simultaneously, not a replacement screenshot.
                _ = try await controller.evaluateLocatorJavaScriptForTesting("""
                var next = document.querySelector('[data-yj-chapter="OEBPS/text/ch2.xhtml"]');
                window.scrollTo(0, window.scrollY + next.getBoundingClientRect().top - 100);
                true;
                """)
                let boundarySample = try #require(await controller.sampleVisibleNow())
                #expect(boundarySample.visibleText.contains("EPUB_CH1_END"))
                #expect(boundarySample.visibleText.contains("EPUB_CH2_START"))
                #expect(boundarySample.path == ch1Token.path)
                // One continuous movement crosses the boundary without calling turnChapter.
                controller.scrollViewWillBeginDragging(scroll)
                let draggingProtected = try await controller.evaluateLocatorJavaScriptForTesting("window.__yjEpub.sampleStatus().scrollActive") as? Bool
                #expect(draggingProtected == true)
                _ = try await controller.evaluateLocatorJavaScriptForTesting("""
                window.scrollTo(0, window.scrollY + document.querySelector('[data-yj-chapter="OEBPS/text/ch2.xhtml"]').getBoundingClientRect().top + 20);
                true;
                """)
                let crossed = try #require(await controller.sampleVisibleNow())
                model.handleLocatorEvent(crossed)
                controller.scrollViewDidEndDragging(scroll, willDecelerate: true)
                let decelerationProtected = try await controller.evaluateLocatorJavaScriptForTesting("window.__yjEpub.sampleStatus().scrollActive") as? Bool
                #expect(decelerationProtected == true)
                try await waitForNewToken(model: model, previous: ch1Token)
                let ch2Request = try #require(model.navigationRequest)
                #expect(ch2Request.token.path == "OEBPS/text/ch2.xhtml")
                #expect(ch2Request.reloadDocument == false && ch2Request.preserveViewport)
                try await waitUntilReady(model: model, expectedToken: ch2Request.token)
                let promotionProtected = try await controller.evaluateLocatorJavaScriptForTesting("window.__yjEpub.sampleStatus().scrollActive") as? Bool
                #expect(promotionProtected == true)
                controller.scrollViewDidEndDecelerating(scroll)
                let idleProtected = try await controller.evaluateLocatorJavaScriptForTesting("window.__yjEpub.sampleStatus().scrollActive") as? Bool
                #expect(idleProtected == false)
                let ch2Token = try #require(model.currentToken)
                #expect(controller.documentLoadCount == 1)
                #expect(!model.loading)
                let retained = try await controller.evaluateLocatorJavaScriptForTesting("document === window.__continuousDocument && document.querySelector('[data-yj-chapter]') === window.__continuousNode") as? Bool
                #expect(retained == true)
                let crossingSample = await controller.sampleVisibleNow()
                if crossingSample == nil {
                    let diagnostic = try await controller.evaluateLocatorJavaScriptForTesting("""
                    (function() {
                        var p = window.__yjEpub.sampleNow();
                        return JSON.stringify({status: window.__yjEpub.sampleStatus(), sampled: p !== null,
                            epochMatches: p ? p.epoch === "\(ch2Token.epoch.uuidString)" : null,
                            pathMatches: p ? p.path === "\(ch2Token.path)" : null,
                            scrollY: window.scrollY, expectedY: \(crossed.scrollY)});
                    })();
                    """)
                    print("EPUB_SYNTHETIC_CROSSING tokenMatches=\(model.currentToken == ch2Token) ready=\(model.ready) diagnostic=\(String(describing: diagnostic))")
                }
                let afterCrossing = try #require(crossingSample)
                #expect(abs(afterCrossing.scrollY - crossed.scrollY) < 2)
                let positionBeforeStale = model.currentPosition
                model.handleLocatorEvent(boundarySample) // old epoch cannot move progress back
                #expect(model.currentPosition == positionBeforeStale)
                #expect(model.turnChapter(.next, from: ch1Token) == false)
                controller.interactionEnabled = false
                #expect(controller.turnPage(.next, animated: false) == false)
                controller.interactionEnabled = true

                _ = try await controller.evaluateLocatorJavaScriptForTesting("""
                window.scrollTo(0, window.scrollY + document.querySelector('[data-yj-chapter="OEBPS/text/ch2.xhtml"]').getBoundingClientRect().top - 100);
                true;
                """)
                let backwardSample = await controller.sampleVisibleNow()
                if backwardSample == nil {
                    let diagnostic = try await controller.evaluateLocatorJavaScriptForTesting("""
                    (function() {
                        var p = window.__yjEpub.sampleNow();
                        return JSON.stringify({status: window.__yjEpub.sampleStatus(), sampled: p !== null,
                            epochMatches: p ? p.epoch === "\(ch2Token.epoch.uuidString)" : null,
                            pathMatches: p ? p.path === "OEBPS/text/ch1.xhtml" : null,
                            scrollY: window.scrollY});
                    })();
                    """)
                    print("EPUB_SYNTHETIC_BACKWARD tokenMatches=\(model.currentToken == ch2Token) ready=\(model.ready) diagnostic=\(String(describing: diagnostic))")
                }
                let backwards = try #require(backwardSample)
                model.handleLocatorEvent(backwards)
                try await waitForNewToken(model: model, previous: ch2Token)
                let backRequest = try #require(model.navigationRequest)
                #expect(backRequest.token.path == "OEBPS/text/ch1.xhtml")
                #expect(backRequest.preserveViewport && !backRequest.reloadDocument)
                let backToken = backRequest.token
                #expect(controller.documentLoadCount == 1)
                #expect(backwards.visibleText.contains("EPUB_CH1_END"))

                let ch3Item = try #require(model.navigationItems.first(where: { $0.path.contains("ch3") }))
                try await waitUntilReady(model: model, expectedToken: backToken)
                let positionBeforeJump = model.currentPosition
                let obsoleteScroll = EPUBLocatorPayload(
                    kind: .scroll, sessionID: backToken.sessionID, epoch: backToken.epoch,
                    path: "OEBPS/text/ch2.xhtml", node: 0, utf16Offset: 0,
                    restoredNode: 0, restoredOffset: 0, scrollY: 400,
                    viewportHeight: 700, contentHeight: 2400, visibleText: "obsolete", reason: nil
                )
                let firstItem = try #require(model.navigationItems.first(where: { $0.path == backToken.path }))
                model.go(to: firstItem) // superseded before either queued task can run
                let loadsBeforeJump = controller.documentLoadCount
                model.go(to: ch3Item)
                #expect(model.currentToken == nil && !model.ready && model.loading)
                model.handleLocatorEvent(obsoleteScroll) // no await: the previously unguarded race window
                model.handleLoadFailure(EPUBError.corruptResource, token: backToken)
                #expect(model.currentPosition == positionBeforeJump)
                #expect(model.currentToken == nil && model.message == nil)
                try await waitForNewToken(model: model, previous: backToken)
                let ch3Request = try #require(model.navigationRequest)
                #expect(ch3Request.token.path == "OEBPS/text/ch3.xhtml")
                controller.apply(ch3Request)
                try await waitUntilReady(model: model, expectedToken: ch3Request.token)
                try await waitForChapterWindow(controller, count: 3)
                let ch3Token = try #require(model.currentToken)
                #expect(ch3Token.path == "OEBPS/text/ch3.xhtml")
                #expect(controller.documentLoadCount == loadsBeforeJump)
                let targetSample = try #require(await controller.sampleVisibleNow())
                #expect(targetSample.path == ch3Item.path)
                #expect(!targetSample.visibleText.isEmpty)
                let sameDocument = try await controller.evaluateLocatorJavaScriptForTesting("document === window.__continuousDocument") as? Bool
                #expect(sameDocument == true)

                let ch3Scroll = controller.webView.scrollView
                let ch3Max = max(0, ch3Scroll.contentSize.height - ch3Scroll.bounds.height)
                ch3Scroll.setContentOffset(CGPoint(x: 0, y: ch3Max), animated: false)
                let lastChapterNext = controller.turnPage(.next, animated: false)
                #expect(lastChapterNext == false)
                #expect(model.turnChapter(.next, from: ch3Token) == false)

                let lastSample = await controller.sampleVisibleNow()
                if let lastSample {
                    model.handleLocatorEvent(lastSample)
                }
                let closed = await model.close()
                #expect(closed == true)
            }

            let reopened = try await fixture.service.openEPUB(id: receipt.book.id)
            #expect(reopened.reading.position?.path == "OEBPS/text/ch3.xhtml")
            try await reopened.close(position: nil, sequence: 1, token: nil, preferences: reopened.preferences)
        }
    }

    private func waitForChapterWindow(_ controller: EPUBWebViewController, count: Int) async throws {
        let deadline = Date().addingTimeInterval(12)
        while controller.renderedChapterPaths.count != count && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.renderedChapterPaths.count == count)
        #expect(controller.renderedChapterPaths.count <= EPUBChapterWindow.maximumChapters)
    }

    private func verifyHorizontalPagination() async throws {
        let savedMode = UserDefaults.standard.object(forKey: EPUBReadingMode.defaultsKey)
        defer {
            if let savedMode { UserDefaults.standard.set(savedMode, forKey: EPUBReadingMode.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: EPUBReadingMode.defaultsKey) }
        }
        try await withHostFixture { fixture in
            let archive = fixture.root.appendingPathComponent("Horizontal.epub")
            try EPUBUITestFixture.writeIllustratedEPUB(to: archive, title: "Horizontal Pages")
            let receipt = try await fixture.install(archive)
            let model = EPUBReaderViewModel(bookID: receipt.book.id, service: fixture.service, readingMode: .paged)
            let controller = EPUBWebViewController()
            model.webView.attach(controller)
            controller.onLocatorEvent = { payload in
                print("EPUB_SYNTHETIC_HORIZONTAL_EVENT kind=\(payload.kind) node=\(payload.node) restored=\(payload.restoredNode) offset=\(payload.restoredOffset) tokenMatches=\(payload.epoch == model.currentToken?.epoch) ready=\(model.ready) loading=\(model.loading)")
                model.handleLocatorEvent(payload)
            }
            controller.onLoadFailure = { error, token in
                let failure = error as NSError
                print("EPUB_SYNTHETIC_HORIZONTAL_LOAD_FAILURE domain=\(failure.domain) code=\(failure.code) tokenMatches=\(token == model.currentToken)")
                model.handleLoadFailure(error, token: token)
            }
            controller.onChapterBoundary = { model.turnChapter($0, from: $1) }
            try await fixture.withHostedController(controller) {
                await model.load()
                let first = try #require(model.navigationRequest)
                controller.apply(first)
                print("EPUB_SYNTHETIC_HORIZONTAL_START mode=\(first.readingMode) bounds=\(controller.webView.bounds) hosted=\(controller.webView.window != nil)")
                do {
                    try await waitUntilReady(model: model, expectedToken: first.token)
                } catch {
                    print("EPUB_SYNTHETIC_HORIZONTAL_FAILURE ready=\(model.ready) loading=\(model.loading) message=\(String(describing: model.message)) requestPresent=\(model.navigationRequest != nil) activeRequestPresent=\(controller.activeRequest != nil) loads=\(controller.documentLoadCount) chapters=\(controller.renderedChapterPaths.count) denied=\(controller.deniedNavigations.count) webLoading=\(controller.webView.isLoading) progress=\(controller.webView.estimatedProgress) bounds=\(controller.webView.bounds) contentSize=\(controller.webView.scrollView.contentSize) hidden=\(controller.webView.isHidden) hosted=\(controller.webView.window != nil)")
                    throw error
                }
                try await waitForChapterWindow(controller, count: 3)
                let scroll = controller.webView.scrollView
                #expect(controller.documentLoadCount == 1)
                #expect(scroll.contentSize.width > scroll.bounds.width * 2)
                #expect(!scroll.panGestureRecognizer.isEnabled)
                #expect(controller.turnPage(.next, animated: false))
                #expect(abs(scroll.contentOffset.x - scroll.bounds.width) < 2)
                #expect(abs(scroll.contentOffset.y) < 1)
                var payload = await controller.sampleVisibleNow()
                let deadline = Date().addingTimeInterval(2)
                while (payload?.scrollX ?? 0) < 1 && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                    payload = await controller.sampleVisibleNow()
                }
                let visible = try #require(payload)
                #expect(visible.scrollX > 0 && visible.scrollY == 0)
                model.handleLocatorEvent(visible)
                let anchor = try #require(model.currentPosition)
                model.setReadingMode(.scroll)
                try await waitForNewToken(model: model, previous: first.token)
                let vertical = try #require(model.navigationRequest)
                controller.apply(vertical)
                try await waitUntilReady(model: model, expectedToken: vertical.token)
                #expect(model.currentPosition == anchor)
                #expect(controller.documentLoadCount == 1)
                #expect(scroll.panGestureRecognizer.isEnabled)
                #expect(scroll.contentSize.height > scroll.bounds.height)
                #expect(abs(scroll.contentOffset.x) < 1)
                let closed = await model.close()
                #expect(closed)
            }
        }
    }
}

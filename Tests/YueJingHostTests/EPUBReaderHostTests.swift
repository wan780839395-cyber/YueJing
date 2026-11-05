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
    @Test func epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position() async throws {
        try await withHostFixture { fixture in
            let archiveURL = fixture.root.appendingPathComponent("Illustrated.epub")
            try EPUBUITestFixture.writeIllustratedEPUB(to: archiveURL, title: "Host Illustrated")
            let receipt = try await fixture.install(archiveURL)
            let reader = try await fixture.service.openEPUB(id: receipt.book.id)
            let path = try #require(reader.publication.package.spine.first)
            let token = try await reader.beginNavigation(path: path)

            let sampleText = "A😀e\u{301}尾"
            #expect(EPUBLocationScript.snapUTF16OffsetToCharacterBoundary(-1, in: sampleText) == nil)
            #expect(EPUBLocationScript.snapUTF16OffsetToCharacterBoundary(999, in: sampleText) == nil)
            // Surrogate pair interior (offset 2 inside 😀 at UTF-16 1..<3) snaps to 1.
            #expect(EPUBLocationScript.snapUTF16OffsetToCharacterBoundary(2, in: sampleText) == 1)
            // Combining acute interior (offset 4 inside e\u{301} at UTF-16 3..<5) snaps to 3.
            #expect(EPUBLocationScript.snapUTF16OffsetToCharacterBoundary(4, in: sampleText) == 3)

            let controller = EPUBWebViewController()
            try await fixture.withHostedController(controller) {
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

                #expect(try await reader.markReady(token))
                let nodes = try #require(reader.publication.package.textNodes[path])
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
            let nodes = try #require(reader.publication.package.textNodes[path])

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
                let ch1Nodes = try #require(package.textNodes[firstToken.path])
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
                try await waitUntilReady(model: model, expectedToken: ch2Request.token, minimumNode: 6)
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
            #expect(reader.publication.package.textNodes[path] == ["图片页"])
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

    // MARK: - Helpers

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
        func withHostedController(_ controller: UIViewController, _ body: @MainActor () async throws -> Void) async throws {
            let scene = try #require(
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first
            )
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
            defer {
                if let webController = controller as? EPUBWebViewController {
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
                _ = try await controller.evaluateLocatorJavaScriptForTesting("""
                window.scrollTo(0, window.scrollY + document.querySelector('[data-yj-chapter="OEBPS/text/ch2.xhtml"]').getBoundingClientRect().top + 20);
                true;
                """)
                let crossed = try #require(await controller.sampleVisibleNow())
                model.handleLocatorEvent(crossed)
                controller.scrollViewDidEndDragging(scroll, willDecelerate: false)
                try await waitForNewToken(model: model, previous: ch1Token)
                let ch2Request = try #require(model.navigationRequest)
                #expect(ch2Request.token.path == "OEBPS/text/ch2.xhtml")
                #expect(ch2Request.reloadDocument == false && ch2Request.preserveViewport)
                try await waitUntilReady(model: model, expectedToken: ch2Request.token)
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
                model.go(to: ch3Item)
                try await waitForNewToken(model: model, previous: backToken)
                let ch3Request = try #require(model.navigationRequest)
                #expect(ch3Request.token.path == "OEBPS/text/ch3.xhtml")
                controller.apply(ch3Request)
                try await waitUntilReady(model: model, expectedToken: ch3Request.token)
                try await waitForChapterWindow(controller, count: 3)
                let ch3Token = try #require(model.currentToken)
                #expect(ch3Token.path == "OEBPS/text/ch3.xhtml")

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
            controller.onLocatorEvent = { model.handleLocatorEvent($0) }
            controller.onLoadFailure = { model.handleLoadFailure($0, token: $1) }
            controller.onChapterBoundary = { model.turnChapter($0, from: $1) }
            try await fixture.withHostedController(controller) {
                await model.load()
                let first = try #require(model.navigationRequest)
                controller.apply(first)
                try await waitUntilReady(model: model, expectedToken: first.token)
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

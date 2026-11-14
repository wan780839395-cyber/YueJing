import Foundation
import ReaderDomain
import Testing
import UIKit
import WebKit
import XCTest
@testable import YueJing

/// Real decodable font loading verification supplementing existing mocked/structural-stub font tests.
///
/// Generator provenance for `syntheticGeometricFontBase64`:
/// - Script: `scripts/make_epub_test_font.py` (stdlib-only Python, deterministic SFNT TrueType)
/// - Command: `python scripts/make_epub_test_font.py --json`
/// - Byte length: 1144 bytes
/// - SHA-256: `48133841ef978419f320fdb833e1630f651a5eff7b0da2d0a3413b67c94c59dd`
/// - Font metadata: family `YueJingTestGeometric`, `unitsPerEm = 1000`, ascent `800`, descent `-200`
/// - Tables: `OS/2`, `cmap`, `glyf`, `head`, `hhea`, `hmtx`, `loca`, `maxp`, `name`, `post`
/// - Glyphs & metrics:
///   - GID 0 (`.notdef`): hollow geometric frame, `advanceWidth = 1000`, `lsb = 100`
///   - GID 1 (`space`, `U+0020`): empty outline, `advanceWidth = 1000`, `lsb = 0`
///   - GID 2 (`A`, `U+0041`): geometric outline, `advanceWidth = 2500` (`2.5em`), `lsb = 100`
@MainActor
@Suite(.serialized)
struct EPUBFontLoadingHostTests {
    private static let waitTimeoutSeconds: TimeInterval = 12
    private static let syntheticFontByteCount = 1144
    private static let syntheticFontSHA256 = "48133841ef978419f320fdb833e1630f651a5eff7b0da2d0a3413b67c94c59dd"

    private static let syntheticGeometricFontBase64 = """
    AAEAAAAKAIAAAwAgT1MvMmYUbsEAAACsAAAAYGNtYXAAdABcAAABDAAAADxnbHlmvb57sgAAAUgA
    AACAaGVhZC8KPKEAAAHIAAAANmhoZWEM5glkAAACAAAAACRobXR4EZQAyAAAAiQAAAAMbG9jYQAc
    AFwAAAIwAAAACG1heHAABgANAAACOAAAACBuYW1lrwA06wAAAlgAAAH4cG9zdP+kAFYAAARQAAAA
    KAAEBdwBkAAFAAACigJYAAAASwKKAlgAAAFeADIA+gAAAgAFAwAAAAAAAAAAAAEAAAAAAAAAAAAA
    AABZSlRGAMAAIABBAyD/OAAAAyAAyAAAAAEAAAAAAfQCvAAAACAAAAAAAAIAAAADAAAAFAADAAEA
    AAAUAAQAKAAAAAYABAABAAIAIABB//8AAAAgAEH////h/8EAAQAAAAAAAAACAGQAAAOEArwAAwAH
    AAABAQEBAQEBAQBkAAADIAAA/UQCWAAA/agAAAK8AAD9RABkAAAB9AAAAAIAZAAACWACvAAHAAoA
    AAEBAQEBAQEBAQEBAGQDtgGQA7b+Pv8a/FT/GgFyApT+tgAAArwAAP1EAAAAyAAA/zgBQAAAAPAA
    AAEAAAABAABkdcbZXw889QADA+gAAAAA4xf8gAAAAADjF/yAAGQAAAlgArwAAAAIAAIAAAAAAAAA
    AQAAAyD/OAAACcQAZABkCWAAAQAAAAAAAAAAAAAAAAAAAAMD6ABkA+gAAAnEAGQAAAAcABwAQAABA
    AAAAwALAAIAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAADACWAAEAAAAAAAEAFAAAAAEAAAAAAAIABw
    AUAAEAAAAAAAMAGAAbAAEAAAAAAAQAHAAzAAEAAAAAAAUACwBPAAEAAAAAAAYAHABaAAMAAQQJAA
    EAKAB2AAMAAQQJAAIADgCeAAMAAQQJAAMAMACsAAMAAQQJAAQAOADcAAMAAQQJAAUAFgEUAAMAAQ
    QJAAYAOAEqWXVlSmluZ1Rlc3RHZW9tZXRyaWNSZWd1bGFyWXVlSmluZ1Rlc3RHZW9tZXRyaWMtMS
    4wWXVlSmluZ1Rlc3RHZW9tZXRyaWMgUmVndWxhclZlcnNpb24gMS4wWXVlSmluZ1Rlc3RHZW9tZX
    RyaWMtUmVndWxhcgBZAHUAZQBKAGkAbgBnAFQAZQBzAHQARwBlAG8AbQBlAHQAcgBpAGMAUgBlAG
    cAdQBsAGEAcgBZAHUAZQBKAGkAbgBnAFQAZQBzAHQARwBlAG8AbQBlAHQAcgBpAGMALQAxAC4AMA
    BZAHUAZQBKAGkAbgBnAFQAZQBzAHQARwBlAG8AbQBlAHQAcgBpAGMAIABSAGUAZwB1AGwAYQByAF
    YAZQByAHMAaQBvAG4AIAAxAC4AMABZAHUAZQBKAGkAbgBnAFQAZQBzAHQARwBlAG8AbQBlAHQAcg
    BpAGMALQBSAGUAZwB1AGwAYQByAAIAAAAAAAD/nAAyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwAAAAMA
    JA==
    """

    @Test func epubWebKitDecodesSyntheticFontServesResourceAndMeasuresGlyphMetrics() async throws {
        let fontData = try Self.makeSyntheticGeometricFontData()
        #expect(try EPUBAuthorStyles.verifyFontData(fontData, declaredMediaType: "font/ttf") == "font/ttf")
        #expect(try EPUBAuthorStyles.verifyFontData(fontData, declaredMediaType: "font/otf") == "font/ttf")

        try await withHostFixture { fixture in
            let archiveURL = fixture.root.appendingPathComponent("SyntheticFont.epub")
            let fontPath = "OEBPS/Fonts/SyntheticGeometric.ttf"
            let chapterPath = "OEBPS/Text/ch1.xhtml"
            try Self.writeFontTestEPUB(
                to: archiveURL,
                title: "Synthetic Geometric Font",
                fontFileName: "SyntheticGeometric.ttf",
                fontData: fontData,
                declaredFontMediaType: "font/otf" // Actual TrueType bytes must still decode and serve as font/ttf.
            )

            // Exercise production EPUBPackageParser + EPUBContentPolicy + EPUBAuthorStyles directly
            // and via LibraryService import + content pool.
            let parseDir = fixture.root.appendingPathComponent("DirectParse", isDirectory: true)
            let directPackage = try EPUBPackageParser.parse(archiveURL: archiveURL, destination: parseDir)
            #expect(directPackage.authorStyleRevision == EPUBFormat.authorStyleRevision)
            #expect(directPackage.resource(at: fontPath)?.mediaType == "font/ttf")
            #expect(directPackage.resource(at: fontPath)?.sha256 == Self.syntheticFontSHA256)
            #expect(directPackage.resource(at: "OEBPS/Styles/font.css") == nil)

            let receipt = try await fixture.install(archiveURL)
            let reader1 = try await fixture.service.openEPUB(id: receipt.book.id)
            let scopeID = EPUBAuthorStyles.scopeIdentifier(for: chapterPath)
            let expectedScopedFamily = "yjfont-\(scopeID)-0"

            let sanitizedXHTML = try EPUBResourceStore.data(path: chapterPath, publication: reader1.publication)
            let sanitizedText = String(decoding: sanitizedXHTML, as: UTF8.self)
            #expect(sanitizedText.contains("data-yj-author-style=\"true\""))
            #expect(sanitizedText.contains(expectedScopedFamily))
            #expect(sanitizedText.contains("url(\"/\(fontPath)\")"))
            #expect(!sanitizedText.contains("AuthorDisplayFace"))

            let token1 = try await reader1.beginNavigation(path: chapterPath)
            let controller1 = EPUBWebViewController()
            try await fixture.withHostedController(controller1) {
                let result1 = try await loadAndAwaitOutcome(
                    controller: controller1,
                    request: EPUBNavigationRequest(
                        id: UUID(),
                        token: token1,
                        publication: reader1.publication,
                        targetPosition: nil,
                        fragment: nil,
                        preferences: reader1.preferences,
                        preserveTargetAnchor: false,
                        reloadDocument: true,
                        layoutMode: .original
                    )
                )
                guard case .ready(let payload1, let readyCount1, let servedAtReady1, let rejectedAtReady1) = result1 else {
                    Issue.record("Expected ready outcome after decoding synthetic font, got: \(result1)")
                    return
                }
                #expect(readyCount1 == 1)
                #expect(!payload1.authorStyleFallback)
                #expect(payload1.sessionID == reader1.reading.session.id)
                #expect(payload1.epoch == token1.epoch)
                #expect(payload1.path == chapterPath)
                #expect(servedAtReady1.contains(chapterPath))
                #expect(servedAtReady1.contains(fontPath))
                #expect(rejectedAtReady1.isEmpty)

                let snapshot1 = try await inspectLoadedFontsAndMetrics(in: controller1)
                try verifyLoadedFontAndMetrics(
                    snapshot: snapshot1,
                    expectedScopedFamily: expectedScopedFamily,
                    expectedCapabilityHost: EPUBResourceCapability.host(for: token1),
                    fontPath: fontPath
                )
            }
            try await reader1.close(position: nil, sequence: 1, token: nil, preferences: reader1.preferences)

            // Reopen the same imported EPUB with a fresh LibraryService, session, capability host, and WKWebView.
            let freshService = LibraryService(store: try LibraryStore(root: fixture.managedRoot))
            let reader2 = try await freshService.openEPUB(id: receipt.book.id)
            let token2 = try await reader2.beginNavigation(path: chapterPath)
            #expect(token2.sessionID != token1.sessionID)
            #expect(token2.epoch != token1.epoch)
            let host1 = EPUBResourceCapability.host(for: token1)
            let host2 = EPUBResourceCapability.host(for: token2)
            #expect(host2 != host1)

            let controller2 = EPUBWebViewController()
            try await fixture.withHostedController(controller2) {
                let result2 = try await loadAndAwaitOutcome(
                    controller: controller2,
                    request: EPUBNavigationRequest(
                        id: UUID(),
                        token: token2,
                        publication: reader2.publication,
                        targetPosition: nil,
                        fragment: nil,
                        preferences: reader2.preferences,
                        preserveTargetAnchor: false,
                        reloadDocument: true,
                        layoutMode: .original
                    )
                )
                guard case .ready(let payload2, let readyCount2, let servedAtReady2, let rejectedAtReady2) = result2 else {
                    Issue.record("Expected ready outcome after fresh session/capability reopen, got: \(result2)")
                    return
                }
                #expect(readyCount2 == 1)
                #expect(!payload2.authorStyleFallback)
                #expect(payload2.sessionID == reader2.reading.session.id)
                #expect(payload2.epoch == token2.epoch)
                #expect(servedAtReady2.contains(chapterPath))
                #expect(servedAtReady2.contains(fontPath))
                #expect(rejectedAtReady2.isEmpty)

                let snapshot2 = try await inspectLoadedFontsAndMetrics(in: controller2)
                try verifyLoadedFontAndMetrics(
                    snapshot: snapshot2,
                    expectedScopedFamily: expectedScopedFamily,
                    expectedCapabilityHost: host2,
                    fontPath: fontPath
                )
            }
            try await reader2.close(position: nil, sequence: 1, token: nil, preferences: reader2.preferences)
        }
    }

    @Test func epubWebKitGatesReadinessOnFontDecodingAndRebindsCapabilityAcrossEpochs() async throws {
        try await withHostFixture { fixture in
            // 1. A structural-only SFNT stub passes EPUBAuthorStyles.verifyFontData and SHA checks
            //    in EPUBResourceHandler, but fails real WebKit FontFace decoding -> must remove the
            //    unusable @font-face rule, settle layout with fallback glyph metrics, preserve the
            //    requested anchor, emit ready with authorStyleFallback=true, keep failed rules
            //    absent on epoch promotion, and reject stale epoch callbacks.
            let stubFont = Self.makeStructuralOnlySFNTStub()
            #expect(try EPUBAuthorStyles.verifyFontData(stubFont, declaredMediaType: "font/ttf") == "font/ttf")

            let brokenArchiveURL = fixture.root.appendingPathComponent("BrokenFontStub.epub")
            let brokenFontPath = "OEBPS/Fonts/BrokenStub.ttf"
            let chapterPath = "OEBPS/Text/ch1.xhtml"
            try Self.writeFontTestEPUB(
                to: brokenArchiveURL,
                title: "Broken Font Stub",
                fontFileName: "BrokenStub.ttf",
                fontData: stubFont
            )
            let brokenReceipt = try await fixture.install(brokenArchiveURL)
            let brokenReader = try await fixture.service.openEPUB(id: brokenReceipt.book.id)
            let brokenToken = try await brokenReader.beginNavigation(path: chapterPath)
            let expectedAnchor = try EPUBLocationScript.makeValidatedPosition(
                bookID: brokenReader.book.id,
                package: brokenReader.publication.package,
                path: chapterPath,
                node: 1,
                rawUTF16Offset: 2,
                viewportOffset: 24
            )
            let brokenController = EPUBWebViewController()
            try await fixture.withHostedController(brokenController) {
                let outcome = try await loadAndAwaitOutcome(
                    controller: brokenController,
                    request: EPUBNavigationRequest(
                        id: UUID(),
                        token: brokenToken,
                        publication: brokenReader.publication,
                        targetPosition: expectedAnchor,
                        fragment: nil,
                        preferences: brokenReader.preferences,
                        preserveTargetAnchor: true,
                        reloadDocument: true,
                        layoutMode: .original
                    )
                )
                guard case .ready(let payload, let readyCount, let servedAtReady, let rejectedAtReady) = outcome else {
                    Issue.record("Expected fallback ready outcome for structural-only SFNT stub, got: \(outcome)")
                    return
                }
                #expect(readyCount == 1)
                #expect(payload.kind == .ready)
                #expect(payload.sessionID == brokenReader.reading.session.id)
                #expect(payload.epoch == brokenToken.epoch)
                #expect(payload.path == chapterPath)
                #expect(payload.authorStyleFallback == true)
                #expect(payload.restoredNode == expectedAnchor.node)
                #expect(payload.restoredOffset == expectedAnchor.utf16Offset)
                #expect(servedAtReady.contains(chapterPath))
                #expect(servedAtReady.contains(brokenFontPath))
                #expect(rejectedAtReady.isEmpty)
                #expect(try await brokenReader.markReady(brokenToken))

                let sampled = try #require(await brokenController.sampleVisibleNow())
                #expect(sampled.epoch == brokenToken.epoch)
                #expect(sampled.authorStyleFallback == true)
                #expect(sampled.node == expectedAnchor.node)
                #expect(sampled.utf16Offset == expectedAnchor.utf16Offset)

                let brokenSnapshot = try await inspectLoadedFontsAndMetrics(in: brokenController)
                #expect(brokenSnapshot["layout"] as? String == "original")
                #expect(brokenSnapshot["fontSetStatus"] as? String == "loaded")
                #expect((brokenSnapshot["fontSetSize"] as? NSNumber)?.intValue == 0)
                let brokenRules = try #require(brokenSnapshot["fontFaceRules"] as? [[String: Any]])
                #expect(brokenRules.isEmpty)
                let brokenStyleTexts = brokenSnapshot["authorStyleTexts"] as? [String] ?? []
                #expect(!brokenStyleTexts.isEmpty)
                #expect(brokenStyleTexts.allSatisfy { !$0.contains("@font-face") && !$0.contains(brokenFontPath) })
                #expect(brokenStyleTexts.contains { $0.contains("24px") })

                let customAAAA = try #require(brokenSnapshot["customAAAA"] as? [String: Any])
                let fallbackAAAA = try #require(brokenSnapshot["fallbackAAAA"] as? [String: Any])
                #expect(customAAAA["text"] as? String == "AAAA")
                #expect(customAAAA["fontSize"] as? String == "24px")
                #expect((customAAAA["clientRectCount"] as? NSNumber)?.intValue == 1)
                let widthCustomAAAA = try #require((customAAAA["rangeWidth"] as? NSNumber)?.doubleValue)
                let widthFallbackAAAA = try #require((fallbackAAAA["rangeWidth"] as? NSNumber)?.doubleValue)
                #expect(widthCustomAAAA > 20.0 && widthCustomAAAA < 110.0)
                #expect(abs(widthCustomAAAA - widthFallbackAAAA) <= 2.0)

                // Promoting / rebinding capability on the degraded document must not resurrect the
                // failed @font-face rule or re-request the broken font, and old epoch callbacks are rejected.
                let servedBrokenBeforePromo = brokenController.resourceHandler.servedPaths.filter { $0 == brokenFontPath }.count
                let brokenEpoch2 = try await brokenReader.beginNavigation(path: chapterPath)
                let promoOutcome = try await loadAndAwaitOutcome(
                    controller: brokenController,
                    request: EPUBNavigationRequest(
                        id: UUID(),
                        token: brokenEpoch2,
                        publication: brokenReader.publication,
                        targetPosition: nil,
                        fragment: nil,
                        preferences: brokenReader.preferences,
                        preserveTargetAnchor: false,
                        reloadDocument: false,
                        preserveViewport: true,
                        layoutMode: .original
                    )
                )
                guard case .ready(let promoPayload, let promoReadyCount, let promoServed, let promoRejected) = promoOutcome else {
                    Issue.record("Expected fallback ready on degraded promotion, got: \(promoOutcome)")
                    return
                }
                #expect(promoReadyCount == 1)
                #expect(promoPayload.epoch == brokenEpoch2.epoch)
                #expect(promoPayload.authorStyleFallback == true)
                #expect(promoRejected.isEmpty)
                #expect(brokenController.documentLoadCount == 1)
                #expect(promoServed.filter { $0 == brokenFontPath }.count == servedBrokenBeforePromo)

                var leakedOldEpoch = false
                brokenController.onLocatorEvent = { incoming in
                    if incoming.epoch == brokenToken.epoch {
                        leakedOldEpoch = true
                    }
                }
                defer { brokenController.onLocatorEvent = nil }
                _ = try await brokenController.evaluateLocatorJavaScriptForTesting(
                    """
                    (function() {
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.yjepubLocator) {
                            window.webkit.messageHandlers.yjepubLocator.postMessage({
                                kind: "ready",
                                sessionID: "\(brokenToken.sessionID)",
                                epoch: "\(brokenToken.epoch.uuidString)",
                                path: "\(chapterPath)",
                                node: 0,
                                utf16Offset: 0,
                                restoredNode: 0,
                                restoredOffset: 0,
                                scrollY: 0,
                                viewportHeight: 760,
                                contentHeight: 760,
                                visibleText: "stale"
                            });
                        }
                        return true;
                    })();
                    """
                )
                await Task.yield()
                #expect(!leakedOldEpoch)
                #expect((await brokenController.sampleVisibleNow())?.epoch == brokenEpoch2.epoch)
            }
            try await brokenReader.close(position: nil, sequence: 1, token: nil, preferences: brokenReader.preferences)
            // 2. A fresh epoch retains decoded fonts in the same DOM without another
            //    request. Retained bytes never grant request authority to the old URL.
            let fontData = try Self.makeSyntheticGeometricFontData()
            let validArchiveURL = fixture.root.appendingPathComponent("ValidEpochRebind.epub")
            let validFontPath = "OEBPS/Fonts/SyntheticGeometric.ttf"
            try Self.writeFontTestEPUB(
                to: validArchiveURL,
                title: "Valid Epoch Rebind",
                fontFileName: "SyntheticGeometric.ttf",
                fontData: fontData
            )
            let validReceipt = try await fixture.install(validArchiveURL)
            let reader = try await fixture.service.openEPUB(id: validReceipt.book.id)
            let scopeID = EPUBAuthorStyles.scopeIdentifier(for: chapterPath)
            let expectedScopedFamily = "yjfont-\(scopeID)-0"

            let epoch1 = try await reader.beginNavigation(path: chapterPath)
            let controller = EPUBWebViewController()
            try await fixture.withHostedController(controller) {
                let firstOutcome = try await loadAndAwaitOutcome(
                    controller: controller,
                    request: EPUBNavigationRequest(
                        id: UUID(),
                        token: epoch1,
                        publication: reader.publication,
                        targetPosition: nil,
                        fragment: nil,
                        preferences: reader.preferences,
                        preserveTargetAnchor: false,
                        reloadDocument: true,
                        layoutMode: .original
                    )
                )
                guard case .ready(let payload1, let readyCount1, let served1, let rejected1) = firstOutcome else {
                    Issue.record("Expected initial ready for epoch1, got: \(firstOutcome)")
                    return
                }
                #expect(readyCount1 == 1)
                #expect(!payload1.authorStyleFallback)
                #expect(rejected1.isEmpty)
                let servedFontCount1 = served1.filter { $0 == validFontPath }.count
                #expect(servedFontCount1 >= 1)
                #expect(controller.documentLoadCount == 1)
                let epoch2 = try await reader.beginNavigation(path: chapterPath)
                #expect(epoch2.epoch != epoch1.epoch)
                let secondOutcome = try await loadAndAwaitOutcome(
                    controller: controller,
                    request: EPUBNavigationRequest(
                        id: UUID(),
                        token: epoch2,
                        publication: reader.publication,
                        targetPosition: nil,
                        fragment: nil,
                        preferences: ReaderPreferences(fontSize: 20, lineSpacing: 10, theme: .dark),
                        preserveTargetAnchor: false,
                        reloadDocument: false,
                        layoutMode: .original
                    )
                )
                guard case .ready(let payload2, let readyCount2, let served2, let rejected2) = secondOutcome else {
                    Issue.record("Expected ready after in-place epoch2 capability rebind, got: \(secondOutcome)")
                    return
                }
                #expect(readyCount2 == 1)
                #expect(!payload2.authorStyleFallback)
                #expect(payload2.epoch == epoch2.epoch)
                #expect(controller.documentLoadCount == 1)
                #expect(rejected2.isEmpty)
                let servedFontCount2 = served2.filter { $0 == validFontPath }.count
                #expect(servedFontCount2 == servedFontCount1)

                let snapshot2 = try await inspectLoadedFontsAndMetrics(in: controller)
                try verifyLoadedFontAndMetrics(
                    snapshot: snapshot2,
                    expectedScopedFamily: expectedScopedFamily,
                    expectedCapabilityHost: EPUBResourceCapability.host(for: epoch1),
                    fontPath: validFontPath
                )

                let scaledToken = try await reader.beginNavigation(path: chapterPath)
                let scaledOutcome = try await loadAndAwaitOutcome(
                    controller: controller,
                    request: EPUBNavigationRequest(id: UUID(), token: scaledToken, publication: reader.publication,
                        targetPosition: nil, fragment: nil,
                        preferences: ReaderPreferences(fontSize: 22, lineSpacing: 10, theme: .dark),
                        preserveTargetAnchor: false, reloadDocument: false, layoutMode: .original)
                )
                guard case .ready(let scaledPayload, let scaledCount, let scaledServed, let scaledRejected) = scaledOutcome else {
                    Issue.record("Expected ready with actual 110% author text scale")
                    return
                }
                #expect(scaledCount == 1 && !scaledPayload.authorStyleFallback && scaledRejected.isEmpty)
                #expect(scaledServed.filter { $0 == validFontPath }.count == servedFontCount1)
                let scaledSnapshot = try await inspectLoadedFontsAndMetrics(in: controller)
                let scaledGlyphs = try #require(scaledSnapshot["customAAAA"] as? [String: Any])
                let scaledWidth = try #require((scaledGlyphs["rangeWidth"] as? NSNumber)?.doubleValue)
                #expect(abs(scaledWidth - 264.0) <= 3.0)
                let scaledSize = Double((scaledGlyphs["fontSize"] as? String ?? "").replacingOccurrences(of: "px", with: ""))
                #expect(scaledSize != nil && abs((scaledSize ?? 0) - 26.4) < 0.1)
                #expect((scaledGlyphs["fontFamily"] as? String)?.contains(expectedScopedFamily) == true)
                #expect(controller.documentLoadCount == 1)
            }

            // 3. Corrupted SHA transport on disk must trigger native failReadiness (loadFailure),
            //    never masquerading as decode fallback ready.
            let diskFontURL = reader.publication.resourceRoot.appendingPathComponent(validFontPath)
            let originalDiskFontData = try Data(contentsOf: diskFontURL)
            var corruptedDiskFontData = originalDiskFontData
            corruptedDiskFontData[corruptedDiskFontData.count - 1] ^= 0xFF
            try corruptedDiskFontData.write(to: diskFontURL)
            defer { try? originalDiskFontData.write(to: diskFontURL) }

            let tamperedToken = try await reader.beginNavigation(path: chapterPath)
            let tamperedController = EPUBWebViewController()
            try await fixture.withHostedController(tamperedController) {
                let tamperedOutcome = try await loadAndAwaitOutcome(
                    controller: tamperedController,
                    request: EPUBNavigationRequest(
                        id: UUID(),
                        token: tamperedToken,
                        publication: reader.publication,
                        targetPosition: nil,
                        fragment: nil,
                        preferences: reader.preferences,
                        preserveTargetAnchor: false,
                        reloadDocument: true,
                        layoutMode: .original
                    )
                )
                guard case .loadFailure(_, let tamperedReadyCount) = tamperedOutcome else {
                    Issue.record("Expected native loadFailure for corrupted SHA font transport, got: \(tamperedOutcome)")
                    return
                }
                #expect(tamperedReadyCount == 0)
                #expect(tamperedController.resourceHandler.rejectedURLs.contains { $0.contains(validFontPath) })
                #expect(await tamperedController.sampleVisibleNow() == nil)
            }
            try await reader.close(position: nil, sequence: 1, token: nil, preferences: reader.preferences)
        }
    }
    @Test func epubWebKitRetriesTimedOutFontOnWarmExplicitOpenWithoutLateReflow() async throws {
        try await withReadinessScriptFixture(image: false) { web, recorder in
            #expect(try await scriptBool(web, """
                window.testLoads = 0;
                window.testFace = {family:'slow',weight:'400',style:'normal',stretch:'normal',status:'unloaded',
                    load:function() {
                        window.testLoads++;
                        if (this.status === 'loaded') return Promise.resolve(this);
                        var face = this;
                        return new Promise(function(resolve) { setTimeout(function() { face.status='loaded';resolve(face); },1800); });
                    }};
                Object.defineProperty(document,'fonts',{configurable:true,value:{forEach:function(fn){fn(window.testFace);},ready:Promise.resolve()}});
                document.querySelector('style[data-yj-author-style]').textContent = '@font-face{font-family:slow;src:url("/OPS/slow.ttf");}';
                window.__yjEpub.configure(window.testConfig('slow','first')); true;
                """))
            try await waitForScriptOutcome(recorder, epoch: "slow")
            let first = try #require(recorder.messages.first { $0["epoch"] as? String == "slow" && $0["kind"] as? String == "ready" })
            #expect(first["authorStyleFallback"] as? Bool == true)
            #expect(first["restoredNode"] as? Int == 6 && first["restoredOffset"] as? Int == 12)
            #expect(try await scriptBool(web, "window.testY=scrollY;window.testCSS=document.querySelector('style[data-yj-author-style]').textContent;window.testNode=document.getElementById('yj-t6');window.testAnchor();"))
            try await waitForScriptBool(web, "window.testFace.status === 'loaded'")
            #expect(try await scriptBool(web, "scrollY === window.testY && document.querySelector('style[data-yj-author-style]').textContent === window.testCSS"))
            #expect(recorder.messages.filter { $0["kind"] as? String == "ready" }.count == 1)
            #expect(try await scriptBool(web, "window.__yjEpub.parkForReopen();window.__yjEpub.configure(window.testConfig('warm','fresh-session'));true;"))
            try await waitForScriptOutcome(recorder, epoch: "warm")
            let warm = try #require(recorder.messages.first { $0["epoch"] as? String == "warm" && $0["kind"] as? String == "ready" })
            #expect(warm["authorStyleFallback"] as? Bool != true)
            #expect(warm["sessionID"] as? String == "fresh-session")
            #expect(warm["restoredNode"] as? Int == 6 && warm["restoredOffset"] as? Int == 12)
            #expect(abs((warm["viewportOffset"] as? Double ?? -100) - 24) <= 1)
            #expect(try await scriptBool(web, "window.testLoads === 2 && window.testNode === document.getElementById('yj-t6') && window.testAnchor() && document.querySelector('style[data-yj-author-style]').textContent.includes('yjepub://s-fresh-session--e-warm/OPS/slow.ttf')"))
        }
    }

    @Test func epubWebKitRejectsInitialBadImageAndDecodeFailureBeforeRetryReady() async throws {
        try await withReadinessScriptFixture(image: true) { web, recorder in
            #expect(try await scriptBool(web, "document.images[0].complete && document.images[0].naturalWidth === 0"))
            #expect(try await scriptBool(web, "window.__yjEpub.configure(window.testConfig('bad','image'));true;"))
            try await waitForScriptOutcome(recorder, epoch: "bad")
            #expect(recorder.messages.contains { $0["epoch"] as? String == "bad" && $0["reason"] as? String == "image-layout-not-ready" })
            #expect(!recorder.messages.contains { $0["kind"] as? String == "ready" || $0["kind"] as? String == "scroll" })
            #expect(try await scriptBool(web, "window.__yjEpub.sampleNow() === null"))
            #expect(try await scriptBool(web, """
                window.testImage=document.images[0];window.testDecode=window.testImage.decode.bind(window.testImage);
                var canvas=document.createElement('canvas');canvas.width=32;canvas.height=80;
                canvas.getContext('2d').fillRect(0,0,32,80);window.testImage.src=canvas.toDataURL('image/png');true;
                """))
            try await waitForScriptBool(web, "window.testImage.complete && window.testImage.naturalWidth === 32")
            #expect(try await scriptBool(web, "window.testImage.decode=function(){return Promise.reject(new Error('controlled decode failure'));};window.__yjEpub.configure(window.testConfig('decode-fail','image'));true;"))
            try await waitForScriptOutcome(recorder, epoch: "decode-fail")
            #expect(recorder.messages.contains { $0["epoch"] as? String == "decode-fail" && $0["kind"] as? String == "error" })
            #expect(try await scriptBool(web, "window.__yjEpub.sampleNow() === null"))
            #expect(try await scriptBool(web, "window.testImage.decode=function(){return new Promise(function(resolve,reject){window.rejectOldImage=reject;});};window.__yjEpub.configure(window.testConfig('old','image'));true;"))
            try await waitForScriptBool(web, "typeof window.rejectOldImage === 'function'")
            #expect(try await scriptBool(web, "window.testImage.decode=window.testDecode;window.__yjEpub.configure(window.testConfig('retry','new-image-session'));window.rejectOldImage(new Error('late old decode'));true;"))
            try await waitForScriptOutcome(recorder, epoch: "retry")
            let ready = try #require(recorder.messages.first { $0["epoch"] as? String == "retry" && $0["kind"] as? String == "ready" })
            #expect(ready["restoredNode"] as? Int == 6 && ready["restoredOffset"] as? Int == 12)
            #expect(abs((ready["viewportOffset"] as? Double ?? -100) - 24) <= 1)
            #expect(!recorder.messages.contains { $0["epoch"] as? String == "old" })
            #expect(!recorder.messages.contains { $0["kind"] as? String == "ready" && $0["epoch"] as? String != "retry" })
            #expect(try await scriptBool(web, "window.testAnchor() && window.__yjEpub.sampleNow().sessionID === 'new-image-session' && window.testImage.naturalWidth === 32"))
        }
    }

    // Actual WKWebView DOM/decoding and production JS; font timing/decode rejection are controlled.
    // This fixture does not claim native resource transport or database save acceptance.
    @MainActor private final class ReadinessMessages: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let payload = message.body as? [String: Any] { messages.append(payload) }
        }
    }

    private func scriptBool(_ web: WKWebView, _ script: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            web.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (value as? Bool) == true) }
            }
        }
    }

    private func waitForScriptBool(_ web: WKWebView, _ script: String) async throws {
        let deadline = Date().addingTimeInterval(Self.waitTimeoutSeconds)
        while Date() < deadline {
            if try await scriptBool(web, script) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try await scriptBool(web, script))
    }

    private func waitForScriptOutcome(_ recorder: ReadinessMessages, epoch: String) async throws {
        let deadline = Date().addingTimeInterval(Self.waitTimeoutSeconds)
        while Date() < deadline {
            if recorder.messages.contains(where: { $0["epoch"] as? String == epoch && ["ready", "error"].contains($0["kind"] as? String ?? "") }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(recorder.messages.contains { $0["epoch"] as? String == epoch })
    }

    private func withReadinessScriptFixture(image: Bool, _ body: @MainActor (WKWebView, ReadinessMessages) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        let host = UIViewController(), configuration = WKWebViewConfiguration(), recorder = ReadinessMessages()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(recorder, name: EPUBLocationScript.handlerName)
        let web = WKWebView(frame: window.bounds, configuration: configuration)
        window.rootViewController = host; window.isHidden = false
        host.view.addSubview(web)
        defer {
            web.stopLoading(); configuration.userContentController.removeScriptMessageHandler(forName: EPUBLocationScript.handlerName)
            window.isHidden = true; window.rootViewController = nil
        }
        let paragraphs = (0..<12).map { "<p><span id=\"yj-t\($0)\">" + String(repeating: "abcdefghij ", count: 40) + "</span></p>" }.joined()
        web.loadHTMLString("<html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"/><style data-yj-author-style=\"true\"></style></head><body data-yj-author-scope=\"test\">" + (image ? "<img src=\"data:image/png;base64,AAAA\"/>" : "") + paragraphs + "</body></html>", baseURL: nil)
        try await waitForScriptBool(web, "document.readyState === 'complete' && !!document.getElementById('yj-t11')")
        #expect(try await scriptBool(web, EPUBLocationScript.bootstrapSource + """
            ;window.testConfig=function(epoch,session){return {sessionID:session,epoch:epoch,path:'OPS/c0.xhtml',chapterIndex:0,
                expectedNodeCount:12,expectedNodeLengths:Array(12).fill(440),targetNode:6,targetOffset:12,
                targetViewportOffset:24,preserveTargetAnchor:true,readingMode:'scroll',layoutMode:'original',
                css:'body{margin:0;padding:16px 20px;font:20px/32px serif;}p{margin:0 0 12px;}'};};
            window.testAnchor=function(){var r=document.createRange(),n=document.getElementById('yj-t6').firstChild;
                r.setStart(n,12);r.setEnd(n,13);return Math.abs(r.getBoundingClientRect().top-24)<=1;};true;
            """))
        try await body(web, recorder)
    }

    @Test func epubWebKitIsolatesFailedCondensedFaceFromNormalFace() async throws {
        let fontData = try Self.makeSyntheticGeometricFontData()
        try await withHostFixture { fixture in
            let archive = fixture.root.appendingPathComponent("MixedFaces.epub")
            let chapterPath = "OEBPS/Text/ch1.xhtml"
            try Self.writeFontTestEPUB(to: archive, title: "Mixed Faces",
                fontFileName: "SyntheticGeometric.ttf", fontData: fontData,
                condensedFontData: Self.makeStructuralOnlySFNTStub())
            let receipt = try await fixture.install(archive)
            let reader = try await fixture.service.openEPUB(id: receipt.book.id)
            let token = try await reader.beginNavigation(path: chapterPath)
            let controller = EPUBWebViewController()
            try await fixture.withHostedController(controller) {
                let outcome = try await loadAndAwaitOutcome(controller: controller,
                    request: EPUBNavigationRequest(id: UUID(), token: token, publication: reader.publication,
                        targetPosition: nil, fragment: nil, preferences: reader.preferences,
                        preserveTargetAnchor: false, reloadDocument: true, layoutMode: .original))
                guard case .ready(let payload, let count, let served, let rejected) = outcome else {
                    Issue.record("Expected isolated condensed-face fallback, got: \(outcome)")
                    return
                }
                #expect(count == 1 && payload.authorStyleFallback)
                #expect(served.contains("OEBPS/Fonts/SyntheticGeometric.ttf"))
                #expect(served.contains("OEBPS/Fonts/CondensedStub.ttf"))
                #expect(rejected.isEmpty)
                let snapshot = try await inspectLoadedFontsAndMetrics(in: controller)
                let rules = try #require(snapshot["fontFaceRules"] as? [[String: Any]])
                #expect(rules.count == 1)
                #expect((rules.first?["src"] as? String)?.contains("SyntheticGeometric.ttf") == true)
                let glyphs = try #require(snapshot["customAAAA"] as? [String: Any])
                let width = try #require((glyphs["rangeWidth"] as? NSNumber)?.doubleValue)
                #expect(abs(width - 240.0) <= 3.0)
            }
            try await reader.close(position: nil, sequence: 1, token: nil, preferences: reader.preferences)
        }
    }

    // MARK: - Helpers

    private enum LocatorOutcome: CustomStringConvertible {
        case ready(payload: EPUBLocatorPayload, readyCount: Int, servedPathsAtReady: [String], rejectedURLsAtReady: [String])
        case locatorError(payload: EPUBLocatorPayload, readyCount: Int)
        case loadFailure(error: Error, readyCount: Int)

        var description: String {
            switch self {
            case .ready(let payload, let readyCount, _, _):
                return "ready(epoch=\(payload.epoch), count=\(readyCount))"
            case .locatorError(let payload, let readyCount):
                return "locatorError(reason=\(payload.reason ?? "nil"), readyCount=\(readyCount))"
            case .loadFailure(let error, let readyCount):
                return "loadFailure(error=\(error), readyCount=\(readyCount))"
            }
        }
    }

    private struct HostFixture {
        let root: URL
        let managedRoot: URL
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

        @MainActor func withHostedController(
            _ controller: EPUBWebViewController,
            _ body: @MainActor () async throws -> Void
        ) async throws {
            let scene = try #require(
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first
            )
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
            defer {
                controller.detachCallbacks()
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
            .appendingPathComponent("YueJing-EPUBFontHost-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let managedRoot = root.appendingPathComponent("Managed", isDirectory: true)
        let store = try LibraryStore(root: managedRoot)
        let service = LibraryService(store: store)
        try await body(HostFixture(root: root, managedRoot: managedRoot, store: store, service: service))
    }

    private func loadAndAwaitOutcome(
        controller: EPUBWebViewController,
        request: EPUBNavigationRequest
    ) async throws -> LocatorOutcome {
        let settledExpectation = XCTestExpectation(description: "EPUB WebKit font-gated locator outcome")
        var settled = false
        var readyCount = 0
        var outcome: LocatorOutcome?

        controller.onLocatorEvent = { payload in
            guard payload.epoch == request.token.epoch else { return }
            if payload.kind == .ready {
                guard !payload.restorationPending else { return }
                readyCount += 1
                guard !settled else { return }
                settled = true
                outcome = .ready(
                    payload: payload,
                    readyCount: readyCount,
                    servedPathsAtReady: controller.resourceHandler.servedPaths,
                    rejectedURLsAtReady: controller.resourceHandler.rejectedURLs
                )
                settledExpectation.fulfill()
            } else if payload.kind == .error {
                guard !settled else { return }
                settled = true
                outcome = .locatorError(payload: payload, readyCount: readyCount)
                settledExpectation.fulfill()
            }
        }
        controller.onLoadFailure = { error, token in
            guard token == request.token, !settled else { return }
            settled = true
            outcome = .loadFailure(error: error, readyCount: readyCount)
            settledExpectation.fulfill()
        }
        defer {
            controller.onLocatorEvent = nil
            controller.onLoadFailure = nil
        }

        controller.apply(request)
        let waitResult = await XCTWaiter.fulfillment(of: [settledExpectation], timeout: Self.waitTimeoutSeconds)
        try #require(waitResult == .completed)
        if let outcome, case .ready = outcome {
            let acknowledged = controller.acknowledgePresentation(for: request.token)
            #expect(acknowledged)
        }
        return try #require(outcome)
    }

    private func inspectLoadedFontsAndMetrics(in controller: EPUBWebViewController) async throws -> [String: Any] {
        let raw = try await controller.evaluateLocatorJavaScriptForTesting(
            """
            (function() {
                function normalizeFamily(value) {
                    return String(value || '').replace(/^["']|["']$/g, '');
                }
                var faces = [];
                document.fonts.forEach(function(face) {
                    faces.push({
                        family: normalizeFamily(face.family),
                        status: String(face.status || ''),
                        weight: String(face.weight || ''),
                        style: String(face.style || '')
                    });
                });
                var rules = [];
                var authorStyleTexts = [];
                Array.prototype.forEach.call(document.querySelectorAll('style[data-yj-author-style]'), function(style) {
                    authorStyleTexts.push(String(style.textContent || ''));
                    var list = style.sheet ? style.sheet.cssRules : [];
                    for (var i = 0; i < list.length; i++) {
                        if (list[i].type === 5) {
                            rules.push({
                                family: normalizeFamily(list[i].style.getPropertyValue('font-family')),
                                src: String(list[i].style.getPropertyValue('src') || ''),
                                cssText: String(list[i].cssText || '')
                            });
                        }
                    }
                });
                function measureParagraph(originalId) {
                    var p = document.querySelector('[data-yj-original-id="' + originalId + '"]') || document.getElementById(originalId);
                    var span = p && p.querySelector('span');
                    var textNode = span && span.firstChild;
                    if (!span || !textNode || textNode.nodeType !== 3) { return null; }
                    var range = document.createRange();
                    range.selectNodeContents(textNode);
                    var rects = range.getClientRects();
                    var rect = range.getBoundingClientRect();
                    var spanRect = span.getBoundingClientRect();
                    var style = window.getComputedStyle(span);
                    return {
                        text: textNode.nodeValue || '',
                        clientRectCount: rects.length,
                        rangeWidth: rect.width,
                        rangeHeight: rect.height,
                        spanWidth: spanRect.width,
                        fontFamily: style.fontFamily,
                        fontSize: style.fontSize
                    };
                }
                return {
                    layout: document.documentElement.getAttribute('data-yj-layout') || '',
                    fontSetStatus: String(document.fonts.status || ''),
                    fontSetSize: document.fonts.size,
                    faces: faces,
                    fontFaceRules: rules,
                    authorStyleTexts: authorStyleTexts,
                    customAAAA: measureParagraph('custom-aaaa'),
                    customAA: measureParagraph('custom-aa'),
                    customSpaced: measureParagraph('custom-spaced'),
                    fallbackAAAA: measureParagraph('fallback-aaaa')
                };
            })();
            """
        ) as? [String: Any]
        return try #require(raw)
    }

    private func verifyLoadedFontAndMetrics(
        snapshot: [String: Any],
        expectedScopedFamily: String,
        expectedCapabilityHost: String,
        fontPath: String
    ) throws {
        #expect(snapshot["layout"] as? String == "original")
        #expect(snapshot["fontSetStatus"] as? String == "loaded")
        let fontSetSize = (snapshot["fontSetSize"] as? NSNumber)?.intValue
        #expect(fontSetSize == 1)

        let expectedFontURL = "yjepub://\(expectedCapabilityHost)/\(fontPath)"
        let rules = try #require(snapshot["fontFaceRules"] as? [[String: Any]])
        #expect(rules.count == 1)
        #expect(rules.first?["family"] as? String == expectedScopedFamily)
        let ruleSrc = rules.first?["src"] as? String ?? ""
        let ruleCSSText = rules.first?["cssText"] as? String ?? ""
        let authorStyleTexts = snapshot["authorStyleTexts"] as? [String] ?? []
        #expect(ruleSrc.contains(expectedFontURL) || ruleCSSText.contains(expectedFontURL))
        #expect(authorStyleTexts.contains { $0.contains(expectedFontURL) })

        let faces = try #require(snapshot["faces"] as? [[String: Any]])
        let matchingFaces = faces.filter { ($0["family"] as? String) == expectedScopedFamily }
        #expect(matchingFaces.count == 1)
        #expect(matchingFaces.allSatisfy { ($0["status"] as? String) == "loaded" })

        let customAAAA = try #require(snapshot["customAAAA"] as? [String: Any])
        let customAA = try #require(snapshot["customAA"] as? [String: Any])
        let customSpaced = try #require(snapshot["customSpaced"] as? [String: Any])
        let fallbackAAAA = try #require(snapshot["fallbackAAAA"] as? [String: Any])

        #expect((customAAAA["fontFamily"] as? String)?.contains(expectedScopedFamily) == true)
        #expect(customAAAA["fontSize"] as? String == "24px")
        #expect((fallbackAAAA["fontFamily"] as? String)?.contains(expectedScopedFamily) == false)
        #expect(fallbackAAAA["fontSize"] as? String == "24px")

        #expect((customAAAA["clientRectCount"] as? NSNumber)?.intValue == 1)
        #expect((customAA["clientRectCount"] as? NSNumber)?.intValue == 1)
        #expect((customSpaced["clientRectCount"] as? NSNumber)?.intValue == 1)
        #expect((fallbackAAAA["clientRectCount"] as? NSNumber)?.intValue == 1)

        // Synthetic font metrics at 24px (unitsPerEm = 1000):
        //   'A'     advance = 2500 -> 60px per glyph ("AAAA" = 240px, "AA" = 120px)
        //   'space' advance = 1000 -> 24px per glyph ("A A"  = 144px)
        let widthCustomAAAA = try #require((customAAAA["rangeWidth"] as? NSNumber)?.doubleValue)
        let widthCustomAA = try #require((customAA["rangeWidth"] as? NSNumber)?.doubleValue)
        let widthCustomSpaced = try #require((customSpaced["rangeWidth"] as? NSNumber)?.doubleValue)
        let widthFallbackAAAA = try #require((fallbackAAAA["rangeWidth"] as? NSNumber)?.doubleValue)

        #expect(abs(widthCustomAAAA - 240.0) <= 3.0)
        #expect(abs(widthCustomAA - 120.0) <= 3.0)
        #expect(abs(widthCustomSpaced - 144.0) <= 3.0)
        #expect(abs((widthCustomSpaced - widthCustomAA) - 24.0) <= 3.0)
        #expect(widthFallbackAAAA > 20.0 && widthFallbackAAAA < 110.0)
        #expect(widthCustomAAAA > widthFallbackAAAA * 2.0)
    }

    private static func makeSyntheticGeometricFontData() throws -> Data {
        let data = try #require(
            Data(base64Encoded: syntheticGeometricFontBase64, options: [.ignoreUnknownCharacters])
        )
        #expect(data.count == syntheticFontByteCount)
        #expect(EPUBResourceStore.digest(data) == syntheticFontSHA256)
        return data
    }

    private static func writeFontTestEPUB(
        to archiveURL: URL,
        title: String,
        fontFileName: String,
        fontData: Data,
        declaredFontMediaType: String = "font/ttf",
        condensedFontData: Data? = nil
    ) throws {
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:\(title.lowercased().replacingOccurrences(of: " ", with: "-"))</dc:identifier>
            <dc:title>\(EPUBContentPolicy.escapeXMLText(title))</dc:title>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="ch1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="css" href="Styles/font.css" media-type="text/css"/>
            <item id="ttf" href="Fonts/\(EPUBContentPolicy.escapeXMLAttribute(fontFileName))" media-type="\(EPUBContentPolicy.escapeXMLAttribute(declaredFontMediaType))"/>
            \(condensedFontData == nil ? "" : "<item id=\"condensed\" href=\"Fonts/CondensedStub.ttf\" media-type=\"font/ttf\"/>")
          </manifest>
          <spine>
            <itemref idref="ch1"/>
          </spine>
        </package>
        """
        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head><title>Contents</title></head>
          <body>
            <nav epub:type="toc">
              <ol>
                <li><a href="Text/ch1.xhtml#ch1-top">Chapter 1</a></li>
              </ol>
            </nav>
          </body>
        </html>
        """
        let css = """
        @font-face {
            font-family: "AuthorDisplayFace";
            src: url("../Fonts/\(fontFileName)") format("truetype");
            font-weight: 400;
            font-style: normal;
        }
        \(condensedFontData == nil ? "" : "@font-face { font-family: AuthorDisplayFace; src: url('../Fonts/CondensedStub.ttf') format('truetype'); font-weight: 400; font-style: normal; font-stretch: condensed; }")
        p.synthetic-font {
            font-family: "AuthorDisplayFace", serif;
            font-size: 24px;
            line-height: 36px;
        }
        p.fallback-font {
            font-family: serif;
            font-size: 24px;
            line-height: 36px;
        }
        """
        let ch1 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head>
            <title>Chapter 1</title>
            <link rel="stylesheet" type="text/css" href="../Styles/font.css"/>
          </head>
          <body>
            <h1 id="ch1-top">Synthetic Font Test</h1>
            <p id="custom-aaaa" class="synthetic-font">AAAA</p>
            <p id="custom-aa" class="synthetic-font">AA</p>
            <p id="custom-spaced" class="synthetic-font">A A</p>
            <p id="fallback-aaaa" class="fallback-font">AAAA</p>
          </body>
        </html>
        """
        var entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(container.utf8)),
            ("OEBPS/content.opf", Data(opf.utf8)),
            ("OEBPS/nav.xhtml", Data(nav.utf8)),
            ("OEBPS/Styles/font.css", Data(css.utf8)),
            ("OEBPS/Text/ch1.xhtml", Data(ch1.utf8)),
            ("OEBPS/Fonts/\(fontFileName)", fontData)
        ]
        if let condensedFontData { entries.append(("OEBPS/Fonts/CondensedStub.ttf", condensedFontData)) }
        try EPUBUITestFixture.writeArchive(entries: entries, to: archiveURL)
    }

    // Structural-only SFNT stub matching EPUBAuthorStyles.verifyFontData container checks,
    // omitting valid glyph/cmap/hmtx tables so real WebKit FontFace decoding must reject it.
    private static func makeStructuralOnlySFNTStub() -> Data {
        func appendUInt16BE(_ data: inout Data, _ value: UInt16) {
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        }
        func appendUInt32BE(_ data: inout Data, _ value: UInt32) {
            data.append(UInt8((value >> 24) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        }

        var head = Data(repeating: 0, count: 54)
        let magic: UInt32 = 0x5F0F3CF5
        head[12] = UInt8((magic >> 24) & 0xFF)
        head[13] = UInt8((magic >> 16) & 0xFF)
        head[14] = UInt8((magic >> 8) & 0xFF)
        head[15] = UInt8(magic & 0xFF)

        var tables: [(String, Data)] = [
            ("glyf", Data(repeating: 0x01, count: 16)),
            ("head", head),
            ("hhea", Data(repeating: 0, count: 36)),
            ("loca", Data(repeating: 0, count: 4)),
            ("maxp", Data(repeating: 0, count: 6)),
            ("name", Data(repeating: 0, count: 8))
        ]
        tables.sort { $0.0 < $1.0 }

        let numTables = tables.count
        var out = Data()
        appendUInt32BE(&out, 0x00010000)
        appendUInt16BE(&out, UInt16(numTables))
        var maxPow2 = 1
        var entrySelector: UInt16 = 0
        while maxPow2 * 2 <= numTables {
            maxPow2 *= 2
            entrySelector += 1
        }
        let searchRange = UInt16(maxPow2 * 16)
        let rangeShift = UInt16(numTables * 16) - searchRange
        appendUInt16BE(&out, searchRange)
        appendUInt16BE(&out, entrySelector)
        appendUInt16BE(&out, rangeShift)

        var offset = 12 + numTables * 16
        var bodies = Data()
        for (tag, body) in tables {
            out.append(contentsOf: Array(tag.utf8))
            appendUInt32BE(&out, 0)
            appendUInt32BE(&out, UInt32(offset))
            appendUInt32BE(&out, UInt32(body.count))
            bodies.append(body)
            let pad = (4 - (body.count % 4)) % 4
            if pad > 0 { bodies.append(Data(repeating: 0, count: pad)) }
            offset += body.count + pad
        }
        out.append(bodies)
        return out
    }
}

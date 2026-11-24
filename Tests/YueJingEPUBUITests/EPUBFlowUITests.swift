import UIKit
import XCTest

final class EPUBFlowUITests: XCTestCase {
    @MainActor private static var finalEvidenceCases: Set<String> = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        let currentName = name
        await MainActor.run {
            let app = XCUIApplication()
            let key = EPUBFlowUITests.evidenceCase(currentName)
            if !EPUBFlowUITests.finalEvidenceCases.contains(key) {
                EPUBFlowUITests.captureEvidence(app, testName: key, stage: "teardown-fallback")
                EPUBFlowUITests.finalEvidenceCases.insert(key)
            }
            app.terminate()
        }
        try await super.tearDown()
    }

    // Development reproducer for run 43427854507's first-content failure.
    // Long cross-chapter/relaunch scenarios below remain acceptance coverage.
    @MainActor func testEPUBFirstContentVisibleSmoke() {
        withEPUBFixture { app in
            openEPUB("EPUBTest-Illustrated-A", expectedMarker: "EPUB_CH1_START", stage: "open-smoke", app)
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "epub.opening.feedback").firstMatch.exists)
            XCTAssertEqual(Self.parseCanvasValue(readerCanvas(app).value as? String ?? "")["path"], "OEBPS/text/ch1.xhtml")
            exitReader(app, shelfBook: "EPUBTest-Illustrated-A")
        }
    }

    @MainActor func testEPUBShelfCoverAndDirectoryCrossChapterNavigation() {
        withEPUBFixture { app in
            let illustratedRow = shelfRow(titled: "EPUBTest-Illustrated-A", app)
            waitHittable(illustratedRow, expectedID: "shelf row: EPUBTest-Illustrated-A", timeout: 20)
            let coverLoaded = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    illustratedRow.exists && illustratedRow.label.contains("EPUB · 封面")
                },
                object: nil
            )
            XCTAssertEqual(waitForPredicates([coverLoaded], timeout: 10), .completed)

            openEPUB("EPUBTest-Illustrated-A", expectedMarker: "EPUB_CH1_START", stage: "open", app)
            // One stationary tap in the old excluded bottom band must reveal tools.
            // First explicitly hide the initial tools; never retry center taps to mask failure.
            let bottom = viewport(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94))
            let exit = app.buttons["reader.exit"]
            let hideDeadline = Date().addingTimeInterval(5)
            waitHittable(exit, expectedID: "reader.exit", timeout: 5, stage: "before-hide")
            viewport(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !exit.exists }, object: nil)
            XCTAssertEqual(waitForPredicates([hidden], timeout: max(0, hideDeadline.timeIntervalSinceNow)), .completed)
            bottom.tap()
            waitHittable(exit, expectedID: "reader.exit", timeout: 5, stage: "bottom-band-reveal")
            openDirectory(app)
            XCTAssertTrue(app.staticTexts["reader.directory.total"].label.contains("4"))
            XCTAssertFalse(app.buttons["reader.contents.bookmarks"].exists)
            XCTAssertEqual(app.buttons["reader.chapter.0"].value as? String, "当前章节")
            // Full filter/clear/locate coverage belongs to the independent directory recovery test.

            let midAnchorChapter = app.buttons["reader.chapter.2"]
            waitHittable(midAnchorChapter, expectedID: "reader.chapter.2")
            midAnchorChapter.tap()

            let canvas = readerCanvas(app)
            let movedToChapter2Mid = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    guard canvas.exists else { return false }
                    let value = canvas.value as? String ?? ""
                    return canvas.label.contains("EPUB_CH2_MID_ANCHOR") &&
                        value.contains("path=OEBPS/text/ch2.xhtml")
                },
                object: nil
            )
            XCTAssertEqual(waitForPredicates([movedToChapter2Mid], timeout: 15), .completed)
            // Tools must remain hidden after chapter selection, not be revived by loading.
            XCTAssertFalse(app.buttons["reader.exit"].isHittable)
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "epub.opening.feedback").firstMatch.exists)
            Self.captureEvidence(app, testName: name, stage: "after-chapter-jump", expectedBook: "EPUBTest-Illustrated-A")

            revealToolsIfHidden(for: "reader.tools.directory", app)
            openDirectory(app)
            XCTAssertTrue(midAnchorChapter.waitForExistence(timeout: 10))
            XCTAssertEqual(midAnchorChapter.value as? String, "当前章节")
            closePanel(app)
            verifyPagingAndCrossChapterNavigation(app)
            let beforeWarmReopen = Self.parseCanvasValue(canvas.value as? String ?? "")
            XCTAssertEqual(beforeWarmReopen["path"], "OEBPS/text/ch3.xhtml")
            XCTAssertNotNil(beforeWarmReopen["node"])
            XCTAssertNotNil(beforeWarmReopen["offset"])
            exitReader(app, shelfBook: "EPUBTest-Illustrated-A")
            // Reuse the closed workspace in the same process; preserve actual saved coordinates.
            openEPUB("EPUBTest-Illustrated-A", expectedMarker: "EPUB_CH3_START", stage: "warm-reopen", app)
            let warmRestored = Self.parseCanvasValue(canvas.value as? String ?? "")
            XCTAssertEqual(warmRestored["path"], "OEBPS/text/ch3.xhtml")
            XCTAssertEqual(warmRestored["node"], beforeWarmReopen["node"])
            XCTAssertEqual(warmRestored["offset"], beforeWarmReopen["offset"])
            exitReader(app, shelfBook: "EPUBTest-Illustrated-A")
        }
    }

    @MainActor func testEPUBProgressSurvivesExitAndProcessRelaunch() {
        withEPUBFixture { app in
            openEPUB("EPUBTest-Illustrated-A", expectedMarker: "EPUB_CH1_START", stage: "open", app)
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "epub.opening.feedback").firstMatch.exists)
            XCTAssertEqual(Self.parseCanvasValue(readerCanvas(app).value as? String ?? "")["layout"], "original")
            selectLayoutMode("阅读器排版", rawValue: "reader", app)
            selectReadingMode("上下滚动", rawValue: "scroll", app)
            openDirectory(app)
            let chapter2 = app.buttons["reader.chapter.1"]
            waitHittable(chapter2, expectedID: "reader.chapter.1")
            chapter2.tap()

            let canvas = readerCanvas(app)
            let ch2Loaded = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    guard canvas.exists else { return false }
                    let value = canvas.value as? String ?? ""
                    return canvas.label.contains("EPUB_CH2_START") &&
                        value.contains("path=OEBPS/text/ch2.xhtml")
                },
                object: nil
            )
            XCTAssertEqual(waitForPredicates([ch2Loaded], timeout: 15), .completed)

            let view = viewport(app)
            for _ in 0..<3 {
                view.swipeUp(velocity: .slow)
            }
            var scrolledNode = 0
            let scrolledExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    guard canvas.exists, let raw = canvas.value as? String else { return false }
                    let parsed = Self.parseCanvasValue(raw)
                    if parsed["path"] == "OEBPS/text/ch2.xhtml",
                       let node = Int(parsed["node"] ?? "0"),
                       let scrollY = Int(parsed["scrollY"] ?? "0"),
                       node > 0, scrollY > 20 {
                        scrolledNode = node
                        return true
                    }
                    return false
                },
                object: nil
            )
            XCTAssertEqual(waitForPredicates([scrolledExpectation], timeout: 12), .completed)
            XCTAssertGreaterThan(scrolledNode, 0)

            revealToolsIfHidden(for: "reader.exit", app)
            scrolledNode = Int(Self.parseCanvasValue(canvas.value as? String ?? "")["node"] ?? "-1") ?? -1
            XCTAssertGreaterThan(scrolledNode, 0)
            exitReader(app, shelfBook: "EPUBTest-Illustrated-A")
            Self.captureEvidence(app, testName: name, stage: "before-relaunch", expectedBook: "EPUBTest-Illustrated-A")

            app.terminate()
            app.launch()

            openEPUB("EPUBTest-Illustrated-A", expectedMarker: "EPUB_A_C2_P", stage: "after-relaunch", app)
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "epub.opening.feedback").firstMatch.exists)
            let restored = Self.parseCanvasValue(canvas.value as? String ?? "")
            XCTAssertEqual(restored["layout"], "reader", "Layout preference must survive process relaunch")
            XCTAssertEqual(restored["path"], "OEBPS/text/ch2.xhtml")
            XCTAssertEqual(Int(restored["node"] ?? "-1"), scrolledNode)
            XCTAssertGreaterThan(Int(restored["scrollY"] ?? "0") ?? 0, 20)

            openDirectory(app)
            XCTAssertTrue(chapter2.waitForExistence(timeout: 10))
            XCTAssertEqual(chapter2.value as? String, "当前章节")
            closePanel(app)
            selectLayoutMode("原始排版", rawValue: "original", app)
            let originalRestored = Self.parseCanvasValue(canvas.value as? String ?? "")
            XCTAssertEqual(originalRestored["path"], restored["path"])
            XCTAssertEqual(originalRestored["node"], restored["node"])
            XCTAssertEqual(originalRestored["offset"], restored["offset"])
            exitReader(app, shelfBook: "EPUBTest-Illustrated-A")
        }
    }

    @MainActor func testEPUBTypographyNoCoverFallbackAndTXTIsolation() {
        withEPUBFixture { app in
            let noCoverRow = shelfRow(titled: "EPUBTest-NoCover-B", app)
            let txtRow = shelfRow(titled: "TXTTest-Companion-C", app)
            waitHittable(noCoverRow, expectedID: "shelf row: EPUBTest-NoCover-B", timeout: 20)
            waitHittable(txtRow, expectedID: "shelf row: TXTTest-Companion-C", timeout: 10)
            XCTAssertTrue(noCoverRow.label.contains("EPUB · 文字占位"))
            XCTAssertTrue(txtRow.label.contains("TXT"))
            let mode = openDeveloperSwitch(app)
            guard let original = mode.value as? String, ["0", "1"].contains(original) else {
                XCTFail("Expected a readable developer mode switch"); return
            }
            var restoredOnShelf = false
            addTeardownBlock { @MainActor () async in
                guard !restoredOnShelf else { return }
                app.launch()
                defer { app.terminate() }
                let restored = self.openDeveloperSwitch(app)
                if restored.value as? String != original { restored.tap() }
                XCTAssertEqual(restored.value as? String, original)
            }
            if original == "1" { mode.tap() }
            XCTAssertEqual(mode.value as? String, "0")
            app.buttons["library.tab.shelf"].tap()

            openEPUB("EPUBTest-NoCover-B", expectedMarker: "EPUB_NOCOVER_START", stage: "open", app)
            let beforeGroups = Self.parseCanvasValue(readerCanvas(app).value as? String ?? "")
            let beforeFrame = viewport(app).frame
            // EPUB exposes both primary actions directly, without an expand/collapse tray.
            let epubDeadline = Date().addingTimeInterval(10)
            revealDockControl("reader.tools.directory", app, deadline: epubDeadline)
            XCTAssertFalse(app.buttons["reader.tools.expand"].exists)
            XCTAssertFalse(app.buttons["reader.tools.collapse"].exists)
            XCTAssertFalse(app.buttons["reader.tools.returnFromSearch"].exists)
            openSettings(app, deadline: epubDeadline)
            assertNoReaderAbout(app)
            let diagnostics = app.buttons["reader.info.diagnostics"]
            XCTAssertFalse(diagnostics.exists)
            selectSettingsGroup("more", app)
            assertNoReaderAbout(app)
            XCTAssertFalse(diagnostics.exists)
            selectSettingsGroup("common", app)
            closePanel(app)
            let afterGroups = Self.parseCanvasValue(readerCanvas(app).value as? String ?? "")
            for key in ["path", "node", "offset", "scrollX", "scrollY"] {
                XCTAssertNotNil(beforeGroups[key])
                XCTAssertEqual(afterGroups[key], beforeGroups[key], "Group navigation must not move the reading position")
            }
            XCTAssertEqual(viewport(app).frame, beforeFrame, "Settings groups must not resize the reading viewport")
            exitReader(app, shelfBook: "EPUBTest-NoCover-B")
            openDeveloperSwitch(app).tap()
            XCTAssertEqual(mode.value as? String, "1")
            app.buttons["library.tab.shelf"].tap()
            openEPUB("EPUBTest-NoCover-B", expectedMarker: "EPUB_NOCOVER_START", stage: "developer-reopen", app)
            selectLayoutMode("阅读器排版", rawValue: "reader", app, returnToCommon: true)
            assertNoReaderAbout(app)

            let darkButton = revealSetting("reader.theme.dark", in: app.buttons, app)
            darkButton.tap()
            XCTAssertEqual(darkButton.value as? String, "已选择")

            let relaxedButton = revealSetting("reader.preset.relaxed", in: app.buttons, app)
            relaxedButton.tap()
            XCTAssertEqual(relaxedButton.value as? String, "已选择")
            XCTAssertTrue(app.staticTexts["reader.font.value"].label.contains("24"))
            XCTAssertTrue(app.staticTexts["reader.spacing.value"].label.contains("10"))

            selectSettingsGroup("more", app)
            let entry = revealSetting("reader.info.diagnostics", in: app.buttons, app)
            assertNoReaderAbout(app)
            entry.tap()
            let done = app.buttons["reader.info.close"]
            waitHittable(done, expectedID: "reader.info.close")
            XCTAssertTrue(app.navigationBars["本书诊断"].exists)
            let scope = revealSetting("epub.settings.scopeNote", in: app.staticTexts, app,
                                      scrollView: app.scrollViews.containing(.staticText, identifier: "epub.settings.scopeNote").firstMatch)
            XCTAssertTrue(scope.label.contains("可重排"))
            done.tap()
            waitHittable(app.buttons["reader.panel.close"], expectedID: "reader.panel.close")
            XCTAssertEqual(app.buttons["epub.settings.group.more"].value as? String, "已选择")
            XCTAssertFalse(scope.exists)

            closePanel(app)

            let canvas = readerCanvas(app)
            let updatedTypography = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    guard canvas.exists, let raw = canvas.value as? String else { return false }
                    return raw.contains("path=OEBPS/text/b1.xhtml") &&
                        raw.contains("font=24") &&
                        raw.contains("spacing=10") &&
                        raw.contains("theme=dark")
                },
                object: nil
            )
            XCTAssertEqual(waitForPredicates([updatedTypography], timeout: 10), .completed)

            // Original mode must offer a real proportional control, not a disabled reader slider.
            selectLayoutMode("原始排版", rawValue: "original", app, returnToCommon: true)
            let authorIncrease = revealSetting("reader.font.increase", in: app.buttons, app)
            XCTAssertTrue(authorIncrease.isEnabled)
            XCTAssertTrue(app.staticTexts["reader.font.value"].label.contains("120%"))
            XCTAssertFalse(app.staticTexts["reader.spacing.value"].exists)
            authorIncrease.tap()
            XCTAssertTrue(app.staticTexts["reader.font.value"].label.contains("125%"))
            let originalSize = revealSetting("reader.preset.standard", in: app.buttons, app)
            originalSize.tap()
            XCTAssertTrue(app.staticTexts["reader.font.value"].label.contains("100%"))
            closePanel(app)
            selectLayoutMode("阅读器排版", rawValue: "reader", app, returnToCommon: true)
            let retainedSpacing = revealSetting("reader.spacing.value", in: app.staticTexts, app)
            XCTAssertTrue(retainedSpacing.label.contains("10"))
            closePanel(app)
            exitReader(app, shelfBook: "EPUBTest-NoCover-B")

            openTXT("TXTTest-Companion-C", expectedMarker: "TXT_COMPANION_START", stage: "open-txt", app)
            // TXT shares the direct chapter panel with EPUB: both primary actions are directly reachable.
            let txtDeadline = Date().addingTimeInterval(10)
            revealDockControl("reader.tools.settings", app, deadline: txtDeadline)
            revealDockControl("reader.tools.directory", app, deadline: txtDeadline)
            XCTAssertFalse(app.buttons["reader.tools.expand"].exists)
            XCTAssertFalse(app.buttons["reader.tools.collapse"].exists)
            XCTAssertFalse(app.buttons["reader.tools.returnFromSearch"].exists)
            let chapterContext = app.staticTexts["reader.tools.chapterContext"]
            let chapterReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                chapterContext.exists && chapterContext.label.contains("第一章 TXT_COMPANION_START")
            }, object: nil)
            XCTAssertEqual(waitForPredicates([chapterReady], timeout: max(0, txtDeadline.timeIntervalSinceNow)), .completed)
            XCTAssertFalse(chapterContext.label.contains("TXTTest-Companion-C"))
            openDirectory(app, deadline: txtDeadline)
            XCTAssertTrue(app.buttons["reader.contents.bookmarks"].waitForExistence(timeout: 10))
            closePanel(app)
            exitReader(app, shelfBook: "TXTTest-Companion-C")
            let restore = openDeveloperSwitch(app)
            if restore.value as? String != original { restore.tap() }
            let restoredValue = restore.value as? String
            XCTAssertEqual(restoredValue, original)
            restoredOnShelf = restoredValue == original
        }
    }

    @MainActor func testEPUBDirectoryControlsRecoverAfterCancelReopenAndForeground() {
        withEPUBFixture { app in
            openEPUB("EPUBTest-Illustrated-A", expectedMarker: "EPUB_CH1_START", stage: "open", app)
            // Close/reopen without a timed pause. A new sheet must not inherit query or presented=false.
            for _ in 0..<2 {
                openDirectory(app)
                waitDirectoryActive(app)
                XCTAssertFalse(app.buttons["epub.directory.clear"].exists)
                exerciseDirectoryFilterClearAndLocate(app)
                filterDirectory("3", expectedIndex: 2, app)
                closePanel(app)
                XCTAssertTrue(readerCanvas(app).label.contains("EPUB_CH1_START"), "Cancel must not select the filtered chapter")
            }
            openDirectory(app)
            filterDirectory("3", expectedIndex: 2, app)
            Self.captureEvidence(app, testName: name, stage: "directory-before-background")
            XCUIDevice.shared.press(.home)
            app.activate()
            // suspend revokes the old panel; foreground must not resurrect its authority.
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !app.textFields["epub.directory.search"].exists
            }, object: nil)
            XCTAssertEqual(waitForPredicates([dismissed], timeout: 10), .completed)
            let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.readerCanvas(app).exists && self.readerCanvas(app).label.contains("EPUB_CH1_START")
            }, object: nil)
            XCTAssertEqual(waitForPredicates([restored], timeout: 15), .completed)
            revealToolsIfHidden(for: "reader.tools.directory", app)
            waitHittable(app.buttons["reader.exit"], expectedID: "reader.exit")
            openDirectory(app)
            waitDirectoryActive(app)
            XCTAssertFalse(app.buttons["epub.directory.clear"].exists)
            exerciseDirectoryFilterClearAndLocate(app)
            filterDirectory("3", expectedIndex: 2, app)
            app.buttons["reader.chapter.2"].tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let canvas = self.readerCanvas(app)
                return canvas.exists && canvas.label.contains("EPUB_CH2_MID_ANCHOR") &&
                    (canvas.value as? String ?? "").contains("path=OEBPS/text/ch2.xhtml")
            }, object: nil)
            XCTAssertEqual(waitForPredicates([selected], timeout: 15), .completed)
            XCTAssertFalse(app.buttons["reader.exit"].isHittable)
            Self.captureEvidence(app, testName: name, stage: "directory-controls-recovered")
        }
    }

    // MARK: - Helpers (no helper method name may start with "test")

    @MainActor private func searchHit(_ query: String, epub: Bool, in app: XCUIApplication) -> XCUIElement {
        let deadline = Date().addingTimeInterval(10)
        revealToolsIfHidden(for: "reader.tools.directory", app)
        tapDirectory(app, deadline: deadline)
        let tabID = epub ? "epub.contents.search" : "reader.contents.search"
        let tab = app.buttons[tabID]
        waitHittable(tab, expectedID: tabID); tab.tap()
        let field = app.textFields["book.search.query"]
        waitHittable(field, expectedID: "book.search.query"); field.tap(); field.typeText(query + "\n")
        let hit = app.buttons["book.search.hit.0"].firstMatch
        waitHittable(hit, expectedID: "book.search.hit.0")
        XCTAssertTrue(hit.label.contains(query), "Result must contain the searched text")
        return hit
    }

    @MainActor func testTXTSearchResultJumpsToMatchingText() {
        withEPUBFixture { app in
            openTXT("TXTTest-Companion-C", expectedMarker: "TXT_COMPANION_START", stage: "search-txt-open", app)
            let view = viewport(app), word = "TXT_C_LINE_11"
            let before = Self.parseCanvasValue(view.value as? String ?? "")
            XCTAssertNotNil(before["raw"])
            _ = searchHit(word, epub: false, in: app)
            dismissPanel(app)
            XCTAssertEqual(Self.parseCanvasValue(view.value as? String ?? "")["raw"], before["raw"])
            let back = app.buttons["reader.tools.returnFromSearch"]
            XCTAssertFalse(back.exists)
            let hit = searchHit(word, epub: false, in: app)
            hit.tap()
            let prefix = "第一章 TXT_COMPANION_START\n" + (1...10).map {
                "TXT_C_LINE_\($0) 合成对照 TXT 文本，用于验证 EPUB 与 TXT 共存且互不串书。\n"
            }.joined()
            let reached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let value = Self.parseCanvasValue(view.value as? String ?? "")
                return !app.buttons["reader.panel.close"].exists && value["raw"] == String(3 + prefix.utf8.count) &&
                    value["utf16"] == String(prefix.utf16.count) && value["lineVisible"] == "true" &&
                    app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "reader.text.canvas", word)).firstMatch.exists
            }, object: nil)
            XCTAssertEqual(waitForPredicates([reached], timeout: 12), .completed, "TXT viewport: \(String(describing: view.value))")
            waitForSearchReturn(app, stage: "first TXT result")
            searchHit("TXT_C_LINE_6", epub: false, in: app).tap()
            let secondRaw = 3 + ("第一章 TXT_COMPANION_START\n" + (1...5).map {
                "TXT_C_LINE_\($0) 合成对照 TXT 文本，用于验证 EPUB 与 TXT 共存且互不串书。\n"
            }.joined()).utf8.count
            let second = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                Self.parseCanvasValue(view.value as? String ?? "")["raw"] == String(secondRaw)
            }, object: nil)
            XCTAssertEqual(waitForPredicates([second], timeout: 12), .completed)
            waitForSearchReturn(app, stage: "second TXT result"); back.tap()
            let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let now = Self.parseCanvasValue(view.value as? String ?? "")
                return now["raw"] == before["raw"] && now["utf16"] == before["utf16"] && now["lineVisible"] == "true" && !back.exists
            }, object: nil)
            XCTAssertEqual(waitForPredicates([restored], timeout: 12), .completed)
        }
    }

    @MainActor func testEPUBSearchResultJumpsToMatchingText() {
        withEPUBFixture { app in
            openEPUB("EPUBTest-Illustrated-A", expectedMarker: "EPUB_CH1_START", stage: "search-epub-open", app)
            let canvas = readerCanvas(app), word = "EPUB_A_C2_P20"
            let before = Self.parseCanvasValue(canvas.value as? String ?? "")
            _ = searchHit(word, epub: true, in: app)
            dismissPanel(app)
            let stayed = Self.parseCanvasValue(canvas.value as? String ?? "")
            for k in ["path", "node", "offset"] { XCTAssertNotNil(before[k]); XCTAssertEqual(stayed[k], before[k]) }
            let back = app.buttons["reader.tools.returnFromSearch"]
            XCTAssertFalse(back.exists)
            let hit = searchHit(word, epub: true, in: app)
            hit.tap()
            let reached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let value = Self.parseCanvasValue(canvas.value as? String ?? "")
                // h1(0), p1...14, h2(15), p15...20 (16...21). The match starts the node.
                return !app.buttons["reader.panel.close"].exists && canvas.label.contains(word) &&
                    value["path"] == "OEBPS/text/ch2.xhtml" && value["node"] == "21" && value["offset"] == "0"
            }, object: nil)
            XCTAssertEqual(waitForPredicates([reached], timeout: 15), .completed, "EPUB canvas: \(String(describing: canvas.value))")
            waitForSearchReturn(app, stage: "first EPUB result")
            searchHit("EPUB_A_C2_P25", epub: true, in: app).tap()
            let second = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let now = Self.parseCanvasValue(canvas.value as? String ?? "")
                return now["path"] == "OEBPS/text/ch2.xhtml" && now["node"] == "26" && canvas.label.contains("EPUB_A_C2_P25")
            }, object: nil)
            XCTAssertEqual(waitForPredicates([second], timeout: 15), .completed)
            waitForSearchReturn(app, stage: "second EPUB result"); back.tap()
            let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let now = Self.parseCanvasValue(canvas.value as? String ?? "")
                return ["path", "node", "offset"].allSatisfy { now[$0] == before[$0] } &&
                    canvas.label.contains("EPUB_CH1_START") && !back.exists
            }, object: nil)
            XCTAssertEqual(waitForPredicates([restored], timeout: 15), .completed)
        }
    }

    @MainActor func testShelfTitleSearchPreservesFilterAcrossReadCancelAndDelete() {
        withEPUBFixture { app in
            let txt = app.buttons["library.shelf.filter.txt"]
            waitHittable(txt, expectedID: "library.shelf.filter.txt"); txt.tap()
            let field = app.textFields["library.shelf.search"]
            field.tap(); field.typeText("test\n")
            let title = "TXTTest-Companion-C"
            openTXT(title, expectedMarker: "TXT_COMPANION_START", stage: "shelf-search-open", app)
            revealToolsIfHidden(for: "reader.exit", app)
            exitReader(app, shelfBook: title)
            XCTAssertEqual(field.value as? String, "test")
            XCTAssertEqual(txt.value as? String, "已选择")
            let row = shelfRow(titled: title, app)
            for action in ["取消", "删除"] {
                row.press(forDuration: 1)
                let menu = app.buttons["删除书籍"].firstMatch
                waitHittable(menu, expectedID: "删除书籍"); menu.tap()
                let alert = app.alerts.firstMatch
                XCTAssertTrue(alert.staticTexts["删除《\(title)》？"].waitForExistence(timeout: 5))
                alert.buttons[action].tap()
                if action == "取消" { waitHittable(row, expectedID: title) }
            }
            XCTAssertTrue(app.staticTexts["没有匹配的书"].waitForExistence(timeout: 5))
            XCTAssertEqual(field.value as? String, "test")
            XCTAssertEqual(txt.value as? String, "已选择")
            XCTAssertFalse(row.exists)
            app.buttons["library.shelf.filter.all"].tap()
            XCTAssertTrue(shelfRow(titled: "EPUBTest-NoCover-B", app).exists)
            XCTAssertEqual(field.value as? String, "test")
        }
    }

    @MainActor private func openDeveloperSwitch(_ app: XCUIApplication) -> XCUIElement {
        let settings = app.buttons["library.tab.settings"]
        waitHittable(settings, expectedID: "library.tab.settings"); settings.tap()
        return revealSetting("library.developerMode", in: app.switches, app, scrollView: app.scrollViews.firstMatch)
    }

    @MainActor private func assertNoReaderAbout(_ app: XCUIApplication) {
        let ids = ["reader.info.license", "library.about.license", "app.version", "epub.settings.scopeNote"]
        let titles = ["开源许可", "维护信息", "兼容与范围"]
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ids)).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label IN %@", titles)).firstMatch.exists)
    }

    @MainActor private func withEPUBFixture(
        callerName: String = #function,
        _ run: (XCUIApplication) -> Void
    ) {
        let previousOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let session = UUID().uuidString
        app.launchEnvironment["YUEJING_EPUB_UI_TEST_SESSION"] = session
        app.launchEnvironment["YUEJING_UI_TEST_SESSION"] = session
        let key = Self.evidenceCase(callerName)
        Self.finalEvidenceCases.remove(key)
        defer {
            Self.captureEvidence(app, testName: key, stage: "before-terminate")
            Self.finalEvidenceCases.insert(key)
            app.terminate()
            XCUIDevice.shared.orientation = previousOrientation
        }
        app.launch()
        run(app)
    }

    @MainActor private func shelfRow(titled title: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    @MainActor private func viewport(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "reader.viewport").firstMatch
    }

    @MainActor private func readerCanvas(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["reader.text.canvas"].firstMatch
    }

    @MainActor private func openEPUB(
        _ title: String,
        expectedMarker: String,
        stage: String,
        _ app: XCUIApplication
    ) {
        let row = shelfRow(titled: title, app)
        waitHittable(row, expectedID: "shelf row: \(title)", timeout: 20, stage: stage)
        row.tap()
        let deadline = Date().addingTimeInterval(20)
        let view = viewport(app)
        let canvas = readerCanvas(app)
        let visiblePredicate = NSPredicate { _, _ in
            guard view.exists, canvas.exists else { return false }
            return canvas.label.contains(expectedMarker)
        }
        let ready = XCTNSPredicateExpectation(predicate: visiblePredicate, object: nil)
        XCTAssertEqual(
            waitForPredicates([ready], timeout: max(0.1, deadline.timeIntervalSinceNow)),
            .completed,
            "Expected EPUB chapter content must be visible in the WebKit reader"
        )
        XCTAssertEqual(app.webViews.matching(identifier: "reader.viewport").count, 1,
                       "The EPUB reader must install exactly one interactive WebView")
        Self.captureEvidence(app, testName: name, stage: stage, expectedBook: title)
    }

    @MainActor private func openTXT(
        _ title: String,
        expectedMarker: String,
        stage: String,
        _ app: XCUIApplication
    ) {
        let row = shelfRow(titled: title, app)
        waitHittable(row, expectedID: "shelf row: \(title)", timeout: 20, stage: stage)
        row.tap()
        let deadline = Date().addingTimeInterval(20)
        let marker = app.staticTexts.matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "reader.text.canvas", expectedMarker)
        ).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: max(0.1, deadline.timeIntervalSinceNow)))
        Self.captureEvidence(app, testName: name, stage: stage, expectedBook: title)
    }

    @MainActor private func revealDockControl(_ id: String, _ app: XCUIApplication, deadline: Date,
                                              stage: String = #function, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id]
        let scroll = app.scrollViews.containing(.button, identifier: id).firstMatch
        var readyInBounds = false
        for _ in 0..<3 {
            guard deadline.timeIntervalSinceNow > 0 else { break }
            let screen = app.windows.firstMatch.frame
            let bounds = scroll.exists ? scroll.frame.intersection(screen) : screen
            let targetFrame = button.exists ? button.frame : .null
            if !targetFrame.isNull && button.isHittable && button.isEnabled && bounds.contains(CGPoint(x: targetFrame.midX, y: targetFrame.midY)) {
                readyInBounds = true
                break
            }
            guard scroll.exists, !bounds.isNull, bounds.width > 0, bounds.height > 0 else { break }
            if !targetFrame.isNull && targetFrame.midY < bounds.midY {
                scroll.swipeDown(velocity: .slow)
            } else {
                scroll.swipeUp(velocity: .slow)
            }
        }
        if !readyInBounds {
            waitHittable(button, expectedID: id, timeout: max(0, deadline.timeIntervalSinceNow), stage: stage, file: file, line: line)
        }
    }

    @MainActor private func selectSettingsGroup(_ group: String, _ app: XCUIApplication) {
        let button = app.buttons["epub.settings.group.\(group)"]
        waitHittable(button, expectedID: "epub.settings.group.\(group)")
        button.tap()
        XCTAssertEqual(button.value as? String, "已选择")
        XCTAssertTrue(button.isSelected)
    }

    @MainActor private func openSettings(_ app: XCUIApplication, deadline: Date = Date().addingTimeInterval(10)) {
        let id = "reader.tools.settings"
        revealDockControl(id, app, deadline: deadline)
        app.buttons[id].tap()
        waitHittable(app.buttons["reader.panel.close"], expectedID: "reader.panel.close")
    }

    @MainActor private func waitDirectoryActive(_ app: XCUIApplication) {
        let status = app.staticTexts["epub.directory.availability"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.exists && (status.value as? String ?? "").contains("state=active;") &&
                app.textFields["epub.directory.search"].isEnabled &&
                app.buttons["epub.directory.current"].isEnabled
        }, object: nil)
        XCTAssertEqual(waitForPredicates([ready], timeout: 5), .completed,
                       "Directory permission state: \(status.exists ? String(describing: status.value) : "missing")")
        XCTAssertFalse(app.buttons["epub.directory.recover"].exists)
    }

    @MainActor private func filterDirectory(_ query: String, expectedIndex: Int, _ app: XCUIApplication) {
        waitDirectoryActive(app)
        let search = app.textFields["epub.directory.search"]
        waitHittable(search, expectedID: "epub.directory.search")
        search.tap()
        search.typeText(query)
        let filtered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (search.value as? String) == query && app.buttons["epub.directory.clear"].isEnabled &&
                app.buttons["reader.chapter.\(expectedIndex)"].isHittable &&
                !app.buttons["reader.chapter.0"].exists
        }, object: nil)
        XCTAssertEqual(waitForPredicates([filtered], timeout: 5), .completed)
    }

    @MainActor private func exerciseDirectoryFilterClearAndLocate(_ app: XCUIApplication) {
        filterDirectory("3", expectedIndex: 2, app)
        app.buttons["epub.directory.clear"].tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.buttons["epub.directory.clear"].exists && app.buttons["reader.chapter.0"].exists &&
                (app.textFields["epub.directory.search"].value as? String) != "3"
        }, object: nil)
        XCTAssertEqual(waitForPredicates([cleared], timeout: 5), .completed)
        // Locate must really clear an active filter and reveal the current row, without navigation.
        filterDirectory("3", expectedIndex: 2, app)
        let locate = app.buttons["epub.directory.current"]
        waitHittable(locate, expectedID: "epub.directory.current")
        locate.tap()
        let located = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let current = app.buttons["reader.chapter.0"]
            return current.isHittable && (current.value as? String) == "当前章节" &&
                !app.buttons["epub.directory.clear"].exists && !app.keyboards.firstMatch.exists
        }, object: nil)
        XCTAssertEqual(waitForPredicates([located], timeout: 5), .completed)
    }

    @MainActor private func tapDirectory(_ app: XCUIApplication, deadline: Date) {
        let id = "reader.tools.directory"
        revealDockControl(id, app, deadline: deadline)
        app.buttons[id].tap()
    }

    @MainActor private func openDirectory(_ app: XCUIApplication, deadline: Date = Date().addingTimeInterval(10)) {
        tapDirectory(app, deadline: deadline)
        waitHittable(app.buttons["reader.panel.close"], expectedID: "reader.panel.close")
    }

    @MainActor private func closePanel(_ app: XCUIApplication) {
        app.buttons["reader.panel.close"].tap()
        revealDockControl("reader.tools.settings", app, deadline: Date().addingTimeInterval(10))
    }

    @MainActor private func dismissPanel(_ app: XCUIApplication) {
        let close = app.buttons["reader.panel.close"]
        close.tap()
        // The subsequent absence check for returnFromSearch must observe a live dock,
        // not pass merely because all tools are still hidden during dismissal.
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !close.exists && app.buttons["reader.tools.directory"].exists && app.buttons["reader.tools.settings"].exists
        }, object: nil)
        XCTAssertEqual(waitForPredicates([dismissed], timeout: 10), .completed)
    }

    // Used after actions that can hide chrome. A missing/disabled target alone
    // doesn't mean hidden: a title bar, panel or tray in AX means wait, don't toggle.
    @MainActor private func revealToolsIfHidden(for id: String, _ app: XCUIApplication) {
        let view = viewport(app)
        guard view.exists, !app.buttons[id].exists, !app.buttons["reader.exit"].exists,
              !app.buttons["reader.panel.close"].exists,
              !app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reader.tools.")).firstMatch.exists
        else { return }
        view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor private func waitForSearchReturn(_ app: XCUIApplication, stage: String,
                                                file: StaticString = #filePath, line: UInt = #line) {
        let id = "reader.tools.returnFromSearch"
        revealToolsIfHidden(for: id, app)
        waitHittable(app.buttons[id], expectedID: id, stage: stage, file: file, line: line)
    }

    @MainActor private func exitReader(_ app: XCUIApplication, shelfBook title: String) {
        let deadline = Date().addingTimeInterval(10)
        let exit = app.buttons["reader.exit"]
        waitHittable(exit, expectedID: "reader.exit", timeout: max(0, deadline.timeIntervalSinceNow))
        exit.tap()
        waitHittable(shelfRow(titled: title, app), expectedID: "shelf row: \(title)", timeout: max(0, deadline.timeIntervalSinceNow))
        XCTAssertFalse(app.staticTexts["暂时无法显示正文"].exists)
    }

    @MainActor private func revealSetting(_ id: String, in query: XCUIElementQuery, _ app: XCUIApplication,
                                          scrollView: XCUIElement? = nil,
                                          stage: String = #function, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = query[id]
        let scroll = scrollView ?? app.scrollViews["reader.settings.scroll"]
        for _ in 0..<10 {
            if element.exists && element.isHittable { break }
            let bounds = scroll.frame
            let offset = element.exists ? element.frame.midY - bounds.midY : CGFloat.infinity
            if abs(offset) <= bounds.height {
                // A full swipe can fling a nearby row past the opposite edge on SE.
                // Drag the scroll view's inset, not a setting, and release at rest.
                let upper = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.25))
                let lower = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.75))
                (offset < 0 ? upper : lower).press(forDuration: 0.05, thenDragTo: offset < 0 ? lower : upper,
                                                  withVelocity: .slow, thenHoldForDuration: 0.3)
            } else if offset < 0 {
                scroll.swipeDown(velocity: .slow)
            } else {
                scroll.swipeUp(velocity: .slow)
            }
        }
        waitHittable(element, expectedID: id, stage: stage, file: file, line: line)
        return element
    }

    @MainActor private func waitForPredicates(
        _ expectations: [XCTNSPredicateExpectation], timeout: TimeInterval
    ) -> XCTWaiter.Result {
        // All callers use one real UI predicate. Avoid a scheduling tick when it
        // already holds; otherwise retain XCTest's normal wait and original budget.
        let deadline = Date().addingTimeInterval(timeout)
        if expectations.count == 1,
           let expectation = expectations.first,
           expectation.predicate.evaluate(with: expectation.object) {
            return .completed
        }
        return XCTWaiter.wait(for: expectations, timeout: max(0, deadline.timeIntervalSinceNow))
    }

    @MainActor private func waitHittable(_ element: XCUIElement, expectedID: String, timeout: TimeInterval = 10,
                                         stage: String = #function, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                element.exists && element.isHittable && element.isEnabled
            },
            object: nil
        )
        guard waitForPredicates([ready], timeout: timeout) != .completed else { return }
        let exists = element.exists
        let details = exists ? "enabled=\(element.isEnabled) hittable=\(element.isHittable) frame=\(element.frame)"
                             : "enabled=n/a hittable=n/a frame=n/a"
        XCTFail("stage=\(stage) expectedID=\(expectedID) exists=\(exists) \(details)", file: file, line: line)
    }

    private static func parseCanvasValue(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in raw.split(separator: "|") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                result[String(kv[0])] = String(kv[1])
            }
        }
        return result
    }

    private static func evidenceCase(_ value: String) -> String {
        value.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            .last(where: { $0.hasPrefix("test") }).map(String.init) ?? "unknown-case"
    }

    @MainActor private static func captureEvidence(
        _ app: XCUIApplication,
        testName: String,
        stage: String,
        expectedBook: String? = nil
    ) {
        let key = evidenceCase(testName)
        let startedUptime = ProcessInfo.processInfo.systemUptime
        let stateSampledAt = Date().timeIntervalSince1970
        let state = app.state
        let screenshotStartedAt = Date().timeIntervalSince1970
        let screenshot = state == .runningForeground ? app.screenshot() : XCUIScreen.main.screenshot()
        let screenshotEndedAt = Date().timeIntervalSince1970
        let prefix = "YueJingEPUBUI--\(key)--\(stage)"
        let image = XCTAttachment(data: screenshot.pngRepresentation, uniformTypeIdentifier: "public.png")
        image.name = prefix + ".png"
        image.lifetime = .keepAlways
        XCTContext.runActivity(named: prefix) { activity in
            activity.add(image)
        }

        let axStartedAt = Date().timeIntervalSince1970
        let description = (state == .notRunning || state == .unknown)
            ? "App is not running; a full App AX hierarchy is unavailable."
            : app.debugDescription
        let axEndedAt = Date().timeIntervalSince1970
        let duration = ProcessInfo.processInfo.systemUptime - startedUptime
        let body =
            "YueJing UI evidence\n" +
            "case: \(key)\n" +
            "stage: \(stage)\n" +
            "appState: \(state.rawValue)\n" +
            "expectedBook: \(expectedBook ?? "not specified")\n" +
            "stateSampledAtUnix: \(stateSampledAt)\n" +
            "screenshotStartedAtUnix: \(screenshotStartedAt)\n" +
            "screenshotEndedAtUnix: \(screenshotEndedAt)\n" +
            "axStartedAtUnix: \(axStartedAt)\n" +
            "axEndedAtUnix: \(axEndedAt)\n" +
            "evidenceDurationSeconds: \(duration)\n" +
            "observationsAreSequential: true\n" +
            "fullAppDebugDescription:\n\(description)"
        let text = XCTAttachment(data: Data(body.utf8), uniformTypeIdentifier: "public.utf8-plain-text")
        text.name = prefix + ".ax.txt"
        text.lifetime = .keepAlways
        XCTContext.runActivity(named: prefix + "--ax") { activity in
            activity.add(text)
        }
    }

    @MainActor private func selectLayoutMode(_ title: String, rawValue: String, _ app: XCUIApplication,
                                             returnToCommon: Bool = false) {
        openSettings(app)
        selectSettingsGroup("more", app)
        let picker = revealSetting("epub.layoutMode", in: app.descendants(matching: .any), app)
        let option = picker.buttons[title]
        waitHittable(option, expectedID: title)
        option.tap()
        let canvas = readerCanvas(app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Self.parseCanvasValue(canvas.value as? String ?? "")["layout"] == rawValue
        }, object: nil)
        XCTAssertEqual(waitForPredicates([ready], timeout: 12), .completed)
        XCTAssertTrue(option.isSelected)
        if returnToCommon { selectSettingsGroup("common", app) } else { closePanel(app) }
    }

    @MainActor private func selectReadingMode(_ title: String, rawValue: String, _ app: XCUIApplication) {
        // Mode selection is setup here; do not repeat a no-op menu round trip.
        // The cross-chapter flow still exercises both actual mode transitions.
        if Self.parseCanvasValue(readerCanvas(app).value as? String ?? "")["mode"] == rawValue {
            XCTAssertEqual(Self.parseCanvasValue(readerCanvas(app).value as? String ?? "")["mode"], rawValue)
            return
        }
        openSettings(app)
        selectSettingsGroup("more", app)
        let picker = revealSetting("epub.readingMode", in: app.descendants(matching: .any), app)
        let option = picker.buttons[title]
        waitHittable(option, expectedID: title)
        option.tap()
        closePanel(app)
        let canvas = readerCanvas(app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Self.parseCanvasValue(canvas.value as? String ?? "")["mode"] == rawValue
        }, object: nil)
        XCTAssertEqual(waitForPredicates([ready], timeout: 12), .completed)
    }

    @MainActor private func verifyPagingAndCrossChapterNavigation(_ app: XCUIApplication) {
        let view = viewport(app)
        let canvas = readerCanvas(app)
        selectReadingMode("左右分页", rawValue: "paged", app)
        let initialFrame = view.frame
        view.pinch(withScale: 1.5, velocity: 1.0)
        XCTAssertEqual(view.frame.size.width, initialFrame.size.width, accuracy: 1.0)
        XCTAssertEqual(view.frame.size.height, initialFrame.size.height, accuracy: 1.0)

        func coordinate(_ key: String) -> Int {
            Int(Self.parseCanvasValue(canvas.value as? String ?? "")[key] ?? "-1") ?? -1
        }
        func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 12) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
            XCTAssertEqual(waitForPredicates([expectation], timeout: timeout), .completed)
        }
        waitFor { coordinate("window") == 3 }
        let initialLoads = coordinate("loads")
        let initialX = coordinate("scrollX")
        view.swipeLeft(velocity: .default)
        // A positive sample can be an intermediate animated offset, not a settled page.
        waitFor { abs(Double(coordinate("scrollX") - initialX) - Double(initialFrame.width)) <= 2 }
        let nextX = coordinate("scrollX")
        XCTAssertEqual(coordinate("scrollY"), 0)
        XCTAssertEqual(Double(nextX - initialX), Double(view.frame.width), accuracy: 2)
        view.swipeRight(velocity: .default)
        waitFor { abs(coordinate("scrollX") - initialX) <= 2 }
        view.swipeLeft(velocity: .default)
        waitFor { abs(coordinate("scrollX") - nextX) <= 2 }
        view.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
        waitFor { abs(coordinate("scrollX") - initialX) <= 2 }
        view.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.4)).tap()
        waitFor { abs(coordinate("scrollX") - nextX) <= 2 }
        XCTAssertEqual(coordinate("scrollY"), 0)

        revealToolsIfHidden(for: "reader.tools.directory", app)
        openDirectory(app)
        let chapter3 = app.buttons["reader.chapter.3"]
        waitHittable(chapter3, expectedID: "reader.chapter.3")
        chapter3.tap()
        waitFor {
            Self.parseCanvasValue(canvas.value as? String ?? "")["path"] == "OEBPS/text/ch3.xhtml" &&
                canvas.label.contains("EPUB_CH3_START")
        }
        waitFor { coordinate("window") == 3 && coordinate("scrollX") > 0 }
        let crossChapterLoads = coordinate("loads")
        view.swipeRight(velocity: .default)
        waitFor {
            Self.parseCanvasValue(canvas.value as? String ?? "")["path"] == "OEBPS/text/ch2.xhtml" &&
                canvas.label.contains("EPUB_CH2_END")
        }
        XCTAssertEqual(coordinate("loads"), crossChapterLoads, "Crossing must keep the same WebKit document")

        // Return to scrolling with the same text anchor, then arrive at the next chapter
        // in one continuous swipe. No second boundary swipe is issued by the test.
        revealToolsIfHidden(for: "reader.tools.settings", app)
        selectReadingMode("上下滚动", rawValue: "scroll", app)
        XCTAssertEqual(Self.parseCanvasValue(canvas.value as? String ?? "")["path"], "OEBPS/text/ch2.xhtml")
        // A fast flick can legitimately carry the viewport past the chapter heading.
        // Cross once with a measured drag, holding at the end to remove inertial overshoot.
        let heading = view.staticTexts.matching(NSPredicate(format: "label == %@", "第三章 EPUB_CH3_START")).firstMatch
        XCTAssertTrue(heading.exists)
        let distance = heading.frame.minY - view.frame.minY + 8
        XCTAssertGreaterThan(distance, 0)
        XCTAssertLessThan(distance, view.frame.height - 40)
        let start = view.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.95))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        waitFor {
            Self.parseCanvasValue(canvas.value as? String ?? "")["path"] == "OEBPS/text/ch3.xhtml" &&
                canvas.label.contains("EPUB_CH3_START")
        }
        XCTAssertEqual(coordinate("loads"), crossChapterLoads)
        XCTAssertGreaterThanOrEqual(initialLoads, 1)
        Self.captureEvidence(app, testName: name, stage: "after-paging-cross-chapter", expectedBook: "EPUBTest-Illustrated-A")
        revealToolsIfHidden(for: "reader.exit", app)
    }
}

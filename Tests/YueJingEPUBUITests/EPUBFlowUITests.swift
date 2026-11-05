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

    @MainActor func testEPUBShelfCoverAndDirectoryCrossChapterNavigation() {
        withEPUBFixture { app in
            let illustratedRow = shelfRow(titled: "EPUBTest-Illustrated-A", app)
            waitHittable(illustratedRow, timeout: 20)
            let coverLoaded = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    illustratedRow.exists && illustratedRow.label.contains("EPUB · 封面")
                },
                object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [coverLoaded], timeout: 10), .completed)

            openEPUB("EPUBTest-Illustrated-A", expectedMarker: "EPUB_CH1_START", stage: "open", app)
            openDirectory(app)
            XCTAssertTrue(app.staticTexts["reader.directory.total"].label.contains("4"))
            XCTAssertFalse(app.buttons["reader.contents.bookmarks"].exists)
            XCTAssertEqual(app.buttons["reader.chapter.0"].value as? String, "当前章节")

            let midAnchorChapter = app.buttons["reader.chapter.2"]
            waitHittable(midAnchorChapter)
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
            XCTAssertEqual(XCTWaiter.wait(for: [movedToChapter2Mid], timeout: 15), .completed)
            Self.captureEvidence(app, testName: name, stage: "after-chapter-jump", expectedBook: "EPUBTest-Illustrated-A")

            showTools(app)
            openDirectory(app)
            XCTAssertTrue(midAnchorChapter.waitForExistence(timeout: 10))
            XCTAssertEqual(midAnchorChapter.value as? String, "当前章节")
            closePanel(app)
            verifyPagingAndCrossChapterNavigation(app)
            exitReader(app, shelfBook: "EPUBTest-Illustrated-A")
        }
    }

    @MainActor func testEPUBProgressSurvivesExitAndProcessRelaunch() {
        withEPUBFixture { app in
            openEPUB("EPUBTest-Illustrated-A", expectedMarker: "EPUB_CH1_START", stage: "open", app)
            selectReadingMode("上下滚动", rawValue: "scroll", app)
            openDirectory(app)
            let chapter2 = app.buttons["reader.chapter.1"]
            waitHittable(chapter2)
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
            XCTAssertEqual(XCTWaiter.wait(for: [ch2Loaded], timeout: 15), .completed)

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
            XCTAssertEqual(XCTWaiter.wait(for: [scrolledExpectation], timeout: 12), .completed)
            XCTAssertGreaterThan(scrolledNode, 0)

            showTools(app)
            scrolledNode = Int(Self.parseCanvasValue(canvas.value as? String ?? "")["node"] ?? "-1") ?? -1
            XCTAssertGreaterThan(scrolledNode, 0)
            exitReader(app, shelfBook: "EPUBTest-Illustrated-A")
            Self.captureEvidence(app, testName: name, stage: "before-relaunch", expectedBook: "EPUBTest-Illustrated-A")

            app.terminate()
            app.launch()

            openEPUB("EPUBTest-Illustrated-A", expectedMarker: "EPUB_A_C2_P", stage: "after-relaunch", app)
            let restored = Self.parseCanvasValue(canvas.value as? String ?? "")
            XCTAssertEqual(restored["path"], "OEBPS/text/ch2.xhtml")
            XCTAssertEqual(Int(restored["node"] ?? "-1"), scrolledNode)
            XCTAssertGreaterThan(Int(restored["scrollY"] ?? "0") ?? 0, 20)

            openDirectory(app)
            XCTAssertTrue(chapter2.waitForExistence(timeout: 10))
            XCTAssertEqual(chapter2.value as? String, "当前章节")
            closePanel(app)
            exitReader(app, shelfBook: "EPUBTest-Illustrated-A")
        }
    }

    @MainActor func testEPUBTypographyNoCoverFallbackAndTXTIsolation() {
        withEPUBFixture { app in
            let noCoverRow = shelfRow(titled: "EPUBTest-NoCover-B", app)
            let txtRow = shelfRow(titled: "TXTTest-Companion-C", app)
            waitHittable(noCoverRow, timeout: 20)
            waitHittable(txtRow, timeout: 10)
            XCTAssertTrue(noCoverRow.label.contains("EPUB · 文字占位"))
            XCTAssertTrue(txtRow.label.contains("TXT"))

            openEPUB("EPUBTest-NoCover-B", expectedMarker: "EPUB_NOCOVER_START", stage: "open", app)
            openSettings(app)

            let darkButton = app.buttons["reader.theme.dark"]
            revealSetting(darkButton, app)
            darkButton.tap()
            XCTAssertEqual(darkButton.value as? String, "已选择")

            let relaxedButton = app.buttons["reader.preset.relaxed"]
            revealSetting(relaxedButton, app)
            relaxedButton.tap()
            XCTAssertEqual(relaxedButton.value as? String, "已选择")
            XCTAssertTrue(app.staticTexts["reader.font.value"].label.contains("24"))
            XCTAssertTrue(app.staticTexts["reader.spacing.value"].label.contains("10"))

            let scopeNote = app.staticTexts["epub.settings.scopeNote"]
            revealSetting(scopeNote, app)
            XCTAssertTrue(scopeNote.exists)
            let version = app.staticTexts["app.version"]
            revealSetting(version, app)
            XCTAssertTrue(version.label.contains("构建"))
            XCTAssertFalse(version.label.contains("未知"))

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
            XCTAssertEqual(XCTWaiter.wait(for: [updatedTypography], timeout: 10), .completed)
            exitReader(app, shelfBook: "EPUBTest-NoCover-B")

            openTXT("TXTTest-Companion-C", expectedMarker: "TXT_COMPANION_START", stage: "open-txt", app)
            openDirectory(app)
            XCTAssertTrue(app.buttons["reader.contents.bookmarks"].waitForExistence(timeout: 10))
            closePanel(app)
            exitReader(app, shelfBook: "TXTTest-Companion-C")
        }
    }

    // MARK: - Helpers (no helper method name may start with "test")

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
        waitHittable(row, timeout: 20)
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
            XCTWaiter.wait(for: [ready], timeout: max(0.1, deadline.timeIntervalSinceNow)),
            .completed,
            "Expected EPUB chapter content must be visible in the WebKit reader"
        )
        XCTAssertEqual(app.webViews.matching(identifier: "reader.viewport").count, 1,
                       "The EPUB reader must install exactly one interactive WebView")
        expandCDock(app, deadline: deadline, startsCollapsed: true)
        revealDockControl(app.buttons["reader.tools.settings"], app, deadline: deadline)
        waitHittable(app.buttons["reader.tools.settings"], timeout: max(0.1, deadline.timeIntervalSinceNow))
        Self.captureEvidence(app, testName: name, stage: stage, expectedBook: title)
    }

    @MainActor private func openTXT(
        _ title: String,
        expectedMarker: String,
        stage: String,
        _ app: XCUIApplication
    ) {
        let row = shelfRow(titled: title, app)
        waitHittable(row, timeout: 20)
        row.tap()
        let deadline = Date().addingTimeInterval(20)
        let marker = app.staticTexts.matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "reader.text.canvas", expectedMarker)
        ).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: max(0.1, deadline.timeIntervalSinceNow)))
        expandCDock(app, deadline: deadline, startsCollapsed: true)
        revealDockControl(app.buttons["reader.tools.settings"], app, deadline: deadline)
        waitHittable(app.buttons["reader.tools.settings"], timeout: max(0.1, deadline.timeIntervalSinceNow))
        Self.captureEvidence(app, testName: name, stage: stage, expectedBook: title)
    }

    @MainActor private func expandCDock(_ app: XCUIApplication, deadline: Date, startsCollapsed: Bool = false) {
        let expand = app.buttons["reader.tools.expand"]
        let collapse = app.buttons["reader.tools.collapse"]
        if startsCollapsed {
            waitHittable(expand, timeout: max(0.1, deadline.timeIntervalSinceNow))
            XCTAssertFalse(collapse.exists)
        } else {
            let presented = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    (expand.exists && expand.isHittable) || collapse.exists
                },
                object: nil
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [presented], timeout: max(0.1, deadline.timeIntervalSinceNow)),
                .completed
            )
        }
        if expand.exists && expand.isHittable {
            expand.tap()
        }
        let expanded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                collapse.exists && !expand.exists
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expanded], timeout: max(0.1, deadline.timeIntervalSinceNow)),
            .completed
        )
    }

    @MainActor private func revealDockControl(_ button: XCUIElement, _ app: XCUIApplication, deadline: Date) {
        let scroll = app.scrollViews["reader.tools.scroll"]
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
            waitHittable(button, timeout: max(0.1, deadline.timeIntervalSinceNow))
        }
    }

    @MainActor private func openSettings(_ app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(10)
        expandCDock(app, deadline: deadline)
        let button = app.buttons["reader.tools.settings"]
        revealDockControl(button, app, deadline: deadline)
        button.tap()
        waitHittable(app.buttons["reader.panel.close"])
    }

    @MainActor private func openDirectory(_ app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(10)
        expandCDock(app, deadline: deadline)
        let button = app.buttons["reader.tools.directory"]
        revealDockControl(button, app, deadline: deadline)
        button.tap()
        waitHittable(app.buttons["reader.panel.close"])
    }

    @MainActor private func closePanel(_ app: XCUIApplication) {
        app.buttons["reader.panel.close"].tap()
        revealDockControl(app.buttons["reader.tools.settings"], app, deadline: Date().addingTimeInterval(10))
    }

    @MainActor private func hasVisibleDockControl(_ app: XCUIApplication) -> Bool {
        let screen = app.windows.firstMatch.frame
        guard !screen.isNull, screen.width > 0, screen.height > 0 else { return false }
        let scroll = app.scrollViews["reader.tools.scroll"]
        let trayBounds = scroll.exists ? scroll.frame.intersection(screen) : screen
        for identifier in ["reader.tools.expand", "reader.tools.directory", "reader.tools.settings", "reader.tools.collapse"] {
            let button = app.buttons[identifier]
            guard button.exists, button.isHittable else { continue }
            let frame = button.frame
            let bounds = identifier == "reader.tools.expand" ? screen : trayBounds
            if !frame.isNull, frame.width > 0, frame.height > 0,
               !bounds.isNull, bounds.width > 0, bounds.height > 0,
               bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                return true
            }
        }
        return false
    }

    @MainActor private func showTools(_ app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(20)
        if !hasVisibleDockControl(app) {
            viewport(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let firstTouch = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in self.hasVisibleDockControl(app) },
                object: nil
            )
            let result = XCTWaiter.wait(for: [firstTouch], timeout: min(10, max(0.1, deadline.timeIntervalSinceNow)))
            if result != .completed {
                viewport(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }
        expandCDock(app, deadline: deadline)
        revealDockControl(app.buttons["reader.tools.settings"], app, deadline: deadline)
    }

    @MainActor private func exitReader(_ app: XCUIApplication, shelfBook title: String) {
        let deadline = Date().addingTimeInterval(10)
        let exit = app.buttons["reader.exit"]
        let settings = app.buttons["reader.tools.settings"]
        revealDockControl(settings, app, deadline: deadline)
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                exit.exists && exit.isHittable && exit.isEnabled && settings.exists && settings.isHittable && settings.isEnabled
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: max(0.1, deadline.timeIntervalSinceNow)), .completed)
        exit.tap()
        waitHittable(shelfRow(titled: title, app), timeout: max(0.1, deadline.timeIntervalSinceNow))
        XCTAssertFalse(app.staticTexts["暂时无法显示正文"].exists)
    }

    @MainActor private func revealSetting(_ element: XCUIElement, _ app: XCUIApplication) {
        let scroll = app.scrollViews["reader.settings.scroll"]
        for _ in 0..<10 {
            if element.exists && element.isHittable { break }
            if element.exists && element.frame.midY < scroll.frame.midY {
                scroll.swipeDown(velocity: .slow)
            } else {
                scroll.swipeUp(velocity: .slow)
            }
        }
        waitHittable(element)
    }

    @MainActor private func waitHittable(_ element: XCUIElement, timeout: TimeInterval = 10) {
        // Avoid the predicate waiter's scheduling delay when the real control is ready.
        if element.exists && element.isHittable && element.isEnabled { return }
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                element.exists && element.isHittable && element.isEnabled
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
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

    @MainActor private func selectReadingMode(_ title: String, rawValue: String, _ app: XCUIApplication) {
        // Mode selection is setup here; do not repeat a no-op menu round trip.
        // The cross-chapter flow still exercises both actual mode transitions.
        if Self.parseCanvasValue(readerCanvas(app).value as? String ?? "")["mode"] == rawValue {
            XCTAssertEqual(Self.parseCanvasValue(readerCanvas(app).value as? String ?? "")["mode"], rawValue)
            return
        }
        showTools(app)
        openSettings(app)
        let picker = app.segmentedControls["epub.readingMode"]
        revealSetting(picker, app)
        let option = picker.buttons[title]
        waitHittable(option)
        option.tap()
        closePanel(app)
        let canvas = readerCanvas(app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Self.parseCanvasValue(canvas.value as? String ?? "")["mode"] == rawValue
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 12), .completed)
        let collapse = app.buttons["reader.tools.collapse"]
        if collapse.exists && collapse.isHittable { collapse.tap() }
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
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
        }
        waitFor { coordinate("window") == 3 }
        let initialLoads = coordinate("loads")
        let initialX = coordinate("scrollX")
        view.swipeLeft(velocity: .default)
        waitFor { coordinate("scrollX") > initialX }
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

        showTools(app)
        openDirectory(app)
        let chapter3 = app.buttons["reader.chapter.3"]
        waitHittable(chapter3)
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
        showTools(app)
    }
}

import XCTest
import UIKit

final class ReadingFlowUITests: XCTestCase {
    @MainActor private static var finalEvidenceCases: Set<String> = []
    @MainActor private static var pendingExitEvidenceCases: Set<String> = []

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDown() async throws {
        let testName = name
        await MainActor.run {
            let app = XCUIApplication()
            let key = ReadingFlowUITests.evidenceCase(testName)
            if !ReadingFlowUITests.finalEvidenceCases.contains(key) {
                ReadingFlowUITests.captureEvidence(app, testName: key, stage: "teardown-fallback",
                    includeExitReadiness: ReadingFlowUITests.pendingExitEvidenceCases.contains(key))
                ReadingFlowUITests.finalEvidenceCases.insert(key)
            }
            ReadingFlowUITests.pendingExitEvidenceCases.remove(key)
            app.terminate()
        }
        try await super.tearDown()
    }

    @MainActor func testSettingsCloseThenScrollExitAndReopenSameAndOtherBook() {
        withFixture { app in
            open("UITest-Long-A", app)
            openSettings(app)
            app.buttons["reader.font.increase"].tap()
            XCTAssertTrue(app.staticTexts["reader.font.value"].label.contains("21"))
            closePanel(app)
            let before = visibleCanvases(app)
            XCTAssertFalse(before.isEmpty)
            viewport(app).swipeUp(velocity: .slow)
            let after = visibleCanvases(app)
            XCTAssertFalse(after.isEmpty)
            XCTAssertNotEqual(after, before)
            showTools(app); exitReader(app)
            open("UITest-Long-A", app); openSettings(app)
            XCTAssertTrue(app.staticTexts["reader.font.value"].label.contains("21"))
            closePanel(app); exitReader(app)
            open("UITest-Short-B", app)
            XCTAssertTrue(endMarker("UI-END-B", app).waitForExistence(timeout: 10))
        }
    }

    @MainActor func testReaderThemeDoesNotChangeShelfEnvironment() {
        withFixture { app in
            let probe = app.staticTexts["ui.fixture.shelf.scheme"]
            XCTAssertTrue(probe.waitForExistence(timeout: 15))
            guard let shelfScheme = probe.value as? String,
                  ["light", "dark"].contains(String(shelfScheme.split(separator: "|").first ?? "")) else {
                XCTFail("Mounted shelf did not expose a valid color scheme"); return
            }
            let choice = shelfScheme.hasPrefix("light") ? "dark" : "light"
            open("UITest-Long-A", app); openSettings(app)
            app.buttons["reader.theme.\(choice)"].tap()
            XCTAssertEqual(app.buttons["reader.theme.\(choice)"].value as? String, "已选择")
            closePanel(app); exitReader(app)
            XCTAssertTrue(probe.waitForExistence(timeout: 10))
            XCTAssertEqual(probe.value as? String, shelfScheme)
            open("UITest-Short-B", app); openSettings(app)
            XCTAssertEqual(app.buttons["reader.theme.\(choice)"].value as? String, "已选择")
            closePanel(app)
        }
    }

    @MainActor func testDirectoryPagingCurrentChapterAndReentryAfterSettings() {
        withFixture { app in
            open("UITest-Long-A", app); openDirectory(app)
            scrollTo(app.buttons["下一组"], in: app.tables.firstMatch)
            app.buttons["下一组"].tap()
            let chapter = app.buttons["reader.chapter.32"]
            waitHittable(chapter); chapter.tap()
            XCTAssertTrue(endMarker("UI_CHAPTER_33", app).waitForExistence(timeout: 10))
            showTools(app); openSettings(app)
            app.buttons["reader.spacing.increase"].tap(); closePanel(app)
            openDirectory(app)
            XCTAssertTrue(chapter.waitForExistence(timeout: 10))
            XCTAssertEqual(chapter.value as? String, "当前章节")
            closePanel(app); exitReader(app)
            open("UITest-Long-A", app); openDirectory(app)
            XCTAssertTrue(chapter.waitForExistence(timeout: 10))
            XCTAssertEqual(chapter.value as? String, "当前章节")
            closePanel(app)
        }
    }

    @MainActor func testFullViewportStaysStableAndLongAndShortBookLastLinesFit() {
        withFixture { app in
            open("UITest-Short-B", app)
            let frame = viewport(app).frame, screen = app.windows.firstMatch.frame
            XCTAssertLessThanOrEqual(frame.minY - screen.minY, 65)
            XCTAssertLessThanOrEqual(screen.maxY - frame.maxY, 50)
            viewport(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertFalse(app.buttons["reader.tools.settings"].isHittable)
            assertSameFrame(viewport(app).frame, frame)
            let last = endMarker("UI-END-B", app)
            XCTAssertTrue(last.waitForExistence(timeout: 10))
            XCTAssertGreaterThanOrEqual(last.frame.minY, frame.minY - 0.5)
            XCTAssertLessThanOrEqual(last.frame.maxY, frame.maxY + 0.5)
            showTools(app); assertSameFrame(viewport(app).frame, frame)
            openSettings(app); closePanel(app)
            assertSameFrame(viewport(app).frame, frame)
            exitReader(app); open("UITest-Long-A", app); openDirectory(app)
            scrollTo(app.buttons["下一组"], in: app.tables.firstMatch); app.buttons["下一组"].tap()
            let finalChapter = app.buttons["reader.chapter.39"]
            scrollTo(finalChapter, in: app.tables.firstMatch); finalChapter.tap()
            XCTAssertTrue(endMarker("UI-END-A", app).waitForExistence(timeout: 10))
            // The final nonempty fixture line is UI-END-A. Inspect the visible final canvas's
            // trailing geometry, not just an offscreen AX marker or the whole tall cell's top.
            for _ in 0..<8 {
                if let end = visibleCanvases(app).last(where: { $0.label.contains("UI-END-A") }),
                   end.frame.maxY <= viewport(app).frame.maxY + 0.5 { break }
                viewport(app).swipeUp(velocity: .slow)
            }
            guard let end = visibleCanvases(app).last(where: { $0.label.contains("UI-END-A") }) else {
                XCTFail("Long-book EOF canvas never entered the viewport"); return
            }
            XCTAssertLessThanOrEqual(end.frame.maxY, viewport(app).frame.maxY + 0.5)
            XCTAssertGreaterThan(end.frame.maxY, viewport(app).frame.minY + 44)
        }
    }

    @MainActor func testRepeatedPanelsAndAuxiliarySheetsReturnOnlyToReading() {
        withFixture { app in
            open("UITest-Long-A", app)
            for _ in 0..<3 {
                openSettings(app); closePanel(app)
                openDirectory(app); closePanel(app)
            }
            openSettings(app)
            for key in ["diagnostics", "license"] {
                let entry = app.buttons["reader.info.\(key)"]
                scrollTo(entry, in: app.scrollViews.firstMatch); entry.tap()
                let done = app.buttons["reader.info.close"]
                waitHittable(done); done.tap()
                waitHittable(app.buttons["reader.panel.close"])
                XCTAssertFalse(app.buttons["reader.exit"].isHittable)
            }
            closePanel(app)
            XCTAssertTrue(viewport(app).exists)
            waitHittable(app.buttons["reader.exit"])
        }
    }

    @MainActor func testAccessibilityFontLeavesExitAndPanelControlsReachable() {
        withFixture(largeText: true) { app in
            let probe = app.staticTexts["ui.fixture.shelf.scheme"]
            XCTAssertTrue(probe.waitForExistence(timeout: 15))
            XCTAssertTrue((probe.value as? String)?.contains("accessibility") == true)
            open("UITest-Short-B", app)
            XCTAssertGreaterThanOrEqual(app.buttons["reader.exit"].frame.height, 44)
            openSettings(app)
            let close = app.buttons["reader.panel.close"]
            XCTAssertGreaterThanOrEqual(close.frame.height, 44)
            closePanel(app); exitReader(app)
        }
    }

    @MainActor private func withFixture(largeText: Bool = false, testName: String = #function,
                                      _ run: (XCUIApplication) -> Void) {
        let orientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["YUEJING_UI_TEST_SESSION"] = UUID().uuidString
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        let key = Self.evidenceCase(testName)
        Self.finalEvidenceCases.remove(key)
        Self.pendingExitEvidenceCases.remove(key)
        defer {
            // Always collect while this App is alive, before either termination path.
            Self.captureEvidence(app, testName: key, stage: "before-terminate",
                includeExitReadiness: Self.pendingExitEvidenceCases.contains(key))
            Self.finalEvidenceCases.insert(key)
            Self.pendingExitEvidenceCases.remove(key)
            app.terminate(); XCUIDevice.shared.orientation = orientation
        }
        app.launch(); run(app)
    }
    @MainActor private func open(_ title: String, _ app: XCUIApplication) {
        let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        waitHittable(book, timeout: 20); book.tap()
        // Content and tools share the original 20-second post-tap budget.
        let deadline = Date().addingTimeInterval(20)
        let marker = title == "UITest-Long-A" ? "UI_A_C" : "UI-END-B"
        let table = viewport(app)
        let visibleBook = NSPredicate { _, _ in
            guard table.exists, table.isHittable else { return false }
            let bounds = table.frame.intersection(app.windows.firstMatch.frame)
            guard !bounds.isNull, bounds.width >= 100, bounds.height >= 100 else { return false }
            return table.cells.allElementsBoundByIndex.contains { cell in
                let canvas = cell.staticTexts["reader.text.canvas"]
                guard canvas.exists, canvas.label.contains(marker) else { return false }
                let visible = canvas.frame.intersection(bounds)
                return !visible.isNull && visible.width >= 100 && visible.height >= 44
            }
        }
        let ready = XCTNSPredicateExpectation(predicate: visibleBook, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: max(0.01, deadline.timeIntervalSinceNow)), .completed,
                       "The expected synthetic book must have content geometrically visible in the reader viewport")
        waitHittable(app.buttons["reader.tools.settings"], timeout: max(0.01, deadline.timeIntervalSinceNow))
        Self.captureEvidence(app, testName: name, stage: "open", expectedBook: title)
    }

    private static func evidenceCase(_ value: String) -> String {
        value.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            .last(where: { $0.hasPrefix("test") }).map(String.init) ?? "unknown-case"
    }

    @MainActor private static func captureEvidence(_ app: XCUIApplication, testName: String, stage: String,
                                                   expectedBook: String? = nil, includeExitReadiness: Bool = false) {
        let key = evidenceCase(testName)
        let stateSampledAt = Date().timeIntervalSince1970
        let state = app.state
        let screenshotStartedAt = Date().timeIntervalSince1970
        let screenshot = state == .runningForeground ? app.screenshot() : XCUIScreen.main.screenshot()
        let screenshotEndedAt = Date().timeIntervalSince1970
        let prefix = "YueJingUI--\(key)--\(stage)"
        let image = XCTAttachment(data: screenshot.pngRepresentation, uniformTypeIdentifier: "public.png")
        image.name = prefix + ".png"; image.lifetime = .keepAlways
        XCTContext.runActivity(named: prefix) { activity in activity.add(image) }
        // Persist the PNG before any subsequent AX query can fail or time out.
        if includeExitReadiness, state != .notRunning, state != .unknown {
            // Each query has its own interval. These observations are not an atomic snapshot.
            @MainActor func sample(_ label: String, _ read: @MainActor () -> String) -> String {
                let startedAt = Date().timeIntervalSince1970
                let value = read()
                return "\(label): startedAtUnix=\(startedAt), endedAtUnix=\(Date().timeIntervalSince1970), value=\(value)\n"
            }
            let exit = app.buttons["reader.exit"], settings = app.buttons["reader.tools.settings"]
            let viewport = app.tables["reader.viewport"], window = app.windows.firstMatch
            var observations = "Sequential observations after the PNG; not atomic or proof of the tap-time state.\n"
            observations += sample("reader.exit.exists") { String(exit.exists) }
            observations += sample("reader.exit.isHittable") { String(exit.isHittable) }
            observations += sample("reader.exit.frame") { exit.exists ? String(describing: exit.frame) : "unavailable: not found during this query" }
            observations += sample("reader.tools.settings.exists") { String(settings.exists) }
            observations += sample("reader.tools.settings.isHittable") { String(settings.isHittable) }
            observations += sample("reader.viewport.frame") { viewport.exists ? String(describing: viewport.frame) : "unavailable: not found during this query" }
            observations += sample("window.frame") { window.exists ? String(describing: window.frame) : "unavailable: not found during this query" }
            let properties = XCTAttachment(data: Data(observations.utf8), uniformTypeIdentifier: "public.utf8-plain-text")
            properties.name = prefix + ".readiness.txt"; properties.lifetime = .keepAlways
            XCTContext.runActivity(named: prefix + "--readiness") { activity in activity.add(properties) }
        }
        let axStartedAt = Date().timeIntervalSince1970
        let description = state == .notRunning || state == .unknown
            ? "App is not running; a full App AX hierarchy is unavailable."
            : app.debugDescription
        let axEndedAt = Date().timeIntervalSince1970
        let descriptionText = "YueJing UI evidence\ncase: \(key)\nstage: \(stage)\nappState: \(state.rawValue)\nexpectedBook: \(expectedBook ?? "not specified")\nstateSampledAtUnix: \(stateSampledAt)\nscreenshotStartedAtUnix: \(screenshotStartedAt)\nscreenshotEndedAtUnix: \(screenshotEndedAt)\naxStartedAtUnix: \(axStartedAt)\naxEndedAtUnix: \(axEndedAt)\nobservationsAreSequential: true\nfullAppDebugDescription:\n\(description)"
        let text = XCTAttachment(data: Data(descriptionText.utf8), uniformTypeIdentifier: "public.utf8-plain-text")
        text.name = prefix + ".ax.txt"; text.lifetime = .keepAlways
        XCTContext.runActivity(named: prefix + "--ax") { activity in activity.add(text) }
    }
    @MainActor private func viewport(_ app: XCUIApplication) -> XCUIElement { app.tables["reader.viewport"] }
    @MainActor private func openSettings(_ app: XCUIApplication) {
        let button = app.buttons["reader.tools.settings"]; waitHittable(button); button.tap()
        waitHittable(app.buttons["reader.panel.close"])
        XCTAssertFalse(app.buttons["reader.exit"].isHittable)
    }
    @MainActor private func openDirectory(_ app: XCUIApplication) {
        let button = app.buttons["reader.tools.directory"]; waitHittable(button); button.tap()
        waitHittable(app.buttons["reader.panel.close"])
    }
    @MainActor private func closePanel(_ app: XCUIApplication) {
        app.buttons["reader.panel.close"].tap()
        waitHittable(app.buttons["reader.tools.settings"])
    }
    @MainActor private func exitReader(_ app: XCUIApplication) {
        // Readiness and return-to-shelf share the original ten-second shelf-wait budget.
        let deadline = Date().addingTimeInterval(10)
        let key = Self.evidenceCase(name)
        Self.pendingExitEvidenceCases.insert(key)
        let exit = app.buttons["reader.exit"], settings = app.buttons["reader.tools.settings"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            exit.exists && exit.isHittable && settings.exists && settings.isHittable
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: max(0, deadline.timeIntervalSinceNow))
        guard result == .completed else {
            Self.captureEvidence(app, testName: key, stage: "exit-not-hittable", includeExitReadiness: true)
            XCTAssertEqual(result, .completed, "Both reading controls, including the exit target itself, must be hittable within the shared budget")
            return
        }
        app.buttons["reader.exit"].tap()
        waitHittable(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "UITest-Long-A")).firstMatch,
                     timeout: max(0, deadline.timeIntervalSinceNow))
        XCTAssertFalse(app.staticTexts["暂时无法显示正文"].exists)
        Self.pendingExitEvidenceCases.remove(key)
    }
    @MainActor private func showTools(_ app: XCUIApplication) {
        if !app.buttons["reader.tools.settings"].isHittable {
            viewport(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if !app.buttons["reader.tools.settings"].waitForExistence(timeout: 10) {
                // Finite protocol: the first tap may only stop inertia; one subsequent tap
                // must reveal tools. This helper does not claim to verify the inertia policy.
                viewport(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }
        waitHittable(app.buttons["reader.tools.settings"])
    }
    @MainActor private func endMarker(_ text: String, _ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "reader.text.canvas", text)).firstMatch
    }
    private struct CanvasSample: Equatable { let label: String; let frame: CGRect }
    @MainActor private func visibleCanvases(_ app: XCUIApplication) -> [CanvasSample] {
        let visible = viewport(app).frame
        var samples: [CanvasSample] = []
        // DerivedReadingLayoutEngine.slices uses 0..<7. Enumerate that entire bounded
        // window and filter by geometry; never truncate a possible visible EOF cell.
        for cell in viewport(app).cells.allElementsBoundByIndex {
            guard cell.exists else { continue }
            let frame = cell.frame, overlap = frame.intersection(visible)
            guard !overlap.isNull, overlap.width > 1, overlap.height > 1 else { continue }
            let canvas = cell.staticTexts["reader.text.canvas"]
            if canvas.exists { samples.append(CanvasSample(label: canvas.label, frame: frame)) }
        }
        return samples.sorted { $0.frame.minY < $1.frame.minY }
    }
    @MainActor private func scrollTo(_ element: XCUIElement, in scroll: XCUIElement) {
        for _ in 0..<12 { if element.isHittable { break }; scroll.swipeUp(velocity: .slow) }
        waitHittable(element)
    }
    @MainActor private func waitHittable(_ element: XCUIElement, timeout: TimeInterval = 10) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
    }
    private func assertSameFrame(_ actual: CGRect, _ expected: CGRect) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5); XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5); XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
    }
}

import XCTest
import UIKit

final class ReadingFlowUITests: XCTestCase {
    @MainActor private static var finalEvidenceCases: Set<String> = []
    @MainActor private static var pendingExitEvidenceCases: Set<String> = []
    @MainActor private static var hitProbeSessions: [String: String] = [:]
    @MainActor private static var hitProbeSequences: [String: Int] = [:]
    @MainActor private static var hitProbeRoutes: [String: String] = [:]
    @MainActor private static var hitProbeWindows: [String: String] = [:]
    @MainActor private static var hitProbePIDs: [String: Int] = [:]

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
            Self.captureEvidence(app, testName: name, stage: "probe-baseline", includeExitReadiness: true)
            let before = visibleCanvases(app)
            XCTAssertFalse(before.isEmpty)
            viewport(app).swipeUp(velocity: .slow)
            let after = visibleCanvases(app)
            XCTAssertFalse(after.isEmpty)
            XCTAssertNotEqual(after, before)
            Self.captureEvidence(app, testName: name, stage: "probe-after-scroll", includeExitReadiness: true)
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

    // New acceptance cases; the original six flows and budgets remain intact.
    @MainActor func testTypographySliderPresetsAndConfirmedRestore() {
        withFixture { app in
            open("UITest-Long-A", app); openSettings(app)
            let font = app.sliders["reader.font.slider"]
            revealSetting(font, app); font.adjust(toNormalizedSliderPosition: 0)
            XCTAssertTrue(app.staticTexts["reader.font.value"].label.contains("14"))
            XCTAssertFalse(app.buttons["reader.font.decrease"].isEnabled)
            revealSetting(font, app); font.adjust(toNormalizedSliderPosition: 1)
            XCTAssertTrue(app.staticTexts["reader.font.value"].label.contains("36"))
            XCTAssertFalse(app.buttons["reader.font.increase"].isEnabled)
            let spacing = app.sliders["reader.spacing.slider"]
            revealSetting(spacing, app); spacing.adjust(toNormalizedSliderPosition: 1)
            XCTAssertTrue(app.staticTexts["reader.spacing.value"].label.contains("20"))
            XCTAssertFalse(app.buttons["reader.spacing.increase"].isEnabled)
            let dark = app.buttons["reader.theme.dark"]
            revealSetting(dark, app); dark.tap()
            for preset in ["compact", "standard", "relaxed"] {
                let button = app.buttons["reader.preset.\(preset)"]
                revealSetting(button, app); button.tap()
                XCTAssertEqual(button.value as? String, "已选择")
                XCTAssertEqual(dark.value as? String, "已选择")
            }
            let restore = app.buttons["reader.typography.restore"]
            revealSetting(restore, app); restore.tap()
            let cancel = app.buttons["取消"]
            waitHittable(cancel); cancel.tap()
            XCTAssertEqual(app.buttons["reader.preset.relaxed"].value as? String, "已选择")
            restore.tap()
            let confirm = app.buttons["恢复字号与行距"]
            waitHittable(confirm); confirm.tap()
            XCTAssertEqual(app.buttons["reader.preset.standard"].value as? String, "已选择")
            XCTAssertEqual(dark.value as? String, "已选择")
            let decrease = app.buttons["reader.font.decrease"]
            revealSetting(decrease, app); decrease.tap()
            XCTAssertTrue(app.staticTexts["reader.font.value"].label.contains("19"))
            let standard = app.buttons["reader.preset.standard"]
            revealSetting(standard, app)
            XCTAssertEqual(standard.value as? String, "未选择")
            closePanel(app); exitReader(app)
            open("UITest-Long-A", app); openSettings(app)
            XCTAssertTrue(app.staticTexts["reader.font.value"].label.contains("19"))
            XCTAssertTrue(app.staticTexts["reader.spacing.value"].label.contains("7"))
            closePanel(app)
        }
    }

    @MainActor func testTypographyAndChapterSurviveProcessRelaunch() {
        withFixture { app in
            open("UITest-Long-A", app); openDirectory(app)
            scrollTo(app.buttons["下一组"], in: app.tables.firstMatch)
            app.buttons["下一组"].tap()
            let chapter = app.buttons["reader.chapter.32"]
            waitHittable(chapter); chapter.tap()
            XCTAssertTrue(endMarker("UI_CHAPTER_33", app).waitForExistence(timeout: 10))
            showTools(app); openSettings(app)
            let dark = app.buttons["reader.theme.dark"]
            revealSetting(dark, app); dark.tap()
            let relaxed = app.buttons["reader.preset.relaxed"]
            revealSetting(relaxed, app); relaxed.tap()
            closePanel(app); exitReader(app)
            open("UITest-Short-B", app); exitReader(app)
            Self.captureEvidence(app, testName: name, stage: "before-relaunch")
            // Retain this fixture UUID/database across process termination; never reset it.
            app.terminate(); app.launch()
            open("UITest-Long-A", app); openDirectory(app)
            XCTAssertTrue(chapter.waitForExistence(timeout: 10))
            XCTAssertEqual(chapter.value as? String, "当前章节")
            closePanel(app); openSettings(app)
            XCTAssertTrue(app.staticTexts["reader.font.value"].label.contains("24"))
            XCTAssertTrue(app.staticTexts["reader.spacing.value"].label.contains("10"))
            revealSetting(dark, app)
            XCTAssertEqual(dark.value as? String, "已选择")
            revealSetting(relaxed, app)
            XCTAssertEqual(relaxed.value as? String, "已选择")
            closePanel(app)
            Self.captureEvidence(app, testName: name, stage: "after-relaunch")
        }
    }

    @MainActor private func revealSetting(_ element: XCUIElement, _ app: XCUIApplication) {
        let scroll = app.scrollViews["reader.settings.scroll"]
        for _ in 0..<12 {
            if element.isHittable { break }
            if element.exists && element.frame.midY < scroll.frame.midY {
                scroll.swipeDown(velocity: .slow)
            } else {
                scroll.swipeUp(velocity: .slow)
            }
        }
        waitHittable(element)
    }

    @MainActor private func withFixture(largeText: Bool = false, testName: String = #function,
                                      _ run: (XCUIApplication) -> Void) {
        let orientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let session = UUID().uuidString
        app.launchEnvironment["YUEJING_UI_TEST_SESSION"] = session
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        let key = Self.evidenceCase(testName)
        Self.finalEvidenceCases.remove(key)
        Self.pendingExitEvidenceCases.remove(key)
        Self.hitProbeSessions.removeValue(forKey: key)
        Self.hitProbeSequences.removeValue(forKey: key)
        Self.hitProbeRoutes.removeValue(forKey: key)
        Self.hitProbeWindows.removeValue(forKey: key)
        Self.hitProbePIDs.removeValue(forKey: key)
        if key == "testSettingsCloseThenScrollExitAndReopenSameAndOtherBook" {
            app.launchEnvironment["YUEJING_READER_HIT_PROBE"] = "1"
            Self.hitProbeSessions[key] = session
        }
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
                                                   expectedBook: String? = nil, includeExitReadiness: Bool = false,
                                                   probeDeadline: Date? = nil) {
        let key = evidenceCase(testName)
        let evidenceStartedUptime = ProcessInfo.processInfo.systemUptime
        let probeBudgetAtStart = probeDeadline.map { String($0.timeIntervalSinceNow) } ?? "not-applicable"
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
        if includeExitReadiness, hitProbeSessions[key] != nil, state == .runningForeground {
            captureHitProbe(app, key: key, prefix: prefix, deadline: probeDeadline)
        }
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
            observations += sample("reader.tools.settings.frame") { settings.exists ? String(describing: settings.frame) : "unavailable: not found during this query" }
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
        let probeBudgetAtEnd = probeDeadline.map { String($0.timeIntervalSinceNow) } ?? "not-applicable"
        let evidenceDuration = ProcessInfo.processInfo.systemUptime - evidenceStartedUptime
        let descriptionText = "YueJing UI evidence\ncase: \(key)\nstage: \(stage)\nappState: \(state.rawValue)\nexpectedBook: \(expectedBook ?? "not specified")\nstateSampledAtUnix: \(stateSampledAt)\nscreenshotStartedAtUnix: \(screenshotStartedAt)\nscreenshotEndedAtUnix: \(screenshotEndedAt)\naxStartedAtUnix: \(axStartedAt)\naxEndedAtUnix: \(axEndedAt)\nprobeBudgetAtStartSeconds: \(probeBudgetAtStart)\nprobeBudgetAtEndSeconds: \(probeBudgetAtEnd)\nevidenceDurationSeconds: \(evidenceDuration)\nobservationsAreSequential: true\nfullAppDebugDescription:\n\(description)"
        let text = XCTAttachment(data: Data(descriptionText.utf8), uniformTypeIdentifier: "public.utf8-plain-text")
        text.name = prefix + ".ax.txt"; text.lifetime = .keepAlways
        XCTContext.runActivity(named: prefix + "--ax") { activity in activity.add(text) }
    }
    @MainActor private static func captureHitProbe(_ app: XCUIApplication, key: String, prefix: String, deadline: Date?) {
        var record: [String: Any] = ["validation": "unknown", "sequentialNotAtomic": true,
            "runnerPID": ProcessInfo.processInfo.processIdentifier, "queryStartedUptime": ProcessInfo.processInfo.systemUptime,
            "insideSharedFunctionalBudget": deadline != nil, "observationMayChangeTiming": true]
        if let deadline { record["budgetRemainingAtStartSeconds"] = deadline.timeIntervalSinceNow }
        var reasons: [String] = []
        @MainActor func rectangle(_ element: XCUIElement) -> CGRect? { element.exists ? element.frame : nil }
        if let deadline, deadline.timeIntervalSinceNow <= 0 { reasons.append("shared-budget-expired-no-probe-read") }
        else {
            let frameStarted = ProcessInfo.processInfo.systemUptime
            let exitRect = rectangle(app.buttons["reader.exit"]), settingsRect = rectangle(app.buttons["reader.tools.settings"])
            record["frameQueryStartedUptime"] = frameStarted
            record["frameQueryEndedUptime"] = ProcessInfo.processInfo.systemUptime
            if let rect = exitRect { record["testExitFrame"] = [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)] }
            if let rect = settingsRect { record["testSettingsFrame"] = [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)] }
            let started = ProcessInfo.processInfo.systemUptime
            let endpoint = app.descendants(matching: .any).matching(identifier: "ui.fixture.reader.hitprobe").firstMatch
            if let deadline, deadline.timeIntervalSinceNow <= 0 { reasons.append("shared-budget-expired-before-value") }
            else if endpoint.exists, let raw = endpoint.value as? String, raw.utf8.count <= 65536,
                    let payload = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: payload),
                    let value = object as? [String: Any] {
                let ended = ProcessInfo.processInfo.systemUptime
                record["valueQueryStartedUptime"] = started; record["valueQueryEndedUptime"] = ended
                record["appSample"] = value
                if value["schema"] as? Int != 1 { reasons.append("unsupported-probe-schema") }
                if value["nonce"] as? String != hitProbeSessions[key] || value["bundle"] as? String != "dev.yuejing.app" {
                    reasons.append("process-or-fixture-identity-mismatch")
                }
                if let pid = value["appPID"] as? Int, pid > 0, pid != Int(ProcessInfo.processInfo.processIdentifier) {
                    if let expected = hitProbePIDs[key], expected != pid { reasons.append("app-process-changed") }
                    if reasons.isEmpty { hitProbePIDs[key] = pid }
                } else { reasons.append("missing-or-runner-process") }
                if let from = value["startedUptime"] as? Double, let to = value["endedUptime"] as? Double {
                    record["ageAtReadSeconds"] = ended - to
                    if from < started || to > ended || to < from { reasons.append("cached-or-clock-mismatched-value") }
                } else { reasons.append("missing-sample-time") }
                if let sequence = value["sequence"] as? Int {
                    if sequence <= (hitProbeSequences[key] ?? 0) { reasons.append("non-increasing-sequence") }
                    hitProbeSequences[key] = max(sequence, hitProbeSequences[key] ?? 0)
                } else { reasons.append("missing-sequence") }
                if let route = value["routeID"] as? String, let window = value["windowToken"] as? String {
                    if let expected = hitProbeRoutes[key], expected != route { reasons.append("route-mismatch") }
                    if let expected = hitProbeWindows[key], expected != window { reasons.append("window-mismatch") }
                    if reasons.isEmpty { hitProbeRoutes[key] = route; hitProbeWindows[key] = window }
                } else { reasons.append("missing-route-or-window") }
                @MainActor func matches(_ raw: Any?, _ expected: CGRect?) -> Bool {
                    guard let actual = raw as? [Double], actual.count == 4, let expected else { return false }
                    return zip(actual, [Double(expected.minX), Double(expected.minY), Double(expected.width), Double(expected.height)])
                        .allSatisfy { $0.0.isFinite && abs($0.0 - $0.1) <= 0.5 }
                }
                if !matches(value["exitScreenRect"], exitRect) { reasons.append("marker-and-AX-geometry-unconfirmed") }
                let hit = value["hit"] as? [String: Any]
                record["bottomGeometryValidation"] = matches(hit?["bottomScreenRect"], settingsRect)
                    ? "matched-sequentially-not-atomic" : "unknown-unavailable-or-mismatched"
                if value["status"] as? String != "observed" { reasons.append("app-reported-unknown") }
                if reasons.isEmpty { record["validation"] = "observed-within-read-interval-not-atomic" }
            } else { reasons.append("probe-unavailable-or-unreadable-no-retry") }
        }
        record["unknownReasons"] = reasons; record["queryEndedUptime"] = ProcessInfo.processInfo.systemUptime
        if let deadline { record["budgetRemainingAtEndSeconds"] = deadline.timeIntervalSinceNow }
        let data = (try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])) ?? Data("{\"validation\":\"unknown-encoding\"}".utf8)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.utf8-plain-text")
        attachment.name = prefix + ".hitprobe.json"; attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: prefix + "--hitprobe") { activity in activity.add(attachment) }
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
        if Self.hitProbeSessions[key] != nil {
            Self.captureEvidence(app, testName: key, stage: "probe-after-show", includeExitReadiness: true, probeDeadline: deadline)
        }
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
        if Self.hitProbeSessions[key] != nil {
            Self.captureEvidence(app, testName: key, stage: "exit-hittable", includeExitReadiness: true, probeDeadline: deadline)
        }
        app.buttons["reader.exit"].tap()
        waitHittable(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "UITest-Long-A")).firstMatch,
                     timeout: max(0, deadline.timeIntervalSinceNow))
        XCTAssertFalse(app.staticTexts["暂时无法显示正文"].exists)
        Self.pendingExitEvidenceCases.remove(key)
        Self.hitProbeSequences.removeValue(forKey: key)
        Self.hitProbeRoutes.removeValue(forKey: key)
        Self.hitProbeWindows.removeValue(forKey: key)
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

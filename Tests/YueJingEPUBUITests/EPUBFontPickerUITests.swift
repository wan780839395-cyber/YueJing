import XCTest

final class EPUBFontPickerUITests: XCTestCase {
    @MainActor func testRevisedCardOpensFilesAndReturns() {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let app = XCUIApplication()
        let session = UUID().uuidString
        app.launchEnvironment["YUEJING_EPUB_UI_TEST_SESSION"] = session
        app.launchArguments += ["-epub-font-picker-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        addTeardownBlock { @MainActor in
            if (self.testRun?.failureCount ?? 0) > 0 { print("Synthetic font picker failure hierarchy: " + String(app.debugDescription.prefix(24000))) }
            app.terminate()
        }

        let selection = app.buttons["epub.font.selection"]
        let openFiles = app.buttons["epub.font.import"]
        let empty = app.descendants(matching: .any).matching(identifier: "epub.font.empty").firstMatch
        let notice = app.descendants(matching: .any).matching(identifier: "epub.font.notice").firstMatch
        let selectedOriginal = app.staticTexts["fixture.font.originalSelected"]
        XCTAssertTrue(empty.waitForExistence(timeout: 8), "Use a clean simulator font library")
        XCTAssertEqual(selection.value as? String, "跟随原书")
        requireInteractive(openFiles)
        openFiles.tap()

        // The fixture contains no Files controls. Require system browser chrome as
        // well as Cancel; a generic modal with a dismissal button is not enough.
        let filesChrome = app.descendants(matching: .any).matching(NSPredicate(
            format: "label IN %@", ["Browse", "Recents", "Locations", "浏览", "最近项目", "位置"]
        )).firstMatch
        XCTAssertTrue(filesChrome.waitForExistence(timeout: 10), "Expected the system Files browser")
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        requireInteractive(cancel)
        cancel.tap()

        requireInteractive(openFiles)
        XCTAssertFalse(cancel.exists)
        XCTAssertTrue(empty.exists)
        XCTAssertFalse(notice.exists, "Cancel must not be reported as an import or error")
        XCTAssertFalse(selectedOriginal.exists, "Cancel must not select a font")
        XCTAssertEqual(selection.value as? String, "跟随原书")

        requireInteractive(selection)
        selection.tap()
        let original = app.buttons.matching(NSPredicate(format: "label == %@", "跟随原书")).firstMatch
        requireInteractive(original)
        original.tap()
        XCTAssertTrue(selectedOriginal.waitForExistence(timeout: 5), "Expected the card's select(nil) action")

        let export = app.buttons["fixture.font.export"]
        requireInteractive(export)
        export.tap()
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "存储", "保存"])).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 8), "Expected the Files export sheet")
        openLocalRoot(app)
        requireInteractive(save)
        save.tap()
        let exportResult = app.staticTexts["fixture.font.exportStatus"]
        XCTAssertTrue(exportResult.waitForExistence(timeout: 8))
        XCTAssertEqual(exportResult.label, "Saved", "Expected a successful Files export callback")

        requireInteractive(openFiles)
        openFiles.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        let name = NSPredicate(format: "label BEGINSWITH[c] %@", "YJFont-\(session.prefix(8))")
        let namedItem = app.descendants(matching: .any).matching(name).firstMatch
        if !namedItem.waitForExistence(timeout: 2) { openLocalRoot(app) }
        XCTAssertTrue(namedItem.waitForExistence(timeout: 6), "The exported TTF must appear in Files")
        let cell = app.cells.matching(name).firstMatch
        let item = cell.exists ? cell : namedItem
        requireInteractive(item)
        item.tap()
        if !notice.waitForExistence(timeout: 2) {
            let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
            if open.exists && open.isHittable && open.isEnabled { open.tap() }
        }
        let fullName = "YueJingTestGeometric Regular" // SFNT full name, not the exported filename
        XCTAssertTrue(notice.waitForExistence(timeout: 8))
        XCTAssertTrue(notice.label.contains("已导入：\(fullName)"), "Expected a new successful import")
        XCTAssertEqual(selection.value as? String, fullName)
        let preview = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "字体样张，\(fullName)：山间有风，书中有光。Aa 123"
        )).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertFalse(empty.exists)
        XCTAssertFalse(selectedOriginal.exists)
        let reset = app.buttons.matching(identifier: "epub.font.followOriginal").firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 5), "Missing Gemini follow-original button")
        XCTAssertTrue(reset.isEnabled, "Follow-original remained disabled after import")
        XCTAssertTrue(reset.isHittable, "Follow-original has no reachable hit point after import")
        reset.tap()
        XCTAssertTrue(selectedOriginal.waitForExistence(timeout: 5))
        XCTAssertEqual(selection.value as? String, "跟随原书")
        XCTAssertFalse(preview.exists)
        XCTAssertFalse(reset.exists)
        XCTAssertFalse(notice.exists)
        XCTAssertFalse(empty.exists, "Resetting the selection must not empty the font library")
    }

    // The two independent system pickers may restore different tabs/directories.
    // Navigate only Files locations; never open a file by position or enumerate its contents.
    @MainActor private func openLocalRoot(_ app: XCUIApplication) {
        let local = NSPredicate(format: "label IN %@", ["On My iPhone", "我的 iPhone"])
        let nav = app.navigationBars
        let localTitle = nav.staticTexts.matching(local).firstMatch
        let localBar = nav.matching(NSPredicate(format: "identifier IN %@", ["On My iPhone", "我的 iPhone"])).firstMatch
        let localLocation = app.descendants(matching: .any).matching(local).firstMatch
        let browse = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
        let back = nav.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "BackButton",
            ["Browse", "Locations", "Back", "浏览", "位置", "返回"])).firstMatch
        for _ in 0..<4 {
            if localBar.exists || localTitle.exists { return }
            if localLocation.exists && localLocation.isHittable { localLocation.tap() }
            else if back.exists && back.isHittable { back.tap() }
            else if browse.exists && browse.isHittable { browse.tap() }
            else { break }
        }
        XCTAssertTrue(localBar.exists || localTitle.waitForExistence(timeout: 3), "Expected the On My iPhone root")
    }

    @MainActor private func requireInteractive(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, file: file, line: line)
    }
}

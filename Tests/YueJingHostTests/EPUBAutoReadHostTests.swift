import Foundation
import ReaderDomain
import Testing
import UIKit
import WebKit
@testable import YueJing

@MainActor
@Suite(.serialized)
struct EPUBAutoReadHostTests {
    private final class MockSpeechAudio: ReaderSpeechAudio {
        var texts: [String] = []
        var begin: (@MainActor () -> Void)?
        var finish: (@MainActor (Bool) -> Void)?
        var immediateStart = true

        func speak(_ text: String, multiplier: Float, started: @escaping @MainActor () -> Void,
                   ended: @escaping @MainActor (Bool) -> Void) throws {
            texts.append(text)
            begin = started
            finish = ended
            if immediateStart { started() }
        }

        func silence() {
            begin = nil
            finish = nil
        }
    }

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
                        if mode == .paged {
                            try #require(firstStep == .waiting)
                            try await requireOneLanding(model, owner: owner)
                            #expect(abs(scroll.contentOffset.x - before.x - scroll.bounds.width) < 1)
                        } else {
                            try #require(firstStep == .advanced)
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
                        if mode == .paged {
                            #expect(abs(scroll.contentOffset.x + scroll.bounds.width - scroll.contentSize.width) < 1)
                        }
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
                let startX = scroll.contentOffset.x
                try #require(model.autoReadStep(from: owner, distance: 0) == .waiting)
                try await requireOneLanding(model, owner: owner)
                try #require(abs(scroll.contentOffset.x - startX - scroll.bounds.width) < 1)
                let landedX = scroll.contentOffset.x
                let session = AutoReadSession()
                session.start(mode: .paged) { model.autoReadStep(from: owner, distance: $0) }
                try #require(model.autoReadStep(from: owner, distance: 0) == .waiting)
                if !UIAccessibility.isReduceMotionEnabled {
                    try await until { scroll.contentOffset.x > landedX + 1 && scroll.contentOffset.x < landedX + scroll.bounds.width - 1 }
                } else {
                    #expect(abs(scroll.contentOffset.x - landedX - scroll.bounds.width) < 1)
                }
                let shield = EPUBAutoReadPauseSurface.Surface(frame: controller.view.bounds)
                shield.pause = {
                    session.stop()
                    controller.cancelAutoPage()
                }
                controller.view.addSubview(shield)
                #expect(controller.view.hitTest(edge, with: nil) === shield)
                shield.touchesBegan([], with: nil)
                let pausedOffset = scroll.contentOffset
                if !UIAccessibility.isReduceMotionEnabled {
                    #expect(pausedOffset.x > landedX && pausedOffset.x < landedX + scroll.bounds.width)
                }
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
        for mode in EPUBReadingMode.allCases {
            try await withBook { service, id in
                try await withReader(service, id, mode, .original) { model, controller in
                    let owner = try #require(model.autoReadOwner)
                    let old = try #require(model.presentationToken)
                    let path = try #require(model.spine.last)
                    let scroll = controller.webView.scrollView
                    if mode == .paged {
                        try #require(controller.beginAutoRead(for: old))
                        try #require(model.autoReadStep(from: owner, distance: 0) == .waiting)
                    }
                    model.navigateExplicitly(path: path, fragment: nil, target: nil)
                    #expect(model.autoReadStep(from: owner, distance: 4) == .stop)
                    try await until { model.ready && model.presentationToken?.path == path }
                    let offset = scroll.contentOffset
                    #expect(controller.autoReadStep(for: old, distance: 4) == .stop)
                    #expect(model.autoReadStep(from: owner, distance: 4) == .stop)
                    #expect(scroll.contentOffset == offset)
                    let current = try #require(model.autoReadOwner)
                    if mode == .paged {
                        try await until { controller.renderedChapterPaths.count == model.spine.count }
                        let token = try #require(model.presentationToken)
                        try #require(controller.beginAutoRead(for: token))
                        try #require(model.autoReadStep(from: current, distance: 0) == .waiting)
                    }
                    await model.suspend()
                    #expect(model.autoReadStep(from: current, distance: 4) == .stop)
                    if mode == .paged {
                        let sample = try #require(await controller.sampleVisibleNow())
                        let saved = try #require(model.currentPosition)
                        #expect(saved.path == sample.path && saved.node == sample.node && saved.utf16Offset == sample.utf16Offset)
                    }
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
    }

    @Test func epubSpeechCursorBoundsUTF16AndSkipsImageAndEmptyChapters() async throws {
        let long = String(repeating: "😀", count: 300)
        let package = EPUBPackage(sourceSHA256: "fixture", title: "", spine: ["a", "image", "blank", "b"],
            navigation: [], resources: [], textNodes: ["a": ["not spoken", "甲😀。 后句！"],
                "image": ["图片页"], "blank": ["空白页"], "b": [" \n", long]], coverPath: nil)
        let cursor = try EPUBSpeechCursor(package: package, path: "a", node: 1, rawOffset: 2)
        let first = try #require(try await cursor.next())
        #expect(first.text == "😀。" && first.position.node == 1 && first.position.utf16Offset == 1)
        let second = try #require(try await cursor.next())
        #expect(second.text == "后句！" && second.position.utf16Offset == 5)
        var joined = ""
        while let chunk = try await cursor.next() {
            try chunk.position.validate(in: package)
            #expect(chunk.position.path == "b" && chunk.position.node == 1)
            #expect(chunk.position.utf16Offset == joined.utf16.count && chunk.text.utf16.count <= 280)
            joined += chunk.text
        }
        #expect(joined == long)
        #expect(try await cursor.next() == nil)
    }

    @Test func epubSpeechContinuesWhileSuspendedAndRestoresLastSentenceAtEOF() async throws {
        try await withBook { service, id in
            try await withReader(service, id, .scroll, .reader) { model, controller in
                let middle = model.spine[1]
                model.navigateExplicitly(path: middle, fragment: "sec-mid", target: nil)
                try await until { model.presentationToken?.path == middle }
                let owner = try #require(model.presentationToken)
                let sample = try #require(await controller.sampleSpeechStart(for: owner))
                let package = try #require(model.reader?.publication.package)
                let oracle = try EPUBSpeechCursor(package: package, path: middle, node: sample.node, rawOffset: sample.utf16Offset)
                let expected = try #require(try await oracle.next())
                let source = try #require(model.speechSource { Issue.record("Locking must not revoke playback") })
                var last = try #require(try await source())
                #expect(last.text == expected.text)
                await model.suspend()
                let offset = controller.webView.scrollView.contentOffset
                let loads = controller.documentLoadCount
                while let chunk = try await source() { last = chunk }
                #expect(last.text == "EPUB_CH3_END 第三章末尾。")
                #expect(controller.documentLoadCount == loads && controller.webView.scrollView.contentOffset == offset)
                #expect(model.currentToken == owner)
                // The session's deferred location may arrive before the reader's resume handler.
                last.locate()
                #expect(model.currentPath == middle)
                await model.resume()
                try await until { model.presentationToken?.path == model.spine.last }
                let target = try #require(model.navigationRequest?.targetPosition)
                let nodes = try #require(try package.nodes(at: target.path))
                #expect(nodes[target.node] == last.text && target.utf16Offset == 0)
                #expect(await model.close())
            }
        }
    }

    @Test func epubSpeechRefusesCachedAnchorWhenViewportHasNoVisibleLocator() async throws {
        try await withBook { service, id in
            try await withReader(service, id, .scroll, .original) { model, controller in
                let token = try #require(model.presentationToken)
                _ = try #require(await controller.sampleVisibleNow())
                let source = try #require(model.speechSource { })
                _ = try await controller.evaluateLocatorJavaScriptForTesting("document.body.style.display = 'none'")
                #expect(await controller.sampleSpeechStart(for: token) == nil)
                await #expect(throws: EPUBError.invalidPosition) { _ = try await source() }
                _ = try await controller.evaluateLocatorJavaScriptForTesting("document.body.style.removeProperty('display')")
                #expect(await model.close())
            }
        }
    }

    @Test func epubSpeechRejectsLateSourceAndLocateAfterNavigationOrExit() async throws {
        try await withBook { service, id in
            try await withReader(service, id, .paged, .original) { model, _ in
                var stops = 0
                let old = try #require(model.speechSource { stops += 1 })
                let heard = try #require(try await old())
                let path = try #require(model.spine.last)
                model.navigateExplicitly(path: path, fragment: nil, target: nil)
                heard.locate()
                #expect(stops == 1)
                await #expect(throws: CancellationError.self) { _ = try await old() }
                try await until { model.presentationToken?.path == path }
                let live = try #require(model.speechSource { stops += 1 })
                let final = try #require(try await live())
                #expect(await model.close())
                final.locate()
                #expect(stops == 2 && model.navigationRequest == nil)
                await #expect(throws: CancellationError.self) { _ = try await live() }
            }
        }
    }

    @Test func epubSpeechFollowRevealsOnlyWhenOffscreenAndDetachesUntilReturn() async throws {
        for mode in EPUBReadingMode.allCases {
            try await withBook { service, id in
                let audio = MockSpeechAudio()
                audio.immediateStart = false
                let speech = ReaderSpeechSession(audio: audio, foreground: { true })
                try await withReader(service, id, mode, .reader, speech: speech) { model, controller in
                    controller.onToolsInteraction = { event in
                        if case .scrollingBegan = event { model.detachSpeechFollow() }
                    }
                    let scroll = controller.webView.scrollView
                    let initialToken = try await settlePresentation(model, controller, label: "\(mode.rawValue).initial")
                    let initial = scroll.contentOffset
                    let initialLoads = controller.documentLoadCount

                    let startSample = try #require(await controller.sampleSpeechStart(for: initialToken))
                    let package = try #require(model.reader?.publication.package)
                    let oracle = try EPUBSpeechCursor(
                        package: package,
                        path: startSample.path,
                        node: startSample.node,
                        rawOffset: startSample.utf16Offset
                    )
                    var expectedPassages: [EPUBSpeechCursor.Passage] = []
                    while let passage = try await oracle.next() {
                        if passage.text.rangeOfCharacter(from: .alphanumerics) != nil {
                            expectedPassages.append(passage)
                        }
                    }
                    try #require(expectedPassages.count >= 4)
                    try #require(
                        await controller.inspectSpeechPosition(expectedPassages[0].position, for: initialToken, stillCurrent: { true }) == .visible
                    )

                    // Identify the first physically offscreen anchor from real WebKit geometry on the initial screen.
                    var offscreenIndex: Int?
                    for index in 1..<expectedPassages.count {
                        let inspection = await controller.inspectSpeechPosition(
                            expectedPassages[index].position,
                            for: initialToken,
                            stillCurrent: { true }
                        )
                        if case .reveal = inspection {
                            offscreenIndex = index
                            break
                        }
                        try #require(inspection == .visible)
                    }
                    let revealIndex = try #require(offscreenIndex)
                    let revealPassage = expectedPassages[revealIndex]

                    model.startSpeech()
                    try await until("\(mode.rawValue).initialSpeechQueued") {
                        model.speech.isActive && audio.texts.count == 1 && audio.begin != nil && audio.finish != nil
                    }
                    #expect(audio.texts.first == expectedPassages[0].text)
                    // Prefetching before didStart must not move the viewport.
                    await Task.yield()
                    _ = try await settlePresentation(model, controller, label: "\(mode.rawValue).prefetchSettled")
                    await Task.yield()
                    #expect(scroll.contentOffset == initial && controller.documentLoadCount == initialLoads)

                    // Visible initial sentence must not scroll or turn the page on didStart.
                    let beginFirst = try #require(audio.begin)
                    audio.begin = nil
                    beginFirst()
                    await Task.yield()
                    let afterFirstToken = try await settlePresentation(model, controller, label: "\(mode.rawValue).initialStartSettled")
                    await Task.yield()
                    #expect(await controller.inspectSpeechPosition(expectedPassages[0].position, for: afterFirstToken, stillCurrent: { true }) == .visible)
                    #expect(scroll.contentOffset == initial && controller.documentLoadCount == initialLoads)
                    #expect(model.speech.isFollowing && !model.autoRead.isRunning)

                    // Advance through all remaining observed-visible passages on the initial screen without moving.
                    for index in 1..<revealIndex {
                        let count = audio.texts.count
                        let finishCurrent = try #require(audio.finish)
                        audio.finish = nil
                        finishCurrent(true)
                        try await until("\(mode.rawValue).visiblePassageQueued.\(index)") {
                            audio.texts.count > count && audio.begin != nil && audio.finish != nil
                        }
                        #expect(audio.texts.last == expectedPassages[index].text)
                        let beginVisible = try #require(audio.begin)
                        audio.begin = nil
                        beginVisible()
                        #expect(scroll.contentOffset == initial)
                    }
                    await Task.yield()
                    _ = try await settlePresentation(model, controller, label: "\(mode.rawValue).lastVisibleSettled")
                    await Task.yield()
                    #expect(scroll.contentOffset == initial && controller.documentLoadCount == initialLoads)

                    // Queueing the first offscreen sentence before didStart must still not move the viewport.
                    let countBeforeOffscreen = audio.texts.count
                    let finishLastVisible = try #require(audio.finish)
                    audio.finish = nil
                    finishLastVisible(true)
                    try await until("\(mode.rawValue).offscreenPassageQueued") {
                        audio.texts.count > countBeforeOffscreen && audio.begin != nil && audio.finish != nil
                    }
                    #expect(audio.texts.last == revealPassage.text)
                    await Task.yield()
                    _ = try await settlePresentation(model, controller, label: "\(mode.rawValue).offscreenPrefetchSettled")
                    await Task.yield()
                    #expect(scroll.contentOffset == initial && controller.documentLoadCount == initialLoads)

                    // Audible start of the offscreen sentence must reveal it so that exact anchor is now visible.
                    let beginOffscreen = try #require(audio.begin)
                    audio.begin = nil
                    beginOffscreen()
                    try await until("\(mode.rawValue).offscreenRevealMoved") {
                        scroll.contentOffset != initial &&
                        model.presentationToken != nil &&
                        !model.promotingVisibleChapter
                    }
                    let revealedToken = try await settlePresentation(model, controller, label: "\(mode.rawValue).revealedPresentation")
                    let revealed = scroll.contentOffset
                    #expect(await controller.inspectSpeechPosition(revealPassage.position, for: revealedToken, stillCurrent: { true }) == .visible)
                    #expect(controller.documentLoadCount == initialLoads)
                    #expect(model.speech.isActive && model.speech.isFollowing)

                    // Next sentence verified visible on the newly revealed screen stays stationary.
                    let nextAfterRevealIndex = revealIndex + 1
                    try #require(nextAfterRevealIndex < expectedPassages.count)
                    let nextAfterReveal = expectedPassages[nextAfterRevealIndex]
                    try #require(
                        await controller.inspectSpeechPosition(nextAfterReveal.position, for: revealedToken, stillCurrent: { true }) == .visible
                    )
                    let countAfterReveal = audio.texts.count
                    let finishRevealed = try #require(audio.finish)
                    audio.finish = nil
                    finishRevealed(true)
                    try await until("\(mode.rawValue).nextVisibleAfterRevealQueued") {
                        audio.texts.count > countAfterReveal && audio.begin != nil && audio.finish != nil
                    }
                    #expect(audio.texts.last == nextAfterReveal.text)
                    let beginAfterReveal = try #require(audio.begin)
                    audio.begin = nil
                    beginAfterReveal()
                    await Task.yield()
                    let postVisibleToken = try await settlePresentation(model, controller, label: "\(mode.rawValue).nextVisibleAfterRevealSettled")
                    await Task.yield()
                    #expect(await controller.inspectSpeechPosition(nextAfterReveal.position, for: postVisibleToken, stillCurrent: { true }) == .visible)
                    #expect(scroll.contentOffset == revealed)
                    #expect(model.speech.isActive && model.speech.isFollowing)

                    // Manual page turn detaches follow while keeping speech active.
                    try #require(controller.turnPage(.next, animated: false))
                    #expect(model.speech.isActive && !model.speech.isFollowing)
                    var manualToken = try await settlePresentation(model, controller, label: "\(mode.rawValue).manualTurnSettled")
                    var manual = scroll.contentOffset
                    try #require(manual != revealed)

                    let detachedIndex = nextAfterRevealIndex + 1
                    try #require(detachedIndex < expectedPassages.count)
                    let detachedPassage = expectedPassages[detachedIndex]
                    let countWhileDetached = audio.texts.count
                    let finishBeforeDetached = try #require(audio.finish)
                    audio.finish = nil
                    finishBeforeDetached(true)
                    try await until("\(mode.rawValue).detachedPassageQueued") {
                        audio.texts.count > countWhileDetached && audio.begin != nil && audio.finish != nil
                    }
                    #expect(audio.texts.last == detachedPassage.text)
                    let beginDetached = try #require(audio.begin)
                    audio.begin = nil
                    beginDetached()
                    await Task.yield()
                    manualToken = try await settlePresentation(model, controller, label: "\(mode.rawValue).detachedPassageSettled")
                    await Task.yield()
                    #expect(scroll.contentOffset == manual)
                    #expect(model.speech.isActive && !model.speech.isFollowing)

                    // Ensure the detached audible anchor is physically outside the viewport before explicit return.
                    var beforeReturn = await controller.inspectSpeechPosition(
                        detachedPassage.position,
                        for: manualToken,
                        stillCurrent: { true }
                    )
                    for _ in 0..<2 where beforeReturn == .visible {
                        if !controller.turnPage(.next, animated: false) {
                            try #require(controller.turnPage(.previous, animated: false))
                        }
                        manualToken = try await settlePresentation(model, controller, label: "\(mode.rawValue).manualBrowseAwaySettled")
                        manual = scroll.contentOffset
                        beforeReturn = await controller.inspectSpeechPosition(
                            detachedPassage.position,
                            for: manualToken,
                            stillCurrent: { true }
                        )
                    }
                    let offscreenBeforeReturn: Bool
                    if case .reveal = beforeReturn { offscreenBeforeReturn = true } else { offscreenBeforeReturn = false }
                    try #require(
                        offscreenBeforeReturn,
                        "Expected detached audible anchor offscreen before returnToSpeech in \(mode.rawValue), got \(beforeReturn)"
                    )
                    #expect(model.speech.isActive && !model.speech.isFollowing)

                    // Explicit return reattaches and physically reveals the latest started sentence.
                    model.speech.returnToSpeech()
                    #expect(model.speech.isFollowing)
                    try await until("\(mode.rawValue).returnToSpeechMoved") {
                        scroll.contentOffset != manual &&
                        model.presentationToken != nil &&
                        !model.promotingVisibleChapter
                    }
                    let returnedToken = try await settlePresentation(model, controller, label: "\(mode.rawValue).returnToSpeechSettled")
                    let returnedOffset = scroll.contentOffset
                    #expect(await controller.inspectSpeechPosition(detachedPassage.position, for: returnedToken, stillCurrent: { true }) == .visible)
                    #expect(controller.documentLoadCount == initialLoads)
                    #expect(model.speech.isActive && model.speech.isFollowing)

                    // Stale callbacks after stop must not restart playback or move the viewport.
                    let staleFinish = audio.finish
                    model.speech.stop(restorePosition: false)
                    #expect(!model.speech.isActive)
                    beginDetached()
                    staleFinish?(true)
                    await Task.yield()
                    _ = try await settlePresentation(model, controller, label: "\(mode.rawValue).postStopStaleSettled")
                    await Task.yield()
                    #expect(!model.speech.isActive)
                    #expect(scroll.contentOffset == returnedOffset)
                    #expect(await model.close())
                }
            }
        }
    }

    @Test func epubSpeechFollowSkipsLockedWebKitAndRestoresOnceAfterReady() async throws {
        try await withBook { service, id in
            var foreground = true
            let audio = MockSpeechAudio()
            let speech = ReaderSpeechSession(audio: audio, foreground: { foreground })
            try await withReader(service, id, .scroll, .reader, speech: speech) { model, controller in
                let scroll = controller.webView.scrollView
                let startToken = try #require(model.presentationToken)
                let startSample = try #require(await controller.sampleSpeechStart(for: startToken))
                let package = try #require(model.reader?.publication.package)
                let oracle = try EPUBSpeechCursor(
                    package: package,
                    path: startSample.path,
                    node: startSample.node,
                    rawOffset: startSample.utf16Offset
                )
                var expectedPassages: [EPUBSpeechCursor.Passage] = []
                while let passage = try await oracle.next() {
                    if passage.text.rangeOfCharacter(from: .alphanumerics) != nil {
                        expectedPassages.append(passage)
                    }
                }
                let ch2TargetIndex = try #require(expectedPassages.firstIndex { $0.text.contains("EPUB_A_C2_P1") })
                let ch2Target = expectedPassages[ch2TargetIndex]
                let ch2Nodes = try #require(try package.nodes(at: model.spine[1]))
                #expect(ch2Target.position.path == model.spine[1] && ch2Nodes[ch2Target.position.node] == ch2Target.text && ch2Target.position.utf16Offset == 0)
                let ch3TargetIndex = try #require(expectedPassages.firstIndex { $0.text.contains("EPUB_A_C3_P1") })
                let ch3Target = expectedPassages[ch3TargetIndex]
                let ch3Nodes = try #require(try package.nodes(at: model.spine[2]))
                #expect(ch3Target.position.path == model.spine[2] && ch3Nodes[ch3Target.position.node] == ch3Target.text && ch3Target.position.utf16Offset == 0)

                model.startSpeech()
                try await until { model.speech.isActive && audio.texts.count == 1 && audio.finish != nil }
                #expect(audio.texts.first == expectedPassages.first?.text)

                foreground = false
                await model.suspend()
                let lockedOffset = scroll.contentOffset
                let lockedLoads = controller.documentLoadCount

                // Advance across chapter 1 into chapter 2 while locked; WebKit must not move.
                for _ in 0..<expectedPassages.count {
                    if audio.texts.last?.contains("EPUB_A_C2_P1") == true { break }
                    let count = audio.texts.count
                    try #require(audio.finish != nil)
                    audio.finish?(true)
                    if audio.texts.count == count && model.speech.isActive { await Task.yield() }
                    try await until { audio.texts.count > count || !model.speech.isActive }
                    if !model.speech.isActive { break }
                }
                try #require(audio.texts.last?.contains("EPUB_A_C2_P1") == true)
                #expect(audio.texts.last == ch2Target.text && audio.texts.count == ch2TargetIndex + 1)
                #expect(model.speech.isActive && model.speech.isFollowing)
                #expect(scroll.contentOffset == lockedOffset && controller.documentLoadCount == lockedLoads)

                // Unlock restores once after readiness and preserves audio ownership across the chapter jump.
                foreground = true
                await model.resume()
                try await until {
                    model.presentationToken?.path == model.spine[1] &&
                    !model.promotingVisibleChapter &&
                    scroll.contentOffset.y > lockedOffset.y + 100
                }
                let resumedToken = try #require(model.presentationToken)
                let caughtUpOffset = scroll.contentOffset
                #expect(await controller.inspectSpeechPosition(ch2Target.position, for: resumedToken, stillCurrent: { true }) == .visible)
                try await Task.sleep(for: .milliseconds(80))
                #expect(scroll.contentOffset == caughtUpOffset)
                #expect(model.speech.isActive && model.speech.isFollowing)
                #expect(controller.documentLoadCount == lockedLoads)

                // Detached playback stays detached across lock/unlock and never yanks to chapter 3.
                model.detachSpeechFollow()
                #expect(!model.speech.isFollowing && model.speech.isActive)
                foreground = false
                await model.suspend()
                let detachedOffset = scroll.contentOffset
                let detachedLoads = controller.documentLoadCount
                for _ in 0..<expectedPassages.count {
                    if audio.texts.last?.contains("EPUB_A_C3_P1") == true { break }
                    let count = audio.texts.count
                    try #require(audio.finish != nil)
                    audio.finish?(true)
                    if audio.texts.count == count && model.speech.isActive { await Task.yield() }
                    try await until { audio.texts.count > count || !model.speech.isActive }
                    if !model.speech.isActive { break }
                }
                try #require(audio.texts.last?.contains("EPUB_A_C3_P1") == true)
                #expect(audio.texts.last == ch3Target.text && audio.texts.count == ch3TargetIndex + 1)
                #expect(scroll.contentOffset == detachedOffset && controller.documentLoadCount == detachedLoads)
                foreground = true
                await model.resume()
                try await until { model.presentationToken != nil && !model.promotingVisibleChapter }
                try await Task.sleep(for: .milliseconds(80))
                #expect(!model.speech.isFollowing && model.speech.isActive)
                #expect(model.presentationToken?.path == model.spine[1])

                model.speech.stop(restorePosition: false)
                #expect(await model.close())
            }
        }
    }

    /// Poll the same action as the clock. No synthetic delegate callback or assumed animation duration.
    private func requireOneLanding(_ model: EPUBReaderViewModel, owner: EPUBNavigationToken) async throws {
        var result = model.autoReadStep(from: owner, distance: 0)
        try #require(result == .waiting) // No second command on the same run-loop turn.
        try await until {
            if result == .waiting { result = model.autoReadStep(from: owner, distance: 0) }
            return result != .waiting
        }
        try #require(result == .advanced)
    }

    private func settlePresentation(
        _ model: EPUBReaderViewModel,
        _ controller: EPUBWebViewController,
        label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> EPUBNavigationToken {
        var settled: EPUBNavigationToken?
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if let token = model.presentationToken, !model.promotingVisibleChapter,
               await controller.sampleVisibleNow() != nil,
               model.presentationToken == token, !model.promotingVisibleChapter {
                settled = token
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(
            settled,
            "Timed out settling presentation for \(label)",
            sourceLocation: sourceLocation
        )
    }

    private func until(
        _ label: String = "condition",
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "Timed out waiting for \(label)", sourceLocation: sourceLocation)
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
                            speech: ReaderSpeechSession? = nil,
                            sourceLocation: SourceLocation = #_sourceLocation,
                            _ body: @MainActor (EPUBReaderViewModel, EPUBWebViewController) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first, sourceLocation: sourceLocation)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
        let model = EPUBReaderViewModel(bookID: id, service: service, readingMode: mode, layoutMode: layout, speech: speech)
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
        try await until("withReader.ready", sourceLocation: sourceLocation) {
            model.presentationToken != nil && controller.renderedChapterPaths.count == model.spine.count
        }
        try await body(model, controller)
    }
}

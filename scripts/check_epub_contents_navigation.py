"""Offline source contracts only: no Swift compilation, UIKit execution or UI proof."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = 'cb749e62b4b468d7077cceaaba7bcd626294a269'
VIEW = 'App/EPUB/EPUBContentsView.swift'
TEST = 'Tests/YueJingHostTests/EPUBContentsNavigationTests.swift'
SCRIPT = 'scripts/check_epub_contents_navigation.py'
SCREEN = 'App/EPUB/EPUBReaderScreen.swift'
UI_TEST = 'Tests/YueJingEPUBUITests/EPUBFlowUITests.swift'
REGRESSION_BASE = 'fc9ab9f93f17329093eaa7586988dfe9d92f1a51'
checks = []


def require(ok, message):
    if not ok:
        raise AssertionError(message)
    checks.append(message)


def method(source, signature):
    return source.split(signature, 1)[1].split('\n    }', 1)[0]


view = (ROOT / VIEW).read_text(encoding='utf-8')
tests = (ROOT / TEST).read_text(encoding='utf-8')
screen = (ROOT / SCREEN).read_text(encoding='utf-8')
ui_tests = (ROOT / UI_TEST).read_text(encoding='utf-8')
before = subprocess.check_output(['git', 'show', BASE + ':' + VIEW], cwd=ROOT).decode('utf-8')
require(method(view, '    static func currentIndex(') == method(before, '    static func currentIndex('),
        'existing path+fragment priority and first-path fallback unchanged')
require('return items.indices.filter' in view and 'String(index + 1) == term' in view and
        'title.localizedStandardContains(term)' in view and '.whitespacesAndNewlines' in view,
        'filter uses title or original one-based ordinal, with trimmed query')
require('ForEach(visibleIndices, id: \\.self)' in view and '.id(index)' in view and
        'ordinal: index + 1' in view and 'totalCount: items.count' in view,
        'List identity and displayed ordinals remain original indices')
require('let item = items[index]' in view and view.count('selected(item)') == 1,
        'selection forwards the original item only from its row button')
require('ScrollViewReader { proxy in' in view and view.count('proxy.scrollTo(target, anchor: .center)') == 2,
        'only directory proxy receives initial scroll and bounded mount correction')
require('geometry.size.width > 0 && geometry.size.height > 0' in view and
        '.task(id: revealKey)' in view and 'guard active, laidOut, owner != nil' in view,
        'initial scroll waits for nonzero List layout and task ownership')
require('.task(id: reveal.initialIssued ? revealKey : nil)' in view and
        'let target = reveal.mountedTarget(index)' in view and 'await Task.yield()' in view,
        'second scroll is tied to lazy target mounting, not a timed retry')
require('guard requestID != nil, !initialIssued, let targetIndex' in view and
        'guard requestID != nil, initialIssued, targetIndex == index' in view and
        'cancel()\n        return index' in view,
        'reveal policy admits one initial scroll and one target correction, then consumes ownership')
require(view.count('reveal.requestID == owner') == 2 and view.count('!Task.isCancelled, active') == 3,
        'scroll and accessibility tasks recheck cancellation and activity after yielding')
require('guard presented else { return .notPresented }' in view and
        'guard sceneActive else { return .sceneInactive }' in view and
        'guard ownerActive && liveOwnerActive else { return .ownerInactive }' in view and
        'sceneActive: scenePhase == .active' in view and 'liveOwnerActive: isActive()' in view and
        '.onChange(of: active)' in view and 'else { reveal.cancel(); searchFocused = false }' in view and
        '.onDisappear {' in view and 'presented = false' in method(view, '    private func dismiss()'),
        'inactive, disappearance and explicit close invalidate pending work; all original authority gates retained')
require('DragGesture().onChanged { _ in reveal.cancel() }' in view and
        'query = $0\n                        reveal.cancel()' in view and
        '.onChange(of: currentPath)' not in view and '.onChange(of: currentFragment)' not in view,
        'manual browsing/filtering cancels reveal; current-position updates do not steal scroll')
require('guard active, initializedSessionID != sessionID' in view and
        'query = ""\n        reveal.request(currentIndex)' in method(view, '    private func initializeSession(') and
        'searchFocused = false\n                reveal.request(currentIndex)' in view and
        '.accessibilityIdentifier("epub.directory.clear")' in view,
        'first authorized appearance of each session clears stale filters; explicit current action requests a fresh reveal')
require('暂无目录。' in view and '没有匹配的章节' in view and '未找到当前章节' in view and
        '.disabled(currentIndex == nil)' in view, 'empty, unmatched and missing-current states are explicit')
require(all(token not in view for token in ('Task.sleep', 'while ', 'DispatchQueue', 'Timer.',
        'WKWebView', 'savePosition', 'beginNavigation', '@Observable', 'scrollPosition(', 'ContentUnavailableView')),
        'no sleep/retry loop, reader-position writes, WebKit access or selected newer APIs introduced')
expected_tests = (
    'largeDirectoryResolvesFirstMiddleAndLast',
    'samePathPrefersFragmentThenFallsBackToFirstPath',
    'filteringKeepsOriginalIndicesOrdinalsAndItems',
    'emptyAndUnmatchedDirectoriesHaveNoInventedTarget',
    'lazyMountCorrectionIsBoundedAndOnlyForTheTarget',
    'cancellationAndNewRequestsInvalidateLateWork',
    'directoryAccessRequiresEveryLiveAndRenderedPermission',
    'directoryReopenAndForegroundNeverRestoreOldSessionAuthority',
    'chapterLoadingKeepsHiddenToolsAndDefersOnlyChapterFeedback',
)
require(tests.count('@Test func ') == len(expected_tests) and
        all('@Test func ' + name + '(' in tests for name in expected_tests),
        'nine native pure-logic regression declarations present (not executed)')
require('0..<10_000' in tests and '[0, 5_000, 9_999]' in tests and
        'matches == [1, 3]' in tests and 'items[1].id == items[3].id' in tests,
        'native declarations include large first/middle/last and duplicate-href filtered identity cases')

# These checks extend, rather than replace, the original reveal/filter/safety contracts.
require('sessionID: session.id' in screen and '.id(session.id)' in screen and
        'ownerActive: panelActive(.directory, session.id)' in screen and
        'isActive: { panelActive(.directory, session.id) }' in screen and
        'let ownerActive: Bool' in view,
        'sheet has explicit owner dependency and independent session identity plus live callback authority')
require('set: {\n                        guard active else { return }\n                        query = $0' in view and
        'Button {\n                        guard active else { return }\n                        query = ""' in view and
        'guard active else { return }\n                query = ""' in view and
        'guard active else { return }\n                                reveal.cancel()\n                                selected(item)' in view,
        'query writes, clear, locate and selection all recheck actual authority at execution')
require('epub.directory.availability' in view and 'epub.directory.recover' in view and
        'state=\\(access.rawValue);presented=\\(presented);scene=\\(scenePhase == .active);owner=\\(ownerActive);live=\\(isActive())' in view,
        'recoverable unavailable state exposes only fixed state codes and permission booleans')
recovery = method(view, '    private var availabilityStatus:')
require('close()' in recovery and all(token not in recovery for token in (
        'query =', 'selected(', 'presented =', 'forceCompact', 'resume()', 'print(', 'Logger',
        '\\(query)', '\\(sessionID)', '\\(currentPath)', '\\(items)')),
        'recovery only requests guarded dismissal; it cannot grant permission or emit private data')
old_screen = subprocess.check_output(['git', 'show', REGRESSION_BASE + ':' + SCREEN], cwd=ROOT).decode('utf-8')
for signature in ('    private func panelActive(', '    private func closePanel(',
                  '    private func selectNavigationItem(', '    private func exitReader('):
    require(method(screen, signature) == method(old_screen, signature),
            'parent safety contract unchanged: ' + signature.strip())
require('UIApplication.willResignActiveNotification' in screen and 'mutateTools { $0.suspend() }' in screen and
        'UIApplication.didBecomeActiveNotification' in screen and 'mutateTools { $0.resume() }' in screen,
        'foreground/background revocation remains in place')
require('initialOpening || phase != .quiet' in screen and
        'static func restoresTools(initialOpening: Bool) -> Bool { initialOpening }' in screen and
        'EPUBReaderLoadingPresentation.showsFeedback(' in screen and
        'if loading, EPUBReaderLoadingPresentation.restoresTools(' in screen and
        screen.count('initialOpening: model.openingPerformanceSummary == nil') == 2,
        'chapter quiet feedback and loading-triggered compact tools are suppressed without changing first opening')
require('let started = model.loadingFeedbackStart ?? ContinuousClock.now' in screen and
        'EPUBOpeningFeedback.compactDelay' in screen and 'EPUBOpeningFeedback.detailedDelay' in screen and
        'Button("返回书架，停止切换") { exitReader() }' in screen and
        '.disabled(!tools.canInteract)' in screen and
        '.accessibilityElement(children: model.openingPerformanceSummary == nil ? .combine : .contain)' in screen,
        'existing feedback delays unchanged; delayed chapter feedback keeps a gated accessible cancel action')
for path, source in ((TEST, tests), (UI_TEST, ui_tests)):
    old = subprocess.check_output(['git', 'show', REGRESSION_BASE + ':' + path], cwd=ROOT).decode('utf-8')
    lines = iter(source.splitlines())
    require(all(any(line == candidate for candidate in lines) for line in old.splitlines()),
            'all original test lines retained in order: ' + path)
require('search.typeText(query)' in ui_tests and 'app.buttons["epub.directory.clear"].tap()' in ui_tests and
        'locate.tap()' in ui_tests and '(search.value as? String) == query' in ui_tests and
        'current.isHittable && (current.value as? String) == "当前章节"' in ui_tests and
        '!app.keyboards.firstMatch.exists' in ui_tests,
        'UI regression performs actual input, clear and locate and checks their effects, not just existence')
require('testEPUBDirectoryControlsRecoverAfterCancelReopenAndForeground' in ui_tests and
        'for _ in 0..<2' in ui_tests and 'XCUIDevice.shared.press(.home)' in ui_tests and
        'app.activate()' in ui_tests and '!app.textFields["epub.directory.search"].exists' in ui_tests and
        'app.buttons["reader.chapter.2"].tap()' in ui_tests and
        'XCTAssertFalse(app.buttons["reader.exit"].isHittable)' in ui_tests,
        'UI regression covers cancel/reopen, foreground revocation/recovery and actual destination after selection')
print(json.dumps(dict(
    passed=True, source_contracts=len(checks), checks=checks,
    native_tests_declared=len(expected_tests), native_executed=0, swift_compiled=False,
    ui_tests_declared=ui_tests.count('@MainActor func test'), ui_executed=0,
    lazy_list_rendering_verified=False, device_verified=False,
    sha256={name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in (VIEW, SCREEN, TEST, UI_TEST, SCRIPT)},
), ensure_ascii=False, indent=2))

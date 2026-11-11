"""Offline source contracts only; does not execute Swift, UIKit or WKWebView."""
from pathlib import Path
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = 'd5fde953ca544deaecace0434a45b014ebd630b0'
checks = []

def read(name):
    return (ROOT / name).read_text(encoding='utf-8')

def require(ok, message):
    if not ok:
        raise AssertionError(message)
    checks.append(message)

def before(name):
    return subprocess.check_output(['git', 'show', BASE + ':' + name], cwd=ROOT).decode('utf-8')

probe = read('App/EPUB/EPUBOpeningPresentation.swift')
model = read('App/EPUB/EPUBReaderViewModel.swift')
screen = read('App/EPUB/EPUBReaderScreen.swift')
route = read('App/Library/BookReadingRouteOwner.swift')
host = read('Tests/YueJingHostTests/EPUBReaderHostTests.swift')
ui = read('Tests/YueJingEPUBUITests/EPUBFlowUITests.swift')

require('static let compactDelay = Duration.milliseconds(280)' in probe and
        'static let detailedDelay = Duration.seconds(1)' in probe, 'bounded feedback thresholds declared')
require('elapsedSeconds >= 1' in probe and 'elapsedSeconds >= 0.280' in probe,
        'feedback policy exposes exact threshold boundaries for native tests')
require('guard interruption == nil, token == readyToken' in probe and 'frameAt == nil' in probe,
        'display observation rejects interruptions, stale tokens and duplicates')
require('now >= readyAt' in probe and 'end >= start' in probe and 'return "未取得"' in probe,
        'invalid/missing clock endpoints are not fabricated zero timings')
require('不是像素首绘/屏幕扫描完成证明' in probe and '不等于设备文件缓存冷态' in probe,
        'measurement and process-cold limitations explicit')
require('window != nil' in probe and 'UIApplication.shared.applicationState == .active' in probe and
        'guard frames >= 2' in probe, 'frame probe needs mounted active presentation and two frame opportunities')
require('displayLink?.invalidate()' in probe and 'dismantleUIView' in probe and
        'if window == nil { stop(); frames = 0 }' in probe, 'frame probe detached/dismantled cleanup exists')
require('link.add(to: .main, forMode: .common)' in probe,
        'probe remains observation-only in common run-loop modes')
require('makeValidatedPosition' not in probe and 'markReady' not in probe and 'load(URLRequest' not in probe,
        'presentation helper grants no reading/session/navigation authority')
require('ReaderTheme(rawValue:' in probe and '?? .paper' in probe and
        'dev.yuejing.epub.presentation-theme.v1' in probe, 'theme hint has validated enum and separate display-only key')

require(route.index('let intent = ContinuousClock.now') < route.index('let model = EPUBReaderViewModel'),
        'click timestamp precedes renderer lookup/model creation')
require(route.index('presentation = BookReadingRoute(epub:') < route.index('model.startOpeningFromRoute()'),
        'early load belongs to published route')
require('guard presentation == nil else { return }' in route and 'private static var epubOpenSerial = 0' in route,
        'single route admission and process-only ordinal retained')
old_route = before('App/Library/BookReadingRouteOwner.swift')
require(route.split('case .txt:', 1)[1].split('case .epub:', 1)[0] ==
        old_route.split('case .txt:', 1)[1].split('case .epub:', 1)[0], 'TXT route branch byte-identical')
require('guard reader == nil, openTask == nil, !closing, !suspended else { return }' in model,
        'early and view load entry retain single-open guard')
require('Task { @MainActor [weak self] in await self?.load() }' in model,
        'early opening uses same guarded load path')
require('ready && !loading && !closing && !suspended && !exitSaveFailed ? currentToken : nil' in model and
        'guard presentationToken == token, openingObservation.observedFrame(token)' in model,
        'presentation callback rechecks current route/session readiness')
require(model.index('let marked = try await activeReader.markReady(expectedToken)') <
        model.index('self.openingObservation.becameReady(expectedToken)'),
        'opening ready observation follows domain authority confirmation')
require('openingObservation.interrupt(.retry)' in model and 'openingObservation.interrupt(.background)' in model,
        'retry/background samples excluded without altering recovery operations')
require('preferences = opened.preferences.validated\n            EPUBPresentationThemeHint.remember(preferences.theme)' in model,
        'authoritative loaded preferences replace appearance hint')

require('if model.openingPerformanceSummary == nil && (!model.ready || model.loading)' in screen,
        'opaque cover restricted to initial opening, not later typography/chapter changes')
require('Color(uiColor: model.preferences.theme.background)' in screen and '.transition(.identity)' in screen,
        'cover uses reading background with no timed reveal gate')
require('.allowsHitTesting(model.ready && !model.loading' in screen and
        '.accessibilityHidden(!model.ready || model.loading' in screen,
        'unconfirmed reader is inaccessible to touch and accessibility')
require('.task(id: model.loading)' in screen and screen.count('guard !Task.isCancelled, model.loading else { return }') == 2,
        'feedback escalation cancels on readiness/disappearance and does not run navigation')
require('started.advanced(by: EPUBOpeningFeedback.compactDelay)' in screen and
        'started.advanced(by: EPUBOpeningFeedback.detailedDelay)' in screen,
        'feedback sleeps use the declared absolute deadlines, not added minimum loading duration')
loading_block = screen.split('if model.loading && tools.exitRequest == nil && tools.valid {', 1)[1].split(
    'if !model.loading && !model.ready', 1)[0]
require('RoundedRectangle' not in loading_block and '正在打开' in loading_block and
        'loadingFeedback == .detailed' in loading_block, 'short loading card removed; honest feedback and long-wait explanation retained')
require('Button("重试打开")' in screen and 'openingSummary: model.diagnosticOpeningSummary' in screen,
        'failure recovery and expanded diagnostics remain reachable')
require('takeSnapshot' not in probe + screen and 'Task.sleep' not in route,
        'no stale screenshot preview or artificial route delay')

old_host = before('Tests/YueJingHostTests/EPUBReaderHostTests.swift')
prefix, suffix = old_host.split('struct EPUBReaderHostTests {\n', 1)
require(host.startswith(prefix + 'struct EPUBReaderHostTests {\n') and host.endswith(suffix),
        'all existing Host test bodies/helpers preserved byte-for-byte')
for name in ('epubOpeningObservationRejectsStaleFramesAndLabelsColdAdmission',
             'epubOpeningRouteStartsOnceAndObservesMountedPresentation'):
    require(host.count('@Test func ' + name + '(') == 1, 'new native regression declared: ' + name)
added_ui = '            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "epub.opening.feedback").firstMatch.exists)\n'
require(ui.count(added_ui) == 2 and ui.replace(added_ui, '') == before('Tests/YueJingEPUBUITests/EPUBFlowUITests.swift'),
        'UI only adds post-ready feedback assertions, all prior actions/waits/assertions unchanged')
require(read('App/EPUB/EPUBWebView.swift') == before('App/EPUB/EPUBWebView.swift') and
        read('App/EPUB/EPUBLocationScript.swift') == before('App/EPUB/EPUBLocationScript.swift'),
        'native navigation/locator JS unchanged; historical layout evidence not rerun')
require(read('App/EPUB/EPUBWarmRendererCache.swift') == before('App/EPUB/EPUBWarmRendererCache.swift'),
        'renderer cache budget/background policy unchanged')
require('guard !openingAttempted else { return }' in model and model.count('openingAttempted = false') == 3,
        'initial attempt is one-shot; only explicit retry and resume reset admission')
require('guard frameAt == nil else { return } // Later reading activity' in probe,
        'completed opening observations survive later background/retry events')
require('failed.openingAttemptCount == 1 && failed.message == originalError && !failed.loading' in host and
        'failed.openingAttemptCount == 2' in host and 'Let the route task, not this test, start first.' in host,
        'native tests cover early success, early failure, no implicit retry and explicit retry')
require('observation.summary == completedSummary && observation.interruption == nil' in host,
        'native regression retains completed observation after later lifecycle events')
print(json.dumps(dict(passed=True,source_contracts=len(checks),checks=checks,native_executed=0,
                     swift_compiled=False,visual_rendering_verified=False,ipa_built=False),ensure_ascii=False,indent=2))

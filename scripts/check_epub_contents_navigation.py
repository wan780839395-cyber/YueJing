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
checks = []


def require(ok, message):
    if not ok:
        raise AssertionError(message)
    checks.append(message)


def method(source, signature):
    return source.split(signature, 1)[1].split('\n    }', 1)[0]


view = (ROOT / VIEW).read_text(encoding='utf-8')
tests = (ROOT / TEST).read_text(encoding='utf-8')
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
require('presented && scenePhase == .active && isActive()' in view and
        '.onChange(of: active) { if !$0 { reveal.cancel(); searchFocused = false } }' in view and
        '.onDisappear {' in view and 'presented = false' in method(view, '    private func dismiss()'),
        'inactive, disappearance and explicit close invalidate pending work')
require('DragGesture().onChanged { _ in reveal.cancel() }' in view and
        'set: { query = $0; reveal.cancel() }' in view and
        '.onChange(of: currentPath)' not in view and '.onChange(of: currentFragment)' not in view,
        'manual browsing/filtering cancels reveal; current-position updates do not steal scroll')
require('query = ""\n            reveal.request(scenePhase == .active && isActive() ? selectedIndex : nil)' in view and
        'searchFocused = false\n                reveal.request(currentIndex)' in view and
        '.accessibilityIdentifier("epub.directory.clear")' in view,
        'opening clears stale filters; explicit current action clears query and requests a fresh reveal')
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
)
require(tests.count('@Test func ') == len(expected_tests) and
        all('@Test func ' + name + '(' in tests for name in expected_tests),
        'six native pure-logic regression declarations present (not executed)')
require('0..<10_000' in tests and '[0, 5_000, 9_999]' in tests and
        'matches == [1, 3]' in tests and 'items[1].id == items[3].id' in tests,
        'native declarations include large first/middle/last and duplicate-href filtered identity cases')
print(json.dumps(dict(
    passed=True, source_contracts=len(checks), checks=checks,
    native_tests_declared=len(expected_tests), native_executed=0, swift_compiled=False,
    lazy_list_rendering_verified=False, device_verified=False,
    sha256={name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in (VIEW, TEST, SCRIPT)},
), ensure_ascii=False, indent=2))

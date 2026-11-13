"""This batch's source wiring checks, NOT Swift/UIKit/WKWebView execution."""
from pathlib import Path
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = 'e98fb9f609a37f37ec646a3d8be41ccc467cd9c1'
def read(path):
    return (ROOT / path).read_text(encoding='utf-8')
def baseline(path):
    return subprocess.check_output(['git', 'show', BASE + ':' + path], cwd=ROOT).decode('utf-8')
vm = read('App/EPUB/EPUBReaderViewModel.swift')
web = read('App/EPUB/EPUBWebView.swift')
screen = read('App/EPUB/EPUBReaderScreen.swift')
js = read('App/EPUB/EPUBLocationScript.swift')
host = read('Tests/YueJingHostTests/EPUBReaderHostTests.swift')
checks = {}
def check(name, condition):
    checks[name] = bool(condition)
check('touch admission is lifecycle gated, separate from ready',
      '!loading && !closing && !suspended && !exitSaveFailed && (ready || promotingVisibleChapter)' in vm)
check('screen uses continuity only for native touch, actions still require ready',
      '.allowsHitTesting(model.acceptsCanvasTouch && tools.exitRequest == nil && tools.panel == nil)' in screen and
      'interactionEnabled: model.ready && !model.loading' in screen and
      '.accessibilityHidden(!model.ready || model.loading' in screen)
promotion = vm.split('private func promoteVisibleChapter(', 1)[1].split('private func settleVisibleChapter', 1)[0]
check('promotion admits motion before revoking old token',
      promotion.index('promotingVisibleChapter = true') < promotion.index('currentToken = nil') < promotion.index('ready = false'))
check('promotion still marks authority before saving',
      promotion.index('try await reader.markReady(token)') < promotion.index('try await reader.save('))
check('failure clears gesture continuity and pending authority',
      'promotingVisibleChapter = false' in vm.split('func handleLoadFailure(', 1)[1].split('func flush()', 1)[0])
check('snapshot precedes both DOM rebase and full load, but never natural promotion',
      web.index('if !request.preserveViewport, loadedDocumentPath != nil') < web.index('if reuseDOM, let previous {'))
check('configuration error uses terminal cleanup',
      web.count('failReadiness(for: request.token, error: error)') == 4)
failed = web.split('private func failReadiness(', 1)[1].split('/// Revoke native authority', 1)[0]
check('terminal cleanup revokes capabilities and removes snapshot before callback',
      failed.index('resourceHandler.invalidate()') < failed.index('onLoadFailure?(error, token)') and
      failed.index('transitionSnapshot = nil') < failed.index('onLoadFailure?(error, token)'))
check('deadlines and bounded window unchanged',
      'Task.sleep(for: .seconds(15))' in web and 'Task.sleep(for: .seconds(12))' in web and
      read('App/EPUB/EPUBChapterWindow.swift') == baseline('App/EPUB/EPUBChapterWindow.swift'))
check('timeout phase is fixed data and stale deadline cannot overwrite it',
      'case preparing, navigating, rebasing, configuring, restoringWindow, ready' in web and
      'guard activeRequest?.token == token, readyToken != token else { return }\n        lastReadinessFailure' in web)
check('font retention needs unchanged CSS, live identity and loaded status',
      'style.__yjRetainedCSS === style.__yjCSS' in js and 'style.__yjRetainedText === style.textContent' in js and
      'face.status === "loaded" && liveFaces.has(face)' in js)
check('font capability handler and integrity policy unchanged',
      read('App/EPUB/EPUBResourceHandler.swift') == baseline('App/EPUB/EPUBResourceHandler.swift'))
check('persistent positions, store and original archive handling unchanged', all(
      read(p) == baseline(p) for p in ['Sources/ReaderDomain/EPUB/EPUBReadingPosition.swift',
      'Sources/ReaderDomain/LibraryStore.swift','Sources/ReaderDomain/EPUB/EPUBArchive.swift']))
old_assertions = [line.strip() for line in baseline('Tests/YueJingHostTests/EPUBReaderHostTests.swift').splitlines()
                  if '#expect(' in line or '#require(' in line]
check('all previous Host assertion lines retained', all(line in host for line in old_assertions))
check('Host covers synchronous snapshot, failed admission and timeout stage',
      'expectTransitionSnapshot: true' in host and '#expect(!model.acceptsCanvasTouch && !model.promotingVisibleChapter)' in host and
      'controller.lastReadinessFailure?.contains("preparing") == true' in host)
print(json.dumps({'passed': all(checks.values()), 'checks': checks, 'native_executions': 0,
                  'swift_compiled': False, 'ipa_built': False}, ensure_ascii=False, indent=2))
raise SystemExit(0 if all(checks.values()) else 1)

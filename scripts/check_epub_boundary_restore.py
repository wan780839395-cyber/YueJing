"""Static wiring checks only: no Swift compiler, WKWebView, or device acceptance."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]
def read(name):
    return (ROOT / name).read_text(encoding='utf-8')

js = read('App/EPUB/EPUBLocationScript.swift')
web = read('App/EPUB/EPUBWebView.swift')
vm = read('App/EPUB/EPUBReaderViewModel.swift')
pos = read('Sources/ReaderDomain/EPUB/EPUBReadingPosition.swift')
store = read('Sources/ReaderDomain/LibraryStore.swift')
checks = {}
def check(name, value):
    checks[name] = bool(value)

check('optional geometry is backward compatible with synthesized Codable',
      'public let viewportOffset: Double?' in pos and 'viewportOffset: Double? = nil' in pos and 'Codable' in pos)
check('finite bounded geometry without relaxing character validation',
      'viewportOffset.isFinite, abs(viewportOffset) <= 16_384' in pos and 'text.indices.contains(index)' in pos)
check('storage still serializes full position and validates session token',
      'JSONEncoder().encode(position)' in store and 'authority.token == token, authority.ready' in store)
check('configuration binds offset to scroll mode and target path',
      'if readingMode == .scroll, targetPosition?.path == token.path' in js and '"spineCount": package.spine.count' in js)
check('bridge decodes offset and provisional readiness',
      'viewportOffset: (dict["viewportOffset"] as? NSNumber)?.doubleValue' in js and 'restorationPending:' in js)
check('all six model position construction paths carry geometry including live layout sampling',
      vm.count('viewportOffset:') == 6 and
      'rawUTF16Offset: sampled.utf16Offset, viewportOffset: sampled.viewportOffset' in vm)
check('saved anchor identity retained on explicit restoration',
      'navigationRequest?.preserveTargetAnchor == true\n                    ? navigationRequest?.targetPosition?.viewportOffset' in vm)
check('pending DOM cannot sample progress',
      'if (!state.ready || state.suppressingReflow || state.syncing) { return null; }' in js)
check('window completion reapplies original restoration', 'if (state.restoreCompletion) { state.restoreCompletion(); }' in js)
check('no viewport height clipping for image anchors', 'Math.min(state.targetViewportOffset' not in js and 'Math.min(viewportOffset' not in js)
check('park cancels restoration callback', 'state.scrollTimer = null;\n                state.restoreCompletion = null;' in js)
ready = web.split('if payload.restorationPending {', 1)[1].split('pendingViewportRestoreToken = nil', 1)[0]
check('provisional ready never reaches model and retains original deadline',
      'refreshChapterWindow()' in ready and 'return // Not presented' in ready and 'readinessTask?.cancel()' not in ready)
check('original window and readiness time budgets retained',
      'Task.sleep(for: .seconds(15))' in web and 'Task.sleep(for: .seconds(12))' in web and 'EPUBChapterWindow.maximumChapters' in ready)
failed = web.split('private func failReadiness(', 1)[1].split('/// Revoke native authority', 1)[0]
check('failure revokes request and resources before callback',
      failed.index('activeRequest = nil') < failed.index('onLoadFailure?(error, token)') and 'resourceHandler.invalidate()' in failed)
check('restoration window error uses terminal failure path',
      'failReadiness(for: token, error: EPUBError.corruptResource)' in web)
failed_model = vm.split('func handleLoadFailure(', 1)[1].split('func flush()', 1)[0]
check('model failure invalidates pending ready work',
      'generation = UUID()' in failed_model and 'currentToken = nil' in failed_model and 'saveTask?.cancel()' in failed_model)
check('provisional callback rejected defensively by model', 'guard !payload.restorationPending else { return }' in vm)

print(json.dumps(dict(passed=all(checks.values()), checks=checks, native_executions=0,
    note='Static wiring only; run browser regressions separately. Swift/WKWebView/device unverified.'), ensure_ascii=False, indent=2))
raise SystemExit(0 if all(checks.values()) else 1)

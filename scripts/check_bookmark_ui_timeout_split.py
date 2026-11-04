"""Read-only split contracts and negative controls; not Swift/XCTest execution."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import sys
sys.dont_write_bytecode = True
import task3_test_inventory as inventory
ROOT = Path(__file__).resolve().parents[1]
UI = 'Tests/YueJingUITests/ReadingFlowUITests.swift'
INV = 'scripts/task3_test_inventory.py'
WF = '.github/workflows/task3-validate.yml'
NEW = 'testNearbyBookmarksKeepIndependentNamesAndExactJumps'
PINS = {
    UI: '67ae71188b68172706f3d4af2c6c9d015362b7a27b9c5dd6d58b6d69f6915d42',
    INV: '1c536ebc7aa86ab96e1e66c28d2839017902880ade53f81df3401938d493fff4',
    WF: '4503ff310c60c52591bdf175af86f244bb3c7475a6b5e747b13b7c0ed5d974fe',
    'scripts/run_reading_ui_tests.py': 'b44d9fc51390aa10f30da456931424d06bf66d78b6f4423cff1223f44ca525e3',
    'scripts/audit_native_case_events.py': '623b86a004c55a5a9ced31034a1301ab8d111204e85339f1b500baa334ccbc1d',
}
INSERT_SHA = 'a957681a1cc4de5662244d30e9bc322119a554a7972127e1342488c61be0506e'
ANCHOR = '            Self.captureEvidence(app, testName: name, stage: "bookmarks-restored")\n            closePanel(app)\n'
TAIL = '            let beforeNearby = visibleCanvases(app)\n'
def need(ok, message):
    if not ok:
        raise ValueError(message)
def sha(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()
def check(texts):
    source = texts[UI]
    need(source.count(ANCHOR) == source.count(TAIL) == 1, 'Split boundary changed or duplicated')
    begin = source.index(ANCHOR) + len(ANCHOR)
    end = source.index(TAIL)
    need(end > begin, 'Split ordering changed')
    added = source[begin:end]
    need(sha(added) == INSERT_SHA, 'Independent fixture setup changed')
    old = source[:begin] + source[end:]
    need(sha(old) == PINS[UI], 'Old tests/actions/assertions/helpers changed')
    original_names = re.findall(r'\bfunc\s+(test\w+)\s*\(', old)
    names = re.findall(r'\bfunc\s+(test\w+)\s*\(', source)
    need(len(names) == 12 and Counter(names) == Counter(original_names) + Counter([NEW]), 'Old identities lost or duplicate/new identity')
    before_assertions = Counter(re.findall(r'^\s*(XCTAssert[^\n]+)', old, re.M))
    after_assertions = Counter(re.findall(r'^\s*(XCTAssert[^\n]+)', source, re.M))
    need(not before_assertions - after_assertions, 'Assertion multiplicity weakened')
    need(added.count('withFixture { app in') == 1 and added.count('add.tap()') == 1 and
         'saveBookmarkNameEditor("添加书签", name: "第一章起点", app)' in added,
         'New scenario must create its first bookmark through UI in an independent fixture')
    inv = texts[INV]
    need(inv.count(' '+NEW) == 1 and inv.count('"YueJingUITests": 12') == 1, 'Inventory split missing')
    old_inv = inv.replace(' '+NEW, '').replace('"YueJingUITests": 12', '"YueJingUITests": 11').replace(
        'TOTAL = 167  # 168 declared; original 166 identities retained plus one independent bookmark scenario',
        'TOTAL = 166  # 167 declared; original 146 plus 20 bookmarks, independent baseline excluded')
    need(sha(old_inv) == PINS[INV], 'Inventory changes exceed one new UI identity/count')
    wf = texts[WF]
    for new, previous in (
        ('Run 12 real App UI flows including 3 bookmark flows', 'Run 11 real App UI flows including 2 bookmark flows'),
        ('Require the exact reviewed 167-case union before device App compilation', 'Require the exact reviewed 166-case union before device App compilation')):
        need(wf.count(new) == 1, 'Workflow count label missing/duplicated')
        wf = wf.replace(new, previous)
    need(sha(wf) == PINS[WF], 'Workflow changed beyond two display labels')
    for path in PINS.keys() - {UI, INV, WF}:
        need(sha(texts[path]) == PINS[path], 'Runner/parser/budgets changed: '+path)
    return dict(passed=True, original_ui_identities=11, new_ui_identity=NEW, ui_selected=12,
                selected=167, all_declared=168, old_assertion_lines_preserved=sum(before_assertions.values()),
                unchanged_helpers_and_other_cases=True, original_file_reconstructed=True,
                case_budget_seconds=180, ui_budget_seconds=1200, host_budget_seconds=480,
                workflow_execution_chain_unchanged=True, native_executions=0)
def self_check(texts):
    result = check(texts)
    mutations = [
        (UI, 'abs(canvas.frame.minY - initialCanvas.frame.minY) < 2', 'true'),
        (UI, 'abs(canvas.frame.minY - nearbyCanvas.frame.minY) <= 44', 'abs(canvas.frame.minY - nearbyCanvas.frame.minY) <= 440'),
        (UI, 'initialCanvas.frame.minY - canvas.frame.minY > 2', 'true'),
        (UI, 'XCTAssertEqual(rows.count, 2)', '// removed assertion'),
        (UI, 'app.terminate(); app.launch() // Same synthetic database and fixture UUID.', '// removed relaunch'),
        (UI, 'XCTAssertFalse(add.isEnabled)', '// removed dedupe check'),
        (UI, 'XCTAssertEqual(rows.count, 0)', '// removed isolation check'),
        (UI, 'let end = start.withOffset(CGVector(dx: 0, dy: -80))', 'let end = start.withOffset(CGVector(dx: 0, dy: -800))'),
        (UI, '@MainActor func '+NEW+'()', '@MainActor func disabledNearbyScenario()'),
        (UI, 'name: "第一章起点", app)', 'name: "mock", app)'),
        (UI, 'stage: "bookmarks-nearby-initial"', 'stage: "shared-fixture"'),
        (UI, 'private func waitHittable(', 'private func alteredWait('),
        (INV, '"YueJingUITests": 12', '"YueJingUITests": 11'),
        (INV, 'TOTAL = 167', 'TOTAL = 166'),
        (INV, ' '+NEW, ''),
        (WF, 'timeout-minutes: 60', 'timeout-minutes: 90'),
        (WF, 'timeout-minutes: 23', 'timeout-minutes: 40'),
        (WF, 'Run 12 real App UI flows including 3 bookmark flows', 'Run 11 real App UI flows including 2 bookmark flows'),
        ('scripts/run_reading_ui_tests.py', 'else 1200', 'else 2400'),
        ('scripts/run_reading_ui_tests.py', '"180"', '"360"'),
        ('scripts/audit_native_case_events.py', "totals['passed'] == 146", "totals['passed'] >= 0"),
    ]
    for path, old, new in mutations:
        need(old in texts[path], 'Negative control target missing: '+old)
        changed = dict(texts)
        changed[path] = changed[path].replace(old, new, 1)
        try:
            check(changed)
        except ValueError:
            continue
        raise ValueError('Unsafe negative control acceptance: '+old)
    result['negative_controls'] = len(mutations)
    return result
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-check', action='store_true')
    args = parser.parse_args()
    texts = {p: (ROOT/p).read_bytes().decode('utf-8') for p in PINS}
    result = self_check(texts) if args.self_check else check(texts)
    reviewed = inventory.validate_source()
    need(reviewed['selected'] == 167 and reviewed['all_declared'] == 168 and reviewed['groups']['YueJingUITests'] == 12, 'Real inventory mismatch')
    result['limitations'] = 'Offline source/hash contracts only; native XCTest timing, compilation and target-phone behavior remain unverified.'
    print(json.dumps(result, ensure_ascii=False, indent=2))

"""Bounded C-only UI-test repair contracts; no Swift compilation or native execution."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TEST = "Tests/YueJingUITests/ReadingFlowUITests.swift"
ALLOWED = [TEST, "scripts/check_c_only_ui_repair.py", "docs/C_ONLY_UI_TEST_REPAIR.md"]
CYCLE = r'''            let frame = viewport(app).frame
            let collapse = app.buttons["reader.tools.collapse"]
            waitHittable(collapse); collapse.tap()
            let expand = app.buttons["reader.tools.expand"]
            waitHittable(expand)
            XCTAssertFalse(collapse.isHittable)
            XCTAssertFalse(app.buttons["reader.tools.settings"].isHittable)
            XCTAssertGreaterThanOrEqual(expand.frame.width, 44)
            XCTAssertGreaterThanOrEqual(expand.frame.height, 44)
            assertSameFrame(viewport(app).frame, frame)
            expandCDock(app, deadline: Date().addingTimeInterval(10), startsCollapsed: true)
            waitHittable(app.buttons["reader.tools.settings"])
            XCTAssertFalse(expand.isHittable)
            assertSameFrame(viewport(app).frame, frame)
'''
RETURN = '''            let returnDeadline = Date().addingTimeInterval(10)
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: max(0, returnDeadline.timeIntervalSinceNow)))
            waitForExclusiveReaderForeground(app, previousApp: settings, deadline: returnDeadline)
'''
HELPERS = r'''    @MainActor private func waitForExclusiveReaderForeground(_ app: XCUIApplication,
                                                            previousApp: XCUIApplication, deadline: Date) {
        var consecutiveMatches = 0
        var observations: [String] = []
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let readerBefore = app.state
            let previous = previousApp.state
            let readerAfter = app.state
            observations.append("\(readerBefore.rawValue)/\(previous.rawValue)/\(readerAfter.rawValue)")
            if observations.count > 4 { observations.removeFirst() }
            let departed = previous == .runningBackground || previous == .runningBackgroundSuspended || previous == .notRunning
            let matches = readerBefore == .runningForeground && readerAfter == .runningForeground && departed
            consecutiveMatches = matches ? consecutiveMatches + 1 : 0
            return consecutiveMatches >= 2
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: max(0, deadline.timeIntervalSinceNow))
        print("UI_C_FOREGROUND_WAIT result=\(result.rawValue) samples=\(observations.joined(separator: ","))")
        XCTAssertEqual(result, .completed, "Reader foreground and previous-App departure must agree within the same return budget")
    }

    @MainActor private func expandCDock(_ app: XCUIApplication, deadline: Date, startsCollapsed: Bool = false) {
        let expand = app.buttons["reader.tools.expand"], collapse = app.buttons["reader.tools.collapse"]
        if startsCollapsed {
            waitHittable(expand, timeout: max(0, deadline.timeIntervalSinceNow))
            XCTAssertFalse(collapse.isHittable)
        } else {
            let presented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (expand.exists && expand.isHittable) || (collapse.exists && collapse.isHittable)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [presented], timeout: max(0, deadline.timeIntervalSinceNow)), .completed,
                           "The C dock must have a real compact or expanded control before opening a panel")
        }
        if expand.isHittable { expand.tap() }
        waitHittable(collapse, timeout: max(0, deadline.timeIntervalSinceNow))
        XCTAssertFalse(expand.isHittable)
    }

'''
SHOW = '''    @MainActor private func showTools(_ app: XCUIApplication) {
        // Preserve the finite two-touch inertia protocol; sharing its original 10+10-second allowance.
        let deadline = Date().addingTimeInterval(20)
        let expand = app.buttons["reader.tools.expand"], collapse = app.buttons["reader.tools.collapse"]
        if !((expand.exists && expand.isHittable) || (collapse.exists && collapse.isHittable)) {
            viewport(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let firstTouch = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (expand.exists && expand.isHittable) || (collapse.exists && collapse.isHittable)
            }, object: nil)
            let result = XCTWaiter.wait(for: [firstTouch], timeout: min(10, max(0, deadline.timeIntervalSinceNow)))
            if result != .completed {
                // Only the existing second fresh touch after a possible inertia-stop touch.
                viewport(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }
        expandCDock(app, deadline: deadline)
        waitHittable(app.buttons["reader.tools.settings"], timeout: max(0, deadline.timeIntervalSinceNow))
    }
'''


def require(ok, name):
    if not ok:
        raise ValueError(name)


def fingerprint(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return {"bytes": path.stat().st_size, "sha256": h.hexdigest()}


def replace_once(text, before, after):
    require(text.count(before) == 1, "unique-frozen-anchor:" + repr(before[:90]))
    return text.replace(before, after, 1)


def region(text, start, end):
    require(text.count(start) == text.count(end) == 1, "unique-region:" + start[:70])
    a, b = text.index(start), text.index(end)
    require(a < b, "region-order")
    return text[a:b]


def expected_source(previous):
    text = previous
    prefix = ('    @MainActor func testRepeatedPanelsAndAuxiliarySheetsReturnOnlyToReading() {\n'
              '        withFixture { app in\n            open("UITest-Long-A", app)\n')
    text = replace_once(text, prefix, prefix + CYCLE)
    text = replace_once(text, '            app.activate()\n            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))\n', RETURN)
    before = '        let entryDiagnostic = ReadingEntryEvidence.beforeSettings(app, key: key, sharedDeadline: deadline)\n'
    text = replace_once(text, before, '        expandCDock(app, deadline: deadline, startsCollapsed: true)\n' + before)
    before = '    @MainActor private func viewport(_ app: XCUIApplication) -> XCUIElement { app.tables["reader.viewport"] }\n'
    text = replace_once(text, before, HELPERS + before)
    for key in ("settings", "directory"):
        before = f'        let button = app.buttons["reader.tools.{key}"]; waitHittable(button); button.tap()\n'
        after = ('        let deadline = Date().addingTimeInterval(10)\n'
                 '        expandCDock(app, deadline: deadline)\n'
                 f'        let button = app.buttons["reader.tools.{key}"]\n'
                 '        waitHittable(button, timeout: max(0, deadline.timeIntervalSinceNow)); button.tap()\n')
        text = replace_once(text, before, after)
    before = region(text, '    @MainActor private func showTools(_ app: XCUIApplication) {\n',
                    '    @MainActor private func endMarker(_ text: String, _ app: XCUIApplication) -> XCUIElement {\n')
    return replace_once(text, before, SHOW)


def assertions(text):
    """Bounded text scanner for this file's assertion calls; not a Swift AST."""
    require('"""' not in text, "unsupported-multiline-literal")
    result = []
    for match in re.finditer(r'\b(?:XCTAssert\w*|XCTFail)\s*\(', text):
        i = match.end() - 1
        depth, quoted, escaped = 0, False, False
        while i < len(text):
            c = text[i]
            if quoted:
                if escaped:
                    escaped = False
                elif c == "\\":
                    escaped = True
                elif c == '"':
                    quoted = False
            elif c == '"':
                quoted = True
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    result.append("\n".join(line.lstrip() for line in text[match.start():i + 1].splitlines()))
                    break
            i += 1
        else:
            raise ValueError("unclosed-assertion")
    return Counter(result)


def contracts(current, previous):
    checks = []

    def need(ok, name):
        require(ok, name)
        checks.append(name)

    need(current == expected_source(previous), "only-approved-test-transformations-full-text")
    old = assertions(previous)
    original_wait = 'XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))'
    shared_wait = 'XCTAssertTrue(app.wait(for: .runningForeground, timeout: max(0, returnDeadline.timeIntervalSinceNow)))'
    require(old[original_wait] == 1, "one-original-return-wait")
    old[original_wait] -= 1
    old[shared_wait] += 1
    actual = assertions(current)
    need(not (old - actual), "every-original-assertion-retained-with-one-shared-timeout-substitution")
    names = lambda text: re.findall(r"\bfunc\s+(test\w+)\s*\(", text)
    need(names(current) == names(previous) and len(set(names(current))) == 9, "same-nine-test-identities-and-order")
    trip = region(current, '    @MainActor func testOtherAppRoundTripRestoresCentralTapAndWindowUpdates() {\n',
                  '    @MainActor private func sceneRoundTripPID(_ app: XCUIApplication) -> Int {\n')
    old_trip = region(previous, '    @MainActor func testOtherAppRoundTripRestoresCentralTapAndWindowUpdates() {\n',
                      '    @MainActor private func sceneRoundTripPID(_ app: XCUIApplication) -> Int {\n')
    suffix = '            XCTAssertNotEqual(settings.state, .runningForeground)\n'
    need(trip[trip.index(suffix):] == old_trip[old_trip.index(suffix):], "return-single-tap-PID-reader-anchor-and-window-assertions-byte-identical")
    need('            let returnDeadline = Date().addingTimeInterval(10)\n            app.activate()' in trip,
         "activation-and-both-return-waits-share-original-ten-seconds")
    need('expandCDock(' not in trip and 'showTools(' not in trip.replace('// No scroll, AX action, showTools helper, context helper or second tap before this assertion.', ''),
         "no-expand-or-recall-helper-after-App-return")
    center = 'viewport(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()'
    need(trip.count(center) == old_trip.count(center) == 1, "exactly-one-return-central-native-tap")
    fg = region(current, '    @MainActor private func waitForExclusiveReaderForeground(', '    @MainActor private func expandCDock(')
    need('consecutiveMatches = matches ? consecutiveMatches + 1 : 0' in fg and 'return consecutiveMatches >= 2' in fg,
         "two-consecutive-positive-observations-reset-on-mismatch")
    need('readerBefore == .runningForeground && readerAfter == .runningForeground && departed' in fg,
         "reader-state-brackets-previous-App-state-read")
    need('previous == .runningBackground || previous == .runningBackgroundSuspended || previous == .notRunning' in fg,
         "previous-App-must-have-known-nonforeground-state")
    need('observations.count > 4' in fg and 'UI_C_FOREGROUND_WAIT' in fg, "bounded-public-state-only-failure-evidence")
    need(not any(token in fg for token in ('.tap()', '.activate()', '.launch()', '.terminate()', 'sleep', 'Timer', 'Task {')),
         "foreground-wait-is-observation-only")
    dock = region(current, '    @MainActor private func expandCDock(', '    @MainActor private func viewport(')
    need('if expand.isHittable { expand.tap() }' in dock and dock.count('expand.tap()') == 1,
         "one-real-visible-C-expand-button-tap-not-AX-invoke")
    need('waitHittable(collapse, timeout: max(0, deadline.timeIntervalSinceNow))' in dock
         and 'XCTAssertFalse(expand.isHittable)' in dock, "real-expanded-control-and-hidden-compact-control-required")
    need(center not in dock and '.activate()' not in dock, "C-expansion-never-taps-body-or-reopens-reader")
    opening = region(current, '    @MainActor private func open(_ title: String, _ app: XCUIApplication) {\n',
                     '    private static func evidenceCase(_ value: String) -> String {\n')
    need('Date().addingTimeInterval(20)' in opening and 'expandCDock(app, deadline: deadline, startsCollapsed: true)' in opening,
         "fresh-C-expansion-and-original-content-settings-oracles-share-twenty-seconds")
    cycle = region(current, '    @MainActor func testRepeatedPanelsAndAuxiliarySheetsReturnOnlyToReading() {\n',
                   '    @MainActor func testAccessibilityFontLeavesExitAndPanelControlsReachable() {\n')
    need(CYCLE in cycle and cycle.count('assertSameFrame(viewport(app).frame, frame)') == 2,
         "real-collapse-reexpand-44pt-hidden-controls-and-viewport-invariance-regression")
    show = region(current, '    @MainActor private func showTools(_ app: XCUIApplication) {\n',
                  '    @MainActor private func endMarker(_ text: String, _ app: XCUIApplication) -> XCUIElement {\n')
    need(show.count(center) == 2 and 'Date().addingTimeInterval(20)' in show and 'min(10, max(0, deadline.timeIntervalSinceNow))' in show,
         "general-inertia-helper-retains-max-two-touches-and-original-ten-plus-ten-budget")
    need(not any(token in current for token in ('XCTSkip', 'withKnownIssue', 'continueAfterFailure = true', 'Thread.sleep', 'Task.sleep')),
         "no-skip-expected-failure-or-added-sleep")
    return {"checks": checks, "count": len(checks), "original_assertions": sum(assertions(previous).values()),
            "final_assertions": sum(actual.values()), "preserved_assertions": sum(old.values())}


def self_check(current, previous):
    mutations = [
        ("missing-C-open-step", '        expandCDock(app, deadline: deadline, startsCollapsed: true)\n', ''),
        ("no-real-expand", 'if expand.isHittable { expand.tap() }', 'if expand.isHittable { }'),
        ("collapse-not-tapped", 'waitHittable(collapse); collapse.tap()', 'waitHittable(collapse)'),
        ("inactive-control-leak-accepted", 'XCTAssertFalse(expand.isHittable)', 'XCTAssertTrue(expand.isHittable)'),
        ("44pt-weakened", 'XCTAssertGreaterThanOrEqual(expand.frame.height, 44)', 'XCTAssertGreaterThanOrEqual(expand.frame.height, 40)'),
        ("extra-return-touch", '            let exit = app.buttons["reader.exit"], dock = app.buttons["reader.tools.settings"]',
         '            ' + 'viewport(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()\n            let exit = app.buttons["reader.exit"], dock = app.buttons["reader.tools.settings"]'),
        ("PID-oracle-removed", 'XCTAssertEqual(sceneRoundTripPID(app), pid, "A terminated/relaunched process is not recovery")', 'XCTAssertTrue(true)'),
        ("window-oracle-removed", 'XCTAssertEqual(visibleCanvases(app), before, "The same stationary synthetic reader must remain visible")', 'XCTAssertTrue(true)'),
        ("foreground-gate-removed", '            waitForExclusiveReaderForeground(app, previousApp: settings, deadline: returnDeadline)\n', ''),
        ("return-budget-increased", 'let returnDeadline = Date().addingTimeInterval(10)', 'let returnDeadline = Date().addingTimeInterval(20)'),
        ("one-sample-accepted", 'return consecutiveMatches >= 2', 'return consecutiveMatches >= 1'),
        ("mismatch-counter-not-reset", 'consecutiveMatches = matches ? consecutiveMatches + 1 : 0', 'consecutiveMatches += 1'),
        ("previous-still-foreground-accepted", 'let departed = previous == .runningBackground', 'let departed = previous == .runningForeground'),
        ("open-budget-increased", 'let deadline = Date().addingTimeInterval(20)', 'let deadline = Date().addingTimeInterval(40)'),
        ("fixture-relaunch-workaround", '        if expand.isHittable { expand.tap() }', '        app.launch()\n        if expand.isHittable { expand.tap() }'),
    ]
    rejected = []
    for name, before, after in mutations:
        require(before in current, "negative-anchor:" + name)
        try:
            contracts(current.replace(before, after, 1), previous)
        except ValueError:
            rejected.append(name)
        else:
            raise ValueError("negative-accepted:" + name)
    try:
        contracts(previous, previous)
    except ValueError:
        rejected.append("real-preimage-missing-C-steps-and-return-wait")
    else:
        raise ValueError("real-preimage-accepted")
    return {"kind": "IN_MEMORY_SOURCE_NEGATIVES_NOT_NATIVE", "count": len(rejected), "rejected": rejected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    path = args.baseline.resolve()
    require(path.is_relative_to((ROOT / "artifacts").resolve()), "project-evidence-baseline-required")
    baseline = json.loads(path.read_text(encoding="utf-8"))
    require(baseline["root"] == str(ROOT) and baseline["allowed"] == ALLOWED, "exact-three-path-baseline")
    previous_path = path.parent / "preimage" / TEST
    require(fingerprint(previous_path) == baseline["protected"][str(ROOT / TEST)], "real-frozen-test-preimage")
    previous = previous_path.read_bytes().decode("utf-8")
    current = (ROOT / TEST).read_bytes().decode("utf-8")
    checked = contracts(current, previous)
    immutable = {name: value for name, value in baseline["protected"].items() if name != str(ROOT / TEST)}
    drift = [name for name, value in immutable.items() if not Path(name).is_file() or Path(name).is_symlink() or fingerprint(Path(name)) != value]
    require(not drift, "outside-test-immutable-drift:" + repr(drift))
    require(fingerprint(ROOT / ".git/index") == baseline["index_before"], "precommit-index-changed")
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", PYTHONDONTWRITEBYTECODE="1")

    def git(*args):
        return subprocess.check_output(["git", "-C", str(ROOT), "-c", "core.quotepath=false", *args], cwd=ROOT, env=env)

    require(git("rev-parse", "HEAD").decode().strip() == baseline["head"], "HEAD-changed")
    require(not git("diff", "--cached", "--name-only"), "staged-changes")
    require(git("diff", "--name-only", "--no-renames").decode().splitlines() == [TEST], "unexpected-tracked-change")
    untracked = {s.decode("utf-8") for s in git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0") if s}
    require(untracked == set(ALLOWED[1:]) | {".architect_memory.json", "PROJECT_STATE.md", "ask_architect.py"}, "unexpected-untracked-set")
    git("diff", "--check")
    result = {"kind": "SOURCE_TEXT_AND_HASH_NOT_SWIFT_RUNTIME", "status": "passed", "source_contracts": checked,
              "immutable_checked": len(immutable), "protection_drift": [], "head": baseline["head"],
              "candidate": {name: fingerprint(ROOT / name) for name in ALLOWED}, "index": fingerprint(ROOT / ".git/index"),
              "swift_compilations": 0, "native_executions": 0, "production_edits": 0, "fps_measured": False}
    if args.self_check:
        result["negative_controls"] = self_check(current, previous)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        print("C UI repair checks stopped: " + str(error), file=sys.stderr)
        sys.exit(1)

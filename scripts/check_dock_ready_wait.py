"""Offline source contracts for one dock readiness-wait repair; NOT Swift/native execution."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = "bf5d53ba4fa1cb47abeb3f81b0e5558a004c0c2b"
UI = "Tests/YueJingUITests/ReadingFlowUITests.swift"
ALLOWED = {UI, "scripts/check_dock_ready_wait.py", "docs/DOCK_READY_WAIT.md"}


def need(value, message):
    if not value:
        raise ValueError(message)


def git(*args, data=None):
    result = subprocess.run(["git", "-C", str(ROOT), *args], input=data, capture_output=True,
                            timeout=90, env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"})
    need(result.returncode == 0, "Read-only Git failed: " + result.stderr.decode("utf-8", "replace"))
    return result.stdout


def replace_once(text, before, after):
    need(text.count(before) == 1, "Non-unique repair anchor")
    return text.replace(before, after, 1)


def repaired(original):
    start = original.index("    @MainActor private func revealDockControl(")
    end = original.index("    @MainActor private func viewport(", start)
    body = original[start:end]
    body = replace_once(body, '        let scroll = app.scrollViews["reader.tools.scroll"]\n',
                        '        let scroll = app.scrollViews["reader.tools.scroll"]\n        var readyInBounds = false\n')
    condition = "            if !targetFrame.isNull && button.isHittable && bounds.contains(CGPoint(x: targetFrame.midX, y: targetFrame.midY))"
    body = replace_once(body, condition + " { break }", condition + " {\n                readyInBounds = deadline.timeIntervalSinceNow > 0\n                break\n            }")
    body = replace_once(body, "        waitHittable(button, timeout: max(0, deadline.timeIntervalSinceNow))",
                        "        // Reuse readiness proved in this deadline; a second predicate poll can outlive its remainder.\n"
                        "        if !readyInBounds { waitHittable(button, timeout: max(0, deadline.timeIntervalSinceNow)) }")
    return original[:start] + body + original[end:]


def contracts(current, original):
    checks = []
    def check(name, value):
        need(value, name)
        checks.append(name)
    check("only-exact-revealDockControl-repair", current == repaired(original))
    check("all100-original-assertion-sites-retained", len(re.findall(r"\bXCT(?:Assert\w*|Fail)\s*\(", original)) ==
          len(re.findall(r"\bXCT(?:Assert\w*|Fail)\s*\(", current)) == 100)
    check("ready-flag-default-false", "var readyInBounds = false" in current)
    check("proof-requires-existing-frame-hittable-and-visible-center",
          "let targetFrame = button.exists ? button.frame : .null" in current and
          "if !targetFrame.isNull && button.isHittable && bounds.contains(CGPoint(x: targetFrame.midX, y: targetFrame.midY)) {\n                readyInBounds" in current)
    check("readiness-must-still-be-inside-original-deadline", "readyInBounds = deadline.timeIntervalSinceNow > 0" in current)
    check("not-ready-or-expired-retains-original-wait", "if !readyInBounds { waitHittable(button, timeout: max(0, deadline.timeIntervalSinceNow)) }" in current)
    check("same-three-local-swipes-no-retry-or-reopen", current.count("for _ in 0..<3") == original.count("for _ in 0..<3"))
    check("original-shared-10-second-dock-budget", "let dockDeadline = Date().addingTimeInterval(10)" in current)
    return checks


def self_check(current, original):
    mutations = [
        ("var readyInBounds = false", "var readyInBounds = true"),
        ("!targetFrame.isNull && button.isHittable && bounds.contains", "!targetFrame.isNull && bounds.contains"),
        ("button.exists ? button.frame : .null", "button.frame"),
        ("readyInBounds = deadline.timeIntervalSinceNow > 0", "readyInBounds = true"),
        ("if !readyInBounds { waitHittable", "if readyInBounds { waitHittable"),
        ("if !readyInBounds { waitHittable(button, timeout: max(0, deadline.timeIntervalSinceNow)) }", "// no wait"),
        ("bounds.contains(CGPoint(x: targetFrame.midX, y: targetFrame.midY)) {\n                readyInBounds", "true {\n                readyInBounds"),
        ("let dockDeadline = Date().addingTimeInterval(10)", "let dockDeadline = Date().addingTimeInterval(20)"),
        ('XCTAssertTrue(bounds.contains(CGPoint(x: targetFrame.midX, y: targetFrame.midY)),', '// removed center assertion'),
        ('XCTAssertEqual(compactControlFrame.height, expandedControlFrame.height, accuracy: 0.5)', '// removed geometry assertion'),
        ('XCTAssertEqual(sceneRoundTripPID(app), pid)', '// removed process identity assertion'),
        ('XCTAssertFalse(endMarker("UI_CHAPTER_1", app).exists)', '// removed chapter assertion'),
    ]
    rejected = []
    for before, after in mutations:
        need(before in current, "Missing negative-control anchor")
        try:
            contracts(current.replace(before, after, 1), original)
        except ValueError:
            rejected.append(before)
        else:
            raise ValueError("Unsafe mutation accepted: " + before)
    return rejected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    original = git("show", BASE + ":" + UI).decode("utf-8")
    current = (ROOT / UI).read_text(encoding="utf-8")
    checks = contracts(current, original)
    paths = []
    for record in git("ls-tree", "-r", "-z", "--full-tree", BASE).split(b"\0"):
        if not record:
            continue
        meta, path = record.split(b"\t", 1)
        mode, kind, oid = meta.decode().split()
        need(kind == "blob" and mode in ("100644", "100755"), "Unexpected baseline entry")
        paths.append((path.decode("utf-8"), oid))
    need(len(paths) == 199, "Baseline tracked count differs")
    data = git("cat-file", "--batch", data="".join(oid + "\n" for _, oid in paths).encode("ascii"))
    at = 0
    for name, expected_oid in paths:
        end = data.index(b"\n", at)
        oid, kind, size = data[at:end].decode().split()
        at = end + 1
        size = int(size)
        body = data[at:at + size]
        at += size
        need(oid == expected_oid and kind == "blob" and data[at:at + 1] == b"\n", "Blob framing differs")
        at += 1
        if name != UI:
            need((ROOT / name).read_bytes() == body, "Unrelated tracked source changed: " + name)
    need(at == len(data), "Unexpected batch tail")
    need(set(git("diff", "--name-only", BASE).decode().splitlines()) <= ALLOWED, "Unapproved tracked scope")
    need(all((ROOT / n).is_file() for n in ALLOWED), "Missing approved file")
    import check_reader_ui_stability as prior
    # Run the unchanged historical contracts on the exactly reversed UI helper only.
    # This is not a claim that its strict historical-tail contract accepts the new helper.
    files = {n: (ROOT / n).read_text(encoding="utf-8") for n in (*prior.EXISTING, prior.BANNER)}
    files[UI] = original
    old = {n: git("show", prior.BASE + ":" + n).decode("utf-8") for n in prior.EXISTING}
    previous_checks = prior.contracts(files, old)
    import task3_test_inventory as inventory
    selected = inventory.validate_source()
    result = dict(kind="OFFLINE_SOURCE_CONTRACTS_NOT_NATIVE", base=BASE, contracts=checks,
                  unchanged_baseline_files=198, production_source_changed=False,
                  original_UI_assertion_sites=100, declared=selected["all_declared"],
                  selected=selected["selected"], previous_contracts_on_exact_reversal=previous_checks,
                  native_executions=0, Swift_compilation=False)
    if args.self_check:
        result["negative_controls_rejected"] = self_check(current, original)
        result["previous_self_check_on_exact_reversal"] = prior.self_check(files, old)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

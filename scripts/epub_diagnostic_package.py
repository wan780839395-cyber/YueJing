"""Explicitly authorized device-only diagnostic package; never claims native test acceptance."""
import json
import os
from pathlib import Path
import subprocess
import sys

import validate_task3 as v

BASE = "e8112fb89a5704efcd4e09d15341264e22c5c9b5"
SCOPE = "epub-diagnostic-e8112fb"
ALLOWED = frozenset((".github/workflows/task3-validate.yml", "scripts/validate_task3.py",
                     "scripts/epub_diagnostic_package.py", "docs/EPUB_DIAGNOSTIC_PACKAGE.md"))


def git(*args):
    return subprocess.check_output(["git", *args], cwd=v.ROOT, timeout=30)


def tree(revision):
    result = {}
    for row in git("ls-tree", "-r", "-z", revision).split(b"\0"):
        if row:
            meta, name = row.split(b"\t", 1)
            result[name.decode()] = meta.decode().split()
    return result


def scope_receipt():
    env = os.environ
    v.require(env.get("VALIDATION_SCOPE") == SCOPE and env.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
              and env.get("GITHUB_REF") == "refs/heads/main" and env.get("GITHUB_RUN_ATTEMPT") == "1"
              and env.get("GITHUB_REPOSITORY") == "wan780839395-cyber/YueJing", "Diagnostic dispatch identity differs")
    head = git("rev-parse", "HEAD").decode().strip()
    v.require(head == env.get("GITHUB_SHA") and git("rev-parse", "HEAD^").decode().strip() == BASE,
              "Diagnostic candidate must be one packaging-only child of the approved source")
    v.require(not git("status", "--porcelain", "--untracked-files=no").strip(), "Tracked source drift")
    before, after = tree(BASE), tree("HEAD")
    changed = {n for n in set(before) | set(after) if before.get(n) != after.get(n)}
    v.require(changed == ALLOWED and all(after[n][:2] == ["100644", "blob"] for n in changed),
              "Diagnostic package may only change the four publishing paths")
    from package_ipa import expected_project_identity
    identity = expected_project_identity()
    v.require(identity["version"] == "0.2.4" and identity["build"] == "6", "Diagnostic version differs")
    return dict(scope=SCOPE, source_commit=head, product_source_commit=BASE,
                run_id=env["GITHUB_RUN_ID"], run_attempt="1", changed_paths=sorted(changed),
                qualification="DEVICE_DIAGNOSTIC_ONLY", coverage="UI_NOT_QUALIFIED",
                native_tests_executed_this_run=0, full_regression_passed=False,
                physical_acceptance="not performed", files=v.candidate_files())


def validate_saved():
    expected = scope_receipt()
    actual = json.loads((v.OUT / "epub-diagnostic-scope.json").read_bytes())
    v.require(actual == expected, "Diagnostic source/run/disclosure receipt drift")
    v.require(not (v.OUT / "epub-reading-gate.json").exists() and not (v.OUT / "native-test-gate.json").exists(),
              "Diagnostic package cannot carry a current native-pass gate")
    return actual


if __name__ == "__main__":
    if sys.argv[1:] == ["freeze"]:
        v.freeze_candidate()
        v.report("epub-diagnostic-scope.json", scope_receipt())
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as output:
            output.write("## DIAGNOSTIC ONLY — TESTS NOT RUN / UI NOT QUALIFIED\n\n"
                         "User requested a device package after repeated UI failures. "
                         "No simulator, Domain, Host or UI execution. Product source unchanged from e8112fb. "
                         "Device Release, dependency, unsigned and payload byte checks remain required.\n")
    else:
        raise SystemExit("Expected freeze")

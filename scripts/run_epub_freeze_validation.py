"""EPUB short-chapter/directory release: exact Host2 + UI1, or explicit diagnostic-only.

No legacy runner globals are rebound. Diagnostic mode cannot carry native-pass evidence.
Both modes still use the unchanged real-device dependency and IPA payload-byte gates.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import audit_native_case_events as audit
import run_epub_compat_validation as compat
import run_epub_paging_validation as paging
import run_reading_ui_tests as ui
import task3_test_inventory as inventory
import validate_task3 as v
from epub_diagnostic_package import git, tree

BASE = "d0e195e829c84376f6061f6d98df8d1fcfb8aaff"
SCOPE = "epub-freeze-3"
DIAGNOSTIC_SCOPE = "epub-freeze-diagnostic"
VERSION, BUILD = "0.2.5", "7"
ROOT, OUT = v.ROOT, v.OUT
SCOPE_JSON = OUT / "epub-freeze-scope.json"
GATE_JSON = OUT / "epub-freeze-gate.json"
NATIVE_OUT = OUT / "epub-freeze"
NEW = frozenset({"scripts/run_epub_freeze_validation.py", "scripts/check_epub_freeze_validation.py",
                 "docs/EPUB_FREEZE_RELEASE.md"})
ALLOWED = NEW | frozenset({
    "App/EPUB/EPUBContentsView.swift", "App/EPUB/EPUBLocationScript.swift",
    "Tests/YueJingHostTests/EPUBReaderHostTests.swift", "scripts/check_epub_continuous_script.cjs",
    "project.yml", ".github/workflows/task3-validate.yml", "scripts/validate_task3.py",
})
GROUPS = {
    "host": {"target": "YueJingHostTests", "suite": "EPUBReaderHostTests", "timeout": 480, "cases": [
        "epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position",
        "epubCompatibilityWebKitLoadsStaticImagePageAndRestoresAnchor"]},
    "ui": {"target": "YueJingEPUBUITests", "suite": "EPUBFlowUITests", "timeout": 480, "cases": [
        "testEPUBShelfCoverAndDirectoryCrossChapterNavigation"]},
}
require = v.require
load = compat.load_json
write = compat.write_new
sha = compat.digest_path


def selection():
    reviewed = inventory.validate_source(ROOT)
    require(reviewed["selected"] == 214, "Inventory drift")
    for spec in GROUPS.values():
        rel = spec["target"] + "/" + spec["suite"] + ".swift"
        names = inventory.source_names(rel, (ROOT / "Tests" / rel).read_text(encoding="utf-8"))
        require(names == inventory.FILES[rel].split() and set(spec["cases"]) <= set(names), "Selection/source drift")
    require([len(g["cases"]) for g in GROUPS.values()] == [2, 1], "Expected Host2/UI1")
    return {group: list(spec["cases"]) for group, spec in GROUPS.items()}


def scope_receipt():
    env = os.environ
    mode = env.get("VALIDATION_SCOPE")
    require(mode in (SCOPE, DIAGNOSTIC_SCOPE) and env.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and env.get("GITHUB_REF") == "refs/heads/main" and env.get("GITHUB_RUN_ATTEMPT") == "1"
            and env.get("GITHUB_REPOSITORY") == "wan780839395-cyber/YueJing", "Unapproved dispatch identity")
    head = git("rev-parse", "HEAD").decode().strip()
    require(re.fullmatch(r"[0-9a-f]{40}", head) and head == env.get("GITHUB_SHA") and head != BASE,
            "Candidate/source mismatch")
    require(re.fullmatch(r"[1-9][0-9]*", env.get("GITHUB_RUN_ID", "")), "Invalid run identity")
    git("merge-base", "--is-ancestor", BASE, head)
    require(not git("status", "--porcelain", "--untracked-files=no").strip(), "Tracked source drift")
    before, after = tree(BASE), tree("HEAD")
    changed = {p for p in set(before) | set(after) if before.get(p) != after.get(p)}
    require(changed == ALLOWED and set(after) - set(before) == NEW and not set(before) - set(after),
            "Release changes outside exact approved boundary")
    require(all(after[p][:2] == ["100644", "blob"] for p in changed), "Nonregular approved source")
    old_version = b'        MARKETING_VERSION: "0.2.4"\n        CURRENT_PROJECT_VERSION: "6"\n'
    new_version = b'        MARKETING_VERSION: "0.2.5"\n        CURRENT_PROJECT_VERSION: "7"\n'
    old_project = git("show", BASE + ":project.yml")
    require(old_project.count(old_version) == 1 and (ROOT / "project.yml").read_bytes() ==
            old_project.replace(old_version, new_version, 1), "Only approved version lines may change")
    return dict(scope=mode, source_commit=head, baseline_commit=BASE,
                run_id=env["GITHUB_RUN_ID"], run_attempt="1", version=VERSION, build=BUILD,
                changed_paths=sorted(changed), selected=selection() if mode == SCOPE else {},
                native_tests_planned=3 if mode == SCOPE else 0,
                files=v.candidate_files(), approved_files={p: sha(ROOT / p) for p in sorted(ALLOWED)},
                physical_acceptance="not performed", full_regression_passed=False)


def live_scope():
    receipt = scope_receipt()
    require(load(SCOPE_JSON) == receipt, "Frozen scope/source/run drift")
    v.check_candidate()
    return receipt


def command(group, destination, result_bundle):
    require(group in GROUPS and re.fullmatch(r"platform=iOS Simulator,id=[0-9a-fA-F-]{36}", destination),
            "Expected selected simulator UUID and group")
    spec = GROUPS[group]
    suffix = "" if group == "ui" else "()"
    only = ["-only-testing:" + spec["target"] + "/" + spec["suite"] + "/" + case + suffix for case in spec["cases"]]
    return ["xcodebuild", "test", "-project", "YueJing.xcodeproj", "-scheme", "YueJingUI",
            "-configuration", "Debug", "-destination", destination, *only,
            "-parallel-testing-enabled", "NO", "-clonedSourcePackagesDirPath", "build/SourcePackages",
            "-disableAutomaticPackageResolution", "-skipPackageUpdates", "-onlyUsePackageVersionsFromResolvedFile",
            "-derivedDataPath", "build/ReadingUIDerivedData", "-resultBundlePath", str(result_bundle),
            "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "180",
            "-maximum-test-execution-time-allowance", "180", "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64"]


def parse_log(group, raw, code, timed_out):
    require(type(code) is int and code == 0 and timed_out is False, "Native failure/timeout")
    require(isinstance(raw, bytes) and raw, "Missing native log")
    names = GROUPS[group]["cases"]
    text = raw.decode("utf-8")
    events = audit.parse_events(raw, names, ui=group == "ui", ui_class="EPUBFlowUITests")
    require(events["parser_complete"] and not events["unexpected"] and not events["unknown_test_lines"], "Impure/incomplete events")
    require(events["totals"] == dict(passed=len(names), failed=0, skipped=0, unexecuted=0, unfinished=0, ambiguous=0),
            "Native case totals differ")
    for case in events["cases"]:
        require(case["status"] == "passed" and len(case["starts"]) == len(case["finishes"]) == 1
                and case["starts"][0]["line"] < case["finishes"][0]["line"]
                and not case["skips"] and not case["issues"], "Invalid case event chain")
    require("** TEST SUCCEEDED **" in text and "** TEST FAILED **" not in text, "Native success marker missing")
    require(not re.search(r"^.*\b(?:Test|Suite)[^\r\n]*\b(?:skipped|failed)\b", text, re.MULTILINE), "Failure takes precedence")
    summaries = re.findall(r"Test run with (\d+) tests?\b[^\r\n]*?\b(passed|failed)\b", text)
    if group == "host":
        require("Test Case '-[" not in text and summaries == [(str(len(names)), "passed")], "Host summary differs")
        finishes = re.findall(r"\bTest (\w+)\(\) passed after ([0-9.]+) seconds?", text)
    else:
        require(summaries in ([], [("0", "passed")]), "Unexpected Swift tests in UI group")
        finishes = re.findall(r"Test Case '-\[(?:\w+\.)?EPUBFlowUITests (test\w+)\]' passed \(([0-9.]+) seconds?\)", text)
        xc = re.findall(r"Executed (\d+) tests?, (?:(\d+) tests? skipped and )?(?:with )?(\d+) failures? \((\d+) unexpected\)", text)
        require(xc and all(n == "1" and skip in ("", "0") and failed == unexpected == "0" for n, skip, failed, unexpected in xc), "UI summary differs")
    require(sorted(n for n, _ in finishes) == sorted(names) and all(float(t) <= 180 for _, t in finishes),
            "Case identity/duration differs; late pass cannot override timeout")
    return dict(group=group, passed=list(names), native_exit=0, timed_out=False,
                log_sha256=compat.digest_bytes(raw), events=events)


def provenance(group, destination, bundle, scope):
    return dict(scope=SCOPE, source_commit=scope["source_commit"], run_id=scope["run_id"], run_attempt="1",
                group=group, target=GROUPS[group]["target"], destination=destination,
                expected_cases=GROUPS[group]["cases"], command=command(group, destination, bundle),
                timeout_seconds=GROUPS[group]["timeout"], case_timeout_seconds=180)


def run_group(group, destination):
    scope = live_scope()
    require(scope["scope"] == SCOPE, "Diagnostic mode cannot execute tests")
    compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=True)
    compat.validate_destination(destination, OUT)
    folder = NATIVE_OUT / group
    require(not folder.exists(), "Existing group evidence; use a fresh run after diagnosis")
    folder.mkdir(parents=True)
    target = GROUPS[group]["target"]
    bundle = folder / (target + ".xcresult")
    want = provenance(group, destination, bundle, scope)
    write(folder / "selection.json", want)
    ui.actual_settings(target, folder, scope["source_commit"])
    paging.validate_group_settings(group, folder, scope["source_commit"], root=ROOT, out=OUT)
    log = folder / (target + ".log")
    code, timed_out = ui.stream_native(want["command"], log, GROUPS[group]["timeout"])
    write(folder / "execution.json", dict(**want, native_exit=code, timed_out=timed_out))
    parsed = parse_log(group, log.read_bytes(), code, timed_out)
    paging.require_xcresult(bundle)
    require(live_scope() == scope, "Source changed during native execution")
    write(folder / "counts.json", parsed)
    print(json.dumps(parsed, indent=2))


def qualification():
    scope = live_scope()
    require(not (OUT / "native-test-gate.json").exists() and not (OUT / "epub-reading-gate.json").exists(), "Mixed qualification")
    if scope["scope"] == DIAGNOSTIC_SCOPE:
        require(not NATIVE_OUT.exists() and not (OUT / "simulator-selection.json").exists(), "Diagnostic run contains native evidence")
        return dict(**scope, qualification="DEVICE_DIAGNOSTIC_ONLY", coverage="UI_NOT_QUALIFIED",
                    native_tests_executed_this_run=0, verified_passed=0)
    compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=False)
    sim = load(OUT / "simulator-selection.json")
    destination = "platform=iOS Simulator,id=" + sim["udid"]
    compat.validate_destination(destination, OUT)
    require(NATIVE_OUT.is_dir() and not NATIVE_OUT.is_symlink() and {p.name for p in NATIVE_OUT.iterdir()} == set(GROUPS), "Missing/extra groups")
    groups = []
    for group, spec in GROUPS.items():
        folder = NATIVE_OUT / group
        require(not folder.is_symlink(), "Symlink group")
        bundle = folder / (spec["target"] + ".xcresult")
        paging.require_xcresult(bundle)
        want = provenance(group, destination, bundle, scope)
        require(load(folder / "selection.json") == want, "Selection receipt mismatch")
        execution = load(folder / "execution.json")
        require(execution == dict(**want, native_exit=0, timed_out=False), "Execution/provenance mismatch")
        paging.validate_group_settings(group, folder, scope["source_commit"], root=ROOT, out=OUT)
        parsed = parse_log(group, (folder / (spec["target"] + ".log")).read_bytes(), execution["native_exit"], execution["timed_out"])
        require(load(folder / "counts.json") == parsed, "Raw events differ from saved counts")
        groups.append(parsed)
    return dict(**scope, qualification="EPUB_FREEZE_3_TARGETED_NATIVE", coverage="EPUB_TARGETED_NOT_FULL",
                native_tests_executed_this_run=3, verified_passed=3, not_executed_this_run=211, groups=groups, simulator=sim)


def validate_saved():
    actual = qualification()
    require(load(GATE_JSON) == actual, "Qualification receipt drift")
    return actual


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("scope")
    run = sub.add_parser("run")
    run.add_argument("group", choices=GROUPS)
    run.add_argument("--destination", required=True)
    sub.add_parser("gate")
    args = parser.parse_args()
    if args.action == "scope":
        v.freeze_candidate()
        write(SCOPE_JSON, scope_receipt())
    elif args.action == "run":
        run_group(args.group, args.destination)
    else:
        result = qualification()
        write(GATE_JSON, result)
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        raise SystemExit("EPUB freeze release stopped: " + str(error))

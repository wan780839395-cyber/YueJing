"""Strict 15-case EPUB reading gate (Domain8 + Host4 + UI3), not full regression.

Shared helpers receive explicit evidence paths. Legacy runner globals are never
rebound. A failed attempt retains its receipts; repairs require a fresh run ID.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import audit_native_case_events as audit
import run_epub_compat_validation as compat
import run_epub_paging_validation as paging
import run_reading_ui_tests as ui
import task3_test_inventory as inventory
import validate_task3 as validator

require = compat.require
digest_bytes = compat.digest_bytes
digest_path = compat.digest_path
git_blob_sha1 = compat.git_blob_sha1
load_json = compat.load_json
write_new = compat.write_new
write_new_text = compat.write_new_text
validate_destination = compat.validate_destination
validate_toolchain_and_dependencies = compat.validate_toolchain_and_dependencies

ROOT = SCRIPT_DIR.parent
OUT = ROOT / "artifacts/task3"
EPUB_OUT = OUT / "epub-reading"
SCOPE_JSON = OUT / "epub-reading-scope.json"
GATE_JSON = OUT / "epub-reading-gate.json"
BASE = "63a68c3d0776ec8084156f16ccd43537f79eaf24"
SCOPE = "epub-reading-15"
EXPECTED_VERSION = "0.2.4"
EXPECTED_BUILD = "6"
BUILD = EXPECTED_BUILD
TOTAL_SELECTED = 15
OLD_VERSION_LINES = b'        MARKETING_VERSION: "0.2.3"\n        CURRENT_PROJECT_VERSION: "5"\n'
NEW_VERSION_LINES = b'        MARKETING_VERSION: "0.2.4"\n        CURRENT_PROJECT_VERSION: "6"\n'
# Reviewed release whitelist, embedded rather than loaded from ignored artifacts.
ALLOWED = frozenset({
    ".github/workflows/task3-validate.yml", "App/AppVersion.swift",
    "App/EPUB/EPUBChapterWindow.swift", "App/EPUB/EPUBLocationScript.swift",
    "App/EPUB/EPUBPaging.swift", "App/EPUB/EPUBReaderScreen.swift",
    "App/EPUB/EPUBReaderViewModel.swift", "App/EPUB/EPUBReadingMode.swift",
    "App/EPUB/EPUBResourceHandler.swift", "App/EPUB/EPUBSettingsView.swift",
    "App/EPUB/EPUBWebView.swift", "App/Library/LibraryExploreSettings.swift",
    "Sources/ReaderDomain/EPUB/EPUBImportService.swift",
    "Sources/ReaderDomain/EPUB/EPUBPublicationCache.swift",
    "Sources/ReaderDomain/EPUB/OpenedEPUBReader.swift",
    "Sources/ReaderDomain/LibraryService.swift", "Sources/ReaderDomain/LibraryStore.swift",
    "Tests/ReaderDomainTests/EPUBLibraryTests.swift",
    "Tests/YueJingEPUBUITests/EPUBFlowUITests.swift",
    "Tests/YueJingHostTests/EPUBReaderHostTests.swift",
    "docs/EPUB_CONTINUOUS_READING.md", "docs/EPUB_READING_MODES.md",
    "docs/EPUB_READING_RELEASE.md", "project.yml",
    "scripts/check_epub_continuous_script.cjs", "scripts/check_epub_horizontal_script.cjs",
    "scripts/check_epub_reading_validation.py", "scripts/run_epub_reading_validation.py",
    "scripts/validate_task3.py",
})
NEW_ALLOWED = frozenset({
    "App/AppVersion.swift", "App/EPUB/EPUBChapterWindow.swift", "App/EPUB/EPUBReadingMode.swift",
    "Sources/ReaderDomain/EPUB/EPUBPublicationCache.swift",
    "docs/EPUB_CONTINUOUS_READING.md", "docs/EPUB_READING_MODES.md", "docs/EPUB_READING_RELEASE.md",
    "scripts/check_epub_continuous_script.cjs", "scripts/check_epub_horizontal_script.cjs",
    "scripts/check_epub_reading_validation.py", "scripts/run_epub_reading_validation.py",
})
SELECTED_FILES = {
    "ReaderDomainTests/EPUBLibraryTests.swift": (
        "epubOriginalArchiveAndValidatedResourcesSurviveReopen",
        "epubDuplicateKeepsProgressAndRepairsMissingArchive",
        "epubBooksAndTXTStayIsolated",
    ),
    "ReaderDomainTests/EPUBCompatibilityTests.swift": (
        "epubCompatibilityEPUB2DoctypeImageWebPImportProgressSurvivesReopen",
    ),
    "ReaderDomainTests/EPUBProgressTests.swift": (
        "epubPositionsRejectForeignVersionsUnitsAndInvalidUTF16Boundaries",
        "epubProgressRequiresReadinessAndIncreasingSequence",
        "epubOldNavigationSupersededSessionAndClosedCallbacksCannotWrite",
        "epubTypographyEpochRestoresSameTextPositionAndSettings",
    ),
    "YueJingHostTests/EPUBReaderHostTests.swift": (
        "epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position",
        "epubSecurityRejectsScriptsFormsExternalResourcesAndKeepsIsolatedLocatorWorking",
        "epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks",
        "epubCompatibilityWebKitLoadsStaticImagePageAndRestoresAnchor",
    ),
    "YueJingEPUBUITests/EPUBFlowUITests.swift": (
        "testEPUBShelfCoverAndDirectoryCrossChapterNavigation",
        "testEPUBProgressSurvivesExitAndProcessRelaunch",
        "testEPUBTypographyNoCoverFallbackAndTXTIsolation",
    ),
}
GROUP_SPECS = {
    "domain": {"target": "ReaderDomainTests", "scheme": "ReaderDomain",
               "derived_data": "build/Task3Tests", "timeout_seconds": 480, "expected_count": 8},
    "host": {"target": "YueJingHostTests", "scheme": "YueJingUI",
             "derived_data": "build/ReadingUIDerivedData", "timeout_seconds": 480, "expected_count": 4},
    "ui": {"target": "YueJingEPUBUITests", "scheme": "YueJingUI",
           "derived_data": "build/ReadingUIDerivedData", "timeout_seconds": 1200, "expected_count": 3},
}
for _spec in GROUP_SPECS.values():
    _spec.update(configuration="Debug", case_timeout_seconds=180)
    _spec["files"] = tuple(f for f in SELECTED_FILES if f.startswith(_spec["target"] + "/"))
    _spec["suites"] = tuple(f.removesuffix(".swift") for f in _spec["files"])
    _spec["cases"] = tuple(n for f in _spec["files"] for n in SELECTED_FILES[f])
del _spec
FAIL_COUNTS = {k: 0 for k in ("failed", "skipped", "unexecuted", "unfinished", "ambiguous")}


def group_expected_names(group):
    require(group in GROUP_SPECS, f"Unknown EPUB reading group: {group!r}")
    return list(GROUP_SPECS[group]["cases"])


def validate_selected_cases(root=ROOT):
    reviewed = inventory.validate_source(Path(root))
    require(reviewed["selected"] == inventory.TOTAL == 214, "Full inventory must remain 214")
    require(len(SELECTED_FILES) == 5, "Exactly five selected source files required")
    all_names = []
    for group, spec in GROUP_SPECS.items():
        expected = group_expected_names(group)
        require(len(expected) == len(set(expected)) == spec["expected_count"], "Invalid selection count")
        require(expected == [n for f in spec["files"] for n in SELECTED_FILES[f]], "Group selection drift")
        for rel in spec["files"]:
            source = Path(root) / "Tests" / rel
            require(source.is_file() and not source.is_symlink(), "Missing regular selected source: " + rel)
            names = inventory.source_names(rel, source.read_text(encoding="utf-8"))
            require(names == inventory.FILES[rel].split() and set(SELECTED_FILES[rel]) <= set(names),
                    "Selection/source differs from frozen inventory: " + rel)
        all_names.extend(expected)
    require(len(all_names) == len(set(all_names)) == TOTAL_SELECTED, "Selected fifteen identities differ")
    return {"total": TOTAL_SELECTED, "domain": 8, "host": 4, "ui": 3, "full_inventory": 214,
            "files": {"Tests/" + k: list(v) for k, v in SELECTED_FILES.items()}}


def validate_project_version(base_bytes, current_bytes):
    require(isinstance(base_bytes, bytes) and isinstance(current_bytes, bytes), "project.yml inputs must be bytes")
    require(base_bytes.count(OLD_VERSION_LINES) == 1, "Baseline lacks unique 0.2.3/build5 lines")
    require(current_bytes.count(NEW_VERSION_LINES) == 1, "Candidate lacks unique 0.2.4/build6 lines")
    require(current_bytes == base_bytes.replace(OLD_VERSION_LINES, NEW_VERSION_LINES, 1),
            "project.yml may change only 0.2.3/5 -> 0.2.4/6")


def validate_scope_boundaries(previous, current, base_project_bytes, current_project_bytes,
                              *, env, head, is_ancestor=True, status=b"", worktree_blobs=None):
    require(isinstance(env, dict), "Environment must be a dict")
    require(env.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and env.get("GITHUB_RUN_ATTEMPT") == "1"
            and env.get("GITHUB_REF") == "refs/heads/main"
            and env.get("VALIDATION_SCOPE") == SCOPE, "Unapproved event/ref/attempt/scope")
    sha, run_id = env.get("GITHUB_SHA", ""), str(env.get("GITHUB_RUN_ID", ""))
    require(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha)
            and sha == head and sha != BASE, "HEAD/GITHUB_SHA mismatch or identical to BASE")
    require(re.fullmatch(r"[1-9][0-9]*", run_id), "Invalid run ID")
    require(is_ancestor is True, "BASE is not an ancestor of HEAD")
    status = status.encode() if isinstance(status, str) else status
    require(isinstance(status, bytes) and not status.strip(), "Worktree must be clean committed state")
    require(isinstance(previous, dict) and isinstance(current, dict) and previous and current, "Invalid git tree")
    require(all(isinstance(v, list) and len(v) == 3 and v[:2] == ["100644", "blob"]
                and re.fullmatch(r"[0-9a-f]{40}", v[2]) for v in current.values()), "Nonregular tracked HEAD input")
    require(not set(previous) - set(current), "Baseline tracked files deleted")
    require(ALLOWED <= set(current), "Approved whitelist files missing")
    changed = {p for p in set(previous) | set(current) if previous.get(p) != current.get(p)}
    require(changed and changed <= ALLOWED, "Changes outside 29-path whitelist: " + repr(sorted(changed - ALLOWED)))
    added = set(current) - set(previous)
    require(added == NEW_ALLOWED, "New tracked files differ from eleven-path whitelist")
    require("project.yml" in changed, "Version update required")
    validate_project_version(base_project_bytes, current_project_bytes)
    require(previous["project.yml"][2] == git_blob_sha1(base_project_bytes), "Baseline project blob mismatch")
    require(current["project.yml"][2] == git_blob_sha1(current_project_bytes), "Current project blob mismatch")
    if worktree_blobs is not None:
        require(set(worktree_blobs) == set(current), "Worktree file set differs from HEAD")
        require(all(worktree_blobs[p] == v[2] for p, v in current.items()), "Worktree bytes differ from committed blobs")
    return {
        "scope": SCOPE, "baseline_commit": BASE, "source_commit": sha,
        "run_id": run_id, "run_attempt": "1", "version": EXPECTED_VERSION, "build": EXPECTED_BUILD,
        "changed_paths": sorted(changed), "added_paths": sorted(added), "allowed_paths": sorted(ALLOWED),
        "project_yml_sha256": digest_bytes(current_project_bytes),
        "baseline_project_yml_sha256": digest_bytes(base_project_bytes),
        "selected_total": TOTAL_SELECTED,
        "selected_groups": {g: s["expected_count"] for g, s in GROUP_SPECS.items()},
        "selected_files": {k: list(v) for k, v in SELECTED_FILES.items()},
    }


def verify_scope(root=ROOT):
    validate_selected_cases(root)
    validator.check_candidate()
    head = compat.git("rev-parse", "HEAD", root=root).decode().strip()
    ancestor = subprocess.run(["git", "merge-base", "--is-ancestor", BASE, "HEAD"],
                              cwd=root, capture_output=True, timeout=30).returncode == 0
    previous, current = compat.git_tree(BASE, root=root), compat.git_tree("HEAD", root=root)
    blobs = {}
    for name in current:
        path = Path(root) / name
        require(path.is_file() and not path.is_symlink(), "Nonregular tracked worktree input: " + name)
        blobs[name] = git_blob_sha1(path.read_bytes())
    return validate_scope_boundaries(
        previous, current, compat.git("show", f"{BASE}:project.yml", root=root),
        (Path(root) / "project.yml").read_bytes(), env=dict(os.environ), head=head,
        is_ancestor=ancestor, status=compat.git("status", "--porcelain=v1", "--untracked-files=no", root=root),
        worktree_blobs=blobs,
    )


def scope():
    receipt = verify_scope(ROOT)
    write_new(SCOPE_JSON, receipt)
    print(json.dumps(receipt, indent=2))
    return receipt


def case_identifiers(group):
    group_expected_names(group)
    suffix = "" if group == "ui" else "()"
    return [f"{f.removesuffix('.swift')}/{name}{suffix}"
            for f in GROUP_SPECS[group]["files"] for name in SELECTED_FILES[f]]


def expected_command(group, destination, result_bundle):
    group_expected_names(group)
    require(isinstance(destination, str) and re.fullmatch(r"platform=iOS Simulator,id=[0-9a-fA-F-]{36}", destination),
            "Provide an installed simulator UUID, never a device")
    spec = GROUP_SPECS[group]
    return [
        "xcodebuild", "test", "-project", "YueJing.xcodeproj", "-scheme", spec["scheme"],
        "-configuration", "Debug", *(["-sdk", "iphonesimulator"] if group == "domain" else []),
        "-destination", destination, *["-only-testing:" + name for name in case_identifiers(group)],
        "-parallel-testing-enabled", "NO", "-clonedSourcePackagesDirPath", "build/SourcePackages",
        "-disableAutomaticPackageResolution", "-skipPackageUpdates", "-onlyUsePackageVersionsFromResolvedFile",
        "-derivedDataPath", spec["derived_data"], "-resultBundlePath", str(result_bundle),
        "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "180",
        "-maximum-test-execution-time-allowance", "180", "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64",
    ]


def prepare_group_settings(group, group_out, source_commit, *, root=ROOT, out=OUT):
    group_expected_names(group)
    if group == "domain":
        # Require the workflow's effective settings proof; never invoke UI's
        # App-hosted settings query for the unhosted ReaderDomainTests target.
        load_json(Path(out) / "effective-test-settings.json")
        compat.prepare_group_settings(group, group_out, source_commit, root=root, out=out)
    else:
        ui.actual_settings(GROUP_SPECS[group]["target"], Path(group_out), source_commit)
    return validate_group_settings(group, group_out, source_commit, root=root, out=out)


def validate_group_settings(group, group_out, source_commit, *, root=ROOT, out=OUT):
    group_expected_names(group)
    helper = compat if group == "domain" else paging
    return helper.validate_group_settings(group, group_out, source_commit, root=root, out=out)


def parse_group_log(group, raw_bytes, native_exit, timed_out):
    expected = group_expected_names(group)
    count = GROUP_SPECS[group]["expected_count"]
    require(type(native_exit) is int and native_exit == 0, f"Native command failed: {native_exit!r}")
    require(timed_out is False, "Native command timed out")
    require(isinstance(raw_bytes, (bytes, bytearray)) and raw_bytes, "Missing raw log")
    raw = bytes(raw_bytes)
    text = raw.decode("utf-8")
    events = audit.parse_events(raw, expected, ui=group == "ui", ui_class="EPUBFlowUITests")
    require(events["parser_complete"] and not events["unexpected"] and not events["unknown_test_lines"],
            "Incomplete or impure native case events")
    require(events["totals"] == {"passed": count, **FAIL_COUNTS}, "Native case totals mismatch")
    for case in events["cases"]:
        require(case["status"] == "passed" and len(case["starts"]) == len(case["finishes"]) == 1
                and case["finishes"][0]["status"] == "passed"
                and case["starts"][0]["line"] < case["finishes"][0]["line"]
                and not case["skips"] and not case["issues"], "Invalid event chain")
    require("** TEST SUCCEEDED **" in text and "** TEST FAILED **" not in text, "Missing native success marker")
    require(not re.search(r"^.*\b(?:Test|Suite)[^\r\n]*\b(?:skipped|failed)\b", text, re.MULTILINE),
            "Native failure/skip takes precedence")
    swift_summaries = re.findall(r"Test run with (\d+) tests?\b[^\r\n]*?\b(passed|failed)\b", text)
    if group != "ui":
        require(not re.search(r"Test Case '-\[", text), "Unexpected XCTest execution in Swift selection")
        require(swift_summaries == [(str(count), "passed")], "Missing/duplicate/wrong Swift Testing summary")
        passed = re.findall(r"\bTest (\w+)\(\) passed after\b", text)
        summaries = [list(row) for row in swift_summaries]
    else:
        other = audit.parse_events(raw, [], ui=False)
        ui_lines = {row["line"] for case in events["cases"] for key in ("starts", "finishes") for row in case[key]}
        require(not other["unexpected"] and not other["derived_starts"]
                and all(row["line"] in ui_lines for row in other["unknown_test_lines"]),
                "Unexpected Swift Testing events in UI selection")
        require(swift_summaries in ([], [("0", "passed")]), "Unexpected Swift Testing run in UI selection")
        passed = re.findall(r"Test Case '-\[(?:\w+\.)?EPUBFlowUITests (test\w+)\]' passed \(", text)
        xc_summaries = re.findall(r"Executed (\d+) tests?, (?:(\d+) tests? skipped and )?(?:with )?(\d+) failures? \((\d+) unexpected\)", text)
        require(xc_summaries and all(n == str(count) and skip in ("", "0") and fail == unexpected == "0"
                                    for n, skip, fail, unexpected in xc_summaries), "XCTest summary mismatch")
        summaries = [list(row) for row in xc_summaries]
    require(len(passed) == len(set(passed)) == count and sorted(passed) == sorted(expected), "Passed identities differ")
    return {"group": group, "target": GROUP_SPECS[group]["target"], "expected": count,
            "declared": expected, "passed": passed, **FAIL_COUNTS, "native_exit": 0, "timed_out": False,
            "native_summaries": summaries, "log_sha256": digest_bytes(raw), "events": events}


def provenance_for(group, destination, result_bundle, scope_receipt):
    group_expected_names(group)
    spec = GROUP_SPECS[group]
    return {
        "scope": SCOPE, "group": group, "target": spec["target"],
        "source_commit": scope_receipt["source_commit"], "run_id": scope_receipt["run_id"], "run_attempt": "1",
        "scheme": spec["scheme"], "configuration": "Debug", "destination": destination,
        "suites": list(spec["suites"]), "case_identifiers": case_identifiers(group),
        "expected": spec["expected_count"], "declared": group_expected_names(group),
        "command": expected_command(group, destination, result_bundle),
        "timeout_seconds": spec["timeout_seconds"], "case_timeout_seconds": spec["case_timeout_seconds"],
    }


require_xcresult = paging.require_xcresult


def run_group(group, destination):
    group_expected_names(group)
    scope_receipt = verify_scope(ROOT)
    require(load_json(SCOPE_JSON) == scope_receipt, "Saved scope differs from live scope")
    validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=True)
    validate_destination(destination, OUT)
    spec = GROUP_SPECS[group]
    target = spec["target"]
    group_out = EPUB_OUT / group
    require(not group_out.exists(), "Group evidence already exists; retries forbidden")
    group_out.mkdir(parents=True, exist_ok=False)
    files_before = validator.candidate_files()
    result_bundle = group_out / f"{target}.xcresult"
    provenance = provenance_for(group, destination, result_bundle, scope_receipt)
    write_new(group_out / f"{target}-selection.json", provenance)
    write_new(group_out / f"{target}-source-hashes.json", {"source_commit": scope_receipt["source_commit"], "files": files_before})
    prepare_group_settings(group, group_out, scope_receipt["source_commit"], root=ROOT, out=OUT)
    log = group_out / f"{target}.log"
    code, timed_out = ui.stream_native(provenance["command"], log, spec["timeout_seconds"])
    write_new_text(group_out / f"{target}-exit-code.txt", f"{code}\n")
    write_new(group_out / f"{target}-execution.json", {**provenance, "native_exit": code, "timed_out": timed_out})
    parsed = parse_group_log(group, log.read_bytes(), code, timed_out)
    require_xcresult(result_bundle)
    require(verify_scope(ROOT) == scope_receipt and validator.candidate_files() == files_before,
            "Source changed during native execution")
    counts = {**provenance, **{k: v for k, v in parsed.items() if k != "events"}}
    write_new(group_out / f"{target}-counts.json", counts)
    print(json.dumps(counts, indent=2))
    return counts


def validate_group_receipts(group, *, scope_receipt, expected_destination, candidate_files, root=ROOT, out=OUT):
    group_expected_names(group)
    spec = GROUP_SPECS[group]
    target = spec["target"]
    group_out = Path(out) / "epub-reading" / group
    require(group_out.is_dir() and not group_out.is_symlink(), "Missing regular group evidence directory")
    result_bundle = group_out / f"{target}.xcresult"
    require_xcresult(result_bundle)
    records = {key: load_json(group_out / f"{target}-{key}.json")
               for key in ("selection", "execution", "counts", "source-hashes")}
    validate_group_settings(group, group_out, scope_receipt["source_commit"], root=root, out=out)
    want = provenance_for(group, expected_destination, result_bundle, scope_receipt)
    for key in ("selection", "execution", "counts"):
        require(all(records[key].get(k) == v for k, v in want.items()), f"{group} {key} provenance/command mismatch")
    exit_path, log_path = group_out / f"{target}-exit-code.txt", group_out / f"{target}.log"
    require(all(p.is_file() and not p.is_symlink() for p in (exit_path, log_path)), "Missing regular exit/log evidence")
    code = int(exit_path.read_text(encoding="utf-8").strip())
    require(code == 0 and all(type(records[k].get("native_exit")) is int and records[k]["native_exit"] == 0
                              and records[k].get("timed_out") is False for k in ("execution", "counts")),
            "Native failure/timeout in receipts")
    parsed = parse_group_log(group, log_path.read_bytes(), code, records["execution"]["timed_out"])
    require(all(records["counts"].get(k) == v for k, v in parsed.items() if k != "events"),
            "Counts differ from raw log reparse")
    require(records["source-hashes"] == {"source_commit": scope_receipt["source_commit"], "files": candidate_files},
            "Source hashes drift")
    return {
        **want, "passed_count": len(parsed["passed"]), "passed": parsed["passed"], **FAIL_COUNTS,
        "native_exit": 0, "timed_out": False, "log_sha256": parsed["log_sha256"],
        **{key.replace("-", "_") + "_sha256": digest_path(group_out / f"{target}-{key}.json")
           for key in ("selection", "execution", "counts", "settings", "source-hashes")},
        "xcresult": result_bundle.relative_to(root).as_posix(),
    }


def verify_gate():
    scope_receipt = verify_scope(ROOT)
    require(load_json(SCOPE_JSON) == scope_receipt, "Saved scope differs from live scope")
    packages = validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=False)
    sim = load_json(OUT / "simulator-selection.json")
    destination = f"platform=iOS Simulator,id={sim.get('udid', '')}"
    validate_destination(destination, OUT)
    require(EPUB_OUT.is_dir() and not EPUB_OUT.is_symlink()
            and {p.name for p in EPUB_OUT.iterdir()} == set(GROUP_SPECS), "Missing/extra root groups")
    files = validator.candidate_files()
    groups = [validate_group_receipts(g, scope_receipt=scope_receipt, expected_destination=destination,
                                     candidate_files=files, root=ROOT, out=OUT) for g in GROUP_SPECS]
    combined = [n for g in groups for n in g["passed"]]
    require(len(combined) == len(set(combined)) == TOTAL_SELECTED
            and set(combined) == {n for g in GROUP_SPECS for n in group_expected_names(g)}, "Combined fifteen identities differ")
    return {
        "qualification": "EPUB_READING_15_TARGETED_NATIVE", "scope": SCOPE,
        "coverage": "EPUB_READING_TARGETED_NOT_FULL",
        "source_commit": scope_receipt["source_commit"], "baseline_commit": BASE,
        "run_id": scope_receipt["run_id"], "run_attempt": "1", "version": EXPECTED_VERSION, "build": EXPECTED_BUILD,
        "passed": True, "native_tests_executed_this_run": TOTAL_SELECTED, "verified_passed": TOTAL_SELECTED,
        **{g["group"] + "_passed": g["passed_count"] for g in groups}, **FAIL_COUNTS,
        "full_inventory_declared": 214, "not_executed_this_run": 199, "full_regression_executed_this_run": False,
        "historical_reference": {"status": "not_executed_this_run",
                                 "note": "The other 199 cases are not executed or claimed passed in this run."},
        "simulator": sim, "changed_paths": scope_receipt["changed_paths"],
        "scope_receipt_sha256": digest_path(SCOPE_JSON),
        "candidate_sources_sha256": digest_path(OUT / "candidate-sources.json"),
        "dependency_resolution_sha256": digest_path(OUT / "dependency-resolution.json"),
        "packages": packages, "groups": groups,
    }


def gate():
    receipt = verify_gate()
    write_new(GATE_JSON, receipt)
    print(json.dumps(receipt, indent=2))
    return receipt


def validate_saved():
    """Read-only: revalidate current source, run and raw native evidence, never repair it."""
    saved = load_json(GATE_JSON)
    actual = verify_gate()
    require(saved == actual, "epub-reading-gate.json receipt drift or mismatch")
    return actual


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("scope", help="Verify 29-path scope and write exclusive scope receipt")
    run = sub.add_parser("run", help="Run one group once, selecting individual cases only")
    run.add_argument("group", choices=tuple(GROUP_SPECS))
    run.add_argument("--destination", required=True)
    sub.add_parser("gate", help="Reparse all three native groups and write exclusive qualification")
    args = parser.parse_args(argv)
    if args.command == "scope":
        scope()
    elif args.command == "run":
        run_group(args.group, args.destination)
    else:
        gate()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError, IndexError, ET.ParseError, subprocess.SubprocessError) as error:
        print("EPUB reading validation stopped: " + str(error), file=sys.stderr)
        sys.exit(1)

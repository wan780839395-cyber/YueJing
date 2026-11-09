"""EPUB reopen/jump release: Domain18 + Host3 + UI1 declarations, 23 executions.

No diagnostic fallback. Existing device dependency/IPA byte gates remain mandatory.
Retries use a new committed candidate/new dispatch, never overwrite failed evidence.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

import audit_native_case_events as audit
import run_epub_compat_validation as compat
import run_epub_paging_validation as paging
import run_epub_reading_validation as reading
import run_reading_ui_tests as ui
import task3_test_inventory as inventory
import validate_task3 as v
from epub_diagnostic_package import git, tree

BASE = "7888b00fe13220775d7bd53045858cda298b08b6"
SCOPE = "epub-reopen-22"
DIAGNOSTIC_SCOPE = "epub-freeze-diagnostic"  # Explicitly disabled for this baseline.
VERSION, BUILD = "0.2.6", "8"
TOTAL, EXECUTIONS = 22, 23
QUALIFICATION = "EPUB_REOPEN_22_TARGETED_NATIVE"
ROOT, OUT = v.ROOT, v.OUT
SCOPE_JSON = OUT / "epub-freeze-scope.json"
GATE_JSON = OUT / "epub-freeze-gate.json"
NATIVE_OUT = OUT / "epub-freeze"
NEW = frozenset()
ALLOWED = frozenset({
    "App/EPUB/EPUBLocationScript.swift", "App/EPUB/EPUBReaderScreen.swift",
    "App/EPUB/EPUBReaderViewModel.swift", "App/EPUB/EPUBWebView.swift",
    "Sources/ReaderDomain/EPUB/EPUBImportService.swift",
    "Sources/ReaderDomain/EPUB/EPUBPublicationCache.swift",
    "Sources/ReaderDomain/EPUB/EPUBResourceStore.swift",
    "Sources/ReaderDomain/EPUB/OpenedEPUBReader.swift", "Sources/ReaderDomain/LibraryService.swift",
    "Tests/ReaderDomainTests/EPUBLibraryTests.swift",
    "Tests/YueJingEPUBUITests/EPUBFlowUITests.swift", "Tests/YueJingHostTests/EPUBReaderHostTests.swift",
    "scripts/check_epub_continuous_script.cjs",
    ".github/workflows/task3-validate.yml", "scripts/run_epub_freeze_validation.py",
    "scripts/check_epub_freeze_validation.py", "scripts/task3_test_inventory.py",
    "scripts/validate_task3.py", "project.yml", "docs/EPUB_FREEZE_RELEASE.md",
})
SELECTED_FILES = {
    "ReaderDomainTests/EPUBLibraryTests.swift": """
        epubOriginalArchiveAndValidatedResourcesSurviveReopen
        epubWarmReopenTransfersFolderWithFreshSessionPositionAndPreferences
        epubOverlappingReadersNeverShareAnActiveWorkspace
        epubConcurrentWorkspaceTakesConsumeTheSlotOnlyOnce
        epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime
        epubWarmPackageMatchIncludesMetadataNotOnlyVersion
        epubFailedOrCancelledCloseNeverReturnsWorkspace
        epubFailureAfterWarmTakeDeletesTransferredFolderNotAnUnusedDestination
        epubCancelledWarmTakeAndImporterDeinitCleanTheirOwnSlot
        epubDuplicateKeepsProgressAndRepairsMissingArchive
        epubCancellationBeforeCommitLeavesNoBook
        epubCancellationAfterCommitReturnsReceipt
        epubFailedImportCleansOnlyItsWorkspace""".split(),
    "ReaderDomainTests/EPUBProgressTests.swift": """
        epubPositionsRejectForeignVersionsUnitsAndInvalidUTF16Boundaries
        epubProgressRequiresReadinessAndIncreasingSequence
        epubOldNavigationSupersededSessionAndClosedCallbacksCannotWrite
        epubTypographyEpochRestoresSameTextPositionAndSettings""".split(),
    "ReaderDomainTests/EPUBCompatibilityTests.swift": [
        "epubCompatibilityEPUB2DoctypeImageWebPImportProgressSurvivesReopen"],
    "YueJingHostTests/EPUBReaderHostTests.swift": [
        "epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position",
        "epubCompatibilityWebKitLoadsStaticImagePageAndRestoresAnchor",
        "epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks"],
    "YueJingEPUBUITests/EPUBFlowUITests.swift": [
        "testEPUBShelfCoverAndDirectoryCrossChapterNavigation"],
}
GROUPS = {}
for _kind, _target in (("domain", "ReaderDomainTests"), ("host", "YueJingHostTests"), ("ui", "YueJingEPUBUITests")):
    _pairs = [(rel, n) for rel, names in SELECTED_FILES.items() if rel.startswith(_target + "/") for n in names]
    # Separate Host invocations isolate launch failures without increasing 480s/180s budgets.
    for _index, _chunk in enumerate([_pairs] if _kind != "host" else [[p] for p in _pairs], 1):
        _key = _kind if _kind != "host" else "host-" + str(_index)
        GROUPS[_key] = dict(kind=_kind, target=_target, timeout=480, pairs=_chunk, cases=[n for _, n in _chunk])
del _kind, _target, _pairs, _index, _chunk, _key
require, load, write, sha = v.require, compat.load_json, compat.write_new, compat.digest_path


def selection():
    reviewed = inventory.validate_source(ROOT)
    require(reviewed["selected"] == inventory.TOTAL == 222 and reviewed["selected_executions"] == 223, "Inventory drift")
    names = []
    for rel, selected in SELECTED_FILES.items():
        actual = inventory.source_names(rel, (ROOT / "Tests" / rel).read_text(encoding="utf-8"))
        require(actual == inventory.FILES[rel].split() and set(selected) <= set(actual), "Selection/source drift")
        names.extend(selected)
    require(len(names) == len(set(names)) == TOTAL and len(GROUPS["domain"]["cases"]) == 18, "Expected Domain18/Host3/UI1")
    return {group: list(spec["cases"]) for group, spec in GROUPS.items()}


def ui_reopen_contract(text):
    # The selected case must exit and reopen WITHOUT terminating/relaunching the process.
    start = text.index("func testEPUBShelfCoverAndDirectoryCrossChapterNavigation()")
    end = text.index("func testEPUBProgressSurvivesExitAndProcessRelaunch()", start)
    case = text[start:end]
    exit_at = case.find("exitReader(app,")
    reopen_at = case.find("openEPUB(", exit_at)
    require(exit_at >= 0 and reopen_at > exit_at and not re.search(r"app\.(terminate|launch)\(", case),
            "Selected UI case lacks same-process exit/reopen coverage; do not substitute process relaunch")


def scope_receipt():
    env = os.environ
    require(env.get("VALIDATION_SCOPE") == SCOPE and env.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and env.get("GITHUB_REF") == "refs/heads/main" and env.get("GITHUB_RUN_ATTEMPT") == "1"
            and env.get("GITHUB_REPOSITORY") == "wan780839395-cyber/YueJing", "Unapproved dispatch identity; diagnostic disabled")
    head = git("rev-parse", "HEAD").decode().strip()
    require(re.fullmatch(r"[0-9a-f]{40}", head) and head == env.get("GITHUB_SHA") and head != BASE, "Candidate/source mismatch")
    require(re.fullmatch(r"[1-9][0-9]*", env.get("GITHUB_RUN_ID", "")), "Invalid run identity")
    git("merge-base", "--is-ancestor", BASE, head)
    require(not git("status", "--porcelain", "--untracked-files=no").strip(), "Tracked source drift")
    before, after = tree(BASE), tree("HEAD")
    changed = {p for p in set(before) | set(after) if before.get(p) != after.get(p)}
    require(changed == ALLOWED and set(after) == set(before), "Release changes outside exact 20-path boundary")
    require(all(after[p][:2] == ["100644", "blob"] for p in changed), "Nonregular approved source")
    old_version = b'        MARKETING_VERSION: "0.2.5"\n        CURRENT_PROJECT_VERSION: "7"\n'
    new_version = b'        MARKETING_VERSION: "0.2.6"\n        CURRENT_PROJECT_VERSION: "8"\n'
    old_project = git("show", BASE + ":project.yml")
    require(old_project.count(old_version) == 1 and (ROOT / "project.yml").read_bytes() ==
            old_project.replace(old_version, new_version, 1), "Only approved version lines may change")
    ui_reopen_contract((ROOT / "Tests/YueJingEPUBUITests/EPUBFlowUITests.swift").read_text(encoding="utf-8"))
    return dict(scope=SCOPE, source_commit=head, baseline_commit=BASE,
                run_id=env["GITHUB_RUN_ID"], run_attempt="1", version=VERSION, build=BUILD,
                changed_paths=sorted(changed), selected=selection(), selected_declarations=TOTAL,
                native_tests_planned=EXECUTIONS, full_inventory_declared=222, full_inventory_executions=223,
                files=v.candidate_files(), approved_files={p: sha(ROOT / p) for p in sorted(ALLOWED)},
                physical_acceptance="not performed", full_regression_passed=False)


def live_scope():
    receipt = scope_receipt()
    require(load(SCOPE_JSON) == receipt, "Frozen scope/source/run drift")
    v.check_candidate()
    return receipt


def command(group, destination, result_bundle):
    require(group in GROUPS and re.fullmatch(r"platform=iOS Simulator,id=[0-9a-fA-F-]{36}", destination), "Expected simulator UUID/group")
    spec = GROUPS[group]
    kind = spec["kind"]
    only = ["-only-testing:" + rel.removesuffix(".swift") + "/" + name +
            ("" if kind == "ui" else inventory.PARAMETERIZED.get(name, {}).get("signature", "()"))
            for rel, name in spec["pairs"]]
    return ["xcodebuild", "test", "-project", "YueJing.xcodeproj", "-scheme", "ReaderDomain" if kind == "domain" else "YueJingUI",
            "-configuration", "Debug", *(["-sdk", "iphonesimulator"] if kind == "domain" else []),
            "-destination", destination, *only,
            "-parallel-testing-enabled", "NO", "-clonedSourcePackagesDirPath", "build/SourcePackages",
            "-disableAutomaticPackageResolution", "-skipPackageUpdates", "-onlyUsePackageVersionsFromResolvedFile",
            "-derivedDataPath", "build/ReadingUIDerivedData", "-resultBundlePath", str(result_bundle),
            "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "180",
            "-maximum-test-execution-time-allowance", "180", "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64"]


def parse_log(group, raw, code, timed_out):
    require(type(code) is int and code == 0 and timed_out is False, "Native failure/timeout")
    require(isinstance(raw, bytes) and raw, "Missing native log")
    names, kind = GROUPS[group]["cases"], GROUPS[group]["kind"]
    text, arguments = inventory.parameter_events(raw.decode("utf-8"), names)
    events = audit.parse_events(text.encode("utf-8"), names, ui=kind == "ui", ui_class="EPUBFlowUITests")
    # Signature-only adapter is explicit; line numbers and argument rows refer to ORIGINAL raw bytes.
    events["raw_sha256"] = compat.digest_bytes(raw)
    events["signature_adapter"] = sorted(arguments)
    for case in events["cases"]:
        for key in ("starts", "finishes", "skips", "issues"):
            for row in case[key]:
                if "text" in row:
                    row["text"] = raw.decode("utf-8").splitlines()[row["line"] - 1]
    require(events["parser_complete"] and not events["unexpected"] and not events["unknown_test_lines"], "Impure/incomplete events")
    require(events["totals"] == dict(passed=len(names), failed=0, skipped=0, unexecuted=0, unfinished=0, ambiguous=0), "Native case totals differ")
    for case in events["cases"]:
        require(case["status"] == "passed" and len(case["starts"]) == len(case["finishes"]) == 1
                and case["starts"][0]["line"] < case["finishes"][0]["line"]
                and not case["skips"] and not case["issues"], "Invalid case event chain")
    require("** TEST SUCCEEDED **" in text and "** TEST FAILED **" not in text, "Native success marker missing")
    require(not re.search(r"^.*\b(?:Test|Suite)[^\r\n]*\b(?:skipped|failed)\b", text, re.MULTILINE), "Failure takes precedence")
    summaries = re.findall(r"Test run with (\d+) tests?\b[^\r\n]*?\b(passed|failed)\b", text)
    if kind != "ui":
        require("Test Case '-[" not in text and summaries == [(str(len(names)), "passed")], "Swift declaration summary differs")
        finishes = re.findall(r"\bTest (\w+)\(\) passed after ([0-9.]+) seconds?", text)
    else:
        other = audit.parse_events(raw, [], ui=False)
        ui_lines = {row["line"] for case in events["cases"] for key in ("starts", "finishes") for row in case[key]}
        require(not other["unexpected"] and not other["derived_starts"]
                and all(row["line"] in ui_lines for row in other["unknown_test_lines"]), "Unexpected Swift tests in UI group")
        require(summaries in ([], [("0", "passed")]), "Unexpected Swift summary in UI group")
        finishes = re.findall(r"Test Case '-\[(?:\w+\.)?EPUBFlowUITests (test\w+)\]' passed \(([0-9.]+) seconds?\)", text)
        xc = re.findall(r"Executed (\d+) tests?, (?:(\d+) tests? skipped and )?(?:with )?(\d+) failures? \((\d+) unexpected\)", text)
        require(xc and all(n == "1" and skip in ("", "0") and failed == unexpected == "0" for n, skip, failed, unexpected in xc), "UI summary differs")
    require(sorted(n for n, _ in finishes) == sorted(names) and all(float(t) <= 180 for _, t in finishes), "Case identity/duration differs")
    return dict(group=group, passed=list(names), declarations_passed=len(names),
                executions=len(names) + sum(len(rows) - 1 for rows in arguments.values()),
                parameter_events=arguments, native_exit=0, timed_out=False,
                log_sha256=compat.digest_bytes(raw), events=events)


def parameter_result(document):
    """Xcode16 test-results/tests: require both real Bool argument leaves, not parent-only green."""
    name = next(iter(inventory.PARAMETERIZED))
    found = []
    def visit(node, inside=False):
        require(isinstance(node, dict), "Malformed xcresult test node")
        signature = name + inventory.PARAMETERIZED[name]["signature"]
        labels = [str(node.get(key, "")) for key in ("nodeIdentifier", "name")]
        inside = inside or any(label == signature or label.endswith("/" + signature) for label in labels)
        if inside:
            require(node.get("result") == "Passed", "Failed/skipped parameter ancestor")
        children = node.get("children", [])
        require(isinstance(children, list), "Malformed xcresult children")
        if inside and not children:
            values = re.findall(r"\b(false|true)\b", str(node.get("name", "")))
            require(len(values) == 1 and node.get("result") == "Passed", "Missing/failed/skipped parameter result")
            found.append(values[0])
        for child in children:
            visit(child, inside)
    require(isinstance(document, dict) and isinstance(document.get("testNodes"), list), "Missing xcresult test tree")
    for node in document["testNodes"]:
        visit(node)
    require(sorted(found) == ["false", "true"], "Expected exactly two successful Bool argument results")
    return dict(name=name, passed_arguments=sorted(found))


def parameter_evidence(group, folder, bundle, *, export=False):
    if group != "domain":
        return None
    path = folder / "xcresult-tests.json"
    if export:
        require(not path.exists(), "Existing xcresult export")
        raw = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)], timeout=60)
        path.write_bytes(raw)
    require(path.is_file() and not path.is_symlink(), "Missing regular xcresult export")
    raw = path.read_bytes()
    # On release recheck the exported tree against the SAME bundle, not a forgeable JSON alone.
    if not export:
        live = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)], timeout=60)
        require(json.loads(live) == json.loads(raw), "xcresult argument export drift")
    return dict(**parameter_result(json.loads(raw)), raw_sha256=compat.digest_bytes(raw))


def provenance(group, destination, bundle, scope):
    return dict(scope=SCOPE, source_commit=scope["source_commit"], run_id=scope["run_id"], run_attempt="1",
                group=group, target=GROUPS[group]["target"], destination=destination,
                expected_cases=GROUPS[group]["cases"], command=command(group, destination, bundle),
                timeout_seconds=GROUPS[group]["timeout"], case_timeout_seconds=180)


def run_group(group, destination):
    scope = live_scope()
    compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=True)
    compat.validate_destination(destination, OUT)
    folder = NATIVE_OUT / group
    require(not folder.exists(), "Existing group evidence; use a fresh dispatch")
    folder.mkdir(parents=True)
    target, kind = GROUPS[group]["target"], GROUPS[group]["kind"]
    bundle = folder / (target + ".xcresult")
    want = provenance(group, destination, bundle, scope)
    write(folder / "selection.json", want)
    reading.prepare_group_settings(kind, folder, scope["source_commit"], root=ROOT, out=OUT)
    log = folder / (target + ".log")
    code, timed_out = ui.stream_native(want["command"], log, GROUPS[group]["timeout"])
    write(folder / "execution.json", dict(**want, native_exit=code, timed_out=timed_out))
    parsed = parse_log(group, log.read_bytes(), code, timed_out)
    paging.require_xcresult(bundle)
    parsed["parameter_xcresult"] = parameter_evidence(group, folder, bundle, export=True)
    require(live_scope() == scope, "Source changed during native execution")
    write(folder / "counts.json", parsed)
    print(json.dumps(parsed, indent=2))


def qualification():
    scope = live_scope()
    require(scope["scope"] == SCOPE, "Diagnostic fallback disabled")
    require(not (OUT / "native-test-gate.json").exists() and not (OUT / "epub-reading-gate.json").exists(), "Mixed qualification")
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
        reading.validate_group_settings(spec["kind"], folder, scope["source_commit"], root=ROOT, out=OUT)
        log = folder / (spec["target"] + ".log")
        require(log.is_file() and not log.is_symlink(), "Missing regular native log")
        parsed = parse_log(group, log.read_bytes(), execution["native_exit"], execution["timed_out"])
        parsed["parameter_xcresult"] = parameter_evidence(group, folder, bundle)
        require(load(folder / "counts.json") == parsed, "Raw events differ from saved counts")
        groups.append(parsed)
    require(sum(g["declarations_passed"] for g in groups) == TOTAL and sum(g["executions"] for g in groups) == EXECUTIONS, "Combined execution count differs")
    return dict(**scope, qualification=QUALIFICATION, coverage="EPUB_TARGETED_NOT_FULL",
                native_tests_executed_this_run=EXECUTIONS, verified_passed=EXECUTIONS,
                verified_declarations=TOTAL, not_executed_this_run=223-EXECUTIONS,
                groups=groups, simulator=sim)


def validate_saved():
    actual = qualification()
    require(load(GATE_JSON) == actual, "Qualification receipt drift")
    return actual


def release_gate():
    result = validate_saved()
    require(result.get("scope") == SCOPE and result.get("qualification") == QUALIFICATION
            and result.get("verified_passed") == result.get("native_tests_executed_this_run") == EXECUTIONS
            and result.get("verified_declarations") == TOTAL
            and result.get("version") == VERSION and result.get("build") == BUILD
            and result.get("full_regression_passed") is False, "Formal release requires all selected native passes")
    return result


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
        raise SystemExit("EPUB reopen release stopped: " + str(error))

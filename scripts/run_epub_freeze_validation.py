"""Recent EPUB lifecycle validation: Domain14 + Host3 + UI3, 21 executions.

Run the full selected batch before any product repair. Device packaging is explicitly staged.
Strict qualification remains separate from explicitly labelled diagnostic delivery.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import signal

import audit_native_case_events as audit
import run_epub_compat_validation as compat
import run_epub_paging_validation as paging
import run_epub_reading_validation as reading
import run_reading_ui_tests as ui
import task3_test_inventory as inventory
import validate_task3 as v
from epub_diagnostic_package import git, tree

BASE = "eee357c1bce90cd576657b1610116e55b75c1b92"
SCOPE = "epub-recent-20"
RETEST_SCOPE = "epub-recent-host-ui-6"
RETEST_BASE = "0cf3849908f9e142733a378848ae70a6bc9366b7"
RETEST_ALLOWED = frozenset({"Tests/YueJingHostTests/EPUBReaderHostTests.swift",
    ".github/workflows/task3-validate.yml", "scripts/run_epub_freeze_validation.py",
    "scripts/check_epub_freeze_validation.py", "docs/EPUB_FREEZE_RELEASE.md"})
DIAGNOSTIC_SCOPE = "epub-freeze-diagnostic"  # Explicitly disabled for this baseline.
VERSION, BUILD = "0.2.9", "11"
TOTAL, EXECUTIONS = 20, 21
QUALIFICATION = "EPUB_RECENT_20_TARGETED_NATIVE"
ROOT, OUT = v.ROOT, v.OUT
SCOPE_JSON = OUT / "epub-freeze-scope.json"
GATE_JSON = OUT / "epub-freeze-gate.json"
PACKAGE_JSON = OUT / "epub-freeze-package.json"
NATIVE_OUT = OUT / "epub-freeze"
NEW = frozenset({"App/EPUB/EPUBWarmRendererCache.swift", "App/EPUB/EPUBParkReply.swift",
                 "Sources/ReaderDomain/EPUB/EPUBContentPool.swift", "Tests/ReaderDomainTests/EPUBContentPoolTests.swift"})
ALLOWED = frozenset({
    "App/EPUB/EPUBLocationScript.swift", "App/EPUB/EPUBReaderViewModel.swift",
    "App/EPUB/EPUBWebView.swift", "App/EPUB/EPUBWarmRendererCache.swift", "App/EPUB/EPUBParkReply.swift",
    "App/Library/BookReadingRouteOwner.swift", "Sources/ReaderDomain/EPUB/EPUBContentPool.swift",
    "Sources/ReaderDomain/EPUB/OpenedEPUBReader.swift", "Sources/ReaderDomain/EPUB/EPUBOpeningTimings.swift",
    "Sources/ReaderDomain/LibraryService.swift", "Sources/ReaderDomain/LibraryStore.swift",
    "Tests/ReaderDomainTests/EPUBLibraryTests.swift", "Tests/ReaderDomainTests/EPUBContentPoolTests.swift",
    "Tests/YueJingHostTests/EPUBReaderHostTests.swift", "scripts/check_epub_continuous_script.cjs",
    ".github/workflows/task3-validate.yml", "scripts/run_epub_freeze_validation.py",
    "scripts/check_epub_freeze_validation.py", "scripts/task3_test_inventory.py",
    "project.yml", "docs/EPUB_FREEZE_RELEASE.md",
})
SELECTED_FILES = {
    "ReaderDomainTests/EPUBLibraryTests.swift": """
        epubOriginalArchiveAndValidatedResourcesSurviveReopen
        epubWarmReopenTransfersFolderWithFreshSessionPositionAndPreferences
        epubOverlappingReadersUseIndependentLeasesAndSessions
        epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime
        epubFailedOrCancelledCloseNeverReturnsWorkspace
        epubFailureAfterWarmTakeDeletesTransferredFolderNotAnUnusedDestination
        epubFailedImportCleansOnlyItsWorkspace
        epubBooksAndTXTStayIsolated""".split(),
    "ReaderDomainTests/EPUBContentPoolTests.swift": """
        recentBooksReuseIndependentVersionsWithoutCopying
        contentLeaseEvictionWaitsForEveryHolderAndRejectsReleasedTokens
        diskContentSurvivesPoolRecreationAndCancellationPublishesNothing
        corruptedLeasedVersionIsNotDeletedUntilOldRendererReleasesIt
        invalidPeerReceiptDoesNotBlockOtherBooks
        unavailableOptionalCacheFallsBackToTemporaryLeasedContent""".split(),
    "YueJingHostTests/EPUBReaderHostTests.swift": [
        "epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position",
        "epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks",
        "epubRecentBooksReusePagesAcrossSwitchesAndEvictOnlyIdleLRU"],
    "YueJingEPUBUITests/EPUBFlowUITests.swift": [
        "testEPUBShelfCoverAndDirectoryCrossChapterNavigation",
        "testEPUBProgressSurvivesExitAndProcessRelaunch",
        "testEPUBTypographyNoCoverFallbackAndTXTIsolation"],
}
GROUPS = {}
for _kind, _target in (("domain", "ReaderDomainTests"), ("host", "YueJingHostTests"), ("ui", "YueJingEPUBUITests")):
    _pairs = [(rel, n) for rel, names in SELECTED_FILES.items() if rel.startswith(_target + "/") for n in names]
    # Every declaration gets independent evidence/process admission. A failed case
    # must not consume the remaining cases' opportunity to execute.
    for _index, _chunk in enumerate([[p] for p in _pairs], 1):
        _key = _kind + "-" + str(_index)
        GROUPS[_key] = dict(kind=_kind, target=_target, timeout=480, pairs=_chunk, cases=[n for _, n in _chunk])
del _kind, _target, _pairs, _index, _chunk, _key

# A test-helper-only repair cannot invalidate the independent Domain target.
# This scope reports only its own six executions; prior Domain evidence is separate.
if os.environ.get("VALIDATION_SCOPE") == RETEST_SCOPE:
    SCOPE, TOTAL, EXECUTIONS = RETEST_SCOPE, 6, 6
    QUALIFICATION = "EPUB_RECENT_HOST_UI_6_TARGETED_NATIVE"
    SELECTED_FILES = {p: n for p, n in SELECTED_FILES.items() if not p.startswith("ReaderDomainTests/")}
    GROUPS = {g: s for g, s in GROUPS.items() if s["kind"] != "domain"}
require, load, write, sha = v.require, compat.load_json, compat.write_new, compat.digest_path


def selection():
    reviewed = inventory.validate_source(ROOT)
    require(reviewed["selected"] == inventory.TOTAL == 229 and reviewed["selected_executions"] == 230, "Inventory drift")
    names = []
    for rel, selected in SELECTED_FILES.items():
        actual = inventory.source_names(rel, (ROOT / "Tests" / rel).read_text(encoding="utf-8"))
        require(actual == inventory.FILES[rel].split() and set(selected) <= set(actual), "Selection/source drift")
        names.extend(selected)
    require(len(names) == len(set(names)) == TOTAL and
            sum(g["kind"] == "domain" for g in GROUPS.values()) == (0 if SCOPE == RETEST_SCOPE else 14) and
            SELECTED_FILES["YueJingEPUBUITests/EPUBFlowUITests.swift"] ==
            inventory.FILES["YueJingEPUBUITests/EPUBFlowUITests.swift"].split(), "Expected selected Domain/Host3/all EPUB UI3")
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


def dispatch_permission():
    """Bind the job environment to the original workflow_dispatch payload."""
    event = load(Path(os.environ["GITHUB_EVENT_PATH"]))
    inputs = event.get("inputs", {})
    value = inputs.get("allow_unqualified_ipa", False)
    require(type(value) is bool or value in ("true", "false"), "Invalid diagnostic permission")
    allowed = value is True or value == "true"
    require(inputs.get("validation_scope") == SCOPE and
            os.environ.get("ALLOW_UNQUALIFIED_IPA") == ("true" if allowed else "false"),
            "Dispatch permission/scope differs from environment")
    build = inputs.get("build_ipa", False)
    require(type(build) is bool or build in ("true", "false"), "Invalid build phase")
    requested = build is True or build == "true"
    require(os.environ.get("BUILD_IPA") == ("true" if requested else "false"), "Build phase differs from dispatch")
    return allowed


def scope_receipt():
    env = os.environ
    require(env.get("VALIDATION_SCOPE") == SCOPE and env.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and env.get("GITHUB_REF") == "refs/heads/main" and env.get("GITHUB_RUN_ATTEMPT") == "1"
            and env.get("GITHUB_REPOSITORY") == "wan780839395-cyber/YueJing", "Unapproved dispatch identity")
    head = git("rev-parse", "HEAD").decode().strip()
    require(re.fullmatch(r"[0-9a-f]{40}", head) and head == env.get("GITHUB_SHA") and head != BASE, "Candidate/source mismatch")
    require(re.fullmatch(r"[1-9][0-9]*", env.get("GITHUB_RUN_ID", "")), "Invalid run identity")
    git("merge-base", "--is-ancestor", BASE, head)
    require(not git("status", "--porcelain", "--untracked-files=no").strip(), "Tracked source drift")
    before, after = tree(BASE), tree("HEAD")
    changed = {p for p in set(before) | set(after) if before.get(p) != after.get(p)}
    require(changed == ALLOWED and set(after) - set(before) == NEW and not set(before) - set(after),
            "Release changes outside exact 21-path boundary / four approved additions")
    require(all(after[p][:2] == ["100644", "blob"] for p in changed), "Nonregular approved source")
    if SCOPE == RETEST_SCOPE:
        git("merge-base", "--is-ancestor", RETEST_BASE, head)
        initial = tree(RETEST_BASE)
        repair_changed = {p for p in set(initial) | set(after) if initial.get(p) != after.get(p)}
        require(repair_changed == RETEST_ALLOWED and set(initial) == set(after),
                "Host/UI-only retest requires unchanged product, Domain sources, dependencies and build settings")
    old_version = b'        MARKETING_VERSION: "0.2.8"\n        CURRENT_PROJECT_VERSION: "10"\n'
    new_version = b'        MARKETING_VERSION: "0.2.9"\n        CURRENT_PROJECT_VERSION: "11"\n'
    old_project = git("show", BASE + ":project.yml")
    require(old_project.count(old_version) == 1 and (ROOT / "project.yml").read_bytes() ==
            old_project.replace(old_version, new_version, 1), "Only approved version lines may change")
    ui_reopen_contract((ROOT / "Tests/YueJingEPUBUITests/EPUBFlowUITests.swift").read_text(encoding="utf-8"))
    return dict(scope=SCOPE, source_commit=head, baseline_commit=BASE,
                run_id=env["GITHUB_RUN_ID"], run_attempt="1", version=VERSION, build=BUILD,
                allow_unqualified_ipa=dispatch_permission(), dispatch_event_sha256=sha(Path(env["GITHUB_EVENT_PATH"])),
                build_ipa=os.environ.get("BUILD_IPA") == "true",
                changed_paths=sorted(changed), selected=selection(), selected_declarations=TOTAL,
                native_tests_planned=EXECUTIONS, full_inventory_declared=229, full_inventory_executions=230,
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
    if not any(name in inventory.PARAMETERIZED for name in GROUPS[group]["cases"]):
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
def stream_case(args, path, timeout_seconds):
    """Write raw output directly: a child keeping a PIPE open cannot hang the scheduler."""
    timed_out = False
    with path.open("x", encoding="utf-8") as stream:
        process = subprocess.Popen(args, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=os.name == "posix")
        def stop():
            try:
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGKILL)
                elif process.poll() is None:
                    process.kill()
            except ProcessLookupError:
                pass
        try:
            try:
                code = process.wait(timeout=timeout_seconds)
            except subprocess.TimeoutExpired:
                timed_out = True
                stop()
                code = process.wait(timeout=10)
        finally:
            # Also clean descendants left behind by a failed/cancelled command.
            stop()
            process.wait(timeout=10)
    return code, timed_out




def run_group(group, destination, *, checked_scope=None):
    scope = checked_scope if checked_scope is not None else live_scope()
    if checked_scope is None:
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
    code, timed_out = stream_case(want["command"], log, GROUPS[group]["timeout"])
    write(folder / "execution.json", dict(**want, native_exit=code, timed_out=timed_out))
    parsed = parse_log(group, log.read_bytes(), code, timed_out)
    paging.require_xcresult(bundle)
    parsed["parameter_xcresult"] = parameter_evidence(group, folder, bundle, export=True)
    require(live_scope() == scope, "Source changed during native execution")
    write(folder / "counts.json", parsed)
    print(json.dumps(parsed, indent=2))


def run_all(destination):
    """Continue independent cases, never convert failed evidence into release success."""
    require(not NATIVE_OUT.exists(), "Existing native evidence; do not retry/overwrite cases")
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        scope = live_scope()
        # Common prerequisites are checked once. A broken environment is not nine
        # independent test failures, and must not trigger nine repeated tool probes.
        compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=True)
        compat.validate_destination(destination, OUT)
        NATIVE_OUT.mkdir()
        summarize()
        for group in GROUPS:
            require(live_scope() == scope, "Source/run changed during case scheduling")
            try:
                print("Running " + group + ": " + GROUPS[group]["cases"][0], flush=True)
                run_group(group, destination, checked_scope=scope)
            except Exception as error:
                # Includes preparation, compilation, assertion, timeout and evidence
                # failures. Cancellation/SystemExit are NOT swallowed.
                folder = NATIVE_OUT / group
                folder.mkdir(exist_ok=True)
                write(folder / "failure.json", dict(group=group, error_type=type(error).__name__,
                      error=str(error), source_commit=scope["source_commit"], run_id=scope["run_id"]))
            finally:
                summarize()
        result = summarize()
        return all(row["status"] == "passed" for row in result["cases"])
    except Exception as error:
        write(OUT / "case-scheduling-error.json", dict(error_type=type(error).__name__, error=str(error)))
        raise
    finally:
        summarize()


def summarize(*, publish=False):
    """Diagnostic display only; qualification() independently revalidates every case."""
    def optional(path):
        if not path.exists():
            return None
        require(path.is_file() and not path.is_symlink(), "Invalid report evidence path")
        return load(path)

    rows = []
    for group, spec in GROUPS.items():
        folder = NATIVE_OUT / group
        case = spec["cases"][0]
        row = dict(group=group, target=spec["target"], case=case, kind=spec["kind"],
                   planned_executions=len(inventory.PARAMETERIZED.get(case, {}).get("values", [None])),
                   status="not_run", reason="尚未开始；检查前置准备、调度或取消状态")
        try:
            execution = optional(folder / "execution.json")
            failure = optional(folder / "failure.json")
            counts = optional(folder / "counts.json")
            if failure is not None:
                row.update(status="error", reason=failure["error"])
            if execution is not None:
                row.update(native_exit=execution["native_exit"], timed_out=execution["timed_out"])
                if execution["timed_out"]:
                    row.update(status="timed_out", reason="执行超时，未放宽预算；继续下一项")
                elif execution["native_exit"] != 0:
                    row.update(status="failed", reason="原生命令失败；查看该项日志（含编译/断言失败）")
                elif counts is not None and failure is None:
                    parsed = parse_log(group, (folder / (spec["target"] + ".log")).read_bytes(), 0, False)
                    parsed["parameter_xcresult"] = None
                    if case in inventory.PARAMETERIZED:
                        raw = (folder / "xcresult-tests.json").read_bytes()
                        parsed["parameter_xcresult"] = dict(**parameter_result(json.loads(raw)),
                                                            raw_sha256=compat.digest_bytes(raw))
                    require(counts == parsed, "Summary counts differ from raw events")
                    row.update(status="passed", reason="原始事件与通过回执一致；正式资格另行核验")
                elif failure is None:
                    row.update(status="error", reason="执行已结束但缺少合格结果回执")
            elif failure is not None:
                row.update(status="blocked", reason=failure["error"])
        except (ValueError, OSError, KeyError, TypeError) as error:
            row.update(status="error", reason="结果证据无效：" + str(error))
        rows.append(row)

    scheduling = optional(OUT / "case-scheduling-error.json")
    if scheduling:
        for row in rows:
            if row["status"] == "not_run":
                row.update(status="blocked", reason=scheduling["error"])
    selected_ui = {row["case"]: row for row in rows if row["kind"] == "ui"}
    ui_rows = []
    for target in ("YueJingEPUBUITests", "YueJingUITests"):
        for case in inventory.expected_names(target):
            ui_rows.append(selected_ui.get(case, dict(target=target, case=case, status="not_selected",
                reason="本轮未选择：独立 TXT/通用阅读 UI 范围，未执行、不计通过")))
    counts = {status: sum(row["status"] == status for row in rows)
              for status in ("passed", "failed", "timed_out", "error", "blocked", "not_run")}
    report = dict(scope=SCOPE, source_commit=os.environ.get("GITHUB_SHA"), run_id=os.environ.get("GITHUB_RUN_ID"),
                  selected_declarations=TOTAL, planned_executions=EXECUTIONS, counts=counts,
                  cases=rows, ui_inventory=ui_rows, scheduling_error=scheduling,
                  qualification="DISPLAY_ONLY_NOT_RELEASE_QUALIFICATION")
    def cell(value):
        return str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("|", "&#124;").replace("\n", " ").replace("\r", " ")
    labels = dict(passed="通过", failed="失败", timed_out="超时", error="证据/执行错误", blocked="阻塞", not_run="未执行", not_selected="未选择")
    lines = ["## EPUB 定向测试逐项结果", "", f"计划：{TOTAL} 个测试身份 / {EXECUTIONS} 次执行；失败不终止后续用例。",
             "汇总仅用于展示，存在失败/超时/阻塞/未执行时不得获得正式 IPA 资格。", "",
             "| 项目 | 状态 | 说明 |", "|---|---|---|"]
    for row in rows:
        lines.append(f"| {cell(row['group'] + ': ' + row['case'])} | {labels[row['status']]} | {cell(row['reason'])} |")
    lines += ["", "### 完整 UI 清单（含未选择项目）", "", "| Target / 用例 | 状态 | 说明 |", "|---|---|---|"]
    for row in ui_rows:
        lines.append(f"| {cell(row['target'] + '/' + row['case'])} | {labels[row['status']]} | {cell(row['reason'])} |")
    if scheduling:
        lines += ["", "公共调度阻塞：" + cell(scheduling["error"])]
    markdown = "\n".join(lines) + "\n"
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "case-results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    (OUT / "case-results.md").write_text(markdown, encoding="utf-8")
    if publish and os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as file:
            file.write(markdown)
    return report


def qualification():
    scope = live_scope()
    require(scope["scope"] == SCOPE, "Diagnostic fallback disabled")
    require(not (OUT / "case-scheduling-error.json").exists() and
            not any((NATIVE_OUT / group / "failure.json").exists() for group in GROUPS),
            "Failed/blocked cases cannot qualify even if a counts receipt exists")
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
                verified_declarations=TOTAL, not_executed_this_run=230-EXECUTIONS,
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


def validate_linkage(kind, scope):
    folder = OUT / ("webkit-" + kind + "-linkage")
    record = load(folder / "verification.json")
    require(all(record.get(key) == scope[key] for key in ("source_commit", "run_id", "run_attempt")) and
            record.get("passed") is True and not record.get("errors") and record.get("binaries"),
            "Missing same-run successful " + kind + " WebKit linkage")
    app = v.APP if kind == "device" else ROOT / "build/ReadingUIDerivedData/Build/Products/Debug-iphonesimulator/YueJing.app"
    for binary in record["binaries"]:
        path = app / binary["path"]
        evidence = folder / binary["evidence"]
        require(path.resolve().is_relative_to(app.resolve()) and evidence.resolve().is_relative_to(folder.resolve())
                and binary.get("passed") is True and binary.get("nm_exit") == 0
                and sha(path) == sha(evidence) == binary["sha256"], "WebKit binary evidence drift")
    return sha(folder / "verification.json")


def delivery_gate():
    """Admission only, not IPA success. Source/common prerequisites never fall back."""
    scope = live_scope()
    require(scope.get("build_ipa") is True, "Validation-only phase cannot package an IPA")
    compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=False)
    require((OUT / "app-build-exit-code.txt").read_text().strip() == "0", "Device App build did not pass")
    device_linkage = validate_linkage("device", scope)
    try:
        native = release_gate()
        validate_linkage("simulator", scope)
        reason = None
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        require(scope.get("allow_unqualified_ipa") is True, "Native qualification failed; explicit diagnostic permission required")
        native, reason = None, str(error)
    # Recheck outside the fallback: a source/run mutation can never be downgraded.
    require(live_scope() == scope, "Source/run changed during qualification")
    report = summarize()
    evidence = {}
    rows = []
    for row in report["cases"]:
        row = dict(row)
        folder = NATIVE_OUT / row["group"]
        if folder.exists():
            require(not folder.is_symlink(), "Symlink native evidence")
            for path in sorted(folder.rglob("*")):
                require(not path.is_symlink(), "Symlink native evidence")
                if path.is_file():
                    evidence[path.relative_to(OUT).as_posix()] = sha(path)
        # Only strict raw success chains supply exact expansion counts. Failed or
        # interrupted commands may have executed some tests: unknown is NOT zero.
        executed = None
        try:
            spec = GROUPS[row["group"]]
            bundle = folder / (spec["target"] + ".xcresult")
            execution = load(folder / "execution.json")
            want = provenance(row["group"], execution["destination"], bundle, scope)
            require(execution == dict(**want, native_exit=0, timed_out=False) and
                    load(folder / "selection.json") == want, "Unbound case evidence")
            parsed = parse_log(row["group"], (folder / (spec["target"] + ".log")).read_bytes(),
                               execution["native_exit"], execution["timed_out"])
            executed = parsed["executions"]
        except (ValueError, OSError, KeyError, TypeError):
            pass
        row["executed_count"] = executed
        row["execution_count_status"] = "known" if executed is not None else "unknown"
        rows.append(row)
    known = sum(row["executed_count"] or 0 for row in rows)
    unknown = [row["group"] for row in rows if row["executed_count"] is None]
    for name in ("toolchain.log", "xcodegen.log", "dependency-resolution.json", "app-build.log",
                 "app-build-exit-code.txt", "epub-freeze-scope.json"):
        path = OUT / name
        require(path.is_file() and not path.is_symlink(), "Missing common evidence: " + name)
        evidence[name] = sha(path)
    for name in ("simulator-selection.json", "simulator-boot.json", "case-scheduling-error.json",
                 "epub-freeze-gate.json", "case-results.json"):
        path = OUT / name
        if path.exists():
            require(path.is_file() and not path.is_symlink(), "Invalid supporting evidence: " + name)
            evidence[name] = sha(path)
    require(live_scope() == scope, "Source/run changed while collecting package evidence")
    return dict(**scope, qualification=QUALIFICATION if native else "DEVICE_DIAGNOSTIC_ONLY",
                coverage="EPUB_TARGETED_NOT_FULL" if native else "UI_NOT_QUALIFIED",
                strict_native_qualification="passed" if native else "failed",
                diagnostic_reason=reason, verified_passed=EXECUTIONS if native else None,
                native_tests_executed_this_run=EXECUTIONS if native else (None if unknown else known),
                known_executions=known, unknown_execution_groups=unknown, cases=rows,
                case_results_qualification=report["qualification"], evidence_sha256=evidence,
                device_linkage_sha256=device_linkage)


def complete_delivery(manifest, packaged_files):
    """Called ONLY after device gates and every IPA byte have passed."""
    result = delivery_gate()
    dependency = load(OUT / "app-dependency-gate.json")
    require(all(dependency.get(key) == result[key] for key in ("source_commit", "run_id", "run_attempt")) and dependency["signing"] == "unsigned",
            "Device dependency receipt identity differs")
    require(dependency["actual_images"], "Missing device image evidence")
    for image in dependency["actual_images"]:
        path = v.APP / image["binary"]
        require(path.resolve().is_relative_to(v.APP.resolve()) and sha(path) == image["sha256"], "Device image drift")
    result.update(ipa_integrity="passed", ipa_sha256=manifest["ipa_sha256"],
                  verified_packaged_files=packaged_files, device_dependency_sha256=sha(OUT / "app-dependency-gate.json"))
    require(manifest["source_commit"] == result["source_commit"] and manifest["version"] == VERSION and
            manifest["build"] == BUILD, "IPA/source/version differs from delivery scope")
    write(PACKAGE_JSON, result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("scope")
    run = sub.add_parser("run")
    run.add_argument("group", choices=GROUPS)
    run.add_argument("--destination", required=True)
    all_cases = sub.add_parser("run-all")
    all_cases.add_argument("--destination", required=True)
    sub.add_parser("report")
    sub.add_parser("gate")
    args = parser.parse_args()
    if args.action == "scope":
        v.freeze_candidate()
        write(SCOPE_JSON, scope_receipt())
    elif args.action == "run":
        run_group(args.group, args.destination)
    elif args.action == "run-all":
        require(run_all(args.destination), "Selected tests failed; remaining cases attempted, see case-results.json")
    elif args.action == "report":
        summarize(publish=True)
    else:
        result = qualification()
        write(GATE_JSON, result)
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        raise SystemExit("EPUB reopen release stopped: " + str(error))

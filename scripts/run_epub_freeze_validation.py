"""Host-only validation: new Host1 + original historical35 + pinned Round-2 UI1.

Delivery executes no tests and reuses all 37 expansions / 36 identities only
through a successful same-source initial validation artifact. No diagnostic IPA.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import zipfile

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import audit_native_case_events as audit
import reuse_native_evidence as rne
import run_epub_compat_validation as compat
import run_epub_paging_validation as paging
import run_epub_reading_validation as reading
import run_reading_ui_tests as ui
import task3_test_inventory as inventory
import validate_task3 as v
from epub_diagnostic_package import git, tree

BASE = "1bf00449884f5fadf9d973a8d63220f9787b459d"
SCOPE = "epub-ready-host-followup-1"
DIAGNOSTIC_SCOPE = "epub-freeze-diagnostic"  # Explicitly disabled for this baseline.
VERSION, BUILD = "0.2.14", "16"
TOTAL, EXECUTIONS = 1, 1
REUSED_DECLARATIONS, REUSED_EXECUTIONS = 34, 35
COMBINED_TOTAL, COMBINED_EXECUTIONS = 36, 37
ALL_REUSED_DECLARATIONS, ALL_REUSED_EXECUTIONS = 35, 36
UI_BASE = "3ed4da9eac1ce59452c35c8412a66827d6b4295e"
UI_RUN = 42974144689
UI_SCOPE = "epub-ready-followup-2"
UI_ARTIFACT_ID = 13834739136
UI_ARTIFACT_NAME = f"task3-evidence-{UI_RUN}-{UI_BASE}"
UI_ARCHIVE_BYTES = 79471216
UI_ARCHIVE_SHA256 = "2f3904851b9a8aa3d7cb59e5f74da8840090a2738a3346a2c7c84d98bf407062"
# Canonical manifest of all 1276 files in that exact authenticated archive.
UI_MEMBERS_SHA256 = "4144d75e2a35f736324c7ca1b025905bd42e35586ceda2c0e80cc2662585350e"
REPO = "wan780839395-cyber/YueJing"
WORKFLOW_ID = 398234793
WORKFLOW_PATH = ".github/workflows/task3-validate.yml"

HIST_RUN = 42954931349
HIST_ATTEMPT = "1"
HIST_SCOPE = "epub-ready-open-36"
HIST_ARTIFACT_ID = 13827937675
HIST_ARTIFACT_NAME = f"task3-evidence-{HIST_RUN}-{BASE}"
HIST_ARCHIVE_BYTES = 144646562
HIST_ARCHIVE_SHA256 = "06e994b0152d56b3cb5024e8f4f694b90bd917dab672f2fd6074463d51dbf883"

VALIDATION_QUALIFICATION = "EPUB_READY_HOST_FOLLOWUP_1_PLUS_REUSED_36_TARGETED_NATIVE"
DELIVERY_QUALIFICATION = "EPUB_READY_HOST_FOLLOWUP_DELIVERY_REUSED_37_TARGETED_NATIVE"
QUALIFICATION = VALIDATION_QUALIFICATION

ROOT, OUT = v.ROOT, v.OUT
SCOPE_JSON = OUT / "epub-freeze-scope.json"
DISPATCH_EVENT_JSON = OUT / "dispatch-event.json"
GATE_JSON = OUT / "epub-freeze-gate.json"
PACKAGE_JSON = OUT / "epub-freeze-package.json"
NATIVE_OUT = OUT / "epub-freeze"
REUSED_OUT = OUT / "reused-evidence"
REUSED_GATE_JSON = REUSED_OUT / "reused-evidence-gate.json"
REUSED_STAGING = ROOT / "build/reused-downloads"

NEW = frozenset()
ALLOWED = frozenset({
    "Tests/YueJingHostTests/EPUBReaderHostTests.swift",
    "Tests/YueJingEPUBUITests/EPUBFlowUITests.swift",
    ".github/workflows/task3-validate.yml",
    "scripts/run_epub_freeze_validation.py",
    "scripts/check_epub_freeze_validation.py",
    "docs/EPUB_FREEZE_RELEASE.md",
})

HOST_TEST_REL = "YueJingHostTests/EPUBReaderHostTests.swift"
UI_TEST_REL = "YueJingEPUBUITests/EPUBFlowUITests.swift"
HOST_METHOD = "epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks"
UI_METHOD = "testEPUBShelfCoverAndDirectoryCrossChapterNavigation"
HOST_METHOD_DECL = "@Test func " + HOST_METHOD + "()"
UI_METHOD_DECL = "@MainActor func " + UI_METHOD + "()"

SELECTED_FILES = {
    "YueJingHostTests/EPUBReaderHostTests.swift": [
        "epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks",
    ],
}

GROUPS = {}
for _kind, _target in (("host", "YueJingHostTests"), ("ui", "YueJingEPUBUITests")):
    _pairs = [(rel, n) for rel, names in SELECTED_FILES.items() if rel.startswith(_target + "/") for n in names]
    # Every declaration gets independent evidence/process admission. A failed case
    # must not consume the remaining cases' opportunity to execute.
    for _index, _chunk in enumerate([[p] for p in _pairs], 1):
        _key = _kind + "-" + str(_index)
        GROUPS[_key] = dict(kind=_kind, target=_target, timeout=480, pairs=_chunk, cases=[n for _, n in _chunk])
del _kind, _target, _pairs, _index, _chunk, _key
UI_SPEC = dict(kind="ui", target="YueJingEPUBUITests", timeout=480,
               pairs=[(UI_TEST_REL, UI_METHOD)], cases=[UI_METHOD])
FOLLOWUP_ALLOWED = ALLOWED - {"Tests/" + UI_TEST_REL}

HIST_ALL_FILES = {
    "ReaderDomainTests/EPUBReadyTests.swift": [
        "readyNodePackKeepsExactNodesWithSmallManifest", "readyImportColdReaderDoesNotDependOnParkedLease",
        "legacyMigrationPreservesProgressPreferencesAndOriginal",
        "readyUnvisitedNodeDamageIsDetectedBeforeOpenAndRepairedWithLeaseIsolation",
        "readyPublicationRollbackAndReconciliationProtectLiveVersions", "readyManifestMutationCannotBeBlessedByRepair",
        "boundedParallelVerificationMatchesSerialIntegrityAndCancellation"],
    "ReaderDomainTests/EPUBLibraryTests.swift": [
        "epubOriginalArchiveAndValidatedResourcesSurviveReopen",
        "epubWarmReopenTransfersFolderWithFreshSessionPositionAndPreferences",
        "epubOverlappingReadersUseIndependentLeasesAndSessions", "epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime",
        "epubFailedOrCancelledCloseNeverReturnsWorkspace", "epubFailureAfterWarmTakeDeletesTransferredFolderNotAnUnusedDestination",
        "epubDuplicateKeepsProgressAndRepairsMissingArchive", "epubCancellationBeforeCommitLeavesNoBook",
        "epubCancellationAfterCommitReturnsReceipt", "epubFailedImportCleansOnlyItsWorkspace",
        "epubV6MigrationPreservesTXTProgressBookmarksAndPreferences", "epubBooksAndTXTStayIsolated"],
    "ReaderDomainTests/EPUBContentPoolTests.swift": [
        "recentBooksReuseIndependentVersionsWithoutCopying", "contentLeaseEvictionWaitsForEveryHolderAndRejectsReleasedTokens",
        "diskContentSurvivesPoolRecreationAndCancellationPublishesNothing",
        "corruptedLeasedVersionIsNotDeletedUntilOldRendererReleasesIt"],
    "ReaderDomainTests/EPUBProgressTests.swift": [
        "epubPositionsRejectForeignVersionsUnitsAndInvalidUTF16Boundaries", "epubProgressRequiresReadinessAndIncreasingSequence",
        "epubOldNavigationSupersededSessionAndClosedCallbacksCannotWrite", "epubTypographyEpochRestoresSameTextPositionAndSettings"],
    "ReaderDomainTests/EPUBCompatibilityTests.swift": ["epubCompatibilityEPUB2DoctypeImageWebPImportProgressSurvivesReopen"],
    "ReaderDomainTests/LibraryWorkflowTests.swift": ["schemaMigrationPreservesBooksAndAddsValidatedSettings"],
    "YueJingHostTests/EPUBReaderHostTests.swift": [
        "epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position",
        "epubSecurityRejectsScriptsFormsExternalResourcesAndKeepsIsolatedLocatorWorking",
        "epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks",
        "epubCompatibilityWebKitLoadsStaticImagePageAndRestoresAnchor",
        "epubRecentBooksReusePagesAcrossSwitchesAndEvictOnlyIdleLRU"],
    "YueJingEPUBUITests/EPUBFlowUITests.swift": [
        "testEPUBShelfCoverAndDirectoryCrossChapterNavigation", "testEPUBProgressSurvivesExitAndProcessRelaunch"],
}

FORBIDDEN_HIST_GROUPS = frozenset({"host-3", "ui-1"})
FORBIDDEN_HIST_CASES = frozenset({HOST_METHOD, UI_METHOD})

HIST_GROUPS = {}
for _kind, _target in (("domain", "ReaderDomainTests"), ("host", "YueJingHostTests"), ("ui", "YueJingEPUBUITests")):
    _pairs = [(rel, n) for rel, names in HIST_ALL_FILES.items() if rel.startswith(_target + "/") for n in names]
    for _index, _chunk in enumerate([[p] for p in _pairs], 1):
        _key = _kind + "-" + str(_index)
        if _key in FORBIDDEN_HIST_GROUPS:
            continue
        HIST_GROUPS[_key] = dict(kind=_kind, target=_target, timeout=480, pairs=_chunk, cases=[n for _, n in _chunk])
del _kind, _target, _pairs, _index, _chunk, _key

require, load, write, sha = v.require, compat.load_json, compat.write_new, compat.digest_path


def selection():
    reviewed = inventory.validate_source(ROOT)
    require(reviewed["selected"] == inventory.TOTAL == 236 and reviewed["selected_executions"] == 237, "Inventory drift")
    names = []
    for rel, selected in SELECTED_FILES.items():
        actual = inventory.source_names(rel, (ROOT / "Tests" / rel).read_text(encoding="utf-8"))
        require(actual == inventory.FILES[rel].split() and set(selected) <= set(actual), "Selection/source drift")
        names.extend(selected)
    require(len(names) == len(set(names)) == TOTAL and
            sum(g["kind"] == "host" for g in GROUPS.values()) == 1 and
            sum(g["kind"] == "ui" for g in GROUPS.values()) == 0,
            "Unexpected selected test count")
    hist_names = []
    for group, spec in HIST_GROUPS.items():
        require(group not in FORBIDDEN_HIST_GROUPS, "Forbidden historical group")
        for rel, name in spec["pairs"]:
            require(name not in FORBIDDEN_HIST_CASES, "Forbidden historical case")
            actual = inventory.source_names(rel, (ROOT / "Tests" / rel).read_text(encoding="utf-8"))
            require(name in inventory.FILES[rel].split() and name in actual, "Historical inventory/source drift: " + name)
            hist_names.append(name)
    require(len(hist_names) == len(set(hist_names)) == REUSED_DECLARATIONS and
            not (set(names) & set(hist_names)),
            "Unexpected historical reuse inventory")
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


def extract_swift_method_span(text, decl_prefix):
    """Return (open_brace_index, close_brace_index) for a unique Swift method declaration."""
    require(text.count(decl_prefix) == 1, "Expected unique Swift method declaration: " + decl_prefix)
    start = text.index(decl_prefix) + len(decl_prefix)
    n = len(text)
    i = start
    while i < n and text[i] != "{":
        if text.startswith("//", i):
            nl = text.find("\n", i)
            i = n if nl < 0 else nl + 1
            continue
        if text.startswith("/*", i):
            depth = 1
            i += 2
            while i < n and depth > 0:
                if text.startswith("/*", i):
                    depth += 1
                    i += 2
                elif text.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        i += 1
    require(i < n and text[i] == "{", "Missing opening brace for method: " + decl_prefix)
    open_idx = i
    brace_depth = 1
    i += 1
    interp_parens = []

    def skip_line_comment(pos):
        nl = text.find("\n", pos)
        return n if nl < 0 else nl + 1

    def skip_block_comment(pos):
        depth = 1
        pos += 2
        while pos < n and depth > 0:
            if text.startswith("/*", pos):
                depth += 1
                pos += 2
            elif text.startswith("*/", pos):
                depth -= 1
                pos += 2
            else:
                pos += 1
        require(depth == 0, "Unterminated block comment in Swift source")
        return pos

    def skip_string(pos, triple):
        delim = '"""' if triple else '"'
        pos += len(delim)
        while pos < n:
            if text.startswith("\\", pos):
                if pos + 1 < n and text[pos + 1] == "(":
                    interp_parens.append((1, triple))
                    return pos + 2
                pos += 2
                continue
            if text.startswith(delim, pos):
                return pos + len(delim)
            pos += 1
        raise ValueError("Unterminated Swift string literal")

    while i < n and brace_depth > 0:
        if text.startswith("//", i):
            i = skip_line_comment(i)
            continue
        if text.startswith("/*", i):
            i = skip_block_comment(i)
            continue
        if text.startswith('"""', i):
            i = skip_string(i, True)
            continue
        if text[i] == '"':
            i = skip_string(i, False)
            continue
        ch = text[i]
        if interp_parens:
            paren_depth, was_triple = interp_parens[-1]
            if ch == "(":
                interp_parens[-1] = (paren_depth + 1, was_triple)
            elif ch == ")":
                if paren_depth == 1:
                    interp_parens.pop()
                    # Resume inside the surrounding string literal.
                    delim = '"""' if was_triple else '"'
                    i += 1
                    while i < n:
                        if text.startswith("\\", i):
                            if i + 1 < n and text[i + 1] == "(":
                                interp_parens.append((1, was_triple))
                                i += 2
                                break
                            i += 2
                            continue
                        if text.startswith(delim, i):
                            i += len(delim)
                            break
                        i += 1
                    continue
                interp_parens[-1] = (paren_depth - 1, was_triple)
        if ch == "{":
            brace_depth += 1
        elif ch == "}":
            brace_depth -= 1
            if brace_depth == 0:
                return open_idx, i
        i += 1
    raise ValueError("Unterminated Swift method body: " + decl_prefix)


HORIZONTAL_DECL = "private func verifyHorizontalPagination()"
PAGING_DECL = "private func verifyPagingAndChapterBoundaryNavigation()"


def normalize_horizontal_diagnostics(base_text, current_text):
    """Only synchronous read-only print slots; normalize back to byte-identical actions.

    No arbitrary Swift expressions, JS evaluation, async work, assignments, retries,
    waits or assertion changes are erased. The callback forwards exactly once and
    the initial readiness catch must rethrow the original error.
    """
    bo, bc = extract_swift_method_span(base_text, HORIZONTAL_DECL)
    co, cc = extract_swift_method_span(current_text, HORIZONTAL_DECL)
    original, body = base_text[bo + 1:bc], current_text[co + 1:cc]
    expressions = (
        "payload.kind", "payload.node", "payload.restoredNode", "payload.restoredOffset",
        "payload.epoch == model.currentToken?.epoch", "model.ready", "model.loading",
        "failure.domain", "failure.code", "token == model.currentToken", "first.readingMode",
        "controller.webView.bounds", "controller.webView.window != nil",
        "String(describing: model.message)", "model.navigationRequest != nil",
        "controller.activeRequest != nil", "controller.documentLoadCount",
        "controller.renderedChapterPaths.count", "controller.deniedNavigations.count",
        "controller.webView.isLoading", "controller.webView.estimatedProgress",
        "controller.webView.scrollView.contentSize", "controller.webView.isHidden",
    )
    interpolation = re.compile(r"\\\(" + "(?:" + "|".join(re.escape(e) for e in expressions) + r")\)")
    prints = re.findall(r'^ *print\("(EPUB_SYNTHETIC_HORIZONTAL_[^\n]*)"\)\n', body, re.M)
    require(len(prints) <= 4 and len({s.split()[0] for s in prints}) == len(prints),
            "Duplicate/excess horizontal diagnostics")
    for message in prints:
        literal = interpolation.sub("VALUE", message)
        require(re.fullmatch(r"EPUB_SYNTHETIC_HORIZONTAL_[A-Z_]+[A-Za-z0-9_ =.:-]*", literal),
                "Horizontal diagnostic contains unapproved expression/escape")
    body = re.sub(r'^ *print\("EPUB_SYNTHETIC_HORIZONTAL_[^\n]*"\)\n', '', body, flags=re.M)
    body = body.replace(
        '            controller.onLocatorEvent = { payload in\n'
        '                model.handleLocatorEvent(payload)\n            }',
        '            controller.onLocatorEvent = { model.handleLocatorEvent($0) }')
    body = body.replace(
        '            controller.onLoadFailure = { error, token in\n'
        '                let failure = error as NSError\n'
        '                model.handleLoadFailure(error, token: token)\n            }',
        '            controller.onLoadFailure = { model.handleLoadFailure($0, token: $1) }')
    body = body.replace(
        '                do {\n'
        '                    try await waitUntilReady(model: model, expectedToken: first.token)\n'
        '                } catch {\n                    throw error\n                }',
        '                try await waitUntilReady(model: model, expectedToken: first.token)')
    require(body == original, "Horizontal helper changed assertions/waits/actions or non-diagnostic code")
    # Lexical call graph is pinned, not a whole-file exemption. Other source files
    # are separately byte-pinned; these private helpers have exactly one caller.
    for name, caller in (("verifyHorizontalPagination", PAGING_DECL),
                         ("verifyPagingAndChapterBoundaryNavigation", HOST_METHOD_DECL)):
        require(len(re.findall(r"\b" + name + r"\s*\(", current_text)) == 2,
                "Private helper gained another caller: " + name)
        start, end = extract_swift_method_span(current_text, caller)
        require(current_text[start:end].count("try await " + name + "()") == 1,
                "Private helper caller isolation drift: " + name)
    return current_text[:co + 1] + original + current_text[cc:]


def validate_followup_sources(source_files=None):
    """Freeze UI, products, dependencies/config and all other Host methods to Round 2."""
    before, after = tree(UI_BASE), tree("HEAD")
    changed = {p for p in set(before) | set(after) if before.get(p) != after.get(p)}
    require(changed <= FOLLOWUP_ALLOWED and set(before) == set(after), "Round-2 source boundary drift")
    current_files = v.candidate_files()
    if source_files is not None:
        require(set(source_files) == set(current_files), "UI source manifest inventory drift")
        for path, digest in source_files.items():
            if path not in FOLLOWUP_ALLOWED:
                require(current_files[path] == digest, "UI/shared source drift: " + path)
    for path in current_files:
        if path not in FOLLOWUP_ALLOWED:
            data = (v.ROOT / path).read_bytes()
            blob_id = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
            require(before.get(path, [None, None, None])[2] == blob_id,
                    "Source differs from UI baseline: " + path)
    base_host = git("show", UI_BASE + ":Tests/" + HOST_TEST_REL).decode("utf-8")
    current_host = (v.ROOT / "Tests" / HOST_TEST_REL).read_text(encoding="utf-8")
    require(normalize_horizontal_diagnostics(base_host, current_host) == base_host,
            "Host changed outside private horizontal diagnostics (including fragment contract)")
    require((v.ROOT / "Tests" / UI_TEST_REL).read_bytes() == git("show", UI_BASE + ":Tests/" + UI_TEST_REL),
            "UI source must remain byte-identical to Round 2")


def validate_test_method_isolation(base_text, current_text, decl_prefix, *, kind):
    """Require byte-identical source outside the single target method body and preserve contracts."""
    if kind == "host":
        current_text = normalize_horizontal_diagnostics(base_text, current_text)
    b_open, b_close = extract_swift_method_span(base_text, decl_prefix)
    c_open, c_close = extract_swift_method_span(current_text, decl_prefix)
    require(base_text[:b_open + 1] == current_text[:c_open + 1],
            "Source modified before target method body: " + decl_prefix)
    require(base_text[b_close:] == current_text[c_close:],
            "Source modified after target method body: " + decl_prefix)
    body = current_text[c_open + 1:c_close]
    if kind == "ui":
        ui_reopen_contract(current_text)
        for token in (
            'let exit = app.buttons["reader.exit"]',
            "exit.exists && exit.isHittable",
            "!exit.exists || !exit.isHittable",
            "waitForPredicates([hidden], timeout: 5)",
            "bottom.tap()",
            'waitHittable(app.buttons["reader.exit"], timeout: 5)',
            "waitForPredicates([movedToChapter2Mid], timeout: 15)",
            "verifyPagingAndCrossChapterNavigation(app)",
        ):
            require(token in body, "Missing preserved UI assertion/budget in target method: " + token)
    elif kind == "host":
        for token in (
            "ReaderPreferences(fontSize: 28, lineSpacing: 14, theme: .dark)",
            "try await waitUntilReady(model: model, expectedToken: ch2Request.token, minimumNode: 6)",
            '#expect(model.currentPosition?.path == "OEBPS/text/ch2.xhtml")',
            "#expect((model.currentPosition?.node ?? 0) > 5)",
            '#expect(reopened.reading.position?.path == "OEBPS/text/ch2.xhtml")',
            "#expect((reopened.reading.position?.node ?? 0) > 5)",
            "try await verifyPagingAndChapterBoundaryNavigation()",
            '#expect(ch2Request.fragment == "sec-mid")',
            "#expect(ch2Request.targetPosition == nil)",
            "#expect(!ch2Request.preserveViewport)",
            "if error is CancellationError || Task.isCancelled { throw error }",
            "throw error",
        ):
            require(token in body, "Missing preserved Host assertion/instrumentation in target method: " + token)
        catch_part = body.split("} catch {", 1)[1].split('#expect(model.currentPosition?.path', 1)[0]
        require("model.go(" not in catch_part and "controller.apply(" not in catch_part and "waitUntilReady(" not in catch_part,
                "Host failure catch block must not retry navigation or wait")
        require(re.search(r"\bthrow error\s*\}\s*$", catch_part),
                "Host failure catch block must rethrow the original error")
    else:
        raise ValueError("Unsupported method isolation kind: " + repr(kind))


def dispatch_context():
    """Bind the job environment to the original workflow_dispatch payload and two-phase rules."""
    event = load(Path(os.environ["GITHUB_EVENT_PATH"]))
    inputs = event.get("inputs", {})
    require(isinstance(inputs, dict), "Invalid dispatch inputs")
    value = inputs.get("allow_unqualified_ipa", False)
    require(type(value) is bool or value in ("true", "false"), "Invalid diagnostic permission")
    allowed = value is True or value == "true"
    require(not allowed, "Diagnostic IPA permission is disabled for host followup")
    require(inputs.get("validation_scope") == SCOPE and
            os.environ.get("ALLOW_UNQUALIFIED_IPA") == ("true" if allowed else "false"),
            "Dispatch permission/scope differs from environment")
    build = inputs.get("build_ipa", False)
    require(type(build) is bool or build in ("true", "false"), "Invalid build phase")
    requested = build is True or build == "true"
    require(os.environ.get("BUILD_IPA") == ("true" if requested else "false"), "Build phase differs from dispatch")
    raw_prior = inputs.get("prior_validation_run", "")
    prior = "" if raw_prior is None else raw_prior
    require(isinstance(prior, str), "Invalid prior validation run")
    require(os.environ.get("PRIOR_VALIDATION_RUN", "") == prior, "Prior validation run differs from dispatch")
    if prior:
        require(bool(re.fullmatch(r"[1-9][0-9]*", prior)), "Invalid prior_validation_run ID")
        require(prior != os.environ.get("GITHUB_RUN_ID"), "Self-referential prior_validation_run rejected")
        require(prior not in (str(HIST_RUN), str(UI_RUN)), "Historical source cannot be prior_validation_run")
        require(requested is True, "Delivery phase with prior_validation_run requires build_ipa=true")
        phase = "delivery"
    else:
        require(requested is False, "Validation phase requires build_ipa=false; delivery requires prior_validation_run")
        phase = "validation"
    return dict(allow_unqualified_ipa=allowed, build_ipa=requested, prior_validation_run=prior, phase=phase)


def dispatch_permission():
    return dispatch_context()["allow_unqualified_ipa"]


def scope_receipt():
    env = os.environ
    require(env.get("VALIDATION_SCOPE") == SCOPE and env.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and env.get("GITHUB_REF") == "refs/heads/main" and env.get("GITHUB_RUN_ATTEMPT") == "1"
            and env.get("GITHUB_REPOSITORY") == REPO, "Unapproved dispatch identity")
    head = git("rev-parse", "HEAD").decode().strip()
    require(re.fullmatch(r"[0-9a-f]{40}", head) and head == env.get("GITHUB_SHA") and head != BASE, "Candidate/source mismatch")
    require(re.fullmatch(r"[1-9][0-9]*", env.get("GITHUB_RUN_ID", "")), "Invalid run identity")
    git("merge-base", "--is-ancestor", BASE, head)
    require(not git("status", "--porcelain", "--untracked-files=no").strip(), "Tracked source drift")
    before, after = tree(BASE), tree("HEAD")
    changed = {p for p in set(before) | set(after) if before.get(p) != after.get(p)}
    require(changed == ALLOWED and set(after) - set(before) == NEW and not set(before) - set(after),
            "Release changes outside exact 6-path scope boundary")
    require(all(after[p][:2] == ["100644", "blob"] for p in changed), "Nonregular approved source")
    base_project = git("show", BASE + ":project.yml")
    current_project = (ROOT / "project.yml").read_bytes()
    require(current_project == base_project, "project.yml must remain byte-identical to BASE")
    require(b'        MARKETING_VERSION: "' + VERSION.encode() + b'"\n' in current_project
            and b'        CURRENT_PROJECT_VERSION: "' + BUILD.encode() + b'"\n' in current_project,
            "project.yml version/build mismatch")
    validate_test_method_isolation(
        git("show", BASE + ":Tests/" + HOST_TEST_REL).decode("utf-8"),
        (ROOT / "Tests" / HOST_TEST_REL).read_text(encoding="utf-8"),
        HOST_METHOD_DECL,
        kind="host",
    )
    validate_test_method_isolation(
        git("show", BASE + ":Tests/" + UI_TEST_REL).decode("utf-8"),
        (ROOT / "Tests" / UI_TEST_REL).read_text(encoding="utf-8"),
        UI_METHOD_DECL,
        kind="ui",
    )
    validate_followup_sources()
    dispatch = dispatch_context()
    return dict(
        scope=SCOPE,
        phase=dispatch["phase"],
        prior_validation_run=dispatch["prior_validation_run"],
        source_commit=head,
        baseline_commit=BASE,
        run_id=env["GITHUB_RUN_ID"],
        run_attempt="1",
        version=VERSION,
        build=BUILD,
        allow_unqualified_ipa=dispatch["allow_unqualified_ipa"],
        dispatch_event_sha256=sha(Path(env["GITHUB_EVENT_PATH"])),
        build_ipa=dispatch["build_ipa"],
        changed_paths=sorted(changed),
        selected=selection(),
        selected_declarations=0 if dispatch["phase"] == "delivery" else TOTAL,
        native_tests_planned=0 if dispatch["phase"] == "delivery" else EXECUTIONS,
        reused_historical_run_id=str(HIST_RUN),
        reused_historical_artifact_id=HIST_ARTIFACT_ID,
        reused_historical_declarations=REUSED_DECLARATIONS,
        reused_historical_executions=REUSED_EXECUTIONS,
        reused_ui_run_id=str(UI_RUN),
        reused_ui_executions=1,
        reused_native_planned=COMBINED_EXECUTIONS if dispatch["phase"] == "delivery" else ALL_REUSED_EXECUTIONS,
        combined_target_declarations=COMBINED_TOTAL,
        combined_target_executions=COMBINED_EXECUTIONS,
        full_inventory_declared=236,
        full_inventory_executions=237,
        files=v.candidate_files(),
        approved_files={p: sha(ROOT / p) for p in sorted(ALLOWED)},
        physical_acceptance="not performed",
        full_regression_passed=False,
    )


def live_scope():
    receipt = scope_receipt()
    require(load(SCOPE_JSON) == receipt, "Frozen scope/source/run drift")
    if DISPATCH_EVENT_JSON.exists() or DISPATCH_EVENT_JSON.is_symlink():
        require(DISPATCH_EVENT_JSON.is_file() and not DISPATCH_EVENT_JSON.is_symlink(), "Invalid saved dispatch event")
        require(sha(DISPATCH_EVENT_JSON) == receipt["dispatch_event_sha256"], "Saved dispatch event drift")
    v.check_candidate()
    return receipt


def command_for_spec(spec, destination, result_bundle):
    require(re.fullmatch(r"platform=iOS Simulator,id=[0-9a-fA-F-]{36}", destination), "Expected simulator UUID/group")
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


def command(group, destination, result_bundle):
    require(group in GROUPS, "Expected simulator UUID/group")
    return command_for_spec(GROUPS[group], destination, result_bundle)


def parse_log_for_spec(group, spec, raw, code, timed_out):
    require(type(code) is int and code == 0 and timed_out is False, "Native failure/timeout")
    require(isinstance(raw, bytes) and raw, "Missing native log")
    names, kind = spec["cases"], spec["kind"]
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


def parse_log(group, raw, code, timed_out):
    require(group in GROUPS, "Unknown group: " + str(group))
    return parse_log_for_spec(group, GROUPS[group], raw, code, timed_out)


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


def parameter_evidence(group, folder, bundle, *, export=False, group_specs=GROUPS, verify_live_bundle=True):
    if not any(name in inventory.PARAMETERIZED for name in group_specs[group]["cases"]):
        return None
    path = folder / "xcresult-tests.json"
    if export:
        require(not path.exists(), "Existing xcresult export")
        raw = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)], timeout=60)
        path.write_bytes(raw)
    require(path.is_file() and not path.is_symlink(), "Missing regular xcresult export")
    raw = path.read_bytes()
    if not export and verify_live_bundle:
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
            stop()
            process.wait(timeout=10)
    return code, timed_out


def run_group(group, destination, *, checked_scope=None):
    scope = checked_scope if checked_scope is not None else live_scope()
    require(scope["phase"] == "validation", "Native execution is forbidden in delivery phase")
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
        require(scope["phase"] == "validation", "Native execution is forbidden in delivery phase")
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


# ---------------------------------------------------------------------------
# Historical 35 & Prior Validation Run Reuse Verification
# ---------------------------------------------------------------------------

def github_api_json(suffix):
    raw = subprocess.check_output(
        ["gh", "api", "--method", "GET", f"repos/{REPO}{suffix}"],
        cwd=ROOT,
        timeout=180,
    )
    value = json.loads(raw)
    require(isinstance(value, dict), "Unexpected GitHub API JSON payload")
    return value


def github_download_artifact_zip(artifact_id, dest_path):
    require(not dest_path.exists(), "Existing staging archive; never overwrite")
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    with dest_path.open("xb") as target:
        subprocess.run(
            ["gh", "api", "--method", "GET", f"repos/{REPO}/actions/artifacts/{artifact_id}/zip"],
            cwd=ROOT,
            stdout=target,
            check=True,
            timeout=600,
        )


def _select_artifact_from_payload(payload, expected_name, expected_id=None):
    if isinstance(payload, dict) and isinstance(payload.get("artifacts"), list):
        candidates = [
            a for a in payload["artifacts"]
            if isinstance(a, dict)
            and (expected_id is None or a.get("id") == expected_id)
            and a.get("name") == expected_name
        ]
        require(len(candidates) == 1, "Expected exactly one matching artifact: " + expected_name)
        return candidates[0]
    require(isinstance(payload, dict) and payload.get("name") == expected_name,
            "Unexpected artifact metadata object")
    return payload


def safe_zip_members(archive_path):
    with zipfile.ZipFile(archive_path) as source:
        infos = source.infolist()
        require(len(infos) <= 50000, "Evidence archive entry count exceeds bound")
        for info in infos:
            require(info.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED),
                    "Unsupported ZIP compression method")
    members = rne.zip_members(archive_path)
    with zipfile.ZipFile(archive_path) as source:
        for info in source.infolist():
            if not info.is_dir():
                require(members[info.filename]["bytes"] == info.file_size,
                        "ZIP header file_size mismatch: " + info.filename)
    return members


def _repo_matches(run, key):
    repo_obj = run.get(key)
    require(isinstance(repo_obj, dict) and repo_obj.get("full_name") == REPO,
            f"Run {key} differs from {REPO}")


def validate_historical_run_and_artifact(run, artifact):
    require(isinstance(run, dict) and isinstance(artifact, dict), "Invalid historical API metadata")
    require(run.get("id") == HIST_RUN
            and run.get("head_sha") == BASE
            and run.get("run_attempt") == 1
            and run.get("workflow_id") == WORKFLOW_ID
            and run.get("path") == WORKFLOW_PATH
            and run.get("event") == "workflow_dispatch"
            and run.get("head_branch") == "main"
            and run.get("status") == "completed"
            and run.get("conclusion") in ("failure", "success"),
            "Unexpected historical run identity")
    _repo_matches(run, "repository")
    _repo_matches(run, "head_repository")
    wf_run = artifact.get("workflow_run")
    require(isinstance(wf_run, dict)
            and artifact.get("id") == HIST_ARTIFACT_ID
            and artifact.get("expired") is False
            and artifact.get("name") == HIST_ARTIFACT_NAME
            and wf_run.get("id") == HIST_RUN
            and wf_run.get("head_sha") == BASE
            and artifact.get("size_in_bytes") == HIST_ARCHIVE_BYTES
            and artifact.get("digest") == "sha256:" + HIST_ARCHIVE_SHA256,
            "Historical artifact provenance mismatch")


def validate_prior_run_and_artifact(prior_id, run, artifact, expected_sha, current_run_id):
    require(isinstance(run, dict) and isinstance(artifact, dict), "Invalid prior API metadata")
    require(re.fullmatch(r"[1-9][0-9]*", str(prior_id)), "Invalid prior run ID")
    require(str(prior_id) not in (str(current_run_id), str(HIST_RUN), str(UI_RUN)),
            "Self-referential or historical prior run rejected")
    require(run.get("id") == int(prior_id)
            and run.get("head_sha") == expected_sha
            and run.get("run_attempt") == 1
            and run.get("workflow_id") == WORKFLOW_ID
            and run.get("path") == WORKFLOW_PATH
            and run.get("event") == "workflow_dispatch"
            and run.get("head_branch") == "main"
            and run.get("status") == "completed"
            and run.get("conclusion") == "success",
            "Unexpected prior validation run identity")
    _repo_matches(run, "repository")
    _repo_matches(run, "head_repository")
    expected_name = f"task3-evidence-{prior_id}-{expected_sha}"
    wf_run = artifact.get("workflow_run")
    digest_value = artifact.get("digest")
    size_value = artifact.get("size_in_bytes")
    require(isinstance(wf_run, dict)
            and isinstance(artifact.get("id"), int) and artifact["id"] > 0
            and artifact.get("expired") is False
            and artifact.get("name") == expected_name
            and wf_run.get("id") == int(prior_id)
            and wf_run.get("head_sha") == expected_sha
            and type(size_value) is int and 0 < size_value < 4 * 1024**3
            and isinstance(digest_value, str)
            and bool(re.fullmatch(r"sha256:[0-9a-f]{64}", digest_value)),
            "Prior artifact provenance mismatch")


def extract_selected_members(zip_path, members, wanted_names, dest_root):
    dest_root.mkdir(parents=True, exist_ok=True)
    resolved_root = dest_root.resolve()
    retained = {}
    with zipfile.ZipFile(zip_path) as source:
        for name in sorted(wanted_names):
            require(name in members, "Missing required archive member: " + name)
            target = (dest_root / name).resolve()
            require(target.is_relative_to(resolved_root), "Escaping archive destination: " + name)
            target.parent.mkdir(parents=True, exist_ok=True)
            data = source.read(name)
            actual_meta = dict(bytes=len(data), sha256=compat.digest_bytes(data))
            require(actual_meta == members[name], "Archive member metadata mismatch: " + name)
            with target.open("xb") as out_stream:
                out_stream.write(data)
            retained[name] = actual_meta
    return retained


def _verify_archive_receipt(folder, *, expected_run_id, expected_source_commit,
                            expected_artifact_id=None, expected_bytes=None, expected_sha256=None):
    require(folder.is_dir() and not folder.is_symlink(), "Missing reused folder: " + str(folder))
    require({p.name for p in folder.iterdir()} == {"api-run.json", "api-artifact.json", "archive-receipt.json", "evidence"},
            "Unexpected files in reused folder: " + str(folder))
    run = load(folder / "api-run.json")
    artifact = load(folder / "api-artifact.json")
    receipt = load(folder / "archive-receipt.json")
    require(str(receipt.get("run_id")) == str(expected_run_id)
            and str(receipt.get("run_attempt")) == "1"
            and receipt.get("source_commit") == expected_source_commit
            and receipt.get("artifact_id") == artifact.get("id")
            and (expected_artifact_id is None or receipt.get("artifact_id") == expected_artifact_id)
            and (expected_bytes is None or receipt.get("archive_bytes") == expected_bytes)
            and (expected_sha256 is None or receipt.get("archive_sha256") == expected_sha256)
            and artifact.get("size_in_bytes") == receipt.get("archive_bytes")
            and artifact.get("digest") == "sha256:" + str(receipt.get("archive_sha256")),
            "Archive receipt metadata mismatch")
    members = receipt.get("members")
    retained = receipt.get("retained_files")
    require(isinstance(members, dict) and isinstance(retained, dict)
            and receipt.get("member_count") == len(members),
            "Malformed archive receipt member table")
    for rel, meta in retained.items():
        require(members.get(rel) == meta, "Retained file differs from archive member receipt: " + rel)
    ev_dir = folder / "evidence"
    require(ev_dir.is_dir() and not ev_dir.is_symlink(), "Missing retained evidence directory")
    actual_disk = {}
    for p in sorted(ev_dir.rglob("*")):
        require(not p.is_symlink() and p.resolve().is_relative_to(ev_dir.resolve()), "Unsafe retained path")
        if p.is_file():
            rel = p.relative_to(ev_dir).as_posix()
            actual_disk[rel] = dict(bytes=p.stat().st_size, sha256=sha(p))
    require(actual_disk == retained, "Retained evidence files drifted on disk")
    return run, artifact, receipt


def _verify_toolchain_and_deps(ev_dir, expected_source_commit, *, expected_packages=None):
    tool_path = ev_dir / "toolchain.log"
    gen_path = ev_dir / "xcodegen.log"
    dep_path = ev_dir / "dependency-resolution.json"
    require(all(p.is_file() and not p.is_symlink() for p in (tool_path, gen_path, dep_path)),
            "Missing reused toolchain/xcodegen/dependency receipt")
    tool = tool_path.read_text(encoding="utf-8")
    require(("Source: " + expected_source_commit) in tool
            and all(t in tool for t in ("Xcode 16.4", "Build version 16F6", "Apple Swift version 6.1.2", "arm64")),
            "Reused toolchain log mismatch")
    require(gen_path.read_text(encoding="utf-8").strip() == "Version: 2.46.0", "Reused xcodegen log mismatch")
    dep = load(dep_path)
    packages = dep.get("packages")
    require(isinstance(packages, dict) and set(packages) == {"grdb.swift", "zipfoundation"},
            "Reused dependency closure mismatch")
    for identity, expected_dep in compat.epub_batch.DEPENDENCIES.items():
        pkg = packages.get(identity, {})
        pkg_meta = pkg.get("package", {})
        state = pkg_meta.get("state", {})
        require(pkg_meta.get("location") == expected_dep["url"]
                and pkg.get("checkout_revision") == expected_dep["revision"]
                and state.get("revision") == expected_dep["revision"]
                and state.get("version") == expected_dep["version"]
                and pkg.get("package_manifest_sha256") == expected_dep["manifest"],
                "Reused dependency pin/manifest mismatch: " + identity)
    if expected_packages is not None:
        require(packages == expected_packages, "Reused dependencies differ from current run")
    return packages


def _verify_simulator_and_linkage(ev_dir, members, expected_source_commit, expected_run_id):
    sim = load(ev_dir / "simulator-selection.json")
    udid = sim.get("udid")
    require(sim.get("physical_device") is False
            and sim.get("architecture") == "arm64"
            and isinstance(udid, str)
            and bool(re.fullmatch(r"[0-9a-fA-F-]{36}", udid))
            and isinstance(sim.get("device_name"), str)
            and sim["device_name"].startswith("iPhone"),
            "Invalid reused simulator selection")
    boot = load(ev_dir / "simulator-boot.json")
    require(boot.get("source_commit") == expected_source_commit
            and str(boot.get("run_id")) == str(expected_run_id)
            and str(boot.get("run_attempt")) == "1"
            and boot.get("exit_code") == 0
            and boot.get("timed_out") is False,
            "Invalid reused simulator boot receipt")
    link_path = ev_dir / "webkit-simulator-linkage/verification.json"
    record = load(link_path)
    require(record.get("source_commit") == expected_source_commit
            and str(record.get("run_id")) == str(expected_run_id)
            and str(record.get("run_attempt")) == "1"
            and record.get("passed") is True
            and not record.get("errors")
            and isinstance(record.get("binaries"), list) and record["binaries"],
            "Invalid reused simulator WebKit linkage receipt")
    for binary in record["binaries"]:
        ev_rel = "webkit-simulator-linkage/" + str(binary.get("evidence", ""))
        require(binary.get("passed") is True and binary.get("nm_exit") == 0
                and members.get(ev_rel, {}).get("sha256") == binary.get("sha256"),
                "Reused simulator WebKit binary digest mismatch: " + ev_rel)
    return sim, sha(link_path)


def _verify_reused_group_settings(kind, target, group_folder, ev_dir, expected_source_commit):
    receipt = load(group_folder / f"{target}-settings.json")
    require(receipt.get("source_commit") == expected_source_commit, "Settings source_commit mismatch")
    require(bool(re.fullmatch(r"[0-9a-f]{64}", str(receipt.get("scheme_sha256", "")))), "Missing scheme sha256")
    if kind == "domain":
        eff_path = ev_dir / "effective-test-settings.json"
        eff = load(eff_path)
        values = eff.get("ReaderDomainTests")
        compat._validate_domain_effective_settings(values)
        require(receipt.get("target") == "ReaderDomainTests"
                and receipt.get("scheme") == "ReaderDomain"
                and receipt.get("effective_settings_sha256") == sha(eff_path)
                and receipt.get("testables") == ["ReaderDomainTests"]
                and receipt.get("settings") == values,
                "Reused Domain settings receipt mismatch")
        return
    require(receipt.get("fixture_environment")
            and set(receipt.get("testables", ())) == set(ui.GROUPS),
            "Reused app suite settings mismatch")
    ui.uuid.UUID(str(receipt["fixture_environment"]))
    targets = receipt.get("targets", {})
    app = targets.get("YueJing", {})
    test = targets.get(target, {})
    require(all(v_.get("SWIFT_VERSION") == "6.0"
                and v_.get("SWIFT_STRICT_CONCURRENCY") == "complete"
                and v_.get("IPHONEOS_DEPLOYMENT_TARGET") == "16.6"
                for v_ in (app, test)),
            "Reused app/test toolchain settings mismatch")
    require(app.get("PRODUCT_TYPE") == "com.apple.product-type.application"
            and "DEBUG" in str(app.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")).split(),
            "Reused app Debug condition missing")
    if target == "YueJingHostTests":
        test_host = PurePosixPath(str(test.get("TEST_HOST", "")))
        require(test.get("PRODUCT_TYPE") == "com.apple.product-type.bundle.unit-test"
                and test_host.name == "YueJing" and test_host.parent.name == "YueJing.app"
                and test.get("BUNDLE_LOADER") == test.get("TEST_HOST"),
                "Reused Host test host mismatch")
    else:
        require(test.get("PRODUCT_TYPE") == "com.apple.product-type.bundle.ui-testing"
                and test.get("TEST_TARGET_NAME") == "YueJing",
                "Reused UI target mismatch")


def _verify_reused_group(group, spec, ev_dir, members, *, expected_scope, expected_source, expected_run_id,
                         destination, prefix=""):
    target, kind = spec["target"], spec["kind"]
    folder = ev_dir / "epub-freeze" / group
    require(folder.is_dir() and not folder.is_symlink(), "Missing reused group directory: " + group)
    require(not (folder / "failure.json").exists(), "Failed reused group cannot qualify: " + group)
    bundle_rel = f"{prefix}epub-freeze/{group}/{target}.xcresult"
    require((folder / f"{target}.xcresult/Info.plist").is_file()
            and not (folder / f"{target}.xcresult/Info.plist").is_symlink()
            and bundle_rel + "/Info.plist" in members
            and any(m.startswith(bundle_rel + "/Data/") for m in members),
            "Missing reused xcresult bundle proof for " + group)
    selection_rec = load(folder / "selection.json")
    execution_rec = load(folder / "execution.json")
    cmd = selection_rec.get("command")
    require(isinstance(cmd, list) and "-resultBundlePath" in cmd, "Malformed reused command: " + group)
    bundle_arg_idx = cmd.index("-resultBundlePath") + 1
    require(bundle_arg_idx < len(cmd), "Missing resultBundlePath arg: " + group)
    bundle_arg = cmd[bundle_arg_idx]
    arg_parts = PurePosixPath(bundle_arg.replace("\\", "/")).parts
    require(len(arg_parts) >= 2 and arg_parts[-2:] == (group, target + ".xcresult"),
            "Unexpected resultBundlePath in reused selection: " + group)
    want_cmd = command_for_spec(spec, destination, bundle_arg)
    want = dict(scope=expected_scope, source_commit=expected_source, run_id=str(expected_run_id), run_attempt="1",
                group=group, target=target, destination=destination,
                expected_cases=spec["cases"], command=want_cmd,
                timeout_seconds=spec["timeout"], case_timeout_seconds=180)
    require(selection_rec == want, "Reused selection provenance mismatch: " + group)
    require(type(execution_rec.get("native_exit")) is int and execution_rec.get("timed_out") is False
            and execution_rec == dict(**want, native_exit=0, timed_out=False), "Reused execution provenance mismatch: " + group)
    _verify_reused_group_settings(kind, target, folder, ev_dir, expected_source)
    log_path = folder / f"{target}.log"
    require(log_path.is_file() and not log_path.is_symlink(), "Missing reused log: " + group)
    parsed = parse_log_for_spec(group, spec, log_path.read_bytes(), 0, False)
    parsed["parameter_xcresult"] = parameter_evidence(
        group, folder, folder / f"{target}.xcresult", group_specs={group: spec}, verify_live_bundle=False,
    )
    require(json.dumps(load(folder / "counts.json"), sort_keys=True) == json.dumps(parsed, sort_keys=True),
            "Reused counts differ from raw log events: " + group)
    return parsed


def validate_ui_run_and_artifact(run, artifact):
    require(run.get("id") == UI_RUN and run.get("head_sha") == UI_BASE
            and run.get("run_attempt") == 1 and run.get("workflow_id") == WORKFLOW_ID
            and run.get("path") == WORKFLOW_PATH and run.get("event") == "workflow_dispatch"
            and run.get("head_branch") == "main" and run.get("status") == "completed"
            and run.get("conclusion") == "failure", "Unexpected pinned UI source run")
    _repo_matches(run, "repository")
    _repo_matches(run, "head_repository")
    require(artifact.get("id") == UI_ARTIFACT_ID and artifact.get("name") == UI_ARTIFACT_NAME
            and artifact.get("expired") is False and artifact.get("size_in_bytes") == UI_ARCHIVE_BYTES
            and artifact.get("digest") == "sha256:" + UI_ARCHIVE_SHA256
            and artifact.get("workflow_run", {}).get("id") == UI_RUN
            and artifact.get("workflow_run", {}).get("head_sha") == UI_BASE,
            "Pinned UI artifact provenance mismatch")


def _ui_wanted_members(members):
    wanted = {"epub-freeze-scope.json", "dispatch-event.json", "candidate-sources.json",
              "toolchain.log", "xcodegen.log", "dependency-resolution.json", "Package.resolved",
              "simulator-selection.json", "simulator-boot.json", "webkit-simulator-linkage/verification.json"}
    wanted.update(m for m in members if m.startswith("webkit-simulator-linkage/nm-") and m.endswith(".log"))
    wanted.update(m for m in members if m.startswith("epub-freeze/ui-1/"))
    return wanted


def verify_ui_xcresult(bundle):
    paging.require_xcresult(bundle)
    require((bundle / "Data").is_dir() and any(p.is_file() and p.stat().st_size > 0
            for p in (bundle / "Data").iterdir()), "Missing UI xcresult Data")
    # The full bundle bytes are bound to the pinned API digest on all platforms.
    # Native parsing is additionally mandatory on the runner, never claimed on Windows.
    if sys.platform == "darwin":
        # xcresulttool may materialize database.sqlite3 even for a read command.
        # Parse an isolated copy so the pinned evidence remains byte-for-byte immutable.
        temporary_root = Path(os.environ.get("PI_SCRATCH_DIR", str(REUSED_STAGING)))
        temporary_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="ui-xcresult-", dir=temporary_root) as temporary:
            working_bundle = Path(temporary) / bundle.name
            shutil.copytree(bundle, working_bundle)
            raw = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary",
                                           "--path", str(working_bundle)], timeout=120)
            tests_raw = subprocess.check_output(
                ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(working_bundle)], timeout=120)
        result = json.loads(raw)
        require(result.get("totalTestCount") == 1 and result.get("passedTests") == 1
                and result.get("failedTests") == 0 and result.get("skippedTests") == 0,
                "UI xcresult summary differs from one passing test")
        tests = json.loads(tests_raw)
        matches = []
        def visit(node):
            if isinstance(node, dict):
                if node.get("name") in (UI_METHOD, UI_METHOD + "()"):
                    matches.append(node)
                for value in node.values():
                    visit(value)
            elif isinstance(node, list):
                for value in node:
                    visit(value)
        visit(tests)
        require(len(matches) == 1 and matches[0].get("result") == "Passed", "UI xcresult identity/result drift")


def verify_ui_evidence(ui_root, *, expected_packages=None, check_shared_sources=True):
    run, artifact, receipt = _verify_archive_receipt(
        ui_root, expected_run_id=UI_RUN, expected_source_commit=UI_BASE,
        expected_artifact_id=UI_ARTIFACT_ID, expected_bytes=UI_ARCHIVE_BYTES, expected_sha256=UI_ARCHIVE_SHA256)
    validate_ui_run_and_artifact(run, artifact)
    require(compat.digest_bytes(json.dumps(receipt["members"], sort_keys=True, separators=(",", ":")).encode())
            == UI_MEMBERS_SHA256, "Pinned UI archive manifest drift")
    ev = ui_root / "evidence"
    require(set(receipt["retained_files"]) == _ui_wanted_members(receipt["members"]), "UI retained manifest incomplete/extra")
    require({p.name for p in (ev / "epub-freeze").iterdir()} == {"ui-1"}, "UI-only reuse cannot include failed Host")
    scope = load(ev / "epub-freeze-scope.json")
    event = load(ev / "dispatch-event.json").get("inputs", {})
    require(scope.get("scope") == UI_SCOPE and scope.get("source_commit") == UI_BASE
            and scope.get("run_id") == str(UI_RUN) and scope.get("run_attempt") == "1"
            and scope.get("phase") == "validation" and scope.get("prior_validation_run") == ""
            and scope.get("build_ipa") is False and scope.get("allow_unqualified_ipa") is False
            and scope.get("selected_declarations") == 2 and scope.get("native_tests_planned") == 2
            and scope.get("version") == VERSION and scope.get("build") == BUILD
            and scope.get("dispatch_event_sha256") == sha(ev / "dispatch-event.json")
            and event.get("validation_scope") == UI_SCOPE and event.get("build_ipa") in (False, "false")
            and event.get("allow_unqualified_ipa") in (False, "false")
            and event.get("prior_validation_run", "") in ("", None), "UI source phase/dispatch mismatch")
    sources = load(ev / "candidate-sources.json")
    require(sources.get("source_commit") == UI_BASE and sources.get("run_id") == str(UI_RUN)
            and sources.get("run_attempt") == "1" and isinstance(sources.get("files"), dict), "UI source receipt mismatch")
    if check_shared_sources:
        validate_followup_sources(sources["files"])
    packages = _verify_toolchain_and_deps(ev, UI_BASE, expected_packages=expected_packages)
    sim, linkage = _verify_simulator_and_linkage(ev, receipt["members"], UI_BASE, UI_RUN)
    parsed = _verify_reused_group("ui-1", UI_SPEC, ev, receipt["members"], expected_scope=UI_SCOPE,
                                  expected_source=UI_BASE, expected_run_id=UI_RUN,
                                  destination="platform=iOS Simulator,id=" + sim["udid"])
    verify_ui_xcresult(ev / "epub-freeze/ui-1/YueJingEPUBUITests.xcresult")
    require(parsed["passed"] == [UI_METHOD] and parsed["executions"] == 1, "UI reuse identity/count drift")
    return dict(run_id=str(UI_RUN), run_attempt="1", source_commit=UI_BASE, scope=UI_SCOPE,
                artifact_id=UI_ARTIFACT_ID, archive_sha256=UI_ARCHIVE_SHA256,
                workflow_conclusion=run["conclusion"], declarations_passed=1, executions_passed=1,
                groups=[parsed], packages=packages, simulator=sim, simulator_linkage_sha256=linkage)


def retain_ui_evidence(offline_ui=None, *, expected_packages=None, check_shared_sources=True):
    if offline_ui is None:
        run = github_api_json(f"/actions/runs/{UI_RUN}")
        artifact = _select_artifact_from_payload(github_api_json(f"/actions/runs/{UI_RUN}/artifacts"),
                                                 UI_ARTIFACT_NAME, UI_ARTIFACT_ID)
        validate_ui_run_and_artifact(run, artifact)
        archive = REUSED_STAGING / f"ui-{UI_RUN}.zip"
        github_download_artifact_zip(UI_ARTIFACT_ID, archive)
    else:
        run, artifact = _load_offline_run_and_artifact(offline_ui["run_json"], offline_ui["artifact_json"],
                                                      UI_ARTIFACT_NAME, UI_ARTIFACT_ID)
        validate_ui_run_and_artifact(run, artifact)
        archive = Path(offline_ui["zip_path"])
    require(archive.is_file() and not archive.is_symlink() and archive.stat().st_size == UI_ARCHIVE_BYTES
            and sha(archive) == UI_ARCHIVE_SHA256, "UI archive size/SHA256 mismatch")
    members = safe_zip_members(archive)  # all entries streamed: CRC, sizes, paths, SHA256
    folder = REUSED_OUT / f"ui-{UI_RUN}"
    folder.mkdir(parents=True, exist_ok=False)
    write(folder / "api-run.json", run)
    write(folder / "api-artifact.json", artifact)
    retained = extract_selected_members(archive, members, _ui_wanted_members(members), folder / "evidence")
    write(folder / "archive-receipt.json", dict(run_id=str(UI_RUN), run_attempt="1", source_commit=UI_BASE,
          artifact_id=UI_ARTIFACT_ID, archive_name=UI_ARTIFACT_NAME, archive_bytes=UI_ARCHIVE_BYTES,
          archive_sha256=UI_ARCHIVE_SHA256, member_count=len(members), members=members, retained_files=retained))
    return verify_ui_evidence(folder, expected_packages=expected_packages, check_shared_sources=check_shared_sources)


def verify_historical_evidence(hist_root, *, expected_packages=None, check_shared_sources=True):
    run, _, receipt = _verify_archive_receipt(
        hist_root,
        expected_run_id=HIST_RUN,
        expected_source_commit=BASE,
        expected_artifact_id=HIST_ARTIFACT_ID,
        expected_bytes=HIST_ARCHIVE_BYTES,
        expected_sha256=HIST_ARCHIVE_SHA256,
    )
    validate_historical_run_and_artifact(run, load(hist_root / "api-artifact.json"))
    require(run.get("workflow_id") == WORKFLOW_ID and run.get("event") == "workflow_dispatch"
            and run.get("head_branch") == "main" and run.get("status") == "completed"
            and run.get("conclusion") in ("failure", "success"),
            "Saved historical API run mismatch")
    ev_dir = hist_root / "evidence"
    freeze_dir = ev_dir / "epub-freeze"
    require(freeze_dir.is_dir() and not freeze_dir.is_symlink(), "Missing historical epub-freeze evidence")
    actual_groups = {p.name for p in freeze_dir.iterdir()}
    require(not (actual_groups & FORBIDDEN_HIST_GROUPS),
            "Forbidden failed historical groups present: " + repr(sorted(actual_groups & FORBIDDEN_HIST_GROUPS)))
    require(actual_groups == set(HIST_GROUPS), "Historical group set mismatch")

    hist_scope = load(ev_dir / "epub-freeze-scope.json")
    require(hist_scope.get("scope") == HIST_SCOPE
            and hist_scope.get("source_commit") == BASE
            and str(hist_scope.get("run_id")) == str(HIST_RUN)
            and str(hist_scope.get("run_attempt")) == HIST_ATTEMPT
            and hist_scope.get("version") == VERSION
            and hist_scope.get("build") == BUILD,
            "Historical scope provenance mismatch")
    hist_sources = load(ev_dir / "candidate-sources.json")
    require(hist_sources.get("source_commit") == BASE
            and str(hist_sources.get("run_id")) == str(HIST_RUN)
            and str(hist_sources.get("run_attempt")) == HIST_ATTEMPT
            and isinstance(hist_sources.get("files"), dict),
            "Historical candidate-sources provenance mismatch")
    if check_shared_sources:
        current_files = v.candidate_files()
        require(set(hist_sources["files"]) - ALLOWED == set(current_files) - ALLOWED,
                "Shared source inventory drifted relative to historical baseline")
        for name, expected_sha in hist_sources["files"].items():
            if name not in ALLOWED:
                require(current_files.get(name) == expected_sha, "Shared source file drifted: " + name)

    packages = _verify_toolchain_and_deps(ev_dir, BASE, expected_packages=expected_packages)
    sim, sim_linkage_sha = _verify_simulator_and_linkage(ev_dir, receipt["members"], BASE, HIST_RUN)
    eff_domain = load(ev_dir / "effective-test-settings.json").get("ReaderDomainTests")
    compat._validate_domain_effective_settings(eff_domain)

    destination = "platform=iOS Simulator,id=" + sim["udid"]
    groups = []
    for group, spec in HIST_GROUPS.items():
        parsed = _verify_reused_group(
            group, spec, ev_dir, receipt["members"],
            expected_scope=HIST_SCOPE, expected_source=BASE, expected_run_id=HIST_RUN, destination=destination,
        )
        groups.append(parsed)
    passed_names = [name for g in groups for name in g["passed"]]
    require(len(passed_names) == len(set(passed_names)) == REUSED_DECLARATIONS
            and not (set(passed_names) & FORBIDDEN_HIST_CASES)
            and sum(g["executions"] for g in groups) == REUSED_EXECUTIONS,
            "Historical 35 reused expansion count mismatch")
    return dict(
        run_id=str(HIST_RUN),
        run_attempt=HIST_ATTEMPT,
        source_commit=BASE,
        scope=HIST_SCOPE,
        artifact_id=HIST_ARTIFACT_ID,
        archive_sha256=HIST_ARCHIVE_SHA256,
        workflow_conclusion=run.get("conclusion"),
        excluded_failed_groups=sorted(FORBIDDEN_HIST_GROUPS),
        declarations_passed=REUSED_DECLARATIONS,
        executions_passed=REUSED_EXECUTIONS,
        simulator=sim,
        simulator_linkage_sha256=sim_linkage_sha,
        packages=packages,
        groups=groups,
    )


def inspect_prior_evidence(prior_root, scope, *, expected_packages=None, check_shared_sources=True):
    """Verify prior validation provenance strictly; report per-case statuses separately."""
    prior_id = scope["prior_validation_run"]
    run, artifact, receipt = _verify_archive_receipt(
        prior_root,
        expected_run_id=prior_id,
        expected_source_commit=scope["source_commit"],
    )
    validate_prior_run_and_artifact(prior_id, run, artifact, scope["source_commit"], scope["run_id"])
    for name in (f"historical-{HIST_RUN}", f"ui-{UI_RUN}"):
        bound_root = prior_root.parent / name
        prefix = "reused-evidence/" + name + "/"
        expected = {p[len(prefix):]: meta for p, meta in receipt["members"].items() if p.startswith(prefix)}
        actual = {}
        for path in bound_root.rglob("*"):
            require(not path.is_symlink(), "Symlink in bound reuse")
            if path.is_file():
                actual[path.relative_to(bound_root).as_posix()] = dict(bytes=path.stat().st_size, sha256=sha(path))
        require(expected and actual == expected, "Bound reuse differs from same-source prior archive: " + name)
    verify_historical_evidence(prior_root.parent / f"historical-{HIST_RUN}",
                               expected_packages=expected_packages, check_shared_sources=check_shared_sources)
    verify_ui_evidence(prior_root.parent / f"ui-{UI_RUN}",
                       expected_packages=expected_packages, check_shared_sources=check_shared_sources)
    ev_dir = prior_root / "evidence"
    native_groups = {m.split('/')[1] for m in receipt["members"] if m.startswith('epub-freeze/')}
    require(native_groups == set(GROUPS), "Prior validation contains missing/extra native groups")
    prior_scope = load(ev_dir / "epub-freeze-scope.json")
    require(prior_scope.get("selected") == {g: s["cases"] for g, s in GROUPS.items()}
            and type(prior_scope.get("selected_declarations")) is int
            and prior_scope.get("selected_declarations") == TOTAL
            and type(prior_scope.get("native_tests_planned")) is int
            and prior_scope.get("native_tests_planned") == EXECUTIONS
            and prior_scope.get("combined_target_declarations") == COMBINED_TOTAL
            and prior_scope.get("combined_target_executions") == COMBINED_EXECUTIONS,
            "Prior validation selection/count drift")
    raw_event_path = ev_dir / "dispatch-event.json"
    require(raw_event_path.is_file() and not raw_event_path.is_symlink(), "Prior run missing raw dispatch-event.json")
    require(sha(raw_event_path) == prior_scope.get("dispatch_event_sha256"), "Prior dispatch-event hash mismatch")
    raw_event = load(raw_event_path)
    raw_inputs = raw_event.get("inputs")
    require(isinstance(raw_inputs, dict)
            and raw_inputs.get("validation_scope") == SCOPE
            and raw_inputs.get("prior_validation_run", "") in ("", None)
            and raw_inputs.get("build_ipa", False) in (False, "false")
            and raw_inputs.get("allow_unqualified_ipa", False) in (False, "false"),
            "Prior run raw dispatch event was not an initial validation phase")
    require(prior_scope.get("scope") == SCOPE
            and prior_scope.get("phase") == "validation"
            and prior_scope.get("prior_validation_run") == ""
            and prior_scope.get("build_ipa") is False
            and prior_scope.get("allow_unqualified_ipa") is False
            and prior_scope.get("source_commit") == scope["source_commit"]
            and prior_scope.get("baseline_commit") == BASE
            and str(prior_scope.get("run_id")) == str(prior_id)
            and str(prior_scope.get("run_attempt")) == "1"
            and prior_scope.get("version") == VERSION
            and prior_scope.get("build") == BUILD,
            "Prior run scope receipt is not a matching validation phase")

    prior_sources = load(ev_dir / "candidate-sources.json")
    require(prior_sources.get("source_commit") == scope["source_commit"]
            and str(prior_sources.get("run_id")) == str(prior_id)
            and str(prior_sources.get("run_attempt")) == "1",
            "Prior candidate-sources provenance mismatch")
    if check_shared_sources:
        require(prior_sources.get("files") == v.candidate_files(), "Prior candidate files differ from current checkout")

    packages = _verify_toolchain_and_deps(ev_dir, scope["source_commit"], expected_packages=expected_packages)

    # Check individual cases and simulator/linkage without erasing failures.
    case_rows = []
    parsed_groups = []
    errors = []
    sim = None
    sim_linkage_sha = None
    try:
        sim, sim_linkage_sha = _verify_simulator_and_linkage(ev_dir, receipt["members"], scope["source_commit"], prior_id)
    except (ValueError, OSError, KeyError, TypeError) as error:
        errors.append("prior-simulator-linkage: " + str(error))

    if run.get("conclusion") != "success":
        errors.append("prior-run-conclusion: " + repr(run.get("conclusion")))
    if (ev_dir / "case-scheduling-error.json").exists():
        errors.append("prior-case-scheduling-error")

    destination = ("platform=iOS Simulator,id=" + sim["udid"]) if sim else None
    for group, spec in GROUPS.items():
        folder = ev_dir / "epub-freeze" / group
        row = dict(group=group, target=spec["target"], case=spec["cases"][0], kind=spec["kind"],
                   planned_executions=1, status="not_run", reason="prior 中未执行或缺失证据",
                   executed_count=None, execution_count_status="unknown")
        try:
            failure_path = folder / "failure.json"
            execution_path = folder / "execution.json"
            if failure_path.exists():
                fail = load(failure_path)
                row.update(status="error", reason=fail.get("error", "prior failure"))
            if execution_path.exists():
                ex = load(execution_path)
                row.update(native_exit=ex.get("native_exit"), timed_out=ex.get("timed_out"))
                if ex.get("timed_out"):
                    row.update(status="timed_out", reason="prior 执行超时")
                elif ex.get("native_exit") != 0:
                    row.update(status="failed", reason="prior 原生执行失败")
                elif failure_path.exists():
                    pass
                elif destination is None:
                    row.update(status="error", reason="prior 缺少有效模拟器或WebKit linkage 证据")
                else:
                    parsed = _verify_reused_group(
                        group, spec, ev_dir, receipt["members"],
                        expected_scope=SCOPE, expected_source=scope["source_commit"],
                        expected_run_id=prior_id, destination=destination,
                    )
                    parsed_groups.append(parsed)
                    row.update(status="passed", reason="prior 原始事件与通过回执一致",
                               executed_count=parsed["executions"], execution_count_status="known")
            elif failure_path.exists():
                row.update(status="blocked")
        except (ValueError, OSError, KeyError, TypeError) as error:
            row.update(status="error", reason="prior 证据无效：" + str(error))
            errors.append(group + ": " + str(error))
        if row["status"] != "passed":
            errors.append(group + ": " + row["status"])
        case_rows.append(row)

    gate_path = ev_dir / "epub-freeze-gate.json"
    if not gate_path.is_file():
        errors.append("missing prior epub-freeze-gate.json")
    else:
        try:
            prior_gate = load(gate_path)
            require(prior_gate.get("scope") == SCOPE
                    and prior_gate.get("phase") == "validation"
                    and prior_gate.get("qualification") == VALIDATION_QUALIFICATION
                    and prior_gate.get("source_commit") == scope["source_commit"]
                    and str(prior_gate.get("run_id")) == str(prior_id)
                    and type(prior_gate.get("native_tests_executed_this_run")) is int
                    and prior_gate.get("native_tests_executed_this_run") == EXECUTIONS
                    and prior_gate.get("groups") == parsed_groups
                    and prior_gate.get("reused_native_passed") == ALL_REUSED_EXECUTIONS
                    and prior_gate.get("verified_declarations") == COMBINED_TOTAL
                    and prior_gate.get("run_attempt") == "1"
                    and prior_gate.get("verified_passed") == COMBINED_EXECUTIONS
                    and prior_gate.get("combined_verified_passed") == COMBINED_EXECUTIONS,
                    "Prior gate receipt fields mismatch")
        except (ValueError, OSError, KeyError, TypeError) as error:
            errors.append("prior-gate: " + str(error))

    passed = not errors and len(parsed_groups) == len(GROUPS)
    return dict(
        run_id=str(prior_id),
        run_attempt="1",
        source_commit=scope["source_commit"],
        scope=SCOPE,
        artifact_id=artifact["id"],
        archive_sha256=receipt["archive_sha256"],
        workflow_conclusion=run.get("conclusion"),
        passed=passed,
        errors=errors,
        declarations_passed=len(parsed_groups) if passed else None,
        executions_passed=sum(g["executions"] for g in parsed_groups) if passed else None,
        simulator=sim,
        simulator_boot_sha256=sha(ev_dir / "simulator-boot.json") if (ev_dir / "simulator-boot.json").is_file() else None,
        simulator_linkage_sha256=sim_linkage_sha,
        packages=packages,
        groups=parsed_groups,
        case_rows=case_rows,
    )


def _historical_wanted_members(members):
    wanted = {
        "candidate-sources.json",
        "epub-freeze-scope.json",
        "toolchain.log",
        "xcodegen.log",
        "dependency-resolution.json",
        "Package.resolved",
        "effective-test-settings.json",
        "simulator-selection.json",
        "simulator-boot.json",
        "webkit-simulator-linkage/verification.json",
    }
    for name in members:
        if name.startswith("webkit-simulator-linkage/nm-") and name.endswith(".log"):
            wanted.add(name)
    for group, spec in HIST_GROUPS.items():
        target = spec["target"]
        base = f"epub-freeze/{group}/"
        wanted.update({
            base + "selection.json",
            base + "execution.json",
            base + "counts.json",
            base + f"{target}.log",
            base + f"{target}-settings.json",
            base + f"{target}.xcresult/Info.plist",
        })
        if any(c in inventory.PARAMETERIZED for c in spec["cases"]):
            wanted.add(base + "xcresult-tests.json")
    return wanted


def _prior_wanted_members(members):
    wanted = {
        "epub-freeze-scope.json",
        "dispatch-event.json",
        "candidate-sources.json",
        "toolchain.log",
        "xcodegen.log",
        "dependency-resolution.json",
    }
    for optional in (
        "Package.resolved",
        "effective-test-settings.json",
        "simulator-selection.json",
        "simulator-boot.json",
        "webkit-simulator-linkage/verification.json",
        "case-results.json",
        "epub-freeze-gate.json",
        "case-scheduling-error.json",
    ):
        if optional in members:
            wanted.add(optional)
    for name in members:
        if name.startswith("webkit-simulator-linkage/nm-") and name.endswith(".log"):
            wanted.add(name)
    for group, spec in GROUPS.items():
        target = spec["target"]
        base = f"epub-freeze/{group}/"
        for candidate in (
            base + "selection.json",
            base + "execution.json",
            base + "counts.json",
            base + "failure.json",
            base + f"{target}.log",
            base + f"{target}-settings.json",
            base + f"{target}.xcresult/Info.plist",
            base + "xcresult-tests.json",
        ):
            if candidate in members:
                wanted.add(candidate)
    return wanted


def _load_offline_run_and_artifact(run_json_path, artifact_json_path, expected_name, expected_id=None):
    run = load(Path(run_json_path))
    artifact_payload = load(Path(artifact_json_path))
    artifact = _select_artifact_from_payload(artifact_payload, expected_name, expected_id=expected_id)
    return run, artifact


def _verify_live_historical_domain11_xcresult(zip_path):
    """Cross-check domain-11 parameter export against real extracted xcresult on macOS."""
    if sys.platform != "darwin" or not shutil.which("xcrun"):
        return
    prefix = "epub-freeze/domain-11/ReaderDomainTests.xcresult/"
    stage_bundle = REUSED_STAGING / "domain-11-bundle"
    if stage_bundle.exists():
        shutil.rmtree(stage_bundle)
    try:
        stage_bundle.mkdir(parents=True, exist_ok=True)
        resolved_root = stage_bundle.resolve()
        with zipfile.ZipFile(zip_path) as source:
            for name in source.namelist():
                if name.startswith(prefix) and not name.endswith("/"):
                    target = (stage_bundle / name).resolve()
                    require(target.is_relative_to(resolved_root), "Escaping domain-11 bundle path")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(source.read(name))
            raw_export = source.read("epub-freeze/domain-11/xcresult-tests.json")
        live = subprocess.check_output(
            ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(stage_bundle / prefix.rstrip("/"))],
            timeout=60,
        )
        require(json.loads(live) == json.loads(raw_export), "Historical domain-11 xcresult export drift")
    finally:
        if stage_bundle.exists():
            shutil.rmtree(stage_bundle, ignore_errors=True)


def reuse_evidence(
    *,
    require_dependencies=True,
    offline_historical=None,
    offline_ui=None,
    offline_prior=None,
    check_shared_sources=True,
    verify_live_bundle=True,
):
    """Fetch, verify, and retain minimal reused evidence in OUT/reused-evidence.

    offline_historical / offline_prior are explicit function/CLI parameters for local
    replay only; environment variables can never bypass GitHub API verification.
    """
    scope = live_scope()
    expected_packages = None
    if require_dependencies:
        expected_packages = compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=False)
    if scope["phase"] == "validation":
        require(offline_prior is None, "Validation phase does not accept offline prior replay")
    else:
        require(offline_historical is None, "Delivery phase must verify historical evidence bound inside prior artifact")
        require(offline_ui is None, "Delivery must use UI evidence bound inside prior validation")
    require(not REUSED_OUT.exists(), "Existing reused evidence; use a fresh dispatch")
    REUSED_OUT.mkdir(parents=True)

    if scope["phase"] == "validation":
        if offline_historical is not None:
            zip_path = Path(offline_historical["zip_path"])
            run, artifact = _load_offline_run_and_artifact(
                offline_historical["run_json"], offline_historical["artifact_json"],
                HIST_ARTIFACT_NAME, expected_id=HIST_ARTIFACT_ID,
            )
            validate_historical_run_and_artifact(run, artifact)
        else:
            run = github_api_json(f"/actions/runs/{HIST_RUN}")
            artifacts_payload = github_api_json(f"/actions/runs/{HIST_RUN}/artifacts")
            artifact = _select_artifact_from_payload(artifacts_payload, HIST_ARTIFACT_NAME, expected_id=HIST_ARTIFACT_ID)
            validate_historical_run_and_artifact(run, artifact)
            zip_path = REUSED_STAGING / f"hist-{HIST_RUN}.zip"
            github_download_artifact_zip(HIST_ARTIFACT_ID, zip_path)
        require(zip_path.is_file() and not zip_path.is_symlink()
                and zip_path.stat().st_size == HIST_ARCHIVE_BYTES
                and sha(zip_path) == HIST_ARCHIVE_SHA256,
                "Historical archive size/SHA256 mismatch")
        members = safe_zip_members(zip_path)
        hist_dir = REUSED_OUT / f"historical-{HIST_RUN}"
        hist_dir.mkdir(parents=True)
        write(hist_dir / "api-run.json", run)
        write(hist_dir / "api-artifact.json", artifact)
        retained = extract_selected_members(zip_path, members, _historical_wanted_members(members), hist_dir / "evidence")
        if verify_live_bundle and offline_historical is None:
            _verify_live_historical_domain11_xcresult(zip_path)
        write(hist_dir / "archive-receipt.json", dict(
            run_id=str(HIST_RUN),
            run_attempt=HIST_ATTEMPT,
            source_commit=BASE,
            artifact_id=HIST_ARTIFACT_ID,
            artifact_name=HIST_ARTIFACT_NAME,
            archive_bytes=HIST_ARCHIVE_BYTES,
            archive_sha256=HIST_ARCHIVE_SHA256,
            member_count=len(members),
            members=members,
            retained_files=retained,
        ))
        hist_summary = verify_historical_evidence(
            hist_dir, expected_packages=expected_packages, check_shared_sources=check_shared_sources,
        )
        ui_summary = retain_ui_evidence(offline_ui, expected_packages=expected_packages,
                                       check_shared_sources=check_shared_sources)
        gate_receipt = dict(
            scope=SCOPE,
            phase="validation",
            source_commit=scope["source_commit"],
            run_id=scope["run_id"],
            run_attempt="1",
            passed=True,
            provenance_valid=True,
            reused_native_passed=ALL_REUSED_EXECUTIONS,
            reused_declarations=ALL_REUSED_DECLARATIONS,
            reused_historical_passed=REUSED_EXECUTIONS,
            reused_prior_passed=None,
            historical=hist_summary,
            ui=ui_summary,
            prior=None,
        )
        write(REUSED_GATE_JSON, gate_receipt)
        return gate_receipt

    # Delivery fetches only a successful same-source validation: Host1 + bound historical35 + UI1.
    prior_id = scope["prior_validation_run"]
    expected_prior_name = f"task3-evidence-{prior_id}-{scope['source_commit']}"
    if offline_prior is not None:
        prior_zip = Path(offline_prior["zip_path"])
        prior_run, prior_artifact = _load_offline_run_and_artifact(
            offline_prior["run_json"], offline_prior["artifact_json"], expected_prior_name,
        )
        validate_prior_run_and_artifact(prior_id, prior_run, prior_artifact, scope["source_commit"], scope["run_id"])
    else:
        prior_run = github_api_json(f"/actions/runs/{prior_id}")
        prior_artifacts = github_api_json(f"/actions/runs/{prior_id}/artifacts")
        prior_artifact = _select_artifact_from_payload(prior_artifacts, expected_prior_name)
        validate_prior_run_and_artifact(prior_id, prior_run, prior_artifact, scope["source_commit"], scope["run_id"])
        prior_zip = REUSED_STAGING / f"prior-{prior_id}.zip"
        github_download_artifact_zip(prior_artifact["id"], prior_zip)
    actual_prior_sha = sha(prior_zip)
    require(prior_zip.is_file() and not prior_zip.is_symlink()
            and prior_zip.stat().st_size == prior_artifact["size_in_bytes"]
            and "sha256:" + actual_prior_sha == prior_artifact["digest"],
            "Prior archive size/SHA256 mismatch")
    prior_members = safe_zip_members(prior_zip)
    hist_prefix = f"reused-evidence/historical-{HIST_RUN}/"
    hist_member_names = {m for m in prior_members if m.startswith(hist_prefix)}
    require(hist_member_names, "Prior validation run artifact lacks bound historical 35 evidence")

    prior_dir = REUSED_OUT / f"prior-{prior_id}"
    prior_dir.mkdir(parents=True)
    write(prior_dir / "api-run.json", prior_run)
    write(prior_dir / "api-artifact.json", prior_artifact)
    retained_prior = extract_selected_members(prior_zip, prior_members, _prior_wanted_members(prior_members), prior_dir / "evidence")
    hist_dir = REUSED_OUT / f"historical-{HIST_RUN}"
    # Extract historical-42954931349 files preserving their internal layout.
    hist_dir.mkdir(parents=True)
    resolved_hist = hist_dir.resolve()
    with zipfile.ZipFile(prior_zip) as source:
        for member_name in sorted(hist_member_names):
            rel_inside = member_name[len(hist_prefix):]
            require(rel_inside and not rel_inside.startswith("/"), "Invalid historical member inside prior archive")
            target = (hist_dir / rel_inside).resolve()
            require(target.is_relative_to(resolved_hist), "Escaping historical path inside prior archive")
            target.parent.mkdir(parents=True, exist_ok=True)
            data = source.read(member_name)
            require(dict(bytes=len(data), sha256=compat.digest_bytes(data)) == prior_members[member_name],
                    "Prior archive historical member mismatch: " + member_name)
            with target.open("xb") as out_stream:
                out_stream.write(data)
    ui_dir = REUSED_OUT / f"ui-{UI_RUN}"
    ui_prefix = f"reused-evidence/ui-{UI_RUN}/"
    ui_names = {m for m in prior_members if m.startswith(ui_prefix)}
    require(ui_names, "Prior validation lacks bound UI evidence")
    # Secure extraction verifies every byte against the outer archive manifest.
    extract_selected_members(prior_zip, prior_members, ui_names, REUSED_STAGING / f"bound-ui-{prior_id}")
    shutil.copytree(REUSED_STAGING / f"bound-ui-{prior_id}" / ui_prefix, ui_dir)
    ui_summary = verify_ui_evidence(ui_dir, expected_packages=expected_packages,
                                    check_shared_sources=check_shared_sources)
    write(prior_dir / "archive-receipt.json", dict(
        run_id=str(prior_id),
        run_attempt="1",
        source_commit=scope["source_commit"],
        artifact_id=prior_artifact["id"],
        artifact_name=expected_prior_name,
        archive_bytes=prior_artifact["size_in_bytes"],
        archive_sha256=actual_prior_sha,
        member_count=len(prior_members),
        members=prior_members,
        retained_files=retained_prior,
    ))

    # Both reuse sources must remain bound before qualifying the prior full Host case.
    hist_summary = verify_historical_evidence(
        hist_dir, expected_packages=expected_packages, check_shared_sources=check_shared_sources,
    )
    prior_summary = inspect_prior_evidence(
        prior_dir, scope, expected_packages=expected_packages, check_shared_sources=check_shared_sources,
    )
    gate_receipt = dict(
        scope=SCOPE,
        phase="delivery",
        source_commit=scope["source_commit"],
        run_id=scope["run_id"],
        run_attempt="1",
        passed=prior_summary["passed"],
        provenance_valid=True,
        reused_native_passed=(ALL_REUSED_EXECUTIONS + EXECUTIONS) if prior_summary["passed"] else None,
        reused_declarations=COMBINED_TOTAL if prior_summary["passed"] else None,
        reused_historical_passed=REUSED_EXECUTIONS,
        reused_prior_passed=EXECUTIONS if prior_summary["passed"] else None,
        errors=prior_summary["errors"],
        historical=hist_summary,
        ui=ui_summary,
        prior=prior_summary,
    )
    write(REUSED_GATE_JSON, gate_receipt)
    require(prior_summary["passed"], "Prior validation run did not pass all required checks: " + "; ".join(prior_summary["errors"]))
    return gate_receipt


# ---------------------------------------------------------------------------
# Summary & Strict Qualification / Delivery Gates
# ---------------------------------------------------------------------------

def _optional_json(path):
    if not path.exists() and not path.is_symlink():
        return None
    require(path.is_file() and not path.is_symlink(), "Invalid report evidence path")
    return load(path)


def _detect_phase_for_summary():
    try:
        frozen = _optional_json(SCOPE_JSON)
        if frozen and frozen.get("phase") in ("validation", "delivery"):
            return frozen["phase"], frozen.get("prior_validation_run", "")
    except (ValueError, OSError):
        pass
    try:
        reused_gate = _optional_json(REUSED_GATE_JSON)
        if reused_gate and reused_gate.get("phase") in ("validation", "delivery"):
            prior = (reused_gate.get("prior") or {}).get("run_id", "") if reused_gate["phase"] == "delivery" else ""
            return reused_gate["phase"], prior
    except (ValueError, OSError):
        pass
    prior = os.environ.get("PRIOR_VALIDATION_RUN", "")
    return ("delivery" if prior else "validation"), prior

def _summarize_historical_reuse():
    hist_dir = REUSED_OUT / f"historical-{HIST_RUN}"
    if not hist_dir.exists():
        return dict(status="not_verified", verified_passed=None, declarations_passed=None,
                    cases=[], error="尚未核验历史35项证据")
    try:
        summary = verify_historical_evidence(hist_dir, expected_packages=None, check_shared_sources=True)
        rows = [
            dict(group=g["group"], target=HIST_GROUPS[g["group"]]["target"],
                 case=g["passed"][0], kind=HIST_GROUPS[g["group"]]["kind"],
                 planned_executions=g["executions"], status="reused_passed",
                 reason="历史42954931349通过证据已核验复用")
            for g in summary["groups"]
        ]
        return dict(status="passed", verified_passed=REUSED_EXECUTIONS,
                    declarations_passed=REUSED_DECLARATIONS, cases=rows, error=None)
    except (ValueError, OSError, KeyError, TypeError) as error:
        return dict(status="failed", verified_passed=None, declarations_passed=None,
                    cases=[], error=str(error))


def _summarize_ui_reuse():
    try:
        result = verify_ui_evidence(REUSED_OUT / f"ui-{UI_RUN}")
        return dict(status="passed", verified_passed=result["executions_passed"], error=None)
    except (ValueError, OSError, KeyError, TypeError) as error:
        return dict(status="not_verified", verified_passed=None, error=str(error))


def _summarize_prior_reuse(prior_id):
    prior_dir = REUSED_OUT / f"prior-{prior_id}"
    if not prior_id or not prior_dir.exists():
        return dict(status="not_verified", verified_passed=None, declarations_passed=None,
                    cases=[], error="尚未核验prior验证run证据")
    try:
        scope = _optional_json(SCOPE_JSON) or dict(
            source_commit=os.environ.get("GITHUB_SHA", ""),
            run_id=os.environ.get("GITHUB_RUN_ID", ""),
            prior_validation_run=prior_id,
        )
        summary = inspect_prior_evidence(prior_dir, scope, expected_packages=None, check_shared_sources=True)
        return dict(status="passed" if summary["passed"] else "failed",
                    verified_passed=summary["executions_passed"] if summary["passed"] else None,
                    declarations_passed=summary["declarations_passed"] if summary["passed"] else None,
                    cases=summary["case_rows"], error="; ".join(summary["errors"]) if summary["errors"] else None)
    except (ValueError, OSError, KeyError, TypeError) as error:
        return dict(status="failed", verified_passed=None, declarations_passed=None,
                    cases=[], error=str(error))


def summarize(*, publish=False):
    """Diagnostic display only; qualification() independently revalidates every case."""
    phase, prior_id = _detect_phase_for_summary()
    rows = []
    if phase == "validation":
        for group, spec in GROUPS.items():
            folder = NATIVE_OUT / group
            case = spec["cases"][0]
            row = dict(group=group, target=spec["target"], case=case, kind=spec["kind"],
                       planned_executions=1, status="not_run", reason="尚未开始；检查前置准备、调度或取消状态")
            try:
                execution = _optional_json(folder / "execution.json")
                failure = _optional_json(folder / "failure.json")
                counts = _optional_json(folder / "counts.json")
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
                        row.update(status="passed", reason="本轮原始事件与通过回执一致；正式资格另行核验")
                    elif failure is None:
                        row.update(status="error", reason="执行已结束但缺少合格结果回执")
                elif failure is not None:
                    row.update(status="blocked", reason=failure["error"])
            except (ValueError, OSError, KeyError, TypeError) as error:
                row.update(status="error", reason="结果证据无效：" + str(error))
            rows.append(row)
        scheduling = _optional_json(OUT / "case-scheduling-error.json")
        if scheduling:
            for row in rows:
                if row["status"] == "not_run":
                    row.update(status="blocked", reason=scheduling["error"])
    else:
        scheduling = None

    hist_summary = _summarize_historical_reuse()
    ui_summary = _summarize_ui_reuse()
    verified_reuse = (hist_summary["verified_passed"] + ui_summary["verified_passed"]
                      if hist_summary["verified_passed"] is not None and ui_summary["verified_passed"] is not None else None)
    prior_summary = _summarize_prior_reuse(prior_id) if phase == "delivery" else None

    if phase == "validation":
        counts = {status: sum(row["status"] == status for row in rows)
                  for status in ("passed", "failed", "timed_out", "error", "blocked", "not_run")}
        native_executed_passed = EXECUTIONS if counts["passed"] == TOTAL else None
        reused_passed = verified_reuse
        combined_passed = (native_executed_passed + reused_passed) if (
            native_executed_passed is not None and reused_passed is not None
        ) else None
    else:
        counts = dict(passed=0, failed=0, timed_out=0, error=0, blocked=0, not_run=0)
        native_executed_passed = 0
        prior_passed = prior_summary["verified_passed"] if prior_summary else None
        hist_passed = verified_reuse
        reused_passed = (prior_passed + hist_passed) if (prior_passed is not None and hist_passed is not None) else None
        combined_passed = reused_passed

    # Full 15-item UI inventory showing both current selection and historical reuse separately.
    current_ui = {row["case"]: row for row in rows if row["kind"] == "ui"}
    prior_ui = {row["case"]: row for row in (prior_summary["cases"] if prior_summary else []) if row.get("kind") == "ui"}
    hist_ui = {row["case"]: row for row in hist_summary["cases"] if row.get("kind") == "ui"}
    ui_rows = []
    for target in ("YueJingEPUBUITests", "YueJingUITests"):
        for case in inventory.expected_names(target):
            if phase == "validation" and case in current_ui:
                cur_row = dict(current_ui[case])
                cur_row["current_selection"] = "selected"
                cur_row["historical_reuse"] = "excluded_previously_failed"
                ui_rows.append(cur_row)
            elif phase == "delivery" and case in prior_ui:
                p_row = dict(prior_ui[case])
                p_status = p_row["status"]
                ui_rows.append(dict(
                    target=target, case=case, group=p_row["group"], kind="ui",
                    status="reused_from_prior" if p_status == "passed" else p_status,
                    current_selection="reused_from_prior",
                    historical_reuse="excluded_previously_failed",
                    reason=("delivery阶段未本轮重跑；" + p_row["reason"]),
                ))
            elif case == UI_METHOD:
                bound = ui_summary["status"] == "passed" and (phase == "validation" or prior_summary["status"] == "passed")
                ui_rows.append(dict(
                    target=target, case=case, group="ui-1", kind="ui",
                    status="reused_ui" if bound else "reuse_unverified",
                    current_selection="reused_ui" if phase == "validation" else "reused_from_prior",
                    historical_reuse="excluded_previously_failed",
                    reason="Pinned 42974144689/UI1 only; overall source run failed; " + ("verified" if bound else "unverified"),
                ))
            elif case == "testEPUBProgressSurvivesExitAndProcessRelaunch":
                h_row = hist_ui.get(case)
                if h_row:
                    ui_rows.append(dict(
                        target=target, case=case, group="ui-2", kind="ui",
                        status="reused_historical",
                        current_selection="not_selected",
                        historical_reuse="reused_passed",
                        reason="本轮未选择；历史42954931349/ui-2通过证据已核验复用",
                    ))
                else:
                    ui_rows.append(dict(
                        target=target, case=case, group="ui-2", kind="ui",
                        status="reuse_unverified",
                        current_selection="not_selected",
                        historical_reuse=hist_summary["status"],
                        reason="本轮未选择；历史42954931349/ui-2复用证据未通过或尚未核验",
                    ))
            else:
                ui_rows.append(dict(
                    target=target, case=case,
                    status="not_selected",
                    current_selection="not_selected",
                    historical_reuse="not_reused",
                    reason="本轮未选择且未复用，未执行、不计通过",
                ))

    report = dict(
        scope=SCOPE,
        phase=phase,
        prior_validation_run=prior_id,
        source_commit=os.environ.get("GITHUB_SHA"),
        run_id=os.environ.get("GITHUB_RUN_ID"),
        selected_declarations=TOTAL if phase == "validation" else 0,
        planned_executions=EXECUTIONS if phase == "validation" else 0,
        native_tests_executed_this_run=native_executed_passed,
        reused_native_passed=reused_passed,
        reused_historical_passed=hist_summary["verified_passed"],
        reused_prior_passed=(prior_summary["verified_passed"] if prior_summary else None),
        combined_verified_passed=combined_passed,
        verified_passed=combined_passed,
        counts=counts,
        cases=rows,
        reused_historical=hist_summary,
        reused_prior=prior_summary,
        reused_ui=ui_summary,
        ui_inventory=ui_rows,
        scheduling_error=scheduling,
        qualification="DISPLAY_ONLY_NOT_RELEASE_QUALIFICATION",
    )

    def cell(value):
        return str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("|", "&#124;").replace("\n", " ").replace("\r", " ")

    labels = dict(
        passed="通过", failed="失败", timed_out="超时", error="证据/执行错误", blocked="阻塞",
        not_run="未执行", not_selected="未选择", reused_historical="历史复用通过",
        reused_from_prior="prior复用通过", reuse_unverified="复用未核验",
    )
    lines = [
        f"## EPUB Followup 定向验证结果（phase: {phase}）",
        "",
        f"- 本轮执行：{EXECUTIONS if phase == 'validation' else 0} 计划 / {native_executed_passed if native_executed_passed is not None else 'null'} 通过",
        f"- 历史复用（run {HIST_RUN}）：34 声明 / 35 展开 -> {hist_summary['verified_passed'] if hist_summary['verified_passed'] is not None else 'null'}（{hist_summary['status']}）",
    ]
    if phase == "delivery" and prior_summary is not None:
        lines.append(f"- Prior 复用（run {prior_id}）：1 声明 / 1 展开 -> {prior_summary['verified_passed'] if prior_summary['verified_passed'] is not None else 'null'}（{prior_summary['status']}）")
    lines.append(f"- UI 复用（run {UI_RUN}）：1 展开 -> {ui_summary['verified_passed']}（{ui_summary['status']}）")
    lines.append(f"- 组合确认通过：{combined_passed if combined_passed is not None else 'null'} / {COMBINED_EXECUTIONS}（仅作展示，正式资格另行门控）")
    lines.append("")
    if phase == "validation":
        lines += ["### 本轮 1 项完整 Host 执行", "", "| 项目 | 状态 | 说明 |", "|---|---|---|"]
        for row in rows:
            lines.append(f"| {cell(row['group'] + ': ' + row['case'])} | {labels.get(row['status'], row['status'])} | {cell(row['reason'])} |")
    elif prior_summary is not None:
        lines += [f"### Prior 验证 run {prior_id} 的 1 项复用结果", "", "| 项目 | 状态 | 说明 |", "|---|---|---|"]
        for row in prior_summary["cases"]:
            lines.append(f"| {cell(row['group'] + ': ' + row['case'])} | {labels.get(row['status'], row['status'])} | {cell(row['reason'])} |")
        if prior_summary["error"] and not prior_summary["cases"]:
            lines.append(f"| prior-{cell(prior_id)} | 失败 | {cell(prior_summary['error'])} |")
    if hist_summary["error"]:
        lines += ["", "历史 35 复用错误：" + cell(hist_summary["error"])]
    lines += ["", "### 完整 15 项 UI 清单（本轮选择 / 历史复用分别展示）", "",
              "| Target / 用例 | 当前选择 | 历史复用 | 状态 | 说明 |", "|---|---|---|---|---|"]
    for row in ui_rows:
        lines.append(
            f"| {cell(row['target'] + '/' + row['case'])} | {cell(row['current_selection'])} | "
            f"{cell(row['historical_reuse'])} | {labels.get(row['status'], row['status'])} | {cell(row['reason'])} |"
        )
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


def qualification():
    scope = live_scope()
    require(scope["scope"] == SCOPE, "Diagnostic fallback disabled")
    require(not (OUT / "native-test-gate.json").exists() and not (OUT / "epub-reading-gate.json").exists(), "Mixed qualification")
    packages = compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=False)
    require(REUSED_OUT.is_dir() and not REUSED_OUT.is_symlink() and REUSED_GATE_JSON.is_file(),
            "Missing reused historical/prior evidence gate")
    saved_reused = load(REUSED_GATE_JSON)
    hist_summary = verify_historical_evidence(REUSED_OUT / f"historical-{HIST_RUN}", expected_packages=packages, check_shared_sources=True)
    ui_summary = verify_ui_evidence(REUSED_OUT / f"ui-{UI_RUN}", expected_packages=packages, check_shared_sources=True)
    require(saved_reused.get("ui") == ui_summary and saved_reused.get("historical") == hist_summary,
            "Reused summary receipt drift")
    require(saved_reused.get("passed") is True
            and saved_reused.get("provenance_valid") is True
            and saved_reused.get("phase") == scope["phase"]
            and saved_reused.get("source_commit") == scope["source_commit"]
            and str(saved_reused.get("run_id")) == str(scope["run_id"])
            and saved_reused.get("reused_historical_passed") == REUSED_EXECUTIONS,
            "Reused evidence gate receipt mismatch")
    if scope["phase"] == "delivery":
        require(saved_reused.get("reused_native_passed") == ALL_REUSED_EXECUTIONS + EXECUTIONS
                and saved_reused.get("reused_prior_passed") == EXECUTIONS
                and saved_reused.get("prior", {}).get("run_id") == str(scope["prior_validation_run"]),
                "Delivery reused gate receipt mismatch")

    if scope["phase"] == "validation":
        require(saved_reused.get("reused_native_passed") == ALL_REUSED_EXECUTIONS
                and saved_reused.get("reused_declarations") == ALL_REUSED_DECLARATIONS,
                "Validation reuse count drift")
        require(not (OUT / "case-scheduling-error.json").exists() and
                not any((NATIVE_OUT / group / "failure.json").exists() for group in GROUPS),
                "Failed/blocked cases cannot qualify even if a counts receipt exists")
        sim = load(OUT / "simulator-selection.json")
        destination = "platform=iOS Simulator,id=" + sim["udid"]
        compat.validate_destination(destination, OUT)
        validate_linkage("simulator", scope)
        require(NATIVE_OUT.is_dir() and not NATIVE_OUT.is_symlink() and {p.name for p in NATIVE_OUT.iterdir()} == set(GROUPS),
                "Missing/extra groups")
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
        require(sum(g["declarations_passed"] for g in groups) == TOTAL and sum(g["executions"] for g in groups) == EXECUTIONS,
                "Combined current execution count differs")
        return dict(
            **scope,
            qualification=VALIDATION_QUALIFICATION,
            coverage="EPUB_TARGETED_NOT_FULL",
            native_tests_executed_this_run=EXECUTIONS,
            reused_native_passed=ALL_REUSED_EXECUTIONS,
            verified_passed=COMBINED_EXECUTIONS,
            combined_verified_passed=COMBINED_EXECUTIONS,
            verified_declarations=COMBINED_TOTAL,
            not_executed_this_run=237 - EXECUTIONS,
            unselected_executions=237 - COMBINED_EXECUTIONS,
            groups=groups,
            reused_historical=hist_summary,
            reused_ui=ui_summary,
            simulator=sim,
        )

    # Delivery phase: 0 native tests in this run; must not have current simulator/test outputs.
    require(not NATIVE_OUT.exists()
            and not (OUT / "simulator-selection.json").exists()
            and not (OUT / "simulator-boot.json").exists()
            and not (OUT / "webkit-simulator-linkage").exists(),
            "Delivery phase must not run simulator or native tests in this run")
    prior_summary = inspect_prior_evidence(
        REUSED_OUT / f"prior-{scope['prior_validation_run']}",
        scope, expected_packages=packages, check_shared_sources=True,
    )
    require(prior_summary["passed"], "Prior validation run failed strict qualification: " + "; ".join(prior_summary["errors"]))
    return dict(
        **scope,
        qualification=DELIVERY_QUALIFICATION,
        coverage="EPUB_TARGETED_NOT_FULL",
        native_tests_executed_this_run=0,
        reused_native_passed=ALL_REUSED_EXECUTIONS + EXECUTIONS,
        reused_historical_passed=REUSED_EXECUTIONS,
        reused_prior_passed=EXECUTIONS,
        verified_passed=COMBINED_EXECUTIONS,
        combined_verified_passed=COMBINED_EXECUTIONS,
        verified_declarations=COMBINED_TOTAL,
        not_executed_this_run=237,
        unselected_executions=237 - COMBINED_EXECUTIONS,
        groups=[],
        reused_historical=hist_summary,
        reused_ui=ui_summary,
        reused_prior=prior_summary,
        simulator=None,
    )


def validate_saved():
    actual = qualification()
    require(load(GATE_JSON) == actual, "Qualification receipt drift")
    return actual


def release_gate():
    result = validate_saved()
    is_delivery = result.get("phase") == "delivery"
    expected_qual = DELIVERY_QUALIFICATION if is_delivery else VALIDATION_QUALIFICATION
    expected_native = 0 if is_delivery else EXECUTIONS
    expected_reused = COMBINED_EXECUTIONS if is_delivery else ALL_REUSED_EXECUTIONS
    require(result.get("scope") == SCOPE
            and result.get("qualification") == expected_qual
            and result.get("native_tests_executed_this_run") == expected_native
            and result.get("reused_native_passed") == expected_reused
            and result.get("verified_passed") == result.get("combined_verified_passed") == COMBINED_EXECUTIONS
            and result.get("verified_declarations") == COMBINED_TOTAL
            and result.get("version") == VERSION and result.get("build") == BUILD
            and result.get("full_regression_passed") is False,
            "Formal release requires combined 37 verified passes")
    return result


def _verify_delivery_provenance(scope, packages):
    """Source, API, archive, and phase provenance checks; no diagnostic bypass."""
    require(not NATIVE_OUT.exists()
            and not (OUT / "simulator-selection.json").exists()
            and not (OUT / "simulator-boot.json").exists()
            and not (OUT / "webkit-simulator-linkage").exists(),
            "Delivery phase must not run simulator or native tests in this run")
    require(REUSED_GATE_JSON.is_file() and not REUSED_GATE_JSON.is_symlink(), "Missing reused-evidence-gate.json")
    saved_reused = load(REUSED_GATE_JSON)
    require(saved_reused.get("provenance_valid") is True
            and saved_reused.get("phase") == "delivery"
            and saved_reused.get("source_commit") == scope["source_commit"]
            and str(saved_reused.get("run_id")) == str(scope["run_id"]),
            "Delivery reused gate provenance mismatch")
    hist_dir = REUSED_OUT / f"historical-{HIST_RUN}"
    prior_dir = REUSED_OUT / f"prior-{scope['prior_validation_run']}"
    hist_summary = verify_historical_evidence(hist_dir, expected_packages=packages, check_shared_sources=True)
    verify_ui_evidence(REUSED_OUT / f"ui-{UI_RUN}", expected_packages=packages, check_shared_sources=True)
    prior_summary = inspect_prior_evidence(prior_dir, scope, expected_packages=packages, check_shared_sources=True)
    return hist_summary, prior_summary


def delivery_gate():
    """Admission only, not IPA success. Source/common/provenance prerequisites never fall back."""
    scope = live_scope()
    require(scope.get("allow_unqualified_ipa") is False, "Diagnostic IPA permission disabled")
    require(scope.get("phase") == "delivery" and scope.get("build_ipa") is True and bool(scope.get("prior_validation_run")),
            "Delivery packaging requires delivery phase with prior_validation_run and build_ipa=true")
    packages = compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=False)
    require((OUT / "app-build-exit-code.txt").read_text().strip() == "0", "Device App build did not pass")
    device_linkage = validate_linkage("device", scope)
    hist_summary, prior_summary = _verify_delivery_provenance(scope, packages)
    release_gate()
    # Recheck: source/run mutation can never be downgraded.
    require(live_scope() == scope, "Source/run changed during qualification")
    report = summarize()
    evidence = {}
    if REUSED_OUT.exists():
        require(not REUSED_OUT.is_symlink(), "Symlink reused evidence")
        for path in sorted(REUSED_OUT.rglob("*")):
            require(not path.is_symlink(), "Symlink reused evidence")
            if path.is_file():
                evidence[path.relative_to(OUT).as_posix()] = sha(path)
    for name in ("toolchain.log", "xcodegen.log", "dependency-resolution.json", "app-build.log",
                 "app-build-exit-code.txt", "epub-freeze-scope.json"):
        path = OUT / name
        require(path.is_file() and not path.is_symlink(), "Missing common evidence: " + name)
        evidence[name] = sha(path)
    for name in ("dispatch-event.json", "epub-freeze-gate.json", "case-results.json"):
        path = OUT / name
        if path.exists():
            require(path.is_file() and not path.is_symlink(), "Invalid supporting evidence: " + name)
            evidence[name] = sha(path)
    rows = prior_summary["case_rows"]
    known_prior = sum(row["executed_count"] or 0 for row in rows)
    unknown_prior = [row["group"] for row in rows if row["executed_count"] is None]
    known_total = ALL_REUSED_EXECUTIONS + known_prior
    require(live_scope() == scope, "Source/run changed while collecting package evidence")
    return dict(
        **scope,
        qualification=DELIVERY_QUALIFICATION,
        coverage="EPUB_TARGETED_NOT_FULL",
        strict_native_qualification="passed",
        diagnostic_reason=None,
        verified_passed=COMBINED_EXECUTIONS,
        combined_verified_passed=COMBINED_EXECUTIONS,
        verified_declarations=COMBINED_TOTAL,
        native_tests_executed_this_run=0,
        reused_native_passed=COMBINED_EXECUTIONS,
        reused_historical_passed=REUSED_EXECUTIONS,
        reused_prior_passed=EXECUTIONS,
        known_executions=known_total,
        unknown_execution_groups=unknown_prior,
        cases=rows,
        reused_historical=hist_summary,
        reused_prior=prior_summary,
        case_results_qualification=report["qualification"],
        evidence_sha256=evidence,
        device_linkage_sha256=device_linkage,
    )


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
    reuse_cmd = sub.add_parser("reuse")
    reuse_cmd.add_argument("--historical-zip", type=Path)
    reuse_cmd.add_argument("--historical-run-json", type=Path)
    reuse_cmd.add_argument("--historical-artifact-json", type=Path)
    reuse_cmd.add_argument("--ui-zip", type=Path)
    reuse_cmd.add_argument("--ui-run-json", type=Path)
    reuse_cmd.add_argument("--ui-artifact-json", type=Path)
    reuse_cmd.add_argument("--prior-zip", type=Path)
    reuse_cmd.add_argument("--prior-run-json", type=Path)
    reuse_cmd.add_argument("--prior-artifact-json", type=Path)
    reuse_cmd.add_argument("--skip-dependency-check", action="store_true")
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
        receipt = scope_receipt()
        raw_event = Path(os.environ["GITHUB_EVENT_PATH"]).read_bytes()
        require(compat.digest_bytes(raw_event) == receipt["dispatch_event_sha256"], "Dispatch event changed")
        with DISPATCH_EVENT_JSON.open("xb") as stream:
            stream.write(raw_event)
        write(SCOPE_JSON, receipt)
        print(json.dumps(receipt, indent=2))
    elif args.action == "reuse":
        offline_hist = None
        if args.historical_zip or args.historical_run_json or args.historical_artifact_json:
            require(args.historical_zip and args.historical_run_json and args.historical_artifact_json,
                    "Offline historical replay requires --historical-zip, --historical-run-json, and --historical-artifact-json")
            offline_hist = dict(zip_path=args.historical_zip, run_json=args.historical_run_json,
                                artifact_json=args.historical_artifact_json)
        offline_ui = None
        if args.ui_zip or args.ui_run_json or args.ui_artifact_json:
            require(args.ui_zip and args.ui_run_json and args.ui_artifact_json, "Offline UI replay needs all three --ui-* arguments")
            offline_ui = dict(zip_path=args.ui_zip, run_json=args.ui_run_json, artifact_json=args.ui_artifact_json)
        offline_prior = None
        if args.prior_zip or args.prior_run_json or args.prior_artifact_json:
            require(args.prior_zip and args.prior_run_json and args.prior_artifact_json,
                    "Offline prior replay requires --prior-zip, --prior-run-json, and --prior-artifact-json")
            offline_prior = dict(zip_path=args.prior_zip, run_json=args.prior_run_json,
                                 artifact_json=args.prior_artifact_json)
        receipt = reuse_evidence(
            require_dependencies=not args.skip_dependency_check,
            offline_historical=offline_hist,
            offline_ui=offline_ui,
            offline_prior=offline_prior,
        )
        print(json.dumps(receipt, indent=2))
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
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        raise SystemExit("EPUB followup release stopped: " + str(error))

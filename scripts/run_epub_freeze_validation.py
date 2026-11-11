"""Opening followup: 3 fresh declarations / 4 expansions plus pinned historical21.

Delivery executes zero tests and reuses a successful same-source followup4 plus
its single fixed historical21 chain. No arbitrary recursion or diagnostic IPA.
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

BASE = "d5fde953ca544deaecace0434a45b014ebd630b0"
SCOPE = "epub-opening-followup-3"
VERSION, BUILD = "0.2.15", "17"
TOTAL, EXECUTIONS = 3, 4
COMBINED_TOTAL, COMBINED_EXECUTIONS = 24, 25
HISTORICAL_TOTAL, HISTORICAL_EXECUTIONS = 21, 21
HISTORICAL_RUN = 43014129792
HISTORICAL_SOURCE = "3f16c2963f2d165f80500d9b23eb4036ff919260"
HISTORICAL_SCOPE = "epub-opening-continuity-24"
HISTORICAL_ARTIFACT = 13853970619
HISTORICAL_NAME = f"task3-evidence-{HISTORICAL_RUN}-{HISTORICAL_SOURCE}"
HISTORICAL_BYTES = 129375479
HISTORICAL_SHA256 = "20bcce9f3167691818fb454e2900de70a90de4734f4f77ee3e952e2ebd10f2e5"
HISTORICAL_FOLDER = f"historical-{HISTORICAL_RUN}"
INVENTORY_TOTAL, INVENTORY_EXECUTIONS = 241, 242
REPO = "wan780839395-cyber/YueJing"
WORKFLOW_ID = 398234793
WORKFLOW_PATH = ".github/workflows/task3-validate.yml"
VALIDATION_QUALIFICATION = "EPUB_OPENING_FOLLOWUP_3_NEW_4_REUSED_21_TARGETED_NATIVE"
DELIVERY_QUALIFICATION = "EPUB_OPENING_FOLLOWUP_DELIVERY_REUSED_25_TARGETED_NATIVE"
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

# The approved local candidate is pinned, not a blanket permission to change
# product code or weaken assertions inside the path allowlist.
CANDIDATE_SHA256 = {
    "App/EPUB/EPUBOpeningPresentation.swift": "85de679e4544922eefe4d04def4efc45e07b7e66be9e2b886f09762cedebab72",
    "App/EPUB/EPUBReaderScreen.swift": "78359c9e56fcc834763a53398d91ce284d035ec455201547ef3d1babd18b8799",
    "App/EPUB/EPUBReaderViewModel.swift": "329af097c9eb168d100224f13d3963b5396d61326bec6b64fddf39aeddf0f716",
    "App/Library/BookReadingRouteOwner.swift": "c583461103094ffa03ec2032a1d8387ba68a7cba250387af51272f3d1d670759",
    "Sources/ReaderDomain/EPUB/EPUBContentPool.swift": "58a3ce26db4a409e4cb595c3ae09857b564b1686c5d6c43b0c609b481ec2b62f",
    "Sources/ReaderDomain/EPUB/EPUBOpeningTimings.swift": "a3d52dbb2ade5b7b3e85f24abd85c60c7d202edf0fbed2f055fdba83bc9256c0",
    "Sources/ReaderDomain/EPUB/EPUBPublicationCache.swift": "54527e4d96ce2ac9c19fa2463ec3695f45af2c9d332eaeb6e9c6a7312ecfad2d",
    "Sources/ReaderDomain/EPUB/EPUBResourceStore.swift": "6cdfff729ac028abe6b430bc522d1adafc44f96943b2acdb1d76c4806349c04e",
    "Tests/ReaderDomainTests/EPUBReadyTests.swift": "6ee16926dc4579daa0a17550812e3d1a8cff5cd6924a7d5c481abc90f3d952ac",
    "Tests/YueJingEPUBUITests/EPUBFlowUITests.swift": "85e2c517498d630ef2a93399a5eaa8f79ee51460be0b1d4889ae52865439461d",
    "Tests/YueJingHostTests/EPUBReaderHostTests.swift": "10440e606ecb1e931c7993d351528625e0bf7e026f0b1665aeab72de7ead642f",
    "docs/EPUB_OPENING_PRESENTATION.md": "3474307453ee703bb29cfdedcd88c1050720213b15792c71a7a7e623c76a1b72",
    "scripts/check_epub_opening_presentation.py": "778cb4a28fec5ee5fc661cc0b351d794ad80ad4727657e2625738b7456a00ed0",
}
NEW = frozenset({"App/EPUB/EPUBOpeningPresentation.swift",
                 "scripts/check_epub_opening_presentation.py", "docs/EPUB_OPENING_PRESENTATION.md"})
ALLOWED = frozenset(CANDIDATE_SHA256) | {
    "project.yml", "App/AppVersion.swift", ".github/workflows/task3-validate.yml",
    "scripts/run_epub_freeze_validation.py", "scripts/check_epub_freeze_validation.py",
    "docs/EPUB_FREEZE_RELEASE.md",
}
HISTORICAL_FILES = {
    "ReaderDomainTests/EPUBReadyTests.swift": [
        "readyImportColdReaderDoesNotDependOnParkedLease",
        "legacyMigrationPreservesProgressPreferencesAndOriginal",
        "readyUnvisitedNodeDamageIsDetectedBeforeOpenAndRepairedWithLeaseIsolation",
        "readyPublicationRollbackAndReconciliationProtectLiveVersions",
        "readyManifestMutationCannotBeBlessedByRepair",
        "boundedParallelVerificationMatchesSerialIntegrityAndCancellation",
        "resourceVerificationTimingsAreBoundedAndIdentityFree",
        "measuredResourceVerificationMatchesSerialFailuresAndCancellation",
        "readyResourceTimingsDistinguishDiskRegistrationFromVerifiedReuse"],
    "ReaderDomainTests/EPUBLibraryTests.swift": [
        "epubOriginalArchiveAndValidatedResourcesSurviveReopen",
        "epubWarmReopenTransfersFolderWithFreshSessionPositionAndPreferences",
        "epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime",
        "epubFailureAfterWarmTakeDeletesTransferredFolderNotAnUnusedDestination",
        "epubBooksAndTXTStayIsolated"],
    "YueJingHostTests/EPUBReaderHostTests.swift": [
        "epubOpeningObservationRejectsStaleFramesAndLabelsColdAdmission",
        "epubOpeningRouteStartsOnceAndObservesMountedPresentation",
        "epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position",
        "epubSecurityRejectsScriptsFormsExternalResourcesAndKeepsIsolatedLocatorWorking",
        "epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks",
        "epubCompatibilityWebKitLoadsStaticImagePageAndRestoresAnchor",
        "epubRecentBooksReusePagesAcrossSwitchesAndEvictOnlyIdleLRU"],
    "YueJingEPUBUITests/EPUBFlowUITests.swift": [
        "testEPUBShelfCoverAndDirectoryCrossChapterNavigation",
        "testEPUBProgressSurvivesExitAndProcessRelaunch",
        "testEPUBTypographyNoCoverFallbackAndTXTIsolation"],
}
HISTORICAL_GROUPS = {}
for _kind, _target in (("domain", "ReaderDomainTests"), ("host", "YueJingHostTests"), ("ui", "YueJingEPUBUITests")):
    _pairs = [(rel, n) for rel, names in HISTORICAL_FILES.items() if rel.startswith(_target + "/") for n in names]
    for _index, _pair in enumerate(_pairs, 1):
        HISTORICAL_GROUPS[_kind + "-" + str(_index)] = dict(kind=_kind, target=_target, timeout=480,
                                                           pairs=[_pair], cases=[_pair[1]])
del _kind, _target, _pairs, _index, _pair
GROUPS = {key: HISTORICAL_GROUPS[key] for key in ("domain-12", "host-2", "ui-2")}
REUSED_GROUPS = {key: spec for key, spec in HISTORICAL_GROUPS.items() if key not in GROUPS}
SELECTED_FILES = {rel: [name for spec in GROUPS.values() for path, name in spec["pairs"] if path == rel]
                  for rel in HISTORICAL_FILES if any(path == rel for spec in GROUPS.values() for path, _ in spec["pairs"])}
require, load, write, sha = v.require, compat.load_json, compat.write_new, compat.digest_path


def reviewed_inventory():
    """Explicit five-case overlay; never infer permission from newly found source."""
    expected = {p: names.split() for p, names in inventory.FILES.items()}
    expected["ReaderDomainTests/EPUBReadyTests.swift"] += HISTORICAL_FILES["ReaderDomainTests/EPUBReadyTests.swift"][-3:]
    expected["YueJingHostTests/EPUBReaderHostTests.swift"] = (
        HISTORICAL_FILES["YueJingHostTests/EPUBReaderHostTests.swift"][:2]
        + expected["YueJingHostTests/EPUBReaderHostTests.swift"])
    actual = {}
    for path in sorted((ROOT / "Tests").rglob("*.swift")):
        rel = path.relative_to(ROOT / "Tests").as_posix()
        names = inventory.source_names(rel, path.read_text(encoding="utf-8"))
        if names:
            actual[rel] = names
    require(actual == expected, "Reviewed inventory/source drift")
    names = [n for p, ns in expected.items() if inventory.group_for(p) not in inventory.EXCLUDED for n in ns]
    require(len(names) == len(set(names)) == INVENTORY_TOTAL, "Inventory declaration drift")
    text = (ROOT / "Tests/ReaderDomainTests/EPUBLibraryTests.swift").read_text(encoding="utf-8")
    name = next(iter(inventory.PARAMETERIZED))
    require(re.search(r"@Test\(arguments: \[false, true\]\)\s+func " + name + r"\(symlink: Bool\)", text),
            "Reviewed Bool matrix changed")
    return dict(kind="SOURCE_INVENTORY_NOT_NATIVE", selected=INVENTORY_TOTAL,
                selected_executions=INVENTORY_EXECUTIONS, all_declared=INVENTORY_TOTAL + 1,
                native_executions=0, cases=expected, excluded=inventory.EXCLUDED)


def selection():
    reviewed = reviewed_inventory()
    names = [name for rel, selected in SELECTED_FILES.items() for name in selected
             if name in reviewed["cases"][rel]]
    require(len(names) == len(set(names)) == TOTAL and
            [sum(g["kind"] == kind for g in GROUPS.values()) for kind in ("domain", "host", "ui")] == [1, 1, 1]
            and sum(len(inventory.PARAMETERIZED.get(n, {}).get("values", [None])) for n in names) == EXECUTIONS,
            "Unexpected selected identities/count")
    require(set(GROUPS) == {"domain-12", "host-2", "ui-2"}
            and len(REUSED_GROUPS) == HISTORICAL_TOTAL and len(HISTORICAL_GROUPS) == COMBINED_TOTAL,
            "Followup/historical partition drift")
    return {group: list(spec["cases"]) for group, spec in GROUPS.items()}


def freeze_candidate():
    scope_receipt()  # Cloud clean-source checks precede every output.
    write(OUT / "candidate-sources.json", dict(source_commit=os.environ["GITHUB_SHA"],
          run_id=os.environ["GITHUB_RUN_ID"], run_attempt="1", files=v.candidate_files(), inventory=reviewed_inventory()))


def check_candidate():
    frozen = load(OUT / "candidate-sources.json")
    require(frozen == dict(source_commit=os.environ["GITHUB_SHA"], run_id=os.environ["GITHUB_RUN_ID"],
            run_attempt="1", files=v.candidate_files(), inventory=reviewed_inventory()), "Candidate/source/run drift")


def validate_version_boundary():
    base = git("show", BASE + ":project.yml")
    old_version, old_build = b'MARKETING_VERSION: "0.2.14"', b'CURRENT_PROJECT_VERSION: "16"'
    require(base.count(old_version) == base.count(old_build) == 1, "Baseline project version drift")
    expected = base.replace(old_version, b'MARKETING_VERSION: "0.2.15"').replace(old_build, b'CURRENT_PROJECT_VERSION: "17"')
    require((ROOT / "project.yml").read_bytes() == expected, "project.yml changes must be only two version values")
    base_app = git("show", BASE + ":App/AppVersion.swift")
    # This baseline reads Bundle metadata dynamically and has no hardcoded values.
    # If it has literals, permit exactly their corresponding replacements only.
    expected_app = base_app.replace(b'"0.2.14"', b'"0.2.15"').replace(b'"16"', b'"17"')
    require((ROOT / "App/AppVersion.swift").read_bytes() == expected_app, "AppVersion logic/value boundary drift")


def validate_followup_sources(source_files=None, *, pending=False):
    """Keep the original user-code boundary, now against the approved BASE."""
    require(not pending or os.environ.get("GITHUB_ACTIONS") != "true", "Cloud cannot use pending source")
    before, after = tree(BASE), tree("HEAD")
    changed = {p for p in set(before) | set(after) if before.get(p) != after.get(p)}
    require(changed <= ALLOWED and not set(before) - set(after), "Committed source boundary drift")
    require(set(after) - set(before) <= NEW, "Unapproved added paths")
    status = git("status", "--porcelain", "-z", "--untracked-files=no").decode("utf-8")
    working_paths = set()
    for entry in status.split("\0"):
        if entry:
            require(len(entry) > 3 and not any(c in entry[:2] for c in "RC"), "Renamed/copied source not approved")
            working_paths.add(entry[3:])
    require(working_paths <= ALLOWED, "Unapproved working-tree change (including dependencies/config)")
    current = v.candidate_files()
    require(set(current) - set(before) <= NEW, "Unapproved untracked candidate source")
    for path in current:
        file = ROOT / path
        require(not file.is_symlink(), "Symlink candidate source")
        if path not in ALLOWED:
            data = file.read_bytes()
            blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
            require(before.get(path, [None, None, None])[2] == blob, "Unapproved source edit: " + path)
    for path, digest in CANDIDATE_SHA256.items():
        require(sha(ROOT / path) == digest, "Approved candidate/assertion drift: " + path)
    if source_files is not None:
        require(source_files == current, "Prior source manifest differs from current candidate")
    validate_version_boundary()
    validate_historical_sources(pending=pending)
    if not pending:
        require(not status, "Cloud requires clean source")
        require(set(current) <= set(after) and set(after) - set(before) == NEW, "Cloud candidate not committed")
    else:
        changed |= working_paths | {p for p in NEW if (ROOT / p).is_file()}
    return dict(source_status="pending" if pending else "clean", changed_paths=sorted(changed))


HOST_SOURCE = "Tests/YueJingHostTests/EPUBReaderHostTests.swift"
FOLLOWUP_CONFIG = frozenset({HOST_SOURCE, WORKFLOW_PATH, "scripts/run_epub_freeze_validation.py",
                             "scripts/check_epub_freeze_validation.py", "docs/EPUB_FREEZE_RELEASE.md"})


def swift_function_span(text, name):
    """Bound a unique Swift function block; comments/string contents cannot end it."""
    declarations = list(re.finditer(r"\bfunc\s+" + re.escape(name) + r"\s*\(", text))
    require(len(declarations) == 1, "Missing/duplicate Swift function")
    start = text.index("{", declarations[0].end())
    depth, i = 1, start + 1
    while i < len(text):
        if text.startswith("//", i):
            end = text.find("\n", i); i = len(text) if end < 0 else end + 1
        elif text.startswith("/*", i):
            comments = 1; i += 2
            while comments and i < len(text):
                if text.startswith("/*", i): comments += 1; i += 2
                elif text.startswith("*/", i): comments -= 1; i += 2
                else: i += 1
            require(comments == 0, "Unterminated Swift comment")
        elif text[i] == '"':
            quote = '"""' if text.startswith('"""', i) else '"'; i += len(quote)
            while i < len(text) and not text.startswith(quote, i):
                i += 2 if text[i] == "\\" else 1
            require(i < len(text), "Unterminated Swift string"); i += len(quote)
        else:
            if text[i] == "{": depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0: return start, i + 1
            i += 1
    raise ValueError("Unterminated Swift function")


def validate_host_diagnostic_isolation(original, candidate):
    require(compat.digest_bytes(candidate.encode()) == CANDIDATE_SHA256[HOST_SOURCE], "Unapproved Host diagnostic bytes")
    name = GROUPS["host-2"]["cases"][0]
    old_start, old_end = swift_function_span(original, name)
    start, end = swift_function_span(candidate, name)
    require(original[:old_start] == candidate[:start] and original[old_end:] == candidate[end:],
            "Reused Host methods/shared helpers must be byte-identical")
    old_body, body = original[old_start:old_end], candidate[start:end]
    call = "                    try await waitUntilReady(model: model, expectedToken: token)\n"
    opening = "                    do {\n" + "    " + call
    closing = "                    }\n                    let deadline"
    require(body.count(opening) == body.count(closing) == old_body.count(call) == 1, "Host diagnostic block boundary drift")
    first = body.index(opening); last = body.index(closing, first) + len("                    }\n")
    diagnostic = body[first:last]
    require("timeout: 2)" in diagnostic and "throw error // Preserve the original failure" in diagnostic
            and diagnostic.count("waitUntilReady(") == 1, "Host failure must retain bounded diagnostics/rethrow")
    require(body[:first] + call + body[last:] == old_body, "Host diagnostic changed actions/assertions/waits")


def historical_source_manifest():
    entries = tree(HISTORICAL_SOURCE)
    paths = [p for p in entries if p == "project.yml" or
             (p.split("/")[0] in ("App", "Sources", "Tests", "scripts", ".github")
              and Path(p).suffix in (".swift", ".py", ".yml", ".txt"))]
    # Batch cat-file avoids hundreds of git subprocesses without reading private files.
    objects = [entries[p][2] for p in paths]
    raw = subprocess.check_output(["git", "cat-file", "--batch"], input=("\n".join(objects) + "\n").encode(), cwd=ROOT, timeout=30)
    position, result = 0, {}
    for path, oid in zip(paths, objects):
        end = raw.index(b"\n", position); header = raw[position:end].decode().split()
        require(header[:2] == [oid, "blob"], "Historical source blob mismatch")
        size = int(header[2]); data = raw[end + 1:end + 1 + size]
        require(len(data) == size, "Truncated historical source blob")
        result[path] = compat.digest_bytes(data); position = end + 2 + size
    require(position == len(raw), "Extra historical source bytes")
    return result


def validate_historical_sources(source_files=None, *, pending=False):
    baseline = historical_source_manifest()
    if source_files is not None:
        require(source_files == baseline, "Historical source manifest differs from fixed git revision")
    current = v.candidate_files()
    require(set(current) == set(baseline), "Followup source inventory drift")
    require(all(current[p] == digest for p, digest in baseline.items() if p not in FOLLOWUP_CONFIG),
            "Product/Domain/UI/shared source drift relative to historical21")
    before, after = tree(HISTORICAL_SOURCE), tree("HEAD")
    require(set(before) == set(after) and all(before[p] == after[p] for p in before if p not in FOLLOWUP_CONFIG),
            "Committed changes outside followup boundary")
    original = git("show", HISTORICAL_SOURCE + ":" + HOST_SOURCE).decode("utf-8")
    validate_host_diagnostic_isolation(original, (ROOT / HOST_SOURCE).read_text(encoding="utf-8"))
    return baseline


def dispatch_context():
    """Bind the job environment to the original workflow_dispatch payload and two-phase rules."""
    event = load(Path(os.environ["GITHUB_EVENT_PATH"]))
    inputs = event.get("inputs", {})
    require(isinstance(inputs, dict), "Invalid dispatch inputs")
    value = inputs.get("allow_unqualified_ipa", False)
    require(type(value) is bool or value in ("true", "false"), "Invalid diagnostic permission")
    allowed = value is True or value == "true"
    require(not allowed, "Diagnostic IPA permission is disabled for opening continuity")
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
    source = validate_followup_sources()
    changed = source["changed_paths"]
    after = tree("HEAD")
    require(all(after[p][:2] == ["100644", "blob"] for p in changed), "Nonregular approved source")
    dispatch = dispatch_context()
    return dict(
        scope=SCOPE,
        phase=dispatch["phase"],
        prior_validation_run=dispatch["prior_validation_run"],
        source_commit=head,
        source_status="clean",
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
        reused_native_planned=COMBINED_EXECUTIONS if dispatch["phase"] == "delivery" else HISTORICAL_EXECUTIONS,
        combined_target_declarations=COMBINED_TOTAL,
        combined_target_executions=COMBINED_EXECUTIONS,
        full_inventory_declared=INVENTORY_TOTAL,
        full_inventory_executions=INVENTORY_EXECUTIONS,
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
    check_candidate()
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
    parents = []

    def visit(node, inside=False):
        require(isinstance(node, dict), "Malformed xcresult test node")
        signature = name + inventory.PARAMETERIZED[name]["signature"]
        labels = [str(node.get(key, "")) for key in ("nodeIdentifier", "name")]
        matches = any(label == signature or label.endswith("/" + signature) for label in labels)
        if matches and not inside:
            parents.append(node)
        inside = inside or matches
        if inside:
            require(node.get("result") == "Passed", "Failed/skipped parameter ancestor")
        children = node.get("children", [])
        require(isinstance(children, list), "Malformed xcresult children")
        if inside and not children:
            argument = str(node.get("name", "")).strip()
            if argument.startswith("(") and argument.endswith(")"):
                argument = argument[1:-1]
            value = re.fullmatch(r"(?:symlink:\s*)?(false|true)", argument)
            require(value is not None and node.get("result") == "Passed", "Missing/failed/skipped parameter result")
            found.append(value[1])
        for child in children:
            visit(child, inside)

    require(isinstance(document, dict) and isinstance(document.get("testNodes"), list), "Missing xcresult test tree")
    for node in document["testNodes"]:
        visit(node)
    require(len(parents) == 1 and sorted(found) == ["false", "true"],
            "Expected one declaration with exactly two successful Bool argument results")
    return dict(name=name, passed_arguments=sorted(found))


def parameter_evidence(group, folder, bundle, *, export=False, group_specs=GROUPS):
    if not any(name in inventory.PARAMETERIZED for name in group_specs[group]["cases"]):
        return None
    path = folder / "xcresult-tests.json"
    if export:
        require(not path.exists(), "Existing xcresult export")
        raw = xcresult_export(bundle, "tests")
        path.write_bytes(raw)
    require(path.is_file() and not path.is_symlink(), "Missing regular xcresult export")
    raw = path.read_bytes()
    if not export:
        live = xcresult_export(bundle, "tests")
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
    try:
        reading.prepare_group_settings(kind, folder, scope["source_commit"], root=ROOT, out=OUT)
    except Exception as error:
        raise GroupPrerequisiteError(str(error)) from error
    log = folder / (target + ".log")
    code, timed_out = stream_case(want["command"], log, GROUPS[group]["timeout"])
    write(folder / "execution.json", dict(**want, native_exit=code, timed_out=timed_out))
    raw = log.read_bytes()
    if code != 0 and (b"** BUILD FAILED **" in raw or b"** TEST BUILD FAILED **" in raw) and b" started." not in raw:
        raise GroupPrerequisiteError("Shared test build failed; remaining target cases blocked")
    # Keep both raw exports before parsing or asserting counts, including failed tests.
    # A rejected result must remain diagnosable without another cloud test invocation.
    retain_xcresult_exports(folder, bundle)
    parsed = parse_log(group, raw, code, timed_out)
    verify_group_xcresult(GROUPS[group], bundle, exported_folder=folder)
    parsed["parameter_xcresult"] = parameter_evidence(group, folder, bundle)
    require(live_scope() == scope, "Source changed during native execution")
    write(folder / "counts.json", parsed)
    print(json.dumps(parsed, indent=2))


class GroupPrerequisiteError(ValueError):
    """A shared target prerequisite failed before an individual case could run."""


def run_all(destination):
    """Continue independent cases, never convert failed evidence into release success."""
    require(not NATIVE_OUT.exists(), "Existing native evidence; do not retry/overwrite cases")
    OUT.mkdir(parents=True, exist_ok=True)
    previous_term = signal.getsignal(signal.SIGTERM)
    def cancelled(signum, frame):
        raise KeyboardInterrupt("User/job cancelled")
    signal.signal(signal.SIGTERM, cancelled)
    try:
        scope = live_scope()
        require(scope["phase"] == "validation", "Native execution is forbidden in delivery phase")
        compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=True)
        compat.validate_destination(destination, OUT)
        NATIVE_OUT.mkdir()
        summarize()
        blocked = {}
        for group, spec in GROUPS.items():
            if spec["kind"] in blocked:
                folder = NATIVE_OUT / group
                folder.mkdir()
                write(folder / "failure.json", dict(group=group, error=blocked[spec["kind"]],
                      status="blocked", source_commit=scope["source_commit"], run_id=scope["run_id"]))
                continue
            require(live_scope() == scope, "Source/run changed during case scheduling")
            try:
                print("Running " + group + ": " + GROUPS[group]["cases"][0], flush=True)
                run_group(group, destination, checked_scope=scope)
            except Exception as error:
                folder = NATIVE_OUT / group
                folder.mkdir(exist_ok=True)
                if isinstance(error, GroupPrerequisiteError):
                    blocked[spec["kind"]] = str(error)
                write(folder / "failure.json", dict(group=group, error_type=type(error).__name__,
                      error=str(error), status="blocked" if isinstance(error, GroupPrerequisiteError) else "error",
                      source_commit=scope["source_commit"], run_id=scope["run_id"]))
            finally:
                summarize()
        result = summarize()
        return all(row["status"] == "passed" for row in result["cases"])
    except (Exception, KeyboardInterrupt) as error:
        write(OUT / "case-scheduling-error.json", dict(error_type=type(error).__name__, error=str(error) or "Cancelled"))
        raise
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        summarize()


# ---------------------------------------------------------------------------
# Same-source initial validation reuse verification
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


def validate_prior_run_and_artifact(prior_id, run, artifact, expected_sha, current_run_id, *, fixed_historical=False):
    require(isinstance(run, dict) and isinstance(artifact, dict), "Invalid prior API metadata")
    require(re.fullmatch(r"[1-9][0-9]*", str(prior_id)), "Invalid prior run ID")
    require(str(prior_id) != str(current_run_id), "Self-referential prior run rejected")
    if fixed_historical:
        require(int(prior_id) == HISTORICAL_RUN and expected_sha == HISTORICAL_SOURCE, "Only fixed historical run may fail")
        require(artifact.get("id") == HISTORICAL_ARTIFACT and artifact.get("size_in_bytes") == HISTORICAL_BYTES
                and artifact.get("digest") == "sha256:" + HISTORICAL_SHA256, "Pinned historical artifact mismatch")
    require(run.get("id") == int(prior_id)
            and run.get("head_sha") == expected_sha
            and run.get("run_attempt") == 1
            and run.get("workflow_id") == WORKFLOW_ID
            and run.get("path") == WORKFLOW_PATH
            and run.get("event") == "workflow_dispatch"
            and run.get("head_branch") == "main"
            and run.get("status") == "completed"
            and run.get("conclusion") == ("failure" if fixed_historical else "success"),
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
                            expected_artifact_id=None, expected_bytes=None, expected_sha256=None, fixed_historical=False):
    require(folder.is_dir() and not folder.is_symlink(), "Missing reused folder: " + str(folder))
    require({p.name for p in folder.iterdir()} == {"api-run.json", "api-artifact.json", "archive-receipt.json", "archive.zip", "evidence"},
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
    archive = folder / "archive.zip"
    require(archive.is_file() and not archive.is_symlink() and archive.stat().st_size == receipt["archive_bytes"]
            and sha(archive) == receipt["archive_sha256"], "Retained authenticated archive drift")
    require(safe_zip_members(archive) == members, "Archive manifest differs from authenticated ZIP bytes")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        live_run = github_api_json(f"/actions/runs/{expected_run_id}")
        live_artifact = github_api_json(f"/actions/artifacts/{artifact['id']}")
        validate_prior_run_and_artifact(expected_run_id, live_run, live_artifact, expected_source_commit,
                                        os.environ.get("GITHUB_RUN_ID"), fixed_historical=fixed_historical)
        require(live_artifact["digest"] == artifact["digest"]
                and live_artifact["size_in_bytes"] == artifact["size_in_bytes"], "API artifact identity/digest drift")
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
                         destination, prefix="", verify_native=True):
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
    if verify_native:
        verify_group_xcresult(spec, folder / f"{target}.xcresult")
    else:
        require(os.environ.get("GITHUB_ACTIONS") != "true" and group in REUSED_GROUPS,
                "Offline structural replay cannot bypass current/parameterized native parsing")
    parsed["parameter_xcresult"] = parameter_evidence(
        group, folder, folder / f"{target}.xcresult", group_specs={group: spec})
    require(json.dumps(load(folder / "counts.json"), sort_keys=True) == json.dumps(parsed, sort_keys=True),
            "Reused counts differ from raw log events: " + group)
    return parsed


def xcresult_export(bundle, section):
    """xcresulttool writes databases even for reads: never parse retained bytes in place."""
    require(sys.platform == "darwin", "Native xcresult parsing requires macOS; no offline qualification")
    temporary_root = Path(os.environ.get("PI_SCRATCH_DIR") or os.environ.get("RUNNER_TEMP") or REUSED_STAGING)
    temporary_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="opening-xcresult-", dir=temporary_root) as temporary:
        working = Path(temporary) / bundle.name
        shutil.copytree(bundle, working)
        return subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", section,
                                        "--path", str(working)], timeout=60, stderr=subprocess.PIPE)


def retain_xcresult_exports(folder, bundle):
    """Retain unmodified output (even invalid JSON), plus raw tool failure streams."""
    first_error = None
    for section in ("tests", "summary"):
        path = folder / ("xcresult-" + section + ".json")
        require(not path.exists() and not path.is_symlink(), "Existing xcresult export; never overwrite")
        try:
            raw = xcresult_export(bundle, section)
            with path.open("xb") as stream:
                stream.write(raw)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            # Do not fabricate valid JSON/counts from a failed or partial export.
            for suffix, payload in (("stdout", getattr(error, "output", None)),
                                    ("stderr", getattr(error, "stderr", None))):
                if payload is not None:
                    with (folder / ("xcresult-" + section + "." + suffix)).open("xb") as stream:
                        stream.write(payload.encode("utf-8") if isinstance(payload, str) else payload)
            write(folder / ("xcresult-" + section + "-export-error.json"),
                  dict(error_type=type(error).__name__, error=str(error),
                       returncode=getattr(error, "returncode", None)))
            if first_error is None:
                first_error = error
    if first_error is not None:
        raise first_error


def verify_group_xcresult(spec, bundle, *, exported_folder=None):
    paging.require_xcresult(bundle)
    require((bundle / "Data").is_dir() and any(p.is_file() and p.stat().st_size > 0
            for p in (bundle / "Data").rglob("*")), "Missing xcresult Data")
    def exported(section):
        if exported_folder is None:
            return xcresult_export(bundle, section)
        path = exported_folder / ("xcresult-" + section + ".json")
        require(path.is_file() and not path.is_symlink(), "Missing regular xcresult export")
        return path.read_bytes()
    tests = json.loads(exported("tests"))
    name = spec["cases"][0]
    signature = name + inventory.PARAMETERIZED.get(name, {}).get("signature", "()")
    summary = json.loads(exported("summary"))
    # Summary presentation may count one declaration or its two argument runs.
    # Neither is expansion proof: the exact two successful Bool leaves below are
    # mandatory in BOTH cases. Non-parameterized cases still require exactly one.
    summary_counts = {len(spec["cases"]), len(inventory.PARAMETERIZED.get(name, {}).get("values", [None]))}
    require(all(type(summary.get(key)) is int for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests"))
            and summary["failedTests"] == summary["skippedTests"] == 0
            and summary["totalTestCount"] == summary["passedTests"]
            and summary["totalTestCount"] in summary_counts,
            "xcresult declaration/argument total/pass/failure/skip mismatch")
    matches = []
    def visit(node):
        require(isinstance(node, dict), "Invalid xcresult node")
        if node.get("nodeType") in ("Test Case", "Arguments"):
            require(node.get("result") == "Passed", "Failed/skipped/incomplete xcresult case")
        labels = [str(node.get(k, "")) for k in ("name", "nodeIdentifier")]
        if any(label in (name, signature) or label.endswith("/" + signature) for label in labels):
            matches.append(node)
        for child in node.get("children", []):
            visit(child)
        if node.get("nodeType") == "Test Case":
            require(any(label in (name, signature) or label.endswith("/" + signature) for label in labels),
                    "Unexpected xcresult test identity")
    require(isinstance(tests.get("testNodes"), list), "Missing xcresult tests")
    for node in tests["testNodes"]:
        visit(node)
    require(len(matches) == 1 and matches[0].get("result") == "Passed", "xcresult identity/result drift")
    if name in inventory.PARAMETERIZED:
        parameter_result(tests)
    return tests


def validate_historical_run_and_artifact(run, artifact):
    validate_prior_run_and_artifact(HISTORICAL_RUN, run, artifact, HISTORICAL_SOURCE,
                                    os.environ.get("GITHUB_RUN_ID", "local"), fixed_historical=True)


def verify_historical_evidence(folder, *, expected_packages=None, verify_native=True):
    """Only the fixed failed Round2 run's independently passing21; retain all24.

    verify_native=False is local STRUCTURAL REPLAY ONLY, never a qualification.
    The pinned archive's original receipts/bundles are never rewritten.
    """
    require(verify_native or os.environ.get("GITHUB_ACTIONS") != "true", "Cloud requires native bundle parsing")
    run, artifact, receipt = _verify_archive_receipt(folder, expected_run_id=HISTORICAL_RUN,
        expected_source_commit=HISTORICAL_SOURCE, expected_artifact_id=HISTORICAL_ARTIFACT,
        expected_bytes=HISTORICAL_BYTES, expected_sha256=HISTORICAL_SHA256, fixed_historical=True)
    validate_historical_run_and_artifact(run, artifact)
    require(receipt["members"] == receipt["retained_files"], "Every historical archive member must be retained")
    members, ev = receipt["members"], folder / "evidence"
    require(not any(p.startswith("reused-evidence/") for p in members), "Historical chain cannot recurse")
    require({p.name for p in (ev / "epub-freeze").iterdir()} == set(HISTORICAL_GROUPS), "Historical24 inventory drift")
    scope = load(ev / "epub-freeze-scope.json")
    expected = dict(scope=HISTORICAL_SCOPE, source_commit=HISTORICAL_SOURCE, source_status="clean",
        baseline_commit=BASE, run_id=str(HISTORICAL_RUN), run_attempt="1", phase="validation",
        prior_validation_run="", build_ipa=False, allow_unqualified_ipa=False, version=VERSION, build=BUILD,
        selected={g: s["cases"] for g, s in HISTORICAL_GROUPS.items()}, selected_declarations=24,
        native_tests_planned=25, reused_native_planned=0, combined_target_declarations=24,
        combined_target_executions=25, full_inventory_declared=241, full_inventory_executions=242)
    require(all(k in scope and json.dumps(scope[k], sort_keys=True) == json.dumps(value, sort_keys=True)
                for k, value in expected.items()), "Historical scope/selection/phase mismatch")
    event = load(ev / "dispatch-event.json").get("inputs", {})
    require(sha(ev / "dispatch-event.json") == scope["dispatch_event_sha256"]
            and event.get("validation_scope") == HISTORICAL_SCOPE and event.get("build_ipa") in (False, "false")
            and event.get("allow_unqualified_ipa") in (False, "false") and event.get("prior_validation_run", "") in ("", None),
            "Historical raw dispatch mismatch")
    sources = load(ev / "candidate-sources.json")
    require(all(sources.get(k) == expected[k] for k in ("source_commit", "run_id", "run_attempt"))
            and sources.get("files") == scope.get("files"), "Historical candidate identity/scope mismatch")
    validate_historical_sources(sources.get("files"))
    packages = _verify_toolchain_and_deps(ev, HISTORICAL_SOURCE, expected_packages=expected_packages)
    sim, linkage = _verify_simulator_and_linkage(ev, members, HISTORICAL_SOURCE, HISTORICAL_RUN)
    destination = "platform=iOS Simulator,id=" + sim["udid"]
    # All three excluded results remain in the pinned archive, but are never passed
    # through the reuse verifier or counted. Current domain12 must execute Bool2 anew.
    for group in GROUPS:
        require((ev / "epub-freeze" / group / "failure.json").is_file(), "Excluded Round2 failure missing")
        require(not (ev / "epub-freeze" / group / "counts.json").exists(), "Excluded Round2 case gained a receipt")
    groups = [_verify_reused_group(g, spec, ev, members, expected_scope=HISTORICAL_SCOPE,
              expected_source=HISTORICAL_SOURCE, expected_run_id=HISTORICAL_RUN, destination=destination,
              verify_native=verify_native) for g, spec in REUSED_GROUPS.items()]
    require(sum(g["executions"] for g in groups) == HISTORICAL_EXECUTIONS
            and len({n for g in groups for n in g["passed"]}) == HISTORICAL_TOTAL, "Historical21 count drift")
    return dict(run_id=str(HISTORICAL_RUN), run_attempt="1", source_commit=HISTORICAL_SOURCE,
        scope=HISTORICAL_SCOPE, artifact_id=HISTORICAL_ARTIFACT, archive_sha256=HISTORICAL_SHA256,
        archive_bytes=HISTORICAL_BYTES, workflow_conclusion="failure", excluded_groups=list(GROUPS),
        declarations_passed=HISTORICAL_TOTAL, executions_passed=HISTORICAL_EXECUTIONS, groups=groups,
        packages=packages, simulator=sim, simulator_linkage_sha256=linkage,
        native_bundle_parse="passed" if verify_native else "not_executed_local_structural_replay",
        qualified=verify_native)


def retain_historical_evidence(folder, offline=None, *, expected_packages=None, verify_native=True):
    require(offline is None or os.environ.get("GITHUB_ACTIONS") != "true", "Cloud offline history forbidden")
    if offline is None:
        run = github_api_json(f"/actions/runs/{HISTORICAL_RUN}")
        artifact = _select_artifact_from_payload(github_api_json(f"/actions/runs/{HISTORICAL_RUN}/artifacts"),
                                                  HISTORICAL_NAME, HISTORICAL_ARTIFACT)
        validate_historical_run_and_artifact(run, artifact)
        archive = REUSED_STAGING / f"{HISTORICAL_ARTIFACT}.zip"
        github_download_artifact_zip(HISTORICAL_ARTIFACT, archive)
    else:
        run, artifact = _load_offline_run_and_artifact(offline["run_json"], offline["artifact_json"],
                                                     HISTORICAL_NAME, HISTORICAL_ARTIFACT)
        validate_historical_run_and_artifact(run, artifact)
        archive = Path(offline["zip_path"])
    require(archive.is_file() and not archive.is_symlink() and archive.stat().st_size == HISTORICAL_BYTES
            and sha(archive) == HISTORICAL_SHA256, "Pinned historical ZIP size/hash mismatch")
    require(not folder.exists(), "Never overwrite retained historical evidence")
    members = safe_zip_members(archive)
    folder.mkdir(parents=True)
    shutil.copyfile(archive, folder / "archive.zip")
    write(folder / "api-run.json", run); write(folder / "api-artifact.json", artifact)
    retained = extract_selected_members(archive, members, set(members), folder / "evidence")
    # This is a transport manifest only, not a replacement for any native receipt.
    write(folder / "archive-receipt.json", dict(run_id=str(HISTORICAL_RUN), run_attempt="1",
        source_commit=HISTORICAL_SOURCE, artifact_id=HISTORICAL_ARTIFACT, archive_bytes=HISTORICAL_BYTES,
        archive_sha256=HISTORICAL_SHA256, member_count=len(members), members=members, retained_files=retained))
    return verify_historical_evidence(folder, expected_packages=expected_packages, verify_native=verify_native)


def validation_reuse_receipt(scope, historical):
    require(historical.get("qualified") is True and historical.get("native_bundle_parse") == "passed"
            and historical.get("executions_passed") == HISTORICAL_EXECUTIONS
            and historical.get("archive_sha256") == HISTORICAL_SHA256, "History not qualified")
    return dict(scope=SCOPE, phase="validation", source_commit=scope["source_commit"], run_id=scope["run_id"],
                run_attempt="1", passed=True, provenance_valid=True, reused_native_passed=HISTORICAL_EXECUTIONS,
                reused_declarations=HISTORICAL_TOTAL, reused_historical_passed=HISTORICAL_EXECUTIONS, historical=historical)


def verify_validation_reuse_gate(saved, scope, historical):
    require(json.dumps(saved, sort_keys=True) == json.dumps(validation_reuse_receipt(scope, historical), sort_keys=True),
            "Fixed historical reuse receipt drift")


def verify_validation_reuse(scope, packages):
    require(REUSED_OUT.is_dir() and not REUSED_OUT.is_symlink()
            and {p.name for p in REUSED_OUT.iterdir()} == {HISTORICAL_FOLDER, REUSED_GATE_JSON.name},
            "Validation must contain only fixed historical21")
    historical = verify_historical_evidence(REUSED_OUT / HISTORICAL_FOLDER, expected_packages=packages)
    verify_validation_reuse_gate(load(REUSED_GATE_JSON), scope, historical)
    return historical


def inspect_prior_evidence(prior_root, scope, *, expected_packages=None, check_shared_sources=True):
    """Verify prior validation provenance strictly; report per-case statuses separately."""
    require(check_shared_sources or os.environ.get("GITHUB_ACTIONS") != "true", "Cloud prior source verification cannot be skipped")
    prior_id = scope["prior_validation_run"]
    run, artifact, receipt = _verify_archive_receipt(
        prior_root,
        expected_run_id=prior_id,
        expected_source_commit=scope["source_commit"],
    )
    validate_prior_run_and_artifact(prior_id, run, artifact, scope["source_commit"], scope["run_id"])
    ev_dir = prior_root / "evidence"
    fixed_root = ev_dir / "reused-evidence" / HISTORICAL_FOLDER
    require({p.name for p in (ev_dir / "reused-evidence").iterdir()} == {HISTORICAL_FOLDER, "reused-evidence-gate.json"},
            "Only the single fixed historical chain is permitted")
    historical = verify_historical_evidence(fixed_root, expected_packages=expected_packages)
    verify_validation_reuse_gate(load(ev_dir / "reused-evidence/reused-evidence-gate.json"),
                                 dict(source_commit=scope["source_commit"], run_id=str(prior_id)), historical)
    require(not ({"native-test-gate.json", "epub-reading-gate.json", "epub-freeze-package.json"} & set(receipt["members"])),
            "Mixed prior qualification/package evidence")
    require(set(receipt["retained_files"]) == _prior_wanted_members(receipt["members"]), "Prior retained manifest incomplete/extra")
    native_groups = {m.split('/')[1] for m in receipt["members"] if m.startswith('epub-freeze/')}
    require(native_groups == set(GROUPS), "Prior validation contains missing/extra native groups")
    prior_scope = load(ev_dir / "epub-freeze-scope.json")
    require(prior_scope.get("selected") == {g: s["cases"] for g, s in GROUPS.items()}
            and type(prior_scope.get("selected_declarations")) is int
            and prior_scope.get("selected_declarations") == TOTAL
            and type(prior_scope.get("native_tests_planned")) is int
            and prior_scope.get("native_tests_planned") == EXECUTIONS
            and prior_scope.get("combined_target_declarations") == COMBINED_TOTAL
            and prior_scope.get("combined_target_executions") == COMBINED_EXECUTIONS
            and prior_scope.get("reused_native_planned") == HISTORICAL_EXECUTIONS
            and prior_scope.get("full_inventory_declared") == INVENTORY_TOTAL
            and prior_scope.get("full_inventory_executions") == INVENTORY_EXECUTIONS,
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
            and prior_scope.get("source_status") == "clean"
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
        validate_followup_sources(prior_sources.get("files"))
        require(prior_scope.get("files") == v.candidate_files()
                and prior_scope.get("approved_files") == {p: sha(ROOT / p) for p in sorted(ALLOWED)},
                "Prior scope/source hashes differ")

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
                   planned_executions=len(inventory.PARAMETERIZED.get(spec["cases"][0], {}).get("values", [None])),
                   status="not_run", reason="prior 中未执行或缺失证据",
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
        except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
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
            require(all(key in prior_gate and json.dumps(prior_gate[key], sort_keys=True) == json.dumps(value, sort_keys=True)
                        for key, value in prior_scope.items()), "Prior gate lost/changed frozen scope fields")
            require(prior_gate.get("scope") == SCOPE
                    and prior_gate.get("phase") == "validation"
                    and prior_gate.get("qualification") == VALIDATION_QUALIFICATION
                    and prior_gate.get("source_commit") == scope["source_commit"]
                    and str(prior_gate.get("run_id")) == str(prior_id)
                    and type(prior_gate.get("native_tests_executed_this_run")) is int
                    and prior_gate.get("native_tests_executed_this_run") == EXECUTIONS
                    and json.dumps(prior_gate.get("groups"), sort_keys=True) == json.dumps(parsed_groups, sort_keys=True)
                    and prior_gate.get("reused_native_passed") == HISTORICAL_EXECUTIONS
                    and prior_gate.get("reused_historical_passed") == HISTORICAL_EXECUTIONS
                    and prior_gate.get("reused_historical") == historical
                    and prior_gate.get("allow_unqualified_ipa") is False
                    and prior_gate.get("build_ipa") is False
                    and prior_gate.get("prior_validation_run") == ""
                    and prior_gate.get("version") == VERSION and prior_gate.get("build") == BUILD
                    and prior_gate.get("full_regression_passed") is False
                    and prior_gate.get("unselected_executions") == INVENTORY_EXECUTIONS - COMBINED_EXECUTIONS
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
        combined_executions_passed=COMBINED_EXECUTIONS if passed else None,
        historical=historical,
        simulator=sim,
        simulator_boot_sha256=sha(ev_dir / "simulator-boot.json") if (ev_dir / "simulator-boot.json").is_file() else None,
        simulator_linkage_sha256=sim_linkage_sha,
        packages=packages,
        groups=parsed_groups,
        case_rows=case_rows,
    )


def _prior_wanted_members(members):
    # Retain every member, including failures/extra evidence: exact archive binding
    # is checked before any semantic selection. No receipt regeneration or filtering.
    return set(members)


def _load_offline_run_and_artifact(run_json_path, artifact_json_path, expected_name, expected_id=None):
    run = load(Path(run_json_path))
    artifact_payload = load(Path(artifact_json_path))
    artifact = _select_artifact_from_payload(artifact_payload, expected_name, expected_id=expected_id)
    return run, artifact


def reuse_evidence(*, require_dependencies=True, offline_prior=None, offline_historical=None, check_shared_sources=True):
    """New4 plus fixed historical21; delivery binds exactly that one-level chain."""
    scope = live_scope()
    require(os.environ.get("GITHUB_ACTIONS") != "true" or
            (require_dependencies and offline_prior is None and offline_historical is None and check_shared_sources),
            "Cloud replay/bypass forbidden")
    expected_packages = compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=False) if require_dependencies else None
    require(not REUSED_OUT.exists(), "Existing reused evidence; use a fresh dispatch")
    REUSED_OUT.mkdir(parents=True)
    if scope["phase"] == "validation":
        require(offline_prior is None, "Validation cannot reuse arbitrary prior")
        historical = retain_historical_evidence(REUSED_OUT / HISTORICAL_FOLDER, offline_historical,
                                                expected_packages=expected_packages)
        receipt = validation_reuse_receipt(scope, historical)
        write(REUSED_GATE_JSON, receipt)
        return receipt
    require(offline_historical is None, "Delivery historical evidence must be inside successful prior")
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
    prior_dir = REUSED_OUT / f"prior-{prior_id}"
    prior_dir.mkdir(parents=True)
    shutil.copyfile(prior_zip, prior_dir / "archive.zip")
    write(prior_dir / "api-run.json", prior_run)
    write(prior_dir / "api-artifact.json", prior_artifact)
    retained_prior = extract_selected_members(prior_zip, prior_members, _prior_wanted_members(prior_members), prior_dir / "evidence")
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
        reused_native_passed=COMBINED_EXECUTIONS if prior_summary["passed"] else None,
        reused_declarations=COMBINED_TOTAL if prior_summary["passed"] else None,
        reused_historical_passed=HISTORICAL_EXECUTIONS if prior_summary["passed"] else None,
        reused_prior_passed=EXECUTIONS if prior_summary["passed"] else None,
        errors=prior_summary["errors"],
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
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
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
                       planned_executions=len(inventory.PARAMETERIZED.get(case, {}).get("values", [None])),
                       status="not_run", reason="尚未开始；检查前置准备、调度或取消状态")
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
                if failure and failure.get("status") == "blocked":
                    row.update(status="blocked", reason=failure["error"])
            except (ValueError, OSError, KeyError, TypeError) as error:
                row.update(status="error", reason="结果证据无效：" + str(error))
            rows.append(row)
        scheduling = _optional_json(OUT / "case-scheduling-error.json")
        if publish and scheduling is None and any(row["status"] == "not_run" for row in rows):
            scheduling = dict(error="Final report: case not admitted; shared preparation incomplete, cancelled, or scheduling never started. No native failure is fabricated.")
        if scheduling:
            for row in rows:
                if row["status"] == "not_run":
                    row.update(status="blocked", reason=scheduling["error"])
    else:
        scheduling = None

    prior_summary = _summarize_prior_reuse(prior_id) if phase == "delivery" else None
    counts = {status: sum(row["status"] == status for row in rows)
              for status in ("passed", "failed", "timed_out", "error", "blocked", "not_run")}
    native_executed_passed = (EXECUTIONS if counts["passed"] == TOTAL else None) if phase == "validation" else 0
    historical_summary = None
    if phase == "validation":
        try:
            saved = load(REUSED_GATE_JSON)
            historical_summary = saved["historical"]
            verify_validation_reuse_gate(saved, _optional_json(SCOPE_JSON) or {}, historical_summary)
        except (ValueError, OSError, KeyError, TypeError):
            historical_summary = None
        reused_passed = HISTORICAL_EXECUTIONS if historical_summary else None
        combined_passed = COMBINED_EXECUTIONS if historical_summary and native_executed_passed == EXECUTIONS else None
    else:
        reused_passed = COMBINED_EXECUTIONS if prior_summary["status"] == "passed" else None
        combined_passed = reused_passed

    # Complete UI inventory distinguishes one fresh selection, two fixed reuses,
    # and twelve unselected declarations; never relabel historical work as new.
    ui_cases = {row["case"]: row for row in (rows if phase == "validation" else prior_summary["cases"])
                if row["kind"] == "ui"}
    ui_rows = []
    for target in ("YueJingEPUBUITests", "YueJingUITests"):
        for case in inventory.expected_names(target):
            selected = case in SELECTED_FILES["YueJingEPUBUITests/EPUBFlowUITests.swift"]
            reused = case in HISTORICAL_FILES["YueJingEPUBUITests/EPUBFlowUITests.swift"] and not selected
            row = dict(ui_cases.get(case, dict(target=target, case=case, status=("reused" if reused and reused_passed else
                       "not_verified" if reused else "not_run" if selected else "unselected"))))
            row.update(current_selection="selected" if selected and phase == "validation" else "reused" if selected or reused else "unselected",
                       evidence_origin="historical21" if reused else "current" if phase == "validation" else "prior4",
                       reason=row.get("reason", "Fixed historical reuse" if reused else "Unselected; not counted as passed"))
            ui_rows.append(row)

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
        reused_prior_passed=(prior_summary["verified_passed"] if prior_summary else None),
        combined_verified_passed=combined_passed,
        verified_passed=combined_passed,
        counts=counts,
        cases=rows,
        reused_prior=prior_summary,
        reused_historical=historical_summary,
        reused_historical_passed=HISTORICAL_EXECUTIONS if reused_passed is not None else None,
        full_inventory_declared=INVENTORY_TOTAL,
        full_inventory_executions=INVENTORY_EXECUTIONS,
        unselected_executions=INVENTORY_EXECUTIONS - COMBINED_EXECUTIONS,
        ui_inventory=ui_rows,
        scheduling_error=scheduling,
        qualification="DISPLAY_ONLY_NOT_RELEASE_QUALIFICATION",
    )

    def cell(value):
        return str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("|", "&#124;").replace("\n", " ").replace("\r", " ")

    lines = [f"## EPUB opening continuity ({phase})", "",
             f"Fresh: {native_executed_passed}; reused: {reused_passed}; verified: {combined_passed}/25",
             "24 declarations, 25 expansions; 217 unselected expansions. Not full regression.", "",
             "| Case | Status | Reason |", "|---|---|---|"]
    for row in (rows if phase == "validation" else prior_summary["cases"]):
        lines.append(f"| {cell(row['group'] + ': ' + row['case'])} | {cell(row['status'])} | {cell(row['reason'])} |")
    lines += ["", "### Complete UI inventory (1 fresh / 2 fixed reuse / 12 unselected in validation)", "",
              "| Case | Selection | Status |", "|---|---|---|"]
    for row in ui_rows:
        lines.append(f"| {cell(row['case'])} | {cell(row['current_selection'])} | {cell(row['status'])} |")
    if scheduling:
        lines += ["", "Shared prerequisite blocked: " + cell(scheduling["error"])]
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
    if scope["phase"] == "validation":
        historical = verify_validation_reuse(scope, packages)
        require(not (OUT / "case-scheduling-error.json").exists() and
                not any((NATIVE_OUT / group / "failure.json").exists() for group in GROUPS),
                "Failed/blocked cases cannot qualify even if a counts receipt exists")
        sim = load(OUT / "simulator-selection.json")
        destination = "platform=iOS Simulator,id=" + sim["udid"]
        compat.validate_destination(destination, OUT)
        validate_linkage("simulator", scope)
        boot = load(OUT / "simulator-boot.json")
        require(all(boot.get(key) == scope[key] for key in ("source_commit", "run_id", "run_attempt"))
                and type(boot.get("exit_code")) is int and boot["exit_code"] == 0 and boot.get("timed_out") is False,
                "Missing same-run successful simulator boot")
        require(NATIVE_OUT.is_dir() and not NATIVE_OUT.is_symlink() and {p.name for p in NATIVE_OUT.iterdir()} == set(GROUPS),
                "Missing/extra groups")
        groups = []
        for group, spec in GROUPS.items():
            folder = NATIVE_OUT / group
            require(not folder.is_symlink(), "Symlink group")
            bundle = folder / (spec["target"] + ".xcresult")
            verify_group_xcresult(spec, bundle)
            want = provenance(group, destination, bundle, scope)
            require(load(folder / "selection.json") == want, "Selection receipt mismatch")
            execution = load(folder / "execution.json")
            require(execution == dict(**want, native_exit=0, timed_out=False), "Execution/provenance mismatch")
            reading.validate_group_settings(spec["kind"], folder, scope["source_commit"], root=ROOT, out=OUT)
            log = folder / (spec["target"] + ".log")
            require(log.is_file() and not log.is_symlink(), "Missing regular native log")
            parsed = parse_log(group, log.read_bytes(), execution["native_exit"], execution["timed_out"])
            parsed["parameter_xcresult"] = parameter_evidence(group, folder, bundle)
            require(json.dumps(load(folder / "counts.json"), sort_keys=True) == json.dumps(parsed, sort_keys=True),
                    "Raw events differ from saved counts")
            groups.append(parsed)
        require(sum(g["declarations_passed"] for g in groups) == TOTAL and sum(g["executions"] for g in groups) == EXECUTIONS,
                "Combined current execution count differs")
        return dict(
            **scope,
            qualification=VALIDATION_QUALIFICATION,
            coverage="EPUB_TARGETED_NOT_FULL",
            native_tests_executed_this_run=EXECUTIONS,
            reused_native_passed=HISTORICAL_EXECUTIONS,
            reused_historical_passed=HISTORICAL_EXECUTIONS,
            reused_historical=historical,
            verified_passed=COMBINED_EXECUTIONS,
            combined_verified_passed=COMBINED_EXECUTIONS,
            verified_declarations=COMBINED_TOTAL,
            not_executed_this_run=INVENTORY_EXECUTIONS - EXECUTIONS,
            unselected_executions=INVENTORY_EXECUTIONS - COMBINED_EXECUTIONS,
            groups=groups,
            simulator=sim,
        )

    # Delivery phase: 0 native tests in this run; must not have current simulator/test outputs.
    require(not NATIVE_OUT.exists()
            and not (OUT / "simulator-selection.json").exists()
            and not (OUT / "simulator-boot.json").exists()
            and not (OUT / "webkit-simulator-linkage").exists(),
            "Delivery phase must not run simulator or native tests in this run")
    prior_summary = _verify_delivery_provenance(scope, packages)
    require(prior_summary["passed"], "Prior validation run failed strict qualification: " + "; ".join(prior_summary["errors"]))
    return dict(
        **scope,
        qualification=DELIVERY_QUALIFICATION,
        coverage="EPUB_TARGETED_NOT_FULL",
        native_tests_executed_this_run=0,
        reused_native_passed=COMBINED_EXECUTIONS,
        reused_historical_passed=HISTORICAL_EXECUTIONS,
        reused_prior_passed=EXECUTIONS,
        verified_passed=COMBINED_EXECUTIONS,
        combined_verified_passed=COMBINED_EXECUTIONS,
        verified_declarations=COMBINED_TOTAL,
        not_executed_this_run=INVENTORY_EXECUTIONS,
        unselected_executions=INVENTORY_EXECUTIONS - COMBINED_EXECUTIONS,
        groups=[],
        reused_prior=prior_summary,
        simulator=None,
    )


def validate_saved():
    actual = qualification()
    require(json.dumps(load(GATE_JSON), sort_keys=True) == json.dumps(actual, sort_keys=True), "Qualification receipt drift")
    return actual


def release_gate():
    result = validate_saved()
    is_delivery = result.get("phase") == "delivery"
    expected_qual = DELIVERY_QUALIFICATION if is_delivery else VALIDATION_QUALIFICATION
    expected_native = 0 if is_delivery else EXECUTIONS
    expected_reused = COMBINED_EXECUTIONS if is_delivery else HISTORICAL_EXECUTIONS
    require(result.get("scope") == SCOPE
            and result.get("phase") in ("validation", "delivery")
            and result.get("build_ipa") is is_delivery
            and bool(result.get("prior_validation_run")) is is_delivery
            and result.get("qualification") == expected_qual
            and result.get("native_tests_executed_this_run") == expected_native
            and result.get("reused_native_passed") == expected_reused
            and result.get("verified_passed") == result.get("combined_verified_passed") == COMBINED_EXECUTIONS
            and result.get("verified_declarations") == COMBINED_TOTAL
            and result.get("version") == VERSION and result.get("build") == BUILD
            and result.get("full_regression_passed") is False
            and result.get("allow_unqualified_ipa") is False,
            "Formal release requires 25 verified passes")
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
    prior_dir = REUSED_OUT / f"prior-{scope['prior_validation_run']}"
    require({p.name for p in REUSED_OUT.iterdir()} == {prior_dir.name, REUSED_GATE_JSON.name}, "Extra/recursive reused sources")
    prior_summary = inspect_prior_evidence(prior_dir, scope, expected_packages=packages, check_shared_sources=True)
    require(prior_summary["passed"] and saved_reused.get("passed") is True
            and saved_reused.get("scope") == SCOPE and saved_reused.get("run_attempt") == "1"
            and saved_reused.get("prior") == prior_summary
            and saved_reused.get("reused_native_passed") == COMBINED_EXECUTIONS
            and saved_reused.get("reused_prior_passed") == EXECUTIONS
            and saved_reused.get("reused_historical_passed") == HISTORICAL_EXECUTIONS
            and saved_reused.get("reused_declarations") == COMBINED_TOTAL, "Reused gate/results drift")
    return prior_summary


def delivery_gate():
    """Admission only, not IPA success. Source/common/provenance prerequisites never fall back."""
    scope = live_scope()
    require(scope.get("allow_unqualified_ipa") is False, "Diagnostic IPA permission disabled")
    require(scope.get("phase") == "delivery" and scope.get("build_ipa") is True and bool(scope.get("prior_validation_run")),
            "Delivery packaging requires delivery phase with prior_validation_run and build_ipa=true")
    packages = compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=False)
    require((OUT / "app-build-exit-code.txt").read_text().strip() == "0", "Device App build did not pass")
    device_linkage = validate_linkage("device", scope)
    prior_summary = _verify_delivery_provenance(scope, packages)
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
    known_total = HISTORICAL_EXECUTIONS + known_prior
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
        reused_prior_passed=EXECUTIONS,
        reused_historical_passed=HISTORICAL_EXECUTIONS,
        reused_historical=prior_summary["historical"],
        known_executions=known_total,
        unknown_execution_groups=unknown_prior,
        cases=rows,
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
    reuse_cmd.add_argument("--prior-zip", type=Path)
    reuse_cmd.add_argument("--prior-run-json", type=Path)
    reuse_cmd.add_argument("--prior-artifact-json", type=Path)
    reuse_cmd.add_argument("--historical-zip", type=Path)
    reuse_cmd.add_argument("--historical-run-json", type=Path)
    reuse_cmd.add_argument("--historical-artifact-json", type=Path)
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
        freeze_candidate()
        receipt = scope_receipt()
        raw_event = Path(os.environ["GITHUB_EVENT_PATH"]).read_bytes()
        require(compat.digest_bytes(raw_event) == receipt["dispatch_event_sha256"], "Dispatch event changed")
        with DISPATCH_EVENT_JSON.open("xb") as stream:
            stream.write(raw_event)
        write(SCOPE_JSON, receipt)
        print(json.dumps(receipt, indent=2))
    elif args.action == "reuse":
        offline_historical = None
        if args.historical_zip or args.historical_run_json or args.historical_artifact_json:
            require(args.historical_zip and args.historical_run_json and args.historical_artifact_json, "Offline history needs all three paths")
            offline_historical = dict(zip_path=args.historical_zip, run_json=args.historical_run_json, artifact_json=args.historical_artifact_json)
        offline_prior = None
        if args.prior_zip or args.prior_run_json or args.prior_artifact_json:
            require(args.prior_zip and args.prior_run_json and args.prior_artifact_json,
                    "Offline prior replay requires --prior-zip, --prior-run-json, and --prior-artifact-json")
            offline_prior = dict(zip_path=args.prior_zip, run_json=args.prior_run_json,
                                 artifact_json=args.prior_artifact_json)
        receipt = reuse_evidence(
            require_dependencies=not args.skip_dependency_check,
            offline_prior=offline_prior,
            offline_historical=offline_historical,
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
        raise SystemExit("EPUB opening continuity release stopped: " + str(error))

"""Strict EPUB author-layout validation runner and qualification/delivery gates."""
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
import package_ipa
import reuse_native_evidence as rne
import run_epub_compat_validation as compat
import run_epub_freeze_validation as freeze
import run_epub_paging_validation as paging
import run_epub_reading_validation as reading
import task3_test_inventory as inventory
import validate_task3 as v
require = compat.require
load = compat.load_json
write = compat.write_new
write_text = compat.write_new_text
sha = compat.digest_path
digest_bytes = compat.digest_bytes
git_blob_sha1 = compat.git_blob_sha1

ROOT = v.ROOT
_DEFAULT_ROOT = ROOT
OUT = v.OUT
_DEFAULT_OUT = OUT
SCOPE_CONFIG_JSON = SCRIPT_DIR / "epub_author_layout_scope.json"

SCOPE = "epub-author-layout"
BASE = "aa834090c73e15bf282c61f3121be30bffb5b4df"
VERSION, BUILD = "0.2.20", "22"
REPO = "wan780839395-cyber/YueJing"
WORKFLOW_ID = 398234793
WORKFLOW_PATH = ".github/workflows/task3-validate.yml"

# Historical reuse constants below describe their original 83/84 selection only.
# The current frozen selection is read from scope JSON; old baselines fail source validation.
PRIOR_RUN_ID = "43153993787"
PRIOR_SOURCE_COMMIT = "bc7c904ad5648268e451ba9635c7bdbf9dc9a23b"
PRIOR_ARTIFACT_ID = 13915617831
PRIOR_ARTIFACT_NAME = f"task3-evidence-{PRIOR_RUN_ID}-{PRIOR_SOURCE_COMMIT}"
PRIOR_ARTIFACT_SHA256 = "7e634f5140f1a088b93b68a542b8d4cedfd369dbf1ad5d5c29987961eb503cad"

ELIGIBLE_PRIOR_REUSE_GROUPS = frozenset({
    "domain-1",
    "domain-3",
    "domain-4",
    "domain-5",
    "domain-6",
    "domain-7",
    "domain-8",
})
PRIOR_REUSED_DECLARATIONS = 55
PRIOR_REUSED_EXECUTIONS = 56
FRESH_WITH_PRIOR_DECLARATIONS = 28
FRESH_WITH_PRIOR_EXECUTIONS = 28
TOTAL_TARGET_DECLARATIONS = 83
TOTAL_TARGET_EXECUTIONS = 84

PRIOR_REUSE_CHANGED_TEST_PINS = frozenset({
    "Tests/ReaderDomainTests/EPUBAuthorStylesTests.swift",
    "Tests/YueJingHostTests/EPUBFontLoadingHostTests.swift",
    "Tests/YueJingHostTests/EPUBReaderHostTests.swift",
})
PRIOR_REUSE_ALLOWED_DIFF_PATHS = frozenset({
    "Tests/ReaderDomainTests/EPUBAuthorStylesTests.swift",
    "Tests/YueJingHostTests/EPUBFontLoadingHostTests.swift",
    "Tests/YueJingHostTests/EPUBReaderHostTests.swift",
    "scripts/run_epub_author_layout_validation.py",
    "scripts/check_epub_author_layout_validation.py",
    ".github/workflows/task3-validate.yml",
    "scripts/epub_author_layout_scope.json",
})

PRIOR2_RUN_ID = "43158884847"
PRIOR2_SOURCE_COMMIT = "b99156e7b7666c5a41d3ab57087d700267166d73"
PRIOR2_ARTIFACT_ID = 13918676262
PRIOR2_ARTIFACT_NAME = f"task3-evidence-{PRIOR2_RUN_ID}-{PRIOR2_SOURCE_COMMIT}"
PRIOR2_ARTIFACT_SHA256 = "3af4bd6ae9f33abbde481acd68bc7ea4a0d8b4b009ea2607a087ec459c2e2a7a"

ELIGIBLE_PRIOR2_REUSE_GROUPS = frozenset({
    "domain-2",
    "host-1",
    "host-2",
    "ui-1",
    "ui-2",
    "ui-3",
})
PRIOR2_REUSED_DECLARATIONS = 16
PRIOR2_REUSED_EXECUTIONS = 16
COMBINED_PRIOR2_REUSED_DECLARATIONS = PRIOR_REUSED_DECLARATIONS + PRIOR2_REUSED_DECLARATIONS
COMBINED_PRIOR2_REUSED_EXECUTIONS = PRIOR_REUSED_EXECUTIONS + PRIOR2_REUSED_EXECUTIONS
FRESH_WITH_PRIOR2_DECLARATIONS = 12
FRESH_WITH_PRIOR2_EXECUTIONS = 12

PRIOR2_REUSE_CHANGED_TEST_PINS = frozenset({
    "Tests/YueJingHostTests/EPUBReaderHostTests.swift",
})
PRIOR2_REUSE_ALLOWED_DIFF_PATHS = frozenset({
    "Tests/YueJingHostTests/EPUBReaderHostTests.swift",
    "scripts/run_epub_author_layout_validation.py",
    "scripts/check_epub_author_layout_validation.py",
    ".github/workflows/task3-validate.yml",
    "scripts/epub_author_layout_scope.json",
})
P2_RUN_ID = "43196231175"
P2_SOURCE = "f3e5a69ec2c903631389183b3fc6efba334b4ee9"
P2_ARTIFACT_ID = 13934927352
P2_ARTIFACT_SHA = "6acba54acba779b7a65881919777ddb8c47c87c580ac75965556fc62281f8553"
P2_FRESH = frozenset({"domain-1", "domain-7"})
P2_REUSED = frozenset({"domain-2", "domain-3", "domain-4", "domain-5", "domain-6",
                       "domain-8", "domain-9", "domain-10", "host-1", "host-2", "ui-1", "ui-2", "ui-3"})
P2_CHANGED_TESTS = frozenset({"Tests/ReaderDomainTests/EPUBAuthorStyleMigrationTests.swift",
                              "Tests/ReaderDomainTests/EPUBPackageTests.swift"})
P2_ALLOWED_DIFF = P2_CHANGED_TESTS | frozenset({"scripts/run_epub_author_layout_validation.py",
    "scripts/check_epub_author_layout_validation.py", "scripts/epub_author_layout_scope.json", WORKFLOW_PATH})
AUTHORIZED_PRIOR_RUNS = frozenset({PRIOR_RUN_ID, PRIOR2_RUN_ID, P2_RUN_ID})
QUALIFICATION = "EPUB_AUTHOR_LAYOUT_TARGETED_NATIVE"
COVERAGE = "EPUB_AUTHOR_LAYOUT_TARGETED_NOT_FULL"

SCOPE_JSON = OUT / "author-layout-scope.json"
CANDIDATE_SOURCES_JSON = OUT / "candidate-sources.json"
DISPATCH_EVENT_JSON = OUT / "dispatch-event.json"
GATE_JSON = OUT / "author-layout-gate.json"
PACKAGE_JSON = OUT / "author-layout-package.json"
REPORT_JSON = OUT / "case-results.json"
REPORT_MD = OUT / "case-results.md"
NATIVE_OUT = OUT / "epub-author-layout"
REUSED_OUT = OUT / "reused-evidence"
REUSED_GATE_JSON = REUSED_OUT / "reused-prior-gate.json"
REUSED_STAGING = ROOT / "build/reused-downloads"
INVOCATION_TIMEOUT_SECONDS = 480
CASE_TIMEOUT_SECONDS = 180
BOOT_TIMEOUT_SECONDS = 120

TARGET_KINDS = {
    "ReaderDomainTests": "domain",
    "YueJingHostTests": "host",
    "YueJingEPUBUITests": "ui",
}
PROTECTED_LOCAL_UNRELATED = frozenset({"AGENTS.md", "docs/CURRENT_STATUS.md", "docs/EPUB_AUTHOR_STYLES_ASSESSMENT.md"})
PRIVATE_LOCAL_UNTRACKED = frozenset({".architect_memory.json", "PROJECT_STATE.md", "ask_architect.py"})
MIXED_QUALIFICATION_FILES = (
    "native-test-gate.json",
    "epub-compat-gate.json",
    "epub-paging-gate.json",
    "epub-reading-gate.json",
    "epub-freeze-gate.json",
    "epub-diagnostic-scope.json",
    "reused-native-gate.json",
)


def _out_path(current, rel):
    return current if current != _DEFAULT_OUT / rel else OUT / rel


def _reused_out():
    return _out_path(REUSED_OUT, "reused-evidence")


def _reused_gate_json():
    default_gate = _DEFAULT_OUT / "reused-evidence/reused-prior-gate.json"
    if REUSED_GATE_JSON != default_gate:
        return REUSED_GATE_JSON
    return _reused_out() / "reused-prior-gate.json"


def _reused_staging():
    return REUSED_STAGING if REUSED_STAGING != _DEFAULT_ROOT / "build/reused-downloads" else ROOT / "build/reused-downloads"
def _safe_rel_path(value, label="path"):
    require(isinstance(value, str) and bool(value), f"Empty or non-string {label}")
    require(not value.startswith("/") and "\\" not in value and ":" not in value, f"Unsafe {label}: {value!r}")
    require(not any(ord(ch) < 32 for ch in value), f"Control character in {label}")
    posix = PurePosixPath(value)
    require(posix.parts and all(part not in ("", ".", "..") for part in posix.parts), f"Invalid {label}: {value!r}")
    require(posix.as_posix() == value, f"Non-canonical {label}: {value!r}")
    return value


def _candidate_files(root=ROOT):
    root = Path(root)
    if root == v.ROOT:
        return v.candidate_files()
    paths = [root / "project.yml"]
    for folder in ("App", "Sources", "Tests", "scripts", ".github/workflows"):
        base = root / folder
        if base.is_dir():
            paths += [p for p in base.rglob("*") if p.is_file() and p.suffix in (".swift", ".py", ".yml", ".txt")]
    return {p.relative_to(root).as_posix(): sha(p) for p in sorted(paths)}


def normalize_scope_config(cfg):
    require(isinstance(cfg, dict), "Scope config must be a JSON object")
    required_keys = {"baseline", "scope", "version", "build", "allowed_paths", "candidate_sha256", "selected_files"}
    require(required_keys <= set(cfg), "Missing required fields in scope config")
    require(cfg["baseline"] == BASE, f"Scope baseline mismatch: {cfg.get('baseline')!r}")
    require(cfg["scope"] == SCOPE, f"Scope identifier mismatch: {cfg.get('scope')!r}")
    require(cfg["version"] == VERSION and cfg["build"] == BUILD, "Scope version/build mismatch")

    allowed = cfg["allowed_paths"]
    require(isinstance(allowed, list) and allowed, "allowed_paths must be a non-empty list")
    normalized_allowed = [_safe_rel_path(item, "allowed_paths entry") for item in allowed]
    require(len(normalized_allowed) == len(set(normalized_allowed)), "Duplicate allowed_paths entry")
    require(not ((PROTECTED_LOCAL_UNRELATED | PRIVATE_LOCAL_UNTRACKED) & set(normalized_allowed)),
            "Protected/private files cannot be included in allowed_paths")

    pinned = cfg["candidate_sha256"]
    require(isinstance(pinned, dict) and pinned, "candidate_sha256 must be a non-empty mapping")
    normalized_pinned = {}
    for rel, digest_hex in pinned.items():
        clean_rel = _safe_rel_path(rel, "candidate_sha256 path")
        require(clean_rel not in (PROTECTED_LOCAL_UNRELATED | PRIVATE_LOCAL_UNTRACKED),
                "Protected/private file cannot be in candidate_sha256")
        require(isinstance(digest_hex, str) and bool(re.fullmatch(r"[0-9a-f]{64}", digest_hex)),
                f"Invalid SHA-256 in candidate_sha256 for {clean_rel}")
        normalized_pinned[clean_rel] = digest_hex

    selected = cfg["selected_files"]
    require(isinstance(selected, dict) and selected, "selected_files must be a non-empty mapping")
    normalized_selected = {}
    seen_cases = set()
    for rel, names in selected.items():
        clean_rel = _safe_rel_path(rel, "selected_files key")
        target = clean_rel.split("/", 1)[0]
        require("/" in clean_rel and clean_rel.endswith(".swift") and target in TARGET_KINDS,
                f"Unsupported selected_files target/path: {clean_rel}")
        if target == "YueJingEPUBUITests":
            require(clean_rel == "YueJingEPUBUITests/EPUBFlowUITests.swift",
                    f"Unsupported UI test file for EPUBFlowUITests parser: {clean_rel}")
        require(isinstance(names, list) and names, f"Selected case list must be non-empty for {clean_rel}")
        clean_names = []
        for name in names:
            require(isinstance(name, str) and bool(re.fullmatch(r"[A-Za-z_]\w*", name)),
                    f"Invalid test case name {name!r} in {clean_rel}")
            require(name not in seen_cases, f"Duplicate selected case identity across selection: {name}")
            seen_cases.add(name)
            clean_names.append(name)
        normalized_selected[clean_rel] = clean_names

    return {
        "baseline": BASE,
        "scope": SCOPE,
        "version": VERSION,
        "build": BUILD,
        "allowed_paths": normalized_allowed,
        "candidate_sha256": normalized_pinned,
        "selected_files": normalized_selected,
    }


def load_scope_config(path=None):
    cfg_path = Path(path) if path is not None else SCOPE_CONFIG_JSON
    return normalize_scope_config(load(cfg_path))

def build_groups(config):
    """Group by non-UI file; UI is always one case per group."""
    groups = {}
    counters = {"domain": 0, "host": 0, "ui": 0}
    ordered = sorted(
        config["selected_files"].items(),
        key=lambda item: (("domain", "host", "ui").index(TARGET_KINDS[item[0].split("/", 1)[0]]), item[0]),
    )
    for rel, cases in ordered:
        target = rel.split("/", 1)[0]
        kind = TARGET_KINDS[target]
        suite = rel.removesuffix(".swift")
        if kind == "ui":
            for case in cases:
                counters["ui"] += 1
                group_id = f"ui-{counters['ui']}"
                groups[group_id] = {
                    "group": group_id,
                    "kind": kind,
                    "target": target,
                    "file": rel,
                    "suite": suite,
                    "timeout": INVOCATION_TIMEOUT_SECONDS,
                    "case_timeout": CASE_TIMEOUT_SECONDS,
                    "pairs": [(rel, case)],
                    "cases": [case],
                }
        else:
            counters[kind] += 1
            group_id = f"{kind}-{counters[kind]}"
            groups[group_id] = {
                "group": group_id,
                "kind": kind,
                "target": target,
                "file": rel,
                "suite": suite,
                "timeout": INVOCATION_TIMEOUT_SECONDS,
                "case_timeout": CASE_TIMEOUT_SECONDS,
                "pairs": [(rel, case) for case in cases],
                "cases": list(cases),
            }
    require(groups, "No execution groups constructed")
    return groups
def _planned_group_executions(spec):
    return sum(len(inventory.PARAMETERIZED.get(case, {}).get("values", [None])) for case in spec["cases"])

def _prior_spec(prior_id):
    pid = str(prior_id)
    if pid == P2_RUN_ID:
        return dict(run_id=P2_RUN_ID, source_commit=P2_SOURCE, artifact_id=P2_ARTIFACT_ID,
                    artifact_name=f"task3-evidence-{P2_RUN_ID}-{P2_SOURCE}", archive_sha256=P2_ARTIFACT_SHA,
                    groups=P2_REUSED, declarations=83, executions=84,
                    changed_pins=P2_CHANGED_TESTS, allowed_diff_paths=P2_ALLOWED_DIFF)
    if pid == PRIOR_RUN_ID:
        return {
            "run_id": PRIOR_RUN_ID,
            "source_commit": PRIOR_SOURCE_COMMIT,
            "artifact_id": PRIOR_ARTIFACT_ID,
            "artifact_name": PRIOR_ARTIFACT_NAME,
            "archive_sha256": PRIOR_ARTIFACT_SHA256,
            "groups": ELIGIBLE_PRIOR_REUSE_GROUPS,
            "declarations": PRIOR_REUSED_DECLARATIONS,
            "executions": PRIOR_REUSED_EXECUTIONS,
            "changed_pins": PRIOR_REUSE_CHANGED_TEST_PINS,
            "allowed_diff_paths": PRIOR_REUSE_ALLOWED_DIFF_PATHS,
        }
    if pid == PRIOR2_RUN_ID:
        return {
            "run_id": PRIOR2_RUN_ID,
            "source_commit": PRIOR2_SOURCE_COMMIT,
            "artifact_id": PRIOR2_ARTIFACT_ID,
            "artifact_name": PRIOR2_ARTIFACT_NAME,
            "archive_sha256": PRIOR2_ARTIFACT_SHA256,
            "groups": ELIGIBLE_PRIOR2_REUSE_GROUPS,
            "declarations": PRIOR2_REUSED_DECLARATIONS,
            "executions": PRIOR2_REUSED_EXECUTIONS,
            "changed_pins": PRIOR2_REUSE_CHANGED_TEST_PINS,
            "allowed_diff_paths": PRIOR2_REUSE_ALLOWED_DIFF_PATHS,
        }
    raise ValueError(f"Unsupported prior_validation_run: {prior_id!r}")


def _prior_origin_ids(prior_validation_run):
    if not prior_validation_run:
        return []
    if prior_validation_run == P2_RUN_ID:
        return [P2_RUN_ID]
    if prior_validation_run == PRIOR_RUN_ID:
        return [PRIOR_RUN_ID]
    if prior_validation_run == PRIOR2_RUN_ID:
        return [PRIOR_RUN_ID, PRIOR2_RUN_ID]
    raise ValueError(f"Unsupported prior_validation_run: {prior_validation_run!r}")


def _prior_origins_plan(prior_validation_run, groups=None):
    origins = []
    for oid in _prior_origin_ids(prior_validation_run):
        spec = _prior_spec(oid)
        reused_groups = (
            [g for g in groups if g in spec["groups"]]
            if groups is not None
            else sorted(spec["groups"])
        )
        origins.append({
            "run_id": spec["run_id"],
            "source_commit": spec["source_commit"],
            "artifact_id": spec["artifact_id"],
            "artifact_name": spec["artifact_name"],
            "archive_sha256": spec["archive_sha256"],
            "groups": reused_groups,
            "declarations": spec["declarations"],
            "executions": spec["executions"],
        })
    return origins


def partition_groups(groups, prior_validation_run=""):
    if not prior_validation_run:
        return list(groups), []
    if prior_validation_run == P2_RUN_ID:
        require(set(groups) == P2_FRESH | P2_REUSED, "P2 group identity drift")
        fresh = [g for g in groups if g in P2_FRESH]
        reused = [g for g in groups if g in P2_REUSED]
        require({"Tests/" + groups[g]["file"] for g in fresh} == P2_CHANGED_TESTS, "P2 changed test selection drift")
        require(sum(len(groups[g]["cases"]) for g in fresh) == 15
                and sum(len(groups[g]["cases"]) for g in reused) == 83
                and sum(_planned_group_executions(groups[g]) for g in reused) == 84,
                "P2 15 fresh + 83/84 reused partition drift")
        return fresh, reused
    require(
        prior_validation_run in AUTHORIZED_PRIOR_RUNS,
        f"Only pinned prior validation runs {sorted(AUTHORIZED_PRIOR_RUNS)} are authorized for bounded reuse",
    )
    if prior_validation_run == PRIOR_RUN_ID:
        require(ELIGIBLE_PRIOR_REUSE_GROUPS <= set(groups),
                "Selected scope groups missing eligible prior reuse groups")
        reused_ids = [g for g in groups if g in ELIGIBLE_PRIOR_REUSE_GROUPS]
        fresh_ids = [g for g in groups if g not in ELIGIBLE_PRIOR_REUSE_GROUPS]
        require(len(reused_ids) == len(ELIGIBLE_PRIOR_REUSE_GROUPS) == 7 and len(fresh_ids) == 7,
                f"Unexpected fresh/reused group partition: {len(fresh_ids)}/{len(reused_ids)}")
        for g in reused_ids:
            spec = groups[g]
            require(spec["kind"] == "domain" and ("Tests/" + spec["file"]) not in PRIOR_REUSE_CHANGED_TEST_PINS,
                    f"Changed or non-domain group cannot be reused: {g}")
        reused_decl = sum(len(groups[g]["cases"]) for g in reused_ids)
        reused_exec = sum(_planned_group_executions(groups[g]) for g in reused_ids)
        fresh_decl = sum(len(groups[g]["cases"]) for g in fresh_ids)
        fresh_exec = sum(_planned_group_executions(groups[g]) for g in fresh_ids)
        require(
            reused_decl == PRIOR_REUSED_DECLARATIONS
            and reused_exec == PRIOR_REUSED_EXECUTIONS
            and fresh_decl == FRESH_WITH_PRIOR_DECLARATIONS
            and fresh_exec == FRESH_WITH_PRIOR_EXECUTIONS
            and reused_decl + fresh_decl == TOTAL_TARGET_DECLARATIONS
            and reused_exec + fresh_exec == TOTAL_TARGET_EXECUTIONS,
            f"Bounded reuse partition counts mismatch: fresh={fresh_decl}/{fresh_exec}, reused={reused_decl}/{reused_exec}",
        )
        return fresh_ids, reused_ids

    require(not (ELIGIBLE_PRIOR_REUSE_GROUPS & ELIGIBLE_PRIOR2_REUSE_GROUPS),
            "Dual prior reuse group sets must be disjoint")
    all_reused = ELIGIBLE_PRIOR_REUSE_GROUPS | ELIGIBLE_PRIOR2_REUSE_GROUPS
    require(all_reused <= set(groups),
            "Selected scope groups missing eligible dual-prior reuse groups")
    reused_ids = [g for g in groups if g in all_reused]
    fresh_ids = [g for g in groups if g not in all_reused]
    require(
        len(reused_ids) == len(all_reused) == 13
        and fresh_ids == ["host-3"]
        and groups["host-3"]["kind"] == "host"
        and groups["host-3"]["file"] == "YueJingHostTests/EPUBReaderHostTests.swift",
        f"Unexpected dual-prior fresh/reused group partition: {fresh_ids}/{len(reused_ids)}",
    )
    for g in ELIGIBLE_PRIOR_REUSE_GROUPS:
        spec = groups[g]
        require(spec["kind"] == "domain" and ("Tests/" + spec["file"]) not in PRIOR_REUSE_CHANGED_TEST_PINS,
                f"Changed or non-domain group cannot be reused from prior1: {g}")
    for g in ELIGIBLE_PRIOR2_REUSE_GROUPS:
        spec = groups[g]
        require(("Tests/" + spec["file"]) not in PRIOR2_REUSE_CHANGED_TEST_PINS,
                f"Changed group cannot be reused from prior2: {g}")
    p1_decl = sum(len(groups[g]["cases"]) for g in groups if g in ELIGIBLE_PRIOR_REUSE_GROUPS)
    p1_exec = sum(_planned_group_executions(groups[g]) for g in groups if g in ELIGIBLE_PRIOR_REUSE_GROUPS)
    p2_decl = sum(len(groups[g]["cases"]) for g in groups if g in ELIGIBLE_PRIOR2_REUSE_GROUPS)
    p2_exec = sum(_planned_group_executions(groups[g]) for g in groups if g in ELIGIBLE_PRIOR2_REUSE_GROUPS)
    reused_decl = p1_decl + p2_decl
    reused_exec = p1_exec + p2_exec
    fresh_decl = sum(len(groups[g]["cases"]) for g in fresh_ids)
    fresh_exec = sum(_planned_group_executions(groups[g]) for g in fresh_ids)
    require(
        p1_decl == PRIOR_REUSED_DECLARATIONS
        and p1_exec == PRIOR_REUSED_EXECUTIONS
        and p2_decl == PRIOR2_REUSED_DECLARATIONS
        and p2_exec == PRIOR2_REUSED_EXECUTIONS
        and reused_decl == COMBINED_PRIOR2_REUSED_DECLARATIONS
        and reused_exec == COMBINED_PRIOR2_REUSED_EXECUTIONS
        and fresh_decl == FRESH_WITH_PRIOR2_DECLARATIONS
        and fresh_exec == FRESH_WITH_PRIOR2_EXECUTIONS
        and reused_decl + fresh_decl == TOTAL_TARGET_DECLARATIONS
        and reused_exec + fresh_exec == TOTAL_TARGET_EXECUTIONS,
        f"Dual-prior reuse partition counts mismatch: fresh={fresh_decl}/{fresh_exec}, p1={p1_decl}/{p1_exec}, p2={p2_decl}/{p2_exec}",
    )
    return fresh_ids, reused_ids

def validate_selected_cases(config, root=ROOT):
    root = Path(root)
    reviewed = inventory.validate_source(root)
    selected_files = config["selected_files"]
    all_selected = []
    kind_counts = {"domain": 0, "host": 0, "ui": 0}
    for rel, cases in selected_files.items():
        require(rel in inventory.FILES, f"Selected file missing from reviewed inventory: {rel}")
        source_file = root / "Tests" / rel
        require(source_file.is_file() and not source_file.is_symlink(), f"Missing regular selected source: {rel}")
        declared = inventory.source_names(rel, source_file.read_text(encoding="utf-8"))
        inv_declared = inventory.FILES[rel].split()
        require(declared == inv_declared, f"Source declarations differ from inventory: {rel}")
        require(set(cases) <= set(inv_declared), f"Selected cases missing from inventory in {rel}")
        kind = TARGET_KINDS[rel.split("/", 1)[0]]
        kind_counts[kind] += len(cases)
        all_selected.extend(cases)
    require(len(all_selected) == len(set(all_selected)) and all_selected, "Selected case union must be unique and non-empty")
    planned_executions = sum(len(inventory.PARAMETERIZED.get(name, {}).get("values", [None])) for name in all_selected)
    return {
        "selected_declarations": len(all_selected),
        "planned_executions": planned_executions,
        "kind_declarations": kind_counts,
        "full_inventory_declared": reviewed["selected"],
        "full_inventory_executions": reviewed["selected_executions"],
        "selected_files": {k: list(v) for k, v in selected_files.items()},
    }


def validate_project_version(root=ROOT):
    project_path = Path(root) / "project.yml"
    require(project_path.is_file() and not project_path.is_symlink(), "Missing regular project.yml")
    identity = package_ipa.expected_project_identity(project_path)
    require(identity["version"] == VERSION and identity["build"] == BUILD,
            f"project.yml identity {identity['version']}/{identity['build']} differs from {VERSION}/{BUILD}")
    return identity


def _git_is_ancestor(base, head, root=ROOT):
    return subprocess.run(
        ["git", "merge-base", "--is-ancestor", base, head],
        cwd=root,
        capture_output=True,
        timeout=30,
    ).returncode == 0


def _parse_git_status(status_bytes, *, pending, allowed_paths):
    raw_status = status_bytes.decode("utf-8") if isinstance(status_bytes, (bytes, bytearray)) else str(status_bytes)
    working_allowed = set()
    for entry in raw_status.split("\0"):
        if not entry:
            continue
        require(len(entry) > 3 and entry[2] == " ", "Malformed git status entry")
        xy, path_str = entry[:2], entry[3:]
        if "R" in xy or "C" in xy:
            raise ValueError("Renamed/copied path is not approved: " + path_str)
        if "D" in xy:
            raise ValueError("Deleted path is not approved: " + path_str)
        if not pending:
            raise ValueError("Clean committed source required; dirty/untracked path: " + path_str)
        if path_str in PROTECTED_LOCAL_UNRELATED:
            continue
        if xy == "??" and path_str in PRIVATE_LOCAL_UNTRACKED:
            continue
        require(path_str in allowed_paths, "Unapproved working-tree or untracked change: " + path_str)
        working_allowed.add(path_str)
    return working_allowed


def validate_scope_boundaries(
    previous,
    current,
    *,
    head,
    is_ancestor,
    status_bytes,
    config,
    pending=False,
    root=ROOT,
):
    root = Path(root)
    require(not pending or os.environ.get("GITHUB_ACTIONS") != "true", "Cloud cannot use pending source")
    require(isinstance(head, str) and bool(re.fullmatch(r"[0-9a-f]{40}", head)), "Invalid HEAD commit")
    require(is_ancestor is True, "BASE commit is not an ancestor of HEAD")
    require(isinstance(previous, dict) and isinstance(current, dict) and previous and current, "Invalid git tree")
    require(
        all(
            isinstance(meta, list)
            and len(meta) >= 3
            and meta[:2] == ["100644", "blob"]
            and re.fullmatch(r"[0-9a-f]{40}", meta[2])
            for meta in current.values()
        ),
        "Nonregular tracked input in HEAD",
    )
    deleted = set(previous) - set(current)
    require(not deleted, "Tracked baseline files deleted: " + repr(sorted(deleted)))

    allowed = set(config["allowed_paths"])
    committed_changed = {p for p in set(previous) | set(current) if previous.get(p) != current.get(p)}
    require(committed_changed <= allowed,
            "Committed changes outside allowed_paths: " + repr(sorted(committed_changed - allowed)))

    working_allowed = _parse_git_status(status_bytes, pending=pending, allowed_paths=allowed)

    if not pending:
        require(head != BASE, "HEAD must advance beyond BASE")
        require(committed_changed, "No committed changes relative to BASE")
        changed = committed_changed
    else:
        changed = committed_changed | working_allowed
        require(changed, "No approved changes relative to BASE")

    root_resolved = root.resolve()
    for path_str, meta in current.items():
        if pending and path_str in PROTECTED_LOCAL_UNRELATED:
            continue
        file_path = root / path_str
        require(
            file_path.is_file()
            and not file_path.is_symlink()
            and file_path.resolve().is_relative_to(root_resolved),
            "Missing or nonregular tracked file: " + path_str,
        )
        if not (pending and path_str in working_allowed):
            require(git_blob_sha1(file_path.read_bytes()) == meta[2],
                    "Worktree differs from committed HEAD blob: " + path_str)

    for path_str in working_allowed:
        file_path = root / path_str
        require(
            file_path.is_file()
            and not file_path.is_symlink()
            and file_path.resolve().is_relative_to(root_resolved),
            "Missing or nonregular pending allowed file: " + path_str,
        )

    candidate_map = _candidate_files(root)
    if not pending:
        require(set(candidate_map) <= set(current), "Untracked candidate source file not committed in HEAD")
        require(set(config["candidate_sha256"]) <= set(current), "Candidate pinned file not committed in HEAD")
        config_rel = "scripts/epub_author_layout_scope.json"
        if (root / config_rel).exists():
            require(config_rel in current, "Scope config JSON must belong to committed HEAD")

    for path_str, expected_sha in config["candidate_sha256"].items():
        file_path = root / path_str
        require(
            file_path.is_file()
            and not file_path.is_symlink()
            and file_path.resolve().is_relative_to(root_resolved),
            "Missing or nonregular candidate_sha256 file: " + path_str,
        )
        actual_sha = sha(file_path)
        require(actual_sha == expected_sha, f"Candidate byte SHA mismatch for {path_str}")

    return {
        "source_commit": head,
        "source_status": "pending" if pending else "clean",
        "changed_paths": sorted(changed),
        "added_paths": sorted(set(current) - set(previous)),
        "allowed_paths": sorted(allowed),
        "candidate_files": candidate_map,
    }


def validate_prior_source_compatibility(
    prior_tree,
    current_tree,
    prior_config,
    current_config,
    *,
    head,
    is_prior_ancestor,
    status_bytes=b"",
    pending=False,
    prior_candidate_files=None,
    current_candidate_files=None,
    prior_inventory=None,
    current_inventory=None,
    prior_commit=None,
    allowed_diff_paths=None,
    changed_test_pins=None,
):
    expected_prior_commit = PRIOR_SOURCE_COMMIT if prior_commit is None else prior_commit
    allowed_diff = PRIOR_REUSE_ALLOWED_DIFF_PATHS if allowed_diff_paths is None else allowed_diff_paths
    allowed_pins = PRIOR_REUSE_CHANGED_TEST_PINS if changed_test_pins is None else changed_test_pins
    require(not pending or os.environ.get("GITHUB_ACTIONS") != "true", "Cloud cannot use pending source")
    require(isinstance(head, str) and bool(re.fullmatch(r"[0-9a-f]{40}", head)), "Invalid HEAD commit")
    require(is_prior_ancestor is True, f"Prior source commit {expected_prior_commit} is not an ancestor of HEAD")
    if not pending:
        require(head != expected_prior_commit, "HEAD must advance beyond prior source commit for reuse")
    require(isinstance(prior_tree, dict) and isinstance(current_tree, dict) and prior_tree and current_tree,
            "Invalid prior/current git tree")
    require(
        all(
            isinstance(meta, list)
            and len(meta) >= 3
            and meta[:2] == ["100644", "blob"]
            and re.fullmatch(r"[0-9a-f]{40}", meta[2])
            for meta in current_tree.values()
        ),
        "Nonregular tracked input in HEAD",
    )
    deleted = set(prior_tree) - set(current_tree)
    require(not deleted, "Tracked files deleted since prior run: " + repr(sorted(deleted)))
    added = set(current_tree) - set(prior_tree)
    require(not added, "Unexpected new files added since prior run: " + repr(sorted(added)))

    committed_changed = {p for p in set(prior_tree) | set(current_tree) if prior_tree.get(p) != current_tree.get(p)}
    require(
        committed_changed <= allowed_diff,
        "Committed changes from prior source outside allowed repair boundary: "
        + repr(sorted(committed_changed - allowed_diff)),
    )

    working_allowed = _parse_git_status(status_bytes, pending=pending, allowed_paths=allowed_diff)
    if not pending:
        require(committed_changed, "No committed changes relative to prior source commit")
        changed = committed_changed
    else:
        changed = committed_changed | working_allowed
        require(changed <= allowed_diff,
                "Pending changes outside prior reuse diff boundary: "
                + repr(sorted(changed - allowed_diff)))

    fields = ("baseline", "scope", "version", "build", "selected_files")
    for field in fields:
        require(prior_config[field] == current_config[field], f"Scope config {field} changed since prior run")
    if expected_prior_commit == P2_SOURCE:
        require(set(current_config["allowed_paths"]) == set(prior_config["allowed_paths"]) |
                {WORKFLOW_PATH, "Tests/ReaderDomainTests/EPUBPackageTests.swift"}, "P2 allowed path drift")
        require(set(current_config["candidate_sha256"]) == set(prior_config["candidate_sha256"]) |
                {"Tests/ReaderDomainTests/EPUBPackageTests.swift"}, "P2 candidate key drift")
    else:
        require(prior_config["allowed_paths"] == current_config["allowed_paths"], "Scope config allowed_paths changed since prior run")
        require(set(prior_config["candidate_sha256"]) == set(current_config["candidate_sha256"]),
                "Scope candidate_sha256 keys changed since prior run")
    changed_pins = {
        path_str for path_str in current_config["candidate_sha256"]
        if current_config["candidate_sha256"][path_str] != prior_config["candidate_sha256"].get(path_str)
    }
    require(
        changed_pins <= allowed_pins,
        "Changed candidate_sha256 outside repaired test files: "
        + repr(sorted(changed_pins - allowed_pins)),
    )

    if prior_candidate_files is not None and current_candidate_files is not None:
        require(set(prior_candidate_files) == set(current_candidate_files),
                "Candidate file inventory changed since prior run")
        changed_cand = {
            path_str for path_str in current_candidate_files
            if current_candidate_files[path_str] != prior_candidate_files[path_str]
        }
        require(
            changed_cand <= allowed_diff,
            "Production/build/helper/reused-test candidate bytes changed since prior run: "
            + repr(sorted(changed_cand - allowed_diff)),
        )

    if prior_inventory is not None and current_inventory is not None:
        require(prior_inventory == current_inventory, "Reviewed inventory changed since prior run")

    return {
        "prior_source_commit": expected_prior_commit,
        "changed_from_prior": sorted(changed),
        "changed_test_pins": sorted(changed_pins),
    }

def verify_source(*, pending=False, root=ROOT, prior_validation_run=""):
    root = Path(root)
    require(not pending or os.environ.get("GITHUB_ACTIONS") != "true", "Cloud cannot use pending source")
    cfg_path = SCOPE_CONFIG_JSON if root == ROOT else root / "scripts/epub_author_layout_scope.json"
    config = load_scope_config(cfg_path)
    selected_summary = validate_selected_cases(config, root=root)
    validate_project_version(root=root)

    head = compat.git("rev-parse", "HEAD", root=root).decode("utf-8").strip()
    is_ancestor = _git_is_ancestor(BASE, head, root=root)
    previous = compat.git_tree(BASE, root=root)
    current = compat.git_tree("HEAD", root=root)
    status_bytes = compat.git("status", "--porcelain=v1", "-z", "--untracked-files=all", root=root)

    source = validate_scope_boundaries(
        previous,
        current,
        head=head,
        is_ancestor=is_ancestor,
        status_bytes=status_bytes,
        config=config,
        pending=pending,
        root=root,
    )
    result = {
        "scope": SCOPE,
        "baseline_commit": BASE,
        "version": VERSION,
        "build": BUILD,
        **source,
        "selected_summary": selected_summary,
        "candidate_sha256": dict(config["candidate_sha256"]),
        "scope_config_sha256": sha(cfg_path),
    }
    if prior_validation_run:
        require(
            prior_validation_run in AUTHORIZED_PRIOR_RUNS,
            f"Only pinned prior validation runs {sorted(AUTHORIZED_PRIOR_RUNS)} are authorized for bounded reuse",
        )
        origins_compat = {}
        for oid in _prior_origin_ids(prior_validation_run):
            spec = _prior_spec(oid)
            is_prior_ancestor = _git_is_ancestor(spec["source_commit"], head, root=root)
            prior_tree = compat.git_tree(spec["source_commit"], root=root)
            prior_cfg_raw = compat.git("show", f"{spec['source_commit']}:scripts/epub_author_layout_scope.json", root=root)
            prior_config = normalize_scope_config(json.loads(prior_cfg_raw.decode("utf-8")))
            origins_compat[oid] = validate_prior_source_compatibility(
                prior_tree,
                current,
                prior_config,
                config,
                head=head,
                is_prior_ancestor=is_prior_ancestor,
                status_bytes=status_bytes,
                pending=pending,
                prior_commit=spec["source_commit"],
                allowed_diff_paths=spec["allowed_diff_paths"],
                changed_test_pins=spec["changed_pins"],
            )
        result["prior_origins_compat"] = origins_compat
        result["prior_source_compat"] = origins_compat[prior_validation_run]
    return result


def dispatch_context():
    env = os.environ
    require(
        env.get("VALIDATION_SCOPE") == SCOPE
        and env.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
        and env.get("GITHUB_REF") == "refs/heads/main"
        and env.get("GITHUB_RUN_ATTEMPT") == "1"
        and env.get("GITHUB_REPOSITORY") == REPO,
        "Unapproved workflow_dispatch identity/ref/attempt/repo/scope",
    )
    wf_ref = env.get("GITHUB_WORKFLOW_REF")
    if wf_ref:
        require(wf_ref.startswith(f"{REPO}/{WORKFLOW_PATH}@"), "Workflow ref mismatch")
    require(bool(re.fullmatch(r"[1-9][0-9]*", env.get("GITHUB_RUN_ID", ""))), "Invalid GITHUB_RUN_ID")
    require(bool(re.fullmatch(r"[0-9a-f]{40}", env.get("GITHUB_SHA", ""))), "Invalid GITHUB_SHA")

    event_path = Path(env["GITHUB_EVENT_PATH"])
    event = load(event_path)
    if "ref" in event:
        require(event["ref"] == "refs/heads/main", "Dispatch payload ref mismatch")
    if "repository" in event:
        require(isinstance(event["repository"], dict) and event["repository"].get("full_name") == REPO,
                "Dispatch payload repository mismatch")
    if "workflow" in event and event["workflow"]:
        require(event["workflow"] in (WORKFLOW_PATH, "Task 3 tests and conditional unsigned IPA"),
                "Dispatch payload workflow mismatch")
    if "workflow_id" in event:
        require(event["workflow_id"] == WORKFLOW_ID, "Dispatch payload workflow_id mismatch")

    inputs = event.get("inputs")
    require(isinstance(inputs, dict), "Missing dispatch inputs")
    require(inputs.get("validation_scope") == SCOPE, "Dispatch input validation_scope mismatch")

    allow_val = inputs.get("allow_unqualified_ipa", False)
    require(type(allow_val) is bool or allow_val in ("true", "false"), "Invalid allow_unqualified_ipa input")
    allowed = allow_val is True or allow_val == "true"
    require(not allowed, "Diagnostic allow_unqualified_ipa is disabled for author-layout")
    require(env.get("ALLOW_UNQUALIFIED_IPA") == "false", "ALLOW_UNQUALIFIED_IPA must be false")

    raw_prior = inputs.get("prior_validation_run", "")
    prior = "" if raw_prior is None else raw_prior
    require(
        isinstance(prior, str) and (prior == "" or prior in AUTHORIZED_PRIOR_RUNS),
        f"prior_validation_run must be empty or pinned {sorted(AUTHORIZED_PRIOR_RUNS)}",
    )
    require(env.get("PRIOR_VALIDATION_RUN", "") == prior, "PRIOR_VALIDATION_RUN differs from dispatch")
    if prior:
        require(prior not in _prior_origin_ids(prior) or env.get("GITHUB_RUN_ID") not in _prior_origin_ids(prior),
                "Self-referential prior_validation_run rejected")
    raw_build = inputs.get("build_ipa", False)
    require(type(raw_build) is bool or raw_build in ("true", "false"), "Invalid build_ipa input")
    build_ipa = raw_build is True or raw_build == "true"
    require(env.get("BUILD_IPA") == ("true" if build_ipa else "false"), "BUILD_IPA differs from dispatch")

    return {
        "allow_unqualified_ipa": False,
        "prior_validation_run": prior,
        "build_ipa": build_ipa,
        "dispatch_event_sha256": sha(event_path),
    }


def scope_receipt(root=ROOT):
    root = Path(root)
    dispatch = dispatch_context()
    prior = dispatch["prior_validation_run"]
    source = verify_source(pending=False, root=root, prior_validation_run=prior)
    head = source["source_commit"]
    require(head == os.environ.get("GITHUB_SHA"), "HEAD differs from GITHUB_SHA")

    config = load_scope_config(SCOPE_CONFIG_JSON if root == ROOT else root / "scripts/epub_author_layout_scope.json")
    groups = build_groups(config)
    fresh_ids, reused_ids = partition_groups(groups, prior)
    reviewed = inventory.validate_source(root)
    selected_summary = source["selected_summary"]

    fresh_decl = sum(len(groups[g]["cases"]) for g in fresh_ids)
    fresh_exec = sum(_planned_group_executions(groups[g]) for g in fresh_ids)
    reused_decl = sum(len(groups[g]["cases"]) for g in reused_ids)
    reused_exec = sum(_planned_group_executions(groups[g]) for g in reused_ids)

    approved_files = {}
    root_resolved = root.resolve()
    for p in source["allowed_paths"]:
        fp = root / p
        if fp.exists() or fp.is_symlink():
            require(fp.is_file() and not fp.is_symlink() and fp.resolve().is_relative_to(root_resolved),
                    "Invalid approved path: " + p)
            approved_files[p] = sha(fp)
        else:
            approved_files[p] = None

    prior_spec = _prior_spec(prior) if prior else None
    prior_origins = _prior_origins_plan(prior, groups=groups)
    reused_group_origins = {
        g: next(oid for oid in _prior_origin_ids(prior) if g in _prior_spec(oid)["groups"])
        for g in reused_ids
    }
    return {
        "scope": SCOPE,
        "phase": "validation",
        "prior_validation_run": prior,
        "prior_source_commit": prior_spec["source_commit"] if prior_spec else "",
        "prior_artifact_id": prior_spec["artifact_id"] if prior_spec else None,
        "prior_artifact_sha256": prior_spec["archive_sha256"] if prior_spec else "",
        "prior_origins": prior_origins,
        "reused_group_origins": reused_group_origins,
        "source_commit": head,
        "source_status": "clean",
        "baseline_commit": BASE,
        "run_id": os.environ["GITHUB_RUN_ID"],
        "run_attempt": "1",
        "repository": REPO,
        "ref": "refs/heads/main",
        "workflow_id": WORKFLOW_ID,
        "workflow_path": WORKFLOW_PATH,
        "version": VERSION,
        "build": BUILD,
        "allow_unqualified_ipa": False,
        "build_ipa": dispatch["build_ipa"],
        "dispatch_event_sha256": dispatch["dispatch_event_sha256"],
        "scope_config_sha256": source["scope_config_sha256"],
        "changed_paths": source["changed_paths"],
        "added_paths": source["added_paths"],
        "allowed_paths": source["allowed_paths"],
        "approved_files": approved_files,
        "candidate_sha256": source["candidate_sha256"],
        "files": source["candidate_files"],
        "selected_files": selected_summary["selected_files"],
        "selected": {g: list(spec["cases"]) for g, spec in groups.items()},
        "fresh_groups": fresh_ids,
        "reused_groups": reused_ids,
        "fresh_selected": {g: list(groups[g]["cases"]) for g in fresh_ids},
        "reused_selected": {g: list(groups[g]["cases"]) for g in reused_ids},
        "selected_declarations": selected_summary["selected_declarations"],
        "native_tests_planned": selected_summary["planned_executions"],
        "fresh_declarations_planned": fresh_decl,
        "fresh_executions_planned": fresh_exec,
        "reused_declarations_planned": reused_decl,
        "reused_executions_planned": reused_exec,
        "full_inventory_declared": reviewed["selected"],
        "full_inventory_executions": reviewed["selected_executions"],
        "physical_acceptance": "not performed",
        "full_regression_passed": False,
    }

def write_scope(root=ROOT):
    receipt = scope_receipt(root=root)
    raw_event = Path(os.environ["GITHUB_EVENT_PATH"]).read_bytes()
    require(digest_bytes(raw_event) == receipt["dispatch_event_sha256"], "Dispatch event changed")
    candidate_doc = {
        "source_commit": receipt["source_commit"],
        "run_id": receipt["run_id"],
        "run_attempt": "1",
        "files": receipt["files"],
        "inventory": inventory.validate_source(root),
    }
    scope_out = _out_path(SCOPE_JSON, "author-layout-scope.json")
    cand_out = _out_path(CANDIDATE_SOURCES_JSON, "candidate-sources.json")
    event_out = _out_path(DISPATCH_EVENT_JSON, "dispatch-event.json")
    for target in (scope_out, cand_out, event_out):
        require(not target.exists() and not target.is_symlink(), f"Existing scope artifact; never overwrite: {target.name}")
    cand_out.parent.mkdir(parents=True, exist_ok=True)
    write(cand_out, candidate_doc)
    with event_out.open("xb") as stream:
        stream.write(raw_event)
    write(scope_out, receipt)
    return receipt


def live_scope(root=ROOT):
    receipt = scope_receipt(root=root)
    scope_out = _out_path(SCOPE_JSON, "author-layout-scope.json")
    cand_out = _out_path(CANDIDATE_SOURCES_JSON, "candidate-sources.json")
    event_out = _out_path(DISPATCH_EVENT_JSON, "dispatch-event.json")
    require(load(scope_out) == receipt, "Frozen scope/source/run drift")
    require(event_out.is_file() and not event_out.is_symlink(), "Invalid saved dispatch event")
    require(sha(event_out) == receipt["dispatch_event_sha256"], "Saved dispatch event drift")
    expected_cand = {
        "source_commit": receipt["source_commit"],
        "run_id": receipt["run_id"],
        "run_attempt": "1",
        "files": receipt["files"],
        "inventory": inventory.validate_source(root),
    }
    require(load(cand_out) == expected_cand, "Candidate/source/inventory drift")
    return receipt


class GroupPrerequisiteError(ValueError):
    """A shared target prerequisite failed before individual cases could run."""


def command_for_spec(spec, destination, result_bundle):
    return freeze.command_for_spec(spec, destination, result_bundle)


def command(group, destination, result_bundle, *, groups=None):
    active_groups = groups if groups is not None else build_groups(load_scope_config())
    require(group in active_groups, "Unknown group: " + str(group))
    return command_for_spec(active_groups[group], destination, result_bundle)


def provenance(group, destination, bundle, scope, *, groups=None):
    active_groups = groups if groups is not None else build_groups(load_scope_config())
    require(group in active_groups, "Unknown group: " + str(group))
    spec = active_groups[group]
    return {
        "scope": SCOPE,
        "source_commit": scope["source_commit"],
        "run_id": scope["run_id"],
        "run_attempt": "1",
        "group": group,
        "target": spec["target"],
        "file": spec["file"],
        "destination": destination,
        "expected_cases": list(spec["cases"]),
        "command": command_for_spec(spec, destination, bundle),
        "timeout_seconds": spec["timeout"],
        "case_timeout_seconds": spec["case_timeout"],
    }


stream_case = freeze.stream_case


def xcresult_export(bundle, section):
    return freeze.xcresult_export(bundle, section)


def retain_xcresult_exports(folder, bundle):
    """Retain unmodified xcresult outputs (and tool streams on export failure) without overwriting."""
    first_error = None
    for section in ("tests", "summary"):
        path = folder / f"xcresult-{section}.json"
        require(not path.exists() and not path.is_symlink(), "Existing xcresult export; never overwrite")
        try:
            raw = xcresult_export(bundle, section)
            with path.open("xb") as stream:
                stream.write(raw)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            for suffix, payload in (("stdout", getattr(error, "output", None)),
                                    ("stderr", getattr(error, "stderr", None))):
                if payload is not None:
                    with (folder / f"xcresult-{section}.{suffix}").open("xb") as stream:
                        stream.write(payload.encode("utf-8") if isinstance(payload, str) else payload)
            write(folder / f"xcresult-{section}-export-error.json", {
                "error_type": type(error).__name__,
                "error": str(error),
                "returncode": getattr(error, "returncode", None),
            })
            if first_error is None:
                first_error = error
    if first_error is not None:
        raise first_error


def parameter_result(document, name=None):
    """Require all Bool/enum argument leaves for a parameterized test to be Passed."""
    if name is None:
        require(inventory.PARAMETERIZED, "No parameterized specification in inventory")
        name = next(iter(inventory.PARAMETERIZED))
    spec = inventory.PARAMETERIZED[name]
    signature = name + spec["signature"]
    arg_name = spec["argument"]
    expected_values = sorted(spec["values"])
    val_pattern = "|".join(re.escape(v_) for v_ in spec["values"])
    found = []
    parents = []

    def visit(node, inside=False):
        require(isinstance(node, dict), "Malformed xcresult test node")
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
            value = re.fullmatch(rf"(?:{re.escape(arg_name)}:\s*)?({val_pattern})", argument)
            require(value is not None and node.get("result") == "Passed", "Missing/failed/skipped parameter result")
            found.append(value[1])
        for child in children:
            visit(child, inside)

    require(isinstance(document, dict) and isinstance(document.get("testNodes"), list), "Missing xcresult test tree")
    for node in document["testNodes"]:
        visit(node)
    require(len(parents) == 1 and sorted(found) == expected_values,
            f"Expected one declaration with exact parameter leaves for {name}")
    return {"name": name, "passed_arguments": sorted(found)}


def parameter_evidence(group, folder, bundle, *, export=False, group_specs=None, verify_native=True):
    require(verify_native or os.environ.get("GITHUB_ACTIONS") != "true",
            "Cloud requires live xcresult parameter verification")
    if group_specs is None:
        group_specs = build_groups(load_scope_config())
    param_names = [n for n in group_specs[group]["cases"] if n in inventory.PARAMETERIZED]
    if not param_names:
        return None
    path = folder / "xcresult-tests.json"
    if export:
        require(not path.exists() and not path.is_symlink(), "Existing xcresult export")
        raw = xcresult_export(bundle, "tests")
        with path.open("xb") as stream:
            stream.write(raw)
    require(path.is_file() and not path.is_symlink(), "Missing regular xcresult export")
    raw = path.read_bytes()
    if not export and verify_native:
        live = xcresult_export(bundle, "tests")
        require(json.loads(live) == json.loads(raw), "xcresult argument export drift")
    doc = json.loads(raw)
    if len(param_names) == 1:
        return {**parameter_result(doc, param_names[0]), "raw_sha256": digest_bytes(raw)}
    return {
        "cases": [parameter_result(doc, name) for name in param_names],
        "raw_sha256": digest_bytes(raw),
    }


def verify_group_xcresult(spec, bundle, *, exported_folder=None):
    """Multi-case-aware xcresult verification (declarations, leaves, no extras/skips/failures)."""
    paging.require_xcresult(bundle)
    require((bundle / "Data").is_dir() and any(p.is_file() and p.stat().st_size > 0
            for p in (bundle / "Data").rglob("*")), "Missing xcresult Data")

    def exported(section):
        if exported_folder is None:
            return xcresult_export(bundle, section)
        path = exported_folder / f"xcresult-{section}.json"
        require(path.is_file() and not path.is_symlink(), "Missing regular xcresult export")
        return path.read_bytes()

    tests = json.loads(exported("tests"))
    summary = json.loads(exported("summary"))
    cases = list(spec["cases"])
    expected_sigs = {
        name: name + inventory.PARAMETERIZED.get(name, {}).get("signature", "()")
        for name in cases
    }
    declarations_count = len(cases)
    executions_count = sum(len(inventory.PARAMETERIZED.get(n, {}).get("values", [None])) for n in cases)
    summary_counts = {declarations_count, executions_count}
    require(
        all(type(summary.get(key)) is int for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests"))
        and summary["failedTests"] == summary["skippedTests"] == 0
        and summary["totalTestCount"] == summary["passedTests"]
        and summary["totalTestCount"] in summary_counts,
        "xcresult declaration/argument total/pass/failure/skip mismatch",
    )

    matches = {name: [] for name in cases}

    def visit(node):
        require(isinstance(node, dict), "Invalid xcresult node")
        if node.get("nodeType") in ("Test Case", "Arguments", "Test Suite", "Unit test bundle", "Test Plan"):
            require(node.get("result") == "Passed", "Failed/skipped/incomplete xcresult case")
        labels = [str(node.get(k, "")) for k in ("name", "nodeIdentifier")]
        matched_names = [
            name for name, sig in expected_sigs.items()
            if any(label in (name, sig) or label.endswith("/" + sig) or label.endswith("/" + name) for label in labels)
        ]
        if matched_names:
            require(len(matched_names) == 1, "Ambiguous xcresult test identity")
            matches[matched_names[0]].append(node)
        if node.get("nodeType") == "Test Case":
            require(len(matched_names) == 1, "Unexpected xcresult test identity")
        for child in node.get("children", []):
            visit(child)

    require(isinstance(tests.get("testNodes"), list), "Missing xcresult tests")
    for node in tests["testNodes"]:
        visit(node)
    for name in cases:
        require(len(matches[name]) == 1 and matches[name][0].get("result") == "Passed",
                "xcresult identity/result drift: " + name)
        if name in inventory.PARAMETERIZED:
            parameter_result(tests, name)
    return tests
def parse_log_for_spec(group, spec, raw, code, timed_out):
    return freeze.parse_log_for_spec(group, spec, raw, code, timed_out)


def parse_log(group, raw, code, timed_out, *, groups=None):
    active_groups = groups if groups is not None else build_groups(load_scope_config())
    require(group in active_groups, "Unknown group: " + str(group))
    return parse_log_for_spec(group, active_groups[group], raw, code, timed_out)
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
    require(not dest_path.exists() and not dest_path.is_symlink(), "Existing staging archive; never overwrite")
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
    require(
        isinstance(payload, dict)
        and payload.get("name") == expected_name
        and (expected_id is None or payload.get("id") == expected_id),
        "Unexpected artifact metadata object",
    )
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
            actual_meta = {"bytes": len(data), "sha256": digest_bytes(data)}
            require(actual_meta == members[name], "Archive member metadata mismatch: " + name)
            with target.open("xb") as out_stream:
                out_stream.write(data)
            retained[name] = actual_meta
    return retained


def _repo_matches(run, key):
    repo_obj = run.get(key)
    require(isinstance(repo_obj, dict) and repo_obj.get("full_name") == REPO,
            f"Run {key} differs from {REPO}")


def validate_prior_run_and_artifact(prior_id, run, artifact, expected_sha, current_run_id):
    require(isinstance(run, dict) and isinstance(artifact, dict), "Invalid prior API metadata")
    require(re.fullmatch(r"[1-9][0-9]*", str(prior_id)), "Invalid prior run ID")
    spec = _prior_spec(prior_id)
    pin_run_id = spec["run_id"]
    pin_commit = spec["source_commit"]
    pin_artifact_id = spec["artifact_id"]
    pin_artifact_name = spec["artifact_name"]
    pin_sha256 = spec["archive_sha256"]
    require(expected_sha == pin_commit, "Prior source commit differs from pinned commit")
    require(str(prior_id) != str(current_run_id), "Self-referential prior run rejected")
    require(
        run.get("id") == int(pin_run_id)
        and run.get("head_sha") == pin_commit
        and run.get("run_attempt") == 1
        and run.get("workflow_id") == WORKFLOW_ID
        and run.get("path") == WORKFLOW_PATH
        and run.get("event") == "workflow_dispatch"
        and run.get("head_branch") == "main"
        and run.get("status") == "completed"
        and run.get("conclusion") in ("failure", "success"),
        "Unexpected prior validation run identity/state",
    )
    _repo_matches(run, "repository")
    _repo_matches(run, "head_repository")
    wf_run = artifact.get("workflow_run")
    digest_value = artifact.get("digest")
    size_value = artifact.get("size_in_bytes")
    require(
        isinstance(wf_run, dict)
        and artifact.get("id") == pin_artifact_id
        and artifact.get("expired") is False
        and artifact.get("name") == pin_artifact_name
        and wf_run.get("id") == int(pin_run_id)
        and wf_run.get("head_sha") == pin_commit
        and type(size_value) is int and 0 < size_value < 4 * 1024**3
        and isinstance(digest_value, str)
        and digest_value == "sha256:" + pin_sha256,
        "Prior artifact provenance/digest mismatch",
    )


def _verify_archive_receipt(folder, *, prior_id=PRIOR_RUN_ID, check_live_api=False, current_run_id=None):
    spec = _prior_spec(prior_id)
    pin_run_id = spec["run_id"]
    pin_commit = spec["source_commit"]
    pin_artifact_id = spec["artifact_id"]
    pin_artifact_name = spec["artifact_name"]
    pin_sha256 = spec["archive_sha256"]
    require(folder.is_dir() and not folder.is_symlink(), "Missing prior evidence folder: " + str(folder))
    require(
        {p.name for p in folder.iterdir()} == {"api-run.json", "api-artifact.json", "archive-receipt.json", "archive.zip", "evidence"},
        "Unexpected files in retained prior folder: " + str(folder),
    )
    for name in ("api-run.json", "api-artifact.json", "archive-receipt.json", "archive.zip"):
        p = folder / name
        require(p.is_file() and not p.is_symlink(), "Invalid retained prior file: " + name)
    run = load(folder / "api-run.json")
    artifact = load(folder / "api-artifact.json")
    receipt = load(folder / "archive-receipt.json")
    validate_prior_run_and_artifact(pin_run_id, run, artifact, pin_commit, current_run_id)
    require(
        str(receipt.get("run_id")) == pin_run_id
        and str(receipt.get("run_attempt")) == "1"
        and receipt.get("source_commit") == pin_commit
        and receipt.get("artifact_id") == pin_artifact_id
        and receipt.get("artifact_name") == pin_artifact_name
        and receipt.get("archive_bytes") == artifact.get("size_in_bytes")
        and receipt.get("archive_sha256") == pin_sha256,
        "Archive receipt metadata mismatch",
    )
    members = receipt.get("members")
    retained = receipt.get("retained_files")
    require(
        isinstance(members, dict)
        and isinstance(retained, dict)
        and receipt.get("member_count") == len(members)
        and members == retained,
        "Malformed or incomplete retained archive member table",
    )
    archive = folder / "archive.zip"
    require(
        archive.stat().st_size == receipt["archive_bytes"] and sha(archive) == pin_sha256,
        "Retained authenticated archive drift",
    )
    require(safe_zip_members(archive) == members, "Archive manifest differs from authenticated ZIP bytes")
    if check_live_api:
        live_run = github_api_json(f"/actions/runs/{pin_run_id}")
        live_artifact = github_api_json(f"/actions/artifacts/{pin_artifact_id}")
        validate_prior_run_and_artifact(pin_run_id, live_run, live_artifact, pin_commit, current_run_id)
        require(
            live_artifact["digest"] == artifact["digest"]
            and live_artifact["size_in_bytes"] == artifact["size_in_bytes"],
            "Live API artifact identity/digest drift",
        )
    ev_dir = folder / "evidence"
    require(ev_dir.is_dir() and not ev_dir.is_symlink(), "Missing retained evidence directory")
    ev_resolved = ev_dir.resolve()
    actual_disk = {}
    for p in sorted(ev_dir.rglob("*")):
        require(not p.is_symlink() and p.resolve().is_relative_to(ev_resolved), "Unsafe retained path")
        if p.is_file():
            rel = p.relative_to(ev_dir).as_posix()
            actual_disk[rel] = {"bytes": p.stat().st_size, "sha256": sha(p)}
    require(actual_disk == retained, "Retained evidence files drifted on disk")
    return run, artifact, receipt


def _verify_prior_toolchain_and_deps(ev_dir, expected_packages=None, *, expected_source_commit=PRIOR_SOURCE_COMMIT):
    tool_path = ev_dir / "toolchain.log"
    gen_path = ev_dir / "xcodegen.log"
    dep_path = ev_dir / "dependency-resolution.json"
    require(
        all(p.is_file() and not p.is_symlink() for p in (tool_path, gen_path, dep_path)),
        "Missing prior toolchain/xcodegen/dependency receipt",
    )
    tool = tool_path.read_text(encoding="utf-8")
    require(
        ("Source: " + expected_source_commit) in tool
        and all(t in tool for t in ("Xcode 16.4", "Build version 16F6", "Apple Swift version 6.1.2", "arm64")),
        "Prior toolchain log mismatch",
    )
    require(gen_path.read_text(encoding="utf-8").strip() == "Version: 2.46.0", "Prior xcodegen log mismatch")
    dep = load(dep_path)
    packages = dep.get("packages")
    require(isinstance(packages, dict) and set(packages) == {"grdb.swift", "zipfoundation"},
            "Prior dependency closure mismatch")
    for identity, expected_dep in compat.epub_batch.DEPENDENCIES.items():
        pkg = packages.get(identity, {})
        pkg_meta = pkg.get("package", {})
        state = pkg_meta.get("state", {})
        require(
            pkg_meta.get("location") == expected_dep["url"]
            and pkg.get("checkout_revision") == expected_dep["revision"]
            and state.get("revision") == expected_dep["revision"]
            and state.get("version") == expected_dep["version"]
            and pkg.get("package_manifest_sha256") == expected_dep["manifest"],
            "Prior dependency pin/manifest mismatch: " + identity,
        )
    resolved_path = ev_dir / "Package.resolved"
    if resolved_path.exists() or resolved_path.is_symlink():
        resolved_doc = load(resolved_path)
        compat.epub_batch.validate_pins(resolved_doc.get("pins"))
    if expected_packages is not None:
        require(packages == expected_packages, "Prior dependencies differ from current run")
    return packages


def _verify_prior_simulator_and_linkage(
    ev_dir,
    members,
    *,
    expected_source_commit=PRIOR_SOURCE_COMMIT,
    expected_run_id=PRIOR_RUN_ID,
):
    sim = load(ev_dir / "simulator-selection.json")
    udid = sim.get("udid")
    require(
        sim.get("physical_device") is False
        and sim.get("architecture") == "arm64"
        and isinstance(udid, str)
        and bool(re.fullmatch(r"[0-9a-fA-F-]{36}", udid))
        and isinstance(sim.get("device_name"), str)
        and sim["device_name"].startswith("iPhone"),
        "Invalid prior simulator selection",
    )
    boot = load(ev_dir / "simulator-boot.json")
    require(
        boot.get("source_commit") == expected_source_commit
        and str(boot.get("run_id")) == str(expected_run_id)
        and str(boot.get("run_attempt")) == "1"
        and boot.get("exit_code") == 0
        and boot.get("timed_out") is False
        and boot.get("timeout_seconds", BOOT_TIMEOUT_SECONDS) == BOOT_TIMEOUT_SECONDS,
        "Invalid prior simulator boot receipt",
    )
    link_path = ev_dir / "webkit-simulator-linkage/verification.json"
    record = load(link_path)
    require(
        record.get("source_commit") == expected_source_commit
        and str(record.get("run_id")) == str(expected_run_id)
        and str(record.get("run_attempt")) == "1"
        and record.get("passed") is True
        and not record.get("errors")
        and isinstance(record.get("binaries"), list)
        and bool(record["binaries"]),
        "Invalid prior simulator WebKit linkage receipt",
    )
    for binary in record["binaries"]:
        ev_rel = "webkit-simulator-linkage/" + str(binary.get("evidence", ""))
        require(
            binary.get("passed") is True
            and binary.get("nm_exit") == 0
            and members.get(ev_rel, {}).get("sha256") == binary.get("sha256"),
            "Prior simulator WebKit binary digest mismatch: " + ev_rel,
        )
    return sim, sha(link_path)


def _verify_reused_domain_settings(
    folder,
    ev_dir,
    current_effective_domain=None,
    *,
    expected_source_commit=PRIOR_SOURCE_COMMIT,
):
    receipt = load(folder / "ReaderDomainTests-settings.json")
    require(receipt.get("source_commit") == expected_source_commit, "Reused settings source_commit mismatch")
    require(bool(re.fullmatch(r"[0-9a-f]{64}", str(receipt.get("scheme_sha256", "")))), "Missing scheme sha256")
    eff_path = ev_dir / "effective-test-settings.json"
    eff = load(eff_path)
    values = eff.get("ReaderDomainTests")
    compat._validate_domain_effective_settings(values)
    require(
        receipt.get("target") == "ReaderDomainTests"
        and receipt.get("scheme") == "ReaderDomain"
        and receipt.get("effective_settings_sha256") == sha(eff_path)
        and receipt.get("testables") == ["ReaderDomainTests"]
        and receipt.get("settings") == values,
        "Reused Domain settings receipt mismatch",
    )
    if current_effective_domain is not None:
        require(values == current_effective_domain, "Prior ReaderDomainTests settings differ from current run")
    return receipt


def _verify_reused_host_or_ui_settings(
    kind,
    target,
    folder,
    *,
    expected_source_commit=PRIOR2_SOURCE_COMMIT,
    current_effective_host=None,
):
    require(kind in ("host", "ui"), "Invalid Host/UI settings kind: " + repr(kind))
    expected_target = "YueJingHostTests" if kind == "host" else "YueJingEPUBUITests"
    require(target == expected_target, "Unexpected Host/UI target: " + repr(target))
    receipt = load(folder / f"{target}-settings.json")
    require(receipt.get("source_commit") == expected_source_commit, "Reused Host/UI settings source_commit mismatch")
    require(bool(re.fullmatch(r"[0-9a-f]{64}", str(receipt.get("scheme_sha256", "")))), "Missing Host/UI scheme sha256")
    fixture = receipt.get("fixture_environment")
    require(bool(fixture) and isinstance(fixture, str), "Missing Host/UI fixture_environment")
    reading.ui.uuid.UUID(fixture)
    require(
        set(receipt.get("testables", ())) == set(reading.ui.GROUPS),
        "Reused Host/UI testables mismatch",
    )
    targets = receipt.get("targets")
    require(isinstance(targets, dict) and set(targets) == {"YueJing", target}, "Reused Host/UI targets mismatch")
    app = targets.get("YueJing")
    test = targets.get(target)
    require(isinstance(app, dict) and isinstance(test, dict), "Malformed Host/UI target settings")
    expected_keys = {
        "PRODUCT_TYPE",
        "SWIFT_VERSION",
        "SWIFT_STRICT_CONCURRENCY",
        "IPHONEOS_DEPLOYMENT_TARGET",
        "TEST_HOST",
        "BUNDLE_LOADER",
        "TEST_TARGET_NAME",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
    }
    for v_ in (app, test):
        require(set(v_) == expected_keys, "Reused Host/UI settings keys mismatch")
        require(
            v_.get("SWIFT_VERSION") == "6.0"
            and v_.get("SWIFT_STRICT_CONCURRENCY") == "complete"
            and v_.get("IPHONEOS_DEPLOYMENT_TARGET") == "16.6",
            "Reused Host/UI language/concurrency/deployment settings mismatch",
        )
    require(
        app.get("PRODUCT_TYPE") == "com.apple.product-type.application"
        and "DEBUG" in str(app.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")).split(),
        "Reused Host/UI Debug App compilation condition missing",
    )
    if kind == "host":
        test_host = PurePosixPath(str(test.get("TEST_HOST", "")))
        require(
            test.get("PRODUCT_TYPE") == "com.apple.product-type.bundle.unit-test"
            and test_host.name == "YueJing"
            and test_host.parent.name == "YueJing.app"
            and test.get("BUNDLE_LOADER") == test.get("TEST_HOST"),
            "Reused Host tests not hosted by real YueJing.app",
        )
    else:
        require(
            test.get("PRODUCT_TYPE") == "com.apple.product-type.bundle.ui-testing"
            and test.get("TEST_TARGET_NAME") == "YueJing"
            and not test.get("TEST_HOST")
            and not test.get("BUNDLE_LOADER"),
            "Reused UI tests do not target real YueJing App",
        )
    for sub in ("YueJing", target):
        exit_path = folder / f"{target}-{sub}-settings-exit-code.txt"
        stdout_path = folder / f"{target}-{sub}-settings.stdout.json"
        require(exit_path.is_file() and not exit_path.is_symlink(), f"Missing settings exit file: {exit_path.name}")
        require(exit_path.read_text(encoding="utf-8").strip() == "0", f"Nonzero settings exit code: {exit_path.name}")
        require(stdout_path.is_file() and not stdout_path.is_symlink(), f"Missing settings stdout file: {stdout_path.name}")
        raw_rows = json.loads(stdout_path.read_text(encoding="utf-8"))
        require(isinstance(raw_rows, list), f"Malformed settings stdout JSON: {stdout_path.name}")
        matched = [row.get("buildSettings") for row in raw_rows if isinstance(row, dict) and row.get("target") == sub]
        require(len(matched) == 1 and isinstance(matched[0], dict), f"Missing target in settings stdout: {sub}")
        for key, val in targets[sub].items():
            require(matched[0].get(key, "") == val, f"Settings summary differs from xcodebuild stdout for {sub}.{key}")
    if current_effective_host is not None:
        require(
            receipt.get("scheme_sha256") == current_effective_host.get("scheme_sha256")
            and receipt.get("fixture_environment") == current_effective_host.get("fixture_environment")
            and set(receipt.get("testables", ())) == set(current_effective_host.get("testables", ()))
            and app == (current_effective_host.get("targets") or {}).get("YueJing"),
            "Prior Host/UI scheme or Debug App settings differ from current run",
        )
        if kind == "host":
            cur_test = (current_effective_host.get("targets") or {}).get("YueJingHostTests", {})
            for key in (
                "PRODUCT_TYPE",
                "SWIFT_VERSION",
                "SWIFT_STRICT_CONCURRENCY",
                "IPHONEOS_DEPLOYMENT_TARGET",
                "TEST_TARGET_NAME",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
            ):
                require(test.get(key) == cur_test.get(key), f"Prior Host {key} differs from current run")
            cur_host_path = PurePosixPath(str(cur_test.get("TEST_HOST", "")))
            require(test_host.parts[-3:] == cur_host_path.parts[-3:], "Prior TEST_HOST suffix differs from current run")
    return receipt
def _verify_reused_domain_group(
    group,
    spec,
    ev_dir,
    members,
    prior_destination,
    *,
    verify_native=True,
    current_effective_domain=None,
):
    require(verify_native or os.environ.get("GITHUB_ACTIONS") != "true",
            "Cloud requires live native xcresult verification for reused group")
    require(
        group in ELIGIBLE_PRIOR_REUSE_GROUPS
        and spec["kind"] == "domain"
        and spec["target"] == "ReaderDomainTests"
        and ("Tests/" + spec["file"]) not in PRIOR_REUSE_CHANGED_TEST_PINS,
        "Ineligible group cannot be reused: " + group,
    )
    folder = ev_dir / "epub-author-layout" / group
    require(folder.is_dir() and not folder.is_symlink(), "Missing reused group directory: " + group)
    require(
        not (folder / "failure.json").exists() and not (folder / "failure.json").is_symlink(),
        "Failed prior group cannot qualify for reuse: " + group,
    )
    target = spec["target"]
    bundle = folder / f"{target}.xcresult"
    bundle_rel = f"epub-author-layout/{group}/{target}.xcresult"
    require(
        (bundle / "Info.plist").is_file()
        and not (bundle / "Info.plist").is_symlink()
        and (bundle_rel + "/Info.plist") in members
        and any(m.startswith(bundle_rel + "/Data/") and members[m]["bytes"] > 0 for m in members),
        "Missing original xcresult bundle proof in prior archive: " + group,
    )

    selection_rec = load(folder / "selection.json")
    execution_rec = load(folder / "execution.json")
    cmd = selection_rec.get("command")
    require(isinstance(cmd, list) and "-resultBundlePath" in cmd, "Malformed reused selection command: " + group)
    bundle_arg_idx = cmd.index("-resultBundlePath") + 1
    require(bundle_arg_idx < len(cmd), "Missing resultBundlePath argument: " + group)
    bundle_arg = cmd[bundle_arg_idx]
    arg_parts = PurePosixPath(bundle_arg.replace("\\", "/")).parts
    require(
        len(arg_parts) >= 3 and arg_parts[-3:] == ("epub-author-layout", group, f"{target}.xcresult"),
        "Unexpected resultBundlePath in reused selection: " + group,
    )
    want_cmd = command_for_spec(spec, prior_destination, bundle_arg)
    want = {
        "scope": SCOPE,
        "source_commit": PRIOR_SOURCE_COMMIT,
        "run_id": PRIOR_RUN_ID,
        "run_attempt": "1",
        "group": group,
        "target": target,
        "file": spec["file"],
        "destination": prior_destination,
        "expected_cases": list(spec["cases"]),
        "command": want_cmd,
        "timeout_seconds": spec["timeout"],
        "case_timeout_seconds": spec["case_timeout"],
    }
    require(selection_rec == want, "Reused selection provenance mismatch: " + group)
    require(
        execution_rec == {**want, "native_exit": 0, "timed_out": False},
        "Reused execution provenance mismatch: " + group,
    )
    _verify_reused_domain_settings(folder, ev_dir, current_effective_domain=current_effective_domain)

    log_path = folder / f"{target}.log"
    require(log_path.is_file() and not log_path.is_symlink(), "Missing prior raw log: " + group)
    parsed = parse_log_for_spec(group, spec, log_path.read_bytes(), 0, False)

    saved_tests = verify_group_xcresult(spec, bundle, exported_folder=folder)
    saved_summary = load(folder / "xcresult-summary.json")
    if verify_native:
        live_tests = verify_group_xcresult(spec, bundle, exported_folder=None)
        require(live_tests == saved_tests, "Prior live xcresult tests differ from saved export: " + group)
        live_summary = json.loads(xcresult_export(bundle, "summary"))
        require(live_summary == saved_summary, "Prior live xcresult summary differs from saved export: " + group)

    parsed["parameter_xcresult"] = parameter_evidence(
        group, folder, bundle, group_specs={group: spec}, verify_native=verify_native
    )
    require(
        json.dumps(load(folder / "counts.json"), sort_keys=True) == json.dumps(parsed, sort_keys=True),
        "Prior counts receipt differs from raw log events: " + group,
    )
    return {
        "group": group,
        "target": target,
        "file": spec["file"],
        "source_commit": PRIOR_SOURCE_COMMIT,
        "run_id": PRIOR_RUN_ID,
        "run_attempt": "1",
        "declarations_passed": parsed["declarations_passed"],
        "executions": parsed["executions"],
        "passed": list(parsed["passed"]),
        "log_sha256": parsed["log_sha256"],
        "selection_sha256": sha(folder / "selection.json"),
        "execution_sha256": sha(folder / "execution.json"),
        "counts_sha256": sha(folder / "counts.json"),
        "settings_sha256": sha(folder / "ReaderDomainTests-settings.json"),
        "xcresult_tests_sha256": sha(folder / "xcresult-tests.json"),
        "xcresult_summary_sha256": sha(folder / "xcresult-summary.json"),
        "parameter_xcresult": parsed["parameter_xcresult"],
    }


def _verify_reused_prior2_group(
    group,
    spec,
    ev_dir,
    members,
    prior_destination,
    *,
    verify_native=True,
    current_effective_domain=None,
    current_effective_host=None,
    expected_source_commit=PRIOR2_SOURCE_COMMIT,
    expected_run_id=PRIOR2_RUN_ID,
    eligible_groups=ELIGIBLE_PRIOR2_REUSE_GROUPS,
    changed_test_pins=PRIOR2_REUSE_CHANGED_TEST_PINS,
):
    require(verify_native or os.environ.get("GITHUB_ACTIONS") != "true",
            "Cloud requires live native xcresult verification for prior2 reused group")
    require(
        group in eligible_groups
        and ("Tests/" + spec["file"]) not in changed_test_pins,
        "Ineligible prior2 group cannot be reused: " + group,
    )
    folder = ev_dir / "epub-author-layout" / group
    require(folder.is_dir() and not folder.is_symlink(), "Missing prior2 reused group directory: " + group)
    require(
        not (folder / "failure.json").exists() and not (folder / "failure.json").is_symlink(),
        "Failed prior2 group cannot qualify for reuse: " + group,
    )
    target = spec["target"]
    bundle = folder / f"{target}.xcresult"
    bundle_rel = f"epub-author-layout/{group}/{target}.xcresult"
    require(
        (bundle / "Info.plist").is_file()
        and not (bundle / "Info.plist").is_symlink()
        and (bundle_rel + "/Info.plist") in members
        and any(m.startswith(bundle_rel + "/Data/") and members[m]["bytes"] > 0 for m in members),
        "Missing original xcresult bundle proof in prior2 archive: " + group,
    )

    selection_rec = load(folder / "selection.json")
    execution_rec = load(folder / "execution.json")
    cmd = selection_rec.get("command")
    require(isinstance(cmd, list) and "-resultBundlePath" in cmd, "Malformed prior2 selection command: " + group)
    bundle_arg_idx = cmd.index("-resultBundlePath") + 1
    require(bundle_arg_idx < len(cmd), "Missing prior2 resultBundlePath argument: " + group)
    bundle_arg = cmd[bundle_arg_idx]
    arg_parts = PurePosixPath(bundle_arg.replace("\\", "/")).parts
    require(
        len(arg_parts) >= 3 and arg_parts[-3:] == ("epub-author-layout", group, f"{target}.xcresult"),
        "Unexpected resultBundlePath in prior2 selection: " + group,
    )
    want_cmd = command_for_spec(spec, prior_destination, bundle_arg)
    want = {
        "scope": SCOPE,
        "source_commit": expected_source_commit,
        "run_id": expected_run_id,
        "run_attempt": "1",
        "group": group,
        "target": target,
        "file": spec["file"],
        "destination": prior_destination,
        "expected_cases": list(spec["cases"]),
        "command": want_cmd,
        "timeout_seconds": spec["timeout"],
        "case_timeout_seconds": spec["case_timeout"],
    }
    require(selection_rec == want, "Prior2 selection provenance mismatch: " + group)
    require(
        execution_rec == {**want, "native_exit": 0, "timed_out": False},
        "Prior2 execution provenance mismatch: " + group,
    )
    if spec["kind"] == "domain":
        _verify_reused_domain_settings(
            folder,
            ev_dir,
            current_effective_domain=current_effective_domain,
            expected_source_commit=expected_source_commit,
        )
    else:
        _verify_reused_host_or_ui_settings(
            spec["kind"],
            target,
            folder,
            expected_source_commit=expected_source_commit,
            current_effective_host=current_effective_host,
        )

    log_path = folder / f"{target}.log"
    require(log_path.is_file() and not log_path.is_symlink(), "Missing prior2 raw log: " + group)
    parsed = parse_log_for_spec(group, spec, log_path.read_bytes(), 0, False)

    saved_tests = verify_group_xcresult(spec, bundle, exported_folder=folder)
    saved_summary = load(folder / "xcresult-summary.json")
    if verify_native:
        live_tests = verify_group_xcresult(spec, bundle, exported_folder=None)
        require(live_tests == saved_tests, "Prior2 live xcresult tests differ from saved export: " + group)
        live_summary = json.loads(xcresult_export(bundle, "summary"))
        require(live_summary == saved_summary, "Prior2 live xcresult summary differs from saved export: " + group)

    parsed["parameter_xcresult"] = parameter_evidence(
        group, folder, bundle, group_specs={group: spec}, verify_native=verify_native
    )
    require(
        json.dumps(load(folder / "counts.json"), sort_keys=True) == json.dumps(parsed, sort_keys=True),
        "Prior2 counts receipt differs from raw log events: " + group,
    )
    return {
        "group": group,
        "target": target,
        "file": spec["file"],
        "source_commit": expected_source_commit,
        "run_id": expected_run_id,
        "run_attempt": "1",
        "declarations_passed": parsed["declarations_passed"],
        "executions": parsed["executions"],
        "passed": list(parsed["passed"]),
        "log_sha256": parsed["log_sha256"],
        "selection_sha256": sha(folder / "selection.json"),
        "execution_sha256": sha(folder / "execution.json"),
        "counts_sha256": sha(folder / "counts.json"),
        "settings_sha256": sha(folder / f"{target}-settings.json"),
        "xcresult_tests_sha256": sha(folder / "xcresult-tests.json"),
        "xcresult_summary_sha256": sha(folder / "xcresult-summary.json"),
        "parameter_xcresult": parsed["parameter_xcresult"],
    }


def _compute_prior_proof_digest(payload):
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return digest_bytes(canonical)


def inspect_prior_evidence(
    prior_root,
    scope,
    *,
    root=ROOT,
    expected_packages=None,
    current_effective_domain=None,
    check_shared_sources=True,
    verify_native=True,
    check_live_api=False,
):
    """Strictly requalify the seven eligible passing Domain groups from pinned prior run 43153993787."""
    require(verify_native or os.environ.get("GITHUB_ACTIONS") != "true",
            "Cloud requires live xcresult bundle parsing for prior reuse")
    require(check_shared_sources or os.environ.get("GITHUB_ACTIONS") != "true",
            "Cloud requires prior source compatibility verification")
    root = Path(root)
    prior_root = Path(prior_root)
    run, artifact, receipt = _verify_archive_receipt(
        prior_root,
        prior_id=PRIOR_RUN_ID,
        check_live_api=check_live_api,
        current_run_id=scope.get("run_id"),
    )
    members = receipt["members"]
    ev_dir = prior_root / "evidence"

    require(not any(p.startswith("reused-evidence/") for p in members), "Recursive prior reuse chain is forbidden")
    forbidden_prior_gates = set(MIXED_QUALIFICATION_FILES) | {
        "author-layout-gate.json",
        "author-layout-package.json",
    }
    require(not (forbidden_prior_gates & set(members)), "Mixed or pre-existing gate/package in prior archive")
    require(
        not (ev_dir / "case-scheduling-error.json").exists()
        and not (ev_dir / "case-scheduling-error.json").is_symlink(),
        "Prior scheduling error prevents reuse",
    )

    cfg_path = SCOPE_CONFIG_JSON if root == ROOT else root / "scripts/epub_author_layout_scope.json"
    current_cfg = load_scope_config(cfg_path)
    groups = build_groups(current_cfg)
    fresh_ids, reused_ids = partition_groups(groups, PRIOR_RUN_ID)
    current_inventory = inventory.validate_source(root)

    prior_scope = load(ev_dir / "author-layout-scope.json")
    expected_prior_scope = {
        "scope": SCOPE,
        "phase": "validation",
        "prior_validation_run": "",
        "source_commit": PRIOR_SOURCE_COMMIT,
        "source_status": "clean",
        "baseline_commit": BASE,
        "run_id": PRIOR_RUN_ID,
        "run_attempt": "1",
        "repository": REPO,
        "ref": "refs/heads/main",
        "workflow_id": WORKFLOW_ID,
        "workflow_path": WORKFLOW_PATH,
        "version": VERSION,
        "build": BUILD,
        "allow_unqualified_ipa": False,
        "allowed_paths": current_cfg["allowed_paths"],
        "selected_files": current_cfg["selected_files"],
        "selected": {g: list(spec["cases"]) for g, spec in groups.items()},
        "selected_declarations": TOTAL_TARGET_DECLARATIONS,
        "native_tests_planned": TOTAL_TARGET_EXECUTIONS,
        "full_inventory_declared": current_inventory["selected"],
        "full_inventory_executions": current_inventory["selected_executions"],
    }
    for key, val in expected_prior_scope.items():
        require(
            key in prior_scope and json.dumps(prior_scope[key], sort_keys=True) == json.dumps(val, sort_keys=True),
            f"Prior scope field mismatch: {key}",
        )
    require(type(prior_scope.get("build_ipa")) is bool, "Prior scope missing valid build_ipa flag")

    raw_event_path = ev_dir / "dispatch-event.json"
    require(raw_event_path.is_file() and not raw_event_path.is_symlink(), "Prior run missing raw dispatch-event.json")
    require(sha(raw_event_path) == prior_scope.get("dispatch_event_sha256"), "Prior dispatch-event hash mismatch")
    raw_event = load(raw_event_path)
    if "ref" in raw_event:
        require(raw_event["ref"] == "refs/heads/main", "Prior raw dispatch ref mismatch")
    if "repository" in raw_event:
        require(isinstance(raw_event["repository"], dict) and raw_event["repository"].get("full_name") == REPO,
                "Prior raw dispatch repository mismatch")
    raw_inputs = raw_event.get("inputs")
    require(
        isinstance(raw_inputs, dict)
        and raw_inputs.get("validation_scope") == SCOPE
        and raw_inputs.get("allow_unqualified_ipa", False) in (False, "false")
        and raw_inputs.get("prior_validation_run", "") in ("", None),
        "Prior raw dispatch inputs incompatible",
    )

    prior_sources = load(ev_dir / "candidate-sources.json")
    require(
        prior_sources.get("source_commit") == PRIOR_SOURCE_COMMIT
        and str(prior_sources.get("run_id")) == PRIOR_RUN_ID
        and str(prior_sources.get("run_attempt")) == "1"
        and prior_sources.get("files") == prior_scope.get("files")
        and prior_sources.get("inventory") == current_inventory,
        "Prior candidate-sources/inventory provenance mismatch",
    )

    prior_cfg_from_scope = normalize_scope_config({
        "baseline": prior_scope["baseline_commit"],
        "scope": prior_scope["scope"],
        "version": prior_scope["version"],
        "build": prior_scope["build"],
        "allowed_paths": prior_scope["allowed_paths"],
        "candidate_sha256": prior_scope["candidate_sha256"],
        "selected_files": prior_scope["selected_files"],
    })
    if check_shared_sources:
        head = compat.git("rev-parse", "HEAD", root=root).decode("utf-8").strip()
        is_prior_ancestor = _git_is_ancestor(PRIOR_SOURCE_COMMIT, head, root=root)
        prior_tree = compat.git_tree(PRIOR_SOURCE_COMMIT, root=root)
        current_tree = compat.git_tree("HEAD", root=root)
        status_bytes = compat.git("status", "--porcelain=v1", "-z", "--untracked-files=all", root=root)
        prior_cfg_raw = compat.git("show", f"{PRIOR_SOURCE_COMMIT}:scripts/epub_author_layout_scope.json", root=root)
        prior_cfg_git = normalize_scope_config(json.loads(prior_cfg_raw.decode("utf-8")))
        require(digest_bytes(prior_cfg_raw) == prior_scope.get("scope_config_sha256"),
                "Prior scope_config_sha256 differs from committed prior config")
        require(prior_cfg_git == prior_cfg_from_scope,
                "Prior scope receipt pins differ from committed prior scope config")
        validate_prior_source_compatibility(
            prior_tree,
            current_tree,
            prior_cfg_git,
            current_cfg,
            head=head,
            is_prior_ancestor=is_prior_ancestor,
            status_bytes=status_bytes,
            pending=False,
            prior_candidate_files=prior_sources.get("files"),
            current_candidate_files=scope.get("files"),
            prior_inventory=prior_sources.get("inventory"),
            current_inventory=current_inventory,
            prior_commit=PRIOR_SOURCE_COMMIT,
            allowed_diff_paths=PRIOR_REUSE_ALLOWED_DIFF_PATHS,
            changed_test_pins=PRIOR_REUSE_CHANGED_TEST_PINS,
        )
    else:
        validate_prior_source_compatibility(
            {"stub.swift": ["100644", "blob", "a" * 40]},
            {"stub.swift": ["100644", "blob", "a" * 40]},
            prior_cfg_from_scope,
            current_cfg,
            head=scope.get("source_commit", "b" * 40),
            is_prior_ancestor=True,
            status_bytes=b"",
            pending=True,
            prior_candidate_files=prior_sources.get("files"),
            current_candidate_files=scope.get("files"),
            prior_inventory=prior_sources.get("inventory"),
            current_inventory=current_inventory,
            prior_commit=PRIOR_SOURCE_COMMIT,
            allowed_diff_paths=PRIOR_REUSE_ALLOWED_DIFF_PATHS,
            changed_test_pins=PRIOR_REUSE_CHANGED_TEST_PINS,
        )

    packages = _verify_prior_toolchain_and_deps(
        ev_dir, expected_packages=expected_packages, expected_source_commit=PRIOR_SOURCE_COMMIT
    )
    sim, sim_linkage_sha = _verify_prior_simulator_and_linkage(
        ev_dir, members, expected_source_commit=PRIOR_SOURCE_COMMIT, expected_run_id=PRIOR_RUN_ID
    )
    prior_destination = "platform=iOS Simulator,id=" + sim["udid"]

    native_prior_dir = ev_dir / "epub-author-layout"
    require(
        native_prior_dir.is_dir()
        and not native_prior_dir.is_symlink()
        and {p.name for p in native_prior_dir.iterdir()} == set(groups),
        "Prior archive group inventory mismatch",
    )
    for excluded in fresh_ids:
        ex_dir = native_prior_dir / excluded
        require(
            (ex_dir / "failure.json").is_file()
            and not (ex_dir / "failure.json").is_symlink()
            and not (ex_dir / "counts.json").exists()
            and not (ex_dir / "counts.json").is_symlink(),
            "Excluded failed/blocked prior group has unexpected passing receipt: " + excluded,
        )

    errors = []
    reused_group_proofs = []
    for group in reused_ids:
        spec = groups[group]
        try:
            proof = _verify_reused_domain_group(
                group,
                spec,
                ev_dir,
                members,
                prior_destination,
                verify_native=verify_native,
                current_effective_domain=current_effective_domain,
            )
            reused_group_proofs.append(proof)
        except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
            errors.append(f"{group}: {error}")

    reused_passed = [n for g in reused_group_proofs for n in g["passed"]]
    expected_reused = [n for g in reused_ids for n in groups[g]["cases"]]
    total_reused_exec = sum(g["executions"] for g in reused_group_proofs)
    if not errors:
        if (
            len(reused_passed) != len(set(reused_passed))
            or len(reused_passed) != PRIOR_REUSED_DECLARATIONS
            or set(reused_passed) != set(expected_reused)
        ):
            errors.append("Reused declaration identity/count mismatch")
        if total_reused_exec != PRIOR_REUSED_EXECUTIONS:
            errors.append("Reused execution count mismatch")

    passed = not errors and len(reused_group_proofs) == len(ELIGIBLE_PRIOR_REUSE_GROUPS)
    sim_boot_sha = sha(ev_dir / "simulator-boot.json")
    scope_sha = sha(ev_dir / "author-layout-scope.json")
    cand_sha = sha(ev_dir / "candidate-sources.json")
    dep_sha = sha(ev_dir / "dependency-resolution.json")
    proof_sha = None
    if passed:
        proof_sha = _compute_prior_proof_digest({
            "prior_run_id": PRIOR_RUN_ID,
            "prior_source_commit": PRIOR_SOURCE_COMMIT,
            "artifact_id": PRIOR_ARTIFACT_ID,
            "archive_sha256": PRIOR_ARTIFACT_SHA256,
            "archive_bytes": receipt["archive_bytes"],
            "reused_groups": reused_group_proofs,
            "simulator_linkage_sha256": sim_linkage_sha,
            "simulator_boot_sha256": sim_boot_sha,
            "scope_sha256": scope_sha,
            "candidate_sources_sha256": cand_sha,
            "dependency_resolution_sha256": dep_sha,
        })

    return {
        "run_id": PRIOR_RUN_ID,
        "run_attempt": "1",
        "source_commit": PRIOR_SOURCE_COMMIT,
        "scope": SCOPE,
        "artifact_id": PRIOR_ARTIFACT_ID,
        "artifact_name": PRIOR_ARTIFACT_NAME,
        "archive_bytes": receipt["archive_bytes"],
        "archive_sha256": PRIOR_ARTIFACT_SHA256,
        "workflow_conclusion": run.get("conclusion"),
        "excluded_groups": fresh_ids,
        "reused_groups": reused_ids,
        "declarations_passed": len(reused_passed) if passed else None,
        "executions_passed": total_reused_exec if passed else None,
        "groups": reused_group_proofs,
        "packages": packages,
        "simulator": sim,
        "simulator_boot_sha256": sim_boot_sha,
        "simulator_linkage_sha256": sim_linkage_sha,
        "proof_sha256": proof_sha,
        "native_bundle_parse": "passed" if (passed and verify_native) else (
            "failed" if verify_native else "not_executed_local_structural_replay"
        ),
        "qualified": passed and verify_native,
        "passed": passed,
        "errors": errors,
    }


def inspect_prior2_evidence(
    prior_root,
    scope,
    *,
    root=ROOT,
    expected_packages=None,
    current_effective_domain=None,
    current_effective_host=None,
    check_shared_sources=True,
    verify_native=True,
    check_live_api=False,
):
    """Independently verify run 43158884847 without trusting its reused-evidence/ or erroneous gate report."""
    require(verify_native or os.environ.get("GITHUB_ACTIONS") != "true",
            "Cloud requires live xcresult bundle parsing for prior2 reuse")
    require(check_shared_sources or os.environ.get("GITHUB_ACTIONS") != "true",
            "Cloud requires prior2 source compatibility verification")
    root = Path(root)
    prior_root = Path(prior_root)
    run, artifact, receipt = _verify_archive_receipt(
        prior_root,
        prior_id=PRIOR2_RUN_ID,
        check_live_api=check_live_api,
        current_run_id=scope.get("run_id"),
    )
    members = receipt["members"]
    ev_dir = prior_root / "evidence"

    forbidden_prior_gates = set(MIXED_QUALIFICATION_FILES) | {
        "author-layout-gate.json",
        "author-layout-package.json",
    }
    own_members = {m for m in members if not m.startswith("reused-evidence/")}
    require(not (forbidden_prior_gates & own_members), "Mixed or pre-existing gate/package in prior2 archive")
    require(
        not (ev_dir / "case-scheduling-error.json").exists()
        and not (ev_dir / "case-scheduling-error.json").is_symlink(),
        "Prior2 scheduling error prevents reuse",
    )

    cfg_path = SCOPE_CONFIG_JSON if root == ROOT else root / "scripts/epub_author_layout_scope.json"
    current_cfg = load_scope_config(cfg_path)
    groups = build_groups(current_cfg)
    phase1_fresh_ids, phase1_reused_ids = partition_groups(groups, PRIOR_RUN_ID)
    phase2_fresh_ids, phase2_all_reused_ids = partition_groups(groups, PRIOR2_RUN_ID)
    prior2_reused_ids = [g for g in groups if g in ELIGIBLE_PRIOR2_REUSE_GROUPS]
    require(
        set(prior2_reused_ids) == ELIGIBLE_PRIOR2_REUSE_GROUPS
        and set(phase1_fresh_ids) - set(prior2_reused_ids) == set(phase2_fresh_ids) == {"host-3"},
        "Prior2 fresh/reused partition mismatch",
    )
    current_inventory = inventory.validate_source(root)

    prior2_scope = load(ev_dir / "author-layout-scope.json")
    expected_prior2_scope = {
        "scope": SCOPE,
        "phase": "validation",
        "prior_validation_run": PRIOR_RUN_ID,
        "prior_source_commit": PRIOR_SOURCE_COMMIT,
        "prior_artifact_id": PRIOR_ARTIFACT_ID,
        "prior_artifact_sha256": PRIOR_ARTIFACT_SHA256,
        "source_commit": PRIOR2_SOURCE_COMMIT,
        "source_status": "clean",
        "baseline_commit": BASE,
        "run_id": PRIOR2_RUN_ID,
        "run_attempt": "1",
        "repository": REPO,
        "ref": "refs/heads/main",
        "workflow_id": WORKFLOW_ID,
        "workflow_path": WORKFLOW_PATH,
        "version": VERSION,
        "build": BUILD,
        "allow_unqualified_ipa": False,
        "allowed_paths": current_cfg["allowed_paths"],
        "selected_files": current_cfg["selected_files"],
        "selected": {g: list(spec["cases"]) for g, spec in groups.items()},
        "fresh_groups": phase1_fresh_ids,
        "reused_groups": phase1_reused_ids,
        "fresh_selected": {g: list(groups[g]["cases"]) for g in phase1_fresh_ids},
        "reused_selected": {g: list(groups[g]["cases"]) for g in phase1_reused_ids},
        "selected_declarations": TOTAL_TARGET_DECLARATIONS,
        "native_tests_planned": TOTAL_TARGET_EXECUTIONS,
        "fresh_declarations_planned": FRESH_WITH_PRIOR_DECLARATIONS,
        "fresh_executions_planned": FRESH_WITH_PRIOR_EXECUTIONS,
        "reused_declarations_planned": PRIOR_REUSED_DECLARATIONS,
        "reused_executions_planned": PRIOR_REUSED_EXECUTIONS,
        "full_inventory_declared": current_inventory["selected"],
        "full_inventory_executions": current_inventory["selected_executions"],
    }
    for key, val in expected_prior2_scope.items():
        require(
            key in prior2_scope and json.dumps(prior2_scope[key], sort_keys=True) == json.dumps(val, sort_keys=True),
            f"Prior2 scope field mismatch: {key}",
        )
    require(type(prior2_scope.get("build_ipa")) is bool, "Prior2 scope missing valid build_ipa flag")

    raw_event_path = ev_dir / "dispatch-event.json"
    require(raw_event_path.is_file() and not raw_event_path.is_symlink(), "Prior2 run missing raw dispatch-event.json")
    require(sha(raw_event_path) == prior2_scope.get("dispatch_event_sha256"), "Prior2 dispatch-event hash mismatch")
    raw_event = load(raw_event_path)
    if "ref" in raw_event:
        require(raw_event["ref"] == "refs/heads/main", "Prior2 raw dispatch ref mismatch")
    if "repository" in raw_event:
        require(isinstance(raw_event["repository"], dict) and raw_event["repository"].get("full_name") == REPO,
                "Prior2 raw dispatch repository mismatch")
    raw_inputs = raw_event.get("inputs")
    require(
        isinstance(raw_inputs, dict)
        and raw_inputs.get("validation_scope") == SCOPE
        and raw_inputs.get("allow_unqualified_ipa", False) in (False, "false")
        and raw_inputs.get("prior_validation_run") == PRIOR_RUN_ID,
        "Prior2 raw dispatch inputs incompatible",
    )

    prior2_sources = load(ev_dir / "candidate-sources.json")
    require(
        prior2_sources.get("source_commit") == PRIOR2_SOURCE_COMMIT
        and str(prior2_sources.get("run_id")) == PRIOR2_RUN_ID
        and str(prior2_sources.get("run_attempt")) == "1"
        and prior2_sources.get("files") == prior2_scope.get("files")
        and prior2_sources.get("inventory") == current_inventory,
        "Prior2 candidate-sources/inventory provenance mismatch",
    )

    prior2_cfg_from_scope = normalize_scope_config({
        "baseline": prior2_scope["baseline_commit"],
        "scope": prior2_scope["scope"],
        "version": prior2_scope["version"],
        "build": prior2_scope["build"],
        "allowed_paths": prior2_scope["allowed_paths"],
        "candidate_sha256": prior2_scope["candidate_sha256"],
        "selected_files": prior2_scope["selected_files"],
    })
    if check_shared_sources:
        head = compat.git("rev-parse", "HEAD", root=root).decode("utf-8").strip()
        is_prior2_ancestor = _git_is_ancestor(PRIOR2_SOURCE_COMMIT, head, root=root)
        prior2_tree = compat.git_tree(PRIOR2_SOURCE_COMMIT, root=root)
        current_tree = compat.git_tree("HEAD", root=root)
        status_bytes = compat.git("status", "--porcelain=v1", "-z", "--untracked-files=all", root=root)
        prior2_cfg_raw = compat.git("show", f"{PRIOR2_SOURCE_COMMIT}:scripts/epub_author_layout_scope.json", root=root)
        prior2_cfg_git = normalize_scope_config(json.loads(prior2_cfg_raw.decode("utf-8")))
        require(digest_bytes(prior2_cfg_raw) == prior2_scope.get("scope_config_sha256"),
                "Prior2 scope_config_sha256 differs from committed prior2 config")
        require(prior2_cfg_git == prior2_cfg_from_scope,
                "Prior2 scope receipt pins differ from committed prior2 scope config")
        validate_prior_source_compatibility(
            prior2_tree,
            current_tree,
            prior2_cfg_git,
            current_cfg,
            head=head,
            is_prior_ancestor=is_prior2_ancestor,
            status_bytes=status_bytes,
            pending=False,
            prior_candidate_files=prior2_sources.get("files"),
            current_candidate_files=scope.get("files"),
            prior_inventory=prior2_sources.get("inventory"),
            current_inventory=current_inventory,
            prior_commit=PRIOR2_SOURCE_COMMIT,
            allowed_diff_paths=PRIOR2_REUSE_ALLOWED_DIFF_PATHS,
            changed_test_pins=PRIOR2_REUSE_CHANGED_TEST_PINS,
        )
    else:
        validate_prior_source_compatibility(
            {"stub.swift": ["100644", "blob", "a" * 40]},
            {"stub.swift": ["100644", "blob", "a" * 40]},
            prior2_cfg_from_scope,
            current_cfg,
            head=scope.get("source_commit", "b" * 40),
            is_prior_ancestor=True,
            status_bytes=b"",
            pending=True,
            prior_candidate_files=prior2_sources.get("files"),
            current_candidate_files=scope.get("files"),
            prior_inventory=prior2_sources.get("inventory"),
            current_inventory=current_inventory,
            prior_commit=PRIOR2_SOURCE_COMMIT,
            allowed_diff_paths=PRIOR2_REUSE_ALLOWED_DIFF_PATHS,
            changed_test_pins=PRIOR2_REUSE_CHANGED_TEST_PINS,
        )

    packages = _verify_prior_toolchain_and_deps(
        ev_dir, expected_packages=expected_packages, expected_source_commit=PRIOR2_SOURCE_COMMIT
    )
    sim, sim_linkage_sha = _verify_prior_simulator_and_linkage(
        ev_dir, members, expected_source_commit=PRIOR2_SOURCE_COMMIT, expected_run_id=PRIOR2_RUN_ID
    )
    prior2_destination = "platform=iOS Simulator,id=" + sim["udid"]

    native_prior2_dir = ev_dir / "epub-author-layout"
    require(
        native_prior2_dir.is_dir()
        and not native_prior2_dir.is_symlink()
        and {p.name for p in native_prior2_dir.iterdir()} == set(phase1_fresh_ids),
        "Prior2 archive fresh group inventory mismatch",
    )
    for excluded in phase2_fresh_ids:
        ex_dir = native_prior2_dir / excluded
        require(
            (ex_dir / "failure.json").is_file()
            and not (ex_dir / "failure.json").is_symlink()
            and not (ex_dir / "counts.json").exists()
            and not (ex_dir / "counts.json").is_symlink(),
            "Excluded failed prior2 group has unexpected passing receipt: " + excluded,
        )

    errors = []
    reused_group_proofs = []
    for group in prior2_reused_ids:
        spec = groups[group]
        try:
            proof = _verify_reused_prior2_group(
                group,
                spec,
                ev_dir,
                members,
                prior2_destination,
                verify_native=verify_native,
                current_effective_domain=current_effective_domain,
                current_effective_host=current_effective_host,
            )
            reused_group_proofs.append(proof)
        except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
            errors.append(f"{group}: {error}")

    reused_passed = [n for g in reused_group_proofs for n in g["passed"]]
    expected_reused = [n for g in prior2_reused_ids for n in groups[g]["cases"]]
    total_reused_exec = sum(g["executions"] for g in reused_group_proofs)
    if not errors:
        if (
            len(reused_passed) != len(set(reused_passed))
            or len(reused_passed) != PRIOR2_REUSED_DECLARATIONS
            or set(reused_passed) != set(expected_reused)
        ):
            errors.append("Prior2 reused declaration identity/count mismatch")
        if total_reused_exec != PRIOR2_REUSED_EXECUTIONS:
            errors.append("Prior2 reused execution count mismatch")

    passed = not errors and len(reused_group_proofs) == len(ELIGIBLE_PRIOR2_REUSE_GROUPS)
    sim_boot_sha = sha(ev_dir / "simulator-boot.json")
    scope_sha = sha(ev_dir / "author-layout-scope.json")
    cand_sha = sha(ev_dir / "candidate-sources.json")
    dep_sha = sha(ev_dir / "dependency-resolution.json")
    proof_sha = None
    if passed:
        proof_sha = _compute_prior_proof_digest({
            "prior_run_id": PRIOR2_RUN_ID,
            "prior_source_commit": PRIOR2_SOURCE_COMMIT,
            "artifact_id": PRIOR2_ARTIFACT_ID,
            "archive_sha256": PRIOR2_ARTIFACT_SHA256,
            "archive_bytes": receipt["archive_bytes"],
            "reused_groups": reused_group_proofs,
            "simulator_linkage_sha256": sim_linkage_sha,
            "simulator_boot_sha256": sim_boot_sha,
            "scope_sha256": scope_sha,
            "candidate_sources_sha256": cand_sha,
            "dependency_resolution_sha256": dep_sha,
        })

    return {
        "run_id": PRIOR2_RUN_ID,
        "run_attempt": "1",
        "source_commit": PRIOR2_SOURCE_COMMIT,
        "scope": SCOPE,
        "artifact_id": PRIOR2_ARTIFACT_ID,
        "artifact_name": PRIOR2_ARTIFACT_NAME,
        "archive_bytes": receipt["archive_bytes"],
        "archive_sha256": PRIOR2_ARTIFACT_SHA256,
        "workflow_conclusion": run.get("conclusion"),
        "excluded_groups": phase2_fresh_ids,
        "reused_groups": prior2_reused_ids,
        "declarations_passed": len(reused_passed) if passed else None,
        "executions_passed": total_reused_exec if passed else None,
        "groups": reused_group_proofs,
        "packages": packages,
        "simulator": sim,
        "simulator_boot_sha256": sim_boot_sha,
        "simulator_linkage_sha256": sim_linkage_sha,
        "proof_sha256": proof_sha,
        "native_bundle_parse": "passed" if (passed and verify_native) else (
            "failed" if verify_native else "not_executed_local_structural_replay"
        ),
        "qualified": passed and verify_native,
        "passed": passed,
        "errors": errors,
    }


def _load_offline_run_and_artifact(run_json_path, artifact_json_path, expected_name, expected_id=None):
    run = load(Path(run_json_path))
    artifact_payload = load(Path(artifact_json_path))
    artifact = _select_artifact_from_payload(artifact_payload, expected_name, expected_id=expected_id)
    return run, artifact


def _retain_prior_archive(prior_id, scope, reused_out, offline_entry=None):
    spec = _prior_spec(prior_id)
    pin_run_id = spec["run_id"]
    pin_commit = spec["source_commit"]
    pin_artifact_id = spec["artifact_id"]
    pin_artifact_name = spec["artifact_name"]
    pin_sha256 = spec["archive_sha256"]

    if offline_entry is not None:
        prior_zip = Path(offline_entry["zip_path"])
        prior_run, prior_artifact = _load_offline_run_and_artifact(
            offline_entry["run_json"],
            offline_entry["artifact_json"],
            pin_artifact_name,
            expected_id=pin_artifact_id,
        )
        validate_prior_run_and_artifact(
            pin_run_id, prior_run, prior_artifact, pin_commit, scope["run_id"]
        )
    else:
        prior_run = github_api_json(f"/actions/runs/{pin_run_id}")
        prior_art_payload = github_api_json(f"/actions/artifacts/{pin_artifact_id}")
        prior_artifact = _select_artifact_from_payload(
            prior_art_payload, pin_artifact_name, expected_id=pin_artifact_id
        )
        validate_prior_run_and_artifact(
            pin_run_id, prior_run, prior_artifact, pin_commit, scope["run_id"]
        )
        prior_zip = _reused_staging() / f"prior-{pin_run_id}.zip"
        github_download_artifact_zip(pin_artifact_id, prior_zip)

    require(
        prior_zip.is_file()
        and not prior_zip.is_symlink()
        and prior_zip.stat().st_size == prior_artifact["size_in_bytes"]
        and sha(prior_zip) == pin_sha256,
        f"Prior archive size/SHA256 mismatch for {pin_run_id}",
    )
    prior_members = safe_zip_members(prior_zip)

    prior_dir = reused_out / f"prior-{pin_run_id}"
    prior_dir.mkdir()
    with (prior_dir / "archive.zip").open("xb") as dst, prior_zip.open("rb") as src:
        shutil.copyfileobj(src, dst)
    write(prior_dir / "api-run.json", prior_run)
    write(prior_dir / "api-artifact.json", prior_artifact)
    retained_prior = extract_selected_members(prior_zip, prior_members, set(prior_members), prior_dir / "evidence")
    write(
        prior_dir / "archive-receipt.json",
        {
            "run_id": pin_run_id,
            "run_attempt": "1",
            "source_commit": pin_commit,
            "artifact_id": pin_artifact_id,
            "artifact_name": pin_artifact_name,
            "archive_bytes": prior_artifact["size_in_bytes"],
            "archive_sha256": pin_sha256,
            "member_count": len(prior_members),
            "members": prior_members,
            "retained_files": retained_prior,
        },
    )
    return prior_dir


def _load_current_effective_settings():
    eff_path = OUT / "effective-test-settings.json"
    current_eff_domain = None
    if eff_path.exists() or eff_path.is_symlink():
        current_eff_domain = load(eff_path).get("ReaderDomainTests")
        compat._validate_domain_effective_settings(current_eff_domain)
    host3_settings_path = _out_path(NATIVE_OUT, "epub-author-layout") / "host-3/YueJingHostTests-settings.json"
    current_eff_host = None
    if host3_settings_path.exists() or host3_settings_path.is_symlink():
        current_eff_host = load(host3_settings_path)
    return current_eff_domain, current_eff_host


def _build_combined_prior_summary(prior_validation_run, origin_summaries):
    if prior_validation_run == PRIOR_RUN_ID:
        return origin_summaries[0], origin_summaries[0]["proof_sha256"]
    s1, s2 = origin_summaries
    all_passed = bool(s1["passed"] and s2["passed"])
    all_qualified = bool(s1["qualified"] and s2["qualified"])
    combined_proof = None
    errors = list(s1["errors"]) + list(s2["errors"])
    combined_groups = list(s1["groups"]) + list(s2["groups"])
    if all_passed:
        cases1 = [n for g in s1["groups"] for n in g["passed"]]
        cases2 = [n for g in s2["groups"] for n in g["passed"]]
        require(not (set(cases1) & set(cases2)), "Dual-origin reused case declarations overlap")
        require(
            len(cases1) == PRIOR_REUSED_DECLARATIONS
            and len(cases2) == PRIOR2_REUSED_DECLARATIONS
            and s1["executions_passed"] == PRIOR_REUSED_EXECUTIONS
            and s2["executions_passed"] == PRIOR2_REUSED_EXECUTIONS,
            "Dual-origin reused counts mismatch",
        )
        combined_proof = _compute_prior_proof_digest({
            "prior_validation_run": PRIOR2_RUN_ID,
            "origins": [
                {
                    "run_id": s1["run_id"],
                    "source_commit": s1["source_commit"],
                    "artifact_id": s1["artifact_id"],
                    "archive_sha256": s1["archive_sha256"],
                    "proof_sha256": s1["proof_sha256"],
                    "reused_groups": s1["reused_groups"],
                },
                {
                    "run_id": s2["run_id"],
                    "source_commit": s2["source_commit"],
                    "artifact_id": s2["artifact_id"],
                    "archive_sha256": s2["archive_sha256"],
                    "proof_sha256": s2["proof_sha256"],
                    "reused_groups": s2["reused_groups"],
                },
            ],
        })
    combined = {
        "run_id": PRIOR2_RUN_ID,
        "run_attempt": "1",
        "source_commit": PRIOR2_SOURCE_COMMIT,
        "scope": SCOPE,
        "artifact_id": PRIOR2_ARTIFACT_ID,
        "artifact_name": PRIOR2_ARTIFACT_NAME,
        "archive_bytes": s2["archive_bytes"],
        "archive_sha256": PRIOR2_ARTIFACT_SHA256,
        "workflow_conclusion": s2["workflow_conclusion"],
        "excluded_groups": list(s2["excluded_groups"]),
        "reused_groups": list(s1["reused_groups"]) + list(s2["reused_groups"]),
        "declarations_passed": COMBINED_PRIOR2_REUSED_DECLARATIONS if all_passed else None,
        "executions_passed": COMBINED_PRIOR2_REUSED_EXECUTIONS if all_passed else None,
        "groups": combined_groups,
        "packages": s2["packages"],
        "simulator": s2["simulator"],
        "simulator_boot_sha256": s2["simulator_boot_sha256"],
        "simulator_linkage_sha256": s2["simulator_linkage_sha256"],
        "proof_sha256": combined_proof,
        "origins": [s1, s2],
        "native_bundle_parse": "passed" if all_qualified else (
            "failed" if any(s["native_bundle_parse"] == "failed" for s in origin_summaries)
            else "not_executed_local_structural_replay"
        ),
        "qualified": all_qualified,
        "passed": all_passed,
        "errors": errors,
    }
    return combined, combined_proof


def reuse_evidence(*, require_dependencies=True, offline_prior=None, check_shared_sources=True, root=ROOT):
    """Download/bind pinned prior archive(s) and strictly requalify eligible passing groups."""
    require(
        os.environ.get("GITHUB_ACTIONS") != "true"
        or (require_dependencies and offline_prior is None and check_shared_sources),
        "Cloud offline replay/bypass forbidden",
    )
    root = Path(root)
    scope = live_scope(root=root)
    prior_id = scope["prior_validation_run"]
    if prior_id == P2_RUN_ID:
        require(require_dependencies and offline_prior is None and check_shared_sources, "P2 cloud reuse requires full prerequisites")
        return p2_reuse(scope, root=root)
    require(
        prior_id in AUTHORIZED_PRIOR_RUNS,
        f"reuse requires prior_validation_run in {sorted(AUTHORIZED_PRIOR_RUNS)}",
    )
    expected_packages = (
        compat.validate_toolchain_and_dependencies(root, OUT, check_live_tools=False)
        if require_dependencies
        else None
    )
    reused_out = _reused_out()
    require(not reused_out.exists() and not reused_out.is_symlink(),
            "Existing reused evidence; use a fresh dispatch")

    if offline_prior is not None:
        if prior_id == PRIOR_RUN_ID:
            require(
                isinstance(offline_prior, dict) and {"zip_path", "run_json", "artifact_json"} <= set(offline_prior),
                "Single-prior offline replay requires zip_path, run_json, and artifact_json",
            )
            offline_map = {PRIOR_RUN_ID: offline_prior}
        else:
            require(
                isinstance(offline_prior, dict)
                and set(offline_prior) == {PRIOR_RUN_ID, PRIOR2_RUN_ID},
                f"Dual-prior offline replay requires entries for both {PRIOR_RUN_ID} and {PRIOR2_RUN_ID}",
            )
            offline_map = offline_prior
    else:
        offline_map = {}

    reused_out.mkdir(parents=True)
    origin_ids = _prior_origin_ids(prior_id)
    prior_dirs = {}
    for oid in origin_ids:
        prior_dirs[oid] = _retain_prior_archive(oid, scope, reused_out, offline_entry=offline_map.get(oid))

    current_eff_domain, current_eff_host = _load_current_effective_settings()
    live_api = os.environ.get("GITHUB_ACTIONS") == "true"
    origin_summaries = [
        inspect_prior_evidence(
            prior_dirs[PRIOR_RUN_ID],
            scope,
            root=root,
            expected_packages=expected_packages,
            current_effective_domain=current_eff_domain,
            check_shared_sources=check_shared_sources,
            verify_native=True,
            check_live_api=live_api,
        )
    ]
    if prior_id == PRIOR2_RUN_ID:
        origin_summaries.append(
            inspect_prior2_evidence(
                prior_dirs[PRIOR2_RUN_ID],
                scope,
                root=root,
                expected_packages=expected_packages,
                current_effective_domain=current_eff_domain,
                current_effective_host=current_eff_host,
                check_shared_sources=check_shared_sources,
                verify_native=True,
                check_live_api=live_api,
            )
        )

    combined_summary, proof_sha = _build_combined_prior_summary(prior_id, origin_summaries)
    spec = _prior_spec(prior_id)
    gate_receipt = {
        "scope": SCOPE,
        "phase": "validation",
        "source_commit": scope["source_commit"],
        "run_id": scope["run_id"],
        "run_attempt": "1",
        "prior_validation_run": prior_id,
        "prior_source_commit": spec["source_commit"],
        "prior_artifact_id": spec["artifact_id"],
        "prior_artifact_sha256": spec["archive_sha256"],
        "provenance_valid": True,
        "passed": combined_summary["passed"],
        "qualified": combined_summary["qualified"],
        "reused_declarations": combined_summary["declarations_passed"] if combined_summary["passed"] else None,
        "reused_executions": combined_summary["executions_passed"] if combined_summary["passed"] else None,
        "reused_native_passed": combined_summary["executions_passed"] if combined_summary["passed"] else None,
        "proof_sha256": proof_sha,
        "errors": combined_summary["errors"],
        "prior": combined_summary,
    }
    if prior_id == PRIOR2_RUN_ID:
        gate_receipt["prior_origins"] = origin_summaries
    write(_reused_gate_json(), gate_receipt)
    require(
        combined_summary["passed"] and combined_summary["qualified"],
        "Prior validation run reuse verification failed: " + "; ".join(combined_summary["errors"]),
    )
    return gate_receipt


def verify_prior_reuse_saved(
    scope,
    packages,
    *,
    current_effective_domain=None,
    current_effective_host=None,
    root=ROOT,
    check_shared_sources=True,
    check_live_api=None,
):
    prior_id = scope["prior_validation_run"]
    if prior_id == P2_RUN_ID:
        return p2_verify_saved(scope, packages=packages, root=root)
    require(
        prior_id in AUTHORIZED_PRIOR_RUNS,
        f"Unsupported prior_validation_run: {prior_id!r}",
    )
    origin_ids = _prior_origin_ids(prior_id)
    reused_out = _reused_out()
    reused_gate_path = _reused_gate_json()
    expected_entries = {f"prior-{oid}" for oid in origin_ids} | {reused_gate_path.name}
    require(
        reused_out.is_dir()
        and not reused_out.is_symlink()
        and {p.name for p in reused_out.iterdir()} == expected_entries,
        "Missing or extra entries in reused-evidence directory",
    )
    require(reused_gate_path.is_file() and not reused_gate_path.is_symlink(),
            "Missing reused-prior-gate.json")
    saved = load(reused_gate_path)
    live_api = (os.environ.get("GITHUB_ACTIONS") == "true") if check_live_api is None else check_live_api
    origin_summaries = [
        inspect_prior_evidence(
            reused_out / f"prior-{PRIOR_RUN_ID}",
            scope,
            root=root,
            expected_packages=packages,
            current_effective_domain=current_effective_domain,
            check_shared_sources=check_shared_sources,
            verify_native=True,
            check_live_api=live_api,
        )
    ]
    if prior_id == PRIOR2_RUN_ID:
        origin_summaries.append(
            inspect_prior2_evidence(
                reused_out / f"prior-{PRIOR2_RUN_ID}",
                scope,
                root=root,
                expected_packages=packages,
                current_effective_domain=current_effective_domain,
                current_effective_host=current_effective_host,
                check_shared_sources=check_shared_sources,
                verify_native=True,
                check_live_api=live_api,
            )
        )
    combined_summary, proof_sha = _build_combined_prior_summary(prior_id, origin_summaries)
    spec = _prior_spec(prior_id)
    expected_gate = {
        "scope": SCOPE,
        "phase": "validation",
        "source_commit": scope["source_commit"],
        "run_id": scope["run_id"],
        "run_attempt": "1",
        "prior_validation_run": prior_id,
        "prior_source_commit": spec["source_commit"],
        "prior_artifact_id": spec["artifact_id"],
        "prior_artifact_sha256": spec["archive_sha256"],
        "provenance_valid": True,
        "passed": True,
        "qualified": True,
        "reused_declarations": combined_summary["declarations_passed"],
        "reused_executions": combined_summary["executions_passed"],
        "reused_native_passed": combined_summary["executions_passed"],
        "proof_sha256": proof_sha,
        "errors": [],
        "prior": combined_summary,
    }
    if prior_id == PRIOR2_RUN_ID:
        expected_gate["prior_origins"] = origin_summaries
    require(combined_summary["passed"] and combined_summary["qualified"],
            "Prior evidence failed strict requalification: " + "; ".join(combined_summary["errors"]))
    require(json.dumps(saved, sort_keys=True) == json.dumps(expected_gate, sort_keys=True),
            "Reused prior gate receipt drift")
    return expected_gate


def run_group(group, destination, *, checked_scope=None, groups=None):
    scope = checked_scope if checked_scope is not None else live_scope()
    active_groups = groups if groups is not None else build_groups(load_scope_config())
    require(group in active_groups, "Unknown group: " + str(group))
    if scope.get("prior_validation_run"):
        require(
            group in scope.get("fresh_groups", []),
            f"Group {group} is reused from prior run {scope['prior_validation_run']} and cannot execute freshly",
        )
    spec = active_groups[group]
    if checked_scope is None:
        compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=True)
        compat.validate_destination(destination, OUT)

    native_out = _out_path(NATIVE_OUT, "epub-author-layout")
    folder = native_out / group
    require(not folder.exists() and not folder.is_symlink(), "Existing group evidence; use a fresh dispatch")
    folder.mkdir(parents=True)
    target, kind = spec["target"], spec["kind"]
    bundle = folder / f"{target}.xcresult"
    want = provenance(group, destination, bundle, scope, groups=active_groups)
    write(folder / "selection.json", want)
    try:
        reading.prepare_group_settings(kind, folder, scope["source_commit"], root=ROOT, out=OUT)
    except Exception as error:
        raise GroupPrerequisiteError(str(error)) from error

    log_path = folder / f"{target}.log"
    code, timed_out = stream_case(want["command"], log_path, spec["timeout"])
    write(folder / "execution.json", {**want, "native_exit": code, "timed_out": timed_out})
    raw = log_path.read_bytes()
    if code != 0 and (b"** BUILD FAILED **" in raw or b"** TEST BUILD FAILED **" in raw) and b" started." not in raw:
        raise GroupPrerequisiteError("Shared test build failed; remaining target cases blocked")

    if code != 0 or timed_out:
        if bundle.exists():
            try:
                retain_xcresult_exports(folder, bundle)
            except (OSError, ValueError, subprocess.SubprocessError):
                pass
    else:
        retain_xcresult_exports(folder, bundle)

    parsed = parse_log(group, raw, code, timed_out, groups=active_groups)
    verify_group_xcresult(spec, bundle, exported_folder=folder)
    parsed["parameter_xcresult"] = parameter_evidence(group, folder, bundle, group_specs=active_groups)
    require(live_scope() == scope, "Source changed during native execution")
    write(folder / "counts.json", parsed)
    return parsed


def run_all(destination):
    """Execute fresh selected groups independently, isolate shared compile blocks per kind, and never retry."""
    native_out = _out_path(NATIVE_OUT, "epub-author-layout")
    require(not native_out.exists() and not native_out.is_symlink(),
            "Existing native evidence; do not retry/overwrite cases")
    OUT.mkdir(parents=True, exist_ok=True)
    previous_term = signal.getsignal(signal.SIGTERM)

    def cancelled(signum, frame):
        raise KeyboardInterrupt("User/job cancelled")

    signal.signal(signal.SIGTERM, cancelled)
    try:
        scope = live_scope()
        packages = compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=True)
        compat.validate_destination(destination, OUT)
        groups = build_groups(load_scope_config())
        fresh_ids, _ = partition_groups(groups, scope.get("prior_validation_run", ""))
        if scope.get("prior_validation_run"):
            eff_path = OUT / "effective-test-settings.json"
            require(eff_path.is_file() and not eff_path.is_symlink(), "Missing effective-test-settings.json")
            current_eff = load(eff_path).get("ReaderDomainTests")
            compat._validate_domain_effective_settings(current_eff)
            verify_prior_reuse_saved(scope, packages, current_effective_domain=current_eff, root=ROOT)
        native_out.mkdir()
        summarize()
        blocked = {}
        for group in fresh_ids:
            spec = groups[group]
            if spec["kind"] in blocked:
                folder = native_out / group
                folder.mkdir()
                write(folder / "failure.json", {
                    "group": group,
                    "target": spec["target"],
                    "kind": spec["kind"],
                    "cases": list(spec["cases"]),
                    "error_type": "GroupPrerequisiteError",
                    "error": blocked[spec["kind"]],
                    "status": "blocked",
                    "source_commit": scope["source_commit"],
                    "run_id": scope["run_id"],
                })
                continue
            require(live_scope() == scope, "Source/run changed during case scheduling")
            try:
                print(f"Running {group} ({spec['file']}): {len(spec['cases'])} case(s)", flush=True)
                run_group(group, destination, checked_scope=scope, groups=groups)
            except Exception as error:
                folder = native_out / group
                folder.mkdir(exist_ok=True)
                is_block = isinstance(error, GroupPrerequisiteError)
                if is_block:
                    blocked[spec["kind"]] = str(error)
                failure_path = folder / "failure.json"
                if not failure_path.exists():
                    write(failure_path, {
                        "group": group,
                        "target": spec["target"],
                        "kind": spec["kind"],
                        "cases": list(spec["cases"]),
                        "error_type": type(error).__name__,
                        "error": str(error),
                        "status": "blocked" if is_block else "error",
                        "source_commit": scope["source_commit"],
                        "run_id": scope["run_id"],
                    })
            finally:
                summarize()
        result = summarize()
        fresh_rows = [row for row in result["cases"] if row.get("execution_origin", "fresh") == "fresh"]
        fresh_ok = bool(fresh_rows) and all(row["status"] == "passed" for row in fresh_rows)
        expected_reused_exec = scope.get("reused_executions_planned", 0)
        reused_ok = not scope.get("prior_validation_run") or (
            result.get("reused_native_passed") == expected_reused_exec
            and (result.get("prior_reuse") or {}).get("status") == "passed"
        )
        return fresh_ok and reused_ok
    except (Exception, KeyboardInterrupt) as error:
        sched_path = OUT / "case-scheduling-error.json"
        if not sched_path.exists():
            write(sched_path, {"error_type": type(error).__name__, "error": str(error) or "Cancelled"})
        raise
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        summarize()

def _optional_json(path):
    if not path.exists() and not path.is_symlink():
        return None
    require(path.is_file() and not path.is_symlink(), f"Invalid report evidence path: {path.name}")
    return load(path)


def _inspect_group_raw_events(spec, raw_bytes):
    """Best-effort diagnostic raw event extraction (never relaxes gate parsing)."""
    names = list(spec["cases"])
    if raw_bytes is None:
        return {n: "no_log" for n in names}, {}
    text = raw_bytes.decode("utf-8", errors="replace")
    adapted = text
    arg_rows = {}
    for name in names:
        p_spec = inventory.PARAMETERIZED.get(name)
        if p_spec:
            sig = name + p_spec["signature"]
            adapted = adapted.replace(sig, name + "()")
            arg_pattern = re.compile(
                rf"^\u200b?(?:◇ )?Passing 1 argument {re.escape(p_spec['argument'])} → ([^\s]+) to {re.escape(sig)}\.?$"
            )
            arg_rows[name] = [m[1] for line in text.splitlines() if (m := arg_pattern.fullmatch(line))]
    try:
        parsed = audit.parse_events(
            adapted.encode("utf-8"),
            names,
            ui=spec["kind"] == "ui",
            ui_class="EPUBFlowUITests",
        )
        return {c["name"]: c["status"] for c in parsed["cases"]}, arg_rows
    except ValueError:
        return {n: "ambiguous" for n in names}, arg_rows


def _summarize_prior_reuse(prior_id, scope):
    if not prior_id:
        return None
    if prior_id == P2_RUN_ID:
        return p2_summary(scope)
    if prior_id not in AUTHORIZED_PRIOR_RUNS:
        return {
            "status": "failed",
            "run_id": prior_id,
            "source_commit": None,
            "artifact_id": None,
            "archive_sha256": None,
            "proof_sha256": None,
            "declarations_passed": None,
            "executions_passed": None,
            "verified_groups": [],
            "origins": [],
            "error": f"Unsupported prior_validation_run: {prior_id!r}",
        }
    spec = _prior_spec(prior_id)
    origin_ids = _prior_origin_ids(prior_id)
    reused_gate_path = _reused_gate_json()
    reused_out = _reused_out()
    prior_dirs = {oid: reused_out / f"prior-{oid}" for oid in origin_ids}
    if not reused_gate_path.exists() and not any(d.exists() for d in prior_dirs.values()):
        return {
            "status": "not_verified",
            "run_id": spec["run_id"],
            "source_commit": spec["source_commit"],
            "artifact_id": spec["artifact_id"],
            "archive_sha256": spec["archive_sha256"],
            "proof_sha256": None,
            "declarations_passed": None,
            "executions_passed": None,
            "verified_groups": [],
            "origins": [
                {
                    "status": "not_verified",
                    "run_id": _prior_spec(oid)["run_id"],
                    "source_commit": _prior_spec(oid)["source_commit"],
                    "artifact_id": _prior_spec(oid)["artifact_id"],
                    "archive_sha256": _prior_spec(oid)["archive_sha256"],
                    "proof_sha256": None,
                    "declarations_passed": None,
                    "executions_passed": None,
                    "verified_groups": [],
                    "error": f"尚未核验前置 run {oid} 证据",
                }
                for oid in origin_ids
            ],
            "error": f"尚未核验前置 run {' 与 '.join(origin_ids)} 证据",
        }
    try:
        reused_gate = _optional_json(reused_gate_path)
        require(reused_gate is not None, "Missing reused-prior-gate.json")
        require(
            reused_gate.get("scope") == SCOPE
            and reused_gate.get("prior_validation_run") == spec["run_id"]
            and reused_gate.get("prior_source_commit") == spec["source_commit"]
            and reused_gate.get("prior_artifact_id") == spec["artifact_id"]
            and reused_gate.get("prior_artifact_sha256") == spec["archive_sha256"]
            and reused_gate.get("passed") is True
            and reused_gate.get("qualified") is True,
            "Reused prior gate receipt did not qualify",
        )
        if os.environ.get("GITHUB_ACTIONS") == "true":
            require(scope is not None, "Missing author-layout-scope.json in cloud")
        effective_scope = scope or {
            "run_id": os.environ.get("GITHUB_RUN_ID", ""),
            "source_commit": os.environ.get("GITHUB_SHA", ""),
        }
        require(
            reused_gate.get("source_commit") == effective_scope.get("source_commit")
            and str(reused_gate.get("run_id")) == str(effective_scope.get("run_id")),
            "Reused gate source/run identity mismatch",
        )
        expected_packages = None
        resolved_path = ROOT / "YueJing.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        if os.environ.get("GITHUB_ACTIONS") == "true" or (
            (OUT / "dependency-resolution.json").is_file() and resolved_path.is_file()
        ):
            expected_packages = compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=False)
        current_eff_domain, current_eff_host = _load_current_effective_settings()
        verify_native_flag = (sys.platform == "darwin") or (os.environ.get("GITHUB_ACTIONS") == "true")

        origin_summaries = [
            inspect_prior_evidence(
                prior_dirs[PRIOR_RUN_ID],
                effective_scope,
                root=ROOT,
                expected_packages=expected_packages,
                current_effective_domain=current_eff_domain,
                check_shared_sources=True,
                verify_native=verify_native_flag,
                check_live_api=False,
            )
        ]
        if prior_id == PRIOR2_RUN_ID:
            origin_summaries.append(
                inspect_prior2_evidence(
                    prior_dirs[PRIOR2_RUN_ID],
                    effective_scope,
                    root=ROOT,
                    expected_packages=expected_packages,
                    current_effective_domain=current_eff_domain,
                    current_effective_host=current_eff_host,
                    check_shared_sources=True,
                    verify_native=verify_native_flag,
                    check_live_api=False,
                )
            )
        for s in origin_summaries:
            require(s["passed"], "; ".join(s["errors"]) or f"Prior inspection failed for {s['run_id']}")
        combined_summary, proof_sha = _build_combined_prior_summary(prior_id, origin_summaries)
        require(reused_gate.get("proof_sha256") == proof_sha, "Prior proof digest drift")
        require(
            (reused_gate.get("prior") or {}).get("native_bundle_parse") == "passed",
            "Prior native xcresult bundle parse not verified",
        )
        if os.environ.get("GITHUB_ACTIONS") == "true":
            require(combined_summary["native_bundle_parse"] == "passed", "Cloud prior xcresult parse did not pass")
        origin_rows = [
            {
                "status": "passed",
                "run_id": s["run_id"],
                "source_commit": s["source_commit"],
                "artifact_id": s["artifact_id"],
                "archive_sha256": s["archive_sha256"],
                "proof_sha256": s["proof_sha256"],
                "declarations_passed": s["declarations_passed"],
                "executions_passed": s["executions_passed"],
                "verified_groups": [g["group"] for g in s["groups"]],
                "error": None,
            }
            for s in origin_summaries
        ]
        return {
            "status": "passed",
            "run_id": spec["run_id"],
            "source_commit": spec["source_commit"],
            "artifact_id": spec["artifact_id"],
            "archive_sha256": spec["archive_sha256"],
            "proof_sha256": proof_sha,
            "declarations_passed": combined_summary["declarations_passed"],
            "executions_passed": combined_summary["executions_passed"],
            "verified_groups": [g["group"] for g in combined_summary["groups"]],
            "origins": origin_rows,
            "error": None,
        }
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        return {
            "status": "failed",
            "run_id": spec["run_id"],
            "source_commit": spec["source_commit"],
            "artifact_id": spec["artifact_id"],
            "archive_sha256": spec["archive_sha256"],
            "proof_sha256": None,
            "declarations_passed": None,
            "executions_passed": None,
            "verified_groups": [],
            "origins": [],
            "error": str(error),
        }


def summarize(*, publish=False):
    """Diagnostic per-case & inventory summary; qualification() independently validates everything."""
    config = load_scope_config()
    groups = build_groups(config)
    native_out = _out_path(NATIVE_OUT, "epub-author-layout")
    scope = None
    try:
        scope = _optional_json(_out_path(SCOPE_JSON, "author-layout-scope.json"))
    except (ValueError, OSError):
        scope = None

    prior_id = (scope or {}).get("prior_validation_run")
    if prior_id is None:
        prior_id = os.environ.get("PRIOR_VALIDATION_RUN", "")
    if prior_id:
        if prior_id in AUTHORIZED_PRIOR_RUNS:
            try:
                fresh_ids, reused_ids = partition_groups(groups, prior_id)
            except ValueError:
                fallback_reused = (
                    ELIGIBLE_PRIOR_REUSE_GROUPS
                    if prior_id == PRIOR_RUN_ID
                    else (ELIGIBLE_PRIOR_REUSE_GROUPS | ELIGIBLE_PRIOR2_REUSE_GROUPS)
                )
                fresh_ids = [g for g in groups if g not in fallback_reused]
                reused_ids = [g for g in groups if g in fallback_reused]
        else:
            fresh_ids = [g for g in groups if g not in ELIGIBLE_PRIOR_REUSE_GROUPS]
            reused_ids = [g for g in groups if g in ELIGIBLE_PRIOR_REUSE_GROUPS]
    else:
        fresh_ids, reused_ids = list(groups), []
    reused_set = set(reused_ids)

    reviewed = None
    try:
        reviewed = inventory.validate_source(ROOT)
    except (ValueError, OSError, KeyError, TypeError):
        reviewed = None

    scheduling = None
    try:
        scheduling = _optional_json(OUT / "case-scheduling-error.json")
    except (ValueError, OSError) as error:
        scheduling = {"error": str(error)}

    prior_reuse_summary = _summarize_prior_reuse(prior_id, scope)
    reused_ok = bool(prior_reuse_summary and prior_reuse_summary["status"] == "passed")

    case_rows = []
    group_rows = []
    for group, spec in groups.items():
        target = spec["target"]
        cases = list(spec["cases"])
        planned_exec = sum(len(inventory.PARAMETERIZED.get(c, {}).get("values", [None])) for c in cases)

        if group in reused_set:
            group_origin_id = (
                P2_RUN_ID if prior_id == P2_RUN_ID else
                (PRIOR_RUN_ID if (group in ELIGIBLE_PRIOR_REUSE_GROUPS or prior_id != PRIOR2_RUN_ID) else PRIOR2_RUN_ID)
            )
            group_origin_spec = _prior_spec(group_origin_id)
            group_origin_commit = group_origin_spec["source_commit"]
            reused_group_ok = reused_ok and group in prior_reuse_summary["verified_groups"]
            if reused_group_ok:
                st = "reused"
                raw_st = "reused_passed"
                rsn = f"严格复用自前置运行 {group_origin_id}（提交 {group_origin_commit[:7]}）；未在本轮重跑"
            elif prior_reuse_summary and prior_reuse_summary["status"] == "failed":
                st = "error"
                raw_st = "reused_failed"
                rsn = "前置复用核验失败：" + (prior_reuse_summary.get("error") or "未知错误")
            else:
                st = "not_verified"
                raw_st = "not_verified"
                rsn = (prior_reuse_summary or {}).get("error") or "尚未核验前置复用证据"
            row_origin_run_id = group_origin_id if prior_id in AUTHORIZED_PRIOR_RUNS else prior_id
            for case in cases:
                case_exec = len(inventory.PARAMETERIZED.get(case, {}).get("values", [None]))
                case_rows.append({
                    "group": group,
                    "target": target,
                    "file": spec["file"],
                    "case": case,
                    "kind": spec["kind"],
                    "execution_origin": "reused_prior",
                    "source_commit": group_origin_commit,
                    "run_id": row_origin_run_id,
                    "planned_executions": case_exec,
                    "raw_event_status": raw_st,
                    "native_exit": 0 if reused_group_ok else None,
                    "timed_out": False if reused_group_ok else None,
                    "status": st,
                    "reason": rsn,
                })
            group_rows.append({
                "group": group,
                "target": target,
                "file": spec["file"],
                "kind": spec["kind"],
                "execution_origin": "reused_prior",
                "source_commit": group_origin_commit,
                "run_id": row_origin_run_id,
                "declared": len(cases),
                "planned_executions": planned_exec,
                "native_exit": 0 if reused_group_ok else None,
                "timed_out": False if reused_group_ok else None,
                "status": st,
            })
            continue

        folder = native_out / group
        execution = failure = counts_doc = None
        raw_bytes = None
        read_error = None
        try:
            execution = _optional_json(folder / "execution.json")
            failure = _optional_json(folder / "failure.json")
            counts_doc = _optional_json(folder / "counts.json")
            log_path = folder / f"{target}.log"
            if log_path.exists() or log_path.is_symlink():
                require(log_path.is_file() and not log_path.is_symlink(), f"Invalid raw log: {target}.log")
                raw_bytes = log_path.read_bytes()
        except (ValueError, OSError) as error:
            read_error = str(error)

        raw_statuses, arg_rows = _inspect_group_raw_events(spec, raw_bytes)
        group_counts_valid = False
        counts_error = read_error
        if (
            read_error is None
            and execution is not None
            and failure is None
            and counts_doc is not None
            and not execution.get("timed_out")
            and execution.get("native_exit") == 0
            and raw_bytes is not None
        ):
            try:
                parsed = parse_log(group, raw_bytes, 0, False, groups=groups)
                if any(c in inventory.PARAMETERIZED for c in cases):
                    param_raw = (folder / "xcresult-tests.json").read_bytes()
                    param_doc = json.loads(param_raw)
                    param_names = [c for c in cases if c in inventory.PARAMETERIZED]
                    if len(param_names) == 1:
                        parsed["parameter_xcresult"] = {
                            **parameter_result(param_doc, param_names[0]),
                            "raw_sha256": digest_bytes(param_raw),
                        }
                    else:
                        parsed["parameter_xcresult"] = {
                            "cases": [parameter_result(param_doc, n) for n in param_names],
                            "raw_sha256": digest_bytes(param_raw),
                        }
                else:
                    parsed["parameter_xcresult"] = None
                require(json.dumps(counts_doc, sort_keys=True) == json.dumps(parsed, sort_keys=True),
                        "Summary counts differ from raw events")
                group_counts_valid = True
            except (ValueError, OSError, KeyError, TypeError) as error:
                counts_error = str(error)

        any_raw_nonpass = any(raw_statuses[c] != "passed" for c in cases)
        per_group_rows = []
        for case in cases:
            case_exec = len(inventory.PARAMETERIZED.get(case, {}).get("values", [None]))
            raw_status = raw_statuses[case]
            row = {
                "group": group,
                "target": target,
                "file": spec["file"],
                "case": case,
                "kind": spec["kind"],
                "execution_origin": "fresh",
                "source_commit": (scope or {}).get("source_commit") or os.environ.get("GITHUB_SHA"),
                "run_id": (scope or {}).get("run_id") or os.environ.get("GITHUB_RUN_ID"),
                "planned_executions": case_exec,
                "raw_event_status": raw_status,
                "native_exit": execution.get("native_exit") if execution else None,
                "timed_out": execution.get("timed_out") if execution else None,
            }
            if read_error is not None:
                row.update(status="error", reason="结果证据无效：" + read_error)
            elif execution is None:
                if failure is not None:
                    row.update(
                        status="blocked" if failure.get("status") == "blocked" else "error",
                        reason=failure.get("error", "组前置失败"),
                    )
                else:
                    row.update(status="not_run", reason="尚未开始；检查前置准备、调度或取消状态")
            elif group_counts_valid:
                row.update(status="passed", reason="本轮原始事件与通过回执一致；正式资格另行核验")
            elif execution.get("native_exit") == 0 and not execution.get("timed_out") and failure is None:
                reason = ("结果证据无效：" + counts_error) if counts_error else "执行已结束但缺少合格结果回执"
                row.update(status="error", reason=reason)
            else:
                if raw_status == "failed":
                    row.update(status="failed", reason="原生事件记录该用例失败")
                elif raw_status == "skipped":
                    row.update(status="skipped", reason="原生事件记录该用例被跳过")
                elif raw_status == "unfinished":
                    if execution.get("timed_out"):
                        row.update(status="timed_out", reason="用例已开始但执行超时未完成")
                    else:
                        row.update(status="unfinished", reason="用例已开始但未记录结束事件")
                elif raw_status == "ambiguous":
                    row.update(status="ambiguous", reason="原生事件出现重复/异常或 recorded issue")
                elif raw_status == "unexecuted":
                    if failure is not None and failure.get("status") == "blocked":
                        row.update(status="blocked", reason=failure.get("error", "共享编译失败，未执行用例"))
                    else:
                        row.update(status="unexecuted", reason="同组命令中止，未执行到该用例")
                elif raw_status == "passed":
                    p_spec = inventory.PARAMETERIZED.get(case)
                    if p_spec and sorted(arg_rows.get(case, [])) != sorted(p_spec["values"]):
                        row.update(status="failed", reason="参数化用例未完整执行全部 Bool 参数")
                    elif not any_raw_nonpass:
                        st = "timed_out" if execution.get("timed_out") else ("failed" if execution.get("native_exit") != 0 else "error")
                        row.update(status=st, reason=f"用例原始事件通过，但组执行异常(exit={execution.get('native_exit')}, timed_out={execution.get('timed_out')})")
                    else:
                        row.update(status="passed", reason="该用例原始事件通过（同组其他用例失败，整体未获资格）")
                else:
                    if failure is not None and failure.get("status") == "blocked":
                        row.update(status="blocked", reason=failure.get("error", "共享前置/编译失败"))
                    elif execution.get("timed_out"):
                        row.update(status="timed_out", reason="执行超时且缺少原始日志")
                    else:
                        row.update(status="error", reason=(failure or {}).get("error", "缺少原始日志或执行异常"))
            per_group_rows.append(row)
            case_rows.append(row)

        group_rows.append({
            "group": group,
            "target": target,
            "file": spec["file"],
            "kind": spec["kind"],
            "execution_origin": "fresh",
            "source_commit": (scope or {}).get("source_commit") or os.environ.get("GITHUB_SHA"),
            "run_id": (scope or {}).get("run_id") or os.environ.get("GITHUB_RUN_ID"),
            "declared": len(cases),
            "planned_executions": planned_exec,
            "native_exit": execution.get("native_exit") if execution else None,
            "timed_out": execution.get("timed_out") if execution else None,
            "status": "passed" if all(r["status"] == "passed" for r in per_group_rows) else (
                "blocked" if all(r["status"] == "blocked" for r in per_group_rows) else
                "not_run" if all(r["status"] == "not_run" for r in per_group_rows) else "failed"
            ),
        })

    if publish and scheduling is None and any(r["status"] == "not_run" for r in case_rows):
        scheduling = {"error": "Final report: case not admitted; shared preparation incomplete, cancelled, or scheduling never started."}
    if scheduling:
        for row in case_rows:
            if row["status"] == "not_run":
                row.update(status="blocked", reason=scheduling["error"])

    status_keys = (
        "passed", "reused", "failed", "skipped", "timed_out",
        "unfinished", "ambiguous", "unexecuted", "blocked", "error",
        "not_run", "not_verified",
    )
    counts = {k: sum(r["status"] == k for r in case_rows) for k in status_keys}
    selected_set = {r["case"] for r in case_rows}
    selected_decl = len(case_rows)
    planned_exec_total = sum(r["planned_executions"] for r in case_rows)
    fresh_rows = [r for r in case_rows if r["execution_origin"] == "fresh"]
    reused_rows = [r for r in case_rows if r["execution_origin"] == "reused_prior"]
    fresh_decl_total = len(fresh_rows)
    fresh_exec_total = sum(r["planned_executions"] for r in fresh_rows)
    reused_decl_total = len(reused_rows)
    reused_exec_total = sum(r["planned_executions"] for r in reused_rows)

    all_fresh_passed = counts["passed"] == fresh_decl_total and fresh_decl_total > 0
    all_reused_verified = (not prior_id) or (reused_ok and counts["reused"] == reused_decl_total)
    fresh_exec_passed = fresh_exec_total if all_fresh_passed else None
    reused_exec_passed = reused_exec_total if (prior_id and all_reused_verified) else (0 if not prior_id else None)
    reused_decl_passed = reused_decl_total if (prior_id and all_reused_verified) else (0 if not prior_id else None)
    verified_exec_total = (fresh_exec_total + reused_exec_total) if (all_fresh_passed and all_reused_verified) else None
    verified_decl_total = (fresh_decl_total + reused_decl_total) if (all_fresh_passed and all_reused_verified) else None

    inventory_targets = []
    if reviewed is not None:
        excluded_map = reviewed.get("excluded", {})
        for target, target_cases in reviewed["cases"].items():
            sel_in_target = [c for c in target_cases if c in selected_set]
            omitted_in_target = [c for c in target_cases if c not in selected_set]
            inventory_targets.append({
                "target": target,
                "declared": len(target_cases),
                "selected": len(sel_in_target),
                "omitted": len(omitted_in_target),
                "status": "NOT RUN" if not sel_in_target else ("PARTIAL" if omitted_in_target else "SELECTED"),
                "omitted_cases": omitted_in_target,
                "excluded_from_task3": target in excluded_map,
            })

    full_decl = reviewed["selected"] if reviewed else (scope.get("full_inventory_declared") if scope else None)
    full_exec = reviewed["selected_executions"] if reviewed else (scope.get("full_inventory_executions") if scope else None)
    unselected_exec = (full_exec - planned_exec_total) if full_exec is not None else None

    prior_spec = _prior_spec(prior_id) if prior_id in AUTHORIZED_PRIOR_RUNS else None
    report_prior_origins = (
        (prior_reuse_summary or {}).get("origins") or _prior_origins_plan(prior_id, groups=groups)
        if prior_id in AUTHORIZED_PRIOR_RUNS
        else []
    )
    report = {
        "scope": SCOPE,
        "phase": "validation",
        "prior_validation_run": prior_id,
        "prior_source_commit": prior_spec["source_commit"] if prior_spec else "",
        "prior_artifact_id": prior_spec["artifact_id"] if prior_spec else None,
        "prior_artifact_sha256": prior_spec["archive_sha256"] if prior_spec else "",
        "prior_origins": report_prior_origins,
        "prior_reuse_proof_sha256": prior_reuse_summary.get("proof_sha256") if reused_ok else None,
        "source_commit": (scope or {}).get("source_commit") or os.environ.get("GITHUB_SHA"),
        "run_id": (scope or {}).get("run_id") or os.environ.get("GITHUB_RUN_ID"),
        "selected_declarations": selected_decl,
        "planned_executions": planned_exec_total,
        "fresh_declarations_planned": fresh_decl_total,
        "fresh_executions_planned": fresh_exec_total,
        "reused_declarations_planned": reused_decl_total,
        "reused_executions_planned": reused_exec_total,
        "native_tests_executed_this_run": fresh_exec_passed,
        "reused_native_passed": reused_exec_passed,
        "reused_declarations": reused_decl_passed,
        "verified_passed": verified_exec_total,
        "verified_declarations": verified_decl_total,
        "counts": counts,
        "groups": group_rows,
        "cases": case_rows,
        "prior_reuse": prior_reuse_summary,
        "inventory_targets": inventory_targets,
        "full_inventory_declared": full_decl,
        "full_inventory_executions": full_exec,
        "unselected_executions": unselected_exec,
        "full_regression_executed_this_run": False,
        "full_regression_passed": False,
        "scheduling_error": scheduling,
        "qualification": "DISPLAY_ONLY_NOT_RELEASE_QUALIFICATION",
    }

    def cell(val):
        return str(val).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("|", "&#124;").replace("\n", " ").replace("\r", " ")

    if prior_id == PRIOR2_RUN_ID:
        proof_label = (prior_reuse_summary or {}).get("proof_sha256") or "unverified"
        origin_bits = []
        for orig in report_prior_origins:
            o_decl = orig.get("declarations_passed") if orig.get("declarations_passed") is not None else orig.get("declarations")
            o_exec = orig.get("executions_passed") if orig.get("executions_passed") is not None else orig.get("executions")
            o_proof = orig.get("proof_sha256") or "unverified"
            origin_bits.append(
                f"run {orig['run_id']} (source {orig['source_commit']}, artifact {orig['artifact_id']}, "
                f"proof {o_proof}) {o_decl} declarations ({o_exec} executions)"
            )
        summary_line = (
            f"Selected: {selected_decl} declarations ({planned_exec_total} planned executions): "
            f"fresh this run {fresh_decl_total} declarations ({fresh_exec_total} executions); "
            f"reused {reused_decl_total} declarations ({reused_exec_total} executions) from two pinned origins "
            f"[{'; '.join(origin_bits)}] (combined proof {proof_label}). "
            "Not full regression."
        )
    elif prior_id:
        proof_label = (prior_reuse_summary or {}).get("proof_sha256") or "unverified"
        summary_line = (
            f"Selected: {selected_decl} declarations ({planned_exec_total} planned executions): "
            f"fresh this run {fresh_decl_total} declarations ({fresh_exec_total} executions); "
            f"reused from run {prior_id} (source {PRIOR_SOURCE_COMMIT}, artifact {PRIOR_ARTIFACT_ID}, "
            f"proof {proof_label}) {reused_decl_total} declarations ({reused_exec_total} executions). "
            "Not full regression."
        )
    else:
        summary_line = f"Selected: {selected_decl} declarations ({planned_exec_total} planned executions). Not full regression."

    lines = [
        f"## EPUB author layout targeted validation ({SCOPE})",
        "",
        summary_line,
        "",
        "| Group | Origin | Case | Status | Raw Event | Reason |",
        "|---|---|---|---|---|---|",
    ]
    for row in case_rows:
        origin = f"reused:{row['run_id']}" if row["execution_origin"] == "reused_prior" else "fresh"
        lines.append(
            f"| {cell(row['group'])} | {cell(origin)} | {cell(row['case'])} | {cell(row['status'])} | "
            f"{cell(row['raw_event_status'])} | {cell(row['reason'])} |"
        )
    if inventory_targets:
        lines += ["", "### Full inventory targets (omitted targets are NOT RUN)", "",
                  "| Target | Declared | Selected | Omitted | Status |", "|---|---|---|---|---|"]
        for item in inventory_targets:
            lines.append(
                f"| {cell(item['target'])} | {item['declared']} | {item['selected']} | "
                f"{item['omitted']} | {cell(item['status'])} |"
            )
    if scheduling:
        lines += ["", "Scheduling/shared error: " + cell(scheduling["error"])]
    markdown = "\n".join(lines) + "\n"

    OUT.mkdir(parents=True, exist_ok=True)
    _out_path(REPORT_JSON, "case-results.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    _out_path(REPORT_MD, "case-results.md").write_text(markdown, encoding="utf-8")
    if publish and os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as stream:
            stream.write(markdown)
    return report

def validate_linkage(kind, scope):
    folder = OUT / f"webkit-{kind}-linkage"
    record = load(folder / "verification.json")
    require(
        all(record.get(key) == scope[key] for key in ("source_commit", "run_id", "run_attempt"))
        and record.get("passed") is True
        and not record.get("errors")
        and isinstance(record.get("binaries"), list)
        and bool(record["binaries"]),
        f"Missing same-run successful {kind} WebKit linkage",
    )
    app = v.APP if kind == "device" else ROOT / "build/ReadingUIDerivedData/Build/Products/Debug-iphonesimulator/YueJing.app"
    app_resolved = app.resolve()
    folder_resolved = folder.resolve()
    for binary in record["binaries"]:
        path = app / binary["path"]
        evidence = folder / binary["evidence"]
        require(
            path.is_file()
            and not path.is_symlink()
            and evidence.is_file()
            and not evidence.is_symlink()
            and path.resolve().is_relative_to(app_resolved)
            and evidence.resolve().is_relative_to(folder_resolved)
            and binary.get("passed") is True
            and binary.get("nm_exit") == 0
            and sha(path) == sha(evidence) == binary["sha256"],
            "WebKit binary evidence drift",
        )
    return sha(folder / "verification.json")


def qualification():
    scope = live_scope()
    require(
        scope["scope"] == SCOPE
        and scope["allow_unqualified_ipa"] is False
        and (scope["prior_validation_run"] == "" or scope["prior_validation_run"] in AUTHORIZED_PRIOR_RUNS),
        "Scope/diagnostic/reuse invariant violation",
    )
    require(not any((OUT / name).exists() or (OUT / name).is_symlink() for name in MIXED_QUALIFICATION_FILES),
            "Mixed qualification receipts forbidden")
    packages = compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=False)

    sched = OUT / "case-scheduling-error.json"
    require(not sched.exists() and not sched.is_symlink(), "Scheduling error prevents qualification")
    native_out = _out_path(NATIVE_OUT, "epub-author-layout")
    require(native_out.is_dir() and not native_out.is_symlink(), "Missing native evidence directory")

    config = load_scope_config()
    groups = build_groups(config)
    fresh_ids, reused_ids = partition_groups(groups, scope["prior_validation_run"])
    require(
        fresh_ids == scope["fresh_groups"] and reused_ids == scope["reused_groups"],
        "Scope fresh/reused group partition drift",
    )
    require({p.name for p in native_out.iterdir()} == set(fresh_ids), "Missing/extra fresh native group folders")
    require(not any((native_out / g / "failure.json").exists() or (native_out / g / "failure.json").is_symlink() for g in fresh_ids),
            "Failed/blocked/skipped cases cannot qualify")

    sim = load(OUT / "simulator-selection.json")
    destination = "platform=iOS Simulator,id=" + str(sim.get("udid", ""))
    compat.validate_destination(destination, OUT)
    boot = load(OUT / "simulator-boot.json")
    require(
        all(boot.get(k) == scope[k] for k in ("source_commit", "run_id", "run_attempt"))
        and type(boot.get("exit_code")) is int
        and boot["exit_code"] == 0
        and boot.get("timed_out") is False
        and boot.get("timeout_seconds", BOOT_TIMEOUT_SECONDS) == BOOT_TIMEOUT_SECONDS,
        "Missing same-run successful simulator boot",
    )
    sim_linkage_sha = (p2_verify_saved(scope, packages=packages)["prior"]["simulator_linkage_sha256"]
                       if scope["prior_validation_run"] == P2_RUN_ID else validate_linkage("simulator", scope))

    fresh_parsed_groups = []
    for group in fresh_ids:
        spec = groups[group]
        folder = native_out / group
        require(folder.is_dir() and not folder.is_symlink(), "Invalid group directory: " + group)
        bundle = folder / f"{spec['target']}.xcresult"
        live_tests = verify_group_xcresult(spec, bundle, exported_folder=None)
        saved_tests = verify_group_xcresult(spec, bundle, exported_folder=folder)
        require(live_tests == saved_tests, "Live xcresult tests differ from saved export: " + group)
        live_summary = json.loads(xcresult_export(bundle, "summary"))
        saved_summary = load(folder / "xcresult-summary.json")
        require(live_summary == saved_summary, "Live xcresult summary differs from saved export: " + group)

        want = provenance(group, destination, bundle, scope, groups=groups)
        require(load(folder / "selection.json") == want, "Selection receipt mismatch: " + group)
        execution = load(folder / "execution.json")
        require(execution == {**want, "native_exit": 0, "timed_out": False}, "Execution/provenance mismatch: " + group)
        reading.validate_group_settings(spec["kind"], folder, scope["source_commit"], root=ROOT, out=OUT)

        log_path = folder / f"{spec['target']}.log"
        require(log_path.is_file() and not log_path.is_symlink(), "Missing regular native log: " + group)
        parsed = parse_log(group, log_path.read_bytes(), execution["native_exit"], execution["timed_out"], groups=groups)
        parsed["parameter_xcresult"] = parameter_evidence(group, folder, bundle, group_specs=groups)
        require(json.dumps(load(folder / "counts.json"), sort_keys=True) == json.dumps(parsed, sort_keys=True),
                "Raw events differ from saved counts: " + group)
        fresh_parsed_groups.append(parsed)

    fresh_passed = [n for g in fresh_parsed_groups for n in g["passed"]]
    expected_fresh = [n for g in fresh_ids for n in groups[g]["cases"]]
    require(
        len(fresh_passed) == len(set(fresh_passed)) == len(expected_fresh) == scope["fresh_declarations_planned"]
        and set(fresh_passed) == set(expected_fresh),
        "Fresh passed declaration identities differ",
    )
    fresh_exec = sum(g["executions"] for g in fresh_parsed_groups)
    require(fresh_exec == scope["fresh_executions_planned"], "Fresh execution count differs")

    if scope["prior_validation_run"]:
        eff_doc = load(OUT / "effective-test-settings.json")
        current_eff_domain = eff_doc.get("ReaderDomainTests")
        compat._validate_domain_effective_settings(current_eff_domain)
        current_eff_host = None
        if scope["prior_validation_run"] == PRIOR2_RUN_ID:
            host3_settings_path = native_out / "host-3/YueJingHostTests-settings.json"
            require(
                host3_settings_path.is_file() and not host3_settings_path.is_symlink(),
                "Missing fresh host-3 YueJingHostTests-settings.json",
            )
            current_eff_host = load(host3_settings_path)
        reused_gate = verify_prior_reuse_saved(
            scope,
            packages,
            current_effective_domain=current_eff_domain,
            current_effective_host=current_eff_host,
            root=ROOT,
        )
        prior_summary = reused_gate["prior"]
        reused_passed = [n for g in prior_summary["groups"] for n in g["passed"]]
        reused_exec = prior_summary["executions_passed"]
        reused_decl = prior_summary["declarations_passed"]
        reused_gate_sha = sha(_reused_gate_json())
        proof_sha = reused_gate["proof_sha256"]
        expected_reused_decl = (
            PRIOR_REUSED_DECLARATIONS
            if scope["prior_validation_run"] == PRIOR_RUN_ID
            else COMBINED_PRIOR2_REUSED_DECLARATIONS
        )
        expected_reused_exec = (
            PRIOR_REUSED_EXECUTIONS
            if scope["prior_validation_run"] == PRIOR_RUN_ID
            else COMBINED_PRIOR2_REUSED_EXECUTIONS
        )
        if scope["prior_validation_run"] == P2_RUN_ID:
            expected_reused_decl, expected_reused_exec = 83, 84
        require(
            reused_decl == expected_reused_decl == scope["reused_declarations_planned"]
            and reused_exec == expected_reused_exec == scope["reused_executions_planned"],
            "Reused prior declaration/execution count mismatch",
        )
        qual_prior_origins = reused_gate.get("prior_origins", [prior_summary])
    else:
        reused_out = _reused_out()
        require(not reused_out.exists() and not reused_out.is_symlink(),
                "Unexpected reused-evidence directory without prior_validation_run")
        prior_summary = None
        reused_passed = []
        reused_exec = 0
        reused_decl = 0
        reused_gate_sha = None
        proof_sha = None
        qual_prior_origins = []

    require(not (set(fresh_passed) & set(reused_passed)), "Fresh and reused declaration sets overlap")
    all_passed = fresh_passed + reused_passed
    expected_all = [n for spec in groups.values() for n in spec["cases"]]
    require(
        len(all_passed) == len(set(all_passed)) == len(expected_all) == scope["selected_declarations"]
        and set(all_passed) == set(expected_all),
        "Combined passed declaration identities differ",
    )
    total_exec = fresh_exec + reused_exec
    require(total_exec == scope["native_tests_planned"], "Combined execution count differs")
    require(live_scope() == scope, "Source/run changed during qualification")

    return {
        **scope,
        "qualification": QUALIFICATION,
        "coverage": COVERAGE,
        "passed": True,
        "native_tests_executed_this_run": fresh_exec,
        "fresh_declarations_passed": len(fresh_passed),
        "reused_native_passed": reused_exec,
        "reused_declarations": reused_decl,
        "verified_passed": total_exec,
        "verified_declarations": len(expected_all),
        "failed": 0,
        "skipped": 0,
        "unexecuted": 0,
        "unfinished": 0,
        "ambiguous": 0,
        "not_executed_this_run": scope["full_inventory_executions"] - fresh_exec,
        "unselected_executions": scope["full_inventory_executions"] - total_exec,
        "groups": fresh_parsed_groups,
        "prior_reuse_proof_sha256": proof_sha,
        "reused_evidence_gate_sha256": reused_gate_sha,
        "reused_prior": prior_summary,
        "prior_origins": qual_prior_origins,
        "simulator": sim,
        "simulator_boot_sha256": sha(OUT / "simulator-boot.json"),
        "simulator_linkage_sha256": sim_linkage_sha,
        "packages": packages,
        "scope_receipt_sha256": sha(_out_path(SCOPE_JSON, "author-layout-scope.json")),
        "candidate_sources_sha256": sha(_out_path(CANDIDATE_SOURCES_JSON, "candidate-sources.json")),
        "dependency_resolution_sha256": sha(OUT / "dependency-resolution.json"),
    }


def validate_saved():
    actual = qualification()
    saved = load(_out_path(GATE_JSON, "author-layout-gate.json"))
    require(json.dumps(saved, sort_keys=True) == json.dumps(actual, sort_keys=True), "Qualification receipt drift")
    return actual


def delivery_gate():
    scope = live_scope()
    require(scope.get("allow_unqualified_ipa") is False, "Diagnostic IPA permission disabled")
    require(
        scope.get("build_ipa") is True
        and (scope.get("prior_validation_run") == "" or scope.get("prior_validation_run") in AUTHORIZED_PRIOR_RUNS),
        "Delivery requires build_ipa=true and either initial full-targeted or pinned prior reuse qualification",
    )
    packages = compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=False)
    qual = validate_saved()
    require(
        qual.get("scope") == SCOPE
        and qual.get("version") == VERSION
        and qual.get("build") == BUILD
        and qual.get("passed") is True
        and qual.get("allow_unqualified_ipa") is False
        and qual.get("build_ipa") is True
        and qual.get("prior_validation_run") == scope["prior_validation_run"]
        and qual.get("full_regression_passed") is False
        and qual.get("native_tests_executed_this_run") == scope["fresh_executions_planned"] > 0
        and qual.get("fresh_declarations_passed") == scope["fresh_declarations_planned"] > 0
        and qual.get("reused_native_passed") == scope["reused_executions_planned"]
        and qual.get("reused_declarations") == scope["reused_declarations_planned"]
        and qual.get("verified_passed") == scope["native_tests_planned"] > 0
        and qual.get("verified_declarations") == scope["selected_declarations"] > 0,
        "Strict qualification mismatch",
    )
    if scope["prior_validation_run"]:
        prior_spec = _prior_spec(scope["prior_validation_run"])
        require(
            qual.get("prior_source_commit") == prior_spec["source_commit"]
            and qual.get("prior_artifact_id") == prior_spec["artifact_id"]
            and qual.get("prior_artifact_sha256") == prior_spec["archive_sha256"]
            and isinstance(qual.get("prior_reuse_proof_sha256"), str)
            and bool(re.fullmatch(r"[0-9a-f]{64}", qual["prior_reuse_proof_sha256"]))
            and isinstance(qual.get("reused_prior"), dict)
            and qual["reused_prior"].get("proof_sha256") == qual["prior_reuse_proof_sha256"],
            "Prior reuse proof digest mismatch in delivery gate",
        )

    build_exit = OUT / "app-build-exit-code.txt"
    require(build_exit.is_file() and not build_exit.is_symlink()
            and build_exit.read_text(encoding="utf-8").strip() == "0",
            "Device App build did not pass")
    device_linkage = validate_linkage("device", scope)
    require(live_scope() == scope, "Source/run changed during delivery gate")

    report = summarize()
    if scope["prior_validation_run"]:
        require(
            (report.get("prior_reuse") or {}).get("status") == "passed"
            and report.get("reused_native_passed") == scope["reused_executions_planned"]
            and report.get("reused_declarations") == scope["reused_declarations_planned"]
            and report.get("verified_passed") == scope["native_tests_planned"],
            "Summary prior reuse verification failed during delivery gate",
        )
    evidence = {}
    for name in (
        "toolchain.log",
        "xcodegen.log",
        "dependency-resolution.json",
        "app-build.log",
        "app-build-exit-code.txt",
        "simulator-selection.json",
        "simulator-boot.json",
    ):
        path = OUT / name
        require(path.is_file() and not path.is_symlink(), "Missing common evidence: " + name)
        evidence[name] = sha(path)
    for attr, rel in (
        (SCOPE_JSON, "author-layout-scope.json"),
        (CANDIDATE_SOURCES_JSON, "candidate-sources.json"),
        (DISPATCH_EVENT_JSON, "dispatch-event.json"),
        (GATE_JSON, "author-layout-gate.json"),
        (REPORT_JSON, "case-results.json"),
    ):
        path = _out_path(attr, rel)
        require(path.is_file() and not path.is_symlink(), "Missing required receipt: " + rel)
        evidence[rel] = sha(path)
    if scope["prior_validation_run"]:
        reused_out = _reused_out()
        gate_path = _reused_gate_json()
        require(gate_path.is_file() and not gate_path.is_symlink(), "Missing reused prior gate")
        evidence["reused-evidence/reused-prior-gate.json"] = sha(gate_path)
        for oid in _prior_origin_ids(scope["prior_validation_run"]):
            prior_dir = reused_out / f"prior-{oid}"
            for fname in ("api-run.json", "api-artifact.json", "archive-receipt.json", "archive.zip"):
                rel = f"reused-evidence/prior-{oid}/{fname}"
                path = prior_dir / fname
                require(path.is_file() and not path.is_symlink(), "Missing reused prior evidence: " + rel)
                evidence[rel] = sha(path)

    require(live_scope() == scope, "Source/run changed while collecting package evidence")
    return {
        **scope,
        "qualification": qual["qualification"],
        "coverage": qual["coverage"],
        "strict_native_qualification": "passed",
        "native_tests_executed_this_run": qual["native_tests_executed_this_run"],
        "fresh_declarations_passed": qual["fresh_declarations_passed"],
        "reused_native_passed": qual["reused_native_passed"],
        "reused_declarations": qual["reused_declarations"],
        "verified_passed": qual["verified_passed"],
        "verified_declarations": qual["verified_declarations"],
        "not_executed_this_run": qual["not_executed_this_run"],
        "unselected_executions": qual["unselected_executions"],
        "prior_reuse_proof_sha256": qual["prior_reuse_proof_sha256"],
        "reused_evidence_gate_sha256": qual["reused_evidence_gate_sha256"],
        "reused_prior": qual["reused_prior"],
        "prior_origins": qual["prior_origins"],
        "simulator": qual["simulator"],
        "simulator_linkage_sha256": qual["simulator_linkage_sha256"],
        "device_linkage_sha256": device_linkage,
        "packages": packages,
        "groups": qual["groups"],
        "case_results_qualification": report["qualification"],
        "evidence_sha256": evidence,
    }


def complete_delivery(manifest, packaged_files):
    """Called ONLY after device dependency and IPA byte verification succeed."""
    result = delivery_gate()
    require(isinstance(manifest, dict), "Invalid manifest")
    require(type(packaged_files) is int and packaged_files > 0, "Invalid packaged file count")
    require(
        manifest.get("source_commit") == result["source_commit"]
        and manifest.get("version") == VERSION
        and manifest.get("build") == BUILD
        and manifest.get("signing") == "unsigned"
        and isinstance(manifest.get("ipa_sha256"), str)
        and bool(re.fullmatch(r"[0-9a-f]{64}", manifest["ipa_sha256"])),
        "IPA/source/version differs from delivery scope",
    )
    dependency = load(OUT / "app-dependency-gate.json")
    require(
        all(dependency.get(k) == result[k] for k in ("source_commit", "run_id", "run_attempt"))
        and dependency.get("signing") == "unsigned"
        and dependency.get("packages") == result["packages"],
        "Device dependency receipt identity or packages differ",
    )
    images = dependency.get("actual_images")
    require(isinstance(images, list) and bool(images), "Missing device image evidence")
    app_resolved = v.APP.resolve()
    for image in images:
        path = v.APP / image["binary"]
        require(
            path.is_file()
            and not path.is_symlink()
            and path.resolve().is_relative_to(app_resolved)
            and sha(path) == image["sha256"],
            "Device image drift",
        )
    result.update(
        ipa_integrity="passed",
        ipa_sha256=manifest["ipa_sha256"],
        verified_packaged_files=packaged_files,
        device_dependency_sha256=sha(OUT / "app-dependency-gate.json"),
    )
    write(_out_path(PACKAGE_JSON, "author-layout-package.json"), result)
    return result


def p2_inspect(scope, *, root=ROOT, packages=None, verify_native=True):
    """Requalify only the pinned first P2 run's wholly passing, unchanged groups."""
    require(verify_native or os.environ.get("GITHUB_ACTIONS") != "true", "Cloud must parse original xcresults")
    require(scope["prior_validation_run"] == P2_RUN_ID, "Wrong P2 origin")
    current = verify_source(pending=os.environ.get("GITHUB_ACTIONS") != "true", root=root,
                            prior_validation_run=P2_RUN_ID)
    require(current["source_commit"] == scope["source_commit"], "Current P2 source mismatch")
    folder = _reused_out() / f"prior-{P2_RUN_ID}"
    _, _, archive = _verify_archive_receipt(folder, prior_id=P2_RUN_ID, current_run_id=scope["run_id"])
    ev = folder / "evidence"
    prior_scope = load(ev / "author-layout-scope.json")
    require(prior_scope["source_commit"] == P2_SOURCE and prior_scope["run_id"] == P2_RUN_ID
            and prior_scope["run_attempt"] == "1" and prior_scope["prior_validation_run"] == ""
            and prior_scope["scope"] == SCOPE and prior_scope["baseline_commit"] == BASE
            and prior_scope["selected_declarations"] == 98 and prior_scope["native_tests_planned"] == 99,
            "Pinned P2 scope identity mismatch")
    require(prior_scope["selected_files"] == current["selected_summary"]["selected_files"], "P2 selected identities changed")
    prior_files, current_files = prior_scope["files"], current["candidate_files"]
    require(set(prior_files) == set(current_files), "P2 candidate inventory drift")
    require({p for p in current_files if current_files[p] != prior_files[p]} <= P2_ALLOWED_DIFF,
            "P2 production/build/reused-test fingerprints changed")
    _verify_prior_toolchain_and_deps(ev, packages, expected_source_commit=P2_SOURCE)
    sim, linkage = _verify_prior_simulator_and_linkage(ev, archive["members"],
        expected_source_commit=P2_SOURCE, expected_run_id=P2_RUN_ID)
    current_eff, _ = _load_current_effective_settings()
    groups = build_groups(load_scope_config())
    _, reused = partition_groups(groups, P2_RUN_ID)
    parsed = [_verify_reused_prior2_group(g, groups[g], ev, archive["members"],
        "platform=iOS Simulator,id=" + sim["udid"], verify_native=verify_native,
        current_effective_domain=current_eff, expected_source_commit=P2_SOURCE,
        expected_run_id=P2_RUN_ID, eligible_groups=P2_REUSED, changed_test_pins=P2_CHANGED_TESTS)
        for g in reused]
    require(sum(g["declarations_passed"] for g in parsed) == 83
            and sum(g["executions"] for g in parsed) == 84, "P2 reused execution totals drift")
    result = dict(run_id=P2_RUN_ID, source_commit=P2_SOURCE, artifact_id=P2_ARTIFACT_ID,
        archive_sha256=P2_ARTIFACT_SHA, passed=True, qualified=verify_native, errors=[],
        declarations_passed=83, executions_passed=84, groups=parsed,
        simulator_linkage_sha256=linkage, simulator=sim,
        native_bundle_parse="passed" if verify_native else "OFFLINE_SAVED_EXPORTS_ONLY")
    # Proof is stable across offline export replay and actual native bundle verification;
    # qualified/native_bundle_parse remain separate mandatory cloud qualifications.
    result["proof_sha256"] = digest_bytes(json.dumps({k: v for k, v in result.items()
        if k not in {"qualified", "native_bundle_parse"}}, sort_keys=True).encode())
    return result


def p2_receipt(scope, prior):
    return dict(scope=SCOPE, phase="validation", source_commit=scope["source_commit"],
        run_id=scope["run_id"], run_attempt="1", prior_validation_run=P2_RUN_ID,
        prior_source_commit=P2_SOURCE, prior_artifact_id=P2_ARTIFACT_ID,
        prior_artifact_sha256=P2_ARTIFACT_SHA, provenance_valid=True,
        passed=prior["passed"], qualified=prior["qualified"], reused_declarations=83,
        reused_executions=84, reused_native_passed=84, proof_sha256=prior["proof_sha256"],
        errors=[], prior=prior, prior_origins=[prior])


def p2_reuse(scope, *, root=ROOT):
    packages = compat.validate_toolchain_and_dependencies(root, OUT, check_live_tools=False)
    dest = _reused_out()
    require(not dest.exists(), "Existing P2 evidence; no overwrite/retry")
    dest.mkdir(parents=True)
    _retain_prior_archive(P2_RUN_ID, scope, dest)
    prior = p2_inspect(scope, root=root, packages=packages)
    receipt = p2_receipt(scope, prior)
    write(_reused_gate_json(), receipt)
    return receipt


def p2_verify_saved(scope, *, root=ROOT, packages=None, verify_native=None):
    if verify_native is None:
        verify_native = sys.platform == "darwin" or os.environ.get("GITHUB_ACTIONS") == "true"
    require({p.name for p in _reused_out().iterdir()} ==
            {f"prior-{P2_RUN_ID}", _reused_gate_json().name}, "P2 retained evidence closure drift")
    prior = p2_inspect(scope, root=root, packages=packages, verify_native=verify_native)
    saved = load(_reused_gate_json())
    require(saved.get("qualified") is True and saved.get("prior", {}).get("native_bundle_parse") == "passed",
            "Missing real cloud xcresult qualification")
    if not verify_native:
        # Compare against the cloud receipt without claiming a Windows xcresult execution.
        prior = {**prior, "qualified": True, "native_bundle_parse": "passed"}
    expected = p2_receipt(scope, prior)
    require(saved == expected, "P2 saved qualification drift")
    return expected


def p2_summary(scope):
    result = dict(status="not_verified", run_id=P2_RUN_ID, source_commit=P2_SOURCE,
        artifact_id=P2_ARTIFACT_ID, archive_sha256=P2_ARTIFACT_SHA, proof_sha256=None,
        declarations_passed=None, executions_passed=None, verified_groups=[], origins=[], error=None)
    try:
        require(scope is not None, "Missing current scope")
        verified = p2_verify_saved(scope)
        prior = verified["prior"]
        result.update(status="passed", proof_sha256=prior["proof_sha256"], declarations_passed=83,
                      executions_passed=84, verified_groups=[g["group"] for g in prior["groups"]])
        result["origins"] = [{k: v for k, v in result.items() if k != "origins"}]
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        result.update(status="failed" if _reused_gate_json().exists() else "not_verified", error=str(error))
    return result


def local_check(*, pending=False, root=ROOT, prior_validation_run=""):
    receipt = verify_source(pending=pending, root=root, prior_validation_run=prior_validation_run)
    return {
        "kind": "LOCAL_SOURCE_CHECK_NOT_NATIVE",
        "native_executions": 0,
        "physical_acceptance": "not performed",
        **receipt,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("scope", help="Verify committed scope/dispatch and write exclusive scope receipts")
    sub.add_parser("p2-linkage", help="Verify explicitly reused P2 simulator linkage, not a new simulator App")
    reuse_cmd = sub.add_parser("reuse", help="Download, verify, and retain immutable prior validation evidence")
    reuse_cmd.add_argument("--prior-zip", type=Path)
    reuse_cmd.add_argument("--prior-run-json", type=Path)
    reuse_cmd.add_argument("--prior-artifact-json", type=Path)
    reuse_cmd.add_argument("--prior2-zip", type=Path)
    reuse_cmd.add_argument("--prior2-run-json", type=Path)
    reuse_cmd.add_argument("--prior2-artifact-json", type=Path)
    reuse_cmd.add_argument("--skip-dependency-check", action="store_true")
    run_all_cmd = sub.add_parser("run-all", help="Execute all fresh selected groups independently without retries")
    run_all_cmd.add_argument("--destination", required=True)
    sub.add_parser("report", help="Update diagnostic case-results.json/md from available raw logs and receipts")
    sub.add_parser("gate", help="Strictly revalidate native/xcresult/linkage/boot receipts and write gate")
    lc_cmd = sub.add_parser("local-check", help="Offline local source/inventory/scope check")
    lc_cmd.add_argument("--pending", action="store_true", help="Allow uncommitted approved edits and protected unrelated files")
    lc_cmd.add_argument("--prior-validation-run", default="", help="Optional pinned prior run ID for compatibility check")

    args = parser.parse_args(argv)
    if args.action == "scope":
        receipt = write_scope(ROOT)
        print(json.dumps(receipt, indent=2))
    elif args.action == "p2-linkage":
        scope = live_scope()
        proof = p2_verify_saved(scope)
        write(OUT / "reused-simulator-linkage.json", dict(source_commit=scope["source_commit"],
            run_id=scope["run_id"], origin_run=P2_RUN_ID, origin_source=P2_SOURCE,
            evidence_sha256=proof["prior"]["simulator_linkage_sha256"],
            qualification="REUSED_UNCHANGED_APP_NOT_NEW_SIMULATOR_BUILD"))
    elif args.action == "reuse":
        offline_prior = None
        has_p1 = any((args.prior_zip, args.prior_run_json, args.prior_artifact_json))
        has_p2 = any((args.prior2_zip, args.prior2_run_json, args.prior2_artifact_json))
        if has_p1 or has_p2:
            require(
                args.prior_zip and args.prior_run_json and args.prior_artifact_json,
                "Offline prior replay requires --prior-zip, --prior-run-json, and --prior-artifact-json",
            )
            p1_entry = {
                "zip_path": args.prior_zip,
                "run_json": args.prior_run_json,
                "artifact_json": args.prior_artifact_json,
            }
            if has_p2:
                require(
                    args.prior2_zip and args.prior2_run_json and args.prior2_artifact_json,
                    "Dual offline replay requires --prior2-zip, --prior2-run-json, and --prior2-artifact-json",
                )
                offline_prior = {
                    PRIOR_RUN_ID: p1_entry,
                    PRIOR2_RUN_ID: {
                        "zip_path": args.prior2_zip,
                        "run_json": args.prior2_run_json,
                        "artifact_json": args.prior2_artifact_json,
                    },
                }
            else:
                offline_prior = p1_entry
        receipt = reuse_evidence(
            require_dependencies=not args.skip_dependency_check,
            offline_prior=offline_prior,
            root=ROOT,
        )
        print(json.dumps(receipt, indent=2))
    elif args.action == "run-all":
        require(run_all(args.destination), "Selected tests failed; remaining cases attempted, see case-results.json")
    elif args.action == "report":
        summarize(publish=True)
    elif args.action == "gate":
        result = qualification()
        write(_out_path(GATE_JSON, "author-layout-gate.json"), result)
        print(json.dumps(result, indent=2))
    else:
        print(json.dumps(local_check(pending=args.pending, root=ROOT, prior_validation_run=args.prior_validation_run), indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        raise SystemExit("EPUB author-layout validation stopped: " + str(error))

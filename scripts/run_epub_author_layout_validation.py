"""Strict EPUB author-layout validation runner and qualification/delivery gates."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import signal
import subprocess
import sys

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import audit_native_case_events as audit
import package_ipa
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
OUT = v.OUT
_DEFAULT_OUT = OUT
SCOPE_CONFIG_JSON = SCRIPT_DIR / "epub_author_layout_scope.json"

SCOPE = "epub-author-layout"
BASE = "cb749e62b4b468d7077cceaaba7bcd626294a269"
VERSION, BUILD = "0.2.16", "18"
REPO = "wan780839395-cyber/YueJing"
WORKFLOW_ID = 398234793
WORKFLOW_PATH = ".github/workflows/task3-validate.yml"

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


def load_scope_config(path=None):
    cfg_path = Path(path) if path is not None else SCOPE_CONFIG_JSON
    cfg = load(cfg_path)
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
        require(path_str in allowed, "Unapproved working-tree or untracked change: " + path_str)
        working_allowed.add(path_str)

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


def verify_source(*, pending=False, root=ROOT):
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
    return {
        "scope": SCOPE,
        "baseline_commit": BASE,
        "version": VERSION,
        "build": BUILD,
        **source,
        "selected_summary": selected_summary,
        "candidate_sha256": dict(config["candidate_sha256"]),
        "scope_config_sha256": sha(cfg_path),
    }


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
    require(isinstance(prior, str) and prior == "", "prior_validation_run must be empty (no initial reuse)")
    require(env.get("PRIOR_VALIDATION_RUN", "") == "", "PRIOR_VALIDATION_RUN must be empty")

    raw_build = inputs.get("build_ipa", False)
    require(type(raw_build) is bool or raw_build in ("true", "false"), "Invalid build_ipa input")
    build_ipa = raw_build is True or raw_build == "true"
    require(env.get("BUILD_IPA") == ("true" if build_ipa else "false"), "BUILD_IPA differs from dispatch")

    return {
        "allow_unqualified_ipa": False,
        "prior_validation_run": "",
        "build_ipa": build_ipa,
        "dispatch_event_sha256": sha(event_path),
    }


def scope_receipt(root=ROOT):
    root = Path(root)
    source = verify_source(pending=False, root=root)
    dispatch = dispatch_context()
    head = source["source_commit"]
    require(head == os.environ.get("GITHUB_SHA"), "HEAD differs from GITHUB_SHA")

    config = load_scope_config(SCOPE_CONFIG_JSON if root == ROOT else root / "scripts/epub_author_layout_scope.json")
    groups = build_groups(config)
    reviewed = inventory.validate_source(root)
    selected_summary = source["selected_summary"]

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

    return {
        "scope": SCOPE,
        "phase": "validation",
        "prior_validation_run": "",
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
        "selected_declarations": selected_summary["selected_declarations"],
        "native_tests_planned": selected_summary["planned_executions"],
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


def parameter_evidence(group, folder, bundle, *, export=False, group_specs=None):
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
    if not export:
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
        if node.get("nodeType") in ("Test Case", "Arguments"):
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


def run_group(group, destination, *, checked_scope=None, groups=None):
    scope = checked_scope if checked_scope is not None else live_scope()
    active_groups = groups if groups is not None else build_groups(load_scope_config())
    require(group in active_groups, "Unknown group: " + str(group))
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
    """Execute independent groups, isolate shared compile blocks per kind, and never retry."""
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
        compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=True)
        compat.validate_destination(destination, OUT)
        groups = build_groups(load_scope_config())
        native_out.mkdir()
        summarize()
        blocked = {}
        for group, spec in groups.items():
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
        return all(row["status"] == "passed" for row in result["cases"])
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

    case_rows = []
    group_rows = []
    for group, spec in groups.items():
        folder = native_out / group
        target = spec["target"]
        cases = list(spec["cases"])
        planned_exec = sum(len(inventory.PARAMETERIZED.get(c, {}).get("values", [None])) for c in cases)
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
                # Failed, timed out, or blocked execution: report each case from raw events honestly.
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

    status_keys = ("passed", "failed", "skipped", "timed_out", "unfinished", "ambiguous", "unexecuted", "blocked", "error", "not_run")
    counts = {k: sum(r["status"] == k for r in case_rows) for k in status_keys}
    selected_set = {r["case"] for r in case_rows}
    selected_decl = len(case_rows)
    planned_exec_total = sum(r["planned_executions"] for r in case_rows)
    all_passed = counts["passed"] == selected_decl and selected_decl > 0

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

    report = {
        "scope": SCOPE,
        "phase": "validation",
        "source_commit": (scope or {}).get("source_commit") or os.environ.get("GITHUB_SHA"),
        "run_id": (scope or {}).get("run_id") or os.environ.get("GITHUB_RUN_ID"),
        "selected_declarations": selected_decl,
        "planned_executions": planned_exec_total,
        "native_tests_executed_this_run": planned_exec_total if all_passed else None,
        "verified_passed": planned_exec_total if all_passed else None,
        "counts": counts,
        "groups": group_rows,
        "cases": case_rows,
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

    lines = [
        f"## EPUB author layout targeted validation ({SCOPE})",
        "",
        f"Selected: {selected_decl} declarations ({planned_exec_total} planned executions). Not full regression.",
        "",
        "| Group | Case | Status | Raw Event | Reason |",
        "|---|---|---|---|---|",
    ]
    for row in case_rows:
        lines.append(
            f"| {cell(row['group'])} | {cell(row['case'])} | {cell(row['status'])} | "
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
    require(scope["scope"] == SCOPE and scope["allow_unqualified_ipa"] is False and scope["prior_validation_run"] == "",
            "Scope/diagnostic/reuse invariant violation")
    require(not any((OUT / name).exists() or (OUT / name).is_symlink() for name in MIXED_QUALIFICATION_FILES),
            "Mixed qualification receipts forbidden")
    packages = compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=False)

    sched = OUT / "case-scheduling-error.json"
    require(not sched.exists() and not sched.is_symlink(), "Scheduling error prevents qualification")
    native_out = _out_path(NATIVE_OUT, "epub-author-layout")
    require(native_out.is_dir() and not native_out.is_symlink(), "Missing native evidence directory")

    config = load_scope_config()
    groups = build_groups(config)
    require({p.name for p in native_out.iterdir()} == set(groups), "Missing/extra native group folders")
    require(not any((native_out / g / "failure.json").exists() or (native_out / g / "failure.json").is_symlink() for g in groups),
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
    sim_linkage_sha = validate_linkage("simulator", scope)

    parsed_groups = []
    for group, spec in groups.items():
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
        parsed_groups.append(parsed)

    all_passed = [n for g in parsed_groups for n in g["passed"]]
    expected_all = [n for spec in groups.values() for n in spec["cases"]]
    require(len(all_passed) == len(set(all_passed)) == len(expected_all) == scope["selected_declarations"]
            and set(all_passed) == set(expected_all), "Combined passed declaration identities differ")
    total_exec = sum(g["executions"] for g in parsed_groups)
    require(total_exec == scope["native_tests_planned"], "Combined execution count differs")
    require(live_scope() == scope, "Source/run changed during qualification")

    return {
        **scope,
        "qualification": QUALIFICATION,
        "coverage": COVERAGE,
        "passed": True,
        "native_tests_executed_this_run": total_exec,
        "verified_passed": total_exec,
        "verified_declarations": len(expected_all),
        "failed": 0,
        "skipped": 0,
        "unexecuted": 0,
        "unfinished": 0,
        "ambiguous": 0,
        "not_executed_this_run": scope["full_inventory_executions"] - total_exec,
        "groups": parsed_groups,
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
    require(scope.get("build_ipa") is True and scope.get("prior_validation_run") == "",
            "Delivery requires build_ipa=true and same-run qualification (no prior reuse)")
    packages = compat.validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=False)
    qual = validate_saved()
    require(
        qual.get("scope") == SCOPE
        and qual.get("version") == VERSION
        and qual.get("build") == BUILD
        and qual.get("passed") is True
        and qual.get("allow_unqualified_ipa") is False
        and qual.get("build_ipa") is True
        and qual.get("prior_validation_run") == ""
        and qual.get("full_regression_passed") is False
        and qual.get("native_tests_executed_this_run") == qual.get("verified_passed") == scope["native_tests_planned"] > 0
        and qual.get("verified_declarations") == scope["selected_declarations"] > 0,
        "Same-run strict qualification mismatch",
    )

    build_exit = OUT / "app-build-exit-code.txt"
    require(build_exit.is_file() and not build_exit.is_symlink()
            and build_exit.read_text(encoding="utf-8").strip() == "0",
            "Device App build did not pass")
    device_linkage = validate_linkage("device", scope)
    require(live_scope() == scope, "Source/run changed during delivery gate")

    report = summarize()
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

    require(live_scope() == scope, "Source/run changed while collecting package evidence")
    return {
        **scope,
        "qualification": qual["qualification"],
        "coverage": qual["coverage"],
        "strict_native_qualification": "passed",
        "native_tests_executed_this_run": qual["native_tests_executed_this_run"],
        "verified_passed": qual["verified_passed"],
        "verified_declarations": qual["verified_declarations"],
        "not_executed_this_run": qual["not_executed_this_run"],
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


def local_check(*, pending=False, root=ROOT):
    receipt = verify_source(pending=pending, root=root)
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
    run_all_cmd = sub.add_parser("run-all", help="Execute all selected groups independently without retries")
    run_all_cmd.add_argument("--destination", required=True)
    sub.add_parser("report", help="Update diagnostic case-results.json/md from available raw logs and receipts")
    sub.add_parser("gate", help="Strictly revalidate native/xcresult/linkage/boot receipts and write gate")
    lc_cmd = sub.add_parser("local-check", help="Offline local source/inventory/scope check")
    lc_cmd.add_argument("--pending", action="store_true", help="Allow uncommitted approved edits and protected unrelated files")

    args = parser.parse_args(argv)
    if args.action == "scope":
        receipt = write_scope(ROOT)
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
        print(json.dumps(local_check(pending=args.pending, root=ROOT), indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        raise SystemExit("EPUB author-layout validation stopped: " + str(error))

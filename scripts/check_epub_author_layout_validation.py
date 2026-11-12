"""Offline synthetic gate/parser/source/scheduler checks for epub-author-layout.

Synthetic fixtures here never execute Swift/Xcode/iOS tests and are NOT native acceptance.
"""
import argparse
import contextlib
import copy
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import traceback
from unittest.mock import patch
import zipfile
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import run_epub_author_layout_validation as r

DESTINATION = "platform=iOS Simulator,id=11111111-2222-3333-4444-555555555555"
SOURCE_SHA = "a" * 40
RUN_ID = "910001"
checks = []


def passed(label):
    checks.append(label)


def rejects(label, action):
    try:
        action()
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError, zipfile.BadZipFile):
        passed(label)
    else:
        raise AssertionError("Expected rejection: " + label)

def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def synthetic_inventory_data():
    files = {
        "ReaderDomainTests/EPUBAuthorStylesTests.swift": "styleCaseOne styleCaseTwo styleCaseThree",
        "ReaderDomainTests/EPUBLibraryTests.swift": "epubBooksStayIsolated epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime",
        "YueJingHostTests/EPUBReaderHostTests.swift": "hostAuthorLayoutOne hostAuthorLayoutTwo",
        "YueJingEPUBUITests/EPUBFlowUITests.swift": "testEPUBAuthorLayoutFlowOne testEPUBAuthorLayoutFlowTwo",
        "TXTCoreTests/TXTChapterTests.swift": "txtChapterOmittedCase",
        "YueJingUITests/ReadingFlowUITests.swift": "testTXTUIOmittedCase",
        "YueJingCanvasTests/ReadingCanvasRenderingTests.swift": "canvasOmittedCase",
        "TXTCorePerformanceTests/TXTLargeFilePerformanceTests.swift": "perfExcludedCase",
    }
    counts = {
        "ReaderDomainTests": 5,
        "YueJingHostTests": 2,
        "YueJingEPUBUITests": 2,
        "TXTCoreTests": 1,
        "YueJingUITests": 1,
        "YueJingCanvasTests": 1,
    }
    parameterized = {
        "epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime": {
            "signature": "(symlink:)",
            "argument": "symlink",
            "values": ["false", "true"],
        }
    }
    excluded = {"TXTCorePerformanceTests": "Independent baseline; excluded."}
    selected_cases = {
        "ReaderDomainTests/EPUBAuthorStylesTests.swift": ["styleCaseOne", "styleCaseTwo", "styleCaseThree"],
        "ReaderDomainTests/EPUBLibraryTests.swift": ["epubBooksStayIsolated", "epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime"],
        "YueJingHostTests/EPUBReaderHostTests.swift": ["hostAuthorLayoutOne", "hostAuthorLayoutTwo"],
        "YueJingEPUBUITests/EPUBFlowUITests.swift": ["testEPUBAuthorLayoutFlowOne", "testEPUBAuthorLayoutFlowTwo"],
    }
    return files, counts, parameterized, excluded, selected_cases


def build_synthetic_repo(repo_root):
    files, _, parameterized, _, selected_cases = synthetic_inventory_data()
    repo_root.mkdir(parents=True, exist_ok=True)
    for rel, names_str in files.items():
        names = names_str.split()
        target = rel.split("/", 1)[0]
        body = []
        if target == "YueJingEPUBUITests":
            body.append("final class EPUBFlowUITests: XCTestCase {")
            for n in names:
                body.append(f"    @MainActor func {n}() {{}}")
            body.append("}")
        elif target == "YueJingUITests":
            body.append("final class ReadingFlowUITests: XCTestCase {")
            for n in names:
                body.append(f"    @MainActor func {n}() {{}}")
            body.append("}")
        else:
            for n in names:
                if n in parameterized:
                    body.append(f"@Test(arguments: [false, true]) func {n}(symlink: Bool) {{}}")
                else:
                    body.append(f"@Test func {n}() {{}}")
        path = repo_root / "Tests" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(body) + "\n", encoding="utf-8")

    product_file = repo_root / "Sources/ReaderDomain/EPUB/AuthorLayout.swift"
    product_file.parent.mkdir(parents=True, exist_ok=True)
    product_file.write_text("public struct AuthorLayoutMarker {}\n", encoding="utf-8")
    proj = repo_root / "project.yml"
    proj.write_text(
        f'name: YueJing\nsettings:\n  base:\n    MARKETING_VERSION: "{r.VERSION}"\n'
        f'    CURRENT_PROJECT_VERSION: "{r.BUILD}"\n    ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\n',
        encoding="utf-8",
    )
    allowed = [
        "project.yml",
        "Sources/ReaderDomain/EPUB/AuthorLayout.swift",
        "Tests/ReaderDomainTests/EPUBAuthorStylesTests.swift",
        "scripts/epub_author_layout_scope.json",
    ]
    pinned = {
        "Sources/ReaderDomain/EPUB/AuthorLayout.swift": r.sha(product_file),
        "Tests/ReaderDomainTests/EPUBAuthorStylesTests.swift": r.sha(repo_root / "Tests/ReaderDomainTests/EPUBAuthorStylesTests.swift"),
    }
    config = {
        "baseline": r.BASE,
        "scope": r.SCOPE,
        "version": r.VERSION,
        "build": r.BUILD,
        "allowed_paths": allowed,
        "candidate_sha256": pinned,
        "selected_files": selected_cases,
    }
    cfg_path = repo_root / "scripts/epub_author_layout_scope.json"
    save(cfg_path, config)
    return config, cfg_path


def make_trees(repo_root):
    all_files = [
        p.relative_to(repo_root).as_posix()
        for p in sorted(repo_root.rglob("*"))
        if p.is_file()
    ]
    current = {rel: ["100644", "blob", r.git_blob_sha1((repo_root / rel).read_bytes())] for rel in all_files}
    previous = dict(current)
    previous["project.yml"] = ["100644", "blob", r.git_blob_sha1(b"old-project")]
    previous["Sources/ReaderDomain/EPUB/AuthorLayout.swift"] = ["100644", "blob", r.git_blob_sha1(b"old-layout")]
    return previous, current


@contextlib.contextmanager
def repo_sandbox(root, *, build_ipa=False):
    repo_root = root / "repo"
    out_root = root / "out"
    config, cfg_path = build_synthetic_repo(repo_root)
    files, counts, parameterized, excluded, _ = synthetic_inventory_data()
    out_root.mkdir(parents=True, exist_ok=True)
    event_path = root / "event.json"
    save(
        event_path,
        {
            "ref": "refs/heads/main",
            "repository": {"full_name": r.REPO},
            "workflow": r.WORKFLOW_PATH,
            "workflow_id": r.WORKFLOW_ID,
            "inputs": {
                "validation_scope": r.SCOPE,
                "allow_unqualified_ipa": False,
                "build_ipa": build_ipa,
                "prior_validation_run": "",
            },
        },
    )
    previous, current = make_trees(repo_root)

    def fake_git(*args, root=None):
        if args[:2] == ("rev-parse", "HEAD"):
            return (SOURCE_SHA + "\n").encode("utf-8")
        if args[0] == "status":
            return b""
        raise AssertionError("Unexpected git call: " + repr(args))

    def fake_tree(rev, root=None):
        return copy.deepcopy(previous if rev == r.BASE else current)

    def fake_validate_source(root=None):
        cases = {}
        for t in (*counts, *excluded):
            cases[t] = [n for p, ns in sorted(files.items()) if p.split("/")[0] == t for n in ns.split()]
        return {
            "kind": "SOURCE_INVENTORY_NOT_NATIVE",
            "groups": dict(counts),
            "selected": sum(counts.values()),
            "execution_groups": {**counts, "ReaderDomainTests": counts["ReaderDomainTests"] + 1},
            "selected_executions": sum(counts.values()) + 1,
            "parameterized": dict(parameterized),
            "excluded": dict(excluded),
            "all_declared": sum(counts.values()) + 1,
            "native_executions": 0,
            "cases": cases,
        }

    real_live_scope = r.live_scope
    with contextlib.ExitStack() as stack:
        stack.enter_context(patch.object(r, "ROOT", repo_root))
        stack.enter_context(patch.object(r, "OUT", out_root))
        stack.enter_context(patch.object(r, "SCOPE_CONFIG_JSON", cfg_path))
        # Default arguments capture the import-time root; keep real checks on the fixture root.
        stack.enter_context(patch.object(r, "live_scope", side_effect=lambda root=repo_root: real_live_scope(root=root)))
        stack.enter_context(patch.object(r.inventory, "FILES", files))
        stack.enter_context(patch.object(r.inventory, "COUNTS", counts))
        stack.enter_context(patch.object(r.inventory, "PARAMETERIZED", parameterized))
        stack.enter_context(patch.object(r.inventory, "EXCLUDED", excluded))
        stack.enter_context(patch.object(r.inventory, "validate_source", side_effect=fake_validate_source))
        stack.enter_context(patch.object(r.compat, "git", side_effect=fake_git))
        stack.enter_context(patch.object(r.compat, "git_tree", side_effect=fake_tree))
        stack.enter_context(patch.object(r, "_git_is_ancestor", return_value=True))
        stack.enter_context(
            patch.dict(
                os.environ,
                GITHUB_ACTIONS="false",
                VALIDATION_SCOPE=r.SCOPE,
                GITHUB_EVENT_NAME="workflow_dispatch",
                GITHUB_REF="refs/heads/main",
                GITHUB_RUN_ATTEMPT="1",
                GITHUB_REPOSITORY=r.REPO,
                GITHUB_WORKFLOW_REF=f"{r.REPO}/{r.WORKFLOW_PATH}@refs/heads/main",
                GITHUB_SHA=SOURCE_SHA,
                GITHUB_RUN_ID=RUN_ID,
                GITHUB_EVENT_PATH=str(event_path),
                ALLOW_UNQUALIFIED_IPA="false",
                PRIOR_VALIDATION_RUN="",
                BUILD_IPA="true" if build_ipa else "false",
            )
        )
        yield repo_root, out_root, config, previous, current, event_path


def fixture_log(spec):
    names = spec["cases"]
    if spec["kind"] == "ui":
        name = names[0]
        return (
            f"Test Case '-[EPUBFlowUITests {name}]' started.\n"
            f"Test Case '-[EPUBFlowUITests {name}]' passed (0.1 seconds).\n"
            "Executed 1 test, with 0 failures (0 unexpected) in 0.1 seconds\n"
            "** TEST SUCCEEDED **\n"
        ).encode("utf-8")
    lines = []
    for name in names:
        param = r.inventory.PARAMETERIZED.get(name)
        sig = name + (param["signature"] if param else "()")
        lines.append(f"◇ Test {sig} started.")
        if param:
            for val in param["values"]:
                lines.append(f"◇ Passing 1 argument {param['argument']} → {val} to {sig}")
        lines.append(f"✔ Test {sig} passed after 0.1 seconds.")
    lines.append(f"✔ Test run with {len(names)} tests passed after 0.2 seconds.")
    lines.append("** TEST SUCCEEDED **")
    return ("\n".join(lines) + "\n").encode("utf-8")


def tree_for(spec):
    nodes = []
    for name in spec["cases"]:
        param = r.inventory.PARAMETERIZED.get(name)
        sig = name + (param["signature"] if param else "()")
        node = {"name": sig, "nodeType": "Test Case", "result": "Passed", "children": []}
        if param:
            node["children"] = [
                {"name": f"{param['argument']}: {val}", "nodeType": "Arguments", "result": "Passed"}
                for val in param["values"]
            ]
        nodes.append(node)
    return {"testNodes": nodes}


def summary_for(spec, *, expanded=False):
    total = (
        sum(len(r.inventory.PARAMETERIZED.get(n, {}).get("values", [None])) for n in spec["cases"])
        if expanded
        else len(spec["cases"])
    )
    return {"totalTestCount": total, "passedTests": total, "failedTests": 0, "skippedTests": 0}


def packages_fixture():
    return {
        name: {
            "package": {
                "identity": name,
                "kind": "remoteSourceControl",
                "location": dep["url"],
                "state": {"revision": dep["revision"], "version": dep["version"]},
            },
            "checkout_revision": dep["revision"],
            "package_manifest_sha256": dep["manifest"],
        }
        for name, dep in r.compat.epub_batch.DEPENDENCIES.items()
    }


def write_common_receipts(out_root, *, boot_exit=0, boot_timeout=False, sim_link_passed=True):
    (out_root / "toolchain.log").write_text(
        f"Source: {SOURCE_SHA}\narm64\nXcode 16.4\nBuild version 16F6\nApple Swift version 6.1.2\n",
        encoding="utf-8",
    )
    (out_root / "xcodegen.log").write_text("Version: 2.46.0\n", encoding="utf-8")
    save(out_root / "dependency-resolution.json", {"packages": packages_fixture()})
    eff = {
        "PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test",
        "SWIFT_VERSION": "6.0",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "IPHONEOS_DEPLOYMENT_TARGET": "16.6",
        "TEST_HOST": "",
        "BUNDLE_LOADER": "",
        "TEST_TARGET_NAME": "",
    }
    save(out_root / "effective-test-settings.json", {"ReaderDomainTests": eff})
    save(
        out_root / "simulator-selection.json",
        {"udid": DESTINATION.split("id=")[1], "device_name": "iPhone SE", "architecture": "arm64", "physical_device": False},
    )
    save(
        out_root / "simulator-boot.json",
        {
            "source_commit": SOURCE_SHA,
            "run_id": RUN_ID,
            "run_attempt": "1",
            "exit_code": boot_exit,
            "timed_out": boot_timeout,
            "timeout_seconds": 120,
        },
    )
    link = out_root / "webkit-simulator-linkage"
    link.mkdir(parents=True, exist_ok=True)
    (link / "binary").write_bytes(b"synthetic-sim-macho")
    save(
        link / "verification.json",
        {
            "source_commit": SOURCE_SHA,
            "run_id": RUN_ID,
            "run_attempt": "1",
            "passed": sim_link_passed,
            "errors": [] if sim_link_passed else ["synthetic linkage failure"],
            "binaries": [
                {
                    "path": "YueJing",
                    "evidence": "binary",
                    "sha256": r.sha(link / "binary"),
                    "passed": sim_link_passed,
                    "nm_exit": 0 if sim_link_passed else 1,
                }
            ],
        },
    )


def write_sim_app_binary(repo_root, out_root):
    sim_app = repo_root / "build/ReadingUIDerivedData/Build/Products/Debug-iphonesimulator/YueJing.app"
    sim_app.mkdir(parents=True, exist_ok=True)
    (sim_app / "YueJing").write_bytes((out_root / "webkit-simulator-linkage/binary").read_bytes())


def write_group_settings(kind, target, folder, eff_path):
    common = {"SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete", "IPHONEOS_DEPLOYMENT_TARGET": "16.6"}
    if kind == "domain":
        values = json.loads(eff_path.read_text(encoding="utf-8"))["ReaderDomainTests"]
        receipt = {
            "source_commit": SOURCE_SHA,
            "target": target,
            "scheme": "ReaderDomain",
            "scheme_sha256": "1" * 64,
            "effective_settings_sha256": r.sha(eff_path),
            "testables": ["ReaderDomainTests"],
            "settings": values,
        }
    else:
        app = {**common, "PRODUCT_TYPE": "com.apple.product-type.application", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"}
        if kind == "host":
            test = {
                **common,
                "PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test",
                "TEST_HOST": "/Debug-iphonesimulator/YueJing.app/YueJing",
                "BUNDLE_LOADER": "/Debug-iphonesimulator/YueJing.app/YueJing",
            }
        else:
            test = {
                **common,
                "PRODUCT_TYPE": "com.apple.product-type.bundle.ui-testing",
                "TEST_TARGET_NAME": "YueJing",
            }
        receipt = {
            "source_commit": SOURCE_SHA,
            "scheme_sha256": "2" * 64,
            "testables": list(r.reading.ui.GROUPS),
            "fixture_environment": "11111111-2222-3333-4444-555555555555",
            "targets": {"YueJing": app, target: test},
        }
    save(folder / f"{target}-settings.json", receipt)


def synthetic_export(bundle, section):
    return (bundle / f"synthetic-{section}.json").read_bytes()


def populate_valid_group(out_root, group, spec, scope):
    folder = out_root / "epub-author-layout" / group
    folder.mkdir(parents=True, exist_ok=True)
    target = spec["target"]
    bundle = folder / f"{target}.xcresult"
    (bundle / "Data").mkdir(parents=True)
    (bundle / "Info.plist").write_bytes(b"synthetic-plist")
    (bundle / "Data/data.0").write_bytes(b"synthetic-data")
    save(bundle / "synthetic-tests.json", tree_for(spec))
    save(bundle / "synthetic-summary.json", summary_for(spec))
    r.retain_xcresult_exports(folder, bundle)
    want = r.provenance(group, DESTINATION, bundle, scope)
    save(folder / "selection.json", want)
    save(folder / "execution.json", {**want, "native_exit": 0, "timed_out": False})
    write_group_settings(spec["kind"], target, folder, out_root / "effective-test-settings.json")
    raw = fixture_log(spec)
    (folder / f"{target}.log").write_bytes(raw)
    parsed = r.parse_log(group, raw, 0, False)
    parsed["parameter_xcresult"] = r.parameter_evidence(group, folder, bundle)
    save(folder / "counts.json", parsed)


def check_config_and_grouping(root):
    rejects("missing scope config rejected on explicit load", lambda: r.load_scope_config(root / "missing.json"))
    with repo_sandbox(root / "cfg") as (_, _, config, _, _, _):
        loaded = r.load_scope_config()
        assert loaded == config
        groups = r.build_groups(loaded)
        assert list(groups) == ["domain-1", "domain-2", "host-1", "ui-1", "ui-2"]
        assert groups["domain-1"]["cases"] == ["styleCaseOne", "styleCaseTwo", "styleCaseThree"]
        assert groups["domain-2"]["cases"] == ["epubBooksStayIsolated", "epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime"]
        assert groups["host-1"]["cases"] == ["hostAuthorLayoutOne", "hostAuthorLayoutTwo"]
        assert groups["ui-1"]["cases"] == ["testEPUBAuthorLayoutFlowOne"]
        assert groups["ui-2"]["cases"] == ["testEPUBAuthorLayoutFlowTwo"]
        assert all(s["timeout"] == 480 and s["case_timeout"] == 180 for s in groups.values())
        passed("grouping: non-UI by FILE, UI one case per group, 480/180 timeouts")

        bad_cases = [
            ("wrong scope", lambda c: c.update(scope="epub-opening-followup-3")),
            ("wrong baseline", lambda c: c.update(baseline="0" * 40)),
            ("wrong version", lambda c: c.update(version="0.2.15")),
            ("wrong build", lambda c: c.update(build="17")),
            ("protected allowed", lambda c: c["allowed_paths"].append("AGENTS.md")),
            ("protected status allowed", lambda c: c["allowed_paths"].append("docs/CURRENT_STATUS.md")),
            ("private allowed", lambda c: c["allowed_paths"].append("ask_architect.py")),
            ("empty file cases", lambda c: c["selected_files"].__setitem__("YueJingHostTests/EPUBReaderHostTests.swift", [])),
            ("duplicate selected case", lambda c: c["selected_files"]["YueJingHostTests/EPUBReaderHostTests.swift"].append("styleCaseOne")),
            ("traversal path", lambda c: c["allowed_paths"].append("../escape.swift")),
        ]
        for label, mutate in bad_cases:
            bad = copy.deepcopy(config)
            mutate(bad)
            p = root / ("bad-cfg-" + label.replace(" ", "_") + ".json")
            save(p, bad)
            rejects("config " + label, lambda path=p: r.load_scope_config(path))


def check_parsers(root):
    with repo_sandbox(root / "parsers") as (_, _, config, _, _, _):
        groups = r.build_groups(config)
        for group, spec in groups.items():
            raw = fixture_log(spec)
            parsed = r.parse_log(group, raw, 0, False, groups=groups)
            expected_exec = 3 if group == "domain-2" else len(spec["cases"])
            assert parsed["executions"] == expected_exec and parsed["declarations_passed"] == len(spec["cases"])
            passed("parser accept: " + group)

            bad_logs = [
                ("skip", raw + b"Test extraCase() skipped.\n", 0, False),
                ("fail", raw + b"Test extraCase() failed after 0.1 seconds.\n", 0, False),
                ("missing", raw.replace(spec["cases"][0].encode(), b"unknownCase"), 0, False),
                ("extra", raw + (b"Test Case '-[EPUBFlowUITests testExtra]' passed (0.1 seconds).\n" if spec["kind"] == "ui" else b"Test extraCase() passed after 0.1 seconds.\n"), 0, False),
                ("duplicate", raw + raw, 0, False),
                ("nonzero", raw, 65, False),
                ("bool_exit", raw, False, False),
                ("timeout_flag", raw, 0, True),
                ("case_over_180", raw.replace(b"0.1 seconds", b"181.0 seconds"), 0, False),
                ("no_success_marker", raw.replace(b"** TEST SUCCEEDED **", b""), 0, False),
                ("failed_marker", raw + b"** TEST FAILED **\n", 0, False),
            ]
            for label, altered, code, tout in bad_logs:
                rejects(f"parser reject {group}:{label}", lambda a=altered, c=code, t=tout: r.parse_log(group, a, c, t, groups=groups))

            cmd = r.command(group, DESTINATION, Path("synthetic.xcresult"), groups=groups)
            only_flags = [arg for arg in cmd if arg.startswith("-only-testing:")]
            assert len(only_flags) == len(spec["cases"])
            assert cmd.count("180") == 2 and "-parallel-testing-enabled" in cmd
            assert cmd[cmd.index("-scheme") + 1] == ("ReaderDomain" if spec["kind"] == "domain" else "YueJingUI")

        # Parameterized Bool log tamper checks
        raw_bool = fixture_log(groups["domain-2"])
        arg_line = next(line for line in raw_bool.splitlines(keepends=True) if b"Passing " in line)
        for label, altered in (
            ("missing_bool_arg", raw_bool.replace(arg_line, b"")),
            ("duplicate_bool_arg", raw_bool.replace(arg_line, arg_line * 2)),
            ("unknown_bool_val", raw_bool.replace(b"false to ", b"maybe to ")),
            ("late_bool_arg", raw_bool.replace(arg_line, b"") + arg_line),
        ):
            rejects("bool parser " + label, lambda a=altered: r.parse_log("domain-2", a, 0, False, groups=groups))


def check_xcresult_and_bool(root):
    with repo_sandbox(root / "xcresult") as (_, _, config, _, _, _):
        groups = r.build_groups(config)
        for group, spec in groups.items():
            bundle = root / "xcresult" / f"{group}.xcresult"
            (bundle / "Data").mkdir(parents=True, exist_ok=True)
            (bundle / "Info.plist").write_bytes(b"synthetic")
            (bundle / "Data/d0").write_bytes(b"synthetic")
            tests = tree_for(spec)
            for expanded in (False, True) if group == "domain-2" else (False,):
                summary = summary_for(spec, expanded=expanded)
                save(bundle / "synthetic-tests.json", tests)
                save(bundle / "synthetic-summary.json", summary)
                with patch.object(r, "xcresult_export", side_effect=synthetic_export):
                    assert r.verify_group_xcresult(spec, bundle) == tests
            passed("xcresult multi-case/Bool verify: " + group)

            # Negative xcresult tamper cases
            bad_summary = dict(summary_for(spec), skippedTests=1)
            with patch.object(r, "xcresult_export", side_effect=lambda b, s: json.dumps(tests if s == "tests" else bad_summary).encode()):
                rejects("xcresult summary skip " + group, lambda: r.verify_group_xcresult(spec, bundle))
            bad_tree = copy.deepcopy(tests)
            bad_tree["testNodes"][0]["result"] = "Failed"
            with patch.object(r, "xcresult_export", side_effect=lambda b, s: json.dumps(bad_tree if s == "tests" else summary_for(spec)).encode()):
                rejects("xcresult failed node " + group, lambda: r.verify_group_xcresult(spec, bundle))
            extra_tree = copy.deepcopy(tests)
            extra_tree["testNodes"].append({"name": "alienTest()", "nodeType": "Test Case", "result": "Passed", "children": []})
            with patch.object(r, "xcresult_export", side_effect=lambda b, s: json.dumps(extra_tree if s == "tests" else summary_for(spec)).encode()):
                rejects("xcresult extra node " + group, lambda: r.verify_group_xcresult(spec, bundle))

        # Bool leaf tampering specifically on domain-2
        spec2 = groups["domain-2"]
        bundle2 = root / "xcresult/domain-2.xcresult"
        base_tree = tree_for(spec2)
        for label, mutate in (
            ("missing_leaf", lambda d: d["testNodes"][1]["children"].pop()),
            ("dup_leaf", lambda d: d["testNodes"][1]["children"].append(copy.deepcopy(d["testNodes"][1]["children"][0]))),
            ("skip_leaf", lambda d: d["testNodes"][1]["children"][0].update(result="Skipped")),
            ("empty_children", lambda d: d["testNodes"][1].update(children=[])),
            ("foreign_arg", lambda d: d["testNodes"][1]["children"][0].update(name="other: false")),
        ):
            mut = copy.deepcopy(base_tree)
            mutate(mut)
            with patch.object(r, "xcresult_export", side_effect=lambda b, s, m=mut: json.dumps(m if s == "tests" else summary_for(spec2)).encode()):
                rejects("bool xcresult " + label, lambda: r.verify_group_xcresult(spec2, bundle2))

        # Export failure stream preservation & no overwrite
        exp_dir = root / "xcresult/exports"
        exp_dir.mkdir(parents=True)
        err = subprocess.CalledProcessError(7, ["xcrun"], output=b"out", stderr=b"err")
        with patch.object(r, "xcresult_export", side_effect=lambda b, s: (_ for _ in ()).throw(err) if s == "tests" else b"{}"):
            rejects("xcresult export error propagated", lambda: r.retain_xcresult_exports(exp_dir, bundle2))
        assert (exp_dir / "xcresult-tests.stdout").read_bytes() == b"out"
        assert (exp_dir / "xcresult-tests.stderr").read_bytes() == b"err"
        assert (exp_dir / "xcresult-summary.json").is_file()
        rejects("xcresult export no overwrite", lambda: r.retain_xcresult_exports(exp_dir, bundle2))
        passed("xcresult export retention & no-overwrite")


def check_source_and_dispatch(root):
    with repo_sandbox(root / "src-disp") as (repo_root, out_root, config, previous, current, event_path):
        receipt = r.write_scope(repo_root)
        assert receipt["scope"] == r.SCOPE and receipt["build_ipa"] is False and receipt["prior_validation_run"] == ""
        assert (out_root / "author-layout-scope.json").is_file()
        assert (out_root / "candidate-sources.json").is_file()
        assert (out_root / "dispatch-event.json").is_file()
        assert r.live_scope(repo_root) == receipt
        rejects("scope refuses overwrite", lambda: r.write_scope(repo_root))
        passed("scope writes exclusive receipts & live_scope verifies")

        # Dispatch mutations
        bad_envs = [
            ("wrong_scope", {"VALIDATION_SCOPE": "old-scope"}),
            ("wrong_event", {"GITHUB_EVENT_NAME": "push"}),
            ("wrong_ref", {"GITHUB_REF": "refs/heads/feature"}),
            ("wrong_attempt", {"GITHUB_RUN_ATTEMPT": "2"}),
            ("wrong_repo", {"GITHUB_REPOSITORY": "other/YueJing"}),
            ("diagnostic_env", {"ALLOW_UNQUALIFIED_IPA": "true"}),
            ("prior_env", {"PRIOR_VALIDATION_RUN": "12345"}),
        ]
        for label, extra in bad_envs:
            with patch.dict(os.environ, **extra):
                rejects("dispatch " + label, r.dispatch_context)

        for label, field, val in (
            ("diagnostic_input", "allow_unqualified_ipa", True),
            ("prior_input", "prior_validation_run", "12345"),
            ("wrong_scope_input", "validation_scope", "other"),
        ):
            ev = json.loads(event_path.read_text(encoding="utf-8"))
            ev["inputs"][field] = val
            bad_ev = root / ("ev_" + label + ".json")
            save(bad_ev, ev)
            with patch.dict(os.environ, GITHUB_EVENT_PATH=str(bad_ev)):
                rejects("dispatch payload " + label, r.dispatch_context)

        # build_ipa=true allowed when allow_unqualified_ipa=false and prior=""
        ev_build = json.loads(event_path.read_text(encoding="utf-8"))
        ev_build["inputs"]["build_ipa"] = True
        ev_build_path = root / "ev_build_true.json"
        save(ev_build_path, ev_build)
        with patch.dict(os.environ, GITHUB_EVENT_PATH=str(ev_build_path), BUILD_IPA="true"):
            assert r.dispatch_context()["build_ipa"] is True
        passed("dispatch binds repo/ref/attempt/scope and allows build_ipa=true without prior/diagnostic")

        # Source boundary rejections in clean mode
        rejects("non-ancestor BASE rejected", lambda: r.validate_scope_boundaries(
            previous, current, head=SOURCE_SHA, is_ancestor=False, status_bytes=b"", config=config, pending=False, root=repo_root
        ))
        rejects("dirty worktree rejected in clean mode", lambda: r.validate_scope_boundaries(
            previous, current, head=SOURCE_SHA, is_ancestor=True, status_bytes=b" M AGENTS.md\0", config=config, pending=False, root=repo_root
        ))
        del_curr = dict(current)
        del_curr.pop("Sources/ReaderDomain/EPUB/AuthorLayout.swift")
        rejects("deletion rejected", lambda: r.validate_scope_boundaries(
            previous, del_curr, head=SOURCE_SHA, is_ancestor=True, status_bytes=b"", config=config, pending=False, root=repo_root
        ))
        outside_curr = dict(current)
        outside_curr["Sources/Unapproved.swift"] = ["100644", "blob", "f" * 40]
        rejects("outside allowed_paths rejected", lambda: r.validate_scope_boundaries(
            previous, outside_curr, head=SOURCE_SHA, is_ancestor=True, status_bytes=b"", config=config, pending=False, root=repo_root
        ))
        bad_cfg = copy.deepcopy(config)
        bad_cfg["candidate_sha256"]["Sources/ReaderDomain/EPUB/AuthorLayout.swift"] = "0" * 64
        rejects("candidate_sha256 drift rejected", lambda: r.validate_scope_boundaries(
            previous, current, head=SOURCE_SHA, is_ancestor=True, status_bytes=b"", config=bad_cfg, pending=False, root=repo_root
        ))

        # Pending local check: allows AGENTS.md, docs/CURRENT_STATUS.md, and untracked private files without reading them!
        protected_files = [
            repo_root / "AGENTS.md",
            repo_root / "docs/CURRENT_STATUS.md",
            repo_root / ".architect_memory.json",
            repo_root / "PROJECT_STATE.md",
            repo_root / "ask_architect.py",
        ]
        for pf in protected_files:
            pf.parent.mkdir(parents=True, exist_ok=True)
            pf.write_text("DO_NOT_READ_SECRET_OR_LOCAL\n", encoding="utf-8")

        orig_read_bytes = Path.read_bytes
        orig_read_text = Path.read_text
        orig_open = Path.open
        protected_set = {pf.resolve() for pf in protected_files}

        def guarded_bytes(self, *a, **kw):
            if self.resolve() in protected_set:
                raise AssertionError("Forbidden read of protected/private file: " + str(self))
            return orig_read_bytes(self, *a, **kw)

        def guarded_text(self, *a, **kw):
            if self.resolve() in protected_set:
                raise AssertionError("Forbidden text read of protected/private file: " + str(self))
            return orig_read_text(self, *a, **kw)

        def guarded_open(self, *a, **kw):
            if self.resolve() in protected_set:
                raise AssertionError("Forbidden open of protected/private file: " + str(self))
            return orig_open(self, *a, **kw)
        dirty_status = (
            b" M AGENTS.md\0"
            b" M docs/CURRENT_STATUS.md\0"
            b"?? .architect_memory.json\0"
            b"?? PROJECT_STATE.md\0"
            b"?? ask_architect.py\0"
            b" M project.yml\0"
        )
        current_with_protected = {
            **current,
            "AGENTS.md": ["100644", "blob", "1" * 40],
            "docs/CURRENT_STATUS.md": ["100644", "blob", "2" * 40],
        }
        previous_with_protected = {
            **previous,
            "AGENTS.md": current_with_protected["AGENTS.md"],
            "docs/CURRENT_STATUS.md": current_with_protected["docs/CURRENT_STATUS.md"],
        }
        with patch.object(Path, "read_bytes", guarded_bytes), patch.object(Path, "read_text", guarded_text), patch.object(Path, "open", guarded_open):
            pend = r.validate_scope_boundaries(
                previous_with_protected, current_with_protected, head=SOURCE_SHA, is_ancestor=True, status_bytes=dirty_status,
                config=config, pending=True, root=repo_root,
            )
            assert pend["source_status"] == "pending"
            assert "AGENTS.md" not in pend["changed_paths"]
            assert "docs/CURRENT_STATUS.md" not in pend["changed_paths"]
            assert "project.yml" in pend["changed_paths"]
            passed("local --pending allows protected/private local files without reading or publishing")

        with patch.dict(os.environ, GITHUB_ACTIONS="true"):
            rejects("cloud forbids pending", lambda: r.verify_source(pending=True, root=repo_root))
        rejects("pending rejects unapproved file", lambda: r.validate_scope_boundaries(
            previous, current, head=SOURCE_SHA, is_ancestor=True, status_bytes=b"?? unapproved.swift\0",
            config=config, pending=True, root=repo_root,
        ))
        rejects("pending rejects rename", lambda: r.validate_scope_boundaries(
            previous, current, head=SOURCE_SHA, is_ancestor=True, status_bytes=b"R  a\0b\0",
            config=config, pending=True, root=repo_root,
        ))


def check_scheduler_and_report(root):
    # 1. Independent error continues; 2. Shared compile error blocks rest of same kind but continues others;
    # 3. Common failure stops all; 4. Cancel stops; 5. Mixed raw failure/skip/unfinished/unexecuted report; 6. Omitted targets NOT RUN
    for mode in ("individual", "blocked_same_kind", "common", "cancel"):
        called = []
        with repo_sandbox(root / ("sched-" + mode)) as (repo_root, out_root, config, _, _, _):
            scope = r.write_scope(repo_root)
            groups = r.build_groups(config)
            write_common_receipts(out_root)
            with patch.object(r.compat, "validate_toolchain_and_dependencies", return_value=packages_fixture()) as tools, \
                 patch.object(r.compat, "validate_destination"), \
                 patch.object(r, "xcresult_export", side_effect=synthetic_export), \
                 patch.object(r, "run_group") as mock_run:

                def exec_group(group, dest, checked_scope=None, groups=None):
                    called.append(group)
                    if mode == "cancel":
                        raise KeyboardInterrupt("synthetic cancel")
                    if mode == "blocked_same_kind" and group == "domain-1":
                        raise r.GroupPrerequisiteError("Shared domain build failed")
                    if mode == "individual" and group == "host-1":
                        folder = out_root / "epub-author-layout" / group
                        folder.mkdir(parents=True, exist_ok=True)
                        spec = groups[group]
                        want = r.provenance(group, dest, folder / f"{spec['target']}.xcresult", scope, groups=groups)
                        save(folder / "selection.json", want)
                        save(folder / "execution.json", {**want, "native_exit": 65, "timed_out": False})
                        # One case passes, one fails!
                        log = (
                            f"◇ Test {spec['cases'][0]}() started.\n"
                            f"✔ Test {spec['cases'][0]}() passed after 0.1 seconds.\n"
                            f"◇ Test {spec['cases'][1]}() started.\n"
                            f"✘ Test {spec['cases'][1]}() failed after 0.1 seconds.\n"
                        ).encode("utf-8")
                        (folder / f"{spec['target']}.log").write_bytes(log)
                        raise ValueError("host case 2 failed")
                    populate_valid_group(out_root, group, groups[group], scope)

                mock_run.side_effect = exec_group
                if mode == "common":
                    tools.side_effect = ValueError("toolchain failure")
                    rejects("common prerequisite stops run_all", lambda: r.run_all(DESTINATION))
                elif mode == "cancel":
                    try:
                        r.run_all(DESTINATION)
                    except KeyboardInterrupt:
                        passed("cancel stops scheduling")
                    else:
                        raise AssertionError("Cancel swallowed")
                else:
                    assert r.run_all(DESTINATION) is False

                rep = json.loads((out_root / "case-results.json").read_text(encoding="utf-8"))
                by_case = {row["case"]: row for row in rep["cases"]}
                inv_by_target = {item["target"]: item for item in rep["inventory_targets"]}
                assert rep["full_regression_executed_this_run"] is False
                assert rep["full_regression_passed"] is False
                for omitted in ("TXTCoreTests", "YueJingUITests", "YueJingCanvasTests", "TXTCorePerformanceTests"):
                    assert inv_by_target[omitted]["status"] == "NOT RUN"

                if mode == "individual":
                    assert called == ["domain-1", "domain-2", "host-1", "ui-1", "ui-2"]
                    assert by_case["hostAuthorLayoutOne"]["status"] == "passed"
                    assert by_case["hostAuthorLayoutOne"]["raw_event_status"] == "passed"
                    assert by_case["hostAuthorLayoutTwo"]["status"] == "failed"
                    assert by_case["hostAuthorLayoutTwo"]["raw_event_status"] == "failed"
                elif mode == "blocked_same_kind":
                    assert called == ["domain-1", "host-1", "ui-1", "ui-2"]
                    assert all(by_case[c]["status"] == "blocked" for c in groups["domain-1"]["cases"])
                    assert all(by_case[c]["status"] == "blocked" for c in groups["domain-2"]["cases"])
                    assert by_case["hostAuthorLayoutOne"]["status"] == "passed"
                    assert by_case["testEPUBAuthorLayoutFlowOne"]["status"] == "passed"
                passed("scheduler semantics + omitted NOT RUN: " + mode)

    # Explicit mixed raw failure/skip/unfinished/unexecuted in a multi-case group
    with repo_sandbox(root / "mixed-raw") as (repo_root, out_root, config, _, _, _):
        scope = r.write_scope(repo_root)
        groups = r.build_groups(config)
        spec = groups["domain-1"]
        folder = out_root / "epub-author-layout/domain-1"
        folder.mkdir(parents=True)
        want = r.provenance("domain-1", DESTINATION, folder / "ReaderDomainTests.xcresult", scope, groups=groups)
        save(folder / "selection.json", want)
        save(folder / "execution.json", {**want, "native_exit": 65, "timed_out": False})
        # Case 0 fails, Case 1 skipped, Case 2 unexecuted
        (folder / "ReaderDomainTests.log").write_text(
            f"◇ Test {spec['cases'][0]}() started.\n"
            f"✘ Test {spec['cases'][0]}() failed after 0.1 seconds.\n"
            f"◇ Test {spec['cases'][1]}() skipped.\n",
            encoding="utf-8",
        )
        rep = r.summarize()
        by_case = {row["case"]: row for row in rep["cases"]}
        assert by_case[spec["cases"][0]]["status"] == "failed" and by_case[spec["cases"][0]]["raw_event_status"] == "failed"
        assert by_case[spec["cases"][1]]["status"] == "skipped" and by_case[spec["cases"][1]]["raw_event_status"] == "skipped"
        assert by_case[spec["cases"][2]]["status"] == "unexecuted" and by_case[spec["cases"][2]]["raw_event_status"] == "unexecuted"
        # Timeout / unfinished raw event check
        save(folder / "execution.json", {**want, "native_exit": -9, "timed_out": True})
        (folder / "ReaderDomainTests.log").write_text(
            f"◇ Test {spec['cases'][0]}() started.\n✔ Test {spec['cases'][0]}() passed after 0.1 seconds.\n"
            f"◇ Test {spec['cases'][1]}() started.\n",
            encoding="utf-8",
        )
        rep_to = r.summarize()
        by_to = {row["case"]: row for row in rep_to["cases"]}
        assert by_to[spec["cases"][0]]["status"] == "passed"
        assert by_to[spec["cases"][1]]["status"] == "timed_out" and by_to[spec["cases"][1]]["raw_event_status"] == "unfinished"
        assert by_to[spec["cases"][2]]["status"] == "unexecuted"
        # Report update allowed without overwrite crash
        rep2 = r.summarize(publish=False)
        assert rep2 == rep_to
        # Shared build failure in run_group raises GroupPrerequisiteError
        folder_rg = out_root / "epub-author-layout/domain-2"
        with patch.object(r.reading, "prepare_group_settings"), \
             patch.object(r, "stream_case", side_effect=lambda cmd, lp, to: (lp.write_bytes(b"** BUILD FAILED **\n"), (65, False))[1]):
            try:
                r.run_group("domain-2", DESTINATION, checked_scope=scope, groups=groups)
            except r.GroupPrerequisiteError:
                assert (folder_rg / "execution.json").is_file()
                passed("shared compile error in run_group raises GroupPrerequisiteError")
            else:
                raise AssertionError("Expected GroupPrerequisiteError on ** BUILD FAILED **")
        rep3 = r.summarize(publish=False)
        assert rep3 == r.summarize(publish=False)
        passed("report differentiates failed/skipped/unfinished/unexecuted raw events and allows report update")


def check_qualification_and_delivery(root):
    for build_ipa in (False, True):
        with repo_sandbox(root / f"qual-{build_ipa}", build_ipa=build_ipa) as (repo_root, out_root, config, _, _, _):
            scope = r.write_scope(repo_root)
            groups = r.build_groups(config)
            write_common_receipts(out_root)
            write_sim_app_binary(repo_root, out_root)
            with patch.object(r, "xcresult_export", side_effect=synthetic_export):
                for group, spec in groups.items():
                    populate_valid_group(out_root, group, spec, scope)

                with patch.object(r.compat, "validate_toolchain_and_dependencies", return_value=packages_fixture()), \
                     patch.object(r.reading, "validate_group_settings"):
                    qual = r.qualification()
                    assert qual["passed"] is True
                    assert qual["verified_declarations"] == 9
                    assert qual["native_tests_executed_this_run"] == 10  # 9 declarations + 1 Bool expansion
                    r.write(out_root / "author-layout-gate.json", qual)
                    assert r.validate_saved() == qual
                    passed(f"qualification passes exact counts with Bool expansion (build_ipa={build_ipa})")

                    if not build_ipa:
                        rejects("build_ipa=false forbids delivery_gate", r.delivery_gate)
                        # Tampered gate JSON rejected by validate_saved
                        save(out_root / "author-layout-gate.json", {**qual, "verified_passed": 999})
                        rejects("tampered gate receipt rejected", r.validate_saved)
                        save(out_root / "author-layout-gate.json", qual)

                        # Tampered xcresult-tests.json rejected by live vs saved xcresult check
                        saved_xc = out_root / "epub-author-layout/domain-2/xcresult-tests.json"
                        orig_xc_bytes = saved_xc.read_bytes()
                        bad_xc = json.loads(orig_xc_bytes)
                        bad_xc["testNodes"][1]["children"][0]["result"] = "Skipped"
                        save(saved_xc, bad_xc)
                        rejects("tampered saved xcresult-tests.json rejected", r.qualification)
                        saved_xc.write_bytes(orig_xc_bytes)

                        # Test negative qualification tamper cases
                        save(out_root / "epub-author-layout/host-1/failure.json", {"error": "failed"})
                        rejects("failure.json overrides green counts", r.qualification)
                        (out_root / "epub-author-layout/host-1/failure.json").unlink()

                        save(out_root / "simulator-boot.json", {**r.load(out_root / "simulator-boot.json"), "exit_code": 1})
                        rejects("failed simulator boot rejected", r.qualification)
                        save(out_root / "simulator-boot.json", {**r.load(out_root / "simulator-boot.json"), "exit_code": 0})

                        save(out_root / "webkit-simulator-linkage/verification.json", {**r.load(out_root / "webkit-simulator-linkage/verification.json"), "passed": False})
                        rejects("failed simulator linkage rejected", r.qualification)
                        save(out_root / "webkit-simulator-linkage/verification.json", {**r.load(out_root / "webkit-simulator-linkage/verification.json"), "passed": True})

                        (out_root / "epub-author-layout/domain-1/counts.json").unlink()
                        rejects("missing counts rejected", r.qualification)

                        save(out_root / "epub-freeze-gate.json", {})
                        rejects("mixed historical gate rejected", r.qualification)
                    else:
                        # Delivery gate & complete_delivery checks
                        dev_app = root / f"qual-{build_ipa}/device-app/YueJing.app"
                        dev_app.mkdir(parents=True)
                        (dev_app / "YueJing").write_bytes(b"synthetic-device-macho")
                        (out_root / "app-build.log").write_text("build ok\n", encoding="utf-8")
                        (out_root / "app-build-exit-code.txt").write_text("65\n", encoding="utf-8")

                        with patch.object(r.v, "APP", dev_app):
                            rejects("device build nonzero blocks delivery_gate", r.delivery_gate)
                            (out_root / "app-build-exit-code.txt").write_text("0\n", encoding="utf-8")
                            rejects("missing device linkage blocks delivery_gate", r.delivery_gate)

                            dev_link = out_root / "webkit-device-linkage"
                            dev_link.mkdir(parents=True)
                            (dev_link / "binary").write_bytes((dev_app / "YueJing").read_bytes())
                            save(
                                dev_link / "verification.json",
                                {
                                    "source_commit": SOURCE_SHA,
                                    "run_id": RUN_ID,
                                    "run_attempt": "1",
                                    "passed": True,
                                    "errors": [],
                                    "binaries": [
                                        {
                                            "path": "YueJing",
                                            "evidence": "binary",
                                            "sha256": r.sha(dev_app / "YueJing"),
                                            "passed": True,
                                            "nm_exit": 0,
                                        }
                                    ],
                                },
                            )
                            dg = r.delivery_gate()
                            assert dg["strict_native_qualification"] == "passed"
                            manifest = {
                                "source_commit": SOURCE_SHA,
                                "version": r.VERSION,
                                "build": r.BUILD,
                                "signing": "unsigned",
                                "ipa_sha256": "e" * 64,
                            }
                            dep_gate = {
                                "source_commit": SOURCE_SHA,
                                "run_id": RUN_ID,
                                "run_attempt": "1",
                                "signing": "unsigned",
                                "packages": packages_fixture(),
                                "actual_images": [{"binary": "YueJing", "sha256": r.sha(dev_app / "YueJing")}],
                            }
                            save(out_root / "app-dependency-gate.json", {**dep_gate, "run_id": "wrong"})
                            rejects("dependency gate wrong run_id rejected", lambda: r.complete_delivery(manifest, 12))

                            save(out_root / "app-dependency-gate.json", dep_gate)
                            rejects("wrong manifest version rejected", lambda: r.complete_delivery({**manifest, "version": "0.2.15"}, 12))

                            (dev_app / "YueJing").write_bytes(b"tampered")
                            rejects("device image drift rejected", lambda: r.complete_delivery(manifest, 12))
                            (dev_app / "YueJing").write_bytes((dev_link / "binary").read_bytes())

                            pkg = r.complete_delivery(manifest, 12)
                            assert pkg["ipa_integrity"] == "passed" and (out_root / "author-layout-package.json").is_file()
                            rejects("package receipt refuses overwrite", lambda: r.complete_delivery(manifest, 12))
                            passed("same-run delivery_gate & complete_delivery verified")


def check_prior_reuse_and_mutations(root):
    """Full 14-group (28 fresh + 55/56 reused = 83/84) bounded reuse + negative mutation matrix."""
    prior_sha = r.PRIOR_SOURCE_COMMIT
    prior_id = r.PRIOR_RUN_ID
    cur_sha = "f" * 40
    cur_run_id = "920001"
    base_root = root / "reuse-suite"
    base_root.mkdir(parents=True, exist_ok=True)

    domain_groups = [
        ("domain-1", "ReaderDomainTests/EPUBAuthorStyleMigrationTests.swift", [f"migCase{i}" for i in range(4)]),
        ("domain-2", "ReaderDomainTests/EPUBAuthorStylesTests.swift", [f"styleCase{i}" for i in range(5)]),
        ("domain-3", "ReaderDomainTests/EPUBCompatibilityTests.swift", [f"compatCase{i}" for i in range(8)]),
        ("domain-4", "ReaderDomainTests/EPUBContentPoolTests.swift", [f"poolCase{i}" for i in range(6)]),
        ("domain-5", "ReaderDomainTests/EPUBLibraryTests.swift",
         [f"libCase{i}" for i in range(4)]
         + ["epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime"]
         + [f"libCase{i}" for i in range(4, 13)]),
        ("domain-6", "ReaderDomainTests/EPUBPackageTests.swift", [f"pkgCase{i}" for i in range(8)]),
        ("domain-7", "ReaderDomainTests/EPUBProgressTests.swift", [f"progCase{i}" for i in range(5)]),
        ("domain-8", "ReaderDomainTests/EPUBReadyTests.swift", [f"readyCase{i}" for i in range(10)]),
    ]
    host_groups = [
        ("host-1", "YueJingHostTests/EPUBContentsNavigationTests.swift", [f"navCase{i}" for i in range(6)]),
        ("host-2", "YueJingHostTests/EPUBFontLoadingHostTests.swift", [f"fontCase{i}" for i in range(2)]),
        ("host-3", "YueJingHostTests/EPUBReaderHostTests.swift", [f"hostCase{i}" for i in range(12)]),
    ]
    ui_cases = [
        "testEPUBShelfCoverAndDirectoryCrossChapterNavigation",
        "testEPUBProgressSurvivesExitAndProcessRelaunch",
        "testEPUBTypographyNoCoverFallbackAndTXTIsolation",
    ]
    files = {}
    selected_files = {}
    for _, rel, cases in domain_groups + host_groups:
        files[rel] = " ".join(cases)
        selected_files[rel] = list(cases)
    files["YueJingEPUBUITests/EPUBFlowUITests.swift"] = " ".join(ui_cases)
    selected_files["YueJingEPUBUITests/EPUBFlowUITests.swift"] = list(ui_cases)
    files["TXTCoreTests/TXTChapterTests.swift"] = " ".join(f"txtCoreOmitted{i}" for i in range(25))
    files["TXTCoreTests/TXTBlockDecoderTests.swift"] = " ".join(f"txtBlockOmitted{i}" for i in range(6))
    files["ReaderDomainTests/DerivedReadingIntegrationTests.swift"] = " ".join(f"domainOmitted{i}" for i in range(120))
    files["ProcessingReuseMeasurementTests/ProcessingReuseMeasurementTests.swift"] = "procMeasureOmitted0"
    files["YueJingHostTests/ReaderViewportLifecycleTests.swift"] = " ".join(f"hostOmitted{i}" for i in range(14))
    files["YueJingUITests/ReadingFlowUITests.swift"] = " ".join(f"testTXTOmitted{i}" for i in range(12))
    files["YueJingCanvasTests/ReadingCanvasRenderingTests.swift"] = " ".join(f"canvasOmitted{i}" for i in range(3))
    files["TXTCorePerformanceTests/TXTLargeFilePerformanceTests.swift"] = "perfExcluded0"

    counts = {
        "TXTCoreTests": 25,
        "ReaderDomainTests": 180,
        "TXTBlockDecoderTests": 6,
        "ProcessingReuseMeasurementTests": 1,
        "YueJingHostTests": 34,
        "YueJingUITests": 12,
        "YueJingCanvasTests": 3,
        "YueJingEPUBUITests": 3,
    }
    parameterized = {
        "epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime": {
            "signature": "(symlink:)",
            "argument": "symlink",
            "values": ["false", "true"],
        }
    }
    excluded = {"TXTCorePerformanceTests": "Independent baseline; excluded."}

    def fake_validate_source(root_arg=None):
        cases = {}
        for t in (*counts, *excluded):
            cases[t] = [
                n for p, ns in sorted(files.items())
                if r.inventory.group_for(p) == t for n in ns.split()
            ]
        return {
            "kind": "SOURCE_INVENTORY_NOT_NATIVE",
            "groups": dict(counts),
            "selected": sum(counts.values()),
            "execution_groups": {**counts, "ReaderDomainTests": counts["ReaderDomainTests"] + 1},
            "selected_executions": sum(counts.values()) + 1,
            "parameterized": dict(parameterized),
            "excluded": dict(excluded),
            "all_declared": sum(counts.values()) + 1,
            "native_executions": 0,
            "cases": cases,
        }

    def write_repo_tree(repo_root, *, repaired=False):
        repo_root.mkdir(parents=True, exist_ok=True)
        for rel, names_str in files.items():
            names = names_str.split()
            target = rel.split("/", 1)[0]
            body = []
            if target in ("YueJingEPUBUITests", "YueJingUITests"):
                cls = "EPUBFlowUITests" if target == "YueJingEPUBUITests" else "ReadingFlowUITests"
                body.append(f"final class {cls}: XCTestCase {{")
                for n in names:
                    body.append(f"    @MainActor func {n}() {{}}")
                body.append("}")
            else:
                for n in names:
                    if n in parameterized:
                        body.append(f"@Test(arguments: [false, true]) func {n}(symlink: Bool) {{}}")
                    else:
                        body.append(f"@Test func {n}() {{}}")
            if repaired and rel in ("ReaderDomainTests/EPUBAuthorStylesTests.swift", "YueJingHostTests/EPUBFontLoadingHostTests.swift"):
                body.append("// repaired fixture")
            p = repo_root / "Tests" / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("\n".join(body) + "\n", encoding="utf-8")

        for extra_rel, extra_text in (
            ("Sources/ReaderDomain/EPUB/EPUBAuthorStyles.swift", "public struct AuthorStyles {}\n"),
            ("App/EPUB/EPUBWebView.swift", "public struct EPUBWebView {}\n"),
            ("Tests/ReaderDomainTests/EPUBTestSupport.swift", "struct EPUBTestSupport {}\n"),
            ("scripts/run_epub_author_layout_validation.py", ("# current\n" if repaired else "# prior\n")),
            ("scripts/check_epub_author_layout_validation.py", ("# current-check\n" if repaired else "# prior-check\n")),
            (".github/workflows/task3-validate.yml", ("# current-wf\n" if repaired else "# prior-wf\n")),
        ):
            fp = repo_root / extra_rel
            fp.parent.mkdir(parents=True, exist_ok=True)
            fp.write_text(extra_text, encoding="utf-8")
        proj = repo_root / "project.yml"
        proj.write_text(
            f'name: YueJing\nsettings:\n  base:\n    MARKETING_VERSION: "{r.VERSION}"\n'
            f'    CURRENT_PROJECT_VERSION: "{r.BUILD}"\n    ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\n',
            encoding="utf-8",
        )
        allowed = [
            ".github/workflows/task3-validate.yml",
            "App/EPUB/EPUBWebView.swift",
            "Sources/ReaderDomain/EPUB/EPUBAuthorStyles.swift",
            "Tests/ReaderDomainTests/EPUBAuthorStyleMigrationTests.swift",
            "Tests/ReaderDomainTests/EPUBAuthorStylesTests.swift",
            "Tests/ReaderDomainTests/EPUBCompatibilityTests.swift",
            "Tests/ReaderDomainTests/EPUBContentPoolTests.swift",
            "Tests/ReaderDomainTests/EPUBLibraryTests.swift",
            "Tests/ReaderDomainTests/EPUBPackageTests.swift",
            "Tests/ReaderDomainTests/EPUBProgressTests.swift",
            "Tests/ReaderDomainTests/EPUBReadyTests.swift",
            "Tests/YueJingEPUBUITests/EPUBFlowUITests.swift",
            "Tests/YueJingHostTests/EPUBContentsNavigationTests.swift",
            "Tests/YueJingHostTests/EPUBFontLoadingHostTests.swift",
            "Tests/YueJingHostTests/EPUBReaderHostTests.swift",
            "project.yml",
            "scripts/check_epub_author_layout_validation.py",
            "scripts/epub_author_layout_scope.json",
            "scripts/run_epub_author_layout_validation.py",
        ]
        pinned = {
            "App/EPUB/EPUBWebView.swift": r.sha(repo_root / "App/EPUB/EPUBWebView.swift"),
            "Sources/ReaderDomain/EPUB/EPUBAuthorStyles.swift": r.sha(repo_root / "Sources/ReaderDomain/EPUB/EPUBAuthorStyles.swift"),
            "project.yml": r.sha(proj),
        }
        for _, rel, _ in domain_groups + host_groups:
            pinned["Tests/" + rel] = r.sha(repo_root / "Tests" / rel)
        pinned["Tests/YueJingEPUBUITests/EPUBFlowUITests.swift"] = r.sha(repo_root / "Tests/YueJingEPUBUITests/EPUBFlowUITests.swift")
        cfg = {
            "baseline": r.BASE,
            "scope": r.SCOPE,
            "version": r.VERSION,
            "build": r.BUILD,
            "allowed_paths": allowed,
            "candidate_sha256": pinned,
            "selected_files": selected_files,
        }
        cfg_path = repo_root / "scripts/epub_author_layout_scope.json"
        save(cfg_path, cfg)
        return cfg, cfg_path

    prior_repo = base_root / "prior-repo"
    cur_repo = base_root / "cur-repo"
    prior_cfg, prior_cfg_path = write_repo_tree(prior_repo, repaired=False)
    cur_cfg, cur_cfg_path = write_repo_tree(cur_repo, repaired=True)

    def tree_for_dir(root_dir):
        return {
            p.relative_to(root_dir).as_posix(): ["100644", "blob", r.git_blob_sha1(p.read_bytes())]
            for p in sorted(root_dir.rglob("*")) if p.is_file()
        }

    prior_tree = tree_for_dir(prior_repo)
    cur_tree = tree_for_dir(cur_repo)
    base_tree = dict(prior_tree)
    base_tree["Sources/ReaderDomain/EPUB/EPUBAuthorStyles.swift"] = ["100644", "blob", r.git_blob_sha1(b"base-styles")]
    base_tree["project.yml"] = ["100644", "blob", r.git_blob_sha1(b"base-project")]

    def build_prior_archive_source(src_dir, *, override_cfg=None, override_tree=None):
        src_dir.mkdir(parents=True, exist_ok=True)
        (src_dir / "toolchain.log").write_text(
            f"Source: {prior_sha}\narm64\nXcode 16.4\nBuild version 16F6\nApple Swift version 6.1.2\n",
            encoding="utf-8",
        )
        (src_dir / "xcodegen.log").write_text("Version: 2.46.0\n", encoding="utf-8")
        pins = [
            {"identity": k, "kind": "remoteSourceControl", "location": d["url"],
             "state": {"revision": d["revision"], "version": d["version"]}}
            for k, d in r.compat.epub_batch.DEPENDENCIES.items()
        ]
        save(src_dir / "Package.resolved", {"pins": pins, "version": 2})
        save(src_dir / "dependency-resolution.json", {"packages": packages_fixture()})
        eff = {
            "PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test",
            "SWIFT_VERSION": "6.0",
            "SWIFT_STRICT_CONCURRENCY": "complete",
            "IPHONEOS_DEPLOYMENT_TARGET": "16.6",
            "TEST_HOST": "",
            "BUNDLE_LOADER": "",
            "TEST_TARGET_NAME": "",
        }
        save(src_dir / "effective-test-settings.json", {"ReaderDomainTests": eff})
        save(src_dir / "simulator-selection.json", {
            "udid": DESTINATION.split("id=")[1],
            "device_name": "iPhone SE",
            "architecture": "arm64",
            "physical_device": False,
        })
        save(src_dir / "simulator-boot.json", {
            "source_commit": prior_sha,
            "run_id": prior_id,
            "run_attempt": "1",
            "exit_code": 0,
            "timed_out": False,
            "timeout_seconds": 120,
        })
        link = src_dir / "webkit-simulator-linkage"
        link.mkdir(parents=True)
        (link / "binary").write_bytes(b"synthetic-prior-sim-macho")
        save(link / "verification.json", {
            "source_commit": prior_sha,
            "run_id": prior_id,
            "run_attempt": "1",
            "passed": True,
            "errors": [],
            "binaries": [{
                "path": "YueJing",
                "evidence": "binary",
                "sha256": r.sha(link / "binary"),
                "passed": True,
                "nm_exit": 0,
            }],
        })
        # Notice prior dispatch-event omits prior_validation_run and sets build_ipa="true", just like real run 43153993787.
        prior_ev = {
            "ref": "refs/heads/main",
            "repository": {"full_name": r.REPO},
            "inputs": {"validation_scope": r.SCOPE, "allow_unqualified_ipa": "false", "build_ipa": "true"},
        }
        save(src_dir / "dispatch-event.json", prior_ev)
        with patch.object(r.inventory, "FILES", files), \
             patch.object(r.inventory, "COUNTS", counts), \
             patch.object(r.inventory, "PARAMETERIZED", parameterized), \
             patch.object(r.inventory, "EXCLUDED", excluded), \
             patch.object(r.inventory, "validate_source", side_effect=fake_validate_source):
            p_groups = r.build_groups(prior_cfg)
            p_cand = r._candidate_files(prior_repo)
            p_inv = fake_validate_source(prior_repo)
            save(src_dir / "candidate-sources.json", {
                "source_commit": prior_sha,
                "run_id": prior_id,
                "run_attempt": "1",
                "files": p_cand,
                "inventory": p_inv,
            })
            p_scope = {
                "scope": r.SCOPE,
                "phase": "validation",
                "prior_validation_run": "",
                "source_commit": prior_sha,
                "source_status": "clean",
                "baseline_commit": r.BASE,
                "run_id": prior_id,
                "run_attempt": "1",
                "repository": r.REPO,
                "ref": "refs/heads/main",
                "workflow_id": r.WORKFLOW_ID,
                "workflow_path": r.WORKFLOW_PATH,
                "version": r.VERSION,
                "build": r.BUILD,
                "allow_unqualified_ipa": False,
                "build_ipa": True,
                "dispatch_event_sha256": r.sha(src_dir / "dispatch-event.json"),
                "scope_config_sha256": r.sha(prior_cfg_path),
                "allowed_paths": prior_cfg["allowed_paths"],
                "candidate_sha256": prior_cfg["candidate_sha256"],
                "files": p_cand,
                "selected_files": prior_cfg["selected_files"],
                "selected": {g: list(s["cases"]) for g, s in p_groups.items()},
                "selected_declarations": 83,
                "native_tests_planned": 84,
                "full_inventory_declared": 264,
                "full_inventory_executions": 265,
            }
            save(src_dir / "author-layout-scope.json", p_scope)
            for group, spec in p_groups.items():
                gdir = src_dir / "epub-author-layout" / group
                gdir.mkdir(parents=True)
                target = spec["target"]
                bundle = gdir / f"{target}.xcresult"
                (bundle / "Data").mkdir(parents=True)
                (bundle / "Info.plist").write_bytes(b"synthetic-prior-xcresult")
                (bundle / "Data/data.0").write_bytes(b"synthetic-prior-data")
                save(bundle / "synthetic-tests.json", tree_for(spec))
                save(bundle / "synthetic-summary.json", summary_for(spec))
                with patch.object(r, "xcresult_export", side_effect=synthetic_export):
                    r.retain_xcresult_exports(gdir, bundle)
                bundle_str = f"/Users/runner/work/YueJing/YueJing/artifacts/task3/epub-author-layout/{group}/{target}.xcresult"
                want = r.provenance(group, DESTINATION, bundle_str, p_scope, groups=p_groups)
                save(gdir / "selection.json", want)
                write_group_settings(spec["kind"], target, gdir, src_dir / "effective-test-settings.json")
                if spec["kind"] == "domain":
                    # Overwrite source_commit in settings receipt to match prior_sha
                    stg_path = gdir / f"{target}-settings.json"
                    stg_doc = r.load(stg_path)
                    stg_doc["source_commit"] = prior_sha
                    save(stg_path, stg_doc)
                if group in r.ELIGIBLE_PRIOR_REUSE_GROUPS:
                    save(gdir / "execution.json", {**want, "native_exit": 0, "timed_out": False})
                    raw = fixture_log(spec)
                    (gdir / f"{target}.log").write_bytes(raw)
                    parsed = r.parse_log(group, raw, 0, False, groups=p_groups)
                    with patch.object(r, "xcresult_export", side_effect=synthetic_export):
                        parsed["parameter_xcresult"] = r.parameter_evidence(group, gdir, bundle, group_specs=p_groups)
                    save(gdir / "counts.json", parsed)
                else:
                    save(gdir / "execution.json", {**want, "native_exit": 65, "timed_out": False})
                    (gdir / f"{target}.log").write_bytes(b"** TEST FAILED **\n")
                    save(gdir / "failure.json", {
                        "group": group, "target": target, "kind": spec["kind"],
                        "cases": list(spec["cases"]), "error": "prior failed/blocked",
                        "status": "error", "source_commit": prior_sha, "run_id": prior_id,
                    })
        return p_groups

    def zip_dir(src_dir, zip_path):
        zip_path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as arc:
            for p in sorted(src_dir.rglob("*")):
                if p.is_file():
                    arc.write(p, p.relative_to(src_dir).as_posix())
        return r.sha(zip_path)

    def make_api_files(out_dir, zip_path):
        run_obj = {
            "id": int(prior_id),
            "head_sha": prior_sha,
            "run_attempt": 1,
            "workflow_id": r.WORKFLOW_ID,
            "path": r.WORKFLOW_PATH,
            "event": "workflow_dispatch",
            "head_branch": "main",
            "status": "completed",
            "conclusion": "failure",
            "repository": {"full_name": r.REPO},
            "head_repository": {"full_name": r.REPO},
        }
        art_obj = {
            "id": r.PRIOR_ARTIFACT_ID,
            "expired": False,
            "name": r.PRIOR_ARTIFACT_NAME,
            "workflow_run": {"id": int(prior_id), "head_sha": prior_sha},
            "size_in_bytes": zip_path.stat().st_size,
            "digest": "sha256:" + r.sha(zip_path),
        }
        run_p = out_dir / "api-run.json"
        art_p = out_dir / "api-artifact.json"
        save(run_p, run_obj)
        save(art_p, {"artifacts": [art_obj]})
        return run_obj, art_obj, run_p, art_p

    prior_src_dir = base_root / "prior-evidence-src"
    full_groups = build_prior_archive_source(prior_src_dir)
    prior_zip_path = base_root / "prior-archive.zip"
    prior_zip_sha = zip_dir(prior_src_dir, prior_zip_path)
    api_meta_dir = base_root / "prior-api"
    prior_run_obj, prior_art_obj, prior_run_p, prior_art_p = make_api_files(api_meta_dir, prior_zip_path)

    @contextlib.contextmanager
    def full_reuse_sandbox(work_dir, *, build_ipa=True, prior_val=prior_id):
        out_dir = work_dir / "out"
        out_dir.mkdir(parents=True, exist_ok=True)
        ev_path = work_dir / "event.json"
        save(ev_path, {
            "ref": "refs/heads/main",
            "repository": {"full_name": r.REPO},
            "workflow": r.WORKFLOW_PATH,
            "workflow_id": r.WORKFLOW_ID,
            "inputs": {
                "validation_scope": r.SCOPE,
                "allow_unqualified_ipa": False,
                "build_ipa": build_ipa,
                "prior_validation_run": prior_val,
            },
        })
        local_tree_state = {"prior": copy.deepcopy(prior_tree), "cur": copy.deepcopy(cur_tree), "base": copy.deepcopy(base_tree), "status": b"", "is_prior_anc": True}
        prior_cfg_bytes = prior_cfg_path.read_bytes()

        def fake_git(*args, root=None):
            if args[:2] == ("rev-parse", "HEAD"):
                return (cur_sha + "\n").encode("utf-8")
            if args[0] == "status":
                return local_tree_state["status"]
            if args[:2] == ("show", f"{prior_sha}:scripts/epub_author_layout_scope.json"):
                return prior_cfg_bytes
            raise AssertionError("Unexpected git call in reuse sandbox: " + repr(args))

        def fake_tree(rev, root=None):
            if rev == r.BASE:
                return copy.deepcopy(local_tree_state["base"])
            if rev == prior_sha:
                return copy.deepcopy(local_tree_state["prior"])
            return copy.deepcopy(local_tree_state["cur"])

        def fake_anc(base_arg, head_arg, root=None):
            if base_arg == prior_sha:
                return local_tree_state["is_prior_anc"]
            return True

        real_live = r.live_scope
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(r, "ROOT", cur_repo))
            stack.enter_context(patch.object(r, "OUT", out_dir))
            stack.enter_context(patch.object(r, "SCOPE_CONFIG_JSON", cur_cfg_path))
            stack.enter_context(patch.object(r, "PRIOR_ARTIFACT_SHA256", prior_zip_sha))
            stack.enter_context(patch.object(r, "live_scope", side_effect=lambda root=cur_repo: real_live(root=root)))
            stack.enter_context(patch.object(r.inventory, "FILES", files))
            stack.enter_context(patch.object(r.inventory, "COUNTS", counts))
            stack.enter_context(patch.object(r.inventory, "PARAMETERIZED", parameterized))
            stack.enter_context(patch.object(r.inventory, "EXCLUDED", excluded))
            stack.enter_context(patch.object(r.inventory, "validate_source", side_effect=fake_validate_source))
            stack.enter_context(patch.object(r.compat, "git", side_effect=fake_git))
            stack.enter_context(patch.object(r.compat, "git_tree", side_effect=fake_tree))
            stack.enter_context(patch.object(r, "_git_is_ancestor", side_effect=fake_anc))
            stack.enter_context(patch.object(r, "xcresult_export", side_effect=synthetic_export))
            stack.enter_context(patch.dict(
                os.environ,
                GITHUB_ACTIONS="false",
                VALIDATION_SCOPE=r.SCOPE,
                GITHUB_EVENT_NAME="workflow_dispatch",
                GITHUB_REF="refs/heads/main",
                GITHUB_RUN_ATTEMPT="1",
                GITHUB_REPOSITORY=r.REPO,
                GITHUB_WORKFLOW_REF=f"{r.REPO}/{r.WORKFLOW_PATH}@refs/heads/main",
                GITHUB_SHA=cur_sha,
                GITHUB_RUN_ID=cur_run_id,
                GITHUB_EVENT_PATH=str(ev_path),
                ALLOW_UNQUALIFIED_IPA="false",
                PRIOR_VALIDATION_RUN=prior_val,
                BUILD_IPA="true" if build_ipa else "false",
            ))
            yield out_dir, local_tree_state

    # 1. Positive end-to-end bounded reuse + fresh28 + qualification + delivery_gate + complete_delivery
    with full_reuse_sandbox(base_root / "pos-e2e", build_ipa=True) as (out_dir, _):
        scope = r.write_scope(cur_repo)
        assert scope["prior_validation_run"] == prior_id
        assert scope["prior_source_commit"] == prior_sha
        assert scope["fresh_declarations_planned"] == 28 and scope["fresh_executions_planned"] == 28
        assert scope["reused_declarations_planned"] == 55 and scope["reused_executions_planned"] == 56
        assert scope["selected_declarations"] == 83 and scope["native_tests_planned"] == 84
        assert len(scope["fresh_groups"]) == 7 and len(scope["reused_groups"]) == 7
        assert set(scope["reused_groups"]) == r.ELIGIBLE_PRIOR_REUSE_GROUPS
        assert "domain-2" in scope["fresh_groups"]

        # Common receipts for current run
        (out_dir / "toolchain.log").write_text(
            f"Source: {cur_sha}\narm64\nXcode 16.4\nBuild version 16F6\nApple Swift version 6.1.2\n",
            encoding="utf-8",
        )
        (out_dir / "xcodegen.log").write_text("Version: 2.46.0\n", encoding="utf-8")
        save(out_dir / "dependency-resolution.json", {"packages": packages_fixture()})
        eff_cur = {
            "PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test",
            "SWIFT_VERSION": "6.0",
            "SWIFT_STRICT_CONCURRENCY": "complete",
            "IPHONEOS_DEPLOYMENT_TARGET": "16.6",
            "TEST_HOST": "",
            "BUNDLE_LOADER": "",
            "TEST_TARGET_NAME": "",
        }
        save(out_dir / "effective-test-settings.json", {"ReaderDomainTests": eff_cur})
        save(out_dir / "simulator-selection.json", {
            "udid": DESTINATION.split("id=")[1], "device_name": "iPhone SE", "architecture": "arm64", "physical_device": False
        })
        save(out_dir / "simulator-boot.json", {
            "source_commit": cur_sha, "run_id": cur_run_id, "run_attempt": "1",
            "exit_code": 0, "timed_out": False, "timeout_seconds": 120,
        })
        sim_link = out_dir / "webkit-simulator-linkage"
        sim_link.mkdir(parents=True)
        (sim_link / "binary").write_bytes(b"cur-sim-macho")
        save(sim_link / "verification.json", {
            "source_commit": cur_sha, "run_id": cur_run_id, "run_attempt": "1",
            "passed": True, "errors": [],
            "binaries": [{"path": "YueJing", "evidence": "binary", "sha256": r.sha(sim_link / "binary"), "passed": True, "nm_exit": 0}],
        })
        sim_app = cur_repo / "build/ReadingUIDerivedData/Build/Products/Debug-iphonesimulator/YueJing.app"
        sim_app.mkdir(parents=True, exist_ok=True)
        (sim_app / "YueJing").write_bytes(b"cur-sim-macho")

        offline = {"zip_path": prior_zip_path, "run_json": prior_run_p, "artifact_json": prior_art_p}
        with patch.object(r.compat, "validate_toolchain_and_dependencies", return_value=packages_fixture()):
            reused_gate = r.reuse_evidence(require_dependencies=True, offline_prior=offline, check_shared_sources=True, root=cur_repo)
        assert reused_gate["reused_declarations"] == 55 and reused_gate["reused_native_passed"] == 56
        assert (out_dir / f"reused-evidence/prior-{prior_id}/archive.zip").read_bytes() == prior_zip_path.read_bytes()
        assert (out_dir / f"reused-evidence/prior-{prior_id}/evidence/author-layout-scope.json").is_file()
        # Refuses overwrite
        rejects("reuse refuses overwrite", lambda: r.reuse_evidence(require_dependencies=False, offline_prior=offline, check_shared_sources=True, root=cur_repo))
        # Refuses running a reused group freshly
        rejects("run_group rejects reused domain-1", lambda: r.run_group("domain-1", DESTINATION, checked_scope=scope, groups=full_groups))
        passed("prior reuse verification preserves immutable zip/evidence & forbids reused rerun")

        executed_fresh = []
        def fake_exec_fresh(group, dest, checked_scope=None, groups=None):
            executed_fresh.append(group)
            folder = out_dir / "epub-author-layout" / group
            folder.mkdir(parents=True, exist_ok=True)
            spec = groups[group]
            target = spec["target"]
            bundle = folder / f"{target}.xcresult"
            (bundle / "Data").mkdir(parents=True)
            (bundle / "Info.plist").write_bytes(b"synthetic")
            (bundle / "Data/data.0").write_bytes(b"synthetic")
            save(bundle / "synthetic-tests.json", tree_for(spec))
            save(bundle / "synthetic-summary.json", summary_for(spec))
            r.retain_xcresult_exports(folder, bundle)
            want = r.provenance(group, dest, bundle, scope, groups=groups)
            save(folder / "selection.json", want)
            save(folder / "execution.json", {**want, "native_exit": 0, "timed_out": False})
            write_group_settings(spec["kind"], target, folder, out_dir / "effective-test-settings.json")
            # fix source_commit in settings to cur_sha
            stg_p = folder / f"{target}-settings.json"
            stg_d = r.load(stg_p)
            stg_d["source_commit"] = cur_sha
            save(stg_p, stg_d)
            raw = fixture_log(spec)
            (folder / f"{target}.log").write_bytes(raw)
            parsed = r.parse_log(group, raw, 0, False, groups=groups)
            parsed["parameter_xcresult"] = r.parameter_evidence(group, folder, bundle, group_specs=groups)
            save(folder / "counts.json", parsed)

        with patch.object(r.compat, "validate_toolchain_and_dependencies", return_value=packages_fixture()), \
             patch.object(r.compat, "validate_destination"), \
             patch.object(r, "run_group", side_effect=fake_exec_fresh):
            assert r.run_all(DESTINATION) is True
        assert executed_fresh == ["domain-2", "host-1", "host-2", "host-3", "ui-1", "ui-2", "ui-3"]
        assert not (out_dir / "epub-author-layout/domain-1").exists()
        rep = r.summarize()
        assert rep["native_tests_executed_this_run"] == 28
        assert rep["reused_native_passed"] == 56 and rep["reused_declarations"] == 55
        assert rep["verified_passed"] == 84 and rep["verified_declarations"] == 83
        assert rep["counts"]["passed"] == 28 and rep["counts"]["reused"] == 55
        assert rep["prior_reuse_proof_sha256"] == reused_gate["proof_sha256"]
        md_text = (out_dir / "case-results.md").read_text(encoding="utf-8")
        assert f"reused:{prior_id}" in md_text and "fresh this run 28 declarations (28 executions)" in md_text
        passed("run_all executes only 28 fresh tests; report distinguishes fresh28 vs reused55/56")

        with patch.object(r.compat, "validate_toolchain_and_dependencies", return_value=packages_fixture()), \
             patch.object(r.reading, "validate_group_settings"):
            qual = r.qualification()
            assert qual["passed"] is True
            assert qual["native_tests_executed_this_run"] == 28
            assert qual["fresh_declarations_passed"] == 28
            assert qual["reused_native_passed"] == 56
            assert qual["reused_declarations"] == 55
            assert qual["verified_passed"] == 84
            assert qual["verified_declarations"] == 83
            assert qual["not_executed_this_run"] == 237
            assert qual["unselected_executions"] == 181
            assert len(qual["groups"]) == 7 and len(qual["reused_prior"]["groups"]) == 7
            assert qual["prior_reuse_proof_sha256"] == reused_gate["proof_sha256"]
            r.write(out_dir / "author-layout-gate.json", qual)
            assert r.validate_saved() == qual
            passed("qualification validates fresh28 + reused55/56 = 83/84 with proof digest")

            dev_app = base_root / "pos-dev-app/YueJing.app"
            dev_app.mkdir(parents=True)
            (dev_app / "YueJing").write_bytes(b"dev-macho")
            (out_dir / "app-build.log").write_text("ok\n", encoding="utf-8")
            (out_dir / "app-build-exit-code.txt").write_text("0\n", encoding="utf-8")
            dev_link = out_dir / "webkit-device-linkage"
            dev_link.mkdir(parents=True)
            (dev_link / "binary").write_bytes(b"dev-macho")
            save(dev_link / "verification.json", {
                "source_commit": cur_sha, "run_id": cur_run_id, "run_attempt": "1",
                "passed": True, "errors": [],
                "binaries": [{"path": "YueJing", "evidence": "binary", "sha256": r.sha(dev_app / "YueJing"), "passed": True, "nm_exit": 0}],
            })
            with patch.object(r.v, "APP", dev_app):
                dg = r.delivery_gate()
                assert dg["native_tests_executed_this_run"] == 28
                assert dg["reused_native_passed"] == 56 and dg["verified_passed"] == 84
                assert dg["prior_reuse_proof_sha256"] == qual["prior_reuse_proof_sha256"]
                assert f"reused-evidence/prior-{prior_id}/archive.zip" in dg["evidence_sha256"]
                manifest = {
                    "source_commit": cur_sha, "version": r.VERSION, "build": r.BUILD,
                    "signing": "unsigned", "ipa_sha256": "d" * 64,
                }
                save(out_dir / "app-dependency-gate.json", {
                    "source_commit": cur_sha, "run_id": cur_run_id, "run_attempt": "1",
                    "signing": "unsigned", "packages": packages_fixture(),
                    "actual_images": [{"binary": "YueJing", "sha256": r.sha(dev_app / "YueJing")}],
                })
                pkg = r.complete_delivery(manifest, 15)
                assert pkg["ipa_integrity"] == "passed" and pkg["reused_native_passed"] == 56
                passed("delivery_gate & complete_delivery verify fresh28 + reused55/56 + proof digest")

            # Negative gate/delivery tamper checks on positive sandbox
            bad_qual_mutations = [
                ("forged native_tests_executed_this_run=84", lambda q: q.update(native_tests_executed_this_run=84)),
                ("forged verified_passed=83", lambda q: q.update(verified_passed=83)),
                ("forged reused_native_passed=55", lambda q: q.update(reused_native_passed=55)),
                ("forged proof_sha256", lambda q: q.update(prior_reuse_proof_sha256="0" * 64)),
            ]
            saved_gate_orig = (out_dir / "author-layout-gate.json").read_bytes()
            for label, mut in bad_qual_mutations:
                m = copy.deepcopy(qual)
                mut(m)
                save(out_dir / "author-layout-gate.json", m)
                rejects(label, r.validate_saved)
            (out_dir / "author-layout-gate.json").write_bytes(saved_gate_orig)

            # Forged extra group in NATIVE_OUT (masquerading domain-1 as fresh)
            (out_dir / "epub-author-layout/domain-1").mkdir()
            rejects("extra fresh folder domain-1 rejected", r.qualification)
            (out_dir / "epub-author-layout/domain-1").rmdir()

            # Missing fresh domain-2 folder rejected
            shutil.move(out_dir / "epub-author-layout/domain-2", base_root / "tmp-d2")
            rejects("missing fresh domain-2 rejected", r.qualification)
            shutil.move(base_root / "tmp-d2", out_dir / "epub-author-layout/domain-2")

            # Forged extra entry in reused-evidence directory
            (out_dir / "reused-evidence/extra.txt").write_text("x", encoding="utf-8")
            rejects("extra entry in reused-evidence rejected", r.qualification)
            (out_dir / "reused-evidence/extra.txt").unlink()

            # Tampered reused-prior-gate.json rejected
            rg_orig = (out_dir / "reused-evidence/reused-prior-gate.json").read_bytes()
            rg_bad = json.loads(rg_orig)
            rg_bad["reused_executions"] = 99
            save(out_dir / "reused-evidence/reused-prior-gate.json", rg_bad)
            rejects("tampered reused-prior-gate counts rejected", r.qualification)
            (out_dir / "reused-evidence/reused-prior-gate.json").write_bytes(rg_orig)

            # Changed effective test settings between prior and current rejected
            eff_orig = (out_dir / "effective-test-settings.json").read_bytes()
            eff_bad = json.loads(eff_orig)
            eff_bad["ReaderDomainTests"]["TEST_HOST"] = "/unexpected"
            save(out_dir / "effective-test-settings.json", eff_bad)
            rejects("changed effective test settings rejected", r.qualification)
            (out_dir / "effective-test-settings.json").write_bytes(eff_orig)

            # Mixed qualification file rejected
            save(out_dir / "reused-native-gate.json", {})
            rejects("mixed reused-native-gate rejected", r.qualification)
            (out_dir / "reused-native-gate.json").unlink()

    # 2. Negative dispatch & API provenance checks
    with full_reuse_sandbox(base_root / "neg-dispatch", build_ipa=False, prior_val=prior_id):
        rejects("wrong prior_validation_run id", lambda: (
            patch.dict(os.environ, PRIOR_VALIDATION_RUN="43153993786").__enter__(),
            r.dispatch_context(),
        ))
        with patch.dict(os.environ, PRIOR_VALIDATION_RUN="43153993786"):
            rejects("dispatch env mismatch", r.dispatch_context)
        with patch.dict(os.environ, GITHUB_RUN_ID=prior_id):
            rejects("dispatch self-referential prior run", r.dispatch_context)
        with patch.dict(os.environ, GITHUB_RUN_ATTEMPT="2"):
            rejects("dispatch wrong run attempt", r.dispatch_context)

    api_mutations = [
        ("wrongsource run.head_sha", lambda rn, ar: rn.update(head_sha="0" * 40)),
        ("wrongsource artifact.head_sha", lambda rn, ar: ar["workflow_run"].update(head_sha="0" * 40)),
        ("wrongrun run.id", lambda rn, ar: rn.update(id=999)),
        ("wrongrun workflow_id", lambda rn, ar: rn.update(workflow_id=1)),
        ("wrongrun workflow path", lambda rn, ar: rn.update(path=".github/workflows/other.yml")),
        ("wrongrun event push", lambda rn, ar: rn.update(event="push")),
        ("wrongrun branch", lambda rn, ar: rn.update(head_branch="feature")),
        ("wrongrun status in_progress", lambda rn, ar: rn.update(status="in_progress")),
        ("wrongrun conclusion cancelled", lambda rn, ar: rn.update(conclusion="cancelled")),
        ("wrongrun conclusion timed_out", lambda rn, ar: rn.update(conclusion="timed_out")),
        ("wrongrun repo", lambda rn, ar: rn["repository"].update(full_name="evil/YueJing")),
        ("wrongrun head_repo", lambda rn, ar: rn["head_repository"].update(full_name="evil/YueJing")),
        ("wrongattempt run_attempt=2", lambda rn, ar: rn.update(run_attempt=2)),
        ("wrongartifact id", lambda rn, ar: ar.update(id=123)),
        ("wrongartifact expired", lambda rn, ar: ar.update(expired=True)),
        ("wrongartifact name", lambda rn, ar: ar.update(name="other-artifact")),
        ("wrongartifact size=0", lambda rn, ar: ar.update(size_in_bytes=0)),
        ("wrongartifact digest", lambda rn, ar: ar.update(digest="sha256:" + "0" * 64)),
    ]
    for label, mutate in api_mutations:
        rn_m = copy.deepcopy(prior_run_obj)
        ar_m = copy.deepcopy(prior_art_obj)
        mutate(rn_m, ar_m)
        rejects("API " + label, lambda rn=rn_m, ar=ar_m: r.validate_prior_run_and_artifact(prior_id, rn, ar, prior_sha, cur_run_id))
    rejects("API self-referential", lambda: r.validate_prior_run_and_artifact(prior_id, prior_run_obj, prior_art_obj, prior_sha, prior_id))

    # 3. Negative source compatibility checks (changedprod, changedreusedtest, wrongsource)
    with full_reuse_sandbox(base_root / "neg-src"):
        # Changed product code in current tree
        bad_prod_tree = copy.deepcopy(cur_tree)
        bad_prod_tree["Sources/ReaderDomain/EPUB/EPUBAuthorStyles.swift"] = ["100644", "blob", r.git_blob_sha1(b"mutated")]
        rejects("changedprod in current tree", lambda: r.validate_prior_source_compatibility(
            prior_tree, bad_prod_tree, prior_cfg, cur_cfg, head=cur_sha, is_prior_ancestor=True,
        ))
        # Changed project.yml in current tree
        bad_proj_tree = copy.deepcopy(cur_tree)
        bad_proj_tree["project.yml"] = ["100644", "blob", r.git_blob_sha1(b"mutated-proj")]
        rejects("changedprod project.yml", lambda: r.validate_prior_source_compatibility(
            prior_tree, bad_proj_tree, prior_cfg, cur_cfg, head=cur_sha, is_prior_ancestor=True,
        ))
        # Changed helper test file
        bad_helper_tree = copy.deepcopy(cur_tree)
        bad_helper_tree["Tests/ReaderDomainTests/EPUBTestSupport.swift"] = ["100644", "blob", r.git_blob_sha1(b"mutated-helper")]
        rejects("changedreusedtest helper", lambda: r.validate_prior_source_compatibility(
            prior_tree, bad_helper_tree, prior_cfg, cur_cfg, head=cur_sha, is_prior_ancestor=True,
        ))
        # Changed reused test file
        bad_reused_tree = copy.deepcopy(cur_tree)
        bad_reused_tree["Tests/ReaderDomainTests/EPUBLibraryTests.swift"] = ["100644", "blob", r.git_blob_sha1(b"mutated-lib")]
        rejects("changedreusedtest EPUBLibraryTests", lambda: r.validate_prior_source_compatibility(
            prior_tree, bad_reused_tree, prior_cfg, cur_cfg, head=cur_sha, is_prior_ancestor=True,
        ))
        # Added or deleted file
        added_tree = copy.deepcopy(cur_tree)
        added_tree["Sources/Extra.swift"] = ["100644", "blob", "1" * 40]
        rejects("added file since prior rejected", lambda: r.validate_prior_source_compatibility(
            prior_tree, added_tree, prior_cfg, cur_cfg, head=cur_sha, is_prior_ancestor=True,
        ))
        deleted_tree = copy.deepcopy(cur_tree)
        deleted_tree.pop("App/EPUB/EPUBWebView.swift")
        rejects("deleted file since prior rejected", lambda: r.validate_prior_source_compatibility(
            prior_tree, deleted_tree, prior_cfg, cur_cfg, head=cur_sha, is_prior_ancestor=True,
        ))
        # Changed candidate_sha256 pin for prod or reused test
        bad_pin_prod = copy.deepcopy(cur_cfg)
        bad_pin_prod["candidate_sha256"]["App/EPUB/EPUBWebView.swift"] = "0" * 64
        rejects("changedprod candidate_sha256 pin", lambda: r.validate_prior_source_compatibility(
            prior_tree, cur_tree, prior_cfg, bad_pin_prod, head=cur_sha, is_prior_ancestor=True,
        ))
        bad_pin_reused = copy.deepcopy(cur_cfg)
        bad_pin_reused["candidate_sha256"]["Tests/ReaderDomainTests/EPUBReadyTests.swift"] = "0" * 64
        rejects("changedreusedtest candidate_sha256 pin", lambda: r.validate_prior_source_compatibility(
            prior_tree, cur_tree, prior_cfg, bad_pin_reused, head=cur_sha, is_prior_ancestor=True,
        ))
        # Changed selected_files / inventory
        bad_sel = copy.deepcopy(cur_cfg)
        bad_sel["selected_files"]["ReaderDomainTests/EPUBReadyTests.swift"].pop()
        rejects("changed selected_files structure", lambda: r.validate_prior_source_compatibility(
            prior_tree, cur_tree, prior_cfg, bad_sel, head=cur_sha, is_prior_ancestor=True,
        ))
        # Non-ancestor prior commit or unadvanced HEAD
        rejects("wrongsource non-ancestor prior", lambda: r.validate_prior_source_compatibility(
            prior_tree, cur_tree, prior_cfg, cur_cfg, head=cur_sha, is_prior_ancestor=False,
        ))
        rejects("wrongsource unadvanced HEAD", lambda: r.validate_prior_source_compatibility(
            prior_tree, cur_tree, prior_cfg, cur_cfg, head=prior_sha, is_prior_ancestor=True,
        ))
        # Clean mode rejects protected local doc; pending=True allows protected doc without reading
        rejects("clean rejects dirty protected doc", lambda: r.validate_prior_source_compatibility(
            prior_tree, cur_tree, prior_cfg, cur_cfg, head=cur_sha, is_prior_ancestor=True,
            status_bytes=b" M docs/CURRENT_STATUS.md\0", pending=False,
        ))
        pend_ok = r.validate_prior_source_compatibility(
            prior_tree, cur_tree, prior_cfg, cur_cfg, head=cur_sha, is_prior_ancestor=True,
            status_bytes=b" M docs/CURRENT_STATUS.md\0 M AGENTS.md\0?? ask_architect.py\0", pending=True,
        )
        assert "docs/CURRENT_STATUS.md" not in pend_ok["changed_from_prior"]
        passed("source diff rejects changedprod/changedreusedtest/wrongsource & protects local docs")

    # 4. Negative archive / evidence mutations (checksum, skip, failedcounts, parameter leaves, forged evidence)
    def bind_mutated_prior(src_dir, work_dir):
        zpath = work_dir / "archive.zip"
        zsha = zip_dir(src_dir, zpath)
        rn, ar, _, _ = make_api_files(work_dir, zpath)
        folder = work_dir / "bound"
        folder.mkdir(parents=True)
        with (folder / "archive.zip").open("xb") as d, zpath.open("rb") as s:
            shutil.copyfileobj(s, d)
        save(folder / "api-run.json", rn)
        save(folder / "api-artifact.json", ar)
        mems = r.safe_zip_members(zpath)
        ret = r.extract_selected_members(zpath, mems, set(mems), folder / "evidence")
        save(folder / "archive-receipt.json", {
            "run_id": prior_id, "run_attempt": "1", "source_commit": prior_sha,
            "artifact_id": r.PRIOR_ARTIFACT_ID, "artifact_name": r.PRIOR_ARTIFACT_NAME,
            "archive_bytes": ar["size_in_bytes"], "archive_sha256": zsha,
            "member_count": len(mems), "members": mems, "retained_files": ret,
        })
        return folder, zsha

    # Test offline checksum mismatch vs pinned PRIOR_ARTIFACT_SHA256
    with full_reuse_sandbox(base_root / "neg-checksum") as (out_dir, _):
        r.write_scope(cur_repo)
        wrong_sha = "0" * 64
        bad_art_p = base_root / "neg-checksum-art.json"
        save(bad_art_p, {"artifacts": [{**prior_art_obj, "digest": "sha256:" + prior_zip_sha}]})
        with patch.object(r, "PRIOR_ARTIFACT_SHA256", wrong_sha):
            rejects("checksum mismatch vs pinned PRIOR_ARTIFACT_SHA256", lambda: r.reuse_evidence(
                require_dependencies=False,
                offline_prior={"zip_path": prior_zip_path, "run_json": prior_run_p, "artifact_json": bad_art_p},
                check_shared_sources=True, root=cur_repo,
            ))

    prior_mutations = [
        ("wrongsource scope", "author-layout-scope.json", lambda x: x.update(source_commit="b" * 40)),
        ("wrongsource candidate", "candidate-sources.json", lambda x: x.update(source_commit="b" * 40)),
        ("wrongattempt scope", "author-layout-scope.json", lambda x: x.update(run_attempt="2")),
        ("wrongattempt candidate", "candidate-sources.json", lambda x: x.update(run_attempt="2")),
        ("wrongattempt boot", "simulator-boot.json", lambda x: x.update(run_attempt="2")),
        ("wrongrun scope", "author-layout-scope.json", lambda x: x.update(run_id="999999")),
        ("recursive scope", "author-layout-scope.json", lambda x: x.update(prior_validation_run="123")),
        ("diagnostic scope", "author-layout-scope.json", lambda x: x.update(allow_unqualified_ipa=True)),
        ("changedprod deps", "dependency-resolution.json", lambda x: x["packages"]["grdb.swift"].update(checkout_revision="0" * 40)),
        ("changedreusedtest scope pin", "author-layout-scope.json", lambda x: x["candidate_sha256"].__setitem__("Tests/ReaderDomainTests/EPUBReadyTests.swift", "0" * 64)),
        ("wronggroup selection cmd", "epub-author-layout/domain-1/selection.json", lambda x: x["command"].append("-skip-testing:foreign")),
        ("failedcounts exec exit=65", "epub-author-layout/domain-3/execution.json", lambda x: x.update(native_exit=65)),
        ("failedcounts exec timed_out", "epub-author-layout/domain-3/execution.json", lambda x: x.update(timed_out=True)),
        ("failedcounts counts.executions", "epub-author-layout/domain-3/counts.json", lambda x: x.update(executions=99)),
        ("failedcounts summary passedTests", "epub-author-layout/domain-3/xcresult-summary.json", lambda x: x.update(passedTests=7)),
        ("skip summary skippedTests", "epub-author-layout/domain-3/xcresult-summary.json", lambda x: x.update(skippedTests=1)),
        ("skip xcresult node", "epub-author-layout/domain-3/xcresult-tests.json", lambda x: x["testNodes"][0].update(result="Skipped")),
        ("parameter leaf missing", "epub-author-layout/domain-5/xcresult-tests.json", lambda x: x["testNodes"][4]["children"].pop()),
        ("parameter leaf skipped", "epub-author-layout/domain-5/xcresult-tests.json", lambda x: x["testNodes"][4]["children"][0].update(result="Skipped")),
        ("parameter leaf failed", "epub-author-layout/domain-5/xcresult-tests.json", lambda x: x["testNodes"][4]["children"][1].update(result="Failed")),
        ("parameter leaf foreign arg", "epub-author-layout/domain-5/xcresult-tests.json", lambda x: x["testNodes"][4]["children"][0].update(name="other: false")),
        ("linkage failed", "webkit-simulator-linkage/verification.json", lambda x: x.update(passed=False)),
    ]
    for idx, (label, rel, mut) in enumerate(prior_mutations):
        wdir = base_root / f"mut-{idx}"
        sdir = wdir / "src"
        shutil.copytree(prior_src_dir, sdir)
        tpath = sdir / rel
        doc = json.loads(tpath.read_text(encoding="utf-8"))
        mut(doc)
        save(tpath, doc)
        folder, zsha = bind_mutated_prior(sdir, wdir)
        with full_reuse_sandbox(wdir / "sb") as (out_dir, _):
            scope = r.write_scope(cur_repo)
            with patch.object(r, "PRIOR_ARTIFACT_SHA256", zsha):
                def check_it(fld=folder, sc=scope):
                    res = r.inspect_prior_evidence(fld, sc, root=cur_repo, expected_packages=packages_fixture())
                    r.require(res["passed"], "; ".join(res["errors"]))
                rejects("prior mutation " + label, check_it)

    # Raw log / file additions / deletions / forged evidence in prior archive
    file_mutations = [
        ("forged recursive folder", lambda s: save(s / "reused-evidence/gate.json", {})),
        ("forged pre-existing gate", lambda s: save(s / "author-layout-gate.json", {})),
        ("forged scheduling error", lambda s: save(s / "case-scheduling-error.json", {"error": "cancelled"})),
        ("forged domain-1 failure.json", lambda s: save(s / "epub-author-layout/domain-1/failure.json", {"error": "failed"})),
        ("forged domain-2 counts.json", lambda s: save(s / "epub-author-layout/domain-2/counts.json", {"passed": []})),
        ("wronggroup missing domain-8", lambda s: shutil.rmtree(s / "epub-author-layout/domain-8")),
        ("skip raw log", lambda s: (s / "epub-author-layout/domain-4/ReaderDomainTests.log").write_bytes(
            (s / "epub-author-layout/domain-4/ReaderDomainTests.log").read_bytes() + b"Test extra() skipped.\n")),
        ("parameter log missing true arg", lambda s: (s / "epub-author-layout/domain-5/ReaderDomainTests.log").write_bytes(
            (s / "epub-author-layout/domain-5/ReaderDomainTests.log").read_bytes().replace(b"symlink \xe2\x86\x92 true", b"symlink \xe2\x86\x92 other"))),
        ("wrongsource toolchain.log", lambda s: (s / "toolchain.log").write_text("Source: " + "0" * 40 + "\n", encoding="utf-8")),
    ]
    for idx, (label, mut) in enumerate(file_mutations):
        wdir = base_root / f"fmut-{idx}"
        sdir = wdir / "src"
        shutil.copytree(prior_src_dir, sdir)
        mut(sdir)
        folder, zsha = bind_mutated_prior(sdir, wdir)
        with full_reuse_sandbox(wdir / "sb") as (out_dir, _):
            scope = r.write_scope(cur_repo)
            with patch.object(r, "PRIOR_ARTIFACT_SHA256", zsha):
                def check_f(fld=folder, sc=scope):
                    res = r.inspect_prior_evidence(fld, sc, root=cur_repo, expected_packages=packages_fixture())
                    r.require(res["passed"], "; ".join(res["errors"]))
                rejects("prior file mutation " + label, check_f)

    # Forged local disk log + forged archive-receipt.json (still rejected against immutable archive.zip!)
    wdir = base_root / "forged-disk"
    sdir = wdir / "src"
    shutil.copytree(prior_src_dir, sdir)
    folder, zsha = bind_mutated_prior(sdir, wdir)
    tamper_log = folder / "evidence/epub-author-layout/domain-1/ReaderDomainTests.log"
    tamper_log.write_bytes(tamper_log.read_bytes() + b"\nforged\n")
    rec_p = folder / "archive-receipt.json"
    rec = r.load(rec_p)
    rel = "epub-author-layout/domain-1/ReaderDomainTests.log"
    rec["members"][rel] = rec["retained_files"][rel] = {"bytes": tamper_log.stat().st_size, "sha256": r.sha(tamper_log)}
    save(rec_p, rec)
    with full_reuse_sandbox(wdir / "sb") as (out_dir, _):
        scope = r.write_scope(cur_repo)
        with patch.object(r, "PRIOR_ARTIFACT_SHA256", zsha):
            rejects("forged retained log + receipt rejected vs archive.zip",
                    lambda: r.inspect_prior_evidence(folder, scope, root=cur_repo, expected_packages=packages_fixture()))

    # Forged live xcresult export mismatching saved xcresult-tests.json / xcresult-summary.json
    wdir2 = base_root / "forged-xc"
    sdir2 = wdir2 / "src"
    shutil.copytree(prior_src_dir, sdir2)
    folder2, zsha2 = bind_mutated_prior(sdir2, wdir2)
    with full_reuse_sandbox(wdir2 / "sb") as (out_dir, _):
        scope = r.write_scope(cur_repo)
        def drift_export(bundle, section):
            data = synthetic_export(bundle, section)
            if bundle.parent.name == "domain-3" and section == "tests":
                doc = json.loads(data)
                doc["testNodes"][0]["result"] = "Failed"
                return json.dumps(doc).encode()
            return data
        with patch.object(r, "PRIOR_ARTIFACT_SHA256", zsha2), \
             patch.object(r, "xcresult_export", side_effect=drift_export):
            def check_drift():
                res = r.inspect_prior_evidence(folder2, scope, root=cur_repo, expected_packages=packages_fixture())
                r.require(res["passed"], "; ".join(res["errors"]))
            rejects("forged saved xcresult vs live xcresulttool rejected", check_drift)

    # Cloud security invariants (cannot bypass API/native parsing/offline)
    with patch.dict(os.environ, GITHUB_ACTIONS="true"):
        rejects("cloud forbids offline prior", lambda: r.reuse_evidence(offline_prior={"zip_path": prior_zip_path, "run_json": prior_run_p, "artifact_json": prior_art_p}))
        rejects("cloud forbids verify_native=False", lambda: r.inspect_prior_evidence(folder2, {}, verify_native=False))
        rejects("cloud forbids check_shared_sources=False", lambda: r.inspect_prior_evidence(folder2, {}, check_shared_sources=False))

    # Forged live GitHub API digest drift on Actions
    with full_reuse_sandbox(base_root / "forged-live-api") as (out_dir, _):
        scope = r.write_scope(cur_repo)
        def fake_api(suffix):
            if suffix == f"/actions/runs/{prior_id}":
                return dict(prior_run_obj)
            if suffix == f"/actions/artifacts/{r.PRIOR_ARTIFACT_ID}":
                return {**prior_art_obj, "digest": "sha256:" + "0" * 64}
            raise AssertionError("Unexpected api: " + suffix)
        with patch.object(r, "PRIOR_ARTIFACT_SHA256", prior_zip_sha), \
             patch.object(r, "github_api_json", side_effect=fake_api):
            rejects("forged live API artifact digest rejected",
                    lambda: r.inspect_prior_evidence(folder2, scope, root=cur_repo, check_live_api=True))

    # Online reuse_evidence path (mocked gh API + zip download) & partial fresh failure isolation
    with full_reuse_sandbox(base_root / "online-api-and-partial-fail", build_ipa=False, prior_val=prior_id) as (out_dir, _):
        scope = r.write_scope(cur_repo)
        (out_dir / "toolchain.log").write_text(
            f"Source: {cur_sha}\narm64\nXcode 16.4\nBuild version 16F6\nApple Swift version 6.1.2\n",
            encoding="utf-8",
        )
        (out_dir / "xcodegen.log").write_text("Version: 2.46.0\n", encoding="utf-8")
        save(out_dir / "dependency-resolution.json", {"packages": packages_fixture()})
        eff_cur = {
            "PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test",
            "SWIFT_VERSION": "6.0",
            "SWIFT_STRICT_CONCURRENCY": "complete",
            "IPHONEOS_DEPLOYMENT_TARGET": "16.6",
            "TEST_HOST": "",
            "BUNDLE_LOADER": "",
            "TEST_TARGET_NAME": "",
        }
        save(out_dir / "effective-test-settings.json", {"ReaderDomainTests": eff_cur})
        save(out_dir / "simulator-selection.json", {
            "udid": DESTINATION.split("id=")[1], "device_name": "iPhone SE", "architecture": "arm64", "physical_device": False,
        })
        save(out_dir / "simulator-boot.json", {
            "source_commit": cur_sha, "run_id": cur_run_id, "run_attempt": "1",
            "exit_code": 0, "timed_out": False, "timeout_seconds": 120,
        })
        sim_link = out_dir / "webkit-simulator-linkage"
        sim_link.mkdir(parents=True)
        (sim_link / "binary").write_bytes(b"cur-sim-macho")
        save(sim_link / "verification.json", {
            "source_commit": cur_sha, "run_id": cur_run_id, "run_attempt": "1",
            "passed": True, "errors": [],
            "binaries": [{"path": "YueJing", "evidence": "binary", "sha256": r.sha(sim_link / "binary"), "passed": True, "nm_exit": 0}],
        })
        sim_app = cur_repo / "build/ReadingUIDerivedData/Build/Products/Debug-iphonesimulator/YueJing.app"
        sim_app.mkdir(parents=True, exist_ok=True)
        (sim_app / "YueJing").write_bytes(b"cur-sim-macho")

        def fake_api_ok(suffix):
            if suffix == f"/actions/runs/{prior_id}":
                return dict(prior_run_obj)
            if suffix == f"/actions/artifacts/{r.PRIOR_ARTIFACT_ID}":
                return dict(prior_art_obj)
            raise AssertionError("Unexpected api suffix: " + suffix)

        def fake_dl(artifact_id, dest_path):
            assert artifact_id == r.PRIOR_ARTIFACT_ID
            dest_path.parent.mkdir(parents=True, exist_ok=True)
            with dest_path.open("xb") as dst, prior_zip_path.open("rb") as src:
                shutil.copyfileobj(src, dst)

        with patch.object(r, "PRIOR_ARTIFACT_SHA256", prior_zip_sha), \
             patch.object(r, "github_api_json", side_effect=fake_api_ok), \
             patch.object(r, "github_download_artifact_zip", side_effect=fake_dl), \
             patch.object(r.compat, "validate_toolchain_and_dependencies", return_value=packages_fixture()):
            rg_online = r.reuse_evidence(require_dependencies=True, offline_prior=None, check_shared_sources=True, root=cur_repo)
            assert rg_online["passed"] is True and rg_online["qualified"] is True

        partial_groups = []
        def exec_domain2_fail(group, dest, checked_scope=None, groups=None):
            partial_groups.append(group)
            folder = out_dir / "epub-author-layout" / group
            folder.mkdir(parents=True, exist_ok=True)
            spec = groups[group]
            target = spec["target"]
            if group == "domain-2":
                want = r.provenance(group, dest, folder / f"{target}.xcresult", scope, groups=groups)
                save(folder / "selection.json", want)
                save(folder / "execution.json", {**want, "native_exit": 65, "timed_out": False})
                lines = [
                    f"◇ Test {spec['cases'][0]}() started.",
                    f"✔ Test {spec['cases'][0]}() passed after 0.1 seconds.",
                    f"◇ Test {spec['cases'][1]}() started.",
                    f"✘ Test {spec['cases'][1]}() failed after 0.1 seconds.",
                ]
                (folder / f"{target}.log").write_text("\n".join(lines) + "\n", encoding="utf-8")
                raise ValueError("domain-2 case failed")
            bundle = folder / f"{target}.xcresult"
            (bundle / "Data").mkdir(parents=True)
            (bundle / "Info.plist").write_bytes(b"synthetic")
            (bundle / "Data/data.0").write_bytes(b"synthetic")
            save(bundle / "synthetic-tests.json", tree_for(spec))
            save(bundle / "synthetic-summary.json", summary_for(spec))
            r.retain_xcresult_exports(folder, bundle)
            want = r.provenance(group, dest, bundle, scope, groups=groups)
            save(folder / "selection.json", want)
            save(folder / "execution.json", {**want, "native_exit": 0, "timed_out": False})
            write_group_settings(spec["kind"], target, folder, out_dir / "effective-test-settings.json")
            stg_p = folder / f"{target}-settings.json"
            stg_d = r.load(stg_p)
            stg_d["source_commit"] = cur_sha
            save(stg_p, stg_d)
            raw = fixture_log(spec)
            (folder / f"{target}.log").write_bytes(raw)
            parsed = r.parse_log(group, raw, 0, False, groups=groups)
            parsed["parameter_xcresult"] = r.parameter_evidence(group, folder, bundle, group_specs=groups)
            save(folder / "counts.json", parsed)

        with patch.object(r, "PRIOR_ARTIFACT_SHA256", prior_zip_sha), \
             patch.object(r.compat, "validate_toolchain_and_dependencies", return_value=packages_fixture()), \
             patch.object(r.compat, "validate_destination"), \
             patch.object(r, "run_group", side_effect=exec_domain2_fail):
            assert r.run_all(DESTINATION) is False
        assert partial_groups == ["domain-2", "host-1", "host-2", "host-3", "ui-1", "ui-2", "ui-3"]
        rep_part = r.load(out_dir / "case-results.json")
        assert rep_part["native_tests_executed_this_run"] is None
        assert rep_part["verified_passed"] is None
        assert rep_part["reused_native_passed"] == 56 and rep_part["counts"]["reused"] == 55
        assert rep_part["counts"]["failed"] == 1 and rep_part["counts"]["unexecuted"] == 3
        with patch.object(r, "PRIOR_ARTIFACT_SHA256", prior_zip_sha), \
             patch.object(r.compat, "validate_toolchain_and_dependencies", return_value=packages_fixture()), \
             patch.object(r.reading, "validate_group_settings"):
            rejects("failed fresh domain-2 prevents qualification despite 56 reused pass", r.qualification)

    # Clean mode forbids reused-evidence dir when prior_validation_run == ""
    with full_reuse_sandbox(base_root / "no-prior-unexpected-reuse", build_ipa=False, prior_val="") as (out_dir, _):
        scope = r.write_scope(cur_repo)
        (out_dir / "toolchain.log").write_text(f"Source: {cur_sha}\narm64\nXcode 16.4\nBuild version 16F6\nApple Swift version 6.1.2\n", encoding="utf-8")
        (out_dir / "xcodegen.log").write_text("Version: 2.46.0\n", encoding="utf-8")
        save(out_dir / "dependency-resolution.json", {"packages": packages_fixture()})
        eff_cur = {
            "PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test",
            "SWIFT_VERSION": "6.0",
            "SWIFT_STRICT_CONCURRENCY": "complete",
            "IPHONEOS_DEPLOYMENT_TARGET": "16.6",
            "TEST_HOST": "",
            "BUNDLE_LOADER": "",
            "TEST_TARGET_NAME": "",
        }
        save(out_dir / "effective-test-settings.json", {"ReaderDomainTests": eff_cur})
        save(out_dir / "simulator-selection.json", {"udid": DESTINATION.split("id=")[1], "device_name": "iPhone SE", "architecture": "arm64", "physical_device": False})
        save(out_dir / "simulator-boot.json", {"source_commit": cur_sha, "run_id": cur_run_id, "run_attempt": "1", "exit_code": 0, "timed_out": False, "timeout_seconds": 120})
        (out_dir / "reused-evidence").mkdir()
        with patch.object(r.compat, "validate_toolchain_and_dependencies", return_value=packages_fixture()), \
             patch.object(r, "validate_linkage", return_value="d" * 64), \
             patch.object(r.reading, "validate_group_settings"):
            for g, spec in full_groups.items():
                populate_valid_group(out_dir, g, spec, scope)
            rejects("unexpected reused-evidence without prior rejected", r.qualification)
            (out_dir / "reused-evidence").rmdir()
            assert r.qualification()["passed"] is True
            passed("clean mode passes without reused-evidence dir (positive control)")
    passed("prior reuse positive + full negative mutation matrix verified")
def check_processes(root):
    p_dir = root / "proc"
    p_dir.mkdir(parents=True, exist_ok=True)
    assert r.stream_case([sys.executable, "-c", 'print("ok")'], p_dir / "ok.log", 10) == (0, False)
    assert r.stream_case([sys.executable, "-c", "raise SystemExit(7)"], p_dir / "fail.log", 10) == (7, False)
    code, expired = r.stream_case([sys.executable, "-c", "import time; time.sleep(20)"], p_dir / "timeout.log", 0.2)
    assert expired and code != 0
    assert r.stream_case([sys.executable, "-c", 'print("after")'], p_dir / "after.log", 10) == (0, False)
    passed("local Python stream_case success/failure/timeout/next")
def _write_xcode_sim_metadata(repo_root):
    resolved_path = repo_root / "YueJing.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    pins = [
        {
            "identity": k,
            "kind": "remoteSourceControl",
            "location": d["url"],
            "state": {"revision": d["revision"], "version": d["version"]},
        }
        for k, d in r.compat.epub_batch.DEPENDENCIES.items()
    ]
    save(resolved_path, {"pins": pins, "version": 2})
    scheme_path = repo_root / "YueJing.xcodeproj/xcshareddata/xcschemes/YueJingUI.xcscheme"
    scheme_path.parent.mkdir(parents=True, exist_ok=True)
    testables = "\n".join(
        f'         <TestableReference skipped="NO"><BuildableReference BlueprintName="{t}"/></TestableReference>'
        for t in sorted(r.reading.ui.GROUPS)
    )
    scheme_path.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Scheme LastUpgradeVersion="1600" version="1.7">\n'
        '   <TestAction>\n'
        '      <Testables>\n'
        f'{testables}\n'
        '      </Testables>\n'
        '      <EnvironmentVariables>\n'
        '         <EnvironmentVariable key="YUEJING_UI_TEST_SESSION" '
        'value="11111111-2222-3333-4444-555555555555" isEnabled="YES"/>\n'
        '      </EnvironmentVariables>\n'
        '   </TestAction>\n'
        '</Scheme>\n',
        encoding="utf-8",
    )
    domain_scheme_path = repo_root / "YueJing.xcodeproj/xcshareddata/xcschemes/ReaderDomain.xcscheme"
    domain_scheme_path.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Scheme LastUpgradeVersion="1600" version="1.7">\n'
        '   <TestAction>\n'
        '      <Testables>\n'
        '         <TestableReference skipped="NO"><BuildableReference BlueprintName="ReaderDomainTests"/></TestableReference>\n'
        '      </Testables>\n'
        '   </TestAction>\n'
        '</Scheme>\n',
        encoding="utf-8",
    )
    return resolved_path, scheme_path, domain_scheme_path


def _write_exact_group_settings(kind, target, folder, eff_path, source_commit, *, scheme_path=None, domain_scheme_path=None):
    common = {
        "SWIFT_VERSION": "6.0",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "IPHONEOS_DEPLOYMENT_TARGET": "16.6",
    }
    if kind == "domain":
        values = json.loads(eff_path.read_text(encoding="utf-8"))["ReaderDomainTests"]
        receipt = {
            "source_commit": source_commit,
            "target": target,
            "scheme": "ReaderDomain",
            "scheme_sha256": r.sha(domain_scheme_path) if domain_scheme_path is not None else ("1" * 64),
            "effective_settings_sha256": r.sha(eff_path),
            "testables": ["ReaderDomainTests"],
            "settings": values,
        }
        save(folder / f"{target}-settings.json", receipt)
        return receipt

    app = {
        **common,
        "PRODUCT_TYPE": "com.apple.product-type.application",
        "TEST_HOST": "",
        "BUNDLE_LOADER": "",
        "TEST_TARGET_NAME": "",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
    }
    if kind == "host":
        host_bin = "/Users/runner/work/YueJing/YueJing/build/Debug-iphonesimulator/YueJing.app/YueJing"
        test = {
            **common,
            "PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test",
            "TEST_HOST": host_bin,
            "BUNDLE_LOADER": host_bin,
            "TEST_TARGET_NAME": "",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        }
    else:
        test = {
            **common,
            "PRODUCT_TYPE": "com.apple.product-type.bundle.ui-testing",
            "TEST_HOST": "",
            "BUNDLE_LOADER": "",
            "TEST_TARGET_NAME": "YueJing",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        }
    targets = {"YueJing": app, target: test}
    scheme_sha = r.sha(scheme_path) if scheme_path is not None else ("2" * 64)
    receipt = {
        "source_commit": source_commit,
        "targets": targets,
        "scheme_sha256": scheme_sha,
        "testables": sorted(r.reading.ui.GROUPS),
        "fixture_environment": "11111111-2222-3333-4444-555555555555",
    }
    save(folder / f"{target}-settings.json", receipt)
    for sub in ("YueJing", target):
        save(folder / f"{target}-{sub}-settings.stdout.json", [{"target": sub, "buildSettings": targets[sub]}])
        (folder / f"{target}-{sub}-settings-exit-code.txt").write_text("0\n", encoding="utf-8")
    return receipt


def _build_3commit_dual_origin_fixture(base_root):
    prior1_sha = r.PRIOR_SOURCE_COMMIT
    prior1_id = r.PRIOR_RUN_ID
    prior2_sha = r.PRIOR2_SOURCE_COMMIT
    prior2_id = r.PRIOR2_RUN_ID
    cur_sha = "e" * 40
    cur_run_id = "930001"
    base_root.mkdir(parents=True, exist_ok=True)

    domain_groups = [
        ("domain-1", "ReaderDomainTests/EPUBAuthorStyleMigrationTests.swift", [f"migCase{i}" for i in range(4)]),
        ("domain-2", "ReaderDomainTests/EPUBAuthorStylesTests.swift", [f"styleCase{i}" for i in range(5)]),
        ("domain-3", "ReaderDomainTests/EPUBCompatibilityTests.swift", [f"compatCase{i}" for i in range(8)]),
        ("domain-4", "ReaderDomainTests/EPUBContentPoolTests.swift", [f"poolCase{i}" for i in range(6)]),
        ("domain-5", "ReaderDomainTests/EPUBLibraryTests.swift",
         [f"libCase{i}" for i in range(4)]
         + ["epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime"]
         + [f"libCase{i}" for i in range(4, 13)]),
        ("domain-6", "ReaderDomainTests/EPUBPackageTests.swift", [f"pkgCase{i}" for i in range(8)]),
        ("domain-7", "ReaderDomainTests/EPUBProgressTests.swift", [f"progCase{i}" for i in range(5)]),
        ("domain-8", "ReaderDomainTests/EPUBReadyTests.swift", [f"readyCase{i}" for i in range(10)]),
    ]
    host_groups = [
        ("host-1", "YueJingHostTests/EPUBContentsNavigationTests.swift", [f"navCase{i}" for i in range(6)]),
        ("host-2", "YueJingHostTests/EPUBFontLoadingHostTests.swift", [f"fontCase{i}" for i in range(2)]),
        ("host-3", "YueJingHostTests/EPUBReaderHostTests.swift", [f"hostCase{i}" for i in range(12)]),
    ]
    ui_cases = [
        "testEPUBShelfCoverAndDirectoryCrossChapterNavigation",
        "testEPUBProgressSurvivesExitAndProcessRelaunch",
        "testEPUBTypographyNoCoverFallbackAndTXTIsolation",
    ]
    files = {}
    selected_files = {}
    for _, rel, cases in domain_groups + host_groups:
        files[rel] = " ".join(cases)
        selected_files[rel] = list(cases)
    files["YueJingEPUBUITests/EPUBFlowUITests.swift"] = " ".join(ui_cases)
    selected_files["YueJingEPUBUITests/EPUBFlowUITests.swift"] = list(ui_cases)
    files["TXTCoreTests/TXTChapterTests.swift"] = " ".join(f"txtCoreOmitted{i}" for i in range(25))
    files["TXTCoreTests/TXTBlockDecoderTests.swift"] = " ".join(f"txtBlockOmitted{i}" for i in range(6))
    files["ReaderDomainTests/DerivedReadingIntegrationTests.swift"] = " ".join(f"domainOmitted{i}" for i in range(120))
    files["ProcessingReuseMeasurementTests/ProcessingReuseMeasurementTests.swift"] = "procMeasureOmitted0"
    files["YueJingHostTests/ReaderViewportLifecycleTests.swift"] = " ".join(f"hostOmitted{i}" for i in range(14))
    files["YueJingUITests/ReadingFlowUITests.swift"] = " ".join(f"testTXTOmitted{i}" for i in range(12))
    files["YueJingCanvasTests/ReadingCanvasRenderingTests.swift"] = " ".join(f"canvasOmitted{i}" for i in range(3))
    files["TXTCorePerformanceTests/TXTLargeFilePerformanceTests.swift"] = "perfExcluded0"

    counts = {
        "TXTCoreTests": 25,
        "ReaderDomainTests": 180,
        "TXTBlockDecoderTests": 6,
        "ProcessingReuseMeasurementTests": 1,
        "YueJingHostTests": 34,
        "YueJingUITests": 12,
        "YueJingCanvasTests": 3,
        "YueJingEPUBUITests": 3,
    }
    parameterized = {
        "epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime": {
            "signature": "(symlink:)",
            "argument": "symlink",
            "values": ["false", "true"],
        }
    }
    excluded = {"TXTCorePerformanceTests": "Independent baseline; excluded."}

    def fake_validate_source(root_arg=None):
        cases = {}
        for t in (*counts, *excluded):
            cases[t] = [
                n for p, ns in sorted(files.items())
                if r.inventory.group_for(p) == t for n in ns.split()
            ]
        return {
            "kind": "SOURCE_INVENTORY_NOT_NATIVE",
            "groups": dict(counts),
            "selected": sum(counts.values()),
            "execution_groups": {**counts, "ReaderDomainTests": counts["ReaderDomainTests"] + 1},
            "selected_executions": sum(counts.values()) + 1,
            "parameterized": dict(parameterized),
            "excluded": dict(excluded),
            "all_declared": sum(counts.values()) + 1,
            "native_executions": 0,
            "cases": cases,
        }

    def write_repo(repo_root, variant):
        assert variant in ("prior1", "prior2", "current")
        repo_root.mkdir(parents=True, exist_ok=True)
        for rel, names_str in files.items():
            names = names_str.split()
            target = rel.split("/", 1)[0]
            body = []
            if target in ("YueJingEPUBUITests", "YueJingUITests"):
                cls = "EPUBFlowUITests" if target == "YueJingEPUBUITests" else "ReadingFlowUITests"
                body.append(f"final class {cls}: XCTestCase {{")
                for n in names:
                    body.append(f"    @MainActor func {n}() {{}}")
                body.append("}")
            else:
                for n in names:
                    if n in parameterized:
                        body.append(f"@Test(arguments: [false, true]) func {n}(symlink: Bool) {{}}")
                    else:
                        body.append(f"@Test func {n}() {{}}")
            if variant in ("prior2", "current") and rel in (
                "ReaderDomainTests/EPUBAuthorStylesTests.swift",
                "YueJingHostTests/EPUBFontLoadingHostTests.swift",
            ):
                body.append("// prior2 repaired fixture")
            if variant == "current" and rel == "YueJingHostTests/EPUBReaderHostTests.swift":
                body.append("// current host-3 repaired fixture")
            p = repo_root / "Tests" / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("\n".join(body) + "\n", encoding="utf-8")

        for extra_rel, extra_text in (
            ("Sources/ReaderDomain/EPUB/EPUBAuthorStyles.swift", "public struct AuthorStyles {}\n"),
            ("App/EPUB/EPUBWebView.swift", "public struct EPUBWebView {}\n"),
            ("Tests/ReaderDomainTests/EPUBTestSupport.swift", "struct EPUBTestSupport {}\n"),
            ("scripts/run_epub_author_layout_validation.py", f"# {variant}\n"),
            ("scripts/check_epub_author_layout_validation.py", f"# check-{variant}\n"),
            (".github/workflows/task3-validate.yml", f"# wf-{variant}\n"),
        ):
            fp = repo_root / extra_rel
            fp.parent.mkdir(parents=True, exist_ok=True)
            fp.write_text(extra_text, encoding="utf-8")
        proj = repo_root / "project.yml"
        proj.write_text(
            f'name: YueJing\nsettings:\n  base:\n    MARKETING_VERSION: "{r.VERSION}"\n'
            f'    CURRENT_PROJECT_VERSION: "{r.BUILD}"\n    ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\n',
            encoding="utf-8",
        )
        allowed = [
            ".github/workflows/task3-validate.yml",
            "App/EPUB/EPUBWebView.swift",
            "Sources/ReaderDomain/EPUB/EPUBAuthorStyles.swift",
            "Tests/ReaderDomainTests/EPUBAuthorStyleMigrationTests.swift",
            "Tests/ReaderDomainTests/EPUBAuthorStylesTests.swift",
            "Tests/ReaderDomainTests/EPUBCompatibilityTests.swift",
            "Tests/ReaderDomainTests/EPUBContentPoolTests.swift",
            "Tests/ReaderDomainTests/EPUBLibraryTests.swift",
            "Tests/ReaderDomainTests/EPUBPackageTests.swift",
            "Tests/ReaderDomainTests/EPUBProgressTests.swift",
            "Tests/ReaderDomainTests/EPUBReadyTests.swift",
            "Tests/YueJingEPUBUITests/EPUBFlowUITests.swift",
            "Tests/YueJingHostTests/EPUBContentsNavigationTests.swift",
            "Tests/YueJingHostTests/EPUBFontLoadingHostTests.swift",
            "Tests/YueJingHostTests/EPUBReaderHostTests.swift",
            "project.yml",
            "scripts/check_epub_author_layout_validation.py",
            "scripts/epub_author_layout_scope.json",
            "scripts/run_epub_author_layout_validation.py",
        ]
        pinned = {
            "App/EPUB/EPUBWebView.swift": r.sha(repo_root / "App/EPUB/EPUBWebView.swift"),
            "Sources/ReaderDomain/EPUB/EPUBAuthorStyles.swift": r.sha(repo_root / "Sources/ReaderDomain/EPUB/EPUBAuthorStyles.swift"),
            "project.yml": r.sha(proj),
        }
        for _, rel, _ in domain_groups + host_groups:
            pinned["Tests/" + rel] = r.sha(repo_root / "Tests" / rel)
        pinned["Tests/YueJingEPUBUITests/EPUBFlowUITests.swift"] = r.sha(repo_root / "Tests/YueJingEPUBUITests/EPUBFlowUITests.swift")
        cfg = {
            "baseline": r.BASE,
            "scope": r.SCOPE,
            "version": r.VERSION,
            "build": r.BUILD,
            "allowed_paths": allowed,
            "candidate_sha256": pinned,
            "selected_files": selected_files,
        }
        cfg_path = repo_root / "scripts/epub_author_layout_scope.json"
        save(cfg_path, cfg)
        return cfg, cfg_path

    p1_repo = base_root / "p1-repo"
    p2_repo = base_root / "p2-repo"
    cur_repo = base_root / "cur-repo"
    p1_cfg, p1_cfg_path = write_repo(p1_repo, "prior1")
    p2_cfg, p2_cfg_path = write_repo(p2_repo, "prior2")
    cur_cfg, cur_cfg_path = write_repo(cur_repo, "current")

    def tree_for_dir(root_dir):
        return {
            p.relative_to(root_dir).as_posix(): ["100644", "blob", r.git_blob_sha1(p.read_bytes())]
            for p in sorted(root_dir.rglob("*")) if p.is_file()
        }

    p1_tree = tree_for_dir(p1_repo)
    p2_tree = tree_for_dir(p2_repo)
    cur_tree = tree_for_dir(cur_repo)
    base_tree = dict(p1_tree)
    base_tree["Sources/ReaderDomain/EPUB/EPUBAuthorStyles.swift"] = ["100644", "blob", r.git_blob_sha1(b"base-styles")]
    base_tree["project.yml"] = ["100644", "blob", r.git_blob_sha1(b"base-project")]

    _, scheme_path, domain_scheme_path = _write_xcode_sim_metadata(cur_repo)
    _write_xcode_sim_metadata(p2_repo)
    _write_xcode_sim_metadata(p1_repo)

    def write_common_archive_base(src_dir, run_id, src_commit):
        src_dir.mkdir(parents=True, exist_ok=True)
        (src_dir / "toolchain.log").write_text(
            f"Source: {src_commit}\narm64\nXcode 16.4\nBuild version 16F6\nApple Swift version 6.1.2\n",
            encoding="utf-8",
        )
        (src_dir / "xcodegen.log").write_text("Version: 2.46.0\n", encoding="utf-8")
        pins = [
            {"identity": k, "kind": "remoteSourceControl", "location": d["url"],
             "state": {"revision": d["revision"], "version": d["version"]}}
            for k, d in r.compat.epub_batch.DEPENDENCIES.items()
        ]
        save(src_dir / "Package.resolved", {"pins": pins, "version": 2})
        save(src_dir / "dependency-resolution.json", {"packages": packages_fixture()})
        eff = {
            "PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test",
            "SWIFT_VERSION": "6.0",
            "SWIFT_STRICT_CONCURRENCY": "complete",
            "IPHONEOS_DEPLOYMENT_TARGET": "16.6",
            "TEST_HOST": "",
            "BUNDLE_LOADER": "",
            "TEST_TARGET_NAME": "",
        }
        save(src_dir / "effective-test-settings.json", {"ReaderDomainTests": eff})
        save(src_dir / "simulator-selection.json", {
            "udid": DESTINATION.split("id=")[1],
            "device_name": "iPhone SE",
            "architecture": "arm64",
            "physical_device": False,
        })
        save(src_dir / "simulator-boot.json", {
            "source_commit": src_commit,
            "run_id": run_id,
            "run_attempt": "1",
            "exit_code": 0,
            "timed_out": False,
            "timeout_seconds": 120,
        })
        link = src_dir / "webkit-simulator-linkage"
        link.mkdir(parents=True)
        (link / "binary").write_bytes(b"synthetic-sim-macho-" + run_id.encode())
        save(link / "verification.json", {
            "source_commit": src_commit,
            "run_id": run_id,
            "run_attempt": "1",
            "passed": True,
            "errors": [],
            "binaries": [{
                "path": "YueJing",
                "evidence": "binary",
                "sha256": r.sha(link / "binary"),
                "passed": True,
                "nm_exit": 0,
            }],
        })

    def build_prior1_src(src_dir):
        write_common_archive_base(src_dir, prior1_id, prior1_sha)
        prior_ev = {
            "ref": "refs/heads/main",
            "repository": {"full_name": r.REPO},
            "inputs": {"validation_scope": r.SCOPE, "allow_unqualified_ipa": "false", "build_ipa": "true"},
        }
        save(src_dir / "dispatch-event.json", prior_ev)
        with patch.object(r.inventory, "FILES", files), \
             patch.object(r.inventory, "COUNTS", counts), \
             patch.object(r.inventory, "PARAMETERIZED", parameterized), \
             patch.object(r.inventory, "EXCLUDED", excluded), \
             patch.object(r.inventory, "validate_source", side_effect=fake_validate_source):
            p_groups = r.build_groups(p1_cfg)
            p_cand = r._candidate_files(p1_repo)
            p_inv = fake_validate_source(p1_repo)
            p_scope = {
                "scope": r.SCOPE, "phase": "validation", "prior_validation_run": "",
                "source_commit": prior1_sha, "source_status": "clean", "baseline_commit": r.BASE,
                "run_id": prior1_id, "run_attempt": "1", "repository": r.REPO, "ref": "refs/heads/main",
                "workflow_id": r.WORKFLOW_ID, "workflow_path": r.WORKFLOW_PATH,
                "version": r.VERSION, "build": r.BUILD, "allow_unqualified_ipa": False, "build_ipa": True,
                "dispatch_event_sha256": r.sha(src_dir / "dispatch-event.json"),
                "scope_config_sha256": r.sha(p1_cfg_path),
                "allowed_paths": p1_cfg["allowed_paths"], "candidate_sha256": p1_cfg["candidate_sha256"],
                "files": p_cand, "selected_files": p1_cfg["selected_files"],
                "selected": {g: list(s["cases"]) for g, s in p_groups.items()},
                "selected_declarations": 83, "native_tests_planned": 84,
                "full_inventory_declared": 264, "full_inventory_executions": 265,
            }
            save(src_dir / "candidate-sources.json", {
                "source_commit": prior1_sha, "run_id": prior1_id, "run_attempt": "1",
                "files": p_cand, "inventory": p_inv,
            })
            save(src_dir / "author-layout-scope.json", p_scope)
            for group, spec in p_groups.items():
                gdir = src_dir / "epub-author-layout" / group
                gdir.mkdir(parents=True)
                target = spec["target"]
                bundle = gdir / f"{target}.xcresult"
                (bundle / "Data").mkdir(parents=True)
                (bundle / "Info.plist").write_bytes(b"p1-xcresult")
                (bundle / "Data/data.0").write_bytes(b"p1-data")
                save(bundle / "synthetic-tests.json", tree_for(spec))
                save(bundle / "synthetic-summary.json", summary_for(spec))
                with patch.object(r, "xcresult_export", side_effect=synthetic_export):
                    r.retain_xcresult_exports(gdir, bundle)
                bundle_str = f"/Users/runner/work/YueJing/YueJing/artifacts/task3/epub-author-layout/{group}/{target}.xcresult"
                want = r.provenance(group, DESTINATION, bundle_str, p_scope, groups=p_groups)
                save(gdir / "selection.json", want)
                _write_exact_group_settings(spec["kind"], target, gdir, src_dir / "effective-test-settings.json", prior1_sha, scheme_path=scheme_path)
                if group in r.ELIGIBLE_PRIOR_REUSE_GROUPS:
                    save(gdir / "execution.json", {**want, "native_exit": 0, "timed_out": False})
                    raw = fixture_log(spec)
                    (gdir / f"{target}.log").write_bytes(raw)
                    parsed = r.parse_log(group, raw, 0, False, groups=p_groups)
                    with patch.object(r, "xcresult_export", side_effect=synthetic_export):
                        parsed["parameter_xcresult"] = r.parameter_evidence(group, gdir, bundle, group_specs=p_groups)
                    save(gdir / "counts.json", parsed)
                else:
                    save(gdir / "execution.json", {**want, "native_exit": 65, "timed_out": False})
                    (gdir / f"{target}.log").write_bytes(b"** TEST FAILED **\n")
                    save(gdir / "failure.json", {
                        "group": group, "target": target, "kind": spec["kind"],
                        "cases": list(spec["cases"]), "error": "prior1 failed/blocked",
                        "status": "error", "source_commit": prior1_sha, "run_id": prior1_id,
                    })
        return p_groups

    def zip_dir(src_dir, zip_path):
        zip_path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as arc:
            for p in sorted(src_dir.rglob("*")):
                if p.is_file():
                    arc.write(p, p.relative_to(src_dir).as_posix())
        return r.sha(zip_path)

    def make_api_files(out_dir, zip_path, run_id, src_commit, art_id, art_name):
        run_obj = {
            "id": int(run_id), "head_sha": src_commit, "run_attempt": 1,
            "workflow_id": r.WORKFLOW_ID, "path": r.WORKFLOW_PATH, "event": "workflow_dispatch",
            "head_branch": "main", "status": "completed", "conclusion": "failure",
            "repository": {"full_name": r.REPO}, "head_repository": {"full_name": r.REPO},
        }
        art_obj = {
            "id": art_id, "expired": False, "name": art_name,
            "workflow_run": {"id": int(run_id), "head_sha": src_commit},
            "size_in_bytes": zip_path.stat().st_size, "digest": "sha256:" + r.sha(zip_path),
        }
        run_p = out_dir / f"api-run-{run_id}.json"
        art_p = out_dir / f"api-artifact-{run_id}.json"
        save(run_p, run_obj)
        save(art_p, {"artifacts": [art_obj]})
        return run_obj, art_obj, run_p, art_p

    p1_src = base_root / "p1-src"
    full_groups = build_prior1_src(p1_src)
    p1_zip = base_root / "p1.zip"
    p1_zip_sha = zip_dir(p1_src, p1_zip)
    api_dir = base_root / "api-meta"
    p1_run_obj, p1_art_obj, p1_run_p, p1_art_p = make_api_files(
        api_dir, p1_zip, prior1_id, prior1_sha, r.PRIOR_ARTIFACT_ID, r.PRIOR_ARTIFACT_NAME
    )

    def build_prior2_src(src_dir):
        write_common_archive_base(src_dir, prior2_id, prior2_sha)
        ev2 = {
            "ref": "refs/heads/main",
            "repository": {"full_name": r.REPO},
            "inputs": {
                "validation_scope": r.SCOPE,
                "allow_unqualified_ipa": False,
                "build_ipa": True,
                "prior_validation_run": prior1_id,
            },
        }
        save(src_dir / "dispatch-event.json", ev2)
        with patch.object(r.inventory, "FILES", files), \
             patch.object(r.inventory, "COUNTS", counts), \
             patch.object(r.inventory, "PARAMETERIZED", parameterized), \
             patch.object(r.inventory, "EXCLUDED", excluded), \
             patch.object(r.inventory, "validate_source", side_effect=fake_validate_source):
            p2_groups = r.build_groups(p2_cfg)
            p1_fresh, p1_reused = r.partition_groups(p2_groups, prior1_id)
            p2_cand = r._candidate_files(p2_repo)
            p2_inv = fake_validate_source(p2_repo)
            p2_scope = {
                "scope": r.SCOPE, "phase": "validation",
                "prior_validation_run": prior1_id, "prior_source_commit": prior1_sha,
                "prior_artifact_id": r.PRIOR_ARTIFACT_ID, "prior_artifact_sha256": p1_zip_sha,
                "source_commit": prior2_sha, "source_status": "clean", "baseline_commit": r.BASE,
                "run_id": prior2_id, "run_attempt": "1", "repository": r.REPO, "ref": "refs/heads/main",
                "workflow_id": r.WORKFLOW_ID, "workflow_path": r.WORKFLOW_PATH,
                "version": r.VERSION, "build": r.BUILD, "allow_unqualified_ipa": False, "build_ipa": True,
                "dispatch_event_sha256": r.sha(src_dir / "dispatch-event.json"),
                "scope_config_sha256": r.sha(p2_cfg_path),
                "allowed_paths": p2_cfg["allowed_paths"], "candidate_sha256": p2_cfg["candidate_sha256"],
                "files": p2_cand, "selected_files": p2_cfg["selected_files"],
                "selected": {g: list(s["cases"]) for g, s in p2_groups.items()},
                "fresh_groups": p1_fresh, "reused_groups": p1_reused,
                "fresh_selected": {g: list(p2_groups[g]["cases"]) for g in p1_fresh},
                "reused_selected": {g: list(p2_groups[g]["cases"]) for g in p1_reused},
                "selected_declarations": 83, "native_tests_planned": 84,
                "fresh_declarations_planned": 28, "fresh_executions_planned": 28,
                "reused_declarations_planned": 55, "reused_executions_planned": 56,
                "full_inventory_declared": 264, "full_inventory_executions": 265,
            }
            save(src_dir / "candidate-sources.json", {
                "source_commit": prior2_sha, "run_id": prior2_id, "run_attempt": "1",
                "files": p2_cand, "inventory": p2_inv,
            })
            save(src_dir / "author-layout-scope.json", p2_scope)
            for group in p1_fresh:
                spec = p2_groups[group]
                gdir = src_dir / "epub-author-layout" / group
                gdir.mkdir(parents=True)
                target = spec["target"]
                bundle = gdir / f"{target}.xcresult"
                bundle_str = f"/Users/runner/work/YueJing/YueJing/artifacts/task3/epub-author-layout/{group}/{target}.xcresult"
                want = r.provenance(group, DESTINATION, bundle_str, p2_scope, groups=p2_groups)
                save(gdir / "selection.json", want)
                _write_exact_group_settings(spec["kind"], target, gdir, src_dir / "effective-test-settings.json", prior2_sha, scheme_path=scheme_path)
                if group in r.ELIGIBLE_PRIOR2_REUSE_GROUPS:
                    (bundle / "Data").mkdir(parents=True)
                    (bundle / "Info.plist").write_bytes(b"p2-xcresult")
                    (bundle / "Data/data.0").write_bytes(b"p2-data")
                    save(bundle / "synthetic-tests.json", tree_for(spec))
                    save(bundle / "synthetic-summary.json", summary_for(spec))
                    with patch.object(r, "xcresult_export", side_effect=synthetic_export):
                        r.retain_xcresult_exports(gdir, bundle)
                    save(gdir / "execution.json", {**want, "native_exit": 0, "timed_out": False})
                    raw = fixture_log(spec)
                    (gdir / f"{target}.log").write_bytes(raw)
                    parsed = r.parse_log(group, raw, 0, False, groups=p2_groups)
                    with patch.object(r, "xcresult_export", side_effect=synthetic_export):
                        parsed["parameter_xcresult"] = r.parameter_evidence(group, gdir, bundle, group_specs=p2_groups)
                    save(gdir / "counts.json", parsed)
                else:
                    # host-3 failed 2 cases (10 passed, 2 failed) - must NEVER be reused
                    save(gdir / "execution.json", {**want, "native_exit": 65, "timed_out": False})
                    lines = []
                    for idx_c, cn in enumerate(spec["cases"]):
                        lines.append(f"◇ Test {cn}() started.")
                        lines.append(f"{'✘' if idx_c >= 10 else '✔'} Test {cn}() {'failed' if idx_c >= 10 else 'passed'} after 0.1 seconds.")
                    (gdir / f"{target}.log").write_text("\n".join(lines) + "\n** TEST FAILED **\n", encoding="utf-8")
                    save(gdir / "failure.json", {
                        "group": group, "target": target, "kind": spec["kind"],
                        "cases": list(spec["cases"]), "error": "host-3 2 failed",
                        "status": "error", "source_commit": prior2_sha, "run_id": prior2_id,
                    })
        # Poisoned reused-evidence subtree & erroneous case-results.json like real 43158884847!
        # Non-recursion requires leaving these untouched and NEVER trusting them.
        save(src_dir / "reused-evidence/reused-prior-gate.json", {"poisoned": True, "passed": True})
        save(src_dir / "reused-evidence/author-layout-gate.json", {"poisoned": True})
        save(src_dir / "reused-evidence/prior-43153993787/evidence/epub-author-layout/domain-1/failure.json", {"poisoned": True})
        save(src_dir / "case-results.json", {"counts": {"passed": 26, "failed": 2, "error": 55}, "prior_reuse": {"status": "failed"}})
        (src_dir / "case-results.md").write_text("# erroneous report from 43158884847\n", encoding="utf-8")
        save(src_dir / "delivery-summary.json", {"package_qualification": "NOT_DELIVERABLE"})
        (src_dir / "reuse-evidence-check.log").write_text("ok\n", encoding="utf-8")
        return p2_groups

    p2_src = base_root / "p2-src"
    build_prior2_src(p2_src)
    p2_zip = base_root / "p2.zip"
    p2_zip_sha = zip_dir(p2_src, p2_zip)
    p2_run_obj, p2_art_obj, p2_run_p, p2_art_p = make_api_files(
        api_dir, p2_zip, prior2_id, prior2_sha, r.PRIOR2_ARTIFACT_ID, r.PRIOR2_ARTIFACT_NAME
    )

    @contextlib.contextmanager
    def sandbox(work_dir, *, build_ipa=True, prior_val=prior2_id, github_actions="false"):
        out_dir = work_dir / "out"
        out_dir.mkdir(parents=True, exist_ok=True)
        ev_path = work_dir / "event.json"
        save(ev_path, {
            "ref": "refs/heads/main",
            "repository": {"full_name": r.REPO},
            "workflow": r.WORKFLOW_PATH,
            "workflow_id": r.WORKFLOW_ID,
            "inputs": {
                "validation_scope": r.SCOPE,
                "allow_unqualified_ipa": False,
                "build_ipa": build_ipa,
                "prior_validation_run": prior_val,
            },
        })
        summary_md_path = work_dir / "step-summary.md"
        tree_state = {
            "base": copy.deepcopy(base_tree),
            "p1": copy.deepcopy(p1_tree),
            "p2": copy.deepcopy(p2_tree),
            "cur": copy.deepcopy(cur_tree),
            "status": b"",
            "p1_anc": True,
            "p2_anc": True,
        }
        p1_cfg_bytes = p1_cfg_path.read_bytes()
        p2_cfg_bytes = p2_cfg_path.read_bytes()

        def fake_git(*args, root=None):
            if args[:2] == ("rev-parse", "HEAD"):
                return (cur_sha + "\n").encode("utf-8")
            if args[0] == "status":
                return tree_state["status"]
            if args[:2] == ("show", f"{prior1_sha}:scripts/epub_author_layout_scope.json"):
                return p1_cfg_bytes
            if args[:2] == ("show", f"{prior2_sha}:scripts/epub_author_layout_scope.json"):
                return p2_cfg_bytes
            raise AssertionError("Unexpected git call: " + repr(args))

        def fake_tree(rev, root=None):
            if rev == r.BASE:
                return copy.deepcopy(tree_state["base"])
            if rev == prior1_sha:
                return copy.deepcopy(tree_state["p1"])
            if rev == prior2_sha:
                return copy.deepcopy(tree_state["p2"])
            return copy.deepcopy(tree_state["cur"])

        def fake_anc(base_arg, head_arg, root=None):
            if base_arg == prior1_sha:
                return tree_state["p1_anc"]
            if base_arg == prior2_sha:
                return tree_state["p2_anc"]
            return True

        def fake_validate_checkouts(pins, root_arg=None):
            r.compat.epub_batch.validate_pins(pins)
            return packages_fixture()

        def fake_api_ok(suffix):
            if suffix == f"/actions/runs/{prior1_id}":
                return dict(p1_run_obj)
            if suffix == f"/actions/artifacts/{r.PRIOR_ARTIFACT_ID}":
                return dict(p1_art_obj)
            if suffix == f"/actions/runs/{prior2_id}":
                return dict(p2_run_obj)
            if suffix == f"/actions/artifacts/{r.PRIOR2_ARTIFACT_ID}":
                return dict(p2_art_obj)
            raise AssertionError("Unexpected API suffix: " + suffix)

        def fake_dl(artifact_id, dest_path):
            src_zip = p1_zip if artifact_id == r.PRIOR_ARTIFACT_ID else p2_zip
            dest_path.parent.mkdir(parents=True, exist_ok=True)
            with dest_path.open("xb") as dst, src_zip.open("rb") as src:
                shutil.copyfileobj(src, dst)

        real_live = r.live_scope
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(r, "ROOT", cur_repo))
            stack.enter_context(patch.object(r, "OUT", out_dir))
            stack.enter_context(patch.object(r, "REUSED_STAGING", work_dir / "reused-downloads"))
            stack.enter_context(patch.object(r, "SCOPE_CONFIG_JSON", cur_cfg_path))
            stack.enter_context(patch.object(r, "PRIOR_ARTIFACT_SHA256", p1_zip_sha))
            stack.enter_context(patch.object(r, "PRIOR2_ARTIFACT_SHA256", p2_zip_sha))
            stack.enter_context(patch.object(r, "live_scope", side_effect=lambda root=cur_repo: real_live(root=root)))
            stack.enter_context(patch.object(r.inventory, "FILES", files))
            stack.enter_context(patch.object(r.inventory, "COUNTS", counts))
            stack.enter_context(patch.object(r.inventory, "PARAMETERIZED", parameterized))
            stack.enter_context(patch.object(r.inventory, "EXCLUDED", excluded))
            stack.enter_context(patch.object(r.inventory, "validate_source", side_effect=fake_validate_source))
            stack.enter_context(patch.object(r.compat, "git", side_effect=fake_git))
            stack.enter_context(patch.object(r.compat, "git_tree", side_effect=fake_tree))
            stack.enter_context(patch.object(r, "_git_is_ancestor", side_effect=fake_anc))
            stack.enter_context(patch.object(r.compat.epub_batch, "validate_checkouts", side_effect=fake_validate_checkouts))
            stack.enter_context(patch.object(r, "xcresult_export", side_effect=synthetic_export))
            stack.enter_context(patch.object(r, "github_api_json", side_effect=fake_api_ok))
            stack.enter_context(patch.object(r, "github_download_artifact_zip", side_effect=fake_dl))
            stack.enter_context(patch.dict(
                os.environ,
                GITHUB_ACTIONS=github_actions,
                VALIDATION_SCOPE=r.SCOPE,
                GITHUB_EVENT_NAME="workflow_dispatch",
                GITHUB_REF="refs/heads/main",
                GITHUB_RUN_ATTEMPT="1",
                GITHUB_REPOSITORY=r.REPO,
                GITHUB_WORKFLOW_REF=f"{r.REPO}/{r.WORKFLOW_PATH}@refs/heads/main",
                GITHUB_SHA=cur_sha,
                GITHUB_RUN_ID=cur_run_id,
                GITHUB_EVENT_PATH=str(ev_path),
                GITHUB_STEP_SUMMARY=str(summary_md_path),
                ALLOW_UNQUALIFIED_IPA="false",
                PRIOR_VALIDATION_RUN=prior_val,
                BUILD_IPA="true" if build_ipa else "false",
            ))
            yield out_dir, tree_state, summary_md_path

    return {
        "prior1_id": prior1_id,
        "prior1_sha": prior1_sha,
        "prior2_id": prior2_id,
        "prior2_sha": prior2_sha,
        "cur_sha": cur_sha,
        "cur_run_id": cur_run_id,
        "p1_repo": p1_repo,
        "p2_repo": p2_repo,
        "cur_repo": cur_repo,
        "p1_cfg": p1_cfg,
        "p2_cfg": p2_cfg,
        "cur_cfg": cur_cfg,
        "p1_tree": p1_tree,
        "p2_tree": p2_tree,
        "cur_tree": cur_tree,
        "p1_src": p1_src,
        "p2_src": p2_src,
        "p1_zip": p1_zip,
        "p1_zip_sha": p1_zip_sha,
        "p2_zip": p2_zip,
        "p2_zip_sha": p2_zip_sha,
        "p1_run_obj": p1_run_obj,
        "p1_art_obj": p1_art_obj,
        "p1_run_p": p1_run_p,
        "p1_art_p": p1_art_p,
        "p2_run_obj": p2_run_obj,
        "p2_art_obj": p2_art_obj,
        "p2_run_p": p2_run_p,
        "p2_art_p": p2_art_p,
        "scheme_path": scheme_path,
        "domain_scheme_path": domain_scheme_path,
        "full_groups": full_groups,
        "sandbox": sandbox,
        "zip_dir": zip_dir,
        "make_api_files": make_api_files,
        "tree_for_dir": tree_for_dir,
    }


def _write_current_common_and_exec_fresh(fx, out_dir, scope, *, executed_log=None):
    cur_sha = fx["cur_sha"]
    cur_run_id = fx["cur_run_id"]
    cur_repo = fx["cur_repo"]
    scheme_path = fx["scheme_path"]
    domain_scheme_path = fx["domain_scheme_path"]
    (out_dir / "toolchain.log").write_text(
        f"Source: {cur_sha}\narm64\nXcode 16.4\nBuild version 16F6\nApple Swift version 6.1.2\n",
        encoding="utf-8",
    )
    (out_dir / "xcodegen.log").write_text("Version: 2.46.0\n", encoding="utf-8")
    save(out_dir / "dependency-resolution.json", {"packages": packages_fixture()})
    eff_cur = {
        "PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test",
        "SWIFT_VERSION": "6.0",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "IPHONEOS_DEPLOYMENT_TARGET": "16.6",
        "TEST_HOST": "",
        "BUNDLE_LOADER": "",
        "TEST_TARGET_NAME": "",
    }
    save(out_dir / "effective-test-settings.json", {"ReaderDomainTests": eff_cur})
    save(out_dir / "simulator-selection.json", {
        "udid": DESTINATION.split("id=")[1],
        "device_name": "iPhone SE",
        "architecture": "arm64",
        "physical_device": False,
    })
    save(out_dir / "simulator-boot.json", {
        "source_commit": cur_sha,
        "run_id": cur_run_id,
        "run_attempt": "1",
        "exit_code": 0,
        "timed_out": False,
        "timeout_seconds": 120,
    })
    sim_link = out_dir / "webkit-simulator-linkage"
    sim_link.mkdir(parents=True, exist_ok=True)
    (sim_link / "binary").write_bytes(b"cur-sim-macho")
    save(sim_link / "verification.json", {
        "source_commit": cur_sha,
        "run_id": cur_run_id,
        "run_attempt": "1",
        "passed": True,
        "errors": [],
        "binaries": [{"path": "YueJing", "evidence": "binary", "sha256": r.sha(sim_link / "binary"), "passed": True, "nm_exit": 0}],
    })
    sim_app = cur_repo / "build/ReadingUIDerivedData/Build/Products/Debug-iphonesimulator/YueJing.app"
    sim_app.mkdir(parents=True, exist_ok=True)
    (sim_app / "YueJing").write_bytes(b"cur-sim-macho")

    def fake_exec_fresh(group, dest, checked_scope=None, groups=None):
        if executed_log is not None:
            executed_log.append(group)
        folder = out_dir / "epub-author-layout" / group
        folder.mkdir(parents=True, exist_ok=True)
        spec = groups[group]
        target = spec["target"]
        bundle = folder / f"{target}.xcresult"
        (bundle / "Data").mkdir(parents=True)
        (bundle / "Info.plist").write_bytes(b"synthetic")
        (bundle / "Data/data.0").write_bytes(b"synthetic")
        save(bundle / "synthetic-tests.json", tree_for(spec))
        save(bundle / "synthetic-summary.json", summary_for(spec))
        r.retain_xcresult_exports(folder, bundle)
        want = r.provenance(group, dest, bundle, scope, groups=groups)
        save(folder / "selection.json", want)
        save(folder / "execution.json", {**want, "native_exit": 0, "timed_out": False})
        _write_exact_group_settings(spec["kind"], target, folder, out_dir / "effective-test-settings.json", cur_sha, scheme_path=scheme_path, domain_scheme_path=domain_scheme_path)
        raw = fixture_log(spec)
        (folder / f"{target}.log").write_bytes(raw)
        parsed = r.parse_log(group, raw, 0, False, groups=groups)
        parsed["parameter_xcresult"] = r.parameter_evidence(group, folder, bundle, group_specs=groups)
        save(folder / "counts.json", parsed)

    return fake_exec_fresh


def check_cloud_summarize_and_qualification(root):
    """Actual GITHUB_ACTIONS=true integration tests for summarize(publish=True) + qualification() + delivery_gate()."""
    fx = _build_3commit_dual_origin_fixture(root / "cloud-fx")
    for prior_val, exp_fresh_groups, exp_fresh_decl, exp_reused_decl, exp_reused_exec in (
        (fx["prior1_id"], 7, 28, 55, 56),
        (fx["prior2_id"], 1, 12, 71, 72),
    ):
        with fx["sandbox"](root / f"cloud-pos-{prior_val}", build_ipa=True, prior_val=prior_val, github_actions="true") as (out_dir, tree_state, summary_md):
            scope = r.write_scope(fx["cur_repo"])
            # Before reuse runs, summarize reports not_verified without crashing
            rep_pre = r.summarize(publish=False)
            assert rep_pre["prior_reuse"]["status"] == "not_verified"
            assert rep_pre["counts"]["not_verified"] == exp_reused_decl
            assert rep_pre["counts"]["error"] == 0

            executed = []
            fake_exec = _write_current_common_and_exec_fresh(fx, out_dir, scope, executed_log=executed)
            reused_gate = r.reuse_evidence(require_dependencies=True, offline_prior=None, check_shared_sources=True, root=fx["cur_repo"])
            assert reused_gate["passed"] is True and reused_gate["qualified"] is True

            orig_vtd = r.compat.validate_toolchain_and_dependencies
            with patch.object(r.compat, "validate_toolchain_and_dependencies", side_effect=lambda rt, ot, check_live_tools=True: orig_vtd(rt, ot, check_live_tools=False)) as dep_spy, \
                 patch.object(r.compat, "validate_destination"), \
                 patch.object(r, "run_group", side_effect=fake_exec):
                assert r.run_all(DESTINATION) is True
                assert len(executed) == exp_fresh_groups
                assert dep_spy.call_count >= 1
            # Real cloud report step (`publish=True`) with full source/dependency/settings/xcresult verification!
            rep = r.summarize(publish=True)
            assert rep["prior_reuse"]["status"] == "passed", rep["prior_reuse"]
            assert rep["counts"]["error"] == 0
            assert rep["counts"]["reused"] == exp_reused_decl
            assert rep["counts"]["passed"] == exp_fresh_decl
            assert rep["native_tests_executed_this_run"] == exp_fresh_decl
            assert rep["reused_declarations"] == exp_reused_decl
            assert rep["reused_native_passed"] == exp_reused_exec
            assert rep["verified_declarations"] == 83 and rep["verified_passed"] == 84
            assert summary_md.is_file() and f"fresh this run {exp_fresh_decl} declarations" in summary_md.read_text(encoding="utf-8")

            qual = r.qualification()
            assert qual["passed"] is True
            assert qual["native_tests_executed_this_run"] == exp_fresh_decl
            assert qual["fresh_declarations_passed"] == exp_fresh_decl
            assert qual["reused_declarations"] == exp_reused_decl
            assert qual["reused_native_passed"] == exp_reused_exec
            assert qual["verified_declarations"] == 83 and qual["verified_passed"] == 84
            r.write(out_dir / "author-layout-gate.json", qual)
            assert r.validate_saved() == qual

            dev_app = root / f"cloud-dev-{prior_val}/YueJing.app"
            dev_app.mkdir(parents=True)
            (dev_app / "YueJing").write_bytes(b"cloud-dev-macho")
            (out_dir / "app-build.log").write_text("ok\n", encoding="utf-8")
            (out_dir / "app-build-exit-code.txt").write_text("0\n", encoding="utf-8")
            dev_link = out_dir / "webkit-device-linkage"
            dev_link.mkdir(parents=True)
            (dev_link / "binary").write_bytes(b"cloud-dev-macho")
            save(dev_link / "verification.json", {
                "source_commit": fx["cur_sha"], "run_id": fx["cur_run_id"], "run_attempt": "1",
                "passed": True, "errors": [],
                "binaries": [{"path": "YueJing", "evidence": "binary", "sha256": r.sha(dev_app / "YueJing"), "passed": True, "nm_exit": 0}],
            })
            with patch.object(r.v, "APP", dev_app):
                dg = r.delivery_gate()
                assert dg["strict_native_qualification"] == "passed"
                manifest = {
                    "source_commit": fx["cur_sha"], "version": r.VERSION, "build": r.BUILD,
                    "signing": "unsigned", "ipa_sha256": "c" * 64,
                }
                save(out_dir / "app-dependency-gate.json", {
                    "source_commit": fx["cur_sha"], "run_id": fx["cur_run_id"], "run_attempt": "1",
                    "signing": "unsigned", "packages": packages_fixture(),
                    "actual_images": [{"binary": "YueJing", "sha256": r.sha(dev_app / "YueJing")}],
                })
                pkg = r.complete_delivery(manifest, 16)
                assert pkg["ipa_integrity"] == "passed"
            passed(f"GITHUB_ACTIONS=true integration summarize+qualification+delivery passed (prior={prior_val})")

            # Cloud negative integration checks on the exact same cloud sandbox:
            # 1. Missing Package.resolved causes cloud summarize to reject (and qualification fails)
            res_p = fx["cur_repo"] / "YueJing.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            res_orig = res_p.read_bytes()
            res_p.unlink()
            rep_no_res = r.summarize(publish=False)
            assert rep_no_res["prior_reuse"]["status"] == "failed" and rep_no_res["counts"]["error"] == exp_reused_decl
            rejects(f"cloud missing Package.resolved blocks qualification ({prior_val})", r.qualification)
            res_p.write_bytes(res_orig)

            # 2. Missing author-layout-scope.json in cloud causes summarize to fail reuse
            sc_p = out_dir / "author-layout-scope.json"
            sc_orig = sc_p.read_bytes()
            sc_p.unlink()
            rep_no_sc = r.summarize(publish=False)
            assert rep_no_sc["prior_reuse"]["status"] == "failed" and rep_no_sc["counts"]["error"] == exp_reused_decl
            sc_p.write_bytes(sc_orig)

            # 3. Source tampering (dirty tree) caught in cloud summarize + qualification
            tree_state["status"] = b" M Sources/ReaderDomain/EPUB/EPUBAuthorStyles.swift\0"
            rep_dirty = r.summarize(publish=False)
            assert rep_dirty["prior_reuse"]["status"] == "failed" and rep_dirty["counts"]["error"] == exp_reused_decl
            rejects(f"cloud dirty tree blocks qualification ({prior_val})", r.qualification)
            tree_state["status"] = b""

            # 4. Live xcresult export drift caught in cloud summarize + qualification
            def drift_export(bundle, section):
                data = synthetic_export(bundle, section)
                if bundle.parent.name == "domain-3" and section == "summary":
                    doc = json.loads(data)
                    doc["skippedTests"] = 1
                    return json.dumps(doc).encode()
                return data
            with patch.object(r, "xcresult_export", side_effect=drift_export):
                rep_xc = r.summarize(publish=False)
                assert rep_xc["prior_reuse"]["status"] == "failed" and rep_xc["counts"]["error"] == exp_reused_decl
                rejects(f"cloud xcresult drift blocks qualification ({prior_val})", r.qualification)

            # 5. Missing reused-prior-gate.json while prior directory exists marks failed
            rg_p = out_dir / "reused-evidence/reused-prior-gate.json"
            rg_orig = rg_p.read_bytes()
            rg_p.unlink()
            rep_no_rg = r.summarize(publish=False)
            assert rep_no_rg["prior_reuse"]["status"] == "failed" and rep_no_rg["counts"]["error"] == exp_reused_decl
            rejects(f"cloud missing reused-prior-gate blocks qualification ({prior_val})", r.qualification)
            rg_p.write_bytes(rg_orig)
            passed(f"GITHUB_ACTIONS=true negative summarize+qualification checks passed (prior={prior_val})")


def check_dual_origin_reuse_and_mutations(root):
    """Full 3-commit dual-origin reuse (43158884847: 12 fresh + 71/72 reused = 83/84) + mutation matrix."""
    fx = _build_3commit_dual_origin_fixture(root / "dual-fx")
    p1_id, p1_sha = fx["prior1_id"], fx["prior1_sha"]
    p2_id, p2_sha = fx["prior2_id"], fx["prior2_sha"]
    cur_sha, cur_run_id = fx["cur_sha"], fx["cur_run_id"]
    cur_repo = fx["cur_repo"]
    full_groups = fx["full_groups"]

    # 1. Positive offline dual-origin end-to-end (including verify_source(prior=p1_id) and prior=p2_id!)
    src_p1_ok = None
    src_p2_ok = None
    with fx["sandbox"](root / "dual-pos-e2e", build_ipa=True, prior_val=p2_id, github_actions="false") as (out_dir, _, _):
        src_p1_ok = r.verify_source(pending=False, root=cur_repo, prior_validation_run=p1_id)
        src_p2_ok = r.verify_source(pending=False, root=cur_repo, prior_validation_run=p2_id)
        assert set(src_p1_ok["prior_origins_compat"]) == {p1_id}
        assert set(src_p2_ok["prior_origins_compat"]) == {p1_id, p2_id}
        assert src_p2_ok["prior_origins_compat"][p2_id]["changed_test_pins"] == ["Tests/YueJingHostTests/EPUBReaderHostTests.swift"]

        scope = r.write_scope(cur_repo)
        assert scope["prior_validation_run"] == p2_id
        assert scope["prior_source_commit"] == p2_sha
        assert scope["fresh_groups"] == ["host-3"]
        assert len(scope["reused_groups"]) == 13
        assert scope["fresh_declarations_planned"] == 12 and scope["fresh_executions_planned"] == 12
        assert scope["reused_declarations_planned"] == 71 and scope["reused_executions_planned"] == 72
        assert scope["selected_declarations"] == 83 and scope["native_tests_planned"] == 84
        assert [o["run_id"] for o in scope["prior_origins"]] == [p1_id, p2_id]
        assert scope["reused_group_origins"]["domain-1"] == p1_id
        assert scope["reused_group_origins"]["domain-2"] == p2_id
        assert scope["reused_group_origins"]["host-1"] == p2_id
        assert scope["reused_group_origins"]["ui-3"] == p2_id

        executed = []
        fake_exec = _write_current_common_and_exec_fresh(fx, out_dir, scope, executed_log=executed)
        offline = {
            p1_id: {"zip_path": fx["p1_zip"], "run_json": fx["p1_run_p"], "artifact_json": fx["p1_art_p"]},
            p2_id: {"zip_path": fx["p2_zip"], "run_json": fx["p2_run_p"], "artifact_json": fx["p2_art_p"]},
        }
        reused_gate = r.reuse_evidence(require_dependencies=True, offline_prior=offline, check_shared_sources=True, root=cur_repo)
        assert reused_gate["reused_declarations"] == 71 and reused_gate["reused_native_passed"] == 72
        assert len(reused_gate["prior_origins"]) == 2
        assert (out_dir / f"reused-evidence/prior-{p1_id}/archive.zip").read_bytes() == fx["p1_zip"].read_bytes()
        assert (out_dir / f"reused-evidence/prior-{p2_id}/archive.zip").read_bytes() == fx["p2_zip"].read_bytes()
        for rg in scope["reused_groups"]:
            rejects(f"dual-origin run_group rejects reused {rg}", lambda g=rg: r.run_group(g, DESTINATION, checked_scope=scope, groups=full_groups))
        rejects("dual-origin reuse refuses overwrite", lambda: r.reuse_evidence(require_dependencies=True, offline_prior=offline, check_shared_sources=True, root=cur_repo))
        # Require dual offline entries when prior_validation_run == p2_id
        rejects("dual-origin offline missing prior2 rejected", lambda: r.reuse_evidence(
            require_dependencies=False, offline_prior=offline[p1_id], check_shared_sources=True, root=cur_repo
        ))

        orig_vtd = r.compat.validate_toolchain_and_dependencies
        with patch.object(r.compat, "validate_toolchain_and_dependencies", side_effect=lambda rt, ot, check_live_tools=True: orig_vtd(rt, ot, check_live_tools=False)), \
             patch.object(r.compat, "validate_destination"), \
             patch.object(r, "run_group", side_effect=fake_exec):
            assert r.run_all(DESTINATION) is True
        assert executed == ["host-3"]
        for rg in scope["reused_groups"]:
            assert not (out_dir / "epub-author-layout" / rg).exists()

        rep = r.summarize()
        assert rep["native_tests_executed_this_run"] == 12
        assert rep["reused_declarations"] == 71 and rep["reused_native_passed"] == 72
        assert rep["verified_declarations"] == 83 and rep["verified_passed"] == 84
        assert rep["counts"]["passed"] == 12 and rep["counts"]["reused"] == 71 and rep["counts"]["error"] == 0
        md_text = (out_dir / "case-results.md").read_text(encoding="utf-8")
        assert "fresh this run 12 declarations (12 executions)" in md_text
        assert "reused 71 declarations (72 executions) from two pinned origins" in md_text
        assert f"reused:{p1_id}" in md_text and f"reused:{p2_id}" in md_text

        qual = r.qualification()
        assert qual["passed"] is True
        assert qual["native_tests_executed_this_run"] == 12
        assert qual["fresh_declarations_passed"] == 12
        assert qual["reused_declarations"] == 71 and qual["reused_native_passed"] == 72
        assert qual["verified_declarations"] == 83 and qual["verified_passed"] == 84
        assert qual["not_executed_this_run"] == 253
        assert qual["unselected_executions"] == 181
        assert len(qual["groups"]) == 1 and len(qual["reused_prior"]["groups"]) == 13
        assert len(qual["prior_origins"]) == 2
        r.write(out_dir / "author-layout-gate.json", qual)
        assert r.validate_saved() == qual

        dev_app = root / "dual-dev-app/YueJing.app"
        dev_app.mkdir(parents=True)
        (dev_app / "YueJing").write_bytes(b"dual-dev-macho")
        (out_dir / "app-build.log").write_text("ok\n", encoding="utf-8")
        (out_dir / "app-build-exit-code.txt").write_text("0\n", encoding="utf-8")
        dev_link = out_dir / "webkit-device-linkage"
        dev_link.mkdir(parents=True)
        (dev_link / "binary").write_bytes(b"dual-dev-macho")
        save(dev_link / "verification.json", {
            "source_commit": cur_sha, "run_id": cur_run_id, "run_attempt": "1",
            "passed": True, "errors": [],
            "binaries": [{"path": "YueJing", "evidence": "binary", "sha256": r.sha(dev_app / "YueJing"), "passed": True, "nm_exit": 0}],
        })
        with patch.object(r.v, "APP", dev_app):
            dg = r.delivery_gate()
            assert dg["reused_native_passed"] == 72 and dg["verified_passed"] == 84
            assert f"reused-evidence/prior-{p1_id}/archive.zip" in dg["evidence_sha256"]
            assert f"reused-evidence/prior-{p2_id}/archive.zip" in dg["evidence_sha256"]
            manifest = {
                "source_commit": cur_sha, "version": r.VERSION, "build": r.BUILD,
                "signing": "unsigned", "ipa_sha256": "f" * 64,
            }
            save(out_dir / "app-dependency-gate.json", {
                "source_commit": cur_sha, "run_id": cur_run_id, "run_attempt": "1",
                "signing": "unsigned", "packages": packages_fixture(),
                "actual_images": [{"binary": "YueJing", "sha256": r.sha(dev_app / "YueJing")}],
            })
            pkg = r.complete_delivery(manifest, 17)
            assert pkg["ipa_integrity"] == "passed" and pkg["reused_declarations"] == 71
        passed("dual-origin 12 fresh + 71/72 reused = 83/84 e2e + delivery verified (ignoring prior2 poisoned subtree)")

        # Negative gate/tamper checks on dual-origin positive sandbox:
        saved_gate_orig = (out_dir / "author-layout-gate.json").read_bytes()
        for label, mut in (
            ("dual gate forged native_tests_executed_this_run=28", lambda q: q.update(native_tests_executed_this_run=28)),
            ("dual gate forged reused_native_passed=56", lambda q: q.update(reused_native_passed=56)),
            ("dual gate forged reused_declarations=55", lambda q: q.update(reused_declarations=55)),
            ("dual gate forged proof_sha256", lambda q: q.update(prior_reuse_proof_sha256="0" * 64)),
        ):
            m = copy.deepcopy(qual)
            mut(m)
            save(out_dir / "author-layout-gate.json", m)
            rejects(label, r.validate_saved)
        (out_dir / "author-layout-gate.json").write_bytes(saved_gate_orig)

        # Non-recursion check: removing prior-43153993787 cannot be satisfied by 43158884847's reused-evidence/!
        shutil.move(out_dir / f"reused-evidence/prior-{p1_id}", root / "tmp-p1-bak")
        rejects("dual-origin missing prior1 rejected even with prior2 reused-evidence", r.qualification)
        shutil.move(root / "tmp-p1-bak", out_dir / f"reused-evidence/prior-{p1_id}")

        # Forged host-1 fresh directory alongside reused host-1 rejected
        (out_dir / "epub-author-layout/host-1").mkdir()
        rejects("dual-origin extra fresh host-1 rejected", r.qualification)
        (out_dir / "epub-author-layout/host-1").rmdir()

        # Host-3 settings drift vs reused host-1/ui-1 rejected
        h3_stg_p = out_dir / "epub-author-layout/host-3/YueJingHostTests-settings.json"
        h3_orig = h3_stg_p.read_bytes()
        h3_bad = json.loads(h3_orig)
        h3_bad["fixture_environment"] = "99999999-2222-3333-4444-555555555555"
        save(h3_stg_p, h3_bad)
        rejects("dual-origin fixture_environment drift vs host-3 rejected", lambda: r.verify_prior_reuse_saved(
            scope, packages_fixture(), current_effective_domain=load_json_safe(out_dir / "effective-test-settings.json")["ReaderDomainTests"],
            current_effective_host=h3_bad, root=cur_repo,
        ))
        h3_stg_p.write_bytes(h3_orig)

    # 2. Partial fresh failure in host-3 (10 pass, 2 fail) with prior_validation_run=43158884847
    with fx["sandbox"](root / "dual-partial-fail", build_ipa=False, prior_val=p2_id, github_actions="true") as (out_dir, _, _):
        scope = r.write_scope(cur_repo)
        _write_current_common_and_exec_fresh(fx, out_dir, scope)
        r.reuse_evidence(require_dependencies=True, offline_prior=None, check_shared_sources=True, root=cur_repo)
        exec_called = []
        def fail_host3(group, dest, checked_scope=None, groups=None):
            exec_called.append(group)
            folder = out_dir / "epub-author-layout" / group
            folder.mkdir(parents=True, exist_ok=True)
            spec = groups[group]
            target = spec["target"]
            want = r.provenance(group, dest, folder / f"{target}.xcresult", scope, groups=groups)
            save(folder / "selection.json", want)
            save(folder / "execution.json", {**want, "native_exit": 65, "timed_out": False})
            lines = []
            for idx_c, cn in enumerate(spec["cases"]):
                lines.append(f"◇ Test {cn}() started.")
                lines.append(f"{'✘' if idx_c >= 10 else '✔'} Test {cn}() {'failed' if idx_c >= 10 else 'passed'} after 0.1 seconds.")
            (folder / f"{target}.log").write_text("\n".join(lines) + "\n** TEST FAILED **\n", encoding="utf-8")
            raise ValueError("host-3 partial 2 failed")

        orig_vtd = r.compat.validate_toolchain_and_dependencies
        with patch.object(r.compat, "validate_toolchain_and_dependencies", side_effect=lambda rt, ot, check_live_tools=True: orig_vtd(rt, ot, check_live_tools=False)), \
             patch.object(r.compat, "validate_destination"), \
             patch.object(r, "run_group", side_effect=fail_host3):
            assert r.run_all(DESTINATION) is False
        assert exec_called == ["host-3"]
        rep = r.summarize(publish=True)
        assert rep["counts"]["reused"] == 71 and rep["counts"]["passed"] == 10 and rep["counts"]["failed"] == 2
        assert rep["native_tests_executed_this_run"] is None and rep["verified_passed"] is None
        rejects("dual-origin host-3 partial failure blocks qualification despite 72 reused pass", r.qualification)
        passed("dual-origin host-3 partial 10/2 failure isolated cleanly without relaxing gate")

    # 3. Dual-origin source compatibility negative matrix vs b99156e (prior2)
    p2_tree, cur_tree = fx["p2_tree"], fx["cur_tree"]
    p2_cfg, cur_cfg = fx["p2_cfg"], fx["cur_cfg"]
    for label, tree_mut, cfg_mut in (
        ("changed EPUBAuthorStylesTests vs b99156e",
         lambda t: t.__setitem__("Tests/ReaderDomainTests/EPUBAuthorStylesTests.swift", ["100644", "blob", r.git_blob_sha1(b"mut-styles")]),
         lambda c: None),
        ("changed EPUBFontLoadingHostTests vs b99156e",
         lambda t: t.__setitem__("Tests/YueJingHostTests/EPUBFontLoadingHostTests.swift", ["100644", "blob", r.git_blob_sha1(b"mut-font")]),
         lambda c: None),
        ("changed EPUBContentsNavigationTests vs b99156e",
         lambda t: t.__setitem__("Tests/YueJingHostTests/EPUBContentsNavigationTests.swift", ["100644", "blob", r.git_blob_sha1(b"mut-nav")]),
         lambda c: None),
        ("changed EPUBFlowUITests vs b99156e",
         lambda t: t.__setitem__("Tests/YueJingEPUBUITests/EPUBFlowUITests.swift", ["100644", "blob", r.git_blob_sha1(b"mut-ui")]),
         lambda c: None),
        ("changed EPUBTestSupport helper vs b99156e",
         lambda t: t.__setitem__("Tests/ReaderDomainTests/EPUBTestSupport.swift", ["100644", "blob", r.git_blob_sha1(b"mut-helper")]),
         lambda c: None),
        ("changed production EPUBAuthorStyles.swift vs b99156e",
         lambda t: t.__setitem__("Sources/ReaderDomain/EPUB/EPUBAuthorStyles.swift", ["100644", "blob", r.git_blob_sha1(b"mut-prod")]),
         lambda c: None),
        ("changed project.yml vs b99156e",
         lambda t: t.__setitem__("project.yml", ["100644", "blob", r.git_blob_sha1(b"mut-proj")]),
         lambda c: None),
        ("changed EPUBAuthorStylesTests pin vs b99156e",
         lambda t: None,
         lambda c: c["candidate_sha256"].__setitem__("Tests/ReaderDomainTests/EPUBAuthorStylesTests.swift", "0" * 64)),
        ("changed EPUBFontLoadingHostTests pin vs b99156e",
         lambda t: None,
         lambda c: c["candidate_sha256"].__setitem__("Tests/YueJingHostTests/EPUBFontLoadingHostTests.swift", "0" * 64)),
    ):
        t_mut = copy.deepcopy(cur_tree)
        c_mut = copy.deepcopy(cur_cfg)
        tree_mut(t_mut)
        cfg_mut(c_mut)
        rejects("dual-origin source compat " + label, lambda tm=t_mut, cm=c_mut: r.validate_prior_source_compatibility(
            p2_tree, tm, p2_cfg, cm, head=cur_sha, is_prior_ancestor=True,
            prior_commit=p2_sha, allowed_diff_paths=r.PRIOR2_REUSE_ALLOWED_DIFF_PATHS,
            changed_test_pins=r.PRIOR2_REUSE_CHANGED_TEST_PINS,
        ))
    rejects("dual-origin non-ancestor b99156e rejected", lambda: r.validate_prior_source_compatibility(
        p2_tree, cur_tree, p2_cfg, cur_cfg, head=cur_sha, is_prior_ancestor=False,
        prior_commit=p2_sha, allowed_diff_paths=r.PRIOR2_REUSE_ALLOWED_DIFF_PATHS,
        changed_test_pins=r.PRIOR2_REUSE_CHANGED_TEST_PINS,
    ))
    rejects("dual-origin unadvanced HEAD == b99156e rejected", lambda: r.validate_prior_source_compatibility(
        p2_tree, cur_tree, p2_cfg, cur_cfg, head=p2_sha, is_prior_ancestor=True,
        prior_commit=p2_sha, allowed_diff_paths=r.PRIOR2_REUSE_ALLOWED_DIFF_PATHS,
        changed_test_pins=r.PRIOR2_REUSE_CHANGED_TEST_PINS,
    ))

    # 4. Dual-origin API + archive + settings + UI + non-recursion negative mutation matrix on 43158884847
    p2_api_muts = [
        ("prior2 wrong head_sha", lambda rn, ar: rn.update(head_sha="0" * 40)),
        ("prior2 wrong run.id", lambda rn, ar: rn.update(id=111)),
        ("prior2 wrong run_attempt=2", lambda rn, ar: rn.update(run_attempt=2)),
        ("prior2 wrong artifact.id", lambda rn, ar: ar.update(id=999)),
        ("prior2 wrong artifact.digest", lambda rn, ar: ar.update(digest="sha256:" + "0" * 64)),
    ]
    for label, mut in p2_api_muts:
        rn_m = copy.deepcopy(fx["p2_run_obj"])
        ar_m = copy.deepcopy(fx["p2_art_obj"])
        mut(rn_m, ar_m)
        rejects("API " + label, lambda rn=rn_m, ar=ar_m: r.validate_prior_run_and_artifact(p2_id, rn, ar, p2_sha, cur_run_id))

    def bind_prior2_mut(src_dir, work_dir):
        zpath = work_dir / "p2-mut.zip"
        zsha = fx["zip_dir"](src_dir, zpath)
        rn, ar, _, _ = fx["make_api_files"](work_dir, zpath, p2_id, p2_sha, r.PRIOR2_ARTIFACT_ID, r.PRIOR2_ARTIFACT_NAME)
        folder = work_dir / f"prior-{p2_id}"
        folder.mkdir(parents=True)
        with (folder / "archive.zip").open("xb") as d, zpath.open("rb") as s:
            shutil.copyfileobj(s, d)
        save(folder / "api-run.json", rn)
        save(folder / "api-artifact.json", ar)
        mems = r.safe_zip_members(zpath)
        ret = r.extract_selected_members(zpath, mems, set(mems), folder / "evidence")
        save(folder / "archive-receipt.json", {
            "run_id": p2_id, "run_attempt": "1", "source_commit": p2_sha,
            "artifact_id": r.PRIOR2_ARTIFACT_ID, "artifact_name": r.PRIOR2_ARTIFACT_NAME,
            "archive_bytes": ar["size_in_bytes"], "archive_sha256": zsha,
            "member_count": len(mems), "members": mems, "retained_files": ret,
        })
        return folder, zsha

    p2_mutations = [
        ("own-member pre-existing author-layout-gate.json", lambda s: save(s / "author-layout-gate.json", {})),
        ("own-member reused-native-gate.json", lambda s: save(s / "reused-native-gate.json", {})),
        ("host-3 missing failure.json", lambda s: (s / "epub-author-layout/host-3/failure.json").unlink()),
        ("host-3 forged counts.json (cannot reuse partial)", lambda s: save(s / "epub-author-layout/host-3/counts.json", {"passed": []})),
        ("missing domain-2 group", lambda s: shutil.rmtree(s / "epub-author-layout/domain-2")),
        ("missing ui-2 group", lambda s: shutil.rmtree(s / "epub-author-layout/ui-2")),
        ("domain-2 failure.json present", lambda s: save(s / "epub-author-layout/domain-2/failure.json", {"error": "fail"})),
        ("host-1 nonzero exit", lambda s: save(s / "epub-author-layout/host-1/execution.json", {**r.load(s / "epub-author-layout/host-1/execution.json"), "native_exit": 65})),
        ("host-2 missing stdout.json", lambda s: (s / "epub-author-layout/host-2/YueJingHostTests-YueJingHostTests-settings.stdout.json").unlink()),
        ("host-1 settings exit code 1", lambda s: (s / "epub-author-layout/host-1/YueJingHostTests-YueJing-settings-exit-code.txt").write_text("1\n", encoding="utf-8")),
        ("host-1 stdout JSON value drift", lambda s: save(s / "epub-author-layout/host-1/YueJingHostTests-YueJingHostTests-settings.stdout.json", [{"target": "YueJingHostTests", "buildSettings": {"PRODUCT_TYPE": "wrong"}}])),
        ("host-1 missing settings key", lambda s: (lambda d: (d["targets"]["YueJing"].pop("TEST_TARGET_NAME"), save(s / "epub-author-layout/host-1/YueJingHostTests-settings.json", d)))(r.load(s / "epub-author-layout/host-1/YueJingHostTests-settings.json"))),
        ("host-1 wrong TEST_HOST", lambda s: (lambda d: (d["targets"]["YueJingHostTests"].update(TEST_HOST="/tmp/Fake.app/Fake", BUNDLE_LOADER="/tmp/Fake.app/Fake"), save(s / "epub-author-layout/host-1/YueJingHostTests-settings.json", d)))(r.load(s / "epub-author-layout/host-1/YueJingHostTests-settings.json"))),
        ("host-1 BUNDLE_LOADER != TEST_HOST", lambda s: (lambda d: (d["targets"]["YueJingHostTests"].update(BUNDLE_LOADER="/other/YueJing.app/YueJing"), save(s / "epub-author-layout/host-1/YueJingHostTests-settings.json", d)))(r.load(s / "epub-author-layout/host-1/YueJingHostTests-settings.json"))),
        ("ui-1 missing DEBUG active condition", lambda s: (lambda d: (d["targets"]["YueJing"].update(SWIFT_ACTIVE_COMPILATION_CONDITIONS=""), save(s / "epub-author-layout/ui-1/YueJingEPUBUITests-settings.json", d)))(r.load(s / "epub-author-layout/ui-1/YueJingEPUBUITests-settings.json"))),
        ("ui-1 wrong TEST_TARGET_NAME", lambda s: (lambda d: (d["targets"]["YueJingEPUBUITests"].update(TEST_TARGET_NAME="Other"), save(s / "epub-author-layout/ui-1/YueJingEPUBUITests-settings.json", d)))(r.load(s / "epub-author-layout/ui-1/YueJingEPUBUITests-settings.json"))),
        ("ui-1 log unexpected Swift event", lambda s: (s / "epub-author-layout/ui-1/YueJingEPUBUITests.log").write_bytes((s / "epub-author-layout/ui-1/YueJingEPUBUITests.log").read_bytes() + b"\xe2\x9c\x94 Test extra() passed after 0.1 seconds.\n")),
        ("ui-3 xcresult skipped summary", lambda s: save(s / "epub-author-layout/ui-3/xcresult-summary.json", {**r.load(s / "epub-author-layout/ui-3/xcresult-summary.json"), "skippedTests": 1})),
        ("prior2 scope prior_validation_run != 43153993787", lambda s: save(s / "author-layout-scope.json", {**r.load(s / "author-layout-scope.json"), "prior_validation_run": "999"})),
        ("prior2 dispatch-event prior_validation_run wrong", lambda s: (lambda d: (d["inputs"].update(prior_validation_run=""), save(s / "dispatch-event.json", d)))(r.load(s / "dispatch-event.json"))),
    ]
    for idx, (label, mut) in enumerate(p2_mutations):
        wdir = root / f"p2-mut-{idx}"
        sdir = wdir / "src"
        shutil.copytree(fx["p2_src"], sdir)
        mut(sdir)
        folder, zsha = bind_prior2_mut(sdir, wdir)
        with fx["sandbox"](wdir / "sb", prior_val=p2_id, github_actions="false"):
            scope = r.write_scope(cur_repo)
            with patch.object(r, "PRIOR2_ARTIFACT_SHA256", zsha):
                def check_p2(fld=folder, sc=scope):
                    res = r.inspect_prior2_evidence(fld, sc, root=cur_repo, expected_packages=packages_fixture())
                    r.require(res["passed"], "; ".join(res["errors"]))
                rejects("prior2 mutation " + label, check_p2)

    passed("dual-origin positive + full source/archive/settings/UI/non-recursion negative matrix verified")


def load_json_safe(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def check_processes(root):
    p_dir = root / "proc"
    p_dir.mkdir(parents=True, exist_ok=True)
    assert r.stream_case([sys.executable, "-c", 'print("ok")'], p_dir / "ok.log", 10) == (0, False)
    assert r.stream_case([sys.executable, "-c", "raise SystemExit(7)"], p_dir / "fail.log", 10) == (7, False)
    code, expired = r.stream_case([sys.executable, "-c", "import time; time.sleep(20)"], p_dir / "timeout.log", 0.2)
    assert expired and code != 0
    assert r.stream_case([sys.executable, "-c", 'print("after")'], p_dir / "after.log", 10) == (0, False)
    passed("local Python stream_case success/failure/timeout/next")


def run_checks(root):
    assert (r.SCOPE, r.BASE, r.VERSION, r.BUILD) == (
        "epub-author-layout",
        "cb749e62b4b468d7077cceaaba7bcd626294a269",
        "0.2.16",
        "18",
    )
    assert r.WORKFLOW_ID == 398234793 and r.REPO == "wan780839395-cyber/YueJing"

    live_source_status = "skipped_scope_config_not_frozen_yet"
    if r.SCOPE_CONFIG_JSON.is_file() or os.environ.get("GITHUB_ACTIONS") == "true":
        src = r.verify_source(pending=os.environ.get("GITHUB_ACTIONS") != "true", prior_validation_run=os.environ.get("PRIOR_VALIDATION_RUN", ""))
        live_source_status = src["source_status"]
        passed("live scope source check: " + live_source_status)

    wf_status = "skipped_workflow_not_wired_yet"
    wf_text = (r.ROOT / r.WORKFLOW_PATH).read_text(encoding="utf-8")
    if "epub_author_layout" in wf_text or os.environ.get("GITHUB_ACTIONS") == "true":
        prefix, job = wf_text.split("  epub_author_layout:", 1)
        assert "run_epub_author_layout_validation.py" not in prefix
        assert "check_epub_author_layout_validation.py" not in prefix
        for token in (
            r.SCOPE,
            "timeout-minutes: 60",
            "contents: read",
            "actions: read",
            "GH_TOKEN: ${{ github.token }}",
            "persist-credentials: false",
            "fetch-depth: 0",
            "PRIOR_VALIDATION_RUN: ${{ inputs.prior_validation_run }}",
            "run_epub_author_layout_validation.py scope",
            "run_epub_author_layout_validation.py reuse",
            "inputs.prior_validation_run != ''",
            "inputs.prior_validation_run == '' || steps.reuse.outcome == 'success'",
            "run_epub_author_layout_validation.py run-all",
            "run_epub_author_layout_validation.py report",
            "run_epub_author_layout_validation.py gate",
            "if: always()",
            "check_webkit_linkage.py",
            "package-gate-epub-author-layout",
            "verify-ipa-epub-author-layout",
            "artifacts/task3/reuse-evidence-check.log",
            "artifacts/task3/author-layout-gate.json",
            "artifacts/task3/delivery-summary.json",
            "fresh_native_executed",
            "fresh_declarations_passed",
            "reused_native_passed",
            "prior_reuse_proof_sha256",
            "prior_origins",
            "case_results",
        ):
            assert token in job, "Missing epub_author_layout workflow contract token: " + token
        wf_status = "passed"
        passed("workflow epub_author_layout contract")

    with patch.dict(os.environ, GITHUB_ACTIONS="false"):
        check_config_and_grouping(root)
        check_parsers(root)
        check_xcresult_and_bool(root)
        check_source_and_dispatch(root)
        check_scheduler_and_report(root)
        check_qualification_and_delivery(root)
        check_processes(root)
        check_prior_reuse_and_mutations(root)
        check_cloud_summarize_and_qualification(root)
        check_dual_origin_reuse_and_mutations(root)

    return live_source_status, wf_status

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    scratch = os.environ.get("PI_SCRATCH_DIR") or os.environ.get("RUNNER_TEMP")
    if not scratch:
        raise SystemExit("PI_SCRATCH_DIR (local) or RUNNER_TEMP (Actions) is required")
    root = Path(tempfile.mkdtemp(prefix="author-layout-check-", dir=scratch))
    print("Retained synthetic checks/fixtures: " + str(root), flush=True)
    try:
        with (root / "checks.log").open("w", encoding="utf-8") as log, contextlib.redirect_stdout(log):
            live_source_status, wf_status = run_checks(root)
        report = {
            "passed": True,
            "checks": len(checks),
            "labels": checks,
            "native_executions": 0,
            "evidence_kind": "SYNTHETIC_GATE_CHECKS_NOT_NATIVE_ACCEPTANCE",
            "physical_acceptance": "not performed",
            "scope": r.SCOPE,
            "live_source_check": live_source_status,
            "workflow_check": wf_status,
        }
        save(root / "checks.json", report)
        print(json.dumps({k: v for k, v in report.items() if k != "labels"}, indent=2))
    except BaseException:
        (root / "failure.txt").write_text(traceback.format_exc(), encoding="utf-8")
        save(root / "checks.json", {"passed": False, "checks": len(checks), "labels": checks, "native_executions": 0})
        raise

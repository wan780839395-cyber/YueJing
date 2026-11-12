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
import subprocess
import sys
import tempfile
import traceback
from unittest.mock import patch

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
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
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
        src = r.verify_source(pending=os.environ.get("GITHUB_ACTIONS") != "true")
        live_source_status = src["source_status"]
        passed("live scope source check: " + live_source_status)

    wf_status = "skipped_workflow_not_wired_yet"
    wf_text = (r.ROOT / r.WORKFLOW_PATH).read_text(encoding="utf-8")
    if "epub_author_layout" in wf_text or os.environ.get("GITHUB_ACTIONS") == "true":
        assert r.SCOPE in wf_text and "run_epub_author_layout_validation.py" in wf_text
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

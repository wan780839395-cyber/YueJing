"""Offline synthetic checks ONLY: no native execution, Git writes, or cloud calls."""
import ast
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import run_epub_paging_validation as paging
import check_epub_compat_validation as fixtures

SHA = "a" * 40
RUN = "987654321"
DEST = fixtures.SYNTHETIC_DEST


def make_log(group, names=None):
    """Synthetic event fixture; never presented as native test evidence."""
    names = paging.group_expected_names(group) if names is None else names
    lines = []
    for name in names:
        if group == "host":
            lines += [f"◇ Test {name}() started.", f"✔ Test {name}() passed after 0.05 seconds."]
        else:
            identity = f"YueJingEPUBUITests.EPUBFlowUITests {name}"
            lines += [f"Test Case '-[{identity}]' started.", f"Test Case '-[{identity}]' passed (0.05 seconds)."]
    if group == "host":
        lines += ["✔ Test run with 4 tests passed after 0.5 seconds."]
    else:
        lines += ["Test Suite 'EPUBFlowUITests' passed at 2026-11-04 01:00:00.",
                  "Executed 2 tests, with 0 failures (0 unexpected) in 0.5 seconds.",
                  "Test Suite 'Selected tests' passed at 2026-11-04 01:00:00.",
                  "Executed 2 tests, with 0 failures (0 unexpected) in 0.5 seconds.",
                  "✔ Test run with 0 tests passed after 0.001 seconds."]
    return ("\n".join(lines + ["** TEST SUCCEEDED **"]) + "\n").encode("utf-8")


def scope_fixture():
    # Deliberately independent of project.yml integration state in the checkout.
    base = b"name: synthetic-scope-fixture\n" + paging.OLD_VERSION_LINES
    current_project = base.replace(paging.OLD_VERSION_LINES, paging.NEW_VERSION_LINES)
    previous = {"Sources/Untouched.swift": ["100644", "blob", "1" * 40]}
    current = copy.deepcopy(previous)
    for i, path in enumerate(sorted(paging.ALLOWED), 100):
        if path not in paging.NEW_ALLOWED:
            previous[path] = ["100644", "blob", f"{i:040x}"]
        current[path] = ["100644", "blob", f"{i + 1000:040x}"]
    previous["project.yml"][2] = paging.git_blob_sha1(base)
    current["project.yml"][2] = paging.git_blob_sha1(current_project)
    env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
           "GITHUB_RUN_ATTEMPT": "1", "VALIDATION_SCOPE": paging.SCOPE,
           "GITHUB_SHA": SHA, "GITHUB_RUN_ID": RUN}
    return dict(previous=previous, current=current, base_project_bytes=base,
                current_project_bytes=current_project, env=env, head=SHA,
                worktree_blobs={p: v[2] for p, v in current.items()})


class EPUBPagingChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="epub-paging-offline-", dir=os.environ.get("PI_SCRATCH_DIR"))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        guard = patch("subprocess.Popen", side_effect=AssertionError("Offline checks forbid subprocess/native execution"))
        guard.start()
        self.addCleanup(guard.stop)

    def test_selection_commands_inventory_and_legacy_state(self):
        legacy = {k: copy.deepcopy(getattr(paging.compat, k))
                  for k in ("BASE", "SCOPE", "ALLOWED", "NEW_ALLOWED", "GROUP_SPECS", "SELECTED_FILES")}
        summary = paging.validate_selected_cases()
        self.assertEqual((summary["total"], summary["host"], summary["ui"], summary["full_inventory"]), (6, 4, 2, 214))
        self.assertEqual(paging.BASE, "99ed6461b9d2b680abf94258658279e8a6e3bf90")
        self.assertEqual((len(paging.ALLOWED), len(paging.NEW_ALLOWED)), (14, 4))
        self.assertLessEqual(paging.NEW_ALLOWED, paging.ALLOWED)
        for group, count, budget in (("host", 4, 480), ("ui", 2, 1200)):
            cmd = paging.expected_command(group, DEST, "synthetic.xcresult")
            flags = [a for a in cmd if a.startswith("-only-testing:")]
            self.assertEqual(flags, ["-only-testing:" + n for n in paging.case_identifiers(group)])
            self.assertEqual(len(flags), count)
            self.assertTrue(all(f.count("/") == 2 for f in flags))
            self.assertEqual(all(f.endswith("()") for f in flags), group == "host")
            self.assertFalse(any(a.startswith(("-skip-testing", "-retry-tests", "-test-iterations")) for a in cmd))
            for key, value in (("-scheme", "YueJingUI"), ("-configuration", "Debug"),
                               ("-parallel-testing-enabled", "NO"), ("-default-test-execution-time-allowance", "180"),
                               ("-maximum-test-execution-time-allowance", "180")):
                self.assertEqual(cmd[cmd.index(key) + 1], value)
            for flag in ("-disableAutomaticPackageResolution", "-skipPackageUpdates",
                         "-onlyUsePackageVersionsFromResolvedFile", "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64"):
                self.assertIn(flag, cmd)
            self.assertEqual(paging.GROUP_SPECS[group]["timeout_seconds"], budget)
            with self.assertRaises(ValueError):
                paging.expected_command(group, DEST.replace("iOS Simulator", "iOS"), "bad.xcresult")
        self.assertEqual(legacy, {k: getattr(paging.compat, k) for k in legacy})
        for name in ("run_epub_paging_validation.py", "check_epub_paging_validation.py"):
            ast.parse((SCRIPT_DIR / name).read_text(encoding="utf-8"))

    def test_scope_version_and_retry_descendant_boundaries(self):
        good = scope_fixture()
        receipt = paging.validate_scope_boundaries(**good)
        self.assertEqual(receipt["selected_groups"], {"host": 4, "ui": 2})
        self.assertEqual((receipt["version"], receipt["build"]), ("0.2.3", "5"))
        # A later allowed descendant is valid against the SAME fixed baseline.
        descendant = copy.deepcopy(good)
        descendant["head"] = descendant["env"]["GITHUB_SHA"] = "b" * 40
        descendant["current"]["App/EPUB/EPUBWebView.swift"][2] = "c" * 40
        descendant["worktree_blobs"]["App/EPUB/EPUBWebView.swift"] = "c" * 40
        self.assertEqual(paging.validate_scope_boundaries(**descendant)["baseline_commit"], paging.BASE)
        variants = []
        for path in ("Sources/Untouched.swift", "App/Unapproved.swift", "scripts/run_epub_compat_validation.py"):
            bad = copy.deepcopy(good)
            bad["current"][path] = ["100644", "blob", "f" * 40]
            bad["worktree_blobs"][path] = "f" * 40
            variants.append(bad)
        for path in ("Sources/Untouched.swift", "docs/EPUB_PAGING.md"):
            bad = copy.deepcopy(good)
            del bad["current"][path]
            del bad["worktree_blobs"][path]
            variants.append(bad)
        for key, value in (("GITHUB_EVENT_NAME", "push"), ("GITHUB_REF", "refs/heads/other"),
                           ("GITHUB_RUN_ATTEMPT", "2"), ("VALIDATION_SCOPE", "epub-compat-33"),
                           ("GITHUB_SHA", paging.BASE), ("GITHUB_RUN_ID", "0")):
            bad = copy.deepcopy(good)
            bad["env"][key] = value
            variants.append(bad)
        for kwargs in ({"status": b" M project.yml"}, {"is_ancestor": False}, {"head": "d" * 40}):
            variants.append({**good, **kwargs})
        bad = copy.deepcopy(good)
        bad["worktree_blobs"]["Sources/Untouched.swift"] = "f" * 40
        variants.append(bad)
        bad = copy.deepcopy(good)
        bad["current"]["project.yml"][0] = "120000"
        variants.append(bad)
        for bad in variants:
            with self.assertRaises(ValueError):
                paging.validate_scope_boundaries(**bad)
        for bad_project in (good["base_project_bytes"], good["current_project_bytes"] + b"# extra\n",
                            good["current_project_bytes"].replace(b'"5"', b'"6"'),
                            good["current_project_bytes"].replace(b"\n", b"\r\n")):
            with self.assertRaises(ValueError):
                paging.validate_project_version(good["base_project_bytes"], bad_project)

    def test_mixed_events_and_failure_precedence(self):
        for group in ("host", "ui"):
            names = paging.group_expected_names(group)
            good = make_log(group)
            self.assertEqual(paging.parse_group_log(group, good, 0, False)["passed"], names)
            variants = [make_log(group, names[:-1]), make_log(group, names + [names[0]]),
                        make_log(group, names + ["testUnexpected"]), good.replace(b"passed", b"failed", 1),
                        good.replace(b"passed", b"skipped", 1), good.replace(b"started.", b"interrupted.", 1),
                        good.replace(b"** TEST SUCCEEDED **", b"** TEST FAILED **"),
                        good + b"Suite synthetic failed after 0.1 seconds.\n",
                        good + b"Test Case '-[OtherTests testAlien]' passed (0.1 seconds).\n",
                        good + b"Test alienCase() recorded an issue at File.swift:1: assertion failed\n",
                        good + b"Test alienCase() started.\nTest alienCase() passed after 0.1 seconds.\n"]
            if group == "host":
                variants += [good + f"Test {names[0]}() recorded an issue at File.swift:1: assertion failed\n".encode(),
                             good + b"Test run with 4 tests passed after 0.1 seconds.\n",
                             good.replace(b"with 4 tests", b"with 3 tests")]
                warning = ("2026-11-03 01:03:26.162225+0000 YueJing[13720:50426] Unbalanced calls to begin/end "
                           "appearance transitions for <YueJing.ReaderViewController: 0x1049b1a00>.")
                split = good.decode().replace(f"Test {names[0]}() started.",
                                             f"Test {names[0][:6]}{warning}\n{names[0][6:]}() started.").encode()
                self.assertEqual(len(paging.parse_group_log(group, split, 0, False)["events"]["derived_starts"]), 1)
            else:
                variants += [good.replace(b"with 0 failures", b"with 1 failure"),
                             good.replace(b"Executed 2 tests", b"Executed 3 tests"),
                             good.replace(b"with 0 failures", b"1 test skipped and 0 failures"),
                             good.replace(b"with 0 tests passed", b"with 1 test passed"),
                             good.replace(b"EPUBFlowUITests", b"ReadingFlowUITests")]
            for raw in variants:
                with self.assertRaises(ValueError, msg=f"Accepted invalid {group} fixture: {raw!r}"):
                    paging.parse_group_log(group, raw, 0, False)
            for code, timeout in ((65, False), (-9, True), (0, True), (False, False)):
                with self.assertRaises(ValueError):
                    paging.parse_group_log(group, good, code, timeout)

    @contextlib.contextmanager
    def synthetic_run(self, code=0, timed_out=False):
        root, out, files, _, packages = fixtures.setup_synthetic_environment(self.root)
        receipt = paging.validate_scope_boundaries(**scope_fixture())
        calls = []

        def settings(target, folder, source_commit):
            cfg = {"SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete", "IPHONEOS_DEPLOYMENT_TARGET": "16.6"}
            test = ({"PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test",
                     "TEST_HOST": "/synthetic/YueJing.app/YueJing", "BUNDLE_LOADER": "/synthetic/YueJing.app/YueJing"}
                    if target == "YueJingHostTests" else
                    {"PRODUCT_TYPE": "com.apple.product-type.bundle.ui-testing", "TEST_TARGET_NAME": "YueJing"})
            scheme = root / "YueJing.xcodeproj/xcshareddata/xcschemes/YueJingUI.xcscheme"
            paging.write_new(folder / f"{target}-settings.json", {
                "source_commit": source_commit, "scheme_sha256": paging.digest_path(scheme),
                "testables": sorted(paging.ui.GROUPS), "fixture_environment": "D052AE4B-7823-447E-BE63-986028A7F54C",
                "targets": {"YueJing": {**cfg, "PRODUCT_TYPE": "com.apple.product-type.application",
                                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"}, target: {**cfg, **test}},
            })

        def stream(command, log, budget):
            group = "host" if log.name.startswith("YueJingHostTests") else "ui"
            calls.append((group, budget))
            log.write_bytes(make_log(group))
            result = Path(command[command.index("-resultBundlePath") + 1])
            result.mkdir()
            (result / "Info.plist").write_text("SYNTHETIC NOT NATIVE", encoding="utf-8")
            return code, timed_out

        # Replace ONLY this new module's dependency references; legacy module
        # globals remain untouched even while synthetic execution is in scope.
        with (patch.multiple(paging, ROOT=root, OUT=out, EPUB_OUT=out / "epub-paging",
                             SCOPE_JSON=out / "epub-paging-scope.json", GATE_JSON=out / "epub-paging-gate.json"),
              patch.object(paging, "verify_scope", return_value=receipt),
              patch.object(paging, "validate_toolchain_and_dependencies", return_value=packages),
              patch.object(paging, "validator", SimpleNamespace(candidate_files=lambda: files)),
              patch.object(paging, "ui", SimpleNamespace(GROUPS=paging.ui.GROUPS, actual_settings=settings, stream_native=stream)),
              contextlib.redirect_stdout(io.StringIO())):
            yield out, calls

    def test_run_gate_saved_and_provenance_tampering(self):
        with self.synthetic_run() as (out, calls):
            paging.main(["scope"])
            with self.assertRaises(ValueError):
                paging.validate_saved()
            for group in ("host", "ui"):
                paging.main(["run", group, "--destination", DEST])
            self.assertEqual(calls, [("host", 480), ("ui", 1200)])
            with self.assertRaises(ValueError):
                paging.run_group("host", DEST)
            paging.main(["gate"])
            result = paging.validate_saved()
            self.assertEqual(result["qualification"], "EPUB_PAGING_6_TARGETED_NATIVE")
            self.assertEqual((result["verified_passed"], result["host_passed"], result["ui_passed"]), (6, 4, 2))
            self.assertEqual(result["not_executed_this_run"], 208)
            self.assertFalse(result["full_regression_executed_this_run"])
            self.assertEqual(len(result["groups"]), 2)
            with self.assertRaises(FileExistsError):
                paging.gate()
            gate = out / "epub-paging-gate.json"
            original = gate.read_bytes()
            for field, value in (("verified_passed", 214), ("coverage", "FULL"), ("run_id", "1"), ("source_commit", "f" * 40)):
                forged = json.loads(original)
                forged[field] = value
                gate.write_text(json.dumps(forged), encoding="utf-8")
                with self.assertRaises(ValueError):
                    paging.validate_saved()
            gate.write_bytes(original)
            for group, spec in paging.GROUP_SPECS.items():
                folder = out / "epub-paging" / group
                for kind in ("selection", "execution", "counts"):
                    path = folder / f"{spec['target']}-{kind}.json"
                    saved = path.read_bytes()
                    for field, value in (("source_commit", "f" * 40), ("run_id", "2"), ("run_attempt", "2"),
                                         ("command", ["xcodebuild", "test"]), ("destination", DEST.replace("abc", "aaa")),
                                         ("case_identifiers", []), ("timeout_seconds", 9999), ("case_timeout_seconds", 181)):
                        forged = json.loads(saved)
                        forged[field] = value
                        path.write_text(json.dumps(forged), encoding="utf-8")
                        with self.assertRaises(ValueError):
                            paging.validate_saved()
                    path.write_bytes(saved)
                for suffix in (".log", "-source-hashes.json", "-settings.json", "-exit-code.txt"):
                    path = folder / (spec["target"] + suffix)
                    saved = path.read_bytes()
                    path.write_bytes(b"{}" if suffix.endswith(".json") else b"65\n")
                    with self.assertRaises(ValueError):
                        paging.validate_saved()
                    path.write_bytes(saved)
                info = folder / f"{spec['target']}.xcresult/Info.plist"
                saved = info.read_bytes()
                info.unlink()
                with self.assertRaises(ValueError):
                    paging.validate_saved()
                info.write_bytes(saved)
            self.assertEqual(paging.validate_saved(), result)

    def test_failed_run_preserves_receipts_and_prevents_retry(self):
        with self.synthetic_run(code=65) as (out, calls):
            paging.scope()
            with self.assertRaises(ValueError):
                paging.run_group("host", DEST)
            folder = out / "epub-paging/host"
            self.assertTrue((folder / "YueJingHostTests.log").is_file())
            self.assertEqual(paging.load_json(folder / "YueJingHostTests-execution.json")["native_exit"], 65)
            self.assertFalse((folder / "YueJingHostTests-counts.json").exists())
            with self.assertRaises(ValueError):
                paging.run_group("host", DEST)
            with self.assertRaises(ValueError):
                paging.gate()
            self.assertEqual(calls, [("host", 480)])

    def test_timeout_preserves_execution_without_counts(self):
        with self.synthetic_run(code=-9, timed_out=True) as (out, calls):
            paging.scope()
            with self.assertRaises(ValueError):
                paging.run_group("ui", DEST)
            folder = out / "epub-paging/ui"
            self.assertTrue(paging.load_json(folder / "YueJingEPUBUITests-execution.json")["timed_out"])
            self.assertFalse((folder / "YueJingEPUBUITests-counts.json").exists())
            self.assertEqual(calls, [("ui", 1200)])


def run_self_check():
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(EPUBPagingChecks)
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    if not result.wasSuccessful():
        sys.stderr.write(stream.getvalue())
        raise ValueError(f"EPUB paging offline checks failed: {len(result.failures)} failures, {len(result.errors)} errors")
    return {"kind": "OFFLINE_EPUB_PAGING_SELF_CHECK_NOT_NATIVE", "passed": True,
            "tests_run": result.testsRun, "selected_cases": 6, "host_cases": 4, "ui_cases": 2,
            "full_inventory": 214, "whitelist_paths": 14, "native_executions": 0}


if __name__ == "__main__":
    try:
        print(json.dumps(run_self_check(), indent=2))
    except Exception as error:
        print("EPUB paging offline self-check failed: " + str(error), file=sys.stderr)
        sys.exit(1)

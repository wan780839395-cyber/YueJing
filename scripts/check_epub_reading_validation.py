"""Offline synthetic runner-contract checks only; never native qualification or IPA evidence."""
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

import run_epub_reading_validation as reading
import check_epub_compat_validation as fixtures

SHA = "a" * 40
RUN = "987654321"
DEST = fixtures.SYNTHETIC_DEST


def make_log(group, names=None):
    """Synthetic event fixture, NOT evidence of native execution."""
    names = reading.group_expected_names(group) if names is None else names
    count = reading.GROUP_SPECS[group]["expected_count"]
    lines = []
    for name in names:
        if group != "ui":
            lines += [f"◇ Test {name}() started.", f"✔ Test {name}() passed after 0.05 seconds."]
        else:
            identity = f"YueJingEPUBUITests.EPUBFlowUITests {name}"
            lines += [f"Test Case '-[{identity}]' started.", f"Test Case '-[{identity}]' passed (0.05 seconds)."]
    if group != "ui":
        lines += [f"✔ Test run with {count} tests passed after 0.5 seconds."]
    else:
        for suite in ("EPUBFlowUITests", "Selected tests"):
            lines += [f"Test Suite '{suite}' passed at 2026-11-04 01:00:00.",
                      f"Executed {count} tests, with 0 failures (0 unexpected) in 0.5 seconds."]
        lines += ["✔ Test run with 0 tests passed after 0.001 seconds."]
    return ("\n".join(lines + ["** TEST SUCCEEDED **"]) + "\n").encode("utf-8")


def scope_fixture():
    base = b"name: synthetic-scope-fixture\n" + reading.OLD_VERSION_LINES
    project = base.replace(reading.OLD_VERSION_LINES, reading.NEW_VERSION_LINES)
    previous = {"Sources/Untouched.swift": ["100644", "blob", "1" * 40]}
    current = copy.deepcopy(previous)
    for i, path in enumerate(sorted(reading.ALLOWED), 100):
        if path not in reading.NEW_ALLOWED:
            previous[path] = ["100644", "blob", f"{i:040x}"]
        current[path] = ["100644", "blob", f"{i + 1000:040x}"]
    previous["project.yml"][2] = reading.git_blob_sha1(base)
    current["project.yml"][2] = reading.git_blob_sha1(project)
    env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
           "GITHUB_RUN_ATTEMPT": "1", "VALIDATION_SCOPE": reading.SCOPE,
           "GITHUB_SHA": SHA, "GITHUB_RUN_ID": RUN}
    return dict(previous=previous, current=current, base_project_bytes=base,
                current_project_bytes=project, env=env, head=SHA,
                worktree_blobs={p: v[2] for p, v in current.items()})


class EPUBReadingChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="epub-reading-offline-", dir=os.environ.get("PI_SCRATCH_DIR"))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        guard = patch("subprocess.Popen", side_effect=AssertionError("Offline checks forbid subprocess/native execution"))
        guard.start()
        self.addCleanup(guard.stop)
        self.legacy = {m: {k: copy.deepcopy(getattr(m, k)) for k in
                          ("ROOT", "OUT", "BASE", "SCOPE", "ALLOWED", "NEW_ALLOWED", "GROUP_SPECS", "SELECTED_FILES")}
                       for m in (reading.compat, reading.paging)}
        self.addCleanup(self.check_legacy)

    def check_legacy(self):
        for module, values in self.legacy.items():
            self.assertEqual(values, {k: getattr(module, k) for k in values})

    def test_selection_commands_and_inventory(self):
        summary = reading.validate_selected_cases()
        self.assertEqual([summary[k] for k in ("total", "domain", "host", "ui", "full_inventory")], [15, 8, 4, 3, 214])
        self.assertEqual(reading.BASE, "63a68c3d0776ec8084156f16ccd43537f79eaf24")
        self.assertEqual((len(reading.ALLOWED), len(reading.NEW_ALLOWED)), (29, 11))
        self.assertLessEqual(reading.NEW_ALLOWED, reading.ALLOWED)
        self.assertEqual(reading.SELECTED_FILES["YueJingHostTests/EPUBReaderHostTests.swift"],
                         reading.paging.SELECTED_FILES["YueJingHostTests/EPUBReaderHostTests.swift"])
        self.assertEqual(list(reading.SELECTED_FILES["YueJingEPUBUITests/EPUBFlowUITests.swift"]),
                         reading.inventory.FILES["YueJingEPUBUITests/EPUBFlowUITests.swift"].split())
        self.assertEqual([len(reading.SELECTED_FILES[f]) for f in reading.GROUP_SPECS["domain"]["files"]], [3, 1, 4])
        self.assertEqual({s["derived_data"] for s in reading.GROUP_SPECS.values()},
                         {"build/ReadingUIDerivedData"})
        for group, count, budget in (("domain", 8, 480), ("host", 4, 480), ("ui", 3, 1200)):
            cmd = reading.expected_command(group, DEST, "synthetic.xcresult")
            flags = [a for a in cmd if a.startswith("-only-testing:")]
            self.assertEqual(flags, ["-only-testing:" + n for n in reading.case_identifiers(group)])
            self.assertEqual(len(flags), count)
            self.assertTrue(all(f.count("/") == 2 for f in flags))
            self.assertEqual(all(f.endswith("()") for f in flags), group != "ui")
            self.assertFalse(any(a.startswith(("-skip-testing", "-retry-tests", "-test-iterations")) for a in cmd))
            for key, value in (("-scheme", "ReaderDomain" if group == "domain" else "YueJingUI"),
                               ("-configuration", "Debug"), ("-parallel-testing-enabled", "NO"),
                               ("-default-test-execution-time-allowance", "180"),
                               ("-maximum-test-execution-time-allowance", "180")):
                self.assertEqual(cmd[cmd.index(key) + 1], value)
            for flag in ("-disableAutomaticPackageResolution", "-skipPackageUpdates",
                         "-onlyUsePackageVersionsFromResolvedFile", "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64"):
                self.assertIn(flag, cmd)
            self.assertEqual(reading.GROUP_SPECS[group]["timeout_seconds"], budget)
            with self.assertRaises(ValueError):
                reading.expected_command(group, DEST.replace("iOS Simulator", "iOS"), "bad.xcresult")
        with self.assertRaises(ValueError):
            reading.group_expected_names("unknown")
        for name in ("run_epub_reading_validation.py", "check_epub_reading_validation.py"):
            ast.parse((SCRIPT_DIR / name).read_text(encoding="utf-8"))

    def test_source_inventory_rejects_changed_extra_and_missing_identity(self):
        for source in (reading.ROOT / "Tests").rglob("*.swift"):
            target = self.root / source.relative_to(reading.ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
        reading.validate_selected_cases(self.root)
        path = self.root / "Tests/ReaderDomainTests/EPUBProgressTests.swift"
        original = path.read_bytes()
        name = reading.group_expected_names("domain")[-1].encode()
        for replacement in (original.replace(name, b"unknownReadingCase"),
                            original + b"\n@Test func unknownReadingCase() {}\n", b""):
            path.write_bytes(replacement)
            with self.assertRaises(ValueError):
                reading.validate_selected_cases(self.root)
        path.write_bytes(original)

    def test_scope_version_and_fresh_descendant_boundaries(self):
        good = scope_fixture()
        receipt = reading.validate_scope_boundaries(**good)
        self.assertEqual(receipt["selected_groups"], {"domain": 8, "host": 4, "ui": 3})
        self.assertEqual((receipt["version"], receipt["build"]), ("0.2.4", "6"))
        descendant = copy.deepcopy(good)
        descendant["head"] = descendant["env"]["GITHUB_SHA"] = "b" * 40
        descendant["env"]["GITHUB_RUN_ID"] = "987654322"
        descendant["current"]["App/EPUB/EPUBWebView.swift"][2] = "c" * 40
        descendant["worktree_blobs"]["App/EPUB/EPUBWebView.swift"] = "c" * 40
        self.assertEqual(reading.validate_scope_boundaries(**descendant)["baseline_commit"], reading.BASE)
        variants = []
        for path in ("Sources/Untouched.swift", "App/Unapproved.swift", "scripts/run_epub_paging_validation.py"):
            bad = copy.deepcopy(good)
            bad["current"][path] = ["100644", "blob", "f" * 40]
            bad["worktree_blobs"][path] = "f" * 40
            variants.append(bad)
        for path in ("Sources/Untouched.swift", "docs/EPUB_READING_MODES.md"):
            bad = copy.deepcopy(good)
            del bad["current"][path]
            del bad["worktree_blobs"][path]
            variants.append(bad)
        bad = copy.deepcopy(good)
        bad["previous"]["App/AppVersion.swift"] = bad["current"]["App/AppVersion.swift"]
        variants.append(bad)
        for key, value in (("GITHUB_EVENT_NAME", "push"), ("GITHUB_REF", "refs/heads/other"),
                           ("GITHUB_RUN_ATTEMPT", "2"), ("VALIDATION_SCOPE", "epub-paging-6"),
                           ("GITHUB_SHA", reading.BASE), ("GITHUB_RUN_ID", "0")):
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
                reading.validate_scope_boundaries(**bad)
        for project in (good["base_project_bytes"], good["current_project_bytes"] + b"# extra\n",
                        good["current_project_bytes"].replace(b'"6"', b'"7"'),
                        good["current_project_bytes"].replace(b"\n", b"\r\n")):
            with self.assertRaises(ValueError):
                reading.validate_project_version(good["base_project_bytes"], project)

    def test_all_fifteen_event_chains_and_failure_precedence(self):
        for group, spec in reading.GROUP_SPECS.items():
            names = reading.group_expected_names(group)
            good = make_log(group)
            self.assertEqual(reading.parse_group_log(group, good, 0, False)["passed"], names)
            variants = [make_log(group, names[:-1]), make_log(group, names + [names[0]]),
                        make_log(group, names + ["testUnexpected"]), good.replace(b"passed", b"failed", 1),
                        good.replace(b"passed", b"skipped", 1), good.replace(b"started.", b"interrupted.", 1),
                        good.replace(b"** TEST SUCCEEDED **", b"** TEST FAILED **"),
                        good + b"Suite synthetic failed after 0.1 seconds.\n",
                        good + b"Test Case '-[OtherTests testAlien]' passed (0.1 seconds).\n",
                        good + b"Test alienCase() recorded an issue at File.swift:1: assertion failed\n",
                        good + b"Test alienCase() started.\nTest alienCase() passed after 0.1 seconds.\n"]
            rows = good.splitlines(keepends=True)
            variants += [b"".join([rows[1], rows[0], *rows[2:]]), b"".join([rows[0], *rows])]
            if group != "ui":
                variants += [good + f"Test {names[0]}() recorded an issue at File.swift:1: assertion failed\n".encode(),
                             good + f"Test run with {spec['expected_count']} tests passed after 0.1 seconds.\n".encode(),
                             good.replace(f"with {spec['expected_count']} tests".encode(), b"with 15 tests")]
                warning = ("2026-11-03 01:03:26.162225+0000 YueJing[13720:50426] Unbalanced calls to begin/end "
                           "appearance transitions for <YueJing.ReaderViewController: 0x1049b1a00>.")
                split = good.decode().replace(f"Test {names[0]}() started.",
                                             f"Test {names[0][:6]}{warning}\n{names[0][6:]}() started.").encode()
                self.assertEqual(len(reading.parse_group_log(group, split, 0, False)["events"]["derived_starts"]), 1)
            else:
                variants += [good.replace(b"with 0 failures", b"with 1 failure"),
                             good.replace(b"Executed 3 tests", b"Executed 2 tests"),
                             good.replace(b"with 0 failures", b"1 test skipped and 0 failures"),
                             good.replace(b"with 0 tests passed", b"with 1 test passed"),
                             good.replace(b"EPUBFlowUITests", b"ReadingFlowUITests")]
            for raw in variants:
                with self.assertRaises(ValueError, msg=f"Accepted invalid {group} fixture: {raw!r}"):
                    reading.parse_group_log(group, raw, 0, False)
            for code, timeout in ((65, False), (-9, True), (0, True), (False, False)):
                with self.assertRaises(ValueError):
                    reading.parse_group_log(group, good, code, timeout)

    @contextlib.contextmanager
    def synthetic_run(self, code=0, timed_out=False):
        root, out, files, _, packages = fixtures.setup_synthetic_environment(self.root)
        receipt = reading.validate_scope_boundaries(**scope_fixture())
        calls = []

        def settings(target, folder, source_commit):
            self.assertNotEqual(target, "ReaderDomainTests")
            cfg = {"SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete", "IPHONEOS_DEPLOYMENT_TARGET": "16.6"}
            test = ({"PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test",
                     "TEST_HOST": "/synthetic/YueJing.app/YueJing", "BUNDLE_LOADER": "/synthetic/YueJing.app/YueJing"}
                    if target == "YueJingHostTests" else
                    {"PRODUCT_TYPE": "com.apple.product-type.bundle.ui-testing", "TEST_TARGET_NAME": "YueJing"})
            scheme = root / "YueJing.xcodeproj/xcshareddata/xcschemes/YueJingUI.xcscheme"
            reading.write_new(folder / f"{target}-settings.json", {
                "source_commit": source_commit, "scheme_sha256": reading.digest_path(scheme),
                "testables": sorted(reading.ui.GROUPS), "fixture_environment": "D052AE4B-7823-447E-BE63-986028A7F54C",
                "targets": {"YueJing": {**cfg, "PRODUCT_TYPE": "com.apple.product-type.application",
                                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"}, target: {**cfg, **test}},
            })

        def stream(command, log, budget):
            group = next(g for g, s in reading.GROUP_SPECS.items() if log.name == s["target"] + ".log")
            calls.append((group, budget))
            log.write_bytes(make_log(group))
            result = Path(command[command.index("-resultBundlePath") + 1])
            result.mkdir()
            (result / "Info.plist").write_text("SYNTHETIC NOT NATIVE", encoding="utf-8")
            return code, timed_out

        # Only the new runner's references are replaced. Domain settings use
        # the real shared helper with explicit root/out and real fixture files.
        with (patch.multiple(reading, ROOT=root, OUT=out, EPUB_OUT=out / "epub-reading",
                             SCOPE_JSON=out / "epub-reading-scope.json", GATE_JSON=out / "epub-reading-gate.json"),
              patch.object(reading, "verify_scope", return_value=receipt),
              patch.object(reading, "validate_toolchain_and_dependencies", return_value=packages),
              patch.object(reading, "validator", SimpleNamespace(candidate_files=lambda: files)),
              patch.object(reading, "ui", SimpleNamespace(GROUPS=reading.ui.GROUPS, actual_settings=settings, stream_native=stream)),
              contextlib.redirect_stdout(io.StringIO())):
            yield out, calls

    def test_run_gate_saved_read_only_and_tampering(self):
        with self.synthetic_run() as (out, calls):
            reading.main(["scope"])
            with self.assertRaises(ValueError):
                reading.validate_saved()
            for group in reading.GROUP_SPECS:
                reading.main(["run", group, "--destination", DEST])
            self.assertEqual(calls, [("domain", 480), ("host", 480), ("ui", 1200)])
            with self.assertRaises(ValueError):
                reading.run_group("domain", DEST)
            reading.main(["gate"])
            result = reading.validate_saved()
            self.assertEqual(result["qualification"], "EPUB_READING_15_TARGETED_NATIVE")
            self.assertEqual(result["coverage"], "EPUB_READING_TARGETED_NOT_FULL")
            self.assertEqual([result[k] for k in ("verified_passed", "domain_passed", "host_passed", "ui_passed")], [15, 8, 4, 3])
            self.assertEqual(result["not_executed_this_run"], 199)
            self.assertFalse(result["full_regression_executed_this_run"])
            self.assertEqual(len(result["groups"]), 3)
            with self.assertRaises(FileExistsError):
                reading.gate()
            before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.root.rglob("*") if p.is_file()}
            with (patch.object(reading, "write_new", side_effect=AssertionError("Saved validation must not write")),
                  patch.object(reading, "prepare_group_settings", side_effect=AssertionError("Must not regenerate settings"))):
                self.assertEqual(reading.validate_saved(), result)
            self.assertEqual(before, {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.root.rglob("*") if p.is_file()})
            gate = out / "epub-reading-gate.json"
            self.assert_json_tamper(gate, [("verified_passed", 214), ("coverage", "FULL"), ("run_id", "1"),
                                          ("source_commit", "f" * 40), ("groups", result["groups"][:-1])])
            self.assert_json_tamper(out / "epub-reading-scope.json", [("run_id", "2"), ("source_commit", "f" * 40)])
            extra = out / "epub-reading/extra"
            extra.mkdir()
            with self.assertRaises(ValueError):
                reading.validate_saved()
            extra.rmdir()
            for group, spec in reading.GROUP_SPECS.items():
                folder = out / "epub-reading" / group
                for kind in ("selection", "execution", "counts"):
                    self.assert_json_tamper(folder / f"{spec['target']}-{kind}.json", [
                        ("source_commit", "f" * 40), ("run_id", "2"), ("run_attempt", "2"), ("group", "other"),
                        ("command", ["xcodebuild", "test"]), ("destination", DEST.replace("abc", "aaa")),
                        ("case_identifiers", []), ("suites", []), ("timeout_seconds", 9999), ("case_timeout_seconds", 181)])
                for suffix in (".log", "-source-hashes.json", "-settings.json", "-exit-code.txt"):
                    path = folder / (spec["target"] + suffix)
                    saved = path.read_bytes()
                    path.write_bytes(b"{}" if suffix.endswith(".json") else b"65\n")
                    with self.assertRaises(ValueError):
                        reading.validate_saved()
                    path.write_bytes(saved)
                info = folder / f"{spec['target']}.xcresult/Info.plist"
                saved = info.read_bytes()
                info.unlink()
                with self.assertRaises(ValueError):
                    reading.validate_saved()
                info.write_bytes(saved)
            self.assert_json_tamper(out / "effective-test-settings.json", [("ReaderDomainTests", {})])
            self.assert_json_tamper(out / "simulator-selection.json", [("physical_device", True)])
            with patch.object(reading, "verify_scope", side_effect=ValueError("live source/env drift")):
                with self.assertRaises(ValueError):
                    reading.validate_saved()
            with patch.object(reading, "validate_toolchain_and_dependencies", side_effect=ValueError("dependency drift")):
                with self.assertRaises(ValueError):
                    reading.validate_saved()
            self.assertEqual(reading.validate_saved(), result)

    def assert_json_tamper(self, path, changes):
        saved = path.read_bytes()
        try:
            for field, value in changes:
                forged = json.loads(saved)
                forged[field] = value
                path.write_text(json.dumps(forged), encoding="utf-8")
                with self.assertRaises(ValueError, msg=f"Accepted tampering: {path}:{field}"):
                    reading.validate_saved()
        finally:
            path.write_bytes(saved)

    def test_failed_run_preserves_receipts_and_prevents_retry(self):
        with self.synthetic_run(code=65) as (out, calls):
            reading.scope()
            with self.assertRaises(ValueError):
                reading.run_group("domain", DEST)
            folder = out / "epub-reading/domain"
            self.assertTrue((folder / "ReaderDomainTests.log").is_file())
            self.assertEqual(reading.load_json(folder / "ReaderDomainTests-execution.json")["native_exit"], 65)
            self.assertFalse((folder / "ReaderDomainTests-counts.json").exists())
            before = {p: p.read_bytes() for p in folder.rglob("*") if p.is_file()}
            with self.assertRaises(ValueError):
                reading.run_group("domain", DEST)
            with self.assertRaises(ValueError):
                reading.gate()
            self.assertEqual(before, {p: p.read_bytes() for p in folder.rglob("*") if p.is_file()})
            self.assertEqual(calls, [("domain", 480)])

    def test_timeout_preserves_execution_without_counts(self):
        with self.synthetic_run(code=-9, timed_out=True) as (out, calls):
            reading.scope()
            with self.assertRaises(ValueError):
                reading.run_group("ui", DEST)
            folder = out / "epub-reading/ui"
            self.assertTrue(reading.load_json(folder / "YueJingEPUBUITests-execution.json")["timed_out"])
            self.assertFalse((folder / "YueJingEPUBUITests-counts.json").exists())
            self.assertEqual(calls, [("ui", 1200)])


def run_self_check():
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(EPUBReadingChecks)
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    if not result.wasSuccessful():
        sys.stderr.write(stream.getvalue())
        raise ValueError(f"EPUB reading offline checks failed: {len(result.failures)} failures, {len(result.errors)} errors")
    return {"kind": "OFFLINE_EPUB_READING_SELF_CHECK_NOT_NATIVE", "passed": True,
            "tests_run": result.testsRun, "selected_cases": 15, "domain_cases": 8, "host_cases": 4, "ui_cases": 3,
            "full_inventory": 214, "not_executed_this_run": 199, "whitelist_paths": 29, "native_executions": 0}


if __name__ == "__main__":
    try:
        print(json.dumps(run_self_check(), indent=2))
    except Exception as error:
        print("EPUB reading offline self-check failed: " + str(error), file=sys.stderr)
        sys.exit(1)

"""Offline unit and boundary checks for targeted 33-case EPUB compatibility validation."""

import ast
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import check_epub_batch as epub_batch
import run_epub_compat_validation as compat
import run_reading_ui_tests as ui
import task3_test_inventory as inventory
import validate_task3 as validator

ROOT = compat.ROOT
SYNTHETIC_SHA = "a" * 40
SYNTHETIC_RUN = "987654321"
SYNTHETIC_UDID = "12345678-1234-1234-1234-123456789abc"
SYNTHETIC_DEST = f"platform=iOS Simulator,id={SYNTHETIC_UDID}"

def make_log(names, *, summary_count="default", summary_status="passed", succeeded=True, extra_lines=()):
    lines = []
    for name in names:
        lines.append(f"◇ Test {name}() started.")
        lines.append(f"✔ Test {name}() passed after 0.05 seconds.")
    lines.extend(extra_lines)
    count = len(names) if summary_count == "default" else summary_count
    if count is not None:
        lines.append(f"✔ Test run with {count} tests {summary_status} after 0.50 seconds.")
    if succeeded:
        lines.append("** TEST SUCCEEDED **")
    return ("\n".join(lines) + "\n").encode("utf-8")


def sample_project_pair():
    current_bytes = (ROOT / "project.yml").read_bytes()
    if compat.NEW_VERSION_LINES in current_bytes:
        base_bytes = current_bytes.replace(compat.NEW_VERSION_LINES, compat.OLD_VERSION_LINES, 1)
    else:
        base_bytes = current_bytes
        current_bytes = base_bytes.replace(compat.OLD_VERSION_LINES, compat.NEW_VERSION_LINES, 1)
    return base_bytes, current_bytes


def build_scope_fixture():
    base_project, current_project = sample_project_pair()
    unchanged_paths = (
        "App/YueJingApp.swift",
        "Sources/TXTCore/TXTDecoders.swift",
        "Sources/ReaderDomain/EPUB/EPUBArchive.swift",
        "Tests/ReaderDomainTests/EPUBArchiveTests.swift",
        "scripts/reuse_native_evidence.py",
    )
    previous = {}
    current = {}
    worktree_blobs = {}
    for idx, path in enumerate(unchanged_paths, 1):
        sha = f"{idx:040x}"
        previous[path] = ["100644", "blob", sha]
        current[path] = ["100644", "blob", sha]
        worktree_blobs[path] = sha
    for idx, path in enumerate(sorted(compat.ALLOWED), 100):
        if path == "project.yml":
            base_sha = compat.git_blob_sha1(base_project)
            cur_sha = compat.git_blob_sha1(current_project)
            previous[path] = ["100644", "blob", base_sha]
            current[path] = ["100644", "blob", cur_sha]
            worktree_blobs[path] = cur_sha
        elif path in compat.NEW_ALLOWED:
            cur_sha = f"{idx + 1000:040x}"
            current[path] = ["100644", "blob", cur_sha]
            worktree_blobs[path] = cur_sha
        else:
            base_sha = f"{idx:040x}"
            cur_sha = f"{idx + 500:040x}"
            previous[path] = ["100644", "blob", base_sha]
            current[path] = ["100644", "blob", cur_sha]
            worktree_blobs[path] = cur_sha
    env = {
        "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_RUN_ATTEMPT": "1",
        "GITHUB_REF": "refs/heads/main",
        "VALIDATION_SCOPE": compat.SCOPE,
        "GITHUB_SHA": SYNTHETIC_SHA,
        "GITHUB_RUN_ID": SYNTHETIC_RUN,
    }
    return previous, current, base_project, current_project, env, worktree_blobs


def write_schemes(root):
    schemes_dir = Path(root) / "YueJing.xcodeproj/xcshareddata/xcschemes"
    schemes_dir.mkdir(parents=True, exist_ok=True)
    domain_scheme = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Scheme>\n'
        '  <TestAction>\n'
        '    <Testables>\n'
        '      <TestableReference skipped="NO">\n'
        '        <BuildableReference BlueprintName="ReaderDomainTests"/>\n'
        '      </TestableReference>\n'
        '    </Testables>\n'
        '  </TestAction>\n'
        '</Scheme>\n'
    )
    (schemes_dir / "ReaderDomain.xcscheme").write_text(domain_scheme, encoding="utf-8")
    testables_xml = "\n".join(
        f'      <TestableReference skipped="NO"><BuildableReference BlueprintName="{t}"/></TestableReference>'
        for t in sorted(ui.GROUPS)
    )
    ui_scheme = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<Scheme>\n'
        '  <TestAction>\n'
        '    <EnvironmentVariables>\n'
        '      <EnvironmentVariable key="YUEJING_UI_TEST_SESSION" '
        'value="D052AE4B-7823-447E-BE63-986028A7F54C" isEnabled="YES"/>\n'
        '    </EnvironmentVariables>\n'
        '    <Testables>\n'
        f'{testables_xml}\n'
        '    </Testables>\n'
        '  </TestAction>\n'
        '</Scheme>\n'
    )
    (schemes_dir / "YueJingUI.xcscheme").write_text(ui_scheme, encoding="utf-8")


def sample_packages():
    return {
        name: {
            "package": {
                "identity": name,
                "kind": "remoteSourceControl",
                "location": info["url"],
                "state": {"version": info["version"], "revision": info["revision"]},
            },
            "checkout_revision": info["revision"],
            "package_manifest_sha256": info["manifest"],
        }
        for name, info in epub_batch.DEPENDENCIES.items()
    }


def setup_synthetic_environment(temp_root):
    root = Path(temp_root)
    out = root / "artifacts/task3"
    out.mkdir(parents=True, exist_ok=True)
    write_schemes(root)

    resolved_path = root / "YueJing.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    resolved_path.parent.mkdir(parents=True, exist_ok=True)
    pins = [v["package"] for v in sample_packages().values()]
    resolved_path.write_text(json.dumps({"pins": pins, "version": 2}), encoding="utf-8")

    (out / "toolchain.log").write_text(
        f"Source: {SYNTHETIC_SHA}\narm64\nXcode 16.4\nBuild version 16F6\nApple Swift version 6.1.2 (swiftlang-6.1.2)\n",
        encoding="utf-8",
    )
    (out / "xcodegen.log").write_text("Version: 2.46.0\n", encoding="utf-8")
    packages = sample_packages()
    (out / "dependency-resolution.json").write_text(
        json.dumps({**packages["grdb.swift"], "packages": packages}),
        encoding="utf-8",
    )
    sim = {
        "device_name": "iPhone 16",
        "udid": SYNTHETIC_UDID,
        "runtime": "iOS 18.5",
        "runtime_version": "18.5",
        "sdk": "18.5",
        "architecture": "arm64",
        "physical_device": False,
    }
    (out / "simulator-selection.json").write_text(json.dumps(sim), encoding="utf-8")
    eff = {
        "ReaderDomainTests": {
            "PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test",
            "SWIFT_VERSION": "6.0",
            "SWIFT_STRICT_CONCURRENCY": "complete",
            "IPHONEOS_DEPLOYMENT_TARGET": "16.6",
            "TEST_HOST": "",
            "BUNDLE_LOADER": "",
            "TEST_TARGET_NAME": "",
        }
    }
    (out / "effective-test-settings.json").write_text(json.dumps(eff), encoding="utf-8")

    cand_files = {"project.yml": "1" * 64, "Sources/ReaderDomain/EPUB/EPUBCompatibility.swift": "2" * 64}
    inv_summary = {"kind": "SOURCE_INVENTORY_NOT_NATIVE", "selected": 214}
    (out / "candidate-sources.json").write_text(
        json.dumps(
            {
                "source_commit": SYNTHETIC_SHA,
                "run_id": SYNTHETIC_RUN,
                "run_attempt": "1",
                "files": cand_files,
                "inventory": inv_summary,
            }
        ),
        encoding="utf-8",
    )
    return root, out, cand_files, inv_summary, packages


class EPUBCompatValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="epub-compat-check-", dir=os.environ.get("PI_SCRATCH_DIR"))
        self.addCleanup(self.tmp.cleanup)
        self.temp_root = Path(self.tmp.name)
        self.popen_guard = patch(
            "subprocess.Popen",
            side_effect=AssertionError("Spawning real native subprocess is forbidden in offline checks"),
        )
        self.popen_guard.start()
        self.addCleanup(self.popen_guard.stop)

    def test_fixed_33_selection_inventory_and_non_adaptive_source_contract(self):
        summary = compat.validate_selected_cases(ROOT)
        self.assertEqual(summary["total"], 33)
        self.assertEqual(summary["domain"], 28)
        self.assertEqual(summary["host"], 5)
        self.assertEqual(summary["full_inventory"], 214)

        selected_json = ROOT / "artifacts/epub-compat-local-4d26ecf-01/LOCAL-CHECK-2/selected-cases.json"
        if selected_json.is_file():
            recorded = json.loads(selected_json.read_text(encoding="utf-8"))
            self.assertEqual(recorded["total"], 33)
            self.assertEqual(recorded["domain"], 28)
            self.assertEqual(recorded["host"], 5)
            self.assertEqual(recorded["cases"], summary["files"])

        self.assertEqual(len(compat.ALLOWED), 18)
        self.assertEqual(len(compat.NEW_ALLOWED), 5)
        self.assertTrue(compat.NEW_ALLOWED <= compat.ALLOWED)
        self.assertEqual(compat.BASE, "4d26ecf62b50014d97cd02d4fd512a617dfcbf1e")
        self.assertEqual(compat.SCOPE, "epub-compat-33")

        domain_cmd = compat.expected_command("domain", SYNTHETIC_DEST, Path("domain.xcresult"))
        self.assertIn("-scheme", domain_cmd)
        self.assertEqual(domain_cmd[domain_cmd.index("-scheme") + 1], "ReaderDomain")
        self.assertEqual(domain_cmd[domain_cmd.index("-configuration") + 1], "Debug")
        self.assertEqual(domain_cmd[domain_cmd.index("-sdk") + 1], "iphonesimulator")
        self.assertEqual(domain_cmd[domain_cmd.index("-derivedDataPath") + 1], "build/Task3Tests")
        self.assertEqual(
            [a for a in domain_cmd if a.startswith("-only-testing:")],
            [
                "-only-testing:ReaderDomainTests/EPUBPackageTests",
                "-only-testing:ReaderDomainTests/EPUBLibraryTests",
                "-only-testing:ReaderDomainTests/EPUBProgressTests",
                "-only-testing:ReaderDomainTests/EPUBCompatibilityTests",
            ],
        )
        self.assertFalse(any(a.startswith("-skip-testing") for a in domain_cmd))
        for required_arg in (
            "-parallel-testing-enabled",
            "-clonedSourcePackagesDirPath",
            "-disableAutomaticPackageResolution",
            "-skipPackageUpdates",
            "-onlyUsePackageVersionsFromResolvedFile",
            "CODE_SIGNING_ALLOWED=NO",
            "ARCHS=arm64",
        ):
            self.assertIn(required_arg, domain_cmd)

        host_cmd = compat.expected_command("host", SYNTHETIC_DEST, Path("host.xcresult"))
        self.assertEqual(host_cmd[host_cmd.index("-scheme") + 1], "YueJingUI")
        self.assertEqual(host_cmd[host_cmd.index("-configuration") + 1], "Debug")
        self.assertEqual(host_cmd[host_cmd.index("-derivedDataPath") + 1], "build/ReadingUIDerivedData")
        self.assertEqual(
            [a for a in host_cmd if a.startswith("-only-testing:")],
            ["-only-testing:YueJingHostTests/EPUBReaderHostTests"],
        )
        self.assertEqual(host_cmd[host_cmd.index("-default-test-execution-time-allowance") + 1], "180")
        self.assertEqual(host_cmd[host_cmd.index("-maximum-test-execution-time-allowance") + 1], "180")

        # Non-adaptive check: if inventory/source drifts from fixed SELECTED_FILES, validate_selected_cases rejects.
        altered_selected = dict(compat.SELECTED_FILES)
        altered_selected["YueJingHostTests/EPUBReaderHostTests.swift"] = compat.SELECTED_FILES[
            "YueJingHostTests/EPUBReaderHostTests.swift"
        ][:-1]
        with patch.object(compat, "SELECTED_FILES", altered_selected):
            with self.assertRaises(ValueError):
                compat.validate_selected_cases(ROOT)

    def test_pure_scope_and_project_version_boundaries(self):
        previous, current, base_proj, cur_proj, env, blobs = build_scope_fixture()
        receipt = compat.validate_scope_boundaries(
            previous,
            current,
            base_proj,
            cur_proj,
            env=env,
            head=SYNTHETIC_SHA,
            is_ancestor=True,
            status=b"",
            worktree_blobs=blobs,
        )
        self.assertEqual(receipt["scope"], "epub-compat-33")
        self.assertEqual(receipt["version"], "0.2.1")
        self.assertEqual(receipt["build"], "3")
        self.assertEqual(receipt["selected_total"], 33)
        self.assertEqual(set(receipt["changed_paths"]), compat.ALLOWED)
        self.assertEqual(set(receipt["added_paths"]), compat.NEW_ALLOWED)

        # Out-of-whitelist path changes must be rejected.
        for forbidden_path in (
            "App/YueJingApp.swift",
            "Sources/TXTCore/TXTDecoders.swift",
            "Sources/ReaderDomain/EPUB/EPUBArchive.swift",
            "Tests/ReaderDomainTests/EPUBArchiveTests.swift",
            "scripts/reuse_native_evidence.py",
            "Sources/ReaderDomain/EPUB/UnapprovedNewFile.swift",
        ):
            bad_cur = copy.deepcopy(current)
            bad_blobs = dict(blobs)
            bad_cur[forbidden_path] = ["100644", "blob", "f" * 40]
            bad_blobs[forbidden_path] = "f" * 40
            with self.assertRaises(ValueError, msg=f"Accepted out-of-scope path {forbidden_path}"):
                compat.validate_scope_boundaries(
                    previous,
                    bad_cur,
                    base_proj,
                    cur_proj,
                    env=env,
                    head=SYNTHETIC_SHA,
                    worktree_blobs=bad_blobs,
                )

        # Deleting a baseline file or deleting a whitelisted file must be rejected.
        for deleted_path in ("App/YueJingApp.swift", "App/EPUB/EPUBResourceHandler.swift", "docs/EPUB_COMPATIBILITY.md"):
            bad_cur = copy.deepcopy(current)
            bad_blobs = dict(blobs)
            bad_cur.pop(deleted_path, None)
            bad_blobs.pop(deleted_path, None)
            with self.assertRaises(ValueError, msg=f"Accepted deletion of {deleted_path}"):
                compat.validate_scope_boundaries(
                    previous,
                    bad_cur,
                    base_proj,
                    cur_proj,
                    env=env,
                    head=SYNTHETIC_SHA,
                    worktree_blobs=bad_blobs,
                )

        # Non-100644 mode (symlink / executable) must be rejected.
        bad_mode = copy.deepcopy(current)
        bad_mode["project.yml"] = ["120000", "blob", current["project.yml"][2]]
        with self.assertRaises(ValueError):
            compat.validate_scope_boundaries(
                previous, bad_mode, base_proj, cur_proj, env=env, head=SYNTHETIC_SHA, worktree_blobs=blobs
            )

        # project.yml version / extra byte mutations must be rejected.
        bad_projects = [
            base_proj,
            base_proj.replace(b'MARKETING_VERSION: "0.2.0"', b'MARKETING_VERSION: "0.2.2"').replace(
                b'CURRENT_PROJECT_VERSION: "2"', b'CURRENT_PROJECT_VERSION: "3"'
            ),
            base_proj.replace(b'MARKETING_VERSION: "0.2.0"', b'MARKETING_VERSION: "0.2.1"').replace(
                b'CURRENT_PROJECT_VERSION: "2"', b'CURRENT_PROJECT_VERSION: "4"'
            ),
            cur_proj + b"# extra comment\n",
        ]
        for bad_proj in bad_projects:
            bad_cur = copy.deepcopy(current)
            bad_blobs = dict(blobs)
            sha = compat.git_blob_sha1(bad_proj)
            bad_cur["project.yml"] = ["100644", "blob", sha]
            bad_blobs["project.yml"] = sha
            with self.assertRaises(ValueError):
                compat.validate_scope_boundaries(
                    previous, bad_cur, base_proj, bad_proj, env=env, head=SYNTHETIC_SHA, worktree_blobs=bad_blobs
                )

        # Provenance, clean worktree, and ancestor negative controls.
        for key, bad_val in (
            ("GITHUB_EVENT_NAME", "push"),
            ("GITHUB_RUN_ATTEMPT", "2"),
            ("GITHUB_REF", "refs/heads/feature"),
            ("VALIDATION_SCOPE", "full"),
            ("VALIDATION_SCOPE", "reuse-native-205-d2110a9"),
            ("GITHUB_SHA", compat.BASE),
            ("GITHUB_SHA", "b" * 40),
            ("GITHUB_RUN_ID", "0"),
        ):
            bad_env = dict(env, **{key: bad_val})
            with self.assertRaises(ValueError, msg=f"Accepted bad env {key}={bad_val}"):
                compat.validate_scope_boundaries(
                    previous, current, base_proj, cur_proj, env=bad_env, head=SYNTHETIC_SHA, worktree_blobs=blobs
                )

        with self.assertRaises(ValueError):
            compat.validate_scope_boundaries(
                previous, current, base_proj, cur_proj, env=env, head=SYNTHETIC_SHA, is_ancestor=False, worktree_blobs=blobs
            )
        with self.assertRaises(ValueError):
            compat.validate_scope_boundaries(
                previous,
                current,
                base_proj,
                cur_proj,
                env=env,
                head=SYNTHETIC_SHA,
                status=b" M project.yml\n",
                worktree_blobs=blobs,
            )
        bad_blobs = dict(blobs, **{"project.yml": "c" * 40})
        with self.assertRaises(ValueError):
            compat.validate_scope_boundaries(
                previous, current, base_proj, cur_proj, env=env, head=SYNTHETIC_SHA, worktree_blobs=bad_blobs
            )

    def test_group_log_and_event_parser_positive_and_negative_controls(self):
        for group, expected_count in (("domain", 28), ("host", 5)):
            names = compat.group_expected_names(group)
            good_raw = make_log(names)
            parsed = compat.parse_group_log(group, good_raw, 0, False)
            self.assertEqual(parsed["expected"], expected_count)
            self.assertEqual(len(parsed["passed"]), expected_count)
            self.assertEqual(parsed["failed"], 0)
            self.assertEqual(parsed["skipped"], 0)

            # Known UIKit interleaved start line remains supported via audit_native_case_events.parse_events.
            warning = (
                "2026-11-03 01:03:26.162225+0000 YueJing[13720:50426] Unbalanced calls to begin/end "
                "appearance transitions for <YueJing.ReaderViewController: 0x1049b1a00>."
            )
            first = names[0]
            split_raw = good_raw.decode("utf-8").replace(
                f"◇ Test {first}() started.",
                f"◇ Test {first[:6]}{warning}\n{first[6:]}() started.",
                1,
            ).encode("utf-8")
            self.assertEqual(len(compat.parse_group_log(group, split_raw, 0, False)["passed"]), expected_count)

            negatives = [
                ("missing-case", make_log(names[:-1], summary_count=expected_count), 0, False),
                ("duplicate-case", make_log(names + [names[0]], summary_count=expected_count), 0, False),
                (
                    "failed-case",
                    good_raw.decode("utf-8").replace(f"Test {names[0]}() passed", f"Test {names[0]}() failed").encode("utf-8"),
                    0,
                    False,
                ),
                (
                    "issue-hidden-by-pass",
                    make_log(
                        names,
                        extra_lines=[f"✘ Test {names[0]}() recorded an issue at File.swift:10:1: assertion failed"],
                    ),
                    0,
                    False,
                ),
                ("skipped-case", make_log(names, extra_lines=[f"◇ Test {names[-1]}() skipped."]), 0, False),
                (
                    "unfinished-case",
                    good_raw.decode("utf-8").replace(f"✔ Test {names[-1]}() passed after 0.05 seconds.\n", "").encode("utf-8"),
                    0,
                    False,
                ),
                ("nonzero-exit", good_raw, 65, False),
                ("timed-out", good_raw, 0, True),
                (
                    "foreign-case-name",
                    make_log(
                        names,
                        extra_lines=[
                            "◇ Test epubArchiveExtractsStoredAndDeflatedEntriesWithVerifiedDigests() started.",
                            "✔ Test epubArchiveExtractsStoredAndDeflatedEntriesWithVerifiedDigests() passed after 0.02 seconds.",
                        ],
                    ),
                    0,
                    False,
                ),
                ("missing-succeeded-marker", make_log(names, succeeded=False), 0, False),
                ("wrong-summary-count", make_log(names, summary_count=expected_count - 1), 0, False),
                ("failed-summary", make_log(names, summary_status="failed"), 0, False),
                ("missing-summary", make_log(names, summary_count=None), 0, False),
                (
                    "duplicate-summary",
                    make_log(names, extra_lines=[f"✔ Test run with {expected_count} tests passed after 0.10 seconds."]),
                    0,
                    False,
                ),
                ("suite-failed-line", make_log(names, extra_lines=["✘ Suite EPUBPackageTests failed after 0.2 seconds."]), 0, False),
                ("suite-skipped-line", make_log(names, extra_lines=["◇ Suite EPUBPackageTests skipped."]), 0, False),
                (
                    "unexpected-xctest",
                    make_log(names, extra_lines=["Test Case '-[EPUBFlowUITests testAlpha]' passed (0.1 seconds)."]),
                    0,
                    False,
                ),
            ]
            for label, raw, exit_code, timed_out in negatives:
                with self.assertRaises(ValueError, msg=f"Group {group} accepted invalid log {label}"):
                    compat.parse_group_log(group, raw, exit_code, timed_out)

    def test_single_shot_run_group_and_gate_validate_saved(self):
        root, out, cand_files, inv_summary, packages = setup_synthetic_environment(self.temp_root)
        previous, current, base_proj, cur_proj, env, blobs = build_scope_fixture()
        scope_receipt = compat.validate_scope_boundaries(
            previous, current, base_proj, cur_proj, env=env, head=SYNTHETIC_SHA, worktree_blobs=blobs
        )

        def fake_host_settings(target, group_out, source_commit):
            scheme = root / "YueJing.xcodeproj/xcshareddata/xcschemes/YueJingUI.xcscheme"
            base_cfg = {
                "SWIFT_VERSION": "6.0",
                "SWIFT_STRICT_CONCURRENCY": "complete",
                "IPHONEOS_DEPLOYMENT_TARGET": "16.6",
            }
            compat.write_new(
                Path(group_out) / f"{target}-settings.json",
                {
                    "source_commit": source_commit,
                    "scheme_sha256": compat.digest_path(scheme),
                    "fixture_environment": "D052AE4B-7823-447E-BE63-986028A7F54C",
                    "testables": sorted(ui.GROUPS),
                    "targets": {
                        "YueJing": {
                            **base_cfg,
                            "PRODUCT_TYPE": "com.apple.product-type.application",
                            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
                        },
                        "YueJingHostTests": {
                            **base_cfg,
                            "PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test",
                            "TEST_HOST": "/synthetic/YueJing.app/YueJing",
                            "BUNDLE_LOADER": "/synthetic/YueJing.app/YueJing",
                        },
                    },
                },
            )

        stream_calls = []

        def fake_stream_success(args, log_path, timeout_seconds):
            stream_calls.append((args, log_path, timeout_seconds))
            group = "domain" if "ReaderDomain" in args else "host"
            Path(log_path).write_bytes(make_log(compat.group_expected_names(group)))
            xcresult = Path(args[args.index("-resultBundlePath") + 1])
            xcresult.mkdir(parents=True, exist_ok=True)
            (xcresult / "Info.plist").write_text("plist", encoding="utf-8")
            return 0, False

        with (
            patch.object(compat, "ROOT", root),
            patch.object(compat, "OUT", out),
            patch.object(compat, "EPUB_OUT", out / "epub-compat"),
            patch.object(compat, "SCOPE_JSON", out / "epub-compat-scope.json"),
            patch.object(compat, "GATE_JSON", out / "epub-compat-gate.json"),
            patch.object(compat, "verify_scope", return_value=scope_receipt),
            patch.object(compat, "validate_toolchain_and_dependencies", return_value=packages),
            patch.object(validator, "OUT", out),
            patch.object(validator, "candidate_files", return_value=cand_files),
            patch.object(inventory, "validate_source", return_value=inv_summary),
            patch.object(ui, "actual_settings", side_effect=fake_host_settings),
            patch.dict(os.environ, env, clear=False),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            compat.main(["scope"])
            self.assertTrue((out / "epub-compat-scope.json").is_file())

            # Negative destination checks before running any native process.
            for bad_dest in ("platform=iOS,id=" + SYNTHETIC_UDID, "platform=iOS Simulator,id=00000000-0000-0000-0000-000000000000"):
                with self.assertRaises(ValueError):
                    compat.main(["run", "domain", "--destination", bad_dest])
            self.assertEqual(len(stream_calls), 0)

            with patch.object(ui, "stream_native", side_effect=fake_stream_success):
                compat.main(["run", "domain", "--destination", SYNTHETIC_DEST])
                compat.main(["run", "host", "--destination", SYNTHETIC_DEST])
            self.assertEqual(len(stream_calls), 2)
            self.assertEqual(stream_calls[0][2], 1200)
            self.assertEqual(stream_calls[1][2], 480)

            # Retry on existing group directory is forbidden.
            with patch.object(ui, "stream_native", side_effect=fake_stream_success):
                with self.assertRaises(ValueError):
                    compat.main(["run", "domain", "--destination", SYNTHETIC_DEST])

            # Gate before writing epub-compat-gate.json -> validate_saved must reject missing gate file.
            with self.assertRaises(ValueError):
                compat.validate_saved()

            compat.main(["gate"])
            qualification = compat.validate_saved()
            self.assertEqual(qualification["scope"], "epub-compat-33")
            self.assertEqual(qualification["coverage"], "EPUB_TARGETED_NOT_FULL")
            self.assertEqual(qualification["native_tests_executed_this_run"], 33)
            self.assertEqual(qualification["verified_passed"], 33)
            self.assertEqual(qualification["domain_passed"], 28)
            self.assertEqual(qualification["host_passed"], 5)
            self.assertEqual(qualification["not_executed_this_run"], 181)
            self.assertFalse(qualification["full_regression_executed_this_run"])
            self.assertEqual(qualification["historical_reference"]["status"], "not_executed_this_run")

            # Tampering with saved epub-compat-gate.json is rejected by validate_saved().
            gate_path = out / "epub-compat-gate.json"
            original_gate = json.loads(gate_path.read_text(encoding="utf-8"))
            for key, bad_val in (
                ("native_tests_executed_this_run", 214),
                ("coverage", "FULL"),
                ("source_commit", "f" * 40),
                ("run_id", "111"),
                ("version", "0.2.0"),
            ):
                forged = copy.deepcopy(original_gate)
                forged[key] = bad_val
                gate_path.write_text(json.dumps(forged), encoding="utf-8")
                with self.assertRaises(ValueError, msg=f"validate_saved accepted forged {key}"):
                    compat.validate_saved()
            gate_path.write_text(json.dumps(original_gate, indent=2) + "\n", encoding="utf-8")
            self.assertEqual(compat.validate_saved(), original_gate)

            # Tampering with group receipts, commands, logs, settings, or xcresult is rejected.
            domain_counts_path = out / "epub-compat/domain/ReaderDomainTests-counts.json"
            orig_counts_bytes = domain_counts_path.read_bytes()
            orig_counts = json.loads(orig_counts_bytes.decode("utf-8"))
            for field, bad_val in (
                ("source_commit", "0" * 40),
                ("run_id", "123"),
                ("run_attempt", "2"),
                ("command", orig_counts["command"][:-1]),
                ("log_sha256", "0" * 64),
            ):
                mutated = copy.deepcopy(orig_counts)
                mutated[field] = bad_val
                domain_counts_path.write_text(json.dumps(mutated), encoding="utf-8")
                with self.assertRaises(ValueError):
                    compat.validate_saved()
            domain_counts_path.write_bytes(orig_counts_bytes)

            # Tampering with raw log bytes while keeping counts.json summary is rejected.
            host_log_path = out / "epub-compat/host/YueJingHostTests.log"
            orig_host_log = host_log_path.read_bytes()
            host_log_path.write_bytes(make_log(compat.group_expected_names("host")[:-1], summary_count=5))
            with self.assertRaises(ValueError):
                compat.validate_saved()
            host_log_path.write_bytes(orig_host_log)

            # Tampering with host settings or source-hashes is rejected.
            host_settings_path = out / "epub-compat/host/YueJingHostTests-settings.json"
            orig_host_settings = host_settings_path.read_bytes()
            bad_host_settings = json.loads(orig_host_settings.decode("utf-8"))
            bad_host_settings["targets"]["YueJingHostTests"]["TEST_HOST"] = ""
            host_settings_path.write_text(json.dumps(bad_host_settings), encoding="utf-8")
            with self.assertRaises(ValueError):
                compat.validate_saved()
            host_settings_path.write_bytes(orig_host_settings)

            host_sources_path = out / "epub-compat/host/YueJingHostTests-source-hashes.json"
            orig_host_sources = host_sources_path.read_bytes()
            bad_host_sources = json.loads(orig_host_sources.decode("utf-8"))
            bad_host_sources["files"]["project.yml"] = "9" * 64
            host_sources_path.write_text(json.dumps(bad_host_sources), encoding="utf-8")
            with self.assertRaises(ValueError):
                compat.validate_saved()
            host_sources_path.write_bytes(orig_host_sources)

            # Removing xcresult Info.plist is rejected.
            info_plist = out / "epub-compat/host/YueJingHostTests.xcresult/Info.plist"
            info_plist.unlink()
            with self.assertRaises(ValueError):
                compat.validate_saved()
            info_plist.write_text("plist", encoding="utf-8")
            self.assertEqual(compat.validate_saved()["verified_passed"], 33)

    def test_failed_or_timed_out_run_preserves_evidence_without_writing_counts(self):
        for label, ret_code, timed_out in (("nonzero-exit", 65, False), ("timeout", -9, True)):
            with tempfile.TemporaryDirectory(
                prefix=f"epub-compat-fail-{label}-", dir=os.environ.get("PI_SCRATCH_DIR")
            ) as sub_tmp:
                root, out, cand_files, inv_summary, packages = setup_synthetic_environment(sub_tmp)
                previous, current, base_proj, cur_proj, env, blobs = build_scope_fixture()
                scope_receipt = compat.validate_scope_boundaries(
                    previous, current, base_proj, cur_proj, env=env, head=SYNTHETIC_SHA, worktree_blobs=blobs
                )
                calls = []

                def fake_stream_fail(args, log_path, timeout_seconds):
                    calls.append(1)
                    Path(log_path).write_text("◇ Test sample() started.\n** TEST FAILED **\n", encoding="utf-8")
                    return ret_code, timed_out

                with (
                    patch.object(compat, "ROOT", root),
                    patch.object(compat, "OUT", out),
                    patch.object(compat, "EPUB_OUT", out / "epub-compat"),
                    patch.object(compat, "SCOPE_JSON", out / "epub-compat-scope.json"),
                    patch.object(compat, "GATE_JSON", out / "epub-compat-gate.json"),
                    patch.object(compat, "verify_scope", return_value=scope_receipt),
                    patch.object(compat, "validate_toolchain_and_dependencies", return_value=packages),
                    patch.object(validator, "OUT", out),
                    patch.object(validator, "candidate_files", return_value=cand_files),
                    patch.object(inventory, "validate_source", return_value=inv_summary),
                    patch.object(ui, "stream_native", side_effect=fake_stream_fail),
                    patch.dict(os.environ, env, clear=False),
                    contextlib.redirect_stdout(io.StringIO()),
                ):
                    compat.main(["scope"])
                    with self.assertRaises(ValueError):
                        compat.main(["run", "domain", "--destination", SYNTHETIC_DEST])
                    self.assertEqual(len(calls), 1)
                    domain_out = out / "epub-compat/domain"
                    self.assertTrue((domain_out / "ReaderDomainTests.log").is_file())
                    self.assertTrue((domain_out / "ReaderDomainTests-selection.json").is_file())
                    self.assertTrue((domain_out / "ReaderDomainTests-execution.json").is_file())
                    exec_receipt = json.loads((domain_out / "ReaderDomainTests-execution.json").read_text(encoding="utf-8"))
                    self.assertEqual(exec_receipt["native_exit"], ret_code)
                    self.assertEqual(exec_receipt["timed_out"], timed_out)
                    self.assertFalse((domain_out / "ReaderDomainTests-counts.json").exists())

    def test_validate_task3_epub_compat_routing(self):
        for fname in ("run_epub_compat_validation.py", "check_epub_compat_validation.py"):
            ast.parse((ROOT / "scripts" / fname).read_text(encoding="utf-8"))

        class SentinelReached(Exception):
            pass

        with (
            patch.object(validator.sys, "platform", "darwin"),
            patch.object(compat, "validate_saved", side_effect=SentinelReached),
        ):
            with self.assertRaises(SentinelReached):
                validator.package_gate(epub_compat=True)
            with self.assertRaises(ValueError):
                validator.package_gate(reused=True, epub_compat=True)


def run_self_check():
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(EPUBCompatValidationTests)
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    if not result.wasSuccessful():
        sys.stderr.write(stream.getvalue())
        raise ValueError(f"EPUB compatibility offline self-check failed: {len(result.failures)} failures, {len(result.errors)} errors")
    return {
        "kind": "OFFLINE_EPUB_COMPAT_SELF_CHECK_NOT_NATIVE",
        "passed": True,
        "tests_run": result.testsRun,
        "selected_cases": 33,
        "domain_cases": 28,
        "host_cases": 5,
        "whitelist_paths": 18,
        "native_executions": 0,
    }


if __name__ == "__main__":
    try:
        print(json.dumps(run_self_check(), indent=2))
    except Exception as error:
        print("EPUB compatibility self-check failed: " + str(error), file=sys.stderr)
        sys.exit(1)

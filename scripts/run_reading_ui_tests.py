"""Explicit serial simulator checks; no installs, dependency resolution, retries, or packaging."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
import xml.etree.ElementTree as ET
import task3_test_inventory as inventory
from reading_launch_diagnostics import LaunchDiagnostics, ProcessLifecycleDiagnostics

ROOT = Path(__file__).resolve().parents[1]
GROUPS = {target: inventory.COUNTS[target] for target in ("YueJingHostTests", "YueJingUITests")}


def declarations(target):
    inventory.validate_source()
    return inventory.expected_names(target)


def count_log(target, log, native_exit):
    expected = declarations(target)
    if len(expected) != GROUPS[target] or len(set(expected)) != len(expected):
        raise ValueError("Unexpected declared inventory: " + target)
    if target == "YueJingHostTests":
        passed = re.findall(r"\bTest (\w+)\(\) passed after\b", log)
        summaries = re.findall(r"Test run with (\d+) tests?\b[^\r\n]*?\b(passed|failed)\b", log)
        if summaries != [(str(GROUPS[target]), "passed")]:
            raise ValueError("Missing or failed Swift Testing summary")
    else:
        passed = re.findall(r"Test Case '-\[(?:\w+\.)?ReadingFlowUITests (test\w+)\]' passed \(", log)
    if native_exit != 0 or "** TEST SUCCEEDED **" not in log:
        raise ValueError("Native test command did not succeed")
    if re.search(r"^.*\b(?:Test|Suite)[^\r\n]*\b(?:skipped|failed)\b", log, re.MULTILINE):
        raise ValueError("A native test failed or was skipped")
    if sorted(passed) != sorted(expected) or len(set(passed)) != len(passed):
        raise ValueError("Missing, duplicate, or unexpected native execution: " + target)
    return {"target": target, "passed": passed, "failed": 0, "skipped": 0, "unexecuted": 0, "native_exit": native_exit}


def self_check():
    """Synthetic parser checks only. Never represents App execution."""
    checked = []
    for target in GROUPS:
        names = declarations(target)
        if target == "YueJingHostTests":
            lines = ["Test " + n + "() passed after 0.1 seconds." for n in names]
            tail = f"Test run with {GROUPS[target]} tests passed after 0.2 seconds.\n** TEST SUCCEEDED **"
        else:
            lines = ["Test Case '-[YueJingUITests.ReadingFlowUITests " + n + "]' passed (0.1 seconds)." for n in names]
            tail = "** TEST SUCCEEDED **"
        good = "\n".join(lines + [tail])
        count_log(target, good, 0); checked.append(target + ":accept")
        bad = [("missing", "\n".join(lines[:-1] + [tail]), 0),
               ("duplicate", good + "\n" + lines[0], 0),
               ("skip", good + "\nTest Case skipped", 0),
               ("failed", good + "\nTest example failed", 0),
               ("exit", good, 65)]
        for label, log, code in bad:
            try:
                count_log(target, log, code)
            except ValueError:
                checked.append(target + ":reject_" + label)
            else:
                raise ValueError("Synthetic parser check incorrectly accepted " + target + ":" + label)
    from check_reading_launch_diagnostics import self_check as launch_self_check
    return {"kind": "SYNTHETIC_PARSER_NOT_NATIVE", "passed": len(checked), "failed": 0, "cases": checked,
            "native_executions": 0, "launch_diagnostics": launch_self_check()}


def preflight():
    inventory = {target: declarations(target) for target in GROUPS}
    if any(len(inventory[t]) != n for t, n in GROUPS.items()):
        raise ValueError("Unexpected source inventory")
    return {"platform": sys.platform, "inventory": inventory, "selected_app_tests": sum(GROUPS.values()),
            "native_executions": 0, "xcodebuild": shutil.which("xcodebuild"),
            "limitations": "Source/count checks are not XcodeGen generation, Swift compilation, App interaction, or device acceptance."}


def write_new(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2)


def actual_settings(target, out, source_commit):
    scheme = ROOT / "YueJing.xcodeproj/xcshareddata/xcschemes/YueJingUI.xcscheme"
    xml = ET.parse(scheme).getroot()
    testables = xml.findall("./TestAction/Testables/TestableReference")
    selected = {node.find("BuildableReference").get("BlueprintName") for node in testables if node.get("skipped") == "NO"}
    variables = {node.get("key"): node.get("value") for node in xml.findall("./TestAction/EnvironmentVariables/EnvironmentVariable") if node.get("isEnabled") == "YES"}
    if selected != set(GROUPS) or not variables.get("YUEJING_UI_TEST_SESSION"):
        raise ValueError("Generated scheme lacks both real App test targets or the isolated host fixture environment")
    uuid.UUID(variables["YUEJING_UI_TEST_SESSION"])
    keys = ("PRODUCT_TYPE", "SWIFT_VERSION", "SWIFT_STRICT_CONCURRENCY", "IPHONEOS_DEPLOYMENT_TARGET",
            "TEST_HOST", "BUNDLE_LOADER", "TEST_TARGET_NAME", "SWIFT_ACTIVE_COMPILATION_CONDITIONS")
    settings = {}
    for name in ("YueJing", target):
        print("Inspect actual Debug App/test settings: " + name, flush=True)
        args = ["xcodebuild", "-project", "YueJing.xcodeproj", "-target", name, "-configuration", "Debug",
                "-sdk", "iphonesimulator", "-showBuildSettings", "-json", "-clonedSourcePackagesDirPath", "build/SourcePackages",
                "-disableAutomaticPackageResolution", "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64"]
        result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=120)
        (out / (target + "-" + name + "-settings.stdout.json")).write_text(result.stdout, encoding="utf-8")
        (out / (target + "-" + name + "-settings.log")).write_text(result.stderr, encoding="utf-8")
        (out / (target + "-" + name + "-settings-exit-code.txt")).write_text(str(result.returncode), encoding="utf-8")
        if result.returncode != 0:
            raise ValueError("Actual test/App settings query failed: " + name)
        rows = [row["buildSettings"] for row in json.loads(result.stdout) if row.get("target") == name]
        if len(rows) != 1:
            raise ValueError("Missing actual target settings: " + name)
        values = {key: rows[0].get(key, "") for key in keys}
        if values["SWIFT_VERSION"] != "6.0" or values["SWIFT_STRICT_CONCURRENCY"] != "complete" or values["IPHONEOS_DEPLOYMENT_TARGET"] != "16.6":
            raise ValueError("Unexpected language/isolation/deployment: " + name)
        settings[name] = values
    app, test = settings["YueJing"], settings[target]
    if app["PRODUCT_TYPE"] != "com.apple.product-type.application" or "DEBUG" not in app["SWIFT_ACTIVE_COMPILATION_CONDITIONS"].split():
        raise ValueError("Isolated fixture is not compiled into the actual Debug App")
    if target == "YueJingHostTests":
        host = Path(test["TEST_HOST"])
        if test["PRODUCT_TYPE"] != "com.apple.product-type.bundle.unit-test" or host.name != "YueJing" or host.parent.name != "YueJing.app" or test["BUNDLE_LOADER"] != test["TEST_HOST"]:
            raise ValueError("Host tests are not hosted by the real YueJing App")
    elif test["PRODUCT_TYPE"] != "com.apple.product-type.bundle.ui-testing" or test["TEST_TARGET_NAME"] != "YueJing":
        raise ValueError("UI tests do not target the real YueJing App")
    write_new(out / (target + "-settings.json"), {"source_commit": source_commit, "targets": settings,
        "scheme_sha256": hashlib.sha256(scheme.read_bytes()).hexdigest(), "testables": sorted(selected), "fixture_environment": variables["YUEJING_UI_TEST_SESSION"]})


def _diagnostic_call(observer, method, *args):
    # Observation must never replace the native exit, timeout or test gate.
    try:
        if observer is not None:
            getattr(observer, method)(*args)
    except Exception:
        pass


def _lifecycle_snapshot(observer):
    try:
        value = observer.snapshot()
        if not isinstance(value, dict) or value.get("acceptance_role") != "none":
            raise ValueError("non-gate metadata missing")
        encoded = json.dumps(value, allow_nan=False)
        if len(encoded.encode("utf-8")) > 16384:
            raise ValueError("lifecycle snapshot over cap")
        return json.loads(encoded)
    except Exception:
        return {"kind": "NON_GATE_NATIVE_PROCESS_LIFECYCLE", "acceptance_role": "none",
                "status": "unknown", "reason": "snapshot-unavailable-or-over-cap"}


class _UIProcessTimeline:
    """Bounded, non-gate UI observations. No disk IO in process/timer callbacks."""
    MAX_EVENTS = 64
    MAX_BYTES = 16384
    EVENTS = frozenset((
        "popen_requested", "popen_returned", "popen_failed", "timer_started", "timer_callback",
        "timer_poll", "timer_poll_failed", "kill_requested", "kill_returned", "kill_failed",
        "stdout_eof", "wait_started", "wait_returned", "stream_error", "timer_cancelled",
        "stdout_closed", "stream_unwound", "stream_returned", "returned_timed_out",
        "native_stream_finished", "first_test_start_observed", "native_receipt_written",
        "native_receipt_failed", "export_started", "export_finished", "export_failed"))

    def __init__(self, path, provenance):
        self.path = path
        self._lock = threading.Lock()
        self._events = []
        self._dropped = 0
        self._unknown = False
        self._lines = 0
        self._first_test = False
        self._identity = {}
        for key, pattern in (("source_commit", r"[0-9a-f]{40}"), ("run_id", r"[1-9][0-9]{0,19}"),
                             ("run_attempt", r"[1-9][0-9]{0,5}"), ("target", r"YueJingUITests")):
            value = provenance.get(key)
            if value is not None and (not isinstance(value, str) or not re.fullmatch(pattern, value)):
                value = None
                self._unknown = True
            self._identity[key] = value

    def record(self, event, value=None):
        with self._lock:
            if event not in self.EVENTS:
                self._unknown = True
                return
            if len(self._events) >= self.MAX_EVENTS:
                self._dropped = min(self._dropped + 1, 2**63 - 1)
                return
            try:
                utc = datetime.now(timezone.utc).isoformat()
                if not isinstance(utc, str) or len(utc) > 40 or not re.fullmatch(r"[0-9T:.+Z-]+", utc):
                    raise ValueError("Invalid observation clock")
                mono = time.monotonic()
                if type(mono) not in (int, float) or mono != mono or abs(mono) == float("inf"):
                    raise ValueError("Invalid observation clock")
            except Exception:
                utc, mono = None, None
                self._unknown = True
            # Never retain exception messages, process arguments, stdout or arbitrary strings.
            numeric = value if type(value) in (int, bool) and -(2**63) <= value < 2**63 else None
            self._events.append({"sequence": len(self._events) + 1, "event": event,
                                 "utc": utc, "monotonic": mono, "value": numeric})

    def start(self, process, deadline):
        pass  # No polling, extra process, deadline change or background writer.

    def observe_line(self, line):
        first = False
        with self._lock:
            self._lines = min(self._lines + 1, 2**63 - 1)
            if not self._first_test and len(line) <= 512 and re.fullmatch(
                    r"Test Case '-\[(?:\w+\.)?ReadingFlowUITests test\w+\]' started\.\s*", line):
                self._first_test = True
                first = True
        if first:
            self.record("first_test_start_observed")

    def finish(self):
        # stream_native calls this before export; do not seal or persist the recorder here.
        self.record("native_stream_finished")

    def snapshot(self):
        with self._lock:
            return {"kind": "NON_GATE_UI_PROCESS_TIMELINE", "schema": 1, "acceptance_role": "none",
                    "status": "unknown" if self._unknown else "truncated" if self._dropped else "observed",
                    "truncated": bool(self._dropped), "dropped_events": self._dropped,
                    "stdout_lines_observed": self._lines, "events": list(self._events),
                    "late_events_possible": True, **self._identity}

    def persist(self):
        try:
            value = self.snapshot()
            while True:
                raw = (json.dumps(value, allow_nan=False, ensure_ascii=True, separators=(",", ":")) + "\n").encode("utf-8")
                if len(raw) <= self.MAX_BYTES:
                    break
                if not value["events"]:
                    raise ValueError("Observation metadata over cap")
                value["events"].pop()
                value.update(status="truncated", truncated=True, dropped_events=value["dropped_events"] + 1)
            with self.path.open("xb") as stream:
                stream.write(raw)
            return True
        except Exception:
            try:
                print("UI process timeline unavailable: non-gate observation unknown", file=sys.stderr)
            except Exception:
                pass
            return False


def _ui_failure_kind(code, timed_out, native_error=None, receipt_error=None, export_error=None):
    if native_error is not None:
        return "NATIVE_EXECUTION_ERROR"
    if timed_out is True:
        return "NATIVE_TIMEOUT"
    if type(code) is not int or type(timed_out) is not bool:
        return "NATIVE_RESULT_UNAVAILABLE"
    if code != 0:
        return "NATIVE_FAILURE"
    if receipt_error is not None:
        return "NATIVE_RECEIPT_ERROR"
    if export_error is not None:
        return "ATTACHMENT_EXPORT_ERROR"
    return None


def _ui_export_exit(out, provenance, native_exit):
    """Only annotate a matching existing receipt; never derive acceptance from it."""
    try:
        path = out / "attachment-export.json"
        if path.stat().st_size > 65536:
            return None
        value = json.loads(path.read_text(encoding="utf-8"))
        if any(value.get(k) != provenance.get(k) for k in ("source_commit", "run_id", "run_attempt", "target")):
            return None
        if value.get("native_exit") != native_exit or type(value.get("export_exit")) is not int:
            return None
        return value["export_exit"]
    except Exception:
        return None


def _run_ui_attempt(args, out, provenance, timeout_seconds):
    """One UI native command and one export entry; original result wins over export errors."""
    if provenance.get("target") != "YueJingUITests":
        raise ValueError("UI coordinator cannot run a different target")
    timeline = None
    try:
        timeline = _UIProcessTimeline(out / "YueJingUITests-process-timeline.json", provenance)
    except Exception:
        pass  # Observation availability is never acceptance.
    code, timed_out = None, None
    native_error = receipt_error = export_error = None
    export_exit = None
    try:
        try:
            code, timed_out = stream_native(args, out / "YueJingUITests.log", timeout_seconds,
                                           process_lifecycle=timeline)
        except BaseException as error:
            native_error = error
        if native_error is None:
            try:
                (out / "YueJingUITests-exit-code.txt").write_text(str(code) + "\n", encoding="utf-8")
                write_new(out / "YueJingUITests-execution.json",
                          {**provenance, "native_exit": code, "timed_out": timed_out})
                _diagnostic_call(timeline, "record", "native_receipt_written")
            except BaseException as error:
                receipt_error = error
                _diagnostic_call(timeline, "record", "native_receipt_failed")
        _diagnostic_call(timeline, "record", "export_started")
        try:
            export_ui_evidence(out, provenance, code)
        except BaseException as error:
            export_error = error
        export_exit = _ui_export_exit(out, provenance, code)
        _diagnostic_call(timeline, "record", "export_failed" if export_error is not None else "export_finished", export_exit)
    finally:
        _diagnostic_call(timeline, "persist")
    kind = _ui_failure_kind(code, timed_out, native_error, receipt_error, export_error)
    note = (f"{kind}: target=YueJingUITests native_exit={code!r} timed_out={timed_out!r}; "
            f"receipt_error={receipt_error is not None} export_error={export_error is not None} export_exit={export_exit!r}")
    if kind:
        try:
            print("UI outcome: " + note, file=sys.stderr)
        except Exception:
            pass
        for label, error in (("native receipt", receipt_error), ("attachment export", export_error)):
            if isinstance(error, Exception):
                try:
                    print("UI " + label + " error: " + str(error), file=sys.stderr)
                except Exception:
                    pass
    # Cancellation/control exceptions remain control flow, not ordinary test failures or success.
    for error in (native_error, receipt_error, export_error):
        if error is not None and not isinstance(error, Exception):
            raise error.with_traceback(error.__traceback__)
    if native_error is not None:
        raise native_error.with_traceback(native_error.__traceback__)
    if kind == "NATIVE_RECEIPT_ERROR":
        raise receipt_error.with_traceback(receipt_error.__traceback__)
    if kind:
        raise ValueError(note) from None
    return code, timed_out


def stream_native(args, path, timeout_seconds, launch_diagnostics=None, process_lifecycle=None):
    timed_out = threading.Event()
    with path.open("x", encoding="utf-8") as stream:
        _diagnostic_call(process_lifecycle, "record", "popen_requested")
        try:
            process = subprocess.Popen(args, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
        except Exception as error:
            _diagnostic_call(process_lifecycle, "record", "popen_failed", type(error).__name__)
            _diagnostic_call(process_lifecycle, "finish")
            raise
        _diagnostic_call(process_lifecycle, "record", "popen_returned", process.pid)
        def expire():
            _diagnostic_call(process_lifecycle, "record", "timer_callback")
            try:
                poll_result = process.poll()  # The same single poll controls the original timeout action.
            except Exception as error:
                _diagnostic_call(process_lifecycle, "record", "timer_poll_failed", type(error).__name__)
                raise
            _diagnostic_call(process_lifecycle, "record", "timer_poll", poll_result)
            if poll_result is None:
                timed_out.set()
                _diagnostic_call(process_lifecycle, "record", "kill_requested")
                try:
                    process.kill()
                except Exception as error:
                    _diagnostic_call(process_lifecycle, "record", "kill_failed", type(error).__name__)
                    raise
                _diagnostic_call(process_lifecycle, "record", "kill_returned")
        timer = threading.Timer(timeout_seconds, expire)
        observation_deadline = time.monotonic() + timeout_seconds if launch_diagnostics is not None or process_lifecycle is not None else 0
        timer.start()
        _diagnostic_call(process_lifecycle, "record", "timer_started")
        _diagnostic_call(process_lifecycle, "start", process, observation_deadline)
        _diagnostic_call(launch_diagnostics, "start", process, observation_deadline)
        completed = False
        try:
            for line in process.stdout:
                _diagnostic_call(process_lifecycle, "observe_line", line)
                stream.write(line); stream.flush()
                print(line, end="", flush=True)
                _diagnostic_call(launch_diagnostics, "observe_line", line)
            _diagnostic_call(process_lifecycle, "record", "stdout_eof")
            _diagnostic_call(process_lifecycle, "record", "wait_started")
            code = process.wait()
            _diagnostic_call(process_lifecycle, "record", "wait_returned", code)
            completed = True
        except Exception as error:
            _diagnostic_call(process_lifecycle, "record", "stream_error", type(error).__name__)
            raise
        finally:
            timer.cancel()
            _diagnostic_call(process_lifecycle, "record", "timer_cancelled")
            process.stdout.close()
            _diagnostic_call(process_lifecycle, "record", "stdout_closed")
            _diagnostic_call(launch_diagnostics, "stop")
            if not completed:
                _diagnostic_call(process_lifecycle, "record", "stream_unwound")
                _diagnostic_call(process_lifecycle, "finish")
    result = (code, timed_out.is_set())
    _diagnostic_call(process_lifecycle, "record", "stream_returned", code)
    _diagnostic_call(process_lifecycle, "record", "returned_timed_out", result[1])
    _diagnostic_call(process_lifecycle, "finish")
    return result


def export_ui_evidence(out, provenance, native_exit):
    """Export native attachments once, including after failed tests; never rerun tests."""
    bundle = out / "YueJingUITests.xcresult"
    exported = out / "YueJingUITests-attachments"
    help_args = ["xcrun", "xcresulttool", "export", "attachments", "--help"]
    help_code, help_timeout = stream_native(help_args, out / "attachment-export-help.log", 30)
    write_new(out / "attachment-export-help.json", {"command": help_args, "exit": help_code, "timed_out": help_timeout})
    help_text = (out / "attachment-export-help.log").read_text(encoding="utf-8")
    if help_code != 0 or help_timeout or not all(flag in help_text for flag in ("--path", "--output-path")):
        raise ValueError("Pinned xcresulttool attachment export is unavailable; help preserved")
    exported.mkdir()
    args = ["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle), "--output-path", str(exported)]
    code, timed_out = stream_native(args, out / "attachment-export.log", 120)
    write_new(out / "attachment-export.json", {**provenance, "command": args, "native_exit": native_exit,
        "export_exit": code, "timed_out": timed_out})
    if code != 0 or timed_out:
        raise ValueError("Native attachment export failed; original test exit and export log preserved")
    manifests = list(exported.rglob("manifest.json"))
    if len(manifests) != 1:
        raise ValueError("Expected one native attachment manifest")
    manifest = json.loads(manifests[0].read_text(encoding="utf-8"))
    cases = {name: {"png": [], "ax": []} for name in declarations("YueJingUITests")}
    files = {}
    for path in sorted(exported.rglob("*")):
        if path.is_symlink() or not path.resolve().is_relative_to(exported.resolve()):
            raise ValueError("Unsafe exported attachment path")
        if not path.is_file():
            continue
        if path.name in files:
            raise ValueError("Duplicate exported attachment filename")
        data = path.read_bytes()
        item = {"path": path.relative_to(out).as_posix(), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        files[path.name] = {**item, "png": data.startswith(b"\x89PNG\r\n\x1a\n")}
        if data.startswith(b"YueJing UI evidence\n"):
            text = data.decode("utf-8")
            name = re.search(r"^case: (test\w+)$", text, re.MULTILINE)
            stage = re.search(r"^stage: ([\w-]+)$", text, re.MULTILINE)
            if name and name[1] in cases:
                cases[name[1]]["ax"].append({**item, "stage": stage[1] if stage else None,
                    "full_app_available": "fullAppDebugDescription:\n" in text and "App is not running;" not in text})
    def index_manifest(value, owner=None):
        if isinstance(value, dict):
            strings = [v for v in value.values() if isinstance(v, str)]
            matched = [name for name in cases if any(name in v for v in strings)]
            owner = matched[0] if len(matched) == 1 else owner
            if owner:
                for text in strings:
                    item = files.get(Path(text).name)
                    if item and item["png"] and item not in cases[owner]["png"]:
                        cases[owner]["png"].append(item)
            for child in value.values():
                index_manifest(child, owner)
        elif isinstance(value, list):
            for child in value:
                index_manifest(child, owner)
    index_manifest(manifest)
    write_new(out / "case-evidence-index.json", {**provenance, "native_exit": native_exit,
        "native_manifest": manifests[0].relative_to(out).as_posix(), "cases": cases,
        "exported_files": list(files.values())})
    if native_exit == 0 and any(not row["png"] or not any(a["full_app_available"] and a["stage"] == "open" for a in row["ax"]) for row in cases.values()):
        raise ValueError("A passed UI case lacks its PNG or full App AX from a visible-book opening")


def run_native(destination, target=None, evidence_dir=None):
    if sys.platform != "darwin" or not shutil.which("xcodebuild"):
        raise ValueError("Native execution not run: macOS and the pinned Xcode toolchain are required")
    if not destination or not re.fullmatch(r"platform=iOS Simulator,id=[0-9a-fA-F-]{36}", destination):
        raise ValueError("Provide one installed simulator UUID; never a physical device")
    version = subprocess.check_output(["xcodebuild", "-version"], text=True)
    swift = subprocess.check_output(["xcrun", "swift", "--version"], text=True)
    if "Xcode 16.4" not in version or "16F6" not in version or "Swift version 6.1.2" not in swift:
        raise ValueError("Pinned native toolchain mismatch")
    resolved = ROOT / "YueJing.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    if not resolved.is_file() or not (ROOT / "build/SourcePackages/checkouts/GRDB.swift").is_dir():
        raise ValueError("Generate project and prepare the approved pinned dependency separately; this script never resolves or installs")
    pins = json.loads(resolved.read_text())["pins"]
    if len(pins) != 1 or pins[0]["location"] != "https://github.com/groue/GRDB.swift.git" or pins[0]["state"]["version"] != "7.0.0":
        raise ValueError("Pinned GRDB resolution mismatch")
    out = (ROOT / evidence_dir).resolve() if evidence_dir else ROOT / "artifacts/reading-ui-native" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8])
    if not out.is_relative_to((ROOT / "artifacts").resolve()):
        raise ValueError("Evidence must stay inside this project's artifacts")
    out.mkdir(parents=True, exist_ok=True)
    source_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if os.environ.get("GITHUB_SHA", source_commit) != source_commit:
        raise ValueError("Checked out source differs from GITHUB_SHA")
    paths = sorted((ROOT / "App").rglob("*.swift")) + [ROOT / "project.yml"]
    paths += [p for t in GROUPS for p in sorted((ROOT / "Tests" / t).glob("*.swift"))]
    source = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    selected_targets = [target] if target else list(GROUPS)
    for target in selected_targets:
        timeout_seconds = 480 if target == "YueJingHostTests" else 900
        args = ["xcodebuild", "test", "-project", "YueJing.xcodeproj", "-scheme", "YueJingUI", "-configuration", "Debug",
                "-destination", destination, "-only-testing:" + target, "-parallel-testing-enabled", "NO",
                "-clonedSourcePackagesDirPath", "build/SourcePackages", "-disableAutomaticPackageResolution", "-skipPackageUpdates",
                "-onlyUsePackageVersionsFromResolvedFile", "-derivedDataPath", "build/ReadingUIDerivedData",
                "-resultBundlePath", str(out / (target + ".xcresult")), "-test-timeouts-enabled", "YES",
                "-default-test-execution-time-allowance", "180", "-maximum-test-execution-time-allowance", "180",
                "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64"]
        provenance = {"source_commit": source_commit, "run_id": os.environ.get("GITHUB_RUN_ID"), "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
                      "target": target, "scheme": "YueJingUI", "configuration": "Debug", "destination": destination,
                      "expected": GROUPS[target], "declared": declarations(target), "command": args, "timeout_seconds": timeout_seconds}
        write_new(out / (target + "-selection.json"), provenance)
        write_new(out / (target + "-source-hashes.json"), {"source_commit": source_commit, "files": source})
        actual_settings(target, out, source_commit)
        print(json.dumps({"starting_target": target, "selected": declarations(target), "timeout_seconds": timeout_seconds}), flush=True)
        code = None
        launch_diagnostics = None
        process_lifecycle = None
        if target == "YueJingHostTests":
            try:
                launch_diagnostics = LaunchDiagnostics(out, destination, provenance)
            except Exception:
                pass  # Missing launch observations are unknown, not test acceptance.
            try:
                process_lifecycle = ProcessLifecycleDiagnostics(out, provenance)
            except Exception:
                pass  # Lifecycle observations never authorize or replace a native result.
        if target == "YueJingUITests":
            code, timed_out = _run_ui_attempt(args, out, provenance, timeout_seconds)
        else:
            code, timed_out = stream_native(args, out / (target + ".log"), timeout_seconds,
                                           launch_diagnostics=launch_diagnostics, process_lifecycle=process_lifecycle)
            (out / (target + "-exit-code.txt")).write_text(str(code) + "\n", encoding="utf-8")
            execution = {**provenance, "native_exit": code, "timed_out": timed_out}
            if process_lifecycle is not None:
                execution["process_lifecycle_observation"] = _lifecycle_snapshot(process_lifecycle)
            write_new(out / (target + "-execution.json"), execution)
        if timed_out:
            raise ValueError("Native target timed out; raw process exit preserved: " + target)
        counts = {**count_log(target, (out / (target + ".log")).read_text(encoding="utf-8", errors="replace"), code), **provenance}
        counts["log_sha256"] = hashlib.sha256((out / (target + ".log")).read_bytes()).hexdigest()
        write_new(out / (target + "-counts.json"), counts)
        print(json.dumps(counts), flush=True)
    if any(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() != value for p, value in source.items()):
        raise ValueError("Sources changed during the native run")
    print(json.dumps({"selected_native_passed": sum(GROUPS[t] for t in selected_targets), "evidence": str(out), "physical_device_acceptance": "not performed"}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preflight", action="store_true", help="Read-only inventory; no native execution")
    parser.add_argument("--self-check", action="store_true", help="Synthetic log-parser checks; not UI tests")
    parser.add_argument("--run", action="store_true", help="Explicitly run only the two new targets on an installed macOS simulator")
    parser.add_argument("--destination")
    parser.add_argument("--target", choices=tuple(GROUPS), help="Select one target, exactly once")
    parser.add_argument("--evidence-dir", help="Explicit project artifacts directory for CI evidence")
    args = parser.parse_args()
    print(json.dumps(preflight(), ensure_ascii=False, indent=2))
    if args.self_check: print(json.dumps(self_check(), indent=2))
    if args.run: run_native(args.destination, args.target, args.evidence_dir)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, ET.ParseError, subprocess.SubprocessError) as error:
        print("Reading UI checks stopped: " + str(error), file=sys.stderr)
        sys.exit(1)

"""Synthetic launch-observer regressions. Never starts Xcode or macOS tools."""
import ast
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import time
from unittest.mock import patch

import reading_launch_diagnostics as diagnostics

UDID = "22A3039C-6A45-47F4-82D4-80C58CA94379"
DESTINATION = "platform=iOS Simulator,id=" + UDID


class FakeNative:
    def __init__(self, output="synthetic native output\n", code=0, pid=101):
        self.stdout = io.StringIO(output)
        self.pid, self.code, self.result, self.kills = pid, None, code, 0
    def poll(self):
        return self.code
    def wait(self):
        if self.code is None:
            self.code = self.result
        return self.code
    def kill(self):
        self.kills += 1; self.code = -9


class FakeCapture:
    def __init__(self, payload=b"synthetic observation", code=0, pipe=None):
        self.stdout = pipe or io.BytesIO(payload)
        self.pid, self.code, self.kills = 60001, code, 0
    def poll(self):
        return self.code
    def kill(self):
        self.kills += 1


class StepClock:
    def __init__(self, step=0.05):
        self.now, self.step = 100.0, step
    def __call__(self):
        self.now += self.step
        return self.now


def self_check():
    import run_reading_ui_tests as runner  # Import only; never run main/run_native.
    checked = []
    def check(condition, name):
        if not condition:
            raise AssertionError(name)
        checked.append(name)
    def reject(action, name):
        try:
            action()
        except (ValueError, KeyError, TypeError):
            check(True, name)
        else:
            raise AssertionError("Expected rejection: " + name)
    def observer(out, clock=None):
        return diagnostics.LaunchDiagnostics(out, DESTINATION,
            dict(source_commit="synthetic-sha", run_id="synthetic-run", run_attempt="1",
                 target="YueJingHostTests", scheme="YueJingUI", configuration="Debug"), clock=clock)

    with tempfile.TemporaryDirectory(prefix="reading-launch-synthetic-", dir=os.environ.get("PI_SCRATCH_DIR")) as tmp:
        out = Path(tmp)
        value = diagnostics._process_rows(b"101 1 S 00:01 /Xcode/xcodebuild\n202 1 S 00:01 /tmp/YueJing\n303 1 S 00:01 /tmp/UnrelatedPrivateApp\n", 101)
        check([row["pid"] for row in value["rows"]] == [101, 202], "ps-keeps-only-native-and-fixed-process-names")
        check("UnrelatedPrivateApp" not in json.dumps(value) and "/tmp/" not in json.dumps(value), "ps-does-not-persist-args-environment-or-unrelated-paths")
        many = b"\n".join(f"{n+1} 1 S 0:01 /tmp/testmanagerd".encode() for n in range(40))
        check(diagnostics._process_rows(many, 101)["rows_truncated"] and len(diagnostics._process_rows(many, 101)["rows"]) == 32, "ps-output-row-bound")
        check(diagnostics._process_rows(b"404 1 S 00:01 /tmp/com.apple.CoreSimulator.CoreSimulatorService", 101)["rows"][0]["pid"] == 404, "full-CoreSimulator-service-name-recognized")
        check(diagnostics._host_pid(b"202 0 UIKitApplication:dev.yuejing.app[session]\n") == 202, "selected-simulator-unique-host-pid")
        for payload, name in ((b"202 0 UIKitApplication:dev.yuejing.app.evil[x]", "reject-lookalike-bundle-pid"),
                              (b"- 0 UIKitApplication:dev.yuejing.app[x]", "missing-host-pid-unknown"),
                              (b"202 0 UIKitApplication:dev.yuejing.app[a]\n203 0 UIKitApplication:dev.yuejing.app[b]", "ambiguous-host-pid-unknown")):
            check(diagnostics._host_pid(payload) is None, name)
        device = json.dumps({"devices": {"runtime": [{"udid": UDID, "name": "synthetic iPhone", "state": "Booted", "isAvailable": True}, {"udid": "unrelated", "name": "private-other"}]}}).encode()
        parsed = diagnostics._device(device, UDID)
        check(parsed["state"] == "Booted" and "private-other" not in json.dumps(parsed), "device-state-scoped-to-selected-udid")
        reject(lambda: diagnostics._device(b'{"devices":{}}', UDID), "missing-selected-device-rejected")
        reject(lambda: diagnostics._device(b"not-json", UDID), "malformed-device-output-rejected")
        logs = json.dumps([{"eventMessage": "unrelated private message", "processImagePath": "/tmp/other"},
                           {"eventMessage": "launch dev.yuejing.app /Users/someone/private/path", "processImagePath": "/usr/libexec/testmanagerd", "processID": 44},
                           {"eventMessage": "dev.yuejing.app environment SECRET=synthetic-only", "processImagePath": "/tmp/testmanagerd"}]).encode()
        parsed = diagnostics._log_rows(logs, UDID)
        check(len(parsed["rows"]) == 2 and "unrelated private" not in json.dumps(parsed), "system-logs-keep-only-scoped-messages")
        check("/Users/" not in json.dumps(parsed) and "synthetic-only" not in json.dumps(parsed), "system-logs-redact-sensitive-records-and-paths")
        check(diagnostics._safe_text("https://example.invalid/key title=synthetic-book") == "<url> <redacted-content>", "url-and-content-redaction")
        check(len(diagnostics._safe_text("x" * 2000)) == 1200, "message-size-bound")
        reject(lambda: diagnostics._log_rows(b"{}", UDID), "unsupported-log-json-rejected")
        stack = diagnostics._stack(b"Path: /Users/synthetic/project\n" + b"synthetic-stack-frame\n" * 5000)
        check(stack["filtered_or_truncated"] and len(stack["text"]) <= 65536 and "/Users/" not in stack["text"], "stack-filter-and-truncation-explicit")

        # Exercise binary capture using fake subprocesses only.
        for label, fake, expected in (("observation-success", FakeCapture(), "observed"),
                                      ("observation-nonzero", FakeCapture(code=42), "unknown"),
                                      ("observation-output-limit", FakeCapture(b"x" * (diagnostics.MAX_CAPTURE_BYTES + 9000)), "unknown")):
            with patch.object(diagnostics.subprocess, "Popen", return_value=fake) as popen, \
                 patch.object(diagnostics, "_terminate_observation") as terminate:
                metadata, payload = diagnostics._capture(["synthetic-readonly-tool"], time.monotonic() + 1, lambda: False)
                check(metadata["status"] == expected and len(payload) <= diagnostics.MAX_CAPTURE_BYTES, label)
                check(popen.call_args.kwargs["start_new_session"] is True and "shell" not in popen.call_args.kwargs, label + "-isolated-no-shell")
                terminate.assert_called_once_with(fake, include_descendants=True)
        with patch.object(diagnostics.subprocess, "Popen") as popen:
            metadata, payload = diagnostics._capture(["must-not-run"], time.monotonic() + 1, lambda: True)
            check(metadata["reason"] == "cancelled-or-no-budget" and not popen.called, "cancelled-observation-never-spawns")
            metadata, _ = diagnostics._capture(["must-not-run"], time.monotonic() - 1, lambda: False)
            check(metadata["status"] == "unknown" and not popen.called, "exhausted-observation-never-spawns")
        with patch.object(diagnostics.subprocess, "Popen", side_effect=FileNotFoundError("synthetic")):
            metadata, _ = diagnostics._capture(["missing-tool"], time.monotonic() + 1, lambda: False)
            check(metadata["reason"] == "command-unavailable", "missing-tool-is-unknown")
        clock = StepClock()
        fake = FakeCapture(code=None)
        with patch.object(diagnostics.subprocess, "Popen", return_value=fake), \
             patch.object(diagnostics, "_terminate_observation") as terminate:
            metadata, _ = diagnostics._capture(["synthetic-hang"], 100.3, lambda: False, clock)
            check(metadata["reason"] == "command-deadline", "diagnostic-command-has-own-deadline")
            terminate.assert_called_once_with(fake, include_descendants=True)
        class BrokenPipe:
            def read(self, count): raise OSError("synthetic read failure")
            def close(self): pass
        with patch.object(diagnostics.subprocess, "Popen", return_value=FakeCapture(pipe=BrokenPipe())), \
             patch.object(diagnostics, "_terminate_observation"):
            metadata, _ = diagnostics._capture(["synthetic-read-error"], time.monotonic() + 1, lambda: False)
            check(metadata["reason"] == "output-read-error", "read-error-is-not-success")
        released = threading.Event()
        class HeldPipe:
            def read(self, count): released.wait(2); return b""
            def close(self): pass
        clock = StepClock()
        fake = FakeCapture(code=0, pipe=HeldPipe())
        with patch.object(diagnostics.subprocess, "Popen", return_value=fake), \
             patch.object(diagnostics, "_terminate_observation") as terminate:
            metadata, _ = diagnostics._capture(["synthetic-descendant-pipe"], 100.3, lambda: False, clock)
            check(metadata["status"] == "unknown" and not released.is_set(), "held-descendant-pipe-does-not-force-a-join")
            terminate.assert_called_once_with(fake, include_descendants=True)
        released.set()
        fake = FakeCapture(code=None)
        with patch.object(diagnostics.subprocess, "Popen", return_value=fake), \
             patch.object(diagnostics.threading, "Thread") as thread, \
             patch.object(diagnostics, "_terminate_observation") as terminate:
            thread.return_value.start.side_effect = RuntimeError("synthetic thread failure")
            metadata, _ = diagnostics._capture(["synthetic-thread-error"], time.monotonic() + 1, lambda: False)
            check(metadata["reason"] == "reader-unavailable", "reader-thread-failure-cleans-diagnostic-only")
            terminate.assert_called_once_with(fake, include_descendants=True)

        fake = FakeCapture(code=None)
        with patch.object(diagnostics.os, "killpg", create=True) as killpg:
            diagnostics._terminate_observation(fake, include_descendants=True)
            if os.name == "posix":
                killpg.assert_called_once_with(fake.pid, diagnostics.signal.SIGKILL)
                check(killpg.call_count == 1, "posix-cleanup-targets-diagnostic-session-only")
            else:
                check(fake.kills == 1, "nonposix-cleanup-targets-diagnostic-process-only")
        completed = FakeCapture(code=0)
        with patch.object(diagnostics.os, "killpg", create=True) as killpg:
            diagnostics._terminate_observation(completed, include_descendants=True)
            if os.name == "posix":
                killpg.assert_called_once_with(completed.pid, diagnostics.signal.SIGKILL)
                check(killpg.call_count == 1, "posix-cleanup-cleans-held-descendants")
            else:
                check(completed.kills == 0, "completed-observation-not-killed-on-nonposix")

        observed = observer(out, clock=lambda: 0)
        observed.process, observed.deadline = FakeNative(), 480
        observed.process.code = None
        check(not observed._cancelled(), "observer-active-before-deadline")
        observed.observe_line("SwiftCompile ordinary compilation\n")
        check(not observed.tests_started.is_set(), "build-output-not-a-test-start")
        for line in ("Test Suite 'All tests' started\n", "Test Case '-[Synthetic test]' started\n", "◇ Test run started.\n", "◇ Test synthetic() started.\n"):
            instance = observer(out); instance.observe_line(line)
            check(instance.tests_started.is_set() and instance.stopped.is_set(), "test-output-stops-observer:" + line.strip())
        observed.stop()
        check(observed._cancelled() and observed.process.kills == 0, "stop-does-not-kill-native-process")
        observed = observer(out, clock=lambda: 475)
        observed.process, observed.deadline = FakeNative(), 480
        check(observed._cancelled(), "observer-stops-before-native-deadline-margin")
        instance = observer(out); instance.provenance["target"] = "YueJingUITests"
        with patch.object(diagnostics.subprocess, "Popen") as popen:
            instance._observe()
            check(not popen.called, "observer-does-not-instrument-UI-or-nonmac-execution")

        # Mock only read-only diagnostic commands, no fake Xcode or acceptance files.
        captures = []
        def synthetic_capture(command, deadline, cancelled, clock):
            captures.append((command, deadline))
            if command[0] == "/bin/ps":
                payload = b"101 1 S 00:01 /Xcode/xcodebuild\n202 1 S 00:01 /tmp/YueJing\n"
            elif command[-2:] == ["available", "--json"]:
                payload = device
            elif command[-2:] == ["launchctl", "list"]:
                payload = b"202 0 UIKitApplication:dev.yuejing.app[synthetic]\n"
            elif command[-1] == "TESTMANAGERD_SIM_SOCK":
                payload = b"/private/tmp/synthetic-testmanager-socket"
            elif command[0] == "/usr/bin/sample":
                payload = b"synthetic stack dispatch_semaphore_wait\nPath: /Users/synthetic/app\n"
            else:
                payload = logs
            return {"status": "observed", "command": command, "returncode": 0}, payload
        instance = observer(out, clock=lambda: 0); instance.process, instance.deadline = FakeNative(), 480
        snapshot_root = out / "synthetic-snapshots"; snapshot_root.mkdir()
        with patch.object(diagnostics, "_capture", side_effect=synthetic_capture):
            instance._snapshot(snapshot_root, 1, UDID)
        check(len(captures) == 8 and all(deadline <= 3 for _, deadline in captures), "each-snapshot-command-capped-at-three-seconds")
        context = json.loads((snapshot_root / "snapshot-1/context.json").read_text(encoding="utf-8"))
        check(context["snapshot_deadline_monotonic"] == 15 and context["functional_deadline_monotonic"] == 480, "snapshot-budget-independent-of-functional-budget")
        check([args[1] for args, _ in captures if args[0] == "/usr/bin/sample"] == ["101", "202"], "samples-only-corroborated-native-and-selected-host-pids")
        check(all(args[-2:] == ["-file", "/dev/stdout"] for args, _ in captures if args[0] == "/usr/bin/sample"), "sample-output-explicitly-captured-not-a-default-temp-file")
        check(all(args[3] == UDID for args, _ in captures if args[:3] == ["/usr/bin/xcrun", "simctl", "spawn"]), "spawn-observations-use-only-selected-simulator")
        check(not any(token in args for args, _ in captures for token in ("boot", "shutdown", "erase", "install", "launch", "attach", "killall")), "no-mutating-simulator-debugger-or-retry-commands")
        records = [json.loads(p.read_text(encoding="utf-8")) for p in (snapshot_root / "snapshot-1").glob("*.json")]
        check(all("native_passed" not in row and "tests_passed" not in row for row in records), "diagnostics-never-write-test-acceptance")
        malformed = out / "synthetic-malformed"; malformed.mkdir()
        with patch.object(diagnostics, "_capture", return_value=({"status": "observed"}, b"not JSON")):
            result = instance._record(malformed, "device", ["synthetic-tool"], lambda data: diagnostics._device(data, UDID), 15)
            check(result is None and json.loads((malformed / "device.json").read_text())["status"] == "unknown", "malformed-observation-remains-unknown")
        missing = out / "synthetic-no-pid"; missing.mkdir()
        with patch.object(diagnostics, "_capture", return_value=({"status": "observed"}, b"")):
            result = instance._record(missing, "host", ["synthetic-tool"], diagnostics._host_pid, 15)
            check(result is None and json.loads((missing / "host.json").read_text())["status"] == "unknown", "missing-pid-not-an-observed-process")

        # Existing native stream lifecycle, tested with fake Popen/Timer only.
        class Timer:
            expire = False
            values = []
            def __init__(self, seconds, callback):
                self.callback, self.cancelled = callback, False; self.values.append(seconds)
            def start(self):
                if self.expire: self.callback()
            def cancel(self): self.cancelled = True
        class ThrowingObserver:
            def start(self, *args): raise OSError("synthetic diagnostic start failure")
            def observe_line(self, *args): raise RuntimeError("synthetic observation failure")
            def stop(self): raise OSError("synthetic stop failure")
        for code in (0, 65):
            fake = FakeNative(code=code)
            with patch.object(runner.subprocess, "Popen", return_value=fake), \
                 patch.object(runner.threading, "Timer", Timer), redirect_stdout(io.StringIO()):
                result = runner.stream_native(["synthetic-native-not-executed"], out / f"stream-{code}.log", 480, ThrowingObserver())
            check(result == (code, False), f"observer-exceptions-preserve-native-exit-{code}")
            check((out / f"stream-{code}.log").read_text() == "synthetic native output\n", f"observer-does-not-change-raw-log-{code}")
        Timer.expire = True
        fake = FakeNative()
        with patch.object(runner.subprocess, "Popen", return_value=fake), \
             patch.object(runner.threading, "Timer", Timer), redirect_stdout(io.StringIO()):
            result = runner.stream_native(["synthetic-timeout-not-executed"], out / "stream-timeout.log", 480, ThrowingObserver())
        check(result == (-9, True) and fake.kills == 1, "original-timeout-still-kills-native-once")
        check(Timer.values == [480, 480, 480], "diagnostics-never-extend-native-timer")
        Timer.expire = False
        began, release, finished = threading.Event(), threading.Event(), threading.Event()
        blocked = observer(out)
        def slow_worker():
            began.set(); release.wait(2); finished.set()
        blocked._observe = slow_worker
        with patch.object(runner.subprocess, "Popen", return_value=FakeNative()), \
             patch.object(runner.threading, "Timer", Timer), redirect_stdout(io.StringIO()):
            result = runner.stream_native(["synthetic-stream"], out / "stream-no-join.log", 480, blocked)
        check(began.is_set() and not finished.is_set() and result == (0, False), "native-stream-never-joins-blocked-observer")
        release.set(); blocked.thread.join(timeout=1)
        check(blocked.thread.daemon and finished.is_set(), "observation-worker-is-daemon")

        source = Path(runner.__file__).read_text(encoding="utf-8")
        tree = ast.parse(source)
        native = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "run_native")
        text = ast.get_source_segment(source, native)
        check('timeout_seconds = 480 if target == "YueJingHostTests" else 900' in text, "host-480-ui-900-budgets-preserved")
        check('"-default-test-execution-time-allowance", "180", "-maximum-test-execution-time-allowance", "180"' in text, "per-case-180-budgets-preserved")
        check('if timed_out:' in text and 'count_log(target,' in text and 'raise ValueError("Native target timed out' in text, "timeout-and-exact-case-gates-preserved")

    return {"kind": "SYNTHETIC_LAUNCH_DIAGNOSTICS_NOT_NATIVE", "passed": len(checked), "cases": checked,
            "native_executions": 0, "native_tool_commands": 0, "physical_device_acceptance": "not performed"}


if __name__ == "__main__":
    print(json.dumps(self_check(), indent=2))

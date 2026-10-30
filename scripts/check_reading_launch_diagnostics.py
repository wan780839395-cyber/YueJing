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
                payload = b"101 1 S 00:01 /Xcode/xcodebuild\n202 1 S 00:01 /tmp/YueJing\n303 1 S 00:01 /System/com.apple.CoreSimulator.CoreSimulatorService\n"
            elif command[-2:] == ["available", "--json"]:
                payload = device
            elif command[-2:] == ["launchctl", "list"]:
                payload = b"202 0 UIKitApplication:dev.yuejing.app[synthetic]\n"
            elif command[-1] == "TESTMANAGERD_SIM_SOCK":
                payload = b"/private/tmp/synthetic-testmanager-socket"
            elif command[0] == "/usr/bin/sample":
                process_name = "xcodebuild" if command[1] == "101" else "com.apple.CoreSimulator.CoreSimulatorService"
                payload = f"Process: {process_name} [{command[1]}]\nPath: /Users/synthetic/app\nCall graph:\n    10 Thread_synthetic\n    + 10 dispatch_semaphore_wait\n".encode()
            else:
                payload = logs
            return {"status": "observed", "command": command, "returncode": 0}, payload
        instance = observer(out, clock=lambda: 0); instance.process, instance.deadline = FakeNative(), 480
        snapshot_root = out / "synthetic-snapshots"; snapshot_root.mkdir()
        with patch.object(diagnostics, "_capture", side_effect=synthetic_capture):
            instance._snapshot(snapshot_root, 1, UDID)
        check(len(captures) == 3 and all(deadline <= 3 for _, deadline in captures), "each-priority-snapshot-command-capped-at-three-seconds")
        context = json.loads((snapshot_root / "snapshot-1/context.json").read_text(encoding="utf-8"))
        check(context["snapshot_deadline_monotonic"] == 15 and context["functional_deadline_monotonic"] == 480, "snapshot-budget-independent-of-functional-budget")
        check([args[1] for args, _ in captures if args[0] == "/usr/bin/sample"] == ["101", "303"], "samples-only-corroborated-native-and-unique-service-pids")
        check(all(args[-2:] == ["-file", "/dev/stdout"] for args, _ in captures if args[0] == "/usr/bin/sample"), "sample-output-explicitly-captured-not-a-default-temp-file")
        check([args[0] for args, _ in captures] == ["/bin/ps", "/usr/bin/sample", "/usr/bin/sample"], "process-then-native-then-service-no-simctl-or-log-probes")
        check(not any(token in args for args, _ in captures for token in ("boot", "shutdown", "erase", "install", "launch", "attach", "killall")), "no-mutating-simulator-debugger-or-retry-commands")
        records = [json.loads(p.read_text(encoding="utf-8")) for p in (snapshot_root / "snapshot-1").glob("*.json")]
        check(all("native_passed" not in row and "tests_passed" not in row for row in records), "diagnostics-never-write-test-acceptance")
        check(all(json.loads((snapshot_root / ("snapshot-1/" + name + ".json")).read_text())["status"] == "observed"
                  for name in ("xcodebuild-stack", "coresimulator-stack")), "priority-valid-stacks-actually-observed")
        malformed = out / "synthetic-malformed"; malformed.mkdir()
        with patch.object(diagnostics, "_capture", return_value=({"status": "observed"}, b"not JSON")):
            result = instance._record(malformed, "device", ["synthetic-tool"], lambda data: diagnostics._device(data, UDID), 15)
            check(result is None and json.loads((malformed / "device.json").read_text())["status"] == "unknown", "malformed-observation-remains-unknown")
        missing = out / "synthetic-no-pid"; missing.mkdir()
        with patch.object(diagnostics, "_capture", return_value=({"status": "observed"}, b"")):
            result = instance._record(missing, "host", ["synthetic-tool"], diagnostics._host_pid, 15)
            check(result is None and json.loads((missing / "host.json").read_text())["status"] == "unknown", "missing-pid-not-an-observed-process")

        # New priority profile: no fallback/retry or uncorroborated stacks.
        service_rows = diagnostics._process_rows(b"303 1 S 00:01 /System/CoreSimulatorService\n", 101)
        check(diagnostics._core_simulator_pid(service_rows) == 303, "unique-CoreSimulator-service-pid")
        for rows, label in ((None, "missing"), ({"rows": [], "rows_truncated": False}, "empty"),
                            ({"rows": service_rows["rows"], "rows_truncated": True}, "truncated"),
                            ({"rows": service_rows["rows"] * 2, "rows_truncated": False}, "duplicate"),
                            (diagnostics._process_rows(b"303 1 S 0:01 CoreSimulatorService\n304 1 S 0:01 com.apple.CoreSimulator.CoreSimulatorService", 101), "ambiguous-aliases")):
            check(diagnostics._core_simulator_pid(rows) is None, "service-pid-reject-" + label)
        good_stack = b"Process: xcodebuild [101]\nPath: /Users/synthetic/private\nCall graph:\n    10 Thread_1\n    + 10 start\n"
        parsed = diagnostics._validated_stack(good_stack, 101, {"xcodebuild"})
        check(parsed["pid"] == 101 and parsed["header_and_call_graph_present"] and "/Users/" not in parsed["text"], "stack-identity-graph-and-filter")
        for data, label in ((good_stack.replace(b"[101]", b"[999]"), "wrong-pid"),
                            (good_stack.replace(b"xcodebuild", b"OtherApp"), "wrong-name"),
                            (good_stack.split(b"Call graph")[0], "header-only"),
                            (b"Process: xcodebuild [101]\nCall graph:\n", "empty-graph"),
                            (b"Process: xcodebuild [101]\n" + good_stack, "duplicate-header"),
                            (b"Sampling process 101 for 1 second", "tool-message-only"),
                            (b"Process: xcodebuild [101]\nCall graph:\nTotal number in stack:\n    10 semaphore_wait_trap\n", "empty-graph-with-summary-counts"),
                            (b"Process: xcodebuild [101]\nCall graph:\n    10 Thread_1\nTotal number in stack:\n    10 semaphore_wait_trap\n", "thread-only-before-summary"),
                            (b"Process: xcodebuild [101]\nCall graph:\n    + 10 start\n", "frames-without-thread"),
                            (b"Process: xcodebuild [101]\nCall graph:\nBinary Images:\n    10 Thread_fake\n    + 10 start\n", "later-section-is-not-a-graph")):
            reject(lambda data=data: diagnostics._validated_stack(data, 101, {"xcodebuild"}), "stack-reject-" + label)
        for label, ps_payload, expected_pids in (
            ("missing-native", b"303 1 S 0:01 CoreSimulatorService\n", ["303"]),
            ("native-lookalike", b"101 1 S 0:01 OtherApp\n303 1 S 0:01 CoreSimulatorService\n", ["303"]),
            ("service-ambiguous", b"101 1 S 0:01 xcodebuild\n303 1 S 0:01 CoreSimulatorService\n304 1 S 0:01 CoreSimulatorService\n", ["101"]),
            ("duplicate-native", b"101 1 S 0:01 xcodebuild\n101 1 S 0:01 xcodebuild\n", []),
            ("truncated-ps", b"\n".join(f"{i+1} 1 S 0:01 testmanagerd".encode() for i in range(40)), [])):
            called = []
            def priority_capture(command, deadline, cancelled, clock):
                called.append(command)
                if command[0] == "/bin/ps": payload = ps_payload
                else:
                    name = "xcodebuild" if command[1] == "101" else "CoreSimulatorService"
                    payload = f"Process: {name} [{command[1]}]\nCall graph:\n    1 Thread_synthetic\n    + 1 start\n".encode()
                return {"status": "observed", "command": command, "returncode": 0}, payload
            folder = out / ("priority-" + label); folder.mkdir()
            with patch.object(diagnostics, "_capture", side_effect=priority_capture): instance._snapshot(folder, 1, UDID)
            check([c[1] for c in called if c[0] == "/usr/bin/sample"] == expected_pids, "priority-reject-" + label)
        folder = out / "priority-ps-timeout"; folder.mkdir()
        with patch.object(diagnostics, "_capture", return_value=({"status": "unknown", "reason": "command-deadline"}, b"")) as capture:
            instance._snapshot(folder, 1, UDID)
        check(capture.call_count == 1, "ps-failure-no-stack-or-retry")
        folder = out / "priority-expired"; folder.mkdir()
        expired = observer(out, clock=lambda: 480); expired.process, expired.deadline = FakeNative(), 480
        with patch.object(diagnostics.subprocess, "Popen") as popen: expired._snapshot(folder, 1, UDID)
        check(not popen.called, "priority-deadline-no-command-start")

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

        # Fixed-slot process timeline; still only fake Popen/Timer and local temp files.
        provenance = dict(source_commit="synthetic-sha", run_id="synthetic-run", run_attempt="1",
                          target="YueJingHostTests", scheme="YueJingUI", configuration="Debug")
        def timeline(directory=out):
            return diagnostics.ProcessLifecycleDiagnostics(directory, provenance, clock=StepClock(0.001), wall_clock=lambda: 1000.0)
        def event_map(trace): return {row["event"]: row for row in trace.snapshot()["events"]}
        trace = timeline()
        for _ in range(500):
            trace.observe_line("private-path-and-book-content-not-persisted\n")
            trace.observe_line("◇ Test synthetic() started.\n")
            trace.observe_line("** TEST SUCCEEDED **\n")
        trace.record("not-an-allowed-event", "private")
        trace.record("stream_error", "private/path or secret")
        snapshot = trace.snapshot()
        check(len(snapshot["events"]) == 3 and snapshot["maximum_events"] == 22, "lifecycle-fixed-slots-first-markers-only")
        check("private" not in json.dumps(snapshot) and "not-an-allowed" not in json.dumps(snapshot), "lifecycle-no-raw-output-or-error-messages")
        check("stdout_eof" in snapshot["unknown_events"] and snapshot["timer_thread_not_joined"], "missing-lifecycle-events-explicitly-unknown")

        for code in (0, 65):
            trace = timeline(); fake = FakeNative(code=code)
            with patch.object(runner.subprocess, "Popen", return_value=fake), patch.object(runner.threading, "Timer", Timer), redirect_stdout(io.StringIO()):
                result = runner.stream_native(["synthetic-no-execution"], out / f"timeline-{code}.log", 480, process_lifecycle=trace)
            events = event_map(trace)
            check(result == (code, False) and events["wait_returned"]["value"] == code, f"lifecycle-preserves-exit-{code}")
            check(events["popen_returned"]["monotonic"] < events["timer_started"]["monotonic"] < events["stdout_eof"]["monotonic"]
                  < events["wait_started"]["monotonic"] < events["wait_returned"]["monotonic"], f"lifecycle-order-{code}")
            check((out / f"timeline-{code}.log").read_text() == "synthetic native output\n", f"lifecycle-raw-log-identical-{code}")
        Timer.expire = True
        trace = timeline(); fake = FakeNative()
        with patch.object(runner.subprocess, "Popen", return_value=fake), patch.object(runner.threading, "Timer", Timer), redirect_stdout(io.StringIO()):
            result = runner.stream_native(["synthetic-timeout"], out / "timeline-timeout.log", 480, process_lifecycle=trace)
        events = event_map(trace)
        check(result == (-9, True) and fake.kills == 1 and events["timer_poll"]["value"] is None, "lifecycle-timeout-original-poll-and-one-kill")
        check(events["kill_requested"]["monotonic"] < events["kill_returned"]["monotonic"] < events["wait_returned"]["monotonic"], "kill-and-wait-recorded-separately")
        trace = timeline(); fake = FakeNative(); fake.code = 0
        with patch.object(runner.subprocess, "Popen", return_value=fake), patch.object(runner.threading, "Timer", Timer), redirect_stdout(io.StringIO()):
            result = runner.stream_native(["synthetic-exited"], out / "timeline-already-exited.log", 480, process_lifecycle=trace)
        check(result == (0, False) and fake.kills == 0 and event_map(trace)["timer_poll"]["value"] == 0, "poll-exited-does-not-kill-or-mark-timeout")
        class ExitsDuringKill(FakeNative):
            def kill(self): self.kills += 1; self.code = 0
        trace = timeline(); fake = ExitsDuringKill()
        with patch.object(runner.subprocess, "Popen", return_value=fake), patch.object(runner.threading, "Timer", Timer), redirect_stdout(io.StringIO()):
            result = runner.stream_native(["synthetic-race"], out / "timeline-exit-race.log", 480, process_lifecycle=trace)
        check(result == (0, True) and fake.kills == 1, "poll-kill-race-does-not-clear-original-timeout")
        Timer.expire = False

        class ControlledTimer(Timer):
            callback = None
            def __init__(self, seconds, callback):
                super().__init__(seconds, callback); ControlledTimer.callback = callback
        class SuccessThenDeadline(io.StringIO):
            def __next__(self):
                line = self.readline()
                if line: return line
                ControlledTimer.callback()
                raise StopIteration
        trace = timeline(); fake = FakeNative(); fake.stdout = SuccessThenDeadline("** TEST SUCCEEDED **\n")
        with patch.object(runner.subprocess, "Popen", return_value=fake), patch.object(runner.threading, "Timer", ControlledTimer), redirect_stdout(io.StringIO()):
            result = runner.stream_native(["synthetic-success-text"], out / "timeline-success-text-timeout.log", 480, process_lifecycle=trace)
        events = event_map(trace)
        check(result == (-9, True) and events["success_marker"]["monotonic"] < events["timer_callback"]["monotonic"] < events["stdout_eof"]["monotonic"], "success-text-never-bypasses-timeout")
        class DeadlineInWait(FakeNative):
            def wait(self): ControlledTimer.callback(); return super().wait()
        trace = timeline(); fake = DeadlineInWait(output="")
        with patch.object(runner.subprocess, "Popen", return_value=fake), patch.object(runner.threading, "Timer", ControlledTimer), redirect_stdout(io.StringIO()):
            result = runner.stream_native(["synthetic-eof-first"], out / "timeline-eof-first.log", 480, process_lifecycle=trace)
        events = event_map(trace)
        check(result == (-9, True) and events["stdout_eof"]["monotonic"] < events["wait_started"]["monotonic"] < events["timer_callback"]["monotonic"], "EOF-distinct-from-process-exit")
        trace = timeline(); fake = FakeNative(); fake.code = 0; fake.stdout = SuccessThenDeadline("** TEST SUCCEEDED **\n")
        with patch.object(runner.subprocess, "Popen", return_value=fake), patch.object(runner.threading, "Timer", ControlledTimer), redirect_stdout(io.StringIO()):
            result = runner.stream_native(["synthetic-exit-before-eof"], out / "timeline-exit-before-eof.log", 480, process_lifecycle=trace)
        check(result == (0, False) and fake.kills == 0 and event_map(trace)["timer_poll"]["value"] == 0, "exited-process-with-late-EOF-keeps-original-result")

        class ThrowingLifecycle:
            def record(self, *args): raise OSError("synthetic-private-message")
            def observe_line(self, *args): raise OSError("synthetic-private-message")
            def start(self, *args): raise OSError("synthetic-private-message")
            def finish(self, *args): raise OSError("synthetic-private-message")
            def snapshot(self): raise OSError("synthetic-private-message")
        for code, expire, expected in ((0, False, (0, False)), (65, False, (65, False)), (0, True, (-9, True))):
            Timer.expire = expire
            with patch.object(runner.subprocess, "Popen", return_value=FakeNative(code=code)), patch.object(runner.threading, "Timer", Timer), redirect_stdout(io.StringIO()):
                result = runner.stream_native(["synthetic-hook-failure"], out / f"timeline-hook-{code}-{expire}.log", 480, process_lifecycle=ThrowingLifecycle())
            check(result == expected, f"all-lifecycle-hook-errors-preserve-{code}-{expire}")
        Timer.expire = False
        check(runner._lifecycle_snapshot(ThrowingLifecycle())["status"] == "unknown", "snapshot-exception-is-non-gate-unknown")
        class InvalidSnapshot:
            def __init__(self, value): self.value = value
            def snapshot(self): return self.value
        for value, label in ((None, "missing"), ({"acceptance_role": "gate"}, "gate"),
                             ({"acceptance_role": "none", "payload": "x" * 17000}, "oversize"),
                             ({"acceptance_role": "none", "clock": float("nan")}, "nonfinite"),
                             ({"acceptance_role": "none", "object": object()}, "unserializable")):
            check(runner._lifecycle_snapshot(InvalidSnapshot(value))["status"] == "unknown", "snapshot-reject-" + label)
        trace = timeline()
        with patch.object(runner.subprocess, "Popen", side_effect=OSError("synthetic private path")), redirect_stdout(io.StringIO()):
            try: runner.stream_native(["synthetic-popen-error"], out / "timeline-popen-error.log", 480, process_lifecycle=trace)
            except OSError: pass
            else: raise AssertionError("Native Popen error was swallowed")
        check(event_map(trace)["popen_failed"]["value"] == "OSError" and "private" not in json.dumps(trace.snapshot()), "native-popen-error-propagates-without-private-message")
        class BrokenLines(io.StringIO):
            def __next__(self): raise OSError("synthetic native stream error")
        trace = timeline(); fake = FakeNative(); fake.stdout = BrokenLines()
        with patch.object(runner.subprocess, "Popen", return_value=fake), patch.object(runner.threading, "Timer", Timer), redirect_stdout(io.StringIO()):
            try: runner.stream_native(["synthetic-read-error"], out / "timeline-read-error.log", 480, process_lifecycle=trace)
            except OSError: pass
            else: raise AssertionError("Native read error was swallowed")
        check("stdout_eof" not in event_map(trace) and "wait_returned" not in event_map(trace) and "stream_unwound" in event_map(trace), "stream-error-does-not-invent-EOF-or-exit")

        # Real local daemon/file IO only; all subprocesses still fake. No main-thread writer join.
        folder = out / "lifecycle-journal"; folder.mkdir(); trace = timeline(folder)
        trace.record("popen_returned", 101)
        with patch.object(diagnostics.sys, "platform", "darwin"): trace.start(FakeNative(), 480)
        trace.record("wait_returned", -9); trace.finish(); trace.thread.join(timeout=1)
        journal = folder / "YueJingHostTests-process-lifecycle.jsonl"
        records = [json.loads(line) for line in journal.read_text().splitlines()]
        check(trace.writer_status == "finished" and len(records) == 3 and records[0]["acceptance_role"] == "none", "daemon-journal-keeps-bounded-partial-events")
        trace = timeline(folder)
        with patch.object(diagnostics.sys, "platform", "darwin"): trace.start(FakeNative(), 480)
        trace.finish(); trace.thread.join(timeout=1)
        check(trace.writer_status == "unavailable" and len(journal.read_text().splitlines()) == 3, "lifecycle-journal-never-overwrites-existing-evidence")
        trace = timeline(out / "lifecycle-missing-directory")
        with patch.object(diagnostics.sys, "platform", "darwin"): trace.start(FakeNative(), 480)
        trace.record("wait_returned", 65); trace.finish(); trace.thread.join(timeout=1)
        check(trace.writer_status == "unavailable" and event_map(trace)["wait_returned"]["value"] == 65, "journal-write-failure-keeps-inline-snapshot")
        trace = timeline()
        with patch.object(diagnostics.sys, "platform", "darwin"), patch.object(diagnostics.threading, "Thread") as worker:
            worker.return_value.start.side_effect = RuntimeError("synthetic worker unavailable")
            trace.start(FakeNative(), 480)
        check(trace.writer_status == "unavailable" and trace.writer_error_type == "RuntimeError", "lifecycle-worker-start-failure-is-unknown")
        began, release, finished = threading.Event(), threading.Event(), threading.Event()
        trace = timeline()
        def blocked_writer(): began.set(); release.wait(2); finished.set()
        trace._write_journal = blocked_writer
        with patch.object(diagnostics.sys, "platform", "darwin"), patch.object(runner.subprocess, "Popen", return_value=FakeNative()), patch.object(runner.threading, "Timer", Timer), redirect_stdout(io.StringIO()):
            result = runner.stream_native(["synthetic-blocked-writer"], out / "timeline-no-join.log", 480, process_lifecycle=trace)
        check(began.is_set() and not finished.is_set() and result == (0, False) and event_map(trace)["wait_returned"]["value"] == 0, "blocked-lifecycle-writer-cannot-hold-native-return")
        release.set(); trace.thread.join(timeout=1)
        check(trace.thread.daemon and finished.is_set(), "lifecycle-writer-is-daemon")
        trace = timeline(); trace.provenance["target"] = "YueJingUITests"
        with patch.object(diagnostics.sys, "platform", "darwin"), patch.object(diagnostics.threading, "Thread") as worker: trace.start(FakeNative(), 900)
        check(not worker.called, "lifecycle-journal-Host-only")

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

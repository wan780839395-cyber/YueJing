"""Best-effort App-host launch observations. Never authorizes or changes test results.

No boot/install/launch/attach/retry commands. An independent daemon owns bounded,
read-only subprocesses; the native runner never joins it or waits for its files.
"""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time

EARLY_SNAPSHOT_SECONDS = 90
LATE_LEAD_SECONDS = 40
SNAPSHOT_SECONDS = 15
COMMAND_SECONDS = 3
STOP_MARGIN_SECONDS = 5
MAX_CAPTURE_BYTES = 256 * 1024
MAX_PROCESS_ROWS = 32
MAX_LOG_ROWS = 80
PROCESS_NAMES = {"xcodebuild", "CoreSimulatorService", "com.apple.CoreSimulator.CoreSimulatorService", "simulatord", "testmanagerd",
                 "debugserver", "launchd_sim", "SpringBoard", "runningboardd", "YueJing", "xctest"}
TEST_OUTPUT = re.compile(r"^(?:Test Suite |Test Case |[◇✔✘] Test(?: run)? )")
BUNDLE_ID = "dev.yuejing.app"
CORE_SIMULATOR_NAMES = {"CoreSimulatorService", "com.apple.CoreSimulator.CoreSimulatorService"}
OBSERVATION_PROFILE = "priority-process-stacks-v2"


def _safe_text(value, limit=1200):
    # Never dump environment, credentials, URLs or content-bearing records.
    if re.search(r"environment|authorization|password|credential|secret|api[-_]?key", value, re.I):
        return "<redacted-sensitive-record>"
    value = re.sub(r"https?://\S+", "<url>", value)
    value = re.sub(r"/(?:Users|private|var|Volumes|home)/[^\s\"'<>]+", "<path>", value)
    value = re.sub(r"(?:book|title|body|text|书名|正文)\s*[:=].*", "<redacted-content>", value, flags=re.I)
    return value[:limit]


def _terminate_observation(process, include_descendants=False):
    """Only the diagnostic Popen's own new session, never the native process."""
    if process.poll() is not None and (not include_descendants or os.name != "posix"):
        return
    try:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
    except (ProcessLookupError, OSError):
        pass


def _capture(command, deadline, cancelled, clock=time.monotonic):
    """Bounded binary capture; no shell, unbounded communicate, or cleanup wait."""
    started = clock()
    metadata = {"status": "unknown", "command": command, "started_monotonic": started,
                "capture_limit_bytes": MAX_CAPTURE_BYTES, "deadline_monotonic": deadline}
    if cancelled() or started >= deadline:
        return {**metadata, "reason": "cancelled-or-no-budget"}, b""
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True, bufsize=0)
    except OSError as error:
        return {**metadata, "reason": "command-unavailable", "error_type": type(error).__name__}, b""
    chunks, size = [], 0
    lock, finished, overflow, read_error = threading.Lock(), threading.Event(), threading.Event(), threading.Event()
    def drain():
        nonlocal size
        try:
            while True:
                block = process.stdout.read(8192)
                if not block:
                    break
                with lock:
                    accepted = block[:max(0, MAX_CAPTURE_BYTES - size)]
                    if accepted:
                        chunks.append(accepted); size += len(accepted)
                    if len(accepted) != len(block):
                        overflow.set()
        except (OSError, ValueError):
            read_error.set()
        finally:
            finished.set()
            try:
                process.stdout.close()
            except OSError:
                pass
    try:
        threading.Thread(target=drain, name="launch-diagnostic-output", daemon=True).start()
    except RuntimeError:
        _terminate_observation(process, include_descendants=True)
        process.stdout.close()
        return {**metadata, "reason": "reader-unavailable"}, b""
    reason = None
    try:
        while process.poll() is None or not finished.is_set():
            if cancelled():
                reason = "cancelled"; break
            if clock() >= deadline:
                reason = "command-deadline"; break
            if overflow.is_set():
                reason = "output-limit"; break
            time.sleep(min(0.025, max(0, deadline - clock())))
        if overflow.is_set():
            reason = "output-limit"
        if read_error.is_set():
            reason = "output-read-error"
    finally:
        _terminate_observation(process, include_descendants=True)
    # No join/wait: a descendant holding a pipe cannot extend the observation budget.
    with lock:
        payload = b"".join(chunks)
    code = process.poll()
    return {**metadata, "status": "observed" if reason is None and code == 0 else "unknown",
            "reason": reason or (None if code == 0 else "command-nonzero"),
            "returncode": code, "captured_bytes": len(payload),
            "ended_monotonic": clock()}, payload


def _process_rows(payload, native_pid):
    rows = []
    for line in payload.decode("utf-8", errors="replace").splitlines():
        fields = line.strip().split(None, 4)
        if len(fields) != 5 or not fields[0].isdigit() or not fields[1].isdigit():
            continue
        pid, ppid, state, elapsed, command = fields
        name = Path(command).name
        if int(pid) == native_pid or name in PROCESS_NAMES:
            rows.append({"pid": int(pid), "ppid": int(ppid), "state": state[:16],
                         "elapsed": elapsed[:24], "name": name[:80]})
    return {"rows": rows[:MAX_PROCESS_ROWS], "rows_truncated": len(rows) > MAX_PROCESS_ROWS}


def _host_pid(payload):
    # launchctl was run inside the selected simulator. Reject lookalike bundle IDs.
    prefix = "UIKitApplication:" + BUNDLE_ID
    matches = []
    for line in payload.decode("utf-8", errors="replace").splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[0].isdigit() and int(fields[0]) > 0:
            label = fields[2]
            if label == prefix or label.startswith(prefix + "["):
                matches.append(int(fields[0]))
    return matches[0] if len(matches) == 1 else None


def _device(payload, udid):
    value = json.loads(payload)
    matches = [(runtime, device) for runtime, devices in value["devices"].items()
               for device in devices if device.get("udid") == udid]
    if len(matches) != 1:
        raise ValueError("selected simulator missing or ambiguous")
    runtime, device = matches[0]
    return {"udid": udid, "runtime": runtime, "name": device.get("name"),
            "state": device.get("state"), "available": device.get("isAvailable")}


def _log_rows(payload, udid):
    values = json.loads(payload)
    if not isinstance(values, list):
        raise ValueError("unexpected log JSON")
    result = []
    for value in values:
        message = value.get("eventMessage", "")
        if not isinstance(message, str) or (udid not in message and BUNDLE_ID not in message):
            continue
        result.append({"timestamp": str(value.get("timestamp", ""))[:64],
                       "process": Path(str(value.get("processImagePath", ""))).name[:80],
                       "pid": value.get("processID"), "message": _safe_text(message)})
    return {"rows": result[:MAX_LOG_ROWS], "rows_truncated": len(result) > MAX_LOG_ROWS}


def _stack(payload):
    raw = payload.decode("utf-8", errors="replace")
    filtered = "\n".join(_safe_text(line) for line in raw.splitlines())
    return {"text": filtered[:65536], "filtered_or_truncated": filtered != raw or len(filtered) > 65536,
            "not_a_debugger_attach": True}


def _core_simulator_pid(processes):
    # Host-wide service, NOT a claimed mapping to the selected simulator or App.
    if not processes or processes.get("rows_truncated"):
        return None
    matches = [row["pid"] for row in processes["rows"] if row["name"] in CORE_SIMULATOR_NAMES
               and type(row["pid"]) is int and row["pid"] > 0]
    return matches[0] if len(matches) == 1 else None


def _validated_stack(payload, expected_pid, expected_names):
    raw = payload.decode("utf-8", errors="replace")
    headers = re.findall(r"^\s*Process:\s*([^\r\n]+?)\s+\((\d+)\)\s*$", raw, re.MULTILINE)
    # Apple's sample header normally uses square brackets, not parentheses.
    headers += re.findall(r"^\s*Process:\s*([^\r\n]+?)\s+\[(\d+)\]\s*$", raw, re.MULTILINE)
    if len(headers) != 1 or int(headers[0][1]) != expected_pid or headers[0][0] not in expected_names:
        raise ValueError("sample process identity unconfirmed")
    graph = re.search(r"^Call graph:[ \t]*\r?$", raw, re.MULTILINE)
    if not graph:
        raise ValueError("sample call graph missing")
    graph_lines = []
    for line in raw[graph.end():].splitlines():
        if line.strip() and not line.startswith((" ", "\t")):
            break  # Stop at the next top-level section; summaries are not call frames.
        graph_lines.append(line)
    body = "\n".join(graph_lines)
    thread = re.search(r"^[ \t]+\d+[ \t]+Thread_\S+[^\r\n]*$", body, re.MULTILINE)
    if not thread or not re.search(r"^[ \t]+[+!:|]?[ \t]*\d+[ \t]+(?!Thread_)\S", body[thread.end():], re.MULTILINE):
        raise ValueError("sample call graph thread or frame missing")
    return {**_stack(payload), "pid": expected_pid, "process_name": headers[0][0],
            "header_and_call_graph_present": True, "pid_reuse_not_excluded": True}


class LaunchDiagnostics:
    """Optional observer only. start/observe_line/stop never perform command or file IO."""
    def __init__(self, out, destination, provenance, clock=None):
        self.out = Path(out)
        self.destination = destination
        self.provenance = {key: provenance.get(key) for key in
                           ("source_commit", "run_id", "run_attempt", "target", "scheme", "configuration")}
        self.clock = clock or time.monotonic
        self.stopped = threading.Event()
        self.tests_started = threading.Event()
        self.process = None
        self.deadline = 0
        self.thread = None

    def start(self, process, deadline):
        self.process, self.deadline = process, deadline
        self.thread = threading.Thread(target=self._observe, name="reading-launch-diagnostics", daemon=True)
        self.thread.start()

    def observe_line(self, line):
        if TEST_OUTPUT.match(line):
            self.tests_started.set(); self.stopped.set()

    def stop(self):
        self.stopped.set()  # Deliberately no join, wait, filesystem or process action.

    def _cancelled(self):
        return (self.stopped.is_set() or self.tests_started.is_set()
                or self.process.poll() is not None
                or self.clock() >= self.deadline - STOP_MARGIN_SECONDS)

    def _write(self, directory, name, value):
        with (directory / name).open("x", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")

    def _record(self, directory, name, command, parser, snapshot_deadline):
        deadline = min(snapshot_deadline, self.clock() + COMMAND_SECONDS)
        metadata, payload = _capture(command, deadline, self._cancelled, self.clock)
        record = {"kind": "NON_GATE_LAUNCH_OBSERVATION", **metadata,
                  "sequential_not_atomic": True, "may_perturb_timing": True}
        data = None
        if metadata["status"] == "observed":
            try:
                data = parser(payload)
                if data is None:
                    raise ValueError("observation unavailable or ambiguous")
                record["data"] = data
            except (ValueError, TypeError, KeyError, UnicodeError, AttributeError):
                record.update(status="unknown", reason="unsupported-or-incomplete-output")
        self._write(directory, name + ".json", record)
        return data if record["status"] == "observed" else None

    def _snapshot(self, root, number, udid):
        directory = root / ("snapshot-" + str(number)); directory.mkdir()
        deadline = min(self.clock() + SNAPSHOT_SECONDS, self.deadline - STOP_MARGIN_SECONDS)
        pid = self.process.pid
        self._write(directory, "context.json", {**self.provenance, "native_pid": pid, "selected_udid": udid,
                    "started_monotonic": self.clock(), "snapshot_deadline_monotonic": deadline,
                    "functional_deadline_monotonic": self.deadline, "acceptance_role": "none",
                    "observation_profile": OBSERVATION_PROFILE, "maximum_commands": 3,
                    "not_requested": ["device", "selected-simulator-host", "testmanager-socket", "host-stack",
                                      "host-system-log", "simulator-system-log"]})
        # Identity first, then the two useful stacks. No device/log/launchctl probes consume this window.
        processes = self._record(directory, "processes", ["/bin/ps", "-axo", "pid=,ppid=,stat=,etime=,comm="],
                                 lambda value: _process_rows(value, pid), deadline)
        rows = processes["rows"] if processes and not processes["rows_truncated"] else []
        native_matches = [row for row in rows if row["pid"] == pid]
        if len(native_matches) == 1 and native_matches[0]["name"] == "xcodebuild":
            self._record(directory, "xcodebuild-stack", ["/usr/bin/sample", str(pid), "1", "10", "-file", "/dev/stdout"],
                         lambda value: _validated_stack(value, pid, {"xcodebuild"}), deadline)
        else:
            self._write(directory, "xcodebuild-stack.json", {"kind": "NON_GATE_LAUNCH_OBSERVATION", "status": "unknown", "reason": "pid-not-corroborated"})
        service_pid = _core_simulator_pid(processes)
        if service_pid is not None:
            self._record(directory, "coresimulator-stack", ["/usr/bin/sample", str(service_pid), "1", "10", "-file", "/dev/stdout"],
                         lambda value: _validated_stack(value, service_pid, CORE_SIMULATOR_NAMES), deadline)
        else:
            self._write(directory, "coresimulator-stack.json", {"kind": "NON_GATE_LAUNCH_OBSERVATION", "status": "unknown", "reason": "service-pid-missing-ambiguous-or-truncated"})

    def _observe(self):
        root = self.out / "YueJingHostTests-launch-diagnostics"
        try:
            match = re.fullmatch(r"platform=iOS Simulator,id=([0-9a-fA-F-]{36})", self.destination or "")
            if sys.platform != "darwin" or self.provenance["target"] != "YueJingHostTests" or not match:
                return
            if not isinstance(self.process.pid, int) or self.process.pid <= 0 or self._cancelled():
                return
            # No following pre-existing directories/symlinks and no replacing evidence.
            root.mkdir()
            self._write(root, "context.json", {"kind": "NON_GATE_LAUNCH_OBSERVATIONS", **self.provenance,
                        "selected_udid": match[1], "native_pid": self.process.pid,
                        "functional_deadline_monotonic": self.deadline,
                        "snapshot_seconds": SNAPSHOT_SECONDS, "command_seconds": COMMAND_SECONDS,
                        "max_capture_bytes": MAX_CAPTURE_BYTES, "maximum_snapshots": 2,
                        "acceptance_role": "none", "may_perturb_timing": True})
            # A host-wide service stack is intentionally distinct from an App/UDID-scoped stack.
            self._write(root, "profile.json", {"observation_profile": OBSERVATION_PROFILE,
                        "order": ["processes", "xcodebuild-stack", "coresimulator-stack"],
                        "maximum_commands_per_snapshot": 3, "service_scope": "host-global-not-selected-device",
                        "acceptance_role": "none"})
            started = self.clock()
            offsets = (EARLY_SNAPSHOT_SECONDS, max(EARLY_SNAPSHOT_SECONDS + SNAPSHOT_SECONDS, self.deadline - started - LATE_LEAD_SECONDS))
            for number, offset in enumerate(offsets, 1):
                while not self._cancelled() and self.clock() < started + offset:
                    self.stopped.wait(min(0.25, started + offset - self.clock()))
                if self._cancelled():
                    break
                self._snapshot(root, number, match[1])
            self._write(root, "finished.json", {"status": "observed" if not self._cancelled() else "unknown",
                        "reason": "test-output-observed" if self.tests_started.is_set() else "observer-finished-or-cancelled",
                        "ended_monotonic": self.clock(), "acceptance_role": "none"})
        except Exception:
            # Missing/unfinished diagnostic files mean unknown, never native failure/success.
            pass


class ProcessLifecycleDiagnostics:
    """Fixed memory slots plus a best-effort daemon journal; never polls or controls a process.

    Every slot has one producer/callsite. Repeated stdout markers cannot grow the buffer.
    Writer IO never holds a lock needed by record/snapshot and is never joined by the runner.
    Missing events, a partial journal, and a snapshot racing the timer remain explicit unknowns.
    """
    EVENTS = ("popen_requested", "popen_returned", "popen_failed", "timer_started",
              "first_stdout", "test_output", "success_marker", "stdout_eof",
              "wait_started", "wait_returned", "stream_error", "timer_callback",
              "timer_poll", "timer_poll_failed", "kill_requested", "kill_returned", "kill_failed",
              "timer_cancelled", "stdout_closed", "stream_unwound", "stream_returned", "returned_timed_out")

    def __init__(self, out, provenance, clock=None, wall_clock=None):
        self.out = Path(out)
        self.provenance = {key: provenance.get(key) for key in
                           ("source_commit", "run_id", "run_attempt", "target", "scheme", "configuration")}
        self.clock, self.wall_clock = clock or time.monotonic, wall_clock or time.time
        self.slots = dict.fromkeys(self.EVENTS)
        self.wake, self.closed = threading.Event(), threading.Event()
        self.thread = None
        self.native_pid = None
        self.deadline = None
        self.writer_status = "not-started"
        self.writer_error_type = None

    def record(self, event, value=None):
        if event not in self.slots or self.slots[event] is not None:
            return
        if value is not None and type(value) not in (int, bool):
            if not isinstance(value, str) or len(value) > 80 or not value.isidentifier():
                return  # Only exception type identifiers, never messages/paths/output/arguments.
        self.slots[event] = (self.clock(), self.wall_clock(), value)
        self.wake.set()

    def observe_line(self, line):
        if self.slots["first_stdout"] is None:
            self.record("first_stdout")
        if self.slots["test_output"] is None and TEST_OUTPUT.match(line):
            self.record("test_output")
        if self.slots["success_marker"] is None and line.strip() == "** TEST SUCCEEDED **":
            self.record("success_marker")  # Text only, not process exit or test acceptance.

    def start(self, process, deadline):
        self.native_pid, self.deadline = process.pid, deadline
        if self.thread is not None or sys.platform != "darwin" or self.provenance["target"] != "YueJingHostTests":
            return
        if type(process.pid) is not int or process.pid <= 0:
            return
        self.thread = threading.Thread(target=self._write_journal, name="native-process-timeline", daemon=True)
        try:
            self.thread.start()
        except Exception as error:
            self.writer_status = "unavailable"; self.writer_error_type = type(error).__name__

    def finish(self):
        self.closed.set(); self.wake.set()  # No file IO, wait, join or process action.

    def _metadata(self):
        return {"schema": 1, "kind": "NON_GATE_NATIVE_PROCESS_LIFECYCLE", **self.provenance,
                "native_pid": self.native_pid, "functional_deadline_monotonic": self.deadline,
                "maximum_events": len(self.EVENTS), "acceptance_role": "none",
                "sequential_not_atomic": True, "timer_thread_not_joined": True,
                "missing_event_means": "unknown-not-recorded-not-a-success-or-failure",
                "may_perturb_timing": True}

    @staticmethod
    def _row(event, slot):
        return {"event": event, "monotonic": slot[0], "unix_seconds": slot[1], "value": slot[2]}

    def snapshot(self):
        # Fixed keys; immutable slot values. A concurrent timer may fill a later slot after this copy.
        captured = self.slots.copy()
        return {**self._metadata(), "snapshot_monotonic": self.clock(),
                "events": [self._row(event, slot) for event, slot in captured.items() if slot is not None],
                "unknown_events": [event for event, slot in captured.items() if slot is None],
                "writer_status": self.writer_status, "writer_error_type": self.writer_error_type}

    def _write_journal(self):
        try:
            path = self.out / "YueJingHostTests-process-lifecycle.jsonl"
            with path.open("x", encoding="utf-8") as stream:
                self.writer_status = "writing"
                stream.write(json.dumps(self._metadata(), ensure_ascii=True) + "\n"); stream.flush()
                written = set()
                while True:
                    self.wake.clear()
                    closing = self.closed.is_set()
                    for event in self.EVENTS:
                        slot = self.slots[event]
                        if slot is not None and event not in written:
                            stream.write(json.dumps(self._row(event, slot), ensure_ascii=True) + "\n")
                            stream.flush(); written.add(event)
                    if closing:
                        break
                    self.wake.wait(0.25)
            self.writer_status = "finished"
        except Exception as error:
            self.writer_status = "unavailable"; self.writer_error_type = type(error).__name__

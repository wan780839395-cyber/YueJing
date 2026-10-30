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
                    "functional_deadline_monotonic": self.deadline, "acceptance_role": "none"})
        self._record(directory, "device", ["/usr/bin/xcrun", "simctl", "list", "devices", "available", "--json"],
                     lambda value: _device(value, udid), deadline)
        processes = self._record(directory, "processes", ["/bin/ps", "-axo", "pid=,ppid=,stat=,etime=,comm="],
                                 lambda value: _process_rows(value, pid), deadline)
        host_pid = self._record(directory, "selected-simulator-host", ["/usr/bin/xcrun", "simctl", "spawn", udid, "launchctl", "list"], _host_pid, deadline)
        self._record(directory, "testmanager-socket", ["/usr/bin/xcrun", "simctl", "getenv", udid, "TESTMANAGERD_SIM_SOCK"],
                     lambda value: {"socket_path_reported": bool(value.strip())}, deadline)
        # Sample only identities corroborated by the scoped launchctl and process list.
        rows = processes["rows"] if processes and not processes["rows_truncated"] else []
        for name, sample_pid, expected in (("xcodebuild-stack", pid, "xcodebuild"), ("host-stack", host_pid, "YueJing")):
            if sample_pid and any(row["pid"] == sample_pid and row["name"] == expected for row in rows):
                self._record(directory, name, ["/usr/bin/sample", str(sample_pid), "1", "10", "-file", "/dev/stdout"], _stack, deadline)
            else:
                self._write(directory, name + ".json", {"kind": "NON_GATE_LAUNCH_OBSERVATION", "status": "unknown", "reason": "pid-not-corroborated"})
        scope = '(eventMessage CONTAINS[c] "' + udid + '" OR eventMessage CONTAINS[c] "' + BUNDLE_ID + '")'
        predicate = '(process == "CoreSimulatorService" OR process == "com.apple.CoreSimulator.CoreSimulatorService" OR process == "simulatord" OR process == "testmanagerd" OR process == "debugserver") AND ' + scope
        self._record(directory, "host-system-log", ["/usr/bin/log", "show", "--last", "2m", "--style", "json", "--predicate", predicate], lambda value: _log_rows(value, udid), deadline)
        self._record(directory, "simulator-system-log", ["/usr/bin/xcrun", "simctl", "spawn", udid, "log", "show", "--last", "2m", "--style", "json", "--predicate", scope], lambda value: _log_rows(value, udid), deadline)

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

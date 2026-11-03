"""Offline synthetic checks. AST-selected subject definitions; never run native tools."""
import argparse
import ast
from contextlib import contextmanager, redirect_stderr, redirect_stdout
import copy
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import re
import tempfile
import threading
import time
from types import SimpleNamespace
import uuid

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts/run_reading_ui_tests.py"
FROZEN = {
    "stream_native": "6ed3d311555c7ae32ea60b98a935f5afa211277d90deec62ea17e6a33decb892",
    "export_ui_evidence": "0c2335f09ade8f976f65cd9c71a4776e35286e8d811661cd855a6e2990d43be7",
    "count_log": "a2be2b055c0416383eccb42fc46c41474a73c82fbbec96ef6152130c19e99820",
    "run_native": "a973329c4c3c1f66399c1a621b76b0a62017b7e9016d85e7d7e1b442f2ae50e3",
}
DEFINITIONS = {"_UIProcessTimeline", "_ui_failure_kind", "_ui_export_exit", "_run_ui_attempt",
               "_diagnostic_call", "_lifecycle_snapshot", "write_new", "stream_native",
               "export_ui_evidence", "count_log", "run_native"}


def require(ok, message):
    if not ok:
        raise AssertionError(message)


def fingerprint(node):
    return hashlib.sha256(ast.dump(node, include_attributes=False).encode()).hexdigest()


def contracts(tree, baseline=None):
    nodes = {n.name: n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.ClassDef))}
    require(DEFINITIONS <= nodes.keys(), "Subject definition missing")
    for name in ("stream_native", "export_ui_evidence", "count_log"):
        require(fingerprint(nodes[name]) == FROZEN[name], "Original function changed: " + name)
    imports = ast.Module(body=[n for n in tree.body if isinstance(n, (ast.Import, ast.ImportFrom))], type_ignores=[])
    require(fingerprint(imports) == "e6ee0a666c58a9d1bf1813d6888b3ea2d90ed60dfad2d89e8b4a9f86831f7ae0", "Imports changed")
    virtual = copy.deepcopy(nodes["run_native"])
    loop = next(n for n in virtual.body if isinstance(n, ast.For))
    routes = [n for n in loop.body if isinstance(n, ast.If) and ast.unparse(n.test) == "target == 'YueJingUITests'"]
    require(len(routes) == 1, "Exactly one UI route required")
    route = routes[0]
    expected = ast.parse("code, timed_out = _run_ui_attempt(args, out, provenance, timeout_seconds)").body
    require(ast.dump(ast.Module(body=route.body, type_ignores=[])) == ast.dump(ast.Module(body=expected, type_ignores=[])), "UI route changed")
    final = ast.parse("if target == 'YueJingUITests':\n    export_ui_evidence(out, provenance, code)").body
    loop.body[loop.body.index(route)] = ast.Try(body=route.orelse, handlers=[], orelse=[], finalbody=final)
    require(fingerprint(virtual) == FROZEN["run_native"], "Host, commands, budgets, count/source gates changed")
    if baseline is not None:
        old_text = baseline.read_text(encoding="utf-8")
        new_text = RUNNER.read_text(encoding="utf-8")
        for old in ast.parse(old_text).body:
            if isinstance(old, ast.FunctionDef) and old.name != "run_native":
                require(ast.get_source_segment(old_text, old) == ast.get_source_segment(new_text, nodes[old.name]),
                        "Original function bytes changed: " + old.name)
    return nodes


def denied(*args, **kwargs):
    raise AssertionError("Real process/tool access is forbidden in this checker")


def load_subject(tree):
    selected = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name in DEFINITIONS]
    require(len(selected) == len(DEFINITIONS) and not any(n.decorator_list for n in selected), "Unsafe definition selection")
    ui = re.findall(r"func (test\w+)\(", (ROOT / "Tests/YueJingUITests/ReadingFlowUITests.swift").read_text(encoding="utf-8"))
    require(len(ui) == len(set(ui)) == 9, "Nine actual UI identities required")
    names = {"YueJingUITests": ui, "YueJingHostTests": ["syntheticHost" + str(i) for i in range(9)]}
    ns = dict(datetime=datetime, timezone=timezone, hashlib=hashlib, json=json, os=SimpleNamespace(environ={}),
              Path=Path, re=re, sys=SimpleNamespace(platform="darwin", stderr=io.StringIO()), time=time,
              threading=threading, uuid=uuid, ROOT=ROOT, GROUPS={k: len(v) for k, v in names.items()},
              declarations=lambda target: names[target], shutil=SimpleNamespace(which=lambda _: "/synthetic/tool"),
              actual_settings=denied,
              subprocess=SimpleNamespace(Popen=denied, run=denied, check_output=denied, PIPE=-1, STDOUT=-2))
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(RUNNER), "exec"), ns)
    return ns


@contextmanager
def override(ns, **values):
    before = {k: ns[k] for k in values}
    ns.update(values)
    try:
        yield
    finally:
        ns.update(before)


def expect_error(call, kind=Exception, text=None, same=None):
    try:
        call()
    except BaseException as error:
        require(isinstance(error, kind), "Wrong exception: " + type(error).__name__)
        require(text is None or text in str(error), "Failure classification missing: " + str(text))
        require(same is None or error is same, "Original exception object was replaced")
        return error
    raise AssertionError("Failure incorrectly accepted")


class Scenario:
    """Runs actual coordinator/export/count functions, replacing only native tool delivery."""
    def __init__(self, ns, folder, code=0, timed_out=False, native_error=None, export_code=0,
                 help_code=0, bad_attachment=None, log=None):
        self.ns, self.folder = ns, folder
        folder.mkdir()
        self.code, self.timed_out, self.native_error = code, timed_out, native_error
        self.export_code, self.help_code, self.bad_attachment = export_code, help_code, bad_attachment
        self.calls, self.export_entries = [], 0
        self.provenance = dict(source_commit="a" * 40, run_id="123", run_attempt="1", target="YueJingUITests",
                               scheme="YueJingUI", configuration="Debug", expected=9,
                               declared=ns["declarations"]("YueJingUITests"), timeout_seconds=900)
        good = "\n".join("Test Case '-[YueJingUITests.ReadingFlowUITests " + n + "]' passed (0.1 seconds)."
                         for n in self.provenance["declared"]) + "\n** TEST SUCCEEDED **\n"
        self.log = good if log is None else log
        self.original_export = ns["export_ui_evidence"]

    def stream(self, args, path, timeout_seconds, **kwargs):
        self.calls.append((list(args), timeout_seconds, kwargs))
        if args[:2] == ["xcodebuild", "test"]:
            observer = kwargs.get("process_lifecycle")
            for event, value in (("popen_requested", None), ("popen_returned", 321), ("timer_started", None)):
                self.ns["_diagnostic_call"](observer, "record", event, value)
            if self.native_error is not None:
                raise self.native_error
            path.write_text(self.log, encoding="utf-8")
            for event, value in (("stdout_eof", None), ("wait_started", None), ("wait_returned", self.code),
                                 ("stream_returned", self.code), ("returned_timed_out", self.timed_out)):
                self.ns["_diagnostic_call"](observer, "record", event, value)
            self.ns["_diagnostic_call"](observer, "finish")
            return self.code, self.timed_out
        if args == ["xcrun", "xcresulttool", "export", "attachments", "--help"]:
            require(timeout_seconds == 30, "Help budget changed")
            path.write_text("--path --output-path\n", encoding="utf-8")
            return self.help_code, False
        if args[:4] == ["xcrun", "xcresulttool", "export", "attachments"]:
            require(timeout_seconds == 120 and "--output-path" in args, "Export command/budget changed")
            path.write_text("synthetic export only\n", encoding="utf-8")
            if self.export_code == 0:
                self.attachments(Path(args[-1]))
            return self.export_code, False
        denied()

    def attachments(self, folder):
        if self.bad_attachment == "manifest":
            return
        manifest = []
        for name in self.provenance["declared"]:
            png, ax = name + ".png", name + ".txt"
            if self.bad_attachment != "png":
                (folder / png).write_bytes(b"\x89PNG\r\n\x1a\nSYNTHETIC-NOT-IMAGE-ACCEPTANCE")
            if self.bad_attachment != "ax":
                text = "YueJing UI evidence\ncase: " + name + "\nstage: open\nfullAppDebugDescription:\nsynthetic hierarchy\n"
                (folder / ax).write_bytes(text.encode("utf-8"))
            manifest.append(dict(testIdentifier=name, attachments=[dict(exportedFileName=png), dict(exportedFileName=ax)]))
        (folder / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")

    def export(self, out, provenance, code):
        self.export_entries += 1
        return self.original_export(out, provenance, code)

    def run(self):
        with override(self.ns, stream_native=self.stream, export_ui_evidence=self.export):
            return self.ns["_run_ui_attempt"](["xcodebuild", "test", "-only-testing:YueJingUITests"],
                                               self.folder, self.provenance, 900)

    def check_once(self, exports=1):
        require(sum(a[0] == "xcodebuild" for a, _, _ in self.calls) == 1, "Native delivery count changed")
        require(self.export_entries == 1, "Export entry count changed")
        require(sum(a[:4] == ["xcrun", "xcresulttool", "export", "attachments"] and a[-1] != "--help"
                    for a, _, _ in self.calls) == exports, "Export delivery count changed")


class FakePipe:
    def __init__(self, error=None):
        self.error, self.closed = error, False

    def __iter__(self):
        if self.error:
            raise self.error
        yield "Test Case '-[YueJingUITests.ReadingFlowUITests testSynthetic]' started.\n"

    def close(self):
        self.closed = True


def stream_check(ns, folder, fire=False, failure=None):
    trace = []
    pipe = FakePipe(OSError("synthetic read") if failure == "read" else None)
    class Process:
        pid = 321
        def poll(self):
            trace.append("poll")
            return None
        def kill(self):
            trace.append("kill")
        def wait(self):
            trace.append("wait")
            if failure == "wait":
                raise OSError("synthetic wait")
            return -9 if fire else 0
    process = Process()
    process.stdout = pipe
    def popen(args, **kwargs):
        trace.append(("Popen", args, kwargs))
        if failure == "popen":
            raise OSError("synthetic popen")
        return process
    class Timer:
        def __init__(self, seconds, callback):
            require(seconds == 900, "Timer moved/changed")
            self.callback = callback
        def start(self):
            trace.append("timer_start")
            if fire:
                self.callback()
        def cancel(self):
            trace.append("timer_cancel")
    timeline = ns["_UIProcessTimeline"](folder / "timeline.json", dict(target="YueJingUITests"))
    proc = SimpleNamespace(Popen=popen, PIPE=-1, STDOUT=-2)
    threads = SimpleNamespace(Event=threading.Event, Lock=threading.Lock, Timer=Timer)
    with override(ns, subprocess=proc, threading=threads):
        call = lambda: ns["stream_native"](["synthetic-xcodebuild"], folder / "stream.log", 900, process_lifecycle=timeline)
        if failure:
            expect_error(call, OSError, "synthetic " + failure)
        else:
            require(call() == ((-9, True) if fire else (0, False)), "Native result changed")
    require(sum(isinstance(x, tuple) and x[0] == "Popen" for x in trace) == 1, "Popen repeated")
    require(trace.count("kill") == int(fire) and trace.count("poll") == int(fire), "Added poll/signal")
    if failure != "popen":
        require(pipe.closed and trace.count("timer_cancel") == 1, "Original cleanup changed")
    events = [e["event"] for e in timeline.snapshot()["events"]]
    require(("first_test_start_observed" in events) == (failure not in ("read", "popen")), "First-start observation changed")
    if fire:
        require(events.index("timer_callback") < events.index("kill_requested") < events.index("kill_returned"), "Kill observation order")
    require(not (folder / "timeline.json").exists(), "Callback performed disk IO")


def self_check(tree, baseline=None, evidence=None):
    contracts(tree, baseline)
    checked = ["contracts:unchanged-stream-export-count-host-commands-budgets-imports"]
    scratch = os.environ.get("PI_SCRATCH_DIR")
    with tempfile.TemporaryDirectory(prefix="ui-failure-chain-synthetic-", dir=scratch) as temp:
        root = Path(temp)
        counter = 0
        def folder():
            nonlocal counter
            counter += 1
            return root / str(counter)
        def case(label, function):
            function()
            checked.append(label)
        for code, timed, export, label in [(-9, True, 64, "NATIVE_TIMEOUT"), (65, False, 64, "NATIVE_FAILURE"),
                                            (0, False, 64, "ATTACHMENT_EXPORT_ERROR"), (-9, True, 0, "NATIVE_TIMEOUT"),
                                            (65, False, 0, "NATIVE_FAILURE"), (0, True, 64, "NATIVE_TIMEOUT")]:
            ns = load_subject(tree)
            sc = Scenario(ns, folder(), code, timed, export_code=export)
            def test(sc=sc, ns=ns, label=label):
                expect_error(sc.run, ValueError, label)
                sc.check_once()
                if sc.export_code != 0:
                    require("UI attachment export error:" in ns["sys"].stderr.getvalue(), "Secondary export detail lost")
                value = json.loads((sc.folder / "YueJingUITests-execution.json").read_text())
                require(value == {**sc.provenance, "native_exit": sc.code, "timed_out": sc.timed_out}, "Original receipt fields changed")
                require((sc.folder / "YueJingUITests-exit-code.txt").read_text().strip() == str(sc.code), "Native code overwritten")
                events = json.loads((sc.folder / "YueJingUITests-process-timeline.json").read_text())["events"]
                labels = [e["event"] for e in events]
                require(labels.index("native_stream_finished") < labels.index("export_started") < len(labels) - 1, "Timeline sealed before export")
            case(f"precedence:{code}:{timed}:{export}", test)
        for error in [OSError("synthetic popen"), RuntimeError("synthetic read"), KeyboardInterrupt(), SystemExit(7)]:
            ns = load_subject(tree)
            sc = Scenario(ns, folder(), native_error=error, export_code=64)
            def test(sc=sc, error=error):
                result = expect_error(sc.run, type(error), same=error)
                sc.check_once()
                require(not (sc.folder / "YueJingUITests-execution.json").exists(), "Invented native result after exception")
                require(any(f.tb_frame.f_code.co_name == "stream" for f in traceback_frames(result.__traceback__)), "Original traceback missing")
            case("execution-exception:" + type(error).__name__, test)
        for code, timed, label in [(0, False, "synthetic receipt"), (-9, True, "NATIVE_TIMEOUT"), (65, False, "NATIVE_FAILURE")]:
            ns = load_subject(tree)
            sc = Scenario(ns, folder(), code, timed, export_code=64)
            original = ns["write_new"]
            def broken(path, value):
                if path.name == "YueJingUITests-execution.json":
                    raise OSError("synthetic receipt")
                original(path, value)
            def test(sc=sc, ns=ns, broken=broken, label=label, code=code):
                with override(ns, write_new=broken):
                    expect_error(sc.run, OSError if code == 0 else ValueError, label)
                sc.check_once()
            case("receipt-write:" + str(code), test)
        ns = load_subject(tree)
        sc = Scenario(ns, folder(), help_code=1)
        case("help-failure-no-export-delivery", lambda: (expect_error(sc.run, ValueError, "ATTACHMENT_EXPORT_ERROR"), sc.check_once(exports=0)))
        for bad in ["manifest", "png", "ax"]:
            ns = load_subject(tree)
            sc = Scenario(ns, folder(), bad_attachment=bad)
            case("evidence-gate:" + bad, lambda sc=sc: (expect_error(sc.run, ValueError, "ATTACHMENT_EXPORT_ERROR"), sc.check_once()))
        for mode in ["good", "missing", "duplicate", "skip", "failed", "unknown", "unfinished"]:
            ns = load_subject(tree)
            sc = Scenario(ns, folder())
            lines = sc.log.splitlines()
            bad_log = {"good": sc.log, "missing": "\n".join(lines[1:]), "duplicate": sc.log + lines[0],
                       "skip": sc.log + "Test Case skipped", "failed": sc.log + "Test example failed",
                       "unknown": sc.log + "Test Case '-[YueJingUITests.ReadingFlowUITests testUnknown]' passed (0.1 seconds).",
                       "unfinished": "\n".join(lines[1:]) + "\nTest Case '-[YueJingUITests.ReadingFlowUITests " + sc.provenance["declared"][0] + "]' started."}[mode]
            sc.log = bad_log
            def test(sc=sc, ns=ns, mode=mode):
                require(sc.run() == (0, False), "Valid coordinator result changed")
                call = lambda: ns["count_log"]("YueJingUITests", sc.log, 0)
                if mode == "good":
                    require(len(call()["passed"]) == 9, "Nine-count success gate changed")
                else:
                    expect_error(call, ValueError)
            case("count-gate:" + mode, test)
        for fire, fail in [(False, None), (True, None), (False, "popen"), (False, "read"), (False, "wait")]:
            ns = load_subject(tree)
            p = folder(); p.mkdir()
            case("original-stream:" + str((fire, fail)), lambda ns=ns, p=p, fire=fire, fail=fail: stream_check(ns, p, fire, fail))
        ns = load_subject(tree)
        cls = ns["_UIProcessTimeline"]
        p = folder(); p.mkdir()
        timeline = cls(p / "timeline.json", dict(target="YueJingUITests", secret="DO_NOT_RECORD"))
        def bounded():
            workers = [threading.Thread(target=lambda: [timeline.record("timer_poll", "DO_NOT_RECORD") for _ in range(100)]) for _ in range(4)]
            for worker in workers: worker.start()
            for worker in workers: worker.join()
            require(timeline.persist(), "Timeline not persisted")
            raw = (p / "timeline.json").read_bytes(); value = json.loads(raw)
            require(len(raw) <= 16384 and len(value["events"]) <= 64 and value["truncated"], "Timeline caps missing")
            require(value["acceptance_role"] == "none" and b"DO_NOT_RECORD" not in raw, "Private data/gate value retained")
            require([x["sequence"] for x in value["events"]] == list(range(1, len(value["events"]) + 1)), "Concurrent sequence invalid")
            before = raw
            require(timeline.persist() is False and (p / "timeline.json").read_bytes() == before, "Exclusive sidecar overwritten")
        case("timeline:caps-thread-safety-privacy-exclusive-write", bounded)
        for clock in [lambda: float("nan"), lambda: float("inf"), lambda: (_ for _ in ()).throw(OSError("clock"))]:
            timeline = cls(p / "unused.json", {})
            with override(ns, time=SimpleNamespace(monotonic=clock)):
                timeline.record("timer_started")
            case("timeline:unknown-clock-" + str(len(checked)), lambda timeline=timeline: require(timeline.snapshot()["status"] == "unknown", "Invalid clock accepted"))
        ns = load_subject(tree)
        timeline = ns["_UIProcessTimeline"](p / "unused2.json", {})
        ticks = iter([10.0, 11.0]); utc = iter(["2026-11-03T03:00:00+00:00", "2026-11-03T02:00:00+00:00"])
        clock = SimpleNamespace(now=lambda _: SimpleNamespace(isoformat=lambda: next(utc)))
        with override(ns, datetime=clock, time=SimpleNamespace(monotonic=lambda: next(ticks))):
            timeline.record("popen_requested"); timeline.record("popen_returned", 321)
        case("timeline:UTC-jump-monotonic-order", lambda: require([e["monotonic"] for e in timeline.snapshot()["events"]] == [10.0, 11.0], "UTC incorrectly controls durations"))
        for failure in ["constructor", "persist"]:
            ns = load_subject(tree)
            sc = Scenario(ns, folder())
            real = ns["_UIProcessTimeline"]
            def broken(*a, **kw):
                if failure == "constructor": raise OSError("diagnostic constructor")
                obj = real(*a, **kw)
                obj.persist = lambda: (_ for _ in ()).throw(OSError("diagnostic write"))
                return obj
            def test(ns=ns, sc=sc, broken=broken):
                with override(ns, _UIProcessTimeline=broken):
                    require(sc.run() == (0, False), "Diagnostic IO changed native outcome")
            case("timeline:isolated-" + failure, test)
        for code, timed in [(None, False), (False, False), (0, None)]:
            ns = load_subject(tree)
            case("unavailable-native-result:" + str((code, timed)), lambda ns=ns, code=code, timed=timed: require(
                ns["_ui_failure_kind"](code, timed) == "NATIVE_RESULT_UNAVAILABLE", "Invalid native result accepted"))
        for error in [KeyboardInterrupt(), SystemExit(8)]:
            ns = load_subject(tree)
            sc = Scenario(ns, folder())
            sc.original_export = lambda *a, error=error: (_ for _ in ()).throw(error)
            case("export-control:" + type(error).__name__, lambda sc=sc, error=error: (
                expect_error(sc.run, type(error), same=error), sc.check_once(exports=0)))
        ns = load_subject(tree)
        p = folder(); p.mkdir()
        timeline = ns["_UIProcessTimeline"](p / "tiny.json", {"target": "YueJingUITests"})
        timeline.MAX_BYTES = 600  # Exercise the byte trimming path without changing production limits.
        for _ in range(20): timeline.record("timer_poll", 123)
        case("timeline:byte-cap-trimming", lambda: require(timeline.persist() and
             len((p / "tiny.json").read_bytes()) <= 600 and json.loads((p / "tiny.json").read_bytes())["truncated"], "Byte cap did not trim"))
        timeline = ns["_UIProcessTimeline"](p / "private.json", {"target": "private-token", "run_id": "private-token"})
        timeline.record("private-token", "private-token")
        timeline.observe_line("private-token" * 1000)
        case("timeline:arbitrary-input-not-retained", lambda: require("private-token" not in json.dumps(timeline.snapshot()) and
             timeline.snapshot()["status"] == "unknown", "Arbitrary data retained"))
        # Integration with actual run_native, including its original final count/source gates.
        for target in ["YueJingUITests", "YueJingHostTests"]:
            ns = load_subject(tree)
            r = folder(); r.mkdir()
            (r / "project.yml").write_text("synthetic", encoding="utf-8")
            (r / "build/SourcePackages/checkouts/GRDB.swift").mkdir(parents=True)
            resolved = r / "YueJing.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            resolved.parent.mkdir(parents=True)
            pin = {"location": "https://github.com/groue/GRDB.swift.git", "state": {"version": "7.0.0"}}
            resolved.write_text(json.dumps({"pins": [pin]}), encoding="utf-8")
            sc = Scenario(ns, r / "artifacts")
            if target == "YueJingHostTests":
                sc.log = "\n".join("Test " + n + "() passed after 0.1 seconds." for n in ns["declarations"](target)) + "\nTest run with 9 tests passed after 0.1 seconds.\n** TEST SUCCEEDED **\n"
            class HostObserver:
                def __getattr__(self, name): return lambda *a: None
                def snapshot(self): return dict(acceptance_role="none", status="synthetic")
            ns["LaunchDiagnostics"] = lambda *a: HostObserver()
            ns["ProcessLifecycleDiagnostics"] = lambda *a: HostObserver()
            def output(args, **kw):
                if args[:2] == ["xcodebuild", "-version"]: return "Xcode 16.4\nBuild version 16F6"
                if args[:3] == ["xcrun", "swift", "--version"]: return "Apple Swift version 6.1.2"
                if args == ["git", "rev-parse", "HEAD"]: return "a" * 40
                denied()
            proc = SimpleNamespace(check_output=output, Popen=denied, run=denied, PIPE=-1, STDOUT=-2)
            with override(ns, ROOT=r, subprocess=proc, actual_settings=lambda *a: None,
                          stream_native=sc.stream, export_ui_evidence=sc.export):
                ns["run_native"]("platform=iOS Simulator,id=" + "0" * 8 + "-" + "0" * 4 + "-" + "0" * 4 + "-" + "0" * 4 + "-" + "0" * 12, target, "artifacts")
            case("integration:actual-run-native:" + target, lambda sc=sc, target=target: require(
                len(json.loads((sc.folder / (target + "-counts.json")).read_text())["passed"]) == 9 and
                sc.export_entries == int(target == "YueJingUITests") and
                next(t for a, t, _ in sc.calls if a[0] == "xcodebuild") == (900 if target == "YueJingUITests" else 480), "Host/UI integration changed"))
        # Deliberately broken implementations must be detected, not silently accepted.
        for code, timed, export in [(-9, True, 64), (0, False, 64)]:
            ns = load_subject(tree); sc = Scenario(ns, folder(), code, timed, export_code=export)
            with override(ns, _ui_failure_kind=lambda *a: None):
                expect_error(lambda: expect_error(sc.run, ValueError), AssertionError)
            checked.append("negative-control:swallowed-failure:" + str(code))
        mutant = copy.deepcopy(tree)
        fn = next(n for n in mutant.body if isinstance(n, ast.FunctionDef) and n.name == "count_log")
        fn.body = [ast.Return(value=ast.Dict(keys=[], values=[]))]
        case("negative-control:weakened-count-gate", lambda: expect_error(lambda: contracts(mutant), AssertionError))
        ns = load_subject(tree); sc = Scenario(ns, folder())
        original_stream = sc.stream
        def duplicate_stream(*args, **kwargs):
            if args[0][:2] == ["xcodebuild", "test"]:
                original_stream(*args, **kwargs)
            return original_stream(*args, **kwargs)
        sc.stream = duplicate_stream
        require(sc.run() == (0, False), "Broken duplicate fixture did not reach delivery-count check")
        case("negative-control:duplicate-native-delivery", lambda: expect_error(sc.check_once, AssertionError, "Native delivery count changed"))
        if evidence is not None:
            require(evidence.is_dir() and (evidence / "YueJingUITests-execution.json").is_file(), "Evidence folder missing")
            ex = json.loads((evidence / "YueJingUITests-execution.json").read_bytes())
            export = json.loads((evidence / "attachment-export.json").read_bytes())
            require(ex["source_commit"] == "a6bb53aa563489f9d72aed428ca772ffc39320ae" and ex["run_id"] == "41573803328" and
                    ex["native_exit"] == -9 and ex["timed_out"] is True and export["export_exit"] == 64, "Historical fixture differs")
            ns = load_subject(tree)
            case("historical:timeout-plus-export64-remains-failed", lambda: require(
                ns["_ui_failure_kind"](ex["native_exit"], ex["timed_out"], export_error=ValueError("recorded export64")) == "NATIVE_TIMEOUT", "Historical failure relabelled"))
            checked.append("historical:original-files-read-only-not-native-reexecution")
            raw = (evidence / "YueJingUITests.log").read_bytes()
            require(hashlib.sha256(raw).hexdigest() == "f94fc462de4c3c66bb7cb4a2e8a14dbdfd9c810882ebecf6666bd63ea60ca842", "Historical raw log differs")
            case("historical:unfinished-raw-log-cannot-pass-count", lambda: expect_error(
                lambda: ns["count_log"]("YueJingUITests", raw.decode("utf-8"), ex["native_exit"]), ValueError))
    return dict(kind="SYNTHETIC_NOT_NATIVE", passed=len(checked), failed=0, cases=checked,
                native_executions=0, real_processes=0, network_requests=0, exports=0,
                limits="No Xcode/UIKit compilation, UI execution, full146 or performance acceptance")

def traceback_frames(tb):
    while tb is not None:
        yield tb
        tb = tb.tb_next


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-check", action="store_true", required=True)
    parser.add_argument("--baseline", type=Path, help="Frozen original runner for byte/AST comparisons")
    parser.add_argument("--evidence", type=Path, help="Existing reading-ui-native folder, read only")
    args = parser.parse_args()
    with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
        result = self_check(ast.parse(RUNNER.read_text(encoding="utf-8")), args.baseline, args.evidence)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

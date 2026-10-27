"""One native performance invocation; preserve partial synthetic evidence even on failure."""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

OUT = Path("artifacts/txt-core-performance")
OUT.mkdir(parents=True, exist_ok=True)
SIZES = [10 * 1024 * 1024, 50 * 1024 * 1024]
PREFIX = "TXT_PERF_EVENT "


def main():
    udid = os.environ["SIMULATOR_UDID"]
    if not re.fullmatch(r"[0-9A-Fa-f-]{36}", udid):
        raise ValueError("Unexpected simulator identity")
    command = [
        "xcodebuild", "-project", "YueJing.xcodeproj", "-scheme", "TXTCorePerformance",
        "-configuration", "Release", "-sdk", "iphonesimulator",
        "-destination", "platform=iOS Simulator,id=" + udid,
        "-derivedDataPath", "build/TXTPerformanceDerivedData",
        "-resultBundlePath", str(OUT / "native-performance.xcresult"),
        "-parallel-testing-enabled", "NO", "-only-testing:TXTCorePerformanceTests",
        "CODE_SIGNING_ALLOWED=NO", "ARCHS=" + os.environ["SIMULATOR_ARCH"],
        "ONLY_ACTIVE_ARCH=YES", "test",
    ]
    metadata = dict(source_commit=os.environ["GITHUB_SHA"], run_id=os.environ["GITHUB_RUN_ID"],
                    runner_label="macos-15", runner_os=os.environ.get("RUNNER_OS"),
                    runner_arch=os.environ.get("RUNNER_ARCH"), configuration="Release",
                    simulator=json.loads((OUT / "simulator-selection.json").read_text()),
                    effective_settings=json.loads((OUT / "effective-test-settings.json").read_text()),
                    native_timeout_seconds=600, test_time_limit_minutes=8,
                    sample_sizes_bytes=SIZES, ordinary_regression_tests_executed=0)
    (OUT / "run-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    started = time.time()
    stream_events, stream_errors = [], []
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)

    def drain():
        try:
            with (OUT / "xcodebuild-performance.log").open("wb") as log, (OUT / "stdout-events.jsonl").open("w") as events:
                for raw in iter(process.stdout.readline, b""):
                    log.write(raw)
                    log.flush()
                    sys.stdout.buffer.write(raw)
                    sys.stdout.buffer.flush()
                    text = raw.decode("utf-8", errors="replace")
                    if PREFIX in text:
                        event = json.loads(text.split(PREFIX, 1)[1])
                        stream_events.append(event)
                        events.write(json.dumps(event) + "\n")
                        events.flush()
        except Exception as error:
            stream_errors.append(repr(error))
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass

    reader = threading.Thread(target=drain, daemon=True)
    reader.start()
    timed_out = False
    try:
        native_exit = process.wait(timeout=600)
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            native_exit = process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            native_exit = process.wait(timeout=10)
    reader.join(timeout=10)
    if reader.is_alive():
        stream_errors.append("Native stdout reader did not finish")
    (OUT / "test-exit-code.txt").write_text(str(native_exit) + "\n")

    # Native writes are synchronized before work begins. Search only this simulator and the runner temp area.
    roots = [Path.home() / "Library/Developer/CoreSimulator/Devices" / udid / "data", Path(tempfile.gettempdir())]
    recovered, recovery_errors = [], []
    for root in roots:
        if not root.exists():
            continue
        try:
            for source in root.rglob("txt-core-performance-*.jsonl"):
                if source.stat().st_mtime < started - 5:
                    continue
                destination = OUT / ("recovered-" + str(len(recovered)) + ".jsonl")
                shutil.copyfile(source, destination)
                recovered.append(destination.name)
                for line in destination.read_text(encoding="utf-8", errors="replace").splitlines():
                    try:
                        stream_events.append(json.loads(line))
                    except json.JSONDecodeError:
                        recovery_errors.append("Incomplete JSONL line in " + destination.name)
        except OSError as error:
            recovery_errors.append(type(error).__name__ + " while collecting a native partial report")
    unique = {e["event_id"]: e for e in stream_events}
    events = sorted(unique.values(), key=lambda e: e["uptime_seconds"])
    (OUT / "events.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))
    log = (OUT / "xcodebuild-performance.log").read_text(encoding="utf-8", errors="replace")
    summaries = [dict(executed=int(n), result=result) for n, result in re.findall(r"Test run with (\d+) tests?\b[^\r\n]*?\b(passed|failed)\b", log)]
    rows = []
    for size in SIZES:
        selected = [e for e in events if e.get("sample_bytes") == size]
        rows.append(dict(sample_bytes=size, sample_mib=size / 1048576,
                         status="completed" if any(e["event"] == "size_complete" for e in selected) else "partial" if selected else "not_started",
                         fixture=next((e for e in selected if e["event"] == "fixture_ready"), None),
                         phases={p: next((e for e in reversed(selected) if e["event"] == "phase_end" and e["phase"] == p), None) for p in ["decode", "chapters"]}))
    success = (native_exit == 0 and not timed_out and not stream_errors and not recovery_errors
               and summaries == [dict(executed=1, result="passed")]
               and all(row["status"] == "completed" for row in rows))
    report = dict(metadata=metadata, status="completed" if success else "failed", native_exit=native_exit,
                  harness_timeout=timed_out, declared_performance_tests=1, native_summaries=summaries,
                  named_performance_tests_started=len(re.findall(r"Test automaticDecodeAndChaptersBaseline\(\) started", log)),
                  rows=rows, stopped_events=[e for e in events if e["event"] == "run_stopped"],
                  recovered_reports=recovered, stream_errors=stream_errors, recovery_errors=recovery_errors,
                  memory_scope="RSS of the test-host process. Observed maxima include boundaries and 100 ms target sampling, can miss spikes. System high water spans entire process, fixtures, earlier sizes, caches and test framework; not a stage peak.")
    (OUT / "performance-report.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = ["# TXT synthetic large-file baseline", "", "Simulator only; one performance test, two sequential size attempts; ordinary regression tests not run.", "",
             "| Size | Status | Decode seconds | Chapters seconds | Pre-decode RSS MiB | Decode observed max RSS MiB | Decode lifetime high-water MiB | Chapters observed max RSS MiB |",
             "|---|---|---:|---:|---:|---:|---:|---:|"]
    for row in rows:
        values = [row["phases"][p].get("wall_seconds", "unknown") if row["phases"][p] else "not completed" for p in ["decode", "chapters"]]
        decode, chapters = row["phases"]["decode"], row["phases"]["chapters"]
        memory = [row["fixture"]["memory_after_generation_before_decode"]["rss_bytes"] if row["fixture"] else None,
                  decode["observed_rss_max_bytes"] if decode else None,
                  decode["after"]["process_lifetime_rss_high_water_bytes"] if decode else None,
                  chapters["observed_rss_max_bytes"] if chapters else None]
        memory = [f"{v / 1048576:.3f}" if v is not None else "unknown" for v in memory]
        lines.append(f"| {row['sample_mib']:g} MiB ({row['sample_bytes']} bytes) | {row['status']} | {values[0]} | {values[1]} | " + " | ".join(memory) + " |")
    lines += ["", report["memory_scope"], "", "Raw numeric memory, sample SHA-256, optimization levels, partial stages and stopping reasons: performance-report.json and events.jsonl."]
    (OUT / "performance-report.md").write_text("\n".join(lines) + "\n")
    print(json.dumps(dict(performance_status=report["status"], native_exit=native_exit, native_summaries=summaries,
                          size_statuses=[dict(sample_bytes=r["sample_bytes"], status=r["status"]) for r in rows])), flush=True)
    return 0 if success else native_exit if 0 < native_exit < 256 else 1


if __name__ == "__main__":
    sys.exit(main())

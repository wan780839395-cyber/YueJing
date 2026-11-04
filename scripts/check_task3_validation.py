"""Offline regression checks only: synthetic logs/evidence, never launches native tools."""
import ast
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from unittest.mock import patch

import task3_test_inventory as inventory
import run_reading_ui_tests as ui
import validate_task3 as gate

ROOT = Path(__file__).resolve().parents[1]


def put(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


def synthetic_fixture(root):
    """Intentionally fake evidence. Isolated from all real artifacts and native processes."""
    out = root / "task3"
    out.mkdir(exist_ok=True)
    (root / "project.yml").write_text("synthetic project, NOT a build\n", encoding="utf-8")
    schemes = root / "YueJing.xcodeproj/xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    for name in ("YueJingUI", "YueJingCanvas"):
        (schemes / (name + ".xcscheme")).write_text("synthetic scheme", encoding="utf-8")
    put(out / "candidate-sources.json", dict(source_commit="synthetic-sha", run_id="synthetic-run", run_attempt="1",
        files=gate.candidate_files(), inventory=inventory.validate_source()))
    for group in inventory.SWIFT_GROUPS:
        log = "\n".join(
            f"Test {n}() started.\nTest {n}() passed after 0.1 seconds."
            for n in inventory.expected_names(group)
        )
        log += f"\nTest run with {inventory.COUNTS[group]} tests passed after 1 seconds.\n** TEST SUCCEEDED **"
        path = out / (group + ".log")
        path.write_text(log, encoding="utf-8")
        (out / (group + "-exit-code.txt")).write_text("0", encoding="utf-8")
        put(out / (group + "-counts.json"), dict(source_commit="synthetic-sha", run_id="synthetic-run", run_attempt="1",
            expected=inventory.COUNTS[group], inventory_sha256=gate.digest(Path(inventory.__file__)),
            selection=inventory.selection(group), log_sha256=gate.digest(path), **inventory.parse_swift_log(group, log, 0)))
    put(out / "canvas-settings.json", dict(source_commit="synthetic-sha", scheme_sha256=gate.digest(schemes / "YueJingCanvas.xcscheme")))
    base = dict(SWIFT_VERSION="6.0", SWIFT_STRICT_CONCURRENCY="complete", IPHONEOS_DEPLOYMENT_TARGET="16.6")
    source_paths = sorted((root / "App").rglob("*.swift")) + [root / "project.yml"]
    source_paths += [p for group in ui.GROUPS for p in sorted((root / "Tests" / group).glob("*.swift"))]
    source_files = {p.relative_to(root).as_posix(): gate.digest(p) for p in source_paths}
    for target, count in ui.GROUPS.items():
        native = root / "artifacts" / ("epub-ui-native" if target == "YueJingEPUBUITests" else "reading-ui-native")
        names = inventory.expected_names(target)
        if target == "YueJingHostTests":
            log = "\n".join(f"Test {n}() started.\nTest {n}() passed after 0.1 seconds." for n in names)
            log += f"\nTest run with {count} tests passed after 1 seconds."
            settings = dict(base, PRODUCT_TYPE="com.apple.product-type.bundle.unit-test", TEST_HOST="/synthetic/YueJing.app/YueJing", BUNDLE_LOADER="/synthetic/YueJing.app/YueJing")
        else:
            ui_class = ui.UI_CLASSES[target]
            log = "\n".join(
                f"Test Case '-[{target}.{ui_class} {n}]' started.\n"
                f"Test Case '-[{target}.{ui_class} {n}]' passed (0.1 seconds)."
                for n in names
            )
            settings = dict(base, PRODUCT_TYPE="com.apple.product-type.bundle.ui-testing", TEST_TARGET_NAME="YueJing")
        log += "\n** TEST SUCCEEDED **"
        provenance = dict(source_commit="synthetic-sha", run_id="synthetic-run", run_attempt="1", target=target,
            expected=count, scheme="YueJingUI", configuration="Debug", declared=names, command=["-only-testing:" + target])
        put(native / (target + "-selection.json"), provenance)
        put(native / (target + "-execution.json"), dict(provenance, native_exit=0, timed_out=False))
        (native / (target + "-exit-code.txt")).write_text("0", encoding="utf-8")
        log_path = native / (target + ".log")
        log_path.write_text(log, encoding="utf-8")
        put(native / (target + "-counts.json"), dict(provenance, **{k: v for k, v in ui.count_log(target, log, 0).items() if k != "target"}, log_sha256=gate.digest(log_path)))
        put(native / (target + "-source-hashes.json"), dict(source_commit="synthetic-sha", files=source_files))
        put(native / (target + "-settings.json"), dict(source_commit="synthetic-sha", fixture_environment="D052AE4B-7823-447E-BE63-986028A7F54C", testables=sorted(ui.GROUPS),
            scheme_sha256=gate.digest(schemes / "YueJingUI.xcscheme"), targets={"YueJing": dict(base, PRODUCT_TYPE="com.apple.product-type.application", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG"), target: settings}))

def check_system_swift_runtime():
    """Synthetic SDK headers only; no downloaded SDK or native execution."""
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        sdk, out = root / "SDK", root / "evidence"
        folder = sdk / "usr/lib/swift"
        folder.mkdir(parents=True)
        def header(name, target="arm64-ios"):
            return ("--- !tapi-tbd\ntbd-version: 4\ntargets: [ " + target + " ]\n"
                    "install-name: '/usr/lib/swift/" + name + "'\n...\n")
        for name in sorted(gate.SYSTEM_SWIFT_RPATH_LIBRARIES):
            stub = folder / (name.removesuffix(".dylib") + ".tbd")
            stub.write_text(header(name), encoding="utf-8")
            result = gate.system_swift_runtime("@rpath/" + name, ["/usr/lib/swift"], sdk, out)
            assert result["resolved_system_path"] == "/usr/lib/swift/" + name
            assert result["stub_sha256"] == gate.digest(out / result["stub_evidence"]) == gate.digest(stub)
            assert gate.system_swift_runtime("@rpath/" + name, ["/usr/lib/swift"], sdk, out) == result
        for link in ("@rpath/libswiftWebKit.dylib", "@rpath/libswiftUnknown.dylib",
                     "@rpath/Private.framework/Private", "@rpath/../libswiftCore.dylib",
                     "@loader_path/libswiftCore.dylib", "/usr/lib/swift/libswiftCore.dylib"):
            assert gate.system_swift_runtime(link, ["/usr/lib/swift"], sdk, out) is None
        for paths in ([], ["@executable_path/Frameworks"], ["/tmp/usr/lib/swift"], ["/usr/lib/swift-extra"]):
            assert gate.system_swift_runtime("@rpath/libswiftCore.dylib", paths, sdk, out) is None
        stub = folder / "libswiftCore.tbd"
        good = header("libswiftCore.dylib")
        for bad in (header("libswiftCore.dylib", "arm64-ios-simulator"),
                    header("libswiftCore.dylib", "arm64-macos"), header("libswiftWrong.dylib"),
                    good.replace("tbd-version: 4", "tbd-version: 3"),
                    header("libswiftWrong.dylib", "arm64-macos") + good, ""):
            stub.write_text(bad, encoding="utf-8")
            try:
                gate.system_swift_runtime("@rpath/libswiftCore.dylib", ["/usr/lib/swift"], sdk, out)
            except ValueError:
                pass
            else:
                raise AssertionError("Invalid system runtime stub accepted")
        stub.unlink()
        try:
            gate.system_swift_runtime("@rpath/libswiftCore.dylib", ["/usr/lib/swift"], sdk, out)
        except ValueError:
            pass
        else:
            raise AssertionError("Absent system runtime stub accepted")


def main():
    checked = []
    check_system_swift_runtime()
    checked.append("system-swift-rpath-positive-negative-and-sdk-evidence")
    inventory.validate_source()
    checked.append("reviewed-source-identity-and-disjoint-union")
    for name in ("task3_test_inventory.py", "run_reading_ui_tests.py", "validate_task3.py", "check_task3_validation.py"):
        ast.parse((ROOT / "scripts" / name).read_text(encoding="utf-8"))
    checked.append("python-ast-four-files")
    workflow = (ROOT / ".github/workflows/task3-validate.yml").read_text(encoding="utf-8")
    blocks = re.split(r"^      - name: ", workflow, flags=re.MULTILINE)[1:]
    selected = []
    for block in blocks:
        match = re.search(r"--selection (\w+)\)", block)
        if not match:
            continue
        group = match[1]
        assert '"${selection[@]}"' in block
        assert "test-counts " + group in block
        assert ("-configuration Release" in block) == (group in ("TXTBlockDecoderTests", "ProcessingReuseMeasurementTests"))
        assert ("-scheme YueJingCanvas" in block) == (group == "YueJingCanvasTests")
        selected.append(group)
    assert sorted(selected) == sorted(inventory.SWIFT_GROUPS)
    assert "--target YueJingHostTests" in workflow and "--target YueJingUITests" in workflow and "--target YueJingEPUBUITests" in workflow
    assert workflow.index("freeze-candidate") < workflow.index("--selection TXTCoreTests")
    assert workflow.index("test-counts YueJingCanvasTests") < workflow.index("all-test-gate") < workflow.index("generic/platform=iOS")
    assert "workflow_dispatch:" in workflow and "runs-on: macos-15" in workflow
    # Approved aggregate UI headroom; Host and individual case deadlines stay unchanged.
    assert re.findall(r"^\s+timeout-minutes: (\d+)\s*$", workflow, re.MULTILINE) == ["60", "12", "23", "10"]
    runner = (ROOT / "scripts/run_reading_ui_tests.py").read_text(encoding="utf-8")
    assert 'timeout_seconds = 480 if target == "YueJingHostTests" else 1200' in runner
    assert '"-default-test-execution-time-allowance", "180", "-maximum-test-execution-time-allowance", "180"' in runner
    assert "-skip-testing:" not in workflow  # filters are emitted only by the reviewed selector
    checked.append("workflow-order-approved-job60-ui1200-case180-host480")
    bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    if bash.is_file():
        bodies = re.findall(r"^        run: \|\n((?:          .*\n|\n)+)", workflow, re.MULTILINE)
        for body in bodies:
            # -n parses only. No commands from the workflow are executed.
            text = "\n".join(line[10:] if line.startswith("          ") else line for line in body.splitlines())
            subprocess.run([str(bash), "-n"], input=text, text=True, check=True, capture_output=True)
        checked.append("bash-parse-only-" + str(len(bodies)) + "-run-blocks")
    else:
        checked.append("bash-syntax-not-checked-tool-unavailable")
    env = dict(GITHUB_SHA="synthetic-sha", GITHUB_RUN_ID="synthetic-run", GITHUB_RUN_ATTEMPT="1", GITHUB_EVENT_NAME="workflow_dispatch")
    with tempfile.TemporaryDirectory(prefix="yuejing-gate-synthetic-", dir=os.environ.get("PI_SCRATCH_DIR")) as folder:
        root = Path(folder)
        with patch.object(gate, "ROOT", root), patch.object(gate, "OUT", root / "task3"), patch.dict(os.environ, env):
            synthetic_fixture(root)
            result = gate.all_test_evidence()
            assert result["passed"] is True and not result["errors"]
            assert result["native_passed"] == inventory.TOTAL == 205 and len(result["groups"]) == 8
            checked.append("synthetic-eight-group-aggregate-accept")
            target = root / "task3/ReaderDomainTests-counts.json"
            for field, value in (("source_commit", "old-sha"), ("run_id", "old-run"), ("expected", 89), ("selection", [])):
                original = json.loads(target.read_text(encoding="utf-8"))
                altered = copy.deepcopy(original); altered[field] = value
                put(target, altered)
                try:
                    gate.all_test_evidence()
                except ValueError:
                    checked.append("aggregate-reject-" + field)
                else:
                    raise AssertionError("Aggregate accepted " + field)
                put(target, original)
            path = root / "task3/YueJingCanvasTests.log"
            original = path.read_text(encoding="utf-8")
            for label, value in (("missing-canvas-case", "\n".join(original.splitlines()[2:])),
                                 ("duplicate-canvas-case", original + "\n" + "\n".join(original.splitlines()[:2])),
                                 ("canvas-skip", original + "\nTest example skipped")):
                path.write_text(value, encoding="utf-8")
                try:
                    gate.all_test_evidence()
                except ValueError:
                    checked.append("aggregate-reject-" + label)
                else:
                    raise AssertionError("Aggregate accepted " + label)
                path.write_text(original, encoding="utf-8")
            project = root / "project.yml"
            original = project.read_text(encoding="utf-8"); project.write_text("drift", encoding="utf-8")
            try:
                gate.all_test_evidence()
            except ValueError:
                checked.append("aggregate-reject-source-drift")
            else:
                raise AssertionError("Aggregate accepted source drift")
            project.write_text(original, encoding="utf-8")
            assert gate.all_test_evidence()["native_passed"] == inventory.TOTAL
    print(json.dumps(dict(kind="OFFLINE_SYNTHETIC_NOT_NATIVE", passed=len(checked), cases=checked,
                          swift_parser=inventory.self_check(), app_parser=ui.self_check(), native_executions=0), indent=2))


if __name__ == "__main__":
    main()

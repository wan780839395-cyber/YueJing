"""Evidence gates for the one-shot Task 3 native workflow; never repairs build output."""

import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "artifacts/task3"
APP = ROOT / "build/DerivedData/Build/Products/Release-iphoneos/YueJing.app"
RESOLVED = ROOT / "YueJing.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=90).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def report(name, value):
    OUT.mkdir(parents=True, exist_ok=True)
    with (OUT / name).open("x", encoding="utf-8") as output:
        json.dump(value, output, indent=2)
        output.write("\n")
    print(json.dumps(value, indent=2))


def select_simulator():
    require(platform.machine() == "arm64", "This batch requires the standard arm64 runner")
    devices = json.loads((OUT / "devices.json").read_text())["devices"]
    runtimes = json.loads((OUT / "runtimes.json").read_text())["runtimes"]
    sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"])

    def version(value):
        return tuple((list(map(int, value.split("."))) + [0, 0, 0])[:3])

    choices = []
    for runtime in runtimes:
        if not runtime.get("isAvailable") or not runtime["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
            continue
        if not version("16.6") <= version(runtime["version"]) <= version(sdk):
            continue
        if runtime.get("supportedArchitectures") and "arm64" not in runtime["supportedArchitectures"]:
            continue
        for device in devices.get(runtime["identifier"], []):
            if device.get("isAvailable") and device["name"].startswith("iPhone"):
                choices.append((version(runtime["version"]), device["name"], runtime, device))
    require(choices, "No installed supported iPhone simulator; do not install a runtime")
    _, _, runtime, device = max(choices, key=lambda item: (item[0], item[1]))
    report("simulator-selection.json", dict(device_name=device["name"], udid=device["udid"],
           runtime=runtime["name"], runtime_version=runtime["version"], sdk=sdk,
           architecture="arm64", physical_device=False))
    with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as output:
        output.write("SIMULATOR_UDID=" + device["udid"] + "\n")


def resolved():
    pins = json.loads(RESOLVED.read_text())["pins"]
    require(len(pins) == 1, "Expected only the approved GRDB dependency")
    pin = pins[0]
    require(pin["identity"].lower() == "grdb.swift" and pin["kind"] == "remoteSourceControl", "Unexpected package identity")
    require(pin["location"] == "https://github.com/groue/GRDB.swift.git", "Unexpected dependency source")
    state = pin["state"]
    require(state["version"] == "7.0.0" and re.fullmatch(r"[0-9a-f]{40}", state["revision"]), "GRDB pin differs from 7.0.0")
    checkout = grdb_checkout()
    require(run(["git", "-C", str(checkout), "rev-parse", "HEAD"]) == state["revision"], "Dependency checkout differs from resolved revision")
    shutil.copyfile(RESOLVED, OUT / "Package.resolved")
    report("dependency-resolution.json", dict(package=pin, checkout_revision=state["revision"],
           package_manifest_sha256=digest(checkout / "Package.swift")))


def grdb_checkout():
    choices = [path for path in (ROOT / "build/SourcePackages/checkouts").iterdir()
               if path.name.lower() == "grdb.swift"]
    require(len(choices) == 1, "Expected exactly one resolved GRDB checkout")
    return choices[0]


def settings():
    selected = {}
    keys = ["PRODUCT_TYPE", "SWIFT_VERSION", "SWIFT_STRICT_CONCURRENCY", "IPHONEOS_DEPLOYMENT_TARGET",
            "TEST_HOST", "BUNDLE_LOADER", "TEST_TARGET_NAME"]
    for target in ("TXTCoreTests", "ReaderDomainTests"):
        result = subprocess.run(["xcodebuild", "-project", "YueJing.xcodeproj", "-target", target,
            "-configuration", "Debug", "-sdk", "iphonesimulator", "-showBuildSettings", "-json",
            "-clonedSourcePackagesDirPath", "build/SourcePackages", "-disableAutomaticPackageResolution",
            "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64"], capture_output=True, text=True, timeout=120)
        (OUT / (target + "-settings.log")).write_text(result.stderr, encoding="utf-8")
        require(result.returncode == 0, target + " effective settings failed: " + result.stderr)
        rows = [row["buildSettings"] for row in json.loads(result.stdout) if row.get("target") == target]
        require(len(rows) == 1, "Missing or ambiguous target settings: " + target)
        values = {key: rows[0].get(key, "") for key in keys}
        selected[target] = values
        require(values["PRODUCT_TYPE"] == "com.apple.product-type.bundle.unit-test", "Expected ordinary unit-test target")
        require(not any(values[key] for key in ("TEST_HOST", "BUNDLE_LOADER", "TEST_TARGET_NAME")), "Unexpected application test host")
        require(values["SWIFT_VERSION"] == "6.0" and values["IPHONEOS_DEPLOYMENT_TARGET"] == "16.6"
                and values["SWIFT_STRICT_CONCURRENCY"] == "complete", "Unexpected language/isolation/deployment settings")
    report("effective-test-settings.json", selected)


def measurement_settings(targets=("TXTCore", "ReaderDomain", "ReaderDomainTests"), name="measurement-settings"):
    selected = {}
    for target in targets:
        result = subprocess.run(["xcodebuild", "-project", "YueJing.xcodeproj", "-target", target,
            "-configuration", "Release", "-sdk", "iphonesimulator", "-showBuildSettings", "-json",
            "-clonedSourcePackagesDirPath", "build/SourcePackages", "-disableAutomaticPackageResolution",
            "CODE_SIGNING_ALLOWED=NO", "ENABLE_TESTABILITY=YES", "ARCHS=arm64"], capture_output=True, text=True, timeout=120)
        (OUT / (target + "-" + name + ".log")).write_text(result.stderr, encoding="utf-8")
        require(result.returncode == 0, "Measurement build settings failed")
        rows = [row["buildSettings"] for row in json.loads(result.stdout) if row.get("target") == target]
        require(len(rows) == 1, "Ambiguous measurement settings")
        values = {key: rows[0].get(key, "") for key in
                  ("CONFIGURATION", "SWIFT_OPTIMIZATION_LEVEL", "ENABLE_TESTABILITY", "ARCHS", "IPHONEOS_DEPLOYMENT_TARGET", "SWIFT_VERSION")}
        require(values["CONFIGURATION"] == "Release" and values["SWIFT_OPTIMIZATION_LEVEL"] == "-O"
                and values["SWIFT_VERSION"] == "6.0" and values["IPHONEOS_DEPLOYMENT_TARGET"] == "16.6",
                "Unexpected measurement configuration")
        require(values["ENABLE_TESTABILITY"] == "YES", "Measurement testability is not enabled")
        selected[target] = values
    report(name + ".json", selected)


def decoder_comparison():
    log = (OUT / "TXTBlockDecoderTests.log").read_text(encoding="utf-8", errors="replace")
    fields = ("bytes", "oldScalarConversions", "newBatchConversions", "newScalarConversions",
              "oldReferenceSeconds", "newWrapperSeconds", "processorSeconds")
    pattern = r"TXT_BLOCK_COMPARISON " + " ".join(key + r"=([0-9.eE+\-]+)" for key in fields)
    matches = re.findall(pattern, log)
    require(len(matches) == 1, "Expected exactly one synthetic timed comparison pair")
    values = dict(zip(fields, matches[0]))
    for key in fields[:4]:
        values[key] = int(values[key])
    for key in fields[4:]:
        values[key] = float(values[key])
        require(math.isfinite(values[key]) and values[key] >= 0, "Invalid decoder timing")
    require(values["bytes"] == 16385 and values["oldScalarConversions"] == 8192
            and 0 < values["newBatchConversions"] < 8192 // 100 and values["newScalarConversions"] == 0,
            "Unexpected decoder sample or actual batch conversion counters")
    require(values["processorSeconds"] <= values["newWrapperSeconds"] + 0.000001, "Nested timing exceeds wrapper")
    report("decoder-comparison.json", dict(source_commit=os.environ["GITHUB_SHA"],
           simulator=json.loads((OUT / "simulator-selection.json").read_text()),
           configuration="Release/-O, ENABLE_TESTABILITY=YES", timed_pairs=1, encoding="GBK/CP936",
           sample="8192 repeated synthetic U+4E2D as D6 D0 plus one LF; 16385 bytes",
           ordering="timed frozen reference, timed new actor call, then one additional unmeasured old/new equality check",
           old_count_scope="8192 is fixture/source-derived, not an instrumented old counter",
           new_count_scope="actual TXTDecodeMetrics batch/scalar counters from the timed new decode",
           timing_scope="old reference runs synchronously in test module; new wrapper includes actor scheduling; processor is nested",
           warmup_scope="same process, serialized six-test suite; other tests may already have initialized converters; not cold start",
           memory_scope="this 16KiB pair does not measure RSS; the separate existing 10MiB path records boundary RSS",
           physical_device=False, values=values))


def processing_measurements():
    log = (OUT / "ProcessingReuseMeasurementTests.log").read_text(encoding="utf-8", errors="replace")
    rows = [json.loads(line.split("PROCESSING_REUSE_METRIC ", 1)[1])
            for line in log.splitlines() if "PROCESSING_REUSE_METRIC " in line]
    require([row["scenario"] for row in rows] ==
            ["import", "first_open", "same_service_reopen", "new_service_cold_cache"], "Missing/duplicate measurement scenarios")
    require(all(row["sample_bytes"] == 10485760 and row["seconds"] >= 0 for row in rows), "Unexpected sample or timing")
    warm = rows[2]
    require(warm["decode_calls"] == 1 and warm["chapter_calls"] == 1 and warm["document_hits"] == 2
            and warm["chapter_hits"] == 1, "Warm reuse was not demonstrated")
    require(not any(p["phase"] in ("decode", "chapters") for p in warm["phases"]), "Warm path recomputed content")
    report("processing-measurements.json", dict(source_commit=os.environ["GITHUB_SHA"],
           simulator=json.loads((OUT / "simulator-selection.json").read_text()),
           configuration="Release/-O, ENABLE_TESTABILITY=YES", repetitions=1, sample="10MiB chinese-chapters-v1, no BOM; fixture generation/write excluded",
           first_paint="not measured", system_picker_copy="not measured", app_cold_start="not measured; new service in same process only",
           memory="test-host process RSS at boundaries, includes fixture/allocator; not a sampled peak or cache delta", rows=rows))


def test_counts(target, expected):
    folder = "TXTCoreTests" if target == "TXTBlockDecoderTests" else target
    paths = sorted((ROOT / "Tests" / folder).glob("*.swift"))
    if folder == "TXTCoreTests":
        paths = [path for path in paths if (path.name == "TXTBlockDecoderTests.swift") == (target == "TXTBlockDecoderTests")]
    declared = [name for path in paths
                for name in re.findall(r"@Test\s+func\s+(\w+)\s*\(\s*\)", path.read_text(encoding="utf-8"))]
    log = (OUT / (target + ".log")).read_text(encoding="utf-8", errors="replace")
    summaries = re.findall(r"Test run with (\d+) tests?\b[^\r\n]*?\b(passed|failed)\b", log)
    passed = re.findall(r"\bTest (\w+)\(\) passed after\b", log)
    skipped = re.findall(r"^.*\b(?:Test|Suite) [^\r\n]*\bskipped\b[^\r\n]*$", log, re.MULTILINE)
    native_exit = int((OUT / (target + "-exit-code.txt")).read_text())
    report(target + "-counts.json", dict(source_commit=os.environ["GITHUB_SHA"], expected=expected,
           source_files=[str(path.relative_to(ROOT)) for path in paths], declared=declared, passed=passed,
           native_summaries=summaries, skipped=skipped, native_exit=native_exit))
    require(native_exit == 0 and len(declared) == expected and len(set(declared)) == expected,
            "Native exit or declared test inventory mismatch: " + target)
    require(summaries == [(str(expected), "passed")] and sorted(passed) == sorted(declared) and not skipped,
            "Actual Swift Testing execution/count/pass evidence mismatch: " + target)


def unsigned(path):
    result = subprocess.run(["/usr/bin/codesign", "--display", str(path)], capture_output=True, text=True,
                            timeout=15, env={**os.environ, "LC_ALL": "C"})
    require(result.returncode == 1 and "not signed at all" in result.stderr, "Product is not confirmed unsigned: " + path.name)


def all_test_evidence():
    """Read/reparse all six real suites. This gate never creates or repairs native evidence."""
    import run_reading_ui_tests as ui
    require(os.environ.get("GITHUB_RUN_ATTEMPT") == "1" and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch",
            "Only the single authorized dispatch attempt is accepted")
    groups, selected = [], []
    for target, expected in (("TXTCoreTests", 25), ("ReaderDomainTests", 89),
                             ("TXTBlockDecoderTests", 6), ("ProcessingReuseMeasurementTests", 1)):
        counts = json.loads((OUT / (target + "-counts.json")).read_text())
        folder = "TXTCoreTests" if target == "TXTBlockDecoderTests" else target
        paths = sorted((ROOT / "Tests" / folder).glob("*.swift"))
        if folder == "TXTCoreTests":
            paths = [p for p in paths if (p.name == "TXTBlockDecoderTests.swift") == (target == "TXTBlockDecoderTests")]
        declared = [name for p in paths for name in re.findall(r"@Test\s+func\s+(\w+)\s*\(\s*\)", p.read_text(encoding="utf-8"))]
        log_path = OUT / (target + ".log")
        log = log_path.read_text(encoding="utf-8", errors="replace")
        passed = re.findall(r"\bTest (\w+)\(\) passed after\b", log)
        summaries = re.findall(r"Test run with (\d+) tests?\b[^\r\n]*?\b(passed|failed)\b", log)
        skipped = re.findall(r"^.*\b(?:Test|Suite) [^\r\n]*\bskipped\b[^\r\n]*$", log, re.MULTILINE)
        require(counts["source_commit"] == os.environ["GITHUB_SHA"] and counts["expected"] == expected
                and counts["native_exit"] == int((OUT / (target + "-exit-code.txt")).read_text()) == 0,
                "Original native provenance/exit mismatch: " + target)
        require(len(declared) == len(set(declared)) == expected and sorted(declared) == sorted(counts["declared"]) == sorted(counts["passed"]) == sorted(passed)
                and summaries == [(str(expected), "passed")] and counts["native_summaries"] == [[str(expected), "passed"]]
                and not skipped and not counts["skipped"], "Original native execution mismatch: " + target)
        groups.append(dict(target=target, expected=expected, passed=passed, failed=0, skipped=0, unexecuted=0, log_sha256=digest(log_path)))
        selected.extend(passed)
    native = ROOT / "artifacts/reading-ui-native"
    for target, expected in ui.GROUPS.items():
        counts = json.loads((native / (target + "-counts.json")).read_text())
        selection = json.loads((native / (target + "-selection.json")).read_text())
        execution = json.loads((native / (target + "-execution.json")).read_text())
        settings = json.loads((native / (target + "-settings.json")).read_text())
        sources = json.loads((native / (target + "-source-hashes.json")).read_text())
        for record in (counts, selection, execution):
            require(record["source_commit"] == os.environ["GITHUB_SHA"] and record["run_id"] == os.environ["GITHUB_RUN_ID"]
                    and record["run_attempt"] == "1" and record["target"] == target and record["expected"] == expected
                    and record["scheme"] == "YueJingUI" and record["configuration"] == "Debug"
                    and record["declared"] == ui.declarations(target), "App suite selection/provenance mismatch: " + target)
        require(counts["command"] == selection["command"] == execution["command"]
                and selection["command"].count("-only-testing:" + target) == 1
                and not any(arg.startswith("-skip-testing") for arg in selection["command"]), "App suite filtering mismatch")
        require(execution["native_exit"] == int((native / (target + "-exit-code.txt")).read_text()) == 0
                and not execution["timed_out"], "App suite command failed or timed out")
        require(settings["source_commit"] == sources["source_commit"] == os.environ["GITHUB_SHA"]
                and settings["fixture_environment"] and set(settings["testables"]) == set(ui.GROUPS), "Missing isolated real App settings")
        ui.uuid.UUID(settings["fixture_environment"])
        require(settings["scheme_sha256"] == digest(ROOT / "YueJing.xcodeproj/xcshareddata/xcschemes/YueJingUI.xcscheme"), "Generated App test scheme changed")
        app, test = settings["targets"]["YueJing"], settings["targets"][target]
        require(all(values["SWIFT_VERSION"] == "6.0" and values["SWIFT_STRICT_CONCURRENCY"] == "complete"
                    and values["IPHONEOS_DEPLOYMENT_TARGET"] == "16.6" for values in (app, test)), "App suite settings changed")
        require(app["PRODUCT_TYPE"] == "com.apple.product-type.application" and "DEBUG" in app["SWIFT_ACTIVE_COMPILATION_CONDITIONS"].split(), "Real App Debug fixture not enabled")
        if target == "YueJingHostTests":
            require(test["PRODUCT_TYPE"] == "com.apple.product-type.bundle.unit-test" and Path(test["TEST_HOST"]).name == "YueJing"
                    and Path(test["TEST_HOST"]).parent.name == "YueJing.app" and test["BUNDLE_LOADER"] == test["TEST_HOST"], "Invalid actual App host")
        else:
            require(test["PRODUCT_TYPE"] == "com.apple.product-type.bundle.ui-testing" and test["TEST_TARGET_NAME"] == "YueJing", "Invalid real UI test target")
        source_paths = sorted((ROOT / "App").rglob("*.swift")) + [ROOT / "project.yml"]
        source_paths += [p for group in ui.GROUPS for p in sorted((ROOT / "Tests" / group).glob("*.swift"))]
        require(set(sources["files"]) == {p.relative_to(ROOT).as_posix() for p in source_paths}
                and all(digest(ROOT / name) == value for name, value in sources["files"].items()), "App/test source changed")
        log_path = native / (target + ".log")
        log = log_path.read_text(encoding="utf-8", errors="replace")
        actual = ui.count_log(target, log, execution["native_exit"])
        all_xctest = re.findall(r"Test Case '-\[[^\r\n]+\]' passed \(", log)
        require(len(all_xctest) == (expected if target == "YueJingUITests" else 0), "Unexpected XCTest execution outside selection")
        require(target != "YueJingUITests" or not re.findall(r"\bTest (\w+)\(\) passed after\b", log), "Unexpected Swift Testing execution in UI selection")
        require(counts["native_exit"] == 0 and counts["passed"] == actual["passed"] and counts["log_sha256"] == digest(log_path)
                and counts["failed"] == counts["skipped"] == counts["unexecuted"] == 0, "App suite native count mismatch")
        groups.append(dict(target=target, expected=expected, passed=actual["passed"], failed=0, skipped=0, unexecuted=0,
                           log_sha256=digest(log_path), selection=selection["command"]))
        selected.extend(actual["passed"])
    require(len(selected) == len(set(selected)) == 129, "All 129 unique native tests must actually pass")
    return dict(source_commit=os.environ["GITHUB_SHA"], run_id=os.environ["GITHUB_RUN_ID"], run_attempt="1",
                native_passed=129, failed=0, skipped=0, unexecuted=0, groups=groups)


def package_gate():
    require(sys.platform == "darwin", "Packaging gates require the real macOS output")
    for target, expected in (("TXTCoreTests", 25), ("ReaderDomainTests", 89),
                             ("TXTBlockDecoderTests", 6), ("ProcessingReuseMeasurementTests", 1)):
        counts = json.loads((OUT / (target + "-counts.json")).read_text())
        require(counts["native_exit"] == 0 and counts["expected"] == expected and len(counts["passed"]) == expected,
                "All 121 real tests must pass before packaging")
        require(counts["source_commit"] == os.environ["GITHUB_SHA"], "Test evidence commit mismatch")
    core = json.loads((OUT / "TXTCoreTests-counts.json").read_text())["declared"]
    block = json.loads((OUT / "TXTBlockDecoderTests-counts.json").read_text())["declared"]
    all_core = [name for path in (ROOT / "Tests/TXTCoreTests").glob("*.swift")
                for name in re.findall(r"@Test\s+func\s+(\w+)\s*\(\s*\)", path.read_text(encoding="utf-8"))]
    require(not set(core) & set(block) and sorted(core + block) == sorted(all_core) and len(all_core) == 31,
            "Debug/Release selection did not cover each of the 31 core tests exactly once")
    domain = json.loads((OUT / "ReaderDomainTests-counts.json").read_text())["declared"]
    measurement = json.loads((OUT / "ProcessingReuseMeasurementTests-counts.json").read_text())["declared"]
    all_domain = [name for folder in ("ReaderDomainTests", "ProcessingReuseMeasurementTests")
                  for path in (ROOT / "Tests" / folder).glob("*.swift")
                  for name in re.findall(r"@Test\s+func\s+(\w+)\s*\(\s*\)", path.read_text(encoding="utf-8"))]
    require(not set(domain) & set(measurement) and sorted(domain + measurement) == sorted(all_domain)
            and len(all_domain) == 90, "Debug/Release selection did not cover each of the 90 domain tests exactly once")
    selected = core + domain + block + measurement
    require(len(selected) == len(set(selected)) == 121, "Native test selection must contain exactly 121 unique tests")
    require(json.loads((OUT / "native-test-gate.json").read_text()) == all_test_evidence(),
            "Same-run 129-test acceptance is required before packaging")
    require(json.loads((OUT / "decoder-comparison.json").read_text())["source_commit"] == os.environ["GITHUB_SHA"],
            "Missing same-commit native decoder comparison")
    require(json.loads((OUT / "processing-measurements.json").read_text())["source_commit"] == os.environ["GITHUB_SHA"],
            "Missing same-commit processing evidence")
    require((OUT / "app-build-exit-code.txt").read_text().strip() == "0", "Device App build did not pass")
    unsigned(APP)
    require(not list(APP.rglob("embedded.mobileprovision")) and not list(APP.rglob("_CodeSignature")), "Unexpected signing material")
    binaries = [APP / "YueJing"]
    for name, identity in (("TXTCore", "dev.yuejing.txtcore"), ("ReaderDomain", "dev.yuejing.reader-domain")):
        framework = APP / "Frameworks" / (name + ".framework")
        require(framework.is_dir() and not framework.is_symlink(), "Required dynamic framework is not embedded: " + name)
        with (framework / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        require(info.get("CFBundleIdentifier") == identity and info.get("MinimumOSVersion") == "16.6"
                and info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "Framework metadata mismatch: " + name)
    for framework in (APP / "Frameworks").glob("*.framework"):
        with (framework / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        binaries.append(framework / info["CFBundleExecutable"])
    binaries += list((APP / "Frameworks").glob("*.dylib"))
    images, rpaths = {}, {}
    for binary in binaries:
        require(binary.is_file() and not binary.is_symlink(), "Missing real embedded binary")
        require(run(["xcrun", "lipo", "-archs", str(binary)]).split() == ["arm64"], "Embedded binary is not arm64")
        build = run(["xcrun", "vtool", "-show-build", str(binary)])
        require(re.search(r"^\s*platform IOS\s*$", build, re.MULTILINE), "Embedded binary is not an iOS device image")
        minimum = re.search(r"^\s*minos (\d+)\.(\d+)(?:\.\d+)?\s*$", build, re.MULTILINE)
        require(minimum and tuple(map(int, minimum.groups())) <= (16, 6), "Embedded binary requires a newer iOS")
        unsigned(binary)
        load = run(["xcrun", "otool", "-l", str(binary)])
        rpaths[binary] = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset \d+\)", load)
        links = run(["xcrun", "otool", "-L", str(binary)]).splitlines()[1:]
        images[binary] = [line.strip().split(" (", 1)[0] for line in links if line.strip()]
    graph, evidence = {}, []
    for binary, links in images.items():
        edges = []
        for link in links:
            if link.startswith(("/System/Library/", "/usr/lib/")):
                continue
            paths = []
            if link.startswith("@rpath/"):
                for base in rpaths[binary] + rpaths[binaries[0]]:
                    base = base.replace("@executable_path", str(APP)).replace("@loader_path", str(binary.parent))
                    paths.append(Path(base) / link[len("@rpath/"):])
            elif link.startswith(("@executable_path/", "@loader_path/")):
                paths.append(Path(link.replace("@executable_path", str(APP)).replace("@loader_path", str(binary.parent))))
            matches = [path.resolve() for path in paths if path.is_file() and path.resolve().is_relative_to(APP.resolve())]
            require(matches and matches[0] in images, "Unresolved bundled dynamic dependency: " + link)
            edges.append(matches[0])
        graph[binary] = edges
        evidence.append(dict(binary=str(binary.relative_to(APP)), sha256=digest(binary),
                             rpaths=rpaths[binary], dependencies=links))
    reached, pending = set(), [binaries[0]]
    while pending:
        binary = pending.pop()
        if binary not in reached:
            reached.add(binary)
            pending.extend(graph[binary])
    require(all(APP / "Frameworks" / (name + ".framework") / name in reached for name in ("TXTCore", "ReaderDomain")),
            "App dependency graph does not load both required custom frameworks")
    checkout = grdb_checkout()
    privacy = checkout / "GRDB/PrivacyInfo.xcprivacy"
    resources = [path for path in APP.rglob("PrivacyInfo.xcprivacy") if digest(path) == digest(privacy)]
    require(resources, "Resolved GRDB privacy resource is missing or changed in the built App")
    license_path = APP / "GRDB-LICENSE.txt"
    require(license_path.is_file() and digest(license_path) == digest(ROOT / "App/Resources/GRDB-LICENSE.txt")
            and digest(license_path) == digest(checkout / "LICENSE"), "GRDB license resource is missing or changed")
    report("app-dependency-gate.json", dict(source_commit=os.environ["GITHUB_SHA"], actual_images=evidence,
           grdb_linkage="dynamic" if any(path.name == "GRDB" for path in binaries) else "SPM automatic/static",
           grdb_privacy_resources=[str(path.relative_to(APP)) for path in resources],
           grdb_privacy_sha256=digest(privacy), grdb_license_sha256=digest(license_path), signing="unsigned"))


def verify_ipa():
    ipa = ROOT / "artifacts/YueJing-unsigned.ipa"
    manifest = json.loads((ROOT / "artifacts/manifest.json").read_text())
    require(manifest["source_commit"] == os.environ["GITHUB_SHA"] and manifest["ipa_sha256"] == digest(ipa), "IPA provenance mismatch")
    expected = {"Payload/YueJing.app/" + str(path.relative_to(APP)): path for path in APP.rglob("*") if path.is_file()}
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)) and archive.testzip() is None, "Duplicate/corrupt IPA entries")
        require(all(name.startswith("Payload/") and ".." not in Path(name).parts for name in names), "Unexpected IPA layout")
        require({name for name in names if not name.endswith("/")} == set(expected), "Packaged files differ from the actual built App")
        for name, path in expected.items():
            require(hashlib.sha256(archive.read(name)).hexdigest() == digest(path), "Packaged bytes differ: " + name)
    report("ipa-verification.json", dict(**manifest, verified_packaged_files=len(expected),
           tests_passed=129, dependency_gate="app-dependency-gate.json"))


if __name__ == "__main__":
    try:
        command = sys.argv[1]
        if command == "test-counts":
            test_counts(sys.argv[2], int(sys.argv[3]))
        else:
            {"select-simulator": select_simulator, "resolved": resolved, "settings": settings,
             "measurement-settings": measurement_settings, "processing-measurements": processing_measurements,
             "decoder-comparison-settings": lambda: measurement_settings(("TXTCore", "TXTCoreTests"), "decoder-comparison-settings"),
             "decoder-comparison": decoder_comparison,
             "all-test-gate": lambda: report("native-test-gate.json", all_test_evidence()),
             "package-gate": package_gate, "verify-ipa": verify_ipa}[command]()
    except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print("Task 3 validation stopped: " + str(error), file=sys.stderr)
        sys.exit(1)

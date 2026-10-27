"""Evidence gates for the one-shot Task 3 native workflow; never repairs build output."""

import hashlib
import json
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


def test_counts(target, expected):
    declared = [name for path in (ROOT / "Tests" / target).glob("*.swift")
                for name in re.findall(r"@Test\s+func\s+(\w+)\s*\(\s*\)", path.read_text(encoding="utf-8"))]
    log = (OUT / (target + ".log")).read_text(encoding="utf-8", errors="replace")
    summaries = re.findall(r"Test run with (\d+) tests?\b[^\r\n]*?\b(passed|failed)\b", log)
    passed = re.findall(r"\bTest (\w+)\(\) passed after\b", log)
    skipped = re.findall(r"^.*\b(?:Test|Suite) [^\r\n]*\bskipped\b[^\r\n]*$", log, re.MULTILINE)
    native_exit = int((OUT / (target + "-exit-code.txt")).read_text())
    report(target + "-counts.json", dict(expected=expected, declared=declared, passed=passed,
           native_summaries=summaries, skipped=skipped, native_exit=native_exit))
    require(native_exit == 0 and len(declared) == expected and len(set(declared)) == expected,
            "Native exit or declared test inventory mismatch: " + target)
    require(summaries == [(str(expected), "passed")] and sorted(passed) == sorted(declared) and not skipped,
            "Actual Swift Testing execution/count/pass evidence mismatch: " + target)


def unsigned(path):
    result = subprocess.run(["/usr/bin/codesign", "--display", str(path)], capture_output=True, text=True,
                            timeout=15, env={**os.environ, "LC_ALL": "C"})
    require(result.returncode == 1 and "not signed at all" in result.stderr, "Product is not confirmed unsigned: " + path.name)


def package_gate():
    require(sys.platform == "darwin", "Packaging gates require the real macOS output")
    for target, expected in (("TXTCoreTests", 25), ("ReaderDomainTests", 13)):
        counts = json.loads((OUT / (target + "-counts.json")).read_text())
        require(counts["native_exit"] == 0 and counts["expected"] == expected and len(counts["passed"]) == expected,
                "All 38 real tests must pass before packaging")
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
           tests_passed=38, dependency_gate="app-dependency-gate.json"))


if __name__ == "__main__":
    try:
        command = sys.argv[1]
        if command == "test-counts":
            test_counts(sys.argv[2], int(sys.argv[3]))
        else:
            {"select-simulator": select_simulator, "resolved": resolved, "settings": settings,
             "package-gate": package_gate, "verify-ipa": verify_ipa}[command]()
    except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print("Task 3 validation stopped: " + str(error), file=sys.stderr)
        sys.exit(1)

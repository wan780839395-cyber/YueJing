#!/usr/bin/env python3
"""Fixed native preparation contract; no dependency resolution or test execution.

inspect_toolchain(root, evidence_dir) queries actual executables and simulator SDK,
returns a JSON-safe identity, and raises ToolPreparationError on mismatch. prepare
also checks project pins, downloads the fixed official asset, verifies its bytes,
extracts into a fresh directory, checks XcodeGen, and generates project.yml.
Every external command uses workflow_process.run_logged; no shell or fallback.
Evidence is exclusive: use a fresh directory for a new invocation. Existing
qualification/dependency-resolution gates remain the caller's responsibility.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tempfile
import time

from workflow_process import run_logged

XCODE_VERSION = "16.4"
XCODE_BUILD = "16F6"
SWIFT_VERSION = "6.1.2"
ARCHITECTURE = "arm64"
SIMULATOR_SDK_VERSION = "18.5"
XCODEGEN_VERSION = "2.46.0"
XCODEGEN_SHA256 = "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
XCODEGEN_ASSET = "https://api.github.com/repos/yonaskolb/XcodeGen/releases/assets/478866069"
DEPENDENCIES = {
    "GRDB": ("https://github.com/groue/GRDB.swift.git", "7.0.0"),
    "ZIPFoundation": ("https://github.com/weichsel/ZIPFoundation.git", "0.9.19"),
}
QUERY_SECONDS = 30
DOWNLOAD_SECONDS = 150
EXTRACT_SECONDS = 60
GENERATE_SECONDS = 120
LOCAL_SECONDS = 5
HASH_SECONDS = 30
MAX_ARCHIVE_BYTES = 128 * 1024 * 1024


class ToolPreparationError(RuntimeError):
    """Environment/tool preparation failed, not a native test failure."""


def require(condition, message):
    if not condition:
        raise ToolPreparationError(message)


def _write_json(path, value):
    with Path(path).open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write("\n")


def _failure_status(error):
    # Fatal cleanup is a BaseException too, but is not a user cancellation.
    return 'cancelled' if isinstance(error, (KeyboardInterrupt, SystemExit)) else 'failed'


class _Evidence:
    def __init__(self, root, directory, receipt):
        self.root = Path(root).resolve()
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True)
        self.receipt = self.directory / receipt
        # Reserve before any command; never truncate old or concurrent evidence.
        self.stream = self.receipt.open("x", encoding="utf-8")
        self.steps = []
        self.started = time.monotonic()

    def command(self, name, args, budget=QUERY_SECONDS):
        path = self.directory / (name + ".log")
        step = dict(name=name, args=[str(arg) for arg in args],
                    timeout_seconds=budget, log=str(path), status="running")
        self.steps.append(step)
        started = time.monotonic()
        try:
            code, timed_out = run_logged(step["args"], path, budget, cwd=self.root)
            step.update(exit_code=code, timed_out=timed_out,
                        status="timed_out" if timed_out else "passed" if code == 0 else "failed")
            require(code == 0 and not timed_out, f"{name} failed: exit={code}, timed_out={timed_out}; {path}")
            require(path.stat().st_size <= 4 * 1024 * 1024, f"Oversized query log: {path}")
            return path.read_text(encoding="utf-8", errors="replace").strip()
        except BaseException as error:
            if step["status"] in ("running", "passed"):
                step['status'] = _failure_status(error)
            step["error"] = str(error)
            raise
        finally:
            step["elapsed_seconds"] = time.monotonic() - started

    def local(self, name, action, budget=LOCAL_SECONDS):
        path = self.directory / (name + ".json")
        step = dict(name=name, timeout_seconds=budget, log=str(path), status="running")
        self.steps.append(step)
        started = time.monotonic()
        try:
            result = action()
            require(time.monotonic() - started <= budget, f"{name} exceeded local budget")
            step.update(status="passed", result=result)
            return result
        except BaseException as error:
            step.update(status=_failure_status(error), error=str(error))
            raise
        finally:
            step["elapsed_seconds"] = time.monotonic() - started
            _write_json(path, step)

    def finish(self, result=None, error=None):
        status = 'passed' if error is None else _failure_status(error)
        receipt = dict(status=status, category="environment_tooling", root=str(self.root),
                       source_commit=os.environ.get("GITHUB_SHA"),
                       elapsed_seconds=time.monotonic() - self.started, steps=self.steps,
                       identity=result, error=str(error) if error else None)
        try:
            json.dump(receipt, self.stream, indent=2, ensure_ascii=False)
            self.stream.write("\n")
        finally:
            self.stream.close()


def validate_toolchain(values, *, allowed_architectures=(ARCHITECTURE,)):
    """Validate query output, never environment-variable version declarations."""
    require(values["system"] == "Darwin", "Native preparation requires macOS")
    require(isinstance(allowed_architectures, (tuple, list)) and allowed_architectures
            and all(arch in ("arm64", "x86_64") for arch in allowed_architectures)
            and len(set(allowed_architectures)) == len(allowed_architectures), "Invalid architecture contract")
    require(values["architecture"] in allowed_architectures, "Host architecture not authorized by caller")
    require(values["xcode"].splitlines() == [f"Xcode {XCODE_VERSION}", f"Build version {XCODE_BUILD}"],
            "Xcode version/build mismatch")
    versions = re.findall(r"^Apple Swift version (\d+\.\d+\.\d+)\b", values["swift"], re.M)
    require(versions == [SWIFT_VERSION], "Swift version mismatch")
    targets = re.findall(r"^Target: (.*)$", values["swift"], re.M)
    require(len(targets) == 1 and re.fullmatch(
        re.escape(values["architecture"]) + r"-apple-macosx[\d.]*", targets[0]), "Swift target mismatch")
    xcode_path = PurePosixPath(values["xcodebuild_path"])
    require(xcode_path.is_absolute() and str(xcode_path).endswith("/Contents/Developer/usr/bin/xcodebuild")
            and ".." not in xcode_path.parts, "Unexpected selected xcodebuild path")
    developer = xcode_path.parents[2]
    swift_path = PurePosixPath(values["swift_path"])
    require(swift_path.is_absolute() and ".." not in swift_path.parts
            and swift_path.is_relative_to(developer / "Toolchains")
            and str(swift_path).endswith(".xctoolchain/usr/bin/swift"), "Swift is outside selected Xcode")
    sdk_path = PurePosixPath(values["sdk_path"])
    sdk_parent = developer / "Platforms/iPhoneSimulator.platform/Developer/SDKs"
    require(sdk_path.is_absolute() and ".." not in sdk_path.parts and sdk_path.parent == sdk_parent
            and sdk_path.name in ("iPhoneSimulator.sdk", f"iPhoneSimulator{SIMULATOR_SDK_VERSION}.sdk"),
            "Simulator SDK is outside selected Xcode or has wrong identity")
    require(values["sdk_version"] == SIMULATOR_SDK_VERSION, "Simulator SDK version mismatch")
    require(re.fullmatch(r"[0-9]+[A-Z][0-9]+[a-z]?", values["sdk_build_version"]), "Missing/malformed simulator SDK build identity")
    return dict(xcode_version=XCODE_VERSION, xcode_build=XCODE_BUILD,
                swift_version=SWIFT_VERSION, swift_output=values["swift"],
                architecture=values["architecture"], system=values["system"], os=values["os"],
                allowed_architectures=list(allowed_architectures),
                developer_dir=str(developer), xcodebuild_path=str(xcode_path), swift_path=str(swift_path),
                sdk=dict(name="iphonesimulator", version=values["sdk_version"],
                         path=str(sdk_path), build_version=values["sdk_build_version"]))


def inspect_toolchain(root, evidence_dir, *, allowed_architectures=(ARCHITECTURE,)) -> dict:
    """No network/install/generation. Fresh toolchain.json + per-query raw logs.

    SDK build is recorded (not guessed); Xcode16.4/16F6, Swift6.1.2,
    SDK18.5 and paths belonging to the selected Xcode are required. Architecture
    defaults to arm64; historical TXT callers explicitly allow arm64/x86_64.
    """
    evidence = _Evidence(root, evidence_dir, "toolchain.json")
    try:
        queries = {
            "system": ["uname", "-s"], "architecture": ["uname", "-m"],
            "os": ["sw_vers"], "xcode": ["xcodebuild", "-version"],
            "xcodebuild_path": ["xcrun", "--find", "xcodebuild"],
            "swift": ["xcrun", "swift", "--version"],
            "swift_path": ["xcrun", "--find", "swift"],
            "sdk_version": ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"],
            "sdk_path": ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
            "sdk_build_version": ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-build-version"],
        }
        values = {key: evidence.command("tool-query-" + key, args) for key, args in queries.items()}
        with (evidence.directory / "toolchain.log").open("x", encoding="utf-8") as stream:
            stream.write("Source: " + os.environ.get("GITHUB_SHA", "unknown") + "\n")
            stream.write("\n".join(values.values()) + "\n")
        identity = evidence.local("toolchain-validation", lambda: validate_toolchain(
            values, allowed_architectures=allowed_architectures))
    except BaseException as error:
        evidence.finish(error=error)
        raise
    evidence.finish(result=identity)
    return identity


def validate_project_dependencies(project):
    """Fail-closed check of the small supported project.yml packages block.

    Not a general YAML parser: anchors/aliases/extra keys/duplicate packages are
    rejected, so overrides cannot silently change the fixed dependency contract.
    Actual resolved checkout verification remains in the existing native gate.
    """
    project = Path(project)
    require(project.stat().st_size <= 1024 * 1024, "Oversized project specification")
    text = project.read_text(encoding="utf-8")
    require(len(re.findall(r"^packages:", text, re.M)) == 1, "Missing/duplicate packages block")
    match = re.search(r"^packages:\s*\n((?:(?:[ \t]+[^\n]*|)\n)*)", text, re.M)
    require(match is not None, "Unsupported packages block")
    lines = [line.rstrip() for line in match[1].splitlines() if line.strip() and not line.lstrip().startswith("#")]
    expected = []
    for name, (url, version) in DEPENDENCIES.items():
        expected.extend([f"  {name}:", f"    url: {url}", f'    exactVersion: "{version}"'])
    require(lines == expected, "Fixed official dependency pins differ (GRDB7.0.0 / ZIPFoundation0.9.19)")
    return dict(project_sha256=hashlib.sha256(text.encode("utf-8")).hexdigest(),
                packages={name: dict(url=url, exact_version=version) for name, (url, version) in DEPENDENCIES.items()},
                resolved_checkouts="not inspected; retain existing post-resolution gates")


def verify_archive(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= MAX_ARCHIVE_BYTES,
            "Missing, symlinked or oversized XcodeGen archive")
    started = time.monotonic()
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            size += len(chunk)
            require(size <= MAX_ARCHIVE_BYTES and time.monotonic() - started <= HASH_SECONDS,
                    "XcodeGen checksum byte/time budget exceeded")
            digest.update(chunk)
    actual = digest.hexdigest()
    require(actual == XCODEGEN_SHA256, f"XcodeGen SHA256 mismatch: {actual}")
    return dict(sha256=actual, bytes=size, asset=XCODEGEN_ASSET)


def validate_xcodegen(output):
    require(re.findall(r"\b\d+\.\d+\.\d+\b", output) == [XCODEGEN_VERSION], "XcodeGen version mismatch")
    return dict(version=XCODEGEN_VERSION)


def prepare(root, evidence_dir, *, allowed_architectures=(ARCHITECTURE,)) -> dict:
    evidence = _Evidence(root, evidence_dir, "preparation.json")
    try:
        pins = evidence.local("project-dependencies", lambda: validate_project_dependencies(evidence.root / "project.yml"))
        identity = inspect_toolchain(evidence.root, evidence.directory, allowed_architectures=allowed_architectures)
        tooling = evidence.root / "_tooling"
        tooling.mkdir(exist_ok=True)
        # No reuse by directory existence or mtime, and no globally installed tool.
        work = Path(tempfile.mkdtemp(prefix="workflow-tools-", dir=tooling))
        archive = work / "xcodegen.zip"
        evidence.command("xcodegen-download", ["curl", "--fail", "--location", "--proto", "=https",
                         "--proto-redir", "=https", "--tlsv1.2", "--connect-timeout", "20",
                         "--max-time", "120", "--retry", "0", "--max-filesize", str(MAX_ARCHIVE_BYTES),
                         "--header", "Accept: application/octet-stream",
                         XCODEGEN_ASSET, "--output", str(archive)], DOWNLOAD_SECONDS)
        checksum = evidence.local("xcodegen-checksum", lambda: verify_archive(archive), HASH_SECONDS)
        evidence.command("xcodegen-extract", ["ditto", "-x", "-k", str(archive), str(work)], EXTRACT_SECONDS)
        binary = work / "xcodegen/bin/xcodegen"
        require(binary.is_file() and not binary.is_symlink() and os.access(binary, os.X_OK), "Missing executable XcodeGen")
        version = evidence.command("xcodegen", [str(binary), "--version"])
        evidence.local("xcodegen-version-validation", lambda: validate_xcodegen(version))
        evidence.command("project-generation", [str(binary), "generate", "--spec", "project.yml", "--project", "."], GENERATE_SECONDS)
        require((evidence.root / "YueJing.xcodeproj/project.pbxproj").is_file(), "XcodeGen produced no project")
        result = dict(toolchain=identity, dependencies=pins, xcodegen=dict(version=XCODEGEN_VERSION,
                      binary=str(binary), **checksum), project_generated=True,
                      native_tests="not run", qualification="tool preparation only")
    except BaseException as error:
        evidence.finish(error=error)
        raise
    evidence.finish(result=result)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "inspect"))
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--allowed-architectures", nargs="+", choices=("arm64", "x86_64"),
                        default=(ARCHITECTURE,), help="Explicit host/Swift architecture contract (default: arm64)")
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    directory = args.evidence if args.evidence.is_absolute() else root / args.evidence
    try:
        result = (prepare if args.command == "prepare" else inspect_toolchain)(
            root, directory, allowed_architectures=args.allowed_architectures)
    except (ToolPreparationError, OSError, ValueError) as error:
        print(f"Tool preparation rejected: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

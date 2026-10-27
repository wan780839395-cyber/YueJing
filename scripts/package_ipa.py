"""Validate the real macOS build output, then package it without signing or installing."""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/DerivedData/Build/Products/Release-iphoneos/YueJing.app"
OUT = ROOT / "artifacts"
BUNDLE_ID = "dev.yuejing.app"
MIN_OS = "16.6"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=60).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    require(sys.platform == "darwin", "IPA packaging requires the actual macOS build; no substitute input")
    commit = os.environ.get("GITHUB_SHA", "")
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "A real workflow source SHA is required")
    require(APP.is_dir() and not APP.is_symlink(), "Expected built App is missing or is a symlink")
    info_path = APP / "Info.plist"
    require(info_path.is_file(), "Built Info.plist is missing")
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    require(info.get("CFBundleIdentifier") == BUNDLE_ID, "Unexpected bundle identity")
    require(info.get("CFBundlePackageType") == "APPL", "Built product is not an App")
    require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "App is not an iPhoneOS product")
    require(info.get("DTPlatformName") == "iphoneos", "App platform metadata is not iphoneos")
    require(info.get("MinimumOSVersion") == MIN_OS, "Built deployment target differs from iOS16.6")
    name = info.get("CFBundleExecutable")
    require(name == "YueJing", "Unexpected or missing executable name")
    executable = APP / name
    require(executable.is_file() and not executable.is_symlink() and os.access(executable, os.X_OK),
            "Built executable is missing, linked, or not executable")
    architectures = run(["xcrun", "lipo", "-archs", str(executable)]).split()
    require(architectures == ["arm64"], "Expected exactly the iPhoneOS arm64 architecture")
    macho = run(["xcrun", "vtool", "-show-build", str(executable)])
    require(re.search(r"^\s*platform IOS\s*$", macho, re.MULTILINE), "Mach-O is not built for iOS devices")
    require(re.search(r"^\s*minos 16\.6(?:\.0)?\s*$", macho, re.MULTILINE), "Mach-O minimum OS differs from iOS16.6")
    signature = subprocess.run(["/usr/bin/codesign", "--display", str(APP)],
                               capture_output=True, text=True, timeout=15,
                               env={**os.environ, "LC_ALL": "C"})
    require(signature.returncode == 1 and "not signed at all" in signature.stderr,
            "App signing state is not confirmed unsigned")
    require(not (APP / "embedded.mobileprovision").exists() and not (APP / "_CodeSignature").exists(),
            "Unexpected signing or provisioning material")
    require(info.get("CFBundleShortVersionString") and info.get("CFBundleVersion"), "Missing version metadata")

    payload = OUT / "Payload"
    ipa = OUT / "YueJing-unsigned.ipa"
    staging_ipa = OUT / "YueJing-unsigned.ipa.partial"
    manifest_path = OUT / "manifest.json"
    sums = OUT / "SHA256SUMS"
    require(not any(path.exists() for path in (payload, ipa, staging_ipa, manifest_path, sums)),
            "Packaging outputs already exist; stop without overwriting or retrying")
    OUT.mkdir(exist_ok=True)
    payload.mkdir()
    run(["/usr/bin/ditto", "--norsrc", "--noextattr", str(APP), str(payload / APP.name)])
    run(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", "--keepParent", str(payload), str(staging_ipa)])
    with zipfile.ZipFile(staging_ipa) as archive:
        require(archive.testzip() is None, "IPA ZIP integrity check failed")
        prefix = "Payload/YueJing.app/"
        require(hashlib.sha256(archive.read(prefix + "Info.plist")).hexdigest() == sha256(info_path),
                "Packaged Info.plist differs from the built App")
        require(hashlib.sha256(archive.read(prefix + name)).hexdigest() == sha256(executable),
                "Packaged executable differs from the built App")
    staging_ipa.rename(ipa)

    manifest = {
        "source_commit": commit,
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "bundle_identifier": BUNDLE_ID,
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "platform": "iPhoneOS",
        "architectures": architectures,
        "minimum_os": info["MinimumOSVersion"],
        "signing": "unsigned",
        "physical_device_acceptance": "not performed",
        "ipa_file": ipa.name,
        "ipa_bytes": ipa.stat().st_size,
        "ipa_sha256": sha256(ipa),
        "executable_sha256": sha256(executable),
        "info_plist_sha256": sha256(info_path),
        "project_spec_sha256": sha256(ROOT / "project.yml"),
    }
    with manifest_path.open("x", encoding="utf8") as output:
        json.dump(manifest, output, ensure_ascii=False, indent=2)
        output.write("\n")
    with sums.open("x", encoding="utf8") as output:
        for path in (ipa, manifest_path):
            output.write(f"{sha256(path)}  {path.name}\n")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(f"Packaging stopped: {error}", file=sys.stderr)
        sys.exit(1)

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
PROJECT_SPEC = ROOT / "project.yml"
BUNDLE_ID = "dev.yuejing.app"
DISPLAY_NAME = "阅境"
EXECUTABLE_NAME = "YueJing"
MIN_OS = "16.6"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
VERSION_RE = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))?")
BUILD_RE = re.compile(r"[1-9][0-9]*")
ICON_NAME_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]*")


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


def parse_unique_setting(spec_text, key):
    matches = re.findall(
        rf"^[ \t]*{re.escape(key)}:[ \t]*(?:\"([^\"\r\n]+)\"|'([^'\r\n]+)'|([^\s#\"'\r\n]+))[ \t]*(?:#.*)?$",
        spec_text,
        re.MULTILINE,
    )
    require(len(matches) == 1, f"Expected unique {key} in project.yml")
    return next(group for group in matches[0] if group != "")


def expected_project_identity(project_spec=PROJECT_SPEC):
    require(project_spec.is_file(), "project.yml is missing")
    spec_text = project_spec.read_text(encoding="utf-8")
    version = parse_unique_setting(spec_text, "MARKETING_VERSION")
    build = parse_unique_setting(spec_text, "CURRENT_PROJECT_VERSION")
    icon_name = parse_unique_setting(spec_text, "ASSETCATALOG_COMPILER_APPICON_NAME")
    require(VERSION_RE.fullmatch(version), f"Invalid MARKETING_VERSION in project.yml: {version!r}")
    require(BUILD_RE.fullmatch(build), f"Invalid numeric CURRENT_PROJECT_VERSION in project.yml: {build!r}")
    require(ICON_NAME_RE.fullmatch(icon_name), f"Invalid ASSETCATALOG_COMPILER_APPICON_NAME in project.yml: {icon_name!r}")
    return {"version": version, "build": build, "icon_name": icon_name}


def validate_built_icons(app_path, info, expected_icon):
    assets_car = app_path / "Assets.car"
    require(assets_car.is_file() and not assets_car.is_symlink() and assets_car.stat().st_size > 64,
            "Compiled Assets.car is missing, linked, or empty")
    icons = info.get("CFBundleIcons")
    require(isinstance(icons, dict), "Built Info.plist is missing CFBundleIcons")
    primary = icons.get("CFBundlePrimaryIcon")
    require(isinstance(primary, dict), "Built Info.plist is missing CFBundlePrimaryIcon")
    icon_name = primary.get("CFBundleIconName")
    require(icon_name == expected_icon,
            f"Built CFBundleIconName {icon_name!r} differs from expected {expected_icon!r}")
    icon_entries = primary.get("CFBundleIconFiles")
    require(isinstance(icon_entries, list) and len(icon_entries) > 0,
            "Built CFBundlePrimaryIcon is missing CFBundleIconFiles")
    referenced_pngs = []
    seen_names = set()
    for entry in icon_entries:
        require(isinstance(entry, str) and entry and "/" not in entry and "\\" not in entry and ".." not in entry,
                f"Invalid CFBundleIconFiles entry: {entry!r}")
        stem = entry[:-4] if entry.endswith(".png") else entry
        require(stem.startswith(expected_icon) and re.fullmatch(r"[A-Za-z0-9._@~-]+", stem),
                f"Unexpected CFBundleIconFiles entry: {entry!r}")
        pattern = re.compile(re.escape(stem) + r"(?:@[123]x)?(?:~iphone|~ipad)?\.png")
        matches = sorted(candidate for candidate in app_path.iterdir() if pattern.fullmatch(candidate.name))
        require(matches, f"Built App is missing PNG resource(s) referenced by {entry!r}")
        for png_path in matches:
            require(png_path.is_file() and not png_path.is_symlink(),
                    f"Built icon PNG is missing or linked: {png_path.name}")
            # actool may emit Apple-optimized PNGs with CgBI before IHDR.
            # Read only the bounded header; this is not a full image decode.
            error = f"Built icon resource has an invalid PNG header: {png_path.name}"
            with png_path.open("rb") as source:
                require(source.read(8) == PNG_SIGNATURE and png_path.stat().st_size >= 57, error)
                chunk = source.read(8)
                if chunk[4:] == b"CgBI":
                    cgbi_size = int.from_bytes(chunk[:4], "big")
                    require(cgbi_size <= 64, error)
                    require(len(source.read(cgbi_size + 4)) == cgbi_size + 4, error)
                    chunk = source.read(8)
                require(chunk == b"\x00\x00\x00\x0dIHDR", error)
                ihdr = source.read(17)  # 13-byte payload and 4-byte CRC.
                require(len(ihdr) == 17 and int.from_bytes(ihdr[:4], "big") > 0
                        and int.from_bytes(ihdr[4:8], "big") > 0, error)
            if png_path.name not in seen_names:
                seen_names.add(png_path.name)
                referenced_pngs.append(png_path)
    return assets_car, referenced_pngs


def validate_release_identity(app_path, info, expected):
    require(info.get("CFBundleIdentifier") == BUNDLE_ID, "Unexpected bundle identity")
    require(info.get("CFBundleDisplayName") == DISPLAY_NAME, "Unexpected bundle display name")
    require(info.get("CFBundlePackageType") == "APPL", "Built product is not an App")
    require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "App is not an iPhoneOS product")
    require(info.get("DTPlatformName") == "iphoneos", "App platform metadata is not iphoneos")
    require(info.get("MinimumOSVersion") == MIN_OS, "Built deployment target differs from iOS16.6")
    name = info.get("CFBundleExecutable")
    require(name == EXECUTABLE_NAME, "Unexpected or missing executable name")
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    require(isinstance(version, str) and VERSION_RE.fullmatch(version),
            "Missing or invalid built CFBundleShortVersionString")
    require(isinstance(build, str) and BUILD_RE.fullmatch(build),
            "Missing or non-numeric built CFBundleVersion")
    require(version == expected["version"],
            f"Built version {version} differs from project.yml {expected['version']}")
    require(build == expected["build"],
            f"Built build {build} differs from project.yml {expected['build']}")
    ipa_name = f"YueJing-{version}.ipa"
    require(Path(ipa_name).name == ipa_name and "/" not in ipa_name and "\\" not in ipa_name and ".." not in ipa_name,
            "Unsafe derived IPA filename")
    assets_car, icon_pngs = validate_built_icons(app_path, info, expected["icon_name"])
    return {
        "executable_name": name,
        "version": version,
        "build": build,
        "ipa_name": ipa_name,
        "staging_ipa_name": f"{ipa_name}.partial",
        "icon_name": expected["icon_name"],
        "assets_car": assets_car,
        "icon_pngs": icon_pngs,
    }


def main():
    require(sys.platform == "darwin", "IPA packaging requires the actual macOS build; no substitute input")
    commit = os.environ.get("GITHUB_SHA", "")
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "A real workflow source SHA is required")
    expected = expected_project_identity(PROJECT_SPEC)
    require(APP.is_dir() and not APP.is_symlink(), "Expected built App is missing or is a symlink")
    info_path = APP / "Info.plist"
    require(info_path.is_file() and not info_path.is_symlink(), "Built Info.plist is missing")
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    identity = validate_release_identity(APP, info, expected)
    name = identity["executable_name"]
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
    require(not (APP / "embedded.mobileprovision").exists() and not (APP / "_CodeSignature").exists()
            and not list(APP.rglob("embedded.mobileprovision")) and not list(APP.rglob("_CodeSignature")),
            "Unexpected signing or provisioning material")

    payload = OUT / "Payload"
    ipa = OUT / identity["ipa_name"]
    staging_ipa = OUT / identity["staging_ipa_name"]
    manifest_path = OUT / "manifest.json"
    sums = OUT / "SHA256SUMS"
    require(not any(path.exists() for path in (payload, ipa, staging_ipa, manifest_path, sums))
            and not list(OUT.glob("*.ipa")) and not list(OUT.glob("*.ipa.partial")),
            "Packaging outputs already exist; stop without overwriting or retrying")
    OUT.mkdir(exist_ok=True)
    payload.mkdir()
    run(["/usr/bin/ditto", "--norsrc", "--noextattr", str(APP), str(payload / APP.name)])
    run(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", "--keepParent", str(payload), str(staging_ipa)])
    assets_car = identity["assets_car"]
    icon_pngs = identity["icon_pngs"]
    with zipfile.ZipFile(staging_ipa) as archive:
        require(archive.testzip() is None, "IPA ZIP integrity check failed")
        prefix = "Payload/YueJing.app/"
        require(hashlib.sha256(archive.read(prefix + "Info.plist")).hexdigest() == sha256(info_path),
                "Packaged Info.plist differs from the built App")
        require(hashlib.sha256(archive.read(prefix + name)).hexdigest() == sha256(executable),
                "Packaged executable differs from the built App")
        require(hashlib.sha256(archive.read(prefix + assets_car.name)).hexdigest() == sha256(assets_car),
                "Packaged Assets.car differs from the built App")
        for icon_png in icon_pngs:
            require(hashlib.sha256(archive.read(prefix + icon_png.name)).hexdigest() == sha256(icon_png),
                    f"Packaged icon PNG differs from the built App: {icon_png.name}")
    staging_ipa.rename(ipa)

    manifest = {
        "source_commit": commit,
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "bundle_identifier": BUNDLE_ID,
        "display_name": info["CFBundleDisplayName"],
        "version": identity["version"],
        "build": identity["build"],
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
        "assets_car_sha256": sha256(assets_car),
        "app_icon_name": identity["icon_name"],
        "app_icon_files": [path.name for path in icon_pngs],
        "project_spec_sha256": sha256(PROJECT_SPEC),
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

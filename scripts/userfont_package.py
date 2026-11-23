"""Same-job targeted package qualification for the custom EPUB body font release."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zipfile

from epub_diagnostic_package import MIT_LICENSES
from package_ipa import expected_project_identity
from validate_task3 import APP, ROOT, digest, require

SCOPE = "userfont-native-025"
VERSION, BUILD = "0.2.25", "27"
PREFIX = "Payload/YueJing.app/"


def qualification(run_id, attempt):
    require(all(re.fullmatch(r"[1-9][0-9]*", s) for s in (run_id, attempt)), "Invalid workflow run or attempt")
    return dict(scope=SCOPE, run_id=run_id, run_attempt=attempt,
                qualification="USERFONT_TARGETED_NATIVE", coverage="USERFONT_TARGETED_NOT_FULL",
                full_regression_passed=False, diagnostic=False, build_ipa=True, allow_unqualified_ipa=False,
                native_tests_executed_this_job=6, native_tests_passed=6,
                native_evidence_directory="artifacts/development/execution")


def verify_native():
    env = os.environ
    require(env.get("GITHUB_EVENT_NAME") == "workflow_dispatch" and env.get("VALIDATION_SCOPE") == SCOPE
            and env.get("BUILD_IPA") == "true" and env.get("ALLOW_UNQUALIFIED_IPA") == "false",
            "Expected explicitly requested qualified custom-font IPA")
    inputs = json.loads(Path(env["GITHUB_EVENT_PATH"]).read_bytes())["inputs"]
    require(inputs.get("validation_scope") == SCOPE and str(inputs.get("build_ipa")).lower() == "true"
            and str(inputs.get("allow_unqualified_ipa")).lower() == "false" and not inputs.get("prior_validation_run"),
            "Dispatch inputs do not authorize same-run qualified packaging")
    project = expected_project_identity()
    info = plistlib.loads((APP / "Info.plist").read_bytes())
    require((project["version"], project["build"]) == (VERSION, BUILD)
            == (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")), "Wrong custom-font release")
    # The native verifier, not a saved pass count, owns the six case identities and raw evidence parsing.
    subprocess.run([sys.executable, "scripts/run_userfont_native.py", "verify"], cwd=ROOT, check=True)
    fields = qualification(env["GITHUB_RUN_ID"], env["GITHUB_RUN_ATTEMPT"])
    return dict(**fields, job=env["GITHUB_JOB"], native_summary_sha256=digest(
        ROOT / fields["native_evidence_directory"] / "development-summary.json"))


def release_hashes(app):
    return {PREFIX + p.relative_to(app).as_posix(): digest(p) for p in app.rglob("*") if p.is_file()}


def check_release_gate(path, qualified, manifest, hashes):
    gate = json.loads(path.read_bytes())
    require(all(gate[k] == val for k, val in qualified.items()) and gate["source_commit"] == manifest["source_commit"]
            and gate["signing"] == manifest["signing"] == "unsigned" and gate["release_files_sha256"] == hashes,
            "IPA files or same-run device Release qualification differ from the pre-package gate")
    licenses = {name: sha for name, (_, sha) in MIT_LICENSES.items()}
    require(gate["mit_licenses"] == licenses and all(hashes[PREFIX + n] == sha for n, sha in licenses.items())
            and gate["actual_images"] and all(hashes[PREFIX + row["binary"]] == row["sha256"] for row in gate["actual_images"]),
            "Packaged MIT licenses or device images differ from checked Release bytes")


def verify_download(directory, source, run_id, attempt, ipa_sha):
    """Check an extracted package artifact against independently supplied workflow identities."""
    qualified = qualification(run_id, attempt)
    require(re.fullmatch(r"[0-9a-f]{40}", source) and re.fullmatch(r"[0-9a-f]{64}", ipa_sha),
            "Expected full checkout SHA and independent IPA SHA256")
    root = Path(directory)
    ipa = root / f"YueJing-{VERSION}.ipa"
    manifest_path = root / "manifest.json"
    gate = root / "task3/app-dependency-gate.json"
    manifest = json.loads(manifest_path.read_bytes())
    proof = json.loads((root / "task3/ipa-verification.json").read_bytes())
    qualified.update(job=proof["job"], native_summary_sha256=proof["native_summary_sha256"])
    require(qualified["job"] and re.fullmatch(r"[0-9a-f]{64}", qualified["native_summary_sha256"]),
            "Incomplete native job provenance")
    require(list(root.glob("*.ipa")) == [ipa] and not ipa.is_symlink() and digest(ipa) == ipa_sha
            and (root / "SHA256SUMS").read_text().splitlines() == [f"{ipa_sha}  {ipa.name}", f"{digest(manifest_path)}  manifest.json"],
            "Downloaded IPA or checksums differ")
    identity = dict(source_commit=source, version=VERSION, build=BUILD, ipa_file=ipa.name, ipa_sha256=ipa_sha,
                    ipa_bytes=ipa.stat().st_size, architectures=["arm64"], minimum_os="16.6", platform="iPhoneOS")
    require(all(manifest[k] == v for k, v in identity.items()) and all(proof[k] == v for k, v in manifest.items())
            and all(proof[k] == v for k, v in qualified.items()) and proof["dependency_gate_sha256"] == digest(gate),
            "Downloaded release identity or qualification differs")
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        require(len(set(names)) == len(names) and archive.testzip() is None, "Duplicate or corrupt IPA entries")
        hashes = {n: hashlib.sha256(archive.read(n)).hexdigest() for n in names if not n.endswith("/")}
    require(len(hashes) == proof["verified_packaged_files"], "Downloaded file count differs")
    check_release_gate(gate, qualified, manifest, hashes)
    print(f"Verified {ipa.name}: {len(hashes)} device Release files, run {run_id}/{attempt}, {ipa_sha}")


if __name__ == "__main__":
    if len(sys.argv) != 7 or sys.argv[1] != "verify-download":
        sys.exit("usage: userfont_package.py verify-download EXTRACTED_DIR SOURCE_SHA RUN_ID ATTEMPT IPA_SHA256")
    verify_download(*sys.argv[2:])

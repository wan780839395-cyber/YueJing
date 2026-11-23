"""Explicitly authorized device-only diagnostic package; never claims native test acceptance."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile

import validate_task3 as v

BASE = "a0fbb605514759286e61cdeb5cd14f85d595697d"
SCOPE = "epub-diagnostic-a0fbb60"
VERSION, BUILD = "0.2.21", "23"
ALLOWED = frozenset((".github/workflows/task3-validate.yml", "scripts/validate_task3.py",
                     "scripts/epub_diagnostic_package.py", "docs/EPUB_DIAGNOSTIC_PACKAGE.md"))


NEON = os.environ.get("VALIDATION_SCOPE") in ("neon-device-022", "neon-device-023")
if NEON:
    BASE = "96e88d8037f8159ab9a4ba4d5609038910a1ba4f"
    SCOPE = "neon-device-022"
    VERSION, BUILD = "0.2.22", "24"
    ALLOWED = frozenset((".github/workflows/task3-validate.yml", "scripts/workflow_admission.py", "scripts/epub_diagnostic_package.py"))
    if os.environ["VALIDATION_SCOPE"] == "neon-device-023":
        BASE, SCOPE = "7fa99ef2d21529e4614a1c0845f4424270c39eff", "neon-device-023"
        VERSION, BUILD = "0.2.23", "25"

WOFF2_SCOPE = "woff2-native-024"
WOFF2_PRODUCT = "88024e7a7f474a90c2ef9b58d23ca0e5cc4ebda2"
WOFF2 = os.environ.get("VALIDATION_SCOPE") == WOFF2_SCOPE
if WOFF2:
    BASE, SCOPE = WOFF2_PRODUCT, WOFF2_SCOPE
    VERSION, BUILD = "0.2.24", "26"
    # Exact child diff, not a permitted superset. Coordinate native paths before publishing.
    ALLOWED = frozenset((".github/workflows/task3-validate.yml", "scripts/workflow_admission.py",
                         "scripts/workflow_tools.py", "scripts/epub_diagnostic_package.py",
                         "scripts/validate_task3.py", "scripts/run_woff2_native.py",
                         "scripts/woff2_native_plan.json"))

# Exact upstream MIT texts as vendored in the frozen product.
MIT_LICENSES = {
    "WOFF2-LICENSE.txt": ("woff", "d42a3e363d99da22b860ab760faa37dfa9781d74c9f3ed634d05109081616513"),
    "Brotli-LICENSE.txt": ("brotli", "3d180008e36922a4e8daec11c34c7af264fed5962d07924aea928c38e8663c94"),
}


def release_licenses():
    for name, (vendor, sha) in MIT_LICENSES.items():
        for path in (v.ROOT / "Sources/CWOFF2" / vendor / "LICENSE", v.ROOT / "App/Resources" / name, v.APP / name):
            v.require(path.is_file() and not path.is_symlink() and v.digest(path) == sha,
                      "Missing or changed MIT license: " + str(path))
    return {name: sha for name, (_, sha) in MIT_LICENSES.items()}


def git(*args):
    return subprocess.check_output(["git", *args], cwd=v.ROOT, timeout=30)


def tree(revision):
    result = {}
    for row in git("ls-tree", "-r", "-z", revision).split(b"\0"):
        if row:
            meta, name = row.split(b"\t", 1)
            result[name.decode()] = meta.decode().split()
    return result


def scope_receipt():
    env = os.environ
    v.require(env.get("VALIDATION_SCOPE") == SCOPE and env.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
              and env.get("GITHUB_REF") == ("refs/heads/dev/workflow-optimization" if NEON or WOFF2 else "refs/heads/main") and env.get("GITHUB_RUN_ATTEMPT") == "1"
              and env.get("GITHUB_REPOSITORY") == "wan780839395-cyber/YueJing", "Diagnostic dispatch identity differs")
    v.require(env.get("ALLOW_UNQUALIFIED_IPA") == "true" and env.get("BUILD_IPA") == "true",
              "Explicit diagnostic delivery and device build inputs are required")
    event = json.loads(Path(env["GITHUB_EVENT_PATH"]).read_bytes())
    inputs = event.get("inputs", {})
    v.require(inputs.get("validation_scope") == SCOPE
              and str(inputs.get("allow_unqualified_ipa")).lower() == "true"
              and str(inputs.get("build_ipa")).lower() == "true"
              and (not (NEON or WOFF2) or inputs.get("scope_acknowledgement") == SCOPE)
              and not inputs.get("prior_validation_run"), "Diagnostic dispatch inputs differ")
    head = git("rev-parse", "HEAD").decode().strip()
    parent = git("rev-parse", "HEAD^").decode().strip()
    download_fix = SCOPE == "neon-device-023" and parent == "8fe15d932ca566928c537dc56b2a8e22509d2e66"
    compare_base = parent if download_fix else BASE
    allowed = {"scripts/workflow_tools.py", "scripts/epub_diagnostic_package.py"} if download_fix else ALLOWED
    v.require(head == env.get("GITHUB_SHA") and parent == compare_base,
              "Diagnostic candidate must be one packaging-only child of the approved source")
    v.require(not git("status", "--porcelain", "--untracked-files=no").strip(), "Tracked source drift")
    if WOFF2:
        v.require(inputs.get("development_source_sha") == head
                  and inputs.get("development_plan_sha256") == v.digest(v.ROOT / "scripts/woff2_native_plan.json"),
                  "WOFF2 dispatch release SHA or bounded plan digest differs")
        v.require(len(git("rev-list", "--parents", "-n1", "HEAD").split()) == 2,
                  "WOFF2 diagnostic candidate must not be a merge")
        v.require(not git("ls-files", "--others", "--", "Sources/CWOFF2").strip(), "Untracked decoder source")
    before, after = tree(compare_base), tree("HEAD")
    changed = {n for n in set(before) | set(after) if before.get(n) != after.get(n)}
    v.require(changed == allowed and all(after[n][:2] == ["100644", "blob"] for n in changed),
              "Diagnostic package must match the exact publishing path set")
    from package_ipa import expected_project_identity
    identity = expected_project_identity()
    v.require(identity["version"] == VERSION and identity["build"] == BUILD, "Diagnostic version differs")
    return dict(scope=SCOPE, source_commit=head, product_source_commit=BASE,
                run_id=env["GITHUB_RUN_ID"], run_attempt="1", changed_paths=sorted(changed),
                qualification="DEVICE_DIAGNOSTIC_ONLY", coverage="UI_NOT_QUALIFIED",
                **({"native_tests_executed_this_job": 0} if WOFF2 else {"native_tests_executed_this_run": 0}),
                full_regression_passed=False,
                allow_unqualified_ipa=True, build_ipa=True,
                unresolved_cases=(["Native qualification is reported by the independent native job; device installation not performed"] if WOFF2
                                  else ["Neon UI and on-device reading interactions not validated"] if NEON
                                  else ["testEPUBShelfCoverAndDirectoryCrossChapterNavigation"]),
                validation_reference=None if NEON or WOFF2 else dict(run_id="43427854507", source_commit=BASE,
                    artifact_id=14040301098,
                    artifact_sha256="c049599ff0bd06d5f4fc672c5ea3ffa16af0f00e823130f0f6617d13c6b4e08e",
                    reported_passed=24, reported_failed=1,
                    evidence_kind="SEPARATE_RUN_REFERENCE_NOT_CURRENT_NATIVE_GATE"),
                physical_acceptance="not performed", files=v.candidate_files())


def validate_saved():
    expected = scope_receipt()
    actual = json.loads((v.OUT / "epub-diagnostic-scope.json").read_bytes())
    v.require(actual == expected, "Diagnostic source/run/disclosure receipt drift")
    native_gates = ("native-test-gate.json", "epub-reading-gate.json", "author-layout-gate.json",
                    "epub-freeze-gate.json", "epub-compat-gate.json", "epub-paging-gate.json", "reused-native-gate.json")
    if WOFF2:
        native_gates += ("woff2-native-gate.json",)
    v.require(not any((v.OUT / name).exists() for name in native_gates),
              "Diagnostic package cannot carry a current native-pass gate")
    return actual


def verify_download(directory, source, run_id, ipa_sha):
    """Read the extracted WOFF2 IPA artifact; take identities from the independent run evidence."""
    v.require(re.fullmatch(r"[0-9a-f]{40}", source) and re.fullmatch(r"[1-9][0-9]*", run_id)
              and re.fullmatch(r"[0-9a-f]{64}", ipa_sha), "Expected full release SHA, run ID and IPA SHA256")
    root = Path(directory)
    manifest_path = root / "manifest.json"
    manifest = json.loads(manifest_path.read_bytes())
    gate = json.loads((root / "task3/app-dependency-gate.json").read_bytes())
    proof = json.loads((root / "task3/ipa-verification.json").read_bytes())
    scope = json.loads((root / "task3/epub-diagnostic-scope.json").read_bytes())
    ipa = root / "YueJing-0.2.24.ipa"
    v.require(list(root.glob("*.ipa")) == [ipa] and not ipa.is_symlink() and v.digest(ipa) == ipa_sha
              and (root / "SHA256SUMS").read_text().splitlines() == [f"{ipa_sha}  {ipa.name}", f"{v.digest(manifest_path)}  manifest.json"],
              "Downloaded IPA or SHA256SUMS mismatch")
    identity = dict(source_commit=source, version="0.2.24", build="26", ipa_file=ipa.name, ipa_sha256=ipa_sha,
                    ipa_bytes=ipa.stat().st_size, minimum_os="16.6", architectures=["arm64"], platform="iPhoneOS", signing="unsigned")
    v.require(all(manifest[k] == val for k, val in identity.items()) and all(proof[k] == val for k, val in manifest.items()),
              "Downloaded manifest/release identity mismatch")
    v.require(scope == proof["diagnostic_evidence"] and scope["scope"] == WOFF2_SCOPE and scope["product_source_commit"] == WOFF2_PRODUCT
              and scope["qualification"] == proof["qualification"] == "DEVICE_DIAGNOSTIC_ONLY"
              and scope["native_tests_executed_this_job"] == proof["native_tests_executed_this_job"] == 0
              and all(row["run_id"] == run_id and row["source_commit"] == source and row["run_attempt"] == "1" for row in (scope, gate)),
              "Downloaded diagnostic evidence provenance mismatch")
    prefix = "Payload/YueJing.app/"
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        v.require(len(names) == len(set(names)) and archive.testzip() is None, "Duplicate or damaged IPA member")
        files = {n: hashlib.sha256(archive.read(n)).hexdigest() for n in names if not n.endswith("/")}
    licenses = {name: sha for name, (_, sha) in MIT_LICENSES.items()}
    v.require(files == proof["release_files_sha256"] and len(files) == proof["verified_packaged_files"]
              and gate["mit_licenses"] == licenses and all(files[prefix + n] == sha for n, sha in licenses.items())
              and gate["signing"] == "unsigned" and gate["actual_images"]
              and all(files[prefix + row["binary"]] == row["sha256"] for row in gate["actual_images"]),
              "Downloaded IPA differs from verified device Release")
    print(f"Verified {ipa.name}: {len(files)} Release files, {len(gate['actual_images'])} device images, {ipa_sha}")


if __name__ == "__main__":
    if sys.argv[1:] == ["freeze"]:
        v.freeze_candidate()
        v.report("epub-diagnostic-scope.json", scope_receipt())
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as output:
            output.write("## DIAGNOSTIC ONLY — TESTS NOT RUN / UI NOT QUALIFIED\n\n"
                         "User requested a device package for on-device diagnosis, not native qualification. "
                         "No simulator, Domain, Host or UI execution in this packaging job. Product source frozen at the bound parent commit. "
                         "Device Release, dependency, unsigned and payload byte checks remain required.\n")
    elif len(sys.argv) == 6 and sys.argv[1] == "verify-download":
        verify_download(*sys.argv[2:])
    else:
        raise SystemExit("Expected freeze | verify-download ARTIFACT_DIR RELEASE_SHA RUN_ID IPA_SHA256")

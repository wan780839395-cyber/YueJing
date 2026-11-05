"""Targeted 33-case EPUB compatibility native validation and scope/receipt gates."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import audit_native_case_events as audit
import check_epub_batch as epub_batch
import run_reading_ui_tests as ui
import task3_test_inventory as inventory
import validate_task3 as validator

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "artifacts/task3"
EPUB_OUT = OUT / "epub-compat"
SCOPE_JSON = OUT / "epub-compat-scope.json"
GATE_JSON = OUT / "epub-compat-gate.json"
RESOLVED = ROOT / "YueJing.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

BASE = "4d26ecf62b50014d97cd02d4fd512a617dfcbf1e"
SCOPE = "epub-compat-33"
EXPECTED_VERSION = "0.2.1"
EXPECTED_BUILD = "3"

OLD_VERSION_LINES = (
    b'        MARKETING_VERSION: "0.2.0"\n'
    b'        CURRENT_PROJECT_VERSION: "2"\n'
)
NEW_VERSION_LINES = (
    b'        MARKETING_VERSION: "0.2.1"\n'
    b'        CURRENT_PROJECT_VERSION: "3"\n'
)

ALLOWED = frozenset({
    "Sources/ReaderDomain/EPUB/EPUBCompatibility.swift",
    "Sources/ReaderDomain/EPUB/EPUBContentPolicy.swift",
    "Sources/ReaderDomain/EPUB/EPUBPackageParser.swift",
    "Sources/ReaderDomain/EPUB/EPUBResourceStore.swift",
    "App/EPUB/EPUBResourceHandler.swift",
    "Tests/ReaderDomainTests/EPUBCompatibilityTests.swift",
    "Tests/YueJingHostTests/EPUBReaderHostTests.swift",
    ".github/workflows/task3-validate.yml",
    "project.yml",
    "scripts/task3_test_inventory.py",
    "scripts/validate_task3.py",
    "scripts/check_task3_validation.py",
    "scripts/check_validation_aggregation.py",
    "scripts/check_epub_batch.py",
    "scripts/check_reuse_native_evidence.py",
    "scripts/run_epub_compat_validation.py",
    "scripts/check_epub_compat_validation.py",
    "docs/EPUB_COMPATIBILITY.md",
})

NEW_ALLOWED = frozenset({
    "Sources/ReaderDomain/EPUB/EPUBCompatibility.swift",
    "Tests/ReaderDomainTests/EPUBCompatibilityTests.swift",
    "scripts/run_epub_compat_validation.py",
    "scripts/check_epub_compat_validation.py",
    "docs/EPUB_COMPATIBILITY.md",
})

# Fixed reviewed 33 case identities (28 Domain across 4 suites + 5 Host in 1 suite).
SELECTED_FILES = {
    "ReaderDomainTests/EPUBPackageTests.swift": (
        "epubPackageParsesEPUB3AndEPUB2ContainersInExactSpineOrder",
        "epubPackageResolvesNavAndNCXHierarchyWithValidatedFragments",
        "epubPackageRejectsXXEDTDAndEntityDeclarationsAcrossUTF8AndUTF16",
        "epubPackageRejectsMissingMetadataEmptyBodyAndDuplicateManifestItems",
        "epubPackageRejectsBrokenSpineAndBodyResourceReferences",
        "epubPackageRejectsEncryptedFixedLayoutAndActiveContent",
        "epubPackageSelectsValidCoversAndFallsBackOnOptionalCoverProblems",
        "epubPackageFailsFatallyOnCorruptBodyImageOrArchiveIntegrityError",
    ),
    "ReaderDomainTests/EPUBLibraryTests.swift": (
        "epubOriginalArchiveAndValidatedResourcesSurviveReopen",
        "epubDuplicateKeepsProgressAndRepairsMissingArchive",
        "epubCancellationBeforeCommitLeavesNoBook",
        "epubCancellationAfterCommitReturnsReceipt",
        "epubFailedImportCleansOnlyItsWorkspace",
        "epubV6MigrationPreservesTXTProgressBookmarksAndPreferences",
        "epubCoverThumbnailBoundsAndDamagedFallback",
        "epubBooksAndTXTStayIsolated",
    ),
    "ReaderDomainTests/EPUBProgressTests.swift": (
        "epubPositionsRejectForeignVersionsUnitsAndInvalidUTF16Boundaries",
        "epubProgressRequiresReadinessAndIncreasingSequence",
        "epubOldNavigationSupersededSessionAndClosedCallbacksCannotWrite",
        "epubTypographyEpochRestoresSameTextPositionAndSettings",
    ),
    "ReaderDomainTests/EPUBCompatibilityTests.swift": (
        "epubCompatibilityStandardDoctypesPreserveAcceptedTextBytesAndNodes",
        "epubCompatibilityRejectsEntitiesUnknownDuplicateAndMisplacedDoctypes",
        "epubCompatibilityStaticSVGBecomesLocalJPEGAndPreservesIDs",
        "epubCompatibilityRejectsComplexActiveAndEscapingSVG",
        "epubCompatibilityImageOnlyPagesHaveStableAnchorButBlankPagesFail",
        "epubCompatibilityWebPRequiresRealBoundedSingleFrameDecode",
        "epubCompatibilityEPUB2DoctypeImageWebPImportProgressSurvivesReopen",
        "epubCompatibilityWebPResourcesStillEnforceSizeAndDigestIntegrity",
    ),
    "YueJingHostTests/EPUBReaderHostTests.swift": (
        "epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position",
        "epubSecurityRejectsScriptsFormsExternalResourcesAndKeepsIsolatedLocatorWorking",
        "epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks",
        "epubShelfCoverThumbnailDisplaysAndMissingOrDamagedCoversFallbackCleanly",
        "epubCompatibilityWebKitLoadsStaticImagePageAndRestoresAnchor",
    ),
}

DOMAIN_FILES = (
    "ReaderDomainTests/EPUBPackageTests.swift",
    "ReaderDomainTests/EPUBLibraryTests.swift",
    "ReaderDomainTests/EPUBProgressTests.swift",
    "ReaderDomainTests/EPUBCompatibilityTests.swift",
)
HOST_FILES = ("YueJingHostTests/EPUBReaderHostTests.swift",)

GROUP_SPECS = {
    "domain": {
        "group": "domain",
        "target": "ReaderDomainTests",
        "scheme": "ReaderDomain",
        "configuration": "Debug",
        "sdk": "iphonesimulator",
        "derived_data": "build/Task3Tests",
        "timeout_seconds": 1200,
        "case_timeout_seconds": None,
        "files": DOMAIN_FILES,
        "suites": (
            "ReaderDomainTests/EPUBPackageTests",
            "ReaderDomainTests/EPUBLibraryTests",
            "ReaderDomainTests/EPUBProgressTests",
            "ReaderDomainTests/EPUBCompatibilityTests",
        ),
        "expected_count": 28,
        "cases": tuple(name for f in DOMAIN_FILES for name in SELECTED_FILES[f]),
    },
    "host": {
        "group": "host",
        "target": "YueJingHostTests",
        "scheme": "YueJingUI",
        "configuration": "Debug",
        "sdk": "iphonesimulator",
        "derived_data": "build/ReadingUIDerivedData",
        "timeout_seconds": 480,
        "case_timeout_seconds": 180,
        "files": HOST_FILES,
        "suites": ("YueJingHostTests/EPUBReaderHostTests",),
        "expected_count": 5,
        "cases": tuple(name for f in HOST_FILES for name in SELECTED_FILES[f]),
    },
}

TOTAL_SELECTED = 33


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def digest_path(path):
    return digest_bytes(Path(path).read_bytes())


def git_blob_sha1(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()


def load_json(path):
    p = Path(path)
    require(p.is_file() and not p.is_symlink(), f"Missing or nonregular JSON file: {p}")
    value = json.loads(p.read_text(encoding="utf-8"))
    require(isinstance(value, dict), f"Expected JSON object in {p}")
    return value


def write_new(path, value):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


def write_new_text(path, text):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("x", encoding="utf-8") as stream:
        stream.write(text)


def git(*args, root=ROOT):
    return subprocess.check_output(["git", *args], cwd=root, timeout=120)


def git_tree(revision, root=ROOT):
    result = {}
    for row in git("ls-tree", "-r", "-z", revision, root=root).split(b"\0"):
        if row:
            metadata, name = row.split(b"\t", 1)
            result[name.decode("utf-8")] = metadata.decode("ascii").split()
    return result


def group_expected_names(group):
    require(group in GROUP_SPECS, f"Unknown EPUB compatibility group: {group!r}")
    return list(GROUP_SPECS[group]["cases"])


def validate_selected_cases(root=ROOT):
    reviewed = inventory.validate_source(root)
    require(
        reviewed["selected"] == inventory.TOTAL == 214,
        f"Expected full reviewed inventory of 214, got {reviewed.get('selected')}",
    )
    require(len(SELECTED_FILES) == 5, "Expected exactly 5 selected test files")
    all_names = []
    for rel_path, fixed_methods in SELECTED_FILES.items():
        expected = list(fixed_methods)
        require(expected and len(expected) == len(set(expected)), f"Invalid fixed methods for {rel_path}")
        require(rel_path in inventory.FILES, f"Selected file missing from inventory: {rel_path}")
        inv_methods = inventory.FILES[rel_path].split()
        require(inv_methods == expected, f"Inventory methods differ from fixed selection for {rel_path}")
        source_file = Path(root) / "Tests" / rel_path
        require(source_file.is_file() and not source_file.is_symlink(), f"Missing test source file: {rel_path}")
        src_methods = inventory.source_names(rel_path, source_file.read_text(encoding="utf-8"))
        require(src_methods == expected, f"Source declarations differ from fixed selection for {rel_path}")
        all_names.extend(expected)
    domain_cases = group_expected_names("domain")
    host_cases = group_expected_names("host")
    require(len(domain_cases) == 28 and len(set(domain_cases)) == 28, "Domain fixed case count must be 28")
    require(len(host_cases) == 5 and len(set(host_cases)) == 5, "Host fixed case count must be 5")
    require(
        len(all_names) == len(set(all_names)) == TOTAL_SELECTED
        and all_names == domain_cases + host_cases,
        "Selected 33 case union mismatch",
    )
    return {
        "total": TOTAL_SELECTED,
        "domain": len(domain_cases),
        "host": len(host_cases),
        "full_inventory": inventory.TOTAL,
        "files": {f"Tests/{k}": list(v) for k, v in SELECTED_FILES.items()},
    }


def validate_project_version(base_bytes, current_bytes):
    require(isinstance(base_bytes, bytes) and isinstance(current_bytes, bytes), "project.yml inputs must be bytes")
    require(base_bytes.count(OLD_VERSION_LINES) == 1, "Baseline project.yml lacks unique 0.2.0/build2 version lines")
    require(current_bytes.count(NEW_VERSION_LINES) == 1, "Candidate project.yml lacks unique 0.2.1/build3 version lines")
    expected_current = base_bytes.replace(OLD_VERSION_LINES, NEW_VERSION_LINES, 1)
    require(
        current_bytes == expected_current,
        "project.yml must differ from BASE only by MARKETING_VERSION 0.2.0->0.2.1 and CURRENT_PROJECT_VERSION 2->3",
    )


def validate_scope_boundaries(
    previous,
    current,
    base_project_bytes,
    current_project_bytes,
    *,
    env,
    head,
    is_ancestor=True,
    status=b"",
    worktree_blobs=None,
):
    require(isinstance(env, dict), "Environment must be a dict")
    require(
        env.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
        and env.get("GITHUB_RUN_ATTEMPT") == "1"
        and env.get("GITHUB_REF") == "refs/heads/main"
        and env.get("VALIDATION_SCOPE") == SCOPE,
        "Unapproved workflow event, ref, attempt, or validation_scope",
    )
    sha = env.get("GITHUB_SHA", "")
    run_id = str(env.get("GITHUB_RUN_ID", ""))
    require(
        isinstance(sha, str) and bool(re.fullmatch(r"[0-9a-f]{40}", sha)) and head == sha and sha != BASE,
        "Checkout HEAD/GITHUB_SHA mismatch or identical to BASE",
    )
    require(bool(re.fullmatch(r"[1-9][0-9]*", run_id)), "Invalid GITHUB_RUN_ID")
    require(is_ancestor is True, "BASE commit is not an ancestor of HEAD")
    status_bytes = status.encode("utf-8") if isinstance(status, str) else status
    require(isinstance(status_bytes, bytes) and not status_bytes.strip(), "Worktree is not clean committed state")
    require(isinstance(previous, dict) and isinstance(current, dict) and previous and current, "Invalid git tree")
    require(
        all(isinstance(v, list) and len(v) >= 3 and v[:2] == ["100644", "blob"] for v in current.values()),
        "Nonregular tracked input in HEAD",
    )
    deleted = set(previous) - set(current)
    require(not deleted, "Tracked baseline files deleted: " + repr(sorted(deleted)))
    missing_allowed = ALLOWED - set(current)
    require(not missing_allowed, "Approved whitelist files missing in HEAD: " + repr(sorted(missing_allowed)))
    changed = {p for p in set(previous) | set(current) if previous.get(p) != current.get(p)}
    require(changed, "No changes relative to BASE")
    require(changed <= ALLOWED, "Uncovered file changes outside 18-path whitelist: " + repr(sorted(changed - ALLOWED)))
    added = set(current) - set(previous)
    require(added == NEW_ALLOWED, "Added tracked paths must match exact 5 new whitelist files: " + repr(sorted(added ^ NEW_ALLOWED)))
    require("project.yml" in changed, "project.yml version update is required")
    validate_project_version(base_project_bytes, current_project_bytes)
    require(
        previous.get("project.yml", [None, None, None])[2] == git_blob_sha1(base_project_bytes),
        "Baseline project.yml blob SHA mismatch",
    )
    require(
        current.get("project.yml", [None, None, None])[2] == git_blob_sha1(current_project_bytes),
        "Current project.yml blob SHA mismatch",
    )
    if worktree_blobs is not None:
        require(set(worktree_blobs) == set(current), "Worktree file set differs from HEAD tree")
        for name, metadata in current.items():
            require(worktree_blobs.get(name) == metadata[2], "Worktree differs from committed blob: " + name)
    return {
        "scope": SCOPE,
        "baseline_commit": BASE,
        "source_commit": sha,
        "run_id": run_id,
        "run_attempt": "1",
        "version": EXPECTED_VERSION,
        "build": EXPECTED_BUILD,
        "changed_paths": sorted(changed),
        "added_paths": sorted(added),
        "allowed_paths": sorted(ALLOWED),
        "project_yml_sha256": digest_bytes(current_project_bytes),
        "baseline_project_yml_sha256": digest_bytes(base_project_bytes),
        "selected_total": TOTAL_SELECTED,
        "selected_groups": {"domain": 28, "host": 5},
        "selected_files": {k: list(v) for k, v in SELECTED_FILES.items()},
    }


def verify_scope(root=ROOT):
    validate_selected_cases(root)
    validator.check_candidate()
    head = git("rev-parse", "HEAD", root=root).decode("utf-8").strip()
    ancestor_proc = subprocess.run(
        ["git", "merge-base", "--is-ancestor", BASE, "HEAD"],
        cwd=root,
        capture_output=True,
        timeout=30,
    )
    is_ancestor = ancestor_proc.returncode == 0
    status = git("status", "--porcelain=v1", "--untracked-files=no", root=root)
    previous = git_tree(BASE, root=root)
    current = git_tree("HEAD", root=root)
    base_project = git("show", f"{BASE}:project.yml", root=root)
    project_path = Path(root) / "project.yml"
    require(project_path.is_file() and not project_path.is_symlink(), "Missing regular project.yml")
    current_project = project_path.read_bytes()
    worktree_blobs = {}
    for name in current:
        file_path = Path(root) / name
        require(file_path.is_file() and not file_path.is_symlink(), f"Nonregular worktree file: {name}")
        worktree_blobs[name] = git_blob_sha1(file_path.read_bytes())
    return validate_scope_boundaries(
        previous,
        current,
        base_project,
        current_project,
        env=dict(os.environ),
        head=head,
        is_ancestor=is_ancestor,
        status=status,
        worktree_blobs=worktree_blobs,
    )


def scope():
    receipt = verify_scope(ROOT)
    write_new(SCOPE_JSON, receipt)
    print(json.dumps(receipt, indent=2))
    return receipt


def expected_command(group, destination, result_bundle):
    require(group in GROUP_SPECS, f"Unknown EPUB compatibility group: {group!r}")
    require(
        isinstance(destination, str)
        and bool(re.fullmatch(r"platform=iOS Simulator,id=[0-9a-fA-F-]{36}", destination)),
        f"Invalid simulator destination: {destination!r}",
    )
    spec = GROUP_SPECS[group]
    only_testing = [f"-only-testing:{suite}" for suite in spec["suites"]]
    if group == "domain":
        return [
            "xcodebuild",
            "test",
            "-project",
            "YueJing.xcodeproj",
            "-scheme",
            "ReaderDomain",
            "-configuration",
            "Debug",
            "-sdk",
            "iphonesimulator",
            "-destination",
            destination,
            *only_testing,
            "-parallel-testing-enabled",
            "NO",
            "-clonedSourcePackagesDirPath",
            "build/SourcePackages",
            "-disableAutomaticPackageResolution",
            "-skipPackageUpdates",
            "-onlyUsePackageVersionsFromResolvedFile",
            "-derivedDataPath",
            "build/Task3Tests",
            "-resultBundlePath",
            str(result_bundle),
            "CODE_SIGNING_ALLOWED=NO",
            "ARCHS=arm64",
        ]
    return [
        "xcodebuild",
        "test",
        "-project",
        "YueJing.xcodeproj",
        "-scheme",
        "YueJingUI",
        "-configuration",
        "Debug",
        "-destination",
        destination,
        *only_testing,
        "-parallel-testing-enabled",
        "NO",
        "-clonedSourcePackagesDirPath",
        "build/SourcePackages",
        "-disableAutomaticPackageResolution",
        "-skipPackageUpdates",
        "-onlyUsePackageVersionsFromResolvedFile",
        "-derivedDataPath",
        "build/ReadingUIDerivedData",
        "-resultBundlePath",
        str(result_bundle),
        "-test-timeouts-enabled",
        "YES",
        "-default-test-execution-time-allowance",
        "180",
        "-maximum-test-execution-time-allowance",
        "180",
        "CODE_SIGNING_ALLOWED=NO",
        "ARCHS=arm64",
    ]


def validate_destination(destination, out=OUT):
    require(
        isinstance(destination, str)
        and bool(re.fullmatch(r"platform=iOS Simulator,id=[0-9a-fA-F-]{36}", destination)),
        f"Provide one installed simulator UUID; never a physical device: {destination!r}",
    )
    sim = load_json(Path(out) / "simulator-selection.json")
    udid = sim.get("udid")
    require(
        sim.get("physical_device") is False
        and sim.get("architecture") == "arm64"
        and isinstance(udid, str)
        and bool(re.fullmatch(r"[0-9a-fA-F-]{36}", udid))
        and isinstance(sim.get("device_name"), str)
        and sim["device_name"].startswith("iPhone"),
        "Simulator selection must be an arm64 non-physical iPhone simulator",
    )
    require(
        destination == f"platform=iOS Simulator,id={udid}",
        "Destination does not match selected simulator UDID in simulator-selection.json",
    )
    return sim


def validate_toolchain_and_dependencies(root=ROOT, out=OUT, *, check_live_tools=True):
    if check_live_tools:
        require(
            sys.platform == "darwin" and platform.machine() == "arm64" and shutil.which("xcodebuild"),
            "macOS arm64 and pinned Xcode toolchain are required",
        )
        xc_ver = subprocess.check_output(["xcodebuild", "-version"], text=True, timeout=30)
        sw_ver = subprocess.check_output(["xcrun", "swift", "--version"], text=True, timeout=30)
        require(
            "Xcode 16.4" in xc_ver and "16F6" in xc_ver and "Swift version 6.1.2" in sw_ver,
            "Live toolchain differs from pinned Xcode 16.4 (16F6) / Swift 6.1.2",
        )
    toolchain_log = Path(out) / "toolchain.log"
    xcodegen_log = Path(out) / "xcodegen.log"
    require(toolchain_log.is_file() and xcodegen_log.is_file(), "Missing toolchain.log or xcodegen.log")
    tool_text = toolchain_log.read_text(encoding="utf-8")
    require(
        all(token in tool_text for token in ("Xcode 16.4", "Build version 16F6", "Apple Swift version 6.1.2", "arm64")),
        "toolchain.log does not prove Xcode 16.4 (16F6) / Swift 6.1.2 / arm64",
    )
    require(
        xcodegen_log.read_text(encoding="utf-8").strip() == "Version: 2.46.0",
        "xcodegen.log does not prove XcodeGen 2.46.0",
    )
    resolved_path = Path(root) / "YueJing.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    require(resolved_path.is_file(), "Missing generated Package.resolved")
    pins = load_json(resolved_path).get("pins")
    packages = epub_batch.validate_checkouts(pins, Path(root))
    dep_receipt = load_json(Path(out) / "dependency-resolution.json")
    require(dep_receipt.get("packages") == packages, "dependency-resolution.json packages drift")
    return packages


def _validate_domain_effective_settings(values):
    require(isinstance(values, dict), "Missing ReaderDomainTests effective settings")
    require(
        values.get("PRODUCT_TYPE") == "com.apple.product-type.bundle.unit-test",
        "ReaderDomainTests must be a unit-test bundle",
    )
    require(
        not any(values.get(k) for k in ("TEST_HOST", "BUNDLE_LOADER", "TEST_TARGET_NAME")),
        "ReaderDomainTests must not use an application test host",
    )
    require(
        values.get("SWIFT_VERSION") == "6.0"
        and values.get("SWIFT_STRICT_CONCURRENCY") == "complete"
        and values.get("IPHONEOS_DEPLOYMENT_TARGET") == "16.6",
        "ReaderDomainTests language/concurrency/deployment settings mismatch",
    )


def _check_domain_scheme(root=ROOT):
    scheme = Path(root) / "YueJing.xcodeproj/xcshareddata/xcschemes/ReaderDomain.xcscheme"
    require(scheme.is_file() and not scheme.is_symlink(), "Missing ReaderDomain.xcscheme")
    xml = ET.parse(scheme).getroot()
    targets = {
        node.find("BuildableReference").get("BlueprintName")
        for node in xml.findall("./TestAction/Testables/TestableReference")
        if node.get("skipped") == "NO" and node.find("BuildableReference") is not None
    }
    require(targets == {"ReaderDomainTests"}, "ReaderDomain scheme testable target mismatch")
    return scheme


def prepare_group_settings(group, group_out, source_commit, *, root=ROOT, out=OUT):
    if group == "domain":
        scheme = _check_domain_scheme(root)
        eff_path = Path(out) / "effective-test-settings.json"
        if not eff_path.is_file():
            validator.settings()
        eff = load_json(eff_path)
        values = eff.get("ReaderDomainTests")
        _validate_domain_effective_settings(values)
        receipt = {
            "source_commit": source_commit,
            "target": "ReaderDomainTests",
            "scheme": "ReaderDomain",
            "scheme_sha256": digest_path(scheme),
            "effective_settings_sha256": digest_path(eff_path),
            "testables": ["ReaderDomainTests"],
            "settings": values,
        }
        write_new(Path(group_out) / "ReaderDomainTests-settings.json", receipt)
        return receipt
    if group == "host":
        ui.actual_settings("YueJingHostTests", Path(group_out), source_commit)
        return validate_group_settings("host", group_out, source_commit, root=root, out=out)
    raise ValueError(f"Unknown group: {group!r}")


def validate_group_settings(group, group_out, source_commit, *, root=ROOT, out=OUT):
    spec = GROUP_SPECS[group]
    target = spec["target"]
    settings_path = Path(group_out) / f"{target}-settings.json"
    receipt = load_json(settings_path)
    require(receipt.get("source_commit") == source_commit, f"Settings source_commit mismatch for {group}")
    if group == "domain":
        scheme = _check_domain_scheme(root)
        eff_path = Path(out) / "effective-test-settings.json"
        eff = load_json(eff_path)
        values = eff.get("ReaderDomainTests")
        _validate_domain_effective_settings(values)
        require(
            receipt.get("target") == "ReaderDomainTests"
            and receipt.get("scheme") == "ReaderDomain"
            and receipt.get("scheme_sha256") == digest_path(scheme)
            and receipt.get("effective_settings_sha256") == digest_path(eff_path)
            and receipt.get("testables") == ["ReaderDomainTests"]
            and receipt.get("settings") == values,
            "Domain settings receipt mismatch",
        )
        return receipt
    scheme = Path(root) / "YueJing.xcodeproj/xcshareddata/xcschemes/YueJingUI.xcscheme"
    require(scheme.is_file() and not scheme.is_symlink(), "Missing YueJingUI.xcscheme")
    require(
        receipt.get("scheme_sha256") == digest_path(scheme)
        and receipt.get("fixture_environment")
        and set(receipt.get("testables", ())) == set(ui.GROUPS),
        "Host scheme/testables/fixture_environment settings mismatch",
    )
    uuid.UUID(str(receipt["fixture_environment"]))
    targets = receipt.get("targets", {})
    app = targets.get("YueJing", {})
    test = targets.get("YueJingHostTests", {})
    require(
        all(
            v.get("SWIFT_VERSION") == "6.0"
            and v.get("SWIFT_STRICT_CONCURRENCY") == "complete"
            and v.get("IPHONEOS_DEPLOYMENT_TARGET") == "16.6"
            for v in (app, test)
        ),
        "Host language/concurrency/deployment settings mismatch",
    )
    require(
        app.get("PRODUCT_TYPE") == "com.apple.product-type.application"
        and "DEBUG" in app.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split(),
        "Host Debug App compilation condition missing",
    )
    test_host = Path(test.get("TEST_HOST", ""))
    require(
        test.get("PRODUCT_TYPE") == "com.apple.product-type.bundle.unit-test"
        and test_host.name == "YueJing"
        and test_host.parent.name == "YueJing.app"
        and test.get("BUNDLE_LOADER") == test.get("TEST_HOST"),
        "Host tests are not hosted by the real YueJing.app binary",
    )
    return receipt


def parse_group_log(group, raw_bytes, native_exit, timed_out):
    require(group in GROUP_SPECS, f"Unknown EPUB compatibility group: {group!r}")
    require(type(native_exit) is int and native_exit == 0, f"Native command failed with exit {native_exit!r} for {group}")
    require(timed_out is False, f"Native command timed out for {group}")
    require(isinstance(raw_bytes, (bytes, bytearray)) and len(raw_bytes) > 0, f"Empty raw log for {group}")
    raw = bytes(raw_bytes)
    text = raw.decode("utf-8")
    expected = group_expected_names(group)
    expected_count = GROUP_SPECS[group]["expected_count"]
    require(len(expected) == expected_count and len(set(expected)) == expected_count, f"Invalid fixed inventory for {group}")

    events = audit.parse_events(raw, expected, ui=False)
    require(events["parser_complete"] is True, f"Incomplete or impure event stream for {group}")
    require(not events["unexpected"], f"Unexpected test case events in {group}")
    require(not events["unknown_test_lines"], f"Unknown test lines in {group}")
    require(
        events["totals"]
        == {
            "passed": expected_count,
            "failed": 0,
            "skipped": 0,
            "unexecuted": 0,
            "unfinished": 0,
            "ambiguous": 0,
        },
        f"Event totals mismatch for {group}: {events['totals']}",
    )
    for case in events["cases"]:
        require(
            case["status"] == "passed"
            and len(case["starts"]) == 1
            and len(case["finishes"]) == 1
            and case["finishes"][0]["status"] == "passed"
            and case["starts"][0]["line"] < case["finishes"][0]["line"]
            and not case["skips"]
            and not case["issues"],
            f"Case event chain invalid for {group}:{case.get('name')}",
        )
    require(
        {c["name"] for c in events["cases"]} == set(expected),
        f"Event case set mismatch for {group}",
    )
    require(
        "** TEST SUCCEEDED **" in text and "** TEST FAILED **" not in text,
        f"Missing ** TEST SUCCEEDED ** marker in {group}",
    )
    require(
        not re.search(r"^.*\b(?:Test|Suite)[^\r\n]*\b(?:skipped|failed)\b", text, re.MULTILINE),
        f"Suite or Test failed/skipped line present in {group}",
    )
    require(
        not re.search(r"Test Case '-\[", text),
        f"Unexpected XCTest execution in {group}",
    )
    summaries = re.findall(r"Test run with (\d+) tests?\b[^\r\n]*?\b(passed|failed)\b", text)
    require(
        summaries == [(str(expected_count), "passed")],
        f"Expected unique Swift Testing summary ({expected_count}, 'passed') for {group}, got {summaries!r}",
    )
    passed = re.findall(r"\bTest (\w+)\(\) passed after\b", text)
    require(
        len(passed) == len(set(passed)) == expected_count and sorted(passed) == sorted(expected),
        f"Passed test list mismatch for {group}",
    )
    return {
        "group": group,
        "target": GROUP_SPECS[group]["target"],
        "expected": expected_count,
        "declared": expected,
        "passed": passed,
        "failed": 0,
        "skipped": 0,
        "unexecuted": 0,
        "unfinished": 0,
        "ambiguous": 0,
        "native_exit": native_exit,
        "timed_out": False,
        "native_summaries": [list(item) for item in summaries],
        "log_sha256": digest_bytes(raw),
        "events": events,
    }


def run_group(group, destination):
    require(group in GROUP_SPECS, f"Unknown EPUB compatibility group: {group!r}")
    scope_receipt = verify_scope(ROOT)
    require(load_json(SCOPE_JSON) == scope_receipt, "epub-compat-scope.json missing or differs from live scope")
    validator.check_candidate()
    validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=True)
    validate_destination(destination, OUT)

    spec = GROUP_SPECS[group]
    target = spec["target"]
    group_out = EPUB_OUT / group
    require(not group_out.exists(), f"Group evidence folder already exists (retries forbidden): {group_out}")
    group_out.mkdir(parents=True, exist_ok=False)

    files_before = validator.candidate_files()
    result_bundle = group_out / f"{target}.xcresult"
    args = expected_command(group, destination, result_bundle)
    provenance = {
        "scope": SCOPE,
        "group": group,
        "target": target,
        "source_commit": scope_receipt["source_commit"],
        "run_id": scope_receipt["run_id"],
        "run_attempt": scope_receipt["run_attempt"],
        "scheme": spec["scheme"],
        "configuration": spec["configuration"],
        "destination": destination,
        "suites": list(spec["suites"]),
        "expected": spec["expected_count"],
        "declared": list(spec["cases"]),
        "command": args,
        "timeout_seconds": spec["timeout_seconds"],
    }
    write_new(group_out / f"{target}-selection.json", provenance)
    write_new(
        group_out / f"{target}-source-hashes.json",
        {"source_commit": scope_receipt["source_commit"], "files": files_before},
    )
    prepare_group_settings(group, group_out, scope_receipt["source_commit"], root=ROOT, out=OUT)

    log_path = group_out / f"{target}.log"
    code, timed_out = ui.stream_native(args, log_path, spec["timeout_seconds"])
    write_new_text(group_out / f"{target}-exit-code.txt", f"{code}\n")
    write_new(
        group_out / f"{target}-execution.json",
        {**provenance, "native_exit": code, "timed_out": timed_out},
    )

    raw_bytes = log_path.read_bytes()
    parsed = parse_group_log(group, raw_bytes, code, timed_out)
    require(
        result_bundle.is_dir() and not result_bundle.is_symlink() and (result_bundle / "Info.plist").is_file(),
        f"Missing real xcresult bundle for {group}",
    )
    validator.check_candidate()
    require(validator.candidate_files() == files_before, f"Candidate sources changed during {group} execution")

    counts = {
        **provenance,
        "native_exit": code,
        "timed_out": False,
        "passed": parsed["passed"],
        "failed": 0,
        "skipped": 0,
        "unexecuted": 0,
        "unfinished": 0,
        "ambiguous": 0,
        "native_summaries": parsed["native_summaries"],
        "log_sha256": parsed["log_sha256"],
    }
    write_new(group_out / f"{target}-counts.json", counts)
    print(json.dumps(counts, indent=2))
    return counts


def validate_group_receipts(group, *, scope_receipt, expected_destination, candidate_files, root=ROOT, out=OUT):
    spec = GROUP_SPECS[group]
    target = spec["target"]
    group_out = Path(out) / "epub-compat" / group
    require(group_out.is_dir() and not group_out.is_symlink(), f"Missing group evidence directory: {group_out}")

    result_bundle = group_out / f"{target}.xcresult"
    require(
        result_bundle.is_dir() and not result_bundle.is_symlink() and (result_bundle / "Info.plist").is_file(),
        f"Missing or incomplete xcresult bundle for {group}: {result_bundle}",
    )

    selection_path = group_out / f"{target}-selection.json"
    execution_path = group_out / f"{target}-execution.json"
    counts_path = group_out / f"{target}-counts.json"
    settings_path = group_out / f"{target}-settings.json"
    sources_path = group_out / f"{target}-source-hashes.json"
    exit_path = group_out / f"{target}-exit-code.txt"
    log_path = group_out / f"{target}.log"

    selection = load_json(selection_path)
    execution = load_json(execution_path)
    counts = load_json(counts_path)
    sources = load_json(sources_path)
    validate_group_settings(group, group_out, scope_receipt["source_commit"], root=root, out=out)

    require(exit_path.is_file() and not exit_path.is_symlink(), f"Missing exit-code file for {group}")
    exit_code = int(exit_path.read_text(encoding="utf-8").strip())
    require(log_path.is_file() and not log_path.is_symlink(), f"Missing raw log for {group}")
    raw_log = log_path.read_bytes()

    want_cmd = expected_command(group, expected_destination, result_bundle)
    only_flags = [arg for arg in want_cmd if arg.startswith("-only-testing:")]
    require(
        only_flags == [f"-only-testing:{s}" for s in spec["suites"]]
        and not any(arg.startswith("-skip-testing") for arg in want_cmd),
        f"Invalid suite filter flags for {group}",
    )

    for label, record in (("selection", selection), ("execution", execution), ("counts", counts)):
        require(
            record.get("scope") == SCOPE
            and record.get("group") == group
            and record.get("target") == target
            and record.get("source_commit") == scope_receipt["source_commit"]
            and record.get("run_id") == scope_receipt["run_id"]
            and record.get("run_attempt") == "1"
            and record.get("scheme") == spec["scheme"]
            and record.get("configuration") == "Debug"
            and record.get("destination") == expected_destination
            and record.get("suites") == list(spec["suites"])
            and record.get("expected") == spec["expected_count"]
            and record.get("declared") == list(spec["cases"])
            and record.get("timeout_seconds") == spec["timeout_seconds"]
            and record.get("command") == want_cmd,
            f"Group {group} {label} provenance or command mismatch",
        )

    require(
        exit_code == 0
        and execution.get("native_exit") == 0
        and counts.get("native_exit") == 0
        and execution.get("timed_out") is False
        and counts.get("timed_out") is False,
        f"Group {group} native execution failed or timed out",
    )

    parsed = parse_group_log(group, raw_log, exit_code, execution["timed_out"])
    require(
        counts.get("log_sha256") == parsed["log_sha256"] == digest_bytes(raw_log),
        f"Group {group} log SHA256 mismatch",
    )
    require(
        counts.get("passed") == parsed["passed"]
        and len(counts["passed"]) == spec["expected_count"]
        and set(counts["passed"]) == set(spec["cases"])
        and all(counts.get(k) == 0 for k in ("failed", "skipped", "unexecuted", "unfinished", "ambiguous"))
        and counts.get("native_summaries") == parsed["native_summaries"],
        f"Group {group} counts receipt differs from recomputed raw log events",
    )
    require(
        sources.get("source_commit") == scope_receipt["source_commit"] and sources.get("files") == candidate_files,
        f"Group {group} source hashes drift",
    )

    return {
        "group": group,
        "target": target,
        "scheme": spec["scheme"],
        "configuration": "Debug",
        "destination": expected_destination,
        "suites": list(spec["suites"]),
        "expected": spec["expected_count"],
        "passed_count": len(parsed["passed"]),
        "passed": parsed["passed"],
        "failed": 0,
        "skipped": 0,
        "unexecuted": 0,
        "unfinished": 0,
        "ambiguous": 0,
        "native_exit": 0,
        "timed_out": False,
        "timeout_seconds": spec["timeout_seconds"],
        "command": want_cmd,
        "log_sha256": parsed["log_sha256"],
        "selection_sha256": digest_path(selection_path),
        "execution_sha256": digest_path(execution_path),
        "counts_sha256": digest_path(counts_path),
        "settings_sha256": digest_path(settings_path),
        "source_hashes_sha256": digest_path(sources_path),
        "xcresult": result_bundle.relative_to(root).as_posix(),
    }


def verify_gate():
    scope_receipt = verify_scope(ROOT)
    require(load_json(SCOPE_JSON) == scope_receipt, "Saved epub-compat-scope.json differs from live scope")
    validator.check_candidate()
    packages = validate_toolchain_and_dependencies(ROOT, OUT, check_live_tools=False)
    sim = load_json(OUT / "simulator-selection.json")
    expected_destination = f"platform=iOS Simulator,id={sim.get('udid', '')}"
    validate_destination(expected_destination, OUT)
    candidate_files = validator.candidate_files()

    domain_summary = validate_group_receipts(
        "domain",
        scope_receipt=scope_receipt,
        expected_destination=expected_destination,
        candidate_files=candidate_files,
        root=ROOT,
        out=OUT,
    )
    host_summary = validate_group_receipts(
        "host",
        scope_receipt=scope_receipt,
        expected_destination=expected_destination,
        candidate_files=candidate_files,
        root=ROOT,
        out=OUT,
    )

    combined_passed = domain_summary["passed"] + host_summary["passed"]
    expected_all = group_expected_names("domain") + group_expected_names("host")
    require(
        len(combined_passed) == len(set(combined_passed)) == TOTAL_SELECTED
        and sorted(combined_passed) == sorted(expected_all),
        "Combined 33 passed case identities mismatch",
    )

    return {
        "qualification": "EPUB_COMPAT_33_TARGETED_NATIVE",
        "scope": SCOPE,
        "coverage": "EPUB_TARGETED_NOT_FULL",
        "source_commit": scope_receipt["source_commit"],
        "baseline_commit": BASE,
        "run_id": scope_receipt["run_id"],
        "run_attempt": "1",
        "version": EXPECTED_VERSION,
        "build": EXPECTED_BUILD,
        "passed": True,
        "native_tests_executed_this_run": TOTAL_SELECTED,
        "verified_passed": TOTAL_SELECTED,
        "domain_passed": domain_summary["passed_count"],
        "host_passed": host_summary["passed_count"],
        "failed": 0,
        "skipped": 0,
        "unexecuted": 0,
        "unfinished": 0,
        "ambiguous": 0,
        "full_inventory_declared": inventory.TOTAL,
        "not_executed_this_run": inventory.TOTAL - TOTAL_SELECTED,
        "full_regression_executed_this_run": False,
        "historical_reference": {
            "native_205_run_id": "41843348986",
            "device_package_run_id": "41952767268",
            "status": "not_executed_this_run",
            "note": (
                "Historical runs are reference only; the remaining 181 cases in the 214 inventory "
                "were not executed in this run and are not claimed passed here."
            ),
        },
        "simulator": sim,
        "changed_paths": scope_receipt["changed_paths"],
        "scope_receipt_sha256": digest_path(SCOPE_JSON),
        "candidate_sources_sha256": digest_path(OUT / "candidate-sources.json"),
        "dependency_resolution_sha256": digest_path(OUT / "dependency-resolution.json"),
        "packages": packages,
        "groups": [domain_summary, host_summary],
    }


def gate():
    receipt = verify_gate()
    write_new(GATE_JSON, receipt)
    print(json.dumps(receipt, indent=2))
    return receipt


def validate_saved():
    require(GATE_JSON.is_file() and not GATE_JSON.is_symlink(), "Missing epub-compat-gate.json")
    saved = load_json(GATE_JSON)
    actual = verify_gate()
    require(saved == actual, "epub-compat-gate.json receipt drift or mismatch")
    return actual


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("scope", help="Verify git/worktree 18-file scope and write epub-compat-scope.json")
    run_parser = subparsers.add_parser("run", help="Run one targeted native group once")
    run_parser.add_argument("group", choices=("domain", "host"))
    run_parser.add_argument("--destination", required=True)
    subparsers.add_parser("gate", help="Reparse both targeted groups and write epub-compat-gate.json")
    args = parser.parse_args(argv)
    if args.command == "scope":
        scope()
    elif args.command == "run":
        run_group(args.group, args.destination)
    elif args.command == "gate":
        gate()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (
        ValueError,
        OSError,
        KeyError,
        TypeError,
        IndexError,
        ET.ParseError,
        subprocess.SubprocessError,
    ) as error:
        print("EPUB compatibility validation stopped: " + str(error), file=sys.stderr)
        sys.exit(1)

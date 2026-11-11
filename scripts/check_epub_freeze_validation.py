"""Offline, synthetic gate checks only: no build, dispatch, Swift or native acceptance."""
import argparse
import copy
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
from unittest.mock import patch
import zipfile

import run_epub_freeze_validation as r
import validate_task3 as v

checks = []


def rejects(label, action):
    try:
        action()
    except (ValueError, OSError, KeyError, zipfile.BadZipFile):
        checks.append(label)
    else:
        raise AssertionError('Expected rejection: ' + label)


def fixture_for(group, spec):
    text = ''
    for name in spec['cases']:
        if spec['kind'] == 'ui':
            text += f"Test Case '-[EPUBFlowUITests {name}]' started.\nTest Case '-[EPUBFlowUITests {name}]' passed (0.1 seconds).\n"
        else:
            param = r.inventory.PARAMETERIZED.get(name)
            signature = name + (param['signature'] if param else '()')
            text += f'◇ Test {signature} started.\n'
            if param:
                text += ''.join(f"◇ Passing 1 argument {param['argument']} → {value} to {signature}\n" for value in param['values'])
            text += f'✔ Test {signature} passed after 0.1 seconds.\n'
    if spec['kind'] == 'ui':
        text += 'Executed 1 test, with 0 failures (0 unexpected) in 0.1 seconds\n'
    else:
        text += f"✔ Test run with {len(spec['cases'])} tests passed after 0.2 seconds.\n"
    return (text + '** TEST SUCCEEDED **\n').encode('utf-8')


def fixture(group):
    return fixture_for(group, r.GROUPS[group])


def expected_executions(group, group_specs=r.GROUPS):
    return sum(len(r.inventory.PARAMETERIZED.get(name, {}).get('values', [None]))
               for name in group_specs[group]['cases'])


def _make_linkage_dir(folder, source_commit, run_id, binaries_payload=None):
    folder.mkdir(parents=True, exist_ok=True)
    data = b'synthetic macho payload' if binaries_payload is None else binaries_payload
    rel_ev = 'binaries/0/YueJing'
    ev_path = folder / rel_ev
    ev_path.parent.mkdir(parents=True, exist_ok=True)
    ev_path.write_bytes(data)
    (folder / 'nm-1.log').write_text('no overlay\n', encoding='utf-8')
    rec = dict(
        source_commit=source_commit,
        run_id=str(run_id),
        run_attempt='1',
        passed=True,
        errors=[],
        binaries=[dict(path='YueJing', evidence=rel_ev, passed=True, nm_exit=0,
                       bytes=len(data), sha256=hashlib.sha256(data).hexdigest())],
    )
    r.write(folder / 'verification.json', rec)
    return rec


def _make_settings_json(kind, target, group_folder, source_commit, eff_path):
    if kind == 'domain':
        eff = json.loads(eff_path.read_text(encoding='utf-8'))
        receipt = dict(
            source_commit=source_commit,
            target='ReaderDomainTests',
            scheme='ReaderDomain',
            scheme_sha256='1' * 64,
            effective_settings_sha256=r.sha(eff_path),
            testables=['ReaderDomainTests'],
            settings=eff['ReaderDomainTests'],
        )
    else:
        app_settings = dict(
            PRODUCT_TYPE='com.apple.product-type.application',
            SWIFT_VERSION='6.0',
            SWIFT_STRICT_CONCURRENCY='complete',
            IPHONEOS_DEPLOYMENT_TARGET='16.6',
            TEST_HOST='',
            BUNDLE_LOADER='',
            TEST_TARGET_NAME='',
            SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG',
        )
        if target == 'YueJingHostTests':
            test_settings = dict(
                PRODUCT_TYPE='com.apple.product-type.bundle.unit-test',
                SWIFT_VERSION='6.0',
                SWIFT_STRICT_CONCURRENCY='complete',
                IPHONEOS_DEPLOYMENT_TARGET='16.6',
                TEST_HOST='/synthetic/Debug-iphonesimulator/YueJing.app/YueJing',
                BUNDLE_LOADER='/synthetic/Debug-iphonesimulator/YueJing.app/YueJing',
                TEST_TARGET_NAME='',
                SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG',
            )
        else:
            test_settings = dict(
                PRODUCT_TYPE='com.apple.product-type.bundle.ui-testing',
                SWIFT_VERSION='6.0',
                SWIFT_STRICT_CONCURRENCY='complete',
                IPHONEOS_DEPLOYMENT_TARGET='16.6',
                TEST_HOST='',
                BUNDLE_LOADER='',
                TEST_TARGET_NAME='YueJing',
                SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG',
            )
        receipt = dict(
            source_commit=source_commit,
            targets={'YueJing': app_settings, target: test_settings},
            scheme_sha256='2' * 64,
            testables=['YueJingEPUBUITests', 'YueJingHostTests', 'YueJingUITests'],
            fixture_environment='D052AE4B-7823-447E-BE63-986028A7F54C',
        )
    r.write(group_folder / f'{target}-settings.json', receipt)


def _synthetic_packages():
    return {
        'grdb.swift': {
            'package': {
                'identity': 'grdb.swift',
                'kind': 'remoteSourceControl',
                'location': 'https://github.com/groue/GRDB.swift.git',
                'state': {'revision': '4de97e6903d29697caae1179cdef8479c64c2639', 'version': '7.0.0'},
            },
            'checkout_revision': '4de97e6903d29697caae1179cdef8479c64c2639',
            'package_manifest_sha256': '8140971be34f0cc80ef71e96a2b709ff98358a5c7412fe2e2a1687a4cb21867a',
        },
        'zipfoundation': {
            'package': {
                'identity': 'zipfoundation',
                'kind': 'remoteSourceControl',
                'location': 'https://github.com/weichsel/ZIPFoundation.git',
                'state': {'revision': '02b6abe5f6eef7e3cbd5f247c5cc24e246efcfe0', 'version': '0.9.19'},
            },
            'checkout_revision': '02b6abe5f6eef7e3cbd5f247c5cc24e246efcfe0',
            'package_manifest_sha256': '2dd90c2f70b1f3d17a4d73bd32ac97e5fc002eecd5797586edaf170def789fff',
        },
    }


def _write_common_run_files(root, source_commit, run_id, candidate_files_map):
    root.mkdir(parents=True, exist_ok=True)
    (root / 'toolchain.log').write_text(
        f'Source: {source_commit}\narm64\nXcode 16.4\nBuild version 16F6\nApple Swift version 6.1.2\n',
        encoding='utf-8',
    )
    (root / 'xcodegen.log').write_text('Version: 2.46.0\n', encoding='utf-8')
    (root / 'Package.resolved').write_text('{"pins": []}\n', encoding='utf-8')
    r.write(root / 'dependency-resolution.json', dict(packages=_synthetic_packages()))
    eff_path = root / 'effective-test-settings.json'
    r.write(eff_path, dict(ReaderDomainTests=dict(
        PRODUCT_TYPE='com.apple.product-type.bundle.unit-test',
        SWIFT_VERSION='6.0',
        SWIFT_STRICT_CONCURRENCY='complete',
        IPHONEOS_DEPLOYMENT_TARGET='16.6',
        TEST_HOST='',
        BUNDLE_LOADER='',
        TEST_TARGET_NAME='',
    )))
    r.write(root / 'candidate-sources.json', dict(
        source_commit=source_commit, run_id=str(run_id), run_attempt='1', files=candidate_files_map,
    ))
    return eff_path


def _zip_directory(src_dir, dest_zip):
    with zipfile.ZipFile(dest_zip, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(src_dir.rglob('*')):
            if path.is_file():
                zf.write(path, path.relative_to(src_dir).as_posix())


def _build_synthetic_historical_zip(work_dir, destination, result_tree, candidate_files_map):
    src = work_dir / 'hist-src'
    eff_path = _write_common_run_files(src, r.BASE, r.HIST_RUN, candidate_files_map)
    r.write(src / 'epub-freeze-scope.json', dict(
        scope=r.HIST_SCOPE, source_commit=r.BASE, run_id=str(r.HIST_RUN), run_attempt='1',
        version=r.VERSION, build=r.BUILD,
    ))
    udid = destination.split('id=')[1]
    r.write(src / 'simulator-selection.json', dict(
        device_name='iPhone SE (3rd generation)', udid=udid, runtime='iOS 18.5',
        runtime_version='18.5', sdk='18.5', architecture='arm64', physical_device=False,
    ))
    r.write(src / 'simulator-boot.json', dict(
        source_commit=r.BASE, run_id=str(r.HIST_RUN), run_attempt='1', exit_code=0, timed_out=False,
    ))
    _make_linkage_dir(src / 'webkit-simulator-linkage', r.BASE, r.HIST_RUN)
    freeze = src / 'epub-freeze'
    freeze.mkdir()
    for group, spec in r.HIST_GROUPS.items():
        folder = freeze / group
        folder.mkdir()
        target = spec['target']
        bundle = folder / (target + '.xcresult')
        (bundle / 'Data').mkdir(parents=True)
        (bundle / 'Info.plist').write_bytes(b'synthetic plist')
        (bundle / 'Data/data.0~synthetic').write_bytes(b'synthetic data')
        bundle_arg = f'/Users/runner/work/YueJing/YueJing/artifacts/task3/epub-freeze/{group}/{target}.xcresult'
        want_cmd = r.command_for_spec(spec, destination, bundle_arg)
        want = dict(scope=r.HIST_SCOPE, source_commit=r.BASE, run_id=str(r.HIST_RUN), run_attempt='1',
                    group=group, target=target, destination=destination, expected_cases=spec['cases'],
                    command=want_cmd, timeout_seconds=spec['timeout'], case_timeout_seconds=180)
        r.write(folder / 'selection.json', want)
        r.write(folder / 'execution.json', dict(**want, native_exit=0, timed_out=False))
        _make_settings_json(spec['kind'], target, folder, r.BASE, eff_path)
        raw_log = fixture_for(group, spec)
        (folder / (target + '.log')).write_bytes(raw_log)
        parsed = r.parse_log_for_spec(group, spec, raw_log, 0, False)
        if any(c in r.inventory.PARAMETERIZED for c in spec['cases']):
            raw_xc = json.dumps(result_tree).encode('utf-8')
            (folder / 'xcresult-tests.json').write_bytes(raw_xc)
            parsed['parameter_xcresult'] = dict(**r.parameter_result(result_tree), raw_sha256=r.compat.digest_bytes(raw_xc))
        else:
            parsed['parameter_xcresult'] = None
        r.write(folder / 'counts.json', parsed)
    # Include the two failed Round 1 groups inside the historical ZIP (they must NOT be reused).
    for bad_group, bad_target, bad_case in (
        ('host-3', 'YueJingHostTests', r.HOST_METHOD),
        ('ui-1', 'YueJingEPUBUITests', r.UI_METHOD),
    ):
        bad_dir = freeze / bad_group
        bad_dir.mkdir()
        (bad_dir / (bad_target + '.log')).write_bytes(b'failed case log\n** TEST FAILED **\n')
        r.write(bad_dir / 'failure.json', dict(group=bad_group, error='Native failure/timeout',
                                              source_commit=r.BASE, run_id=str(r.HIST_RUN)))
    zip_path = work_dir / 'hist.zip'
    _zip_directory(src, zip_path)
    hist_bytes = zip_path.stat().st_size
    hist_sha = r.sha(zip_path)
    run_meta = dict(
        id=r.HIST_RUN, head_sha=r.BASE, run_attempt=1, workflow_id=r.WORKFLOW_ID,
        path=r.WORKFLOW_PATH, event='workflow_dispatch', head_branch='main',
        status='completed', conclusion='failure',
        repository=dict(full_name=r.REPO), head_repository=dict(full_name=r.REPO),
    )
    artifact_meta = dict(
        id=r.HIST_ARTIFACT_ID, expired=False, name=r.HIST_ARTIFACT_NAME,
        workflow_run=dict(id=r.HIST_RUN, head_sha=r.BASE),
        size_in_bytes=hist_bytes, digest='sha256:' + hist_sha,
    )
    return zip_path, run_meta, artifact_meta


def _build_synthetic_prior_zip(work_dir, prior_id, prior_sha, destination, candidate_files_map,
                               hist_extracted_dir, *, failed_group=None,
                               prior_phase='validation', prior_prior='', prior_build_ipa=False,
                               prior_conclusion='success', include_event=True, include_hist=True,
                               include_gate=True, include_linkage=True):
    src = work_dir / f'prior-src-{prior_id}'
    eff_path = _write_common_run_files(src, prior_sha, prior_id, candidate_files_map)
    event_obj = dict(inputs=dict(
        validation_scope=r.SCOPE,
        allow_unqualified_ipa=False,
        build_ipa=prior_build_ipa,
        prior_validation_run=prior_prior,
    ))
    event_bytes = json.dumps(event_obj).encode('utf-8')
    if include_event:
        (src / 'dispatch-event.json').write_bytes(event_bytes)
    prior_scope = dict(
        scope=r.SCOPE,
        phase=prior_phase,
        prior_validation_run=prior_prior,
        source_commit=prior_sha,
        baseline_commit=r.BASE,
        run_id=str(prior_id),
        run_attempt='1',
        version=r.VERSION,
        build=r.BUILD,
        allow_unqualified_ipa=False,
        dispatch_event_sha256=hashlib.sha256(event_bytes).hexdigest(),
        build_ipa=prior_build_ipa,
        changed_paths=sorted(r.ALLOWED),
        selected={g: list(spec['cases']) for g, spec in r.GROUPS.items()},
        selected_declarations=r.TOTAL,
        native_tests_planned=r.EXECUTIONS,
        reused_historical_run_id=str(r.HIST_RUN),
        reused_historical_artifact_id=r.HIST_ARTIFACT_ID,
        reused_historical_declarations=r.REUSED_DECLARATIONS,
        reused_historical_executions=r.REUSED_EXECUTIONS,
        combined_target_declarations=r.COMBINED_TOTAL,
        combined_target_executions=r.COMBINED_EXECUTIONS,
        full_inventory_declared=236,
        full_inventory_executions=237,
        files=candidate_files_map,
        approved_files={p: candidate_files_map.get(p, '0' * 64) for p in sorted(r.ALLOWED)},
        physical_acceptance='not performed',
        full_regression_passed=False,
    )
    r.write(src / 'epub-freeze-scope.json', prior_scope)
    udid = destination.split('id=')[1]
    r.write(src / 'simulator-selection.json', dict(
        device_name='iPhone SE (3rd generation)', udid=udid, runtime='iOS 18.5',
        runtime_version='18.5', sdk='18.5', architecture='arm64', physical_device=False,
    ))
    r.write(src / 'simulator-boot.json', dict(
        source_commit=prior_sha, run_id=str(prior_id), run_attempt='1', exit_code=0, timed_out=False,
    ))
    if include_linkage:
        _make_linkage_dir(src / 'webkit-simulator-linkage', prior_sha, prior_id)
    freeze = src / 'epub-freeze'
    freeze.mkdir()
    groups_summary = []
    for group, spec in r.GROUPS.items():
        folder = freeze / group
        folder.mkdir()
        target = spec['target']
        bundle = folder / (target + '.xcresult')
        (bundle / 'Data').mkdir(parents=True)
        (bundle / 'Info.plist').write_bytes(b'synthetic plist')
        (bundle / 'Data/data.0~synthetic').write_bytes(b'synthetic data')
        bundle_arg = f'/Users/runner/work/YueJing/YueJing/artifacts/task3/epub-freeze/{group}/{target}.xcresult'
        want_cmd = r.command_for_spec(spec, destination, bundle_arg)
        want = dict(scope=r.SCOPE, source_commit=prior_sha, run_id=str(prior_id), run_attempt='1',
                    group=group, target=target, destination=destination, expected_cases=spec['cases'],
                    command=want_cmd, timeout_seconds=spec['timeout'], case_timeout_seconds=180)
        r.write(folder / 'selection.json', want)
        _make_settings_json(spec['kind'], target, folder, prior_sha, eff_path)
        if failed_group == group:
            r.write(folder / 'execution.json', dict(**want, native_exit=65, timed_out=False))
            (folder / (target + '.log')).write_bytes(fixture(group).replace(b'passed', b'failed').replace(b'TEST SUCCEEDED', b'TEST FAILED'))
            r.write(folder / 'failure.json', dict(group=group, error='Native failure/timeout',
                                                 source_commit=prior_sha, run_id=str(prior_id)))
        else:
            r.write(folder / 'execution.json', dict(**want, native_exit=0, timed_out=False))
            raw_log = fixture(group)
            (folder / (target + '.log')).write_bytes(raw_log)
            parsed = r.parse_log_for_spec(group, spec, raw_log, 0, False)
            parsed['parameter_xcresult'] = None
            r.write(folder / 'counts.json', parsed)
            groups_summary.append(parsed)
    r.write(src / 'case-results.json', dict(scope=r.SCOPE, phase='validation'))
    if include_hist:
        import shutil
        shutil.copytree(hist_extracted_dir, src / f'reused-evidence/historical-{r.HIST_RUN}')
    if include_gate and not failed_group:
        r.write(src / 'epub-freeze-gate.json', dict(
            **prior_scope,
            qualification=r.VALIDATION_QUALIFICATION,
            coverage='EPUB_TARGETED_NOT_FULL',
            native_tests_executed_this_run=r.EXECUTIONS,
            reused_native_passed=r.REUSED_EXECUTIONS,
            verified_passed=r.COMBINED_EXECUTIONS,
            combined_verified_passed=r.COMBINED_EXECUTIONS,
            verified_declarations=r.COMBINED_TOTAL,
            not_executed_this_run=237 - r.EXECUTIONS,
            unselected_executions=237 - r.COMBINED_EXECUTIONS,
            groups=groups_summary,
        ))
    zip_path = work_dir / f'prior-{prior_id}.zip'
    _zip_directory(src, zip_path)
    p_bytes = zip_path.stat().st_size
    p_sha = r.sha(zip_path)
    run_meta = dict(
        id=int(prior_id), head_sha=prior_sha, run_attempt=1, workflow_id=r.WORKFLOW_ID,
        path=r.WORKFLOW_PATH, event='workflow_dispatch', head_branch='main',
        status='completed', conclusion=prior_conclusion,
        repository=dict(full_name=r.REPO), head_repository=dict(full_name=r.REPO),
    )
    artifact_meta = dict(
        id=9900001, expired=False, name=f'task3-evidence-{prior_id}-{prior_sha}',
        workflow_run=dict(id=int(prior_id), head_sha=prior_sha),
        size_in_bytes=p_bytes, digest='sha256:' + p_sha,
    )
    return zip_path, run_meta, artifact_meta


def run_offline_checks():
    assert r.BASE == '1bf00449884f5fadf9d973a8d63220f9787b459d'
    assert r.SCOPE == 'epub-ready-followup-2'
    assert r.VERSION == '0.2.14' and r.BUILD == '16'
    assert r.VALIDATION_QUALIFICATION == 'EPUB_READY_FOLLOWUP_2_PLUS_REUSED_35_TARGETED_NATIVE'
    assert r.DELIVERY_QUALIFICATION == 'EPUB_READY_FOLLOWUP_DELIVERY_REUSED_37_TARGETED_NATIVE'
    assert r.HIST_RUN == 42954931349 and r.HIST_ARTIFACT_ID == 13827937675

    selected = r.selection()
    expected_selected_files = [
        ('YueJingHostTests/EPUBReaderHostTests.swift', [
            'epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks',
        ]),
        ('YueJingEPUBUITests/EPUBFlowUITests.swift', [
            'testEPUBShelfCoverAndDirectoryCrossChapterNavigation',
        ]),
    ]
    assert list(r.SELECTED_FILES.items()) == expected_selected_files
    expected_selected = {
        'host-1': ['epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks'],
        'ui-1': ['testEPUBShelfCoverAndDirectoryCrossChapterNavigation'],
    }
    assert selected == expected_selected and list(selected) == ['host-1', 'ui-1']
    assert list(r.GROUPS) == ['host-1', 'ui-1']
    assert len(selected) == r.TOTAL == 2 and r.EXECUTIONS == 2
    assert len(r.HIST_GROUPS) == r.REUSED_DECLARATIONS == 34
    assert sum(expected_executions(g, r.HIST_GROUPS) for g in r.HIST_GROUPS) == r.REUSED_EXECUTIONS == 35
    assert r.TOTAL + r.REUSED_DECLARATIONS == r.COMBINED_TOTAL == 36
    assert r.EXECUTIONS + r.REUSED_EXECUTIONS == r.COMBINED_EXECUTIONS == 37
    assert not (set(r.HIST_GROUPS) & r.FORBIDDEN_HIST_GROUPS)
    assert r.HIST_GROUPS['domain-11']['cases'] == ['epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime']
    assert expected_executions('domain-11', r.HIST_GROUPS) == 2

    release_groups = copy.deepcopy(r.GROUPS)
    parameter = next(iter(r.inventory.PARAMETERIZED))
    assert parameter == 'epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime'
    PARAM_GROUP = 'domain-11'

    expected_allowed = {
        '.github/workflows/task3-validate.yml',
        'Tests/YueJingEPUBUITests/EPUBFlowUITests.swift',
        'Tests/YueJingHostTests/EPUBReaderHostTests.swift',
        'docs/EPUB_FREEZE_RELEASE.md',
        'scripts/check_epub_freeze_validation.py',
        'scripts/run_epub_freeze_validation.py',
    }
    assert len(r.ALLOWED) == 6 and r.ALLOWED == expected_allowed and r.NEW == frozenset()
    project_text = (r.ROOT / 'project.yml').read_text(encoding='utf-8')
    assert 'MARKETING_VERSION: "' + r.VERSION + '"' in project_text and 'CURRENT_PROJECT_VERSION: "' + r.BUILD + '"' in project_text
    assert (r.ROOT / 'project.yml').read_bytes() == r.git('show', r.BASE + ':project.yml')

    reviewed = r.inventory.validate_source()
    assert json.loads(json.dumps(reviewed)) == reviewed
    assert reviewed['selected'] == 236 and reviewed['selected_executions'] == 237
    assert reviewed['selected'] - r.COMBINED_TOTAL == 200 and reviewed['selected_executions'] - r.COMBINED_EXECUTIONS == 200
    checks.append('candidate inventory survives JSON roundtrip')
    checks.append('exact current2 (host-1, ui-1) + historical34/35 (domain-11 Bool 2x) / inventory236 declarations, 237 expansions, 200 unselected, 13 unselected UI')

    # Real method-level isolation check on the actual local Swift test files against BASE.
    real_host_base = r.git('show', r.BASE + ':Tests/' + r.HOST_TEST_REL).decode('utf-8')
    real_host_cur = (r.ROOT / 'Tests' / r.HOST_TEST_REL).read_text(encoding='utf-8')
    real_ui_base = r.git('show', r.BASE + ':Tests/' + r.UI_TEST_REL).decode('utf-8')
    real_ui_cur = (r.ROOT / 'Tests' / r.UI_TEST_REL).read_text(encoding='utf-8')
    r.validate_test_method_isolation(real_host_base, real_host_cur, r.HOST_METHOD_DECL, kind='host')
    r.validate_test_method_isolation(real_ui_base, real_ui_cur, r.UI_METHOD_DECL, kind='ui')
    checks.append('real Host and UI test files differ only inside the two approved target methods and retain original assertions')
    # Swift method lexer negative/positive edge checks (comments, interpolations, multiline strings).
    swift_edge = (
        '@Test func edgeCase() {\n'
        '  /* nested /* } */ block comment */\n'
        '  let a = "hello \\(helper("}"))"\n'
        '  let b = """\n  { }\n  """\n'
        '  // }\n'
        '}\n'
        'let trailing = 1\n'
    )
    eo, ec = r.extract_swift_method_span(swift_edge, '@Test func edgeCase()')
    assert swift_edge[ec + 1:] == '\nlet trailing = 1\n' and swift_edge[eo] == '{' and swift_edge[ec] == '}'
    checks.append('swift method lexer handles nested comments, interpolations, and multiline strings')
    rejects('host edit before method rejected', lambda: r.validate_test_method_isolation(
        real_host_base, real_host_cur.replace('struct EPUBReaderHostTests', 'struct EPUBReaderHostTests_edited', 1),
        r.HOST_METHOD_DECL, kind='host'))
    rejects('host edit after method rejected', lambda: r.validate_test_method_isolation(
        real_host_base, real_host_cur.replace('verifyReopenDiagnostics', 'verifyReopenDiagnostics_edited', 1),
        r.HOST_METHOD_DECL, kind='host'))
    rejects('host weakened minimumNode rejected', lambda: r.validate_test_method_isolation(
        real_host_base, real_host_cur.replace('minimumNode: 6', 'minimumNode: 0', 1),
        r.HOST_METHOD_DECL, kind='host'))
    rejects('host removed rethrow rejected', lambda: r.validate_test_method_isolation(
        real_host_base, re.sub(r'\n\s*throw error(\n\s*\})', r'\1', real_host_cur, count=1),
        r.HOST_METHOD_DECL, kind='host'))
    rejects('host catch retry navigation rejected', lambda: r.validate_test_method_isolation(
        real_host_base, real_host_cur.replace('print("EPUB_SYNTHETIC_FRAGMENT_FAILURE', 'model.go(to: ch2MidItem)\nprint("EPUB_SYNTHETIC_FRAGMENT_FAILURE'),
        r.HOST_METHOD_DECL, kind='host'))
    rejects('ui edit after method rejected', lambda: r.validate_test_method_isolation(
        real_ui_base, real_ui_cur.replace('testEPUBProgressSurvivesExitAndProcessRelaunch()', 'testEPUBProgressSurvivesExitAndProcessRelaunch() /* drift */', 1),
        r.UI_METHOD_DECL, kind='ui'))
    rejects('ui edit before method rejected', lambda: r.validate_test_method_isolation(
        real_ui_base, real_ui_cur.replace('continueAfterFailure = false', 'continueAfterFailure = true', 1),
        r.UI_METHOD_DECL, kind='ui'))
    rejects('ui weakened exit check rejected', lambda: r.validate_test_method_isolation(
        real_ui_base, real_ui_cur.replace('!exit.exists || !exit.isHittable', '!exit.isHittable', 1),
        r.UI_METHOD_DECL, kind='ui'))

    destination = 'platform=iOS Simulator,id=11111111-2222-3333-4444-555555555555'
    # Test all 2 current groups AND all 34 historical groups for log parsing & command invariants.
    for group_label, specs_map in (('current', r.GROUPS), ('historical', r.HIST_GROUPS)):
        for group, spec in specs_map.items():
            raw = fixture_for(group, spec)
            parsed = r.parse_log_for_spec(group, spec, raw, 0, False)
            assert parsed['passed'] == spec['cases']
            assert parsed['executions'] == expected_executions(group, specs_map)
            tag = group_label + ':' + group
            checks.append(tag + ' valid synthetic events, not native execution')
            rejects(tag + ' nonzero exit', lambda g=group, s=spec, w=raw: r.parse_log_for_spec(g, s, w, 65, False))
            rejects(tag + ' bool exit', lambda g=group, s=spec, w=raw: r.parse_log_for_spec(g, s, w, False, False))
            rejects(tag + ' timeout', lambda g=group, s=spec, w=raw: r.parse_log_for_spec(g, s, w, 0, True))
            rejects(tag + ' missing success', lambda g=group, s=spec, w=raw: r.parse_log_for_spec(g, s, w.replace(b'** TEST SUCCEEDED **', b''), 0, False))
            rejects(tag + ' late pass', lambda g=group, s=spec, w=raw: r.parse_log_for_spec(g, s, w.replace(b'0.1 seconds', b'181.1 seconds'), 0, False))
            rejects(tag + ' duplicate events', lambda g=group, s=spec, w=raw: r.parse_log_for_spec(g, s, w + w, 0, False))
            rejects(tag + ' missing case', lambda g=group, s=spec, w=raw: r.parse_log_for_spec(g, s, w.replace(s['cases'][0].encode(), b'foreignCase'), 0, False))
            rejects(tag + ' failed despite green', lambda g=group, s=spec, w=raw: r.parse_log_for_spec(g, s, w + b'Test extra failed\n', 0, False))
            rejects(tag + ' skipped despite green', lambda g=group, s=spec, w=raw: r.parse_log_for_spec(g, s, w + b'Test extra skipped\n', 0, False))
            if spec['kind'] == 'ui':
                rejects(tag + ' wrong ui class', lambda g=group, s=spec, w=raw: r.parse_log_for_spec(g, s, w.replace(b'EPUBFlowUITests', b'ReadingFlowUITests'), 0, False))
                rejects(tag + ' ui executed 2 tests', lambda g=group, s=spec, w=raw: r.parse_log_for_spec(g, s, w.replace(b'Executed 1 test', b'Executed 2 tests'), 0, False))
                rejects(tag + ' ui failure summary', lambda g=group, s=spec, w=raw: r.parse_log_for_spec(g, s, w.replace(b'0 failures', b'1 failure'), 0, False))
                rejects(tag + ' ui skip summary', lambda g=group, s=spec, w=raw: r.parse_log_for_spec(g, s, w.replace(b'with 0 failures', b'1 tests skipped and with 0 failures'), 0, False))
                rejects(tag + ' ui unexpected swift test run', lambda g=group, s=spec, w=raw: r.parse_log_for_spec(g, s, w.replace(b'** TEST SUCCEEDED **', b'Test run with 1 tests passed after 0.1 seconds.\n** TEST SUCCEEDED **'), 0, False))
            cmd = r.command_for_spec(spec, destination, Path('synthetic.xcresult'))
            assert len([a for a in cmd if a.startswith('-only-testing:')]) == len(spec['cases'])
            expected_suffix = '/' + spec['cases'][0] + (
                '' if spec['kind'] == 'ui' else
                r.inventory.PARAMETERIZED.get(spec['cases'][0], {}).get('signature', '()'))
            assert any(a.endswith(expected_suffix) for a in cmd if a.startswith('-only-testing:'))
            assert cmd.count('180') == 2 and spec['timeout'] == 480
            assert cmd[cmd.index('-scheme') + 1] == ('ReaderDomain' if spec['kind'] == 'domain' else 'YueJingUI')

    rejects('device destination', lambda: r.command('host-1', 'generic/platform=iOS', Path('synthetic')))
    rejects('ui device destination', lambda: r.command('ui-1', 'generic/platform=iOS', Path('synthetic')))

    # Dedicated historical Bool parameterized fixture checks (domain-11).
    param_spec = r.HIST_GROUPS[PARAM_GROUP]
    raw_param = fixture_for(PARAM_GROUP, param_spec)
    arg_line = next(line for line in raw_param.splitlines(keepends=True) if b'Passing ' in line)
    decorated = raw_param.replace(arg_line, '\u200b'.encode('utf-8') + arg_line)
    assert r.parse_log_for_spec(PARAM_GROUP, param_spec, decorated, 0, False)['executions'] == 2
    for label, altered in [
        ('unknown argument decoration', raw_param.replace(arg_line, b'foreign ' + arg_line)),
        ('missing argument', raw_param.replace(arg_line, b'')),
        ('duplicate argument', raw_param.replace(arg_line, arg_line * 2)),
        ('foreign argument', raw_param.replace(b'false to ', b'unknown to ')),
        ('argument after finish', raw_param.replace(arg_line, b'') + arg_line),
        ('expanded count pretending declarations', raw_param.replace(b'1 tests passed', b'2 tests passed')),
    ]:
        rejects(PARAM_GROUP + ': ' + label, lambda g=PARAM_GROUP, s=param_spec, a=altered: r.parse_log_for_spec(g, s, a, 0, False))
    checks.append('Swift Testing line-leading zero-width decoration preserves argument identity')

    assert r.GROUPS == release_groups and r.selection() == selected
    with patch.dict(r.SELECTED_FILES, {'YueJingHostTests/EPUBReaderHostTests.swift': ['foreignCase']}):
        rejects('selection identity drift', r.selection)

    result_tree = {'testNodes': [{'name': parameter + '(symlink:)', 'result': 'Passed', 'children': [
        {'name': 'symlink: false', 'nodeType': 'Arguments', 'result': 'Passed'},
        {'name': 'symlink: true', 'nodeType': 'Arguments', 'result': 'Passed'}]}]}
    assert r.parameter_result(result_tree)['passed_arguments'] == ['false', 'true']
    checks.append('both parameter xcresult leaves required')
    for label, mutate in [
        ('missing parameter leaf', lambda x: x['testNodes'][0]['children'].pop()),
        ('duplicate parameter leaf', lambda x: x['testNodes'][0]['children'].append(x['testNodes'][0]['children'][0])),
        ('skipped parameter leaf', lambda x: x['testNodes'][0]['children'][0].update(result='Skipped')),
        ('failed parameter leaf', lambda x: x['testNodes'][0]['children'][0].update(result='Failed')),
        ('failed parameter parent', lambda x: x['testNodes'][0].update(result='Failed')),
        ('substring parameter impostor', lambda x: x['testNodes'][0].update(name='foreign' + parameter + '(symlink:)')),
        ('foreign parameter tree', lambda x: x['testNodes'][0].update(name='foreign')),
    ]:
        altered = copy.deepcopy(result_tree)
        mutate(altered)
        rejects(label, lambda a=altered: r.parameter_result(a))

    # Workflow routing & two-phase structure checks.
    workflow = (r.ROOT / '.github/workflows/task3-validate.yml').read_text(encoding='utf-8')
    job = workflow.split('\n  epub_freeze:\n')[1]
    assert 'default: ' + r.SCOPE in workflow
    assert "inputs.validation_scope != '" + r.SCOPE + "'" in workflow.split('\n  epub_freeze:\n')[0]
    assert "if: ${{ inputs.validation_scope == '" + r.SCOPE + "' }}" in job
    assert 'epub-recent-' not in workflow
    assert 'epub-ready-open-36' not in workflow
    assert 'epub-freeze-diagnostic' not in workflow and 'epub-freeze-3' not in workflow and 'epub-reopen-fast-10' not in workflow and 'epub-reopen-diagnostics-3' not in workflow
    assert 'check_epub_freeze_validation.py' in job and 'check_epub_ready_open.py' in job and 'check_epub_reopen_diagnostics.py' not in job
    assert 'run_epub_freeze_validation.py scope' in job
    assert 'run_epub_freeze_validation.py reuse' in job and 'GH_TOKEN: ${{ github.token }}' in job
    assert 'PRIOR_VALIDATION_RUN: ${{ inputs.prior_validation_run }}' in job
    assert 'timeout=120' in job and 'timeout_seconds=120' in job
    assert 'run-all' in job and 'for group in host-1' not in job and 'run domain' not in job
    assert 'Show every selected result and the complete UI inventory\n        if: always()' in job
    assert 'run_epub_freeze_validation.py report' in job
    assert job.index('run_epub_freeze_validation.py scope') < job.index('run_epub_freeze_validation.py reuse') < job.index('run-all') < job.index('run_epub_freeze_validation.py gate') < job.index('Compile actual unsigned') < job.index('package-gate-epub-freeze') < job.index('verify-ipa-epub-freeze')
    assert job.count('!cancelled() && inputs.build_ipa &&') == 2 and "BUILD_IPA: ${{ inputs.build_ipa && 'true' || 'false' }}" in job
    assert 'continue-on-error' not in job and 'Publish verified unsigned IPA' in job and 'if: success()' not in job
    try:
        import yaml as _yaml
    except ModuleNotFoundError:
        _yaml = None
    if _yaml is not None:
        _wf = _yaml.safe_load(workflow)
        _wf_on = _wf.get('on') or _wf.get(True)
        _wf_inputs = _wf_on['workflow_dispatch']['inputs']
        _wf_scope = _wf_inputs['validation_scope']
        assert _wf_scope['default'] == r.SCOPE and r.SCOPE in _wf_scope['options']
        assert _wf['jobs']['epub_freeze']['if'] == "${{ inputs.validation_scope == '" + r.SCOPE + "' }}"
        assert _wf['jobs']['epub_freeze']['timeout-minutes'] == 60
        assert _wf['jobs']['epub_freeze']['permissions'] == {'contents': 'read', 'actions': 'read'}
        assert _wf_inputs['allow_unqualified_ipa']['default'] is False
        assert _wf_inputs['build_ipa']['default'] is False
        assert _wf_inputs['prior_validation_run']['default'] == '' and _wf_inputs['prior_validation_run']['type'] == 'string'
    checks.append('exclusive scope routing / two-phase workflow / independent reuse & device build / strict gates separated')

    # Scope boundary & 6-path isolation checks.
    base_project = r.git('show', r.BASE + ':project.yml')
    old = {p: ['100644', 'blob', '1' * 40] for p in r.ALLOWED}
    old['Sources/ReaderDomain/untouched.swift'] = ['100644', 'blob', '3' * 40]
    old['project.yml'] = ['100644', 'blob', '5' * 40]
    current = {**old, **{p: ['100644', 'blob', '2' * 40] for p in r.ALLOWED}}
    head = 'a' * 40
    candidate_map = v.candidate_files()
    base_env = dict(
        VALIDATION_SCOPE=r.SCOPE, GITHUB_EVENT_NAME='workflow_dispatch', GITHUB_REF='refs/heads/main',
        GITHUB_RUN_ATTEMPT='1', GITHUB_REPOSITORY=r.REPO, GITHUB_SHA=head, GITHUB_RUN_ID='12345',
        ALLOW_UNQUALIFIED_IPA='false',
    )

    with tempfile.TemporaryDirectory(prefix='epub-scope-check-', dir=os.environ.get('PI_SCRATCH_DIR')) as tmp:
        ev_val = Path(tmp) / 'val-event.json'
        ev_val.write_text(json.dumps(dict(inputs=dict(
            validation_scope=r.SCOPE, allow_unqualified_ipa=False, build_ipa=False, prior_validation_run='',
        ))), encoding='utf-8')
        ev_del = Path(tmp) / 'del-event.json'
        ev_del.write_text(json.dumps(dict(inputs=dict(
            validation_scope=r.SCOPE, allow_unqualified_ipa=False, build_ipa=True, prior_validation_run='987654',
        ))), encoding='utf-8')
        val_env = {**base_env, 'GITHUB_EVENT_PATH': str(ev_val), 'BUILD_IPA': 'false', 'PRIOR_VALIDATION_RUN': ''}
        del_env = {**base_env, 'GITHUB_EVENT_PATH': str(ev_del), 'BUILD_IPA': 'true', 'PRIOR_VALIDATION_RUN': '987654'}

        def fakegit(*args):
            if args == ('rev-parse', 'HEAD'):
                return head.encode()
            if args[0] in ('merge-base', 'status'):
                return b''
            if args == ('show', r.BASE + ':project.yml'):
                return base_project
            if args == ('show', r.BASE + ':Tests/' + r.HOST_TEST_REL):
                return real_host_base.encode('utf-8')
            if args == ('show', r.BASE + ':Tests/' + r.UI_TEST_REL):
                return real_ui_base.encode('utf-8')
            raise AssertionError(args)

        with patch.object(r, 'git', side_effect=fakegit), \
             patch.object(r, 'tree', side_effect=lambda rev: old if rev == r.BASE else current):
            with patch.dict(os.environ, val_env):
                val_receipt = r.scope_receipt()
                assert val_receipt['phase'] == 'validation' and val_receipt['prior_validation_run'] == ''
                assert val_receipt['build_ipa'] is False and val_receipt['native_tests_planned'] == 2
                assert val_receipt['selected_declarations'] == 2 and val_receipt['reused_historical_executions'] == 35
                assert val_receipt['combined_target_declarations'] == 36 and val_receipt['combined_target_executions'] == 37
                assert val_receipt['full_inventory_declared'] == 236 and val_receipt['full_inventory_executions'] == 237
                assert val_receipt['version'] == '0.2.14' and val_receipt['build'] == '16'
                assert val_receipt['baseline_commit'] == r.BASE
                assert 'verified_passed' not in val_receipt
                checks.append('validation scope binds exact6 paths, empty NEW, byte-identical project.yml, and makes no pass claim')
            with patch.dict(os.environ, del_env):
                receipt = r.scope_receipt()
                assert receipt['phase'] == 'delivery' and receipt['prior_validation_run'] == '987654'
                assert receipt['build_ipa'] is True and receipt['native_tests_planned'] == 0
                checks.append('delivery scope binds prior_validation_run, build_ipa=true, and plans 0 native executions')
            with patch.dict(os.environ, val_env):
                for key, value in [
                    ('VALIDATION_SCOPE', 'full'), ('VALIDATION_SCOPE', r.DIAGNOSTIC_SCOPE),
                    ('GITHUB_SHA', 'b' * 40), ('GITHUB_RUN_ATTEMPT', '2'),
                    ('GITHUB_REPOSITORY', 'foreign/repo'), ('GITHUB_REF', 'refs/heads/other'),
                    ('PRIOR_VALIDATION_RUN', '987654'),
                ]:
                    with patch.dict(os.environ, {key: value}):
                        rejects('foreign ' + key + '=' + value, r.scope_receipt)
                current['foreign.swift'] = ['100644', 'blob', '2' * 40]
                rejects('unapproved added path', r.scope_receipt)
                del current['foreign.swift']
                current['Sources/ReaderDomain/untouched.swift'] = ['100644', 'blob', '4' * 40]
                rejects('unapproved product drift', r.scope_receipt)
                current['Sources/ReaderDomain/untouched.swift'] = old['Sources/ReaderDomain/untouched.swift']
                current['project.yml'] = ['100644', 'blob', '6' * 40]
                rejects('project.yml drift rejected', r.scope_receipt)
                current['project.yml'] = old['project.yml']
                current['docs/EPUB_FREEZE_RELEASE.md'] = old['docs/EPUB_FREEZE_RELEASE.md']
                rejects('missing required path change', r.scope_receipt)
                current['docs/EPUB_FREEZE_RELEASE.md'] = ['120000', 'blob', '2' * 40]
                rejects('symlink candidate', r.scope_receipt)
                current['docs/EPUB_FREEZE_RELEASE.md'] = ['100644', 'blob', '2' * 40]
                with patch.object(r, 'git', side_effect=lambda *a: b'changed: true\n' if a == ('show', r.BASE + ':project.yml') else fakegit(*a)):
                    rejects('project.yml byte mismatch rejected', r.scope_receipt)

    ui_fixture = 'func testEPUBShelfCoverAndDirectoryCrossChapterNavigation() { exitReader(app, x); openEPUB(x) } func testEPUBProgressSurvivesExitAndProcessRelaunch()'
    r.ui_reopen_contract(ui_fixture)
    rejects('UI coverage cannot silently omit reopen', lambda: r.ui_reopen_contract(ui_fixture.replace('openEPUB(x)', '')))
    rejects('process relaunch cannot substitute warm reopen', lambda: r.ui_reopen_contract(ui_fixture.replace('openEPUB(x)', 'app.terminate(); openEPUB(x)')))
    blockers = []
    try:
        r.ui_reopen_contract(real_ui_cur)
    except ValueError as error:
        blockers.append(str(error))

    # Synthetic historical35 reuse, validation gate, prior delivery reuse, delivery gate & IPA checks.
    with tempfile.TemporaryDirectory(prefix='epub-followup-selfcheck-', dir=os.environ.get('PI_SCRATCH_DIR')) as temp:
        work = Path(temp)
        hist_zip, hist_run, hist_artifact = _build_synthetic_historical_zip(work, destination, result_tree, candidate_map)
        hist_run_json = work / 'hist-run.json'
        hist_art_json = work / 'hist-art.json'
        r.write(hist_run_json, hist_run)
        r.write(hist_art_json, dict(total_count=1, artifacts=[hist_artifact]))

        out_val = work / 'out-val'
        native_val = out_val / 'epub-freeze'
        out_val.mkdir()
        native_val.mkdir()
        r.write(out_val / 'dependency-resolution.json', dict(packages=_synthetic_packages()))
        (out_val / 'simulator-selection.json').write_text(json.dumps(dict(
            udid=destination.split('id=')[1], physical_device=False, architecture='arm64', device_name='iPhone SE (3rd generation)',
        )), encoding='utf-8')
        sim_app = work / 'build/ReadingUIDerivedData/Build/Products/Debug-iphonesimulator/YueJing.app'
        sim_app.mkdir(parents=True)
        (sim_app / 'YueJing').write_bytes(b'synthetic macho payload')
        _make_linkage_dir(out_val / 'webkit-simulator-linkage', head, val_receipt['run_id'])
        r.write(out_val / 'epub-freeze-scope.json', val_receipt)
        with patch.object(r, 'ROOT', work), patch.object(r, 'OUT', out_val), patch.object(r, 'NATIVE_OUT', native_val), \
             patch.object(r, 'SCOPE_JSON', out_val / 'epub-freeze-scope.json'), \
             patch.object(r, 'REUSED_OUT', out_val / 'reused-evidence'), \
             patch.object(r, 'REUSED_GATE_JSON', out_val / 'reused-evidence/reused-evidence-gate.json'), \
             patch.object(r, 'GATE_JSON', out_val / 'gate.json'), \
             patch.object(r, 'live_scope', return_value=val_receipt), \
             patch.object(r, 'HIST_ARCHIVE_BYTES', hist_artifact['size_in_bytes']), \
             patch.object(r, 'HIST_ARCHIVE_SHA256', hist_artifact['digest'].split(':', 1)[1]), \
             patch.object(r.compat, 'validate_toolchain_and_dependencies', return_value=_synthetic_packages()), \
             patch.object(r.compat, 'validate_destination'), \
             patch.object(r.reading, 'validate_group_settings'), \
             patch.object(r.paging, 'require_xcresult'), \
             patch.object(r.subprocess, 'check_output', return_value=json.dumps(result_tree).encode()):
            reused_val = r.reuse_evidence(
                offline_historical=dict(zip_path=hist_zip, run_json=hist_run_json, artifact_json=hist_art_json),
                verify_live_bundle=False,
            )
            assert reused_val['passed'] is True and reused_val['reused_native_passed'] == 35
            assert reused_val['historical']['workflow_conclusion'] == 'failure'
            assert not (out_val / 'reused-evidence/historical-42954931349/evidence/epub-freeze/host-3').exists()
            assert not (out_val / 'reused-evidence/historical-42954931349/evidence/epub-freeze/ui-1').exists()
            assert not any((out_val / 'reused-evidence').rglob('data.0~*'))
            checks.append('historical35 reuse accepts Round 1 workflow failure for 34/35 passing cases, drops heavy Data/, excludes host-3/ui-1')

            for group, spec in r.GROUPS.items():
                folder = native_val / group
                folder.mkdir()
                bundle = folder / (spec['target'] + '.xcresult')
                want = r.provenance(group, destination, bundle, val_receipt)
                r.write(folder / 'selection.json', want)
                r.write(folder / 'execution.json', dict(**want, native_exit=0, timed_out=False))
                (folder / (spec['target'] + '.log')).write_bytes(fixture(group))
                parsed = r.parse_log(group, fixture(group), 0, False)
                parsed['parameter_xcresult'] = r.parameter_evidence(group, folder, bundle, export=True)
                r.write(folder / 'counts.json', parsed)
            qualified = r.qualification()
            r.write(out_val / 'gate.json', qualified)
            qualified_gate = r.release_gate()
            assert qualified_gate['verified_passed'] == 37 and qualified_gate['combined_verified_passed'] == 37
            assert qualified_gate['verified_declarations'] == 36
            assert qualified_gate['native_tests_executed_this_run'] == 2
            assert qualified_gate['reused_native_passed'] == 35
            assert qualified_gate['not_executed_this_run'] == 235
            assert qualified_gate['qualification'] == r.VALIDATION_QUALIFICATION
            val_summary = r.summarize()
            assert val_summary['native_tests_executed_this_run'] == 2
            assert val_summary['reused_native_passed'] == 35
            assert val_summary['combined_verified_passed'] == 37
            assert len(val_summary['ui_inventory']) == 15
            assert sum(x['status'] == 'passed' for x in val_summary['ui_inventory']) == 1
            assert sum(x['status'] == 'reused_historical' for x in val_summary['ui_inventory']) == 1
            assert sum(x['status'] == 'not_selected' for x in val_summary['ui_inventory']) == 13
            checks.append('validation phase combined2+35 gate & 15 UI inventory verified')

            # Negative tests on validation phase current2 + historical35.
            for failure_path in (native_val / 'host-1/failure.json', native_val / 'ui-1/failure.json', out_val / 'case-scheduling-error.json'):
                r.write(failure_path, dict(error='synthetic failure after passing receipt'))
                rejects('failure record overrides green receipts: ' + failure_path.name, r.release_gate)
                failure_path.unlink()
            broken = native_val / 'host-1/counts.json'
            prev_bytes = broken.read_bytes()
            broken.write_bytes(b'{invalid')
            bad_sum = r.summarize()
            assert bad_sum['counts']['error'] == 1 and bad_sum['counts']['passed'] == 1
            assert bad_sum['native_tests_executed_this_run'] is None and bad_sum['combined_verified_passed'] is None
            assert len(bad_sum['ui_inventory']) == 15
            broken.write_bytes(prev_bytes)
            checks.append('corrupt current result yields null counts without hiding remaining UI cases')

            for target_group, filename, field, value in [
                ('host-1', 'selection.json', 'source_commit', 'b' * 40),
                ('host-1', 'execution.json', 'timed_out', True),
                ('host-1', 'execution.json', 'run_id', '999'),
                ('host-1', 'counts.json', 'executions', 18),
                ('ui-1', 'execution.json', 'timed_out', True),
                ('ui-1', 'counts.json', 'executions', 2),
            ]:
                p = native_val / target_group / filename
                orig = p.read_bytes()
                data = json.loads(orig)
                data[field] = value
                p.write_text(json.dumps(data), encoding='utf-8')
                rejects('current drift ' + target_group + '/' + filename + ':' + field, r.release_gate)
                p.write_bytes(orig)

            # Tampered retained historical file / domain-11 xcresult leaf / forbidden host-3/ui-1 / shared source drift.
            hist_dom11_xc = out_val / f'reused-evidence/historical-{r.HIST_RUN}/evidence/epub-freeze/domain-11/xcresult-tests.json'
            orig_dom11 = hist_dom11_xc.read_bytes()
            tampered_dom11 = json.loads(orig_dom11)
            tampered_dom11['testNodes'][0]['children'].pop()
            hist_dom11_xc.write_text(json.dumps(tampered_dom11), encoding='utf-8')
            rejects('historical domain-11 missing Bool leaf rejected', r.release_gate)
            hist_dom11_xc.write_bytes(orig_dom11)

            hist_log = out_val / f'reused-evidence/historical-{r.HIST_RUN}/evidence/epub-freeze/domain-1/ReaderDomainTests.log'
            orig_log = hist_log.read_bytes()
            hist_log.write_bytes(orig_log + b'\n')
            rejects('tampered historical log rejected', r.release_gate)
            hist_log.write_bytes(orig_log)

            bad_hist_group = out_val / f'reused-evidence/historical-{r.HIST_RUN}/evidence/epub-freeze/host-3'
            bad_hist_group.mkdir()
            rejects('reused forbidden host-3 rejected', r.release_gate)
            bad_hist_group.rmdir()

            cs_path = out_val / f'reused-evidence/historical-{r.HIST_RUN}/evidence/candidate-sources.json'
            orig_cs = cs_path.read_bytes()
            cs_data = json.loads(orig_cs)
            shared_key = next(k for k in cs_data['files'] if k not in r.ALLOWED)
            cs_data['files'][shared_key] = 'f' * 64
            cs_path.write_text(json.dumps(cs_data), encoding='utf-8')
            rejects('shared source drift vs historical baseline rejected', lambda: r.verify_historical_evidence(out_val / f'reused-evidence/historical-{r.HIST_RUN}'))
            cs_path.write_bytes(orig_cs)

            with patch.object(r.paging, 'require_xcresult', side_effect=ValueError('missing bundle')):
                rejects('missing xcresult bundle', r.release_gate)
            (native_val / 'extra').mkdir()
            rejects('extra native group', r.release_gate)
            (native_val / 'extra').rmdir()
            bin_ev = out_val / 'webkit-simulator-linkage/binaries/0/YueJing'
            orig_bin = bin_ev.read_bytes()
            bin_ev.write_bytes(b'drift')
            rejects('tampered simulator linkage rejected', r.release_gate)
            bin_ev.write_bytes(orig_bin)
            (sim_app / 'YueJing').write_bytes(b'changed sim app')
            rejects('tampered simulator app rejected', r.release_gate)
            (sim_app / 'YueJing').write_bytes(orig_bin)
            checks.append('strict validation gate rejects missing/tampered current2, historical35, Bool leaf, shared source, and linkage')

        # Historical API & ZIP negative tests.
        for field, val in [
            ('id', 1), ('head_sha', 'f' * 40), ('run_attempt', 2), ('workflow_id', 1),
            ('path', '.github/workflows/other.yml'), ('event', 'push'), ('head_branch', 'other'),
            ('status', 'in_progress'), ('conclusion', 'cancelled'),
            ('repository', {'full_name': 'foreign/repo'}),
        ]:
            rejects('historical run ' + field, lambda f=field, v_=val: r.validate_historical_run_and_artifact({**hist_run, f: v_}, hist_artifact))
        for field, val in [
            ('id', 1), ('expired', True), ('name', 'wrong'), ('size_in_bytes', 1),
            ('digest', 'sha256:' + '0' * 64), ('workflow_run', dict(id=1, head_sha=r.BASE)),
        ]:
            rejects('historical artifact ' + field, lambda f=field, v_=val: r.validate_historical_run_and_artifact(hist_run, {**hist_artifact, f: v_}))

        hostile_seq = [0]
        def build_hostile_zip(names, mode=0o100644, *, encrypt=False, corrupt_crc=False, spoof_size=False):
            hostile_seq[0] += 1
            zpath = work / f'hostile-{hostile_seq[0]}.zip'
            with zipfile.ZipFile(zpath, 'w') as zf:
                for n in names:
                    info = zipfile.ZipInfo(n)
                    info.filename = n
                    info.external_attr = mode << 16
                    zf.writestr(info, b'evidence')
            raw_z = bytearray(zpath.read_bytes())
            if corrupt_crc:
                cd = raw_z.find(b'PK\x01\x02')
                raw_z[cd + 16] ^= 0xFF
            if encrypt:
                lfh = raw_z.find(b'PK\x03\x04')
                cd = raw_z.find(b'PK\x01\x02')
                raw_z[lfh + 6] |= 1
                raw_z[cd + 8] |= 1
            if spoof_size:
                cd = raw_z.find(b'PK\x01\x02')
                raw_z[cd + 24] ^= 1
            zpath.write_bytes(bytes(raw_z))
            return zpath

        for bad_names in (['../escape'], ['/abs'], ['a\\b'], ['C:/x'], ['a/./b'], ['a//b'], ['a', 'A']):
            rejects('unsafe ZIP member ' + repr(bad_names), lambda bn=bad_names: r.safe_zip_members(build_hostile_zip(bn)))
        rejects('ZIP symlink entry', lambda: r.safe_zip_members(build_hostile_zip(['link'], stat.S_IFLNK | 0o777)))
        rejects('ZIP encrypted entry', lambda: r.safe_zip_members(build_hostile_zip(['enc.txt'], encrypt=True)))
        rejects('ZIP CRC corruption', lambda: r.safe_zip_members(build_hostile_zip(['crc.txt'], corrupt_crc=True)))
        rejects('ZIP spoofed size', lambda: r.safe_zip_members(build_hostile_zip(['sz.txt'], spoof_size=True)))
        checks.append('historical API provenance and ZIP security/CRC/NFC/symlink/size checks enforced')

        # Build delivery phase tests reusing the historical evidence extracted above.
        hist_extracted = out_val / f'reused-evidence/historical-{r.HIST_RUN}'
        prior_id = '987654'
        prior_zip, prior_run, prior_artifact = _build_synthetic_prior_zip(
            work, prior_id, head, destination, candidate_map, hist_extracted,
        )
        prior_run_json = work / 'prior-run.json'
        prior_art_json = work / 'prior-art.json'
        r.write(prior_run_json, prior_run)
        r.write(prior_art_json, dict(total_count=1, artifacts=[prior_artifact]))

        out_del = work / 'out-del'
        out_del.mkdir()
        r.write(out_del / 'dependency-resolution.json', dict(packages=_synthetic_packages()))
        (out_del / 'toolchain.log').write_text('Xcode 16.4\n', encoding='utf-8')
        (out_del / 'xcodegen.log').write_text('Version: 2.46.0\n', encoding='utf-8')
        (out_del / 'app-build.log').write_text('BUILD SUCCEEDED\n', encoding='utf-8')
        (out_del / 'app-build-exit-code.txt').write_text('0\n', encoding='utf-8')
        r.write(out_del / 'epub-freeze-scope.json', receipt)
        app = work / 'YueJing.app'
        app.mkdir()
        (app / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString=r.VERSION, CFBundleVersion=r.BUILD)))
        (app / 'Assets.car').write_bytes(b'synthetic icon')
        (app / 'YueJing').write_bytes(b'synthetic device image')
        _make_linkage_dir(out_del / 'webkit-device-linkage', head, receipt['run_id'], binaries_payload=b'synthetic device image')
        r.write(out_del / 'app-dependency-gate.json', dict(
            source_commit=head, run_id=receipt['run_id'], run_attempt='1', signing='unsigned',
            actual_images=[dict(binary='YueJing', sha256=r.sha(app / 'YueJing'))],
        ))
        artifacts = work / 'artifacts'
        artifacts.mkdir()
        ipa = artifacts / f'YueJing-{r.VERSION}.ipa'

        def package(tamper=False):
            with zipfile.ZipFile(ipa, 'w') as archive:
                for path in app.iterdir():
                    archive.writestr('Payload/YueJing.app/' + path.name,
                                     b'tampered' if tamper and path.name == 'Assets.car' else path.read_bytes())
            manifest = dict(version=r.VERSION, build=r.BUILD, ipa_file=ipa.name, source_commit=head, signing='unsigned',
                            ipa_bytes=ipa.stat().st_size, ipa_sha256=hashlib.sha256(ipa.read_bytes()).hexdigest(),
                            app_icon_files=['Assets.car'])
            (artifacts / 'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')

        package()
        with patch.object(r, 'OUT', out_del), patch.object(r, 'NATIVE_OUT', out_del / 'epub-freeze'), \
             patch.object(r, 'SCOPE_JSON', out_del / 'epub-freeze-scope.json'), \
             patch.object(r, 'REUSED_OUT', out_del / 'reused-evidence'), \
             patch.object(r, 'REUSED_GATE_JSON', out_del / 'reused-evidence/reused-evidence-gate.json'), \
             patch.object(r, 'GATE_JSON', out_del / 'gate.json'), \
             patch.object(r, 'PACKAGE_JSON', out_del / 'package.json'), \
             patch.object(r, 'live_scope', return_value=receipt), \
             patch.object(r, 'HIST_ARCHIVE_BYTES', hist_artifact['size_in_bytes']), \
             patch.object(r, 'HIST_ARCHIVE_SHA256', hist_artifact['digest'].split(':', 1)[1]), \
             patch.object(r.compat, 'validate_toolchain_and_dependencies', return_value=_synthetic_packages()), \
             patch.object(v, 'APP', app), patch.object(v, 'report'):
            reused_del = r.reuse_evidence(
                offline_prior=dict(zip_path=prior_zip, run_json=prior_run_json, artifact_json=prior_art_json),
            )
            assert reused_del['passed'] is True and reused_del['reused_native_passed'] == 37
            del_qual = r.qualification()
            r.write(out_del / 'gate.json', del_qual)
            assert del_qual['qualification'] == r.DELIVERY_QUALIFICATION
            assert del_qual['native_tests_executed_this_run'] == 0
            assert del_qual['reused_native_passed'] == 37
            assert del_qual['verified_passed'] == 37 and del_qual['combined_verified_passed'] == 37
            assert del_qual['simulator'] is None and del_qual['groups'] == []
            assert del_qual['reused_prior']['run_id'] == prior_id
            assert del_qual['reused_historical']['run_id'] == str(r.HIST_RUN)
            del_summary = r.summarize()
            assert del_summary['native_tests_executed_this_run'] == 0 and del_summary['reused_native_passed'] == 37
            assert sum(x['status'] == 'reused_from_prior' for x in del_summary['ui_inventory']) == 1
            assert sum(x['status'] == 'reused_historical' for x in del_summary['ui_inventory']) == 1
            assert sum(x['status'] == 'not_selected' for x in del_summary['ui_inventory']) == 13

            formal_del = r.delivery_gate()
            assert formal_del['strict_native_qualification'] == 'passed'
            assert formal_del['native_tests_executed_this_run'] == 0 and formal_del['reused_native_passed'] == 37
            assert formal_del['verified_passed'] == 37 and formal_del['combined_verified_passed'] == 37
            with patch.object(v, 'ROOT', work), patch.object(v, 'candidate_files', return_value=candidate_map), \
                 patch.dict(os.environ, {'GITHUB_SHA': head}):
                v.verify_ipa(epub_freeze=True)
            saved_pkg = r.load(out_del / 'package.json')
            assert saved_pkg['ipa_integrity'] == 'passed' and saved_pkg['qualification'] == r.DELIVERY_QUALIFICATION
            assert saved_pkg['native_tests_executed_this_run'] == 0 and saved_pkg['verified_passed'] == 37
            (out_del / 'package.json').unlink()
            checks.append('delivery phase reuses prior2+historical35 (native=0, reused=37) and verifies device + IPA')

            # Reject validation phase calling delivery_gate.
            with patch.object(r, 'live_scope', return_value=val_receipt):
                rejects('validation phase cannot enter delivery_gate', r.delivery_gate)
            # Reject delivery phase with leftover simulator/native evidence.
            (out_del / 'simulator-selection.json').write_text('{}', encoding='utf-8')
            rejects('delivery phase rejects leftover simulator-selection.json', r.release_gate)
            (out_del / 'simulator-selection.json').unlink()

            # Reject corrupted IPA payload and changed device image even after formal qualification.
            package(tamper=True)
            with patch.object(v, 'ROOT', work), patch.object(v, 'candidate_files', return_value=candidate_map), \
                 patch.dict(os.environ, {'GITHUB_SHA': head}):
                rejects('IPA bytes differ even with matching manifest digest', lambda: v.verify_ipa(epub_freeze=True))
                package()
                with patch.dict(os.environ, {'GITHUB_SHA': 'b' * 40}):
                    rejects('IPA foreign SHA', lambda: v.verify_ipa(epub_freeze=True))
                (app / 'YueJing').write_bytes(b'changed image')
                package()
                rejects('matching ZIP cannot conceal changed device image', lambda: v.verify_ipa(epub_freeze=True))
                (app / 'YueJing').write_bytes(b'synthetic device image')
                package()

            # Reject wrong qualification / counts in release_gate.
            for field, val in [
                ('scope', r.DIAGNOSTIC_SCOPE), ('qualification', 'DEVICE_DIAGNOSTIC_ONLY'),
                ('verified_passed', 36), ('combined_verified_passed', 35), ('native_tests_executed_this_run', 2),
                ('reused_native_passed', 35), ('verified_declarations', 37),
                ('version', '0.2.13'), ('build', '15'), ('full_regression_passed', True),
            ]:
                with patch.object(r, 'validate_saved', return_value={**del_qual, field: val}):
                    rejects('formal release rejects ' + field + '=' + str(val), r.release_gate)

        # Negative prior validation run checks: recursive prior, wrong source, missing event, failed current2, diagnostic opt-in.
        for label, kwargs in [
            ('recursive prior_validation_run', dict(prior_phase='delivery', prior_prior='111111', prior_build_ipa=True)),
            ('prior wrong source_commit', dict(prior_sha='b' * 40)),
            ('prior build_ipa true', dict(prior_build_ipa=True)),
            ('prior missing dispatch-event', dict(include_event=False)),
            ('prior missing historical35', dict(include_hist=False)),
            ('prior failed ui-1', dict(failed_group='ui-1', prior_conclusion='failure')),
        ]:
            neg_out = work / f'neg-{len(checks)}'
            neg_out.mkdir()
            p_zip, p_run, p_art = _build_synthetic_prior_zip(
                work, '777' + str(len(checks)), kwargs.pop('prior_sha', head), destination,
                candidate_map, hist_extracted, **kwargs,
            )
            p_run_j = neg_out / 'prun.json'
            p_art_j = neg_out / 'part.json'
            r.write(p_run_j, p_run)
            r.write(p_art_j, dict(total_count=1, artifacts=[p_art]))
            del_neg_scope = {**receipt, 'prior_validation_run': str(p_run['id']), 'allow_unqualified_ipa': True}
            r.write(neg_out / 'dependency-resolution.json', dict(packages=_synthetic_packages()))
            (neg_out / 'toolchain.log').write_text('Xcode 16.4\n', encoding='utf-8')
            (neg_out / 'xcodegen.log').write_text('Version: 2.46.0\n', encoding='utf-8')
            (neg_out / 'app-build.log').write_text('BUILD SUCCEEDED\n', encoding='utf-8')
            (neg_out / 'app-build-exit-code.txt').write_text('0\n', encoding='utf-8')
            r.write(neg_out / 'epub-freeze-scope.json', del_neg_scope)
            _make_linkage_dir(neg_out / 'webkit-device-linkage', head, del_neg_scope['run_id'], binaries_payload=b'synthetic device image')
            with patch.object(r, 'OUT', neg_out), patch.object(r, 'NATIVE_OUT', neg_out / 'epub-freeze'), \
                 patch.object(r, 'SCOPE_JSON', neg_out / 'epub-freeze-scope.json'), \
                 patch.object(r, 'REUSED_OUT', neg_out / 'reused-evidence'), \
                 patch.object(r, 'REUSED_GATE_JSON', neg_out / 'reused-evidence/reused-evidence-gate.json'), \
                 patch.object(r, 'GATE_JSON', neg_out / 'gate.json'), \
                 patch.object(r, 'PACKAGE_JSON', neg_out / 'package.json'), \
                 patch.object(r, 'live_scope', return_value=del_neg_scope), \
                 patch.object(r, 'HIST_ARCHIVE_BYTES', hist_artifact['size_in_bytes']), \
                 patch.object(r, 'HIST_ARCHIVE_SHA256', hist_artifact['digest'].split(':', 1)[1]), \
                 patch.object(r.compat, 'validate_toolchain_and_dependencies', return_value=_synthetic_packages()), \
                 patch.object(v, 'APP', app):
                rejects(label + ' rejected by reuse', lambda pz=p_zip, pr=p_run_j, pa=p_art_j: r.reuse_evidence(
                    offline_prior=dict(zip_path=pz, run_json=pr, artifact_json=pa)))
                if 'failed ui-1' in label:
                    # With allow_unqualified_ipa=False, failed ui-1 refuses delivery.
                    with patch.object(r, 'live_scope', return_value={**del_neg_scope, 'allow_unqualified_ipa': False}):
                        rejects('failed prior ui-1 without diagnostic opt-in refuses delivery', r.delivery_gate)
                    # With allow_unqualified_ipa=True, emits DEVICE_DIAGNOSTIC_ONLY with truthful known/unknown counts.
                    diag = r.delivery_gate()
                    assert diag['qualification'] == 'DEVICE_DIAGNOSTIC_ONLY' and diag['coverage'] == 'UI_NOT_QUALIFIED'
                    assert diag['verified_passed'] is None and diag['combined_verified_passed'] is None
                    assert diag['native_tests_executed_this_run'] == 0 and diag['reused_native_passed'] is None
                    assert diag['reused_historical_passed'] == 35 and diag['known_executions'] == 36
                    assert diag['unknown_execution_groups'] == ['ui-1']
                    checks.append('failed prior ui-1 with explicit diagnostic opt-in preserves known=36, unknown=ui-1, verified=null')
                    # Diagnostic opt-in still cannot bypass source/device/toolchain integrity.
                    with patch.object(r, 'live_scope', side_effect=ValueError('source mismatch')):
                        rejects('explicit permission cannot bypass source integrity', r.delivery_gate)
                    with patch.object(r, 'validate_linkage', side_effect=ValueError('device linkage failed')):
                        rejects('explicit permission cannot bypass device WebKit integrity', r.delivery_gate)
                    (neg_out / 'app-build-exit-code.txt').write_text('65')
                    rejects('explicit permission cannot bypass failed device build', r.delivery_gate)
                    (neg_out / 'app-build-exit-code.txt').write_text('0')
                else:
                    # Provenance/source/recursive errors CANNOT be bypassed even with allow_unqualified_ipa=True!
                    rejects(label + ' cannot be bypassed by allow_unqualified_ipa', r.delivery_gate)
                    neg_sum = r.summarize()
                    assert neg_sum['native_tests_executed_this_run'] == 0
                    assert neg_sum['reused_native_passed'] is None and neg_sum['combined_verified_passed'] is None
                    ui1_row = next(x for x in neg_sum['ui_inventory'] if x['case'] == r.UI_METHOD)
                    assert ui1_row['status'] == 'reuse_unverified' and ui1_row['current_selection'] == 'reused_from_prior'
            # Reject cross-phase offline replay kwargs.
            rejects('delivery phase rejects offline_historical', lambda: r.reuse_evidence(
                offline_historical=dict(zip_path=hist_zip, run_json=hist_run_json, artifact_json=hist_art_json)))
    # Dispatch permission & two-phase event binding tests.
    with tempfile.TemporaryDirectory(prefix='epub-dispatch-', dir=os.environ.get('PI_SCRATCH_DIR')) as temp:
        out = Path(temp)
        event = out / 'event.json'
        with patch.dict(os.environ, {'GITHUB_EVENT_PATH': str(event), 'ALLOW_UNQUALIFIED_IPA': 'false',
                                     'BUILD_IPA': 'false', 'PRIOR_VALIDATION_RUN': '', 'GITHUB_RUN_ID': '12345'}):
            event.write_text(json.dumps(dict(inputs=dict(validation_scope=r.SCOPE))))
            assert r.dispatch_permission() is False
            checks.append('missing explicit dispatch permission defaults false')
            with patch.dict(os.environ, {'ALLOW_UNQUALIFIED_IPA': 'true'}):
                rejects('environment true cannot forge omitted dispatch permission', r.dispatch_permission)
                event.write_text(json.dumps(dict(inputs=dict(validation_scope=r.SCOPE, allow_unqualified_ipa=True))))
                assert r.dispatch_permission() is True
                checks.append('explicit true dispatch and environment agree')
            rejects('dispatch true cannot be changed to environment false', r.dispatch_permission)
            event.write_text(json.dumps(dict(inputs=dict(validation_scope='full', allow_unqualified_ipa=False))))
            rejects('diagnostic permission cannot cross scope', r.dispatch_permission)
            event.write_text(json.dumps(dict(inputs=dict(validation_scope=r.SCOPE, build_ipa=True, prior_validation_run='987654'))))
            rejects('build environment cannot differ from dispatch stage', r.dispatch_permission)
            with patch.dict(os.environ, {'BUILD_IPA': 'true', 'PRIOR_VALIDATION_RUN': '987654'}):
                assert r.dispatch_context()['phase'] == 'delivery'
                checks.append('explicit delivery phase bound to dispatch event')
            event.write_text(json.dumps(dict(inputs=dict(validation_scope=r.SCOPE, build_ipa=True, prior_validation_run=''))))
            with patch.dict(os.environ, {'BUILD_IPA': 'true', 'PRIOR_VALIDATION_RUN': ''}):
                rejects('validation phase with build_ipa=true rejected', r.dispatch_context)
            event.write_text(json.dumps(dict(inputs=dict(validation_scope=r.SCOPE, build_ipa=False, prior_validation_run='987654'))))
            with patch.dict(os.environ, {'BUILD_IPA': 'false', 'PRIOR_VALIDATION_RUN': '987654'}):
                rejects('delivery phase with build_ipa=false rejected', r.dispatch_context)
            event.write_text(json.dumps(dict(inputs=dict(validation_scope=r.SCOPE, build_ipa=True, prior_validation_run='12345'))))
            with patch.dict(os.environ, {'BUILD_IPA': 'true', 'PRIOR_VALIDATION_RUN': '12345'}):
                rejects('self-referential prior_validation_run rejected', r.dispatch_context)
            event.write_text(json.dumps(dict(inputs=dict(validation_scope=r.SCOPE, build_ipa=True, prior_validation_run=str(r.HIST_RUN)))))
            with patch.dict(os.environ, {'BUILD_IPA': 'true', 'PRIOR_VALIDATION_RUN': str(r.HIST_RUN)}):
                rejects('historical Round 1 run rejected as prior_validation_run', r.dispatch_context)

    # Package gate entrypoints cannot bypass delivery_gate or mix modes.
    with patch.object(v.sys, 'platform', 'darwin'), patch.object(r, 'delivery_gate', side_effect=ValueError('not qualified')):
        rejects('device package cannot bypass explicit delivery gate', lambda: v.package_gate(epub_freeze=True))
    with patch.object(v.sys, 'platform', 'darwin'):
        rejects('mixed device package qualification', lambda: v.package_gate(epub_freeze=True, diagnostic=True))
        rejects('mixed IPA qualification', lambda: v.verify_ipa(epub_freeze=True, epub_reading=True))

    # Scheduler checks: first case fails -> second case still executes; preflight blocks; cancel not swallowed.
    with tempfile.TemporaryDirectory(prefix='epub-continue-', dir=os.environ.get('PI_SCRATCH_DIR')) as temp:
        root = Path(temp)
        scope = dict(scope=r.SCOPE, phase='validation', prior_validation_run='', source_commit='a' * 40, run_id='synthetic')
        for scenario in ('early_failure', 'timeout_and_fail', 'all_pass', 'preflight', 'cancelled'):
            out = root / scenario
            visited = []

            def prepare(kind, folder, source_commit, **kwargs):
                visited.append(folder.name)

            def stream(args, log, timeout):
                group = log.parent.name
                assert len([s for s in args if s.startswith('-only-testing:')]) == 1
                assert timeout == 480
                if scenario == 'cancelled' and group == 'ui-1':
                    raise KeyboardInterrupt()
                raw = fixture(group)
                if scenario == 'early_failure' and group == 'host-1':
                    log.write_bytes(raw.replace(b'passed', b'failed').replace(b'TEST SUCCEEDED', b'TEST FAILED'))
                    return 65, False
                if scenario == 'timeout_and_fail' and group == 'host-1':
                    log.write_bytes(b'synthetic timeout')
                    return -9, True
                log.write_bytes(raw)
                return 0, False

            def preflight(*args, **kwargs):
                if scenario == 'preflight':
                    raise ValueError('synthetic common toolchain unavailable')

            with patch.object(r, 'OUT', out), patch.object(r, 'NATIVE_OUT', out / 'epub-freeze'), \
                 patch.object(r, 'REUSED_OUT', out / 'reused-evidence'), \
                 patch.object(r, 'REUSED_GATE_JSON', out / 'reused-evidence/reused-evidence-gate.json'), \
                 patch.object(r, 'SCOPE_JSON', out / 'epub-freeze-scope.json'), \
                 patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(out / 'synthetic-step-summary.md'), 'PRIOR_VALIDATION_RUN': ''}), \
                 patch.object(r, 'live_scope', return_value=scope), \
                 patch.object(r.compat, 'validate_toolchain_and_dependencies', side_effect=preflight), \
                 patch.object(r.compat, 'validate_destination'), \
                 patch.object(r.reading, 'prepare_group_settings', side_effect=prepare), \
                 patch.object(r, 'stream_case', side_effect=stream), \
                 patch.object(r.paging, 'require_xcresult'), \
                 contextlib.redirect_stdout(io.StringIO()):
                if scenario == 'preflight':
                    rejects('common prerequisite fails once without running tests', lambda: r.run_all(destination))
                    assert not visited
                elif scenario == 'cancelled':
                    try:
                        r.run_all(destination)
                    except KeyboardInterrupt:
                        pass
                    else:
                        raise AssertionError('Cancellation swallowed')
                    assert visited == ['host-1', 'ui-1'] and (out / 'epub-freeze/host-1/counts.json').is_file()
                    checks.append('cancellation stops scheduling without swallowing KeyboardInterrupt')
                else:
                    assert r.run_all(destination) == (scenario == 'all_pass')
                    assert visited == ['host-1', 'ui-1']
                    checks.append(scenario + ': production scheduler attempted both selected identities')
                report = r.summarize(publish=True)
                assert len(report['cases']) == 2 and len(report['ui_inventory']) == 15
                assert sum(report['counts'].values()) == 2
                assert sum(x['status'] == 'not_selected' for x in report['ui_inventory']) == 13
                if scenario == 'early_failure':
                    assert report['counts'] == dict(passed=1, failed=1, timed_out=0, error=0, blocked=0, not_run=0)
                    assert report['native_tests_executed_this_run'] is None
                    rejects('early failure cannot qualify despite later ui-1 pass', r.qualification)
                elif scenario == 'timeout_and_fail':
                    assert report['counts'] == dict(passed=1, failed=0, timed_out=1, error=0, blocked=0, not_run=0)
                    rejects('timeout cannot qualify', r.qualification)
                elif scenario == 'all_pass':
                    assert report['counts'] == dict(passed=2, failed=0, timed_out=0, error=0, blocked=0, not_run=0)
                    rejects('all_pass without historical reuse cannot qualify', r.qualification)
                elif scenario == 'preflight':
                    assert report['counts'] == dict(passed=0, failed=0, timed_out=0, error=0, blocked=2, not_run=0)
                else:
                    assert report['counts'] == dict(passed=1, failed=0, timed_out=0, error=0, blocked=0, not_run=1)
                markdown = (out / 'case-results.md').read_text('utf-8')
                assert all(x['case'] in markdown for x in report['ui_inventory'])
                if scenario != 'preflight':
                    rejects('existing case evidence cannot be overwritten/retried', lambda: r.run_all(destination))

        # Real local child success/nonzero/timeout followed by next process (Python processes, NOT Swift).
        assert r.stream_case([sys.executable, '-c', 'print("ok")'], root / 'success.log', 10) == (0, False)
        assert r.stream_case([sys.executable, '-c', 'raise SystemExit(7)'], root / 'failure.log', 10) == (7, False)
        code, expired = r.stream_case([sys.executable, '-c', 'import time; time.sleep(20)'], root / 'timeout.log', 0.2)
        assert expired and code != 0
        assert r.stream_case([sys.executable, '-c', 'print("after timeout")'], root / 'after.log', 10) == (0, False)
        checks.append('real local child success/nonzero/timeout followed by next process; no pipe hang')

    # Workflow step admission evaluation across both phases.
    blocks = {re.search(r'\n        id: (\w+)', block)[1]: block for block in job.split('      - name: ')
              if re.search(r'\n        id: (\w+)', block)}

    def admitted(step, outcomes, cancelled=False, build_ipa=False, prior=''):
        expression = re.search(r'\n        if: \$\{\{ (.+) \}\}', blocks[step])[1]
        expression = expression.replace('!cancelled()', str(not cancelled)).replace('&&', ' and ')
        expression = expression.replace('inputs.build_ipa', str(build_ipa))
        expression = expression.replace('inputs.prior_validation_run', repr(prior))
        expression = re.sub(r"steps\.(\w+)\.outcome", lambda m: repr(outcomes.get(m[1], 'skipped')), expression)
        return eval(expression, {'__builtins__': {}}, {})

    val_ok = dict(scope='success', toolchain='success', dependencies='success', reuse='failure',
                  simulator='success', boot='success', tests='failure', native_gate='failure')
    assert admitted('simulator', val_ok, build_ipa=False, prior='') and admitted('tests', val_ok, build_ipa=False, prior='')
    assert admitted('simulator_linkage', val_ok, build_ipa=False, prior='')
    assert not admitted('device', val_ok, build_ipa=False, prior='') and not admitted('package', val_ok, build_ipa=False, prior='')
    del_ok = dict(scope='success', toolchain='success', dependencies='success', reuse='success',
                  simulator='skipped', boot='skipped', tests='skipped', device='success')
    assert admitted('reuse', del_ok, build_ipa=True, prior='987654')
    assert not admitted('simulator', del_ok, build_ipa=True, prior='987654')
    assert not admitted('boot', del_ok, build_ipa=True, prior='987654')
    assert not admitted('tests', del_ok, build_ipa=True, prior='987654')
    assert not admitted('simulator_linkage', del_ok, build_ipa=True, prior='987654')
    assert admitted('device', del_ok, build_ipa=True, prior='987654') and admitted('package', del_ok, build_ipa=True, prior='987654')
    for prereq in ('scope', 'toolchain', 'dependencies'):
        assert not admitted('reuse', {**del_ok, prereq: 'failure'}, build_ipa=True, prior='987654')
        assert not admitted('device', {**del_ok, prereq: 'failure'}, build_ipa=True, prior='987654')
        assert not admitted('package', {**del_ok, prereq: 'failure'}, build_ipa=True, prior='987654')
    assert not admitted('package', del_ok, cancelled=True, build_ipa=True, prior='987654')
    assert "!cancelled() && steps.package.outcome == 'success'" in job
    checks.append('workflow conditions verified for validation phase, delivery phase, reuse independence, and shared prerequisite blocking')

    ui_source = (r.ROOT / 'Tests/YueJingEPUBUITests/EPUBFlowUITests.swift').read_text('utf-8')
    assert 'waitFor { abs(Double(coordinate("scrollX") - initialX) - Double(initialFrame.width)) <= 2 }' in ui_source
    assert 'XCTAssertEqual(Double(nextX - initialX), Double(view.frame.width), accuracy: 2)' in ui_source
    assert 348 > 0 and not abs(348 - 375) <= 2 and abs(375 - 375) <= 2
    checks.append('existing exact paging completion wait and final assertion preserved')

    return dict(
        offline_checks_passed=len(checks),
        checks=checks,
        native_tests_executed=0,
        release_source_ready=not blockers,
        source_blockers=blockers,
    )


def run_explicit_historical_replay(hist_zip, hist_run_json, hist_art_json):
    """Explicit offline replay against a real historical artifact ZIP (never called by default)."""
    with tempfile.TemporaryDirectory(prefix='epub-real-hist-replay-', dir=os.environ.get('PI_SCRATCH_DIR')) as temp:
        work = Path(temp)
        out = work / 'out'
        out.mkdir()
        head = r.git('rev-parse', 'HEAD').decode().strip()
        ev = work / 'val-event.json'
        ev.write_text(json.dumps(dict(inputs=dict(
            validation_scope=r.SCOPE, allow_unqualified_ipa=False, build_ipa=False, prior_validation_run='',
        ))), encoding='utf-8')
        scope = dict(
            scope=r.SCOPE, phase='validation', prior_validation_run='',
            source_commit=head, baseline_commit=r.BASE, run_id='888001', run_attempt='1',
            version=r.VERSION, build=r.BUILD, allow_unqualified_ipa=False,
            dispatch_event_sha256=r.sha(ev), build_ipa=False,
        )
        r.write(out / 'dependency-resolution.json', dict(packages=_synthetic_packages()))
        (out / 'toolchain.log').write_text(
            f'Source: {head}\narm64\nXcode 16.4\nBuild version 16F6\nApple Swift version 6.1.2\n', encoding='utf-8',
        )
        (out / 'xcodegen.log').write_text('Version: 2.46.0\n', encoding='utf-8')
        with patch.object(r, 'OUT', out), patch.object(r, 'NATIVE_OUT', out / 'epub-freeze'), \
             patch.object(r, 'REUSED_OUT', out / 'reused-evidence'), \
             patch.object(r, 'REUSED_GATE_JSON', out / 'reused-evidence/reused-evidence-gate.json'), \
             patch.object(r, 'live_scope', return_value=scope), \
             patch.object(r.compat, 'validate_toolchain_and_dependencies', return_value=_synthetic_packages()):
            receipt = r.reuse_evidence(
                offline_historical=dict(zip_path=hist_zip, run_json=hist_run_json, artifact_json=hist_art_json),
                check_shared_sources=True,
                verify_live_bundle=False,
            )
            assert receipt['passed'] is True
            assert receipt['reused_historical_passed'] == 35
            assert receipt['historical']['declarations_passed'] == 34
            assert receipt['historical']['executions_passed'] == 35
            assert receipt['historical']['workflow_conclusion'] == 'failure'
            assert not (out / f'reused-evidence/historical-{r.HIST_RUN}/evidence/epub-freeze/host-3').exists()
            assert not (out / f'reused-evidence/historical-{r.HIST_RUN}/evidence/epub-freeze/ui-1').exists()
            assert not any((out / 'reused-evidence').rglob('data.0~*'))
            # Also verify delivery-phase replay carrying that real historical35 inside a synthetic prior ZIP!
            dest = 'platform=iOS Simulator,id=66571EB4-A450-4628-ABB9-3D215AFEDD58'
            hist_extracted = out / f'reused-evidence/historical-{r.HIST_RUN}'
            cand = v.candidate_files()
            p_zip, p_run, p_art = _build_synthetic_prior_zip(
                work, '888001', head, dest, cand, hist_extracted,
            )
            p_run_j = work / 'p-run.json'
            p_art_j = work / 'p-art.json'
            r.write(p_run_j, p_run)
            r.write(p_art_j, dict(total_count=1, artifacts=[p_art]))
            out_del = work / 'out-del'
            out_del.mkdir()
            r.write(out_del / 'dependency-resolution.json', dict(packages=_synthetic_packages()))
            (out_del / 'toolchain.log').write_text('Xcode 16.4\n', encoding='utf-8')
            (out_del / 'xcodegen.log').write_text('Version: 2.46.0\n', encoding='utf-8')
            del_scope = {**scope, 'phase': 'delivery', 'prior_validation_run': '888001', 'build_ipa': True, 'run_id': '888002'}
            r.write(out_del / 'epub-freeze-scope.json', del_scope)
            with patch.object(r, 'OUT', out_del), patch.object(r, 'NATIVE_OUT', out_del / 'epub-freeze'), \
                 patch.object(r, 'SCOPE_JSON', out_del / 'epub-freeze-scope.json'), \
                 patch.object(r, 'REUSED_OUT', out_del / 'reused-evidence'), \
                 patch.object(r, 'REUSED_GATE_JSON', out_del / 'reused-evidence/reused-evidence-gate.json'), \
                 patch.object(r, 'GATE_JSON', out_del / 'gate.json'), \
                 patch.object(r, 'live_scope', return_value=del_scope), \
                 patch.object(r.compat, 'validate_toolchain_and_dependencies', return_value=_synthetic_packages()):
                del_reuse = r.reuse_evidence(
                    offline_prior=dict(zip_path=p_zip, run_json=p_run_j, artifact_json=p_art_j),
                    check_shared_sources=True,
                )
                assert del_reuse['passed'] is True and del_reuse['reused_native_passed'] == 37
                del_qual = r.qualification()
                assert del_qual['native_tests_executed_this_run'] == 0
                assert del_qual['reused_native_passed'] == 37
                assert del_qual['verified_passed'] == 37
                del_sum = r.summarize()
                assert del_sum['native_tests_executed_this_run'] == 0 and del_sum['reused_native_passed'] == 37
        retained_files = [p for p in (out / 'reused-evidence').rglob('*') if p.is_file()]
        retained_bytes = sum(p.stat().st_size for p in retained_files)
    return dict(
        historical_replay_passed=True,
        historical_run=r.HIST_RUN,
        historical_artifact_id=r.HIST_ARTIFACT_ID,
        historical_archive_sha256=r.HIST_ARCHIVE_SHA256,
        historical_reused_declarations=34,
        historical_reused_executions=35,
        delivery_combined_verified=37,
        retained_file_count=len(retained_files),
        retained_bytes=retained_bytes,
        native_tests_executed=0,
    )


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--historical-zip', type=Path)
    parser.add_argument('--historical-run-json', type=Path)
    parser.add_argument('--historical-artifact-json', type=Path)
    args = parser.parse_args()
    result = run_offline_checks()
    if args.historical_zip or args.historical_run_json or args.historical_artifact_json:
        if not (args.historical_zip and args.historical_run_json and args.historical_artifact_json):
            parser.error('Offline historical replay requires --historical-zip, --historical-run-json, and --historical-artifact-json')
        result['historical_replay'] = run_explicit_historical_replay(
            args.historical_zip, args.historical_run_json, args.historical_artifact_json,
        )
    print(json.dumps(result, indent=2))

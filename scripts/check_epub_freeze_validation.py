"""Offline gate/parser/security checks. Synthetic native fixtures are NOT native acceptance."""
import argparse
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import traceback
from unittest.mock import patch
import zipfile

import run_epub_freeze_validation as r

checks = []
DESTINATION = 'platform=iOS Simulator,id=11111111-2222-3333-4444-555555555555'
SOURCE = 'a' * 40
PRIOR_ID, CURRENT_ID = '900001', '900002'


def passed(label):
    checks.append(label)


def rejects(label, action):
    try:
        action()
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile):
        passed(label)
    else:
        raise AssertionError('Expected rejection: ' + label)


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2), encoding='utf-8')


def fixture(group):
    spec = r.GROUPS[group]
    name = spec['cases'][0]
    if spec['kind'] == 'ui':
        text = (f"Test Case '-[EPUBFlowUITests {name}]' started.\n"
                f"Test Case '-[EPUBFlowUITests {name}]' passed (0.1 seconds).\n"
                'Executed 1 test, with 0 failures (0 unexpected) in 0.1 seconds\n')
    else:
        param = r.inventory.PARAMETERIZED.get(name)
        signature = name + (param['signature'] if param else '()')
        text = f'◇ Test {signature} started.\n'
        if param:
            text += ''.join(f"◇ Passing 1 argument {param['argument']} → {value} to {signature}\n" for value in param['values'])
        text += f'✔ Test {signature} passed after 0.1 seconds.\n✔ Test run with 1 tests passed after 0.2 seconds.\n'
    return (text + '** TEST SUCCEEDED **\n').encode()


def executions(spec):
    return len(r.inventory.PARAMETERIZED.get(spec['cases'][0], {}).get('values', [None]))


def tree_for(spec):
    name = spec['cases'][0]
    node = dict(name=name + r.inventory.PARAMETERIZED.get(name, {}).get('signature', '()'),
                nodeType='Test Case', result='Passed', children=[])
    if name in r.inventory.PARAMETERIZED:
        node['children'] = [dict(name='symlink: ' + value, nodeType='Arguments', result='Passed') for value in ('false', 'true')]
    return dict(testNodes=[node])


def synthetic_export(bundle, section):
    # Explicit mock boundary. This data is never described as an xcresulttool run.
    return (bundle / ('synthetic-' + section + '.json')).read_bytes()


def scope_for(phase='validation'):
    return dict(scope=r.SCOPE, phase=phase, prior_validation_run=PRIOR_ID if phase == 'delivery' else '',
                source_commit=SOURCE, baseline_commit=r.BASE, run_id=CURRENT_ID if phase == 'delivery' else PRIOR_ID,
                run_attempt='1', version=r.VERSION, build=r.BUILD, allow_unqualified_ipa=False, source_status='clean',
                build_ipa=phase == 'delivery', selected=r.selection(), selected_declarations=0 if phase == 'delivery' else 3,
                native_tests_planned=0 if phase == 'delivery' else 4, reused_native_planned=25 if phase == 'delivery' else 21,
                combined_target_declarations=24, combined_target_executions=25, full_inventory_declared=241,
                full_inventory_executions=242, files={'synthetic.swift': 'b' * 64}, approved_files={},
                changed_paths=sorted(r.ALLOWED), physical_acceptance='not performed', full_regression_passed=False)


@contextlib.contextmanager
def sandbox(root, scope=None):
    root.mkdir(parents=True, exist_ok=True)
    attrs = dict(OUT=root, NATIVE_OUT=root / 'epub-freeze', SCOPE_JSON=root / 'epub-freeze-scope.json',
                 DISPATCH_EVENT_JSON=root / 'dispatch-event.json', GATE_JSON=root / 'epub-freeze-gate.json',
                 PACKAGE_JSON=root / 'epub-freeze-package.json', REUSED_OUT=root / 'reused-evidence',
                 REUSED_GATE_JSON=root / 'reused-evidence/reused-evidence-gate.json', REUSED_STAGING=root / 'staging')
    with contextlib.ExitStack() as stack:
        for name, value in attrs.items():
            stack.enter_context(patch.object(r, name, value))
        stack.enter_context(patch.dict(os.environ, GITHUB_ACTIONS='false', PRIOR_VALIDATION_RUN=''))
        if scope is not None:
            stack.enter_context(patch.object(r, 'live_scope', return_value=scope))
            save(r.SCOPE_JSON, scope)
        yield


def settings(kind, target, folder, source, eff):
    common = dict(SWIFT_VERSION='6.0', SWIFT_STRICT_CONCURRENCY='complete', IPHONEOS_DEPLOYMENT_TARGET='16.6')
    if kind == 'domain':
        values = json.loads(eff.read_text())['ReaderDomainTests']
        receipt = dict(source_commit=source, target=target, scheme='ReaderDomain', scheme_sha256='1' * 64,
                       effective_settings_sha256=r.sha(eff), testables=['ReaderDomainTests'], settings=values)
    else:
        app = dict(**common, PRODUCT_TYPE='com.apple.product-type.application', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG')
        test = dict(**common, PRODUCT_TYPE='com.apple.product-type.bundle.ui-testing', TEST_TARGET_NAME='YueJing')
        if kind == 'host':
            test = dict(**common, PRODUCT_TYPE='com.apple.product-type.bundle.unit-test',
                        TEST_HOST='/Debug-iphonesimulator/YueJing.app/YueJing', BUNDLE_LOADER='/Debug-iphonesimulator/YueJing.app/YueJing')
        receipt = dict(source_commit=source, scheme_sha256='2' * 64, testables=list(r.ui.GROUPS),
                       fixture_environment='11111111-2222-3333-4444-555555555555', targets={'YueJing': app, target: test})
    save(folder / (target + '-settings.json'), receipt)


def group_files(root, group, scope, *, exit_code=0, timed_out=False):
    spec = r.GROUPS[group]
    folder = root / 'epub-freeze' / group
    folder.mkdir(parents=True, exist_ok=True)
    target = spec['target']
    bundle = folder / (target + '.xcresult')
    (bundle / 'Data').mkdir(parents=True)
    (bundle / 'Info.plist').write_bytes(b'synthetic-not-native')
    (bundle / 'Data/data.0').write_bytes(b'synthetic-not-native')
    save(bundle / 'synthetic-tests.json', tree_for(spec))
    save(bundle / 'synthetic-summary.json', dict(totalTestCount=len(spec['cases']), passedTests=len(spec['cases']), failedTests=0, skippedTests=0))
    want = r.provenance(group, DESTINATION, bundle, scope)
    save(folder / 'selection.json', want)
    save(folder / 'execution.json', dict(**want, native_exit=exit_code, timed_out=timed_out))
    raw = fixture(group)
    (folder / (target + '.log')).write_bytes(raw)
    if exit_code or timed_out:
        return
    parsed = r.parse_log(group, raw, 0, False)
    parsed['parameter_xcresult'] = r.parameter_evidence(group, folder, bundle, export=True)
    save(folder / 'counts.json', parsed)
    return parsed


def packages():
    return {name: dict(package=dict(identity=name, kind='remoteSourceControl', location=dep['url'],
                                   state=dict(revision=dep['revision'], version=dep['version'])),
                       checkout_revision=dep['revision'], package_manifest_sha256=dep['manifest'])
            for name, dep in r.compat.epub_batch.DEPENDENCIES.items()}


def common_files(root, scope):
    (root / 'toolchain.log').write_text(f'Source: {SOURCE}\narm64\nXcode 16.4\nBuild version 16F6\nApple Swift version 6.1.2\n')
    (root / 'xcodegen.log').write_text('Version: 2.46.0\n')
    (root / 'Package.resolved').write_text('{}\n')
    save(root / 'dependency-resolution.json', dict(packages=packages()))
    save(root / 'candidate-sources.json', dict(source_commit=SOURCE, run_id=scope['run_id'], run_attempt='1', files=scope['files']))
    values = dict(PRODUCT_TYPE='com.apple.product-type.bundle.unit-test', SWIFT_VERSION='6.0',
                  SWIFT_STRICT_CONCURRENCY='complete', IPHONEOS_DEPLOYMENT_TARGET='16.6', TEST_HOST='', BUNDLE_LOADER='', TEST_TARGET_NAME='')
    save(root / 'effective-test-settings.json', dict(ReaderDomainTests=values))
    save(root / 'simulator-selection.json', dict(udid=DESTINATION.split('id=')[1], device_name='iPhone SE',
                                               architecture='arm64', physical_device=False))
    save(root / 'simulator-boot.json', dict(source_commit=SOURCE, run_id=scope['run_id'], run_attempt='1', exit_code=0, timed_out=False))
    link = root / 'webkit-simulator-linkage'
    link.mkdir()
    (link / 'binary').write_bytes(b'synthetic macho')
    (link / 'nm-1.log').write_text('synthetic nm')
    save(link / 'verification.json', dict(source_commit=SOURCE, run_id=scope['run_id'], run_attempt='1', passed=True,
                                         errors=[], binaries=[dict(evidence='binary', sha256=r.sha(link / 'binary'), passed=True, nm_exit=0)]))


def zip_source(source, path):
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(source.rglob('*')):
            if file.is_file():
                archive.write(file, file.relative_to(source).as_posix())


def api_metadata(archive):
    run = dict(id=int(PRIOR_ID), head_sha=SOURCE, run_attempt=1, workflow_id=r.WORKFLOW_ID, path=r.WORKFLOW_PATH,
               event='workflow_dispatch', head_branch='main', status='completed', conclusion='success',
               repository=dict(full_name=r.REPO), head_repository=dict(full_name=r.REPO))
    artifact = dict(id=9900001, expired=False, name=f'task3-evidence-{PRIOR_ID}-{SOURCE}',
                    workflow_run=dict(id=int(PRIOR_ID), head_sha=SOURCE), size_in_bytes=archive.stat().st_size,
                    digest='sha256:' + r.sha(archive))
    return run, artifact


def synthetic_historical():
    return dict(run_id=str(r.HISTORICAL_RUN), source_commit=r.HISTORICAL_SOURCE, archive_sha256=r.HISTORICAL_SHA256,
                qualified=True, native_bundle_parse='passed', executions_passed=21, declarations_passed=21)


def build_prior(root):
    scope = scope_for()
    root.mkdir()
    common_files(root, scope)
    event = dict(inputs=dict(validation_scope=r.SCOPE, allow_unqualified_ipa=False, build_ipa=False, prior_validation_run=''))
    save(root / 'dispatch-event.json', event)
    scope['dispatch_event_sha256'] = r.sha(root / 'dispatch-event.json')
    save(root / 'epub-freeze-scope.json', scope)
    historical = synthetic_historical()
    (root / 'reused-evidence' / r.HISTORICAL_FOLDER).mkdir(parents=True)
    (root / 'reused-evidence' / r.HISTORICAL_FOLDER / 'synthetic-bound-marker').write_bytes(b'not native evidence')
    save(root / 'reused-evidence/reused-evidence-gate.json', r.validation_reuse_receipt(scope, historical))
    groups = []
    for group, spec in r.GROUPS.items():
        groups.append(group_files(root, group, scope))
        settings(spec['kind'], spec['target'], root / 'epub-freeze' / group, SOURCE, root / 'effective-test-settings.json')
    gate = dict(**scope, qualification=r.VALIDATION_QUALIFICATION, coverage='EPUB_TARGETED_NOT_FULL',
                native_tests_executed_this_run=4, reused_native_passed=21, reused_historical_passed=21,
                reused_historical=historical, verified_passed=25, combined_verified_passed=25,
                verified_declarations=24, unselected_executions=217, not_executed_this_run=238, groups=groups)
    save(root / 'epub-freeze-gate.json', gate)
    return scope, gate


def bind_prior(source, folder):
    folder.mkdir(parents=True)
    archive = folder / 'archive.zip'
    zip_source(source, archive)
    run, artifact = api_metadata(archive)
    save(folder / 'api-run.json', run)
    save(folder / 'api-artifact.json', artifact)
    members = r.safe_zip_members(archive)
    retained = r.extract_selected_members(archive, members, r._prior_wanted_members(members), folder / 'evidence')
    save(folder / 'archive-receipt.json', dict(run_id=PRIOR_ID, run_attempt='1', source_commit=SOURCE,
         artifact_id=artifact['id'], archive_bytes=archive.stat().st_size, archive_sha256=r.sha(archive),
         member_count=len(members), members=members, retained_files=retained))
    return run, artifact


def inspect_pass(folder):
    result = r.inspect_prior_evidence(folder, scope_for('delivery'), expected_packages=packages(), check_shared_sources=False)
    r.require(result['passed'] and result['executions_passed'] == 4 and result['declarations_passed'] == 3,
              'Synthetic prior rejected: ' + '; '.join(result['errors']))
    return result


def check_parsers():
    for group, spec in r.GROUPS.items():
        raw = fixture(group)
        assert r.parse_log(group, raw, 0, False)['executions'] == executions(spec)
        passed(group + ': synthetic event chain')
        for label, altered, code, timeout in (
            ('exit', raw, 65, False), ('bool exit', raw, False, False), ('timeout', raw, 0, True),
            ('no success', raw.replace(b'** TEST SUCCEEDED **', b''), 0, False),
            ('late', raw.replace(b'0.1 seconds', b'181 seconds'), 0, False), ('duplicate', raw + raw, 0, False),
            ('missing', raw.replace(spec['cases'][0].encode(), b'foreignCase'), 0, False),
            ('failed green', raw + b'Test foreign failed\n', 0, False), ('skipped green', raw + b'Test foreign skipped\n', 0, False)):
            rejects(group + ': ' + label, lambda a=altered, c=code, t=timeout: r.parse_log(group, a, c, t))
        cmd = r.command(group, DESTINATION, Path('synthetic.xcresult'))
        assert len([a for a in cmd if a.startswith('-only-testing:')]) == 1
        assert cmd.count('180') == 2 and spec['timeout'] == 480
        assert cmd[cmd.index('-scheme') + 1] == ('ReaderDomain' if spec['kind'] == 'domain' else 'YueJingUI')
    raw = fixture('domain-12')
    line = next(line for line in raw.splitlines(keepends=True) if b'Passing ' in line)
    for label, altered in [('missing argument', raw.replace(line, b'')), ('duplicate argument', raw.replace(line, line * 2)),
                           ('unknown argument', raw.replace(b'false to ', b'unknown to ')), ('late argument', raw.replace(line, b'') + line)]:
        rejects(label, lambda a=altered: r.parse_log('domain-12', a, 0, False))
    tree = tree_for(r.GROUPS['domain-12'])
    assert r.parameter_result(tree)['passed_arguments'] == ['false', 'true']
    for label, mutate in [('missing leaf', lambda x: x['testNodes'][0]['children'].pop()),
                           ('skip leaf', lambda x: x['testNodes'][0]['children'][0].update(result='Skipped')),
                           ('failed parent', lambda x: x['testNodes'][0].update(result='Failed'))]:
        altered = copy.deepcopy(tree)
        mutate(altered)
        rejects(label, lambda a=altered: r.parameter_result(a))


def check_dispatch(root):
    event_path = root / 'event.json'
    def invoke(build=False, prior='', allowed=False):
        save(event_path, dict(inputs=dict(validation_scope=r.SCOPE, build_ipa=build, prior_validation_run=prior, allow_unqualified_ipa=allowed)))
        with patch.dict(os.environ, GITHUB_EVENT_PATH=str(event_path), GITHUB_RUN_ID=CURRENT_ID,
                        BUILD_IPA=str(build).lower(), PRIOR_VALIDATION_RUN=prior, ALLOW_UNQUALIFIED_IPA=str(allowed).lower()):
            return r.dispatch_context()
    assert invoke()['phase'] == 'validation'
    assert invoke(True, PRIOR_ID)['phase'] == 'delivery'
    for label, args in [('diagnostic', (False, '', True)), ('delivery no prior', (True, '')),
                         ('prior without build', (False, PRIOR_ID)), ('self prior', (True, CURRENT_ID)), ('invalid prior', (True, '../1'))]:
        rejects(label, lambda a=args: invoke(*a))
    passed('two-phase dispatch boundaries')


def check_scheduler(root):
    for mode in ('individual', 'blocked', 'common', 'cancel'):
        called = []
        scope = scope_for()
        with sandbox(root / mode, scope), patch.object(r, 'xcresult_export', side_effect=synthetic_export), \
                patch.object(r.compat, 'validate_toolchain_and_dependencies') as tools, \
                patch.object(r.compat, 'validate_destination'), patch.object(r, 'run_group') as run:
            def execute(group, destination, checked_scope=None):
                called.append(group)
                if mode == 'cancel':
                    raise KeyboardInterrupt('synthetic cancellation')
                if mode == 'blocked' and group == 'domain-12':
                    raise r.GroupPrerequisiteError('synthetic shared settings failure')
                if mode == 'individual' and group == 'host-2':
                    group_files(r.OUT, group, scope, exit_code=65)
                    raise ValueError('synthetic assertion failure')
                group_files(r.OUT, group, scope)
            run.side_effect = execute
            if mode == 'common':
                tools.side_effect = ValueError('synthetic toolchain failure')
                rejects('shared prerequisite stops all', lambda: r.run_all(DESTINATION))
            elif mode == 'cancel':
                try:
                    r.run_all(DESTINATION)
                except KeyboardInterrupt:
                    passed('cancel stops scheduling')
                else:
                    raise AssertionError('Cancellation swallowed')
            else:
                assert r.run_all(DESTINATION) is False
            report = r.summarize()
            assert len(report['ui_inventory']) == 15
            assert sum(row['current_selection'] == 'selected' for row in report['ui_inventory']) == 1
            assert sum(row['current_selection'] == 'reused' for row in report['ui_inventory']) == 2
            assert report['unselected_executions'] == 217
            if mode == 'individual':
                assert called == list(r.GROUPS) and report['counts']['passed'] == 2 and report['counts']['failed'] == 1
            elif mode == 'blocked':
                assert len(called) == 3 and report['counts']['blocked'] == 1 and report['counts']['passed'] == 2
            else:
                assert len(called) == (1 if mode == 'cancel' else 0) and report['counts']['blocked'] == 3
            passed(mode + ': independent scheduling / truthful blocked accounting')
    with sandbox(root / 'validation-reuse', scope_for()), patch.object(r, 'retain_historical_evidence', return_value=synthetic_historical()) as retain, \
            patch.object(r.compat, 'validate_toolchain_and_dependencies', return_value=packages()):
        assert r.reuse_evidence()['reused_native_passed'] == 21
        assert retain.call_args.args[0].name == r.HISTORICAL_FOLDER
        passed('validation admits only fixed historical21; never calls prior reuse')
    with sandbox(root / 'delivery-no-native', scope_for('delivery')), patch.object(r, 'stream_case') as stream:
        rejects('delivery forbids run-group', lambda: r.run_group('host-2', DESTINATION))
        rejects('delivery forbids run-all', lambda: r.run_all(DESTINATION))
        stream.assert_not_called()


def check_archive_security(root):
    for index, name in enumerate(('../escape', '/absolute', 'C:/drive', 'a\\escape', 'a/../escape')):
        path = root / f'unsafe-{index}.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            info = zipfile.ZipInfo(name)
            info.filename = name  # Defeat Windows ZipInfo separator normalization in this hostile fixture.
            archive.writestr(info, b'bad')
        rejects('unsafe ZIP ' + name, lambda p=path: r.safe_zip_members(p))
    for mode in ('symlink', 'duplicate', 'compression'):
        path = root / (mode + '.zip')
        with zipfile.ZipFile(path, 'w') as archive:
            if mode == 'symlink':
                info = zipfile.ZipInfo('link')
                info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(info, 'target')
            elif mode == 'duplicate':
                archive.writestr('same', b'one')
                archive.writestr('same', b'two')
            else:
                archive.writestr('member', b'data', compress_type=zipfile.ZIP_BZIP2)
        rejects('ZIP ' + mode, lambda p=path: r.safe_zip_members(p))
    path = root / 'download.zip'
    def download(args, **kwargs):
        assert kwargs['timeout'] == 600 and kwargs['check'] is True
        assert args[:4] == ['gh', 'api', '--method', 'GET']
        kwargs['stdout'].write(b'synthetic-download')
    with patch.object(r.subprocess, 'run', side_effect=download):
        r.github_download_artifact_zip(99, path)
        rejects('download refuses overwrite', lambda: r.github_download_artifact_zip(99, path))
    assert path.read_bytes() == b'synthetic-download'
    passed('download bytes streamed to exclusive file with bounded invocation')


def check_prior(root):
    source = root / 'prior-source'
    with patch.object(r, 'xcresult_export', side_effect=synthetic_export), \
            patch.object(r, 'verify_historical_evidence', return_value=synthetic_historical()):
        scope, gate = build_prior(source)
        folder = root / 'valid-prior'
        run, artifact = bind_prior(source, folder)
        assert inspect_pass(folder)['executions_passed'] == 4
        passed('same-source followup prior3/4 bound to one fixed historical21 (synthetic boundary)')
        def timeout_one(bundle, section):
            if bundle.parent.name == 'host-2':
                raise subprocess.TimeoutExpired('synthetic xcresulttool', 60)
            return synthetic_export(bundle, section)
        with patch.object(r, 'xcresult_export', side_effect=timeout_one):
            report = r.inspect_prior_evidence(folder, scope_for('delivery'), check_shared_sources=False)
            assert report['passed'] is False and len(report['case_rows']) == 3 and len(report['groups']) == 2
            passed('xcresult parser timeout rejects prior without hiding other two independent results')
        for field, value in [('status', 'in_progress'), ('conclusion', 'failure'), ('conclusion', 'cancelled'),
                             ('run_attempt', 2), ('head_sha', 'c' * 40), ('workflow_id', 1), ('event', 'push'), ('head_branch', 'other')]:
            altered = dict(run, **{field: value})
            rejects('prior API ' + field + '=' + str(value), lambda a=altered: r.validate_prior_run_and_artifact(PRIOR_ID, a, artifact, SOURCE, CURRENT_ID))
        rejects('API self reference', lambda: r.validate_prior_run_and_artifact(PRIOR_ID, run, artifact, SOURCE, PRIOR_ID))
        for field, value in [('expired', True), ('digest', None), ('size_in_bytes', 0), ('name', 'wrong')]:
            altered = dict(artifact, **{field: value})
            rejects('artifact API ' + field, lambda a=altered: r.validate_prior_run_and_artifact(PRIOR_ID, run, a, SOURCE, CURRENT_ID))
        mutations = [
            ('recursive', 'epub-freeze-scope.json', lambda x: x.update(phase='delivery', prior_validation_run='123', build_ipa=True)),
            ('wrong scope', 'epub-freeze-scope.json', lambda x: x.update(scope='old-scope')),
            ('wrong source', 'candidate-sources.json', lambda x: x.update(source_commit='b' * 40)),
            ('wrong count', 'epub-freeze-gate.json', lambda x: x.update(verified_passed=24)),
            ('old reused count', 'epub-freeze-gate.json', lambda x: x.update(reused_native_passed=36)),
            ('diagnostic gate', 'epub-freeze-gate.json', lambda x: x.update(allow_unqualified_ipa=True)),
            ('missing gate field', 'epub-freeze-gate.json', lambda x: x.pop('qualification')),
            ('command drift', 'epub-freeze/host-2/selection.json', lambda x: x['command'].append('-skip-testing:foreign')),
            ('failed native', 'epub-freeze/host-2/execution.json', lambda x: x.update(native_exit=65)),
            ('timeout native', 'epub-freeze/ui-2/execution.json', lambda x: x.update(timed_out=True)),
            ('skip xcresult', 'epub-freeze/ui-2/YueJingEPUBUITests.xcresult/synthetic-tests.json', lambda x: x['testNodes'][0].update(result='Skipped')),
            ('missing parameter', 'epub-freeze/domain-12/xcresult-tests.json', lambda x: x['testNodes'][0]['children'].pop()),
            ('deps drift', 'dependency-resolution.json', lambda x: x['packages']['grdb.swift'].update(checkout_revision='0' * 40)),
            ('linkage failure', 'webkit-simulator-linkage/verification.json', lambda x: x.update(passed=False)),
            ('historical count drift', 'reused-evidence/reused-evidence-gate.json', lambda x: x.update(reused_native_passed=20)),
            ('historical wrong binding', 'reused-evidence/reused-evidence-gate.json', lambda x: x['historical'].update(archive_sha256='0' * 64)),
            ('prior claims fresh25', 'epub-freeze-gate.json', lambda x: x.update(native_tests_executed_this_run=25)),
        ]
        for index, (label, rel, mutate) in enumerate(mutations):
            altered_source = root / f'bad-source-{index}'
            shutil.copytree(source, altered_source)
            path = altered_source / rel
            value = json.loads(path.read_text())
            mutate(value)
            save(path, value)
            bad = root / f'bad-prior-{index}'
            bind_prior(altered_source, bad)
            rejects(label, lambda p=bad: inspect_pass(p))
        for index, rel in enumerate(('epub-freeze-gate.json', 'epub-freeze/ui-2/counts.json',
                                     'epub-freeze/domain-12/ReaderDomainTests.xcresult/Data/data.0')):
            altered_source = root / f'missing-source-{index}'
            shutil.copytree(source, altered_source)
            (altered_source / rel).unlink()
            bad = root / f'missing-prior-{index}'
            bind_prior(altered_source, bad)
            rejects('missing ' + rel, lambda p=bad: inspect_pass(p))
        tampered = root / 'tampered-prior'
        shutil.copytree(folder, tampered)
        log = tampered / 'evidence/epub-freeze/host-2/YueJingHostTests.log'
        log.write_bytes(log.read_bytes() + b'tampered')
        rejects('retained log tampering', lambda: inspect_pass(tampered))
        receipt = json.loads((tampered / 'archive-receipt.json').read_text())
        rel = log.relative_to(tampered / 'evidence').as_posix()
        receipt['members'][rel] = receipt['retained_files'][rel] = dict(bytes=log.stat().st_size, sha256=r.sha(log))
        save(tampered / 'archive-receipt.json', receipt)
        rejects('forged retained manifest still bound to original archive', lambda: inspect_pass(tampered))
        extra_source = root / 'recursive-source'
        shutil.copytree(source, extra_source)
        save(extra_source / 'reused-evidence/prior-foreign/gate.json', {})
        extra = root / 'recursive-prior'; bind_prior(extra_source, extra)
        rejects('arbitrary nested prior chain', lambda: inspect_pass(extra))
        with sandbox(root / 'delivery', scope_for('delivery')):
            offline = dict(zip_path=folder / 'archive.zip', run_json=folder / 'api-run.json', artifact_json=folder / 'api-artifact.json')
            reused = r.reuse_evidence(require_dependencies=False, offline_prior=offline, check_shared_sources=False)
            assert reused['reused_native_passed'] == 25 and reused['reused_declarations'] == 24
            assert not r.NATIVE_OUT.exists() and not (r.OUT / 'simulator-boot.json').exists()
            passed('delivery downloads/binds only initial same-source prior; zero new native evidence')
            inspect = r.inspect_prior_evidence
            def synthetic_inspect(path, scope, **kwargs):
                return inspect(path, scope, expected_packages=kwargs.get('expected_packages'), check_shared_sources=False)
            with patch.object(r, 'inspect_prior_evidence', side_effect=synthetic_inspect), \
                    patch.object(r.compat, 'validate_toolchain_and_dependencies', return_value=packages()):
                delivery = r.qualification()
                assert delivery['native_tests_executed_this_run'] == 0 and delivery['reused_native_passed'] == 25
                save(r.GATE_JSON, delivery)
                assert r.release_gate()['verified_passed'] == 25
                save(r.OUT / 'simulator-selection.json', {})
                rejects('delivery rejects current simulator evidence', r.qualification)
                (r.OUT / 'simulator-selection.json').unlink()
                altered = dict(reused, reused_native_passed=24)
                save(r.REUSED_GATE_JSON, altered)
                rejects('delivery reused gate count tampering', r.qualification)
                passed('real delivery qualification logic enforces 0/25 with synthetic native parser boundary')
        # Fresh gate runs its real parser, commands, counts and xcresult verification;
        # only platform tool/settings/linkage calls and live source are mocked.
        with sandbox(root / 'fresh-gate', scope), patch.object(r.compat, 'validate_toolchain_and_dependencies', return_value=packages()), \
                patch.object(r.compat, 'validate_destination'), patch.object(r, 'validate_linkage', return_value='d' * 64), \
                patch.object(r.reading, 'validate_group_settings'), \
                patch.object(r, 'verify_validation_reuse', return_value=synthetic_historical()):
            shutil.copytree(source / 'epub-freeze', r.NATIVE_OUT)
            shutil.copyfile(source / 'simulator-selection.json', r.OUT / 'simulator-selection.json')
            shutil.copyfile(source / 'simulator-boot.json', r.OUT / 'simulator-boot.json')
            # Rewrite only the synthetic absolute result path for the new local fixture root.
            for group, spec in r.GROUPS.items():
                f = r.NATIVE_OUT / group
                want = r.provenance(group, DESTINATION, f / (spec['target'] + '.xcresult'), scope)
                save(f / 'selection.json', want)
                save(f / 'execution.json', dict(**want, native_exit=0, timed_out=False))
            fresh = r.qualification()
            assert fresh['native_tests_executed_this_run'] == 4 and fresh['reused_native_passed'] == 21
            save(r.GATE_JSON, fresh)
            assert r.release_gate()['verified_passed'] == 25
            altered = dict(fresh, verified_passed=24)
            save(r.GATE_JSON, altered)
            rejects('saved gate tampering', r.release_gate)
            save(r.NATIVE_OUT / 'host-2/failure.json', dict(error='failed'))
            rejects('failure receipt overrides green counts', r.qualification)
            passed('followup native gate enforces new4/reused21/combined25, exact receipts')


def check_native_copy(root):
    bundle = root / 'immutable.xcresult'
    bundle.mkdir()
    (bundle / 'Info.plist').write_bytes(b'immutable')
    seen = []
    def export(args, **kwargs):
        working = Path(args[-1])
        assert working != bundle and kwargs['timeout'] == 60
        assert (working / 'Info.plist').read_bytes() == b'immutable'
        (working / 'database.sqlite3').write_bytes(b'materialized')
        seen.append(str(working))
        return b'{}'
    with patch.object(r.sys, 'platform', 'darwin'), patch.object(r.subprocess, 'check_output', side_effect=export):
        r.xcresult_export(bundle, 'tests')
    assert seen and not (bundle / 'database.sqlite3').exists()
    passed('mocked xcresulttool materialization confined to temporary copy; not native verification')


def check_package(root):
    scope = scope_for('delivery')
    qualified = dict(**scope, qualification=r.DELIVERY_QUALIFICATION, verified_passed=25,
                     combined_verified_passed=25, verified_declarations=24, native_tests_executed_this_run=0,
                     reused_native_passed=25)
    with patch.object(r, 'validate_saved', return_value=qualified):
        assert r.release_gate() == qualified
    for field, value in [('allow_unqualified_ipa', True), ('verified_passed', 24), ('reused_native_passed', 24),
                         ('native_tests_executed_this_run', 1), ('version', '0.2.14'), ('build', '16'), ('qualification', 'DIAGNOSTIC')]:
        with patch.object(r, 'validate_saved', return_value=dict(qualified, **{field: value})):
            rejects('release strict field ' + field, r.release_gate)
    with sandbox(root / 'package', scope), patch.object(r.compat, 'validate_toolchain_and_dependencies', return_value=packages()):
        (r.OUT / 'app-build-exit-code.txt').write_text('65')
        rejects('actual device build failure blocks package', r.delivery_gate)
        (r.OUT / 'app-build-exit-code.txt').write_text('0')
        rejects('missing actual device linkage blocks package', r.delivery_gate)
        with patch.object(r, 'delivery_gate', return_value=qualified), patch.object(r.v, 'APP', root / 'app'):
            r.v.APP.mkdir()
            (r.v.APP / 'YueJing').write_bytes(b'synthetic device image')
            dep = dict(source_commit=SOURCE, run_id=CURRENT_ID, run_attempt='1', signing='unsigned',
                       actual_images=[dict(binary='YueJing', sha256=r.sha(r.v.APP / 'YueJing'))])
            manifest = dict(source_commit=SOURCE, version=r.VERSION, build=r.BUILD, ipa_sha256='f' * 64)
            save(r.OUT / 'app-dependency-gate.json', dict(dep, run_id='wrong'))
            rejects('device dependency source/run binding', lambda: r.complete_delivery(manifest, 1))
            save(r.OUT / 'app-dependency-gate.json', dep)
            rejects('IPA actual version binding', lambda: r.complete_delivery(dict(manifest, version='0.2.14'), 1))
            (r.v.APP / 'YueJing').write_bytes(b'tampered')
            rejects('actual device image hash binding', lambda: r.complete_delivery(manifest, 1))


def workflow_contract():
    text = (r.ROOT / r.WORKFLOW_PATH).read_text(encoding='utf-8')
    job = text.split('  epub_freeze:', 1)[1]
    for token in (r.SCOPE, 'timeout-minutes: 60', 'timeout=120', 'run_epub_freeze_validation.py run-all',
                  'run_epub_freeze_validation.py gate', 'run_epub_freeze_validation.py reuse',
                  "inputs.prior_validation_run == ''", 'if: always()', 'check_webkit_linkage.py',
                  'package-gate-epub-freeze', 'verify-ipa-epub-freeze', 'actions: read', 'persist-credentials: false'):
        assert token in job, 'Missing workflow contract: ' + token
    assert 'epub-ready-host-followup-1' not in job
    # The 30-second live tool probes live in the unchanged shared helper.
    helper = (r.ROOT / 'scripts/run_epub_compat_validation.py').read_text(encoding='utf-8')
    assert 'timeout=30' in helper
    passed('workflow directed routing / 60min job / 120s boot / 30s tool probe contracts')


def check_source_boundaries():
    original_git = r.git
    with patch.dict(os.environ, GITHUB_ACTIONS='true'):
        rejects('cloud cannot use pending source', lambda: r.validate_followup_sources(pending=True))
    with patch.object(r, 'git', side_effect=lambda *args: b' M Package.swift\0' if args[0] == 'status' else original_git(*args)):
        rejects('pending cannot change dependency manifest', lambda: r.validate_followup_sources(pending=True))
    candidate = r.v.candidate_files()
    with patch.object(r.v, 'candidate_files', return_value={**candidate, 'Sources/unapproved.swift': '0' * 64}):
        rejects('pending cannot add arbitrary source', lambda: r.validate_followup_sources(pending=True))
    original_sha = r.sha
    protected = 'Tests/YueJingHostTests/EPUBReaderHostTests.swift'
    with patch.object(r, 'sha', side_effect=lambda p: '0' * 64 if p == r.ROOT / protected else original_sha(p)):
        rejects('approved path cannot weaken existing assertions', lambda: r.validate_followup_sources(pending=True))
    original_read = Path.read_bytes
    def altered_project(path):
        data = original_read(path)
        return data + b'\n# unapproved configuration change\n' if path == r.ROOT / 'project.yml' else data
    with patch.object(Path, 'read_bytes', altered_project):
        rejects('project version-only boundary', r.validate_version_boundary)
    original = r.git('show', r.HISTORICAL_SOURCE + ':' + r.HOST_SOURCE).decode('utf-8')
    current = (r.ROOT / r.HOST_SOURCE).read_text(encoding='utf-8')
    r.validate_host_diagnostic_isolation(original, current)
    for label, old, new in (
        ('shared helper', 'private func waitUntilReady', 'private func changedWaitUntilReady'),
        ('bounded snapshot', 'timeout: 2)', 'timeout: 20)'),
        ('rethrow', 'throw error // Preserve', 'return // Preserve'),
        ('original readiness call', 'waitUntilReady(model: model, expectedToken: token)', 'waitUntilReady(model: model, expectedToken: token, minimumNode: 0)'),
    ):
        altered = current.replace(old, new, 1)
        assert altered != current
        rejects('Host isolation: ' + label, lambda a=altered: r.validate_host_diagnostic_isolation(original, a))
        # Exercise structural isolation behind the independently pinned byte gate.
        if label in ('shared helper', 'bounded snapshot', 'rethrow', 'original readiness call'):
            with patch.dict(r.CANDIDATE_SHA256, {r.HOST_SOURCE: r.compat.digest_bytes(altered.encode())}):
                rejects('Host function boundary behind SHA: ' + label, lambda a=altered: r.validate_host_diagnostic_isolation(original, a))


def check_processes(root):
    assert r.stream_case([sys.executable, '-c', 'print("ok")'], root / 'process-ok.log', 10) == (0, False)
    assert r.stream_case([sys.executable, '-c', 'raise SystemExit(7)'], root / 'process-fail.log', 10) == (7, False)
    code, expired = r.stream_case([sys.executable, '-c', 'import time; time.sleep(20)'], root / 'process-timeout.log', 0.2)
    assert expired and code != 0
    assert r.stream_case([sys.executable, '-c', 'print("after timeout")'], root / 'process-after.log', 10) == (0, False)
    passed('real local Python child success/failure/timeout/next process; NOT Swift/native execution')


def check_bool_results(root):
    """Declaration totals cannot replace the two independently successful arguments."""
    spec = r.GROUPS['domain-12']
    tests = tree_for(spec)
    summary = dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0)
    bundle = root / 'bool.xcresult'
    (bundle / 'Data').mkdir(parents=True)
    (bundle / 'Info.plist').write_bytes(b'synthetic-not-native')
    (bundle / 'Data/data.0').write_bytes(b'synthetic-not-native')
    def verify(tests_value, summary_value):
        with patch.object(r, 'xcresult_export', side_effect=lambda b, section: json.dumps(
                tests_value if section == 'tests' else summary_value).encode()):
            return r.verify_group_xcresult(spec, bundle)
    assert verify(tests, summary) == tests
    assert r.parameter_result(tests)['passed_arguments'] == ['false', 'true']
    assert r.parse_log('domain-12', fixture('domain-12'), 0, False)['executions'] == 2
    passed('one summary declaration plus exactly two passed Bool leaves yields two expansions')
    expanded_summary = dict(summary, totalTestCount=2, passedTests=2)
    assert verify(tests, expanded_summary) == tests
    passed('expansion-count summary still requires both exact Bool leaves')
    rejects('foreign summary cardinality', lambda: verify(tests, dict(summary, totalTestCount=3, passedTests=3)))
    for label, mutate in (
        ('missing leaf', lambda x: x['testNodes'][0]['children'].pop()),
        ('duplicate leaf', lambda x: x['testNodes'][0]['children'].append(copy.deepcopy(x['testNodes'][0]['children'][0]))),
        ('failed leaf', lambda x: x['testNodes'][0]['children'][0].update(result='Failed')),
        ('skipped leaf', lambda x: x['testNodes'][0]['children'][0].update(result='Skipped')),
        ('missing leaf result', lambda x: x['testNodes'][0]['children'][0].pop('result')),
        ('duplicate declaration', lambda x: x['testNodes'].append(copy.deepcopy(x['testNodes'][0]))),
        ('failed declaration', lambda x: x['testNodes'][0].update(result='Failed')),
        ('green parent without arguments', lambda x: x['testNodes'][0].update(children=[])),
        ('foreign argument label', lambda x: x['testNodes'][0]['children'][0].update(name='foreign false')),
    ):
        bad = copy.deepcopy(tests); mutate(bad)
        rejects('Bool: ' + label, lambda b=bad: verify(b, summary))
        rejects('Bool expanded-summary: ' + label, lambda b=bad: verify(b, expanded_summary))
    for field, value in (('totalTestCount', 2), ('passedTests', 2), ('passedTests', 0),
                         ('failedTests', 1), ('skippedTests', 1), ('totalTestCount', True), ('passedTests', None)):
        rejects('Bool summary ' + field + '=' + str(value), lambda f=field, v=value: verify(tests, dict(summary, **{f: v})))
    # Exercise actual run_group ordering, not a mock of run_group itself.
    scope = dict(scope=r.SCOPE, phase='validation', source_commit=SOURCE, run_id=CURRENT_ID, run_attempt='1')
    for scenario in ('passed', 'bad-summary', 'bad-tree', 'native-failed'):
        out = root / ('bool-run-' + scenario)
        raw_tests = json.dumps(tests).encode() if scenario != 'bad-tree' else b'{invalid native JSON'
        raw_summary = json.dumps(dict(summary, passedTests=0) if scenario == 'bad-summary' else summary).encode()
        def stream(args, log, timeout):
            assert timeout == 480 and args.count('180') == 2
            destination = log.parent / 'ReaderDomainTests.xcresult'
            shutil.copytree(bundle, destination)
            log.write_bytes(fixture('domain-12'))
            return (65 if scenario == 'native-failed' else 0), False
        with sandbox(out, scope), patch.object(r.reading, 'prepare_group_settings'), \
                patch.object(r, 'stream_case', side_effect=stream), \
                patch.object(r, 'xcresult_export', side_effect=lambda b, section: raw_tests if section == 'tests' else raw_summary):
            if scenario == 'passed':
                r.run_group('domain-12', DESTINATION, checked_scope=scope)
            else:
                rejects('Bool run-group ' + scenario, lambda: r.run_group('domain-12', DESTINATION, checked_scope=scope))
            folder = r.NATIVE_OUT / 'domain-12'
            assert (folder / 'xcresult-tests.json').read_bytes() == raw_tests
            assert (folder / 'xcresult-summary.json').read_bytes() == raw_summary
            assert (folder / 'counts.json').exists() == (scenario == 'passed')
            if scenario == 'passed':
                assert r.load(folder / 'counts.json')['executions'] == 2
            passed('both raw exports preserved before validation: ' + scenario)
    for scenario in ('export-failed', 'export-timeout'):
        folder = root / scenario; folder.mkdir()
        original = (subprocess.CalledProcessError(7, ['xcrun'], output=b'partial stdout', stderr=b'raw stderr')
                    if scenario == 'export-failed' else subprocess.TimeoutExpired(['xcrun'], 60, output=b'partial stdout', stderr=b'raw stderr'))
        def export(b, section):
            if section == 'tests':
                raise original
            return json.dumps(summary).encode()
        with patch.object(r, 'xcresult_export', side_effect=export):
            try:
                r.retain_xcresult_exports(folder, bundle)
            except subprocess.SubprocessError as error:
                assert error is original
            else:
                raise AssertionError('Export failure swallowed')
        assert (folder / 'xcresult-tests.stdout').read_bytes() == b'partial stdout'
        assert (folder / 'xcresult-tests.stderr').read_bytes() == b'raw stderr'
        assert not (folder / 'xcresult-tests.json').exists() and not (folder / 'counts.json').exists()
        assert (folder / 'xcresult-summary.json').is_file()
        passed('raw tool streams + original error + independent summary preserved: ' + scenario)
    rejects('raw export never overwritten', lambda: r.retain_xcresult_exports(folder, bundle))


def check_historical_api():
    run = dict(id=r.HISTORICAL_RUN, head_sha=r.HISTORICAL_SOURCE, run_attempt=1, workflow_id=r.WORKFLOW_ID,
               path=r.WORKFLOW_PATH, event='workflow_dispatch', head_branch='main', status='completed', conclusion='failure',
               repository=dict(full_name=r.REPO), head_repository=dict(full_name=r.REPO))
    artifact = dict(id=r.HISTORICAL_ARTIFACT, expired=False, name=r.HISTORICAL_NAME,
                    workflow_run=dict(id=r.HISTORICAL_RUN, head_sha=r.HISTORICAL_SOURCE),
                    size_in_bytes=r.HISTORICAL_BYTES, digest='sha256:' + r.HISTORICAL_SHA256)
    r.validate_historical_run_and_artifact(run, artifact)
    for field, value in [('id', 1), ('head_sha', SOURCE), ('run_attempt', 2), ('status', 'in_progress'),
                         ('conclusion', 'success'), ('event', 'push'), ('workflow_id', 1), ('head_branch', 'foreign')]:
        rejects('pinned historical API ' + field, lambda f=field, v=value: r.validate_historical_run_and_artifact(dict(run, **{f: v}), artifact))
    for field, value in [('id', 1), ('expired', True), ('name', 'foreign'), ('size_in_bytes', 1), ('digest', 'sha256:' + '0' * 64)]:
        rejects('pinned historical artifact ' + field, lambda f=field, v=value: r.validate_historical_run_and_artifact(run, dict(artifact, **{f: v})))
    rejects('failed historical run cannot masquerade as successful prior',
            lambda: r.validate_prior_run_and_artifact(r.HISTORICAL_RUN, run, artifact, r.HISTORICAL_SOURCE, CURRENT_ID))
    with patch.dict(os.environ, GITHUB_ACTIONS='true'):
        rejects('cloud cannot disable historical native parsing', lambda: r.verify_historical_evidence(Path('unused'), verify_native=False))
        rejects('cloud cannot supply offline historical metadata', lambda: r.retain_historical_evidence(Path('unused'), {}))
    passed('fixed failed run contributes only21; no generic failure/attempt/source relaxation')


def run_checks(root, skip_workflow_contract=False):
    assert not skip_workflow_contract or os.environ.get('GITHUB_ACTIONS') != 'true'
    assert r.BASE == 'd5fde953ca544deaecace0434a45b014ebd630b0'
    assert (r.SCOPE, r.VERSION, r.BUILD, r.TOTAL, r.EXECUTIONS) == ('epub-opening-followup-3', '0.2.15', '17', 3, 4)
    assert len(r.ALLOWED) == 19 and len(r.NEW) == 3 and len(r.CANDIDATE_SHA256) == 13
    reviewed = r.reviewed_inventory()
    assert reviewed['selected'] == 241 and reviewed['selected_executions'] == 242
    assert [sum(s['kind'] == kind for s in r.GROUPS.values()) for kind in ('domain', 'host', 'ui')] == [1, 1, 1]
    assert list(r.selection()) == ['domain-12', 'host-2', 'ui-2'] and sum(executions(s) for s in r.GROUPS.values()) == 4
    assert len(r.HISTORICAL_GROUPS) == 24 and len(r.REUSED_GROUPS) == 21
    assert not (set(r.GROUPS) & set(r.REUSED_GROUPS))
    source = r.validate_followup_sources(pending=os.environ.get('GITHUB_ACTIONS') != 'true')
    passed('exact approved candidate/source boundary: ' + source['source_status'])
    passed('inventory241/242; fresh3/4 + fixed historical21 = combined24/25; 217 unselected')
    if not skip_workflow_contract:
        workflow_contract()
    # Even on Actions these checks must never contact an API or execute native tests.
    with patch.dict(os.environ, GITHUB_ACTIONS='false'), \
            patch.object(r, 'github_api_json', side_effect=AssertionError('Self-check cannot contact GitHub')):
        check_source_boundaries()
        check_parsers()
        check_dispatch(root)
        check_scheduler(root)
        check_archive_security(root)
        check_prior(root)
        check_historical_api()
        check_native_copy(root)
        check_bool_results(root)
        check_package(root)
        check_processes(root)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-workflow-contract', action='store_true', help='Local integration only; forbidden in Actions')
    parser.add_argument('--bool-result-only', action='store_true', help='Local focused Bool gate/export checks; no source/business inspection')
    parser.add_argument('--historical-zip', type=Path)
    parser.add_argument('--historical-run-json', type=Path)
    parser.add_argument('--historical-artifact-json', type=Path)
    args = parser.parse_args()
    scratch = os.environ.get('PI_SCRATCH_DIR') or os.environ.get('RUNNER_TEMP')
    if not scratch:
        raise SystemExit('PI_SCRATCH_DIR (local) or RUNNER_TEMP (Actions) is required')
    root = Path(tempfile.mkdtemp(prefix='opening-freeze-check-', dir=scratch))
    print('Retained checks/fixtures: ' + str(root), flush=True)
    try:
        with (root / 'checks.log').open('w', encoding='utf-8') as log, contextlib.redirect_stdout(log):
            if args.bool_result_only:
                assert os.environ.get('GITHUB_ACTIONS') != 'true', 'Focused checks cannot replace cloud self-check'
                check_bool_results(root)
                check_native_copy(root)
            else:
                run_checks(root, args.skip_workflow_contract)
            if any((args.historical_zip, args.historical_run_json, args.historical_artifact_json)):
                assert all((args.historical_zip, args.historical_run_json, args.historical_artifact_json))
                assert os.environ.get('GITHUB_ACTIONS') != 'true'
                offline = dict(zip_path=args.historical_zip, run_json=args.historical_run_json, artifact_json=args.historical_artifact_json)
                replay = r.retain_historical_evidence(root / 'real-historical21', offline, verify_native=sys.platform == 'darwin')
                save(root / 'real-historical-replay.json', replay)
                assert replay['executions_passed'] == 21 and replay['declarations_passed'] == 21
                passed('real pinned ZIP historical21 replay; native parsing=' + replay['native_bundle_parse'])
                if not replay['qualified']:
                    rejects('Windows structural replay cannot qualify reuse', lambda: r.validation_reuse_receipt(scope_for(), replay))
                # Mutate only a fresh scratch copy. Keep original pinned ZIP and
                # all original receipts intact; never bless a regenerated count.
                bad = root / 'tampered-real-history'
                shutil.copytree(root / 'real-historical21', bad)
                rel = 'epub-freeze/domain-1/counts.json'
                path = bad / 'evidence' / rel
                original = path.read_bytes()
                (root / 'tampered-history-original-counts.json').write_bytes(original)
                value = json.loads(original); value['executions'] = 999; save(path, value)
                rejects('real pinned history changed counts rejected', lambda: r.verify_historical_evidence(bad, verify_native=False))
                manifest = r.load(bad / 'archive-receipt.json')
                manifest['members'][rel] = manifest['retained_files'][rel] = dict(bytes=path.stat().st_size, sha256=r.sha(path))
                save(bad / 'archive-receipt.json', manifest)
                rejects('real pinned history local rehash cannot bless changed counts', lambda: r.verify_historical_evidence(bad, verify_native=False))
        report = dict(passed=True, checks=len(checks), labels=checks, native_executions=0,
                      evidence_kind='SYNTHETIC_GATE_CHECKS_NOT_NATIVE_ACCEPTANCE', scope=r.SCOPE,
                      selected_declarations=3, selected_executions=4, reused_historical_executions=21,
                      combined_declarations=24, combined_executions=25, inventory_declarations=241,
                      inventory_executions=242, unselected_executions=217,
                      workflow_check='skipped' if args.skip_workflow_contract or args.bool_result_only else 'passed',
                      check_scope='bool-result-only' if args.bool_result_only else 'full')
        save(root / 'checks.json', report)
        print(json.dumps({k: v for k, v in report.items() if k != 'labels'}, indent=2))
    except BaseException:
        (root / 'failure.txt').write_text(traceback.format_exc(), encoding='utf-8')
        save(root / 'checks.json', dict(passed=False, checks=len(checks), labels=checks, native_executions=0))
        raise
